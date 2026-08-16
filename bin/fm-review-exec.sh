#!/usr/bin/env bash
# fm-review-exec.sh - the component that ACTUALLY launches and captures a
# reviewer, and therefore the single owner of that review's execution evidence.
#
# THE ONE LAW
#
# Execution is established only by what THIS process observed with its own file
# descriptors and its own wait status, during the launch it performed itself.
# Nothing a reviewer says, and nothing anyone else writes down, can raise any
# dimension of the record to observed. In particular none of these establishes
# "review executed", now or ever:
#
#   - a suite label or any other text in the captured stream, including this
#     script's own literals appearing inside the reviewer's output;
#   - a task terminal line, a status event, or a backlog entry;
#   - a liveness signal, a running process, or an endpoint that answers;
#   - a reviewer acknowledgement, fresh or stale, of any assignment;
#   - a wrapper marker emitted by something that wrapped the real work;
#   - a caller-supplied assertion, case, or check name.
#
# The retired substrate this replaces failed exactly here. It ran a whole suite,
# grepped the output for `ok - <case>`, and printed
# `FM_RECURRENCE_ASSERTION_EXECUTED` on the strength of that line, so a suite
# that printed the label without running the assertion satisfied it. Worse, the
# review half established "a review happened" by reading a status event the
# reviewer itself had emitted, laundered through a status file - a claim citing
# itself. A substrate whose purpose is to stop execution being inferred from a
# proxy inferred execution from a proxy.
#
# So this script never reads the captured stream to decide anything. It reads
# it only to write it to disk, count its bytes, and digest it. The stream is
# EVIDENCE, addressed by location and digest; it is never TESTIMONY.
#
# WHAT THE RECORD BINDS
#
# One review attempt, in seventeen dimensions. Each is present with a value this
# process observed, or absent with the reason it could not be observed. There is
# no third form and no default:
#
#   attempt_identity           the review attempt this record is about
#   review_role                the review role that was requested
#   reviewer_binding           the reviewer this attempt was bound to
#   reviewer_effort            the effort or profile that binding required
#   candidate_commit           the exact commit under review, in the source
#   candidate_tree             that commit's exact tree
#   reviewer_checkout          where the reviewer was actually materialized
#   reviewer_checkout_commit   what that materialized checkout actually was
#   reviewer_checkout_tree     that checkout's exact tree
#   launch_executable          the resolved absolute path that was executed
#   launch_argv                the exact argv it was executed with
#   launch_cwd                 the exact working directory it ran in
#   started_at                 when the launch happened
#   ended_at                   when the terminal state was observed
#   terminal_state             exited, signalled, running, or not_started
#   exit_status                the exit code or signal number
#   artifact_sha256            the digest of the raw captured review artifact
#
# The raw artifact's LOCATION is the record's own directory, which is why it is
# not a separate dimension: a record and the bytes it digests are one artifact.
#
# HOW A RESULT IS REACHED
#
# Through bin/fm-verify-lib.sh's three-valued type, never two:
#
#   PASS             every dimension observed, and the reviewer reached a normal
#                    terminal state
#   FAIL             every dimension observed, and the reviewer reached a bad
#                    terminal state (non-zero exit, or a signal)
#   NO_VERIFIER_RAN  any dimension unobserved, or no terminal state observed at
#                    all. A reviewer still running has NOT executed for this
#                    purpose: liveness is the proxy, not the observation.
#
# A missing dimension outranks a good terminal state. Sixteen observed and one
# missing is could-not-observe, which leaves the review requirement UNSATISFIED
# rather than waived, assumed, or degraded to a warning.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO
#
# It does not read, parse, judge, or classify the review's CONTENT. Whether the
# reviewer approved or rejected, what it found, and whether its findings are
# sound are all a different question with a different owner. Mixing them is how
# a verdict starts standing in for an execution: this script answers only "did
# this exact reviewer actually run against this exact tree, and where are the
# bytes it produced".
#
# SOURCE ISOLATION
#
# The reviewer never runs in a checkout anyone else is using. Before any launch:
# the source must not be a primary checkout; the clone is made with
# --no-local so it borrows no objects; it is detached onto the pinned candidate
# and its HEAD is verified to equal it; it must own its repository
# administration; and it must have no objects/info/alternates. Each of those is
# refused as could-not-observe rather than warned about, because a reviewer that
# can write to a live checkout is not a read-only reviewer and a reviewer
# sharing object storage is not reviewing a pinned tree.
#
# IMMUTABILITY
#
# A record is written once. A second launch into an occupied output directory is
# refused; supersede a generation, never overwrite one. A record whose artifact
# is missing or whose digest no longer matches is could-not-observe, so a record
# cannot outlive the bytes it attests to.
#
# Usage:
#   fm-review-exec.sh launch --attempt <id> --role <role> --reviewer <binding>
#                            --effort <effort> --source <repo> --candidate <rev>
#                            --out <dir> -- <argv>...
#   fm-review-exec.sh show <dir>
#   fm-review-exec.sh result <dir>
#   fm-review-exec.sh -h | --help
#
# launch materializes, runs, captures, and writes <dir>/record.json plus the raw
# artifact <dir>/review.raw. Its exit status is 0 for an observed-good
# execution, 1 for an observed-bad one, and 2 for could-not-observe, matching
# bin/fm-verify.sh so that a caller reading nothing but the status still gets
# the fail-closed answer.
#
# show prints the record. result re-derives the three-valued outcome from the
# record's dimensions and a fresh re-digest of the artifact, and prints one
# bin/fm-verify.sh record so a consumer reads it through fm_verify_case and
# cannot write a two-branch read of a three-valued answer. It never trusts the
# stored outcome: a stored outcome that disagrees with the dimensions is itself
# could-not-observe.
set -u

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
  printf 'fm-review-exec: COULD_NOT_OBSERVE: %s\n' "$1" >&2
  exit 2
}

REQUIRED_DIMENSIONS='attempt_identity review_role reviewer_binding reviewer_effort
candidate_commit candidate_tree reviewer_checkout reviewer_checkout_commit
reviewer_checkout_tree launch_executable launch_argv launch_cwd started_at
ended_at terminal_state exit_status artifact_sha256'

digest_file() {  # <path> -> sha256 hex, or non-zero
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- launch -----------------------------------------------------------------

cmd_launch() {
  local attempt='' role='' reviewer='' effort='' source='' candidate='' out=''
  local want='' arg
  local -a argv=()
  local saw_separator=0

  while [ "$#" -gt 0 ]; do
    arg=$1
    if [ "$saw_separator" -eq 1 ]; then
      argv+=("$arg")
      shift
      continue
    fi
    if [ -n "$want" ]; then
      case "$want" in
        attempt) attempt=$arg ;;
        role) role=$arg ;;
        reviewer) reviewer=$arg ;;
        effort) effort=$arg ;;
        source) source=$arg ;;
        candidate) candidate=$arg ;;
        out) out=$arg ;;
      esac
      want=''
      shift
      continue
    fi
    case "$arg" in
      --) saw_separator=1 ;;
      --attempt) want=attempt ;;
      --attempt=*) attempt=${arg#--attempt=} ;;
      --role) want=role ;;
      --role=*) role=${arg#--role=} ;;
      --reviewer) want=reviewer ;;
      --reviewer=*) reviewer=${arg#--reviewer=} ;;
      --effort) want=effort ;;
      --effort=*) effort=${arg#--effort=} ;;
      --source) want=source ;;
      --source=*) source=${arg#--source=} ;;
      --candidate) want=candidate ;;
      --candidate=*) candidate=${arg#--candidate=} ;;
      --out) want=out ;;
      --out=*) out=${arg#--out=} ;;
      *) cno "unknown argument to launch: $arg" ;;
    esac
    shift
  done
  [ -z "$want" ] || cno "--$want requires a value"

  [ -n "$attempt" ] || cno "launch requires --attempt"
  [ -n "$role" ] || cno "launch requires --role"
  [ -n "$reviewer" ] || cno "launch requires --reviewer"
  [ -n "$effort" ] || cno "launch requires --effort"
  [ -n "$source" ] || cno "launch requires --source"
  [ -n "$candidate" ] || cno "launch requires --candidate"
  [ -n "$out" ] || cno "launch requires --out"
  [ "$saw_separator" -eq 1 ] || cno "launch requires -- followed by the reviewer argv"
  [ "${#argv[@]}" -gt 0 ] || cno "launch requires a reviewer argv after --"

  command -v git >/dev/null 2>&1 || cno "git is unavailable, so no candidate could be materialized"
  command -v jq >/dev/null 2>&1 || cno "jq is unavailable, so no record could be written"
  digest_file /dev/null >/dev/null 2>&1 || cno "no sha256 tool is available, so no artifact could be digested"
  command -v base64 >/dev/null 2>&1 || cno "base64 is unavailable, so the reviewer argv could not be recorded exactly"

  # The record directory is claimed BEFORE anything runs, and an occupied one is
  # refused rather than reused. Overwriting a generation is how a superseded
  # record silently becomes the current one.
  if [ -e "$out" ]; then
    [ -d "$out" ] || cno "output path exists and is not a directory: $out"
    [ -z "$(ls -A "$out" 2>/dev/null)" ] || cno "output directory is not empty, and a record is written once: $out"
  fi
  mkdir -p "$out" 2>/dev/null || cno "output directory cannot be created: $out"
  out=$(cd "$out" && pwd) || cno "output directory cannot be resolved: $out"

  local record=$out/record.json
  local raw=$out/review.raw
  local checkout=$out/checkout

  # --- source isolation ------------------------------------------------------
  [ -d "$source" ] || cno "source is not a directory: $source"
  source=$(cd "$source" && pwd) || cno "source cannot be resolved"
  [ "$(git -C "$source" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
    || cno "source is not a git checkout: $source"

  local git_dir common_dir
  git_dir=$(git -C "$source" rev-parse --absolute-git-dir 2>/dev/null) \
    || cno "source git directory is unreadable"
  common_dir=$(git -C "$source" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || cno "source git common directory is unreadable"
  [ "$git_dir" != "$common_dir" ] \
    || cno "review execution refuses a primary checkout as its source: $source"

  case "$out" in
    "$source"|"$source"/*) cno "output directory is inside the source checkout: $out" ;;
  esac

  local candidate_commit candidate_tree
  candidate_commit=$(git -C "$source" rev-parse --verify --quiet "$candidate^{commit}" 2>/dev/null) \
    || cno "candidate does not resolve to a commit in the source: $candidate"
  candidate_tree=$(git -C "$source" rev-parse --verify --quiet "$candidate_commit^{tree}" 2>/dev/null) \
    || cno "candidate commit has no readable tree: $candidate_commit"

  # --no-local so the clone copies objects instead of borrowing them. A clone
  # that hardlinks the source's object store is not isolated from it.
  git clone --quiet --no-local "$source" "$checkout" 2>/dev/null \
    || cno "disposable reviewer clone failed"
  git -C "$checkout" checkout --quiet --detach "$candidate_commit" 2>/dev/null \
    || cno "reviewer checkout could not detach onto the pinned candidate"
  [ "$(git -C "$checkout" rev-parse HEAD 2>/dev/null)" = "$candidate_commit" ] \
    || cno "reviewer checkout does not match the pinned candidate"
  [ "$(git -C "$checkout" rev-parse --git-common-dir 2>/dev/null)" = .git ] \
    || cno "reviewer checkout shares repository administration"
  [ ! -e "$checkout/.git/objects/info/alternates" ] \
    || cno "reviewer checkout depends on the source's objects"
  # --no-local is what makes the clone copy objects instead of hardlinking them,
  # and losing that flag is invisible to every other check here: a hardlinked
  # clone still detaches onto the candidate, still owns its administration, and
  # still has no alternates. So the property is checked directly rather than the
  # flag being trusted. A link count above one under the clone's object store
  # means those bytes are shared with something, which is the whole thing
  # --no-local exists to prevent.
  [ -z "$(find "$checkout/.git/objects" -type f -links +1 -print 2>/dev/null | head -n 1)" ] \
    || cno "reviewer checkout shares object storage with the source"

  local checkout_commit checkout_tree
  checkout_commit=$(git -C "$checkout" rev-parse HEAD 2>/dev/null) \
    || cno "reviewer checkout commit is unreadable"
  checkout_tree=$(git -C "$checkout" rev-parse 'HEAD^{tree}' 2>/dev/null) \
    || cno "reviewer checkout tree is unreadable"
  [ "$checkout_tree" = "$candidate_tree" ] \
    || cno "reviewer checkout tree does not match the candidate tree"

  # --- launch ----------------------------------------------------------------
  local executable
  executable=$(command -v -- "${argv[0]}" 2>/dev/null) \
    || cno "reviewer executable does not resolve: ${argv[0]}"
  case "$executable" in
    /*) ;;
    *) executable=$(cd "$(dirname "$executable")" && pwd)/$(basename "$executable") \
         || cno "reviewer executable path cannot be resolved" ;;
  esac
  [ -x "$executable" ] || cno "reviewer executable is not executable: $executable"

  local started_at ended_at status terminal_state
  started_at=$(now_utc)

  # The raw artifact is captured by THIS process, into a file descriptor it
  # opened itself, so its bytes are an observation rather than a report.
  ( cd "$checkout" && exec "$executable" "${argv[@]:1}" ) >"$raw" 2>&1
  status=$?
  ended_at=$(now_utc)

  # A shell reports a signalled child as 128+n, which is how a reviewer that was
  # killed is told apart from one that chose its own exit code.
  #
  # There is deliberately no deadline option here. Wrapping the launch in
  # timeout(1) would make exit 124 mean either "the deadline killed it" or "the
  # reviewer exited 124 by itself", and one status covering both a kill and a
  # verdict is the exact type error this substrate exists to refuse. A reviewer
  # that never terminates is already covered: with no terminal state observed,
  # the result is could-not-observe.
  if [ "$status" -gt 128 ] && [ "$status" -lt 192 ]; then
    terminal_state=signalled
    status=$((status - 128))
  else
    terminal_state=exited
  fi

  [ -f "$raw" ] || cno "raw review artifact was not captured"
  local artifact_sha256
  artifact_sha256=$(digest_file "$raw") \
    || cno "raw review artifact could not be digested"
  [ -n "$artifact_sha256" ] || cno "raw review artifact digest is empty"

  # Each argument is base64'd before it reaches jq, because the encoding has to
  # be TOTAL over real argv: an argument may begin with a dash (jq's --args
  # still parses those as its own options), contain a newline (so a
  # newline-joined string cannot round-trip), or be empty (so an emptiness
  # filter would drop it). A record that cannot represent the argv it observed
  # is not a record of that argv.
  local argv_json a
  argv_json=$(
    for a in "${argv[@]}"; do
      printf '%s' "$a" | base64 | tr -d '\n'
      printf '\n'
    done | jq -Rs -c 'rtrimstr("\n") | split("\n") | map(@base64d)'
  ) || cno "reviewer argv could not be recorded"
  [ -n "$argv_json" ] || cno "reviewer argv could not be recorded"

  jq -n \
    --arg attempt "$attempt" --arg role "$role" --arg reviewer "$reviewer" \
    --arg effort "$effort" --arg cc "$candidate_commit" --arg ct "$candidate_tree" \
    --arg co "$checkout" --arg coc "$checkout_commit" --arg cot "$checkout_tree" \
    --arg exe "$executable" --argjson argv "$argv_json" --arg cwd "$checkout" \
    --arg started "$started_at" --arg ended "$ended_at" --arg term "$terminal_state" \
    --arg status "$status" --arg sha "$artifact_sha256" --arg raw "review.raw" \
    --arg recorded "$(now_utc)" '
    {
      schema: "fm-review-exec.v1",
      generation: 1,
      recorded_at: $recorded,
      artifact: $raw,
      dimensions: {
        attempt_identity:         { observed: true, value: $attempt },
        review_role:              { observed: true, value: $role },
        reviewer_binding:         { observed: true, value: $reviewer },
        reviewer_effort:          { observed: true, value: $effort },
        candidate_commit:         { observed: true, value: $cc },
        candidate_tree:           { observed: true, value: $ct },
        reviewer_checkout:        { observed: true, value: $co },
        reviewer_checkout_commit: { observed: true, value: $coc },
        reviewer_checkout_tree:   { observed: true, value: $cot },
        launch_executable:        { observed: true, value: $exe },
        launch_argv:              { observed: true, value: $argv },
        launch_cwd:               { observed: true, value: $cwd },
        started_at:               { observed: true, value: $started },
        ended_at:                 { observed: true, value: $ended },
        terminal_state:           { observed: true, value: $term },
        exit_status:              { observed: true, value: ($status | tonumber) },
        artifact_sha256:          { observed: true, value: $sha }
      }
    }' >"$record.tmp" 2>/dev/null || cno "execution record could not be written"
  mv -f "$record.tmp" "$record" 2>/dev/null || cno "execution record could not be published"

  emit_result "$out"
}

# --- result -----------------------------------------------------------------

# The outcome is DERIVED here, every time, from the record's dimensions and a
# fresh re-digest of the artifact. Nothing stored in the record decides it.
# A record that carries a stored outcome is not consulted for it: this is the
# whole point of the substrate, applied to the substrate's own output.
derive_result() {  # <dir>; sets DERIVED_RESULT and DERIVED_REASON
  local dir=$1
  local record=$dir/record.json
  local raw missing schema term status sha actual
  DERIVED_RESULT=NO_VERIFIER_RAN
  DERIVED_REASON=no_evidence

  command -v jq >/dev/null 2>&1 || { DERIVED_REASON=verifier_unavailable; return 0; }
  [ -f "$record" ] || { DERIVED_REASON=empty_result_set; return 0; }
  schema=$(jq -r 'if type == "object" then (.schema // "") else "" end' "$record" 2>/dev/null) \
    || { DERIVED_REASON=no_evidence; return 0; }
  [ "$schema" = fm-review-exec.v1 ] || { DERIVED_REASON=no_evidence; return 0; }

  # An unobserved dimension outranks everything below it, including a perfectly
  # normal terminal state, so it is checked first and reported by name.
  missing=$(jq -r --arg req "$REQUIRED_DIMENSIONS" '
      . as $rec
      | ($req | split("\n") | map(split(" ")) | flatten | map(select(length > 0))) as $need
      | [ $need[]
          | . as $d
          | ($rec.dimensions[$d]?) as $dim
          | select(($dim | type) != "object"
                   or $dim.observed != true
                   or $dim.value == null
                   or (($dim.value | type) == "string" and $dim.value == ""))
          | $d ]
      | join(" ")' "$record" 2>/dev/null) || { DERIVED_REASON=no_evidence; return 0; }
  if [ -n "$missing" ]; then
    DERIVED_REASON=verification_incomplete
    DERIVED_MISSING=$missing
    return 0
  fi

  # A name, never a path: a record that could point its digest at a file
  # outside its own directory could borrow another artifact's bytes.
  local artifact_name
  artifact_name=$(jq -r '.artifact // ""' "$record" 2>/dev/null)
  case "$artifact_name" in
    ''|*/*|.*) DERIVED_REASON=no_evidence; return 0 ;;
  esac
  raw=$dir/$artifact_name
  sha=$(jq -r '.dimensions.artifact_sha256.value' "$record" 2>/dev/null)
  [ -f "$raw" ] || { DERIVED_REASON=no_evidence; return 0; }
  actual=$(digest_file "$raw") || { DERIVED_REASON=verifier_unavailable; return 0; }
  [ "$actual" = "$sha" ] || { DERIVED_REASON=no_evidence; return 0; }

  # The isolation law is re-proven HERE, on every read, against the checkout the
  # record names - not merely at launch. Two things follow. A reviewer that
  # moved its own checkout off the pinned candidate is caught, which is the
  # restoration check. And a record cannot be made to assert an execution
  # without an isolated materialized checkout still standing at the exact
  # candidate tree behind it, so the cheapest forgery - a plausible record with
  # no reviewer behind it - reaches could-not-observe rather than a pass.
  local co coc cot
  co=$(jq -r '.dimensions.reviewer_checkout.value' "$record" 2>/dev/null)
  coc=$(jq -r '.dimensions.reviewer_checkout_commit.value' "$record" 2>/dev/null)
  cot=$(jq -r '.dimensions.reviewer_checkout_tree.value' "$record" 2>/dev/null)
  command -v git >/dev/null 2>&1 || { DERIVED_REASON=verifier_unavailable; return 0; }
  [ -d "$co" ] || { DERIVED_REASON=verification_unreachable; return 0; }
  [ "$(git -C "$co" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
    || { DERIVED_REASON=verification_unreachable; return 0; }
  [ "$(git -C "$co" rev-parse HEAD 2>/dev/null)" = "$coc" ] \
    || { DERIVED_REASON=verification_unreachable; return 0; }
  [ "$(git -C "$co" rev-parse 'HEAD^{tree}' 2>/dev/null)" = "$cot" ] \
    || { DERIVED_REASON=verification_unreachable; return 0; }
  [ "$(git -C "$co" rev-parse --git-common-dir 2>/dev/null)" = .git ] \
    || { DERIVED_REASON=verification_unreachable; return 0; }
  [ ! -e "$co/.git/objects/info/alternates" ] \
    || { DERIVED_REASON=verification_unreachable; return 0; }

  term=$(jq -r '.dimensions.terminal_state.value' "$record" 2>/dev/null)
  status=$(jq -r '.dimensions.exit_status.value' "$record" 2>/dev/null)
  case "$term" in
    exited)
      if [ "$status" = 0 ]; then
        DERIVED_RESULT=PASS
        DERIVED_REASON=verified
      else
        DERIVED_RESULT=FAIL
        DERIVED_REASON=verifier_reported_failure
      fi
      ;;
    signalled)
      DERIVED_RESULT=FAIL
      DERIVED_REASON=verifier_reported_failure
      ;;
    running|not_started)
      DERIVED_RESULT=NO_VERIFIER_RAN
      DERIVED_REASON=verification_incomplete
      ;;
    *)
      DERIVED_RESULT=NO_VERIFIER_RAN
      DERIVED_REASON=no_evidence
      ;;
  esac
}

DERIVED_RESULT=
DERIVED_REASON=
DERIVED_MISSING=

emit_result() {  # <dir>
  local dir=$1
  DERIVED_MISSING=
  derive_result "$dir"
  printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  %s,%s,%s,%s\n' \
    review-exec "$DERIVED_RESULT" "$DERIVED_REASON" "$dir/record.json"
  if [ -n "$DERIVED_MISSING" ]; then
    printf 'fm-review-exec: unobserved dimensions: %s\n' "$DERIVED_MISSING" >&2
  fi
  case "$DERIVED_RESULT" in
    PASS) return 0 ;;
    FAIL) return 1 ;;
    *) return 2 ;;
  esac
}

cmd_show() {
  local dir=${1:-}
  [ -n "$dir" ] || cno "show requires a record directory"
  [ -f "$dir/record.json" ] || cno "no execution record in $dir"
  cat "$dir/record.json"
}

cmd_result() {
  local dir=${1:-}
  [ -n "$dir" ] || cno "result requires a record directory"
  emit_result "$dir"
}

case "${1:-}" in
  -h|--help|'') usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
  launch) shift; cmd_launch "$@" ;;
  show) shift; cmd_show "$@" ;;
  result) shift; cmd_result "$@" ;;
  *) cno "unknown subcommand: $1" ;;
esac
