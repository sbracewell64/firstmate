#!/usr/bin/env bash
# Behavior tests for the FRESHLY OBSERVED ZERO PRICE gate: the rule that a model
# is dispatched on an API-key provider only while the PROVIDER, asked now, prices
# it at exactly zero on every axis.
#
# The gap this closes. The zero-budget rule is enforced from config/models.json,
# and every number in that file is a copy someone wrote down. Its own drift check
# compares that copy against a catalogue file also on disk, and both age at the
# same rate - so a repricing that lands after both were written is invisible to
# every local check there is. The allowlist would keep saying zero, correctly,
# about a price that no longer exists.
#
# Every case below is one control on that gap, and they are deliberately not one
# case with ten inputs: a price that is positive, a price that is positive on one
# axis only, a price that is zero on the model and not on the endpoint that
# serves it, a provider that cannot be reached, a document that does not parse, a
# model that is not there, a price that cannot be read, two endpoints where the
# resolved one cannot be identified, an identity that moved under a reused name,
# and an observation that has aged out are TEN different things to repair. The
# gate treats all ten the same way - it refuses - and this suite proves each one
# is separately reachable, because a refusal nobody can trace to a cause is a
# refusal nobody can fix.
#
# The load-bearing assertion across all of them is negative: no verdict other
# than ZERO ever admits a dispatch. An unknown price is not a free one.
#
# The cases drive the real bin/fm-model-price-lib.sh, the real bin/fm-spawn.sh
# against a real isolated git worktree, the real bin/fm-model-verify.sh, and the
# real registry validator. The metadata sources are served over the SAME curl
# transport production uses, through file:// and, for the credential case, a real
# loopback HTTP server - so a verdict comes from the code that produces it in the
# fleet rather than from a stub that could only confirm its own assumptions.
set -u

# fail() inside a command substitution kills only the subshell, so an aborting
# fixture builder hands its caller an empty string and the suite keeps going -
# then exits on its LAST case's status, which the runner reads as a pass. The
# identity contract closes that: every declared test must have reported success.
FM_TEST_IDENTITY_CONTRACT=1
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-model-price-lib.sh
. "$ROOT/bin/fm-model-price-lib.sh"
# shellcheck source=bin/fm-model-registry-lib.sh
. "$ROOT/bin/fm-model-registry-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
VERIFY="$ROOT/bin/fm-model-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-model-price-zero)

# The model under test. A vendor-neutral placeholder: this suite is about the
# rule, and naming a real routed model here would make the cases stop being
# re-runnable against the next candidate.
KEY=vendorx/m
MODEL_ID=m
CREATED=1700000000

# --- metadata fixtures ------------------------------------------------------
#
# Written to disk and served through file:// URLs, which curl handles on the same
# code path as https. That is what lets these cases exercise
# fm_model_price_fetch itself rather than a substitute for it: a stub transport
# can only ever confirm the assumption written into the stub.

# fixture_dir <name> -> a fresh directory for one case's metadata documents.
fixture_dir() {
  local d="$TMP_ROOT/fx/$1"
  mkdir -p "$d" || return 1
  printf '%s\n' "$d"
}

# write_catalogue <dir> <prompt> <completion> [<created>] [<slug>]
write_catalogue() {
  local dir=$1 prompt=$2 completion=$3 created=${4:-$CREATED} slug=${5:-$MODEL_ID}
  cat > "$dir/catalogue.json" <<JSON
{"data":[{"id":"$slug","created":$created,
          "pricing":{"prompt":"$prompt","completion":"$completion"}}]}
JSON
}

# write_endpoints <dir> <prompt> <completion> [<created>] [<slug>]
# One endpoint, which is the only shape that can resolve to a price.
write_endpoints() {
  local dir=$1 prompt=$2 completion=$3 created=${4:-$CREATED} slug=${5:-$MODEL_ID}
  mkdir -p "$dir/$(dirname "$slug")"
  cat > "$dir/endpoints-$(basename "$slug").json" <<JSON
{"data":{"id":"$slug","created":$created,
         "endpoints":[{"tag":"vx","provider_name":"VendorX","name":"VendorX | $slug",
                       "pricing":{"prompt":"$prompt","completion":"$completion"}}]}}
JSON
}

# write_registry <dir> [options]
#   opt_out          omit price_metadata entirely (the inert path)
#   half             declare only catalogue_url
#   no_identity      omit identity_at_verification from the allowlist entry
#   window=<n>       declare observation.levels.O1.price_max_age_seconds
#   identity=<s>@<c> record a different identity than the fixtures serve
#   endpoints=<file> point the template at a specific endpoints document
write_registry() {
  local dir=$1 mode=${2:-} window=${3:-} ident=${4:-} epname=${5:-}
  local reg="$dir/models.json" pm ident_slug ident_created obs alw
  epname=${epname:-"endpoints-{model_id}.json"}
  case "$mode" in
    opt_out) pm='' ;;
    half)    pm="\"price_metadata\": { \"catalogue_url\": \"file://$dir/catalogue.json\" }," ;;
    *)       pm="\"price_metadata\": { \"catalogue_url\": \"file://$dir/catalogue.json\", \"endpoints_url_template\": \"file://$dir/$epname\" }," ;;
  esac
  ident_slug=${MODEL_ID}
  ident_created=${CREATED}
  case "$ident" in
    ?*) ident_slug=${ident%@*}; ident_created=${ident#*@} ;;
  esac
  if [ "$mode" = no_identity ]; then
    alw="{ \"sources\": [\"provider-doc\"], \"verified_at\": \"2026-08-26T00:00:00Z\",
           \"price_at_verification\": { \"input\": 0, \"output\": 0 } }"
  else
    alw="{ \"sources\": [\"provider-doc\"], \"verified_at\": \"2026-08-26T00:00:00Z\",
           \"price_observed_at\": \"2026-08-26T00:00:00Z\",
           \"identity_at_verification\": { \"slug\": \"$ident_slug\", \"created\": $ident_created },
           \"price_at_verification\": { \"input\": 0, \"output\": 0 } }"
  fi
  obs=''
  case "$window" in
    ?*) obs="\"observation\": { \"levels\": { \"O1\": { \"price_max_age_seconds\": $window } } }," ;;
  esac
  cat > "$reg" <<JSON
{
  "schema": "fm-model-registry.v1",
  $obs
  "providers": {
    "vendorx": { "access_class": "B", "cost_posture": "api-key", $pm "status": "active" }
  },
  "models": {
    "$KEY": { "provider": "vendorx", "model_id": "$MODEL_ID", "harness": "pi",
              "cost_class": "verified-free", "status": "approved-fallback",
              "evidence": { "probe": { "result": "ok", "rc": 0, "at": "2026-08-26T00:00:00Z" } } }
  },
  "zero_budget": { "allowlist": { "$KEY": $alw } }
}
JSON
  printf '%s\n' "$reg"
}

# case_env <name> <cat-prompt> <cat-completion> <ep-prompt> <ep-completion>
# The common shape: a fixture dir with both documents and a complete opt-in
# registry. Echoes "<dir>|<registry>".
case_env() {
  local name=$1 cp=$2 cc=$3 ep=$4 ec=$5 dir reg
  dir=$(fixture_dir "$name") || return 1
  write_catalogue "$dir" "$cp" "$cc"
  write_endpoints "$dir" "$ep" "$ec"
  reg=$(write_registry "$dir") || return 1
  printf '%s|%s\n' "$dir" "$reg"
}

# observe <registry> -> the folded record, or empty.
observe() { fm_model_price_observe "$1" "$KEY"; }

# verdict_of <record> -> the verdict token.
verdict_of() { printf '%s' "$1" | jq -r '.verdict // "NONE"'; }

# refuses <registry> <record> [now] -> 0 when the gate refuses, 1 when it admits.
refuses() {
  local reg=$1 rec=$2 now=${3:-}
  if fm_model_price_decision "$rec" "$reg" "$KEY" "$now" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# --- 1. the green control ---------------------------------------------------
#
# Every refusal below is only meaningful against a case that PASSES, otherwise a
# gate that refuses everything would look identical to a gate that works.

test_a_freshly_observed_exact_zero_admits_the_dispatch() {
  local env dir reg rec
  env=$(case_env green 0 0 0 0); IFS='|' read -r dir reg <<< "$env"
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = ZERO ] || fail "the unmodified green control must observe ZERO, got: $rec"
  [ "$(fm_model_price_class ZERO)" = observed-good ] || fail "ZERO must be observed-good"
  if ! fm_model_price_decision "$rec" "$reg" "$KEY" >/dev/null; then
    fail "an exactly-zero freshly observed price must admit the dispatch"
  fi
  # The identity is recorded alongside the price, which is what makes the
  # observation re-checkable later rather than merely reassuring now.
  assert_contains "$rec" "\"slug\":\"$MODEL_ID\"" "the exact slug is recorded"
  assert_contains "$rec" "\"created\":$CREATED" "the metadata generation is recorded"
  assert_contains "$rec" '"endpoint":"vx"' "the resolved endpoint identity is recorded"
  assert_contains "$rec" '"endpoint_provider":"VendorX"' "the endpoint provider is recorded"
  assert_contains "$rec" '"observed_at"' "the observation time is recorded"
  pass "a freshly observed exactly-zero price admits the dispatch and records what it was observed on"
}

# --- 2. watched red: a positive price ---------------------------------------

test_a_positive_price_refuses() {
  local env dir reg rec
  env=$(case_env priced 0.000002 0.000008 0 0); IFS='|' read -r dir reg <<< "$env"
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = PRICED ] || fail "a positive advertised price must observe PRICED, got: $rec"
  refuses "$reg" "$rec" || fail "a positive price must refuse the dispatch"
  pass "a positive price refuses"
}

# --- 3. watched red: a ONE-SIDED positive price -----------------------------
#
# The case a "is it free?" boolean gets wrong. Zero prompt tokens and priced
# completion tokens is a metered model, and reading it as free because the first
# number matched is the whole failure.

test_a_one_sided_positive_price_refuses() {
  local env dir reg rec
  env=$(case_env onesided 0 0.000008 0 0); IFS='|' read -r dir reg <<< "$env"
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = PRICED ] \
    || fail "a zero prompt price with a priced completion must observe PRICED, got: $rec"
  refuses "$reg" "$rec" || fail "a one-sided positive price must refuse the dispatch"
  pass "a one-sided positive price refuses - zero on one axis is not zero"
}

# --- 4. watched red: a priced RESOLVED ENDPOINT -----------------------------
#
# The case that proves the endpoint read is not redundant with the catalogue
# read. The advertised model price is exactly zero and correct, and the endpoint
# that will actually serve the request is metered. A gate reading only the
# catalogue passes this, which is why the two sources both exist.

test_a_priced_resolved_endpoint_refuses_even_though_the_model_advertises_zero() {
  local env dir reg rec
  env=$(case_env epriced 0 0 0.000004 0); IFS='|' read -r dir reg <<< "$env"
  rec=$(observe "$reg")
  assert_contains "$rec" '"catalogue_prompt":0' "the advertised price really is zero in this case"
  [ "$(verdict_of "$rec")" = PRICED_ENDPOINT ] \
    || fail "a priced resolved endpoint must be distinguishable from a priced model, got: $rec"
  refuses "$reg" "$rec" || fail "a priced resolved endpoint must refuse the dispatch"
  pass "a priced resolved endpoint refuses, and is reported apart from a priced model"
}

# --- 5. watched red: an ambiguous endpoint set ------------------------------

test_multiple_endpoints_refuse_because_no_price_can_be_attributed() {
  local dir reg rec
  dir=$(fixture_dir ambiguous) || fail "fixture"
  write_catalogue "$dir" 0 0
  cat > "$dir/endpoints-$MODEL_ID.json" <<JSON
{"data":{"id":"$MODEL_ID","created":$CREATED,
         "endpoints":[{"tag":"a","pricing":{"prompt":"0","completion":"0"}},
                      {"tag":"b","pricing":{"prompt":"0","completion":"0"}}]}}
JSON
  reg=$(write_registry "$dir")
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = AMBIGUOUS_ENDPOINT ] \
    || fail "two endpoints must observe AMBIGUOUS_ENDPOINT, got: $rec"
  # Both endpoints are priced at zero here ON PURPOSE. The refusal is not about
  # the prices; it is that "the resolved endpoint" names nothing, so no price can
  # be attributed to the dispatch at all.
  refuses "$reg" "$rec" || fail "an unresolvable endpoint must refuse even when every endpoint reads zero"
  pass "an ambiguous endpoint set refuses even when every endpoint is priced at zero"
}

# --- 6. watched red: unreachable metadata -----------------------------------

test_unreachable_metadata_refuses() {
  local dir reg rec
  dir=$(fixture_dir unreachable) || fail "fixture"
  write_catalogue "$dir" 0 0
  # The endpoints document is simply never written, so the real transport fails
  # to retrieve it exactly as it would against an unreachable provider.
  reg=$(write_registry "$dir")
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = UNREACHABLE ] || fail "an absent source must observe UNREACHABLE, got: $rec"
  [ "$(fm_model_price_class UNREACHABLE)" = could-not-observe ] \
    || fail "an unreachable source is could-not-observe, not observed-good"
  refuses "$reg" "$rec" || fail "unreachable metadata must refuse the dispatch"
  pass "unreachable metadata refuses"
}

# --- 7. watched red: malformed metadata -------------------------------------

test_malformed_metadata_refuses() {
  local dir reg rec
  dir=$(fixture_dir malformed) || fail "fixture"
  write_catalogue "$dir" 0 0
  printf 'this is not the document you are looking for\n' > "$dir/endpoints-$MODEL_ID.json"
  reg=$(write_registry "$dir")
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = MALFORMED ] || fail "an unparseable source must observe MALFORMED, got: $rec"
  refuses "$reg" "$rec" || fail "malformed metadata must refuse the dispatch"
  pass "malformed metadata refuses"
}

# --- 8. watched red: the model is not there ---------------------------------

test_a_model_absent_from_the_metadata_refuses() {
  local dir reg rec
  dir=$(fixture_dir missing) || fail "fixture"
  write_catalogue "$dir" 0 0 "$CREATED" "someone-else"
  write_endpoints "$dir" 0 0
  reg=$(write_registry "$dir")
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = MISSING ] || fail "an absent model must observe MISSING, got: $rec"
  refuses "$reg" "$rec" || fail "a model absent from the provider metadata must refuse"
  pass "a model absent from the provider metadata refuses"
}

# --- 9. watched red: the price cannot be read -------------------------------

test_an_unreadable_price_refuses() {
  local dir reg rec
  dir=$(fixture_dir unknownprice) || fail "fixture"
  printf '{"data":[{"id":"%s","created":%s,"pricing":{}}]}\n' "$MODEL_ID" "$CREATED" > "$dir/catalogue.json"
  write_endpoints "$dir" 0 0
  reg=$(write_registry "$dir")
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = UNKNOWN_PRICE ] || fail "a missing price must observe UNKNOWN_PRICE, got: $rec"
  refuses "$reg" "$rec" || fail "an unknown price must refuse - it is never a free one"
  pass "an unreadable price refuses rather than defaulting to free"
}

# --- 10. watched red: identity mutation -------------------------------------
#
# Two shapes, and both matter. The sources can disagree with each other, and the
# provider can disagree with the evidence this home recorded - a slug reused for
# a new generation, which would otherwise inherit the trust of the thing it
# replaced.

test_sources_that_disagree_on_identity_refuse() {
  local dir reg rec
  dir=$(fixture_dir crossid) || fail "fixture"
  write_catalogue "$dir" 0 0 "$CREATED"
  write_endpoints "$dir" 0 0 $((CREATED + 999))
  reg=$(write_registry "$dir")
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = IDENTITY_MISMATCH ] \
    || fail "sources naming different generations must observe IDENTITY_MISMATCH, got: $rec"
  refuses "$reg" "$rec" || fail "disagreeing sources must refuse rather than one supplying the price"
  pass "two sources disagreeing on identity refuse"
}

test_an_identity_that_moved_since_verification_refuses() {
  local dir reg rec out
  dir=$(fixture_dir idmoved) || fail "fixture"
  write_catalogue "$dir" 0 0
  write_endpoints "$dir" 0 0
  # The provider serves the identity the fixtures name; the RECORDED evidence was
  # taken against a different generation of the same slug.
  reg=$(write_registry "$dir" '' '' "$MODEL_ID@$((CREATED - 1))")
  rec=$(observe "$reg")
  [ "$(verdict_of "$rec")" = ZERO ] || fail "the observation itself is clean in this case, got: $rec"
  out=$(fm_model_price_decision "$rec" "$reg" "$KEY" 2>&1) \
    && fail "a generation that moved since verification must refuse"
  assert_contains "$out" "IDENTITY_MISMATCH" "the refusal names identity, not price"
  pass "an identity that moved since the price was verified refuses"
}

test_a_slug_that_moved_since_verification_refuses() {
  local dir reg rec out
  dir=$(fixture_dir slugmoved) || fail "fixture"
  write_catalogue "$dir" 0 0
  write_endpoints "$dir" 0 0
  reg=$(write_registry "$dir" '' '' "other-slug@$CREATED")
  rec=$(observe "$reg")
  out=$(fm_model_price_decision "$rec" "$reg" "$KEY" 2>&1) \
    && fail "a slug that moved since verification must refuse"
  assert_contains "$out" "IDENTITY_MISMATCH" "the refusal names identity"
  pass "a slug that moved since the price was verified refuses"
}

# --- 11. watched red: a stale observation -----------------------------------

test_an_observation_older_than_the_window_refuses() {
  local env dir reg rec now out
  env=$(case_env stale 0 0 0 0); IFS='|' read -r dir reg <<< "$env"
  rec=$(observe "$reg")
  now=$(fm_model_price_epoch "$(printf '%s' "$rec" | jq -r .observed_at)")
  # One second inside the window still admits; one second past it does not. The
  # pair is the point: a boundary asserted from one side only is not a boundary.
  if ! fm_model_price_decision "$rec" "$reg" "$KEY" "$((now + FM_MODEL_PRICE_O1_MAX_AGE_SECONDS - 1))" >/dev/null; then
    fail "an observation inside the freshness window must still admit"
  fi
  out=$(fm_model_price_decision "$rec" "$reg" "$KEY" "$((now + FM_MODEL_PRICE_O1_MAX_AGE_SECONDS + 1))" 2>&1) \
    && fail "an observation past the freshness window must refuse"
  assert_contains "$out" "STALE" "the refusal names staleness"
  pass "an observation older than the freshness window refuses, and one inside it does not"
}

test_a_home_may_narrow_the_freshness_window_but_never_widen_it() {
  local dir reg_narrow reg_wide rec now
  dir=$(fixture_dir window) || fail "fixture"
  write_catalogue "$dir" 0 0
  write_endpoints "$dir" 0 0
  reg_narrow=$(write_registry "$dir" '' 60)
  rec=$(observe "$reg_narrow")
  now=$(fm_model_price_epoch "$(printf '%s' "$rec" | jq -r .observed_at)")
  if fm_model_price_decision "$rec" "$reg_narrow" "$KEY" "$((now + 61))" >/dev/null 2>&1; then
    fail "a home that narrowed its window to 60s must refuse a 61s-old observation"
  fi
  # And the ceiling: a home cannot buy itself a longer window than the policy
  # allows. Same direction as the promotion-authority rows - more conservative is
  # permitted, more permissive is not.
  mkdir -p "$dir/wide"
  cp "$dir/catalogue.json" "$dir/wide/" 2>/dev/null || true
  reg_wide=$(write_registry "$dir" '' $((FM_MODEL_PRICE_O1_MAX_AGE_SECONDS * 10)))
  [ "$(fm_model_price_window "$reg_wide")" = "$FM_MODEL_PRICE_O1_MAX_AGE_SECONDS" ] \
    || fail "a declared window wider than the policy ceiling must be clamped to it"
  pass "a home may narrow the freshness window and cannot widen it past the policy ceiling"
}

# --- 12. the negative rule that ties them together --------------------------

test_no_verdict_other_than_zero_ever_admits_a_dispatch() {
  local env dir reg rec v
  env=$(case_env allverdicts 0 0 0 0); IFS='|' read -r dir reg <<< "$env"
  rec=$(observe "$reg")
  # Every non-ZERO verdict in the vocabulary, substituted into an otherwise clean
  # record. This is the assertion that makes the suite exhaustive rather than
  # anecdotal: it does not depend on being able to CONSTRUCT each condition, so a
  # verdict added later without a refusal path fails here.
  for v in PRICED PRICED_ENDPOINT AMBIGUOUS_ENDPOINT IDENTITY_MISMATCH STALE \
           UNREACHABLE MALFORMED MISSING UNKNOWN_PRICE SOMETHING_UNFORESEEN; do
    if fm_model_price_decision \
        "$(printf '%s' "$rec" | jq -c --arg v "$v" '.verdict = $v')" \
        "$reg" "$KEY" >/dev/null 2>&1; then
      fail "verdict $v must not admit a dispatch"
    fi
  done
  # And an empty record - the shape a caller gets when nothing could be produced
  # at all - must refuse rather than read as an absent objection.
  if fm_model_price_decision "" "$reg" "$KEY" >/dev/null 2>&1; then
    fail "an empty record must refuse rather than admit"
  fi
  pass "no verdict other than ZERO admits a dispatch, and an unknown price is never a free one"
}

test_the_three_observation_values_stay_distinguishable() {
  # Refusing everything is correct AND insufficient: a report has to be able to
  # say whether the fleet saw a charge or failed to look, because those are
  # different repairs. This is the only thing the classifier is for; it never
  # softens the refusal above.
  [ "$(fm_model_price_class ZERO)" = observed-good ] || fail "ZERO is observed-good"
  [ "$(fm_model_price_class PRICED)" = observed-bad ] || fail "a seen charge is observed-bad"
  [ "$(fm_model_price_class PRICED_ENDPOINT)" = observed-bad ] || fail "a seen endpoint charge is observed-bad"
  [ "$(fm_model_price_class UNREACHABLE)" = could-not-observe ] || fail "a failed fetch is could-not-observe"
  [ "$(fm_model_price_class MALFORMED)" = could-not-observe ] || fail "an unparseable document is could-not-observe"
  [ "$(fm_model_price_class STALE)" = could-not-observe ] || fail "an aged observation is could-not-observe"
  [ "$(fm_model_price_class ANYTHING_ELSE)" = could-not-observe ] \
    || fail "an unrecognised verdict must fall to could-not-observe, never to observed-good"
  pass "the three observation values stay distinguishable without any of them admitting a dispatch"
}

# --- 13. a slashed model id resolves through the template -------------------
#
# The production slug carries a slash, and a template substitution that broke on
# one would report every such model unreachable - a could-not-observe caused by
# the instrument rather than by the provider.

test_a_model_id_containing_a_slash_resolves_through_the_url_template() {
  local dir reg rec saved_key saved_id
  dir=$(fixture_dir slashed) || fail "fixture"
  saved_key=$KEY; saved_id=$MODEL_ID
  KEY=vendorx/nested/thing; MODEL_ID=nested/thing
  write_catalogue "$dir" 0 0
  write_endpoints "$dir" 0 0
  reg=$(write_registry "$dir" '' '' '' 'endpoints-{model_id}.json')
  # write_endpoints names the file after the BASENAME, so point the template at
  # the same shape the fixture actually wrote.
  reg=$(write_registry "$dir" '' '' '' 'nested/endpoints-thing.json')
  mkdir -p "$dir/nested"
  mv "$dir/endpoints-thing.json" "$dir/nested/endpoints-thing.json" 2>/dev/null || true
  rec=$(observe "$reg")
  KEY=$saved_key; MODEL_ID=$saved_id
  [ "$(verdict_of "$rec")" = ZERO ] \
    || fail "a slashed model id must resolve through the template, got: $rec"
  pass "a model id containing a slash resolves through the endpoint url template"
}

# --- 14. no credential ever reaches a metadata fetch ------------------------
#
# The price of a model is public and the credential that reaches it is not. This
# is asserted BEHAVIOURALLY, against a real loopback server that records what
# arrived, because the property under test is what curl actually sends - which a
# grep for a flag in this repo cannot answer.

test_ambient_curl_configuration_cannot_attach_a_credential_to_a_metadata_fetch() {
  local dir port srv_pid out fake_home rc
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to observe what the fetch actually sends; refusing to pass without checking"
  dir=$(fixture_dir credential) || fail "fixture"
  cat > "$dir/server.py" <<'PY'
import http.server, socket, sys, threading
recorded = open(sys.argv[1], "w")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        for k, v in self.headers.items():
            recorded.write("%s: %s\n" % (k, v))
        recorded.flush()
        body = b'{"data":[]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
srv = http.server.HTTPServer(("127.0.0.1", port), H)
open(sys.argv[2], "w").write(str(port))
srv.serve_forever()
PY
  python3 "$dir/server.py" "$dir/headers.txt" "$dir/port.txt" &
  srv_pid=$!
  fm_test_reap "$srv_pid"
  fm_test_wait_file "$dir/port.txt" 30 "$srv_pid" \
    "the loopback metadata server exited before it could serve a request; refusing to pass without observing one" \
    "the loopback metadata server did not start; refusing to pass without observing a real request"
  port=$(cat "$dir/port.txt")

  # An ambient curl configuration that WOULD attach a credential to every
  # request, in both of the places curl reads one from.
  fake_home="$dir/home"
  mkdir -p "$fake_home"
  printf 'header = "X-Leaked-Credential: sentinel-must-not-appear"\n' > "$fake_home/.curlrc"
  printf 'machine 127.0.0.1 login sentinel-user password sentinel-must-not-appear\n' > "$fake_home/.netrc"
  chmod 600 "$fake_home/.netrc"

  rc=0
  HOME="$fake_home" CURL_HOME="$fake_home" \
    fm_model_price_fetch "http://127.0.0.1:$port/models" "$dir/out.json" || rc=$?
  [ "$rc" = 0 ] || fail "the metadata fetch did not complete against the loopback server (rc=$rc)"

  # A control on the observation itself: the recording must have captured a real
  # request, or the absence below would prove nothing.
  assert_present "$dir/headers.txt" "the server must have recorded the request"
  assert_grep "Accept:" "$dir/headers.txt" "the recorded request must be the real one this library sends"
  out=$(cat "$dir/headers.txt")
  assert_not_contains "$out" "sentinel-must-not-appear" "no ambient credential may reach a metadata fetch"
  assert_not_contains "$out" "X-Leaked-Credential" "no ambient header may reach a metadata fetch"
  assert_not_contains "$out" "Authorization" "a metadata fetch carries no authorization"
  pass "ambient curl configuration cannot attach a credential to a metadata fetch"
}

# --- 15. the registry validator catches a half-built opt-in -----------------

test_the_validator_requires_a_recorded_identity_once_a_provider_opts_in() {
  local dir reg err
  dir=$(fixture_dir valid-noident) || fail "fixture"
  write_catalogue "$dir" 0 0
  write_endpoints "$dir" 0 0
  reg=$(write_registry "$dir" no_identity)
  err=$(fm_model_registry_validate "$reg") \
    && fail "an opted-in provider whose allowlist entry records no identity must be refused"
  assert_contains "$err" "identity_at_verification" "the refusal names the missing field"
  assert_contains "$err" "$KEY" "the refusal names the entry"
  pass "the validator requires a recorded identity once its provider opts in"
}

test_the_validator_refuses_a_half_declared_metadata_source() {
  local dir reg err
  dir=$(fixture_dir valid-half) || fail "fixture"
  write_catalogue "$dir" 0 0
  reg=$(write_registry "$dir" half)
  err=$(fm_model_registry_validate "$reg") \
    && fail "a price_metadata declaring only one source must be refused"
  assert_contains "$err" "endpoints_url_template" "the refusal names what is missing"
  pass "the validator refuses a half-declared metadata source"
}

test_the_validator_refuses_a_template_that_cannot_name_a_model() {
  local dir reg err
  dir=$(fixture_dir valid-tmpl) || fail "fixture"
  write_catalogue "$dir" 0 0
  reg=$(write_registry "$dir")
  jq '.providers.vendorx.price_metadata.endpoints_url_template = "https://example.invalid/endpoints"' \
    "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
  err=$(fm_model_registry_validate "$reg") \
    && fail "a template with no {model_id} placeholder must be refused"
  assert_contains "$err" "{model_id}" "the refusal names the placeholder"
  pass "the validator refuses an endpoint template that cannot name a model"
}

test_the_validator_refuses_an_unusable_freshness_window() {
  local dir reg err
  dir=$(fixture_dir valid-window) || fail "fixture"
  write_catalogue "$dir" 0 0
  write_endpoints "$dir" 0 0
  reg=$(write_registry "$dir" '' 0)
  err=$(fm_model_registry_validate "$reg") \
    && fail "a zero freshness window must be refused rather than making every dispatch stale"
  assert_contains "$err" "price_max_age_seconds" "the refusal names the field"
  pass "the validator refuses an unusable freshness window"
}

test_a_registry_that_never_opts_in_stays_valid_and_inert() {
  local dir reg rc
  dir=$(fixture_dir optout) || fail "fixture"
  write_catalogue "$dir" 0 0
  write_endpoints "$dir" 0 0
  reg=$(write_registry "$dir" opt_out)
  if ! fm_model_registry_validate "$reg" >/dev/null; then
    fail "a registry that declares no price_metadata must remain valid"
  fi
  rc=0
  fm_model_price_observe "$reg" "$KEY" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "a provider that never opted in must be inert (rc 1), got rc=$rc"
  pass "a registry that never opts in stays valid and the live check stays inert"
}

test_an_absent_registry_is_inert_rather_than_broken() {
  local rc=0
  # The additive-compatibility guarantee. Reading an absent registry as a broken
  # one would refuse every dispatch in every home that never opted in, which is
  # the more dangerous of the two ways to get this backwards.
  fm_model_price_observe "$TMP_ROOT/definitely-absent-models.json" "$KEY" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "an absent registry must be inert (rc 1), got rc=$rc"
  pass "an absent registry is inert rather than broken"
}

test_a_bare_harness_native_model_name_is_not_a_provider_route() {
  local env dir reg rc bare
  env=$(case_env bare 0 0 0 0); IFS='|' read -r dir reg <<< "$env"
  for bare in '' default opus; do
    rc=0
    fm_model_price_observe "$reg" "$bare" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || fail "\"$bare\" involves no provider credential and must be inert, got rc=$rc"
  done
  pass "a bare harness-native model name is not a provider route and is inert"
}

# --- 16. the dispatch chokepoint --------------------------------------------
#
# The library answering correctly is necessary and not sufficient: the answer has
# to be asked at the point where money would be spent. These drive the real
# bin/fm-spawn.sh.

# spawn_home <name> <cat-prompt> <cat-completion> <ep-prompt> <ep-completion> [<registry-mode>]
# A home whose fake tmux succeeds and which owns a real isolated worktree, so a
# dispatch that passes every gate reaches task metadata.
spawn_home() {
  local name=$1 cp=$2 cc=$3 ep=$4 ec=$5 mode=${6:-}
  local home="$TMP_ROOT/$name" dir
  mkdir -p "$home/config" "$home/state" "$home/data/pricetask" "$home/projects" "$home/bin"
  dir=$(fixture_dir "reg-$name") || return 1
  write_catalogue "$dir" "$cp" "$cc"
  write_endpoints "$dir" "$ep" "$ec"
  write_registry "$dir" "$mode" >/dev/null
  cp "$dir/models.json" "$home/config/models.json"
  cat > "$home/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$home/bin/tmux"
  fm_fake_treehouse "$home/bin"
  fm_fake_exit0 "$home/bin" pi
  fm_git_worktree "$home/repo" "$home/wt" "wt-$name"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    printf 'Delivery contract: mode=no-mistakes\n'
  } > "$home/data/pricetask/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

run_price_spawn() {  # <home>
  local home=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
    FM_FAKE_PANE_PATH="$home/wt" TMUX="fake,1,0" PATH="$home/bin:$PATH" \
    "$SPAWN" pricetask "$home/repo" --mode no-mistakes --yolo off \
      --harness pi --model "$KEY" --effort low \
      --reason-code NL_RULE_CLASSIFICATION 2>&1
}

test_spawn_refuses_a_dispatch_whose_freshly_observed_price_is_not_zero() {
  local home out
  home=$(spawn_home spawn-priced 0 0 0.000004 0) || fail "fixture"
  out=$(run_price_spawn "$home" || true)
  assert_contains "$out" "zero-cost check refuses" "the spawn must refuse on the live price"
  assert_contains "$out" "PRICED_ENDPOINT" "the refusal names the observed cause"
  assert_absent "$home/state/pricetask.meta" "a refused dispatch writes no task metadata"
  pass "fm-spawn refuses a dispatch whose freshly observed resolved-endpoint price is not zero"
}

test_spawn_records_the_price_evidence_it_was_admitted_against() {
  local home out meta
  home=$(spawn_home spawn-green 0 0 0 0) || fail "fixture"
  out=$(run_price_spawn "$home" || true)
  meta="$home/state/pricetask.meta"
  [ -f "$meta" ] || fail "a dispatch at an exactly-zero price must reach task metadata"$'\n'"--- output ---"$'\n'"$out"
  # RECURRENCE PROBE. The recorded evidence is what proves this dispatch consulted
  # the provider at all. A dispatch that reached metadata with no price block in
  # an opted-in home is one that got past the gate.
  assert_grep "price_verdict=ZERO" "$meta" "meta records the verdict this dispatch was admitted against"
  assert_grep "price_slug=$MODEL_ID" "$meta" "meta records the exact slug"
  assert_grep "price_metadata_created=$CREATED" "$meta" "meta records the metadata generation"
  assert_grep "price_endpoint=vx" "$meta" "meta records the resolved endpoint"
  assert_grep "price_endpoint_provider=VendorX" "$meta" "meta records the endpoint provider identity"
  assert_grep "price_prompt=0" "$meta" "meta records the observed prompt price"
  assert_grep "price_completion=0" "$meta" "meta records the observed completion price"
  assert_grep "price_observed_at=" "$meta" "meta records when the price was observed"
  # The normal execution-attempt lineage is untouched by any of this.
  assert_grep "model=$KEY" "$meta" "the ordinary dispatch record is unchanged"
  pass "fm-spawn binds the exact price evidence it was admitted against into the task metadata"
}

test_spawn_is_inert_for_a_provider_that_declared_no_metadata_source() {
  local home out
  home=$(spawn_home spawn-inert 0 0 0 0 opt_out) || fail "fixture"
  out=$(run_price_spawn "$home" || true)
  assert_not_contains "$out" "zero-cost check refuses" "a provider that never opted in must not be gated"
  assert_present "$home/state/pricetask.meta" "an un-opted-in dispatch proceeds exactly as before"
  assert_no_grep "price_verdict=" "$home/state/pricetask.meta" \
    "an absent price block means the home enforces no live check, not that one was skipped"
  pass "fm-spawn stays inert for a provider that declared no metadata source"
}

test_spawn_refuses_a_broken_metadata_declaration_rather_than_treating_it_as_absent() {
  local home out
  home=$(spawn_home spawn-half 0 0 0 0 half) || fail "fixture"
  out=$(run_price_spawn "$home" || true)
  assert_contains "$out" "could not be read" "a broken declaration must refuse"
  assert_absent "$home/state/pricetask.meta" "a refused dispatch writes no task metadata"
  pass "fm-spawn refuses a broken metadata declaration rather than reading it as an absent one"
}

# --- 17. the verification path ----------------------------------------------

run_verify() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    "$VERIFY" "$@" 2>&1
}

verify_home() {  # <name> <cat-prompt> <cat-completion> <ep-prompt> <ep-completion>
  local name=$1
  # Two statements, deliberately. bash expands every right-hand side in one
  # `local` before assigning any of them, so "$TMP_ROOT/$name" here would read
  # whatever outer `name` happened to exist - a stale path, silently.
  local home="$TMP_ROOT/$name" dir
  mkdir -p "$home/config" "$home/state"
  dir=$(fixture_dir "vreg-$name") || return 1
  write_catalogue "$dir" "$2" "$3"
  write_endpoints "$dir" "$4" "$5"
  write_registry "$dir" >/dev/null
  cp "$dir/models.json" "$home/config/models.json"
  printf '%s\n' "$home"
}

test_verification_refuses_to_probe_a_model_whose_live_price_is_not_zero() {
  local home out
  home=$(verify_home verify-priced 0 0 0.000004 0) || fail "fixture"
  out=$(run_verify "$home" --all || true)
  assert_contains "$out" "MODEL_PRICE:" "the live price refusal is reported"
  assert_contains "$out" "refusing to probe" "and it stops the probe"
  # The probe is the billable act, so this ordering is the point: cost class is
  # established before entitlement, never after.
  pass "verification refuses to probe a model whose freshly observed price is not zero"
}

test_force_probe_does_not_lift_the_live_price_refusal() {
  local home out
  home=$(verify_home verify-force 0 0 0.000004 0) || fail "fixture"
  out=$(run_verify "$home" --all --force-probe || true)
  assert_contains "$out" "refusing to probe" \
    "--force-probe overrides the RECORDED cost refusal and must not override a fresh contradiction from the provider"
  pass "--force-probe does not lift a refusal the provider itself just issued"
}

test_verification_records_the_observation_it_made() {
  local home rec
  home=$(verify_home verify-record 0 0 0 0) || fail "fixture"
  run_verify "$home" --dry-run >/dev/null || true
  assert_present "$home/state/model-price.json" "the observation is recorded for a later reader"
  rec=$(jq -r --arg k "$KEY" '.models[$k].verdict // "NONE"' "$home/state/model-price.json")
  [ "$rec" = ZERO ] || fail "the recorded observation must carry the verdict, got $rec"
  rec=$(jq -r --arg k "$KEY" '.models[$k].endpoint_provider // ""' "$home/state/model-price.json")
  [ "$rec" = VendorX ] || fail "the recorded observation must carry the endpoint identity, got '$rec'"
  # Availability and price stay on separate files, as they do everywhere else in
  # this fleet: one is about reachability and the other about cost, and merging
  # them would let either lend authority to the other.
  assert_absent "$home/state/model-price.json.health" "price and availability stay separate records"
  pass "verification records the observation, with its identity, on its own axis"
}

test_a_freshly_observed_exact_zero_admits_the_dispatch
test_a_positive_price_refuses
test_a_one_sided_positive_price_refuses
test_a_priced_resolved_endpoint_refuses_even_though_the_model_advertises_zero
test_multiple_endpoints_refuse_because_no_price_can_be_attributed
test_unreachable_metadata_refuses
test_malformed_metadata_refuses
test_a_model_absent_from_the_metadata_refuses
test_an_unreadable_price_refuses
test_sources_that_disagree_on_identity_refuse
test_an_identity_that_moved_since_verification_refuses
test_a_slug_that_moved_since_verification_refuses
test_an_observation_older_than_the_window_refuses
test_a_home_may_narrow_the_freshness_window_but_never_widen_it
test_no_verdict_other_than_zero_ever_admits_a_dispatch
test_the_three_observation_values_stay_distinguishable
test_a_model_id_containing_a_slash_resolves_through_the_url_template
test_ambient_curl_configuration_cannot_attach_a_credential_to_a_metadata_fetch
test_the_validator_requires_a_recorded_identity_once_a_provider_opts_in
test_the_validator_refuses_a_half_declared_metadata_source
test_the_validator_refuses_a_template_that_cannot_name_a_model
test_the_validator_refuses_an_unusable_freshness_window
test_a_registry_that_never_opts_in_stays_valid_and_inert
test_an_absent_registry_is_inert_rather_than_broken
test_a_bare_harness_native_model_name_is_not_a_provider_route
test_spawn_refuses_a_dispatch_whose_freshly_observed_price_is_not_zero
test_spawn_records_the_price_evidence_it_was_admitted_against
test_spawn_is_inert_for_a_provider_that_declared_no_metadata_source
test_spawn_refuses_a_broken_metadata_declaration_rather_than_treating_it_as_absent
test_verification_refuses_to_probe_a_model_whose_live_price_is_not_zero
test_force_probe_does_not_lift_the_live_price_refusal
test_verification_records_the_observation_it_made

fm_test_contract "$0" || exit 1
