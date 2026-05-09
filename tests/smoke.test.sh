#!/usr/bin/env bash
# tests/smoke.test.sh — minimal sanity tests for viv-hooks.
#
# Verifies:
#   1. All hook scripts are syntactically valid bash.
#   2. All lib scripts are syntactically valid bash.
#   3. settings.json.fragment is valid JSON.
#   4. routing-loader and workflow-loader can be sourced without error.
#   5. Hooks exit 0 when CLAUDE_HOOKS_MODE=disabled.
#
# Run from the repo root:
#   bash tests/smoke.test.sh
#
# Exits non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "--- Bash syntax check (hooks/) ---"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "$f syntax"; else ko "$f syntax"; fi
done < <(find hooks -name '*.sh')

echo "--- Bash syntax check (lib/) ---"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "$f syntax"; else ko "$f syntax"; fi
done < <(find lib -name '*.sh')

echo "--- settings.json.fragment is valid JSON ---"
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json; json.load(open('settings.json.fragment'))" 2>/dev/null; then
    ok "settings.json.fragment parses"
  else
    ko "settings.json.fragment parses"
  fi
fi

echo "--- routing-loader sourceable ---"
if bash -c "source lib/path-utils.sh && source lib/routing-loader.sh && type resolve_routing_table_path >/dev/null" 2>/dev/null; then
  ok "routing-loader sources cleanly"
else
  ko "routing-loader sources cleanly"
fi

echo "--- workflow-loader sourceable ---"
if bash -c "source lib/workflow-loader.sh && type resolve_workflow_file >/dev/null" 2>/dev/null; then
  ok "workflow-loader sources cleanly"
else
  ko "workflow-loader sources cleanly"
fi

echo "--- Hooks exit 0 in disabled mode ---"
SAMPLE_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"src/foo.ts"}}'
for hook in hooks/deny/*.sh hooks/advisory/*.sh hooks/refinement/*.sh hooks/commit/*.sh; do
  out=$(echo "$SAMPLE_INPUT" | CLAUDE_HOOKS_MODE=disabled bash "$hook" 2>&1; echo "EXIT=$?")
  rc=$(echo "$out" | tail -n1 | sed 's/EXIT=//')
  if [ "$rc" = "0" ]; then ok "$hook exits 0 disabled"; else ko "$hook exits 0 disabled (got $rc)"; fi
done

echo ""
echo "Results: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
