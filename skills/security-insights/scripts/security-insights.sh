#!/usr/bin/env bash
# security-insights — security findings for a repository from forge, dependency and Moderne sources.
# In library mode (sourced by the test harness) skip -e and do not dispatch.
if [[ -z "${SECURITY_INSIGHTS_LIB:-}" ]]; then set -euo pipefail; fi

si_usage() {
    cat <<'USAGE'
Usage: security-insights [--repo <path>] [--moderne-run] [--help]

Emits one JSON document: security findings for a repository, collected
from the forge, dependency tooling and Moderne.

  --repo <path>   Repository to inspect (default: current directory)
  --moderne-run   Forces a Moderne LST build and recipe run; minutes of JVM build
  -h, --help      This help
USAGE
}

si_main() {
    local repo="." moderne_run=0 root
    while (( $# )); do
        case "$1" in
            --repo) [[ $# -ge 2 ]] || { echo "--repo needs a path" >&2; return 1; }
                    repo="$2"; shift 2 ;;
            --moderne-run) moderne_run=1; shift ;;
            -h|--help) si_usage; return 0 ;;
            *) echo "Unknown flag: $1" >&2; si_usage >&2; return 1 ;;
        esac
    done
    command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; return 1; }
    root=$(si_repo_root "$repo") || { echo "Not a git repository: $repo" >&2; return 2; }
    si_collect "$root" "$moderne_run"
}

si_repo_root() {
    git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

si_select_remote_url() {
    local dir="$1" r url
    for r in origin $(git -C "$dir" remote 2>/dev/null); do
        if url=$(git -C "$dir" remote get-url "$r" 2>/dev/null) && [[ -n "$url" ]]; then
            printf '%s' "$url"; return 0
        fi
    done
}

# si_parse_remote <url> -> host<TAB>path  (empty if unparseable)
si_parse_remote() {
    local url="${1:-}" host path
    [[ -n "$url" ]] || return 0
    while [[ "$url" == */ ]]; do url="${url%/}"; done
    url="${url%.git}"
    case "$url" in
        https://*|http://*|ssh://*)
            url="${url#*://}"
            host="${url%%/*}"
            path="${url#*/}"
            [[ "$url" == */* ]] || return 0
            ;;
        *@*:*)
            url="${url#*@}"
            host="${url%%:*}"
            path="${url#*:}"
            ;;
        *) return 0 ;;
    esac
    host="${host##*@}"
    host="${host%%:*}"
    path="${path#/}"
    [[ -n "$host" && -n "$path" ]] || return 0
    printf '%s\t%s\n' "$host" "$path"
}


# si_first_err <rc> [host]  (stderr text on stdin) -> first trimmed line that is not empty,
# the bare host or a bare ERROR; else "exit <rc>, no error output"
si_first_err() {
    local rc="$1" host="${2:-}" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ -n "$line" && "$line" != "$host" && "$line" != "ERROR" ]]; then
            printf '%s' "$line"; return 0
        fi
    done
    printf 'exit %s, no error output' "$rc"
}

si_detect_forge() {
    local host="$1"
    if [[ "$host" == "github.com" ]]; then printf 'github'
    elif glab auth status --hostname "$host" >/dev/null 2>&1; then printf 'gitlab'
    elif gh auth status --hostname "$host" >/dev/null 2>&1; then printf 'github'
    elif [[ "$host" == *gitlab* ]]; then printf 'gitlab'
    else printf 'unknown'
    fi
}

si_repo_json() {
    local dir="$1" url parsed host="" path="" forge="unknown"
    url=$(si_select_remote_url "$dir")
    parsed=$(si_parse_remote "$url")
    if [[ -n "$parsed" ]]; then
        host="${parsed%%$'\t'*}"
        path="${parsed#*$'\t'}"
        forge=$(si_detect_forge "$host")
    fi
    jq -n --arg forge "$forge" --arg path "$path" --arg host "$host" --arg dir "$dir" \
        '{forge: $forge, path: (if $path == "" then null else $path end),
          host: (if $host == "" then null else $host end), dir: $dir}'
}

# si_result <name> <status> <reason or ""> <findings stream> [reads stream] -> one source result;
# with reads, status and reason are derived from them
si_result() {
    jq -nc --arg name "$1" --arg status "$2" --arg reason "$3" --slurpfile f "$4" --slurpfile r "${5:-/dev/null}" '
        {source: ({name: $name, status: $status, reason: (if $reason == "" then null else $reason end), count: 0}
                  + if $r == [] then {} else
                      ([$r[] | select(.status == "ok")] | length) as $ok
                      | {status: (if $ok == ($r | length) then "ok" elif $ok > 0 then "partial" else "skipped" end),
                         reason: (if $ok == 0 then [$r[] | "\(.name): \(.reason)"] | join("; ") else null end),
                         reads: $r} end),
         findings: ($f | add // [])}'
}

si_skipped() {
    si_result "$1" skipped "$2" /dev/null
}

# si_preflight <source> <cli> <host> -> 0 when the CLI is installed and authenticated for host;
# else prints the skipped result and returns 1
si_preflight() {
    local source="$1" cli="$2" host="$3" err rc=0
    if ! command -v "$cli" >/dev/null 2>&1; then
        si_skipped "$source" "$cli not installed"; return 1
    fi
    err=$("$cli" auth status --hostname "$host" 2>&1 >/dev/null) || rc=$?
    [[ "$rc" -ne 0 ]] || return 0
    si_skipped "$source" "$cli auth status --hostname $host failed: $(si_first_err "$rc" "$host" <<<"$err")"
    return 1
}

SI_READ_REASON=""

# si_map <label> <outfile> <jq args...> -> appends the mapped array to outfile;
# on failure sets SI_READ_REASON and returns 1
si_map() {
    local label="$1" out="$2" err rc=0
    shift 2
    err=$(jq -c "$@" 2>&1 >>"$out") || rc=$?
    [[ "$rc" -ne 0 ]] || return 0
    SI_READ_REASON="$label output not understood: $(si_first_err "$rc" <<<"$err")"
    return 1
}

SI_SHAPE_JQ='
def sev_rank: {critical: 0, high: 1, medium: 2, low: 3, unknown: 4}[.];
def source_rank: {gitlab: 0, github: 1, moderne: 2}[.] // 3;
def norm_sev:
  (. // "" | ascii_downcase) as $s
  | if $s == "critical" then "critical"
    elif $s | IN("high", "error") then "high"
    elif $s | IN("medium", "moderate", "warning") then "medium"
    elif $s | IN("low", "info", "note") then "low"
    else "unknown" end;
def ordered_unique: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
def norm_id:
  if test("^(cve|ghsa)-"; "i") then ascii_upcase
  else sub("^cwe-?0*(?<n>[0-9]+)$"; "CWE-\(.n)"; "i") end;
def normalise:
  .identifiers = (.identifiers // [] | map(select(type == "string") | norm_id))
  | .locations = (.locations // [])
  | .adv = [.identifiers[] | select(startswith("CVE-") or startswith("GHSA-"))]
  | .severity = (if .severity_origin == "policy" then "critical" else .severity_raw | norm_sev end);
def well_formed: type == "object" and (.findings | type) == "array" and (.source | type) == "object";
def malformed:
  ((try .source.name catch null) // "unknown") as $name
  | {source: {name: $name, status: "skipped", reason: "\($name) result malformed", count: 0}, findings: []};
# Lists of finding indexes that must share a group: one per advisory id, and one per
# package@version among dependency findings that carry no advisory id.
def link_sets:
  [to_entries[] | .key as $i | .value
   | if (.kind | IN("dependency", "container")) and (.adv | length) > 0 then .adv[] | {k: ., i: $i}
     elif .kind == "dependency" and .package != null then {k: "pkg:\(.package.name)@\(.package.version)", i: $i}
     else empty end]
  | group_by(.k) | map(map(.i));
def components($n; $sets):
  def step: reduce $sets[] as $s (.; ([.[$s[]]] | min) as $m | reduce $s[] as $i (.; .[$i] = $m));
  def settle: step as $next | if $next == . then . else $next | settle end;
  [range($n)] | settle;
def merge_key($adv):
  "\(.source):\(.kind):\(.native_id)" as $native
  | if .kind | IN("dependency", "container") | not then $native
    else first($adv[] | select(startswith("CVE-")))
         // first($adv[] | select(startswith("GHSA-")))
         // (if .kind == "dependency" and .package != null
             then "pkg:\(.package.name)@\(.package.version)" else $native end) end;
def first_of($rows; f): first($rows[] | (f // empty)) // null;
def merge:
  sort_by([(.source | source_rank), .native_id])
  | .[0] as $first
  | ([.[].adv[]] | unique) as $adv
  | (sort_by(.severity | sev_rank) | .[0]) as $worst
  | $first.package.name as $pname
  | [.[] | select(.package != null and .package.name == $pname)] as $same
  | [.[] | select(.package.fix_version != null) | {source, version: .package.fix_version, package: .package.name}] as $fixes
  | ([$fixes[] | select(.package == $pname) | .version] | unique) as $own_fixes
  | {key: ($first | merge_key($adv)),
     severity: $worst.severity,
     severity_origin: $worst.severity_origin,
     title: $first.title,
     kind: $first.kind,
     package: (if $first.package == null then null else
       {name: $pname,
        version: first_of($same; .package.version),
        fix_version: (if ($own_fixes | length) == 1 then $own_fixes[0] else null end),
        fix_candidates: ($fixes | unique),
        depth: first_of($same; .package.depth),
        scope: first_of($same; .package.scope)} end),
     identifiers: ([.[].identifiers[]] | ordered_unique),
     locations: ([.[].locations[]] | ordered_unique),
     sources: map({name: .source, id: .native_id, severity_raw, url, solution,
                   package: (if .package == null then null else .package | {name, version, fix_version} end)}
                  + (if .epss != null then {epss} else {} end)
                  + (if .as_of != null then {as_of} else {} end))};

[.results[] | if well_formed then . else malformed end
 | .findings |= unique_by([.source, .native_id])] as $results
| [$results[].findings[] | normalise] as $raw
| components($raw | length; $raw | link_sets) as $labels
| ([range($raw | length)] | group_by($labels[.]) | map(map($raw[.]) | merge)
   | sort_by([(.severity | sev_rank), .key])) as $findings
| {repo: .repo,
   sources: [$results[] | .source + {count: (.findings | length)}],
   findings: $findings,
   summary: (reduce $findings[] as $f ({critical: 0, high: 0, medium: 0, low: 0, unknown: 0};
               .[$f.severity] += 1)
             + {merged: (($raw | length) - ($findings | length))})}
'

si_shape() {
    jq -c "$SI_SHAPE_JQ"
}

# si_gh_read <host> <path> <endpoint> <outfile> -> alerts as a JSON stream in outfile;
# on failure sets SI_READ_REASON and returns 1
si_gh_read() {
    local host="$1" path="$2" endpoint="$3" out="$4" err rc=0 msg code
    SI_READ_REASON=""
    err=$(gh api --hostname "$host" "repos/$path/$endpoint?state=open&per_page=100" --paginate --jq '.[]' 2>&1 >"$out") || rc=$?
    [[ "$rc" -ne 0 ]] || return 0
    err=$(si_first_err "$rc" <<<"$err")
    msg=$(jq -r '.message // empty' "$out" 2>/dev/null | head -n 1) || msg=""
    code=$(sed -n 's/.*(HTTP \([0-9][0-9]*\)).*/\1/p' <<<"$err" | head -n 1)
    SI_READ_REASON="HTTP ${code:-?}: ${msg:-$err}"
    return 1
}

SI_GH_MAP='
def dependabot:
  {source: "github", native_id: ("dependabot:\(.number)"), kind: "dependency",
   severity_raw: .security_advisory.severity, severity_origin: "source",
   title: .security_advisory.summary,
   package: {name: .dependency.package.name,
             version: ((.security_vulnerability.vulnerable_version_range // "") | capture("^= (?<v>[^ ,]+)$").v? // null),
             fix_version: (.security_vulnerability.first_patched_version.identifier // null),
             depth: null, scope: (.dependency.scope // null)},
   identifiers: ([.security_advisory.cve_id, .security_advisory.ghsa_id] | map(select(. != null))),
   locations: [{file: .dependency.manifest_path, line: null}],
   url: .html_url, solution: null, epss: null, as_of: null};
def code_scanning:
  {source: "github", native_id: ("code-scanning:\(.number)"), kind: "code",
   severity_raw: (.rule.security_severity_level // .rule.severity), severity_origin: "source",
   title: (.rule.description // .rule.id),
   package: null,
   identifiers: ([.rule.id] + [(.rule.tags // [])[] | strings | capture("^external/cwe/(?<id>.*)$").id]),
   locations: [{file: .most_recent_instance.location.path, line: .most_recent_instance.location.start_line}],
   url: .html_url, solution: null, epss: null, as_of: null};
def secret_scanning:
  {source: "github", native_id: ("secret-scanning:\(.number)"), kind: "secret",
   severity_raw: "n/a (secret)", severity_origin: "policy",
   title: (.secret_type_display_name // .secret_type),
   package: null, identifiers: [.secret_type], locations: [],
   url: .html_url, solution: null, epss: null, as_of: null};
'

si_source_github() {
    local host="$1" path="$2" endpoint work
    si_preflight github gh "$host" || return 0
    work=$(mktemp -d "${TMPDIR:-/tmp}/si-gh.XXXXXX")
    trap 'rm -rf "$work"; trap - RETURN' RETURN
    : > "$work/findings.json"
    for endpoint in dependabot code-scanning secret-scanning; do
        if si_gh_read "$host" "$path" "$endpoint/alerts" "$work/read.json"; then
            si_map github "$work/findings.json" -s "$SI_GH_MAP"'[.[] | '"${endpoint//-/_}"']' "$work/read.json" || :
        fi
        jq -nc --arg n "$endpoint" --arg r "$SI_READ_REASON" \
            '{name: $n} + if $r == "" then {status: "ok"} else {status: "skipped", reason: $r} end' >> "$work/reads.json"
    done
    si_result github "" "" "$work/findings.json" "$work/reads.json"
}

SI_GITLAB_QUERY='query($fullPath: ID!, $after: String) {
  project(fullPath: $fullPath) {
    vulnerabilities(state: [DETECTED, CONFIRMED], first: 100, after: $after) {
      nodes {
        id title severity state reportType webUrl solution
        identifiers { externalType externalId name }
        location {
          ... on VulnerabilityLocationDependencyScanning { file dependency { package { name } version } }
          ... on VulnerabilityLocationSast { file startLine }
          ... on VulnerabilityLocationSecretDetection { file startLine }
          ... on VulnerabilityLocationContainerScanning { image dependency { package { name } version } }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}'

SI_GL_MAP='
def kind: {"DEPENDENCY_SCANNING": "dependency", "SAST": "code", "SECRET_DETECTION": "secret",
           "CONTAINER_SCANNING": "container"}[.reportType] // "unknown";
def colon: if (test("@") | not) and (split("/") | length) == 2 then sub("/"; ":") else . end;
def fix: (.solution // "") | capture("(?s)[Uu]pgrade.*?(?<v>[0-9]+(\\.[0-9]+)+)").v? // null;
def loc($k):
  if $k == "container" then (if .image != null then [{file: .image, line: null}] else [] end)
  elif .file != null then [{file, line: (.startLine // null)}] else [] end;
[.data.project.vulnerabilities.nodes[] | kind as $k | (.location // {}) as $l
 | {source: "gitlab", native_id: .id, kind: $k,
    severity_raw: .severity, severity_origin: "source", title: .title,
    package: (if $k == "dependency" or $k == "container"
              then {name: ($l.dependency.package.name | if . == null then null else colon end),
                    version: ($l.dependency.version // null), fix_version: fix, depth: null, scope: null}
              else null end),
    identifiers: [(.identifiers // [])[] | ((.externalType // "") | ascii_downcase) as $t
                  | select($t | IN("cve", "ghsa", "cwe")) | .externalId
                  | if $t == "cwe" and (tostring | test("^[0-9]+$")) then "cwe-\(.)" else . end],
    locations: ($l | loc($k)),
    url: .webUrl, solution: (.solution // null), epss: null, as_of: null}]
'

# si_gl_check <page file> <path> <host> -> 1 with SI_READ_REASON set when the page is unusable
si_gl_check() {
    SI_READ_REASON=$(jq -rs --arg p "$2" --arg h "$3" '
        if length != 1 or (.[0] | type) != "object" then "unparseable response" else .[0]
        | if (.errors // [] | length) > 0 then .errors[0].message
          elif .data.project == null then "project \($p) not found on \($h) or not visible to this token"
          elif .data.project.vulnerabilities == null then "vulnerability report unavailable on \($p) (requires GitLab Ultimate)"
          else empty end end' "$1" 2>/dev/null) || SI_READ_REASON="unparseable response"
    [[ -z "$SI_READ_REASON" ]]
}

si_source_gitlab() {
    local host="$1" path="$2" cursor="" page=0 err rc work status="ok" reason=""
    local -a args
    si_preflight gitlab glab "$host" || return 0
    work=$(mktemp -d "${TMPDIR:-/tmp}/si-gl.XXXXXX")
    trap 'rm -rf "$work"; trap - RETURN' RETURN
    : > "$work/findings.json"
    while :; do
        page=$((page+1))
        args=(api graphql --hostname "$host" -f "query=$SI_GITLAB_QUERY" -f "fullPath=$path")
        [[ -z "$cursor" ]] || args+=(-f "after=$cursor")
        rc=0 SI_READ_REASON=""
        err=$(glab "${args[@]}" 2>&1 >"$work/page.json") || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            SI_READ_REASON=$(si_first_err "$rc" "$host" <<<"$err")
        elif si_gl_check "$work/page.json" "$path" "$host"; then
            si_map gitlab "$work/findings.json" "$SI_GL_MAP" "$work/page.json" || :
        fi
        if [[ -n "$SI_READ_REASON" ]]; then
            if [[ "$page" -eq 1 ]]; then si_skipped gitlab "$SI_READ_REASON"; return 0; fi
            status="partial" reason="page $page failed: $SI_READ_REASON"
            break
        fi
        cursor=$(jq -r '.data.project.vulnerabilities.pageInfo | if .hasNextPage == true then .endCursor // "" else "" end' "$work/page.json")
        [[ -n "$cursor" ]] || break
    done
    si_result gitlab "$status" "$reason" "$work/findings.json"
}

SI_MOD_RECIPE=org.openrewrite.java.dependencies.DependencyVulnerabilityCheck
SI_MOD_TABLE=org.openrewrite.java.dependencies.table.VulnerabilityReport

SI_MOD_MAP='
def opt: if . == null or . == "" then null else . end;
def cwes: (.CWEs // "" | tostring) | [splits("[,;]")] | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))
          | map(if test("^[0-9]+$") then "cwe-" + . else . end);
def depth_label: opt | if . == null then null elif type == "number" then (if . == 0 then "direct" else "transitive" end)
                       else ascii_downcase end;
if type != "array" then error("not an array") else
[to_entries[] | .key as $i | .value
 | select(.repositoryPath == $path and .repositoryOrigin == $origin)
 | {source: "moderne", native_id: "VulnerabilityReport:row:\($i)", kind: "dependency",
    severity_raw: .severity, severity_origin: "source",
    title: ((.summary | opt) // .cve),
    package: {name: "\(.groupId):\(.artifactId)", version: (.version | opt),
              fix_version: (.fixedVersion | opt), depth: (.depth | depth_label), scope: $scope},
    identifiers: ([.cve | opt] | map(select(. != null))) + cwes,
    locations: [], url: null, solution: null,
    epss: (.epss | if type == "number" then . elif type == "string" then (tonumber? // null) else null end),
    as_of: $as_of}] end
'

# si_mod_as_of <run id> -> local ISO-8601 time from the YYYYMMDDHHMMSS run id prefix
si_mod_as_of() {
    local ts="${1%%-*}" z
    z=$(date +%z)
    printf '%s-%s-%sT%s:%s:%s%s:%s' "${ts:0:4}" "${ts:4:2}" "${ts:6:2}" "${ts:8:2}" "${ts:10:2}" "${ts:12:2}" "${z:0:3}" "${z:3:2}"
}

SI_MOD_ORIGIN="" SI_MOD_PATH=""

# si_mod_list <dir> -> SI_MOD_ORIGIN, SI_MOD_PATH (empty when there is no LST)
si_mod_list() {
    local listing
    SI_MOD_ORIGIN="" SI_MOD_PATH=""
    listing=$(mod list --json "$1" 2>/dev/null) || return 0
    SI_MOD_ORIGIN=$(jq -r '.[0].origin // empty' <<<"$listing" 2>/dev/null) || SI_MOD_ORIGIN=""
    SI_MOD_PATH=$(jq -r '.[0].path // empty' <<<"$listing" 2>/dev/null) || SI_MOD_PATH=""
    [[ -n "$SI_MOD_PATH" ]] || SI_MOD_ORIGIN=""
}

# si_mod_step <build|run> <args...> -> progress on stderr; on failure prints the skipped result, returns 1
si_mod_step() {
    local step="$1" err rc=0
    err=$(mod "$@" 2>&1 >&2) || rc=$?
    [[ -z "$err" ]] || printf '%s\n' "$err" >&2
    [[ "$rc" -ne 0 ]] || return 0
    si_skipped moderne "mod $step failed: $(si_first_err "$rc" <<<"$err")"
    return 1
}

si_source_moderne() {
    local dir="$1" moderne_run="$2" f jvm=0 work entry run_id scope err rc=0
    command -v mod >/dev/null 2>&1 || { si_skipped moderne "mod not installed"; return 0; }
    for f in pom.xml build.gradle build.gradle.kts settings.gradle settings.gradle.kts; do
        if [[ -f "$dir/$f" ]]; then jvm=1; fi
    done
    if [[ "$jvm" -eq 0 ]]; then
        si_skipped moderne "not a JVM project; DependencyVulnerabilityCheck covers Maven and Gradle only"
        return 0
    fi
    if [[ "$moderne_run" == 1 ]]; then si_mod_step build "$dir" || return 0; fi
    si_mod_list "$dir"
    if [[ -z "$SI_MOD_ORIGIN" ]]; then
        si_skipped moderne "no Moderne LST for this repository; run: mod build ."
        return 0
    fi
    if [[ "$moderne_run" == 1 ]]; then si_mod_step run "$dir" --recipe "$SI_MOD_RECIPE" || return 0; fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/si-mod.XXXXXX")
    trap 'rm -rf "$work"; trap - RETURN' RETURN
    if ! mod run-history --json --most-recent "$dir" >"$work/history.json" 2>/dev/null \
        || ! entry=$(jq -rs --arg r "$SI_MOD_RECIPE" '
            .[0] | if type != "object" then error("not an object") else
              [to_entries[] | select(.value.recipeId == $r)] | sort_by(.key) | last
              | if . == null then empty else "\(.key)\t\(.value.recipeOptions.scope // null | tojson)" end end
            ' "$work/history.json" 2>/dev/null); then
        si_skipped moderne "run-history output not understood"
        return 0
    fi
    if [[ -z "$entry" ]]; then
        si_skipped moderne "no DependencyVulnerabilityCheck run for this repository; run: mod run . --recipe $SI_MOD_RECIPE"
        return 0
    fi
    run_id="${entry%%$'\t'*}" scope="${entry#*$'\t'}"
    err=$(mod study "$dir" "--recipe-run=$run_id" --data-table "$SI_MOD_TABLE" --json 2>&1 >"$work/study.json") || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        si_skipped moderne "mod study failed: $(si_first_err "$rc" <<<"$err")"
        return 0
    fi
    if ! si_map moderne "$work/findings.json" --arg path "$SI_MOD_PATH" --arg origin "$SI_MOD_ORIGIN" \
        --arg as_of "$(si_mod_as_of "$run_id")" --argjson scope "$scope" "$SI_MOD_MAP" "$work/study.json"; then
        si_skipped moderne "$SI_READ_REASON"
        return 0
    fi
    si_result moderne ok "" "$work/findings.json"
}

si_collect() {
    local dir="$1" moderne_run="${2:-0}" repo forge host path reason
    repo=$(si_repo_json "$dir")
    { read -r forge; read -r host; read -r path; } < <(jq -r '.forge, .host // "", .path // ""' <<<"$repo")
    {
        case "$forge" in
            gitlab) si_source_gitlab "$host" "$path" ;;
            github) si_source_github "$host" "$path" ;;
            *)
                reason="no git remote"
                if [[ -n "$host" ]]; then reason="host $host is not known to gh or glab"; fi
                si_skipped gitlab "$reason"
                si_skipped github "$reason"
                ;;
        esac
        si_source_moderne "$dir" "$moderne_run"
    } | jq -sc --argjson repo "$repo" '{repo: $repo, results: .}' | si_shape
}

if [[ -z "${SECURITY_INSIGHTS_LIB:-}" ]]; then si_main "$@"; fi
