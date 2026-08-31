#!/usr/bin/env bash
# Behavior tests for the head-bound no-mistakes attestation: bin/fm-attest.sh,
# which emits and verifies it, and the step scripts in
# .github/workflows/no-mistakes-required.yml that drive it in CI. The workflow
# belongs here rather than in a suite of its own because what the check tells a
# contributor is decided jointly by the verifier's exit status and the step's
# reading of it, and splitting them lets the two drift apart.
#
# Every refusal here is paired with a positive control that differs from it by
# exactly one input, because a verifier that refuses everything would satisfy
# red-only assertions and would be a worse defect than the honour-system check
# it replaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The repository's own bounded runner, used here to bound a call that must not
# run unbounded. Its 124 is what an unbounded read looks like from outside.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-attest)
ATTEST="$ROOT/bin/fm-attest.sh"
WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
NOTES_REF=refs/notes/no-mistakes
FM_ATTEST_TEST_HOME="$TMP_ROOT/home"
mkdir -p "$FM_ATTEST_TEST_HOME/config" "$FM_ATTEST_TEST_HOME/data"
export FM_HOME="$FM_ATTEST_TEST_HOME"
export FM_CONFIG_OVERRIDE="$FM_ATTEST_TEST_HOME/config"
export FM_DATA_OVERRIDE="$FM_ATTEST_TEST_HOME/data"

# A repository with one commit and no attestation ref.
new_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q -b fm/demo .
  git -C "$repo" config user.email attest@example.invalid
  git -C "$repo" config user.name "Attest Test"
  printf 'one\n' > "$repo/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" commit -qm one
}

install_default_branch() {
  local repo=$1
  local marker=${2:-absent}
  local source="$repo-default-source"
  local remote="$repo-default.git"
  git clone -q "$repo" "$source"
  git -C "$source" config user.email attest@example.invalid
  git -C "$source" config user.name "Attest Test"
  git -C "$source" checkout -qb main
  case "$marker" in
    absent) ;;
    regular)
      mkdir -p "$source/.github"
      printf 'fm-attest.v1 required\n' > "$source/.github/no-mistakes-attestation"
      git -C "$source" add .github
      git -C "$source" commit -qm declaration
      ;;
    symlink)
      mkdir -p "$source/.github"
      ln -s ../target "$source/.github/no-mistakes-attestation"
      git -C "$source" add .github
      git -C "$source" commit -qm declaration
      ;;
    *) fail "unknown default marker fixture: $marker" ;;
  esac
  git clone -q --bare "$source" "$remote"
  git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
  git -C "$repo" remote add origin "$remote"
}

add_note() {
  local repo=$1 commit=$2 body=$3
  git -C "$repo" notes --ref="$NOTES_REF" add -f -m "$body" "$commit" >/dev/null 2>&1
}

# The exact payload the gate accepts, so every negative fixture below can be
# written as this minus one property.
good_note() {
  printf 'no-mistakes-attestation: v1\nhead: %s\nrun: 01KZ5YTADR5YAXZSNKFXTW8W9F\ngates: intent,rebase,review,test,document,lint,push\ntool: no-mistakes/v1.40.3\n' "$1"
}

# Installs a fake `no-mistakes` on PATH that prints the given `axi status` body,
# so the emitter is exercised against the tool's real output shape without a
# pipeline run. The body goes to stdout and the exit status is the caller's,
# because that is what the real tool does with its own errors.
#
# Every stub also writes the version-upgrade banner to stderr, as the real tool
# does whenever an upgrade is available. That notice is unrelated to any run
# record, so it must never decide, satisfy, or describe one.
STUB_STDERR_NOTICE='A new version of no-mistakes is available: v1.40.3 -> v1.41.2'

install_pipeline_stub() {
  local dir=$1 status=$2 rc=${3:-0} notice=${4:-$STUB_STDERR_NOTICE}
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in\n'
    printf '  "--version") echo "no-mistakes version v1.40.3 (d873960) 2026-07-22T01:41:41Z" ;;\n'
    printf '  "axi status")\n'
    printf '    echo %s >&2\n' "'$notice'"
    printf '    cat <<%s\n' "'FM_STUB_TOON'"
    printf '%s\n' "$status"
    printf 'FM_STUB_TOON\n'
    printf '    exit %s\n' "$rc"
    printf '  ;;\nesac\n'
  } > "$dir/bin/no-mistakes"
  chmod +x "$dir/bin/no-mistakes"
}

# A pipeline tool that never answers, so the only thing that can end the call is
# the bound the emitter imposes on it.
install_hanging_pipeline_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in\n'
    printf '  "--version") echo "no-mistakes version v1.40.3 (d873960) 2026-07-22T01:41:41Z" ;;\n'
    printf '  "axi status") sleep 120 ;;\n'
    printf 'esac\n'
  } > "$dir/bin/no-mistakes"
  chmod +x "$dir/bin/no-mistakes"
}

# A pull request as this check sees it, in three repositories rather than one,
# because the check reads two of them and they are not always the same: the
# repository the branch was pushed to, which serves the attestation ref; the base
# repository, which serves refs/pull/<n>/head; and the workspace the job checks
# out, which addresses both by the remote names the workflow configures.
#
# Every path is derived after `local` has assigned, never in the same statement
# as the directory it is built from, because bash expands every right-hand side
# on that line before assigning any of them and a fixture that hands `git -C` an
# empty path runs against the checkout these tests live in.
new_reconcile_fixture() {
  local dir=$1
  local source_repo base_repo work
  source_repo="$dir/source.git"
  base_repo="$dir/base.git"
  work="$dir/work"
  mkdir -p "$dir"
  git init -q --bare "$source_repo"
  git init -q --bare "$base_repo"
  new_repo "$work"
  git -C "$work" remote add attestation-source "$source_repo"
  git -C "$work" remote add pullrequest-source "$base_repo"
  git -C "$work" push -q attestation-source HEAD:refs/heads/topic
  git -C "$work" push -q pullrequest-source HEAD:refs/pull/1/head
  git -C "$work" rev-parse HEAD
}

# Publishes a note to the repository the check reads and leaves the workspace
# without it, which is the state a job is in whenever an attestation lands after
# its checkout: the evidence exists where the check looks, and only a re-read
# finds it.
publish_to_source() {
  local dir=$1 head=$2 body=$3
  local work
  work="$dir/work"
  git -C "$work" notes --ref="$NOTES_REF" add -f -m "$body" "$head" >/dev/null 2>&1
  git -C "$work" push -q -f attestation-source "$NOTES_REF:$NOTES_REF"
  git -C "$work" update-ref -d "$NOTES_REF" 2>/dev/null || :
}

run_reconcile() {
  local dir=$1
  shift
  (
    cd "$dir/work" || exit 2
    "$ATTEST" reconcile --remote attestation-source \
      --pr 1 --pr-remote pullrequest-source "$@" 2>&1
  )
}

# Wall-clock seconds around one call, so a window that was honoured and a window
# that was skipped can be told apart by the only thing that distinguishes them.
elapsed_seconds() {
  local started
  started=$1
  echo $(($(date +%s) - started))
}

# One step's own script, lifted out of the workflow and run as the workflow runs
# it, so what the check tells a contributor is exercised rather than asserted
# against YAML text. The step is found by name, and an extraction that yields
# nothing is a failure, so a renamed or restructured step cannot pass vacuously.
workflow_step_script() {
  local want=$1
  awk -v want="$want" '
    /^      - / { in_step = 0; collecting = 0 }
    $0 == "      - name: " want { in_step = 1; next }
    in_step && $0 == "        run: |" { collecting = 1; next }
    !collecting { next }
    $0 == "" { print ""; next }
    substr($0, 1, 10) == "          " { print substr($0, 11); next }
    { collecting = 0; in_step = 0 }
  ' "$WORKFLOW"
}

# A verifier that reaches one chosen exit status, so the step's reading of that
# status is the single property under test. --print-format still answers,
# because the refusal branch prints the format and a stub that could not would
# make that branch fail for a reason of the fixture's own making.
install_verifier_stub() {
  local dir=$1 rc=$2
  mkdir -p "$dir/bin"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
    printf 'case "${1:-}" in\n'
    printf '  --print-format) echo "no-mistakes-attestation: v1" ;;\n'
    printf '  *) exit %s ;;\n' "$rc"
    printf 'esac\n'
  } > "$dir/bin/fm-attest.sh"
  chmod +x "$dir/bin/fm-attest.sh"
}

# A PATH carrying everything the emitter needs except any utility that could
# impose a timeout, so the single property under test is the absence of those
# three. bin/fm-timeout-lib.sh's bash watchdog must still bound the call there.
install_unbounded_path() {
  local dir=$1 tool
  mkdir -p "$dir"
  for tool in bash sh git sed awk tr cat cut head rm mktemp sleep dirname basename env uname grep; do
    command -v "$tool" >/dev/null 2>&1 || continue
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
}

# A push target that reads fine but refuses the write, echoing the given text as
# the server's own reason. git passes `remote:` lines through verbatim, so any
# redaction observed on them is this script's rather than git's own.
install_rejecting_fork() {
  local fork=$1 message=$2
  git init -q --bare "$fork"
  {
    printf '#!/bin/sh\n'
    printf 'cat <<%s >&2\n' "'FM_HOOK_MSG'"
    printf '%s\n' "$message"
    printf 'FM_HOOK_MSG\n'
    printf 'exit 1\n'
  } > "$fork/hooks/pre-receive"
  chmod +x "$fork/hooks/pre-receive"
}

run_status_toon() {
  local branch=$1 head=$2 review_state=$3
  printf 'run:\n  id: "01KZ5YTADR5YAXZSNKFXTW8W9F"\n  branch: %s\n  status: running\n  head: %s\n  steps[8]{step,status,findings,duration_ms}:\n    intent,completed,0,3\n    rebase,completed,0,581\n    review,%s,0,599904\n    test,completed,0,235507\n    document,completed,0,58499\n    lint,completed,0,78748\n    push,completed,0,2200\n    ci,awaiting_approval,1,99775564\ngate:\n  step: ci\n  status: awaiting_approval\n' \
    "$branch" "$head" "$review_state"
}

verify_out() {
  local repo=$1 head=$2
  ( cd "$repo" && "$ATTEST" verify --head "$head" 2>&1 )
}

# ---------------------------------------------------------------------------
# verify - absence, mis-binding and malformed evidence each refuse in their own
# words, and none of them can be reached by editing pull request text.
# ---------------------------------------------------------------------------

test_absent_notes_ref_refuses_as_absent() {
  local repo head out rc
  repo="$TMP_ROOT/absent-ref"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an absent attestation ref was accepted"
  assert_contains "$out" "no-attestation-ref" "absent ref did not report its own reason"
  pass "fm-attest.sh: an absent attestation ref refuses as absent"
}

test_ref_without_note_for_head_refuses_distinctly() {
  local repo head other out rc
  repo="$TMP_ROOT/ref-no-note"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  other=$(git -C "$repo" commit-tree -m other "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$other" "$(good_note "$other")"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a missing exact-head attestation did not return the verifier's refusal verdict (exit $rc): $out"
  assert_contains "$out" "no-attestation-for-head" "missing note for the head was not reported distinctly"
  assert_contains "$out" "$NOTES_REF exists but carries no attestation for $head." \
    "missing-note refusal evidence did not identify the exact unattested head"
  assert_not_contains "$out" "no-attestation-ref" "a present ref was reported as an absent one"
  pass "fm-attest.sh: an attestation for another commit is not evidence for this one"
}

test_unreadable_notes_ref_refuses_distinctly() {
  local repo head blob out rc
  repo="$TMP_ROOT/unreadable-ref"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # A ref that resolves but cannot be read as notes. Publishing a note can never
  # repair it, so it must not borrow the missing-note reason, whose repair is to
  # publish one.
  blob=$(printf 'not a notes tree\n' | git -C "$repo" hash-object -w --stdin)
  git -C "$repo" update-ref "$NOTES_REF" "$blob"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -eq 1 ] || fail "an unreadable attestation ref did not refuse as a verdict (exit $rc): $out"
  assert_contains "$out" "attestation-ref-unreadable" \
    "an unreadable ref did not report its own reason"
  assert_not_contains "$out" "no-attestation-for-head" \
    "an unreadable ref was reported as a missing note, which republishing can never repair"
  # The matched control, differing by one property: the same repository once the
  # ref again holds a readable notes commit carrying this head's attestation.
  git -C "$repo" update-ref -d "$NOTES_REF"
  add_note "$repo" "$head" "$(good_note "$head")"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the repaired ref was still refused: $out"
  assert_contains "$out" "attested $head" "the success line did not name the attested head"
  pass "fm-attest.sh: an attestation ref that cannot be read as notes is its own refusal"
}

test_note_naming_another_head_refuses_as_unbound() {
  local repo head other out rc
  repo="$TMP_ROOT/unbound"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  other=$(git -C "$repo" commit-tree -m other "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  # A well-formed attestation for a different commit, attached to this one.
  add_note "$repo" "$head" "$(good_note "$other")"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation naming another commit was accepted"
  assert_contains "$out" "attestation-not-bound" "a mis-bound attestation was not reported as such"
  pass "fm-attest.sh: an attestation must name the commit it is attached to"
}

test_genuine_attestation_does_not_survive_a_rewrite() {
  local repo head rewritten before after
  repo="$TMP_ROOT/rewrite"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" "$(good_note "$head")"
  before=$(verify_out "$repo" "$head")
  case "$before" in
    *"attested $head"*) ;;
    *) fail "the positive control did not pass before the rewrite: $before" ;;
  esac
  # Reword the commit and carry the genuine attestation across verbatim. This is
  # the copy that the replaced body marker permitted and this check must not.
  git -C "$repo" commit -q --amend -m "one (reworded)"
  rewritten=$(git -C "$repo" rev-parse HEAD)
  [ "$rewritten" != "$head" ] || fail "the rewrite did not change the head commit"
  git -C "$repo" notes --ref="$NOTES_REF" show "$head" > "$repo/carried.note"
  git -C "$repo" notes --ref="$NOTES_REF" add -f -F "$repo/carried.note" "$rewritten" >/dev/null 2>&1
  local rc=0
  after=$(verify_out "$repo" "$rewritten") || rc=$?
  [ "$rc" -ne 0 ] || fail "a genuine attestation copied onto a rewritten head was accepted"
  assert_contains "$after" "attestation-not-bound" "a carried attestation was not reported as unbound"
  pass "fm-attest.sh: a genuine attestation copied onto a rewritten head is refused"
}

test_legacy_body_marker_is_not_an_attestation() {
  local repo head out rc
  repo="$TMP_ROOT/legacy-marker"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" \
    'Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "the replaced honour-system marker was accepted as an attestation"
  assert_contains "$out" "attestation-malformed" "the legacy marker was not reported as malformed"
  pass "fm-attest.sh: the replaced honour-system marker is not an attestation"
}

test_unknown_field_refuses_rather_than_being_ignored() {
  local repo head out rc
  repo="$TMP_ROOT/unknown-field"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" "$(good_note "$head"; printf 'override: please-pass\n')"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation carrying an unknown field was accepted"
  assert_contains "$out" "attestation-malformed" "an unknown field was not reported as malformed"
  pass "fm-attest.sh: an unknown field is refused rather than ignored"
}

test_missing_required_step_refuses_distinctly() {
  local repo head out rc
  repo="$TMP_ROOT/missing-gate"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" \
    "$(good_note "$head" | sed 's/^gates: .*/gates: intent,rebase,test,document,lint,push/')"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation with no completed review step was accepted"
  assert_contains "$out" "attestation-missing-gate" "a skipped required step was not reported distinctly"
  assert_contains "$out" "review" "the refusal did not name the missing step"
  pass "fm-attest.sh: an attestation that skipped a required step is refused"
}

test_unusable_gate_list_refuses_as_malformed() {
  local repo head out rc
  repo="$TMP_ROOT/bad-gates"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" \
    "$(good_note "$head" | sed 's/^gates: .*/gates: review,,test,lint,push/')"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation with an unusable step list was accepted"
  assert_contains "$out" "attestation-malformed" "an unusable step list was not reported as malformed"
  pass "fm-attest.sh: an unusable step list is refused"
}

test_absent_head_commit_refuses_as_its_own_state() {
  local repo out rc missing
  repo="$TMP_ROOT/no-head-object"
  new_repo "$repo"
  missing=0123456789012345678901234567890123456789
  add_note "$repo" "$(git -C "$repo" rev-parse HEAD)" "$(good_note "$(git -C "$repo" rev-parse HEAD)")"
  out=$(verify_out "$repo" "$missing")
  rc=$?
  [ "$rc" -ne 0 ] || fail "verification of an absent commit was accepted"
  assert_contains "$out" "head-commit-unavailable" "an absent head commit was not reported as its own state"
  pass "fm-attest.sh: a head commit missing from the checkout is its own refusal"
}

test_head_bound_attestation_passes() {
  local repo head out rc
  repo="$TMP_ROOT/positive"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" "$(good_note "$head")"
  out=$(verify_out "$repo" "$head")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a well-formed head-bound attestation was refused: $out"
  assert_contains "$out" "attested $head" "the success line did not name the attested head"
  pass "fm-attest.sh: a well-formed head-bound attestation passes"
}

# ---------------------------------------------------------------------------
# write - the emitter transcribes the pipeline's own run record and refuses to
# publish anything that record does not support.
# ---------------------------------------------------------------------------

write_out() {
  local repo=$1
  ( cd "$repo" && PATH="$repo/stub/bin:$PATH" "$ATTEST" write --no-push 2>&1 )
}

# Publication on its own. write re-evaluates the head it published as its last
# step, and every case below is about what reaches the push target rather than
# about what GitHub is then asked to do, so that step is switched off here
# instead of being pointed at a stub each of them would have to carry. The
# recheck section owns that step, and one case there proves write still performs
# it by default, so switching it off here cannot hide it going missing.
publish_out() {
  local repo=$1 home=$1/fm-home
  mkdir -p "$home/config" "$home/data" || return 1
  ( cd "$repo" && PATH="$repo/stub/bin:$PATH" \
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ATTEST" write --no-recheck --publish-repo "$(publish_target "$repo")" \
      --publish-notes-ref "$NOTES_REF" 2>&1 )
}

# The same publication, asked to do nothing where no check reads the result.
# Deliberately the same command as publish_out plus one flag, so a difference in
# outcome can only be that flag.
publish_only_if_required_out() {
  local repo=$1 policy
  shift
  if [ -e "$repo/.github/no-mistakes-attestation" ] || [ -L "$repo/.github/no-mistakes-attestation" ]; then
    git -C "$repo" add .github/no-mistakes-attestation
    git -C "$repo" diff --cached --quiet || git -C "$repo" commit -qm policy
  fi
  policy=$(policy_remote "$repo" HEAD)
  ( cd "$repo" && PATH="$repo/stub/bin:$PATH" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$policy.insteadOf" \
      GIT_CONFIG_VALUE_0=https://github.com/fixture/policy.git \
      "$ATTEST" write --no-recheck --only-if-required \
      --publish-repo "$(publish_target "$repo")" \
      --publish-notes-ref "$NOTES_REF" \
      --policy-venue github.com/fixture/policy --policy-url https://github.com/fixture/policy.git \
      --policy-generation refs/heads/policy --policy-ref refs/heads/policy "$@" 2>&1 )
}

required_out() {
  local repo=$1 source_ref policy
  shift
  source_ref=${1:-HEAD}
  if [ -e "$repo/.github/no-mistakes-attestation" ] || [ -L "$repo/.github/no-mistakes-attestation" ]; then
    git -C "$repo" add .github/no-mistakes-attestation
    git -C "$repo" diff --cached --quiet || git -C "$repo" commit -qm policy
  fi
  policy=$(policy_remote "$repo" "$source_ref")
  ( cd "$repo" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$policy.insteadOf" \
      GIT_CONFIG_VALUE_0=https://github.com/fixture/policy.git \
      "$ATTEST" required --policy-venue github.com/fixture/policy \
      --policy-url https://github.com/fixture/policy.git \
      --policy-generation refs/heads/policy --policy-ref refs/heads/policy 2>&1 )
}

policy_remote() {
  local repo=$1 source_ref=$2 key policy
  key=$(printf '%s' "$repo" | cksum | awk '{ print $1 }')
  policy="$TMP_ROOT/policy-$key.git"
  [ -d "$policy" ] || git init -q --bare "$policy"
  git -C "$repo" push -q --force "$policy" "$source_ref:refs/heads/policy"
  git --git-dir="$policy" symbolic-ref HEAD refs/heads/policy
  printf '%s\n' "$policy"
}

# A repository whose workflow consumes the verifier and whose fixed marker
# declares that publication belongs there.
declare_gate() {
  local repo=$1 name=${2:-some-gate.yml}
  mkdir -p "$repo/.github/workflows"
  printf 'jobs:\n  check:\n    steps:\n      - run: bin/fm-attest.sh verify --head 0000\n' \
    > "$repo/.github/workflows/$name"
  printf 'fm-attest.v1 required\n' > "$repo/.github/no-mistakes-attestation"
}

# A workflow unrelated to this gate, with no declaration marker.
declare_unrelated_workflow() {
  local repo=$1 name=${2:-unrelated.yml}
  mkdir -p "$repo/.github/workflows"
  printf 'jobs:\n  build:\n    steps:\n      - run: make\n' > "$repo/.github/workflows/$name"
}

# A push target's published attestations, or nothing. Used as the observable for
# "was anything published", so a claim that nothing was published is read off
# the repository rather than off the absence of a message.
published_heads() {
  local fork=$1
  git -C "$fork" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 || return 0
  git -C "$fork" ls-tree -r --name-only "$NOTES_REF" | tr -d '/'
}

test_write_refuses_a_run_head_absent_from_this_checkout() {
  local repo head out rc
  repo="$TMP_ROOT/write-other-head"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo deadbeef completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run record naming a commit this checkout lacks was transcribed"
  assert_contains "$out" "run-head-unavailable" "an absent run head was not reported distinctly"
  # A commit this repository does not have is a fetch, not a re-validation, so
  # it must not borrow the reason for a run that covers different work.
  assert_not_contains "$out" "run-covers-another-head" \
    "a commit absent from the checkout was reported as a run covering other work"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "a refused attestation was still written"
  pass "fm-attest.sh: write refuses a run head that is not a commit in this checkout"
}

test_write_attests_the_run_tip_the_pipeline_advanced_past_head() {
  local repo head tip out rc verified
  repo="$TMP_ROOT/write-tip-ahead"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # The pipeline's own fix commits advance the run tip past the local checkout,
  # so a run head ahead of HEAD on the same history is the normal state and the
  # tip is the head the pull request is opened on.
  tip=$(git -C "$repo" commit-tree -p "$head" -m "no-mistakes(review): fix" \
    "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${tip:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a run tip ahead of HEAD on the same history was refused: $out"
  assert_contains "$out" "recorded $NOTES_REF for $tip" \
    "the note was not bound to the head that run validated"
  verified=$(verify_out "$repo" "$tip") \
    || fail "the gate rejected the attestation for the run tip: $verified"
  assert_contains "$verified" "attested $tip" "the run tip was not attested"
  rc=0
  out=$(verify_out "$repo" "$head") || rc=$?
  [ "$rc" -ne 0 ] || fail "a commit the run advanced past was attested too"
  assert_contains "$out" "no-attestation-for-head" \
    "the commit the run advanced past was not refused for its own reason"
  pass "fm-attest.sh: write attests the run tip the pipeline advanced past HEAD"
}

test_write_refuses_an_incomplete_run() {
  local repo head out rc
  repo="$TMP_ROOT/write-incomplete"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" running)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run with no completed review step was transcribed"
  assert_contains "$out" "run-incomplete" "an incomplete run was not reported distinctly"
  assert_contains "$out" "review" "the refusal did not name the incomplete step"
  pass "fm-attest.sh: write refuses a run that has not completed a required step"
}

test_write_refuses_a_run_from_another_branch() {
  local repo head out rc
  repo="$TMP_ROOT/write-other-branch"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/elsewhere "${head:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run record for another branch was transcribed"
  assert_contains "$out" "run-covers-another-branch" "a foreign branch run was not reported distinctly"
  pass "fm-attest.sh: write refuses a run record for another branch"
}

test_write_emits_an_attestation_the_gate_accepts() {
  local repo head out rc verified
  repo="$TMP_ROOT/write-positive"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a complete run covering this exact head was refused: $out"
  verified=$(verify_out "$repo" "$head") \
    || fail "the emitted attestation was rejected by the gate: $verified"
  assert_contains "$verified" "attested $head" "the round trip did not attest this head"
  assert_contains "$verified" "01KZ5YTADR5YAXZSNKFXTW8W9F" "the attestation lost the run identity"
  pass "fm-attest.sh: write emits an attestation the gate accepts for that exact head"
}

test_write_refuses_a_later_commit_on_the_same_branch() {
  local repo head later out rc
  repo="$TMP_ROOT/write-later-commit"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  write_out "$repo" >/dev/null || fail "the positive control failed before the later commit"
  printf 'two\n' > "$repo/b.txt"
  git -C "$repo" add b.txt
  git -C "$repo" commit -qm two
  later=$(git -C "$repo" rev-parse HEAD)
  [ "$later" != "$head" ] || fail "the later commit did not move the head"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unvalidated later commit was attested from the earlier run"
  assert_contains "$out" "run-covers-another-head" "the stale run was not reported distinctly"
  rc=0
  out=$(verify_out "$repo" "$later") || rc=$?
  [ "$rc" -ne 0 ] || fail "the gate accepted a head the pipeline never validated"
  assert_contains "$out" "no-attestation-for-head" "the unvalidated head was not refused for its own reason"
  pass "fm-attest.sh: work committed after a run is not covered by it"
}

test_write_refuses_without_a_run_record() {
  local repo out rc
  repo="$TMP_ROOT/write-no-run"
  new_repo "$repo"
  install_pipeline_stub "$repo/stub" ""
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation was emitted with no pipeline run record"
  assert_contains "$out" "no-run-record" "a missing run record was not reported distinctly"
  # The stub reported nothing on stdout and only the upgrade banner on stderr.
  # An absent run must stay an absent run, and the banner must still be shown.
  assert_not_contains "$out" "run-record-unparsed" \
    "an unrelated stderr notice was read as a run record"
  assert_contains "$out" "$STUB_STDERR_NOTICE" "the tool's stderr was not surfaced as detail"
  pass "fm-attest.sh: write refuses when the pipeline reports no run"
}

test_write_surfaces_a_tool_failure_instead_of_reporting_no_run() {
  local repo out rc
  repo="$TMP_ROOT/write-tool-error"
  new_repo "$repo"
  # The real tool reports its own errors on stdout, so the captured output looks
  # like a run record to anything that only checks for emptiness. This is the
  # case where it also exits non-zero; the case where it does not is below.
  install_pipeline_stub "$repo/stub" \
    "error: repo not initialized (run 'no-mistakes init' first)" 1
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation was emitted while the pipeline tool was failing"
  assert_contains "$out" "run-record-unreadable" "a failing tool was not reported distinctly"
  assert_contains "$out" "repo not initialized" "the tool's own message was swallowed"
  assert_contains "$out" "$STUB_STDERR_NOTICE" "the tool's stderr was not surfaced as detail"
  assert_not_contains "$out" "no-run-record" "a failing tool was reported as an absent run"
  pass "fm-attest.sh: write surfaces a failing pipeline tool rather than reporting no run"
}

# The same refusal without the non-zero exit, which is what the real tool does:
# `repo not initialized` is written to stdout and the tool exits 0 (measured
# 2026-08-18 against v1.40.3). Judged on the exit status alone it is a run
# record, every field reads as absent from it, and the refusal reached says this
# transcription needs updating - which is a repair to the wrong thing, on the
# one path a contributor takes to clear the `Require no-mistakes` check.
test_write_reports_a_refusing_tool_that_exited_zero_as_a_refusing_tool() {
  local repo head out rc
  repo="$TMP_ROOT/write-tool-error-zero"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" \
    "error: repo not initialized (run 'no-mistakes init' first)" 0
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation was emitted while the pipeline tool was refusing"
  assert_contains "$out" "run-record-unreadable" "a refusing tool was not reported distinctly"
  assert_contains "$out" "repo not initialized" "the tool's own message was swallowed"
  assert_not_contains "$out" "run-record-unparsed" \
    "a tool that refused was reported as a run record this transcription cannot read"
  assert_not_contains "$out" "no-run-record" "a refusing tool was reported as an absent run"

  # A run record carrying an `error` field of its own is a fact about that run,
  # not the tool declining to report one, so the record still attests. Without
  # this the refusal above could be had by treating any `error` anywhere as the
  # tool refusing, which would refuse every failed run's record.
  install_pipeline_stub "$repo/stub" \
    "$(run_status_toon fm/demo "${head:0:8}" completed)
error: the review step reported 1 finding"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a run record naming an error of its own was read as a refusing tool: $out"

  # The matched control: the same call on the same repository, differing only in
  # that the tool reported its record rather than a refusal.
  git -C "$repo" update-ref -d "$NOTES_REF"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused when the tool reported a run: $out"
  pass "fm-attest.sh: a pipeline tool that refused without a non-zero exit is a refusing tool"
}

test_write_reports_a_record_with_no_head_as_a_record_fault() {
  local repo head out rc
  repo="$TMP_ROOT/write-record-no-head"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # The passing record minus exactly one property: the head it covers.
  install_pipeline_stub "$repo/stub" \
    "$(run_status_toon fm/demo "${head:0:8}" completed | sed '/^  head: /d')"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a run record naming no head was transcribed"
  assert_contains "$out" "run-record-no-head" "a record with no readable head was not reported distinctly"
  # Unreadability is not divergence. Saying the branch is uncovered sends a
  # contributor to re-validate a branch that is fine, for the identical refusal.
  assert_not_contains "$out" "run-covers-another-head" \
    "a record this transcription cannot read was reported as a diverged branch"
  assert_not_contains "$out" "run-head-unavailable" \
    "a record with no head was reported as a commit missing from the checkout"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "a refused attestation was still written"
  # The matched control: the same record, differing only by that one line.
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same record with its head line was refused: $out"
  pass "fm-attest.sh: a run record with no readable head is a record fault, not a diverged branch"
}

test_write_attests_on_a_host_with_no_timeout_utility() {
  local repo bare head out rc tool verified
  repo="$TMP_ROOT/write-unbounded"
  bare="$TMP_ROOT/write-unbounded-path"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  install_unbounded_path "$bare"
  for tool in timeout gtimeout perl; do
    PATH="$repo/stub/bin:$bare" command -v "$tool" >/dev/null 2>&1 \
      && fail "the fixture PATH still offers $tool, so this would not exercise the fallback"
  done
  out=$(cd "$repo" && PATH="$repo/stub/bin:$bare" "$ATTEST" write --no-push 2>&1)
  rc=$?
  # The repository's own policy: bin/fm-timeout-lib.sh falls back to a
  # dependency-free bash watchdog, so such a host is bounded rather than turned
  # away from the one command CONTRIBUTING.md prescribes.
  [ "$rc" -eq 0 ] || fail "a host with no timeout utility could not attest at all: $out"
  verified=$(verify_out "$repo" "$head") \
    || fail "the attestation written on that host was rejected by the gate: $verified"
  assert_contains "$verified" "attested $head" "the round trip did not attest this head"
  # The matched control: the same repository and record on a PATH that does
  # offer one, which must reach the same verdict rather than a different one.
  git -C "$repo" update-ref -d "$NOTES_REF"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same run record was refused where a timeout utility exists: $out"
  pass "fm-attest.sh: a host with no timeout, gtimeout or perl still attests under the shared bash bound"
}

test_write_reports_an_unreadable_run_record_distinctly() {
  local repo out rc
  repo="$TMP_ROOT/write-unparsed-run"
  new_repo "$repo"
  # A successful call whose output carries no run identity: a record that exists
  # but cannot be read is a different repair from a record that does not exist.
  install_pipeline_stub "$repo/stub" "runs: none matching this worktree"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an attestation was emitted from an unreadable run record"
  assert_contains "$out" "run-record-unparsed" "an unreadable run record was not reported distinctly"
  assert_contains "$out" "none matching this worktree" "the reported record was not quoted back"
  assert_contains "$out" "$STUB_STDERR_NOTICE" "the tool's stderr was not surfaced as detail"
  assert_not_contains "$out" "no-run-record" "an unreadable record was reported as an absent run"
  pass "fm-attest.sh: write distinguishes an unreadable run record from an absent one"
}

test_write_publishes_to_the_push_target_it_reconciled_against() {
  local repo parent fork head parent_seed fork_seed local_only out rc published
  repo="$TMP_ROOT/write-push-target"
  parent="$TMP_ROOT/write-push-target-parent.git"
  fork="$TMP_ROOT/write-push-target-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$parent"
  git init -q --bare "$fork"
  # Two unrelated attestation histories, one already published in each
  # repository, so reconciling against the wrong one cannot fast-forward into
  # the other. This is the setup CONTRIBUTING.md describes: origin fetches the
  # parent and pushes the contributor's fork.
  parent_seed=$(git -C "$repo" commit-tree -m parent-seed "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$parent_seed" "$(good_note "$parent_seed")"
  git -C "$repo" push -q "$parent" "$NOTES_REF:$NOTES_REF"
  git -C "$repo" update-ref -d "$NOTES_REF"
  fork_seed=$(git -C "$repo" commit-tree -m fork-seed "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$fork_seed" "$(good_note "$fork_seed")"
  git -C "$repo" push -q "$fork" "$NOTES_REF:$NOTES_REF"
  git -C "$repo" update-ref -d "$NOTES_REF"
  # An attestation held locally only, which publishing a later one must not
  # discard.
  local_only=$(git -C "$repo" commit-tree -m local-only "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$local_only" "$(good_note "$local_only")"

  git -C "$repo" remote add origin "$parent"
  git -C "$repo" config remote.origin.pushurl "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "publishing to the remote's push target was refused: $out"
  # The repository the note actually reached, because a remote's name does not
  # say which repository that is and only one of these two is the one the gate
  # reads.
  assert_contains "$out" "published $NOTES_REF to $fork" \
    "the success line did not name the repository the note reached"
  assert_not_contains "$out" "$parent" "the fetch URL was reported as the published target"
  published=$(git -C "$fork" ls-tree -r --name-only "$NOTES_REF" | tr -d '/')
  assert_contains "$published" "$head" "the attested head never reached the push target"
  assert_contains "$published" "$fork_seed" "publishing discarded the push target's own attestation"
  assert_not_contains "$published" "$parent_seed" \
    "the fetch URL's attestation history was published to the push target"
  assert_contains "$(git -C "$repo" notes --ref="$NOTES_REF" list)" "$local_only" \
    "publishing discarded an attestation recorded with --no-push"
  pass "fm-attest.sh: write reconciles with and publishes to the remote's push target"
}

test_write_publishes_a_first_attestation_to_a_push_target_with_no_ref() {
  local repo fork head out rc published
  repo="$TMP_ROOT/write-first-publish"
  fork="$TMP_ROOT/write-first-publish-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  # A push target that carries no attestation ref yet genuinely has nothing to
  # reconcile against, which is the one reading of a failed read that is a fact
  # about that repository rather than about our ability to reach it.
  [ "$rc" -eq 0 ] || fail "a push target with no attestation ref yet was refused: $out"
  assert_contains "$out" "published $NOTES_REF to $fork" \
    "the success line did not name the repository the note reached"
  published=$(git -C "$fork" ls-tree -r --name-only "$NOTES_REF" | tr -d '/')
  assert_contains "$published" "$head" "the first attestation never reached the push target"
  pass "fm-attest.sh: a push target with no attestation ref yet still receives the note"
}

# --- the publication guard, reached through this real path --------------------
#
# bin/fm-publication-seam-lib.sh decides whether a publication may happen, and
# these two cases are the only evidence that THIS command reaches that decision
# rather than pushing beside it. They are a pair on one perturbation: the same
# fixture publishes when the home declares no publication governance and refuses
# when it declares governance this push target cannot be placed under.
#
# The refusal is asserted from the push target's own state, not from an exit
# code, because a command that refused everything would produce the same code.

publish_out_home() {  # <repo> <home>
  ( cd "$1" && PATH="$1/stub/bin:$PATH" \
    FM_HOME="$2" FM_CONFIG_OVERRIDE="$2/config" FM_DATA_OVERRIDE="$2/data" \
    "$ATTEST" write --no-recheck 2>&1 )
}

test_write_publishes_ungoverned_and_says_so() {
  local repo fork home head out rc
  repo="$TMP_ROOT/write-ungoverned"
  fork="$TMP_ROOT/write-ungoverned-fork.git"
  home="$TMP_ROOT/write-ungoverned-home"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  mkdir -p "$home/config" "$home/data"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out_home "$repo" "$home")
  rc=$?
  [ "$rc" -eq 0 ] || fail "an ungoverned publication was refused: $out"
  # REPORTED, not silent. The failure this replaces is a home that looks
  # authorised because nothing spoke.
  assert_contains "$out" "ungoverned" \
    "an ungoverned publication did not say that it was ungoverned: $out"
  assert_contains "$(git -C "$fork" ls-tree -r --name-only "$NOTES_REF" | tr -d '/')" "$head" \
    "the ungoverned publication never reached the push target"
  pass "fm-attest.sh: an ungoverned publication proceeds and reports that it was ungoverned"
}

test_write_refuses_to_publish_when_governance_cannot_be_established() {
  local repo fork home head out rc
  repo="$TMP_ROOT/write-governed"
  fork="$TMP_ROOT/write-governed-fork.git"
  home="$TMP_ROOT/write-governed-home"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  mkdir -p "$home/config" "$home/data"
  # THE ONE PERTURBATION: this home has opted into publication governance, and
  # the policy does not name this push target. Once governance is declared, a
  # target nobody can place is could-not-observe rather than a way around it.
  printf '{"generation":"pol-1","venues":{"github.com/declared/elsewhere":{}}}\n' \
    > "$home/config/publication-identity.json"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out_home "$repo" "$home")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a publication that could not be placed under this home's governance was published: $out"
  assert_contains "$out" "attestation-not-published" \
    "the refusal was not reported as a publication that did not happen: $out"
  # THE PUSH TARGET'S OWN STATE, which is the only thing that settles it.
  git -C "$fork" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "the push target received $NOTES_REF although the publication was refused"
  pass "fm-attest.sh: a publication this home's governance cannot place is refused, and the push target is unchanged"
}

test_write_publishes_attestation_evidence_to_a_governed_venue() {
  local repo fork home head out rc
  repo="$TMP_ROOT/write-governed-attestation"
  fork="$TMP_ROOT/write-governed-attestation-fork.git"
  home="$TMP_ROOT/write-governed-attestation-home"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  mkdir -p "$home/config" "$home/data"
  printf '{"generation":"pol-1","venues":{"-":{}}}\n' \
    > "$home/config/publication-identity.json"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out_home "$repo" "$home")
  rc=$?
  [ "$rc" -eq 0 ] || fail "governed attestation evidence was refused: $out"
  assert_contains "$out" "under a spent publication authority" \
    "governed attestation evidence did not report its authority: $out"
  assert_contains "$(git -C "$fork" ls-tree -r --name-only "$NOTES_REF" | tr -d '/')" "$head" \
    "governed attestation evidence never reached the trusted target"
  pass "fm-attest.sh: governed attestation evidence publishes through an exact one-use authority"
}

test_write_refuses_an_unintended_attestation_evidence_ref() {
  local repo fork home head out rc unintended
  repo="$TMP_ROOT/write-governed-unintended"
  fork="$TMP_ROOT/write-governed-unintended-fork.git"
  home="$TMP_ROOT/write-governed-unintended-home"
  unintended=refs/notes/unintended
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  mkdir -p "$home/config" "$home/data"
  printf '{"generation":"pol-1","venues":{"-":{}}}\n' \
    > "$home/config/publication-identity.json"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && PATH="$repo/stub/bin:$PATH" \
    FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$ATTEST" write --no-recheck --notes-ref "$unintended" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unintended attestation evidence ref was published: $out"
  assert_contains "$out" 'FM_PUB_EFFECT_CLASS_MISMATCH' \
    "the unintended ref refusal did not identify the effect mismatch: $out"
  git -C "$fork" rev-parse --verify --quiet "$unintended" >/dev/null 2>&1 \
    && fail "the unintended attestation evidence ref reached the remote"
  pass "fm-attest.sh: attestation evidence cannot publish an unintended ref"
}

test_write_reports_the_rejection_reason_with_credentials_redacted() {
  local repo fork head out rc
  repo="$TMP_ROOT/write-push-rejected"
  fork="$TMP_ROOT/write-push-rejected-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  # A push target that reads fine but refuses the write, and explains why in the
  # server's own words. `remote:` text is passed through verbatim by git, so a
  # credentialed URL inside it is the one form this fixture controls exactly:
  # whatever redaction happens to it is ours, not git's.
  {
    printf '#!/bin/sh\n'
    printf 'echo "refs/notes/* is blocked by a ruleset" >&2\n'
    printf 'echo "retry against https://someone:s3cr3t@example.invalid/owner/repo.git" >&2\n'
    printf 'exit 1\n'
  } > "$fork/hooks/pre-receive"
  chmod +x "$fork/hooks/pre-receive"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  assert_contains "$out" "attestation-not-published" \
    "a rejected push did not report its own reason"
  assert_contains "$out" "Could not publish $NOTES_REF to $fork" \
    "the refusal did not name the repository it could not publish to"
  # The reason the server gave must reach the person who has to act on it:
  # suppressing it leaves a ruleset or quota rejection undiagnosable.
  assert_contains "$out" "refs/notes/* is blocked by a ruleset" \
    "the server's own rejection reason was discarded"
  # And it must arrive with the credential stripped out of the URL it named.
  assert_contains "$out" "https://example.invalid/owner/repo.git" \
    "the redacted URL did not survive redaction"
  assert_not_contains "$out" "s3cr3t" "a credential in the remote's text reached the caller"
  # The matched control: the same repository and the same remote, differing only
  # in that this push target accepts the write.
  rm -f "$fork/hooks/pre-receive"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "publishing was refused once the same target accepted writes: $out"
  assert_contains "$out" "published $NOTES_REF to $fork" \
    "the success line did not name the repository the note reached"
  pass "fm-attest.sh: a rejected push reports the server's reason with credentials redacted"
}

test_write_refuses_an_unreadable_push_target_without_leaking_credentials() {
  local repo parent head out rc
  repo="$TMP_ROOT/write-unreadable-target"
  parent="$TMP_ROOT/write-unreadable-target-parent.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$parent"
  git -C "$repo" remote add origin "$parent"
  # A push target that cannot be read at all, carrying a secret in its URL as a
  # remote's configuration may. Nothing listens on port 1, so the read fails
  # locally without reaching any network.
  git -C "$repo" config remote.origin.pushurl 'https://someone:s3cr3t@127.0.0.1:1/owner/repo.git'
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && GIT_TERMINAL_PROMPT=0 no_proxy='*' NO_PROXY='*' \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write --publish-repo "$(publish_target "$repo")" --publish-notes-ref "$NOTES_REF" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable push target was treated as one with no attestations"
  assert_contains "$out" "127.0.0.1:1/owner/repo.git" \
    "the refusal did not name the repository it could not read"
  assert_not_contains "$out" "s3cr3t" "the push target's credentials were printed"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "an attestation was recorded against a push target that was never read"
  pass "fm-attest.sh: an unreadable push target stops the command rather than reading as an absent one"
}

test_write_emits_only_positively_safe_urls() {
  local repo fork head out rc
  repo="$TMP_ROOT/redact-shapes"
  fork="$TMP_ROOT/redact-shapes-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_rejecting_fork "$fork" "$(printf '%s\n' \
    'none https://plain.invalid/o/r.git' \
    'user https://alice@u1.invalid/o/r.git' \
    'userpass https://alice:hunter2@u2.invalid/o/r.git' \
    'at-in-pass https://alice:pw@word@u3.invalid/o/r.git' \
    'colon-in-pass https://alice:pw:word@u4.invalid/o/r.git' \
    'encoded-at https://alice:pw%40word@u5.invalid/o/r.git' \
    'encoded-slash https://alice:s%2Fs@u9.invalid/o/r.git' \
    'explicit-port https://alice:pw@u7.invalid:8443/o/r.git' \
    'ipv6-host https://alice:pw@[2001:db8::1]/o/r.git' \
    'scp-style git@u15.invalid:o/r.git' \
    "trailing-garbage 'https://alice:pw@u13.invalid/r.git')," \
    'unparseable https://alice:pa/ss@u8.invalid/x')"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  # A URL is emitted only in a form that positively matches a shape with no
  # userinfo at all, so what reaches the caller is the repository it names.
  assert_contains "$out" "https://plain.invalid/o/r.git" "a URL with no userinfo was altered"
  assert_contains "$out" "https://u1.invalid/o/r.git" "a user-only URL was not rewritten to its host"
  assert_contains "$out" "https://u2.invalid/o/r.git" "a user:password URL was not rewritten to its host"
  assert_contains "$out" "https://u3.invalid/o/r.git" \
    "a password holding an unencoded @ was not rewritten to its host"
  assert_contains "$out" "https://u4.invalid/o/r.git" "a password holding a colon was not rewritten"
  assert_contains "$out" "https://u5.invalid/o/r.git" "a percent-encoded password was not rewritten"
  assert_contains "$out" "https://u9.invalid/o/r.git" "a percent-encoded slash was not rewritten"
  assert_contains "$out" "https://u7.invalid:8443/o/r.git" "an explicit port was not preserved"
  assert_contains "$out" "https://[2001:db8::1]/o/r.git" "an IPv6 literal host was not preserved"
  assert_contains "$out" "u15.invalid:o/r.git" "an scp-style remote was not named by its host and path"
  assert_not_contains "$out" "git@u15.invalid" "an scp-style remote kept its user"
  assert_contains "$out" "https://u13.invalid/r.git" "punctuation around a URL defeated the rewrite"
  # No fragment of any credential survives, whatever shape it took.
  assert_not_contains "$out" "alice" "a username reached the caller"
  assert_not_contains "$out" "hunter2" "a plain password reached the caller"
  assert_not_contains "$out" "pw@word" "a password holding an unencoded @ reached the caller"
  assert_not_contains "$out" "word@u3" "a fragment of that password reached the caller"
  assert_not_contains "$out" "pw:word" "a password holding a colon reached the caller"
  assert_not_contains "$out" "pw%40word" "a percent-encoded password reached the caller"
  assert_not_contains "$out" "s%2Fs" "a percent-encoded slash password reached the caller"
  # The pairing that stops this passing under blanket suppression: the one shape
  # here that cannot be positively parsed is withheld while the rest are shown.
  assert_not_contains "$out" "pa/ss" "a password holding an unencoded slash reached the caller"
  assert_not_contains "$out" "u8.invalid" "a URL that could not be positively parsed was emitted"
  assert_contains "$out" "withheld in full" "the withheld URL was dropped without saying so"
  pass "fm-attest.sh: a URL reaches the caller only in a form with no userinfo at all"
}

test_write_withholds_a_push_target_it_cannot_positively_parse() {
  local repo parent head out rc
  repo="$TMP_ROOT/redact-unlocatable"
  parent="$TMP_ROOT/redact-unlocatable-parent.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$parent"
  git -C "$repo" remote add origin "$parent"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  # A push URL no reader here models, because the credential holds a space.
  # Emitting it because nothing recognised a credential in it is the fail-open
  # hole this design exists to close.
  git -C "$repo" config remote.origin.pushurl 'https://someone:pa ss@127.0.0.1:1/owner/repo.git'
  out=$(cd "$repo" && GIT_TERMINAL_PROMPT=0 no_proxy='*' NO_PROXY='*' \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write --publish-repo "$(publish_target "$repo")" --publish-notes-ref "$NOTES_REF" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable push target was published to"
  assert_contains "$out" "withheld in full" "a URL that could not be positively parsed was emitted"
  assert_not_contains "$out" "pa ss" "the credential reached the caller"
  assert_not_contains "$out" "someone" "the credential's user reached the caller"
  # The space splits this URL into two words, and its tail alone matches the
  # scp-style shape. Emitting that beside the marker names a host and path that
  # were never a remote, so the whole target must go, not the half that parsed.
  assert_not_contains "$out" "credential-free> 127.0.0.1" \
    "the tail of a split URL was emitted beside the marker as a remote of its own"
  assert_contains "$out" "credential-free>, the push target of origin" \
    "the marker was not the whole target, so part of a split URL survived beside it"
  # Deliberate rather than incidental: the same unreachable target, differing
  # only in that this URL does positively parse, is named rather than withheld.
  git -C "$repo" config remote.origin.pushurl 'https://someone:passphrase@127.0.0.1:1/owner/repo.git'
  out=$(cd "$repo" && GIT_TERMINAL_PROMPT=0 no_proxy='*' NO_PROXY='*' \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write --publish-repo "$(publish_target "$repo")" --publish-notes-ref "$NOTES_REF" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable push target was published to"
  assert_contains "$out" "https://127.0.0.1:1/owner/repo.git" \
    "a push target that positively parses was not named"
  assert_not_contains "$out" "passphrase" "the credential reached the caller"
  pass "fm-attest.sh: a push target that cannot be positively parsed is withheld, not emitted"
}

test_write_names_an_scp_style_push_target() {
  local repo parent head out rc
  repo="$TMP_ROOT/scp-push-target"
  parent="$TMP_ROOT/scp-push-target-parent.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$parent"
  git -C "$repo" remote add origin "$parent"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  # The form CONTRIBUTING.md prescribes. It must be named, because a contributor
  # who cannot see which repository the note reached cannot tell their fork from
  # the parent, and this form has no password field to protect.
  git -C "$repo" config remote.origin.pushurl 'git@u14.invalid:owner/repo.git'
  out=$(cd "$repo" && GIT_SSH_COMMAND=false GIT_TERMINAL_PROMPT=0 \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write --publish-repo "$(publish_target "$repo")" --publish-notes-ref "$NOTES_REF" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable push target was published to"
  assert_contains "$out" "u14.invalid:owner/repo.git" "an scp-style push target was not named"
  assert_not_contains "$out" "git@u14.invalid" "the scp-style push target kept its user"
  # The matched control, differing by one property: a colon before the @ means
  # this is not that shape, because that is where a password lives. It must be
  # withheld entirely rather than emitted with the password stripped off.
  git -C "$repo" config remote.origin.pushurl 'someone:hunter2@u14.invalid:owner/repo.git'
  out=$(cd "$repo" && GIT_SSH_COMMAND=false GIT_TERMINAL_PROMPT=0 \
    PATH="$repo/stub/bin:$PATH" "$ATTEST" write --publish-repo "$(publish_target "$repo")" --publish-notes-ref "$NOTES_REF" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable push target was published to"
  assert_contains "$out" "withheld in full" "a token with a colon before its @ was not withheld"
  assert_not_contains "$out" "hunter2" "the password reached the caller"
  assert_not_contains "$out" "u14.invalid:owner/repo.git" \
    "a token with a colon before its @ was emitted with its password stripped instead of withheld"
  pass "fm-attest.sh: an scp-style push target is named, and a colon before its user is not"
}

test_write_withholds_the_whole_line_a_withheld_url_sat_on() {
  local repo fork head out rc
  repo="$TMP_ROOT/line-withheld"
  fork="$TMP_ROOT/line-withheld-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # Words are split on spaces, so half a URL can match a shape the whole never
  # would. Emitting the safe half beside a marker reads as two places where
  # there was one, so the line goes whole.
  install_rejecting_fork "$fork" "$(printf '%s\n' \
    'mixed push failed for https://user:pa/ss@bad.invalid/x see https://companion.invalid/o/r.git' \
    'clean see https://alone.invalid/o/r.git' \
    'refs/notes/* is blocked by a ruleset')"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  assert_contains "$out" "withheld in full" "a line holding a withheld URL was dropped without saying so"
  assert_not_contains "$out" "pa/ss" "the credential reached the caller"
  assert_not_contains "$out" "bad.invalid" "the URL that could not be parsed was emitted"
  # The control that proves line granularity rather than reworded marker text:
  # this URL is safe on its own and would survive per-word withholding.
  assert_not_contains "$out" "companion.invalid" \
    "a safe URL sharing a line with a withheld one survived, so withholding is still per word"
  # The pairing, so this is not blanket suppression: a clean line is untouched,
  # and so is the server's own reason.
  assert_contains "$out" "https://alone.invalid/o/r.git" "a line with nothing withheld was suppressed"
  assert_contains "$out" "refs/notes/* is blocked by a ruleset" \
    "the server's own rejection reason was suppressed along with the URLs"
  pass "fm-attest.sh: a line holding a URL that cannot be parsed is withheld whole"
}

test_write_withholds_url_shapes_no_reader_models() {
  local repo fork head out rc
  repo="$TMP_ROOT/default-deny"
  fork="$TMP_ROOT/default-deny-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # Shapes that no reader here models. Under redact-what-you-recognise each of
  # these was emitted verbatim, because nothing recognised a credential in them.
  install_rejecting_fork "$fork" "$(printf '%s\n' \
    'refs/notes/* is blocked by a ruleset' \
    'safe https://safe.invalid/o/r.git' \
    'no-scheme alice:pw@u10.invalid/r.git' \
    'colon-before-at bob:hunter2@u11.invalid:o/r.git' \
    'at-after-authority https://u6.invalid/o/r.git@v2' \
    'unfamiliar weird+scheme://a:b/c@d:e/f?g#h')"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  assert_contains "$out" "withheld in full" "a URL-shaped token was dropped without saying so"
  assert_not_contains "$out" "alice" "a credential in a URL with no scheme reached the caller"
  assert_not_contains "$out" "u10.invalid" "a URL with no scheme was emitted"
  # The guard on the scp-style shape. Its colon separates host from path, which
  # is what makes that form credential-free, so a colon BEFORE the @ means this
  # is not that shape: it is where a password lives. Emitting anything at all
  # here, even with the password stripped, is an unproven shape being emitted.
  assert_not_contains "$out" "hunter2" "a password before the @ reached the caller"
  assert_not_contains "$out" "u11.invalid" \
    "a token with a colon before its @ was emitted as though it were an scp-style remote"
  assert_not_contains "$out" "u6.invalid" "a URL with an @ after its authority was emitted"
  # The class control: a deliberately unfamiliar URL-shaped token that no reader
  # models must be withheld. Emitting it is what "unmatched means safe" looks
  # like, and it is the shape that proves the default is deny.
  assert_not_contains "$out" "a:b/c@d:e" "an unfamiliar URL-shaped token was emitted"
  assert_not_contains "$out" "weird+scheme" "an unfamiliar URL-shaped token was emitted"
  # The pairing, twice over: withholding is not blanket. A URL that positively
  # parses still reaches the caller, and so does the server's own reason.
  assert_contains "$out" "https://safe.invalid/o/r.git" "a positively safe URL was withheld"
  assert_contains "$out" "refs/notes/* is blocked by a ruleset" \
    "the server's own rejection reason was withheld along with the URLs"
  pass "fm-attest.sh: a URL-shaped token no reader models is withheld rather than emitted"
}

test_write_withholds_a_url_carrying_a_query_or_fragment() {
  local repo fork head out rc
  repo="$TMP_ROOT/query-fragment"
  fork="$TMP_ROOT/query-fragment-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # A query string or fragment is a place a token credential lives, so a form
  # carrying either is not credential-free however safe its authority looks.
  install_rejecting_fork "$fork" "$(printf '%s\n' \
    'refs/notes/* is blocked by a ruleset' \
    'safe https://safe.invalid/o/r.git' \
    'query https://q1.invalid/o/r.git?private_token=SECRET123' \
    'fragment https://q2.invalid/o/r.git#access_token=SECRET456' \
    'mixed https://alice:pw@q3.invalid/o/r.git?token=SECRET789')"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected push was reported as a publication"
  assert_contains "$out" "withheld in full" "a URL carrying a query was dropped without saying so"
  assert_not_contains "$out" "SECRET123" "a query-string credential reached the caller"
  assert_not_contains "$out" "q1.invalid" "a URL carrying a query was emitted"
  assert_not_contains "$out" "SECRET456" "a fragment credential reached the caller"
  assert_not_contains "$out" "q2.invalid" "a URL carrying a fragment was emitted"
  # The mixed shape: stripping the userinfo used to leave a form that emitted
  # with its query token intact. The whole line must go instead.
  assert_not_contains "$out" "SECRET789" "a query credential survived beside a stripped userinfo"
  assert_not_contains "$out" "q3.invalid" \
    "a userinfo URL carrying a query was emitted with only its userinfo stripped"
  assert_not_contains "$out" "alice" "the userinfo reached the caller"
  # The pairing, so this is not blanket suppression: a query-free URL and the
  # server's own reason still reach the caller.
  assert_contains "$out" "https://safe.invalid/o/r.git" "a query-free URL was withheld"
  assert_contains "$out" "refs/notes/* is blocked by a ruleset" \
    "the server's own rejection reason was withheld along with the URLs"
  pass "fm-attest.sh: a URL whose emitted form carries a query or fragment is withheld"
}

# The pipeline tool's own two streams are text from outside this script exactly
# as git's are, and all four run-record refusals quote them. Redaction is a
# property of printing rather than of each call site remembering, so these four
# get it without asking for it.
LEAKY_STDOUT_URL='https://alice:hunter2@u20.invalid/o/r.git'
LEAKY_STDERR_URL='https://bob:s3cr3t@u21.invalid/o/r.git'

assert_tool_stream_made_safe() {
  local out=$1 reason=$2 kept=$3 host=$4
  assert_contains "$out" "$reason" "the refusal lost its own reason"
  assert_not_contains "$out" "hunter2" "a password on the tool's stdout reached the caller"
  assert_not_contains "$out" "s3cr3t" "a password on the tool's stderr reached the caller"
  assert_not_contains "$out" "alice" "a username on the tool's stdout reached the caller"
  assert_not_contains "$out" "bob" "a username on the tool's stderr reached the caller"
  # The pairing, so this cannot pass by suppressing the diagnostic instead of
  # redacting it: what the tool said still reaches the person who has to act.
  assert_contains "$out" "$kept" "the tool's own words were discarded rather than made safe"
  assert_contains "$out" "$host" "the URL the tool named was withheld rather than shown without its userinfo"
}

test_write_makes_the_pipeline_tools_own_streams_safe_to_print() {
  local repo head out
  repo="$TMP_ROOT/tool-stream-redaction"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)

  # run-record-unreadable: the tool failed, and reports its own error on stdout.
  install_pipeline_stub "$repo/stub" \
    "error: repo not initialized, retry against $LEAKY_STDOUT_URL" 1 \
    "upgrade available from $LEAKY_STDERR_URL"
  out=$(write_out "$repo")
  assert_tool_stream_made_safe "$out" run-record-unreadable "repo not initialized" \
    'https://u20.invalid/o/r.git'
  assert_contains "$out" 'https://u21.invalid/o/r.git' \
    "the tool's stderr was withheld rather than shown without its userinfo"

  # no-run-record: nothing on stdout, so only stderr is quoted.
  install_pipeline_stub "$repo/stub" "" 0 "upgrade available from $LEAKY_STDERR_URL"
  out=$(write_out "$repo")
  assert_tool_stream_made_safe "$out" no-run-record "upgrade available" \
    'https://u21.invalid/o/r.git'

  # run-record-unparsed: stdout was not empty, but no run identity is in it.
  install_pipeline_stub "$repo/stub" \
    "runs: none matching this worktree, see $LEAKY_STDOUT_URL" 0 \
    "upgrade available from $LEAKY_STDERR_URL"
  out=$(write_out "$repo")
  assert_tool_stream_made_safe "$out" run-record-unparsed "none matching this worktree" \
    'https://u20.invalid/o/r.git'

  # run-record-no-head: a run record this transcription cannot read a head from.
  install_pipeline_stub "$repo/stub" \
    "$(run_status_toon fm/demo "${head:0:8}" completed | sed '/^  head: /d'
      printf '  detail: %s\n' "$LEAKY_STDOUT_URL")"
  out=$(write_out "$repo")
  assert_tool_stream_made_safe "$out" run-record-no-head "01KZ5YTADR5YAXZSNKFXTW8W9F" \
    'https://u20.invalid/o/r.git'

  # The matched positive control: the same tool, the same streams, differing
  # only in that this record is complete. Redaction must not have cost the
  # emitter its ability to read a record at all.
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)" 0 \
    "upgrade available from $LEAKY_STDERR_URL"
  local rc=0
  out=$(write_out "$repo") || rc=$?
  [ "$rc" -eq 0 ] || fail "a complete run record was refused once its streams were redacted: $out"
  pass "fm-attest.sh: every run-record refusal quotes the tool's streams with credentials made safe"
}

test_write_rejects_a_zero_bound_rather_than_running_the_read_unbounded() {
  local repo head out rc
  repo="$TMP_ROOT/zero-timeout"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_hanging_pipeline_stub "$repo/stub"
  # bin/fm-timeout-lib.sh states the rule for every caller: `timeout 0` and the
  # perl fallback's `alarm 0` both disable the deadline, so a zero that reached
  # the runner would be no bound at all. The bound below is this test's own, and
  # reaching it is exactly the regression.
  out=$(cd "$repo" && fm_run_timed 60 \
    env FM_ATTEST_NM_TIMEOUT=0 PATH="$repo/stub/bin:$PATH" \
    "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -ne 124 ] || fail "a zero bound left the run-record read unbounded: it outlived this test's own bound"
  [ "$rc" -ne 0 ] || fail "a pipeline tool that never answered was transcribed"
  assert_contains "$out" "run-record-unreadable" \
    "a read that hit its bound was not reported as an unreadable record"
  # The matched control, differing by one property: the same zero against a tool
  # that answers at once must still attest. A zero read as an instant deadline,
  # which is what it becomes on a host falling back to the bash watchdog, would
  # refuse this too, and refusing every read is not a bound either.
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && FM_ATTEST_NM_TIMEOUT=0 PATH="$repo/stub/bin:$PATH" \
    "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a zero bound expired a run-record read that answered at once: $out"
  pass "fm-attest.sh: a zero FM_ATTEST_NM_TIMEOUT falls back to the default bound rather than removing it"
}

# ---------------------------------------------------------------------------
# reconcile - the bounded window before a terminal verdict. Every case here is
# about WHEN the verdict is reached, because what the verdict is remains
# verify's and is pinned above. Two properties carry the rest: the window is
# entered only for absence, and it always ends.
# ---------------------------------------------------------------------------

test_reconcile_converges_on_an_attestation_published_during_the_window() {
  local dir head out rc started waited publisher
  dir="$TMP_ROOT/reconcile-converges"
  head=$(new_reconcile_fixture "$dir")

  # The negative control first, and on this fixture rather than a described one:
  # with nothing publishing, the same call must refuse. A convergence assertion
  # on a fixture that was already green would prove nothing at all.
  out=$(run_reconcile "$dir" --head "$head" --window 2 --poll 1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "an unattested head was not refused before the publisher ran (exit $rc): $out"

  # The race this whole window exists for: the note lands after the check has
  # looked once and found nothing.
  (
    sleep 2
    publish_to_source "$dir" "$head" "$(good_note "$head")"
  ) &
  publisher=$!
  fm_test_reap "$publisher"
  started=$(date +%s)
  out=$(run_reconcile "$dir" --head "$head" --window 30 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  wait "$publisher" 2>/dev/null || :
  [ "$rc" -eq 0 ] || fail "an attestation published during the window did not converge (exit $rc): $out"
  assert_contains "$out" "attested $head" "the converging call did not report the head it attested"
  [ "$waited" -ge 2 ] \
    || fail "the window returned in ${waited}s, before the note existed, so it cannot have re-read anything"
  [ "$waited" -lt 30 ] || fail "the window ran to its bound instead of converging on the published note"
  pass "fm-attest.sh: reconcile converges on an attestation published during its window"
}

test_reconcile_refuses_a_head_no_attestation_arrives_for() {
  local dir head out rc started waited
  dir="$TMP_ROOT/reconcile-exhausts"
  head=$(new_reconcile_fixture "$dir")

  started=$(date +%s)
  out=$(run_reconcile "$dir" --head "$head" --window 4 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  # The acceptance criterion the window is not allowed to cost: a head nobody
  # has attested is still refused, and refused within the bound rather than
  # whenever evidence might turn up.
  [ "$rc" -eq 1 ] || fail "a head with no attestation was not refused as a verdict (exit $rc): $out"
  assert_contains "$out" "no-attestation-ref" "the exhausted window did not report the evidence's own state"
  [ "$waited" -ge 4 ] || fail "the window ended after ${waited}s, short of the 4s it was given"
  [ "$waited" -lt 20 ] || fail "the window did not end at its bound: it took ${waited}s"
  # The bound is the one number that shaped this verdict, so it is in it.
  assert_contains "$out" "4s window" "the refusal did not say how long it waited"

  # The matched control, differing by one property: the same fixture with the
  # attestation already published passes without waiting at all.
  publish_to_source "$dir" "$head" "$(good_note "$head")"
  started=$(date +%s)
  out=$(run_reconcile "$dir" --head "$head" --window 4 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  [ "$rc" -eq 0 ] || fail "an attested head was refused by the same call (exit $rc): $out"
  [ "$waited" -lt 4 ] || fail "an attested head was made to wait out the window"
  pass "fm-attest.sh: reconcile refuses an unattested head within its documented bound"
}

test_reconcile_does_not_grace_evidence_already_seen_to_be_invalid() {
  local dir head out rc started waited other body
  dir="$TMP_ROOT/reconcile-no-grace"
  head=$(new_reconcile_fixture "$dir")
  other=0123456789012345678901234567890123456789

  # The window is for absence. Evidence that has already been looked at and
  # found bad is a verdict, and a window that delayed it would be buying time
  # for exactly what this check exists to refuse.
  for body in \
    "$(printf 'no-mistakes-attestation: v1\nhead: %s\nrun: R1\ngates: review,test,lint,push\ntool: nm/v1\n' "$other")" \
    "$(printf 'no-mistakes-attestation: v1\nhead: %s\nrun: R1\ngates: review,test,lint,push\ntool: nm/v1\nunknown: field\n' "$head")" \
    "$(printf 'no-mistakes-attestation: v1\nhead: %s\nrun: R1\ngates: test,lint,push\ntool: nm/v1\n' "$head")"; do
    publish_to_source "$dir" "$head" "$body"
    started=$(date +%s)
    out=$(run_reconcile "$dir" --head "$head" --window 20 --poll 1)
    rc=$?
    waited=$(elapsed_seconds "$started")
    [ "$rc" -eq 1 ] || fail "invalid evidence was not refused as a verdict (exit $rc): $out"
    [ "$waited" -lt 20 ] \
      || fail "invalid evidence was given the whole ${waited}s window instead of being refused on sight"
    assert_not_contains "$out" "window this check allows" \
      "invalid evidence was reported as an attestation that never arrived"
  done

  # The matched control on the same fixture: change only the payload's validity
  # and the identical call passes.
  publish_to_source "$dir" "$head" "$(good_note "$head")"
  out=$(run_reconcile "$dir" --head "$head" --window 20 --poll 1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a valid attestation was refused by the same call (exit $rc): $out"
  pass "fm-attest.sh: reconcile refuses invalid evidence on sight rather than waiting it out"
}

test_reconcile_ignores_local_evidence_when_the_authoritative_ref_is_absent() {
  local dir head out rc
  dir="$TMP_ROOT/reconcile-authoritative-absence"
  head=$(new_reconcile_fixture "$dir")
  add_note "$dir/work" "$head" "$(good_note "$head")"

  out=$(run_reconcile "$dir" --head "$head" --window 0 --poll 1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a local note passed while the authoritative ref was absent (exit $rc): $out"
  assert_contains "$out" "no-attestation-ref" "authoritative absence was not the state verify read"
  pass "fm-attest.sh: authoritative ref absence clears stale local evidence"
}

test_reconcile_consults_the_clock_only_after_absence_applies() {
  local dir head out rc stub
  dir="$TMP_ROOT/reconcile-clock-order"
  head=$(new_reconcile_fixture "$dir")
  publish_to_source "$dir" "$head" "malformed"
  stub="$dir/stub"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub/date"
  chmod +x "$stub/date"

  out=$(PATH="$stub:$PATH" run_reconcile "$dir" --head "$head" --window 20 --poll 1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "invalid evidence consulted an unreadable clock before verify (exit $rc): $out"
  assert_contains "$out" "attestation-malformed" "invalid evidence did not reach the canonical verifier"
  assert_not_contains "$out" "clock-unreadable" "the clock was consulted before absence made waiting applicable"
  pass "fm-attest.sh: reconciliation establishes applicability before reading the clock"
}

test_reconcile_validates_the_initial_observation_before_sleeping() {
  local dir head moved out rc stub marker
  dir="$TMP_ROOT/reconcile-initial-head-order"
  head=$(new_reconcile_fixture "$dir")
  printf 'moved\n' > "$dir/work/moved.txt"
  git -C "$dir/work" add moved.txt
  git -C "$dir/work" commit -qm moved
  moved=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" push -q -f pullrequest-source "$moved:refs/pull/1/head"
  git -C "$dir/work" checkout -q "$head"
  stub="$dir/stub"
  marker="$dir/slept"
  mkdir -p "$stub"
  printf '#!/usr/bin/env bash\nprintf slept > %q\n' "$marker" > "$stub/sleep"
  chmod +x "$stub/sleep"

  out=$(PATH="$stub:$PATH" run_reconcile "$dir" --head "$head" --window 30 --poll 20)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a moved initial head did not reach verify (exit $rc): $out"
  assert_contains "$out" "now proposes $moved" "the initial observation did not detect head movement"
  [ ! -e "$marker" ] || fail "the initial absent observation slept before revalidating the pull request head"
  pass "fm-attest.sh: initial absence revalidates the pull request head before sleep"
}

test_reconcile_refuses_wrong_head_evidence_arriving_during_the_wait() {
  local dir head other out rc stub body
  dir="$TMP_ROOT/reconcile-arriving-wrong-head"
  head=$(new_reconcile_fixture "$dir")
  printf 'other\n' > "$dir/work/other.txt"
  git -C "$dir/work" add other.txt
  git -C "$dir/work" commit -qm other
  other=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" checkout -q "$head"
  body="$dir/wrong-head-note"
  good_note "$other" > "$body"
  stub="$dir/stub"
  mkdir -p "$stub"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'git -C %q notes --ref=%q add -f -F %q %q >/dev/null 2>&1\n' "$dir/work" "$NOTES_REF" "$body" "$head"
    printf 'git -C %q push -q -f attestation-source %q\n' "$dir/work" "$NOTES_REF:$NOTES_REF"
  } > "$stub/sleep"
  chmod +x "$stub/sleep"

  out=$(PATH="$stub:$PATH" run_reconcile "$dir" --head "$head" --window 20 --poll 1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "wrong-head evidence arriving during the wait passed (exit $rc): $out"
  assert_contains "$out" "attestation-not-bound" "arriving evidence was not bound to the evaluated head"
  pass "fm-attest.sh: arriving evidence must bind the exact evaluated head"
}

test_reconcile_accepts_exact_head_evidence_when_the_pull_request_moves() {
  local dir head moved out rc stub body
  dir="$TMP_ROOT/reconcile-arriving-exact-head-after-move"
  head=$(new_reconcile_fixture "$dir")
  printf 'moved\n' > "$dir/work/moved.txt"
  git -C "$dir/work" add moved.txt
  git -C "$dir/work" commit -qm moved
  moved=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" checkout -q "$head"
  body="$dir/exact-head-note"
  good_note "$head" > "$body"
  stub="$dir/stub"
  mkdir -p "$stub"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'git -C %q push -q -f pullrequest-source %q\n' "$dir/work" "$moved:refs/pull/1/head"
    printf 'git -C %q notes --ref=%q add -f -F %q %q >/dev/null 2>&1\n' "$dir/work" "$NOTES_REF" "$body" "$head"
    printf 'git -C %q push -q -f attestation-source %q\n' "$dir/work" "$NOTES_REF:$NOTES_REF"
  } > "$stub/sleep"
  chmod +x "$stub/sleep"

  out=$(PATH="$stub:$PATH" run_reconcile "$dir" --head "$head" --window 20 --poll 1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "valid exact-head evidence was rejected after the pull request moved (exit $rc): $out"
  assert_contains "$out" "attested $head" "the canonical verifier did not accept the evaluated head"
  assert_not_contains "$out" "now proposes $moved" "head movement overruled already-arrived exact-head evidence"
  pass "fm-attest.sh: pull request movement does not falsify exact-head evidence"
}

test_reconcile_waits_only_for_absence() {
  local dir head out rc started waited blob neighbour
  # The correspondence this window rests on, asserted rather than assumed: the
  # states verify names as an absent attestation are exactly the states worth
  # waiting through, and every other refusal is reached at once. A later reason
  # added on one side and not the other shows up here.
  dir="$TMP_ROOT/reconcile-absence-only"
  head=$(new_reconcile_fixture "$dir")

  # Absent ref: waits.
  started=$(date +%s)
  out=$(run_reconcile "$dir" --head "$head" --window 3 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  assert_contains "$out" "no-attestation-ref" "an absent ref was not reported as such"
  [ "$waited" -ge 3 ] || fail "an absent attestation ref did not wait out the window"

  # Ref present, nothing for THIS head: waits, because publication changes it.
  # The ref is made to exist by attesting a different commit, which is the shape
  # every repository that has ever shipped an attestation is already in.
  printf 'other\n' > "$dir/work/other.txt"
  git -C "$dir/work" add other.txt
  git -C "$dir/work" commit -qm other
  neighbour=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" checkout -q "$head"
  publish_to_source "$dir" "$neighbour" "$(good_note "$neighbour")"
  started=$(date +%s)
  out=$(run_reconcile "$dir" --head "$head" --window 3 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  assert_contains "$out" "no-attestation-for-head" "a ref carrying no note for this head was not reported as such"
  [ "$waited" -ge 3 ] || fail "a ref carrying no note for this head did not wait out the window"

  # A head this checkout does not carry: does not wait. No publication puts a
  # commit in a checkout, so the wait could only ever expire.
  started=$(date +%s)
  out=$(run_reconcile "$dir" --head 0123456789012345678901234567890123456789 --window 20 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  [ "$rc" -eq 1 ] || fail "an absent head commit was not refused as a verdict (exit $rc): $out"
  assert_contains "$out" "head-commit-unavailable" "an absent head commit was not reported as its own state"
  [ "$waited" -lt 20 ] || fail "an absent head commit was waited out for ${waited}s"

  # A ref that resolves but is not notes: does not wait. Publishing into a
  # damaged ref repairs nothing, so waiting for a publication is waiting for
  # something that would not help.
  blob=$(printf 'not a notes tree\n' | git -C "$dir/work" hash-object -w --stdin)
  git -C "$dir/work" update-ref "$NOTES_REF" "$blob"
  git -C "$dir/work" remote set-url attestation-source "$dir/empty.git"
  git init -q --bare "$dir/empty.git"
  git -C "$dir/work" push -q -f attestation-source "$NOTES_REF:$NOTES_REF"
  started=$(date +%s)
  out=$(run_reconcile "$dir" --head "$head" --window 20 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  [ "$rc" -eq 1 ] || fail "an unreadable attestation ref was not refused as a verdict (exit $rc): $out"
  assert_contains "$out" "attestation-ref-unreadable" "an unreadable ref did not report its own reason"
  [ "$waited" -lt 20 ] || fail "an unreadable ref was waited out for ${waited}s as if it were absence"
  pass "fm-attest.sh: reconcile waits for an absent attestation and for nothing else"
}

test_reconcile_stops_when_the_pull_request_head_moves() {
  local dir head moved out rc started waited
  dir="$TMP_ROOT/reconcile-head-moves"
  head=$(new_reconcile_fixture "$dir")
  printf 'two\n' > "$dir/work/b.txt"
  git -C "$dir/work" add b.txt
  git -C "$dir/work" commit -qm two
  moved=$(git -C "$dir/work" rev-parse HEAD)
  # The pipeline attests the commit it actually validated, which is the new one.
  # An attestation for it says nothing about the head this run was raised for,
  # and the verdict below has to keep saying so.
  publish_to_source "$dir" "$moved" "$(good_note "$moved")"
  git -C "$dir/work" checkout -q "$head"

  # The request now proposes another commit, so no attestation for this one is
  # coming and the remaining bound would buy nothing. The verdict is still this
  # head's, reached early rather than differently.
  git -C "$dir/work" push -q -f pullrequest-source "$moved:refs/pull/1/head"
  started=$(date +%s)
  out=$(run_reconcile "$dir" --head "$head" --window 30 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  [ "$rc" -eq 1 ] || fail "a head the request moved off was not refused as a verdict (exit $rc): $out"
  assert_contains "$out" "now proposes $moved" "the early stop did not say which commit the request now proposes"
  assert_contains "$out" "no-attestation-for-head" "the verdict was not about the head this run was raised for"
  [ "$waited" -lt 30 ] || fail "a moved head was waited out for the whole ${waited}s window"

  # The matched control, differing by one property: with the request still on
  # this head, the same call spends the window it was given.
  git -C "$dir/work" push -q -f pullrequest-source "$head:refs/pull/1/head"
  started=$(date +%s)
  out=$(run_reconcile "$dir" --head "$head" --window 3 --poll 1)
  rc=$?
  waited=$(elapsed_seconds "$started")
  [ "$rc" -eq 1 ] || fail "an unmoved head was not refused (exit $rc): $out"
  assert_not_contains "$out" "now proposes" "an unmoved head was reported as one the request moved off"
  [ "$waited" -ge 3 ] || fail "an unmoved head did not wait out its window"
  pass "fm-attest.sh: reconcile stops waiting once the pull request proposes another commit"
}

test_reconcile_reports_an_unreadable_repository_as_no_verdict() {
  local dir head out rc
  dir="$TMP_ROOT/reconcile-unreadable"
  head=$(new_reconcile_fixture "$dir")

  # Not reading a repository is not reading an absence. Both are red, and that
  # is not the point: one sends a contributor to publish an attestation and the
  # other sends them to re-run a job, and a check that confused them would be
  # committing the defect it exists to remove.
  git -C "$dir/work" remote set-url attestation-source "$dir/not-a-repository.git"
  out=$(run_reconcile "$dir" --head "$head" --window 3 --poll 1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unreadable attestation repository reached a verdict (exit $rc): $out"
  assert_contains "$out" "attestation-source-unreadable" "an unreadable source did not report its own reason"
  assert_not_contains "$out" "no-attestation-ref" "a repository that was never read was reported as carrying no attestation"

  git -C "$dir/work" remote set-url attestation-source "$dir/source.git"
  git -C "$dir/work" push -q pullrequest-source --delete refs/pull/1/head
  out=$(run_reconcile "$dir" --head "$head" --window 3 --poll 1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unconfirmable pull request head reached a verdict (exit $rc): $out"
  assert_contains "$out" "pull-request-head-absent" "an absent pull request head did not report its own reason"
  assert_not_contains "$out" "no-attestation-ref" "a head that could not be confirmed was reported as carrying no attestation"

  # The matched control: with both repositories readable again, the same call
  # reaches an ordinary verdict rather than a failure.
  git -C "$dir/work" push -q pullrequest-source "$head:refs/pull/1/head"
  out=$(run_reconcile "$dir" --head "$head" --window 1 --poll 1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "two readable repositories did not reach a verdict (exit $rc): $out"
  pass "fm-attest.sh: reconcile keeps a repository it could not read apart from an attestation that is not there"
}

test_reconcile_repeats_without_compounding() {
  local dir head first second rc_first rc_second started waited
  dir="$TMP_ROOT/reconcile-replay"
  head=$(new_reconcile_fixture "$dir")

  # A pull_request workflow run can be replayed, and this window keeps nothing
  # between runs: each is bounded on its own and each reaches the same verdict.
  # A window that accumulated would either stop waiting for a head that never
  # got its bound, or wait longer every time a run was re-run.
  started=$(date +%s)
  first=$(run_reconcile "$dir" --head "$head" --window 2 --poll 1)
  rc_first=$?
  waited=$(elapsed_seconds "$started")
  [ "$waited" -lt 10 ] || fail "the first evaluation took ${waited}s for a 2s window"

  started=$(date +%s)
  second=$(run_reconcile "$dir" --head "$head" --window 2 --poll 1)
  rc_second=$?
  waited=$(elapsed_seconds "$started")
  [ "$rc_first" -eq "$rc_second" ] \
    || fail "a replayed evaluation reached a different verdict ($rc_first then $rc_second)"
  assert_contains "$second" "no-attestation-ref" "the replayed evaluation did not reach the same state"
  [ "$waited" -ge 2 ] || fail "the replayed evaluation skipped the window the first one was given"
  [ "$waited" -lt 10 ] || fail "the replayed evaluation waited ${waited}s, longer than its own bound"
  assert_contains "$first" "no-attestation-ref" "the first evaluation did not reach the state being replayed"
  pass "fm-attest.sh: a replayed evaluation is bounded on its own and reaches the same verdict"
}

test_supports_answers_for_capabilities_this_program_has() {
  local rc
  # The workflow asks this before choosing what to run, because a head raised
  # before a subcommand existed does not carry it and must not be failed for the
  # age of its checkout. The answer is an exit status, so a caller never has to
  # tell "does not do that" from "that failed" by reading a message.
  "$ATTEST" --supports reconcile >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "--supports denied a capability this program has (exit $rc)"
  "$ATTEST" --supports verify >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "--supports denied verify (exit $rc)"
  "$ATTEST" --supports something-else >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "--supports claimed a capability this program does not have"
  pass "fm-attest.sh: --supports answers for what this program can be asked to do"
}

# ---------------------------------------------------------------------------
# The workflow's own step scripts. The check fails closed on every path below;
# what these pin is what it tells the contributor, because a gate that reports
# evidence it never examined as absent evidence is committing the defect the
# whole check exists to remove.
# ---------------------------------------------------------------------------

test_check_step_separates_a_verdict_from_a_verifier_that_could_not_run() {
  local dir script head out rc
  dir="$TMP_ROOT/workflow-verify"
  mkdir -p "$dir"
  script="$dir/verify-step.sh"
  head=0123456789012345678901234567890123456789
  workflow_step_script 'Verify the head-bound no-mistakes attestation' > "$script"
  [ -s "$script" ] || fail "the verify step's own script could not be read out of the workflow"

  # POLICY_VERIFIER is what the previous step resolves out of the governed
  # venue's policy generation. The stub stands in for THAT program, not for the
  # candidate's copy of it: the step no longer runs anything out of the
  # checkout, which is what test_check_step_refuses_to_run_the_candidates_own_verifier
  # below pins.
  run_verify_step() {
    ( cd "$dir" && HEAD_SHA="$head" PR_NUMBER=1 PR_AUTHOR=someone \
        POLICY_VERIFIER="$dir/bin/fm-attest.sh" POLICY_SHA=policygeneration \
        bash "$script" 2>&1 )
  }

  # Exit 1 is a refusal: the evidence was examined and found absent. That is a
  # verdict, and it is told as one.
  install_verifier_stub "$dir" 1
  out=$(run_verify_step)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a refused attestation did not fail the check with exit 1 (exit $rc): $out"
  assert_contains "$out" "carries no verified no-mistakes attestation" \
    "a refusal was not reported as an absent attestation"
  assert_not_contains "$out" "could not evaluate" \
    "a verdict about the evidence was reported as an inability to reach one"

  # Exit 2 is a failure: no verdict was reached, so it says nothing about the
  # evidence either way and must not borrow the refusal's words.
  install_verifier_stub "$dir" 2
  out=$(run_verify_step)
  rc=$?
  [ "$rc" -eq 1 ] \
    || fail "a verifier that reached no verdict did not fail the check with exit 1 (exit $rc): $out"
  assert_contains "$out" "could not evaluate" \
    "a verifier that reached no verdict was not reported as such"
  assert_contains "$out" "exited 2" "the failing exit status was not named"
  assert_not_contains "$out" "carries no verified no-mistakes attestation" \
    "evidence the check never examined was reported as absent evidence"

  # The reachable case this was found on: a head where the verifier is not there
  # to run at all. That is not exit 1 either, and the branch reporting it must
  # not itself depend on the script that is missing.
  rm -f "$dir/bin/fm-attest.sh"
  out=$(run_verify_step)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a head carrying no verifier did not fail the check with exit 1 (exit $rc): $out"
  assert_contains "$out" "could not evaluate" \
    "a head that carries no verifier was not reported as one the check could not evaluate"
  assert_not_contains "$out" "carries no verified no-mistakes attestation" \
    "a head that carries no verifier was reported as one carrying no attestation"

  # The matched positive control: an attested head still passes, and is told
  # neither of the two failure stories.
  install_verifier_stub "$dir" 0
  out=$(run_verify_step)
  rc=$?
  [ "$rc" -eq 0 ] || fail "an attested head was failed by the check: $out"
  assert_not_contains "$out" "could not evaluate" "a passing head was told the check could not look"
  assert_not_contains "$out" "carries no verified no-mistakes attestation" \
    "a passing head was told it carries no attestation"
  unset -f run_verify_step
  pass "no-mistakes-required.yml: a verifier that could not run is not reported as an absent attestation"
}

# The refusal's other reachable state: a head no pipeline run ever validated. It
# reaches the same exit 1, so the text is the only thing that distinguishes it,
# and a refusal that stops at "publish one" sends that reader to a command that
# must refuse and to the commit-to-restart loop that follows from being refused.
test_check_step_names_validating_an_unvalidated_head_as_the_repair() {
  local dir script head out rc
  dir="$TMP_ROOT/workflow-unvalidated"
  mkdir -p "$dir"
  script="$dir/verify-step.sh"
  head=0123456789012345678901234567890123456789
  workflow_step_script 'Verify the head-bound no-mistakes attestation' > "$script"
  [ -s "$script" ] || fail "the verify step's own script could not be read out of the workflow"

  install_verifier_stub "$dir" 1
  out=$( cd "$dir" && HEAD_SHA="$head" PR_NUMBER=1 PR_AUTHOR=someone \
    HEAD_REPO_FULL=owner/fork POLICY_VERIFIER="$dir/bin/fm-attest.sh" \
    POLICY_SHA=policygeneration bash "$script" 2>&1 )
  rc=$?
  [ "$rc" -eq 1 ] || fail "a refused attestation did not fail the check with exit 1 (exit $rc): $out"
  # Each of these is a sentence the refusal did not carry before, because the
  # refusal already named 'git push no-mistakes' as how this repository is
  # contributed to and asserting on that alone would pass without any of it.
  assert_contains "$out" "no attestation for it can exist yet" \
    "the refusal did not name a head no pipeline run validated as its own state"
  assert_contains "$out" "Publishing is not the repair" \
    "the refusal left publishing as the only thing an unvalidated head is sent to do"
  assert_contains "$out" "Validate this head first with 'git push no-mistakes'" \
    "the refusal did not name validating this head as the repair for a head no run validated"
  assert_contains "$out" "Do not add a commit merely to restart this check" \
    "the refusal did not rule out the commit that advances the head past the last validated one"

  # The matched control: a head that passes is told none of it, so the lines
  # above are reached by the refusal rather than printed unconditionally.
  install_verifier_stub "$dir" 0
  out=$( cd "$dir" && HEAD_SHA="$head" PR_NUMBER=1 PR_AUTHOR=someone \
    HEAD_REPO_FULL=owner/fork POLICY_VERIFIER="$dir/bin/fm-attest.sh" \
    POLICY_SHA=policygeneration bash "$script" 2>&1 )
  rc=$?
  [ "$rc" -eq 0 ] || fail "an attested head was failed by the check: $out"
  assert_not_contains "$out" "Validate this head first with 'git push no-mistakes'" \
    "a passing head was sent to re-validate itself"
  pass "no-mistakes-required.yml: a head no run validated is sent to the pipeline rather than to publishing"
}

test_check_step_addresses_both_repositories_without_logging_its_token() {
  local dir script log out rc repo fork
  dir="$TMP_ROOT/workflow-address"
  mkdir -p "$dir/bin"
  script="$dir/address-step.sh"
  log="$dir/git-said.log"
  workflow_step_script 'Address the repositories the attestation is read from' > "$script"
  [ -s "$script" ] || fail "the addressing step's own script could not be read out of the workflow"

  # First, against real git in a real repository, because what this step is for
  # is the two remotes the verifier then reads, and only real git can be asked
  # whether they are there. The attestation is published to the head repository
  # and refs/pull/* lives in the base repository, so a step that addressed one
  # of them twice would leave the verifier reading the wrong place.
  repo="$dir/same-repo"
  new_repo "$repo"
  out=$(cd "$repo" && HEAD_REPO=owner/repo BASE_REPO=owner/repo \
    GH_TOKEN=ghs_fixturetokenvalue bash "$script" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "addressing two readable repositories failed the step: $out"
  assert_contains "$(git -C "$repo" remote get-url attestation-source)" \
    "https://x-access-token:ghs_fixturetokenvalue@github.com/owner/repo.git" \
    "the attestation is not read from the head repository through the job's token"
  assert_contains "$(git -C "$repo" remote get-url pullrequest-source)" \
    "https://x-access-token:ghs_fixturetokenvalue@github.com/owner/repo.git" \
    "the pull request head is not read from the base repository through the job's token"
  assert_not_contains "$out" "ghs_fixturetokenvalue" "the job token reached the step's output"

  # A fork's attestation is read through its plain https URL, which carries the
  # token from the workspace's git configuration rather than from the URL; the
  # base repository it is compared against is still read through the token URL.
  fork="$dir/fork"
  new_repo "$fork"
  out=$(cd "$fork" && HEAD_REPO=someone/fork BASE_REPO=owner/repo \
    GH_TOKEN=ghs_fixturetokenvalue bash "$script" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "addressing a fork failed the step: $out"
  assert_contains "$(git -C "$fork" remote get-url attestation-source)" \
    "https://github.com/someone/fork.git" "a fork's attestation is not read from the fork"
  assert_not_contains "$(git -C "$fork" remote get-url attestation-source)" \
    "ghs_fixturetokenvalue" "a fork's URL was given the job token it does not take"

  # Then against a git that quotes the whole tokenized URL back the way real git
  # does in its own errors, and records what it said, so the assertion that none
  # of it reached the log cannot pass merely because the fixture stayed quiet.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "fatal: unable to access %%s: the server said no\\n" "$*" | tee -a %s >&2\n' "$log"
    printf 'exit "${FM_FAKE_GIT_RC:-0}"\n'
  } > "$dir/bin/git"
  chmod +x "$dir/bin/git"
  out=$(cd "$dir" && PATH="$dir/bin:$PATH" HEAD_REPO=owner/repo BASE_REPO=owner/repo \
    GH_TOKEN=ghs_fixturetokenvalue bash "$script" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the addressing step failed on git output it should have suppressed: $out"
  assert_contains "$(cat "$log")" "ghs_fixturetokenvalue" \
    "the fixture never quoted the tokenized URL back, so this assertion proves nothing"
  assert_not_contains "$out" "ghs_fixturetokenvalue" "the job token reached the step's output"
  assert_contains "$out" "owner/repo" "the step did not name the repositories it addressed"

  # And the head repository that cannot be addressed at all: a name that is not
  # a repository path stops the job rather than being interpolated into a URL.
  out=$(cd "$dir" && PATH="$dir/bin:$PATH" HEAD_REPO='owner/repo/../evil' BASE_REPO=owner/repo \
    GH_TOKEN=ghs_fixturetokenvalue bash "$script" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unusable head repository name was addressed anyway"
  assert_not_contains "$out" "ghs_fixturetokenvalue" "the job token reached the step's output"
  pass "no-mistakes-required.yml: both repositories are addressed by name, and the job token is not logged"
}

# ---------------------------------------------------------------------------
# write and show - the failure half of the error model. Every documented
# `cannot attest` reason fires for its own condition and for no other's.
# ---------------------------------------------------------------------------

test_write_outside_a_repository_fails_as_such() {
  local dir out rc
  dir="$TMP_ROOT/no-repo"
  mkdir -p "$dir"
  out=$(cd "$dir" && "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran outside a git repository"
  assert_contains "$out" "not-a-git-repository" "a non-repository was not reported as such"
  assert_not_contains "$out" "head-unresolvable" "a non-repository was reported as an unresolvable head"
  pass "fm-attest.sh: write outside a repository fails as a non-repository"
}

test_write_without_the_pipeline_tool_fails_as_such() {
  local repo bare head out rc
  repo="$TMP_ROOT/no-tool"
  bare="$TMP_ROOT/no-tool-path"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_unbounded_path "$bare"
  out=$(cd "$repo" && PATH="$bare" "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran with no pipeline tool on PATH"
  assert_contains "$out" "pipeline-tool-missing" "an absent pipeline tool was not reported as such"
  assert_not_contains "$out" "no-run-record" "an absent tool was reported as an absent run"
  # The matched control: the same repository and PATH, plus the tool.
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && PATH="$repo/stub/bin:$bare" "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused once the tool was on PATH: $out"
  pass "fm-attest.sh: an absent pipeline tool fails as a missing tool, not as a missing run"
}

test_write_on_an_unborn_head_fails_as_such() {
  local repo out rc
  repo="$TMP_ROOT/unborn-head"
  mkdir -p "$repo"
  git -C "$repo" init -q -b fm/demo .
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo deadbeef completed)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran with no commit to attest"
  assert_contains "$out" "head-unresolvable" "an unborn HEAD was not reported as such"
  assert_not_contains "$out" "head-detached" "an unborn HEAD was reported as a detached one"
  pass "fm-attest.sh: an unborn HEAD fails as unresolvable, not as detached"
}

test_write_on_a_detached_head_fails_as_such() {
  local repo head out rc
  repo="$TMP_ROOT/detached-head"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  git -C "$repo" checkout -q --detach
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran from a detached HEAD"
  assert_contains "$out" "head-detached" "a detached HEAD was not reported as such"
  assert_not_contains "$out" "head-unresolvable" "a detached HEAD was reported as an unresolvable one"
  # The matched control: the same repository back on the branch the run covers.
  git -C "$repo" checkout -q fm/demo
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused once back on its branch: $out"
  pass "fm-attest.sh: a detached HEAD fails as detached, not as unresolvable"
}

test_write_without_a_usable_scratch_directory_fails_as_such() {
  local repo head out rc
  repo="$TMP_ROOT/no-tmpdir"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(cd "$repo" && TMPDIR="$repo/absent" PATH="$repo/stub/bin:$PATH" \
    "$ATTEST" write --no-push 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "write ran with no usable temporary directory"
  assert_contains "$out" "scratch-file-unavailable" "an unusable TMPDIR was not reported as such"
  assert_not_contains "$out" "run-record-unreadable" "an unusable TMPDIR was reported as a failing tool"
  # The matched control: the same repository with a usable one.
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused with a usable TMPDIR: $out"
  pass "fm-attest.sh: an unusable scratch directory fails as its own state, not as a tool failure"
}

test_write_reports_an_unfetchable_push_target_as_such() {
  local repo fork head out rc
  repo="$TMP_ROOT/unfetchable"
  fork="$TMP_ROOT/unfetchable-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  # A push target that advertises the ref but cannot serve it, because the ref
  # names an object it does not have. Readable is not the same as fetchable.
  mkdir -p "$fork/refs/notes"
  printf '0123456789012345678901234567890123456789\n' > "$fork/refs/notes/no-mistakes"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unfetchable push target was published to"
  assert_contains "$out" "push-target-unfetchable" "an unfetchable push target was not reported as such"
  assert_not_contains "$out" "push-target-unreadable" \
    "a target that advertised the ref was reported as one that could not be read"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "an attestation was recorded against a target that would not serve its ref"
  # The matched control: the same target once that ref is serviceable.
  rm -f "$fork/refs/notes/no-mistakes"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same target was refused once its ref was serviceable: $out"
  pass "fm-attest.sh: a push target that advertises a ref it cannot serve fails as unfetchable"
}

test_write_reports_an_unreconcilable_local_ref_as_such() {
  local repo fork head seed out rc
  repo="$TMP_ROOT/unreconcilable"
  fork="$TMP_ROOT/unreconcilable-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  # The push target holds a real attestation history, so the reconcile is
  # reached; the local ref is broken, so it cannot complete.
  seed=$(git -C "$repo" commit-tree -m seed "$(git -C "$repo" rev-parse 'HEAD^{tree}')")
  add_note "$repo" "$seed" "$(good_note "$seed")"
  git -C "$repo" push -q "$fork" "$NOTES_REF:$NOTES_REF"
  # A local ref that resolves, so the fetch completes, but that names no notes
  # tree, so only the reconcile itself can fail.
  git -C "$repo" update-ref "$NOTES_REF" "$(printf 'x' | git -C "$repo" hash-object -w --stdin)"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a local ref naming no notes tree was published over"
  assert_contains "$out" "attestation-not-reconciled" "a failed reconcile was not reported as such"
  assert_not_contains "$out" "attestation-not-recorded" \
    "a reconcile that failed was reported as a record that failed"
  assert_not_contains "$out" "push-target-unfetchable" \
    "a reconcile that failed was reported as a target that would not serve its ref"
  # The matched control: the same target with a usable local ref.
  git -C "$repo" update-ref -d "$NOTES_REF"
  out=$(publish_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same push target was refused with a usable local ref: $out"
  pass "fm-attest.sh: a local ref that cannot be reconciled fails as unreconciled"
}

test_write_reports_an_unrecordable_note_as_such() {
  local repo head out rc
  repo="$TMP_ROOT/unrecordable"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  git -C "$repo" update-ref "$NOTES_REF" "$(printf 'x' | git -C "$repo" hash-object -w --stdin)"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -ne 0 ] || fail "a note was recorded against a ref naming no notes tree"
  assert_contains "$out" "attestation-not-recorded" "a failed record was not reported as such"
  assert_not_contains "$out" "attestation-not-reconciled" \
    "a record that failed with no push was reported as a failed reconcile"
  # The matched control: the same repository with a usable ref.
  git -C "$repo" update-ref -d "$NOTES_REF"
  out=$(write_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the same repository was refused with a readable ref: $out"
  pass "fm-attest.sh: a note that cannot be recorded fails as unrecorded"
}

test_show_reports_an_unknown_commit_as_such() {
  local repo head out rc
  repo="$TMP_ROOT/show-unknown"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  add_note "$repo" "$head" "$(good_note "$head")"
  out=$(cd "$repo" && "$ATTEST" show --commit 0123456789012345678901234567890123456789 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "show accepted a commit this repository does not have"
  assert_contains "$out" "commit-unknown" "an unknown commit was not reported as such"
  assert_not_contains "$out" "no-attestation-for-head" \
    "a commit this repository does not have was reported as one carrying no attestation"
  # The matched control: the commit this repository does have.
  out=$(cd "$repo" && "$ATTEST" show --commit "$head" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "show refused the attested commit: $out"
  pass "fm-attest.sh: show fails as commit-unknown rather than as an absent attestation"
}

# ---------------------------------------------------------------------------
# recheck - publishing an attestation makes the verdict follow it, without
# anyone closing, reopening or editing a pull request.
#
# The property under test throughout is the ACTION taken against the forge, read
# out of a log of every call, and never a message this program prints about it.
# A stub that answered "re-run requested" would satisfy an assertion on the
# wording while re-running nothing, so each case asserts on the POST that was or
# was not made, and every negative case asserts the POST was NOT made.
#
# The stub applies the real --jq filter to real fixture JSON, so the selection
# rules - this head only, this pull request, the run that started last - are
# exercised rather than assumed. gh embeds a jq implementation, so the filters
# are the deliverable and a case that cannot evaluate them skips rather than
# passing on a weaker check.
# ---------------------------------------------------------------------------

# A repository whose push target is a real bare repository, so the evidence
# recheck reads is a note genuinely published rather than one recorded locally.
# Echoes nothing; sets up "$repo", "$repo.fork.git" and the stub PATH.
publish_target() {  # <repo> - the exact URL this repo's origin pushes to
  git -C "$1" config --get remote.origin.pushurl 2>/dev/null \
    || git -C "$1" config --get remote.origin.url 2>/dev/null
}

new_published_repo() {
  local repo=$1 head
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$repo.fork.git"
  git -C "$repo" config url."$repo.fork.git".insteadOf https://github.com/example/repo.git
  git -C "$repo" remote add origin https://github.com/example/repo.git
  git -C "$repo" push -q origin fm/demo
  add_note "$repo" "$head" "$(good_note "$head")"
  git -C "$repo" push -q origin "$NOTES_REF:$NOTES_REF"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  install_gh_stub "$repo/stub"
}

# A gh that answers off its argv and records every call. Reads are answered by
# applying the caller's own --jq filter, with jq, to a fixture file named in the
# environment, so a filter that selects the wrong run fails here rather than
# being papered over by a stub that returns what the test wanted. Writes are
# recorded and nothing else, because the POST is the observable action.
install_gh_stub() {
  local dir=$1
  mkdir -p "$dir/bin"
  cat > "$dir/bin/gh" <<'FM_GH_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:-/dev/null}"
[ "${1:-}" = api ] || { echo "gh stub: unexpected call: $*" >&2; exit 3; }
shift
method=GET
path=
filter=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method) method=$2; shift 2 ;;
    --jq) filter=$2; shift 2 ;;
    -f | -F | -H) shift 2 ;;
    -*) shift ;;
    *)
      [ -n "$path" ] || path=$1
      shift
      ;;
  esac
done
case "$method:$path" in
  POST:*/rerun)
    [ "${FM_TEST_RERUN_RC:-0}" = 0 ] || {
      echo "HTTP 403: Resource not accessible by integration" >&2
      exit "$FM_TEST_RERUN_RC"
    }
    exit 0
    ;;
esac
fixture=
case "$path" in
  graphql) fixture=${FM_TEST_PULLS_JSON:-} ;;
  */actions/workflows/*/runs*) fixture=${FM_TEST_RUNS_JSON:-} ;;
  */pulls/*) fixture=${FM_TEST_PR_JSON:-} ;;
esac
[ -n "$fixture" ] && [ -f "$fixture" ] || { echo "gh stub: no fixture for $path" >&2; exit 4; }
jq -r "$filter" < "$fixture"
FM_GH_STUB
  chmod +x "$dir/bin/gh"
}

# The three fixtures, written from one head so a case that means to change one
# property changes exactly that one.
runs_fixture() { # <path> <head> <run>:<attempt>:<status>:<conclusion>:<pr>...
  local path=$1 head=$2 first=1 spec id attempt status conclusion pr
  shift 2
  {
    printf '{"total_count":%s,"workflow_runs":[' "$#"
    for spec in "$@"; do
      IFS=: read -r id attempt status conclusion pr <<EOF
$spec
EOF
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"id":%s,"run_attempt":%s,"status":"%s","conclusion":%s,"head_sha":"%s","pull_requests":[%s]}' \
        "$id" "$attempt" "$status" \
        "$([ "$conclusion" = none ] && printf 'null' || printf '"%s"' "$conclusion")" \
        "$head" \
        "$([ -z "$pr" ] && printf '' || printf '{"number":%s}' "$pr")"
    done
    printf ']}\n'
  } > "$path"
}

pr_fixture() { # <path> <state> <head> [<head owner/name>|absent|unreadable]
  local head_repo=${4:-example/repo}
  case "$head_repo" in
    absent)
      printf '{"state":"%s","head":{"sha":"%s","repo":null}}\n' "$2" "$3" > "$1"
      ;;
    unreadable)
      printf '{"state":"%s","head":{"sha":"%s","repo":{"full_name":"not a repository"}}}\n' "$2" "$3" > "$1"
      ;;
    *)
      printf '{"state":"%s","head":{"sha":"%s","repo":{"full_name":"%s"}}}\n' "$2" "$3" "$head_repo" > "$1"
      ;;
  esac
}

pulls_fixture() { # <path> <head> <owner/name>:<number>...
  local path=$1 head=$2 first=1 spec repo number
  shift 2
  {
    printf '{"data":{"repository":{"object":{"associatedPullRequests":{"pageInfo":{"hasNextPage":false},"nodes":['
    for spec in "$@"; do
      repo=${spec%%:*}
      number=${spec##*:}
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"number":%s,"state":"OPEN","headRefOid":"%s","baseRepository":{"nameWithOwner":"%s"},"headRepository":{"nameWithOwner":"example/repo"}}' \
        "$number" "$head" "$repo"
    done
    printf ']}}}}}\n'
  } > "$path"
}

pulls_fixture_truncated() { # <path> <head> <owner/name> <number>
  printf '{"data":{"repository":{"object":{"associatedPullRequests":{"pageInfo":{"hasNextPage":true},"nodes":[{"number":%s,"state":"OPEN","headRefOid":"%s","baseRepository":{"nameWithOwner":"%s"},"headRepository":{"nameWithOwner":"example/repo"}}]}}}}}\n' \
    "$4" "$2" "$3" > "$1"
}

# A repository that simply does not have this commit. GraphQL answers that with
# a null object and a success status, which is a fact about that repository
# rather than a read that failed, and an unrelated remote in a checkout is
# ordinary enough that it must not be able to stop the whole command.
pulls_fixture_commit_absent() { # <path>
  printf '{"data":{"repository":{"object":null}}}\n' > "$1"
}

# An open request GitHub still associates with this commit while its head has
# moved past it. That association is real and permanent - the commit was in that
# request's history - so it is exactly the shape that must not be mistaken for a
# request open ON this commit.
pulls_fixture_other_head() { # <path> <owner/name> <number> <that request's head>
  printf '{"data":{"repository":{"object":{"associatedPullRequests":{"nodes":[{"number":%s,"state":"OPEN","headRefOid":"%s","baseRepository":{"nameWithOwner":"%s"},"headRepository":{"nameWithOwner":"example/repo"}}]}}}}}\n' \
    "$3" "$4" "$2" > "$1"
}

# A request on this exact head that is no longer open. GitHub returns closed and
# merged requests here too, and a request that is not open has no check for this
# to re-evaluate.
pulls_fixture_state() { # <path> <owner/name> <number> <head> <state>
  printf '{"data":{"repository":{"object":{"associatedPullRequests":{"nodes":[{"number":%s,"state":"%s","headRefOid":"%s","baseRepository":{"nameWithOwner":"%s"},"headRepository":{"nameWithOwner":"example/repo"}}]}}}}}\n' \
    "$3" "$5" "$4" "$2" > "$1"
}

# A resolved request whose head repository is spelled as the caller asks, so the
# case-insensitivity of repository identity can be exercised on the RESOLVED
# path as well as the explicit one. The two read different fields -
# `.head.repo.full_name` against `headRepository.nameWithOwner` - and GitHub
# returns its own canonical casing for both, so a fix applied to one of them
# would leave the other refusing a match that is really a match.
pulls_fixture_head_repo() { # <path> <head> <base owner/name> <number> <head owner/name>
  printf '{"data":{"repository":{"object":{"associatedPullRequests":{"nodes":[{"number":%s,"state":"OPEN","headRefOid":"%s","baseRepository":{"nameWithOwner":"%s"},"headRepository":{"nameWithOwner":"%s"}}]}}}}}\n' \
    "$4" "$2" "$3" "$5" > "$1"
}

# One recheck invocation with the stubs in front of the real tools, its call log
# in the case's own directory so nothing is shared between cases.
recheck_out() {
  local repo=$1
  shift
  (
    cd "$repo" || exit 2
    PATH="$repo/stub/bin:$PATH" \
    FM_TEST_GH_LOG="$repo/gh.log" \
    FM_TEST_RUNS_JSON="$repo/runs.json" \
    FM_TEST_PR_JSON="$repo/pr.json" \
    FM_TEST_PULLS_JSON="$repo/pulls.json" \
      "$ATTEST" recheck "$@" 2>&1
  )
}

assert_reran() {
  local repo=$1 run=$2 label=$3
  grep -qxF "api --method POST repos/example/repo/actions/runs/$run/rerun" "$repo/gh.log" \
    || fail "$label: run $run was not re-run (calls: $(tr '\n' '|' < "$repo/gh.log"))"
  [ "$(grep -c -- '--method POST' "$repo/gh.log")" -eq 1 ] \
    || fail "$label: more than one write reached the forge"
}

assert_not_reran() {
  local repo=$1 label=$2
  [ -f "$repo/gh.log" ] || return 0
  grep -q -- '--method POST' "$repo/gh.log" \
    && fail "$label: a re-run was requested when it must not have been"
  return 0
}

# Nothing this does may mutate a pull request. Closing, reopening or editing one
# is the manual step being removed, and automating it would restore the defect
# with a different actor rather than remove it.
assert_left_the_pull_request_alone() {
  local repo=$1 label=$2
  [ -f "$repo/gh.log" ] || return 0
  grep -qE -- '--method (PATCH|PUT|DELETE)|pr edit|pr close|pr reopen' "$repo/gh.log" \
    && fail "$label: the pull request itself was altered to nudge the check"
  return 0
}

jq_or_skip() {
  command -v jq >/dev/null 2>&1 && return 1
  pass "SKIP (jq unavailable): $1"
  return 0
}

test_recheck_reruns_the_run_that_judged_a_published_head() {
  local repo head out rc
  jq_or_skip "a published head is re-evaluated without touching the pull request" && return
  repo="$TMP_ROOT/recheck-converges"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head"
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a published exact-head attestation was not re-evaluated: $out"
  assert_reran "$repo" 100 "converges"
  assert_left_the_pull_request_alone "$repo" "converges"
  assert_contains "$out" "re-ran https://github.com/example/repo/actions/runs/100" \
    "the re-evaluation did not name the run it re-ran"
  pass "fm-attest.sh: a published exact-head attestation re-runs the run that judged it"
}

test_recheck_requests_one_re_evaluation_per_attempt() {
  local repo head out rc
  jq_or_skip "re-triggering the same head twice requests nothing the second time" && return
  repo="$TMP_ROOT/recheck-idempotent"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head"
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the first re-evaluation was refused"
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  # Still success: nothing is wrong, and there is nothing left to do. The
  # observable property is the count of writes, not the exit status.
  [ "$rc" -eq 0 ] || fail "a repeat re-evaluation was reported as a fault: $out"
  assert_reran "$repo" 100 "idempotent"
  assert_contains "$out" "already been re-triggered" \
    "the repeat was not reported as one"
  pass "fm-attest.sh: an unchanged head and attempt is re-triggered once, not repeatedly"
}

test_recheck_pre_request_record_consumes_the_attempt() {
  local control repo head out rc
  jq_or_skip "a pre-request record survives a crash without permitting a duplicate POST" && return
  control="$TMP_ROOT/recheck-pre-request-control"
  new_published_repo "$control"
  head=$(git -C "$control" rev-parse HEAD)
  runs_fixture "$control/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$control/pr.json" open "$head"
  recheck_out "$control" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the no-crash control did not request a re-evaluation"
  assert_reran "$control" 100 "pre-request control"

  repo="$TMP_ROOT/recheck-pre-request-crash"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head"
  printf 'fm-attest-recheck.v1 ts=unknown repo=example/repo pr=7 head=%s note=unknown run=100 attempt=1 action=requesting reason=attestation-published\n' \
    "$head" > "$repo/.git/fm-attest-recheck.log"
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a crash-spent attempt was reported as a fault: $out"
  assert_not_reran "$repo" "pre-request crash"
  pass "fm-attest.sh: a durable pre-request record consumes its run attempt"
}

# The ledger lock, tested by CONTENTION rather than by hoping two processes
# interleave. The control this replaces asserted a POST count that the
# per-attempt guard produced on its own: with roughly 200ms of git and gh work
# before the count and a sub-millisecond window between the count and the
# append, the second invocation essentially always arrived after the first had
# appended and was turned away by that guard, so the lock was never exercised
# and removing it entirely left the case green ten runs out of ten. A control
# that passes because a DIFFERENT mechanism produced the asserted outcome is
# measuring that other mechanism.
#
# So the lock is isolated instead: something else already holds it, and nothing
# but the lock can decide what happens next.
test_recheck_refuses_while_the_ledger_lock_is_held() {
  local repo head out rc
  jq_or_skip "a held ledger lock stops the request rather than racing it" && return
  repo="$TMP_ROOT/recheck-lock-held"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head"
  mkdir -p "$repo/.git/fm-attest-recheck.lock"
  printf '%s %s\n' "$(hostname)" "$$" > "$repo/.git/fm-attest-recheck.lock/holder"
  out=$(FM_ATTEST_RECHECK_LOCK_WAIT=1 recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a held ledger lock did not reach could-not-observe (exit $rc): $out"
  assert_contains "$out" "ledger-lock-unavailable" "a held lock was not named as its own state"
  assert_not_reran "$repo" "lock held"
  # The anchor, differing by exactly one property: nobody holding the lock.
  rm "$repo/.git/fm-attest-recheck.lock/holder"
  rmdir "$repo/.git/fm-attest-recheck.lock"
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the same call with the lock free was refused"
  assert_reran "$repo" 100 "lock-free anchor"
  pass "fm-attest.sh: a held ledger lock stops the request and a free one does not"
}

test_recheck_reclaims_only_a_demonstrably_stale_ledger_lock() {
  local repo head out rc stale_pid
  jq_or_skip "only a demonstrably stale ledger lock is reclaimed" && return

  repo="$TMP_ROOT/recheck-lock-stale"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head"
  stale_pid=999999
  while ps -p "$stale_pid" >/dev/null 2>&1; do stale_pid=$((stale_pid - 1)); done
  mkdir -p "$repo/.git/fm-attest-recheck.lock"
  printf '%s %s\n' "$(hostname)" "$stale_pid" > "$repo/.git/fm-attest-recheck.lock/holder"
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "a demonstrably stale local lock was not reclaimed"
  assert_reran "$repo" 100 "stale local lock"

  repo="$TMP_ROOT/recheck-lock-remote"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head"
  mkdir -p "$repo/.git/fm-attest-recheck.lock"
  printf 'another-host.invalid %s\n' "$stale_pid" > "$repo/.git/fm-attest-recheck.lock/holder"
  out=$(FM_ATTEST_RECHECK_LOCK_WAIT=0 recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a different-host lock was reclaimed (exit $rc): $out"
  assert_not_reran "$repo" "different-host lock"

  repo="$TMP_ROOT/recheck-lock-unobservable"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head"
  mkdir -p "$repo/.git/fm-attest-recheck.lock"
  out=$(FM_ATTEST_RECHECK_LOCK_WAIT=0 recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a lock without an observable holder was reclaimed (exit $rc): $out"
  assert_not_reran "$repo" "unobservable lock"
  pass "fm-attest.sh: only a demonstrably stale ledger lock is reclaimed"
}

test_recheck_refuses_a_truncated_pull_request_listing() {
  local repo head out rc
  jq_or_skip "a truncated pull request listing reaches no verdict" && return
  repo="$TMP_ROOT/recheck-truncated-pulls"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pulls_fixture_truncated "$repo/pulls.json" "$head" example/repo 7
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head"
  out=$(recheck_out "$repo" --head "$head")
  rc=$?
  [ "$rc" -eq 2 ] || fail "a truncated pull request listing was accepted (exit $rc): $out"
  assert_not_reran "$repo" "truncated pull request listing"
  pulls_fixture "$repo/pulls.json" "$head" example/repo:7
  recheck_out "$repo" --head "$head" >/dev/null \
    || fail "the complete pull request listing anchor was refused"
  assert_reran "$repo" 100 "complete pull request listing anchor"
  pass "fm-attest.sh: a truncated pull request listing reaches no verdict"
}

test_recheck_binds_the_published_repository_to_the_pr_head_repository() {
  local repo head out rc
  jq_or_skip "a different published repository cannot trigger a PR head recheck" && return
  repo="$TMP_ROOT/recheck-repository-binding"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" config url."$repo.fork.git".insteadOf https://github.com/other/repo.git
  git -C "$repo" remote set-url origin https://github.com/other/repo.git
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pr_fixture "$repo/pr.json" open "$head" example/repo
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a mismatched head repository was not refused (exit $rc): $out"
  assert_contains "$out" "pull-request-head-repository-mismatch" "the repository mismatch lacked its own reason"
  assert_not_reran "$repo" "repository mismatch"
  pr_fixture "$repo/pr.json" open "$head" other/repo
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the matched head repository control was refused"
  assert_reran "$repo" 100 "repository-binding control"
  pass "fm-attest.sh: published evidence is bound to the pull request head repository"
}

# WHAT IS NOT PROVEN HERE, AND WHY NO CASE ABOVE CLAIMS IT.
#
# That two invocations racing for the last slot cannot both take it is NOT
# tested, and a case asserting it was written, measured, and removed rather than
# kept. Two independent processes only collide inside a sub-millisecond window
# between the count and the append; each spends roughly 200ms in git and gh
# before reaching it, so the later one arrives after the earlier has appended
# and is turned away by the bound instead. The one thing that can release both
# at the same instant is the lock itself, which makes any such case synchronize
# on the very mechanism it claims to test: with the lock removed it stayed green
# eight runs out of eight, exactly as its predecessor stayed green ten out of
# ten.
#
# So the proven claim is the narrower one the case above does establish: the
# lock is taken, it is reached before the count, and a holder stops the request
# rather than letting it proceed. Mutual exclusion between two holders follows
# from mkdir being atomic on POSIX, which is a property of the operating system
# rather than of this program, and is stated here as inherited rather than
# demonstrated. An honest gap is worth more than a green that measures process
# startup stagger.

# GitHub repository names are case-insensitive, and the two sides of this
# binding are spelled by different authorities: the push side is lowercased out
# of a remote URL, the forge side comes back in GitHub's own canonical casing.
# Comparing them as text refused a match that was really a match, which put the
# manual re-trigger back for every contributor whose repository name carries a
# capital. It failed CLOSED, so no head was ever reported green on evidence the
# check could not see; what it cost was the automation itself.
#
# Both resolution paths get this, because they read different fields -
# `.head.repo.full_name` here and `headRepository.nameWithOwner` below - and a
# fix applied to one of them passes a suite whose every other fixture is
# lowercase.
test_recheck_matches_a_head_repository_spelled_in_another_case() {
  local repo head out rc
  jq_or_skip "one repository spelled two ways is one repository" && return
  repo="$TMP_ROOT/recheck-case-explicit"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  # The same repository the note was published to, in GitHub's canonical casing.
  pr_fixture "$repo/pr.json" open "$head" Example/Repo
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the same repository spelled in another case was refused"
  assert_reran "$repo" 100 "case-insensitive explicit path"
  # The anchor that keeps this from passing vacuously: a genuinely DIFFERENT
  # repository is still refused, so the comparison was relaxed in case and in
  # nothing else.
  rm -f "$repo/gh.log"
  pr_fixture "$repo/pr.json" open "$head" Other/Repo
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a different repository was accepted as a case variant (exit $rc): $out"
  assert_contains "$out" "pull-request-head-repository-mismatch" \
    "a different repository lost its own reason"
  assert_not_reran "$repo" "case-insensitive explicit anchor"
  pass "fm-attest.sh: the explicit path matches one repository spelled two ways, and only that"
}

test_recheck_matches_a_resolved_head_repository_spelled_in_another_case() {
  local repo head out rc
  jq_or_skip "the resolved path reads a different field and needs its own case control" && return
  repo="$TMP_ROOT/recheck-case-resolved"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pulls_fixture_head_repo "$repo/pulls.json" "$head" example/repo 7 Example/Repo
  recheck_out "$repo" --head "$head" >/dev/null \
    || fail "the resolved path refused the same repository in another case"
  assert_reran "$repo" 100 "case-insensitive resolved path"
  rm -f "$repo/gh.log"
  pulls_fixture_head_repo "$repo/pulls.json" "$head" example/repo 7 Other/Repo
  out=$(recheck_out "$repo" --head "$head")
  rc=$?
  [ "$rc" -eq 1 ] || fail "the resolved path accepted a different repository (exit $rc): $out"
  assert_contains "$out" "pull-request-head-repository-mismatch" \
    "the resolved path lost the mismatch reason"
  assert_not_reran "$repo" "case-insensitive resolved anchor"
  pass "fm-attest.sh: the resolved path matches one repository spelled two ways, and only that"
}

# The bound is per repository, and a repository is not its spelling. Keying the
# ledger on the caller's text let three spent re-runs be followed by three more
# under another capitalisation of the same name, which is the bound this program
# exists to hold rather than to appear to hold.
test_recheck_bound_is_not_reset_by_respelling_the_repository() {
  local repo head out rc n
  jq_or_skip "the request bound survives the repository being retyped" && return
  repo="$TMP_ROOT/recheck-bound-spelling"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head" example/repo
  for n in 100 101 102; do
    runs_fixture "$repo/runs.json" "$head" "$n:1:completed:failure:7"
    recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
      || fail "re-evaluation $n was refused before the bound was spent"
  done
  runs_fixture "$repo/runs.json" "$head" 103:1:completed:failure:7
  out=$(recheck_out "$repo" --head "$head" --repo Example/Repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "another spelling of the same repository got a fresh bound (exit $rc): $out"
  assert_contains "$out" "recheck-budget-spent" "the bound was not what refused the retyped name"
  [ "$(grep -c -- '--method POST' "$repo/gh.log")" -eq 3 ] \
    || fail "the bound did not hold across two spellings of one repository"
  # The anchor: a genuinely different repository legitimately gets its own bound,
  # so this held the bound rather than simply refusing everything after three.
  pr_fixture "$repo/pr.json" open "$head" example/repo
  recheck_out "$repo" --head "$head" --repo other/repo --pr 7 >/dev/null \
    || fail "a different repository was denied its own bound"
  [ "$(grep -c -- '--method POST' "$repo/gh.log")" -eq 4 ] \
    || fail "a different repository did not get its own bound"
  pass "fm-attest.sh: the request bound is keyed on the repository, not on its spelling"
}

test_recheck_refuses_absent_and_unreadable_head_repositories() {
  local repo head out rc shape
  jq_or_skip "absent and unreadable PR head repositories are could-not-observe" && return
  repo="$TMP_ROOT/recheck-head-repository-unobservable"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  for shape in absent unreadable; do
    pr_fixture "$repo/pr.json" open "$head" "$shape"
    out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
    rc=$?
    [ "$rc" -eq 2 ] || fail "a $shape head repository was not could-not-observe (exit $rc): $out"
    assert_contains "$out" "pull-request-head-repository-$shape" "$shape did not have its own reason"
    assert_not_reran "$repo" "$shape head repository"
  done
  pr_fixture "$repo/pr.json" open "$head" example/repo
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the readable head repository control was refused"
  assert_reran "$repo" 100 "readable-head-repository control"
  pass "fm-attest.sh: absent and unreadable head repositories fail closed distinctly"
}

test_recheck_bounds_repeated_re_evaluation_of_one_head() {
  local repo head out rc ledger n
  jq_or_skip "repeated re-evaluation of one head is bounded" && return
  repo="$TMP_ROOT/recheck-bounded"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  # A fresh run identity each time, so the per-attempt guard above never fires
  # and the only thing that can stop this is the bound itself.
  for n in 100 101 102; do
    runs_fixture "$repo/runs.json" "$head" "$n:1:completed:failure:7"
    recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
      || fail "re-evaluation $n was refused before the bound"
  done
  runs_fixture "$repo/runs.json" "$head" 103:1:completed:failure:7
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a fourth re-evaluation of one head was not refused (exit $rc): $out"
  assert_contains "$out" "recheck-budget-spent" "the bound was not named as the reason"
  [ "$(grep -c -- '--method POST' "$repo/gh.log")" -eq 3 ] \
    || fail "the bound did not stop the fourth request"
  ledger=$(cat "$repo/.git/fm-attest-recheck.log")
  assert_contains "$ledger" "action=requested" "the ledger recorded no request to audit"
  pass "fm-attest.sh: re-evaluation of one head is bounded rather than repeated forever"
}

test_recheck_selects_the_run_that_started_last() {
  local repo head out
  jq_or_skip "the run that started last is the one re-run" && return
  repo="$TMP_ROOT/recheck-latest-run"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # Two failed runs on one unchanged head, which is what a synchronize followed
  # by any other subscribed event leaves behind. The merge guard reduces a
  # check's attempts to the one that started last, so re-running an older run
  # would leave the newer failure speaking for the check.
  pr_fixture "$repo/pr.json" open "$head"
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7 220:1:completed:failure:7
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7) \
    || fail "two failed runs on one head refused re-evaluation: $out"
  assert_reran "$repo" 220 "latest-run"
  pass "fm-attest.sh: the run that started last is the one re-evaluated"
}

test_recheck_ignores_runs_belonging_to_another_head() {
  local repo head other out rc
  jq_or_skip "a run for another head is not evidence about this one" && return
  repo="$TMP_ROOT/recheck-other-head"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  other=1111111111111111111111111111111111111111
  pr_fixture "$repo/pr.json" open "$head"
  # GitHub answered, and every run it returned belongs to a different commit.
  printf '{"total_count":1,"workflow_runs":[{"id":101,"run_attempt":1,"status":"completed","conclusion":"failure","head_sha":"%s","pull_requests":[{"number":7}]}]}\n' \
    "$other" > "$repo/runs.json"
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a run for another head was treated as this head's (exit $rc): $out"
  assert_contains "$out" "no-applicable-run" "another head's run was not excluded by reason"
  assert_not_reran "$repo" "other-head"
  # The matched control: the same listing with this head's own run in it.
  runs_fixture "$repo/runs.json" "$head" 101:1:completed:failure:7
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the same listing naming this head was still refused"
  assert_reran "$repo" 101 "other-head control"
  pass "fm-attest.sh: a run for another commit is never this head's applicable run"
}

test_recheck_refuses_a_head_with_no_applicable_run() {
  local repo head out rc
  jq_or_skip "an empty applicable run set is not a passing check" && return
  repo="$TMP_ROOT/recheck-no-run"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  printf '{"total_count":0,"workflow_runs":[]}\n' > "$repo/runs.json"
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "an empty run set was not refused (exit $rc): $out"
  assert_contains "$out" "no-applicable-run" "an empty run set was not named as its own state"
  assert_not_reran "$repo" "no-run"
  pass "fm-attest.sh: a head with no applicable run is refused, never treated as passing"
}

test_recheck_refuses_a_truncated_run_listing() {
  local repo head out rc
  jq_or_skip "a listing GitHub did not return in full is no verdict" && return
  repo="$TMP_ROOT/recheck-truncated"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  # GitHub says there are more runs than it handed over, so the run that started
  # last may be one this never saw.
  printf '{"total_count":140,"workflow_runs":[{"id":100,"run_attempt":1,"status":"completed","conclusion":"failure","head_sha":"%s","pull_requests":[{"number":7}]}]}\n' \
    "$head" > "$repo/runs.json"
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a truncated listing was treated as a whole one (exit $rc): $out"
  assert_contains "$out" "forge-read-truncated" "a truncated listing was not named as such"
  assert_not_reran "$repo" "truncated"
  pass "fm-attest.sh: a truncated run listing reaches no verdict rather than a wrong one"
}

test_recheck_reports_an_unreadable_forge_as_no_verdict() {
  local repo head out rc
  jq_or_skip "a forge that could not be read is not a head with no runs" && return
  repo="$TMP_ROOT/recheck-forge-unreadable"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  rm -f "$repo/runs.json"
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  # Exit 2, not 1: a read that failed says nothing about the evidence, and the
  # exit status is what a caller branching on it reads.
  [ "$rc" -eq 2 ] || fail "an unreadable forge did not reach no verdict (exit $rc): $out"
  assert_contains "$out" "forge-unreadable" "an unreadable forge was not named as such"
  assert_not_contains "$out" "no-applicable-run" \
    "a forge this could not read was reported as a head with no runs"
  assert_not_reran "$repo" "forge-unreadable"
  pass "fm-attest.sh: a forge that could not be read is could-not-observe, never absence"
}

test_recheck_does_nothing_when_the_run_already_passed() {
  local repo head out rc
  jq_or_skip "a head whose check already passed needs no re-evaluation" && return
  repo="$TMP_ROOT/recheck-green"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  runs_fixture "$repo/runs.json" "$head" 100:2:completed:success:7
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 0 ] || fail "an already green head was reported as a fault: $out"
  assert_not_reran "$repo" "green"
  assert_contains "$out" "already passed" "a green run was not reported as one"
  pass "fm-attest.sh: a head whose check already passed is left alone"
}

test_recheck_refuses_a_head_the_request_has_moved_off() {
  local repo head out rc
  jq_or_skip "a moved pull request head invalidates the attempt" && return
  repo="$TMP_ROOT/recheck-moved"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open 1111111111111111111111111111111111111111
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a head the request moved off was still re-evaluated (exit $rc): $out"
  assert_contains "$out" "pull-request-head-moved" "a moved head was not named as such"
  assert_not_reran "$repo" "moved"
  # The matched control: the same request open on this exact head.
  pr_fixture "$repo/pr.json" open "$head"
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the same request open on this head was still refused"
  assert_reran "$repo" 100 "moved control"
  pass "fm-attest.sh: a pull request that moved off this head is not re-evaluated for it"
}

test_recheck_refuses_a_head_with_no_published_attestation() {
  local repo head later out rc
  jq_or_skip "a head with no published attestation is not re-evaluated" && return
  repo="$TMP_ROOT/recheck-unattested"
  new_published_repo "$repo"
  printf 'two\n' > "$repo/b.txt"
  git -C "$repo" add b.txt
  git -C "$repo" commit -qm two
  later=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" push -q origin fm/demo
  pr_fixture "$repo/pr.json" open "$later"
  runs_fixture "$repo/runs.json" "$later" 100:1:completed:failure:7
  out=$(recheck_out "$repo" --head "$later" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "an unattested head was still re-evaluated (exit $rc): $out"
  assert_contains "$out" "attestation-not-published-for-head" \
    "an unattested head was not refused for its own reason"
  assert_not_reran "$repo" "unattested"
  # The matched control: the head the published ref does attest.
  head=$(git -C "$repo" rev-parse 'HEAD^')
  pr_fixture "$repo/pr.json" open "$head"
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the head the published ref attests was still refused"
  assert_reran "$repo" 100 "unattested control"
  pass "fm-attest.sh: an attestation for another commit never re-evaluates this head"
}

test_recheck_reports_invalid_evidence_as_evidence_not_as_a_missed_step() {
  local repo head out rc
  jq_or_skip "invalid published evidence is a verdict on the evidence" && return
  repo="$TMP_ROOT/recheck-invalid-evidence"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # A note published for this head that names another commit. The check would
  # refuse it, so re-running the check could only reproduce that refusal, and
  # the reader must be sent to the evidence rather than to the forge.
  add_note "$repo" "$head" "$(good_note 1111111111111111111111111111111111111111)"
  git -C "$repo" push -q --force origin "$NOTES_REF:$NOTES_REF"
  pr_fixture "$repo/pr.json" open "$head"
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "invalid published evidence was still re-evaluated (exit $rc): $out"
  assert_contains "$out" "not attested (attestation-not-bound)" \
    "invalid evidence was not reported in the evidence's own words"
  assert_not_contains "$out" "not re-evaluated" \
    "invalid evidence was dressed up as a re-evaluation that merely did not happen"
  assert_not_reran "$repo" "invalid-evidence"
  pass "fm-attest.sh: invalid published evidence is refused as evidence, not re-triggered"
}

test_recheck_reports_a_run_still_in_flight_rather_than_guessing() {
  local repo head out rc
  jq_or_skip "a run still in flight is neither a pass nor a failure" && return
  repo="$TMP_ROOT/recheck-in-flight"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  runs_fixture "$repo/runs.json" "$head" 100:1:in_progress:none:7
  # No wait at all, so the case is about the answer rather than about how long
  # the bound is. The bound itself is a knob, and zero is one of its values.
  out=$(FM_ATTEST_RECHECK_WAIT=0 recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a run in flight was resolved into a verdict (exit $rc): $out"
  assert_contains "$out" "run-in-progress" "a run in flight was not named as its own state"
  assert_not_reran "$repo" "in-flight"
  pass "fm-attest.sh: a run still in flight is reported rather than resolved either way"
}

test_recheck_without_gh_reports_a_missing_tool_not_a_verdict() {
  local repo head out rc
  repo="$TMP_ROOT/recheck-no-gh"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  install_unbounded_path "$repo/bare"
  out=$(cd "$repo" && PATH="$repo/bare" "$ATTEST" recheck --head "$head" --repo example/repo --pr 7 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an absent gh reached a verdict (exit $rc): $out"
  assert_contains "$out" "forge-tool-missing" "an absent gh was not named as a missing tool"
  assert_not_contains "$out" "no-applicable-run" \
    "an absent gh was reported as a head with no runs"
  pass "fm-attest.sh: an absent gh is a missing tool, never a statement about the check"
}

test_recheck_reports_no_open_pull_request_as_such() {
  local repo head out rc
  jq_or_skip "a head carrying no open pull request has no check to re-evaluate" && return
  repo="$TMP_ROOT/recheck-no-pr"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # The landing-branch shape: validated and attested in its own right, proposed
  # nowhere. Resolution has to reach a github.com repository to ask at all.
  git -C "$repo" remote add upstream https://github.com/example/repo.git
  # A re-runnable failed run is in place throughout, so every "nothing to
  # re-evaluate" case below fails by re-running something rather than by running
  # out of fixtures. A case that can only fail for want of a fixture proves
  # nothing about the rule it names.
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  pulls_fixture "$repo/pulls.json" "$head"
  out=$(recheck_out "$repo" --head "$head")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a head with no open pull request was reported as a fault: $out"
  assert_contains "$out" "no open pull request" "an empty answer was not reported as one"
  # The same outcome from the other shape GitHub gives it: a repository that
  # does not carry this commit at all.
  pulls_fixture_commit_absent "$repo/pulls.json"
  out=$(recheck_out "$repo" --head "$head")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a repository without this commit was read as a failed read: $out"
  # And the third: a request on this exact head that is no longer open. GitHub
  # returns closed and merged requests here as well, and neither has a check
  # left for this to re-evaluate.
  pulls_fixture_state "$repo/pulls.json" example/repo 7 "$head" MERGED
  out=$(recheck_out "$repo" --head "$head")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a merged request on this head was treated as a fault (exit $rc): $out"
  assert_contains "$out" "no open pull request" \
    "a request that is not open was counted as one to re-evaluate"
  assert_not_reran "$repo" "merged-request"
  # And the fourth shape, which must NOT join them: a repository this could not
  # read at all. Reading that as "no pull request here" would exit 0 and do
  # nothing, which is the closest thing in this design to reporting a pass.
  rm -f "$repo/pulls.json"
  out=$(recheck_out "$repo" --head "$head")
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unreadable candidate repository was not could-not-observe (exit $rc): $out"
  assert_contains "$out" "forge-unreadable" "an unreadable candidate was not named as such"
  assert_not_contains "$out" "no open pull request" \
    "a repository this could not read was reported as one with no pull request"
  assert_not_reran "$repo" "no-pr"
  # The matched control: the same head with one open request on it.
  pulls_fixture "$repo/pulls.json" "$head" example/repo:7
  recheck_out "$repo" --head "$head" >/dev/null \
    || fail "the same head with an open request was not re-evaluated"
  assert_reran "$repo" 100 "no-pr control"
  pass "fm-attest.sh: a head carrying no open pull request is an outcome, not a fault"
}

test_recheck_ignores_a_request_this_commit_is_only_associated_with() {
  local repo head out rc
  jq_or_skip "a request this commit merely appears in is not a request open on it" && return
  repo="$TMP_ROOT/recheck-associated-only"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" remote add upstream https://github.com/example/repo.git
  # GitHub associates a pull request with every commit that was ever in its
  # history, so a request whose head has moved past this commit still comes back
  # here. Re-evaluating it would judge a head this attestation does not cover.
  pulls_fixture_other_head "$repo/pulls.json" example/repo 7 \
    1111111111111111111111111111111111111111
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  out=$(recheck_out "$repo" --head "$head")
  rc=$?
  [ "$rc" -eq 0 ] || fail "an association-only request was treated as a fault (exit $rc): $out"
  assert_contains "$out" "no open pull request" \
    "a request open on another head was counted as one open on this head"
  assert_not_reran "$repo" "associated-only"
  # The matched control: the same request, open on this exact head.
  pulls_fixture "$repo/pulls.json" "$head" example/repo:7
  recheck_out "$repo" --head "$head" >/dev/null \
    || fail "the same request open on this head was refused"
  assert_reran "$repo" 100 "associated-only control"
  pass "fm-attest.sh: only a request open ON this head resolves to this head"
}

test_recheck_refuses_to_choose_between_two_open_pull_requests() {
  local repo head out rc
  jq_or_skip "one head on two open pull requests is not chosen between" && return
  repo="$TMP_ROOT/recheck-ambiguous"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" remote add upstream https://github.com/example/repo.git
  pulls_fixture "$repo/pulls.json" "$head" example/repo:7 other/repo:9
  out=$(recheck_out "$repo" --head "$head")
  rc=$?
  [ "$rc" -eq 1 ] || fail "one head on two requests was resolved anyway (exit $rc): $out"
  assert_contains "$out" "pull-request-ambiguous" "the ambiguity was not named as such"
  assert_not_reran "$repo" "ambiguous"
  pass "fm-attest.sh: one head on two open pull requests is refused rather than guessed"
}

test_recheck_dry_run_asks_the_forge_to_do_nothing() {
  local repo head out rc
  jq_or_skip "a dry run reports what it would do and does none of it" && return
  repo="$TMP_ROOT/recheck-dry-run"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  out=$(recheck_out "$repo" --head "$head" --repo example/repo --pr 7 --dry-run)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a dry run was refused: $out"
  assert_contains "$out" "would re-run" "a dry run did not say what it would have done"
  assert_not_reran "$repo" "dry-run"
  [ ! -f "$repo/.git/fm-attest-recheck.log" ] \
    || assert_not_contains "$(cat "$repo/.git/fm-attest-recheck.log")" "action=requesting" \
      "a dry run recorded a request it never made"
  # The matched control: the same call without --dry-run.
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the same call without --dry-run was refused"
  assert_reran "$repo" 100 "dry-run control"
  pass "fm-attest.sh: a dry run names the re-run it would make and makes none"
}

test_recheck_refuses_half_a_pull_request_identity() {
  local repo head out rc
  repo="$TMP_ROOT/recheck-half-identity"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # A number without the repository holding it names nothing, and resolving the
  # other half would answer a different question than the one asked.
  out=$(recheck_out "$repo" --head "$head" --pr 7)
  rc=$?
  [ "$rc" -eq 2 ] || fail "half a pull request identity was accepted (exit $rc): $out"
  assert_contains "$out" "given together or not at all" \
    "half an identity was not refused in plain words"
  out=$(recheck_out "$repo" --head not-a-sha)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a head that is not a sha was accepted (exit $rc): $out"
  assert_contains "$out" "40-character lowercase sha" "an unusable head was not named as such"
  assert_not_reran "$repo" "half-identity"
  pass "fm-attest.sh: an argument this cannot act on is a usage error, named in plain words"
}

test_recheck_records_every_decision_it_made() {
  local repo head ledger
  jq_or_skip "every decision is recorded where it can be audited" && return
  repo="$TMP_ROOT/recheck-ledger"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  recheck_out "$repo" --head "$head" --repo example/repo --pr 7 >/dev/null \
    || fail "the re-evaluation was refused"
  ledger="$repo/.git/fm-attest-recheck.log"
  [ -f "$ledger" ] || fail "no re-evaluation record was written"
  # Repository, pull request and head together, so a record can be matched back
  # to exactly one thing that was re-triggered.
  assert_contains "$(cat "$ledger")" "repo=example/repo pr=7 head=$head" \
    "the record did not bind repository, pull request and head"
  assert_contains "$(cat "$ledger")" "run=100 attempt=1 action=requested" \
    "the record did not name what was re-triggered"
  pass "fm-attest.sh: every re-evaluation decision is recorded with what it bound"
}

test_recheck_reports_a_refused_rerun_without_claiming_one() {
  local repo head out rc
  jq_or_skip "a re-run GitHub refused is reported as refused" && return
  repo="$TMP_ROOT/recheck-rerun-refused"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  pr_fixture "$repo/pr.json" open "$head"
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  out=$(FM_TEST_RERUN_RC=1 recheck_out "$repo" --head "$head" --repo example/repo --pr 7)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a refused re-run was not reported as reaching no verdict (exit $rc): $out"
  assert_contains "$out" "rerun-not-requested" "a refused re-run was not named as such"
  assert_contains "$out" "Actions tab" "the residual manual fallback was not named"
  assert_contains "$(cat "$repo/.git/fm-attest-recheck.log")" "action=refused" \
    "a refused request was not recorded"
  pass "fm-attest.sh: a re-run GitHub refused is reported, never counted as done"
}

test_write_re_evaluates_the_head_it_published() {
  local repo head out rc
  jq_or_skip "write re-evaluates the head it published, by default" && return
  repo="$TMP_ROOT/write-then-recheck"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  # Nothing published yet for this run: strip the note and the ref so write is
  # the thing that publishes it, exactly as a contributor runs it.
  git -C "$repo" update-ref -d "$NOTES_REF"
  git -C "$repo" push -q --delete origin "$NOTES_REF"
  # write hands recheck nothing but the head it published, so the pull request
  # is resolved rather than named, exactly as a contributor's run does it.
  git -C "$repo" remote add upstream https://github.com/example/repo.git
  pulls_fixture "$repo/pulls.json" "$head" example/repo:7
  runs_fixture "$repo/runs.json" "$head" 100:1:completed:failure:7
  out=$(
    cd "$repo" || exit 2
    PATH="$repo/stub/bin:$PATH" \
    FM_TEST_GH_LOG="$repo/gh.log" \
    FM_TEST_RUNS_JSON="$repo/runs.json" \
    FM_TEST_PR_JSON="$repo/pr.json" \
    FM_TEST_PULLS_JSON="$repo/pulls.json" \
      "$ATTEST" write --publish-repo "$(publish_target "$repo")" --publish-notes-ref "$NOTES_REF" 2>&1
  )
  rc=$?
  [ "$rc" -eq 0 ] || fail "write did not publish and re-evaluate in one step: $out"
  assert_contains "$out" "published $NOTES_REF" "write did not publish"
  assert_reran "$repo" 100 "write-then-recheck"
  assert_left_the_pull_request_alone "$repo" "write-then-recheck"
  pass "fm-attest.sh: write re-evaluates the head it published without being asked"
}

test_write_no_recheck_publishes_without_asking_the_forge() {
  local repo head out rc
  repo="$TMP_ROOT/write-no-recheck"
  new_published_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref -d "$NOTES_REF"
  git -C "$repo" push -q --delete origin "$NOTES_REF"
  out=$(
    cd "$repo" || exit 2
    PATH="$repo/stub/bin:$PATH" FM_TEST_GH_LOG="$repo/gh.log" \
      "$ATTEST" write --no-recheck --publish-repo "$(publish_target "$repo")" --publish-notes-ref "$NOTES_REF" 2>&1
  )
  rc=$?
  [ "$rc" -eq 0 ] || fail "write --no-recheck was refused: $out"
  assert_contains "$out" "published $NOTES_REF" "write --no-recheck did not publish"
  [ ! -s "$repo/gh.log" ] || fail "write --no-recheck still reached the forge"
  pass "fm-attest.sh: write --no-recheck publishes and asks the forge nothing"
}

# ---------------------------------------------------------------------------
# required, and the publication step it makes safe to run everywhere.
#
# Publication had no owner: nothing invoked it, so a validated candidate reached
# the delivery boundary with no evidence whenever nobody remembered to publish
# by hand. The step below is what an owner runs unconditionally, which is only
# safe if one predicate decides where it applies. Each case here is paired with
# one that differs by a single input, because a predicate that answered "not
# required" everywhere would silently restore exactly the recurrence it exists
# to end.
# ---------------------------------------------------------------------------

test_required_answers_a_repository_whose_checks_read_an_attestation() {
  local repo out rc
  repo="$TMP_ROOT/required-declared"
  new_repo "$repo"
  declare_unrelated_workflow "$repo"
  declare_gate "$repo"
  out=$(required_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a repository carrying the exact declaration was not reported as reading an attestation: $out"
  assert_contains "$out" ".github/no-mistakes-attestation" "the answer did not name the declaration it read"
  pass "fm-attest.sh: the exact declaration requires an attestation"
}

test_required_ignores_a_launcher_prefixed_invocation_without_the_marker() {
  local repo out rc
  repo="$TMP_ROOT/required-launcher-declared"
  new_repo "$repo"
  mkdir -p "$repo/.github/workflows"
  printf 'jobs:\n  check:\n    steps:\n      - run: bash bin/fm-attest.sh verify --head 0000\n' \
    > "$repo/.github/workflows/some-gate.yml"
  install_default_branch "$repo" absent
  out=$(required_out "$repo")
  rc=$?
  [ "$rc" -eq 1 ] || fail "workflow text replaced the absent declaration (exit $rc): $out"
  pass "fm-attest.sh: launcher-prefixed workflow text is not the declaration"
}

test_required_answers_the_repository_workflow_fixture() {
  local out rc
  out=$(required_out "$ROOT")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the repository's real declaration was missed (exit $rc): $out"
  assert_contains "$out" ".github/no-mistakes-attestation" \
    "the real declaration was not named"
  pass "fm-attest.sh: the repository carries the exact declaration"
}

test_required_answers_a_repository_whose_checks_read_none() {
  local repo out rc
  # The case above minus the one workflow that invokes the verifier.
  repo="$TMP_ROOT/required-undeclared"
  new_repo "$repo"
  declare_unrelated_workflow "$repo"
  install_default_branch "$repo" absent
  out=$(required_out "$repo")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a repository declaring no such gate did not answer 'not required' (exit $rc): $out"
  assert_contains "$out" "reads no head-bound attestation" \
    "the answer did not say the repository reads none"
  pass "fm-attest.sh: a repository with CI but no such gate reads no attestation"
}

test_required_ignores_a_commented_invocation() {
  local repo out rc
  repo="$TMP_ROOT/required-comment-only"
  new_repo "$repo"
  mkdir -p "$repo/.github/workflows"
  printf 'jobs:\n  check:\n    steps:\n      # - run: bin/fm-attest.sh verify --head 0000\n      - run: make\n' \
    > "$repo/.github/workflows/some-gate.yml"
  install_default_branch "$repo" absent
  out=$(required_out "$repo")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a commented invocation declared the gate (exit $rc): $out"
  pass "fm-attest.sh: a commented invocation does not declare the gate"
}

test_required_ignores_an_invocation_inside_prose() {
  local repo out rc
  repo="$TMP_ROOT/required-prose-only"
  new_repo "$repo"
  mkdir -p "$repo/.github/workflows"
  printf 'name: "Documentation mentioning bin/fm-attest.sh for maintainers"\njobs:\n  check:\n    steps:\n      - run: make\n' \
    > "$repo/.github/workflows/some-gate.yml"
  install_default_branch "$repo" absent
  out=$(required_out "$repo")
  rc=$?
  [ "$rc" -eq 1 ] || fail "an invocation token inside prose declared the gate (exit $rc): $out"
  pass "fm-attest.sh: prose mentioning the verifier does not declare the gate"
}

test_required_ignores_a_bare_invocation_without_the_marker() {
  local repo out rc
  repo="$TMP_ROOT/required-bare-without-marker"
  new_repo "$repo"
  mkdir -p "$repo/.github/workflows"
  printf 'jobs:\n  check:\n    steps:\n      - run: bin/fm-attest.sh verify --head 0000\n' \
    > "$repo/.github/workflows/some-gate.yml"
  install_default_branch "$repo" absent
  out=$(required_out "$repo")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a bare workflow invocation replaced the absent declaration (exit $rc): $out"
  pass "fm-attest.sh: bare workflow text is not the declaration"
}

test_required_reports_a_symlink_declaration_as_neither() {
  local repo out rc
  repo="$TMP_ROOT/required-symlink"
  new_repo "$repo"
  mkdir -p "$repo/.github"
  printf 'fm-attest.v1 required\n' > "$repo/target"
  ln -s ../target "$repo/.github/no-mistakes-attestation"
  out=$(required_out "$repo")
  rc=$?
  [ "$rc" -eq 2 ] || fail "a symlink declaration was resolved into an answer (exit $rc): $out"
  assert_contains "$out" "policy-declaration-not-regular" "the symlink did not report its own reason"
  assert_not_contains "$out" "reads no head-bound attestation" \
    "a symlink declaration was reported as absent"
  pass "fm-attest.sh: a symlink declaration answers neither way"
}

test_required_reports_wrong_declaration_content_as_neither() {
  local repo out rc
  repo="$TMP_ROOT/required-wrong-content"
  new_repo "$repo"
  mkdir -p "$repo/.github"
  printf 'fm-attest.v1 optional\n' > "$repo/.github/no-mistakes-attestation"
  out=$(required_out "$repo")
  rc=$?
  [ "$rc" -eq 2 ] || fail "wrong declaration content was resolved into an answer (exit $rc): $out"
  assert_contains "$out" "policy-declaration-invalid" "wrong declaration content did not report its own reason"
  pass "fm-attest.sh: wrong declaration content answers neither way"
}

test_required_reads_a_marker_from_the_repository_default_branch() {
  local repo out rc
  repo="$TMP_ROOT/required-default-marker"
  new_repo "$repo"
  install_default_branch "$repo" regular
  git -C "$repo" fetch -q origin main:refs/remotes/origin/main
  out=$(required_out "$repo" refs/remotes/origin/main)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a pre-marker candidate did not inherit the repository declaration (exit $rc): $out"
  assert_contains "$out" "refs/heads/policy" "the governed policy generation was not named"
  pass "fm-attest.sh: a pre-marker candidate reads the repository declaration"
}

# A venue whose current generation declares the gate, plus a supplied
# generation from before it did. Returns the bare venue path; the marker lives
# on the venue's HEAD and refs/heads/old is the pre-marker commit.
install_superseded_policy_venue() {
  local repo=$1 marker=${2:-current} policy old
  policy="$repo-superseded.git"
  old=$(git -C "$repo" rev-parse HEAD)
  case "$marker" in
    current)
      declare_gate "$repo"
      git -C "$repo" add .github
      git -C "$repo" commit -qm declaration
      ;;
    never)
      printf 'two\n' > "$repo/b.txt"
      git -C "$repo" add b.txt
      git -C "$repo" commit -qm advance
      ;;
    symlink)
      mkdir -p "$repo/.github"
      ln -s ../target "$repo/.github/no-mistakes-attestation"
      git -C "$repo" add .github
      git -C "$repo" commit -qm declaration
      ;;
    invalid)
      mkdir -p "$repo/.github"
      printf 'fm-attest.v1 optional\n' > "$repo/.github/no-mistakes-attestation"
      git -C "$repo" add .github
      git -C "$repo" commit -qm declaration
      ;;
    *) fail "unknown superseded fixture: $marker" ;;
  esac
  git init -q --bare "$policy"
  git -C "$repo" push -q --force "$policy" HEAD:refs/heads/policy
  git -C "$repo" push -q --force "$policy" "$old:refs/heads/old"
  git --git-dir="$policy" symbolic-ref HEAD refs/heads/policy
  printf '%s\n' "$policy"
}

superseded_out() {
  # ${4-...} rather than ${4:-...}: a caller passing an EMPTY policy ref is
  # stating that nothing recorded one, and that is a case under test. The
  # colon form would silently substitute the default and test the opposite.
  local repo=$1 policy=$2 generation=$3 owner_ref=${4-refs/heads/policy}
  # The generation and the ref that OWNS policy are supplied separately,
  # because they are separate facts and the whole stale-generation question
  # only exists where they disagree. Currency is read from the named ref, never
  # from the venue's bare HEAD.
  ( cd "$repo" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$policy.insteadOf" \
      GIT_CONFIG_VALUE_0=https://github.com/fixture/policy.git \
      "$ATTEST" required --policy-venue github.com/fixture/policy \
      --policy-url https://github.com/fixture/policy.git \
      --policy-generation "$generation" --policy-ref "$owner_ref" 2>&1 )
}

test_required_reports_a_superseded_policy_generation_as_neither() {
  local repo policy current out rc
  # Topology case T7. A declaration absent from a generation the venue has
  # moved past is a fact about that generation's age, not about the venue, and
  # reporting it as not-required is the ruling's forbidden reinterpretation of
  # a missing marker: a candidate based before the venue adopted the gate would
  # publish nothing and say nothing, which is the recurrence itself.
  repo="$TMP_ROOT/required-superseded-generation"
  new_repo "$repo"
  policy=$(install_superseded_policy_venue "$repo" current)
  current=$(git --git-dir="$policy" rev-parse HEAD)
  out=$(superseded_out "$repo" "$policy" refs/heads/old)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a superseded policy generation became an answer (exit $rc): $out"
  assert_contains "$out" "policy-generation-stale" \
    "the superseded generation did not report its own reason"
  assert_contains "$out" "$current" \
    "the superseded-generation refusal did not name the venue's current generation"
  assert_not_contains "$out" "reads no head-bound attestation" \
    "a superseded generation was reported as a venue that declares nothing"
  pass "fm-attest.sh: a superseded policy generation answers neither way"
}

test_required_still_answers_not_required_when_the_venue_never_declared() {
  local repo policy out rc
  # The case above with one input changed: the venue's CURRENT generation
  # carries no declaration either. Both generations agree, so the absence is a
  # fact about the venue and not-required is correct. Without this control the
  # fix above would be satisfied by turning every non-current generation into
  # could-not-observe, which would break the ordinary path the ruling's own
  # watched red depends on.
  repo="$TMP_ROOT/required-never-declared"
  new_repo "$repo"
  policy=$(install_superseded_policy_venue "$repo" never)
  out=$(superseded_out "$repo" "$policy" refs/heads/old)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a venue that never declared did not answer not-required (exit $rc): $out"
  assert_contains "$out" "carries no" "the answer did not name the absent declaration"
  assert_not_contains "$out" "policy-generation-stale" \
    "an absence both generations agree on was reported as superseded"
  pass "fm-attest.sh: a generation the venue never declared at still answers not-required"
}

test_required_reports_a_current_generation_symlink_as_unobservable() {
  local repo policy out rc
  repo="$TMP_ROOT/required-current-generation-symlink"
  new_repo "$repo"
  policy=$(install_superseded_policy_venue "$repo" symlink)
  out=$(superseded_out "$repo" "$policy" refs/heads/old)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a current-generation symlink became an answer (exit $rc): $out"
  assert_contains "$out" "policy-generation-currency-unobservable" \
    "the current-generation symlink did not report unobservable currency"
  assert_not_contains "$out" "policy-generation-stale" \
    "the current-generation symlink was credited as a declaration"
  pass "fm-attest.sh: a current-generation symlink leaves currency unobservable"
}

test_required_reports_current_generation_wrong_content_as_unobservable() {
  local repo policy out rc
  repo="$TMP_ROOT/required-current-generation-invalid"
  new_repo "$repo"
  policy=$(install_superseded_policy_venue "$repo" invalid)
  out=$(superseded_out "$repo" "$policy" refs/heads/old)
  rc=$?
  [ "$rc" -eq 2 ] || fail "current-generation wrong content became an answer (exit $rc): $out"
  assert_contains "$out" "policy-generation-currency-unobservable" \
    "current-generation wrong content did not report unobservable currency"
  assert_not_contains "$out" "policy-generation-stale" \
    "current-generation wrong content was credited as a declaration"
  pass "fm-attest.sh: invalid current-generation content leaves currency unobservable"
}

test_required_reports_an_unresolvable_default_ref_as_neither() {
  local repo policy out rc
  repo="$TMP_ROOT/required-default-unresolvable"
  new_repo "$repo"
  policy="$TMP_ROOT/missing-policy.git"
  git init -q --bare "$policy"
  out=$(cd "$repo" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$policy.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/fixture/policy.git \
    "$ATTEST" required --policy-venue github.com/fixture/policy \
    --policy-url https://github.com/fixture/policy.git \
    --policy-generation refs/heads/missing --policy-ref refs/heads/policy 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unresolvable default ref became an answer (exit $rc): $out"
  assert_contains "$out" "policy-ref-unreadable" "the unresolved policy ref did not report its own reason"
  pass "fm-attest.sh: an unresolvable repository default answers neither way"
}

test_required_refuses_a_foreign_local_policy_ref() {
  local repo policy out rc
  repo="$TMP_ROOT/required-foreign-local-ref"
  policy="$TMP_ROOT/foreign-policy.git"
  new_repo "$repo"
  declare_gate "$repo"
  git -C "$repo" add .github
  git -C "$repo" commit -qm foreign-policy
  git -C "$repo" branch policy
  git init -q --bare "$policy"
  out=$(cd "$repo" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$policy.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/fixture/policy.git \
    "$ATTEST" required --policy-venue github.com/fixture/policy \
    --policy-url https://github.com/fixture/policy.git \
    --policy-generation refs/heads/policy --policy-ref refs/heads/policy 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a foreign local policy ref decided venue policy (exit $rc): $out"
  assert_contains "$out" "policy-ref-unreadable" "the foreign ref did not report a venue fetch failure"
  pass "fm-attest.sh: a foreign local ref cannot decide venue policy"
}

test_required_cleans_the_policy_ref_when_fetch_is_interrupted() {
  local repo policy wrapper real_git fetched out rc refs
  repo="$TMP_ROOT/required-interrupted-fetch"
  policy="$TMP_ROOT/required-interrupted-policy.git"
  wrapper="$TMP_ROOT/required-interrupted-bin"
  fetched="$TMP_ROOT/required-interrupted-fetched"
  new_repo "$repo"
  declare_gate "$repo"
  git -C "$repo" add .github
  git -C "$repo" commit -qm policy
  git init -q --bare "$policy"
  git -C "$repo" push -q "$policy" HEAD:refs/heads/policy
  real_git=$(command -v git)
  mkdir -p "$wrapper"
  # shellcheck disable=SC2016 # These fixture lines must preserve literal wrapper expansions.
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "$1" = fetch ]; then' \
    '  "$FM_TEST_REAL_GIT" "$@" || exit' \
    '  : > "$FM_TEST_FETCHED"' \
    '  sleep 30' \
    '  exit 0' \
    'fi' \
    'exec "$FM_TEST_REAL_GIT" "$@"' > "$wrapper/git"
  chmod +x "$wrapper/git"
  out=$(cd "$repo" && fm_run_timed 1 env PATH="$wrapper:$PATH" \
    FM_TEST_REAL_GIT="$real_git" FM_TEST_FETCHED="$fetched" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$policy.insteadOf" \
    GIT_CONFIG_VALUE_0=https://github.com/fixture/policy.git \
    "$ATTEST" required --policy-venue github.com/fixture/policy \
    --policy-url https://github.com/fixture/policy.git \
    --policy-generation refs/heads/policy --policy-ref refs/heads/policy 2>&1)
  rc=$?
  [ "$rc" -eq 124 ] || fail "the interrupted policy fetch did not hit its bound (exit $rc): $out"
  assert_present "$fetched" "the interruption happened before the policy ref was fetched"
  refs=$(git -C "$repo" for-each-ref --format='%(refname)' refs/fm-attest/policy-)
  [ -z "$refs" ] || fail "an interrupted policy fetch leaked scratch refs: $refs"
  pass "fm-attest.sh: an interrupted policy fetch leaves no scratch ref"
}

test_required_reports_a_default_branch_symlink_as_neither() {
  local repo out rc
  repo="$TMP_ROOT/required-default-symlink"
  new_repo "$repo"
  install_default_branch "$repo" symlink
  git -C "$repo" fetch -q origin main:refs/remotes/origin/main
  out=$(required_out "$repo" refs/remotes/origin/main)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a default-branch symlink became an answer (exit $rc): $out"
  assert_contains "$out" "policy-declaration-not-regular" \
    "the default-branch symlink did not report its own reason"
  pass "fm-attest.sh: a default-branch symlink answers neither way"
}

test_declaration_check_refuses_a_consumer_without_the_marker() {
  local repo out rc
  repo="$TMP_ROOT/declaration-invariant-missing"
  new_repo "$repo"
  mkdir -p "$repo/.github/workflows"
  printf 'jobs:\n  check:\n    steps:\n      - run: timeout 30 bin/fm-attest.sh verify --head 0000\n' \
    > "$repo/.github/workflows/gate.yml"
  out=$(cd "$repo" && "$ATTEST" declaration-check 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a consumer without the declaration passed the invariant (exit $rc): $out"
  assert_contains "$out" "declaration-missing" "the invariant did not name the missing declaration"
  pass "fm-attest.sh: an attestation consumer must carry the declaration"
}

test_declaration_check_accepts_the_repository_invariant() {
  local out rc
  out=$(cd "$ROOT" && "$ATTEST" declaration-check 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the repository failed its attestation declaration invariant (exit $rc): $out"
  assert_contains "$out" "declaration invariant satisfied" \
    "the repository invariant did not report its positive verdict"
  pass "fm-attest.sh: the repository satisfies its declaration invariant"
}

test_write_only_if_required_publishes_nothing_where_no_check_reads_it() {
  local repo fork head out rc
  repo="$TMP_ROOT/write-only-if-required-none"
  fork="$TMP_ROOT/write-only-if-required-none-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  git -C "$repo" push -q origin HEAD:refs/heads/main
  git --git-dir="$fork" symbolic-ref HEAD refs/heads/main
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"

  # The negative control first: without the flag this same fixture publishes, so
  # the silence below is the flag's doing and not a fixture that could never
  # have published anything.
  out=$(publish_only_if_required_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the publication step failed where no check reads it: $out"
  assert_contains "$out" "nothing published" "the step did not say it published nothing"
  [ -z "$(published_heads "$fork")" ] || fail "a repository that reads no attestation was published to"

  declare_gate "$repo"
  git -C "$repo" add .github
  git -C "$repo" commit -qm gate
  head=$(git -C "$repo" rev-parse HEAD)
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  out=$(publish_only_if_required_out "$repo")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the publication step was refused where a check reads it: $out"
  assert_contains "$(published_heads "$fork")" "$head" \
    "the repository whose check reads an attestation was not published to"
  pass "fm-attest.sh: the publication step touches only a repository whose checks read it"
}

test_write_only_if_required_stops_rather_than_guess_at_an_unreadable_declaration() {
  local repo fork head out rc
  repo="$TMP_ROOT/write-only-if-required-unreadable"
  fork="$TMP_ROOT/write-only-if-required-unreadable-fork.git"
  new_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"
  mkdir -p "$repo/.github"
  ln -s ../missing "$repo/.github/no-mistakes-attestation"
  out=$(publish_only_if_required_out "$repo")
  rc=$?
  # Publishing into a repository that never asked and skipping publication in
  # one that did are both wrong, so a failed read buys neither.
  [ "$rc" -eq 2 ] || fail "an unreadable declaration was resolved into an action (exit $rc): $out"
  assert_contains "$out" "declaration-not-regular" "the stop did not name its own cause"
  [ -z "$(published_heads "$fork")" ] || fail "an unreadable declaration still published"
  pass "fm-attest.sh: an unreadable declaration stops publication rather than guessing"
}

test_write_expect_head_binds_publication_to_the_request_head() {
  local repo fork head other out rc
  repo="$TMP_ROOT/write-expect-head"
  fork="$TMP_ROOT/write-expect-head-fork.git"
  new_repo "$repo"
  declare_gate "$repo"
  git -C "$repo" add .github
  git -C "$repo" commit -qm gate
  head=$(git -C "$repo" rev-parse HEAD)
  other=0123456789abcdef0123456789abcdef01234567
  git init -q --bare "$fork"
  git -C "$repo" remote add origin "$fork"
  install_pipeline_stub "$repo/stub" "$(run_status_toon fm/demo "${head:0:8}" completed)"

  out=$(publish_only_if_required_out "$repo" --expect-head "$other")
  rc=$?
  [ "$rc" -eq 1 ] || fail "publication for a different request head was not refused (exit $rc): $out"
  assert_contains "$out" "expected-head-mismatch" "the mismatch did not report its own reason"
  [ -z "$(published_heads "$fork")" ] || fail "a mismatch recorded or published evidence"

  out=$(publish_only_if_required_out "$repo" --expect-head "$head")
  rc=$?
  [ "$rc" -eq 0 ] || fail "publication for the matching request head failed: $out"
  assert_contains "$(published_heads "$fork")" "$head" \
    "the matching request head was not published"
  pass "fm-attest.sh: publication is bound to the request's exact head"
}

test_check_step_no_longer_sends_a_contributor_to_edit_the_request() {
  local dir script out rc
  # The message the workflow actually prints, lifted out of the workflow and run
  # as the workflow runs it. Once publishing re-evaluates the head on its own,
  # an instruction to close and reopen the request teaches work that is no
  # longer needed, and this is the only place that text exists.
  dir="$TMP_ROOT/step-no-manual-nudge"
  mkdir -p "$dir"
  install_verifier_stub "$dir" 1
  script="$dir/verify-step.sh"
  workflow_step_script 'Verify the head-bound no-mistakes attestation' > "$script"
  [ -s "$script" ] || fail "the verify step could not be lifted out of the workflow"
  out=$(cd "$dir" && HEAD_SHA=0123456789012345678901234567890123456789 \
    PR_NUMBER=1 PR_AUTHOR=someone HEAD_REPO_FULL=owner/fork \
    POLICY_VERIFIER="$dir/bin/fm-attest.sh" POLICY_SHA=policygeneration \
    bash "$script" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the refusal branch did not fail"
  assert_not_contains "$out" "close and reopen" \
    "the check still tells a contributor to close and reopen the pull request"
  assert_not_contains "$out" "edit its title or body" \
    "the check still tells a contributor to edit the pull request"
  assert_contains "$out" "bin/fm-attest.sh write" \
    "the check no longer names the command that publishes and re-evaluates"
  assert_contains "$out" "Actions tab" \
    "the check does not name the one fallback that remains"
  pass "fm-attest.sh: the check sends a contributor to publish, not to edit the request"
}

# ---------------------------------------------------------------------------
# The role tuple and the policy generation. Browser Sol 19/5431020714 requires
# each of these observed refusing, because each is a way the gate could be made
# to answer about the wrong subject: the wrong generation, the wrong repository,
# or a judge the candidate itself supplied.
# ---------------------------------------------------------------------------

# A venue with TWO unrelated histories, so "the generation supplied" and "the
# generation the policy ref leads" can be made to disagree in the one way that
# is not merely being older.
install_split_history_venue() {
  local repo=$1 policy
  policy="$repo-split.git"
  declare_gate "$repo"
  git -C "$repo" add .github
  git -C "$repo" commit -qm declaration
  git init -q --bare "$policy"
  git -C "$repo" push -q --force "$policy" HEAD:refs/heads/policy
  # An orphan: it carries the same declaration file and shares no commit with
  # the policy ref, which is exactly the shape that must not be read as an
  # older policy.
  git -C "$repo" checkout -q --orphan stranger
  git -C "$repo" add -A
  git -C "$repo" commit -qm stranger
  git -C "$repo" push -q --force "$policy" HEAD:refs/heads/stranger
  git -C "$repo" checkout -q fm/demo
  git --git-dir="$policy" symbolic-ref HEAD refs/heads/policy
  printf '%s\n' "$policy"
}

test_required_refuses_a_generation_the_policy_ref_does_not_reach() {
  local repo policy out rc
  # Watched red 1. The named policy ref resolves to one commit and the supplied
  # generation is an unrelated one. It carries a declaration, so reading it
  # alone answers "required" with complete confidence about a repository whose
  # policy it never expressed. Applicability is decided before the declaration
  # is credited, and an unrelated generation decides nothing.
  repo="$TMP_ROOT/required-unrelated-generation"
  new_repo "$repo"
  policy=$(install_split_history_venue "$repo")
  out=$(superseded_out "$repo" "$policy" refs/heads/stranger refs/heads/policy)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unrelated policy generation became an answer (exit $rc): $out"
  assert_contains "$out" "policy-generation-unrelated" \
    "the unrelated generation did not report its own reason"
  assert_not_contains "$out" "reads a head-bound attestation" \
    "a generation the policy ref never reached was credited as this venue's policy"
  pass "fm-attest.sh: a generation the named policy ref does not reach answers neither way"
}

test_required_reads_the_named_policy_ref_rather_than_the_venues_head() {
  local repo policy out rc
  # Watched reds 2 and 3 together, because they are one property observed from
  # both sides: the venue's HEAD says one thing and the named policy ref says
  # another, and the answer must follow the ref.
  #
  # HEAD here points at a branch that never declared, while refs/heads/policy
  # does. Reading HEAD - which is what this used to do - reports that a venue
  # requiring attestation requires none, and publication is then skipped in
  # exactly the repository that reads the note. The generation supplied is the
  # undeclared one, so nothing but the ref can produce the right answer.
  repo="$TMP_ROOT/required-ref-not-head"
  new_repo "$repo"
  policy=$(install_superseded_policy_venue "$repo" current)
  # Move the venue's HEAD onto the generation that predates the declaration.
  git --git-dir="$policy" symbolic-ref HEAD refs/heads/old
  out=$(superseded_out "$repo" "$policy" refs/heads/old refs/heads/policy)
  rc=$?
  [ "$rc" -eq 2 ] || fail "the venue's HEAD decided its policy (exit $rc): $out"
  assert_contains "$out" "policy-generation-stale" \
    "a superseded generation was not reported as superseded once HEAD disagreed with the policy ref"
  assert_not_contains "$out" "reads no head-bound attestation" \
    "the venue's HEAD overrode the ref recorded as owning its policy"
  pass "fm-attest.sh: policy follows the named ref, not the venue's HEAD"
}

test_required_refuses_when_no_ref_is_recorded_as_owning_policy() {
  local repo policy out rc
  # Watched red 4's precondition, and the one the old implementation answered by
  # substituting HEAD. With no ref recorded, whether the supplied generation is
  # current is not a question this can answer at all - and could-not-observe is
  # the only honest answer, because not-required would silently skip publishing
  # for every candidate based before a venue adopted the gate.
  repo="$TMP_ROOT/required-no-policy-ref"
  new_repo "$repo"
  policy=$(install_superseded_policy_venue "$repo" current)
  out=$(superseded_out "$repo" "$policy" refs/heads/old '')
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unrecorded policy ref produced an answer (exit $rc): $out"
  assert_contains "$out" "policy-ref-unrecorded" \
    "an unrecorded policy ref did not report its own reason"
  assert_not_contains "$out" "reads no head-bound attestation" \
    "an unanswerable currency question was reported as a venue that declares nothing"
  pass "fm-attest.sh: with no ref recorded as owning policy, currency answers neither way"
}

test_required_refuses_a_policy_ref_it_cannot_resolve() {
  local repo policy out rc
  # Watched red 4. A named ref that cannot be resolved at the effect boundary
  # leaves the supplied generation unproven, and an unproven generation carries
  # no authority - not to require, and above all not to excuse.
  repo="$TMP_ROOT/required-unresolvable-policy-ref"
  new_repo "$repo"
  policy=$(install_superseded_policy_venue "$repo" current)
  out=$(superseded_out "$repo" "$policy" refs/heads/policy refs/heads/no-such-ref)
  rc=$?
  [ "$rc" -eq 2 ] || fail "an unresolvable policy ref became an answer (exit $rc): $out"
  assert_contains "$out" "policy-ref-unresolvable" \
    "an unresolvable policy ref did not report its own reason"
  pass "fm-attest.sh: a policy ref that will not resolve answers neither way"
}

test_write_refuses_a_remote_that_addresses_another_repository() {
  local repo out rc before
  # Watched red 5. The remote resolves to a repository other than the one bound
  # to receive the note. Before this, the ambient remote won and the note landed
  # wherever it pointed; the refusal must come BEFORE the push, and the target
  # it would have written to must be untouched.
  repo="$TMP_ROOT/write-target-mismatch"
  new_published_repo "$repo"
  git -C "$repo" update-ref -d "$NOTES_REF"
  git -C "$repo" push -q --delete origin "$NOTES_REF" 2>/dev/null || true
  before=$(git -C "$repo" ls-remote origin "$NOTES_REF" 2>/dev/null || true)
  out=$(cd "$repo" && PATH="$repo/stub/bin:$PATH" "$ATTEST" write \
    --publish-repo github.com/someone/elsewhere 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a note was published through a remote addressing another repository: $out"
  assert_contains "$out" "publication-target-mismatch" \
    "the mismatched publication target did not report its own reason"
  assert_contains "$out" "github.com/someone/elsewhere" \
    "the refusal did not name the repository that was bound to receive the note"
  git -C "$repo" rev-parse --verify --quiet "$NOTES_REF" >/dev/null 2>&1 \
    && fail "a note was recorded locally despite the target being refused"
  [ "$(git -C "$repo" ls-remote origin "$NOTES_REF" 2>/dev/null || true)" = "$before" ] \
    || fail "the remote's notes ref moved despite the publication target being refused"
  pass "fm-attest.sh: a remote addressing another repository is refused before the push"
}

test_write_refuses_a_notes_ref_the_effect_plan_did_not_name() {
  local repo out rc
  # Watched red 6. The gate reads exactly one ref, so publishing to a different
  # one is evidence nothing will look at - indistinguishable at the boundary
  # from having published nothing.
  repo="$TMP_ROOT/write-notes-ref-mismatch"
  new_published_repo "$repo"
  out=$(cd "$repo" && PATH="$repo/stub/bin:$PATH" "$ATTEST" write \
    --publish-repo "$(publish_target "$repo")" \
    --publish-notes-ref refs/notes/no-mistakes \
    --notes-ref refs/notes/somewhere-else 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a note was published to a ref the effect plan did not name: $out"
  assert_contains "$out" "publication-notes-ref-mismatch" \
    "the mismatched notes ref did not report its own reason"
  git -C "$repo" rev-parse --verify --quiet refs/notes/somewhere-else >/dev/null 2>&1 \
    && fail "a note was recorded on the unplanned ref"
  pass "fm-attest.sh: a notes ref the effect plan did not name is refused before the push"
}

test_write_refuses_an_unbound_notes_ref() {
  local repo out rc
  repo="$TMP_ROOT/write-notes-ref-unbound"
  new_published_repo "$repo"
  out=$(cd "$repo" && PATH="$repo/stub/bin:$PATH" "$ATTEST" write \
    --publish-repo "$(publish_target "$repo")" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unbound notes ref was published: $out"
  assert_contains "$out" "publication-notes-ref-unbound" \
    "the unbound notes ref did not report its own reason"
  pass "fm-attest.sh: publication requires a bound notes ref"
}

test_write_binds_the_three_repository_roles_independently_on_a_fork() {
  local repo fork out rc
  # Watched red 7. The venue the request is raised at, the repository the branch
  # was pushed to, and the repository the note belongs on are three roles, and
  # on a fork layout they are three different repositories. Each is bound
  # separately here: origin FETCHES the parent and PUSHES the fork, the note is
  # bound to the fork, and only the fork may move.
  repo="$TMP_ROOT/write-fork-roles"
  new_repo "$repo"
  fork="$repo.fork.git"
  git init -q --bare "$fork"
  git init -q --bare "$repo.parent.git"
  git -C "$repo" remote add origin https://github.com/upstream/repo.git
  git -C "$repo" config remote.origin.pushurl https://github.com/contributor/repo.git
  git -C "$repo" config url."$fork".insteadOf https://github.com/contributor/repo.git
  git -C "$repo" config url."$repo.parent.git".insteadOf https://github.com/upstream/repo.git
  install_pipeline_stub "$repo/stub" \
    "$(run_status_toon fm/demo "$(git -C "$repo" rev-parse --short=8 HEAD)" completed)"
  install_gh_stub "$repo/stub"

  # The parent is where the request lives, so naming it as the note's home is
  # the inversion this must refuse rather than perform.
  out=$(cd "$repo" && PATH="$repo/stub/bin:$PATH" "$ATTEST" write --no-recheck \
    --publish-repo github.com/upstream/repo \
    --publish-notes-ref refs/notes/no-mistakes 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "the note was published to the venue rather than the head repository: $out"
  assert_contains "$out" "publication-target-mismatch" \
    "binding the note to the venue instead of the head repository was not refused"
  [ -z "$(git --git-dir="$repo.parent.git" for-each-ref refs/notes 2>/dev/null)" ] \
    || fail "the parent repository received a note"

  # The fork is the repository holding the head, and it alone moves.
  out=$(cd "$repo" && PATH="$repo/stub/bin:$PATH" "$ATTEST" write --no-recheck \
    --publish-repo github.com/contributor/repo \
    --publish-notes-ref refs/notes/no-mistakes 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "publication to the bound head repository was refused: $out"
  [ -n "$(git --git-dir="$fork" for-each-ref "$NOTES_REF" 2>/dev/null)" ] \
    || fail "the head repository did not receive the note"
  [ -z "$(git --git-dir="$repo.parent.git" for-each-ref refs/notes 2>/dev/null)" ] \
    || fail "the venue received a note as well as the head repository"
  pass "fm-attest.sh: venue, push target and note repository stay independently bound on a fork"
}

# The resolve step's own script, run as the workflow runs it, against a
# repository whose `pullrequest-source` remote is the governed venue. What it
# must never do is take the verifier from the checkout it is standing in.
new_policy_generation_fixture() {  # <dir> <candidate-verifier-body>
  local dir=$1 body=${2-} venue
  mkdir -p "$dir"
  venue="$dir/venue.git"
  git init -q "$dir/work"
  git -C "$dir/work" config user.email t@e && git -C "$dir/work" config user.name t
  mkdir -p "$dir/work/bin"
  # The AUTHORITATIVE verifier: it supports reconcile and refuses everything.
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
    printf 'case "${1:-}" in\n'
    printf '  --supports) exit 0 ;;\n'
    printf '  --print-format) echo "no-mistakes-attestation: v1" ;;\n'
    printf '  *) echo "authoritative verifier refused"; exit 1 ;;\n'
    printf 'esac\n'
  } > "$dir/work/bin/fm-attest.sh"
  chmod +x "$dir/work/bin/fm-attest.sh"
  git -C "$dir/work" add -A
  git -C "$dir/work" commit -qm policy
  git init -q --bare "$venue"
  git -C "$dir/work" push -q --force "$venue" HEAD:refs/heads/main

  # The CANDIDATE checkout, carrying whatever verifier the test wants it to.
  git init -q "$dir/candidate"
  git -C "$dir/candidate" config user.email t@e && git -C "$dir/candidate" config user.name t
  git -C "$dir/candidate" remote add pullrequest-source "$venue"
  mkdir -p "$dir/candidate/bin"
  if [ -n "$body" ]; then
    printf '%s\n' "$body" > "$dir/candidate/bin/fm-attest.sh"
    chmod +x "$dir/candidate/bin/fm-attest.sh"
  fi
  printf '%s\n' "$venue"
}

run_resolve_step() {  # <dir> [base-ref]
  local dir=$1 ref=${2:-main} script env_file
  script="$dir/resolve-step.sh"
  workflow_step_script 'Resolve the authoritative verifier from the governed policy generation' > "$script"
  [ -s "$script" ] || fail "the resolve step could not be lifted out of the workflow"
  env_file="$dir/github-env"
  : > "$env_file"
  ( cd "$dir/candidate" && RUNNER_TEMP="$dir/runner" GITHUB_ENV="$env_file" \
      BASE_REPO=owner/venue POLICY_REF="refs/heads/$ref" bash "$script" 2>&1 )
}

test_check_step_judges_a_candidate_by_the_governed_verifier_not_its_own() {
  local dir out rc verifier
  # Watched red 8. The candidate ships a verifier that passes everything. Under
  # the old shape the workflow ran exactly that program to decide whether to
  # accept exactly that change, so a contribution could widen what counts as
  # evidence and have the widened rule judge its own admission.
  dir="$TMP_ROOT/policy-candidate-permissive"
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
  new_policy_generation_fixture "$dir" \
    '#!/usr/bin/env bash
case "${1:-}" in --supports) exit 0 ;; --print-format) echo "anything goes" ;; *) exit 0 ;; esac'
  out=$(run_resolve_step "$dir")
  rc=$?
  [ "$rc" -eq 0 ] || fail "the resolve step failed on a readable venue (exit $rc): $out"
  verifier=$(sed -n 's/^POLICY_VERIFIER=//p' "$dir/github-env")
  [ -n "$verifier" ] || fail "no authoritative verifier was resolved: $out"
  case $verifier in
    "$dir/candidate"/*) fail "the authoritative verifier was taken from the candidate checkout" ;;
  esac
  "$verifier" verify --head deadbeef >/dev/null 2>&1 \
    && fail "the resolved verifier accepted what the governed generation refuses"
  assert_contains "$out" "is not authority here" \
    "the step did not state that the candidate's own verifier is not authority"
  pass "fm-attest.sh: the governed policy generation supplies the verifier, not the candidate"
}

test_check_step_does_not_become_a_pass_when_the_candidate_deletes_the_judge() {
  local dir out rc verifier
  # Watched red 9. The candidate carries NO bin/fm-attest.sh at all. Under the
  # old shape that turned a refusal into "the check could not look", which is a
  # different failure but still not the refusal the candidate had earned. The
  # governed verifier is unaffected by what the candidate did or did not ship.
  dir="$TMP_ROOT/policy-candidate-deleted"
  new_policy_generation_fixture "$dir" ''
  [ ! -e "$dir/candidate/bin/fm-attest.sh" ] || fail "the candidate fixture still carries a verifier"
  out=$(run_resolve_step "$dir")
  rc=$?
  [ "$rc" -eq 0 ] || fail "deleting the candidate's verifier stopped the resolve step (exit $rc): $out"
  verifier=$(sed -n 's/^POLICY_VERIFIER=//p' "$dir/github-env")
  [ -n "$verifier" ] || fail "no verifier was resolved once the candidate deleted its own: $out"
  "$verifier" verify --head deadbeef >/dev/null 2>&1 \
    && fail "a candidate that deleted its verifier was not judged by current policy"
  grep -q '^POLICY_UNRESOLVED=' "$dir/github-env" \
    && fail "deleting the candidate's verifier was reported as an unresolvable policy generation"
  pass "fm-attest.sh: deleting the candidate's verifier does not disarm the check"
}

test_check_step_reaches_no_verdict_rather_than_running_the_candidate() {
  local dir out rc
  # Watched red 10. The governed policy generation cannot be resolved. The one
  # thing that must NOT happen is the candidate's copy being run instead: a
  # fallback that reaches for the candidate whenever authority is unreachable is
  # self-ratification with an extra step in front of it. The step declares no
  # verifier, and the verify step then reports no verdict.
  local script out2
  dir="$TMP_ROOT/policy-unresolvable"
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
  new_policy_generation_fixture "$dir" \
    '#!/usr/bin/env bash
case "${1:-}" in --supports) exit 0 ;; *) exit 0 ;; esac'
  out=$(run_resolve_step "$dir" no-such-policy-ref)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the resolve step aborted rather than declaring the authority unresolved: $out"
  grep -q '^POLICY_UNRESOLVED=1' "$dir/github-env" \
    || fail "an unresolvable policy generation was not declared as one: $out"
  grep -q '^POLICY_VERIFIER=' "$dir/github-env" \
    && fail "a verifier was declared despite the policy generation being unresolvable"

  script="$dir/verify-step.sh"
  workflow_step_script 'Verify the head-bound no-mistakes attestation' > "$script"
  out2=$( cd "$dir/candidate" && HEAD_SHA=0123456789012345678901234567890123456789 \
    PR_NUMBER=1 PR_AUTHOR=someone HEAD_REPO_FULL=owner/fork POLICY_UNRESOLVED=1 \
    bash "$script" 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unobtainable authority let the check pass: $out2"
  assert_contains "$out2" "could not obtain the authoritative" \
    "the no-verdict outcome did not name the authority it could not obtain"
  assert_not_contains "$out2" "carries no verified no-mistakes attestation" \
    "an inability to obtain the judge borrowed the refusal's words"
  pass "fm-attest.sh: an unobtainable authority reaches no verdict rather than running the candidate"
}

# ---------------------------------------------------------------------------
# The acceptance runner's control flow. The exact-head REVISE on PR #134
# (applying 19/5431020714) found that protecting bin/fm-attest.sh left the
# workflow wrapper - the program that selects, sequences, or could bypass the
# verifier - in candidate hands. The law now: on pull_request_target the
# platform takes the workflow FILE from the governed branch, and the file runs
# bin/fm-attest-gate.sh out of the governed generation, so a candidate's edits
# to either are proposal-only. These tests pin both halves: the five wrapper
# tamperings are REAL programs under the preceding law, and INERT under this
# one, because nothing of the candidate's is ever consulted.
# ---------------------------------------------------------------------------

# The five wrapper tamperings the ruling names. Each writes a candidate copy of
# the workflow whose acceptance semantics differ from the governed file's.
install_tampered_workflow() {  # <dir> <tamper>
  local dir=$1 tamper=$2
  mkdir -p "$dir/.github/workflows"
  case $tamper in
    skip-policy-resolution)
      # (a) the policy-resolution step is deleted outright.
      awk '
        $0 == "      - name: Resolve the authoritative verifier from the governed policy generation" { skipping = 1 }
        skipping && /^      - name: / && $0 != "      - name: Resolve the authoritative verifier from the governed policy generation" { skipping = 0 }
        !skipping { print }
      ' "$WORKFLOW" > "$dir/.github/workflows/no-mistakes-required.yml"
      ;;
    substitute-candidate-verifier)
      # (b) the resolved verifier is pointed at the candidate's own copy.
      # shellcheck disable=SC2016  # The unexpanded text is what the workflow carries.
      sed 's|POLICY_VERIFIER=${policy_dir}/bin/fm-attest.sh|POLICY_VERIFIER=${PWD}/bin/fm-attest.sh|' \
        "$WORKFLOW" > "$dir/.github/workflows/no-mistakes-required.yml"
      ;;
    force-verify-success)
      # (c) the verify step is made to succeed before it looks at anything.
      sed 's|^          set -eu$|          set -eu\n          exit 0|' \
        "$WORKFLOW" > "$dir/.github/workflows/no-mistakes-required.yml"
      ;;
    remove-verify-step)
      # (d) the verify step is deleted outright.
      awk '
        $0 == "      - name: Verify the head-bound no-mistakes attestation" { skipping = 1 }
        skipping && /^      - name: / && $0 != "      - name: Verify the head-bound no-mistakes attestation" { skipping = 0 }
        !skipping { print }
      ' "$WORKFLOW" > "$dir/.github/workflows/no-mistakes-required.yml"
      ;;
    change-policy-ref-selection)
      # (e) the ref policy is read from is redirected to a candidate branch.
      # shellcheck disable=SC2016  # The unexpanded text is what the workflow carries.
      sed 's|POLICY_REF: refs/heads/${{ github.event.pull_request.base.ref }}|POLICY_REF: refs/heads/attacker-policy|' \
        "$WORKFLOW" > "$dir/.github/workflows/no-mistakes-required.yml"
      ;;
    *) fail "unknown wrapper tamper: $tamper" ;;
  esac
}

wrapper_tampers='skip-policy-resolution substitute-candidate-verifier force-verify-success remove-verify-step change-policy-ref-selection'

# Extract a named step from an arbitrary workflow file, the same way
# workflow_step_script extracts from the repository's own.
workflow_step_script_from() {  # <file> <step-name>
  local file=$1 want=$2
  awk -v want="$want" '
    /^      - / { in_step = 0; collecting = 0 }
    $0 == "      - name: " want { in_step = 1; next }
    in_step && $0 == "        run: |" { collecting = 1; next }
    !collecting { next }
    $0 == "" { print ""; next }
    substr($0, 1, 10) == "          " { print substr($0, 11); next }
    { collecting = 0; in_step = 0 }
  ' "$file"
}

test_workflow_subscribes_the_governed_event_and_checks_out_its_generation() {
  local on_block ref_line
  # The platform rule this whole repair leans on: pull_request_target executes
  # the workflow file from the governed branch. A file that does not subscribe
  # it has no governed leg at all, and a target leg that checks out the
  # candidate head would execute candidate code with the governed file.
  on_block=$(awk '/^on:$/,/^permissions:/' "$WORKFLOW")
  printf '%s\n' "$on_block" | grep -q 'pull_request_target:' \
    || fail "the workflow does not subscribe pull_request_target, so no governed leg exists"
  printf '%s\n' "$on_block" | grep -q '  pull_request:' \
    || fail "the transitional pull_request leg is gone before a descendant generation may remove it"
  # shellcheck disable=SC2016  # The unexpanded expression is the asserted file text.
  ref_line=$(grep -F "ref: \${{ github.event_name == 'pull_request' && github.event.pull_request.head.sha || '' }}" "$WORKFLOW" || true)
  [ -n "$ref_line" ] \
    || fail "the checkout does not send the governed leg to the base generation and the transitional leg to the head"
  # The governed leg refuses to exist without the gate program beside the
  # verifier, and the verify step dispatches the governed gate before any
  # inline flow can run.
  workflow_step_script 'Resolve the authoritative verifier from the governed policy generation' \
    | grep -q 'bin/fm-attest-gate.sh' \
    || fail "the resolve step never selects the governed acceptance gate"
  workflow_step_script 'Verify the head-bound no-mistakes attestation' \
    | grep -q 'POLICY_GATE' \
    || fail "the verify step never dispatches the governed acceptance gate"
  pass "fm-attest.sh: the workflow subscribes the governed event and checks out its generation"
}

test_governed_workflow_resolves_and_dispatches_its_own_verifier() {
  local dir env_file resolve_script verify_script verifier gate policy_sha out rc
  dir="$TMP_ROOT/governed-workflow-dispatch"
  mkdir -p "$dir/bin" "$dir/.github/workflows"
  cp "$WORKFLOW" "$dir/.github/workflows/no-mistakes-required.yml"
  cp "$ROOT/bin/fm-attest-gate.sh" "$dir/bin/fm-attest-gate.sh"
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --supports) exit 0 ;; --print-format) echo fmt ;; *) exit 1 ;; esac\n' \
    > "$dir/bin/fm-attest.sh"
  chmod +x "$dir/bin/fm-attest-gate.sh" "$dir/bin/fm-attest.sh"
  git -C "$dir" init -q .
  git -C "$dir" add -A
  git -C "$dir" -c user.email=t@e -c user.name=t commit -qm policy
  policy_sha=$(git -C "$dir" rev-parse HEAD)

  resolve_script="$dir/resolve-step.sh"
  workflow_step_script_from "$dir/.github/workflows/no-mistakes-required.yml" \
    'Resolve the authoritative verifier from the governed policy generation' > "$resolve_script"
  env_file="$dir/github-env"
  : > "$env_file"
  out=$(cd "$dir" && GITHUB_ENV="$env_file" EVENT_NAME=pull_request_target \
    BASE_REPO=owner/venue POLICY_REF=refs/heads/main bash "$resolve_script" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "the governed resolve step failed (exit $rc): $out"
  verifier=$(sed -n 's/^POLICY_VERIFIER=//p' "$env_file")
  gate=$(sed -n 's/^POLICY_GATE=//p' "$env_file")
  [ "$verifier" = "$dir/bin/fm-attest.sh" ] \
    || fail "the governed resolve step did not select its own verifier: $verifier"
  [ "$gate" = "$dir/bin/fm-attest-gate.sh" ] \
    || fail "the governed resolve step did not select its own gate: $gate"

  verify_script="$dir/verify-step.sh"
  workflow_step_script_from "$dir/.github/workflows/no-mistakes-required.yml" \
    'Verify the head-bound no-mistakes attestation' > "$verify_script"
  out=$(cd "$dir" && POLICY_VERIFIER="$verifier" POLICY_GATE="$gate" POLICY_SHA="$policy_sha" \
    HEAD_SHA=0123456789012345678901234567890123456789 HEAD_REPO_FULL=owner/fork \
    BASE_REPO=owner/venue PR_NUMBER=1 PR_AUTHOR=someone bash "$verify_script" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "the governed workflow did not dispatch its refusing gate (exit $rc): $out"
  assert_contains "$out" "carries no verified no-mistakes attestation" \
    "the governed workflow did not reach its gate's refusal"
  assert_not_contains "$out" "could not obtain the authoritative" \
    "the governed workflow stopped at the missing-verifier guard"
  pass "fm-attest.sh: the governed workflow resolves and dispatches its own verifier"
}

test_wrapper_tampering_is_real_under_the_preceding_law() {
  local dir tamper file
  # The RED half. Each tamper, were the candidate's file still the acceptance
  # program - which is exactly what the preceding law's pull_request leg runs -
  # carries different executable semantics than the governed file. Without
  # this, the green half below could be satisfied by tamperings that change
  # nothing.
  dir="$TMP_ROOT/wrapper-tamper-real"
  for tamper in $wrapper_tampers; do
    rm -rf "$dir"; mkdir -p "$dir"
    install_tampered_workflow "$dir" "$tamper"
    file="$dir/.github/workflows/no-mistakes-required.yml"
    [ -s "$file" ] || fail "tamper $tamper produced no workflow file"
    cmp -s "$file" "$WORKFLOW" \
      && fail "tamper $tamper left the workflow byte-identical, so it tests nothing"
    case $tamper in
      skip-policy-resolution)
        [ -z "$(workflow_step_script_from "$file" 'Resolve the authoritative verifier from the governed policy generation')" ] \
          || fail "tamper $tamper did not remove the policy-resolution step"
        ;;
      substitute-candidate-verifier)
        # shellcheck disable=SC2016  # The unexpanded text is what the tampered file carries.
        grep -q 'POLICY_VERIFIER=${PWD}/bin/fm-attest.sh' "$file" \
          || fail "tamper $tamper did not point the verifier at the candidate copy"
        ;;
      force-verify-success)
        workflow_step_script_from "$file" 'Verify the head-bound no-mistakes attestation' \
          | head -3 | grep -q '^exit 0$' \
          || fail "tamper $tamper did not force the verify step to success"
        ;;
      remove-verify-step)
        [ -z "$(workflow_step_script_from "$file" 'Verify the head-bound no-mistakes attestation')" ] \
          || fail "tamper $tamper did not remove the verify step"
        ;;
      change-policy-ref-selection)
        grep -q 'refs/heads/attacker-policy' "$file" \
          || fail "tamper $tamper did not redirect the policy-ref selection"
        ;;
    esac
  done
  pass "fm-attest.sh: each wrapper tamper is a real change to the preceding law's program"
}

test_wrapper_tampering_cannot_reach_the_governed_acceptance_program() {
  local dir venue tamper out rc marker
  # The GREEN half, and the ruling's watched reds (a) through (e) in one
  # mechanism: on the governed leg both the workflow file and the acceptance
  # program come from the governed generation, so the acceptance run is built
  # here from the VENUE's bytes alone - exactly what the platform does on
  # pull_request_target - while a fully tampered candidate tree sits in reach
  # and is proven untouched. The candidate's gate, verifier and workflow are
  # booby-trapped to leave a marker if anything executes them; the venue's
  # verifier refuses, and the verdict must remain that refusal for every
  # tamper, with no marker.
  dir="$TMP_ROOT/wrapper-tamper-inert"
  rm -rf "$dir"; mkdir -p "$dir/venue"
  # The venue generation: the real workflow and gate, and a verifier that
  # refuses everything - so any flip to success can only come from candidate
  # bytes getting into the program.
  mkdir -p "$dir/venue/bin" "$dir/venue/.github/workflows"
  cp "$WORKFLOW" "$dir/venue/.github/workflows/no-mistakes-required.yml"
  cp "$ROOT/bin/fm-attest-gate.sh" "$dir/venue/bin/fm-attest-gate.sh"
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --supports) exit 0 ;; --print-format) echo fmt ;; *) exit 1 ;; esac\n' \
    > "$dir/venue/bin/fm-attest.sh"
  chmod +x "$dir/venue/bin/fm-attest-gate.sh" "$dir/venue/bin/fm-attest.sh"
  ( cd "$dir/venue" && git init -q . && git add -A \
    && git -c user.email=t@e -c user.name=t commit -qm policy )

  for tamper in $wrapper_tampers; do
    rm -rf "$dir/candidate"; mkdir -p "$dir/candidate/bin"
    install_tampered_workflow "$dir/candidate" "$tamper"
    marker="$dir/candidate/EXECUTED"
    printf '#!/usr/bin/env bash\ntouch %s\nexit 0\n' "$marker" > "$dir/candidate/bin/fm-attest.sh"
    printf '#!/usr/bin/env bash\ntouch %s\nexit 0\n' "$marker" > "$dir/candidate/bin/fm-attest-gate.sh"
    chmod +x "$dir/candidate/bin/fm-attest.sh" "$dir/candidate/bin/fm-attest-gate.sh"

    # The governed leg, as the platform runs it: workdir is the venue
    # generation's checkout, the program is its own gate, and the candidate
    # head crosses in as data. The candidate tree exists on disk and its
    # tampered file subscribes whatever it likes; none of it is consulted.
    out=$( cd "$dir/venue" \
      && HEAD_SHA=0123456789012345678901234567890123456789 \
        HEAD_REPO=owner/fork BASE_REPO=owner/venue PR_NUMBER=1 PR_AUTHOR=someone \
        FM_GATE_POLICY_SHA=venuegeneration bash bin/fm-attest-gate.sh 2>&1 )
    rc=$?
    [ "$rc" -eq 1 ] \
      || fail "tamper $tamper changed the governed verdict (exit $rc): $out"
    printf '%s\n' "$out" | grep -q 'carries no verified no-mistakes attestation' \
      || fail "tamper $tamper turned the governed refusal into something else: $out"
    [ ! -e "$marker" ] \
      || fail "tamper $tamper got candidate bytes executed by the governed acceptance run"
    # And the program judging is provably the venue's: the file the platform
    # would take from the governed branch is untouched by the tamper.
    git -C "$dir/venue" diff --quiet \
      || fail "tamper $tamper modified the governed generation itself"
  done
  pass "fm-attest.sh: all five wrapper tamperings are inert against the governed acceptance program"
}

test_gate_script_owns_the_error_model_and_never_leaves_its_generation() {
  local dir out rc
  # The gate program's own contract: its verifier is its sibling and nothing
  # else, an unusable sibling is a no-verdict rather than a search, and its
  # refusal carries the bound publish command. A candidate verifier planted in
  # the working directory - the place a lazy path would pick it up - is never
  # executed.
  dir="$TMP_ROOT/gate-script-contract"
  rm -rf "$dir"; mkdir -p "$dir/generation" "$dir/cwd/bin"
  cp "$ROOT/bin/fm-attest-gate.sh" "$dir/generation/fm-attest-gate.sh"
  chmod +x "$dir/generation/fm-attest-gate.sh"
  printf '#!/usr/bin/env bash\ntouch %s/CWD-EXECUTED\nexit 0\n' "$dir" > "$dir/cwd/bin/fm-attest.sh"
  chmod +x "$dir/cwd/bin/fm-attest.sh"
  ( cd "$dir/cwd" && git init -q . )

  # No sibling verifier: a no-verdict in the could-not-obtain voice, and the
  # planted candidate copy stays unexecuted.
  out=$( cd "$dir/cwd" && HEAD_SHA=0123456789012345678901234567890123456789 \
    HEAD_REPO=owner/fork BASE_REPO=owner/venue PR_NUMBER=1 PR_AUTHOR=someone \
    bash "$dir/generation/fm-attest-gate.sh" 2>&1 )
  rc=$?
  [ "$rc" -eq 1 ] || fail "a gate with no sibling verifier did not fail (exit $rc)"
  printf '%s\n' "$out" | grep -q 'could not obtain the authoritative' \
    || fail "a missing sibling was not reported as a no-verdict: $out"
  printf '%s\n' "$out" | grep -q 'carries no verified' \
    && fail "a missing sibling borrowed the refusal's words"
  [ ! -e "$dir/CWD-EXECUTED" ] || fail "the gate executed a verifier from the working directory"

  # A sibling without the reconcile contract: the unsupported-version
  # no-verdict, never a fallback.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/generation/fm-attest.sh"
  chmod +x "$dir/generation/fm-attest.sh"
  out=$( cd "$dir/cwd" && HEAD_SHA=0123456789012345678901234567890123456789 \
    HEAD_REPO=owner/fork BASE_REPO=owner/venue PR_NUMBER=1 PR_AUTHOR=someone \
    bash "$dir/generation/fm-attest-gate.sh" 2>&1 )
  rc=$?
  [ "$rc" -eq 1 ] || fail "an unsupported sibling did not fail (exit $rc)"
  printf '%s\n' "$out" | grep -q 'does not support the reconcile' \
    || fail "an unsupported sibling was not reported as version skew: $out"

  # A refusing sibling: the refusal, carrying the bound publish command with
  # the head repository the note belongs on.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the stub.
  printf '#!/usr/bin/env bash\ncase "${1:-}" in --supports) exit 0 ;; --print-format) echo fmt ;; *) exit 1 ;; esac\n' \
    > "$dir/generation/fm-attest.sh"
  out=$( cd "$dir/cwd" && HEAD_SHA=0123456789012345678901234567890123456789 \
    HEAD_REPO=owner/fork BASE_REPO=owner/venue PR_NUMBER=1 PR_AUTHOR=someone \
    bash "$dir/generation/fm-attest-gate.sh" 2>&1 )
  rc=$?
  [ "$rc" -eq 1 ] || fail "a refusing sibling did not fail the gate (exit $rc)"
  printf '%s\n' "$out" | grep -q -- '--publish-repo github.com/owner/fork' \
    || fail "the refusal does not carry the bound publish command: $out"
  [ ! -e "$dir/CWD-EXECUTED" ] || fail "the gate reached outside its generation for a verifier"
  pass "fm-attest.sh: the acceptance gate owns its error model and never leaves its generation"
}

test_cases='
test_workflow_subscribes_the_governed_event_and_checks_out_its_generation
test_governed_workflow_resolves_and_dispatches_its_own_verifier
test_wrapper_tampering_is_real_under_the_preceding_law
test_wrapper_tampering_cannot_reach_the_governed_acceptance_program
test_gate_script_owns_the_error_model_and_never_leaves_its_generation
test_required_refuses_a_generation_the_policy_ref_does_not_reach
test_required_reads_the_named_policy_ref_rather_than_the_venues_head
test_required_refuses_when_no_ref_is_recorded_as_owning_policy
test_required_refuses_a_policy_ref_it_cannot_resolve
test_write_refuses_an_unbound_notes_ref
test_write_refuses_a_remote_that_addresses_another_repository
test_write_refuses_a_notes_ref_the_effect_plan_did_not_name
test_write_binds_the_three_repository_roles_independently_on_a_fork
test_check_step_judges_a_candidate_by_the_governed_verifier_not_its_own
test_check_step_does_not_become_a_pass_when_the_candidate_deletes_the_judge
test_check_step_reaches_no_verdict_rather_than_running_the_candidate
test_absent_notes_ref_refuses_as_absent
test_ref_without_note_for_head_refuses_distinctly
test_unreadable_notes_ref_refuses_distinctly
test_note_naming_another_head_refuses_as_unbound
test_genuine_attestation_does_not_survive_a_rewrite
test_legacy_body_marker_is_not_an_attestation
test_unknown_field_refuses_rather_than_being_ignored
test_missing_required_step_refuses_distinctly
test_unusable_gate_list_refuses_as_malformed
test_absent_head_commit_refuses_as_its_own_state
test_head_bound_attestation_passes
test_write_refuses_a_run_head_absent_from_this_checkout
test_write_attests_the_run_tip_the_pipeline_advanced_past_head
test_write_refuses_an_incomplete_run
test_write_refuses_a_run_from_another_branch
test_write_emits_an_attestation_the_gate_accepts
test_write_refuses_a_later_commit_on_the_same_branch
test_write_refuses_without_a_run_record
test_write_surfaces_a_tool_failure_instead_of_reporting_no_run
test_write_reports_a_refusing_tool_that_exited_zero_as_a_refusing_tool
test_write_reports_an_unreadable_run_record_distinctly
test_write_reports_a_record_with_no_head_as_a_record_fault
test_write_attests_on_a_host_with_no_timeout_utility
test_write_publishes_to_the_push_target_it_reconciled_against
test_write_reports_the_rejection_reason_with_credentials_redacted
test_write_publishes_ungoverned_and_says_so
test_write_refuses_to_publish_when_governance_cannot_be_established
test_write_publishes_attestation_evidence_to_a_governed_venue
test_write_refuses_an_unintended_attestation_evidence_ref
test_write_publishes_a_first_attestation_to_a_push_target_with_no_ref
test_write_refuses_an_unreadable_push_target_without_leaking_credentials
test_write_emits_only_positively_safe_urls
test_write_withholds_a_push_target_it_cannot_positively_parse
test_write_names_an_scp_style_push_target
test_write_withholds_the_whole_line_a_withheld_url_sat_on
test_write_withholds_url_shapes_no_reader_models
test_write_withholds_a_url_carrying_a_query_or_fragment
test_write_makes_the_pipeline_tools_own_streams_safe_to_print
test_write_rejects_a_zero_bound_rather_than_running_the_read_unbounded
test_check_step_separates_a_verdict_from_a_verifier_that_could_not_run
test_check_step_names_validating_an_unvalidated_head_as_the_repair
test_check_step_addresses_both_repositories_without_logging_its_token
test_write_outside_a_repository_fails_as_such
test_write_without_the_pipeline_tool_fails_as_such
test_write_on_an_unborn_head_fails_as_such
test_write_on_a_detached_head_fails_as_such
test_write_without_a_usable_scratch_directory_fails_as_such
test_write_reports_an_unfetchable_push_target_as_such
test_write_reports_an_unreconcilable_local_ref_as_such
test_write_reports_an_unrecordable_note_as_such
test_show_reports_an_unknown_commit_as_such
test_recheck_reruns_the_run_that_judged_a_published_head
test_recheck_requests_one_re_evaluation_per_attempt
test_recheck_pre_request_record_consumes_the_attempt
test_recheck_refuses_while_the_ledger_lock_is_held
test_recheck_reclaims_only_a_demonstrably_stale_ledger_lock
test_recheck_refuses_a_truncated_pull_request_listing
test_recheck_binds_the_published_repository_to_the_pr_head_repository
test_recheck_matches_a_head_repository_spelled_in_another_case
test_recheck_matches_a_resolved_head_repository_spelled_in_another_case
test_recheck_bound_is_not_reset_by_respelling_the_repository
test_recheck_refuses_absent_and_unreadable_head_repositories
test_recheck_bounds_repeated_re_evaluation_of_one_head
test_recheck_selects_the_run_that_started_last
test_recheck_ignores_runs_belonging_to_another_head
test_recheck_refuses_a_head_with_no_applicable_run
test_recheck_refuses_a_truncated_run_listing
test_recheck_reports_an_unreadable_forge_as_no_verdict
test_recheck_does_nothing_when_the_run_already_passed
test_recheck_refuses_a_head_the_request_has_moved_off
test_recheck_refuses_a_head_with_no_published_attestation
test_recheck_reports_invalid_evidence_as_evidence_not_as_a_missed_step
test_recheck_reports_a_run_still_in_flight_rather_than_guessing
test_recheck_without_gh_reports_a_missing_tool_not_a_verdict
test_recheck_reports_no_open_pull_request_as_such
test_recheck_ignores_a_request_this_commit_is_only_associated_with
test_recheck_refuses_to_choose_between_two_open_pull_requests
test_recheck_dry_run_asks_the_forge_to_do_nothing
test_recheck_refuses_half_a_pull_request_identity
test_recheck_records_every_decision_it_made
test_recheck_reports_a_refused_rerun_without_claiming_one
test_write_re_evaluates_the_head_it_published
test_write_no_recheck_publishes_without_asking_the_forge
test_required_answers_a_repository_whose_checks_read_an_attestation
test_required_ignores_a_launcher_prefixed_invocation_without_the_marker
test_required_answers_the_repository_workflow_fixture
test_required_answers_a_repository_whose_checks_read_none
test_required_ignores_a_commented_invocation
test_required_ignores_an_invocation_inside_prose
test_required_ignores_a_bare_invocation_without_the_marker
test_required_reports_a_symlink_declaration_as_neither
test_required_reports_wrong_declaration_content_as_neither
test_required_reads_a_marker_from_the_repository_default_branch
test_required_reports_a_superseded_policy_generation_as_neither
test_required_still_answers_not_required_when_the_venue_never_declared
test_required_reports_a_current_generation_symlink_as_unobservable
test_required_reports_current_generation_wrong_content_as_unobservable
test_required_reports_an_unresolvable_default_ref_as_neither
test_required_refuses_a_foreign_local_policy_ref
test_required_cleans_the_policy_ref_when_fetch_is_interrupted
test_required_reports_a_default_branch_symlink_as_neither
test_declaration_check_refuses_a_consumer_without_the_marker
test_declaration_check_accepts_the_repository_invariant
test_write_only_if_required_publishes_nothing_where_no_check_reads_it
test_write_only_if_required_stops_rather_than_guess_at_an_unreadable_declaration
test_write_expect_head_binds_publication_to_the_request_head
test_check_step_no_longer_sends_a_contributor_to_edit_the_request
test_reconcile_converges_on_an_attestation_published_during_the_window
test_reconcile_refuses_a_head_no_attestation_arrives_for
test_reconcile_does_not_grace_evidence_already_seen_to_be_invalid
test_reconcile_ignores_local_evidence_when_the_authoritative_ref_is_absent
test_reconcile_consults_the_clock_only_after_absence_applies
test_reconcile_validates_the_initial_observation_before_sleeping
test_reconcile_refuses_wrong_head_evidence_arriving_during_the_wait
test_reconcile_accepts_exact_head_evidence_when_the_pull_request_moves
test_reconcile_waits_only_for_absence
test_reconcile_stops_when_the_pull_request_head_moves
test_reconcile_reports_an_unreadable_repository_as_no_verdict
test_reconcile_repeats_without_compounding
test_supports_answers_for_capabilities_this_program_has
'

missing_invoked=
for test_case in $test_cases; do
  declare -F "$test_case" >/dev/null || missing_invoked="$missing_invoked $test_case"
done
[ -z "$missing_invoked" ] || fail "invoked test cases are not defined:$missing_invoked"

missing_registered=
while read -r declaration; do
  defined_test=${declaration##* }
  case "$defined_test" in
    test_*)
      case "
$test_cases
" in
        *"
$defined_test
"*) ;;
        *) missing_registered="$missing_registered $defined_test" ;;
      esac
      ;;
  esac
done <<EOF
$(declare -F)
EOF
[ -z "$missing_registered" ] || fail "defined test cases are not invoked:$missing_registered"

for test_case in $test_cases; do
  "$test_case"
done
