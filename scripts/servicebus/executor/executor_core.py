"""Fail-closed fixed queue recovery logic; HTTP auth is enforced by App Service Easy Auth."""

from __future__ import annotations

import base64
import json
import os
import re
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Protocol

try:
    from .coordination import CoordinationError, CoordinationStore
except ImportError:
    from coordination import CoordinationError, CoordinationStore

ARM_SCOPE = "https://management.azure.com/.default"
ARM_API_VERSION = "2024-01-01"
FAULT_CONTRACT = "retailtx-servicebus-fault-v1"
COORDINATION_CONTRACT = "retailtx-servicebus-coordination-v1"
QUEUE_ID_PATTERN = re.compile(
    r"^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/"
    r"Microsoft\.ServiceBus/namespaces/[a-z0-9-]{6,50}/queues/"
    r"[A-Za-z0-9][A-Za-z0-9._-]{0,249}$",
    re.IGNORECASE,
)


class AuthorizationError(Exception):
    """The authenticated caller does not match the one authorized SRE identity."""


class RequestError(ValueError):
    """The executor request is not the single supported fixed action."""


class QueueTransport(Protocol):
    def get_queue(self) -> dict[str, Any]: ...

    def put_queue(self, queue: dict[str, Any]) -> dict[str, Any]: ...


@dataclass(frozen=True)
class Settings:
    queue_resource_id: str
    sre_tenant_id: str
    executor_audience: str
    sre_client_app_id: str
    sre_principal_object_id: str
    sre_required_role: str
    owner_token: str
    environment_name: str
    storage_account_name: str
    coordination_container: str
    coordination_blob_name: str


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Required executor setting is missing: {name}.")
    return value


def configuration() -> Settings:
    settings = Settings(
        queue_resource_id=_required_env("EXECUTOR_QUEUE_RESOURCE_ID"),
        sre_tenant_id=_required_env("SRE_TENANT_ID").lower(),
        executor_audience=_required_env("EXECUTOR_AUDIENCE"),
        sre_client_app_id=_required_env("SRE_CLIENT_APP_ID").lower(),
        sre_principal_object_id=_required_env("SRE_PRINCIPAL_OBJECT_ID").lower(),
        sre_required_role=_required_env("SRE_REQUIRED_ROLE"),
        owner_token=_required_env("SCENARIO_OWNER_TOKEN").lower(),
        environment_name=_required_env("SCENARIO_ENVIRONMENT_NAME"),
        storage_account_name=_required_env("COORDINATION_STORAGE_ACCOUNT"),
        coordination_container=_required_env("COORDINATION_CONTAINER"),
        coordination_blob_name=_required_env("COORDINATION_BLOB_NAME"),
    )
    if not QUEUE_ID_PATTERN.fullmatch(settings.queue_resource_id):
        raise RuntimeError("Executor queue resource ID is not a queue resource.")
    for value in (
        settings.sre_tenant_id,
        settings.sre_client_app_id,
        settings.sre_principal_object_id,
        settings.owner_token,
    ):
        try:
            uuid.UUID(value)
        except ValueError as error:
            raise RuntimeError("Executor identity or ownership setting is not a GUID.") from error
    if not re.fullmatch(r"[a-z][a-z0-9]{2,11}", settings.environment_name):
        raise RuntimeError("Executor environment name is invalid.")
    if not settings.executor_audience.startswith("api://"):
        raise RuntimeError("The executor audience must be a registered custom API URI.")
    if settings.sre_required_role != "ServiceBus.QueueRestore":
        raise RuntimeError("Only the fixed ServiceBus.QueueRestore app role is supported.")
    return settings


def _claim_type(value: Any) -> str:
    claim = str(value).lower()
    aliases = {
        "http://schemas.microsoft.com/identity/claims/tenantid": "tid",
        "http://schemas.microsoft.com/identity/claims/objectidentifier": "oid",
        "http://schemas.microsoft.com/identity/claims/applicationid": "appid",
        "http://schemas.microsoft.com/identity/claims/identityprovider": "idp",
        "http://schemas.microsoft.com/ws/2008/06/identity/claims/role": "roles",
    }
    return aliases.get(claim, claim.rsplit("/", 1)[-1])


def decode_principal(encoded: str, **expected: str) -> dict[str, str]:
    if not encoded:
        raise AuthorizationError("Authenticated principal header is missing.")
    try:
        decoded = base64.b64decode(encoded, validate=True)
        principal = json.loads(decoded)
        claims = principal["claims"]
        if not isinstance(claims, list):
            raise ValueError("claims must be a list")
    except (ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
        raise AuthorizationError("Authenticated principal header is invalid.") from error

    normalized: dict[str, list[str]] = {}
    for claim in claims:
        if not isinstance(claim, dict) or "typ" not in claim or "val" not in claim:
            raise AuthorizationError("Authenticated principal contains a malformed claim.")
        claim_name = _claim_type(claim["typ"])
        normalized.setdefault(claim_name, []).append(str(claim["val"]))

    def exact_one(name: str) -> str:
        values = normalized.get(name, [])
        if len(values) != 1:
            raise AuthorizationError(f"Authenticated principal must have one {name} claim.")
        return values[0]

    tid = exact_one("tid").lower()
    aud = exact_one("aud")
    object_id = exact_one("oid").lower()
    app_ids = normalized.get("azp", []) + normalized.get("appid", [])
    roles = normalized.get("roles", [])
    if len(app_ids) != 1 or len(roles) != 1:
        raise AuthorizationError(
            "Authenticated principal has ambiguous application or role claims."
        )
    app_id = app_ids[0].lower()
    role = roles[0]

    actual = {
        "tenant_id": tid,
        "audience": aud,
        "client_app_id": app_id,
        "object_id": object_id,
        "required_role": role,
    }
    for key, value in expected.items():
        if actual.get(key) != value:
            raise AuthorizationError("Authenticated principal is not the authorized SRE identity.")
    return actual


def _utc(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("Fault deadline is missing.")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Fault deadline must include a timezone.")
    return parsed.astimezone(UTC)


class QueueControl:
    def __init__(
        self,
        settings: Settings,
        credential: Any,
        transport: QueueTransport | None = None,
        coordination_store: CoordinationStore | None = None,
    ):
        self.settings = settings
        self.credential = credential
        self.transport = transport
        if coordination_store is None:
            try:
                from .coordination import BlobCoordinationStore
            except ImportError:
                from coordination import BlobCoordinationStore

            coordination_store = BlobCoordinationStore.from_managed_identity(
                storage_account_name=settings.storage_account_name,
                container_name=settings.coordination_container,
                blob_name=settings.coordination_blob_name,
                credential=credential,
            )
        self.coordination_store = coordination_store

    def _request(self, method: str, document: dict[str, Any] | None = None) -> dict[str, Any]:
        token = self.credential.get_token(ARM_SCOPE).token
        url = (
            "https://management.azure.com"
            + self.settings.queue_resource_id
            + "?api-version="
            + ARM_API_VERSION
        )
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }
        request = urllib.request.Request(
            url,
            data=json.dumps(document).encode("utf-8") if document is not None else None,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                if response.status not in (200, 201):
                    raise RuntimeError("ARM queue operation returned an unexpected status.")
                body = response.read()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"ARM queue operation failed with HTTP {error.code}.") from None
        except (urllib.error.URLError, TimeoutError) as error:
            raise RuntimeError("ARM queue operation could not be confirmed.") from error

    def get_queue(self) -> dict[str, Any]:
        if self.transport is not None:
            return self.transport.get_queue()
        return self._request("GET")

    def put_queue(self, queue: dict[str, Any]) -> dict[str, Any]:
        if self.transport is not None:
            return self.transport.put_queue(queue)
        return self._request("PUT", queue)

    def _read_queue(self) -> dict[str, Any]:
        queue = self.get_queue()
        if not isinstance(queue, dict) or str(queue.get("id", "")).lower() != (
            self.settings.queue_resource_id.lower()
        ):
            raise RuntimeError("ARM returned a queue outside the fixed executor target.")
        properties = queue.get("properties")
        if not isinstance(properties, dict) or not isinstance(properties.get("status"), str):
            raise RuntimeError("ARM returned an invalid queue description.")
        return queue

    def _change_status(self, queue: dict[str, Any], status: str) -> None:
        properties = dict(queue["properties"])
        properties["status"] = status
        self.put_queue({"location": queue.get("location"), "properties": properties})

    def _validate_state(self, state: dict[str, Any]) -> dict[str, Any]:
        if (
            not isinstance(state, dict)
            or state.get("contract") != COORDINATION_CONTRACT
            or str(state.get("ownerToken", "")).lower() != self.settings.owner_token
            or state.get("environmentName") != self.settings.environment_name
            or str(state.get("queueResourceId", "")).lower()
            != self.settings.queue_resource_id.lower()
            or state.get("stateVersion") != 1
        ):
            raise RuntimeError(
                "Coordination blob owner, environment, queue, or contract does not match."
            )
        run = state.get("currentRun")
        if run is not None and (
            not isinstance(run, dict)
            or run.get("contract") != FAULT_CONTRACT
            or str(run.get("ownerToken", "")).lower() != self.settings.owner_token
        ):
            raise RuntimeError("Coordination blob contains a foreign fault record.")
        return state

    @contextmanager
    def _locked_state(self) -> Any:
        try:
            with self.coordination_store.locked() as session:
                self._validate_state(session.state)
                yield session
        except CoordinationError as error:
            raise RuntimeError("Durable coordination lease/state is unavailable.") from error

    def initialize_state(self) -> dict[str, Any]:
        initial_state = {
            "contract": COORDINATION_CONTRACT,
            "stateVersion": 1,
            "ownerToken": self.settings.owner_token,
            "environmentName": self.settings.environment_name,
            "queueResourceId": self.settings.queue_resource_id,
            "currentRun": None,
            "watchdogHeartbeatUtc": None,
            "watchdogHeartbeatSuccess": False,
        }
        try:
            state = self.coordination_store.initialize(initial_state)
        except CoordinationError as error:
            raise RuntimeError("Coordination state could not be initialized.") from error
        self._validate_state(state)
        queue = self._read_queue()
        if queue["properties"].get("status") != "Active" or state.get("currentRun"):
            raise RuntimeError("Initialization requires an Active queue with no fault run.")
        return {"initialized": True, "queueId": self.settings.queue_resource_id}

    def snapshot(self) -> dict[str, Any]:
        with self._locked_state() as session:
            return {
                "queue": self._read_queue(),
                "coordination": dict(session.state),
                "coordinationEtag": session.etag,
            }

    def start_fault(
        self,
        *,
        transaction_id: str,
        fault_run_id: str,
        deadline: datetime,
        now: datetime,
    ) -> dict[str, Any]:
        try:
            transaction_id = str(uuid.UUID(transaction_id))
            run_id = str(uuid.UUID(fault_run_id))
        except (ValueError, TypeError, AttributeError) as error:
            raise RequestError("Fault transaction and run IDs must be GUIDs.") from error
        now = now.astimezone(UTC)
        deadline = deadline.astimezone(UTC)
        if not now < deadline <= now + timedelta(minutes=15):
            raise RequestError("Fault deadline must be within the next 15 minutes.")
        with self._locked_state() as session:
            queue = self._read_queue()
            if queue["properties"].get("status") != "Active":
                raise RuntimeError("Fault requires an Active queue.")
            prior = session.state.get("currentRun")
            if prior and prior.get("state") not in {"Recovered", "FaultNotApplied"}:
                raise RuntimeError("An unresolved fault run already owns the queue.")
            run = {
                "contract": FAULT_CONTRACT,
                "ownerToken": self.settings.owner_token,
                "environmentName": self.settings.environment_name,
                "queueResourceId": self.settings.queue_resource_id,
                "runId": run_id,
                "transactionId": transaction_id,
                "deadlineUtc": deadline.isoformat(),
                "createdAtUtc": now.isoformat(),
                "state": "FaultIntent",
                "faultActor": "operator",
                "recoveryMechanism": None,
                "initiatingPrincipalObjectId": None,
                "recoveredAtUtc": None,
            }
            state = dict(session.state)
            state["currentRun"] = run
            session.save(state)
            session.renew()
            try:
                self._change_status(queue, "SendDisabled")
            except RuntimeError as error:
                raise RuntimeError(
                    "Fault mutation outcome is ambiguous; no replay is allowed and the "
                    "deadline watchdog must reconcile the durable intent."
                ) from error
            verified = self._read_queue()
            if verified["properties"].get("status") != "SendDisabled":
                if verified["properties"].get("status") == "Active":
                    run["state"] = "FaultNotApplied"
                    run["completedAtUtc"] = datetime.now(UTC).isoformat()
                    state["currentRun"] = run
                    session.save(state)
                raise RuntimeError(
                    "Queue did not read back SendDisabled after the single fault attempt."
                )
            run["state"] = "Faulted"
            run["faultedAtUtc"] = datetime.now(UTC).isoformat()
            state["currentRun"] = run
            session.save(state)
            return {
                "status": "Faulted",
                "faultRunId": run_id,
                "transactionId": transaction_id,
                "deadlineUtc": deadline.isoformat(),
                "queueId": self.settings.queue_resource_id,
            }

    def restore(
        self,
        *,
        fault_run_id: str | None,
        now: datetime,
        watchdog: bool,
        initiating_principal_id: str | None = None,
    ) -> dict[str, Any]:
        try:
            expected_run_id = str(uuid.UUID(fault_run_id)) if fault_run_id else None
        except (ValueError, TypeError, AttributeError) as error:
            raise RequestError("faultRunId must be a GUID.") from error
        now = now.astimezone(UTC)
        with self._locked_state() as session:
            state = dict(session.state)
            run = state.get("currentRun")
            queue = self._read_queue()
            status = queue["properties"]["status"]
            if run is None:
                if watchdog and status == "Active":
                    return {"status": "NoExpiredFault", "faultRunId": None}
                raise RuntimeError("No durable fault run exists for this queue.")
            try:
                run_id = str(uuid.UUID(run.get("runId", "")))
            except (ValueError, TypeError, AttributeError) as error:
                raise RuntimeError("Coordination fault run ID is invalid.") from error
            if (
                run.get("environmentName") != self.settings.environment_name
                or str(run.get("queueResourceId", "")).lower()
                != self.settings.queue_resource_id.lower()
            ):
                raise RuntimeError("Fault run target differs from the fixed queue.")
            if expected_run_id is not None and expected_run_id != run_id:
                raise RequestError("The supplied run ID is not the active queue fault.")
            run_state = run.get("state")
            if run_state in {"Recovered", "FaultNotApplied"}:
                if status != "Active":
                    raise RuntimeError(
                        "Durable recovery marker conflicts with actual queue status."
                    )
                if expected_run_id == run_id or watchdog:
                    return {
                        "status": "AlreadyRecovered"
                        if run_state == "Recovered"
                        else "NoExpiredFault",
                        "faultRunId": run_id,
                        "recoveryMechanism": run.get("recoveryMechanism"),
                        "initiatingPrincipalObjectId": run.get(
                            "initiatingPrincipalObjectId"
                        ),
                    }
                raise RequestError("The supplied run ID is not the current fault.")
            deadline = _utc(run.get("deadlineUtc"))
            if watchdog and now < deadline:
                return {"status": "NoExpiredFault", "faultRunId": run_id}
            if not watchdog and now >= deadline:
                raise RequestError("The recovery request arrived at or after its deadline.")
            if status == "Active":
                if run_state == "FaultIntent":
                    run["state"] = "FaultNotApplied"
                    run["completedAtUtc"] = now.isoformat()
                    state["currentRun"] = run
                    session.save(state)
                    return {"status": "NoExpiredFault", "faultRunId": run_id}
                if run_state == "RecoveryIntent":
                    run["state"] = "Recovered"
                    run["recoveredAtUtc"] = now.isoformat()
                    state["currentRun"] = run
                    session.save(state)
                    return self._recovered_result(run, run_id)
                raise RuntimeError("Active queue conflicts with the durable fault state.")
            if status != "SendDisabled":
                raise RuntimeError("Queue status is not SendDisabled; refusing mutation.")
            if run_state == "FaultIntent" and not watchdog:
                raise RuntimeError("The fault is not confirmed; fixed recovery is not available.")
            if run_state == "RecoveryIntent" and not watchdog:
                return {"status": "RecoveryPending", "faultRunId": run_id}
            if run_state not in {"Faulted", "FaultIntent", "RecoveryIntent"}:
                raise RuntimeError("Durable fault state is not eligible for recovery.")
            actor = "deadline-watchdog" if watchdog else "sre-fixed-tool"
            if run_state != "RecoveryIntent" or run.get("recoveryMechanism") != actor:
                run["state"] = "RecoveryIntent"
                run["recoveryMechanism"] = actor
                run["initiatingPrincipalObjectId"] = (
                    None if watchdog else initiating_principal_id
                )
                run["recoveryIntentUtc"] = now.isoformat()
                state["currentRun"] = run
                session.save(state)
            elif not watchdog:
                return {"status": "RecoveryPending", "faultRunId": run_id}
            session.renew()
            try:
                self._change_status(queue, "Active")
            except RuntimeError as error:
                raise RuntimeError(
                    "Recovery mutation outcome is ambiguous; the watchdog will verify "
                    "the durable intent without claiming success."
                ) from error
            verified = self._read_queue()
            if verified["properties"].get("status") != "Active":
                raise RuntimeError("Queue recovery was not confirmed by ARM readback.")
            run["state"] = "Recovered"
            run["recoveredAtUtc"] = datetime.now(UTC).isoformat()
            state["currentRun"] = run
            session.save(state)
            return self._recovered_result(run, run_id)

    def _recovered_result(self, run: dict[str, Any], run_id: str) -> dict[str, Any]:
        return {
            "status": "Recovered",
            "faultRunId": run_id,
            "queueId": self.settings.queue_resource_id,
            "recoveryMechanism": run.get("recoveryMechanism"),
            "initiatingPrincipalObjectId": run.get("initiatingPrincipalObjectId"),
        }

    def record_watchdog_heartbeat(self, *, now: datetime) -> dict[str, Any]:
        now = now.astimezone(UTC)
        with self._locked_state() as session:
            queue = self._read_queue()
            status = queue["properties"]["status"]
            if status not in {"Active", "SendDisabled"}:
                raise RuntimeError("Watchdog refuses a queue in an unexpected state.")
            run = session.state.get("currentRun")
            if status == "Active" and run and run.get("state") in {
                "FaultIntent",
                "Faulted",
                "RecoveryIntent",
            }:
                raise RuntimeError("Active queue conflicts with an unresolved durable fault.")
            if status == "SendDisabled" and (
                not run or run.get("state") not in {"Faulted", "RecoveryIntent"}
            ):
                raise RuntimeError("A disabled queue has no confirmed durable fault state.")
            state = dict(session.state)
            state["watchdogHeartbeatUtc"] = now.isoformat()
            state["watchdogHeartbeatSuccess"] = True
            state["watchdogQueueStatus"] = status
            session.save(state)
            return {
                "status": "HeartbeatRecorded",
                "queueId": self.settings.queue_resource_id,
                "watchdogHeartbeatUtc": now.isoformat(),
                "queueStatus": status,
                "coordinationEtag": session.etag,
            }


def restore_for_request(
    control: QueueControl,
    *,
    fault_run_id: Any,
    now: datetime,
    initiating_principal_id: str,
) -> dict[str, Any]:
    if not isinstance(fault_run_id, str):
        raise RequestError("faultRunId must be a GUID.")
    return control.restore(
        fault_run_id=fault_run_id,
        now=now,
        watchdog=False,
        initiating_principal_id=initiating_principal_id,
    )


def restore_if_expired(control: QueueControl, *, now: datetime) -> dict[str, Any]:
    return control.restore(fault_run_id=None, now=now, watchdog=True)
