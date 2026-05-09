# Migration from viblocks-ai

How viv-hooks was extracted from viblocks-ai's `.claude/hooks/` and inline `.claude/settings.json` rules.

## Source artifacts

### Standalone hook files (viblocks-ai/.claude/hooks/)

| File | Lines | Role |
|---|---|---|
| `enforce-routing.sh` | 167 | Deny — block Class A writes from main |
| `enforce-secrets.sh` | 120 | Deny — block .env*/secrets/*.pem/*.key/*credential* |
| `enforce-self-mod.sh` | 157 | Deny — block edits to .claude/hooks, settings, root CLAUDE.md |
| `enforce-subagent-isolation.sh` | 172 | Deny — confine subagents to their scope |
| `pretooluse-bash-commit.sh` | 75 | Commit gate — Audit-Trail trailer |
| `pretooluse-fast-lane.sh` | 234 | Refinement — fast-lane allow for Class A non-app |
| `pretooluse-agent.sh` | 132 | Lifecycle — register marker; advisory routing |
| `posttooluse-agent.sh` | 51 | Lifecycle — cleanup marker |
| `lib/path-utils.sh` | 74 | Helper — canonicalize, is_under, is_class_a |
| `lib/marker-registry.sh` | 200 | Helper — concurrent-safe marker file ops |
| `lib/role-detection.sh` | 109 | Helper — main-vs-subagent via walk-up |
| `lib/bash-write-detector.sh` | 378 | Helper — verb-agnostic write extraction |

Total ~1869 lines.

### Inline hook commands in settings.json

| Inline command | Extracted to |
|---|---|
| Skill-install advisor (post-tool-use Edit/Write on .claude/skills/**) | `hooks/advisory/skill-installed-advisor.sh` |
| Post-implementation chain advisor (post-tool-use Agent) | `hooks/advisory/post-impl-chain.sh` |
| Evidence gate (pre-tool-use Bash on `gh issue close`) | `hooks/advisory/evidence-gate.sh` |
| Fix-intent gate (pre-tool-use Agent on *implementer*) | `hooks/advisory/fix-intent-gate.sh` |
| Blacklist domain detector | **NOT extracted** — project-specific advisor |
| Semantic token gate | **NOT extracted** — project-specific (viblocks UI tokens) |

## Transformations applied

### 1. Reorganized into SRP-typed directories (per ADR-RD-006)

```
hooks/
├── deny/        ← enforce-* (4 files)
├── advisory/    ← post-impl, evidence, fix-intent, skill-installed (4 files)
├── refinement/  ← fast-lane (1 file)
├── lifecycle/   ← marker-register, marker-cleanup (2 files)
└── commit/      ← audit-trail-gate (1 file)
```

Files renamed for clarity:
- `pretooluse-bash-commit.sh` → `commit/audit-trail-gate.sh`
- `pretooluse-fast-lane.sh` → `refinement/fast-lane.sh`
- `pretooluse-agent.sh` → `lifecycle/marker-register.sh`
- `posttooluse-agent.sh` → `lifecycle/marker-cleanup.sh`

### 2. Replaced hardcoded patterns with rule-driven loaders (per ADR-004 local + ADR-RD-004/005)

Major redesigns:

| Hook | Before | After |
|---|---|---|
| `enforce-routing.sh` | Hardcoded `CLASS_A_PATTERNS=("*/services/*" "*/packages/*" ...)` array | Calls `load_class_a_patterns_array` from `lib/routing-loader.sh`; reads `routing-table.json` |
| `audit-trail-gate.sh` | Hardcoded `Audit-Trail:[[:space:]]*(VI-[0-9]+|adhoc-...)` regex; references to `.claude/context/artifact-classifier.json` and `scripts/query-classifier.sh` | Calls `load_audit_trail_trailer_name` and `load_audit_trail_value_pattern` from `lib/workflow-loader.sh`; consumes `audit-trail-pattern.json`. Class A check via routing-loader. |
| `evidence-gate.sh` (new file) | Inline bash in settings.json with `**Verification**`, `**Code review**`, etc. literals | Reads `evidence-schema.json` from workflow-loader; markers come from JSON |
| `fix-intent-gate.sh` (new file) | Inline bash with EN+ES keyword alternation | Reads `fix-intent-pattern.json`; flattens language-segmented arrays |
| `marker-register.sh` | Hardcoded keyword regex for path detection; references `scripts/query-classifier.sh` | Builds keyword regex from routing-table pattern roots; falls back to generic if loader unavailable |

### 3. Renamed env var (compatible)

`AIDLC_ENFORCEMENT_MODE` → `CLAUDE_HOOKS_MODE`. Legacy name still honored for migration: `MODE="${CLAUDE_HOOKS_MODE:-${AIDLC_ENFORCEMENT_MODE:-hard}}"`. Documented in ADR-003 local.

### 4. New library files

| File | Purpose |
|---|---|
| `lib/routing-loader.sh` | Read routing-table.json; expose `load_class_a_patterns`, `route_for_path`, `reviewer_for_implementer` |
| `lib/workflow-loader.sh` | Read workflow rule files; expose loaders per rule type |

These are NEW (didn't exist in viblocks). They implement the contracts ADR-RD-004 and ADR-RD-005 declare.

### 5. Updated path resolution

Hook layout changed from flat (`hooks/*.sh` + `hooks/lib/*.sh`) to typed (`hooks/<type>/*.sh` + `lib/*.sh`). All hooks updated:

```bash
# Before
LIB_DIR="$(cd "$(dirname "$0")/lib" && pwd)"

# After
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../../lib" && pwd)"
```

### 6. Removed project-specific content

- Spanish-only error messages → kept as defaults from rule files (consumer-customizable via JSON)
- VI-XXX issue prefix → consumer-defined via `audit-trail-pattern.value_pattern`
- Blacklist domain detector → stays in viblocks-ai
- Semantic token gate → stays in viblocks-ai
- viblocks-specific path mentions in fast-lane.sh → preserved (viblocks-style consumer can still match)

## Sanitization checklist

- [x] No `AIDLC_ENFORCEMENT_MODE` as the canonical env var name (legacy honored)
- [x] No `VI-` literal in hook code (consumer-defined via workflow rule)
- [x] No `services|packages|Dockerfile` hardcoded as the only Class A patterns (loaded from routing-table)
- [x] No reference to `.claude/context/artifact-classifier.json` (eliminated per ADR-RD-004)
- [x] No reference to `scripts/query-classifier.sh` (replaced by routing-loader)
- [x] Spanish-only messages restricted to consumer rule files
- [x] Project-specific advisors (blacklist, semantic-token) stayed in viblocks-ai

## Re-vendor plan (future)

When viv-hooks is vendored back into viblocks-ai:

1. Replace `viblocks-ai/.claude/hooks/` with vendored copy (preserve marker file)
2. Vendor companions: `viv-routing` to `.claude/routing/`, `viv-workflows` to `.claude/workflows/`
3. Update `viblocks-ai/.claude/settings.json`:
   - Remove inline rule commands (now in `hooks/advisory/`)
   - Glue in `viv-hooks/settings.json.fragment`
   - Set `CLAUDE_HOOKS_MODE=hard` (or keep `AIDLC_ENFORCEMENT_MODE=hard` legacy)
4. Re-add viblocks-specific extensions (blacklist domain detector, semantic-token gate) as additional hook entries
5. Run full hook test suite (`__tests__/`) — verify behavior unchanged for routing, secrets, self-mod, isolation, fast-lane, commit
6. Spot-check end-to-end: dispatch a typed implementer; confirm chain runs

This re-vendor closes the migration loop. After re-vendor, all 6 components are live in viblocks-ai with the SOLID redesign.
