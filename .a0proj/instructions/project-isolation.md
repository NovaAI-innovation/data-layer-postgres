# data-layer-postgres — project isolation directive

This file is injected into the Agent Zero system prompt when this project
is active. It captures the workspace contract for the postgres submodule.

## Workspace

ACTIVE WORKSPACE: `/a0/usr/projects/data-layer/data-layer-postgres`

The workspace owns the postgres schema service: 4 SQL migrations, the
PG18 cluster installer, the idempotent applier, schema-abstraction docs,
and per-project Agent Zero metadata.

## Boundary

This project does NOT own:

- Redis cache layer → `../data-layer-redis`
- FalkorDB graph layer → `../data-layer-falkordb`
- Framework adapters → `../data-layer-adapters`
- Umbrella orchestration → `..`

## Required workflow

1. Read `README.md`, `docs/schema-abstraction.md`, and `AGENTS.md` before changing anything.
2. State the intended outcome and affected paths before implementation.
3. Migrations are append-only: add a new numbered file rather than editing applied ones.
4. Use `/opt/venv-a0/bin/python` for Agent Zero framework checks; `/opt/venv/bin/python` for task checks.
5. Never write real secrets to source-controlled files.

## Cross-project communication

Cross-component wiring goes through the umbrella's `bootstrap postgres`
(which delegates to `lib/install.sh`) and through shared env variables in
`.env.example` / `.a0proj/variables.env`. Do not hard-code paths to other
projects.