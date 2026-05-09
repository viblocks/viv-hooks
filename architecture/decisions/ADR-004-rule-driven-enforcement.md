# ADR-004 — Rule-driven enforcement via routing-loader and workflow-loader

**Status:** Accepted
**Date:** 2026-05-08
**Category:** viv-hooks local

## Context

viblocks-ai's hooks contain hardcoded patterns:

- `enforce-routing.sh` had `CLASS_A_PATTERNS=("*/services/*" "*/packages/*" ...)` — a literal array.
- `audit-trail-gate.sh` had `Audit-Trail:[[:space:]]*(VI-[0-9]+|adhoc-[a-z0-9-]+)` — a hardcoded regex with viblocks' Linear prefix.
- The fix-intent gate had keywords inline in `settings.json`: `fix|bug|fail|broken|...|falla|corregir|...`.

Per ADR-RD-003 (single routing file), ADR-RD-004 (classifier folded), and ADR-RD-005 (workflow rules as data), these patterns must come from **declarative rule files** (`routing-table.json`, `audit-trail-pattern.json`, `fix-intent-pattern.json`, `evidence-schema.json`, `post-implementation-chain.json`). Hardcoding them violates the system-wide architecture.

## Decision

Two loader libraries decouple hooks from rule data:

### `lib/routing-loader.sh`

```
resolve_routing_table_path        → echo path or ""
load_class_a_patterns             → echo patterns from enforced=true routes
load_class_a_patterns_array <var> → populate bash array (raw + */raw variants)
route_for_path <abs-path>         → echo {domain, implementer, reviewer} JSON
reviewer_for_implementer <name>   → echo reviewer per pairings + routing
```

### `lib/workflow-loader.sh`

```
resolve_workflow_file <basename>      → echo path or ""
load_evidence_required_markers       → echo one marker per line
load_audit_trail_trailer_name        → echo trailer name (e.g. "Audit-Trail")
load_audit_trail_value_pattern       → echo regex (consumer-defined)
load_audit_trail_editor_policy       → echo block|warn|allow
load_fix_intent_keywords             → echo keywords across all language sets
load_fix_intent_required_tokens      → echo tokens (Root cause:/Causa raíz:/...)
load_fix_intent_agent_pattern        → echo agent regex
load_fix_intent_violation_message    → echo consumer-defined message
load_security_review_paths           → echo glob patterns
```

Hooks call these loaders. **No hook embeds patterns directly.**

## Rationale

| Concern | How this satisfies |
|---|---|
| ADR-RD-005 compliance | Workflow rules ARE data; hooks consume them at runtime |
| ADR-RD-003/004 compliance | Class A scope is computed from routing-table; no separate classifier file or hardcoded array |
| Consumer customization | Changing the audit-trail prefix is a 1-line JSON edit, not a hook code change |
| Drift prevention | A consumer who updates routing-table sees hooks adapt automatically; no parallel array to maintain |

## Consequences

- Hooks have **zero project-specific patterns**. A consumer can vendor viv-hooks and a different consumer's routing/workflow data, and the hooks behave correctly for that consumer.
- Hooks fail-soft when contract files are absent (per ADR-002 local). A consumer using only viv-hooks without routing/workflows gets warnings on stderr but no blocks.
- Performance cost: each hook invocation reads + parses JSON (jq). Mitigation: cached jq invocations within a single hook run; cross-hook caching not implemented (each hook is a fresh process).
- Hooks lose the ability to enforce a rule the consumer hasn't yet declared — a consumer transitioning from no rules → rules has zero enforcement during the gap. Acceptable per fail-soft policy.

## Alternatives considered

- **Compile patterns into hook scripts at vendor time:** rejected — couples hooks to a build step; defeats the cp-r vendoring pattern.
- **Generate hook scripts from rule files via a CLI:** rejected — re-introduces a code generator (deferred per viv-typed-agents §10 outstanding decisions).
- **Hardcode "common" patterns in hooks; allow override via env vars:** rejected — partial decoupling; consumer who renames a domain still must update hook code.

## Related

- ADR-RD-003 (single routing file)
- ADR-RD-004 (classifier folded)
- ADR-RD-005 (workflows as data)
- ADR-002 local (fail-soft on missing config)
