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
    for c in jq git sort paste grep sed tr cat mktemp date basename dirname head; do
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

rc=0; out=$(PATH="$NOGLAB" "$BASH" "$SCRIPT" --repo "$REPO" 2>&1) || rc=$?
assert_eq "runs without glab on PATH" 0 "$rc"
assert_eq "output without glab parses as JSON" github "$(jq -r .repo.forge <<<"$out" 2>/dev/null)"

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

REPO_JSON=$(si_repo_json "$REPO")
# raw_finding <source> <native_id> <kind> <severity_raw> <origin> <ids_csv> [fix_version] [depth] [scope]
raw_finding() {
    jq -nc --arg s "$1" --arg id "$2" --arg kind "$3" --arg sev "$4" --arg origin "$5" --arg ids "$6" \
        --arg fix "${7:-}" --arg depth "${8:-}" --arg scope "${9:-}" '
        def opt: if . == "" or . == "null" then null else . end;
        {source: $s, native_id: $id, kind: $kind, severity_raw: ($sev | opt), severity_origin: $origin,
         title: ("finding " + $id),
         package: (if $kind == "dependency" or $kind == "container"
                   then {name: "org.example:lib", version: "1.2.3", fix_version: ($fix | opt),
                         depth: ($depth | opt), scope: ($scope | opt)}
                   else null end),
         identifiers: (if $ids == "" then [] else $ids | split(",") end),
         locations: [{file: "pom.xml", line: null}],
         url: ("https://example.com/" + $s + "/" + $id), solution: null, epss: null, as_of: null}'
}
# raw findings on stdin -> si_shape input, one ok result per source
shape_input() {
    jq -sc --argjson repo "$REPO_JSON" '{repo: $repo, results: (group_by(.source)
        | map({source: {name: .[0].source, status: "ok", reason: null, count: 0}, findings: .}))}'
}
one_finding()   { raw_finding "$1" "$2" "$3" "$4" "$5" "" | shape_input; }
dep_finding()   { raw_finding "$1" "$2" dependency high source "$3" | shape_input; }
two_deps()      { { raw_finding "$1" 1 dependency high source "$2"; raw_finding "$3" 2 dependency high source "$4"; } | shape_input; }
two_deps_fix()  { { raw_finding "$1" 1 dependency high source "$2" "$3"; raw_finding "$4" 2 dependency high source "$5" "$6"; } | shape_input; }
two_deps_sev()  { { raw_finding "$1" 1 dependency "$2" source CVE-2024-1; raw_finding "$3" 2 dependency "$4" source CVE-2024-1; } | shape_input; }
two_deps_pkg()  { { raw_finding "$1" 1 dependency high source "$2" "" "$3" "$4"; raw_finding "$5" 2 dependency high source "$6" "" "$7" "$8"; } | shape_input; }
bridge_three()  { { raw_finding gitlab 1 dependency high source CVE-2024-1
                    raw_finding github 2 dependency high source GHSA-AAAA,CVE-2024-1
                    raw_finding moderne 3 dependency high source GHSA-AAAA; } | shape_input; }
two_code_same_rule() { { raw_finding github 1 code high source js/sql-injection; raw_finding github 2 code high source js/sql-injection; } | shape_input; }
dup_native_id() { { raw_finding github 7 dependency high source CVE-2024-1; raw_finding github 7 dependency high source CVE-2024-1; } | shape_input; }
mixed_severities() { { raw_finding github 5 code "" source ""; raw_finding github 4 code low source ""
                       raw_finding github 3 code medium source ""; raw_finding github 2 code high source ""
                       raw_finding github 1 code critical source ""; } | shape_input; }
ids_finding()   { raw_finding "$1" "$2" "$3" high source "$4,$5,$6" | shape_input; }
one_container() { raw_finding "$1" "$2" container high source "$3" | shape_input; }
two_containers() { { raw_finding "$1" 1 container high source "$2"; raw_finding "$3" 2 container high source "$4"; } | shape_input; }

echo "si_shape"
shape() { si_shape <<<"$1"; }
# severity table
for pair in "Critical:critical" "ERROR:high" "moderate:medium" "warning:medium" "INFO:low" "note:low" ":unknown" "weird:unknown"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  got=$(shape "$(one_finding github 1 code "$raw" source)" | jq -r '.findings[0].severity')
  assert_eq "severity $raw -> $want" "$want" "$got"
done
assert_eq "policy origin forces critical" critical "$(shape "$(one_finding github 2 secret 'n/a (secret)' policy)" | jq -r '.findings[0].severity')"
# keys
assert_eq "CVE key" "CVE-2024-1" "$(shape "$(dep_finding gitlab 9 CVE-2024-1)" | jq -r '.findings[0].key')"
assert_eq "GHSA key when no CVE" "GHSA-AAAA" "$(shape "$(dep_finding github 3 GHSA-AAAA)" | jq -r '.findings[0].key')"
assert_eq "mixed-case ids upper-cased and merged" 1 "$(shape "$(two_deps gitlab cve-2024-1 moderne CVE-2024-1)" | jq '.findings | length')"
assert_eq "unidentified dependency key" "pkg:org.example:lib@1.2.3" "$(shape "$(dep_finding moderne 7 '')" | jq -r '.findings[0].key')"
assert_eq "code key" "github:code:42" "$(shape "$(one_finding github 42 code high source)" | jq -r '.findings[0].key')"
# merge rules
m=$(shape "$(two_deps gitlab CVE-2024-1 moderne CVE-2024-1)")
assert_eq "same CVE merges" 1 "$(jq '.findings|length' <<<"$m")"
assert_eq "merged keeps both sources" 2 "$(jq '.findings[0].sources|length' <<<"$m")"
assert_eq "merged count arithmetic" "$(jq '.findings|length' <<<"$m")" "$(jq '([.sources[].count]|add) - .summary.merged' <<<"$m")"
assert_eq "transitive merge via GHSA+CVE bridge" 1 "$(shape "$(bridge_three)" | jq '.findings|length')"
assert_eq "two unidentified same pkg@ver merge" 1 "$(shape "$(two_deps gitlab '' moderne '')" | jq '.findings|length')"
assert_eq "unidentified never joins identified" 2 "$(shape "$(two_deps gitlab CVE-2024-1 moderne '')" | jq '.findings|length')"
assert_eq "two CVEs same pkg stay two" 2 "$(shape "$(two_deps gitlab CVE-2024-1 moderne CVE-2024-2)" | jq '.findings|length')"
assert_eq "code findings never merge" 2 "$(shape "$(two_code_same_rule)" | jq '.findings|length')"
assert_eq "duplicate native id collapses" 1 "$(shape "$(dup_native_id)" | jq '.sources[0].count')"
# fix candidates, severity, ordering
f=$(shape "$(two_deps_fix gitlab CVE-1 1.2.4 moderne CVE-1 1.2.4)")
assert_eq "agreeing candidates set fix_version" 1.2.4 "$(jq -r '.findings[0].package.fix_version' <<<"$f")"
f=$(shape "$(two_deps_fix gitlab CVE-1 1.2.4 moderne CVE-1 1.3.0)")
assert_eq "disagreeing candidates null fix_version" null "$(jq -r '.findings[0].package.fix_version' <<<"$f")"
assert_eq "both candidates kept" 2 "$(jq '.findings[0].package.fix_candidates|length' <<<"$f")"
assert_eq "highest severity wins" critical "$(shape "$(two_deps_sev gitlab low moderne critical)" | jq -r '.findings[0].severity')"
o=$(shape "$(mixed_severities)")
assert_eq "ordered by severity then key" "critical high medium low unknown" "$(jq -r '[.findings[].severity]|join(" ")' <<<"$o")"
assert_eq "summary counts" '{"critical":1,"high":1,"medium":1,"low":1,"unknown":1,"merged":0}' "$(jq -c .summary <<<"$o")"
assert_eq "package null for code" null "$(shape "$(one_finding github 42 code high source)" | jq -r '.findings[0].package')"
# identifiers and containers
i=$(shape "$(ids_finding github 5 code 'cve-2024-9' 'js/sql-injection' 'ghsa-zzzz')")
assert_eq "only CVE/GHSA upper-cased" '["CVE-2024-9","js/sql-injection","GHSA-ZZZZ"]' "$(jq -c '.findings[0].identifiers' <<<"$i")"
assert_eq "unidentified containers do not merge" 2 "$(shape "$(two_containers gitlab '' github '')" | jq '.findings|length')"
assert_eq "unidentified container key" "gitlab:container:gid://gitlab/Vulnerability/8" "$(shape "$(one_container gitlab 'gid://gitlab/Vulnerability/8' '')" | jq -r '.findings[0].key')"
assert_eq "containers merge on CVE" 1 "$(shape "$(two_containers gitlab CVE-2024-3 github CVE-2024-3)" | jq '.findings|length')"
# merged package fields: gitlab member has depth null, scope null; moderne member has depth transitive, scope test
p=$(shape "$(two_deps_pkg gitlab CVE-2024-1 null null moderne CVE-2024-1 transitive test)" | jq -c '.findings[0].package|{name,version,depth,scope}')
assert_eq "merged package takes first-source name/version, first non-null depth/scope" '{"name":"org.example:lib","version":"1.2.3","depth":"transitive","scope":"test"}' "$p"

echo
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
