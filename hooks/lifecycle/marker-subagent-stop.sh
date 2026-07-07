#!/usr/bin/env bash
# SubagentStop hook — removes the subagent marker on ACTUAL completion.
#
# For background (async) Agent dispatch, PostToolUse fires at LAUNCH, so
# marker-cleanup.sh defers cleanup (it annotates the entry's agent_id instead of
# unregistering). SubagentStop is the real completion signal: its input carries
# `agent_id` == the PostToolUse tool_response.agentId that was annotated onto the
# marker entry. We remove that entry by agent_id here. See orchestrator#39.
#
# Always exits 0 — cleanup must never block the chain.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/path-utils.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/marker-registry.sh"

INPUT=$(cat)

AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
[ -z "$AGENT_ID" ] || [ "$AGENT_ID" = "null" ] && exit 0

# Resolve scope: walk up from cwd to the nearest marker dir (same pattern as the
# PostToolUse cleanup fallback).
SESSION_CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
[ -z "$SESSION_CWD" ] || [ "$SESSION_CWD" = "null" ] && SESSION_CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
cur=$(canonicalize "$SESSION_CWD")
SCOPE=""
while [ -n "$cur" ] && [ "$cur" != "/" ]; do
  if [ -f "$cur/.claude/.subagent-active.json" ]; then
    SCOPE="$cur"
    break
  fi
  parent=$(dirname "$cur")
  [ "$parent" = "$cur" ] && break
  cur="$parent"
done

[ -z "$SCOPE" ] && exit 0

ERR_LOG="${TMPDIR:-/tmp}/subagentstop-unregister-error.log"
if ! unregister_by_agent_id "$AGENT_ID" "$SCOPE" 2>>"$ERR_LOG"; then
  echo "subagentstop: unregister failed — agent_id=$AGENT_ID SCOPE=$SCOPE (see $ERR_LOG)" >&2
fi
exit 0
