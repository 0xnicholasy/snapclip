---
name: implement
description: Implements the next todo of the SnapClip hardening pass feature from docs/snapclip-hardening/TODO.md on feat/snapclip-hardening: picks the next ready todo, builds it in its own worktree, verifies it, PRs it into feat/snapclip-hardening, merges it and marks it done. One todo per run, designed to be looped with /goal. After the last todo it cleans itself up. Use when the user runs /implement, says "next todo", "continue the feature", "implement T04", or asks "how far along is snapclip-hardening".
argument-hint: "[next | <todo id e.g. T04> | status | resume | cleanup]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Agent, Skill, AskUserQuestion
---

# /implement (snapclip-hardening)

Created by `/ultraplan`. Lives only on `feat/snapclip-hardening`; `cleanup` deletes it.
Single source of truth: `docs/snapclip-hardening/TODO.md` on `origin/feat/snapclip-hardening`. Read the TODO format from its own header and existing entries; keep it exactly.

## Arguments

| Argument | Does |
| --- | --- |
| none / `next` | Ship the next ready todo |
| `<id>` | Ship that todo if its `needs` are done or skipped |
| `status` | Read-only progress line, changes nothing |
| `resume` | Continue a todo left `in_progress` (its worktree / open PR) |
| `cleanup` | The final step (below). Runs automatically when only `TZZ` is left |

## Every run ends with exactly one of these lines (the /goal evaluator reads them)

- `IMPLEMENTED <id>: <what now works> (#<pr>). Progress: <done>/<total>. Next: <id>`
- `ULTRAPLAN BLOCKED <id>: <reason>. Needs: <the one thing the owner must do>`
- `ULTRAPLAN COMPLETE snapclip-hardening: landing PR #<n> into main awaits owner merge`

## Ship one todo

Stop at any step that fails its check, and end with the BLOCKED line.

### 1. Preflight
- `pwd`, `git branch --show-current`, fresh `git status`, `git fetch origin --prune`.
- Read `docs/snapclip-hardening/TODO.md` from `origin/feat/snapclip-hardening` (`git show origin/feat/snapclip-hardening:docs/snapclip-hardening/TODO.md`), not the local copy.
- A todo already `in_progress`: do `resume` for it instead of starting another. Also check `gh pr list --base feat/snapclip-hardening --state open`.
- Pick: the first `todo` in file order whose `needs` are all `done`/`skipped`. None ready but some not done: BLOCKED, naming what they wait on. Only `TZZ` left: go to Cleanup.
- A todo whose `done when` depends on an unanswered decision or external answer: BLOCKED. Never build against a guess.

### 2. Sync with main
If `git merge-base --is-ancestor origin/main origin/feat/snapclip-hardening` fails: temporary worktree on `feat/snapclip-hardening`, `git merge --no-ff origin/main`, normal push. Conflict: abort, remove the worktree, BLOCKED with the conflicting files.

### 3. Worktree
- `git worktree add .claude/worktrees/snapclip-hardening-<id lc> -b feat/snapclip-hardening-<id lc> origin/feat/snapclip-hardening`.
- Project worktree setup (env links, `bun install` in touched apps) per the project CLAUDE.md.
- Every later command: `cd <abs worktree> && <cmd>`. Never edit or commit in the main checkout.

### 4. Build
Build with a `sonnet` implementation agent (tool cap 80 for code plus tests, 40 otherwise). Its first action re-verifies the todo's cited file:line at the branch tip; if the premise no longer holds, mark the todo `skipped (<reason>)` and log it to `tasks/research/STATE.md` instead of improvising. Emergent forks: take the lowest-risk reversible option and log it to STATE.md. Every new test must be shown to fail under a hand mutation of its guard (record the mutation and the failing line in the PR body). Independent review: the `codex` subagent, blind to the author's reasoning, reviews the diff; the author may not clear its own change. Todos touching process spawning or signals also get `/secreview`.
This repo has no CI: `gh pr checks` reports no checks, so step 6 merges on the local verify evidence pasted in the PR body.
Spec handed over: the todo's scope, files, done-when, verify, the TODO `## Constraints`, and "work only in <abs worktree>".
In the same branch, edit `docs/snapclip-hardening/TODO.md`: this todo `status: done (#PR, <date>)`, bump `Progress`, append a `## Log` line, add any follow-ups found to `## Backlog`. Also update `tasks/lessons.md` (failure modes a test cannot lock), `tasks/research/STATE.md` (forks and skips), and `README.md` when it states behavior the todo changes if the todo changes what they describe.

### 5. Check before pushing
All must pass, with output kept as evidence:
- Every command in the todo's `verify`, plus `swift build` and `swift test` at the repo root, plus `scripts/build-app.sh` when `Sources/SnapClip/` is touched for the apps touched.
- The `done when` shown true (command output, test name, or screenshot for UI).
- A code-review pass on the diff (`code-reviewer`, model `sonnet`); fix Medium and above, at most 2 fix rounds.
- `git diff --cached --stat`: only files this todo names, plus TODO.md. Unstage anything else.
Failure after 2 attempts: leave the todo `in_progress`, push nothing, BLOCKED with the failing output's decisive line.

### 6. PR, CI, merge
- Push; PR base `feat/snapclip-hardening` (never main, never `release`); read the base back. Title `<type>(snapclip-hardening): <id> <title>`. Body: done-when evidence, verify output summary, review result, attribution line from the session's system reminder.
- Fill the PR number into TODO.md, push.
- `gh pr checks <n> --watch`. Real failure (job started): fix in the worktree, at most 2 attempts. Jobs never started (billing/quota): rerun once, then run each red check's local equivalent (read the workflow file whole) and merge on that evidence, naming which command stood in for which check.
- `BEHIND`: merge `origin/feat/snapclip-hardening` into the branch, push, re-watch. Squash-merge, confirm with `git log -1 origin/feat/snapclip-hardening`, remove the worktree, delete the branch locally and remotely.
- End with the IMPLEMENTED line.

## Status
`<done>/<total> done. In progress: <id or none>. Next ready: <id title>. Blocked: <ids + reason, max 5>.`

## Cleanup (TZZ)
Runs when every other todo is `done` or `skipped`. Worktree `.claude/worktrees/snapclip-hardening-cleanup` on `feat/snapclip-hardening-cleanup` from `origin/feat/snapclip-hardening`:
1. `git rm -r .claude/skills/implement` (this skill).
2. TODO.md: `Status: COMPLETE <date>, kept as backlog`, `TZZ` `done`, final Log line. Keep the file; it lands on main as the record.
3. Remove anything the enabling PR added on main that is on this branch too: the `CLAUDE.md` integration-branch bullet for `feat/snapclip-hardening`, CI branch filters for `feat/snapclip-hardening`, the matching deploy-doc lines. Leave any `.gitignore` exception that keeps `docs/snapclip-hardening/` tracked.
4. Verify: no remaining reference to `feat/snapclip-hardening` or `/implement` outside `docs/snapclip-hardening/` (`git grep`), full test run for every app the feature touched (`swift build` and `swift test` at the repo root, plus `scripts/build-app.sh` when `Sources/SnapClip/` is touched).
5. PR into `feat/snapclip-hardening`, CI, merge (same as step 6 above).
6. Open the landing PR `feat/snapclip-hardening` into main (merge commit, not squash, so the per-todo history stays). Body: Goal, todo table with PR numbers, Backlog, test evidence. Do NOT merge it: landing is the owner's call. Delete tag `pre-snapclip-hardening-main` only after the owner merges.
7. End with the COMPLETE line.

## Rules
- One todo per run, one PR per todo. Never batch.
- A todo whose scope turns out wrong: stop, BLOCKED, and propose the TODO.md edit (split, new todo, changed done-when) for the owner to approve.
- Never push to main or `release`, never force-push, never rebase `feat/snapclip-hardening`.
- Tests go through the project's test skills, never hand-rolled commands when the project mandates skills.
