#!/usr/bin/env bash
# PreToolUse Agent hook — fix-intent-gate (DENY type)
#
# Single Responsibility: when dispatching a typed implementer with a bugfix
# step, require a Root cause: / Causa raíz: token in the prompt.
#
# Per ADR-005 (intent-aware fix gate), the gate only fires when the step
# intent is confirmed to be bugfix (or hotfix/incident). For feature,
# refactor, docs, chore, and ambiguous prompts the hook passes through
# without enforcing the marker — see issue #2.
#
# Intent resolution (handled by lib/intent-detection.sh):
#   1. "Intent: <name>" line in prompt
#   2. AIDLC_INTENT env var
#   3. AIDLC_STEP_TYPE env var
#   4. Branch name prefix (feat/*, fix/*, ...)
#   5. ≥2 distinct fix-intent-pattern keyword matches in prompt
#   6. unknown → fail-open
#
# Rule source: fix-intent-pattern.json (per ADR-RD-005 + ADR-004).
# Modes:
#   disabled → bypass

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

MODE="${CLAUDE_HOOKS_MODE:-${AIDLC_ENFORCEMENT_MODE:-hard}}"
[ "$MODE" = "disabled" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/workflow-loader.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/intent-detection.sh"

INPUT=$(cat)
SUBAGENT=$(echo "$INPUT" | jq -r '(.tool_input.subagent_type // "")')
PROMPT=$(echo "$INPUT" | jq -r '(.tool_input.prompt // "")')
[ -z "$SUBAGENT" ] && exit 0

AGENT_PATTERN=$(load_fix_intent_agent_pattern)
echo "$SUBAGENT" | grep -qE "$AGENT_PATTERN" || exit 0

# Best-effort branch read; empty string when not in a git worktree.
CURRENT_BRANCH=""
if command -v git >/dev/null 2>&1; then
  # symbolic-ref works on empty repos (no commits yet) and returns empty
  # on detached HEAD — both correct for our purposes.
  CURRENT_BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" symbolic-ref --short HEAD 2>/dev/null || true)
fi

# Build keyword regex from all language sets — used for both the heuristic
# count AND to bound the gate scope (no keyword set → nothing to enforce).
KEYWORDS=$(load_fix_intent_keywords | paste -sd'|' -)
[ -z "$KEYWORDS" ] && exit 0

# Count distinct keyword matches in the prompt (passed to detector as the
# textual-heuristic input). grep -oiE returns one match per line; sort -u
# deduplicates so e.g. "fix fix fix" still counts as 1.
KEYWORD_HITS=$(printf '%s\n' "$PROMPT" \
  | grep -oiE "($KEYWORDS)" 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | sort -u \
  | grep -c . || true)

INTENT=$(viv_intent_detect "$PROMPT" "$CURRENT_BRANCH" "$KEYWORD_HITS")

# Only enforce on confirmed bugfix intent. Everything else (feature,
# refactor, docs, chore, unknown) passes through.
[ "$INTENT" = "bugfix" ] || exit 0

# Bugfix confirmed — require one of the Root cause tokens.
TOKENS=$(load_fix_intent_required_tokens)
satisfied=0
while IFS= read -r tok; do
  [ -z "$tok" ] && continue
  if echo "$PROMPT" | grep -qiF "$tok"; then
    satisfied=1
    break
  fi
done <<< "$TOKENS"
if [ "$satisfied" = "0" ]; then
  MSG=$(load_fix_intent_violation_message)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}' "$MSG"
  exit 2
fi

exit 0
