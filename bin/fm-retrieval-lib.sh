#!/usr/bin/env bash
# fm-retrieval-lib.sh - the single owner of firstmate's remote-collection
# retrieval type: page traversal, continuation, deduplication by immutable
# remote identity, bounded retry, completeness state, provenance, and the
# conclusion algebra that refuses a negative over a universe nothing enumerated.
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-retrieval-lib.sh
#   . "$SCRIPT_DIR/fm-retrieval-lib.sh"
#
# THE DEFECT THIS EXISTS TO PREVENT
#
# A control-plane read once reported "the authority has not replied" for hours
# while three rulings sat unread, one of them an approval a worker was already
# parked on. The read asked a paginated endpoint for comments and received the
# first page, and the first page holds the OLDEST records.
#
# Pagination is the mechanism, not the defect. The defect was making a NEGATIVE
# CLAIM over a source whose complete candidate universe had never been
# enumerated. An earlier version of the same miss was diagnosed as "I only read
# the newest record", and the fix adopted then - scan by timestamp - still read
# only the first page. The second fix landed on the wrong layer of one defect,
# which is what happens when the invariant lives in a caller's memory rather
# than in a type.
#
# The invariant, stated once:
#
#   discovery != identity
#   selection != retrieval
#   no match != absence, unless the relevant universe was completely observed
#
# TWO AXES, NEVER ONE
#
# A caller asking "has the authority ruled?" is asking two separable questions
# and a collapsed answer loses one of them:
#
#   RETRIEVAL COMPLETENESS is a fact about the SOURCE. Was the whole candidate
#   universe enumerated? Three values, never two:
#     complete    the source itself said there is nothing after what was read
#     incomplete  read cleanly, and stopped at a bound this reader imposed
#     unobserved  the extent could not be established at all
#
#   SELECTION is a fact about the CANDIDATES that were read. How many satisfy
#   the caller's exact identity and applicability test?
#
# Completeness is not a selection outcome and selection is not a completeness
# proof. Keeping incomplete and unobserved apart matters because they need
# different work: incomplete is a bound a caller may raise, unobserved is a
# source someone has to reach. Both refuse a negative, and a consumer that
# folded either into "nothing found" would be the original defect.
#
# THE ASYMMETRY THAT MAKES THIS USABLE
#
# Incompleteness kills negatives, not positives. A record actually read exists
# whatever remains unread, so an EXISTENCE claim can be answered from a partial
# read. An ABSENCE claim and an EXTREMAL claim ("the latest applicable ruling")
# both range over the whole universe, so both require complete retrieval even
# when a match is already in hand: a first page carrying an approval that a
# later page supersedes is exactly the shape that reads as a successful answer.
#
# Without that asymmetry the contract would refuse almost everything and callers
# would go around it, which is how the defect returns.
#
# WHAT IT DOES NOT DO
#
# It owns no meaning. What a ruling SAYS, which verdicts are applicable, and
# what an identifier means are the caller's, supplied as patterns. This layer
# decides only whether the caller may draw a conclusion from what was read.
#
# CONFIGURATION
#   FM_RETRIEVAL_GH        reader command (default: gh). Plain gh rather than
#                          gh-axi because the continuation lives in the response
#                          headers, which the agent-ergonomic wrapper does not
#                          expose; bin/fm-pr-merge.sh and bin/fm-attest.sh read
#                          GitHub the same way and for the same reason.
#   FM_RETRIEVAL_RETRIES   extra attempts per page after the first (default 2)
#   FM_RETRIEVAL_BACKOFF_MS  first backoff, doubled per attempt (default 400)
#   FM_RETRIEVAL_SLEEP     sleep command (default sleep; tests set it to :)
#   FM_RETRIEVAL_MAX_PAGES default page bound (default 50)
#   FM_RETRIEVAL_FORCE_LINK  test-only continuation override, applied to the
#                          first page only, so the unparsable-continuation path
#                          can be exercised without a fixture that lies about
#                          every page.
#
# The public-content transport's own configuration is documented beside it, in
# the "public-content retrieval" section below.

# shellcheck disable=SC2034  # published for sourcing scripts, not used here.
FM_RETRIEVAL_SCHEMA=fm-retrieval.v1

# The closed reason vocabulary. A reason names WHY the completeness value is
# what it is, and every value below maps to exactly one completeness:
#
#   complete
#     enumerated            the source offered no further continuation
#     body_complete         a public body arrived whole, inside every bound
#   incomplete
#     page_bound_reached    the page bound was spent with a continuation left
#     record_bound_reached  the record bound was spent with a continuation left
#     byte_bound_reached    a public body hit the byte bound. The prefix that
#                           arrived is never published, because a truncated
#                           document read as the document is the same defect
#                           this file exists to stop, one layer down
#   unobserved
#     transport_unavailable   the reader command is not present or not runnable
#     not_authorized          the source refused the credential
#     subject_unreadable      the source answered 404. GitHub returns 404 both
#                             for a resource that does not exist and for one the
#                             credential cannot see, so this deliberately does
#                             not claim which; what matters is that it is neither
#                             an empty collection nor a readable one
#     rate_limited            the source refused for rate reasons after retries
#     page_unreadable         a page, or a public body, failed after its retries
#                             for another reason
#     continuation_unreadable a continuation existed and could not be parsed
#     schema_unexpected       the response was not the shape this reader knows
#     state_uncommitted       a stored record set carries no committed proof
#     usage_error             the call itself was malformed
#
#   The public-content transport adds the refusals a body download can meet.
#   Every one of them is unobserved rather than a negative fact about the
#   document, and each is kept apart from the others because they authorize
#   different next steps - and, for the first four, because collapsing any of
#   them into client filtering is exactly how a fallback becomes a bypass:
#     access_boundary         401, 407, 451, or a positively identified
#                             authorization, paywall, geographic, session or
#                             access-control refusal
#     challenge_presented     a CAPTCHA or interactive challenge, which is never
#                             answered automatically
#     ambiguous_refusal       a 403 or 406 that identified nothing at all
#     redirect_refused        a redirect this reader would not follow: a
#                             protocol downgrade, an unfollowable target, the
#                             hop bound, or sensitive material the caller
#                             declared must not cross an origin
#     client_filtered         positively identified filtering on the client
#                             string, with the closed attempt order spent or
#                             structurally unavailable to this caller
#     tls_failed              certificate or TLS negotiation failure. There is
#                             no insecure retry anywhere below
#     time_bound_reached      the wall-clock bound was spent
#     malformed_response      no readable status at all

FM_RETRIEVAL_COMPLETENESS=
FM_RETRIEVAL_REASON=
FM_RETRIEVAL_PAGES=0
FM_RETRIEVAL_RECORDS=0
FM_RETRIEVAL_DUPLICATES=0
FM_RETRIEVAL_REPORTED=unknown
FM_RETRIEVAL_RECORDS_FILE=
FM_RETRIEVAL_PROVENANCE=
FM_RETRIEVAL_SNAPSHOT_DIR=
FM_RETRIEVAL_DETAIL=

FM_RETRIEVAL_CANDIDATES=0
FM_RETRIEVAL_MATCHES=0
FM_RETRIEVAL_QUOTED_ONLY=0
FM_RETRIEVAL_PREFIX_REJECTED=0
FM_RETRIEVAL_SELECTED_ID=
FM_RETRIEVAL_SELECTED_AT=
FM_RETRIEVAL_SELECTED_URL=

FM_RETRIEVAL_CONCLUSION=
FM_RETRIEVAL_SOURCE=

fm_retrieval_reset() {
  FM_RETRIEVAL_COMPLETENESS=
  FM_RETRIEVAL_REASON=
  FM_RETRIEVAL_PAGES=0
  FM_RETRIEVAL_RECORDS=0
  FM_RETRIEVAL_DUPLICATES=0
  FM_RETRIEVAL_REPORTED=unknown
  FM_RETRIEVAL_RECORDS_FILE=
  FM_RETRIEVAL_PROVENANCE=
  FM_RETRIEVAL_SNAPSHOT_DIR=
  FM_RETRIEVAL_DETAIL=
  FM_RETRIEVAL_CANDIDATES=0
  FM_RETRIEVAL_MATCHES=0
  FM_RETRIEVAL_QUOTED_ONLY=0
  FM_RETRIEVAL_PREFIX_REJECTED=0
  FM_RETRIEVAL_SELECTED_ID=
  FM_RETRIEVAL_SELECTED_AT=
  FM_RETRIEVAL_SELECTED_URL=
  FM_RETRIEVAL_CONCLUSION=
  FM_RETRIEVAL_SOURCE=
  fm_retrieval_public_reset
}

# fm_retrieval_completeness_of <reason>: the completeness value a reason implies.
# The mapping is total and lives here alone, so no caller can invent a fourth
# value or attach a reason to the wrong one.
fm_retrieval_completeness_of() {  # <reason>
  case "${1:-}" in
    enumerated|body_complete) printf 'complete' ;;
    page_bound_reached|record_bound_reached|byte_bound_reached) printf 'incomplete' ;;
    transport_unavailable|not_authorized|rate_limited|page_unreadable) \
      printf 'unobserved' ;;
    subject_unreadable) printf 'unobserved' ;;
    continuation_unreadable|schema_unexpected|state_uncommitted|usage_error) \
      printf 'unobserved' ;;
    access_boundary|challenge_presented|ambiguous_refusal|redirect_refused) \
      printf 'unobserved' ;;
    client_filtered|tls_failed|time_bound_reached|malformed_response) \
      printf 'unobserved' ;;
    *) return 1 ;;
  esac
}

fm_retrieval_set_reason() {  # <reason> [detail]
  local completeness
  completeness=$(fm_retrieval_completeness_of "$1") || {
    FM_RETRIEVAL_REASON=usage_error
    FM_RETRIEVAL_COMPLETENESS=unobserved
    FM_RETRIEVAL_DETAIL="unknown retrieval reason: $1"
    return 1
  }
  FM_RETRIEVAL_REASON=$1
  FM_RETRIEVAL_COMPLETENESS=$completeness
  FM_RETRIEVAL_DETAIL=${2:-}
  return 0
}

# --- page traversal ----------------------------------------------------------
#
# One page is one attempt at one URL. The response is split at the first blank
# line: the status line and headers above it, the body below. That is the shape
# `gh api --include` produces, and reading the headers is the whole point -
# GitHub's continuation is a Link header carrying an opaque cursor, so a reader
# that incremented page= itself would be guessing at a sequence the source did
# not publish and would silently skip or repeat records under insertion.

fm_retrieval_page_status() {  # <headers>
  printf '%s\n' "$1" | sed -n '1s|^HTTP/[0-9.]* \([0-9][0-9]*\).*|\1|p' | head -1
}

# The rel="next" target, or empty when the source published none. Returns 2 when
# a continuation is present in a shape this cannot follow, which is a different
# fact from no continuation at all and must never be read as the end of the set.
fm_retrieval_next_link() {  # <headers>
  local link next
  link=$(printf '%s\n' "$1" | sed -n 's/^[Ll]ink:[[:space:]]*//p' | tr -d '\r' | head -1)
  [ -n "$link" ] || return 0
  case "$link" in
    *'rel="next"'*|*'rel=next'*) ;;
    *) return 0 ;;
  esac
  next=$(printf '%s' "$link" | sed -n 's/.*<\([^>]*\)>[[:space:]]*;[[:space:]]*rel="\{0,1\}next"\{0,1\}.*/\1/p' | head -1)
  case "$next" in
    http://*|https://*) printf '%s' "$next"; return 0 ;;
    *) return 2 ;;
  esac
}

# fm_retrieval_fetch_page <url> <headers-out> <body-out>: one page with its
# bounded retries. Echoes nothing; sets FM_RETRIEVAL_REASON on failure.
#
# A 429, a 403 that names rate limiting, and any 5xx are retried because they
# are the failures that clear on their own. A 401, 403 without a rate signal,
# and 404 are not retried: a refused credential and a path that does not exist
# do not become readable by asking again, and retrying them only delays the
# report. Neither is ever a negative result about the collection.
fm_retrieval_fetch_page() {  # <url> <headers-out> <body-out>
  local url=$1 headers_out=$2 body_out=$3
  local gh=${FM_RETRIEVAL_GH:-gh}
  local retries=${FM_RETRIEVAL_RETRIES:-2}
  local backoff=${FM_RETRIEVAL_BACKOFF_MS:-400}
  local sleeper=${FM_RETRIEVAL_SLEEP:-sleep}
  local attempt=0 raw status rc

  command -v "$gh" >/dev/null 2>&1 || {
    fm_retrieval_set_reason transport_unavailable "$gh is not on PATH"
    return 1
  }
  case "$retries" in ''|*[!0-9]*) retries=2 ;; esac

  while :; do
    attempt=$((attempt + 1))
    rc=0
    raw=$("$gh" api --include "$url" 2>/dev/null) || rc=$?
    status=$(fm_retrieval_page_status "$raw")
    if [ "$status" = 200 ]; then
      printf '%s\n' "$raw" | sed -n '1,/^[[:space:]]*$/p' > "$headers_out"
      printf '%s\n' "$raw" | sed -n '1,/^[[:space:]]*$/d;p' > "$body_out"
      FM_RETRIEVAL_LAST_ATTEMPTS=$attempt
      return 0
    fi
    case "$status" in
      404)
        # Not retried, and deliberately not called an authorization fact:
        # GitHub answers 404 both for a resource that is absent and for one this
        # credential cannot see, so naming either would be a claim nothing here
        # can support. Neither is an empty collection.
        fm_retrieval_set_reason subject_unreadable \
          "the source answered HTTP 404 for $url"
        return 1
        ;;
      401|403)
        # A 403 that names the rate limiter is a rate refusal wearing a
        # different number; anything else at 403 is an authorization fact.
        if [ "$status" = 403 ] && printf '%s' "$raw" | grep -qi 'rate limit'; then
          : # fall through to the retry path below
        else
          fm_retrieval_set_reason not_authorized \
            "the source answered HTTP $status for $url"
          return 1
        fi
        ;;
      429|5??) ;;
      '')
        # No status line at all: the reader produced something this cannot
        # classify, which is could-not-observe and never an empty page.
        if [ "$attempt" -gt "$retries" ]; then
          fm_retrieval_set_reason page_unreadable \
            "the reader returned no readable response for $url (exit $rc)"
          return 1
        fi
        ;;
      *)
        fm_retrieval_set_reason page_unreadable \
          "the source answered HTTP $status for $url"
        return 1
        ;;
    esac
    if [ "$attempt" -gt "$retries" ]; then
      case "$status" in
        429|403) fm_retrieval_set_reason rate_limited \
          "the source rate-limited $url after $attempt attempt(s)" ;;
        *) fm_retrieval_set_reason page_unreadable \
          "the source answered HTTP ${status:-none} for $url after $attempt attempt(s)" ;;
      esac
      return 1
    fi
    "$sleeper" "$(awk -v ms="$backoff" 'BEGIN { printf "%.3f", ms / 1000 }')" \
      >/dev/null 2>&1 || true
    backoff=$((backoff * 2))
  done
}

# fm_retrieval_fetch <first-url> <records-file> <id-field> [max-pages] [max-records] [text-field] [time-field]
#
# Traverses from <first-url> to the end of the collection, writing one JSON
# record per line to <records-file> and its completeness/provenance proof to
# <records-file>.meta. Deduplicates by <id-field>, which must be present on
# every record: a collection whose members carry no immutable identity cannot be
# deduplicated across a shifting page window, so its absence is schema movement
# rather than a record to keep.
#
# CRASH AND RETRY SAFETY. The record set is written to a private temporary file
# and renamed into place, and the .meta proof is renamed LAST. The proof's
# presence is therefore the commit point: a record set found without one is the
# remains of an interrupted read, and fm_retrieval_load reports it as
# state_uncommitted rather than as a complete set of whatever survived. Re-running
# with the same path is idempotent because both renames replace atomically.
fm_retrieval_fetch() {  # <first-url> <records-file> <id-field> [max-pages] [max-records] [text-field] [time-field]
  local url=$1 records=$2 id_field=$3
  local max_pages=${4:-${FM_RETRIEVAL_MAX_PAGES:-50}}
  local max_records=${5:-0}
  local text_field=${6:-} time_field=${7:-}
  local tmp headers body pages=0 next rc seen_file out_file
  local page_records total=0 dups=0 attempts record_bound_hit=0

  case "$max_pages" in ''|*[!0-9]*|0) max_pages=${FM_RETRIEVAL_MAX_PAGES:-50} ;; esac
  case "$max_records" in ''|*[!0-9]*) max_records=0 ;; esac

  command -v jq >/dev/null 2>&1 || {
    fm_retrieval_set_reason transport_unavailable "jq is not on PATH"
    return 1
  }

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-retrieval.XXXXXX") || {
    fm_retrieval_set_reason usage_error "could not create a working directory"
    return 1
  }
  headers=$tmp/headers
  body=$tmp/body
  seen_file=$tmp/seen
  out_file=$tmp/records
  : > "$seen_file"
  : > "$out_file"
  : > "$tmp/pages.json"

  FM_RETRIEVAL_REASON=
  FM_RETRIEVAL_COMPLETENESS=

  while :; do
    FM_RETRIEVAL_LAST_ATTEMPTS=1
    if ! fm_retrieval_fetch_page "$url" "$headers" "$body"; then
      break
    fi
    attempts=$FM_RETRIEVAL_LAST_ATTEMPTS
    pages=$((pages + 1))

    # The body must be a JSON array of objects each carrying the identity
    # field. Anything else - an envelope, a scalar, an error object with a 200 -
    # is schema movement, and reading it as zero records is the defect one level
    # down from the one this file exists to stop.
    if ! jq -e 'type == "array"' "$body" >/dev/null 2>&1; then
      fm_retrieval_set_reason schema_unexpected \
        "page $pages was not a JSON array"
      break
    fi
    jq -c '.[]' "$body" > "$tmp/page-records" || {
      fm_retrieval_set_reason schema_unexpected \
        "page $pages could not be read as records"
      break
    }
    fm_retrieval_validate_records "$tmp/page-records" "$id_field" \
      "$text_field" "$time_field" "page $pages" || break

    page_records=$(jq 'length' "$body")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local this_id
      this_id=$(fm_retrieval_field "$line" "$id_field")
      if grep -qxF -- "$this_id" "$seen_file" 2>/dev/null; then
        dups=$((dups + 1))
        continue
      fi
      if [ "$max_records" -gt 0 ] && [ "$total" -ge "$max_records" ]; then
        record_bound_hit=1
        break
      fi
      printf '%s\n' "$this_id" >> "$seen_file"
      printf '%s\n' "$line" >> "$out_file"
      total=$((total + 1))
    done < <(jq -c '.[]' "$body")

    jq -cn --arg url "$url" --argjson n "$page_records" --argjson a "$attempts" \
      '{url: $url, records: $n, attempts: $a, status: 200}' >> "$tmp/pages.json"

    if [ "$record_bound_hit" = 1 ]; then
      fm_retrieval_set_reason record_bound_reached \
        "the unique-record bound of $max_records was reached during page $pages"
      break
    fi

    if [ -n "${FM_RETRIEVAL_FORCE_LINK:-}" ] && [ "$pages" = 1 ]; then
      printf 'Link: %s\n' "$FM_RETRIEVAL_FORCE_LINK" >> "$headers"
    fi
    rc=0
    next=$(fm_retrieval_next_link "$(cat "$headers")") || rc=$?
    if [ "$rc" = 2 ]; then
      fm_retrieval_set_reason continuation_unreadable \
        "page $pages published a continuation this reader cannot follow"
      break
    fi
    if [ -z "$next" ]; then
      fm_retrieval_set_reason enumerated \
        "the source published no continuation after page $pages"
      break
    fi
    if [ "$max_records" -gt 0 ] && [ "$total" -ge "$max_records" ]; then
      fm_retrieval_set_reason record_bound_reached \
        "the record bound of $max_records was reached with a continuation left"
      break
    fi
    if [ "$pages" -ge "$max_pages" ]; then
      fm_retrieval_set_reason page_bound_reached \
        "the page bound of $max_pages was reached with a continuation left"
      break
    fi
    url=$next
  done

  FM_RETRIEVAL_PAGES=$pages
  FM_RETRIEVAL_RECORDS=$total
  FM_RETRIEVAL_DUPLICATES=$dups
  [ -n "$FM_RETRIEVAL_REASON" ] || fm_retrieval_set_reason page_unreadable \
    "the traversal ended without a reason, which is itself unobserved"

  fm_retrieval_publish "$records" "$out_file" "$tmp/pages.json" "$tmp/proof.json"
  rc=$?
  FM_RETRIEVAL_RECORDS_FILE=$out_file
  FM_RETRIEVAL_SNAPSHOT_DIR=$tmp
  [ -f "$tmp/proof.json" ] && FM_RETRIEVAL_PROVENANCE=$tmp/proof.json
  return "$rc"
}

fm_retrieval_validate_records() {  # <jsonl-records> <id-field> <text-field> <time-field> <source>
  local records=$1 id_field=$2 text_field=$3 time_field=$4 source=$5 required_field
  for required_field in "$id_field" "$text_field" "$time_field"; do
    [ -n "$required_field" ] || continue
    if ! jq -se --arg f "$required_field" \
      "all(.[]; ($FM_RETRIEVAL_HAS_FIELD_EXPR))" \
      "$records" >/dev/null 2>&1; then
      fm_retrieval_set_reason schema_unexpected \
        "$source carried a record with no $required_field"
      return 1
    fi
  done
  return 0
}

# Publish the payload and then its proof, proof LAST. The ordering is the commit
# point the whole crash-safety contract rests on, so it is stated here once and
# every payload shape goes through it rather than restating it.
#
# The meta is built by a caller-supplied builder rather than here, because a
# collection proof and a public-content proof are genuinely different shapes and
# a single function trying to be both would carry fields neither one means. The
# builder receives the digest this function bound to the staged bytes, so no
# caller can publish a proof describing bytes it did not measure.
fm_retrieval_commit() {  # <payload-path> <staged-payload> <retained-proof|-> <meta-builder> [builder-args...]
  local payload=$1 staged=$2 retained_proof=$3 builder=$4
  local dir meta digest publish_dir
  shift 4
  [ "$retained_proof" = '-' ] && retained_proof=
  dir=$(dirname "$payload")
  [ -d "$dir" ] || mkdir -p "$dir" || {
    fm_retrieval_set_reason usage_error "cannot write to $dir"
    return 1
  }
  meta=$payload.meta
  publish_dir=$(mktemp -d "$dir/.fm-retrieval-publish.XXXXXX") || {
    fm_retrieval_set_reason state_uncommitted "cannot create private publication staging"
    return 1
  }

  cp "$staged" "$publish_dir/payload" || {
    fm_retrieval_set_reason usage_error "cannot stage the payload at $payload"
    rm -rf "$publish_dir"
    return 1
  }
  digest=$(fm_retrieval_sha256 "$publish_dir/payload") || {
    fm_retrieval_set_reason state_uncommitted \
      "the staged payload could not be bound to a SHA-256 digest"
    rm -rf "$publish_dir"
    return 1
  }

  "$builder" "sha256:$digest" "$publish_dir/meta" "$@" || {
    fm_retrieval_set_reason usage_error "cannot stage the completeness proof"
    rm -rf "$publish_dir"
    return 1
  }
  if [ -n "$retained_proof" ]; then
    cp "$publish_dir/meta" "$retained_proof" || {
      fm_retrieval_set_reason state_uncommitted "cannot retain this attempt's proof"
      rm -rf "$publish_dir"
      return 1
    }
  fi
  rm -f "$meta"
  mv -f "$publish_dir/payload" "$payload" || {
    rm -rf "$publish_dir"
    fm_retrieval_set_reason state_uncommitted "cannot publish the payload at $payload"
    return 1
  }
  if [ "${FM_RETRIEVAL_TEST_KILL_AFTER_RECORDS:-0}" = 1 ]; then
    kill -KILL "$$"
  fi
  mv -f "$publish_dir/meta" "$meta" || {
    rm -rf "$publish_dir"
    fm_retrieval_set_reason usage_error "cannot publish the completeness proof"
    return 1
  }
  rm -rf "$publish_dir"
  FM_RETRIEVAL_PROVENANCE=${retained_proof:-$meta}
  return 0
}

# The collection proof shape. Called by fm_retrieval_commit with the digest it
# bound to the staged record set.
fm_retrieval_collection_meta() {  # <digest> <out> <staged-pages>
  local digest=$1 out=$2 pages_file=$3 observed
  observed=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
  jq -cn \
    --arg schema "$FM_RETRIEVAL_SCHEMA" \
    --arg retrieval "$FM_RETRIEVAL_COMPLETENESS" \
    --arg reason "$FM_RETRIEVAL_REASON" \
    --arg detail "$FM_RETRIEVAL_DETAIL" \
    --arg observed "$observed" \
    --arg reader "${FM_RETRIEVAL_GH:-gh}" \
    --arg digest "$digest" \
    --argjson records "$FM_RETRIEVAL_RECORDS" \
    --argjson duplicates "$FM_RETRIEVAL_DUPLICATES" \
    --slurpfile pages "$pages_file" \
    '{schema: $schema, retrieval: $retrieval, reason: $reason, detail: $detail,
      observed_at: $observed, reader: $reader, record_digest: $digest, records: $records,
      duplicates: $duplicates, pages: $pages}' > "$out"
}

# Publish the record set and then its proof, proof last. Called by fetch; the
# ordering itself lives in fm_retrieval_commit so it cannot be reordered by
# editing the traversal.
fm_retrieval_publish() {  # <records-file> <staged-records> <staged-pages> [retained-proof]
  fm_retrieval_commit "$1" "$2" "${4:--}" fm_retrieval_collection_meta "$3"
}

fm_retrieval_sha256() {  # <file>
  local output digest
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 "$1" 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum "$1" 2>/dev/null) || return 1
  else
    return 1
  fi
  digest=${output%%[[:space:]]*}
  printf '%s\n' "$digest" | grep -Eq '^[0-9a-fA-F]{64}$' || return 1
  printf '%s\n' "$digest"
}

# fm_retrieval_load <records-file>: adopt a previously published read. The proof
# is required: a record set with none is an interrupted write, and the count of
# whatever survived is not a fact about the collection.
fm_retrieval_load() {  # <records-file>
  local records=$1 meta=$1.meta expected_digest actual_digest snapshot
  if [ ! -f "$records" ]; then
    fm_retrieval_set_reason state_uncommitted "no record set at $records"
    return 1
  fi
  if [ ! -f "$meta" ]; then
    fm_retrieval_set_reason state_uncommitted \
      "$records carries no completeness proof, so its extent is unknown"
    FM_RETRIEVAL_RECORDS_FILE=$records
    return 1
  fi
  snapshot=$(mktemp -d "${TMPDIR:-/tmp}/fm-retrieval-snapshot.XXXXXX") || {
    fm_retrieval_set_reason state_uncommitted "could not create a replay snapshot"
    return 1
  }
  if ! cp "$records" "$snapshot/records" || ! cp "$meta" "$snapshot/meta"; then
    rm -rf "$snapshot"
    fm_retrieval_set_reason state_uncommitted "could not copy a replay snapshot"
    return 1
  fi
  records=$snapshot/records
  meta=$snapshot/meta
  FM_RETRIEVAL_SNAPSHOT_DIR=$snapshot
  if ! jq -e --arg s "$FM_RETRIEVAL_SCHEMA" '.schema == $s' "$meta" >/dev/null 2>&1; then
    fm_retrieval_set_reason schema_unexpected \
      "$meta is not a $FM_RETRIEVAL_SCHEMA proof"
    return 1
  fi
  expected_digest=$(jq -r '.record_digest // empty' "$meta" 2>/dev/null)
  case "$expected_digest" in
    sha256:????????????????????????????????????????????????????????????????) ;;
    *)
      fm_retrieval_set_reason state_uncommitted \
        "$meta carries no usable record digest"
      return 1
      ;;
  esac
  printf '%s\n' "${expected_digest#sha256:}" \
    | grep -Eq '^[0-9a-fA-F]{64}$' || {
      fm_retrieval_set_reason state_uncommitted \
        "$meta carries a malformed record digest"
      return 1
    }
  actual_digest=$(fm_retrieval_sha256 "$records") || {
    fm_retrieval_set_reason state_uncommitted \
      "$records could not be checked against its record digest"
    return 1
  }
  if [ "$expected_digest" != "sha256:$actual_digest" ]; then
    fm_retrieval_set_reason state_uncommitted \
      "$records does not match the record digest in $meta"
    return 1
  fi
  fm_retrieval_set_reason "$(jq -r '.reason' "$meta")" "$(jq -r '.detail' "$meta")" || return 1
  FM_RETRIEVAL_RECORDS=$(jq -r '.records' "$meta")
  FM_RETRIEVAL_DUPLICATES=$(jq -r '.duplicates' "$meta")
  FM_RETRIEVAL_PAGES=$(jq -r '.pages | length' "$meta")
  FM_RETRIEVAL_RECORDS_FILE=$records
  FM_RETRIEVAL_PROVENANCE=$meta
  return 0
}

# --- public-content retrieval ------------------------------------------------
#
# A SECOND TRANSPORT UNDER THE SAME TYPE, NOT A SECOND TYPE.
#
# Everything above reads an authenticated GitHub COLLECTION, where the question
# is "was the whole candidate universe enumerated". This section reads one
# PUBLIC DOCUMENT, where the question is "were the whole bytes received". Those
# are different subjects and they share one completeness algebra, one closed
# reason vocabulary, one commit ordering, and one provenance discipline, so a
# caller cannot get a weaker guarantee by picking the other door. The GitHub
# collection path is untouched by anything below it.
#
# WHAT MAKES THIS DANGEROUS ENOUGH TO NEED A STATE MACHINE
#
# When a public fetch is refused, the tempting repair is to send a different
# User-Agent until something answers. That move is correct for exactly one
# cause - a filter on the client string - and is an access-control bypass for
# every other cause. A refusal that is really a paywall, a login boundary, a
# geographic block, a CAPTCHA, or a revoked credential does not become lawful
# because a second identity got through, and a 403 that says nothing at all does
# not license guessing which it was.
#
# So the ladder moves only on POSITIVE evidence of client filtering, never on
# the absence of evidence for anything else. Silence is a refusal, not a permit.
#
# THE CLOSED ATTEMPT ORDER
#
#   1. NORMAL                       ordinary client identity.
#   2. BROWSER_COMPAT_RETRIEVAL     at most one, and only after attempt 1 was
#                                   positively typed as client filtering.
#   3. AUTHORIZED_BRANDED_RETRIEVAL at most one, and only after attempts 1 and 2
#                                   both failed AND attempt 2 was still
#                                   positively typed as client filtering rather
#                                   than an access boundary.
#
# The third profile's exact User-Agent is a Captain authorization, not this
# fleet's identity. It is spelled once, in fm_retrieval_public_profile_ua, and
# tests/fm-retrieval-public-content.test.sh carries a calibrated control that
# goes red if that exact string ever changes.
#
# WHAT A FALLBACK SUCCESS DOES NOT PROVE
#
# This is the failure mode the whole section exists to stop. Bytes obtained on
# profile 2 or 3 answer "can this content be retrieved at all". They do NOT
# answer "is this reachable by a default client", "is this normally
# accessible", "is the authenticated API behaving", or "is there no bot
# filtering here" - and a fallback success is in fact positive evidence that
# filtering exists. Crediting a fallback result to a default-client verifier is
# a wrong-subject conclusion, so fm_retrieval_public_supports refuses those
# claims structurally and the published proof carries the same refusal in
# cannot_establish. Nothing here lets a caller ask a narrower question and have
# the answer credited to the wider one.
#
# EXCLUDED CALLERS
#
# The caller declares its own context and the ladder is capped at NORMAL for
# every context except public-content. Authenticated forge and provider API
# reads, installers, and application, auth, security, client-compatibility and
# behavior test contexts must never have a substituted client identity blur what
# they are measuring. An unknown context is a usage error, not a permissive
# default: this fails closed.
#
# CONFIGURATION
#   FM_RETRIEVAL_PUBLIC_CURL          transport command (default: curl)
#   FM_RETRIEVAL_PUBLIC_MAX_BYTES     body byte bound (default 5000000)
#   FM_RETRIEVAL_PUBLIC_TIMEOUT       per-request wall-clock seconds (default 30)
#   FM_RETRIEVAL_PUBLIC_MAX_REDIRECTS redirect hops per attempt (default 5)
#   FM_RETRIEVAL_PUBLIC_RATE_RETRIES  bounded 429 retries per profile (default 2)
#   FM_RETRIEVAL_PUBLIC_MAX_RETRY_AFTER  cap on an honored Retry-After (default 30)
#   FM_RETRIEVAL_PUBLIC_SENSITIVE     strip|refuse on a cross-origin redirect
#                                     carrying authorization or cookie material
#                                     (default strip)
#   FM_RETRIEVAL_SLEEP                shared with the collection path

FM_RETRIEVAL_PUBLIC_SCHEMA=fm-retrieval-public.v1

# The closed profile ladder, in order. Nothing outside this list is a profile.
FM_RETRIEVAL_PUBLIC_LADDER='NORMAL BROWSER_COMPAT_RETRIEVAL AUTHORIZED_BRANDED_RETRIEVAL'

# The closed claim vocabulary a caller may ask a public result to support.
FM_RETRIEVAL_PUBLIC_CLAIMS='content-retrieved default-client-compatible normal-client-accessible authenticated-api-correct no-bot-filtering'

FM_RETRIEVAL_PUBLIC_PROFILE=
FM_RETRIEVAL_PUBLIC_ATTEMPTS=0
FM_RETRIEVAL_PUBLIC_REQUESTS=0
FM_RETRIEVAL_PUBLIC_STATUS=
FM_RETRIEVAL_PUBLIC_URL=
FM_RETRIEVAL_PUBLIC_FINAL_URL=
FM_RETRIEVAL_PUBLIC_FINAL_ORIGIN=
FM_RETRIEVAL_PUBLIC_BYTES=0
FM_RETRIEVAL_PUBLIC_CLASS=
FM_RETRIEVAL_PUBLIC_CONTEXT=
FM_RETRIEVAL_PUBLIC_REDIRECTS=0
FM_RETRIEVAL_PUBLIC_STRIPPED=0
FM_RETRIEVAL_PUBLIC_FILTER_OBSERVED=0
FM_RETRIEVAL_PUBLIC_FALLBACK_BLOCKED=
FM_RETRIEVAL_PUBLIC_BODY_FILE=
FM_RETRIEVAL_PUBLIC_BODY_PUBLISHED=false
FM_RETRIEVAL_PUBLIC_NOTE=
FM_RETRIEVAL_PUBLIC_LAST_RC=0
FM_RETRIEVAL_PUBLIC_LAST_CODE=

fm_retrieval_public_reset() {
  FM_RETRIEVAL_PUBLIC_PROFILE=
  FM_RETRIEVAL_PUBLIC_ATTEMPTS=0
  FM_RETRIEVAL_PUBLIC_REQUESTS=0
  FM_RETRIEVAL_PUBLIC_STATUS=
  FM_RETRIEVAL_PUBLIC_URL=
  FM_RETRIEVAL_PUBLIC_FINAL_URL=
  FM_RETRIEVAL_PUBLIC_FINAL_ORIGIN=
  FM_RETRIEVAL_PUBLIC_BYTES=0
  FM_RETRIEVAL_PUBLIC_CLASS=
  FM_RETRIEVAL_PUBLIC_CONTEXT=
  FM_RETRIEVAL_PUBLIC_REDIRECTS=0
  FM_RETRIEVAL_PUBLIC_STRIPPED=0
  FM_RETRIEVAL_PUBLIC_FILTER_OBSERVED=0
  FM_RETRIEVAL_PUBLIC_FALLBACK_BLOCKED=
  FM_RETRIEVAL_PUBLIC_BODY_FILE=
  FM_RETRIEVAL_PUBLIC_BODY_PUBLISHED=false
  FM_RETRIEVAL_PUBLIC_NOTE=
  FM_RETRIEVAL_PUBLIC_LAST_RC=0
  FM_RETRIEVAL_PUBLIC_LAST_CODE=
}

# The exact client identity each profile transmits. This is the single place
# any of the three strings is spelled.
#
# The third is a Captain authorization carried verbatim, not a name this fleet
# chose for itself, which is why it is recorded in the proof as an authorization
# rather than as an identity.
fm_retrieval_public_profile_ua() {  # <profile>
  case "${1:-}" in
    NORMAL) printf 'firstmate-retrieval/1.0' ;;
    BROWSER_COMPAT_RETRIEVAL) printf 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' ;;
    AUTHORIZED_BRANDED_RETRIEVAL) printf 'OpenAI File Downloader, XaiImageApiFetch/1.0' ;;
    *) return 1 ;;
  esac
}

# Whether a caller context may climb the ladder at all.
#   0  may fall back            1  capped at NORMAL            2  unknown context
#
# The excluded list is the inventoried caller classes whose subject a
# substituted client identity would blur: an authenticated forge or provider
# API, a fixed release-asset installer, and every application, auth, security,
# client-compatibility and behavior test context.
fm_retrieval_public_context_allows_fallback() {  # <context>
  case "${1:-}" in
    public-content) return 0 ;;
    authenticated-api|provider-api|installer|auth|security|\
    client-compatibility|behavior-test|application-test) return 1 ;;
    *) return 2 ;;
  esac
}

# scheme://host:port with the default port made explicit and the host folded to
# lower case, so "same origin" is a comparison and not a guess. Userinfo is
# dropped because it is not part of the origin.
fm_retrieval_public_origin() {  # <url>
  local url=${1:-} scheme rest hostport
  case "$url" in
    https://*) scheme=https; rest=${url#https://} ;;
    http://*) scheme=http; rest=${url#http://} ;;
    *) return 1 ;;
  esac
  hostport=${rest%%/*}
  hostport=${hostport%%\?*}
  hostport=${hostport%%#*}
  case "$hostport" in *@*) hostport=${hostport##*@} ;; esac
  [ -n "$hostport" ] || return 1
  case "$hostport" in
    *:*) ;;
    *) if [ "$scheme" = https ]; then hostport=$hostport:443; else hostport=$hostport:80; fi ;;
  esac
  printf '%s://%s' "$scheme" "$(printf '%s' "$hostport" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
}

# Resolve a Location against the URL that produced it. Returns 1 for a target
# this reader will not follow, which is a refusal rather than a rewrite.
fm_retrieval_public_resolve() {  # <base-url> <location>
  local base=${1:-} loc=${2:-} scheme rest authority path
  [ -n "$loc" ] || return 1
  case "$loc" in
    http://*|https://*) printf '%s' "$loc"; return 0 ;;
  esac
  case "$base" in
    https://*) scheme=https; rest=${base#https://} ;;
    http://*) scheme=http; rest=${base#http://} ;;
    *) return 1 ;;
  esac
  authority=${rest%%/*}
  case "$rest" in
    */*) path=/${rest#*/} ;;
    *) path=/ ;;
  esac
  path=${path%%\?*}
  path=${path%%#*}
  case "$loc" in
    //*) printf '%s:%s' "$scheme" "$loc" ;;
    /*) printf '%s://%s%s' "$scheme" "$authority" "$loc" ;;
    *:*) return 1 ;;
    *) printf '%s://%s%s/%s' "$scheme" "$authority" "${path%/*}" "$loc" ;;
  esac
  return 0
}

FM_RETRIEVAL_PUBLIC_SENSITIVE_ERE='^(authorization|proxy-authorization|cookie)[[:space:]]*:'

fm_retrieval_public_has_sensitive() {  # <request-headers-file>
  [ -s "${1:-}" ] || return 1
  grep -qiE "$FM_RETRIEVAL_PUBLIC_SENSITIVE_ERE" "$1"
}

fm_retrieval_public_strip_sensitive() {  # <in> <out>
  grep -viE "$FM_RETRIEVAL_PUBLIC_SENSITIVE_ERE" "$1" > "$2" 2>/dev/null || :
  return 0
}

# --- classification ----------------------------------------------------------
#
# The marker sets below are read against the response headers and a bounded head
# of the body, folded to lower case.
#
# PRECEDENCE IS THE SAFETY PROPERTY, not the marker lists. A page can carry a
# bot-vendor banner AND a CAPTCHA, or a filter phrase AND a login wall. Every
# such overlap must resolve to the answer that permits LESS, so challenge and
# access boundaries are tested before client filtering and win outright. A
# marker list that is too narrow costs a retrieval; a precedence order that is
# wrong costs an access-control bypass.

# Two challenge sets, because the word and the wall are different facts. A page
# that IS an interstitial says so structurally, and that reading holds at any
# status - challenge walls are served as 200 as readily as 403. A page that
# merely CONTAINS "captcha" is usually a document about captchas, so that
# reading is admitted only at a status that already refused the request.
# Collapsing the two would either refuse ordinary prose or accept a wall as
# content, and both are wrong-subject answers.
FM_RETRIEVAL_PUBLIC_CHALLENGE_ERE='verify (that )?you are (a )?human|are you a robot|checking your browser'
FM_RETRIEVAL_PUBLIC_CHALLENGE_ERE=$FM_RETRIEVAL_PUBLIC_CHALLENGE_ERE'|cf-chl|cf-mitigated:[[:space:]]*challenge|challenge-platform|challenge required'
FM_RETRIEVAL_PUBLIC_CHALLENGE_ERE=$FM_RETRIEVAL_PUBLIC_CHALLENGE_ERE'|enable javascript and cookies to continue|complete the security check'

FM_RETRIEVAL_PUBLIC_CHALLENGE_TOPICAL_ERE='captcha|recaptcha|hcaptcha|turnstile'

FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE='www-authenticate:|proxy-authenticate:'
FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE=$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE'|unauthori(z|s)ed|not authori(z|s)ed|authentication required'
FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE=$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE'|permission denied|access denied|access is denied|insufficient (permission|scope|privilege)'
FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE=$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE'|login required|please (log|sign) in|sign in to (view|read|continue)|log in to (view|read|continue)'
FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE=$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE'|invalid (api )?(key|token|credential)|revoked (key|token|credential)'
FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE=$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE'|subscription required|subscriber[- ]only|paywall|premium (content|article)|metered'
FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE=$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE'|not available in your (country|region|location)|geo[- ]?(restricted|blocked)|geographic restriction'
FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE=$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE'|session (expired|invalid)|invalid session|access control|acl denied'
FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE=$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE'|ip (address )?(blocked|banned|not allowed)'

FM_RETRIEVAL_PUBLIC_FILTER_ERE='automated (client|traffic|request|access|tool)'
FM_RETRIEVAL_PUBLIC_FILTER_ERE=$FM_RETRIEVAL_PUBLIC_FILTER_ERE'|bot (detected|protection|management|traffic)|anti-?bot'
FM_RETRIEVAL_PUBLIC_FILTER_ERE=$FM_RETRIEVAL_PUBLIC_FILTER_ERE'|(unsupported|unrecognized|invalid|blocked|missing) user[ -]?agent|your user[ -]?agent'
FM_RETRIEVAL_PUBLIC_FILTER_ERE=$FM_RETRIEVAL_PUBLIC_FILTER_ERE'|user[ -]?agent (is )?(not )?(supported|allowed|permitted|recognized)'
FM_RETRIEVAL_PUBLIC_FILTER_ERE=$FM_RETRIEVAL_PUBLIC_FILTER_ERE'|(unsupported|outdated) browser|browser (is )?not supported|please use a (supported |modern )?browser'
FM_RETRIEVAL_PUBLIC_FILTER_ERE=$FM_RETRIEVAL_PUBLIC_FILTER_ERE'|crawlers? (are |is )?not allowed|scraping (is )?(not allowed|prohibited|detected)|scraper detected'

# The bounded head of the response this classifier is allowed to read. A refusal
# page states its cause early, and an unbounded read would hand a hostile body
# control over how long classification takes.
FM_RETRIEVAL_PUBLIC_CLASSIFY_BYTES=65536

fm_retrieval_public_haystack() {  # <headers-file> <body-file>
  { cat "${1:-/dev/null}" 2>/dev/null
    head -c "$FM_RETRIEVAL_PUBLIC_CLASSIFY_BYTES" "${2:-/dev/null}" 2>/dev/null
  } | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -d '\r'
}

# fm_retrieval_public_classify <status> <headers-file> <body-file>: the closed
# class vocabulary, printed on stdout.
#
#   ok           2xx with a body inside the bounds
#   not_found    404
#   access_denied  401, 407, 451, or a positively identified access boundary
#   challenge    an interstitial challenge, structurally identified at any
#                status, or a CAPTCHA named on a response that already refused
#   client_filter  positively identified filtering on the client string, and
#                nothing that identifies a boundary or a challenge
#   rate_limited 429
#   server_error 5xx
#   ambiguous    403 or 406 that identifies nothing; could-not-observe
#   http_error   any other status this reader will not interpret
#   malformed    no readable status at all
fm_retrieval_public_classify() {  # <status> <headers-file> <body-file>
  local status=${1:-} headers=${2:-} body=${3:-} hay
  case "$status" in
    ''|*[!0-9]*) printf 'malformed'; return 0 ;;
  esac
  hay=$(fm_retrieval_public_haystack "$headers" "$body")
  case "$status" in
    401|407) printf 'access_denied'; return 0 ;;
  esac
  if printf '%s' "$hay" | grep -qE "$FM_RETRIEVAL_PUBLIC_CHALLENGE_ERE"; then
    printf 'challenge'; return 0
  fi
  case "$status" in
    2??) printf 'ok'; return 0 ;;
  esac
  if printf '%s' "$hay" | grep -qE "$FM_RETRIEVAL_PUBLIC_CHALLENGE_TOPICAL_ERE"; then
    printf 'challenge'; return 0
  fi
  case "$status" in
    404) printf 'not_found'; return 0 ;;
    451) printf 'access_denied'; return 0 ;;
  esac
  if printf '%s' "$hay" | grep -qE "$FM_RETRIEVAL_PUBLIC_BOUNDARY_ERE"; then
    printf 'access_denied'; return 0
  fi
  case "$status" in
    403|406)
      if printf '%s' "$hay" | grep -qE "$FM_RETRIEVAL_PUBLIC_FILTER_ERE"; then
        printf 'client_filter'
      else
        printf 'ambiguous'
      fi
      return 0
      ;;
    429) printf 'rate_limited'; return 0 ;;
    5??) printf 'server_error'; return 0 ;;
  esac
  printf 'http_error'
}

# The total class-to-reason mapping. Kept beside the classifier so a new class
# cannot be introduced without answering what it means for completeness.
fm_retrieval_public_reason_of() {  # <class>
  case "${1:-}" in
    ok) printf 'body_complete' ;;
    transport_absent) printf 'transport_unavailable' ;;
    not_found) printf 'subject_unreadable' ;;
    access_denied) printf 'access_boundary' ;;
    challenge) printf 'challenge_presented' ;;
    client_filter) printf 'client_filtered' ;;
    rate_limited) printf 'rate_limited' ;;
    server_error|http_error|unreachable) printf 'page_unreadable' ;;
    ambiguous) printf 'ambiguous_refusal' ;;
    malformed) printf 'malformed_response' ;;
    tls) printf 'tls_failed' ;;
    timeout) printf 'time_bound_reached' ;;
    too_large) printf 'byte_bound_reached' ;;
    redirect_refused) printf 'redirect_refused' ;;
    *) return 1 ;;
  esac
}

# --- one request -------------------------------------------------------------
#
# Redirects are deliberately NOT delegated to the transport. Following them here
# is what makes the cross-origin rule enforceable at all: the decision to strip
# or refuse authorization and cookie material has to happen BEFORE the next hop
# is transmitted, and a transport following redirects internally has already
# sent them by the time this code could look.
#
# TLS is never retried insecurely. There is no code path below that adds a
# certificate-verification override, because "it worked without verification" is
# not a weaker version of success, it is a different and unauthorized act.
fm_retrieval_public_request() {  # <url> <profile> <headers-out> <body-out> <request-headers-file>
  local url=$1 profile=$2 hdr_out=$3 body_out=$4 req_headers=$5
  local transport ua line rc=0 code
  local -a args=()
  transport=${FM_RETRIEVAL_PUBLIC_CURL:-curl}
  command -v "$transport" >/dev/null 2>&1 || {
    FM_RETRIEVAL_PUBLIC_LAST_RC=-1
    FM_RETRIEVAL_PUBLIC_LAST_CODE=
    return 2
  }
  ua=$(fm_retrieval_public_profile_ua "$profile") || {
    FM_RETRIEVAL_PUBLIC_LAST_RC=-1
    FM_RETRIEVAL_PUBLIC_LAST_CODE=
    return 3
  }
  args+=( -sS )
  args+=( --proto '=http,https' )
  args+=( --max-time "${FM_RETRIEVAL_PUBLIC_TIMEOUT:-30}" )
  args+=( --max-filesize "${FM_RETRIEVAL_PUBLIC_MAX_BYTES:-5000000}" )
  args+=( -A "$ua" )
  args+=( -D "$hdr_out" -o "$body_out" -w '%{http_code}' )
  if [ -s "$req_headers" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      args+=( -H "$line" )
    done < "$req_headers"
  fi
  : > "$hdr_out"
  : > "$body_out"
  code=$("$transport" "${args[@]}" "$url" 2>/dev/null) || rc=$?
  FM_RETRIEVAL_PUBLIC_LAST_RC=$rc
  FM_RETRIEVAL_PUBLIC_LAST_CODE=$code
  return 0
}

# The transport's own failures, before any HTTP status exists to classify.
# Returns the class name, or 1 when the transport reported no failure.
fm_retrieval_public_transport_class() {  # <exit-code>
  case "${1:-0}" in
    0) return 1 ;;
    28) printf 'timeout' ;;
    63) printf 'too_large' ;;
    35|51|53|54|58|59|60|66|77|80|82|83|90|91) printf 'tls' ;;
    6|7|18|52|56) printf 'unreachable' ;;
    1|2|3) printf 'malformed' ;;
    *) printf 'unreachable' ;;
  esac
  return 0
}

# --- one profile attempt -----------------------------------------------------
#
# One attempt is one profile carried from the starting URL to a terminal
# response, following redirects and absorbing a bounded number of 429s WITHOUT
# moving the profile. Rate limiting is the source asking for patience, not
# evidence about client identity, so answering it with a different User-Agent
# would be reading one fact as another.
fm_retrieval_public_attempt() {  # <start-url> <profile> <work-dir> <caller-headers>
  local start_url=$1 profile=$2 work=$3 caller_headers=$4
  local url hops=0 rate_tries=0 max_hops rate_max cap
  local rc cls status location next origin_now origin_next
  local active retry_after wait_s
  url=$start_url
  active=$work/req-headers
  max_hops=${FM_RETRIEVAL_PUBLIC_MAX_REDIRECTS:-5}
  rate_max=${FM_RETRIEVAL_PUBLIC_RATE_RETRIES:-2}
  cap=${FM_RETRIEVAL_PUBLIC_MAX_RETRY_AFTER:-30}
  case "$max_hops" in ''|*[!0-9]*) max_hops=5 ;; esac
  case "$rate_max" in ''|*[!0-9]*) rate_max=2 ;; esac
  case "$cap" in ''|*[!0-9]*) cap=30 ;; esac
  : > "$active"
  if [ -s "$caller_headers" ]; then
    cp "$caller_headers" "$active" || return 1
  fi
  FM_RETRIEVAL_PUBLIC_NOTE=

  while :; do
    rc=0
    fm_retrieval_public_request "$url" "$profile" "$work/hdr" "$work/body" "$active" || rc=$?
    FM_RETRIEVAL_PUBLIC_REQUESTS=$((FM_RETRIEVAL_PUBLIC_REQUESTS + 1))
    FM_RETRIEVAL_PUBLIC_FINAL_URL=$url
    case "$rc" in
      0) ;;
      2) FM_RETRIEVAL_PUBLIC_CLASS=transport_absent
         FM_RETRIEVAL_PUBLIC_NOTE="${FM_RETRIEVAL_PUBLIC_CURL:-curl} is not on PATH"
         return 0 ;;
      *) FM_RETRIEVAL_PUBLIC_CLASS=malformed
         FM_RETRIEVAL_PUBLIC_NOTE="the transport could not be invoked for $profile"
         return 0 ;;
    esac

    cls=$(fm_retrieval_public_transport_class "$FM_RETRIEVAL_PUBLIC_LAST_RC")
    if [ -n "$cls" ]; then
      FM_RETRIEVAL_PUBLIC_CLASS=$cls
      FM_RETRIEVAL_PUBLIC_STATUS=$FM_RETRIEVAL_PUBLIC_LAST_CODE
      FM_RETRIEVAL_PUBLIC_NOTE="the transport failed with exit $FM_RETRIEVAL_PUBLIC_LAST_RC for $url"
      return 0
    fi
    status=$FM_RETRIEVAL_PUBLIC_LAST_CODE
    FM_RETRIEVAL_PUBLIC_STATUS=$status

    case "$status" in
      301|302|303|307|308)
        location=$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$work/hdr" | tr -d '\r' | head -1)
        if [ -z "$location" ]; then
          FM_RETRIEVAL_PUBLIC_CLASS=malformed
          FM_RETRIEVAL_PUBLIC_NOTE="HTTP $status carried no Location"
          return 0
        fi
        hops=$((hops + 1))
        FM_RETRIEVAL_PUBLIC_REDIRECTS=$((FM_RETRIEVAL_PUBLIC_REDIRECTS + 1))
        if [ "$hops" -gt "$max_hops" ]; then
          FM_RETRIEVAL_PUBLIC_CLASS=redirect_refused
          FM_RETRIEVAL_PUBLIC_NOTE="the redirect bound of $max_hops hops was spent"
          return 0
        fi
        next=$(fm_retrieval_public_resolve "$url" "$location") || {
          FM_RETRIEVAL_PUBLIC_CLASS=redirect_refused
          FM_RETRIEVAL_PUBLIC_NOTE="the redirect target is not an http or https URL"
          return 0
        }
        origin_now=$(fm_retrieval_public_origin "$url") || origin_now=
        origin_next=$(fm_retrieval_public_origin "$next") || origin_next=
        if [ -z "$origin_next" ]; then
          FM_RETRIEVAL_PUBLIC_CLASS=redirect_refused
          FM_RETRIEVAL_PUBLIC_NOTE="the redirect target has no readable origin"
          return 0
        fi
        if [ "$origin_now" != "$origin_next" ]; then
          # A cross-origin hop that also drops TLS is refused outright: the
          # bytes would arrive over a channel the first origin's guarantee does
          # not cover, and no header discipline repairs that.
          case "$url" in
            https://*)
              case "$next" in
                http://*)
                  FM_RETRIEVAL_PUBLIC_CLASS=redirect_refused
                  FM_RETRIEVAL_PUBLIC_NOTE="the redirect downgrades $origin_now to $origin_next"
                  return 0
                  ;;
              esac
              ;;
          esac
          if fm_retrieval_public_has_sensitive "$active"; then
            if [ "${FM_RETRIEVAL_PUBLIC_SENSITIVE:-strip}" = refuse ]; then
              FM_RETRIEVAL_PUBLIC_CLASS=redirect_refused
              FM_RETRIEVAL_PUBLIC_NOTE="authorization or cookie material must not cross from $origin_now to $origin_next"
              return 0
            fi
            fm_retrieval_public_strip_sensitive "$active" "$work/req-stripped"
            mv -f "$work/req-stripped" "$active" || return 1
            FM_RETRIEVAL_PUBLIC_STRIPPED=1
          fi
        fi
        url=$next
        continue
        ;;
    esac

    cls=$(fm_retrieval_public_classify "$status" "$work/hdr" "$work/body")
    if [ "$cls" = rate_limited ]; then
      rate_tries=$((rate_tries + 1))
      if [ "$rate_tries" -gt "$rate_max" ]; then
        FM_RETRIEVAL_PUBLIC_CLASS=rate_limited
        FM_RETRIEVAL_PUBLIC_NOTE="the source rate-limited $url through $rate_tries bounded retries on $profile"
        return 0
      fi
      retry_after=$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' "$work/hdr" | tr -d '\r' | head -1)
      case "$retry_after" in
        ''|*[!0-9]*)
          wait_s=$(awk -v ms="${FM_RETRIEVAL_PUBLIC_BACKOFF_MS:-400}" -v n="$rate_tries" \
            'BEGIN { printf "%.3f", (ms * (2 ^ (n - 1))) / 1000 }')
          ;;
        *)
          if [ "$retry_after" -gt "$cap" ]; then
            # Waiting less than the source asked and asking again is not a
            # bounded retry, it is ignoring the answer. Stop instead.
            FM_RETRIEVAL_PUBLIC_CLASS=rate_limited
            FM_RETRIEVAL_PUBLIC_NOTE="the source asked for ${retry_after}s, beyond this reader's ${cap}s bound"
            return 0
          fi
          wait_s=$retry_after
          ;;
      esac
      "${FM_RETRIEVAL_SLEEP:-sleep}" "$wait_s" >/dev/null 2>&1 || true
      continue
    fi
    FM_RETRIEVAL_PUBLIC_CLASS=$cls
    return 0
  done
}

# --- what a public result may be credited with -------------------------------
#
# The single fold. The published proof's cannot_establish list is computed from
# this function rather than restated, so a verifier reading the proof and a
# caller asking in process cannot disagree.
#
#   0 supported    1 not supported    2 not a claim in the vocabulary
fm_retrieval_public_supports() {  # <claim>
  case "${1:-}" in
    content-retrieved)
      [ "$FM_RETRIEVAL_COMPLETENESS" = complete ] || return 1
      return 0
      ;;
    default-client-compatible|normal-client-accessible)
      # Bytes obtained under a substituted client identity say nothing about
      # what a default client would receive. This is the wrong-subject refusal.
      [ "$FM_RETRIEVAL_COMPLETENESS" = complete ] || return 1
      [ "$FM_RETRIEVAL_PUBLIC_PROFILE" = NORMAL ] || return 1
      return 0
      ;;
    authenticated-api-correct)
      # This entrypoint never speaks to an authenticated API, so no result it
      # produces is evidence about one, however it was obtained.
      return 1
      ;;
    no-bot-filtering)
      # A fallback success is positive evidence that filtering EXISTS, so it is
      # the strongest possible refusal of this claim rather than a weak pass.
      [ "$FM_RETRIEVAL_COMPLETENESS" = complete ] || return 1
      [ "$FM_RETRIEVAL_PUBLIC_PROFILE" = NORMAL ] || return 1
      [ "$FM_RETRIEVAL_PUBLIC_FILTER_OBSERVED" = 0 ] || return 1
      return 0
      ;;
    *) return 2 ;;
  esac
}

# The public-content proof shape, built by fm_retrieval_commit with the digest
# it bound to the published bytes.
fm_retrieval_public_meta() {  # <digest> <out>
  local digest=$1 out=$2 observed authorization ua cannot claim
  local -a claims=()
  observed=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
  ua=$(fm_retrieval_public_profile_ua "$FM_RETRIEVAL_PUBLIC_PROFILE" 2>/dev/null) || ua=
  if [ "$FM_RETRIEVAL_PUBLIC_PROFILE" = AUTHORIZED_BRANDED_RETRIEVAL ]; then
    authorization=captain-authorized-exact-string
  else
    authorization=fleet-default-identity
  fi
  read -r -a claims <<< "$FM_RETRIEVAL_PUBLIC_CLAIMS"
  cannot=$(
    for claim in "${claims[@]}"; do
      fm_retrieval_public_supports "$claim" || printf '%s\n' "$claim"
    done | jq -R . | jq -sc .
  ) || return 1
  jq -cn \
    --arg schema "$FM_RETRIEVAL_PUBLIC_SCHEMA" \
    --arg retrieval "$FM_RETRIEVAL_COMPLETENESS" \
    --arg reason "$FM_RETRIEVAL_REASON" \
    --arg detail "$FM_RETRIEVAL_DETAIL" \
    --arg observed "$observed" \
    --arg context "$FM_RETRIEVAL_PUBLIC_CONTEXT" \
    --arg profile "$FM_RETRIEVAL_PUBLIC_PROFILE" \
    --arg ua "$ua" \
    --arg authorization "$authorization" \
    --arg requested_url "$FM_RETRIEVAL_PUBLIC_URL" \
    --arg final_url "$FM_RETRIEVAL_PUBLIC_FINAL_URL" \
    --arg final_origin "$FM_RETRIEVAL_PUBLIC_FINAL_ORIGIN" \
    --arg status "$FM_RETRIEVAL_PUBLIC_STATUS" \
    --arg classification "$FM_RETRIEVAL_PUBLIC_CLASS" \
    --arg fallback_blocked "$FM_RETRIEVAL_PUBLIC_FALLBACK_BLOCKED" \
    --arg transport "${FM_RETRIEVAL_PUBLIC_CURL:-curl}" \
    --arg digest "$digest" \
    --argjson attempts "$FM_RETRIEVAL_PUBLIC_ATTEMPTS" \
    --argjson requests "$FM_RETRIEVAL_PUBLIC_REQUESTS" \
    --argjson bytes "$FM_RETRIEVAL_PUBLIC_BYTES" \
    --argjson redirects "$FM_RETRIEVAL_PUBLIC_REDIRECTS" \
    --argjson sensitive_stripped "$FM_RETRIEVAL_PUBLIC_STRIPPED" \
    --argjson filter_observed "$FM_RETRIEVAL_PUBLIC_FILTER_OBSERVED" \
    --argjson body_published "$FM_RETRIEVAL_PUBLIC_BODY_PUBLISHED" \
    --argjson cannot_establish "$cannot" \
    '{schema: $schema, retrieval: $retrieval, reason: $reason, detail: $detail,
      observed_at: $observed, context: $context, profile: $profile,
      profile_user_agent: $ua, profile_authorization: $authorization,
      attempts: $attempts, requests: $requests, requested_url: $requested_url,
      final_url: $final_url, final_origin: $final_origin, status: $status,
      classification: $classification, bytes: $bytes, body_digest: $digest,
      body_published: $body_published, redirects: $redirects,
      sensitive_stripped: ($sensitive_stripped == 1),
      filter_observed: ($filter_observed == 1),
      fallback_blocked: $fallback_blocked, transport: $transport,
      cannot_establish: $cannot_establish}' > "$out"
}

# fm_retrieval_public_fetch <url> <body-out> <context> [request-headers-file]
#
# The distinct typed public-content entrypoint. Writes the retrieved bytes to
# <body-out> and their proof to <body-out>.meta through the same commit ordering
# the collection path uses, and returns 0 only for a complete body.
#
# The request-headers file, when given, carries one "Name: value" per line.
# Authorization, Proxy-Authorization and Cookie lines in it are the sensitive
# material the cross-origin rule governs.
#
# TRUNCATION IS NOT A WEAK SUCCESS. A body that hit the byte bound publishes
# EMPTY bytes with retrieval=incomplete, so no caller can be handed a prefix and
# read it as the document. The observed length is still recorded, because how
# much arrived is evidence even when none of it may be used.
fm_retrieval_public_fetch() {  # <url> <body-out> <context> [request-headers-file]
  local url=${1:-} out=${2:-} context=${3:-} caller_headers=${4:-}
  local work allows attempts=0 profile cls reason payload rc detail max_bytes
  local -a ladder=()

  fm_retrieval_reset
  FM_RETRIEVAL_PUBLIC_URL=$url
  FM_RETRIEVAL_PUBLIC_CONTEXT=$context

  if [ -z "$out" ]; then
    fm_retrieval_set_reason usage_error "fm_retrieval_public_fetch needs an output path"
    return 1
  fi
  case "$url" in
    http://*|https://*) ;;
    *)
      fm_retrieval_set_reason usage_error "not an http or https URL: ${url:-<empty>}"
      return 1
      ;;
  esac
  command -v jq >/dev/null 2>&1 || {
    fm_retrieval_set_reason transport_unavailable "jq is not on PATH"
    return 1
  }
  allows=0
  fm_retrieval_public_context_allows_fallback "$context" || allows=$?
  if [ "$allows" = 2 ]; then
    # An unrecognized context is a usage error rather than a permissive
    # default, because the permissive default is the one that would quietly
    # give an excluded caller a substituted client identity.
    fm_retrieval_set_reason usage_error \
      "unknown public-content caller context: ${context:-<empty>}"
    return 1
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-retrieval-public.XXXXXX") || {
    fm_retrieval_set_reason usage_error "could not create a working directory"
    return 1
  }
  : > "$work/hdr"
  : > "$work/body"
  : > "$work/empty"
  : > "$work/caller-headers"
  if [ -n "$caller_headers" ] && [ -f "$caller_headers" ]; then
    cp "$caller_headers" "$work/caller-headers" || {
      rm -rf "$work"
      fm_retrieval_set_reason usage_error "could not read the request headers at $caller_headers"
      return 1
    }
  fi

  read -r -a ladder <<< "$FM_RETRIEVAL_PUBLIC_LADDER"
  cls=
  for profile in "${ladder[@]}"; do
    FM_RETRIEVAL_PUBLIC_PROFILE=$profile
    attempts=$((attempts + 1))
    FM_RETRIEVAL_PUBLIC_ATTEMPTS=$attempts
    fm_retrieval_public_attempt "$url" "$profile" "$work" "$work/caller-headers"
    cls=$FM_RETRIEVAL_PUBLIC_CLASS
    [ "$cls" = client_filter ] && FM_RETRIEVAL_PUBLIC_FILTER_OBSERVED=1

    # Every terminal class stops here. The ladder advances on exactly one
    # condition - this attempt was positively typed as client filtering - which
    # is what keeps a boundary, a challenge, a rate refusal, or an unexplained
    # 403 from being answered with a different identity.
    [ "$cls" = client_filter ] || break

    if [ "$allows" != 0 ]; then
      FM_RETRIEVAL_PUBLIC_FALLBACK_BLOCKED="context:$context"
      break
    fi
  done

  reason=$(fm_retrieval_public_reason_of "$cls") || reason=malformed_response
  FM_RETRIEVAL_PUBLIC_BYTES=$(wc -c < "$work/body" 2>/dev/null | tr -d '[:space:]')
  case "$FM_RETRIEVAL_PUBLIC_BYTES" in ''|*[!0-9]*) FM_RETRIEVAL_PUBLIC_BYTES=0 ;; esac
  max_bytes=${FM_RETRIEVAL_PUBLIC_MAX_BYTES:-5000000}
  case "$max_bytes" in ''|*[!0-9]*) max_bytes=5000000 ;; esac
  if [ "$reason" = body_complete ] && [ "$FM_RETRIEVAL_PUBLIC_BYTES" -gt "$max_bytes" ]; then
    # The transport did not stop it, so this does. A response that declares no
    # length can outrun a transport-side cap, and the caller must never be
    # handed the prefix that did arrive.
    cls=too_large
    reason=byte_bound_reached
    FM_RETRIEVAL_PUBLIC_CLASS=$cls
    FM_RETRIEVAL_PUBLIC_NOTE="the body reached $FM_RETRIEVAL_PUBLIC_BYTES bytes, past this reader's $max_bytes byte bound"
  fi
  FM_RETRIEVAL_PUBLIC_FINAL_ORIGIN=$(fm_retrieval_public_origin "$FM_RETRIEVAL_PUBLIC_FINAL_URL") \
    || FM_RETRIEVAL_PUBLIC_FINAL_ORIGIN=

  detail="profile $FM_RETRIEVAL_PUBLIC_PROFILE on attempt $attempts of ${#ladder[@]}"
  detail="$detail answered HTTP ${FM_RETRIEVAL_PUBLIC_STATUS:-none} for $FM_RETRIEVAL_PUBLIC_FINAL_URL"
  [ -n "${FM_RETRIEVAL_PUBLIC_NOTE:-}" ] && detail="$detail: $FM_RETRIEVAL_PUBLIC_NOTE"
  [ -n "$FM_RETRIEVAL_PUBLIC_FALLBACK_BLOCKED" ] && \
    detail="$detail; fallback is structurally unavailable to $FM_RETRIEVAL_PUBLIC_FALLBACK_BLOCKED"
  fm_retrieval_set_reason "$reason" "$detail" || :

  if [ "$reason" = body_complete ]; then
    payload=$work/body
    FM_RETRIEVAL_PUBLIC_BODY_PUBLISHED=true
  else
    payload=$work/empty
    FM_RETRIEVAL_PUBLIC_BODY_PUBLISHED=false
  fi

  rc=0
  fm_retrieval_commit "$out" "$payload" - fm_retrieval_public_meta || rc=$?
  FM_RETRIEVAL_PUBLIC_BODY_FILE=$out
  rm -rf "$work"
  [ "$rc" = 0 ] || return 1
  [ "$FM_RETRIEVAL_COMPLETENESS" = complete ] || return 1
  return 0
}

# --- selection: discovery first, identity second -----------------------------
#
# Discovery is deliberately loose and identity is exact, in that order, because
# the reverse cannot report what it nearly matched. A record whose text merely
# mentions the subject is a CANDIDATE; a candidate becomes a MATCH only when the
# identifier occurs as a whole token on a line the record's own author wrote.
#
# Two rejections are counted rather than silently dropped, because each is a
# way a plausible answer reaches the wrong subject:
#
#   prefix collision - "req-7" occurs inside "req-71" and "req-7-b". The
#     boundary characters are therefore letters, digits, and the separators
#     identifiers are built from, so a longer identifier sharing this prefix is
#     never this one.
#   quoted prose - an identifier on a quoted line is a reference to ANOTHER
#     record, not an occurrence in this one. A reply that quotes an approval has
#     not approved anything, and counting it attributes someone else's ruling to
#     whoever answered it.
#
# The applicability pattern is held to the same unquoted rule, so quoting a
# verdict does not issue it.
#
# IDENTITY MODE. Two different things get called identity and they need different
# tests. In PROSE - a comment body, a ruling, a reply - the identifier occurs
# somewhere inside free text, so the test is a whole-token occurrence. In a FIELD
# whose entire value IS the identifier - a branch ref, a slug, a key - the test is
# equality, because token boundaries are the wrong rule there: "feature/x" occurs
# as a whole token inside "feature/x/y", and a reader looking for the first would
# accept the second. A caller says which it has; token is the default because
# prose is the case that produced the defect.
fm_retrieval_select() {  # <records-file> <id-field> <text-field> <time-field> <discover-ere> <identity> <applicable-ere> [token|exact]
  local records=$1 id_field=$2 text_field=$3 time_field=$4
  local discover=$5 identity=$6 applicable=$7 identity_mode=${8:-token}
  local line text id at url
  local best_id='' best_at='' best_url=''

  FM_RETRIEVAL_CANDIDATES=0
  FM_RETRIEVAL_MATCHES=0
  FM_RETRIEVAL_QUOTED_ONLY=0
  FM_RETRIEVAL_PREFIX_REJECTED=0
  FM_RETRIEVAL_SELECTED_ID=
  FM_RETRIEVAL_SELECTED_AT=
  FM_RETRIEVAL_SELECTED_URL=
  [ -f "$records" ] || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    text=$(fm_retrieval_field "$line" "$text_field")
    id=$(fm_retrieval_field "$line" "$id_field")
    at=$(fm_retrieval_field "$line" "$time_field")
    url=$(printf '%s' "$line" | jq -r '(.html_url // .url // "-") | tostring')

    # Discovery: over-broad on purpose. An empty pattern discovers everything,
    # so a caller who does not narrow still gets the complete universe rather
    # than an accidental filter.
    if [ -n "$discover" ]; then
      printf '%s' "$text" | grep -qE -- "$discover" || continue
    fi
    FM_RETRIEVAL_CANDIDATES=$((FM_RETRIEVAL_CANDIDATES + 1))

    if [ -n "$identity" ]; then
      if [ "$identity_mode" = exact ]; then
        if [ "$text" != "$identity" ]; then
          case "$text" in
            *"$identity"*) FM_RETRIEVAL_PREFIX_REJECTED=$((FM_RETRIEVAL_PREFIX_REJECTED + 1)) ;;
          esac
          continue
        fi
      elif ! fm_retrieval_identity_unquoted "$text" "$identity"; then
        if printf '%s' "$text" | grep -qF -- "$identity"; then
          if fm_retrieval_identity_quoted_only "$text" "$identity"; then
            FM_RETRIEVAL_QUOTED_ONLY=$((FM_RETRIEVAL_QUOTED_ONLY + 1))
          else
            FM_RETRIEVAL_PREFIX_REJECTED=$((FM_RETRIEVAL_PREFIX_REJECTED + 1))
          fi
        fi
        continue
      fi
    fi

    if [ -n "$applicable" ]; then
      fm_retrieval_unquoted_lines "$text" | grep -qE -- "$applicable" || continue
    fi

    FM_RETRIEVAL_MATCHES=$((FM_RETRIEVAL_MATCHES + 1))
    # Extremal selection by the source's own immutable ordering: the recorded
    # time first, then the identity as the tie-break, so two records sharing a
    # timestamp still resolve the same way on every run.
    if [ -z "$best_id" ] \
      || [ "$at" \> "$best_at" ] \
      || { [ "$at" = "$best_at" ] && fm_retrieval_id_gt "$id" "$best_id"; }; then
      best_id=$id
      best_at=$at
      best_url=$url
    fi
  done < "$records"

  FM_RETRIEVAL_SELECTED_ID=$best_id
  FM_RETRIEVAL_SELECTED_AT=$best_at
  FM_RETRIEVAL_SELECTED_URL=$best_url
  return 0
}

# One field of one record, as a string. A name carrying a dot is a path into the
# object, so a nested value such as head.ref is addressable without a caller
# reshaping the records first; a name without one is a plain key. Absent reads as
# the empty string, which the callers above treat as no value rather than as a
# value of their own.
fm_retrieval_field() {  # <record-json> <field-or-path>
  printf '%s' "$1" | jq -r --arg f "$2" \
    'if ($f | test("[.]")) then (getpath($f | split(".")) // "")
     else (.[$f] // "") end | tostring'
}

# Whether a record carries a usable value at <field-or-path>. Kept beside the
# reader so the traversal's schema check and the selection use one rule. The
# $f inside is jq's own argument, which must reach jq unexpanded.
# shellcheck disable=SC2016
FM_RETRIEVAL_HAS_FIELD_EXPR='
  def at($f): if ($f | test("[.]")) then getpath($f | split(".")) else .[$f] end;
  type == "object" and (at($f) != null)'

# Numeric where both sides are numbers, lexical otherwise, so a numeric comment
# id orders as a number and an opaque node id still orders deterministically.
fm_retrieval_id_gt() {  # <a> <b>
  local a=$1 b=$2
  case "$a$b" in
    ''|*[!0-9]*) [ "$a" \> "$b" ] ;;
    *) [ "$a" -gt "$b" ] ;;
  esac
}

# The lines a record's own author wrote: everything that is not quoted context.
# A leading ">" after optional whitespace is the quote marker every forge and
# mail client produces, so one rule covers replies, quoted rulings, and threaded
# context alike.
fm_retrieval_unquoted_lines() {  # <text>
  printf '%s\n' "$1" | grep -v '^[[:space:]]*>' || true
}

# Does <identity> occur as a whole identifier token in the given lines?
#
# The test is extraction and equality rather than a boundary regex, because the
# boundary characters and the separators identifiers are built from are the same
# characters, and a regex has to pick one meaning for each. A boundary set that
# excludes "." rejects "req-7." at the end of a sentence, which is a FALSE
# NEGATIVE on the most ordinary way a human writes a ruling; a boundary set that
# allows "." accepts "req-7.1", which is a different request. This was not a
# hypothetical: the first live run of this contract against a real thread
# reported a token absent that was present, for exactly that reason.
#
# So: pull out every maximal run of identifier characters, trim the separators
# that attach as punctuation from each end, and require equality. A longer
# identifier can never equal a shorter one, and sentence punctuation is never
# part of the run.
#
#   req-7.   -> run "req-7."   -> trimmed "req-7"   -> matches
#   req-71   -> run "req-71"   -> trimmed "req-71"  -> does not
#   req-7-b  -> run "req-7-b"  -> trimmed "req-7-b" -> does not
#   req-7.1  -> run "req-7.1"  -> trimmed "req-7.1" -> does not
#   (req-7)  -> run "req-7"                         -> matches
#
# An identity that is not itself a single identifier token cannot equal any run,
# so token mode is for identifiers; a caller whose identity is a whole field
# value uses exact mode instead.
fm_retrieval_token_occurs() {  # <lines> <identity>
  printf '%s\n' "$1" | grep -oE '[A-Za-z0-9._/-]+' 2>/dev/null \
    | sed -e 's/^[._/-]*//' -e 's/[._/-]*$//' \
    | grep -qxF -- "$2"
}

fm_retrieval_identity_unquoted() {  # <text> <identity>
  fm_retrieval_token_occurs "$(fm_retrieval_unquoted_lines "$1")" "$2"
}

# Present as a whole token, but only on quoted lines: a reference rather than an
# occurrence. Distinguished from a prefix collision so each is counted as what
# it is.
fm_retrieval_identity_quoted_only() {  # <text> <identity>
  local quoted
  quoted=$(printf '%s\n' "$1" | grep '^[[:space:]]*>' || true)
  [ -n "$quoted" ] || return 1
  fm_retrieval_token_occurs "$quoted" "$2"
}

# --- the conclusion algebra --------------------------------------------------
#
# The one place where a completeness value and a selection count become a
# conclusion a caller may act on.
#
#   PRESENT        a matching record was observed
#   ABSENT         the universe was completely enumerated and holds no match
#   INDETERMINATE  no conclusion may be drawn
#
# exists  a positive survives a partial read, because a record that was read
#         exists whatever remains unread. A negative needs complete retrieval.
# absent  the same algebra from the caller's other side: the answer is the same
#         value, the claim only says which one the caller expected.
# latest  ranges over the whole universe in BOTH directions, so complete
#         retrieval is required even with a match already in hand.
fm_retrieval_conclude() {  # <claim>
  local claim=${1:-exists}
  case "$claim" in
    exists|absent|latest) ;;
    *)
      fm_retrieval_set_reason usage_error "unknown claim: $claim"
      FM_RETRIEVAL_CONCLUSION=INDETERMINATE
      return 0
      ;;
  esac
  if [ "$claim" = latest ]; then
    if [ "$FM_RETRIEVAL_COMPLETENESS" != complete ]; then
      FM_RETRIEVAL_CONCLUSION=INDETERMINATE
      return 0
    fi
    if [ "$FM_RETRIEVAL_MATCHES" -gt 0 ]; then
      FM_RETRIEVAL_CONCLUSION=PRESENT
    else
      FM_RETRIEVAL_CONCLUSION=ABSENT
    fi
    return 0
  fi
  if [ "$FM_RETRIEVAL_MATCHES" -gt 0 ]; then
    FM_RETRIEVAL_CONCLUSION=PRESENT
    return 0
  fi
  if [ "$FM_RETRIEVAL_COMPLETENESS" = complete ]; then
    FM_RETRIEVAL_CONCLUSION=ABSENT
    return 0
  fi
  FM_RETRIEVAL_CONCLUSION=INDETERMINATE
  return 0
}

# --- the record and its only supported consumer ------------------------------

FM_RETRIEVAL_FIELDS='source,retrieval,reason,pages,records,duplicates,reported,candidates,matches,quoted_only,prefix_rejected,claim,conclusion,selected,evidence_ref'

fm_retrieval_encode_field() {  # <value>
  local value=$1
  value=${value//'%'/'%25'}
  value=${value//$'\r'/'%0D'}
  value=${value//$'\n'/'%0A'}
  value=${value//','/'%2C'}
  printf '%s' "$value"
}

fm_retrieval_decode_field() {  # <value>
  local value=$1
  value=${value//'%2C'/','}
  value=${value//'%0A'/$'\n'}
  value=${value//'%0D'/$'\r'}
  value=${value//'%25'/'%'}
  FM_RETRIEVAL_DECODED=$value
}

# fm_retrieval_emit <source> <claim>: the one record shape, on stdout.
fm_retrieval_emit() {  # <source> <claim>
  printf 'retrieval[2]{%s}:\n' "$FM_RETRIEVAL_FIELDS"
  printf '  %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(fm_retrieval_encode_field "${1:--}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_COMPLETENESS:-unobserved}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_REASON:-usage_error}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_PAGES:-0}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_RECORDS:-0}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_DUPLICATES:-0}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_REPORTED:-unknown}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_CANDIDATES:-0}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_MATCHES:-0}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_QUOTED_ONLY:-0}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_PREFIX_REJECTED:-0}")" \
    "$(fm_retrieval_encode_field "${2:-exists}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_CONCLUSION:-INDETERMINATE}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_SELECTED_ID:--}")" \
    "$(fm_retrieval_encode_field "${FM_RETRIEVAL_PROVENANCE:--}")"
}

# fm_retrieval_parse <record>: read one record and export its fields. Refuses
# anything it cannot parse and leaves no partially-populated fields behind,
# because an unparseable record is itself a could-not-observe and a consumer
# reading half of one would be looking at a result this function refused.
fm_retrieval_parse() {  # <record>
  local record=$1 header version row n i name value
  local -a names=() values=()
  FM_RETRIEVAL_COMPLETENESS=
  FM_RETRIEVAL_REASON=
  FM_RETRIEVAL_CONCLUSION=
  FM_RETRIEVAL_SOURCE=
  header=$(printf '%s\n' "$record" | head -1)
  case "$header" in
    "retrieval[1]{$FM_RETRIEVAL_FIELDS}:") version=1 ;;
    "retrieval[2]{$FM_RETRIEVAL_FIELDS}:") version=2 ;;
    *) return 1 ;;
  esac
  row=$(printf '%s\n' "$record" | sed -n 's/^  //p' | head -1)
  [ -n "$row" ] || return 1
  IFS=, read -r -a names <<< "$FM_RETRIEVAL_FIELDS"
  IFS=, read -r -a values <<< "$row"
  n=${#names[@]}
  [ "${#values[@]}" -eq "$n" ] || return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    name=${names[$i]}
    value=${values[$i]}
    if [ "$version" = 2 ]; then
      fm_retrieval_decode_field "$value"
      value=$FM_RETRIEVAL_DECODED
      values[i]=$FM_RETRIEVAL_DECODED
    fi
    case "$name" in
      retrieval)
        case "$value" in complete|incomplete|unobserved) ;; *) return 1 ;; esac
        ;;
      conclusion)
        case "$value" in PRESENT|ABSENT|INDETERMINATE) ;; *) return 1 ;; esac
        ;;
    esac
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${names[$i]}" in
      source) FM_RETRIEVAL_SOURCE=${values[$i]} ;;
      retrieval) FM_RETRIEVAL_COMPLETENESS=${values[$i]} ;;
      reason) FM_RETRIEVAL_REASON=${values[$i]} ;;
      conclusion) FM_RETRIEVAL_CONCLUSION=${values[$i]} ;;
      records) FM_RETRIEVAL_RECORDS=${values[$i]} ;;
      pages) FM_RETRIEVAL_PAGES=${values[$i]} ;;
      matches) FM_RETRIEVAL_MATCHES=${values[$i]} ;;
      selected) FM_RETRIEVAL_SELECTED_ID=${values[$i]} ;;
      evidence_ref) FM_RETRIEVAL_PROVENANCE=${values[$i]} ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# fm_retrieval_case <record> <on_present> <on_absent> <on_indeterminate>: the
# only supported way to consume a conclusion, and the reason this library exists
# as a type rather than a convention.
#
# It refuses, with status 3, when fewer or more than three handlers are named, a
# handler is not a defined function, or the indeterminate handler is the same
# function as either of the others. That last case is coercion written as a
# consumer: a caller who routes INDETERMINATE into the absent branch has
# rebuilt the original defect on top of a correct producer, so it has to be
# written as a decision rather than smuggled in as an argument.
fm_retrieval_case() {  # <record> <on_present> <on_absent> <on_indeterminate>
  local record=${1:-} on_present=${2:-} on_absent=${3:-} on_unknown=${4:-} handler
  if [ "$#" -ne 4 ]; then
    printf 'fm-retrieval: consumer must handle all three conclusions\n' >&2
    return 3
  fi
  for handler in "$on_present" "$on_absent" "$on_unknown"; do
    if ! declare -F "$handler" >/dev/null 2>&1; then
      printf 'fm-retrieval: consumer must handle all three conclusions\n' >&2
      return 3
    fi
  done
  if [ "$on_unknown" = "$on_present" ] || [ "$on_unknown" = "$on_absent" ]; then
    printf 'fm-retrieval: INDETERMINATE is not coercible; decide it explicitly\n' >&2
    return 3
  fi
  if ! fm_retrieval_parse "$record"; then
    printf 'fm-retrieval: unreadable result record\n' >&2
    return 3
  fi
  case "$FM_RETRIEVAL_CONCLUSION" in
    PRESENT) "$on_present" ;;
    ABSENT) "$on_absent" ;;
    *) "$on_unknown" ;;
  esac
}
