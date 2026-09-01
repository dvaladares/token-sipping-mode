#!/bin/bash
# How much does each external process cost on THIS machine? A statusline is a budget of
# process spawns; know the unit price before optimising.
ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
bench() { # name, iterations, command...
  local name="$1" n="$2"; shift 2
  local s e i; s=$(ms)
  for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1 </dev/null; done
  e=$(ms); printf '  %-32s %4d ms each\n' "$name" $(( (e - s) / n ))
}
echo "spawn costs (avg):"
bench "true (baseline fork+exec)" 20 /usr/bin/true
bench "tr"        20 tr a b
bench "date"      20 date +%s
bench "sed"       20 sed -n 1p /dev/null
bench "readlink -f" 20 readlink -f /tmp
bench "jq '.a' on {}" 10 jq -n '.a'
bench "perl alarm wrapper" 10 perl -MTime::HiRes=alarm -e 'alarm(1); exec @ARGV' /usr/bin/true
bench "python3 -c pass" 5 python3 -c pass
bench "bash -c true" 10 bash -c true
bench "git rev-parse (here)" 10 git rev-parse --git-dir
bench "git branch --show-current" 10 git branch --show-current
bench "git status --porcelain" 5 git status --porcelain
