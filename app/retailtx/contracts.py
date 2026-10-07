from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

Country = Literal["NL", "BE", "DE", "FR"]
Brand = Literal["market", "fresh"]
Sku = Literal["basket-a", "basket-b", "basket-c"]
COUNTRIES: tuple[Country, ...] = ("NL", "BE", "DE", "FR")
BRANDS: tuple[Brand, ...] = ("market", "fresh")
PRICES: dict[Sku, int] = {"basket-a": 199, "basket-b": 349, "basket-c": 105}
Cents = Annotated[int, Field(strict=True, ge=1, le=100_000_000)]


class Contract(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class Checkout(Contract):
    transaction_id: UUID
    country: Country
    brand: Brand
    sku: Sku
    quantity: Annotated[int, Field(strict=True, ge=1, le=100)]


class Posting(Checkout):
    schema_version: Literal[1] = 1
    currency: Literal["EUR"] = "EUR"
    unit_price_cents: Cents
    amount_cents: Cents

    @model_validator(mode="after")
    def exact_total(self) -> "Posting":
        if self.amount_cents != self.quantity * self.unit_price_cents:
            raise ValueError("amount_cents must equal quantity * unit_price_cents")
        return self


class Lookup(Contract):
    transaction_ids: Annotated[list[UUID], Field(min_length=1, max_length=100)]


class Price(Contract):
    sku: Sku
    currency: Literal["EUR"] = "EUR"
    unit_price_cents: Cents


class Conflict(Exception):
    """A stable identifier was reused for different immutable business data."""


class EvidenceUnavailable(Exception):
    """An authoritative dependency did not supply valid evidence."""


def euros(cents: int) -> str:
    return f"{cents // 100}.{cents % 100:02d}"
