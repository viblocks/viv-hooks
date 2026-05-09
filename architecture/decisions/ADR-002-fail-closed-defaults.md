# ADR-002 — Fail-closed on ambiguity; fail-soft on missing config

**Status:** Accepted
**Date:** 2026-05-08
**Category:** viv-hooks local

## Context

Hooks operate at security boundaries. Their default behavior under ambiguity matters:

- **Fail-closed** = block on ambiguity. Higher safety, more false positives.
- **Fail-open** = allow on ambiguity. Higher convenience, lower safety.

viblocks-ai's hooks were tightened over time toward fail-closed for security-relevant ambiguity (shell-substitution in Class A targets, missing canonicalization, missing jq). But they fail-soft when the contract data itself is missing (no routing-table = log + exit 0).

The dichotomy needs to be explicit: **operational ambiguity** (ambiguity within a contract) is fail-closed; **configuration absence** (the contract itself is missing) is fail-soft.

## Decision

### Fail-closed cases (exit 2, block)

All of these block by default:

1. **Canonicalization failure** in `path-utils.canonicalize` → block (path resolution couldn't determine the real target).
2. **Shell substitution** (`$`, backtick, `~`) in a write-shaped Bash command without an extractable literal target → block (target is opaque; SEC-M3).
3. **Missing `jq`** → block (cannot parse hook input; FATAL exit 2).
4. **Invalid JSON input** to a hook → block (fail-fast; FATAL).
5. **Marker walk-up returns no scope** AND `CLAUDE_HOOK_TEST` is not set → role defaults to `main` (fail-safe — false positives only block writes, never grant escalation).

### Fail-soft cases (exit 0 with stderr WARN)

These are non-violations:

1. **Routing-table missing** → log "no routing-table.json resolved" → exit 0. The hook is inert; consumers who haven't yet vendored `viv-routing` are not blocked from doing other work.
2. **Workflow rule file missing** → log "no <rule>.json resolved" → exit 0.
3. **Routing-table present but no `enforced: true` routes** → exit 0 (consumer may have only Class B routes).

### Asymmetric mode handling

Per ADR-003 local, **deny hooks do NOT honor `warn` mode**. Setting `CLAUDE_HOOKS_MODE=warn` does not downgrade a hard-deny to a soft warning — it falls through to the default (`hard`). Only `disabled` provides a bypass.

## Rationale

| Concern | How this satisfies |
|---|---|
| Safety | Operational ambiguity blocks; never silently allows |
| Onboarding ergonomics | Missing config is not a blocker; consumer can vendor incrementally |
| Auditability | All fail-closed cases emit `additionalContext` explaining the block reason |
| No silent downgrade | `warn` cannot soften a deny; SEC-M4 rationale |

## Consequences

- A consumer who has NOT vendored `viv-routing` will see "WARN: no routing-table.json resolved" on stderr but be otherwise unblocked. The hooks are inert.
- A consumer who has vendored `viv-routing` but with zero `enforced: true` routes will likewise be unblocked. Effectively all paths are Class B.
- A typo in the routing-table (malformed JSON) is treated as a configuration error: hooks may emit "FATAL: invalid JSON input" or behave inert depending on which loader call hits the parse error.
- Consumers who want stricter behavior (e.g. block on missing config) can set `CLAUDE_HOOKS_REQUIRE_CONFIG=1` (future extension; not yet implemented — see ADR-004).

## Alternatives considered

- **Block on missing config:** rejected — onboarding tax too high; a consumer just vendoring viv-hooks before routing/workflows would be locked out.
- **Allow on shell-substitution:** rejected — bypassed by `cp $X /services/foo` with `X=../malicious-source`; security regression vs viblocks.
- **Honor `warn` for deny hooks:** rejected — silently downgrading hard-deny is the SEC-M4 anti-pattern.

## Related

- ADR-003 local (mode policy)
- ADR-RD-006 (hook type taxonomy; deny/advisory/refinement/lifecycle)
- viblocks SEC-M3, SEC-M4 (origin of the asymmetric mode handling)
