# data-layer-postgres/Dockerfile
#
# Builds the postgres schema service for the data-layer stack.
# Wraps pgvector/pgvector:pg16 with:
#   - all six data-layer migrations auto-applied on first start
#   - agent_zero role + database + grants created on first start
#   - persistent data via the postgres base image's /var/lib/postgresql/data
#
# Build:   docker build -t data-layer-postgres data-layer-postgres/
# Run:     docker run -d --name az-postgres \n#                -p 127.0.0.1:5432:5432 \n#                -v az-postgres-data:/var/lib/postgresql/data \n#                -e POSTGRES_PASSWORD=postgres_dev_password \n#                -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \n#                data-layer-postgres

FROM pgvector/pgvector:pg16

LABEL org.opencontainers.image.title="data-layer-postgres"
LABEL org.opencontainers.image.description="pgvector postgres + data-layer migrations + agent_zero role"
LABEL org.opencontainers.image.source="data-layer/data-layer-postgres"

# Copy all SQL migrations. The pgvector image's docker-entrypoint.sh
# auto-runs /docker-entrypoint-initdb.d/*.sql in lex order on first
# start (when the data directory is empty). Re-runs are no-ops because
# each migration is idempotent (IF NOT EXISTS, OR REPLACE, etc.).
COPY migrations/*.sql /docker-entrypoint-initdb.d/

# Post-migration bootstrap: create the agent_zero role, the agent_zero
# database, and the per-table CRUD grants. Runs LAST in lex order so
# the migrations' tables and functions are already present.
COPY docker-entrypoint-initdb.d/zzz_create_agent_zero.sh /docker-entrypoint-initdb.d/
RUN chmod 0755 /docker-entrypoint-initdb.d/zzz_create_agent_zero.sh

# Healthcheck: postgres is ready when SELECT 1 returns.
HEALTHCHECK --interval=10s --timeout=3s --retries=5 CMD pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1

# Use the stock postgres entrypoint; our init scripts fire from
# /docker-entrypoint-initdb.d/ during first start.
CMD ["docker-entrypoint.sh", "postgres"]
