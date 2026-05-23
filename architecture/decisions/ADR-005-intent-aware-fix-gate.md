# ADR-005 — Intent-aware fix-intent-gate

**Status:** Accepted
**Date:** 2026-05-22
**Category:** viv-hooks local
**Closes:** [viv-hooks#2](https://github.com/viblocks/viv-hooks/issues/2)

## Context

`hooks/advisory/fix-intent-gate.sh` blocked any dispatched implementer prompt
that mentioned a bugfix-shaped keyword (`fix`, `bug`, `broken`, `falla`,
`corregir`, ...) without also containing `Root cause:` / `Causa raíz:`. The
keyword list comes from `fix-intent-pattern.json` (per ADR-004) so the rule
is data-driven, but the gate ran on every step regardless of its actual
intent.

This produced false positives on feature work. A consumer of
viv-aidlc-orchestrator reported:

> El gate `fix-intent-gate.sh` exige "Root cause:/Causa raíz:" en el prompt.
> Step 32 es feature work nuevo (no bugfix), pero el hook es genérico.

The operator workaround was to add an artificial `Root cause:` preamble to
feature prompts. This contaminates feature prompts with bugfix vocabulary
and trains a bad habit (writing fake root causes to placate the gate).

## Decision

Add an intent-detection layer (`lib/intent-detection.sh`) and apply the
gate **only** when the step intent is confirmed to be `bugfix` (which
covers `hotfix` and `incident` as aliases). The gate stays advisory; the
"block" remains a `<system-reminder>` with `exit 2`.

### Intent resolution precedence

First match wins:

| # | Source | Strength | Rationale |
|---|---|---|---|
| 1 | `Intent: <name>` in prompt | Highest — author opted in | Most explicit |
| 2 | Env var `AIDLC_INTENT` | Orchestrator-provided | Stronger than convention |
| 3 | Env var `AIDLC_STEP_TYPE` | Orchestrator step metadata | Equivalent to #2 when present |
| 4 | Branch name prefix | Conventional but reliable | `feat/*`, `fix/*`, `refactor/*`, ... |
| 5 | Keyword count ≥ 2 (heuristic) | Weak — last resort | Strong-enough text signal |
| 6 | `unknown` → fail-open | — | Prefer false-negative over false-positive |

The textual heuristic (#5) uses the same JSON-defined keyword set the old
gate used, but now requires **two distinct keyword matches** before
declaring `bugfix`. A prompt that incidentally says "add a fix-it button"
no longer triggers the gate. A prompt that mentions "broken" + "regression"
+ "failing" still does.

### Why fail-open on `unknown`

The hook is advisory. The cost of a false positive (operator pollutes
feature prompts with `Root cause:`) is concrete and recurring. The cost of
a false negative (a real bugfix is dispatched without `Root cause:`) is
that a separate downstream check or human review catches it. Per ADR-002
(fail-closed defaults), enforcement gates fail closed; this one is
explicitly advisory and inverts the bias.

### Aliases handled

`bugfix`, `bug`, `fix`, `hotfix`, `incident`, `patch` → `bugfix`.
`feature`, `feat`, `enhancement`, `new` → `feature`.
`refactor`, `refactoring`, `cleanup` → `refactor`.
`docs`, `doc`, `documentation` → `docs`.
`chore`, `maintenance`, `deps`, `dependency`, `dependabot` → `chore`.

## Consequences

### Behavior changes per scenario

| Scenario | Before | After |
|---|---|---|
| Bugfix branch (`fix/*`) + `Root cause:` | pass | pass |
| Bugfix branch (`fix/*`) + missing marker | advisory | advisory |
| Feature branch (`feat/*`) + missing marker | **advisory (false positive)** | **pass** |
| Feature branch (`feat/*`) + artificial `Root cause:` | pass | pass |
| `Intent: feature` in prompt + missing marker | n/a (no parsing) | pass |
| `Intent: bugfix` overrides `feat/*` branch | n/a | advisory |
| Plain prompt on `main`, one keyword (`fix`) | advisory | pass |
| Plain prompt on `main`, many keywords | advisory | advisory (heuristic) |

### Zero regression for the reporting consumer

The consumer's workaround was to add `Root cause:` to feature prompts.
After this change:

- Their bugfix dispatches with `Root cause:` → still pass.
- Their feature dispatches with artificial `Root cause:` → still pass
  (the gate does not reject by excess; presence of the marker just goes
  unused when intent ≠ bugfix).
- Their feature dispatches without `Root cause:` → **now pass** (the
  problem reported in the issue).

They can drop the workaround at their own pace.

### Performance

One additional `grep -oiE` + `sort -u` per Agent dispatch when keywords
are configured. Negligible compared to the existing `jq` work.

### Surface area for orchestrator integration

The hook now recognizes `AIDLC_INTENT` and `AIDLC_STEP_TYPE` env vars.
viv-aidlc-orchestrator does not set these today; when it does, the gate
will pick them up automatically. No installer change is required.

## Decision 1 — Defer `Goal:` / `Objetivo:` for feature work

The issue asks the gate to **stop** enforcing `Root cause:` on non-bugfix
work. It does not ask for a new positive requirement on feature work.
Adding `Goal:` enforcement is scope creep this consumer did not request.

Deferred to a future change, behind an opt-in JSON config field
(`feature_required_tokens`). When and if a consumer requests it, the
intent-detection layer is already in place; only `fix-intent-gate.sh`
would need an extra branch.

## Decision 2 — `hotfix` and `incident` are aliases of `bugfix`

Semantically they are bugfix with different urgency. The gate's
requirement (Root cause attribution) is identical for all three.
No separate intent label is introduced.

## Decision 3 — Heuristic threshold (≥2 distinct keywords)

Single-keyword matches are too noisy; the keyword list deliberately
includes generic words ("fix", "fail") to catch bugfix language.
Requiring two distinct matches keeps the heuristic useful while
eliminating the most common false-positive class (incidental usage).

Trade-off: a bugfix prompt that uses only one keyword and is dispatched
without an `Intent:` marker, env var, or `fix/*` branch will now slip
through. This is the documented fail-open bias.

## Open questions

- Should the heuristic threshold be configurable in
  `fix-intent-pattern.json` (e.g. `min_keyword_hits: 2`)?
  Defer until a second consumer asks for a different threshold.
- Should `Goal:` / `Objetivo:` enforcement on feature work become a
  separate sibling gate (`goal-intent-gate.sh`) instead of a flag in
  this gate? Decide when the first consumer asks.
- If a future `stage-transition-gate` lands in viv-aidlc-orchestrator,
  it should publish `AIDLC_INTENT` automatically — at that point branch
  inference becomes a fallback rather than the primary signal.

## Related

- ADR-002 (fail-closed defaults) — explicitly inverted here for the
  advisory case; documented as the exception.
- ADR-004 (rule-driven enforcement) — keyword list still loaded from
  `fix-intent-pattern.json`; only the gating logic is new.
- [viv-hooks#2](https://github.com/viblocks/viv-hooks/issues/2) — issue this closes.
