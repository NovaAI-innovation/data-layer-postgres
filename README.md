# data-layer-postgres

Framework-agnostic PostgreSQL schema service for the data-layer stack.

This project owns the pgvector docker container (`az-postgres`), the
six append-only SQL migrations, the idempotent applier, the
schema-abstraction docs, and the cross-framework identity contract.
It is wired into the `data-layer` umbrella as a sibling submodule
(its own git repository at
`github.com/NovaAI-innovation/data-layer-postgres`).

## Deployment (docker)

Postgres runs as a docker container on the data-layer host. The
native apt install path (`lib/postgres.sh`) is deprecated; the
container is the supported deployment.

```bash
# Start az-postgres (pgvector/pgvector:pg16) with persistent volume
docker run -d --name az-postgres --restart=unless-stopped \
    -p 5432:5432 \
    -v az-postgres-data:/var/lib/postgresql/data \
    -e POSTGRES_PASSWORD=postgres_dev_password \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    pgvector/pgvector:pg16

# Wait for ready
until PGPASSWORD=postgres_dev_password psql -h 127.0.0.1 -U postgres \
    -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; do sleep 1; done

# Apply all migrations (idempotent — re-runs are no-ops)
bash lib/install.sh install
```

The container listens on host port 5432 (default postgres port) and
data persists in the named volume `az-postgres-data`. Stopping and
restarting the container preserves all state. Removing the volume
(`docker volume rm az-postgres-data`) drops all data.

## Layout

```
data-layer-postgres/
├── .a0proj/                           Agent Zero project metadata
├── docs/
│   ├── schema-abstraction.md          cross-framework abstraction contract
│   └── decisions/                     append-only ADRs
├── lib/
│   ├── postgres.sh                    legacy native installer (deprecated)
│   └── install.sh                     migration applier (install | verify | status | reset)
├── migrations/
│   ├── 0001_init.sql                  10-table initial schema
│   ├── 0002_alter_agents.sql          add agents.deployment column + rebuild unique key
│   ├── 0003_pgvector.sql              enable pgvector + messages.embedding + HNSW index
│   ├── 0004_session_presence.sql      sessions.last_heartbeat_at + session_heartbeats audit
│   ├── 0005_tool_executions_lifecycle.sql  tool_executions idempotency_key + attempt_number + retry_of_execution_id
│   └── 0006_idempotency_keys.sql      idempotency_keys table + claim/finish helpers
├── tests/smoke.sh                     verify the schema is reachable
├── README.md
├── AGENTS.md
├── .env.example
└── .gitignore
```

## Commands

```bash
# Start the az-postgres container (see Deployment above)
docker run -d --name az-postgres ...

# Apply all migrations (idempotent — re-runs are no-ops)
bash lib/install.sh install

# Verify all business tables + new objects exist
bash lib/install.sh verify

# Show applied migration history
bash lib/install.sh status

# Run smoke tests
bash tests/smoke.sh
```

## Environment

- `DATA_LAYER_POSTGRES_DSN` — postgres URI
  (default `postgresql://postgres@localhost:5432/postgres`)
- `POSTGRES_PASSWORD` — postgres superuser password (set on the
  az-postgres container via `POSTGRES_PASSWORD` env; required by
  `lib/install.sh` if not using trust auth)
- `DATA_LAYER_AGENT_ZERO_PASSWORD` — agent_zero role password (set
  on the container via init SQL; default `agent_zero_dev_password`
  for test data only)

### Container env vars

| Env | Default | Purpose |
|---|---|---|
| `POSTGRES_PASSWORD` | (required) | postgres superuser password |
| `POSTGRES_HOST_AUTH_METHOD` | `trust` | `trust` allows TCP connections without password verification; switch to `scram-sha-256` for production |
| `POSTGRES_DB` | `postgres` | Initial database created on first start |

### Named volumes

| Volume | Mount | Purpose |
|---|---|---|
| `az-postgres-data` | `/var/lib/postgresql/data` | Persistent cluster data |

## Status

Schema is fully migrated. Six migrations land the framework-agnostic
schema:

- **0001_init** — `projects`, `agent_frameworks`, `agents`,
  `agent_skills`, `agent_plugins`, `available_tools`, `hooks`,
  `sessions`, `messages`, `tool_executions`
- **0002_alter_agents** — `agents.deployment` + rebuild unique key
- **0003_pgvector** — `messages.embedding vector(1536)` + HNSW index + `match_messages()` helper
- **0004_session_presence** — `sessions.last_heartbeat_at`,
  `session_heartbeats` audit table, `record_session_heartbeat()`
  function (per ADR `docs/decisions/0002-...`)
- **0005_tool_executions_lifecycle** — `tool_executions.idempotency_key`,
  `attempt_number`, `retry_of_execution_id` columns +
  `tool_executions_latest_attempt` view (no FK to idempotency_keys;
  composite PK makes single-column FK invalid — see migration file)
- **0006_idempotency_keys** — `idempotency_keys` table +
  `claim_idempotency_key()` / `finish_idempotency_key()` /
  `touch_idempotency_keys_updated_at()` helpers

Identity contract: `(framework_id, framework_local_id, deployment)`
uniquely identifies an agent row across all adapters. The
`agent_zero` role is the per-tenant login role; the `postgres`
superuser is used by `lib/install.sh` and for DDL.

## pgvector

Migration `migrations/0003_pgvector.sql` enables the `vector`
extension and adds an `embedding vector(1536)` column on `messages`
with an HNSW index (`idx_messages_embedding_hnsw`,
`vector_cosine_ops`), tuned for higher recall at modest build cost
(`m = 24`, `ef_construction = 128`). Autovacuum is tightened
(`autovacuum_vacuum_scale_factor = 0.05`) so HNSW maintenance
triggers earlier. A `match_messages(query_embedding,
match_threshold, match_count)` SQL helper function provides
expressive recall with a configurable `hnsw.ef_search` per query
(default 100) for higher query-time recall.

FAISS at `.a0proj/memory/` is the primary in-process cache;
pgvector is the durable recall path.

## Boundary

This project does NOT own:

- Redis cache layer → `../data-layer-redis`
- FalkorDB graph layer → `../data-layer-falkordb`
- Framework adapters → `../data-layer-adapters`
- Umbrella orchestration → `..`

## Migration policy

Append-only. Each new migration adds a new numbered file
(`0007_*.sql`, etc.); existing files are never rewritten once
applied. The applier tracks applied versions in
`schema_migrations`. Re-running `lib/install.sh install` is a
no-op once all migrations are applied.
