#!/usr/bin/env bash
# fm-review-envelope.sh - compile, inspect and classify a review-envelope/v1
# artifact: the immutable, content-addressed statement of one review candidate.
#
# bin/fm-review-envelope-lib.sh owns the contract itself - every bound fact,
# where it comes from, how the bytes are canonicalized, and every refusal and
# could-not-observe code. Read that header before this one.
#
# Usage:
#   fm-review-envelope.sh prepare  --repo <dir> --inputs <file>
#                                  --evidence-root <dir> --out <dir>
#                                  [--predecessor <envelope>] [--json]
#   fm-review-envelope.sh validate --envelope <dir|file> --repo <dir>
#                                  (--evidence-root <dir> | --no-evidence-recheck)
#                                  [--json]
#   fm-review-envelope.sh show     --envelope <dir|file>
#   fm-review-envelope.sh schema
#   fm-review-envelope.sh docs
#   fm-review-envelope.sh -h | --help
#
# prepare derives the candidate's facts from the repository, binds them to the
# project's declared identities, digests and results, and writes
# <out>/envelope.json. It is write-once: an output already holding an envelope
# is refused, because overwriting a generation is how a superseded envelope
# silently becomes the current one.
#
# validate re-reads a stored envelope, recomputes its digest, and re-derives
# the classification against the repository as it stands now. An envelope
# whose candidate reference has moved, whose base has moved, or whose base has
# fallen further behind the trunk than policy allows is refused here - that is
# the whole point of a separate validation step, and why no verdict is ever
# stored inside the envelope.
#
# validate has to be told what to do about evidence bytes, and will not guess.
# Pass --evidence-root to re-read and re-digest every bound artifact. Pass
# --no-evidence-recheck to skip that deliberately; the declination is recorded
# in the classification and the result can never be review-ready, because the
# bytes behind the bound digests were not looked at.
#
# show prints the stored document. schema prints the machine-readable field
# catalog. docs renders docs/contracts/review-envelope.md from that catalog;
# the catalog is the single owner and the page is generated, so there is no
# second hand-written copy to drift against it.
#
# --json prints the full classification as JSON instead of human lines.
#
# Output for prepare and validate is exactly one bin/fm-verify.sh record after
# the classification, so a consumer reads the result through fm_verify_case and
# cannot write a two-branch read of a three-valued answer:
#
#   verify[1]{verifier,result,reason,evidence_ref}:
#     review-envelope,FAIL,verifier_reported_failure,/path/to/envelope.json
#
# Exit status is 0 for REVIEW_READY and only for REVIEW_READY, 1 for REFUSED,
# and 2 for COULD_NOT_OBSERVE, matching bin/fm-verify.sh so that a caller
# reading nothing but the status still gets the fail-closed answer.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-review-envelope-lib.sh
. "$SCRIPT_DIR/fm-review-envelope-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# Could-not-observe is the only way out that is not an observation. It exits 2,
# never 0 and never 1, so no caller can reach a verdict through it.
cno() {
  printf 'fm-review-envelope: COULD_NOT_OBSERVE: %s\n' "$1" >&2
  printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  %s,%s,%s,%s\n' \
    review-envelope NO_VERIFIER_RAN "${2:-verifier_unavailable}" -
  exit 2
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    usage
    exit 2
    ;;
  schema|docs)
    command -v python3 >/dev/null 2>&1 \
      || cno "python3 is unavailable, so the contract could not be read"
    shift
    fm_review_envelope_python "$COMMAND" "$@"
    exit $?
    ;;
  show)
    command -v python3 >/dev/null 2>&1 \
      || cno "python3 is unavailable, so no envelope could be read"
    shift
    fm_review_envelope_python show "$@"
    exit $?
    ;;
  prepare|validate) ;;
  *)
    cno "unknown subcommand: $COMMAND" usage_error
    ;;
esac

command -v python3 >/dev/null 2>&1 \
  || cno "python3 is unavailable, so no envelope could be compiled or classified"
command -v git >/dev/null 2>&1 \
  || cno "git is unavailable, so no candidate fact could be observed"

shift

# The evidence reference the record points at is the envelope itself, resolved
# from whichever argument named it, so a consumer following the record reaches
# the bound facts rather than this run's transient output.
EVIDENCE_REF=-
WANT=
for ARG in "$@"; do
  case "$WANT" in
    out) EVIDENCE_REF=$ARG/envelope.json ;;
    envelope) EVIDENCE_REF=$ARG ;;
  esac
  WANT=
  case "$ARG" in
    --out) WANT=out ;;
    --out=*) EVIDENCE_REF=${ARG#--out=}/envelope.json ;;
    --envelope) WANT=envelope ;;
    --envelope=*) EVIDENCE_REF=${ARG#--envelope=} ;;
  esac
done

SUMMARY=$(mktemp "${TMPDIR:-/tmp}/.fm-review-envelope.XXXXXX") \
  || cno "no summary file could be created"
trap 'rm -f "$SUMMARY"' EXIT

fm_review_envelope_python "$COMMAND" --summary-out "$SUMMARY" "$@"

# The result is read from the summary the classifier wrote, never from the exit
# status: a killed or crashed compiler leaves no summary, and that absence is
# could-not-observe rather than whatever its status happened to be.
RESULT=$(sed -n 's/^result=//p' "$SUMMARY" | head -1)
REASON=$(sed -n 's/^reason=//p' "$SUMMARY" | head -1)
case "$RESULT" in
  PASS|FAIL|NO_VERIFIER_RAN) ;;
  *)
    RESULT=NO_VERIFIER_RAN
    REASON=no_evidence
    ;;
esac
[ -n "$REASON" ] || REASON=no_evidence

printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  %s,%s,%s,%s\n' \
  review-envelope "$RESULT" "$REASON" "$EVIDENCE_REF"

case "$RESULT" in
  PASS) exit 0 ;;
  FAIL) exit 1 ;;
  *) exit 2 ;;
esac
