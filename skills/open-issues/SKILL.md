---
name: open-issues
description: List open issues for the current repo, grouped by label (GitHub or GitLab). Use when the user invokes /open-issues or asks what issues are open in this repo.
---

# Open Issues

List this repo's open issues, grouped by label, with each group sorted oldest-first. Supports GitHub (via `gh`) and GitLab (via `glab`).

## Steps

1. **Detect issue source:**

   ```bash
   origin="$(git remote get-url origin 2>/dev/null)"
   if [[ "$origin" == *"gitlab"* ]]; then
     platform="gitlab"
   else
     platform="github"
   fi
   ```

   Decision matrix:
   - GitHub repo → use GitHub (silent)
   - GitLab repo → use GitLab (silent)
   - No remote detected → default to GitHub

   Announce the selected source, e.g. `Using GitHub issues.`

2. **Fetch and deterministically group/sort** open issues:

   **GitHub (default):**
   ```sh
   gh issue list --state open --json number,title,author,createdAt,labels,url --jq '
     [.[] | {number, title, author: .author.login, createdAt, url,
              labels: (if (.labels | length) == 0 then ["(no label)"] else [.labels[].name] end)}]
     | sort_by(.createdAt)
     | reduce .[] as $item ({}; reduce $item.labels[] as $label (.; .[$label] += [$item]))
   '
   ```

   **GitLab:**
   ```sh
   glab issue list -O json --jq '
     [.[] | {number: .iid, title, author: .author.username, createdAt: .created_at, url: .web_url,
              labels: (if (.labels | length) == 0 then ["(no label)"] else .labels end)}]
     | sort_by(.createdAt)
     | reduce .[] as $item ({}; reduce $item.labels[] as $label (.; .[$label] += [$item]))
   '
   ```

   This returns a single JSON object keyed by label name (plus `(no label)` for unlabeled issues), each value a `createdAt`-ascending array of issue objects. An issue with multiple labels appears under every one of its label keys (no dedup — a literal reading of "group by commonality" via existing labels).

   - If the CLI is not installed: tell the user, stop.
   - If the CLI errors (not authenticated, not a git repo, no remote, etc.): surface the error text as-is, stop. Do not attempt a workaround — the CLI already reports these cases clearly.
   - If the returned object is empty (`{}`): print `No open issues.` and stop. Do not print an empty report.

3. **Render as markdown**: iterate the object's keys in alphabetical order, with `(no label)` sorted last. For each key, emit a `##` heading with the item count, then one line per issue in that key's array:

   ```
   ## bug (3)
   #142 Login fails on retry (12d, @alice)
   #150 Crash on empty input (4d, @bob)
   #151 Crash on empty input variant (1d, @alice)

   ## (no label) (1)
   #160 Investigate flaky CI (2d, @carol)
   ```

   Compute the relative age (`12d`, `4d`, `1d`) from each issue's `createdAt` (an ISO-8601 timestamp) relative to the current date — whole days, rounding down, with `<1d` for anything under 24 hours. This is a cosmetic formatting step; it does not affect the grouping or ordering already guaranteed by the `--jq` filter in step 2.

   Print the rendered report directly in the conversation. Do not write it to a file.
