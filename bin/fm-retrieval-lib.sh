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

# shellcheck disable=SC2034  # published for sourcing scripts, not used here.
FM_RETRIEVAL_SCHEMA=fm-retrieval.v1

# The closed reason vocabulary. A reason names WHY the completeness value is
# what it is, and every value below maps to exactly one completeness:
#
#   complete
#     enumerated            the source offered no further continuation
#   incomplete
#     page_bound_reached    the page bound was spent with a continuation left
#     record_bound_reached  the record bound was spent with a continuation left
#   unobserved
#     transport_unavailable   the reader command is not present or not runnable
#     not_authorized          the source refused the credential
#     subject_unreadable      the source answered 404. GitHub returns 404 both
#                             for a resource that does not exist and for one the
#                             credential cannot see, so this deliberately does
#                             not claim which; what matters is that it is neither
#                             an empty collection nor a readable one
#     rate_limited            the source refused for rate reasons after retries
#     page_unreadable         a page failed after its retries for another reason
#     continuation_unreadable a continuation existed and could not be parsed
#     schema_unexpected       the response was not the shape this reader knows
#     state_uncommitted       a stored record set carries no committed proof
#     usage_error             the call itself was malformed

FM_RETRIEVAL_COMPLETENESS=
FM_RETRIEVAL_REASON=
FM_RETRIEVAL_PAGES=0
FM_RETRIEVAL_RECORDS=0
FM_RETRIEVAL_DUPLICATES=0
FM_RETRIEVAL_REPORTED=unknown
FM_RETRIEVAL_RECORDS_FILE=
FM_RETRIEVAL_PROVENANCE=
FM_RETRIEVAL_DETAIL=

FM_RETRIEVAL_CANDIDATES=0
FM_RETRIEVAL_MATCHES=0
FM_RETRIEVAL_QUOTED_ONLY=0
FM_RETRIEVAL_PREFIX_REJECTED=0
FM_RETRIEVAL_SELECTED_ID=
FM_RETRIEVAL_SELECTED_AT=
FM_RETRIEVAL_SELECTED_URL=

FM_RETRIEVAL_CONCLUSION=

fm_retrieval_reset() {
  FM_RETRIEVAL_COMPLETENESS=
  FM_RETRIEVAL_REASON=
  FM_RETRIEVAL_PAGES=0
  FM_RETRIEVAL_RECORDS=0
  FM_RETRIEVAL_DUPLICATES=0
  FM_RETRIEVAL_REPORTED=unknown
  FM_RETRIEVAL_RECORDS_FILE=
  FM_RETRIEVAL_PROVENANCE=
  FM_RETRIEVAL_DETAIL=
  FM_RETRIEVAL_CANDIDATES=0
  FM_RETRIEVAL_MATCHES=0
  FM_RETRIEVAL_QUOTED_ONLY=0
  FM_RETRIEVAL_PREFIX_REJECTED=0
  FM_RETRIEVAL_SELECTED_ID=
  FM_RETRIEVAL_SELECTED_AT=
  FM_RETRIEVAL_SELECTED_URL=
  FM_RETRIEVAL_CONCLUSION=
}

# fm_retrieval_completeness_of <reason>: the completeness value a reason implies.
# The mapping is total and lives here alone, so no caller can invent a fourth
# value or attach a reason to the wrong one.
fm_retrieval_completeness_of() {  # <reason>
  case "${1:-}" in
    enumerated) printf 'complete' ;;
    page_bound_reached|record_bound_reached) printf 'incomplete' ;;
    transport_unavailable|not_authorized|rate_limited|page_unreadable) \
      printf 'unobserved' ;;
    subject_unreadable) printf 'unobserved' ;;
    continuation_unreadable|schema_unexpected|state_uncommitted|usage_error) \
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
  local page_records total=0 dups=0 attempts

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
      printf '%s\n' "$this_id" >> "$seen_file"
      printf '%s\n' "$line" >> "$out_file"
      total=$((total + 1))
    done < <(jq -c '.[]' "$body")

    jq -cn --arg url "$url" --argjson n "$page_records" --argjson a "$attempts" \
      '{url: $url, records: $n, attempts: $a, status: 200}' >> "$tmp/pages.json"

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
  FM_RETRIEVAL_RECORDS_FILE=$records
  [ -n "$FM_RETRIEVAL_REASON" ] || fm_retrieval_set_reason page_unreadable \
    "the traversal ended without a reason, which is itself unobserved"

  fm_retrieval_publish "$records" "$out_file" "$tmp/pages.json"
  rc=$?
  rm -rf "$tmp"
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

# Publish the record set and then its proof, proof last. Called by fetch; split
# out so the ordering is stated in one place and cannot be reordered by editing
# the traversal.
fm_retrieval_publish() {  # <records-file> <staged-records> <staged-pages>
  local records=$1 staged=$2 pages_file=$3 dir meta observed digest
  dir=$(dirname "$records")
  [ -d "$dir" ] || mkdir -p "$dir" || {
    fm_retrieval_set_reason usage_error "cannot write to $dir"
    return 1
  }
  observed=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
  meta=$records.meta

  cp "$staged" "$records.staging" || {
    fm_retrieval_set_reason usage_error "cannot stage the record set at $records"
    return 1
  }
  rm -f "$meta"
  mv -f "$records.staging" "$records" || {
    fm_retrieval_set_reason usage_error "cannot publish the record set at $records"
    return 1
  }
  digest=$(fm_retrieval_sha256 "$records") || {
    fm_retrieval_set_reason state_uncommitted \
      "the published record set could not be bound to a SHA-256 digest"
    return 1
  }

  jq -cn \
    --arg schema "$FM_RETRIEVAL_SCHEMA" \
    --arg retrieval "$FM_RETRIEVAL_COMPLETENESS" \
    --arg reason "$FM_RETRIEVAL_REASON" \
    --arg detail "$FM_RETRIEVAL_DETAIL" \
    --arg observed "$observed" \
    --arg reader "${FM_RETRIEVAL_GH:-gh}" \
    --arg digest "sha256:$digest" \
    --argjson records "$FM_RETRIEVAL_RECORDS" \
    --argjson duplicates "$FM_RETRIEVAL_DUPLICATES" \
    --slurpfile pages "$pages_file" \
    '{schema: $schema, retrieval: $retrieval, reason: $reason, detail: $detail,
      observed_at: $observed, reader: $reader, record_digest: $digest, records: $records,
      duplicates: $duplicates, pages: $pages}' > "$meta.staging" || {
    fm_retrieval_set_reason usage_error "cannot stage the completeness proof"
    return 1
  }
  mv -f "$meta.staging" "$meta" || {
    fm_retrieval_set_reason usage_error "cannot publish the completeness proof"
    return 1
  }
  FM_RETRIEVAL_PROVENANCE=$meta
  return 0
}

fm_retrieval_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk 'NF { print $1; exit }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk 'NF { print $1; exit }'
  else
    return 1
  fi
}

# fm_retrieval_load <records-file>: adopt a previously published read. The proof
# is required: a record set with none is an interrupted write, and the count of
# whatever survived is not a fact about the collection.
fm_retrieval_load() {  # <records-file>
  local records=$1 meta=$1.meta expected_digest actual_digest
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
  if ! jq -e --arg s "$FM_RETRIEVAL_SCHEMA" '.schema == $s' "$meta" >/dev/null 2>&1; then
    fm_retrieval_set_reason schema_unexpected \
      "$meta is not a $FM_RETRIEVAL_SCHEMA proof"
    return 1
  fi
  expected_digest=$(jq -r '.record_digest // empty' "$meta" 2>/dev/null)
  case "$expected_digest" in
    sha256:*) ;;
    *)
      fm_retrieval_set_reason state_uncommitted \
        "$meta carries no usable record digest"
      return 1
      ;;
  esac
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

# fm_retrieval_emit <source> <claim>: the one record shape, on stdout.
fm_retrieval_emit() {  # <source> <claim>
  printf 'retrieval[1]{%s}:\n' "$FM_RETRIEVAL_FIELDS"
  printf '  %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "${1:--}" \
    "${FM_RETRIEVAL_COMPLETENESS:-unobserved}" \
    "${FM_RETRIEVAL_REASON:-usage_error}" \
    "${FM_RETRIEVAL_PAGES:-0}" \
    "${FM_RETRIEVAL_RECORDS:-0}" \
    "${FM_RETRIEVAL_DUPLICATES:-0}" \
    "${FM_RETRIEVAL_REPORTED:-unknown}" \
    "${FM_RETRIEVAL_CANDIDATES:-0}" \
    "${FM_RETRIEVAL_MATCHES:-0}" \
    "${FM_RETRIEVAL_QUOTED_ONLY:-0}" \
    "${FM_RETRIEVAL_PREFIX_REJECTED:-0}" \
    "${2:-exists}" \
    "${FM_RETRIEVAL_CONCLUSION:-INDETERMINATE}" \
    "${FM_RETRIEVAL_SELECTED_ID:--}" \
    "${FM_RETRIEVAL_PROVENANCE:--}"
}

# fm_retrieval_parse <record>: read one record and export its fields. Refuses
# anything it cannot parse and leaves no partially-populated fields behind,
# because an unparseable record is itself a could-not-observe and a consumer
# reading half of one would be looking at a result this function refused.
fm_retrieval_parse() {  # <record>
  local record=$1 row n i name value
  local -a names=() values=()
  FM_RETRIEVAL_COMPLETENESS=
  FM_RETRIEVAL_REASON=
  FM_RETRIEVAL_CONCLUSION=
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
