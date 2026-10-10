"""Fixed, root-owned command protocol for the private Service Bus scenario VM."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Any

try:
    import fcntl
except ImportError:  # Keep offline tests importable on Windows; the runner executes on Linux.
    fcntl = None  # type: ignore[assignment]

ROOT = Path("/opt/retailtx-servicebus")
STATE_ROOT = Path("/var/lib/retailtx-servicebus")
MANIFEST_PATH = STATE_ROOT / "owner.json"
PUBLISH_PATH = STATE_ROOT / "publish-state.json"
DATABASE_PATH = STATE_ROOT / "servicebus.sqlite"
OWNER_PATTERN = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
NAMESPACE_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{5,49}\.servicebus\.windows\.net$")
QUEUE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,249}$")
APP_PATTERN = re.compile(r"^func-sb-(exec|watch)-[a-z0-9]{3,12}-[a-z0-9]+$")
ALLOWED_ACTIONS = {"configure", "initialize", "state", "fault", "health", "probe", "publish"}
ALLOWED_PROBES = {"health", "seed", "send", "receive", "verify"}
FUNCTION_FILES = (
    "host.json",
    "function_app.py",
    "executor_core.py",
    "coordination.py",
    "mcp_stdio.py",
    "requirements.txt",
)
PRIVATE_NETWORKS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)
SERVICE_BUS_ENDPOINT_NETWORK = ipaddress.ip_network("10.84.1.0/24")
STORAGE_ENDPOINT_NETWORK = ipaddress.ip_network("10.85.0.64/26")


def _json_file(path: Path) -> dict[str, Any]:
    info = path.lstat()
    if path.is_symlink() or not path.is_file() or info.st_uid != 0:
        raise ValueError(f"Owned runner file is missing or not root-owned: {path.name}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"Owned runner file is not an object: {path.name}")
    return value


def _write_json(path: Path, value: dict[str, Any]) -> None:
    if path.exists() and path.is_symlink():
        raise ValueError(f"Refusing to replace a symbolic link: {path.name}")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    next_path = path.with_name(f"{path.name}.next")
    with next_path.open("x", encoding="utf-8") as stream:
        os.chmod(next_path, 0o600)
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(next_path, path)
    os.chmod(path, 0o600)


def _canonical_source_digest(root: Path, files: tuple[str, ...]) -> str:
    records = []
    for name in sorted(files):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Attested source file is missing or unsafe: {name}")
        file_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        records.append(f"{name}\0{file_hash}\n")
    return hashlib.sha256("".join(records).encode("utf-8")).hexdigest()


def _assert_root() -> None:
    if os.geteuid() != 0:
        raise PermissionError("The runner must execute as root through Azure VM Run Command.")
    info = STATE_ROOT.lstat()
    if STATE_ROOT.is_symlink() or not STATE_ROOT.is_dir() or info.st_uid != 0:
        raise ValueError("The durable runner state directory is not an owned root directory.")
    if os.name != "nt" and info.st_mode & 0o077:
        raise ValueError("The durable runner state directory must be mode 0700.")


def _load_manifest(request: dict[str, Any]) -> dict[str, Any]:
    _assert_root()
    manifest = _json_file(MANIFEST_PATH)
    if request["ownerToken"] != manifest.get("ownerToken"):
        raise ValueError("Runner request owner token does not match the installed manifest.")
    if request["bundleSha256"] != manifest.get("bundleSha256"):
        raise ValueError("Runner source bundle digest does not match the installed manifest.")
    if (
        _canonical_source_digest(ROOT, tuple(manifest["runnerFiles"]))
        != manifest["bundleSourceSha256"]
    ):
        raise ValueError("Installed runner source differs from its ownership attestation.")
    if (
        _canonical_source_digest(ROOT / "function-app", FUNCTION_FILES)
        != manifest["functionSourceSha256"]
    ):
        raise ValueError("Installed Function source differs from its ownership attestation.")
    return manifest


def _validate_request(request: Any) -> dict[str, Any]:
    if not isinstance(request, dict) or set(request) != {
        "schemaVersion",
        "ownerToken",
        "bundleSha256",
        "action",
        "arguments",
    }:
        raise ValueError("Runner request fields do not match the fixed protocol.")
    if type(request["schemaVersion"]) is not int or request["schemaVersion"] != 1:
        raise ValueError("Unsupported runner protocol version.")
    if not isinstance(request["ownerToken"], str) or not OWNER_PATTERN.fullmatch(
        request["ownerToken"]
    ):
        raise ValueError("Invalid scenario owner token.")
    if not isinstance(request["bundleSha256"], str) or not re.fullmatch(
        r"[0-9a-f]{64}", request["bundleSha256"]
    ):
        raise ValueError("Invalid runner bundle digest.")
    if not isinstance(request["action"], str) or request["action"] not in ALLOWED_ACTIONS:
        raise ValueError("Runner action is not in the fixed allow-list.")
    if not isinstance(request["arguments"], dict):
        raise ValueError("Runner action arguments must be an object.")
    return request


@contextmanager
def _runner_lock():
    if fcntl is None:
        raise RuntimeError("The runner lock is supported only on Linux.")
    lock_path = STATE_ROOT / "runner.lock"
    if lock_path.is_symlink():
        raise ValueError("Runner lock path must not be a symbolic link.")
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _private_addresses(hostname: str) -> set[str]:
    answers = socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
    addresses = {ipaddress.ip_address(answer[4][0]) for answer in answers}
    if not addresses or any(
        not any(address in network for network in PRIVATE_NETWORKS)
        for address in addresses
    ):
        raise ValueError(f"{hostname} did not resolve exclusively to private addresses.")
    return {str(address) for address in addresses}


def _has_binary(name: str) -> bool:
    return any((Path(path) / name).is_file() for path in ("/usr/bin", "/usr/local/bin"))


def _health(manifest: dict[str, Any]) -> dict[str, Any]:
    queue_addresses = _private_addresses(manifest["namespace"])
    if any(
        ipaddress.ip_address(address) not in SERVICE_BUS_ENDPOINT_NETWORK
        for address in queue_addresses
    ):
        raise ValueError(
            "Service Bus DNS does not resolve to the retained private endpoint subnet."
        )
    scm_addresses = {
        app: sorted(_private_addresses(f"{app}.scm.azurewebsites.net"))
        for app in manifest["functionApps"]
    }
    storage_addresses = _private_addresses(
        f"{manifest['coordinationStorageAccount']}.blob.core.windows.net"
    )
    if any(
        ipaddress.ip_address(address) not in STORAGE_ENDPOINT_NETWORK
        for address in storage_addresses
    ):
        raise ValueError(
            "Coordination storage DNS does not resolve to its owned private endpoint."
        )
    for binary in ("az", "func"):
        if not _has_binary(binary):
            raise RuntimeError(f"Required private runner tool is not installed: {binary}")
    database = _probe(manifest, {"operation": "health"})
    if database["exitCode"] != 0 or not database["result"].get("ready"):
        raise RuntimeError("The durable probe database failed its health check.")
    info = DATABASE_PATH.lstat()
    if info.st_uid != 0 or (os.name != "nt" and info.st_mode & 0o077):
        raise ValueError("The durable SQLite file must be root-owned and mode 0600.")
    coordination = _queue_control(manifest).snapshot()
    if (
        coordination["queue"].get("id", "").lower()
        != manifest["queueResourceId"].lower()
        or not coordination.get("coordinationEtag")
    ):
        raise RuntimeError("Private coordination blob lease/ETag readback failed.")
    return {
        "ready": True,
        "ownerToken": manifest["ownerToken"],
        "bundleSha256": manifest["bundleSha256"],
        "functionSourceSha256": manifest["functionSourceSha256"],
        "queuePrivateAddresses": sorted(queue_addresses),
        "scmPrivateAddresses": scm_addresses,
        "coordinationStoragePrivateAddresses": sorted(storage_addresses),
        "stateDatabaseReady": True,
        "coordinationStoreReady": True,
        "database": database["result"],
    }


def _configure(manifest: dict[str, Any], arguments: dict[str, Any]) -> dict[str, Any]:
    expected = {
        "namespace",
        "queueName",
        "queueResourceId",
        "functionApps",
        "environmentName",
        "coordinationStorageAccount",
        "coordinationContainer",
        "coordinationBlobName",
    }
    if set(arguments) != expected:
        raise ValueError("Runner configuration fields do not match the fixed contract.")
    namespace = arguments["namespace"]
    queue = arguments["queueName"]
    resource_id = arguments["queueResourceId"]
    apps = arguments["functionApps"]
    environment_name = arguments["environmentName"]
    storage_account = arguments["coordinationStorageAccount"]
    coordination_container = arguments["coordinationContainer"]
    coordination_blob = arguments["coordinationBlobName"]
    if not isinstance(namespace, str) or not NAMESPACE_PATTERN.fullmatch(namespace):
        raise ValueError("Invalid private Service Bus namespace.")
    if not isinstance(queue, str) or not QUEUE_PATTERN.fullmatch(queue):
        raise ValueError("Invalid dedicated queue name.")
    expected_queue = (
        r"^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/"
        r"rg-retailtx-servicebus-[a-z0-9]{3,12}-swedencentral/providers/"
        r"Microsoft\.ServiceBus/namespaces/[^/]+/queues/[^/]+$"
    )
    if not isinstance(resource_id, str) or not re.fullmatch(expected_queue, resource_id):
        raise ValueError("Queue resource ID is outside the scenario's owned scope.")
    resource_parts = resource_id.split("/")
    environment = resource_parts[4].removeprefix("rg-retailtx-servicebus-").removesuffix(
        "-swedencentral"
    )
    if resource_parts[-3] != namespace.split(".", maxsplit=1)[0] or resource_parts[-1] != queue:
        raise ValueError("Queue resource ID does not match its supplied queue and namespace.")
    if not isinstance(apps, list) or len(apps) != 2 or any(
        not isinstance(app, str) or not APP_PATTERN.fullmatch(app) for app in apps
    ):
        raise ValueError("Function app names do not match the fixed executor pair.")
    if environment_name != environment:
        raise ValueError("Environment name does not match the owned resource group.")
    if not isinstance(storage_account, str) or not re.fullmatch(
        r"[a-z0-9]{3,24}", storage_account
    ):
        raise ValueError("Coordination storage account name is invalid.")
    if coordination_container != "scenario-coordination":
        raise ValueError("Coordination container differs from the fixed scenario resource.")
    if coordination_blob != "scenario-state.json":
        raise ValueError("Coordination blob name differs from the fixed scenario resource.")
    if (
        apps[0].split("-")[2] != "exec"
        or apps[1].split("-")[2] != "watch"
        or any(app.split("-")[3] != environment for app in apps)
    ):
        raise ValueError("Function app order must be executor followed by watchdog.")
    next_values = {
        "namespace": namespace,
        "queueName": queue,
        "queueResourceId": resource_id,
        "functionApps": apps,
        "environmentName": environment_name,
        "coordinationStorageAccount": storage_account,
        "coordinationContainer": coordination_container,
        "coordinationBlobName": coordination_blob,
    }
    for key, value in next_values.items():
        current = manifest.get(key)
        if current not in (None, "", [] , value):
            raise ValueError(f"Runner configuration drift detected for {key}.")
        manifest[key] = value
    _write_json(MANIFEST_PATH, manifest)
    return {"configured": True, "queueResourceId": resource_id, "functionApps": apps}


def _queue_control(manifest: dict[str, Any]) -> Any:
    if str(ROOT / "function-app") not in sys.path:
        sys.path.insert(0, str(ROOT / "function-app"))
    from azure.identity import ManagedIdentityCredential
    from coordination import BlobCoordinationStore
    from executor_core import QueueControl, Settings

    credential = ManagedIdentityCredential()
    settings = Settings(
        queue_resource_id=manifest["queueResourceId"],
        sre_tenant_id="",
        executor_audience="",
        sre_client_app_id="",
        sre_principal_object_id="",
        sre_required_role="",
        owner_token=manifest["ownerToken"],
        environment_name=manifest["environmentName"],
        storage_account_name=manifest["coordinationStorageAccount"],
        coordination_container=manifest["coordinationContainer"],
        coordination_blob_name=manifest["coordinationBlobName"],
    )
    store = BlobCoordinationStore.from_managed_identity(
        storage_account_name=settings.storage_account_name,
        container_name=settings.coordination_container,
        blob_name=settings.coordination_blob_name,
        credential=credential,
    )
    return QueueControl(
        settings=settings,
        credential=credential,
        coordination_store=store,
    )


def _coordination_action(
    manifest: dict[str, Any], action: str, arguments: dict[str, Any]
) -> dict[str, Any]:
    control = _queue_control(manifest)
    if action == "initialize":
        if arguments:
            raise ValueError("Initialize does not accept arguments.")
        return control.initialize_state()
    if action == "state":
        if arguments:
            raise ValueError("State does not accept arguments.")
        return control.snapshot()
    if action != "fault" or set(arguments) != {
        "transactionId",
        "faultRunId",
        "deadlineUtc",
    }:
        raise ValueError("Fault accepts only transactionId, faultRunId, and deadlineUtc.")
    transaction_id = arguments["transactionId"]
    run_id = arguments["faultRunId"]
    deadline_text = arguments["deadlineUtc"]
    for value in (transaction_id, run_id):
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", value):
            raise ValueError("Fault requires stable transaction and run UUIDs.")
    if not isinstance(deadline_text, str):
        raise ValueError("Fault deadline must be an ISO-8601 timestamp.")
    from datetime import UTC, datetime, timedelta

    now = datetime.now(UTC)
    try:
        deadline = datetime.fromisoformat(deadline_text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("Fault deadline must be an ISO-8601 timestamp.") from error
    if deadline.tzinfo is None or not now < deadline.astimezone(UTC) <= now + timedelta(
        minutes=15
    ):
        raise ValueError("Fault deadline must be within the next 15 minutes.")
    return control.start_fault(
        transaction_id=transaction_id,
        fault_run_id=run_id,
        deadline=deadline,
        now=now,
    )


def _probe(manifest: dict[str, Any], arguments: dict[str, Any]) -> dict[str, Any]:
    if set(arguments) - {"operation", "transactionId", "maxMessages"}:
        raise ValueError("Probe arguments contain unsupported fields.")
    operation = arguments.get("operation")
    if not isinstance(operation, str) or operation not in ALLOWED_PROBES:
        raise ValueError("Probe operation is not in the fixed allow-list.")
    command = [
        str(ROOT / "venv/bin/python"),
        str(ROOT / "probe.py"),
        "--state",
        str(DATABASE_PATH),
        operation,
    ]
    if operation in {"send", "receive"}:
        command.extend(
            ["--namespace", manifest["namespace"], "--queue", manifest["queueName"]]
        )
    if operation in {"send", "verify"}:
        transaction_id = arguments.get("transactionId")
        if not isinstance(transaction_id, str) or not re.fullmatch(
            r"[0-9a-fA-F-]{36}", transaction_id
        ):
            raise ValueError("Probe requires a stable transaction UUID.")
        command.extend(["--transaction-id", transaction_id])
    if operation == "receive":
        count = arguments.get("maxMessages", 10)
        if not isinstance(count, int) or isinstance(count, bool) or not 1 <= count <= 10:
            raise ValueError("Probe receive count must be from 1 through 10.")
        command.extend(["--max-messages", str(count)])
    process = subprocess.run(
        command, cwd=ROOT, capture_output=True, text=True, timeout=90, check=False
    )
    output = process.stdout.strip()
    result = json.loads(output) if output else {"errorType": "EmptyProbeResponse"}
    return {"exitCode": process.returncode, "result": result}


def _publish(manifest: dict[str, Any], arguments: dict[str, Any]) -> dict[str, Any]:
    if set(arguments) != {"appName"}:
        raise ValueError("Publish accepts only the exact app name from the owned pair.")
    app_name = arguments["appName"]
    if app_name not in manifest["functionApps"]:
        raise ValueError("Publish target is not one of the owned Function Apps.")
    if _canonical_source_digest(ROOT / "function-app", FUNCTION_FILES) != manifest[
        "functionSourceSha256"
    ]:
        raise ValueError("Function source changed after the manifest was saved.")
    _private_addresses(f"{app_name}.scm.azurewebsites.net")
    publish_state = _json_file(PUBLISH_PATH) if PUBLISH_PATH.exists() else {"apps": {}}
    if publish_state.get("ownerToken", manifest["ownerToken"]) != manifest["ownerToken"]:
        raise ValueError("Publish journal belongs to a different scenario owner.")
    apps = publish_state.setdefault("apps", {})
    prior = apps.get(app_name)
    if prior:
        if prior.get("sourceSha256") != manifest["functionSourceSha256"]:
            raise ValueError("Published source digest differs from the owned manifest.")
        if prior.get("status") == "Succeeded":
            return {"published": True, "alreadyPublished": True, "appName": app_name}
        if prior.get("status") in {"Started", "Ambiguous"}:
            raise RuntimeError(
                "A prior package publish has an ambiguous outcome; refusing automatic replay."
            )
    login = subprocess.run(
        ["az", "login", "--identity", "--allow-no-subscriptions", "--output", "none"],
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    if login.returncode != 0:
        raise RuntimeError(
            "Managed-identity Azure CLI login failed before package publish."
        )
    state = {
        "ownerToken": manifest["ownerToken"],
        "apps": apps,
    }
    state["apps"][app_name] = {
        "sourceSha256": manifest["functionSourceSha256"],
        "status": "Started",
    }
    _write_json(PUBLISH_PATH, state)
    try:
        process = subprocess.run(
            [
                "func",
                "azure",
                "functionapp",
                "publish",
                app_name,
                "--build",
                "remote",
            ],
            cwd=ROOT / "function-app",
            capture_output=True,
            text=True,
            timeout=1200,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        state["apps"][app_name]["status"] = "Ambiguous"
        _write_json(PUBLISH_PATH, state)
        raise RuntimeError(
            "Function package publish timed out; automatic replay is disabled."
        ) from error
    if process.returncode != 0:
        state["apps"][app_name]["status"] = "Ambiguous"
        _write_json(PUBLISH_PATH, state)
        raise RuntimeError(
            "Function package publish outcome is uncertain; automatic replay is disabled."
        )
    state["apps"][app_name]["status"] = "Succeeded"
    _write_json(PUBLISH_PATH, state)
    return {"published": True, "alreadyPublished": False, "appName": app_name}


def dispatch(request: Any) -> dict[str, Any]:
    normalized = _validate_request(request)
    with _runner_lock():
        manifest = _load_manifest(normalized)
        action = normalized["action"]
        arguments = normalized["arguments"]
        if action == "configure":
            return _configure(manifest, arguments)
        if not manifest.get("namespace") or not manifest.get("functionApps"):
            raise ValueError("Runner is not configured to the owned queue and Function Apps.")
        if action == "health":
            if arguments:
                raise ValueError("Health does not accept arguments.")
            return _health(manifest)
        if action in {"initialize", "state", "fault"}:
            return _coordination_action(manifest, action, arguments)
        if action == "probe":
            return _probe(manifest, arguments)
        if action == "publish":
            return _publish(manifest, arguments)
    raise ValueError("Unsupported runner action.")


def main() -> int:
    request_bytes = sys.stdin.buffer.read(262145)
    if len(request_bytes) > 262144:
        print(json.dumps({"error": "Request exceeds the fixed size limit."}))
        return 2
    try:
        result = dispatch(json.loads(request_bytes))
    except (
        OSError,
        RuntimeError,
        TypeError,
        ValueError,
        TimeoutError,
        subprocess.TimeoutExpired,
    ) as error:
        result = {"error": str(error)}
        print("SB_RESULT:" + json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 2
    print("SB_RESULT:" + json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
