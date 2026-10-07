ALTER TABLE outbox DROP CONSTRAINT outbox_state_check;
ALTER TABLE outbox ADD CONSTRAINT outbox_state_check
    CHECK (state IN ('pending', 'sent', 'blocked', 'confirmed'));
ALTER TABLE outbox ADD COLUMN confirmed_at timestamptz;
