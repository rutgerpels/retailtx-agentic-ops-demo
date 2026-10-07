from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import ValidationError
from retailtx.contracts import Checkout, Posting, euros
from retailtx.http import setup
from retailtx.settings import Settings

from sim.pos_sim import dataset


def request(**changes):
    return {
        "transaction_id": str(uuid4()),
        "country": "NL",
        "brand": "market",
        "sku": "basket-a",
        "quantity": 1,
        **changes,
    }


@pytest.mark.parametrize("quantity", [0, -1, 101, 1.1, "1", True])
def test_quantity_is_bounded_integer(quantity):
    with pytest.raises(ValidationError):
        Checkout.model_validate(request(quantity=quantity))


@pytest.mark.parametrize(
    "changes",
    [
        {"country": "ZZ"},
        {"brand": "unbounded"},
        {"sku": "unknown"},
        {"extra": 1},
        {"transaction_id": "not-a-uuid"},
    ],
)
def test_bounded_contract(changes):
    with pytest.raises(ValidationError):
        Checkout.model_validate(request(**changes))


def test_exact_money():
    posting = Posting(**request(quantity=3), unit_price_cents=199, amount_cents=597)
    assert posting.amount_cents == 597
    assert euros(597) == "5.97"
    assert euros(1) == "0.01"
    with pytest.raises(ValidationError):
        Posting(**request(quantity=3), unit_price_cents=199, amount_cents=598)
    with pytest.raises(ValidationError):
        Posting(**request(), unit_price_cents=1.99, amount_cents=1.99)


def test_known_dataset_repeats_ids_and_has_four_bounded_countries():
    first = dataset("known", 12)
    assert first == dataset("known", 12)
    assert {row.country for row in first} == {"NL", "BE", "DE", "FR"}
    assert len({row.transaction_id for row in first}) == 12
    assert first[0].transaction_id != dataset("different", 12)[0].transaction_id


def test_request_body_and_validation_are_bounded():
    app = FastAPI()
    setup(app)

    @app.post("/")
    def checkout(value: Checkout):
        return value

    with TestClient(app) as client:
        assert client.post("/", json=request()).status_code == 200
        invalid = client.post("/", json=request(quantity="secret-not-to-echo"))
        assert invalid.status_code == 422
        assert "secret-not-to-echo" not in invalid.text
        assert client.post("/", content=b" " * 8193).status_code == 413


def test_local_settings_refuse_cloud(monkeypatch):
    monkeypatch.setenv("RETAILTX_MODE", "azure")
    with pytest.raises(ValueError, match="local"):
        Settings.from_env()
    monkeypatch.setenv("RETAILTX_MODE", "local")
    monkeypatch.setenv("BROKER_HOST", "example.servicebus.windows.net")
    with pytest.raises(ValueError, match="emulator"):
        Settings.from_env()
