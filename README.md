# my-claude-setup-auto-route

A personal Claude Code setup for cheaper workflows. Unofficial, not affiliated with Anthropic.
For now it holds one plugin.

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

## License

MIT
