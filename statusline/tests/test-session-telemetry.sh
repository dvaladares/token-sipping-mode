#!/bin/bash
# lib/session-telemetry.py against a synthetic transcript: hit rate, a full rebuild, the
# TTL countdown and a compaction, all with a pinned "now" so the numbers are exact.
HERE=$(cd "$(dirname "$0")" && pwd)
P="$HERE/../gauges/session-telemetry.py"
T=$(mktemp -d)
NOW=1788300000            # pinned
fail=0
u() { # ts_offset_s read write eph1h -> one assistant line
  printf '{"type":"assistant","timestamp":"%s","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":5,"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":0}}}}\n' \
    "$(python3 -c "import datetime;print(datetime.datetime.fromtimestamp($NOW+$1,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")" "$2" "$3" "$4"
}
{
  u -3000 0      120000 120000     # full rebuild 50 min ago
  u -2400 120000 500    500
  printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s","compactMetadata":{"trigger":"auto","preTokens":150000,"postTokens":20000}}\n' \
    "$(python3 -c "import datetime;print(datetime.datetime.fromtimestamp($NOW-1800,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")"
  u -1700 20000  300    300
  u -600  20300  200    200        # last call 10 min ago -> ttl left = 3600-600 = 3000
} > "$T/t.jsonl"

out=$(python3 "$P" "$T/t.jsonl" "$NOW")
echo "$out" | sed 's/^/  /'
chk() { if echo "$out" | grep -q "^$1 $2\$"; then echo "  PASS: $1 = $2"; else echo "  FAIL: expected '$1 $2'"; fail=1; fi; }
chk rebuild_kind OLD
chk rebuild_size 120000
chk rebuild_age_s 3000
chk ttl_kind 1h
chk ttl_left_s 3000
chk last_api_age_s 600
chk compact_n 1
chk compact_age_s 1800
chk compact_pre 150000
chk compact_post 20000
# hit rate over 4 calls: reads 160300 / (reads 160300 + writes 121000 + input 40) = 56.98%, floored
chk cache_pct 56

echo "=== no file: prints nothing, exit 0 ==="
o=$(python3 "$P" /nonexistent/x.jsonl "$NOW"; echo "rc=$?")
[ "$o" = "rc=0" ] && echo "  PASS" || { echo "  FAIL: '$o'"; fail=1; }

rm -rf "$T"
echo
[ "$fail" = "0" ] && echo "ALL TELEMETRY CASES PASS" || { echo "TELEMETRY TESTS FAILED"; exit 1; }
