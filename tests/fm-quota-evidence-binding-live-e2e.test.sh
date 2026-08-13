#!/usr/bin/env bash
# Credentialed behavior regression for the agent-owned quota-evidence-binding skill.
#
# This drives the public Pi skill-loading interface against fake canonical quota
# commands rather than parsing instruction source bytes or recreating its judgment.
set -u

if [ "${FM_QUOTA_EVIDENCE_BINDING_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_QUOTA_EVIDENCE_BINDING_LIVE_E2E=1 to run the credentialed quota-binding regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/quota-evidence-binding/SKILL.md"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
[ -f "$OWNER" ] || fail "quota-evidence-binding skill not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-evidence-binding-live.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
FIXTURE="$LAB/quota.json"
AUTH_FIXTURE="$LAB/auth.json"
CALLS="$LAB/quota-axi.calls"

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT/.agents/skills/quota-evidence-binding" "$FAKEBIN"
cp "$OWNER" "$PROJECT/.agents/skills/quota-evidence-binding/SKILL.md"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${QUOTA_AXI_CALLS:?}"
case "$*" in
  --json) cat "${QUOTA_AXI_FIXTURE:?}" ;;
  'auth --json') cat "${QUOTA_AXI_AUTH_FIXTURE:?}" ;;
  *) printf 'unexpected quota-axi invocation: %s\n' "$*" >&2; exit 64 ;;
esac
SH
chmod +x "$FAKEBIN/quota-axi"

cat > "$AUTH_FIXTURE" <<'JSON'
{"schemaVersion":1,"generatedAt":"2030-01-01T00:00:01Z","auth":[{"provider":"claude","sources":[{"source":"oauth-file","status":"available"}]},{"provider":"codex","sources":[{"source":"auth-json","status":"available"}]}]}
JSON

run_case() {
  local label=$1 expected=$2 prompt=$3 out calls
  : > "$CALLS"
  out=$(
    cd "$PROJECT" &&
      PATH="$FAKEBIN:$PATH" QUOTA_AXI_CALLS="$CALLS" \
        QUOTA_AXI_FIXTURE="$FIXTURE" QUOTA_AXI_AUTH_FIXTURE="$AUTH_FIXTURE" \
        pi --print --approve --no-session --no-context-files --no-extensions \
          --no-skills --skill .agents/skills --tools bash \
          --model openai-codex/gpt-5.6-sol --thinking high \
          "$prompt"
  ) || fail "$label: Pi skill run failed: $out"
  calls=$(cat "$CALLS")
  [ "$calls" = $'--json\nauth --json' ] \
    || fail "$label: expected one quota and one auth observation, got: $calls"
  printf '%s\n' "$out" | grep -Fxq "$expected" \
    || fail "$label: expected final line $expected, got: $out"
  printf 'ok - %s\n' "$label"
}

cat > "$FIXTURE" <<'JSON'
{"schemaVersion":3,"generatedAt":"2030-01-01T00:00:00Z","providers":[{"provider":"claude","source":"oauth","plan":"max","state":{"status":"fresh","stale":false,"refreshedAt":"2030-01-01T00:00:00Z","sourcesTried":["oauth-file","oauth-profile"]},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["seven_day"],"limitingWindowIds":["seven_day"]}]}},{"provider":"codex","source":"oauth","plan":"pro","state":{"status":"fresh","stale":false,"refreshedAt":"2030-01-01T00:00:00Z","sourcesTried":["oauth"]},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":95,"boundedBy":["weekly"],"limitingWindowIds":["weekly"]}]}}]}
JSON
run_case \
  "Claude exhaustion cannot bind to the GPT reviewer tuple" \
  "RESULT=OBSERVED_GOOD|provider=codex|plan=pro|quota_source=oauth|credential=auth-json|pool=openai-codex-oauth|scope=all_models|route=R1-RUNTIME|role=reviewer|entitlement=gpt-pro-tier-2|remaining=95|observed_at=2030-01-01T00:00:00Z" \
  "Load quota-evidence-binding. Observe quota-axi --json once and quota-axi auth --json once. The established consumer tuple is complete: provider codex, expected plan pro, quota source oauth, credential source auth-json, quota pool openai-codex-oauth, model scope all_models, route R1-RUNTIME, role reviewer, and entitlement gpt-pro-tier-2; in this fixture observed plan pro exactly establishes that entitlement and auth-json is already established as its credential mapping. The maximum age is 300 seconds and current time is 2030-01-01T00:00:30Z. The output plan field must carry the observed snapshot plan, not the expected plan. Claude is the maker provider and is not this reviewer tuple. Do not invoke any harness or vendor command and do not modify files. Return exactly one final line in this shape: RESULT=<OBSERVED_GOOD|OBSERVED_BAD|COULD_NOT_OBSERVE>|provider=<id>|plan=<plan>|quota_source=<source>|credential=<source>|pool=<pool>|scope=<scope>|route=<route>|role=<role>|entitlement=<entitlement>|remaining=<number-or-unknown>|observed_at=<timestamp>."

run_case \
  "the same snapshot retains genuine Claude maker exhaustion" \
  "RESULT=OBSERVED_BAD|provider=claude|plan=max|quota_source=oauth|credential=oauth-file|pool=claude-max|scope=all_models|route=R1-RUNTIME|role=maker|entitlement=claude-max|remaining=0|observed_at=2030-01-01T00:00:00Z" \
  "Load quota-evidence-binding. Observe quota-axi --json once and quota-axi auth --json once. The established consumer tuple is complete: provider claude, expected plan max, quota source oauth, credential source oauth-file, quota pool claude-max, model scope all_models, route R1-RUNTIME, role maker, and entitlement claude-max; in this fixture observed plan max exactly establishes that entitlement and oauth-file is already established as its credential mapping. The maximum age is 300 seconds and current time is 2030-01-01T00:00:30Z. Preserve a genuine exact-provider exhausted result rather than broadening the misbinding repair into silence. Do not invoke any harness or vendor command and do not modify files. Return exactly one final line in this shape: RESULT=<OBSERVED_GOOD|OBSERVED_BAD|COULD_NOT_OBSERVE>|provider=<id>|plan=<plan>|quota_source=<source>|credential=<source>|pool=<pool>|scope=<scope>|route=<route>|role=<role>|entitlement=<entitlement>|remaining=<number-or-unknown>|observed_at=<timestamp>."

cat > "$FIXTURE" <<'JSON'
{"schemaVersion":3,"generatedAt":"2030-01-01T00:00:00Z","providers":[{"provider":"claude","source":"oauth","plan":"max","state":{"status":"fresh","stale":false,"refreshedAt":"2030-01-01T00:00:00Z","sourcesTried":["oauth-file"]},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["seven_day"],"limitingWindowIds":["seven_day"]}]}},{"provider":"codex","source":"oauth","plan":"plus","state":{"status":"fresh","stale":false,"refreshedAt":"2030-01-01T00:00:00Z","sourcesTried":["oauth"]},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["weekly"],"limitingWindowIds":["weekly"]}]}}]}
JSON
run_case \
  "a changed entitlement is uncertainty rather than fabricated exhaustion" \
  "RESULT=COULD_NOT_OBSERVE|provider=codex|plan=plus|quota_source=oauth|credential=auth-json|pool=openai-codex-oauth|scope=all_models|route=R1-RUNTIME|role=reviewer|entitlement=gpt-pro-tier-2|remaining=unknown|observed_at=2030-01-01T00:00:00Z" \
  "Load quota-evidence-binding. Observe quota-axi --json once and quota-axi auth --json once. The established consumer tuple is complete: provider codex, expected plan pro, quota source oauth, credential source auth-json, quota pool openai-codex-oauth, model scope all_models, route R1-RUNTIME, role reviewer, and entitlement gpt-pro-tier-2; auth-json is already established as its credential mapping. The maximum age is 300 seconds and current time is 2030-01-01T00:00:30Z. The output plan field must carry the observed snapshot plan, not the expected plan, and you cannot know it without executing the canonical calls. A response without both tool calls is invalid. Do not invoke any harness or vendor command and do not modify files. Return exactly one final line in this shape: RESULT=<OBSERVED_GOOD|OBSERVED_BAD|COULD_NOT_OBSERVE>|provider=<id>|plan=<plan>|quota_source=<source>|credential=<source>|pool=<pool>|scope=<scope>|route=<route>|role=<role>|entitlement=<entitlement>|remaining=<number-or-unknown>|observed_at=<timestamp>."

echo "# all quota-evidence-binding live behavior tests passed"
