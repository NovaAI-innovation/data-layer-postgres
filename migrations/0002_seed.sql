-- 0000_seed.sql
--
-- Seeds the minimum rows needed for a fresh deployment to be usable.
-- Run AFTER 0001_init.sql. Safe to re-run (idempotent).

BEGIN;

INSERT INTO agent_frameworks (kind, display_name, version)
VALUES ('agent_zero', 'Agent Zero', '2.11')
ON CONFLICT (kind) DO NOTHING;

INSERT INTO projects (project_key, display_name, description)
VALUES ('default', 'Default Project',
        'Workspace for the agent-zero-sbzm instance')
ON CONFLICT (project_key) DO NOTHING;

INSERT INTO agents (id, project_id, framework_id, framework_local_id,
                    display_name, profile_key, status)
SELECT
    '11111111-1111-1111-1111-111111111111'::uuid,
    p.id,
    f.id,
    'agent-zero-sbzm',
    'a0',
    'agent0',
    'active'
FROM projects p, agent_frameworks f
WHERE p.project_key = 'default'
  AND f.kind        = 'agent_zero'
ON CONFLICT (framework_id, framework_local_id) DO NOTHING;

COMMIT;
