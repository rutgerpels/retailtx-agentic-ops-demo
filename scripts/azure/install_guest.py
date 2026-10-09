"""Install one hash-locked release through the owned Azure guest bridge."""

import argparse
import base64
import grp
import json
import os
import re
import shlex
import subprocess
from pathlib import Path

from guest_transport import blob, extract_release, token

ROOT = Path("/var/lib/retailtx")
CONFIG = Path("/etc/retailtx")


def run(*args: str, user: str | None = None, input_text: str | None = None) -> None:
    command = (["runuser", "-u", user, "--"] if user else []) + list(args)
    completed = subprocess.run(
        command, input=input_text, text=True, capture_output=True, timeout=1200
    )
    if completed.returncode:
        # Installation commands contain no tokens/password arguments; do not print captured SQL.
        raise RuntimeError(f"{args[0]} failed ({completed.returncode}): {completed.stderr[-2000:]}")


def runtime_file(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    os.chown(path, 0, grp.getgrnam("retailtx").gr_gid)
    path.chmod(0o640)


def configure_tls(config: dict) -> None:
    role = config["role"]
    storage = config["storageAccount"]
    ca = ROOT / "certificate-authority"
    if role == "cloud":
        ca.mkdir(mode=0o700, exist_ok=True)
        if not (ca / "ca.crt").exists():
            run(
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:3072",
                "-nodes",
                "-keyout",
                str(ca / "ca.key"),
                "-out",
                str(ca / "ca.crt"),
                "-days",
                "365",
                "-subj",
                "/CN=RetailTx isolated demo",
            )
            (ca / "ca.key").chmod(0o600)
        for host, dns in (("cloud", config["capHost"]), ("dc", config["erpHost"])):
            if not (ca / f"{host}.crt").exists():
                extensions = ca / f"{host}.ext"
                extensions.write_text(
                    f"subjectAltName=DNS:{dns}\nextendedKeyUsage=serverAuth,clientAuth\n"
                    "keyUsage=digitalSignature,keyEncipherment\nbasicConstraints=CA:FALSE\n"
                )
                run(
                    "openssl",
                    "req",
                    "-newkey",
                    "rsa:3072",
                    "-nodes",
                    "-keyout",
                    str(ca / f"{host}.key"),
                    "-out",
                    str(ca / f"{host}.csr"),
                    "-subj",
                    f"/CN={dns}",
                )
                (ca / f"{host}.key").chmod(0o600)
                run(
                    "openssl",
                    "x509",
                    "-req",
                    "-in",
                    str(ca / f"{host}.csr"),
                    "-CA",
                    str(ca / "ca.crt"),
                    "-CAkey",
                    str(ca / "ca.key"),
                    "-CAcreateserial",
                    "-out",
                    str(ca / f"{host}.crt"),
                    "-days",
                    "30",
                    "-extfile",
                    str(extensions),
                )
            run("openssl", "x509", "-checkend", "3600", "-noout", "-in", str(ca / f"{host}.crt"))
        for source, name in (("ca.crt", "ca.crt"), ("dc.crt", "host.crt"), ("dc.key", "host.key")):
            blob(role, storage, f"provisioning/dc/{name}", (ca / source).read_bytes())
        for source, name in (
            ("ca.crt", "ca.crt"),
            ("cloud.crt", "host.crt"),
            ("cloud.key", "host.key"),
        ):
            runtime_file(CONFIG / "tls" / name, (ca / source).read_bytes())
    else:
        for name in ("ca.crt", "host.crt", "host.key"):
            runtime_file(CONFIG / "tls" / name, blob(role, storage, f"provisioning/dc/{name}"))
    run("openssl", "verify", "-CAfile", str(CONFIG / "tls/ca.crt"), str(CONFIG / "tls/host.crt"))


def migrate_databases(config: dict) -> None:
    import psycopg
    from psycopg import sql
    from psycopg.conninfo import make_conninfo
    from retailtx.db import migrate

    if config["role"] == "cloud":
        common = {
            "host": config["postgresHost"],
            "user": config["databaseAdminName"],
            "password": token(
                "cloud",
                "https://ossrdbms-aad.database.windows.net",
                config["databaseAdminClientId"],
            ),
            "sslmode": "verify-full",
            "sslrootcert": "/etc/ssl/certs/ca-certificates.crt",
            "connect_timeout": 10,
        }
        with psycopg.connect(**common, dbname="postgres") as conn:
            exists = conn.execute(
                "SELECT 1 FROM pg_roles WHERE rolname = %s", ("retailtx-cap",)
            ).fetchone()
            if not exists:
                conn.execute(
                    "SELECT * FROM pgaadauth_create_principal_with_oid"
                    "(%s, %s, 'service', false, false)",
                    ("retailtx-cap", config["cloudPrincipalId"]),
                )
        # Preserve existing objects before removing dependencies on the temporary login.
        for database in ("postgres", "retailtx"):
            with psycopg.connect(**common, dbname=database) as conn:
                conn.execute(
                    sql.SQL("REASSIGN OWNED BY {} TO azure_pg_admin").format(
                        sql.Identifier(config["databaseAdminName"])
                    )
                )
                conn.execute(
                    sql.SQL("DROP OWNED BY {} RESTRICT").format(
                        sql.Identifier(config["databaseAdminName"])
                    )
                )
        owner = {**common, "options": "-c role=azure_pg_admin"}
        migrate(make_conninfo(**owner, dbname="retailtx"), "cap")
        with psycopg.connect(**owner, dbname="retailtx") as conn:
            conn.execute('GRANT CONNECT ON DATABASE retailtx TO "retailtx-cap"')
            conn.execute('GRANT USAGE ON SCHEMA public TO "retailtx-cap"')
            conn.execute(
                'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO "retailtx-cap"'
            )
            conn.execute('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "retailtx-cap"')
    else:
        run(
            "psql",
            "-v",
            "ON_ERROR_STOP=1",
            "-d",
            "postgres",
            "-c",
            "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='retailtx') "
            "THEN CREATE ROLE retailtx LOGIN; END IF; END $$;",
            user="postgres",
        )
        query = subprocess.run(
            [
                "runuser",
                "-u",
                "postgres",
                "--",
                "psql",
                "-At",
                "-d",
                "postgres",
                "-c",
                "SELECT 1 FROM pg_database WHERE datname='retailtx'",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if query.stdout.strip() != "1":
            run("createdb", "--owner=postgres", "retailtx", user="postgres")
        release = Path(__file__).resolve().parents[2]
        run(
            str(release / ".venv/bin/python"),
            "-c",
            "from retailtx.db import migrate; "
            "migrate('host=/var/run/postgresql dbname=retailtx user=postgres', 'erp')",
            user="postgres",
        )
        run(
            "psql",
            "-v",
            "ON_ERROR_STOP=1",
            "-d",
            "retailtx",
            "-c",
            "GRANT CONNECT ON DATABASE retailtx TO retailtx; "
            "GRANT USAGE ON SCHEMA public TO retailtx; "
            "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO retailtx; "
            "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO retailtx;",
            user="postgres",
        )


def configure_services(config: dict, release: Path) -> None:
    (CONFIG / "runtime-enabled").unlink(missing_ok=True)
    environment = config["runtimeEnv"]
    if any(not re.fullmatch(r"[A-Z][A-Z0-9_]+", key) for key in environment):
        raise ValueError("Invalid runtime environment key")
    if any(
        not isinstance(value, str) or "\n" in value or "\r" in value
        for value in environment.values()
    ):
        raise ValueError("Invalid runtime environment value")
    runtime_file(
        CONFIG / "runtime.env",
        "".join(f"{key}={shlex.quote(value)}\n" for key, value in environment.items()).encode(),
    )
    runtime_file(CONFIG / "deployment.json", json.dumps(config).encode())
    current = Path("/opt/retailtx/current")
    temporary = Path("/opt/retailtx/current.new")
    if temporary.is_symlink():
        temporary.unlink()
    temporary.symlink_to(release)
    temporary.replace(current)
    services = (
        {"cap-api": "api", "outbox-publisher": "worker", "recon-job": "worker"}
        if config["role"] == "cloud"
        else {"erp-core": "api", "erp-poster": "worker"}
    )
    for name, kind in services.items():
        if kind == "api":
            module = "retailtx.cap_api" if name == "cap-api" else "retailtx.erp_core"
            command = (
                f"/opt/retailtx/current/.venv/bin/python -m uvicorn {module}:create_app "
                "--factory --host 0.0.0.0 --port 8443 "
                "--ssl-keyfile /etc/retailtx/tls/host.key "
                "--ssl-certfile /etc/retailtx/tls/host.crt "
                "--ssl-ca-certs /etc/retailtx/tls/ca.crt --ssl-cert-reqs 2 --no-access-log"
            )
        else:
            command = f"/opt/retailtx/current/.venv/bin/python -m retailtx.runtime {name}"
        unit = (
            "[Unit]\nDescription=RetailTx " + name + "\nAfter=network-online.target\n"
            "ConditionPathExists=/etc/retailtx/runtime-enabled\n"
            "[Service]\nUser=retailtx\nGroup=retailtx\n"
            + ("SupplementaryGroups=himds\n" if config["role"] == "dc" else "")
            + "EnvironmentFile=/etc/retailtx/runtime.env\nWorkingDirectory=/opt/retailtx/current\n"
            f"ExecStart={command}\nRestart=on-failure\nRestartSec=5\nTimeoutStopSec=30\n"
            "NoNewPrivileges=true\nProtectSystem=strict\nProtectHome=true\nPrivateTmp=true\n"
            "ReadWritePaths=/var/lib/retailtx-app\n"
            "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX\n"
            "[Install]\nWantedBy=multi-user.target\n"
        )
        Path(f"/etc/systemd/system/retailtx-{name}.service").write_text(unit)
    run("systemctl", "daemon-reload")
    for name in services:
        run("systemctl", "disable", "--now", f"retailtx-{name}")


def main() -> None:
    os.umask(0o022)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--phase", choices=["install", "configure", "cleanup"], default="install")
    args = parser.parse_args()
    config = json.loads(base64.b64decode(args.config))
    if config["role"] not in {"cloud", "dc"} or not re.fullmatch(
        r"[a-f0-9]{64}", config["releaseSha"]
    ):
        raise ValueError("Invalid guest installation identity")
    if not (ROOT / "bootstrap-complete").exists():
        raise RuntimeError("Initial host bootstrap is incomplete")
    release = Path("/opt/retailtx/releases") / config["releaseSha"]
    if args.phase == "cleanup":
        if config["role"] != "cloud":
            raise ValueError("Provisioning cleanup must run on the cloud host")
        for name in ("ca.crt", "host.crt", "host.key"):
            blob("cloud", config["storageAccount"], f"provisioning/dc/{name}", delete=True)
    elif args.phase == "install":
        archive = ROOT / "release.zip"
        if config["role"] == "dc":
            archive.write_bytes(
                blob("dc", config["storageAccount"], f"releases/{config['releaseSha']}.zip")
            )
        extract_release(archive, config["releaseSha"], release)
        run("python3", "-m", "venv", str(release / ".venv"))
        python = str(release / ".venv/bin/python")
        run(
            python,
            "-m",
            "pip",
            "install",
            "--quiet",
            "--require-hashes",
            "-r",
            str(release / "requirements-dev.lock"),
        )
        run(
            python,
            "-m",
            "pip",
            "install",
            "--quiet",
            "--no-deps",
            "--no-build-isolation",
            str(release),
        )
        if config["role"] == "cloud":
            blob(
                "cloud",
                config["storageAccount"],
                f"releases/{config['releaseSha']}.zip",
                archive.read_bytes(),
            )
        run(
            python,
            str(release / "scripts/azure/install_guest.py"),
            "--config",
            args.config,
            "--phase",
            "configure",
        )
    else:
        configure_tls(config)
        migrate_databases(config)
        configure_services(config, release)
        (ROOT / "installed-release").write_text(config["releaseSha"])
    print(json.dumps({"installed": True, "role": config["role"], "release": config["releaseSha"]}))


if __name__ == "__main__":
    main()
