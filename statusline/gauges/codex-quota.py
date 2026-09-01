#!/usr/bin/env python3
"""Read codex's OWN rate-limit telemetry for BOTH windows.

WHY THIS EXISTS (2026-08-31). The statusline used to parse codex's rate_limits with
grep, take `head -1` of used_percent, and `break` after the first match. codex records
TWO windows in every rollout:

    window_minutes = 300     the 5-hour window
    window_minutes = 10080   the 7-day window

Taking the first match meant one window was reported and the other silently discarded,
with no indication which one you were looking at. Measured the day this was written:
the statusline displayed "codex 5h 30%" while the real 5h figure was 100% and the
weekly was 16%. The lane was exhausted and the gauge said it was fine.

Two parsing traps this avoids, both real:
  1. BSD grep caps BRE interval counts at 255 (RE_DUP_MAX). A pattern like
     `.\\{0,500\\}` fails with "maximum repetition exceeds 255" and returns NOTHING,
     which reads as "no data" rather than as an error.
  2. Slicing JSON with a fixed-width regex truncates the object. This walks braces
     and parses real JSON instead.

Output: one line, space separated, `-` for anything genuinely unknown.

    <5h_pct> <5h_resets_at> <7d_pct> <7d_resets_at>

Never invents a value. No data means `-`, and the caller omits the field.
"""

import datetime
import glob
import json
import os
import re
import sys

WINDOW_5H = 300
WINDOW_7D = 10080
MAX_FILES = 6          # newest rollouts only; older ones carry stale windows
TAIL_BYTES = 2_000_000


def latest_windows(session_root):
    """Return {window_minutes: (used_percent, resets_at)} from the newest telemetry."""
    today = datetime.date.today()
    dirs = []
    for back in (0, 1):                       # today, and yesterday for early-morning runs
        d = today - datetime.timedelta(days=back)
        dirs.append(os.path.join(session_root, d.strftime("%Y/%m/%d")))

    files = []
    for d in dirs:
        files.extend(glob.glob(os.path.join(d, "*.jsonl")))
    if not files:
        return {}
    files.sort(key=os.path.getmtime, reverse=True)
    files = files[:MAX_FILES]

    best = {}   # window_minutes -> (used_percent, resets_at, mtime)
    for path in files:
        try:
            mtime = os.path.getmtime(path)
            with open(path, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                size = fh.tell()
                fh.seek(max(0, size - TAIL_BYTES))
                chunk = fh.read().decode("utf8", errors="ignore")
        except OSError:
            continue

        for m in re.finditer(r'"rate_limits"\s*:\s*', chunk):
            start = m.end()
            if start >= len(chunk) or chunk[start] != "{":
                continue
            depth = 0
            end = None
            for i in range(start, min(start + 8000, len(chunk))):
                if chunk[i] == "{":
                    depth += 1
                elif chunk[i] == "}":
                    depth -= 1
                    if depth == 0:
                        end = i + 1
                        break
            if end is None:
                continue            # truncated object at the tail boundary; skip it
            try:
                obj = json.loads(chunk[start:end])
            except ValueError:
                continue
            for key in ("primary", "secondary"):
                w = obj.get(key)
                if not isinstance(w, dict):
                    continue
                wm, up, ra = w.get("window_minutes"), w.get("used_percent"), w.get("resets_at")
                if wm is None or up is None:
                    continue
                prev = best.get(wm)
                if prev is None or mtime >= prev[2]:
                    best[wm] = (up, ra, mtime)
    return {wm: (v[0], v[1]) for wm, v in best.items()}


def pick(windows, target, tolerance):
    """Find a window at or near `target` minutes. Exact first, then nearest in range."""
    if target in windows:
        return windows[target]
    for wm, val in windows.items():
        if abs(wm - target) <= tolerance:
            return val
    return None


def fmt(val):
    if val is None:
        return "- -"
    pct, reset = val
    try:
        pct_s = str(int(float(pct)))
    except (TypeError, ValueError):
        pct_s = "-"
    reset_s = str(int(reset)) if isinstance(reset, (int, float)) else "-"
    return f"{pct_s} {reset_s}"


def newest_mtime(root):
    """Age of the freshest telemetry, in seconds, or None."""
    files = []
    today = datetime.date.today()
    for back in (0, 1):
        d = today - datetime.timedelta(days=back)
        files.extend(glob.glob(os.path.join(root, d.strftime("%Y/%m/%d"), "*.jsonl")))
    if not files:
        return None
    return int(datetime.datetime.now().timestamp() - max(os.path.getmtime(f) for f in files))


def main():
    root = os.path.expanduser("~/.codex/sessions")
    if not os.path.isdir(root):
        print("- - - - -")     # codex not installed: report nothing, never a zero
        return 0
    try:
        windows = latest_windows(root)
        age = newest_mtime(root)
    except Exception:
        print("- - - - -")
        return 0
    # FIFTH FIELD: age of the telemetry in seconds, or '-'.
    #
    # WHY (added 2026-08-31, within an hour of the parser itself). This gauge only
    # refreshes when codex ACTUALLY RUNS. A stale 100% and a live 100% are byte for
    # byte identical, so the statusline showed "codex 5h 100%" for 45 minutes after
    # the window had already reset to 0%. The lane was free and the gauge said it was
    # exhausted, which is the same absence-reads-wrong fault in the other direction:
    # here it cost unnecessary caution rather than an overspend.
    #
    # A canary call is what exposed it. The caller should treat anything older than
    # roughly half an hour as unverified and canary before trusting it.
    print(f"{fmt(pick(windows, WINDOW_5H, 60))} {fmt(pick(windows, WINDOW_7D, 1440))} "
          f"{age if age is not None else '-'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
