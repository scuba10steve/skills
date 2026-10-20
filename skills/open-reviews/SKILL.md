---
name: open-reviews
description: Show the pull requests and merge requests across GitHub and GitLab that are waiting on you as a reviewer, each joined to any live local Claude Code session, where detectable. Use when the user invokes /open-reviews or asks what is waiting on their review / what they need to review.
---

# Open Reviews

The PRs and MRs waiting on you, joined to the agent sessions running on this
machine.

## Steps

1. **Collect.** Run `bash <skill-dir>/scripts/open-work.sh --reviews-only`, where
   `<skill-dir>` is the directory containing this SKILL.md. It emits one JSON
   document. If it exits non-zero, show its stderr and stop.

   Do **not** pass `--exclude-reviewed`. On GitLab, `reviewer_username` persists after you comment, so this queue
   deliberately shows MRs you have commented on but not approved. On GitHub,
   submitting a review (approve, request-changes, or review-with-comments)
   removes you from the requested reviewers, so that PR leaves the queue on its
   own; a plain issue-style PR comment does not clear it.

2. **Render** one section. Ages are whole days from `created_at`, `<1d` under 24
   hours. Session idle is **per repository, not per session** — say "repo idle".

   ```
   ## Needs your review (n)
   ```

   Per item: `[<display_id>](<url>)  <forge>  <repo_id>  <title>  (<age>)  <marker>`,
   with ` (draft)` appended when `is_draft` is true. `display_id` is rendered as
   a Markdown link to the item's `url` so the queue is clickable — that is what
   the `url` field exists for on this side. If `url` is null, emit the bare
   `display_id` rather than an empty link.

   **The marker comes from BOTH axes, not from `status` alone** — `status` has
   only four values, one short of the six markers below, and the
   `active`/`stale`/`unknown` split lives entirely in `session_state`:

   | `status` | `session_state` | renders as |
   |---|---|---|
   | `no-session` | `null` | `○ no session` |
   | `session-repo-only` | any | `◔ repo has a session, repo idle <t>` |
   | `session-other-branch` | any | `◑ session on <branch>` |
   | `session` | `active` | `● session, repo idle <t>` |
   | `session` | `stale` | `◌ stale, repo idle <t>` |
   | `session` | `unknown` | `◍ session, repo idle unknown` |

   `unknown` never renders as active and never as stale — a live process whose
   transcript could not be resolved is a session with an unknown idle time, and
   claiming either would be a guess.

   `◔` means a session exists in that repository but the item has no branch to
   match against (a PR whose head branch could not be resolved), so no claim is
   made that the session is working on that item.

   **Which match is displayed:** `matches` arrives freshest-first, so the
   displayed idle and branch always come from `matches[0]`. If an item has more
   than one match, append `(+N more sessions)`, where N is the count of
   additional matches beyond the one displayed, i.e. `(matches | length) - 1` —
   do not silently hide them, and do not average or merge their idle times.

   `session_state` describes `matches[0]` — the freshest session in that
   repository, which may not be the one on your branch. An item can therefore
   read `● session, repo idle 4m` while the session actually on its branch is
   days stale.

   **Preserve the order as emitted.** `shape` already orders items oldest-first
   and matches freshest-first; re-sorting here throws that away.

3. **Never render failure as emptiness.** Under `--reviews-only` only two keys
   can feed this section:

   | `.errors` key | meaning |
   |---|---|
   | `github_review` | GitHub items missing from the queue |
   | `gitlab_review` | GitLab items missing from the queue |

   - Render whatever items did come back, normally.
   - For each key present, add one line naming the forge and its CLI text:
     `ERROR (gitlab): HTTP 401 unauthorized — GitLab items missing from this section`.
   - Only when **both** keys errored does the section show no count at all, just
     its `ERROR` lines.

   An empty queue is a legitimate result, so an expired token must never render
   identically to having nothing to review.

   **`.limits` uses the same two keys.** For each one present, add
   `(showing first 100 — more exist)`.

   **Two further keys feed no section and are separate axes.**
   `.errors.sessions` reports that session discovery itself failed, and
   `sessions` is then `[]`; print `Session correlation unavailable: <reason>`
   once, above the section, and still render every item.
   `.errors.github_pr_branches` reports lost precision rather than missing
   items; render it as
   `WARNING (pr branches): <text> — affected PRs show ◔ rather than a branch match`.

## Scope

Review requests are those made of you **directly** — GitHub
`user-review-requested:@me`, GitLab `reviewer_username`. Team-routed GitHub
requests and GitLab MRs where you are merely the assignee are deliberately out
of scope.

GitHub coverage is the **active `gh` identity only**; `gh` holds one account per
host, so review requests under a different GitHub account will not appear.

Only Claude sessions join to items. Other agents (OpenCode, Codex, Gemini) have
no transcript this script reads, so they never match an item.
