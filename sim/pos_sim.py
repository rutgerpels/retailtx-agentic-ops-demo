import argparse
import time
from uuid import NAMESPACE_URL, uuid5

import httpx
from retailtx.contracts import PRICES, Checkout, Country, Posting, Sku, euros
from retailtx.http import client
from retailtx.settings import Settings
from retailtx.telemetry import SpanKind, carrier, configure, event, tracer

COUNTRY_MIX: tuple[Country, ...] = (
    "NL",
    "NL",
    "BE",
    "NL",
    "BE",
    "DE",
    "NL",
    "BE",
    "FR",
    "NL",
    "BE",
    "DE",
)
SKUS: tuple[Sku, ...] = ("basket-a", "basket-b", "basket-c")


def dataset(seed: str, count: int) -> list[Checkout]:
    if not seed or len(seed) > 64 or not 1 <= count <= 10_000:
        raise ValueError("Supply a 1-64 character synthetic seed and 1-10000 transactions")
    return [
        Checkout(
            transaction_id=uuid5(NAMESPACE_URL, f"retailtx/{seed}/{index}"),
            country=COUNTRY_MIX[index % len(COUNTRY_MIX)],
            brand="market" if index % 2 == 0 else "fresh",
            sku=SKUS[index % len(SKUS)],
            quantity=index % 3 + 1,
        )
        for index in range(count)
    ]


def main() -> None:
    parser = argparse.ArgumentParser(description="Bounded, deterministic synthetic checkout load")
    parser.add_argument("--seed", default="demo01")
    parser.add_argument("--count", type=int, default=12)
    parser.add_argument("--interval", type=float, default=0.1)
    args = parser.parse_args()
    if not 0 <= args.interval <= 5:
        parser.error("--interval must be between 0 and 5 seconds")
    rows = dataset(args.seed, args.count)
    settings = Settings.from_env()
    configure("pos-sim", settings)
    expected = sum(PRICES[row.sku] * row.quantity for row in rows)
    with client(settings, settings.cap_url, timeout=5) as http:
        for row in rows:
            with tracer.start_as_current_span("pos.checkout", kind=SpanKind.CLIENT):
                for attempt in range(3):
                    try:
                        response = http.post(
                            "/transaction", json=row.model_dump(mode="json"), headers=carrier()
                        )
                        response.raise_for_status()
                        posting = Posting.model_validate(response.json())
                        if posting.transaction_id != row.transaction_id:
                            raise RuntimeError("Checkout returned a different transaction")
                        break
                    except (httpx.TransportError, httpx.HTTPStatusError) as exc:
                        if attempt == 2 or (
                            isinstance(exc, httpx.HTTPStatusError)
                            and exc.response.status_code < 500
                        ):
                            raise
                        time.sleep(0.5 * 2**attempt)
            time.sleep(args.interval)
    event(
        "load.completed",
        seed=args.seed,
        unique_transactions=len(rows),
        expected_cents=expected,
        expected_eur=euros(expected),
    )


if __name__ == "__main__":
    main()
