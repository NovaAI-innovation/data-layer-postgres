# data-layer-postgres — SCHEMAS.md

**Postgres is the source of truth for runtime history** (per
`docs/SUBMODULE_OWNERSHIP.md` boundary rule #1 + ADR
`docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md`).
This document is the column-level schema spec for every table introduced
by migrations `0001_init.sql` … `0007_emails.sql`. Each column is
documented along five dimensions:

1. **Purpose** — what the column represents.
2. **Value** — what the column enables at the agent / operator level.
3. **Retrieval impact** — how the column is used by MCP read tools
   (`projects.list`, `agents.list`, `sessions.list`, `messages.search`,
   `tool_executions.list`, `history.retrieve`, `execute_sql`, etc.).
4. **Mutation / transformation impact** — how writes and derived columns
   (e.g. `messages.embedding` → qdrant) propagate downstream.
5. **Queries enabled** — concrete SQL patterns this column makes
   efficient (i.e. backed by an index).

> **Schema authority rule:** if this doc disagrees with the migration
> `.sql` file, the migration wins. Update this doc in the same commit
> that updates the schema.

---

## Table inventory (13 tables + 4 helper functions)

| # | Table | Migration | Rows | Cardinality expectation |
|---|---|---|---|---|
| 1 | `projects` | 0001 | low | ~tens |
| 2 | `agent_frameworks` | 0001 | low | ~handful |
| 3 | `agents` | 0001 + 0002 | medium | hundreds → millions |
| 4 | `agent_skills` | 0001 | high | per-agent × skills |
| 5 | `agent_plugins` | 0001 | high | per-agent × plugins |
| 6 | `available_tools` | 0001 | high | per-agent × tools |
| 7 | `hooks` | 0001 | medium | per-agent × events |
| 8 | `sessions` | 0001 + 0004 | high | per agent over time |
| 9 | `messages` | 0001 + 0003 | **very high** | all agent traffic |
| 10 | `tool_executions` | 0001 + 0005 | very high | every tool call |
| 11 | `session_heartbeats` | 0004 | very high | every heartbeat event |
| 12 | `idempotency_keys` | 0006 | high | cross-table key claim log |
| 13 | `emails` | 0007 | high | inbound + outbound mail |

---

## 1. `projects` (0001_init.sql)

Workspace or tenant that owns a set of agents. Sessions/messages/tool_executions
inherit project scope through the agents join.

| Column | Type | Purpose | Value | Retrieval impact | Mutation / transformation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | stable internal id | row identity | MCP `projects.get(id)` / `agents.list(project_key=...)` (cross-table join) | never updated | by-id lookup |
| `project_key` | `text` UNIQUE NOT NULL | business key | stable slug for ops + scripts | filter by `project_key` across MCP tools | never updated (rename requires a migration) | unique equality |
| `display_name` | `text` NOT NULL | human label | UI display | surfaced by `projects.list` | editable | LIKE / ILIKE search |
| `description` | `text` | free-form notes | operator context | surfaced in long-form listing | editable | ILIKE |
| `status` | `text` CHECK ('active','archived') | lifecycle | gates writes vs reads | `projects.list(status='active')` | transitions active → archived | equality + index `idx_projects_status` |
| `metadata` | `jsonb` | free-form | tags, links, tenant config | GIN-indexed if needed | merged on update | GIN ops when GIN present |
| `created_at` | `timestamptz` | audit | lineage | range filtering | immutable | range |
| `updated_at` | `timestamptz` | audit | last change | range filtering | auto-maintained by trigger `trg_projects_updated_at` | range |

---

## 2. `agent_frameworks` (0001)

Registry of frameworks that write into this schema. Adapters dispatch on `kind`.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | row identity | FK target for `agents.framework_id` | immutable | by-id |
| `kind` | `text` UNIQUE NOT NULL | framework identifier | dispatch key | adapter routing | immutable (kind change = new row) | unique equality |
| `display_name` | `text` NOT NULL | UI label | readability | surfaced in `agents.list` | editable | ILIKE |
| `version` | `text` | framework version | capability gating | filter "compatible with framework X" | updated by adapter on bootstrap | equality |
| `metadata` | `jsonb` | adapter-specific | capability manifest | filtered in adapters | merged | JSONB ops |
| `created_at` | `timestamptz` | audit | lineage | range | immutable | range |

---

## 3. `agents` (0001 + 0002)

Individual agents from any framework. Business key:
`(framework_id, framework_local_id, deployment)` (deployment added in 0002).

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | row identity | FK in `sessions`, `messages`, `tool_executions`, `emails` | immutable | by-id |
| `project_id` | `uuid` FK `projects(id)` | tenant scope | multi-tenant isolation | every cross-table filter joins here | immutable after first insert | FK index |
| `framework_id` | `uuid` FK `agent_frameworks(id)` | adapter dispatch | dispatch key | `agents.list(framework=...)` | immutable | index `idx_agents_framework_status` |
| `framework_local_id` | `text` NOT NULL | per-framework agent id | adapter-side correlation | adapter sees this id; postgres uses uuid | immutable | equality |
| `deployment` | `text` NOT NULL DEFAULT '' | multi-deployment partition | per-deploy agent identity | prevents cross-deploy collisions | set once per agent | equality |
| `display_name` | `text` | human label | UI display | surfaced in MCP listings | editable | ILIKE |
| `profile_key` | `text` | agent profile reference | capability/profile lookup | adapter reads to load profile | editable | equality |
| `status` | `text` CHECK ('active','disabled','archived') | lifecycle | gates new sessions | `agents.list(status='active')` | lifecycle transitions | equality + index |
| `metadata` | `jsonb` | adapter-specific | free-form | JSONB ops | merged | JSONB ops |
| `created_at`, `updated_at` | `timestamptz` | audit | lineage | range | `updated_at` auto-triggered | range |

**Business key constraint:** `UNIQUE (framework_id, framework_local_id, deployment)`.

---

## 4. `agent_skills` (0001)

Skills loaded for an agent.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | row identity | join key | immutable | by-id |
| `agent_id` | `uuid` FK `agents(id)` ON DELETE CASCADE | ownership | scoping | `agent_skills` filtered by agent | cascade with agent | FK index |
| `skill_key` | `text` NOT NULL | skill identifier | dispatch | adapter loads by key | editable | equality |
| `source` | `text` CHECK ('core','plugin','user') | provenance | trust tier | adapter filters by source | lifecycle | equality |
| `version` | `text` | semantic version | upgrade gate | equality filter | updates bump version | equality |
| `manifest` | `jsonb` | free-form config | per-skill config | JSONB ops | merged | JSONB ops |
| `enabled` | `boolean` | activation toggle | runtime gate | adapter skips disabled | toggle | equality (filtered) |
| `created_at` | `timestamptz` | audit | lineage | range | immutable | range |

**Unique constraint:** `(agent_id, skill_key, source)`.

---

## 5. `agent_plugins` (0001)

Plugins registered for an agent.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | row identity | join key | immutable | by-id |
| `agent_id` | `uuid` FK `agents(id)` ON DELETE CASCADE | ownership | scoping | scoped | cascade | FK index |
| `plugin_key` | `text` NOT NULL | plugin identifier | dispatch | adapter loads | editable | equality |
| `version` | `text` | semver | upgrade gate | equality filter | update bumps | equality |
| `manifest` | `jsonb` | plugin config | per-plugin config | JSONB ops | merged | JSONB ops |
| `enabled` | `boolean` | activation toggle | runtime gate | adapter skips disabled | toggle | equality |
| `installed_at` | `timestamptz` | audit | install lineage | range | immutable | range |

**Unique constraint:** `(agent_id, plugin_key)`.

---

## 6. `available_tools` (0001)

Per-agent tool grants. Parallel to skills and plugins — each row is "agent X has access to tool Y".

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | identity | join key | immutable | by-id |
| `agent_id` | `uuid` FK `agents(id)` ON DELETE CASCADE | ownership | scoping | scoped | cascade | FK index `idx_available_tools_agent` |
| `tool_key` | `text` NOT NULL | tool identifier | grant key | `available_tools(tool_key)` reverse lookup | editable | equality `idx_available_tools_tool` |
| `category` | `text` | grouping | UI taxonomy | filter by category | editable | equality |
| `version` | `text` | semver | upgrade gate | equality | updated on bump | equality |
| `manifest` | `jsonb` | config | per-tool config | JSONB ops | merged | JSONB ops |
| `enabled` | `boolean` | activation toggle | runtime gate | adapter skips disabled | toggle | equality |
| `granted_at` | `timestamptz` | audit | grant lineage | range | immutable | range |
| `revoked_at` | `timestamptz` | revocation | time-bounded grant | filter `revoked_at IS NULL` | set on revocation | equality |
| `metadata` | `jsonb` | free-form | context | JSONB ops | merged | JSONB ops |

**Unique constraint:** `(agent_id, tool_key)`.

---

## 7. `hooks` (0001)

Lifecycle event handlers per agent. Fired in priority order at runtime.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | identity | join key | immutable | by-id |
| `agent_id` | `uuid` FK `agents(id)` ON DELETE CASCADE | ownership | scoping | scoped | cascade | FK index |
| `event_type` | `text` NOT NULL | event name | dispatch | adapter fires by event_type | editable | equality |
| `handler_key` | `text` NOT NULL | handler id | dispatch within event | dedupe + dispatch | editable | equality |
| `priority` | `integer` DEFAULT 100 | fire order | deterministic ordering | adapter sorts by priority | editable | ordering `idx_hooks_fire_order` |
| `config` | `jsonb` | handler config | per-handler config | JSONB ops | merged | JSONB ops |
| `enabled` | `boolean` | activation | runtime gate | adapter skips disabled | toggle | equality |
| `created_at`, `updated_at` | `timestamptz` | audit | lineage | range | `updated_at` triggered | range |

**Unique constraint:** `(agent_id, event_type, handler_key)`. Fire-order index: `(agent_id, event_type, priority)`.

---

## 8. `sessions` (0001 + 0004)

Runtime windows for an agent. A session groups messages and tool calls.
`last_heartbeat_at` added in 0004 to promote heartbeats to durable SOT.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | identity | join target for messages, tool_executions | immutable | by-id |
| `agent_id` | `uuid` FK `agents(id)` ON DELETE CASCADE | ownership | scoping | scoped | cascade | FK index `idx_sessions_agent_started` |
| `session_key` | `text` NOT NULL | per-agent session key | adapter correlation | adapter sees this id | immutable | unique equality |
| `status` | `text` CHECK ('active','closed','crashed') | lifecycle | gates new writes | `sessions.list(status='active')` | lifecycle transitions | equality |
| `started_at` | `timestamptz` | audit | wall-clock start | range filtering | immutable | range |
| `ended_at` | `timestamptz` | audit | wall-clock end (nullable while active) | range filtering | set on close | range |
| `last_heartbeat_at` | `timestamptz` | audit (0004) | liveness proof | presence check / SLA | auto-maintained by `record_session_heartbeat()` | partial index `idx_sessions_last_heartbeat` |
| `metadata` | `jsonb` | free-form | context | JSONB ops | merged | JSONB ops |

**Unique constraint:** `(agent_id, session_key)`.

---

## 9. `messages` (0001 + 0003 — pgvector)

All agent traffic, either direction. Self-FK for threading. In 0003,
`embedding vector(1536)` was added with an HNSW index, plus the
`match_messages()` helper for semantic recall.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | identity | MCP `messages.get(id)` | immutable | by-id |
| `session_id` | `uuid` FK `sessions(id)` ON DELETE CASCADE | session scope | scoping | `messages.list(session_id=...)` | cascade | FK `idx_messages_session_time` |
| `agent_id` | `uuid` FK `agents(id)` | ownership | scoping | `messages.list(agent_id=...)` | immutable | FK `idx_messages_agent_time` |
| `direction` | `text` CHECK ('in','out') | traffic direction | filtering | `messages.list(role|direction=...)` | immutable | equality `idx_messages_direction_time` |
| `peer_agent_id` | `uuid` FK `agents(id)` | counterparty (nullable) | cross-agent thread | join for peer correlation | set on receive | equality |
| `role` | `text` CHECK ('user','assistant','tool','system') | LLM role | retrieval ranking | `messages.search(q=..., role=...)` | immutable | equality |
| `content` | `text` NOT NULL | the message body | retrieval corpus | ILIKE search, embedding source | immutable | ILIKE |
| `content_type` | `text` DEFAULT 'text' | MIME-ish type | adapter routing | filter by type | immutable | equality |
| `thread_id` | `uuid` | conversation id | thread reconstruction | thread queries | immutable | partial index `idx_messages_thread_time` |
| `parent_message_id` | `uuid` FK `messages(id)` ON DELETE SET NULL | self-thread | in-conversation ordering | tree traversal | immutable | recursive CTE |
| `external_ref` | `jsonb` | provider metadata | ILIKE search across json | GIN ops | merged | GIN `idx_messages_external_ref` |
| `created_at` | `timestamptz` | audit | lineage | range | immutable | range |
| `embedding` | `vector(1536)` (0003) | semantic embedding | semantic recall | `match_messages()` HNSW recall | written by embed pipeline | HNSW `idx_messages_embedding_hnsw` (m=24, ef_construction=128) |

**Read path:** `match_messages(query_embedding, threshold, count, ef_search)` — returns `(id, session_id, agent_id, direction, content, similarity)`.

---

## 10. `tool_executions` (0001 + 0005 — lifecycle)

Every tool call as a durable record. Links to triggering message and
parent execution for sub-calls. 0005 added `idempotency_key`,
`attempt_number`, `retry_of_execution_id`, and the
`latest_execution_per_key` view.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | identity | MCP `tool_executions.get(id)` | immutable | by-id |
| `agent_id` | `uuid` FK `agents(id)` | ownership | scoping | `tool_executions.list(agent_id=...)` | immutable | FK `idx_tool_executions_agent_time` |
| `session_id` | `uuid` FK `sessions(id)` ON DELETE SET NULL | session scope (nullable) | scoping | `tool_executions.list(session_id=...)` | set/clear | FK `idx_tool_executions_session_time` |
| `message_id` | `uuid` FK `messages(id)` ON DELETE SET NULL | triggering message | correlate | join to message | set/clear | FK `idx_tool_executions_message` |
| `tool_name` | `text` NOT NULL | tool identifier | grant check + reporting | `tool_executions.list(tool_name=...)` | immutable | FK `idx_tool_executions_tool_time` |
| `arguments` | `jsonb` | tool input | forensic | adapter logs | immutable | JSONB ops |
| `result` | `jsonb` | tool output (nullable until done) | forensic | adapter logs | set on completion | JSONB ops |
| `status` | `text` CHECK ('pending','success','error','blocked') | lifecycle | retry/dedupe decisions | `tool_executions.list(status='error')` | transitions | equality + partial index `idx_tool_executions_errors` |
| `started_at` | `timestamptz` | audit | latency analysis | range | immutable | range |
| `finished_at` | `timestamptz` | audit | latency | range | set on completion | range |
| `duration_ms` | `integer` | audit | latency | range | computed | range + CHECK (>=0) |
| `error` | `text` | error message | debugging | surfaced in error queries | set on error | ILIKE |
| `parent_execution_id` | `uuid` FK `tool_executions(id)` ON DELETE SET NULL | sub-call tree | recursion | tree traversal | set for sub-calls | recursive CTE |
| `external_ref` | `jsonb` | provider metadata | cross-system correlation | GIN ops | merged | GIN |
| `idempotency_key` | `text` (0005) | cross-table key | dedupe | `latest_execution_per_key` view | set on claim | partial index `idx_tool_executions_idempotency_key` |
| `attempt_number` | `integer` (0005) | retry counter | retry chain | dedupe chain | increment per retry | equality |
| `retry_of_execution_id` | `uuid` FK `tool_executions(id)` (0005) | retry pointer | retry chain | chain traversal | set on retry | self-FK |

**View:** `latest_execution_per_key` returns the highest-`attempt_number` row per `idempotency_key` (NULL keys excluded).

---

## 11. `session_heartbeats` (0004)

Per-event audit trail of every heartbeat. Idempotent on
`(session_id, received_at, source)`. ADR 0002 promoted heartbeats to
postgres primary; redis is a hot cache.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | identity | join key | immutable | by-id |
| `session_id` | `uuid` FK `sessions(id)` ON DELETE CASCADE | session | lineage | per-session replay | cascade | FK `idx_session_heartbeats_session_time` |
| `received_at` | `timestamptz` | audit | wall-clock event time | range + replay | immutable | range + FK index (DESC) |
| `source` | `text` CHECK ('adapter','replay','import') | provenance | trust + replay scope | filter by source | immutable | equality |
| `metadata` | `jsonb` | event payload | context | JSONB ops | merged | JSONB ops |

**Unique constraint:** `(session_id, received_at, source)`.
**Helper:** `record_session_heartbeat(session_id, source='adapter', metadata='{}')` — inserts into this table + updates `sessions.last_heartbeat_at` atomically.

---

## 12. `idempotency_keys` (0006)

Cross-table claim log for idempotent operations. 0006 promoted
idempotency from redis-only to postgres-durable; redis remains a hot
cache but is not the source of truth.

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | identity | join key | immutable | by-id |
| `scope` | `text` NOT NULL | namespace ('tool','webhook','message', …) | partitioning | filter by scope | immutable | partial index `idx_idempotency_keys_scope` |
| `key` | `text` NOT NULL | caller-supplied claim | dedupe | equality (within scope) | immutable | partial index `idx_idempotency_keys_key` |
| `agent_id` | `uuid` FK `agents(id)` ON DELETE SET NULL | ownership | scoping | scoped | set/clear | equality |
| `session_id` | `uuid` FK `sessions(id)` ON DELETE SET NULL | session | scoping | scoped | set/clear | equality |
| `project_id` | `uuid` FK `projects(id)` ON DELETE SET NULL | tenant | scoping | scoped | set/clear | equality |
| `status` | `text` CHECK ('fresh','in_progress','completed','failed') | state machine | retry decision | `claim_idempotency_key()` | transitions | equality + partial index on `status='in_progress'` |
| `response_payload` | `jsonb` | cached response | replay | adapter reads on completion | set on completion | JSONB ops |
| `tool_execution_id` | `uuid` FK `tool_executions(id)` ON DELETE SET NULL (added via 0005 view, not hard FK) | correlation | joins | join to execution | set | partial index `idx_idempotency_keys_tool_execution_id` |
| `expires_at` | `timestamptz` | TTL | claim expiry | range | set on claim | partial index on non-NULL |
| `created_at`, `updated_at` | `timestamptz` | audit | lineage | range | `updated_at` triggered | range |

**Primary key:** `(scope, key)` (composite). **Helper:** `claim_idempotency_key(scope, key, ttl_s=86400)` returns `(status, response_payload)` atomically via `SELECT … FOR UPDATE`.

---

## 13. `emails` (0007)

Inbound + outbound email records. Audit-grade (legal/contractual
records) AND high-volume (so heavy text stays in postgres, semantic
index mirrored to `data-layer-qdrant`).

| Column | Type | Purpose | Value | Retrieval impact | Mutation | Queries enabled |
|---|---|---|---|---|---|---|
| `id` | `uuid` PK | internal id | identity + qdrant point join key | join to `mpg_emails` qdrant point | immutable | by-id |
| `agent_id` | `uuid` FK `agents(id)` ON DELETE SET NULL | owning agent (nullable for inbound) | scoping | scoped queries | set/clear | FK index |
| `direction` | `text` CHECK ('in','out') | traffic direction | filtering | filter in/out | immutable | equality |
| `message_id` | `text` UNIQUE NOT NULL | RFC 5322 Message-ID | dedupe | inbox dedupe | immutable | unique equality |
| `in_reply_to` | `text` | parent Message-ID (nullable on roots) | thread reconstruction | thread queries | immutable | equality (self-FK added in DO block) |
| `thread_id` | `uuid` | conversation id | thread linking | falkordb graph join | immutable | equality |
| `subject` | `text` NOT NULL | human label | display + search | ILIKE | immutable | ILIKE |
| `from_email` | `text` NOT NULL | sender | identity | ILIKE | immutable | ILIKE |
| `to_emails` | `jsonb` | recipient list | delivery | JSONB containment | immutable | JSONB |
| `cc_emails` | `jsonb` | cc list | delivery | JSONB | immutable | JSONB |
| `bcc_emails` | `jsonb` | bcc list | delivery | JSONB | immutable | JSONB |
| `body` | `text` NOT NULL | plain-text body | semantic recall source | embedded → qdrant | immutable | ILIKE |
| `body_html` | `text` | HTML body (nullable) | display | rarely embedded | immutable | ILIKE |
| `raw_mime` | `text` | full MIME source (nullable) | forensic | not for retrieval | immutable | n/a |
| `attachments` | `jsonb` | attachment descriptors | delivery + audit | JSONB | immutable | JSONB |
| `external_ref` | `jsonb` | provider metadata (gmail label ids, IMAP uid, …) | cross-system correlation | GIN | merged | GIN |
| `received_at` | `timestamptz` | audit (in) | wall-clock | range | immutable | range |
| `sent_at` | `timestamptz` | audit (out) | wall-clock | range | immutable | range |
| `ingested_at` | `timestamptz` | audit | wall-clock ingest | range | immutable | range |
| `project_id` | `uuid` FK `projects(id)` ON DELETE SET NULL | tenant | scoping | `rag.search filter project_id` | set/clear | FK index |
| `qdrant_point_id` | `uuid` UNIQUE | qdrant join key | explicit qdrant join | join to `mpg_emails` | set on ingest | unique equality |
| `qdrant_ingested_y_n` | `text` CHECK ('Y','N','SUPERSEDED','DO_NOT_INGEST') | ingest gate | pipeline filter | embed pipeline filters by this | transitions | equality |

**Notes:**
- `direction + message_id` together uniquely identify a row from a single provider.
- The self-FK on `in_reply_to` is added in a DO block (cannot reference a not-yet-created table).
- The `qdrant_*` columns are the explicit idempotency + traceability contract between postgres and qdrant.

---

## Helper functions

| Function | Migration | Signature | Purpose |
|---|---|---|---|
| `touch_updated_at()` | 0001 | trigger | generic `updated_at = now()` setter |
| `match_messages(query_embedding, match_threshold=0.7, match_count=10, query_ef_search=100)` | 0003 | returns TABLE | cosine-similarity recall over `messages.embedding` (HNSW), with SET_CONFIG on `hnsw.ef_search` |
| `record_session_heartbeat(p_session_id, p_source='adapter', p_metadata='{}')` | 0004 | returns timestamptz | atomically insert heartbeat + update `sessions.last_heartbeat_at` |
| `claim_idempotency_key(p_scope, p_key, p_ttl_s=86400)` | 0006 | returns TABLE(status, response_payload) | atomic SELECT-FOR-UPDATE claim + cache; transitions fresh → in_progress → completed/failed |
| `touch_idempotency_keys_updated_at()` | 0006 | trigger | `updated_at` setter for `idempotency_keys` |

## Views

| View | Migration | Definition |
|---|---|---|
| `latest_execution_per_key` | 0005 | DISTINCT ON highest-`attempt_number` row per `idempotency_key` (NULL keys excluded) |

---

## Cross-table integrity contracts

1. **Hard FK** between `tool_executions.idempotency_key` and `idempotency_keys.key` is intentionally NOT enforced (multi-scope reuse). Integrity is verified at write time by the application.
2. **Soft join** between `emails.qdrant_point_id` and qdrant `mpg_emails.id` is verified by the embed pipeline (postgres is the SOT).
3. **Soft join** between `messages.embedding` and qdrant is one-way (postgres is the SOT for messages; qdrant does not mirror them).

---

## Migration audit trail

| Migration | Date applied (typical) | Adds | Alters |
|---|---|---|---|
| `0001_init.sql` | initial | 10 tables + `touch_updated_at()` trigger function | — |
| `0002_alter_agents.sql` | post-deploy | — | `agents.deployment`, rebuilds unique constraint |
| `0003_pgvector.sql` | post-deploy | `messages.embedding vector(1536)`, HNSW index, `match_messages()` | `messages` (embedding column), autovacuum tuning |
| `0004_session_presence.sql` | post-deploy | `session_heartbeats`, `record_session_heartbeat()` | `sessions.last_heartbeat_at`, partial index |
| `0005_tool_executions_lifecycle.sql` | post-deploy | `latest_execution_per_key` view | `tool_executions.idempotency_key`, `attempt_number`, `retry_of_execution_id` |
| `0006_idempotency_keys.sql` | post-deploy | `idempotency_keys`, `claim_idempotency_key()`, `touch_idempotency_keys_updated_at()` | — |
| `0007_emails.sql` | post-deploy | `emails` table | self-FK on `emails.in_reply_to` |
