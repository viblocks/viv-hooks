# Preservation audit

What was extracted into viv-hooks vs. what stayed behind in viblocks-ai.

## Extracted (lives in viv-hooks)

| Capability | Source | Where it lives now |
|---|---|---|
| Routing enforcement (Class A → typed agent) | `enforce-routing.sh` (167L) | `hooks/deny/enforce-routing.sh` (rule-driven) |
| Secrets blocking (.env*, *.pem, *.key, *credential*, secrets/**) | `enforce-secrets.sh` (120L) | `hooks/deny/enforce-secrets.sh` |
| Self-mod protection (.claude/hooks, settings, root CLAUDE.md) | `enforce-self-mod.sh` (157L) | `hooks/deny/enforce-self-mod.sh` |
| Subagent isolation (scope confinement) | `enforce-subagent-isolation.sh` (172L) | `hooks/deny/enforce-subagent-isolation.sh` |
| Bash write-target extraction (verb-agnostic) | `lib/bash-write-detector.sh` (378L) | `lib/bash-write-detector.sh` (unchanged) |
| Marker registry (concurrent-safe) | `lib/marker-registry.sh` (200L) | `lib/marker-registry.sh` (unchanged) |
| Role detection (walk-up from marker) | `lib/role-detection.sh` (109L) | `lib/role-detection.sh` (unchanged) |
| Path utilities (canonicalize, is_class_a) | `lib/path-utils.sh` (74L) | `lib/path-utils.sh` (unchanged) |
| Audit-Trail commit trailer enforcement | `pretooluse-bash-commit.sh` (75L) | `hooks/commit/audit-trail-gate.sh` (rule-driven) |
| Fast-lane refinement for Class A non-app | `pretooluse-fast-lane.sh` (234L) | `hooks/refinement/fast-lane.sh` |
| Marker register lifecycle | `pretooluse-agent.sh` (132L) | `hooks/lifecycle/marker-register.sh` |
| Marker cleanup lifecycle | `posttooluse-agent.sh` (51L) | `hooks/lifecycle/marker-cleanup.sh` |
| Skill-install advisory (inline) | `settings.json` PostToolUse | `hooks/advisory/skill-installed-advisor.sh` |
| Post-impl chain advisory (inline) | `settings.json` PostToolUse | `hooks/advisory/post-impl-chain.sh` |
| Evidence gate (inline; gh issue close) | `settings.json` PreToolUse | `hooks/advisory/evidence-gate.sh` (rule-driven) |
| Fix-intent gate (inline; *implementer* + fix keywords) | `settings.json` PreToolUse | `hooks/advisory/fix-intent-gate.sh` (rule-driven) |

## NEW (no equivalent in viblocks)

| Capability | Why added |
|---|---|
| `lib/routing-loader.sh` | Implements ADR-RD-003/004 — eliminates hardcoded CLASS_A_PATTERNS |
| `lib/workflow-loader.sh` | Implements ADR-RD-005 — eliminates inline rule logic |
| `settings.json.fragment` | Consumer glue template (ADR-RD-001 — no inline hooks) |

## Stayed behind (viblocks-ai-specific)

| Content | Why it stays |
|---|---|
| Blacklist domain detector (TronPoll, EthereumPoll, etc. keywords) | viblocks' product domain advisor |
| Semantic token gate | viblocks UI design system |
| `VI-` Linear prefix in audit-trail | Consumer-defined via workflow rule (now configurable) |
| Spanish-only violation messages | Preserved in viblocks examples; default messages now English |
| Reference to `aidlc-docs/` paths | viblocks' AI-DLC integration files |
| `.claude/context/` legacy directory | Honored as fallback; preferred is `.claude/routing/` |

## Knowledge loss check

- [x] All 4 deny hook capabilities preserved (routing, secrets, self-mod, isolation)
- [x] Verb-agnostic write detection preserved (1 file, 378L unchanged)
- [x] Marker registry concurrency model preserved (flock + mkdir-spinlock fallback)
- [x] Role detection precedence preserved (CLAUDE_HOOK_TEST gate, marker walk-up, default main)
- [x] All security hardenings preserved (SEC-M3 shell-subst fail-closed, SEC-M4 no-warn-downgrade, INFRA-H1 interpreter-as-editor, INFRA-H2 git-apply block)
- [x] Editor-mode commit policy preserved (configurable via audit-trail-pattern.json)
- [x] Fast-lane 7-criteria eligibility preserved
- [x] All 4 inline advisory hooks extracted to standalone files
- [x] Audit-Trail trailer name + regex made consumer-configurable

## Verification

Reproduce viblocks-ai's behavior with viv-hooks + viv-routing/viblocks-style + viv-workflows/viblocks-style:

| viblocks-ai behavior | viv-hooks equivalent |
|---|---|
| Main session edit `services/core/foo.ts` → blocked | enforce-routing reads routing-table → matches `services/core/**` enforced=true → blocks |
| Subagent edit within scope → allowed | role-detection returns subagent → enforce-routing exits 0 |
| Read `.env.production` from any role → blocked | enforce-secrets matches `.env*` (excluding .env.example etc.) → blocks |
| Edit `.claude/hooks/foo.sh` from main → blocked | enforce-self-mod matches `.claude/hooks/**` → blocks |
| Subagent escapes scope via `cd /etc/...` → blocked | enforce-subagent-isolation detects absolute path outside scope → blocks |
| Commit Class A files without `Audit-Trail:` trailer → blocked | audit-trail-gate reads pattern from workflow rule, validates, blocks if missing |
| Dispatch `*-implementer` with fix prompt without `Root cause:` → blocked | fix-intent-gate reads keywords + tokens from workflow rule, blocks if missing |
| Close issue without 4 evidence markers → blocked | evidence-gate reads markers from workflow rule, blocks if any missing |
| `git apply` from main → blocked | enforce-routing INFRA-H2 unconditional block (preserved) |
| `python -c "open('services/...')"` from main → blocked | enforce-routing INFRA-H1 keyword scan (uses pattern roots from routing) |

All major behaviors representable. No coverage loss for the generic strategy.

**Project-specific gaps (intentional)**: blacklist detector and semantic-token gate are NOT in viv-hooks; they remain consumer extensions in viblocks-ai's settings.json.

## Identified during post-extraction review

End-to-end network validation (2026-05-08) cross-checked schema fields published
by `viv-routing` and `viv-workflows` against fields actually consumed by
`viv-hooks`. Two contract drifts were detected and corrected in commit after
initial publication:

### MED-1 (resolved) — `audit-trail-gate.sh` ignored `applies_to`

Schema `audit-trail-pattern.schema.json` declares an enum
`["class_a", "all", "any-staged-path"]`. Initial hook hardcoded `class_a`
behavior regardless. Fix: added `load_audit_trail_applies_to` to
`workflow-loader.sh` and switched the gate logic on the value. All three enum
values now route through `TRIGGERED_PATHS` correctly.

### MED-2 (resolved) — `routing-loader.reviewer_for_implementer` ignored `default_rule`

Schema `implementer-reviewer-pairings.schema.json` declares
`default_rule: enum["from-routing-table", "explicit-only"]`. Initial loader
always fell through to routing-table even when the rule said `explicit-only`.
Fix: read `default_rule` after checking overrides; branch on the value;
`explicit-only` now returns empty when no override matches.

### LOW-1 (deferred) — `security-reviewer` literal in OR playbook

`viv-orchestration-rules/playbooks/post-implementation-chain.md` mentions
`security-reviewer` literally in two places. Strictly violates SPEC Apéndice B
invariant 7. Atenuante: `security-reviewer` is a singleton agent (no
domain prefix, no tier variant) declared once in `viv-agents`. Decision:
acceptable as-is; consumer can override the post-impl-chain JSON if they use
a different security-review agent.
