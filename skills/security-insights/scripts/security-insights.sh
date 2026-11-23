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
  | {key: (first($adv[] | select(startswith("CVE-")))
           // first($adv[] | select(startswith("GHSA-")))
           // (if $first.kind == "dependency" and $first.package != null
               then "pkg:\($first.package.name)@\($first.package.version)"
               else "\($first.source):\($first.kind):\($first.native_id)" end)),
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

si_collect() {
    local dir="$1" repo forge host reason results=""
    repo=$(si_repo_json "$dir")
    forge=$(jq -r .forge <<<"$repo")
    host=$(jq -r '.host // ""' <<<"$repo")
    if [[ "$forge" == "unknown" ]]; then
        if [[ -n "$host" ]]; then reason="host $host is not known to gh or glab"; else reason="no git remote"; fi
        results="$(si_skipped gitlab "$reason")
$(si_skipped github "$reason")"
    fi
    printf '%s\n' "$results" | jq -sc --argjson repo "$repo" '{repo: $repo, results: .}' | si_shape
}

if [[ -z "${SECURITY_INSIGHTS_LIB:-}" ]]; then si_main "$@"; fi
