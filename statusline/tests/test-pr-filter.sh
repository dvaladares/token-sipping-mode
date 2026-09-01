#!/bin/bash
# Prove the merged/closed PR filter fires in BOTH directions.
# A filter never seen to KEEP something is indistinguishable from one that hides
# everything. Both cases must be checked.
#
# Self-contained: builds a throwaway CLAUDE_CONFIG_DIR holding a gh-pr-status-cache.json
# with known states, so the test does not depend on any real PR cache on this machine.
HERE=$(cd "$(dirname "$0")" && pwd)
SL="$HERE/../statusline.sh"
T=$(mktemp -d)
mkdir -p "$T/home"
cat > "$T/home/gh-pr-status-cache.json" <<'JSON'
{
  "https://github.com/acme/app/pull/1579":  {"number": 1579, "state": "MERGED"},
  "https://github.com/acme/app/pull/191":   {"number": 191,  "state": "CLOSED"},
  "https://github.com/acme/site/pull/214":  {"number": 214,  "state": "MERGED"},
  "https://github.com/acme/app/pull/214":   {"number": 214,  "state": "CLOSED"},
  "https://github.com/acme/site/pull/300":  {"number": 300,  "state": "MERGED"},
  "https://github.com/acme/app/pull/300":   {"number": 300,  "state": "OPEN"},
  "https://github.com/acme/app/pull/5":     {"number": 5,    "state": "OPEN"}
}
JSON
export CLAUDE_STATUSLINE_CONFIG="$HERE/config.test.sh"

render_with_pr() {
  cat <<JSON | CLAUDE_CONFIG_DIR="$T/home" bash "$SL" 2>/dev/null | perl -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;.*?\e\\//g'
{"model":{"display_name":"Opus 5","id":"opus"},"cwd":"$PWD","cost":{"total_cost_usd":1},
 "context_window":{"context_window_size":1000000,"total_input_tokens":1000,"used_percentage":10},
 "pr":{"number":$1,"review_state":"approved"}}
JSON
}

fail=0
check_hidden() { if render_with_pr "$1" | grep -q "PR #$1"; then echo "  FAIL: #$1 ($2) is still displayed"; fail=1; else echo "  PASS: #$1 ($2) hidden"; fi; }
check_shown()  { if render_with_pr "$1" | grep -q "PR #$1"; then echo "  PASS: #$1 ($2) shown"; else echo "  FAIL: #$1 ($2) was hidden"; fail=1; fi; }

echo "=== NEGATIVE: dead PRs must be hidden ==="
check_hidden 1579 "MERGED"
check_hidden 191  "CLOSED"
echo "=== COLLISION: one number, two repos, both dead -> hidden ==="
check_hidden 214  "MERGED+CLOSED"
echo "=== COLLISION: one number, two repos, one still OPEN -> shown (fail-safe) ==="
check_shown  300  "MERGED+OPEN"
echo "=== POSITIVE: open and unknown PRs must be shown ==="
check_shown  5      "OPEN"
check_shown  999999 "absent from cache: unknown is not dead"

rm -rf "$T"
echo
[ "$fail" = "0" ] && echo "ALL PR-FILTER CASES PASS" || { echo "PR-FILTER TESTS FAILED"; exit 1; }
