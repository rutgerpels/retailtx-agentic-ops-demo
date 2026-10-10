#!/usr/bin/env bash
set -euo pipefail

readonly state_root="/var/lib/retailtx-servicebus"
readonly app_root="/opt/retailtx-servicebus"
readonly owner_token="@@OWNER_TOKEN@@"
readonly bundle_sha256="@@BUNDLE_SHA256@@"
readonly bundle_source_sha256="@@BUNDLE_SOURCE_SHA256@@"
readonly function_source_sha256="@@FUNCTION_SOURCE_SHA256@@"
readonly bundle_base64="@@BUNDLE_BASE64@@"

install -d -o root -g root -m 0700 "$state_root" "$app_root" "$app_root/function-app"
if [[ -e "$state_root/owner.json" ]]; then
    python3 -c 'import json,pathlib,sys; x=json.loads(pathlib.Path(sys.argv[1]).read_text()); sys.exit(0 if x.get("ownerToken")==sys.argv[2] and x.get("bundleSha256")==sys.argv[3] else 1)' \
        "$state_root/owner.json" "$owner_token" "$bundle_sha256" \
        || { echo "Existing runner ownership or source digest differs." >&2; exit 1; }
    exit 0
fi

readonly archive_path="$state_root/runner-source.zip"
printf '%s' "$bundle_base64" | base64 --decode > "$archive_path"
chmod 0600 "$archive_path"
printf '%s  %s\n' "$bundle_sha256" "$archive_path" | sha256sum --check --status

python3 - "$archive_path" "$app_root" <<'PY'
import pathlib
import stat
import sys
from zipfile import ZipFile

archive_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
allowed = {
    "runner.py",
    "probe.py",
    "function-app/host.json",
    "function-app/function_app.py",
    "function-app/executor_core.py",
    "function-app/coordination.py",
    "function-app/mcp_stdio.py",
    "function-app/requirements.txt",
}
with ZipFile(archive_path) as archive:
    names = set(archive.namelist())
    if names != allowed:
        raise SystemExit("Runner bundle files do not match the exact source allow-list.")
    for item in archive.infolist():
        mode = item.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise SystemExit("Runner bundle must not contain symbolic links.")
    archive.extractall(root)
PY

chmod 0700 "$app_root" "$app_root/function-app"
chmod 0600 "$app_root/runner.py" "$app_root/probe.py" "$app_root/function-app/"*

curl --fail --silent --show-error \
    --output "$state_root/packages-microsoft-prod.deb" \
    https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
dpkg --install "$state_root/packages-microsoft-prod.deb"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --yes \
    azure-cli azure-functions-core-tools-4 python3-venv
python3 -m venv "$app_root/venv"
"$app_root/venv/bin/pip" install --disable-pip-version-check \
    azure-identity==1.26.0 azure-servicebus==7.14.3 azure-storage-blob==12.31.0

python3 - "$state_root/owner.json" "$owner_token" "$bundle_sha256" \
    "$bundle_source_sha256" "$function_source_sha256" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = {
    "schemaVersion": 1,
    "ownerToken": sys.argv[2],
    "bundleSha256": sys.argv[3],
    "bundleSourceSha256": sys.argv[4],
    "runnerFiles": ["probe.py", "runner.py"],
    "functionSourceSha256": sys.argv[5],
    "namespace": None,
    "queueName": None,
    "queueResourceId": None,
    "functionApps": [],
}
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")), encoding="utf-8")
path.chmod(0o600)
PY
