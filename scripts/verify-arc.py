"""Run on the Arc host: verify private, Entra-authenticated telemetry without tokens in output."""

import argparse
import ipaddress
import json
from pathlib import Path
import re
import socket
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid


def get_arc_token(resource: str) -> str:
    endpoint = "http://127.0.0.1:40342/metadata/identity/oauth2/token?" + urllib.parse.urlencode(
        {"api-version": "2020-06-01", "resource": resource}
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(endpoint, headers={"Metadata": "true"})
    try:
        with opener.open(request, timeout=20) as response:
            return json.load(response)["access_token"]
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
        challenge = error.headers.get("WWW-Authenticate", "")
        if not challenge.startswith("Basic realm="):
            raise RuntimeError("Unexpected Arc identity challenge") from None
        secret_path = Path(challenge[len("Basic realm="):].strip('"')).resolve()
        if not secret_path.is_relative_to(Path("/var/opt/azcmagent/tokens")):
            raise RuntimeError("Arc challenge was outside the token directory") from None
        secret = secret_path.read_text().strip()
    authenticated = urllib.request.Request(
        endpoint, headers={"Metadata": "true", "Authorization": f"Basic {secret}"}
    )
    with opener.open(authenticated, timeout=20) as response:
        return json.load(response)["access_token"]


def private_addresses(host: str) -> list[str]:
    addresses = sorted({entry[4][0] for entry in socket.getaddrinfo(host, 443)})
    network = ipaddress.ip_network("10.84.0.0/16")
    if not addresses or any(ipaddress.ip_address(address) not in network for address in addresses):
        raise RuntimeError(f"{host} did not resolve exclusively to private addresses in the proof VNet")
    return addresses


def verify(workspace_id: str, machine_id: str) -> dict:
    workspace_id = str(uuid.UUID(workspace_id))
    if not re.fullmatch(
        r"/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[a-zA-Z0-9-]+"
        r"/providers/Microsoft\.HybridCompute/machines/erp-core-01", machine_id
    ):
        raise ValueError("Unexpected Arc machine resource ID")
    subprocess.run(
        ["systemctl", "is-active", "--quiet", "retailtx-demo-worker.service"], check=True
    )
    for address in ("169.254.169.254", "169.254.169.253"):
        subprocess.run(
            ["iptables", "-C", "OUTPUT", "-d", address, "-j", "REJECT"], check=True
        )
    if not Path("/var/lib/retailtx/bootstrap-complete").is_file():
        raise RuntimeError("Arc bootstrap completion marker is missing")
    addresses = private_addresses(f"{workspace_id}.ods.opinsights.azure.com")
    query_addresses = private_addresses("api.loganalytics.io")
    token = get_arc_token("https://api.loganalytics.io")
    query = {
        "query": "Heartbeat | where TimeGenerated > ago(30m) "
        f"| where _ResourceId =~ '{machine_id}' | project Computer, TimeGenerated | take 1"
    }
    request = urllib.request.Request(
        f"https://api.loganalytics.io/v1/workspaces/{workspace_id}/query",
        data=json.dumps(query).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        result = json.load(response)
    if not result.get("tables") or not result["tables"][0].get("rows"):
        raise RuntimeError("No recent AMA heartbeat in the private workspace")
    return {
        "worker": "active",
        "azureImds": "blocked",
        "arcIdentity": "authenticated",
        "workspaceIngestionAddresses": addresses,
        "workspaceQueryAddresses": query_addresses,
        "machineId": machine_id,
        "privateWorkspaceQuery": "succeeded",
        "recentHeartbeat": True,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--machine-id", required=True)
    arguments = parser.parse_args()
    try:
        print(json.dumps(verify(arguments.workspace_id, arguments.machine_id)))
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Identity or telemetry HTTP request failed with status {error.code}") from None
