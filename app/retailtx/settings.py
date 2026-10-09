import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from azure.identity import ManagedIdentityCredential
from psycopg.conninfo import make_conninfo

from retailtx.db import DatabaseTarget, EntraPostgres
from retailtx.identity import managed_identity, validate_identity


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value.strip():
        raise ValueError(f"Azure mode requires {name}; local defaults are not permitted")
    return value


def existing_file(name: str) -> str:
    value = required(name)
    if not Path(value).is_file():
        raise ValueError(f"{name} must identify a readable installed file")
    return value


def https_url(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError("Azure application endpoints must be HTTPS origins without credentials")
    return value.rstrip("/")


@dataclass(frozen=True)
class Settings:
    _cap_dsn: str | None
    _erp_dsn: str | None
    erp_url: str
    cap_url: str
    broker_host: str
    mode: str = "local"
    environment_id: str = "local"
    identity_kind: str = ""
    tls_ca_file: str = ""
    tls_cert_file: str = ""
    tls_key_file: str = ""
    applicationinsights_connection_string: str = ""

    @property
    def credential(self) -> ManagedIdentityCredential:
        if self.mode != "azure":
            raise ValueError("Managed identity is only available in Azure mode")
        return managed_identity(self.identity_kind)

    @property
    def cap_dsn(self) -> DatabaseTarget:
        if self._cap_dsn is None:
            raise ValueError("This command requires CAP_DB_HOST and cloud CAP database settings")
        if self.mode == "azure":
            return EntraPostgres(self._cap_dsn, self.credential)
        return self._cap_dsn

    @property
    def erp_dsn(self) -> str:
        if self._erp_dsn is None:
            raise ValueError("This command requires ERP_DB_HOST on the DC host (peer socket)")
        return self._erp_dsn

    @classmethod
    def from_env(cls) -> "Settings":
        mode = os.environ.get("RETAILTX_MODE")
        if mode == "azure":
            return cls._azure()
        if mode != "local":
            raise ValueError("Set RETAILTX_MODE explicitly to local or azure")
        host = os.environ.get("BROKER_HOST", "servicebus")
        if host not in {"servicebus", "localhost", "127.0.0.1"}:
            raise ValueError("Only the local Service Bus emulator is supported")

        def dsn(prefix: str, default_host: str) -> str:
            return make_conninfo(
                host=os.environ.get(f"{prefix}_DB_HOST", default_host),
                dbname="retailtx",
                user="retailtx",
                password=os.environ[f"{prefix}_DB_PASSWORD"],
                connect_timeout=3,
                options="-c statement_timeout=10000 -c lock_timeout=3000",
            )

        return cls(
            _cap_dsn=dsn("CAP", "cap-db"),
            _erp_dsn=dsn("ERP", "erp-db"),
            erp_url=os.environ.get("ERP_URL", "http://erp-core:8000"),
            cap_url=os.environ.get("CAP_URL", "http://cap-api:8000"),
            broker_host=host,
        )

    @classmethod
    def _azure(cls) -> "Settings":
        environment_id = required("RETAILTX_ENVIRONMENT_ID")
        if not re.fullmatch(r"[a-z][a-z0-9-]{2,23}", environment_id):
            raise ValueError("RETAILTX_ENVIRONMENT_ID must be a bounded neutral environment name")
        identity_kind = required("RETAILTX_IDENTITY")
        validate_identity(identity_kind)
        if any(
            os.environ.get(key)
            for key in (
                "CAP_DB_PASSWORD",
                "ERP_DB_PASSWORD",
                "PGPASSWORD",
                "PGSERVICE",
                "PGSERVICEFILE",
                "SERVICEBUS_CONNECTION_STRING",
            )
        ):
            raise ValueError("Azure mode does not accept database passwords or broker shared keys")
        namespace = required("BROKER_NAMESPACE")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.servicebus\.windows\.net", namespace):
            raise ValueError("BROKER_NAMESPACE must be an Azure Service Bus namespace FQDN")
        cap_dsn = None
        if os.environ.get("CAP_DB_HOST"):
            host = required("CAP_DB_HOST")
            if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.postgres\.database\.azure\.com", host):
                raise ValueError("CAP_DB_HOST must be an Azure PostgreSQL server FQDN")
            cap_dsn = make_conninfo(
                host=host,
                port=5432,
                dbname=os.environ.get("CAP_DB_NAME", "retailtx"),
                user=required("CAP_DB_USER"),
                sslmode="verify-full",
                sslrootcert=existing_file("CAP_DB_SSLROOTCERT"),
                connect_timeout=5,
                options="-c statement_timeout=10000 -c lock_timeout=3000",
            )
        erp_dsn = None
        if os.environ.get("ERP_DB_HOST"):
            host = required("ERP_DB_HOST")
            if not host.startswith("/") or "," in host:
                raise ValueError("ERP_DB_HOST must be a local UNIX socket directory for peer auth")
            erp_dsn = make_conninfo(
                host=host,
                port=5432,
                dbname=os.environ.get("ERP_DB_NAME", "retailtx"),
                user=required("ERP_DB_USER"),
                sslmode="disable",
                connect_timeout=3,
                options="-c statement_timeout=10000 -c lock_timeout=3000",
            )
        return cls(
            _cap_dsn=cap_dsn,
            _erp_dsn=erp_dsn,
            erp_url=https_url(required("ERP_URL")),
            cap_url=https_url(required("CAP_URL")),
            broker_host=namespace,
            mode="azure",
            environment_id=environment_id,
            identity_kind=identity_kind,
            tls_ca_file=existing_file("TLS_CA_FILE"),
            tls_cert_file=existing_file("TLS_CERT_FILE"),
            tls_key_file=existing_file("TLS_KEY_FILE"),
            applicationinsights_connection_string=required("APPLICATIONINSIGHTS_CONNECTION_STRING"),
        )

    @property
    def emulator_connection(self) -> str:
        if self.mode != "local":
            raise ValueError("The emulator connection is forbidden in Azure mode")
        # This documented placeholder is not an Azure credential.
        return (
            f"Endpoint=sb://{self.broker_host};SharedAccessKeyName=RootManageSharedAccessKey;"
            "SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;"
        )
