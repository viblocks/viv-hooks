#!/usr/bin/env bash
# lib/marker-registry.sh — concurrent-safe registry of active subagents.
#
# Marker file: <scope>/.claude/.subagent-active.json
# Lock file:   <scope>/.claude/.subagent-active.json.lock
#
# Schema:
# {
#   "subagents": [
#     {
#       "id": "<stable-id>",
#       "agent_type": "<typed-agent-name>",
#       "dispatched_at": "<ISO 8601 UTC>",
#       "ttl_seconds": 1800,
#       "allow_self_mod": true|false,
#       "scope": "<absolute-path>"
#     }
#   ]
# }
#
# All mutations atomic via flock(1) on the lock file.

# Internal: marker path for a scope.
_marker_path() { echo "$1/.claude/.subagent-active.json"; }
_lock_path()   { echo "$1/.claude/.subagent-active.json.lock"; }

# Internal: ISO 8601 UTC timestamp.
_now_iso() {
  if date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null; then return; fi
  python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))'
}

# Internal: epoch seconds.
_now_epoch() { date -u +%s; }

# Internal: parse ISO 8601 to epoch (best-effort, fail returns 0).
_iso_to_epoch() {
  local s="$1"
  # Try GNU date first.
  local out
  if out=$(date -u -d "$s" +%s 2>/dev/null); then echo "$out"; return; fi
  # BSD/macOS date: -j -f format
  if out=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$s" +%s 2>/dev/null); then echo "$out"; return; fi
  # Python fallback.
  if out=$(python3 -c "import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$s" 2>/dev/null); then
    echo "$out"; return
  fi
  echo "0"
}

# _with_lock <scope> <command...>
# Acquires exclusive lock then runs the command.
# Uses flock(1) when available (Linux); falls back to atomic mkdir spinlock on
# macOS/BSD where flock is absent.
_with_lock() {
  local scope="$1"; shift
  local lock; lock=$(_lock_path "$scope")
  mkdir -p "$(dirname "$lock")"
  if command -v flock >/dev/null 2>&1; then
    ( flock -x -w 5 200 || { echo "LOCK_TIMEOUT" >&2; return 1; }
      "$@"
    ) 200>"$lock"
    return $?
  fi
  # Fallback: mkdir-based mutex. mkdir is atomic on POSIX filesystems.
  local lockdir="${lock}.d"
  local waited=0
  local rc
  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -gt 100 ]; then
      # 100 * 50ms = 5s — match flock timeout.
      # Stale lock recovery: if older than 30s, remove and retry once.
      if [ -d "$lockdir" ]; then
        local age
        age=$(( $(date -u +%s) - $(stat -f %m "$lockdir" 2>/dev/null || stat -c %Y "$lockdir" 2>/dev/null || echo 0) ))
        if [ "$age" -gt 30 ]; then
          rmdir "$lockdir" 2>/dev/null || true
          waited=0   # reset counter after recovery (SEC-MED-1)
          continue
        fi
      fi
      echo "LOCK_TIMEOUT" >&2
      return 1
    fi
  done
  "$@"
  rc=$?
  rmdir "$lockdir" 2>/dev/null || true
  return $rc
}

# register_subagent <id> <agent_type> <scope> <allow_self_mod> [ttl_seconds]
register_subagent() {
  local id="$1" agent_type="$2" scope="$3" allow_self_mod="$4" ttl="${5:-1800}"
  local marker; marker=$(_marker_path "$scope")
  mkdir -p "$(dirname "$marker")"
  local ts; ts=$(_now_iso)
  _with_lock "$scope" bash -c '
    marker="$1"; id="$2"; agent_type="$3"; scope="$4"; asm="$5"; ts="$6"; ttl="$7"
    if [ -f "$marker" ]; then
      existing=$(cat "$marker")
    else
      existing="{\"subagents\":[]}"
    fi
    new_entry=$(jq -cn \
      --arg id "$id" \
      --arg at "$agent_type" \
      --arg sc "$scope" \
      --arg ts "$ts" \
      --argjson asm "$asm" \
      --argjson ttl "$ttl" \
      "{id:\$id, agent_type:\$at, dispatched_at:\$ts, ttl_seconds:\$ttl, allow_self_mod:\$asm, scope:\$sc}")
    echo "$existing" | jq --argjson e "$new_entry" ".subagents += [\$e]" > "$marker.tmp"
    mv "$marker.tmp" "$marker"
  ' _ "$marker" "$id" "$agent_type" "$scope" "$allow_self_mod" "$ts" "$ttl"
}

# unregister_subagent <id> <scope>
# Idempotent: missing entry is a no-op. Empty subagents array → file removed.
unregister_subagent() {
  local id="$1" scope="$2"
  local marker; marker=$(_marker_path "$scope")
  [ -f "$marker" ] || return 0
  _with_lock "$scope" bash -c '
    marker="$1"; id="$2"
    if [ ! -f "$marker" ]; then exit 0; fi
    jq --arg id "$id" ".subagents |= map(select(.id != \$id))" "$marker" > "$marker.tmp"
    mv "$marker.tmp" "$marker"
    if [ "$(jq ".subagents | length" "$marker")" = "0" ]; then
      rm -f "$marker"
    fi
  ' _ "$marker" "$id"
}

# list_active_subagents <scope>
# Echoes JSON array of fresh (non-stale) entries. Empty array if marker missing.
list_active_subagents() {
  local scope="$1"
  local marker; marker=$(_marker_path "$scope")
  if [ ! -f "$marker" ]; then echo "[]"; return; fi
  local now; now=$(_now_epoch)
  # Read entries; filter out stale ones.
  local entries; entries=$(jq -c '.subagents // []' "$marker" 2>/dev/null || echo "[]")
  local fresh="[]"
  local len; len=$(echo "$entries" | jq 'length')
  local i=0
  while [ "$i" -lt "$len" ]; do
    local entry dispatched_at ttl ep age
    entry=$(echo "$entries" | jq -c ".[$i]")
    dispatched_at=$(echo "$entry" | jq -r '.dispatched_at // ""')
    ttl=$(echo "$entry" | jq -r '.ttl_seconds // 1800')
    if [ -n "$dispatched_at" ]; then
      ep=$(_iso_to_epoch "$dispatched_at")
      age=$((now - ep))
      if [ "$age" -lt "$ttl" ]; then
        fresh=$(echo "$fresh" | jq --argjson e "$entry" '. + [$e]')
      fi
    fi
    i=$((i + 1))
  done
  echo "$fresh"
}

# _purge_expired_subagents <scope>
# Rewrites marker file with only fresh (non-stale) entries. Called before
# register_subagent by pretooluse-agent.sh to clean up orphaned entries from
# sessions that terminated before their PostToolUse cleanup could fire.
# No-op if marker file missing. All-expired → file removed.
#
# Concurrency: read+filter+write happen inside a SINGLE _with_lock critical
# section to avoid TOCTOU with concurrent register_subagent. The TTL filter
# is inlined here (rather than calling list_active_subagents) because that
# helper is unlocked and would race with this function's own write.
_purge_expired_subagents() {
  local scope="$1"
  local marker; marker=$(_marker_path "$scope")
  [ -f "$marker" ] || return 0
  local now; now=$(_now_epoch)
  _with_lock "$scope" bash -c '
    marker="$1"; now="$2"
    [ -f "$marker" ] || exit 0
    # Read entries (default to []), then filter by TTL using epoch math.
    # jq computes age via fromdateiso8601; if dispatched_at is missing or
    # unparsable, the entry is dropped (mirrors list_active_subagents).
    fresh=$(jq -c --argjson now "$now" "
      [ .subagents[]?
        | select((.dispatched_at // \"\") != \"\")
        | select((\$now - (.dispatched_at | fromdateiso8601? // 0)) < (.ttl_seconds // 1800))
      ]
    " "$marker" 2>/dev/null) || fresh="[]"
    fresh_len=$(echo "$fresh" | jq "length")
    if [ "$fresh_len" = "0" ]; then
      rm -f "$marker"
    else
      jq -n --argjson s "$fresh" "{\"subagents\":\$s}" > "$marker.tmp" && mv "$marker.tmp" "$marker"
    fi
  ' _ "$marker" "$now"
}
