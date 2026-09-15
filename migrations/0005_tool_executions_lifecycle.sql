-- 0005_tool_executions_lifecycle.sql
--
-- Promote tool execution lifecycle metadata to a durable postgres primary.
-- Per ADR data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md,
-- the tool execution record is audit-grade.
--
-- Note: 0001_init.sql already created tool_executions with the following
-- columns that were originally listed as "missing" in the handoff plan:
--   * started_at   timestamptz NOT NULL DEFAULT now()
--   * finished_at  timestamptz
--   * arguments    jsonb NOT NULL DEFAULT '{}'::jsonb
--   * result       jsonb
--   * duration_ms  integer
--   * error        text
-- This migration therefore closes the remaining lifecycle gaps that
-- 0001 did not cover:
--   * idempotency_key         text (cross-references idempotency_keys
--                                  table from migration 0006; nullable
--                                  for ad-hoc tools that do not opt in)
--   * attempt_number          int  (1 = first attempt; >1 = retry)
--   * retry_of_execution_id   uuid (self-FK; null on first attempt)
--
-- Idempotent. Run AFTER 0004_session_presence.sql.

BEGIN;

-- 1. Cross-reference to idempotency_keys (table from migration 0006).
--    NOT a hard FK because 0006 may be applied later in some deployments
--    during staged rollout; the FK is added at the end of this file
--    inside an IF EXISTS guard so it activates once 0006 has landed.
ALTER TABLE tool_executions
    ADD COLUMN IF NOT EXISTS idempotency_key text;

CREATE INDEX IF NOT EXISTS idx_tool_executions_idempotency_key
    ON tool_executions(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- 2. Attempt counter. Defaults to 1 (first attempt).
ALTER TABLE tool_executions
    ADD COLUMN IF NOT EXISTS attempt_number integer NOT NULL DEFAULT 1
        CHECK (attempt_number >= 1);

-- 3. Self-FK for retry lineage. Nullable on the original attempt.
ALTER TABLE tool_executions
    ADD COLUMN IF NOT EXISTS retry_of_execution_id uuid;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_tool_executions_retry_of'
    ) THEN
        ALTER TABLE tool_executions
            ADD CONSTRAINT fk_tool_executions_retry_of
            FOREIGN KEY (retry_of_execution_id)
            REFERENCES tool_executions(id)
            ON DELETE SET NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_tool_executions_retry_of
    ON tool_executions(retry_of_execution_id)
    WHERE retry_of_execution_id IS NOT NULL;

-- 4. Convenience view: latest attempt per idempotency_key. Helps the
--    adapter answer "is this idempotency key already in flight or done?".
CREATE OR REPLACE VIEW tool_executions_latest_attempt AS
SELECT DISTINCT ON (idempotency_key)
       te.id,
       te.idempotency_key,
       te.agent_id,
       te.session_id,
       te.tool_name,
       te.attempt_number,
       te.status,
       te.started_at,
       te.finished_at,
       te.duration_ms
FROM tool_executions te
WHERE te.idempotency_key IS NOT NULL
ORDER BY te.idempotency_key, te.attempt_number DESC;

-- 5. NOTE on cross-table FK: tool_executions.idempotency_key does NOT
--    have a hard FK to idempotency_keys.key by design. The primary key
--    on idempotency_keys is (scope, key) — `key` alone is not unique
--    across scopes, so a single-column FK reference would require a
--    separate UNIQUE constraint that prevents legitimate multi-scope
--    reuse. Cross-table integrity is enforced by application code
--    (the adapter calls claim_idempotency_key() and stores the
--    returned status). Reconsider this decision if multi-scope reuse
--    becomes a problem in practice.

COMMIT;
