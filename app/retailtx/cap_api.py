from time import perf_counter

import httpx
import psycopg
from azure.core.exceptions import AzureError
from fastapi import FastAPI
from opentelemetry.trace import StatusCode

from retailtx import storage
from retailtx.contracts import Checkout, Conflict, EvidenceUnavailable, Posting, Price
from retailtx.db import connect
from retailtx.http import client, setup
from retailtx.reconciliation import status
from retailtx.settings import Settings
from retailtx.telemetry import SpanKind, carrier, configure, event, tracer


def create_app() -> FastAPI:
    settings = Settings.from_env()
    _ = settings.cap_dsn
    configure("cap-api", settings)
    app = FastAPI(title="RetailTx checkout")
    setup(app)

    @app.get("/health")
    def health() -> dict[str, str]:
        with connect(settings.cap_dsn) as conn:
            conn.execute("SELECT transaction_id FROM outbox LIMIT 1")
        return {"status": "healthy", "mode": settings.mode}

    @app.post("/transaction", response_model=Posting, status_code=202)
    def checkout(request: Checkout) -> Posting:
        started = perf_counter()
        with tracer.start_as_current_span(
            "checkout", record_exception=False, set_status_on_exception=False
        ) as span:
            span.set_attribute("country", request.country)
            span.set_attribute("brand", request.brand)

            def lookup() -> Price:
                with tracer.start_as_current_span(
                    "erp.price",
                    kind=SpanKind.CLIENT,
                    record_exception=False,
                    set_status_on_exception=False,
                ):
                    with client(settings, settings.erp_url) as http:
                        response = http.get(f"/price/{request.sku}", headers=carrier())
                    response.raise_for_status()
                    try:
                        return Price.model_validate(response.json())
                    except ValueError as exc:
                        raise EvidenceUnavailable("ERP returned invalid price evidence") from exc

            try:
                result = storage.accept(settings.cap_dsn, request, lookup)
            except (
                Conflict,
                EvidenceUnavailable,
                httpx.HTTPError,
                psycopg.Error,
                AzureError,
            ) as exc:
                span.set_status(StatusCode.ERROR)
                event(
                    "checkout.attempt",
                    country=request.country,
                    brand=request.brand,
                    success=False,
                    error=type(exc).__name__,
                    duration_ms=round((perf_counter() - started) * 1000, 3),
                )
                raise
            event(
                "checkout.attempt",
                country=request.country,
                brand=request.brand,
                transaction_id=request.transaction_id,
                success=True,
                duration_ms=round((perf_counter() - started) * 1000, 3),
            )
            return result

    @app.get("/reconciliation")
    def reconciliation() -> dict[str, object]:
        return status(settings.cap_dsn)

    return app
