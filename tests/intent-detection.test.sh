#!/usr/bin/env bash
# tests/intent-detection.test.sh — unit tests for lib/intent-detection.sh.
#
# Run from the repo root:
#   bash tests/intent-detection.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/intent-detection.sh"

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 (expected '$2', got '$3')"; FAIL=$((FAIL+1)); }

# expect <label> <expected> <actual>
expect() {
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "$2" "$3"; fi
}

# Always start each case with env clean to avoid leakage.
clear_env() {
  unset AIDLC_INTENT AIDLC_STEP_TYPE
}

echo "--- viv_intent_normalize ---"
expect "normalize bugfix"      "bugfix"  "$(viv_intent_normalize "bugfix")"
expect "normalize BUGFIX upper" "bugfix"  "$(viv_intent_normalize "BUGFIX")"
expect "normalize hotfix"       "bugfix"  "$(viv_intent_normalize "hotfix")"
expect "normalize incident"     "bugfix"  "$(viv_intent_normalize "incident")"
expect "normalize feat alias"   "feature" "$(viv_intent_normalize "feat")"
expect "normalize Feature"      "feature" "$(viv_intent_normalize "Feature")"
expect "normalize refactor"     "refactor" "$(viv_intent_normalize "refactor")"
expect "normalize docs"         "docs"     "$(viv_intent_normalize "docs")"
expect "normalize chore"        "chore"    "$(viv_intent_normalize "chore")"
expect "normalize empty"        ""         "$(viv_intent_normalize "")"
expect "normalize unknown"      ""         "$(viv_intent_normalize "nonsense")"

echo "--- viv_intent_from_prompt ---"
expect "explicit Intent: bugfix" "bugfix" \
  "$(viv_intent_from_prompt $'Some context\nIntent: bugfix\nmore text')"
expect "explicit Intent: feature lowercase" "feature" \
  "$(viv_intent_from_prompt 'intent: feature stuff')"
expect "explicit Intent: refactor" "refactor" \
  "$(viv_intent_from_prompt $'\nIntent:   refactor\n')"
expect "no Intent: line returns empty" "" \
  "$(viv_intent_from_prompt 'just normal text')"
expect "Intent: unknown value normalized away" "" \
  "$(viv_intent_from_prompt 'Intent: random')"

echo "--- viv_intent_from_branch ---"
expect "branch fix/foo"             "bugfix"   "$(viv_intent_from_branch fix/foo)"
expect "branch hotfix/x"            "bugfix"   "$(viv_intent_from_branch hotfix/x)"
expect "branch bug/oops"            "bugfix"   "$(viv_intent_from_branch bug/oops)"
expect "branch feat/bar"            "feature"  "$(viv_intent_from_branch feat/bar)"
expect "branch feature/baz"         "feature"  "$(viv_intent_from_branch feature/baz)"
expect "branch refactor/old"        "refactor" "$(viv_intent_from_branch refactor/old)"
expect "branch docs/readme"         "docs"     "$(viv_intent_from_branch docs/readme)"
expect "branch chore/deps"          "chore"    "$(viv_intent_from_branch chore/deps)"
expect "branch dependabot/npm/foo"  "chore"    "$(viv_intent_from_branch dependabot/npm/foo)"
expect "branch main → empty"        ""         "$(viv_intent_from_branch main)"
expect "branch release/v1.2"        ""         "$(viv_intent_from_branch release/v1.2)"
expect "branch empty → empty"       ""         "$(viv_intent_from_branch "")"

echo "--- viv_intent_detect precedence ---"

# 1. Explicit Intent: in prompt beats branch.
clear_env
expect "explicit Intent: feature beats branch fix/foo" "feature" \
  "$(viv_intent_detect 'Intent: feature' 'fix/foo' 0)"

# 2. AIDLC_INTENT env beats branch.
clear_env
AIDLC_INTENT=bugfix \
  expect "env AIDLC_INTENT=bugfix beats branch feat/x" "bugfix" \
    "$(AIDLC_INTENT=bugfix viv_intent_detect 'no marker' feat/x 0)"

# 3. AIDLC_STEP_TYPE env when AIDLC_INTENT empty.
clear_env
expect "env AIDLC_STEP_TYPE=feature beats branch fix/x" "feature" \
  "$(AIDLC_STEP_TYPE=feature viv_intent_detect 'plain' fix/x 0)"

# 4. Branch when no env, no explicit Intent:.
clear_env
expect "branch feat/x with no signals" "feature" \
  "$(viv_intent_detect 'plain text' feat/x 0)"

# 5. Keyword heuristic only when nothing else resolves.
clear_env
expect "≥2 keyword hits → bugfix"  "bugfix" \
  "$(viv_intent_detect 'plain' main 2)"
expect "1 keyword hit → unknown"   "unknown" \
  "$(viv_intent_detect 'plain' main 1)"
expect "0 keyword hits → unknown"  "unknown" \
  "$(viv_intent_detect 'plain' main 0)"

# 6. Explicit Intent: still beats env.
clear_env
expect "explicit Intent: docs beats AIDLC_INTENT=bugfix" "docs" \
  "$(AIDLC_INTENT=bugfix viv_intent_detect 'Intent: docs' fix/x 5)"

echo ""
echo "Results: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
