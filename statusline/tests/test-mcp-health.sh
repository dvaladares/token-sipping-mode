#!/bin/bash
# Prove lib/mcp-health.sh reports DOWN, and prove a reconnect clears it.
# A gauge that has never been seen to alarm is not a gauge.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/../gauges/mcp-health.sh"
T=$(mktemp -d)

# A fake claude home with two configured servers. The cache file is keyed by the home's
# basename, so use a unique one and clear it before each case.
H="$T/mcp-test-home-$$"
mkdir -p "$H"
cat > "$H/.claude.json" <<'JSON'
{"mcpServers": {"alpha": {}, "beta": {}}}
JSON
CACHE="$HOME/.cache/mcp-health-$(basename "$H").cache"
fail=0

echo "=== CASE 1: healthy, one server served a call ==="
printf '%s\n' '{"attributionMcpServer":"alpha","attributionMcpTool":"do_thing"}' > "$T/t1.jsonl"
rm -f "$CACHE"; OUT1=$(bash "$S" "$T/t1.jsonl" "$H"); echo "  $OUT1"
case "$OUT1" in *"2 cfg"*"1 live"*) echo "  PASS" ;; *) echo "  FAIL: expected '2 cfg · 1 live'"; fail=1 ;; esac

echo "=== CASE 2: a server DISCONNECTED, must show DOWN ==="
cat > "$T/t2.jsonl" <<'JSON'
{"attributionMcpServer":"alpha","attributionMcpTool":"do_thing"}
{"text":"The following deferred tools are no longer available (MCP server disconnected): mcp__beta__query"}
JSON
rm -f "$CACHE"; OUT2=$(bash "$S" "$T/t2.jsonl" "$H"); echo "  $OUT2"
case "$OUT2" in *DOWN*beta*) echo "  PASS: DOWN fired and named beta" ;; *) echo "  FAIL: a disconnect did not raise DOWN"; fail=1 ;; esac

echo "=== CASE 3: reconnect must CLEAR the DOWN ==="
cat > "$T/t3.jsonl" <<'JSON'
{"attributionMcpServer":"alpha","attributionMcpTool":"do_thing"}
{"text":"The following deferred tools are no longer available (MCP server disconnected): mcp__beta__query"}
{"text":"50 deferred tools are available again (MCP server reconnected): mcp__beta__query"}
JSON
rm -f "$CACHE"; OUT3=$(bash "$S" "$T/t3.jsonl" "$H"); echo "  $OUT3"
case "$OUT3" in *DOWN*) echo "  FAIL: DOWN stuck after a reconnect"; fail=1 ;; *) echo "  PASS: reconnect cleared it" ;; esac

echo "=== CASE 4: no data at all, must print NOTHING, not a fake zero ==="
E="$T/empty-home-$$"; mkdir -p "$E"
rm -f "$HOME/.cache/mcp-health-$(basename "$E").cache"
OUT4=$(bash "$S" "/nonexistent/path.jsonl" "$E")
if [ -z "$OUT4" ]; then echo "  PASS: printed nothing"; else echo "  FAIL: invented '$OUT4'"; fail=1; fi
rm -f "$HOME/.cache/mcp-health-$(basename "$E").cache" "$CACHE"

rm -rf "$T"
echo
[ "$fail" = "0" ] && echo "ALL MCP-HEALTH CASES PASS" || { echo "MCP-HEALTH TESTS FAILED"; exit 1; }
