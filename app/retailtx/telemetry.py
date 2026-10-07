import json
import logging
import sys
from collections.abc import Sequence
from datetime import UTC, datetime
from threading import Lock
from typing import Any
from uuid import UUID

from opentelemetry import trace
from opentelemetry._logs import Logger, SeverityNumber
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter, SpanExportResult
from opentelemetry.trace import SpanKind
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator

from retailtx.settings import Settings

propagator = TraceContextTextMapPropagator()
tracer = trace.get_tracer("retailtx")
_configured = False
_output_lock = Lock()
_environment_id = "local"
_event_logger: Logger | None = None


class JsonSpanExporter(ConsoleSpanExporter):
    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        with _output_lock:
            return super().export(spans)


def configure(service: str, settings: Settings | None = None) -> None:
    global _configured, _environment_id, _event_logger
    if _configured:
        return
    logging.basicConfig(level=logging.WARNING)
    _environment_id = settings.environment_id if settings is not None else "local"
    resource = Resource.create({"service.name": service, "environment_id": _environment_id})
    if settings is not None and settings.mode == "azure":
        from azure.monitor.opentelemetry.exporter import (
            ApplicationInsightsSampler,
            AzureMonitorLogExporter,
            AzureMonitorTraceExporter,
        )

        provider = TracerProvider(resource=resource, sampler=ApplicationInsightsSampler(1.0))
        provider.add_span_processor(
            BatchSpanProcessor(
                AzureMonitorTraceExporter(
                    connection_string=settings.applicationinsights_connection_string,
                    credential=settings.credential,
                    disable_offline_storage=True,
                ),
                schedule_delay_millis=500,
            )
        )
        logs = LoggerProvider(resource=resource)
        logs.add_log_record_processor(
            BatchLogRecordProcessor(
                AzureMonitorLogExporter(
                    connection_string=settings.applicationinsights_connection_string,
                    credential=settings.credential,
                    disable_offline_storage=True,
                ),
                schedule_delay_millis=500,
            )
        )
        # Direct SDK emission captures only our events, never the exporter's own logs.
        _event_logger = logs.get_logger("retailtx.events")
    else:
        provider = TracerProvider(resource=resource)
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
            **fields,
            "event": name,
            "environment_id": _environment_id,
            "timestamp": datetime.now(UTC).isoformat(),
            "trace_id": f"{context.trace_id:032x}" if context.is_valid else None,
        },
        default=str,
    )
    # SDK batch exports and request threads share stdout: serialize whole JSON records.
    with _output_lock:
        sys.stdout.write(record + "\n")
        sys.stdout.flush()
    if _event_logger is not None:
        properties = {
            key: (
                value
                if isinstance(value, (str, bool, int, float))
                else str(value) if isinstance(value, UUID) else json.dumps(value, default=str)
            )
            for key, value in fields.items()
            if value is not None
        }
        _event_logger.emit(
            body=name,
            severity_number=SeverityNumber.INFO,
            attributes={**properties, "event": name, "environment_id": _environment_id},
        )


def carrier() -> dict[str, str]:
    headers: dict[str, str] = {}
    propagator.inject(headers)
    return headers


__all__ = ["SpanKind", "carrier", "configure", "event", "propagator", "tracer"]
