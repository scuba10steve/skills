---
name: clean-comments
description: Review code comments for AI-narration noise, restates-the-code filler, structural clutter, and staleness, then remove or rewrite them while preserving TODO/FIXME/XXX markers and license/copyright headers. Use when the user invokes /clean-comments or asks to clean up / tidy up / prune comments in code they're working on.
---

# Clean Comments

Review comments in code — by default the current diff — and remove or rewrite the ones that are noise, while leaving load-bearing comments alone. This is a judgment pass, not a blanket strip: the goal is fewer, better comments, not zero comments.

## Trigger

- Invoked explicitly via `/clean-comments [flags] ["<directive>"]`.
- Invoked when the user asks to clean up, tidy up, or prune comments in code they're working on.
- Do NOT self-invoke after writing or editing code. Only run when asked.

## Args

- `/clean-comments` → dry-run against the current diff.
- `/clean-comments --apply` → same scope, writes the changes.
- `/clean-comments --sweep [path]` → whole-repo (or `path`) sweep instead of the diff. Combine with `--apply` to write.
- `/clean-comments "<directive>"` → free-form instruction layered on top of the default criteria below, e.g. `"match Google style"`, `"only touch the auth module"`, `"rewrite comments to be terser"`. Combinable with `--apply` and `--sweep`.
- Flags and a directive can be combined in any order: `/clean-comments --sweep src/ --apply "match Google style"`.

## Scope resolution

1. Explicit path/glob in the arguments (with or without `--sweep`) → use it directly.
2. `--sweep` with no path → walk all source files in the repo via `git ls-files` (respects `.gitignore` for tracked-file purposes; skip untracked build output too).
3. Default (no `--sweep`, no path) → resolve the diff:
   - `git diff` (unstaged) + `git diff --staged` (staged).
   - If both are empty (clean tree), fall back to `git diff HEAD~1`.
4. Regardless of path, skip generated/vendored files: `node_modules`, `vendor`, `dist`, `build`, other compiled/lockfile output, and binary files. Use judgment for project-specific equivalents (e.g. `.terraform/`).

## Sweep dispatch (large `--sweep` only)

Compute file count for the resolved sweep scope. If `> 20` files:

Ask the user: *"This sweep covers N files. Dispatch parallel review agents split by directory and aggregate? (y/N)"*. On yes, dispatch parallel subagents, each given a directory slice, the removal criteria and preserve rules below, the apply mode (dry-run vs `--apply`), and any custom directive — then merge their reported changes into one summary. On no, on a non-interactive run, or when the harness has no subagents, process files inline, sequentially. With `≤ 20` files, process inline.

Diff-scoped runs (the default, no `--sweep`) never dispatch — they're always inline.

## What counts as noise

Evaluate each comment in scope against these; a comment can match more than one:

1. **Restates-the-code filler** — adds zero information beyond the line(s) it sits above, e.g. `// increment counter` above `counter++`, `// loop through items` above a `for` loop.
2. **AI narration / meta-commentary** — describes the act of editing rather than the code itself, e.g. `// Added this check per user request`, `// New helper function`, `// Fixed bug here`.
3. **Structural clutter** — decorative banners/separators (`// ===== Section =====`) that carry no information beyond visual grouping, and commented-out dead code (git history already preserves it).
4. **Stale/inaccurate** — the comment contradicts what the code actually does now. Verify against current behavior before touching — don't pattern-match alone. When you're not sure whether it's stale or you're missing context, flag it in the report instead of silently deleting it.

## Always preserved, no exceptions

- `TODO` / `FIXME` / `XXX` markers, in any comment style, however terse.
- License/copyright headers at the top of a file.

Never remove, shorten, or rewrite these even under a custom directive that would otherwise apply to the whole file.

## Judgment calls — not blanket rules

Rationale ("why") comments and doc comments/docstrings are **not** automatically protected — hold them to the same scrutiny as everything else:

- Keep them when they carry real information a reader couldn't get from the code alone (a non-obvious trade-off, a workaround for a specific bug/quirk, an API contract).
- Rewrite them when a custom directive asks for a different style or when they're accurate but verbose.
- Remove them when they're stale, or when they're empty restatements (`// Returns the result.` above a one-line getter).

## Custom directive

When the invocation includes a quoted directive, treat it as an addition to (not a replacement for) the criteria and preserve rules above. Apply the directive's intent per-file/per-comment as it makes sense; if it conflicts with an always-preserved category (TODO/FIXME/XXX, license headers), the preserve rule wins and you should say so in the summary.

## Output — dry-run (default)

Never write to files in this mode. For each file with proposed changes, show a before/after for every touched comment with a one-line reason tag (`filler` / `narration` / `clutter` / `stale` / `directive`):

```
### path/to/file.ext

- `// increment counter` (filler) → removed
- `// Fixed bug here` (narration) → removed
- `// TTL is 5s to match the upstream cache header, not arbitrary` (kept — carries rationale)
- `// ===================` (clutter) → removed
```

End with a totals line: `N files, M comments removed, K rewritten, J flagged for review`. "Flagged for review" covers stale-but-uncertain cases — list those separately with why you weren't sure.

## Output — `--apply`

Make the same edits (comment lines only — never touch surrounding code logic), then print the same per-file summary and totals. Tell the user to review with `git diff` before committing; do not commit on their behalf.

## Non-goals

- Does not touch commit messages, PR descriptions, or non-comment code.
- Does not fix bugs or refactor logic — that's a code review or refactoring task.
- Does not run automatically after edits or as part of any other skill's flow — standalone and on-demand only.
