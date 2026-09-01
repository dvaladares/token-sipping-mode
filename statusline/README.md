# statusline

A session-scoped, honest statusline for [Claude Code](https://code.claude.com). One bash
file, three small helpers in `gauges/`, the frugal meter in `frugal/`, no daemon. Built
for people who run more than one Claude account and more than one AI CLI on the same
machine. Part of the [token-sipping-mode](..) kit.

```
Fable 5.1 (claude-fable-5-1) · 👤 you@example.com [MAX 20x] (M2) · ‹statusline v2›
✍️  40% (80k/200k) · ⚡ 91% warm (ttl 45m) · $1.23 · cache miss 14m ago (2×, ~310k rewritten)
claude-statusline (main ⇡2) · +10 −2 · xhigh · ⏱ 1h13m
claude 5h ●●●●●●○○○○ 56% ⇡12  ↻ 6:50pm (23m)
claude 7d ●○○○○○○○○○ 11% ⇣49  ↻ Thu Sep 3, 8:00am (1d13h)
codex 5h  ●●●●●●●○○○ 68% ⇡11  ↻ 8:32pm (2h07m)
codex 7d  ●●●●○○○○○○ 43%      ↻ Mon Sep 7, 2:03pm (5d19h)
← 2 agents · PR #4242 · approved · ⇄ today  claude 7 · codex 19 (26.7M tok) · agy 35 runs
mcp 7 cfg · 3 live
```

Try it without installing: `bash statusline.sh --demo`.

## Rules it lives by

1. **Omit, never fabricate.** A field with no real data source is not printed. No
   placeholder, no guess, no zero standing in for "unknown".
2. **Session-scoped.** Prompt cache, compactions, MCP liveness and cost come from this
   session's input JSON or this session's transcript. Nothing is globbed across every
   transcript on the machine and then shown as if it were yours.
3. **Fast.** Claude Code debounces at 300 ms and cancels a render that is still running
   when the next trigger fires. One `jq` pass extracts every field; the helpers run in
   parallel; slow lookups are cached and refreshed by detached jobs. Typical render:
   100 to 170 ms on an M-series Mac.
4. **Account-agnostic.** Plan badge, seat label and quota paths derive from the input
   JSON and `CLAUDE_CONFIG_DIR`. Per-machine labels live in one small config file.
5. **Portable.** bash 3.2 (stock macOS) and GNU userland. Needs `jq`, `python3`, `perl`.

## Install

```bash
git clone https://github.com/dvaladares/token-sipping-mode ~/code/token-sipping-mode
cd ~/code/token-sipping-mode/statusline
./install.sh ~/.claude                      # one account
./install.sh ~/.claude ~/.claude-max20x     # every CLAUDE_CONFIG_DIR home you use
```

`install.sh` backs up any existing `statusline.sh`, symlinks each home to this repo's
file (so a `git pull` updates every seat at once), and prints the `settings.json` snippet
if yours does not already point there. It never edits `settings.json`. Add this yourself:

```json
"statusLine": {
  "type": "command",
  "command": "bash ~/.claude/statusline.sh",
  "refreshInterval": 30
}
```

`refreshInterval` is optional. Without it the line re-renders only on events, so the
countdowns and the cache TTL freeze while the session is idle.

## Configure

`~/.config/claude-statusline/config.sh` is plain bash, sourced on every render. See
`config.example.sh`. The two things most people set:

```bash
# what to call each account home; the argument is the resolved CLAUDE_CONFIG_DIR
seat_label() { case "$1" in *".claude-max20x") printf 'M2' ;; *) printf 'M4' ;; esac; }

# where other tools can read this seat's rate limits (quota-<seat>.json)
SL_QUOTA_DIR="$HOME/.claude/torch-agy"
```

Everything else is a toggle or a threshold: `SL_SHOW_CODEX`, `SL_SHOW_DELEGATION`,
`SL_SHOW_MCP`, `SL_SHOW_CTX_TOKENS`, `SL_SHOW_REPO`, `SL_CTX_WARN`, `SL_TTL_WARN_S`,
`SL_NARROW_COLS`.

## What each field reads

| Field | Source |
| --- | --- |
| model, slug | `model.display_name`, `model.id` |
| account, plan badge | `oauthAccount.*` in the input, else this home's `.claude.json` |
| seat tag | `CLAUDE_CONFIG_DIR` through `seat_label()` |
| 🤖 agent, ‹session name› | `agent.name`, `session_name` |
| ✍️ context % and tokens | `context_window.used_percentage`, `total_input_tokens`, `context_window_size` |
| ⚡ warm %, ttl, COLD | `prompt_cache.*` (Claude Code 2.1.251+); before that, derived from the transcript by `gauges/session-telemetry.py` |
| cache MISS / miss | `prompt_cache.misses`, `last_miss_at`, `miss_recache_tokens`; legacy: rebuild signature `cache_read == 0 && cache_creation >= 20k` |
| ⧉ compacted | `compact_boundary` records in this session's transcript |
| $cost | `cost.total_cost_usd`, omitted when 0 (Team and Enterprise plans always report 0) |
| frugal | optional `~/.claude/frugal/bin/statusline.py`, omitted if absent |
| dir (branch* ⇡ ⇣) | `cwd`; `git branch --show-current`, `status --porcelain`, `rev-list --left-right --count @{u}...HEAD` |
| owner/repo | `workspace.repo.owner`, `workspace.repo.name` |
| +added −removed | `cost.total_lines_added`, `cost.total_lines_removed` |
| 🌳 worktree | `worktree.name` |
| effort, fast | `effort.level`, `fast_mode` |
| ⏱ session | `cost.total_duration_ms` |
| [VIM] | `vim.mode` |
| claude 5h / 7d / spend | `rate_limits.five_hour`, `seven_day`, `spend_limit` |
| ⇡ / ⇣ pace on a bar | quota used minus the share of the window already elapsed; quiet within 10 points |
| codex 5h / 7d | codex's own `rate_limits` in `~/.codex/sessions/*/rollout*.jsonl`, both windows (`gauges/codex-quota.py`) |
| ← N agents | `subagents` (only when it is a real array) |
| PR #n · state | `pr.number`, `pr.url` (clickable), `pr.review_state`, `pr.kind` (MR for GitLab); merged/closed PRs filtered via `gh-pr-status-cache.json` |
| ⇄ today | transcripts, codex rollouts and agy conversations touched today (cached 60 s) |
| mcp cfg / live / DOWN | `.claude.json` servers; tool attributions and disconnect notices in this transcript (`gauges/mcp-health.sh`) |

## Test and debug

```bash
tests/run-all.sh                    # every suite
tests/render.sh full --plain        # render a fixture, colours stripped
tests/render.sh edge --time         # median render time in ms
tests/probe-fields.sh               # which fields does the installed Claude Code know?
tests/bench-spawns.sh               # cost of each external process on this machine
```

Every render also writes the raw input it received to
`~/.cache/claude-statusline/last-input-<seat>.json`, so "what did the harness actually
send?" is one `jq . ` away. Render it back with `tests/render.sh <that file>`.

## Known harness behaviour

- `prompt_cache` appears only after the session's first API response, and only on Claude
  Code 2.1.251 or newer. Older versions get the transcript-derived fallback.
- `context_window.current_usage` is `null` right after `/compact` until the next call.
- Two Claude Code sessions on different accounts running at the same time on one machine
  may show converging `rate_limits` numbers
  ([anthropics/claude-code#68772](https://github.com/anthropics/claude-code/issues/68772)).
  Each seat still writes its own `quota-<seat>.json`, but treat the bars with care while
  both seats are active.
- `tput cols` cannot see the terminal from inside the script. The harness sets `COLUMNS`,
  which this script uses to drop dim extras on narrow panes.

## Layout

```
L1  identity   model (slug) · 👤 email [PLAN] (SEAT) · 🤖 agent · ‹session name›
L2  budget     ✍️ ctx% (used/size) · ⚡ warm% (ttl) · $cost · frugal · cache MISS · ⧉ compactions
L3  place      dir (branch* ⇡ ⇣) · owner/repo · +a −r · 🌳 worktree · effort · fast · ⏱ · [VIM]
L4  claude 5h  ●●●●●●○○○○ 56% ⇡12  ↻ reset (countdown)
L5  claude 7d  same; spend limit line for gateway accounts
L6  codex 5h / 7d
L8  lanes      ← N agents · PR #n · ⇄ today claude N · codex N (tok) · agy N runs
L9  mcp        mcp N cfg · N live · DOWN <name>
```

Identity first, so a narrow pane never cuts the one field that says which account is
being spent. Budget second. Place third. Every line is dropped when it has nothing real
to say.

## License

MIT.
