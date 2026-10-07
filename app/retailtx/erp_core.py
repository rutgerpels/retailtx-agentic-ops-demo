from typing import Any

from fastapi import FastAPI, HTTPException

from retailtx import storage
from retailtx.contracts import Lookup, Posting, Price, Sku
from retailtx.db import connect
from retailtx.http import setup
from retailtx.settings import Settings
from retailtx.telemetry import configure


def create_app() -> FastAPI:
    settings = Settings.from_env()
    configure("erp-core")
    app = FastAPI(title="RetailTx local ERP")
    setup(app)

    @app.get("/health")
    def health() -> dict[str, str]:
        with connect(settings.erp_dsn) as conn:
            conn.execute("SELECT transaction_id FROM ledger LIMIT 1")
        return {"status": "healthy", "mode": "local"}

    @app.get("/price/{sku}", response_model=Price)
    def price(sku: Sku) -> Price:
        with connect(settings.erp_dsn) as conn:
            row = conn.execute(
                "SELECT unit_price_cents FROM prices WHERE sku = %s", (sku,)
            ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Unknown SKU")
        return Price(sku=sku, unit_price_cents=row["unit_price_cents"])

    @app.post("/ledger", response_model=Posting)
    def ledger(posting: Posting) -> Posting:
        return storage.post(settings.erp_dsn, posting)

    @app.post("/ledger/lookup", response_model=list[Posting])
    def lookup(query: Lookup) -> list[Posting]:
        return storage.ledger_lookup(settings.erp_dsn, query.transaction_ids)

    @app.get("/worker")
    def worker() -> dict[str, Any]:
        with connect(settings.erp_dsn) as conn:
            row = conn.execute(
                "SELECT *, coalesce(fault_until > clock_timestamp(), false) AS paused "
                "FROM worker_control"
            ).fetchone()
        assert row is not None
        return row

    return app
