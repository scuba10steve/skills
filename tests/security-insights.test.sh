#!/usr/bin/env bash
# security-insights.test.sh — assertions for security-insights.sh
set -uo pipefail

SCRIPT_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )"
SCRIPT="$SCRIPT_DIR/../skills/security-insights/scripts/security-insights.sh"

TMPHOME="$(mktemp -d "${TMPDIR:-/tmp}/security-insights-test.XXXXXX")"
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

mkrepo() {
    git init -q "$1"
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name t
}

REPO="$TMPHOME/repo";       mkrepo "$REPO"
git -C "$REPO" remote add origin https://github.com/o/r.git
mkdir "$REPO/sub"
NOREMOTE="$TMPHOME/noremote"; mkrepo "$NOREMOTE"
JVMREPO="$TMPHOME/jvm";     mkrepo "$JVMREPO"
: > "$JVMREPO/pom.xml"

ARGV_LOG="$TMPHOME/argv.log"; export ARGV_LOG
: > "$ARGV_LOG"

STUB="$TMPHOME/stub"; mkdir "$STUB"
for cli in gh glab; do
    known=KNOWN_GH; [[ "$cli" == glab ]] && known=KNOWN_GL
    cat > "$STUB/$cli" <<FAKE
#!/usr/bin/env bash
echo "$cli \$*" >> "\$ARGV_LOG"
if [[ "\$1 \$2 \$3" == "auth status --hostname" ]]; then
    if [[ -n "\${$known:-}" && "\$4" == "\${$known}" ]]; then exit 0; fi
    echo "not logged in" >&2
    exit 1
fi
echo '[]'
FAKE
done
cat > "$STUB/mod" <<'FAKE'
#!/usr/bin/env bash
echo "mod $*" >> "$ARGV_LOG"
exit 0
FAKE
chmod +x "$STUB"/*

mkpath() {
    local dir="$1" skip="$2" c p
    mkdir -p "$dir"
    for c in jq git sort paste grep sed tr cat mktemp date basename dirname; do
        [[ "$c" == "$skip" ]] && continue
        p=$(command -v "$c") && ln -s "$p" "$dir/$c"
    done
    for c in gh glab mod; do
        [[ "$c" == "$skip" ]] && continue
        ln -s "$STUB/$c" "$dir/$c"
    done
}
NOJQ="$TMPHOME/nojq";     mkpath "$NOJQ" jq
NOGH="$TMPHOME/nogh";     mkpath "$NOGH" gh
NOGLAB="$TMPHOME/noglab"; mkpath "$NOGLAB" glab
NOMOD="$TMPHOME/nomod";   mkpath "$NOMOD" mod

PATH="$STUB:$PATH"

echo "skeleton"
out=$("$BASH" "$SCRIPT" --help 2>&1); rc=$?
assert_eq "--help exits 0" 0 "$rc"; assert_contains "--help shows usage" "Usage:" "$out"
rc=0; out=$("$BASH" "$SCRIPT" --bogus 2>&1) || rc=$?
assert_eq "unknown flag exits 1" 1 "$rc"; assert_contains "unknown flag explains itself" "Unknown" "$out"
rc=0; out=$("$BASH" "$SCRIPT" --repo "$TMPHOME" 2>&1) || rc=$?
assert_eq "non-repo exits 2" 2 "$rc"
rc=0; out=$(PATH="$NOJQ" "$BASH" "$SCRIPT" --repo "$REPO" 2>&1) || rc=$?
assert_eq "missing jq exits 1" 1 "$rc"; assert_contains "missing jq names jq" "jq is required" "$out"
out=$(SECURITY_INSIGHTS_LIB=1 "$BASH" -c 'source "$1"' _ "$SCRIPT" 2>&1)
assert_not_contains "library mode does not dispatch" '"repo"' "$out"

echo "si_parse_remote"
SECURITY_INSIGHTS_LIB=1 source "$SCRIPT"
assert_eq "scp form"            $'gitlab.example.com\tgroup/sub/repo' "$(si_parse_remote 'git@gitlab.example.com:group/sub/repo.git')"
assert_eq "ssh with port"       $'gitlab.example.com\tgroup/repo'     "$(si_parse_remote 'ssh://git@gitlab.example.com:2222/group/repo.git')"
assert_eq "https with creds"    $'github.com\towner/repo'             "$(si_parse_remote 'https://u:t@github.com:443/owner/repo/')"
assert_eq "unparseable is empty" "" "$(si_parse_remote 'file:///tmp/x')"

echo "si_detect_forge"
assert_eq "glab-known host is gitlab"   gitlab  "$(KNOWN_GL=code.example.com si_detect_forge code.example.com)"
assert_eq "gh-known host is github"     github  "$(KNOWN_GH=ghe.example.com  si_detect_forge ghe.example.com)"
assert_eq "github.com fallback"         github  "$(si_detect_forge github.com)"
assert_eq "gitlab substring fallback"   gitlab  "$(si_detect_forge gitlab.example.net)"
assert_eq "unknown host"                unknown "$(si_detect_forge code.example.org)"
assert_contains "auth probe passes --hostname" "glab auth status --hostname code.example.com" "$(cat "$ARGV_LOG")"

echo "si_repo_json"
assert_eq "forge from origin" github "$(si_repo_json "$REPO" | jq -r .forge)"
assert_eq "path from origin"  o/r    "$(si_repo_json "$REPO" | jq -r .path)"
assert_eq "subdirectory resolves to root" "$(cd "$REPO" && pwd -P)" "$(si_repo_root "$REPO/sub")"
assert_eq "no remote is unknown" unknown "$(si_repo_json "$NOREMOTE" | jq -r .forge)"
out=$("$BASH" "$SCRIPT" --repo "$NOREMOTE")
assert_eq "no remote skips both forge sources" 2 "$(jq '[.sources[] | select(.reason=="no git remote")] | length' <<<"$out")"

echo
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
