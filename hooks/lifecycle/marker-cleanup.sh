#!/usr/bin/env bash
# PostToolUse hook for Agent — cleans up the subagent marker on completion.
#
# Strategy:
#   - Read tool_use_id (or session_id) from input as the stable identifier.
#   - Read the registered scope from hookSpecificInput.registered_scope (set by
#     pretooluse-agent.sh when it registered the marker). Fallback: walk up
#     from cwd to find the nearest marker dir.
#   - Call unregister_subagent (idempotent).
#
# Always exits 0 — cleanup failures should never block downstream chain.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/path-utils.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/marker-registry.sh"

INPUT=$(cat)

ID=$(echo "$INPUT" | jq -r '.tool_use_id // .session_id // ""')
[ -z "$ID" ] || [ "$ID" = "null" ] && exit 0

SCOPE=$(echo "$INPUT" | jq -r '.hookSpecificInput.registered_scope // .tool_input.registered_scope // ""')
if [ -z "$SCOPE" ] || [ "$SCOPE" = "null" ]; then
  # Fallback: walk up from cwd to find the marker.
  SESSION_CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
  [ -z "$SESSION_CWD" ] || [ "$SESSION_CWD" = "null" ] && SESSION_CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
  cur=$(canonicalize "$SESSION_CWD")
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/.claude/.subagent-active.json" ]; then
      SCOPE="$cur"
      break
    fi
    parent=$(dirname "$cur")
    [ "$parent" = "$cur" ] && break
    cur="$parent"
  done
fi

[ -z "$SCOPE" ] && exit 0

ERR_LOG="${TMPDIR:-/tmp}/posttooluse-unregister-error.log"
if ! unregister_subagent "$ID" "$SCOPE" 2>>"$ERR_LOG"; then
  echo "posttooluse-agent: unregister failed — ID=$ID SCOPE=$SCOPE (see $ERR_LOG)" >&2
fi
exit 0
