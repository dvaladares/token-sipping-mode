#!/usr/bin/env python3
"""Today's runs and tokens per delegation lane, from each lane's OWN records.

Usage: today-usage.py            (called by the statusline's detached refresh, never per render)

Prints one line, space separated, `-` for anything genuinely unknown:

    <claude_n> <claude_in> <claude_out> <codex_n> <codex_in> <codex_out> <codex_tok> <agy_n> <agy_in> <agy_out>

Sources
  claude  every transcript under ~/.claude*/projects/*/*.jsonl modified since local
          midnight. runs = files. in = input + cache_creation + cache_read of each
          assistant response stamped today; out = output_tokens. Cache reads dominate
          "in", which is exactly the point: that is what the context costs to carry.
  codex   rollouts under ~/.codex/sessions/Y/M/D. runs = files. The LAST
          total_token_usage object in each file is the running total for that session:
          input_tokens (cached included), output_tokens, total_tokens.
  agy     conversation dirs under ~/.gemini/antigravity-cli/brain touched today.
          runs = dirs. agy writes no per-call token usage anywhere on disk that this
          script can find (checked brain/, conversations/, history.jsonl, cli.log on
          2026-09-01), so its tokens print as `-` and the statusline OMITS them rather
          than inventing a number.

Cost: a full read of today's transcripts, which can be hundreds of MB late in a day.
That is why this runs detached behind a 60 s cache and never inside a render.
"""
import datetime
import glob
import json
import os
import re
import sys

HOME = os.path.expanduser("~")


def local_midnight():
    now = datetime.datetime.now().astimezone()
    return now.replace(hour=0, minute=0, second=0, microsecond=0)


def claude(midnight):
    n = 0
    tin = 0
    tout = 0
    seen_any = False
    cut = midnight.timestamp()
    for path in glob.glob(os.path.join(HOME, ".claude*", "projects", "*", "*.jsonl")):
        try:
            if os.path.getmtime(path) < cut:
                continue
        except OSError:
            continue
        n += 1
        try:
            with open(path, "rb") as fh:
                for raw in fh:
                    if b'"usage"' not in raw or b'"type":"assistant"' not in raw:
                        continue
                    try:
                        d = json.loads(raw)
                    except ValueError:
                        continue
                    ts = d.get("timestamp") or ""
                    try:
                        t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    if t < midnight:
                        continue
                    u = (d.get("message") or {}).get("usage") or {}
                    if not u:
                        continue
                    seen_any = True
                    tin += (u.get("input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0) \
                        + (u.get("cache_read_input_tokens") or 0)
                    tout += u.get("output_tokens") or 0
        except OSError:
            continue
    if n == 0:
        return ("-", "-", "-")
    if not seen_any:
        return (str(n), "-", "-")
    return (str(n), str(tin), str(tout))


TTU = re.compile(rb'"total_token_usage":\{[^}]*\}')


def codex():
    root = os.path.join(HOME, ".codex", "sessions")
    if not os.path.isdir(root):
        return ("-", "-", "-", "-")
    day = datetime.date.today().strftime("%Y/%m/%d")
    files = glob.glob(os.path.join(root, day, "*.jsonl"))
    n = len(files)
    tin = tout = tot = 0
    seen = False
    for f in files:
        try:
            size = os.path.getsize(f)
            with open(f, "rb") as fh:
                if size > 200_000:
                    fh.seek(size - 200_000)
                chunk = fh.read()
        except OSError:
            continue
        m = TTU.findall(chunk)
        if not m:
            continue
        try:
            u = json.loads(b"{" + m[-1] + b"}")["total_token_usage"]
        except (ValueError, KeyError):
            continue
        seen = True
        tin += u.get("input_tokens") or 0
        tout += u.get("output_tokens") or 0
        tot += u.get("total_tokens") or 0
    if not seen:
        return (str(n), "-", "-", "-")
    return (str(n), str(tin), str(tout), str(tot))


def agy(midnight):
    root = os.path.join(HOME, ".gemini", "antigravity-cli", "brain")
    if not os.path.isdir(root):
        return ("-", "-", "-")
    cut = midnight.timestamp()
    n = 0
    for d in os.listdir(root):
        p = os.path.join(root, d)
        try:
            if os.path.isdir(p) and os.path.getmtime(p) >= cut:
                n += 1
        except OSError:
            continue
    return (str(n), "-", "-")


def main():
    midnight = local_midnight()
    c = claude(midnight)
    x = codex()
    a = agy(midnight)
    print(" ".join(c + x + a))
    return 0


if __name__ == "__main__":
    sys.exit(main())
