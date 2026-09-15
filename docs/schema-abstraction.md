# Cross-framework abstraction strategy

The data-layer postgres schema is the cross-framework abstraction layer for the
agent stack. This document records the contract that makes it framework-
agnostic.

## Identity contract

- **`agent_frameworks.kind`** — snake_case short name of the framework
  family. One row per family. Adapter adapters dispatch on this column.
- **`agents.framework_local_id`** — the running container's name, taken
  from the runtime (`hostname`, Docker `--name`, or whatever the
  framework runtime supplies). Operators supply this at apply time.
- **`agents.deployment`** — logical host/workload tag (e.g. `local`,
  `hermes`). Independent of container name; useful for grouping agents
  by deployment without exposing infrastructure detail.
- **Business key** — `UNIQUE (framework_id, framework_local_id,
  deployment)`. Two containers of the same framework running side by side
  are uniquely identified by this triple.

## Design principles

1. **One row per identity.** Every agent has exactly one row, addressed by
   a UUID PK and a `(framework_id, framework_local_id, deployment)` business key.
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
7. **Sessions scope activity.** Every message belongs to a session row
   (FK, NOT NULL); tool executions have a nullable session_id for
   bootstrap-time calls. A session is a runtime window for one agent —
   it groups messages, tool calls, and lifecycle facts together.
8. **Projects group agents.** A project is a workspace or tenant that
   owns a set of agents. `project_id` lives on `agents` only; sessions,
   messages, and tool executions inherit project scope through the agent
   join, keeping the schema lean.
9. **Tools are caps, hooks are events.** `available_tools` records the
   per-agent tool grants (parallel to skills and plugins). `hooks`
   records lifecycle handlers per agent, keyed by event type and
   priority so the runtime can fire them in order.

## Tables (10 business tables)

1. `projects` — workspace or tenant. Owns a set of agents.
2. `agent_frameworks` — registry of frameworks; `kind` is the dispatch key.
3. `agents` — individual agents; identity = (framework_id, framework_local_id, deployment).
4. `agent_skills` — skills loaded for an agent. Source ∈ {core, plugin, user}.
5. `agent_plugins` — plugins registered for an agent.
6. `available_tools` — per-agent tool grants.
7. `hooks` — lifecycle event handlers per agent; fired in priority order.
8. `sessions` — runtime windows for an agent. UNIQUE (agent_id, session_key).
9. `messages` — all agent traffic, either direction. Direction ∈ {in, out}.
10. `tool_executions` — every tool call as a durable record.
11. `pgvector` — when migration 0003 has been applied, the `vector`
    extension is enabled, `messages.embedding vector(1536)` is
    available, and an HNSW index `idx_messages_embedding_hnsw`
    (vector_cosine_ops) supports approximate nearest-neighbour
    recall at the database level. The FAISS cache at
    `.a0proj/memory/` remains the primary in-process recall path;
    pgvector is the durable second-tier recall.

Plus a `schema_migrations` tracker table maintained by the applier.

## Adapter home

Framework-specific code and seed rows live in sibling projects under
`data-layer-adapters/`:

- `data-layer-adapters/<framework>/` — one subdirectory per framework family.
  Each contains its own plugin code (if any), prompts, and `seeds/`
  directory for that framework's default DB rows.
- `data-layer-adapters/mcp/` — the universal MCP server. Speaks the
  MCP protocol; not framework-specific.

The postgres submodule holds the schema only. It does NOT register any
framework, seed any framework's defaults, or include framework names in
DDL, seeds, or comments. Framework coupling starts at
`data-layer-adapters/<framework>/`.
