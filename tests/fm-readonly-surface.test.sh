#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for the READ-ONLY execution surface: a bounded inspection that
# takes no treehouse slot, gets no worktree, and cannot write outside the three
# destinations it owns.
#
# The surface has four owners and this suite drives each through its executable:
#   bin/fm-readonly-lib.sh            the surface vocabulary and the enforceable
#                                     -harness predicate
#   bin/fm-readonly-subject.sh        sealing an exact head, and proving nothing
#                                     under it moved
#   bin/fm-readonly-command-policy.mjs the write-intent decision
#   bin/fm-readonly-pretool-check.sh  the PreToolUse transport that renders it
# plus the two consumers that had to learn about it: bin/fm-spawn.sh's dispatch
# refusals and bin/fm-backend.sh's endpoint validation.
#
# NO HARNESS IS SPAWNED and no model turn is taken. Every spawn case here stops
# at an argument or dispatch refusal, and the pool case stops at a backend that
# is not installed. What this suite therefore CANNOT prove is that claude's
# `--permission-mode dontAsk` refuses a denied tool at RUNTIME: that needs a real
# turn. tests/fm-readonly-live-harness.test.sh is the opt-in guard that proves
# it, and docs/verification/readonly-execution-surface.md records which half is
# which rather than letting the unproven half read as proven.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-readonly-surface)

SUBJECT="$ROOT/bin/fm-readonly-subject.sh"
POLICY="$ROOT/bin/fm-readonly-command-policy.mjs"
GUARD="$ROOT/bin/fm-readonly-pretool-check.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

# A git repo with two committed files, so a seal has something exact to take.
make_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf 'alpha\n' > "$dir/alpha.txt"
  mkdir -p "$dir/nested"
  printf 'beta\n' > "$dir/nested/beta.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  git -C "$dir" rev-parse HEAD
}

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" "$@" 2>&1
}

# A sealed subject is deliberately not writable, so the harness's own cleanup
# cannot remove it and would leave debris in /tmp. Restore write permission on
# this suite's scratch as soon as each sealing test is done asserting against it.
unlock_seals() { chmod -R u+w "$TMP_ROOT" 2>/dev/null || true; }

policy() {  # <command> [extra policy args...]
  local cmd=$1
  shift
  node "$POLICY" --command "$cmd" "$@"
}

# --- the surface vocabulary -------------------------------------------------

# The three-valued metadata read is the one every consumer branches on, and the
# distinction that matters is the one a naive `grep -c || return` destroys:
# a task with NO execution_surface line is an ORDINARY task, not an unreadable
# record. That bug shipped once here and sent every ordinary meta down the
# could-not-observe arm.
test_meta_surface_is_three_valued() {
  local dir="$TMP_ROOT/vocab" rc
  mkdir -p "$dir"
  printf 'window=x:1\nexecution_surface=readonly\n' > "$dir/ro.meta"
  printf 'window=x:1\nworktree=/tmp/wt\n' > "$dir/ordinary.meta"
  printf 'window=x:1\nexecution_surface=readonly\nexecution_surface=readonly\n' > "$dir/dup.meta"
  printf 'window=x:1\nexecution_surface=nonsense\n' > "$dir/bogus.meta"

  # shellcheck source=bin/fm-readonly-lib.sh
  . "$ROOT/bin/fm-readonly-lib.sh"

  fm_readonly_meta_surface "$dir/ro.meta" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "a declared readonly meta must read as the surface (got rc=$rc)"

  fm_readonly_meta_surface "$dir/ordinary.meta" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] || fail "an ordinary meta must read as NOT-readonly, not as unreadable (got rc=$rc)"

  fm_readonly_meta_surface "$dir/dup.meta" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "a duplicated surface line must read as unreadable, never last-one-wins (got rc=$rc)"

  fm_readonly_meta_surface "$dir/bogus.meta" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] || fail "an out-of-vocabulary surface value must not normalize onto the member (got rc=$rc)"

  fm_readonly_meta_surface "$dir/absent.meta" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "a missing meta file must read as unreadable (got rc=$rc)"

  pass "execution_surface reads three-valued and never folds ordinary onto unreadable"
}

# The enforceable-harness roster must be DERIVED from launch_template's own arms.
# A hand-listed copy goes vacuous the day an adapter is added rather than renamed.
test_enforceable_harness_roster_is_derived() {
  local roster
  # shellcheck source=bin/fm-launch-lib.sh
  . "$ROOT/bin/fm-launch-lib.sh"
  # shellcheck source=bin/fm-readonly-lib.sh
  . "$ROOT/bin/fm-readonly-lib.sh"

  roster=$(fm_readonly_enforceable_harnesses) || fail "the enforceable roster must be derivable"
  printf '%s\n' "$roster" | grep -qx claude || fail "claude must be enforceable"

  # Every adapter the launcher knows is either enforceable or explicitly not;
  # none may be silently absent from the judgement.
  local h
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    if fm_readonly_harness_enforceable "$h"; then
      launch_template "$h" readonly >/dev/null 2>&1 \
        || fail "$h is called enforceable but has no readonly launch template"
    else
      launch_template "$h" readonly >/dev/null 2>&1 \
        && fail "$h is not enforceable yet a readonly template was composed for it"
    fi
  done <<EOF
$(launch_harnesses)
EOF
  pass "the enforceable-harness roster is derived from the launcher's own arms"
}

# Adding the readonly KIND must not invent a phantom harness in the roster.
test_readonly_kind_does_not_pollute_the_harness_roster() {
  local roster
  # shellcheck source=bin/fm-launch-lib.sh
  . "$ROOT/bin/fm-launch-lib.sh"
  roster=$(launch_harnesses) || fail "the harness roster must be derivable"
  printf '%s\n' "$roster" | grep -qx readonly \
    && fail "'readonly' is a session kind, not a harness, and must not enter the roster"
  printf '%s\n' "$roster" | grep -qx claude || fail "claude must remain in the roster"
  pass "the readonly kind does not pollute the derived harness roster"
}

# The readonly launch must NOT carry an autonomy bypass, and MUST carry the deny
# list placeholder. This is the whole difference from every other crewmate arm.
test_readonly_template_denies_writes_without_a_bypass() {
  local tmpl
  # shellcheck source=bin/fm-launch-lib.sh
  . "$ROOT/bin/fm-launch-lib.sh"
  tmpl=$(launch_template claude readonly) || fail "claude must have a readonly template"
  assert_contains "$tmpl" '--permission-mode dontAsk' "readonly launch must use the non-prompting, non-bypassing mode"
  assert_contains "$tmpl" '--disallowedTools __DENIEDTOOLS__' "readonly launch must carry the tool deny list placeholder"
  assert_not_contains "$tmpl" '--dangerously-skip-permissions' "readonly launch must not carry an autonomy bypass"
  pass "the readonly launch template is prompt-free without bypassing permissions"
}

# --- sealing an exact subject ----------------------------------------------

test_seal_takes_the_commit_not_the_working_copy() {
  local repo="$TMP_ROOT/seal-repo" dest="$TMP_ROOT/seal-dest" head sealed
  head=$(make_repo "$repo")
  # Dirty the working copy AFTER the commit: the seal must not contain this.
  printf 'uncommitted\n' > "$repo/alpha.txt"
  printf 'untracked\n' > "$repo/stray.txt"

  "$SUBJECT" seal --repo "$repo" --head "$head" --dest "$dest" >/dev/null \
    || fail "seal of a clean commit must succeed"

  assert_grep 'alpha' "$dest/subject/alpha.txt" "the seal must carry the COMMITTED bytes"
  assert_no_grep 'uncommitted' "$dest/subject/alpha.txt" "the seal must not carry uncommitted working-copy bytes"
  assert_absent "$dest/subject/stray.txt" "the seal must not carry untracked files"
  sealed=$("$SUBJECT" head --dest "$dest")
  [ "$sealed" = "$head" ] || fail "the recorded head must be the exact commit sealed ($sealed != $head)"
  unlock_seals
  pass "seal extracts the exact commit, never the working copy"
}

test_seal_is_create_only() {
  local repo="$TMP_ROOT/create-only-repo" dest="$TMP_ROOT/create-only-dest" head out
  head=$(make_repo "$repo")
  "$SUBJECT" seal --repo "$repo" --head "$head" --dest "$dest" >/dev/null \
    || fail "first seal must succeed"
  out=$("$SUBJECT" seal --repo "$repo" --head "$head" --dest "$dest" 2>&1) \
    && fail "a second seal into the same dest must be refused"
  assert_contains "$out" "refusing to seal into an existing path" "the refusal must name the create-only rule"
  unlock_seals
  pass "seal refuses an existing destination rather than overwriting a subject"
}

# A failed seal must name git's OWN reason. "archive failed" alone cannot tell an
# untracked path from a bad commit from a full disk, and the untracked-path case
# is the common one.
test_failed_seal_surfaces_gits_reason_and_leaves_nothing() {
  local repo="$TMP_ROOT/failseal-repo" dest="$TMP_ROOT/failseal-dest" head out
  head=$(make_repo "$repo")
  out=$("$SUBJECT" seal --repo "$repo" --head "$head" --dest "$dest" --path not-in-this-commit 2>&1) \
    && fail "sealing a path absent from the commit must fail"
  assert_contains "$out" "did not match any files" "the refusal must carry git's own message"
  assert_absent "$dest" "a failed seal must not leave a partial destination behind"
  unlock_seals
  pass "a failed seal reports git's reason and leaves no partial subject"
}

# PREVENTION: the sealed tree is not writable.
test_sealed_subject_is_not_writable() {
  local repo="$TMP_ROOT/prevent-repo" dest="$TMP_ROOT/prevent-dest" head
  head=$(make_repo "$repo")
  "$SUBJECT" seal --repo "$repo" --head "$head" --dest "$dest" >/dev/null || fail "seal must succeed"
  ( printf 'mutation\n' >> "$dest/subject/alpha.txt" ) 2>/dev/null \
    && fail "a sealed file must not be writable"
  ( printf 'new\n' > "$dest/subject/added.txt" ) 2>/dev/null \
    && fail "a sealed directory must not accept a new file"
  unlock_seals
  pass "the sealed subject refuses writes at the filesystem"
}

# DETECTION: each of the three ways a subject can move is reported distinctly,
# and each is exit 2 rather than a silent pass.
test_mutation_of_the_sealed_subject_is_detected() {
  local repo="$TMP_ROOT/detect-repo" head base out status
  head=$(make_repo "$repo")

  # A positive control first: an untouched seal verifies clean, and says how many
  # files it checked. "no differences found" over an empty manifest would look
  # identical to a real pass.
  base="$TMP_ROOT/detect-clean"
  "$SUBJECT" seal --repo "$repo" --head "$head" --dest "$base" >/dev/null || fail "seal must succeed"
  out=$("$SUBJECT" verify --dest "$base"); status=$?
  expect_code 0 "$status" "an untouched subject must verify"
  assert_contains "$out" "2 files match" "verify must report a POSITIVE count, not merely no differences"

  local case_name mutate
  for case_name in changed added removed; do
    local dir="$TMP_ROOT/detect-$case_name"
    cp -r "$base" "$dir"
    chmod -R u+w "$dir"
    case "$case_name" in
      changed) printf 'tampered\n' > "$dir/subject/alpha.txt"; mutate=CHANGED ;;
      added)   printf 'extra\n' > "$dir/subject/extra.txt"; mutate=ADDED ;;
      removed) rm -f "$dir/subject/nested/beta.txt"; mutate=REMOVED ;;
    esac
    out=$("$SUBJECT" verify --dest "$dir" 2>&1); status=$?
    expect_code 2 "$status" "a $case_name subject must fail verification"
    assert_contains "$out" "$mutate" "verify must name the $case_name file"
  done
  unlock_seals
  pass "a changed, added, or removed file under the seal is detected distinctly"
}

# An unreadable subject is could-not-observe (3), never "intact" (0).
test_unverifiable_subject_is_could_not_observe() {
  local dir="$TMP_ROOT/cno" status
  mkdir -p "$dir/subject"
  "$SUBJECT" verify --dest "$dir" >/dev/null 2>&1; status=$?
  expect_code 3 "$status" "a subject with no manifest must be could-not-observe"
  "$SUBJECT" verify --dest "$TMP_ROOT/nope-not-here" >/dev/null 2>&1; status=$?
  expect_code 3 "$status" "an absent subject must be could-not-observe"
  pass "an unreadable subject is could-not-observe, never a pass"
}

# --- the write-intent policy ------------------------------------------------

test_policy_allows_ordinary_inspection() {
  local home="$TMP_ROOT/home" task=insp tmp="$TMP_ROOT/tmp-insp" cmd out
  for cmd in 'grep -rn needle .' 'git log --oneline -5' 'git status' 'cat config/models.json' \
             'find . -type f' 'jq .rules x.json' 'git -C /elsewhere diff' 'echo hello'; do
    out=$(policy "$cmd" --home "$home" --task "$task" --tasktmp "$tmp")
    [ "$out" = allow ] || fail "inspection command must be allowed: $cmd (got: $out)"
  done
  pass "ordinary read-only inspection is allowed"
}

test_policy_allows_only_the_tasks_own_three_destinations() {
  local home="$TMP_ROOT/home" task=own tmp="$TMP_ROOT/tmp-own" out
  out=$(policy "echo x > $home/data/$task/report.md" --home "$home" --task "$task" --tasktmp "$tmp")
  [ "$out" = allow ] || fail "a task must be able to write its own report (got: $out)"
  out=$(policy "echo x >> $home/state/$task.status" --home "$home" --task "$task" --tasktmp "$tmp")
  [ "$out" = allow ] || fail "a task must be able to append its own status (got: $out)"
  out=$(policy "rm $tmp/scratch" --home "$home" --task "$task" --tasktmp "$tmp")
  [ "$out" = allow ] || fail "a task must be able to manage its own scratch (got: $out)"

  # Another task's status file is NOT its own.
  out=$(policy "echo x >> $home/state/other.status" --home "$home" --task "$task" --tasktmp "$tmp")
  assert_contains "$out" deny "another task's status file must be denied"
  pass "only the task's own report, status, and scratch are writable"
}

test_policy_denies_writes_into_protected_trees() {
  local home="$TMP_ROOT/home" task=prot tmp="$TMP_ROOT/tmp-prot" out target
  for target in bin config qualifications state data; do
    out=$(policy "echo pwn > $home/$target/evil" --home "$home" --task "$task" --tasktmp "$tmp")
    assert_contains "$out" deny "a write into $target/ must be denied"
  done
  out=$(policy "rm -rf $home/config" --home "$home" --task "$task" --tasktmp "$tmp")
  assert_contains "$out" deny "deleting a protected tree must be denied"
  out=$(policy 'touch /etc/passwd' --home "$home" --task "$task" --tasktmp "$tmp")
  assert_contains "$out" deny "a write outside the home entirely must be denied"
  pass "writes into the protected trees and outside the home are denied"
}

# The sealed subject lives INSIDE the task's own writable scratch root, so the
# scratch allowance would hand back write access to the very tree the surface
# protects unless the subject is carved out.
test_policy_denies_writes_into_the_sealed_subject() {
  local home="$TMP_ROOT/home" task=carve tmp="$TMP_ROOT/tmp-carve"
  local subj="$tmp/seal/subject" out
  out=$(policy "echo x > $subj/alpha.txt" --home "$home" --task "$task" --tasktmp "$tmp" --subject "$subj")
  assert_contains "$out" deny "writing into the sealed subject must be denied"
  out=$(policy "rm -rf $subj" --home "$home" --task "$task" --tasktmp "$tmp" --subject "$subj")
  assert_contains "$out" deny "deleting the sealed subject must be denied"
  # ...while the scratch beside it stays usable, or the carve-out would be a
  # blanket denial of the task's own working area.
  out=$(policy "echo x > $tmp/work/notes" --home "$home" --task "$task" --tasktmp "$tmp" --subject "$subj")
  [ "$out" = allow ] || fail "scratch beside the subject must stay writable (got: $out)"
  pass "the sealed subject is carved out of the task's own writable scratch"
}

test_policy_denies_mutating_git_and_allows_reading_git() {
  local home="$TMP_ROOT/home" task=git tmp="$TMP_ROOT/tmp-git" out sub
  for sub in 'push origin main' 'commit -m wip' 'checkout -b fm/x' 'reset --hard' \
             'add .' 'stash' 'tag v1' 'fetch origin'; do
    out=$(policy "git $sub" --home "$home" --task "$task" --tasktmp "$tmp")
    assert_contains "$out" "mutating-git" "git $sub must be denied as mutating"
  done
  for sub in 'log' 'show HEAD' 'diff' 'status' 'rev-parse HEAD' 'blame f' 'cat-file -p HEAD'; do
    out=$(policy "git $sub" --home "$home" --task "$task" --tasktmp "$tmp")
    [ "$out" = allow ] || fail "git $sub is read-only and must be allowed (got: $out)"
  done
  pass "mutating git subcommands are denied while reading git stays available"
}

test_policy_sees_through_substitutions_and_in_place_edits() {
  local home="$TMP_ROOT/home" task=hidden tmp="$TMP_ROOT/tmp-hidden" out
  out=$(policy "echo \$(rm -rf $home/bin)" --home "$home" --task "$task" --tasktmp "$tmp")
  assert_contains "$out" deny "a mutation hidden in a command substitution must be denied"
  out=$(policy "sed -i s/a/b/ $home/bin/fm-spawn.sh" --home "$home" --task "$task" --tasktmp "$tmp")
  assert_contains "$out" deny "an in-place edit must be denied"
  out=$(policy "sed s/a/b/ $home/bin/fm-spawn.sh" --home "$home" --task "$task" --tasktmp "$tmp")
  [ "$out" = allow ] || fail "a non-in-place sed only reads and must be allowed (got: $out)"
  pass "substitutions and in-place edits are classified rather than passed over"
}

# FAIL CLOSED. This is the deliberate difference from the cd-guard sibling, and
# the property that makes "read-only" true rather than merely claimed.
test_policy_fails_closed_on_unclassifiable_input() {
  local home="$TMP_ROOT/home" task=closed tmp="$TMP_ROOT/tmp-closed" out
  out=$(policy 'grep "unterminated' --home "$home" --task "$task" --tasktmp "$tmp")
  assert_contains "$out" "unclassifiable-command" "unparseable shell syntax must be DENIED, not allowed"
  # A relative write with no declared cwd cannot be located, so it cannot be
  # shown to be inside an allowance.
  out=$(policy 'echo x > somewhere.txt' --home "$home" --task "$task" --tasktmp "$tmp")
  assert_contains "$out" deny "an unlocatable relative write must be denied"
  pass "the write-intent policy fails closed on what it cannot classify"
}

# --- the PreToolUse transport ----------------------------------------------

test_guard_denies_a_write_and_records_why() {
  local home="$TMP_ROOT/home" task=guard tmp="$TMP_ROOT/tmp-guard" err status stdout
  err=$(printf '{"tool_name":"Bash","tool_input":{"command":"echo pwn > %s/bin/evil"},"cwd":"%s"}' "$home" "$tmp" \
    | "$GUARD" --home "$home" --task "$task" --tasktmp "$tmp" --claude 2>&1 >/dev/null)
  status=${PIPESTATUS[0]}
  printf '{"tool_name":"Bash","tool_input":{"command":"echo pwn > %s/bin/evil"}}' "$home" \
    | "$GUARD" --home "$home" --task "$task" --tasktmp "$tmp" --claude >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a denied write must exit 2"
  assert_contains "$err" '"permissionDecision":"deny"' "the deny object must carry the harness decision"
  assert_contains "$err" 'write-outside-allowance' "the denial must record WHY it was denied"

  # Claude only honors a denial when stdout is empty.
  stdout=$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"}}' \
    | "$GUARD" --home "$home" --task "$task" --claude 2>/dev/null)
  [ -z "$stdout" ] || fail "stdout must stay empty on a Claude denial (got: $stdout)"
  pass "a write attempt is denied, recorded, and shaped for the harness"
}

test_guard_allows_inspection_and_the_tasks_own_writes() {
  local home="$TMP_ROOT/home" task=ok tmp="$TMP_ROOT/tmp-ok" status
  printf '{"tool_name":"Bash","tool_input":{"command":"grep -rn x ."},"cwd":"%s"}' "$tmp" \
    | "$GUARD" --home "$home" --task "$task" --tasktmp "$tmp" --claude >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "an inspection command must be allowed through"
  printf '{"tool_name":"Bash","tool_input":{"command":"echo x >> %s/state/%s.status"}}' "$home" "$task" \
    | "$GUARD" --home "$home" --task "$task" --tasktmp "$tmp" --claude >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "the task's own status append must be allowed through"
  pass "inspection and the task's own writes pass the guard"
}

# A guard that cannot tell WHICH task it is enforcing for would deny every write
# for the wrong reason, which teaches a worker to ignore it. It refuses loudly.
test_guard_without_task_identity_denies_rather_than_allows() {
  local status
  printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | "$GUARD" --claude >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a misconfigured guard must deny, not allow"
  # An empty payload is not a command at all, so there is nothing to deny.
  printf '' | "$GUARD" --home /h --task t --claude >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "an empty payload is not a shell invocation"
  pass "a misconfigured guard denies while an empty payload stays inert"
}

# --- dispatch refusals ------------------------------------------------------

# A readonly task delivers a report and has no branch to push, so every ship-only
# combination is refused before anything is created.
test_readonly_dispatch_refuses_contradictory_combinations() {
  local out
  out=$(run_spawn ro-a projects/none --readonly --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION)
  assert_contains "$out" "delivery contract" "a readonly ship contract must be refused"
  out=$(run_spawn ro-b projects/none --readonly --secondmate)
  assert_contains "$out" "secondmate owns a persistent home" "readonly + secondmate must be refused"
  out=$(run_spawn ro-c projects/none --readonly --succeed-execution --reason-code NL_RULE_CLASSIFICATION)
  assert_contains "$out" "already holds a slot" "readonly + successor dispatch must be refused"
  out=$(run_spawn ro-d projects/none --scout --reason-code NL_RULE_CLASSIFICATION --readonly-head HEAD)
  assert_contains "$out" "applies only to a --readonly spawn" "a readonly-only flag must be refused elsewhere"
  pass "contradictory readonly dispatch combinations are refused before anything is created"
}

# The load-bearing refusal: a harness that cannot mechanically enforce the
# posture is refused BY NAME rather than launched unrestricted, because a silent
# fallback would be a worker with write access to a subject it may not touch.
test_unenforceable_harness_is_refused_by_name() {
  local out h
  # shellcheck source=bin/fm-launch-lib.sh
  . "$ROOT/bin/fm-launch-lib.sh"
  # shellcheck source=bin/fm-readonly-lib.sh
  . "$ROOT/bin/fm-readonly-lib.sh"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    fm_readonly_harness_enforceable "$h" && continue
    out=$(run_spawn "ro-h-$h" projects/none --readonly --harness "$h" --reason-code NL_RULE_CLASSIFICATION)
    assert_contains "$out" "cannot mechanically enforce a read-only posture" "$h must be refused for readonly"
    assert_contains "$out" "$h" "the refusal must name the harness"
    assert_contains "$out" "Harnesses that can:" "the refusal must name a harness that would work"
  done <<EOF
$(launch_harnesses)
EOF
  pass "a harness that cannot enforce read-only is refused by name"
}

# --- endpoint validation ----------------------------------------------------

# A readonly task presents its sealed subject where worktree= would be. The
# substitution must be narrow: an ORDINARY task missing worktree= is still
# refused, or this would have quietly widened the endpoint contract for everyone.
test_endpoint_validation_accepts_readonly_without_widening_it() {
  local dir="$TMP_ROOT/endpoint" out
  mkdir -p "$dir"
  printf 'window=x:1\nendpoint_task_id=ro\nexecution_surface=readonly\nreadonly_subject=/tmp/fm-ro/seal/subject\nproject=/p\n' > "$dir/ro.meta"
  printf 'window=x:1\nendpoint_task_id=ns\nexecution_surface=readonly\nproject=/p\n' > "$dir/nosubject.meta"
  printf 'window=x:1\nendpoint_task_id=nw\nproject=/p\n' > "$dir/noworktree.meta"

  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh" >/dev/null 2>&1

  # The readonly meta must get PAST the worktree identity check. It still fails
  # later on a synthetic endpoint, which is what proves the check it passed was
  # the worktree one and not something else.
  out=$(fm_backend_validate_task_endpoint "$dir/ro.meta" ro 2>&1 >/dev/null || true)
  assert_not_contains "$out" "worktree identity" "a readonly meta must not be refused for a missing worktree"

  out=$(fm_backend_validate_task_endpoint "$dir/nosubject.meta" ns 2>&1 >/dev/null || true)
  assert_contains "$out" "readonly_subject" "a readonly meta with no subject must still be refused"

  out=$(fm_backend_validate_task_endpoint "$dir/noworktree.meta" nw 2>&1 >/dev/null || true)
  assert_contains "$out" "worktree identity" "an ORDINARY meta missing worktree= must still be refused"
  pass "endpoint validation accepts a readonly subject without widening the ordinary contract"
}

# --- no slot ----------------------------------------------------------------

# The reason the surface exists: a readonly dispatch must never consult the pool.
# Proven as a differential against an ordinary scout, because "the guard was not
# called" is only meaningful next to a run in which it WAS called - otherwise a
# spawn that died early for an unrelated reason would look identical.
test_readonly_dispatch_never_consults_the_pool() {
  local fixture="$TMP_ROOT/poolfix" log="$TMP_ROOT/pool-guard.log"
  local repo="$fixture/proj" home="$fixture/home" head out

  mkdir -p "$fixture"
  cp -r "$ROOT/bin" "$fixture/bin"
  # A recorder in place of the pool owner: it logs every consultation and then
  # refuses, which is what a full pool looks like to a spawn.
  cat > "$fixture/bin/fm-worktree-guard.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
[ "\${1:-}" = owner-fields ] && exit 0
echo "pool is full (recorder)" >&2
exit 1
SH
  chmod +x "$fixture/bin/fm-worktree-guard.sh"

  head=$(make_repo "$repo")
  mkdir -p "$home/state" "$home/data/pool-ro" "$home/data/pool-ordinary"
  printf 'task\n' > "$home/data/pool-ro/brief.md"
  printf 'task\n' > "$home/data/pool-ordinary/brief.md"
  : > "$log"

  # CONTROL: an ordinary scout MUST reach the pool. Without this the readonly
  # assertion below could pass vacuously.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 FM_BACKEND=zellij \
    "$fixture/bin/fm-spawn.sh" pool-ordinary "$repo" --scout --harness claude \
    --reason-code NL_RULE_CLASSIFICATION >/dev/null 2>&1 || true
  assert_grep 'select' "$log" "CONTROL FAILED: an ordinary scout must consult the pool, or this test proves nothing"

  # SUBJECT: the readonly dispatch must not appear in the log at all.
  : > "$log"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 FM_BACKEND=zellij \
    "$fixture/bin/fm-spawn.sh" pool-ro "$repo" --readonly --harness claude \
    --readonly-head "$head" --reason-code NL_RULE_CLASSIFICATION 2>&1 || true)
  assert_no_grep 'select' "$log" "a readonly dispatch must never consult the pool guard"

  # And it got far enough to matter: the subject was sealed, which happens after
  # the point the ordinary run was refused at.
  [ -d "/tmp/fm-pool-ro/seal/subject" ] || [ -n "$out" ] \
    || fail "the readonly dispatch did not proceed far enough for this to be meaningful"
  chmod -R u+w /tmp/fm-pool-ro 2>/dev/null || true
  rm -rf /tmp/fm-pool-ro
  pass "a readonly dispatch takes no pool slot while an ordinary scout still asks for one"
}

# NO AUTHORITY WIDENING. A readonly task reports; firstmate acts on the report.
# These are not file writes the allowance rule can see - several reach the
# network - so they are denied by the name of the program being run.
test_policy_denies_authority_widening() {
  local home="$TMP_ROOT/home" task=auth tmp="$TMP_ROOT/tmp-auth" out cmd
  for cmd in "$home/bin/fm-decision-hold.sh hold x k --title t --reason r" \
             "$home/bin/fm-landing-authorization.sh mint" \
             "bin/fm-pr-merge.sh 123" \
             "no-mistakes axi run --intent x" \
             "gh pr comment 12 --body hi" \
             "gh pr merge 12" \
             "gh issue create --title t" \
             "tasks-axi done x"; do
    out=$(policy "$cmd" --home "$home" --task "$task" --tasktmp "$tmp")
    assert_contains "$out" "authority-widening" "minting fleet state must be denied: $cmd"
  done

  # Reading the forge and the backlog is ordinary inspection work and must stay
  # available, or the surface cannot do the job it exists for.
  for cmd in "gh pr list" "gh pr view 12" "gh issue view 3087" "gh run view 5 --log" \
             "tasks-axi list" "tasks-axi ready"; do
    out=$(policy "$cmd" --home "$home" --task "$task" --tasktmp "$tmp")
    [ "$out" = allow ] || fail "reading the forge/backlog must be allowed: $cmd (got: $out)"
  done

  # An unknown subcommand denies rather than passing, so the list stays
  # fail-closed as those CLIs grow.
  out=$(policy "gh pr some-new-verb 12" --home "$home" --task "$task" --tasktmp "$tmp")
  assert_contains "$out" "authority-widening" "an unrecognized forge subcommand must deny, not pass"

  # Reading the lifecycle scripts is fine: an inspection reads them, it does not
  # run them.
  out=$(policy "cat $home/bin/fm-pr-merge.sh" --home "$home" --task "$task" --tasktmp "$tmp")
  [ "$out" = allow ] || fail "reading a lifecycle script must be allowed (got: $out)"
  pass "a readonly task cannot mint decisions, landings, or control comments"
}

# The property canonical teardown depends on. The seal deliberately strips write
# permission, which means a plain `rm -rf` CANNOT remove it - teardown's removal
# is `&&`-chained, so that failure would be SILENT and one abandoned copy of the
# tree would survive every readonly task. The seal must therefore be RECLAIMABLE
# by its owner: restoring write permission has to be enough.
#
# This pins the seal's chmod choice, not coreutils. A seal that used mode 000, or
# changed ownership, would still be unremovable after `chmod -R u+w` and would
# strand a tree in /tmp on every dispatch.
test_sealed_subject_is_reclaimable_by_its_owner() {
  local repo="$TMP_ROOT/reclaim-repo" dest="$TMP_ROOT/reclaim-dest" head
  head=$(make_repo "$repo")
  "$SUBJECT" seal --repo "$repo" --head "$head" --dest "$dest" >/dev/null || fail "seal must succeed"

  # First establish that the naive removal really does fail, or the assertion
  # below would pass for a seal that was never protected in the first place.
  rm -rf "$dest" 2>/dev/null
  [ -e "$dest" ] || fail "CONTROL FAILED: a sealed subject was removable without restoring write permission, so it was not actually protected"

  # Then the exact sequence bin/fm-teardown.sh uses on the task temp root.
  chmod -R u+w "$dest" 2>/dev/null || true
  rm -rf "$dest"
  assert_absent "$dest" "restoring write permission must be enough to reclaim the seal, or teardown strands it in /tmp forever"
  pass "the sealed subject is reclaimable by its owner after write permission is restored"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck unavailable; skipped"; return; }
  shellcheck "$ROOT/bin/fm-readonly-lib.sh" "$ROOT/bin/fm-readonly-subject.sh" \
    "$ROOT/bin/fm-readonly-pretool-check.sh" \
    || fail "the readonly surface scripts must be shellcheck clean"
  pass "the readonly surface scripts are shellcheck clean"
}

test_meta_surface_is_three_valued
test_enforceable_harness_roster_is_derived
test_readonly_kind_does_not_pollute_the_harness_roster
test_readonly_template_denies_writes_without_a_bypass
test_seal_takes_the_commit_not_the_working_copy
test_seal_is_create_only
test_failed_seal_surfaces_gits_reason_and_leaves_nothing
test_sealed_subject_is_not_writable
test_mutation_of_the_sealed_subject_is_detected
test_unverifiable_subject_is_could_not_observe
test_sealed_subject_is_reclaimable_by_its_owner
test_policy_allows_ordinary_inspection
test_policy_allows_only_the_tasks_own_three_destinations
test_policy_denies_writes_into_protected_trees
test_policy_denies_writes_into_the_sealed_subject
test_policy_denies_mutating_git_and_allows_reading_git
test_policy_sees_through_substitutions_and_in_place_edits
test_policy_fails_closed_on_unclassifiable_input
test_policy_denies_authority_widening
test_guard_denies_a_write_and_records_why
test_guard_allows_inspection_and_the_tasks_own_writes
test_guard_without_task_identity_denies_rather_than_allows
test_readonly_dispatch_refuses_contradictory_combinations
test_unenforceable_harness_is_refused_by_name
test_endpoint_validation_accepts_readonly_without_widening_it
test_readonly_dispatch_never_consults_the_pool
test_scripts_are_shellcheck_clean
unlock_seals
