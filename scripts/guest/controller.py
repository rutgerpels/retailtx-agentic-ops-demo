#!/usr/bin/env python3
"""Root-owned fixed-action fixture controller. Run Command itself is NOT constrained RBAC."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from urllib.request import urlopen

ROOT = Path("/opt/retailtx-guest")
DATA = Path("/var/lib/retailtx-guest")
SERVICE = "retailtx-demo-posting-worker"
TIMER = "retailtx-guest-watchdog.timer"
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HASH = re.compile(r"^[0-9a-f]{64}$")
FILES = ("controller.py", "bootstrap.py", "worker.py", "retailtx-demo-posting-worker.service",
         "retailtx-guest-watchdog.service", "retailtx-guest-watchdog.timer")


def utc(value=None):
    return datetime.fromtimestamp(time.time() if value is None else value, timezone.utc).isoformat()


def protected(path, directory=False):
    info = path.lstat()
    if info.st_uid != 0 or stat.S_ISLNK(info.st_mode) or info.st_mode & 0o022:
        raise ValueError("Unprotected fixture path")
    if directory != stat.S_ISDIR(info.st_mode):
        raise ValueError("Unexpected fixture path type")
    if not directory and not stat.S_ISREG(info.st_mode):
        raise ValueError("Unexpected fixture file type")


def load(path):
    protected(path)
    return json.loads(path.read_text(encoding="utf-8"))


def save(state):
    path = DATA / "state.json"
    if path.exists():
        protected(path)
    staging = DATA / "state.next"
    if staging.exists() or staging.is_symlink():
        protected(staging)
        staging.unlink()  # An interrupted pre-rename write cannot supersede the durable marker.
    descriptor = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(state, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(staging, path)
        descriptor = os.open(DATA, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if staging.exists():
            staging.unlink()


def systemctl(action, unit):
    if action not in ("start", "stop", "is-active", "is-enabled"):
        raise ValueError("Unsupported service operation")
    if unit not in (SERVICE, TIMER):
        raise ValueError("Unsupported service")
    result = subprocess.run(["/usr/bin/systemctl", action, unit], timeout=20,
                            check=False, capture_output=True, text=True)
    return result.returncode == 0


def healthy():
    try:
        with urlopen("http://127.0.0.1:8765/health", timeout=1) as response:
            return response.status == 200 and json.loads(response.read(512)) == {
                "service": SERVICE, "healthy": True}
    except (OSError, ValueError):
        return False


def await_health():
    for _ in range(10):
        if systemctl("is-active", SERVICE) and healthy():
            return
        time.sleep(0.5)
    raise ValueError("Worker recovery health check failed")


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def attest():
    protected(ROOT, True)
    protected(DATA, True)
    config = load(ROOT / "config.json")
    if set(config) != {"schemaVersion", "ownerToken", "sourceHashes"} or config["schemaVersion"] != 1:
        raise ValueError("Invalid configuration")
    if not UUID.fullmatch(config["ownerToken"]) or set(config["sourceHashes"]) != set(FILES):
        raise ValueError("Invalid source manifest")
    for name in FILES:
        path = ROOT / name if name.endswith(".py") else Path("/etc/systemd/system") / name
        protected(path)
        expected = config["sourceHashes"][name]
        if not HASH.fullmatch(expected) or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("Fixture source attestation failed")
    return config


def validate_request(request, config):
    action = request.get("action")
    keys = {"action", "ownerToken", "sourceHashes"}
    if action == "fault":
        keys |= {"runId", "actor", "startBeforeUtc", "durationSeconds", "canary"}
    elif action in ("repair", "reset"):
        keys |= {"runId", "actor"}
        if action == "repair" and "expectedDeadlineUtc" in request:
            keys.add("expectedDeadlineUtc")
    elif action not in ("configure", "status"):
        raise ValueError("Unsupported action")
    if set(request) != keys or request["ownerToken"] != config["ownerToken"]:
        raise ValueError("Request ownership mismatch")
    if request["sourceHashes"] != config["sourceHashes"]:
        raise ValueError("Request source mismatch")
    if action in ("fault", "repair", "reset"):
        if not UUID.fullmatch(request["runId"]) or not UUID.fullmatch(request["actor"]):
            raise ValueError("Exact run and actor UUIDs required")
    if action == "fault":
        duration = request["durationSeconds"]
        canary = request["canary"]
        if type(canary) is not bool or type(duration) is not int:
            raise ValueError("Invalid bounded duration")
        if (canary and duration != 60) or (not canary and not 120 <= duration <= 600):
            raise ValueError("Canary is 60 seconds; subsequent faults are 120-600 seconds")
        admission = datetime.fromisoformat(request["startBeforeUtc"])
        if admission.tzinfo is None or admission.utcoffset().total_seconds() != 0:
            raise ValueError("UTC deadline required")
        remaining = admission.timestamp() - time.time()
        if not 0 < remaining <= 90:
            raise ValueError("Expired or unbounded fault intent")
    return action


def recover(state, actor, reason):
    marker = state["marker"]
    if marker:
        marker["phase"] = "recovering"
        save(state)
    if not systemctl("start", SERVICE):
        raise ValueError("Worker start failed")
    await_health()
    if marker:
        marker["phase"] = "recovered"
        marker["recoveredBy"] = actor
        marker["recoveryReason"] = reason
        marker["recoveredAtUtc"] = utc()
        elapsed = time.monotonic() >= marker["monotonicDeadlineSeconds"]
        if actor == "watchdog" and marker["canary"] and reason == "deadline" and elapsed:
            state["watchdogProof"] = {"runId": marker["runId"], "recoveredAtUtc": marker["recoveredAtUtc"]}
    save(state)


def execute(request, config, state):
    action = validate_request(request, config)
    if action == "configure":
        if state["marker"] and state["marker"]["phase"] not in ("recovered", "cancelled"):
            raise ValueError("Configure cannot reset an outstanding fault")
        if not systemctl("is-enabled", TIMER) or not systemctl("is-active", TIMER):
            raise ValueError("Independent watchdog not active")
        if not systemctl("start", SERVICE):
            raise ValueError("Worker start failed")
        await_health()
    elif action == "fault":
        if request["runId"] in state["usedRunIds"]:
            raise ValueError("Fault replay refused, even after recovery")
        if len(state["usedRunIds"]) >= 256:
            raise ValueError("Fixture run history full; redeploy")
        if state["marker"] and state["marker"]["phase"] not in ("recovered", "cancelled"):
            raise ValueError("An outstanding fault already exists")
        if not request["canary"] and not state["watchdogProof"]:
            raise ValueError("Deadline watchdog canary must pass first")
        if not systemctl("is-active", SERVICE) or not healthy():
            raise ValueError("Fault requires healthy worker")
        if not systemctl("is-active", TIMER) or not systemctl("is-enabled", TIMER):
            raise ValueError("Independent watchdog not active")
        state["usedRunIds"].append(request["runId"])
        state["marker"] = {key: request[key] for key in (
            "runId", "actor", "startBeforeUtc", "durationSeconds", "canary")}
        started = time.time()
        state["marker"].update(phase="prepared", startedAtUtc=utc(started),
                               deadlineUtc=utc(started + request["durationSeconds"]), bootId=boot_id(),
                               monotonicDeadlineSeconds=time.monotonic() + request["durationSeconds"])
        save(state)  # Durable intent precedes the ONLY fault: stopping this exact service.
        if time.time() >= datetime.fromisoformat(request["startBeforeUtc"]).timestamp():
            state["marker"].update(phase="cancelled", cancellationReason="admission-expired",
                                   cancelledAtUtc=utc())
            save(state)
            raise ValueError("Admission expired before stop; fault cancelled without stopping")
        if not systemctl("stop", SERVICE):
            raise ValueError("Stop result unknown; watchdog remains armed")
        if systemctl("is-active", SERVICE) or healthy():
            raise ValueError("Fault health readback failed")
        state["marker"]["phase"] = "fault-active"
        save(state)
    elif action in ("repair", "reset"):
        marker = state["marker"]
        if marker:
            if request["runId"] != marker["runId"]:
                raise ValueError("Repair/reset exact run mismatch")
        elif action == "repair" or request["runId"] != "00000000-0000-0000-0000-000000000000":
            raise ValueError("No matching fault to repair")
        if "expectedDeadlineUtc" in request:
            expected = datetime.fromisoformat(request["expectedDeadlineUtc"])
            if (expected.tzinfo is None or expected.utcoffset().total_seconds() != 0 or
                    marker["phase"] != "fault-active" or
                    expected != datetime.fromisoformat(marker["deadlineUtc"]) or
                    time.time() >= expected.timestamp() or marker["bootId"] != boot_id() or
                    time.monotonic() >= marker["monotonicDeadlineSeconds"]):
                raise ValueError("Approved repair window expired or fault already recovered")
        recover(state, request["actor"], action)


def watchdog(state):
    marker = state["marker"]
    if marker and marker["phase"] not in ("recovered", "cancelled"):
        rebooted = marker["bootId"] != boot_id()
        expired = (time.time() >= datetime.fromisoformat(marker["deadlineUtc"]).timestamp() or
                   (not rebooted and time.monotonic() >= marker["monotonicDeadlineSeconds"]))
        if expired or rebooted:
            recover(state, "watchdog", "deadline" if expired else "reboot")


def evidence(config, state):
    return {
        "schemaVersion": 1, "ownerToken": config["ownerToken"], "observedAtUtc": utc(),
        "service": SERVICE, "active": systemctl("is-active", SERVICE), "healthy": healthy(),
        "marker": state["marker"], "watchdogEnabled": systemctl("is-enabled", TIMER),
        "watchdogActive": systemctl("is-active", TIMER), "watchdogProof": state["watchdogProof"],
        "sourceHashes": config["sourceHashes"],
    }


def main():
    if os.geteuid() != 0:
        raise ValueError("Root execution required")
    config = attest()
    descriptor = os.open(DATA / "controller.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        protected(DATA / "controller.lock")
        watchdog_call = sys.argv[1:] == ["--watchdog"]
        for attempt in range(11):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if watchdog_call:
                    return  # The recurring timer retries without queuing duplicate recovery commands.
                if attempt == 10:
                    raise ValueError("Fixture command already active")
                time.sleep(0.5)
        if not watchdog_call and len(sys.argv) != 2:
            raise ValueError("One fixed encoded request required")
        request = None if watchdog_call else json.loads(base64.b64decode(sys.argv[1], validate=True))
        path = DATA / "state.json"
        if path.exists():
            state = load(path)
        elif request and validate_request(request, config) == "configure":
            state = {"ownerToken": config["ownerToken"], "marker": None,
                     "watchdogProof": None, "usedRunIds": []}
            save(state)
        else:
            raise ValueError("Fixture not configured")
        if state["ownerToken"] != config["ownerToken"]:
            raise ValueError("State ownership mismatch")
        if watchdog_call:
            watchdog(state)
        else:
            execute(request, config, state)
            print("RETAILTX_GUEST=" + json.dumps(evidence(config, state), separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Fixture action failed: " + str(error), file=sys.stderr)
        sys.exit(1)
