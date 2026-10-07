"""Dependency-free bootstrap transport; the application uses Azure Identity SDK."""

import hashlib
import ipaddress
import json
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from zipfile import ZipFile

NETWORKS = (ipaddress.ip_network("10.86.0.0/16"), ipaddress.ip_network("10.87.0.0/16"))
RESOURCES = {
    "https://storage.azure.com/",
    "https://ossrdbms-aad.database.windows.net",
    "https://api.loganalytics.io",
}


def token(role: str, resource: str, client_id: str | None = None) -> str:
    if resource not in RESOURCES or role not in {"cloud", "dc"}:
        raise ValueError("Unsupported bootstrap identity request")
    query = {"api-version": "2020-06-01" if role == "dc" else "2018-02-01", "resource": resource}
    if client_id:
        if role != "cloud" or not re.fullmatch(r"[0-9a-fA-F-]{36}", client_id):
            raise ValueError("Invalid temporary identity")
        query["client_id"] = client_id
    endpoint = (
        ("http://localhost:40342" if role == "dc" else "http://169.254.169.254")
        + "/metadata/identity/oauth2/token?"
        + urllib.parse.urlencode(query)
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(endpoint, headers={"Metadata": "true"})
    try:
        with opener.open(request, timeout=20) as response:
            return str(json.load(response)["access_token"])
    except urllib.error.HTTPError as exc:
        if role != "dc" or exc.code != 401:
            raise RuntimeError(f"Bootstrap identity HTTP status {exc.code}") from None
        challenge = exc.headers.get("WWW-Authenticate", "")
        if not challenge.startswith("Basic realm="):
            raise RuntimeError("Unexpected Arc identity challenge") from None
        path = Path(challenge.removeprefix("Basic realm=").strip('"')).resolve()
        if not path.is_relative_to("/var/opt/azcmagent/tokens") or path.stat().st_size > 4096:
            raise RuntimeError("Invalid Arc identity challenge file") from None
        secret = path.read_text().strip()
    request = urllib.request.Request(
        endpoint, headers={"Metadata": "true", "Authorization": f"Basic {secret}"}
    )
    with opener.open(request, timeout=20) as response:
        return str(json.load(response)["access_token"])


def private_addresses(host: str) -> list[str]:
    addresses = sorted({entry[4][0] for entry in socket.getaddrinfo(host, 443)})
    if not addresses or any(
        not any(ipaddress.ip_address(address) in network for network in NETWORKS)
        for address in addresses
    ):
        raise RuntimeError(f"Expected exclusively owned private addresses for {host}")
    return addresses


def blob(
    role: str, account: str, name: str, data: bytes | None = None, *, delete: bool = False
) -> bytes:
    if not re.fullmatch(r"[a-z0-9]{3,24}", account):
        raise ValueError("Invalid storage account name")
    if not re.fullmatch(r"(releases|provisioning)/[a-zA-Z0-9._/-]+", name) or ".." in name:
        raise ValueError("Invalid owned blob path")
    if delete and (data is not None or not name.startswith("provisioning/dc/")):
        raise ValueError("Only temporary DC provisioning blobs may be removed")
    host = f"{account}.blob.core.windows.net"
    private_addresses(host)
    for attempt in range(20):
        headers = {
            "Authorization": f"Bearer {token(role, 'https://storage.azure.com/')}",
            "x-ms-version": "2023-11-03",
            "x-ms-date": datetime.now(UTC).strftime("%a, %d %b %Y %H:%M:%S GMT"),
        }
        if data is not None:
            headers["x-ms-blob-type"] = "BlockBlob"
        request = urllib.request.Request(
            f"https://{host}/{name}",
            data=data,
            headers=headers,
            method="DELETE" if delete else "PUT" if data is not None else "GET",
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                limit = 180_000 if name.startswith("releases/") else 20_000
                content = response.read(limit + 1)
                if len(content) > limit:
                    raise ValueError("Private artifact response exceeds the size bound")
                return content
        except urllib.error.HTTPError as exc:
            if delete and exc.code == 404:
                return b""
            if exc.code not in {403, 404, 409, 429, 500, 502, 503, 504} or attempt == 19:
                raise RuntimeError(f"Private artifact operation HTTP status {exc.code}") from None
            time.sleep(15)
    raise RuntimeError("Private artifact operation exceeded retry limit")


def extract_release(archive: Path, sha256: str, target: Path) -> None:
    if not re.fullmatch(r"[a-f0-9]{64}", sha256):
        raise ValueError("Invalid release digest")
    content = archive.read_bytes()
    if len(content) > 180_000 or hashlib.sha256(content).hexdigest() != sha256:
        raise ValueError("Release digest or size mismatch")
    target.mkdir(parents=True, exist_ok=True)
    with ZipFile(archive) as release:
        for entry in release.infolist():
            resolved = (target / entry.filename).resolve()
            if (
                not resolved.is_relative_to(target.resolve())
                or entry.file_size > 2_000_000
                or (entry.external_attr >> 16) & 0o170000 == 0o120000
            ):
                raise ValueError("Invalid release entry")
        if sum(entry.file_size for entry in release.infolist()) > 5_000_000:
            raise ValueError("Release expansion exceeds limit")
        release.extractall(target)
