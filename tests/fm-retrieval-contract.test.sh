#!/usr/bin/env bash
# The control-plane retrieval contract: bin/fm-control-read.sh and its helper
# bin/fm-retrieval-lib.sh must never let a negative conclusion rest on a
# partially-enumerated source.
#
# Every case here is written so that the assertion fails if completeness is
# assumed rather than established. No case may accept "no match" as an answer
# unless the record it reads also proves the whole candidate universe was
# enumerated, which is why each negative case asserts retrieval= as well as the
# conclusion.
#
# The fixture serves real HTTP-shaped pages through a fake `gh` on PATH, because
# the traversal under test is Link-header continuation and a stub that answered
# in some other shape would only confirm the stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READ="$ROOT/bin/fm-control-read.sh"
LIB="$ROOT/bin/fm-retrieval-lib.sh"
CHECK="$ROOT/bin/fm-retrieval-check.sh"
VERIFY="$ROOT/bin/fm-verify.sh"

TMP_ROOT=$(fm_test_tmproot fm-retrieval) || fail "could not create a temp root"

# --- fixture ----------------------------------------------------------------
#
# fixture_new <name> creates a page-serving root and echoes it. Pages are added
# with fixture_page, which takes the page number, the value of the next-page
# continuation ("-" for none), the HTTP status, and the JSON array body.
#
# The fake gh resolves a request to a page by the fm_page=<n> query parameter it
# puts in every continuation URL it hands out, so the traversal has to follow the
# continuation rather than guess page numbers: a reader that incremented page=
# itself would ask for a URL this fixture never published.

fixture_new() {  # <name>
  local root="$TMP_ROOT/fix-$1"
  mkdir -p "$root/pages" || return 1
  printf '%s' "$root"
}

fixture_page() {  # <root> <n> <next|-> <status> <body>
  local root=$1 n=$2 next=$3 status=$4 body=$5
  printf '%s' "$status" > "$root/pages/$n.status"
  printf '%s' "$next" > "$root/pages/$n.next"
  printf '%s' "$body" > "$root/pages/$n.body"
}

# Every attempt the fake serves is appended to <root>/requests, so a test can
# assert the traversal followed the continuation and how many attempts a page
# cost.
install_fake_gh() {  # <fixture-root>
  local fixture=$1 fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
# Fake gh serving the fixture at $fixture. Only 'api -i <url>' is answered.
set -u
FIX='$fixture'
SH
  cat >> "$fakebin/gh" <<'SH'
url=
want_headers=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    api) shift ;;
    -i|--include) want_headers=1; shift ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ "$want_headers" = 1 ] || { printf 'fake gh: -i is required\n' >&2; exit 64; }
page=$(printf '%s' "$url" | sed -n 's/.*[?&]fm_page=\([0-9]*\).*/\1/p')
[ -n "$page" ] || page=1
printf '%s\t%s\n' "$page" "$url" >> "$FIX/requests"
[ -f "$FIX/pages/$page.status" ] || { printf 'fake gh: no such page %s\n' "$page" >&2; exit 1; }
status=$(cat "$FIX/pages/$page.status")
# A page may be scripted to fail a bounded number of attempts and then succeed:
# <n>.failures holds the remaining scripted failures.
if [ -f "$FIX/pages/$page.failures" ]; then
  remaining=$(cat "$FIX/pages/$page.failures")
  if [ "$remaining" -gt 0 ]; then
    printf '%s' "$((remaining - 1))" > "$FIX/pages/$page.failures"
    status=$(cat "$FIX/pages/$page.failstatus" 2>/dev/null || printf '500')
  fi
fi
if [ "$status" != 200 ]; then
  printf 'HTTP/2.0 %s SCRIPTED\r\n' "$status"
  printf 'Content-Type: application/json\r\n'
  printf '\r\n'
  printf '{"message":"scripted %s"}\n' "$status"
  exit 1
fi
next=$(cat "$FIX/pages/$page.next")
printf 'HTTP/2.0 200 OK\r\n'
printf 'Content-Type: application/json; charset=utf-8\r\n'
if [ "$next" != "-" ]; then
  printf 'Link: <https://api.github.com/fixture?fm_page=%s>; rel="next", <https://api.github.com/fixture?fm_page=9>; rel="last"\r\n' "$next"
fi
printf '\r\n'
cat "$FIX/pages/$page.body"
SH
  chmod +x "$fakebin/gh"
  printf '%s' "$fakebin"
}

# One comment object. The body is JSON-escaped by jq so a test can write real
# newlines and quoted-reply prose into it.
comment() {  # <id> <created_at> <body>
  jq -cn --arg id "$1" --arg at "$2" --arg body "$3" \
    '{id: ($id|tonumber), created_at: $at, body: $body,
      html_url: ("https://github.test/c/" + $id)}'
}

page_body() {  # <comment-json>...
  local out='' c
  for c in "$@"; do
    [ -z "$out" ] && out=$c || out="$out,$c"
  done
  printf '[%s]' "$out"
}

# Run the contract against a fixture and leave the record in RECORD, the exit
# status in RC.
RECORD=
RC=0
run_read() {  # <fixture-root> <args...>
  local fixture=$1 fakebin
  shift
  fakebin=$(install_fake_gh "$fixture")
  RECORD=$(PATH="$fakebin:$PATH" FM_RETRIEVAL_SLEEP=: \
    "$READ" endpoint 'fixture?fm_page=1' "$@" 2>&1)
  RC=$?
  return 0
}

# One field of the emitted record, by column name.
field() {  # <record> <name>
  printf '%s\n' "$1" | awk -v want="$2" '
    /^[a-z_]+\[1\]\{/ {
      hdr = $0
      sub(/^[a-z_]+\[1\]\{/, "", hdr)
      sub(/\}:.*$/, "", hdr)
      n = split(hdr, names, ",")
      next
    }
    /^  / && n > 0 {
      row = $0
      sub(/^  /, "", row)
      m = split(row, vals, ",")
      for (i = 1; i <= n; i++) if (names[i] == want) { print (i <= m ? vals[i] : ""); exit }
    }'
}

assert_field() {  # <record> <name> <expected> <label>
  local got
  got=$(field "$1" "$2")
  [ "$got" = "$3" ] || fail "$4: expected $2=$3, got '$got' in record: $1"
}

fixture_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

rebind_records() {  # <records-file>
  local records=$1 staged=$1.meta.staged digest
  digest=$(fixture_sha256 "$records")
  jq --arg digest "sha256:$digest" '.record_digest = $digest' \
    "$records.meta" > "$staged"
  mv "$staged" "$records.meta"
}

# --- controls ---------------------------------------------------------------

# The defect's exact shape: the applicable ruling is not on page one. A reader
# that stops at the first page reports a clean negative here.
test_applicable_ruling_only_on_page_two() {
  local fix
  fix=$(fixture_new p2)
  fixture_page "$fix" 1 2 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'unrelated chatter')" \
    "$(comment 12 2026-08-02T00:00:00Z 'still nothing to do with it')")"
  fixture_page "$fix" 2 - 200 "$(page_body \
    "$(comment 21 2026-08-03T00:00:00Z 'APPROVE req-7 ship it')")"
  run_read "$fix" --identity req-7 --applicable 'APPROVE|REJECT' --claim exists
  assert_field "$RECORD" conclusion PRESENT "ruling on page two"
  assert_field "$RECORD" retrieval complete "ruling on page two"
  assert_field "$RECORD" matches 1 "ruling on page two"
  assert_field "$RECORD" pages 2 "ruling on page two"
  expect_code 0 "$RC" "a ruling found on page two is PRESENT"
  pass "an applicable ruling only on page two is found, not reported absent"
}

# Page one carries the OLDEST records, which is why "read the newest comment"
# and "scan by timestamp" both failed against a first-page-only read.
test_oldest_record_is_on_page_one() {
  local fix
  fix=$(fixture_new oldest)
  fixture_page "$fix" 1 2 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7 first word')")"
  fixture_page "$fix" 2 3 200 "$(page_body \
    "$(comment 21 2026-08-05T00:00:00Z 'unrelated')")"
  fixture_page "$fix" 3 - 200 "$(page_body \
    "$(comment 31 2026-08-09T00:00:00Z 'APPROVE req-7 final word')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim latest
  assert_field "$RECORD" conclusion PRESENT "oldest on page one"
  assert_field "$RECORD" retrieval complete "oldest on page one"
  assert_field "$RECORD" selected 31 "oldest on page one"
  assert_field "$RECORD" matches 2 "oldest on page one"
  pass "the newest applicable record wins even though page one holds the oldest"
}

# A first page that already carries an applicable ruling is the trap: the read
# looks successful and stops, and the superseding ruling is never seen.
test_page_one_ruling_superseded_later() {
  local fix
  fix=$(fixture_new supersede)
  fixture_page "$fix" 1 2 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'REJECT req-7 not yet')")"
  fixture_page "$fix" 2 - 200 "$(page_body \
    "$(comment 21 2026-08-06T00:00:00Z 'APPROVE req-7 superseding the earlier call')")"
  run_read "$fix" --identity req-7 --applicable 'APPROVE|REJECT' --claim latest
  assert_field "$RECORD" selected 21 "superseded ruling"
  assert_field "$RECORD" retrieval complete "superseded ruling"
  pass "a page-one ruling superseded on a later page does not win"
}

# An extremal claim ranges over the whole universe, so it must refuse even when
# it already holds a match. This is the case a positive-survives-incompleteness
# rule would get wrong.
test_latest_refuses_when_retrieval_is_bounded_out() {
  local fix
  fix=$(fixture_new latestbound)
  fixture_page "$fix" 1 2 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7 possibly obsolete')")"
  fixture_page "$fix" 2 3 200 "$(page_body "$(comment 21 2026-08-02T00:00:00Z x)")"
  fixture_page "$fix" 3 - 200 "$(page_body "$(comment 31 2026-08-03T00:00:00Z y)")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim latest --max-pages 1
  assert_field "$RECORD" conclusion INDETERMINATE "latest under a page bound"
  assert_field "$RECORD" retrieval incomplete "latest under a page bound"
  assert_field "$RECORD" reason page_bound_reached "latest under a page bound"
  expect_code 2 "$RC" "an extremal claim over an unenumerated universe is undecidable"
  # ... while the weaker existence claim over the same bounded read still
  # answers, because a record actually read exists whatever remains unread.
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists --max-pages 1
  assert_field "$RECORD" conclusion PRESENT "exists under a page bound"
  assert_field "$RECORD" retrieval incomplete "exists under a page bound"
  expect_code 0 "$RC" "an existence claim survives an unenumerated tail"
  pass "latest refuses a bounded-out read while exists still answers"
}

# Traversal stopped at its own bound with the source still offering more. The
# universe was not enumerated, so no negative may be drawn from it.
test_pagination_stopping_early_refuses_a_negative() {
  local fix
  fix=$(fixture_new early)
  fixture_page "$fix" 1 2 200 "$(page_body "$(comment 11 2026-08-01T00:00:00Z 'nothing')")"
  fixture_page "$fix" 2 3 200 "$(page_body "$(comment 21 2026-08-02T00:00:00Z 'nothing')")"
  fixture_page "$fix" 3 - 200 "$(page_body "$(comment 31 2026-08-03T00:00:00Z 'nothing')")"
  run_read "$fix" --identity req-7 --claim exists --max-pages 2
  assert_field "$RECORD" conclusion INDETERMINATE "early stop"
  assert_field "$RECORD" retrieval incomplete "early stop"
  assert_field "$RECORD" reason page_bound_reached "early stop"
  expect_code 2 "$RC" "a bounded-out traversal cannot report absence"
  pass "pagination that stops early refuses the negative instead of reporting absence"
}

# One page unreadable after its bounded retries. Two records were read, so the
# read is not empty; what is missing is the proof that nothing else exists.
test_unreadable_page_refuses_a_negative() {
  local fix
  fix=$(fixture_new unreadable)
  fixture_page "$fix" 1 2 200 "$(page_body "$(comment 11 2026-08-01T00:00:00Z 'nothing')")"
  fixture_page "$fix" 2 - 500 "$(page_body)"
  run_read "$fix" --identity req-7 --claim exists
  assert_field "$RECORD" conclusion INDETERMINATE "unreadable page"
  assert_field "$RECORD" retrieval unobserved "unreadable page"
  assert_field "$RECORD" reason page_unreadable "unreadable page"
  assert_field "$RECORD" records 1 "unreadable page"
  expect_code 2 "$RC" "an unreadable page is could-not-observe, never absence"
  pass "a page that cannot be read refuses the negative and still reports what it read"
}

# A record inserted while paging shifts the window and re-serves an earlier
# record. Immutable remote identity is what makes that harmless.
test_duplicate_identifiers_across_pages() {
  local fix dup
  fix=$(fixture_new dup)
  dup=$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7 the only ruling')
  fixture_page "$fix" 1 2 200 "$(page_body "$dup" "$(comment 12 2026-08-02T00:00:00Z 'x')")"
  fixture_page "$fix" 2 - 200 "$(page_body "$dup" "$(comment 13 2026-08-03T00:00:00Z 'y')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim latest
  assert_field "$RECORD" records 3 "duplicate ids"
  assert_field "$RECORD" duplicates 1 "duplicate ids"
  assert_field "$RECORD" matches 1 "duplicate ids"
  assert_field "$RECORD" retrieval complete "duplicate ids"
  pass "a record re-served across a page boundary is counted once, not twice"
}

# Later traffic is not a later ruling. The applicability filter, not recency
# alone, decides what the extremal claim ranges over.
test_irrelevant_later_comment_does_not_displace_the_ruling() {
  local fix
  fix=$(fixture_new irrelevant)
  fixture_page "$fix" 1 2 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7 ship it')")"
  fixture_page "$fix" 2 - 200 "$(page_body \
    "$(comment 21 2026-08-08T00:00:00Z 'thanks, will do')" \
    "$(comment 22 2026-08-09T00:00:00Z 'unrelated req-7 chatter with no verdict')")"
  run_read "$fix" --identity req-7 --applicable 'APPROVE|REJECT' --claim latest
  assert_field "$RECORD" selected 11 "irrelevant later comment"
  assert_field "$RECORD" matches 1 "irrelevant later comment"
  assert_field "$RECORD" candidates 3 "irrelevant later comment"
  pass "an irrelevant later comment does not displace the applicable ruling"
}

# Quoting an identifier is a reference to another record, not an occurrence in
# this one. Counting it would attribute someone else's subject to this comment.
test_identity_only_in_quoted_prose_is_not_a_match() {
  local fix body
  fix=$(fixture_new quoted)
  body='> APPROVE req-7 ship it
I am replying to the above and saying nothing myself.'
  fixture_page "$fix" 1 - 200 "$(page_body "$(comment 11 2026-08-01T00:00:00Z "$body")")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists
  assert_field "$RECORD" conclusion ABSENT "quoted-only identity"
  assert_field "$RECORD" retrieval complete "quoted-only identity"
  assert_field "$RECORD" matches 0 "quoted-only identity"
  assert_field "$RECORD" quoted_only 1 "quoted-only identity"
  expect_code 1 "$RC" "a quoted-only identity leaves a genuine, complete absence"
  pass "an identifier present only in quoted prose is reported, not matched"
}

# The other side of the prefix rule, and the one that is easy to get backwards:
# the separators identifiers are built from are the same characters that end a
# sentence, so a boundary rule strict enough to reject req-7.1 must still accept
# "APPROVE req-7." - the most ordinary way a human writes a ruling. Found by the
# first live run of this contract against a real thread, not by inspection.
test_identity_followed_by_sentence_punctuation_matches() {
  local fix
  fix=$(fixture_new punct)
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7. Ship it.')" \
    "$(comment 12 2026-08-02T00:00:00Z 'APPROVE (req-7), confirmed')" \
    "$(comment 13 2026-08-03T00:00:00Z 'APPROVE req-7: go')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim latest
  assert_field "$RECORD" conclusion PRESENT "punctuated identity"
  assert_field "$RECORD" matches 3 "punctuated identity"
  assert_field "$RECORD" prefix_rejected 0 "punctuated identity"
  pass "an identifier followed by ordinary punctuation still matches"
}

# Discovery is not identity: req-71 contains req-7.
test_prefix_collision_is_not_a_match() {
  local fix
  fix=$(fixture_new prefix)
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-71 a different request')" \
    "$(comment 12 2026-08-02T00:00:00Z 'APPROVE req-7-b also different')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists
  assert_field "$RECORD" conclusion ABSENT "prefix collision"
  assert_field "$RECORD" retrieval complete "prefix collision"
  assert_field "$RECORD" matches 0 "prefix collision"
  assert_field "$RECORD" candidates 2 "prefix collision"
  assert_field "$RECORD" prefix_rejected 2 "prefix collision"
  expect_code 1 "$RC" "a prefix collision is not the request"
  pass "a longer identifier sharing this one's prefix is discovered and then rejected"
}

# The negative that must remain assertable, or the contract would have replaced
# one defect with a tool that can never answer.
test_complete_retrieval_with_genuine_absence() {
  local fix
  fix=$(fixture_new absent)
  fixture_page "$fix" 1 2 200 "$(page_body "$(comment 11 2026-08-01T00:00:00Z 'chatter')")"
  fixture_page "$fix" 2 - 200 "$(page_body "$(comment 21 2026-08-02T00:00:00Z 'more chatter')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists
  assert_field "$RECORD" conclusion ABSENT "genuine absence"
  assert_field "$RECORD" retrieval complete "genuine absence"
  assert_field "$RECORD" reason enumerated "genuine absence"
  assert_field "$RECORD" records 2 "genuine absence"
  expect_code 1 "$RC" "a completely enumerated source with no match is absent"
  pass "a genuinely absent ruling over a complete read is still assertable"
}

# The non-vacuity anchor: exactly one applicable ruling, found and identified.
test_complete_retrieval_with_exactly_one_ruling() {
  local fix
  fix=$(fixture_new one)
  fixture_page "$fix" 1 2 200 "$(page_body "$(comment 11 2026-08-01T00:00:00Z 'chatter')")"
  fixture_page "$fix" 2 - 200 "$(page_body \
    "$(comment 21 2026-08-02T00:00:00Z 'APPROVE req-7 ship it')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim latest
  assert_field "$RECORD" conclusion PRESENT "exactly one ruling"
  assert_field "$RECORD" matches 1 "exactly one ruling"
  assert_field "$RECORD" selected 21 "exactly one ruling"
  assert_field "$RECORD" retrieval complete "exactly one ruling"
  expect_code 0 "$RC" "one applicable ruling over a complete read is present"
  pass "exactly one applicable ruling is found and identified, so the suite is not vacuous"
}

# --- retrieval-layer failures ------------------------------------------------

test_absent_reader_tool_is_could_not_observe() {
  local record rc=0
  # The reader is named through FM_RETRIEVAL_GH rather than removed from PATH,
  # so this exercises the missing-tool path without also removing the shell's
  # own utilities and failing for an unrelated reason.
  record=$(FM_RETRIEVAL_GH=fm-no-such-reader "$READ" endpoint 'fixture?fm_page=1' \
    --identity req-7 --claim exists 2>&1) || rc=$?
  assert_field "$record" retrieval unobserved "absent reader"
  assert_field "$record" reason transport_unavailable "absent reader"
  assert_field "$record" conclusion INDETERMINATE "absent reader"
  expect_code 2 "$rc" "an absent reader tool cannot report absence"
  pass "a missing reader tool is could-not-observe, not an empty source"
}

test_schema_movement_fails_closed() {
  local fix
  fix=$(fixture_new schema)
  # The shape a paginated list endpoint would take if GitHub moved to an
  # envelope, which a reader expecting a bare array must refuse rather than
  # read as zero records.
  fixture_page "$fix" 1 - 200 '{"total_count":3,"items":[]}'
  run_read "$fix" --identity req-7 --claim exists
  assert_field "$RECORD" retrieval unobserved "schema movement"
  assert_field "$RECORD" reason schema_unexpected "schema movement"
  expect_code 2 "$RC" "an unrecognized response shape cannot report absence"
  pass "a moved response schema fails closed instead of reading as an empty set"
}

test_record_without_identity_field_fails_closed() {
  local fix
  fix=$(fixture_new noid)
  fixture_page "$fix" 1 - 200 '[{"created_at":"2026-08-01T00:00:00Z","body":"APPROVE req-7"}]'
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists
  assert_field "$RECORD" retrieval unobserved "missing identity field"
  assert_field "$RECORD" reason schema_unexpected "missing identity field"
  expect_code 2 "$RC" "records with no immutable identity cannot be deduplicated"
  pass "a record carrying no immutable identity fails closed"
}

test_record_without_text_field_fails_closed() {
  local fix
  fix=$(fixture_new notext)
  fixture_page "$fix" 1 - 200 '[{"id":11,"created_at":"2026-08-01T00:00:00Z"}]'
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists
  assert_field "$RECORD" retrieval unobserved "missing text field"
  assert_field "$RECORD" reason schema_unexpected "missing text field"
  assert_field "$RECORD" conclusion INDETERMINATE "missing text field"
  expect_code 2 "$RC" "a missing configured text field cannot report absence"
  pass "a record missing the configured text field fails closed"
}

test_record_without_time_field_fails_closed() {
  local fix
  fix=$(fixture_new notime)
  fixture_page "$fix" 1 - 200 '[{"id":11,"body":"APPROVE req-7"}]'
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists
  assert_field "$RECORD" retrieval unobserved "missing time field"
  assert_field "$RECORD" reason schema_unexpected "missing time field"
  assert_field "$RECORD" conclusion INDETERMINATE "missing time field"
  expect_code 2 "$RC" "a missing configured time field cannot report absence"
  pass "a record missing the configured time field fails closed"
}

test_unparsable_continuation_fails_closed() {
  local fix fakebin record rc=0
  fix=$(fixture_new badlink)
  fixture_page "$fix" 1 - 200 "$(page_body "$(comment 11 2026-08-01T00:00:00Z 'x')")"
  fakebin=$(install_fake_gh "$fix")
  # A continuation header the reader cannot parse is not the same as no
  # continuation: the source said there is more and this cannot reach it.
  record=$(PATH="$fakebin:$PATH" FM_RETRIEVAL_SLEEP=: \
    FM_RETRIEVAL_FORCE_LINK='<not-a-url; rel=next' \
    "$READ" endpoint 'fixture?fm_page=1' --identity req-7 --claim exists 2>&1) || rc=$?
  assert_field "$record" retrieval unobserved "unparsable continuation"
  assert_field "$record" reason continuation_unreadable "unparsable continuation"
  expect_code 2 "$rc" "a continuation this cannot follow is could-not-observe"
  pass "a continuation header that cannot be parsed fails closed"
}

test_bounded_retry_recovers_a_transient_page() {
  local fix attempts
  fix=$(fixture_new retry)
  fixture_page "$fix" 1 2 200 "$(page_body "$(comment 11 2026-08-01T00:00:00Z 'x')")"
  fixture_page "$fix" 2 - 200 "$(page_body \
    "$(comment 21 2026-08-02T00:00:00Z 'APPROVE req-7 ship it')")"
  printf '1' > "$fix/pages/2.failures"
  printf '500' > "$fix/pages/2.failstatus"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim latest
  assert_field "$RECORD" retrieval complete "bounded retry"
  assert_field "$RECORD" conclusion PRESENT "bounded retry"
  attempts=$(awk -F '\t' '$1 == 2' "$fix/requests" | wc -l | tr -d ' ')
  [ "$attempts" = 2 ] || fail "bounded retry: page 2 should have been attempted twice, got $attempts"
  pass "one transient page failure is retried and the read still completes"
}

test_rate_limited_read_is_could_not_observe() {
  local fix
  fix=$(fixture_new ratelimit)
  fixture_page "$fix" 1 - 429 "$(page_body)"
  run_read "$fix" --identity req-7 --claim exists
  assert_field "$RECORD" retrieval unobserved "rate limited"
  assert_field "$RECORD" reason rate_limited "rate limited"
  expect_code 2 "$RC" "a rate-limited read cannot report absence"
  pass "a rate-limited source is could-not-observe, not an empty source"
}

test_not_authorized_read_is_could_not_observe() {
  local fix
  fix=$(fixture_new unauth)
  fixture_page "$fix" 1 - 401 "$(page_body)"
  run_read "$fix" --identity req-7 --claim exists
  assert_field "$RECORD" retrieval unobserved "unauthorized"
  assert_field "$RECORD" reason not_authorized "unauthorized"
  expect_code 2 "$RC" "a refused credential cannot report absence"
  pass "a refused credential is could-not-observe, not an empty source"
}

# A 404 is reported as its own reason rather than as an authorization fact,
# because GitHub answers 404 both for a resource that is absent and for one the
# credential cannot see. What matters for the conclusion is that it is neither an
# empty collection nor a readable one.
test_unreadable_subject_is_could_not_observe() {
  local fix
  fix=$(fixture_new notfound)
  fixture_page "$fix" 1 - 404 "$(page_body)"
  run_read "$fix" --identity req-7 --claim exists
  assert_field "$RECORD" retrieval unobserved "unreadable subject"
  assert_field "$RECORD" reason subject_unreadable "unreadable subject"
  expect_code 2 "$RC" "a subject this cannot read cannot report absence"
  pass "an absent-or-invisible subject is could-not-observe, not an empty collection"
}

# --- machine-readable state and its commit point -----------------------------

test_records_and_provenance_are_written_and_committed_last() {
  local fix records
  fix=$(fixture_new state)
  records="$TMP_ROOT/state-records.jsonl"
  fixture_page "$fix" 1 2 200 "$(page_body "$(comment 11 2026-08-01T00:00:00Z 'x')")"
  fixture_page "$fix" 2 - 200 "$(page_body \
    "$(comment 21 2026-08-02T00:00:00Z 'APPROVE req-7')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim latest --records "$records"
  assert_present "$records" "the retrieved record set is written"
  assert_present "$records.meta" "the completeness and provenance sidecar is written"
  [ "$(jq -r '.retrieval' "$records.meta")" = complete ] \
    || fail "state: the sidecar must carry the completeness value"
  [ "$(jq -r '.pages | length' "$records.meta")" = 2 ] \
    || fail "state: the sidecar must carry per-page provenance"
  [ -n "$(jq -r '.observed_at' "$records.meta")" ] \
    || fail "state: the sidecar must carry an observation time"
  # The sidecar is the commit point: a record set found without it is a crashed
  # write, and reading it as a complete set is exactly the defect.
  rm -f "$records.meta"
  RECORD=$(FM_RETRIEVAL_SLEEP=: "$READ" --replay "$records" --claim exists \
    --identity req-7 --applicable APPROVE 2>&1) && RC=0 || RC=$?
  assert_field "$RECORD" retrieval unobserved "uncommitted record set"
  assert_field "$RECORD" reason state_uncommitted "uncommitted record set"
  expect_code 2 "$RC" "a record set with no committed completeness proof is unusable"
  pass "records and provenance are written, and the completeness sidecar is the commit point"
}

test_replay_of_a_committed_read_reaches_the_same_conclusion() {
  local fix records absent_records
  fix=$(fixture_new replay)
  records="$TMP_ROOT/replay-records.jsonl"
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim latest --records "$records"
  assert_field "$RECORD" conclusion PRESENT "replay source read"
  RECORD=$("$READ" --replay "$records" --claim latest --identity req-7 \
    --applicable APPROVE 2>&1) && RC=0 || RC=$?
  assert_field "$RECORD" conclusion PRESENT "replayed read"
  assert_field "$RECORD" retrieval complete "replayed read"
  expect_code 0 "$RC" "a committed complete read replays to the same conclusion"
  absent_records="$TMP_ROOT/replay-absent-records.jsonl"
  run_read "$fix" --identity req-8 --applicable APPROVE --claim exists \
    --records "$absent_records"
  assert_field "$RECORD" conclusion ABSENT "absent source read"
  RECORD=$("$READ" --replay "$absent_records" --claim exists --identity req-8 \
    --applicable APPROVE 2>&1) && RC=0 || RC=$?
  assert_field "$RECORD" conclusion ABSENT "replayed absent read"
  assert_field "$RECORD" retrieval complete "replayed absent read"
  expect_code 1 "$RC" "a committed complete absence remains assertable on replay"
  pass "valid committed reads replay to both PRESENT and ABSENT"
}

test_replay_without_text_field_fails_closed() {
  local fix records staged
  fix=$(fixture_new replay-notext)
  records="$TMP_ROOT/replay-notext.jsonl"
  staged="$TMP_ROOT/replay-notext-staged.jsonl"
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists --records "$records"
  jq -c 'del(.body)' "$records" > "$staged"
  mv "$staged" "$records"
  rebind_records "$records"
  RECORD=$("$READ" --replay "$records" --claim exists --identity req-7 \
    --applicable APPROVE 2>&1) && RC=0 || RC=$?
  assert_field "$RECORD" retrieval unobserved "replay missing text field"
  assert_field "$RECORD" reason schema_unexpected "replay missing text field"
  assert_field "$RECORD" conclusion INDETERMINATE "replay missing text field"
  expect_code 2 "$RC" "replay missing configured text cannot report absence"
  pass "replay missing the configured text field fails closed"
}

test_replay_without_time_field_fails_closed() {
  local fix records staged
  fix=$(fixture_new replay-notime)
  records="$TMP_ROOT/replay-notime.jsonl"
  staged="$TMP_ROOT/replay-notime-staged.jsonl"
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists --records "$records"
  jq -c 'del(.created_at)' "$records" > "$staged"
  mv "$staged" "$records"
  rebind_records "$records"
  RECORD=$("$READ" --replay "$records" --claim exists --identity req-7 \
    --applicable APPROVE 2>&1) && RC=0 || RC=$?
  assert_field "$RECORD" retrieval unobserved "replay missing time field"
  assert_field "$RECORD" reason schema_unexpected "replay missing time field"
  assert_field "$RECORD" conclusion INDETERMINATE "replay missing time field"
  expect_code 2 "$RC" "replay missing configured time cannot report absence"
  pass "replay missing the configured time field fails closed"
}

BOUND_REPLAY_RECORDS=
prepare_bound_replay() {  # <name>
  local fix=$TMP_ROOT/fix-bound-$1
  BOUND_REPLAY_RECORDS="$TMP_ROOT/bound-$1.jsonl"
  mkdir -p "$fix/pages" || fail "could not create bound replay fixture"
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7')" \
    "$(comment 12 2026-08-02T00:00:00Z 'REJECT req-8')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists \
    --records "$BOUND_REPLAY_RECORDS"
}

assert_bound_replay_refused() {  # <label>
  local label=$1
  RECORD=$("$READ" --replay "$BOUND_REPLAY_RECORDS" --claim exists \
    --identity req-7 --applicable APPROVE 2>&1) && RC=0 || RC=$?
  assert_field "$RECORD" retrieval unobserved "$label"
  assert_field "$RECORD" conclusion INDETERMINATE "$label"
  expect_code 2 "$RC" "$label cannot produce a replay verdict"
}

test_replay_with_deleted_records_fails_closed() {
  local staged
  prepare_bound_replay deleted
  staged="$BOUND_REPLAY_RECORDS.staged"
  sed -n '2,$p' "$BOUND_REPLAY_RECORDS" > "$staged"
  mv "$staged" "$BOUND_REPLAY_RECORDS"
  assert_bound_replay_refused "deleted replay records"
  pass "deleting committed replay records invalidates their proof"
}

test_replay_with_appended_records_fails_closed() {
  prepare_bound_replay appended
  comment 13 2026-08-03T00:00:00Z 'APPROVE req-9' >> "$BOUND_REPLAY_RECORDS"
  assert_bound_replay_refused "appended replay records"
  pass "appending committed replay records invalidates their proof"
}

test_replay_with_reordered_records_fails_closed() {
  local staged
  prepare_bound_replay reordered
  staged="$BOUND_REPLAY_RECORDS.staged"
  awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }' \
    "$BOUND_REPLAY_RECORDS" > "$staged"
  mv "$staged" "$BOUND_REPLAY_RECORDS"
  assert_bound_replay_refused "reordered replay records"
  pass "reordering committed replay records invalidates their proof"
}

test_replay_without_record_digest_fails_closed() {
  local staged
  prepare_bound_replay nodigest
  staged="$BOUND_REPLAY_RECORDS.meta.staged"
  jq 'del(.record_digest)' "$BOUND_REPLAY_RECORDS.meta" > "$staged"
  mv "$staged" "$BOUND_REPLAY_RECORDS.meta"
  assert_bound_replay_refused "digestless replay proof"
  pass "a replay proof without a record digest fails closed"
}

test_digest_command_failure_cannot_certify() {
  local fix fakebin records record rc=0
  fix=$(fixture_new digest-failure)
  records="$TMP_ROOT/digest-failure.jsonl"
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7')")"
  fakebin=$(install_fake_gh "$fix")
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$fakebin/shasum"
  chmod +x "$fakebin/shasum"
  record=$(PATH="$fakebin:$PATH" FM_RETRIEVAL_SLEEP=: \
    "$READ" endpoint 'fixture?fm_page=1' --identity req-7 --applicable APPROVE \
    --claim exists --records "$records" 2>&1) || rc=$?
  assert_field "$record" retrieval unobserved "failed digest command"
  assert_field "$record" conclusion INDETERMINATE "failed digest command"
  expect_code 2 "$rc" "a failed digest command cannot certify records"
  rm -f "$fakebin/shasum"
  pass "a failing digest command yields unobserved state"
}

test_concurrent_publishers_cannot_mix_proof_and_records() {
  local records pages_a pages_b staged_a staged_b pid_a pid_b count proof_count
  records="$TMP_ROOT/concurrent.jsonl"
  pages_a="$TMP_ROOT/pages-a.json"
  pages_b="$TMP_ROOT/pages-b.json"
  staged_a="$TMP_ROOT/staged-a.jsonl"
  staged_b="$TMP_ROOT/staged-b.jsonl"
  comment 11 2026-08-01T00:00:00Z 'APPROVE req-7' > "$staged_a"
  page_body "$(comment 21 2026-08-02T00:00:00Z x)" \
    "$(comment 22 2026-08-03T00:00:00Z y)" | jq -c '.[]' > "$staged_b"
  printf '%s\n' '{"url":"a","records":1,"attempts":1,"status":200}' > "$pages_a"
  printf '%s\n' '{"url":"b","records":2,"attempts":1,"status":200}' > "$pages_b"
  FM_RETRIEVAL_TEST_LIB="$LIB" RECORDS="$records" STAGED="$staged_a" PAGES="$pages_a" \
    EXPECTED=1 bash -c '. "$FM_RETRIEVAL_TEST_LIB"; fm_retrieval_reset; FM_RETRIEVAL_RECORDS=$EXPECTED; FM_RETRIEVAL_REASON=enumerated; FM_RETRIEVAL_COMPLETENESS=complete; fm_retrieval_publish "$RECORDS" "$STAGED" "$PAGES"' &
  pid_a=$!
  fm_test_reap "$pid_a"
  FM_RETRIEVAL_TEST_LIB="$LIB" RECORDS="$records" STAGED="$staged_b" PAGES="$pages_b" \
    EXPECTED=2 bash -c '. "$FM_RETRIEVAL_TEST_LIB"; fm_retrieval_reset; FM_RETRIEVAL_RECORDS=$EXPECTED; FM_RETRIEVAL_REASON=enumerated; FM_RETRIEVAL_COMPLETENESS=complete; fm_retrieval_publish "$RECORDS" "$STAGED" "$PAGES"' &
  pid_b=$!
  fm_test_reap "$pid_b"
  wait "$pid_a" || fail "first concurrent publisher failed"
  wait "$pid_b" || fail "second concurrent publisher failed"
  count=$(awk 'NF { n++ } END { print n + 0 }' "$records")
  proof_count=$(jq -r '.records' "$records.meta")
  RECORD=$("$READ" --replay "$records" --identity req-7 --claim exists 2>&1) && RC=0 || RC=$?
  if [ "$count" = "$proof_count" ]; then
    assert_field "$RECORD" retrieval complete "coherent concurrent publication"
  else
    assert_field "$RECORD" retrieval unobserved "interleaved concurrent publication"
  fi
  pass "concurrent publishers cannot mix record and proof generations"
}

test_replay_selects_only_from_certified_snapshot() {
  local fix records replacement
  fix=$(fixture_new snapshot-race)
  records="$TMP_ROOT/snapshot-race.jsonl"
  replacement="$TMP_ROOT/snapshot-replacement.jsonl"
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7')")"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists --records "$records"
  comment 21 2026-08-02T00:00:00Z 'unrelated' > "$replacement"
  RECORD=$(FM_RETRIEVAL_TEST_REPLACE_REPLAY_WITH="$replacement" \
    "$READ" --replay "$records" --identity req-7 --applicable APPROVE \
    --claim exists 2>&1) && RC=0 || RC=$?
  case "$(field "$RECORD" retrieval):$(field "$RECORD" conclusion)" in
    complete:PRESENT) expect_code 0 "$RC" "selection uses the certified snapshot" ;;
    unobserved:INDETERMINATE) expect_code 2 "$RC" "a raced snapshot fails closed" ;;
    *) fail "snapshot selection race produced an unauthorized verdict: $RECORD" ;;
  esac
  pass "replay replacement cannot authorize a verdict over changed bytes"
}

test_crashed_publisher_cannot_block_reader_or_retry() {
  local fix records fakebin rc=0
  fix=$(fixture_new publisher-crash)
  records="$TMP_ROOT/publisher-crash.jsonl"
  fixture_page "$fix" 1 - 200 "$(page_body \
    "$(comment 11 2026-08-01T00:00:00Z 'APPROVE req-7')")"
  fakebin=$(install_fake_gh "$fix")
  PATH="$fakebin:$PATH" FM_RETRIEVAL_SLEEP=: FM_RETRIEVAL_TEST_KILL_AFTER_RECORDS=1 \
    "$READ" endpoint 'fixture?fm_page=1' --identity req-7 --applicable APPROVE \
    --claim exists --records "$records" >/dev/null 2>&1 || :
  RECORD=$("$READ" --replay "$records" --identity req-7 --applicable APPROVE \
    --claim exists 2>&1) && RC=0 || RC=$?
  assert_field "$RECORD" retrieval unobserved "reader after publisher crash"
  expect_code 2 "$RC" "a reader after publisher crash makes progress"
  run_read "$fix" --identity req-7 --applicable APPROVE --claim exists --records "$records"
  assert_field "$RECORD" conclusion PRESENT "retry after publisher crash"
  expect_code 0 "$RC" "a publish retry after crash succeeds"
  pass "a publisher crash blocks neither readers nor later publication"
}

# --- the consumer type ------------------------------------------------------

test_consumer_must_handle_all_three_conclusions() {
  local out rc=0
  out=$(FM_RETRIEVAL_TEST_LIB="$LIB" bash -c '
    set -u
    . "$FM_RETRIEVAL_TEST_LIB"
    record="retrieval[1]{source,retrieval,reason,pages,records,duplicates,reported,candidates,matches,quoted_only,prefix_rejected,claim,conclusion,selected,evidence_ref}:
  x,complete,enumerated,1,1,0,unknown,1,0,0,0,exists,ABSENT,-,-"
    on_present() { :; }
    on_absent() { :; }
    fm_retrieval_case "$record" on_present on_absent
  ' 2>&1) || rc=$?
  expect_code 3 "$rc" "a two-branch consumer of a three-valued result is refused"
  assert_contains "$out" "must handle all three" \
    "the refusal names the exhaustiveness requirement"
  pass "a consumer that does not handle all three conclusions is refused"
}

test_indeterminate_is_not_coercible_by_a_consumer() {
  local out rc=0
  out=$(FM_RETRIEVAL_TEST_LIB="$LIB" bash -c '
    set -u
    . "$FM_RETRIEVAL_TEST_LIB"
    record="retrieval[1]{source,retrieval,reason,pages,records,duplicates,reported,candidates,matches,quoted_only,prefix_rejected,claim,conclusion,selected,evidence_ref}:
  x,unobserved,page_unreadable,1,0,0,unknown,0,0,0,0,exists,INDETERMINATE,-,-"
    on_absent() { :; }
    on_present() { :; }
    fm_retrieval_case "$record" on_present on_absent on_absent
  ' 2>&1) || rc=$?
  expect_code 3 "$rc" "reusing the absent handler for INDETERMINATE is coercion"
  assert_contains "$out" "not coercible" "the refusal names the coercion"
  pass "an INDETERMINATE conclusion cannot be quietly handled as an absence"
}

# --- the deterministic check ------------------------------------------------

test_check_rejects_an_unannotated_remote_collection_read() {
  local dir out rc=0
  dir="$TMP_ROOT/check-unannotated"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fm-new-reader.sh" <<'SH'
#!/usr/bin/env bash
set -u
out=$(gh api "repos/o/r/issues/1/comments")
printf '%s\n' "$out"
SH
  out=$("$CHECK" --check --root "$dir" 2>&1) || rc=$?
  expect_code 1 "$rc" "an unannotated remote collection read is rejected"
  assert_contains "$out" "bin/fm-new-reader.sh:3" "the rejection names the exact line"
  assert_contains "$out" "fm-retrieval-audit" "the rejection names the annotation it wants"
  pass "the check rejects a new load-bearing remote collection read with no classification"
}

test_check_accepts_a_classified_read() {
  local dir out rc=0
  dir="$TMP_ROOT/check-annotated"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fm-new-reader.sh" <<'SH'
#!/usr/bin/env bash
set -u
# fm-retrieval-audit: contract - routed through bin/fm-control-read.sh
out=$(gh api "repos/o/r/issues/1/comments")
printf '%s\n' "$out"
SH
  out=$("$CHECK" --check --root "$dir" 2>&1) || rc=$?
  expect_code 0 "$rc" "a classified read passes"
  assert_contains "$out" "fm-retrieval-check: ok" "the pass names itself"
  assert_contains "$out" "coverage=complete" "the pass proves complete coverage"
  pass "the check accepts a read carrying an exact classification and reason"
}

test_check_rejects_an_unchecked_non_shell_file() {
  local dir out rc=0
  dir="$TMP_ROOT/check-unchecked"
  mkdir -p "$dir/bin"
  printf '%s\n' 'gh api repos/o/r/issues/1/comments' > "$dir/bin/reader.xyz"
  out=$("$CHECK" --check --root "$dir" 2>&1) || rc=$?
  expect_code 2 "$rc" "an unclassifiable tracked file has a distinct coverage status"
  assert_contains "$out" "UNCHECKED" "the coverage failure names its class"
  assert_contains "$out" "bin/reader.xyz" "the coverage failure names the file"
  assert_not_contains "$out" "coverage=complete" "unchecked coverage is never complete"
  pass "a non-shell tracked file cannot pass outside the gate universe"
}

test_check_discovers_a_native_non_shell_read() {
  local dir out rc=0
  dir="$TMP_ROOT/check-native"
  mkdir -p "$dir/src"
  printf '%s\n' 'const result = await fetch("https://api.example.test/comments");' \
    > "$dir/src/reader.js"
  out=$("$CHECK" --check --root "$dir" 2>&1) || rc=$?
  expect_code 1 "$rc" "an unclassified native read is rejected"
  assert_contains "$out" "src/reader.js:1" "the native classifier names the read"
  assert_contains "$out" "no fm-retrieval-audit" "the native read requires classification"
  pass "a native non-shell read is discovered by its language classifier"
}

test_check_reports_coverage_beside_violations() {
  local dir out rc=0
  dir="$TMP_ROOT/check-violation-and-unchecked"
  mkdir -p "$dir/bin"
  printf '%s\n' 'out=$(gh api repos/o/r/issues/1/comments)' > "$dir/bin/reader.sh"
  printf '%s\n' 'opaque outbound implementation' > "$dir/bin/reader.xyz"
  out=$("$CHECK" --check --root "$dir" 2>&1) || rc=$?
  expect_code 1 "$rc" "site violations retain precedence over incomplete coverage"
  assert_contains "$out" "coverage=incomplete" "the violation path reports coverage"
  assert_contains "$out" "UNCHECKED" "the violation path reports unchecked files"
  assert_contains "$out" "bin/reader.xyz" "the violation path names unchecked files"
  pass "site violations cannot conceal incomplete gate coverage"
}

test_check_rejects_an_unknown_classification() {
  local dir out rc=0
  dir="$TMP_ROOT/check-badclass"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fm-new-reader.sh" <<'SH'
#!/usr/bin/env bash
set -u
# fm-retrieval-audit: probably-fine - looks alright to me
out=$(gh api "repos/o/r/issues/1/comments")
printf '%s\n' "$out"
SH
  out=$("$CHECK" --check --root "$dir" 2>&1) || rc=$?
  expect_code 1 "$rc" "a classification outside the closed vocabulary is rejected"
  assert_contains "$out" "probably-fine" "the rejection names the unknown class"
  pass "the check refuses a classification outside its closed vocabulary"
}

test_check_requires_a_reason_with_the_classification() {
  local dir out rc=0
  dir="$TMP_ROOT/check-noreason"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fm-new-reader.sh" <<'SH'
#!/usr/bin/env bash
set -u
# fm-retrieval-audit: not-a-collection
out=$(gh api "repos/o/r/issues/1/comments")
printf '%s\n' "$out"
SH
  out=$("$CHECK" --check --root "$dir" 2>&1) || rc=$?
  expect_code 1 "$rc" "a classification with no reason is rejected"
  assert_contains "$out" "reason" "the rejection asks for the reason"
  pass "the check refuses a classification carrying no reason"
}

test_check_passes_this_repository() {
  local out rc=0
  out=$("$CHECK" --check 2>&1) || rc=$?
  expect_code 0 "$rc" "this repository's own read sites are all classified: $out"
  pass "every read site in this repository carries a classification"
}

test_check_census_is_strictly_broader_than_the_enforced_set() {
  local census check rc=0 census_sites check_sites
  # The audit census is deliberately broader than the enforced pattern, so it
  # must report strictly more sites. Narrowing the census down to the enforced
  # set is what turns an audit into a patch, and this is what would catch it.
  census=$("$CHECK" --audit 2>&1) || rc=$?
  expect_code 0 "$rc" "the census runs over this repository"
  assert_contains "$census" "fm-retrieval-check: census" "the census names itself"
  check=$("$CHECK" --check 2>&1) || fail "the enforced check must pass here: $check"
  census_sites=$(printf '%s\n' "$census" | sed -n 's/.*census .*sites=\([0-9]*\).*/\1/p' | head -1)
  check_sites=$(printf '%s\n' "$check" | sed -n 's/.*ok sites=\([0-9]*\).*/\1/p' | head -1)
  [ -n "$census_sites" ] && [ -n "$check_sites" ] \
    || fail "both modes must report a site count (census=$census_sites check=$check_sites)"
  [ "$census_sites" -gt "$check_sites" ] \
    || fail "the census must be broader than the enforced set (census=$census_sites check=$check_sites)"
  [ "$check_sites" -gt 0 ] \
    || fail "an enforced set of zero sites would make the check vacuous"
  pass "the broad audit census stays strictly broader than the enforced set"
}

# --- the migrated consumer --------------------------------------------------
#
# bin/fm-verify.sh's pr-checks verifier read gh's flattened statusCheckRollup,
# which gh 2.96.0 requests as contexts(first:100): a head with more than 100
# members silently loses the newest ones, and "no member is non-SUCCESS" is a
# negative claim over that truncated set.

rollup_json() {  # <member-count> <last-conclusion>
  jq -cn --argjson n "$1" --arg last "$2" '
    {statusCheckRollup: [ range($n) | {__typename:"CheckRun", status:"COMPLETED",
      conclusion: (if . == ($n - 1) then $last else "SUCCESS" end)} ]}'
}

fake_gh_pr_view() {  # <payload>
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/rollup-$RANDOM")
  printf '%s' "$1" > "$fakebin/payload.json"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
cat "$(dirname "$0")/payload.json"
SH
  chmod +x "$fakebin/gh"
  printf '%s' "$fakebin"
}

test_rollup_at_the_page_cap_is_not_a_pass() {
  local fakebin out
  fakebin=$(fake_gh_pr_view "$(rollup_json 100 SUCCESS)")
  out=$(PATH="$fakebin:$PATH" "$VERIFY" pr-checks https://github.test/o/r/pull/1 2>&1) \
    && fail "rollup cap: a set filling the page must not exit 0"
  assert_contains "$out" NO_VERIFIER_RAN \
    "a rollup that exactly fills its page is not proven complete"
  assert_contains "$out" retrieval_incomplete \
    "the reason names the incomplete retrieval"
  pass "a check rollup filling gh's page cap refuses a pass instead of assuming completeness"
}

test_rollup_below_the_cap_still_passes() {
  local fakebin out
  fakebin=$(fake_gh_pr_view "$(rollup_json 99 SUCCESS)")
  out=$(PATH="$fakebin:$PATH" "$VERIFY" pr-checks https://github.test/o/r/pull/1 2>&1) \
    || fail "rollup below cap: 99 successful members must still pass: $out"
  assert_contains "$out" PASS "a complete successful rollup still passes"
  pass "a rollup below the page cap still reaches a pass, so the guard is not vacuous"
}

test_rollup_below_the_cap_still_fails_on_a_failure() {
  local fakebin out rc=0
  fakebin=$(fake_gh_pr_view "$(rollup_json 99 FAILURE)")
  out=$(PATH="$fakebin:$PATH" "$VERIFY" pr-checks https://github.test/o/r/pull/1 2>&1) || rc=$?
  expect_code 1 "$rc" "a failing member below the cap is still a failure"
  assert_contains "$out" FAIL "a failing rollup still fails"
  pass "a failing member below the page cap is still reported as a failure"
}

# --- run --------------------------------------------------------------------

run() {  # <test-name>
  "$1"
  FM_TEST_PASSED_TESTS="$FM_TEST_PASSED_TESTS
$1"
}

run test_applicable_ruling_only_on_page_two
run test_oldest_record_is_on_page_one
run test_page_one_ruling_superseded_later
run test_latest_refuses_when_retrieval_is_bounded_out
run test_pagination_stopping_early_refuses_a_negative
run test_unreadable_page_refuses_a_negative
run test_duplicate_identifiers_across_pages
run test_irrelevant_later_comment_does_not_displace_the_ruling
run test_identity_only_in_quoted_prose_is_not_a_match
run test_identity_followed_by_sentence_punctuation_matches
run test_prefix_collision_is_not_a_match
run test_complete_retrieval_with_genuine_absence
run test_complete_retrieval_with_exactly_one_ruling
run test_absent_reader_tool_is_could_not_observe
run test_schema_movement_fails_closed
run test_record_without_identity_field_fails_closed
run test_record_without_text_field_fails_closed
run test_record_without_time_field_fails_closed
run test_unparsable_continuation_fails_closed
run test_bounded_retry_recovers_a_transient_page
run test_rate_limited_read_is_could_not_observe
run test_not_authorized_read_is_could_not_observe
run test_unreadable_subject_is_could_not_observe
run test_records_and_provenance_are_written_and_committed_last
run test_replay_of_a_committed_read_reaches_the_same_conclusion
run test_replay_without_text_field_fails_closed
run test_replay_without_time_field_fails_closed
run test_replay_with_deleted_records_fails_closed
run test_replay_with_appended_records_fails_closed
run test_replay_with_reordered_records_fails_closed
run test_replay_without_record_digest_fails_closed
run test_digest_command_failure_cannot_certify
run test_concurrent_publishers_cannot_mix_proof_and_records
run test_replay_selects_only_from_certified_snapshot
run test_crashed_publisher_cannot_block_reader_or_retry
run test_consumer_must_handle_all_three_conclusions
run test_indeterminate_is_not_coercible_by_a_consumer
run test_check_rejects_an_unannotated_remote_collection_read
run test_check_accepts_a_classified_read
run test_check_rejects_an_unchecked_non_shell_file
run test_check_discovers_a_native_non_shell_read
run test_check_reports_coverage_beside_violations
run test_check_rejects_an_unknown_classification
run test_check_requires_a_reason_with_the_classification
run test_check_passes_this_repository
run test_check_census_is_strictly_broader_than_the_enforced_set
run test_rollup_at_the_page_cap_is_not_a_pass
run test_rollup_below_the_cap_still_passes
run test_rollup_below_the_cap_still_fails_on_a_failure

fm_test_contract "$0"
