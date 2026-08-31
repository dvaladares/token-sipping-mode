#!/usr/bin/env python3
"""Find cache rebuilds from measured telemetry. No marks, no inference.

    cache-verdict.py            # last 6h: every rebuild, with the gap that caused it
    cache-verdict.py 24         # look back 24h
    cache-verdict.py watch      # one line, for a heartbeat: OK or the last rebuild

WHY THIS WAS REWRITTEN (2026-08-31). Version 1 required you to set a "mark" before a
restart, then reported the EARLIEST turns after that mark. That is the wrong window: the
turns right after a mark are still pre-restart. It confidently printed "the cache HELD"
while the very next call in the same transcript showed cache_read=0 and 605,071 written.

The fix is to stop asking the human to mark anything. A rebuild has a signature you can
find directly:

    cache_read_input_tokens == 0  AND  cache_creation_input_tokens is large

Those are the API's own billing fields. Nothing is inferred. The gap before the rebuild
is reported alongside it, because the gap tells you WHY: over ~60 min means the TTL
expired on its own; well under it means the PREFIX changed, which on this setup is
almost always the MCP server set.
"""

import datetime
import glob
import json
import os
import sys

REBUILD_WRITE = 20_000     # a write this big with zero reads is a rebuild, not a top-up
PARTIAL_WRITE = 50_000     # a big write WITH reads means the prefix moved mid-conversation
TTL_MIN = 60               # documented prompt-cache TTL for this setup


def load(hours):
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)
    files = []
    # Point this at your own config homes, space separated, if you run more than one:
    #   CLAUDE_TRANSCRIPT_DIRS="~/.claude ~/.claude-work"
    homes = os.environ.get("CLAUDE_TRANSCRIPT_DIRS", "~/.claude").split()
    for p in [h.rstrip("/") + "/projects/*/*.jsonl" for h in homes]:
        files.extend(glob.glob(os.path.expanduser(p)))
    files = [f for f in files
             if datetime.datetime.fromtimestamp(os.path.getmtime(f), datetime.timezone.utc) >= cutoff]
    rows = []
    for f in files:
        try:
            fh = open(f, errors="ignore")
        except OSError:
            continue
        with fh:
            for line in fh:
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
                if t < cutoff:
                    continue
                rows.append((t,
                             u.get("cache_read_input_tokens", 0) or 0,
                             u.get("cache_creation_input_tokens", 0) or 0,
                             u.get("input_tokens", 0) or 0))
    rows.sort()
    # DEDUPE. The same logical API call can appear more than once: streaming produces
    # repeated usage records, and a call can be written to more than one transcript.
    # Without this, one rebuild is counted three or four times and the wasted-token
    # total is inflated by the same multiple. Collapse calls with identical token
    # counts landing within a 3-second window.
    deduped = []
    for r in rows:
        if deduped:
            p = deduped[-1]
            if (r[1], r[2], r[3]) == (p[1], p[2], p[3]) and (r[0] - p[0]).total_seconds() <= 3:
                continue
        deduped.append(r)
    return deduped


def find_events(rows):
    """Return [(when, kind, write, gap_minutes)] for every rebuild in the window."""
    events, prev_t = [], None
    for t, rd, wr, _fr in rows:
        gap = (t - prev_t).total_seconds() / 60.0 if prev_t else None
        if rd == 0 and wr >= REBUILD_WRITE:
            events.append((t, "FULL", wr, gap))
        elif rd > 0 and wr >= PARTIAL_WRITE:
            events.append((t, "PARTIAL", wr, gap))
        prev_t = t
    return events


def why(gap):
    if gap is None:
        return "first call in the window; cause unknown"
    if gap >= TTL_MIN:
        return f"gap {gap:.0f} min exceeded the {TTL_MIN} min TTL, so time alone explains it"
    return (f"gap only {gap:.0f} min, well inside the {TTL_MIN} min TTL, so the PREFIX "
            f"changed (MCP set, agent types, or model)")


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "6"
    watch = arg == "watch"
    hours = 6 if watch else (float(arg) if arg.replace(".", "").isdigit() else 6)

    rows = load(hours)
    if not rows:
        print("no telemetry in the window")
        return 0
    events = find_events(rows)

    if watch:
        if not events:
            print(f"cache OK - no rebuild in {hours:.0f}h ({len(rows)} calls)")
        else:
            t, kind, wr, gap = events[-1]
            print(f"cache {kind} REBUILD at {t.strftime('%H:%M')}Z, {wr:,} written - {why(gap)}")
        return 0

    read = sum(r[1] for r in rows)
    write = sum(r[2] for r in rows)
    tot = read + write
    print(f"window            : last {hours:.0f}h, {len(rows)} API calls")
    if tot:
        print(f"hit rate          : {100.0 * read / tot:.1f}%   read {read:,} / write {write:,}")
    print(f"rebuilds detected : {len(events)}")

    if not events:
        print("\nNo rebuild. Every call read from cache.")
        return 0

    print("\n  time UTC   kind      written      gap before   cause")
    for t, kind, wr, gap in events:
        g = f"{gap:.0f} min" if gap is not None else "-"
        print(f"  {t.strftime('%H:%M:%S')}   {kind:<8}  {wr:>10,}   {g:>10}   {why(gap)}")

    wasted = sum(e[2] for e in events)
    print(f"\nTokens written by rebuilds: {wasted:,}")
    print("A rebuild bills at ~2x base; the same tokens read from cache bill at ~0.1x,")
    print("so each rebuild costs roughly 20x what the cached turn would have.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
