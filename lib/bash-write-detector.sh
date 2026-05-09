#!/usr/bin/env bash
# lib/bash-write-detector.sh — verb-agnostic write-target extraction.
#
# Replaces the brittle EDIT_PATTERNS denylist (enumerated edit verbs) with
# structural detection of write OPERATIONS:
#
#   1. Shell redirects:    >, >>, >|, &>, &>>  (covers ANY verb)
#   2. In-place editors:   sed -i, perl -i     (target = positional args)
#   3. Copy/move/install:  cp, mv, install, ln, rsync (target = last positional)
#   4. HTTP fetch:         curl -o/-O/--output, wget -O/--output-document/-o
#   5. Direct write tools: tee, dd of=, truncate
#
# Pure read commands are detected and short-circuited before write extraction.
#
# Functions:
#   extract_write_targets <cmd>     : echo path tokens (one per line) the cmd
#                                      may write to. Quotes stripped.
#   is_pure_read_command <cmd>      : returns 0 if cmd is a read-only operation.
#   is_class_a_token <path>         : (used by callers via is_class_a wrapper)
#
# Known limitations (documented, not fixed — out of scope per task):
#   - Process substitution `<(...)`, `>(...)` not parsed.
#   - Here-strings `<<<` not parsed.
#   - Pipelines: each segment is treated independently via the redirect scan,
#     but complex wrappings (eval, xargs sh -c) are NOT recursively analyzed.
#   - Quoted shell metachars inside single quotes treated as literal — fine.
#   - `tar -xf` writes filesystem but extracts to cwd or via -C flag — NOT
#     covered (use case unknown for self-mod). Add if a bypass surfaces.
#
# Design principle: detect WRITE OPERATIONS, not VERBS. Adding a new verb
# (e.g. `xxd > file`) requires no change here — the redirect scan catches it.

# _strip_quotes <token> : echo token with surrounding quotes removed.
_strip_quotes() {
  local t="$1"
  # Strip leading/trailing single OR double quotes.
  case "$t" in
    \'*\') t="${t#\'}"; t="${t%\'}" ;;
    \"*\") t="${t#\"}"; t="${t%\"}" ;;
  esac
  echo "$t"
}

# extract_redirect_targets <cmd> : echo each redirect target on its own line.
# Matches >, >>, >|, &>, &>> (single or double quoted, or bare).
_extract_redirect_targets() {
  local cmd="$1"
  # Use ERE to match redirect operator + optional whitespace + path token.
  # Token = a quoted string or a run of non-whitespace, non-pipe, non-redirect chars.
  # We do this with a multi-pass grep.
  #
  # Pattern explanation:
  #   (&?>{1,2}|>\|)   — &>, &>>, >, >>, >|
  #   [[:space:]]*     — optional spaces
  #   ('[^']+'         — single-quoted path
  #    |"[^"]+"        — double-quoted path
  #    |[^[:space:];&|<>]+) — bare path (no whitespace, no shell ops)
  echo "$cmd" | grep -oE "(&?>{1,2}\|?)[[:space:]]*('[^']+'|\"[^\"]+\"|[^[:space:];&|<>]+)" 2>/dev/null | \
    while IFS= read -r match; do
      # Strip the redirect operator prefix.
      local tok
      tok=$(echo "$match" | sed -E 's/^(&?>{1,2}\|?)[[:space:]]*//')
      tok=$(_strip_quotes "$tok")
      [ -n "$tok" ] && echo "$tok"
    done
}

# _extract_in_place_editor_targets <cmd> : for sed -i / perl -i, echo positional args.
_extract_in_place_editor_targets() {
  local cmd="$1"
  # Match `sed -i` or `sed --in-place` or `perl -i*` followed by the file list.
  # Approach: tokenize the whole command (split on whitespace, respecting quotes
  # is hard in bash; we do best-effort), find the verb+flag, then collect
  # subsequent non-flag tokens until end or a shell op.
  #
  # We use awk for tokenization, since it's already a hard dependency in this
  # codebase and handles word-splitting predictably.
  echo "$cmd" | awk '
    {
      # Replace shell separators with newlines so we can scan per-segment.
      gsub(/[;&|]/, "\n");
      print;
    }
  ' | while IFS= read -r segment; do
      # shellcheck disable=SC2086
      set -- $segment
      local verb="" want_files=0
      while [ $# -gt 0 ]; do
        case "$1" in
          sed)
            verb="sed"; shift
            # Look for -i or --in-place
            if [ $# -gt 0 ]; then
              case "$1" in
                -i|--in-place|-i*)
                  shift; want_files=1; continue
                  ;;
              esac
            fi
            ;;
          perl)
            verb="perl"; shift
            if [ $# -gt 0 ]; then
              case "$1" in
                -i|-i*) shift; want_files=1; continue ;;
              esac
            fi
            ;;
        esac
        if [ "$want_files" = "1" ]; then
          case "$1" in
            -*) shift; continue ;;
            "") break ;;
            *)
              local tok
              tok=$(_strip_quotes "$1")
              [ -n "$tok" ] && echo "$tok"
              ;;
          esac
        fi
        shift
      done
    done
}

# _extract_cp_mv_install_ln_targets <cmd> : last positional arg of cp/mv/install/ln/rsync.
_extract_cp_mv_install_ln_targets() {
  local cmd="$1"
  echo "$cmd" | awk '{ gsub(/[;&|]/, "\n"); print }' | while IFS= read -r segment; do
      # shellcheck disable=SC2086
      set -- $segment
      local verb=""
      while [ $# -gt 0 ]; do
        case "$1" in
          cp|mv|install|ln|rsync) verb="$1"; shift; break ;;
          *) shift ;;
        esac
      done
      [ -z "$verb" ] && continue
      # Collect remaining non-flag positional args.
      local args=()
      while [ $# -gt 0 ]; do
        case "$1" in
          -*)
            # Skip flags. Some flags take an arg (-m MODE, -t TARGET, --target=).
            # Best-effort: -m, -t, -T, --target, --target= are common.
            case "$1" in
              -m|-t|-T|--target|--mode|--owner|--group|--suffix|--backup)
                shift
                [ $# -gt 0 ] && shift
                ;;
              *) shift ;;
            esac
            ;;
          *)
            args+=("$1")
            shift
            ;;
        esac
      done
      local n=${#args[@]}
      [ "$n" -eq 0 ] && continue
      # For ln, rsync, cp, mv, install: last arg is destination.
      local last="${args[$((n-1))]}"
      local tok
      tok=$(_strip_quotes "$last")
      [ -n "$tok" ] && echo "$tok"
    done
}

# _extract_curl_wget_targets <cmd> : output paths from curl/wget.
_extract_curl_wget_targets() {
  local cmd="$1"
  # curl: -o <path>, -O (uses URL basename — not a literal path), --output <path>, --output=<path>
  #       Combined short flags: -sLo <path>, -qso <path> etc.
  # wget: -O <path>, --output-document=<path>, -o <logfile>
  echo "$cmd" | awk '{ gsub(/[;&|]/, "\n"); print }' | while IFS= read -r segment; do
      # shellcheck disable=SC2086
      set -- $segment
      local in_curl=0 in_wget=0
      while [ $# -gt 0 ]; do
        case "$1" in
          curl) in_curl=1; in_wget=0; shift; continue ;;
          wget) in_wget=1; in_curl=0; shift; continue ;;
        esac
        if [ "$in_curl" = "1" ]; then
          case "$1" in
            --output)
              shift; [ $# -gt 0 ] && { local tok; tok=$(_strip_quotes "$1"); [ -n "$tok" ] && echo "$tok"; }
              ;;
            --output=*)
              local tok="${1#--output=}"; tok=$(_strip_quotes "$tok"); [ -n "$tok" ] && echo "$tok"
              ;;
            -o)
              shift; [ $# -gt 0 ] && { local tok; tok=$(_strip_quotes "$1"); [ -n "$tok" ] && echo "$tok"; }
              ;;
            -*o)
              # Combined short flag like -sLo, -qso, -sso. Next arg is path.
              # Distinguish from -O (uppercase) which uses URL basename.
              case "$1" in
                -*O*o|-*o)
                  shift; [ $# -gt 0 ] && { local tok; tok=$(_strip_quotes "$1"); [ -n "$tok" ] && echo "$tok"; }
                  ;;
                *) shift ;;
              esac
              continue
              ;;
          esac
        fi
        if [ "$in_wget" = "1" ]; then
          case "$1" in
            --output-document)
              shift; [ $# -gt 0 ] && { local tok; tok=$(_strip_quotes "$1"); [ -n "$tok" ] && echo "$tok"; }
              ;;
            --output-document=*)
              local tok="${1#--output-document=}"; tok=$(_strip_quotes "$tok"); [ -n "$tok" ] && echo "$tok"
              ;;
            -O)
              shift; [ $# -gt 0 ] && { local tok; tok=$(_strip_quotes "$1"); [ -n "$tok" ] && echo "$tok"; }
              ;;
            -o)
              # Logfile — treat as write.
              shift; [ $# -gt 0 ] && { local tok; tok=$(_strip_quotes "$1"); [ -n "$tok" ] && echo "$tok"; }
              ;;
            -*O*)
              # Combined short flag like -qO, -sO. Next arg is path.
              shift; [ $# -gt 0 ] && { local tok; tok=$(_strip_quotes "$1"); [ -n "$tok" ] && echo "$tok"; }
              continue
              ;;
            -*o*)
              # Combined short flag containing lowercase o (logfile).
              shift; [ $# -gt 0 ] && { local tok; tok=$(_strip_quotes "$1"); [ -n "$tok" ] && echo "$tok"; }
              continue
              ;;
          esac
        fi
        shift
      done
    done
}

# _extract_tee_dd_truncate_targets <cmd>
_extract_tee_dd_truncate_targets() {
  local cmd="$1"
  echo "$cmd" | awk '{ gsub(/[;&|]/, "\n"); print }' | while IFS= read -r segment; do
      # shellcheck disable=SC2086
      set -- $segment
      while [ $# -gt 0 ]; do
        case "$1" in
          tee)
            shift
            # tee writes to all positional args (skip flags like -a, --append, -i).
            while [ $# -gt 0 ]; do
              case "$1" in
                -*) shift ;;
                *)
                  local tok
                  tok=$(_strip_quotes "$1")
                  [ -n "$tok" ] && echo "$tok"
                  shift
                  ;;
              esac
            done
            ;;
          dd)
            shift
            while [ $# -gt 0 ]; do
              case "$1" in
                of=*)
                  local tok="${1#of=}"; tok=$(_strip_quotes "$tok")
                  [ -n "$tok" ] && echo "$tok"
                  shift
                  ;;
                *) shift ;;
              esac
            done
            ;;
          truncate)
            shift
            while [ $# -gt 0 ]; do
              case "$1" in
                -*|*=*) shift ;;
                *)
                  local tok
                  tok=$(_strip_quotes "$1")
                  [ -n "$tok" ] && echo "$tok"
                  shift
                  ;;
              esac
            done
            ;;
          *) shift ;;
        esac
      done
    done
}

# extract_write_targets <cmd>
# Returns (on stdout, one per line) all paths the command may write to.
# Verb-agnostic: structural extraction across all detection categories.
extract_write_targets() {
  local cmd="$1"
  [ -z "$cmd" ] && return 0
  {
    _extract_redirect_targets "$cmd"
    _extract_in_place_editor_targets "$cmd"
    _extract_cp_mv_install_ln_targets "$cmd"
    _extract_curl_wget_targets "$cmd"
    _extract_tee_dd_truncate_targets "$cmd"
  } | awk 'NF' | sort -u
}

# is_pure_read_command <cmd>
# Returns 0 if cmd is a single-segment, single-verb read-only operation.
# Conservative — false negatives (treating safe commands as writes) only
# cost a follow-up extract_write_targets pass that finds nothing.
#
# A pure read requires ALL of:
#   - No shell separator (`;`, `|`, `&`, `&&`, `||`)
#   - No redirect operator (`>`, `>>`, `>|`, `&>`, etc.)
#   - No in-place editor flag (sed -i / perl -i)
#   - First token is a known read-only verb
is_pure_read_command() {
  local cmd="$1"
  [ -z "$cmd" ] && return 1
  # Strip leading whitespace.
  local stripped="${cmd#"${cmd%%[![:space:]]*}"}"
  # Reject if any shell composition operator present.
  # Pipelines: `cmd1 | cmd2` — second cmd may be a writer (e.g. tee).
  # Sequencing: `cmd1; cmd2`, `cmd1 && cmd2`, etc. — second may write.
  case "$stripped" in
    *"|"*|*";"*|*"&"*) return 1 ;;
  esac
  # Reject if any redirect operator present (write).
  case "$stripped" in
    *">"*) return 1 ;;
  esac
  # Reject if sed -i / perl -i present (in-place edit).
  if echo "$stripped" | grep -qE '(sed|perl)[[:space:]]+(-i|--in-place|-i[a-zA-Z]*)'; then
    return 1
  fi
  # Match first verb token (split on whitespace).
  local first_token="${stripped%%[[:space:]]*}"
  case "$first_token" in
    cat|less|more|head|tail|ls|file|stat|wc|grep|find|diff|awk|jq|git|echo|printf|true|false|test|\[|pwd|env|which|type|command|date|basename|dirname|readlink)
      # echo/printf without `>` is read (just prints). Same for awk without `>`.
      return 0
      ;;
  esac
  return 1
}

# is_class_a_token <path> [pattern1 pattern2 ...]
# Wrapper around is_class_a for clarity at call sites. Already case-insensitive
# via shopt -s nocasematch in is_class_a.
is_class_a_token() {
  is_class_a "$@"
}

# has_potential_write <cmd>
# Returns 0 if the command appears to perform any kind of write operation.
# Used for SEC-M3 fail-closed: if shell-subst is present and no literal target
# was extracted, we still need to know if the command is "write-shaped" to
# decide whether to fail closed.
has_potential_write() {
  local cmd="$1"
  [ -z "$cmd" ] && return 1
  # Any redirect operator → write.
  case "$cmd" in
    *">"*) return 0 ;;
  esac
  # Known write verbs (verb-agnostic for redirects, but for these we want the
  # bare verb to count as "potential write" even without an extractable target).
  if echo "$cmd" | grep -qE '(^|[[:space:];&|])(sed[[:space:]]+(-i|--in-place|-i[a-zA-Z]*)|perl[[:space:]]+-i|cp[[:space:]]|mv[[:space:]]|install[[:space:]]|ln[[:space:]]|rsync[[:space:]]|tee[[:space:]]|dd[[:space:]]+[^=]*of=|truncate[[:space:]]|python[23]?[[:space:]]+-c|node[[:space:]]+-e|curl[[:space:]].*-[a-zA-Z]*[oO]|wget[[:space:]].*-[a-zA-Z]*[oO]|curl[[:space:]].*--output|wget[[:space:]].*--output-document)'; then
    return 0
  fi
  return 1
}
