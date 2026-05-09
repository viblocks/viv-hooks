# ADR-003 — Mode policy: only `disabled` provides bypass

**Status:** Accepted
**Date:** 2026-05-08
**Category:** viv-hooks local

## Context

viblocks-ai introduced an `AIDLC_ENFORCEMENT_MODE` env var with three values: `hard`, `warn`, `disabled`. The original intent: `warn` would log violations without blocking, allowing a grace period during rollout.

In practice, `warn` was inconsistently honored:
- **Deny hooks** (enforce-routing, enforce-secrets, enforce-self-mod, enforce-isolation, audit-trail-gate) treated `warn` as `hard` — honoring `warn` would have silently downgraded hard-deny enforcement (SEC-M4).
- **Advisory hooks** (post-impl-chain, evidence-gate when implemented as deny) treated `warn` as a softer message.
- **Refinement** (fast-lane) used `warn` to log near-misses.

The asymmetry was intentional but underdocumented. Consumers expected `warn` to globally soften enforcement; in reality it varied per hook type.

## Decision

`CLAUDE_HOOKS_MODE` (legacy `AIDLC_ENFORCEMENT_MODE` honored for migration) accepts three values:

| Value | Effect |
|---|---|
| `disabled` | Full bypass. Every hook exits 0 immediately at the top of execution. |
| `hard` (default) | Strict enforcement. Deny hooks block on violation; advisory hooks emit context; refinement hooks emit allow. |
| `warn` | **Not honored by deny/commit hooks.** Honored only by advisory and refinement hooks (where it was already accepted as a softer mode). |

Setting `CLAUDE_HOOKS_MODE=warn` produces the same behavior as `hard` for deny hooks. This is by design.

The only safe global bypass is `disabled`.

## Rationale

| Concern | How this satisfies |
|---|---|
| Predictability | The taxonomy is documented; consumers can read this ADR and know what each mode does |
| Security (SEC-M4) | `warn` cannot silently downgrade hard-deny; an attacker setting `MODE=warn` does not gain bypass |
| Compatibility with viblocks | The legacy env var name is honored; consumers migrating don't need to rename |
| Simplicity | Three values is the minimum; doesn't proliferate to per-hook env vars |

## Consequences

- A consumer who wants per-hook bypass must edit `settings.json` to remove the specific hook entry (not via env var).
- Documentation (this ADR + README hook taxonomy table) is the contract; tooling does not enforce it (the asymmetry is in hook code, not in a config schema).
- Future work could expose a per-hook-type `CLAUDE_HOOKS_<TYPE>_MODE` for finer control; deferred until a real consumer need.

## Alternatives considered

- **Honor `warn` globally (downgrade deny to advisory):** rejected — SEC-M4; silently downgrades hard-deny semantics.
- **Reject `warn` entirely (only `disabled` and `hard`):** considered — cleaner taxonomy, but breaks viblocks consumers who set `MODE=warn` for advisory hooks. Kept for compatibility.
- **Per-hook env vars:** rejected — proliferation; not yet justified by consumer need.

## Related

- ADR-RD-006 (hook type taxonomy)
- ADR-002 local (fail-closed defaults)
- viblocks SEC-M4 (origin)
