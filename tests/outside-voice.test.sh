#!/usr/bin/env bash
# outside-voice.test.sh — assertions for outside-voice.sh
set -uo pipefail

USER_HOME_BACKUP="$HOME"
trap 'export HOME="$USER_HOME_BACKUP"; [[ -n "${STUBDIR:-}" ]] && rm -rf "$STUBDIR"' EXIT

SCRIPT_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )"
SCRIPT="$SCRIPT_DIR/../skills/outside-voice/scripts/outside-voice.sh"
PASS=0; FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then PASS=$((PASS+1)); printf '  ok  %s\n' "$label"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n    expected: %q\n    actual:   %q\n' "$label" "$expected" "$actual"; fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then PASS=$((PASS+1)); printf '  ok  %s\n' "$label"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n    needle:   %q\n    haystack: %q\n' "$label" "$needle" "$haystack"; fi
}

# Stub CLIs so cli_installed sees them. Each stub echoes a marker.
STUBDIR="$(mktemp -d)"
for c in claude gemini codex opencode kiro-cli glab; do
    printf '#!/usr/bin/env bash\necho "STUB-%s"\n' "$c" > "$STUBDIR/$c"
    chmod +x "$STUBDIR/$c"
done
export PATH="$STUBDIR:$PATH"

# Source the script in library mode (no main) to test functions directly.
OUTSIDE_VOICE_LIB=1 source "$SCRIPT"

# resolve_targets: single
assert_eq "resolve single" "claude" "$(resolve_targets claude)"
# resolve_targets: comma list keeps priority order regardless of input order
assert_eq "resolve comma order" $'claude\ngemini' "$(resolve_targets gemini,claude)"
# resolve_targets: all expands to full installed order
assert_eq "resolve all" $'claude\ngemini\ncodex\nopencode\nkiro\nduo' "$(resolve_targets all)"
# resolve_targets: unknown returns nonzero
resolve_targets bogus >/dev/null 2>&1; assert_eq "resolve unknown rc" "2" "$?"
# spaced comma list is trimmed
assert_eq "resolve spaced list" $'claude\ngemini' "$(resolve_targets 'claude, gemini')"
# duplicate names de-dupe to a single run
assert_eq "resolve dedupe" "claude" "$(resolve_targets claude,claude)"

unset OUTSIDE_VOICE_TIMEOUT OUTSIDE_VOICE_OUTPUT_CAP OUTSIDE_VOICE_DIFF_CAP OUTSIDE_VOICE_MODEL OUTSIDE_VOICE_EFFORT
TMPHOME_T3="$(mktemp -d)"
export HOME="$TMPHOME_T3"

# env knobs have fixed defaults
assert_eq "timeout default 180" "180" "$(default_timeout)"
assert_eq "timeout env" "90" "$(OUTSIDE_VOICE_TIMEOUT=90 default_timeout)"
assert_eq "output cap default 800" "800" "$(output_cap)"
assert_eq "output cap env" "50" "$(OUTSIDE_VOICE_OUTPUT_CAP=50 output_cap)"
assert_eq "diff cap default 2000" "2000" "$(diff_cap)"
assert_eq "diff cap env" "10" "$(OUTSIDE_VOICE_DIFF_CAP=10 diff_cap)"

# --- caller_provider -------------------------------------------------------
# Every case runs inside $( ), which is a subshell, so cp_scrub's unset and the
# assignments after it are confined to that one assertion. Scrubbing matters:
# the dev machine exports CLAUDECODE, and without this the codex and default
# cases would silently answer "anthropic" and pass for the wrong reason.
cp_scrub() {
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CODEX_HOME CODEX_SANDBOX \
          GEMINI_API_KEY GEMINI_CLI OPENCODE_BIN OPENCODE_CONFIG
    AVOID_OVERRIDE=''
}

# Each fingerprint maps to its provider.
assert_eq "caller detects claude" "anthropic" "$( cp_scrub; CLAUDECODE=1;      caller_provider 2>/dev/null )"
assert_eq "caller detects codex"  "openai"    "$( cp_scrub; CODEX_HOME=/tmp;   caller_provider 2>/dev/null )"
assert_eq "caller detects gemini" "google"    "$( cp_scrub; GEMINI_API_KEY=x;  caller_provider 2>/dev/null )"
assert_eq "caller detects opencode" "unknown" "$( cp_scrub; OPENCODE_BIN=/tmp/oc; caller_provider 2>/dev/null )"
# --avoid beats every fingerprint.
assert_eq "caller override wins"  "openai"    "$( cp_scrub; CLAUDECODE=1; AVOID_OVERRIDE=openai; caller_provider 2>/dev/null )"
# Nothing matches -> anthropic, and the guess is announced on stderr.
assert_eq "caller default value"  "anthropic" "$( cp_scrub; caller_provider 2>/dev/null )"
assert_contains "caller default warns" "undetected" "$( cp_scrub; caller_provider 2>&1 >/dev/null )"
# A confident answer is silent — the notice marks a guess, not every resolution.
assert_eq "caller detected is silent" "" "$( cp_scrub; CLAUDECODE=1;           caller_provider 2>&1 >/dev/null )"
assert_eq "caller override is silent" "" "$( cp_scrub; AVOID_OVERRIDE=openai;  caller_provider 2>&1 >/dev/null )"
assert_eq "caller opencode is silent" "" "$( cp_scrub; OPENCODE_BIN=/tmp/oc;   caller_provider 2>&1 >/dev/null )"
# First match wins when several fingerprints are set at once.
assert_eq "caller first match wins" "anthropic" "$( cp_scrub; CLAUDECODE=1; CODEX_HOME=/tmp; caller_provider 2>/dev/null )"

# --- target_providers / reviewer_model -------------------------------------
# An `assert_eq "" "$(fn ...)"` passes when fn is undefined as well as when it
# correctly returns empty. Pin definedness first so the empty-return
# assertions below can only pass for the right reason.
assert_eq "target_providers is defined" "0" "$(declare -f target_providers >/dev/null 2>&1; echo $?)"
assert_eq "reviewer_model is defined" "0" "$(declare -f reviewer_model >/dev/null 2>&1; echo $?)"

assert_eq "providers claude" "anthropic" "$(target_providers claude)"
assert_eq "providers codex" "openai" "$(target_providers codex)"
assert_eq "providers gemini" "google" "$(target_providers gemini)"
assert_eq "providers duo" "gitlab" "$(target_providers duo)"
target_providers bogus >/dev/null 2>&1; assert_eq "providers unknown rc" "1" "$?"
# kiro is the multi-provider target; it must list more than one.
assert_eq "providers kiro is multi" "yes" \
    "$([[ "$(target_providers kiro | wc -l | tr -d ' ')" -gt 1 ]] && echo yes || echo no)"

# No model unless OUTSIDE_VOICE_MODEL is set, and then only for kiro.
assert_eq "reviewer model unset by default" "" "$(reviewer_model kiro anthropic)"
assert_eq "reviewer model env kiro" "foo" "$(OUTSIDE_VOICE_MODEL=foo reviewer_model kiro anthropic)"
for t in claude codex gemini duo opencode; do
    assert_eq "no model for $t" "" "$(OUTSIDE_VOICE_MODEL=foo reviewer_model "$t" anthropic)"
done

# gather_context in a temp git repo: dirty-only fallback on main
TMPREPO="$(mktemp -d)"; ( cd "$TMPREPO"
    git init -q; git config user.email t@e; git config user.name t
    echo hello > a.txt; git add a.txt; git commit -qm init
    echo changed >> a.txt )
# Array/scalar globals are set as explicit statements (not command prefixes),
# because array prefix assignment before a function call is invalid on bash 3.2.
ctx="$( cd "$TMPREPO"; PATHS=(); gather_context )"
assert_contains "context has diff" "changed" "$ctx"
assert_contains "context has stat" "a.txt" "$ctx"
rm -rf "$TMPREPO"

# empty scope returns 3
TMPCLEAN="$(mktemp -d)"; ( cd "$TMPCLEAN"
    git init -q; git config user.email t@e; git config user.name t
    echo x > a.txt; git add a.txt; git commit -qm init )
( cd "$TMPCLEAN"; PATHS=(); gather_context >/dev/null 2>&1 ); assert_eq "empty scope rc" "3" "$?"
rm -rf "$TMPCLEAN"

# --- base-ref resolution: committed work must be in review scope ------------
# Feature branch in a master-default repo. The old code required a *local*
# branch literally named `main`; without one it diffed only the working tree,
# so every committed change was invisible to the reviewer.
TMPMASTER="$(mktemp -d)"; ( cd "$TMPMASTER"
    git init -q; git symbolic-ref HEAD refs/heads/master
    git config user.email t@e; git config user.name t
    echo base > a.txt; echo base > b.txt; git add a.txt b.txt; git commit -qm init
    git checkout -q -b feature
    echo committed-on-feature >> a.txt; git commit -qam work ) >/dev/null 2>&1
ctxm="$( cd "$TMPMASTER"; PATHS=(); BASE_OVERRIDE=''; gather_context )"
assert_contains "master-default sees committed work" "committed-on-feature" "$ctxm"
assert_eq "base_ref picks master" "master" "$( cd "$TMPMASTER"; BASE_OVERRIDE=''; base_ref )"
# Explicit paths must narrow the scope, not drop committed work from it.
ctxp="$( cd "$TMPMASTER"; PATHS=(a.txt); BASE_OVERRIDE=''; gather_context )"
assert_contains "paths scope keeps committed work" "committed-on-feature" "$ctxp"
( cd "$TMPMASTER"; PATHS=(b.txt); BASE_OVERRIDE=''; gather_context >/dev/null 2>&1 )
assert_eq "paths scope still filters" "3" "$?"
# --base short-circuits resolution.
assert_eq "base_ref honors override" "HEAD~1" "$( cd "$TMPMASTER"; BASE_OVERRIDE='HEAD~1'; base_ref )"
rm -rf "$TMPMASTER"

# On the default branch itself, committed-but-unpushed work compares against
# the remote counterpart instead of yielding an empty range.
TMPBARE="$(mktemp -d)"; TMPCLONE="$(mktemp -d)"
git init -q --bare "$TMPBARE/origin.git"
( cd "$TMPCLONE"
    git init -q; git symbolic-ref HEAD refs/heads/master
    git config user.email t@e; git config user.name t
    echo base > a.txt; git add a.txt; git commit -qm init
    git remote add origin "$TMPBARE/origin.git"; git push -q -u origin master
    echo unpushed-line >> a.txt; git commit -qam more ) >/dev/null 2>&1
assert_eq "base_ref uses remote on default branch" "origin/master" \
    "$( cd "$TMPCLONE"; BASE_OVERRIDE=''; base_ref )"
ctxu="$( cd "$TMPCLONE"; PATHS=(); BASE_OVERRIDE=''; gather_context )"
assert_contains "unpushed work on default branch" "unpushed-line" "$ctxu"
rm -rf "$TMPBARE" "$TMPCLONE"

# No default branch and no remote: base_ref declines, dirty-only scope still works.
TMPORPHAN="$(mktemp -d)"; ( cd "$TMPORPHAN"
    git init -q; git symbolic-ref HEAD refs/heads/trunk
    git config user.email t@e; git config user.name t
    echo x > a.txt; git add a.txt; git commit -qm init; echo dirty-only >> a.txt ) >/dev/null 2>&1
( cd "$TMPORPHAN"; BASE_OVERRIDE=''; base_ref >/dev/null 2>&1 ); assert_eq "base_ref no candidate rc" "1" "$?"
ctxo="$( cd "$TMPORPHAN"; PATHS=(); BASE_OVERRIDE=''; gather_context )"
assert_contains "no-base falls back to dirty diff" "dirty-only" "$ctxo"
rm -rf "$TMPORPHAN"

export HOME="$USER_HOME_BACKUP"
rm -rf "$TMPHOME_T3"

# compose_prompt carries the read-only guardrail and both sections
p="$(compose_prompt "check the auth change" "DIFFBODY")"
assert_contains "prompt read-only" "Do not modify" "$p"
assert_contains "prompt instruction" "check the auth change" "$p"
assert_contains "prompt context" "DIFFBODY" "$p"

# run_with_timeout kills a hanging command (rc 124)
run_with_timeout 1 sleep 5 >/dev/null 2>&1; assert_eq "timeout rc" "124" "$?"

# The manual-watcher fallback (no timeout/gtimeout on PATH) must pass stdin through:
# bash 3.2 gives a backgrounded job /dev/null stdin unless it is redirected explicitly.
FBBIN="$(mktemp -d)"
for b in cat sleep; do ln -s "$(command -v "$b")" "$FBBIN/$b"; done
assert_eq "fallback path has no timeout binary" "" "$(PATH="$FBBIN"; command -v timeout gtimeout)"
fb_out="$(PATH="$FBBIN"; printf hello | run_with_timeout 3 cat)"
assert_eq "fallback run_with_timeout preserves stdin" "hello" "$fb_out"
rm -rf "$FBBIN"

# frame_target on success shows header + stdout, hides stderr
out="$(frame_target claude "LGTM" "noise" 0)"
assert_contains "frame header" "claude" "$out"
assert_contains "frame stdout" "LGTM" "$out"
assert_eq "frame hides stderr on success" "0" "$(printf '%s' "$out" | grep -c noise | tr -d ' ')"

# frame_target on failure surfaces stderr + warning
outf="$(frame_target gemini "" "boom-auth-error" 1)"
assert_contains "frame failure warn" "⚠" "$outf"
assert_contains "frame failure stderr" "boom-auth-error" "$outf"

# output cap: default 800 truncates; omitted count pins the boundary.
long="$(seq 1 1000)"
capped="$(frame_target codex "$long" "" 0)"
assert_contains "output cap notice" "reviewer output truncated" "$capped"
assert_contains "output cap boundary 800" "200 lines omitted" "$capped"
uncapped="$(OUTSIDE_VOICE_OUTPUT_CAP=1500 frame_target codex "$long" "" 0)"
assert_eq "raised cap no truncation" "0" "$(printf '%s' "$uncapped" | grep -c 'reviewer output truncated' | tr -d ' ')"

# Make the stub CLIs echo a per-tool marker so we can see who ran.
for c in claude gemini codex opencode kiro-cli glab; do
    printf '#!/usr/bin/env bash\necho "REVIEW-FROM-%s"\ncat >/dev/null 2>&1 || true\n' "$c" > "$STUBDIR/$c"
    chmod +x "$STUBDIR/$c"
done

# In a dirty temp repo, single target runs immediately and is framed.
TR="$(mktemp -d)"; ( cd "$TR"; git init -q; git config user.email t@e; git config user.name t
    echo a > f; git add f; git commit -qm init; echo b >> f )
single="$(cd "$TR" && bash "$SCRIPT" claude "review")"
assert_contains "single runs" "REVIEW-FROM-claude" "$single"
assert_contains "single framed" "═══ claude ═══" "$single"

# Multi target without --yes shows preview and does NOT run.
preview="$(cd "$TR" && bash "$SCRIPT" claude,gemini "review")"
assert_contains "preview count" "2 paid reviewer runs" "$preview"
assert_eq "preview did not run" "0" "$(printf '%s' "$preview" | grep -c REVIEW-FROM | tr -d ' ')"

# Multi target with --yes runs both, framed in priority order.
ran="$(cd "$TR" && bash "$SCRIPT" --yes gemini,claude "review")"
assert_contains "yes ran claude" "REVIEW-FROM-claude" "$ran"
assert_contains "yes ran gemini" "REVIEW-FROM-gemini" "$ran"
# claude header precedes gemini header (priority order, not input order)
assert_eq "priority order" "claude" "$(printf '%s\n' "$ran" | grep -oE 'claude|gemini' | head -1)"

# `all` is not capped: every installed target is previewed
allprev="$(cd "$TR" && bash "$SCRIPT" all "review")"
assert_contains "all not capped" "6 paid reviewer runs" "$allprev"

# Explicitly-named uninstalled target => warning, batch still runs the rest.
mv "$STUBDIR/codex" "$STUBDIR/codex.bak"
# Restrict PATH to the stub dir + bare POSIX utils for this one invocation: on a
# dev machine with the real `codex` CLI installed, removing only the stub would
# otherwise fall through to the real (paid, network-calling) binary. Keep
# timeout/gtimeout/bash reachable via a small symlink dir so run_with_timeout
# still uses its primary `timeout` path instead of the slower manual-watcher
# fallback.
SAFEBIN="$(mktemp -d)"
for b in timeout gtimeout bash; do
    p="$(command -v "$b" 2>/dev/null)" && ln -s "$p" "$SAFEBIN/$b"
done
unavail="$(cd "$TR" && PATH="$STUBDIR:$SAFEBIN:/usr/bin:/bin" bash "$SCRIPT" --yes claude,codex "review" 2>&1)"
rm -rf "$SAFEBIN"
assert_contains "unavailable notice" "codex unavailable" "$unavail"
assert_contains "unavailable still ran claude" "REVIEW-FROM-claude" "$unavail"
mv "$STUBDIR/codex.bak" "$STUBDIR/codex"

# A spaced comma list must not warn about a target that is installed and ran.
spaced="$(cd "$TR" && bash "$SCRIPT" --yes "claude, gemini" "review" 2>&1)"
assert_eq "spaced list: no false unavailable warning" "0" "$(printf '%s' "$spaced" | grep -c 'unavailable' | tr -d ' ')"
assert_contains "spaced list: gemini ran" "REVIEW-FROM-gemini" "$spaced"

# Parallel mode buffers per-target: claude block precedes gemini block, no interleave.
paral="$(cd "$TR" && bash "$SCRIPT" --parallel --yes claude,gemini "review")"
cl="$(printf '%s\n' "$paral" | grep -n '═══ claude ═══' | head -1 | cut -d: -f1)"
gl="$(printf '%s\n' "$paral" | grep -n '═══ gemini ═══' | head -1 | cut -d: -f1)"
assert_eq "parallel order not interleaved" "yes" "$([[ -n "$cl" && -n "$gl" && "$cl" -lt "$gl" ]] && echo yes || echo no)"

# Timeout in a batch: a hanging target is reported timed out; the batch continues.
printf '#!/usr/bin/env bash\nsleep 5\n' > "$STUBDIR/claude"; chmod +x "$STUBDIR/claude"
tob="$(cd "$TR" && bash "$SCRIPT" --yes --timeout 1 claude,gemini "review")"
assert_contains "batch timeout notice" "claude timed out" "$tob"
assert_contains "batch continues after timeout" "REVIEW-FROM-gemini" "$tob"
printf '#!/usr/bin/env bash\necho "REVIEW-FROM-claude"\ncat >/dev/null 2>&1 || true\n' > "$STUBDIR/claude"; chmod +x "$STUBDIR/claude"

# --- model selection reaches the command line ------------------------------
# Every invocation below redirects </dev/null. No existing test runs kiro, and
# unlike the claude branch (which pipes the prompt to stdin) the kiro branch
# passes it positionally — so the stub's `cat` has no producer and would read
# the terminal, hanging until the timeout kills it.
# The stub advertises --effort in its help text, like current kiro-cli builds.
printf '#!/usr/bin/env bash\nif [[ "$*" == *--help* ]]; then echo "      --effort <EFFORT>"; exit 0; fi\necho "ARGV: $*"\ncat >/dev/null 2>&1 || true\n' > "$STUBDIR/kiro-cli"
chmod +x "$STUBDIR/kiro-cli"

mk="$(cd "$TR" && OUTSIDE_VOICE_MODEL=foo OUTSIDE_VOICE_EFFORT=high bash "$SCRIPT" kiro "review" </dev/null)"
assert_contains "kiro gets model flag" "--model foo" "$mk"
assert_contains "kiro gets effort flag" "--effort high" "$mk"
mkp="$(cd "$TR" && bash "$SCRIPT" --avoid openai kiro "review" </dev/null)"
assert_eq "kiro unpinned by default" "0" "$(printf '%s' "$mkp" | grep -c -- '--model' | tr -d ' ')"
assert_eq "no effort by default" "0" "$(printf '%s' "$mkp" | grep -c -- '--effort' | tr -d ' ')"
# A kiro-cli whose help lacks --effort must not receive it.
printf '#!/usr/bin/env bash\nif [[ "$*" == *--help* ]]; then echo "      --model <MODEL>"; exit 0; fi\necho "ARGV: $*"\ncat >/dev/null 2>&1 || true\n' > "$STUBDIR/kiro-cli"
mko="$(cd "$TR" && OUTSIDE_VOICE_MODEL=foo OUTSIDE_VOICE_EFFORT=high bash "$SCRIPT" kiro "review" </dev/null)"
assert_eq "no effort when kiro-cli lacks it" "0" "$(printf '%s' "$mko" | grep -c -- '--effort' | tr -d ' ')"
assert_contains "old kiro-cli still gets model flag" "--model foo" "$mko"
# The pre-feature flags are still present in both cases.
assert_contains "kiro keeps trust-tools" "--trust-tools=fs_read" "$mk"
assert_contains "kiro keeps no-interactive" "--no-interactive" "$mkp"

# A fixed-provider target's command line is untouched by model selection.
printf '#!/usr/bin/env bash\necho "ARGV: $*"\ncat >/dev/null 2>&1 || true\n' > "$STUBDIR/claude"
chmod +x "$STUBDIR/claude"
ck="$(cd "$TR" && bash "$SCRIPT" --avoid openai claude "review" </dev/null)"
assert_eq "claude never gets a model flag" "0" "$(printf '%s' "$ck" | grep -c -- '--model' | tr -d ' ')"
printf '#!/usr/bin/env bash\necho "REVIEW-FROM-claude"\ncat >/dev/null 2>&1 || true\n' > "$STUBDIR/claude"
chmod +x "$STUBDIR/claude"
printf '#!/usr/bin/env bash\necho "REVIEW-FROM-kiro-cli"\ncat >/dev/null 2>&1 || true\n' > "$STUBDIR/kiro-cli"
chmod +x "$STUBDIR/kiro-cli"

# --- collision warning -----------------------------------------------------
# A fixed-provider target matching the avoided provider is flagged, not blocked.
cw="$(cd "$TR" && bash "$SCRIPT" --avoid anthropic claude "review" </dev/null 2>&1)"
assert_contains "collision warns for claude" "shares the caller" "$cw"
assert_contains "collision names provider" "anthropic" "$cw"
assert_contains "collision does not block" "REVIEW-FROM-claude" "$cw"
# A multi-provider target's provider list is newline-joined (e.g.
# "anthropic\nopenai\n..."), which can never string-match a bare provider
# token like $avoid — so kiro is never flagged, regardless of which single
# provider is being avoided.
kw="$(cd "$TR" && bash "$SCRIPT" --avoid anthropic kiro "review" </dev/null 2>&1)"
assert_eq "kiro's multi-line provider list never string-matches avoid" "0" \
    "$(printf '%s' "$kw" | grep -c 'shares the caller' | tr -d ' ')"
# A fixed-provider target that differs from the caller is not flagged.
nw="$(cd "$TR" && bash "$SCRIPT" --avoid openai claude "review" </dev/null 2>&1)"
assert_eq "no warning when providers differ" "0" \
    "$(printf '%s' "$nw" | grep -c 'shares the caller' | tr -d ' ')"
# An unidentified caller produces no warning at all, rather than a nonsensical
# "shares the caller's provider (unknown)".
uw="$(cd "$TR" && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CODEX_HOME -u CODEX_SANDBOX \
    -u GEMINI_API_KEY -u GEMINI_CLI OPENCODE_BIN=/tmp/oc \
    bash "$SCRIPT" opencode "review" </dev/null 2>&1)"
assert_eq "no warning for unknown caller" "0" \
    "$(printf '%s' "$uw" | grep -c 'shares the caller' | tr -d ' ')"
# ...but the batch's diversity guarantee going unenforced is not silent: the
# unidentified-caller notice must still appear.
assert_contains "unidentified caller notice appears" "provider unidentified" "$uw"

rm -rf "$TR"

# A value-taking flag given with no value exits cleanly (64), not an
# unbound-variable crash under set -u.
for flag in --timeout --base --avoid; do
    mv_out="$(bash "$SCRIPT" "$flag" 2>&1)"; mv_rc=$?
    assert_eq "missing-value exit 64 ($flag)" "64" "$mv_rc"
    assert_eq "missing-value no crash ($flag)" "0" "$(printf '%s' "$mv_out" | grep -c 'unbound variable' | tr -d ' ')"
done

# --base with an unresolvable ref fails fast rather than silently reviewing nothing.
TMPBASE="$(mktemp -d)"; ( cd "$TMPBASE"
    git init -q; git config user.email t@e; git config user.name t
    echo x > a.txt; git add a.txt; git commit -qm init; echo y >> a.txt ) >/dev/null 2>&1
bb_out="$(cd "$TMPBASE" && bash "$SCRIPT" --base no-such-ref claude "review" 2>&1)"; bb_rc=$?
assert_eq "bogus --base exit 64" "64" "$bb_rc"
assert_contains "bogus --base message" "no-such-ref" "$bb_out"
rm -rf "$TMPBASE"

# --avoid rejects a provider name that isn't in the known list.
TMPAV="$(mktemp -d)"; ( cd "$TMPAV"
    git init -q; git config user.email t@e; git config user.name t
    echo x > a.txt; git add a.txt; git commit -qm init; echo y >> a.txt ) >/dev/null 2>&1
av_out="$(cd "$TMPAV" && bash "$SCRIPT" --avoid nosuchprovider claude "review" 2>&1)"; av_rc=$?
assert_eq "bogus --avoid exit 64" "64" "$av_rc"
assert_contains "bogus --avoid lists valid" "anthropic" "$av_out"
# --avoid "" must not silently degrade to autodetect like every other invalid value.
ae_out="$(cd "$TMPAV" && bash "$SCRIPT" --avoid "" claude "review" 2>&1)"; ae_rc=$?
assert_eq "empty --avoid exit 64" "64" "$ae_rc"
assert_contains "empty --avoid message" "requires a value" "$ae_out"
rm -rf "$TMPAV"

# --- untracked/ignored path inclusion --------------------------------------
# Fixture: a repo ignoring docs/ and work/, holding an ignored spec, an ignored
# credential file, and an untracked loose file.
TMPUT="$(mktemp -d)"; ( cd "$TMPUT"
    git init -q; git config user.email t@e; git config user.name t
    printf 'docs/\nwork/\n' > .gitignore
    git add .gitignore; git commit -qm init
    mkdir -p docs work
    echo 'spec body' > docs/spec.md
    echo 'AWS_SECRET=hunter2' > work/creds.sh
    printf 'decoy\n' > 'work/*'
    echo 'loose body' > loose.txt
    echo 'spaced body' > 'has space.md'
    printf 'nl body\n' > "$(printf 'has\nnewline.md')" ) >/dev/null 2>&1

# The function must exist: an assert on empty output would otherwise pass for
# an undefined function too.
assert_eq "untracked_candidates is defined" "0" \
    "$(declare -f untracked_candidates >/dev/null 2>&1; echo $?)"

uc() { ( cd "$TMPUT"; PATHS=("$@"); untracked_candidates | tr '\0' '\n' ); }

# 1. Ignored file reachable by EXACT path.
assert_eq "ignored exact file included" "docs/spec.md" "$(uc docs/spec.md)"
# 2. Untracked-not-ignored file included.
assert_eq "untracked file included" "loose.txt" "$(uc loose.txt)"
# 3. SECURITY: a directory pathspec must not sweep ignored descendants.
#    Verified expected value: both untracked-not-ignored files, in ls-files
#    sort order, and neither ignored file.
# NOTE: ls-files sorts; the newline-named file sorts before 'has space.md'.
# Compare against a NUL-joined form so the newline in a filename cannot be
# confused with the separator between filenames.
ucz() { ( cd "$TMPUT"; PATHS=("$@"); untracked_candidates | tr '\0' '|' ); }
assert_eq "dir pathspec yields only untracked" \
    $'has\nnewline.md|has space.md|loose.txt|' "$(ucz .)"
assert_eq "ignored dir pathspec yields nothing" "" "$(uc docs/)"
# Belt and braces: the ignored credential file must not appear for ANY pathspec.
case "$(uc .)$(uc docs/)$(uc work/)" in
    *creds*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "ignored credential enumerated" ;;
    *) PASS=$((PASS+1)); printf '  ok  %s\n' "ignored credential never enumerated" ;;
esac
# 5. Overlapping and repeated pathspecs emit the file once.
assert_eq "overlapping paths emit once" "docs/spec.md" \
    "$(uc docs/ docs/spec.md docs/spec.md)"
# 5b. Same property for the NON-ignored enumeration, which is a separate
#     ls-files call: overlapping/repeated untracked pathspecs emit once.
assert_eq "overlapping untracked paths emit once" \
    $'has\nnewline.md|has space.md|loose.txt|' "$(ucz . loose.txt loose.txt)"
# 7a. A path containing a space is not split (quoting regression).
assert_eq "spaced path not split" "has space.md" "$(uc 'has space.md')"
# 7b. NUL-safety proper: a filename containing a NEWLINE survives as one path.
#     The space test cannot prove this — only a newline can distinguish
#     NUL-delimited reading from line-delimited reading.
assert_eq "newline path survives as one path" $'has\nnewline.md|' \
    "$(ucz "$(printf 'has\nnewline.md')")"
# 3b. SECURITY / P0: a file literally named `work/*` passes the -f gate, but
#     must NOT let git glob-expand it into its ignored siblings.
assert_eq "literal glob name cannot reach siblings" 'work/*|' "$(ucz 'work/*')"
# 3d. A glob pathspec still reaches UNTRACKED files, matching how the tracked
#     `git diff` treats pathspecs. Literal mode is applied only to the ignored
#     query, so this symmetry is preserved.
assert_eq "glob reaches untracked files" 'loose.txt|' "$(ucz '*.txt')"
# 3e. ...but a glob can never reach an IGNORED file, because the non-ignored
#     query excludes ignored paths regardless of what the pathspec matches.
assert_eq "glob cannot reach ignored files" "" "$(ucz '*creds*')"
# 3c. SECURITY: mixing an exact file with a directory pathspec must not let the
#     directory reach ignored files. Without this the mutation
#     `-- "${exact[@]}"` -> `-- "${PATHS[@]}"` on the ignored query goes
#     undetected, because the `${#exact[@]}` guard neutralizes it whenever
#     exact is empty (as it is for a bare `.`).
assert_eq "exact file plus dir does not sweep ignored" 'docs/spec.md|' \
    "$(ucz docs/spec.md work/)"
# Empty PATHS produces nothing at all — on stdout AND stderr. The stderr half
# is load-bearing: removing the PATHS guard makes bash 3.2 emit
# "PATHS[@]: unbound variable" under set -u with empty stdout, which an
# stdout-only assertion would happily pass.
assert_eq "no paths yields nothing" "" "$(uc)"
assert_eq "no paths is silent" "" "$( ( cd "$TMPUT"; PATHS=(); untracked_candidates ) 2>&1 >/dev/null )"

# gather_context now surfaces an explicitly passed ignored artifact.
ctxi="$( cd "$TMPUT"; PATHS=(docs/spec.md); BASE_OVERRIDE=''; gather_context 2>/dev/null )"
assert_contains "ignored artifact reaches context" "spec body" "$ctxi"
# 7c. NUL-safety through the SNAPSHOT. The `newline path survives as one path`
#     assertion above exercises untracked_candidates only; the NUL *reading*
#     happens in snapshot_candidates, so without this the reader is untested
#     and replacing `read -r -d ''` with `read -r` goes undetected there.
ctxn="$( cd "$TMPUT"; PATHS=("$(printf 'has\nnewline.md')"); BASE_OVERRIDE=''; gather_context 2>/dev/null )"
assert_contains "newline file reaches context via snapshot" "nl body" "$ctxn"
# ...and does NOT leak the credential file when '.' is passed.
ctxc="$( cd "$TMPUT"; PATHS=(.); BASE_OVERRIDE=''; gather_context 2>/dev/null )"
case "$ctxc" in
    *hunter2*|*creds*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "credential leak via '.' pathspec" ;;
    *) PASS=$((PASS+1)); printf '  ok  %s\n' "no credential leak via '.' pathspec" ;;
esac
rm -rf "$TMPUT"

# --- no-repo and unmatched-path notices ------------------------------------
assert_eq "warn_unmatched_paths is defined" "0" \
    "$(declare -f warn_unmatched_paths >/dev/null 2>&1; echo $?)"

# 9. Outside any git repository, an explicit file is still reviewable and no
#    git fatal reaches stderr.
TMPNR="$(mktemp -d)"; echo 'orphan body' > "$TMPNR/a.md"
nr_out="$( cd "$TMPNR"; PATHS=(a.md); BASE_OVERRIDE=''; gather_context 2>/dev/null )"
assert_contains "no-repo explicit path reviewed" "orphan body" "$nr_out"
nr_err="$( cd "$TMPNR"; PATHS=(a.md); BASE_OVERRIDE=''; gather_context 2>&1 >/dev/null )"
case "$nr_err" in
    *"not a git repository"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "no-repo git fatal leaked to stderr" ;;
    *) PASS=$((PASS+1)); printf '  ok  %s\n' "no-repo git fatal suppressed" ;;
esac
rm -rf "$TMPNR"

# 8. A path matching nothing is reported rather than swallowed.
TMPNM="$(mktemp -d)"; ( cd "$TMPNM"
    git init -q; git config user.email t@e; git config user.name t
    echo x > a.txt; git add a.txt; git commit -qm init; echo y >> a.txt ) >/dev/null 2>&1
nm_err="$( cd "$TMPNM"; PATHS=(nosuch.md); BASE_OVERRIDE=''; gather_context 2>&1 >/dev/null )"
assert_contains "unmatched path warns" "nosuch.md matched no file" "$nm_err"
# A path that DOES match must stay silent.
ok_err="$( cd "$TMPNM"; PATHS=(a.txt); BASE_OVERRIDE=''; gather_context 2>&1 >/dev/null )"
# An UNTRACKED-but-existing path must not warn either. The tracked case above is
# satisfied by the `git ls-files --error-unmatch` branch alone; only this case
# exercises the `[[ -e "$p" ]]` short-circuit, without which an untracked or
# ignored artifact is wrongly reported as "matched no file".
( cd "$TMPNM"; echo fresh > fresh.md ) >/dev/null 2>&1
fresh_err="$( cd "$TMPNM"; PATHS=(fresh.md); BASE_OVERRIDE=''; gather_context 2>&1 >/dev/null )"
case "$fresh_err" in
    *"matched no file"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "untracked existing path warned spuriously" ;;
    *) PASS=$((PASS+1)); printf '  ok  %s\n' "untracked existing path stays silent" ;;
esac
case "$ok_err" in
    *"matched no file"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "matched path warned spuriously" ;;
    *) PASS=$((PASS+1)); printf '  ok  %s\n' "matched path stays silent" ;;
esac
rm -rf "$TMPNM"

# --- regression guards -----------------------------------------------------
# Fixture with a committed change, an uncommitted change, an untracked file,
# and an ignored artifact.
TMPRG="$(mktemp -d)"; ( cd "$TMPRG"
    git init -q; git config user.email t@e; git config user.name t
    echo 'docs/' > .gitignore
    echo 'tracked v1' > tracked.txt
    git add .gitignore tracked.txt; git commit -qm init
    echo 'tracked v2' >> tracked.txt
    mkdir -p docs; echo 'ignored artifact body' > docs/spec.md
    echo 'stray' > stray.txt ) >/dev/null 2>&1

# 4. With no paths, output is byte-identical to the two pre-existing diff
#    sources alone. Reconstructed here rather than kept as a checked-in golden
#    file, which would drift on any unrelated formatting change.
# scoped_diff reads the CANDIDATES snapshot; set it explicitly here since we
# bypass gather_context (and therefore snapshot_candidates).
rg_actual="$( cd "$TMPRG"; PATHS=(); CANDIDATES=(); BASE_OVERRIDE=''; scoped_diff "" )"
rg_expect="$( cd "$TMPRG"; git diff HEAD 2>/dev/null || true )"
assert_eq "no-paths output unchanged" "$rg_expect" "$rg_actual"
# The untracked and ignored files must be absent from that output.
case "$rg_actual" in
    *stray*|*"ignored artifact body"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "no-paths output leaked untracked content" ;;
    *) PASS=$((PASS+1)); printf '  ok  %s\n' "no-paths output excludes untracked content" ;;
esac

# 6. Mixed review: tracked diff plus an explicitly supplied ignored artifact.
rg_mixed="$( cd "$TMPRG"; PATHS=(tracked.txt docs/spec.md); BASE_OVERRIDE=''; gather_context 2>/dev/null )"
assert_contains "mixed review has tracked change" "tracked v2" "$rg_mixed"
assert_contains "mixed review has ignored artifact" "ignored artifact body" "$rg_mixed"

# 10. The review must not touch the index. Exercised with a NON-ignored
#     untracked file: `git add -N` on an ignored path is refused by git and
#     leaves the index untouched, so an ignored-only fixture would let a
#     `git add -N` mutation slip through undetected (verified).
idx_before="$( cd "$TMPRG"; git status --porcelain )"
( cd "$TMPRG"; PATHS=(stray.txt docs/spec.md); BASE_OVERRIDE=''; gather_context ) >/dev/null 2>&1
idx_after="$( cd "$TMPRG"; git status --porcelain )"
assert_eq "index unmodified by review" "$idx_before" "$idx_after"
rm -rf "$TMPRG"

# --- dispatch transparency -------------------------------------------------
TMPAN="$(mktemp -d)"; ( cd "$TMPAN"
    git init -q; git config user.email t@e; git config user.name t
    echo 'docs/' > .gitignore; git add .gitignore; git commit -qm init
    mkdir -p docs; echo 'body' > docs/spec.md ) >/dev/null 2>&1
an_err="$( cd "$TMPAN"; PATHS=(docs/spec.md); BASE_OVERRIDE=''; gather_context 2>&1 >/dev/null )"
assert_contains "announces header" "including untracked/ignored files:" "$an_err"
assert_contains "announces the path" "docs/spec.md" "$an_err"
# With no untracked candidates, stay silent.
sil_err="$( cd "$TMPAN"; PATHS=(); BASE_OVERRIDE=''; gather_context 2>&1 >/dev/null )"
case "$sil_err" in
    *"including untracked"*) FAIL=$((FAIL+1)); printf '  FAIL %s\n' "announced with no candidates" ;;
    *) PASS=$((PASS+1)); printf '  ok  %s\n' "silent with no candidates" ;;
esac
rm -rf "$TMPAN"


# --- removed profile flag, target availability -----------------------------
pf_out="$(bash "$SCRIPT" --profile work claude "review" 2>&1)"; pf_rc=$?
assert_eq "profile flag rejected exit 64" "64" "$pf_rc"
assert_contains "profile flag named in error" "--profile" "$pf_out"

SAFEBIN="$(mktemp -d)"
for b in timeout gtimeout bash git; do
    p="$(command -v "$b" 2>/dev/null)" && ln -s "$p" "$SAFEBIN/$b"
done
EMPTYBIN="$(mktemp -d)"
nocli_out="$(PATH="$EMPTYBIN:$SAFEBIN:/usr/bin:/bin" bash "$SCRIPT" all "review" 2>&1)"; nocli_rc=$?
assert_eq "no CLI installed exit 69" "69" "$nocli_rc"
assert_contains "no CLI message" "no requested target CLIs are installed." "$nocli_out"

THREEBIN="$(mktemp -d)"
for c in claude gemini codex; do
    printf '#!/usr/bin/env bash\necho "REVIEW-FROM-%s"\n' "$c" > "$THREEBIN/$c"; chmod +x "$THREEBIN/$c"
done
TR3="$(mktemp -d)"; ( cd "$TR3"; git init -q; git config user.email t@e; git config user.name t
    echo a > f; git add f; git commit -qm init; echo b >> f )
three_out="$(cd "$TR3" && PATH="$THREEBIN:$SAFEBIN" bash "$SCRIPT" all "review" 2>&1)"
assert_contains "all not capped with 3 CLIs" "3 paid reviewer runs" "$three_out"
rm -rf "$SAFEBIN" "$EMPTYBIN" "$THREEBIN" "$TR3"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
