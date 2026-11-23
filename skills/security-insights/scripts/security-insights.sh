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
  --moderne-run   Allow Moderne recipe runs (slower, may cost credits)
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
    local dir="$1" url remote
    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || url=""
    if [[ -z "$url" ]]; then
        remote=$(git -C "$dir" remote 2>/dev/null | head -n 1) || remote=""
        if [[ -n "$remote" ]]; then url=$(git -C "$dir" remote get-url "$remote" 2>/dev/null) || url=""; fi
    fi
    printf '%s' "$url"
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

SI_GLAB_AUTH_RC="" SI_GH_AUTH_RC="" SI_GLAB_AUTH_ERR="" SI_GH_AUTH_ERR=""

si_detect_forge() {
    local host="$1" err
    SI_GLAB_AUTH_RC=0 SI_GH_AUTH_RC=0 SI_GLAB_AUTH_ERR="" SI_GH_AUTH_ERR=""
    err=$(glab auth status --hostname "$host" 2>&1 >/dev/null) || SI_GLAB_AUTH_RC=$?
    SI_GLAB_AUTH_ERR=$(printf '%s\n' "$err" | head -n 1)
    err=$(gh auth status --hostname "$host" 2>&1 >/dev/null) || SI_GH_AUTH_RC=$?
    SI_GH_AUTH_ERR=$(printf '%s\n' "$err" | head -n 1)
    if [[ "$SI_GLAB_AUTH_RC" -eq 0 ]]; then printf 'gitlab'
    elif [[ "$SI_GH_AUTH_RC" -eq 0 ]]; then printf 'github'
    elif [[ "$host" == "github.com" ]]; then printf 'github'
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

si_skipped() {
    jq -n --arg name "$1" --arg reason "$2" \
        '{source: {name: $name, status: "skipped", reason: $reason, count: 0}, findings: []}'
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
def normalise:
  .identifiers |= map(if test("^(cve|ghsa)-"; "i") then ascii_upcase else . end)
  | .adv = [.identifiers[] | select(startswith("CVE-") or startswith("GHSA-"))]
  | .severity = (if .severity_origin == "policy" then "critical" else .severity_raw | norm_sev end);
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
def merge:
  sort_by([(.source | source_rank), .native_id])
  | .[0] as $first
  | ([.[].adv[]] | unique) as $adv
  | (sort_by(.severity | sev_rank) | .[0]) as $worst
  | [.[] | select(.package.fix_version != null) | {source, version: .package.fix_version}] as $fixes
  | "\($first.source):\($first.kind):\($first.native_id)" as $native_key
  | {key: (if $first.kind | IN("dependency", "container") | not then $native_key
           else first($adv[] | select(startswith("CVE-")))
                // first($adv[] | select(startswith("GHSA-")))
                // (if $first.kind == "dependency" and $first.package != null
                    then "pkg:\($first.package.name)@\($first.package.version)"
                    else $native_key end) end),
     severity: $worst.severity,
     severity_origin: $worst.severity_origin,
     title: $first.title,
     kind: $first.kind,
     package: (if $first.package == null then null else
       {name: $first.package.name, version: $first.package.version,
        fix_version: (if ($fixes | map(.version) | unique | length) == 1 then $fixes[0].version else null end),
        fix_candidates: ($fixes | unique),
        depth: (first(.[].package.depth // empty) // null),
        scope: (first(.[].package.scope // empty) // null)} end),
     identifiers: ([.[].identifiers[]] | ordered_unique),
     locations: ([.[].locations[]] | ordered_unique),
     sources: map({name: .source, id: .native_id, severity_raw, url, solution}
                  + (if .epss != null then {epss} else {} end)
                  + (if .as_of != null then {as_of} else {} end))};

[.results[] | .findings |= unique_by([.source, .native_id])] as $results
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

SI_READ_JSON="" SI_READ_REASON=""

# si_gh_read <host> <path> <endpoint> -> SI_READ_JSON (array) or SI_READ_REASON on failure
si_gh_read() {
    local host="$1" path="$2" endpoint="$3" errf out rc=0 err msg code
    errf=$(mktemp "${TMPDIR:-/tmp}/si-gh.XXXXXX")
    out=$(gh api --hostname "$host" "repos/$path/$endpoint?state=open&per_page=100" --paginate --jq '.[]' 2>"$errf") || rc=$?
    err=$(head -n 1 "$errf")
    rm -f "$errf"
    SI_READ_JSON="" SI_READ_REASON=""
    if [[ "$rc" -eq 0 ]]; then
        SI_READ_JSON=$(jq -sc '.' <<<"$out" 2>/dev/null) || SI_READ_REASON="unparseable response"
        return 0
    fi
    msg=$(jq -r '.message // empty' <<<"$out" 2>/dev/null | head -n 1) || msg=""
    [[ -n "$msg" ]] || msg="$err"
    code=$(sed -n 's/.*(HTTP \([0-9][0-9]*\)).*/\1/p' <<<"$err" | head -n 1)
    SI_READ_REASON="HTTP ${code:-?}: $msg"
}

SI_GH_MAP='
def dependabot:
  {source: "github", native_id: (.number | tostring), kind: "dependency",
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
  {source: "github", native_id: (.number | tostring), kind: "code",
   severity_raw: (.rule.security_severity_level // .rule.severity), severity_origin: "source",
   title: (.rule.description // .rule.id),
   package: null, identifiers: [.rule.id],
   locations: [{file: .most_recent_instance.location.path, line: .most_recent_instance.location.start_line}],
   url: .html_url, solution: null, epss: null, as_of: null};
def secret_scanning:
  {source: "github", native_id: (.number | tostring), kind: "secret",
   severity_raw: "n/a (secret)", severity_origin: "policy",
   title: (.secret_type_display_name // .secret_type),
   package: null, identifiers: [.secret_type], locations: [],
   url: .html_url, solution: null, epss: null, as_of: null};
'

si_source_github() {
    local host="$1" path="$2" endpoint filter err reads="[]" reasons="" ok=0 total=0 work acc
    command -v gh >/dev/null 2>&1 || { si_skipped github "gh not installed"; return 0; }
    err=$(gh auth status --hostname "$host" 2>&1 >/dev/null) || {
        si_skipped github "gh auth status --hostname $host failed: $(printf '%s\n' "$err" | head -n 1)"
        return 0
    }
    work=$(mktemp -d "${TMPDIR:-/tmp}/si-gh.XXXXXX")
    acc="$work/acc.json"
    printf '[]' > "$acc"
    for endpoint in dependabot code-scanning secret-scanning; do
        filter="${endpoint//-/_}"
        total=$((total+1))
        si_gh_read "$host" "$path" "$endpoint/alerts"
        if [[ -n "$SI_READ_REASON" ]]; then
            reads=$(jq -c --arg n "$endpoint" --arg r "$SI_READ_REASON" '. + [{name: $n, status: "skipped", reason: $r}]' <<<"$reads")
            if [[ -n "$reasons" ]]; then reasons="$reasons; $SI_READ_REASON"; else reasons="$SI_READ_REASON"; fi
        else
            ok=$((ok+1))
            reads=$(jq -c --arg n "$endpoint" '. + [{name: $n, status: "ok"}]' <<<"$reads")
            jq -c "$SI_GH_MAP"'[.[] | '"$filter"']' <<<"$SI_READ_JSON" > "$work/new.json"
            jq -sc 'add' "$acc" "$work/new.json" > "$work/next.json"
            mv "$work/next.json" "$acc"
        fi
    done
    jq -nc --argjson reads "$reads" --slurpfile findings "$acc" --arg reasons "$reasons" --argjson ok "$ok" --argjson total "$total" '
        {source: {name: "github",
                  status: (if $ok == $total then "ok" elif $ok > 0 then "partial" else "skipped" end),
                  reason: (if $ok == 0 then $reasons else null end),
                  count: 0, reads: $reads},
         findings: $findings[0]}'
    rm -rf "$work"
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
[.data.project.vulnerabilities.nodes[] | (. | kind) as $k | (.location // {}) as $l
 | {source: "gitlab", native_id: .id, kind: $k,
    severity_raw: .severity, severity_origin: "source", title: .title,
    package: (if $k == "dependency" or $k == "container"
              then {name: ($l.dependency.package.name | if . == null then null else colon end),
                    version: ($l.dependency.version // null), fix_version: fix, depth: null, scope: null}
              else null end),
    identifiers: [(.identifiers // [])[] | select((.externalType // "") | ascii_downcase | IN("cve", "ghsa", "cwe")) | .externalId],
    locations: (if $k == "container" then (if $l.image != null then [{file: $l.image, line: null}] else [] end)
                elif $l.file != null then [{file: $l.file, line: ($l.startLine // null)}] else [] end),
    url: .webUrl, solution: (.solution // null), epss: null, as_of: null}]
'

# si_gl_check <body> <path> <host> -> SI_READ_REASON set when the page is unusable
si_gl_check() {
    local body="$1" path="$2" host="$3"
    SI_READ_REASON=$(jq -r --arg p "$path" --arg h "$host" '
        if (.errors // [] | length) > 0 then .errors[0].message
        elif .data.project == null then "project \($p) not found on \($h) or not visible to this token"
        elif .data.project.vulnerabilities == null then "vulnerability report unavailable on \($p) (requires GitLab Ultimate)"
        else empty end' <<<"$body" 2>/dev/null) || SI_READ_REASON="unparseable response"
}

si_source_gitlab() {
    local host="$1" path="$2" cursor="" page=0 body err rc work acc status="ok" reason="" more
    local -a args
    command -v glab >/dev/null 2>&1 || { si_skipped gitlab "glab not installed"; return 0; }
    err=$(glab auth status --hostname "$host" 2>&1 >/dev/null) || {
        si_skipped gitlab "glab auth status --hostname $host failed: $(printf '%s\n' "$err" | head -n 1)"
        return 0
    }
    work=$(mktemp -d "${TMPDIR:-/tmp}/si-gl.XXXXXX")
    acc="$work/acc.json"
    printf '[]' > "$acc"
    while :; do
        page=$((page+1))
        args=(api graphql --hostname "$host" -f "query=$SI_GITLAB_QUERY" -f "fullPath=$path")
        [[ -z "$cursor" ]] || args+=(-f "after=$cursor")
        rc=0
        body=$(glab "${args[@]}" 2>"$work/err") || rc=$?
        err=$(head -n 1 "$work/err")
        SI_READ_REASON=""
        if [[ "$rc" -ne 0 ]]; then
            SI_READ_REASON="${err:-glab api graphql failed}"
        elif ! jq -e . >/dev/null 2>&1 <<<"$body"; then
            SI_READ_REASON="${err:-unparseable response}"
        else
            si_gl_check "$body" "$path" "$host"
        fi
        if [[ -n "$SI_READ_REASON" ]]; then
            if [[ "$page" -eq 1 ]]; then
                si_skipped gitlab "$SI_READ_REASON"
                rm -rf "$work"
                return 0
            fi
            status="partial"; reason="page $page failed: $SI_READ_REASON"
            break
        fi
        jq -c "$SI_GL_MAP" <<<"$body" > "$work/new.json"
        jq -sc 'add' "$acc" "$work/new.json" > "$work/next.json"
        mv "$work/next.json" "$acc"
        more=$(jq -r '.data.project.vulnerabilities.pageInfo | if .hasNextPage == true then .endCursor // "" else "" end' <<<"$body")
        [[ -n "$more" ]] || break
        cursor="$more"
    done
    jq -nc --arg status "$status" --arg reason "$reason" --slurpfile findings "$acc" '
        {source: {name: "gitlab", status: $status, reason: (if $reason == "" then null else $reason end), count: 0},
         findings: $findings[0]}'
    rm -rf "$work"
}

SI_MOD_RECIPE=org.openrewrite.java.dependencies.DependencyVulnerabilityCheck
SI_MOD_TABLE=org.openrewrite.java.dependencies.table.VulnerabilityReport
SI_MOD_RH_RECIPE_PATH='.recipeId'
SI_MOD_RH_SCOPE_PATH='.recipeOptions.scope'
SI_MOD_ROW_PATH_COL=repositoryPath

SI_MOD_MAP='
def opt: if . == null or . == "" then null else . end;
def cwes: (.CWEs // "" | tostring) | [splits("[,;]")] | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))
          | map(if test("^[0-9]+$") then "CWE-" + . else . end);
[to_entries[] | .key as $i | .value
 | select(.[$col] == $path and .repositoryOrigin == $origin)
 | {source: "moderne", native_id: "VulnerabilityReport:row:\($i)", kind: "dependency",
    severity_raw: .severity, severity_origin: "source",
    title: ((.summary | opt) // .cve),
    package: {name: "\(.groupId):\(.artifactId)", version: (.version | opt),
              fix_version: (.fixedVersion | opt),
              depth: (.depth | opt | if . == null then null elif type == "number" then (if . == 0 then "direct" else "transitive" end) else ascii_downcase end),
              scope: $scope},
    identifiers: ([.cve | opt] | map(select(. != null))) + cwes,
    locations: [], url: null, solution: null,
    epss: (.epss | if type == "number" then . elif type == "string" then (tonumber? // null) else null end),
    as_of: $as_of}]
'

# si_mod_as_of <run id> -> local ISO-8601 time from the YYYYMMDDHHMMSS run id prefix
si_mod_as_of() {
    local ts="${1%%-*}" z
    z=$(date +%z)
    printf '%s-%s-%sT%s:%s:%s%s:%s' "${ts:0:4}" "${ts:4:2}" "${ts:6:2}" "${ts:8:2}" "${ts:10:2}" "${ts:12:2}" "${z:0:3}" "${z:3:2}"
}

si_source_moderne() {
    local dir="$1" moderne_run="$2" work rc=0 msg listing history entry run_id scope origin path as_of
    command -v mod >/dev/null 2>&1 || { si_skipped moderne "mod not installed"; return 0; }
    if [[ ! -f "$dir/pom.xml" && ! -f "$dir/build.gradle" && ! -f "$dir/build.gradle.kts" ]]; then
        si_skipped moderne "not a JVM project; DependencyVulnerabilityCheck covers Maven and Gradle only"
        return 0
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/si-mod.XXXXXX")
    listing=$(mod list --json "$dir" 2>/dev/null) || rc=$?
    origin=$(jq -r '.[0].origin // empty' <<<"$listing" 2>/dev/null) || origin=""
    path=$(jq -r '.[0].path // empty' <<<"$listing" 2>/dev/null) || path=""
    if [[ "$rc" -ne 0 || -z "$origin" || -z "$path" ]]; then
        si_skipped moderne "no Moderne LST for this repository; run: mod build ."
        rm -rf "$work"
        return 0
    fi
    if [[ "$moderne_run" == 1 ]]; then
        mod build "$dir" >&2 2>"$work/err" || {
            si_skipped moderne "mod build failed: $(head -n 1 "$work/err")"; cat "$work/err" >&2; rm -rf "$work"; return 0; }
        cat "$work/err" >&2
        mod run "$dir" --recipe "$SI_MOD_RECIPE" >&2 2>"$work/err" || {
            si_skipped moderne "mod run failed: $(head -n 1 "$work/err")"; cat "$work/err" >&2; rm -rf "$work"; return 0; }
        cat "$work/err" >&2
    fi
    history=$(mod run-history --json --most-recent "$dir" 2>/dev/null) || history=""
    if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$history"; then
        si_skipped moderne "run-history output not understood"
        rm -rf "$work"
        return 0
    fi
    entry=$(jq -c --arg r "$SI_MOD_RECIPE" "[to_entries[] | select((.value | $SI_MOD_RH_RECIPE_PATH) == \$r)] | sort_by(.key) | last // empty" <<<"$history")
    if [[ -z "$entry" ]]; then
        si_skipped moderne "no DependencyVulnerabilityCheck run for this repository; run: mod run . --recipe $SI_MOD_RECIPE"
        rm -rf "$work"
        return 0
    fi
    run_id=$(jq -r .key <<<"$entry")
    scope=$(jq -c "(.value | $SI_MOD_RH_SCOPE_PATH) // null" <<<"$entry")
    as_of=$(si_mod_as_of "$run_id")
    rc=0
    mod study "$dir" "--recipe-run=$run_id" --data-table "$SI_MOD_TABLE" --json >"$work/study.json" 2>"$work/err" || rc=$?
    if [[ "$rc" -ne 0 ]] || ! jq -e 'type == "array"' "$work/study.json" >/dev/null 2>&1; then
        msg=$(head -n 1 "$work/err")
        si_skipped moderne "mod study failed: ${msg:-exit $rc, no error output}"
        rm -rf "$work"
        return 0
    fi
    jq -c --arg col "$SI_MOD_ROW_PATH_COL" --arg path "$path" --arg origin "$origin" --arg as_of "$as_of" \
        --argjson scope "$scope" "$SI_MOD_MAP" "$work/study.json" > "$work/findings.json"
    jq -nc --slurpfile findings "$work/findings.json" '
        {source: {name: "moderne", status: "ok", reason: null, count: 0}, findings: $findings[0]}'
    rm -rf "$work"
}

si_collect() {
    local dir="$1" moderne_run="${2:-0}" repo forge host reason results=""
    repo=$(si_repo_json "$dir")
    forge=$(jq -r .forge <<<"$repo")
    host=$(jq -r '.host // ""' <<<"$repo")
    if [[ "$forge" == "unknown" ]]; then
        if [[ -n "$host" ]]; then reason="host $host is not known to gh or glab"; else reason="no git remote"; fi
        results="$(si_skipped gitlab "$reason")
$(si_skipped github "$reason")"
    fi
    if [[ "$forge" == "gitlab" ]]; then
        results="$(si_source_gitlab "$host" "$(jq -r .path <<<"$repo")")"
    fi
    if [[ "$forge" == "github" ]]; then
        results="$(si_source_github "$host" "$(jq -r .path <<<"$repo")")"
    fi
    results="$results
$(si_source_moderne "$dir" "$moderne_run")"
    printf '%s\n' "$results" | jq -sc --argjson repo "$repo" '{repo: $repo, results: .}' | si_shape
}

if [[ -z "${SECURITY_INSIGHTS_LIB:-}" ]]; then si_main "$@"; fi
