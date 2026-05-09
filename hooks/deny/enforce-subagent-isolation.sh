#!/usr/bin/env bash
# PreToolUse hook — enforce-subagent-isolation
#
# Single Responsibility: confine subagents to their declared scope.
# Only fires when role=subagent (per marker registry). Main role: no-op.
#
# Scope: the path stored in the subagent marker entry. With multiple active
# subagents in the same scope, the scope is the registered scope (they share
# it by construction).
#
# Confinement applies to:
#   - Edit, Write, Read file_path
#   - Bash command targets:
#       * GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR / GIT_OBJECT_DIRECTORY /
#         GIT_INDEX_FILE / GIT_HOOKS_PATH / GIT_CONFIG[_GLOBAL|_SYSTEM] /
#         GIT_TEMPLATE_DIR env-var assignments
#       * git -C <path>, git --git-dir=<path>, git --work-tree=<path>
#       * cd / pushd <abs-path>
#       * Generic absolute-path token scan (catch-all): any /-prefixed token
#         resolving outside scope is blocked.
#
# Shell substitution ($, backtick, ~) in any of the above values fails closed.
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
# shellcheck source=/dev/null
source "$LIB_DIR/marker-registry.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/role-detection.sh"

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "FATAL: invalid JSON input to enforce-subagent-isolation" >&2
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

# Determine role + scope inside the hook caller's cwd context.
get_role()  { ( cd "$SESSION_CWD_ABS" 2>/dev/null || cd "$SESSION_CWD" 2>/dev/null || true; detect_role           ); }
get_scope() { ( cd "$SESSION_CWD_ABS" 2>/dev/null || cd "$SESSION_CWD" 2>/dev/null || true; detect_subagent_scope ); }

ROLE=$(get_role)
[ "$ROLE" != "subagent" ] && exit 0

SCOPE=$(get_scope)
SCOPE_ABS=$(canonicalize "$SCOPE")
[ -z "$SCOPE_ABS" ] && emit_block "BLOCKED (isolation): subagent scope unresolvable — fail-closed."

resolve_and_check_target() {
  local raw="$1" label="${2:-}"
  case "$raw" in
    *\$*|*\`*|*'~'*)
      emit_block "BLOCKED (isolation): ${label:+$label }value '$raw' contains shell substitution (\$, backtick, or ~) — unanalyzable, fails closed."
      ;;
  esac
  local abs
  case "$raw" in
    /*) abs=$(canonicalize "$raw") ;;
    *)  abs=$(canonicalize "$SESSION_CWD_ABS/$raw") ;;
  esac
  [ -z "$abs" ] && emit_block "BLOCKED (isolation): canonicalization failed for '$raw' — fail-closed."
  if ! is_under "$abs" "$SCOPE_ABS"; then
    emit_block "BLOCKED (isolation): ${label:+$label — }path '$raw' resolves to '$abs' outside subagent scope '$SCOPE_ABS'."
  fi
}

case "$TOOL_NAME" in
  Edit|Write|Read)
    FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
    [ -z "$FP" ] && exit 0
    resolve_and_check_target "$FP" "$TOOL_NAME"
    ;;

  Bash)
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0

    # GIT_* env-var escape.
    ENV_ASSIGNS=$(echo "$CMD" | grep -oE '\b(GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_OBJECT_DIRECTORY|GIT_INDEX_FILE|GIT_HOOKS_PATH|GIT_CONFIG|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_TEMPLATE_DIR)=[^[:space:];&|]+' || true)
    while IFS= read -r assign; do
      [ -z "$assign" ] && continue
      val="${assign#*=}"
      case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
      esac
      [ -z "$val" ] && continue
      var_name="${assign%%=*}"
      resolve_and_check_target "$val" "$var_name"
    done <<< "$ENV_ASSIGNS"

    # git flag values.
    GIT_FLAG_VALS=$(echo "$CMD" | grep -oE "git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+|--(git-dir|work-tree)=[^[:space:];&|]+" || true)
    while IFS= read -r raw; do
      [ -z "$raw" ] && continue
      case "$raw" in
        --git-dir=*)   flag="--git-dir";   val="${raw#--git-dir=}" ;;
        --work-tree=*) flag="--work-tree"; val="${raw#--work-tree=}" ;;
        git*-C*)
          flag="git -C"
          val=$(printf '%s' "$raw" | sed -E 's/^git[[:space:]]+-C[[:space:]]+//')
          ;;
        *) continue ;;
      esac
      case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
      esac
      [ -z "$val" ] && continue
      resolve_and_check_target "$val" "$flag"
    done <<< "$GIT_FLAG_VALS"

    # cd / pushd to absolute paths.
    CD_TARGETS=$(echo "$CMD" | grep -oE '(^|[;&|[:space:]])(cd|pushd)[[:space:]]+"?'"'"'?(/[A-Za-z0-9._/-]+)' | grep -oE '/[A-Za-z0-9._/-]+' || true)
    while IFS= read -r t; do
      [ -z "$t" ] && continue
      abs_t=$(canonicalize "$t")
      if [ -n "$abs_t" ] && ! is_under "$abs_t" "$SCOPE_ABS"; then
        emit_block "BLOCKED (isolation): cd/pushd target '$t' is outside subagent scope '$SCOPE_ABS'."
      fi
    done <<< "$CD_TARGETS"

    # Generic absolute-path token scan.
    TOKENS=$(printf '%s\n' "$CMD" | tr '[:space:];&|=`"'"'"'' '\n')
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      case "$tok" in /*) ;; *) continue ;; esac
      abs_tok=$(canonicalize "$tok")
      [ -z "$abs_tok" ] && emit_block "BLOCKED (isolation): canonicalization failed for token '$tok' — fail-closed."
      # Only flag tokens that exist or look path-like; skip tokens like /bin/sh
      # (system) — but the subagent should not be running system writes anyway.
      # Conservative: any absolute token outside scope blocks.
      if ! is_under "$abs_tok" "$SCOPE_ABS"; then
        # Whitelist common immutable system paths subagents legitimately need
        # (binaries, config, runtime). DO NOT whitelist user-data temp roots
        # like /tmp or /var/folders — those can host sibling project trees the
        # subagent must NOT cross into.
        case "$abs_tok" in
          /bin/*|/usr/*|/sbin/*|/opt/*|/etc/*|/var/run/*|/dev/*|/proc/*|/sys/*) continue ;;
        esac
        emit_block "BLOCKED (isolation): Bash references absolute path '$tok' outside subagent scope '$SCOPE_ABS'."
      fi
    done <<< "$TOKENS"
    ;;

  *) exit 0 ;;
esac

exit 0
