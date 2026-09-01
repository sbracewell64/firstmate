#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for the proven-isolated set,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane portable-serial-<k>of<n>   (one CI serial shard)
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --print-jobs-max
#   fm-test-run.sh --check-coverage
#     Also judges docs/fm-test-isolation-proof.json against this code and
#     refuses a stale or unjudgeable proof. Exits 0 ok, 1 a stated invariant
#     broke, 3 could-not-observe.
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Measurement-basis qualification (no suite execution):
#   fm-test-run.sh --check-basis
#     Re-derives the mean and the measured spread from the declared basis
#     samples and refuses when either disagrees with the declarations, or when
#     the basis carries fewer samples than the declared minimum. Prints one
#     FM_TEST_BASIS line. Exits 0 qualified, 1 the declarations disagree with
#     their own evidence, 3 the sample evidence cannot be read, or 4 the basis
#     is too small to calibrate the lane axis.
#
# Serial-lane budget recurrence control (no suite execution):
#   fm-test-run.sh --check-budget <lane.json> [more lane.json...]
#     Judges the serial lane a run actually executed against the declared budget
#     and shard count. Non-serial lane artifacts among the inputs are ignored.
#     Set FM_SERIAL_TIMEOUT_MINUTES to the workflow's literal shard
#     timeout-minutes so a disagreement with this runner is refused.
#     Prints one FM_TEST_BUDGET line and exits:
#       0  within budget and the declared partition ran exactly once
#       1  drifted past a stated bound, or the partition did not hold
#       4  measurement could-not-observe: the lane sits within the declared
#          measured spread of the drift threshold, or the basis is unqualified,
#          so the lane axis carries no product verdict either way
#       3  could not be observed (missing, unreadable, or incomplete artifacts,
#          which is what a shard cancelled at its hang tripwire leaves behind)
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run
#   --list          print selected script paths (one per line) and exit 0
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Default is 1 (serial). N>1 is allowed only when every
#                   selected script is in the proven-isolated set
#                   (bin/fm-test-isolation-proof.sh --list-proven). The cap is
#                   the concurrency the proof measured, printed by
#                   --print-jobs-max. Stateful families never schedule under
#                   --jobs.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#
# Exit status is non-zero if any selected script exits non-zero or a configured
# --fail-on-gate-skip token appears. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated set is owned by
# docs/fm-test-isolation-proof.json, the proof that measured it, and this script
# is a consumer of that artifact rather than a second copy of the list; the
# candidate set that proof run takes as input stays with
# bin/fm-test-isolation-proof.sh. Portable parallel shards are a duration-balanced
# partition of the proven set (see docs/fm-test-portable-shards.md).
#
# portable-serial stays strictly serial. Its CI shards (portable-serial-<k>of<n>)
# split it across separate runners, so two of its stateful scripts still never
# share a machine. This script owns <n>: a lane whose <n> disagrees with the
# configured shard count is refused, so a CI matrix cannot silently drop a shard.
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=bin/fm-test-isolation-lib.sh
. "$ROOT/bin/fm-test-isolation-lib.sh"

# The proof artifact this runner consumes. It owns the proven-isolated set and
# the freshness bindings that say whether that set is still about this code.
ISOLATION_PROOF_PATH="$ROOT/docs/fm-test-isolation-proof.json"

MODE=
LIST_ONLY=0
LIST_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
PRINT_JOBS_MAX=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
JOBS=1

# Maximum concurrent workers --jobs will schedule over the proven-isolated set.
# This is a licence, not a preference: it may not exceed the concurrency the
# proof actually measured, and bin/fm-test-isolation-lib.sh's freshness check
# refuses when it does. It was 8 against a proof taken at 4 - the runner was
# handing out twice the concurrency anyone had evidence for - and it is now
# stated against that evidence. Raising it means re-running the proof at the
# higher concurrency first, never the other way round.
JOBS_MAX=4

# Declared serial-lane budget, and the associated shard count and drift bounds.
# This block is the one owner of every number the recurrence control checks;
# docs/fm-test-portable-shards.md owns how to re-derive them.
#
# BASIS (2026-08-29). QUALIFIED MULTI-OBSERVATION basis: 18 CI runs recorded
# 2026-08-26..2026-08-29 across main and the branches of pull requests 134, 137
# and 138, every one of them on the same 136-script portable-serial inventory
# with zero script failures. portable_serial_basis_samples() below carries all
# 18, each with the run id and head that produced it, so the basis can be
# re-derived from its own evidence instead of trusted.
#
#   declared budget  = the mean of those 18 lane totals            = 2968619 ms
#   measured spread  = max |sample - budget| / budget = 5.986%  -> declared 6%
#   drift allowance  = 3x the measured spread                      = 18%
#
# WHY THIS BASIS IS PLURAL. A single run cannot measure its own uncertainty, so
# a one-run basis cannot establish that a growth threshold is separated from
# environmental movement. The previous basis was one run (32998443526,
# 3039944 ms) and the 25% allowance it retained had no measured support at all.
# 18 samples of the same inventory put the observed envelope at 6%, which is
# what the allowance is now derived FROM rather than asserted against.
#
# THE ADVERSE EVIDENCE THIS BASIS EXISTS TO EXPLAIN, preserved rather than
# laundered. Pull request 133 ran the SAME bin/fm-test-run.sh blob 82bf999c as
# main against its own unchanged 137-script inventory and landed on BOTH sides
# of the then-declared 2958406 ms bound:
#
#   run 33032980891 head 7f9f69bc  2786722 ms  below
#   run 33029663411 head 0462f4a2  2875920 ms  below
#   run 33031974388 head 31363d42  2942861 ms  below
#   run 33024470703 head 57aee0a8  2976279 ms  ABOVE
#   run 33012539386 head 890e0a80  2997408 ms  ABOVE
#   run 33022553898 head 656f2c24  3108169 ms  ABOVE
#
# Same candidate, same policy, opposite verdicts. Neither side is the true one
# and the later favorable samples do not erase the earlier adverse ones. That
# pair is why the lane axis now answers cno inside the measured envelope rather
# than calling either side a product verdict.
#
# This supersedes the 2026-08-17 basis of 122 scripts and 2366725 ms and the
# 2026-08-26 single-run basis of 3039944 ms. The lane genuinely grew past the
# 2026-08-17 inventory, so the budget is re-derived from what the suite now is;
# it is never restored to what it used to be and never widened to make a sample
# pass. 18% is NARROWER than the 25% it replaces.
#
# That rule is not local to this number. The isolation proof reached the same
# state from the same cause - its subjects moved while the recorded evidence
# stayed put - and is repaired the same way: re-MEASURE against what the code now
# is, never restamp the old evidence to match. Read
# bin/fm-test-isolation-lib.sh's header for that freshness model; this comment is
# only the cross-reference to it.
PORTABLE_SERIAL_BUDGET_MS=2968619

# The measured environmental envelope of the basis above, as a whole percent of
# the declared budget, rounded UP from the observed 5.986% so the envelope is
# never declared narrower than what was actually observed.
#
# This is the instrument's resolution. Inside it the lane total cannot tell
# suite growth apart from runner movement, so a lane whose distance from the
# drift threshold is within this envelope is reported cno rather than as a
# product pass or a product failure.
PORTABLE_SERIAL_MEASURED_SPREAD_PCT=6

# How many qualified same-inventory observations the basis must carry before the
# lane axis may return a product verdict at all. Below this the instrument is
# uncalibrated and every lane reads cno, which is what stops a single favorable
# sample from being rebased into a pass.
PORTABLE_SERIAL_BASIS_MIN_SAMPLES=8

# How many separate-runner shards the portable serial remainder splits into.
# One owner: CI lane names carry this count and are refused when they disagree.
#
# The existing 8 shards put the balanced wall at 2968619/8 = 371077 ms
# (~6.18 min) against the 15-minute cap below. The qualified basis did not move
# the sizing rule, so the count is unchanged here; re-deriving it under the ~3x
# hang-tripwire margin that originally sized this lane is separate work.
# The floor for any count is the longest single script
# (tests/fm-pr-check-security.test.sh, 257620 ms), which binds near 11 shards.
PORTABLE_SERIAL_SHARDS=8

# The hang tripwire .github/workflows/ci.yml sets on every serial shard job.
# A job's own timeout-minutes is not readable from inside the job, so the
# workflow passes its literal through FM_SERIAL_TIMEOUT_MINUTES and
# --check-budget refuses a value that disagrees with this one, the same way a
# lane name carrying the wrong shard count is refused.
PORTABLE_SERIAL_TIMEOUT_MIN=15

# LANE drift allowance, derived rather than asserted: 3x the 6% measured spread
# above. That places the drift threshold at 3502970 ms and the cno window at
# 3292792..3713148 ms, so a lane must clear the envelope by a full envelope
# width in either direction before the axis will call it.
#
# The largest qualified sample, 3074726 ms, sits 218066 ms (7.35% of budget)
# below the pass ceiling, which is more than the whole measured envelope. A
# healthy suite therefore still PASSES rather than parking on cno forever, and
# growth beyond the envelope still FAILS.
#
# This bound is derived from the spread and is never widened to admit a sample.
# Re-measuring the basis is what absorbs growth that already happened.
PORTABLE_SERIAL_BUDGET_DRIFT_PCT=18

# SHARD headroom is checked only against the hang tripwire, never against the
# balanced wall, so per-shard jitter is not a verdict. At 60% of a 15-minute cap
# the bound is 9 min against a ~6.18 min balanced wall. This axis answers a
# different question from the lane axis - proximity to a job timeout, not suite
# growth - so it keeps its own deterministic verdict.
PORTABLE_SERIAL_SHARD_HEADROOM_PCT=60

# Balance hint for a portable-serial script with no measured duration. Rounded
# from the measured per-script mean of the declared budget
# (2968619/136 = 21828 ms) so a newly added test neither starves nor overloads
# the shard it lands in.
PORTABLE_SERIAL_DEFAULT_WEIGHT_MS=22000

# The qualified observations the budget and spread above are derived FROM, one
# per line as "<run-id> <head> <lane-ms>". Every one is a CI run of this
# repository's own 136-script portable-serial inventory with zero script
# failures, recorded 2026-08-26..2026-08-29.
#
# This table is evidence, not decoration: --check-basis re-derives the mean and
# the spread from these lines and refuses when either disagrees with the
# declarations above, so the two cannot drift apart silently. An adverse sample
# may never be deleted to improve the numbers. If an inventory change requires
# a fresh qualified table, preserve every displaced adverse sample verbatim in
# the adjacent BASIS evidence before replacing the table; only the weight hints
# are replaced wholesale without that evidence-preservation step.
portable_serial_basis_samples() {
  cat <<'EOF'
32992825736 1ebdf3bd 2810550
32994090563 5218cd8a 2941063
32998443526 f2631785 3039944
33000979712 1c58904d 2987123
33006158339 d6fa2d30 3074726
33007341010 601393fc 2941059
33009849291 af13a31b 3057939
33011266153 05d5067e 3027470
33012188876 a2bc1e65 2994535
33012291827 d62cc50d 2983662
33014755502 6a48ef02 3020882
33016433772 40f181dd 2957219
33017276039 c1284e0e 2998916
33018918797 fedc1134 3019169
33020225875 cc58b439 2861399
33020877733 076f5b6f 3027101
33021966375 64d0b267 2790931
33023852185 96fed3ec 2901461
EOF
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  else
    # Second precision only when python3 is unavailable.
    echo $(($(date +%s) * 1000))
  fi
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
family_for_basename() {
  case "$1" in
    fm-admission.test.sh|\
    fm-arm-pretool-check.test.sh|fm-ask-user-authority.test.sh|\
    fm-brief.test.sh|fm-vendor-auth-probe.test.sh|\
    fm-calm-pi-extension.test.sh|fm-capability-catalog.test.sh|fm-cd-pretool-check.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|fm-context-statusline.test.sh|\
    fm-crew-state.test.sh|fm-decision-hold-lifecycle.test.sh|fm-decision-surface.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-grok-harness.test.sh|\
    fm-kimi-harness.test.sh|fm-herdr-lab.test.sh|fm-landed-lib.test.sh|\
    fm-launch-lib.test.sh|fm-lint.test.sh|\
    fm-nm-run-lib.test.sh|fm-qualification.test.sh|\
    fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|\
    fm-subagent-pretool-check.test.sh|\
    fm-supervision-instructions.test.sh|fm-task-axis.test.sh|\
    fm-task-base.test.sh|fm-task-delivery.test.sh|\
    fm-tmux-submit-busy.test.sh|fm-trace-context-lib.test.sh|\
    fm-review-exec.test.sh|fm-review-mutation.test.sh|\
    fm-review-envelope.test.sh|\
    fm-transition-lib.test.sh|fm-verify.test.sh|\
    fm-worker-initiated-validation.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-blocker-lib.test.sh|fm-classify.test.sh|\
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-session-lock-ancestry.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-ledger.test.sh|fm-wake-queue.test.sh|fm-watch-arm.test.sh|\
    fm-watch-checkpoint.test.sh|fm-watch-triage.test.sh|fm-watcher-lock.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-launcher-workspace-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-on.test.sh|fm-remote-backlog-handoff.test.sh|\
    fm-remote-doctor.test.sh|fm-remote-job.test.sh|\
    fm-remote-reply.test.sh|fm-remote-secondmate-lifecycle-e2e.test.sh|\
    fm-remote-secondmate-trace-context.test.sh|\
    fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-startup-memory-budget.test.sh|\
    fm-send-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-bootstrap.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-tangle-guard.test.sh|\
    fm-unattended-session.test.sh|fm-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-harness-liveness-drift-live-e2e.test.sh|\
    fm-opencode-primary-live-e2e.test.sh|fm-pi-primary-live-e2e.test.sh|\
    fm-quota-array-dispatch-live-e2e.test.sh|fm-send-secondmate-marker-herdr-e2e.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-tmux-agent-liveness.test.sh|\
    fm-route-enforcement.test.sh|fm-route-qualification.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-launch.test.sh|fm-send-strict.test.sh|\
    fm-spawn-batch.test.sh|fm-spawn-dispatch-profile.test.sh|\
    fm-trace-context-spawn.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-attest.test.sh|fm-attribution-sweep.test.sh|fm-merge-local.test.sh|\
    fm-exact-head-green-one-owner.test.sh|fm-pr-check-security.test.sh|\
    fm-pr-merge.test.sh|fm-review-diff.test.sh|\
    fm-teardown.test.sh|fm-x-mode.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      printf '%s\n' afk
      ;;
    fm-bearings-snapshot.test.sh|fm-fleet-snapshot-view.test.sh)
      printf '%s\n' snapshot-bearings
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      printf '%s\n' cmux
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' zellij
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' orca
      ;;
    *)
      printf '%s\n' unclassified
      ;;
  esac
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin) printf '%s\n' optin-env ;;
    cmux|zellij|orca) printf '%s\n' optional-binary ;;
    snapshot-bearings) printf '%s\n' optional-binary ;;
    *) printf '%s\n' none ;;
  esac
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
cmux
zellij
orca
unclassified
EOF
}

list_known_lanes() {
  local i
  printf '%s\n' portable-parallel-1
  printf '%s\n' portable-parallel-2
  printf '%s\n' portable-serial
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    printf 'portable-serial-%sof%s\n' "$i" "$PORTABLE_SERIAL_SHARDS"
    i=$((i + 1))
  done
  printf '%s\n' real-herdr-gated
}

# The proven-isolated set, read from the proof that measured it. This used to be
# a hand-maintained heredoc here, which made the runner a second owner of a claim
# the proof document was supposed to hold: the two agreed only by luck, and
# nothing compared them. There is now one owner - the artifact - and this is a
# consumer of it.
#
# An unreadable proof is could-not-observe and stops the run. It is never an
# empty proven set, because an empty set would silently reroute every proven
# script into the serial lane and read as a successful selection.
PROVEN_ISOLATED_CACHE=
PROVEN_ISOLATED_RESOLVED=0

# Resolves the proven set once and caches it. Returns non-zero, having said why,
# when the artifact cannot be read.
#
# The status matters more than the text. An earlier draft of this had
# list_proven_isolated call die() directly, which looked fail-closed and was not:
# every call site consumes it through a pipeline or a process substitution, so
# die() killed only the subshell and the guard carried on with an empty set - and
# then reported a shard-partition mismatch, which is a true statement about the
# wrong subject. Callers below check this status themselves for that reason.
resolve_proven_isolated() {
  local rc
  [ "$PROVEN_ISOLATED_RESOLVED" -eq 1 ] && return 0
  set +e
  PROVEN_ISOLATED_CACHE=$(fm_isolation_proven_paths "$ISOLATION_PROOF_PATH")
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    log "could not read the proven-isolated set from $ISOLATION_PROOF_PATH"
    log "that is could-not-observe, not an empty set; re-measure with: bin/fm-test-isolation-proof.sh --jobs $JOBS_MAX --json $ISOLATION_PROOF_PATH"
    return 1
  fi
  PROVEN_ISOLATED_RESOLVED=1
  return 0
}

list_proven_isolated() {
  resolve_proven_isolated || return 1
  printf '%s\n' "$PROVEN_ISOLATED_CACHE"
}

# Portable parallel shard 1: LPT balance of the proven-isolated set using the
# 2026-07-29 concurrent-proof durations, now known-stale for balance pending
# parallel-lane-split-rebalance (see docs/fm-test-portable-shards.md).
# Execution order is longest first so wall-clock stays near the balanced sum.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-x-mode.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-test-run.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-grok-harness.test.sh
tests/fm-lint.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-review-diff.test.sh
tests/fm-brief.test.sh
tests/fm-transition-lib.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-backend-herdr.test.sh
tests/fm-arm-pretool-check.test.sh
tests/fm-crew-state.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-pr-merge.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-composer-lib.test.sh
EOF
}

is_proven_isolated_script() {
  local want=$1 line
  # Resolve first so the artifact's readability is checked where the status can
  # still be acted on; the listing below then cannot fail silently.
  resolve_proven_isolated || die "cannot classify $want without a readable isolation proof"
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_proven_isolated)
  return 1
}

# The portable serial remainder: every tests/*.test.sh that is neither
# proven-isolated nor real-herdr-gated. Watcher, lock, AFK, real tmux, daemon,
# secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other
# unproven work stays here. Derived rather than enumerated so a newly added test
# lands here by default instead of falling out of every lane.
list_portable_serial() {
  local s base fam
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "real-herdr-gated" ]; then
      continue
    fi
    if is_proven_isolated_script "$s"; then
      continue
    fi
    printf '%s\n' "$s"
  done < <(all_repo_tests)
}

# Measured portable-serial script durations in milliseconds, from the CI timing
# artifact recorded in docs/fm-test-portable-shards.md. These are balance hints
# only: the shard partition stays complete and disjoint whatever they say, so a
# stale hint costs balance rather than coverage. That doc owns the refresh
# procedure.
#
# A suite added since the last artifact is seeded from a local measurement of
# that suite rather than left on PORTABLE_SERIAL_DEFAULT_WEIGHT_MS, because the
# default is a mean and a suite far above it packs onto an already-loaded shard
# every run. The next refresh replaces the whole table from CI, which is where a
# hint's authoritative value comes from.
portable_serial_weight_hints() {
  cat <<'EOF'
tests/fm-admission.test.sh 10870
tests/fm-afk-inject-e2e.test.sh 35090
tests/fm-afk-pi-herdr-return-e2e.test.sh 75
tests/fm-afk-return.test.sh 1392
tests/fm-ask-user-authority.test.sh 103
tests/fm-attempt.test.sh 17055
tests/fm-attest.test.sh 61019
tests/fm-attribution-sweep.test.sh 959
tests/fm-backend-cmux-smoke.test.sh 29
tests/fm-backend-cmux.test.sh 3023
tests/fm-backend-herdr-focus-flash-e2e.test.sh 21
tests/fm-backend-orca.test.sh 16307
tests/fm-backend-tmux-smoke.test.sh 560
tests/fm-backend-zellij-smoke.test.sh 22
tests/fm-backend-zellij.test.sh 7441
tests/fm-backend.test.sh 22323
tests/fm-backlog-handoff.test.sh 3243
tests/fm-bearings-snapshot.test.sh 78412
tests/fm-blocker-lib.test.sh 5383
tests/fm-bootstrap.test.sh 74800
tests/fm-busy-adapter-wiring.test.sh 18959
tests/fm-busy-state.test.sh 771
tests/fm-calm-pi-extension.test.sh 396
tests/fm-capability-catalog.test.sh 514
tests/fm-capacity-retry.test.sh 38922
tests/fm-capacity-routing.test.sh 57031
tests/fm-certify.test.sh 3979
tests/fm-classify.test.sh 4936
tests/fm-claude-stop-autoarm-live-e2e.test.sh 15
tests/fm-claude-stop-autoarm.test.sh 60625
tests/fm-codex-continuity-live-e2e.test.sh 21
tests/fm-commitment-register.test.sh 23684
tests/fm-conflict-marker-check.test.sh 275
tests/fm-context-statusline.test.sh 585
tests/fm-daemon.test.sh 31350
tests/fm-dead-predicate-check.test.sh 90099
tests/fm-decision-surface.test.sh 7860
tests/fm-documentation-audiences.test.sh 749
tests/fm-exact-head-green-one-owner.test.sh 2075
tests/fm-execution-replacement.test.sh 109803
tests/fm-fleet-snapshot-view.test.sh 102443
tests/fm-fleet-sync.test.sh 19228
tests/fm-gate-refuse.test.sh 3584
tests/fm-gitignore-config.test.sh 33
tests/fm-gotmp.test.sh 924
tests/fm-grok-continuity-live-e2e.test.sh 20
tests/fm-grok-stop-live-e2e.test.sh 21
tests/fm-guard-stale-banner.test.sh 5971
tests/fm-harness-liveness-drift-live-e2e.test.sh 19
tests/fm-herdr-session-cleanup.test.sh 6729
tests/fm-kimi-harness.test.sh 15782
tests/fm-landed-lib.test.sh 3185
tests/fm-landing-authorization.test.sh 9955
tests/fm-landing-seam.test.sh 20288
tests/fm-launch-lib.test.sh 865
tests/fm-launch.test.sh 6881
tests/fm-loop-actuate.test.sh 10953
tests/fm-loopspec.test.sh 15927
tests/fm-merge-local.test.sh 13511
tests/fm-model-registry.test.sh 869
tests/fm-model-zero-budget.test.sh 3566
tests/fm-nm-run-lib.test.sh 507
tests/fm-on.test.sh 7815
tests/fm-opencode-primary-live-e2e.test.sh 21
tests/fm-operational-input.test.sh 217
tests/fm-outbound-artifact.test.sh 47121
tests/fm-pending-reply.test.sh 8843
tests/fm-pi-primary-live-e2e.test.sh 19
tests/fm-pi-watch-extension.test.sh 17943
tests/fm-pr-check-security.test.sh 257620
tests/fm-procevent.test.sh 49764
tests/fm-public-followup.test.sh 28348
tests/fm-qualification.test.sh 6211
tests/fm-quota-array-dispatch-live-e2e.test.sh 20
tests/fm-reasoning-required.test.sh 43759
tests/fm-rebase-equivalence.test.sh 9403
tests/fm-remote-backlog-handoff.test.sh 15874
tests/fm-remote-doctor.test.sh 4723
tests/fm-remote-job.test.sh 38514
tests/fm-remote-reply.test.sh 9168
tests/fm-remote-secondmate-lifecycle-e2e.test.sh 174755
tests/fm-remote-secondmate-trace-context.test.sh 41620
tests/fm-research-scan.test.sh 4348
tests/fm-retrieval-contract.test.sh 11899
tests/fm-review-exec.test.sh 3789
tests/fm-review-mutation.test.sh 38752
tests/fm-route-enforcement.test.sh 25224
tests/fm-route-qualification.test.sh 42183
tests/fm-ruling-reconcile.test.sh 16034
tests/fm-secondmate-harness.test.sh 125944
tests/fm-secondmate-lifecycle-e2e.test.sh 6277
tests/fm-secondmate-liveness.test.sh 11319
tests/fm-secondmate-safety.test.sh 45265
tests/fm-secondmate-sync.test.sh 19640
tests/fm-send-marker.test.sh 4531
tests/fm-send-secondmate-marker-herdr-e2e.test.sh 50
tests/fm-session-lock-ancestry.test.sh 1167
tests/fm-session-start.test.sh 69347
tests/fm-sessionstart-nudge.test.sh 206
tests/fm-shared-captain-inheritance.test.sh 5623
tests/fm-slot-reservation.test.sh 34452
tests/fm-spawn-dispatch-profile.test.sh 51931
tests/fm-spawn-worktree-settle.test.sh 14730
tests/fm-startup-memory-budget.test.sh 6954
tests/fm-subagent-pretool-check.test.sh 697
tests/fm-supervision-events.test.sh 525
tests/fm-tangle-guard.test.sh 9041
tests/fm-task-axis.test.sh 2805
tests/fm-task-base.test.sh 24666
tests/fm-task-delivery.test.sh 11466
tests/fm-teardown-endpoint-safety.test.sh 1729
tests/fm-teardown.test.sh 122078
tests/fm-test-fixture-cleanup.test.sh 547
tests/fm-test-isolation-proof.test.sh 2601
tests/fm-test-lib-wait.test.sh 5998
tests/fm-tmux-agent-liveness.test.sh 1900
tests/fm-trace-context-lib.test.sh 228
tests/fm-trace-context-spawn.test.sh 43925
tests/fm-turnend-guard.test.sh 17061
tests/fm-unattended-session.test.sh 6711
tests/fm-update.test.sh 5119
tests/fm-vendor-auth-probe.test.sh 42871
tests/fm-verify-fork-landing.test.sh 148
tests/fm-verify.test.sh 3944
tests/fm-wake-daemon-lifecycle-e2e.test.sh 9751
tests/fm-wake-drain-open-decisions.test.sh 3699
tests/fm-wake-ledger.test.sh 16829
tests/fm-wake-queue.test.sh 29614
tests/fm-watch-arm.test.sh 27427
tests/fm-watch-checkpoint.test.sh 4401
tests/fm-watch-triage.test.sh 200349
tests/fm-watcher-lock.test.sh 100082
tests/fm-worker-initiated-validation.test.sh 124
tests/fm-worktree-guard.test.sh 9732
tests/fm-wrong-subject.test.sh 311
tests/fm-wsl-entry.test.sh 105
EOF
}

portable_serial_weight_for() {
  local want=$1 path ms
  while read -r path ms; do
    if [ "$path" = "$want" ]; then
      printf '%s\n' "$ms"
      return 0
    fi
  done < <(portable_serial_weight_hints)
  printf '%s\n' "$PORTABLE_SERIAL_DEFAULT_WEIGHT_MS"
}

# Longest-processing-time assignment of the serial remainder to
# PORTABLE_SERIAL_SHARDS bins, printing "<shard>\t<script>" for every script.
# Deterministic: candidates are ordered by hint descending then path, and ties
# between equally loaded bins always take the lowest bin index.
portable_serial_assignments() {
  local ms script i best best_load
  local -a loads=()
  i=1
  while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    loads[i]=0
    i=$((i + 1))
  done
  while IFS=$'\t' read -r ms script; do
    [ -n "$script" ] || continue
    best=1
    best_load=${loads[1]}
    i=2
    while [ "$i" -le "$PORTABLE_SERIAL_SHARDS" ]; do
      if [ "${loads[i]}" -lt "$best_load" ]; then
        best_load=${loads[i]}
        best=$i
      fi
      i=$((i + 1))
    done
    loads[best]=$((best_load + ms))
    printf '%s\t%s\n' "$best" "$script"
  done < <(
    while IFS= read -r script; do
      [ -n "$script" ] || continue
      printf '%s\t%s\n' "$(portable_serial_weight_for "$script")" "$script"
    done < <(list_portable_serial) | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2
  )
}

# Parse "<k>of<n>" from a portable-serial shard lane and echo <k>, refusing when
# <n> disagrees with this script's configured count so a CI matrix built for a
# different shard count fails loudly instead of dropping tests.
portable_serial_shard_index() {
  local lane=$1 spec index count
  spec=${lane#portable-serial-}
  index=${spec%%of*}
  count=${spec#*of}
  case "$spec" in
    *of*) ;;
    *) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$index" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  case "$count" in
    ''|*[!0-9]*) die "unknown lane '$lane' (see --list-lanes)" ;;
  esac
  if [ "$count" -ne "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' asks for $count portable serial shards but this runner is configured for $PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  if [ "$index" -lt 1 ] || [ "$index" -gt "$PORTABLE_SERIAL_SHARDS" ]; then
    die "lane '$lane' shard index is outside 1..$PORTABLE_SERIAL_SHARDS (see --list-lanes)"
  fi
  printf '%s\n' "$index"
}

select_proven_isolated() {
  local s
  resolve_proven_isolated || die "cannot select the proven-isolated lane without a readable isolation proof"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s shard idx found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      resolve_proven_isolated || die "cannot select lane '$want' without a readable isolation proof"
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_serial)
      ;;
    portable-serial-*)
      # One separate-runner shard of the same remainder, still serial in itself.
      shard=$(portable_serial_shard_index "$want")
      resolve_proven_isolated || die "cannot select lane '$want' without a readable isolation proof"
      while IFS=$'\t' read -r idx s; do
        [ -n "$s" ] || continue
        if [ "$idx" = "$shard" ]; then
          add_script "$s"
          found=1
        fi
      done < <(portable_serial_assignments)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b shard freshness_rc
  local -a saved_scripts=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-coverage.XXXXXX")

  if ! resolve_proven_isolated; then
    log "coverage guard: the proven-isolated set COULD NOT BE OBSERVED"
    rm -rf "$tmp"
    return 3
  fi
  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial (whole lane and each CI shard) + Herdr lane listings without
  # disturbing a caller's selection.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  : >"$tmp/serial_shards_raw"
  shard=1
  while [ "$shard" -le "$PORTABLE_SERIAL_SHARDS" ]; do
    SCRIPTS=()
    select_lane "portable-serial-${shard}of${PORTABLE_SERIAL_SHARDS}"
    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
      log "coverage guard: portable serial shard $shard of $PORTABLE_SERIAL_SHARDS is empty"
      SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")
      rm -rf "$tmp"
      return 1
    fi
    printf '%s\n' "${SCRIPTS[@]}" >>"$tmp/serial_shards_raw"
    shard=$((shard + 1))
  done
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  # Every serial script runs in exactly one CI shard: no duplicate work across
  # runners, and no script silently left out of the required lane.
  LC_ALL=C sort "$tmp/serial_shards_raw" | uniq -d >"$tmp/serial_shard_dups"
  if [ -s "$tmp/serial_shard_dups" ]; then
    log "coverage guard: portable serial shards share scripts:"
    cat "$tmp/serial_shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/serial_shards_raw" >"$tmp/serial_shards"
  missing=$(comm -23 "$tmp/serial" "$tmp/serial_shards" || true)
  extra=$(comm -13 "$tmp/serial" "$tmp/serial_shards" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable serial shards must equal the portable serial lane"
    [ -z "$missing" ] || { log "missing from serial shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond serial lane:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Every candidate the proof harness would measure must be a script the proof
  # actually proved, and vice versa. Candidates are the input to a proof run and
  # the proven set is its output, so a difference here means a measured set that
  # nobody re-recorded, not a formatting drift.
  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: proven-isolated set diverges from the harness candidate set (bin/fm-test-isolation-proof.sh --list)"
      comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  # The mandatory refusing consumer this artifact never had. A proven script
  # whose bytes moved, a fixture that moved under it, changed isolation
  # semantics, or a lane now running the proven set wider than the proof
  # measured all stop here. Failing to READ any of that stops here too: a proof
  # that cannot be judged is not a proof that passed.
  set +e
  fm_isolation_check_freshness "$ROOT" "$ISOLATION_PROOF_PATH" "$JOBS_MAX" >"$tmp/freshness" 2>&1
  freshness_rc=$?
  set -e
  case "$freshness_rc" in
    0) ;;
    1)
      log "coverage guard: the isolation proof is STALE for this code"
      cat "$tmp/freshness" >&2
      log "re-measure it: bin/fm-test-isolation-proof.sh --jobs $JOBS_MAX --json $ISOLATION_PROOF_PATH"
      log "re-measure means running the subjects again; never restamp digests onto old evidence"
      rm -rf "$tmp"
      return 1
      ;;
    *)
      log "coverage guard: the isolation proof's freshness COULD NOT BE OBSERVED"
      cat "$tmp/freshness" >&2
      rm -rf "$tmp"
      return 3
      ;;
  esac
  grep '^FM_ISOLATION_FRESHNESS ' "$tmp/freshness" || true

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s serial=%s serial_shards=%s herdr=%s proven=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')" \
    "$(wc -l <"$tmp/proven" | tr -d ' ')"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--aggregate-json requires python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

# Qualification check for the declared measurement basis. The declarations and
# the samples they were derived from live in the same file, which is exactly how
# they drift apart, so this re-derives both from the sample table and refuses a
# disagreement rather than trusting the constants.
#
# A basis too small to measure its own uncertainty is not a failing basis, it is
# an UNCALIBRATED instrument, so it exits 4 (measurement could-not-observe)
# rather than 1. Malformed or absent sample evidence exits 3 because the basis
# could not be observed at all.
check_serial_basis() {
  local tmp rc
  command -v python3 >/dev/null 2>&1 || die "--check-basis requires python3"
  tmp=$(mktemp -d)
  portable_serial_basis_samples >"$tmp/samples"
  set +e
  python3 - \
    "$tmp/samples" \
    "$PORTABLE_SERIAL_BUDGET_MS" \
    "$PORTABLE_SERIAL_MEASURED_SPREAD_PCT" \
    "$PORTABLE_SERIAL_BASIS_MIN_SAMPLES" \
    "$PORTABLE_SERIAL_BUDGET_DRIFT_PCT" <<'BASISPY'
import math, sys
from pathlib import Path

samples_path = sys.argv[1]
budget, spread_pct, min_samples, drift_pct = (int(a) for a in sys.argv[2:6])


def unobserved(reason, message):
    print("FM_TEST_BASIS verdict=could-not-observe reason=%s" % reason)
    print("fm-test-run: basis: %s" % message, file=sys.stderr)
    raise SystemExit(3)


samples = []
for raw in Path(samples_path).read_text(encoding="utf-8").split("\n"):
    raw = raw.strip()
    if not raw:
        continue
    parts = raw.split()
    if len(parts) != 3:
        unobserved("malformed-sample-line", "sample line is not '<run-id> <head> <lane-ms>': %s" % raw)
    try:
        ms = int(parts[2])
    except ValueError:
        unobserved("non-numeric-sample", "sample has a non-numeric lane total: %s" % raw)
    if ms <= 0:
        unobserved("non-positive-sample", "sample has a non-positive lane total: %s" % raw)
    samples.append(ms)

if not samples:
    unobserved("empty-basis", "the declared basis carries no samples")

n = len(samples)

# One run cannot measure its own uncertainty. Below the declared minimum the
# instrument is uncalibrated and the lane axis may not return a product verdict.
if n < min_samples:
    print(
        "FM_TEST_BASIS verdict=cno samples=%d min_samples=%d budget_ms=%d declared_spread_pct=%d"
        % (n, min_samples, budget, spread_pct)
    )
    print(
        "fm-test-run: basis: %d qualified observation(s) is below the declared minimum of %d, "
        "so the lane axis is uncalibrated and can credit neither a pass nor a failure" % (n, min_samples),
        file=sys.stderr,
    )
    raise SystemExit(4)

mean = sum(samples) // n
observed_dev = max(abs(v - budget) for v in samples)
observed_pct = observed_dev * 100.0 / budget
required_pct = int(math.ceil(observed_pct))

problems = []
if mean != budget:
    problems.append("declared budget %d ms is not the mean of its own %d samples (%d ms)" % (budget, n, mean))
# Declaring an envelope NARROWER than what was observed would hide real movement
# inside a product verdict, which is the defect this basis exists to remove.
if spread_pct < required_pct:
    problems.append(
        "declared spread %d%% is narrower than the observed %.3f%% (needs at least %d%%)"
        % (spread_pct, observed_pct, required_pct)
    )
elif spread_pct != required_pct:
    problems.append(
        "declared spread %d%% disagrees with the observed %.3f%% it is derived from (expected %d%%)"
        % (spread_pct, observed_pct, required_pct)
    )
required_drift_pct = 3 * spread_pct
if drift_pct != required_drift_pct:
    problems.append(
        "drift allowance %d%% disagrees with 3x the %d%% declared spread (expected %d%%)"
        % (drift_pct, spread_pct, required_drift_pct)
    )

print(
    "FM_TEST_BASIS verdict=%s samples=%d budget_ms=%d mean_ms=%d observed_spread_pct=%.3f "
    "declared_spread_pct=%d drift_pct=%d"
    % ("qualified" if not problems else "unqualified", n, budget, mean, observed_pct, spread_pct, drift_pct)
)
for problem in problems:
    print("fm-test-run: basis: %s" % problem, file=sys.stderr)
raise SystemExit(1 if problems else 0)
BASISPY
  rc=$?
  set -e
  rm -rf "$tmp"
  return "$rc"
}
# Recurrence control for serial-lane budget drift. Reads the per-shard timing
# artifacts a run just produced and distinguishes within budget, drifted past
# the declared bound, measurement cno, and evidence that could not be observed.
#
# Deliberately NOT a jitter detector. The semantic verdict rides on the LANE
# total against the derived 18% growth allowance and its 6% measurement band; a
# single shard's wall is only ever compared to the independent 9-minute
# headroom bound below the hang tripwire. A breach therefore reports lane
# growth or dangerous shard imbalance, not a comparison with the balanced-wall
# estimate.
#
# A missing, unreadable, or incomplete artifact set is could-not-observe (exit 3)
# and never a pass: a shard cancelled at its timeout uploads no timing, which is
# exactly the state this control exists to make legible.
check_serial_budget() {
  local tmp saved_scripts rc
  [ "$#" -gt 0 ] || die "--check-budget requires at least one lane timing JSON"
  command -v python3 >/dev/null 2>&1 || die "--check-budget requires python3"

  # The workflow's literal hang tripwire, refused when it disagrees with the
  # value the bounds above were derived against.
  if [ -n "${FM_SERIAL_TIMEOUT_MINUTES:-}" ]; then
    case "$FM_SERIAL_TIMEOUT_MINUTES" in
      ''|*[!0-9]*) die "FM_SERIAL_TIMEOUT_MINUTES must be a positive integer (got '$FM_SERIAL_TIMEOUT_MINUTES')" ;;
    esac
    if [ "$FM_SERIAL_TIMEOUT_MINUTES" -ne "$PORTABLE_SERIAL_TIMEOUT_MIN" ]; then
      die "serial shard timeout is ${FM_SERIAL_TIMEOUT_MINUTES}m in the workflow but this runner derived its bounds against ${PORTABLE_SERIAL_TIMEOUT_MIN}m; reconcile both"
    fi
  fi

  tmp=$(mktemp -d)
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/expected"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  python3 - \
    "$tmp/expected" \
    "$PORTABLE_SERIAL_SHARDS" \
    "$PORTABLE_SERIAL_BUDGET_MS" \
    "$PORTABLE_SERIAL_BUDGET_DRIFT_PCT" \
    "$PORTABLE_SERIAL_TIMEOUT_MIN" \
    "$PORTABLE_SERIAL_SHARD_HEADROOM_PCT" \
    "$PORTABLE_SERIAL_MEASURED_SPREAD_PCT" \
    "$PORTABLE_SERIAL_BASIS_MIN_SAMPLES" \
    "$(portable_serial_basis_samples | grep -c . || true)" \
    "$@" <<'PY'
import json, re, sys
from pathlib import Path

expected_path, shards, budget, drift_pct, timeout_min, headroom_pct = sys.argv[1:7]
spread_pct, basis_min, basis_n = (int(a) for a in sys.argv[7:10])
shards = int(shards)
budget = int(budget)
drift_pct = int(drift_pct)
timeout_ms = int(timeout_min) * 60000
headroom_ms = timeout_ms * int(headroom_pct) // 100
allowed = budget + budget * drift_pct // 100
# The instrument resolution carried onto the decision boundary. A lane whose
# distance from `allowed` falls inside this cannot be told apart from ordinary
# runner movement, so it yields no product verdict in either direction.
cno_band = allowed * spread_pct // 100

expected = {l for l in Path(expected_path).read_text(encoding="utf-8").split("\n") if l}

UNOBSERVED = 3
lane_re = re.compile(r"^lane=portable-serial-(\d+)of(\d+)$")


def unobserved(msg):
    print(f"FM_TEST_BUDGET verdict=could-not-observe reason={msg}")
    print(f"fm-test-run: serial budget could not be observed: {msg}", file=sys.stderr)
    sys.exit(UNOBSERVED)


seen = {}
for raw in sys.argv[10:]:
    p = Path(raw)
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        unobserved(f"{p} is not readable timing JSON ({exc.__class__.__name__})")
    if not isinstance(doc, dict):
        unobserved(f"{p} timing JSON is not an object")
    selection = doc.get("selection")
    if not isinstance(selection, str) or not selection:
        unobserved(f"{p} timing JSON has an invalid selection")
    m = lane_re.match(selection)
    if not m:
        if selection.startswith("lane=portable-serial-"):
            unobserved(f"{p} has malformed serial shard metadata")
        continue  # another lane's artifact; this control only judges the serial lane
    try:
        idx, of = int(m.group(1)), int(m.group(2))
    except ValueError:
        unobserved(f"{p} has invalid numeric shard metadata")
    if of != shards:
        unobserved(f"{p} reports {of} shards but this runner is configured for {shards}")
    if idx < 1 or idx > shards:
        unobserved(f"{p} reports shard {idx} outside the configured range 1..{shards}")
    if idx in seen:
        unobserved(f"shard {idx} appears in more than one timing artifact")
    rows = doc.get("scripts")
    if not isinstance(rows, list) or not rows:
        unobserved(f"shard {idx} timing artifact lists no scripts")
    paths, total, failed, skipped_gate = [], 0, 0, 0
    for row in rows:
        if not isinstance(row, dict):
            unobserved(f"shard {idx} has an invalid script record")
        ms = row.get("duration_ms")
        if type(ms) is not int or ms < 0:
            unobserved(f"shard {idx} has a script with an invalid measured duration")
        path = row.get("path")
        if not isinstance(path, str) or not path:
            unobserved(f"shard {idx} has a script with an invalid path")
        exit_code = row.get("exit")
        if type(exit_code) is not int or exit_code < 0:
            unobserved(f"shard {idx} has a script with an invalid exit code")
        gate_skip = row.get("gate_skip")
        if type(gate_skip) is not bool:
            unobserved(f"shard {idx} has a script with an invalid gate-skip result")
        if gate_skip and exit_code != 0:
            unobserved(f"shard {idx} has a self-contradictory script result")
        paths.append(path)
        total += ms
        failed += exit_code != 0
        skipped_gate += gate_skip
    summary = doc.get("summary")
    if not isinstance(summary, dict):
        unobserved(f"shard {idx} timing artifact has an invalid summary")
    for field in ("total", "failed", "skipped_gate", "duration_ms"):
        value = summary.get(field)
        if type(value) is not int or value < 0:
            unobserved(f"shard {idx} timing artifact has an invalid summary {field}")
    if (
        summary["total"] != len(rows)
        or summary["failed"] != failed
        or summary["skipped_gate"] != skipped_gate
        or summary["duration_ms"] < total
    ):
        unobserved(f"shard {idx} timing artifact summary disagrees with its script records")
    seen[idx] = (total, summary["duration_ms"], paths)

missing_shards = [i for i in range(1, shards + 1) if i not in seen]
if missing_shards:
    unobserved(
        "no timing artifact for shard(s) "
        + ",".join(str(i) for i in missing_shards)
        + " (a shard cancelled at its hang tripwire uploads none)"
    )

observed = [p for _, _, paths in seen.values() for p in paths]
lane_total = sum(total for total, _, _ in seen.values())
worst_idx = max(seen, key=lambda i: (seen[i][1], i))
worst = seen[worst_idx][1]

failures = []

# Partition half: the run must have executed exactly the lane this head declares.
dup = sorted({p for p in observed if observed.count(p) > 1})
gone = sorted(expected - set(observed))
extra = sorted(set(observed) - expected)
if dup or gone or extra:
    if dup:
        failures.append(f"scripts ran in more than one shard: {', '.join(dup)}")
    if gone:
        failures.append(f"declared lane scripts that no shard ran: {', '.join(gone)}")
    if extra:
        failures.append(f"scripts run that the declared lane does not contain: {', '.join(extra)}")

# THE LANE AXIS, and the only axis the measured spread applies to. It is the one
# whose input is a wall-clock measurement of a shared hosted runner, so it is the
# one that can be moved across its own threshold by the environment alone. The
# partition and shard-headroom axes below are deterministic facts about what ran,
# not measurements of how fast, and keep their ordinary verdicts.
#
# Three outcomes, and the middle one is a real answer rather than a missing one:
#   lane_total > allowed + cno_band   growth past the boundary by more than the
#                                     instrument can explain            -> FAIL
#   within cno_band of allowed        indistinguishable from runner movement,
#                                     so neither side may be credited   -> CNO
#   lane_total < allowed - cno_band   materially clear of the boundary  -> PASS
lane_cno = None
if basis_n < basis_min:
    # An uncalibrated instrument cannot certify anything, so no number of
    # favorable samples can be rebased into a pass while the basis is this thin.
    lane_cno = (
        f"the declared basis carries {basis_n} qualified observation(s), below the "
        f"declared minimum of {basis_min}; the lane axis is uncalibrated, so this "
        f"{lane_total} ms lane credits neither a pass nor a failure"
    )
elif lane_total > allowed + cno_band:
    failures.append(
        f"lane grew to {lane_total} ms, past the {allowed} ms bound "
        f"({drift_pct}% over the declared {budget} ms budget) by more than the "
        f"{cno_band} ms measured-spread allowance; that is beyond what runner "
        f"movement explains, so re-derive the budget from a fresh qualified basis"
    )
elif lane_total >= allowed - cno_band:
    lane_cno = (
        f"lane measured {lane_total} ms, within the {cno_band} ms measured spread "
        f"({spread_pct}%) of the {allowed} ms bound; the same candidate under the same "
        f"policy has been observed on both sides of a boundary this close, so the lane "
        f"axis reports no product verdict"
    )

if worst > headroom_ms:
    failures.append(
        f"shard {worst_idx} ran {worst} ms, past the {headroom_ms} ms bound "
        f"({headroom_pct}% of the {timeout_ms} ms hang tripwire); "
        f"it is close enough to the cap to cancel on a slower runner"
    )

# A deterministic failure still outranks the measurement verdict: a run that did
# not execute the declared lane, or a shard crowding the hang tripwire, is a fact
# about the run rather than a reading that noise could explain.
verdict = "drifted" if failures else ("cno" if lane_cno else "ok")

print(
    "FM_TEST_BUDGET verdict=%s shards=%d lane_ms=%d budget_ms=%d allowed_ms=%d "
    "spread_pct=%d cno_band_ms=%d basis_samples=%d "
    "balanced_ms=%d worst_shard=%d worst_shard_ms=%d headroom_ms=%d"
    % (
        verdict,
        shards,
        lane_total,
        budget,
        allowed,
        spread_pct,
        cno_band,
        basis_n,
        lane_total // shards,
        worst_idx,
        worst,
        headroom_ms,
    )
)
for f in failures:
    print(f"fm-test-run: serial budget: {f}", file=sys.stderr)
if lane_cno and not failures:
    print(f"fm-test-run: serial budget: {lane_cno}", file=sys.stderr)
    sys.exit(4)
sys.exit(1 if failures else 0)
PY
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s base fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1 fixture_ref
  case "$path" in
    tests/fm-test-run.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh|bin/fm-test-isolation-proof.sh)
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-classify-lib.sh)
      printf '%s\n' watcher-wake-lock
      # The registered-probe closure gate (decision_close_refused, the fenced
      # pre-check, and the resolved branch of the open-decision fold) lives here,
      # and every case that covers it lives in the register's own suite, which is
      # in no family. Without this the gate could be inverted or dropped and a
      # changed-files run would select only the watcher lanes, which assert
      # nothing about it.
      printf '%s\n' "__script__:fm-commitment-register.test.sh"
      ;;
    bin/fm-watch*|bin/fm-wake*|\
    bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-blocker-lib.sh)
      # The dependency-driven pause re-surface has one library and two consumers
      # (the watcher and the away-mode daemon), and both live in this family.
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-startup-memory-budget.sh|bin/fm-startup-memory-budget-lib.sh)
      printf '%s\n' secondmate
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-secondmate*|bin/fm-remote*|bin/fm-on.sh|bin/fm-home-seed.sh|\
    bin/fm-backlog-handoff.sh|bin/fm-backlog-receive.sh|bin/fm-procevent-remote-reply.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*)
      printf '%s\n' secondmate
      ;;
    bin/fm-session-start.sh|bin/fm-bootstrap.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*|bin/fm-quota-axi-lib.sh)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-verify-lib.sh)
      # The shared three-valued observation type and check-set rule: the
      # wrapper's own suite, and the bearings snapshot, which splices that same
      # rule and asserts on the label it produces.
      printf '%s\n' pure-contract-unit
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-review-envelope.sh|bin/fm-review-envelope-lib.sh)
      # The review-envelope contract, its compiler and its classifier.
      # bin/fm-verify.sh's review-envelope adapter transports this script's
      # result, so a change here reaches tests/fm-verify.test.sh as well as its
      # own suite; both are in the same family, named once here so the
      # dependency is not left to the basename scan.
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-review-exec.sh)
      # The review execution and capture substrate. bin/fm-verify.sh's
      # review-exec adapter transports this script's result, so a change here
      # reaches tests/fm-verify.test.sh as well as its own suite; both are in
      # the same family, named once here so the dependency is not left to the
      # basename scan. bin/fm-review-mutation.sh commissions every one of its
      # executions through it, so its suite is reached from here too.
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-review-mutation.sh)
      # The recurrence and mutation proof owner. Same family as the substrate it
      # consumes and the wrapper that transports its result.
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-teardown.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*)
      printf '%s\n' pr-forge
      ;;
    bin/fm-task-base-lib.sh)
      # A task's two base references and the venue identity derived from them.
      # tests/fm-task-base.test.sh owns the derivation (pure-contract-unit), and
      # bin/fm-pr-check.sh sources this lib for the venue guard whose ssh-alias
      # coverage lives in tests/fm-pr-check-security.test.sh (pr-forge). The
      # basename scan finds only the first, so the second is named here.
      printf '%s\n' pure-contract-unit
      printf '%s\n' pr-forge
      ;;
    bin/fm-nm-run-lib.sh|bin/fm-timeout-lib.sh)
      # Shared no-mistakes run-attribution primitives, sourced by both
      # bin/fm-crew-state.sh (pure-contract-unit) and bin/fm-teardown.sh's
      # pre-teardown run abort (pr-forge). The shared hard bound those reads go
      # through is owned by bin/fm-timeout-lib.sh, so it selects the same lanes.
      printf '%s\n' pure-contract-unit
      printf '%s\n' pr-forge
      ;;
    bin/fm-launch-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      # The derived harness roster and launch_permission_posture live here, and
      # the commitment register's launch probe reads them: a roster that goes
      # vacuous retires a commitment while an unrestricted harness is still
      # launchable, so that suite has to run on a change to this file too.
      printf '%s\n' "__script__:fm-commitment-register.test.sh"
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-lint.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|\
    bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-vendor-auth-probe.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
    bin/fm-reflag.sh|bin/fm-task-axis-lib.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    commitments/*)
      # The typed commitment register. Registering an entry is a routine
      # operation, so this maps the directory rather than leaning on some test
      # happening to mention each new entry's path: the interpreter's own suite,
      # plus session start, which relays the open set and is the surface that
      # must not be able to go quiet while an entry is open.
      printf '%s\n' "__script__:fm-commitment-register.test.sh"
      printf '%s\n' session-bootstrap
      ;;
    .agents/skills/quota-array-dispatch/SKILL.md)
      printf '%s\n' pure-contract-unit
      printf '%s\n' live-harness-optin
      ;;
    .agents/skills/*/SKILL.md)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/no-mistakes-required.yml)
      # The required attestation gate. Its step scripts are exercised by
      # tests/fm-attest.test.sh alongside the verifier they drive, so a change
      # to the workflow has to select that suite and not only the doc lane.
      printf '%s\n' pr-forge
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/lib.sh|tests/*-helpers.sh)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/fixtures/*/*)
      # A fixture belongs to whichever suite reads its directory, found by the
      # same reference scan used for shared helpers. Keyed on the directory
      # rather than the file so adding a fixture selects the same suite.
      # A removed fixture directory has no consuming suite left to select.
      fixture_ref=${path#tests/fixtures/}
      fixture_ref=${fixture_ref%%/*}
      if [ -d "tests/fixtures/$fixture_ref" ]; then
        families_for_test_reference "fixtures/$fixture_ref" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    bin/*)
      # A deleted script has no consuming suite left to select, the same rule
      # the fixture case above applies. Refusing on its absent mapping would
      # make every retirement branch unable to select its changed tests.
      if [ -e "$path" ]; then
        families_for_test_reference "$(basename "$path")" \
          || printf '%s\n' "__unmapped__:$path"
      fi
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    *)
      families_for_test_reference "$path" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_basename "$(basename "$s")")
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! command -v python3 >/dev/null 2>&1; then
    die "--json requires python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, expected, exit_s, dur_s, gate = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
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
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --print-jobs-max)
      PRINT_JOBS_MAX=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --check-budget)
      [ -z "${MODE:-}" ] || die "--check-budget cannot be combined with --$MODE"
      MODE=check-budget
      shift
      ;;
    --check-basis)
      [ -z "${MODE:-}" ] || die "--check-basis cannot be combined with --$MODE"
      MODE=check-basis
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ] || [ "${MODE:-}" = "check-budget" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$PRINT_JOBS_MAX" -eq 1 ]; then
  printf '%s\n' "$JOBS_MAX"
  exit 0
fi

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "check-basis" ]; then
  check_serial_basis
  exit $?
fi

if [ "${MODE:-}" = "check-budget" ]; then
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--check-budget requires at least one lane timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "budget input not found: $s"
  done
  check_serial_budget "${SCRIPTS[@]}"
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$JOBS" -gt 1 ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0\n'
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    started=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$started" "$started" "empty" 0 0 0 0 "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit 0
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# --jobs N>1 only for the proven-isolated set. Stateful families stay serial.
if [ "$JOBS" -gt 1 ]; then
  for s in "${SCRIPTS[@]}"; do
    if ! is_proven_isolated_script "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list). Stateful families stay serial."
    fi
  done
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
trap 'rm -rf "$RUN_TMP"' EXIT

RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5
  local base family expected gate_skip fail_delta
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

run_one_serial() {
  local script=$1
  local base family expected out begin_iso begin_ms end_ms end_iso duration rc
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")
  out="$RUN_TMP/out.$TOTAL"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$begin_iso" "$script" "$family" "$expected"

  set +e
  # Stream live output while retaining a copy for gate-skip detection.
  # PIPESTATUS[0] is the test script; tee's exit is ignored for aggregate.
  bash "$script" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  set -e
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_one_serial "$script"
  done
else
  # Bounded concurrent execution for proven-isolated scripts only. Each worker
  # gets a private mode-0700 TMPDIR so mktemp roots cannot collide. Retries are
  # never used as a green strategy.
  declare -a WORKER_PIDS=()
  declare -a WORKER_IDX=()
  declare -a WORKER_SCRIPTS=()
  worker_n=0
  active_workers=0

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    set +e
    wait "$pid"
    set -e
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    if [ -s "$out" ]; then
      cat "$out"
    fi
    mode=$(stat -c %a "$work" 2>/dev/null || stat -f %Lp "$work" 2>/dev/null || echo unknown)
    case "$mode" in
      700|0700) ;;
      *)
        log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
        rc=1
        ;;
    esac
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
  }

  worker_pid_is_running() {
    local want=$1 running inventory="$RUN_TMP/running-pids"
    # Keep `jobs` in this shell. A process substitution runs it in a subshell
    # without this shell's job table on Bash 3.2/5.x, falsely reporting every
    # worker complete and making the scheduler wait for the oldest PID.
    jobs -r -p >"$inventory"
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done <"$inventory"
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${SCRIPTS[@]}"; do
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    base=$(basename "$script")
    family=$(family_for_basename "$base")
    expected=$(expected_gate_skip_for_family "$family")
    printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
      "$(now_iso)" "$script" "$family" "$expected"
    (
      set +e
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
        FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      bash "$script" >"$work/output" 2>&1
      rc=$?
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    WORKER_PIDS[worker_n]=$!
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  log "wrote timing artifact: $JSON_PATH"
fi

exit "$AGG_RC"
