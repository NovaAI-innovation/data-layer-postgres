-- 0004_seed_hermes.sql
--
-- Seed the Hermes agent row. Run on the Hermes host AFTER 0001_init,
-- 0002_seed, 0003_alter_agents.
--
-- See: docs/agent-persistence-schema-plan.md (Conventions + Migration impact).

BEGIN;

INSERT INTO agent_frameworks (kind, display_name, version)
VALUES ('agent_zero', 'Agent Zero', '2.11')
ON CONFLICT (kind) DO NOTHING;

INSERT INTO agents (project_id, framework_id, framework_local_id,
                    deployment, display_name, profile_key, status, metadata)
SELECT p.id, f.id,
       '__HERMES_CONTAINER_NAME__',  -- substituted at apply time on the Hermes host
       'hermes',
       'Hermes root',
       'hermes',
       'active',
       jsonb_build_object(
           'host',        'hermes.tailbcc871.ts.net',
           'address',     '100.64.49.70:8091',
           'mcp_service', 'az-retrieval-mcp',
           'kanban',      true)
  FROM projects p, agent_frameworks f
 WHERE p.project_key = 'default'
   AND f.kind        = 'agent_zero'
ON CONFLICT (framework_id, framework_local_id, deployment) DO NOTHING;

COMMIT;
