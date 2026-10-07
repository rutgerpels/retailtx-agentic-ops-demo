import os
import time

import httpx
import pytest
from azure.servicebus import ServiceBusSubQueue
from retailtx import broker
from retailtx.db import connect
from retailtx.settings import Settings


@pytest.fixture
def settings():
    if os.environ.get("RETAILTX_INTEGRATION") != "1":
        pytest.skip("Use Invoke-Local.ps1 Verify in an isolated retailtx-test-* Compose project")
    if not os.environ.get("RETAILTX_TEST_PROJECT", "").startswith("retailtx-test-"):
        pytest.fail("Refusing destructive integration tests outside a retailtx-test-* project")
    return Settings.from_env()


def clear_data(settings):
    with connect(settings.cap_dsn) as conn:
        conn.execute("TRUNCATE outbox, accepted_transactions, reconciliation, recovery_events")
    with connect(settings.erp_dsn) as conn:
        conn.execute("TRUNCATE ledger, change_events")
        conn.execute(
            "UPDATE worker_control SET fault_until = NULL, heartbeat_at = NULL, worker_state = NULL"
        )
    with broker.client(settings) as bus:
        for sub_queue in (None, ServiceBusSubQueue.DEAD_LETTER):
            with bus.get_queue_receiver(
                broker.QUEUE, sub_queue=sub_queue, max_wait_time=1
            ) as receiver:
                for _ in range(20):
                    messages = receiver.receive_messages(max_message_count=100, max_wait_time=1)
                    for message in messages:
                        receiver.complete_message(message)
                    if not messages:
                        break
                else:
                    pytest.fail("Queue did not drain within the bounded test cleanup")


@pytest.fixture
def stack(settings):
    clear_data(settings)
    yield settings
    clear_data(settings)


@pytest.fixture
def erp(stack):
    with httpx.Client(base_url=stack.erp_url, timeout=3) as client:
        yield client


def wait_until(condition, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(0.1)
    pytest.fail("Expected condition was not reached before the deadline")
