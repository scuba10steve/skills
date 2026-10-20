---
name: pr
description: Create a pull request or merge request from the current branch with safety checks. Use whenever the user wants to create a PR/MR, push and open a PR/MR, submit work for review, or says "create a PR" / "open a PR" / "submit this" / "pr this". Also use when the user types /pr. Handles fork detection, branch verification, conventional commit titles, and project-specific verification.
---

# Create Pull Request

This skill creates a pull request (GitHub) or merge request (GitLab) with built-in safety checks to prevent common mistakes like targeting the wrong repository or pushing unverified code.

## Detect code platform

```bash
origin="$(git remote get-url origin 2>/dev/null)"
if [[ "$origin" == *"gitlab"* ]]; then
  platform="gitlab"
else
  platform="github"
fi
```

Announce the detected platform, e.g. `Detected GitHub repo → creating PR.`

## Workflow

Follow these steps in order. Stop and report if any step fails.

### 1. Pre-flight checks

Run these in parallel:
- `git status` — confirm working tree is clean (no uncommitted changes). If dirty, ask the user whether to commit first or proceed without those changes.
- `git branch --show-current` — get current branch name. If on `main` or `master`, stop and tell the user they need to be on a feature branch.
- `git log --oneline main..HEAD` (or `master..HEAD`) — confirm there are commits to include. If none, stop.

### 2. Identify the correct remote

This is the most important safety check — past mistakes have come from pushing to or creating PRs against the wrong repository.

```bash
git remote -v
```

**GitHub fork detection:**
- If there are two remotes (typically `origin` and `upstream`), this is a fork. The PR target should be `origin` (the fork), NOT `upstream`.
- If there is only `origin`, use that.

**GitLab fork detection:**
```bash
glab repo view -F json --jq '.forked_from_project.path_with_namespace'
```
- If non-empty, the repo is a fork. The MR target is the parent project (the value returned).
- If empty/null, this is not a fork. Use `origin`.

**Verify the remote URL** — show the user which repository the PR/MR will target and confirm before proceeding.

### 3. Run project verification

Before pushing, detect the project type and run verification. Check for these markers in order:

| Marker | Type | Command |
|--------|------|---------|
| `terragrunt.hcl` | Terragrunt | `terragrunt validate` |
| `*.tf` files | Terraform | `terraform init -backend=false && terraform validate` |
| `build.gradle` / `build.gradle.kts` | Gradle | `./gradlew build` |
| `pom.xml` | Maven | `./mvnw verify` |
| `go.mod` | Go | `go build ./... && go test ./...` |
| `Cargo.toml` | Rust | `cargo build && cargo test` |
| `package.json` | Node | `npm test` |
| `pytest.ini` / `pyproject.toml` | Python | `pytest` |

If verification fails, stop and report the errors. Do not push broken code.

### 4. Push the branch

```bash
git push -u origin HEAD
```

If the push is rejected (e.g., needs force push), ask the user — do not force-push without explicit permission.

### 5. Create the PR/MR

**GitHub:**
```bash
gh pr create --title "<type>: <description>" --body "$(cat <<'EOF'
## Summary
- <bullet points>

## Test plan
- <how to verify>
EOF
)"
```

**GitLab:**
```bash
glab mr create \
  --title "<type>: <description>" \
  --description "$(cat <<'EOF'
## Summary
- <bullet points>

## Test plan
- <how to verify>
EOF
)" \
  --target-branch main
```

For GitLab forks: `--source-branch <current-branch>` is automatic when targeting the parent project via `glab repo view`.

Use a conventional commit-style title (e.g., `feat:`, `fix:`, `chore:`, `refactor:`):
- Keep the title under 70 characters
- Body with a `## Summary` section containing 1-3 bullet points
- A `## Test plan` section if the changes affect behavior

Important constraints:
- Do NOT add "Generated with Claude Code" or any AI attribution to the PR/MR body
- Do NOT add "Co-Authored-By" trailers to any commits
- Target the fork's repository, not upstream (if this is a fork)

### 6. Report

Output the PR/MR URL so the user can review it in their browser.

## Edge cases

- **No `gh`/`glab` CLI**: If the platform CLI is not installed, provide the URL to create the PR/MR manually in the browser.
- **Draft PR/MR**: If the user says "draft" or "wip", add `--draft` (GitHub) or `--draft` (GitLab) to the create command.
- **Specific base branch**: If the user specifies a target branch, use `--base <branch>` (GitHub) or `--target-branch <branch>` (GitLab) instead of defaulting to `main`.
- **Multiple commits**: Use `git log --oneline main..HEAD` and `git diff main...HEAD` to understand the full scope when writing the description — not just the latest commit.
