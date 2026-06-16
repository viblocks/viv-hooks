#!/usr/bin/env bash
# PreToolUse Agent hook — Layer 2 enforcement + marker registration
#
# Two responsibilities here, both pre-existing or newly added:
#   1. (existing) Validate routing — reject cross-domain or general-purpose
#      dispatch into Class A paths.
#   2. (new) Register subagent marker for downstream enforcement hooks.
#      Replaces the broken cwd-based role detection in the old god-object
#      pretooluse-path-policy.sh — see lib/role-detection.sh.

set -euo pipefail

MODE="${CLAUDE_HOOKS_MODE:-${AIDLC_ENFORCEMENT_MODE:-hard}}"

INPUT=$(cat)
AGENT=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // ""')
PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // ""')

# --- Library loading (libs are needed for registration below) -----------------

HOOK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || HOOK_DIR=""
LIB_DIR="$(cd "$HOOK_DIR/../../lib" 2>/dev/null && pwd)" || LIB_DIR=""
LIBS_AVAILABLE=0
if [ -n "$LIB_DIR" ] && [ -f "$LIB_DIR/marker-registry.sh" ]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/path-utils.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/marker-registry.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/routing-loader.sh" 2>/dev/null || true
  LIBS_AVAILABLE=1
fi

# --- Routing enforcement (runs FIRST so blocked dispatches never register) ---
# Per ADR-RD-007 (defer validation to Edit/Write time), the orchestrator-side
# pre-dispatch grep is RETAINED here as a soft check (advisory) but the
# canonical validation happens in enforce-routing.sh on Edit/Write.

if [ "$MODE" != "disabled" ]; then
  # Build keyword regex from Class A pattern roots (per routing-table).
  # Falls back to a generic keyword set if routing-table not yet vendored.
  KEYWORDS=""
  if [ "$LIBS_AVAILABLE" = "1" ] && command -v load_class_a_patterns >/dev/null 2>&1; then
    KEYWORDS=$(load_class_a_patterns | sed -E 's,/?\*+/?.*,,; s,^[*/]+,,' | awk 'NF' | sort -u | paste -sd'|' -)
  fi
  [ -z "$KEYWORDS" ] && KEYWORDS='services|packages|Dockerfile|docker-compose|\.github/workflows|Makefile|scripts'
  # Heuristic class-A detection (keyword-based; canonical check is at Edit/Write).
  CLASS_A_FOUND="false"
  for path_match in $(echo "$PROMPT" | grep -oE "($KEYWORDS)/[a-zA-Z0-9._/-]*"); do
    CLASS_A_FOUND="true"
    break
  done

  backend=$(echo "$PROMPT" | grep -cE 'services/(core|bot)/|packages/(shared|[a-z])' 2>/dev/null || true)
  backend=${backend:-0}
  frontend=$(echo "$PROMPT" | grep -cE 'services/ui/' 2>/dev/null || true)
  frontend=${frontend:-0}
  backend_general=$(echo "$PROMPT" | grep -cE 'services/[a-zA-Z][a-zA-Z0-9_-]*/' 2>/dev/null || true)
  backend_general=${backend_general:-0}

  # Cross-domain blocks
  if [ "$frontend" -gt 0 ] && [ "$backend" -le "$frontend" ] && echo "$AGENT" | grep -qE '^nestjs-'; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"CROSS-DOMAIN BLOCKED: nestjs agent cannot work in services/ui. Use reactjs-crypto-implementer."}}'
    [ "$MODE" = "warn" ] && exit 0 || exit 2
  fi

  if [ "$backend" -gt "$frontend" ] && echo "$AGENT" | grep -qE '^reactjs-'; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"CROSS-DOMAIN BLOCKED: reactjs agent cannot work in backend paths. Use nestjs-crypto-implementer."}}'
    [ "$MODE" = "warn" ] && exit 0 || exit 2
  fi

  if [ "$backend_general" -gt 0 ] && [ "$frontend" -eq 0 ] && echo "$AGENT" | grep -qE '^reactjs-'; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"CROSS-DOMAIN BLOCKED: reactjs agent cannot work in backend paths. Use nestjs-crypto-implementer."}}'
    [ "$MODE" = "warn" ] && exit 0 || exit 2
  fi

  # general-purpose block
  if [ "$AGENT" = "general-purpose" ] && echo "$PROMPT" | grep -qiE '(implement|fix|create|add|modify|update|edit|write|crear|implementar|corregir|modificar|agregar)'; then
    if [ "$CLASS_A_FOUND" = "true" ] || [ "$backend" -gt "$frontend" ] || ([ "$backend_general" -gt 0 ] && [ "$frontend" -eq 0 ]); then
      if [ "$frontend" -gt "$backend" ] && [ "$frontend" -gt 0 ]; then
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FRONTEND GATE BLOCKED: Class A path requires reactjs-crypto-implementer, not general-purpose."}}'
      else
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"BACKEND GATE BLOCKED: Class A path requires nestjs-crypto-implementer, not general-purpose."}}'
      fi
      [ "$MODE" = "warn" ] && exit 0 || exit 2
    fi
  fi
fi

# --- Marker registration (reached in disabled OR routing-passed case) -------
# Preserves the prior invariant: registration runs even when MODE=disabled,
# because downstream hooks honor disabled themselves and the registration is
# harmless in that mode.

if [ "$LIBS_AVAILABLE" = "1" ]; then
  TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // .session_id // ""')
  if [ -z "$TOOL_USE_ID" ] || [ "$TOOL_USE_ID" = "null" ]; then
    TOOL_USE_ID="agent-$(date +%s)-$$"
  fi

  SESSION_CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
  [ -z "$SESSION_CWD" ] || [ "$SESSION_CWD" = "null" ] && SESSION_CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

  # Scope precision: use main repo root (git-common-dir parent) so that
  # isolation-worktree subagents can find their marker via walk-up (VI-205).
  # git-common-dir returns the shared .git dir for any worktree:
  #   - in main repo:  ".git" (relative) → parent = cwd = repo root
  #   - in worktree:   "/abs/path/.git" (absolute) → parent = main repo root
  # Using this ensures the marker lands at /main-repo/.claude/.subagent-active.json,
  # reachable by walk-up from any sibling worktree under .claude/worktrees/.
  REG_SCOPE=""
  COMMON_DIR_RAW=$(git -C "$SESSION_CWD" rev-parse --git-common-dir 2>/dev/null)
  if [ -n "$COMMON_DIR_RAW" ]; then
    case "$COMMON_DIR_RAW" in
      /*) REG_SCOPE=$(dirname "$COMMON_DIR_RAW") ;;
      *)  REG_SCOPE=$(cd "$SESSION_CWD" && cd "${COMMON_DIR_RAW}/.." 2>/dev/null && pwd) || REG_SCOPE="" ;;
    esac
  fi
  if [ -z "$REG_SCOPE" ]; then
    # Fallback: use show-toplevel (worktree root) — covers non-git repos
    REG_SCOPE=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null) || true
  fi
  if [ -z "$REG_SCOPE" ]; then
    REG_SCOPE=$(canonicalize "$SESSION_CWD")
  fi
  [ -z "$REG_SCOPE" ] && REG_SCOPE="$SESSION_CWD"
  FINAL=$(canonicalize "$REG_SCOPE")
  [ -n "$FINAL" ] && REG_SCOPE="$FINAL"

  case "$AGENT" in
    infra-devops-implementer) ALLOW_ASM="true" ;;
    *)                        ALLOW_ASM="false" ;;
  esac

  # Purge expired entries before registering a new one (VI-186: handles
  # orphaned entries from sessions that terminated before PostToolUse fired).
  _purge_expired_subagents "$REG_SCOPE" 2>/dev/null || true

  register_subagent "$TOOL_USE_ID" "$AGENT" "$REG_SCOPE" "$ALLOW_ASM" "${VIV_MARKER_TTL_SECONDS:-1800}" 2>/dev/null || true

  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","registered_scope":"%s","registered_id":"%s"}}\n' "$REG_SCOPE" "$TOOL_USE_ID"
fi

exit 0
