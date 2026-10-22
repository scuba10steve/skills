---
name: task-estimate
description: Estimate token usage for a task prompt and produce a bucket (S/M/L/XL) plus ready-to-paste split prompts at L/XL. Use when the user invokes /task-estimate or asks for a token-budget pre-check before starting non-trivial work.
---

# Task Estimate

Estimate token usage for a task before starting it, so the user can decide whether to run inline, phase-split across providers, or decompose first.

## Trigger

- Invoked explicitly via `/task-estimate "<prompt>"`.
- Invoked when the user asks for a token estimate, budget check, or provider-split recommendation for a specific task.
- Do NOT self-invoke. Only run when asked.

## Args

- `/task-estimate "<prompt>"` → heuristic estimate, default human output.
- `/task-estimate --json "<prompt>"` → machine-readable JSON.
- `/task-estimate --breakdown "<prompt>"` → include per-phase token allocation.
- `/task-estimate --deep "<prompt>"` → force deep-scope subagent.
- `/task-estimate --no-split "<prompt>"` → suppress split-prompt generation at L/XL.

## Procedure

### Step 1 — Run the heuristic

```sh
bash <skill-dir>/scripts/task-estimate.sh --json <the user's arguments>
```

`<skill-dir>` is the directory containing this `SKILL.md`.

Thresholds, the session cap, and other settings come from `${XDG_CONFIG_HOME:-~/.config}/scuba10steve-skills/task-estimate.json` (flat keys: `buckets.{s,m,l}`, `session_cap`, `verbs`, `scope_adverbs`, `phase_split`, `multi_agent`, and an optional `providers`). The file is auto-created with defaults on first run when its directory is writable; any key it omits falls back to the default.

Capture the JSON. Read `bucket`, `confidence`, `requested_deep`.

### Step 1.5 — Quick codebase glance

Skip this step if `requested_deep` is true — the deep-scope subagent in Step 3 supersedes it.

Run **at most 5** shell commands to collect a lightweight codebase snapshot.
Good candidates — pick the most relevant to the prompt:

```sh
ls -1                                              # top-level layout
git status --short                                 # pending / modified files
git diff --stat HEAD                               # which files are in-flight
find . -maxdepth 2 -type f | wc -l                # rough total file count
ls <directory most implied by the prompt>          # one targeted dir peek
```

From the snapshot, reason briefly (internal only — do not emit this):
- How many distinct files would this task realistically touch?
- Are pending changes already in-flight that compound the scope?
- Does the repo structure suggest the task is wider or narrower than the prompt implies?

Then emit a **Quick analysis** block immediately after the heuristic output:

```
Quick analysis (N tool calls):
Saw: <1–2 sentences on what you found>
Assumption: <what you're assuming about scope/intent>
Adjusted estimate: ~Xk–Yk tokens, N–M agents
```

Rules:
- Hard cap: **≤5 tool calls**. Stop after 5 regardless of what remains.
- If your adjusted estimate is within 25% of the heuristic, append "(agrees with heuristic)".
- If it diverges by more than 25%, say so explicitly — the user uses this to decide whether to proceed, decompose, or escalate to `--deep`.
- Do **not** read file contents in this step — directory listings and stat output only.

### Step 2 — Decide whether to escalate to deep-scope

Deep-scope (a read-only exploration subagent) is the expensive path. Run it only with consent: the user passed `--deep`, or the user says yes when offered.

**Offer trigger** (any of):
- `requested_deep` is true (user passed `--deep`; consent is already given)
- Bucket is `L` and confidence is `low`
- Bucket is `XL`

**Capability guard:** the harness can dispatch subagents.

If the trigger holds and the user passed `--deep`, proceed to Step 3. If the trigger holds without `--deep`, ask whether to run deep-scope. On yes, proceed to Step 3. On no, skip to Step 4. If you can't ask (non-interactive run), show a preview of what deep-scope would do (the Step 3 prompt, with the heuristic JSON filled in) and stop; do not quietly skip it and do not run it. If the trigger does not hold, skip to Step 4. If the guard fails, say deep-scope is unavailable here and skip to Step 4.

### Step 3 — Deep-scope subagent

Dispatch a read-only exploration subagent with this prompt:

> You are estimating token usage for a task. Heuristic baseline (JSON): `<paste JSON>`.
> Original prompt: `<verbatim user prompt>`.
>
> Read at most 6 files implied by the prompt (named paths, files modified in the last 7 days inside named repos, or files matching obvious keywords from the prompt). Do not read exhaustively — sample.
>
> Return a JSON object with these fields and **nothing else**:
>
> ```json
> {
>   "total": <int>, "low": <int>, "high": <int>,
>   "breakdown": {"read": <int>, "plan": <int>, "edit": <int>, "verify": <int>},
>   "decomposition": [ { "label": "<short>", "files": ["<path>", ...], "rationale": "<sentence>" }, ... ] | null,
>   "rationale": "<2-3 sentences explaining the estimate>"
> }
> ```
>
> Token budget for this analysis: ≤15k tokens. Bias toward sampling, not exhaustive reads.
> For XL prompts, populate `decomposition` with independent units if any exist; otherwise return `null`.

Validate the returned JSON via `jq -e .`. If invalid, log to stderr, fall back to the heuristic.

### Step 4 — Merge (if deep-scope ran) and render

If deep-scope returned valid JSON:
1. Replace `estimate.total/low/high` and `breakdown` with the agent's numbers.
2. **Re-derive `bucket`** from the new `estimate.total` using the thresholds in `.buckets.{s,m,l}` of `${XDG_CONFIG_HOME:-~/.config}/scuba10steve-skills/task-estimate.json` (defaults 15000/40000/75000 when absent). Use the same `< threshold` semantics as the script's `bucket_for` function.
3. **Re-derive `recommendation`** from the new bucket using the same prose as `recommendation_for` in the script (S/M → "Fits comfortably...", L → "Tight against session cap...", XL → "Will overflow session cap...").
4. Set `method: "deep-scope"`, `confidence: "high"`.
5. If the merged bucket is now XL, follow Step 5 to generate scope-split prompts (the script's L phase-split prompts, if any, should be discarded).
6. If the merged bucket dropped to S/M, clear the `prompts` array.

Render the human-facing output mirroring the script's format:

```
~Xk tokens (low–high) — BUCKET, METHOD, confidence: LEVEL
Recommendation: TEXT
[breakdown line if --breakdown]
[--- prompt N: provider --- blocks if any]
Artifacts: <run_dir>
```

### Step 5 — Scope-split prompt rendering (XL only)

The script does not pre-create the run-id directory at XL bucket (only L triggers `render_phase_split`). Before writing any scope-N.md files, materialize the directory yourself:

```sh
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/scuba10steve-skills/task-estimate/<run-id>"
```

For each unit in `decomposition`:

```markdown
# Scope unit N/M — <label> [(provider: <bulk_edit provider from config>) only when the config defines providers]

Independent unit. Do not depend on the output of other units.

Files:
- <path 1>
- <path 2>
- ...

Original task:
<verbatim user prompt>

Unit rationale: <rationale from agent>

Coordination doc: ${XDG_CACHE_HOME:-$HOME/.cache}/scuba10steve-skills/task-estimate/<run-id>/README.md
```

Write each to `${XDG_CACHE_HOME:-$HOME/.cache}/scuba10steve-skills/task-estimate/<run-id>/scope-<N>.md`. Create `${XDG_CACHE_HOME:-$HOME/.cache}/scuba10steve-skills/task-estimate/<run-id>/README.md` (the script did not write one at XL) listing the run-id, bucket, parallel execution ordering, and each scope unit's filename (plus its provider when the config defines providers).

Treat an empty array (`decomposition: []`) the same as `null`.

If `decomposition` is `null`, emit:

```
WARN: This task is XL and no clean decomposition was found. Decompose manually before starting.
```

and exit non-zero.

## Failure modes

- Script exits non-zero → surface stderr to the user, do not fabricate an estimate.
- `jq` not installed → script self-reports and exits; surface the message.
- Subagent returns malformed JSON → fall back to heuristic, log to stderr.
- Subagent exceeds budget → trust whatever JSON it returns if valid; otherwise fall back.
