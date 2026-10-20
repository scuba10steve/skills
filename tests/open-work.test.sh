#!/usr/bin/env bash
# open-work.test.sh — assertions for open-work.sh
set -uo pipefail

SCRIPT_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )"
SCRIPT="$SCRIPT_DIR/../skills/open-work/scripts/open-work.sh"

REAL_HOME="$HOME"          # captured before the override; session discovery needs the real
                           # transcript store and process table
TMPHOME="$(mktemp -d "${TMPDIR:-/tmp}/open-work-test.XXXXXX")"
export HOME="$TMPHOME"
unset XDG_CONFIG_HOME
trap 'rm -rf "$TMPHOME"' EXIT

PASS=0
FAIL=0
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
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then PASS=$((PASS+1)); printf '  ok  %s\n' "$label"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n    needle should not appear: %q\n    haystack: %q\n' "$label" "$needle" "$haystack"; fi
}

echo "skeleton"
out=$("$BASH" "$SCRIPT" --help 2>&1); rc=$?
assert_eq "--help exits 0" 0 "$rc"
assert_contains "--help shows usage" "Usage:" "$out"

rc=0; out=$("$BASH" "$SCRIPT" --bogus 2>&1) || rc=$?
assert_eq "unknown flag exits 1" 1 "$rc"
assert_contains "unknown flag explains itself" "Unknown" "$out"

# Library mode: functions are callable after sourcing.
out=$(OPEN_WORK_LIB=1 "$BASH" -c 'source "$1"; open_work_usage' _ "$SCRIPT" 2>&1)
assert_contains "library mode exposes callable functions" "Usage:" "$out"

# Library mode: sourcing does not dispatch.
out=$(OPEN_WORK_LIB=1 "$BASH" -c 'source "$1"' _ "$SCRIPT" 2>&1)
assert_not_contains "library mode does not dispatch" '"sessions"' "$out"

echo "normalize_repo_id"
OPEN_WORK_LIB=1 source "$SCRIPT"

assert_eq "https strips .git" \
  "gitlab.com/example-org/group-a/repo-one" \
  "$(normalize_repo_id 'https://gitlab.com/example-org/group-a/repo-one.git')"
assert_eq "https without .git unchanged" \
  "gitlab.com/example-org/repo-two" \
  "$(normalize_repo_id 'https://gitlab.com/example-org/repo-two')"
assert_eq "github https" \
  "github.com/example-user/widget" \
  "$(normalize_repo_id 'https://github.com/example-user/widget')"
assert_eq "deep subgroup preserved" \
  "gitlab.com/example-org/group-a/subgroup-b/repo-three" \
  "$(normalize_repo_id 'https://gitlab.com/example-org/group-a/subgroup-b/repo-three.git')"
assert_eq "ssh scp form" \
  "gitlab.com/example-org/group-c/repo-four" \
  "$(normalize_repo_id 'git@gitlab.com:example-org/group-c/repo-four.git')"
assert_eq "ssh:// form" \
  "gitlab.com/example-org/group-c/repo-four" \
  "$(normalize_repo_id 'ssh://git@gitlab.com/example-org/group-c/repo-four.git')"
assert_eq "unparseable yields empty" "" "$(normalize_repo_id 'file:///tmp/whatever')"
assert_eq "empty input yields empty" "" "$(normalize_repo_id '')"
assert_eq "https with credentials and port" \
  "gitlab.com/group/repo" \
  "$(normalize_repo_id 'https://user:pass@gitlab.com:8443/group/repo.git')"
assert_eq "ssh:// with port" \
  "gitlab.com/group/repo" \
  "$(normalize_repo_id 'ssh://git@gitlab.com:2222/group/repo.git')"
assert_eq "trailing slashes stripped" \
  "gitlab.com/group/repo" \
  "$(normalize_repo_id 'git@gitlab.com:group/repo.git/')"
assert_eq "multiple trailing slashes stripped" \
  "gitlab.com/group/repo" \
  "$(normalize_repo_id 'https://gitlab.com/group/repo///')"

echo "last_conversation_ts"
# A transcript whose LAST record is an untimestamped mode record (the real trap),
# with the newest real conversation 30 days old. mtime says "now"; the answer is 30d.
proj="$HOME/.claude/projects/-Users-demo-code-widget"
mkdir -p "$proj"
old_ts="$(date -u -v-30d +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%S.000Z)"
{
  printf '{"type":"user","timestamp":"%s","x":1}\n' "$old_ts"
  printf '{"type":"assistant","timestamp":"%s","x":2}\n' "$old_ts"
  printf '{"type":"file-history-snapshot","x":3}\n'
  printf '{"type":"mode","mode":"default"}\n'
  printf '{"type":"system","subtype":"x"}\n'
} > "$proj/session-a.jsonl"

assert_eq "ignores untimestamped trailing records" "$old_ts" "$(last_conversation_ts /Users/demo/code/widget)"

# A second, newer transcript in the same dir must win (dirs accumulate dead sessions).
new_ts="$(date -u -v-2H +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%S.000Z)"
printf '{"type":"user","timestamp":"%s","x":9}\n' "$new_ts" > "$proj/session-b.jsonl"
assert_eq "newest conversation across files wins" "$new_ts" "$(last_conversation_ts /Users/demo/code/widget)"

# Worktree paths: '/' and '.' both collapse to '-'.
wt="$HOME/.claude/projects/-Users-demo-code-widget--worktrees-featbranch"
mkdir -p "$wt"
printf '{"type":"user","timestamp":"%s","x":1}\n' "$old_ts" > "$wt/s.jsonl"
assert_eq "worktree slug resolves" "$old_ts" "$(last_conversation_ts '/Users/demo/code/widget/.worktrees/featbranch')"

# No project dir at all -> non-zero exit, empty stdout.
rc=0; out=$(last_conversation_ts /Users/demo/nope) || rc=$?
assert_eq "missing project dir exits non-zero" 1 "$rc"
assert_eq "missing project dir prints nothing" "" "$out"

# Malformed JSONL must not abort the run (it would under set -euo pipefail).
proj3="$HOME/.claude/projects/-Users-demo-code-broken"
mkdir -p "$proj3"
{ printf '{"type":"user","timestamp":"%s"}\n' "$old_ts"; printf 'this is not json at all\n'; } > "$proj3/s.jsonl"
rc=0; out=$("$BASH" -c 'set -euo pipefail; OPEN_WORK_LIB=1 source "$1"; last_conversation_ts /Users/demo/code/broken' _ "$SCRIPT") || rc=$?
assert_eq "malformed JSONL still yields the good timestamp" "$old_ts" "$out"
assert_eq "malformed JSONL does not abort under set -e" 0 "$rc"

# Negative control: a transcript with ONLY untimestamped records must not report a time.
proj2="$HOME/.claude/projects/-Users-demo-code-empty"
mkdir -p "$proj2"; printf '{"type":"mode","mode":"default"}\n' > "$proj2/s.jsonl"
rc=0; out=$(last_conversation_ts /Users/demo/code/empty) || rc=$?
assert_eq "only-untimestamped exits non-zero" 1 "$rc"
assert_eq "only-untimestamped prints nothing" "" "$out"

# Finding 1: tail -n 800 bound is load-bearing. More than 800 untimestamped records
# after the last user/assistant record must cause non-zero return (unknown), not a wrong
# timestamp from earlier in the file.
proj_bound="$HOME/.claude/projects/-Users-demo-code-overflow"
mkdir -p "$proj_bound"
{
  printf '{"type":"user","timestamp":"%s","x":1}\n' "$old_ts"
  for i in {1..850}; do printf '{"type":"mode","mode":"default"}\n'; done
} > "$proj_bound/s.jsonl"
rc=0; out=$(last_conversation_ts /Users/demo/code/overflow) || rc=$?
assert_eq ">800 untimestamped lines after last user returns non-zero" 1 "$rc"
assert_eq "overflow case prints nothing" "" "$out"

# Finding 2: Type filter correctly ignores timestamped non-user/non-assistant records.
# A newer system record with a timestamp must not override an older user record.
proj_type="$HOME/.claude/projects/-Users-demo-code-typefilt"
mkdir -p "$proj_type"
system_ts="$(date -u -v-1H +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000Z)"
{
  printf '{"type":"user","timestamp":"%s","x":1}\n' "$old_ts"
  printf '{"type":"system","timestamp":"%s","event":"some-event"}\n' "$system_ts"
} > "$proj_type/s.jsonl"
rc=0; out=$(last_conversation_ts /Users/demo/code/typefilt) || rc=$?
assert_eq "older user timestamp chosen over newer system timestamp" "$old_ts" "$out"
assert_eq "type filter works" 0 "$rc"

echo "collect_sessions"
# collect_sessions returns {sessions, errors} so a discovery failure has somewhere
# to go. Unwrap the array here; the error channel is asserted below.
sess_doc=$(HOME="$REAL_HOME" collect_sessions 2>/dev/null)
assert_eq "emits an object with a sessions key and an errors key" "true" \
  "$(printf '%s' "$sess_doc" | jq 'has("sessions") and has("errors")')"
sess=$(printf '%s' "$sess_doc" | jq -c '.sessions')
assert_eq ".sessions is a JSON array" "array" "$(printf '%s' "$sess" | jq -r 'type')"

# PRECONDITION: every assertion below uses all(...) or a filtered count, and
# `jq 'all(...)'` on [] is *true*. Without this guard a collect_sessions that
# always returns [] passes the entire task. Verified: `echo '[]' | jq
# 'all(has("pid"))'` -> true.
n_sess=$(printf '%s' "$sess" | jq 'length')
if (( n_sess == 0 )); then
    printf '  SKIP no live agent sessions on this host — session shape unverified here.\n'
else
    PASS=$((PASS+1)); printf '  ok  found %s live session(s) to validate\n' "$n_sess"
assert_eq "observer sessions excluded" "0" \
  "$(printf '%s' "$sess" | jq '[.[] | select(.cwd | test("observer-sessions"))] | length')"
assert_eq "every entry has required keys" "true" \
  "$(printf '%s' "$sess" | jq 'all(has("pid") and has("cwd") and has("repo_id") and has("branch") and has("idle_seconds") and has("agent") and has("root") and has("tty"))')"
assert_eq "idle is number or null" "true" \
  "$(printf '%s' "$sess" | jq 'all(.idle_seconds == null or (.idle_seconds|type) == "number")')"
# Root resolution check: git rev-parse --show-toplevel must resolve subdirectories.
# Count sessions where root != cwd and root != "". If any exist, assert they start
# with the root. If none exist, print SKIP — we have no subdirectory sessions to
# validate the git resolution actually worked.
n_subdir=$(printf '%s' "$sess" | jq '[.[] | select(.root != .cwd and .root != "")] | length')
if (( n_subdir > 0 )); then
    assert_eq "subdirectory sessions resolve to parent root" "true" \
      "$(printf '%s' "$sess" | jq 'all(select(.root != .cwd and .root != "") as $obj | ($obj.cwd | startswith($obj.root)))')"
else
    printf '  SKIP no subdirectory sessions found — root resolution unverified here.\n'
    printf '       All live sessions have cwd == root; git rev-parse --show-toplevel\n'
    printf '       is unexercised. To exercise this path, start an agent in a subdirectory\n'
    printf '       of a git repo (not the root) and re-run.\n'
fi
# `all(select(...))` over zero matching elements is TRUE, so this assertion is
# vacuous on a machine running only Claude sessions. Report that honestly
# instead of banking a free pass.
n_other=$(printf '%s' "$sess" | jq '[.[] | select(.agent != "claude")] | length')
if (( n_other > 0 )); then
    assert_eq "non-claude agents have null idle" "true" \
      "$(printf '%s' "$sess" | jq 'all(select(.agent != "claude") | .idle_seconds == null)')"
else
    printf '  SKIP no non-claude sessions running — collector rule unverified here.\n'
    printf '       Shape-level handling is covered by the shape tests; to exercise this path,\n'
    printf '       start a codex/opencode session in a git repo and re-run.\n'
fi
# Idle_seconds provenance check: for Claude sessions, cross-check the stored
# idle_seconds against a fresh last_conversation_ts call. An implementation that
# used process age instead would diverge visibly. Allow a few seconds tolerance
# since the two are computed at different moments.
n_claude_idle=$(printf '%s' "$sess" | jq '[.[] | select(.agent == "claude" and .idle_seconds != null)] | length')
if (( n_claude_idle > 0 )); then
    # For each claude session with idle_seconds, recompute idle from last_conversation_ts
    # and verify the stored value is within a few seconds.
    # Key by pid (unique per session) not cwd (can be shared by multiple sessions).
    check_idle=$(printf '%s' "$sess" | jq -r '.[] | select(.agent == "claude" and .idle_seconds != null) | [.pid, .cwd] | @tsv' | while read pid cwd; do
        now=$(date -u +%s)
        if ts=$(OPEN_WORK_LIB=1 "$BASH" -c 'source tools/open-work.sh; last_conversation_ts "$1"' _ "$cwd" 2>/dev/null); then
            epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${ts%%.*}" +%s 2>/dev/null \
                    || date -u -d "${ts}" +%s 2>/dev/null || echo "")
            if [[ -n "$epoch" ]]; then
                recomputed_idle=$(( now - epoch ))
                stored_idle=$(printf '%s' "$sess" | jq -r ".[] | select(.pid == $pid) | .idle_seconds")
                diff=$(( stored_idle - recomputed_idle ))
                # Allow 5-second tolerance for drift between collection time and recomputation
                if (( diff < -5 || diff > 5 )); then
                    printf 'false'
                    break
                fi
            fi
        fi
    done)
    if [[ "$check_idle" != "false" ]]; then
        PASS=$((PASS+1)); printf '  ok  idle_seconds provenance verified against last_conversation_ts\n'
    else
        FAIL=$((FAIL+1)); printf '  FAIL idle_seconds diverges from last_conversation_ts (possible process-age substitution)\n'
    fi
else
    printf '  SKIP no claude sessions with non-null idle_seconds — provenance unverified here.\n'
    printf '       All claude sessions lack transcript data; process-age substitution would\n'
    printf '       not be detectable. To exercise this path, conduct extended agent work\n'
    printf '       in a git repo and re-run.\n'
fi
fi

# Session discovery must have an error channel. A broken pgrep, a
# missing pgrep and a failing lsof each produce an empty session list, which is
# indistinguishable from "no agents are running" — every item renders
# `○ no session` and Stale shows 0. These assertions cover rule 1 (no pgrep),
# rule 2 (pgrep exit >1), rule 3 (pids found, no cwds resolved) and the healthy
# case. Each stub shadows exactly one tool on PATH so the rest of the collector
# runs for real. Every probe dispatches collect_sessions as a bare command under
# `set -euo pipefail`, not inside a command substitution: that is the form that
# catches an abort.
host_sess_err="$(printf '%s' "$sess_doc" | jq -r '.errors.sessions // "null"')"
if [[ "$host_sess_err" == *"not found"* ]]; then
    printf '  SKIP host lacks a session-discovery tool (%s)\n' "$host_sess_err"
else
    assert_eq "healthy pgrep reports no session error" "null" "$host_sess_err"
fi

pgrep_stub="$TMPHOME/pgrep_stub"; mkdir -p "$pgrep_stub"
printf '#!/bin/sh\necho "pgrep: broken" >&2\nexit 2\n' > "$pgrep_stub/pgrep"
chmod +x "$pgrep_stub/pgrep"
sess_err=$(PATH="$pgrep_stub:$PATH" HOME="$REAL_HOME" "$BASH" -c '
  set -euo pipefail; OPEN_WORK_LIB=1 . "$1"; collect_sessions' _ "$SCRIPT" 2>/dev/null || echo '{}')
assert_contains "broken pgrep is reported, not silent" "pgrep failed" \
  "$(printf '%s' "$sess_err" | jq -r '.errors.sessions // ""')"

# Rule 1: no pgrep on PATH at all. The early return runs before anything else,
# so a PATH holding only jq is enough to produce the document.
nopgrep_bin="$TMPHOME/nopgrep_bin"; mkdir -p "$nopgrep_bin"
ln -sf "$(command -v jq)" "$nopgrep_bin/jq"
sess_nop=$(PATH="$nopgrep_bin" HOME="$REAL_HOME" "$BASH" -c '
  set -euo pipefail; OPEN_WORK_LIB=1 . "$1"; collect_sessions' _ "$SCRIPT" 2>/dev/null || echo '{}')
assert_contains "missing pgrep is reported" "pgrep not found" \
  "$(printf '%s' "$sess_nop" | jq -r '.errors.sessions // ""')"

# Tool-absence guards: build a PATH dir holding only the named tools.
mkpath() {
    local d; d="$(mktemp -d "$TMPHOME/path.XXXXXX")"
    local t
    for t in "$@"; do ln -sf "$(command -v "$t")" "$d/$t"; done
    printf '%s' "$d"
}
run_sessions_with_path() {
    PATH="$1" HOME="$REAL_HOME" "$BASH" -c '
      set -euo pipefail; OPEN_WORK_LIB=1 . "$1"; collect_sessions' _ "$SCRIPT" 2>/dev/null || echo '{}'
}
stub_pgrep() { printf '#!/bin/sh\necho 424242\n' > "$1/pgrep"; chmod +x "$1/pgrep"; }
stub_lsof() { printf '#!/bin/sh\necho "n/tmp"\n' > "$1/lsof"; chmod +x "$1/lsof"; }

p_none="$(mkpath jq)"
out=$(run_sessions_with_path "$p_none")
assert_eq "no pgrep: sessions empty" "0" "$(printf '%s' "$out" | jq '.sessions | length')"
assert_contains "test_sessions_unavailable_without_tools" "pgrep not found" \
  "$(printf '%s' "$out" | jq -r '.errors.sessions // ""')"

p_nolsof="$(mkpath jq)"; stub_pgrep "$p_nolsof"
out=$(run_sessions_with_path "$p_nolsof")
assert_eq "no lsof: sessions empty" "0" "$(printf '%s' "$out" | jq '.sessions | length')"
assert_contains "test_sessions_unavailable_without_lsof" "lsof not found" \
  "$(printf '%s' "$out" | jq -r '.errors.sessions // ""')"

p_nops="$(mkpath jq)"; stub_pgrep "$p_nops"; stub_lsof "$p_nops"
out=$(run_sessions_with_path "$p_nops")
assert_eq "no ps: sessions empty" "0" "$(printf '%s' "$out" | jq '.sessions | length')"
assert_contains "test_sessions_unavailable_without_ps" "ps not found" \
  "$(printf '%s' "$out" | jq -r '.errors.sessions // ""')"

# No ~/.claude/projects: transcript matching is skipped silently, not an error.
nohome="$TMPHOME/nohome"; mkdir -p "$nohome"
assert_eq "absent ~/.claude/projects yields no last_conversation_ts" "1" \
  "$(HOME="$nohome" last_conversation_ts /tmp/x >/dev/null 2>&1; echo $?)"

# Rule 3: pgrep finds processes but lsof resolves no working directory. A
# per-pid miss is a race and stays silent; zero out of N is a tool failure.
lsof_stub="$TMPHOME/lsof_stub"; mkdir -p "$lsof_stub"
printf '#!/bin/sh\necho 424242\n' > "$lsof_stub/pgrep"
printf '#!/bin/sh\necho "lsof: broken" >&2\nexit 1\n' > "$lsof_stub/lsof"
chmod +x "$lsof_stub/pgrep" "$lsof_stub/lsof"
sess_nolsof=$(PATH="$lsof_stub:$PATH" HOME="$REAL_HOME" "$BASH" -c '
  set -euo pipefail; OPEN_WORK_LIB=1 . "$1"; collect_sessions' _ "$SCRIPT" 2>/dev/null || echo '{}')
assert_contains "wholesale lsof failure is reported" "resolved no working directories" \
  "$(printf '%s' "$sess_nolsof" | jq -r '.errors.sessions // ""')"
assert_eq "wholesale lsof failure still yields a valid empty session list" "0" \
  "$(printf '%s' "$sess_nolsof" | jq '.sessions | length')"

# Rule 3, the other side: a per-pid lsof miss is a RACE (the process exited
# mid-scan), not a fault, so it must be skipped silently while the surviving
# session is still captured. Only a wholesale failure is reported. Without this
# assertion the race-vs-fault distinction — a deliberate design decision — has
# no test, and a future change could start reporting an error on every scan
# that happens to catch an exiting process.
mixed_stub="$TMPHOME/mixed_stub"; mkdir -p "$mixed_stub"
printf '#!/bin/sh\ncase "$*" in *claude*) echo 111; echo 222;; *) exit 1;; esac\n' \
  > "$mixed_stub/pgrep"
printf '#!/bin/sh\nfor a in "$@"; do\n  [ "$a" = "111" ] && { echo "n%s"; exit 0; }\ndone\necho "lsof: gone" >&2\nexit 1\n' \
  "$PWD" > "$mixed_stub/lsof"
chmod +x "$mixed_stub/pgrep" "$mixed_stub/lsof"
sess_mixed=$(PATH="$mixed_stub:$PATH" HOME="$REAL_HOME" "$BASH" -c '
  set -euo pipefail; OPEN_WORK_LIB=1 . "$1"; collect_sessions' _ "$SCRIPT" 2>/dev/null || echo '{}')
assert_eq "a per-pid lsof miss is skipped, not reported" "null" \
  "$(printf '%s' "$sess_mixed" | jq -r '.errors.sessions // "null"')"
assert_eq "the pid that did resolve is still captured" "1" \
  "$(printf '%s' "$sess_mixed" | jq '.sessions | length')"

echo "forge payload parsing"
gh_fixture="$TMPHOME/gh_prs.json"
cat > "$gh_fixture" <<'JSON'
[{"createdAt":"2026-09-10T16:10:00Z","number":234,"id":"PR_kwDO1",
  "repository":{"nameWithOwner":"example-user/widget"},
  "title":"fix: example change","url":"https://github.com/example-user/widget/pull/234","isDraft":false},
 {"createdAt":"2026-06-30T14:00:08Z","number":145,"id":"PR_kwDO2",
  "repository":{"nameWithOwner":"example-user/gadget"},
  "title":"fix: another example change","url":"https://github.com/example-user/gadget/pull/145","isDraft":false}]
JSON
items=$(parse_gh_prs authored < "$gh_fixture")
assert_eq "gh: two items" "2" "$(printf '%s' "$items" | jq 'length')"
assert_eq "gh: repo_id normalised" "github.com/example-user/widget" "$(printf '%s' "$items" | jq -r '.[0].repo_id')"
assert_eq "gh: display id" "#234" "$(printf '%s' "$items" | jq -r '.[0].display_id')"
assert_eq "gh: bucket honoured" "authored" "$(printf '%s' "$items" | jq -r '.[0].bucket')"
assert_eq "gh: branch is null (search cannot return headRefName)" "null" "$(printf '%s' "$items" | jq -r '.[0].branch')"

glab_fixture="$TMPHOME/glab_mrs.json"
cat > "$glab_fixture" <<'JSON'
[{"id":531863901,"iid":2,"title":"fix: example merge request","created_at":"2026-08-28T15:22:12Z",
  "source_branch":"fix/example-change",
  "web_url":"https://gitlab.com/example-org/group-a/subgroup-b/repo-three/-/merge_requests/2"}]
JSON
items=$(parse_glab_mrs authored < "$glab_fixture")
assert_eq "glab: repo_id from web_url via /-/ split" \
  "gitlab.com/example-org/group-a/subgroup-b/repo-three" "$(printf '%s' "$items" | jq -r '.[0].repo_id')"
assert_eq "glab: display id uses iid" "!2" "$(printf '%s' "$items" | jq -r '.[0].display_id')"
assert_eq "glab: dedup id uses global id" "531863901" "$(printf '%s' "$items" | jq -r '.[0].id')"
assert_eq "glab: source_branch captured" "fix/example-change" "$(printf '%s' "$items" | jq -r '.[0].branch')"

# A non-array payload is an error, never a count. Regression:
# `reviewer_id=me` returns HTTP 400 and an early probe read the error body's
# length as "1 result".
err_fixture="$TMPHOME/glab_err.json"
echo '{"error":"reviewer_id should be an integer, none, or any, however got me"}' > "$err_fixture"
rc=0; out=$(parse_glab_mrs review < "$err_fixture") || rc=$?
assert_eq "non-array payload exits non-zero" 1 "$rc"
assert_eq "non-array payload yields no items" "" "$out"

# Regression: the guard must not depend on the caller setting pipefail.
# This harness sets `set -uo pipefail`, so the piped form would pass here and
# still break in library mode, which skips it. Re-check with pipefail OFF.
rc=0
out=$("$BASH" -c 'set -u; OPEN_WORK_LIB=1 source "$1"; parse_glab_mrs review < "$2"' _ "$SCRIPT" "$err_fixture") || rc=$?
assert_eq "non-array rejected even without pipefail" 1 "$rc"
assert_eq "non-array yields no items without pipefail" "" "$out"

# --- collector behaviour, using stub CLIs on PATH (no network) ---
STUB="$TMPHOME/stubbin"; mkdir -p "$STUB"
# gh: first call succeeds with exactly GH_LIMIT items (limit-reached), others fail
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"user-review-requested"* ]]; then
  echo "gh: HTTP 401 Bad credentials" >&2; exit 1
fi
if [[ "$*" == *"--author=@me"* ]]; then
  /usr/bin/awk 'BEGIN{printf "[";for(i=1;i<=100;i++){printf "%s{\"number\":%d,\"id\":\"P%d\",\"title\":\"t\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"repository\":{\"nameWithOwner\":\"o/r\"},\"url\":\"u\",\"isDraft\":false}",(i>1?",":""),i,i}printf "]"}'
  exit 0
fi
echo '[]'; exit 0
STUBEOF
cat > "$STUB/glab" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$*" == *"/user"* ]] && { echo '{"id":1,"username":"tester"}'; exit 0; }
echo '[]'; exit 0
STUBEOF
chmod +x "$STUB/gh" "$STUB/glab"

coll=$(PATH="$STUB:$PATH" collect_items)
assert_contains "failed query captured in .errors" "401" "$(printf '%s' "$coll" | jq -r '.errors.github_review // ""')"
assert_eq "one failure does not suppress other queries" "100" "$(printf '%s' "$coll" | jq '.items | length')"
assert_eq "limit-reached is marked" "true" "$(printf '%s' "$coll" | jq -r '.limits.github_authored // false')"
assert_eq "identity lookup succeeded (no gitlab_review error)" "" "$(printf '%s' "$coll" | jq -r '.errors.gitlab_review // ""')"

# --- collect() must actually combine both collectors (regression: it was never wired) ---
agg=$(PATH="$STUB:$PATH" HOME="$REAL_HOME" collect)
assert_eq "collect emits its four keys" "true" \
  "$(printf '%s' "$agg" | jq 'has("sessions") and has("items") and has("errors") and has("limits")')"
assert_eq "test_no_profile_key" "false" "$(printf '%s' "$agg" | jq 'has("profile")')"
assert_eq "collect carries items through" "100" "$(printf '%s' "$agg" | jq '.items | length')"
assert_eq "collect carries sessions through (array)" "array" "$(printf '%s' "$agg" | jq -r '.sessions | type')"

# collect() must fold collect_sessions' error map into the
# document's single flat .errors, or the new channel never reaches the renderer
# and the session error is invisible. `sessions` cannot collide with the seven
# <forge>_<bucket> keys, so a plain `+` is the whole merge.
agg_err=$(PATH="$pgrep_stub:$STUB:$PATH" HOME="$REAL_HOME" collect)
assert_contains "collect merges session errors into .errors" "pgrep failed" \
  "$(printf '%s' "$agg_err" | jq -r '.errors.sessions // ""')"
assert_contains "merged .errors still carries forge errors alongside" "401" \
  "$(printf '%s' "$agg_err" | jq -r '.errors.github_review // ""')"

# Regression: /user identity lookup must capture both stdout and stderr separately.
# Real glab returns structured errors in the JSON body (stdout) with only a terse
# summary on stderr. The fix captures them separately so jq parses only the body,
# and error messages include both. The stub body has unique text (insufficient_scope)
# not present in stderr, to verify the body was actually captured.
STUB2="$TMPHOME/stubbin2"; mkdir -p "$STUB2"
cat > "$STUB2/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo '[]'; exit 0
STUBEOF
cat > "$STUB2/glab" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"/user"* ]]; then
  echo '{"message":"insufficient_scope: missing read_api"}' >&1
  echo "glab: 401 Unauthorized" >&2
  exit 1
fi
echo '[]'; exit 0
STUBEOF
chmod +x "$STUB2/gh" "$STUB2/glab"

coll=$(PATH="$STUB2:$PATH" collect_items)
assert_contains "identity lookup captures unique body text" "insufficient_scope" "$(printf '%s' "$coll" | jq -r '.errors.gitlab_review // ""')"
assert_contains "identity lookup includes stderr summary" "401 Unauthorized" "$(printf '%s' "$coll" | jq -r '.errors.gitlab_review // ""')"

# Regression: _try must capture stdout/stderr separately. A CLI that succeeds (exit 0, valid
# JSON array) but writes a deprecation notice to stderr must not corrupt the payload.
# Before the fix, stderr was merged into the payload, jq would fail on the corrupted JSON,
# and a successful query would be recorded as an error.
STUB3="$TMPHOME/stubbin3"; mkdir -p "$STUB3"
cat > "$STUB3/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "gh: notice: search syntax will change in a future release" >&2
echo '[{"number":1,"id":"P1","title":"test","createdAt":"2026-01-01T00:00:00Z","repository":{"nameWithOwner":"o/r"},"url":"u","isDraft":false}]'
exit 0
STUBEOF
cat > "$STUB3/glab" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$*" == *"/user"* ]] && { echo '{"id":1,"username":"tester"}'; exit 0; }
echo '[]'; exit 0
STUBEOF
chmod +x "$STUB3/gh" "$STUB3/glab"

coll=$(PATH="$STUB3:$PATH" collect_items)
assert_eq "success with stderr notice parses items" "3" "$(printf '%s' "$coll" | jq '.items | length')"
assert_eq "success with stderr notice has no errors" "0" "$(printf '%s' "$coll" | jq '.errors | length')"

# _try must report a failed forge call regardless of how its caller
# dispatches collect_items. A bare `payload="$(cmd)"` aborts under set -e, so
# before this fix the error path survived only because collect_items happens to
# be called inside a command substitution in collect(). Dispatch it with a
# redirect instead — that is the form that catches a regression here, and it
# discriminates under both bash 3.2 and 5.3.
errexit_stub="$TMPHOME/errexit_stub"; mkdir -p "$errexit_stub"
for c in gh glab; do
  printf '#!/bin/sh\necho "stub failure" >&2\nexit 1\n' > "$errexit_stub/$c"
  chmod +x "$errexit_stub/$c"
done
errexit_out="$TMPHOME/errexit_out.json"
# "$BASH", not a bare `bash`: the probe must run under the SAME bash as the
# harness. A bare `bash` resolves via PATH to Homebrew 5.3, so running this
# suite under /bin/bash 3.2 would silently re-test 5.3 — and set -e abort
# behaviour is exactly what is version-sensitive here.
PATH="$errexit_stub:$PATH" "$BASH" -c '
  set -euo pipefail
  OPEN_WORK_LIB=1 . "$1"
  collect_items > "$2"
' _ "$SCRIPT" "$errexit_out" 2>/dev/null || true
assert_eq "_try reports errors under strict mode with a redirect dispatch" "7" \
  "$(jq -r '.errors | keys | length' < "$errexit_out" 2>/dev/null || echo MISSING)"
assert_eq "_try returns no items when every forge call fails" "0" \
  "$(jq -r '.items | length' < "$errexit_out" 2>/dev/null || echo MISSING)"

# --- gh pr view branch resolution, cap, and degrade-never-fail ---
# 2 review PRs (101,102) + 30 authored PRs (1..30) + 1 assigned issue (501) = 33
# items, 32 of them PRs. GH_PR_BRANCH_LOOKUP_CAP=25 means only the first 25 PRs
# in emission order (101,102,1..23) are attempted; number 5 is made to fail
# (exit 1, no output) to exercise degrade-never-fail; numbers 24-30 are never
# attempted at all, to exercise the cap. The issue (501) must never be queried.
STUB4="$TMPHOME/stubbin4"; mkdir -p "$STUB4"
PR_VIEW_LOG="$TMPHOME/pr_view.log"; : > "$PR_VIEW_LOG"
export PR_VIEW_LOG
cat > "$STUB4/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr view" ]]; then
  echo "$3" >> "$PR_VIEW_LOG"
  [[ "$3" == "5" ]] && exit 1
  echo "feat/pr-$3"
  exit 0
fi
case "$*" in
  *user-review-requested*)
    echo '[{"number":101,"id":"R101","title":"r1","createdAt":"2026-01-01T00:00:00Z","repository":{"nameWithOwner":"o/r"},"url":"u","isDraft":false},{"number":102,"id":"R102","title":"r2","createdAt":"2026-01-01T00:00:00Z","repository":{"nameWithOwner":"o/r"},"url":"u","isDraft":false}]'
    exit 0 ;;
  *--author=@me*)
    /usr/bin/awk 'BEGIN{printf "[";for(i=1;i<=30;i++){printf "%s{\"number\":%d,\"id\":\"A%d\",\"title\":\"a\",\"createdAt\":\"2026-01-02T00:00:00Z\",\"repository\":{\"nameWithOwner\":\"o/r\"},\"url\":\"u\",\"isDraft\":false}",(i>1?",":""),i,i}printf "]"}'
    exit 0 ;;
  *--assignee=@me*)
    echo '[{"number":501,"id":"I501","title":"issue","createdAt":"2026-01-03T00:00:00Z","repository":{"nameWithOwner":"o/r"}}]'
    exit 0 ;;
  *) echo '[]'; exit 0 ;;
esac
STUBEOF
cat > "$STUB4/glab" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$*" == *"/user"* ]] && { echo '{"id":1,"username":"tester"}'; exit 0; }
echo '[]'; exit 0
STUBEOF
chmod +x "$STUB4/gh" "$STUB4/glab"

coll4=$(PATH="$STUB4:$PATH" collect_items)
assert_eq "gh pr view: cap enforced at exactly 25 lookups" "25" "$(wc -l < "$PR_VIEW_LOG" | tr -d ' ')"
assert_eq "gh pr view: no item dropped by branch resolution" "33" "$(printf '%s' "$coll4" | jq '.items | length')"
assert_eq "gh pr view: resolved branch applied" "feat/pr-1" \
  "$(printf '%s' "$coll4" | jq -r '.items[] | select(.forge=="github" and .display_id=="#1") | .branch')"
assert_eq "gh pr view: failed lookup degrades to null, item kept" "null" \
  "$(printf '%s' "$coll4" | jq -r '.items[] | select(.forge=="github" and .display_id=="#5") | .branch')"
assert_eq "gh pr view: PR left uncapped stays null" "null" \
  "$(printf '%s' "$coll4" | jq -r '.items[] | select(.forge=="github" and .display_id=="#30") | .branch')"
assert_eq "gh pr view: issues are never queried, branch stays null" "null" \
  "$(printf '%s' "$coll4" | jq -r '.items[] | select(.forge=="github" and .display_id=="#501") | .branch')"
assert_eq "gh pr view: precision loss reported" "resolved 24 of 32 GitHub PR head branches; 8 left at repository level" \
  "$(printf '%s' "$coll4" | jq -r '.errors.github_pr_branches')"

# Every PR resolving must omit the key entirely, not report it empty.
STUB5="$TMPHOME/stubbin5"; mkdir -p "$STUB5"
cat > "$STUB5/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr view" ]]; then echo "feat/x"; exit 0; fi
case "$*" in
  *--author=@me*) echo '[{"number":1,"id":"A1","title":"a","createdAt":"2026-01-01T00:00:00Z","repository":{"nameWithOwner":"o/r"},"url":"u","isDraft":false}]'; exit 0 ;;
  *) echo '[]'; exit 0 ;;
esac
STUBEOF
cat > "$STUB5/glab" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$*" == *"/user"* ]] && { echo '{"id":1,"username":"tester"}'; exit 0; }
echo '[]'; exit 0
STUBEOF
chmod +x "$STUB5/gh" "$STUB5/glab"
coll5=$(PATH="$STUB5:$PATH" collect_items)
assert_eq "gh pr view: key omitted entirely when every PR resolves" "null" \
  "$(printf '%s' "$coll5" | jq -r '.errors.github_pr_branches // "null"')"

echo "shape"
fix="$TMPHOME/shape.json"
cat > "$fix" <<'JSON'
{
 "sessions":[
   {"pid":1,"tty":"ttys041","agent":"claude","cwd":"/c/widget","root":"/c/widget",
    "repo_id":"github.com/example-user/widget","branch":"main","idle_seconds":14400},
   {"pid":2,"tty":"ttys060","agent":"claude","cwd":"/c/stale-repo","root":"/c/stale-repo",
    "repo_id":"gitlab.com/example-org/stale-repo","branch":"main","idle_seconds":1036800},
   {"pid":3,"tty":"ttys099","agent":"opencode","cwd":"/c/other","root":"/c/other",
    "repo_id":"gitlab.com/example-org/other","branch":"main","idle_seconds":null}],
 "items":[
   {"forge":"gitlab","host":"gitlab.com","repo_id":"gitlab.com/example-org/x","id":"100","display_id":"!2",
    "title":"authored+assigned dup","created_at":"2026-08-28T15:22:12Z","branch":"feat/x","bucket":"authored"},
   {"forge":"gitlab","host":"gitlab.com","repo_id":"gitlab.com/example-org/x","id":"100","display_id":"!2",
    "title":"authored+assigned dup","created_at":"2026-08-28T15:22:12Z","branch":"feat/x","bucket":"assigned"},
   {"forge":"github","host":"github.com","repo_id":"github.com/example-user/widget","id":"200","display_id":"#234",
    "title":"has active session","created_at":"2026-09-10T16:10:00Z","branch":null,"bucket":"authored"},
   {"forge":"gitlab","host":"gitlab.com","repo_id":"gitlab.com/example-org/stale-repo","id":"300","display_id":"!7",
    "title":"session is stale","created_at":"2026-08-01T00:00:00Z","branch":"main","bucket":"authored"},
   {"forge":"github","host":"github.com","repo_id":"github.com/example-user/gadget","id":"400","display_id":"#145",
    "title":"no local clone","created_at":"2026-06-30T14:00:08Z","branch":null,"bucket":"authored"}],
 "errors":{"gitlab_issues":"HTTP 401 unauthorized"},
 "limits":{}}
JSON

out=$("$BASH" "$SCRIPT" --from-json "$fix")
assert_eq "dedups the authored/assigned duplicate" "4" "$(printf '%s' "$out" | jq '.items | length')"
assert_eq "dedup keeps the higher-priority bucket" "authored" \
  "$(printf '%s' "$out" | jq -r '.items[] | select(.id=="100") | .bucket')"
# Regression test for the reported defect: item 200 has a null branch (GitHub
# search cannot return one) and a session sits in its repo on "main" — but that
# session is not shown to be working on THIS item, only on the repo. Before
# the fix, `$i.branch == null` in the status rule matched this unconditionally
# and returned "session"; a GitHub issue's session marker claimed in-flight work
# that was never verified against a branch.
assert_eq "null-branch item with a repo session -> session-repo-only (regression)" "session-repo-only" \
  "$(printf '%s' "$out" | jq -r '.items[] | select(.id=="200") | .status')"
# Two axes now: status says whether a session matched, session_state says how
# idle it is. An earlier draft collapsed them, which made a live session with an
# unresolvable transcript report as "stale".
assert_eq "stale session still matches" "session" \
  "$(printf '%s' "$out" | jq -r '.items[] | select(.id=="300") | .status')"
assert_eq "stale session state is stale" "stale" \
  "$(printf '%s' "$out" | jq -r '.items[] | select(.id=="300") | .session_state')"
assert_eq "active session state is active" "active" \
  "$(printf '%s' "$out" | jq -r '.items[] | select(.id=="200") | .session_state')"
assert_eq "unmatched item has null session_state" "null" \
  "$(printf '%s' "$out" | jq -r '.items[] | select(.id=="400") | .session_state')"

# A live Claude session whose transcript cannot be resolved must NOT read as
# stale — it is live with unknown idle. This fixture is the regression.
fix_unk="$TMPHOME/shape_unknown.json"
cat > "$fix_unk" <<'JSON'
{
 "sessions":[{"pid":7,"tty":"t7","agent":"claude","cwd":"/c/u","root":"/c/u",
              "repo_id":"gitlab.com/example-org/u","branch":"main","idle_seconds":null}],
 "items":[{"forge":"gitlab","host":"gitlab.com","repo_id":"gitlab.com/example-org/u","id":"700",
           "display_id":"!7","title":"t","created_at":"2026-08-01T00:00:00Z",
           "branch":"main","bucket":"authored"}],
 "errors":{},"limits":{}}
JSON
out_unk=$("$BASH" "$SCRIPT" --from-json "$fix_unk")
assert_eq "unknown-idle session still counts as a session" "session" \
  "$(printf '%s' "$out_unk" | jq -r '.items[0].status')"
assert_eq "unknown-idle is reported unknown, never stale" "unknown" \
  "$(printf '%s' "$out_unk" | jq -r '.items[0].session_state')"
assert_eq "no matching repo -> no-session" "no-session" \
  "$(printf '%s' "$out" | jq -r '.items[] | select(.id=="400") | .status')"
assert_eq "session under threshold is active" "active" \
  "$(printf '%s' "$out" | jq -r '.sessions[] | select(.pid==1) | .state')"
assert_eq "session over threshold is stale" "stale" \
  "$(printf '%s' "$out" | jq -r '.sessions[] | select(.pid==2) | .state')"
assert_eq "null idle is unknown, never active" "unknown" \
  "$(printf '%s' "$out" | jq -r '.sessions[] | select(.pid==3) | .state')"
assert_eq "errors survive shaping" "HTTP 401 unauthorized" \
  "$(printf '%s' "$out" | jq -r '.errors.gitlab_issues')"
# Assert the order SHAPE EMITTED. The earlier version applied sort_by() to the
# output itself before checking, so it passed even when shape did no ordering.
assert_eq "items emitted oldest-first" "400,300,100,200" \
  "$(printf '%s' "$out" | jq -r '[.items[].id] | join(",")')"
assert_eq "unmatched sessions listed" "1" \
  "$(printf '%s' "$out" | jq '[.sessions[] | select(.matched == false)] | length')"

# A non-Claude session in a MATCHING repo must never join. The original
# fixture put the opencode session in a non-matching repo, so the bug passed.
fix2="$TMPHOME/shape_a7.json"
cat > "$fix2" <<'JSON'
{
 "sessions":[{"pid":9,"tty":"t9","agent":"opencode","cwd":"/c/x","root":"/c/x",
              "repo_id":"gitlab.com/example-org/x","branch":"main","idle_seconds":null}],
 "items":[{"forge":"gitlab","host":"gitlab.com","repo_id":"gitlab.com/example-org/x","id":"900",
           "display_id":"!9","title":"t","created_at":"2026-08-01T00:00:00Z",
           "branch":"feat/x","bucket":"authored"}],
 "errors":{},"limits":{}}
JSON
out2=$("$BASH" "$SCRIPT" --from-json "$fix2")
assert_eq "non-claude session never joins" "no-session" "$(printf '%s' "$out2" | jq -r '.items[0].status')"
assert_eq "non-claude session yields no matches" "0" "$(printf '%s' "$out2" | jq '.items[0].matches | length')"

# session-other-branch is a public status with no previous coverage.
fix3="$TMPHOME/shape_branch.json"
cat > "$fix3" <<'JSON'
{
 "sessions":[{"pid":11,"tty":"t11","agent":"claude","cwd":"/c/c","root":"/c/c",
              "repo_id":"gitlab.com/example-org/c","branch":"other","idle_seconds":600}],
 "items":[{"forge":"gitlab","host":"gitlab.com","repo_id":"gitlab.com/example-org/c","id":"910",
           "display_id":"!10","title":"t","created_at":"2026-08-01T00:00:00Z",
           "branch":"feat/x","bucket":"authored"},
          {"forge":"github","host":"github.com","repo_id":"gitlab.com/example-org/c","id":"911",
           "display_id":"#11","title":"null-branch item","created_at":"2026-08-02T00:00:00Z",
           "branch":null,"bucket":"authored"}],
 "errors":{},"limits":{}}
JSON
out3=$("$BASH" "$SCRIPT" --from-json "$fix3")
assert_eq "branch mismatch -> session-other-branch" "session-other-branch" \
  "$(printf '%s' "$out3" | jq -r '.items[] | select(.id=="910") | .status')"
assert_eq "null branch with a repo session -> session-repo-only, not session" "session-repo-only" \
  "$(printf '%s' "$out3" | jq -r '.items[] | select(.id=="911") | .status')"

# Amplification case from the live run, stated as an assertion: one session
# sitting in a repo must not light up EVERY null-branch item in that repo as
# "session". Three GitHub issues in example-user/widget all rendered "session"
# from a single unrelated session on main — this is that scenario, reduced.
fix_repo_only="$TMPHOME/shape_repo_only.json"
cat > "$fix_repo_only" <<'JSON'
{
 "sessions":[{"pid":21,"tty":"t21","agent":"claude","cwd":"/c/widget","root":"/c/widget",
              "repo_id":"github.com/example-user/widget","branch":"main","idle_seconds":18000}],
 "items":[{"forge":"github","host":"github.com","repo_id":"github.com/example-user/widget","id":"65",
           "display_id":"#65","title":"issue 65","created_at":"2026-09-01T00:00:00Z",
           "branch":null,"bucket":"assigned"},
          {"forge":"github","host":"github.com","repo_id":"github.com/example-user/widget","id":"66",
           "display_id":"#66","title":"issue 66","created_at":"2026-09-02T00:00:00Z",
           "branch":null,"bucket":"assigned"},
          {"forge":"github","host":"github.com","repo_id":"github.com/example-user/widget","id":"78",
           "display_id":"#78","title":"issue 78","created_at":"2026-09-03T00:00:00Z",
           "branch":null,"bucket":"assigned"}],
 "errors":{},"limits":{}}
JSON
out_repo_only=$("$BASH" "$SCRIPT" --from-json "$fix_repo_only")
assert_eq "all three null-branch items in one repo report session-repo-only" "session-repo-only,session-repo-only,session-repo-only" \
  "$(printf '%s' "$out_repo_only" | jq -r '[.items[].status] | join(",")')"
assert_eq "none of the three amplify to session" "0" \
  "$(printf '%s' "$out_repo_only" | jq '[.items[] | select(.status=="session")] | length')"
assert_eq "session_state still populates for a session-repo-only item" "active" \
  "$(printf '%s' "$out_repo_only" | jq -r '.items[0].session_state')"

# Negative case: the new clause must not swallow a genuinely absent session.
# A null-branch item with no session anywhere in its repo is still "no-session".
fix_repo_only_absent="$TMPHOME/shape_repo_only_absent.json"
cat > "$fix_repo_only_absent" <<'JSON'
{
 "sessions":[{"pid":22,"tty":"t22","agent":"claude","cwd":"/c/elsewhere","root":"/c/elsewhere",
              "repo_id":"github.com/other/repo","branch":"main","idle_seconds":100}],
 "items":[{"forge":"github","host":"github.com","repo_id":"github.com/example-user/widget","id":"79",
           "display_id":"#79","title":"issue 79, no session in this repo","created_at":"2026-09-01T00:00:00Z",
           "branch":null,"bucket":"assigned"}],
 "errors":{},"limits":{}}
JSON
out_repo_only_absent=$("$BASH" "$SCRIPT" --from-json "$fix_repo_only_absent")
assert_eq "null-branch item with no session in its repo is still no-session" "no-session" \
  "$(printf '%s' "$out_repo_only_absent" | jq -r '.items[0].status')"

# Matched sessions must be freshest-first, not merely active-first.
fix4="$TMPHOME/shape_order.json"
cat > "$fix4" <<'JSON'
{
 "sessions":[{"pid":1,"tty":"a","agent":"claude","cwd":"/c/a","root":"/c/a","repo_id":"gl/a","branch":"main","idle_seconds":14400},
             {"pid":2,"tty":"b","agent":"claude","cwd":"/c/a2","root":"/c/a2","repo_id":"gl/a","branch":"main","idle_seconds":600}],
 "items":[{"forge":"gitlab","host":"gl","repo_id":"gl/a","id":"920","display_id":"!20","title":"t",
           "created_at":"2026-08-01T00:00:00Z","branch":"main","bucket":"authored"}],
 "errors":{},"limits":{}}
JSON
out4=$("$BASH" "$SCRIPT" --from-json "$fix4")
assert_eq "matches freshest-first" "2,1" \
  "$(printf '%s' "$out4" | jq -r '[.items[0].matches[].pid] | join(",")')"

# The parsers build repo_id in jq rather than calling normalize_repo_id, so
# the two paths must be asserted to agree or they can silently diverge.
assert_eq "parser repo_id agrees with normalize_repo_id" \
  "$(normalize_repo_id 'https://gitlab.com/example-org/group-a/subgroup-b/repo-three.git')" \
  "$(printf '%s' "$(parse_glab_mrs authored < "$glab_fixture")" | jq -r '.[0].repo_id')"

# normalize_repo_id strips a host port; the jq path used to keep it, so
# an item on a self-hosted forge with a non-default port could never join a
# session in its local clone. Compare the two paths' output directly rather than
# hard-coding either side, so the assertion fails if either one drifts. The
# parser-agreement assertion above is the negative control: it uses a portless gitlab.com URL, so
# it goes red if the new strip ever mangles an ordinary host.
port_fixture="$TMPHOME/glab_port.json"
cat > "$port_fixture" <<'JSON'
[{"id":77,"iid":3,"title":"self-hosted with a port","created_at":"2026-08-28T15:22:12Z",
  "source_branch":"feat/p",
  "web_url":"https://gl.example.com:8443/group/repo/-/merge_requests/3"}]
JSON
assert_eq "MR parser and normalize_repo_id agree on a port-bearing host" \
  "$(normalize_repo_id 'https://gl.example.com:8443/group/repo.git')" \
  "$(parse_glab_mrs authored < "$port_fixture" | jq -r '.[0].repo_id')"

# The issues parser carries its own copy of the expression, so it needs its own
# assertion or one of the two can be fixed while the other rots.
port_issue_fixture="$TMPHOME/glab_port_issue.json"
cat > "$port_issue_fixture" <<'JSON'
[{"id":78,"iid":4,"title":"self-hosted issue with a port","created_at":"2026-08-28T15:22:12Z",
  "web_url":"https://gl.example.com:8443/group/repo/-/issues/4"}]
JSON
assert_eq "issues parser and normalize_repo_id agree on a port-bearing host" \
  "$(normalize_repo_id 'https://gl.example.com:8443/group/repo.git')" \
  "$(parse_glab_issues assigned < "$port_issue_fixture" | jq -r '.[0].repo_id')"

# Match ordering's PRIMARY key (state_rank) is never exercised.
# shape_order.json gives both matches active state, so only idle_seconds is tested.
# Add a fixture with one active and one stale match on the same item,
# assert the active one (state_rank=0) comes first.
fix_mixed_state="$TMPHOME/shape_mixed_state.json"
cat > "$fix_mixed_state" <<'JSON'
{
 "sessions":[{"pid":101,"tty":"t101","agent":"claude","cwd":"/c/m1","root":"/c/m1",
              "repo_id":"gl/mixed","branch":"main","idle_seconds":100},
             {"pid":102,"tty":"t102","agent":"claude","cwd":"/c/m2","root":"/c/m2",
              "repo_id":"gl/mixed","branch":"main","idle_seconds":1000000}],
 "items":[{"forge":"gitlab","host":"gl","repo_id":"gl/mixed","id":"930",
           "display_id":"!30","title":"mixed states","created_at":"2026-08-01T00:00:00Z",
           "branch":"main","bucket":"authored"}],
 "errors":{},"limits":{}}
JSON
out_mixed=$("$BASH" "$SCRIPT" --from-json "$fix_mixed_state")
assert_eq "match ordering: active before stale" "101,102" \
  "$(printf '%s' "$out_mixed" | jq -r '[.items[0].matches[].pid] | join(",")')"
assert_eq "session_state from active match" "active" \
  "$(printf '%s' "$out_mixed" | jq -r '.items[0].session_state')"

# Dedup priority is two-thirds untested.
# Only authored > assigned is asserted. review (rank 0) is never tested.
# Add a fixture where same {forge, host, id} appears as review, authored, and assigned.
fix_all_buckets="$TMPHOME/shape_all_buckets.json"
cat > "$fix_all_buckets" <<'JSON'
{
 "sessions":[],
 "items":[{"forge":"gitlab","host":"gl","repo_id":"gl/b","id":"940",
           "display_id":"!40","title":"review bucket","created_at":"2026-08-01T00:00:00Z",
           "branch":"main","bucket":"review"},
          {"forge":"gitlab","host":"gl","repo_id":"gl/b","id":"940",
           "display_id":"!40","title":"review bucket","created_at":"2026-08-01T00:00:00Z",
           "branch":"main","bucket":"authored"},
          {"forge":"gitlab","host":"gl","repo_id":"gl/b","id":"940",
           "display_id":"!40","title":"review bucket","created_at":"2026-08-01T00:00:00Z",
           "branch":"main","bucket":"assigned"}],
 "errors":{},"limits":{}}
JSON
out_buckets=$("$BASH" "$SCRIPT" --from-json "$fix_all_buckets")
assert_eq "dedup: review > authored" "review" \
  "$(printf '%s' "$out_buckets" | jq -r '.items[0].bucket')"

# Secondary and tertiary ordering keys are unexercised.
# Items sort by created_at (primary), forge (secondary), id (tertiary).
# Fixture ids chosen so dropping .forge (while keeping .id) reverses order
# (id 950 gitlab < 951 github). This fixture cannot catch dropping BOTH keys —
# group_by already imposes forge order here — so the forge tie-break test below covers that.
fix_forge_order="$TMPHOME/shape_forge_order.json"
cat > "$fix_forge_order" <<'JSON'
{
 "sessions":[],
 "items":[{"forge":"gitlab","host":"gl","repo_id":"gl/r","id":"950",
           "display_id":"!50","title":"gitlab","created_at":"2026-08-01T00:00:00Z",
           "branch":null,"bucket":"authored"},
          {"forge":"github","host":"github.com","repo_id":"github.com/o/r","id":"951",
           "display_id":"#51","title":"github","created_at":"2026-08-01T00:00:00Z",
           "branch":null,"bucket":"authored"}],
 "errors":{},"limits":{}}
JSON
out_forge=$("$BASH" "$SCRIPT" --from-json "$fix_forge_order")
assert_eq "items ordered by forge after created_at" "github,gitlab" \
  "$(printf '%s' "$out_forge" | jq -r '[.items[].forge] | join(",")')"

# group_by's key is "forge|host|id" but the tie-break is (.forge, .id)
# — it skips .host. Since sort_by is stable, the two orders diverge only when
# one forge spans two hosts and id-order contradicts host-order. That is the
# fixture that catches dropping BOTH tie-break keys; shape_forge_order above
# cannot, because with one host per forge the orders agree.
fix_multi_host="$TMPHOME/shape_multi_host_order.json"
cat > "$fix_multi_host" <<'JSON'
{
 "sessions":[],
 "items":[{"forge":"gitlab","host":"a.example","repo_id":"a.example/o/r","id":"999",
           "display_id":"!999","title":"host a high id","created_at":"2026-08-01T00:00:00Z",
           "branch":null,"bucket":"authored"},
          {"forge":"gitlab","host":"b.example","repo_id":"b.example/o/r","id":"100",
           "display_id":"!100","title":"host b low id","created_at":"2026-08-01T00:00:00Z",
           "branch":null,"bucket":"authored"}],
 "errors":{},"limits":{}}
JSON
out_multi_host=$("$BASH" "$SCRIPT" --from-json "$fix_multi_host")
assert_eq "one forge across two hosts orders by id, not by host" "b.example,a.example" \
  "$(printf '%s' "$out_multi_host" | jq -r '[.items[].host] | join(",")')"

# Matches break ties on pid when state and idle_seconds match.
# Add two matches with same state and idle_seconds, assert order by pid.
fix_pid_order="$TMPHOME/shape_pid_order.json"
cat > "$fix_pid_order" <<'JSON'
{
 "sessions":[{"pid":201,"tty":"t201","agent":"claude","cwd":"/c/p1","root":"/c/p1",
              "repo_id":"gl/p","branch":"main","idle_seconds":100},
             {"pid":200,"tty":"t200","agent":"claude","cwd":"/c/p2","root":"/c/p2",
              "repo_id":"gl/p","branch":"main","idle_seconds":100}],
 "items":[{"forge":"gitlab","host":"gl","repo_id":"gl/p","id":"960",
           "display_id":"!60","title":"pid order","created_at":"2026-08-01T00:00:00Z",
           "branch":"main","bucket":"authored"}],
 "errors":{},"limits":{}}
JSON
out_pid=$("$BASH" "$SCRIPT" --from-json "$fix_pid_order")
assert_eq "matches ordered by pid on state/idle tie" "200,201" \
  "$(printf '%s' "$out_pid" | jq -r '[.items[0].matches[].pid] | join(",")')"

# Stale boundary untested.
# idle_seconds > 3 days is stale. Test exactly at threshold (3 * 86400 = 259200).
# Should be active (< stale threshold), not stale.
fix_boundary="$TMPHOME/shape_boundary.json"
cat > "$fix_boundary" <<'JSON'
{
 "sessions":[{"pid":301,"tty":"t301","agent":"claude","cwd":"/c/bound","root":"/c/bound",
              "repo_id":"gl/bound","branch":"main","idle_seconds":259200}],
 "items":[],
 "errors":{},"limits":{}}
JSON
out_bound=$("$BASH" "$SCRIPT" --from-json "$fix_boundary")
assert_eq "stale boundary: idle == 3*86400 is active" "active" \
  "$(printf '%s' "$out_bound" | jq -r '.sessions[0].state')"
echo "--reviews-only"

# Argv-logging stubs. Unlike the forge-parsing stubs these record every invocation, so
# the assertions can be about requests NOT MADE -- which is the actual contract.
# An output-shape assertion would also pass against a collector that ran all
# eight requests and discarded five, the implementation the spec forbids.
RSTUB="$TMPHOME/reviews_only_stub"; mkdir -p "$RSTUB"
RLOG="$TMPHOME/reviews_only.log"
cat > "$RSTUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Log the joined form (for substring assertions) AND each argv entry separately.
# "$*" alone cannot distinguish two arguments from one glued argument -- both
# render as `A B` -- which the argv assertions depend on being able to tell apart.
echo "gh $*" >> "$ARGV_LOG"
for a in "$@"; do printf 'ARG=[%s]\n' "$a" >> "$ARGV_LOG"; done
if [[ "$*" == *"pr view"* ]]; then echo "feature-branch"; exit 0; fi
# The review search MUST return an item. With an empty result `gh_pr_total` is 0
# and the head-branch-resolution loop never runs, so Step 5 could not observe
# whether --reviews-only wrongly suppressed it.
if [[ "$*" == *"user-review-requested"* ]]; then
  echo '[{"number":1,"id":"PR1","title":"t","createdAt":"2026-01-01T00:00:00Z","repository":{"nameWithOwner":"o/r"},"url":"https://github.com/o/r/pull/1","isDraft":false}]'
  exit 0
fi
echo '[]'; exit 0
STUBEOF
cat > "$RSTUB/glab" <<'STUBEOF'
#!/usr/bin/env bash
echo "glab $*" >> "$ARGV_LOG"
[[ "$*" == *"/user"* ]] && { echo '{"id":1,"username":"tester"}'; exit 0; }
echo '[]'; exit 0
STUBEOF
chmod +x "$RSTUB/gh" "$RSTUB/glab"

: > "$RLOG"
ro_out=$(PATH="$RSTUB:$PATH" ARGV_LOG="$RLOG" collect_items 1)
ro_log=$(cat "$RLOG")

assert_not_contains "--reviews-only skips github_assigned (issues)" "gh search issues" "$ro_log"
assert_not_contains "--reviews-only skips github_authored" "--author=@me" "$ro_log"
assert_not_contains "--reviews-only skips gitlab_authored" "scope=created_by_me" "$ro_log"
assert_not_contains "--reviews-only skips gitlab_assigned" "scope=assigned_to_me" "$ro_log"
assert_not_contains "--reviews-only skips gitlab_issues" "/issues?" "$ro_log"

assert_contains "--reviews-only keeps github_review" "user-review-requested:@me" "$ro_log"
assert_contains "--reviews-only keeps the glab identity lookup" "/user" "$ro_log"
assert_contains "--reviews-only keeps gitlab_review" "reviewer_username=tester" "$ro_log"
# The loop selects on `bucket=="review" or bucket=="authored"`, so review still
# qualifies and it must keep running. Gating it behind !reviews_only would be
# invisible to every other assertion here.
assert_contains "--reviews-only keeps the gh pr view branch-resolution loop" "pr view 1" "$ro_log"

# Drive the real entry point, not the internal function. HOME is the real one so
# session discovery works; the stubs still shadow gh/glab on PATH.
: > "$RLOG"
PATH="$RSTUB:$PATH" ARGV_LOG="$RLOG" HOME="$REAL_HOME" \
  "$BASH" "$SCRIPT" --reviews-only >/dev/null 2>&1
e2e_log=$(cat "$RLOG")
assert_not_contains "entry point forwards --reviews-only (suppression reaches collect)" \
  "gh search issues" "$e2e_log"
assert_contains "entry point still runs the review query" \
  "user-review-requested:@me" "$e2e_log"

# Review Focus 3: gitlab_review interpolates $uid. If /user fails, the error must
# still surface -- and with five requests suppressed it is now a much larger
# share of the result, so rendering it as emptiness would hide most of the run.
IDSTUB="$TMPHOME/idfail_stub"; mkdir -p "$IDSTUB"
cat > "$IDSTUB/glab" <<'STUBEOF'
#!/usr/bin/env bash
echo '{"message":"401 Unauthorized"}'; exit 1
STUBEOF
# gh returns one review PR so the items-count assertion below can discriminate:
# with an empty payload `.items | length` is 0 against any implementation.
cat > "$IDSTUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "gh $*" >> "$ARGV_LOG"
if [[ "$*" == *"user-review-requested"* ]]; then
  echo '[{"number":1,"id":"PR1","title":"t","createdAt":"2026-01-01T00:00:00Z","repository":{"nameWithOwner":"o/r"},"url":"https://github.com/o/r/pull/1","isDraft":false}]'
  exit 0
fi
echo '[]'; exit 0
STUBEOF
chmod +x "$IDSTUB/glab" "$IDSTUB/gh"
: > "$RLOG"
idfail=$(PATH="$IDSTUB:$PATH" ARGV_LOG="$RLOG" collect_items 1)
assert_contains "identity failure reported under --reviews-only" "401" \
  "$(printf '%s' "$idfail" | jq -r '.errors.gitlab_review // ""')"
assert_eq "identity failure keeps the other forge's items and fabricates none" "1" \
  "$(printf '%s' "$idfail" | jq '.items | length')"

# Review Focus 4: _try's truncation check is per-key, so it must still fire when
# only two requests run. A reader seeing 100 items has no way to know more exist.
LIMSTUB="$TMPHOME/limit_stub"; mkdir -p "$LIMSTUB"
cat > "$LIMSTUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$*" == *"user-review-requested"* ]]; then
  /usr/bin/awk 'BEGIN{printf "[";for(i=1;i<=100;i++){printf "%s{\"number\":%d,\"id\":\"R%d\",\"title\":\"t\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"repository\":{\"nameWithOwner\":\"o/r\"},\"url\":\"u\",\"isDraft\":false,\"author\":{\"login\":\"alice\",\"is_bot\":false}}",(i>1?",":""),i,i}printf "]"}'
  exit 0
fi
if [[ "$*" == *"pr view"* ]]; then echo "feature-branch"; exit 0; fi
echo '[]'; exit 0
STUBEOF
cp "$RSTUB/glab" "$LIMSTUB/glab"
chmod +x "$LIMSTUB/gh" "$LIMSTUB/glab"
: > "$RLOG"
limout=$(PATH="$LIMSTUB:$PATH" ARGV_LOG="$RLOG" collect_items 1)
assert_eq "truncation flagged under --reviews-only" "true" \
  "$(printf '%s' "$limout" | jq -r '.limits.github_review // false')"


# --exclude-reviewed: the GitHub term must be its own argv entry. `gh` quotes a
# multi-term positional as one term and the API rejects it while exiting 0.
: > "$RLOG"
xr_out=$(PATH="$RSTUB:$PATH" ARGV_LOG="$RLOG" collect_items 1 1)
xr_log=$(cat "$RLOG")
assert_contains "GitHub negation is a discrete argv entry" "ARG=[-reviewed-by:@me]" "$xr_log"
assert_not_contains "GitHub terms are not glued into one argv entry" \
  "ARG=[user-review-requested:@me -reviewed-by:@me]" "$xr_log"
xr_gh_line=$(printf '%s\n' "$xr_log" | grep '^gh search prs user-review-requested')
xr_suffix="-- -reviewed-by:@me"
assert_eq "GitHub negation pair is the LAST argv (after every flag)" "$xr_suffix" \
  "${xr_gh_line: -${#xr_suffix}}"
assert_contains "exclude-reviewed adds the GitLab exclusion" \
  "not[approved_by_usernames][]=tester" "$xr_log"
assert_contains "GitHub negation immediately follows a -- separator" \
  "ARG=[--]"$'\n'"ARG=[-reviewed-by:@me]" "$xr_log"

# gh search issues has no isDraft field; requesting it would fail github_assigned.
: > "$RLOG"
PATH="$RSTUB:$PATH" ARGV_LOG="$RLOG" collect_items "" >/dev/null
full_log=$(cat "$RLOG")
issues_line=$(printf '%s\n' "$full_log" | grep '^gh search issues')
assert_contains "issues query actually ran" "--json" "$issues_line"
assert_not_contains "gh search issues never requests isDraft" "isDraft" "$issues_line"

# Review Focus 1: the flags are independent. Each must work alone and together.
: > "$RLOG"
solo=$(PATH="$RSTUB:$PATH" ARGV_LOG="$RLOG" "$BASH" -c \
  'OPEN_WORK_LIB=1 source "$1"; collect_items "" 1 >/dev/null' _ "$SCRIPT" 2>&1; cat "$RLOG")
assert_contains "--exclude-reviewed works without --reviews-only" "-reviewed-by:@me" "$solo"
assert_contains "--exclude-reviewed alone still runs authored queries" "--author=@me" "$solo"

# --from-json returns before `collect`, so drive the real collecting path.
: > "$RLOG"
PATH="$RSTUB:$PATH" ARGV_LOG="$RLOG" HOME="$REAL_HOME" \
  "$BASH" "$SCRIPT" --reviews-only --exclude-reviewed >/dev/null 2>&1
both_log=$(cat "$RLOG")
assert_not_contains "both flags together: suppression reaches collect" "gh search issues" "$both_log"
assert_contains "both flags together: exclusion reaches collect" "ARG=[-reviewed-by:@me]" "$both_log"
assert_contains "both flags together: GitLab exclusion reaches collect" \
  "not[approved_by_usernames][]=tester" "$both_log"


# The fields the consuming skills filter and link on must survive shape().
fix_doc="$TMPHOME/doc_fields.json"
cat > "$fix_doc" <<'JSON'
{"sessions":[],
 "items":[{"forge":"github","host":"github.com","repo_id":"github.com/o/r","id":"PR9","display_id":"#9",
           "title":"bump","created_at":"2026-01-01T00:00:00Z","branch":"b","bucket":"review",
           "url":"https://github.com/o/r/pull/9","is_draft":true,"author":"dependabot","is_bot":true}],
 "errors":{},"limits":{}}
JSON
out_doc=$("$BASH" "$SCRIPT" --from-json "$fix_doc")
for f in url is_draft author is_bot; do
  assert_eq "emitted document keeps item field $f" "true" \
    "$(printf '%s' "$out_doc" | jq ".items[0] | has(\"$f\")")"
done
assert_eq "emitted document keeps is_draft value" "true" "$(printf '%s' "$out_doc" | jq '.items[0].is_draft')"
assert_eq "emitted document keeps is_bot value" "true" "$(printf '%s' "$out_doc" | jq '.items[0].is_bot')"
assert_eq "emitted document keeps url value" "https://github.com/o/r/pull/9" \
  "$(printf '%s' "$out_doc" | jq -r '.items[0].url')"

# url, is_draft, author, is_bot on every parser.
gh_pr_fix="$TMPHOME/gh_pr_fields.json"
cat > "$gh_pr_fix" <<'JSON'
[{"number":7,"id":"PR7","title":"add thing","createdAt":"2026-02-01T00:00:00Z",
  "repository":{"nameWithOwner":"o/r"},"url":"https://github.com/o/r/pull/7",
  "isDraft":true,"author":{"login":"alice","is_bot":false,"type":"User"}},
 {"number":8,"id":"PR8","title":"bump dep","createdAt":"2026-02-01T00:00:00Z",
  "repository":{"nameWithOwner":"o/r"},"url":"https://github.com/o/r/pull/8",
  "isDraft":false,"author":{"login":"dependabot","is_bot":true,"type":"Bot"}}]
JSON
gh_pr_item=$(parse_gh_prs review < "$gh_pr_fix")
assert_eq "gh PR maps url"      "https://github.com/o/r/pull/7" "$(printf '%s' "$gh_pr_item" | jq -r '.[0].url')"
assert_eq "gh PR maps is_draft" "true"  "$(printf '%s' "$gh_pr_item" | jq -r '.[0].is_draft')"
assert_eq "gh PR maps author"   "alice" "$(printf '%s' "$gh_pr_item" | jq -r '.[0].author')"
assert_eq "gh PR maps is_bot"   "false" "$(printf '%s' "$gh_pr_item" | jq -r '.[0].is_bot')"
assert_eq "gh PR author is a string, never the object" "string" \
  "$(printf '%s' "$gh_pr_item" | jq -r '.[0].author | type')"
assert_eq "gh PR non-draft maps is_draft false" "false" "$(printf '%s' "$gh_pr_item" | jq -r '.[1].is_draft')"
assert_eq "gh PR bot author maps is_bot true"   "true"  "$(printf '%s' "$gh_pr_item" | jq -r '.[1].is_bot')"

glab_mr_fix="$TMPHOME/glab_mr_fields.json"
cat > "$glab_mr_fix" <<'JSON'
[{"id":99,"iid":12,"title":"fix thing","created_at":"2026-02-02T00:00:00Z",
  "web_url":"https://gitlab.com/g/s/r/-/merge_requests/12","source_branch":"fix",
  "draft":true,"author":{"username":"bob","bot":true}},
 {"id":100,"iid":13,"title":"ready thing","created_at":"2026-02-02T00:00:00Z",
  "web_url":"https://gitlab.com/g/s/r/-/merge_requests/13","source_branch":"ready",
  "draft":false,"author":{"username":"erin","bot":false}}]
JSON
glab_mr_item=$(parse_glab_mrs review < "$glab_mr_fix")
assert_eq "glab MR maps url"      "https://gitlab.com/g/s/r/-/merge_requests/12" "$(printf '%s' "$glab_mr_item" | jq -r '.[0].url')"
assert_eq "glab MR maps is_draft" "true" "$(printf '%s' "$glab_mr_item" | jq -r '.[0].is_draft')"
assert_eq "glab MR maps author"   "bob"  "$(printf '%s' "$glab_mr_item" | jq -r '.[0].author')"
assert_eq "glab MR maps is_bot"   "true" "$(printf '%s' "$glab_mr_item" | jq -r '.[0].is_bot')"
assert_eq "glab MR non-draft maps is_draft false" "false" "$(printf '%s' "$glab_mr_item" | jq -r '.[1].is_draft')"
assert_eq "glab MR human author maps is_bot false" "false" "$(printf '%s' "$glab_mr_item" | jq -r '.[1].is_bot')"

# is_draft is not an all-bucket field: `gh search issues --json` has no isDraft and
# GitLab issue payloads carry no .draft, so both issue parsers emit a literal.
gh_iss_fix="$TMPHOME/gh_iss_fields.json"
cat > "$gh_iss_fix" <<'JSON'
[{"number":4,"id":"I4","title":"bug","createdAt":"2026-02-03T00:00:00Z",
  "repository":{"nameWithOwner":"o/r"},"url":"https://github.com/o/r/issues/4",
  "author":{"login":"carol","is_bot":false}},
 {"number":5,"id":"I5","title":"bot bug","createdAt":"2026-02-03T00:00:00Z",
  "repository":{"nameWithOwner":"o/r"},"url":"https://github.com/o/r/issues/5",
  "author":{"login":"renovate","is_bot":true}}]
JSON
gh_iss_item=$(parse_gh_issues assigned < "$gh_iss_fix")
assert_eq "gh issue emits is_draft false from a payload with no draft field" "false" \
  "$(printf '%s' "$gh_iss_item" | jq -r '.[0].is_draft')"
assert_eq "gh issue still maps url"    "https://github.com/o/r/issues/4" "$(printf '%s' "$gh_iss_item" | jq -r '.[0].url')"
assert_eq "gh issue still maps author" "carol" "$(printf '%s' "$gh_iss_item" | jq -r '.[0].author')"
assert_eq "gh issue maps is_bot"       "false" "$(printf '%s' "$gh_iss_item" | jq -r '.[0].is_bot')"
assert_eq "gh issue bot author maps is_bot true" "true" "$(printf '%s' "$gh_iss_item" | jq -r '.[1].is_bot')"

glab_iss_fix="$TMPHOME/glab_iss_fields.json"
cat > "$glab_iss_fix" <<'JSON'
[{"id":77,"iid":5,"title":"task","created_at":"2026-02-04T00:00:00Z",
  "web_url":"https://gitlab.com/g/s/r/-/issues/5","author":{"username":"dave","bot":false}},
 {"id":78,"iid":6,"title":"bot task","created_at":"2026-02-04T00:00:00Z",
  "web_url":"https://gitlab.com/g/s/r/-/issues/6","author":{"username":"ghost-bot","bot":true}}]
JSON
glab_iss_item=$(parse_glab_issues assigned < "$glab_iss_fix")
assert_eq "glab issue emits is_draft false" "false" \
  "$(printf '%s' "$glab_iss_item" | jq -r '.[0].is_draft')"
assert_eq "glab issue maps author" "dave" "$(printf '%s' "$glab_iss_item" | jq -r '.[0].author')"
assert_eq "glab issue maps url" "https://gitlab.com/g/s/r/-/issues/5" \
  "$(printf '%s' "$glab_iss_item" | jq -r '.[0].url')"
assert_eq "glab issue maps is_bot" "false" "$(printf '%s' "$glab_iss_item" | jq -r '.[0].is_bot')"
assert_eq "glab issue bot author maps is_bot true" "true" "$(printf '%s' "$glab_iss_item" | jq -r '.[1].is_bot')"

: > "$RLOG"
PATH="$RSTUB:$PATH" ARGV_LOG="$RLOG" collect_items 1 >/dev/null
assert_contains "github_review requests the author field" "url,isDraft,author" "$(cat "$RLOG")"


echo
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
