#!/usr/bin/env bash
# lib/workflow-loader.sh — read workflow rule files from viv-workflows.
#
# Per ADR-RD-005, workflow rules are declarative data. Hooks consume them
# at runtime instead of embedding the rule logic in bash.
#
# Resolution order (per rule file):
#   1. CLAUDE_HOOKS_WORKFLOWS_DIR env var
#   2. <CLAUDE_PROJECT_DIR>/.claude/workflows/<rule-file>.json
#   3. <PWD>/.claude/workflows/<rule-file>.json
#
# Functions:
#   resolve_workflow_file <basename>     : echo absolute path or empty
#   load_evidence_required_markers       : echo one marker per line
#   load_audit_trail_pattern             : echo trailer name and value regex
#   load_fix_intent_keywords             : echo keywords (one per line, all langs)
#   load_fix_intent_required_tokens      : echo required tokens (one per line)
#   load_security_review_paths           : echo glob patterns (one per line)

resolve_workflow_file() {
  local base="$1"
  local explicit_dir="${CLAUDE_HOOKS_WORKFLOWS_DIR:-}"
  if [ -n "$explicit_dir" ] && [ -f "$explicit_dir/$base" ]; then
    echo "$explicit_dir/$base"
    return 0
  fi
  local proj="${CLAUDE_PROJECT_DIR:-$PWD}"
  for candidate in \
    "$proj/.claude/workflows/$base" \
    "$PWD/.claude/workflows/$base"; do
    if [ -f "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  echo ""
}

load_evidence_required_markers() {
  local f
  f=$(resolve_workflow_file "evidence-schema.json")
  [ -z "$f" ] && return 0
  jq -r '.required_fields[].marker' "$f" 2>/dev/null
}

load_audit_trail_trailer_name() {
  local f
  f=$(resolve_workflow_file "audit-trail-pattern.json")
  [ -z "$f" ] && return 0
  jq -r '.required_trailer.name' "$f" 2>/dev/null
}

load_audit_trail_value_pattern() {
  local f
  f=$(resolve_workflow_file "audit-trail-pattern.json")
  [ -z "$f" ] && return 0
  jq -r '.required_trailer.value_pattern' "$f" 2>/dev/null
}

load_audit_trail_editor_policy() {
  local f
  f=$(resolve_workflow_file "audit-trail-pattern.json")
  [ -z "$f" ] && { echo "block"; return 0; }
  jq -r '.editor_mode_policy // "block"' "$f" 2>/dev/null
}

load_fix_intent_keywords() {
  local f
  f=$(resolve_workflow_file "fix-intent-pattern.json")
  [ -z "$f" ] && return 0
  jq -r '.intent_keywords[].keywords[]' "$f" 2>/dev/null
}

load_fix_intent_required_tokens() {
  local f
  f=$(resolve_workflow_file "fix-intent-pattern.json")
  [ -z "$f" ] && return 0
  jq -r '.required_tokens[]' "$f" 2>/dev/null
}

load_fix_intent_agent_pattern() {
  local f
  f=$(resolve_workflow_file "fix-intent-pattern.json")
  [ -z "$f" ] && { echo "implementer$"; return 0; }
  jq -r '.trigger.agent_type_pattern' "$f" 2>/dev/null
}

load_fix_intent_violation_message() {
  local f
  f=$(resolve_workflow_file "fix-intent-pattern.json")
  [ -z "$f" ] && return 0
  jq -r '.violation_message // "DEBUGGING GATE: missing root cause token in implementer prompt."' "$f" 2>/dev/null
}

load_security_review_paths() {
  local f
  f=$(resolve_workflow_file "post-implementation-chain.json")
  [ -z "$f" ] && return 0
  jq -r '
    .stages[]
    | select(.kind == "security-review")
    | (.condition // {}).paths // []
    | .[]
  ' "$f" 2>/dev/null
}
