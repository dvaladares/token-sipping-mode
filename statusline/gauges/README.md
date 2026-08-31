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

## `cache-verdict.py` and `cache-field.sh`

Find prompt-cache rebuilds, and put the cost on screen while it still means something.

```console
$ python3 cache-verdict.py            # full report, last 6h
$ python3 cache-verdict.py watch      # one line, for a statusline or heartbeat
$ ./cache-field.sh                    # coloured statusline field, or nothing
```

Set `CLAUDE_TRANSCRIPT_DIRS` if you run more than one config home:

```console
$ export CLAUDE_TRANSCRIPT_DIRS="$HOME/.claude $HOME/.claude-work"
```

**Why.** A rebuild is invisible while it happens and costs roughly 20x a cached turn:
written tokens bill at ~2x, cached reads at ~0.1x. Measured on one machine in one day:

| event | cost | cause |
| --- | --- | --- |
| an MCP server flapped mid-session | ~75k written | tool list changed, no user action at all |
| a restart with one MCP server missing | 605k written | prefix changed, 25 min gap, well inside the TTL |

Neither surfaced at the time. Both were found hours later by reading transcripts.

**What it reads.** The API's own per-call accounting: `cache_read_input_tokens`,
`cache_creation_input_tokens`, `input_tokens`. Nothing is estimated.

**Two mistakes worth inheriting rather than repeating.**

1. *Do not require a "mark" before a restart and then report the first turns after it.*
   The turns immediately after a mark are still pre-restart. Version one of this tool
   printed "the cache HELD" while the very next call showed `cache_read=0` and 605,071
   written. It now finds rebuilds by signature and reports the gap that caused each,
   so no human has to remember to arm anything.

2. *Deduplicate before totalling.* The same logical call appears more than once, from
   streaming records and from multiple transcripts. Without dedup the waste total was
   inflated by 60%.

**Reading the gap is how you learn the cause.** A gap longer than the TTL means time
expired the entry on its own. A short gap means the PREFIX changed, which in practice
means the MCP server set, the available agent types, or the model.
