#!/usr/bin/env bash
# PreToolUse Bash hook — evidence-gate (DENY type, despite location in advisory/)
#
# Single Responsibility: enforce required evidence markers when an issue is
# closed via the configured tracker CLI.
#
# Rule source: .claude/workflows/evidence-schema.json (per ADR-RD-005).
# Trigger pattern + required_fields + validations come from that file.
#
# This hook is conceptually a deny (blocks the close action) but it consumes
# a workflow rule to know WHAT to require. To keep the deny/advisory taxonomy
# clean, the file lives in advisory/ where it can be wired alongside the
# other rule-driven hooks; it still emits exit 2 on violation.
#
# Modes (CLAUDE_HOOKS_MODE; legacy AIDLC_ENFORCEMENT_MODE honored):
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
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && exit 0

RULE=$(resolve_workflow_file "evidence-schema.json")
[ -z "$RULE" ] && { echo "WARN: no evidence-schema.json resolved — evidence-gate inert" >&2; exit 0; }

TRIGGER=$(jq -r '.trigger.bash_command_pattern' "$RULE")
[ -z "$TRIGGER" ] && exit 0

# Only fire when command matches the trigger.
echo "$CMD" | grep -qE "$TRIGGER" || exit 0

# Extract the close-comment text. Convention: --comment <text> | --body <text>.
COMMENT=$(echo "$CMD" | sed -nE 's/.*--(comment|body)[= ]+("([^"]*)"|'\''([^'\'']*)'\''|([^[:space:]]+)).*/\3\4\5/p')

# Check required markers.
MISSING=""
while IFS= read -r marker; do
  [ -z "$marker" ] && continue
  if ! echo "$COMMENT" | grep -qF "$marker"; then
    MISSING="$MISSING $marker"
  fi
done < <(jq -r '.required_fields[].marker' "$RULE")

if [ -n "$MISSING" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"EVIDENCE GATE: missing required markers in close comment:%s"}}' "$MISSING"
  exit 2
fi

# Apply validations (e.g. N/A justification).
VIOLATION=""
while IFS= read -r vrow; do
  [ -z "$vrow" ] && continue
  marker=$(echo "$vrow" | jq -r '.applies_to_marker')
  rule_text=$(echo "$vrow" | jq -r '.rule')
  msg=$(echo "$vrow" | jq -r '.violation_message')
  # Generic implementation for the canonical N/A-needs-justification rule.
  # Other rule types: log-and-skip (extension point).
  case "$rule_text" in
    *"N/A"*"justification"*|*"' -- '"*)
      value=$(echo "$COMMENT" | sed -nE "s|.*${marker}[: ]+([^\\n]*).*|\1|p")
      if echo "$value" | grep -qiE 'N/A' && ! echo "$value" | grep -q ' -- '; then
        VIOLATION="$msg"
        break
      fi
      ;;
  esac
done < <(jq -c '(.validations // [])[]' "$RULE")

if [ -n "$VIOLATION" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}' "$VIOLATION"
  exit 2
fi

exit 0
