#!/usr/bin/env bash
# outside-voice — dispatch the current work to another AI harness for read-only review.
# In library mode (sourced by the test harness) we skip -e so a function that
# returns nonzero (e.g. resolve_targets on an unknown name) doesn't abort the
# sourcing shell. The test file sets its own `set -uo pipefail`.
if [[ -z "${OUTSIDE_VOICE_LIB:-}" ]]; then set -euo pipefail; fi

TARGET_ORDER=(claude gemini codex opencode kiro duo)

usage() {
    cat <<'EOF'
Usage: outside-voice [flags] <targets> "<instruction>" [path ...]

Dispatch the current work to another AI harness for a read-only review.

  <targets>   one of claude|gemini|codex|opencode|kiro|duo, a comma list, or 'all'
  instruction free-text describing what to review
  [path ...]  optional files/globs that replace the auto-scoped context

Flags:
  --parallel         run multi-target reviews concurrently (default: sequential)
  --timeout <sec>    per-target wall-clock cap (default: 180, or $OUTSIDE_VOICE_TIMEOUT)
  --yes              confirm a multi-target/all run (skip the dry preview)
  --base <ref>       diff against this ref instead of the detected base branch
  --avoid <provider> caller provider for collision notices (default: autodetected)
  -h, --help         show this help

Environment:
  OUTSIDE_VOICE_TIMEOUT     per-target timeout in seconds (default: 180; --timeout wins)
  OUTSIDE_VOICE_OUTPUT_CAP  max reviewer output lines shown per target (default: 800)
  OUTSIDE_VOICE_DIFF_CAP    max diff lines sent to reviewers (default: 2000)
  OUTSIDE_VOICE_MODEL       model passed as --model to kiro (default: unset)
  OUTSIDE_VOICE_EFFORT      effort passed as --effort to kiro when supported (default: unset)

Policy file (optional): ${XDG_CONFIG_HOME:-~/.config}/scuba10steve-skills/policy
EOF
}

# Map a target name to the binary that must be on PATH.
target_binary() {
    case "$1" in
        claude) echo claude ;; gemini) echo gemini ;; codex) echo codex ;;
        opencode) echo opencode ;; kiro) echo kiro-cli ;; duo) echo glab ;;
        *) return 1 ;;
    esac
}

cli_installed() {
    local bin; bin="$(target_binary "$1")" || return 1
    command -v "$bin" >/dev/null 2>&1
}

# resolve_targets <spec> -> priority-ordered, installed target names (one per line)
resolve_targets() {
    local spec="$1" requested=() name
    if [[ "$spec" == "all" ]]; then
        requested=("${TARGET_ORDER[@]}")
    else
        IFS=',' read -r -a requested <<< "$spec"
        # Trim surrounding whitespace so "claude, gemini" parses correctly.
        local i
        for i in "${!requested[@]}"; do requested[i]="${requested[i]//[[:space:]]/}"; done
    fi
    # Validate every requested name is known.
    for name in "${requested[@]}"; do
        target_binary "$name" >/dev/null 2>&1 || return 2
    done
    # Emit in canonical priority order, installed only.
    for name in "${TARGET_ORDER[@]}"; do
        for req in "${requested[@]}"; do
            if [[ "$name" == "$req" ]] && cli_installed "$name"; then echo "$name"; break; fi
        done
    done
    return 0
}

parse_args() {
    PARALLEL=0; TIMEOUT=""; ASSUME_YES=0; BASE_OVERRIDE=""; AVOID_OVERRIDE=""; PATHS=()
    TARGET_SPEC=""; INSTRUCTION=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --parallel) PARALLEL=1; shift ;;
            --timeout) [[ $# -ge 2 ]] || { echo "--timeout requires a value" >&2; exit 64; }; TIMEOUT="$2"; shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            --base) [[ $# -ge 2 ]] || { echo "--base requires a value" >&2; exit 64; }; BASE_OVERRIDE="$2"; shift 2 ;;
            --avoid)
                [[ $# -ge 2 ]] || { echo "--avoid requires a value" >&2; exit 64; }
                [[ -n "$2" ]] || { echo "--avoid requires a value" >&2; exit 64; }
                AVOID_OVERRIDE="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*) echo "unknown flag: $1" >&2; usage >&2; exit 64 ;;
            *) break ;;
        esac
    done
    TARGET_SPEC="${1:-}"; shift || true
    INSTRUCTION="${1:-}"; shift || true
    PATHS=("$@")
}

VALID_PROVIDERS=(anthropic openai google gitlab deepseek minimax zhipu qwen)

# caller_provider -> the calling harness's provider, for collision notices.
# --avoid wins outright; then env fingerprints in declared precedence order
# (first match, deliberately); then a documented anthropic default. The default
# is announced on stderr because a wrong guess can invert the guarantee.
caller_provider() {
    local override="${AVOID_OVERRIDE:-}"
    if [[ -n "$override" ]]; then printf '%s\n' "$override"; return 0; fi
    if [[ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then echo anthropic; return 0; fi
    if [[ -n "${CODEX_HOME:-}${CODEX_SANDBOX:-}" ]]; then echo openai; return 0; fi
    if [[ -n "${GEMINI_API_KEY:-}${GEMINI_CLI:-}" ]]; then echo google; return 0; fi
    # opencode is a harness, not a provider; its backing model is user-configured
    # and invisible to us, so it counts as unknown for avoidance purposes.
    # "unknown" is an internal sentinel, deliberately not in VALID_PROVIDERS:
    # that array gates user input to --avoid, and "avoid unknown" is meaningless.
    if [[ -n "${OPENCODE_BIN:-}${OPENCODE_CONFIG:-}" ]]; then echo unknown; return 0; fi
    echo "⚠ caller provider undetected; assuming anthropic (override with --avoid)" >&2
    echo anthropic
}

# target_providers <name> -> the providers this target can serve, one per line.
# Single-provider targets emit exactly one name; that is what makes a collision
# detectable. Returns 1 for an unknown target.
target_providers() {
    case "$1" in
        claude)   echo anthropic ;;
        codex)    echo openai ;;
        gemini)   echo google ;;
        duo)      echo gitlab ;;
        kiro)     printf '%s\n' anthropic openai deepseek minimax zhipu qwen ;;
        opencode) echo unknown ;;
        *) return 1 ;;
    esac
}

# reviewer_model <name> <avoid> -> a model identifier, or nothing.
# Empty output means "pass no --model flag". Only kiro takes a model, and only
# when OUTSIDE_VOICE_MODEL is set.
reviewer_model() {
    local name="$1"
    [[ "$name" == "kiro" ]] || return 0
    [[ -n "${OUTSIDE_VOICE_MODEL:-}" ]] || return 0
    printf '%s\n' "$OUTSIDE_VOICE_MODEL"
}

# warn_provider_collisions <avoid> <target>... -> stderr notices, always rc 0.
# Fires only for targets that serve exactly one provider and that provider is
# the one we are avoiding. A warning, not a block: a same-provider reviewer in a
# fresh context still has value, and the user asked for it by name.
warn_provider_collisions() {
    local avoid="$1"; shift
    local name provs
    # An unidentified caller cannot collide with anything; warning that a target
    # "shares the caller's provider (unknown)" would be noise, not information.
    # But the batch's diversity guarantee is unenforced in this case, and that
    # must not be silent either.
    if [[ "$avoid" == "unknown" ]]; then
        echo "⚠ caller provider unidentified; provider diversity not enforced (override with --avoid)" >&2
        return 0
    fi
    for name in "$@"; do
        provs="$(target_providers "$name" 2>/dev/null)" || continue
        [[ "$provs" == "$avoid" ]] || continue
        echo "⚠ $name shares the caller's provider ($avoid) — not an independent model" >&2
    done
    return 0
}

diff_cap() { echo "${OUTSIDE_VOICE_DIFF_CAP:-2000}"; }

policy_path() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/scuba10steve-skills/policy"; }

# policy_get <key> -> last trimmed value for key, or nothing. Always rc 0.
policy_get() {
    local want="$1" file line k v val=""
    file="$(policy_path)"
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        k="${line#"${line%%[![:space:]]*}"}"
        [[ "$k" == "#"* || "$k" != *=* ]] && continue
        v="${k#*=}"; k="${k%%=*}"
        k="${k%"${k##*[![:space:]]}"}"
        [[ "$k" == "$want" ]] || continue
        v="${v#"${v%%[![:space:]]*}"}"
        val="${v%"${v##*[![:space:]]}"}"
    done < "$file" 2>/dev/null
    [[ -n "$val" ]] && printf '%s\n' "$val"
    return 0
}

# base_ref -> the ref HEAD is compared against, or rc 1 when the repo offers no
# sensible base (callers then fall back to uncommitted changes only).
# Order: --base override, the remote's declared default branch, then the
# conventional names, preferring a local branch but falling back to origin/.
# On the base branch itself we use its remote counterpart, so committed-but-
# unpushed work stays in scope instead of collapsing to an empty range.
base_ref() {
    local override="${BASE_OVERRIDE:-}"
    if [[ -n "$override" ]]; then printf '%s\n' "$override"; return 0; fi
    local cur declared name
    cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    declared="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    local names=()
    [[ -n "$declared" ]] && names+=("${declared#origin/}")
    names+=(main master)
    for name in "${names[@]}"; do
        if [[ "$name" == "$cur" ]]; then
            git rev-parse --verify -q "refs/remotes/origin/$name" >/dev/null 2>&1 \
                && { printf 'origin/%s\n' "$name"; return 0; }
            return 1
        fi
        git rev-parse --verify -q "refs/heads/$name" >/dev/null 2>&1 \
            && { printf '%s\n' "$name"; return 0; }
        git rev-parse --verify -q "refs/remotes/origin/$name" >/dev/null 2>&1 \
            && { printf 'origin/%s\n' "$name"; return 0; }
    done
    return 1
}

# CANDIDATES holds one review's snapshot of untracked/ignored files.
# gather_context fills it exactly once via snapshot_candidates; both scoped_diff
# and the pre-dispatch announcement read it. Enumerating separately per consumer
# would let the announced set and the transmitted set diverge if the worktree
# changed in between, breaking the promise that every file sent was listed
# first — and gather_context calls scoped_diff twice, so it would enumerate
# three times per run.
CANDIDATES=()

# untracked_candidates -> NUL-delimited untracked/ignored files under PATHS.
#
# Ignored files are reachable ONLY through an exact-file pathspec. A directory
# pathspec must never sweep ignored descendants: ignored trees routinely hold
# credentials and review targets are external providers. Untracked-but-not-ignored files carry no such
# expectation — they are already visible to `git status` — so those may expand
# from a directory pathspec.
#
# One invocation per category, not one per path: a single `git ls-files` call
# collapses overlapping and repeated pathspecs, and the two categories are
# disjoint by construction (`--ignored` selects only ignored files; omitting it
# selects only non-ignored ones). No explicit dedupe is required.
untracked_candidates() {
    [[ "${#PATHS[@]}" -gt 0 ]] || return 0
    local p
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # No repository: ls-files cannot enumerate, but `diff --no-index` still
        # works, so explicit files stay reviewable instead of collapsing to
        # "Nothing to review".
        for p in "${PATHS[@]}"; do
            [[ -f "$p" ]] && printf '%s\0' "$p"
        done
        return 0
    fi
    local exact=()
    for p in "${PATHS[@]}"; do
        [[ -f "$p" ]] && exact+=("$p")
    done
    # The non-ignored query needs no pathspec restriction: `--exclude-standard`
    # without `--ignored` cannot return an ignored file no matter what the
    # pathspec matches, and untracked-not-ignored files are already visible to
    # `git status`. Leaving it glob-capable keeps path arguments behaving as
    # they do for the tracked `git diff` above, which is not literal either.
    git ls-files -z --others --exclude-standard -- "${PATHS[@]}" 2>/dev/null
    if [[ "${#exact[@]}" -gt 0 ]]; then
        # GIT_LITERAL_PATHSPECS=1 matters HERE, and only here. Without it the
        # exact-file rule is bypassable: a file literally named `work/*`
        # satisfies `[[ -f ]]`, and git then expands that same string as a
        # wildcard — verified to return `work/creds.sh` alongside it. Literal
        # mode still honors directory pathspecs, so `-- .` and `-- docs/`
        # behave as before (verified).
        GIT_LITERAL_PATHSPECS=1 \
            git ls-files -z --others --ignored --exclude-standard -- "${exact[@]}" 2>/dev/null
    fi
}

# snapshot_candidates -> fill CANDIDATES from untracked_candidates. Call once
# per review, before any consumer reads CANDIDATES.
snapshot_candidates() {
    CANDIDATES=()
    local f
    while IFS= read -r -d '' f; do
        CANDIDATES+=("$f")
    done < <(untracked_candidates)
}

# scoped_diff <base> [git-diff flags...] -> committed work since <base> plus
# everything uncommitted, narrowed to PATHS when set. `git diff HEAD` covers
# staged and unstaged in one pass, so nothing is emitted twice.
scoped_diff() {
    local base="$1"; shift
    local flags=("$@") pathspec=()
    [[ "${#PATHS[@]}" -gt 0 ]] && pathspec=(-- "${PATHS[@]}")
    if [[ -n "$base" ]]; then
        git diff ${flags[@]+"${flags[@]}"} "$base...HEAD" ${pathspec[@]+"${pathspec[@]}"} 2>/dev/null || true
    fi
    git diff ${flags[@]+"${flags[@]}"} HEAD ${pathspec[@]+"${pathspec[@]}"} 2>/dev/null || true
    # Third source: explicitly-passed untracked/ignored files, which the two
    # calls above cannot see. Reads the snapshot rather than re-enumerating.
    # `--no-index` exits 1 on difference, hence `|| true`.
    local f
    for f in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
        git diff --no-index ${flags[@]+"${flags[@]}"} -- /dev/null "$f" 2>/dev/null || true
    done
}

# warn_unmatched_paths -> stderr notices for explicit paths that match nothing,
# always rc 0. `git ls-files` exits 0 with empty output for a nonexistent path,
# so without this a typo'd artifact path fails as "Nothing to review" with no
# indication of the cause.
warn_unmatched_paths() {
    [[ "${#PATHS[@]}" -gt 0 ]] || return 0
    local p
    for p in "${PATHS[@]}"; do
        [[ -e "$p" ]] && continue
        git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && continue
        echo "⚠ $p matched no file" >&2
    done
    return 0
}

# Emit "<stat>\n\n<diff>", capped. Returns 3 if there is nothing to review.
gather_context() {
    warn_unmatched_paths
    snapshot_candidates
    if [[ "${#CANDIDATES[@]}" -gt 0 ]]; then
        echo "including untracked/ignored files:" >&2
        local _c
        for _c in "${CANDIDATES[@]}"; do
            echo "  $_c" >&2
        done
    fi
    local cap; cap="$(diff_cap)"
    local base stat diff
    base="$(base_ref)" || base=""
    stat="$(scoped_diff "$base" --stat)"
    diff="$(scoped_diff "$base")"
    [[ -z "$diff" ]] && return 3
    local total kept notice=""
    total="$(printf '%s\n' "$diff" | wc -l | tr -d ' ')"
    if [[ "$total" -gt "$cap" ]]; then
        kept="$(printf '%s\n' "$diff" | head -n "$cap")"
        notice=$'\n[truncated '"$((total - cap))"' lines]'
        diff="$kept"
    fi
    printf '## Changed files\n%s\n\n## Diff\n%s%s\n' "$stat" "$diff" "$notice"
}

default_timeout() { echo "${OUTSIDE_VOICE_TIMEOUT:-180}"; }
output_cap()      { echo "${OUTSIDE_VOICE_OUTPUT_CAP:-800}"; }

compose_prompt() {
    local instruction="$1" context="$2"
    cat <<EOF
You are an outside reviewer invoked by another AI harness. Review the work below.
IMPORTANT: analyze and report ONLY. Do not modify files, do not commit, do not run
mutating commands, and do not invoke further review tools.

## Review request
$instruction

## Work under review
$context
EOF
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout -k 5 "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout -k 5 "$secs" "$@"
    else
        "$@" <&0 & local pid=$!
        ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) & local watcher=$!
        wait "$pid" 2>/dev/null; local rc=$?
        if kill -0 "$watcher" 2>/dev/null; then
            # watcher still sleeping => command finished on its own
            kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
            return "$rc"
        fi
        # watcher already exited => it fired the kill => treat as timeout
        return 124
    fi
}

# Invocation forms:
#   claude   stdin OK (live-confirmed)
#   codex    `codex exec -` consumes stdin (live-confirmed; needs OpenAI auth)
#   gemini   `-p ""` + stdin-append (form accepted; needs GEMINI_API_KEY)
#   kiro     positional arg (live-confirmed)
#   opencode positional arg per --help (live-unverified; SIGKILL-protected)
#   duo      `run --goal <prompt>` (goal is a required flag; stdin is NOT read.
#            UNVERIFIED end-to-end — needs `glab auth login`; without --goal it
#            drops into the interactive TUI. timeout+SIGKILL degrades a hang cleanly)
kiro_supports_effort() { kiro-cli chat --help 2>/dev/null | grep -q -- '--effort'; }

run_target() {
    local name="$1" prompt="$2" secs="$3" model="${4:-}"
    case "$name" in
        claude)   printf '%s' "$prompt" | run_with_timeout "$secs" claude -p ;;
        gemini)   printf '%s' "$prompt" | run_with_timeout "$secs" gemini -p "" ;;
        codex)    printf '%s' "$prompt" | run_with_timeout "$secs" codex exec - ;;
        opencode) run_with_timeout "$secs" opencode run "$prompt" ;;
        kiro)     local kiro_args=()
                  [[ -n "$model" ]] && kiro_args+=(--model "$model")
                  # Older kiro-cli builds reject --effort outright, so probe
                  # --help rather than failing the whole review.
                  [[ -n "${OUTSIDE_VOICE_EFFORT:-}" ]] && kiro_supports_effort && kiro_args+=(--effort "$OUTSIDE_VOICE_EFFORT")
                  run_with_timeout "$secs" kiro-cli chat --no-interactive \
                      --trust-tools=fs_read ${kiro_args[@]+"${kiro_args[@]}"} "$prompt" ;;
        duo)      run_with_timeout "$secs" glab duo cli --yes run --goal "$prompt" ;;
    esac
}

frame_target() {
    local name="$1" out="$2" err="$3" rc="$4" cap; cap="$(output_cap)"
    printf '═══ %s ═══\n' "$name"
    if [[ "$rc" -eq 124 ]]; then
        printf '⚠ %s timed out\n' "$name"; [[ -n "$err" ]] && printf '%s\n' "$err"; return 0
    fi
    if [[ "$rc" -ne 0 || -z "$out" ]]; then
        printf '⚠ %s failed (exit %s)\n' "$name" "$rc"; [[ -n "$err" ]] && printf '%s\n' "$err"; return 0
    fi
    local total; total="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
    if [[ "$total" -gt "$cap" ]]; then
        printf '%s\n[reviewer output truncated — %s lines omitted]\n' \
            "$(printf '%s\n' "$out" | head -n "$cap")" "$((total - cap))"
    else
        printf '%s\n' "$out"
    fi
}

run_all() {
    local targets=("$@") secs context prompt name avoid
    secs="${TIMEOUT:-$(default_timeout)}"
    avoid="$(caller_provider)"
    context="$(gather_context)" || { echo "Nothing to review (no diff, no paths given)." >&2; exit 3; }
    warn_provider_collisions "$avoid" ${targets[@]+"${targets[@]}"}
    prompt="$(compose_prompt "$INSTRUCTION" "$context")"
    if [[ "$PARALLEL" -eq 1 ]]; then
        local tmp; tmp="$(mktemp -d)"
        for name in "${targets[@]}"; do
            { local o rc m; m="$(reviewer_model "$name" "$avoid")"
              o="$(run_target "$name" "$prompt" "$secs" "$m" 2>"$tmp/$name.err")" && rc=0 || rc=$?
              frame_target "$name" "$o" "$(cat "$tmp/$name.err")" "$rc" > "$tmp/$name.out"; } &
        done
        wait
        for name in "${targets[@]}"; do cat "$tmp/$name.out"; echo; done
        rm -rf "$tmp"
    else
        for name in "${targets[@]}"; do
            local errf; errf="$(mktemp)"
            local o rc m
            m="$(reviewer_model "$name" "$avoid")"
            o="$(run_target "$name" "$prompt" "$secs" "$m" 2>"$errf")" && rc=0 || rc=$?
            frame_target "$name" "$o" "$(cat "$errf")" "$rc"; echo
            rm -f "$errf"
        done
    fi
}

main() {
    parse_args "$@"
    [[ -z "$TARGET_SPEC" || -z "$INSTRUCTION" ]] && { usage >&2; exit 64; }
    if [[ -n "$BASE_OVERRIDE" ]] && ! git rev-parse --verify -q "${BASE_OVERRIDE}^{commit}" >/dev/null 2>&1; then
        echo "--base: cannot resolve ref '$BASE_OVERRIDE'" >&2; exit 64
    fi
    if [[ -n "$AVOID_OVERRIDE" ]]; then
        local ok=0 p
        for p in "${VALID_PROVIDERS[@]}"; do [[ "$p" == "$AVOID_OVERRIDE" ]] && ok=1; done
        [[ "$ok" -eq 1 ]] || {
            echo "--avoid: unknown provider '$AVOID_OVERRIDE'. valid: ${VALID_PROVIDERS[*]}" >&2
            exit 64
        }
    fi
    local resolved
    if ! resolved="$(resolve_targets "$TARGET_SPEC")"; then
        echo "unknown target in '$TARGET_SPEC'. valid: ${TARGET_ORDER[*]}, or 'all'." >&2
        exit 64
    fi
    # Explicitly-named-but-uninstalled targets get a notice (silent for 'all').
    if [[ "$TARGET_SPEC" != "all" ]]; then
        local req name
        IFS=',' read -r -a req <<< "$TARGET_SPEC"
        for name in "${req[@]}"; do
            name="${name//[[:space:]]/}"
            grep -qx "$name" <<< "$resolved" || echo "⚠ $name unavailable (CLI not installed)" >&2
        done
    fi
    [[ -z "$resolved" ]] && { echo "no requested target CLIs are installed." >&2; exit 69; }
    local targets=(); while IFS= read -r line; do targets+=("$line"); done <<< "$resolved"
    if [[ "${#targets[@]}" -gt 1 && "$ASSUME_YES" -ne 1 ]]; then
        printf 'This would run %d paid reviewer runs: %s\n' "${#targets[@]}" "${targets[*]}"
        printf 'Re-run with --yes to proceed.\n'
        exit 0
    fi
    run_all "${targets[@]}"
}

if [[ -z "${OUTSIDE_VOICE_LIB:-}" ]]; then
    main "$@"
fi
