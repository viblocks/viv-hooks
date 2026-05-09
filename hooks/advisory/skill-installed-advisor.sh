#!/usr/bin/env bash
# PostToolUse hook — skill-installed-advisor (ADVISORY type)
#
# Single Responsibility: when a skill file is installed/edited, advise the
# user/LLM to evaluate whether a corresponding workflow rule or hook is
# needed. Generic across consumers — no project-specific keywords.
#
# Triggers:
#   - Edit/Write to .claude/skills/<skill-name>/SKILL.md
#   - Edit/Write to .claude/skills/<skill-name>/patterns/**
#
# Modes:
#   disabled → bypass
#   warn or hard → emit advisory

set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }

MODE="${CLAUDE_HOOKS_MODE:-${AIDLC_ENFORCEMENT_MODE:-hard}}"
[ "$MODE" = "disabled" ] && exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')
case "$TOOL" in Edit|Write) ;; *) exit 0 ;; esac

FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
[ -z "$FP" ] && exit 0

case "$FP" in
  *.claude/skills/*/SKILL.md|*.claude/skills/*/patterns/*)
    # Extract skill name (best-effort: segment after .claude/skills/).
    SKILL_NAME=$(echo "$FP" | sed -nE 's|.*\.claude/skills/([^/]+)/.*|\1|p')
    [ -z "$SKILL_NAME" ] && SKILL_NAME="(unknown)"
    MSG="Skill '$SKILL_NAME' was modified. Consider: (1) does the skill change require an update to viv-workflows rule data? (2) is a new advisory hook needed? (3) should typed agents declare this skill in their frontmatter?"
    jq -cn --arg msg "$MSG" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$msg}}'
    ;;
esac

exit 0
