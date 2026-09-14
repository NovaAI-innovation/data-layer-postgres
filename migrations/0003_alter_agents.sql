-- 0003_alter_agents.sql
--
-- Add `agents.deployment` and rebuild the unique constraint to include it.
-- Idempotent. Run AFTER 0001_init.sql and 0002_seed.sql.
--
-- See: docs/agent-persistence-schema-plan.md (Conventions + Migration impact).

BEGIN;

ALTER TABLE agents
    ADD COLUMN IF NOT EXISTS deployment text NOT NULL DEFAULT '';

ALTER TABLE agents
    DROP CONSTRAINT IF EXISTS uq_agent_business_key;

ALTER TABLE agents
    ADD CONSTRAINT uq_agent_business_key
    UNIQUE (framework_id, framework_local_id, deployment);

-- Migrate the existing local row from the prior '-sbzm' label to the
-- container-name + deployment tag (per the plan). `$(hostname)` is
-- substituted at apply time (e.g. `52ba0cdf32af` locally).
UPDATE agents
   SET framework_local_id = '__CONTAINER_NAME__',
       deployment         = 'local'
 WHERE framework_local_id = 'agent-zero-sbzm'
   AND deployment         = '';

COMMIT;
