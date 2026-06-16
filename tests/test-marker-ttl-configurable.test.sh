#!/usr/bin/env bash
# tests/test-marker-ttl-configurable.test.sh
# TDD test for configurable marker TTL (VIV_MARKER_TTL_SECONDS).
#
# Regression: marker-register.sh hardcoded TTL=600 instead of the library
# default of 1800, causing mid-task IMPLEMENTER BLOCKED in consumers.
# See: https://github.com/viblocks/viv-hooks — fix/configurable-marker-ttl
#
# Run from repo root:
#   bash tests/test-marker-ttl-configurable.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/lifecycle/marker-register.sh"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# Set up an isolated git repo to satisfy marker-register.sh's git rev-parse calls.
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

FAKE_REPO="$TMP_ROOT/fake-repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q -b main 2>/dev/null \
  || { git -C "$FAKE_REPO" init -q; git -C "$FAKE_REPO" checkout -q -b main 2>/dev/null || true; }

# Build a minimal Agent PreToolUse payload for an implementer.
# The hook reads: .tool_input.subagent_type, .tool_input.prompt, .tool_use_id, .cwd
make_payload() {
  local tool_use_id="$1"
  jq -cn \
    --arg id   "$tool_use_id" \
    --arg sa   "nestjs-crypto-implementer" \
    --arg p    "Intent: feature — add wallet endpoint" \
    --arg cwd  "$FAKE_REPO" \
    '{tool_name:"Agent", tool_use_id:$id,
      tool_input:{subagent_type:$sa, prompt:$p},
      cwd:$cwd}'
}

# run_hook [env_vars...] — pipe payload into hook, return exit code.
# Sets CLAUDE_HOOKS_MODE=disabled so routing enforcement is skipped;
# we only want to exercise the marker-registration path.
run_hook() {
  local tool_use_id="$1"; shift
  local payload; payload=$(make_payload "$tool_use_id")
  # shellcheck disable=SC2086
  env -i PATH="$PATH" HOME="$HOME" \
      CLAUDE_HOOKS_MODE=disabled \
      "$@" \
      bash "$HOOK" <<< "$payload" >/dev/null 2>&1
}

# get_ttl <scope> <id> — read ttl_seconds from the marker file.
get_ttl() {
  local scope="$1" id="$2"
  local marker="$scope/.claude/.subagent-active.json"
  if [ ! -f "$marker" ]; then echo "MISSING_MARKER"; return; fi
  jq -r --arg id "$id" '.subagents[] | select(.id==$id) | .ttl_seconds // "MISSING_TTL"' "$marker"
}

# Derive the scope the hook will use: git-common-dir parent (= FAKE_REPO itself
# since it is a plain main-worktree repo).
SCOPE="$FAKE_REPO"

echo "--- Marker TTL tests ---"

# --- Case 1: No VIV_MARKER_TTL_SECONDS → must default to 1800 (RED today) ---
TOOL_USE_ID_1="test-ttl-default-$(date +%s)"
rm -f "$SCOPE/.claude/.subagent-active.json"  # start clean

run_hook "$TOOL_USE_ID_1"
actual_ttl=$(get_ttl "$SCOPE" "$TOOL_USE_ID_1")

if [ "$actual_ttl" = "1800" ]; then
  ok "1. No VIV_MARKER_TTL_SECONDS → ttl_seconds defaults to 1800 (got $actual_ttl)"
else
  ko "1. No VIV_MARKER_TTL_SECONDS → expected 1800" "got '$actual_ttl' (currently hardcoded 600)"
fi

# --- Case 2: VIV_MARKER_TTL_SECONDS=3600 → marker must use 3600 ---
TOOL_USE_ID_2="test-ttl-custom-$(date +%s)-2"
rm -f "$SCOPE/.claude/.subagent-active.json"

run_hook "$TOOL_USE_ID_2" VIV_MARKER_TTL_SECONDS=3600
actual_ttl_custom=$(get_ttl "$SCOPE" "$TOOL_USE_ID_2")

if [ "$actual_ttl_custom" = "3600" ]; then
  ok "2. VIV_MARKER_TTL_SECONDS=3600 → ttl_seconds is 3600 (got $actual_ttl_custom)"
else
  ko "2. VIV_MARKER_TTL_SECONDS=3600 → expected 3600" "got '$actual_ttl_custom'"
fi

# --- Case 3: Marker file is actually written (sanity) ---
TOOL_USE_ID_3="test-ttl-written-$(date +%s)-3"
rm -f "$SCOPE/.claude/.subagent-active.json"

run_hook "$TOOL_USE_ID_3"
marker_file="$SCOPE/.claude/.subagent-active.json"

if [ -f "$marker_file" ]; then
  ok "3. Marker file is written at expected path"
else
  ko "3. Marker file is written" "file not found: $marker_file"
fi

echo ""
echo "Results: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
