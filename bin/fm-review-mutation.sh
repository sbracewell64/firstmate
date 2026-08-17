#!/usr/bin/env bash
# fm-review-mutation.sh - the proof owner for recurrence and mutation cases, and
# therefore the single owner of the answer "did the NAMED TARGET ASSERTION run,
# and what did it conclude".
#
# THE ONE LAW, INHERITED
#
# The component that ACTUALLY executes the target assertion must emit and own
# the evidence that it executed. bin/fm-review-exec.sh is that component here:
# it launches a probe in a disposable clone pinned to an exact tree and observes
# the terminal state with its own wait status. This script consumes that
# substrate through its published interface and never reimplements it.
#
# So none of these establishes that a named assertion ran, now or ever:
#
#   - a suite label, or any other text in the probe's captured stream;
#   - a task terminal line, a status event, or a backlog entry;
#   - a liveness signal, a running process, or an endpoint that answers;
#   - an acknowledgement, fresh or stale;
#   - a wrapper marker emitted by something that wrapped the real work;
#   - a caller-supplied assertion, case, or check name.
#
# This script NEVER READS THE PROBE'S OUTPUT. Not to grep it, not to count it,
# not to classify it. The captured stream reaches disk under
# bin/fm-review-exec.sh's ownership and is addressed there by digest; nothing in
# this file opens it. That is structural, not a policy: a literal planted in a
# probe's stdout cannot reach any decision here because no decision here has a
# path to those bytes.
#
# THE RETIRED DEFECT, WHICH THIS INCREMENT IS THE ONE THAT REPEATED
#
# The predecessor ran an entire suite and then treated an exact textual
# `ok - <case>` / `not ok - <case>: <failure>` line as proof that the named
# assertion had executed. Its mutation catalogue routed many distinct cases
# through that same broad-suite wrapper, including cases whose stated purpose
# was proving that labels and proxies cannot establish execution. A substrate
# built to stop execution being inferred from a proxy inferred execution from a
# proxy. Fifteen correction rounds did not fix it, so it was retired rather than
# repaired a sixteenth time.
#
# HOW EXECUTION IS ESTABLISHED INSTEAD
#
# By causal control of the verdict, measured in both directions, from three
# executions this script commissions and never interprets beyond their terminal
# states.
#
# For one case, the named target's exact bytes are located in one file of the
# pinned candidate tree and substituted three ways, each producing its own
# commit in a disposable clone:
#
#   baseline   the target substituted with ITSELF. The apparatus runs in full -
#              splice, blob, tree, commit, clone, launch - and the resulting
#              tree must be byte-identical to the candidate tree. This is both
#              the restoration check and the apparatus control: whatever the
#              other two runs show, it is not an artifact of the machinery.
#   falsified  the target substituted with bytes that must make it conclude
#              FAIL if it is evaluated at all.
#   satisfied  the target substituted with bytes that must make it conclude
#              PASS if it is evaluated at all.
#
# The probe's verdict is then said to be CONTROLLED BY the named bytes only when
# the falsified run is observed bad AND the satisfied run is observed good. Both
# directions are required, and the satisfied direction is what makes the
# falsified one attributable: a substitution that merely breaks the file would
# move the falsified run too, and it moves the satisfied run with it, which
# reaches could-not-observe instead of a verdict.
#
# Once control is established, the BASELINE run - the unmutated candidate - says
# what the target concluded, and it says so attributably: baseline and satisfied
# differ only inside the target's byte range, so a bad baseline against a good
# satisfied run is caused by the target.
#
# The decisive property, stated as the retired defect would meet it: a probe
# that prints `ok - <case>` and exits 0 without evaluating the assertion returns
# the SAME verdict when the assertion is falsified. That is complete observation
# of the falsifying direction, and it is a finding, so the case FAILS.
#
# HOW A RESULT IS REACHED
#
# Through bin/fm-verify-lib.sh's three-valued type, never two. Let n, s, b be
# the falsified, satisfied, and baseline results, each re-derived fresh:
#
#   n PASS                     FAIL. The probe passed with the target falsified,
#                              so its verdict is not controlled by the target.
#                              Checked FIRST: a failure outranks a
#                              could-not-observe, and an observation gap must
#                              never mask a real finding.
#   any of n, s, b unobserved  NO_VERIFIER_RAN.
#   s FAIL                     NO_VERIFIER_RAN. The satisfying substitution did
#                              not yield a satisfied probe, so the falsified
#                              run's badness is not attributable to the target.
#   otherwise (n FAIL, s PASS) control established; b decides:
#     b PASS                   PASS. The target executed and concluded pass.
#     b FAIL                   FAIL. The target executed and concluded fail.
#
# WHAT THIS ESTABLISHES, AND WHAT IT DOES NOT
#
# It establishes that the probe's terminal verdict is controlled by the named
# target's exact bytes in both directions, and what verdict the probe reached on
# the unmutated candidate.
#
# It does not establish WHY those bytes control the verdict. Terminal states
# cannot separate "the assertion evaluated these bytes" from "these bytes were
# load-bearing for some other reason", and this script does not pretend
# otherwise: the limit is written into every record it produces, under
# does_not_establish, alongside all three exits so a reader can judge it. The
# satisfied direction is required precisely to shrink that gap, and the record
# is the place the residue is admitted rather than argued away.
#
# It also does not establish that the caller's words are true. Everything the
# caller says about a case - its name, its purpose, the defect it recurs on -
# is recorded under `declared`, which is quarantined from `dimensions` and is
# never read to reach a verdict. Prose is not evidence.
#
# THE MUTATION NEVER TOUCHES WHAT IT PROTECTS
#
# No working tree is ever written. The substitution is performed on bytes read
# out of the object database, hashed into a new blob, spliced into a temporary
# index, and committed with commit-tree, all inside a disposable clone made with
# --no-local. The source is opened read-only and is never a commit target, so
# there is no window in which a concurrent reader could see a mutated source -
# restore-in-finally would leave exactly that window, which is why none is used.
#
# The disposable clone re-proves the isolation law on its own terms: it must own
# its repository administration, carry no alternates, and share no object
# storage. Object sharing is measured by link count, because losing --no-local
# is invisible to every other check. bin/fm-review-exec.sh then applies the same
# law again to each execution's own clone.
#
# THE EXACTLY-ONE-OCCURRENCE GUARD
#
# The target must occur exactly once in the named file, counted by START
# POSITION so overlapping occurrences are counted separately. Zero occurrences
# is refused, and so is more than one: a substitution with two candidate sites
# mutates a site nobody chose. Discovery is not identity - the match locates
# bytes and nothing more, which is why the located bytes then have to earn the
# verdict by controlling it.
#
# IMMUTABILITY
#
# A record is written once. A second prove into an occupied output directory is
# refused; supersede a generation, never overwrite one. The evidence a record
# rests on - the disposable clone, the exact byte files, and each execution's
# own record and materialized checkout - stays under the output directory,
# because `result` re-derives everything from them and trusts nothing stored.
#
# The reason vocabulary in the emitted record is bin/fm-verify.sh's closed one
# and is not extended here. Where this script draws a distinction that vocabulary
# does not carry - a failure of the target versus a target that never ran - the
# distinction lives in the record the result points at, under verdict_basis, and
# on stderr. One owner for the vocabulary, one owner for the finding.
#
# Usage:
#   fm-review-mutation.sh prove --case <id> --source <repo> --candidate <rev>
#                               --path <path-in-tree> --target <file>
#                               --falsify <file> --satisfy <file> --out <dir>
#                               [--declare <text>] -- <probe argv>...
#   fm-review-mutation.sh catalogue --catalogue <json> --source <repo>
#                               --candidate <rev> --out <dir>
#   fm-review-mutation.sh show <dir>
#   fm-review-mutation.sh result <dir>
#   fm-review-mutation.sh -h | --help
#
# --target, --falsify and --satisfy name FILES holding exact bytes, not literals,
# because an assertion spans lines and an argv-passed literal invites a shell to
# reshape it before this script ever sees it.
#
# --out must resolve outside the source checkout and must not contain a `..`
# component. Both prove and catalogue judge that path from its nearest existing
# ancestor before creating it, so a refusal leaves no trace in the source.
#
# prove writes <dir>/record.json and returns 0 for PASS, 1 for FAIL, and 2 for
# could-not-observe, matching bin/fm-verify.sh so a caller reading nothing but
# the status still gets the fail-closed answer.
#
# catalogue proves every case in a JSON catalogue into <dir>/cases/<id> and
# writes <dir>/catalogue.json. Its fold is precedence-ordered: one FAIL makes
# the catalogue FAIL, one could-not-observe makes it could-not-observe, and only
# an all-PASS catalogue passes. An empty catalogue is could-not-observe, never a
# clean one.
#
# show prints the record. result re-derives the outcome from the record's
# dimensions, a fresh re-read of each execution through bin/fm-verify.sh, and a
# fresh re-check of the three mutant trees against the object database. It never
# consults a stored outcome.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# shellcheck source=bin/fm-verify-lib.sh
. "$SCRIPT_DIR/fm-verify-lib.sh"

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
  printf 'fm-review-mutation: COULD_NOT_OBSERVE: %s\n' "$1" >&2
  exit 2
}

REQUIRED_DIMENSIONS='case_identity candidate_commit candidate_tree target_path
target_mode target_blob target_sha256 target_length target_occurrences
target_offset probe_argv staging_root staging_isolation baseline_commit
baseline_tree falsified_commit falsified_tree satisfied_commit satisfied_tree
baseline_execution falsified_execution satisfied_execution'

VARIANTS='baseline falsified satisfied'

# The commit identity used for every mutant commit. Fixed rather than inherited
# so a mutant commit is a function of its tree and nothing else, and so this
# script needs no configured git identity to run.
export GIT_AUTHOR_NAME=fm-review-mutation
export GIT_AUTHOR_EMAIL=fm-review-mutation@invalid
export GIT_COMMITTER_NAME=fm-review-mutation
export GIT_COMMITTER_EMAIL=fm-review-mutation@invalid
export GIT_AUTHOR_DATE='1970-01-01T00:00:00 +0000'
export GIT_COMMITTER_DATE='1970-01-01T00:00:00 +0000'

digest_file() {  # <path> -> sha256 hex, or non-zero
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

guard_output_outside_source() {  # <resolved-source> <raw-output>
  local source=$1 out=$2 out_parent out_leaf out_resolved
  case "$out" in
    */../*|*/..|../*|..) cno "output path must not contain a .. component: $out" ;;
  esac
  out_parent=$out
  out_leaf=
  while [ ! -d "$out_parent" ] && [ "$out_parent" != / ] && [ "$out_parent" != . ]; do
    if [ -n "$out_leaf" ]; then
      out_leaf=$(basename -- "$out_parent")/$out_leaf
    else
      out_leaf=$(basename -- "$out_parent")
    fi
    out_parent=$(dirname -- "$out_parent")
  done
  [ -d "$out_parent" ] || cno "output directory has no existing ancestor: $out"
  out_parent=$(cd "$out_parent" && pwd -P) || cno "output directory cannot be resolved: $out"
  out_resolved=$out_parent
  [ -z "$out_leaf" ] || out_resolved=$out_resolved/$out_leaf
  case "$out_resolved" in
    "$source"|"$source"/*) cno "output directory is inside the source checkout: $out" ;;
  esac
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- reading one execution's result ------------------------------------------
#
# Read through bin/fm-verify.sh, which transports bin/fm-review-exec.sh's own
# derivation, and consumed through fm_verify_case, which refuses a consumer that
# does not handle all three values. The exit status is deliberately not
# consulted: the record is the observation.
EXEC_RESULT=
EXEC_REASON=

exec_saw_pass() { EXEC_RESULT=PASS; }
exec_saw_fail() { EXEC_RESULT=FAIL; }
exec_saw_nothing() { EXEC_RESULT=NO_VERIFIER_RAN; }

read_execution() {  # <record-dir>; sets EXEC_RESULT and EXEC_REASON
  local dir=$1 record
  EXEC_RESULT=NO_VERIFIER_RAN
  EXEC_REASON=no_evidence
  if [ ! -x "$SCRIPT_DIR/fm-verify.sh" ]; then
    EXEC_REASON=verifier_unavailable
    return 0
  fi
  record=$("$SCRIPT_DIR/fm-verify.sh" review-exec "$dir" 2>/dev/null)
  if ! fm_verify_case "$record" exec_saw_pass exec_saw_fail exec_saw_nothing; then
    EXEC_RESULT=NO_VERIFIER_RAN
    EXEC_REASON=no_evidence
    return 0
  fi
  EXEC_REASON=$FM_VERIFY_REASON
  return 0
}

execution_matches() {  # <record-dir> <commit> <tree> <argv-json>
  local dir=$1 commit=$2 tree=$3 argv_json=$4 record
  record=$dir/record.json
  [ -f "$record" ] || return 1
  jq -e --arg commit "$commit" --arg tree "$tree" --argjson argv "$argv_json" '
    .schema == "fm-review-exec.v1"
    and .dimensions.candidate_commit.observed == true
    and .dimensions.candidate_commit.value == $commit
    and .dimensions.candidate_tree.observed == true
    and .dimensions.candidate_tree.value == $tree
    and .dimensions.launch_argv.observed == true
    and .dimensions.launch_argv.value == $argv
  ' "$record" >/dev/null 2>&1
}

# --- the fold ----------------------------------------------------------------
#
# One function, so the ordering that encodes the precedence law exists once.
fold_case() {  # <falsified> <satisfied> <baseline>; sets FOLD_*
  local n=$1 s=$2 b=$3
  FOLD_RESULT=NO_VERIFIER_RAN
  FOLD_REASON=no_evidence
  FOLD_BASIS=unreadable_executions

  # A finding first. The probe passing with the target falsified is a complete
  # observation of the falsifying direction, so it outranks any gap elsewhere.
  if [ "$n" = PASS ]; then
    FOLD_RESULT=FAIL
    FOLD_REASON=verifier_reported_failure
    FOLD_BASIS=target_not_executed
    return 0
  fi
  if [ "$n" = NO_VERIFIER_RAN ] || [ "$s" = NO_VERIFIER_RAN ] || [ "$b" = NO_VERIFIER_RAN ]; then
    FOLD_RESULT=NO_VERIFIER_RAN
    FOLD_REASON=verification_incomplete
    FOLD_BASIS=execution_not_observed
    return 0
  fi
  if [ "$s" = FAIL ]; then
    FOLD_RESULT=NO_VERIFIER_RAN
    FOLD_REASON=no_verdict_reached
    FOLD_BASIS=control_not_attributable
    return 0
  fi
  # n FAIL and s PASS: the verdict is controlled by the named bytes in both
  # directions, so the unmutated run is attributable to the target.
  if [ "$b" = PASS ]; then
    FOLD_RESULT=PASS
    FOLD_REASON=verified
    FOLD_BASIS=target_executed_and_concluded_pass
  else
    FOLD_RESULT=FAIL
    FOLD_REASON=verifier_reported_failure
    FOLD_BASIS=target_executed_and_concluded_fail
  fi
  return 0
}

FOLD_RESULT=
FOLD_REASON=
FOLD_BASIS=

# --- prove -------------------------------------------------------------------

# Splices one target occurrence three ways, in one pass over the exact bytes.
# Overlapping start positions are counted separately: "aa" occurs twice in
# "aaa", and a substitution with two candidate sites has no single site.
plan_mutations() {  # <orig> <target> <base-out> <falsify-in> <falsify-out> <satisfy-in> <satisfy-out>
  python3 -c '
import sys

orig_p, target_p, base_out, fal_in, fal_out, sat_in, sat_out = sys.argv[1:]
try:
    data = open(orig_p, "rb").read()
    target = open(target_p, "rb").read()
    falsify = open(fal_in, "rb").read()
    satisfy = open(sat_in, "rb").read()
except OSError:
    sys.exit(4)
if not target:
    sys.exit(5)

positions = []
at = data.find(target)
while at != -1:
    positions.append(at)
    at = data.find(target, at + 1)

print(len(positions), positions[0] if positions else -1)
if len(positions) != 1:
    sys.exit(3)

start = positions[0]
end = start + len(target)
for path, replacement in ((base_out, target), (fal_out, falsify), (sat_out, satisfy)):
    with open(path, "wb") as handle:
        handle.write(data[:start] + replacement + data[end:])
' "$@"
}

# Builds one mutant commit from a spliced file, entirely in the object database.
# No working tree is written, so nothing this function does is visible to a
# concurrent reader of any checkout.
build_variant() {  # <staging> <candidate-tree> <candidate-commit> <path> <mode> <spliced> <variant>
  local staging=$1 cand_tree=$2 cand_commit=$3 path=$4 mode=$5 spliced=$6 variant=$7
  local blob tree commit index=$staging/.git/fm-mutation-index.$variant
  blob=$(git -C "$staging" hash-object -w --no-filters -t blob "$spliced" 2>/dev/null) \
    || return 1
  rm -f "$index"
  GIT_INDEX_FILE=$index git -C "$staging" read-tree "$cand_tree" 2>/dev/null || return 1
  GIT_INDEX_FILE=$index git -C "$staging" update-index --cacheinfo "$mode,$blob,$path" 2>/dev/null \
    || return 1
  tree=$(GIT_INDEX_FILE=$index git -C "$staging" write-tree 2>/dev/null) || return 1
  rm -f "$index"
  commit=$(git -C "$staging" commit-tree "$tree" -p "$cand_commit" -m "fm-review-mutation:$variant" 2>/dev/null) \
    || return 1
  git -C "$staging" update-ref "refs/heads/fm-mutation-$variant" "$commit" 2>/dev/null || return 1
  printf '%s %s\n' "$commit" "$tree"
}

validate_mutation_evidence() {  # <staging> <work> <record>
  local staging=$1 work=$2 record=$3
  python3 - "$staging" "$work" "$record" <<'PY'
import hashlib
import json
import subprocess
import sys

staging, work, record_path = sys.argv[1:]
try:
    with open(record_path, "rb") as handle:
        record = json.load(handle)
    dimensions = record["dimensions"]
    values = {name: dimension["value"] for name, dimension in dimensions.items()}
    candidate = values["candidate_commit"]
    path = values["target_path"]
    entry = subprocess.check_output(
        ["git", "-C", staging, "ls-tree", "-z", candidate, "--", path], stderr=subprocess.DEVNULL
    ).rstrip(b"\0").split(b"\t", 1)
    if len(entry) != 2:
        raise ValueError
    metadata = entry[0].decode().split()
    if len(metadata) != 3 or metadata[1] != "blob":
        raise ValueError
    mode, _, candidate_blob = metadata
    entry_path = entry[1].decode()
    if entry_path != path or mode not in ("100644", "100755"):
        raise ValueError
    original = subprocess.check_output(
        ["git", "-C", staging, "cat-file", "blob", candidate_blob], stderr=subprocess.DEVNULL
    )
    with open(work + "/target.bytes", "rb") as handle:
        target = handle.read()
    with open(work + "/falsify.bytes", "rb") as handle:
        falsify = handle.read()
    with open(work + "/satisfy.bytes", "rb") as handle:
        satisfy = handle.read()
    if not target:
        raise ValueError
    positions = []
    offset = original.find(target)
    while offset != -1:
        positions.append(offset)
        offset = original.find(target, offset + 1)
    if len(positions) != 1:
        raise ValueError
    offset = positions[0]
    expected = {
        "baseline": original[:offset] + target + original[offset + len(target):],
        "falsified": original[:offset] + falsify + original[offset + len(target):],
        "satisfied": original[:offset] + satisfy + original[offset + len(target):],
    }
    object_format = subprocess.check_output(
        ["git", "-C", staging, "rev-parse", "--show-object-format"], stderr=subprocess.DEVNULL
    ).decode().strip()
    digest = getattr(hashlib, object_format)
    expected_blobs = {
        name: digest(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
        for name, content in expected.items()
    }
    if (
        values["target_mode"] != mode
        or values["target_blob"] != candidate_blob
        or values["target_sha256"] != hashlib.sha256(target).hexdigest()
        or values["target_length"] != len(target)
        or values["target_occurrences"] != 1
        or values["target_offset"] != offset
    ):
        raise ValueError
    for name in ("baseline", "falsified", "satisfied"):
        commit = values[name + "_commit"]
        tree = values[name + "_tree"]
        actual_tree = subprocess.check_output(
            ["git", "-C", staging, "rev-parse", commit + "^{tree}"], stderr=subprocess.DEVNULL
        ).decode().strip()
        parents = subprocess.check_output(
            ["git", "-C", staging, "show", "-s", "--format=%P", commit], stderr=subprocess.DEVNULL
        ).decode().strip().split()
        mutant_entry = subprocess.check_output(
            ["git", "-C", staging, "ls-tree", "-z", commit, "--", path], stderr=subprocess.DEVNULL
        ).rstrip(b"\0").split(b"\t", 1)
        mutant_metadata = mutant_entry[0].decode().split() if len(mutant_entry) == 2 else []
        if (
            actual_tree != tree
            or parents != [candidate]
            or len(mutant_metadata) != 3
            or mutant_metadata[0] != mode
            or mutant_metadata[1] != "blob"
            or mutant_metadata[2] != expected_blobs[name]
            or mutant_entry[1].decode() != path
        ):
            raise ValueError
except (AttributeError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError):
    sys.exit(1)
PY
}

# The isolation law, applied to this script's own disposable clone. Each
# execution's clone is checked again by bin/fm-review-exec.sh; this is the copy
# the mutation itself lives in.
prove_clone_isolated() {  # <clone>
  local clone=$1
  [ "$(git -C "$clone" rev-parse --git-common-dir 2>/dev/null)" = .git ] || return 1
  [ ! -e "$clone/.git/objects/info/alternates" ] || return 1
  [ -z "$(find "$clone/.git/objects" -type f -links +1 -print 2>/dev/null | head -n 1)" ] || return 1
  return 0
}

cmd_prove() {
  local case_id='' source='' candidate='' path='' target='' falsify='' satisfy=''
  local out='' declare_text='' want='' arg source_root
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
        case) case_id=$arg ;;
        source) source=$arg ;;
        candidate) candidate=$arg ;;
        path) path=$arg ;;
        target) target=$arg ;;
        falsify) falsify=$arg ;;
        satisfy) satisfy=$arg ;;
        out) out=$arg ;;
        declare) declare_text=$arg ;;
      esac
      want=''
      shift
      continue
    fi
    case "$arg" in
      --) saw_separator=1 ;;
      --case) want=case ;;
      --case=*) case_id=${arg#--case=} ;;
      --source) want=source ;;
      --source=*) source=${arg#--source=} ;;
      --candidate) want=candidate ;;
      --candidate=*) candidate=${arg#--candidate=} ;;
      --path) want=path ;;
      --path=*) path=${arg#--path=} ;;
      --target) want=target ;;
      --target=*) target=${arg#--target=} ;;
      --falsify) want=falsify ;;
      --falsify=*) falsify=${arg#--falsify=} ;;
      --satisfy) want=satisfy ;;
      --satisfy=*) satisfy=${arg#--satisfy=} ;;
      --out) want=out ;;
      --out=*) out=${arg#--out=} ;;
      --declare) want=declare ;;
      --declare=*) declare_text=${arg#--declare=} ;;
      *) cno "unknown argument to prove: $arg" ;;
    esac
    shift
  done
  [ -z "$want" ] || cno "--$want requires a value"

  [ -n "$case_id" ] || cno "prove requires --case"
  [ -n "$source" ] || cno "prove requires --source"
  [ -n "$candidate" ] || cno "prove requires --candidate"
  [ -n "$path" ] || cno "prove requires --path"
  [ -n "$target" ] || cno "prove requires --target"
  [ -n "$falsify" ] || cno "prove requires --falsify"
  [ -n "$satisfy" ] || cno "prove requires --satisfy"
  [ -n "$out" ] || cno "prove requires --out"
  [ "$saw_separator" -eq 1 ] || cno "prove requires -- followed by the probe argv"
  [ "${#argv[@]}" -gt 0 ] || cno "prove requires a probe argv after --"

  case "$case_id" in
    *[!A-Za-z0-9._-]*|''|.*|-*) cno "case identity must be a plain slug: $case_id" ;;
  esac
  case "$path" in
    /*|*/../*|*/..|../*|..) cno "target path must be a plain path inside the tree: $path" ;;
  esac

  command -v git >/dev/null 2>&1 || cno "git is unavailable, so no candidate could be materialized"
  command -v jq >/dev/null 2>&1 || cno "jq is unavailable, so no record could be written"
  command -v python3 >/dev/null 2>&1 || cno "python3 is unavailable, so no substitution could be planned"
  command -v base64 >/dev/null 2>&1 || cno "base64 is unavailable, so the probe argv could not be recorded exactly"
  digest_file /dev/null >/dev/null 2>&1 || cno "no sha256 tool is available, so the target bytes could not be digested"
  [ -x "$SCRIPT_DIR/fm-review-exec.sh" ] || cno "the execution substrate is unavailable: $SCRIPT_DIR/fm-review-exec.sh"
  [ -x "$SCRIPT_DIR/fm-verify.sh" ] || cno "the verification wrapper is unavailable: $SCRIPT_DIR/fm-verify.sh"

  for arg in "$target" "$falsify" "$satisfy"; do
    [ -f "$arg" ] || cno "substitution bytes file is missing: $arg"
  done

  # --- source isolation, BEFORE anything is created --------------------------
  #
  # The source is judged first, and every refusal that concerns it is reached
  # before this process creates a single directory. Claiming the output first
  # would mean a caller who names a primary checkout as the source, with an
  # output path inside it, gets a directory written into the very checkout the
  # next line refuses - the control mutating the artifact it protects, while
  # printing a correct refusal. A refusal that leaves a trace in what it refused
  # is not a refusal.
  [ -d "$source" ] || cno "source is not a directory: $source"
  source=$(cd "$source" && pwd -P) || cno "source cannot be resolved"
  [ "$(git -C "$source" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
    || cno "source is not a git checkout: $source"
  source_root=$(git -C "$source" rev-parse --show-toplevel 2>/dev/null) \
    || cno "source checkout root is unreadable"
  source_root=$(cd "$source_root" && pwd -P) || cno "source checkout root cannot be resolved"
  local git_dir common_dir
  git_dir=$(git -C "$source" rev-parse --absolute-git-dir 2>/dev/null) \
    || cno "source git directory is unreadable"
  common_dir=$(git -C "$source" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || cno "source git common directory is unreadable"
  [ "$git_dir" != "$common_dir" ] \
    || cno "mutation proof refuses a primary checkout as its source: $source"

  guard_output_outside_source "$source_root" "$out"

  # Only now is the record directory claimed, and an occupied one is refused
  # rather than reused.
  if [ -e "$out" ]; then
    [ -d "$out" ] || cno "output path exists and is not a directory: $out"
    [ -z "$(ls -A "$out" 2>/dev/null)" ] || cno "output directory is not empty, and a record is written once: $out"
  fi
  mkdir -p "$out" 2>/dev/null || cno "output directory cannot be created: $out"
  out=$(cd "$out" && pwd -P) || cno "output directory cannot be resolved: $out"
  case "$out" in
    "$source_root"|"$source_root"/*) cno "output directory is inside the source checkout: $out" ;;
  esac

  local candidate_commit candidate_tree
  candidate_commit=$(git -C "$source" rev-parse --verify --quiet "$candidate^{commit}" 2>/dev/null) \
    || cno "candidate does not resolve to a commit in the source: $candidate"
  candidate_tree=$(git -C "$source" rev-parse --verify --quiet "$candidate_commit^{tree}" 2>/dev/null) \
    || cno "candidate commit has no readable tree: $candidate_commit"

  # --- the disposable clone the mutation lives in ----------------------------
  local staging=$out/staging staging_wt=$out/staging-wt work=$out/work
  mkdir -p "$work" 2>/dev/null || cno "working directory cannot be created: $work"
  git clone --quiet --no-local "$source" "$staging" 2>/dev/null \
    || cno "disposable mutation clone failed"
  prove_clone_isolated "$staging" \
    || cno "disposable mutation clone is not isolated from the source"
  [ "$(git -C "$staging" cat-file -t "$candidate_commit" 2>/dev/null)" = commit ] \
    || cno "the candidate is not reachable from any ref in the source, so the disposable clone does not carry it: $candidate_commit"
  [ "$(git -C "$staging" rev-parse --verify --quiet "$candidate_commit^{tree}" 2>/dev/null)" = "$candidate_tree" ] \
    || cno "the disposable clone's candidate tree does not match the source's"

  # --- locate the target -----------------------------------------------------
  local entry target_mode target_type target_blob
  entry=$(git -C "$staging" ls-tree "$candidate_commit" -- "$path" 2>/dev/null) \
    || cno "target path could not be read from the candidate tree: $path"
  [ -n "$entry" ] || cno "target path does not exist in the candidate tree: $path"
  target_mode=$(printf '%s' "$entry" | awk '{print $1}')
  target_type=$(printf '%s' "$entry" | awk '{print $2}')
  target_blob=$(printf '%s' "$entry" | awk '{print $3}')
  [ "$target_type" = blob ] || cno "target path is not a file in the candidate tree: $path"
  case "$target_mode" in
    100644|100755) ;;
    *) cno "target path is not a regular file in the candidate tree: $path mode $target_mode" ;;
  esac

  local original=$work/original.bytes
  git -C "$staging" cat-file blob "$target_blob" >"$original" 2>/dev/null \
    || cno "target file contents could not be read: $path"

  local target_sha256 target_length
  target_sha256=$(digest_file "$target") || cno "target bytes could not be digested"
  target_length=$(wc -c <"$target" 2>/dev/null | tr -d ' ') || cno "target bytes could not be measured"

  cp "$target" "$work/target.bytes" 2>/dev/null || cno "target bytes could not be captured"
  cp "$falsify" "$work/falsify.bytes" 2>/dev/null || cno "falsifying bytes could not be captured"
  cp "$satisfy" "$work/satisfy.bytes" 2>/dev/null || cno "satisfying bytes could not be captured"

  # The two substitutions must differ from each other and from the target, or
  # the two directions are not two experiments.
  cmp -s "$work/falsify.bytes" "$work/satisfy.bytes" \
    && cno "the falsifying and satisfying substitutions are identical, so no direction is tested"
  cmp -s "$work/falsify.bytes" "$work/target.bytes" \
    && cno "the falsifying substitution is the target itself, so nothing is falsified"
  cmp -s "$work/satisfy.bytes" "$work/target.bytes" \
    && cno "the satisfying substitution is the target itself, so nothing is satisfied"

  local plan plan_status occurrences offset
  plan=$(plan_mutations "$original" "$work/target.bytes" "$work/baseline.bytes" \
    "$work/falsify.bytes" "$work/falsified.bytes" \
    "$work/satisfy.bytes" "$work/satisfied.bytes" 2>/dev/null)
  plan_status=$?
  occurrences=$(printf '%s' "$plan" | awk '{print $1}')
  offset=$(printf '%s' "$plan" | awk '{print $2}')
  case "$plan_status" in
    0) ;;
    3) cno "target occurs $occurrences times in $path, and exactly one occurrence is required" ;;
    5) cno "target bytes are empty, so no occurrence could be located" ;;
    *) cno "target occurrences in $path could not be counted" ;;
  esac
  [ "$occurrences" = 1 ] || cno "target occurrence count is not one: $occurrences"

  # --- three commits, three executions ---------------------------------------
  local variant spliced built commit tree
  local baseline_commit='' baseline_tree='' falsified_commit='' falsified_tree=''
  local satisfied_commit='' satisfied_tree=''
  for variant in $VARIANTS; do
    spliced=$work/$variant.bytes
    [ -f "$spliced" ] || cno "spliced $variant file was not produced"
    built=$(build_variant "$staging" "$candidate_tree" "$candidate_commit" \
      "$path" "$target_mode" "$spliced" "$variant") \
      || cno "the $variant commit could not be built"
    commit=$(printf '%s' "$built" | awk '{print $1}')
    tree=$(printf '%s' "$built" | awk '{print $2}')
    [ -n "$commit" ] && [ -n "$tree" ] || cno "the $variant commit could not be built"
    case "$variant" in
      baseline) baseline_commit=$commit; baseline_tree=$tree ;;
      falsified) falsified_commit=$commit; falsified_tree=$tree ;;
      satisfied) satisfied_commit=$commit; satisfied_tree=$tree ;;
    esac
  done

  # The apparatus control and the restoration check, in one object comparison:
  # substituting the target with itself, through the whole splice-blob-tree-
  # commit path, must reproduce the candidate tree byte for byte.
  [ "$baseline_tree" = "$candidate_tree" ] \
    || cno "the identity substitution did not reproduce the candidate tree, so the apparatus is not neutral"
  [ "$falsified_tree" != "$candidate_tree" ] \
    || cno "the falsifying substitution produced no change to the candidate tree"
  [ "$satisfied_tree" != "$candidate_tree" ] \
    || cno "the satisfying substitution produced no change to the candidate tree"
  [ "$falsified_tree" != "$satisfied_tree" ] \
    || cno "the falsifying and satisfying substitutions produced the same tree"

  # A linked worktree, because the execution substrate refuses a primary
  # checkout as its source and a fresh clone is one.
  git -C "$staging" worktree add --quiet --detach "$staging_wt" "$candidate_commit" 2>/dev/null \
    || cno "the disposable clone's linked worktree could not be created"

  local -a results=() reasons=()
  local exec_dir
  for variant in $VARIANTS; do
    case "$variant" in
      baseline) commit=$baseline_commit ;;
      falsified) commit=$falsified_commit ;;
      satisfied) commit=$satisfied_commit ;;
    esac
    exec_dir=$out/exec/$variant
    # The substrate owns this launch entirely; its exit status is ignored here
    # because its record, re-derived below, is the observation.
    "$SCRIPT_DIR/fm-review-exec.sh" launch \
      --attempt "$case_id:$variant" --role mutation-probe \
      --reviewer "$case_id" --effort deterministic \
      --source "$staging_wt" --candidate "$commit" --out "$exec_dir" \
      -- "${argv[@]}" >/dev/null 2>&1
    read_execution "$exec_dir"
    results+=("$EXEC_RESULT")
    reasons+=("$EXEC_REASON")
  done

  local argv_json a
  argv_json=$(
    for a in "${argv[@]}"; do
      printf '%s' "$a" | base64 | tr -d '\n'
      printf '\n'
    done | jq -Rs -c 'rtrimstr("\n") | split("\n") | map(@base64d)'
  ) || cno "probe argv could not be recorded"
  [ -n "$argv_json" ] || cno "probe argv could not be recorded"

  local record=$out/record.json
  jq -n \
    --arg case "$case_id" --arg cc "$candidate_commit" --arg ct "$candidate_tree" \
    --arg path "$path" --arg mode "$target_mode" --arg blob "$target_blob" \
    --arg tsha "$target_sha256" --arg tlen "$target_length" \
    --arg occ "$occurrences" --arg off "$offset" \
    --argjson argv "$argv_json" \
    --arg staging "$staging" --arg wt "$staging_wt" \
    --arg bc "$baseline_commit" --arg bt "$baseline_tree" \
    --arg fc "$falsified_commit" --arg ft "$falsified_tree" \
    --arg sc "$satisfied_commit" --arg st "$satisfied_tree" \
    --arg br "${results[0]}" --arg brr "${reasons[0]}" \
    --arg fr "${results[1]}" --arg frr "${reasons[1]}" \
    --arg sr "${results[2]}" --arg srr "${reasons[2]}" \
    --arg declared "$declare_text" --arg recorded "$(now_utc)" '
    {
      schema: "fm-review-mutation.v1",
      generation: 1,
      recorded_at: $recorded,
      establishes: "the probe verdict is controlled by the named target bytes in both directions, and the verdict the probe reached on the unmutated candidate",
      does_not_establish: "why those bytes control the verdict. Terminal states cannot separate an assertion evaluating these bytes from these bytes being load-bearing for another reason. The satisfying direction is required to shrink that gap and all three exits are recorded here so a reader can judge the residue.",
      declared: { text: $declared, evidential: false,
                  note: "the caller own words, recorded and quarantined. Never read to reach a verdict." },
      dimensions: {
        case_identity:       { observed: true, value: $case },
        candidate_commit:    { observed: true, value: $cc },
        candidate_tree:      { observed: true, value: $ct },
        target_path:         { observed: true, value: $path },
        target_mode:         { observed: true, value: $mode },
        target_blob:         { observed: true, value: $blob },
        target_sha256:       { observed: true, value: $tsha },
        target_length:       { observed: true, value: ($tlen | tonumber) },
        target_occurrences:  { observed: true, value: ($occ | tonumber) },
        target_offset:       { observed: true, value: ($off | tonumber) },
        probe_argv:          { observed: true, value: $argv },
        staging_root:        { observed: true, value: $staging },
        # The property NAMES that were proven, not stored booleans asserting
        # they hold. A stored true would read as the live answer, and the live
        # answer is re-measured against this clone on every result read.
        staging_isolation:   { observed: true, value: { worktree: $wt,
                                 proven: "own_administration no_alternates no_shared_objects" } },
        baseline_commit:     { observed: true, value: $bc },
        baseline_tree:       { observed: true, value: $bt },
        falsified_commit:    { observed: true, value: $fc },
        falsified_tree:      { observed: true, value: $ft },
        satisfied_commit:    { observed: true, value: $sc },
        satisfied_tree:      { observed: true, value: $st },
        baseline_execution:  { observed: true, value: { result: $br, reason: $brr, record: "exec/baseline" } },
        falsified_execution: { observed: true, value: { result: $fr, reason: $frr, record: "exec/falsified" } },
        satisfied_execution: { observed: true, value: { result: $sr, reason: $srr, record: "exec/satisfied" } }
      }
    }' >"$record.tmp" 2>/dev/null || cno "mutation record could not be written"
  mv -f "$record.tmp" "$record" 2>/dev/null || cno "mutation record could not be published"

  emit_result "$out"
}

# --- result ------------------------------------------------------------------

# The outcome is DERIVED here, every time, from the record's dimensions, a fresh
# re-read of each execution, and a fresh re-check of the three mutant trees in
# the object database. Nothing stored in the record decides it.
derive_result() {  # <dir>; sets DERIVED_*
  local dir=$1
  local record=$dir/record.json
  local schema missing staging path
  local cc ct bc bt fc ft sc st
  local n s b
  DERIVED_RESULT=NO_VERIFIER_RAN
  DERIVED_REASON=no_evidence
  DERIVED_BASIS=no_record
  DERIVED_MISSING=

  command -v jq >/dev/null 2>&1 || { DERIVED_REASON=verifier_unavailable; return 0; }
  [ -f "$record" ] || { DERIVED_REASON=empty_result_set; DERIVED_BASIS=no_record; return 0; }
  schema=$(jq -r 'if type == "object" then (.schema // "") else "" end' "$record" 2>/dev/null) \
    || return 0
  [ "$schema" = fm-review-mutation.v1 ] || return 0

  # An unobserved dimension outranks everything below it and is reported by name.
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
      | join(" ")' "$record" 2>/dev/null) || return 0
  if [ -n "$missing" ]; then
    DERIVED_REASON=verification_incomplete
    DERIVED_BASIS=dimensions_unobserved
    DERIVED_MISSING=$missing
    return 0
  fi

  staging=$(jq -r '.dimensions.staging_root.value' "$record" 2>/dev/null)
  path=$(jq -r '.dimensions.target_path.value' "$record" 2>/dev/null)
  cc=$(jq -r '.dimensions.candidate_commit.value' "$record" 2>/dev/null)
  ct=$(jq -r '.dimensions.candidate_tree.value' "$record" 2>/dev/null)
  bc=$(jq -r '.dimensions.baseline_commit.value' "$record" 2>/dev/null)
  bt=$(jq -r '.dimensions.baseline_tree.value' "$record" 2>/dev/null)
  fc=$(jq -r '.dimensions.falsified_commit.value' "$record" 2>/dev/null)
  ft=$(jq -r '.dimensions.falsified_tree.value' "$record" 2>/dev/null)
  sc=$(jq -r '.dimensions.satisfied_commit.value' "$record" 2>/dev/null)
  st=$(jq -r '.dimensions.satisfied_tree.value' "$record" 2>/dev/null)

  # The mutation facts are re-proven against the object database on every read,
  # so a record cannot outlive the commits it names, and a hand-edited record
  # reaches could-not-observe rather than a verdict.
  command -v git >/dev/null 2>&1 || { DERIVED_REASON=verifier_unavailable; return 0; }
  DERIVED_REASON=verification_unreachable
  DERIVED_BASIS=mutation_evidence_unreadable
  [ -d "$staging" ] || return 0
  prove_clone_isolated "$staging" || return 0
  [ "$(git -C "$staging" rev-parse --verify --quiet "$bc^{tree}" 2>/dev/null)" = "$bt" ] || return 0
  [ "$(git -C "$staging" rev-parse --verify --quiet "$fc^{tree}" 2>/dev/null)" = "$ft" ] || return 0
  [ "$(git -C "$staging" rev-parse --verify --quiet "$sc^{tree}" 2>/dev/null)" = "$st" ] || return 0
  [ "$(git -C "$staging" rev-parse --verify --quiet "$cc^{tree}" 2>/dev/null)" = "$ct" ] || return 0
  [ "$bt" = "$ct" ] || return 0
  [ "$ft" != "$ct" ] && [ "$st" != "$ct" ] && [ "$ft" != "$st" ] || return 0
  # Each mutant must differ from the candidate at the named path and nowhere
  # else: a substitution that reached a second file is not the substitution the
  # record describes.
  local changed
  for changed in "$fc" "$sc"; do
    [ "$(git -C "$staging" -c core.quotePath=false diff --name-only "$cc" "$changed" 2>/dev/null)" = "$path" ] \
      || return 0
  done

  validate_mutation_evidence "$staging" "$dir/work" "$record" || return 0

  local argv_json
  argv_json=$(jq -c '.dimensions.probe_argv.value' "$record" 2>/dev/null) || return 0
  [ "$(jq -r '.dimensions.baseline_execution.value.record' "$record" 2>/dev/null)" = exec/baseline ] || return 0
  [ "$(jq -r '.dimensions.falsified_execution.value.record' "$record" 2>/dev/null)" = exec/falsified ] || return 0
  [ "$(jq -r '.dimensions.satisfied_execution.value.record' "$record" 2>/dev/null)" = exec/satisfied ] || return 0
  execution_matches "$dir/exec/baseline" "$bc" "$bt" "$argv_json" || return 0
  execution_matches "$dir/exec/falsified" "$fc" "$ft" "$argv_json" || return 0
  execution_matches "$dir/exec/satisfied" "$sc" "$st" "$argv_json" || return 0

  read_execution "$dir/exec/baseline"; b=$EXEC_RESULT
  read_execution "$dir/exec/falsified"; n=$EXEC_RESULT
  read_execution "$dir/exec/satisfied"; s=$EXEC_RESULT

  fold_case "$n" "$s" "$b"
  DERIVED_RESULT=$FOLD_RESULT
  DERIVED_REASON=$FOLD_REASON
  DERIVED_BASIS=$FOLD_BASIS
  return 0
}

DERIVED_RESULT=
DERIVED_REASON=
DERIVED_BASIS=
DERIVED_MISSING=

emit_result() {  # <dir>
  local dir=$1
  derive_result "$dir"
  printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  %s,%s,%s,%s\n' \
    review-mutation "$DERIVED_RESULT" "$DERIVED_REASON" "$dir/record.json"
  printf 'fm-review-mutation: basis: %s\n' "$DERIVED_BASIS" >&2
  if [ -n "$DERIVED_MISSING" ]; then
    printf 'fm-review-mutation: unobserved dimensions: %s\n' "$DERIVED_MISSING" >&2
  fi
  case "$DERIVED_RESULT" in
    PASS) return 0 ;;
    FAIL) return 1 ;;
    *) return 2 ;;
  esac
}

# --- catalogue ---------------------------------------------------------------

cmd_catalogue() {
  local catalogue='' source='' candidate='' out='' want='' arg source_root
  while [ "$#" -gt 0 ]; do
    arg=$1
    if [ -n "$want" ]; then
      case "$want" in
        catalogue) catalogue=$arg ;;
        source) source=$arg ;;
        candidate) candidate=$arg ;;
        out) out=$arg ;;
      esac
      want=''
      shift
      continue
    fi
    case "$arg" in
      --catalogue) want=catalogue ;;
      --catalogue=*) catalogue=${arg#--catalogue=} ;;
      --source) want=source ;;
      --source=*) source=${arg#--source=} ;;
      --candidate) want=candidate ;;
      --candidate=*) candidate=${arg#--candidate=} ;;
      --out) want=out ;;
      --out=*) out=${arg#--out=} ;;
      *) cno "unknown argument to catalogue: $arg" ;;
    esac
    shift
  done
  [ -z "$want" ] || cno "--$want requires a value"
  [ -n "$catalogue" ] || cno "catalogue requires --catalogue"
  [ -n "$source" ] || cno "catalogue requires --source"
  [ -n "$candidate" ] || cno "catalogue requires --candidate"
  [ -n "$out" ] || cno "catalogue requires --out"
  command -v jq >/dev/null 2>&1 || cno "jq is unavailable, so no catalogue could be read"
  [ -f "$catalogue" ] || cno "catalogue file is missing: $catalogue"

  # The source is judged here too, before anything is created, for the same
  # reason it is in prove: a catalogue naming a primary checkout must not leave
  # a directory inside the checkout it is about to refuse. prove re-checks the
  # source per case; this is the copy that runs before the first mkdir.
  [ -d "$source" ] || cno "source is not a directory: $source"
  source=$(cd "$source" && pwd -P) || cno "source cannot be resolved"
  [ "$(git -C "$source" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
    || cno "source is not a git checkout: $source"
  source_root=$(git -C "$source" rev-parse --show-toplevel 2>/dev/null) \
    || cno "source checkout root is unreadable"
  source_root=$(cd "$source_root" && pwd -P) || cno "source checkout root cannot be resolved"
  local cat_git_dir cat_common_dir
  cat_git_dir=$(git -C "$source" rev-parse --absolute-git-dir 2>/dev/null) \
    || cno "source git directory is unreadable"
  cat_common_dir=$(git -C "$source" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || cno "source git common directory is unreadable"
  [ "$cat_git_dir" != "$cat_common_dir" ] \
    || cno "mutation proof refuses a primary checkout as its source: $source"

  guard_output_outside_source "$source_root" "$out"

  if [ -e "$out" ]; then
    [ -d "$out" ] || cno "output path exists and is not a directory: $out"
    [ -z "$(ls -A "$out" 2>/dev/null)" ] || cno "output directory is not empty, and a catalogue is written once: $out"
  fi
  mkdir -p "$out" 2>/dev/null || cno "output directory cannot be created: $out"
  out=$(cd "$out" && pwd -P) || cno "output directory cannot be resolved: $out"
  case "$out" in
    "$source_root"|"$source_root"/*) cno "output directory is inside the source checkout: $out" ;;
  esac

  local count ids
  count=$(jq -r 'if (type == "object" and (.cases | type) == "array") then (.cases | length) else -1 end' \
    "$catalogue" 2>/dev/null) || cno "catalogue could not be parsed: $catalogue"
  [ "$count" != -1 ] || cno "catalogue has no cases array: $catalogue"
  # An empty catalogue is could-not-observe. Zero findings over an empty
  # universe is not a clean universe.
  [ "$count" -gt 0 ] || cno "catalogue declares no cases, so nothing was observed: $catalogue"
  ids=$(jq -r '[.cases[].case] | length as $n | (unique | length) as $u
               | if $n == $u then "unique" else "duplicate" end' "$catalogue" 2>/dev/null)
  [ "$ids" = unique ] || cno "catalogue declares duplicate case identities, so its fold is ambiguous"

  # Per-case artifacts live under their own directories so a case identity can
  # never collide with this command's own output. A slug is a legal file name,
  # and `catalogue.json` is a legal slug.
  local work=$out/cases result_dir=$out/results i case_id status
  mkdir -p "$work" "$result_dir" 2>/dev/null \
    || cno "case directories cannot be created under: $out"
  local -a rows=()
  i=0
  while [ "$i" -lt "$count" ]; do
    case_id=$(jq -r --argjson i "$i" '.cases[$i].case // ""' "$catalogue" 2>/dev/null)
    [ -n "$case_id" ] || cno "catalogue case $i has no identity"
    case "$case_id" in
      *[!A-Za-z0-9._-]*|.*|-*) cno "catalogue case identity must be a plain slug: $case_id" ;;
    esac
    local case_dir=$work/$case_id bytes=$out/bytes/$case_id
    mkdir -p "$bytes" 2>/dev/null || cno "case bytes directory cannot be created: $bytes"
    jq -j --argjson i "$i" '.cases[$i].target // ""' "$catalogue" >"$bytes/target" 2>/dev/null \
      || cno "case $case_id target bytes could not be extracted"
    jq -j --argjson i "$i" '.cases[$i].falsify // ""' "$catalogue" >"$bytes/falsify" 2>/dev/null \
      || cno "case $case_id falsifying bytes could not be extracted"
    jq -j --argjson i "$i" '.cases[$i].satisfy // ""' "$catalogue" >"$bytes/satisfy" 2>/dev/null \
      || cno "case $case_id satisfying bytes could not be extracted"

    local case_path declared
    case_path=$(jq -r --argjson i "$i" '.cases[$i].path // ""' "$catalogue" 2>/dev/null)
    declared=$(jq -r --argjson i "$i" '.cases[$i].declare // ""' "$catalogue" 2>/dev/null)
    [ -n "$case_path" ] || cno "catalogue case $case_id has no path"

    # NUL-separated, because a command substitution strips trailing newlines and
    # an argv element is allowed to end in one. The argv a catalogue declares has
    # to reach the probe as the argv it declared.
    local -a probe=()
    local line probe_argv=$bytes/probe.argv probe_error=$bytes/probe.error
    if ! python3 -c '
import json
import sys

with open(sys.argv[1], "rb") as handle:
    catalogue = json.load(handle)
probe = catalogue["cases"][int(sys.argv[2])].get("probe", [])
if not isinstance(probe, list):
    raise ValueError("probe is not an array")
for index, argument in enumerate(probe):
    if not isinstance(argument, str):
        raise ValueError(f"probe element {index} is not a string")
    if "\0" in argument:
        raise ValueError(f"probe element {index} contains a NUL byte")
    sys.stdout.write(argument + "\0")
' "$catalogue" "$i" >"$probe_argv" 2>"$probe_error"; then
      line=$(tail -n 1 "$probe_error" 2>/dev/null)
      cno "catalogue case $case_id probe argv could not be decoded: ${line:-decoder failed without an error}"
    fi
    while IFS= read -r -d '' line; do
      probe+=("$line")
    done <"$probe_argv"
    [ "${#probe[@]}" -gt 0 ] || cno "catalogue case $case_id has no probe argv"

    "$SELF" prove --case "$case_id" --source "$source" --candidate "$candidate" \
      --path "$case_path" --target "$bytes/target" --falsify "$bytes/falsify" \
      --satisfy "$bytes/satisfy" --out "$case_dir" --declare "$declared" \
      -- "${probe[@]}" >"$result_dir/$case_id.result" 2>>"$out/catalogue.err"
    status=$?
    local case_result
    case "$status" in
      0) case_result=PASS ;;
      1) case_result=FAIL ;;
      *) case_result=NO_VERIFIER_RAN ;;
    esac
    rows+=("$case_id $case_result")
    i=$((i + 1))
  done

  # Precedence: one FAIL makes the catalogue FAIL, one could-not-observe makes
  # it could-not-observe, and only an all-PASS catalogue passes. An observation
  # gap never masks a finding, and a finding never hides behind a gap.
  local folded=PASS reason=verified row row_result
  for row in "${rows[@]}"; do
    row_result=${row#* }
    case "$row_result" in
      FAIL) folded=FAIL; reason=verifier_reported_failure; break ;;
    esac
  done
  if [ "$folded" != FAIL ]; then
    for row in "${rows[@]}"; do
      row_result=${row#* }
      case "$row_result" in
        NO_VERIFIER_RAN) folded=NO_VERIFIER_RAN; reason=verification_incomplete; break ;;
      esac
    done
  fi

  printf '%s\n' "${rows[@]}" \
    | jq -Rs --arg folded "$folded" --arg reason "$reason" --arg recorded "$(now_utc)" '
      {
        schema: "fm-review-mutation-catalogue.v1",
        recorded_at: $recorded,
        result: $folded,
        reason: $reason,
        cases: (rtrimstr("\n") | split("\n") | map(split(" ") | {case: .[0], result: .[1]}))
      }' >"$out/catalogue.json" 2>/dev/null \
    || cno "catalogue record could not be written"

  printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  %s,%s,%s,%s\n' \
    review-mutation-catalogue "$folded" "$reason" "$out/catalogue.json"
  case "$folded" in
    PASS) return 0 ;;
    FAIL) return 1 ;;
    *) return 2 ;;
  esac
}

cmd_show() {
  local dir=${1:-}
  [ -n "$dir" ] || cno "show requires a record directory"
  [ -f "$dir/record.json" ] || cno "no mutation record in $dir"
  cat "$dir/record.json"
}

cmd_result() {
  local dir=${1:-}
  [ -n "$dir" ] || cno "result requires a record directory"
  emit_result "$dir"
}

case "${1:-}" in
  -h|--help|'') usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
  prove) shift; cmd_prove "$@" ;;
  catalogue) shift; cmd_catalogue "$@" ;;
  show) shift; cmd_show "$@" ;;
  result) shift; cmd_result "$@" ;;
  *) cno "unknown subcommand: $1" ;;
esac
