---
name: outside-voice
description: Dispatch the current work to a DIFFERENT AI harness for a read-only review and relay it verbatim. Use when the user invokes /outside-voice or asks to get a second opinion / outside review from another agent (claude, gemini, codex, opencode, kiro, duo). Handles single or multi-target fan-out with a confirmation gate.
---

# Outside Voice

Dispatch the current work to another harness for a read-only review.

## Args

- `/outside-voice <targets> "<instruction>" [path ...]`
- `<targets>`: `claude|gemini|codex|opencode|kiro|duo`, a comma list, or `all`. May be omitted (`/outside-voice "<instruction>" [path ...]`) only when `review_targets` resolves non-empty (see Policy).
- Optional flags: `--parallel` (run multi-target reviews concurrently; default sequential), `--timeout <sec>` (per-target cap), `--yes` (confirm a multi-target/`all` run).
- Optional flags cont.: `--base <ref>` (diff against this ref instead of the detected base branch), `--avoid <provider>` (override the autodetected caller provider).

## Scope

The reviewed diff is **committed work since the base branch plus everything
uncommitted**. The base branch is resolved from `origin/HEAD`, then `main`,
then `master` — local branch preferred, `origin/` counterpart as fallback. On
the base branch itself the remote counterpart is used, so unpushed commits stay
in scope. Passing paths narrows that scope; it does not switch it to
working-tree-only.

Explicitly passed paths may be **untracked or gitignored** — that is how a
gitignored spec or plan gets reviewed. Ignored files are reachable only by
**exact file path**: a directory pathspec deliberately contributes no ignored
files, so `outside-voice.sh . ` cannot sweep an ignored tree of credentials out
to an external reviewer. The *ignored* lookup resolves its pathspec literally, so a
file whose name contains glob characters cannot expand into its ignored
siblings. Pathspecs for tracked and untracked-not-ignored files still glob, the
same way they do for the underlying `git diff`. Untracked-but-not-ignored files may
expand from a directory. Every included file is listed on stderr before
dispatch, and a path matching nothing warns `⚠ <path> matched no file` instead
of failing silently as "Nothing to review".

If the repo's target branch is none of those (a release branch, a stacked MR),
pass it explicitly: `--base origin/release-2.4`.

## Model diversity

Pick a target whose provider differs from the calling harness's, so the
reviewer does not share the author's blind spots. The script does not choose
models: `kiro` runs its default model unless `OUTSIDE_VOICE_MODEL` is set (see
Configuration); set it to pick a model from a different provider.

`claude`, `codex`, `gemini`, and `duo` are each locked to one provider; when one
of them matches the caller you get a `⚠ shares the caller's provider` notice,
not a refusal.

`--avoid <provider>` overrides the autodetected caller provider that those
notices compare against. It changes no target's model. Valid values:
`anthropic`, `openai`, `google`, `gitlab`, `deepseek`, `minimax`, `zhipu`, `qwen`.

Caller detection is best-effort and says so when it isn't sure. Two notices can
appear on stderr: `⚠ caller provider undetected; assuming anthropic (override
with --avoid)` when no fingerprint matches at all, and `⚠ caller provider
unidentified; provider diversity not enforced (override with --avoid)` when the
caller is `opencode`, whose backing provider is invisible to us. Either one
means the collision notices may be wrong for this run — pass `--avoid
<provider>` to make the caller's provider explicit instead of guessed.

## Policy

Before dispatch, resolve `multi_target` (`allow`, `deny`, or `ask`) and
`review_targets`:

```bash
policy="${XDG_CONFIG_HOME:-$HOME/.config}/scuba10steve-skills/policy"
v="$(tr -d '\r' 2>/dev/null < "$policy" | sed -n 's/^[[:space:]]*multi_target[[:space:]]*=[[:space:]]*//p' | sed 's/[[:space:]]*$//' | tail -n 1)"
case "$v" in allow|deny|ask) src="$policy" ;; "") v=ask; src=default ;; *) src="default; invalid value '$v' in $policy"; v=ask ;; esac
echo "Policy: multi_target=$v ($src)"
t="$(tr -d '\r' 2>/dev/null < "$policy" | sed -n 's/^[[:space:]]*review_targets[[:space:]]*=[[:space:]]*//p' | sed 's/[[:space:]]*$//' | tail -n 1)"
printf '%s\n' "$t" | tr ',' '\n' | {
  l=; r=
  while read -r n; do
    case " $l " in *" $n "*) continue ;; esac
    case "$n" in
      "") continue ;;
      claude|gemini|codex|opencode) b=$n ;;
      kiro) b=kiro-cli ;;
      duo) b=glab ;;
      *) echo "Policy: review_targets dropped unknown name '$n'"; continue ;;
    esac
    l="$l $n"
    command -v "$b" >/dev/null 2>&1 && r="${r:+$r,}$n"
  done
  if [ -z "$l" ]; then echo "Policy: review_targets=none (default)"
  elif [ -z "$r" ]; then echo "Policy: review_targets=none ($policy; none of$l installed)"
  else echo "Policy: review_targets=$r ($policy)"; fi
}
```

Print every `Policy:` line. Unset or invalid `multi_target` means `ask`.

If the user named targets, use them and ignore `review_targets`. Several named
targets: under `allow`, show step 2's preview then re-run with `--yes` without
waiting; under `ask` or `deny`, step 2 as written (naming them is the request,
so `deny` never blocks it).

If the user named none, the resolved `review_targets` list decides:

- **Two or more:** under `ask`, propose the list and ask, then step 2; under
  `allow`, step 2's preview then `--yes` without waiting; under `deny`, run the
  first alone and say the rest are available on request.
- **One:** run it as a single target (step 1).
- **`none`, "none of ... installed":** say `review_targets` matched no installed
  CLI, then ask for a target as without a policy.
- **`none (default)`:** `<targets>` is required, as without a policy.
- **No reviewer CLI installed at all:** say so and stop.

**Same-provider rule** (with or without a policy file): if every target about
to run is one of `claude` (anthropic), `codex` (openai), `gemini` (google), or
`duo` (gitlab) and matches your own harness's provider (or `--avoid`), ask
before dispatching — the review would not come from an independent model.
`kiro` and `opencode` never match. If you can't ask, don't dispatch; say why
and stop.

## Procedure

`<skill-dir>` is the directory containing this `SKILL.md`.

1. For a SINGLE target (subject to the same-provider rule), run and relay verbatim:

   ```bash
   bash <skill-dir>/scripts/outside-voice.sh <targets> "<instruction>" [paths...]
   ```

2. For MULTIPLE targets or `all`, first run WITHOUT `--yes` to get the cost
   preview and show the resolved target list to the user. Never take the
   expensive path without explicit consent, given in the original request, as
   an answer to the ask, or by `multi_target=allow`. If you can't ask the user, report the preview and
   stop; do not quietly run fewer targets and do not go ahead. Only on approval,
   re-run with `--yes`:

   ```bash
   bash <skill-dir>/scripts/outside-voice.sh --yes <targets> "<instruction>" [paths...]
   ```

   An explicitly named target whose CLI is absent warns and is dropped; if none
   are installed the script exits 69.

3. Relay each reviewer's framed output verbatim, before any interpretation. Do
   NOT summarize or reconcile it in place — the user is the judge of what the
   reviewer said.

   Relaying verbatim and validating are **sequential, not competing**. Once the
   output is relayed intact, a separately labelled validation pass over it is
   not only permitted but expected for anything you intend to act on: reviewers
   in this setup ran a 60-70% useful-finding rate, so acting on unvalidated
   findings is how a confident wrong claim becomes a real bug. See
   `/spec-and-plan` for the full validate-then-fold gate.

## Configuration

Environment knobs, all optional:

- `OUTSIDE_VOICE_TIMEOUT`: per-target timeout in seconds (default 180; `--timeout` wins).
- `OUTSIDE_VOICE_OUTPUT_CAP`: max reviewer output lines shown per target (default 800).
- `OUTSIDE_VOICE_DIFF_CAP`: max diff lines sent to reviewers (default 2000).
- `OUTSIDE_VOICE_MODEL`: model passed as `--model` to kiro (default unset).
- `OUTSIDE_VOICE_EFFORT`: effort passed to kiro as `--effort` when supported (default unset).
