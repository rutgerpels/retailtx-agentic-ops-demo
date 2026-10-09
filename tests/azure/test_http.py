import ssl
from unittest.mock import Mock

import httpx
import pytest
from azure.identity import CredentialUnavailableError
from fastapi import FastAPI
from fastapi.testclient import TestClient
from retailtx import http


def test_outbound_https_requires_verified_mutual_tls(settings, monkeypatch):
    context = Mock(spec=ssl.SSLContext)
    factory = Mock(return_value=context)
    constructor = Mock()
    monkeypatch.setattr(http.ssl, "create_default_context", factory)
    monkeypatch.setattr(http.httpx, "Client", constructor)
    http.client(settings, settings.erp_url)
    factory.assert_called_once_with(cafile=settings.tls_ca_file)
    context.load_cert_chain.assert_called_once_with(settings.tls_cert_file, settings.tls_key_file)
    assert context.minimum_version == ssl.TLSVersion.TLSv1_2
    args = constructor.call_args.kwargs
    assert args["verify"] is context
    assert args["trust_env"] is False
    assert args["follow_redirects"] is False
    check = args["event_hooks"]["request"][0]
    check(httpx.Request("GET", settings.erp_url + "/health"))
    check(httpx.Request("GET", settings.cap_url + "/health"))
    for address in ("http://erp.example/health", "https://untrusted.example/health"):
        with pytest.raises(ValueError, match="HTTPS peers"):
            check(httpx.Request("GET", address))


def test_reject_http_before_loading_certificates(settings):
    with pytest.raises(ValueError, match="HTTPS"):
        http.client(settings, "http://localhost:8000")


def test_invalid_trust_bundle_is_never_ignored(settings):
    with pytest.raises(ssl.SSLError):
        http.client(settings, settings.erp_url)


def test_azure_credential_errors_are_safe_dependency_responses():
    app = FastAPI()
    http.setup(app)

    @app.get("/health")
    def unavailable():
        raise CredentialUnavailableError("credential diagnostic must not reach the caller")

    with TestClient(app) as client:
        response = client.get("/health")
    assert response.status_code == 503
    assert response.json() == {"detail": "Dependency unavailable; retry safely"}
