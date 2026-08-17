#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, a reaper for background processes,
# fakebin/PATH-shim helpers, deterministic git identity and fixture builders,
# state/<id>.meta writers, and the common string/exit-code/file assertions.
# It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1
FM_TEST_PASSED_TESTS=

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Point every suite's shared-validation-daemon liveness read (bootstrap's
# VALIDATION_DAEMON check) at a root that does not exist, so it is deterministically
# silent. Without this, whether the machine's real no-mistakes daemon happens to
# be alive would leak into every suite that asserts exact bootstrap output. The
# cases that own that check set NM_HOME per invocation, which wins over this.
# Same hermeticity discipline as pinning PATH: the tests decide the inputs.
export NM_HOME="${TMPDIR:-/tmp}/fm-test-absent-nm-home"

# Point every suite's session-start commitment read (bootstrap's COMMITMENT
# check) at an EMPTY register, for the same reason and by the same discipline:
# whether the shipped register currently carries an unmet commitment must not leak
# into a suite that asserts exact bootstrap output. It is an empty register rather
# than an absent one on purpose - an absent register is could-not-observe and
# prints, which is the behavior tests/fm-commitment-register.test.sh owns. Cases
# that exercise the register set FM_COMMITMENT_DIR per invocation, which wins.
FM_TEST_EMPTY_COMMITMENT_DIR="${TMPDIR:-/tmp}/fm-test-empty-commitment-register"
mkdir -p "$FM_TEST_EMPTY_COMMITMENT_DIR" 2>/dev/null || true
export FM_COMMITMENT_DIR="$FM_TEST_EMPTY_COMMITMENT_DIR"

# Point every suite's session-start outbound sweep (bootstrap's OUTBOUND check)
# at an EMPTY backlog, for the same reason and by the same discipline as the two
# above: whether this machine's real fleet currently strands work must not leak
# into a suite that asserts exact bootstrap output.
#
# It is an empty backlog rather than an absent one on purpose. A fixture home is
# usually not a git repository, so the real snapshot reader fails there and the
# sweep correctly answers could-not-observe - which PRINTS, because a blind sweep
# that stayed quiet would be the defect the invariant exists to refuse. Handing
# it a readable empty backlog is what makes silence mean "nothing is stranded"
# instead of "nothing was checked". Cases that exercise the sweep set
# FM_OUTBOUND_SNAPSHOT per invocation, which wins.
FM_TEST_EMPTY_SNAPSHOT="${TMPDIR:-/tmp}/fm-test-empty-fleet-snapshot.json"
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","backlog":{"present":true,"records":[]},"tasks":[]}' \
  > "$FM_TEST_EMPTY_SNAPSHOT" 2>/dev/null || true
export FM_OUTBOUND_SNAPSHOT="$FM_TEST_EMPTY_SNAPSHOT"

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# The snapshot and Bearings suites opt into this identity ledger so their
# final contract can derive expected tests from the test declarations rather
# than maintaining a second list or a count.
pass() {
  local caller
  caller=${FUNCNAME[1]:-}
  if [ "${FM_TEST_IDENTITY_CONTRACT:-0}" = 1 ]; then
    FM_TEST_PASSED_TESTS="${FM_TEST_PASSED_TESTS:-}${caller}"$'\n'
  fi
  printf 'ok - %s\n' "$1"
}

# Compare the generated test-function identities with the identities that
# reported success.  An omitted invocation fails, while a new declared and
# invoked test is admitted without changing a maintained number.
fm_test_contract() {  # <suite-name>
  local suite=${1##*/} expected actual
  expected=$(compgen -A function | awk '/^test_/ { print }' | LC_ALL=C sort)
  actual=$(printf '%s' "${FM_TEST_PASSED_TESTS:-}" | awk 'NF' | LC_ALL=C sort)
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    printf 'not ok - %s: test identity contract mismatch\n' "$suite" >&2
    printf 'expected test identities:\n%s\nexecuted test identities:\n%s\n' \
      "$expected" "$actual" >&2
    return 1
  fi
  printf 'FM_TEST_CONTRACT suite=%s status=pass\n' "$suite"
}

# --- self-cleaning temp root and background-process reaper -------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal.
# fm_test_reap <pid>... registers a background process for teardown.
# Both are torn down by fm_test_cleanup, which is armed below on EXIT and on the
# signals that stop a wedged suite. A test file that needs extra teardown (e.g.
# killing a daemon) should define its own EXIT trap and call fm_test_cleanup from
# inside it so registered dirs and processes are still torn down.
#
# Directories and processes register through deliberately different mechanisms.
# The tmproot call site is almost always `TMP_ROOT=$(fm_test_tmproot prefix)`,
# which forks a subshell to capture stdout. Anything that function does to the
# current shell's state - an array append, a trap - dies with that subshell and
# never reaches the real caller, so directory registration cannot go through
# in-process state. `$$` is the one thing bash keeps stable across that boundary
# (it always resolves to the invoking shell's PID, not the subshell's - see
# `man bash` on `$$`), so fm_test_tmproot records the directory in a `$$`-keyed
# registry file instead. fm_test_reap is called directly from the test shell,
# never through command substitution, so it registers into arrays and can also
# carry each pid's identity for the recycled-pid check.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_PIDS=()
FM_TEST_CLEANUP_PID_IDENTITIES=()
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-cleanup.$$.XXXXXX") || return 1

# Install fm_test_cleanup for every way a suite can end, once per shell.
# A bare EXIT trap does not run for a signalled shell, and timeout(1) stops a
# hung suite with TERM, so EXIT alone would let a wedged case orphan its
# background processes.
fm_test_install_cleanup_trap() {
  [ -z "${FM_TEST_CLEANUP_TRAP_INSTALLED:-}" ] || return 0
  FM_TEST_CLEANUP_TRAP_INSTALLED=1
  trap fm_test_cleanup EXIT
  trap 'fm_test_cleanup_on_signal 1' HUP
  trap 'fm_test_cleanup_on_signal 2' INT
  trap 'fm_test_cleanup_on_signal 15' TERM
}

# Tear down, then exit with the conventional 128+signo so the runner still sees
# the suite as signalled. Clearing the EXIT trap keeps teardown from running
# twice; fm_test_cleanup is idempotent regardless.
fm_test_cleanup_on_signal() {  # <signal-number>
  fm_test_cleanup
  trap - EXIT
  exit "$((128 + $1))"
}

# Read a process identity through the production primitive. It runs in a
# throwaway bash rather than being sourced here: bin/fm-wake-lib.sh defines
# every fm_ function and mkdirs its state dir at source time, and injecting
# that into every shell that sources this harness could change unrelated
# suites. Failure prints nothing and returns nonzero.
fm_test_pid_identity() {  # <pid>
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c '. "$1" && fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$1" 2>/dev/null
}

# This shell's own identity, recorded into every fixture's .fm-test-fixture
# marker so the orphan sweep below can tell a live owner's directory from a dead
# one across PID reuse. Read once, here, in the real caller.
FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

# fm_test_reap <pid> ...: register background processes for teardown on every
# exit path - a clean pass, a fail() abort, or an abrupt signal. Register a pid
# as soon as it is known, BEFORE the assertions that could abort: a case that
# only kills on its happy path leaks on every other path. Each pid's identity
# is recorded alongside it: the registry lives for the whole suite, so by
# teardown a short-lived helper's pid can have been recycled to an unrelated
# process, and a root is only killed when its identity still matches.
fm_test_reap() {
  local pid identity
  fm_test_install_cleanup_trap
  for pid in "$@"; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    identity=$(fm_test_pid_identity "$pid") || identity=
    FM_TEST_CLEANUP_PIDS+=("$pid")
    FM_TEST_CLEANUP_PID_IDENTITIES+=("$identity")
  done
}

# Echo every given pid and its descendants, parents before children. A
# registered process may have forked its own tracked child - bin/fm-watch-arm.sh
# forks the watcher it supervises - and killing only the registered pid would
# orphan that child. All roots share one process-table read so registering many
# short-lived helpers stays cheap. Depth is bounded so a malformed process table
# cannot loop forever.
fm_test_process_tree() {  # <pid> ...
  local rows generation next depth=0
  [ "$#" -gt 0 ] || return 0
  # A ps that cannot render the pid/ppid table (MSYS/Cygwin, some busybox
  # builds) must not turn the reaper into a no-op: the identity-verified roots
  # are still known good, so emit them even when their descendants cannot be
  # discovered.
  if ! rows=$(ps -axo pid=,ppid= 2>/dev/null); then
    printf '%s\n' "$@"
    return 0
  fi
  generation="$*"
  while [ -n "$generation" ] && [ "$depth" -lt 8 ]; do
    printf '%s\n' "$generation" | tr ' ' '\n' | grep -v '^$' || true
    next=$(printf '%s\n' "$rows" | awk -v gen="$generation" '
      BEGIN { n = split(gen, ids, " "); for (i = 1; i <= n; i += 1) parent[ids[i]] = 1 }
      parent[$2] { printf "%s ", $1 }
    ')
    generation=${next% }
    depth=$((depth + 1))
  done
}

# Kill the given processes and every descendant they had at teardown time.
# The snapshot is taken BEFORE the first kill because a dead parent's children
# are reparented and can no longer be found by walking ppid. SIGKILL rather than
# SIGTERM because the process this reaper exists for, bin/fm-watch-arm.sh,
# deliberately launches a successor watcher when its child cycle ends: a
# catchable signal would hand back a fresh process nothing ever recorded.
fm_test_kill_tree() {  # <pid> ...
  local p
  while IFS= read -r p; do
    case "$p" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -KILL "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done <<<"$(fm_test_process_tree "$@")"
}

fm_test_cleanup() {
  local d i pid verified=()
  # Processes first: a live child must not keep writing into a directory that is
  # about to be removed. Never kill what cannot be proven ours: a registered
  # root is killed only when its identity read now matches the one recorded at
  # registration, so a recycled pid belonging to an unrelated process is
  # skipped and never enumerated as a tree root. Descendants found under a
  # verified root need no gate - they are that live process's current children.
  if [ "${#FM_TEST_CLEANUP_PIDS[@]}" -gt 0 ]; then
    for i in "${!FM_TEST_CLEANUP_PIDS[@]}"; do
      pid=${FM_TEST_CLEANUP_PIDS[$i]}
      [ -n "${FM_TEST_CLEANUP_PID_IDENTITIES[$i]:-}" ] || continue
      [ "$(fm_test_pid_identity "$pid")" = "${FM_TEST_CLEANUP_PID_IDENTITIES[$i]}" ] || continue
      verified+=("$pid")
    done
    if [ "${#verified[@]}" -gt 0 ]; then
      fm_test_kill_tree "${verified[@]}"
    fi
  fi
  FM_TEST_CLEANUP_PIDS=()
  FM_TEST_CLEANUP_PID_IDENTITIES=()
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  FM_TEST_CLEANUP_DIRS=()
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$root/.fm-test-fixture" ||
    ! printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"; then
    rm -rf "$root"
    return 1
  fi
  printf '%s\n' "$root"
}

# Arm cleanup here, at source time, which always runs in the real caller and
# never in one of fm_test_tmproot's command-substitution subshells. The install
# is idempotent, so the fm_test_reap call site can re-request it harmlessly.
fm_test_install_cleanup_trap

# fm_test_reap_orphans: best-effort sweep for fixture roots left behind by a
# prior run that was killed hard enough to skip the traps above (e.g. a
# SIGKILL timeout). Only removes directories carrying the .fm-test-fixture
# marker fm_test_tmproot writes, so it never touches unrelated fm-* tmp dirs
# from real (non-test) firstmate commands. The marker identifies the owning
# shell across PID reuse, so the same live owner always wins over the age
# fallback for dead or unowned roots.
FM_TEST_ORPHAN_MAX_AGE_SECONDS=${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-3600}

fm_test_reap_orphans() {
  local marker dir mtime now owner_pid owner_identity current_identity
  now=$(date +%s)
  for marker in "${TMPDIR:-/tmp}"/fm-*/.fm-test-fixture; do
    [ -e "$marker" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
        if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        ;;
    esac
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    dir=$(dirname "$marker")
    rm -rf "$dir"
  done
}

fm_test_reap_orphans

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_fake_git_fault <fakebin>: install a `git` shim that forwards to the real git
# except for the invocations a test selects, which fail the way git fails when it
# cannot read - fatal status 128, nothing on stdout.
#
# WHY A FAULT INJECTOR AND NOT A FIXTURE. The distinction under test in several
# suites is between "git successfully reported that this thing is absent" and
# "git could not read". A fixture can only build the first; the second is a
# failed read, and the only faithful way to produce one on demand is to make the
# read fail. Corrupting the repository instead fails EVERY read at once, which
# proves nothing about which read the code under test misclassified.
#
# The shim is inert unless the caller exports one of:
#   FM_FAULT_MATCH    bash ERE matched against the invocation's arguments joined
#                     by single spaces; every matching invocation fails
#   FM_FAULT_AT       1-based index; only the invocation at that index fails
# and, for FM_FAULT_AT, FM_FAULT_COUNTER naming a file the shim counts into. The
# counter is readable afterwards, so a sweep can tell "this index failed a read"
# from "this entry point never made that many reads" instead of assuming.
fm_fake_git_fault() {  # <fakebin>
  local fakebin=$1 real
  real=$(command -v git) || return 1
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
FM_FAULT_REAL_GIT='$real'
SH
  cat >> "$fakebin/git" <<'SH'
fm_fault_hit=0
if [ -n "${FM_FAULT_MATCH:-}" ]; then
  fm_fault_argv="$*"
  [[ $fm_fault_argv =~ $FM_FAULT_MATCH ]] && fm_fault_hit=1
fi
if [ -n "${FM_FAULT_AT:-}" ] && [ -n "${FM_FAULT_COUNTER:-}" ]; then
  fm_fault_n=$(cat "$FM_FAULT_COUNTER" 2>/dev/null || printf 0)
  case "$fm_fault_n" in ''|*[!0-9]*) fm_fault_n=0 ;; esac
  fm_fault_n=$((fm_fault_n + 1))
  printf '%s' "$fm_fault_n" > "$FM_FAULT_COUNTER"
  [ "$fm_fault_n" = "$FM_FAULT_AT" ] && fm_fault_hit=1
fi
if [ "$fm_fault_hit" = 1 ]; then
  printf 'fatal: injected read failure\n' >&2
  exit 128
fi
exec "$FM_FAULT_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
}

# fm_fake_treehouse <fakebin>: a treehouse stub that answers `status` with an
# empty pool and exits 0 for everything else.
#
# `status` cannot be a silent exit-0 like the other stubs: bin/fm-worktree-guard.sh
# runs before `treehouse get` and refuses a pool it cannot read, so a silent stub
# fails the spawn for the wrong reason. It must answer all three shapes the guard
# uses, because the guard probes capability from `status --help` (the --json flag
# does not exist before treehouse v2.1.0) and then reads whichever format that
# probe selected. An empty pool prints "[]" in the machine format and nothing at
# all in the human-readable one. Suites that need populated slots should install
# their own fake instead of using this one.
fm_fake_treehouse() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --help ]; then
  printf 'Usage:\n  treehouse status [flags]\n\nFlags:\n  -h, --help   help for status\n      --json   Print pool status as JSON\n'
  exit 0
fi
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  echo '[]'
  exit 0
fi
[ "${1:-}" = status ] && exit 0
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- validation-pipeline state database -------------------------------------

# fm_test_pipeline_db <db> <repo working path> <invocation>...: build a stand-in
# for the validation pipeline's state database, holding exactly the tables and
# columns the independence derivation joins.
#
# Each <invocation> is
# "<branch>|<provider>|<model>[|<purpose>[|<sessions>[|<status>]]]".
# An empty provider or model writes SQL NULL, the shape the real database uses
# when it recorded no such fact. <purpose> defaults to review, the reviewing
# invocation; pass review-fix for the agent that rewrites code in response,
# which is maker-side and must never be read as the critic, or none for a run
# that recorded NO agent invocation at all - the run that touched these bytes
# and never reached the review step.
#
# <sessions> selects which of the three recorded session shapes this run has,
# because all three have to be expressible or the derivation's three values
# cannot each be reached from a fixture:
#
#   ''      the reviewer and the review-fixer hold distinct sessions
#   1       they share one session - process independence observably ABSENT
#   none    the run records NO session rows at all - the reviewing invocation
#           happened and whose process ran it was never captured, which is
#           could-not-observe and must never read as independent
#
# <status> is the run's own status and defaults to completed. cancelled and
# failed are the statuses that make a run a NON-MEMBER of the branch fold: it
# never finished verifying anything, so its reviewer does not decide whether
# these bytes were verified independently. running and pending are in flight.
# Pass none to write an EMPTY status, the shape a row whose state was never
# recorded would have - which is could-not-observe and must never read as a run
# that is merely still going.
#
# Returns nonzero when python3 is unavailable, which callers report as a
# skipped case.
fm_test_pipeline_db() {
  local db=$1 repo=$2
  shift 2
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$db" "$repo" "$@" <<'PYDB'
import sqlite3
import sys

db, repo, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
conn = sqlite3.connect(db)
conn.executescript(
    "create table repos (id text primary key, working_path text);"
    "create table runs (id text primary key, repo_id text, branch text,"
    "  status text not null default 'completed');"
    "create table agent_invocations ("
    "  id text primary key, run_id text, step_name text, round integer,"
    "  purpose text, agent text, model_provider text, model text,"
    "  started_at integer, exit_status text);"
    "create table run_agent_sessions ("
    "  run_id text, role text, agent text, session_id text);"
)
conn.execute("insert into repos values ('r1', ?)", (repo,))
for n, spec in enumerate(specs):
    parts = spec.split("|")
    branch, provider, model = parts[0], parts[1], parts[2]
    purpose = parts[3] if len(parts) > 3 and parts[3] else "review"
    sessions = parts[4] if len(parts) > 4 else ""
    status = parts[5] if len(parts) > 5 and parts[5] else "completed"
    if status == "none":
        status = ""
    run = "run%d" % n
    conn.execute("insert into runs values (?, 'r1', ?, ?)", (run, branch, status))
    # A run that recorded no agent invocation at all: it touched these bytes and
    # never reached the review step. It has no invocation row and no session
    # rows, because there was nothing to hold either.
    if purpose == "none":
        continue
    conn.execute(
        "insert into agent_invocations"
        " values (?, ?, 'review', 1, ?, 'codex', ?, ?, ?, 'success')",
        ("inv%d" % n, run, purpose, provider or None, model or None, n),
    )
    # The invocation above is written either way: this run reviewed. Only the
    # SESSION rows are withheld, which is the whole point of the shape - the
    # derivation must not be able to reach it through "no invocation was
    # recorded for these bytes" and call the case proven.
    if sessions == "none":
        continue
    # The reviewer and the review-fixer are distinct sessions unless the spec
    # deliberately collapses them.
    fixer = "s-review-%d" % n if sessions == "1" else "s-fix-%d" % n
    conn.execute(
        "insert into run_agent_sessions values (?, 'reviewer', 'codex', ?)",
        (run, "s-review-%d" % n),
    )
    conn.execute(
        "insert into run_agent_sessions values (?, 'review-fixer', 'codex', ?)",
        (run, fixer),
    )
# A non-review step on the same run must never be read as a review. It is not
# added to a run declared to have recorded no invocation at all, which would
# quietly undo that shape.
if specs and (specs[0].split("|") + ["", "", ""])[3] != "none":
    conn.execute(
        "insert into agent_invocations"
        " values ('other', 'run0', 'test', 1, 'test', 'codex', 'nobody', 'no-model', 99, 'success')"
    )
conn.commit()
conn.close()
PYDB
}

# fm_test_model_registry <file> [yes|no]: write a config/models.json holding two
# providers on two credential pools, optionally declaring the mapping from the
# validation pipeline's own vocabulary onto this fleet's. Without that
# declaration the vendor and pool dimensions are could-not-observe, which is the
# honest reading and the one this fleet actually has today.
fm_test_model_registry() {
  local file=$1 declare_map=${2:-yes}
  local anthropic='' openai='' opus='' fable='' sol=''
  if [ "$declare_map" = yes ]; then
    anthropic='"pipeline_providers": ["anthropic"],'
    openai='"pipeline_providers": ["openai"],'
    opus='"pipeline_model_ids": ["claude-opus-5"],'
    fable='"pipeline_model_ids": ["claude-fable-5"],'
    sol='"pipeline_model_ids": ["gpt-5.6-sol"],'
  fi
  cat > "$file" <<JSON
{
  "schema": "fm-model-registry.v1",
  "providers": {
    "claude": {$anthropic "access_class": "A", "cost_posture": "subscription-flat", "status": "active"},
    "openai-codex": {$openai "access_class": "A", "cost_posture": "subscription-flat", "status": "active"}
  },
  "models": {
    "claude/opus": {"provider": "claude", "model_id": "opus", "harness": "claude",
      $opus "cost_class": "subscription-flat", "status": "approved-primary",
      "limits": {"shared_quota_pool": "claude-max"}},
    "claude/fable": {"provider": "claude", "model_id": "fable", "harness": "claude",
      $fable "cost_class": "subscription-flat", "status": "approved-specialist",
      "limits": {"shared_quota_pool": "claude-max"}},
    "openai-codex/gpt-5.6-sol": {"provider": "openai-codex", "model_id": "gpt-5.6-sol",
      "harness": "pi", $sol "cost_class": "subscription-flat", "status": "approved-primary",
      "limits": {"shared_quota_pool": "openai-codex-oauth"}}
  }
}
JSON
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- bounded waits ----------------------------------------------------------

# fm_test_wait_file <path> <seconds> <pid|-> <exited-msg> <timeout-msg>: poll
# until <path> exists, bounded by WALL-CLOCK seconds rather than an iteration
# count. An iteration budget is not a duration: the same "250 iterations of
# sleep 0.02" spends ~5s on an idle runner and ~20s on a loaded one, so a bound
# written as a count silently shrinks exactly when the work it waits for is
# slowest. bin/fm-remote-job-lib.sh bounds its own polls the same way.
# Choose <seconds> as a hang tripwire with margin over the measured worst case,
# never as the expected duration: a healthy wait returns the moment <path>
# appears and costs nothing extra.
# Fails with <exited-msg> when <pid> dies without producing <path>, or with
# <timeout-msg> at the deadline. Pass - for <pid> when no process backs the wait.
fm_test_wait_file() {
  local path=$1 seconds=$2 pid=$3 exited_msg=$4 timeout_msg=$5 deadline
  deadline=$((SECONDS + seconds))
  while [ ! -e "$path" ]; do
    if [ "$pid" != - ] && ! kill -0 "$pid" 2>/dev/null; then
      # The process can create <path> and exit between the two checks, so a
      # dead pid only proves failure once <path> is still absent afterwards.
      [ ! -e "$path" ] || return 0
      fail "$exited_msg"
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "$timeout_msg"
    sleep 0.02
  done
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
