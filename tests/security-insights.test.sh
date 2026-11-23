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

GHFIX="$TMPHOME/ghfix"; mkdir "$GHFIX"; export GHFIX
cat > "$GHFIX/dependabot.json" <<'JSON'
[{"number":1,"html_url":"https://github.com/o/r/security/dependabot/1",
  "security_advisory":{"severity":"high","summary":"Lib is vulnerable","cve_id":"CVE-2024-1","ghsa_id":"GHSA-AAAA"},
  "dependency":{"package":{"name":"org.example:lib"},"manifest_path":"pom.xml","scope":"development"},
  "security_vulnerability":{"vulnerable_version_range":"= 1.2.3","first_patched_version":{"identifier":"1.2.4"}}}]
JSON
cat > "$GHFIX/code-scanning.json" <<'JSON'
[{"number":7,"html_url":"https://github.com/o/r/security/code-scanning/7",
  "rule":{"id":"java/sql-injection","severity":"warning","description":"SQL injection"},
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
cat > "$GLFIX/page2.json" <<'JSON'
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
cat > "$MODFIX/study.json" <<'JSON'
[
{"repositoryOrigin":"github.com","repositoryPath":"o/jvm","repositoryBranch":"main","projectName":"app","cve":"CVE-2024-1","groupId":"org.example","artifactId":"lib","version":"1.2.3","fixedVersion":"1.2.4","lastAffectedVersion":"1.2.3","versionWithinDelta":"","summary":"Lib is vulnerable","severity":"CRITICAL","depth":"Transitive","CWEs":"CWE-79, 611","epss":0.42},
{"repositoryOrigin":"github.com","repositoryPath":"o/jvm","repositoryBranch":"main","projectName":"app","cve":"","groupId":"org.example","artifactId":"other","version":"2.0.0","fixedVersion":"","lastAffectedVersion":"2.0.0","versionWithinDelta":"","summary":"Other is vulnerable","severity":"MODERATE","depth":"Direct","CWEs":"","epss":null},
{"repositoryOrigin":"github.com","repositoryPath":"o/elsewhere","repositoryBranch":"main","projectName":"x","cve":"CVE-2024-9","groupId":"org.example","artifactId":"far","version":"9.0.0","fixedVersion":"9.0.1","lastAffectedVersion":"9.0.0","versionWithinDelta":"","summary":"Far","severity":"HIGH","depth":"Direct","CWEs":"","epss":0.1}
]
JSON
cp "$MODFIX/list_good.json" "$MODFIX/list.json"; cp "$MODFIX/history_good.json" "$MODFIX/history.json"
reset_counter() { rm -f "$GLFIX/counter"; }

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
if [[ "\$1" == "api" && "$cli" == "gh" ]]; then
    case "\$*" in
        *dependabot/alerts*) ep=dependabot ;;
        *code-scanning/alerts*) ep=code-scanning ;;
        *secret-scanning/alerts*) ep=secret-scanning ;;
        *) ep=unknown ;;
    esac
    rc=0; [[ -f "\$GHFIX/\$ep.rc" ]] && rc=\$(tr -d '[:space:]' < "\$GHFIX/\$ep.rc")
    if [[ -n "\$rc" && "\$rc" != 0 ]]; then
        msg=\$(cat "\$GHFIX/\$ep.msg" 2>/dev/null || echo failed)
        jq -nc --arg m "\$msg" '{message: \$m}'
        echo "gh: \$msg (HTTP 403)" >&2
        exit 1
    fi
    jq -c '.[]' "\$GHFIX/\$ep.json"
    exit 0
fi
if [[ "\$1 \$2" == "api graphql" ]]; then
    n=0; [[ -f "\$GLFIX/counter" ]] && n=\$(cat "\$GLFIX/counter")
    n=\$((n+1)); echo "\$n" > "\$GLFIX/counter"
    cat "\$GLFIX/page\$n.json"
    exit 0
fi
echo '[]'
FAKE
done
cat > "$STUB/mod" <<'FAKE'
#!/usr/bin/env bash
echo "mod $*" >> "$ARGV_LOG"
case "$1" in
    list) cat "$MODFIX/list.json" ;;
    run-history) cat "$MODFIX/history.json" ;;
    study) cat "$MODFIX/study.json" ;;
    build|run) if [[ -f "$MODFIX/$1.rc" ]]; then echo "$1 exploded" >&2; echo "second line" >&2; exit 1; fi ;;
esac
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
assert_eq "code finding with a CVE keeps the native key" "github:code:5" "$(jq -r '.findings[0].key' <<<"$i")"
assert_eq "unidentified containers do not merge" 2 "$(shape "$(two_containers gitlab '' github '')" | jq '.findings|length')"
assert_eq "unidentified container key" "gitlab:container:gid://gitlab/Vulnerability/8" "$(shape "$(one_container gitlab 'gid://gitlab/Vulnerability/8' '')" | jq -r '.findings[0].key')"
assert_eq "containers merge on CVE" 1 "$(shape "$(two_containers gitlab CVE-2024-3 github CVE-2024-3)" | jq '.findings|length')"
# merged package fields: gitlab member has depth null, scope null; moderne member has depth transitive, scope test
p=$(shape "$(two_deps_pkg gitlab CVE-2024-1 null null moderne CVE-2024-1 transitive test)" | jq -c '.findings[0].package|{name,version,depth,scope}')
assert_eq "merged package takes first-source name/version, first non-null depth/scope" '{"name":"org.example:lib","version":"1.2.3","depth":"transitive","scope":"test"}' "$p"

echo "si_source_github"
export KNOWN_GH=github.com
r=$(si_source_github github.com o/r)
assert_eq "all reads ok -> ok" ok "$(jq -r .source.status <<<"$r")"
assert_eq "dependabot severity raw" high "$(jq -r '.findings[]|select(.native_id=="1").severity_raw' <<<"$r")"
assert_eq "dependabot scope" development "$(jq -r '.findings[]|select(.native_id=="1").package.scope' <<<"$r")"
assert_eq "dependabot identifiers" '["CVE-2024-1","GHSA-AAAA"]' "$(jq -c '.findings[]|select(.native_id=="1").identifiers' <<<"$r")"
assert_eq "dependabot exact range is version" 1.2.3 "$(jq -r '.findings[]|select(.native_id=="1").package.version' <<<"$r")"
assert_eq "code scanning falls back to rule.severity" warning "$(jq -r '.findings[]|select(.native_id=="7").severity_raw' <<<"$r")"
assert_eq "code scanning location" 'src/A.java:12' "$(jq -r '.findings[]|select(.native_id=="7").locations[0]|"\(.file):\(.line)"' <<<"$r")"
assert_eq "secret is policy critical" policy "$(jq -r '.findings[]|select(.kind=="secret").severity_origin' <<<"$r")"
assert_eq "secret has no locations" 0 "$(jq '.findings[]|select(.kind=="secret").locations|length' <<<"$r")"
assert_contains "gh api carries --hostname" "--hostname github.com" "$(cat "$ARGV_LOG")"
assert_contains "gh api uses explicit path" "repos/o/r/dependabot/alerts" "$(cat "$ARGV_LOG")"
echo 1 > "$GHFIX/code-scanning.rc"; echo "Code scanning is not enabled for this repository" > "$GHFIX/code-scanning.msg"
r=$(si_source_github github.com o/r)
assert_eq "one read 403 -> partial" partial "$(jq -r .source.status <<<"$r")"
assert_eq "failed read named" 'HTTP 403: Code scanning is not enabled for this repository' "$(jq -r '.source.reads[]|select(.name=="code-scanning").reason' <<<"$r")"
printf '[]' > "$GHFIX/dependabot.json"; : > "$GHFIX/code-scanning.rc"
r=$(si_source_github github.com o/r)
assert_eq "empty array read is ok" ok "$(jq -r '.source.reads[]|select(.name=="dependabot").status' <<<"$r")"
cp "$GHFIX/dependabot.json" "$GHFIX/dependabot.small"
jq -n '[range(300) | {number: ., html_url: "https://github.com/o/r/security/dependabot/\(.)",
    security_advisory: {severity: "high", summary: "advisory \(.)", cve_id: "CVE-2024-\(.)", ghsa_id: "GHSA-\(.)",
                        description: ("x" * 4000)},
    dependency: {package: {name: "org.example:lib\(.)"}, manifest_path: "pom.xml", scope: "runtime"},
    security_vulnerability: {vulnerable_version_range: "= 1.0.0", first_patched_version: {identifier: "1.0.1"}}}]' > "$GHFIX/dependabot.json"
r=$(si_source_github github.com o/r 2>&1)
assert_eq "300 alerts -> ok" ok "$(jq -r .source.status <<<"$r" 2>/dev/null)"
assert_eq "300 alerts -> 300 dependabot findings" 300 "$(jq '[.findings[]|select(.kind=="dependency")]|length' <<<"$r" 2>/dev/null)"
cp "$GHFIX/dependabot.small" "$GHFIX/dependabot.json"; printf '[]' > "$GHFIX/dependabot.json"
out=$(SECURITY_INSIGHTS_LIB= KNOWN_GH=github.com "$BASH" "$SCRIPT" --repo "$REPO")
assert_eq "collect includes github source" 1 "$(jq '[.sources[]|select(.name=="github" and .status=="ok")]|length' <<<"$out")"
for e in dependabot code-scanning secret-scanning; do echo 1 > "$GHFIX/$e.rc"; done
assert_eq "all reads fail -> skipped" skipped "$(si_source_github github.com o/r | jq -r .source.status)"
assert_eq "gh absent -> skipped" "gh not installed" "$(PATH="$NOGH" si_source_github github.com o/r | jq -r .source.reason)"
assert_eq "gh unauthenticated -> skipped" "gh auth status --hostname github.com failed: not logged in" "$(KNOWN_GH= si_source_github github.com o/r | jq -r .source.reason)"

echo "si_source_gitlab"
cp "$GLFIX/good_page1.json" "$GLFIX/page1.json"; reset_counter
export KNOWN_GL=gitlab.example.com
: > "$ARGV_LOG"
r=$(si_source_gitlab gitlab.example.com group/sub/repo)
assert_eq "two pages read" 2 "$(grep -c 'api graphql' "$ARGV_LOG")"
assert_contains "graphql call carries --hostname" "--hostname gitlab.example.com" "$(cat "$ARGV_LOG")"
assert_contains "graphql call passes fullPath" "fullPath=group/sub/repo" "$(cat "$ARGV_LOG")"
assert_contains "page 2 passes the cursor" "after=c1" "$(cat "$ARGV_LOG")"
assert_eq "status ok" ok "$(jq -r .source.status <<<"$r")"
assert_eq "three findings across pages" 3 "$(jq '.findings|length' <<<"$r")"
assert_eq "dependency kind from reportType" dependency "$(jq -r '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/1").kind' <<<"$r")"
assert_eq "package name colon form" "org.example:lib" "$(jq -r '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/1").package.name' <<<"$r")"
assert_eq "package version" 1.2.3 "$(jq -r '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/1").package.version' <<<"$r")"
assert_eq "fix version from solution" 1.2.4 "$(jq -r '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/1").package.fix_version' <<<"$r")"
assert_eq "identifiers keep only cve/ghsa/cwe" '["CVE-2024-1"]' "$(jq -c '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/1").identifiers' <<<"$r")"
assert_eq "cwe identifier case-insensitive" '["89"]' "$(jq -c '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/2").identifiers' <<<"$r")"
assert_eq "INFO severity raw kept" Info "$(jq -r '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/2").severity_raw' <<<"$r")"
assert_eq "sast location" 'src/B.java:40' "$(jq -r '.findings[]|select(.kind=="code").locations[0]|"\(.file):\(.line)"' <<<"$r")"
assert_eq "code package null" null "$(jq -c '.findings[]|select(.kind=="code").package' <<<"$r")"
assert_eq "secret kind" secret "$(jq -r '.findings[]|select(.native_id=="gid://gitlab/Vulnerability/3").kind' <<<"$r")"
assert_eq "empty identifiers is an array" '[]' "$(jq -c '.findings[]|select(.kind=="secret").identifiers' <<<"$r")"
assert_eq "scope null" null "$(jq -r '.findings[0].package.scope' <<<"$r")"
assert_eq "no reads for gitlab" null "$(jq -c '.source.reads' <<<"$r")"
cp "$GLFIX/errors.json" "$GLFIX/page1.json"; reset_counter
assert_eq "errors[] on page 1 -> skipped with message" "The resource that you are attempting to access does not exist or you don't have permission" "$(si_source_gitlab gitlab.example.com g/r | jq -r .source.reason)"
cp "$GLFIX/null_project.json" "$GLFIX/page1.json"; reset_counter
assert_eq "null project reason" "project g/r not found on gitlab.example.com or not visible to this token" "$(si_source_gitlab gitlab.example.com g/r | jq -r .source.reason)"
cp "$GLFIX/null_vulns.json" "$GLFIX/page1.json"; reset_counter
assert_eq "null vulnerabilities reason" "vulnerability report unavailable on g/r (requires GitLab Ultimate)" "$(si_source_gitlab gitlab.example.com g/r | jq -r .source.reason)"
cp "$GLFIX/good_page1.json" "$GLFIX/page1.json"; cp "$GLFIX/errors.json" "$GLFIX/page2.json"; reset_counter
r=$(si_source_gitlab gitlab.example.com g/r)
assert_eq "page 2 failure -> partial" partial "$(jq -r .source.status <<<"$r")"
assert_contains "partial reason names page" "page 2 failed:" "$(jq -r .source.reason <<<"$r")"
assert_eq "page 1 findings kept" 2 "$(jq '.findings|length' <<<"$r")"
assert_eq "glab absent -> skipped" "glab not installed" "$(PATH="$NOGLAB" si_source_gitlab gitlab.example.com g/r | jq -r .source.reason)"
assert_eq "glab unauthenticated -> skipped" "glab auth status --hostname gitlab.example.com failed: not logged in" "$(KNOWN_GL= si_source_gitlab gitlab.example.com g/r | jq -r .source.reason)"

echo "si_source_moderne"
assert_eq "not a JVM project" "not a JVM project; DependencyVulnerabilityCheck covers Maven and Gradle only" "$(si_source_moderne "$REPO" 0 | jq -r .source.reason)"
assert_eq "mod absent" "mod not installed" "$(PATH="$NOMOD" si_source_moderne "$JVMREPO" 0 | jq -r .source.reason)"
assert_eq "mod probed before JVM check" "mod not installed" "$(PATH="$NOMOD" si_source_moderne "$REPO" 0 | jq -r .source.reason)"
printf '[]' > "$MODFIX/list.json"
assert_eq "no LST" "no Moderne LST for this repository; run: mod build ." "$(si_source_moderne "$JVMREPO" 0 | jq -r .source.reason)"
cp "$MODFIX/list_good.json" "$MODFIX/list.json"; cp "$MODFIX/history_other_recipe.json" "$MODFIX/history.json"
assert_eq "no DVC run" "no DependencyVulnerabilityCheck run for this repository; run: mod run . --recipe org.openrewrite.java.dependencies.DependencyVulnerabilityCheck" "$(si_source_moderne "$JVMREPO" 0 | jq -r .source.reason)"
printf 'not json' > "$MODFIX/history.json"
assert_eq "unparseable history" "run-history output not understood" "$(si_source_moderne "$JVMREPO" 0 | jq -r .source.reason)"
cp "$MODFIX/history_good.json" "$MODFIX/history.json"
: > "$ARGV_LOG"; r=$(si_source_moderne "$JVMREPO" 0)
assert_contains "study uses --recipe-run" "--recipe-run=20261120140200-abcde" "$(cat "$ARGV_LOG")"
assert_not_contains "study never uses --last-recipe-run" "--last-recipe-run" "$(cat "$ARGV_LOG")"
assert_not_contains "no build without flag" "mod build" "$(cat "$ARGV_LOG")"
assert_eq "status ok" ok "$(jq -r .source.status <<<"$r")"
assert_eq "cve identifier" "CVE-2024-1" "$(jq -r '.findings[0].identifiers[0]' <<<"$r")"
assert_eq "package colon form" "org.example:lib" "$(jq -r '.findings[0].package.name' <<<"$r")"
assert_eq "fix version" "1.2.4" "$(jq -r '.findings[0].package.fix_version' <<<"$r")"
assert_eq "MODERATE raw kept" MODERATE "$(jq -r '.findings[1].severity_raw' <<<"$r")"
assert_eq "CWEs split into identifiers" 2 "$(jq '.findings[0].identifiers|map(select(startswith("CWE-")))|length' <<<"$r")"
assert_eq "bare CWE digits prefixed" '["CVE-2024-1","CWE-79","CWE-611"]' "$(jq -c '.findings[0].identifiers' <<<"$r")"
assert_eq "as_of derived from run id" true "$(jq '.findings[0].as_of|startswith("2026-11-20T14:02:00")' <<<"$r")"
assert_eq "as_of carries a UTC offset" true "$(jq '.findings[0].as_of|test("T14:02:00[+-][0-9]{2}:[0-9]{2}$")' <<<"$r")"
assert_eq "rows for other repo dropped" 2 "$(jq '.findings|length' <<<"$r")"
assert_eq "empty cve cell -> no advisory id" 0 "$(jq '.findings[1].identifiers|map(select(startswith("CVE-")))|length' <<<"$r")"
assert_eq "empty identifiers is an array" '[]' "$(jq -c '.findings[1].identifiers' <<<"$r")"
assert_eq "empty fixedVersion is null" null "$(jq -c '.findings[1].package.fix_version' <<<"$r")"
assert_eq "depth lower-cased" transitive "$(jq -r '.findings[0].package.depth' <<<"$r")"
assert_eq "epss number" 0.42 "$(jq -c '.findings[0].epss' <<<"$r")"
assert_eq "epss null" null "$(jq -c '.findings[1].epss' <<<"$r")"
assert_eq "native id by row index" "VulnerabilityReport:row:0" "$(jq -r '.findings[0].native_id' <<<"$r")"
assert_eq "scope from run options" test "$(jq -r '.findings[0].package.scope' <<<"$r")"
cp "$MODFIX/history_noscope.json" "$MODFIX/history.json"
assert_eq "scope null when run has none" null "$(si_source_moderne "$JVMREPO" 0 | jq -r '.findings[0].package.scope')"
cp "$MODFIX/history_good.json" "$MODFIX/history.json"
: > "$ARGV_LOG"; si_source_moderne "$JVMREPO" 1 >/dev/null
assert_eq "--moderne-run builds then runs" "mod build|mod run" "$(grep -oE 'mod (build|run) ' "$ARGV_LOG" | sed 's/ $//' | paste -sd'|' -)"
: > "$MODFIX/build.rc"
assert_eq "build failure skips" "mod build failed: build exploded" "$(si_source_moderne "$JVMREPO" 1 2>/dev/null | jq -r .source.reason)"
rm -f "$MODFIX/build.rc"; : > "$MODFIX/run.rc"
assert_eq "run failure skips" "mod run failed: run exploded" "$(si_source_moderne "$JVMREPO" 1 2>/dev/null | jq -r .source.reason)"
rm -f "$MODFIX/run.rc"
out=$(SECURITY_INSIGHTS_LIB= "$BASH" "$SCRIPT" --repo "$JVMREPO" 2>/dev/null)
assert_eq "collect includes moderne source" 1 "$(jq '[.sources[]|select(.name=="moderne" and .status=="ok")]|length' <<<"$out")"

echo
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
