# Design — Async subagent marker lifecycle

**Date:** 2026-07-06
**Repo:** `viblocks/viv-hooks`
**Branch:** `fix/async-subagent-marker-lifecycle`
**Fixes:** `viblocks/viv-aidlc-orchestrator#39` — *Marker routing-enforcement breaks under asynchronous (background) subagent dispatch*

## Problem

The typed-agent routing enforcement uses a **subagent marker registry** as a capability
token: `PreToolUse:Agent` registers a marker at the repo root; downstream Edit/Write/Bash
hooks call `detect_role`, which walks up from `cwd` looking for a fresh marker. A found
marker → `role=subagent` (Class A edits allowed); no marker → `role=main` (Class A edits
blocked by `enforce-routing.sh`).

Cleanup is wired on `PostToolUse:Agent`, which unregisters the marker by `tool_use_id`.

`PostToolUse` fires on the **tool-call return**. For a **background** Agent dispatch the
tool returns immediately at *launch* (with `tool_response.status == "async_launched"` and
an `agentId`), so `PostToolUse` — and therefore the unregister — fires while the subagent
is *still running*. The subagent then keeps executing **with no marker** → `detect_role`
returns `main` → its first Class A edit is blocked. Net effect: typed-agent Class A edits
are impossible under async dispatch, the IRON LAW cannot be satisfied, and work stalls
until a session restart.

Validated against code at `viv-hooks@bd6a915`:
- `hooks/lifecycle/marker-cleanup.sh` calls `unregister_subagent` unconditionally — no
  async-launch detection.
- `lib/role-detection.sh::_walk_up_for_scope` → no fresh marker → `main`.
- `hooks/deny/enforce-routing.sh` → `role=main` blocks Class A Edit/Write/Bash-write.

## Harness contract (verified against Claude Code docs)

| Event | Fires (background) | Key fields |
|-------|--------------------|------------|
| `PreToolUse:Agent`  | at dispatch          | `tool_use_id`; `tool_input.run_in_background` |
| `PostToolUse:Agent` | at **launch**        | `tool_use_id`; `tool_response.status == "async_launched"`; `tool_response.agentId` |
| `SubagentStop`      | at **real completion** (background *and* sync) | `agent_id` (== the PostToolUse `agentId`); `session_id`; `cwd`. **`tool_use_id` NOT documented** |

Two load-bearing facts:

1. **`tool_input.run_in_background` is not a reliable async signal** — the harness may
   background a dispatch even when the flag is absent (reproduced this session; matches the
   issue report). The reliable async signal is `tool_response.status == "async_launched"`
   in the `PostToolUse` input.
2. **`SubagentStop` is the correct completion event.** Correlation from dispatch →
   completion is carried by `agentId` (present in the `PostToolUse` async response and as
   `agent_id` in `SubagentStop`), **not** by `tool_use_id` (absent from `SubagentStop`).

## Approach — cleanup driven by the correct event (hybrid)

Tie the marker's lifetime to the subagent's **real** lifetime instead of to the tool-call
return. The synchronous path (which already works and uses the certain identifier) is left
untouched; the asynchronous path is completed via `SubagentStop`.

### Flow

**`PreToolUse:Agent`** — unchanged in substance. Register the marker keyed by
`tool_use_id`, TTL `${VIV_MARKER_TTL_SECONDS:-1800}` (now purely a crash-fallback, not the
primary cleanup mechanism).

**`PostToolUse:Agent`** — branch on the async signal:
- `tool_response.status == "async_launched"` → **do not unregister.** Annotate the existing
  marker entry with `agent_id = tool_response.agentId` so `SubagentStop` can find it later.
  The subagent keeps running *with* its marker → Class A edits allowed.
- otherwise (sync/foreground completion) → **unregister by `tool_use_id`**, exactly as
  today. Proven path, certain identifier, no behavior change.

**`SubagentStop`** (new hook) — the real completion signal for background subagents.
Unregister the marker entry whose `agent_id` matches the event's `agent_id`. Scope is found
by walking up from the event `cwd` (same pattern as the existing cleanup fallback).

**Safety net** (already present, retained): `_purge_expired_subagents` runs before each new
registration, and entries carry a bounded TTL (1800s default). If `SubagentStop` never fires
(crash, killed process), the async marker expires on its own — it can never linger
indefinitely granting `subagent` role to the main session.

### Why this is not a patch

- It removes the **root tension** — TTL length vs. long-running agents — because the marker
  is deleted on the *actual completion event*, not by timeout. TTL becomes a pure
  crash-fallback, not a correctness knob.
- The **synchronous path is unchanged and still uses `tool_use_id`** (the certain id); only
  the async path uses the new `agent_id` correlation.
- It uses the harness event (`SubagentStop`) that exists precisely to signal subagent
  completion, rather than special-casing `async_launched` in the wrong event and papering
  over it with a short TTL.

## Components / changes

### `lib/marker-registry.sh`
- Marker entry schema gains an optional `agent_id` field.
- New `set_agent_id <tool_use_id> <agent_id> <scope>` — locked mutation that annotates the
  matching entry (idempotent; no-op if entry absent).
- New `unregister_by_agent_id <agent_id> <scope>` — locked removal of the entry matching
  `agent_id`; removes the marker file when the array empties (mirrors `unregister_subagent`).
- Existing `register_subagent` / `unregister_subagent` / `list_active_subagents` /
  `_purge_expired_subagents` unchanged in contract.

### `hooks/lifecycle/marker-cleanup.sh` (`PostToolUse:Agent`)
- Read `tool_response.status`. If `async_launched`: read `tool_response.agentId`, call
  `set_agent_id` on the registered scope, and exit 0 **without** unregistering.
- Else: unregister by `tool_use_id` (current behavior).
- Still always exits 0 (cleanup must never block the chain).

### `hooks/lifecycle/marker-subagent-stop.sh` (new, `SubagentStop`)
- Read `agent_id` and `cwd` from input. Walk up from `cwd` (or `registered_scope` if the
  harness passes it) to find the marker scope. Call `unregister_by_agent_id`. Always exit 0.

### `settings.json.fragment`
- Add a `SubagentStop` matcher wiring `marker-subagent-stop.sh`.

### Consumer propagation
- New hook file + settings fragment must reach consumers via the typed-agents MANIFEST pin
  and the orchestrator installer (out of scope for this repo's change; tracked for the
  release step).

## Testing

TDD — write the failing test first, reproducing the async race, then implement.

1. **Async race regression (unit, drives the fix):** simulate `PreToolUse` register →
   `PostToolUse` with `tool_response.status=async_launched` → assert marker **still present**
   and annotated with `agent_id`. Then simulate `SubagentStop` with that `agent_id` → assert
   marker removed. Before the fix, step 2 removes the marker → test fails.
2. **Sync path unchanged:** `PreToolUse` register → `PostToolUse` with a normal (non-async)
   `tool_response` → assert marker removed by `tool_use_id`. Guards against regression.
3. **Registry units:** `set_agent_id` annotates the right entry and is idempotent;
   `unregister_by_agent_id` removes only the matching entry, leaves concurrent entries,
   removes the file when empty.
4. **Crash fallback:** async marker never cleaned by `SubagentStop` → still purged by TTL /
   `_purge_expired_subagents` on next registration.
5. **Empirical integration check (must pass before shipping):** a real background dispatch
   in a live Claude Code session confirming `SubagentStop.agent_id` equals the PostToolUse
   `agentId`, and that a typed implementer completes a Class A edit end-to-end under async
   dispatch. This validates the one non-contractual assumption (agent_id correlation).

Existing tests (`tests/*.test.sh`, incl. `test-marker-ttl-configurable.test.sh`) must
continue to pass.

## Security

- Removing a marker only ever *tightens* enforcement (can make `role=main`, never grants
  escalation). Skipping the async unregister is paired with the bounded TTL so a stale marker
  cannot keep granting `subagent` role beyond the TTL window if `SubagentStop` fails.
- No self-register from agents. `CLAUDE_HOOK_ROLE` / `CLAUDE_HOOK_SCOPE` honored only under
  `CLAUDE_HOOK_TEST=1` (HIGH-A anti-spoof) — unchanged.
- `agent_id` correlation is a harness-provided identifier written by the trusted hook, not by
  the subagent, so it is not spoofable from within a subagent prompt.

## Out of scope

- Changing the TTL default (already configurable via `VIV_MARKER_TTL_SECONDS`, default 1800).
- `SubagentStart` hook usage.
- Consumer-side release/propagation (separate typed-agents + orchestrator release step).
