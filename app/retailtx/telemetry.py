import json
import logging
import sys
from collections.abc import Sequence
from datetime import UTC, datetime
from threading import Lock
from typing import Any

from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter, SpanExportResult
from opentelemetry.trace import SpanKind
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

propagator = TraceContextTextMapPropagator()
tracer = trace.get_tracer("retailtx")
_configured = False
_output_lock = Lock()


class JsonSpanExporter(ConsoleSpanExporter):
    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        with _output_lock:
            return super().export(spans)


def configure(service: str) -> None:
    global _configured
    if _configured:
        return
    logging.basicConfig(level=logging.WARNING)
    provider = TracerProvider(resource=Resource.create({"service.name": service}))
    provider.add_span_processor(
        BatchSpanProcessor(
            JsonSpanExporter(formatter=lambda span: span.to_json(indent=None) + "\n"),
            schedule_delay_millis=500,
        )
    )
    trace.set_tracer_provider(provider)
    _configured = True


def event(name: str, **fields: Any) -> None:
    context = trace.get_current_span().get_span_context()
    record = json.dumps(
        {
            "event": name,
            "timestamp": datetime.now(UTC).isoformat(),
            "trace_id": f"{context.trace_id:032x}" if context.is_valid else None,
            **fields,
        },
        default=str,
    )
    # SDK batch exports and request threads share stdout: serialize whole JSON records.
    with _output_lock:
        sys.stdout.write(record + "\n")
        sys.stdout.flush()


def carrier() -> dict[str, str]:
    headers: dict[str, str] = {}
    propagator.inject(headers)
    return headers


__all__ = ["SpanKind", "carrier", "configure", "event", "propagator", "tracer"]
