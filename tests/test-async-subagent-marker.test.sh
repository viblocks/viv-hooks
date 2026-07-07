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

echo ""
echo "Results: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
