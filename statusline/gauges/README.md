# Gauges

Two small, self-contained readers for a Claude Code statusline. Both exist because a
budget number you cannot see cannot pace you, and because the way these numbers fail is
almost always **absence rendered as good news**.

Neither tool invents a value. No data means no output, and the caller omits the field.

## `codex-quota.py`

Reads codex's own rate-limit telemetry for **both** windows and prints one line:

```
<5h_pct> <5h_resets_at> <7d_pct> <7d_resets_at>
```

`-` for anything genuinely unknown. Example:

```console
$ python3 codex-quota.py
100 1788217388 16 1788804188
```

**Why it exists.** codex records two windows in every rollout, `window_minutes` 300 and
10080. A statusline that greps for the first `used_percent` and stops reports one window
and silently discards the other, with no indication which you are seeing. Measured
2026-08-31: the display read `codex 5h 30%` while the true 5h figure was **100%** and the
weekly was 16%. The lane was exhausted and the gauge looked fine.

**Two parsing traps it avoids, both real:**

1. BSD `grep` caps BRE interval counts at 255 (`RE_DUP_MAX`). A pattern like
   `.\{0,500\}` fails with *"maximum repetition exceeds 255"* and returns **nothing**,
   which reads as "no data" rather than as an error.
2. Slicing JSON with a fixed-width regex truncates the object. This walks braces and
   parses real JSON.

## `mcp-health.sh`

Reports MCP server health as three distinct states:

```
mcp 7 cfg · 3 live
mcp 7 cfg · 2 live · DOWN aws-mcp
```

| field | meaning |
| --- | --- |
| `cfg` | servers configured in `.claude.json` |
| `live` | servers that have **served a tool call** this session |
| `DOWN` | a disconnect notice with no later reconnect notice |

Usage: `mcp-health.sh <transcript_path> <claude_config_dir>`

**`live` is not `connected`.** A configured server that served no call may be perfectly
fine and simply unused. So an unseen server is reported as unseen, never as down. Only a
real disconnect notice raises `DOWN`. A gauge that cries wolf gets ignored, and this one
has to be trusted at hour nine of a long session.

It caches for 45 seconds and should be called behind a timeout guard, because a
statusline render must never block.

## Testing

```console
$ ./test/test-mcp-health.sh
ALL CASES PASS
```

Four cases: healthy, a forced disconnect that must raise `DOWN` **and name the server**,
a reconnect that must clear it, and no data at all which must print **nothing** rather
than a fake zero.

That third and fourth case are the point. **A gauge nobody has seen alarm is not a
gauge**, and a gauge that has only ever been seen to alarm may simply be stuck on. Prove
both directions before you trust either.
