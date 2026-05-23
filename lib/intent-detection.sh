#!/usr/bin/env bash
# lib/intent-detection.sh — infer step intent for advisory gates.
#
# Per ADR-005 (intent-aware fix gate), the fix-intent-gate should only
# require a Root cause: marker when the dispatch is actually a bugfix.
# This module produces a single intent label so the gate can decide
# whether the rule applies.
#
# Public API:
#   viv_intent_detect <prompt> <branch> [keyword_match_count] → one of:
#     bugfix | feature | refactor | docs | chore | unknown
#
# Inputs (in precedence order, first hit wins):
#   1. Prompt contains explicit "Intent: <name>" line.
#   2. Env var AIDLC_INTENT.
#   3. Env var AIDLC_STEP_TYPE (orchestrator step metadata).
#   4. Branch name conventional prefix (feat/*, fix/*, refactor/*, ...).
#   5. Textual heuristic via keyword_match_count argument
#      (caller pre-computes count from the workflow JSON keyword regex);
#      ≥2 distinct matches → tentative bugfix.
#   6. Default: unknown (fail-open).
#
# The caller supplies the keyword count rather than re-parsing the
# workflow JSON here, so this lib stays pure (no jq, no I/O) and can
# be unit-tested in isolation.

# Normalize free-form step type / intent strings to a canonical label.
viv_intent_normalize() {
  local raw="${1:-}"
  raw=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  case "$raw" in
    bugfix|bug|fix|hotfix|incident|patch) echo "bugfix" ;;
    feature|feat|enhancement|new)         echo "feature" ;;
    refactor|refactoring|cleanup)         echo "refactor" ;;
    docs|doc|documentation)               echo "docs" ;;
    chore|maintenance|deps|dependency)    echo "chore" ;;
    "")                                   echo "" ;;
    *)                                    echo "" ;;
  esac
}

# Extract "Intent: <value>" from the prompt (case-insensitive, first match).
viv_intent_from_prompt() {
  local prompt="${1:-}"
  local raw
  raw=$(printf '%s' "$prompt" \
    | grep -iE '(^|[[:space:]])Intent:[[:space:]]*[A-Za-z]+' \
    | head -n1 \
    | sed -E 's/.*[Ii]ntent:[[:space:]]*([A-Za-z]+).*/\1/')
  viv_intent_normalize "$raw"
}

# Map a git branch name to an intent based on conventional prefixes.
# Returns "" when the branch is ambiguous (main, develop, release/*, etc.).
viv_intent_from_branch() {
  local branch="${1:-}"
  case "$branch" in
    fix/*|hotfix/*|bug/*|bugfix/*)        echo "bugfix" ;;
    feat/*|feature/*)                     echo "feature" ;;
    refactor/*)                           echo "refactor" ;;
    docs/*|doc/*)                         echo "docs" ;;
    chore/*|deps/*|dependabot/*)          echo "chore" ;;
    *)                                    echo "" ;;
  esac
}

# Main entry point.
#   $1 = prompt text
#   $2 = branch name (may be empty)
#   $3 = optional integer: count of distinct workflow-keyword matches in prompt.
#        Caller is responsible for computing it. ≥2 → bugfix fallback.
viv_intent_detect() {
  local prompt="${1:-}"
  local branch="${2:-}"
  local keyword_count="${3:-0}"
  local hit

  # 1. Explicit Intent: marker in prompt — strongest signal.
  hit=$(viv_intent_from_prompt "$prompt")
  if [ -n "$hit" ]; then echo "$hit"; return 0; fi

  # 2. AIDLC_INTENT env (orchestrator-provided, normalized).
  if [ -n "${AIDLC_INTENT:-}" ]; then
    hit=$(viv_intent_normalize "$AIDLC_INTENT")
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi
  fi

  # 3. AIDLC_STEP_TYPE env.
  if [ -n "${AIDLC_STEP_TYPE:-}" ]; then
    hit=$(viv_intent_normalize "$AIDLC_STEP_TYPE")
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi
  fi

  # 4. Branch name.
  hit=$(viv_intent_from_branch "$branch")
  if [ -n "$hit" ]; then echo "$hit"; return 0; fi

  # 5. Textual heuristic — requires ≥2 keyword hits to count as "strong".
  if [ "${keyword_count:-0}" -ge 2 ] 2>/dev/null; then
    echo "bugfix"
    return 0
  fi

  # 6. Default.
  echo "unknown"
}
