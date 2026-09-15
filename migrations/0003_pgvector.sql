-- 0003_pgvector.sql
--
-- Add the pgvector extension and an embedding column on messages.
-- Idempotent. Run AFTER 0001_init.sql + 0002_alter_agents.sql.
--
-- This migration widens the persistence layer to support vector
-- similarity search at the database level. The FAISS index at
-- .a0proj/memory/ continues to be the agent-runtime cache; this
-- column lets the database answer recall queries when the FAISS
-- cache is cold or absent.

BEGIN;

-- 1. Enable the extension.
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Add an embedding column on messages.
--    1536 dims is the OpenAI text-embedding-3-* default. Override per
--    deployment by editing the dim constant and re-applying this
--    migration; an idempotent ALTER TYPE step would require a custom
--    re-embed job and is out of scope for this migration.
ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- 3. HNSW index for approximate nearest-neighbour search.
--    vector_cosine_ops is the right operator for normalized text
--    embeddings (OpenAI's, sentence-transformers' all-mpnet-base-v2,
--    e5-* models). Use vector_l2_ops for raw Euclidean distance.
CREATE INDEX IF NOT EXISTS idx_messages_embedding_hnsw
    ON messages USING hnsw (embedding vector_cosine_ops);

-- 4. GIN keeps working on external_ref; pgvector's hnsw is the new
--    recall path. No competing indexes.

COMMIT;
