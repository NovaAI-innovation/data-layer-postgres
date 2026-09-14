-- 0001_init.sql
--
-- Initial schema for the unified agent persistence layer.
-- Replaces the previous 3-table layout (conversations, messages, tool_calls)
-- with the 10-table design that adds agent identity, capability rows,
-- lifecycle hooks, project scoping, and richer execution metadata.
--
-- Target: Postgres 14+
-- Apply with: psql -f 0001_init.sql
--
-- Idempotent: uses IF NOT EXISTS on all CREATE statements.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────
-- Enable required extensions
-- ─────────────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";  -- for uuid_generate_v4()


-- ─────────────────────────────────────────────────────────────────────────
-- projects
-- ─────────────────────────────────────────────────────────────────────────
-- Workspace or tenant that owns a set of agents. Sessions/messages/
-- tool_executions inherit project scope through the agent join.

CREATE TABLE IF NOT EXISTS projects (
    id           uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_key  text        UNIQUE NOT NULL,
    display_name text        NOT NULL,
    description  text,
    status       text        NOT NULL DEFAULT 'active'
                             CHECK (status IN ('active','archived')),
    metadata     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);


-- ─────────────────────────────────────────────────────────────────────────
-- agent_frameworks
-- ─────────────────────────────────────────────────────────────────────────
-- Registry of frameworks that write into this schema. Adapters dispatch
-- on `kind`.

CREATE TABLE IF NOT EXISTS agent_frameworks (
    id           uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    kind         text        UNIQUE NOT NULL,
    display_name text        NOT NULL,
    version      text,
    metadata     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now()
);


-- ─────────────────────────────────────────────────────────────────────────
-- agents
-- ─────────────────────────────────────────────────────────────────────────
-- Individual agents from any framework. Business key:
-- (framework_id, framework_local_id).

CREATE TABLE IF NOT EXISTS agents (
    id                 uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    project_id          uuid        NOT NULL REFERENCES projects(id),
    framework_id        uuid        NOT NULL REFERENCES agent_frameworks(id),
    framework_local_id  text        NOT NULL,
    display_name        text,
    profile_key         text,
    status              text        NOT NULL DEFAULT 'active'
                                     CHECK (status IN ('active','disabled','archived')),
    metadata            jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_agent_business_key UNIQUE (framework_id, framework_local_id)
);

CREATE INDEX IF NOT EXISTS idx_agents_framework_status ON agents(framework_id, status);
CREATE INDEX IF NOT EXISTS idx_agents_project          ON agents(project_id);


-- ─────────────────────────────────────────────────────────────────────────
-- agent_skills
-- ─────────────────────────────────────────────────────────────────────────
-- Skills loaded for an agent.

CREATE TABLE IF NOT EXISTS agent_skills (
    id         uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id   uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    skill_key  text        NOT NULL,
    source     text        NOT NULL
                           CHECK (source IN ('core','plugin','user')),
    version    text,
    manifest   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    enabled    boolean     NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_agent_skill UNIQUE (agent_id, skill_key, source)
);

CREATE INDEX IF NOT EXISTS idx_agent_skills_agent ON agent_skills(agent_id);


-- ─────────────────────────────────────────────────────────────────────────
-- agent_plugins
-- ─────────────────────────────────────────────────────────────────────────
-- Plugins registered for an agent.

CREATE TABLE IF NOT EXISTS agent_plugins (
    id           uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id     uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    plugin_key   text        NOT NULL,
    version      text,
    manifest     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    enabled      boolean     NOT NULL DEFAULT true,
    installed_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_agent_plugin UNIQUE (agent_id, plugin_key)
);

CREATE INDEX IF NOT EXISTS idx_agent_plugins_agent ON agent_plugins(agent_id);


-- ─────────────────────────────────────────────────────────────────────────
-- available_tools
-- ─────────────────────────────────────────────────────────────────────────
-- Per-agent tool grants. Parallel to skills and plugins — each row is
-- "agent X has access to tool Y".

CREATE TABLE IF NOT EXISTS available_tools (
    id         uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id   uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    tool_key   text        NOT NULL,
    category   text,
    version    text,
    manifest   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    enabled    boolean     NOT NULL DEFAULT true,
    granted_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    metadata   jsonb       NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT uq_agent_tool UNIQUE (agent_id, tool_key)
);

CREATE INDEX IF NOT EXISTS idx_available_tools_agent  ON available_tools(agent_id);
CREATE INDEX IF NOT EXISTS idx_available_tools_tool   ON available_tools(tool_key);


-- ─────────────────────────────────────────────────────────────────────────
-- hooks
-- ─────────────────────────────────────────────────────────────────────────
-- Lifecycle event handlers per agent. Fired in priority order at runtime.

CREATE TABLE IF NOT EXISTS hooks (
    id          uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id    uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    event_type  text        NOT NULL,
    handler_key text        NOT NULL,
    priority    integer     NOT NULL DEFAULT 100,
    config      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    enabled     boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_hook UNIQUE (agent_id, event_type, handler_key)
);

CREATE INDEX IF NOT EXISTS idx_hooks_fire_order
    ON hooks(agent_id, event_type, priority);


-- ─────────────────────────────────────────────────────────────────────────
-- sessions
-- ─────────────────────────────────────────────────────────────────────────
-- Runtime windows for an agent. A session groups messages and tool calls.

CREATE TABLE IF NOT EXISTS sessions (
    id          uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id    uuid        NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    session_key text        NOT NULL,
    status      text        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active','closed','crashed')),
    started_at  timestamptz NOT NULL DEFAULT now(),
    ended_at    timestamptz,
    metadata    jsonb       NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT uq_session UNIQUE (agent_id, session_key)
);

CREATE INDEX IF NOT EXISTS idx_sessions_agent_started
    ON sessions(agent_id, started_at DESC);


-- ─────────────────────────────────────────────────────────────────────────
-- messages
-- ─────────────────────────────────────────────────────────────────────────
-- All agent traffic, either direction. Self-FK for threading.

CREATE TABLE IF NOT EXISTS messages (
    id                uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id         uuid        NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    agent_id           uuid        NOT NULL REFERENCES agents(id),
    direction          text        NOT NULL
                                    CHECK (direction IN ('in','out')),
    peer_agent_id      uuid        REFERENCES agents(id),
    role               text        NOT NULL
                                    CHECK (role IN ('user','assistant','tool','system')),
    content            text        NOT NULL,
    content_type       text        NOT NULL DEFAULT 'text',
    thread_id          uuid,
    parent_message_id  uuid        REFERENCES messages(id) ON DELETE SET NULL,
    external_ref       jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_messages_agent_time
    ON messages(agent_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_session_time
    ON messages(session_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_thread_time
    ON messages(thread_id, created_at)
    WHERE thread_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_messages_direction_time
    ON messages(direction, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_external_ref
    ON messages USING GIN (external_ref);


-- ─────────────────────────────────────────────────────────────────────────
-- tool_executions
-- ─────────────────────────────────────────────────────────────────────────
-- Every tool call as a durable record. Links to triggering message and
-- parent execution for sub-calls.

CREATE TABLE IF NOT EXISTS tool_executions (
    id                  uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id            uuid        NOT NULL REFERENCES agents(id),
    session_id          uuid        REFERENCES sessions(id) ON DELETE SET NULL,
    message_id          uuid        REFERENCES messages(id) ON DELETE SET NULL,
    tool_name           text        NOT NULL,
    arguments           jsonb       NOT NULL DEFAULT '{}'::jsonb,
    result              jsonb,
    status              text        NOT NULL
                                    CHECK (status IN ('pending','success','error','blocked')),
    started_at          timestamptz NOT NULL DEFAULT now(),
    finished_at         timestamptz,
    duration_ms         integer,
    error               text,
    parent_execution_id uuid        REFERENCES tool_executions(id) ON DELETE SET NULL,
    external_ref        jsonb       NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT chk_duration_positive
        CHECK (duration_ms IS NULL OR duration_ms >= 0)
);

CREATE INDEX IF NOT EXISTS idx_tool_executions_agent_time
    ON tool_executions(agent_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_tool_executions_session_time
    ON tool_executions(session_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_tool_executions_tool_time
    ON tool_executions(tool_name, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_tool_executions_message
    ON tool_executions(message_id);
CREATE INDEX IF NOT EXISTS idx_tool_executions_errors
    ON tool_executions(started_at DESC)
    WHERE status = 'error';


-- ─────────────────────────────────────────────────────────────────────────
-- updated_at triggers (lightweight)
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_projects_updated_at ON projects;
CREATE TRIGGER trg_projects_updated_at
    BEFORE UPDATE ON projects
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_agents_updated_at ON agents;
CREATE TRIGGER trg_agents_updated_at
    BEFORE UPDATE ON agents
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

DROP TRIGGER IF EXISTS trg_hooks_updated_at ON hooks;
CREATE TRIGGER trg_hooks_updated_at
    BEFORE UPDATE ON hooks
    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();


COMMIT;


-- ─────────────────────────────────────────────────────────────────────────
-- Seed (optional; comment out if running multiple times)
-- ─────────────────────────────────────────────────────────────────────────
--
-- INSERT INTO projects (project_key, display_name, description)
-- VALUES ('default', 'Default Project', 'Auto-created by 0001_init')
-- ON CONFLICT (project_key) DO NOTHING;
--
-- INSERT INTO agent_frameworks (kind, display_name, version)
-- VALUES ('agent_zero', 'Agent Zero', '2.11')
-- ON CONFLICT (kind) DO NOTHING;
