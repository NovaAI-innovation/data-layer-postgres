#!/usr/bin/env bash
# data-layer-postgres/lib/install.sh
# Idiomatic applier following the data-layer umbrella contract.
# Subcommands: install | verify | status | reset
#
# Migrated from persistence-postgres/lib/schema.sh.
# Tracks applied versions in a schema_migrations table so re-runs are no-ops.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MIG_DIR="$ROOT/migrations"

# DSN resolution: prefer explicit env, fall back to defaults the cluster installer creates.
DSN="${DATA_LAYER_POSTGRES_DSN:-${PSQL_DSN:-postgresql://postgres@localhost:5432/postgres}}"

log()  { printf '[postgres %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[postgres FAIL] %s\n' "$*" >&2; exit 3; }

run_sql() {
  psql "$DSN" -v ON_ERROR_STOP=1 -X -tAc "$1"
}

ensure_tracker() {
  run_sql "CREATE TABLE IF NOT EXISTS schema_migrations (
              version   text PRIMARY KEY,
              applied_at timestamptz NOT NULL DEFAULT now(),
              checksum  text
          )" >/dev/null
}

apply_migration() {
  local file="$1" version="$2"
  [[ -f "$file" ]] || fail "missing $file"
  local applied
  applied=$(run_sql "SELECT version FROM schema_migrations WHERE version='$version'")
  if [[ -n "$applied" ]]; then
    log "$version already applied, skipping"
    return 0
  fi
  log "applying $version"
  # Use psql -f so the file is executed as a script (multi-statement OK).
  psql "$DSN" -v ON_ERROR_STOP=1 -X -q -f "$file" >/dev/null
  run_sql "INSERT INTO schema_migrations(version) VALUES('$version')" >/dev/null
  log "$version applied"
}

verify_tables() {
  local found
  found=$(run_sql "SELECT count(*) FROM information_schema.tables
                    WHERE table_schema='public'
                      AND table_name IN ('projects','agent_frameworks','agents','sessions','messages','tool_executions','agent_skills','agent_plugins','available_tools','hooks')")
  [[ "$found" -ge 10 ]] || fail "expected 10 business tables; found $found"
  log "all 10 business tables present"
}



verify_extensions() {
  local exts
  exts=$(run_sql "SELECT extname FROM pg_extension WHERE extname IN ('uuid-ossp','vector')")
  echo "$exts" | grep -qx uuid-ossp || fail "extension uuid-ossp missing"
  echo "$exts" | grep -qx vector    || fail "extension vector (pgvector) missing"
  log "extensions uuid-ossp + vector present"
}



verify_helpers() {
  local fn
  fn=$(run_sql "SELECT 1 FROM pg_proc WHERE proname='match_messages'")
  [[ -n "$fn" ]] || fail "helper function match_messages missing"
  log "helper function match_messages present"
}

verify_embedding_index() {
  local idx
  idx=$(run_sql "SELECT 1 FROM pg_indexes WHERE indexname='idx_messages_embedding_hnsw'")
  [[ -n "$idx" ]] || fail "HNSW index idx_messages_embedding_hnsw missing"
  log "HNSW index on messages.embedding present"
}

# Idempotent application of the agent_zero tenant role + database +
# per-table CRUD grants. Replaces the older one-shot initdb path
# (zzz_create_agent_zero.sh — which only runs against a fresh
# /var/lib/postgresql/data volume). This makes `bootstrap postgres
# install` self-heal a half-broken live DB instead of needing
# ad-hoc psql incantations.
#
# Contract:
#   * CREATE ROLE agent_zero is idempotent via a DO-guarded block.
#   * CREATE DATABASE agent_zero is attempted as a separate
#     psql call (CREATE DATABASE cannot live inside a transaction
#     so it cannot sit in the same -1 transaction as the role).
#   * GRANT statements are emitted unconditionally; postgres
#     treats redundant GRANTs as no-ops.
#   * Reads DATA_LAYER_AGENT_ZERO_PASSWORD from env. Fails loudly
#     if unset (no dev default — the initdb script's fallback is
#     gone; see .env.example).
apply_agent_zero_grants() {
  [[ -n "${DATA_LAYER_AGENT_ZERO_PASSWORD:-}" ]] || fail "DATA_LAYER_AGENT_ZERO_PASSWORD must be set (no default; see .env.example)"

  log "apply_agent_zero_grants: role + db + grants via psycopg"
  # Delegate to a python helper that uses psycopg's parameter
  # binding for the password (safe for any special character) and
  # emits GRANT statements as plain SQL (postgres no-ops redundant
  # ones). CREATE DATABASE is issued on an autocommit connection
  # because it cannot run inside a transaction. Re-runs are safe:
  # every step is either an IF-NOT-EXISTS check or a no-op GRANT.
  DATA_LAYER_POSTGRES_DSN="$DSN" \
  DATA_LAYER_AGENT_ZERO_PASSWORD="${DATA_LAYER_AGENT_ZERO_PASSWORD}" \
  PYTHON_BIN=""; for cand in ${PYTHON_BIN_OVERRIDE:-} /opt/venv/bin/python /opt/venv-a0/bin/python python3 python; do
    [[ -x "$cand" ]] || continue
    if "$cand" -c 'import psycopg' 2>/dev/null; then PYTHON_BIN="$cand"; break; fi
  done
  # Self-contained fallback: install psycopg into a user-site prefix
  # the chosen python can see. This makes the script work on bare
  # hosts without requiring a system-wide pip install.
  if [[ -z "$PYTHON_BIN" ]]; then
    PYTHON_BIN="${PYTHON_BIN_OVERRIDE:-python3}"
    log "apply_agent_zero_grants: psycopg not found; bootstrapping via pip"
    if "$PYTHON_BIN" -m pip install --quiet --break-system-packages \
            "psycopg[binary]>=3.1" >/dev/null 2>&1 \
       || "$PYTHON_BIN" -m pip install --quiet --user \
            "psycopg[binary]>=3.1" >/dev/null 2>&1; then
      if ! "$PYTHON_BIN" -c 'import psycopg' 2>/dev/null; then
        fail "pip install of psycopg succeeded but the module is not importable by $PYTHON_BIN"
      fi
    else
      fail "no python with psycopg found and pip install failed; install with: pip install 'psycopg[binary]>=3.1'"
    fi
  fi
  exec "$PYTHON_BIN" - <<'PY'
import os
import psycopg
from psycopg import errors

DSN = os.environ["DATA_LAYER_POSTGRES_DSN"]
PW  = os.environ["DATA_LAYER_AGENT_ZERO_PASSWORD"]
ROLE = "agent_zero"

def say(m): print(f"apply_agent_zero_grants.py: {m}")

# 1. Idempotent CREATE ROLE.
with psycopg.connect(DSN, autocommit=True) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (ROLE,))
        if cur.fetchone() is None:
            say(f"creating role {ROLE}")
            # Role/db names are hardcoded literals (no user input),
            # so inline them directly. The password is parameter-
            # bound via %s so it round-trips safely.
            cur.execute("CREATE ROLE agent_zero WITH LOGIN PASSWORD %s", (PW,))
        else:
            say(f"role {ROLE} present")

# 2. Idempotent CREATE DATABASE (autocommit, cannot be in txn).
with psycopg.connect(DSN, autocommit=True) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (ROLE,))
        if cur.fetchone() is None:
            say(f"creating database {ROLE}")
            cur.execute("CREATE DATABASE agent_zero OWNER agent_zero")
        else:
            say(f"database {ROLE} present")

# 3. Schema grants (redundant GRANTs are no-ops, so re-runs are safe).
TABLES = [
    "projects", "agent_frameworks", "agents", "agent_skills",
    "agent_plugins", "available_tools", "hooks", "sessions",
    "messages", "tool_executions", "session_heartbeats",
    "idempotency_keys",
]
FUNCTIONS = [
    ("record_session_heartbeat", "uuid, text, jsonb"),
    ("claim_idempotency_key",    "text, text, integer"),
    ("finish_idempotency_key",   "text, text, text, jsonb"),
    ("match_messages",           "vector, float, int, int"),
]

with psycopg.connect(DSN, autocommit=True) as conn:
    with conn.cursor() as cur:
        cur.execute("GRANT USAGE ON SCHEMA public TO agent_zero")
        cur.execute(
            "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE " +
            ", ".join(TABLES) +
            " TO agent_zero"
        )
        cur.execute(
            "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO agent_zero"
        )
        # Function grants are best-effort: skip any function that
        # does not exist (older schema before migration 0004/0006).
        # to_regprocedure('fn(args)') returns the OID if present,
        # NULL otherwise — that's how we avoid running a GRANT on
        # a missing function.
        for fn, sig in FUNCTIONS:
            cur.execute(
                "SELECT to_regprocedure(%s) IS NOT NULL",
                (f"{fn}({sig})",),
            )
            if not cur.fetchone()[0]:
                say(f"function {fn}({sig}) missing; skipping its GRANT")
                continue
            # fn and sig are hardcoded strings from FUNCTIONS; safe
            # to inline as plain SQL (no psycopg.sql dependency).
            cur.execute(f"GRANT EXECUTE ON FUNCTION {fn}({sig}) TO agent_zero")

say("done")
PY

  log "apply_agent_zero_grants: complete"
}

verify_agent_zero_role() {
  local r
  r=$(run_sql "SELECT 1 FROM pg_roles WHERE rolname='agent_zero'")
  [[ -n "$r" ]] || fail "role agent_zero missing; install must have failed"
  local d
  d=$(run_sql "SELECT 1 FROM pg_database WHERE datname='agent_zero'")
  [[ -n "$d" ]] || fail "database agent_zero missing"
  local g
  g=$(run_sql "SELECT 1 FROM information_schema.role_table_grants
                WHERE grantee='agent_zero' AND table_name='agents'
                  AND privilege_type='SELECT'")
  [[ -n "$g" ]] || fail "agent_zero missing SELECT grant on agents"
  log "agent_zero role, database, and grants present"
}

usage() {
  cat <<USAGE
Usage: $0 <install|verify|status|reset>

Environment:
  DATA_LAYER_POSTGRES_DSN             postgres URI (default: postgresql://postgres@localhost:5432/postgres)
  DATA_LAYER_AGENT_ZERO_PASSWORD      tenant password (required for install when migrations are missing role/db/grants)
USAGE
}

case "${1:-help}" in
  install)
    ensure_tracker
    # Apply in version order. Names are stable; lexicographic == numeric.
    for f in "$MIG_DIR"/000*.sql; do
      [[ -f "$f" ]] || continue
      version="$(basename "$f" .sql)"
      apply_migration "$f" "$version"
    done
    verify_tables
    # After migrations are present, ensure the tenant role/db/grants
    # are present (idempotent recovery for live DBs that were not
    # initialized via the docker initdb path).
    apply_agent_zero_grants
    log "install complete"
    ;;
  verify)
    ensure_tracker
    verify_tables
    verify_extensions
    verify_embedding_index
    verify_helpers
    verify_agent_zero_role
    log "verify ok"
    ;;
  status)
    ensure_tracker
    run_sql "SELECT version || ' | applied_at=' || applied_at
             FROM schema_migrations ORDER BY version"
    ;;
  reset)
    log "reset is a no-op for a fresh cluster; cluster-install lives in lib/postgres.sh"
    log "to nuke the cluster, run: sudo /usr/lib/postgresql/18/bin/pg_ctl -D /var/lib/postgresql/... stop"
    log "                       sudo rm -rf /var/lib/postgresql/18"
    ;;
  help|--help|-h|"") usage ;;
  *) echo "unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac
