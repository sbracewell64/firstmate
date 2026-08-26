#!/usr/bin/env bash
# fm-attest.sh - emit and verify the head-bound no-mistakes attestation.
#
# The attestation is a git note on refs/notes/no-mistakes keyed by the exact
# commit it covers, so it binds to one head instead of to mutable pull request
# prose. A note never rewrites the branch, so emitting one cannot disturb the
# pipeline's custody of it, and the ref reaches the forge as an ordinary ref
# that a pull_request workflow can read with contents: read.
#
# Usage:
#   fm-attest.sh write [--run <id>] [--remote <name>] [--no-push] [--no-recheck] [--only-if-required {--policy-meta <file>|--policy-venue <host/owner/repo> --policy-url <url> --policy-ref <ref>}] [--expect-head <sha>] [--notes-ref <ref>]
#   fm-attest.sh recheck --head <sha> [--repo <owner/name> --pr <number>] [--remote <name>] [--notes-ref <ref>] [--dry-run]
#   fm-attest.sh required --policy-venue <host/owner/repo> --policy-url <url> --policy-ref <ref>
#   fm-attest.sh declaration-check
#   fm-attest.sh show [--commit <rev>] [--notes-ref <ref>]
#   fm-attest.sh verify --head <sha> [--notes-ref <ref>]
#   fm-attest.sh reconcile --head <sha> --remote <name> --pr <number> --pr-remote <name> [--notes-ref <ref>] [--window <seconds>] [--poll <seconds>]
#   fm-attest.sh --supports <capability>
#   fm-attest.sh --print-format
#   fm-attest.sh --help
#
# write reads the local pipeline run record through `no-mistakes axi status`,
# refuses unless that run covers this branch and completed every required
# validation step, then writes the note on the head that run validated and
# pushes the ref. That head is not always HEAD: the pipeline's own fix commits
# advance the run tip past the local checkout, and bin/fm-nm-run-lib.sh owns the
# rule that decides whether a run belongs to a worktree for every caller that
# has to ask, so this reads it from there rather than re-deriving it. Having
# published, it runs recheck on that head, because publishing evidence repairs
# the evidence and not the verdict.
#
# recheck is what makes the verdict follow the evidence. It confirms that the
# repository the check reads now serves a valid attestation for that exact head,
# finds the open pull request the head belongs to, and re-runs the workflow run
# that already judged it, which is GitHub's own way of re-deriving a verdict for
# an unchanged head. It is bounded, idempotent, and durably records each request
# before making it. It never reports anything about the check itself: GitHub
# stays the only place a verdict comes from. --no-recheck on write skips it.
#
# required answers, for one checkout, whether this repository's own CI reads a
# head-bound attestation at all. It is the predicate that lets an unconditional
# publication step be safe in every repository: a caller that must publish where
# the gate exists, and must touch nothing where it does not, asks here rather
# than deciding for itself. Three-valued like every other observation in this
# repository, and its exit status is the whole answer.
#
# verify is the CI side. It reads a note already fetched into this repository
# and reports one distinct reason per failure, so an absent attestation is
# never reported as a rejected one and never as a passing one.
#
# reconcile is the CI side's bounded window. A genuinely pipeline-raised head is
# pushed before its note exists, so the check's first look can be a near miss
# rather than a verdict about the change. reconcile re-reads the authoritative
# ref for a short, explicit bound while - and only while - no note exists for
# this head yet, then hands the terminal verdict to verify. It never reaches a
# verdict of its own, so nothing can pass except through verify.
#
# Every exit from either side names its own cause. A refusal (exit 1) is a
# verdict on the evidence; a failure (exit 2) means no verdict was reached, and
# the two are never worded as each other. docs/no-mistakes-attestation.md lists
# the full set.
#
# The attestation records what the pipeline did to one commit. It is not a
# proof of who ran the pipeline: a locally run pipeline holds only credentials
# its own operator holds, so no artifact it emits can be unforgeable by that
# operator. docs/no-mistakes-attestation.md owns that boundary in full.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# The publication guard's decision layer. Sourced here rather than inside the
# publish path so a missing owner is a load failure at the top of the command,
# not a surprise at the moment the remote would have moved.
# shellcheck source=bin/fm-outbound-artifact-lib.sh
. "$SCRIPT_DIR/fm-outbound-artifact-lib.sh"
# shellcheck source=bin/fm-sol-control-config-lib.sh
. "$SCRIPT_DIR/fm-sol-control-config-lib.sh"
# shellcheck source=bin/fm-landing-authorization-lib.sh
. "$SCRIPT_DIR/fm-landing-authorization-lib.sh"
# shellcheck source=bin/fm-landing-seam-lib.sh
. "$SCRIPT_DIR/fm-landing-seam-lib.sh"
# shellcheck source=bin/fm-publication-seam-lib.sh
. "$SCRIPT_DIR/fm-publication-seam-lib.sh"
# shellcheck source=bin/fm-task-base-lib.sh
. "$SCRIPT_DIR/fm-task-base-lib.sh"

# Every call to the pipeline is bounded, so a tool blocked on a lock or on a
# network read refuses with its own reason instead of hanging at a terminal.
# bin/fm-timeout-lib.sh owns imposing that bound and falls back to a
# dependency-free bash watchdog, so no host is refused for lacking a utility.
#
# A non-positive bound is not a bound, and that owner states the rule for every
# caller: `timeout 0` and the perl fallback's `alarm 0` both disable the deadline
# outright. A zero here would therefore not shorten the bound, it would remove it
# on a host with timeout or gtimeout and expire every read instantly on one
# falling back to the watchdog, so the same value would produce opposite failures
# on two hosts. An unusable value falls back to the default rather than removing
# the bound, which is the same reading the repository's other bounded callers
# apply to their own knobs.
NM_TIMEOUT=${FM_ATTEST_NM_TIMEOUT:-20}
case "$NM_TIMEOUT" in '' | *[!0-9]* | 0*) NM_TIMEOUT=20 ;; esac

NOTES_REF_DEFAULT=refs/notes/no-mistakes
ATTESTATION_VERSION=v1
ATTESTATION_KEY=no-mistakes-attestation

# Steps a contribution must have completed for the attestation to mean what the
# gate claims: this exact commit was reviewed, tested, linted, and pushed by the
# pipeline rather than assembled by hand. Recorded steps beyond these are kept
# in the note but are not required, because a repository may legitimately skip
# intent, rebase, document, pr, or ci for a given run.
REQUIRED_GATES='review test lint push'

# Every key a v1 note may carry. An unknown key is malformed rather than
# ignored, so a future format can never be read as a weaker v1 one.
KNOWN_KEYS="$ATTESTATION_KEY head run gates tool"

# ---------------------------------------------------------------------------
# recheck - the re-evaluation side
# ---------------------------------------------------------------------------
#
# The note can only exist after the push it attests, and that push is what
# started the check, so a genuinely pipeline-raised head can still reach a first
# refusal when its evidence lands after reconcile's bounded window. Publishing
# the note repairs the evidence but not that verdict: refs/notes/no-mistakes is
# not a pull request head, so pushing it fires no pull_request event and nothing
# re-reads the head. recheck is what re-reads it, so that publishing an
# attestation converges on its own instead of waiting for someone to close and
# reopen a pull request.
#
# It re-runs the workflow run that already evaluated this exact head. That is
# GitHub's own supported mechanism and it keeps GitHub the single authority: the
# same event payload replays, so the job checks out the same head.sha, fetches
# the ref afresh, and re-derives its verdict from the evidence now present. No
# second check, no second truth store, and nothing that could report a head as
# green without the workflow itself saying so.
#
# The workflow whose run is re-run is named here rather than inferred, because
# "the applicable check" has to be a binding rather than a guess.
RECHECK_WORKFLOW_FILE=no-mistakes-required.yml

# The most re-evaluations one repository, pull request and head may be given. A
# re-trigger that does not converge is a fault to report rather than a thing to
# repeat, and an unbounded retry against a forge is how a repair becomes an
# outage. The bound is spent by every attempt, including one whose request never
# reached GitHub, so a broken forge cannot buy unlimited attempts.
RECHECK_MAX=3

# How long recheck waits for a run already in flight on this head. A run that
# started before the note was published cannot be re-run while it is still
# going, and its verdict is not knowable from outside until it ends: it may have
# fetched the ref before the note landed, or after. This wait is on the
# contributor's machine and never inside a job, so it cannot make any check
# slower to report, and it is bounded rather than open-ended.
#
# 0 is a real value here and means "do not wait, report the run in flight",
# unlike FM_ATTEST_NM_TIMEOUT above where 0 would remove a deadline rather than
# shorten it. Anything that is not a non-negative integer falls back to the
# default, which is the same reading every other bounded knob in this repository
# applies to an unusable value.
RECHECK_WAIT=${FM_ATTEST_RECHECK_WAIT:-180}
case "$RECHECK_WAIT" in '' | *[!0-9]*) RECHECK_WAIT=180 ;; esac
RECHECK_POLL=${FM_ATTEST_RECHECK_POLL:-10}
case "$RECHECK_POLL" in '' | *[!0-9]* | 0*) RECHECK_POLL=10 ;; esac
RECHECK_LOCK_WAIT=${FM_ATTEST_RECHECK_LOCK_WAIT:-10}
case "$RECHECK_LOCK_WAIT" in '' | *[!0-9]*) RECHECK_LOCK_WAIT=10 ;; esac

# The ledger record type. One line per decision, in this script's own validated
# tokens, so what was re-triggered and why can be audited afterwards without
# asking the forge what it thinks it was told.
RECHECK_RECORD=fm-attest-recheck.v1

# ---------------------------------------------------------------------------
# reconcile - the bounded window before a terminal verdict
# ---------------------------------------------------------------------------
#
# recheck above repairs the VERDICT after the evidence lands. This repairs the
# FIRST look, and the two are layered rather than alternatives: a short window
# absorbs the near miss, and recheck remains the recovery for everything past
# it. Neither is a second truth store, because neither reaches a verdict -
# recheck asks GitHub to re-derive one and this hands one to verify.
#
# How long to wait is the only judgement here, and it was measured rather than
# picked. Across 45 attestations published to this repository, the delay from
# the pull request event that started a check to the note being published ran
# from 9 seconds to 1815, with a median of 200. Those observations cluster: 11
# of the 45 land within 55 seconds and the next one is at 75, because the short
# ones are a publication that raced its own push while the long ones are a
# pipeline still working. 60 seconds covers that cluster and stops before the
# tail begins.
#
# It is deliberately NOT sized to the tail. Waiting out a pipeline would be an
# unbounded wait wearing a bound: it would hold a runner for the length of
# somebody else's validation run, and the head would still be unattested for
# every second of it. The tail is recheck's, and docs/no-mistakes-attestation.md
# owns what this covers and what it does not.
#
# 0 is a real value here and means "look once, do not wait", which is what the
# window collapses to when the caller does not want one. A poll of 0 would spin,
# so an unusable poll falls back to the default; this is the same reading the
# recheck knobs above apply to their own values.
RECONCILE_WINDOW=${FM_ATTEST_RECONCILE_WINDOW:-60}
case "$RECONCILE_WINDOW" in '' | *[!0-9]*) RECONCILE_WINDOW=60 ;; esac
RECONCILE_POLL=${FM_ATTEST_RECONCILE_POLL:-15}
case "$RECONCILE_POLL" in '' | *[!0-9]* | 0*) RECONCILE_POLL=15 ;; esac

# What this program can be asked to do, for a caller that has to know before
# asking. The workflow runs this script from the pull request's own head, so a
# head raised before a subcommand existed does not carry it, and a caller that
# probed by running it could not tell "this program does not do that" from
# "that failed". Answering as an exit status rather than as text keeps the probe
# out of the business of reading messages.
CAPABILITIES="write verify recheck reconcile show required declaration-check"

# ---------------------------------------------------------------------------
# printing - the one path text leaves this script by
# ---------------------------------------------------------------------------

# git quotes the push URL back in its own messages, and the server's rejection
# reason arrives in the same stream. Suppressing that stream keeps a credential
# out of the log but throws the rejection reason away with it, which leaves a
# contributor blocked by a ruleset or a quota with nothing to act on. So text is
# made safe to print rather than withheld wholesale.
#
# This comment owns the safety rationale; bin/fm-publication-seam-lib.sh owns the
# shared implementation used by both attestation and the publication guard.
#
# One function does it for everything this prints, git's output, the pipeline
# tool's two streams and the push target alike, and that is enforced by where it
# sits rather than by every author remembering it. emit() below is the only
# place this script constructs a line and writes it, and every line it writes
# passes through the scrubber first, so a diagnostic carrying text from outside
# this script cannot be constructed unscrubbed: a refusal added later is safe
# because printing is what makes it safe. Scrubbing at each call site was the
# shape this had, and it grew a channel that was never scrubbed, for the same
# reason parse-then-redact grew shapes that were never modelled.
#
# A shell script also runs programs that hold streams of their own, and that
# half is closed from the other side rather than left to the same claim: every
# git call and every call to the pipeline tool has its stdout and stderr either
# captured into a variable or discarded, so no stream that could carry external
# text reaches a terminal except through emit(). The scratch-file helpers here
# are discarded for the same reason bin/fm-timeout-lib.sh discards its own, and
# nothing diagnostic is lost by it because the refusal that follows names the
# condition in this script's own words.
#
# It is default deny, and that is the whole design. Redacting what a reader
# recognises means every shape git accepts has to be modelled, and any shape it
# does not model is emitted intact: absence of detection read as absence of a
# credential, which is the same mistake as reading an empty check set as green.
# Two such shapes reached the log before this inversion. So a word that could
# carry a credential is emitted ONLY when it positively matches a shape that has
# no place for one, or can be rewritten into one; unparseable, ambiguous,
# unfamiliar or merely unmatched all withhold.
#
# Withholding is by LINE, not by word. Words are split on spaces, so a URL whose
# credential holds one arrives here as two words, and the tail of it can match a
# shape the whole never would - emitting a host and path that were never a
# remote, beside a marker, reading as two places when there was one. Partial
# emission is what has bitten this twice, so a line holding anything withheld is
# withheld entire. The alternatives, not splitting on spaces or letting a marker
# absorb what follows it, are both more parsing, and parsing is the part that
# keeps failing.
#
# Two shapes are modelled. A scheme URL is emitted without its userinfo, and
# never contains an '@' at all afterwards, so nothing turns on where a reader
# believes the authority ends. An scp-style [user@]host:path is emitted without
# its user, because that form has no password field: its colon separates host
# from path. That last point is the whole guard, so it is stated as a rule
# rather than left to the regex to imply - a colon BEFORE the '@' is exactly
# where a password would live, so a token carrying one is not this shape and is
# withheld. Neither shape reaches into a query or fragment: a '?' or '#' is
# exactly where a token credential lives in a remote URL or a presigned link,
# so a form carrying either is not credential-free and is withheld like any
# other unproven shape. Adding a modelled shape is default deny working;
# excepting one from it is not, and the difference is the entire safety of this
# function.
#
# The cost is deliberate: an address, or a URL with an '@' after its host, is
# withheld even though it holds no secret, and it takes its line with it. The
# marker says so in its place, because an omission the reader knows about is
# recoverable and a silent one is not. A line with no URL-shaped word is
# untouched, so the server's own rejection reason still reaches the person who
# has to act on it.
credential_safe_stream() {
  fm_pub_seam_credential_safe_stream
}

# The one place this script constructs a line and writes it. Callers hand it
# whole lines and it writes them safe; a caller that wants them on stderr
# redirects the call.
emit() {
  [ "$#" -gt 0 ] || return 0
  printf '%s\n' "$@" | credential_safe_stream
}

# Names one repository safely, once, so that a target whose URL cannot be shown
# is replaced by the marker inside the sentence naming it rather than taking the
# whole sentence with it. This is the same scrubber emit() applies and not a
# second one: emitting the result again changes nothing, because a form already
# proved to have no place for a credential still positively matches.
credential_safe_text() {
  [ -n "$1" ] || {
    printf '(nothing)'
    return 0
  }
  printf '%s\n' "$1" | credential_safe_stream
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" | credential_safe_stream >&2
}

# Three exits, and the difference between them is the whole error model.
#
#   refuse <reason>   exit 1, "not attested": the evidence was examined and
#                     found absent, unbound, or invalid. A verdict.
#   fail <reason>     exit 2, "cannot attest": the command could not carry the
#                     work out, so it reached no verdict and says nothing about
#                     the evidence either way.
#   die               exit 2, caller misuse: an argument this program cannot
#                     act on at all, named in plain words because there is no
#                     state to describe.
#
# Every refusal and every failure carries its own machine-readable reason, and
# no condition borrows another's. That rule is the one this component keeps
# having to relearn: an unreadable record reported as head divergence, or a
# missing utility reported as a tool exit, sends a reader to repair something
# that was never broken and to hit the identical message again.
#
# Both forms take prose details after the reason, indented line by line, so a
# refusal can quote a tool's own output verbatim instead of paraphrasing it.
# Verbatim means the wording is the tool's rather than a paraphrase of it; it
# still leaves through emit(), so quoting a stream is safe by construction and a
# reason added later inherits that without its author arranging anything.
die() {
  emit "fm-attest: $*" >&2
  exit 2
}

report() {
  headline=$1
  reason=$2
  shift 2
  emit "fm-attest: $headline ($reason)" >&2
  while [ "$#" -gt 0 ]; do
    emit "$1" | sed 's/^/  /' >&2
    shift
  done
}

refuse() {
  report 'not attested' "$@"
  exit 1
}

fail() {
  report 'cannot attest' "$@"
  exit 2
}

# recheck's own two headlines, and they are deliberately not the two above.
# "attested" is a statement about the EVIDENCE; re-evaluation is a different
# subject, and a head can carry perfect evidence and still not be re-evaluated.
# Borrowing "not attested" for that would send a reader to republish a note that
# is already correct, which is exactly the class of mistake the error model in
# this file exists to prevent.
#
#   recheck_refuse <reason>  exit 1: the re-evaluation was considered and is not
#                            being carried out, and the reason is a fact about
#                            this head, this pull request, or this repository.
#   recheck_fail <reason>    exit 2: the re-evaluation could not be carried out
#                            or could not be judged, so nothing here says
#                            whether the check would now pass.
#
# Genuinely invalid evidence is NOT one of these. It exits through refuse()
# above with the verifier's own reason, because "the note published for this
# head is not a valid attestation" is a verdict on the evidence and must not be
# reported as a re-evaluation that did not happen.
recheck_refuse() {
  report 'not re-evaluated' "$@"
  recheck_publication_note
  exit 1
}

recheck_fail() {
  report 'cannot re-evaluate' "$@"
  recheck_publication_note
  exit 2
}

# Set while recheck runs as write's own last step, and read only by the two
# reporters above. write reaches recheck only after git push has succeeded, so a
# reader who sees a non-zero exit there has already published the note; without
# this line the obvious repair is to publish it again, which is both useless and
# the wrong place to look.
RECHECK_FROM_WRITE=0
RECHECK_HEAD=
recheck_publication_note() {
  [ "$RECHECK_FROM_WRITE" -eq 1 ] || return 0
  {
    emit "This ran as the last step of 'write', after the attestation was recorded and pushed."
    emit "Repair what is named above rather than publishing the note again, then re-run only"
    emit "the re-evaluation:"
    emit ""
    emit "    bin/fm-attest.sh recheck --head $RECHECK_HEAD"
  } >&2
}

is_full_sha() {
  case "$1" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

is_short_sha() {
  case "$1" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#1}" -ge 4 ] && [ "${#1}" -le 40 ]
}

is_run_id() {
  case "$1" in
    '' | *[!0-9A-Za-z_-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

is_gate_name() {
  case "$1" in
    '' | *[!0-9a-z-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

is_tool_token() {
  case "$1" in
    '' | *[!0-9A-Za-z._/+-]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

# owner/name, exactly two segments. Everything downstream interpolates this into
# an API path and into a ledger field, so it is checked as a whole shape rather
# than trusted because it came from a remote URL or from the forge.
is_repo_slug() {
  case "$1" in
    '' | /* | */ | */*/*) return 1 ;;
    *[!0-9A-Za-z._/-]*) return 1 ;;
    */*) return 0 ;;
  esac
  return 1
}

# One repository's identity, for COMPARING and for KEYING only.
#
# GitHub repository names are case-insensitive: `Owner/Repo` and `owner/repo`
# are one repository. The two spellings reach this program from different
# places and neither is wrong - bin/fm-task-base-lib.sh lowercases a remote
# URL, while GitHub's API returns its own canonical casing - so any comparison
# between them has to go through here rather than matching raw text. Two
# separate defects came from doing it raw: a re-run refused because the same
# repository was spelled two ways, and a per-head request bound that reset when
# the caller retyped the name differently, because the ledger was keyed on the
# spelling instead of on the repository.
#
# What gets PRINTED never comes from here. A message that renames a repository
# is harder to act on than one that leaves it as the reader wrote it, so every
# diagnostic keeps the original spelling and only the comparison is normalized.
repo_identity() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# A positive decimal with no leading zero, used for pull request numbers, run
# identities and attempt counts. Run identities are compared arithmetically
# below, so a value that is not a plain number is refused rather than coerced.
is_positive_number() {
  case "$1" in
    '' | 0* | *[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 19 ]
}

# Membership in a space-separated list. Every needle this script passes is a
# token already validated against its own character class, so padding both sides
# and matching whole words is exact.
list_has() {
  case " $2 " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

print_format() {
  emit \
    "$ATTESTATION_KEY: $ATTESTATION_VERSION" \
    'head: <the 40-character lowercase sha of the commit this attests>' \
    'run: <the pipeline run identity that validated it>' \
    'gates: <comma-separated pipeline steps that completed for that head>' \
    'tool: <the pipeline binary and version that ran them>'
}

# ---------------------------------------------------------------------------
# verify - the CI side
# ---------------------------------------------------------------------------

cmd_verify() {
  head=
  notes_ref=$NOTES_REF_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        [ "$#" -ge 2 ] || die "--head needs a value"
        head=$2
        shift 2
        ;;
      --notes-ref)
        [ "$#" -ge 2 ] || die "--notes-ref needs a value"
        notes_ref=$2
        shift 2
        ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$head" ] || die "verify needs --head <sha>"
  is_full_sha "$head" || die "--head must be a 40-character lowercase sha"

  git rev-parse --git-dir >/dev/null 2>&1 || fail not-a-git-repository \
    "This directory is not inside a git repository."

  # A head whose commit object is absent cannot be attested or refuted here.
  # Report it as its own state rather than as a missing note, because the two
  # need different repairs.
  git rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1 \
    || refuse head-commit-unavailable \
      "The commit $head is not present in this checkout." \
      "Check out the pull request head before verifying its attestation."

  git rev-parse --verify --quiet "$notes_ref" >/dev/null 2>&1 \
    || refuse no-attestation-ref \
      "This repository holds no $notes_ref, so no attestation was published or fetched." \
      "Absence of evidence is not evidence: this is a refusal, not a pass."

  # git reports a note genuinely absent for this head as exit 1 and a ref it
  # cannot read as notes at all - one resolving to a blob, say - as a fatal
  # error. The two need different repairs: publishing a note can never mend a
  # damaged ref, so neither may borrow the other's reason.
  note_rc=0
  note=$(git notes --ref="$notes_ref" show "$head" 2>/dev/null) || note_rc=$?
  [ "$note_rc" -ne 1 ] || refuse no-attestation-for-head \
    "$notes_ref exists but carries no attestation for $head." \
    "An attestation for any other commit says nothing about this one."
  [ "$note_rc" -eq 0 ] || refuse attestation-ref-unreadable \
    "$notes_ref resolves but cannot be read as notes (git notes exited $note_rc)." \
    "Publishing an attestation cannot repair a damaged ref: repair or delete $notes_ref on the repository the gate reads, then publish afresh."

  verify_note_payload "$head" "$note"

  emit "fm-attest: attested $head (run $note_run, gates $note_gates, $note_tool)"
}

# Parses and checks one note payload. Sets note_run/note_gates/note_tool for the
# caller's success line. Every failure path exits through refuse().
verify_note_payload() {
  expect_head=$1
  payload=$2

  seen_keys=
  note_version=
  note_head=
  note_run=
  note_gates=
  note_tool=

  while IFS= read -r line; do
    # Tolerate a trailing CR so a note written on another platform is read the
    # same way, but nothing else: no blank lines, no comments, no continuations.
    line=${line%$'\r'}
    [ -n "$line" ] || refuse attestation-malformed \
      "The attestation for $expect_head contains a blank line." \
      "A v1 attestation is exactly one 'key: value' line per field."

    case "$line" in
      *': '*) ;;
      *)
        refuse attestation-malformed \
          "The attestation for $expect_head has a line that is not 'key: value': $line"
        ;;
    esac
    key=${line%%': '*}
    value=${line#*': '}

    list_has "$key" "$KNOWN_KEYS" || refuse attestation-malformed \
      "The attestation for $expect_head carries an unknown field '$key'." \
      "A v1 attestation is rejected rather than partly understood."
    list_has "$key" "$seen_keys" && refuse attestation-malformed \
      "The attestation for $expect_head repeats the field '$key'."
    seen_keys="$seen_keys $key"

    case "$key" in
      "$ATTESTATION_KEY") note_version=$value ;;
      head) note_head=$value ;;
      run) note_run=$value ;;
      gates) note_gates=$value ;;
      tool) note_tool=$value ;;
    esac
  done <<EOF
$payload
EOF

  [ "$note_version" = "$ATTESTATION_VERSION" ] || refuse attestation-malformed \
    "The attestation for $expect_head does not declare $ATTESTATION_KEY: $ATTESTATION_VERSION." \
    "Only the format this gate understands is accepted."

  for key in head run gates tool; do
    list_has "$key" "$seen_keys" || refuse attestation-malformed \
      "The attestation for $expect_head is missing the required field '$key'."
  done

  is_full_sha "$note_head" || refuse attestation-malformed \
    "The attestation for $expect_head names a head that is not a 40-character lowercase sha."
  is_run_id "$note_run" || refuse attestation-malformed \
    "The attestation for $expect_head names an unusable run identity."
  is_tool_token "$note_tool" || refuse attestation-malformed \
    "The attestation for $expect_head names an unusable tool identity."

  # The binding this whole gate rests on: the attestation must name the commit
  # under review, not merely sit near it. A note moved, copied, or carried
  # across a rewrite fails here.
  [ "$note_head" = "$expect_head" ] || refuse attestation-not-bound \
    "The attestation attached to $expect_head attests $note_head instead." \
    "An attestation that does not name this exact commit does not cover it."

  case "$note_gates" in
    ,* | *, | *,,* | '')
      refuse attestation-malformed \
        "The attestation for $expect_head has an unusable 'gates' list: $note_gates"
      ;;
  esac
  gates_list=$(printf '%s' "$note_gates" | tr ',' ' ')
  for gate in $gates_list; do
    is_gate_name "$gate" || refuse attestation-malformed \
      "The attestation for $expect_head names an unusable pipeline step '$gate'."
  done
  for gate in $REQUIRED_GATES; do
    list_has "$gate" "$gates_list" || refuse attestation-missing-gate \
      "The attestation for $expect_head does not record a completed '$gate' step." \
      "Required steps: $REQUIRED_GATES."
  done
}

# ---------------------------------------------------------------------------
# reconcile - the CI side's bounded window
# ---------------------------------------------------------------------------
#
# One question only: is there any evidence for this head yet? Whether evidence
# is valid, bound, complete or readable is verify's, and reconcile ends by
# asking it. That split is the whole safety of the window: it can delay a
# verdict, it cannot reach one, and it cannot delay one already reached.

# This host's clock, or a stop. A window whose end cannot be computed is not a
# bounded wait, and guessing one would be the unbounded wait this must not be.
reconcile_clock() {
  reconcile_epoch=$(date +%s 2>/dev/null) || reconcile_epoch=
  is_positive_number "$reconcile_epoch" || fail clock-unreadable \
    "This host's clock could not be read, so the re-read window could not be bounded." \
    "Nothing was waited for, and this says nothing about whether $reconcile_head carries an attestation."
}

# One repository, named for a reader rather than for git. The caller passes
# configured remote names, so a credential in a remote's URL stays in git's
# configuration and never crosses this program's interface; but "the remote
# 'attestation-source' would not serve it" sends nobody anywhere, so the URL is
# resolved back out and made safe to print by the same scrubber every other line
# here goes through. A URL that cannot be proved credential-free is replaced by
# the marker rather than shown, and the remote's own name still names it.
reconcile_repository_name() {
  reconcile_url=$(git remote get-url "$1" 2>/dev/null) || reconcile_url=
  if [ -z "$reconcile_url" ]; then
    printf "the remote '%s'" "$1"
    return 0
  fi
  printf '%s' "$(credential_safe_text "$reconcile_url")"
}

# The one place this program reads the attestation ref from the repository the
# check reads: the first look and every re-read in the window go through here,
# so the two can never come to disagree about what an unreadable repository
# means.
#
# Three answers, three rather than two on purpose. The ref advertised and
# fetched is evidence for verify to judge. The ref not being there at all is an
# ordinary state - a repository that has never carried an attestation - and is
# left absent for verify to name in its own words. Anything else is a read that
# did not happen, and it stops the command rather than being resolved as either
# of the first two.
reconcile_read_source() {
  reconcile_ls_rc=0
  git ls-remote --exit-code "$reconcile_remote" "$reconcile_notes_ref" >/dev/null 2>&1 \
    || reconcile_ls_rc=$?
  case "$reconcile_ls_rc" in
    0)
      git fetch --quiet --no-tags --force "$reconcile_remote" \
        "$reconcile_notes_ref:$reconcile_notes_ref" >/dev/null 2>&1 \
        || fail attestation-source-unfetchable \
          "$reconcile_source advertises $reconcile_notes_ref but would not serve it." \
          "Not reading a repository is not reading an absence: this says nothing about whether $reconcile_head carries an attestation."
      ;;
    2)
      git update-ref -d "$reconcile_notes_ref" >/dev/null 2>&1 \
        || fail attestation-source-unfetchable \
          "$reconcile_source serves no $reconcile_notes_ref, but the local copy could not be cleared." \
          "The authoritative absence could not be reconciled with the evidence verify would read."
      ;;
    *)
      fail attestation-source-unreadable \
        "$reconcile_notes_ref could not be read from $reconcile_source (git exited $reconcile_ls_rc)." \
        "Not reading a repository is not reading an absence: this says nothing about whether $reconcile_head carries an attestation."
      ;;
  esac
}

# Whether this head has no evidence yet, which is the only state worth waiting
# through. These are deliberately the same two conditions verify reports as
# head-commit-unavailable and no-attestation-ref / no-attestation-for-head, read
# here as "nothing to verify yet" rather than as a verdict:
#
#   head commit absent          not waiting. No publication puts a commit in
#                               this checkout, and verify says so in its words.
#   git notes exits 1           WAITING. The ref is not here, or carries nothing
#                               for this commit; a note published a moment from
#                               now changes exactly that.
#   git notes exits 0           not waiting. Evidence exists. Whether it is good
#                               is verify's to say, and to say immediately.
#   git notes exits otherwise   not waiting. A ref that cannot be read as notes
#                               is damaged rather than empty, and publishing
#                               into it repairs nothing.
#
# Absence is the only state that waits. Evidence already observed to be invalid,
# unbound, stale or unreadable leaves through verify on the first look, because
# a window that graced bad evidence would be buying time for the exact thing
# this check exists to refuse.
reconcile_absent() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1 || return 1
  reconcile_note_rc=0
  git notes --ref="$2" show "$1" >/dev/null 2>&1 || reconcile_note_rc=$?
  [ "$reconcile_note_rc" -eq 1 ]
}

# The pull request's head, re-read on every observation this window makes.
# Waiting is a bet that evidence for THIS head is about to arrive; once the
# request proposes a different commit, nobody is going to publish for this one
# and the remaining bound would be spent reaching the verdict already in hand.
#
# refs/pull/<n>/head is GitHub's own record of what a pull request proposes, so
# it answers that directly, over the same read-only protocol and to the same
# host as the attestation ref beside it. Nothing the check does not already hold
# is needed to read it.
#
# Movement is not a verdict and does not become one here: it ends the wait and
# leaves the verdict to verify, which still judges the head this run was raised
# for. Failing to read it at all is a read that did not happen and stops the
# command, because treating an unanswered question as "still ours" would be
# waiting on a fact never established. Returns 1 for movement, and does not
# return at all for a read that failed.
reconcile_revalidate_head() {
  reconcile_ls_rc=0
  reconcile_ls=$(git ls-remote --exit-code "$reconcile_pr_remote" \
    "refs/pull/$reconcile_pr/head" 2>/dev/null) || reconcile_ls_rc=$?
  case "$reconcile_ls_rc" in
    0) ;;
    2)
      fail pull-request-head-absent \
        "$reconcile_pr_source serves no refs/pull/$reconcile_pr/head, so the head under review could not be confirmed." \
        "That is a question that went unanswered rather than an attestation that is not there."
      ;;
    *)
      fail pull-request-head-unreadable \
        "refs/pull/$reconcile_pr/head could not be read from $reconcile_pr_source (git exited $reconcile_ls_rc)." \
        "Not reading a pull request's head is not reading a head that has not moved."
      ;;
  esac
  reconcile_current=${reconcile_ls%%$'\n'*}
  reconcile_current=${reconcile_current%%[!0-9a-f]*}
  is_full_sha "$reconcile_current" || fail pull-request-head-unreadable \
    "refs/pull/$reconcile_pr/head on $reconcile_pr_source did not name a commit."
  [ "$reconcile_current" = "$reconcile_head" ]
}

cmd_reconcile() {
  reconcile_head=
  reconcile_remote=
  reconcile_pr=
  reconcile_pr_remote=
  reconcile_notes_ref=$NOTES_REF_DEFAULT
  reconcile_window=$RECONCILE_WINDOW
  reconcile_poll=$RECONCILE_POLL
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        [ "$#" -ge 2 ] || die "--head needs a value"
        reconcile_head=$2
        shift 2
        ;;
      --remote)
        [ "$#" -ge 2 ] || die "--remote needs a value"
        reconcile_remote=$2
        shift 2
        ;;
      --pr)
        [ "$#" -ge 2 ] || die "--pr needs a value"
        reconcile_pr=$2
        shift 2
        ;;
      --pr-remote)
        [ "$#" -ge 2 ] || die "--pr-remote needs a value"
        reconcile_pr_remote=$2
        shift 2
        ;;
      --notes-ref)
        [ "$#" -ge 2 ] || die "--notes-ref needs a value"
        reconcile_notes_ref=$2
        shift 2
        ;;
      --window)
        [ "$#" -ge 2 ] || die "--window needs a value"
        case "$2" in '' | *[!0-9]*) die "--window must be a number of seconds" ;; esac
        reconcile_window=$2
        shift 2
        ;;
      --poll)
        [ "$#" -ge 2 ] || die "--poll needs a value"
        case "$2" in '' | *[!0-9]*) die "--poll must be a number of seconds" ;; esac
        [ "$2" -gt 0 ] || die "--poll must be more than zero, because a poll of zero does not pause"
        reconcile_poll=$2
        shift 2
        ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$reconcile_head" ] || die "reconcile needs --head <sha>"
  is_full_sha "$reconcile_head" || die "--head must be a 40-character lowercase sha"
  # All three travel together. Re-reading evidence without revalidating the head
  # would wait on a request that has moved on, and revalidating the head without
  # re-reading evidence would confirm the head and learn nothing new about it, so
  # neither half is a window on its own.
  [ -n "$reconcile_remote" ] || die "reconcile needs --remote <name>"
  [ -n "$reconcile_pr" ] || die "reconcile needs --pr <number>"
  is_positive_number "$reconcile_pr" || die "--pr must be a pull request number"
  [ -n "$reconcile_pr_remote" ] || die "reconcile needs --pr-remote <name>"

  git rev-parse --git-dir >/dev/null 2>&1 || fail not-a-git-repository \
    "This directory is not inside a git repository."
  reconcile_source=$(reconcile_repository_name "$reconcile_remote")
  reconcile_pr_source=$(reconcile_repository_name "$reconcile_pr_remote")

  reconcile_read_source

  if ! reconcile_absent "$reconcile_head" "$reconcile_notes_ref"; then
    cmd_verify --head "$reconcile_head" --notes-ref "$reconcile_notes_ref"
    return $?
  fi

  reconcile_revalidate_head || {
    {
      emit "fm-attest: pull request $reconcile_pr now proposes $reconcile_current, so waiting for an attestation on $reconcile_head stopped here."
      emit "The verdict below is about $reconcile_head, which is the commit this check was raised for."
    } >&2
    cmd_verify --head "$reconcile_head" --notes-ref "$reconcile_notes_ref"
    return $?
  }

  reconcile_clock
  reconcile_deadline=$((reconcile_epoch + reconcile_window))

  # Every path out of this loop reaches the same verdict below it. The loop
  # decides only how long the check keeps looking, and the sleep is clamped to
  # what remains, so the total waited is at most --window and never the window
  # plus one more poll.
  reconcile_exhausted=0
  while :; do
    reconcile_clock
    reconcile_left=$((reconcile_deadline - reconcile_epoch))
    if [ "$reconcile_left" -le 0 ]; then
      reconcile_exhausted=1
      break
    fi
    if [ "$reconcile_left" -gt "$reconcile_poll" ]; then
      reconcile_left=$reconcile_poll
    fi
    sleep "$reconcile_left"
    reconcile_read_source
    reconcile_absent "$reconcile_head" "$reconcile_notes_ref" || break
    reconcile_revalidate_head || {
      {
        emit "fm-attest: pull request $reconcile_pr now proposes $reconcile_current, so waiting for an attestation on $reconcile_head stopped here."
        emit "The verdict below is about $reconcile_head, which is the commit this check was raised for."
      } >&2
      break
    }
  done

  # The bound, said out loud at the only moment it decided anything. A reader
  # who has just been told this head is unattested is owed how long it was given
  # to become attested, because otherwise the one number that shaped the verdict
  # is the one number nowhere in it.
  [ "$reconcile_exhausted" -eq 0 ] || emit \
    "fm-attest: no attestation for $reconcile_head arrived in the ${reconcile_window}s window this check allows for one just published." >&2

  cmd_verify --head "$reconcile_head" --notes-ref "$reconcile_notes_ref"
}

# ---------------------------------------------------------------------------
# required - is a head-bound attestation read here at all?
# ---------------------------------------------------------------------------
#
# The publication step has to be unconditional to be reliable, and it has to
# touch nothing in a repository that never asked for it. Those two are only
# compatible if one place answers "does this repository read a head-bound
# attestation", so every caller asks the same question and gets the same answer.
# Deciding it at each call site is how a step becomes conditional on the caller
# recognising a repository, which is the recognition problem this repository
# already knows it cannot do from a name.
#
# The question is answered from what the repository DECLARES rather than from
# anything about its name, its remote, or the fleet it belongs to. The fixed
# declaration is a regular .github/no-mistakes-attestation file containing the
# exact line "fm-attest.v1 required".
#
# It is an OBSERVATION and not a verdict on evidence, so it does not borrow the
# refusal and failure headlines above. Reporting "not attested" for a repository
# that attests nothing would send a reader to publish a note no check reads.
# Three exits, and the third is a real answer rather than a missing one:
#
#   0  required      the exact declaration is present.
#   1  not required   the declaration is absent.
#   2  unobservable   the declaration could not be read, so this says NEITHER.
REQUIRED_DECLARATION=.github/no-mistakes-attestation
REQUIRED_DECLARATION_CONTENT='fm-attest.v1 required'

required_state=
required_evidence=
required_reason=
required_scratch_ref=

required_policy_cleanup() {
  [ -z "${required_scratch_ref:-}" ] || git update-ref -d "$required_scratch_ref" >/dev/null 2>&1
  required_scratch_ref=
}

required_policy_clear_traps() {
  trap - EXIT HUP INT TERM
}

required_declaration_observe() {
  required_declaration_commit=$1
  required_declaration_state=unobservable
  required_declaration_fault=
  required_declaration_entry=$(git ls-tree "$required_declaration_commit" -- "$REQUIRED_DECLARATION" 2>/dev/null) || {
    required_declaration_fault=unreadable
    return 0
  }
  if [ -z "$required_declaration_entry" ]; then
    required_declaration_state=absent
    return 0
  fi
  required_declaration_mode=${required_declaration_entry%% *}
  required_declaration_entry_rest=${required_declaration_entry#* }
  required_declaration_type=${required_declaration_entry_rest%% *}
  case "$required_declaration_mode:$required_declaration_type" in 100644:blob | 100755:blob) ;; *)
    required_declaration_fault=not-regular
    return 0
    ;;
  esac
  required_declaration_content=$(git cat-file -p "$required_declaration_commit:$REQUIRED_DECLARATION" 2>/dev/null) || {
    required_declaration_fault=unreadable
    return 0
  }
  required_declaration_size=$(git cat-file -s "$required_declaration_commit:$REQUIRED_DECLARATION" 2>/dev/null) || {
    required_declaration_fault=unreadable
    return 0
  }
  if [ "$required_declaration_content" != "$REQUIRED_DECLARATION_CONTENT" ] || [ "$required_declaration_size" != 22 ]; then
    required_declaration_fault=invalid
    return 0
  fi
  required_declaration_state=present
  return 0
}

# Whether the venue's CURRENT generation carries the declaration, so that an
# absence read from a supplied generation can be told apart from a superseded
# one. Sets required_currency to present, absent, or unobservable, plus
# required_current and required_currency_detail.
#
# It fetches the venue's own default branch from the governed URL into its own
# private scratch ref, under the same trap discipline as the generation read
# above, and never trusts an object that happens to be present locally: a
# candidate checkout routinely holds commits from several repositories, and one
# of those deciding another venue's currency is the same wrong-subject
# substitution the referential-integrity rule refuses one level down.
required_currency_observe() {
  required_currency=unobservable
  required_current=
  required_currency_detail=

  required_scratch_ref="refs/fm-attest/policy-current-$$"
  git update-ref -d "$required_scratch_ref" >/dev/null 2>&1 || true
  trap required_policy_cleanup EXIT
  trap 'required_policy_cleanup; exit 2' HUP INT TERM
  if ! git fetch --quiet --no-tags --force "$required_url" "HEAD:$required_scratch_ref" 2>/dev/null; then
    required_policy_cleanup
    required_policy_clear_traps
    required_currency_detail="the venue's current generation could not be fetched."
    return 0
  fi
  required_current=$(git rev-parse --verify --quiet "$required_scratch_ref^{commit}" 2>/dev/null) || required_current=
  required_current_fetched=$(git rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null) || required_current_fetched=
  required_policy_cleanup
  required_policy_clear_traps
  if [ -z "$required_current" ] || [ "$required_current" != "$required_current_fetched" ]; then
    required_currency_detail="the venue's current generation did not resolve to one matching commit."
    return 0
  fi

  # Equal generations cannot be stale, and answering from the entry already
  # read avoids a second tree read that could only agree with it.
  if [ "$required_current" = "$required_commit" ]; then
    required_currency=absent
    return 0
  fi

  required_declaration_observe "$required_current"
  case "$required_declaration_state" in
    present | absent) required_currency=$required_declaration_state ;;
    *) required_currency_detail="$REQUIRED_DECLARATION at the venue's current generation is ${required_declaration_fault:-unreadable}." ;;
  esac
  return 0
}

required_observe() {
  required_allow_checkout=${1:-0}
  required_venue=${2-}
  required_url=${3-}
  required_ref=${4-}
  required_state=
  required_evidence=
  required_reason=

  required_top=$(git rev-parse --show-toplevel 2>/dev/null) || required_top=
  [ -n "$required_top" ] || {
    required_state=unobservable
    required_reason=not-a-git-repository
    required_evidence="This directory is not inside a git repository, so no repository declares anything here."
    return 0
  }

  required_file="$required_top/$REQUIRED_DECLARATION"
  if [ "$required_allow_checkout" -eq 0 ]; then
    if [ -z "$required_venue" ] || [ -z "$required_url" ] || [ -z "$required_ref" ] \
      || [ "$required_venue" = unresolved ] || [ "$required_ref" = unresolved ]; then
      required_state=unobservable
      required_reason=policy-subject-missing
      required_evidence="The governed contribution venue and policy generation were not supplied unambiguously."
      return 0
    fi
    required_url_identity=$(task_base_venue_identity "$required_url" 2>/dev/null || true)
    required_url_alias=$(task_base_venue_identity_alias "$required_url" 2>/dev/null || true)
    if [ "$required_venue" != "$required_url_identity" ] && [ "$required_venue" != "$required_url_alias" ]; then
      required_state=unobservable
      required_reason=policy-subject-mismatch
      required_evidence="The governed venue $required_venue is inconsistent with its recorded repository URL."
      return 0
    fi
    required_scratch_ref="refs/fm-attest/policy-$$"
    git update-ref -d "$required_scratch_ref" >/dev/null 2>&1 || true
    trap required_policy_cleanup EXIT
    trap 'required_policy_cleanup; exit 2' HUP INT TERM
    if ! git fetch --quiet --no-tags --force "$required_url" "$required_ref:$required_scratch_ref" 2>/dev/null; then
      required_policy_cleanup
      required_policy_clear_traps
      required_state=unobservable
      required_reason=policy-ref-unreadable
      required_evidence="The policy generation $required_ref at $required_venue could not be fetched."
      return 0
    fi
    required_commit=$(git rev-parse --verify --quiet "$required_scratch_ref^{commit}" 2>/dev/null) || required_commit=
    required_fetched_commit=$(git rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null) || required_fetched_commit=
    required_policy_cleanup
    required_policy_clear_traps
    if [ -z "$required_commit" ] || [ "$required_commit" != "$required_fetched_commit" ]; then
      required_state=unobservable
      required_reason=policy-ref-mismatch
      required_evidence="The fetched policy generation $required_ref at $required_venue did not resolve to one matching commit."
      return 0
    fi
    required_declaration_observe "$required_commit"
    if [ "$required_declaration_state" = absent ]; then
      # An absent declaration is only a fact about the VENUE when the
      # generation it was read from is the venue's current one. Read from a
      # superseded generation it is a fact about the AGE of that generation,
      # and reporting it as not-required is the ruling's forbidden
      # reinterpretation of a missing marker: a candidate based before the
      # venue adopted the gate would silently publish nothing.
      #
      # So absence is checked twice, against two generations, and only
      # agreement credits not-required. The current generation is the venue's
      # own default branch, fetched from the same governed URL by the same
      # mechanism; nothing here consults a remote of this checkout.
      required_currency_observe
      case "$required_currency" in
        absent) ;;
        present)
          required_state=unobservable
          required_reason=policy-generation-stale
          required_evidence="$required_venue generation $required_ref carries no $REQUIRED_DECLARATION, but the venue's current generation $required_current does, so this generation is superseded rather than undeclared."
          return 0
          ;;
        *)
          required_state=unobservable
          required_reason=policy-generation-currency-unobservable
          required_evidence="$required_venue generation $required_ref carries no $REQUIRED_DECLARATION, and whether that generation is current could not be established: $required_currency_detail"
          return 0
          ;;
      esac
      required_state=not-required
      required_evidence="$required_venue generation $required_ref carries no $REQUIRED_DECLARATION, and neither does its current generation"
      return 0
    fi
    case "$required_declaration_state:$required_declaration_fault" in
      present:) ;;
      unobservable:not-regular)
      required_state=unobservable
      required_reason=policy-declaration-not-regular
      required_evidence="$REQUIRED_DECLARATION at $required_venue generation $required_ref is not a regular-file blob."
      return 0
      ;;
      unobservable:invalid)
      required_state=unobservable
      required_reason=policy-declaration-invalid
      required_evidence="$REQUIRED_DECLARATION at $required_venue generation $required_ref does not contain exactly one '$REQUIRED_DECLARATION_CONTENT' line."
      return 0
      ;;
      unobservable:unreadable | *)
        required_state=unobservable
        required_reason=policy-declaration-unreadable
        required_evidence="$REQUIRED_DECLARATION at $required_venue generation $required_ref could not be read."
        return 0
        ;;
    esac
    required_state=required
    required_evidence="$REQUIRED_DECLARATION at $required_venue generation $required_ref carries the required declaration"
    return 0
  fi
  if [ ! -e "$required_file" ] && [ ! -L "$required_file" ]; then
    required_state=not-required
    required_evidence="it carries no $REQUIRED_DECLARATION"
    return 0
  fi
  if [ -L "$required_file" ]; then
    required_state=unobservable
    required_reason=declaration-not-regular
    required_evidence="$REQUIRED_DECLARATION is a symbolic link rather than a regular declaration file."
    return 0
  fi
  if [ ! -f "$required_file" ]; then
    required_state=unobservable
    required_reason=declaration-not-regular
    required_evidence="$REQUIRED_DECLARATION is not a regular declaration file."
    return 0
  fi
  if [ ! -r "$required_file" ]; then
    required_state=unobservable
    required_reason=declaration-unreadable
    required_evidence="$REQUIRED_DECLARATION could not be read."
    return 0
  fi

  required_content=$(cat "$required_file" 2>/dev/null) || {
    required_state=unobservable
    required_reason=declaration-unreadable
    required_evidence="$REQUIRED_DECLARATION could not be read."
    return 0
  }
  required_size=$(wc -c < "$required_file" 2>/dev/null) || {
    required_state=unobservable
    required_reason=declaration-unreadable
    required_evidence="$REQUIRED_DECLARATION could not be read."
    return 0
  }
  required_size=$(printf '%s' "$required_size" | tr -d '[:space:]')
  if [ "$required_content" != "$REQUIRED_DECLARATION_CONTENT" ] || [ "$required_size" != 22 ]; then
    required_state=unobservable
    required_reason=declaration-invalid
    required_evidence="$REQUIRED_DECLARATION does not contain exactly one '$REQUIRED_DECLARATION_CONTENT' line."
    return 0
  fi

  required_state=required
  required_evidence="$REQUIRED_DECLARATION contains the required declaration"
  return 0
}

cmd_required() {
  policy_venue=
  policy_url=
  policy_ref=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --policy-venue) [ "$#" -ge 2 ] || die "--policy-venue needs a value"; policy_venue=$2; shift 2 ;;
      --policy-url) [ "$#" -ge 2 ] || die "--policy-url needs a value"; policy_url=$2; shift 2 ;;
      --policy-ref) [ "$#" -ge 2 ] || die "--policy-ref needs a value"; policy_ref=$2; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  required_observe 0 "$policy_venue" "$policy_url" "$policy_ref"
  case "$required_state" in
    required)
      emit "fm-attest: this repository reads a head-bound attestation ($required_evidence)"
      exit 0
      ;;
    not-required)
      emit "fm-attest: this repository reads no head-bound attestation ($required_evidence)"
      exit 1
      ;;
    *)
      report 'cannot tell whether an attestation is read here' "$required_reason" \
        "$required_evidence" \
        "That is a declaration this could not read rather than one that is absent, so this says neither that an attestation is required here nor that it is not."
      exit 2
      ;;
  esac
}

cmd_declaration_check() {
  [ "$#" -eq 0 ] || die "unexpected argument: $1"
  declaration_top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  declaration_workflows="$declaration_top/.github/workflows"
  declaration_match=1
  if [ -d "$declaration_workflows" ]; then
    declaration_match=0
    grep -rFqs 'fm-attest.sh' "$declaration_workflows" 2>/dev/null || declaration_match=$?
  fi
  case "$declaration_match" in
    1) return 0 ;;
    0) ;;
    *) die "could not inspect workflows for attestation consumers" ;;
  esac
  required_observe 1 '' '' ''
  [ "$required_state" = required ] || {
    report 'repository invariant failed' "${required_reason:-declaration-missing}" \
      "A workflow mentions fm-attest.sh, but $REQUIRED_DECLARATION is not the exact regular declaration."
    exit 1
  }
  emit "fm-attest: declaration invariant satisfied"
}

# ---------------------------------------------------------------------------
# write - the contributor side
# ---------------------------------------------------------------------------

cmd_write() {
  run_id=
  expect_head=
  remote=origin
  push=1
  publication_expected_tip=
  recheck=1
  only_if_required=0
  policy_venue=
  policy_url=
  policy_ref=
  policy_meta=
  notes_ref=$NOTES_REF_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --only-if-required)
        only_if_required=1
        shift
        ;;
      --policy-venue) [ "$#" -ge 2 ] || die "--policy-venue needs a value"; policy_venue=$2; shift 2 ;;
      --policy-url) [ "$#" -ge 2 ] || die "--policy-url needs a value"; policy_url=$2; shift 2 ;;
      --policy-ref) [ "$#" -ge 2 ] || die "--policy-ref needs a value"; policy_ref=$2; shift 2 ;;
      --policy-meta) [ "$#" -ge 2 ] || die "--policy-meta needs a value"; policy_meta=$2; shift 2 ;;
      --run)
        [ "$#" -ge 2 ] || die "--run needs a value"
        run_id=$2
        shift 2
        ;;
      --expect-head)
        [ "$#" -ge 2 ] || die "--expect-head needs a value"
        expect_head=$2
        shift 2
        ;;
      --remote)
        [ "$#" -ge 2 ] || die "--remote needs a value"
        remote=$2
        shift 2
        ;;
      --notes-ref)
        [ "$#" -ge 2 ] || die "--notes-ref needs a value"
        notes_ref=$2
        shift 2
        ;;
      --no-push)
        push=0
        shift
        ;;
      --no-recheck)
        recheck=0
        shift
        ;;
      *) die "unexpected argument: $1" ;;
    esac
  done

  [ -z "$expect_head" ] || is_full_sha "$expect_head" \
    || die "--expect-head must be a 40-character lowercase sha"
  if [ -n "$policy_meta" ]; then
    [ -z "$policy_venue$policy_url$policy_ref" ] \
      || die "--policy-meta cannot be combined with explicit policy subject arguments"
    task_base_policy_metadata "$policy_meta" || {
      policy_venue=
      policy_url=
      policy_ref=
    }
    [ -z "$TASK_BASE_POLICY_VENUE" ] || policy_venue=$TASK_BASE_POLICY_VENUE
    [ -z "$TASK_BASE_POLICY_URL" ] || policy_url=$TASK_BASE_POLICY_URL
    [ -z "$TASK_BASE_POLICY_REF" ] || policy_ref=$TASK_BASE_POLICY_REF
  fi

  git rev-parse --git-dir >/dev/null 2>&1 || fail not-a-git-repository \
    "This directory is not inside a git repository, so there is no head to attest."

  # Asked before anything is read or recorded, so an unconditional publication
  # step costs a repository that reads no attestation exactly one file listing
  # and changes nothing there. An unreadable declaration stops the command
  # instead: publishing into a repository that never asked for it and skipping
  # publication in one that did are both wrong, and a failed read is not a
  # licence to pick either.
  if [ "$only_if_required" -eq 1 ]; then
    required_observe 0 "$policy_venue" "$policy_url" "$policy_ref"
    case "$required_state" in
      required) ;;
      not-required)
        emit "fm-attest: nothing published - this repository reads no head-bound attestation ($required_evidence)"
        return 0
        ;;
      *)
        fail "$required_reason" \
          "$required_evidence" \
          "Nothing was recorded or published: whether an attestation belongs in this repository could not be established."
        ;;
    esac
  fi

  command -v no-mistakes >/dev/null 2>&1 || fail pipeline-tool-missing \
    "no-mistakes is not on PATH, so its run record cannot be read." \
    "That is a missing tool rather than a missing run: install it and re-run."

  head=$(git rev-parse --verify HEAD 2>/dev/null) || fail head-unresolvable \
    "HEAD does not resolve to a commit, so there is nothing to attest yet." \
    "Commit this work, validate it, then attest the head the pipeline pushes."
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || fail head-detached \
    "HEAD is not on a branch, and a run record is attributed to one." \
    "Check out the branch the pipeline validated and attest from there."
  [ "$branch" != HEAD ] || fail head-detached \
    "HEAD is detached, and a run record is attributed to a branch." \
    "Check out the branch the pipeline validated and attest from there."

  # A tool that failed, a tool whose output this transcription cannot read, and a
  # tool reporting no run at all are three different repairs, and none of them
  # may be described as one of the others.
  #
  # The two streams are therefore kept apart. The tool reports its own errors on
  # stdout but writes unrelated notices there too, such as its version-upgrade
  # banner, on stderr. Only stdout decides whether a run record was reported and
  # only stdout is parsed, so a stderr notice can never stand in for a run
  # record; stderr is quoted alongside it purely as diagnostic detail.
  status_err_file=$(mktemp "${TMPDIR:-/tmp}/.fm-attest-status.XXXXXX" 2>/dev/null) \
    || fail scratch-file-unavailable \
      "Could not create a temporary file to capture the pipeline tool's stderr." \
      "Check TMPDIR and its free space, then re-run."
  status_rc=0
  if [ -n "$run_id" ]; then
    status=$(fm_nm_run_bounded . "$NM_TIMEOUT" axi status --run "$run_id" 2>"$status_err_file") || status_rc=$?
  else
    status=$(fm_nm_run_bounded . "$NM_TIMEOUT" axi status 2>"$status_err_file") || status_rc=$?
  fi
  status_err=$(cat "$status_err_file" 2>/dev/null || true)
  rm -f "$status_err_file" 2>/dev/null || true

  # A tool that refused is judged before a tool that exited non-zero, because
  # the two are not the same set: the tool writes its refusal to stdout and does
  # not always exit non-zero for one, and `repo not initialized` - the state of
  # every checkout the pipeline was never set up in - exits 0 with that line and
  # nothing else. Read only from the exit status, such a refusal reaches the
  # unparsed-record refusal below, which says this transcription needs updating.
  # That sends a reader to repair a transcription that was never broken, over a
  # tool that was never asked about a run, and they hit the identical message
  # again: the exact class of mistake this file's error model exists to prevent.
  # The refusal is read through bin/fm-nm-run-lib.sh, which owns this tool's
  # output shape, and is quoted back in the tool's own words.
  status_error=$(fm_nm_error_line "$status")
  [ -z "$status_error" ] || refuse run-record-unreadable \
    "no-mistakes reported an error instead of a pipeline run: $status_error" \
    "It exited $status_rc." \
    "Its stdout: ${status:-(nothing)}" \
    "Its stderr: ${status_err:-(nothing)}" \
    "That is a tool or setup failure rather than a missing run; fix it and re-run." \
    "A checkout the pipeline was never set up in reports exactly this, so attest from the checkout it validated rather than from one it has never run in."
  [ "$status_rc" -eq 0 ] || refuse run-record-unreadable \
    "no-mistakes exited $status_rc instead of reporting a pipeline run." \
    "Its stdout: ${status:-(nothing)}" \
    "Its stderr: ${status_err:-(nothing)}" \
    "That is a tool or setup failure rather than a missing run; fix it and re-run."
  [ -n "$status" ] || refuse no-run-record \
    "no-mistakes reported no pipeline run for this repository: it wrote nothing to stdout." \
    "Its stderr: ${status_err:-(nothing)}" \
    "Validate this branch with no-mistakes before attesting its head."

  # The run record is read through bin/fm-nm-run-lib.sh, the one owner of this
  # tool's output shape, so a change to that shape moves every reader at once
  # instead of leaving this one refusing what the others still understand. Every
  # token it yields is re-checked below, because this is tool output rather than
  # input the note format may inherit unchecked.
  run_field=$(fm_nm_strip_quotes "$(fm_nm_field "$status" id)")
  branch_field=$(fm_nm_strip_quotes "$(fm_nm_field "$status" branch)")
  head_field=$(fm_nm_strip_quotes "$(fm_nm_field "$status" head)")
  gates=
  while IFS= read -r step; do
    is_gate_name "$step" || continue
    list_has "$step" "$gates" && continue
    gates="$gates $step"
  done <<EOF
$(fm_nm_completed_steps "$status")
EOF

  is_run_id "$run_field" || refuse run-record-unparsed \
    "no-mistakes wrote a run record to stdout, but no run identity could be read from it." \
    "Its stdout: $status" \
    "Its stderr: ${status_err:-(nothing)}" \
    "Its stdout was not empty, so this is not an absent run: either that output is not a run record, or its shape changed and this transcription needs updating."
  [ "$branch_field" = "$branch" ] || refuse run-covers-another-branch \
    "The most recent pipeline run covers branch '$branch_field', not '$branch'." \
    "Attest from the branch that run validated, or name the run with --run <id>."

  # The run record abbreviates the head it pushed, and the pipeline's own fix
  # commits routinely advance that tip past the local HEAD, so a run tip ahead of
  # HEAD on the same history is the normal state rather than a stale record.
  # fm_nm_head_matches_worktree owns that directional rule for every caller that
  # has to decide whether a run belongs to a worktree: equal matches, HEAD an
  # ancestor of the run tip matches, and a run tip behind or beside HEAD does
  # not. The note is then bound to the commit that run validated, which is the
  # head the pipeline pushed and therefore the head the gate reads; binding it to
  # a HEAD the run has already moved past would publish a note for a commit no
  # pull request is open on.
  is_short_sha "$head_field" || refuse run-record-no-head \
    "no-mistakes reported run $run_field, but no usable head commit could be read from that record." \
    "Its stdout: $status" \
    "That is a record this transcription cannot read rather than a branch that diverged from it: nothing here says this branch carries uncovered work, so re-validating it would report the same." \
    "Either that output is not a run record, or its shape changed and this transcription needs updating."
  attest_head=$(git rev-parse --verify --quiet "$head_field^{commit}" 2>/dev/null) \
    || refuse run-head-unavailable \
      "The pipeline run validated $head_field, which is not a commit in this checkout." \
      "That is a commit this repository does not have rather than one it has not validated." \
      "Fetch the branch the pipeline pushed so that commit is present, then attest again."
  fm_nm_head_matches_worktree . "$head_field" || refuse run-covers-another-head \
    "The pipeline run validated $attest_head, but HEAD is $head, which that run does not cover." \
    "HEAD is neither that commit nor an ancestor of it, so this branch carries work the run never saw, or its tip was rewritten." \
    "Validate this branch again and attest the head that run pushes."
  [ -z "$expect_head" ] || [ "$attest_head" = "$expect_head" ] \
    || refuse expected-head-mismatch \
      "The pipeline run validated $attest_head, but the request head is $expect_head." \
      "Nothing was recorded or published for another head." \
      "Validate the request's exact head and attest again."

  missing=
  for gate in $REQUIRED_GATES; do
    list_has "$gate" "$gates" && continue
    missing="$missing $gate"
  done
  [ -z "$missing" ] || refuse run-incomplete \
    "The pipeline run for $attest_head has not completed:$missing." \
    "Required steps: $REQUIRED_GATES."

  tool=$(fm_nm_run_bounded . "$NM_TIMEOUT" --version 2>/dev/null | awk 'NR == 1 { print $3; exit }')
  is_tool_token "$tool" || tool=unknown

  gates_csv=$(printf '%s' "${gates# }" | tr ' ' ',')
  payload=$(printf '%s: %s\nhead: %s\nrun: %s\ngates: %s\ntool: %s\n' \
    "$ATTESTATION_KEY" "$ATTESTATION_VERSION" "$attest_head" "$run_field" "$gates_csv" "no-mistakes/$tool")

  # Refuse to publish anything this repository's own gate would reject, so a
  # malformed note can never reach the forge and be discovered only in CI.
  verify_note_payload "$attest_head" "$payload"

  # Reconcile against the repository this is about to write to, which is the
  # remote's push URL and not its fetch URL. The two are different repositories
  # in the setup CONTRIBUTING.md describes: origin fetches the parent and pushes
  # the contributor's fork, and the fork is the repository the gate reads.
  # Reconciling against the parent would reset the local ref to a history the
  # fork has never seen, so every push would be refused as a non-fast-forward
  # and re-running would refuse identically.
  #
  # The incoming ref is merged rather than forced over the local one, so an
  # attestation recorded locally with --no-push is not silently discarded by the
  # act of publishing a later one.
  #
  # That repository is named in everything this prints, because "published to
  # origin" does not say which repository was reached and the note is evidence
  # only on the one holding the pull request head. The name is made safe once
  # here so that a target which cannot be shown is replaced by the marker inside
  # the sentence naming it, rather than taking that sentence with it; git's own
  # text needs no such handling at these call sites, because emit() makes
  # everything printed safe and the reason a remote refused still reaches the
  # person who has to act on it.
  push_target=$remote
  if [ "$push" -eq 1 ]; then
    push_url=$(git remote get-url --push "$remote" 2>/dev/null) || push_url=$remote
    push_target=$(credential_safe_text "$push_url")
    incoming_ref="$notes_ref-incoming"
    # Absence and unreadability are two different answers and only one of them is
    # a fact about the attestations there. A push target with no
    # refs/notes/no-mistakes has nothing to reconcile against; a push target that
    # cannot be read at all has told us nothing, so it stops the command before
    # anything is recorded. git ls-remote --exit-code reports the first as exit 2
    # and everything else as a failure, which is the same line the gate draws
    # when it fetches this ref.
    ls_rc=0
    ls_err=$(git ls-remote --exit-code "$push_url" "$notes_ref" 2>&1 >/dev/null) || ls_rc=$?
    case "$ls_rc" in
      0)
        fetch_rc=0
        fetch_err=$(git fetch --quiet --no-tags --force "$push_url" "$notes_ref:$incoming_ref" 2>&1 >/dev/null) \
          || fetch_rc=$?
        [ "$fetch_rc" -eq 0 ] || fail push-target-unfetchable \
          "$push_target, the push target of $remote, advertises $notes_ref but would not serve it." \
          "git said: $fetch_err" \
          "Resolve that and re-run; nothing was recorded."
        merge_rc=0
        merge_err=$(git notes --ref="$notes_ref" merge -s ours "$incoming_ref" 2>&1 >/dev/null) \
          || merge_rc=$?
        [ "$merge_rc" -eq 0 ] || fail attestation-not-reconciled \
          "Could not reconcile the local $notes_ref with the one on $push_target, the push target of $remote." \
          "git said: $merge_err" \
          "Resolve that and re-run; nothing was recorded."
        # The tip the publication is being PLANNED AGAINST, taken from what was
        # just fetched rather than from a second network read. The guard below
        # re-observes the remote for itself; this is the caller's own statement
        # of which tip it compiled its plan on, and the two disagreeing is
        # precisely the remote-moved case that must not publish.
        publication_expected_tip=$(git rev-parse --verify --quiet "$incoming_ref" 2>/dev/null) \
          || publication_expected_tip=
        git update-ref -d "$incoming_ref" 2>/dev/null || true
        ;;
      2) publication_expected_tip='-' ;;
      *)
        fail push-target-unreadable \
          "Could not read $notes_ref from $push_target, the push target of $remote (git exit $ls_rc)." \
          "git said: $ls_err" \
          "That is a repository this could not read rather than one with no attestations, so nothing was recorded." \
          "Check access to it, or name another with --remote <name>, then re-run."
        ;;
    esac
  fi
  notes_err=$(git notes --ref="$notes_ref" add -f -m "$payload" "$attest_head" 2>&1 >/dev/null) \
    || fail attestation-not-recorded \
      "Could not record the attestation note on $attest_head." \
      "git said: $notes_err"
  if [ "$attest_head" != "$head" ]; then
    emit "fm-attest: the run tip is ahead of HEAD $head, as the pipeline advances it with its own fix commits"
  fi
  emit "fm-attest: recorded $notes_ref for $attest_head"

  [ "$push" -eq 1 ] || return 0

  # THE ONE REMOTE-CHANGING PUBLICATION THIS REPOSITORY PERFORMS, and therefore
  # the one that has to pass the publication guard. Everything the guard needs is
  # already established here: the ref, the local tip about to move it, the tip
  # that was observed above, and the venue the push target names.
  #
  # bin/fm-publication-seam-lib.sh owns the whole decision and runs the push
  # inside the authority when one governs it, so this site holds no copy of when
  # a publication is permitted - only the act, and the report of what happened.
  # Sourced here rather than at the top because this library resets its own
  # globals when loaded, and the two functions below already load it themselves.
  # shellcheck source=bin/fm-task-base-lib.sh
  . "$SCRIPT_DIR/fm-task-base-lib.sh"
  publication_repo=$(git rev-parse --show-toplevel 2>/dev/null) || publication_repo=
  publication_head=$(git rev-parse --verify --quiet "$notes_ref" 2>/dev/null) || publication_head=
  publication_tree=$(git rev-parse --verify --quiet "$notes_ref^{tree}" 2>/dev/null) || publication_tree=
  # A push target that is not a forge - a local mirror, a fixture - has no venue
  # identity, and that is a fact about the target rather than a defect. It is
  # passed through as the unidentified marker so the guard decides what it means
  # in THIS home, instead of this site deciding it twice.
  publication_venue=$(task_base_venue_identity_alias "$push_url" 2>/dev/null) \
    || publication_venue=$(task_base_venue_identity "$push_url" 2>/dev/null) \
    || publication_venue=
  [ -n "$publication_venue" ] || publication_venue='-'
  [ -n "$publication_repo" ] && [ -n "$publication_head" ] && [ -n "$publication_tree" ] \
    && [ -n "$publication_expected_tip" ] \
    || fail attestation-not-published \
      "Could not establish what publishing $notes_ref to $push_target would change." \
      "The guard that permits a publication needs the exact ref, its local tip, and the tip already on that target, and at least one of those could not be read here." \
      "Nothing was published."

  publication_rc=0
  fm_pub_seam_publish "$SCRIPT_DIR/fm-publication-guard.sh" \
    "$publication_repo" "$remote" "$publication_venue" "$notes_ref" \
    "$publication_head" "$publication_expected_tip" '-' attestation-evidence \
    git -C "$publication_repo" push "$remote" "$publication_head:$notes_ref" \
    || publication_rc=$?
  case "$publication_rc" in
    0) ;;
    3)
      fail attestation-not-published \
        "Publishing $notes_ref to $push_target, the push target of $remote, was refused before that repository was touched." \
        "$FM_PUB_SEAM_TOKEN: $FM_PUB_SEAM_REASON" \
        "$notes_ref on that target is unchanged. Resolve what the refusal names, then re-run."
      ;;
    *)
      # The remote may have been reached and may even have refused in its own
      # words, so those words are relayed here rather than replaced by the
      # guard's. A URL in that text is shown only in a form that has no place for
      # a credential, and any line holding one that is not is withheld whole
      # rather than shown in part.
      fail attestation-not-published \
        "Could not publish $notes_ref to $push_target, the push target of $remote." \
        "$FM_PUB_SEAM_TOKEN: $FM_PUB_SEAM_REASON" \
        "${FM_PUB_SEAM_OUTPUT:-No output was captured from the attempt.}" \
        "That the attempt reported a failure does not establish that it had no effect; $notes_ref on that target may or may not have moved, so re-run to reconcile rather than assuming either."
      ;;
  esac
  case "$FM_PUB_SEAM_VERDICT" in
    no-effect)
      emit "fm-attest: $push_target (the push target of $remote) already has $notes_ref at this tip, so nothing was published"
      ;;
    not-applicable)
      emit "fm-attest: published $notes_ref to $push_target (the push target of $remote), ungoverned - $FM_PUB_SEAM_REASON"
      ;;
    *)
      emit "fm-attest: published $notes_ref to $push_target (the push target of $remote) under a spent publication authority"
      ;;
  esac

  # Publishing repairs the evidence but not the verdict, and the verdict is what
  # a contributor is actually waiting on. This step is what closes that gap, so
  # it is the default rather than something to remember: leaving it opt-in would
  # keep the manual re-trigger alive under a different name.
  #
  # It runs only when something was published. --no-push records the note
  # locally and there is then nothing on the forge for a check to re-read, so
  # asking GitHub to look again would be asking it to confirm the same refusal.
  [ "$recheck" -eq 1 ] || return 0
  RECHECK_FROM_WRITE=1
  cmd_recheck --head "$attest_head" --remote "$remote" --notes-ref "$notes_ref"
}

# ---------------------------------------------------------------------------
# recheck - re-evaluate one published head
# ---------------------------------------------------------------------------

# Every read of the forge goes through this, so a read that FAILED can never be
# mistaken for a read that returned nothing. "GitHub has no runs for this head"
# and "this program could not ask" are different facts, and collapsing them is
# the same defect as reading an empty check set as green. It sets RECHECK_OUT
# and RECHECK_ERR together and returns gh's own status; no caller reads one
# without having judged the other.
recheck_gh() {
  recheck_gh_rc=0
  RECHECK_OUT=$(gh "$@" 2>"$RECHECK_ERR_FILE") || recheck_gh_rc=$?  # fm-retrieval-audit: chokepoint - the recheck transport wrapper carries no collection semantics; each recheck_gh api caller classifies its own read
  RECHECK_ERR=$(cat "$RECHECK_ERR_FILE" 2>/dev/null || true)
  return "$recheck_gh_rc"
}

# Counts ledger records carrying every one of the given `key=value` tokens.
# Fields are matched whole and by name rather than by position, so a record
# gaining a field later cannot silently change what an older count means.
recheck_ledger_count() { # <ledger> "<key>=<value> ..."
  [ -e "$1" ] || {
    printf '0\n'
    return 0
  }
  awk -v record="$RECHECK_RECORD" -v want="$2" '
    BEGIN { n_want = split(want, w, " ") }
    $1 != record { next }
    {
      hits = 0
      for (i = 1; i <= n_want; i++) {
        for (j = 2; j <= NF; j++) {
          if ($j == w[i]) { hits++; break }
        }
      }
      if (hits == n_want) n++
    }
    END { print n + 0 }
  ' "$1"
}

# One line per decision, in tokens this script validated, so the record needs no
# quoting and can be matched field by field afterwards. Returns the append's own
# status; the caller that writes before acting is the one that must read it.
recheck_ledger_append() { # <action> <reason> [<run>] [<attempt>]
  recheck_stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || recheck_stamp=
  case "$recheck_stamp" in
    '' | *[!0-9A-Za-z:-]*) recheck_stamp=unknown ;;
  esac
  printf '%s ts=%s repo=%s pr=%s head=%s note=%s run=%s attempt=%s action=%s reason=%s\n' \
    "$RECHECK_RECORD" "$recheck_stamp" "${recheck_repo_key:-none}" "${recheck_pr:-none}" \
    "$recheck_head" "${recheck_note_oid:-none}" "${3:-none}" "${4:-none}" "$1" "$2" \
    >> "$recheck_ledger" 2>/dev/null
}

# The ledger lives beside the repository rather than in it, in the common git
# directory so that every worktree of one clone shares one record, which is the
# same scope the attestation ref itself has. It is never committed and never
# consulted by the check: it is an audit record of what this program did, not a
# second place a verdict could come from.
recheck_ledger_prepare() {
  recheck_ledger_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || recheck_ledger_dir=
  if [ -z "$recheck_ledger_dir" ]; then
    recheck_ledger_dir=$(git rev-parse --git-common-dir 2>/dev/null) || recheck_ledger_dir=
    case "$recheck_ledger_dir" in
      '')
        recheck_fail ledger-unlocatable \
          "git would not name this repository's common directory, so the re-evaluation record has nowhere to live." \
          "Nothing was re-triggered: a re-evaluation nobody can audit is worse than one that did not happen."
        ;;
      /*) ;;
      *) recheck_ledger_dir="$(pwd)/$recheck_ledger_dir" ;;
    esac
  fi
  recheck_ledger="$recheck_ledger_dir/fm-attest-recheck.log"
  recheck_lock_dir="$recheck_ledger_dir/fm-attest-recheck.lock"
  [ ! -e "$recheck_ledger" ] || [ -r "$recheck_ledger" ] || recheck_fail ledger-unreadable \
    "$recheck_ledger exists but cannot be read, so this cannot tell a first re-trigger from a repeat." \
    "Repair or remove it and re-run; nothing was re-triggered."
}

recheck_ledger_unlock() {
  [ "${recheck_lock_held:-0}" -eq 1 ] || return 0
  rm -f "$recheck_lock_dir/holder" >/dev/null 2>&1 || true
  rmdir "$recheck_lock_dir" >/dev/null 2>&1 || true
  recheck_lock_held=0
}

recheck_ledger_lock() {
  recheck_lock_waited=0
  while ! mkdir "$recheck_lock_dir" 2>/dev/null; do
    recheck_lock_host=$(hostname 2>/dev/null) || recheck_lock_host=
    recheck_holder_host=
    recheck_holder_pid=
    if [ -n "$recheck_lock_host" ] && [ -r "$recheck_lock_dir/holder" ]; then
      IFS=' ' read -r recheck_holder_host recheck_holder_pid < "$recheck_lock_dir/holder" || {
        recheck_holder_host=
        recheck_holder_pid=
      }
    fi
    case "$recheck_holder_pid" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$recheck_holder_host" = "$recheck_lock_host" ] && command -v ps >/dev/null 2>&1; then
          ps -p "$recheck_holder_pid" >/dev/null 2>&1
          recheck_ps_rc=$?
          if [ "$recheck_ps_rc" -eq 1 ]; then
            recheck_stale_lock="$recheck_lock_dir.stale.$$.$recheck_lock_waited"
            if mv "$recheck_lock_dir" "$recheck_stale_lock" 2>/dev/null; then
              rm -rf "$recheck_stale_lock"
              emit "Reclaimed $recheck_lock_dir: process $recheck_holder_pid on $recheck_holder_host is gone."
              continue
            fi
          fi
        fi
        ;;
    esac
    [ "$recheck_lock_waited" -lt "$RECHECK_LOCK_WAIT" ] || recheck_fail ledger-lock-unavailable \
      "Could not take the re-evaluation ledger lock at $recheck_lock_dir within ${RECHECK_LOCK_WAIT}s." \
      "The request bound could not be observed atomically, so nothing was re-triggered."
    sleep 1
    recheck_lock_waited=$((recheck_lock_waited + 1))
  done
  recheck_lock_held=1
  recheck_lock_host=$(hostname 2>/dev/null) || recheck_lock_host=
  case "$recheck_lock_host" in
    '' | *[!0-9A-Za-z._-]*)
      recheck_ledger_unlock
      recheck_fail ledger-lock-unavailable \
        "Could not record this process as the holder of $recheck_lock_dir." \
        "The lock could not be made safely reclaimable, so nothing was re-triggered."
      ;;
  esac
  printf '%s %s\n' "$recheck_lock_host" "$$" > "$recheck_lock_dir/holder" 2>/dev/null || {
    recheck_ledger_unlock
    recheck_fail ledger-lock-unavailable \
      "Could not record this process as the holder of $recheck_lock_dir." \
      "The lock could not be made safely reclaimable, so nothing was re-triggered."
  }
}

recheck_cleanup() {
  recheck_ledger_unlock
  [ -z "${RECHECK_ERR_FILE:-}" ] || rm -f "$RECHECK_ERR_FILE" >/dev/null 2>&1
  [ -z "${recheck_scratch_ref:-}" ] || git update-ref -d "$recheck_scratch_ref" >/dev/null 2>&1
}

recheck_resolve_push_repository() {
  [ -f "$SCRIPT_DIR/fm-task-base-lib.sh" ] || recheck_fail repository-unresolved \
    "bin/fm-task-base-lib.sh is not beside this script, so the push target cannot be bound to a GitHub repository."
  # shellcheck source=bin/fm-task-base-lib.sh
  . "$SCRIPT_DIR/fm-task-base-lib.sh"
  recheck_push_venue=$(task_base_venue_identity_alias "$push_identity_url" 2>/dev/null) \
    || recheck_push_venue=$(task_base_venue_identity "$push_identity_url" 2>/dev/null) \
    || recheck_push_venue=
  case "$recheck_push_venue" in
    github.com/*) recheck_push_repo=${recheck_push_venue#github.com/} ;;
    *) recheck_push_repo= ;;
  esac
  is_repo_slug "$recheck_push_repo" || recheck_fail repository-unresolved \
    "$push_target, the push target of $remote, could not be resolved to an owner/name GitHub repository." \
    "Nothing was re-triggered because the published evidence repository could not be bound to the pull request head repository."
}

# The pull request this head is open on, resolved from the repositories this
# clone already addresses rather than from a search. Sets recheck_repo and
# recheck_pr, or leaves recheck_repo empty when this head carries no open pull
# request at all - which is an ordinary outcome, not a fault: a landing branch
# validated in its own right is attested and never proposed anywhere.
recheck_resolve_pull_request() {
  [ -f "$SCRIPT_DIR/fm-task-base-lib.sh" ] || recheck_fail repository-unresolved \
    "bin/fm-task-base-lib.sh is not beside this script, so a remote URL cannot be read as a forge repository." \
    "Name the pull request instead: bin/fm-attest.sh recheck --head $recheck_head --repo <owner/name> --pr <number>"
  # Sourced here rather than at the top of this file on purpose. The workflow
  # runs `verify` from a pull request's own head with fetch-depth 1, and every
  # library that path loads is another thing that can be missing at that head
  # and turn a verdict into a crash. Nothing outside recheck needs this one.
  # shellcheck source=bin/fm-task-base-lib.sh
  . "$SCRIPT_DIR/fm-task-base-lib.sh"

  recheck_candidates=
  for recheck_remote_name in "$remote" upstream origin; do
    for recheck_url_kind in --push --all; do
      case "$recheck_url_kind" in
        --push)
          recheck_remote_url=$(git config --get "remote.$recheck_remote_name.pushurl" 2>/dev/null) \
            || recheck_remote_url=$(git config --get "remote.$recheck_remote_name.url" 2>/dev/null) \
            || continue
          ;;
        *) recheck_remote_url=$(git config --get "remote.$recheck_remote_name.url" 2>/dev/null) || continue ;;
      esac
      recheck_venue=$(task_base_venue_identity_alias "$recheck_remote_url" 2>/dev/null) \
        || recheck_venue=$(task_base_venue_identity "$recheck_remote_url" 2>/dev/null) \
        || continue
      case "$recheck_venue" in
        github.com/*) recheck_slug=${recheck_venue#github.com/} ;;
        *) continue ;;
      esac
      is_repo_slug "$recheck_slug" || continue
      list_has "$recheck_slug" "$recheck_candidates" && continue
      recheck_candidates="$recheck_candidates $recheck_slug"
    done
  done
  [ -n "$recheck_candidates" ] || recheck_fail repository-unresolved \
    "None of this checkout's remotes names a github.com repository, so there is nowhere to look for the pull request." \
    "Name it: bin/fm-attest.sh recheck --head $recheck_head --repo <owner/name> --pr <number>"

  # An open request whose head is this exact commit, wherever it was raised.
  # GitHub answers this per repository, so each candidate is asked and the
  # answers are reconciled by the request's own base repository and number,
  # which is what makes asking a fork and its parent the same question twice
  # rather than two different ones.
  #
  # Asked over GraphQL rather than through the REST "pull requests associated
  # with a commit" route, because that route answers 422 for a commit the
  # repository does not have and this could not then tell it apart from a
  # repository it failed to reach. GraphQL answers the same question with a null
  # object and a success status, so "this repository does not have that commit"
  # stays a fact about the repository rather than becoming a failed read, and a
  # repository that genuinely could not be resolved still arrives as an error.
  # An unrelated remote is an ordinary thing for a checkout to carry, so that
  # distinction decides whether one of them can stop the whole command.
  # A partial association listing could otherwise become a silent no-op: a
  # mechanism whose job is to act automatically must never be able to do
  # nothing quietly when GitHub says it withheld part of the answer.
  recheck_found=
  for recheck_slug in $recheck_candidates; do
    # shellcheck disable=SC2016  # $owner, $name and $oid are GraphQL variables.
    # fm-retrieval-audit: complete-source - refuses on pageInfo.hasNextPage as pull-request-list-truncated rather than resolving from a partial association listing
    recheck_gh api graphql \
      -f query='query($owner: String!, $name: String!, $oid: GitObjectID!) {
        repository(owner: $owner, name: $name) {
          object(oid: $oid) {
            ... on Commit {
              associatedPullRequests(first: 20) {
                pageInfo { hasNextPage }
                nodes {
                  number state headRefOid
                  baseRepository { nameWithOwner }
                  headRepository { nameWithOwner }
                }
              }
            }
          }
        }
      }' \
      -f owner="${recheck_slug%%/*}" -f name="${recheck_slug##*/}" -f oid="$recheck_head" \
      --jq '"page-info \(.data.repository.object.associatedPullRequests.pageInfo.hasNextPage // false)",
            ((.data.repository.object.associatedPullRequests.nodes // [])[]
             | select(.state == "OPEN")
             | select(.headRefOid == "'"$recheck_head"'")
             | "\(.baseRepository.nameWithOwner) \(.number) \(.headRepository.nameWithOwner // "absent")")' \
      || recheck_fail forge-unreadable \
        "Could not ask $recheck_slug which pull requests are open on $recheck_head (gh exited $recheck_gh_rc)." \
        "gh said: ${RECHECK_ERR:-(nothing)}" \
        "That is a forge this could not read rather than a head with no pull request, so nothing here says whether one is open on it." \
        "Skip resolution and name the request instead: bin/fm-attest.sh recheck --head $recheck_head --repo <owner/name> --pr <number>"
    recheck_page_info=${RECHECK_OUT%%
*}
    [ "$recheck_page_info" = "page-info true" ] && recheck_fail pull-request-list-truncated \
      "GitHub returned only part of the pull request associations for $recheck_head in $recheck_slug." \
      "Nothing was re-triggered because a partial pull request listing cannot resolve the request." \
      "Skip resolution and name it: bin/fm-attest.sh recheck --head $recheck_head --repo <owner/name> --pr <number>"
    while IFS=' ' read -r recheck_found_repo recheck_found_pr recheck_found_head_repo; do
      [ "$recheck_found_repo" != page-info ] || continue
      [ -n "$recheck_found_pr" ] || continue
      is_repo_slug "$recheck_found_repo" || continue
      is_positive_number "$recheck_found_pr" || continue
      [ "$recheck_found_head_repo" != absent ] || recheck_fail pull-request-head-repository-absent \
        "Pull request $recheck_found_pr on $recheck_found_repo has no head repository." \
        "A deleted fork is not a repository the published attestation can be bound to, so nothing was re-triggered."
      is_repo_slug "$recheck_found_head_repo" || recheck_fail pull-request-head-repository-unreadable \
        "GitHub did not return a usable head repository for pull request $recheck_found_pr on $recheck_found_repo." \
        "Nothing was re-triggered because absence and an unreadable repository are not evidence of a match."
      list_has "$recheck_found_repo#$recheck_found_pr#$recheck_found_head_repo" "$recheck_found" && continue
      recheck_found="$recheck_found $recheck_found_repo#$recheck_found_pr#$recheck_found_head_repo"
    done <<EOF
$RECHECK_OUT
EOF
  done

  recheck_repo=
  recheck_pr=
  # Split on purpose: every element was built from two tokens this script
  # validated, so neither can carry a space or a glob character.
  # shellcheck disable=SC2086
  set -- $recheck_found
  case "$#" in
    0) return 0 ;;
    1) ;;
    *)
      recheck_refuse pull-request-ambiguous \
        "$recheck_head is the head of more than one open pull request:$recheck_found." \
        "Re-evaluating one of them would leave the others as they are, so this will not choose for you." \
        "Name the one to re-evaluate: bin/fm-attest.sh recheck --head $recheck_head --repo <owner/name> --pr <number>"
      ;;
  esac
  recheck_repo=${1%%#*}
  recheck_pr=${1#*#}
  recheck_pr=${recheck_pr%%#*}
  recheck_pr_head_repo=${1##*#}
}

# The runs this head's applicable check has produced. A run whose head_sha is
# not this head is not evidence about this head; a run GitHub reported alongside
# pull request numbers that do not include ours belongs to another request.
# GitHub leaves that list empty for a cross-repository request, so an empty list
# is accepted on the head binding alone rather than refused.
#
# Sets recheck_run to the newest applicable run and recheck_attempt,
# recheck_status and recheck_conclusion to its state, or leaves recheck_run
# empty when there is none. Run identities increase monotonically, which is the
# same ordering bin/fm-pr-merge.sh reduces check attempts by, so the largest is
# the one that started last.
recheck_select_run() {
  # fm-retrieval-audit: complete-source - reconciles total_count against the returned length and refuses forge-read-truncated, so an unread run is never an absent one
  recheck_gh api \
    "repos/$recheck_repo/actions/workflows/$RECHECK_WORKFLOW_FILE/runs?head_sha=$recheck_head&event=pull_request&per_page=100" \
    --jq '"total \(.total_count) \(.workflow_runs | length)",
          (.workflow_runs[]
           | select(.head_sha == "'"$recheck_head"'")
           | select((.pull_requests | length) == 0
                    or ([.pull_requests[].number] | index('"$recheck_pr"') != null))
           | "run \(.id) \(.run_attempt) \(.status) \(.conclusion // "none")")' \
    || recheck_fail forge-unreadable \
      "Could not read the $RECHECK_WORKFLOW_FILE runs for $recheck_head on $recheck_repo (gh exited $recheck_gh_rc)." \
      "gh said: ${RECHECK_ERR:-(nothing)}" \
      "That is a forge this could not read rather than a head with no runs, so nothing here says whether its check has passed, failed, or ever run."

  recheck_run=
  recheck_attempt=none
  recheck_status=
  recheck_conclusion=
  recheck_total=
  recheck_returned=
  while IFS=' ' read -r recheck_kind recheck_f1 recheck_f2 recheck_f3 recheck_f4; do
    case "$recheck_kind" in
      total)
        recheck_total=$recheck_f1
        recheck_returned=$recheck_f2
        ;;
      run)
        is_positive_number "$recheck_f1" || continue
        [ -z "$recheck_run" ] || [ "$recheck_f1" -gt "$recheck_run" ] || continue
        recheck_run=$recheck_f1
        recheck_attempt=$recheck_f2
        recheck_status=$recheck_f3
        recheck_conclusion=$recheck_f4
        ;;
    esac
  done <<EOF
$RECHECK_OUT
EOF

  case "$recheck_total" in
    '' | *[!0-9]*)
      recheck_fail forge-unreadable \
        "GitHub's run listing for $recheck_head did not carry a usable count." \
        "gh printed: ${RECHECK_OUT:-(nothing)}" \
        "Either that output is not a run listing, or its shape changed and this transcription needs updating."
      ;;
  esac
  case "$recheck_returned" in
    '' | *[!0-9]*)
      recheck_fail forge-unreadable \
        "GitHub's run listing for $recheck_head did not say how many runs it returned." \
        "gh printed: ${RECHECK_OUT:-(nothing)}" \
        "Either that output is not a run listing, or its shape changed and this transcription needs updating."
      ;;
  esac
  [ "$recheck_total" -le "$recheck_returned" ] || recheck_fail forge-read-truncated \
    "GitHub reports $recheck_total $RECHECK_WORKFLOW_FILE runs for $recheck_head but returned $recheck_returned of them." \
    "The run that started last cannot be chosen out of a listing this program did not see the whole of."
  case "$recheck_attempt" in
    '' | *[!0-9]*) recheck_attempt=none ;;
  esac
}

cmd_recheck() {
  recheck_head=
  recheck_repo=
  recheck_pr=
  remote=origin
  notes_ref=$NOTES_REF_DEFAULT
  recheck_dry_run=0
  recheck_repo_key=
  recheck_lock_held=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head)
        [ "$#" -ge 2 ] || die "--head needs a value"
        recheck_head=$2
        shift 2
        ;;
      --repo)
        [ "$#" -ge 2 ] || die "--repo needs a value"
        recheck_repo=$2
        shift 2
        ;;
      --pr)
        [ "$#" -ge 2 ] || die "--pr needs a value"
        recheck_pr=$2
        shift 2
        ;;
      --remote)
        [ "$#" -ge 2 ] || die "--remote needs a value"
        remote=$2
        shift 2
        ;;
      --notes-ref)
        [ "$#" -ge 2 ] || die "--notes-ref needs a value"
        notes_ref=$2
        shift 2
        ;;
      --dry-run)
        recheck_dry_run=1
        shift
        ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$recheck_head" ] || die "recheck needs --head <sha>"
  is_full_sha "$recheck_head" || die "--head must be a 40-character lowercase sha"
  RECHECK_HEAD=$recheck_head
  # The two travel together or not at all. A pull request number means nothing
  # without the repository holding it, and resolving one while the other was
  # given by hand would answer a different question than the one asked.
  if [ -n "$recheck_repo" ] || [ -n "$recheck_pr" ]; then
    { [ -n "$recheck_repo" ] && [ -n "$recheck_pr" ]; } \
      || die "--repo and --pr are given together or not at all"
    is_repo_slug "$recheck_repo" || die "--repo must be owner/name"
    is_positive_number "$recheck_pr" || die "--pr must be a pull request number"
  fi

  git rev-parse --git-dir >/dev/null 2>&1 || fail not-a-git-repository \
    "This directory is not inside a git repository."
  command -v gh >/dev/null 2>&1 || recheck_fail forge-tool-missing \
    "gh is not on PATH, so GitHub cannot be asked to re-evaluate this head." \
    "That is a missing tool rather than a verdict: nothing here says whether this head's check would now pass." \
    "Install gh and authenticate it, then re-run; or re-run the 'Require no-mistakes' run for this head from the repository's Actions tab."

  recheck_scratch_ref="$notes_ref-published-$$"
  RECHECK_ERR_FILE=$(mktemp "${TMPDIR:-/tmp}/.fm-attest-recheck.XXXXXX" 2>/dev/null) \
    || fail scratch-file-unavailable \
      "Could not create a temporary file to capture gh's stderr." \
      "Check TMPDIR and its free space, then re-run."
  trap recheck_cleanup EXIT

  # ---- the evidence, as the check itself will read it --------------------
  #
  # Not the local ref. The check reads refs/notes/no-mistakes from the
  # repository the branch was pushed to, so that copy is the one whose validity
  # decides whether re-evaluating this head could converge. A note recorded
  # locally but never published, or one a remote rewrote, would otherwise buy a
  # re-trigger that must reproduce the same refusal.
  push_url=$(git remote get-url --push "$remote" 2>/dev/null) || push_url=$remote
  push_identity_url=$(git config --get "remote.$remote.pushurl" 2>/dev/null) \
    || push_identity_url=$(git config --get "remote.$remote.url" 2>/dev/null) \
    || push_identity_url=$push_url
  push_target=$(credential_safe_text "$push_url")
  recheck_resolve_push_repository
  ls_rc=0
  ls_err=$(git ls-remote --exit-code "$push_url" "$notes_ref" 2>&1 >/dev/null) || ls_rc=$?
  case "$ls_rc" in
    0) ;;
    2)
      recheck_refuse attestation-not-published \
        "$push_target, the push target of $remote, carries no $notes_ref at all." \
        "The check reads the attestation from the repository holding the pull request head and nowhere else, so a re-evaluation has nothing there to find." \
        "Publish it with 'bin/fm-attest.sh write', naming that repository with --remote <name> if it is not $remote."
      ;;
    *)
      recheck_fail push-target-unreadable \
        "Could not read $notes_ref from $push_target, the push target of $remote (git exit $ls_rc)." \
        "git said: $ls_err" \
        "That is a repository this could not read rather than one with no attestations, so nothing here says whether this head is attested."
      ;;
  esac
  fetch_rc=0
  fetch_err=$(git fetch --quiet --no-tags --force "$push_url" "$notes_ref:$recheck_scratch_ref" 2>&1 >/dev/null) \
    || fetch_rc=$?
  [ "$fetch_rc" -eq 0 ] || recheck_fail push-target-unfetchable \
    "$push_target, the push target of $remote, advertises $notes_ref but would not serve it." \
    "git said: $fetch_err" \
    "Resolve that and re-run; nothing was re-triggered."

  note_rc=0
  recheck_note=$(git notes --ref="$recheck_scratch_ref" show "$recheck_head" 2>/dev/null) || note_rc=$?
  [ "$note_rc" -ne 1 ] || recheck_refuse attestation-not-published-for-head \
    "$push_target carries $notes_ref, but it holds no attestation for $recheck_head." \
    "An attestation for any other commit says nothing about this one, so re-evaluating this head would only reproduce the same refusal." \
    "Publish one for this exact head with 'bin/fm-attest.sh write'."
  [ "$note_rc" -eq 0 ] || recheck_fail attestation-ref-unreadable \
    "$notes_ref resolves on $push_target but cannot be read as notes here (git notes exited $note_rc)." \
    "Repair or delete that ref on the repository the check reads, then publish afresh."

  # The same code path the gate runs, so an attestation this refuses could never
  # have passed the check and re-running it would spend a job to be told so. It
  # exits through refuse() rather than recheck_refuse(), because invalid evidence
  # is a verdict on the evidence and must not be dressed up as a re-evaluation
  # that merely did not happen. That is the whole difference between "this head
  # is now attested and a stale failed run is all that stands in the way" and
  # "what is published for this head is not an attestation".
  verify_note_payload "$recheck_head" "$recheck_note"
  recheck_note_oid=$(git notes --ref="$recheck_scratch_ref" list "$recheck_head" 2>/dev/null | awk 'NR == 1 { print $1 }')
  case "$recheck_note_oid" in
    '' | *[!0-9a-f]*) recheck_note_oid=unknown ;;
  esac

  # ---- the pull request this head is open on -----------------------------
  if [ -n "$recheck_repo" ]; then
    # fm-retrieval-audit: not-a-collection - one pull request object's state, head sha, and head repository; there is no extent to enumerate
    recheck_gh api "repos/$recheck_repo/pulls/$recheck_pr" --jq '"\(.state) \(.head.sha) \(.head.repo.full_name // "absent")"' \
      || recheck_fail forge-unreadable \
        "Could not read pull request $recheck_pr on $recheck_repo (gh exited $recheck_gh_rc)." \
        "gh said: ${RECHECK_ERR:-(nothing)}" \
        "That is a forge this could not read rather than a request that has moved or closed."
    read -r recheck_pr_state recheck_pr_head recheck_pr_head_repo <<EOF
$RECHECK_OUT
EOF
    [ "$recheck_pr_state" = open ] || recheck_refuse pull-request-not-open \
      "Pull request $recheck_pr on $recheck_repo is '$recheck_pr_state' rather than open." \
      "A request that is not open has no check for this to re-evaluate."
    [ "$recheck_pr_head" = "$recheck_head" ] || recheck_refuse pull-request-head-moved \
      "Pull request $recheck_pr on $recheck_repo is open on $recheck_pr_head, not on $recheck_head." \
      "The attestation names one commit, so evidence for a head the request has moved off does not cover the head under review, and re-evaluating it would judge a commit nobody is proposing." \
      "Attest the current head and re-run."
  else
    recheck_resolve_pull_request
    if [ -z "$recheck_repo" ]; then
      recheck_ledger_prepare
      recheck_ledger_append skipped no-open-pull-request
      emit "fm-attest: no open pull request is on $recheck_head, so there is no check to re-evaluate"
      exit 0
    fi
  fi

  [ "$recheck_pr_head_repo" != absent ] || recheck_fail pull-request-head-repository-absent \
    "Pull request $recheck_pr on $recheck_repo has no head repository." \
    "A deleted fork is not a repository the published attestation can be bound to, so nothing was re-triggered."
  is_repo_slug "$recheck_pr_head_repo" || recheck_fail pull-request-head-repository-unreadable \
    "GitHub did not return a usable head repository for pull request $recheck_pr on $recheck_repo." \
    "Nothing was re-triggered because absence and an unreadable repository are not evidence of a match."
  # Compared as identities rather than as text, because the two sides arrive
  # spelled differently by construction and this binding holds on BOTH paths:
  # the explicit lookup reads .head.repo.full_name and the resolved one reads
  # headRepository.nameWithOwner, and GitHub returns its canonical casing for
  # each while the push side is lowercased from a remote URL. Both spellings are
  # kept in the message.
  [ "$(repo_identity "$recheck_pr_head_repo")" = "$(repo_identity "$recheck_push_repo")" ] \
    || recheck_refuse pull-request-head-repository-mismatch \
      "Pull request $recheck_pr on $recheck_repo reads its head from $recheck_pr_head_repo, but the attestation was read from $recheck_push_repo." \
      "No head is reported green on unseen evidence, but re-running now would report publication where the check does not look, so nothing was re-triggered."

  # The ledger is keyed on the repository, not on how this invocation happened
  # to spell it. Keying on the spelling made the per-head request bound resettable
  # by retyping the same name in another case, which is the bound this program
  # exists to hold rather than to appear to hold.
  recheck_repo_key=$(repo_identity "$recheck_repo")

  recheck_ledger_prepare

  # ---- the run that already judged this head -----------------------------
  recheck_waited=0
  while :; do
    recheck_select_run
    [ -n "$recheck_run" ] || recheck_refuse no-applicable-run \
      "GitHub has no $RECHECK_WORKFLOW_FILE run for $recheck_head on pull request $recheck_pr of $recheck_repo." \
      "There is no verdict on this head to re-derive, and a check that never ran is not a check that passed." \
      "That check runs on a pull request event, so a head it never ran on needs one: push the branch again, or run the workflow for this head from the repository's Actions tab."
    [ "$recheck_status" != completed ] || break
    if [ "$recheck_waited" -ge "$RECHECK_WAIT" ]; then
      recheck_ledger_append skipped run-in-progress "$recheck_run" "$recheck_attempt"
      recheck_refuse run-in-progress \
        "Run $recheck_run for $recheck_head is '$recheck_status' after ${recheck_waited}s, and a run cannot be re-run while it is going." \
        "Whether it read the attestation depends on when it fetched the ref, which is not knowable from outside until it ends, so this is neither a pass nor a failure." \
        "Re-run only the re-evaluation once it finishes: bin/fm-attest.sh recheck --head $recheck_head"
    fi
    sleep "$RECHECK_POLL"
    recheck_waited=$((recheck_waited + RECHECK_POLL))
  done

  if [ "$recheck_conclusion" = success ]; then
    recheck_ledger_append skipped already-green "$recheck_run" "$recheck_attempt"
    emit "fm-attest: run $recheck_run already passed for $recheck_head, so there is nothing to re-evaluate"
    exit 0
  fi

  # ---- idempotency, the bound, then the one supported action -------------
  recheck_ledger_lock
  recheck_already=$(recheck_ledger_count "$recheck_ledger" \
    "repo=$recheck_repo_key pr=$recheck_pr head=$recheck_head run=$recheck_run attempt=$recheck_attempt action=requesting") \
    || recheck_already=
  case "$recheck_already" in
    '' | *[!0-9]*)
      recheck_fail ledger-unreadable \
        "$recheck_ledger could not be counted, so this cannot tell a first re-trigger from a repeat." \
        "Repair or remove it and re-run; nothing was re-triggered."
      ;;
  esac
  if [ "$recheck_already" -gt 0 ]; then
    recheck_ledger_unlock
    emit "fm-attest: attempt $recheck_attempt of run $recheck_run for $recheck_head has already been re-triggered; not requesting it again"
    exit 0
  fi

  recheck_spent=$(recheck_ledger_count "$recheck_ledger" \
    "repo=$recheck_repo_key pr=$recheck_pr head=$recheck_head action=requesting") \
    || recheck_spent=
  case "$recheck_spent" in
    '' | *[!0-9]*)
      recheck_fail ledger-unreadable \
        "$recheck_ledger could not be counted, so this cannot tell a first re-trigger from a repeat." \
        "Repair or remove it and re-run; nothing was re-triggered."
      ;;
  esac
  [ "$recheck_spent" -lt "$RECHECK_MAX" ] || recheck_refuse recheck-budget-spent \
    "$recheck_head has already been given $recheck_spent re-evaluations on pull request $recheck_pr of $recheck_repo, and the bound is $RECHECK_MAX." \
    "A re-trigger that has not converged by then is a fault to report rather than one to repeat." \
    "Every attempt is recorded in $recheck_ledger."

  recheck_url="https://github.com/$recheck_repo/actions/runs/$recheck_run"
  if [ "$recheck_dry_run" -eq 1 ]; then
    recheck_ledger_unlock
    emit "fm-attest: would re-run $recheck_url for $recheck_head (attempt $recheck_attempt concluded '$recheck_conclusion')"
    exit 0
  fi

  # Recorded BEFORE the request while the count and append share one lock.
  # This record consumes the attempt because after a crash there is no safe way
  # to distinguish a request that never happened from one GitHub accepted.
  # Burning an attempt is safe; posting the same attempt twice is not, and the
  # total bound leaves room for that fail-closed outcome.
  recheck_ledger_append requesting attestation-published "$recheck_run" "$recheck_attempt" \
    || recheck_fail ledger-unwritable \
      "Could not append to $recheck_ledger, so nothing was re-triggered." \
      "A re-evaluation nobody can audit is worse than one that did not happen: repair that path and re-run."
  recheck_ledger_unlock

  recheck_gh api --method POST "repos/$recheck_repo/actions/runs/$recheck_run/rerun" || {  # fm-retrieval-audit: write - a re-run dispatch, which is an action and has no observation type
    recheck_ledger_append refused rerun-not-requested "$recheck_run" "$recheck_attempt"
    recheck_fail rerun-not-requested \
      "GitHub did not accept a re-run of $recheck_url (gh exited $recheck_gh_rc)." \
      "gh said: ${RECHECK_ERR:-(nothing)}" \
      "Re-running a workflow run needs write access to that repository's Actions, which the author of a pull request raised from a fork does not hold on the parent." \
      "Ask someone holding it to re-run that run, or re-run it from the repository's Actions tab."
  }
  recheck_ledger_append requested attestation-published "$recheck_run" "$recheck_attempt"
  emit "fm-attest: re-evaluating $recheck_head - re-ran $recheck_url for pull request $recheck_pr of $recheck_repo"
}

# ---------------------------------------------------------------------------
# show
# ---------------------------------------------------------------------------

cmd_show() {
  commit=HEAD
  notes_ref=$NOTES_REF_DEFAULT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --commit)
        [ "$#" -ge 2 ] || die "--commit needs a value"
        commit=$2
        shift 2
        ;;
      --notes-ref)
        [ "$#" -ge 2 ] || die "--notes-ref needs a value"
        notes_ref=$2
        shift 2
        ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  git rev-parse --git-dir >/dev/null 2>&1 || fail not-a-git-repository \
    "This directory is not inside a git repository."
  sha=$(git rev-parse --verify "$commit^{commit}" 2>/dev/null) || fail commit-unknown \
    "No such commit in this repository: $commit"
  note=$(git notes --ref="$notes_ref" show "$sha" 2>/dev/null) \
    || refuse no-attestation-for-head "No attestation is recorded for $sha."
  emit "$note"
}

# ---------------------------------------------------------------------------

[ "$#" -ge 1 ] || {
  usage
  exit 2
}
command=$1
shift
case "$command" in
  write) cmd_write "$@" ;;
  verify) cmd_verify "$@" ;;
  recheck) cmd_recheck "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  required) cmd_required "$@" ;;
  declaration-check) cmd_declaration_check "$@" ;;
  show) cmd_show "$@" ;;
  # A capability query, answered as an exit status and nothing else: zero for a
  # capability this program has, non-zero for one it does not. It is not a
  # verdict and borrows neither error model, so a caller reads only whether it
  # succeeded. A copy of this script old enough to predate the query itself
  # answers non-zero by not recognizing it, which is the same answer.
  --supports)
    [ "$#" -ge 1 ] || die "--supports needs a capability"
    list_has "$1" "$CAPABILITIES"
    ;;
  --print-format) print_format ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
