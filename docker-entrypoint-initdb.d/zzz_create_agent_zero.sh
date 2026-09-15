#!/usr/bin/env bash
# data-layer-postgres/docker-entrypoint-initdb.d/zzz_create_agent_zero.sh
#
# Final init script; runs AFTER all 0001-0006 migrations because the
# filename starts with "zzz" (lex order). Creates the per-tenant
# agent_zero role + database and applies tight (table-scoped) grants
# on the postgres database.
#
# Wired in from the Dockerfile via:
#   COPY docker-entrypoint-initdb.d/zzz_create_agent_zero.sh /docker-entrypoint-initdb.d/
#
# The password below is test-data only. Rotate per-environment.

set -euo pipefail

AGENT_ZERO_PASSWORD="${DATA_LAYER_AGENT_ZERO_PASSWORD:-agent_zero_dev_password}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL

-- Per-tenant login role.
CREATE ROLE agent_zero WITH LOGIN PASSWORD '$AGENT_ZERO_PASSWORD';

-- Per-tenant database (separate from the business-data database).
CREATE DATABASE agent_zero OWNER agent_zero;

-- In the business database, drop the overly-broad default grants
-- that the base image may have set, then re-grant narrowly.
\c $POSTGRES_DB

REVOKE ALL ON SCHEMA public FROM agent_zero;

GRANT USAGE ON SCHEMA public TO agent_zero;

-- Business tables: table-scoped CRUD only.
GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE projects, agent_frameworks, agents, agent_skills,
              agent_plugins, available_tools, hooks, sessions,
              messages, tool_executions, session_heartbeats,
              idempotency_keys
    TO agent_zero;

-- Sequences (uuid_generate_v4 defaults).
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO agent_zero;

-- Functions: explicit allow-list. The agent runtime uses these.
GRANT EXECUTE ON FUNCTION record_session_heartbeat(uuid, text, jsonb) TO agent_zero;
GRANT EXECUTE ON FUNCTION claim_idempotency_key(text, text, integer) TO agent_zero;
GRANT EXECUTE ON FUNCTION finish_idempotency_key(text, text, text, jsonb) TO agent_zero;
GRANT EXECUTE ON FUNCTION match_messages(vector, float, int, int) TO agent_zero;

EOSQL

echo "[init] agent_zero role + database + grants created"
