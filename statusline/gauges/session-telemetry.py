#!/usr/bin/env python3
"""Per-session telemetry for the Claude Code statusline, from THIS session's transcript.

Usage: session-telemetry.py <transcript_path> [now_epoch]

WHY (2026-09-01, Daniel). The old cache-rebuild field globbed EVERY transcript in both
config homes and wrote ONE shared cache file. Every open session therefore showed the same
machine-wide "cache rebuilt 25m ago", whichever session had actually rebuilt. Prompt cache
is per conversation. The gauge must be too. This reads one transcript, the session's own,
and nothing else.

It also folds three separate tail-reads of the same file into one pass: the warm-cache hit
rate (was tail | grep | jq), the rebuild detector (was cache-field.sh) and a new cache-TTL
countdown. One read, one python start, one cache file per session.

Output: one "key value" pair per line. A key with no real data is NOT printed, so the
caller omits the field. Nothing here is ever a guess.

    cache_pct 89           rolling hit rate over the last 200 API calls, percent
    rebuild_kind HOT       HOT = full rebuild in the last 10 min, OLD = older or partial
    rebuild_size 605071    cache_creation tokens written by that rebuild
    rebuild_age_s 1520     seconds since it
    ttl_kind 1h            which ephemeral TTL the last call used (1h or 5m)
    ttl_left_s 2711        seconds until the cache goes cold, negative if already cold
    last_api_age_s 889     seconds since the last API response in this session
    compact_n 2            compactions in this session
    compact_age_s 3400     seconds since the last one
    compact_pre 115016     context tokens before that compaction
    compact_post 19417     context tokens after it

Rebuild signature, from the API's own billing fields (nothing inferred):
    cache_read == 0 and cache_creation >= 20k    a full rebuild
    cache_read >  0 and cache_creation >= 50k    the prefix moved mid-conversation

TTL anchor: Anthropic refreshes the cache TTL on every hit at no cost, so the anchor is
the timestamp of the LAST API response, whatever it wrote. The window is 1h when that
response reports ephemeral_1h_input_tokens > 0, else 5m when ephemeral_5m > 0. When the
row carries neither, the TTL is unknown and not printed.
"""
import datetime
import json
import os
import sys

TAIL_BYTES = 3_000_000          # enough for hundreds of turns; a render must stay cheap
ROLLING_N = 200                 # calls in the warm-cache window
REBUILD_FULL = 20_000
REBUILD_PARTIAL = 50_000
HOT_S = 600
LOOKBACK_S = 3 * 3600


def parse_ts(s):
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def main():
    if len(sys.argv) < 2 or not sys.argv[1]:
        return 0
    path = sys.argv[1]
    now = float(sys.argv[2]) if len(sys.argv) > 2 else datetime.datetime.now(
        datetime.timezone.utc).timestamp()
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TAIL_BYTES:
                fh.seek(size - TAIL_BYTES)
                fh.readline()                     # drop the partial first line
            chunk = fh.read()
    except OSError:
        return 0

    rows = []                                     # (ts, read, write, input, eph1h, eph5m)
    compacts = []                                 # (ts, pre, post)
    for raw in chunk.split(b"\n"):
        if b'"usage"' in raw and b'"type":"assistant"' in raw:
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            u = (d.get("message") or {}).get("usage") or {}
            if not u:
                continue
            ts = parse_ts(d.get("timestamp") or "")
            cc = u.get("cache_creation") or {}
            rows.append((ts,
                         u.get("cache_read_input_tokens") or 0,
                         u.get("cache_creation_input_tokens") or 0,
                         u.get("input_tokens") or 0,
                         cc.get("ephemeral_1h_input_tokens") or 0,
                         cc.get("ephemeral_5m_input_tokens") or 0))
        elif b'"subtype":"compact_boundary"' in raw:
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            m = d.get("compactMetadata") or {}
            compacts.append((parse_ts(d.get("timestamp") or ""),
                             m.get("preTokens"), m.get("postTokens")))

    # Compactions earlier than the tail window are counted with a cheap byte scan of the
    # head, so compact_n is the whole-session count even on a long transcript.
    if size > TAIL_BYTES:
        try:
            with open(path, "rb") as fh:
                head = fh.read(size - TAIL_BYTES)
            compacts = [(None, None, None)] * head.count(b'"subtype":"compact_boundary"') + compacts
        except OSError:
            pass

    out = []
    if rows:
        win = rows[-ROLLING_N:]
        rd = sum(r[1] for r in win)
        tot = sum(r[1] + r[2] + r[3] for r in win)
        if tot > 0:
            out.append(("cache_pct", int(rd * 100 // tot)))

        last = None
        for ts, rd, wr, _in, _e1, _e5 in rows:
            if ts is None or now - ts > LOOKBACK_S:
                continue
            if (rd == 0 and wr >= REBUILD_FULL) or (rd > 0 and wr >= REBUILD_PARTIAL):
                # one rebuild can span several parallel calls in the same second; keep
                # the first of a burst unless the size changed
                if last is None or ts - last[0] > 3 or wr != last[1]:
                    last = (ts, wr)
        if last:
            age = now - last[0]
            out.append(("rebuild_kind", "HOT" if age <= HOT_S else "OLD"))
            out.append(("rebuild_size", last[1]))
            out.append(("rebuild_age_s", int(age)))

        ts, _rd, _wr, _in, e1, e5 = rows[-1]
        if ts is not None:
            out.append(("last_api_age_s", int(now - ts)))
            ttl = 3600 if e1 > 0 else 300 if e5 > 0 else None
            if ttl:
                out.append(("ttl_kind", "1h" if ttl == 3600 else "5m"))
                out.append(("ttl_left_s", int(ts + ttl - now)))

    if compacts:
        out.append(("compact_n", len(compacts)))
        ts, pre, post = compacts[-1]
        if ts is not None:
            out.append(("compact_age_s", int(now - ts)))
        if pre is not None and post is not None:
            out.append(("compact_pre", pre))
            out.append(("compact_post", post))

    for k, v in out:
        print(k, v)
    return 0


if __name__ == "__main__":
    sys.exit(main())
