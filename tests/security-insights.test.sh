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
git -C "$JVMREPO" remote add origin https://github.com/o/jvm.git
GRADLEREPO="$TMPHOME/gradle"; mkrepo "$GRADLEREPO"
: > "$GRADLEREPO/settings.gradle.kts"
NODEREPO="$TMPHOME/node";   mkrepo "$NODEREPO";  : > "$NODEREPO/package.json"
PYREPO="$TMPHOME/py";       mkrepo "$PYREPO";    : > "$PYREPO/requirements.txt"
GOREPO="$TMPHOME/go";       mkrepo "$GOREPO";    : > "$GOREPO/go.mod"
CSREPO="$TMPHOME/cs";       mkrepo "$CSREPO";    : > "$CSREPO/App.csproj"
CSSUBREPO="$TMPHOME/cssub"; mkrepo "$CSSUBREPO"; mkdir "$CSSUBREPO/sub" "$CSSUBREPO/Dir.csproj"; : > "$CSSUBREPO/sub/Other.csproj"
MIXREPO="$TMPHOME/mix";     mkrepo "$MIXREPO";   : > "$MIXREPO/build.gradle"; : > "$MIXREPO/package.json"

GHFIX="$TMPHOME/ghfix"; mkdir "$GHFIX"; export GHFIX
cat > "$GHFIX/dependabot.json" <<'JSON'
[{"number":1,"html_url":"https://github.com/o/r/security/dependabot/1",
  "security_advisory":{"severity":"high","summary":"Lib is vulnerable","cve_id":"CVE-2024-1","ghsa_id":"GHSA-AAAA"},
  "dependency":{"package":{"name":"org.example:lib"},"manifest_path":"pom.xml","scope":"development"},
  "security_vulnerability":{"vulnerable_version_range":"= 1.2.3","first_patched_version":{"identifier":"1.2.4"}}}]
JSON
cat > "$GHFIX/code-scanning.json" <<'JSON'
[{"number":7,"html_url":"https://github.com/o/r/security/code-scanning/7",
  "rule":{"id":"java/sql-injection","severity":"warning","description":"SQL injection","tags":["security","external/cwe/cwe-079"]},
  "most_recent_instance":{"location":{"path":"src/A.java","start_line":12}}}]
JSON
cat > "$GHFIX/secret-scanning.json" <<'JSON'
[{"number":3,"html_url":"https://github.com/o/r/security/secret-scanning/3","secret_type":"aws_key",
  "secret_type_display_name":"AWS Key","locations_url":"https://api.github.com/repos/o/r/secret-scanning/alerts/3/locations"}]
JSON

GLFIX="$TMPHOME/glfix"; mkdir "$GLFIX"; export GLFIX
cat > "$GLFIX/good_page1.json" <<'JSON'
{"data":{"project":{"vulnerabilities":{
  "pageInfo":{"hasNextPage":true,"endCursor":"c1"},
  "nodes":[
   {"id":"gid://gitlab/Vulnerability/1","title":"Lib is vulnerable","severity":"Critical","reportType":"DEPENDENCY_SCANNING",
    "webUrl":"https://gitlab.example.com/group/sub/repo/-/security/vulnerabilities/1","solution":"Upgrade to 1.2.4",
    "identifiers":[{"externalType":"CVE","externalId":"CVE-2024-1"},{"externalType":"GEMNASIUM","externalId":"gemnasium-1"}],
    "location":{"file":"pom.xml","dependency":{"package":{"name":"org.example/lib"},"version":"1.2.3"}}},
   {"id":"gid://gitlab/Vulnerability/2","title":"SQL injection","severity":"Info","reportType":"SAST",
    "webUrl":"https://gitlab.example.com/group/sub/repo/-/security/vulnerabilities/2","solution":null,
    "identifiers":[{"externalType":"cwe","externalId":"89"}],
    "location":{"file":"src/B.java","startLine":40}}]}}}}
JSON
cat > "$GLFIX/good_page2.json" <<'JSON'
{"data":{"project":{"vulnerabilities":{
  "pageInfo":{"hasNextPage":false,"endCursor":"c2"},
  "nodes":[
   {"id":"gid://gitlab/Vulnerability/3","title":"Leaked token","severity":"High","reportType":"SECRET_DETECTION",
    "webUrl":"https://gitlab.example.com/group/sub/repo/-/security/vulnerabilities/3","solution":null,
    "identifiers":[],"location":{"file":"config/app.yml","startLine":3}}]}}}}
JSON
cat > "$GLFIX/errors.json" <<'JSON'
{"errors":[{"message":"The resource that you are attempting to access does not exist or you don't have permission"}]}
JSON
cat > "$GLFIX/null_project.json" <<'JSON'
{"data":{"project":null}}
JSON
cat > "$GLFIX/null_vulns.json" <<'JSON'
{"data":{"project":{"vulnerabilities":null}}}
JSON
cat > "$GLFIX/null_nodes.json" <<'JSON'
{"data":{"project":{"vulnerabilities":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":null}}}}
JSON
MODFIX="$TMPHOME/modfix"; mkdir "$MODFIX"; export MODFIX
cat > "$MODFIX/list_good.json" <<'JSON'
[{"origin":"github.com","path":"o/jvm","branch":"main","rootDir":"file:///work/jvm"}]
JSON
cat > "$MODFIX/history_good.json" <<'JSON'
{"20261119090000-zzzzz":{"recipeId":"org.openrewrite.java.format.AutoFormat","recipeOptions":{},"dataTablesProduced":[]},
 "20261120140200-abcde":{"recipeId":"org.openrewrite.java.dependencies.DependencyVulnerabilityCheck","recipeOptions":{"scope":"test"},
  "dataTablesProduced":["org.openrewrite.java.dependencies.table.VulnerabilityReport"]}}
JSON
cat > "$MODFIX/history_other_recipe.json" <<'JSON'
{"20261119090000-zzzzz":{"recipeId":"org.openrewrite.java.format.AutoFormat","recipeOptions":{},"dataTablesProduced":[]}}
JSON
cat > "$MODFIX/history_noscope.json" <<'JSON'
{"20261120140200-abcde":{"recipeId":"org.openrewrite.java.dependencies.DependencyVulnerabilityCheck","recipeOptions":{},
  "dataTablesProduced":["org.openrewrite.java.dependencies.table.VulnerabilityReport"]}}
JSON
cat > "$MODFIX/history_nodejs.json" <<'JSON'
{"20261121100000-nodej":{"recipeId":"org.openrewrite.nodejs.security.DependencyVulnerabilityCheck","recipeOptions":{},
  "dataTablesProduced":["org.openrewrite.nodejs.table.VulnerabilityReport"]}}
JSON
cat > "$MODFIX/history_java_and_nodejs.json" <<'JSON'
{"20261101080000-older":{"recipeId":"org.openrewrite.nodejs.security.DependencyVulnerabilityCheck","recipeOptions":{},
  "dataTablesProduced":["org.openrewrite.nodejs.table.VulnerabilityReport"]},
 "20261120140200-abcde":{"recipeId":"org.openrewrite.java.dependencies.DependencyVulnerabilityCheck","recipeOptions":{"scope":"test"},
  "dataTablesProduced":["org.openrewrite.java.dependencies.table.VulnerabilityReport"]},
 "20261121100000-nodej":{"recipeId":"org.openrewrite.nodejs.security.DependencyVulnerabilityCheck","recipeOptions":{},
  "dataTablesProduced":["org.openrewrite.nodejs.table.VulnerabilityReport"]}}
JSON
printf 'not json' > "$MODFIX/history_bad.txt"
printf '[]' > "$MODFIX/list_empty.json"
cat > "$MODFIX/study_good.json" <<'JSON'
[
{"repositoryOrigin":"github.com","repositoryPath":"o/jvm","repositoryBranch":"main","projectName":"app","cve":"CVE-2024-1","groupId":"org.example","artifactId":"lib","version":"1.2.3","fixedVersion":"1.2.4","lastAffectedVersion":"1.2.3","versionWithinDelta":"","summary":"Lib is vulnerable","severity":"CRITICAL","depth":2,"CWEs":"CWE-79, 611","epss":0.42},
{"repositoryOrigin":"github.com","repositoryPath":"o/jvm","repositoryBranch":"main","projectName":"app","cve":"","groupId":"org.example","artifactId":"other","version":"2.0.0","fixedVersion":"","lastAffectedVersion":"2.0.0","versionWithinDelta":"","summary":"Other is vulnerable","severity":"MODERATE","depth":0,"CWEs":"","epss":null},
{"repositoryOrigin":"github.com","repositoryPath":"o/elsewhere","repositoryBranch":"main","projectName":"x","cve":"CVE-2024-9","groupId":"org.example","artifactId":"far","version":"9.0.0","fixedVersion":"9.0.1","lastAffectedVersion":"9.0.0","versionWithinDelta":"","summary":"Far","severity":"HIGH","depth":"Direct","CWEs":"","epss":0.1}
]
JSON
cat > "$MODFIX/study_nodejs.json" <<'JSON'
[{"repositoryOrigin":"github.com","repositoryPath":"o/jvm","repositoryBranch":"main","projectName":"web","cve":"CVE-2024-7","packageName":"lodash","version":"4.17.20","fixedVersion":"4.17.21","summary":"Prototype pollution in lodash","severity":"HIGH","direct":false,"cwes":"CWE-1321"}]
JSON
cat > "$MODFIX/study_bad_row.json" <<'JSON'
[{"repositoryOrigin":"github.com","repositoryPath":"o/jvm","cve":"CVE-2024-1","groupId":"org.example","artifactId":"lib","version":"1.2.3","fixedVersion":"1.2.4","severity":"HIGH","depth":0},
 "not a row"]
JSON

# gl_pages <page1 fixture> [page2 fixture] -> the pages the glab stub serves, from page 1
gl_pages() {
    rm -f "$GLFIX"/live*.json "$GLFIX/counter"
    cp "$GLFIX/$1" "$GLFIX/live1.json"
    [[ -z "${2:-}" ]] || cp "$GLFIX/$2" "$GLFIX/live2.json"
}
# mod_use <kind>=<fixture>... -> the list/history/study output the mod stub serves
mod_use() {
    local kv
    for kv in "$@"; do cp "$MODFIX/${kv#*=}" "$MODFIX/live-${kv%%=*}.json"; done
}
mod_use list=list_good.json history=history_good.json study=study_good.json

ARGV_LOG="$TMPHOME/argv.log"; export ARGV_LOG
: > "$ARGV_LOG"
argv() { cat "$ARGV_LOG"; }
reason_of() { jq -r .source.reason; }

STUB="$TMPHOME/stub"; mkdir "$STUB"
cat > "$TMPHOME/forge-stub" <<'FAKE'
#!/usr/bin/env bash
cli=${0##*/}
echo "$cli $*" >> "$ARGV_LOG"
if [[ "$1 $2 $3" == "auth status --hostname" ]]; then
    case "$cli" in gh) known=${KNOWN_GH:-} ;; *) known=${KNOWN_GL:-} ;; esac
    if [[ -n "$known" && "$4" == "$known" ]]; then exit 0; fi
    case "$cli" in gh) echo "$4" >&2 ;; *) echo >&2; echo ERROR >&2 ;; esac
    echo "not logged in" >&2
    exit 1
fi
if [[ "$cli" == gh && "$1" == api ]]; then
    case "$*" in
        *dependabot/alerts*) ep=dependabot ;;
        *code-scanning/alerts*) ep=code-scanning ;;
        *secret-scanning/alerts*) ep=secret-scanning ;;
        *) ep=unknown ;;
    esac
    [[ -f "$GHFIX/$ep.silent" ]] && exit 1
    rc=0; [[ -f "$GHFIX/$ep.rc" ]] && rc=$(tr -d '[:space:]' < "$GHFIX/$ep.rc")
    if [[ -n "$rc" && "$rc" != 0 ]]; then
        msg=$(cat "$GHFIX/$ep.msg" 2>/dev/null || echo failed)
        jq -nc --arg m "$msg" '{message: $m}'
        echo "gh: $msg (HTTP 403)" >&2
        exit 1
    fi
    jq -c '.[]' "$GHFIX/$ep.json"
    exit 0
fi
if [[ "$1 $2" == "api graphql" ]]; then
    n=0; [[ -f "$GLFIX/counter" ]] && n=$(cat "$GLFIX/counter")
    n=$((n+1)); echo "$n" > "$GLFIX/counter"
    cat "$GLFIX/live$n.json"
    exit 0
fi
echo '[]'
FAKE
ln -s "$TMPHOME/forge-stub" "$STUB/gh"
ln -s "$TMPHOME/forge-stub" "$STUB/glab"
cat > "$STUB/mod" <<'FAKE'
#!/usr/bin/env bash
echo "mod $*" >> "$ARGV_LOG"
case "$1" in
    list) cat "$MODFIX/live-list.json" ;;
    run-history) cat "$MODFIX/live-history.json" ;;
    study) if [[ -f "$MODFIX/study.rc" ]]; then exit 1; fi
           case "$*" in
               *"--data-table org.openrewrite.nodejs.table.VulnerabilityReport"*) cat "$MODFIX/study_nodejs.json" ;;
               *) cat "$MODFIX/live-study.json" ;;
           esac ;;
    build|run) if [[ -f "$MODFIX/$1.rc" ]]; then echo "$1 exploded" >&2; echo "second line" >&2; exit 1; fi
               if [[ "$1" == build && -f "$MODFIX/build.writes" ]]; then cp "$MODFIX/list_good.json" "$MODFIX/live-list.json"; fi ;;
esac
exit 0
FAKE
chmod +x "$TMPHOME/forge-stub" "$STUB/mod"

mkpath() {
    local dir="$1" skip="$2" c p
    mkdir -p "$dir"
    for c in jq git sort paste grep sed tr cat mktemp date basename dirname head rm mv; do
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
assert_contains "auth probe passes --hostname" "glab auth status --hostname code.example.com" "$(argv)"

assert_eq "first useful stderr line skips host and ERROR" "not logged in" "$(printf '\n  gl.example.com\nERROR\nnot logged in\n' | si_first_err 1 gl.example.com)"
assert_eq "no useful stderr line" "exit 4, no error output" "$(printf '\nERROR\n' | si_first_err 4 gl.example.com)"

echo "si_repo_json"
assert_eq "forge from origin" github "$(si_repo_json "$REPO" | jq -r .forge)"
assert_eq "path from origin"  o/r    "$(si_repo_json "$REPO" | jq -r .path)"
assert_eq "subdirectory resolves to root" "$(cd "$REPO" && pwd -P)" "$(si_repo_root "$REPO/sub")"
assert_eq "no remote is unknown" unknown "$(si_repo_json "$NOREMOTE" | jq -r .forge)"
out=$("$BASH" "$SCRIPT" --repo "$NOREMOTE")
assert_eq "no remote skips both forge sources" 2 "$(jq '[.sources[] | select(.reason=="no git remote")] | length' <<<"$out")"

REPO_JSON=$(si_repo_json "$REPO")
# raw_finding <source> <native_id> <kind> <severity_raw> <origin> <ids_csv> [fix_version] [depth] [scope] [package] [version]
raw_finding() {
    jq -nc --arg s "$1" --arg id "$2" --arg kind "$3" --arg sev "$4" --arg origin "$5" --arg ids "$6" \
        --arg fix "${7:-}" --arg depth "${8:-}" --arg scope "${9:-}" --arg pname "${10:-org.example:lib}" --arg ver "${11:-1.2.3}" '
        def opt: if . == "" or . == "null" then null else . end;
        {source: $s, native_id: $id, kind: $kind, severity_raw: ($sev | opt), severity_origin: $origin,
         title: ("finding " + $id),
         package: (if $kind == "dependency" or $kind == "container"
                   then {name: $pname, version: ($ver | opt), fix_version: ($fix | opt),
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
# one source result on stdin -> si_shape output
shape_result() { jq -c --argjson repo "$REPO_JSON" '{repo: $repo, results: [.]}' | si_shape; }
one_finding()   { raw_finding "$1" "$2" "$3" "$4" "$5" "" | shape_input; }
dep_finding()   { raw_finding "$1" "$2" dependency high source "$3" | shape_input; }
two_deps()      { { raw_finding "$1" 1 dependency high source "$2"; raw_finding "$3" 2 dependency high source "$4"; } | shape_input; }

echo "si_shape"
# severity table
for pair in "Critical:critical" "ERROR:high" "moderate:medium" "warning:medium" "INFO:low" "note:low" ":unknown" "weird:unknown"; do
  raw="${pair%%:*}"; want="${pair##*:}"
  got=$(one_finding github 1 code "$raw" source | si_shape | jq -r '.findings[0].severity')
  assert_eq "severity $raw -> $want" "$want" "$got"
done
assert_eq "policy origin forces critical" critical "$(one_finding github 2 secret 'n/a (secret)' policy | si_shape | jq -r '.findings[0].severity')"
# keys
assert_eq "CVE key" "CVE-2024-1" "$(dep_finding gitlab 9 CVE-2024-1 | si_shape | jq -r '.findings[0].key')"
assert_eq "GHSA key when no CVE" "GHSA-AAAA" "$(dep_finding github 3 GHSA-AAAA | si_shape | jq -r '.findings[0].key')"
assert_eq "mixed-case ids upper-cased and merged" 1 "$(two_deps gitlab cve-2024-1 moderne CVE-2024-1 | si_shape | jq '.findings | length')"
assert_eq "unidentified dependency key" "pkg:org.example:lib@1.2.3" "$(dep_finding moderne 7 '' | si_shape | jq -r '.findings[0].key')"
assert_eq "code key" "github:code:42" "$(one_finding github 42 code high source | si_shape | jq -r '.findings[0].key')"
# merge rules
m=$(two_deps gitlab CVE-2024-1 moderne CVE-2024-1 | si_shape)
assert_eq "same CVE merges" 1 "$(jq '.findings|length' <<<"$m")"
assert_eq "merged keeps both sources" 2 "$(jq '.findings[0].sources|length' <<<"$m")"
assert_eq "merged count arithmetic" "$(jq '.findings|length' <<<"$m")" "$(jq '([.sources[].count]|add) - .summary.merged' <<<"$m")"
assert_eq "transitive merge via GHSA+CVE bridge" 1 "$({ raw_finding gitlab 1 dependency high source CVE-2024-1
    raw_finding github 2 dependency high source GHSA-AAAA,CVE-2024-1
    raw_finding moderne 3 dependency high source GHSA-AAAA; } | shape_input | si_shape | jq '.findings|length')"
assert_eq "two unidentified same pkg@ver merge" 1 "$(two_deps gitlab '' moderne '' | si_shape | jq '.findings|length')"
assert_eq "unidentified never joins identified" 2 "$(two_deps gitlab CVE-2024-1 moderne '' | si_shape | jq '.findings|length')"
assert_eq "two CVEs same pkg stay two" 2 "$(two_deps gitlab CVE-2024-1 moderne CVE-2024-2 | si_shape | jq '.findings|length')"
assert_eq "code findings never merge" 2 "$({ raw_finding github 1 code high source js/sql-injection
    raw_finding github 2 code high source js/sql-injection; } | shape_input | si_shape | jq '.findings|length')"
assert_eq "duplicate native id collapses" 1 "$({ raw_finding github 7 dependency high source CVE-2024-1
    raw_finding github 7 dependency high source CVE-2024-1; } | shape_input | si_shape | jq '.sources[0].count')"
# fix candidates, severity, ordering
f=$({ raw_finding gitlab 1 dependency high source CVE-1 1.2.4; raw_finding moderne 2 dependency high source CVE-1 1.2.4; } | shape_input | si_shape)
assert_eq "agreeing candidates set fix_version" 1.2.4 "$(jq -r '.findings[0].package.fix_version' <<<"$f")"
f=$({ raw_finding gitlab 1 dependency high source CVE-1 1.2.4; raw_finding moderne 2 dependency high source CVE-1 1.3.0; } | shape_input | si_shape)
assert_eq "disagreeing candidates null fix_version" null "$(jq -r '.findings[0].package.fix_version' <<<"$f")"
assert_eq "both candidates kept" 2 "$(jq '.findings[0].package.fix_candidates|length' <<<"$f")"
assert_eq "highest severity wins" critical "$({ raw_finding gitlab 1 dependency low source CVE-2024-1
    raw_finding moderne 2 dependency critical source CVE-2024-1; } | shape_input | si_shape | jq -r '.findings[0].severity')"
o=$({ raw_finding github 5 code "" source ""; raw_finding github 4 code low source ""
      raw_finding github 3 code medium source ""; raw_finding github 2 code high source ""
      raw_finding github 1 code critical source ""; } | shape_input | si_shape)
assert_eq "ordered by severity then key" "critical high medium low unknown" "$(jq -r '[.findings[].severity]|join(" ")' <<<"$o")"
assert_eq "summary counts" '{"critical":1,"high":1,"medium":1,"low":1,"unknown":1,"merged":0}' "$(jq -c .summary <<<"$o")"
assert_eq "package null for code" null "$(one_finding github 42 code high source | si_shape | jq -r '.findings[0].package')"
# identifiers and containers
i=$(raw_finding github 5 code high source 'cve-2024-9,js/sql-injection,ghsa-zzzz' | shape_input | si_shape)
assert_eq "only CVE/GHSA upper-cased" '["CVE-2024-9","js/sql-injection","GHSA-ZZZZ"]' "$(jq -c '.findings[0].identifiers' <<<"$i")"
assert_eq "code finding with a CVE keeps the native key" "github:code:5" "$(jq -r '.findings[0].key' <<<"$i")"
assert_eq "CWE forms normalised to CWE-n" '["CWE-79","CWE-611","CWE-89","CWE-0"]' "$(raw_finding github 6 code high source 'cwe-079,cwe611,Cwe89,CWE-000' | shape_input | si_shape | jq -c '.findings[0].identifiers')"
assert_eq "bare digits kept verbatim" '["12345"]' "$(raw_finding github 8 code high source 12345 | shape_input | si_shape | jq -c '.findings[0].identifiers')"
assert_eq "unidentified containers do not merge" 2 "$({ raw_finding gitlab 1 container high source ''
    raw_finding github 2 container high source ''; } | shape_input | si_shape | jq '.findings|length')"
assert_eq "unidentified container key" "gitlab:container:gid://gitlab/Vulnerability/8" "$(raw_finding gitlab 'gid://gitlab/Vulnerability/8' container high source '' | shape_input | si_shape | jq -r '.findings[0].key')"
assert_eq "containers merge on CVE" 1 "$({ raw_finding gitlab 1 container high source CVE-2024-3
    raw_finding github 2 container high source CVE-2024-3; } | shape_input | si_shape | jq '.findings|length')"
# merged package fields: gitlab member has depth null, scope null; moderne member has depth transitive, scope test
p=$({ raw_finding gitlab 1 dependency high source CVE-2024-1 "" null null
      raw_finding moderne 2 dependency high source CVE-2024-1 "" transitive test; } | shape_input | si_shape | jq -c '.findings[0].package|{name,version,depth,scope}')
assert_eq "merged package takes first-source name/version, first non-null depth/scope" '{"name":"org.example:lib","version":"1.2.3","depth":"transitive","scope":"test"}' "$p"
c=$({ raw_finding moderne 1 dependency high source CVE-2024-5 1.2.4 "" "" org.ex:lib 1.2.3
      raw_finding moderne 2 dependency high source CVE-2024-5 2.0.1 "" "" org.ex:lib-core 2.0.0
      raw_finding github 3 dependency high source CVE-2024-5 "" "" "" org.ex:lib null; } | shape_input | si_shape)
assert_eq "multi-artifact CVE is one finding" 1 "$(jq '.findings|length' <<<"$c")"
assert_eq "multi-artifact package is the first member's" org.ex:lib "$(jq -r '.findings[0].package.name' <<<"$c")"
assert_eq "fix_version only from same-package candidates" 1.2.4 "$(jq -r '.findings[0].package.fix_version' <<<"$c")"
assert_eq "other artifact's candidate kept with its package" true "$(jq '.findings[0].package.fix_candidates|any(.package=="org.ex:lib-core" and .version=="2.0.1")' <<<"$c")"
assert_eq "sources carry each member's package" '["org.ex:lib","org.ex:lib-core"]' "$(jq -c '[.findings[0].sources[].package.name]|unique' <<<"$c")"
assert_eq "source package carries version and fix" '{"name":"org.ex:lib-core","version":"2.0.0","fix_version":"2.0.1"}' "$(jq -c '.findings[0].sources[]|select(.id=="2").package' <<<"$c")"
assert_eq "code source package is null" null "$(one_finding github 42 code high source | si_shape | jq -c '.findings[0].sources[0].package')"
v=$({ raw_finding github 1 dependency high source CVE-2024-6 "" "" "" org.example:lib null
      raw_finding moderne 2 dependency high source CVE-2024-6 1.2.4 "" "" org.example:lib 1.2.3; } | shape_input | si_shape)
assert_eq "merged version is first non-null same-package version" 1.2.3 "$(jq -r '.findings[0].package.version' <<<"$v")"
rc=0; n=$(one_finding github 1 code high source | jq -c '.results[0].findings = null' | si_shape) || rc=$?
assert_eq "null findings still shapes" "0 0" "$rc $(jq '.findings|length' <<<"$n")"
rc=0; n=$(dep_finding github 1 CVE-2024-1 | jq -c '.results[0].findings[0].identifiers = [null, "CVE-2024-1"] | .results[0].findings[0].locations = null' | si_shape) || rc=$?
assert_eq "null identifier and locations still shape" '0 ["CVE-2024-1"] []' "$rc $(jq -c '.findings[0].identifiers' <<<"$n") $(jq -c '.findings[0].locations' <<<"$n")"
e=$({ raw_finding moderne 1 dependency high source CVE-2024-8 | jq -c '.ecosystem = "nodejs"'
      raw_finding github 2 dependency high source CVE-2024-8; } | shape_input | si_shape)
assert_eq "moderne ecosystem lands on its source entry" nodejs "$(jq -r '.findings[0].sources[]|select(.name=="moderne").ecosystem' <<<"$e")"
assert_eq "github source entry has no ecosystem" false "$(jq '.findings[0].sources[]|select(.name=="github")|has("ecosystem")' <<<"$e")"
r=$(one_finding moderne 1 code high source | jq -c '.results[0].findings = null' | si_shape)
assert_eq "malformed source result replaced" "skipped moderne result malformed" "$(jq -r '.sources[]|select(.name=="moderne")|"\(.status) \(.reason)"' <<<"$r")"
r=$(one_finding moderne 1 code high source | jq -c '.results[0].source = null' | si_shape)
assert_eq "result without a source object replaced" "skipped unknown result malformed 0" "$(jq -r '.sources[0]|"\(.status) \(.reason) \(.count)"' <<<"$r")"

echo "si_source_github"
export KNOWN_GH=github.com
r=$(si_source_github github.com o/r)
assert_eq "all reads ok -> ok" ok "$(jq -r .source.status <<<"$r")"
d=$(jq -c '.findings[]|select(.native_id=="dependabot:1")' <<<"$r")
assert_eq "dependabot severity raw" high "$(jq -r .severity_raw <<<"$d")"
assert_eq "dependabot scope" development "$(jq -r .package.scope <<<"$d")"
assert_eq "dependabot identifiers" '["CVE-2024-1","GHSA-AAAA"]' "$(jq -c .identifiers <<<"$d")"
assert_eq "dependabot exact range is version" 1.2.3 "$(jq -r .package.version <<<"$d")"
cs=$(jq -c '.findings[]|select(.native_id=="code-scanning:7")' <<<"$r")
assert_eq "code scanning CWE tag becomes CWE-n" '["java/sql-injection","CWE-79"]' "$(shape_result <<<"$r" | jq -c '.findings[]|select(.key=="github:code:code-scanning:7").identifiers')"
assert_eq "code scanning falls back to rule.severity" warning "$(jq -r .severity_raw <<<"$cs")"
assert_eq "code scanning location" 'src/A.java:12' "$(jq -r '.locations[0]|"\(.file):\(.line)"' <<<"$cs")"
assert_eq "secret is policy critical" policy "$(jq -r '.findings[]|select(.kind=="secret").severity_origin' <<<"$r")"
assert_eq "secret has no locations" 0 "$(jq '.findings[]|select(.kind=="secret").locations|length' <<<"$r")"
assert_contains "gh api carries --hostname" "gh api --hostname github.com repos/o/r/" "$(argv)"
assert_contains "gh api uses explicit path" "repos/o/r/dependabot/alerts" "$(argv)"
cp "$GHFIX/code-scanning.json" "$GHFIX/code-scanning.orig"; jq '.[0].number = 1' "$GHFIX/code-scanning.orig" > "$GHFIX/code-scanning.json"
c=$(si_source_github github.com o/r | shape_result)
assert_eq "same alert number across endpoints keeps both findings" "code dependency" "$(jq -r '[.findings[]|select(.sources[0].id|test("(^|:)1$"))|.kind]|sort|join(" ")' <<<"$c")"
mv "$GHFIX/code-scanning.orig" "$GHFIX/code-scanning.json"
echo 1 > "$GHFIX/code-scanning.rc"; echo "Code scanning is not enabled for this repository" > "$GHFIX/code-scanning.msg"
r=$(si_source_github github.com o/r)
assert_eq "one read 403 -> partial" partial "$(jq -r .source.status <<<"$r")"
assert_eq "failed read named" 'HTTP 403: Code scanning is not enabled for this repository' "$(jq -r '.source.reads[]|select(.name=="code-scanning").reason' <<<"$r")"
printf '[]' > "$GHFIX/dependabot.json"; : > "$GHFIX/code-scanning.rc"
r=$(si_source_github github.com o/r)
assert_eq "empty array read is ok" ok "$(jq -r '.source.reads[]|select(.name=="dependabot").status' <<<"$r")"
cp "$GHFIX/secret-scanning.json" "$GHFIX/secret-scanning.good"; printf '[1]' > "$GHFIX/secret-scanning.json"
r=$(si_source_github github.com o/r)
assert_contains "unmappable read is skipped as not understood" "github output not understood: " "$(jq -r '.source.reads[]|select(.name=="secret-scanning").reason' <<<"$r")"
assert_eq "unmappable read leaves source partial" partial "$(jq -r .source.status <<<"$r")"
cp "$GHFIX/secret-scanning.good" "$GHFIX/secret-scanning.json"
jq -n '[range(300) | {number: ., html_url: "https://github.com/o/r/security/dependabot/\(.)",
    security_advisory: {severity: "high", summary: "advisory \(.)", cve_id: "CVE-2024-\(.)", ghsa_id: "GHSA-\(.)",
                        description: ("x" * 4000)},
    dependency: {package: {name: "org.example:lib\(.)"}, manifest_path: "pom.xml", scope: "runtime"},
    security_vulnerability: {vulnerable_version_range: "= 1.0.0", first_patched_version: {identifier: "1.0.1"}}}]' > "$GHFIX/dependabot.json"
r=$(si_source_github github.com o/r 2>&1)
assert_eq "300 alerts -> ok" ok "$(jq -r .source.status <<<"$r" 2>/dev/null)"
assert_eq "300 alerts -> 300 dependabot findings" 300 "$(jq '[.findings[]|select(.kind=="dependency")]|length' <<<"$r" 2>/dev/null)"
printf '[]' > "$GHFIX/dependabot.json"
out=$(SECURITY_INSIGHTS_LIB= KNOWN_GH=github.com "$BASH" "$SCRIPT" --repo "$REPO")
assert_eq "collect includes github source" 1 "$(jq '[.sources[]|select(.name=="github" and .status=="ok")]|length' <<<"$out")"
for e in dependabot code-scanning secret-scanning; do echo 1 > "$GHFIX/$e.rc"; done
r=$(si_source_github github.com o/r)
assert_eq "all reads fail -> skipped" skipped "$(jq -r .source.status <<<"$r")"
assert_eq "all-reads reason names each read" "dependabot: HTTP 403: failed; code-scanning: HTTP 403: Code scanning is not enabled for this repository; secret-scanning: HTTP 403: failed" "$(reason_of <<<"$r")"
: > "$GHFIX/dependabot.silent"
assert_eq "silent failure reason" "HTTP ?: exit 1, no error output" "$(si_source_github github.com o/r | jq -r '.source.reads[]|select(.name=="dependabot").reason')"
rm -f "$GHFIX/dependabot.silent"
assert_eq "gh absent -> skipped" "gh not installed" "$(PATH="$NOGH" si_source_github github.com o/r | reason_of)"
assert_eq "gh unauthenticated -> skipped" "gh auth status --hostname github.com failed: not logged in" "$(KNOWN_GH= si_source_github github.com o/r | reason_of)"

echo "si_source_gitlab"
gl_pages good_page1.json good_page2.json
export KNOWN_GL=gitlab.example.com
: > "$ARGV_LOG"
r=$(si_source_gitlab gitlab.example.com group/sub/repo)
assert_eq "two pages read" 2 "$(grep -c 'api graphql' "$ARGV_LOG")"
assert_contains "graphql call carries --hostname" "glab api graphql --hostname gitlab.example.com" "$(argv)"
assert_contains "graphql call passes fullPath" "fullPath=group/sub/repo" "$(argv)"
assert_contains "page 2 passes the cursor" "after=c1" "$(argv)"
assert_eq "status ok" ok "$(jq -r .source.status <<<"$r")"
assert_eq "three findings across pages" 3 "$(jq '.findings|length' <<<"$r")"
v1=$(jq -c '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/1")' <<<"$r")
assert_eq "dependency kind from reportType" dependency "$(jq -r .kind <<<"$v1")"
assert_eq "package name colon form" "org.example:lib" "$(jq -r .package.name <<<"$v1")"
assert_eq "package version" 1.2.3 "$(jq -r .package.version <<<"$v1")"
assert_eq "fix version from solution" 1.2.4 "$(jq -r .package.fix_version <<<"$v1")"
assert_eq "identifiers keep only cve/ghsa/cwe" '["CVE-2024-1"]' "$(jq -c .identifiers <<<"$v1")"
assert_eq "bare cwe id gains CWE- prefix" '["CWE-89"]' "$(shape_result <<<"$r" | jq -c '.findings[]|select(.key=="gitlab:code:gid://gitlab/Vulnerability/2").identifiers')"
assert_eq "INFO severity raw kept" Info "$(jq -r '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/2").severity_raw' <<<"$r")"
assert_eq "sast location" 'src/B.java:40' "$(jq -r '.findings[]|select(.kind=="code").locations[0]|"\(.file):\(.line)"' <<<"$r")"
assert_eq "code package null" null "$(jq -c '.findings[]|select(.kind=="code").package' <<<"$r")"
assert_eq "secret kind" secret "$(jq -r '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/3").kind' <<<"$r")"
assert_eq "empty identifiers is an array" '[]' "$(jq -c '.findings[]|select(.kind=="secret").identifiers' <<<"$r")"
assert_eq "scope null" null "$(jq -r '.findings[0].package.scope' <<<"$r")"
assert_eq "no reads for gitlab" null "$(jq -c '.source.reads' <<<"$r")"
gl_pages errors.json
assert_eq "errors[] on page 1 -> skipped with message" "The resource that you are attempting to access does not exist or you don't have permission" "$(si_source_gitlab gitlab.example.com g/r | reason_of)"
gl_pages null_project.json
assert_eq "null project reason" "project g/r not found on gitlab.example.com or not visible to this token" "$(si_source_gitlab gitlab.example.com g/r | reason_of)"
gl_pages null_vulns.json
assert_eq "null vulnerabilities reason" "vulnerability report unavailable on g/r (requires GitLab Ultimate)" "$(si_source_gitlab gitlab.example.com g/r | reason_of)"
gl_pages good_page1.json errors.json
r=$(si_source_gitlab gitlab.example.com g/r)
assert_eq "page 2 failure -> partial" partial "$(jq -r .source.status <<<"$r")"
assert_contains "partial reason names page" "page 2 failed:" "$(reason_of <<<"$r")"
assert_eq "page 1 findings kept" 2 "$(jq '.findings|length' <<<"$r")"
gl_pages null_nodes.json
r=$(si_source_gitlab gitlab.example.com g/r)
assert_eq "null nodes -> skipped, not ok" skipped "$(jq -r .source.status <<<"$r")"
assert_contains "null nodes reason" "gitlab output not understood: " "$(reason_of <<<"$r")"
gl_pages good_page1.json null_nodes.json
r=$(si_source_gitlab gitlab.example.com g/r)
assert_contains "null nodes on page 2 -> partial" "partial page 2 failed: gitlab output not understood: " "$(jq -r '"\(.source.status) \(.source.reason)"' <<<"$r")"
assert_eq "glab absent -> skipped" "glab not installed" "$(PATH="$NOGLAB" si_source_gitlab gitlab.example.com g/r | reason_of)"
assert_eq "glab unauthenticated -> skipped" "glab auth status --hostname gitlab.example.com failed: not logged in" "$(KNOWN_GL= si_source_gitlab gitlab.example.com g/r | reason_of)"

echo "si_source_moderne"
assert_eq "no manifest" "no supported dependency manifest; DependencyVulnerabilityCheck covers Maven/Gradle, npm, Python, Go and NuGet" "$(si_source_moderne "$REPO" 0 | reason_of)"
assert_eq "java detected" java "$(si_mod_ecosystems "$JVMREPO")"
assert_eq "gradle settings detected" java "$(si_mod_ecosystems "$GRADLEREPO")"
assert_eq "nodejs detected" nodejs "$(si_mod_ecosystems "$NODEREPO")"
assert_eq "python detected" python "$(si_mod_ecosystems "$PYREPO")"
assert_eq "golang detected" golang "$(si_mod_ecosystems "$GOREPO")"
assert_eq "csharp detected by csproj glob" csharp "$(si_mod_ecosystems "$CSREPO")"
assert_eq "csproj in subdir or as a directory is not detected" "" "$(si_mod_ecosystems "$CSSUBREPO")"
assert_eq "two ecosystems in order" $'java\nnodejs' "$(si_mod_ecosystems "$MIXREPO")"
assert_eq "mod absent" "mod not installed" "$(PATH="$NOMOD" si_source_moderne "$JVMREPO" 0 | reason_of)"
assert_eq "mod probed before JVM check" "mod not installed" "$(PATH="$NOMOD" si_source_moderne "$REPO" 0 | reason_of)"
mod_use list=list_empty.json
assert_eq "no LST" "no Moderne LST for this repository; run: mod build ." "$(si_source_moderne "$JVMREPO" 0 | reason_of)"
assert_eq "no java run names the ecosystem" "no java DependencyVulnerabilityCheck run for this repository; run: mod run . --recipe org.openrewrite.java.dependencies.DependencyVulnerabilityCheck" "$(mod_use list=list_good.json history=history_other_recipe.json; si_source_moderne "$JVMREPO" 0 | reason_of)"
mod_use history=history_bad.txt
assert_eq "unparseable history" "run-history output not understood" "$(si_source_moderne "$JVMREPO" 0 | reason_of)"
mod_use history=history_good.json
touch "$MODFIX/study.rc"
assert_eq "study failure without stderr" "mod study failed: exit 1, no error output" "$(si_source_moderne "$JVMREPO" 0 | reason_of)"
rm -f "$MODFIX/study.rc"
: > "$ARGV_LOG"; r=$(si_source_moderne "$JVMREPO" 0)
assert_contains "study uses --recipe-run" "--recipe-run=20261120140200-abcde" "$(argv)"
assert_not_contains "study never uses --last-recipe-run" "--last-recipe-run" "$(argv)"
assert_not_contains "no build without flag" "mod build" "$(argv)"
assert_eq "status ok" ok "$(jq -r .source.status <<<"$r")"
assert_eq "cve identifier" "CVE-2024-1" "$(jq -r '.findings[0].identifiers[0]' <<<"$r")"
assert_eq "package colon form" "org.example:lib" "$(jq -r '.findings[0].package.name' <<<"$r")"
assert_eq "fix version" "1.2.4" "$(jq -r '.findings[0].package.fix_version' <<<"$r")"
assert_eq "numeric depth maps to transitive/direct" '["transitive","direct"]' "$(jq -c '[.findings[].package.depth]' <<<"$r")"
assert_eq "MODERATE raw kept" MODERATE "$(jq -r '.findings[1].severity_raw' <<<"$r")"
ids=$(shape_result <<<"$r" | jq -c '.findings[]|select(.key=="CVE-2024-1").identifiers')
assert_eq "CWEs split into identifiers" 2 "$(jq 'map(select(startswith("CWE-")))|length' <<<"$ids")"
assert_eq "bare CWE digits prefixed" '["CVE-2024-1","CWE-79","CWE-611"]' "$ids"
assert_eq "as_of derived from run id" true "$(jq '.findings[0].as_of|startswith("2026-11-20T14:02:00")' <<<"$r")"
assert_eq "as_of carries a UTC offset" true "$(jq '.findings[0].as_of|test("T14:02:00[+-][0-9]{2}:[0-9]{2}$")' <<<"$r")"
assert_eq "rows for other repo dropped" 2 "$(jq '.findings|length' <<<"$r")"
assert_eq "empty cve cell -> no advisory id" 0 "$(jq '.findings[1].identifiers|map(select(startswith("CVE-")))|length' <<<"$r")"
assert_eq "empty identifiers is an array" '[]' "$(jq -c '.findings[1].identifiers' <<<"$r")"
assert_eq "empty fixedVersion is null" null "$(jq -c '.findings[1].package.fix_version' <<<"$r")"
assert_eq "numeric depth 2 maps to transitive" transitive "$(jq -r '.findings[0].package.depth' <<<"$r")"
assert_eq "epss number" 0.42 "$(jq -c '.findings[0].epss' <<<"$r")"
assert_eq "epss null" null "$(jq -c '.findings[1].epss' <<<"$r")"
assert_eq "native id by row index" "VulnerabilityReport:row:0" "$(jq -r '.findings[0].native_id' <<<"$r")"
assert_eq "scope from run options" test "$(jq -r '.findings[0].package.scope' <<<"$r")"
mod_use history=history_noscope.json
assert_eq "scope null when run has none" null "$(si_source_moderne "$JVMREPO" 0 | jq -r '.findings[0].package.scope')"
mod_use history=history_good.json
mod_steps() { grep -oE 'mod (build|run) ' "$ARGV_LOG" | sed 's/ $//' | paste -sd'|' -; }
: > "$ARGV_LOG"; si_source_moderne "$JVMREPO" 1 >/dev/null
assert_eq "--moderne-run builds then runs" "mod build|mod run" "$(mod_steps)"
: > "$MODFIX/build.rc"
assert_eq "build failure skips" "mod build failed: build exploded" "$(si_source_moderne "$JVMREPO" 1 2>/dev/null | reason_of)"
rm -f "$MODFIX/build.rc"; : > "$MODFIX/run.rc"
assert_eq "run failure skips" "mod run failed: run exploded" "$(si_source_moderne "$JVMREPO" 1 2>/dev/null | reason_of)"
rm -f "$MODFIX/run.rc"
assert_eq "settings.gradle.kts passes the JVM check" ok "$(si_source_moderne "$GRADLEREPO" 0 | jq -r .source.status)"
mod_use study=study_bad_row.json
r=$(si_source_moderne "$JVMREPO" 0)
assert_eq "non-object row -> skipped" skipped "$(jq -r .source.status <<<"$r")"
assert_contains "non-object row reason" "moderne output not understood: " "$(reason_of <<<"$r")"
mod_use study=study_good.json list=list_empty.json
: > "$MODFIX/build.writes"; : > "$ARGV_LOG"
r=$(si_source_moderne "$JVMREPO" 1 2>/dev/null)
assert_eq "--moderne-run recovers from no LST" ok "$(jq -r .source.status <<<"$r")"
assert_eq "no-LST recovery builds once then runs" "mod build|mod run" "$(mod_steps)"
rm -f "$MODFIX/build.writes"; mod_use list=list_good.json
mod_use history=history_nodejs.json study=study_nodejs.json
: > "$ARGV_LOG"; r=$(si_source_moderne "$NODEREPO" 0)
assert_eq "nodejs read ok" ok "$(jq -r .source.status <<<"$r")"
assert_eq "nodejs recipe used in study" 1 "$(grep -c -- "--data-table org.openrewrite.nodejs.table.VulnerabilityReport" "$ARGV_LOG")"
assert_eq "packageName mapped" lodash "$(jq -r '.findings[0].package.name' <<<"$r")"
assert_eq "direct:false maps to transitive" transitive "$(jq -r '.findings[0].package.depth' <<<"$r")"
assert_eq "lower-case cwes split" '["CVE-2024-7","CWE-1321"]' "$(jq -c '.findings[0].identifiers' <<<"$r")"
assert_eq "ecosystem on finding" nodejs "$(jq -r '.findings[0].ecosystem' <<<"$r")"
assert_eq "nodejs read named by ecosystem" '[{"name":"nodejs","status":"ok"}]' "$(jq -c .source.reads <<<"$r")"
mod_use history=history_java_and_nodejs.json study=study_good.json
: > "$ARGV_LOG"; r=$(si_source_moderne "$MIXREPO" 0)
assert_eq "two reads" 2 "$(jq '.source.reads|length' <<<"$r")"
assert_eq "both ok" ok "$(jq -r .source.status <<<"$r")"
assert_eq "findings from both tables" 3 "$(jq '.findings|length' <<<"$r")"
assert_eq "run-history read once" 1 "$(grep -c '^mod run-history' "$ARGV_LOG")"
assert_contains "latest run per recipe" "--recipe-run=20261121100000-nodej --data-table org.openrewrite.nodejs.table.VulnerabilityReport" "$(argv)"
assert_eq "java rows tagged java" '["java","java","nodejs"]' "$(jq -c '[.findings[].ecosystem]' <<<"$r")"
assert_eq "rows from two tables survive shaping" 3 "$(shape_result <<<"$r" | jq '.findings|length')"
mod_use history=history_good.json
r=$(si_source_moderne "$MIXREPO" 0)
assert_eq "one missing run -> partial" partial "$(jq -r .source.status <<<"$r")"
assert_eq "missing read named" "no nodejs DependencyVulnerabilityCheck run for this repository; run: mod run . --recipe org.openrewrite.nodejs.security.DependencyVulnerabilityCheck" "$(jq -r '.source.reads[]|select(.name=="nodejs").reason' <<<"$r")"
assert_eq "partial keeps the read ecosystem's findings" 2 "$(jq '.findings|length' <<<"$r")"
mod_use history=history_other_recipe.json
assert_eq "no run in any ecosystem names each" "java: no java DependencyVulnerabilityCheck run for this repository; run: mod run . --recipe org.openrewrite.java.dependencies.DependencyVulnerabilityCheck; nodejs: no nodejs DependencyVulnerabilityCheck run for this repository; run: mod run . --recipe org.openrewrite.nodejs.security.DependencyVulnerabilityCheck" "$(si_source_moderne "$MIXREPO" 0 | reason_of)"
mod_use history=history_good.json
: > "$ARGV_LOG"; si_source_moderne "$MIXREPO" 1 >/dev/null
assert_eq "one build then two runs" "mod build|mod run|mod run" "$(mod_steps)"
assert_eq "runs name both recipes" 2 "$(grep -c -E -- '--recipe org.openrewrite.(java.dependencies|nodejs.security).DependencyVulnerabilityCheck' "$ARGV_LOG")"
assert_eq "runs in detection order" "java nodejs" "$(grep -oE -- '^mod run .* --recipe org.openrewrite.(java|nodejs)' "$ARGV_LOG" | sed -E 's/.*org.openrewrite.//' | paste -sd' ' -)"
out=$(SECURITY_INSIGHTS_LIB= "$BASH" "$SCRIPT" --repo "$JVMREPO" 2>/dev/null)
assert_eq "collect includes moderne source" 1 "$(jq '[.sources[]|select(.name=="moderne" and .status=="ok")]|length' <<<"$out")"

echo
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
