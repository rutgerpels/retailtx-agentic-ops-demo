import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, TypeAlias

import psycopg
from azure.core.credentials import TokenCredential
from psycopg.rows import dict_row

POSTGRES_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


@dataclass(frozen=True)
class EntraPostgres:
    conninfo: str
    credential: TokenCredential = field(repr=False)


DatabaseTarget: TypeAlias = str | EntraPostgres


def connect(dsn: DatabaseTarget) -> psycopg.Connection[dict[str, Any]]:
    if isinstance(dsn, EntraPostgres):
        return psycopg.connect(
            dsn.conninfo,
            password=dsn.credential.get_token(POSTGRES_SCOPE).token,
            row_factory=dict_row,
        )
    return psycopg.connect(dsn, row_factory=dict_row)


def migrate(dsn: DatabaseTarget, component: str) -> None:
    if component not in {"cap", "erp"}:
        raise ValueError("Unknown database component")
    with connect(dsn) as conn:
        conn.execute("SELECT pg_advisory_xact_lock(7219401)")
        conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations "
            "(name text PRIMARY KEY, checksum text NOT NULL)"
        )
        for path in sorted((Path(__file__).parent / "migrations" / component).glob("*.sql")):
            sql = path.read_text(encoding="utf-8")
            checksum = hashlib.sha256(sql.encode()).hexdigest()
            previous = conn.execute(
                "SELECT checksum FROM schema_migrations WHERE name = %s", (path.name,)
            ).fetchone()
            if previous:
                if previous["checksum"] != checksum:
                    raise RuntimeError(f"Applied migration was modified: {component}/{path.name}")
                continue
            conn.execute(sql)
            conn.execute("INSERT INTO schema_migrations VALUES (%s, %s)", (path.name, checksum))
