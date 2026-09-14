# AGENTS.md — data-layer-postgres

Agent contract for the postgres submodule of the data-layer stack.

## Scope and ownership

This project is the postgres service. It owns the PG18 cluster installer,
the schema migrations, the applier, and the schema-abstraction contract.
It does NOT own Redis, FalkorDB, the framework adapters, or the umbrella
orchestration. Those live in sibling projects.

## Isolation and security

Keep plans, scripts, migrations, tests, docs, and evidence inside this
workspace. Do not write real secrets to source-controlled files; use
`.env.example` for placeholders. Do not modify files in `/a0`, the parent
`../data-layer/`, other sibling submodules, global plugins, system
services, or live databases unless the user explicitly requests the
integration and the side effect is reported.

## Required workflow

Before consequential changes, read `README.md`,
`docs/schema-abstraction.md`, `AGENTS.md`,
`.a0proj/instructions/project-isolation.md`, and the affected migration.
State the intended outcome and affected paths before implementation.
Applied migrations are append-only: add a new numbered migration rather
than rewriting an applied one. Keep deployment state separate from source.

## Runtime boundary

Use `/opt/venv-a0/bin/python` for Agent Zero framework and plugin-hook
checks. Use `/opt/venv/bin/python` for task or user-code checks. Do not
treat one runtime as proof of the other.

## Canonical references

- `lib/postgres.sh` — PG18 cluster installer
- `lib/install.sh` — migration applier (install | verify | status | reset)
- `migrations/` — schema history (append-only)
- `docs/schema-abstraction.md` — cross-framework abstraction contract
- `docs/decisions/` — append-only ADRs