CREATE TABLE prices (
    sku text PRIMARY KEY,
    unit_price_cents bigint NOT NULL CHECK (unit_price_cents BETWEEN 1 AND 1000000)
);
INSERT INTO prices VALUES ('basket-a', 199), ('basket-b', 349), ('basket-c', 105);

CREATE TABLE ledger (
    transaction_id uuid PRIMARY KEY,
    posting jsonb NOT NULL,
    amount_cents bigint NOT NULL CHECK (amount_cents BETWEEN 1 AND 100000000),
    posted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE worker_control (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    fault_until timestamptz,
    heartbeat_at timestamptz,
    worker_state text CHECK (worker_state IN ('running', 'paused'))
);
INSERT INTO worker_control (singleton) VALUES (true);

CREATE TABLE change_events (
    sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    action text NOT NULL,
    expires_at timestamptz
);
