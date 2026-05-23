#!/usr/bin/env bash
# tests/fix-intent-gate.test.sh — integration tests for the intent-aware
# fix gate (hooks/advisory/fix-intent-gate.sh). Covers issue #2.
#
# Run from the repo root:
#   bash tests/fix-intent-gate.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/advisory/fix-intent-gate.sh"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Set up an isolated workflow dir + git repo so the hook resolves a
# known fix-intent-pattern.json and a controllable branch name.
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

WORKFLOWS_DIR="$TMP_ROOT/.claude/workflows"
mkdir -p "$WORKFLOWS_DIR"
cat > "$WORKFLOWS_DIR/fix-intent-pattern.json" <<'JSON'
{
  "version": "1.0",
  "trigger": { "agent_type_pattern": "implementer$" },
  "intent_keywords": [
    { "language": "en",
      "keywords": ["fix","bug","fail","broken","crash","failing","unexpected","regression","broke","breaking"] },
    { "language": "es",
      "keywords": ["falla","corregir","arreglar","roto","no funciona","rompi"] }
  ],
  "required_tokens": ["Root cause:","Causa raíz:","Causa raiz:"],
  "violation_message": "DEBUGGING GATE: falta Root cause/Causa raíz."
}
JSON
export CLAUDE_HOOKS_WORKFLOWS_DIR="$WORKFLOWS_DIR"

# Helper: prepare a fresh git repo on a given branch.
mkrepo() {
  local branch="$1"
  local dir="$TMP_ROOT/repo-$branch-$RANDOM"
  mkdir -p "$dir"
  git -C "$dir" init -q -b "$branch" 2>/dev/null \
    || { git -C "$dir" init -q; git -C "$dir" checkout -q -b "$branch"; }
  echo "$dir"
}

# Helper: run the hook with given stdin/branch/env and capture (exit_code, stdout).
# Usage: run_hook <branch> <prompt> [env_assignments...]
# Prints "EXIT=<n>\n<stdout>"
run_hook() {
  local branch="$1"; shift
  local prompt="$1"; shift
  local repo
  repo=$(mkrepo "$branch")
  local input
  input=$(jq -nc --arg sa "domain-implementer" --arg p "$prompt" \
    '{tool_name:"Agent", tool_input:{subagent_type:$sa, prompt:$p}}')
  local out rc
  # shellcheck disable=SC2086
  out=$(env -i PATH="$PATH" HOME="$HOME" \
      CLAUDE_HOOKS_WORKFLOWS_DIR="$CLAUDE_HOOKS_WORKFLOWS_DIR" \
      CLAUDE_PROJECT_DIR="$repo" \
      "$@" \
      bash "$HOOK" <<< "$input" 2>&1)
  rc=$?
  printf 'EXIT=%s\n%s' "$rc" "$out"
}

# Assertion: expect_pass — exit 0 (or other non-2), no Root cause msg.
expect_pass() {
  local name="$1" result="$2"
  local rc; rc=$(printf '%s' "$result" | head -n1 | sed 's/EXIT=//')
  local body; body=$(printf '%s' "$result" | tail -n +2)
  if [ "$rc" = "0" ] && ! echo "$body" | grep -qi "DEBUGGING GATE"; then
    ok "$name"
  else
    ko "$name" "rc=$rc body=$(echo "$body" | head -c 200)"
  fi
}

# Assertion: expect_advisory — exit 2 with the violation message.
expect_advisory() {
  local name="$1" result="$2"
  local rc; rc=$(printf '%s' "$result" | head -n1 | sed 's/EXIT=//')
  local body; body=$(printf '%s' "$result" | tail -n +2)
  if [ "$rc" = "2" ] && echo "$body" | grep -qi "DEBUGGING GATE"; then
    ok "$name"
  else
    ko "$name" "rc=$rc body=$(echo "$body" | head -c 200)"
  fi
}

echo "--- Issue #2 scenarios ---"

# 1. Intent: bugfix + Root cause present → pass.
R=$(run_hook main "Intent: bugfix
The login endpoint returns 500.
Root cause: missing null check on session token.")
expect_pass "1. explicit bugfix + Root cause" "$R"

# 2. Intent: bugfix + no marker → advisory.
R=$(run_hook main "Intent: bugfix
Login endpoint returns 500, please patch it.")
expect_advisory "2. explicit bugfix + no marker" "$R"

# 3. Intent: feature + no marker → pass (the original false-positive).
R=$(run_hook main "Intent: feature
Add new wallet creation endpoint for the WaaS product.")
expect_pass "3. explicit feature + no marker" "$R"

# 4. Intent: feature + artificial Root cause → pass (no rejection by excess).
R=$(run_hook main "Intent: feature
Build the dispatch panel UI.
Root cause: workaround preamble from old gate behavior.")
expect_pass "4. explicit feature + artificial Root cause" "$R"

# 5. Intent: refactor → pass.
R=$(run_hook main "Intent: refactor
Split the mega-class into three smaller modules.")
expect_pass "5. explicit refactor" "$R"

# 6. Branch fix/foo + no marker → advisory.
R=$(run_hook fix/login-500 "Login endpoint returns 500, please patch it.")
expect_advisory "6. branch fix/* + no marker" "$R"

# 7. Branch feat/bar + no marker → pass.
R=$(run_hook feat/wallet-create "Add new wallet creation endpoint.")
expect_pass "7. branch feat/* + no marker" "$R"

# 8. AIDLC_INTENT=bugfix overrides branch feat/* → advisory.
R=$(run_hook feat/wallet-create \
  "Patch the wallet bug." \
  AIDLC_INTENT=bugfix)
expect_advisory "8. env AIDLC_INTENT=bugfix beats branch feat/*" "$R"

# 9. Explicit Intent: bugfix overrides branch feat/* → advisory.
R=$(run_hook feat/wallet-create "Intent: bugfix
Patch the wallet bug.")
expect_advisory "9. explicit Intent: bugfix beats branch feat/*" "$R"

# 10. No signals (branch main, no env, no Intent:, neutral prompt) → pass.
R=$(run_hook main "Add a new helper function to the utils module.")
expect_pass "10. no signals → fail-open pass" "$R"

# 11. Causa raíz: (Spanish) counts equally with Root cause: — regression guard.
R=$(run_hook fix/cuentas "Intent: bugfix
La cuenta falla al crear.
Causa raíz: race condition en el upsert.")
expect_pass "11. Spanish Causa raíz: marker accepted" "$R"

# 12. CLAUDE_HOOKS_MODE=disabled → no-op on every path.
for branch in main fix/foo feat/bar; do
  R=$(run_hook "$branch" "anything goes here" CLAUDE_HOOKS_MODE=disabled)
  expect_pass "12. disabled on branch $branch" "$R"
done

# Strong heuristic: branch main + many bugfix keywords + no marker → advisory.
R=$(run_hook main "The login is broken, the dispatcher fails on every request, this is a regression.")
expect_advisory "13. heuristic ≥2 keywords + main branch + no marker" "$R"

# Weak heuristic: branch main + single weak keyword → pass (fail-open).
R=$(run_hook main "Add a new fix-it button to the settings panel.")
expect_pass "14. single keyword on neutral branch → fail-open pass" "$R"

# Empty subagent → pass-through (existing behavior).
INPUT_EMPTY='{"tool_name":"Agent","tool_input":{"subagent_type":"","prompt":"x"}}'
out=$(bash "$HOOK" <<< "$INPUT_EMPTY" 2>&1; echo "EXIT=$?")
rc=$(echo "$out" | tail -n1 | sed 's/EXIT=//')
if [ "$rc" = "0" ]; then ok "15. empty subagent → exit 0"; else ko "15. empty subagent → exit 0" "rc=$rc"; fi

# Non-implementer subagent → pass-through.
INPUT_REVIEWER=$(jq -nc '{tool_name:"Agent",tool_input:{subagent_type:"domain-reviewer",prompt:"fix the bug, Root cause missing"}}')
out=$(CLAUDE_HOOKS_WORKFLOWS_DIR="$CLAUDE_HOOKS_WORKFLOWS_DIR" bash "$HOOK" <<< "$INPUT_REVIEWER" 2>&1; echo "EXIT=$?")
rc=$(echo "$out" | tail -n1 | sed 's/EXIT=//')
if [ "$rc" = "0" ]; then ok "16. non-implementer subagent → exit 0"; else ko "16. non-implementer subagent → exit 0" "rc=$rc"; fi

echo ""
echo "Results: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
