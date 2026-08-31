#!/bin/bash
# mcp-health.sh — MCP connection gauge for the Claude Code statusline.
#
# WHY THIS EXISTS (2026-08-31, from the operator): "Those are the kinds of things I would catch
# myself fixing once and for all at the very beginning of a big long session, only to
# realize halfway through that it was broken."
#
# Measured the same day: aws-mcp dropped silently mid session and went unnoticed for
# hours. The retool tools disconnected and reconnected with nobody seeing either event.
# A disconnected MCP is invisible until you reach for it.
#
# WHAT IT REPORTS, and the distinction is the whole point:
#   cfg   servers configured in .claude.json, global scope plus this project's scope
#   live  servers that have SERVED A TOOL CALL in this session's transcript
#   DOWN  a server named in a disconnect notice with no later reconnect notice
#
# "live" is not "connected". A configured server that has served no call may be fine
# and simply unused. So an unseen server is reported as unseen, never as down. Only an
# actual disconnect notice produces DOWN.
#
# Usage: mcp-health.sh <transcript_path> <claude_home>
# Prints one short field, or nothing when there is no data to report.
set -uo pipefail

TPATH="${1:-}"
CHOME="${2:-$HOME/.claude}"
CACHE="$HOME/.cache/mcp-health-$(basename "$CHOME").cache"
TTL=45

# Serve from cache when fresh. A statusline render must never block.
if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$TTL" ]; then
    cat "$CACHE"
    exit 0
  fi
fi

OUT=$(python3 - "$TPATH" "$CHOME" <<'PY' 2>/dev/null
import json, os, re, sys, collections

tpath = sys.argv[1] if len(sys.argv) > 1 else ""
chome = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/.claude")

# --- configured servers, global scope plus the cwd project scope -------------
cfg = set()
try:
    d = json.load(open(os.path.join(chome, ".claude.json")))
    cfg |= set((d.get("mcpServers") or {}).keys())
    for _, pv in (d.get("projects") or {}).items():
        cfg |= set(((pv or {}).get("mcpServers") or {}).keys())
except Exception:
    pass

# --- what actually served a call, and what disconnected ---------------------
live = set()
down = set()
if tpath and os.path.exists(tpath):
    try:
        # Tail only. A long transcript must not cost a full read on every render.
        with open(tpath, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - 4_000_000))
            chunk = fh.read().decode("utf8", errors="ignore")
        for line in chunk.split("\n"):
            if '"attributionMcpServer"' in line:
                m = re.search(r'"attributionMcpServer"\s*:\s*"([^"]+)"', line)
                if m:
                    live.add(m.group(1))
            # Disconnect and reconnect notices arrive as plain text reminders.
            if "MCP server disconnected" in line or "no longer available" in line:
                for m in re.finditer(r'mcp__([A-Za-z0-9_.-]+?)__', line):
                    down.add(m.group(1))
            if "are available again" in line or "MCP server reconnected" in line:
                for m in re.finditer(r'mcp__([A-Za-z0-9_.-]+?)__', line):
                    down.discard(m.group(1))
    except Exception:
        pass

if not cfg and not live and not down:
    sys.exit(0)          # no data at all: print nothing rather than a fake zero

parts = []
if cfg:
    parts.append("%d cfg" % len(cfg))
if live:
    parts.append("%d live" % len(live))
if down:
    parts.append("DOWN " + ",".join(sorted(down)[:2]))

print("mcp " + " · ".join(parts))
PY
)

printf '%s' "$OUT" > "$CACHE"
printf '%s' "$OUT"
exit 0
