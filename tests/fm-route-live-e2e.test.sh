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
routes=$(jq -r '.rules[]? | select(.route != null) | .route' "$CONFIG") || fail "live routing policy is invalid"
[ -n "$routes" ] || fail "live routing policy contains no routes"

records=
while IFS= read -r route; do
  out=$(FM_HOME="$FM_HOME" "$ROUTE" --json eligible --route "$route" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || fail "route $route could not be evaluated: $out"
  records="$records$out
"
done <<EOF
$routes
EOF

printf '%s' "$records" | jq -es '[.[].candidates[]?.violations[]?.rule] | index("context_below_floor") == null' \
  | grep -qx true || fail "live routing still emits context_below_floor"
printf '%s' "$records" | jq -es '[.[].candidates[]?.violations[]?.rule | select(. != "context_below_floor")] | length > 0' \
  | grep -qx true || fail "live routing check observed no unrelated exclusion"

echo "ok - live routing has no ceiling-as-floor exclusion while unrelated exclusions remain"
