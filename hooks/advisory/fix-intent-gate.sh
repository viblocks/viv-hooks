#!/usr/bin/env bash
# PreToolUse Agent hook — fix-intent-gate (DENY type)
#
# Single Responsibility: when dispatching a typed implementer with a fix-shaped
# prompt, require a Root cause: token (per .claude/workflows/fix-intent-pattern.json).
#
# Rule source: fix-intent-pattern.json (per ADR-RD-005).
# Per ADR-002 in viv-workflows, intent_keywords are language-segmented arrays;
# this hook flattens them into a single OR-regex at runtime.
#
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

INPUT=$(cat)
SUBAGENT=$(echo "$INPUT" | jq -r '(.tool_input.subagent_type // "")')
PROMPT=$(echo "$INPUT" | jq -r '(.tool_input.prompt // "")')
[ -z "$SUBAGENT" ] && exit 0

AGENT_PATTERN=$(load_fix_intent_agent_pattern)
echo "$SUBAGENT" | grep -qE "$AGENT_PATTERN" || exit 0

# Build keyword regex from all language sets.
KEYWORDS=$(load_fix_intent_keywords | paste -sd'|' -)
[ -z "$KEYWORDS" ] && exit 0

if echo "$PROMPT" | grep -qiE "($KEYWORDS)"; then
  # Intent matches — check required tokens.
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
fi

exit 0
