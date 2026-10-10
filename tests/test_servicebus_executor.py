from __future__ import annotations

import base64
import copy
import importlib
import json
import sys
import threading
import types
import uuid
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

from scripts.servicebus.executor.coordination import (
    BlobCoordinationStore,
    BlobLeaseSession,
    CoordinationError,
    LEASE_SECONDS,
)
from scripts.servicebus.executor.executor_core import (
    AuthorizationError,
    QueueControl,
    RequestError,
    Settings,
    decode_principal,
    restore_for_request,
    restore_if_expired,
)

TENANT_ID = "11111111-1111-4111-8111-111111111111"
SRE_CLIENT_APP_ID = "22222222-2222-4222-8222-222222222222"
SRE_OBJECT_ID = "33333333-3333-4333-8333-333333333333"
OWNER_TOKEN = "55555555-5555-4555-8555-555555555555"
FAULT_RUN_ID = "66666666-6666-4666-8666-666666666666"
TRANSACTION_ID = "77777777-7777-4777-8777-777777777777"
QUEUE_ID = (
    "/subscriptions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/resourceGroups/"
    "rg-retailtx-servicebus-demo01-swedencentral/providers/Microsoft.ServiceBus/"
    "namespaces/sbtxexample/queues/recovery-demo01"
)
AUDIENCE = "api://88888888-8888-4888-8888-888888888888"
ROLE = "ServiceBus.QueueRestore"
NOW = datetime(2030, 1, 1, tzinfo=UTC)


def _settings(**overrides: str) -> Settings:
    values = {
        "queue_resource_id": QUEUE_ID,
        "sre_tenant_id": TENANT_ID,
        "executor_audience": AUDIENCE,
        "sre_client_app_id": SRE_CLIENT_APP_ID,
        "sre_principal_object_id": SRE_OBJECT_ID,
        "sre_required_role": ROLE,
        "owner_token": OWNER_TOKEN,
        "environment_name": "demo01",
        "storage_account_name": "stsbexample",
        "coordination_container": "scenario-coordination",
        "coordination_blob_name": "scenario-state.json",
    }
    values.update(overrides)
    return Settings(**values)


def _principal(
    *,
    tenant_id: str = TENANT_ID,
    audience: str = AUDIENCE,
    client_app_id: str = SRE_CLIENT_APP_ID,
    object_id: str = SRE_OBJECT_ID,
    roles: list[str] | None = None,
) -> str:
    claims = [
        {"typ": "tid", "val": tenant_id},
        {"typ": "aud", "val": audience},
        {"typ": "appid", "val": client_app_id},
        {"typ": "oid", "val": object_id},
    ]
    claims.extend({"typ": "roles", "val": role} for role in ([ROLE] if roles is None else roles))
    return base64.b64encode(json.dumps({"claims": claims}).encode()).decode()


def _coordination_state() -> dict[str, Any]:
    return {
        "contract": "retailtx-servicebus-coordination-v1",
        "stateVersion": 1,
        "ownerToken": OWNER_TOKEN,
        "environmentName": "demo01",
        "queueResourceId": QUEUE_ID,
        "currentRun": None,
        "watchdogHeartbeatUtc": None,
        "watchdogHeartbeatSuccess": False,
    }


class MemorySession:
    def __init__(self, store: MemoryCoordinationStore) -> None:
        self.store = store
        self.state = copy.deepcopy(store.state)
        self.etag = store.etag
        self.renewals = 0

    def renew(self) -> None:
        self.renewals += 1

    def save(self, state: dict[str, Any]) -> None:
        if self.etag != self.store.etag:
            raise CoordinationError("Stale coordination ETag.")
        self.store.state = copy.deepcopy(state)
        self.store.version += 1
        self.store.etag = f'"coord-etag-{self.store.version}"'
        self.state = copy.deepcopy(state)
        self.etag = self.store.etag
        self.store.events.append(("save", copy.deepcopy(state)))


class MemoryCoordinationStore:
    def __init__(self, state: dict[str, Any] | None = None) -> None:
        self.state = copy.deepcopy(state or _coordination_state())
        self.version = 1
        self.etag = f'"coord-etag-{self.version}"'
        self.events: list[tuple[str, Any]] = []
        self.lock = threading.Lock()

    def initialize(self, initial_state: dict[str, Any]) -> dict[str, Any]:
        if self.state is None:
            self.state = copy.deepcopy(initial_state)
        return copy.deepcopy(self.state)

    @contextmanager
    def locked(self) -> Any:
        self.lock.acquire()
        session = MemorySession(self)
        self.events.append(("lease-acquired", self.etag))
        try:
            yield session
        finally:
            self.events.append(("lease-released", self.etag))
            self.lock.release()


def _queue(status: str = "Active") -> dict[str, Any]:
    return {
        "id": QUEUE_ID,
        "name": "recovery-demo01",
        "location": "swedencentral",
        "properties": {
            "status": status,
            "lockDuration": "PT30S",
            "maxDeliveryCount": 5,
            "requiresDuplicateDetection": True,
        },
    }


class FakeQueue:
    def __init__(self, queue: dict[str, Any]) -> None:
        self.current = copy.deepcopy(queue)
        self.puts: list[dict[str, Any]] = []
        self.before_put: Any = None

    def get_queue(self) -> dict[str, Any]:
        return copy.deepcopy(self.current)

    def put_queue(self, queue: dict[str, Any]) -> dict[str, Any]:
        self.puts.append(copy.deepcopy(queue))
        if self.before_put:
            self.before_put(queue)
        self.current["properties"] = copy.deepcopy(queue["properties"])
        return copy.deepcopy(self.current)


def _control(
    *,
    status: str = "Active",
    store: MemoryCoordinationStore | None = None,
    transport: FakeQueue | None = None,
) -> tuple[QueueControl, FakeQueue, MemoryCoordinationStore]:
    state_store = store or MemoryCoordinationStore()
    queue_transport = transport or FakeQueue(_queue(status))
    control = QueueControl(_settings(), object(), queue_transport, state_store)
    return control, queue_transport, state_store


def _start_fault(control: QueueControl, deadline: datetime = NOW + timedelta(minutes=5)) -> None:
    control.start_fault(
        transaction_id=TRANSACTION_ID,
        fault_run_id=FAULT_RUN_ID,
        deadline=deadline,
        now=NOW,
    )


def _restore(control: QueueControl, now: datetime = NOW) -> dict[str, Any]:
    return restore_for_request(
        control,
        fault_run_id=FAULT_RUN_ID,
        now=now,
        initiating_principal_id=SRE_OBJECT_ID,
    )


@pytest.mark.parametrize(
    ("claim", "expected"),
    [
        ("tenant_id", "99999999-9999-4999-8999-999999999999"),
        ("audience", "https://management.azure.com/"),
        ("client_app_id", "99999999-9999-4999-8999-999999999999"),
        ("object_id", "99999999-9999-4999-8999-999999999999"),
    ],
)
def test_rejects_wrong_tenant_audience_client_or_object(claim: str, expected: str) -> None:
    values = {
        "tenant_id": TENANT_ID,
        "audience": AUDIENCE,
        "client_app_id": SRE_CLIENT_APP_ID,
        "object_id": SRE_OBJECT_ID,
    }
    values[claim] = expected
    with pytest.raises(AuthorizationError):
        decode_principal(
            _principal(**values),
            tenant_id=TENANT_ID,
            audience=AUDIENCE,
            client_app_id=SRE_CLIENT_APP_ID,
            object_id=SRE_OBJECT_ID,
            required_role=ROLE,
        )


def test_rejects_missing_wrong_and_ambiguous_roles() -> None:
    for roles in ([], ["Other.Role"], [ROLE, ROLE]):
        with pytest.raises(AuthorizationError):
            decode_principal(
                _principal(roles=roles),
                tenant_id=TENANT_ID,
                audience=AUDIENCE,
                client_app_id=SRE_CLIENT_APP_ID,
                object_id=SRE_OBJECT_ID,
                required_role=ROLE,
            )


def test_rejects_malformed_and_ambiguous_principal_claims() -> None:
    with pytest.raises(AuthorizationError):
        decode_principal("not-base64", tenant_id=TENANT_ID)
    duplicate_claims = [
        {"typ": "tid", "val": TENANT_ID},
        {"typ": "tid", "val": TENANT_ID},
    ]
    encoded = base64.b64encode(json.dumps({"claims": duplicate_claims}).encode()).decode()
    with pytest.raises(AuthorizationError):
        decode_principal(encoded, tenant_id=TENANT_ID)


def test_initialization_and_first_watchdog_heartbeat_work_without_queue_metadata() -> None:
    control, transport, store = _control()
    result = control.initialize_state()
    assert result == {"initialized": True, "queueId": QUEUE_ID}
    assert "etag" not in transport.current
    assert "userMetadata" not in transport.current["properties"]

    assert restore_if_expired(control, now=NOW) == {
        "status": "NoExpiredFault",
        "faultRunId": None,
    }
    heartbeat = control.record_watchdog_heartbeat(now=NOW)
    assert heartbeat["status"] == "HeartbeatRecorded"
    assert store.state["watchdogHeartbeatSuccess"] is True
    assert store.state["watchdogQueueStatus"] == "Active"
    assert store.state["watchdogHeartbeatUtc"] == NOW.isoformat()
    assert transport.puts == []


def test_fault_records_durable_intent_before_single_status_mutation() -> None:
    control, transport, store = _control()
    result = control.start_fault(
        transaction_id=TRANSACTION_ID,
        fault_run_id=FAULT_RUN_ID,
        deadline=NOW + timedelta(minutes=5),
        now=NOW,
    )
    assert result["status"] == "Faulted"
    assert len(transport.puts) == 1
    assert transport.puts[0]["properties"]["status"] == "SendDisabled"
    assert transport.puts[0]["properties"]["lockDuration"] == "PT30S"
    assert "etag" not in transport.current
    assert "userMetadata" not in transport.current["properties"]
    saved_states = [event[1] for event in store.events if event[0] == "save"]
    assert saved_states[0]["currentRun"]["state"] == "FaultIntent"
    assert saved_states[-1]["currentRun"]["state"] == "Faulted"


def test_fault_rejects_existing_foreign_owner_or_unresolved_run() -> None:
    store = MemoryCoordinationStore()
    store.state["ownerToken"] = "99999999-9999-4999-8999-999999999999"
    control, transport, _ = _control(store=store)
    with pytest.raises(RuntimeError, match="owner"):
        control.start_fault(
            transaction_id=TRANSACTION_ID,
            fault_run_id=FAULT_RUN_ID,
            deadline=NOW + timedelta(minutes=5),
            now=NOW,
        )
    assert transport.puts == []

    control, transport, store = _control()
    store.state["currentRun"] = {
        "contract": "retailtx-servicebus-fault-v1",
        "ownerToken": OWNER_TOKEN,
        "state": "FaultIntent",
    }
    with pytest.raises(RuntimeError, match="unresolved"):
        control.start_fault(
            transaction_id=TRANSACTION_ID,
            fault_run_id=FAULT_RUN_ID,
            deadline=NOW + timedelta(minutes=5),
            now=NOW,
        )
    assert transport.puts == []


def test_blob_updates_use_real_lease_id_and_etag_condition(monkeypatch: pytest.MonkeyPatch) -> None:
    match_conditions = types.SimpleNamespace(IfNotModified=object())
    monkeypatch.setitem(
        sys.modules,
        "azure.core",
        types.SimpleNamespace(MatchConditions=match_conditions),
    )

    class Lease:
        id = "lease-id"

        def renew(self) -> None:
            pass

    class Properties:
        etag = '"coord-etag-2"'

    class Blob:
        def __init__(self) -> None:
            self.upload_arguments: dict[str, Any] = {}

        def upload_blob(self, payload: str, **kwargs: Any) -> None:
            self.upload_arguments = kwargs | {"payload": payload}

        def get_blob_properties(self, **kwargs: Any) -> Properties:
            assert kwargs["lease"] == "lease-id"
            return Properties()

    blob = Blob()
    session = BlobLeaseSession(blob, Lease(), {"count": 1}, '"coord-etag-1"')
    session.save({"count": 2})
    assert blob.upload_arguments["lease"] == "lease-id"
    assert blob.upload_arguments["etag"] == '"coord-etag-1"'
    assert blob.upload_arguments["match_condition"] is match_conditions.IfNotModified
    assert session.etag == '"coord-etag-2"'


def test_blob_state_reads_and_writes_under_a_finite_actual_lease() -> None:
    class Lease:
        id = "lease-id"
        released = False

        def renew(self) -> None:
            pass

        def release(self) -> None:
            self.released = True

    class Properties:
        etag = '"blob-etag-1"'

    class Downloader:
        @staticmethod
        def readall() -> bytes:
            return json.dumps(_coordination_state()).encode()

    class Blob:
        lease: Lease | None = None

        def acquire_lease(self, *, lease_duration: int, timeout: int) -> Lease:
            assert lease_duration == LEASE_SECONDS
            assert 15 <= lease_duration <= 60
            assert timeout == 10
            self.lease = Lease()
            return self.lease

        def download_blob(self, *, lease: str, timeout: int) -> Downloader:
            assert lease == "lease-id"
            assert timeout == 10
            return Downloader()

        def get_blob_properties(self, *, lease: str, timeout: int) -> Properties:
            assert lease == "lease-id"
            assert timeout == 10
            return Properties()

    blob = Blob()
    store = BlobCoordinationStore(blob)
    with store.locked() as session:
        assert session.state["ownerToken"] == OWNER_TOKEN
        assert session.etag == '"blob-etag-1"'
    assert blob.lease is not None and blob.lease.released


def test_coordination_etag_conflict_fails_before_queue_mutation() -> None:
    class ConflictingSession(MemorySession):
        def save(self, state: dict[str, Any]) -> None:
            raise CoordinationError("Blob ETag precondition failed.")

    class ConflictingStore(MemoryCoordinationStore):
        @contextmanager
        def locked(self) -> Any:
            yield ConflictingSession(self)

    store = ConflictingStore()
    control, transport, _ = _control(store=store)
    with pytest.raises(RuntimeError, match="coordination lease/state"):
        control.start_fault(
            transaction_id=TRANSACTION_ID,
            fault_run_id=FAULT_RUN_ID,
            deadline=NOW + timedelta(minutes=5),
            now=NOW,
        )
    assert transport.puts == []


def test_sre_restores_only_exact_fault_run_and_persists_actor() -> None:
    control, transport, store = _control()
    _start_fault(control)
    result = _restore(control)

    assert result == {
        "status": "Recovered",
        "faultRunId": FAULT_RUN_ID,
        "queueId": QUEUE_ID,
        "recoveryMechanism": "sre-fixed-tool",
        "initiatingPrincipalObjectId": SRE_OBJECT_ID,
    }
    assert len(transport.puts) == 2
    assert transport.puts[-1]["properties"]["status"] == "Active"
    run = store.state["currentRun"]
    assert run["state"] == "Recovered"
    assert run["recoveryMechanism"] == "sre-fixed-tool"
    assert run["initiatingPrincipalObjectId"] == SRE_OBJECT_ID
    assert "userMetadata" not in transport.current["properties"]


def test_repeated_restore_is_idempotent_only_for_exact_run() -> None:
    control, transport, _ = _control()
    _start_fault(control)
    assert _restore(control)["status"] == "Recovered"
    already = _restore(control)
    assert already["status"] == "AlreadyRecovered"
    with pytest.raises(RequestError):
        restore_for_request(
            control,
            fault_run_id=str(uuid.uuid4()),
            now=NOW,
            initiating_principal_id=SRE_OBJECT_ID,
        )
    assert len(transport.puts) == 2


def test_recovered_state_requires_actual_active_queue() -> None:
    control, transport, _ = _control()
    _start_fault(control)
    _restore(control)
    transport.current["properties"]["status"] = "SendDisabled"
    with pytest.raises(RuntimeError, match="conflicts"):
        _restore(control)


def test_watchdog_waits_until_deadline_then_recovers_the_exact_run() -> None:
    control, transport, _ = _control()
    deadline = NOW + timedelta(minutes=5)
    _start_fault(control, deadline)
    assert restore_if_expired(control, now=NOW + timedelta(minutes=4))["status"] == (
        "NoExpiredFault"
    )
    result = restore_if_expired(control, now=deadline)
    assert result["status"] == "Recovered"
    assert result["recoveryMechanism"] == "deadline-watchdog"
    assert result["initiatingPrincipalObjectId"] is None
    assert transport.current["properties"]["status"] == "Active"


def test_ambiguous_fault_is_never_replayed_and_watchdog_reconciles_intent() -> None:
    control, transport, store = _control()
    original_put = transport.put_queue
    failed_once = False

    def mutate_then_timeout(queue: dict[str, Any]) -> dict[str, Any]:
        nonlocal failed_once
        if queue["properties"]["status"] == "SendDisabled" and not failed_once:
            failed_once = True
            original_put(queue)
            raise RuntimeError("simulated ambiguous response")
        return original_put(queue)

    transport.put_queue = mutate_then_timeout  # type: ignore[method-assign]
    deadline = NOW + timedelta(minutes=5)
    with pytest.raises(RuntimeError, match="ambiguous"):
        control.start_fault(
            transaction_id=TRANSACTION_ID,
            fault_run_id=FAULT_RUN_ID,
            deadline=deadline,
            now=NOW,
        )
    assert store.state["currentRun"]["state"] == "FaultIntent"
    assert restore_if_expired(control, now=deadline - timedelta(seconds=1))[
        "status"
    ] == "NoExpiredFault"
    assert len(transport.puts) == 1
    result = restore_if_expired(control, now=deadline)
    assert result["status"] == "Recovered"
    assert len(transport.puts) == 2
    assert store.state["currentRun"]["recoveryMechanism"] == "deadline-watchdog"


def test_ambiguous_sre_recovery_is_not_replayed_and_readback_is_reconciled() -> None:
    control, transport, store = _control()
    _start_fault(control)
    original_put = transport.put_queue
    failed_once = False

    def mutate_then_timeout(queue: dict[str, Any]) -> dict[str, Any]:
        nonlocal failed_once
        if queue["properties"]["status"] == "Active" and not failed_once:
            failed_once = True
            original_put(queue)
            raise RuntimeError("simulated ambiguous response")
        return original_put(queue)

    transport.put_queue = mutate_then_timeout  # type: ignore[method-assign]
    with pytest.raises(RuntimeError, match="ambiguous"):
        _restore(control)
    assert len(transport.puts) == 2
    assert store.state["currentRun"]["state"] == "RecoveryIntent"
    result = _restore(control)
    assert result["status"] == "Recovered"
    assert len(transport.puts) == 2
    assert store.state["currentRun"]["initiatingPrincipalObjectId"] == SRE_OBJECT_ID


def test_watchdog_takes_over_unconfirmed_sre_intent_only_after_deadline() -> None:
    control, transport, store = _control()
    deadline = NOW + timedelta(minutes=5)
    _start_fault(control, deadline)
    run = store.state["currentRun"]
    run["state"] = "RecoveryIntent"
    run["recoveryMechanism"] = "sre-fixed-tool"
    run["initiatingPrincipalObjectId"] = SRE_OBJECT_ID
    store.state["currentRun"] = run

    before = restore_if_expired(control, now=deadline - timedelta(seconds=1))
    assert before["status"] == "NoExpiredFault"
    assert len(transport.puts) == 1
    after = restore_if_expired(control, now=deadline)
    assert after["status"] == "Recovered"
    assert len(transport.puts) == 2
    assert store.state["currentRun"]["recoveryMechanism"] == "deadline-watchdog"
    assert store.state["currentRun"]["initiatingPrincipalObjectId"] is None


def test_watchdog_records_fresh_success_heartbeat_only_after_readback() -> None:
    control, transport, store = _control()
    control.initialize_state()
    result = control.record_watchdog_heartbeat(now=NOW)
    assert result["status"] == "HeartbeatRecorded"
    assert result["coordinationEtag"] == store.etag
    assert store.state["watchdogHeartbeatSuccess"] is True
    assert transport.puts == []


def test_first_watchdog_timer_execution_succeeds_with_active_unmarked_queue(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    executor_directory = str(
        Path(__file__).resolve().parents[1] / "scripts" / "servicebus" / "executor"
    )
    if executor_directory not in sys.path:
        sys.path.insert(0, executor_directory)
    azure_module = types.ModuleType("azure")
    azure_module.__path__ = []
    functions_module = types.ModuleType("azure.functions")

    class StubFunctionApp:
        def __init__(self, **_kwargs: Any) -> None:
            pass

        @staticmethod
        def route(**_kwargs: Any) -> Any:
            return lambda function: function

        @staticmethod
        def timer_trigger(**_kwargs: Any) -> Any:
            return lambda function: function

    functions_module.FunctionApp = StubFunctionApp
    functions_module.AuthLevel = types.SimpleNamespace(ANONYMOUS="anonymous")
    functions_module.HttpRequest = type("HttpRequest", (), {})
    functions_module.HttpResponse = type("HttpResponse", (), {})
    functions_module.TimerRequest = type("TimerRequest", (), {})
    identity_module = types.ModuleType("azure.identity")
    identity_module.ManagedIdentityCredential = type("ManagedIdentityCredential", (), {})
    monkeypatch.setitem(sys.modules, "azure", azure_module)
    monkeypatch.setitem(sys.modules, "azure.functions", functions_module)
    monkeypatch.setitem(sys.modules, "azure.identity", identity_module)
    function_app = importlib.import_module("function_app")
    control, transport, store = _control()
    control.initialize_state()
    monkeypatch.setattr(function_app, "_queue_control", lambda: control)

    function_app.watchdog(None)

    assert transport.puts == []
    assert store.state["watchdogHeartbeatSuccess"] is True
    assert store.state["watchdogHeartbeatUtc"]


def test_provider_metadata_is_not_used_and_unknown_queue_status_fails_closed() -> None:
    queue = _queue()
    control, transport, _ = _control(transport=FakeQueue(queue))
    assert control.snapshot()["queue"]["id"] == QUEUE_ID
    assert transport.puts == []

    queue = _queue("Unknown")
    control, transport, _ = _control(transport=FakeQueue(queue))
    with pytest.raises(RuntimeError, match="unexpected state"):
        control.record_watchdog_heartbeat(now=NOW)
    assert transport.puts == []


def test_wrong_coordination_owner_and_queue_are_rejected() -> None:
    for key, value in (
        ("ownerToken", "99999999-9999-4999-8999-999999999999"),
        ("queueResourceId", QUEUE_ID + "-foreign"),
        ("environmentName", "other01"),
    ):
        store = MemoryCoordinationStore()
        store.state[key] = value
        control, transport, _ = _control(store=store)
        with pytest.raises(RuntimeError, match="Coordination blob"):
            control.snapshot()
        assert transport.puts == []


def test_restore_rejects_wrong_run_and_expired_sre_request_without_mutation() -> None:
    control, transport, _ = _control()
    _start_fault(control)
    with pytest.raises(RequestError, match="run ID"):
        restore_for_request(
            control,
            fault_run_id=str(uuid.uuid4()),
            now=NOW,
            initiating_principal_id=SRE_OBJECT_ID,
        )
    with pytest.raises(RequestError, match="deadline"):
        _restore(control, NOW + timedelta(minutes=5))
    assert len(transport.puts) == 1
