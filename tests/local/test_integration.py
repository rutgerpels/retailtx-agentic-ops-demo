import json
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import httpx
import psycopg
import pytest
from azure.servicebus import ServiceBusMessage, ServiceBusSubQueue
from azure.servicebus.exceptions import ServiceBusError
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
from psycopg.types.json import Jsonb
from retailtx import broker, fault, storage
from retailtx.contracts import PRICES, Checkout, Conflict, Price
from retailtx.db import connect, migrate
from retailtx.poster import handle_message, message_context
from retailtx.publisher import MAX_ATTEMPTS, publish_one
from retailtx.reconciliation import reconcile, replay_unposted, status
from retailtx.telemetry import propagator

from sim.pos_sim import dataset

pytestmark = pytest.mark.integration


def checkout_request():
    return Checkout(
        transaction_id=uuid4(), country="NL", brand="market", sku="basket-a", quantity=3
    )


def accept(stack, request=None):
    row = request or checkout_request()
    return storage.accept(
        stack.cap_dsn, row, lambda: Price(sku=row.sku, unit_price_cents=PRICES[row.sku])
    )


def counts(stack):
    with connect(stack.cap_dsn) as conn:
        accepted = conn.execute("SELECT count(*) AS n FROM accepted_transactions").fetchone()["n"]
        outbox = conn.execute("SELECT count(*) AS n FROM outbox").fetchone()["n"]
    with connect(stack.erp_dsn) as conn:
        ledger = conn.execute("SELECT count(*) AS n FROM ledger").fetchone()["n"]
    return accepted, outbox, ledger


def receive(receiver):
    messages = receiver.receive_messages(max_message_count=1, max_wait_time=5)
    assert len(messages) == 1
    return messages[0]


class Crash(BaseException):
    pass


def test_migrations_repeat_without_changing_data(stack):
    posting = accept(stack)
    migrate(stack.cap_dsn, "cap")
    migrate(stack.erp_dsn, "erp")
    assert (
        storage.accepted(
            stack.cap_dsn,
            Checkout(
                **{
                    key: value
                    for key, value in posting.model_dump().items()
                    if key in Checkout.model_fields
                }
            ),
        )
        == posting
    )


def test_acceptance_and_outbox_rollback_together(stack):
    with connect(stack.cap_dsn) as conn:
        conn.execute(
            "CREATE FUNCTION reject_outbox() RETURNS trigger LANGUAGE plpgsql AS "
            "$$ BEGIN RAISE EXCEPTION 'injected pre-commit failure'; END $$"
        )
        conn.execute(
            "CREATE TRIGGER reject_outbox BEFORE INSERT ON outbox "
            "FOR EACH ROW EXECUTE FUNCTION reject_outbox()"
        )
    try:
        with pytest.raises(psycopg.errors.RaiseException):
            accept(stack)
        assert counts(stack) == (0, 0, 0)
    finally:
        with connect(stack.cap_dsn) as conn:
            conn.execute("DROP TRIGGER reject_outbox ON outbox")
            conn.execute("DROP FUNCTION reject_outbox()")


def test_lost_acceptance_response_and_concurrent_retry(stack):
    request = checkout_request()
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: accept(stack, request), range(16)))
    assert len(set(item.model_dump_json() for item in results)) == 1
    assert counts(stack) == (1, 1, 0)

    # Retrying after a lost response does not need the price service.
    def unavailable_price():
        raise AssertionError("ERP should not be called for an accepted retry")

    assert storage.accept(stack.cap_dsn, request, unavailable_price) == results[0]
    with pytest.raises(Conflict):
        accept(stack, request.model_copy(update={"quantity": 4}))


def test_known_dataset_stop_resume_exact_country_totals(stack, erp):
    rows = dataset("acceptance", 12)
    for row in rows:
        response = httpx.post(
            f"{stack.cap_url}/transaction", json=row.model_dump(mode="json"), timeout=5
        )
        assert response.status_code == 202
        assert (
            httpx.post(
                f"{stack.cap_url}/transaction", json=row.model_dump(mode="json"), timeout=5
            ).json()
            == response.json()
        )
    before = reconcile(stack.cap_dsn, erp)
    assert before["status"] == "fresh"
    report = before["current"]
    assert (report["accepted_count"], report["posted_count"], report["unposted_cents"]) == (
        12,
        0,
        4848,
    )
    by_country = {}
    for bucket in report["by_country_brand"]:
        by_country[bucket["country"]] = (
            by_country.get(bucket["country"], 0) + bucket["unposted_cents"]
        )
    assert by_country == {"NL": 1494, "BE": 2409, "DE": 630, "FR": 315}
    with (
        broker.client(stack) as bus,
        bus.get_queue_sender(broker.QUEUE) as sender,
        bus.get_queue_receiver(broker.QUEUE, max_wait_time=5) as receiver,
    ):
        for _ in rows:
            assert publish_one(stack.cap_dsn, sender)
        assert not publish_one(stack.cap_dsn, sender)
        for _ in rows:
            assert handle_message(receiver, receive(receiver), erp)
    after = reconcile(stack.cap_dsn, erp)["current"]
    assert (after["accepted_count"], after["posted_count"], after["unposted_cents"]) == (12, 12, 0)
    assert counts(stack) == (12, 12, 12)
    with connect(stack.cap_dsn) as cap, connect(stack.erp_dsn) as ledger:
        accepted = cap.execute(
            "SELECT transaction_id, posting FROM accepted_transactions"
        ).fetchall()
        posted = ledger.execute("SELECT transaction_id, posting FROM ledger").fetchall()
    assert {str(row["transaction_id"]): row["posting"] for row in accepted} == {
        str(row["transaction_id"]): row["posting"] for row in posted
    }


def test_send_ack_before_outbox_commit_redelivers_safely(stack, erp):
    accept(stack)
    with (
        broker.client(stack) as bus,
        bus.get_queue_sender(broker.QUEUE) as sender,
        bus.get_queue_receiver(broker.QUEUE, max_wait_time=5) as receiver,
    ):

        class SendThenCrash:
            def send_messages(self, message, *, timeout):
                sender.send_messages(message, timeout=timeout)
                raise Crash()

        with pytest.raises(Crash):
            publish_one(stack.cap_dsn, SendThenCrash())
        with connect(stack.cap_dsn) as conn:
            assert conn.execute("SELECT state FROM outbox").fetchone()["state"] == "pending"
        assert publish_one(stack.cap_dsn, sender)
        assert handle_message(receiver, receive(receiver), erp)
        assert handle_message(receiver, receive(receiver), erp)
    assert counts(stack) == (1, 1, 1)


def test_bounded_publish_failure_is_visible_and_explicitly_replayable(stack, erp):
    accept(stack)

    class BrokenSender:
        def send_messages(self, message, *, timeout):
            raise ServiceBusError("injected broker outage")

    for _ in range(MAX_ATTEMPTS):
        with connect(stack.cap_dsn) as conn:
            conn.execute("UPDATE outbox SET next_attempt_at = clock_timestamp()")
        assert publish_one(stack.cap_dsn, BrokenSender())
    with connect(stack.cap_dsn) as conn:
        row = conn.execute("SELECT * FROM outbox").fetchone()
        assert row["state"] == "blocked"
        assert row["attempts"] == MAX_ATTEMPTS
        assert row["last_error"] == "ServiceBusError"
    assert not publish_one(stack.cap_dsn, BrokenSender())
    assert replay_unposted(stack.cap_dsn, erp) == 1
    with connect(stack.cap_dsn) as conn:
        assert conn.execute("SELECT state FROM outbox").fetchone()["state"] == "pending"


def test_last_send_ack_lost_but_posted_is_confirmed_without_reenqueue(stack, erp):
    accept(stack)

    class FailedSend:
        def send_messages(self, message, *, timeout):
            raise ServiceBusError("injected unavailable broker")

    for _ in range(MAX_ATTEMPTS - 1):
        with connect(stack.cap_dsn) as conn:
            conn.execute("UPDATE outbox SET next_attempt_at = clock_timestamp()")
        assert publish_one(stack.cap_dsn, FailedSend())
    with connect(stack.cap_dsn) as conn:
        conn.execute("UPDATE outbox SET next_attempt_at = clock_timestamp()")
    with (
        broker.client(stack) as bus,
        bus.get_queue_sender(broker.QUEUE) as sender,
        bus.get_queue_receiver(broker.QUEUE, max_wait_time=5) as receiver,
    ):

        class FinalAckLost:
            def send_messages(self, message, *, timeout):
                sender.send_messages(message, timeout=timeout)
                raise ServiceBusError("injected lost send acknowledgement")

        assert publish_one(stack.cap_dsn, FinalAckLost())
        with connect(stack.cap_dsn) as conn:
            assert conn.execute("SELECT state FROM outbox").fetchone()["state"] == "blocked"
        assert handle_message(receiver, receive(receiver), erp)
        assert replay_unposted(stack.cap_dsn, erp) == 0
        with connect(stack.cap_dsn) as conn:
            row = conn.execute("SELECT * FROM outbox").fetchone()
            assert row["state"] == "confirmed"
            assert row["confirmed_at"] is not None and row["last_error"] is None
            assert (
                conn.execute(
                    "SELECT transaction_count FROM recovery_events WHERE action = 'confirm-posted'"
                ).fetchone()["transaction_count"]
                == 1
            )
        assert not publish_one(stack.cap_dsn, sender)
        assert not receiver.receive_messages(max_message_count=1, max_wait_time=1)
    assert counts(stack) == (1, 1, 1)


@pytest.mark.parametrize("boundary", ["before-commit", "lost-erp-response", "lost-completion"])
def test_erp_commit_and_completion_boundaries(stack, erp, boundary):
    posting = accept(stack)
    with (
        broker.client(stack) as bus,
        bus.get_queue_sender(broker.QUEUE) as sender,
        bus.get_queue_receiver(broker.QUEUE, max_wait_time=5) as receiver,
    ):
        publish_one(stack.cap_dsn, sender)
        first = receive(receiver)
        if boundary == "before-commit":

            def fail_before_commit(request):
                return httpx.Response(503)

            with httpx.Client(
                base_url=stack.erp_url, transport=httpx.MockTransport(fail_before_commit)
            ) as bad:
                assert not handle_message(receiver, first, bad)
            assert counts(stack)[2] == 0
        elif boundary == "lost-erp-response":

            def lose_response(request):
                response = erp.post("/ledger", json=json.loads(request.content))
                response.raise_for_status()
                raise httpx.ReadTimeout("Injected loss after real ERP commit")

            with httpx.Client(
                base_url=stack.erp_url, transport=httpx.MockTransport(lose_response)
            ) as bad:
                assert not handle_message(receiver, first, bad)
            assert counts(stack)[2] == 1
        else:

            class CompletionLost:
                def complete_message(self, message):
                    raise Crash()

            with pytest.raises(Crash):
                handle_message(CompletionLost(), first, erp)
            assert counts(stack)[2] == 1
            # Do not abandon: allow the real 30-second broker lock to expire.
            time.sleep(31)
        second = receive(receiver)
        assert second.delivery_count >= 1
        assert handle_message(receiver, second, erp)
    assert counts(stack) == (1, 1, 1)
    assert storage.ledger_lookup(stack.erp_dsn, [posting.transaction_id]) == [posting]


def test_ledger_rejects_changed_duplicate(stack):
    first = accept(stack)
    storage.post(stack.erp_dsn, first)
    changed = first.model_copy(update={"country": "BE"})
    with pytest.raises(Conflict):
        storage.post(stack.erp_dsn, changed)
    assert counts(stack) == (1, 1, 1)


def test_erp_database_commit_failure_never_completes_message(stack, erp):
    accept(stack)
    with connect(stack.erp_dsn) as conn:
        conn.execute(
            "CREATE FUNCTION reject_ledger_commit() RETURNS trigger LANGUAGE plpgsql AS "
            "$$ BEGIN RAISE EXCEPTION 'injected ERP commit failure'; END $$"
        )
        conn.execute(
            "CREATE CONSTRAINT TRIGGER reject_ledger_commit AFTER INSERT ON ledger "
            "DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION reject_ledger_commit()"
        )
    with (
        broker.client(stack) as bus,
        bus.get_queue_sender(broker.QUEUE) as sender,
        bus.get_queue_receiver(broker.QUEUE, max_wait_time=5) as receiver,
    ):
        try:
            assert publish_one(stack.cap_dsn, sender)
            assert not handle_message(receiver, receive(receiver), erp)
            assert counts(stack) == (1, 1, 0)
        finally:
            with connect(stack.erp_dsn) as conn:
                conn.execute("DROP TRIGGER reject_ledger_commit ON ledger")
                conn.execute("DROP FUNCTION reject_ledger_commit()")
        assert handle_message(receiver, receive(receiver), erp)
    assert counts(stack) == (1, 1, 1)


def test_delivery_exhaustion_is_dead_lettered_and_not_posted(stack):
    accept(stack)
    with (
        broker.client(stack) as bus,
        bus.get_queue_sender(broker.QUEUE) as sender,
        bus.get_queue_receiver(broker.QUEUE, max_wait_time=5) as receiver,
    ):
        assert publish_one(stack.cap_dsn, sender)
        for _ in range(5):
            receiver.abandon_message(receive(receiver))
        assert not receiver.receive_messages(max_message_count=1, max_wait_time=2)
        with bus.get_queue_receiver(broker.QUEUE, sub_queue=ServiceBusSubQueue.DEAD_LETTER) as dlq:
            messages = dlq.peek_messages(max_message_count=10)
            assert len(messages) == 1
            assert messages[0].dead_letter_reason == "MaxDeliveryCountExceeded"
    assert counts(stack) == (1, 1, 0)


def test_poison_and_conflicting_postings_go_to_dead_letter(stack, erp):
    original = accept(stack)
    storage.post(stack.erp_dsn, original)
    changed = original.model_copy(update={"country": "BE"})
    with (
        broker.client(stack) as bus,
        bus.get_queue_sender(broker.QUEUE) as sender,
        bus.get_queue_receiver(broker.QUEUE, max_wait_time=5) as receiver,
    ):
        sender.send_messages(ServiceBusMessage("not-json", message_id=str(uuid4())))
        sender.send_messages(
            ServiceBusMessage(changed.model_dump_json(), message_id=str(changed.transaction_id))
        )
        assert not handle_message(receiver, receive(receiver), erp)
        assert not handle_message(receiver, receive(receiver), erp)
        with bus.get_queue_receiver(broker.QUEUE, sub_queue=ServiceBusSubQueue.DEAD_LETTER) as dlq:
            reasons = {
                message.dead_letter_reason for message in dlq.peek_messages(max_message_count=10)
            }
            assert reasons == {"InvalidContract", "LedgerConflict"}
    assert counts(stack) == (1, 1, 1)


def test_unknown_stale_expired_and_recovered_evidence(stack, erp):
    def unavailable(request):
        return httpx.Response(503)

    with httpx.Client(base_url=stack.erp_url, transport=httpx.MockTransport(unavailable)) as bad:
        assert status(stack.cap_dsn)["status"] == "unknown"
        unknown = reconcile(stack.cap_dsn, bad)
        assert unknown["status"] == "unknown" and unknown["current"] is None
        accept(stack)
        fresh = reconcile(stack.cap_dsn, erp)
        assert fresh["current"]["unposted_cents"] == 597
        stale = reconcile(stack.cap_dsn, bad)
        assert stale["status"] == "stale" and stale["current"] is None
        assert stale["last_success"]["unposted_cents"] == 597
        with pytest.raises(httpx.HTTPStatusError):
            replay_unposted(stack.cap_dsn, bad)
    assert reconcile(stack.cap_dsn, erp)["status"] == "fresh"
    with connect(stack.cap_dsn) as conn:
        conn.execute(
            "UPDATE reconciliation SET last_success_at = %s",
            (datetime.now(UTC) - timedelta(seconds=31),),
        )
    assert status(stack.cap_dsn)["status"] == "stale"


def test_pagination_and_immutable_ledger_mismatch(stack, erp):
    rows = dataset("pagination", 205)
    for row in rows:
        item = accept(stack, row)
        storage.post(stack.erp_dsn, item)
    report = reconcile(stack.cap_dsn, erp)["current"]
    assert report["accepted_count"] == report["posted_count"] == 205
    assert report["unposted_cents"] == 0
    with connect(stack.erp_dsn) as conn:
        conn.execute(
            "UPDATE ledger SET posting = jsonb_set(posting, '{country}', %s) "
            "WHERE transaction_id = %s",
            (Jsonb("FR"), rows[0].transaction_id),
        )
    result = reconcile(stack.cap_dsn, erp)
    assert result["status"] == "stale"
    assert result["current"] is None
    assert result["error"] == "EvidenceUnavailable"


def test_fault_expiry_and_idempotent_undo(stack):
    with pytest.raises(RuntimeError, match="heartbeat"):
        fault.backlog(stack.erp_dsn, 10)
    assert not fault.heartbeat(stack.erp_dsn)
    fault.backlog(stack.erp_dsn, 1)
    assert fault.heartbeat(stack.erp_dsn)
    time.sleep(1.1)
    assert not fault.heartbeat(stack.erp_dsn)
    fault.backlog(stack.erp_dsn, None)
    fault.backlog(stack.erp_dsn, None)
    assert not fault.heartbeat(stack.erp_dsn)
    with connect(stack.erp_dsn) as conn:
        actions = [
            row["action"] for row in conn.execute("SELECT action FROM change_events").fetchall()
        ]
    assert actions == ["backlog.inject", "backlog.expired", "backlog.undo", "backlog.undo"]
    with pytest.raises(ValueError):
        fault.backlog(stack.erp_dsn, 301)


def test_trace_context_survives_persisted_outbox_and_broker(stack):
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    local_tracer = provider.get_tracer("boundary-test")
    with local_tracer.start_as_current_span("checkout-test") as span:
        original_id = span.get_span_context().trace_id
        accept(stack)
    with (
        broker.client(stack) as bus,
        bus.get_queue_sender(broker.QUEUE) as sender,
        bus.get_queue_receiver(broker.QUEUE, max_wait_time=5) as receiver,
    ):
        publish_one(stack.cap_dsn, sender)
        message = receive(receiver)
        extracted = trace.get_current_span(
            propagator.extract(message_context(message))
        ).get_span_context()
        assert extracted.trace_id == original_id
        receiver.complete_message(message)
    provider.shutdown()
