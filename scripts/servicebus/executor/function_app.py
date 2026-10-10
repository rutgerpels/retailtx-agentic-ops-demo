"""Private fixed-action Service Bus queue executor and independent watchdog."""

from __future__ import annotations

import json
import logging
import os
from datetime import UTC, datetime

import azure.functions as func
from azure.identity import ManagedIdentityCredential
from executor_core import (
    AuthorizationError,
    QueueControl,
    RequestError,
    configuration,
    decode_principal,
    restore_for_request,
    restore_if_expired,
)

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
logger = logging.getLogger("retailtx.servicebus.executor")
_credential: ManagedIdentityCredential | None = None


def _queue_control() -> QueueControl:
    global _credential
    settings = configuration()
    if _credential is None:
        _credential = ManagedIdentityCredential()
    return QueueControl(settings=settings, credential=_credential)


@app.route(route="restore", methods=["POST"])
def restore(req: func.HttpRequest) -> func.HttpResponse:
    try:
        settings = configuration()
        principal = decode_principal(
            req.headers.get("x-ms-client-principal", ""),
            tenant_id=settings.sre_tenant_id,
            audience=settings.executor_audience,
            client_app_id=settings.sre_client_app_id,
            object_id=settings.sre_principal_object_id,
            required_role=settings.sre_required_role,
        )
        payload = req.get_json()
        if not isinstance(payload, dict) or set(payload) != {"faultRunId"}:
            raise RequestError("The request must contain only faultRunId.")
        result = restore_for_request(
            _queue_control(),
            fault_run_id=payload["faultRunId"],
            now=datetime.now(UTC),
            initiating_principal_id=principal["object_id"],
        )
        return func.HttpResponse(
            json.dumps(result, sort_keys=True),
            status_code=200,
            mimetype="application/json",
        )
    except AuthorizationError:
        return func.HttpResponse("Unauthorized", status_code=401)
    except RequestError as error:
        return func.HttpResponse(str(error), status_code=400)
    except (ValueError, RuntimeError) as error:
        return func.HttpResponse(str(error), status_code=409)
    except Exception:
        logger.exception("Fixed Service Bus recovery failed.")
        return func.HttpResponse("Recovery was not confirmed.", status_code=502)


@app.timer_trigger(
    arg_name="timer",
    schedule=os.environ.get("WATCHDOG_SCHEDULE", "0 */1 * * * *"),
    run_on_startup=False,
    use_monitor=True,
)
def watchdog(timer: func.TimerRequest) -> None:
    del timer
    control = _queue_control()
    try:
        now = datetime.now(UTC)
        result = restore_if_expired(control, now=now)
        heartbeat = control.record_watchdog_heartbeat(now=datetime.now(UTC))
    except Exception:
        logger.exception("Service Bus deadline watchdog failed.")
        raise
    if result["status"] != "NoExpiredFault" or heartbeat["status"] != "HeartbeatRecorded":
        logger.warning(
            "Service Bus watchdog result: status=%s runId=%s heartbeat=%s",
            result["status"],
            result.get("faultRunId"),
            heartbeat["watchdogHeartbeatUtc"],
        )
