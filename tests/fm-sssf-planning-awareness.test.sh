#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT/bin/fm-sssf-planning-awareness.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-sssf-planning-test.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM
STATE="$TMP/state"
FAKEBIN="$TMP/bin"
FEED="$TMP/feed.jsonl"
mkdir -p "$STATE" "$FAKEBIN"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { printf 'skip - jq unavailable\n'; exit 0; }

SOURCE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BOOT='{"actionability":"awareness","authoritative_refs":["docs/development/FUTURE_CANDIDATES.md"],"event_id":"plan-20260818-0001","increments":["FP-001","FM-FP-001"],"kind":"bootstrap","schema":"sssf-planning-event/v1","sequence":1,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","states":{"FUT-003":"ACTIVE"}}'
printf '%s\n' "$BOOT" > "$FEED"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
request=${!#}
case "$request" in
  *'/contents/docs/development/PLANNING_EVENTS.jsonl?ref='*)
    cat "$FM_TEST_FEED"
    ;;
  *'/contents/docs/'*'?ref=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    printf 'authoritative fixture\n'
    ;;
  *)
    printf 'unexpected fake gh request: %s\n' "$request" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_adapter() {
  PATH="$FAKEBIN:$PATH" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_TEST_FEED="$FEED" \
  FM_SSSF_PLANNING_REPO='fixture/sssf' \
  FM_SSSF_PLANNING_REF='fixture-ref' \
  "$ADAPTER" "$@"
}

out=$(run_adapter check) || fail "bootstrap check returned nonzero"
printf '%s' "$out" | grep -q 'sssf-planning pending event_id=plan-20260818-0001 kind=bootstrap actionability=awareness' \
  || fail "bootstrap did not surface as typed awareness"
[ -f "$STATE/sssf-planning.pending" ] || fail "bootstrap pending generation was not durable"
[ ! -e "$STATE/sssf-planning.cursor" ] || fail "cursor advanced before acknowledgement"
pass "bootstrap is awareness-only and cursor does not advance before acknowledgement"

inspected=$(run_adapter inspect) || fail "inspect failed"
[ "$inspected" = "$BOOT" ] || fail "inspect did not return the exact pending event"
pass "inspect returns the exact pending planning event"

run_adapter acknowledge plan-20260818-0001 >/dev/null || fail "acknowledgement failed"
[ -f "$STATE/sssf-planning.cursor" ] || fail "acknowledgement did not publish cursor"
[ ! -e "$STATE/sssf-planning.pending" ] || fail "acknowledgement did not retire pending generation"
pass "acknowledgement atomically advances cursor then retires pending generation"

out=$(run_adapter check) || fail "unchanged-feed check returned nonzero"
[ -z "$out" ] || fail "unchanged feed produced a wake: $out"
pass "unchanged feed is silent"

cp "$STATE/sssf-planning.cursor" "$TMP/cursor.before"
printf 'X' | dd of="$FEED" bs=1 seek=0 conv=notrunc status=none 2>/dev/null 
out=$(run_adapter check) || fail "prefix-mutation check returned nonzero"
printf '%s' "$out" | grep -q 'continuity failure=prefix-changed' \
  || fail "prefix mutation was not refused: $out"
cmp -s "$TMP/cursor.before" "$STATE/sssf-planning.cursor" \
  || fail "continuity failure advanced the cursor"
[ ! -e "$STATE/sssf-planning.pending" ] || fail "continuity failure created a pending event"
pass "prefix mutation fails closed with no cursor advance or pending effect"

printf '%s\n' "$BOOT" > "$FEED"
ACTIVE='{"actionability":"engineering","authoritative_refs":["docs/increments/FP-002.md"],"event_id":"plan-20260818-0002","increments":["FP-002"],"item_id":"FUT-004","kind":"transition","from":"SEQUENCED","schema":"sssf-planning-event/v1","sequence":2,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","to":"ACTIVE"}'
printf '%s\n%s\n' "$BOOT" "$ACTIVE" > "$FEED"
out=$(run_adapter check) || fail "ACTIVE check returned nonzero"
printf '%s' "$out" | grep -q 'event_id=plan-20260818-0002 kind=transition to=ACTIVE actionability=engineering' \
  || fail "ACTIVE did not surface as engineering-intake eligible: $out"
[ -f "$STATE/sssf-planning.pending" ] || fail "ACTIVE event was not retained pending handling"
[ "$(find "$STATE" -maxdepth 1 -name '*.meta' -o -name '*.status' | wc -l | tr -d ' ')" -eq 0 ] \
  || fail "planning adapter created task state directly"
pass "ACTIVE surfaces intake eligibility but adapter creates no task or status record"

printf 'all fm-sssf-planning-awareness tests passed\n'
