#!/usr/bin/env bash
set -u

if [ "${FM_ROUTE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_ROUTE_LIVE_E2E=1 to check the live routing table"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME=${FM_HOME:-$ROOT}
CONFIG="$FM_HOME/config/crew-dispatch.json"
ROUTE="$ROOT/bin/fm-route.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

[ -r "$CONFIG" ] || fail "live routing policy is unreadable: $CONFIG"
routes=$(FM_HOME="$FM_HOME" "$ROUTE" routes 2>/dev/null | awk '/^policy_digest=/ { next } { print $1 }') \
  || fail "live routing policy is invalid"
[ -n "$routes" ] || fail "live routing policy contains no routes"

records=
unrelated_record=
while IFS= read -r route; do
  out=$(FM_HOME="$FM_HOME" "$ROUTE" --json eligible --route "$route" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || fail "route $route could not be evaluated: $out"
  records="$records$out
"
  if [ -z "$unrelated_record" ]; then
    outsider=$(printf '%s\n' "$out" \
      | jq -r --slurpfile policy "$CONFIG" '($policy[0]._models | keys) - .pool | first // empty')
    if [ -n "$outsider" ]; then
      unrelated_record=$(FM_HOME="$FM_HOME" "$ROUTE" --json check \
        --route "$route" --model "$outsider" 2>&1); rc=$?
      [ "$rc" -eq 1 ] || fail "live route $route admitted out-of-pool model $outsider: $unrelated_record"
    fi
  fi
done <<EOF
$routes
EOF

printf '%s' "$records" | jq -es '[.[].candidates[]?.violations[]?.rule] | index("context_below_floor") == null' \
  | grep -qx true || fail "live routing still emits context_below_floor"
[ -n "$unrelated_record" ] || fail "live routing policy has no model outside any route pool"
printf '%s' "$unrelated_record" | jq -e '.subject.violations[] | select(.rule == "model_not_in_pool")' >/dev/null \
  || fail "live routing check observed no unrelated exclusion"

echo "ok - live routing has no ceiling-as-floor exclusion while unrelated exclusions remain"
