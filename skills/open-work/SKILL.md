---
name: open-work
description: Show your open pull requests, merge requests, and assigned issues across GitHub and GitLab, each joined to any live local Claude Code session, where detectable, with abandoned sessions called out. Use when the user invokes /open-work or asks what work they have open / in flight / what they were working on across repos.
---

# Open Work

Your open work across every forge, joined to the agent sessions actually running
on this machine.

## Steps

1. **Collect.** Run `bash <skill-dir>/scripts/open-work.sh`, where `<skill-dir>` is the
   directory containing this SKILL.md. It emits one JSON document and takes a
   few seconds. If it exits non-zero, show its stderr
   and stop.

2. **Render** the JSON in this order. Ages are whole days from `created_at`,
   `<1d` under 24 hours. Session idle is **per repository, not per session** —
   say "repo idle" so the report never implies more precision than exists.

   ```
   ## Needs your review (n)          items with bucket=review
   ## Your open PRs/MRs (n)          bucket=authored
   ## Assigned to you (n)            bucket=assigned
   ## Sessions with no open item (n) sessions where matched=false
   ## Stale (idle > 3d) (n)          sessions where state=stale
   ```

   Per item: `<display_id>  <forge>  <repo_id>  <title>  (<age>)  <marker>`.

   **The marker comes from BOTH axes, not from `status` alone** — an earlier
   draft of this rule derived every glyph from `status`, which cannot work
   because `status` has only four values, one short of the six markers below,
   and the `active`/`stale`/`unknown` split lives entirely in `session_state`:

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
   match against (a GitHub issue, or a PR whose head branch could not be
   resolved), so no claim is made that the session is working on that item.

   **Which match is displayed:** `matches` arrives freshest-first, so the
   displayed idle and branch always come from `matches[0]`. If an item has more
   than one match, append `(+N more sessions)` — do not silently hide them, and
   do not average or merge their idle times.

   `session_state` describes `matches[0]` — the freshest session in that
   repository, which may not be the one on your branch. An item can therefore
   read `● session, repo idle 4m` while the session actually on its branch is
   days stale.

   **The two session sections list sessions, not items,** so they need their own
   line format. Use the fields that exist on a session object — `pid`, `tty`,
   `agent`, `cwd`, `branch`, `idle_seconds`, `state`:

   ```
   <agent> <pid> <tty>  <cwd>  [<branch>]  (repo idle <t>)
   ```

   `Sessions with no open item` lists every session with `matched=false`;
   `Stale (idle > 3d)` lists every session with `state=stale`. A stale session
   with no open item appears in both — correct, because they answer different
   questions. Say "repo idle" here too, for the reason given above: a session's
   `idle_seconds` is derived from the newest transcript in its project, not from
   that process. Render it as `unknown` when `idle_seconds` is `null`, never as
   `0`. **Omit the tty when it is `??`** — a daemonised agent has no controlling
   terminal, and printing `??` reads as a rendering bug rather than a fact.

   **Preserve the order as emitted.** `shape` already orders items oldest-first
   and matches freshest-first; re-sorting in the renderer would throw that away.

3. **Never render failure as emptiness — and errors are per-request, not
   per-forge.** Every section draws from more than one request, and "Assigned to
   you" draws from three. Read the mapping here rather than inferring it from key
   names — `gitlab_issues` does not follow the `<forge>_<bucket>` pattern:

   | `.errors` key | section |
   |---|---|
   | `github_review`, `gitlab_review` | Needs your review |
   | `github_authored`, `gitlab_authored` | Your open PRs/MRs |
   | `github_assigned`, `gitlab_assigned`, `gitlab_issues` | Assigned to you |

   One rule covers every case:

   - Render whatever items did come back, normally.
   - For each `.errors` key feeding the section, add one line naming the forge
     and its CLI text: `ERROR (gitlab): HTTP 401 unauthorized — GitLab items
     missing from this section`.
   - Only when **every key** feeding a section errored does that section show no
     count at all, just its `ERROR` lines. Two of "Assigned to you"'s three keys
     failing still means the third returned real work: keep the count, add two
     `ERROR` lines.

   Never suppress a section that has real items (it hides work) and never show a
   section as complete when a request failed (it hides the failure). An empty
   "Needs your review" is a legitimate result, so an expired token must never
   render identically to having no work.

   **`.limits` uses the same seven keys as `.errors`** — route each one to its
   section with the same table above rather than inferring it from the key name,
   for the same reason: `gitlab_issues` defeats name inference. For each
   `.limits` key add `(showing first 100 — more exist)` to that key's section.

   **Session discovery failure is a separate axis.** `.errors.sessions` is one
   of two keys that feed no section: it reports that session discovery itself
   failed, and `sessions` is then `[]`. When it is present, print
   `Session correlation unavailable: <reason>` once, above the sections, and
   still render every item. The item→session join is computed entirely from the
   session list, so an empty list downgrades items to `○ no session` and shows
   `Stale` as 0 — the same failure rendered as emptiness, on the session axis.

   **`.errors.github_pr_branches` is the second such key.** It reports lost
   precision, not a missing-items error: some GitHub PRs' head branches could
   not be resolved, whether by the lookup cap or by a failed lookup, and those
   PRs match at the repository level (`◔`) instead of by branch. When present,
   render it as `WARNING (pr branches): <text> — affected PRs show ◔ rather
   than a branch match`.

## Scope

Issues are those **assigned** to you — not authored-but-unassigned, not
mentions. GitHub coverage is the **active `gh` identity only**; `gh` holds one
account per host and `--owner` filters cannot change that. GitHub PR head
branches are resolved separately, via `gh pr view`, up to a bounded number of
lookups per run — PRs left unresolved match at the repository level instead.
GitHub issues never have a branch and always match at the repository level. A
PR from a fork names its base repository, so a fork PR with no local clone
correctly reports `○ no session`.

Only Claude sessions join to items. Other agents (OpenCode, Codex, Gemini) have
no transcript this script reads, so their idle time is always `unknown`, they
never match an item, and they always appear under "Sessions with no open item".
A repo with a live OpenCode session and an open PR therefore renders
`○ no session` — the session is real, but not joinable.
