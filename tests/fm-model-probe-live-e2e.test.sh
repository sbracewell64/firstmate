#!/usr/bin/env bash
# Credentialed live guard for the entitlement probe's per-harness command shapes.
#
# WHY THIS IS OPT-IN AND LIVE. The probe's verdict comes from what a vendor CLI
# emits - its exit status and its first line of output - so only the real binary
# can prove the command shape still works. A fake harness can confirm nothing
# except the assumption already written into the fake, and the portable
# regression in tests/fm-availability-observation.test.sh deliberately covers
# the classifier and the record instead.
#
# WHAT IT PROTECTS. `claude` had NO probe arm at all, so every claude-routed
# model recorded a could-not-observe forever while being entitled and live, and
# the fleet's single-candidate runtime route was refused on that non-answer. The
# repair added the arm; this guard is what keeps a vendor flag change from
# quietly returning it to the same state. The design already fails in the safe
# direction - a broken command shape produces UNOBSERVABLE and a TOOLING_GAP
# rather than a wrong answer - so this exists to catch that BEFORE a dispatch
# does.
#
# COST. One probe per installed harness, on models the zero-budget decision
# already admits. An absent harness is reported and skipped rather than passed
# over silently, and a run that probed nothing at all refuses rather than
# reporting success over an empty set.
set -u

if [ "${FM_MODEL_PROBE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_MODEL_PROBE_LIVE_E2E=1 to run the credentialed model-probe command-shape guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT/bin/fm-model-verify.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || fail "jq not found"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-probe-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

# One home per case, carrying exactly the model under test, so a probe here can
# never touch the operating home's own availability or observation records.
write_home() {  # <home> <key> <provider> <model-id> <harness>
  local home=$1 key=$2 provider=$3 model_id=$4 harness=$5
  mkdir -p "$home/config" "$home/state"
  cat > "$home/config/crew-dispatch.json" <<JSON
{ "_floors": { "F-P": { "effort_floor": "low" } },
  "_models": { "$key": { "smart_zone": 140000, "effort_expressible": ["low"], "tool_loop": "verified-agentic" } },
  "rules": [ { "when": "probe guard", "route": "R-P", "floor": "F-P",
               "use": { "harness": "$harness", "model": "$key", "effort": "low" },
               "pool": ["$key"] } ] }
JSON
  cat > "$home/config/models.json" <<JSON
{ "schema": "fm-model-registry.v1",
  "providers": { "$provider": { "access_class": "A", "cost_posture": "subscription-flat", "status": "active" } },
  "models": { "$key": { "provider": "$provider", "model_id": "$model_id", "harness": "$harness",
      "cost_class": "subscription-flat", "status": "approved-primary",
      "limits": { "shared_quota_pool": "$provider-probe-guard" } } } }
JSON
}

PROBED=0

# One harness's command shape, end to end through the real binary.
guard_harness() {  # <harness> <key> <provider> <model-id>
  local harness=$1 key=$2 provider=$3 model_id=$4 home obs shape detail version
  if ! command -v "$harness" >/dev/null 2>&1; then
    # Reported, never silent: a guard that skips quietly is indistinguishable
    # from one that passed, which is the defect this whole change is about.
    printf 'ok - skipped %s: not installed on this machine, so its probe command shape was NOT verified\n' "$harness"
    return 0
  fi
  version=$("$harness" --version 2>&1 | head -1)
  home="$LAB/$harness"
  write_home "$home" "$key" "$provider" "$model_id" "$harness"
  env -u FM_ROOT_OVERRIDE FM_HOME="$home" "$VERIFY" --model "$key" >/dev/null 2>&1 || true
  [ -f "$home/state/model-observation.json" ] \
    || fail "$harness ($version): the probe recorded no observation at all for $key, so nothing was measured"
  obs=$(jq -r --arg k "$key" '.models[$k].observation // "ABSENT"' "$home/state/model-observation.json")
  shape=$(jq -r --arg k "$key" '.models[$k].shape // "-"' "$home/state/model-observation.json")
  detail=$(jq -r --arg k "$key" '.models[$k].detail // "-"' "$home/state/model-observation.json")
  case "$obs" in
    AVAILABLE) ;;
    UNOBSERVABLE)
      fail "$harness ($version): the probe command shape no longer works - $key recorded $obs ($shape: $detail). Repair the $harness arm in bin/fm-model-verify.sh probe_one; every $harness-routed model is excluded from routing until it works"
      ;;
    *)
      fail "$harness ($version): $key recorded $obs ($shape: $detail) rather than AVAILABLE. Either this account genuinely lost the model, or the classifier no longer recognises what $harness emits"
      ;;
  esac
  PROBED=$((PROBED + 1))
  pass "$harness ($version): the probe command shape reaches the provider and $key answers AVAILABLE"
}

guard_harness claude claude/opus claude opus
guard_harness pi openai-codex/gpt-5.6-sol openai-codex gpt-5.6-sol

# An empty result set is never a pass. With no harness installed this guard
# verified nothing, and saying so is the honest outcome.
[ "$PROBED" -gt 0 ] \
  || fail "no probe ran: every harness this guard covers is absent, so no command shape was verified"
pass "the probe command shape guard verified $PROBED harness(es)"
