CREATE TABLE accepted_transactions (
    sequence bigint GENERATED ALWAYS AS IDENTITY UNIQUE NOT NULL,
    transaction_id uuid PRIMARY KEY,
    country text NOT NULL CHECK (country IN ('NL', 'BE', 'DE', 'FR')),
    brand text NOT NULL CHECK (brand IN ('market', 'fresh')),
    amount_cents bigint NOT NULL CHECK (amount_cents BETWEEN 1 AND 100000000),
    request jsonb NOT NULL,
    posting jsonb NOT NULL,
    accepted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE outbox (
    transaction_id uuid PRIMARY KEY REFERENCES accepted_transactions(transaction_id),
    trace_context jsonb NOT NULL,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'sent', 'blocked')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    sent_at timestamptz,
    last_error text
);
CREATE INDEX outbox_pending ON outbox(next_attempt_at) WHERE state = 'pending';

CREATE TABLE reconciliation (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    attempted_at timestamptz NOT NULL,
    last_success_at timestamptz,
    last_success jsonb,
    error text
);

CREATE TABLE recovery_events (
    sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    action text NOT NULL,
    transaction_count bigint NOT NULL
);
