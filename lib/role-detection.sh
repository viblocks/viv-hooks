#!/usr/bin/env bash
# lib/role-detection.sh — single source of truth for hook role detection.
#
# Replaces the broken cwd-based heuristic in pretooluse-path-policy.sh with a
# marker-file registry that supports concurrent subagents and survives main
# sessions running inside worktrees (the bug fix).
#
# Signal precedence:
#   1. CLAUDE_HOOK_ROLE env var — ONLY honored when CLAUDE_HOOK_TEST=1 (testing
#      escape hatch). HIGH-A: in production this var is ignored to prevent
#      attackers from spoofing role=subagent and bypassing routing enforcement.
#   2. Marker file walk-up from cwd: nearest ancestor containing
#      .claude/.subagent-active.json with at least one fresh entry → subagent
#   3. Default: main (fail-safe — false positives only block writes, never
#      grant escalation)
#
# Required dependencies (caller must source first):
#   - lib/path-utils.sh (canonicalize, is_under)
#   - lib/marker-registry.sh (list_active_subagents)

# detect_role : echoes "main" or "subagent"
#
# HIGH-A: env var override is ONLY honored when CLAUDE_HOOK_TEST=1. This
# prevents an attacker from spoofing CLAUDE_HOOK_ROLE=subagent to bypass
# routing enforcement from the main session. The marker file is the sole
# capability token in normal operation.
detect_role() {
  if [ "${CLAUDE_HOOK_TEST:-}" = "1" ]; then
    local override="${CLAUDE_HOOK_ROLE:-}"
    case "$override" in
      main|subagent) echo "$override"; return ;;
    esac
  fi
  local scope
  scope=$(_walk_up_for_scope)
  if [ -n "$scope" ]; then
    echo "subagent"
  else
    echo "main"
  fi
}

# detect_subagent_scope : echoes confinement scope path or empty.
#
# HIGH-A: env var override is ONLY honored when CLAUDE_HOOK_TEST=1.
detect_subagent_scope() {
  if [ "${CLAUDE_HOOK_TEST:-}" = "1" ]; then
    local override="${CLAUDE_HOOK_ROLE:-}"
    if [ "$override" = "main" ]; then
      echo ""
      return
    fi
    if [ "$override" = "subagent" ] && [ -n "${CLAUDE_HOOK_SCOPE:-}" ]; then
      echo "$CLAUDE_HOOK_SCOPE"
      return
    fi
  fi
  _walk_up_for_scope
}

# detect_allow_self_mod : echoes "true" only if ALL active subagent entries
# in scope have allow_self_mod=true. With zero active entries, returns "false"
# (no bypass for main).
detect_allow_self_mod() {
  local scope
  scope=$(detect_subagent_scope)
  [ -z "$scope" ] && { echo "false"; return; }
  local list
  list=$(list_active_subagents "$scope")
  local len
  len=$(echo "$list" | jq 'length')
  if [ "$len" = "0" ] || [ -z "$len" ]; then
    echo "false"; return
  fi
  # All must be true: count entries where allow_self_mod != true.
  local violators
  violators=$(echo "$list" | jq '[.[] | select(.allow_self_mod != true)] | length')
  if [ "$violators" = "0" ]; then
    echo "true"
  else
    echo "false"
  fi
}

# Internal: walk up from current PWD looking for a marker dir with fresh
# entries. Echoes the scope (directory containing .claude/.subagent-active.json)
# or empty.
_walk_up_for_scope() {
  local start
  start=$(canonicalize "$PWD")
  [ -z "$start" ] && start="$PWD"
  local cur="$start"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    local marker="$cur/.claude/.subagent-active.json"
    if [ -f "$marker" ]; then
      local fresh_count
      fresh_count=$(list_active_subagents "$cur" | jq 'length' 2>/dev/null || echo 0)
      if [ -n "$fresh_count" ] && [ "$fresh_count" -gt 0 ]; then
        echo "$cur"
        return
      fi
    fi
    local parent
    parent=$(dirname "$cur")
    [ "$parent" = "$cur" ] && break
    cur="$parent"
  done
  echo ""
}
