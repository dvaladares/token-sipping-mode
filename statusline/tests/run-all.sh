#!/bin/bash
# Run every suite. Exit non-zero if any fails.
HERE=$(cd "$(dirname "$0")" && pwd)
rc=0
for t in test-render.sh test-pr-filter.sh test-mcp-health.sh test-codex-weekly.sh test-session-telemetry.sh; do
  [ -f "$HERE/$t" ] || continue
  echo "################ $t"
  bash "$HERE/$t" || rc=1
  echo
done
[ "$rc" = "0" ] && echo "ALL SUITES PASS" || echo "SOME SUITES FAILED"
exit $rc
