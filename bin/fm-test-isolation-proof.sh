#!/usr/bin/env bash
# fm-test-isolation-proof.sh - bounded concurrent isolation proof for portable
# behavior-test candidates (Phase 2 pre-shard gate).
#
# This is the single owner of the parallel CANDIDATE set, the concurrent proof
# run, and the isolation checks that admit a candidate. The PROVEN set - the
# subjects a run actually observed passing, and the only set production lanes
# consume - is owned by the artifact this writes, docs/fm-test-isolation-proof.json.
# Candidates are the input to a proof run and the proven set is its output; the
# coverage guard refuses when the two disagree. Production portable CI shards
# and bounded local fm-test-run.sh --jobs over the proven set are owned by
# bin/fm-test-run.sh (docs/fm-test-portable-shards.md).
#
# It does NOT:
#   - compose production CI shard membership (fm-test-run.sh owns that partition)
#   - run real Herdr, real default-server tmux, watcher lock races, AFK, live
#     harnesses, or GUI backends
#
# Usage:
#   fm-test-isolation-proof.sh [--jobs N] [--json path] [--list]
#   fm-test-isolation-proof.sh --list-exclusions
#   fm-test-isolation-proof.sh --list-proven [--proof path]
#   fm-test-isolation-proof.sh --print-contract
#   fm-test-isolation-proof.sh --check-freshness [--proof path] [--root dir]
#                                                [--runner-jobs-max N]
#   fm-test-isolation-proof.sh -h | --help
#
# Options:
#   --jobs N     max concurrent workers (default: 4; min 1)
#   --json path  write a machine-readable proof artifact after the run
#   --list       print the candidate paths this harness would measure, and exit 0
#   --list-proven
#                print the paths a recorded proof actually observed passing, and
#                exit 0. This is the set production lanes consume; --list is the
#                input to a proof run, --list-proven is its output.
#   --print-contract
#                print the isolation contract every worker sandbox is built from
#   --check-freshness
#                judge a recorded proof against the code that is here now, and
#                exit 0 proven / 1 stale / 3 could-not-observe
#   --proof path proof artifact to read (default: docs/fm-test-isolation-proof.json)
#   --root dir   repository root the proof is judged against (default: this one)
#   --runner-jobs-max N
#                concurrency cap the runner declares for the proven set
#                (default: bin/fm-test-run.sh --print-jobs-max, its owner)
#   --list-exclusions
#                print basename + reason for scripts deliberately kept serial
#                relative to the scout-proposed parallel pool, then exit 0
#   -h, --help   print this header
#
# The isolation contract each concurrent worker is built from - sandbox mode,
# private TMPDIR, cleared ambient overrides, global-git treatment, worktree, and
# retry policy - is owned by bin/fm-test-isolation-lib.sh and printed verbatim by
# --print-contract. That library also owns the freshness model: what a recorded
# proof binds to, and when it has gone stale. Read its header before changing
# what a proof means.
#
# Markers (stdout):
#   FM_ISOLATION_BEGIN <iso8601> concurrency=<n> candidates=<n>
#   FM_ISOLATION_CANDIDATE_BEGIN <iso8601> <script> worker=<i>
#   FM_ISOLATION_CANDIDATE_END <iso8601> <script> exit=<code> duration_ms=<n> worker=<i>
#   FM_ISOLATION_SUMMARY total=<n> failed=<n> concurrency=<n> duration_ms=<n>
#   FM_ISOLATION_ARTIFACT WRITTEN path=<p> subjects=<n> candidates=<n>
#   FM_ISOLATION_ARTIFACT WITHHELD path=<p> reason=<r> candidates=<n> failed=<n>
#   FM_ISOLATION_SEAM PROVEN|REFUSED|COULD-NOT-OBSERVE|NOT-APPLICABLE ...
#
# --json writes the artifact only from a run that observed EVERY candidate good.
# A run with a failed or unmeasured subject withholds it and says so, leaving the
# previous genuine artifact byte-identical: a proof recording a subset of the
# candidate universe would become the acceptance evidence that same subset is
# measured against. See the "Well-founded artifact generation" block below for
# the ordering and the incident it repairs.
#
# Exit status is the aggregate of candidate exits: non-zero if any candidate
# fails, if isolation checks fail, if the candidate set is empty, if the artifact
# was withheld, or if the canonical coverage seam refuses the artifact just
# written. A script that fails only under concurrency must be removed from the
# candidate set and investigated; this harness never retries a failure into green.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=bin/fm-test-isolation-lib.sh
. "$ROOT/bin/fm-test-isolation-lib.sh"

JOBS=4
JSON_PATH=
LIST_ONLY=0
LIST_EXCLUSIONS=0
LIST_PROVEN=0
PRINT_CONTRACT=0
CHECK_FRESHNESS=0
PROOF_PATH=
CHECK_ROOT=
RUNNER_JOBS_MAX=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-isolation-proof: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-isolation-proof: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    echo $(($(date +%s) * 1000))
  fi
}

# Serial exclusions relative to the scout-proposed parallel pool (pure units,
# fake backends, private git fixtures, stubbed network). Reasons are audit
# evidence; do not re-add a basename without clearing its reason.
exclusion_reason() {
  case "$1" in
    fm-test-isolation-proof.test.sh)
      printf '%s\n' 'isolation-proof harness contract itself; must not re-enter concurrent matrix'
      ;;
    fm-backend-tmux-smoke.test.sh)
      printf '%s\n' 'real tmux on a private socket; keep exclusive of default-server contention class'
      ;;
    fm-backend.test.sh)
      printf '%s\n' 'old-vs-new main checkout diff fixture; gray-zone concurrent git/worktree cost'
      ;;
    fm-spawn-dispatch-profile.test.sh|fm-spawn-worktree-settle.test.sh|fm-trace-context-spawn.test.sh)
      printf '%s\n' 'real isolated git worktrees plus spawn settle loops; gray zone until dedicated proof'
      ;;
    fm-pr-check-security.test.sh)
      printf '%s\n' 'watcher lock / migration / poll security surface; intentional shared-lock class'
      ;;
    fm-teardown.test.sh)
      printf '%s\n' 'landed-work + lock-race teardown matrix; keep serial with forge/git stress peers'
      ;;
    fm-herdr-session-cleanup.test.sh)
      printf '%s\n' 'session-start task/presentation lock matrix; keep serial until dedicated concurrent proof'
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-queue.test.sh|fm-watch-checkpoint.test.sh|fm-watch-triage.test.sh|\
    fm-watcher-lock.test.sh)
      printf '%s\n' 'watcher/wake/lock family; intentional process locks and daemon races'
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh|fm-afk-inject-herdr-e2e.test.sh|\
    fm-afk-launch.test.sh)
      printf '%s\n' 'AFK lifecycle / inject path; exclusive daemon and pane control'
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-primary-live-e2e.test.sh|\
    fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh)
      printf '%s\n' 'live harness opt-in; never default parallel CI'
      ;;
    fm-backend-autodetect-smoke.test.sh|fm-backend-herdr-eventwait-smoke.test.sh|\
    fm-backend-herdr-presentation-e2e.test.sh|fm-backend-herdr-prune-safety-e2e.test.sh|\
    fm-backend-herdr-respawn-idem-e2e.test.sh|fm-backend-herdr-smoke.test.sh|\
    fm-backend-herdr-workspace-per-home-e2e.test.sh|fm-herdr-session-cleanup-e2e.test.sh)
      printf '%s\n' 'real Herdr-gated; Herdr lane is a later phase'
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      printf '%s\n' 'cmux GUI backend; never parallel with another cmux mutator'
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' 'zellij optional backend; keep out of pure parallel pool'
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' 'orca backend surface; keep serial until dedicated isolation proof'
      ;;
    *)
      return 1
      ;;
  esac
}

# Exact candidate set from the archived concurrent proof. Adding or removing a
# path requires a new audit and proof archive.
list_parallel_candidates() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

list_exclusions_for_report() {
  local base reason
  # Stable report of known serial reasons for the scout-proposed pool classes.
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if reason=$(exclusion_reason "$base"); then
      printf '%s\t%s\n' "$base" "$reason"
    fi
  done <<'EOF'
fm-test-isolation-proof.test.sh
fm-backend-tmux-smoke.test.sh
fm-backend.test.sh
fm-spawn-dispatch-profile.test.sh
fm-spawn-worktree-settle.test.sh
fm-trace-context-spawn.test.sh
fm-pr-check-security.test.sh
fm-teardown.test.sh
fm-watcher-lock.test.sh
fm-wake-queue.test.sh
fm-afk-inject-e2e.test.sh
fm-backend-herdr-smoke.test.sh
fm-backend-cmux-smoke.test.sh
fm-pi-primary-live-e2e.test.sh
fm-quota-array-dispatch-live-e2e.test.sh
EOF
}

global_git_snapshot() {
  # Empty string when no global config is present or git cannot read it.
  git config --global --list 2>/dev/null | LC_ALL=C sort || true
}


while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-exclusions)
      LIST_EXCLUSIONS=1
      shift
      ;;
    --list-proven)
      LIST_PROVEN=1
      shift
      ;;
    --print-contract)
      PRINT_CONTRACT=1
      shift
      ;;
    --check-freshness)
      CHECK_FRESHNESS=1
      shift
      ;;
    --proof)
      [ "$#" -gt 1 ] || die "--proof requires a path"
      PROOF_PATH=$2
      shift 2
      ;;
    --proof=*)
      PROOF_PATH=${1#--proof=}
      shift
      ;;
    --root)
      [ "$#" -gt 1 ] || die "--root requires a directory"
      CHECK_ROOT=$2
      shift 2
      ;;
    --root=*)
      CHECK_ROOT=${1#--root=}
      shift
      ;;
    --runner-jobs-max)
      [ "$#" -gt 1 ] || die "--runner-jobs-max requires a positive integer"
      RUNNER_JOBS_MAX=$2
      shift 2
      ;;
    --runner-jobs-max=*)
      RUNNER_JOBS_MAX=${1#--runner-jobs-max=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1 (this harness owns its candidate set)"
      ;;
  esac
done

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"

if [ "$PRINT_CONTRACT" -eq 1 ]; then
  fm_isolation_print_contract
  exit 0
fi

if [ "$LIST_EXCLUSIONS" -eq 1 ]; then
  list_exclusions_for_report
  exit 0
fi

# Where a recorded proof lives, and the root it is judged against. Both default
# to this repository, so the ordinary invocation needs no arguments.
CHECK_ROOT=${CHECK_ROOT:-$ROOT}
PROOF_PATH=${PROOF_PATH:-$CHECK_ROOT/docs/fm-test-isolation-proof.json}

if [ "$LIST_PROVEN" -eq 1 ]; then
  set +e
  proven_out=$(fm_isolation_proven_paths "$PROOF_PATH")
  proven_rc=$?
  set -e
  if [ "$proven_rc" -ne 0 ]; then
    log "could not read the proven set from $PROOF_PATH (could-not-observe, not an empty set)"
    exit 3
  fi
  printf '%s\n' "$proven_out"
  exit 0
fi

if [ "$CHECK_FRESHNESS" -eq 1 ]; then
  if [ -z "$RUNNER_JOBS_MAX" ]; then
    # bin/fm-test-run.sh owns its own cap; read it through its public interface
    # rather than restating the number here.
    RUNNER_JOBS_MAX=$("$ROOT/bin/fm-test-run.sh" --print-jobs-max 2>/dev/null || echo)
  fi
  case "$RUNNER_JOBS_MAX" in
    ''|*[!0-9]*)
      printf 'FM_ISOLATION_FRESHNESS COULD-NOT-OBSERVE subjects=0 proven=0 stale=0 unobservable=0 dependencies_stale=0 dependencies_unobservable=1\n'
      log "could not read the runner concurrency cap; pass --runner-jobs-max N"
      exit 3
      ;;
  esac
  set +e
  fm_isolation_check_freshness "$CHECK_ROOT" "$PROOF_PATH" "$RUNNER_JOBS_MAX"
  freshness_rc=$?
  set -e
  exit "$freshness_rc"
fi

CANDIDATES=()
while IFS= read -r s; do
  [ -n "$s" ] || continue
  CANDIDATES+=("$s")
done < <(list_parallel_candidates | LC_ALL=C sort -u)

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${CANDIDATES[@]+"${CANDIDATES[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

[ "${#CANDIDATES[@]}" -gt 0 ] || die "candidate set is empty; refusing isolation proof"

for s in "${CANDIDATES[@]}"; do
  [ -f "$s" ] || die "candidate not found: $s"
done

PROOF_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-isolation-proof.XXXXXX")
chmod 0700 "$PROOF_ROOT" || die "could not chmod 0700 proof root $PROOF_ROOT"
RECORDS="$PROOF_ROOT/records.tsv"
: >"$RECORDS"
trap 'rm -rf "$PROOF_ROOT"' EXIT

GIT_BEFORE=$(global_git_snapshot)
RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="fm-isolation-${RUN_STARTED_MS}-$$"
TOTAL=${#CANDIDATES[@]}
FAILED=0
AGG_RC=0

printf 'FM_ISOLATION_BEGIN %s concurrency=%s candidates=%s\n' \
  "$RUN_STARTED_ISO" "$JOBS" "$TOTAL"

# Worker state arrays parallel to CANDIDATES indices (1-based worker labels).
declare -a WORKER_PIDS=()
declare -a WORKER_IDX=()

wait_one_slot() {
  local pid idx work rc duration script mode record
  # Wait for the oldest launched worker still recorded.
  pid=${WORKER_PIDS[0]}
  idx=${WORKER_IDX[0]}
  WORKER_PIDS=("${WORKER_PIDS[@]:1}")
  WORKER_IDX=("${WORKER_IDX[@]:1}")
  set +e
  wait "$pid"
  set -e
  work="$PROOF_ROOT/w$idx"
  script=${CANDIDATES[$((idx - 1))]}
  # An absent exit file means the sandbox could not be built to contract, so the
  # subject was never measured. That is could-not-observe, and exit -1 keeps it
  # out of the proven set instead of letting it read as an ordinary failure.
  if [ -f "$work/out/exit" ]; then
    rc=$(cat "$work/out/exit")
    duration=$(cat "$work/out/duration_ms" 2>/dev/null || echo 0)
    # A present but non-numeric exit record is could-not-observe, the same as an
    # absent one: exit -1 keeps the subject out of the proven set instead of
    # letting it slip past both the proven and the failed counters.
    case "${rc#-}" in
      ''|*[!0-9]*)
        log "could not measure (unreadable exit record): $script"
        rc=-1
        ;;
    esac
    case "$duration" in
      ''|*[!0-9]*) duration=0 ;;
    esac
  else
    rc=-1
    duration=0
    log "could not measure (sandbox not built to contract): $script"
  fi
  # The binding is built here, from the bytes that were just executed, by the
  # library's one recorder. A subject whose binding cannot be built is recorded
  # unmeasured rather than proven on evidence its dependencies were not read.
  if [ "$rc" -eq 0 ]; then
    if record=$(fm_isolation_record_subject "$ROOT" "$script" "$rc" "$duration" "$idx"); then
      printf '%s\n' "$record" >>"$RECORDS"
    else
      log "could not bind proof dependencies (unresolved fixture or no digest tool): $script"
      rc=-1
      printf '%s\t\t-1\t%s\t%s\t\t\n' "$script" "$duration" "$idx" >>"$RECORDS"
    fi
  else
    printf '%s\t\t%s\t%s\t%s\t\t\n' "$script" "$rc" "$duration" "$idx" >>"$RECORDS"
  fi
  printf 'FM_ISOLATION_CANDIDATE_END %s %s exit=%s duration_ms=%s worker=%s\n' \
    "$(now_iso)" "$script" "$rc" "$duration" "$idx"
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    AGG_RC=1
    log "candidate failed: $script exit=$rc"
    if [ -s "$work/out/stdout" ]; then
      log "--- stdout ($script) ---"
      tail -n 40 "$work/out/stdout" >&2 || true
    fi
    if [ -s "$work/out/stderr" ]; then
      log "--- stderr ($script) ---"
      tail -n 40 "$work/out/stderr" >&2 || true
    fi
  fi
  # Isolation: worker root must remain mode 0700 and under the proof parent.
  mode=$(fm_isolation_dir_mode "$work")
  case "$mode" in
    700|0700) ;;
    *)
      log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
      AGG_RC=1
      FAILED=$((FAILED + 1))
      ;;
  esac
  case "$work" in
    "$PROOF_ROOT"/*) ;;
    *)
      log "isolation failure: worker root escaped proof parent: $work"
      AGG_RC=1
      ;;
  esac
}

idx=0
for script in "${CANDIDATES[@]}"; do
  idx=$((idx + 1))
  work="$PROOF_ROOT/w$idx"

  printf 'FM_ISOLATION_CANDIDATE_BEGIN %s %s worker=%s\n' \
    "$(now_iso)" "$script" "$idx"

  # One measurement path, owned by bin/fm-test-isolation-lib.sh and shared with
  # this harness's own regression tests, so a proof run and a re-measurement
  # mean the same thing. It builds the sandbox from the contract and refuses to
  # run a subject it could not build one for.
  ( fm_isolation_run_subject "$ROOT" "$work" "$script" || exit 1 ) &
  WORKER_PIDS+=("$!")
  WORKER_IDX+=("$idx")

  # Bound concurrency.
  while [ "${#WORKER_PIDS[@]}" -ge "$JOBS" ]; do
    wait_one_slot
  done
done

while [ "${#WORKER_PIDS[@]}" -gt 0 ]; do
  wait_one_slot
done

GIT_AFTER=$(global_git_snapshot)
if [ "$GIT_BEFORE" != "$GIT_AFTER" ]; then
  log "isolation failure: git config --global changed during the concurrent proof"
  log "--- before ---"
  printf '%s\n' "$GIT_BEFORE" >&2
  log "--- after ---"
  printf '%s\n' "$GIT_AFTER" >&2
  AGG_RC=1
  FAILED=$((FAILED + 1))
fi

# Cross-process artifact check: no candidate may leave debris outside the
# proof-owned TMPDIR tree. Workers only receive TMPDIR under PROOF_ROOT, so any
# residual path under PROOF_ROOT is expected and cleaned by trap. Refuse if a
# worker wrote a fixed global path we know about from audit (none remain after
# the arm-pretool stderr path uses TMPDIR).
if find "$PROOF_ROOT" -type f -name 'fm-arm-pretool-check-claude-stderr.*' 2>/dev/null | grep -q .; then
  : # allowed only under proof roots; nothing to do
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_ISOLATION_SUMMARY total=%s failed=%s concurrency=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$JOBS" "$RUN_DURATION"

# ---------------------------------------------------------------------------
# Well-founded artifact generation.
#
# The order below is the whole point, and it is stated once here: every subject
# is EXECUTED first, every execution must then be observed-good, only then is
# the artifact written - whole, from those actual results - and only then is the
# separate canonical coverage seam asked whether the artifact it can now read is
# good. Nothing earlier in that order consults the artifact this run produces.
#
# WHY. A previous version wrote the artifact whatever the run observed. Editing
# tests/fm-test-run.test.sh - a subject whose own assertions consumed the
# INSTALLED proof - therefore reached a fixed point: the run recorded that
# subject failing, replaced a genuine 24-subject proof with a 23-subject one,
# and the next run failed the same subject again for the same reason. The
# subject required, as a passing precondition, the current acceptance artifact
# whose generation required that subject to pass. docs/architecture.md states
# that law under EVIDENCE_GENERATION_WELL_FOUNDEDNESS; the two repairs are here
# and at the test/evidence boundary in tests/fm-test-run.test.sh.
#
# Withholding is not tolerance and not a retry. A measured FAIL stays FAIL, this
# run is non-PASS, and the previous genuine artifact stays exactly as it was
# rather than being replaced by a weaker one.
# ---------------------------------------------------------------------------

abs_path() {
  local p=$1 d b
  d=$(dirname "$p")
  b=$(basename "$p")
  d=$(cd "$d" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "$b"
}

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Stable record order for the artifact.
  sort -t$'\t' -k1,1 "$RECORDS" -o "$RECORDS"

  # Step 2: every subject execution observed-good, judged by the one owner of
  # that question in bin/fm-test-isolation-lib.sh so the harness and that
  # module's regressions cannot answer it differently.
  CANDIDATE_FILE="$PROOF_ROOT/candidates.txt"
  printf '%s\n' "${CANDIDATES[@]}" >"$CANDIDATE_FILE"
  ARTIFACT_REFUSAL=$(fm_isolation_artifact_refusal "$RECORDS" "$CANDIDATE_FILE" "$FAILED" "$AGG_RC") || true

  if [ -n "$ARTIFACT_REFUSAL" ]; then
    printf 'FM_ISOLATION_ARTIFACT WITHHELD path=%s reason=%s candidates=%s failed=%s\n' \
      "$JSON_PATH" "$ARTIFACT_REFUSAL" "$TOTAL" "$FAILED"
    log "the previous artifact at $JSON_PATH is left exactly as it was"
    log "a measured failure is not cleared by writing a smaller proof; fix the subject and measure again"
    if [ "$AGG_RC" -ne 0 ]; then
      exit "$AGG_RC"
    fi
    exit 1
  fi

  # The proof-wide material dependencies, captured at proof time: the isolation
  # semantics every worker was built from, and the concurrency this repository
  # currently runs the proven set at. An unobservable lane inventory is written
  # as such rather than as a concurrency of zero.
  CONTRACT_DIGEST=$(fm_isolation_contract_digest) \
    || die "could not digest the isolation contract; refusing to record an unbound proof"
  LANES_FILE="$PROOF_ROOT/lanes.txt"
  : >"$LANES_FILE"
  set +e
  fm_isolation_lane_concurrency "$ROOT" >"$LANES_FILE"
  LANES_RC=$?
  set -e
  if [ "$LANES_RC" -ne 0 ]; then
    log "could not observe CI lane concurrency; recording it as could-not-observe"
    : >"$LANES_FILE"
  fi
  RUNNER_CAP=$("$ROOT/bin/fm-test-run.sh" --print-jobs-max 2>/dev/null || echo)
  case "$RUNNER_CAP" in
    ''|*[!0-9]*) die "could not read the runner concurrency cap; refusing to record an unbound proof" ;;
  esac

  # Step 3: write it whole. bin/fm-test-isolation-lib.sh renames a completed
  # document over the destination, so a write that dies partway leaves the
  # previous genuine artifact byte-identical instead of a truncated one.
  fm_isolation_write_proof "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$JOBS" "$RUN_DURATION" "$RECORDS" \
    "$CONTRACT_DIGEST" "$LANES_FILE" "$RUNNER_CAP" \
    || die "could not write the isolation proof; the previous artifact is unchanged"
  printf 'FM_ISOLATION_ARTIFACT WRITTEN path=%s subjects=%s candidates=%s\n' \
    "$JSON_PATH" "$TOTAL" "$TOTAL"

  # Step 4: the separate canonical seam. bin/fm-test-run.sh is the production
  # consumer of this artifact, it is not one of the subjects above, and it runs
  # no test - so asking it now closes the loop without re-entering it. It is
  # asked only about the canonical proof, because that is the only artifact it
  # reads; any other destination is stated as out of its scope rather than
  # silently reported as good.
  SEAM_TARGET=$(abs_path "$JSON_PATH" || true)
  SEAM_CANONICAL=$(abs_path "$ROOT/docs/fm-test-isolation-proof.json" || true)
  if [ -n "$SEAM_TARGET" ] && [ "$SEAM_TARGET" = "$SEAM_CANONICAL" ]; then
    set +e
    SEAM_OUT=$("$ROOT/bin/fm-test-run.sh" --check-coverage 2>&1)
    SEAM_RC=$?
    set -e
    case "$SEAM_RC" in
      0)
        printf 'FM_ISOLATION_SEAM PROVEN consumer=bin/fm-test-run.sh check=--check-coverage\n'
        ;;
      1)
        printf 'FM_ISOLATION_SEAM REFUSED consumer=bin/fm-test-run.sh check=--check-coverage\n'
        log "the artifact is genuine, but the canonical coverage seam refuses it:"
        printf '%s\n' "$SEAM_OUT" >&2
        AGG_RC=1
        ;;
      *)
        printf 'FM_ISOLATION_SEAM COULD-NOT-OBSERVE consumer=bin/fm-test-run.sh check=--check-coverage rc=%s\n' "$SEAM_RC"
        log "the canonical coverage seam could not judge the artifact just written:"
        printf '%s\n' "$SEAM_OUT" >&2
        AGG_RC=1
        ;;
    esac
  else
    printf 'FM_ISOLATION_SEAM NOT-APPLICABLE reason=artifact-is-not-the-canonical-proof path=%s\n' \
      "$JSON_PATH"
  fi
fi

exit "$AGG_RC"
