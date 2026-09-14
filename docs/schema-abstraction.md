# Agent Persistence Schema Plan (v2 — fresh)

**Goal.** A simple, framework-agnostic Postgres schema that records agent
identity, capabilities, messages, and tool executions for any agent
framework. Adapters translate framework-native payloads into schema rows;
consumers read a unified shape.

**Identity contract (per user, 2026-09-13, revised):**
`agent_frameworks.kind` is the **snake_case short name** of the
framework family (e.g. `agent_zero`);
`agents.framework_local_id` is the **running container's name** (e.g.
`52ba0cdf32af` for the local container, or whatever Docker assigned
the Hermes container). The `agents.deployment` column still tags
which logical host/workload the container belongs to, so two
containers of the same family running side by side are easy to
filter without relying on the runtime to invent unique ids.

## Reconciliation with the existing persistence layer

There is already an end-to-end persistence deployment at
`/a0/usr/projects/persistence-bootstrap/`:

- `migrations/0001_init.sql` — 10 tables: `projects`,
  `agent_frameworks`, `agents`, `agent_skills`, `agent_plugins`,
  `conversations`, `messages`, `tool_executions`, plus
  session-related tables.
- `migrations/0002_seed.sql` — seeds `agent_frameworks.kind =
  'agent_zero'`, `agents.framework_local_id = 'agent-zero-sbzm'`.
- `plugin/data_management/` — `ChatJsonAdapter` + `PostgresAdapter`
  for ingesting `usr/chats/<id>/chat.json`, plus `execute_sql` for
  ad-hoc reads/writes.
- `mcp/` — `persistence_mcp` Python package exposing five PostgreSQL-backed
  read tools over the rebuilt schema. Redis is a separate implementation.
- `bootstrap` CLI (v0.2.0) for one-shot install / component / bundle.

This plan is therefore **not** a from-scratch schema. It extends the
existing schema with the conventions below, so the Hermes deploy and
any future deployments share its structure.

## Conventions

Identity contract (per user, 2026-09-13, revised): every framework
row's `kind` is the framework-family short name (snake_case) and
`agents.framework_local_id` is the **running container's name**
(e.g. `52ba0cdf32af` for the local container, an analogous name for
the Hermes container). The `agents.deployment` column still tags the
logical host/workload (e.g. `local`, `hermes`) so two containers of
the same family running side by side are easy to filter and group.

- **`agent_frameworks.kind`** — snake_case short name of the framework
  family. One row per family. Examples: `agent_zero`.
- **`agents.framework_local_id`** — the **running container's name**,
  taken from the runtime (`hostname` / Docker-assigned short id, or
  whatever `--name` was passed at `docker run`). Examples:
  - local: `52ba0cdf32af` (current container's `hostname`)
  - Hermes: `<hermes_container_name>` (supplied at deploy time on
    the other VPS)
- **`agents.deployment`** — logical host/workload tag, independent of
  the container name. Examples: `local` for the `/a0` host;
  `hermes` for the other VPS. Useful for cross-container analytics
  without exposing infrastructure details.
- **Business key** — `UNIQUE (framework_id, framework_local_id,
  deployment)` so a future migration (container rename) and
  multi-container workloads can coexist. Replaces the prior `UNIQUE
  (framework_id, framework_local_id)`.
- **Migration impact** — the existing
  `migrations/0002_seed.sql` inserts `framework_local_id =
  'agent-zero-sbzm'` (a previous label, not the actual container
  name). Under the new contract that row must be replaced with
  `framework_local_id = '52ba0cdf32af', deployment = 'local'`
  (or whatever the operator confirms at deploy time). Hermes is
  inserted with its own container name and `deployment = 'hermes'`.

## Design principles

1. **One row per identity.** Every agent has exactly one row, addressed by
   a UUID PK and a `(framework_id, framework_local_id)` business key.
2. **Direction-aware messages.** A single `messages` table carries a
   `direction` column so incoming and outgoing traffic share one shape.
3. **Skills and plugins are siblings.** Same structure, distinct tables —
   each belongs to an agent and is keyed by name + source.
4. **Tool executions are durable.** Every tool call is a row that links
   to its triggering message and optionally to a parent execution for
   sub-calls.
5. **Native payload preserved.** Every table carries a free-form JSONB
   blob (`metadata` or `external_ref`) so framework-specific data lives
   without schema churn.
6. **Dispatch on `kind`.** Framework adapters dispatch on
   `agent_frameworks.kind`; switching kinds is a one-line edit per
   adapter.
7. **Sessions scope activity.** Every message and tool execution belongs
   to a session row (FK, nullable for legacy/bootstrap data). A session
   is a runtime window for one agent — it groups messages, tool calls,
   and lifecycle facts together. Tool executions connect back to their
   triggering message directly; ordering inside a session is recovered
   from `started_at`.
8. **Projects group agents.** A project is a workspace or tenant that
   owns a set of agents. `project_id` lives on `agents` only; sessions,
   messages, and tool executions inherit project scope through the agent
   join, keeping the schema lean.
9. **Tools are caps, hooks are events.** `available_tools` records the
   per-agent tool grants (parallel to skills and plugins). `hooks`
   records lifecycle handlers per agent, keyed by event type and
   priority so the runtime can fire them in order.

## Tables

### `agent_frameworks`

Registry of frameworks that write into this schema.

| Column        | Type                       | Notes                              |
|---------------|----------------------------|------------------------------------|
| id            | uuid PK                    | generated                          |
| kind          | text UNIQUE NOT NULL       | adapter-dispatch key, e.g. `agent_zero` |
| display_name  | text NOT NULL              |                                    |
| version       | text                       | framework version this row describes |
| metadata      | jsonb NOT NULL DEFAULT '{}' | framework-native facts             |
| created_at    | timestamptz NOT NULL DEFAULT now() |                          |

### `projects`

A project is a workspace or tenant that owns a set of agents. Sessions,
messages, and tool executions inherit project scope through the agent
join (`agents.project_id`), keeping the schema lean.

| Column       | Type                            | Notes                              |
|--------------|---------------------------------|------------------------------------|
| id           | uuid PK                         | generated                          |
| project_key  | text UNIQUE NOT NULL            | slug, e.g. `agent-persistence`    |
| display_name | text NOT NULL                   |                                    |
| description  | text                            |                                    |
| status       | text NOT NULL DEFAULT 'active'  | `active`, `archived`              |
| metadata     | jsonb NOT NULL DEFAULT '{}'     | framework-native facts             |
| created_at   | timestamptz NOT NULL DEFAULT now() |                                |
| updated_at   | timestamptz NOT NULL DEFAULT now() |                                |

- `INDEX (status)` — fast "active projects" filter.

### `agents`

Individual agents, one row per `(framework_id, framework_local_id,
deployment)` — see *Conventions* above for why deployment is part of
the business key.

| Column              | Type                                  | Notes                         |
|---------------------|---------------------------------------|-------------------------------|
| id                  | uuid PK                               | generated                     |
| project_id          | uuid FK → `projects.id` NOT NULL      | workspace or tenant           |
| framework_id        | uuid FK → `agent_frameworks.id` NOT NULL |                             |
| framework_local_id  | text NOT NULL                         | running container's name (e.g. `52ba0cdf32af` for the local container, `<hermes_container>` for the Hermes VPS) |
| deployment          | text NOT NULL                         | logical host/workload tag, e.g. `local`, `hermes` |
| display_name        | text                                  |                               |
| profile_key         | text                                  | optional profile/profile key  |
| status              | text NOT NULL DEFAULT 'active'        | `active`, `disabled`, `archived` |
| metadata            | jsonb NOT NULL DEFAULT '{}'           | framework-native blob (host, Tailscale, Kanban, MCP service, …) |
| created_at          | timestamptz NOT NULL DEFAULT now()    |                               |
| updated_at          | timestamptz NOT NULL DEFAULT now()    |                               |

- `UNIQUE (framework_id, framework_local_id, deployment)` — the business key.
- `INDEX (framework_id, status)`.
- `INDEX (deployment)` — fast "all agents on this host" queries.

### `sessions`

Runtime sessions for an agent. A session groups messages, tool calls,
and lifecycle facts for one runtime window.

| Column       | Type                                              | Notes                              |
|--------------|---------------------------------------------------|------------------------------------|
| id           | uuid PK                                           | generated                          |
| agent_id     | uuid FK → `agents.id` ON DELETE CASCADE NOT NULL  |                                    |
| session_key  | text NOT NULL                                     | framework-native session id        |
| status       | text NOT NULL DEFAULT 'active'                    | `active`, `closed`, `crashed`      |
| started_at   | timestamptz NOT NULL DEFAULT now()                |                                    |
| ended_at     | timestamptz                                       |                                    |
| metadata     | jsonb NOT NULL DEFAULT '{}'                      | framework-native facts             |

- `UNIQUE (agent_id, session_key)` — the business key.
- `INDEX (agent_id, started_at DESC)` — recent-session queries.

### `agent_skills`

Skills loaded for an agent.

| Column     | Type                                          | Notes                     |
|------------|-----------------------------------------------|---------------------------|
| id         | uuid PK                                       |                           |
| agent_id   | uuid FK → `agents.id` ON DELETE CASCADE        |                           |
| skill_key  | text NOT NULL                                 | e.g. `browser-automation` |
| source     | text NOT NULL                                 | `core`, `plugin`, `user`  |
| version    | text                                          |                           |
| manifest   | jsonb NOT NULL DEFAULT '{}'                   |                           |
| enabled    | boolean NOT NULL DEFAULT true                 |                           |
| created_at | timestamptz NOT NULL DEFAULT now()             |                           |

- `UNIQUE (agent_id, skill_key, source)`.

### `agent_plugins`

Plugins registered for an agent.

| Column       | Type                                          | Notes                  |
|--------------|-----------------------------------------------|------------------------|
| id           | uuid PK                                       |                        |
| agent_id     | uuid FK → `agents.id` ON DELETE CASCADE        |                        |
| plugin_key   | text NOT NULL                                 |                        |
| version      | text                                          |                        |
| manifest     | jsonb NOT NULL DEFAULT '{}'                   |                        |
| enabled      | boolean NOT NULL DEFAULT true                 |                        |
| installed_at | timestamptz NOT NULL DEFAULT now()             |                        |

- `UNIQUE (agent_id, plugin_key)`.

### `available_tools`

Per-agent tool grants. Parallel to `agent_skills` and `agent_plugins` —
each row is "agent X has access to tool Y".

| Column       | Type                                          | Notes                              |
|--------------|-----------------------------------------------|------------------------------------|
| id           | uuid PK                                       | generated                          |
| agent_id     | uuid FK → `agents.id` ON DELETE CASCADE NOT NULL |                                  |
| tool_key     | text NOT NULL                                 | e.g. `code_execution_tool`         |
| category     | text                                          | e.g. `filesystem`, `browser`, `search` |
| version      | text                                          |                                    |
| manifest     | jsonb NOT NULL DEFAULT '{}'                   | tool config / schema               |
| enabled      | boolean NOT NULL DEFAULT true                 |                                    |
| granted_at   | timestamptz NOT NULL DEFAULT now()             |                                    |
| revoked_at   | timestamptz                                   | populated when access is removed   |
| metadata     | jsonb NOT NULL DEFAULT '{}'                   | framework-native facts             |

- `UNIQUE (agent_id, tool_key)` — one active grant per pair.
- `INDEX (tool_key)` — "which agents have this tool?"

### `hooks`

Lifecycle event handlers per agent. The runtime fires hooks in
`priority` order when the corresponding `event_type` event occurs.

| Column        | Type                                          | Notes                              |
|---------------|-----------------------------------------------|------------------------------------|
| id            | uuid PK                                       | generated                          |
| agent_id      | uuid FK → `agents.id` ON DELETE CASCADE NOT NULL |                                  |
| event_type    | text NOT NULL                                 | `pre_message`, `post_tool_call`, `on_session_start`, … |
| handler_key   | text NOT NULL                                 | registered handler reference       |
| priority      | integer NOT NULL DEFAULT 100                  | lower = earlier                    |
| config        | jsonb NOT NULL DEFAULT '{}'                   | handler-specific config             |
| enabled       | boolean NOT NULL DEFAULT true                 |                                    |
| created_at    | timestamptz NOT NULL DEFAULT now()             |                                    |
| updated_at    | timestamptz NOT NULL DEFAULT now()             |                                    |

- `UNIQUE (agent_id, event_type, handler_key)`.
- `INDEX (agent_id, event_type, priority)` — fast "fire order" lookup.

### `messages`

All agent-to-agent or user-to-agent traffic, either direction.

| Column            | Type                                          | Notes                                |
|-------------------|-----------------------------------------------|--------------------------------------|
| id                | uuid PK                                       |                                      |
| direction         | text NOT NULL CHECK (direction IN ('in','out')) | incoming vs outgoing               |
| agent_id          | uuid FK → `agents.id` NOT NULL                | the local agent                      |
| session_id        | uuid FK → `sessions.id`                      | runtime session, when known          |
| peer_agent_id     | uuid FK → `agents.id`                         | counterparty, when known             |
| role              | text NOT NULL                                 | `user`, `assistant`, `tool`, `system` |
| content           | text NOT NULL                                 |                                      |
| content_type      | text NOT NULL DEFAULT 'text'                  | `text`, `json`, `markdown`           |
| thread_id         | uuid                                          | optional grouping across messages    |
| parent_message_id | uuid FK → `messages.id`                       | threading                            |
| external_ref      | jsonb NOT NULL DEFAULT '{}'                   | framework-native ids                 |
| created_at        | timestamptz NOT NULL DEFAULT now()             |                                      |

Indexes:
- `(agent_id, created_at DESC)` — agent thread reads.
- `(thread_id, created_at)` — group reads.
- `(direction, created_at)` — analytics.
- GIN on `external_ref` — native-id lookup.

### `tool_executions`

Every tool call as a durable record.

| Column               | Type                                          | Notes                         |
|----------------------|-----------------------------------------------|-------------------------------|
| id                   | uuid PK                                       |                               |
| agent_id             | uuid FK → `agents.id` NOT NULL                |                               |
| session_id           | uuid FK → `sessions.id`                      | runtime session               |
| message_id           | uuid FK → `messages.id`                       | triggering message            |
| tool_name            | text NOT NULL                                 |                               |
| arguments            | jsonb NOT NULL DEFAULT '{}'                   |                               |
| result               | jsonb                                         | populated on completion       |
| status               | text NOT NULL                                 | `pending`, `success`, `error`, `blocked` |
| started_at           | timestamptz NOT NULL DEFAULT now()             |                               |
| finished_at          | timestamptz                                   |                               |
| duration_ms          | integer                                       | generated on completion       |
| error                | text                                          |                               |
| parent_execution_id  | uuid FK → `tool_executions.id`                | sub-calls                     |
| external_ref         | jsonb NOT NULL DEFAULT '{}'                   | native trace ids              |

Indexes:
- `(agent_id, started_at DESC)`.
- `(tool_name, started_at DESC)`.
- `(message_id)`.
- Partial `(status) WHERE status = 'error'` — fast failure queries.

## Abstraction layer

Two layers, loosely coupled via the schema:

1. **Framework adapters.** One per `agent_frameworks.kind`. Each adapter
   owns its kind string and translates native payloads into schema rows,
   resolving framework-local agent IDs to UUIDs through the
   `(framework_id, framework_local_id)` business key. The adapter is the
   only place that knows about framework-specific fields; everything
   downstream sees the unified shape.
2. **Unified read API.** Reads query the common tables. Returning a
   framework-rich view is a matter of joining `external_ref` / `metadata`
   and feeding the rows back through the matching adapter.

This keeps the schema framework-neutral while letting each framework
retain its native semantics in JSONB blobs.

## Relations at a glance

```
projects ──────────┐
                   │ 1
                   │
                   ▼ n
agent_frameworks ──┐
                   │ 1
                   │
                   ▼ n
                agents ──┬── 1:n ── agent_skills
                         ├── 1:n ── agent_plugins
                         ├── 1:n ── available_tools
                         ├── 1:n ── hooks
                         ├── 1:n ── sessions
                         ├── 1:n ── messages  ◄── self-FK (parent_message_id)
                         │     │
                         │     ├── session_id ──► sessions
                         │     └── optional thread_id
                         └── 1:n ── tool_executions
                                          │
                                          ├── session_id ──► sessions
                                          ├── message_id ──► messages
                                          └── parent_execution_id ──► self
```

## MVP primitives

The bootstrap repository at `/a0/usr/projects/persistence-bootstrap/`
(v0.2.0) is the home for this MVP. Each primitive is a `bootstrap`
subcommand backed by `lib/<name>.sh`, with its own config namespace.
No shared globals — services are decoupled by interface.

| Primitive | CLI command | Status | Notes |
|---|---|---|---|
| Postgres | `bootstrap postgres` | existing | `lib/postgres.sh` (78 LOC). Fresh PG18 cluster; seeds password, role, db. |
| Schema | `bootstrap schema` | existing | `lib/schema.sh` (57 LOC). Applies 0001_init + 0002_seed (post-migration). |
| Plugin | `bootstrap plugin` | existing | `lib/plugin.sh` (45 LOC). Installs `data_management` Agent Zero plugin. |
| MCP | `bootstrap mcp` | existing | `lib/mcp.sh` (142 LOC). pip install + symlink + systemd unit. |
| Agent Zero | `bootstrap agent-zero` | existing | `lib/agent_zero.sh` (104 LOC). Installs A0 deps + secrets.env. |
| **Redis** | `bootstrap redis` | new | `lib/redis.sh` (TBD). Read-through cache per `docs/redis-integration-plan.md`: optional dependency, bounded payloads, short timeouts, tenant isolation. Env: `PERSISTENCE_REDIS_URL`, `PERSISTENCE_REDIS_PREFIX`, `PERSISTENCE_REDIS_ENABLED`. |
| **FalkorDB** | `bootstrap falkordb` | new | `lib/falkordb.sh` (TBD). Service install + auth + reachability. Env: `PERSISTENCE_FALKORDB_URL`, `PERSISTENCE_FALKORDB_DATABASE`. |
| **Governance injection** | `bootstrap governance` | new | `lib/governance.sh` (TBD). Copies `runtime_governance` plugin from `/a0/usr/plugins/runtime_governance/`, runs `bootstrap plugin` to install it, verifies hooks (`system_prompt` + `tool_execute_before`) load, runs the plugin test suite. Env: `PERSISTENCE_GOVERNANCE_POLICY` (optional override path). |
| Bundle | `bootstrap services` | new | redis + falkordb. |
| Bundle | `bootstrap full` | new | services + schema + plugin + mcp + governance + agent-zero. |
| Verify | `bootstrap verify` | existing | smoke test extended to cover each new primitive. |

**Decoupling rule:** every primitive reads its own env namespace
(`PERSISTENCE_<SERVICE>_*`) and owns its own client wrapper. The MCP
server reads them through one `config.py` entry-point but each
service's client is independently importable and mockable. No
process-wide globals.

**Migration impact on existing files (under the container-name identity contract):**

- `migrations/0001_init.sql` — add `agents.deployment text NOT NULL
  DEFAULT ''`; drop `CONSTRAINT uq_agent_business_key UNIQUE
  (framework_id, framework_local_id)`; recreate as `UNIQUE
  (framework_id, framework_local_id, deployment)`.
- `migrations/0002_seed.sql` — replace `framework_local_id =
  'agent-zero-sbzm'` with `framework_local_id = $(hostname)` (the
  container's own `hostname` output, e.g. `52ba0cdf32af` locally);
  add `deployment = 'local'`.
- `migrations/0003_alter_agents.sql` (new) — idempotent
  `ALTER TABLE agents ADD COLUMN IF NOT EXISTS deployment text NOT
  NULL DEFAULT ''` plus the unique-constraint swap, for installs
  that already ran 0001+0002.
- `migrations/0004_seed_hermes.sql` (new) — Hermes agent row with
  `framework_local_id = $(hostname)` (set at deploy time on the
  Hermes host) and `deployment = 'hermes'`.
- `plugin/data_management/adapters/chat_json.py` — replace
  `DEFAULT_AGENT_LOCAL_ID = 'agent-zero-sbzm'` with a runtime
  derivation:
  ```python
  import os
  DEFAULT_AGENT_LOCAL_ID = os.environ.get('AGENT_LOCAL_ID') or os.uname().nodename
  DEFAULT_DEPLOYMENT      = os.environ.get('AGENT_DEPLOYMENT', 'local')
  ```
- `bootstrap` CLI — `cmd_schema` and `cmd_mcp` reference
  `MCP_AGENT_NAME='agent-zero-sbzm'`; replace with
  `MCP_AGENT_NAME="$(hostname)"` (default `52ba0cdf32af` on this
  host) and add a new `MCP_DEPLOYMENT='local'` env. `install.sh` and
  the `bootstrap` script export both from `$(hostname)` so each
  container picks up its own name at install time.

## Open decisions

These are the only items still blocking a concrete implementation:

1. **Cross-deployment queries.** When a consumer wants "all agents on
   both deployments", do we (a) replicate Hermes into the local DB,
   (b) ship a federation layer that queries both Postgres instances,
   or (c) require consumers to query each host and join client-side?
   Default: (c) — keep each deployment's DB authoritative.
2. **Redis bypass behaviour.** If `PERSISTENCE_REDIS_ENABLED=false` or
   Redis is unreachable, MCP server falls through to Postgres. Confirm
   the policy is "warn once, never block" and not "fail-closed".
3. **Governance policy source.** Does `bootstrap governance` ship a
   default 36-rule policy (matching the existing
   `runtime_governance` plugin), or pull a policy file from a path?
4. **Migration tool.** Plain SQL files (`psql -f`, current approach)
   or move to `sqitch`/`sqlx`/`alembic` once the new tables settle?
5. **Adapter home.** Per-framework plugins (current direction) or
   shared `agent_persistence` library? Affects imports more than
   schema.
6. **Hermes container name.** The local container is `52ba0cdf32af`
   (verified via `hostname` on `/a0`). The Hermes VPS's container
   name must be supplied at deploy time on that host — either as
   env vars (`MCP_AGENT_NAME=<hermes_hostname>`,
   `AGENT_LOCAL_ID=<hermes_hostname>`,
   `AGENT_DEPLOYMENT=hermes`) or auto-derived via `$(hostname)` in
   the `bootstrap` install flow. Confirm the preferred mode.