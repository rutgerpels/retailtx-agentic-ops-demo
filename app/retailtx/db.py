import hashlib
from pathlib import Path
from typing import Any

import psycopg
from psycopg.rows import dict_row


def connect(dsn: str) -> psycopg.Connection[dict[str, Any]]:
    return psycopg.connect(dsn, row_factory=dict_row)


def migrate(dsn: str, component: str) -> None:
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
