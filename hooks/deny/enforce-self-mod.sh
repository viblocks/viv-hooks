#!/usr/bin/env bash
# PreToolUse hook — enforce-self-mod
#
# Single Responsibility: protect the enforcement layer from self-modification.
# Bypass is role-aware (via marker registry, not cwd): only subagents whose
# active marker entries ALL declare allow_self_mod=true can edit these paths.
#
# Scope (Edit/Write/Bash edit-style):
#   - .claude/hooks/**
#   - .claude/settings.json, .claude/settings.local.json
#   - root-level CLAUDE.md (NOT subdir CLAUDE.md, which are per-agent docs)
#
# Modes:
#   disabled → full bypass
#   any other value → enforce (warn is NOT honored — would silently downgrade
#                              hard denies; see VI-137 SEC-M4)

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
# shellcheck source=/dev/null
source "$LIB_DIR/bash-write-detector.sh"

INPUT=$(cat)
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "FATAL: invalid JSON input to enforce-self-mod" >&2
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

# Walk-up role detection runs against the cwd we're called with, not the
# script's PWD, so re-run inside that dir.
get_role()       { ( cd "$SESSION_CWD_ABS" 2>/dev/null || cd "$SESSION_CWD" 2>/dev/null || true; detect_role        ); }
get_allow_asm()  { ( cd "$SESSION_CWD_ABS" 2>/dev/null || cd "$SESSION_CWD" 2>/dev/null || true; detect_allow_self_mod ); }

# is_self_mod_path <abs-path>
is_self_mod_path() {
  local p="$1"
  shopt -s nocasematch
  case "$p" in
    */.claude/hooks/*)                                                  shopt -u nocasematch; return 0 ;;
    */.claude/settings.json)                                            shopt -u nocasematch; return 0 ;;
    */.claude/settings.local.json)                                      shopt -u nocasematch; return 0 ;;
    */.claude/.subagent-active.json|*/.claude/.subagent-active.json.lock|*/.claude/.subagent-active.json.lock.d|*/.claude/.subagent-active.json.tmp)
      shopt -u nocasematch; return 0 ;;
  esac
  shopt -u nocasematch
  # Root-level CLAUDE.md only. Subdir CLAUDE.md (.claude/agents/*/CLAUDE.md
  # etc., or any consumer-defined orchestrator's per-rule CLAUDE.md) are
  # per-agent or per-rule docs, not the enforcement layer.
  #
  # Generic pattern: any CLAUDE.md nested 2+ levels under a directory
  # starting with `.` (dotdir) is treated as per-rule documentation, NOT
  # the root enforcement layer. This covers .claude/, .aidlc-rule-details/,
  # .cursor/, and any future orchestrator-rule paths without hardcoding.
  shopt -s nocasematch
  case "$p" in
    */CLAUDE.md|CLAUDE.md)
      case "$p" in
        */agents/*/CLAUDE.md) shopt -u nocasematch; return 1 ;;
        */.[a-z]*/*/CLAUDE.md|.[a-z]*/*/CLAUDE.md) shopt -u nocasematch; return 1 ;;
        *) shopt -u nocasematch; return 0 ;;
      esac
      ;;
  esac
  shopt -u nocasematch
  return 1
}

check_path() {
  local fp="$1"
  local abs
  case "$fp" in
    /*) abs=$(canonicalize "$fp") ;;
    *)  abs=$(canonicalize "$SESSION_CWD_ABS/$fp") ;;
  esac
  [ -z "$abs" ] && emit_block "BLOCKED (self-mod): canonicalization failed for '$fp'."
  is_self_mod_path "$abs" || return 0
  local allow
  allow=$(get_allow_asm)
  if [ "$allow" = "true" ]; then
    return 0
  fi
  emit_block "BLOCKED (self-mod): '$fp' is part of the enforcement layer. Only subagents dispatched with allow_self_mod=true (e.g. infra-devops-implementer) may modify .claude/hooks/**, .claude/settings*.json, or root CLAUDE.md."
}

case "$TOOL_NAME" in
  Edit|Write)
    FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
    [ -z "$FP" ] && exit 0
    check_path "$FP"
    ;;
  Bash)
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0

    # Fast-path: pure read commands cannot write.
    if is_pure_read_command "$CMD"; then
      exit 0
    fi

    # Verb-agnostic write-target extraction. Catches ANY verb + redirect, plus
    # known write-arg-position commands (cp/mv/install/ln/rsync/curl/wget/
    # tee/dd/truncate/sed -i/perl -i). Replaces the brittle EDIT_PATTERNS
    # denylist (which missed wget -qO, curl -so, printf, install, ln, openssl,
    # etc — any verb not enumerated bypassed the gate).
    TARGETS=$(extract_write_targets "$CMD")

    literal_hit=0
    while IFS= read -r tgt; do
      [ -z "$tgt" ] && continue
      # Resolve relative paths against session cwd so is_self_mod_path sees
      # the absolute form. check_path does this for us — we just call it.
      # But check_path will block immediately on hit; we want to record
      # literal_hit first for the SEC-M3 path. So we inline the abs check.
      local_abs=""
      case "$tgt" in
        /*) local_abs=$(canonicalize "$tgt") ;;
        *)  local_abs=$(canonicalize "$SESSION_CWD_ABS/$tgt") ;;
      esac
      if [ -n "$local_abs" ] && is_self_mod_path "$local_abs"; then
        literal_hit=1
        check_path "$tgt"  # will emit_block (does not return)
      fi
    done <<< "$TARGETS"

    # SEC-HIGH-1 / SEC-M3: shell-substitution fail-closed when no literal
    # self-mod target was extracted but the command is "write-shaped".
    # Mirrors enforce-routing.sh symmetry. Catches obfuscation like
    # `sed -i s/a/b/ $HOOKS_DIR/foo.sh` where target is shell-substituted.
    case "$CMD" in
      *\$*|*\`*|*'~'*)
        if [ "$literal_hit" = "0" ] && has_potential_write "$CMD"; then
          emit_block "BLOCKED (self-mod): Bash command appears to write (redirect or write-arg verb) but target contains shell substitution (\$, backtick, or ~) — fails closed. Rewrite with a literal path or dispatch infra-devops-implementer."
        fi
        ;;
    esac
    ;;
  *) exit 0 ;;
esac

exit 0
