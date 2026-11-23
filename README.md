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

## Uninstall

```
bash uninstall-claude-setup.sh --dry-run     # show the plan, change nothing
bash uninstall-claude-setup.sh               # asks before doing it (use --yes when not interactive)
```

Nothing is deleted: removed files, plus copies of `settings.json` and `CLAUDE.md` as they were, go to
`~/.claude/uninstalled-<timestamp>/`. It removes only what the installer wrote (agents, hooks, `nested-claude`, status line,
routing file and the two skills), our own hook and `statusLine` entries in `settings.json`, and the `@import` line in
`CLAUDE.md`. It refuses to run while a nested session is alive.

Options: `--purge` also moves `~/.claude/nested` (session history), `--with-ids-layer` also removes the private IDS skills.
Never touched: `review-lessons.md`, `nested-allow.txt`, `*.bak-*`, your own agents/skills/hooks, `"model": "opus"` (the
installer overwrote your previous value; look in `settings.json.bak-*`) and the git read-only allow rules.
The plugin is removed separately: `/plugin uninstall auto-route`.

## Tests

```
bash tests/run.sh          # all suites (about 10 s); needs bash, python3, git
bash tests/run.sh nested   # only suites whose file name contains "nested"
```

The suites run the installer into a throwaway `HOME` and drive `nested-claude` with a stub `claude` (`tests/stubs/claude`),
so they need no network, no `gh` and no API key. They cover installer idempotency and settings merge, the read-only Bash
hook, the model-switch guard, the status line, ticket classification, tier caps, the deny list for pushes, run logging and
`report`. They do not cover real Claude Code or GitHub behaviour. The `auto-route` mod has its own tests
(`claude plugin test .`), which need the `claude` CLI and are not part of CI.

## License

MIT

## agent-monitor (mod)

Watches subagents: `/monitor` prints running count, peak parallel, and the last runs
(type, actual model, duration). A pane titled "Agents" shows the same live.
Rows get a warning when the model differs from the routing map
(scout/Explore -> haiku, critic -> opus, critic-lite -> sonnet), which also reveals
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE`. Also lists nested-claude sessions (status + model) from `~/.claude/nested`.

    /plugin install agent-monitor --marketplace dstwn/my-claude-setup-auto-route

## code-watch (mod)

Pane "Code watch": every file the agent edits (Edit/Write/MultiEdit/NotebookEdit) with +/- lines
and the symbols (def/class/function) in the change; the latest one is highlighted for 10 seconds.

`/code-watch review [base]` writes per-file review notes with LOW/MEDIUM/HIGH risk from `git diff`
(no base = uncommitted work, with base = `base...HEAD`). Risk is heuristic: a changed signature or
removed definition is HIGH, a new definition or a big diff MEDIUM. Add `--ai` to also ask the model
(sonnet) for a one-line note per file; that sends up to 12 KB of the diff to the model and costs tokens.
Without `--ai` nothing leaves your machine.

    /plugin install code-watch --marketplace dstwn/my-claude-setup-auto-route
