# 0002 — Audit-grade ephemeral state promoted to postgres

**Status:** Accepted (per data-layer architecture review, 2026-09-14)
**Context:** Several categories of state that were previously
redis-only are required by audit, recovery, or correctness flows.
Storing them in redis-only meant correctness depended on TTL
housekeeping (a time-based vacuum) instead of a durable primary
record. The review concluded that anything audit-grade must live in
postgres as the source of truth, with redis serving as hot cache /
ephemeral working state.

## Decision

Apply the following rule uniformly:

> **If a state category must survive an audit, replay, or recovery
> scenario, postgres is the primary. Redis is allowed as a hot cache
> or working copy, but a redis miss or TTL expiry must never cause a
> correctness failure.**

Operational-only state (lock tokens, pub/sub fan-out, transient
working blobs, request-scoped counters) stays in redis by design.
Those categories are explicitly OUT of this ADR.

## Promoted categories (Phase 1 candidates)

| Category | Primary home | Redis role | Migration |
|---|---|---|---|
| Session presence / heartbeat | postgres (`session_heartbeats` or `sessions.last_heartbeat_at`) | hot cache (recent N seconds) | `0004_session_presence.sql` |
| Tool execution lifecycle | postgres `tool_executions` (extended) | cache of in-flight subset | `0005_tool_executions_lifecycle.sql` |
| Idempotency keys | postgres `idempotency_keys` | cache for active window | `0006_idempotency_keys.sql` |
| Rate-limit events (deferred) | postgres `rate_limit_events` | rolling counter cache | ADR-locked; migration deferred |
| Lock audit (deferred) | postgres `lock_audit` | none | ADR-locked; migration deferred |

## What stays redis-only

- Lock tokens (transient, contended, never audited)
- Pure cache reads (any key whose source of truth is elsewhere)
- Pub/sub channels (one-shot, not durable)
- Working blobs (request-scoped, never inspected)
- Current counters (best-effort, derived not stored)

## Migration notes

- Append-only migrations under `data-layer-postgres/migrations/`.
- Each migration is idempotent (`IF NOT EXISTS`, `ADD COLUMN IF NOT
  EXISTS`).
- Each migration runs after the previous in the standard applier.
- No backfill required for hot-only historical data (we accept
  starting fresh on day 1 of the new schema).

## Consequences

- Postgres write traffic increases by O(active_sessions + in_flight_tools).
- TTL on redis for promoted keys becomes advisory (cache may go
  cold; postgres still has the durable record).
- The cache layer's failure semantics (miss-on-error) remain valid
  and are reinforced: a redis outage never breaks correctness.
- Vacuuming the postgres tables is now part of normal operational
  hygiene (separate effort, see Postgres ops followups).

## See also

- `docs/decisions/0001-framework-local-id-is-container-name.md` —
  identity contract for the rows that populate these tables.
- `../data-layer-redis/docs/decisions/0001-key-pattern-catalog.md`
  — the matching redis key inventory.
- `../data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md`
  — how adapters write through to both stores.
- `../data-layer-falkordb/docs/decisions/0002-data-layer-recommendations-handoff.md`
  — parent handoff that named these categories.
