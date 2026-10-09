"""Offline checks for the source-release bridge, not evidence of Azure connectivity."""

import hashlib
import importlib.util
import io
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock
from zipfile import ZipFile

import pytest

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts" / "azure"


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


transport = load("guest_transport")
packaging = load("package_release")


def test_source_release_is_deterministic_and_excludes_environment(tmp_path):
    root = tmp_path / "source"
    root.mkdir()
    (root / "pyproject.toml").write_text("[project]\nname='demo'\n")
    (root / "requirements-dev.lock").write_text("")
    (root / "app").mkdir()
    (root / "app" / "main.py").write_text("print('synthetic')\n")
    (root / ".env").write_text("never include")
    first = tmp_path / "first.zip"
    second = tmp_path / "second.zip"
    assert packaging.package(root, first) == packaging.package(root, second)
    with ZipFile(first) as archive:
        assert set(archive.namelist()) == {"pyproject.toml", "requirements-dev.lock", "app/main.py"}
        assert all(entry.create_system == 3 for entry in archive.infolist())


def test_source_release_rejects_wrong_digest(tmp_path):
    archive = tmp_path / "source.zip"
    with ZipFile(archive, "w") as release:
        release.writestr("app.py", "pass")
    with pytest.raises(ValueError, match="digest"):
        transport.extract_release(archive, "0" * 64, tmp_path / "target")


@pytest.mark.parametrize("entry", ["../../outside.py", "/outside.py"])
def test_release_rejects_traversal(tmp_path, entry):
    archive = tmp_path / "source.zip"
    with ZipFile(archive, "w") as release:
        release.writestr(entry, "pass")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    with pytest.raises(ValueError, match="entry"):
        transport.extract_release(archive, digest, tmp_path / "target")


def test_release_extracts_verified_source(tmp_path):
    archive = tmp_path / "source.zip"
    with ZipFile(archive, "w") as release:
        release.writestr("app/main.py", "pass\n")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    target = tmp_path / "release"
    transport.extract_release(archive, digest, target)
    assert (target / "app" / "main.py").read_text() == "pass\n"


@pytest.mark.parametrize("address", ["127.0.0.1", "10.84.0.4", "20.1.2.3", "::1"])
def test_private_dns_rejects_foreign_addresses(monkeypatch, address):
    monkeypatch.setattr(
        transport.socket, "getaddrinfo", lambda *args: [(2, 1, 6, "", (address, 443))]
    )
    with pytest.raises(RuntimeError, match="private"):
        transport.private_addresses("example.invalid")


def test_private_dns_accepts_only_owned_networks(monkeypatch):
    monkeypatch.setattr(
        transport.socket,
        "getaddrinfo",
        lambda *args: [(2, 1, 6, "", ("10.86.1.4", 443)), (2, 1, 6, "", ("10.87.0.4", 443))],
    )
    assert transport.private_addresses("example.invalid") == ["10.86.1.4", "10.87.0.4"]


@pytest.mark.parametrize(
    "role,resource", [("local", "https://storage.azure.com/"), ("dc", "https://example.invalid")]
)
def test_bootstrap_identity_rejects_arbitrary_requests(role, resource):
    with pytest.raises(ValueError, match="Unsupported"):
        transport.token(role, resource)


def test_artifact_endpoint_rejects_arbitrary_host_before_token():
    with pytest.raises(ValueError, match="account"):
        transport.blob("cloud", "invalid.example/path", "releases/one.zip")


def test_artifact_endpoint_rejects_arbitrary_path_before_token():
    with pytest.raises(ValueError, match="path"):
        transport.blob("cloud", "validaccount", "releases/../../outside")


@pytest.mark.parametrize(
    "name,limit", [("releases/source.zip", 180_000), ("provisioning/dc/host.key", 20_000)]
)
def test_artifact_response_is_bounded(monkeypatch, name, limit):
    monkeypatch.setattr(transport, "private_addresses", lambda _: ["10.86.1.4"])
    monkeypatch.setattr(transport, "token", lambda *args: "synthetic")
    monkeypatch.setattr(
        transport.urllib.request, "urlopen", lambda *args, **kwargs: io.BytesIO(b"x" * (limit + 1))
    )
    with pytest.raises(ValueError, match="size bound"):
        transport.blob("cloud", "validaccount", name)


def test_tls_gate_rejects_unauthenticated_success(monkeypatch):
    monkeypatch.setitem(sys.modules, "guest_transport", transport)
    verifier = load("verify_guest")
    monkeypatch.setattr(verifier.ssl, "create_default_context", lambda **kwargs: object())
    monkeypatch.setattr(
        verifier.urllib.request, "urlopen", lambda *args, **kwargs: io.BytesIO(b"{}")
    )
    with pytest.raises(RuntimeError, match="without a client certificate"):
        verifier.require_client_certificate("cap.demo01.retailtx.internal")


def test_tls_gate_does_not_accept_network_failure_as_authentication(monkeypatch):
    monkeypatch.setitem(sys.modules, "guest_transport", transport)
    verifier = load("verify_guest")
    monkeypatch.setattr(verifier.ssl, "create_default_context", lambda **kwargs: object())

    def unreachable(*args, **kwargs):
        raise verifier.urllib.error.URLError("network unavailable")

    monkeypatch.setattr(verifier.urllib.request, "urlopen", unreachable)
    with pytest.raises(verifier.urllib.error.URLError):
        verifier.require_client_certificate("cap.demo01.retailtx.internal")


@pytest.mark.parametrize(
    "age_minutes,status,include_observation",
    [(6, "fresh", True), (0, "stale", True), (0, "fresh", False)],
)
def test_readiness_rejects_old_or_incomplete_reconciliation(
    monkeypatch, age_minutes, status, include_observation
):
    monkeypatch.setitem(sys.modules, "guest_transport", transport)
    verifier = load("verify_guest")
    observed = (datetime.now(UTC) - timedelta(minutes=age_minutes)).isoformat()
    rows = [["reconciliation.freshness", observed, "", status]]
    if include_observation:
        rows.append(["reconciliation.observed", observed, observed, ""])
    monkeypatch.setattr(verifier, "query", lambda *args: rows)
    config = {"environment": "demo01", "installedAt": observed, "arcMachineId": "synthetic"}
    with pytest.raises(verifier.ReadinessPending, match="reconciliation"):
        verifier.telemetry(config)


def test_services_remain_disabled_and_boot_gated_before_cleanup(monkeypatch, tmp_path):
    monkeypatch.setitem(sys.modules, "guest_transport", transport)
    if sys.platform == "win32":
        monkeypatch.setitem(sys.modules, "grp", SimpleNamespace())
    installer = load("install_guest")
    config_path = tmp_path / "config"
    config_path.mkdir()
    (config_path / "runtime-enabled").touch()
    monkeypatch.setattr(installer, "CONFIG", config_path)
    units = tmp_path / "units"
    units.mkdir()

    def local_path(value):
        if value.startswith("/opt/retailtx/"):
            return SimpleNamespace(
                is_symlink=lambda: False,
                symlink_to=lambda target: None,
                replace=lambda target: None,
            )
        if value.startswith("/etc/systemd/system/"):
            return units / Path(value).name
        raise AssertionError(value)

    monkeypatch.setattr(installer, "Path", local_path)
    monkeypatch.setattr(installer, "runtime_file", lambda path, content: path.write_bytes(content))
    commands = []
    monkeypatch.setattr(installer, "run", lambda *args: commands.append(args))
    release = tmp_path / "release"
    release.mkdir()
    installer.configure_services(
        {"role": "cloud", "runtimeEnv": {"RETAILTX_MODE": "azure"}}, release
    )
    assert not (config_path / "runtime-enabled").exists()
    for name in ("cap-api", "outbox-publisher", "recon-job"):
        assert ("systemctl", "disable", "--now", f"retailtx-{name}") in commands
        assert (
            "ConditionPathExists=/etc/retailtx/runtime-enabled"
            in (units / f"retailtx-{name}.service").read_text()
        )
    assert not any("enable" in command or "start" in command for command in commands)


@pytest.mark.parametrize("payload_size", [3892, 3893])
def test_guest_evidence_output_size_boundary(monkeypatch, capsys, payload_size):
    monkeypatch.setitem(sys.modules, "guest_transport", transport)
    verifier = load("verify_guest")
    monkeypatch.setattr(verifier, "Path", lambda _: SimpleNamespace(read_text=lambda: "{}"))
    monkeypatch.setattr(verifier, "doctor", lambda _: {"p": "x" * payload_size})
    monkeypatch.setattr(sys, "argv", ["verify_guest", "--operation", "doctor"])
    if payload_size == 3893:
        with pytest.raises(RuntimeError, match="output limit"):
            verifier.main()
        assert not capsys.readouterr().out
    else:
        verifier.main()
        assert len(capsys.readouterr().out.encode()) == 3901


@pytest.mark.parametrize("native_agent_active", [False, True])
def test_arc_posture_requires_blocked_imds_and_inactive_native_agent(
    monkeypatch, native_agent_active
):
    monkeypatch.setitem(sys.modules, "guest_transport", transport)
    verifier = load("verify_guest")
    monkeypatch.setattr(verifier, "Path", lambda _: SimpleNamespace(is_file=lambda: True))
    checked_addresses = []

    def run(command, **kwargs):
        if command[0] == "iptables":
            checked_addresses.append(command[4])
            return SimpleNamespace(returncode=0)
        if command[1] == "is-enabled":
            return SimpleNamespace(returncode=1, stdout="disabled\n")
        active = native_agent_active and command[-1] == "walinuxagent"
        return SimpleNamespace(returncode=0 if active else 3)

    monkeypatch.setattr(verifier.subprocess, "run", run)
    if native_agent_active:
        with pytest.raises(RuntimeError, match="active Azure guest agent"):
            verifier.host_posture({"role": "dc"})
    else:
        assert verifier.host_posture({"role": "dc"})["azure_imds"] == "blocked"
    assert checked_addresses == ["169.254.169.254", "169.254.169.253"]


def test_migration_retires_temporary_ownership_before_using_stable_owner(monkeypatch):
    import psycopg
    from psycopg.conninfo import conninfo_to_dict
    from retailtx import db

    monkeypatch.setitem(sys.modules, "guest_transport", transport)
    if sys.platform == "win32":
        monkeypatch.setitem(sys.modules, "grp", SimpleNamespace())
    installer = load("install_guest")
    monkeypatch.setattr(installer, "token", lambda *args: "synthetic")
    statements = []
    connections = []

    def connect(**kwargs):
        connections.append(kwargs)
        connection = MagicMock()
        connection.__enter__.return_value = connection

        def execute(statement, *args):
            text = statement if isinstance(statement, str) else statement.as_string()
            statements.append((kwargs["dbname"], text))
            return SimpleNamespace(fetchone=lambda: (1,))

        connection.execute.side_effect = execute
        return connection

    monkeypatch.setattr(psycopg, "connect", connect)
    migrations = []
    monkeypatch.setattr(db, "migrate", lambda dsn, kind: migrations.append((dsn, kind)))
    installer.migrate_databases(
        {
            "role": "cloud",
            "postgresHost": "synthetic.postgres.database.azure.com",
            "databaseAdminName": "temporary-admin",
            "databaseAdminClientId": "synthetic",
            "cloudPrincipalId": "synthetic",
        }
    )
    for database in ("postgres", "retailtx"):
        reassign = statements.index(
            (database, 'REASSIGN OWNED BY "temporary-admin" TO azure_pg_admin')
        )
        assert statements[reassign + 1] == (
            database, 'DROP OWNED BY "temporary-admin" RESTRICT'
        )
    assert conninfo_to_dict(migrations[0][0])["options"] == "-c role=azure_pg_admin"
    assert connections[-1]["options"] == "-c role=azure_pg_admin"


def test_trace_gate_includes_pinned_framework_endpoint_parentage(monkeypatch):
    monkeypatch.setitem(sys.modules, "guest_transport", transport)
    verifier = load("verify_guest")
    queries = []

    def query(config, kql):
        queries.append(kql)
        return [[12]]

    monkeypatch.setattr(verifier, "query", query)
    result = verifier.traces(
        {"environment": "demo01"}, "11111111-2222-4333-8444-555555555555"
    )
    assert result["parent_edges_per_trace"] == 9
    assert result["verified_transactions"] == 12
    assert "'cap-api', 'POST /transaction', 'cap-api', 'fastapi.endpoint'" in queries[0]
    assert "'cap-api', 'fastapi.endpoint', 'cap-api', 'checkout'" in queries[0]
    assert "EventKinds == 5 and EdgeKinds == 9" in queries[0]
