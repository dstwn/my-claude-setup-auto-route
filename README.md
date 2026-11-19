# my-claude-setup-auto-route

A personal Claude Code setup for cheaper workflows. Unofficial, not affiliated with Anthropic.
It has two independent parts.

## 1. `auto-route` (mod / plugin)

Routes each prompt in the main session to a model and effort level, and shows the decision above the prompt
(`auto · light → sonnet · low`).

| Tier | Typical prompts | Route |
| --- | --- | --- |
| light | short or simple: `git status`, "apa itu worktree?", read/list/rename | Sonnet, effort low |
| standard | everything else | session default (unchanged) |
| deep | security, auth, migration, architecture, `/grill-with-docs`, `/to-spec`, `/to-tickets`, `/code-review`, `/implement-spec` | Opus, effort high |

- **Cache guard:** above 40,000 context tokens the model is never switched (up or down), because a switch throws away the warm prompt cache.
- **Commands:** `/auto-route on|off|status` (on/off lasts for the session).
- **Tune it:** the tier table and threshold are at the top of `hooks/register.tsx`; classification is plain regex, so expect some misrouted prompts.
- Uses the Claude Code mod API (`turn.start`, `turn.step`, `ui.render`). Tested with `claude plugin test`; the label is not yet verified in every client.

### Install

At the prompt of a terminal session:

```
/plugin install auto-route --marketplace dstwn/my-claude-setup-auto-route
```

From a shell:

```
claude plugin install auto-route --marketplace dstwn/my-claude-setup-auto-route
```

## 2. `install-claude-setup.sh` (generic core)

One idempotent script that writes only to `~/.claude/` (backups as `*.bak-<timestamp>`): model-tiered subagents
(`scout`/`Explore` Haiku, `builder`, `critic` Opus, `critic-lite` Sonnet), routing rules, a read-only Bash hook,
a worktree hook that copies `.env*` and `vendor/`, `nested-claude` (separate `claude -p` sessions per ticket, with a
`/nested-implement` supervisor skill), a `PreModelSwitch` cache guard and a status line.

```
bash install-claude-setup.sh
```

- `nested-claude start --tier auto` classifies a ticket (`auto-llm` adds a Haiku opinion) and picks tier, caps and model;
  `nested-claude classify <task-file>` previews the decision.
- Every finished session appends one line (tier, model, turns, cost, status, PR yes/no; no ticket text) to
  `~/.claude/nested/runs.jsonl`. `nested-claude report [--days N] [--json]` summarises it per tier/model and score bucket and,
  once a group has 5+ sessions, suggests tuning the score thresholds.
- Ticket keys look like `PROJ-123` and drive branch names and commit/PR-title prefixes. Team-specific conventions can be
  added as a skill (for example `ids-spec-parallel-pr`); `/nested-implement` uses it when installed.
- `/receiving-codereview` triages a person's PR feedback (fix / ask / push back / skip), fixes through `builder`, drafts
  replies, and records general lessons in `.claude/review-lessons.md` (repo) or `~/.claude/review-lessons.md`. `builder`,
  `critic`, `critic-lite` and nested sessions read the confirmed lessons first. Lessons never come from the agents' own
  reviews, and unconfirmed ones stay under `## Pending`.
- Requires `python3`; the nested features need `gh`. Tested with stubs; behaviour against real Claude Code and GitHub
  is not fully verified.

## License

MIT
