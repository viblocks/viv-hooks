#!/usr/bin/env bash
# PreToolUse hook — audit-trail-gate (DENY type per ADR-RD-006)
#
# Single Responsibility: enforce a commit-message trailer policy on Class A
# commits. The trailer name and value pattern come from
# .claude/workflows/audit-trail-pattern.json (per ADR-RD-005). Class A status
# is derived from routing-table.json (per ADR-RD-004).
#
# Conservative: only validates when at least one staged path is Class A.
# Pure Class B commits pass through.
#
# Editor-mode policy (commit without -m/-F) comes from the rule file:
#   block (default) → blocked when Class A staged
#   warn            → log but allow
#   allow           → permitted
#
# Modes (CLAUDE_HOOKS_MODE; legacy AIDLC_ENFORCEMENT_MODE honored):
#   disabled → bypass
#   any other value → enforce (warn NOT honored for deny hooks; ADR-RD-006)

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

MODE="${CLAUDE_HOOKS_MODE:-${AIDLC_ENFORCEMENT_MODE:-hard}}"
[ "$MODE" = "disabled" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/path-utils.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/routing-loader.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/workflow-loader.sh"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only process git commit commands.
echo "$CMD" | grep -qE '^git commit(\s|$)' || exit 0

# Resolve the trailer rule.
TRAILER_NAME=$(load_audit_trail_trailer_name)
TRAILER_PATTERN=$(load_audit_trail_value_pattern)
EDITOR_POLICY=$(load_audit_trail_editor_policy)

# If no rule file resolved, the hook is inert. No silent bypass — log and exit
# 0 (a missing contract is a configuration error, not a commit violation).
if [ -z "$TRAILER_NAME" ] || [ -z "$TRAILER_PATTERN" ]; then
  echo "WARN: no audit-trail-pattern.json resolved — audit-trail-gate is inert" >&2
  exit 0
fi

# Determine staged paths (-a/--all expands to working-tree diff).
if echo "$CMD" | grep -qE '\s(-a|--all)(\s|$)'; then
  DIFF_CMD="git diff --name-only HEAD"
else
  DIFF_CMD="git diff --cached --name-only"
fi
PATHS=$($DIFF_CMD 2>/dev/null || echo "")

# Build Class A pattern array from routing-table.
CLASS_A_PATTERNS=()
load_class_a_patterns_array CLASS_A_PATTERNS
if [ "${#CLASS_A_PATTERNS[@]}" -eq 0 ]; then
  echo "WARN: no enforced routes in routing-table.json — audit-trail-gate cannot determine Class A scope" >&2
  exit 0
fi

# Identify Class A staged paths.
CLASS_A_PATHS=""
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if is_class_a "$p" "${CLASS_A_PATTERNS[@]}"; then
    CLASS_A_PATHS="$CLASS_A_PATHS $p"
  fi
done <<< "$PATHS"

# Pure Class B commit → allow.
if [ -z "$(echo "$CLASS_A_PATHS" | tr -d '[:space:]')" ]; then
  exit 0
fi

# Editor-mode check: -m/-F required when Class A staged (default policy).
if ! echo "$CMD" | grep -qE '(\s-m\s|\s-m"|\s-m'"'"'|\s--message[= ]|\s-F\s|\s--file[= ])'; then
  case "$EDITOR_POLICY" in
    allow) : ;;  # explicitly allowed by rule
    warn)
      echo "WARN: editor-mode commit on Class A paths (audit-trail-pattern policy=warn):$CLASS_A_PATHS" >&2
      ;;
    block|*)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"COMMIT GATE: Class A files staged (%s). Must use -m/--message or -F/--file to enable %s trailer validation. Editor-mode commits bypass trailer check and are blocked for Class A paths."}}' "$(echo "$CLASS_A_PATHS" | tr -s ' ')" "$TRAILER_NAME"
      exit 2
      ;;
  esac
fi

# Extract commit message from -m "..." / -m '...' / -F file (best-effort).
MSG=$(echo "$CMD" | python3 -c "
import sys, re
cmd = sys.stdin.read()
m = re.search(r'-m\s+[\"\'](.*?)[\"\']', cmd, re.DOTALL)
if m:
    print(m.group(1))
" 2>/dev/null || true)

# If -F file used, read file. (-F path may need expansion; best-effort.)
if [ -z "$MSG" ]; then
  F_FILE=$(echo "$CMD" | grep -oE '(-F|--file[= ])[[:space:]]*[^[:space:]]+' | tail -n1 | sed -E 's/^(-F|--file[= ])[[:space:]]*//')
  if [ -n "$F_FILE" ] && [ -f "$F_FILE" ]; then
    MSG=$(cat "$F_FILE")
  fi
fi

# Validate trailer.
TRAILER_REGEX="${TRAILER_NAME}:[[:space:]]*${TRAILER_PATTERN}"
# value_pattern from JSON may include anchors (^...$); strip them for embed.
TRAILER_REGEX_STRIPPED=$(echo "$TRAILER_REGEX" | sed -E 's/\^//g; s/\$//g')

if ! echo "$MSG" | grep -qE "$TRAILER_REGEX_STRIPPED"; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"COMMIT GATE: Missing %s trailer for Class A commit. Required value pattern: %s. Staged Class A paths:%s"}}' "$TRAILER_NAME" "$TRAILER_PATTERN" "$(echo "$CLASS_A_PATHS" | tr -s ' ')"
  exit 2
fi

exit 0
