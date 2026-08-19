#!/usr/bin/env bash
# fm-test-isolation-lib.sh - the one owner of what an isolation measurement IS,
# what an isolation proof RESTS ON, and when that proof has gone stale.
#
# Sourced by bin/fm-test-isolation-proof.sh (which records proofs) and by
# bin/fm-test-run.sh (which consumes them). Not executable on its own.
#
# WHY THIS EXISTS. An isolation proof is a measurement, and a measurement is
# only about the thing that was measured. The archived proof recorded a path and
# a duration and nothing else, so when fourteen of its twenty-four subjects were
# edited over the following three weeks the document kept reading as current:
# no consumer could tell that the bytes it certified were gone. Worse, the set
# it certified was not the set CI actually ran - bin/fm-test-run.sh kept its own
# hand-maintained copy - so the proof had no mandatory consumer at all and could
# not have refused anything even had it noticed.
#
# The repair is not a fresher number. It is a freshness MODEL: bind each proven
# subject to its own bytes and to the named material dependencies its isolation
# claim rests on, and give the artifact a consumer that refuses when any of them
# has moved. Section "MATERIAL DEPENDENCIES" below is that list.
#
# THE LESSON THIS SHARES WITH bin/fm-test-run.sh's serial budget. That budget
# comment records a sibling incident: the serial lane had grown to 2.07x a stale
# declared budget, and the repair was to re-derive the budget from what the suite
# now is rather than restore it to what it used to be. The same rule governs a
# stale isolation proof. When a subject's bytes move, the proof is re-MEASURED
# against the new bytes; it is never relabelled with a new digest over old
# evidence. There is deliberately no refresh-digests path anywhere in this
# module: a subject record can only be produced by fm_isolation_record_subject,
# which digests the bytes that fm_isolation_run_subject just executed.
#
# MATERIAL DEPENDENCIES. An isolation claim for one subject rests on:
#   1. the subject's own bytes            - per-subject sha256, enforced
#   2. its fixture identity               - per-fixture sha256, enforced
#      (the shared tests/ harness files the subject loads at top level)
#   3. runner semantics + sandbox layout  - the contract digest below, enforced
#   4. the concurrency it was proven at   - lane concurrency, enforced
#   5. the shared-state surfaces it touches - recorded evidence; its freshness
#      rides on 1 and 2, because the surfaces are observed from those bytes
#
# WHAT IS DELIBERATELY NOT A DEPENDENCY. Repository state at large. A proof does
# not go stale because some unrelated file moved; only the five items above can
# invalidate it. That is why nothing here digests a whole workflow file or a
# tree hash: the CI lane contributes a NUMBER (its concurrency), not its bytes.
#
# THREE-VALUED THROUGHOUT. Every observation here returns observed-good,
# observed-bad, or could-not-observe. An absent subject, an unreadable proof, an
# unresolvable fixture reference, a missing digest tool, and a workflow with no
# recognisable lane invocation are all could-not-observe, and none of them is a
# pass. Overall precedence, stated once: a definite STALE finding outranks a
# could-not-observe, because "at least one subject definitely moved" is a
# stronger fact than "one component could not be read"; with no stale finding
# and anything unobservable the verdict is COULD-NOT-OBSERVE. Both refuse.
#
# NOT ENROLLED IN bin/fm-dead-predicate-check.sh, stated here so the omission is
# a decision rather than an oversight. That control treats any heredoc in an
# enrolled file as an unparseable construct and returns could-not-observe for
# the whole file; this module embeds several, including the python3 blocks that
# read and write the artifact. Enrolling it would turn a clean repository check
# red without examining a single predicate. Every function below instead has a
# named call site in bin/fm-test-isolation-proof.sh or bin/fm-test-run.sh, and
# tests/fm-test-isolation-proof.test.sh drives each refusal red on purpose.

# ---------------------------------------------------------------------------
# The isolation contract. These variables ARE the contract: fm_isolation_run_subject
# below builds every worker sandbox from them, and fm_isolation_print_contract
# renders exactly the same values. There is no second copy to drift from, which
# is what lets a contract digest mean "the semantics under which this was
# measured" rather than "the bytes of some file that happens to contain them".
# ---------------------------------------------------------------------------

FM_ISOLATION_CONTRACT_VERSION='isolation-contract.v1'

# Mode every worker sandbox root, its private TMPDIR, and its output dir carry.
FM_ISOLATION_SANDBOX_MODE='0700'

# Environment variables pointed at the worker's private temporary root, so
# mktemp and fm_test_tmproot cannot reach a shared location.
FM_ISOLATION_TMPDIR_VARS='TMPDIR TMP'

# Ambient fleet overrides cleared for every worker, so no two subjects can be
# handed the same live firstmate home.
FM_ISOLATION_CLEARED_ENV='FM_BACKEND FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_HOME FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE'

# How global git configuration is treated across the proof run.
FM_ISOLATION_GLOBAL_GIT='snapshot-before-and-after'

# The worktree every subject runs against. Subjects share the repository root as
# their working directory and are expected to write only into their private
# sandbox; they are never given a private checkout.
FM_ISOLATION_WORKTREE='shared-repo-root-cwd'

# Failure handling. A subject that fails under concurrency is a finding, never a
# retry candidate.
FM_ISOLATION_RETRY_POLICY='none'

# Closed vocabulary of shared-state surfaces recorded per subject. Each token
# has exactly one detector in fm_isolation_shared_state_for; adding a token
# without a detector, or a detector without a token, is a defect.
FM_ISOLATION_SHARED_STATE_VOCABULARY='git-global-config home-env literal-tmp network-tool private-tmproot repo-worktree tmux-server'

fm_isolation_print_contract() {
  printf 'contract_version=%s\n' "$FM_ISOLATION_CONTRACT_VERSION"
  printf 'sandbox_mode=%s\n' "$FM_ISOLATION_SANDBOX_MODE"
  printf 'tmpdir_vars=%s\n' "$FM_ISOLATION_TMPDIR_VARS"
  printf 'cleared_env=%s\n' "$FM_ISOLATION_CLEARED_ENV"
  printf 'global_git=%s\n' "$FM_ISOLATION_GLOBAL_GIT"
  printf 'worktree=%s\n' "$FM_ISOLATION_WORKTREE"
  printf 'retry_policy=%s\n' "$FM_ISOLATION_RETRY_POLICY"
  printf 'shared_state_vocabulary=%s\n' "$FM_ISOLATION_SHARED_STATE_VOCABULARY"
}

# ---------------------------------------------------------------------------
# Digests
# ---------------------------------------------------------------------------

fm_isolation_now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

# Prints "sha256:<hex>" for a readable file. Returns 1 and prints nothing when
# the file is unreadable or no digest tool is available: could-not-observe, not
# an empty digest that would silently compare equal to another empty digest.
fm_isolation_digest_file() {
  local path=$1 out=
  [ -f "$path" ] && [ -r "$path" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$path" 2>/dev/null) || return 1
    out=${out%% *}
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$path" 2>/dev/null) || return 1
    out=${out%% *}
  elif command -v python3 >/dev/null 2>&1; then
    out=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$path" 2>/dev/null) || return 1
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf 'sha256:%s\n' "$out"
}

# Digest of the current isolation contract as rendered above.
fm_isolation_contract_digest() {
  local tmp out
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-isolation-contract.XXXXXX") || return 1
  fm_isolation_print_contract >"$tmp" || { rm -f "$tmp"; return 1; }
  out=$(fm_isolation_digest_file "$tmp") || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Fixture identity
# ---------------------------------------------------------------------------

# The shared tests/ harness files a subject loads at top level. Detection is
# pinned to the one idiom this corpus uses:
#     . "$(dirname "${BASH_SOURCE[0]}")/<name>"
# Anything else that sources through BASH_SOURCE is printed as
# "UNRESOLVED\t<line>" so the caller can return could-not-observe rather than
# quietly certifying a fixture set it did not manage to read. Sources that use a
# runtime variable (bin/ libraries loaded through $ROOT inside a case body) are
# the subject exercising its own subject-under-test, not fixture identity, and
# are deliberately out of scope.
fm_isolation_fixtures_for() {
  local root=$1 rel=$2 path line target
  path="$root/$rel"
  [ -f "$path" ] && [ -r "$path" ] || return 1
  while IFS= read -r line; do
    # Only top-level source commands are fixture references. A line that merely
    # mentions BASH_SOURCE - deriving ROOT, for instance - is not one.
    case "$line" in
      [[:space:]]*'. '*|'. '*|[[:space:]]*'source '*|'source '*) ;;
      *) continue ;;
    esac
    case "$line" in
      *'BASH_SOURCE'*) ;;
      *) continue ;;
    esac
    # shellcheck disable=SC2016 # The source idiom is matched literally, not expanded.
    target=$(printf '%s\n' "$line" | sed -n 's|^[[:space:]]*[.][[:space:]]*"\$(dirname "\${BASH_SOURCE\[0\]}")/\([A-Za-z0-9._-]*\)".*$|\1|p')
    if [ -z "$target" ]; then
      # shellcheck disable=SC2016 # The source idiom is matched literally, not expanded.
      target=$(printf '%s\n' "$line" | sed -n 's|^[[:space:]]*source[[:space:]]*"\$(dirname "\${BASH_SOURCE\[0\]}")/\([A-Za-z0-9._-]*\)".*$|\1|p')
    fi
    if [ -n "$target" ]; then
      printf 'tests/%s\n' "$target"
    else
      printf 'UNRESOLVED\t%s\n' "$line"
    fi
  done <"$path" | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# Shared-state surfaces
# ---------------------------------------------------------------------------

# Observed statically from the subject's bytes plus its fixtures' bytes. This is
# a static read, not a syscall trace: it names the shared surfaces the code
# references, and it cannot prove a surface is never reached at runtime. Stated
# so the record cannot be read as stronger evidence than it is.
fm_isolation_shared_state_for() {
  local root=$1
  shift
  local rel path body all=
  for rel in "$@"; do
    path="$root/$rel"
    [ -f "$path" ] && [ -r "$path" ] || return 1
    body=$(cat "$path") || return 1
    all=$all$body$'\n'
  done
  [ -n "$all" ] || return 1

  # ${TMPDIR:-/tmp} is the private-root idiom, not a literal shared /tmp path.
  local stripped
  # shellcheck disable=SC2016 # The private-root idiom is matched literally.
  stripped=$(printf '%s\n' "$all" | sed 's|\${TMPDIR:-/tmp}||g')

  local found=
  case "$all" in *'git config --global'*) found="$found git-global-config" ;; esac
  # shellcheck disable=SC2016 # Detectors match the literal text in the subject's bytes.
  case "$all" in *'$HOME'*|*'${HOME'*) found="$found home-env" ;; esac
  case "$stripped" in *'/tmp/'*|*'"/tmp"'*) found="$found literal-tmp" ;; esac
  # fm-retrieval-audit: not-a-read - a detector naming network tools in the subject's bytes; nothing is read on this line
  case "$all" in *'curl '*|*'wget '*|*'gh api'*|*'gh pr'*) found="$found network-tool" ;; esac
  case "$all" in *'fm_test_tmproot'*|*'mktemp'*) found="$found private-tmproot" ;; esac
  # shellcheck disable=SC2016 # Detectors match the literal text in the subject's bytes.
  case "$all" in *'$ROOT'*|*'${ROOT'*) found="$found repo-worktree" ;; esac
  case "$all" in *'tmux '*|*'tmux-'*) found="$found tmux-server" ;; esac

  printf '%s\n' "$found" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
  printf '\n'
}

# ---------------------------------------------------------------------------
# Lane concurrency
# ---------------------------------------------------------------------------

# The concurrency at which CI actually runs proven-isolated scripts on one
# machine. Read from the workflow rather than declared, so a lane that starts
# running the proven set N-wide is observed instead of assumed. Each parallel
# lane invocation contributes its own --jobs value, or 1 when it passes none.
#
# Prints one "lane=<name> jobs=<n>" line per invocation found. Returns 3 when
# the workflow is missing, unreadable, or contains no recognisable proven-set
# lane invocation: could-not-observe, never a concurrency of zero.
fm_isolation_lane_concurrency() {
  local root=$1 wf="$1/.github/workflows/ci.yml" joined lane jobs line count=0
  [ -f "$wf" ] && [ -r "$wf" ] || return 3
  joined=$(awk '
    {
      line = $0
      while (sub(/\\[[:space:]]*$/, "", line) > 0) {
        if ((getline nxt) <= 0) break
        sub(/^[[:space:]]+/, " ", nxt)
        line = line nxt
      }
      print line
    }
  ' "$wf") || return 3
  while IFS= read -r line; do
    case "$line" in
      *'fm-test-run.sh'*'--lane portable-parallel'*) ;;
      *) continue ;;
    esac
    lane=$(printf '%s\n' "$line" | sed -n 's/.*--lane[[:space:]]\{1,\}\(portable-parallel[A-Za-z0-9-]*\).*/\1/p')
    [ -n "$lane" ] || continue
    jobs=$(printf '%s\n' "$line" | sed -n 's/.*--jobs[[:space:]=]\{1,\}\([0-9]\{1,\}\).*/\1/p')
    [ -n "$jobs" ] || jobs=1
    printf 'lane=%s jobs=%s\n' "$lane" "$jobs"
    count=$((count + 1))
  done <<EOF
$joined
EOF
  [ "$count" -gt 0 ] || return 3
  return 0
}

# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------

fm_isolation_dir_mode() {
  local path=$1
  if stat -f %Lp "$path" >/dev/null 2>&1; then
    stat -f %Lp "$path"
  else
    stat -c %a "$path"
  fi
}

# Builds one worker sandbox from the contract above and runs one subject in it.
# Writes exit, duration_ms, stdout, and stderr under <workroot>/out. Returns 0
# when the subject was measured (whatever its own exit was) and non-zero when
# the sandbox could not be built to contract, because an unmeasured subject must
# never be recorded as a measured one.
#
# This is the only path that runs a subject for proof purposes. Both the proof
# harness and its own regression tests go through it, so a measurement means the
# same thing in both.
fm_isolation_run_subject() {
  local root=$1 workroot=$2 script=$3
  local var mode begin_ms end_ms duration rc

  mkdir -p "$workroot/tmp" "$workroot/out" || return 1
  # Create then chmod: mkdir -m can still be umask-adjusted on some platforms.
  chmod "$FM_ISOLATION_SANDBOX_MODE" "$workroot" "$workroot/tmp" "$workroot/out" || return 1
  for var in "$workroot" "$workroot/tmp" "$workroot/out"; do
    mode=$(fm_isolation_dir_mode "$var") || return 1
    case "$mode" in
      700|0700) ;;
      *) return 1 ;;
    esac
  done

  (
    set +e
    for var in $FM_ISOLATION_TMPDIR_VARS; do
      export "$var=$workroot/tmp"
    done
    # shellcheck disable=SC2086
    unset $FM_ISOLATION_CLEARED_ENV 2>/dev/null || true
    cd "$root" || exit 1
    begin_ms=$(fm_isolation_now_ms)
    bash "$script" >"$workroot/out/stdout" 2>"$workroot/out/stderr"
    rc=$?
    end_ms=$(fm_isolation_now_ms)
    duration=$((end_ms - begin_ms))
    [ "$duration" -ge 0 ] || duration=0
    printf '%s\n' "$rc" >"$workroot/out/exit"
    printf '%s\n' "$duration" >"$workroot/out/duration_ms"
    exit 0
  )
}

# Builds one subject's proof record from the bytes that were just executed.
# Prints a TSV line: path, digest, exit, duration_ms, worker, shared_state,
# fixtures as "path=digest" pairs joined by commas.
#
# The digest is computed here, from the subject on disk, at record time. There
# is no entry point that stamps a digest onto an existing record: re-proving a
# moved subject means running it again through fm_isolation_run_subject.
fm_isolation_record_subject() {
  local root=$1 rel=$2 exit_code=$3 duration=$4 worker=$5
  local digest fixtures fixture fixture_digest shared inputs
  local pairs=''

  digest=$(fm_isolation_digest_file "$root/$rel") || return 1
  fixtures=$(fm_isolation_fixtures_for "$root" "$rel") || return 1
  case "$fixtures" in
    *UNRESOLVED*) return 1 ;;
  esac

  inputs="$rel"
  while IFS= read -r fixture; do
    [ -n "$fixture" ] || continue
    fixture_digest=$(fm_isolation_digest_file "$root/$fixture") || return 1
    if [ -n "$pairs" ]; then
      pairs="$pairs,$fixture=$fixture_digest"
    else
      pairs="$fixture=$fixture_digest"
    fi
    inputs="$inputs $fixture"
  done <<EOF
$fixtures
EOF

  # shellcheck disable=SC2086
  shared=$(fm_isolation_shared_state_for "$root" $inputs) || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$rel" "$digest" "$exit_code" "$duration" "$worker" "$shared" "$pairs"
}

# ---------------------------------------------------------------------------
# Reading a recorded proof
# ---------------------------------------------------------------------------

# Normalises a proof artifact into TSV on stdout:
#   meta<TAB><schema_version><TAB><concurrency><TAB><contract_digest>
#   subject<TAB><path><TAB><digest><TAB><exit><TAB><fixture pairs>
# Returns 3 when the artifact is missing, unreadable, not JSON, not an isolation
# proof, or written to a schema without freshness bindings, and 4 when python3
# is unavailable. Both are could-not-observe; neither is an empty proof.
fm_isolation_proof_read() {
  local proof=$1
  [ -f "$proof" ] && [ -r "$proof" ] || return 3
  command -v python3 >/dev/null 2>&1 || return 4
  python3 - "$proof" <<'PY' || return 3
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict) or doc.get("kind") != "isolation-proof":
    sys.exit(1)
if doc.get("schema_version") != 2:
    sys.exit(1)
contract = doc.get("isolation_contract")
if not isinstance(contract, dict) or not contract.get("digest"):
    sys.exit(1)
scripts = doc.get("scripts")
if not isinstance(scripts, list) or not scripts:
    sys.exit(1)
out = ["meta\t%s\t%s\t%s" % (doc["schema_version"], doc.get("concurrency"), contract["digest"])]
for s in scripts:
    if not isinstance(s, dict):
        sys.exit(1)
    for key in ("path", "digest", "exit"):
        if key not in s:
            sys.exit(1)
    fixtures = s.get("fixtures", [])
    if not isinstance(fixtures, list):
        sys.exit(1)
    pairs = []
    for f in fixtures:
        if not isinstance(f, dict) or "path" not in f or "digest" not in f:
            sys.exit(1)
        pairs.append("%s=%s" % (f["path"], f["digest"]))
    out.append("subject\t%s\t%s\t%s\t%s" % (s["path"], s["digest"], s["exit"], ",".join(pairs)))
sys.stdout.write("\n".join(out) + "\n")
PY
}

# The proven-isolated set: every subject a recorded proof observed passing under
# concurrency. This is the artifact's authority over lane membership; the paths
# are not maintained anywhere else.
fm_isolation_proven_paths() {
  local proof=$1 tsv rc
  tsv=$(fm_isolation_proof_read "$proof")
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$tsv" | awk -F'\t' '$1 == "subject" && $4 == "0" { print $2 }' | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# Freshness
# ---------------------------------------------------------------------------

# Answers one question: is this recorded proof still about the code that is here
# now? Prints one FM_ISOLATION_SUBJECT line per proven subject, one
# FM_ISOLATION_DEPENDENCY line per proof-wide dependency, and one closing
# FM_ISOLATION_FRESHNESS summary.
#
#   0  PROVEN            every subject's bytes, every fixture, the contract, and
#                        the configured concurrency all match the proof
#   1  STALE             at least one of them definitely moved
#   3  COULD-NOT-OBSERVE nothing was found stale, but some component could not
#                        be read, so "still current" cannot be asserted
fm_isolation_check_freshness() {
  local root=$1 proof=$2 runner_jobs_max=$3
  local tsv rc line kind path recorded_digest exit_code pairs
  local current_digest fixture_pair fixture_path fixture_digest fixture_current
  local recorded_concurrency recorded_contract current_contract
  local subjects=0 proven_count=0 stale=0 unobservable=0 dep_stale=0 dep_unobservable=0
  local subject_state subject_reason lanes lane_line lane_name lane_jobs observed_max

  tsv=$(fm_isolation_proof_read "$proof")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      4) subject_reason=python3-unavailable ;;
      *) subject_reason='proof-unreadable-or-unbound' ;;
    esac
    printf 'FM_ISOLATION_DEPENDENCY COULD-NOT-OBSERVE name=proof-artifact reason=%s path=%s\n' \
      "$subject_reason" "$proof"
    printf 'FM_ISOLATION_FRESHNESS COULD-NOT-OBSERVE subjects=0 proven=0 stale=0 unobservable=0 dependencies_stale=0 dependencies_unobservable=1\n'
    return 3
  fi

  recorded_concurrency=$(printf '%s\n' "$tsv" | awk -F'\t' '$1 == "meta" { print $3; exit }')
  recorded_contract=$(printf '%s\n' "$tsv" | awk -F'\t' '$1 == "meta" { print $4; exit }')

  # Dependency: runner semantics and sandbox layout.
  if current_contract=$(fm_isolation_contract_digest); then
    if [ "$current_contract" = "$recorded_contract" ]; then
      printf 'FM_ISOLATION_DEPENDENCY PROVEN name=isolation-contract digest=%s\n' "$current_contract"
    else
      dep_stale=$((dep_stale + 1))
      printf 'FM_ISOLATION_DEPENDENCY STALE name=isolation-contract reason=contract-changed proven=%s current=%s\n' \
        "$recorded_contract" "$current_contract"
    fi
  else
    dep_unobservable=$((dep_unobservable + 1))
    printf 'FM_ISOLATION_DEPENDENCY COULD-NOT-OBSERVE name=isolation-contract reason=digest-tool-unavailable\n'
  fi

  # Dependency: the concurrency proven-isolated scripts are actually run at.
  observed_max=$runner_jobs_max
  printf 'FM_ISOLATION_DEPENDENCY OBSERVED name=runner-jobs-cap jobs=%s\n' "$runner_jobs_max"
  if lanes=$(fm_isolation_lane_concurrency "$root"); then
    while IFS= read -r lane_line; do
      [ -n "$lane_line" ] || continue
      lane_name=${lane_line%% *}
      lane_name=${lane_name#lane=}
      lane_jobs=${lane_line##*jobs=}
      printf 'FM_ISOLATION_DEPENDENCY OBSERVED name=lane-concurrency lane=%s jobs=%s\n' \
        "$lane_name" "$lane_jobs"
      [ "$lane_jobs" -le "$observed_max" ] || observed_max=$lane_jobs
    done <<EOF
$lanes
EOF
    if [ "$observed_max" -le "$recorded_concurrency" ]; then
      printf 'FM_ISOLATION_DEPENDENCY PROVEN name=concurrency observed_max=%s proven=%s\n' \
        "$observed_max" "$recorded_concurrency"
    else
      dep_stale=$((dep_stale + 1))
      printf 'FM_ISOLATION_DEPENDENCY STALE name=concurrency reason=exceeds-proof observed_max=%s proven=%s\n' \
        "$observed_max" "$recorded_concurrency"
    fi
  else
    dep_unobservable=$((dep_unobservable + 1))
    printf 'FM_ISOLATION_DEPENDENCY COULD-NOT-OBSERVE name=concurrency reason=no-parallel-lane-invocation-found\n'
  fi

  # Per subject: its own bytes, then its fixture identity.
  while IFS= read -r line; do
    kind=${line%%	*}
    [ "$kind" = "subject" ] || continue
    path=$(printf '%s\n' "$line" | awk -F'\t' '{ print $2 }')
    recorded_digest=$(printf '%s\n' "$line" | awk -F'\t' '{ print $3 }')
    exit_code=$(printf '%s\n' "$line" | awk -F'\t' '{ print $4 }')
    pairs=$(printf '%s\n' "$line" | awk -F'\t' '{ print $5 }')
    [ "$exit_code" = "0" ] || continue
    subjects=$((subjects + 1))
    subject_state=PROVEN
    subject_reason=

    if current_digest=$(fm_isolation_digest_file "$root/$path"); then
      if [ "$current_digest" != "$recorded_digest" ]; then
        subject_state=STALE
        subject_reason=subject-bytes-changed
      fi
    else
      subject_state=COULD-NOT-OBSERVE
      subject_reason=subject-unreadable
    fi

    if [ "$subject_state" = "PROVEN" ] && [ -n "$pairs" ]; then
      while IFS= read -r fixture_pair; do
        [ -n "$fixture_pair" ] || continue
        fixture_path=${fixture_pair%%=*}
        fixture_digest=${fixture_pair#*=}
        if fixture_current=$(fm_isolation_digest_file "$root/$fixture_path"); then
          if [ "$fixture_current" != "$fixture_digest" ]; then
            subject_state=STALE
            subject_reason="fixture-bytes-changed:$fixture_path"
            break
          fi
        else
          subject_state=COULD-NOT-OBSERVE
          subject_reason="fixture-unreadable:$fixture_path"
          break
        fi
      done <<EOF
$(printf '%s\n' "$pairs" | tr ',' '\n')
EOF
    fi

    case "$subject_state" in
      PROVEN)
        proven_count=$((proven_count + 1))
        printf 'FM_ISOLATION_SUBJECT PROVEN path=%s\n' "$path"
        ;;
      STALE)
        stale=$((stale + 1))
        printf 'FM_ISOLATION_SUBJECT STALE path=%s reason=%s\n' "$path" "$subject_reason"
        ;;
      *)
        unobservable=$((unobservable + 1))
        printf 'FM_ISOLATION_SUBJECT COULD-NOT-OBSERVE path=%s reason=%s\n' "$path" "$subject_reason"
        ;;
    esac
  done <<EOF
$tsv
EOF

  # Precedence is stated in this file's header: a definite STALE anywhere
  # outranks a could-not-observe, and both refuse. Subject and dependency counts
  # stay separate so neither can be read as the other.
  if [ "$stale" -gt 0 ] || [ "$dep_stale" -gt 0 ]; then
    printf 'FM_ISOLATION_FRESHNESS STALE subjects=%s proven=%s stale=%s unobservable=%s dependencies_stale=%s dependencies_unobservable=%s\n' \
      "$subjects" "$proven_count" "$stale" "$unobservable" "$dep_stale" "$dep_unobservable"
    return 1
  fi
  if [ "$unobservable" -gt 0 ] || [ "$dep_unobservable" -gt 0 ]; then
    printf 'FM_ISOLATION_FRESHNESS COULD-NOT-OBSERVE subjects=%s proven=%s stale=%s unobservable=%s dependencies_stale=%s dependencies_unobservable=%s\n' \
      "$subjects" "$proven_count" "$stale" "$unobservable" "$dep_stale" "$dep_unobservable"
    return 3
  fi
  printf 'FM_ISOLATION_FRESHNESS PROVEN subjects=%s proven=%s stale=%s unobservable=%s dependencies_stale=%s dependencies_unobservable=%s\n' \
    "$subjects" "$proven_count" "$stale" "$unobservable" "$dep_stale" "$dep_unobservable"
  return 0
}

# ---------------------------------------------------------------------------
# Writing a proof
# ---------------------------------------------------------------------------

# The one writer of the proof artifact, so its schema has a single owner that
# both the harness and this module's own regression tests go through. Records
# arrive as the TSV that fm_isolation_record_subject produces, which is the only
# thing that produces them.
fm_isolation_write_proof() {
  local out=$1 started=$2 finished=$3 run_id=$4 total=$5 failed=$6 concurrency=$7 duration=$8 records=$9
  local contract_digest=${10} lanes=${11} runner_jobs_max=${12}
  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$concurrency" "$duration" "$records" \
    "$contract_digest" "$lanes" "$runner_jobs_max" <<'PY'
import json, sys
(out, started, finished, run_id, total, failed, concurrency, duration, records_path,
 contract_digest, lanes_path, runner_jobs_max) = sys.argv[1:13]
scripts = []
with open(records_path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, digest, exit_s, dur_s, worker, shared, pairs = line.split("\t")
        fixtures = []
        for pair in [p for p in pairs.split(",") if p]:
            fixture_path, _, fixture_digest = pair.partition("=")
            fixtures.append({"path": fixture_path, "digest": fixture_digest})
        fixtures.sort(key=lambda f: f["path"])
        scripts.append({
            "path": path,
            "digest": digest,
            "exit": int(exit_s),
            "duration_ms": int(dur_s),
            "worker": int(worker),
            "fixtures": fixtures,
            "shared_state": sorted(t for t in shared.split(" ") if t),
        })
scripts.sort(key=lambda s: s["path"])
lanes = []
try:
    with open(lanes_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            name, _, jobs = line.partition(" ")
            lanes.append({"lane": name.split("=", 1)[1], "jobs": int(jobs.split("=", 1)[1])})
except OSError:
    lanes = []
lane_observation = "observed" if lanes else "could-not-observe"
observed_max = max([int(runner_jobs_max)] + [l["jobs"] for l in lanes])
doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "kind": "isolation-proof",
    "schema_version": 2,
    "concurrency": int(concurrency),
    "isolation_contract": {"digest": contract_digest},
    "lane_concurrency": {
        "observation": lane_observation,
        "lanes": lanes,
        "runner_jobs_max": int(runner_jobs_max),
        "observed_max": observed_max,
    },
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "production_sharding_enabled": False,
    "fm_test_run_jobs_enabled": False,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}
