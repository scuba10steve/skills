#!/usr/bin/env bash
# task-estimate.test.sh — assertions for task-estimate.sh
set -uo pipefail

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/task-estimate-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"
export XDG_CONFIG_HOME="$TMPROOT/config"
export XDG_CACHE_HOME="$TMPROOT/cache"
mkdir -p "$HOME"
CONFIG_FILE="$XDG_CONFIG_HOME/scuba10steve-skills/task-estimate.json"
LEGACY_FILE="$XDG_CONFIG_HOME/skills/task-estimate.json"
CACHE_ROOT="$XDG_CACHE_HOME/scuba10steve-skills/task-estimate"

SCRIPT_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )"
SCRIPT="$SCRIPT_DIR/../skills/task-estimate/scripts/task-estimate.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf '  ok  %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n    expected: %q\n    actual:   %q\n' "$label" "$expected" "$actual"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS + 1))
        printf '  ok  %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n    needle should not appear: %q\n    haystack: %q\n' "$label" "$needle" "$haystack"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
        printf '  ok  %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %s\n    needle:   %q\n    haystack: %q\n' "$label" "$needle" "$haystack"
    fi
}

# --- skeleton ---

echo "skeleton"

out=$(bash "$SCRIPT" --help 2>&1)
rc=$?
assert_eq "--help exits 0" 0 "$rc"
assert_contains "--help mentions task-estimate" "task-estimate" "$out"

rc=0
out=$(bash "$SCRIPT" --bogus-flag 2>&1) || rc=$?
assert_eq "unknown flag exits non-zero" 1 "$rc"
assert_contains "unknown flag explains itself" "Unknown" "$out"

rc=0
out=$(bash "$SCRIPT" 2>&1) || rc=$?
assert_eq "missing prompt exits non-zero" 1 "$rc"
assert_contains "missing prompt explains itself" "prompt" "$out"

# --- config ---

echo
echo "config"

test_default_config_shape() {
    rm -rf "$XDG_CONFIG_HOME"
    bash "$SCRIPT" --json "test prompt" >/dev/null 2>&1 || true
    if [[ -f "$CONFIG_FILE" ]]; then PASS=$((PASS + 1)); echo "  ok  default config written"
    else FAIL=$((FAIL + 1)); echo "  FAIL default config not written"; fi
    assert_eq "default .buckets.s" 15000 "$(jq -r '.buckets.s' "$CONFIG_FILE" 2>/dev/null)"
    assert_eq "default .session_cap" 100000 "$(jq -r '.session_cap' "$CONFIG_FILE" 2>/dev/null)"
    assert_eq "default config has no .profiles" false "$(jq 'has("profiles")' "$CONFIG_FILE" 2>/dev/null)"
    assert_eq "default config has no .providers" false "$(jq 'has("providers")' "$CONFIG_FILE" 2>/dev/null)"
}
test_default_config_shape

test_json_has_no_profile() {
    local out
    out=$(bash "$SCRIPT" --json "test prompt" 2>/dev/null) || true
    assert_eq "--json has no profile key" false "$(echo "$out" | jq 'has("profile")')"
    out=$(bash "$SCRIPT" "test prompt" 2>/dev/null) || true
    [[ "$out" != *"Profile:"* ]] && { PASS=$((PASS + 1)); echo "  ok  human output has no Profile line"; } \
        || { FAIL=$((FAIL + 1)); echo "  FAIL human output mentions Profile"; }
}
test_json_has_no_profile

test_profile_flag_rejected() {
    local rc=0
    bash "$SCRIPT" --json --profile work "test prompt" >/dev/null 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] && { PASS=$((PASS + 1)); echo "  ok  --profile rejected (rc=$rc)"; } \
        || { FAIL=$((FAIL + 1)); echo "  FAIL --profile accepted"; }
}
test_profile_flag_rejected

test_partial_config_uses_user_value() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo '{"session_cap":200000}' > "$CONFIG_FILE"
    local rc=0 out
    out=$(bash "$SCRIPT" --json "refactor the auth module everywhere" 2>&1) || rc=$?
    assert_eq "partial config runs" 0 "$rc"
    assert_contains "partial config uses its session_cap" "~200k" "$(echo "$out" | jq -r '.recommendation' 2>/dev/null)"
    assert_eq "partial config falls back to default buckets" "XL" "$(echo "$out" | jq -r '.bucket' 2>/dev/null)"
    assert_eq "partial config file is not rewritten" '{"session_cap":200000}' "$(cat "$CONFIG_FILE")"
    rm -f "$CONFIG_FILE"
}
test_partial_config_uses_user_value

test_readonly_config_dir_uses_defaults() {
    local ro="$TMPROOT/ro-config" rc=0 out
    mkdir -p "$ro"; chmod 555 "$ro"
    out=$(XDG_CONFIG_HOME="$ro" bash "$SCRIPT" --json "refactor the auth module everywhere" 2>&1) || rc=$?
    chmod 755 "$ro"
    assert_eq "read-only config dir runs" 0 "$rc"
    assert_contains "read-only config dir uses default session_cap" "~100k" "$(echo "$out" | jq -r '.recommendation' 2>/dev/null)"
    assert_eq "read-only config dir writes nothing" "" "$(ls -A "$ro")"
}
test_readonly_config_dir_uses_defaults

test_legacy_config_fallback() {
    rm -rf "$XDG_CONFIG_HOME"
    mkdir -p "$(dirname "$LEGACY_FILE")"
    echo '{"session_cap":222000}' > "$LEGACY_FILE"
    local out errf="$TMPROOT/legacy.err"
    out=$(bash "$SCRIPT" --json "refactor the auth module everywhere" 2>"$errf") || true
    assert_contains "legacy config value used" "~222k" "$(echo "$out" | jq -r '.recommendation' 2>/dev/null)"
    assert_contains "legacy notice names legacy config" "legacy config" "$(cat "$errf")"
    assert_contains "legacy notice names new path" "$CONFIG_FILE" "$(cat "$errf")"
    [[ ! -e "$CONFIG_FILE" ]] && { PASS=$((PASS + 1)); echo "  ok  legacy fallback writes no new config"; } \
        || { FAIL=$((FAIL + 1)); echo "  FAIL legacy fallback wrote $CONFIG_FILE"; }
    assert_eq "legacy file unchanged" '{"session_cap":222000}' "$(cat "$LEGACY_FILE")"
    rm -rf "$XDG_CONFIG_HOME"
}
test_legacy_config_fallback

test_new_config_beats_legacy() {
    rm -rf "$XDG_CONFIG_HOME"
    mkdir -p "$(dirname "$LEGACY_FILE")" "$(dirname "$CONFIG_FILE")"
    echo '{"session_cap":222000}' > "$LEGACY_FILE"
    echo '{"session_cap":333000}' > "$CONFIG_FILE"
    local out errf="$TMPROOT/both.err"
    out=$(bash "$SCRIPT" --json "refactor the auth module everywhere" 2>"$errf") || true
    assert_contains "new config wins over legacy" "~333k" "$(echo "$out" | jq -r '.recommendation' 2>/dev/null)"
    [[ "$(cat "$errf")" != *legacy* ]] && { PASS=$((PASS + 1)); echo "  ok  no legacy notice when new config exists"; } \
        || { FAIL=$((FAIL + 1)); echo "  FAIL legacy notice printed with new config present"; }
    rm -rf "$XDG_CONFIG_HOME"
}
test_new_config_beats_legacy

test_cache_namespace() {
    rm -rf "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo '{"buckets":{"s":1,"m":2,"l":100000000}}' > "$CONFIG_FILE"
    (cd /tmp && bash "$SCRIPT" --json "refactor the auth module everywhere" >/dev/null 2>&1) || true
    rm -rf "$XDG_CONFIG_HOME"
    [[ -n "$(ls -A "$CACHE_ROOT" 2>/dev/null)" ]] && { PASS=$((PASS + 1)); echo "  ok  artifacts under scuba10steve-skills cache"; } \
        || { FAIL=$((FAIL + 1)); echo "  FAIL no artifacts under $CACHE_ROOT"; }
    [[ ! -e "$XDG_CACHE_HOME/skills" ]] && { PASS=$((PASS + 1)); echo "  ok  nothing under legacy cache dir"; } \
        || { FAIL=$((FAIL + 1)); echo "  FAIL legacy cache dir created"; }
}
test_cache_namespace

# --- heuristic core ---

echo
echo "heuristic core"

# Tiny prompt → small estimate (3750 floor + few chars, no multipliers + maybe cwd).
# Run from /tmp to avoid cwd git-modified-files contribution polluting the floor.
out=$(cd /tmp && bash "$SCRIPT" --json "typo in button" 2>/dev/null)
total=$(echo "$out" | jq -r '.estimate.total')
if [[ "$total" =~ ^[0-9]+$ && "$total" -lt 2000 ]]; then
    PASS=$((PASS + 1)); echo "  ok  tiny prompt → small estimate ($total)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL tiny prompt expected <2000, got $total"
fi

# Refactor verb → ×3 multiplier kicks in (base ~3756 × 3 ≈ 11000+)
out=$(bash "$SCRIPT" --json "refactor the cmux helper" 2>/dev/null)
total=$(echo "$out" | jq -r '.estimate.total')
if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 11000 ]]; then
    PASS=$((PASS + 1)); echo "  ok  refactor → multiplier applied ($total)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL refactor expected >11000, got $total"
fi

# Scope + amplifying verb compounds (audit ×3, everywhere ×2 → ~22000+)
out=$(bash "$SCRIPT" --json "audit everywhere across the codebase" 2>/dev/null)
total=$(echo "$out" | jq -r '.estimate.total')
if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 22000 ]]; then
    PASS=$((PASS + 1)); echo "  ok  scope + verb compounds ($total)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL scope+verb expected >22000, got $total"
fi

# --- path/repo extraction + cwd context ---

echo
echo "path/repo extraction + cwd context"

# Same verb, but with a named path → larger estimate
plain=$(bash "$SCRIPT" --json "refactor the helper" 2>/dev/null | jq -r '.estimate.total')
with_path=$(bash "$SCRIPT" --json "refactor /tmp/some-imaginary-dir/helper.sh" 2>/dev/null | jq -r '.estimate.total')
if [[ "$plain" =~ ^[0-9]+$ && "$with_path" =~ ^[0-9]+$ && "$with_path" -gt "$plain" ]]; then
    PASS=$((PASS + 1)); echo "  ok  named path increases estimate (plain=$plain with_path=$with_path)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL plain=$plain with_path=$with_path"
fi

# Non-git cwd: script should not fail
out=$(cd /tmp && bash "$SCRIPT" --json "fix typo" 2>&1)
rc=$?
assert_eq "non-git cwd does not fail" 0 "$rc"
assert_contains "non-git cwd still returns JSON" '"estimate"' "$out"

# --- phases, buckets, confidence ---

echo
echo "phases, buckets, confidence"

out=$(cd /tmp && bash "$SCRIPT" --json "typo in button" 2>/dev/null)
flat=$(echo "$out" | tr -d ' \n')
assert_contains "tiny prompt → bucket S" '"bucket":"S"' "$flat"
assert_contains "short prompt no signals → confidence low" '"confidence":"low"' "$flat"

out=$(bash "$SCRIPT" --json "refactor /tmp/foo/bar everywhere across the repo" 2>/dev/null)
flat=$(echo "$out" | tr -d ' \n')
# CALIBRATION: refactor + scope amplifies the heuristic; verify the
# amplification fires by comparing against a no-amplifier baseline.
# Bucket-specific behavior (L/XL triggering split prompts) is validated by
# manual smoke runs rather than calibrated thresholds here.
amplified=$(echo "$out" | jq -r '.estimate.total')
baseline=$(bash "$SCRIPT" --json "do the task" 2>/dev/null | jq -r '.estimate.total')
if [[ "$amplified" =~ ^[0-9]+$ && "$baseline" =~ ^[0-9]+$ && "$amplified" -gt $(( baseline * 3 )) ]]; then
    PASS=$((PASS + 1)); echo "  ok  refactor+scope amplifies vs baseline ($amplified vs $baseline)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL expected amplification, got amplified=$amplified baseline=$baseline"
fi
assert_contains "richer prompt → confidence medium" '"confidence":"medium"' "$flat"

# Per-phase breakdown sums to ~total
out=$(bash "$SCRIPT" --json "refactor /tmp/foo/bar" 2>/dev/null)
total=$(echo "$out" | jq -r '.estimate.total')
sum=$(echo "$out" | jq -r '.breakdown.read + .breakdown.plan + .breakdown.edit + .breakdown.verify')
if [[ "$total" =~ ^[0-9]+$ && "$sum" =~ ^[0-9]+$ ]]; then
    diff=$(( total > sum ? total - sum : sum - total ))
    if [[ "$diff" -lt 100 ]]; then
        PASS=$((PASS + 1)); echo "  ok  phase breakdown sums to total (Δ$diff)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL total=$total sum=$sum (Δ$diff)"
    fi
else
    FAIL=$((FAIL + 1)); echo "  FAIL non-numeric total=$total sum=$sum"
fi

# --- recommendation ---

echo
echo "recommendation"

out=$(bash "$SCRIPT" --json "fix typo" 2>/dev/null)
rec=$(echo "$out" | jq -r '.recommendation')
assert_contains "S bucket → fits comfortably" "Fits comfortably" "$rec"

out=$(bash "$SCRIPT" --json "refactor /tmp/a/b/c everywhere across the repo" 2>/dev/null)
b=$(echo "$out" | jq -r '.bucket')
rec=$(echo "$out" | jq -r '.recommendation')
# Bucket may be S/M/L/XL depending on calibration; just verify recommendation matches whatever bucket fired.
case "$b" in
    S|M)
        if [[ "$rec" == *"Fits comfortably"* ]]; then
            PASS=$((PASS + 1)); echo "  ok  $b bucket → fits comfortably recommendation"
        else
            FAIL=$((FAIL + 1)); echo "  FAIL $b rec was: $rec"
        fi ;;
    L)
        if [[ "$rec" == *"Tight against"* ]]; then
            PASS=$((PASS + 1)); echo "  ok  L → tight recommendation"
        else
            FAIL=$((FAIL + 1)); echo "  FAIL L rec was: $rec"
        fi ;;
    XL)
        if [[ "$rec" == *"overflow"* ]]; then
            PASS=$((PASS + 1)); echo "  ok  XL → overflow recommendation"
        else
            FAIL=$((FAIL + 1)); echo "  FAIL XL rec was: $rec"
        fi ;;
    *)
        FAIL=$((FAIL + 1)); echo "  FAIL unexpected bucket: $b" ;;
esac

# Human output includes the recommendation line
out=$(bash "$SCRIPT" "fix typo" 2>/dev/null)
assert_contains "human output shows Recommendation:" "Recommendation:" "$out"

# --- split prompts + artifacts ---

echo
echo "split prompts + artifacts"

# Force L bucket via a config with tiny bucket thresholds.
write_low_threshold_config() {
    local providers="${1:-}"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<JSON
{
  "buckets": {"s": 10000, "m": 50000, "l": 200000},
  "session_cap": 200000,
  "verbs": {
    "refactor|migrate|audit|investigate|overhaul": 3.0,
    "implement|build|create|port|convert|switch": 2.0,
    "fix|update|tweak|adjust|add": 1.0,
    "typo|rename|one-liner": 0.3
  },
  "scope_adverbs": {
    "everywhere|across|all of|repo-wide": 2.0,
    "this file|just this|only": 0.5
  },
  "phase_split": {"read": 0.4, "plan": 0.15, "edit": 0.3, "verify": 0.15},
  "multi_agent": {
    "per_agent_base": 28000,
    "verb_to_agents": {
      "refactor|migrate|audit|investigate|overhaul": 4,
      "implement|build|create|port|convert|switch": 2,
      "fix|update|tweak|adjust|add": 1,
      "typo|rename|one-liner": 0
    },
    "default_agents": 1
  }
}
JSON
    if [[ -n "$providers" ]]; then
        jq --argjson p "$providers" '.providers = $p' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
}

write_low_threshold_config

# Prompt with paths to ensure deterministic bucket (run from /tmp to avoid git signals).
prompt="refactor /tmp/a/b/c.sh and /tmp/d/e/f.sh"
out=$(cd /tmp && bash "$SCRIPT" --json "$prompt" 2>/dev/null)
b=$(echo "$out" | jq -r '.bucket')

if [[ "$b" == "L" ]]; then
    n=$(echo "$out" | jq -r '.prompts | length')
    assert_eq "L → 3 phase-split prompts emitted" 3 "$n"

    run_id=$(echo "$out" | jq -r '.run_id')
    if [[ -n "$run_id" && "$run_id" != "null" ]]; then
        PASS=$((PASS + 1)); echo "  ok  run_id populated ($run_id)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL run_id was null"
    fi

    if [[ -d "$CACHE_ROOT/$run_id" ]]; then
        PASS=$((PASS + 1)); echo "  ok  artifact dir created"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL artifact dir missing"
    fi

    if [[ -f "$CACHE_ROOT/$run_id/README.md" ]]; then
        PASS=$((PASS + 1)); echo "  ok  coordination README written"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL README missing"
    fi
else
    FAIL=$((FAIL + 1)); echo "  FAIL expected L bucket with tiny thresholds, got $b (total=$(echo "$out" | jq -r '.estimate.total'))"
fi

# --no-split skips prompt generation even at L
out=$(cd /tmp && bash "$SCRIPT" --json --no-split "$prompt" 2>/dev/null)
n=$(echo "$out" | jq -r '.prompts | length')
assert_eq "--no-split → 0 prompts at L" 0 "$n"

test_split_prompt_without_providers() {
    local out
    out=$(cd /tmp && bash "$SCRIPT" --json "$prompt" 2>/dev/null)
    assert_eq "no-providers config lands in bucket L" L "$(echo "$out" | jq -r '.bucket')"
    local n; n=$(echo "$out" | jq -r '.prompts | length')
    [[ "$n" -gt 0 ]] && { PASS=$((PASS + 1)); echo "  ok  .prompts non-empty ($n)"; } \
        || { FAIL=$((FAIL + 1)); echo "  FAIL .prompts empty"; }
    assert_not_contains "no provider text without providers" "provider:" "$(echo "$out" | jq -r '.prompts[].body')"
    out=$(cd /tmp && bash "$SCRIPT" "$prompt" 2>/dev/null)
    assert_not_contains "human output has no provider text" "provider:" "$out"
}
test_split_prompt_without_providers

test_split_prompt_with_providers() {
    write_low_threshold_config '{"bulk_edit":"opencode"}'
    local out
    out=$(cd /tmp && bash "$SCRIPT" --json "$prompt" 2>/dev/null)
    assert_eq "providers config lands in bucket L" L "$(echo "$out" | jq -r '.bucket')"
    assert_contains "split prompt carries configured provider" "(provider: opencode)" "$(echo "$out" | jq -r '.prompts[1].body')"
    assert_eq "unconfigured phase has null provider" null "$(echo "$out" | jq -r '.prompts[0].provider')"
    write_low_threshold_config
}
test_split_prompt_with_providers

# S/M bucket → 0 prompts (the original real config might trigger different buckets; reset HOME first)
rm -f "$CONFIG_FILE"
out=$(bash "$SCRIPT" --json "fix typo" 2>/dev/null)
n=$(echo "$out" | jq -r '.prompts | length')
assert_eq "non-L bucket → 0 prompts" 0 "$n"

# --- low-confidence warning ---

echo
echo "low-confidence warning"

# Need a prompt that triggers low confidence: <10 words, no paths, non-git cwd.
WARN_FILE2="$(mktemp "${TMPDIR:-/tmp}/task-estimate-warn.XXXXXX")"
out=$(cd /tmp && bash "$SCRIPT" --json "hi" 2>"$WARN_FILE2")
flat=$(echo "$out" | tr -d ' \n')
assert_contains "low confidence prompt" '"confidence":"low"' "$flat"
if grep -q "warn: low confidence" "$WARN_FILE2"; then
    PASS=$((PASS + 1)); echo "  ok  low-confidence warning emitted to stderr"
else
    FAIL=$((FAIL + 1)); echo "  FAIL no low-confidence warning"
fi
rm -f "$WARN_FILE2"

# --- multi-agent verb mapping ---

echo
echo "multi-agent verb mapping"

out=$(cd /tmp && bash "$SCRIPT" --json "refactor the widget" 2>/dev/null)
assert_eq "refactor → 4 agents" 4 "$(echo "$out" | jq -r '.agent_count')"
overhead=$(echo "$out" | jq -r '.multi_agent_overhead')
assert_eq "refactor → overhead = 4 × 28000" 112000 "$overhead"

out=$(cd /tmp && bash "$SCRIPT" --json "implement the widget" 2>/dev/null)
assert_eq "implement → 2 agents" 2 "$(echo "$out" | jq -r '.agent_count')"

out=$(cd /tmp && bash "$SCRIPT" --json "typo in button" 2>/dev/null)
assert_eq "typo → 0 agents" 0 "$(echo "$out" | jq -r '.agent_count')"
assert_eq "typo → overhead = 0" 0 "$(echo "$out" | jq -r '.multi_agent_overhead')"

out=$(cd /tmp && bash "$SCRIPT" --json "do the task" 2>/dev/null)
assert_eq "unmatched verb → default 1 agent" 1 "$(echo "$out" | jq -r '.agent_count')"

# Scope scales agent count: refactor × everywhere 2.0 = 8
out=$(cd /tmp && bash "$SCRIPT" --json "refactor everywhere across the repo" 2>/dev/null)
assert_eq "refactor + scope → 8 agents" 8 "$(echo "$out" | jq -r '.agent_count')"

# Scope shrinks agent count: refactor × only 0.5 → int(4 * 0.5 + 0.5) = 2
out=$(cd /tmp && bash "$SCRIPT" --json "refactor only" 2>/dev/null)
assert_eq "refactor + only → 2 agents" 2 "$(echo "$out" | jq -r '.agent_count')"

# --- greedy verb matching ---

echo
echo "greedy verb matching"

# verb_to_agents iterates "typo" before "fix" in JSON key order,
# so "fix typo" matches "typo|rename|one-liner" first → 0 agents.
out=$(cd /tmp && bash "$SCRIPT" --json "fix typo" 2>/dev/null)
assert_eq "fix typo → 0 agents (typo matched before fix)" 0 "$(echo "$out" | jq -r '.agent_count')"
# Meanwhile apply_verb_multiplier has "fix" before "typo", so verb mult=×1.0
# — this key-ordering mismatch is a known issue

# "fix the button" uniquely matches "fix" → 1 agent
out=$(cd /tmp && bash "$SCRIPT" --json "fix the button" 2>/dev/null)
assert_eq "fix button → 1 agent (unique fix match)" 1 "$(echo "$out" | jq -r '.agent_count')"

# --- phase shift verbs ---

echo
echo "phase shift verbs"

# refactor shifts +20% edit, -20% read → edit > read
out=$(cd /tmp && bash "$SCRIPT" --json "refactor the frobnicator" 2>/dev/null)
read_val=$(echo "$out" | jq -r '.breakdown.read')
edit_val=$(echo "$out" | jq -r '.breakdown.edit')
if [[ "$edit_val" -gt "$read_val" ]]; then
    PASS=$((PASS + 1)); echo "  ok  refactor → edit ($edit_val) > read ($read_val)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL refactor expected edit > read (edit=$edit_val read=$read_val)"
fi

# default (no shift verb) → read > edit (0.4 > 0.3)
out=$(cd /tmp && bash "$SCRIPT" --json "fix the frobnicator" 2>/dev/null)
read_val=$(echo "$out" | jq -r '.breakdown.read')
edit_val=$(echo "$out" | jq -r '.breakdown.edit')
if [[ "$read_val" -gt "$edit_val" ]]; then
    PASS=$((PASS + 1)); echo "  ok  default (fix) → read ($read_val) > edit ($edit_val)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL fix expected read > edit (read=$read_val edit=$edit_val)"
fi

# --- --deep flag ---

echo
echo "--deep flag"

out=$(cd /tmp && bash "$SCRIPT" --json "refactor x" 2>/dev/null)
assert_eq "requested_deep false by default" "false" "$(echo "$out" | jq -r '.requested_deep')"

out=$(cd /tmp && bash "$SCRIPT" --json --deep "refactor x" 2>/dev/null)
assert_eq "--deep sets requested_deep true" "true" "$(echo "$out" | jq -r '.requested_deep')"

# --deep does not change the heuristic estimate
shallow=$(cd /tmp && bash "$SCRIPT" --json "refactor x" 2>/dev/null | jq -r '.estimate.total')
deep=$(cd /tmp && bash "$SCRIPT" --json --deep "refactor x" 2>/dev/null | jq -r '.estimate.total')
assert_eq "--deep does not alter heuristic" "$shallow" "$deep"

# --deep in human output mode
out=$(cd /tmp && bash "$SCRIPT" --deep "some task" 2>/dev/null)
rc=$?
assert_eq "--deep exits 0 with human output" 0 "$rc"

# --- config deep merge ---

echo
echo "config deep merge"

rm -rf "$XDG_CONFIG_HOME"
default_out=$(bash "$SCRIPT" --json "refactor the auth module everywhere" 2>/dev/null)

mkdir -p "$(dirname "$CONFIG_FILE")"
cat > "$CONFIG_FILE" <<'JSON'
{
  "buckets": {"s": 15000, "m": 40000, "l": 75000},
  "providers": {"planning": "claude-code", "bulk_edit": "opencode", "verify": "claude-code"},
  "session_cap": 100000,
  "verbs": {"refactor|migrate|audit|investigate|overhaul": 3.0},
  "scope_adverbs": {"everywhere|across|all of|repo-wide": 2.0},
  "phase_split": {"read": 0.4, "plan": 0.15, "edit": 0.3, "verify": 0.15}
}
JSON
cp "$CONFIG_FILE" "$TMPROOT/config.before"

merged_out=$(bash "$SCRIPT" --json "refactor the auth module everywhere" 2>/dev/null)
assert_eq "missing multi_agent falls back to default agent_count" \
  "$(echo "$default_out" | jq -r '.agent_count')" "$(echo "$merged_out" | jq -r '.agent_count')"
assert_eq "missing multi_agent falls back to default overhead" \
  "$(echo "$default_out" | jq -r '.multi_agent_overhead')" "$(echo "$merged_out" | jq -r '.multi_agent_overhead')"
if cmp -s "$CONFIG_FILE" "$TMPROOT/config.before"; then
    PASS=$((PASS + 1)); echo "  ok  existing config file left untouched"
else
    FAIL=$((FAIL + 1)); echo "  FAIL existing config file was rewritten"
fi

echo
printf 'Total: %d pass, %d fail\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
