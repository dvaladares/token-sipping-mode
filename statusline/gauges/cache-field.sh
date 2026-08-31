#!/bin/bash
# One compact statusline field: was the prompt cache rebuilt recently, and what did it cost?
#
# WHY (2026-08-31). A rebuild is invisible while it happens and expensive when it does.
# Measured this day: an MCP server flapped mid-session and cost ~75k written tokens with
# no restart and no user action. A second rebuild on restart cost 605k. Both were found
# HOURS later by digging through transcripts. Nothing surfaced them at the time.
#
# Output (nothing at all when there is no rebuild in the window):
#   cache ~605k rebuilt 14m ago      dim yellow, a partial or an old full
#   cache ~605k REBUILT 2m ago       bold red, a full rebuild in the last 10 minutes
#
# Caches for 90s. A statusline render must never block, so the caller wraps this in
# `guard`. Prints NOTHING when it cannot tell, never a zero.
set -uo pipefail

CACHE="$HOME/.cache/cache-field.cache"
TTL=90

if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$TTL" ] && { cat "$CACHE"; exit 0; }
fi

OUT=$(python3 - <<'PY' 2>/dev/null
import datetime, glob, json, os

CUT = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=3)
rows = []
for pat in tuple(p + "/projects/*/*.jsonl" for p in os.environ.get("CLAUDE_TRANSCRIPT_DIRS", "~/.claude").split()):
    for f in glob.glob(os.path.expanduser(pat)):
        try:
            if datetime.datetime.fromtimestamp(os.path.getmtime(f), datetime.timezone.utc) < CUT:
                continue
            fh = open(f, errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"cache_creation_input_tokens"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                u = (d.get("message") or {}).get("usage") or {}
                ts = d.get("timestamp")
                if not u or not ts:
                    continue
                try:
                    t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                except ValueError:
                    continue
                if t < CUT:
                    continue
                rows.append((t, u.get("cache_read_input_tokens", 0) or 0,
                             u.get("cache_creation_input_tokens", 0) or 0))
rows.sort()
last = None
for t, rd, wr in rows:
    if (rd == 0 and wr >= 20000) or (rd > 0 and wr >= 50000):
        if last is None or (t - last[0]).total_seconds() > 3 or wr != last[1]:
            last = (t, wr)
if not last:
    raise SystemExit(0)           # no rebuild: print nothing
t, wr = last
mins = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 60.0
size = f"{wr/1000:.0f}k" if wr < 1_000_000 else f"{wr/1_000_000:.1f}M"
when = f"{mins:.0f}m" if mins < 90 else f"{mins/60:.1f}h"
print(("HOT " if mins <= 10 else "OLD ") + f"{size} {when}")
PY
)

FIELD=""
if [ -n "$OUT" ]; then
  set -- $OUT
  kind="$1"; size="$2"; when="$3"
  if [ "$kind" = "HOT" ]; then
    FIELD=$(printf '\033[1;38;5;203mcache ~%s REBUILT %s ago\033[0m' "$size" "$when")
  else
    FIELD=$(printf '\033[2;38;5;221mcache ~%s rebuilt %s ago\033[0m' "$size" "$when")
  fi
fi

mkdir -p "$HOME/.cache" 2>/dev/null
printf '%s' "$FIELD" > "$CACHE"
printf '%s' "$FIELD"
exit 0
