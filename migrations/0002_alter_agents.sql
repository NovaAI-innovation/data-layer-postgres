-- 0002_alter_agents.sql
--
-- Add agents.deployment and rebuild the unique constraint to include it.
-- Pure schema change. Idempotent.
--
-- Run AFTER 0001_init.sql. Safe to re-run.
--
-- Note: any operator with pre-existing seeded data (e.g. the legacy
-- 'agent-zero-sbzm' row inserted by an older 0002_seed.sql) should run
-- data-layer-adapters/agent-zero/seeds/0002_migrate_local_id.sql as a
-- one-shot to migrate their row to the new identity contract.

BEGIN;

ALTER TABLE agents
    ADD COLUMN IF NOT EXISTS deployment text NOT NULL DEFAULT '';

ALTER TABLE agents
    DROP CONSTRAINT IF EXISTS uq_agent_business_key;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'uq_agent_business_key'
  ) THEN
    ALTER TABLE agents
      ADD CONSTRAINT uq_agent_business_key
      UNIQUE (framework_id, framework_local_id, deployment);
  END IF;
END $$;

COMMIT;
