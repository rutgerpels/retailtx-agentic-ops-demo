import os
from unittest.mock import Mock

import pytest
from azure.core.credentials import AccessToken
from azure.identity import CredentialUnavailableError
from psycopg.conninfo import conninfo_to_dict
from retailtx import broker, db, identity
from retailtx.runtime import validate_command
from retailtx.settings import Settings


def test_cap_uses_freshly_requested_token_for_every_connection(settings, monkeypatch):
    credential = Mock()
    credential.get_token.side_effect = [AccessToken("first-test-token", 1), AccessToken("next", 2)]
    monkeypatch.setattr("retailtx.settings.managed_identity", lambda kind: credential)
    connect = Mock()
    monkeypatch.setattr(db.psycopg, "connect", connect)
    target = settings.cap_dsn
    assert isinstance(target, db.EntraPostgres)
    config = conninfo_to_dict(target.conninfo)
    assert config["sslmode"] == "verify-full"
    assert config["sslrootcert"] == "pyproject.toml"
    assert config["user"] == "cap-runtime"
    assert "password" not in config
    db.connect(target)
    db.connect(target)
    assert [call.kwargs["password"] for call in connect.call_args_list] == [
        "first-test-token",
        "next",
    ]
    assert [call.args for call in credential.get_token.call_args_list] == [(db.POSTGRES_SCOPE,)] * 2
    assert "first-test-token" not in repr(settings)
    assert "first-test-token" not in repr(target)
    assert "first-test-token" not in os.environ.values()


def test_identity_failure_never_opens_a_password_or_operator_connection(settings, monkeypatch):
    credential = Mock()
    credential.get_token.side_effect = CredentialUnavailableError("No host identity")
    monkeypatch.setattr("retailtx.settings.managed_identity", lambda kind: credential)
    connect = Mock()
    monkeypatch.setattr(db.psycopg, "connect", connect)
    with pytest.raises(CredentialUnavailableError):
        db.connect(settings.cap_dsn)
    connect.assert_not_called()


def test_broker_uses_namespace_and_managed_identity_only(settings, monkeypatch):
    credential = Mock()
    constructor = Mock()
    monkeypatch.setattr("retailtx.settings.managed_identity", lambda kind: credential)
    monkeypatch.setattr(broker, "ServiceBusClient", constructor)
    broker.client(settings)
    assert constructor.call_args.kwargs["fully_qualified_namespace"] == settings.broker_host
    assert constructor.call_args.kwargs["credential"] is credential
    constructor.from_connection_string.assert_not_called()
    with pytest.raises(ValueError, match="forbidden"):
        _ = settings.emulator_connection


def test_vm_sdk_selection_is_system_imds(azure_env):
    identity._credential.cache_clear()
    credential = identity.managed_identity("vm")
    assert type(credential._credential).__name__ == "ImdsCredential"
    credential.close()
    identity._credential.cache_clear()


def test_arc_sdk_selection_and_local_peer_database(azure_env, monkeypatch):
    monkeypatch.setenv("RETAILTX_IDENTITY", "arc")
    monkeypatch.setenv("IDENTITY_ENDPOINT", identity.ARC_IDENTITY_ENDPOINT)
    monkeypatch.setenv("IMDS_ENDPOINT", identity.ARC_IMDS_ENDPOINT)
    monkeypatch.delenv("CAP_DB_HOST")
    monkeypatch.setenv("ERP_DB_HOST", "/var/run/postgresql")
    monkeypatch.setenv("ERP_DB_USER", "retailtx")
    settings = Settings.from_env()
    assert conninfo_to_dict(settings.erp_dsn)["host"] == "/var/run/postgresql"
    assert "password" not in conninfo_to_dict(settings.erp_dsn)
    identity._credential.cache_clear()
    credential = settings.credential
    assert type(credential._credential).__name__ == "AzureArcCredential"
    credential.close()
    identity._credential.cache_clear()
    validate_command("erp-poster", settings)
    validate_command("migrate-erp", settings)
    with pytest.raises(ValueError, match="CAP_DB_HOST"):
        validate_command("recon-job", settings)


def test_cloud_commands_do_not_require_remote_unix_database(settings):
    for command in ("reconcile", "recon-job", "migrate-cap"):
        validate_command(command, settings)
    with pytest.raises(ValueError, match="DC host"):
        validate_command("undo", settings)
    with pytest.raises(ValueError, match="separate"):
        validate_command("migrate", settings)


@pytest.mark.parametrize(
    ("key", "value", "message"),
    [
        ("CAP_DB_PASSWORD", "not-accepted", "passwords"),
        ("ERP_DB_PASSWORD", "not-accepted", "passwords"),
        ("SERVICEBUS_CONNECTION_STRING", "not-accepted", "shared keys"),
        ("PGSERVICE", "unsafe", "passwords"),
        ("RETAILTX_IDENTITY", "cli", "RETAILTX_IDENTITY"),
        ("AZURE_CLIENT_ID", "not-accepted", "system-assigned"),
        ("AZURE_FEDERATED_TOKEN_FILE", "not-accepted", "system-assigned"),
        ("IDENTITY_ENDPOINT", identity.ARC_IDENTITY_ENDPOINT, "Azure IMDS"),
        ("BROKER_NAMESPACE", "localhost", "FQDN"),
        ("BROKER_NAMESPACE", "sb://example.servicebus.windows.net", "FQDN"),
        ("CAP_DB_HOST", "localhost", "FQDN"),
        ("ERP_DB_HOST", "erp.example.internal", "UNIX socket"),
        ("ERP_DB_HOST", "/var/run/postgresql,remote", "UNIX socket"),
        ("CAP_URL", "http://cap.example", "HTTPS"),
        ("ERP_URL", "https://user:password@erp.example", "HTTPS"),
        ("ERP_URL", "https://erp.example/path", "HTTPS"),
        ("TLS_KEY_FILE", "not-present.key", "installed file"),
        ("CAP_DB_SSLROOTCERT", "not-present.pem", "installed file"),
    ],
)
def test_invalid_azure_configuration_fails_closed(azure_env, monkeypatch, key, value, message):
    monkeypatch.setenv(key, value)
    with pytest.raises(ValueError, match=message):
        Settings.from_env()


@pytest.mark.parametrize("missing", ["TLS_CA_FILE", "TLS_CERT_FILE", "TLS_KEY_FILE", "CAP_DB_USER"])
def test_missing_required_configuration(azure_env, monkeypatch, missing):
    monkeypatch.delenv(missing)
    with pytest.raises(ValueError, match=missing):
        Settings.from_env()


def test_arc_rejects_remote_identity_endpoint(azure_env, monkeypatch):
    monkeypatch.setenv("RETAILTX_IDENTITY", "arc")
    monkeypatch.setenv("IDENTITY_ENDPOINT", "http://not-local/metadata/identity/oauth2/token")
    monkeypatch.setenv("IMDS_ENDPOINT", identity.ARC_IMDS_ENDPOINT)
    with pytest.raises(ValueError, match="localhost:40342"):
        Settings.from_env()
