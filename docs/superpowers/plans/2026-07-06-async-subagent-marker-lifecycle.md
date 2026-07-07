# Async Subagent Marker Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the subagent routing marker from being revoked mid-run under background (async) Agent dispatch, by tying marker cleanup to the real completion event (`SubagentStop`) instead of the tool-call return (`PostToolUse`, which fires at launch for background agents).

**Architecture:** Hybrid cleanup. The synchronous path is unchanged: `PostToolUse:Agent` still unregisters by `tool_use_id` when the tool actually completed. The asynchronous path is new: when `PostToolUse` reports `tool_response.status == "async_launched"`, cleanup is skipped and the marker entry is annotated with the harness `agentId`; a new `SubagentStop` hook then removes that entry by `agent_id` at real completion. Bounded TTL (already present) is retained purely as a crash-fallback.

**Tech Stack:** POSIX bash, `jq`, `flock`/mkdir-mutex file locking. Tests are standalone bash scripts (no framework) following the existing `tests/*.test.sh` pattern.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-06-async-subagent-marker-lifecycle-design.md`. Fixes `viblocks/viv-aidlc-orchestrator#39`.
- Branch: `fix/async-subagent-marker-lifecycle` (already based on `origin/main` = `bd6a915`, which includes the marker-TTL fix).
- Async detection MUST use `tool_response.status == "async_launched"` — NEVER `tool_input.run_in_background` (the harness backgrounds dispatches even without the flag).
- Correlation dispatch→completion is by `agentId` (PostToolUse `tool_response.agentId` == SubagentStop `agent_id`). `tool_use_id` is NOT available in `SubagentStop`.
- All lifecycle hooks MUST always `exit 0` — cleanup failures must never block the tool chain.
- Removing a marker only ever tightens enforcement (can make `role=main`, never grants escalation). Preserve this invariant: no self-register from agents; `CLAUDE_HOOK_ROLE`/`CLAUDE_HOOK_SCOPE` honored only under `CLAUDE_HOOK_TEST=1`.
- Preserve existing public registry contract: `register_subagent`, `unregister_subagent`, `list_active_subagents`, `_purge_expired_subagents` signatures unchanged.
- Run tests from repo root: `bash tests/<file>.test.sh`. Existing suites (`tests/smoke.test.sh`, `tests/test-marker-ttl-configurable.test.sh`) must keep passing.
- Marker file: `<scope>/.claude/.subagent-active.json`; entry schema is `{id, agent_type, dispatched_at, ttl_seconds, allow_self_mod, scope}` — this plan adds an optional `agent_id`.

---

## File Structure

- Modify `lib/marker-registry.sh` — add `set_agent_id` and `unregister_by_agent_id` (the only two new registry primitives; both consumed by the hooks below).
- Modify `hooks/lifecycle/marker-cleanup.sh` — branch on `async_launched`: annotate instead of unregister.
- Create `hooks/lifecycle/marker-subagent-stop.sh` — new `SubagentStop` hook; unregisters by `agent_id`.
- Modify `settings.json.fragment` — wire the `SubagentStop` hook.
- Create `tests/test-async-subagent-marker.test.sh` — the TDD suite; grows one section per task.

---

## Task 1: Registry primitives — `set_agent_id` + `unregister_by_agent_id`

**Files:**
- Modify: `lib/marker-registry.sh` (append after `unregister_subagent`, ~line 135)
- Test: `tests/test-async-subagent-marker.test.sh` (create)

**Interfaces:**
- Consumes: existing `register_subagent`, `_with_lock`, `_marker_path` from `lib/marker-registry.sh`.
- Produces:
  - `set_agent_id <id> <agent_id> <scope>` — annotates the entry whose `.id == <id>` with `.agent_id = <agent_id>`. Idempotent; no-op if marker file or entry absent. Returns 0.
  - `unregister_by_agent_id <agent_id> <scope>` — removes the entry whose `.agent_id == <agent_id>`; removes the marker file when the array empties. Entries without `agent_id` are left untouched. Idempotent. Returns 0.

- [ ] **Step 1: Write the failing test (create the suite + Task 1 cases)**

Create `tests/test-async-subagent-marker.test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-async-subagent-marker.test.sh`
Expected: FAIL — `set_agent_id: command not found` / `unregister_by_agent_id: command not found`, tests 1a–1f fail.

- [ ] **Step 3: Implement the two registry functions**

In `lib/marker-registry.sh`, insert after `unregister_subagent()` closes (after the current `}` at ~line 135, before `list_active_subagents`):

```bash
# set_agent_id <id> <agent_id> <scope>
# Annotates the entry matching <id> (the tool_use_id used at register time) with
# the harness subagent <agent_id> (from PostToolUse tool_response.agentId), so the
# SubagentStop hook can correlate real completion → entry for background dispatch.
# Idempotent: no-op if marker file or entry is absent.
set_agent_id() {
  local id="$1" agent_id="$2" scope="$3"
  local marker; marker=$(_marker_path "$scope")
  [ -f "$marker" ] || return 0
  _with_lock "$scope" bash -c '
    marker="$1"; id="$2"; agent_id="$3"
    [ -f "$marker" ] || exit 0
    jq --arg id "$id" --arg aid "$agent_id" \
      ".subagents |= map(if .id == \$id then .agent_id = \$aid else . end)" \
      "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
  ' _ "$marker" "$id" "$agent_id"
}

# unregister_by_agent_id <agent_id> <scope>
# Removes the entry whose agent_id matches (SubagentStop carries agent_id, not
# tool_use_id). Entries without an agent_id are left untouched. Idempotent;
# empty subagents array → marker file removed. Mirrors unregister_subagent.
unregister_by_agent_id() {
  local agent_id="$1" scope="$2"
  local marker; marker=$(_marker_path "$scope")
  [ -f "$marker" ] || return 0
  _with_lock "$scope" bash -c '
    marker="$1"; aid="$2"
    [ -f "$marker" ] || exit 0
    jq --arg aid "$aid" ".subagents |= map(select(.agent_id != \$aid))" \
      "$marker" > "$marker.tmp" && mv "$marker.tmp" "$marker"
    if [ "$(jq ".subagents | length" "$marker")" = "0" ]; then
      rm -f "$marker"
    fi
  ' _ "$marker" "$agent_id"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-async-subagent-marker.test.sh`
Expected: PASS — `Results: 6 pass, 0 fail`.

- [ ] **Step 5: Commit**

```bash
git add lib/marker-registry.sh tests/test-async-subagent-marker.test.sh
git commit -m "feat(registry): agent_id annotate + unregister-by-agent_id (orchestrator#39)"
```

---

## Task 2: Async-aware `PostToolUse` cleanup

**Files:**
- Modify: `hooks/lifecycle/marker-cleanup.sh` (replace the unregister block, current lines 48-52)
- Test: `tests/test-async-subagent-marker.test.sh` (add Task 2 section)

**Interfaces:**
- Consumes: `register_subagent` (via the register hook), `set_agent_id` / `unregister_subagent` from Task 1 / existing.
- Produces: no new functions. Behavior contract — `marker-cleanup.sh` given `tool_response.status == "async_launched"` annotates the entry's `agent_id` and leaves the marker present; given any other `tool_response`, unregisters by `tool_use_id` (unchanged).

- [ ] **Step 1: Write the failing test (add before the final Results block)**

Insert this section into `tests/test-async-subagent-marker.test.sh`, immediately before the closing `echo ""` / `Results` lines:

```bash
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
```

- [ ] **Step 2: Run test to verify the new cases fail**

Run: `bash tests/test-async-subagent-marker.test.sh`
Expected: FAIL — case 2a/2b fail (current cleanup unconditionally unregisters, so the marker is gone and agent_id is never set). Case 2c passes. Tasks 1a–1f still pass.

- [ ] **Step 3: Implement the async branch**

In `hooks/lifecycle/marker-cleanup.sh`, replace the final block (current lines 48-52):

```bash
ERR_LOG="${TMPDIR:-/tmp}/posttooluse-unregister-error.log"
if ! unregister_subagent "$ID" "$SCOPE" 2>>"$ERR_LOG"; then
  echo "posttooluse-agent: unregister failed — ID=$ID SCOPE=$SCOPE (see $ERR_LOG)" >&2
fi
exit 0
```

with:

```bash
ERR_LOG="${TMPDIR:-/tmp}/posttooluse-unregister-error.log"

# Async (background) dispatch: PostToolUse fires at LAUNCH, not completion, so
# the subagent is still running and MUST keep its marker. Detect via the
# tool_response async signature (NOT tool_input.run_in_background, which the
# harness may omit while still backgrounding). Annotate the entry with the
# harness agentId so SubagentStop can remove it at real completion. See
# orchestrator#39.
STATUS=$(echo "$INPUT" | jq -r '.tool_response.status // ""')
if [ "$STATUS" = "async_launched" ]; then
  AGENT_ID=$(echo "$INPUT" | jq -r '.tool_response.agentId // ""')
  if [ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "null" ]; then
    set_agent_id "$ID" "$AGENT_ID" "$SCOPE" 2>>"$ERR_LOG" || true
  fi
  exit 0
fi

# Synchronous completion: the tool returned after the subagent finished, so
# unregister by tool_use_id — unchanged behavior.
if ! unregister_subagent "$ID" "$SCOPE" 2>>"$ERR_LOG"; then
  echo "posttooluse-agent: unregister failed — ID=$ID SCOPE=$SCOPE (see $ERR_LOG)" >&2
fi
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-async-subagent-marker.test.sh`
Expected: PASS — `Results: 9 pass, 0 fail`.

- [ ] **Step 5: Commit**

```bash
git add hooks/lifecycle/marker-cleanup.sh tests/test-async-subagent-marker.test.sh
git commit -m "fix(marker-cleanup): skip unregister on async launch, annotate agentId (orchestrator#39)"
```

---

## Task 3: `SubagentStop` hook + wiring

**Files:**
- Create: `hooks/lifecycle/marker-subagent-stop.sh`
- Modify: `settings.json.fragment` (add `SubagentStop` entry)
- Test: `tests/test-async-subagent-marker.test.sh` (add Task 3 section)

**Interfaces:**
- Consumes: `unregister_by_agent_id` (Task 1); `canonicalize` from `lib/path-utils.sh`.
- Produces: a `SubagentStop` hook that reads `.agent_id` and `.cwd`, resolves scope by walking up to the marker dir, and calls `unregister_by_agent_id`. Always exits 0.

- [ ] **Step 1: Write the failing test (add before the final Results block)**

Insert into `tests/test-async-subagent-marker.test.sh`, before the closing Results lines:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-async-subagent-marker.test.sh`
Expected: FAIL — `SUBSTOP_HOOK` file does not exist, so `bash "$SUBSTOP_HOOK"` errors; case 3b fails (marker not removed). Tasks 1 & 2 still pass.

- [ ] **Step 3: Create the SubagentStop hook**

Create `hooks/lifecycle/marker-subagent-stop.sh`:

```bash
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
```

- [ ] **Step 4: Wire the hook in `settings.json.fragment`**

In `settings.json.fragment`, add a top-level `SubagentStop` key inside `"hooks"` (a sibling of `PreToolUse` / `PostToolUse`). `SubagentStop` is not a tool event, so it takes no `matcher`:

```json
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ./.claude/hooks/lifecycle/marker-subagent-stop.sh"
          }
        ]
      }
    ]
```

- [ ] **Step 5: Run tests to verify pass (feature suite + smoke)**

Run: `bash tests/test-async-subagent-marker.test.sh`
Expected: PASS — `Results: 12 pass, 0 fail`.

Run: `bash tests/smoke.test.sh`
Expected: PASS — the new hook passes `bash -n` syntax and disabled-mode checks; `settings.json.fragment` still parses as JSON.

- [ ] **Step 6: Commit**

```bash
git add hooks/lifecycle/marker-subagent-stop.sh settings.json.fragment tests/test-async-subagent-marker.test.sh
git commit -m "feat(subagentstop): remove marker at real completion via agent_id (orchestrator#39)"
```

---

## Task 4: Full-suite regression + empirical live verification

**Files:**
- Modify: `tests/test-async-subagent-marker.test.sh` (add the crash-fallback case)
- Verify only: `tests/smoke.test.sh`, `tests/test-marker-ttl-configurable.test.sh`

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: the crash-fallback regression case; a documented live-verification result recorded on the PR.

- [ ] **Step 1: Write the crash-fallback test (add before the final Results block)**

The async marker must still be reclaimable if `SubagentStop` never fires (crash): `_purge_expired_subagents` on the next registration drops it once its TTL elapses. Insert:

```bash
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
```

Note: `register_via_hook` sets `env -i` and does not currently forward `VIV_MARKER_TTL_SECONDS`. Update its `env -i` line in the Task 2 helper to forward it:

```bash
  env -i PATH="$PATH" HOME="$HOME" CLAUDE_HOOKS_MODE=disabled \
    ${VIV_MARKER_TTL_SECONDS:+VIV_MARKER_TTL_SECONDS="$VIV_MARKER_TTL_SECONDS"} \
    bash "$REGISTER_HOOK" <<< "$payload" >/dev/null 2>&1
```

- [ ] **Step 2: Run the full feature suite**

Run: `bash tests/test-async-subagent-marker.test.sh`
Expected: PASS — `Results: 13 pass, 0 fail`.

- [ ] **Step 3: Run the whole repo test set (no regressions)**

Run: `bash tests/smoke.test.sh && bash tests/test-marker-ttl-configurable.test.sh && bash tests/test-async-subagent-marker.test.sh`
Expected: all three suites end with `0 fail` / non-zero-free exit.

- [ ] **Step 4: Empirical live verification (the one non-contractual assumption)**

This confirms `SubagentStop.agent_id == PostToolUse.agentId` for a real background dispatch — the only fact the docs do not contractually guarantee.

In a real Claude Code session that has these hooks installed (e.g. a scratch repo or the `viblocks-waas` consumer after a dev install), with a typed implementer configured:

1. Temporarily add a debug line to each of `marker-cleanup.sh` (async branch) and `marker-subagent-stop.sh` that appends the observed id to a log, e.g.:
   `echo "POSTTOOL agentId=$AGENT_ID id=$ID" >> "${TMPDIR:-/tmp}/marker-trace.log"` and
   `echo "SUBSTOP agent_id=$AGENT_ID scope=$SCOPE" >> "${TMPDIR:-/tmp}/marker-trace.log"`.
2. Dispatch a typed implementer that performs a Class A edit (e.g. touch a file under `services/**`) — do NOT pass `run_in_background`; let the harness background it.
3. Confirm from `marker-trace.log` that the `SUBSTOP agent_id` equals the `POSTTOOL agentId`, and that the Class A edit was **allowed** (no `BLOCKED (routing)` from `enforce-routing.sh`) while the marker was present.
4. Confirm the marker file is gone after completion.
5. Remove the debug lines.

Record the observed ids and the pass/fail on the PR description.

Expected: `agent_id` values match; Class A edit succeeds under async dispatch; marker cleaned at completion.

- [ ] **Step 5: Commit and open PR**

```bash
git add tests/test-async-subagent-marker.test.sh
git commit -m "test(marker): crash-fallback purge for un-stopped async markers (orchestrator#39)"
git push -u origin fix/async-subagent-marker-lifecycle
gh pr create --repo viblocks/viv-hooks --base main \
  --title "fix: async subagent marker lifecycle — SubagentStop cleanup (orchestrator#39)" \
  --body "See docs/superpowers/specs/2026-07-06-async-subagent-marker-lifecycle-design.md. Include the live-verification agent_id trace from Task 4 Step 4 here."
```

If the empirical check in Step 4 shows `SubagentStop.agent_id` does NOT match the PostToolUse `agentId`, STOP and revisit correlation (fallback: correlate on a stable field the harness does expose, or key the annotation differently) before merging — do not ship on the TTL fallback alone.

---

## Post-merge propagation (out of scope for this branch; tracked for release)

The new hook file + `SubagentStop` wiring reach consumers only via the release chain: bump the `viv-hooks` pin in the `viv-typed-agents` MANIFEST, then bump `TA_SHA` + version in `viv-aidlc-orchestrator`, then upgrade consumers (e.g. `viblocks-waas`). File these as the release follow-up once this PR merges.

---

## Self-Review

**Spec coverage:**
- Async skip + agentId annotate at PostToolUse → Task 2 ✅
- SubagentStop cleanup by agent_id → Task 3 ✅
- `set_agent_id` / `unregister_by_agent_id` registry primitives → Task 1 ✅
- settings.json.fragment SubagentStop wiring → Task 3 Step 4 ✅
- Sync path unchanged → Task 2 case 2c ✅
- Crash fallback / bounded TTL retained → Task 4 case 4a ✅
- Empirical agent_id correlation check → Task 4 Step 4 ✅
- Security invariants (no self-register, tighten-only) → preserved; no changes to `role-detection.sh` / `enforce-routing.sh`; annotation written by trusted hook ✅
- Consumer propagation → called out as out-of-scope release follow-up ✅

**Placeholder scan:** none — every code and command step is complete.

**Type/name consistency:** `set_agent_id <id> <agent_id> <scope>` and `unregister_by_agent_id <agent_id> <scope>` are used identically in Tasks 1-4; hook paths `hooks/lifecycle/marker-subagent-stop.sh`, marker field `agent_id`, and async signal `tool_response.status == "async_launched"` are consistent throughout.
