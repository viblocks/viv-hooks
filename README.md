# viv-hooks

Structural enforcement layer for the typed-agents strategy. The **only repo with executable code** (per [ADR-RD-008](https://github.com/viblocks/viv-typed-agents/blob/main/architecture/decisions/ADR-RD-008-pure-descriptors.md)).

This is the **Tier 4** component — vendoring it elevates the strategy from "behavioral guidance" to "structural enforcement". Without these hooks, the IRON LAW is advisory; with them, wrong dispatches are physically blocked at Edit/Write time.

## Contents

```
viv-hooks/
├── README.md
├── settings.json.fragment              ← glue snippet for consumer's settings.json
├── hooks/
│   ├── deny/                           ← hard block on contract violation (ADR-RD-006)
│   │   ├── enforce-routing.sh
│   │   ├── enforce-secrets.sh
│   │   ├── enforce-self-mod.sh
│   │   └── enforce-subagent-isolation.sh
│   ├── advisory/                       ← warn-and-allow with additionalContext
│   │   ├── post-impl-chain.sh
│   │   ├── evidence-gate.sh           ← deny semantics; lives in advisory/ as rule-driven
│   │   ├── fix-intent-gate.sh         ← deny semantics; rule-driven
│   │   └── skill-installed-advisor.sh
│   ├── refinement/                     ← positive override (allow what deny would block)
│   │   └── fast-lane.sh
│   ├── lifecycle/                      ← marker register/cleanup; no allow/deny decision
│   │   ├── marker-register.sh
│   │   └── marker-cleanup.sh
│   └── commit/                         ← commit-trailer gate (DENY type)
│       └── audit-trail-gate.sh
├── lib/
│   ├── path-utils.sh                   ← canonicalize, is_under, is_class_a
│   ├── marker-registry.sh              ← concurrent-safe marker file ops
│   ├── role-detection.sh               ← main-vs-subagent via marker walk-up
│   ├── bash-write-detector.sh          ← verb-agnostic write-target extraction
│   ├── routing-loader.sh               ← read routing-table.json (NEW per ADR-RD-004)
│   └── workflow-loader.sh              ← read workflow rule files (NEW per ADR-RD-005)
├── tests/
│   ├── fixtures/
│   └── *.test.sh                       ← smoke tests
├── architecture/decisions/
│   ├── ADR-001-bash-as-runtime.md
│   ├── ADR-002-fail-closed-defaults.md
│   ├── ADR-003-mode-disabled-only.md
│   └── ADR-004-rule-driven-enforcement.md
└── migration/
    ├── from-viblocks.md
    └── preservation-audit.md
```

## How it works

The hooks consume **contracts** published by the other repos:

```
viv-routing/routing-table.json    ── Class A scope + agent assignments
viv-workflows/<rule>.json         ── audit-trail, evidence, fix-intent rules
viv-agents (referenced by name)    ── implementer/reviewer pairing
```

When the consumer vendors `viv-routing` and `viv-workflows` into their project, the hooks resolve to those files automatically. **No hardcoded patterns in hook code** (per ADRs RD-003/RD-004/RD-005).

### Resolution order

For routing-table:
1. `$CLAUDE_HOOKS_ROUTING_TABLE` env (explicit override)
2. `.claude/routing/routing-table.json`
3. `.claude/context/routing-table.json` (legacy viblocks layout)
4. `<PWD>/.claude/routing/routing-table.json`

For workflow rules:
1. `$CLAUDE_HOOKS_WORKFLOWS_DIR` env
2. `.claude/workflows/<rule>.json`
3. `<PWD>/.claude/workflows/<rule>.json`

If a contract file is missing, the corresponding hook **logs a warning to stderr and exits 0** (cannot enforce a contract that's absent). This is intentional fail-soft for missing config; ADR-002 documents the fail-closed behavior on edge cases within the contract.

## Quick start (consumer)

1. **Vendor**: `cp -r viv-hooks/ my-project/.claude/hooks/`
2. **Vendor companions**: `viv-routing` to `.claude/routing/`, `viv-workflows` to `.claude/workflows/`
3. **Glue**: merge `settings.json.fragment` into `my-project/.claude/settings.json`
4. **Set mode** (optional): `CLAUDE_HOOKS_MODE=hard` (default) | `disabled` (bypass all)
5. **Verify**: dispatch a test agent and confirm hooks fire (look for stderr/blocks)

## Hook taxonomy (per ADR-RD-006)

| Type | Behavior | Honors `disabled` | Honors `warn` |
|---|---|---|---|
| **deny** | exit 2 with `additionalContext` blocks the action | yes | NO (would silently downgrade hard-deny) |
| **advisory** | exit 0 with `additionalContext`; never blocks | yes | yes |
| **refinement** | emits `permissionDecision: allow` to override a parallel deny | yes | yes |
| **lifecycle** | state-only (marker register/cleanup); no allow/deny | no (always runs) | n/a |

## Mode policy (per ADR-003 local)

`CLAUDE_HOOKS_MODE` (legacy `AIDLC_ENFORCEMENT_MODE` honored):

| Value | Effect |
|---|---|
| `disabled` | Full bypass — every hook exits 0 immediately |
| `hard` (default) | Strict enforcement |
| `warn` | **Not honored** for deny/commit hooks (would silently downgrade hard-deny). Honored only for advisory and refinement hooks. |

Documented in ADR-003 local. The asymmetry is intentional — see SEC-M4.

## Companion repos

- [viv-routing](https://github.com/viblocks/viv-routing) — Class A scope + agent map (consumed by enforce-routing, audit-trail-gate, marker-register)
- [viv-workflows](https://github.com/viblocks/viv-workflows) — gate rule data (consumed by evidence-gate, fix-intent-gate, post-impl-chain, audit-trail-gate)
- [viv-agents](https://github.com/viblocks/viv-agents) — agent identities (referenced via routing-table; not directly read by hooks)
- [viv-orchestration-rules](https://github.com/viblocks/viv-orchestration-rules) — behavioral playbooks (Tier 5; orthogonal to hooks)
- [viv-typed-agents](https://github.com/viblocks/viv-typed-agents) — strategy spec + cross-component ADRs

## Status

Initial extraction (2026-05-08). Last component of the typed-agents strategy.
