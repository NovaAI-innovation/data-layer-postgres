-- 0004_session_presence.sql
--
-- Promote session presence (heartbeats) to a durable postgres primary.
-- Per ADR data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md,
-- session presence is audit-grade and therefore must live in postgres as
-- the source of truth. Redis is allowed as a hot cache for the most
-- recent N seconds; a redis miss or TTL expiry must never cause a
-- correctness failure.
--
-- Adds:
--   * sessions.last_heartbeat_at timestamptz   (nullable; first heartbeat
--                                             back-fills it)
--   * session_heartbeats table                (audit trail of every
--                                             heartbeat event for replay
--                                             and offline analysis)
--
-- Idempotent. Run AFTER 0003_pgvector.sql.

BEGIN;

-- 1. Last-heartbeat column on sessions. Back-fill from existing data is
--    NOT performed (we accept starting fresh on day 1 of the new schema).
ALTER TABLE sessions
    ADD COLUMN IF NOT EXISTS last_heartbeat_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_sessions_last_heartbeat
    ON sessions(last_heartbeat_at DESC)
    WHERE last_heartbeat_at IS NOT NULL;

-- 2. Per-event audit trail. One row per heartbeat. Idempotent insert
--    via (session_id, received_at, source) uniqueness — collisions
--    collide on the same logical heartbeat.
CREATE TABLE IF NOT EXISTS session_heartbeats (
    id           uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id   uuid        NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    received_at  timestamptz NOT NULL DEFAULT now(),
    source       text        NOT NULL DEFAULT 'adapter'
                             CHECK (source IN ('adapter','replay','import')),
    metadata     jsonb       NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT uq_session_heartbeat UNIQUE (session_id, received_at, source)
);

CREATE INDEX IF NOT EXISTS idx_session_heartbeats_session_time
    ON session_heartbeats(session_id, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_session_heartbeats_received_at
    ON session_heartbeats(received_at DESC);

-- 3. Helper function: update both columns atomically.
CREATE OR REPLACE FUNCTION record_session_heartbeat(
    p_session_id uuid,
    p_source     text   DEFAULT 'adapter',
    p_metadata   jsonb  DEFAULT '{}'::jsonb
) RETURNS timestamptz
LANGUAGE plpgsql
AS $$
DECLARE
    v_now timestamptz := now();
BEGIN
    INSERT INTO session_heartbeats (session_id, received_at, source, metadata)
    VALUES (p_session_id, v_now, p_source, p_metadata)
    ON CONFLICT (session_id, received_at, source) DO NOTHING;

    UPDATE sessions
       SET last_heartbeat_at = v_now
     WHERE id = p_session_id;

    RETURN v_now;
END;
$$;

COMMIT;
