#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Claude Code global setup: model routing + auto-chain (mattpocock skills)
# v5 — idempotent (aman di-run ulang), semua global di ~/.claude
#       + hook worktree (salin vendor/.env) + sesi nested (/nested-implement)
#       + auto-routing: nested-claude --tier auto + hook PreModelSwitch (pengaman cache)
#
#   Session utama → Opus 5.5 (medium)  perencanaan, dialog, keputusan
#   Explore/scout → Haiku              baca, grep, git read-only, triage
#   builder       → inherit (= main)   koding, refactor, test
#   critic        → Opus                code review, security audit, arsitektur
# ═══════════════════════════════════════════════════════════════════
set -e

CLAUDE_DIR="$HOME/.claude"
AGENTS_DIR="$CLAUDE_DIR/agents"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
ROUTING="$CLAUDE_DIR/model-routing.md"
HOOK="$HOOKS_DIR/readonly-bash.py"
WT_HOOK="$HOOKS_DIR/worktree-create.sh"
GUARD_HOOK="$HOOKS_DIR/model-switch-guard.py"
STATUS_PY="$CLAUDE_DIR/statusline.py"
NESTED_BIN="$CLAUDE_DIR/bin/nested-claude"
SKILL_DIR="$CLAUDE_DIR/skills/nested-implement"
IMPORT_LINE='@~/.claude/model-routing.md'
TS=$(date +%Y%m%d-%H%M%S)

if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ python3 dibutuhkan (untuk hook read-only & merge settings.json)."
  exit 1
fi

ask() { # $1 = pertanyaan, $2 = default
  local ans=""
  read -rp "$1 " ans || ans=""
  echo "${ans:-$2}"
}

mkdir -p "$AGENTS_DIR" "$HOOKS_DIR"

install_file() { # $1 = tujuan; isi dari stdin. Backup hanya jika file lama berbeda.
  local tmp; tmp=$(mktemp); cat > "$tmp"
  if [ -f "$1" ] && ! cmp -s "$tmp" "$1"; then cp "$1" "$1.bak-$TS"; fi
  mv "$tmp" "$1"; chmod 644 "$1"
}

# ─── Hook: batasi Bash agar benar-benar read-only ───────────────────
install_file "$HOOK" << 'HOOKEOF'
#!/usr/bin/env python3
"""PreToolUse hook: izinkan hanya perintah Bash read-only (agent scout & critic).
Exit 0 = izinkan. Exit 2 = blokir (stderr dikirim balik ke agent)."""
import json, re, shlex, sys

def block(msg):
    sys.stderr.write("BLOCKED (agent read-only): " + msg + "\n")
    sys.exit(2)

try:
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    block("input hook tidak terbaca")

if not isinstance(cmd, str) or not cmd.strip():
    sys.exit(0)

if re.search(r"[;&<>`\n]|\$\(", cmd):
    block("operator shell ( ; & < > ` $( ) tidak diizinkan")

try:
    lex = shlex.shlex(cmd, posix=True, punctuation_chars="|")
    lex.whitespace_split = True
    tokens = list(lex)
except ValueError:
    block("quote tidak seimbang")

segments, cur = [], []
for t in tokens:
    if t and set(t) == {"|"}:
        if t != "|" or not cur:
            block("pipa tidak valid")
        segments.append(cur)
        cur = []
    else:
        cur.append(t)
if not cur:
    block("perintah kosong setelah pipa")
segments.append(cur)

SIMPLE = {"ls", "cat", "head", "tail", "wc", "grep", "rg", "tree", "pwd", "sort",
          "uniq", "cut", "stat", "file", "which", "diff", "find", "du",
          "basename", "dirname"}
GIT_SAFE = {"status", "log", "diff", "show", "blame", "rev-parse", "ls-files",
            "shortlog", "describe", "rev-list", "ls-tree", "cat-file"}
BAD_EXACT = {"--pre", "--pre-glob", "-exec", "-execdir", "-ok", "-okdir",
             "-delete", "-fprint", "-fls"}
BAD_PREFIX = ("--output", "--ext-diff", "--exec-path", "--pre=", "--pre-glob=")
BRANCH_FLAGS = {"-a", "-r", "-v", "-vv", "--list", "-l", "--show-current",
                "--merged", "--no-merged", "--contains", "--all", "--remotes",
                "--verbose"}
BRANCH_LIST = {"--list", "-l", "--merged", "--no-merged", "--contains"}

for seg in segments:
    name, args = seg[0], seg[1:]
    if any(a in BAD_EXACT or a.startswith(BAD_PREFIX) for a in args):
        block("argumen berbahaya: " + " ".join(args))
    if name == "git":
        if not args:
            block("git tanpa subcommand")
        sub, rest = args[0], args[1:]
        if sub in GIT_SAFE:
            continue
        if sub == "branch":
            flags = [a for a in rest if a.startswith("-")]
            plain = [a for a in rest if not a.startswith("-")]
            if any(f not in BRANCH_FLAGS for f in flags):
                block("git branch: flag tidak diizinkan")
            if plain and not any(f in BRANCH_LIST for f in flags):
                block("git branch: membuat/mengubah cabang tidak diizinkan")
            continue
        if sub == "remote":
            if all(a in ("-v", "--verbose") for a in rest):
                continue
            block("git remote: hanya -v yang diizinkan")
        block("git %s tidak diizinkan (hanya read-only)" % sub)
    elif name in SIMPLE:
        if name in ("sort", "tree") and any(a.startswith("-o") for a in args):
            block("opsi output file tidak diizinkan")
    else:
        block("perintah '%s' tidak ada di allowlist read-only" % name)

sys.exit(0)
HOOKEOF
chmod +x "$HOOK"
echo "✅ hooks/readonly-bash.py"

# ─── Self-test hook ─────────────────────────────────────────────────
hook_expect() { # $1 = exit code yang diharapkan, $2 = perintah
  local json rc=0
  json=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$2")
  printf '%s' "$json" | python3 "$HOOK" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne "$1" ]; then
    echo "❌ self-test gagal (harap $1, dapat $rc): $2"
    exit 1
  fi
}
hook_expect 0 'git log --oneline -5'
hook_expect 0 'git log --pretty=format:%h -3'
hook_expect 0 'git diff main...HEAD | head -50'
hook_expect 0 'grep -rn "foo|bar" src | wc -l'
hook_expect 0 'git branch -a'
hook_expect 2 'git push origin main'
hook_expect 2 'rm -rf build'
hook_expect 2 'git log > out.txt'
hook_expect 2 'git branch newbranch'
hook_expect 2 'git diff --output=x.patch'
hook_expect 2 'ls || rm x'
hook_expect 2 'find . -name x -delete'
echo "✅ self-test hook lulus (12 kasus)"

# ─── Agent: scout (Haiku) ───────────────────────────────────────────
install_file "$AGENTS_DIR/scout.md" << 'AGENTEOF'
---
name: scout
description: >
  Use proactively for read-only work: searching and reading files, grep,
  summarizing modules, git log/diff/status summaries, listing branches,
  and log triage. Fast and cheap. Prefer this for anything that only
  needs to READ.
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit, MultiEdit
model: haiku
color: green
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "python3 $HOME/.claude/hooks/readonly-bash.py"
---

You are a codebase scout. Explore and summarize; never modify anything.

## Rules
- Bash is restricted to read-only commands (a hook blocks the rest). If a
  command is blocked, do not look for a workaround; report that the task
  needs a write-capable agent.
- Return concise summaries with exact file paths and line numbers.
- When asked to explore a topic, report: relevant files and their roles,
  key functions/types, dependency chains, patterns in use.
- For git tasks: summarize commits, list branches, show diffs. Creating,
  switching or deleting branches is NOT your job.
- Keep the response under 500 words unless asked for more.
AGENTEOF
echo "✅ agents/scout.md   🟢 Haiku"

# ─── Agent: Explore (Haiku) — menimpa built-in Explore agar tidak ikut model session ───
install_file "$AGENTS_DIR/Explore.md" << 'AGENTEOF'
---
name: Explore
description: >
  Fast read-only codebase exploration: find files, search code, read and
  summarize. Use for any lookup that does not need judgment.
tools: Read, Grep, Glob
model: haiku
color: green
---

Search and read only. Report file paths, line numbers and a short summary.
Never edit anything. Keep the answer under 400 words unless asked for more.
AGENTEOF
echo "✅ agents/Explore.md 🟢 Haiku (menggantikan Explore bawaan)"

# ─── Agent: builder (inherit) ────────────────────────────────────────
install_file "$AGENTS_DIR/builder.md" << 'AGENTEOF'
---
name: builder
description: >
  Use for writing and modifying code when the plan or spec is already
  clear: implementation, refactoring, performance optimization, writing
  and running tests, creating/switching git branches. Give it a
  self-contained task (spec path, relevant files, acceptance criteria).
tools: Read, Write, Edit, MultiEdit, Grep, Glob, Bash
model: inherit
color: yellow
---

You are a code builder. You receive context (file paths, summaries, specs)
and implement changes.

## Rules
- Follow the spec or plan. Don't redesign.
- Before coding, read `.claude/review-lessons.md` (repo) and `~/.claude/review-lessons.md` if they exist and follow
  the confirmed lessons (ignore the Pending section).
- Match the repo's existing style and conventions.
- Verify before reporting done: run the project's test and typecheck/build
  commands (see "Verify your work" in the project CLAUDE.md; if absent, find
  them in package.json / Makefile / pyproject and say which you used). Fix
  what you break. Never report "tests pass" without having run them.
- Never push, force-push, or delete branches unless explicitly told to.
- Report back: files changed, what was added/removed, test results, and
  any ambiguity you resolved (state the interpretation you chose).
AGENTEOF
echo "✅ agents/builder.md 🟡 inherit (ikut model session)"

# ─── Agent: builder-isolated (inherit, worktree sendiri) — hanya untuk edit paralel ───
install_file "$AGENTS_DIR/builder-isolated.md" << 'AGENTEOF'
---
name: builder-isolated
description: >
  Same as builder, but every run gets its own git worktree (isolation: worktree). Use ONLY for edits that
  run in parallel with other editing agents (tickets on disjoint files) or for experiments you may throw
  away. It is slower to start (the worktree hook copies vendor/ and .env*): for a normal sequential edit
  use builder.
tools: Read, Write, Edit, MultiEdit, Grep, Glob, Bash
model: inherit
color: orange
isolation: worktree
---

You are a code builder working in your OWN git worktree on your own branch. You receive a self-contained
task (TASK, RELEVANT FILES, RELEVANT SYMBOLS, CONSTRAINTS, EXPECTED RESULT) and implement it.

## Rules
- Follow the spec or plan. Don't redesign. Match the repo's style and conventions.
- Before coding, read `.claude/review-lessons.md` (repo) and `~/.claude/review-lessons.md` if they exist and follow
  the confirmed lessons (ignore the Pending section).
- Stay inside your worktree; never write to the parent checkout.
- Verify before reporting done: run the targeted checks (typecheck, lint, focused tests) from the project
  CLAUDE.md; if it has none, find them in package.json / Makefile / pyproject and say which you used.
- Commit your work in the worktree. Never push, merge, rebase onto other branches, or delete branches.
- Report back: the branch name and worktree path, files changed, test results, and any ambiguity you resolved.
AGENTEOF
echo "✅ agents/builder-isolated.md 🟠 inherit + worktree (hanya untuk edit paralel)"

# ─── Agent: critic (Opus) ───────────────────────────────────────────
install_file "$AGENTS_DIR/critic.md" << 'AGENTEOF'
---
name: critic
description: >
  Use for deep code review, security audit, and architecture decisions
  after implementation is done, for HEAVY work only (security, auth, data
  integrity, destructive DB changes, cross-service, concurrency, architecture)
  or when the user asks for a strict review. Expensive: routine reviews go to
  critic-lite. Give it a self-contained task: what to review (e.g. `git diff
  main...HEAD`) and which spec to review against.
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit, MultiEdit
model: opus
color: red
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "python3 $HOME/.claude/hooks/readonly-bash.py"
---

You are a senior code reviewer and security auditor. You review; you never
fix. Use `git diff` / `git log` (read-only Bash) to see the changes.

## Review axes
1. Correctness: does it match the spec? Edge cases?
2. Security: injection, authz/authn gaps, data leaks, unsafe defaults, secrets.
3. Performance: needless O(n^2), N+1 queries, unnecessary I/O.
4. Architecture: boundaries, abstractions, coupling.
5. Tests: are the changed behaviors covered?
6. Style: repo conventions.

Before reviewing, read `.claude/review-lessons.md` (repo) and `~/.claude/review-lessons.md` if they exist and check
the diff against each confirmed lesson (ignore the Pending section).

## Output
- Verdict: PASS or FAIL
- If FAIL: each issue with file, line, severity (critical/warning) and a
  suggested fix. Fixing is done by someone else.
- If PASS: one short paragraph on what looks good.
- Be concise.
AGENTEOF
echo "✅ agents/critic.md  🔴 Opus"

# ─── Agent: critic-lite (Sonnet) — review rutin LIGHT/MEDIUM ────────
install_file "$AGENTS_DIR/critic-lite.md" << 'AGENTEOF'
---
name: critic-lite
description: >
  Routine code review of one PR or diff for LIGHT/MEDIUM tickets (Sonnet, cheaper than critic). Escalate to
  critic for HEAVY work: security, auth, data integrity, destructive DB changes, cross-service, concurrency,
  architecture. Give it a self-contained task: the refs to diff and the acceptance criteria.
tools: Read, Grep, Glob, Bash
disallowedTools: Write, Edit, MultiEdit
model: sonnet
color: purple
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "python3 $HOME/.claude/hooks/readonly-bash.py"
---

You are a code reviewer for routine changes. If the diff touches security, auth, data integrity,
destructive database operations or concurrency, say so and recommend a re-review by critic (Opus). You review; you never
fix. Use `git diff` / `git log` (read-only Bash) to see the changes.

## Review axes
1. Correctness: does it match the spec? Edge cases?
2. Security: injection, authz/authn gaps, data leaks, unsafe defaults, secrets.
3. Performance: needless O(n^2), N+1 queries, unnecessary I/O.
4. Architecture: boundaries, abstractions, coupling.
5. Tests: are the changed behaviors covered?
6. Style: repo conventions.

Before reviewing, read `.claude/review-lessons.md` (repo) and `~/.claude/review-lessons.md` if they exist and check
the diff against each confirmed lesson (ignore the Pending section).

## Output
- Verdict: PASS or FAIL
- If FAIL: each issue with file, line, severity (critical/warning) and a
  suggested fix. Fixing is done by someone else.
- If PASS: one short paragraph on what looks good.
- Be concise.
AGENTEOF
echo "✅ agents/critic-lite.md  🟣 Sonnet (review rutin; critic Opus untuk HEAVY)"

# ─── model-routing.md (selalu ditimpa; ini file milik script) ───────
install_file "$ROUTING" << 'ROUTEEOF'
# Model routing & auto-chain

## Tiers

| Agent                | Model              | Use for                                               |
|----------------------|--------------------|-------------------------------------------------------|
| Main session         | Opus 5.5, `medium` | Planning, design, all dialog with the user, judgment  |
| `Explore` / `scout`  | Haiku              | Read-only: find, grep, read logs, git log/diff/status |
| `builder`            | inherits main      | Code edits, refactor, perf, tests, branch create/switch |
| `critic`             | Opus               | Review of HEAVY work, security audit, architecture    |
| `critic-lite`        | Sonnet             | Routine review of LIGHT/MEDIUM changes                |

Small models only take work where a mistake is cheap to spot. Code edits and
judgment calls stay on the main model. For a ticket that is a plain
spec-driven bug fix, the user may run that session with `/model sonnet`.
Perf optimization and migrations stay on Opus (Fable for a major migration or
when leading many subagents). Do not raise effort above `high` by default:
test the next model up at a lower effort first.

## Delegation rules
- Scope decides. Narrow work (one or two files, a known location, a question the loaded context already
  answers) stays in this session. Wide work is delegated, and independent parts run in PARALLEL: put all the
  Agent calls in ONE message. One subagent = one responsibility, the smallest independent task.
- Subagents do NOT see this conversation. Every delegation prompt is self-contained and has exactly these
  parts: TASK, RELEVANT FILES, RELEVANT SYMBOLS, CONSTRAINTS, EXPECTED RESULT (plus acceptance criteria and
  the spec/ticket location when they exist).
- Prefer `Explore` / `scout` for any lookup that only reads.
- Interactive skills stay in the main session: `/grill-with-docs`,
  `/to-spec`, `/to-tickets`, `/retro`.
- `/implement`: `scout` gathers context first, then `builder` implements.
- `/code-review`: by risk. HEAVY work (or any HEAVY override, or the user asks for a strict review): `critic`
  (Opus); LIGHT/MEDIUM: `critic-lite` (Sonnet). A re-review after a critical finding and a fix round is always
  `critic`.
- Other skills if installed: `/wayfinder`, `/research` -> `scout`;
  `/diagnosing-bugs` -> `scout` then `builder`; `/tdd`, `/prototype` ->
  `builder`; `/improve-codebase-architecture` -> `critic`;
  `/start-issue` -> `scout`, then continue the chain.
- Parallel fan-out, only for pieces that are truly independent (defaults, lower them when in doubt):
  - Read-only: 3+ separate areas, modules or questions -> one `scout` per area, at most 4 at once.
  - Review: several independent diffs or PRs -> one `critic-lite` / `critic` per diff, at most 4 at once.
  - Edits: tickets that touch disjoint files and do not need each other's output -> `builder-isolated`, at most
    3 at once, then merge the branches yourself. Overlapping files, a shared migration, or one piece needing
    another's result stay sequential on `builder`.
  - Never parallelize steps that depend on a previous result, and never fan out a small task just to save time.
  Every isolated run copies `vendor/` and `.env*` into a new worktree (disk and time), so never use it for
  small edits.
- Never retry a failed step on the same agent more than once, and never repeat the same failed strategy:
  scout poor -> `builder`; builder poor -> main session; `critic`/`critic-lite` findings
  go to `builder` to fix (reviewers never fix).

## Complexity score (picks the model for delegated and nested work)
Score the task: +1 each for single-file, known pattern, isolated component; +2 each for multiple files,
external API, DB, queue/background job; +3 each for architectural decision, security-sensitive,
cross-service, unclear root cause, data integrity.
- 0-2 LIGHT and 3-5 MEDIUM: Sonnet (`--model sonnet` for a nested session). Escalate to Opus when it fails,
  tests fail, the root cause stays unclear, requirements conflict, or the worker reports uncertainty.
- 6+ HEAVY: Opus (Fable for a major migration or when leading many subagents).
- HEAVY overrides always win: security, data integrity, architecture, destructive database operations,
  production incidents, authn/authz, concurrency, distributed systems, cross-service debugging, major
  refactor, ambiguous requirements, difficult root-cause analysis.
- Failed worker: retry once with better context, then escalate. Critical review findings always go to Opus.
- The review tier follows the same score: HEAVY -> `critic` (Opus), LIGHT/MEDIUM -> `critic-lite` (Sonnet).
- The user's explicit model choice wins.

## Context budget
Never load whole repositories, unrelated files, `node_modules`, `vendor`, generated files, build output,
lockfiles, or unrelated docs/tests. Search a symbol, open the relevant file, then its references: smallest
scope first. Order of savings: no extra agent calls, no extra context, cheapest capable model, targeted
verification, escalate only when needed, concise answers.

## Team conventions (skills, loaded only when needed)
- Running `/to-tickets` or breaking a spec into tickets: also invoke the `to-tickets-preferences` skill if it is installed.
- A person's review feedback on a PR (comments, requested changes): use the `/receiving-codereview` skill.
- Work that comes from a spec and tickets (`/to-tickets`, `/implement-spec`, `/nested-implement`): if a team-conventions
  skill such as `ids-spec-parallel-pr` is installed, invoke it; it overrides the defaults in `/nested-implement`
  (branch and PR naming, Mode A single PR or Mode B per-ticket PRs).

## Verify your work (applies to every project)
- Before reporting any ticket or fix as done, run the targeted checks for the change (typecheck, lint,
  focused tests); larger diffs and every PR get the broader suite, while trivial edits (typo, rename, format)
  do not need the full suite. Correctness beats token savings. Take the commands from the project CLAUDE.md
  ("Verify your work" section). If the project does not document them, find
  them (package.json scripts, Makefile, pyproject, Cargo.toml, go.mod), use
  them, and tell the user which commands you used so they can be added to the
  project CLAUDE.md.
- Every ticket produced by `/to-tickets` must name one command that proves it
  is done.
- Order of escalation when a result is not good enough: first make sure the
  work can be verified, then raise effort one level, then move one model up
  at a lower effort.
- If checks are automatic: run at low effort and re-run only failures at high.

## Main flow (auto-chain)

Trigger: the user asks to implement a feature, or says "jalankan flow" /
"run the flow" / "full flow".

```
/grill-with-docs -> /to-spec -> /to-tickets -> [CHECKPOINT] -> /implement -> /code-review -> /retro
```

1. `/grill-with-docs` (main). Interactive. Wait until the plan is resolved.
2. `/to-spec` (main). Proceed automatically.
3. `/to-tickets` (main). Then STOP: show the ticket list and wait for the
   user's approval or edits. This is the only mandatory pause after grill.
4. `/implement`. Per ticket, in dependency order: `scout` then `builder`,
   then run the ticket's proving command plus test and typecheck.
5. `/code-review` -> `critic` or `critic-lite` (by risk, see Delegation rules) against the spec.
   PASS -> continue. FAIL -> `builder` fixes, `critic` re-reviews (max 2 loops,
   then ask the user).
6. `/retro` (main). Final summary.

## Bug fix chain
`/diagnosing-bugs` (`scout`) -> fix with `/tdd` or `/implement` (`builder`)
-> `/code-review` (`critic` or `critic-lite`, by risk) -> report.

## Issue chain
When the user mentions an issue number: `/start-issue` (`scout`) ->
`/implement` (`builder`) -> `/code-review` (`critic` or `critic-lite`, by risk) -> report.

## Status reporting
- Between steps print one line: `✅ <step> done (<agent>/<model>) -> next: <step> (<agent>/<model>)`.
- Final summary: what changed, which agents ran on which models, retries.

## Nested sessions (a separate `claude` process instead of subagents)
- If the user asks for a "nested session" / "sesi terpisah" (also together with `/implement-spec` or
  `/implement`), do NOT delegate to subagents. Use the `/nested-implement` skill: it holds the whole
  procedure (ticket-key conventions, Mode A/B, parent branch, parallel waves, dependencies, risk-based per-PR review
  with fix rounds, multi-repo). This session only supervises and never edits the repo itself.
- Everything the nested session needs must be in its task file: it cannot ask questions.
- Suggest, never switch on your own: when `/implement-spec` (or `/implement` on a parent issue) runs WITHOUT
  nested wording and the work has 3+ tickets, or tickets in more than one repo, or 2+ parallel tickets (count
  them from the spec/issue or with `nested-claude subissues <url>`), say ONE sentence in the user's language:
  it is an epic of N tickets, `/nested-implement` can do it one PR per ticket unattended but costs more, and
  you continue in this session as asked unless they reply "nested". Say it once per run, ask no question, and
  do not do this inside a `NESTED RUN` session.

## If YOU are the nested session
- If your prompt starts with `NESTED RUN`: skip the auto-chain (no `/grill-with-docs`,
  `/to-spec`, `/to-tickets`), never ask the user anything, follow the rules in the prompt, and end
  with `PR: <url>` or `BLOCKED: <reason>`.

## Worktrees
- The `WorktreeCreate` hook (`~/.claude/hooks/worktree-create.sh`) creates worktrees under
  `.claude/worktrees/` and copies untracked local files (`.env*`, `vendor/`, plus anything listed in
  the project's `.worktreeinclude`, gitignore syntax) so tests can run inside them.

## Model env vars
- `CLAUDE_CODE_SUBAGENT_MODEL` only sets the default for subagents that have
  no `model:` of their own (current Claude Code). Do not set
  `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`: it makes every agent ignore its own
  `model:` field.
- `/model` also moves every subagent that inherits the main model (`builder`).
ROUTEEOF
echo "✅ model-routing.md"

# ─── Hook worktree: salin vendor/ dan .env* ke worktree baru ────────
mkdir -p "$CLAUDE_DIR/bin" "$SKILL_DIR" "$CLAUDE_DIR/skills/receiving-codereview"
install_file "$WT_HOOK" << 'WTHOOKEOF'
#!/bin/bash
# WorktreeCreate hook (Claude Code): bikin git worktree LENGKAP dengan file lokal yang tidak ikut git
# (.env*, vendor/, dan isi .worktreeinclude bila ada), supaya test bisa jalan di worktree.
#
# Kontrak hook : stdin = JSON {"name": "..."} ; stdout = HANYA path absolut worktree ; log -> stderr.
# Env opsional : WORKTREE_BRANCH (default worktree-<slug>), WORKTREE_BASE_REF (default HEAD).
# Juga dipanggil langsung oleh ~/.claude/bin/nested-claude.
set -euo pipefail
log() { echo "[worktree-create] $*" >&2; }

INPUT=$(cat)
NAME=$(printf '%s' "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)
[ -n "$NAME" ] || { log "field name kosong"; exit 1; }
case "$NAME" in *[!A-Za-z0-9._#/-]*) log "nama tidak valid: $NAME"; exit 1;; esac
SLUG=$(printf '%s' "$NAME" | tr '/#' '--' | sed 's/^[-.]*//')
[ -n "$SLUG" ] || { log "nama tidak valid: $NAME"; exit 1; }

PROJECT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
git -C "$PROJECT" rev-parse --git-dir >/dev/null 2>&1 || { log "bukan repo git: $PROJECT"; exit 1; }
# sumber file lokal = worktree UTAMA (di sanalah vendor/.env berada), walau dipanggil dari worktree lain
MAIN=$(git -C "$PROJECT" worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')
cd "$MAIN"

BRANCH="${WORKTREE_BRANCH:-worktree-$SLUG}"
BASE="${WORKTREE_BASE_REF:-HEAD}"
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || { log "nama branch tidak valid: $BRANCH"; exit 1; }

# jangan sampai .claude/worktrees/ ikut ke-commit (aturan lokal saja, tidak mengubah repo)
GITCOMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd)
mkdir -p "$GITCOMMON/info"
grep -qxF '.claude/worktrees/' "$GITCOMMON/info/exclude" 2>/dev/null || echo '.claude/worktrees/' >> "$GITCOMMON/info/exclude"

DEST="$MAIN/.claude/worktrees/$SLUG"
if [ -d "$DEST" ] && git -C "$DEST" rev-parse --git-dir >/dev/null 2>&1; then
  log "worktree sudah ada, dipakai ulang: $DEST"
else
  mkdir -p "$(dirname "$DEST")"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$DEST" "$BRANCH" >&2
  else
    git worktree add -b "$BRANCH" "$DEST" "$BASE" >&2
  fi
fi

copy_into() { # $1 = path relatif terhadap $MAIN (file atau folder)
  local rel="${1%/}" src dst parent
  src="$MAIN/$rel"; dst="$DEST/$rel"; parent=$(dirname "$dst")
  [ -e "$src" ] || return 0
  [ -e "$dst" ] && return 0            # jangan menimpa (mis. file yang sudah dilacak git)
  mkdir -p "$parent"
  if [ "$(uname -s)" = "Darwin" ]; then
    cp -Rc "$src" "$parent/" 2>/dev/null || cp -R "$src" "$parent/"          # clonefile (APFS) lalu fallback
  else
    cp -a --reflink=auto "$src" "$parent/" 2>/dev/null || cp -a "$src" "$parent/"
  fi
  log "disalin: $rel"
}

# daftar pola: .worktreeinclude milik project (sintaks gitignore) atau default
PATTERNS="$MAIN/.worktreeinclude"
if [ ! -f "$PATTERNS" ]; then
  PATTERNS=$(mktemp); trap 'rm -f "$PATTERNS"' EXIT
  printf '.env\n.env.*\nvendor/\n' > "$PATTERNS"
fi
# hanya file yang cocok dengan pola DAN memang di-gitignore (sama seperti aturan resmi .worktreeinclude)
git ls-files --others --ignored --exclude-from="$PATTERNS" --directory | while IFS= read -r p; do
  git check-ignore -q -- "${p%/}" || continue
  copy_into "$p"
done

printf '%s\n' "$DEST"
WTHOOKEOF
chmod +x "$WT_HOOK"
echo "✅ hooks/worktree-create.sh"

WT_HOOK_OK=0
if command -v git >/dev/null 2>&1; then
  T=$(cd "$(mktemp -d)" && pwd -P)
  (
    cd "$T" && git init -q r && cd r
    git config user.email t@t; git config user.name t
    printf 'vendor/\n.env\n' > .gitignore; echo a > a.txt; git add -A; git commit -qm i
    echo S=1 > .env; mkdir -p vendor/p; echo x > vendor/p/f
    out=$(printf '{"name":"selftest"}' | CLAUDE_PROJECT_DIR="$T/r" "$WT_HOOK" 2>/dev/null)
    [ "$out" = "$T/r/.claude/worktrees/selftest" ] && [ -f "$out/.env" ] && [ -f "$out/vendor/p/f" ] && [ -f "$out/a.txt" ]
  ) && WT_HOOK_OK=1
  rm -rf "$T"
fi
if [ "$WT_HOOK_OK" = "1" ]; then
  echo "✅ self-test hook worktree lulus (vendor + .env tersalin)"
else
  echo "⚠️  self-test hook worktree GAGAL atau git tidak ada: hook tidak akan didaftarkan"
fi

# ─── Hook: pengaman ganti model (PreModelSwitch) ─────────────────────
install_file "$GUARD_HOOK" << 'GUARDEOF'
#!/usr/bin/env python3
# PreModelSwitch: pengaman cache saat ganti model lewat /model.
# Konteks kecil atau cache dingin -> allow (lewati konfirmasi bawaan, tidak ada yang hilang).
# Konteks besar + cache hangat    -> ask dengan angka biaya (hanya /model interaktif yang bisa menampilkan ask).
# Berlaku dua arah (turun dan naik). Ambang: env CLAUDE_SWITCH_GUARD_TOKENS (default 40000).
# Apa pun yang salah -> diam (exit 0 tanpa output) = perilaku bawaan Claude Code.
import json, os, sys

def main():
    try:
        d = json.load(sys.stdin)
        if d.get("hook_event_name") != "PreModelSwitch" or d.get("source") != "command":
            return
        try:
            limit = int(os.environ.get("CLAUDE_SWITCH_GUARD_TOKENS", "40000"))
        except ValueError:
            limit = 40000
        tokens = int(d.get("context_tokens") or 0)
        warm = bool(d.get("prompt_cache_warm"))
        if not warm or tokens < limit:
            out = {"hookSpecificOutput": {"hookEventName": "PreModelSwitch", "permissionDecision": "allow"}}
        else:
            usd = d.get("estimated_cache_write_usd")
            cost = f" (~${float(usd):.2f} tulis ulang cache)" if isinstance(usd, (int, float)) else ""
            reason = (f"Ganti {d.get('from_model')} -> {d.get('to_model')} membuang cache hangat dan mengirim ulang "
                      f"~{tokens // 1000}k token{cost}. Lanjut? Lebih murah: biarkan model ini, atau "
                      f"delegasikan ke subagent/nested session.")
            out = {"hookSpecificOutput": {"hookEventName": "PreModelSwitch",
                                          "permissionDecision": "ask", "permissionDecisionReason": reason}}
        print(json.dumps(out))
    except Exception:
        return

main()
GUARDEOF
chmod +x "$GUARD_HOOK"
echo "✅ hooks/model-switch-guard.py"

GUARD_OK=0
g1=$(printf '%s' '{"hook_event_name":"PreModelSwitch","source":"command","context_tokens":9000,"prompt_cache_warm":true}' | python3 -I "$GUARD_HOOK" 2>/dev/null)
g2=$(printf '%s' '{"hook_event_name":"PreModelSwitch","source":"command","context_tokens":200000,"prompt_cache_warm":true}' | python3 -I "$GUARD_HOOK" 2>/dev/null)
g3=$(printf '%s' 'bukan json' | python3 -I "$GUARD_HOOK" 2>/dev/null; echo "rc=$?")
case "$g1" in *'"allow"'*) case "$g2" in *'"ask"'*) [ "$g3" = "rc=0" ] && GUARD_OK=1;; esac;; esac
if [ "$GUARD_OK" = "1" ]; then
  echo "✅ self-test model-switch-guard lulus (kecil=allow, besar+hangat=ask, input rusak=diam)"
else
  echo "⚠️  self-test model-switch-guard GAGAL: hook tidak akan didaftarkan"
fi

# ─── Status line: model · effort · konteks · sesi nested ─────────────
install_file "$STATUS_PY" << 'STATUSEOF'
#!/usr/bin/env python3
# Status line: model aktif · effort · konteks · sesi nested yang sedang berjalan.
# Hanya MENAMPILKAN keadaan nyata (Claude Code tidak mengizinkan hook memilih model sesi utama).
import glob, json, os, sys

def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    m = (d.get("model") or {}).get("display_name") or (d.get("model") or {}).get("id") or "claude"
    parts = [m]
    lvl = (d.get("effort") or {}).get("level")
    if lvl:
        parts.append(str(lvl))
    cw = d.get("context_window") or {}
    tok = cw.get("total_input_tokens")
    if isinstance(tok, (int, float)) and tok > 0:
        s = f"ctx {int(tok) // 1000}k"
        pct = cw.get("used_percentage")
        if isinstance(pct, (int, float)):
            s += f" ({int(pct)}%)"
        parts.append(s)
    root = os.environ.get("NESTED_STATE_DIR") or os.path.expanduser("~/.claude/nested")
    run = []
    for sd in glob.glob(os.path.join(root, "*")):
        try:
            if open(os.path.join(sd, "status")).read().strip() != "RUNNING":
                continue
            os.kill(int(open(os.path.join(sd, "pid")).read().strip()), 0)
            run.append(open(os.path.join(sd, "model")).read().strip() or "?")
        except Exception:
            continue
    if run:
        shown = ", ".join(run[:3]) + (f" +{len(run) - 3}" if len(run) > 3 else "")
        parts.append(f"nested {len(run)}: {shown}")
    print(" · ".join(parts))

main()
STATUSEOF
chmod +x "$STATUS_PY"
echo "✅ statusline.py"
STATUS_OK=0
sl=$(printf '%s' '{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"context_window":{"total_input_tokens":42000,"used_percentage":21}}' | NESTED_STATE_DIR=/nonexistent python3 -I "$STATUS_PY" 2>/dev/null)
[ "$sl" = "Opus 5.5 · high · ctx 42k (21%)" ] && STATUS_OK=1
if [ "$STATUS_OK" = "1" ]; then echo "✅ self-test statusline lulus: $sl"; else echo "⚠️  self-test statusline GAGAL: tidak didaftarkan"; fi

# ─── Launcher sesi nested + skill supervisor ────────────────────────
install_file "$NESTED_BIN" << 'NESTLAUNCHEOF'
#!/bin/bash
# nested-claude — sesi Claude Code terpisah (nested) di git worktree sendiri, dengan log, status, dan batas aman.
#
#   nested-claude start  --name N --task-file F [--branch B] [--model opus] [--max-turns 150]
#                        [--max-budget 10] [--repo DIR] [--base REF] [--skill poteto-mode] [--allow 'Bash(cmd:*)']...
#                        [--stacked-on BRANCH]   # stacked PR: cabang & PR dibuat di atas BRANCH (sub-issue sebelumnya)
#                        [--reuse NAME --fix-pr URL]   # ronde perbaikan review: pakai worktree & cabang sesi NAME, tanpa PR baru
#                        [--ids KEY-123] [--draft]     # ticket key (awalan commit, judul PR) dan PR draft
#                        [--tier light|medium|heavy|auto|auto-llm]   # batas default: light 60 turn/$3, medium 100/$6, heavy 150/$10
#                              auto = klasifikasi heuristik dari task file (light/medium -> sonnet, heavy -> opus; --model eksplisit menang)
#                              auto-llm = sama, tapi Haiku ikut menilai (gagal/timeout -> heuristik); override HEAVY tidak bisa diturunkan
#   nested-claude classify TASK_FILE [--llm]    # tampilkan tier/model hasil klasifikasi tanpa menjalankan apa pun
#   nested-claude report [--days N] [--json]    # rangkum riwayat sesi (runs.jsonl: tier, model, turn, biaya, hasil) + saran setel ambang
#   nested-claude wait NAME [NAME...] [--timeout 540] [--stall 600]   # blokir sampai ada yang selesai/mati/macet/timeout
#   nested-claude parent-branch --repo DIR --branch KEY-123-slug [--base REF] [--no-empty-commit] [--no-push]
#   nested-claude repo-path OWNER/REPO         # cari clone lokal repo (nested-repos.txt atau $NESTED_WORKSPACE, default ~/Work)
#   nested-claude subissues ISSUE_URL           # JSON: sub-issue/ticket (native atau tabel Child tickets), urutan, gelombang, dasar stack, yang dilewati, siklus
#   nested-claude status NAME
#   nested-claude stop   NAME
#   nested-claude list
#
# `start` berjalan di foreground sampai sesi nested selesai: panggil lewat Bash dengan run_in_background.
# State: ~/.claude/nested/<NAME>/ (prompt.md, log.ndjson, stderr.log, status, result.json, worktree, pid).
set -uo pipefail

STATE_ROOT="${NESTED_STATE_DIR:-$HOME/.claude/nested}"
HOOK="${NESTED_WORKTREE_HOOK:-$HOME/.claude/hooks/worktree-create.sh}"
CLAUDE_BIN="${NESTED_CLAUDE_BIN:-claude}"

die() { echo "nested-claude: $*" >&2; exit 1; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Klasifikasi tiket -> tier/model (skor sama dengan model-routing.md; override HEAVY selalu menang).
classify_task() { # $1=task file, $2="llm" untuk menyertakan Haiku. Hasil: CLS_TIER CLS_MODEL CLS_INFO
  local f="$1" use_llm="${2:-}" out h_tier h_score h_over h_sig l_tier=""
  out=$(python3 -I - "$f" << 'PYCLS'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
t = text.lower()
# HEAVY override: selalu menang (sama dengan daftar di model-routing.md)
OVERRIDE = {
 "security": r"\bsecurity\b|\bvulnerab|\bxss\b|\bcsrf\b|\bsql injection\b|\bencrypt|\bsecrets?\b",
 "authn/authz": r"\bauth(n|z|entication|orization|orisation)?\b|\boauth\b|\bsso\b|\bpermissions?\b|\brbac\b",
 "data integrity/destructive": r"\bdrop (table|column)\b|\btruncate\b|\bdelete from\b|data (loss|integrity|corruption)|\bbackfill\b",
 "payments": r"\bpayments?\b|\bbilling\b|\binvoice calculation\b|\brefunds?\b",
 "production incident": r"\bincident\b|\bhotfix\b|\boutage\b|\bpost-?mortem\b",
 "concurrency/distributed": r"\bconcurren|\brace condition\b|\bdeadlock\b|\bdistributed\b|\bidempoten",
 "architecture": r"\barchitectur|\bmajor refactor\b|\bre-?architect|\bcross-service\b|\bmonolith\b",
 "unclear root cause": r"\broot cause\b|\bintermittent\b|\bflaky\b|\bcannot reproduce\b|\bunclear\b",
}
MEDIUM = {
 "api/integration": r"\bapi\b|\bwebhook|\bendpoint|\bintegration\b|\bthird[- ]party\b",
 "database": r"\bdatabase\b|\bmigrations?\b|\bschema\b|\bquer(y|ies)\b|\beloquent\b|\bindex(es)?\b",
 "queue/job": r"\bqueue|\bjobs?\b|\bhorizon\b|\bscheduler|\bcron\b|\bbackground\b",
 "multi-file": r"\bmultiple (files|components|modules)\b|\bacross\b|\bseveral\b|\bend-to-end\b|\be2e\b",
}
hits_o = [k for k, r in OVERRIDE.items() if re.search(r, t)]
hits_m = [k for k, r in MEDIUM.items() if re.search(r, t)]
bullets = len(re.findall(r"^\s*(?:- \[[ xX]\]|[-*] )", text, re.M))
score = 2 * len(hits_m) + 3 * len(hits_o) + (1 if len(text) > 3000 else 0) + (1 if len(text) > 8000 else 0) + (1 if bullets > 8 else 0)
if hits_o:
    tier = "heavy"
elif score >= 6:
    tier = "heavy"
elif score >= 3:
    tier = "medium"
else:
    tier = "light"
print("tier=%s" % tier)
print("score=%d" % score)
print("override=%s" % ",".join(hits_o))
print("signals=%s" % ",".join(hits_m))
PYCLS
  ) || out=""
  h_tier=$(printf '%s\n' "$out" | sed -n 's/^tier=//p'); h_score=$(printf '%s\n' "$out" | sed -n 's/^score=//p')
  h_over=$(printf '%s\n' "$out" | sed -n 's/^override=//p'); h_sig=$(printf '%s\n' "$out" | sed -n 's/^signals=//p')
  [ -n "$h_tier" ] || { h_tier=medium; h_score=?; }   # classifier rusak -> medium (aman)
  CLS_TIER="$h_tier"; CLS_SCORE="$h_score"; CLS_OVER="$h_over"; CLS_SIG="$h_sig"
  CLS_INFO="heuristik score=$h_score override=${h_over:-none} signals=${h_sig:-none}"
  if [ "$use_llm" = llm ] && [ -z "$h_over" ] && command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    local pr="Classify the engineering ticket below by implementation difficulty. Reply with exactly one word: light (small, local, known pattern), medium (several files or an integration, clear requirements) or heavy (architecture, security, data integrity, unclear root cause, large refactor). If unsure reply medium.

$(head -c 6000 "$f")"
    local ans
    ans=$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT timeout 25 "$CLAUDE_BIN" -p "$pr" --model haiku --max-turns 1 \
          --permission-mode dontAsk --max-budget-usd 0.05 < /dev/null 2>/dev/null | tr 'A-Z' 'a-z' | grep -o -w -E 'light|medium|heavy' | head -1) || ans=""
    if [ -n "$ans" ]; then l_tier="$ans"; CLS_TIER="$ans"; CLS_INFO="$CLS_INFO; haiku=$ans"
    else CLS_INFO="$CLS_INFO; haiku=gagal(pakai heuristik)"; fi
  fi
  case "$CLS_TIER" in heavy) CLS_MODEL=opus;; *) CLS_MODEL=sonnet;; esac
}

cmd_classify() {
  local f="${1:-}" llm=""; shift || true
  [ "${1:-}" = "--llm" ] && llm=llm
  [ -f "$f" ] || die "classify: task file tidak ditemukan: ${f:-<kosong>}"
  classify_task "$f" "$llm"
  printf 'tier=%s\nmodel=%s\ninfo=%s\n' "$CLS_TIER" "$CLS_MODEL" "$CLS_INFO"
}

cmd_start() {
  local model_set="" name="" branch="" task_file="" model="opus" turns="" budget="" tier="" repo="" base="" skill="" stacked_on="" pr_base="" reuse="" fix_pr="" ids="" draft=""
  local -a extra_allow=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)       name="${2:?--name butuh nilai}"; shift 2;;
      --branch)     branch="${2:?--branch butuh nilai}"; shift 2;;
      --task-file)  task_file="${2:?--task-file butuh nilai}"; shift 2;;
      --model)      model="${2:?--model butuh nilai}"; model_set=1; shift 2;;
      --tier)       tier="${2:?--tier butuh nilai}"; shift 2;;
      --max-turns)  turns="${2:?--max-turns butuh nilai}"; shift 2;;
      --max-budget) budget="${2:?--max-budget butuh nilai}"; shift 2;;
      --repo)       repo="${2:?--repo butuh nilai}"; shift 2;;
      --base)       base="${2:?--base butuh nilai}"; shift 2;;
      --skill)      skill="${2:?--skill butuh nilai}"; shift 2;;
      --stacked-on) stacked_on="${2:?--stacked-on butuh nilai}"; shift 2;;
      --reuse)      reuse="${2:?--reuse butuh nilai}"; shift 2;;
      --fix-pr)     fix_pr="${2:?--fix-pr butuh nilai}"; shift 2;;
      --ids)        ids="${2:?--ids butuh nilai}"; shift 2;;
      --draft)      draft=1; shift;;
      --allow)      extra_allow+=("${2:?--allow butuh nilai}"); shift 2;;
      *) die "opsi tidak dikenal: $1";;
    esac
  done
  local d_turns d_budget tier_arg="$tier"
  CLS_SCORE=""; CLS_OVER=""; CLS_SIG=""
  case "$tier" in auto|auto-llm)
    [ -f "$task_file" ] || die "--task-file tidak ditemukan: $task_file"
    classify_task "$task_file" "$([ "$tier" = auto-llm ] && echo llm)"
    tier="$CLS_TIER"
    [ -n "$model_set" ] || model="$CLS_MODEL"
    echo "nested-claude: auto-tier -> $tier / $model ($CLS_INFO)";;
  esac
  case "$tier" in
    light)       d_turns=60;  d_budget=3;;
    medium)      d_turns=100; d_budget=6;;
    heavy|"")    d_turns=150; d_budget=10;;
    *) die "--tier harus light, medium, heavy, auto, atau auto-llm";;
  esac
  [ -n "$turns" ]  || turns=$d_turns
  [ -n "$budget" ] || budget=$d_budget
  [ -n "$name" ] || die "--name wajib"
  case "$name" in *[!A-Za-z0-9._-]*|"") die "--name hanya boleh huruf, angka, . _ -";; esac
  [ -f "$task_file" ] || die "--task-file tidak ditemukan: $task_file"
  [ -x "$HOOK" ] || die "hook worktree tidak ada/eksekutabel: $HOOK"
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "perintah '$CLAUDE_BIN' tidak ditemukan"
  [ -n "$repo" ] || repo=$(git rev-parse --show-toplevel 2>/dev/null) || die "bukan di dalam repo git; pakai --repo"
  [ -n "$branch" ] || branch="impl/$name"
  if [ -n "$reuse" ]; then
    [ "$reuse" != "$name" ] || die "--name harus berbeda dari --reuse (log sesi awal tetap disimpan)"
    [ -f "$STATE_ROOT/$reuse/worktree" ] || die "--reuse: sesi '$reuse' tidak ditemukan"
  fi
  [ -z "$fix_pr" ] || [ -n "$reuse" ] || die "--fix-pr butuh --reuse"
  case "$ids" in ""|[A-Z]*-[0-9]*) ;; *) die "--ids harus berbentuk KEY-123 (mis. PROJ-123)";; esac
  case "$ids" in *[!A-Za-z0-9-]*) die "--ids harus berbentuk KEY-123 (mis. PROJ-123)";; esac

  local S="$STATE_ROOT/$name"
  if [ -f "$S/pid" ] && alive "$(cat "$S/pid")"; then die "sesi '$name' masih berjalan (pid $(cat "$S/pid"))"; fi
  rm -rf "$S"; mkdir -p "$S"

  local wt
  if [ -n "$reuse" ]; then   # ronde perbaikan: pakai ulang worktree & cabang dari sesi sebelumnya
    wt=$(cat "$STATE_ROOT/$reuse/worktree"); branch=$(cat "$STATE_ROOT/$reuse/branch")
    pr_base=$(cat "$STATE_ROOT/$reuse/pr_base" 2>/dev/null || true)
    { [ -d "$wt" ] && git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; } || die "worktree dari '$reuse' sudah tidak ada: $wt"
    base="(lanjutan $reuse)"
  else
    if [ -n "$stacked_on" ]; then   # stacked PR: dasar cabang & dasar PR = cabang sub-issue sebelumnya
      if git -C "$repo" show-ref --verify --quiet "refs/heads/$stacked_on"; then
        [ -n "$base" ] || base="$stacked_on"
      elif git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$stacked_on"; then
        [ -n "$base" ] || base="origin/$stacked_on"
      else
        die "--stacked-on: cabang '$stacked_on' tidak ditemukan (lokal maupun origin)"
      fi
      pr_base="$stacked_on"
    fi
    if [ -z "$base" ]; then   # default: cabang default remote yang terbaru, kalau tidak ada: HEAD
      git -C "$repo" fetch origin --quiet 2>/dev/null || true
      base=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
      base="${base:-HEAD}"
    fi

    wt=$(printf '{"name":"%s"}' "$name" | CLAUDE_PROJECT_DIR="$repo" WORKTREE_BRANCH="$branch" WORKTREE_BASE_REF="$base" "$HOOK" 2>"$S/worktree.log") \
      || { cat "$S/worktree.log" >&2; die "gagal membuat worktree"; }
  fi
  echo "$wt" > "$S/worktree"; echo "$branch" > "$S/branch"; echo "${pr_base:-}" > "$S/pr_base"

  # izin: daftar sempit (mode dontAsk menolak semua yang tidak terdaftar, karena sesi ini tidak bisa bertanya)
  local -a ALLOW=(Read Glob Grep Edit Write Skill Agent Task TaskCreate TaskUpdate TodoWrite
    "Bash(git status:*)" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" "Bash(git add:*)"
    "Bash(git commit:*)" "Bash(git switch:*)" "Bash(git fetch:*)" "Bash(git push:*)"
    "Bash(gh issue view:*)" "Bash(gh pr create:*)" "Bash(gh pr view:*)" "Bash(gh pr checks:*)"
    "Bash(gh pr edit:*)" "Bash(gh pr comment:*)" "Bash(gh pr diff:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(mkdir:*)")
  local -a DENY=("Bash(git push --force:*)" "Bash(git push -f:*)" "Bash(git push --force-with-lease:*)"
    "Bash(git push --delete:*)" "Bash(git push origin main:*)" "Bash(git push origin master:*)"
    "Bash(git push origin HEAD:main:*)" "Bash(git push origin HEAD:master:*)"
    "Bash(gh pr merge:*)" "Bash(git reset --hard:*)" "Bash(git clean:*)" "Bash(git branch -D:*)"
    "Bash(rm -rf:*)" "Bash(sudo:*)")
  local f line
  for f in "$HOME/.claude/nested-allow.txt" "$repo/.claude/nested-allow.txt"; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ""|"#"*) continue;; esac
      ALLOW+=("$line")
    done < "$f"
  done
  [ ${#extra_allow[@]} -gt 0 ] && ALLOW+=("${extra_allow[@]}")

  {
    echo "NESTED RUN — non-interactive session supervised by another Claude Code session."
    echo
    echo "Rules:"
    echo "- Never ask questions: nobody can answer. Decide, and record every assumption in the PR description."
    echo "- If you are truly blocked, stop and make your final message start with \"BLOCKED:\" followed by the reason."
    echo "- Do not run /grill-with-docs, /to-spec or /to-tickets; the work is already specified below."
    echo "- If \`.claude/review-lessons.md\` exists in the repo, read it first and follow its confirmed lessons."
    [ -n "$skill" ] && echo "- First invoke the \`$skill\` skill with the Skill tool and follow it for this task."
    if [ -n "$reuse" ]; then
      echo "- Work only in this directory: the existing git worktree on branch \`$branch\`. Never push to main/master, never force-push, never merge."
    else
      echo "- Work only in this directory: a git worktree on branch \`$branch\` (base: $base). Never push to main/master, never force-push, never merge."
    fi
    echo "- Before opening the PR, run the project's tests and typecheck/build; put the evidence (commands and results) in the PR description."
    if [ -n "$ids" ]; then
      echo "- Convention: every commit message starts with \`$ids: \` (for example \`$ids: add export endpoint\`); the PR title must contain \`$ids\`; the PR body must link the spec/epic issue and the ticket issue(s) this PR implements (their URLs are in the task) and mention \`$ids\`."
    fi
    if [ -n "$fix_pr" ]; then
      echo "- A pull request already exists: $fix_pr. Do NOT open another one. The task below contains REVIEW FINDINGS: fix them, add NEW commits only (no rebase, no amend, no force-push), push to the same branch with \`git push\`, then add a short \`gh pr comment\` saying what changed. Re-run the tests and typecheck. Your final message: first line \`PR: $fix_pr\`, then a short summary."
    else
      local pr_cmd="gh pr create"
      if [ -n "$stacked_on" ]; then
        echo "- This is a STACKED pull request: your branch builds on \`$stacked_on\` (an earlier sub-issue). Do not rebase onto main and do not change commits that came from \`$stacked_on\`. Implement only what this task asks."
        pr_cmd="gh pr create --base $pr_base"
      fi
      [ -n "$draft" ] && pr_cmd="$pr_cmd --draft"
      echo "- Finish by opening a pull request from \`$branch\` with \`$pr_cmd\`, linking the issue. Your final message: first line \`PR: <url>\`, then a short summary."
    fi
    echo
    echo "TASK:"
    cat "$task_file"
  } > "$S/prompt.md"

  echo "RUNNING" > "$S/status"; echo "$model/${tier:-none}" > "$S/model"
  python3 -I - "$S/meta.json" "$tier" "${tier_arg:-manual}" "$model" "$turns" "$budget" "$CLS_SCORE" "$CLS_OVER" "$CLS_SIG" "$ids" "${fix_pr:+1}" "${stacked_on:+1}" << 'PYMETA' 2>/dev/null || true
import json, sys
p, tier, src, model, turns, budget, score, over, sig, ids, fix, stacked = sys.argv[1:13]
def num(x):
    try:
        return float(x) if "." in x else int(x)
    except ValueError:
        return None
json.dump({"tier": tier or "none", "tier_source": src if src in ("auto", "auto-llm") else "manual", "model": model,
           "max_turns": num(turns), "max_budget_usd": num(budget), "score": num(score),
           "override": [x for x in over.split(",") if x], "signals": [x for x in sig.split(",") if x],
           "ids": ids or None, "kind": "fix" if fix else "ticket", "stacked": bool(stacked)}, open(p, "w"))
PYMETA
  echo "nested-claude: worktree=$wt branch=$branch base=$base pr_base=${pr_base:-<default>} model=$model tier=${tier:-none} max_turns=$turns max_budget_usd=$budget"
  (
    cd "$wt" || exit 97
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT "$CLAUDE_BIN" -p "$(cat "$S/prompt.md")" \
      --model "$model" --output-format stream-json --verbose \
      --permission-mode dontAsk --max-turns "$turns" --max-budget-usd "$budget" \
      --disallowedTools "${DENY[@]}" \
      --allowedTools "${ALLOW[@]}" \
      < /dev/null > "$S/log.ndjson" 2> "$S/stderr.log"
  ) &
  local cpid=$!
  echo "$cpid" > "$S/pid"
  trap 'touch "$S/stop_requested"; pkill -TERM -P "$cpid" 2>/dev/null; kill -TERM "$cpid" 2>/dev/null' INT TERM
  wait "$cpid"; local rc=$?
  wait "$cpid" 2>/dev/null
  python3 - "$S" "$rc" << 'PY'
import json, os, re, sys
S, rc = sys.argv[1], int(sys.argv[2])
res, sid = None, None
try:
    for line in open(os.path.join(S, "log.ndjson"), encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") == "system" and ev.get("subtype") == "init" and not sid:
            sid = ev.get("session_id")
        if ev.get("type") == "result":
            res = ev
except FileNotFoundError:
    pass
out = {"exit_code": rc, "session_id": (res or {}).get("session_id") or sid}
text = ""
if res:
    for k in ("subtype", "is_error", "num_turns", "total_cost_usd", "duration_ms"):
        out[k] = res.get(k)
    text = res.get("result") if isinstance(res.get("result"), str) else ""
    out["result"] = text
m = re.search(r"https://github\.com/\S+/pull/\d+", text or "")
out["pr_url"] = m.group(0) if m else None
sub = (res or {}).get("subtype") or ""
if os.path.exists(os.path.join(S, "stop_requested")):
    status = "STOPPED"
elif res is None:
    status = "FAILED"
elif text.lstrip().startswith("BLOCKED:"):
    status = "BLOCKED"
elif sub.startswith("error_max"):
    status = "LIMIT"
elif res.get("is_error") or sub != "success":
    status = "FAILED"
elif not out["pr_url"]:
    status = "DONE_NO_PR"
else:
    status = "DONE"
json.dump(out, open(os.path.join(S, "result.json"), "w"), indent=2, ensure_ascii=False)
try:   # satu baris per sesi untuk `nested-claude report` (tanpa teks tiket, hanya angka dan label)
    import time
    meta = {}
    try:
        meta = json.load(open(os.path.join(S, "meta.json")))
    except Exception:
        pass
    row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "name": os.path.basename(S.rstrip("/")), "status": status,
           "turns": out.get("num_turns"), "cost_usd": out.get("total_cost_usd"), "duration_ms": out.get("duration_ms"),
           "pr": bool(out["pr_url"])}
    row.update(meta)
    with open(os.path.join(os.path.dirname(S.rstrip("/")), "runs.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
except Exception:
    pass
open(os.path.join(S, "status"), "w").write(status + "\n")
print("FINISHED status=%s pr=%s turns=%s cost_usd=%s" % (status, out["pr_url"], out.get("num_turns"), out.get("total_cost_usd")))
PY
}

cmd_report() {
  local days="" as_json=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:?--days butuh angka}"; shift 2;;
      --json) as_json=1; shift;;
      *) die "report: opsi tidak dikenal: $1";;
    esac
  done
  python3 -I - "$STATE_ROOT/runs.jsonl" "${days:-0}" "${as_json:-}" << 'PYREPORT'
import json, sys, time, collections
path, days, as_json = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3] == "1"
rows = []
try:
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            rows.append(json.loads(line))
        except Exception:
            pass
except FileNotFoundError:
    pass
if days:
    cut = time.time() - days * 86400
    def ts(r):
        try:
            return time.mktime(time.strptime(r["ts"][:19], "%Y-%m-%dT%H:%M:%S"))
        except Exception:
            return 0
    rows = [r for r in rows if ts(r) >= cut]
if not rows:
    print("(belum ada riwayat sesi%s)" % (" dalam %d hari" % days if days else ""))
    sys.exit(0)

def agg(g):
    n = len(g)
    c = collections.Counter(r.get("status") for r in g)
    cost = [r["cost_usd"] for r in g if isinstance(r.get("cost_usd"), (int, float))]
    turns = [r["turns"] for r in g if isinstance(r.get("turns"), (int, float))]
    cp = [r["cost_usd"] / r["max_budget_usd"] for r in g if isinstance(r.get("cost_usd"), (int, float)) and r.get("max_budget_usd")]
    tp = [r["turns"] / r["max_turns"] for r in g if isinstance(r.get("turns"), (int, float)) and r.get("max_turns")]
    avg = lambda x: sum(x) / len(x) if x else None
    return {"n": n, "done": c["DONE"] / n, "limit": c["LIMIT"] / n, "failed": (c["FAILED"] + c["BLOCKED"] + c["DONE_NO_PR"] + c["STOPPED"]) / n,
            "avg_turns": avg(turns), "avg_cost": avg(cost), "total_cost": sum(cost), "cost_of_cap": avg(cp), "turns_of_cap": avg(tp)}

def bucket(r):
    s = r.get("score")
    if r.get("override"):
        return "override"
    if not isinstance(s, (int, float)):
        return None
    return "0-2" if s <= 2 else "3-5" if s <= 5 else "6+"

groups = {
    "tier/model": collections.defaultdict(list),
    "asal tier": collections.defaultdict(list),
    "skor (hanya auto)": collections.defaultdict(list),
    "jenis": collections.defaultdict(list),
}
for r in rows:
    groups["tier/model"]["%s/%s" % (r.get("tier", "?"), r.get("model", "?"))].append(r)
    groups["asal tier"][r.get("tier_source", "?")].append(r)
    groups["jenis"][r.get("kind", "?")].append(r)
    b = bucket(r) if r.get("tier_source") in ("auto", "auto-llm") else None
    if b:
        groups["skor (hanya auto)"][b].append(r)

res = {k: {kk: agg(v) for kk, v in sorted(g.items())} for k, g in groups.items()}
total = agg(rows)
hints = []
MIN = 5
for key, a in res["tier/model"].items():
    if a["n"] < MIN:
        continue
    if a["limit"] >= 0.2:
        hints.append("%s: %d%% sesi kena batas turn/biaya -> naikkan tier (turunkan ambang skor) atau naikkan batasnya." % (key, round(a["limit"] * 100)))
    if a["failed"] >= 0.3:
        hints.append("%s: %d%% sesi gagal/blocked/tanpa PR -> cek isi task file; tier lebih tinggi mungkin membantu." % (key, round(a["failed"] * 100)))
    if a["done"] >= 0.9 and a["cost_of_cap"] is not None and a["cost_of_cap"] < 0.25 and not key.startswith("light"):
        hints.append("%s: selesai %d%% dengan biaya rata-rata hanya %d%% dari batas -> kandidat tier lebih murah (naikkan ambang skor, atau longgarkan daftar kata kunci override)." % (key, round(a["done"] * 100), round(a["cost_of_cap"] * 100)))
for key, a in res["skor (hanya auto)"].items():
    if a["n"] >= MIN and key == "6+" and a["done"] >= 0.9 and a["cost_of_cap"] is not None and a["cost_of_cap"] < 0.3:
        hints.append("skor 6+: %d%% selesai, biaya %d%% dari batas -> ambang HEAVY (6) mungkin terlalu rendah; coba 7." % (round(a["done"] * 100), round(a["cost_of_cap"] * 100)))
    if a["n"] >= MIN and key == "0-2" and a["limit"] + a["failed"] >= 0.3:
        hints.append("skor 0-2 (light): %d%% bermasalah -> heuristik terlalu optimis; tambah kata kunci MEDIUM atau turunkan ambang." % round((a["limit"] + a["failed"]) * 100))

if as_json:
    print(json.dumps({"total": total, "groups": res, "hints": hints}, indent=2, ensure_ascii=False))
    sys.exit(0)

def pct(x):
    return "-" if x is None else "%d%%" % round(x * 100)
def f(x, d=1):
    return "-" if x is None else ("%.*f" % (d, x))
print("Riwayat: %d sesi, total biaya $%.2f, selesai %s, kena batas %s, gagal %s\n" % (total["n"], total["total_cost"], pct(total["done"]), pct(total["limit"]), pct(total["failed"])))
for title, g in res.items():
    if not g:
        continue
    print("== %s" % title)
    print("%-22s %4s %6s %6s %6s %8s %9s %9s %9s" % ("", "n", "DONE", "LIMIT", "GAGAL", "turn", "biaya", "%batas$", "%batasT"))
    for k, a in g.items():
        print("%-22s %4d %6s %6s %6s %8s %9s %9s %9s" % (k, a["n"], pct(a["done"]), pct(a["limit"]), pct(a["failed"]), f(a["avg_turns"], 0), "$" + f(a["avg_cost"], 2), pct(a["cost_of_cap"]), pct(a["turns_of_cap"])))
    print()
if hints:
    print("Saran (butuh >= %d sesi per kelompok):" % MIN)
    for h in hints:
        print("  - " + h)
else:
    print("Belum ada saran: tiap kelompok butuh >= %d sesi dan pola yang jelas." % MIN)
PYREPORT
}

cmd_parent_branch() {
  local repo="" branch="" base="" empty=1 push=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)            repo="${2:?--repo butuh nilai}"; shift 2;;
      --branch)          branch="${2:?--branch butuh nilai}"; shift 2;;
      --base)            base="${2:?--base butuh nilai}"; shift 2;;
      --no-empty-commit) empty=0; shift;;
      --no-push)         push=0; shift;;
      *) die "opsi tidak dikenal: $1";;
    esac
  done
  [ -d "$repo" ] || die "--repo tidak ditemukan: $repo"
  case "$branch" in [A-Z]*-[0-9]*-[a-z0-9]*) ;; *) die "--branch harus berbentuk KEY-{nomor}-{slug}, mis. PROJ-123-export-csv (slug huruf kecil, tanda hubung)";; esac
  case "$branch" in *[!A-Za-z0-9-]*) die "--branch hanya boleh huruf, angka, tanda hubung";; esac
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "bukan repo git: $repo"
  local ids; ids=$(printf '%s' "$branch" | sed -E 's/^([A-Z][A-Z0-9]*-[0-9]+)-.*/\1/')
  git -C "$repo" fetch origin --quiet 2>/dev/null || true
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    echo "parent_branch=$branch status=exists"
    return 0
  fi
  if [ -z "$base" ]; then
    base=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    base="${base:-HEAD}"
  fi
  git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "base tidak valid: $base"
  local commit
  if [ "$empty" = 1 ]; then   # commit kosong supaya PR parent (draft) bisa dibuka sebelum ada child yang merge
    commit=$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse "$base^{tree}")" -p "$(git -C "$repo" rev-parse "$base^{commit}")" -m "$ids: integration branch") \
      || die "gagal membuat commit kosong (user.name/user.email belum di-set?)"
  else
    commit=$(git -C "$repo" rev-parse "$base^{commit}")
  fi
  git -C "$repo" branch "$branch" "$commit" || die "gagal membuat branch $branch"
  if [ "$push" = 1 ]; then
    git -C "$repo" push -u origin "$branch" >&2 || die "gagal push $branch ke origin"
  fi
  echo "parent_branch=$branch status=created base=$base commit=$commit pushed=$push"
}

cmd_repo_path() {
  local slug="${1:-}"; [ -n "$slug" ] || die "pakai: repo-path OWNER/REPO"
  case "$slug" in */*) ;; *) die "format harus OWNER/REPO";; esac
  local map="${NESTED_REPOS_FILE:-$HOME/.claude/nested-repos.txt}" line k v
  if [ -f "$map" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ""|"#"*) continue;; esac
      k="${line%%=*}"; v="${line#*=}"
      if [ "$k" = "$slug" ] && [ -d "$v" ]; then echo "$v"; return 0; fi
    done < "$map"
  fi
  local root="${NESTED_WORKSPACE:-$HOME/Work}" d url
  if [ -d "$root" ]; then
    for d in "$root"/*/; do
      [ -e "${d}.git" ] || continue
      # baca konfigurasi MENTAH dulu: `remote get-url` menerapkan aturan insteadOf (URL ditulis ulang)
      for url in "$(git -C "$d" config --get remote.origin.url 2>/dev/null)" "$(git -C "$d" remote get-url origin 2>/dev/null)"; do
        url="${url%.git}"
        case "$url" in *"/$slug"|*":$slug") echo "${d%/}"; return 0;; esac
      done
    done
  fi
  die "clone lokal untuk $slug tidak ditemukan (tambahkan '$slug=/path' ke $map)"
}

cmd_subissues() {
  local url="${1:-}"; [ -n "$url" ] || die "pakai: subissues <issue-url>"
  command -v gh >/dev/null 2>&1 || die "gh tidak ditemukan"
  python3 - "$url" << 'PY'
import json, re, subprocess, sys
m = re.match(r"https://github\.com/([^/]+)/([^/]+)/issues/(\d+)", sys.argv[1])
if not m:
    sys.exit("nested-claude: URL issue GitHub tidak valid")
powner, prepo, pnum = m.group(1), m.group(2), int(m.group(3))
phome = "%s/%s" % (powner, prepo)

def key(repo, n):
    return "%s#%d" % (repo.lower(), n)
def repo_of_ref(r):
    return r.rsplit("#", 1)[0]
def num_of_ref(r):
    return int(r.rsplit("#", 1)[1])

def gh(path, soft=False):
    r = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github+json", path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        if soft:
            return None
        sys.exit("nested-claude: gh api gagal untuk %s: %s" % (path, r.stderr.strip()))
    return json.loads(r.stdout)

cache = {}
def issue(repo, n):
    k = key(repo, n)
    if k not in cache:
        cache[k] = gh("repos/%s/issues/%d" % (repo, n), soft=True)
    return cache[k]

def repo_of(obj, default):
    return (obj.get("repository_url") or "").split("/repos/")[-1] or default

def info_of(obj, default_repo):
    repo = repo_of(obj, default_repo)
    return {"ref": key(repo, obj["number"]), "number": obj["number"], "repo": repo,
            "title": obj.get("title", ""), "url": obj.get("html_url", ""), "state": obj.get("state", "open")}

def children(repo, n):
    return gh("repos/%s/issues/%d/sub_issues?per_page=100" % (repo, n))

def norm_tokens(text, default_repo):
    refs = []
    for mm in re.finditer(r"https://github\.com/([\w.-]+/[\w.-]+)/(?:issues|pull)/(\d+)", text):
        refs.append(key(mm.group(1), int(mm.group(2))))
    t2 = re.sub(r"https://github\.com/\S+", " ", text)
    for mm in re.finditer(r"([\w.-]+/[\w.-]+)#(\d+)", t2):
        refs.append(key(mm.group(1), int(mm.group(2))))
    t3 = re.sub(r"[\w.-]+/[\w.-]+#\d+", " ", t2)
    for mm in re.finditer(r"(?<![\w/])#(\d+)", t3):
        refs.append(key(default_repo, int(mm.group(1))))
    return refs

def parse_child_table(body):
    sec = re.search(r"(?ims)^#{1,6}\s*child tickets[^\n]*\n(.*?)(?=^#{1,6}\s|\Z)", body)
    if not sec:
        return []
    rows, cols = [], None
    for line in sec.group(1).splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip().strip("`").strip() for c in line.strip("|").split("|")]
        if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
            continue
        low = [c.lower() for c in cells]
        if cols is None and any(c.startswith("repo") for c in low) and any(c.startswith("issue") for c in low):
            cols = {"repo": next(i for i, c in enumerate(low) if c.startswith("repo")),
                    "issue": next(i for i, c in enumerate(low) if c.startswith("issue")),
                    "blocked": next((i for i, c in enumerate(low) if c.startswith("blocked")), None)}
            continue
        if cols is None or len(cells) <= max(i for i in cols.values() if i is not None):
            continue
        repo = cells[cols["repo"]]
        if re.fullmatch(r"[\w.-]+", repo):
            repo = "%s/%s" % (powner, repo)
        mi = re.search(r"#?(\d+)", cells[cols["issue"]])
        if not mi or not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
            continue
        blockers = norm_tokens(cells[cols["blocked"]], repo) if cols["blocked"] is not None else []
        rows.append({"repo": repo, "number": int(mi.group(1)), "blockers": blockers})
    return rows

parent = gh("repos/%s/issues/%d" % (phome, pnum))
parent_ref = key(phome, pnum)
leaves, closed, unresolved = [], [], []
seen, bodies, groups, table_blockers = {parent_ref}, {}, {}, {}

def visit(kids, depth):
    under = []
    for k in kids:
        info = info_of(k, phome)
        if k.get("state") == "closed":
            closed.append(info); continue
        if info["ref"] in seen:
            continue
        seen.add(info["ref"])
        grand = children(info["repo"], info["number"]) if depth < 3 else []
        if grand:
            sub = visit(grand, depth + 1)
            groups[info["ref"]] = sub
            under += sub
        else:
            leaves.append(info); bodies[info["ref"]] = k.get("body") or ""; under.append(info["ref"])
    return under

visit(children(phome, pnum), 1)
source = "native" if leaves else "none"
if not leaves:   # fallback: tabel "## Child tickets" di body parent (format "Child tickets")
    for row in parse_child_table(parent.get("body") or ""):
        obj = issue(row["repo"], row["number"])
        r = key(row["repo"], row["number"])
        if obj is None:
            unresolved.append({"ref": r, "reason": "issue tidak bisa dibaca (akses atau tidak ada)"}); continue
        info = info_of(obj, row["repo"])
        if obj.get("state") == "closed":
            closed.append(info); continue
        if info["ref"] in seen:
            continue
        seen.add(info["ref"]); leaves.append(info); bodies[info["ref"]] = obj.get("body") or ""
        table_blockers[info["ref"]] = row["blockers"]
        source = "table"

# ── dependensi ──
refs = [l["ref"] for l in leaves]
by_ref = {l["ref"]: l for l in leaves}
idx = {r: i for i, r in enumerate(refs)}
deps, api_state = {r: [] for r in refs}, "ok"

def add_dep(n, b, src, state=None):
    if b == n or any(d["ref"] == b for d in deps[n]):
        return
    deps[n].append({"ref": b, "state": state, "source": src})

for l in leaves:
    res = gh("repos/%s/issues/%d/dependencies/blocked_by?per_page=100" % (l["repo"], l["number"]), soft=True)
    if res is None:
        api_state = "unavailable"; res = []
    for b in res:
        bi = info_of(b, l["repo"])
        cache.setdefault(bi["ref"], b)
        add_dep(l["ref"], bi["ref"], "native", bi["state"])
for n, toks in table_blockers.items():
    for t in toks:
        add_dep(n, t, "table")
for l in leaves:
    body = bodies.get(l["ref"], "")
    sec = re.search(r"(?ims)^#{1,6}\s*blocked by[^\n]*\n(.*?)(?=^#{1,6}\s|\Z)", body)
    if sec:
        for t in norm_tokens(sec.group(1), l["repo"]):
            add_dep(l["ref"], t, "body")
    for mm in re.finditer(r"(?i)\b(?:depends on|blocked by|requires)\s+(https://github\.com/\S+|[\w.-]+/[\w.-]+#\d+|#\d+)", body):
        for t in norm_tokens(mm.group(1), l["repo"]):
            if t in idx:
                add_dep(l["ref"], t, "text")

def state_of(ref):
    obj = issue(repo_of_ref(ref), num_of_ref(ref))
    return obj.get("state") if obj else None

before, external = {r: set() for r in refs}, {}
for n in refs:
    for d in deps[n]:
        b = d["ref"]
        if b == n or b == parent_ref:
            continue
        if b in idx:
            before[n].add(b)
        elif b in groups:
            before[n].update(groups[b])
        else:
            st = d.get("state") or state_of(b) or "unknown"
            if st != "closed":
                external.setdefault(n, []).append({"ref": b, "state": st})

def short(b, leaf_repo):
    return ("#%d" % num_of_ref(b)) if repo_of_ref(b) == leaf_repo.lower() else b

skipped = {}
for n, bl in external.items():
    skipped[n] = "blocked by " + ", ".join("%s (%s)" % (short(d["ref"], by_ref[n]["repo"]), d["state"]) for d in bl)
changed = True
while changed:
    changed = False
    for n in refs:
        if n in skipped:
            continue
        for b in before[n]:
            if b in skipped:
                skipped[n] = "depends on skipped %s" % short(b, by_ref[n]["repo"]); changed = True; break

order_all, state, cycles = [], {}, []
def dfs(n, path):
    if state.get(n) == 2:
        return
    if state.get(n) == 1:
        cyc = path[path.index(n):] + [n]
        if not any(set(cyc) == set(c) for c in cycles):
            cycles.append(cyc)
        return
    state[n] = 1; path.append(n)
    for b in sorted(before[n], key=lambda x: idx[x]):
        if b not in skipped:
            dfs(b, path)
    path.pop(); state[n] = 2; order_all.append(n)
for n in refs:
    if n not in skipped:
        dfs(n, [])
cyc_bad = {x for c in cycles for x in c}
changed = True
while changed:
    changed = False
    for n in refs:
        if n in skipped or n in cyc_bad:
            continue
        if any(b in cyc_bad for b in before[n]):
            cyc_bad.add(n); changed = True
order = [n for n in order_all if n not in skipped and n not in cyc_bad]
placed = set(order)

# gelombang paralel, dasar stack (hanya blocker satu repo, setelah reduksi transitif), blocker lintas repo
before_same = {n: {b for b in before[n] if repo_of_ref(b) == repo_of_ref(n)} for n in order}
cross = {n: sorted(b for b in before[n] if repo_of_ref(b) != repo_of_ref(n)) for n in order}
anc_memo = {}
def anc(n):
    if n not in anc_memo:
        a = set()
        for b in before_same.get(n, ()):
            a.add(b); a |= anc(b)
        anc_memo[n] = a
    return anc_memo[n]
direct = {n: [b for b in sorted(before_same[n], key=lambda x: idx[x])
              if not any(b in anc(a) for a in before_same[n] if a != b)] for n in order}
wave_memo = {}
def wave(n):
    if n not in wave_memo:
        ws = [wave(b) for b in before[n] if b in placed]
        wave_memo[n] = 1 + max(ws) if ws else 0
    return wave_memo[n]

plan = []
for n in order:
    e = dict(by_ref[n])
    e.update({"wave": wave(n),
              "stack_on": direct[n][0] if len(direct[n]) == 1 else None,
              "wait_for": direct[n] if len(direct[n]) >= 2 else [],
              "cross_repo_blockers": cross[n],
              "blocked_by": deps[n]})
    plan.append(e)

print(json.dumps({
    "parent": {"ref": parent_ref, "number": pnum, "repo": phome, "title": parent["title"],
               "url": parent["html_url"], "state": parent["state"]},
    "source": source,
    "repos": sorted({l["repo"] for l in leaves}),
    "leaves": leaves,
    "order": order,
    "plan": plan,
    "reordered": order != [n for n in refs if n in placed],
    "skipped_blocked": [{"ref": n, "number": by_ref[n]["number"], "repo": by_ref[n]["repo"],
                         "title": by_ref[n]["title"], "reason": skipped[n]} for n in refs if n in skipped],
    "cycles": cycles,
    "unplaceable_due_to_cycle": sorted(cyc_bad),
    "deps_api": api_state,
    "skipped_closed": closed,
    "unresolved": unresolved}, indent=2, ensure_ascii=False))
PY
}

cmd_wait() {
  local timeout=540 stall=600; local -a names=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="${2:?--timeout butuh nilai}"; shift 2;;
      --stall)   stall="${2:?--stall butuh nilai}"; shift 2;;
      -*) die "opsi tidak dikenal: $1";;
      *)  names+=("$1"); shift;;
    esac
  done
  [ ${#names[@]} -gt 0 ] || die "pakai: wait NAME [NAME...] [--timeout DETIK] [--stall DETIK]"
  python3 - "$STATE_ROOT" "$timeout" "$stall" "${names[@]}" << 'PY'
import json, os, sys, time
root, timeout, stall, names = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
interval = float(os.environ.get("NESTED_WAIT_INTERVAL", "10"))
def rd(d, n, default=""):
    try:
        return open(os.path.join(d, n), encoding="utf-8").read().strip()
    except OSError:
        return default
def snap(n):
    d = os.path.join(root, n)
    pid, alive = rd(d, "pid"), False
    if pid.isdigit():
        try:
            os.kill(int(pid), 0); alive = True
        except OSError:
            pass
    log = os.path.join(d, "log.ndjson")
    idle = int(time.time() - os.path.getmtime(log)) if os.path.exists(log) else -1
    return {"name": n, "dir": d, "status": rd(d, "status", "UNKNOWN"), "alive": alive, "idle": idle}
for n in names:
    if not os.path.isdir(os.path.join(root, n)):
        sys.exit("nested-claude: tidak ada sesi: " + n)
t0 = time.time()
while True:
    snaps = [snap(n) for n in names]
    done  = [s for s in snaps if s["status"] != "RUNNING"]
    died  = [s for s in snaps if s["status"] == "RUNNING" and not s["alive"]]
    stuck = [s for s in snaps if s["status"] == "RUNNING" and s["alive"] and s["idle"] > stall]
    if done:    result, trig = "finished", done
    elif died:  result, trig = "died", died
    elif stuck: result, trig = "stalled", stuck
    elif time.time() - t0 >= timeout: result, trig = "timeout", []
    else:
        time.sleep(interval); continue
    break
print("wait_result=" + result)
print("trigger=" + ",".join(s["name"] for s in trig))
for s in snaps:
    line = "%s status=%s alive=%s idle_seconds=%d" % (s["name"], s["status"], "yes" if s["alive"] else "no", s["idle"])
    rj = rd(s["dir"], "result.json")
    if rj and s["status"] != "RUNNING":
        r = json.loads(rj)
        line += " pr_url=%s turns=%s cost_usd=%s" % (r.get("pr_url"), r.get("num_turns"), r.get("total_cost_usd"))
    print(line)
PY
}

cmd_status() {
  local name="${1:-}"; [ -n "$name" ] || die "pakai: status NAME"
  local S="$STATE_ROOT/$name"; [ -d "$S" ] || die "tidak ada sesi: $name"
  python3 - "$S" << 'PY'
import json, os, sys, time
S = sys.argv[1]
def rd(n, d=""):
    try:
        return open(os.path.join(S, n), encoding="utf-8").read().strip()
    except OSError:
        return d
pid, alive = rd("pid"), False
if pid.isdigit():
    try:
        os.kill(int(pid), 0); alive = True
    except OSError:
        pass
log = os.path.join(S, "log.ndjson")
events, last, sid = 0, "", ""
if os.path.exists(log):
    for line in open(log, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        events += 1
        if ev.get("type") == "system" and ev.get("subtype") == "init":
            sid = ev.get("session_id", sid)
        if ev.get("type") == "assistant":
            for b in ((ev.get("message") or {}).get("content") or []):
                if b.get("type") == "tool_use":
                    inp = b.get("input") or {}
                    d = inp.get("command") or inp.get("file_path") or inp.get("description") or ""
                    last = ("tool: %s %s" % (b.get("name"), d)).strip()[:160]
                elif b.get("type") == "text" and (b.get("text") or "").strip():
                    last = ("said: " + b["text"].strip().replace("\n", " "))[:160]
idle = int(time.time() - os.path.getmtime(log)) if os.path.exists(log) else -1
status = rd("status", "UNKNOWN")
print("name=" + os.path.basename(S))
print("status=" + status)
print("process_alive=" + ("yes" if alive else "no"))
print("worktree=" + rd("worktree"))
print("branch=" + rd("branch"))
print("events=%d" % events)
print("idle_seconds=%d" % idle)
print("session_id=" + sid)
print("last=" + last)
if status == "RUNNING" and idle > 600:
    print("hint=STALLED? tidak ada event baru selama %d detik" % idle)
if status == "RUNNING" and not alive:
    print("hint=proses sudah mati tapi status belum final; lihat stderr.log")
rj = rd("result.json")
if rj:
    r = json.loads(rj)
    for k in ("pr_url", "num_turns", "total_cost_usd", "subtype", "exit_code"):
        print("%s=%s" % (k, r.get(k)))
PY
}

cmd_stop() {
  local name="${1:-}"; [ -n "$name" ] || die "pakai: stop NAME"
  local S="$STATE_ROOT/$name"; [ -f "$S/pid" ] || die "tidak ada sesi: $name"
  local pid; pid=$(cat "$S/pid")
  touch "$S/stop_requested"
  alive "$pid" || { echo "sesi sudah tidak berjalan"; return 0; }
  pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
  sleep 2
  if alive "$pid"; then pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; fi
  echo "dihentikan: $name"
}

cmd_list() {
  [ -d "$STATE_ROOT" ] || { echo "(belum ada sesi)"; return 0; }
  local d
  for d in "$STATE_ROOT"/*/; do
    [ -d "$d" ] || continue
    printf '%s\t%s\n' "$(basename "$d")" "$(cat "$d/status" 2>/dev/null || echo UNKNOWN)"
  done
}

case "${1:-}" in
  start)  shift; cmd_start "$@";;
  status) shift; cmd_status "$@";;
  stop)   shift; cmd_stop "$@";;
  wait)   shift; cmd_wait "$@";;
  subissues) shift; cmd_subissues "$@";;
  parent-branch) shift; cmd_parent_branch "$@";;
  repo-path) shift; cmd_repo_path "$@";;
  list)   cmd_list;;
  classify) shift; cmd_classify "$@";;
  report) shift; cmd_report "$@";;
  *) sed -n '2,/^set -/p' "$0" | sed '$d' >&2; exit 2;;
esac
NESTLAUNCHEOF
chmod +x "$NESTED_BIN"
echo "✅ bin/nested-claude"

install_file "$SKILL_DIR/SKILL.md" << 'NESTSKILLEOF'
---
name: nested-implement
description: >
  Implement a GitHub issue/spec in separate nested Claude Code sessions (their own processes and worktrees,
  NOT subagents) that this session supervises until the pull request(s) exist. Asks for the ticket key, picks Mode A (one draft PR) or Mode B (parent branch + one PR per
  ticket, parallel where independent), reviews every PR (critic or critic-lite by risk), and reports the parent PR. Works with
  native sub-issues or the parent's "Child tickets" table, across repos. Use when the user says "nested
  session", "sesi terpisah", "pakai nested", combines /implement-spec (or /implement) with that wording, or
  invokes /nested-implement <issue-url> [extra instructions].
argument-hint: <issue-url> [extra instructions]
---

# nested-implement — supervise nested Claude Code sessions until the PR(s) exist

You are the SUPERVISOR. You do not implement anything yourself in this mode. Nested sessions do the work in
their own git worktrees; you prepare them, watch them, verify and review the results, and report once.

Report to the user in the language they wrote in.

## 0. If the user said "don't execute yet / make sure you understand first"
Stop after step 2 (without launching or creating anything). Reply with: what you understood (issue, tickets,
repos, mode and why, branch names, stack/wave plan, models, limits, worst-case cost), the allowlist you will
pass, and anything you cannot do. Wait for their go-ahead.

## 1. Understand and preflight (read-only)
- Read the issue: `gh issue view <url> --json title,body,labels,comments`. Note acceptance criteria. If it is too
  thin to implement without guessing, say so and ask before launching (nested sessions cannot ask questions).
- Tickets: `~/.claude/bin/nested-claude subissues <url>` (native sub-issues, otherwise the parent's
  `## Child tickets` table). Key fields: `source`, `repos`, `plan` (wave, stack_on, wait_for,
  cross_repo_blockers, blocked_by), `order`, `skipped_blocked`, `cycles`, `reordered`, `deps_api`,
  `skipped_closed`, `unresolved`. Everything is keyed by `owner/repo#N`.
  - `plan` empty and no `cycles`: single-issue flow (one ticket, Mode A).
  - `unresolved` not empty: say which table rows could not be read (access?) before going on.
- Repos: for each repo in `repos`, find the local clone with `~/.claude/bin/nested-claude repo-path owner/repo`
  (the current directory counts when its remote matches). If one is missing, ask the user for its path and,
  once given, append `owner/repo=/path` to `~/.claude/nested-repos.txt`.
- Preflight: `command -v gh claude python3`, `gh auth status`, `claude --version`, and that
  `~/.claude/bin/nested-claude` and `~/.claude/hooks/worktree-create.sh` exist. If the requested skill (default
  `poteto-mode`) is not installed (`ls ~/.claude/skills`; check installed plugins), tell the user instead of
  launching without it.
- Per repo, find the project's test and typecheck/build commands (project CLAUDE.md "Verify your work",
  package.json, composer.json, Makefile...). Nested sessions can only run allowlisted commands, so each one
  becomes `--allow 'Bash(<cmd>:*)'` (or a line in the repo's `.claude/nested-allow.txt`). Without them it
  cannot verify, so do not skip this.

## 2. Conventions and mode (the one mandatory pause)
If a team-conventions skill such as `ids-spec-parallel-pr` is installed, invoke it first; its rules override the defaults here. Defaults:
- **Ticket key** (for example `PROJ-123`): if it is not in the conversation, ask. Never guess.
- **Mode**: B when any of: complexity 6+ or a HEAVY override; 3+ tickets; about 300k+ tokens (or a `to-tickets`
  soft cap of 3+); 2+ parallel tickets in different areas/packages/repos; the user says epic/large/multi-PR.
  A only when all of: complexity 0-5, 1-2 tickets, under 300k tokens, one cohesive slice. Borderline: state
  your recommendation (A or B) and ask. "satu PR" means A, "satu PR per ticket" means B; the user wins.
- **Names**: slug = short kebab-case from the parent title. Parent branch `<KEY>-<slug>`; ticket branches
  `<KEY>-<slug>-t<k>` (k = position in `order`, 1-based, across repos).
- **Cycles**: if `cycles` is not empty, show each cycle (A -> B -> A) and ask which dependency to drop. Do
  nothing else until they answer.
Ask everything that is missing in ONE message (ticket key, borderline mode, missing repo paths, cycle edge)
and wait for the answer.

Then tell the user once, in one short message, the plan: mode, branch names, the tickets by wave with
`stack_on`/`wait_for`, which are skipped or pending and why (`skipped_blocked`, `skipped_closed`), models,
the caps and the worst-case total (the sum over runnable tickets of the tier cap + 2 fix rounds x $5; tier caps:
LIGHT $3, MEDIUM $6, HEAVY $10 per session; your own reviews are not capped by the launcher). Do not wait for approval beyond
this pause, unless the user asked to confirm first (section 0).

## 3. Task file and model
Per nested session create a temp file (e.g. `/tmp/nested-task-<name>.md`) containing: the ticket(s) (URL,
title, acceptance criteria), the parent/epic for context (URL, title), the ticket key, the user's extra
instructions verbatim, and "Scope is this ticket only." For a stacked child add: "Stacked on <base branch>".
For a cross-repo blocker add: "Depends on <url> (different repo); mention it in the PR body." The launcher adds
the standard NESTED RUN rules (no questions, BLOCKED protocol, never push to main, ticket-key commit/PR-title rules,
verify before the PR, final line `PR: <url>`).

Model: score the ticket with the complexity score in model-routing.md. LIGHT/MEDIUM: `--model sonnet`; HEAVY (or a
HEAVY override): `--model opus`; Mode A uses the highest tier among its tickets. The user's choice wins.
Fix rounds always use `--model opus`. A failed Sonnet session is retried once on Opus with the failure notes.

Caps: pass the same tier to the launcher with `--tier light|medium|heavy` (LIGHT 60 turns/$3, MEDIUM 100 turns/$6,
HEAVY 150 turns/$10). Explicit `--max-turns` / `--max-budget` from the user override the tier.
Shortcut: `--tier auto` makes the launcher score the task file itself (same score and HEAVY overrides; sets tier, caps and
model; an explicit `--model` still wins). `--tier auto-llm` adds a Haiku opinion but can never lower a HEAVY override.
Preview with `nested-claude classify <task-file>`. Your own judgement still wins: if you know better, pass tier/model.

## 4. Launch (background)
Always with the Bash tool and `run_in_background: true`.

**Mode A** (one session, all tickets, one draft PR):

    ~/.claude/bin/nested-claude start --name <key> --repo <path> --branch <KEY>-<slug> --ids <KEY> --draft \
      --task-file <file> --skill poteto-mode --model <m> --tier <t> --allow 'Bash(<cmd>:*)' ...

**Mode B**: first, once per repo that has tickets, create the parent branch (pushes it, with an empty first
commit so the draft parent PR can exist):

    ~/.claude/bin/nested-claude parent-branch --repo <path> --branch <KEY>-<slug>

then per ticket:

    ~/.claude/bin/nested-claude start --name <key>-t<k> --repo <path> --branch <KEY>-<slug>-t<k> \
      --stacked-on <base> --ids <KEY> --task-file <file> --skill poteto-mode --model <m> \
      --tier <t> --allow 'Bash(<cmd>:*)' ...

`<base>` = the branch of `stack_on` when it is set (`<KEY>-<slug>-t<j>`), otherwise the parent branch.

Never add `--dangerously-skip-permissions` or widen the allowlist to make something pass; if a nested session
needs a command, restart with that one `--allow`.

## 5. Supervise
Do not poll with sleep loops. Block with `wait` (Bash tool with `timeout: 600000`; if your Bash tool caps the
timeout lower, pass a smaller `--timeout`):

    ~/.claude/bin/nested-claude wait <name> [<name> ...] --timeout 540

It returns when any listed session finishes, dies or stalls (no new events for 600 s), or after the timeout.
`wait_result=timeout`: just call it again. `finished`: continue with step 6 for the `trigger` session (its
`pr_url`, turns and cost are in the output). `died` or `stalled`: look at the tail of
`~/.claude/nested/<name>/log.ndjson` and `stderr.log`, and run `nested-claude stop <name>` if it is looping or
stuck. Use `nested-claude status <name>` only for details. Do not message the user while it runs unless
something needs them.
- Permission denials in the log mean a missing allow rule: stop, relaunch with that rule.
- Terminal statuses: `DONE` (PR found), `DONE_NO_PR`, `BLOCKED`, `LIMIT` (turn or budget cap), `FAILED`, `STOPPED`.

## 6. Verify yourself (status DONE)
Do not trust the nested session's summary. Check:
- `gh pr view <url> -R <owner/repo> --json state,isDraft,headRefName,baseRefName,title,additions,deletions,changedFiles,statusCheckRollup --jq '{state,isDraft,head:.headRefName,base:.baseRefName,title,additions,deletions,changedFiles,checks:[.statusCheckRollup[]? | {n:(.name // .context), c:(.conclusion // .state)}]}'`
  (the `--jq` keeps the output small; the raw check list can be long)
- head is the expected branch; base is right (Mode A: default branch, draft; Mode B: the parent branch or the
  `stack_on` branch); the title contains `<KEY>`; nothing is merged.
- `gh pr diff <url> --name-only`: files stay within the ticket's scope; for a stacked child, no files from the
  blocker's PR.
- The PR description has verification evidence (commands and results), links the spec, the ticket issue(s) and
  `<KEY>`, and lists the assumptions made.
If something fails, report it plainly instead of calling it done.

## 7. Review gate (every PR, before anything is stacked on it)
Step 6 checks the shape of the PR; this step judges the code. Run it for every PR unless the user said to
skip review.
1. Gather: the ticket's acceptance criteria, the PR description (`gh pr view <url> --json body --jq .body`), the base ref
   and head ref of that PR.
2. Delegate to a read-only reviewer chosen by risk: `critic` (Opus) for HEAVY tickets, any HEAVY override, or when
   the user asked for strict review; otherwise `critic-lite` (Sonnet). A re-review after a fix round is always
   `critic` (Opus): a critical finding already showed the stakes. Neither has `gh`, and their Bash is read-only
   git run from the repo root, so give refs, not URLs. Self-contained prompt:

       Review one pull request. From the repo root <path> run `git diff --stat <base>...<head>` and
       `git diff <base>...<head>`; review ONLY that diff (earlier PRs in the stack are out of scope).
       Files can be read under <worktree path>.
       Acceptance criteria: <criteria>
       PR description (claims to verify): <body>
       Check correctness against the criteria, security, tests and the evidence claimed, and scope creep.
       Verdict PASS or FAIL. For FAIL list issues as file, line, severity (critical|warning), suggested fix.
       Do not fix anything.

3. PASS: continue. Keep `warning` items for the final report; do not post them on the PR unless asked.
4. FAIL with a `critical` issue: a fix round in the SAME worktree and branch (a new session; the original log
   is kept), always on Opus:

       ~/.claude/bin/nested-claude start --name <name>-fix<j> --reuse <name> --fix-pr <pr-url> --ids <KEY> \
         --task-file <findings> --skill poteto-mode --model opus --max-turns 60 --max-budget 5 --allow ...

   The task file holds the findings verbatim plus the acceptance criteria. Repeat step 6 and a fresh `critic` (Opus)
   review of the whole PR diff. At most 2 fix rounds per PR.
5. Still FAIL after 2 rounds: the ticket is FAILED (see failures below).

## 8. Scheduling (Mode B)
Process `plan` by `wave`:
- Start the tickets of a wave in parallel, at most 2 at a time (use the user's number if given). When one
  session finishes, verify and review it (steps 6-7), then start the next waiting ticket.
- A ticket may start only when ALL its blockers (same-repo and cross-repo) are DONE, verified and review PASS.
- `stack_on` set: base = that ticket's branch. `stack_on` null: base = the parent branch of its repo.
- `wait_for` not empty (2+ same-repo blockers): do NOT launch. Record "pending: blockers must be merged into the
  parent first: <list>" and continue with the rest.
- Cross-repo blockers only order the work; never stack across repos.
- Failures: a ticket that ends BLOCKED, LIMIT, FAILED, DONE_NO_PR, STOPPED, fails verification, or stays in
  review FAIL after 2 fix rounds is FAILED. Skip its dependents (transitively, including stacked ones);
  independent tickets continue. Report each failure with its reason, the logs, and options (relaunch it with
  adjusted limits/allowlist, or `claude --resume <session_id>` in its worktree).
- A `BLOCKED:` caused by a dependency nobody recorded (e.g. needs code from a later ticket): treat as FAILED
  for that ticket; do NOT reorder once PRs exist. Report the missing dependency; adding it as a "blocked by"
  relation and re-planning needs the user's go-ahead.
- Keep a chain file `~/.claude/nested/chain-<key>.md` (ticket, repo, wave, base, branch, PR, review verdict,
  fix rounds, status; skipped/pending with reasons) and update it after every step so the plan survives a long
  run.

## 9. Parent PR (Mode B, one per repo that has tickets)
After the last runnable ticket is finished, open the parent PR yourself (it contains no new commits):

    gh pr create -R <owner/repo> --draft --base <default branch> --head <KEY>-<slug> \
      --title "<KEY>: <parent title>" --body-file <file>

Body: <KEY>; the epic link; the children as a list (PR link, check status, review verdict); a note that the
child PRs are merged into this branch (stacked ones bottom-up), after which this PR is marked ready. In the
repo that owns the epic add `Closes #<epic>` only when nothing was skipped, pending or failed; otherwise
`Refs #<epic>`, "PARTIAL" in the title, and each skipped/pending/failed ticket with its reason. In other
repos link the epic by full URL. Never merge anything. In Mode A the single draft PR already is the parent PR.

## 10. Report once
- Lead with the PARENT PR URL(s), one per repo (say "partial" when tickets were skipped, pending or failed).
- Then the children (ticket, PR URL, base, checks, review verdict, fix rounds, remaining warnings), the
  wave/stack order and why it differs from the parent's order, pending and skipped tickets with their
  blockers (these are what the user must unblock or merge first), totals for turns and cost across sessions,
  assumptions the sessions recorded, and anything that looked off.
- Leave the worktrees in place for review. Tell the user how to remove them later:
  `git worktree remove .claude/worktrees/<name>`.

## Hard rules
- Never merge a PR. Never force-push. Never push to main/master. Never use `--dangerously-skip-permissions`.
- Never guess the ticket key. Never put code from two repos in one PR.
- `critic` and `critic-lite` only read and judge; fixes always go through a nested fix round. Do not post review comments on a
  PR unless the user asked.
- Do not edit the repo yourself in this mode; all changes come from nested sessions. The only things you
  create are the parent branch (via `parent-branch`) and the parent PR (via `gh pr create`).
NESTSKILLEOF
echo "✅ skills/nested-implement/SKILL.md  (/nested-implement)"

install_file "$CLAUDE_DIR/skills/receiving-codereview/SKILL.md" << 'RCSKILLEOF'
---
name: receiving-codereview
description: >
  Use when a person's review feedback arrives on a PR (comments, requested changes) or the user pastes review
  points. Verify each point before acting, fix through builder, draft replies, and record the generalizable
  lessons in review-lessons.md so future builds and reviews avoid the same findings.
---

# Receiving code review

Feedback is input to evaluate, not an order. Never answer "you're right" before checking the code.

## 1. Gather
A PR URL or pasted points. For a PR (REST, trimmed):
```bash
gh api repos/<o>/<r>/pulls/<n>/comments --paginate --jq '.[] | {id, in_reply_to_id, path, line, user: .user.login, body}'
gh api repos/<o>/<r>/pulls/<n>/reviews --jq '.[] | select(.body != "") | {user: .user.login, state, body}'
gh api repos/<o>/<r>/issues/<n>/comments --jq '.[] | {id, user: .user.login, body}'
```
Skip threads already settled by a later commit or by a reply that ends the discussion.

## 2. Triage (one line per point)
- **FIX**: valid and clear, after you checked the code at that line.
- **ASK**: ambiguous, or two points conflict. Collect all of them into ONE question to the user.
- **PUSHBACK**: wrong, out of scope, or against the spec or acceptance criteria. Cite evidence (file:line, a test,
  the spec). Polite, short, not defensive.
- **SKIP**: praise, already fixed, or opinion with no impact (say so).
If you cannot tell whether a point is valid, run the code or the test; do not guess.

## 3. Act
- Do the FIX points through `builder`: related points batched, one commit per logical group, tests run. For a PR from
  a nested session use the fix-round flow of `/nested-implement` (`--reuse ... --fix-pr`).
- Draft a reply per thread (what changed plus the commit, or the pushback evidence). Post only when the user asks.
  Never resolve a thread on the reviewer's behalf.
- Do not widen the diff beyond what the points need.

## 4. Record lessons (this is how the agent improves)
For each accepted point (a FIX, or a PUSHBACK the reviewer later accepted) ask: would this recur in other changes?
Only a general rule counts: a repo convention, a pitfall, a preference. A one-off fix does not.
- Source: a person's feedback or the user's own words. Never the output of `critic` / `critic-lite`: agents must not
  teach themselves.
- Where: repo-specific in `<repo>/.claude/review-lessons.md`; valid across repos in `~/.claude/review-lessons.md`.
- Format, one line each: `- <imperative rule> — why: <reason> (PR #<n>, YYYY-MM)`.
- Read the file first and merge duplicates instead of appending. Keep each file under 40 lines; when over, merge or
  drop the least useful and tell the user.
- Show the proposed lines and ask once before writing. If the user cannot answer, write them under
  `## Pending (unconfirmed)`; Pending lines are not binding and are promoted only when the user confirms.
- No secrets, customer data, or people's names in lessons.

## 5. Report
Counts (FIX / ASK / PUSHBACK / SKIP), commits pushed, replies drafted, lessons added or merged.
`builder`, `critic` and `critic-lite` read the lessons files first, so a confirmed lesson becomes both a coding rule
and a review check.
RCSKILLEOF
echo "✅ skills/receiving-codereview/SKILL.md  (/receiving-codereview)"



# ─── CLAUDE.md: hanya @import (idempotent) ──────────────────────────
touch "$CLAUDE_MD"
if grep -q '^## Model Tiers' "$CLAUDE_MD" 2>/dev/null; then
  echo ""
  echo "⚠️  CLAUDE.md berisi blok lama dari script versi sebelumnya (akan dobel dengan import baru)."
  ans=$(ask "   Hapus blok lama dari '# Global Rules' sampai akhir file? (backup dibuat) [Y/n]:" "y")
  if [[ "$ans" =~ ^[Yy] ]]; then
    cp "$CLAUDE_MD" "$CLAUDE_MD.bak-$TS"
    python3 - "$CLAUDE_MD" << 'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
i = s.find("# Global Rules")
if i == -1:
    i = s.find("## Model Tiers")
s = s[:i]
s = re.sub(r"\n*---\s*$", "", s.rstrip()) if s.strip() else ""
open(p, "w", encoding="utf-8").write((s + "\n") if s.strip() else "")
PYEOF
    echo "   ✅ blok lama dihapus (backup: CLAUDE.md.bak-$TS)"
  else
    echo "   ⏭️  dibiarkan; hapus manual agar tidak dobel."
  fi
fi
if grep -qxF "$IMPORT_LINE" "$CLAUDE_MD"; then
  echo "✅ CLAUDE.md sudah punya import"
else
  [ -s "$CLAUDE_MD" ] && printf '\n' >> "$CLAUDE_MD"
  printf '%s\n' "$IMPORT_LINE" >> "$CLAUDE_MD"
  echo "✅ CLAUDE.md += $IMPORT_LINE"
fi

# ─── settings.json: model opus + allow git read-only ────────────────
[ -s "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-$TS"
if python3 - "$SETTINGS" "$WT_HOOK_OK" "$WT_HOOK" "$GUARD_OK" "$GUARD_HOOK" "$STATUS_OK" "$STATUS_PY" << 'PYEOF'
import json, os, shlex, sys
p, hook_ok, hook_path = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
guard_ok, guard_path = sys.argv[4] == "1", sys.argv[5]
status_ok, status_path = sys.argv[6] == "1", sys.argv[7]
d = json.load(open(p, encoding="utf-8")) if os.path.exists(p) and os.path.getsize(p) else {}
d["model"] = "opus"
allow = d.setdefault("permissions", {}).setdefault("allow", [])
for r in ("Bash(git status:*)", "Bash(git log:*)", "Bash(git diff:*)", "Bash(git show:*)"):
    if r not in allow:
        allow.append(r)
if hook_ok:
    wc = d.setdefault("hooks", {}).setdefault("WorktreeCreate", [])
    ours = any("worktree-create.sh" in (h.get("command") or "") for e in wc for h in (e.get("hooks") or []))
    if ours:
        pass
    elif wc:
        print("   ⚠️  sudah ada hook WorktreeCreate lain; tidak ditambah (dua hook akan bentrok)")
    else:
        wc.append({"hooks": [{"type": "command", "command": shlex.quote(hook_path)}]})
        print("   ✅ hook WorktreeCreate terdaftar di settings.json")
else:
    print("   ⚠️  hook WorktreeCreate TIDAK didaftarkan (self-test gagal)")
if guard_ok:
    pm = d.setdefault("hooks", {}).setdefault("PreModelSwitch", [])
    if any("model-switch-guard.py" in (h.get("command") or "") for e in pm for h in (e.get("hooks") or [])):
        pass
    else:
        pm.append({"hooks": [{"type": "command", "command": "python3 -I " + shlex.quote(guard_path)}]})
        print("   ✅ hook PreModelSwitch terdaftar (pengaman cache; butuh Claude Code >= 2.1.251)")
else:
    print("   ⚠️  hook PreModelSwitch TIDAK didaftarkan (self-test gagal)")
if status_ok:
    cur = d.get("statusLine")
    if cur and "statusline.py" not in json.dumps(cur):
        print("   ℹ️  statusLine milikmu sudah ada; tidak diganti (pakai ~/.claude/statusline.py bila mau)")
    else:
        d["statusLine"] = {"type": "command", "command": "python3 -I " + shlex.quote(status_path), "refreshInterval": 20}
        print("   ✅ statusLine terdaftar (model · effort · konteks · sesi nested)")
json.dump(d, open(p, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
open(p, "a").write("\n")
PYEOF
then
  [ -f "$SETTINGS.bak-$TS" ] && cmp -s "$SETTINGS" "$SETTINGS.bak-$TS" && rm -f "$SETTINGS.bak-$TS"
  echo "✅ settings.json → model: opus, allow git read-only"
else
  echo "⚠️  settings.json tidak bisa di-merge otomatis (bukan JSON murni?)."
  echo "   Tambahkan manual: \"model\": \"opus\""
fi

# ─── Opsional: /code-review wajib lewat critic (fork) ───────────────
SKILL="$CLAUDE_DIR/skills/code-review/SKILL.md"
if [ -f "$SKILL" ]; then
  if grep -q '^context:' "$SKILL"; then
    echo "ℹ️  code-review SKILL.md sudah punya 'context:', dilewati."
  else
    echo ""
    echo "Ditemukan $SKILL"
    echo "Patch agar /code-review SELALU jalan di agent critic (Opus) via context: fork?"
    echo "Catatan: fork tidak melihat percakapan; isi skill harus bisa berdiri sendiri."
    ans=$(ask "   Patch? (backup dibuat) [y/N]:" "n")
    if [[ "$ans" =~ ^[Yy] ]]; then
      cp "$SKILL" "$SKILL.bak-$TS"
      python3 - "$SKILL" << 'PYEOF'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
if not lines or lines[0].strip() != "---":
    print("   ⚠️  tidak ada frontmatter; tidak diubah."); sys.exit(0)
end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
if end is None:
    print("   ⚠️  frontmatter tidak tertutup; tidak diubah."); sys.exit(0)
lines[end:end] = ["context: fork", "agent: critic"]
open(p, "w", encoding="utf-8").write("\n".join(lines))
print("   ✅ code-review → context: fork, agent: critic")
PYEOF
    else
      echo "   ⏭️  dilewati (routing tetap via model-routing.md)."
    fi
  fi
else
  echo "ℹ️  Skill code-review tidak ada di $SKILL (dilewati)."
fi

# ─── Info env var ───────────────────────────────────────────────────
if [ "$CLAUDE_CODE_SUBAGENT_MODEL_FORCE" = "1" ]; then
  echo ""
  echo "⚠️  CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 terdeteksi: semua agent mengabaikan model: miliknya."
  echo "   Hapus dari env/settings/rc file bila itu tidak disengaja."
elif [ -n "$CLAUDE_CODE_SUBAGENT_MODEL" ]; then
  echo ""
  echo "ℹ️  CLAUDE_CODE_SUBAGENT_MODEL=$CLAUDE_CODE_SUBAGENT_MODEL terdeteksi."
  echo "   Itu hanya jadi default untuk subagent TANPA model: sendiri (mis. general-purpose)."
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "🎉 Selesai. Restart Claude Code, lalu:"
echo "  1. /agents  → Explore & scout (hijau), builder (kuning), builder-isolated (oranye), critic (merah), critic-lite (ungu)"
echo "  2. Tes hook: minta scout menjalankan 'git push' → harus ditolak"
echo "  3. Setelah task jalan: /tasks untuk melihat model tiap subagent, /usage untuk biaya"
echo "  Catatan: alias haiku = Haiku 5.5 hanya di Anthropic API + Claude Code >= 2.1.293 (cek: claude --version)"
echo "  Nested: /nested-implement <URL issue> (supervisor) memakai ~/.claude/bin/nested-claude; butuh gh login + skill poteto-mode"
echo '          Batas sesi nested per tier (--tier): light 60 turn/$3, medium 100/$6, heavy 150/$10; pantau dengan nested-claude wait (bukan polling)'
echo "          Konvensi: tanya ticket key (mis. PROJ-123); Mode A (1 PR draft) atau Mode B (branch parent + 1 PR per ticket, paralel bila independen); PR parent (draft) dilaporkan di akhir"
echo "          Multi-repo: ticket dari sub-issue native atau tabel '## Child tickets'; clone lokal dicari via nested-claude repo-path (~/.claude/nested-repos.txt atau ~/Work)"
echo "          Code review berbasis risiko: critic (Opus) untuk HEAVY, critic-lite (Sonnet) untuk LIGHT/MEDIUM, tiap PR sebelum ticket berikutnya; temuan critical -> ronde perbaikan nested (Opus, maks 2)"
echo "          Dependensi antar sub-issue: blocker dulu; siklus -> berhenti & tanya; blocker eksternal -> dilewati, PR parent jadi draft PARTIAL"
if grep -q 'worktree-create.sh' "$SETTINGS" 2>/dev/null; then
  echo "  Worktree: hook global WorktreeCreate menyalin vendor/ dan .env* (tambah pola lain di .worktreeinclude)."
  echo "            Matikan: hapus entri hooks.WorktreeCreate di ~/.claude/settings.json"
fi
echo "  Auto-routing: nested-claude --tier auto (heuristik) / auto-llm (+Haiku); preview: nested-claude classify <task-file>"
echo "                Hook PreModelSwitch: /model dengan konteks >= 40k token + cache hangat -> konfirmasi berisi biaya (ambang: CLAUDE_SWITCH_GUARD_TOKENS)"
echo "  Review: /receiving-codereview memverifikasi feedback PR dan mencatat pelajaran ke .claude/review-lessons.md (dibaca builder, critic, sesi nested)"
echo "  Status line: model · effort · konteks · sesi nested yang jalan (hanya menampilkan keadaan nyata, bukan keputusan routing)"
echo "  Catatan: isi \"Verify your work\" (perintah test/build) di CLAUDE.md tiap project"
echo "  4. Opsional: pip install claude-status && claude-status --setup"
echo "═══════════════════════════════════════════════════════"
