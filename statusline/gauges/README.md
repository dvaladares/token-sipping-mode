# Gauges

Small, self-contained readers for a Claude Code statusline. They exist because a budget
number you cannot see cannot pace you, and because the way these numbers fail is almost
always **absence rendered as good news**.

No tool here invents a value. No data means no output, and the caller omits the field.

## `session-telemetry.py`

Per-session cache and compaction telemetry from **this session's** transcript only.

```
$ python3 session-telemetry.py <transcript_path> [now_epoch]
cache_pct 93
rebuild_kind OLD
rebuild_size 120000
rebuild_age_s 3000
ttl_kind 1h
ttl_left_s 2711
last_api_age_s 889
compact_n 2
compact_age_s 3400
compact_pre 115016
compact_post 19417
```

One tail read (3 MB) of one file, one python start, every key optional. The statusline
uses it as the FALLBACK behind Claude Code's native `prompt_cache` object (v2.1.251+),
and as the only source for compactions (`compact_boundary` records).

**Why it replaced `cache-field.sh`.** That script globbed every transcript in every
config home and wrote one shared cache file, so every open session showed the same
"cache rebuilt 25m ago", whichever session had actually rebuilt. Prompt cache is per
conversation; the gauge must be too. The rebuild signature is unchanged and still comes
from the API's own billing fields: `cache_read == 0` with `cache_creation >= 20k` is a
full rebuild; `cache_read > 0` with `cache_creation >= 50k` means the prefix moved.
The TTL anchor is the last response's timestamp, because Anthropic refreshes the cache
on every hit, plus 1h or 5m depending on which `ephemeral_*_input_tokens` it reported.

## `codex-quota.py`

Reads codex's own rate-limit telemetry for **both** windows and prints one line:

```
<5h_pct> <5h_resets_at> <7d_pct> <7d_resets_at> <telemetry_age_s>
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
$ ../tests/run-all.sh
ALL SUITES PASS
```

`tests/test-mcp-health.sh` has four cases: healthy, a forced disconnect that must raise
`DOWN` **and name the server**, a reconnect that must clear it, and no data at all which
must print **nothing** rather than a fake zero. `tests/test-session-telemetry.sh` pins
"now" and checks every key against a synthetic transcript.

That third and fourth case are the point. **A gauge nobody has seen alarm is not a
gauge**, and a gauge that has only ever been seen to alarm may simply be stuck on. Prove
both directions before you trust either.

## `cache-verdict.py`

A machine-wide diagnostic (not a statusline field): find every prompt-cache rebuild in
the last N hours across all config homes, with the gap that caused each.

```console
$ python3 cache-verdict.py            # full report, last 6h
$ python3 cache-verdict.py watch      # one line, for a heartbeat
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

## `lanes.sh`

The one-call burn probe. Prints every gauge, every lane, and the ladder rung the skill
should obey. Read-only, under a second, safe at the top of every turn.

```console
$ ./lanes.sh
GAUGE claude_5h 56 1788303000
GAUGE claude_7d 11 1788436800
GAUGE quota_age_s 14
GAUGE quota_seat m2
GAUGE seat m2 56 11 14
GAUGE seat m4 UNKNOWN 10 22
GAUGE codex_5h 68 1788309120
GAUGE codex_7d 43 1788804188
LANE codex ok /opt/homebrew/bin/codex
LANE agy ok /Users/you/.local/bin/agy
LANE local missing
RUNG L1 5h=56% 7d=11%
```

It reads the same `config.sh` the statusline reads, so both agree on where
`quota-<seat>.json` lives. A seat that has never rendered does not appear. A window the
harness did not send prints `UNKNOWN`, and UNKNOWN or stale (over 30 min) forces at least
L1: headroom is never assumed. Override the file with `CLAUDE_QUOTA_FILE`, the local-model
probe with `LOCAL_LANE_BIN`.

## `today-usage.py`

Today's runs and tokens per delegation lane, from each lane's own records, one line:

```
<claude_n> <claude_in> <claude_out> <codex_n> <codex_in> <codex_out> <codex_tok> <agy_n> <agy_in> <agy_out>
```

Claude: transcripts touched since local midnight; `in` is input plus cache creation plus
cache reads of today's responses, `out` is output tokens. Codex: today's rollouts; the last
`total_token_usage` object per file. agy: conversation dirs touched today; agy writes no
token usage anywhere on disk (checked 2026-09-01), so its tokens print `-` and the
statusline omits them. This reads every transcript touched today, which can be hundreds
of megabytes, so it runs only inside the statusline's detached 60 s refresh, never per
render. Feeds the `⇄ today  claude 7 (1.3B in · 4.9M out) · codex 21 (28M in · 206k out) · agy 57 runs` line.
