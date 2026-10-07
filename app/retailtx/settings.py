import os
from dataclasses import dataclass

from psycopg.conninfo import make_conninfo


@dataclass(frozen=True)
class Settings:
    cap_dsn: str
    erp_dsn: str
    erp_url: str
    cap_url: str
    broker_host: str

    @classmethod
    def from_env(cls) -> "Settings":
        if os.environ.get("RETAILTX_MODE") != "local":
            raise ValueError(
                "This release requires RETAILTX_MODE=local; Azure auth is not implemented"
            )
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
            cap_dsn=dsn("CAP", "cap-db"),
            erp_dsn=dsn("ERP", "erp-db"),
            erp_url=os.environ.get("ERP_URL", "http://erp-core:8000"),
            cap_url=os.environ.get("CAP_URL", "http://cap-api:8000"),
            broker_host=host,
        )

    @property
    def emulator_connection(self) -> str:
        # This documented placeholder is not an Azure credential.
        return (
            f"Endpoint=sb://{self.broker_host};SharedAccessKeyName=RootManageSharedAccessKey;"
            "SharedAccessKey=SAS_KEY_VALUE;UseDevelopmentEmulator=true;"
        )
