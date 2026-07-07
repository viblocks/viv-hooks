#!/usr/bin/env bash
# tests/test-async-subagent-marker.test.sh
# TDD suite for the async subagent marker lifecycle (orchestrator#39).
# Grows one section per implementation task.
#
# Run from repo root:
#   bash tests/test-async-subagent-marker.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTER_HOOK="$REPO_ROOT/hooks/lifecycle/marker-register.sh"
CLEANUP_HOOK="$REPO_ROOT/hooks/lifecycle/marker-cleanup.sh"
SUBSTOP_HOOK="$REPO_ROOT/hooks/lifecycle/marker-subagent-stop.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# --- isolated fake repo (satisfies git rev-parse in the hooks) ---------------
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
FAKE_REPO="$TMP_ROOT/fake-repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q -b main 2>/dev/null \
  || { git -C "$FAKE_REPO" init -q; git -C "$FAKE_REPO" checkout -q -b main 2>/dev/null || true; }
SCOPE="$FAKE_REPO"
MARKER="$SCOPE/.claude/.subagent-active.json"

clean_marker() { rm -f "$MARKER"; }

# --- marker inspection helpers ----------------------------------------------
entry_field() {  # entry_field <id> <field>
  local id="$1" field="$2"
  [ -f "$MARKER" ] || { echo "MISSING_MARKER"; return; }
  jq -r --arg id "$id" --arg f "$field" \
    '.subagents[] | select(.id==$id) | .[$f] // "MISSING_FIELD"' "$MARKER"
}
entry_count() {  # entry_count <id>
  local id="$1"
  [ -f "$MARKER" ] || { echo 0; return; }
  jq --arg id "$id" '[.subagents[] | select(.id==$id)] | length' "$MARKER"
}

# =============================================================================
echo "--- Task 1: registry set_agent_id / unregister_by_agent_id ---"
source "$REPO_ROOT/lib/path-utils.sh"
source "$REPO_ROOT/lib/marker-registry.sh"

# set_agent_id annotates the matching entry, leaves others untouched.
clean_marker
register_subagent "id-A" "nestjs-crypto-implementer" "$SCOPE" "false" 1800
register_subagent "id-B" "reactjs-crypto-implementer" "$SCOPE" "false" 1800
set_agent_id "id-A" "agent-xyz" "$SCOPE"

if [ "$(entry_field id-A agent_id)" = "agent-xyz" ]; then
  ok "1a. set_agent_id annotates the matching entry"
else
  ko "1a. set_agent_id annotates the matching entry" "got '$(entry_field id-A agent_id)'"
fi
if [ "$(entry_field id-B agent_id)" = "MISSING_FIELD" ]; then
  ok "1b. set_agent_id leaves other entries untouched"
else
  ko "1b. set_agent_id leaves other entries untouched" "id-B got '$(entry_field id-B agent_id)'"
fi

# set_agent_id is idempotent (second call is a no-op success).
set_agent_id "id-A" "agent-xyz" "$SCOPE"
if [ "$(entry_field id-A agent_id)" = "agent-xyz" ]; then
  ok "1c. set_agent_id idempotent"
else
  ko "1c. set_agent_id idempotent" "got '$(entry_field id-A agent_id)'"
fi

# unregister_by_agent_id removes only the matching entry.
unregister_by_agent_id "agent-xyz" "$SCOPE"
if [ "$(entry_count id-A)" = "0" ] && [ "$(entry_count id-B)" = "1" ]; then
  ok "1d. unregister_by_agent_id removes only the matching entry"
else
  ko "1d. unregister_by_agent_id removes only the matching entry" \
     "id-A count=$(entry_count id-A) id-B count=$(entry_count id-B)"
fi

# entries WITHOUT agent_id are never removed by a non-matching agent_id.
unregister_by_agent_id "does-not-exist" "$SCOPE"
if [ "$(entry_count id-B)" = "1" ]; then
  ok "1e. unregister_by_agent_id keeps entries lacking agent_id"
else
  ko "1e. unregister_by_agent_id keeps entries lacking agent_id" "id-B count=$(entry_count id-B)"
fi

# removing the last entry deletes the marker file.
set_agent_id "id-B" "agent-b" "$SCOPE"
unregister_by_agent_id "agent-b" "$SCOPE"
if [ ! -f "$MARKER" ]; then
  ok "1f. unregister_by_agent_id removes marker file when empty"
else
  ko "1f. unregister_by_agent_id removes marker file when empty" "file still present"
fi


# =============================================================================
echo "--- Task 2: PostToolUse async-aware cleanup ---"

# Register via the real PreToolUse hook, then run the real PostToolUse cleanup.
register_via_hook() {  # register_via_hook <tool_use_id>
  local id="$1"
  local payload
  payload=$(jq -cn --arg id "$id" --arg cwd "$FAKE_REPO" \
    '{tool_name:"Agent", tool_use_id:$id,
      tool_input:{subagent_type:"nestjs-crypto-implementer",
                  prompt:"Intent: feature — add wallet endpoint"},
      cwd:$cwd}')
  env -i PATH="$PATH" HOME="$HOME" CLAUDE_HOOKS_MODE=disabled \
    ${VIV_MARKER_TTL_SECONDS:+VIV_MARKER_TTL_SECONDS="$VIV_MARKER_TTL_SECONDS"} \
    bash "$REGISTER_HOOK" <<< "$payload" >/dev/null 2>&1
}

cleanup_async() {  # cleanup_async <tool_use_id> <agentId>
  local id="$1" aid="$2"
  local payload
  payload=$(jq -cn --arg id "$id" --arg aid "$aid" --arg cwd "$FAKE_REPO" \
    '{tool_name:"Agent", tool_use_id:$id, cwd:$cwd,
      tool_response:{status:"async_launched", agentId:$aid}}')
  env -i PATH="$PATH" HOME="$HOME" CLAUDE_HOOKS_MODE=disabled \
    bash "$CLEANUP_HOOK" <<< "$payload" >/dev/null 2>&1
}

cleanup_sync() {  # cleanup_sync <tool_use_id>
  local id="$1"
  local payload
  payload=$(jq -cn --arg id "$id" --arg cwd "$FAKE_REPO" \
    '{tool_name:"Agent", tool_use_id:$id, cwd:$cwd,
      tool_response:"Done. Summary of the subagent run."}')
  env -i PATH="$PATH" HOME="$HOME" CLAUDE_HOOKS_MODE=disabled \
    bash "$CLEANUP_HOOK" <<< "$payload" >/dev/null 2>&1
}

# Async launch: marker MUST remain and be annotated with agentId.
clean_marker
register_via_hook "tu-async-1"
cleanup_async "tu-async-1" "agent-async-1"
if [ "$(entry_count tu-async-1)" = "1" ]; then
  ok "2a. async cleanup keeps the marker (no premature unregister)"
else
  ko "2a. async cleanup keeps the marker" "entry count=$(entry_count tu-async-1)"
fi
if [ "$(entry_field tu-async-1 agent_id)" = "agent-async-1" ]; then
  ok "2b. async cleanup annotates agent_id for later SubagentStop"
else
  ko "2b. async cleanup annotates agent_id" "got '$(entry_field tu-async-1 agent_id)'"
fi

# Sync completion: marker MUST be removed by tool_use_id (unchanged behavior).
clean_marker
register_via_hook "tu-sync-1"
cleanup_sync "tu-sync-1"
if [ "$(entry_count tu-sync-1)" = "0" ]; then
  ok "2c. sync cleanup unregisters by tool_use_id (unchanged)"
else
  ko "2c. sync cleanup unregisters by tool_use_id" "entry count=$(entry_count tu-sync-1)"
fi


# =============================================================================
echo "--- Task 3: SubagentStop hook removes by agent_id ---"

subagent_stop() {  # subagent_stop <agentId>
  local aid="$1"
  local payload
  payload=$(jq -cn --arg aid "$aid" --arg cwd "$FAKE_REPO" \
    '{hook_event_name:"SubagentStop", agent_id:$aid, cwd:$cwd}')
  env -i PATH="$PATH" HOME="$HOME" CLAUDE_HOOKS_MODE=disabled \
    bash "$SUBSTOP_HOOK" <<< "$payload" >/dev/null 2>&1
}

# Full async lifecycle: register → async cleanup (annotate) → SubagentStop (remove).
clean_marker
register_via_hook "tu-e2e-1"
cleanup_async "tu-e2e-1" "agent-e2e-1"
[ "$(entry_count tu-e2e-1)" = "1" ] \
  && ok "3a. marker present after async launch" \
  || ko "3a. marker present after async launch" "count=$(entry_count tu-e2e-1)"

subagent_stop "agent-e2e-1"
if [ "$(entry_count tu-e2e-1)" = "0" ]; then
  ok "3b. SubagentStop removes the marker by agent_id (async race fixed)"
else
  ko "3b. SubagentStop removes the marker by agent_id" "count=$(entry_count tu-e2e-1)"
fi

# SubagentStop for an unknown agent_id is a safe no-op (does not crash / non-zero).
clean_marker
register_via_hook "tu-e2e-2"
cleanup_async "tu-e2e-2" "agent-e2e-2"
subagent_stop "some-other-agent"
if [ "$(entry_count tu-e2e-2)" = "1" ]; then
  ok "3c. SubagentStop with unknown agent_id leaves the marker intact"
else
  ko "3c. SubagentStop with unknown agent_id leaves the marker intact" "count=$(entry_count tu-e2e-2)"
fi

# =============================================================================
echo "--- Task 4: crash-fallback (TTL purge still reclaims async markers) ---"

# Register an async marker with a 1-second TTL, never send SubagentStop, let it
# expire, then trigger a new registration → _purge_expired_subagents drops it.
clean_marker
VIV_MARKER_TTL_SECONDS=1 register_via_hook "tu-stale-1"
cleanup_async "tu-stale-1" "agent-stale-1"   # marker present, no SubagentStop
sleep 2
register_via_hook "tu-fresh-1"               # register hook purges expired first
if [ "$(entry_count tu-stale-1)" = "0" ] && [ "$(entry_count tu-fresh-1)" = "1" ]; then
  ok "4a. expired async marker is purged on next registration (crash-fallback)"
else
  ko "4a. expired async marker is purged on next registration" \
     "stale=$(entry_count tu-stale-1) fresh=$(entry_count tu-fresh-1)"
fi

echo ""
echo "Results: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
