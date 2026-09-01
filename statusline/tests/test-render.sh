#!/bin/bash
# Behavioural tests. Every case states what MUST and MUST NOT appear, because the
# statusline's whole discipline is "omit, never fabricate": the negative cases matter
# as much as the positive ones.
#
# Fixture cases run under a DETERMINISTIC config (tests/config.test.sh) that turns off
# the machine-dependent sections (frugal, codex, delegation, mcp). One smoke case at the
# end runs with whatever config this machine really has.
HERE=$(cd "$(dirname "$0")" && pwd)
R="$HERE/render.sh"
export CLAUDE_STATUSLINE_CONFIG="$HERE/config.test.sh"
fail=0; pass=0
has()    { if printf '%s' "$1" | grep -q -- "$2"; then pass=$((pass+1)); else echo "  FAIL: expected '$2' in:"; printf '%s\n' "$1" | sed 's/^/    | /'; fail=$((fail+1)); fi; }
hasnot() { if printf '%s' "$1" | grep -q -- "$2"; then echo "  FAIL: did not expect '$2' in:"; printf '%s\n' "$1" | sed 's/^/    | /'; fail=$((fail+1)); else pass=$((pass+1)); fi; }

echo "== full fixture: every field with a source renders =="
out=$(bash "$R" full --plain)
has "$out" "Fable 5.1"
has "$out" "(claude-fable-5-1)"
has "$out" "someone@example.com"
has "$out" "[MAX 20x]"
has "$out" "(TESTSEAT)"
has "$out" "🤖 reviewer"
has "$out" "‹statusline v2›"
has "$out" "40%"
has "$out" "(80k/200k)"
has "$out" "⚡ 91% warm"
has "$out" "(ttl 45m)"
has "$out" "\$1.23"
has "$out" "cache miss 14m ago (2×, ~310k rewritten)"
has "$out" "example-org/example-repo"
has "$out" "+10"
has "$out" "−2"
has "$out" "🌳 steady-walrus"
has "$out" "xhigh"
has "$out" "⏱ 1h13m"
has "$out" "claude 5h"
has "$out" "claude 7d"
has "$out" "2 agents"
has "$out" "PR #4242"
has "$out" "approved"
hasnot "$out" ">200k"
hasnot "$out" "fast"
hasnot "$out" "frugal"

echo "== minimal fixture: nothing invented =="
out=$(bash "$R" minimal --plain)
has "$out" "Sonnet 5"
has "$out" "0%"
hasnot "$out" "claude 5h"
hasnot "$out" '[$][0-9]'
hasnot "$out" "agent"
hasnot "$out" "PR #"
hasnot "$out" "⏱"
hasnot "$out" "🌳"
hasnot "$out" "warm"

echo "== edge fixture: ISO resets, null subagents, team badge, >200k, vim, zero cost =="
out=$(bash "$R" edge --plain)
has "$out" "Opus 5 (1M context)"
has "$out" "92%"
has "$out" ">200k"
has "$out" "[ACME TEAM]"
has "$out" "claude 5h ●●●●●●●●●● 100%"
has "$out" "claude 7d ●●●●●●●○○○ 70%"
has "$out" "[NORMAL]"
hasnot "$out" "agent"
hasnot "$out" "\$0.00"
hasnot "$out" "⏱"
hasnot "$out" "value too great"

echo "== team5x fixture: team plan with a max_5x user tier keeps the TEAM badge =="
out=$(bash "$R" team5x --plain)
has "$out" "dev@acme.example"
has "$out" "[ACME TEAM 5x]"
hasnot "$out" "MAX 5x"
hasnot "$out" "claude 5h"

echo "== default seat: account read from ~/.claude.json even when ~/.claude/.claude.json exists without one =="
T=$(mktemp -d); mkdir -p "$T/.claude"
printf '{"mcpServers":{}}\n' > "$T/.claude/.claude.json"
printf '{"oauthAccount":{"emailAddress":"home@example.test","organizationType":"claude_pro"}}\n' > "$T/.claude.json"
out=$(env -u CLAUDE_CONFIG_DIR HOME="$T" bash "$R" minimal --plain)
rm -rf "$T"
has "$out" "home@example.test"
has "$out" "[PRO]"
hasnot "$out" "no account"

echo "== pro fixture: weekly only, never mislabeled as 5h =="
out=$(bash "$R" pro --plain)
has "$out" "[PRO]"
has "$out" "claude 7d ●●●○○○○○○○ 33%"
hasnot "$out" "claude 5h"

echo "== legacy fixture: no prompt_cache object, warm% derived from the transcript =="
out=$(bash "$R" legacy --plain)
has "$out" "% warm"
has "$out" "\$0.50"
hasnot "$out" "cache miss"

echo "== cold fixture: cold cache, recache cost, GitLab MR, draft =="
out=$(bash "$R" cold --plain)
has "$out" "⚡ cache COLD (~58k to recache)"
has "$out" "78% session"
has "$out" "cache miss 14m ago (1×, ~40k rewritten)"
has "$out" "MR #7"
has "$out" "draft"

echo "== narrow terminal: dim extras dropped, identity kept =="
out=$(COLUMNS=80 bash "$R" full --plain)
has "$out" "Fable 5.1"
has "$out" "someone@example.com"
hasnot "$out" "(claude-fable-5-1)"
hasnot "$out" "(80k/200k)"
hasnot "$out" "example-org/example-repo"

echo "== empty object: seat still named, exit 0 =="
out=$(echo '{}' | bash "$HERE/../statusline.sh"; echo "rc=$?")
has "$out" "rc=0"
has "$out" "👤"

echo "== no stdin at all: exit 0 =="
out=$(bash "$HERE/../statusline.sh" < /dev/null; echo "rc=$?")
has "$out" "rc=0"

echo "== render time (deterministic config) =="
t=$(bash "$R" full --time)
echo "  median of 7 renders: ${t} ms"
if [ "$t" -lt 250 ] 2>/dev/null; then pass=$((pass+1)); else echo "  FAIL: slower than 250 ms (harness debounce is 300 ms)"; fail=$((fail+1)); fi

echo "== smoke: this machine's real config renders and exits 0 =="
unset CLAUDE_STATUSLINE_CONFIG
out=$(bash "$R" full --plain; echo "rc=$?")
has "$out" "rc=0"
has "$out" "Fable 5.1"
t=$(bash "$R" full --time)
echo "  median of 7 renders with real config: ${t} ms"

echo
echo "passed $pass, failed $fail"
[ "$fail" = "0" ]
