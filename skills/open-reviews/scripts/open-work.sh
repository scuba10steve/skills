#!/usr/bin/env bash
# open-work — your open PRs/MRs/issues across forges, joined to live agent sessions.
# In library mode (sourced by the test harness) skip -e and do not dispatch.
if [[ -z "${OPEN_WORK_LIB:-}" ]]; then set -euo pipefail; fi

STALE_DAYS=3   # Hardcoded. No env override — an untested knob
               # that silently changes classification is worse than no knob.

open_work_usage() {
    cat <<'USAGE'
Usage: open-work [--from-json <file>] [--reviews-only] [--exclude-reviewed] [--help]

Emits one JSON document: your open work items across GitHub and GitLab,
plus live local agent sessions, joined by repository.

  --from-json <file>  Skip collection; shape this document instead (testing)
  --reviews-only      Only collect items awaiting your review
  --exclude-reviewed  Drop items you have already reviewed (GitLab: already approved)
  -h, --help          This help
USAGE
}

open_work_main() {
    local from_json="" reviews_only="" exclude_reviewed=""
    while (( $# )); do
        case "$1" in
            --from-json) [[ $# -ge 2 ]] || { echo "--from-json needs a file" >&2; return 1; }
                         from_json="$2"; shift 2 ;;
            --reviews-only) reviews_only=1; shift ;;
            --exclude-reviewed) exclude_reviewed=1; shift ;;
            -h|--help)   open_work_usage; return 0 ;;
            *)           echo "Unknown flag: $1" >&2; open_work_usage >&2; return 1 ;;
        esac
    done
    if [[ -n "$from_json" ]]; then
        [[ -f "$from_json" ]] || { echo "No such file: $from_json" >&2; return 1; }
        shape < "$from_json"
    else
        collect "$reviews_only" "$exclude_reviewed" | shape
    fi
}

# normalize_repo_id <remote-url> -> host/full/path  (empty if unparseable)
normalize_repo_id() {
    local url="${1:-}" host path
    [[ -n "$url" ]] || { printf ''; return 0; }
    while [[ "$url" == */ ]]; do url="${url%/}"; done  # strip trailing slashes
    url="${url%.git}"
    case "$url" in
        https://*|http://*)
            url="${url#*://}"
            host="${url%%/*}"
            path="${url#*/}"
            ;;
        ssh://*)
            url="${url#ssh://}"
            url="${url#*@}"          # ssh://git@host/path -> host/path
            host="${url%%/*}"
            path="${url#*/}"
            ;;
        git@*:*)
            url="${url#git@}"
            host="${url%%:*}"
            path="${url#*:}"
            ;;
        *) printf ''; return 0 ;;
    esac
    host="${host##*@}"   # drop any credentials
    host="${host%%:*}"   # drop any port
    if [[ -z "$path" || "$path" == "$url" ]]; then printf ''; return 0; fi
    # Host is deliberately not case-folded: GitLab.COM/Group/Repo normalizes to GitLab.COM/Group/Repo.
    # That is acceptable since real forge URLs are consistently lowercase, but it is undocumented.
    # Path is not case-folded since repository paths are case-sensitive.
    printf '%s/%s' "$host" "$path"
}

# last_conversation_ts <cwd> -> newest user/assistant timestamp in that project's transcripts
last_conversation_ts() {
    local cwd="${1:-}" slug dir f newest="" t
    [[ -n "$cwd" ]] || return 1
    slug="-${cwd#/}"
    slug="${slug//\//-}"
    slug="${slug//./-}"
    dir="$HOME/.claude/projects/$slug"
    [[ -d "$dir" ]] || return 1
    for f in "$dir"/*.jsonl; do
        [[ -f "$f" ]] || continue
        # Malformed lines are skipped INSIDE jq via `fromjson?`, so jq exits 0
        # and still emits the good timestamps. An earlier draft instead wrote
        # `| tail -1) || t=""` with a plain jq filter -- but under pipefail one
        # bad line made jq exit non-zero, and the guard then threw away
        # timestamps jq had already produced, contradicting this task's own
        # test. Verified: one good record followed by a malformed line returns
        # the good timestamp with exit 0; only-untimestamped still returns 1.
        # tail -n 800: bound against trailing untimestamped records (type=mode/system).
        # If >800 untimestamped lines follow the last user/assistant turn, the
        # bound prevents accessing it; the function returns non-zero (unknown).
        # Worst observed in live transcripts: 10 trailing untimestamped lines (80× headroom).
        t=$(tail -n 800 "$f" 2>/dev/null \
            | jq -Rr 'fromjson? // empty
                      | select((.type=="user" or .type=="assistant") and .timestamp != null)
                      | .timestamp' 2>/dev/null \
            | tail -1) || t=""
        [[ -n "$t" ]] || continue
        # Lexical comparison works because all measured timestamps have uniform precision (milliseconds).
        if [[ -z "$newest" || "$t" > "$newest" ]]; then newest="$t"; fi
    done
    [[ -n "$newest" ]] || return 1
    printf '%s' "$newest"
}

# collect_sessions -> {"sessions": [ ... ], "errors": { }}
# The errors map is not decoration: a broken discovery tool and a machine with no
# agents running both produce an empty sessions array, and the reader cannot tell
# them apart. Every item would render `no session` and Stale would show 0 — a
# failure rendered as emptiness, which is the one thing this tool must never do.
# Only the key `sessions` is ever set here; it cannot collide with collect_items'
# seven <forge>_<bucket> keys when the two maps are merged in collect().
collect_sessions() {
    # Check the discovery tools (pgrep, lsof, ps) before anything else runs: without
    # them there is nothing to discover, and the caller needs to be told rather than
    # handed an empty list.
    if ! command -v pgrep >/dev/null 2>&1; then
        jq -nc '{sessions: [], errors: {sessions: "pgrep not found — session discovery unavailable"}}'
        return 0
    fi
    local missing
    for missing in lsof ps; do
        if ! command -v "$missing" >/dev/null 2>&1; then
            jq -nc --arg err "$missing not found — session discovery unavailable" \
              '{sessions: [], errors: {sessions: $err}}'
            return 0
        fi
    done
    local agents=(claude codex opencode gemini) agent pid cwd root origin branch tty
    local now ts idle repo_id
    local sess_err="" pgrep_rc pids n_pids=0 n_cwds=0 tmp_sess
    now=$(date -u +%s)
    # Sessions accumulate in a file rather than a `{ ... } | jq -s` pipeline: a
    # pipeline's left side runs in a subshell, so the counters and sess_err this
    # function now needs would be discarded on exit from it.
    tmp_sess="$(mktemp "${TMPDIR:-/tmp}/open-work-sess.XXXXXX")"
    trap 'rm -f "$tmp_sess"' RETURN
    for agent in "${agents[@]}"; do
        pgrep_rc=0
        # `|| pgrep_rc=$?`, never a bare assignment: pgrep exits 1 whenever nothing
        # matched, which is the normal case, and a bare capture would abort the shell
        # under set -e.
        pids="$(pgrep -x "$agent" 2>/dev/null)" || pgrep_rc=$?
        # Rule 2: 0 = matched, 1 = no match (legitimate), >1 = pgrep itself failed.
        # First error wins; one key holds one message, and the earliest fault is the
        # most likely cause of whatever follows it.
        if (( pgrep_rc > 1 )) && [[ -z "$sess_err" ]]; then
            sess_err="pgrep failed for $agent (exit $pgrep_rc) — session list may be incomplete"
        fi
        for pid in $pids; do
            n_pids=$(( n_pids + 1 ))
            cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)" || cwd=""
            # A single unresolved cwd is a race (the process exited mid-scan), not a
            # fault: skip it. Rule 3 below is what notices a wholesale lsof failure.
            [[ -n "$cwd" ]] || continue
            n_cwds=$(( n_cwds + 1 ))
            # Exclude the claude-mem observer by path, not by TTY: TTY presence is
            # not a reliable discriminator for an interactive session.
            case "$cwd" in *".claude-mem/observer-sessions"*) continue ;; esac
            tty="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')" || tty=""
            root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
            origin=$(git -C "$cwd" remote get-url origin 2>/dev/null || true)
            branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
            repo_id=$(normalize_repo_id "$origin")
            idle=null
            if [[ "$agent" == "claude" ]]; then
                if ts=$(last_conversation_ts "$cwd" 2>/dev/null); then
                    local epoch
                    epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${ts%%.*}" +%s 2>/dev/null \
                            || date -u -d "${ts}" +%s 2>/dev/null || echo "")
                    # An `if`, not `[[ -n "$epoch" ]] && idle=...`: a trailing false
                    # && list would be the last command of this block, so its status
                    # becomes the block's and aborts the shell under set -e.
                    if [[ -n "$epoch" ]]; then idle=$(( now - epoch )); fi
                fi
            fi
            jq -nc --arg pid "$pid" --arg tty "$tty" --arg agent "$agent" \
                   --arg cwd "$cwd" --arg root "$root" --arg repo_id "$repo_id" \
                   --arg branch "$branch" --argjson idle "$idle" \
              '{pid: ($pid|tonumber), tty: $tty, agent: $agent, cwd: $cwd,
                root: $root, repo_id: $repo_id, branch: $branch, idle_seconds: $idle}' >> "$tmp_sess"
        done
    done
    # Rule 3: processes found but not one working directory resolved. Per-pid misses
    # are races; zero out of N is lsof being unavailable or failing outright.
    if (( n_pids > 0 && n_cwds == 0 )) && [[ -z "$sess_err" ]]; then
        sess_err="found $n_pids agent process(es) but resolved no working directories — lsof unavailable or failing"
    fi
    jq -sc --arg err "$sess_err" \
      '{sessions: ., errors: (if $err == "" then {} else {sessions: $err} end)}' < "$tmp_sess"
}

# Each parser: $1 = bucket (review|authored|assigned); stdin = CLI payload.
# Non-array input is an error, never zero items.
#
# NOTE the explicit `doc="$(_require_array)" || return 1` form. Do NOT write this
# as `_require_array | jq ...`: a pipeline's exit status is jq's, and jq exits 0
# on empty stdin. Verified: without `pipefail` the piped form returns rc=0 on an
# HTTP 400 payload, silently turning an error into zero items — the exact R1
# failure this guard exists to prevent. Library mode skips `set -euo pipefail`,
# so the function must not depend on the caller having set it.
_require_array() {
    local doc; doc="$(cat)"
    [[ "$(printf '%s' "$doc" | jq -r 'type' 2>/dev/null)" == "array" ]] || return 1
    printf '%s' "$doc"
}

parse_gh_prs() {
    local bucket="$1" doc
    doc="$(_require_array)" || return 1
    printf '%s' "$doc" | jq -c --arg b "$bucket" '
      [ .[] | {forge:"github", host:"github.com",
               repo_id:("github.com/" + .repository.nameWithOwner),
               id:(.id // (.number|tostring)), display_id:("#" + (.number|tostring)),
               title:.title, created_at:.createdAt, branch:null, bucket:$b,
               url:(.url // null),
               is_draft:(.isDraft // false),
               author:(.author.login // null),
               is_bot:(.author.is_bot // false)} ]'
}

parse_gh_issues() {
    local bucket="$1" doc
    doc="$(_require_array)" || return 1
    printf '%s' "$doc" | jq -c --arg b "$bucket" '
      [ .[] | {forge:"github", host:"github.com",
               repo_id:("github.com/" + .repository.nameWithOwner),
               id:(.id // (.number|tostring)), display_id:("#" + (.number|tostring)),
               title:.title, created_at:.createdAt, branch:null, bucket:$b,
               url:(.url // null),
               is_draft:false,
               author:(.author.login // null),
               is_bot:(.author.is_bot // false)} ]'
}

parse_glab_mrs() {
    local bucket="$1" doc
    doc="$(_require_array)" || return 1
    printf '%s' "$doc" | jq -c --arg b "$bucket" '
      [ .[] | {forge:"gitlab", host:"gitlab.com",
               # repo_id strips a host port, exactly as normalize_repo_id does: the
               # identity of a repo must not depend on whether it was cloned over
               # https:443 or ssh:2222, or an item on a self-hosted forge could never
               # join a session in its local clone. The sub is anchored to the host
               # segment, so a colon inside a path segment is left alone.
               repo_id:(.web_url | sub("^https?://"; "") | split("/-/")[0]
                        | sub("^(?<h>[^/:]+):[0-9]+"; .h)),
               id:(.id|tostring), display_id:("!" + (.iid|tostring)),
               title:.title, created_at:.created_at,
               branch:(.source_branch // null), bucket:$b,
               url:(.web_url // null),
               is_draft:(.draft // false),
               author:(.author.username // null),
               is_bot:(.author.bot // false)} ]'
}

parse_glab_issues() {
    local bucket="$1" doc
    doc="$(_require_array)" || return 1
    printf '%s' "$doc" | jq -c --arg b "$bucket" '
      [ .[] | {forge:"gitlab", host:"gitlab.com",
               # repo_id strips a host port, exactly as normalize_repo_id does: the
               # identity of a repo must not depend on whether it was cloned over
               # https:443 or ssh:2222, or an item on a self-hosted forge could never
               # join a session in its local clone. The sub is anchored to the host
               # segment, so a colon inside a path segment is left alone.
               repo_id:(.web_url | sub("^https?://"; "") | split("/-/")[0]
                        | sub("^(?<h>[^/:]+):[0-9]+"; .h)),
               id:(.id|tostring), display_id:("#" + (.iid|tostring)),
               title:.title, created_at:.created_at, branch:null, bucket:$b,
               url:(.web_url // null),
               is_draft:false,
               author:(.author.username // null),
               is_bot:(.author.bot // false)} ]'
}

# GH_LIMIT sets the page size for BOTH CLIs and is the sole yardstick for the
# truncation check in _try (`n >= GH_LIMIT`). It must stay <= 100: `gh` accepts up
# to 1000, but a single `glab` page caps at 100, so a higher value would make every
# GitLab request return fewer items than the threshold and GitLab truncation would
# silently never be reported. Raising it requires splitting this into two limits,
# one per CLI, and comparing each request against its own.
GH_LIMIT=100
# GH_PR_BRANCH_LOOKUP_CAP bounds the number of `gh pr view` calls made to resolve
# GitHub PR head branches (gh search prs cannot return one). Each lookup is a
# separate API call; without a cap, a GH_LIMIT-sized result would fan out into
# that many sequential calls every run. A PR left unresolved by the cap degrades
# to repository-level matching (branch stays null) rather than failing the run.
GH_PR_BRANCH_LOOKUP_CAP=25
collect_items() {
    local reviews_only="${1:-}" exclude_reviewed="${2:-}"
    local errors='{}' limits='{}' items='[]' uid
    local TMPDIR_ERR; TMPDIR_ERR="$(mktemp "${TMPDIR:-/tmp}/open-work-err.XXXXXX")"
    trap 'rm -f "$TMPDIR_ERR"' RETURN
    _try() {  # $1 = key, $2 = parser fn, $3 = bucket, rest = command
        local key="$1" parser="$2" bucket="$3"; shift 3
        local payload payload_stderr parsed n exit_code=0
        # Capture stdout and stderr separately to prevent CLI notices (deprecation warnings, etc.)
        # from corrupting the JSON payload. Reuse TMPDIR_ERR; each call truncates it via 2>
        payload="$("$@" 2>"$TMPDIR_ERR")" || exit_code=$?
        payload_stderr="$(cat "$TMPDIR_ERR" 2>/dev/null)"
        if (( exit_code != 0 )); then
            errors=$(jq -c --arg k "$key" --arg v "$payload${payload_stderr:+$'\n'}$payload_stderr" '. + {($k): $v}' <<<"$errors"); return
        fi
        if ! parsed="$(printf '%s' "$payload" | "$parser" "$bucket")"; then
            errors=$(jq -c --arg k "$key" --arg v "$payload${payload_stderr:+$'\n'}$payload_stderr" '. + {($k): ("unexpected payload: " + $v)}' <<<"$errors"); return
        fi
        n=$(printf '%s' "$parsed" | jq 'length')
        (( n >= GH_LIMIT )) && limits=$(jq -c --arg k "$key" '. + {($k): true}' <<<"$limits")
        items=$(jq -c -s 'add' <<<"$items$parsed")
    }

    # A separate argv entry, never appended to the preceding term: `gh` quotes a
    # multi-term positional string as a single term and the API rejects it with
    # "Invalid search query". The term starts with `-`, so it must follow `--`
    # (after every flag) or gh parses it as a flag.
    local gh_excl=()
    [[ -n "$exclude_reviewed" ]] && gh_excl=(-- "-reviewed-by:@me")
    _try github_review   parse_gh_prs    review   gh search prs "user-review-requested:@me" --state=open --limit $GH_LIMIT --json number,id,title,createdAt,repository,url,isDraft,author ${gh_excl+"${gh_excl[@]}"}
    if [[ -z "$reviews_only" ]]; then
        _try github_authored parse_gh_prs    authored gh search prs --author=@me --state=open --limit $GH_LIMIT --json number,id,title,createdAt,repository,url,isDraft,author
        _try github_assigned parse_gh_issues assigned gh search issues --assignee=@me --state=open --limit $GH_LIMIT --json number,id,title,createdAt,repository,url,author
    fi

    # `gh search prs` cannot return a head ref, but `gh pr view` can. Resolve it
    # per PR, bounded by GH_PR_BRANCH_LOOKUP_CAP.
    # PRs only — github_assigned above is issues, and an issue has no branch, so
    # it is never touched here. A lookup that fails or is left uncapped simply
    # leaves that item's branch null, which renders at the repo level; it
    # never drops the item or fails the run.
    local gh_pr_total gh_pr_resolved=0 gh_pr_attempted=0
    gh_pr_total=$(printf '%s' "$items" | jq '[.[] | select(.forge=="github" and (.bucket=="review" or .bucket=="authored"))] | length')
    if (( gh_pr_total > 0 )); then
        local pr_id pr_repo pr_num pr_branch pr_ec
        while IFS=$'\t' read -r pr_id pr_repo pr_num; do
            (( gh_pr_attempted >= GH_PR_BRANCH_LOOKUP_CAP )) && break
            gh_pr_attempted=$(( gh_pr_attempted + 1 ))
            pr_ec=0
            # `|| pr_ec=$?`, never a bare assignment: same discipline as _try and the
            # /user lookup above — a bare `x="$(cmd)"` aborts under set -e.
            pr_branch="$(gh pr view "$pr_num" --repo "$pr_repo" --json headRefName -q .headRefName 2>/dev/null)" || pr_ec=$?
            if (( pr_ec == 0 )) && [[ -n "$pr_branch" ]]; then
                items=$(jq -c --arg id "$pr_id" --arg b "$pr_branch" \
                  'map(if .forge == "github" and .id == $id then .branch = $b else . end)' <<<"$items")
                gh_pr_resolved=$(( gh_pr_resolved + 1 ))
            fi
        done < <(printf '%s' "$items" | jq -r '
          .[] | select(.forge=="github" and (.bucket=="review" or .bucket=="authored"))
              | [.id, (.repo_id | ltrimstr("github.com/")), (.display_id | ltrimstr("#"))]
              | @tsv')
        local gh_pr_left=$(( gh_pr_total - gh_pr_resolved ))
        if (( gh_pr_left > 0 )); then
            errors=$(jq -c --arg v "resolved $gh_pr_resolved of $gh_pr_total GitHub PR head branches; $gh_pr_left left at repository level" \
              '. + {github_pr_branches: $v}' <<<"$errors")
        fi
    fi

    local uid_payload uid_stderr
    # Capture stdout and stderr separately: this is one of the eight requests, and the global rule is
    # that a failed query surfaces the CLI's own text rather than vanishing. glab returns
    # structured errors in the body (stdout) with a terse summary on stderr; we need both.
    # Capturing separately ensures jq only parses the JSON body, not stderr noise.
    # `|| true` for the same reason _try uses `|| exit_code=$?`: a bare assignment from a
    # failing command substitution aborts under set -e, which would make an auth failure
    # render as emptiness. glab exits non-zero on auth failure and we still need its body;
    # the status is not consulted because the `.username` check below decides success.
    uid_payload="$(glab api /user 2>"$TMPDIR_ERR")" || true
    uid_stderr="$(cat "$TMPDIR_ERR" 2>/dev/null)"
    if uid="$(printf '%s' "$uid_payload" | jq -r '.username // empty' 2>/dev/null)" && [[ -n "$uid" ]]; then
        local gl_excl=""
        [[ -n "$exclude_reviewed" ]] && gl_excl="&not[approved_by_usernames][]=$uid"
        _try gitlab_review parse_glab_mrs review glab api "/merge_requests?state=opened&reviewer_username=$uid&per_page=$GH_LIMIT$gl_excl"
    else
        errors=$(jq -c --arg v "could not resolve GitLab identity from /user: $uid_payload${uid_stderr:+$'\n'}$uid_stderr" \
                 '. + {gitlab_review: $v}' <<<"$errors")
    fi
    if [[ -z "$reviews_only" ]]; then
        _try gitlab_authored parse_glab_mrs    authored glab api "/merge_requests?state=opened&scope=created_by_me&per_page=$GH_LIMIT"
        _try gitlab_assigned parse_glab_mrs    assigned glab api "/merge_requests?state=opened&scope=assigned_to_me&per_page=$GH_LIMIT"
        _try gitlab_issues   parse_glab_issues assigned glab api "/issues?state=opened&scope=assigned_to_me&per_page=$GH_LIMIT"
    fi

    jq -nc --argjson items "$items" --argjson errors "$errors" --argjson limits "$limits" \
      '{items: $items, errors: $errors, limits: $limits}'
}

collect() {
    local reviews_only="${1:-}" exclude_reviewed="${2:-}"
    local sessions forge
    # collect_sessions now returns {sessions, errors}; unwrap the array and merge its
    # error map into the document's single flat .errors. The two maps share no keys:
    # sessions uses only `sessions`, collect_items only `<forge>_<bucket>`. The
    # document's top-level shape is unchanged, so shape() and --from-json are untouched.
    sessions="$(collect_sessions)"
    forge="$(collect_items "$reviews_only" "$exclude_reviewed")"
    jq -nc --argjson sessions "$sessions" --argjson forge "$forge" \
      '{sessions: $sessions.sessions,
        items: $forge.items, errors: ($forge.errors + $sessions.errors), limits: $forge.limits}'
}

shape() {
    jq -c --argjson stale_secs "$(( STALE_DAYS * 86400 ))" '
      def rank: {"review":0,"authored":1,"assigned":2}[.bucket] // 9;

      .sessions |= map(
        .state = (if   .idle_seconds == null      then "unknown"
                  elif .idle_seconds > $stale_secs then "stale"
                  else "active" end)
        | .matched = false)

      | .items = ( .items
          | group_by(.forge + "|" + .host + "|" + .id)
          | map(sort_by(rank) | .[0])
          | sort_by(.created_at, .forge, .id) )  # tie-break skips .host, which the group_by key includes; bites when one forge spans two hosts

      | ( .sessions | map(select(.agent == "claude")) ) as $s
      | .items |= map(
          . as $i
          | .matches = ( $s
              | map(select($i.repo_id != "" and .repo_id == $i.repo_id))
              | sort_by([ (if .state == "active" then 0
                           elif .state == "stale" then 1
                           else 2 end),
                          (.idle_seconds // 9999999999),
                          .pid ]) )
          | .status = (
              if   (.matches | length) == 0 then "no-session"
              elif $i.branch == null then "session-repo-only"
              elif any(.matches[]; .branch == $i.branch) then "session"
              else "session-other-branch" end)
          | .session_state = (.matches[0].state // null) )

      | ( [ .items[].matches[]?.pid ] | unique ) as $matched_pids
      | .sessions |= map(.matched = ([.pid] | inside($matched_pids)))
    '
}

if [[ -z "${OPEN_WORK_LIB:-}" ]]; then open_work_main "$@"; fi
