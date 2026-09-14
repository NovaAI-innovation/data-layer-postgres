# 0001 — framework_local_id is the running container's name

**Status:** Accepted (per user, 2026-09-13)
**Context:** `persistence-bootstrap/migrations/0002_seed.sql` previously
seeded `framework_local_id='agent-zero-sbzm'`. The user clarified that
the local id should be the container's name (Docker short id or
whatever `--name` was passed at run time).

**Decision:** `agents.framework_local_id = $(hostname)` at apply
time. Local container is `52ba0cdf32af` (verified). Hermes's
container name is supplied at deploy time on the Hermes VPS.

**Consequences:**

- Existing `agent-zero-sbzm` row is migrated by `0003_alter_agents.sql`.
- `plugin/data_management/adapters/chat_json.py` `DEFAULT_AGENT_LOCAL_ID`
  is replaced with a runtime derivation:
  `os.environ.get('AGENT_LOCAL_ID') or os.uname().nodename`.
- `bootstrap` CLI exports `MCP_AGENT_NAME="$(hostname)"` and adds
  `MCP_DEPLOYMENT='local'`.
- `agents.deployment` column (logical host tag) is added to
  disambiguate deployments sharing the same container name.

**See also:** `docs/agent-persistence-schema-plan.md` (Conventions).
