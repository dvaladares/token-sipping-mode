#!/bin/bash
# Prove mcp-health.sh reports DOWN, and prove a reconnect clears it.
# A gauge that has never been seen to alarm is not a gauge.
set -uo pipefail
T=$(mktemp -d)
S=$HOME/.claude/limit-sentinel/mcp-health.sh

# A fake claude home with two configured servers.
mkdir -p "$T/home"
cat > "$T/home/.claude.json" <<'JSON'
{"mcpServers": {"alpha": {}, "beta": {}}}
JSON

echo "=== CASE 1: healthy, one server served a call ==="
cat > "$T/t1.jsonl" <<'JSON'
{"attributionMcpServer":"alpha","attributionMcpTool":"do_thing"}
JSON
rm -f "$HOME/.cache/mcp-health-home.cache"
bash "$S" "$T/t1.jsonl" "$T/home"; echo

echo "=== CASE 2: a server DISCONNECTED, must show DOWN ==="
cat > "$T/t2.jsonl" <<'JSON'
{"attributionMcpServer":"alpha","attributionMcpTool":"do_thing"}
{"text":"The following deferred tools are no longer available (MCP server disconnected): mcp__beta__query"}
JSON
rm -f "$HOME/.cache/mcp-health-home.cache"
OUT2=$(bash "$S" "$T/t2.jsonl" "$T/home"); echo "$OUT2"
case "$OUT2" in
  *DOWN*beta*) echo "  PASS: DOWN fired and named beta" ;;
  *)           echo "  FAIL: a disconnect did not raise DOWN" ; exit 1 ;;
esac
echo

echo "=== CASE 3: reconnect must CLEAR the DOWN ==="
cat > "$T/t3.jsonl" <<'JSON'
{"attributionMcpServer":"alpha","attributionMcpTool":"do_thing"}
{"text":"The following deferred tools are no longer available (MCP server disconnected): mcp__beta__query"}
{"text":"50 deferred tools are available again (MCP server reconnected): mcp__beta__query"}
JSON
rm -f "$HOME/.cache/mcp-health-home.cache"
OUT3=$(bash "$S" "$T/t3.jsonl" "$T/home"); echo "$OUT3"
case "$OUT3" in
  *DOWN*) echo "  FAIL: DOWN stuck after a reconnect" ; exit 1 ;;
  *)      echo "  PASS: reconnect cleared it" ;;
esac
echo

echo "=== CASE 4: no data at all, must print NOTHING, not a fake zero ==="
mkdir -p "$T/empty"
rm -f "$HOME/.cache/mcp-health-empty.cache"
OUT4=$(bash "$S" "/nonexistent/path.jsonl" "$T/empty")
if [ -z "$OUT4" ]; then echo "  PASS: printed nothing"; else echo "  FAIL: invented '$OUT4'"; exit 1; fi

rm -rf "$T"
echo
echo "ALL CASES PASS"
