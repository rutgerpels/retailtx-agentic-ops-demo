from typing import Protocol

from azure.servicebus import ServiceBusMessage
from azure.servicebus.exceptions import ServiceBusError

from retailtx.contracts import Posting
from retailtx.db import DatabaseTarget, connect
from retailtx.telemetry import SpanKind, carrier, event, propagator, tracer

MAX_ATTEMPTS = 8


class Sender(Protocol):
    def send_messages(self, message: ServiceBusMessage, *, timeout: float) -> None: ...


def publish_one(dsn: DatabaseTarget, sender: Sender) -> bool:
    # Holding the row lock across a bounded send makes process death release the claim.
    # A send/commit ambiguity is intentionally resolved by redelivery, never data deletion.
    with connect(dsn) as conn:
        row = conn.execute(
            """
            SELECT o.transaction_id, o.trace_context, o.attempts, a.posting
            FROM outbox o JOIN accepted_transactions a USING (transaction_id)
            WHERE o.state = 'pending' AND o.next_attempt_at <= clock_timestamp()
            ORDER BY o.next_attempt_at, a.sequence
            LIMIT 1 FOR UPDATE OF o SKIP LOCKED
            """
        ).fetchone()
        if row is None:
            return False
        posting = Posting.model_validate(row["posting"])
        with tracer.start_as_current_span(
            "outbox.publish",
            kind=SpanKind.PRODUCER,
            context=propagator.extract(row["trace_context"]),
            record_exception=False,
            set_status_on_exception=False,
        ):
            message = ServiceBusMessage(
                posting.model_dump_json(),
                message_id=str(posting.transaction_id),
                content_type="application/json",
                application_properties={key: value for key, value in carrier().items()},
            )
            try:
                sender.send_messages(message, timeout=5)
            except ServiceBusError as exc:
                attempts = row["attempts"] + 1
                state = "blocked" if attempts >= MAX_ATTEMPTS else "pending"
                conn.execute(
                    """
                    UPDATE outbox SET state = %s, attempts = %s, last_error = %s,
                        next_attempt_at = clock_timestamp() + %s * interval '1 second'
                    WHERE transaction_id = %s
                    """,
                    (
                        state,
                        attempts,
                        type(exc).__name__,
                        min(30, 2**attempts),
                        posting.transaction_id,
                    ),
                )
                event(
                    "outbox.failed",
                    transaction_id=posting.transaction_id,
                    attempts=attempts,
                    state=state,
                    error=type(exc).__name__,
                )
            else:
                conn.execute(
                    "UPDATE outbox SET state = 'sent', sent_at = clock_timestamp(), "
                    "attempts = attempts + 1, last_error = NULL WHERE transaction_id = %s",
                    (posting.transaction_id,),
                )
                event("outbox.sent", transaction_id=posting.transaction_id)
    return True
