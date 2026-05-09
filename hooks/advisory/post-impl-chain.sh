#!/usr/bin/env bash
# PostToolUse Agent hook — post-impl-chain advisor (ADVISORY type per ADR-RD-006)
#
# Single Responsibility: after a typed implementer completes, inject the
# post-implementation chain reminder so the orchestrator runs verification +
# domain review + (conditional) security review + commit.
#
# This hook does NOT block. It returns exit 0 with additionalContext that
# tells the LLM what to do next. Per ADR-RD-006, advisory hooks honor both
# `disabled` and `warn` modes (warn = allow with a softer message).
#
# Rule source: .claude/workflows/post-implementation-chain.json (per ADR-RD-005).

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
[ -z "$SUBAGENT" ] && exit 0

CHAIN_FILE=$(resolve_workflow_file "post-implementation-chain.json")
[ -z "$CHAIN_FILE" ] && exit 0

AGENT_PATTERN=$(jq -r '.trigger.agent_type_pattern' "$CHAIN_FILE")
echo "$SUBAGENT" | grep -qE "$AGENT_PATTERN" || exit 0

# Build the advisory message: list the stages.
STAGES=$(jq -r '.stages[] | "  - \(.id) (\(.kind))"' "$CHAIN_FILE")

MSG="POST-IMPL CHAIN (after $SUBAGENT): execute the following stages in order before committing:"$'\n'"$STAGES"$'\n''Format the Post-Chain Output per CLAUDE.md before any commit. See .claude/workflows/post-implementation-chain.json.'

jq -cn --arg msg "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$msg}}'
exit 0
