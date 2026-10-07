from typing import Protocol

import httpx
from azure.servicebus import ServiceBusReceivedMessage
from pydantic import ValidationError

from retailtx.contracts import Posting
from retailtx.telemetry import SpanKind, carrier, event, propagator, tracer


class Receiver(Protocol):
    def complete_message(self, message: ServiceBusReceivedMessage) -> None: ...
    def abandon_message(self, message: ServiceBusReceivedMessage) -> None: ...
    def dead_letter_message(
        self, message: ServiceBusReceivedMessage, *, reason: str, error_description: str
    ) -> None: ...


def message_context(message: ServiceBusReceivedMessage) -> dict[str, str]:
    properties = message.application_properties or {}
    result: dict[str, str] = {}
    for name in ("traceparent", "tracestate"):
        value = properties.get(name.encode()) or properties.get(name)
        if isinstance(value, bytes):
            result[name] = value.decode("ascii", errors="replace")
        elif isinstance(value, str):
            result[name] = value
    return result


def handle_message(
    receiver: Receiver, message: ServiceBusReceivedMessage, http: httpx.Client
) -> bool:
    with tracer.start_as_current_span(
        "posting.consume",
        kind=SpanKind.CONSUMER,
        context=propagator.extract(message_context(message)),
        record_exception=False,
        set_status_on_exception=False,
    ) as span:
        try:
            posting = Posting.model_validate_json(str(message))
            if str(message.message_id) != str(posting.transaction_id):
                raise ValueError("Message ID must equal the transaction ID")
        except (ValidationError, ValueError):
            receiver.dead_letter_message(
                message, reason="InvalidContract", error_description="Invalid posting contract"
            )
            event("posting.dead_letter", reason="InvalidContract")
            return False
        span.set_attribute("country", posting.country)
        span.set_attribute("brand", posting.brand)
        with tracer.start_as_current_span(
            "erp.post",
            kind=SpanKind.CLIENT,
            record_exception=False,
            set_status_on_exception=False,
        ):
            try:
                response = http.post(
                    "/ledger", json=posting.model_dump(mode="json"), headers=carrier()
                )
                if response.status_code in {409, 422}:
                    receiver.dead_letter_message(
                        message,
                        reason="LedgerConflict",
                        error_description="ERP rejected immutable posting data",
                    )
                    event(
                        "posting.dead_letter",
                        transaction_id=posting.transaction_id,
                        reason="LedgerConflict",
                    )
                    return False
                response.raise_for_status()
                evidence = Posting.model_validate(response.json())
                if evidence != posting:
                    raise ValueError("ERP acknowledgement does not match the posting")
            except (httpx.HTTPError, ValidationError, ValueError) as exc:
                event(
                    "posting.retry", transaction_id=posting.transaction_id, error=type(exc).__name__
                )
                receiver.abandon_message(message)
                return False
        # ERP has committed before returning this response. Settlement failure is safe to retry.
        receiver.complete_message(message)
        event("posting.completed", transaction_id=posting.transaction_id)
        return True
