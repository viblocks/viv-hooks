#!/usr/bin/env bash
# PreToolUse hook — enforce-routing (DENY type per ADR-RD-006)
#
# Single Responsibility: enforce typed-agent dispatch for Class A paths.
# Main role → block all Edit/Write/Bash-edit-style on Class A paths
#             (force dispatch to typed agent per routing-table.json).
# Subagent role → allow (typed agent has been dispatched).
#
# Class A scope is DERIVED from routing-table.json (per ADR-RD-004) — no
# separate classifier file. Patterns come from routes where enforced=true.
# See lib/routing-loader.sh for resolution.
#
# Bash extras:
#   - INFRA-H2: `git apply` from main → unconditional block (opaque patches)
#   - INFRA-H1: interpreter-as-editor (python -c, node -e, curl -o, wget -O,
#     rsync) targeting Class A → block
#   - SEC-M3: shell-substitution ($, backtick, ~) in edit-style commands
#     fails closed when no literal Class A target is extractable
#
# Note: Read is NOT enforced here — routing is about who writes, not who reads.
# Secrets are handled by enforce-secrets.sh (orthogonal concern).
#
# Modes (CLAUDE_HOOKS_MODE; legacy AIDLC_ENFORCEMENT_MODE honored):
#   disabled → bypass
#   any other value → enforce (warn NOT honored for deny hooks; ADR-RD-006)

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

MODE="${CLAUDE_HOOKS_MODE:-${AIDLC_ENFORCEMENT_MODE:-hard}}"
[ "$MODE" = "disabled" ] && exit 0

# Hook layout: hooks/<type>/<hook>.sh; lib at lib/.
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/path-utils.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/marker-registry.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/role-detection.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/bash-write-detector.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/routing-loader.sh"

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "FATAL: invalid JSON input to enforce-routing" >&2
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

# Class A patterns derived from routing-table.json (per ADR-RD-004).
# load_class_a_patterns_array populates the array with both raw and absolute-
# prefix variants so both relative and canonical paths match.
CLASS_A_PATTERNS=()
load_class_a_patterns_array CLASS_A_PATTERNS

# If no routing-table is resolved or no enforced routes exist, the hook is
# inert. Logging to stderr; exit 0 (cannot enforce a contract that's absent).
if [ "${#CLASS_A_PATTERNS[@]}" -eq 0 ]; then
  echo "WARN: no routing-table.json resolved or no enforced routes — enforce-routing is inert" >&2
  exit 0
fi

get_role() { ( cd "$SESSION_CWD_ABS" 2>/dev/null || cd "$SESSION_CWD" 2>/dev/null || true; detect_role ); }

check_path() {
  local fp="$1"
  local abs
  case "$fp" in
    /*) abs=$(canonicalize "$fp") ;;
    *)  abs=$(canonicalize "$SESSION_CWD_ABS/$fp") ;;
  esac
  [ -z "$abs" ] && emit_block "BLOCKED (routing): canonicalization failed for '$fp' — fail-closed."
  if is_class_a "$abs" "${CLASS_A_PATTERNS[@]}"; then
    emit_block "BLOCKED (routing): '$fp' matches an enforced route in routing-table.json — dispatch the typed agent for this domain. Main session must not edit Class A paths directly. See .claude/routing/routing-table.json (routes where enforced=true)."
  fi
}

case "$TOOL_NAME" in
  Edit|Write)
    ROLE=$(get_role)
    [ "$ROLE" = "subagent" ] && exit 0
    FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
    [ -z "$FP" ] && exit 0
    check_path "$FP"
    ;;

  Bash)
    ROLE=$(get_role)
    [ "$ROLE" = "subagent" ] && exit 0
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0

    # INFRA-H2: `git apply` from main is opaque — unconditional block.
    if echo "$CMD" | grep -qE '(^|[[:space:];&|])git[[:space:]]+apply([[:space:]]|$)'; then
      emit_block "BLOCKED (routing): 'git apply' from main session is opaque — patches can mutate any path including Class A. Dispatch the typed agent for the affected domain, or apply the patch inside a worktree subagent session."
    fi

    # Fast-path: pure read commands cannot write Class A paths.
    if is_pure_read_command "$CMD"; then
      exit 0
    fi

    # Verb-agnostic write-target extraction. Catches ANY verb + redirect, plus
    # known write-arg-position commands. Replaces the brittle EDIT_PATTERNS
    # denylist that missed wget -qO, curl -so, printf, install, ln, openssl,
    # uppercase paths, and any verb not enumerated in the regex.
    TARGETS=$(extract_write_targets "$CMD")

    # INFRA-H1 supplement: interpreter-as-editor (python -c, node -e, perl -e,
    # ruby -e) embeds the write target inside the script string, not as a
    # positional arg. Scan the whole command for Class A path tokens when an
    # interpreter -c/-e is present. Without shell-subst, this is enough; with
    # shell-subst, the SEC-M3 fail-closed below catches the obfuscated case.
    if echo "$CMD" | grep -qE '(^|[[:space:];&|])(python[23]?[[:space:]]+-c|node[[:space:]]+-e|perl[[:space:]]+-e|ruby[[:space:]]+-e)'; then
      # Build interpreter-target regex from Class A pattern roots (strip wildcards).
      INTERP_KEYWORDS=$(printf '%s\n' "${CLASS_A_PATTERNS[@]}" | sed -E 's,/?\*+/?.*,,; s,^[*/]+,,' | awk 'NF' | sort -u | paste -sd'|' -)
      [ -z "$INTERP_KEYWORDS" ] && INTERP_KEYWORDS='services|packages|Dockerfile|docker-compose|\.github/workflows|Makefile|scripts'
      INTERP_TARGETS=$(echo "$CMD" | grep -oiE "($INTERP_KEYWORDS)[a-zA-Z0-9._/:-]*" || true)
      if [ -n "$INTERP_TARGETS" ]; then
        TARGETS="$TARGETS"$'\n'"$INTERP_TARGETS"
      fi
    fi

    literal_hit=0
    while IFS= read -r tgt; do
      [ -z "$tgt" ] && continue
      # Resolve to absolute for case-insensitive Class A check.
      tgt_abs=""
      case "$tgt" in
        /*) tgt_abs=$(canonicalize "$tgt") ;;
        *)  tgt_abs=$(canonicalize "$SESSION_CWD_ABS/$tgt") ;;
      esac
      [ -z "$tgt_abs" ] && tgt_abs="$tgt"
      if is_class_a "$tgt_abs" "${CLASS_A_PATTERNS[@]}"; then
        literal_hit=1
        emit_block "BLOCKED (routing): Bash command writes to Class A path '$tgt'. Dispatch the typed agent for this domain (see .claude/routing/routing-table.json)."
      fi
    done <<< "$TARGETS"

    # SEC-M3: shell-substitution fail-closed when no literal Class A target
    # was extracted but the command is "write-shaped" (any redirect, or known
    # write-arg verb like sed -i, cp, install, curl -o, wget -O, etc.).
    case "$CMD" in
      *\$*|*\`*|*'~'*)
        if [ "$literal_hit" = "0" ] && has_potential_write "$CMD"; then
          emit_block "BLOCKED (routing): Bash command appears to write (redirect or write-arg verb) but target contains shell substitution (\$, backtick, or ~) — fails closed. Dispatch the typed agent if the target is a Class A path, or rewrite with a literal path."
        fi
        ;;
    esac
    ;;

  *) exit 0 ;;
esac

exit 0
