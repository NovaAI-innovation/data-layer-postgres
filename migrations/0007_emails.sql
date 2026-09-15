-- 0007_emails.sql
--
-- Add the emails table to the data-layer postgres schema.
--
-- Email is the only inbound + outbound integration that is BOTH
-- audit-grade (every inbound row is a contractual record of a real
-- communication that needs to survive replay) AND high-volume (so we
-- keep the heavy text in postgres and only mirror the body to the
-- semantic index in data-layer-qdrant).
--
-- Per the data-layer architecture:
--   * postgres is the immutable historical record (this table).
--   * qdrant is the derived semantic index (mpg_emails collection).
--   * falkordb will hold graph edges (thread + reply_to).
--   * redis is the ephemeral cache (poll cursors, dedupe keys).
--
-- The qdrant_point_id + qdrant_ingested_y_n columns make the join
-- between the two layers explicit and idempotent: re-running the
-- seed/ingest pipeline updates the row, never the other way around.
--
-- Self-FK on in_reply_to is added at the bottom of this file inside
-- a DO block (because the table does not exist at CREATE time, a
-- REFERENCES clause on the same CREATE TABLE would fail).
--
-- Idempotent. Run AFTER 0006_idempotency_keys.sql.

BEGIN;

-- 1. Emails table.
CREATE TABLE IF NOT EXISTS emails (
    id                  uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    -- FK to agents (nullable for inbound external mail where no agent
    -- is on the receiving side yet, or for system-generated records).
    agent_id            uuid REFERENCES agents(id) ON DELETE SET NULL,
    -- 'in' for inbound (received), 'out' for outbound (sent by an agent).
    direction           text NOT NULL CHECK (direction IN ('in','out')),
    -- RFC 5322 Message-ID. UNIQUE so the same message cannot be
    -- ingested twice (idempotency on the inbox side).
    message_id          text UNIQUE NOT NULL,
    -- FK to the parent message (its Message-ID), nullable on thread
    -- roots. Self-reference added below.
    in_reply_to         text,
    -- Conversation identifier. Stable across the whole thread even when
    -- in_reply_to is missing on intermediate hops. uuid so falkordb can
    -- graph-link messages that share a thread.
    thread_id           uuid,
    subject             text NOT NULL,
    from_email          text NOT NULL,
    to_emails           jsonb NOT NULL DEFAULT '[]'::jsonb,
    cc_emails           jsonb NOT NULL DEFAULT '[]'::jsonb,
    bcc_emails          jsonb NOT NULL DEFAULT '[]'::jsonb,
    body                text NOT NULL,
    body_html           text,
    -- Full raw MIME source for forensic / re-parse purposes. May be
    -- NULL for synthetic rows generated internally.
    raw_mime            text,
    attachments         jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- Catch-all for inbox-provider specific metadata (gmail label ids,
    -- IMAP uid, exchange conversation index, etc.). Free-form JSONB.
    external_ref        jsonb NOT NULL DEFAULT '{}'::jsonb,
    received_at         timestamptz NOT NULL DEFAULT now(),
    sent_at             timestamptz,
    ingested_at         timestamptz NOT NULL DEFAULT now(),
    -- FK to projects (nullable for system/global mail not tied to a
    -- project). Lets rag.search filter by project_id without a join.
    project_id          uuid REFERENCES projects(id) ON DELETE SET NULL,
    -- The qdrant point UUID this email is embedded under. NULL until
    -- the embedding pipeline has run. UNIQUE so we cannot double-upsert.
    qdrant_point_id     uuid UNIQUE,
    -- Gate column the qdrant pipeline writes against. Default 'N'
    -- means "not yet ingested". 'SUPERSEDED' marks rows replaced by
    -- a newer version (e.g. retry / re-embed). 'DO_NOT_INGEST' is for
    -- rows that must be retained in postgres but excluded from the
    -- semantic index (bounce notices, system messages, etc.).
    qdrant_ingested_y_n text NOT NULL DEFAULT 'N'
                         CHECK (qdrant_ingested_y_n IN ('Y','N','SUPERSEDED','DO_NOT_INGEST')),

    -- Direction + message_id together is unique enough to identify a
    -- row from one provider (an inbound gmail message-id will never
    -- collide with an outbound smtp message-id for the same address
    -- pair). We rely on the per-column UNIQUE on message_id above.

    -- A sent email MUST have sent_at; a received email MUST have
    -- received_at. Both columns allow NULL in general; the constraint
    -- below enforces the invariant per direction.
    CONSTRAINT chk_emails_direction_ts CHECK (
        (direction = 'in'  AND received_at IS NOT NULL) OR
        (direction = 'out' AND sent_at     IS NOT NULL)
    )
);

-- 2. Indexes.
CREATE INDEX IF NOT EXISTS idx_emails_thread
    ON emails(thread_id, received_at DESC NULLS LAST)
    WHERE thread_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_emails_from
    ON emails(from_email, received_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS idx_emails_received
    ON emails(received_at DESC NULLS LAST);

-- UNIQUE on message_id already creates a btree; we add a partial
-- index on the lookup pattern the qdrant ingestion pipeline uses:
-- "what rows still need to be ingested?".
CREATE INDEX IF NOT EXISTS idx_emails_qdrant_pending
    ON emails(qdrant_ingested_y_n)
    WHERE qdrant_ingested_y_n IN ('N','SUPERSEDED');

CREATE INDEX IF NOT EXISTS idx_emails_project
    ON emails(project_id)
    WHERE project_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_emails_agent
    ON emails(agent_id)
    WHERE agent_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_emails_qdrant_point
    ON emails(qdrant_point_id)
    WHERE qdrant_point_id IS NOT NULL;

-- 3. Self-FK on in_reply_to. Added here (not in CREATE TABLE) because
--    postgres requires the referenced table to exist at the time of
--    constraint creation. Guarded so re-runs are no-ops.
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_emails_in_reply_to'
    ) THEN
        ALTER TABLE emails
            ADD CONSTRAINT fk_emails_in_reply_to
            FOREIGN KEY (in_reply_to)
            REFERENCES emails(message_id)
            ON DELETE SET NULL;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_emails_in_reply_to
    ON emails(in_reply_to)
    WHERE in_reply_to IS NOT NULL;

-- 4. updated_at trigger to match the convention used by other tables
--    (0001_init.sql sets updated_at in app code; this one column is
--    a kept simple because emails are largely append-only — the
--    only column that meaningfully changes post-insert is
--    qdrant_ingested_y_n and we touch ingested_at instead).
--
-- We deliberately do NOT add an updated_at column here; the
-- audit trail for an email is (ingested_at, received_at, sent_at).

-- 5. Convenience view for the qdrant ingestion pipeline: "rows that
--    still need to be ingested, joined to the project for permission
--    filtering".
CREATE OR REPLACE VIEW emails_pending_qdrant_ingest AS
SELECT e.id, e.message_id, e.thread_id, e.direction, e.subject,
       e.from_email, e.to_emails, e.cc_emails, e.bcc_emails,
       e.body, e.attachments, e.external_ref,
       e.received_at, e.sent_at, e.ingested_at,
       e.project_id, e.qdrant_point_id, e.qdrant_ingested_y_n
FROM emails e
WHERE e.qdrant_ingested_y_n IN ('N','SUPERSEDED');

-- 6. Convenience view: full thread reconstruction in chronological
--    order. Useful for "show me the whole email conversation" UIs.
CREATE OR REPLACE VIEW emails_thread_chronological AS
SELECT e.id, e.message_id, e.thread_id, e.in_reply_to,
       e.direction, e.from_email, e.to_emails, e.subject,
       e.body, e.received_at, e.sent_at
FROM emails e
WHERE e.thread_id IS NOT NULL
ORDER BY e.thread_id,
         COALESCE(e.received_at, e.sent_at) ASC;

COMMIT;
