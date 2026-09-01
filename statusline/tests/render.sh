#!/bin/bash
# Render the statusline against a fixture so a change can be SEEN before it ships.
#
#   tests/render.sh                    full fixture, this machine's default config dir
#   tests/render.sh edge               another fixture from tests/fixtures/
#   tests/render.sh path/to/input.json a captured real input (see ~/.cache/claude-statusline/last-input-*.json)
#   tests/render.sh full --plain       strip ANSI colour
#   tests/render.sh full --time        median of 7 renders, in ms
#
# Placeholders in a fixture: __TRANSCRIPT__ becomes the newest transcript under the
# config dir (so session telemetry has something real to read), __CWD__ becomes $PWD,
# __EXPIRES__ becomes now+45min and __LAST_MISS__ now-14min (so time fields are live).
# CLAUDE_CONFIG_DIR selects the seat, exactly as the harness does.
HERE=$(cd "$(dirname "$0")" && pwd)
SL="$HERE/../statusline.sh"
FX="${1:-full}"; shift 2>/dev/null
PLAIN=0; TIME=0
for a in "$@"; do case "$a" in --plain) PLAIN=1 ;; --time) TIME=1 ;; esac; done
[ -f "$FX" ] || FX="$HERE/fixtures/$FX.json"
[ -f "$FX" ] || { echo "no fixture: $FX" >&2; exit 2; }
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TP=$(ls -t "$CFG"/projects/*/*.jsonl 2>/dev/null | head -1)
NOW=$(date +%s)

render() {
  sed "s#__TRANSCRIPT__#$TP#g; s#__CWD__#$PWD#g; s#__EXPIRES__#$((NOW + 2700))#g; s#__LAST_MISS__#$((NOW - 840))#g" "$FX" \
    | CLAUDE_CONFIG_DIR="$CFG" bash "$SL"
}
ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

if [ "$TIME" = "1" ]; then
  render >/dev/null 2>&1                     # warm caches once
  ts=""
  for i in 1 2 3 4 5 6 7; do s=$(ms); render >/dev/null 2>&1; e=$(ms); ts="$ts $((e - s))"; done
  echo "$ts" | tr ' ' '\n' | grep . | sort -n | sed -n 4p
  exit 0
fi
# --plain strips SGR colour and OSC 8 hyperlinks (perl: BSD sed has no \x escapes in bracket expressions)
if [ "$PLAIN" = "1" ]; then render | perl -pe 's/\e\[[0-9;]*m//g; s/\e\]8;;.*?\e\\//g'; else render; fi
