#!/usr/bin/env bash
# lib/routing-loader.sh — read routing-table.json and project Class A patterns.
#
# Per ADR-RD-003 (single routing file) and ADR-RD-004 (classifier folded), the
# Class A pattern set is DERIVED from routing-table.json — it is NOT a separate
# hardcoded array.
#
# Per ADR-RD-008 (pure descriptors), this loader lives here (in viv-hooks, the
# only code repo) rather than in viv-routing.
#
# Resolution order for routing-table.json:
#   1. CLAUDE_HOOKS_ROUTING_TABLE env var (explicit override)
#   2. <CLAUDE_PROJECT_DIR>/.claude/routing/routing-table.json
#   3. <CLAUDE_PROJECT_DIR>/.claude/context/routing-table.json (legacy viblocks)
#   4. <PWD>/.claude/routing/routing-table.json
#
# Functions:
#   resolve_routing_table_path        : echo absolute path, or empty if missing
#   load_class_a_patterns             : echo glob patterns (one per line) for
#                                        all routes with enforced=true
#   load_class_a_patterns_array <name> : populate <name>[] with bash-glob
#                                        variants (path/* and */path/* forms)
#   route_for_path <abs-path>          : echo {domain, implementer, reviewer}
#                                        JSON, or empty if unmatched
#   reviewer_for_implementer <name>   : echo reviewer agent (per pairings)
#
# Required dependencies (caller must source first):
#   - lib/path-utils.sh

resolve_routing_table_path() {
  local explicit="${CLAUDE_HOOKS_ROUTING_TABLE:-}"
  if [ -n "$explicit" ] && [ -f "$explicit" ]; then
    echo "$explicit"
    return 0
  fi
  local proj="${CLAUDE_PROJECT_DIR:-$PWD}"
  for candidate in \
    "$proj/.claude/routing/routing-table.json" \
    "$proj/.claude/context/routing-table.json" \
    "$PWD/.claude/routing/routing-table.json"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  echo ""
}

# load_class_a_patterns — echo one glob pattern per line, derived from routes
# where enforced==true. Includes both `path` and `*/path` variants for matching
# against absolute and relative paths.
load_class_a_patterns() {
  local rt
  rt=$(resolve_routing_table_path)
  [ -z "$rt" ] && return 0
  jq -r '
    .routes[]
    | select(.enforced == true)
    | .paths[]
  ' "$rt" 2>/dev/null
}

# load_class_a_patterns_array <name> — populate the named bash array with both
# raw and absolute-style variants of each pattern. Caller passes a nameref via
# `local -n out=$1`.
load_class_a_patterns_array() {
  local _name="$1"
  # Bash 4.3+ namerefs.
  if ! declare -p "$_name" >/dev/null 2>&1; then
    eval "$_name=()"
  fi
  local pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    # Both forms: bare (matches against canonicalized absolute path tail) and
    # absolute-prefix (matches against full canonical path).
    eval "$_name+=(\"\$pat\" \"*/\$pat\")"
  done < <(load_class_a_patterns)
}

# route_for_path <abs-path>
# Echoes the JSON of the longest-match route, or empty if unmatched.
# Per viv-routing ADR-001, longest-path-match wins on conflict.
route_for_path() {
  local target="$1"
  local rt
  rt=$(resolve_routing_table_path)
  [ -z "$rt" ] && { echo ""; return 0; }
  jq -c --arg t "$target" '
    def literal_segs(p): (p | split("/") | map(select(test("^[^*?[]+$"))) | length);
    [ .routes[]
      | . as $route
      | .paths[]
      | . as $pat
      | select( $t | test( ($pat | gsub("\\*\\*"; ".*") | gsub("\\*"; "[^/]*") )) )
      | { route: $route, score: literal_segs($pat) }
    ]
    | sort_by(-.score)
    | .[0].route // empty
  ' "$rt" 2>/dev/null
}

# reviewer_for_implementer <implementer-name>
# Reads implementer-reviewer-pairings.json (default_rule: from-routing-table)
# and routing-table.json. Echoes the reviewer agent name, or empty.
reviewer_for_implementer() {
  local impl="$1"
  local rt
  rt=$(resolve_routing_table_path)
  [ -z "$rt" ] && { echo ""; return 0; }
  # Check overrides first, then derive from routing-table.
  local pairings="${CLAUDE_HOOKS_PAIRINGS_FILE:-${CLAUDE_PROJECT_DIR:-$PWD}/.claude/workflows/implementer-reviewer-pairings.json}"
  if [ -f "$pairings" ]; then
    local override
    override=$(jq -r --arg i "$impl" '
      (.overrides // [])[]
      | select(.implementer == $i)
      | .reviewer // ""
    ' "$pairings" 2>/dev/null | head -n1)
    if [ -n "$override" ]; then
      echo "$override"
      return 0
    fi
  fi
  # Default rule: derive from routing.
  jq -r --arg i "$impl" '
    .routes[]
    | select(.implementer == $i)
    | .reviewer // ""
  ' "$rt" 2>/dev/null | head -n1
}
