#!/usr/bin/env bash
# PreToolUse hook — enforce-secrets
#
# Single Responsibility: prevent any tool from exposing or modifying secret
# material. Applies to ALL roles (no marker bypass — secrets are equal-weight
# across main and subagent).
#
# Scope:
#   - .env* (except .env.example, .env.template, .env.local, .env.dev, .env.test)
#   - **/secrets/**
#   - **/*.pem
#   - **/*.key
#   - **/*credential*  (case-insensitive substring)
#
# Tools covered: Read, Edit, Write, Bash (read-style cat/less/head/tail/more
# and write-style sed/echo/cat>/tee/cp/mv targeting these paths).
#
# Modes:
#   disabled → bypass
#   any other value → enforce

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

MODE="${CLAUDE_HOOKS_MODE:-${AIDLC_ENFORCEMENT_MODE:-hard}}"
[ "$MODE" = "disabled" ] && exit 0

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/path-utils.sh"

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "FATAL: invalid JSON input to enforce-secrets" >&2
  exit 2
fi
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

SESSION_CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
[ -z "$SESSION_CWD" ] || [ "$SESSION_CWD" = "null" ] && SESSION_CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
SESSION_CWD_ABS=$(canonicalize "$SESSION_CWD")

emit_block() {
  local msg="$1"
  jq -cn --arg msg "$msg" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$msg}}'
  echo "$msg" >&2
  exit 2
}

# is_secret_path <path> — case-insensitive
is_secret_path() {
  local p="$1"
  [ -z "$p" ] && return 1
  local base
  base=$(basename "$p")
  shopt -s nocasematch
  local result=1
  case "$base" in
    .env.example|.env.template|.env.local|.env.dev|.env.test|.env.sample) shopt -u nocasematch; return 1 ;;
  esac
  case "$base" in
    .env|.env.*) result=0 ;;
  esac
  case "$p" in
    */secrets/*|secrets/*) result=0 ;;
    *.pem|*.key) result=0 ;;
  esac
  case "$base" in
    *credential*) result=0 ;;
  esac
  case "$p" in
    */*credential*/*) result=0 ;;
  esac
  shopt -u nocasematch
  return $result
}

check_path() {
  local fp="$1"
  local abs
  case "$fp" in
    /*) abs=$(canonicalize "$fp") ;;
    *)  abs=$(canonicalize "$SESSION_CWD_ABS/$fp") ;;
  esac
  [ -z "$abs" ] && emit_block "BLOCKED (secrets): canonicalization failed for '$fp' — fail-closed."
  if is_secret_path "$abs"; then
    emit_block "BLOCKED (secrets): '$fp' matches a secret pattern (.env*, secrets/**, *.pem, *.key, *credential*). Use a runtime secret manager (Parameter Store, env var injection) instead of reading or editing the file directly."
  fi
}

case "$TOOL_NAME" in
  Read|Edit|Write)
    FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
    [ -z "$FP" ] && exit 0
    check_path "$FP"
    ;;
  Bash)
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0
    # Read-style commands targeting secret paths.
    READ_VERBS='cat|less|more|head|tail|view|bat|tac|nl|od|hexdump|xxd|strings'
    EDIT_VERBS='sed[[:space:]]+-i|awk[[:space:]]+.*>|echo[[:space:]]+.*>>|echo[[:space:]]+.*>|cat[[:space:]]+.*>|tee[[:space:]]+|dd[[:space:]]+.*of=|truncate[[:space:]]+|perl[[:space:]]+-i|cp[[:space:]]+|mv[[:space:]]+|python[23]?[[:space:]]+-c|node[[:space:]]+-e|curl[[:space:]].*(-o|--output)|wget[[:space:]].*(-O|--output-document)|rsync[[:space:]]+'
    # Trigger if any read-verb appears with a secret-looking token, OR any edit-verb does.
    if echo "$CMD" | grep -qE "(^|[[:space:];&|])(${READ_VERBS})([[:space:]]|$)" \
       || echo "$CMD" | grep -qE "$EDIT_VERBS"; then
      # Extract path-like tokens.
      TOKENS=$(printf '%s\n' "$CMD" | tr '[:space:];&|=`"'"'"'>' '\n' | grep -E '\.env|secrets/|\.pem|\.key|credential' || true)
      while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        # Guard: skip flags.
        case "$tok" in -*) continue ;; esac
        check_path "$tok"
      done <<< "$TOKENS"
    fi
    ;;
  *) exit 0 ;;
esac

exit 0
