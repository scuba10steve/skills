# skills

A set of agent skills for working with pull requests, code review, research and open-work tracking. Each skill is a folder with a `SKILL.md` and, where needed, helper scripts. They are written to be harness-agnostic: they name actions ("dispatch a subagent", "ask the user") rather than any one tool's identifiers.

## Skills

| Skill | Description |
|---|---|
| `pr` | Create a pull request or merge request from the current branch with safety checks. |
| `merge-main` | Merge the default branch into the current branch, verify a clean build, and report before pushing. |
| `clean-comments` | Remove or rewrite noisy, redundant or stale code comments, keeping TODO/FIXME markers and license headers. |
| `research` | Research an external technical question; every claim carries a verbatim quote from a page that was read. |
| `task-estimate` | Estimate token usage for a task prompt, bucket it S/M/L/XL, and produce split prompts at L/XL. |
| `outside-voice` | Send the current work to a different AI harness for a read-only review and relay it verbatim. |
| `spec-and-plan` | Drive work through spec, outside review, plan and outside review, then execute on approval. |
| `open-work` | Show your open PRs/MRs and assigned issues across GitHub and GitLab, joined to local sessions where detectable. |
| `open-reviews` | Show the PRs/MRs waiting on your review across GitHub and GitLab. |
| `open-prs` | List open PRs/MRs for the current repo, grouped by label. |
| `open-issues` | List open issues for the current repo, grouped by label. |
| `rfr` | Draft an "RFR: <link>" message in Slack, or copy it to the clipboard for Microsoft Teams. |

## Install

Each skill folder is self-contained, so you can copy just one into a skills directory instead of installing the whole pack.

### Claude Code

```
/plugin marketplace add scuba10steve/skills
/plugin install skills@scuba10steve
```

For a local checkout, use `claude --plugin-dir <path>`. Manifests: `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.

### Codex CLI

```
codex plugin marketplace add scuba10steve/skills
```

Then enable `skills@scuba10steve`. Marketplace: `.agents/plugins/marketplace.json`. Codex prefers the root `plugin.json` (portable Agent Plugins format); `.codex-plugin/plugin.json` is the compatibility layout and is also shipped.

### Cursor

Install through the Customize panel. For local development, place the repo in `~/.cursor/plugins/local/`. Manifest: `.cursor-plugin/plugin.json`.

### Kiro (IDE and CLI v3)

Install as a Power from the marketplace or a GitHub URL (Agent Plugins format). Manifest: root `plugin.json`, which has no `skills` field; Kiro finds the fixed `skills/` directory. Plain skills can also be copied to `.kiro/skills/` or `~/.kiro/skills/`. `kiro-cli powers install <catalog-name|local-path>` installs a Power from a catalog name or local path; `--help` lists no URL form (as of 2.32.0). `npx skills add scuba10steve/skills -g -a kiro-cli` installs to `~/.kiro/skills/`. A custom Kiro agent must list `skill://~/.kiro/skills/**/SKILL.md` in its `resources` to load global skills.

### GitLab Duo CLI

```
duo plugin marketplace add https://github.com/scuba10steve/skills.git
duo plugin install skills@scuba10steve
```

Duo reads the root `plugin.json` (and legacy `.claude-plugin/plugin.json`), and uses `.claude-plugin/marketplace.json` as its marketplace file. Alternatively copy the skills to `skills/` or `.agents/skills/` in a project, or `~/.gitlab/duo/skills/` (GitLab 18.10+, CLI 8.73+). Whether bundled scripts can be executed is not documented.

### OpenCode

No manifest: OpenCode plugins are JS/TS modules and there is no documented way to load a skills folder through them. Copy the folders in `skills/` to `.opencode/skills/` or `~/.config/opencode/skills/` (it also reads `.claude/skills/` and `.agents/skills/`).

### Gemini CLI

```
gemini extensions install https://github.com/scuba10steve/skills
```

Manifest: `gemini-extension.json`; skills in `skills/` are discovered automatically.

### Any other harness

```
npx skills add scuba10steve/skills -g -a <agent…>
```

Or copy the folders in `skills/` into your harness's skills directory.

## Requirements

- `git` and `jq`.
- `gh` and/or `glab`, optional, for the PR/MR/issue skills.
- Optional reviewer CLIs for `outside-voice`: `claude`, `gemini`, `codex`, `opencode`, `kiro-cli`, and `glab` for the `duo` target (runs `glab duo cli`).
- The superpowers plugin, for `spec-and-plan`.

## Configuration

`outside-voice` (flags override env vars):

| Variable | Default | Meaning |
|---|---|---|
| `OUTSIDE_VOICE_TIMEOUT` | `180` | Per-target timeout in seconds (`--timeout` wins) |
| `OUTSIDE_VOICE_OUTPUT_CAP` | `800` | Max reviewer output lines shown per target |
| `OUTSIDE_VOICE_DIFF_CAP` | `2000` | Max diff lines sent to reviewers |
| `OUTSIDE_VOICE_MODEL` | unset | Model passed as `--model` to kiro; literal, beats policy `review_model` (empty = unset) |
| `OUTSIDE_VOICE_EFFORT` | unset | Effort passed as `--effort` to kiro when supported; literal, beats policy `review_effort` (empty = unset) |

`task-estimate` reads `${XDG_CONFIG_HOME:-~/.config}/scuba10steve-skills/task-estimate.json` (cache: `${XDG_CACHE_HOME:-~/.cache}/scuba10steve-skills/task-estimate/`). In 0.2.x, if the new file is absent and the old `${XDG_CONFIG_HOME:-~/.config}/skills/task-estimate.json` exists, it is read with a stderr notice and the new file is not created; move it to the new path. The cache has no fallback. The config file is written with defaults on first run (when the directory is writable) and has flat top-level keys:

```json
{
  "buckets": {"s": 15000, "m": 40000, "l": 75000},
  "session_cap": 100000,
  "verbs": {"refactor|migrate|audit|investigate|overhaul": 3.0, "...": "..."},
  "scope_adverbs": {"everywhere|across|all of|repo-wide|entire|everything": 2.0, "...": "..."},
  "phase_split": {"read": 0.4, "plan": 0.15, "edit": 0.3, "verify": 0.15},
  "multi_agent": {"per_agent_base": 28000, "verb_to_agents": {"...": 4}, "default_agents": 1}
}
```

Your file is deep-merged over the defaults in memory on every run: your values win, and any key you omit, at any depth, uses the default. The file itself is never rewritten. If the directory is not writable, the defaults are used without writing anything.

`"providers": {"planning"|"bulk_edit"|"verify": "<harness name>"}` is optional; the labels are shown on split prompts.

### Tuning

An optional policy file pre-answers the choices skills otherwise ask about. With no file, every skill behaves as before.

Path: `${XDG_CONFIG_HOME:-~/.config}/scuba10steve-skills/policy`. Format: `key=value` lines. A line whose first non-space character is `#` is a comment; an inline `#` after a value is not, so `fan_out=allow # work` has the value `allow # work`, which is invalid (`ask`, or passed literally for `review_model`). Keys and values are trimmed, CRLF is tolerated, unknown keys are ignored, the last occurrence wins, an unreadable file counts as absent, and an empty value is unset. Each affected skill prints a `Policy: key=value (source)` line.

| Key | Values | Governs | Skills |
|---|---|---|---|
| `fan_out` | `allow` / `deny` / `ask` | parallel subagents for large inputs | `clean-comments` (sweep > 20 files) |
| `deep_budget` | `allow` / `deny` / `ask` | expensive budget tiers | `research` (deep budget), `task-estimate` (deep-scope subagent) |
| `multi_target` | `allow` / `deny` / `ask` | multi-target outside reviews | `outside-voice`, `spec-and-plan` |
| `review_targets` | comma list | default reviewer targets when none are named | `outside-voice`, `spec-and-plan` |
| `review_model` | `auto` / `<model-id>` / unset | reviewer model passed to kiro | `outside-voice` |
| `review_effort` | `<level>` / unset | `--effort` passed to kiro builds that support it | `outside-voice` |

- `allow`: take the expensive path without asking when the skill's own trigger is met. `deny`: do not offer it; take the cheap path and say the expensive one is available on request. `ask`: the default. Any other value resolves to `ask`.
- An explicit request beats `deny` (`--deep`, "go deep", naming several targets). Policy pre-answers the offer; it never blocks a direct instruction.
- `multi_target=allow` replaces the confirmation ask, not the cost preview, which is still shown before `--yes`.
- `OUTSIDE_VOICE_MODEL` and `OUTSIDE_VOICE_EFFORT` beat `review_model` and `review_effort`. `OUTSIDE_VOICE_MODEL=auto` passes `--model auto` literally.
- `review_effort` goes through the same `--effort` capability probe as the env var.

`review_model=auto` applies to kiro only, picking a model from a different provider than the caller:

| Caller provider | kiro `--model` |
|---|---|
| `anthropic` | `gpt-5.6-terra` |
| `openai` | `claude-opus-5` |
| anything else, including `unknown` | `claude-opus-5` (a default, not an avoidance choice; the notice says so) |

A literal `review_model=<id>` pins the model; unset passes no `--model`.

`review_targets` is a comma list of `claude`, `gemini`, `codex`, `opencode`, `kiro`, `duo`. Unknown names and duplicates are dropped, names whose CLI is not installed are skipped, and `all` is not accepted. It applies only when the user named no targets. One resolved target runs alone; two or more follow `multi_target`.

Exception: with or without a policy file, if the user named no targets and every target about to run matches the caller's own provider (`claude`, `codex`, `gemini`, `duo`; `kiro` and `opencode` never match), `outside-voice` asks before dispatching, since the review would not be independent. Explicitly named targets dispatch as before.

## Name collisions

In plain-folder installs, skills such as `pr` and `research` can shadow same-named skills or commands your harness already has. Rename the folder (and the `name` in its frontmatter) or install only the skills you want.

## Contributing

There is no `lib/`, test runner or sync script. Two scripts are shared between skills and the canonical copy lives in its owning skill:

- `skills/outside-voice/scripts/outside-voice.sh`, copied to `skills/spec-and-plan/scripts/`
- `skills/open-work/scripts/open-work.sh`, copied to `skills/open-reviews/scripts/`

After editing a canonical script, re-copy it to the other location. Run tests with `bash tests/<name>.test.sh` (for example `bash tests/outside-voice.test.sh`).

## License

MIT. See `LICENSE`.
