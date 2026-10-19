---
name: open-prs
description: List open pull requests or merge requests for the current repo, grouped by label (GitHub or GitLab). Use when the user invokes /open-prs or asks what PRs/MRs are open in this repo.
---

# Open PRs

List this repo's open pull requests, grouped by label, with each group sorted oldest-first. Supports GitHub (via `gh`) and GitLab (via `glab`).

## Steps

1. **Detect code platform:**

   ```bash
   origin="$(git remote get-url origin 2>/dev/null)"
   if [[ "$origin" == *"gitlab"* ]]; then
     platform="gitlab"
     cli="glab"
   else
     platform="github"
     cli="gh"
   fi
   ```

   Announce the detected platform, e.g. `Detected GitHub repo → using gh.`
   If no remote URL is available, warn the user (`No remote URL detected; defaulting to GitHub.`) and proceed.

2. **Fetch and deterministically group/sort** open PRs:

   **GitHub (default):**
   ```sh
   gh pr list --state open --json number,title,author,createdAt,labels,url,isDraft --jq '
     [.[] | {number, title, author: .author.login, createdAt, url, isDraft,
              labels: (if (.labels | length) == 0 then ["(no label)"] else [.labels[].name] end)}]
     | sort_by(.createdAt)
     | reduce .[] as $item ({}; reduce $item.labels[] as $label (.; .[$label] += [$item]))
   '
   ```

   **GitLab:**
   ```sh
   glab mr list -O json --jq '
     [.[] | {number: .iid, title, author: .author.username, createdAt: .created_at, url: .web_url, isDraft: .draft,
              labels: (if (.labels | length) == 0 then ["(no label)"] else .labels end)}]
     | sort_by(.createdAt)
     | reduce .[] as $item ({}; reduce $item.labels[] as $label (.; .[$label] += [$item]))
   '
   ```

   This returns a single JSON object keyed by label name (plus `(no label)` for unlabeled PRs), each value a `createdAt`-ascending array of PR objects. A PR with multiple labels appears under every one of its label keys (no dedup — a literal reading of "group by commonality" via existing labels).

   - If the CLI is not installed: tell the user, stop.
   - If the CLI errors (not authenticated, not a git repo, no remote, etc.): surface the error text as-is, stop. Do not attempt a workaround — the CLI already reports these cases clearly.
   - If the returned object is empty (`{}`): print `No open PRs.` and stop. Do not print an empty report.

3. **Render as markdown**: iterate the object's keys in alphabetical order, with `(no label)` sorted last. For each key, emit a `##` heading with the item count, then one line per PR in that key's array, prefixed with `[draft]` when `isDraft` is true:

   ```
   ## feature (2)
   [draft] #201 Add dark mode toggle (6d, @dave)
   #205 Add dark mode toggle tests (2d, @erin)

   ## (no label) (1)
   #210 Bump lodash to patch CVE (1d, @frank)
   ```

   Compute the relative age (`6d`, `2d`, `1d`) from each PR's `createdAt` (an ISO-8601 timestamp) relative to the current date — whole days, rounding down, with `<1d` for anything under 24 hours. This is a cosmetic formatting step; it does not affect the grouping or ordering already guaranteed by the `--jq` filter in step 2.

   Print the rendered report directly in the conversation. Do not write it to a file.
