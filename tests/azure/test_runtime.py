from contextlib import contextmanager
from dataclasses import replace
from unittest.mock import MagicMock, Mock

import httpx
import pytest
from retailtx import runtime
from retailtx.settings import Settings


@pytest.fixture
def local_settings():
    return Settings("cap-local", "erp-local", "http://erp:8000", "http://cap:8000", "servicebus")


@pytest.mark.parametrize("command", ["doctor", "drain"])
@pytest.mark.parametrize("identity_kind", ["vm", "arc"])
def test_azure_full_readiness_rejects_before_any_io(settings, monkeypatch, command, identity_kind):
    settings = replace(settings, identity_kind=identity_kind, _cap_dsn=None)
    http, database, bus, emit = Mock(), Mock(), Mock(), Mock()
    monkeypatch.setattr(runtime, "client", http)
    monkeypatch.setattr(runtime, "connect", database)
    monkeypatch.setattr(runtime.broker, "client", bus)
    monkeypatch.setattr(runtime, "event", emit)
    with pytest.raises(ValueError, match="Invoke-Azure.ps1.*operator-authorized DLQ"):
        getattr(runtime, command)(settings)
    for dependency in (http, database, bus, emit):
        dependency.assert_not_called()


@pytest.mark.parametrize("command", ["doctor", "drain", "dead-letters"])
def test_cloud_cli_rejects_before_telemetry_or_broker(settings, monkeypatch, command):
    configure, bus = Mock(), Mock()
    monkeypatch.setattr(runtime.Settings, "from_env", lambda: settings)
    monkeypatch.setattr(runtime, "configure", configure)
    monkeypatch.setattr(runtime.broker, "client", bus)
    monkeypatch.setattr("sys.argv", ["runtime", command])
    with pytest.raises(ValueError, match="Invoke-Azure.ps1"):
        runtime.main()
    configure.assert_not_called()
    bus.assert_not_called()


def test_dc_identity_retains_explicit_dead_letter_inspection(settings):
    runtime.validate_command("dead-letters", replace(settings, identity_kind="arc"))


def doctor_dependencies(monkeypatch, worker):
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json=worker if request.url.path == "/worker" else {})

    @contextmanager
    def client(settings, url):
        with httpx.Client(base_url=url, transport=httpx.MockTransport(handler)) as http:
            yield http

    monkeypatch.setattr(runtime, "client", client)
    database = MagicMock()
    database.__enter__.return_value.execute.return_value.fetchone.return_value = {"count": 0}
    monkeypatch.setattr(runtime, "connect", Mock(return_value=database))
    bus = MagicMock()
    receiver = bus.__enter__.return_value.get_queue_receiver.return_value.__enter__.return_value
    receiver.peek_messages.return_value = []
    monkeypatch.setattr(runtime.broker, "client", Mock(return_value=bus))
    monkeypatch.setattr(runtime, "status", Mock(return_value={"status": "fresh"}))
    local_status = Mock(return_value=worker)
    monkeypatch.setattr(runtime.fault, "worker_status", local_status)
    return requests, receiver


def test_local_doctor_still_checks_dead_letters(local_settings, monkeypatch):
    requests, receiver = doctor_dependencies(
        monkeypatch, {"alive": True, "paused": False, "worker_state": "running"}
    )
    assert runtime.doctor(local_settings)
    receiver.peek_messages.assert_called_once_with(max_message_count=1, timeout=5)
    assert len(requests) == 2
    assert all(request.url.path == "/health" for request in requests)
    receiver.peek_messages.return_value = [object()]
    assert not runtime.doctor(local_settings)


@pytest.mark.parametrize(
    "worker",
    [
        {"alive": False, "paused": False, "worker_state": "running"},
        {"alive": None, "paused": False, "worker_state": None},
        {"alive": True, "paused": True, "worker_state": "paused"},
    ],
)
def test_local_doctor_rejects_unhealthy_worker(local_settings, monkeypatch, worker):
    doctor_dependencies(monkeypatch, worker)
    assert not runtime.doctor(local_settings)


@pytest.mark.parametrize("healthy", [True, False])
def test_local_drain_requires_full_local_doctor(local_settings, monkeypatch, healthy):
    doctor_dependencies(monkeypatch, {"alive": True, "paused": False, "worker_state": "running"})
    doctor = Mock(return_value=healthy)
    emit = Mock()
    monkeypatch.setattr(runtime, "doctor", doctor)
    monkeypatch.setattr(runtime, "event", emit)
    monkeypatch.setattr(
        runtime,
        "reconcile",
        Mock(return_value={"status": "fresh", "current": {"unposted_count": 0}}),
    )
    monkeypatch.setattr(runtime, "monotonic", Mock(side_effect=[0, 1, 121]))
    monkeypatch.setattr(runtime, "sleep", Mock())
    if healthy:
        runtime.drain(local_settings)
        emit.assert_called_once_with("recovery.verified", unposted_cents=0)
    else:
        with pytest.raises(RuntimeError, match="Backlog did not drain"):
            runtime.drain(local_settings)
        emit.assert_not_called()
    doctor.assert_called_once_with(local_settings)
