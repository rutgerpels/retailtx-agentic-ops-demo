import io
import json
import time
from concurrent.futures import ThreadPoolExecutor

from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from retailtx.telemetry import JsonSpanExporter, event


def test_concurrent_spans_and_events_are_individual_json_lines(monkeypatch):
    class SlowOutput(io.StringIO):
        def write(self, value):
            time.sleep(0.001)
            return super().write(value)

    output = SlowOutput()
    monkeypatch.setattr("sys.stdout", output)
    provider = TracerProvider()
    provider.add_span_processor(
        SimpleSpanProcessor(
            JsonSpanExporter(out=output, formatter=lambda span: span.to_json(indent=None) + "\n")
        )
    )
    tracer = provider.get_tracer("concurrent-output")

    def write(index):
        with tracer.start_as_current_span("checkout"):
            event("checkout.attempt", index=index)

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(write, range(100)))
    provider.shutdown()
    records = [json.loads(line) for line in output.getvalue().splitlines()]
    assert len(records) == 200
    assert sum(record.get("event") == "checkout.attempt" for record in records) == 100
    assert sum(record.get("name") == "checkout" for record in records) == 100
