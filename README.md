# data-layer-postgres

Framework-agnostic PostgreSQL schema service for the data-layer stack.

This project owns the postgres 18 cluster installer, the four append-only
SQL migrations, the idempotent applier, the schema-abstraction docs, and
the cross-framework identity contract. It is wired into the
`data-layer` umbrella as a sibling submodule (its own git repository
at `github.com/NovaAI-innovation/data-layer-postgres`).

## Layout

```
data-layer-postgres/
├── .a0proj/                           Agent Zero project metadata
├── docs/
│   ├── schema-abstraction.md          cross-framework abstraction contract
│   └── decisions/                     append-only ADRs
├── lib/
│   ├── postgres.sh                    PG18 cluster installer
│   └── install.sh                      migration applier (install | verify | status | reset)
├── migrations/
│   ├── 0001_init.sql                   10-table initial schema
│   ├── │   ├── 0003_alter_agents.sql           add agents.deployment column + rebuild unique key
│   └── ├── tests/smoke.sh                     verify the schema is reachable
├── README.md
├── AGENTS.md
├── .env.example
└── .gitignore
```

## Commands

```bash
# Install postgres 18 + start cluster
sudo bash lib/postgres.sh

# Apply all migrations (idempotent — re-runs are no-ops)
bash lib/install.sh install

# Verify all 10 business tables exist
bash lib/install.sh verify

# Show applied migration history
bash lib/install.sh status

# Run smoke tests
bash tests/smoke.sh
```

## Environment

- `DATA_LAYER_POSTGRES_DSN` — postgres URI (default `postgresql://postgres@localhost:5432/postgres`)
- `POSTGRES_PASSWORD` — postgres user password (required; cluster installer fails fast if blank)
- `PERSISTENCE_DATA_DIR` — cluster data dir (default `/var/lib/postgresql`)
- `PERSISTENCE_CONFIG_DIR` — cluster config dir (default `/etc/persistence`)

## Status

Schema is fully migrated. Three migrations land a 10-table framework-agnostic
schema: `projects`, `agent_frameworks`, `agents`, `agent_skills`,
`agent_plugins`, `available_tools`, `hooks`, `sessions`, `messages`,
`tool_executions` — with the cross-framework identity contract on
`agents.framework_local_id` + `agents.deployment`, an
`agents.framework_id` FK to `agent_frameworks`, and (via migration 0003)
a pgvector-backed `messages.embedding vector(1536)` column with an HNSW
index for vector similarity search.

This submodule is scoped strictly to the postgres persistence database.
Framework-specific code (plugin glue, prompts, MCP wiring) and DB seed
rows live in `data-layer-adapters/<framework>/`. The FAISS memory cache
sits at the agent runtime level (`.a0proj/memory/`, gitignored).
## pgvector

Migration `migrations/0003_pgvector.sql` enables the `vector` extension and adds an `embedding vector(1536)` column on `messages` with an HNSW index (`idx_messages_embedding_hnsw`, vector_cosine_ops). FAISS at `.a0proj/memory/` is the primary in-process cache; pgvector is the durable recall path.
