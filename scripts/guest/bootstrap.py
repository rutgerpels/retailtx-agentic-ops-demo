#!/usr/bin/env python3
"""Install only an exact source-attested, root-owned fixture; never replace foreign files."""
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

FILES = ("controller.py", "bootstrap.py", "worker.py", "retailtx-demo-posting-worker.service",
         "retailtx-guest-watchdog.service", "retailtx-guest-watchdog.timer",
         "retailtx-guest-observer.service", "retailtx-guest-observer.timer")


def safe_directory(path, mode):
    if not path.exists():
        path.mkdir(mode=mode)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError("Unprotected installation directory")


def install_exact(path, content, mode):
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("Foreign or unprotected installation file")
        if path.read_bytes() != content:
            raise ValueError("Installed source mismatch; teardown required")
        return
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())


def main():
    if os.geteuid() != 0 or len(sys.argv) != 2:
        raise ValueError("Root and one encoded configuration required")
    payload = json.loads(base64.b64decode(sys.argv[1], validate=True))
    if set(payload) != {"config", "sources"} or set(payload["sources"]) != set(FILES):
        raise ValueError("Unexpected installation payload")
    config = payload["config"]
    if set(config) != {"schemaVersion", "ownerToken", "sourceHashes"}:
        raise ValueError("Invalid configuration")
    if config["schemaVersion"] != 1 or set(config["sourceHashes"]) != set(FILES):
        raise ValueError("Invalid source manifest")
    import uuid
    if str(uuid.UUID(config["ownerToken"])) != config["ownerToken"]:
        raise ValueError("Invalid owner")
    sources = {}
    for name in FILES:
        content = base64.b64decode(payload["sources"][name], validate=True)
        if hashlib.sha256(content).hexdigest() != config["sourceHashes"][name]:
            raise ValueError("Installation digest mismatch")
        sources[name] = content
    root = Path("/opt/retailtx-guest")
    data = Path("/var/lib/retailtx-guest")
    safe_directory(root, 0o755)
    safe_directory(data, 0o700)
    config_bytes = json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
    install_exact(root / "config.json", config_bytes, 0o600)
    for name, content in sources.items():
        path = root / name if name.endswith(".py") else Path("/etc/systemd/system") / name
        install_exact(path, content, 0o644)
    subprocess.run(["/usr/bin/systemctl", "daemon-reload"], check=True, timeout=20)
    subprocess.run(["/usr/bin/systemctl", "enable", "retailtx-demo-posting-worker.service",
                    "retailtx-guest-watchdog.timer", "retailtx-guest-observer.timer"],
                   check=True, timeout=20, capture_output=True)
    subprocess.run(["/usr/bin/systemctl", "start", "retailtx-guest-watchdog.timer"],
                   check=True, timeout=20)
    request = {"action": "configure", "ownerToken": config["ownerToken"],
               "sourceHashes": config["sourceHashes"]}
    encoded = base64.b64encode(json.dumps(request).encode()).decode()
    subprocess.run(["/usr/bin/python3", str(root / "controller.py"), encoded], check=True, timeout=40)
    subprocess.run(["/usr/bin/systemctl", "start", "retailtx-guest-observer.timer"],
                   check=True, timeout=20)


if __name__ == "__main__":
    main()
