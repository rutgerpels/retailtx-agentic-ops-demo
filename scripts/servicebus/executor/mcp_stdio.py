"""Single-tool MCP stdio bridge to the private fixed-action executor."""

from __future__ import annotations

import ipaddress
import json
import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

SUPPORTED_PROTOCOLS = {"2024-11-05", "2025-03-26"}
MAX_LINE_BYTES = 65536
RESTORE_TOOL = {
    "name": "restore_servicebus_queue",
    "description": (
        "Restore the single manifest-bound RetailTx Service Bus queue after "
        "the current SendDisabled fault. No target, status, or command is accepted."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "faultRunId": {
                "type": "string",
                "format": "uuid",
                "description": "Current durable queue fault-run GUID from incident evidence.",
            }
        },
        "required": ["faultRunId"],
        "additionalProperties": False,
    },
}


@dataclass(frozen=True)
class AccessToken:
    token: str


class ManagedIdentityCredential:
    def get_token(self, scope: str) -> AccessToken:
        if not scope.endswith("/.default"):
            raise RuntimeError("Executor token scope must use the default app role.")
        resource = scope[: -len("/.default")]
        endpoint = os.environ.get("IDENTITY_ENDPOINT")
        header = os.environ.get("IDENTITY_HEADER")
        secret_endpoint = os.environ.get("MSI_ENDPOINT")
        secret = os.environ.get("MSI_SECRET")
        if endpoint or header:
            if not endpoint or not header:
                raise RuntimeError("Managed identity endpoint configuration is incomplete.")
            url, headers = self._local_endpoint(
                endpoint, resource, "X-IDENTITY-HEADER", header
            )
        elif secret_endpoint or secret:
            if not secret_endpoint or not secret:
                raise RuntimeError("Managed identity endpoint configuration is incomplete.")
            url, headers = self._local_endpoint(
                secret_endpoint, resource, "secret", secret
            )
        else:
            url = (
                "http://169.254.169.254/metadata/identity/oauth2/token?"
                + urllib.parse.urlencode(
                    {"api-version": "2018-02-01", "resource": resource}
                )
            )
            headers = {"Metadata": "true"}
        request = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=10) as response:
                if response.status != 200:
                    raise RuntimeError("Managed identity token endpoint rejected the request.")
                token = json.loads(response.read()).get("access_token")
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise RuntimeError("Managed identity token acquisition failed.") from error
        if not isinstance(token, str) or not token:
            raise RuntimeError("Managed identity token response was invalid.")
        return AccessToken(token)

    @staticmethod
    def _local_endpoint(
        endpoint: str, resource: str, header_name: str, header_value: str
    ) -> tuple[str, dict[str, str]]:
        parsed = urllib.parse.urlsplit(endpoint)
        if (
            parsed.scheme not in {"http", "https"}
            or parsed.hostname is None
            or parsed.username is not None
            or parsed.password is not None
            or parsed.fragment
            or parsed.query
            or parsed.hostname.lower() not in {"localhost", "127.0.0.1", "::1"}
        ):
            raise RuntimeError("Managed identity endpoint must be a local container endpoint.")
        query = urllib.parse.urlencode(
            {"api-version": "2019-08-01", "resource": resource}
        )
        url = urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, parsed.path, query, "")
        )
        return url, {header_name: header_value}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        request: urllib.request.Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        return None


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Required MCP bridge setting is missing: {name}.")
    return value


def _endpoint() -> tuple[str, str, ipaddress.IPv4Network | ipaddress.IPv6Network]:
    url = _required("EXECUTOR_PRIVATE_URL")
    audience = _required("EXECUTOR_AUDIENCE")
    subnet = ipaddress.ip_network(_required("EXECUTOR_PRIVATE_ENDPOINT_CIDR"), strict=True)
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.port not in (None, 443)
        or parsed.query
        or parsed.fragment
        or parsed.path != "/api/restore"
        or parsed.hostname is None
        or not parsed.hostname.lower().endswith(".azurewebsites.net")
        or not audience.startswith("api://")
    ):
        raise RuntimeError("MCP bridge endpoint must be the fixed private HTTPS restore route.")
    return url, audience, subnet


def _assert_private_resolution(host: str, subnet: ipaddress._BaseNetwork) -> None:
    try:
        answers = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    except OSError as error:
        raise RuntimeError("Private executor DNS resolution failed.") from error
    addresses = {ipaddress.ip_address(answer[4][0]) for answer in answers}
    if not addresses or any(
        address not in subnet or not address.is_private or address.is_loopback
        for address in addresses
    ):
        raise RuntimeError("Executor DNS did not resolve exclusively inside its private subnet.")


def call_executor(
    fault_run_id: Any,
    *,
    credential: Any | None = None,
    opener: Any | None = None,
    resolver: Callable[[str, int], list[Any]] | None = None,
) -> dict[str, Any]:
    if not isinstance(fault_run_id, str):
        raise ValueError("faultRunId must be a GUID.")
    try:
        run_id = str(uuid.UUID(fault_run_id))
    except ValueError as error:
        raise ValueError("faultRunId must be a GUID.") from error
    url, audience, subnet = _endpoint()
    parsed = urllib.parse.urlsplit(url)
    resolve = resolver or socket.getaddrinfo
    try:
        answers = resolve(parsed.hostname or "", 443)
    except OSError as error:
        raise RuntimeError("Private executor DNS resolution failed.") from error
    addresses = {ipaddress.ip_address(answer[4][0]) for answer in answers}
    if not addresses or any(
        address not in subnet or not address.is_private or address.is_loopback
        for address in addresses
    ):
        raise RuntimeError("Executor DNS did not resolve exclusively inside its private subnet.")

    credential = credential or ManagedIdentityCredential()
    token = credential.get_token(f"{audience}/.default").token
    request = urllib.request.Request(
        url,
        data=json.dumps({"faultRunId": run_id}, separators=(",", ":")).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    client = opener or urllib.request.build_opener(NoRedirect())
    try:
        with client.open(request, timeout=10) as response:
            if response.status != 200:
                raise RuntimeError("Executor did not confirm recovery.")
            result = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Executor rejected recovery with HTTP {error.code}.") from None
    except (urllib.error.URLError, TimeoutError) as error:
        raise RuntimeError("Executor recovery was not confirmed.") from error
    if (
        not isinstance(result, dict)
        or result.get("status") not in {"Recovered", "AlreadyRecovered"}
        or result.get("faultRunId") != run_id
        or result.get("recoveryMechanism") != "sre-fixed-tool"
        or not isinstance(result.get("initiatingPrincipalObjectId"), str)
    ):
        raise RuntimeError("Executor response does not prove recovery of the requested run.")
    try:
        uuid.UUID(result["initiatingPrincipalObjectId"])
    except ValueError as error:
        raise RuntimeError("Executor response has no valid SRE caller identity.") from error
    return result


def _rpc_error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }


def handle_message(
    message: Any,
    invoke: Callable[[Any], dict[str, Any]] = call_executor,
) -> dict[str, Any] | None:
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return _rpc_error(None, -32600, "Invalid Request")
    method = message.get("method")
    request_id = message.get("id")
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}
    if method == "initialize":
        params = message.get("params")
        protocol = params.get("protocolVersion") if isinstance(params, dict) else None
        if protocol not in SUPPORTED_PROTOCOLS:
            return _rpc_error(request_id, -32602, "Unsupported MCP protocol version")
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "protocolVersion": protocol,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "retailtx-servicebus-recovery", "version": "1.0.0"},
            },
        }
    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {"tools": [RESTORE_TOOL]},
        }
    if method == "tools/call":
        if request_id is None:
            return None
        params = message.get("params")
        if not isinstance(params, dict) or params.get("name") != RESTORE_TOOL["name"]:
            return _rpc_error(request_id, -32602, "Unknown fixed recovery tool")
        arguments = params.get("arguments")
        if (
            not isinstance(arguments, dict)
            or set(arguments) != {"faultRunId"}
            or not isinstance(arguments["faultRunId"], str)
        ):
            return _rpc_error(request_id, -32602, "Only faultRunId is accepted")
        try:
            result = invoke(arguments["faultRunId"])
        except Exception:
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "content": [{"type": "text", "text": "Recovery was not confirmed."}],
                    "isError": True,
                },
            }
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(result, separators=(",", ":"), sort_keys=True),
                    }
                ],
            },
        }
    if request_id is None:
        return None
    return _rpc_error(request_id, -32601, "Method not found")


def main() -> int:
    for raw_line in sys.stdin.buffer:
        if len(raw_line) > MAX_LINE_BYTES:
            return 2
        try:
            request = json.loads(raw_line)
            response = handle_message(request)
        except (ValueError, RuntimeError):
            response = _rpc_error(None, -32603, "MCP bridge configuration or request failed")
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
