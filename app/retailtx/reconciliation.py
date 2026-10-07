from datetime import UTC, datetime
from typing import Any, TypedDict

import httpx
import psycopg
from psycopg.types.json import Jsonb
from pydantic import TypeAdapter, ValidationError

from retailtx.contracts import (
    BRANDS,
    COUNTRIES,
    Brand,
    Country,
    EvidenceUnavailable,
    Posting,
    euros,
)
from retailtx.db import connect
from retailtx.telemetry import SpanKind, carrier, event, tracer

INTERVAL_SECONDS = 5
STALE_SECONDS = 30
PAGE_SIZE = 100
POSTINGS = TypeAdapter(list[Posting])


class Bucket(TypedDict):
    country: Country
    brand: Brand
    accepted_count: int
    posted_count: int
    unposted_count: int
    unposted_cents: int
    unposted_eur: str
    oldest_unposted_age_seconds: float | None


def snapshot(
    conn: psycopg.Connection[dict[str, Any]], http: httpx.Client
) -> tuple[dict[str, Any], list[str], list[str]]:
    conn.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
    row = conn.execute(
        "SELECT coalesce(max(sequence), 0) AS watermark, clock_timestamp() AS observed_at "
        "FROM accepted_transactions"
    ).fetchone()
    assert row is not None
    observed = row["observed_at"]
    buckets: dict[tuple[Country, Brand], Bucket] = {
        (country, brand): {
            "country": country,
            "brand": brand,
            "accepted_count": 0,
            "posted_count": 0,
            "unposted_count": 0,
            "unposted_cents": 0,
            "unposted_eur": "0.00",
            "oldest_unposted_age_seconds": None,
        }
        for country in COUNTRIES
        for brand in BRANDS
    }
    unposted: list[str] = []
    posted: list[str] = []
    cursor = 0
    # Even an empty CAP snapshot needs live ERP evidence before it can report zero.
    http.get("/health", headers=carrier()).raise_for_status()
    while True:
        rows = conn.execute(
            "SELECT sequence, posting, accepted_at FROM accepted_transactions "
            "WHERE sequence > %s AND sequence <= %s ORDER BY sequence LIMIT %s",
            (cursor, row["watermark"], PAGE_SIZE),
        ).fetchall()
        if not rows:
            break
        expected = [Posting.model_validate(item["posting"]) for item in rows]
        response = http.post(
            "/ledger/lookup",
            json={"transaction_ids": [str(item.transaction_id) for item in expected]},
            headers=carrier(),
        )
        response.raise_for_status()
        found = POSTINGS.validate_python(response.json())
        postings = {item.transaction_id: item for item in found}
        wanted = {item.transaction_id for item in expected}
        if len(postings) != len(found) or not postings.keys() <= wanted:
            raise EvidenceUnavailable("ERP returned duplicate or unrequested identifiers")
        for item, accepted_row in zip(expected, rows, strict=True):
            bucket = buckets[(item.country, item.brand)]
            bucket["accepted_count"] += 1
            if item.transaction_id in postings:
                if item != postings[item.transaction_id]:
                    raise EvidenceUnavailable("ERP ledger does not match the accepted transaction")
                bucket["posted_count"] += 1
                posted.append(str(item.transaction_id))
            else:
                unposted.append(str(item.transaction_id))
                bucket["unposted_count"] += 1
                bucket["unposted_cents"] += item.amount_cents
                age = max(0, (observed - accepted_row["accepted_at"]).total_seconds())
                bucket["oldest_unposted_age_seconds"] = max(
                    bucket["oldest_unposted_age_seconds"] or 0, age
                )
        cursor = rows[-1]["sequence"]
    values = list(buckets.values())
    total = sum(item["unposted_cents"] for item in values)
    for bucket in values:
        bucket["unposted_eur"] = euros(bucket["unposted_cents"])
    return (
        {
            "observed_at": observed.isoformat(),
            "completed_at": datetime.now(UTC).isoformat(),
            "watermark": row["watermark"],
            "accepted_count": sum(item["accepted_count"] for item in values),
            "posted_count": sum(item["posted_count"] for item in values),
            "unposted_count": len(unposted),
            "unposted_cents": total,
            "unposted_eur": euros(total),
            "oldest_unposted_age_seconds": max(
                (
                    item["oldest_unposted_age_seconds"]
                    for item in values
                    if item["oldest_unposted_age_seconds"] is not None
                ),
                default=None,
            ),
            "by_country_brand": values,
        },
        unposted,
        posted,
    )


def reconcile(dsn: str, http: httpx.Client) -> dict[str, object]:
    attempted = datetime.now(UTC)
    with tracer.start_as_current_span(
        "reconciliation",
        kind=SpanKind.CLIENT,
        record_exception=False,
        set_status_on_exception=False,
    ):
        try:
            with connect(dsn) as conn:
                report, _, _ = snapshot(conn, http)
        except (httpx.HTTPError, ValidationError, ValueError, EvidenceUnavailable) as exc:
            with connect(dsn) as conn:
                conn.execute(
                    """
                    INSERT INTO reconciliation (singleton, attempted_at, error)
                    VALUES (true, %s, %s)
                    ON CONFLICT (singleton) DO UPDATE SET
                        attempted_at = EXCLUDED.attempted_at, error = EXCLUDED.error
                    WHERE reconciliation.attempted_at <= EXCLUDED.attempted_at
                    """,
                    (attempted, type(exc).__name__),
                )
            event("reconciliation.unavailable", error=type(exc).__name__)
        else:
            with connect(dsn) as conn:
                conn.execute(
                    """
                    INSERT INTO reconciliation
                        (singleton, attempted_at, last_success_at, last_success, error)
                    VALUES (true, %s, %s, %s, NULL)
                    ON CONFLICT (singleton) DO UPDATE SET
                        attempted_at = EXCLUDED.attempted_at,
                        last_success_at = EXCLUDED.last_success_at,
                        last_success = EXCLUDED.last_success, error = NULL
                    WHERE reconciliation.attempted_at <= EXCLUDED.attempted_at
                    """,
                    (attempted, report["observed_at"], Jsonb(report)),
                )
            event("reconciliation.observed", **report)
    return status(dsn)


def status(dsn: str) -> dict[str, object]:
    with connect(dsn) as conn:
        row = conn.execute("SELECT * FROM reconciliation").fetchone()
    if row is None:
        return {
            "status": "unknown",
            "current": None,
            "last_success": None,
            "last_success_at": None,
            "attempted_at": None,
            "expected_lag_seconds": INTERVAL_SECONDS,
            "error": "NotYetObserved",
        }
    state = "unknown"
    if row["last_success_at"] is not None:
        age = (datetime.now(UTC) - row["last_success_at"]).total_seconds()
        state = "fresh" if row["error"] is None and age <= STALE_SECONDS else "stale"
    return {
        "status": state,
        "current": row["last_success"] if state == "fresh" else None,
        "last_success": row["last_success"],
        "last_success_at": row["last_success_at"],
        "attempted_at": row["attempted_at"],
        "expected_lag_seconds": INTERVAL_SECONDS,
        "error": row["error"] or ("ObservationExpired" if state == "stale" else None),
    }


def replay_unposted(dsn: str, http: httpx.Client) -> int:
    with connect(dsn) as conn:
        report, ids, confirmed_ids = snapshot(conn, http)
    # A posting after the observation can only cause a harmless duplicate delivery.
    with connect(dsn) as conn:
        confirmed_count = 0
        if confirmed_ids:
            confirmed_count = conn.execute(
                "UPDATE outbox SET state = 'confirmed', confirmed_at = clock_timestamp(), "
                "last_error = NULL WHERE transaction_id = ANY(%s::uuid[]) AND state <> 'confirmed'",
                (confirmed_ids,),
            ).rowcount
        if ids:
            conn.execute(
                "UPDATE outbox SET state = 'pending', attempts = 0, "
                "next_attempt_at = clock_timestamp(), last_error = NULL "
                "WHERE transaction_id = ANY(%s::uuid[])",
                (ids,),
            )
        conn.execute(
            "INSERT INTO recovery_events (action, transaction_count) "
            "VALUES ('replay-unposted', %s)",
            (len(ids),),
        )
        conn.execute(
            "INSERT INTO recovery_events (action, transaction_count) VALUES ('confirm-posted', %s)",
            (confirmed_count,),
        )
    event(
        "outbox.replayed",
        transaction_count=len(ids),
        watermark=report["watermark"],
        confirmed_count=confirmed_count,
    )
    return len(ids)
