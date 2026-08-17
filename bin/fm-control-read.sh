#!/usr/bin/env bash
# fm-control-read.sh - the repository-owned retrieval contract for every
# control-plane read whose result can reach a negative conclusion.
#
# Use it wherever "nothing pending", "nothing new", "no ruling yet", "no such
# request", "already handled", or "not present" could be the answer. It reads
# the WHOLE collection, proves it did, and refuses to hand back a negative it
# cannot support. bin/fm-retrieval-lib.sh owns the type, the traversal, and the
# conclusion algebra; this script is the callable surface over it.
#
# WHY A CALLER SHOULD NOT ROLL THEIR OWN
#
# `gh api repos/o/r/issues/N/comments` returns the FIRST page, and the first page
# holds the OLDEST records. A reader that stops there and reports "no reply yet"
# is not wrong about what it read; it is wrong about what it read it over. This
# command exists so that no caller has to remember pagination, and so that the
# refusal to conclude is a returned value rather than a habit.
#
# Usage:
#   fm-control-read.sh issue-comments <owner/repo> <number> [options]
#   fm-control-read.sh pr-reviews <owner/repo> <number> [options]
#   fm-control-read.sh endpoint <rest-path> [options]
#   fm-control-read.sh --replay <records-file> [options]
#   fm-control-read.sh --list-sources
#   fm-control-read.sh -h | --help
#
# Sources:
#   issue-comments  the conversation on one issue or pull request. A pull
#                   request's conversation comments live on its issue, so this is
#                   the source for a ruling posted in a pull request thread too.
#   pr-reviews      the review submissions on one pull request. Review BODIES
#                   only; a review's inline comments are a different collection.
#   endpoint        any REST list path, for a collection with no named source
#                   here yet. The identity, text, and time fields default to a
#                   comment's and can be overridden.
#
# Options:
#   --identity <token>   the exact identifier a record must carry to be this
#                        subject. Matched as a whole identifier token on a line
#                        the record's own author wrote, so a longer identifier
#                        containing this one (req-71, req-7-b, req-7.1) and a
#                        quoted reference to another record both fail it, while
#                        ordinary sentence punctuation ("APPROVE req-7.") does
#                        not. bin/fm-retrieval-lib.sh owns that rule and why it
#                        is extraction rather than a boundary pattern.
#   --identity-mode token|exact
#                        token (default) finds the identifier inside prose.
#                        exact requires the text field to BE the identifier, for
#                        a field whose whole value is the identity - a branch
#                        ref, a slug, a key - where token boundaries are the
#                        wrong rule: "feature/x" occurs as a whole token inside
#                        "feature/x/y".
#   --discover <ere>     the deliberately broad candidate filter applied BEFORE
#                        identity. Default: every record is a candidate.
#   --applicable <ere>   an extended regular expression a matching record must
#                        also satisfy, on an unquoted line. This is where the
#                        caller's own meaning goes - which verdicts count, which
#                        dispositions apply - because this command owns
#                        retrieval and identity, never meaning.
#   --claim exists|absent|latest
#                        exists (default) answers "is there one?", absent answers
#                        the same question from the other side, and latest also
#                        selects the newest applicable record. latest requires
#                        complete retrieval even when a match is already in hand,
#                        because "the latest" ranges over the whole universe: a
#                        first page carrying a ruling a later page supersedes is
#                        precisely the shape that reads as a successful answer.
#   --records <path>      keep the retrieved record set and its completeness
#                        proof at <path> and <path>.meta instead of a temporary
#                        file. The proof is written last and its presence is the
#                        commit point, so an interrupted read is never adopted as
#                        a complete one.
#   --id-field <name>    immutable remote identity (default: id). Required on
#                        every record: without it a collection cannot be
#                        deduplicated across a page window that shifts while
#                        being read.
#   --text-field <name>  the field identity and applicability are matched against
#                        (default: body).
#   --time-field <name>  the field extremal selection orders by (default:
#                        created_at). Any of these three names carrying a dot is
#                        a path into the record, so head.ref addresses a nested
#                        value without the caller reshaping the records first.
#   --max-pages <n>      page bound (default 50). Spending it with a continuation
#                        left is incomplete retrieval, never the end of the set.
#   --max-records <n>    record bound, same rule.
#   --per-page <n>       records requested per page (default 100).
#   --json               also print the completeness proof as JSON on stdout.
#
# Output is exactly one record on stdout, in every case:
#
#   retrieval[1]{source,retrieval,reason,pages,records,duplicates,reported,candidates,matches,quoted_only,prefix_rejected,claim,conclusion,selected,evidence_ref}:
#     issue-comments:o/r#12,complete,enumerated,3,137,0,unknown,4,1,0,2,latest,PRESENT,984,/tmp/x.jsonl.meta
#
# retrieval is one of complete, incomplete, or unobserved, and conclusion is one
# of PRESENT, ABSENT, or INDETERMINATE. bin/fm-retrieval-lib.sh's header owns
# what each means and which reasons map to which.
#
# Exit status:
#   0  PRESENT        a matching record was observed
#   1  ABSENT         the universe was completely enumerated and holds no match
#   2  INDETERMINATE  no conclusion may be drawn, and none may be inferred
#
# That mapping is the enforcement rather than a convenience. A caller writing
# `if fm-control-read.sh ...; then` gets the fail-closed answer by construction,
# and a caller reading only the status can never turn an unenumerated source into
# an absence, because absence has a status of its own.
#
# LIMITS, AND WHERE TO SEE THEM
#
# The page and record bounds exist so an unbounded collection cannot hang a
# supervision cycle. Spending one is reported as incomplete retrieval with the
# bound named in the proof, so the limit is a discoverable fact and never a
# quiet truncation: `--json` prints it, and the .meta sidecar keeps it. Raise the
# bound and re-run when a collection genuinely needs more.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-retrieval-lib.sh
. "$SCRIPT_DIR/fm-retrieval-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

list_sources() {
  printf 'issue-comments <owner/repo> <number>\n'
  printf 'pr-reviews <owner/repo> <number>\n'
  printf 'endpoint <rest-path>\n'
}

SOURCE=
SOURCE_LABEL=
REPLAY=
IDENTITY=
IDENTITY_MODE=token
DISCOVER=
APPLICABLE=
CLAIM=exists
RECORDS=
ID_FIELD=id
TEXT_FIELD=body
TIME_FIELD=created_at
MAX_PAGES=
MAX_RECORDS=0
PER_PAGE=100
WANT_JSON=0
declare -a POSITIONAL=()

# A usage error is reported in the same record shape as every other result, so a
# caller reading records never has to parse a second format to learn it asked
# wrongly - and never sees an empty answer where a refusal belongs.
refuse_usage() {  # <detail>
  fm_retrieval_reset
  fm_retrieval_set_reason usage_error "$1"
  FM_RETRIEVAL_CONCLUSION=INDETERMINATE
  printf 'fm-control-read: %s\n' "$1" >&2
  fm_retrieval_emit "${SOURCE_LABEL:--}" "$CLAIM"
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list-sources) list_sources; exit 0 ;;
    --replay) [ "$#" -ge 2 ] || refuse_usage "--replay needs a path"; REPLAY=$2; shift 2 ;;
    --identity) [ "$#" -ge 2 ] || refuse_usage "--identity needs a value"; IDENTITY=$2; shift 2 ;;
    --identity-mode) [ "$#" -ge 2 ] || refuse_usage "--identity-mode needs a value"; IDENTITY_MODE=$2; shift 2 ;;
    --discover) [ "$#" -ge 2 ] || refuse_usage "--discover needs a value"; DISCOVER=$2; shift 2 ;;
    --applicable) [ "$#" -ge 2 ] || refuse_usage "--applicable needs a value"; APPLICABLE=$2; shift 2 ;;
    --claim) [ "$#" -ge 2 ] || refuse_usage "--claim needs a value"; CLAIM=$2; shift 2 ;;
    --records) [ "$#" -ge 2 ] || refuse_usage "--records needs a path"; RECORDS=$2; shift 2 ;;
    --id-field) [ "$#" -ge 2 ] || refuse_usage "--id-field needs a value"; ID_FIELD=$2; shift 2 ;;
    --text-field) [ "$#" -ge 2 ] || refuse_usage "--text-field needs a value"; TEXT_FIELD=$2; shift 2 ;;
    --time-field) [ "$#" -ge 2 ] || refuse_usage "--time-field needs a value"; TIME_FIELD=$2; shift 2 ;;
    --max-pages) [ "$#" -ge 2 ] || refuse_usage "--max-pages needs a value"; MAX_PAGES=$2; shift 2 ;;
    --max-records) [ "$#" -ge 2 ] || refuse_usage "--max-records needs a value"; MAX_RECORDS=$2; shift 2 ;;
    --per-page) [ "$#" -ge 2 ] || refuse_usage "--per-page needs a value"; PER_PAGE=$2; shift 2 ;;
    --json) WANT_JSON=1; shift ;;
    --) shift; while [ "$#" -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*) refuse_usage "unknown option: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

case "$CLAIM" in
  exists|absent|latest) ;;
  *) refuse_usage "unknown claim: $CLAIM (exists, absent, or latest)" ;;
esac
case "$IDENTITY_MODE" in
  token|exact) ;;
  *) refuse_usage "unknown identity mode: $IDENTITY_MODE (token or exact)" ;;
esac
case "$PER_PAGE" in ''|*[!0-9]*|0) refuse_usage "--per-page must be a positive whole number" ;; esac
[ "$PER_PAGE" -le 100 ] || refuse_usage "--per-page above 100 is not served by GitHub"
[ -z "$MAX_PAGES" ] || case "$MAX_PAGES" in ''|*[!0-9]*|0) refuse_usage "--max-pages must be a positive whole number" ;; esac
case "$MAX_RECORDS" in ''|*[!0-9]*) refuse_usage "--max-records must be a whole number" ;; esac

# --- resolve the source ------------------------------------------------------

FIRST_URL=

resolve_repo_number() {  # <label> <path-template>
  local repo number
  [ "${#POSITIONAL[@]}" -eq 3 ] \
    || refuse_usage "$1 needs <owner/repo> and <number>"
  repo=${POSITIONAL[1]}
  number=${POSITIONAL[2]}
  case "$repo" in
    */*) ;;
    *) refuse_usage "'$repo' is not an owner/repo slug" ;;
  esac
  case "$repo" in *[!A-Za-z0-9._/-]*) refuse_usage "'$repo' carries a character a repository slug cannot" ;; esac
  case "$number" in ''|*[!0-9]*) refuse_usage "'$number' is not a number" ;; esac
  SOURCE_LABEL="$1:$repo#$number"
  # shellcheck disable=SC2059  # the template is this script's own, not input.
  FIRST_URL=$(printf "$2" "$repo" "$number")
  FIRST_URL="$FIRST_URL?per_page=$PER_PAGE"  # fm-retrieval-audit: contract - this contract's own request builder; the traversal it feeds proves its own extent
}

if [ -n "$REPLAY" ]; then
  SOURCE_LABEL="replay:$REPLAY"
  [ "${#POSITIONAL[@]}" -eq 0 ] || refuse_usage "--replay takes no positional source"
else
  [ "${#POSITIONAL[@]}" -ge 1 ] || refuse_usage "name a source (--list-sources)"
  SOURCE=${POSITIONAL[0]}
  case "$SOURCE" in
    issue-comments) resolve_repo_number issue-comments 'repos/%s/issues/%s/comments' ;;
    pr-reviews) resolve_repo_number pr-reviews 'repos/%s/pulls/%s/reviews' ;;
    endpoint)
      [ "${#POSITIONAL[@]}" -eq 2 ] || refuse_usage "endpoint needs a REST path"
      case "${POSITIONAL[1]}" in
        *[[:space:]]*) refuse_usage "a REST path cannot contain whitespace" ;;
      esac
      SOURCE_LABEL="endpoint:${POSITIONAL[1]}"
      FIRST_URL=${POSITIONAL[1]}
      # A caller who did not say how many records per page gets the largest page
      # the source serves, because a smaller page only means more requests for
      # the same complete traversal.
      case "$FIRST_URL" in
        *per_page=*) ;;  # fm-retrieval-audit: contract - leaves a caller-supplied page size alone in this contract's own request builder
        *\?*) FIRST_URL="$FIRST_URL&per_page=$PER_PAGE" ;;  # fm-retrieval-audit: contract - this contract's own request builder; the traversal it feeds proves its own extent
        *) FIRST_URL="$FIRST_URL?per_page=$PER_PAGE" ;;  # fm-retrieval-audit: contract - this contract's own request builder; the traversal it feeds proves its own extent
      esac
      ;;
    *) refuse_usage "unknown source: $SOURCE (--list-sources)" ;;
  esac
fi

# --- retrieve, then select, then conclude ------------------------------------

fm_retrieval_reset

WORK_DIR=
# shellcheck disable=SC2329  # invoked by the EXIT trap below.
cleanup() {
  [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  return 0
}
trap cleanup EXIT

if [ -z "$RECORDS" ]; then
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-read.XXXXXX") \
    || refuse_usage "could not create a working directory"
  RECORDS="$WORK_DIR/records.jsonl"
fi

RETRIEVED=0
if [ -n "$REPLAY" ]; then
  RECORDS=$REPLAY
  fm_retrieval_load "$RECORDS" && RETRIEVED=1
else
  fm_retrieval_fetch "$FIRST_URL" "$RECORDS" "$ID_FIELD" "$MAX_PAGES" "$MAX_RECORDS" \
    "$TEXT_FIELD" "$TIME_FIELD" \
    && RETRIEVED=1
fi

# Selection runs over whatever WAS retrieved even when retrieval did not
# complete, because a match already read is a real observation and the algebra
# needs the count to tell PRESENT from INDETERMINATE. What it must never do is
# treat that partial set as the universe, which is exactly what
# fm_retrieval_conclude refuses to do.
if [ "$FM_RETRIEVAL_REASON" != state_uncommitted ] \
  && [ "$FM_RETRIEVAL_REASON" != transport_unavailable ] \
  && [ "$FM_RETRIEVAL_REASON" != usage_error ]; then
  fm_retrieval_select "$RECORDS" "$ID_FIELD" "$TEXT_FIELD" "$TIME_FIELD" \
    "$DISCOVER" "$IDENTITY" "$APPLICABLE" "$IDENTITY_MODE"
fi

fm_retrieval_conclude "$CLAIM"
fm_retrieval_emit "$SOURCE_LABEL" "$CLAIM"

if [ "$WANT_JSON" = 1 ] && [ -n "$FM_RETRIEVAL_PROVENANCE" ] \
  && [ -f "$FM_RETRIEVAL_PROVENANCE" ]; then
  cat "$FM_RETRIEVAL_PROVENANCE"
fi

# RETRIEVED is deliberately unused in the exit decision: whether the traversal
# returned zero is not the answer, the conclusion is. It stays computed so a
# future reader sees that the status was not taken from the fetch.
: "$RETRIEVED"

case "$FM_RETRIEVAL_CONCLUSION" in
  PRESENT) exit 0 ;;
  ABSENT) exit 1 ;;
  *) exit 2 ;;
esac
