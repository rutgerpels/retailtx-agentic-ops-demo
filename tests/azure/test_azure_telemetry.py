import json
from unittest.mock import Mock
from uuid import UUID

import httpx
import psycopg
import pytest
from azure.identity import CredentialUnavailableError
from azure.monitor.opentelemetry import exporter
from opentelemetry.sdk._logs import LoggerProvider
from opentelemetry.sdk._logs.export import InMemoryLogRecordExporter, SimpleLogRecordProcessor
from opentelemetry.sdk.trace import TracerProvider
from retailtx import telemetry
from retailtx.reconciliation import observe_freshness


def test_azure_exporters_share_explicit_identity_and_disable_disk_storage(settings, monkeypatch):
    credential = Mock()
    traces, logs = Mock(), Mock()
    trace_provider, log_provider = Mock(), Mock()
    monkeypatch.setattr("retailtx.settings.managed_identity", lambda kind: credential)
    monkeypatch.setattr(exporter, "AzureMonitorTraceExporter", traces)
    monkeypatch.setattr(exporter, "AzureMonitorLogExporter", logs)
    monkeypatch.setattr(telemetry, "TracerProvider", Mock(return_value=trace_provider))
    monkeypatch.setattr(telemetry, "LoggerProvider", Mock(return_value=log_provider))
    monkeypatch.setattr(telemetry, "BatchSpanProcessor", Mock())
    monkeypatch.setattr(telemetry, "BatchLogRecordProcessor", Mock())
    monkeypatch.setattr(telemetry.trace, "set_tracer_provider", Mock())
    monkeypatch.setattr(telemetry, "_configured", False)
    monkeypatch.setattr(telemetry, "_event_logger", None)
    monkeypatch.setattr(telemetry, "_environment_id", "local")
    telemetry.configure("recon-job", settings)
    for factory in (traces, logs):
        assert factory.call_args.kwargs == {
            "connection_string": settings.applicationinsights_connection_string,
            "credential": credential,
            "disable_offline_storage": True,
        }
    assert trace_provider.add_span_processor.call_count == 2
    log_provider.get_logger.assert_called_once_with("retailtx.events")


def test_actual_sdk_event_attributes_and_trace_context(monkeypatch, capsys):
    exported = InMemoryLogRecordExporter()
    provider = LoggerProvider()
    provider.add_log_record_processor(SimpleLogRecordProcessor(exported))
    spans = TracerProvider()
    monkeypatch.setattr(telemetry, "_event_logger", provider.get_logger("retailtx.events"))
    monkeypatch.setattr(telemetry, "_environment_id", "demo01")
    with spans.get_tracer("unit").start_as_current_span("reconciliation") as span:
        telemetry.event(
            "reconciliation.observed",
            unposted_count=3,
            unposted_cents=597,
            transaction_id=UUID("11111111-2222-4333-8444-555555555555"),
            by_country_brand=[{"country": "NL", "brand": "market", "unposted_count": 3}],
        )
    record = exported.get_finished_logs()[0].log_record
    assert record.trace_id == span.get_span_context().trace_id
    assert record.attributes["event"] == "reconciliation.observed"
    assert record.attributes["environment_id"] == "demo01"
    assert record.attributes["unposted_count"] == 3
    assert record.attributes["unposted_cents"] == 597
    assert record.attributes["transaction_id"] == "11111111-2222-4333-8444-555555555555"
    assert isinstance(record.attributes["by_country_brand"], str)
    assert json.loads(record.attributes["by_country_brand"])[0]["country"] == "NL"
    assert json.loads(capsys.readouterr().out)["unposted_cents"] == 597
    provider.shutdown()
    spans.shutdown()


def test_stale_and_unknown_never_export_current_zero(monkeypatch):
    emit = Mock()
    monkeypatch.setattr("retailtx.reconciliation.event", emit)
    for state in ("stale", "unknown"):
        observe_freshness(
            {
                "status": state,
                "error": "NoEvidence",
                "current": None,
                "last_success": {"unposted_count": 0, "unposted_cents": 0},
            }
        )
    assert [call.args for call in emit.call_args_list] == [("reconciliation.freshness",)] * 2
    assert all("unposted_cents" not in call.kwargs for call in emit.call_args_list)


def test_fresh_country_events_are_exact_integer_sums(monkeypatch):
    emit = Mock()
    monkeypatch.setattr("retailtx.reconciliation.event", emit)
    observe_freshness(
        {
            "status": "fresh",
            "error": None,
            "current": {
                "observed_at": "2026-10-07T12:00:00+00:00",
                "unposted_count": 3,
                "unposted_cents": 597,
                "by_country_brand": [
                    {
                        "country": "NL",
                        "brand": "market",
                        "unposted_count": 2,
                        "unposted_cents": 398,
                    },
                    {"country": "NL", "brand": "fresh", "unposted_count": 1, "unposted_cents": 199},
                ],
            },
        }
    )
    countries = [
        call.kwargs for call in emit.call_args_list if call.args == ("reconciliation.country",)
    ]
    assert {row["country"] for row in countries} == {"NL", "BE", "DE", "FR"}
    assert next(row for row in countries if row["country"] == "NL")["unposted_cents"] == 597
    assert sum(row["unposted_count"] for row in countries) == 3


@pytest.mark.parametrize("error", [psycopg.OperationalError, CredentialUnavailableError])
def test_reconciliation_database_or_identity_outage_emits_unknown(monkeypatch, error):
    from retailtx import reconciliation

    emit = Mock()
    monkeypatch.setattr(reconciliation, "event", emit)
    monkeypatch.setattr(reconciliation, "connect", Mock(side_effect=error("Unavailable")))
    with httpx.Client() as http, pytest.raises(error):
        reconciliation.reconcile("not-connected", http)
    emit.assert_called_once_with("reconciliation.freshness", status="unknown", error=error.__name__)
