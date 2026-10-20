---
name: merge-main
description: Merge the default branch (e.g. main) into the current branch, verify a clean build, and report before pushing. Use when the user asks to bring a feature branch up to date with main or sync with upstream before pushing.
---

# Merge the default branch and verify

Resolve `<default>` with `git symbolic-ref --short refs/remotes/origin/HEAD` (strip the `origin/` prefix). If that fails, fall back to `main`, then `master`.

## Steps

1. `git fetch origin && git merge origin/<default>`
2. Resolve conflicts
3. Run the project's verification command, detected from marker files:

| Marker | Command |
|--------|---------|
| `build.gradle` / `build.gradle.kts` | `./gradlew build` |
| `pom.xml` | `./mvnw verify` (fallback `mvn verify`) |
| `package.json` | `npm test` |
| `pyproject.toml` / `setup.py` / `pytest.ini` | `pytest` |
| `go.mod` | `go build ./... && go test ./...` |
| `Cargo.toml` | `cargo build && cargo test` |
| none | ask the user |

4. `git status` to confirm all changes staged
5. Report results before pushing
