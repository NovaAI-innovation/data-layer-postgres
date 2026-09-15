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
  run_sql "BEGIN; \$(cat "$file"); COMMIT;" >/dev/null
  run_sql "INSERT INTO schema_migrations(version) VALUES('$version')" >/dev/null
  log "$version applied"
}

verify_tables() {
  for t in projects agent_frameworks agents sessions messages tool_executions \n           agent_skills agent_plugins available_tools hooks; do
    local exists
    exists=$(run_sql "SELECT 1 FROM information_schema.tables
                       WHERE table_schema='public' AND table_name='$t'")
    [[ -n "$exists" ]] || fail "table $t missing after migration"
  done
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

usage() {
  cat <<USAGE
Usage: $0 <install|verify|status|reset>

Environment:
  DATA_LAYER_POSTGRES_DSN   postgres URI (default: postgresql://postgres@localhost:5432/postgres)
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
    log "install complete"
    ;;
  verify)
    ensure_tracker
    verify_tables
    verify_extensions
    verify_embedding_index
    verify_helpers
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
