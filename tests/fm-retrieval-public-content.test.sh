#!/usr/bin/env bash
# The public-content retrieval contract: bin/fm-retrieval-lib.sh's
# fm_retrieval_public_fetch may climb its closed User-Agent ladder only on
# positively typed evidence of client filtering, and a fallback success may
# never be credited with what only a default-client success could establish.
#
# Every case here is written so the assertion fails if the ladder moved on the
# absence of evidence rather than the presence of it. A refusal that is really a
# paywall, a login boundary, a CAPTCHA, a rate limit, or an unexplained 403 must
# cost exactly one request, and the transport log is what proves it: each case
# asserts the number of requests and the exact User-Agent of each one, so a
# second identity cannot be sent quietly.
#
# The fixture serves real HTTP-shaped responses through a fake `curl` on PATH,
# recording method, URL, every request header, the client string, and the hop
# order. A stub that answered in some other shape would only confirm the stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Overridable so the mutation controls in this file, and a maintainer's watched-red
# sweep, can point the same behavioral assertions at a deliberately broken copy.
LIB="${FM_TEST_RETRIEVAL_LIB:-$ROOT/bin/fm-retrieval-lib.sh}"

TMP_ROOT=$(fm_test_tmproot fm-retrieval-public) || fail "could not create a temp root"

# The exact string the Captain authorized for the final profile. It is written
# here independently of the implementation so this suite disagrees loudly if the
# implementation ever transmits something else.
AUTHORIZED_UA='OpenAI File Downloader, XaiImageApiFetch/1.0'

# --- fixture -----------------------------------------------------------------
#
# fixture_new <name> creates a response-serving root and echoes it.
#
# fixture_reply <root> <key> <status> <headers> <body> scripts one reply. The key
# is how the fake selects a reply, in this order:
#   ua:<user-agent>   matched against the exact client string of the request
#   url:<url>         matched against the exact request URL
#   default           used when nothing else matched
# Matching on the CLIENT STRING is what lets a case say "this document answers
# 200 only to the branded profile" without the fake knowing anything about the
# ladder under test.
#
# fixture_fail <root> <key> <exit> scripts a transport-level failure instead,
# which is how TLS, timeout and byte-bound behavior are exercised without a
# network.

fixture_new() {  # <name>
  local root=$TMP_ROOT/fix-$1
  mkdir -p "$root/replies" || return 1
  : > "$root/requests"
  printf '%s' "$root"
}

fixture_key_path() {  # <root> <key>
  local root=$1 key=$2 safe
  safe=$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/replies/%s' "$root" "$safe"
}

fixture_reply() {  # <root> <key> <status> <headers> <body>
  local path
  path=$(fixture_key_path "$1" "$2")
  printf '%s' "$3" > "$path.status"
  printf '%s' "$4" > "$path.headers"
  printf '%s' "$5" > "$path.body"
  rm -f "$path.exit"
}

fixture_fail() {  # <root> <key> <exit>
  local path
  path=$(fixture_key_path "$1" "$2")
  printf '%s' "$3" > "$path.exit"
  rm -f "$path.status" "$path.headers" "$path.body"
}

# Every request the fake serves appends one TAB-separated record to
# <root>/requests: url, user-agent, then each -H header joined by '|'. A case
# reads that log to assert how many identities were transmitted and in what
# order.
install_fake_curl() {  # <fixture-root>
  local fixture=$1 fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
# Fake curl serving the fixture at $fixture.
set -u
FIX='$fixture'
SH
  cat >> "$fakebin/curl" <<'SH'
url=; ua=; hdr_out=; body_out=; hdrs=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -A) ua=$2; shift 2 ;;
    -D) hdr_out=$2; shift 2 ;;
    -o) body_out=$2; shift 2 ;;
    -H) hdrs="${hdrs}${hdrs:+|}$2"; shift 2 ;;
    -w) shift 2 ;;
    --max-time|--max-filesize|--proto|--proto-redir) shift 2 ;;
    -sS|-s|-S) shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\t%s\t%s\n' "$url" "$ua" "$hdrs" >> "$FIX/requests"

key_path() {
  printf '%s/replies/%s' "$FIX" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}
sel=
for candidate in "ua:$ua" "url:$url" default; do
  p=$(key_path "$candidate")
  if [ -f "$p.status" ] || [ -f "$p.exit" ]; then sel=$p; break; fi
done
[ -n "$sel" ] && [ -f "$sel.exit" ] && exit "$(cat "$sel.exit")"
if [ -z "$sel" ]; then printf '000'; exit 7; fi
status=$(cat "$sel.status")
{
  printf 'HTTP/2.0 %s SCRIPTED\r\n' "$status"
  if [ -s "$sel.headers" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      printf '%s\r\n' "$line"
    done < "$sel.headers"
  fi
  printf '\r\n'
} > "$hdr_out"
cat "$sel.body" > "$body_out"
printf '%s' "$status"
exit 0
SH
  chmod +x "$fakebin/curl"
  printf '%s' "$fakebin"
}

# --- driver ------------------------------------------------------------------
#
# run_public <fixture> <url> <context> <request-headers-file-or-empty> [env=...]
# sources the library in a child shell, runs the entrypoint, and reports the
# resulting state as one KEY=VALUE block in OUT, with the exit status in RC.
# Sourcing in a child keeps each case's globals from leaking into the next.

OUT=
run_public() {  # <fixture> <url> <context> <headers-file-or-empty> [env=...]
  local fixture=$1 url=$2 context=$3 headers=$4 fakebin
  shift 4
  fakebin=$(install_fake_curl "$fixture")
  : > "$fixture/sleeps"
  cat > "$fakebin/fm-test-sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> '$fixture/sleeps'
SH
  chmod +x "$fakebin/fm-test-sleep"
  # The child script is deliberately single-quoted: every name in it must expand
  # in the child, against the environment assembled on this command line.
  # shellcheck disable=SC2016
  OUT=$(PATH="$fakebin:$PATH" FM_RETRIEVAL_SLEEP=fm-test-sleep \
    FM_TEST_LIB="$LIB" FM_TEST_URL="$url" FM_TEST_CONTEXT="$context" \
    FM_TEST_HEADERS="$headers" FM_TEST_OUT="$fixture/body" \
    env "$@" bash -c '
      set -u
      . "$FM_TEST_LIB"
      rc=0
      fm_retrieval_public_fetch "$FM_TEST_URL" "$FM_TEST_OUT" "$FM_TEST_CONTEXT" \
        "$FM_TEST_HEADERS" || rc=$?
      printf "rc=%s\n" "$rc"
      printf "completeness=%s\n" "$FM_RETRIEVAL_COMPLETENESS"
      printf "reason=%s\n" "$FM_RETRIEVAL_REASON"
      printf "detail=%s\n" "$FM_RETRIEVAL_DETAIL"
      printf "profile=%s\n" "$FM_RETRIEVAL_PUBLIC_PROFILE"
      printf "attempts=%s\n" "$FM_RETRIEVAL_PUBLIC_ATTEMPTS"
      printf "requests=%s\n" "$FM_RETRIEVAL_PUBLIC_REQUESTS"
      printf "status=%s\n" "$FM_RETRIEVAL_PUBLIC_STATUS"
      printf "class=%s\n" "$FM_RETRIEVAL_PUBLIC_CLASS"
      printf "final_url=%s\n" "$FM_RETRIEVAL_PUBLIC_FINAL_URL"
      printf "final_origin=%s\n" "$FM_RETRIEVAL_PUBLIC_FINAL_ORIGIN"
      printf "stripped=%s\n" "$FM_RETRIEVAL_PUBLIC_STRIPPED"
      printf "blocked=%s\n" "$FM_RETRIEVAL_PUBLIC_FALLBACK_BLOCKED"
      printf "provenance=%s\n" "$FM_RETRIEVAL_PROVENANCE"
      for claim in content-retrieved default-client-compatible \
        normal-client-accessible authenticated-api-correct no-bot-filtering; do
        if fm_retrieval_public_supports "$claim"; then
          printf "supports:%s=yes\n" "$claim"
        else
          printf "supports:%s=no\n" "$claim"
        fi
      done
    ' 2>&1)
  return 0
}

state() {  # <key>
  printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1
}

assert_state() {  # <key> <expected> <label>
  local got
  got=$(state "$1")
  [ "$got" = "$2" ] || fail "$3: expected $1=$2, got '$got'
--- state ---
$OUT"
}

request_count() {  # <fixture>
  local n
  n=$(wc -l < "$1/requests" 2>/dev/null | tr -d ' ')
  printf '%s' "${n:-0}"
}

request_ua() {  # <fixture> <n>
  sed -n "${2}p" "$1/requests" | cut -f2
}

request_headers() {  # <fixture> <n>
  sed -n "${2}p" "$1/requests" | cut -f3
}

meta_field() {  # <fixture> <jq-filter>
  jq -r "$2" "$1/body.meta" 2>/dev/null
}

# One reply body that positively names an automated-client filter, and one that
# names nothing at all. The difference between them is the entire licence to
# move the ladder, so they are defined once and reused.
FILTER_BODY='<html><body>Request blocked: automated client traffic is not permitted.</body></html>'
SILENT_BODY='<html><body>Forbidden.</body></html>'

# --- the closed attempt order ------------------------------------------------

test_normal_success_costs_exactly_one_request() {
  local fix
  fix=$(fixture_new normal-ok)
  fixture_reply "$fix" default 200 'Content-Type: text/plain' 'the whole document'
  run_public "$fix" 'https://public.test/doc.txt' public-content ''

  assert_state rc 0 "an ordinary public document is retrieved"
  assert_state completeness complete "the body arrived whole"
  assert_state reason body_complete "the reason names a complete body"
  assert_state profile NORMAL "the ladder never moved"
  assert_state attempts 1 "one profile was attempted"
  [ "$(request_count "$fix")" = 1 ] || fail "expected exactly one request, got $(request_count "$fix")"
  [ "$(cat "$fix/body")" = 'the whole document' ] || fail "the published bytes are not the document"
  pass "a public document that answers a normal client costs exactly one request"
}

test_positively_typed_filter_admits_one_browser_retry() {
  local fix browser_ua
  fix=$(fixture_new browser-ok)
  fixture_reply "$fix" default 403 'Content-Type: text/html' "$FILTER_BODY"
  browser_ua=$(bash -c '. "$1"; fm_retrieval_public_profile_ua BROWSER_COMPAT_RETRIEVAL' _ "$LIB")
  fixture_reply "$fix" "ua:$browser_ua" 200 'Content-Type: text/html' '<html>the document</html>'
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state rc 0 "the browser-compatibility profile retrieved the document"
  assert_state profile BROWSER_COMPAT_RETRIEVAL "the second profile is the one that answered"
  assert_state attempts 2 "exactly two profiles were attempted"
  [ "$(request_count "$fix")" = 2 ] || fail "expected exactly two requests, got $(request_count "$fix")"
  [ "$(request_ua "$fix" 2)" = "$browser_ua" ] || fail "the second request did not carry the browser profile"
  printf '%s' "$(request_ua "$fix" 1)$(request_ua "$fix" 2)" | grep -qF "$AUTHORIZED_UA" \
    && fail "the authorized branded string was transmitted before the ladder reached it"
  pass "a positively typed client filter admits exactly one browser-compatibility retry"
}

test_third_profile_transmits_the_exact_authorized_client_string() {
  local fix
  fix=$(fixture_new branded-ok)
  fixture_reply "$fix" default 403 'Content-Type: text/html' "$FILTER_BODY"
  fixture_reply "$fix" "ua:$AUTHORIZED_UA" 200 'Content-Type: text/plain' 'branded bytes'
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state rc 0 "the authorized profile retrieved the document"
  assert_state profile AUTHORIZED_BRANDED_RETRIEVAL "the third profile is the one that answered"
  assert_state attempts 3 "exactly three profiles were attempted"
  [ "$(request_count "$fix")" = 3 ] || fail "expected exactly three requests, got $(request_count "$fix")"
  [ "$(request_ua "$fix" 3)" = "$AUTHORIZED_UA" ] \
    || fail "the third request carried '$(request_ua "$fix" 3)', not the authorized string"
  [ "$(meta_field "$fix" .profile_authorization)" = captain-authorized-exact-string ] \
    || fail "the proof does not record the final profile as a Captain authorization"
  pass "the third profile transmits the exact Captain-authorized client string"
}

test_the_ladder_stops_at_three_profiles() {
  local fix
  fix=$(fixture_new ladder-exhausted)
  fixture_reply "$fix" default 403 'Content-Type: text/html' "$FILTER_BODY"
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state rc 1 "a document that filters every profile is not retrieved"
  assert_state completeness unobserved "an exhausted ladder observes nothing about the document"
  assert_state reason client_filtered "the reason names the filtering it identified"
  assert_state attempts 3 "the ladder stopped at its third and last profile"
  [ "$(request_count "$fix")" = 3 ] || fail "expected exactly three requests, got $(request_count "$fix")"
  pass "the attempt order is closed at three profiles and stops there"
}

# The calibrated control for the exact string above. It mutates a COPY of the
# implementation so the final profile transmits something else, then runs the
# same behavioral assertion the positive case runs. That assertion must go red -
# if it stays green, it was never reading the transmitted client string and
# every "the exact UA was sent" result in this file is vacuous.
test_the_exact_client_string_assertion_is_calibrated() {
  local fix mutated seen
  fix=$(fixture_new branded-mutated)
  mutated=$TMP_ROOT/mutated-lib.sh
  sed "s|OpenAI File Downloader, XaiImageApiFetch/1.0|Some Other Downloader/9.9|" "$LIB" > "$mutated"
  grep -qF "$AUTHORIZED_UA" "$mutated" && fail "the mutation did not remove the authorized string"
  grep -qF 'Some Other Downloader/9.9' "$mutated" || fail "the mutation did not take"

  fixture_reply "$fix" default 403 'Content-Type: text/html' "$FILTER_BODY"
  fixture_reply "$fix" 'ua:Some Other Downloader/9.9' 200 'Content-Type: text/plain' 'mutated bytes'
  LIB=$mutated run_public "$fix" 'https://public.test/doc' public-content ''

  [ "$(request_count "$fix")" = 3 ] || fail "the mutated ladder did not reach its third profile"
  seen=$(request_ua "$fix" 3)
  [ "$seen" = "$AUTHORIZED_UA" ] \
    && fail "the mutated implementation still transmitted the authorized string, so this control cannot detect a change"
  [ "$seen" = 'Some Other Downloader/9.9' ] \
    || fail "the mutated implementation transmitted neither string, so the control observes nothing: got '$seen'"
  pass "changing the exact authorized client string is detected, so the positive control is calibrated"
}

# --- refusals that permit no fallback ----------------------------------------
#
# Each of these scripts the SAME positively-typed filter body that the ladder
# does move on, plus the refusal under test. If precedence were wrong, the
# filter phrase would win and the ladder would move; asserting one request is
# what proves the boundary took precedence rather than the marker list being
# narrow.

assert_no_fallback() {  # <fixture> <expected-reason> <label>
  assert_state rc 1 "$3: the document is not retrieved"
  assert_state completeness unobserved "$3: the refusal observes nothing about the document"
  assert_state reason "$2" "$3: the reason names the refusal"
  assert_state attempts 1 "$3: no second profile was attempted"
  assert_state profile NORMAL "$3: the ladder never moved"
  [ "$(request_count "$1")" = 1 ] \
    || fail "$3: expected exactly one request, got $(request_count "$1")"
  printf '%s' "$(request_ua "$1" 1)" | grep -qF "$AUTHORIZED_UA" \
    && fail "$3: the authorized branded string was transmitted"
  return 0
}

test_401_permits_no_fallback() {
  local fix
  fix=$(fixture_new deny-401)
  fixture_reply "$fix" default 401 'WWW-Authenticate: Bearer' "$FILTER_BODY"
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" access_boundary "a credential refusal"
  pass "HTTP 401 permits no fallback attempt, even carrying a client-filter phrase"
}

test_407_permits_no_fallback() {
  local fix
  fix=$(fixture_new deny-407)
  fixture_reply "$fix" default 407 'Proxy-Authenticate: Basic' "$FILTER_BODY"
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" access_boundary "a proxy credential refusal"
  pass "HTTP 407 permits no fallback attempt, even carrying a client-filter phrase"
}

test_explicit_authorization_denial_permits_no_fallback() {
  local fix
  fix=$(fixture_new deny-403-explicit)
  fixture_reply "$fix" default 403 'Content-Type: text/html' \
    '<html>You do not have permission to view this. Permission denied.</html>'
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" access_boundary "an explicit authorization denial"
  pass "an explicitly denied 403 permits no fallback attempt"
}

test_paywall_permits_no_fallback() {
  local fix
  fix=$(fixture_new deny-paywall)
  fixture_reply "$fix" default 403 'Content-Type: text/html' \
    '<html>Subscription required to read this article. automated client traffic</html>'
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" access_boundary "a paywall"
  pass "a paywall permits no fallback attempt even when the page also names automated traffic"
}

test_geographic_boundary_permits_no_fallback() {
  local fix
  fix=$(fixture_new deny-geo)
  fixture_reply "$fix" default 403 'Content-Type: text/html' \
    '<html>This content is not available in your country.</html>'
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" access_boundary "a geographic boundary"
  pass "a geographic boundary permits no fallback attempt"
}

test_session_boundary_permits_no_fallback() {
  local fix
  fix=$(fixture_new deny-session)
  fixture_reply "$fix" default 403 'Content-Type: text/html' \
    '<html>Your session expired. Please sign in to continue.</html>'
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" access_boundary "a session boundary"
  pass "a session boundary permits no fallback attempt"
}

test_challenge_is_never_answered_automatically() {
  local fix
  fix=$(fixture_new challenge)
  fixture_reply "$fix" default 403 'Content-Type: text/html' \
    '<html>Please complete the CAPTCHA below. automated client traffic detected</html>'
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" challenge_presented "a CAPTCHA challenge"
  pass "a CAPTCHA challenge is refused rather than answered with another identity"
}

test_a_challenge_wall_served_as_200_is_not_returned_as_the_document() {
  local fix
  fix=$(fixture_new challenge-200)
  fixture_reply "$fix" default 200 'Content-Type: text/html' \
    '<html><title>Just a moment</title>Checking your browser before you continue.</html>'
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_no_fallback "$fix" challenge_presented "an interstitial served as 200"
  [ ! -s "$fix/body" ] || fail "the challenge wall was published as the document"
  pass "an interstitial challenge served as 200 is refused rather than returned as content"
}

test_a_document_that_merely_discusses_captchas_is_still_retrieved() {
  local fix body
  fix=$(fixture_new captcha-article)
  body='<html>How CAPTCHA and reCAPTCHA systems work, and why hCaptcha exists.</html>'
  fixture_reply "$fix" default 200 'Content-Type: text/html' "$body"
  run_public "$fix" 'https://public.test/article' public-content ''

  assert_state rc 0 "an article about captchas is ordinary content"
  assert_state reason body_complete "the document arrived whole"
  [ "$(cat "$fix/body")" = "$body" ] \
    || fail "the article was not published, so naming a challenge is being read as being one"
  pass "a document that merely names captchas is retrieved, so the challenge test reads walls and not words"
}

test_ambiguous_403_is_could_not_observe_with_no_fallback() {
  local fix
  fix=$(fixture_new ambiguous)
  fixture_reply "$fix" default 403 'Content-Type: text/html' "$SILENT_BODY"
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" ambiguous_refusal "an unexplained 403"
  pass "a 403 that identifies nothing is could-not-observe and moves nothing"
}

test_tls_failure_is_never_retried_insecurely() {
  local fix
  fix=$(fixture_new tls)
  fixture_fail "$fix" default 60
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_no_fallback "$fix" tls_failed "a certificate failure"
  pass "a TLS failure stops the retrieval and is never retried insecurely"
}

# The non-vacuity control for every case above: the same fixture shape, with the
# boundary removed, DOES move the ladder. Without this, "one request" would be
# satisfied by an implementation that never falls back at all.
test_the_no_fallback_assertion_is_not_vacuous() {
  local fix
  fix=$(fixture_new no-fallback-calibration)
  fixture_reply "$fix" default 403 'Content-Type: text/html' "$FILTER_BODY"
  run_public "$fix" 'https://public.test/doc' public-content ''
  [ "$(request_count "$fix")" -gt 1 ] \
    || fail "the same fixture shape without a boundary made only one request, so the no-fallback cases prove nothing"
  assert_state attempts 3 "the unbounded filter case climbs the whole ladder"
  pass "the same fixture shape does climb the ladder once the boundary is removed"
}

# --- rate limiting, bounds, and cross-origin material ------------------------

test_429_retries_within_a_bound_without_moving_the_profile() {
  local fix i
  fix=$(fixture_new rate-then-ok)
  fixture_reply "$fix" default 429 'Retry-After: 1' 'slow down'
  fixture_reply "$fix" 'url:https://public.test/doc?ok=1' 200 'Content-Type: text/plain' 'rate limited then fine'
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state rc 1 "a document that never stops rate-limiting is not retrieved"
  assert_state reason rate_limited "the reason names the rate refusal"
  assert_state profile NORMAL "rate limiting never moves the profile"
  assert_state attempts 1 "rate limiting is absorbed inside one profile attempt"
  [ "$(request_count "$fix")" = 3 ] \
    || fail "expected the first attempt plus its two bounded retries, got $(request_count "$fix")"
  i=1
  while [ "$i" -le "$(request_count "$fix")" ]; do
    [ "$(request_ua "$fix" "$i")" = "$(request_ua "$fix" 1)" ] \
      || fail "request $i changed the client string during rate-limit backoff"
    i=$((i + 1))
  done
  [ "$(wc -l < "$fix/sleeps" | tr -d ' ')" = 2 ] \
    || fail "expected two bounded waits between the three requests, got: $(cat "$fix/sleeps")"
  while IFS= read -r i; do
    [ "$i" = 1 ] || fail "a wait of '$i' did not honor the source's Retry-After of 1"
  done < "$fix/sleeps"
  pass "429 retries within a bound, honors Retry-After, and never moves the client string"
}

test_a_retry_after_beyond_the_bound_stops_rather_than_ignoring_it() {
  local fix
  fix=$(fixture_new rate-long)
  fixture_reply "$fix" default 429 'Retry-After: 600' 'come back much later'
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state rc 1 "a long rate refusal is not retrieved"
  assert_state reason rate_limited "the reason names the rate refusal"
  [ "$(request_count "$fix")" = 1 ] \
    || fail "a Retry-After beyond the bound was retried anyway: $(request_count "$fix") requests"
  printf '%s' "$(state detail)" | grep -q '600' \
    || fail "the refusal does not record the delay the source actually asked for"
  pass "a Retry-After beyond this reader's bound stops instead of asking again too early"
}

test_a_body_over_the_byte_bound_is_not_a_partial_success() {
  local fix
  fix=$(fixture_new too-large)
  fixture_fail "$fix" default 63
  run_public "$fix" 'https://public.test/big' public-content ''

  assert_state rc 1 "a body over the byte bound is not a success"
  assert_state completeness incomplete "the byte bound leaves the document incomplete"
  assert_state reason byte_bound_reached "the reason names the byte bound"
  [ ! -s "$fix/body" ] || fail "a prefix of the document was published as the document"
  [ "$(meta_field "$fix" .body_published)" = false ] \
    || fail "the proof claims bytes were published when none were"
  assert_state 'supports:content-retrieved' no "a truncated body retrieves nothing"
  pass "a body over the byte bound publishes no partial content and is never a pass"
}

# The transport-side cap is not the only thing that can miss an oversized body:
# a response that declares no length can outrun it. This case has the transport
# report success and hand back more bytes than the bound allows.
test_an_oversized_body_the_transport_allowed_is_still_not_a_success() {
  local fix
  fix=$(fixture_new too-large-silently)
  fixture_reply "$fix" default 200 'Content-Type: text/plain' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  run_public "$fix" 'https://public.test/big' public-content '' \
    FM_RETRIEVAL_PUBLIC_MAX_BYTES=16

  assert_state rc 1 "a body past the bound is not a success however it got through"
  assert_state completeness incomplete "the byte bound leaves the document incomplete"
  assert_state reason byte_bound_reached "the reason names the byte bound"
  [ ! -s "$fix/body" ] || fail "a prefix of the document was published as the document"
  assert_state 'supports:content-retrieved' no "an oversized body retrieves nothing"
  pass "an oversized body the transport allowed through is still refused, with no partial content"
}

test_the_oversized_body_control_is_not_vacuous() {
  local fix
  fix=$(fixture_new too-large-calibration)
  fixture_reply "$fix" default 200 'Content-Type: text/plain' 'small enough'
  run_public "$fix" 'https://public.test/small' public-content '' \
    FM_RETRIEVAL_PUBLIC_MAX_BYTES=16

  assert_state rc 0 "the same bound admits a body that fits"
  [ "$(cat "$fix/body")" = 'small enough' ] || fail "the fitting body was not published"
  pass "the same byte bound admits a body that fits, so the refusal tracks size and not the bound's presence"
}

test_a_body_over_the_time_bound_is_not_a_partial_success() {
  local fix
  fix=$(fixture_new timeout)
  fixture_fail "$fix" default 28
  run_public "$fix" 'https://public.test/slow' public-content ''

  assert_state rc 1 "a body over the time bound is not a success"
  assert_state completeness unobserved "a timeout observes nothing about the document"
  assert_state reason time_bound_reached "the reason names the time bound"
  [ ! -s "$fix/body" ] || fail "a prefix of the document was published as the document"
  pass "a retrieval over the wall-clock bound publishes nothing and is never a pass"
}

test_a_malformed_response_is_could_not_observe() {
  local fix
  fix=$(fixture_new malformed)
  fixture_fail "$fix" default 3
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state rc 1 "an unclassifiable response is not a success"
  assert_state completeness unobserved "an unclassifiable response observes nothing"
  assert_state reason malformed_response "the reason names the malformed response"
  pass "a response this reader cannot classify is could-not-observe, never an empty document"
}

test_a_cross_origin_redirect_strips_authorization_and_cookie_material() {
  local fix headers first second
  fix=$(fixture_new redirect-strip)
  headers=$TMP_ROOT/redirect-strip-headers
  printf 'Authorization: Bearer secret-token\nCookie: session=secret-session\nAccept: text/plain\n' > "$headers"
  fixture_reply "$fix" 'url:https://origin-a.test/doc' 302 'Location: https://origin-b.test/doc' ''
  fixture_reply "$fix" 'url:https://origin-b.test/doc' 200 'Content-Type: text/plain' 'other origin bytes'
  run_public "$fix" 'https://origin-a.test/doc' public-content "$headers"

  assert_state rc 0 "the redirected document is retrieved"
  assert_state stripped 1 "the strip is recorded"
  assert_state final_origin 'https://origin-b.test:443' "the final origin is recorded exactly"
  first=$(request_headers "$fix" 1)
  second=$(request_headers "$fix" 2)
  printf '%s' "$first" | grep -q 'secret-token' \
    || fail "the first request did not carry the material, so this control proves nothing"
  printf '%s' "$second" | grep -q 'secret-token' \
    && fail "the authorization material crossed the origin boundary"
  printf '%s' "$second" | grep -q 'secret-session' \
    && fail "the cookie material crossed the origin boundary"
  printf '%s' "$second" | grep -q 'Accept: text/plain' \
    || fail "stripping removed a header that is not sensitive material"
  [ "$(meta_field "$fix" .sensitive_stripped)" = true ] \
    || fail "the proof does not record that material was stripped"
  pass "a cross-origin redirect strips authorization and cookie material before transmitting"
}

test_a_cross_origin_redirect_can_be_refused_instead_of_stripped() {
  local fix headers
  fix=$(fixture_new redirect-refuse)
  headers=$TMP_ROOT/redirect-refuse-headers
  printf 'Authorization: Bearer secret-token\n' > "$headers"
  fixture_reply "$fix" 'url:https://origin-a.test/doc' 302 'Location: https://origin-b.test/doc' ''
  fixture_reply "$fix" 'url:https://origin-b.test/doc' 200 'Content-Type: text/plain' 'other origin bytes'
  run_public "$fix" 'https://origin-a.test/doc' public-content "$headers" \
    FM_RETRIEVAL_PUBLIC_SENSITIVE=refuse

  assert_state rc 1 "the refused redirect is not retrieved"
  assert_state reason redirect_refused "the reason names the refused redirect"
  [ "$(request_count "$fix")" = 1 ] \
    || fail "the second origin was contacted anyway: $(request_count "$fix") requests"
  pass "a caller may have cross-origin material refused rather than stripped"
}

test_a_same_origin_redirect_keeps_the_material() {
  local fix second
  fix=$(fixture_new redirect-same-origin)
  local headers=$TMP_ROOT/redirect-same-headers
  printf 'Authorization: Bearer secret-token\n' > "$headers"
  fixture_reply "$fix" 'url:https://origin-a.test/doc' 302 'Location: /moved' ''
  fixture_reply "$fix" 'url:https://origin-a.test/moved' 200 'Content-Type: text/plain' 'same origin bytes'
  run_public "$fix" 'https://origin-a.test/doc' public-content "$headers"

  assert_state rc 0 "the same-origin redirect is followed"
  assert_state stripped 0 "nothing was stripped on a same-origin hop"
  second=$(request_headers "$fix" 2)
  printf '%s' "$second" | grep -q 'secret-token' \
    || fail "material was stripped on a same-origin hop, so the cross-origin control is not about origins"
  pass "a same-origin redirect keeps the material, so the strip tracks the origin and not the redirect"
}

test_a_protocol_downgrading_redirect_is_refused() {
  local fix
  fix=$(fixture_new redirect-downgrade)
  fixture_reply "$fix" 'url:https://origin-a.test/doc' 302 'Location: http://origin-b.test/doc' ''
  fixture_reply "$fix" 'url:http://origin-b.test/doc' 200 'Content-Type: text/plain' 'downgraded bytes'
  run_public "$fix" 'https://origin-a.test/doc' public-content ''

  assert_state rc 1 "a downgrading redirect is not retrieved"
  assert_state reason redirect_refused "the reason names the refused redirect"
  [ "$(request_count "$fix")" = 1 ] \
    || fail "the downgraded origin was contacted anyway: $(request_count "$fix") requests"
  pass "a redirect that drops TLS across origins is refused rather than followed"
}

# --- what a result may be credited with --------------------------------------

test_a_fallback_success_cannot_be_credited_to_a_default_client_verifier() {
  local fix cannot
  fix=$(fixture_new subject-mismatch)
  fixture_reply "$fix" default 403 'Content-Type: text/html' "$FILTER_BODY"
  fixture_reply "$fix" "ua:$AUTHORIZED_UA" 200 'Content-Type: text/plain' 'branded bytes'
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state rc 0 "the document was retrieved under the authorized profile"
  assert_state 'supports:content-retrieved' yes "the bytes really were retrieved"
  assert_state 'supports:default-client-compatible' no \
    "a fallback success is not evidence about a default client"
  assert_state 'supports:normal-client-accessible' no \
    "a fallback success is not evidence about normal accessibility"
  assert_state 'supports:authenticated-api-correct' no \
    "a public body is not evidence about an authenticated API"
  assert_state 'supports:no-bot-filtering' no \
    "a fallback success is evidence that filtering exists, not that it does not"
  cannot=$(meta_field "$fix" '.cannot_establish | join(",")')
  printf '%s' "$cannot" | grep -q 'default-client-compatible' \
    || fail "the durable proof does not carry the refusal the in-process fold makes: $cannot"
  printf '%s' "$cannot" | grep -q 'no-bot-filtering' \
    || fail "the durable proof does not refuse the bot-filtering claim: $cannot"
  pass "a fallback success refuses every claim only a default-client success could support"
}

test_a_normal_success_can_support_the_default_client_claims() {
  local fix
  fix=$(fixture_new subject-match)
  fixture_reply "$fix" default 200 'Content-Type: text/plain' 'ordinary bytes'
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state 'supports:content-retrieved' yes "the bytes were retrieved"
  assert_state 'supports:default-client-compatible' yes \
    "an ordinary success is evidence about a default client"
  assert_state 'supports:normal-client-accessible' yes \
    "an ordinary success is evidence about normal accessibility"
  assert_state 'supports:no-bot-filtering' yes \
    "an ordinary success with no filtering observed supports the claim"
  assert_state 'supports:authenticated-api-correct' no \
    "no public body is ever evidence about an authenticated API"
  [ "$(meta_field "$fix" '.cannot_establish | length')" = 1 ] \
    || fail "an ordinary success should refuse exactly the authenticated-API claim"
  pass "an ordinary success does support the default-client claims, so the refusal is not blanket"
}

# --- excluded callers ---------------------------------------------------------

test_an_excluded_caller_cannot_enter_the_fallback_ladder() {
  local fix context
  for context in authenticated-api provider-api installer auth security \
    client-compatibility behavior-test application-test; do
    fix=$(fixture_new "excluded-$context")
    fixture_reply "$fix" default 403 'Content-Type: text/html' "$FILTER_BODY"
    fixture_reply "$fix" "ua:$AUTHORIZED_UA" 200 'Content-Type: text/plain' 'branded bytes'
    run_public "$fix" 'https://public.test/doc' "$context" ''

    assert_state rc 1 "$context: an excluded caller does not reach the document"
    assert_state attempts 1 "$context: no second profile was attempted"
    assert_state profile NORMAL "$context: the ladder never moved"
    assert_state blocked "context:$context" "$context: the structural refusal is recorded"
    [ "$(request_count "$fix")" = 1 ] \
      || fail "$context: expected exactly one request, got $(request_count "$fix")"
    printf '%s' "$(request_ua "$fix" 1)" | grep -qF "$AUTHORIZED_UA" \
      && fail "$context: the authorized branded string was transmitted"
  done
  pass "every excluded caller context is structurally capped at the ordinary client identity"
}

test_the_excluded_caller_control_is_not_vacuous() {
  local fix
  fix=$(fixture_new excluded-calibration)
  fixture_reply "$fix" default 403 'Content-Type: text/html' "$FILTER_BODY"
  fixture_reply "$fix" "ua:$AUTHORIZED_UA" 200 'Content-Type: text/plain' 'branded bytes'
  run_public "$fix" 'https://public.test/doc' public-content ''

  assert_state rc 0 "the identical fixture is retrieved for a public-content caller"
  assert_state attempts 3 "the public-content caller climbs the whole ladder"
  [ "$(request_ua "$fix" 3)" = "$AUTHORIZED_UA" ] \
    || fail "the calibration run did not transmit the branded string, so the excluded cases prove nothing"
  pass "the identical fixture does reach the branded profile for a permitted caller"
}

test_an_unknown_caller_context_is_refused_rather_than_defaulted() {
  local fix
  fix=$(fixture_new unknown-context)
  fixture_reply "$fix" default 200 'Content-Type: text/plain' 'bytes'
  run_public "$fix" 'https://public.test/doc' not-a-declared-context ''

  assert_state rc 1 "an unknown context does not retrieve anything"
  assert_state reason usage_error "an unknown context is a usage error"
  [ "$(request_count "$fix")" = 0 ] \
    || fail "an unknown context reached the network anyway: $(request_count "$fix") requests"
  pass "an unrecognized caller context is refused instead of quietly permitted"
}

# --- provenance ---------------------------------------------------------------

test_a_complete_retrieval_publishes_exact_bytes_and_their_proof() {
  local fix body digest
  fix=$(fixture_new provenance)
  body='exact public document bytes'
  fixture_reply "$fix" default 200 'Content-Type: text/plain' "$body"
  run_public "$fix" 'https://public.test/a/doc.txt' public-content ''

  assert_state rc 0 "the document was retrieved"
  [ "$(cat "$fix/body")" = "$body" ] || fail "the published bytes are not the served bytes"
  digest=$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)
  [ "$(meta_field "$fix" .body_digest)" = "sha256:$digest" ] \
    || fail "the proof's digest does not bind the published bytes"
  [ "$(meta_field "$fix" .schema)" = fm-retrieval-public.v1 ] || fail "wrong proof schema"
  [ "$(meta_field "$fix" .retrieval)" = complete ] || fail "the proof does not record completeness"
  [ "$(meta_field "$fix" .profile)" = NORMAL ] || fail "the proof does not record the profile"
  [ "$(meta_field "$fix" .attempts)" = 1 ] || fail "the proof does not record the attempt count"
  [ "$(meta_field "$fix" .requests)" = 1 ] || fail "the proof does not record the request count"
  [ "$(meta_field "$fix" .status)" = 200 ] || fail "the proof does not record the status"
  [ "$(meta_field "$fix" .requested_url)" = 'https://public.test/a/doc.txt' ] \
    || fail "the proof does not record the requested URL"
  [ "$(meta_field "$fix" .final_url)" = 'https://public.test/a/doc.txt' ] \
    || fail "the proof does not record the final URL"
  [ "$(meta_field "$fix" .final_origin)" = 'https://public.test:443' ] \
    || fail "the proof does not record the final origin"
  [ "$(meta_field "$fix" .bytes)" = "${#body}" ] || fail "the proof does not record the byte count"
  [ "$(meta_field "$fix" .body_published)" = true ] || fail "the proof does not record publication"
  pass "a complete retrieval publishes the exact bytes with a proof binding every recorded fact"
}

test_a_published_body_is_readable_only_with_its_proof() {
  local fix rc=0
  fix=$(fixture_new proof-required)
  fixture_reply "$fix" default 200 'Content-Type: text/plain' 'bytes'
  run_public "$fix" 'https://public.test/doc' public-content ''
  assert_state rc 0 "the document was retrieved"
  [ -f "$fix/body.meta" ] || fail "no proof was published beside the body"
  rm -f "$fix/body.meta"
  FM_TEST_LIB="$LIB" FM_TEST_BODY="$fix/body" bash -c '
    set -u
    . "$FM_TEST_LIB"
    fm_retrieval_load "$FM_TEST_BODY"
  ' >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "a body with no proof was adopted as a committed result"
  pass "a published body with no proof beside it is refused rather than adopted"
}

test_an_absent_transport_is_could_not_observe_not_a_refusal() {
  local fix out rc=0
  fix=$(fixture_new no-transport)
  fixture_reply "$fix" default 200 'Content-Type: text/plain' 'bytes'
  out=$(FM_TEST_LIB="$LIB" FM_TEST_OUT="$fix/body" bash -c '
    set -u
    . "$FM_TEST_LIB"
    FM_RETRIEVAL_PUBLIC_CURL=fm-no-such-transport
    fm_retrieval_public_fetch "https://public.test/doc" "$FM_TEST_OUT" public-content "" || true
    printf "completeness=%s
reason=%s
"       "$FM_RETRIEVAL_COMPLETENESS" "$FM_RETRIEVAL_REASON"
  ' 2>&1) || rc=$?
  expect_code 0 "$rc" "the entrypoint returned a readable result: $out"
  printf '%s' "$out" | grep -q 'completeness=unobserved'     || fail "an absent transport was not could-not-observe: $out"
  printf '%s' "$out" | grep -q 'reason=transport_unavailable'     || fail "an absent transport did not name the unrunnable reader: $out"
  pass "an absent transport is an unrunnable reader, never a refusal by the source"
}

# --- the authenticated collection path is untouched --------------------------

test_the_collection_path_still_refuses_a_negative_over_a_bounded_read() {
  local rc=0 out
  out=$(FM_TEST_LIB="$LIB" bash -c '
    set -u
    . "$FM_TEST_LIB"
    fm_retrieval_reset
    fm_retrieval_set_reason page_bound_reached "bounded"
    fm_retrieval_conclude absent
    printf "%s %s\n" "$FM_RETRIEVAL_COMPLETENESS" "$FM_RETRIEVAL_CONCLUSION"
  ') || rc=$?
  expect_code 0 "$rc" "the collection algebra still runs"
  [ "$out" = 'incomplete INDETERMINATE' ] \
    || fail "the collection conclusion algebra changed: got '$out'"
  pass "adding a public-content transport left the collection conclusion algebra intact"
}

test_every_public_reason_maps_to_exactly_one_completeness_value() {
  local out reason expected line
  out=$(FM_TEST_LIB="$LIB" bash -c '
    set -u
    . "$FM_TEST_LIB"
    for r in body_complete byte_bound_reached access_boundary challenge_presented \
      ambiguous_refusal redirect_refused client_filtered tls_failed \
      time_bound_reached malformed_response; do
      printf "%s %s\n" "$r" "$(fm_retrieval_completeness_of "$r" || printf UNMAPPED)"
    done
  ') || fail "the reason mapping could not be read"
  while IFS= read -r line; do
    reason=${line%% *}
    expected=${line#* }
    case "$reason" in
      body_complete) [ "$expected" = complete ] ;;
      byte_bound_reached) [ "$expected" = incomplete ] ;;
      *) [ "$expected" = unobserved ] ;;
    esac || fail "$reason maps to '$expected', which is not the value its meaning requires"
  done <<< "$out"
  pass "every public-content reason maps to exactly one completeness value in the shared owner"
}

run() {  # <test-name>
  "$1"
  FM_TEST_PASSED_TESTS="$FM_TEST_PASSED_TESTS
$1"
}

run test_normal_success_costs_exactly_one_request
run test_positively_typed_filter_admits_one_browser_retry
run test_third_profile_transmits_the_exact_authorized_client_string
run test_the_ladder_stops_at_three_profiles
run test_the_exact_client_string_assertion_is_calibrated
run test_401_permits_no_fallback
run test_407_permits_no_fallback
run test_explicit_authorization_denial_permits_no_fallback
run test_paywall_permits_no_fallback
run test_geographic_boundary_permits_no_fallback
run test_session_boundary_permits_no_fallback
run test_challenge_is_never_answered_automatically
run test_a_challenge_wall_served_as_200_is_not_returned_as_the_document
run test_a_document_that_merely_discusses_captchas_is_still_retrieved
run test_ambiguous_403_is_could_not_observe_with_no_fallback
run test_tls_failure_is_never_retried_insecurely
run test_the_no_fallback_assertion_is_not_vacuous
run test_429_retries_within_a_bound_without_moving_the_profile
run test_a_retry_after_beyond_the_bound_stops_rather_than_ignoring_it
run test_a_body_over_the_byte_bound_is_not_a_partial_success
run test_an_oversized_body_the_transport_allowed_is_still_not_a_success
run test_the_oversized_body_control_is_not_vacuous
run test_a_body_over_the_time_bound_is_not_a_partial_success
run test_a_malformed_response_is_could_not_observe
run test_a_cross_origin_redirect_strips_authorization_and_cookie_material
run test_a_cross_origin_redirect_can_be_refused_instead_of_stripped
run test_a_same_origin_redirect_keeps_the_material
run test_a_protocol_downgrading_redirect_is_refused
run test_a_fallback_success_cannot_be_credited_to_a_default_client_verifier
run test_a_normal_success_can_support_the_default_client_claims
run test_an_excluded_caller_cannot_enter_the_fallback_ladder
run test_the_excluded_caller_control_is_not_vacuous
run test_an_unknown_caller_context_is_refused_rather_than_defaulted
run test_a_complete_retrieval_publishes_exact_bytes_and_their_proof
run test_a_published_body_is_readable_only_with_its_proof
run test_an_absent_transport_is_could_not_observe_not_a_refusal
run test_the_collection_path_still_refuses_a_negative_over_a_bounded_read
run test_every_public_reason_maps_to_exactly_one_completeness_value

fm_test_contract "$0"
