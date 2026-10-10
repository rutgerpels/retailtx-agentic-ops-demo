from __future__ import annotations

import json
from typing import Any
from urllib.parse import parse_qs, urlsplit

import pytest

from scripts.servicebus.executor.mcp_stdio import (
    RESTORE_TOOL,
    ManagedIdentityCredential,
    call_executor,
    handle_message,
)

PRIVATE_URL = "https://func-sb-exec-demo01.azurewebsites.net/api/restore"
PRIVATE_CIDR = "10.85.0.64/26"
AUDIENCE = "api://11111111-1111-4111-8111-111111111111"
FAULT_RUN_ID = "22222222-2222-4222-8222-222222222222"


def _env(monkeypatch: pytest.MonkeyPatch, **overrides: str) -> None:
    values = {
        "EXECUTOR_PRIVATE_URL": PRIVATE_URL,
        "EXECUTOR_PRIVATE_ENDPOINT_CIDR": PRIVATE_CIDR,
        "EXECUTOR_AUDIENCE": AUDIENCE,
    }
    values.update(overrides)
    for key, value in values.items():
        monkeypatch.setenv(key, value)


class FakeCredential:
    def __init__(self) -> None:
        self.scopes: list[str] = []

    def get_token(self, scope: str) -> Any:
        self.scopes.append(scope)
        return type("Token", (), {"token": "executor-audience-token"})()


class FakeResponse:
    status = 200

    def __init__(self, result: dict[str, Any]) -> None:
        self.result = result

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *_: Any) -> None:
        return None

    def read(self) -> bytes:
        return json.dumps(self.result).encode()


class FakeOpener:
    def __init__(self, result: dict[str, Any]) -> None:
        self.result = result
        self.request = None

    def open(self, request: Any, timeout: int) -> FakeResponse:
        self.request = request
        assert timeout == 10
        return FakeResponse(self.result)


def _private_answers() -> list[tuple[Any, ...]]:
    return [(None, None, None, None, ("10.85.0.70", 443))]


def test_mcp_exposes_only_fixed_restore_tool_and_schema() -> None:
    result = handle_message({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    assert result is not None
    assert result["result"]["tools"] == [RESTORE_TOOL]
    assert RESTORE_TOOL["inputSchema"]["additionalProperties"] is False
    assert set(RESTORE_TOOL["inputSchema"]["properties"]) == {"faultRunId"}


def test_mcp_negotiates_protocol_and_ignores_initialized_notification() -> None:
    result = handle_message(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2025-03-26"},
        }
    )
    assert result and result["result"]["protocolVersion"] == "2025-03-26"
    assert (
        handle_message({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None
    )


def test_mcp_rejects_arbitrary_tools_and_arguments_before_invocation() -> None:
    invoked: list[Any] = []

    def invoke(value: Any) -> dict[str, str]:
        invoked.append(value)
        return {"status": "Recovered"}

    bad_calls = [
        {"name": "run_command", "arguments": {"command": "az servicebus queue update"}},
        {
            "name": RESTORE_TOOL["name"],
            "arguments": {"faultRunId": FAULT_RUN_ID, "queueId": "/other"},
        },
        {"name": RESTORE_TOOL["name"], "arguments": {"faultRunId": 5}},
    ]
    for params in bad_calls:
        response = handle_message(
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": params},
            invoke,
        )
        assert response and "error" in response
    assert invoked == []


def test_mcp_does_not_execute_tool_call_notification() -> None:
    invoked: list[Any] = []
    response = handle_message(
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {
                "name": RESTORE_TOOL["name"],
                "arguments": {"faultRunId": FAULT_RUN_ID},
            },
        },
        lambda run_id: invoked.append(run_id) or {"status": "Recovered"},
    )

    assert response is None
    assert invoked == []


def test_mcp_fixed_restore_tool_calls_only_supplied_run_id() -> None:
    invoked: list[Any] = []
    response = handle_message(
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": RESTORE_TOOL["name"],
                "arguments": {"faultRunId": FAULT_RUN_ID},
            },
        },
        lambda run_id: invoked.append(run_id)
        or {"status": "Recovered", "faultRunId": run_id},
    )
    assert response and response["result"]["content"][0]["text"] == json.dumps(
        {"status": "Recovered", "faultRunId": FAULT_RUN_ID},
        separators=(",", ":"),
        sort_keys=True,
    )
    assert invoked == [FAULT_RUN_ID]


def test_fixed_bridge_uses_custom_executor_audience_and_tls_private_endpoint(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _env(monkeypatch)
    credential = FakeCredential()
    opener = FakeOpener(
        {
            "status": "Recovered",
            "faultRunId": FAULT_RUN_ID,
            "recoveryMechanism": "sre-fixed-tool",
            "initiatingPrincipalObjectId": "33333333-3333-4333-8333-333333333333",
        }
    )
    result = call_executor(
        FAULT_RUN_ID,
        credential=credential,
        opener=opener,
        resolver=lambda host, port: _private_answers(),
    )
    assert result["status"] == "Recovered"
    assert credential.scopes == [f"{AUDIENCE}/.default"]
    assert opener.request.full_url == PRIVATE_URL
    assert opener.request.get_header("Authorization") == "Bearer executor-audience-token"
    assert json.loads(opener.request.data) == {"faultRunId": FAULT_RUN_ID}


@pytest.mark.parametrize(
    "url",
    [
        "http://func-sb-exec-demo01.azurewebsites.net/api/restore",
        "https://example.com/api/restore",
        "https://func-sb-exec-demo01.azurewebsites.net/api/restore?target=other",
        "https://user:password@func-sb-exec-demo01.azurewebsites.net/api/restore",
    ],
)
def test_fixed_bridge_rejects_nonprivate_or_mutable_endpoints(
    monkeypatch: pytest.MonkeyPatch, url: str
) -> None:
    _env(monkeypatch, EXECUTOR_PRIVATE_URL=url)
    with pytest.raises(RuntimeError):
        call_executor(
            FAULT_RUN_ID,
            credential=FakeCredential(),
            opener=FakeOpener({"status": "Recovered", "faultRunId": FAULT_RUN_ID}),
            resolver=lambda host, port: _private_answers(),
        )


def test_fixed_bridge_rejects_public_dns_resolution(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _env(monkeypatch)
    with pytest.raises(RuntimeError, match="private subnet"):
        call_executor(
            FAULT_RUN_ID,
            credential=FakeCredential(),
            opener=FakeOpener({"status": "Recovered", "faultRunId": FAULT_RUN_ID}),
            resolver=lambda host, port: [
                (None, None, None, None, ("20.10.0.1", 443))
            ],
        )


def test_fixed_bridge_rejects_executor_response_for_another_run(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _env(monkeypatch)
    opener = FakeOpener(
        {
            "status": "Recovered",
            "faultRunId": "33333333-3333-4333-8333-333333333333",
            "recoveryMechanism": "sre-fixed-tool",
            "initiatingPrincipalObjectId": "33333333-3333-4333-8333-333333333333",
        }
    )
    with pytest.raises(RuntimeError, match="requested run"):
        call_executor(
            FAULT_RUN_ID,
            credential=FakeCredential(),
            opener=opener,
            resolver=lambda host, port: _private_answers(),
        )


def test_fixed_bridge_does_not_claim_watchdog_recovery_as_sre_action(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _env(monkeypatch)
    opener = FakeOpener(
        {
            "status": "AlreadyRecovered",
            "faultRunId": FAULT_RUN_ID,
            "recoveryMechanism": "deadline-watchdog",
            "initiatingPrincipalObjectId": None,
        }
    )
    with pytest.raises(RuntimeError, match="requested run"):
        call_executor(
            FAULT_RUN_ID,
            credential=FakeCredential(),
            opener=opener,
            resolver=lambda host, port: _private_answers(),
        )


class FakeTokenResponse:
    status = 200

    def __enter__(self) -> FakeTokenResponse:
        return self

    def __exit__(self, *_: Any) -> None:
        return None

    def read(self) -> bytes:
        return json.dumps({"access_token": "managed-identity-token"}).encode()


class FakeTokenOpener:
    def __init__(self) -> None:
        self.request = None
        self.timeout = None

    def open(self, request: Any, timeout: int) -> FakeTokenResponse:
        self.request = request
        self.timeout = timeout
        return FakeTokenResponse()


def test_managed_identity_uses_local_endpoint_and_custom_resource(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import scripts.servicebus.executor.mcp_stdio as mcp_stdio

    monkeypatch.setenv("IDENTITY_ENDPOINT", "http://localhost:42342/metadata/identity/token")
    monkeypatch.setenv("IDENTITY_HEADER", "host-injected-header")
    monkeypatch.delenv("MSI_ENDPOINT", raising=False)
    monkeypatch.delenv("MSI_SECRET", raising=False)
    opener = FakeTokenOpener()
    monkeypatch.setattr(
        mcp_stdio.urllib.request, "build_opener", lambda *_: opener
    )

    token = ManagedIdentityCredential().get_token(f"{AUDIENCE}/.default")

    assert token.token == "managed-identity-token"
    assert opener.request.get_header("X-identity-header") == "host-injected-header"
    parsed = urlsplit(opener.request.full_url)
    assert parsed.hostname == "localhost"
    assert parse_qs(parsed.query) == {
        "api-version": ["2019-08-01"],
        "resource": [AUDIENCE],
    }
    assert opener.timeout == 10


@pytest.mark.parametrize(
    "endpoint",
    [
        "http://169.254.169.254/metadata/token",
        "https://attacker.example/token",
        "http://localhost/token?resource=https://management.azure.com/",
    ],
)
def test_managed_identity_rejects_untrusted_endpoint_override(
    monkeypatch: pytest.MonkeyPatch, endpoint: str
) -> None:
    monkeypatch.setenv("IDENTITY_ENDPOINT", endpoint)
    monkeypatch.setenv("IDENTITY_HEADER", "header")
    with pytest.raises(RuntimeError, match="local container"):
        ManagedIdentityCredential().get_token(f"{AUDIENCE}/.default")


def test_managed_identity_requests_only_default_scope(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("IDENTITY_ENDPOINT", raising=False)
    monkeypatch.delenv("IDENTITY_HEADER", raising=False)
    monkeypatch.delenv("MSI_ENDPOINT", raising=False)
    monkeypatch.delenv("MSI_SECRET", raising=False)
    with pytest.raises(RuntimeError, match="default app role"):
        ManagedIdentityCredential().get_token("https://management.azure.com/")
