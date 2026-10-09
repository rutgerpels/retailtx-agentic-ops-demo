from __future__ import annotations

import shutil
import socket
import sqlite3
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from azure.servicebus.exceptions import ServiceBusError

from scripts.servicebus import probe


@pytest.fixture
def state_dir() -> Iterator[Path]:
    directory = Path(__file__).parent / f".servicebus-probe-tests-{uuid.uuid4().hex}"
    directory.mkdir()
    try:
        yield directory
    finally:
        shutil.rmtree(directory)


class FakeCredential:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True


class FakeSender:
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.sent: list[Any] = []

    def __enter__(self) -> FakeSender:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def send_messages(self, message: Any) -> None:
        if self.error:
            raise self.error
        self.sent.append(message)


class FakeMessage:
    def __init__(self, transaction_id: str) -> None:
        self.message_id = transaction_id
        self.body = probe._payload_text(transaction_id)


class FakeReceiver:
    def __init__(
        self, messages: list[FakeMessage], *, fail_completion_once: bool = False
    ) -> None:
        self.messages = messages
        self.completed: list[FakeMessage] = []
        self.abandoned: list[FakeMessage] = []
        self.fail_completion_once = fail_completion_once

    def __enter__(self) -> FakeReceiver:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def receive_messages(self, **_: object) -> list[FakeMessage]:
        return self.messages

    def complete_message(self, message: FakeMessage) -> None:
        if self.fail_completion_once:
            self.fail_completion_once = False
            raise RuntimeError("simulated ambiguous settlement failure")
        self.completed.append(message)

    def abandon_message(self, message: FakeMessage) -> None:
        self.abandoned.append(message)


class FakeClient:
    def __init__(
        self, sender: FakeSender | None = None, receiver: FakeReceiver | None = None
    ) -> None:
        self.sender = sender
        self.receiver = receiver

    def __enter__(self) -> FakeClient:
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def get_queue_sender(self, *, queue_name: str) -> FakeSender:
        assert queue_name == "recovery-demo01"
        assert self.sender is not None
        return self.sender

    def get_queue_receiver(self, *, queue_name: str, max_wait_time: int) -> FakeReceiver:
        assert queue_name == "recovery-demo01"
        assert max_wait_time == 5
        assert self.receiver is not None
        return self.receiver


def configure_client(
    monkeypatch: pytest.MonkeyPatch, client: FakeClient, credential: FakeCredential
) -> None:
    monkeypatch.setattr(probe, "_client", lambda _: (credential, client))


def outbox_row(path: Path, transaction_id: str) -> sqlite3.Row:
    with probe.store(path) as connection:
        row = connection.execute(
            "SELECT * FROM outbox WHERE transaction_id = ?", (transaction_id,)
        ).fetchone()
    assert row is not None
    return row


def test_seed_is_durable_and_idempotent(state_dir: Path) -> None:
    transaction_id = "3e89dc0f-cb8d-4eaa-9e83-107ecc7a6d07"
    path = state_dir / "state" / "outbox.sqlite"
    first = probe.seed(path, transaction_id)
    second = probe.seed(path, transaction_id)
    row = outbox_row(path, transaction_id)

    assert first == second
    assert row["state"] == "pending"
    assert row["send_attempts"] == 0
    assert row["payload_hash"] == first["payloadHash"]


def test_send_disabled_error_keeps_outbox_pending_for_same_id(
    state_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transaction_id = "3e89dc0f-cb8d-4eaa-9e83-107ecc7a6d07"
    path = state_dir / "outbox.sqlite"
    probe.seed(path, transaction_id)
    credential = FakeCredential()
    configure_client(
        monkeypatch,
        FakeClient(sender=FakeSender(ServiceBusError("entity disabled"))),
        credential,
    )

    result = probe.send(path, "sbtx12345.servicebus.windows.net", "recovery-demo01", transaction_id)
    row = outbox_row(path, transaction_id)

    assert result["accepted"] is False
    assert row["state"] == "pending"
    assert row["send_attempts"] == 1
    assert credential.closed


def test_send_retry_reuses_stable_message_id_after_send_error(
    state_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transaction_id = "3e89dc0f-cb8d-4eaa-9e83-107ecc7a6d07"
    path = state_dir / "outbox.sqlite"
    probe.seed(path, transaction_id)
    failed_sender = FakeSender(ServiceBusError("entity disabled"))
    configure_client(monkeypatch, FakeClient(sender=failed_sender), FakeCredential())

    failed = probe.send(
        path, "sbtx12345.servicebus.windows.net", "recovery-demo01", transaction_id
    )
    assert failed["accepted"] is False
    assert failed_sender.sent == []

    retry_sender = FakeSender()
    configure_client(monkeypatch, FakeClient(sender=retry_sender), FakeCredential())
    retried = probe.send(
        path, "sbtx12345.servicebus.windows.net", "recovery-demo01", transaction_id
    )
    row = outbox_row(path, transaction_id)

    assert retried["accepted"] is True
    assert [message.message_id for message in retry_sender.sent] == [transaction_id]
    assert row["state"] == "accepted"
    assert row["send_attempts"] == 2


def test_retry_and_duplicate_delivery_post_exactly_once(
    state_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transaction_id = "3e89dc0f-cb8d-4eaa-9e83-107ecc7a6d07"
    path = state_dir / "outbox.sqlite"
    probe.seed(path, transaction_id)

    credential = FakeCredential()
    sender = FakeSender()
    configure_client(monkeypatch, FakeClient(sender=sender), credential)
    accepted = probe.send(
        path, "sbtx12345.servicebus.windows.net", "recovery-demo01", transaction_id
    )
    assert accepted["accepted"] is True
    assert sender.sent[0].message_id == transaction_id
    assert probe.send(path, "sbtx12345.servicebus.windows.net", "recovery-demo01", transaction_id)[
        "alreadyAccepted"
    ]

    messages = [FakeMessage(transaction_id), FakeMessage(transaction_id)]
    receiver = FakeReceiver(messages)
    configure_client(monkeypatch, FakeClient(receiver=receiver), FakeCredential())
    result = probe.receive(path, "sbtx12345.servicebus.windows.net", "recovery-demo01")
    evidence = probe.verify(path, transaction_id)

    assert result == {"completed": 2, "duplicateDeliveries": 1}
    assert len(receiver.completed) == len(messages)
    assert receiver.abandoned == []
    assert evidence["state"] == "posted"
    assert evidence["postedCount"] == 1
    assert evidence["payloadHash"] == outbox_row(path, transaction_id)["payload_hash"]


def test_redelivery_after_ambiguous_completion_failure_keeps_one_ledger_post(
    state_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transaction_id = "3e89dc0f-cb8d-4eaa-9e83-107ecc7a6d07"
    path = state_dir / "outbox.sqlite"
    probe.seed(path, transaction_id)
    configure_client(
        monkeypatch,
        FakeClient(sender=FakeSender()),
        FakeCredential(),
    )
    probe.send(
        path, "sbtx12345.servicebus.windows.net", "recovery-demo01", transaction_id
    )

    first_delivery = FakeMessage(transaction_id)
    first_receiver = FakeReceiver([first_delivery], fail_completion_once=True)
    configure_client(
        monkeypatch, FakeClient(receiver=first_receiver), FakeCredential()
    )
    with pytest.raises(RuntimeError, match="ambiguous settlement failure"):
        probe.receive(
            path, "sbtx12345.servicebus.windows.net", "recovery-demo01"
        )

    assert first_receiver.abandoned == []
    with probe.store(path) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM ledger WHERE transaction_id = ?", (transaction_id,)
        ).fetchone()[0] == 1

    redelivery = FakeMessage(transaction_id)
    retry_receiver = FakeReceiver([redelivery])
    configure_client(monkeypatch, FakeClient(receiver=retry_receiver), FakeCredential())
    result = probe.receive(path, "sbtx12345.servicebus.windows.net", "recovery-demo01")

    assert result == {"completed": 1, "duplicateDeliveries": 1}
    assert retry_receiver.completed == [redelivery]
    assert retry_receiver.abandoned == []
    assert probe.verify(path, transaction_id)["postedCount"] == 1


def test_receive_rejects_unseeded_transaction_and_abandons_message(
    state_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    transaction_id = "3e89dc0f-cb8d-4eaa-9e83-107ecc7a6d07"
    receiver = FakeReceiver([FakeMessage(transaction_id)])
    configure_client(monkeypatch, FakeClient(receiver=receiver), FakeCredential())

    with pytest.raises(ValueError, match="durable outbox"):
        probe.receive(
            state_dir / "outbox.sqlite",
            "sbtx12345.servicebus.windows.net",
            "recovery-demo01",
        )

    assert receiver.abandoned == receiver.messages
    assert receiver.completed == []


@pytest.mark.parametrize(
    ("namespace", "queue"),
    [
        ("sbtx12345.servicebus.windows.net.evil.example", "recovery-demo01"),
        ("sbtx12345.servicebus.windows.net", "queue;EntityPath=other"),
    ],
)
def test_target_validation_rejects_non_private_or_injected_target(
    namespace: str, queue: str
) -> None:
    with pytest.raises(ValueError):
        probe.validate_target(namespace, queue)


def test_client_fails_closed_when_namespace_dns_is_not_private(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        probe.socket,
        "getaddrinfo",
        lambda *_args, **_kwargs: [
            (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("20.50.60.70", 443))
        ],
    )
    monkeypatch.setattr(
        probe,
        "ManagedIdentityCredential",
        lambda: (_ for _ in ()).throw(AssertionError("Credential must not be acquired")),
    )

    with pytest.raises(ValueError, match="private endpoint subnet"):
        probe._client("sbtx12345.servicebus.windows.net")


def test_client_uses_system_identity_and_private_websocket_transport(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    credential = FakeCredential()
    created: dict[str, Any] = {}
    monkeypatch.setattr(probe, "assert_private_endpoint", lambda _: None)
    monkeypatch.setattr(probe, "ManagedIdentityCredential", lambda: credential)
    monkeypatch.setattr(
        probe,
        "ServiceBusClient",
        lambda **kwargs: created.update(kwargs) or object(),
    )

    actual_credential, client = probe._client("sbtx12345.servicebus.windows.net")

    assert actual_credential is credential
    assert created["fully_qualified_namespace"] == "sbtx12345.servicebus.windows.net"
    assert created["credential"] is credential
    assert created["transport_type"] == probe.TransportType.AmqpOverWebsocket
    assert client is not None
    credential.close()


def test_verify_requires_accepted_and_one_matching_post(state_dir: Path) -> None:
    transaction_id = "3e89dc0f-cb8d-4eaa-9e83-107ecc7a6d07"
    path = state_dir / "outbox.sqlite"
    probe.seed(path, transaction_id)

    with pytest.raises(RuntimeError, match="not posted exactly once"):
        probe.verify(path, transaction_id)
