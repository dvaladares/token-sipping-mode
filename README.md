# token-sipping-mode

**Delegate the legwork. Own the verdict.**

An operating mode for AI coding agents that must survive on a capped token budget:
overnight runs, weekly rate windows, subscription tiers, long autonomous sessions.
The expensive frontier model in your main loop spends tokens on exactly one thing,
judgment. Everything that is cheap to specify gets fanned out to cheaper models,
or to a second vendor's CLI that burns a separate budget entirely.

This repo is the whole kit:

| Piece | What it does |
|---|---|
| `SKILL.md` | The operating mode itself: a routing table, a delegation contract, spend discipline rules, and the anti-pattern list |
| `statusline/statusline.sh` | A session-scoped terminal statusline: model, which account and seat you are spending, context %, prompt-cache warmth and TTL, cache misses, compactions, cost, git, PR, 5-hour and weekly rate-limit bars with pace, codex's quota, MCP health. See [statusline/README.md](statusline/README.md) |
| `statusline/gauges/` | The readers behind it: per-session cache telemetry, two-window codex quota, MCP health. Each omits rather than guesses |
| `statusline/frugal/` | The frugal meter: three small Python scripts that measure what delegation actually saved you, in dollars, live in the statusline |
| `statusline/tests/` | 69 render cases plus suites for every gauge; `tests/run-all.sh` |

The statusline in action:

```
Fable 5.1 (claude-fable-5-1) · 👤 you@example.com [MAX 20x] (M2)
✍️  40% (80k/200k) · ⚡ 91% warm (ttl 45m) · $1.23 · frugal $603.41/$603.41 saved · cache miss 14m ago (2×, ~310k rewritten)
my-project (feature/thing* ⇡2) · +10 −2 · xhigh · ⏱ 1h13m
claude 5h ●●●●●●○○○○ 56% ⇡12  ↻ 6:50pm (23m)
claude 7d ●○○○○○○○○○ 11% ⇣49  ↻ Thu Sep 3, 8:00am (1d13h)
codex 5h  ●●●●●●●○○○ 68%      ↻ 8:32pm (2h07m)
← 2 agents · PR #4242 · approved · ⇄ today  claude 7 · codex 19 (26.7M tok) · agy 35 runs
mcp 7 cfg · 3 live
```

That `frugal $603.41 saved` figure is not vibes. It is the difference between what
your delegated subagent work would have cost at top-model pricing and what it
actually cost at the tier it ran on, summed across the session and the lifetime of
the metrics file.

## The one law

Route each task DOWN to the cheapest tier that can do it correctly.

- **Judgment stays home.** Verdicts, synthesis, risk calls, anything that lands,
  posts, or gets graded: the main loop, on the best model you have.
- **Verification goes mid-tier.** Spec-clear multi-step work with checkable output:
  builds, test runs, diff analysis, structured research.
- **Mechanical goes bottom-tier.** Polls, greps, inventories, format checks.
- **Second vendors are free capacity.** A Codex CLI, a Gemini CLI, whatever you
  have: their budget is not your budget. Route heavy legwork there when your
  primary window is the constraint.

`SKILL.md` carries the full contract: how to brief a cheap model so it comes back
reliable, how to verify delegated work without re-doing it, the spend rules
(no speculative fan-outs, verify the settled artifact rather than every
intermediate, batch everything), and the list of expensive failures this mode
exists to prevent.

## Quickstart: Claude Code

1. **The skill.**

   ```bash
   mkdir -p ~/.claude/skills/token-sipping-mode
   cp SKILL.md ~/.claude/skills/token-sipping-mode/SKILL.md
   ```

   Then say "token sipping mode" in any session, or invoke
   `/token-sipping-mode`.

2. **The statusline.**

   ```bash
   statusline/install.sh ~/.claude            # add every CLAUDE_CONFIG_DIR home you use
   mkdir -p ~/.claude/frugal/bin
   cp statusline/frugal/*.py ~/.claude/frugal/bin/
   ```

   `install.sh` symlinks `~/.claude/statusline.sh` into the clone, so `git pull`
   updates it, and prints this snippet for `~/.claude/settings.json` if it is missing:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline.sh",
       "refreshInterval": 30
     }
   }
   ```

   Seat labels and toggles live in `~/.config/claude-statusline/config.sh`; see
   [statusline/README.md](statusline/README.md).

3. **The frugal meter.** `log_metrics.py` is a `SubagentStop` hook: every time a
   subagent finishes, it appends one line of token accounting to
   `~/.claude/frugal/metrics.jsonl`. It is built to never break a session: it
   always exits 0 and swallows every error. In `~/.claude/settings.json`:

   ```json
   {
     "hooks": {
       "SubagentStop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "python3 ~/.claude/frugal/bin/log_metrics.py"
             }
           ]
         }
       ]
     }
   }
   ```

   The statusline picks the meter up automatically and stays silent until the
   first metric exists.

## Any other harness

The method is not Claude-specific and the skill file is just markdown. If you run
a different orchestrator, the install is one sentence:

> Log into whatever CLI you use, make sure it is up to date, hand your
> orchestrator model this repo's `SKILL.md`, and tell it: "adopt this operating
> mode, and map the routing table onto the models and tools we actually have
> here."

A frontier model is clever enough to do the mapping itself. The tiers are roles,
not brand names: a judgment model, a verification model, a mechanical model, and
any second-vendor lane you happen to have. The discipline transfers unchanged.

## Adapting the routing table

`SKILL.md` names the setup I run (Claude tiers, the Codex CLI, the Antigravity
`agy` CLI). Swap freely. What must survive the swap:

1. One place owns judgment, and it never delegates a verdict.
2. Every delegated task carries the contract: one concrete deliverable,
   structured returns, an output cap, a timeout, raw findings over prose.
3. Spot-check delegate claims instead of re-running their work, and distrust
   flattering results.
4. Governance and irreversibles never leave the main loop, whatever the budget.

## License

MIT. See [LICENSE](LICENSE).
