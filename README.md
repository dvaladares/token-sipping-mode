# token-sipping-mode

A Claude Code skill for running long agent sessions against a capped token budget.

The idea in one line: delegate the legwork, own the verdict. The expensive model in your
main loop does judgment, synthesis, and final calls. Everything cheap to specify fans out
to cheaper models (or to a second vendor's CLI, which burns a separate budget).

What the skill covers:

- A routing table: which tier of model gets which class of task.
- A delegation contract that makes cheap models reliable (structured returns, output caps,
  timeouts, standing safety lines).
- Spend discipline rules: no speculative fan-outs, verify the settled artifact instead of
  every intermediate, batch everything, cap what re-enters expensive context.
- What is never delegated: governance, irreversibles, anything posted to humans.
- How to verify delegated work without re-doing it.
- The anti-pattern list: the expensive failures this mode exists to prevent.

## Install

Copy the skill into your Claude Code skills directory:

```
mkdir -p ~/.claude/skills/token-sipping-mode
cp SKILL.md ~/.claude/skills/token-sipping-mode/SKILL.md
```

Then invoke it in a session with `/token-sipping-mode`, or just ask for
"token sipping mode".

## Adapt it

The routing table names the models and tools I use (Claude tiers, the Codex CLI, the
Antigravity `agy` CLI). Swap in whatever you have. The method does not care which vendors
you route to; it cares that judgment stays in one place and legwork goes to the cheapest
tier that can do it correctly.

## License

MIT. See LICENSE.
