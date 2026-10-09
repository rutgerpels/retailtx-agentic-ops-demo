from collections.abc import Callable
from uuid import UUID

from psycopg.types.json import Jsonb

from retailtx.contracts import Checkout, Conflict, EvidenceUnavailable, Posting, Price
from retailtx.db import DatabaseTarget, connect
from retailtx.telemetry import carrier, event


def accepted(dsn: DatabaseTarget, request: Checkout) -> Posting | None:
    with connect(dsn) as conn:
        row = conn.execute(
            "SELECT request, posting FROM accepted_transactions WHERE transaction_id = %s",
            (request.transaction_id,),
        ).fetchone()
    if row is None:
        return None
    if row["request"] != request.model_dump(mode="json"):
        raise Conflict("Transaction ID already belongs to a different checkout")
    return Posting.model_validate(row["posting"])


def accept(dsn: DatabaseTarget, request: Checkout, lookup: Callable[[], Price]) -> Posting:
    previous = accepted(dsn, request)
    if previous is not None:
        return previous
    price = lookup()
    if price.sku != request.sku:
        raise EvidenceUnavailable("ERP returned a price for a different SKU")
    posting = Posting(
        **request.model_dump(),
        unit_price_cents=price.unit_price_cents,
        amount_cents=price.unit_price_cents * request.quantity,
    )
    with connect(dsn) as conn:
        inserted = conn.execute(
            """
            INSERT INTO accepted_transactions
                (transaction_id, country, brand, amount_cents, request, posting)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (transaction_id) DO NOTHING RETURNING transaction_id
            """,
            (
                request.transaction_id,
                request.country,
                request.brand,
                posting.amount_cents,
                Jsonb(request.model_dump(mode="json")),
                Jsonb(posting.model_dump(mode="json")),
            ),
        ).fetchone()
        if inserted:
            conn.execute(
                "INSERT INTO outbox (transaction_id, trace_context) VALUES (%s, %s)",
                (request.transaction_id, Jsonb(carrier())),
            )
        else:
            row = conn.execute(
                "SELECT request, posting FROM accepted_transactions WHERE transaction_id = %s",
                (request.transaction_id,),
            ).fetchone()
            assert row is not None
            if row["request"] != request.model_dump(mode="json"):
                raise Conflict("Transaction ID already belongs to a different checkout")
            posting = Posting.model_validate(row["posting"])
    event(
        "transaction.accepted",
        transaction_id=request.transaction_id,
        country=request.country,
        brand=request.brand,
        amount_cents=posting.amount_cents,
    )
    return posting


def post(dsn: DatabaseTarget, posting: Posting) -> Posting:
    with connect(dsn) as conn:
        conn.execute(
            """
            INSERT INTO ledger (transaction_id, posting, amount_cents) VALUES (%s, %s, %s)
            ON CONFLICT (transaction_id) DO NOTHING
            """,
            (posting.transaction_id, Jsonb(posting.model_dump(mode="json")), posting.amount_cents),
        )
        row = conn.execute(
            "SELECT posting FROM ledger WHERE transaction_id = %s", (posting.transaction_id,)
        ).fetchone()
        assert row is not None
        if row["posting"] != posting.model_dump(mode="json"):
            raise Conflict("Ledger transaction ID already has different immutable data")
    event(
        "ledger.committed",
        transaction_id=posting.transaction_id,
        country=posting.country,
        brand=posting.brand,
        amount_cents=posting.amount_cents,
    )
    return posting


def ledger_lookup(dsn: DatabaseTarget, ids: list[UUID]) -> list[Posting]:
    with connect(dsn) as conn:
        rows = conn.execute(
            "SELECT posting FROM ledger WHERE transaction_id = ANY(%s)", (ids,)
        ).fetchall()
    return [Posting.model_validate(row["posting"]) for row in rows]
