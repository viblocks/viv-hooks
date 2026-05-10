#!/usr/bin/env bash
# PreToolUse Edit|Write hook — Layer 1 refinement: fast-lane for mechanical edits
#
# Purpose:
#   The Layer 1 deny list in settings.json blocks main-session Edit/Write on all
#   Class A paths. That is correct for app code (services/*/src, packages/*/src)
#   but excessive for Class A non-app paths (docker-compose.yml, docs, config)
#   when the change is mechanical (small diff, no new code structure).
#   This hook emits `permissionDecision: allow` to bypass the deny list for such
#   mechanical edits.
#
# Contract (VI-130, hardened per security-reviewer findings):
#   Emits allow ONLY when ALL 7 eligibility criteria hold:
#     1. Tool is Write or Edit
#     2. Extension is in allow-list (md, yml, yaml, json, toml, ini, txt,
#        gitignore, gitattributes)
#     3. Path does NOT match app-code patterns (services/*/src/**, packages/*/src/**)
#     4. Path does NOT match security-sensitive patterns:
#         - self-modification: CLAUDE.md, AGENTS.md, GEMINI.md, and any
#           dotdir-rule-paths (.claude/**, .cursor/**, .github/**, and any
#           consumer-defined orchestrator paths like .<orchestrator>-rule-details/**)
#         - supply chain: package.json, lockfiles, docker-compose*, Dockerfile*,
#           tsconfig*, Makefile, .npmrc, .yarnrc*
#         - reviewer trust: .gitignore, .gitattributes, .gitmodules
#         - env files: .env*
#         - substring-sensitive path segments: *auth*, *crypto*, *guard*,
#           *secret*, *credential*
#     5. Diff size threshold: added+deleted lines <= 10
#     6. No new imports/requires/exports vs original
#     7. No new function/class/def vs original
#
#   Symlinks are resolved and BOTH the original path AND target are classified.
#   If either matches an exclusion, the hook defers.
#
#   Any criterion failing → exit 0 with NO permissionDecision → Layer 1
#   applies normally (deny list blocks if path is Class A).
#
# Modes:
#   AIDLC_ENFORCEMENT_MODE=disabled → hook no-op (exit 0, no decision).
#   AIDLC_ENFORCEMENT_MODE=warn     → same eligibility, but on a would-be-blocked
#                                      case (threshold exceeded etc.) emit advisory
#                                      to stderr and exit 0 without allow.
#   AIDLC_ENFORCEMENT_MODE=hard (default) → strict 7-criteria allow-or-defer.

set -euo pipefail

MODE="${CLAUDE_HOOKS_MODE:-${AIDLC_ENFORCEMENT_MODE:-hard}}"
[ "$MODE" = "disabled" ] && exit 0

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL_NAME" in
  Write|Edit) : ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
[ -z "$FILE_PATH" ] && exit 0

# --- Resolve symlinks — classify both original and target -------------------

if [ -L "$FILE_PATH" ]; then
  RESOLVED=$(readlink -f "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
else
  RESOLVED="$FILE_PATH"
fi

# --- Criterion 2: extension allow-list --------------------------------------

BASENAME=$(basename "$FILE_PATH")
EXT="${BASENAME##*.}"
# Handle dotfiles / no-extension files
if [ "$EXT" = "$BASENAME" ]; then
  EXT=""
fi

case "$BASENAME" in
  .gitignore) EXT="gitignore" ;;
  .gitattributes) EXT="gitattributes" ;;
esac

allowed_ext() {
  case "$1" in
    md|yml|yaml|json|toml|ini|txt|gitignore|gitattributes) return 0 ;;
    *) return 1 ;;
  esac
}

allowed_ext "$EXT" || exit 0

# --- Criterion 3: excluded app-code paths -----------------------------------

is_app_code() {
  local p="$1"
  case "$p" in
    */services/*/src/*|services/*/src/*) return 0 ;;
    */packages/*/src/*|packages/*/src/*) return 0 ;;
  esac
  return 1
}

if is_app_code "$FILE_PATH" || is_app_code "$RESOLVED"; then
  exit 0
fi

# --- Criterion 4: security-sensitive paths ----------------------------------

is_security_sensitive() {
  local p="$1"
  local base
  base=$(basename "$p")

  # --- Self-modification class: AI agent config, enforcement infra ---------
  case "$base" in
    CLAUDE.md|AGENTS.md|GEMINI.md) return 0 ;;
  esac
  # Dotdir-rule paths: any directory starting with `.` that hosts orchestrator
  # rules or per-tool config (.claude/, .cursor/, .github/, and any consumer-
  # defined .<orchestrator>-rule-details/ such as .aidlc-rule-details/) is
  # treated as self-modification — fast-lane never bypasses these.
  case "$p" in
    */.claude/*|.claude/*|*/.claude|.claude) return 0 ;;
    */.cursor/*|.cursor/*) return 0 ;;
    */.github/*|.github/*) return 0 ;;
    # Generic: any dotdir matching .<name>-rule-details/ pattern
    */.[a-z]*-rule-details/*|.[a-z]*-rule-details/*) return 0 ;;
  esac

  # --- Supply-chain / runtime config ---------------------------------------
  case "$base" in
    package.json|package-lock.json|pnpm-lock.yaml|yarn.lock) return 0 ;;
    Makefile) return 0 ;;
    .npmrc|.yarnrc|.yarnrc.yml) return 0 ;;
  esac
  case "$base" in
    docker-compose*.yml|docker-compose*.yaml) return 0 ;;
    Dockerfile|Dockerfile.*) return 0 ;;
    tsconfig*.json) return 0 ;;
  esac

  # --- Reviewer-trust artifacts --------------------------------------------
  case "$base" in
    .gitignore|.gitattributes|.gitmodules) return 0 ;;
  esac

  # --- Env files -----------------------------------------------------------
  case "$p" in
    */.env|*/.env.*|.env|.env.*) return 0 ;;
    *.env|*.env.*) return 0 ;;
  esac
  case "$base" in
    .env|.env.*) return 0 ;;
  esac

  # --- Substring-sensitive segments: auth, crypto, guard, secret, credential
  # Walk each path segment (split on /) and match via case glob. This catches
  # authenticator/, crypto-utils.md, someguard/, secrets-rotation.md, etc.
  local IFS='/'
  local seg
  # shellcheck disable=SC2086
  set -- $p
  for seg in "$@"; do
    case "$seg" in
      *auth*|*crypto*|*guard*|*secret*|*credential*) return 0 ;;
    esac
  done

  return 1
}

if is_security_sensitive "$FILE_PATH" || is_security_sensitive "$RESOLVED"; then
  exit 0
fi

# --- Compute "old content" and "new content" for Edit vs Write --------------

OLD_CONTENT=""
NEW_CONTENT=""

if [ "$TOOL_NAME" = "Edit" ]; then
  OLD_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""')
  NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
else
  # Write: new_content is tool_input.content; old_content is existing file (if any)
  NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""')
  if [ -f "$FILE_PATH" ]; then
    OLD_CONTENT=$(cat "$FILE_PATH")
  fi
fi

# --- Criterion 5: diff size threshold ---------------------------------------

count_lines() {
  if [ -z "$1" ]; then echo 0; return; fi
  printf '%s' "$1" | awk 'END{print NR}'
}

OLD_LINES=$(count_lines "$OLD_CONTENT")
NEW_LINES=$(count_lines "$NEW_CONTENT")

TOTAL=$((OLD_LINES + NEW_LINES))

advise_and_defer() {
  local reason="$1"
  if [ "$MODE" = "warn" ]; then
    echo "FAST-LANE advisory: $reason (would defer to Layer 1 deny list)" >&2
  fi
  exit 0
}

if [ "$TOTAL" -gt 10 ]; then
  advise_and_defer "diff size $TOTAL exceeds 10-line threshold"
fi

# --- Criterion 6 & 7: no new symbols ----------------------------------------

SYMBOL_PATTERNS='^[[:space:]]*import[[:space:]]|^[[:space:]]*from[[:space:]].*[[:space:]]import[[:space:]]|require\(|^[[:space:]]*export[[:space:]]|module\.exports|^[[:space:]]*function[[:space:]]|^[[:space:]]*def[[:space:]]|^[[:space:]]*class[[:space:]]|=>[[:space:]]*\{|\)[[:space:]]*\{[[:space:]]*$'

count_symbols() {
  if [ -z "$1" ]; then echo 0; return; fi
  local n
  n=$(printf '%s' "$1" | grep -cE "$SYMBOL_PATTERNS" 2>/dev/null || true)
  echo "${n:-0}"
}

OLD_SYMBOLS=$(count_symbols "$OLD_CONTENT")
NEW_SYMBOLS=$(count_symbols "$NEW_CONTENT")

if [ "$NEW_SYMBOLS" -gt "$OLD_SYMBOLS" ]; then
  advise_and_defer "introduces new import/export/function/class symbol"
fi

# --- All criteria met → emit permissionDecision: allow ----------------------

REASON="FAST-LANE (VI-130): mechanical edit on Class A non-app path — ext=$EXT, diff=${TOTAL}L, no new symbols"

jq -cn --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r}}'

exit 0
