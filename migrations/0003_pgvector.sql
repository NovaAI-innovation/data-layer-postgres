-- 0003_pgvector.sql
--
-- Enable the pgvector extension and add an embedding column on messages
-- with a tuned HNSW index, helper function, and autovacuum config.
--
-- Idempotent. Run AFTER 0001_init.sql + 0002_alter_agents.sql.
--
-- This is the OPTIMIZED variant of pgvector setup. Optimization is
-- part of setup (per project policy).

BEGIN;

-- 1. Enable the extension.
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Tune index build resources (faster index builds).
--    Effective only for the CREATE INDEX below; reset is optional.
SET LOCAL max_parallel_maintenance_workers = 4;
SET LOCAL maintenance_work_mem = '2GB';

-- 3. Add an embedding column on messages.
--    1536 dims is the OpenAI text-embedding-3-* default. Override per
--    deployment by editing the dim constant and re-applying; an
--    idempotent dim change requires a re-embed job (out of scope).
ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- 4. HNSW index for approximate nearest-neighbour search.
--    Tuned for higher recall at modest build cost:
--      m = 24                  (graph degree; default 16)
--      ef_construction = 128   (build-time quality; default 64)
--    vector_cosine_ops for normalized text embeddings
--    (OpenAI, sentence-transformers, e5-*). For raw Euclidean
--    distance use vector_l2_ops.
DROP INDEX IF EXISTS idx_messages_embedding_hnsw;
CREATE INDEX idx_messages_embedding_hnsw
    ON messages USING hnsw (embedding vector_cosine_ops)
    WITH (m = 24, ef_construction = 128);

-- 5. Autovacuum tuning. HNSW maintenance is sensitive to bloat;
--    tighten the scale factors so autovacuum triggers earlier.
ALTER TABLE messages SET (
    autovacuum_vacuum_scale_factor   = 0.05,
    autovacuum_analyze_scale_factor = 0.02
);

-- 6. Helper function for ergonomic recall.
--    Returns top-K messages whose cosine similarity to the query
--    embedding exceeds a threshold. Default threshold and count are
--    tunable per call.
CREATE OR REPLACE FUNCTION match_messages(
    query_embedding   vector(1536),
    match_threshold   float   DEFAULT 0.7,
    match_count       int     DEFAULT 10,
    query_ef_search   int     DEFAULT 100
)
RETURNS TABLE (
    id           uuid,
    session_id   uuid,
    agent_id     uuid,
    direction    text,
    content      text,
    similarity   float
)
LANGUAGE sql STABLE
AS $$
    WITH params AS (
        SELECT SET_CONFIG('hnsw.ef_search', query_ef_search::text, true) AS _
    )
    SELECT
        m.id, m.session_id, m.agent_id, m.direction, m.content,
        1 - (m.embedding <=> query_embedding) AS similarity
    FROM messages m, params
    WHERE m.embedding IS NOT NULL
      AND 1 - (m.embedding <=> query_embedding) > match_threshold
    ORDER BY m.embedding <=> query_embedding
    LIMIT match_count;
$$;

-- 7. GIN keeps working on external_ref; pgvector's hnsw is the
--    recall path. No competing indexes.

COMMIT;
