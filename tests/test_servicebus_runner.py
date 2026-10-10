from __future__ import annotations

import json
import os
import shutil
import uuid
from contextlib import nullcontext
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest

from scripts.servicebus import runner


@pytest.fixture
def runner_paths(monkeypatch: pytest.MonkeyPatch) -> Path:
    test_root = Path(__file__).parent / f".servicebus-runner-tests-{uuid.uuid4().hex}"
    app_root = test_root / "opt"
    state_root = test_root / "state"
    function_root = app_root / "function-app"
    function_root.mkdir(parents=True)
    state_root.mkdir()
    monkeypatch.setattr(runner, "ROOT", app_root)
    monkeypatch.setattr(runner, "STATE_ROOT", state_root)
    monkeypatch.setattr(runner, "MANIFEST_PATH", state_root / "owner.json")
    monkeypatch.setattr(runner, "PUBLISH_PATH", state_root / "publish-state.json")
    monkeypatch.setattr(runner, "DATABASE_PATH", state_root / "servicebus.sqlite")
    monkeypatch.setattr(runner.os, "geteuid", lambda: 0, raising=False)
    monkeypatch.setattr(runner, "_runner_lock", lambda: nullcontext())
    try:
        yield test_root
    finally:
        shutil.rmtree(test_root, ignore_errors=True)


def request(action: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "ownerToken": "12345678-1234-1234-1234-123456789abc",
        "bundleSha256": "a" * 64,
        "action": action,
        "arguments": arguments or {},
    }


def write_sources(root: Path) -> tuple[str, str]:
    (root / "runner.py").write_text("runner source\n", encoding="utf-8")
    (root / "probe.py").write_text("probe source\n", encoding="utf-8")
    function_root = root / "function-app"
    for name in runner.FUNCTION_FILES:
        (function_root / name).write_text(f"{name}\n", encoding="utf-8")
    return (
        runner._canonical_source_digest(root, ("probe.py", "runner.py")),
        runner._canonical_source_digest(function_root, runner.FUNCTION_FILES),
    )


def save_manifest(root: Path) -> dict[str, Any]:
    source_digest, function_digest = write_sources(root)
    manifest = {
        "schemaVersion": 1,
        "ownerToken": "12345678-1234-1234-1234-123456789abc",
        "bundleSha256": "a" * 64,
        "bundleSourceSha256": source_digest,
        "runnerFiles": ["probe.py", "runner.py"],
        "functionSourceSha256": function_digest,
        "namespace": None,
        "queueName": None,
        "queueResourceId": None,
        "functionApps": [],
    }
    runner._write_json(runner.MANIFEST_PATH, manifest)
    return manifest


def configured_manifest() -> dict[str, Any]:
    return {
        "namespace": "sbtxabc123.servicebus.windows.net",
        "queueName": "recovery-demo01",
        "queueResourceId": (
            "/subscriptions/12345678-1234-1234-1234-123456789abc/"
            "resourceGroups/rg-retailtx-servicebus-demo01-swedencentral/"
            "providers/Microsoft.ServiceBus/namespaces/sbtxabc123/queues/recovery-demo01"
        ),
        "functionApps": [
            "func-sb-exec-demo01-abc123",
            "func-sb-watch-demo01-abc123",
        ],
        "environmentName": "demo01",
        "coordinationStorageAccount": "stsbexample",
        "coordinationContainer": "scenario-coordination",
        "coordinationBlobName": "scenario-state.json",
    }


def test_runner_request_rejects_unknown_fields_and_arbitrary_commands() -> None:
    bad_fields = request("probe", {"operation": "health", "command": "id"})
    with pytest.raises(ValueError, match="unsupported fields"):
        runner._probe({}, bad_fields["arguments"])
    with pytest.raises(ValueError, match="allow-list"):
        runner._validate_request(request("shell", {"command": "id"}))
    with pytest.raises(ValueError, match="fixed protocol"):
        runner._validate_request(request("health") | {"timeout": 60})


def test_runner_configuration_binds_exact_owned_queue_and_apps(runner_paths: Path) -> None:
    manifest = save_manifest(runner_paths / "opt")
    result = runner._configure(manifest, configured_manifest())
    assert result["configured"] is True
    saved = json.loads(runner.MANIFEST_PATH.read_text(encoding="utf-8"))
    assert saved["queueResourceId"] == configured_manifest()["queueResourceId"]
    assert saved["functionApps"] == configured_manifest()["functionApps"]
    assert saved["coordinationStorageAccount"] == "stsbexample"
    assert saved["coordinationContainer"] == "scenario-coordination"
    if os.name != "nt":
        assert runner.MANIFEST_PATH.stat().st_mode & 0o077 == 0

    altered = configured_manifest()
    altered["queueName"] = "foreign-queue"
    with pytest.raises(ValueError, match="does not match"):
        runner._configure(saved, altered)


def test_runner_state_and_fault_actions_use_only_the_fixed_control_contract(
    runner_paths: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = save_manifest(runner_paths / "opt") | configured_manifest()

    class Control:
        def __init__(self) -> None:
            self.fault_arguments: dict[str, Any] | None = None

        def snapshot(self) -> dict[str, Any]:
            return {
                "queue": {"id": manifest["queueResourceId"], "properties": {"status": "Active"}},
                "coordination": {"ownerToken": manifest["ownerToken"]},
                "coordinationEtag": '"blob-etag-1"',
            }

        def initialize_state(self) -> dict[str, Any]:
            return {"initialized": True, "queueId": manifest["queueResourceId"]}

        def start_fault(self, **arguments: Any) -> dict[str, Any]:
            self.fault_arguments = arguments
            return {"status": "Faulted", "faultRunId": arguments["fault_run_id"]}

    control = Control()
    monkeypatch.setattr(runner, "_queue_control", lambda _: control)

    state = runner._coordination_action(manifest, "state", {})
    assert state["queue"]["properties"]["status"] == "Active"
    assert state["coordinationEtag"] == '"blob-etag-1"'
    assert runner._coordination_action(manifest, "initialize", {})["initialized"]
    with pytest.raises(ValueError, match="does not accept arguments"):
        runner._coordination_action(manifest, "state", {"queueId": "foreign"})

    deadline = (datetime.now(UTC) + timedelta(minutes=5)).isoformat()
    fault = runner._coordination_action(
        manifest,
        "fault",
        {
            "transactionId": "11111111-1111-4111-8111-111111111111",
            "faultRunId": "22222222-2222-4222-8222-222222222222",
            "deadlineUtc": deadline,
        },
    )
    assert fault["status"] == "Faulted"
    assert control.fault_arguments is not None
    assert control.fault_arguments["transaction_id"] == "11111111-1111-4111-8111-111111111111"
    with pytest.raises(ValueError, match="only"):
        runner._coordination_action(manifest, "fault", {"command": "id"})


def test_runner_source_and_owner_mismatch_fails_before_action(runner_paths: Path) -> None:
    save_manifest(runner_paths / "opt")
    bad_owner = request("health") | {"ownerToken": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}
    with pytest.raises(ValueError, match="owner token"):
        runner._load_manifest(bad_owner)

    (runner.ROOT / "probe.py").write_text("changed source\n", encoding="utf-8")
    with pytest.raises(ValueError, match="source differs"):
        runner._load_manifest(request("health"))


def test_publish_login_failure_can_be_retried_before_any_publish(
    runner_paths: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = save_manifest(runner_paths / "opt") | configured_manifest()
    assert runner.FUNCTION_FILES
    calls: list[list[str]] = []
    monkeypatch.setattr(runner, "_private_addresses", lambda _: {"10.85.0.90"})

    def login_then_publish(arguments: list[str], **_: Any) -> Any:
        calls.append(arguments)
        if arguments[0] == "az":
            return type("Process", (), {"returncode": 1 if len(calls) == 1 else 0})()
        return type("Process", (), {"returncode": 0})()

    monkeypatch.setattr(runner.subprocess, "run", login_then_publish)
    with pytest.raises(RuntimeError, match="before package publish"):
        runner._publish(manifest, {"appName": manifest["functionApps"][0]})
    assert len(calls) == 1
    assert not runner.PUBLISH_PATH.exists()

    result = runner._publish(manifest, {"appName": manifest["functionApps"][0]})
    assert result["published"] is True
    assert [arguments[0] for arguments in calls] == ["az", "az", "func"]
    state = json.loads(runner.PUBLISH_PATH.read_text(encoding="utf-8"))
    assert state["apps"][manifest["functionApps"][0]]["status"] == "Succeeded"


def test_publish_ambiguous_scm_result_is_never_replayed(
    runner_paths: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = save_manifest(runner_paths / "opt") | configured_manifest()
    monkeypatch.setattr(runner, "_private_addresses", lambda _: {"10.85.0.90"})
    calls: list[list[str]] = []

    def failed_publish(arguments: list[str], **_: Any) -> Any:
        calls.append(arguments)
        return type("Process", (), {"returncode": 0 if arguments[0] == "az" else 1})()

    monkeypatch.setattr(runner.subprocess, "run", failed_publish)
    with pytest.raises(RuntimeError, match="outcome is uncertain"):
        runner._publish(manifest, {"appName": manifest["functionApps"][0]})
    assert [arguments[0] for arguments in calls] == ["az", "func"]
    state = json.loads(runner.PUBLISH_PATH.read_text(encoding="utf-8"))
    assert state["apps"][manifest["functionApps"][0]]["status"] == "Ambiguous"
    with pytest.raises(RuntimeError, match="refusing automatic replay"):
        runner._publish(manifest, {"appName": manifest["functionApps"][0]})
    assert [arguments[0] for arguments in calls] == ["az", "func"]


def test_runner_health_requires_private_dns_and_root_owned_durable_database(
    runner_paths: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manifest = save_manifest(runner_paths / "opt") | configured_manifest()
    for binary in ("az", "func"):
        path = Path("/usr/bin") / binary
        monkeypatch.setattr(runner, "Path", Path)
        assert path
    monkeypatch.setattr(
        runner,
        "_private_addresses",
        lambda hostname: (
            {"10.85.0.90"}
            if ".scm." in hostname
            else {"10.85.0.70"}
            if ".blob." in hostname
            else {"10.84.1.10"}
        ),
    )
    monkeypatch.setattr(runner, "_has_binary", lambda _: True)
    runner.DATABASE_PATH.touch()
    runner.DATABASE_PATH.chmod(0o600)
    monkeypatch.setattr(
        runner,
        "_probe",
        lambda *_: {
            "exitCode": 0,
            "result": {"ready": True, "statePath": str(runner.DATABASE_PATH)},
        },
    )
    monkeypatch.setattr(
        runner,
        "_queue_control",
        lambda _: type(
            "Control",
            (),
            {
                "snapshot": lambda self: {
                    "queue": {"id": manifest["queueResourceId"]},
                    "coordinationEtag": '"blob-etag-1"',
                }
            },
        )(),
    )
    result = runner._health(manifest)
    assert result["ready"] is True
    assert result["stateDatabaseReady"] is True
    assert result["queuePrivateAddresses"] == ["10.84.1.10"]
    assert result["coordinationStoreReady"] is True
    assert result["coordinationStoragePrivateAddresses"] == ["10.85.0.70"]
