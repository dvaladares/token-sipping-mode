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
    for p in ("~/.claude-max20x/projects/*/*.jsonl", "~/.claude/projects/*/*.jsonl"):
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
                             u.get("input_tokens", 0) or 0,
                             os.path.basename(f)[:8],
                             (d.get("message") or {}).get("id") or ""))
    rows.sort()
    # DEDUPE. The same logical API call can appear more than once: streaming produces
    # repeated usage records, and a call can be written to more than one transcript.
    # Without this, one rebuild is counted three or four times and the wasted-token
    # total is inflated by the same multiple. Collapse calls with identical token
    # counts landing within a 3-second window.
    # WIDENED 2026-09-01. The old rule compared ONLY the immediately preceding row and
    # only within 3 seconds. Measured the same day: one 78,364 token rebuild appeared at
    # 13:54:45 and again at 13:54:49, four seconds apart, so both were counted. The
    # reported waste read 1,382,573 when the true figure was 1,189,750, an 16% overstate.
    # Now: look back over the last few kept rows, within 10 seconds. Two genuinely
    # distinct calls with byte-identical read, write AND fresh counts inside 10 seconds
    # do not happen; the same call written twice does.
    # CORRECTED 2026-09-08. Dedupe is now PER SESSION, and prefers the message id when
    # the transcript carries one. Streaming writes the same assistant message many times
    # with one id, so the id is exact where the token-count heuristic was only close.
    deduped, seen_ids = [], set()
    for r in rows:
        sess, mid = r[4], r[5]
        if mid:
            if (sess, mid) in seen_ids:
                continue
            seen_ids.add((sess, mid))
            deduped.append(r)
            continue
        if any(
            (r[1], r[2], r[3]) == (k[1], k[2], k[3]) and r[4] == k[4]
            and (r[0] - k[0]).total_seconds() <= 10
            for k in deduped[-5:]
        ):
            continue
        deduped.append(r)
    return deduped


def find_events(rows):
    """Return [(when, kind, write, gap_minutes, session)] for every rebuild in the window.

    THE GAP IS MEASURED WITHIN ONE SESSION, and that is the whole point of this function.

    BUG FIXED 2026-09-08. The old version kept a single prev_t across every transcript on
    the machine. With two sessions live it compared a rebuild against some OTHER session's
    call, saw a tiny gap, and printed "the PREFIX changed". Measured that day: a rebuild in
    session 754d68bc at 22:04:40 UTC, 474,471 written, was reported as "gap 0 min, prefix
    changed". That session had actually been idle 138 minutes and the TTL had simply run
    out. Nothing was misconfigured. A cache verdict that blames a prefix change sends you
    hunting for an MCP or model change that never happened.
    """
    events = {}
    prev_by_session = {}
    for t, rd, wr, _fr, sess, _mid in rows:
        prev_t = prev_by_session.get(sess)
        gap = (t - prev_t).total_seconds() / 60.0 if prev_t else None
        if rd == 0 and wr >= REBUILD_WRITE:
            events[(t, sess)] = (t, "FULL", wr, gap, sess)
        elif rd > 0 and wr >= PARTIAL_WRITE:
            events[(t, sess)] = (t, "PARTIAL", wr, gap, sess)
        prev_by_session[sess] = t
    return [events[k] for k in sorted(events)]


def why(gap):
    if gap is None:
        return "first call this session had in the window; cause unknown"
    if gap >= TTL_MIN:
        return f"gap {gap:.0f} min exceeded the {TTL_MIN} min TTL, so time alone explains it"
    return (f"gap only {gap:.0f} min, well inside the {TTL_MIN} min TTL, so the PREFIX "
            f"changed (MCP set, agent types, or model)")


def staleness(rows):
    """How old is the newest telemetry record, in minutes.

    THIS MATTERS AND IT COST A WRONG ANSWER (2026-09-01). The tool reads the
    transcript file. The API call for the turn you are running RIGHT NOW is not
    written there yet. So a check at the top of a turn is structurally blind to
    that turn's own rebuild. I ran it, said "cache is fine", and the heartbeat
    three minutes later reported a 996,927 token FULL rebuild that had already
    happened. The data was not wrong. My reading of it was.

    So: always say how stale the newest record is, and refuse to imply the
    current turn is covered when it cannot be.
    """
    import datetime
    newest = rows[-1][0]
    now = datetime.datetime.now(datetime.timezone.utc)
    if newest.tzinfo is None:
        newest = newest.replace(tzinfo=datetime.timezone.utc)
    return (now - newest).total_seconds() / 60.0


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
            age = staleness(rows)
            note = "" if age < 2 else f" [newest record {age:.0f} min old, THIS turn not covered]"
            print(f"cache OK - no rebuild in {hours:.0f}h ({len(rows)} calls){note}")
        else:
            t, kind, wr, gap, sess = events[-1]
            print(f"cache {kind} REBUILD at {t.strftime('%H:%M')}Z in {sess}, "
                  f"{wr:,} written - {why(gap)}")
        return 0

    read = sum(r[1] for r in rows)
    write = sum(r[2] for r in rows)
    tot = read + write
    print(f"window            : last {hours:.0f}h, {len(rows)} API calls")
    age = staleness(rows)
    if age >= 2:
        print(f"newest record     : {age:.0f} min old - the CURRENT turn is not in this data")
    if tot:
        print(f"hit rate          : {100.0 * read / tot:.1f}%   read {read:,} / write {write:,}")
    print(f"rebuilds detected : {len(events)}")

    if not events:
        print("\nNo rebuild. Every call read from cache.")
        return 0

    sessions = sorted({r[4] for r in rows})
    print(f"sessions in window: {len(sessions)} ({', '.join(sessions)})")
    print("\n  time UTC   session   kind      written    gap in session   cause")
    for t, kind, wr, gap, sess in events:
        g = f"{gap:.0f} min" if gap is not None else "-"
        print(f"  {t.strftime('%H:%M:%S')}   {sess:<8}  {kind:<8}  {wr:>9,}   {g:>14}   {why(gap)}")

    wasted = sum(e[2] for e in events)
    print(f"\nTokens written by rebuilds: {wasted:,}")
    print("A rebuild bills at ~2x base; the same tokens read from cache bill at ~0.1x,")
    print("so each rebuild costs roughly 20x what the cached turn would have.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
