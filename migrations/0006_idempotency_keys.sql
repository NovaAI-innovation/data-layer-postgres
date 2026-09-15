-- 0006_idempotency_keys.sql
--
-- Promote idempotency keys from a redis-only concern to a durable
-- postgres primary. Per ADR
-- data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md,
-- idempotency must survive audit and replay; TTL on the redis cache
-- is therefore advisory only, and the postgres table is the
-- correctness boundary.
--
-- Adds:
--   * idempotency_keys table          (one row per (scope, key);
--                                       response_payload is the cached
--                                       result of the first successful
--                                       execution)
--   * Helper function claim_idempotency_key() that returns 'fresh',
--     'in_progress', or 'completed' atomically.
--
-- Idempotent. Run AFTER 0005_tool_executions_lifecycle.sql.

BEGIN;

-- 1. Idempotency keys table.
CREATE TABLE IF NOT EXISTS idempotency_keys (
    -- Composite identity: scope determines the namespace (e.g. 'tool',
    -- 'webhook', 'message'), key is the caller-supplied opaque token.
    scope                text        NOT NULL,
    key                  text        NOT NULL,
    agent_id             uuid        REFERENCES agents(id) ON DELETE SET NULL,
    session_id           uuid        REFERENCES sessions(id) ON DELETE SET NULL,
    tool_execution_id    uuid        REFERENCES tool_executions(id) ON DELETE SET NULL,
    status               text        NOT NULL DEFAULT 'in_progress'
                                    CHECK (status IN ('in_progress','completed','failed','expired')),
    response_payload     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    expires_at           timestamptz,

    CONSTRAINT pk_idempotency_keys PRIMARY KEY (scope, key)
);

CREATE INDEX IF NOT EXISTS idx_idempotency_keys_agent
    ON idempotency_keys(agent_id)
    WHERE agent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_session
    ON idempotency_keys(session_id)
    WHERE session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_status_expires
    ON idempotency_keys(status, expires_at)
    WHERE status IN ('in_progress','completed');
CREATE INDEX IF NOT EXISTS idx_idempotency_keys_tool_execution
    ON idempotency_keys(tool_execution_id)
    WHERE tool_execution_id IS NOT NULL;

-- 2. updated_at trigger (matches the convention of other tables in
--    0001_init.sql which set updated_at = now() in application code).
CREATE OR REPLACE FUNCTION touch_idempotency_keys_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_idempotency_keys_touch ON idempotency_keys;
CREATE TRIGGER trg_idempotency_keys_touch
    BEFORE UPDATE ON idempotency_keys
    FOR EACH ROW
    EXECUTE FUNCTION touch_idempotency_keys_updated_at();

-- 3. Atomic claim function. Returns:
--    'fresh'      -- caller is the first; should proceed.
--    'in_progress' -- another caller is processing; caller should wait
--                    or 409.
--    'completed'  -- caller should replay the cached response_payload.
--    'failed'     -- previous attempt failed; caller should retry
--                    (touches updated_at so audit shows the retry).
CREATE OR REPLACE FUNCTION claim_idempotency_key(
    p_scope   text,
    p_key     text,
    p_ttl_s   integer DEFAULT 86400
) RETURNS TABLE (
    status          text,
    response_payload jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_now      timestamptz := now();
    v_expires  timestamptz := now() + make_interval(secs => p_ttl_s);
    v_existing idempotency_keys%ROWTYPE;
BEGIN
    -- Lock the row if it exists.
    SELECT * INTO v_existing
    FROM idempotency_keys
    WHERE scope = p_scope AND key = p_key
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO idempotency_keys (scope, key, status, expires_at)
        VALUES (p_scope, p_key, 'in_progress', v_expires);
        RETURN QUERY SELECT 'fresh'::text, '{}'::jsonb;
        RETURN;
    END IF;

    IF v_existing.status = 'in_progress' THEN
        RETURN QUERY SELECT v_existing.status, v_existing.response_payload;
        RETURN;
    END IF;

    IF v_existing.status = 'completed' THEN
        RETURN QUERY SELECT v_existing.status, v_existing.response_payload;
        RETURN;
    END IF;

    IF v_existing.status IN ('failed','expired') THEN
        UPDATE idempotency_keys
           SET status = 'in_progress',
               updated_at = v_now,
               expires_at = v_expires
         WHERE scope = p_scope AND key = p_key;
        RETURN QUERY SELECT 'fresh'::text, '{}'::jsonb;
        RETURN;
    END IF;

    -- Defensive fallback (should be unreachable given the CHECK).
    RETURN QUERY SELECT 'failed'::text, '{}'::jsonb;
END;
$$;

-- 4. Helper to mark a claim completed / failed.
CREATE OR REPLACE FUNCTION finish_idempotency_key(
    p_scope   text,
    p_key     text,
    p_status  text,
    p_payload jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE sql
AS $$
    UPDATE idempotency_keys
       SET status = p_status,
           response_payload = p_payload
     WHERE scope = p_scope AND key = p_key;
$$;

COMMIT;
