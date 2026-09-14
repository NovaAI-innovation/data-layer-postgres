#!/usr/bin/env bash
# lib/postgres.sh - Install + init PostgreSQL 18 (idempotent).
#
# On a fresh Debian/Ubuntu host: apt-install postgresql-18, init cluster,
# start it, set the postgres password, enable localhost listen.
# On an existing host (already has postgres 18): skip install, just verify
# the cluster is online and the password matches POSTGRES_PASSWORD.

set -euo pipefail

log() { printf '[postgres %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[postgres FAIL] %s\n' "$*" >&2; exit 3; }

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}"
: "${PERSISTENCE_DATA_DIR:=/var/lib/postgresql}"

# ---- detect environment ----
IN_DOCKER=0
if [[ -f /.dockerenv || -f /run/.containerenv ]]; then IN_DOCKER=1; fi

# Inside an Agent Zero container, postgresql is expected to be installed
# already. Skip apt, just bring up the cluster.
if [[ $IN_DOCKER -eq 0 ]] && command -v pg_lsclusters >/dev/null 2>&1 \
   && [[ -z "$(pg_lsclusters -h | awk '$1=="18"')" ]]; then
    log "postgres 18 cluster not present, attempting apt install"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq postgresql-18 || {
            log "apt failed; trying to add PGDG repo"
            apt-get install -y -qq curl ca-certificates gnupg lsb-release
            . /etc/os-release
            echo "deb http://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
                > /etc/apt/sources.list.d/pgdg.list
            curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor \
                -o /etc/apt/trusted.gpg.d/postgresql.gpg
            apt-get update -qq
            apt-get install -y -qq postgresql-18
        }
    else
        fail "no apt and no postgres cluster found; install postgres 18 manually"
    fi
else
    log "postgres 18 already present, skipping apt install"
fi

# ---- ensure cluster exists ----
if ! pg_lsclusters -h | awk '$1=="18"{found=1} END{exit !found}'; then
    log "creating cluster 18/main"
    pg_createcluster 18 main --start
else
    log "cluster 18/main already exists"
    pg_ctlcluster 18 main start || true
fi

# ---- ensure localhost listen ----
CONF=/etc/postgresql/18/main/postgresql.conf
if [[ -f "$CONF" ]] && ! grep -q "^listen_addresses" "$CONF"; then
    sed -i "s|#listen_addresses = 'localhost'|listen_addresses = 'localhost'|" "$CONF"
    log "enabled localhost listen in $CONF"
    pg_ctlcluster 18 main restart
fi

# ---- ensure password ----
runuser -u postgres -- psql -tAc "ALTER USER postgres WITH PASSWORD '$POSTGRES_PASSWORD'" >/dev/null
log "postgres password synced"

chown -R postgres:postgres "$PERSISTENCE_DATA_DIR" 2>/dev/null || true

# ---- wait for ready ----
for i in 1 2 3 4 5 6 7 8 9 10; do
    if PGPASSWORD="$POSTGRES_PASSWORD" psql -h localhost -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
        log "postgres ready on localhost:5432"
        exit 0
    fi
    sleep 1
done
fail "postgres did not become ready on localhost:5432"
