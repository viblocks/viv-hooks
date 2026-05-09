#!/usr/bin/env bash
# lib/path-utils.sh — pure path helpers used by enforce-* hooks.
#
# Functions:
#   canonicalize <path>          : echoes absolute, symlink-resolved path
#                                  (or empty on failure — fail-closed for caller)
#   is_under <target> <root>     : returns 0 if target is root or descendant,
#                                  1 otherwise
#   is_class_a <path> <pat...>   : returns 0 if path (case-insensitive) matches
#                                  ANY of the supplied glob patterns
#                                  (parameterized — no hard-coded class)

# Resolve an absolute, symlink-followed path. Returns empty string on failure
# (caller MUST treat empty as fail-closed and block).
canonicalize() {
  local p="$1"
  [ -z "$p" ] && { echo ""; return 0; }
  local out
  if command -v realpath >/dev/null 2>&1; then
    if out=$(realpath -m "$p" 2>/dev/null); then
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    if out=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null); then
      if [ -n "$out" ]; then echo "$out"; return 0; fi
    fi
  fi
  # Fallback: if already absolute, just normalize trailing slash.
  if [ "${p#/}" != "$p" ]; then
    # Strip trailing slashes (but keep "/" itself).
    while [ "${p}" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    echo "$p"; return 0
  fi
  local dir base
  dir=$(dirname "$p" 2>/dev/null || echo "")
  base=$(basename "$p" 2>/dev/null || echo "")
  if [ -n "$dir" ] && [ -n "$base" ] && (unset CDPATH; cd "$dir" 2>/dev/null); then
    out="$(unset CDPATH; cd "$dir" 2>/dev/null && printf '%s/%s\n' "$PWD" "$base")"
    if [ -n "$out" ]; then echo "$out"; return 0; fi
  fi
  echo ""
}

# is_under <target> <root>
# Returns 0 if target is root or strictly under root.
is_under() {
  local target="$1" root="$2"
  [ -z "$target" ] && return 1
  [ -z "$root" ] && return 1
  case "$target" in
    "$root"|"$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# is_class_a <path> [pattern1 pattern2 ...]
# Returns 0 if path matches any of the supplied glob patterns
# (case-insensitive, APFS-friendly). With zero patterns, returns 1.
is_class_a() {
  local p="$1"; shift
  [ -z "$p" ] && return 1
  [ "$#" -eq 0 ] && return 1
  local pat matched=1
  shopt -s nocasematch
  for pat in "$@"; do
    # shellcheck disable=SC2254
    case "$p" in
      $pat) matched=0; break ;;
    esac
  done
  shopt -u nocasematch
  return $matched
}
