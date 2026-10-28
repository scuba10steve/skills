#!/usr/bin/env bash
# task-estimate — estimate token usage for a task prompt and recommend a provider routing strategy.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: task-estimate [flags] "<prompt>"

Estimate token usage for a task and produce a provider routing recommendation.

Flags:
  --deep            Request deep-scope analysis (skill wrapper only)
  --breakdown       Show per-phase breakdown in human output
  --json            Emit JSON to stdout instead of human format
  --no-split        Skip split-prompt generation at L/XL
  -h, --help        Show this help
EOF
}

# --- arg parsing ---

REQUESTED_DEEP=0
SHOW_BREAKDOWN=0
EMIT_JSON=0
NO_SPLIT=0
PROMPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deep)       REQUESTED_DEEP=1; shift ;;
        --breakdown)  SHOW_BREAKDOWN=1; shift ;;
        --json)       EMIT_JSON=1; shift ;;
        --no-split)   NO_SPLIT=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        --*)          echo "Unknown flag: $1" >&2; usage >&2; exit 1 ;;
        *)            if [[ -z "$PROMPT" ]]; then PROMPT="$1"; shift
                      else echo "Unexpected positional arg: $1" >&2; usage >&2; exit 1; fi ;;
    esac
done

if [[ -z "$PROMPT" ]]; then
    echo "Missing prompt argument." >&2
    usage >&2
    exit 1
fi

# --- config ---

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_PATH="$CONFIG_HOME/scuba10steve-skills/task-estimate.json"

DEFAULT_CONFIG=$(cat <<'JSON'
{
  "buckets": {"s": 15000, "m": 40000, "l": 75000},
  "session_cap": 100000,
  "verbs": {
    "refactor|migrate|audit|investigate|overhaul": 3.0,
    "implement|build|create|port|convert|switch": 2.0,
    "plan|design|explore|approach|strategy": 2.0,
    "fix|update|tweak|adjust|add": 1.0,
    "typo|rename|one-liner": 0.3
  },
  "scope_adverbs": {
    "everywhere|across|all of|repo-wide|entire|everything": 2.0,
    "all things|all the|would touch|touches": 1.5,
    "this file|just this|only": 0.5
  },
  "phase_split": {"read": 0.4, "plan": 0.15, "edit": 0.3, "verify": 0.15},
  "multi_agent": {
    "per_agent_base": 28000,
    "verb_to_agents": {
      "refactor|migrate|audit|investigate|overhaul": 4,
      "implement|build|create|port|convert|switch": 2,
      "plan|design|explore|approach|strategy": 3,
      "typo|rename|one-liner": 0,
      "fix|update|tweak|adjust|add": 1
    },
    "default_agents": 1
  }
}
JSON
)

load_config() {
    local dir
    dir="$(dirname "$CONFIG_PATH")"
    if [[ ! -f "$CONFIG_PATH" ]]; then
        if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
            printf '%s\n' "$DEFAULT_CONFIG" > "$CONFIG_PATH" 2>/dev/null || true
        fi
        printf '%s\n' "$DEFAULT_CONFIG"
        return
    fi
    # Deep merge: user values win; anything the user's file omits comes from the defaults.
    jq -s '.[0] * .[1]' <(printf '%s' "$DEFAULT_CONFIG") "$CONFIG_PATH" 2>/dev/null || {
        echo "error: cannot parse $CONFIG_PATH" >&2
        exit 1
    }
}

need_jq() { command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }; }
need_jq

CONFIG_JSON="$(load_config)" || exit 1

BUCKET_S=$(echo "$CONFIG_JSON" | jq -r '.buckets.s')
BUCKET_M=$(echo "$CONFIG_JSON" | jq -r '.buckets.m')
BUCKET_L=$(echo "$CONFIG_JSON" | jq -r '.buckets.l')
SESSION_CAP=$(echo "$CONFIG_JSON" | jq -r '.session_cap')

# --- heuristic ---

# Base token floor: prompt char count / 4 (rough English tokenization heuristic).
# Plus a flat 3750-token planning overhead so trivial prompts aren't zeroed out.
# (Initial calibration set this to 3000; bumped +25% so verb-amplified prompts
# reach M/L without requiring scope-adverb hits.)
prompt_token_floor() {
    local chars
    chars=$(printf '%s' "$PROMPT" | wc -c | tr -d ' ')
    echo $(( chars / 4 + 3750 ))
}

apply_verb_multiplier() {
    local base="$1" multiplier=1.0 pattern
    while IFS= read -r pattern; do
        if printf '%s' "$PROMPT" | grep -qiE "\\b($pattern)\\b"; then
            multiplier=$(echo "$CONFIG_JSON" | jq -r --arg p "$pattern" '.verbs[$p]')
            break
        fi
    done < <(echo "$CONFIG_JSON" | jq -r '.verbs | keys_unsorted[]')
    awk -v b="$base" -v m="$multiplier" 'BEGIN { printf "%d\n", b * m }'
}

apply_scope_multiplier() {
    local base="$1" multiplier=1.0 pattern
    while IFS= read -r pattern; do
        if printf '%s' "$PROMPT" | grep -qiE "($pattern)"; then
            multiplier=$(echo "$CONFIG_JSON" | jq -r --arg p "$pattern" '.scope_adverbs[$p]')
            break
        fi
    done < <(echo "$CONFIG_JSON" | jq -r '.scope_adverbs | keys_unsorted[]')
    awk -v b="$base" -v m="$multiplier" 'BEGIN { printf "%d\n", b * m }'
}

get_scope_multiplier_value() {
    local pattern
    while IFS= read -r pattern; do
        if printf '%s' "$PROMPT" | grep -qiE "($pattern)"; then
            echo "$CONFIG_JSON" | jq -r --arg p "$pattern" '.scope_adverbs[$p]'
            return
        fi
    done < <(echo "$CONFIG_JSON" | jq -r '.scope_adverbs | keys_unsorted[]')
    echo "1.0"
}

# Estimate how many subagents this task will likely spawn, then add per-agent overhead.
# Each subagent independently reads repo context (~28k tokens on average).
get_agent_count() {
    local matched=0 count=0 pattern
    while IFS= read -r pattern; do
        if printf '%s' "$PROMPT" | grep -qiE "\\b($pattern)\\b"; then
            count=$(echo "$CONFIG_JSON" | jq -r --arg p "$pattern" '.multi_agent.verb_to_agents[$p] // 1')
            matched=1
            break
        fi
    done < <(echo "$CONFIG_JSON" | jq -r '(.multi_agent.verb_to_agents // {}) | keys_unsorted[]')
    if [[ "$matched" -eq 0 ]]; then
        count=$(echo "$CONFIG_JSON" | jq -r '.multi_agent.default_agents // 1')
    fi
    echo "$count"
}

# Heuristic running tally. Later tasks add path-derived and cwd-derived contributions.
EST_BASE=$(prompt_token_floor)

# --- path / repo extraction ---

extract_paths() {
    # Grab `/abs/path` and `~/path` sequences from the prompt.
    printf '%s' "$PROMPT" | grep -oE '(~|/)[A-Za-z0-9._/-]+' || true
}

path_contribution() {
    # ~2000 tokens per named path. Cap at 6 paths so a long file list doesn't dominate.
    local count=0
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        count=$((count + 1))
        [[ "$count" -ge 6 ]] && break
    done < <(extract_paths)
    echo $(( count * 2000 ))
}

cwd_signals() {
    # Modified file count in cwd (if in git); each modified file → +1500 tokens.
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local modified
        modified=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        echo $(( modified * 1500 ))
    else
        echo 0
    fi
}

EST_PATHS=$(path_contribution)
EST_CWD=$(cwd_signals)
EST_RAW=$(( EST_BASE + EST_PATHS + EST_CWD ))
EST_VERB=$(apply_verb_multiplier "$EST_RAW")
EST_TOTAL=$(apply_scope_multiplier "$EST_VERB")

# Multi-agent overhead: each spawned subagent reads repo context independently.
SCOPE_MULT_VAL=$(get_scope_multiplier_value)
AGENT_COUNT_RAW=$(get_agent_count)
AGENT_COUNT=$(awk -v b="$AGENT_COUNT_RAW" -v s="$SCOPE_MULT_VAL" 'BEGIN {
    n = int(b * s + 0.5)
    if (n < 0) n = 0
    printf "%d\n", n
}')
PER_AGENT_BASE=$(echo "$CONFIG_JSON" | jq -r '.multi_agent.per_agent_base // 28000')
MULTI_AGENT_EST=$(( AGENT_COUNT * PER_AGENT_BASE ))
EST_TOTAL=$(( EST_TOTAL + MULTI_AGENT_EST ))

EST_LOW=$(( EST_TOTAL * 60 / 100 ))
EST_HIGH=$(( EST_TOTAL * 250 / 100 ))

# --- bucket assignment ---

bucket_for() {
    local total="$1"
    if   [[ "$total" -lt "$BUCKET_S" ]]; then echo S
    elif [[ "$total" -lt "$BUCKET_M" ]]; then echo M
    elif [[ "$total" -lt "$BUCKET_L" ]]; then echo L
    else echo XL
    fi
}

BUCKET="$(bucket_for "$EST_TOTAL")"

# --- confidence ---

word_count() { printf '%s' "$PROMPT" | wc -w | tr -d ' '; }
has_paths()  { extract_paths | grep -q . ; }
has_git()    { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }

confidence_level() {
    local wc; wc=$(word_count)
    if [[ "$wc" -lt 10 ]] && ! has_paths && ! has_git; then
        echo low
    else
        echo medium
    fi
}

CONFIDENCE="$(confidence_level)"

if [[ "$CONFIDENCE" == "low" ]]; then
    echo "warn: low confidence — prompt is short, has no paths, and cwd is not in a git repo. Estimate may be inaccurate." >&2
fi

# --- phase breakdown ---

phase_share() {
    local key="$1"
    echo "$CONFIG_JSON" | jq -r --arg k "$key" '.phase_split[$k]'
}

# Verb-driven phase shift: "audit" → +20% read, -20% edit; "refactor" → +20% edit, -20% read.
phase_amount() {
    local key="$1" share base
    share=$(phase_share "$key")
    base=$(awk -v t="$EST_TOTAL" -v s="$share" 'BEGIN { printf "%d\n", t * s }')
    if printf '%s' "$PROMPT" | grep -qiE '\b(audit|investigate)\b'; then
        case "$key" in
            read) base=$(( base * 12 / 10 )) ;;
            edit) base=$(( base * 8 / 10 )) ;;
        esac
    fi
    if printf '%s' "$PROMPT" | grep -qiE '\b(refactor|migrate)\b'; then
        case "$key" in
            read) base=$(( base * 8 / 10 )) ;;
            edit) base=$(( base * 12 / 10 )) ;;
        esac
    fi
    echo "$base"
}

PH_READ=$(phase_amount read)
PH_PLAN=$(phase_amount plan)
PH_EDIT=$(phase_amount edit)
PH_VERIFY=$(phase_amount verify)

# Reconcile rounding so the breakdown sums to total ±1.
PH_SUM=$(( PH_READ + PH_PLAN + PH_EDIT + PH_VERIFY ))
PH_DELTA=$(( EST_TOTAL - PH_SUM ))
PH_VERIFY=$(( PH_VERIFY + PH_DELTA ))

# --- run id + artifacts ---

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/scuba10steve-skills/task-estimate"

# Deterministic-ish run id: short hash of prompt, prefixed with the date.
generate_run_id() {
    local hash
    hash=$(printf '%s\n' "$PROMPT" | shasum | cut -c1-6)
    printf 'task-estimate-%s-%s\n' "$(date +%Y%m%d)" "$hash"
}

RUN_ID="$(generate_run_id)"
RUN_DIR="$CACHE_DIR/$RUN_ID"

# --- providers ---

provider_for() {
    local phase="$1"
    echo "$CONFIG_JSON" | jq -r --arg ph "$phase" '.providers[$ph] // empty'
}

provider_suffix() { [[ -n "$1" ]] && printf ' (provider: %s)' "$1" || true; }

# --- phase-split prompts (L) ---

render_phase_split() {
    local p_plan p_edit p_verify
    p_plan=$(provider_for planning)
    p_edit=$(provider_for bulk_edit)
    p_verify=$(provider_for verify)

    local can_write=1
    if ! mkdir -p "$RUN_DIR" 2>/dev/null; then
        echo "warn: cannot create $RUN_DIR; printing prompts to stdout only" >&2
        can_write=0
    fi

    # Build the three prompt bodies as variables (so we can emit them even when can_write=0)
    local body1 body2 body3
    body1=$(cat <<EOF
# Phase 1/3 — planning$(provider_suffix "$p_plan")

Read the files implied by the task below and produce an implementation plan at
\`$RUN_DIR/plan.md\`. Do not edit any code yet.

Original task:
$PROMPT
EOF
)
    body2=$(cat <<EOF
# Phase 2/3 — bulk edits$(provider_suffix "$p_edit")

Execute the plan at \`$RUN_DIR/plan.md\`. Make edits only. Do not deviate.
EOF
)
    body3=$(cat <<EOF
# Phase 3/3 — verify$(provider_suffix "$p_verify")

Verify the diff produced by phase 2 against \`$RUN_DIR/plan.md\`.
Run the project-appropriate verification command and report results.
EOF
)

    if [[ "$can_write" -eq 1 ]]; then
        printf '%s\n' "$body1" > "$RUN_DIR/prompt-1.md" 2>/dev/null || echo "warn: failed to write prompt-1.md" >&2
        printf '%s\n' "$body2" > "$RUN_DIR/prompt-2.md" 2>/dev/null || echo "warn: failed to write prompt-2.md" >&2
        printf '%s\n' "$body3" > "$RUN_DIR/prompt-3.md" 2>/dev/null || echo "warn: failed to write prompt-3.md" >&2
        cat > "$RUN_DIR/README.md" 2>/dev/null <<EOF || echo "warn: failed to write README.md" >&2
# Task-estimate run $RUN_ID

Bucket: $BUCKET
Order: sequential (phase split)

1. prompt-1.md${p_plan:+ → $p_plan}
2. prompt-2.md${p_edit:+ → $p_edit}
3. prompt-3.md${p_verify:+ → $p_verify}

Shared scratch: $RUN_DIR/plan.md
EOF
    fi

    # Emit the prompt bodies as a JSON array for the --json branch.
    jq -nc --arg p1 "$body1" --arg p2 "$body2" --arg p3 "$body3" \
            --arg pp1 "$p_plan" --arg pp2 "$p_edit" --arg pp3 "$p_verify" \
        'def prov: if . == "" then null else . end;
             [{provider:($pp1|prov), body:$p1}, {provider:($pp2|prov), body:$p2}, {provider:($pp3|prov), body:$p3}]'
}

PROMPTS_JSON='[]'
if [[ "$NO_SPLIT" -eq 0 && "$BUCKET" == "L" ]]; then
    PROMPTS_JSON="$(render_phase_split)"
fi

# --- recommendation ---

recommendation_for() {
    case "$1" in
        S|M) printf 'Fits comfortably in one session.' ;;
        L)   printf 'Tight against session cap (~%dk). Consider phase-splitting below.' \
                 $(( SESSION_CAP / 1000 )) ;;
        XL)  printf 'Will overflow session cap (~%dk). Decompose into the scope-split prompts below.' \
                 $(( SESSION_CAP / 1000 )) ;;
    esac
}

RECOMMENDATION="$(recommendation_for "$BUCKET")"

# --- output ---

if [[ "$EMIT_JSON" -eq 1 ]]; then
    jq -nc \
        --arg bucket "$BUCKET" \
        --arg confidence "$CONFIDENCE" \
        --argjson total "$EST_TOTAL" --argjson low "$EST_LOW" --argjson high "$EST_HIGH" \
        --argjson read "$PH_READ" --argjson plan "$PH_PLAN" --argjson edit "$PH_EDIT" --argjson verify "$PH_VERIFY" \
        --arg recommendation "$RECOMMENDATION" \
        --argjson prompts "$PROMPTS_JSON" \
        --arg run_id "$RUN_ID" \
        --argjson requested_deep "$REQUESTED_DEEP" \
        --argjson agent_count "$AGENT_COUNT" \
        --argjson multi_agent_est "$MULTI_AGENT_EST" \
        '{bucket:$bucket, confidence:$confidence, method:"heuristic",
          estimate:{total:$total, low:$low, high:$high},
          breakdown:{read:$read, plan:$plan, edit:$edit, verify:$verify},
          agent_count:$agent_count, multi_agent_overhead:$multi_agent_est,
          recommendation:$recommendation,
          prompts:$prompts, run_id:$run_id, requested_deep:($requested_deep==1)}'
else
    printf '~%dk tokens (%dk–%dk) — %s, heuristic, confidence: %s\nEst. agents: %d\n' \
        $(( EST_TOTAL / 1000 )) $(( EST_LOW / 1000 )) $(( EST_HIGH / 1000 )) \
        "$BUCKET" "$CONFIDENCE" "$AGENT_COUNT"
    printf 'Recommendation: %s\n' "$RECOMMENDATION"
    if [[ "$SHOW_BREAKDOWN" -eq 1 ]]; then
        printf 'Breakdown: read %dk, plan %dk, edit %dk, verify %dk\n' \
            $(( PH_READ / 1000 )) $(( PH_PLAN / 1000 )) $(( PH_EDIT / 1000 )) $(( PH_VERIFY / 1000 ))
    fi
    if [[ "$PROMPTS_JSON" != "[]" ]]; then
        echo
        prompt_count=$(echo "$PROMPTS_JSON" | jq 'length')
        i=0
        while [[ "$i" -lt "$prompt_count" ]]; do
            prov=$(echo "$PROMPTS_JSON" | jq -r ".[$i].provider // empty")
            body=$(echo "$PROMPTS_JSON" | jq -r ".[$i].body")
            printf -- '--- prompt %d%s ---\n%s\n---\n' "$(( i + 1 ))" "${prov:+: $prov}" "$body"
            i=$((i + 1))
        done
        printf 'Artifacts: %s\n' "$RUN_DIR"
    fi
fi
exit 0
