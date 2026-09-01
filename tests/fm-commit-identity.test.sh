#!/usr/bin/env bash
# Behavior tests for the production commit identity binding.
#
# The defect these controls are built from was published, not hypothesized: real
# production commits on real pull requests carried `Test <test@example.com>` as
# BOTH author and committer, because the repository the validation pipeline
# commits in carries no repository-local identity and nothing in the pipeline's
# environment names one, so every one of its commit-producing stages fell through
# to the machine's GLOBAL git identity.
#
# So the fixture reproduces that exact topology rather than a convenient one: a
# poisoned global identity, a bare gate repository with no local identity, and a
# checkout that DOES have one - which is what made the defect alternate inside a
# single branch and stay hidden for four generations of evidence.
#
# Every case here observes a real commit object's author and committer, or the
# absence of one. That is the only subject that matters: a verdict about
# configuration would be a verdict about the wrong thing, since configuration is
# exactly what the environment can outrank.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Derive the expected test set from the declarations rather than maintaining a
# second list, so an added control that is never invoked fails loudly.
FM_TEST_IDENTITY_CONTRACT=1

CMD="$ROOT/bin/fm-commit-identity.sh"
TMP_ROOT=$(fm_test_tmproot fm-commit-identity)

AUTHORITATIVE='Shane Bracewell <sbracewell64@gmail.com>'
POISON_IDENTITY='Test <test@example.com>'

# --- fixture ----------------------------------------------------------------
#
# Every git command is pinned to a path derived inside the caller, never to a
# variable that could arrive empty: an empty repo path would aim these fixtures
# at the checkout the tests live in.

# Echoes "<case-root>". The layout mirrors the real one: the gate repository sits
# at <nm-root>/repos/<name>.git so the daemon record is found where the real
# tool keeps it, which is what the command derives from the gate path.
make_case() {  # <name> [<policy-json>]
  local name=${1:?case name required} policy=${2:-default} root
  root="$TMP_ROOT/$name"
  mkdir -p "$root/home" "$root/config" "$root/bin" "$root/nm/repos" || return 1

  # The poisoned GLOBAL identity: git's own worked example, exactly as measured.
  printf '[user]\n\temail = test@example.com\n\tname = Test\n' > "$root/home/.gitconfig" || return 1

  git init -q "$root/checkout" || return 1
  git -C "$root/checkout" remote add origin https://github.com/sbracewell64/firstmate.git || return 1
  git -C "$root/checkout" -c user.name=Seed -c user.email=seed@example.invalid \
    commit -q --allow-empty -m seed || return 1

  git init -q --bare "$root/nm/repos/gate.git" || return 1
  git -C "$root/checkout" push -q "$root/nm/repos/gate.git" HEAD:refs/heads/main || return 1
  git --git-dir="$root/nm/repos/gate.git" worktree add -q "$root/gatewt" main || return 1

  case "$policy" in
    default) write_policy "$root" "$AUTHORITATIVE" "$AUTHORITATIVE" ;;
    none) : ;;
    *) printf '%s' "$policy" > "$root/config/publication-identity.json" || return 1 ;;
  esac

  printf '  repo:  %s\n  gate:  %s\n  daemon:  running\n' \
    "$root/checkout" "$root/nm/repos/gate.git" > "$root/nm-status" || return 1
  cat > "$root/bin/no-mistakes" <<'FAKE' || return 1
#!/usr/bin/env bash
[ "${1:-}" = status ] || { printf 'unsupported\n'; exit 2; }
cat "$FM_TEST_NM_STATUS"
FAKE
  chmod +x "$root/bin/no-mistakes" || return 1
  printf '%s\n' "$root"
}

write_policy() {  # <root> <author> <committer> [<venue>]
  local root=${1:?} author=${2:-} committer=${3:-} venue=${4:-github.com/sbracewell64/firstmate}
  jq -n --arg a "$author" --arg c "$committer" --arg v "$venue" '{
    generation: "pol-test-g1",
    venues: { ($v): { identities: (
      (if $a == "" then {} else { author: $a } end) +
      (if $c == "" then {} else { committer: $c } end) +
      { delivery_actor: "sbracewell64", maker: "m/one", reviewer: "r/two", ruling: "browser-sol" }
    ) } }
  }' > "$root/config/publication-identity.json"
}

# A live process standing in for the pipeline daemon, so the environment check
# reads a real one. Extra arguments are VAR=VALUE assignments placed into it.
start_daemon() {  # <root> [VAR=VALUE...]
  local root=${1:?} pid started
  shift
  env "$@" sleep 300 &
  pid=$!
  fm_test_reap "$pid"
  # `ps -o lstart=` is LOCAL time with no zone, so it is parsed as local and only
  # then formatted as UTC through an unambiguous epoch. Converting it with a
  # single `date -u -d` would misread it as UTC - which is the exact defect the
  # production reader had, and because this fixture once shared it, the two
  # agreed with each other while neither matched a real daemon.
  started=$(LC_ALL=C ps -p "$pid" -o lstart=) || return 1
  started=$(date -d "$started" +%s) || return 1
  started=$(date -u -d "@$started" +%Y-%m-%dT%H:%M:%SZ) || return 1
  printf '{"pid":%s,"started_at":"%s"}' "$pid" "$started" > "$root/nm/daemon.pid" || return 1
  printf '%s\n' "$pid"
}

run_cmd() {  # <root> <verb> [env-assignments...] -- runs against the fixture
  local root=${1:?} verb=${2:?}
  shift 2
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    HOME="$root/home" PATH="$root/bin:$PATH" \
    FM_TEST_NM_STATUS="$root/nm-status" \
    FM_HOME="$root" FM_CONFIG_OVERRIDE="$root/config" \
    "$@" "$CMD" "$verb" "$root/checkout" 2>&1
}

# The subject of every assertion: the identity a REAL commit object carries when
# made the way the pipeline makes one, with nothing on the command line saying
# who it is.
commit_identity() {  # <repo> <message>
  local repo=${1:?} msg=${2:?} root
  root=$(cd "$repo" && git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$root" ] || return 1
  git -C "$root" commit -q --allow-empty -m "$msg" >/dev/null 2>&1 || return 1
  git -C "$root" log -1 --format='%an <%ae>|%cn <%ce>'
}

gate_commit_identity() {  # <root> [env-assignments...]
  local root=${1:?}
  shift
  # shellcheck disable=SC2016  # positional args inside bash -c, not expansions
  env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
    HOME="$root/home" \
    "$@" bash -c 'cd "$1" && git commit -q --allow-empty -m "pipeline stage fix" && git log -1 --format="%an <%ae>|%cn <%ce>"' _ "$root/gatewt"
}

# --- the real launch path ----------------------------------------------------
#
# These two controls answer the question the primitive's own tests cannot: not
# "does the binder work when invoked?" but "can a production commit path reach
# its first commit-producing action WITHOUT it having been invoked?" That is a
# property of the launch owner, so they drive bin/fm-spawn.sh for real - a real
# isolated worktree, a fake terminal backend, and NO manual binder call anywhere.
#
# The brief instruction is deliberately absent from both. It is projection, and a
# control that relied on it would be measuring the prose rather than the gate.

SPAWN="$ROOT/bin/fm-spawn.sh"
LAUNCH_VENUE='example.invalid/sbracewell64/firstmate'
LAUNCH_CASE_REC=

# Every launch-path invocation is BOUNDED. The subject of these controls is what
# the launch owner binds, not whether a stand-in terminal completes its
# handshake, so a slow or unfinished launch must surface as a bounded failure
# rather than a hung suite.
FM_CI_LAUNCH_TIMEOUT=${FM_CI_LAUNCH_TIMEOUT:-90}

# Sets LAUNCH_CASE_REC to "<home>|<project>|<worktree>|<fakebin>". The project
# carries the poisoned global identity through HOME, exactly as the real defect
# did. Call this directly: its daemon must register with the suite's reaper in
# this shell, not in a command-substitution subshell that loses the registration.
make_launch_case() {  # <name> [<policy>]
  local name=${1:?} policy=${2:-default} case_dir home proj wt fakebin gate
  LAUNCH_CASE_REC=
  case_dir="$TMP_ROOT/launch-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  gate="$case_dir/nm/repos/gate.git"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$case_dir/nm/repos" "$case_dir/home_env" || return 1
  printf '[user]\n\temail = test@example.com\n\tname = Test\n' > "$case_dir/home_env/.gitconfig" || return 1
  fakebin=$(fm_fakebin "$case_dir") || return 1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  new-window) touch "$FM_TEST_ENDPOINT_MARKER"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" || return 1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEST_SLOT_MARKER"
exit 0
SH
  chmod +x "$fakebin/treehouse" || return 1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = status ] || exit 0
cat "$FM_TEST_NM_STATUS"
SH
  chmod +x "$fakebin/no-mistakes" || return 1
  printf 'claude\n' > "$home/config/crew-harness" || return 1
  printf '%s\n' "$$" > "$home/state/.lock" || return 1
  touch "$home/state/.last-watcher-beat" || return 1

  fm_git_worktree "$proj" "$wt" "wt-$name" || return 1
  # A reserved-invalid host: the venue is what the policy is keyed on, and using
  # a real forge URL would let a launch-path step try to reach it.
  git -C "$proj" remote add origin "git@example.invalid:sbracewell64/firstmate.git" || return 1
  git init -q --bare "$gate" || return 1
  git -C "$proj" push -q "$gate" HEAD:refs/heads/main || return 1

  case "$policy" in
    default) write_policy "$home" "$AUTHORITATIVE" "$AUTHORITATIVE" "$LAUNCH_VENUE" || return 1 ;;
    none) : ;;
    *) printf '%s' "$policy" > "$home/config/publication-identity.json" || return 1 ;;
  esac
  printf '  repo:  %s\n  gate:  %s\n' "$proj" "$gate" > "$case_dir/nm-status" || return 1
  start_daemon "$case_dir" >/dev/null || return 1
  LAUNCH_CASE_REC="$home|$proj|$wt|$fakebin"
}

run_launch() {  # <case-dir> <home> <wt> <fakebin> <spawn-args...>
  local case_dir=${1:?} home=${2:?} wt=${3:?} fakebin=${4:?}
  shift 4
  env HOME="$case_dir/home_env" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_NM_STATUS="$case_dir/nm-status" \
    FM_TEST_ENDPOINT_MARKER="$case_dir/endpoint-allocated" \
    FM_TEST_SLOT_MARKER="$case_dir/slot-allocated" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    timeout "$FM_CI_LAUNCH_TIMEOUT" "$SPAWN" "$@" 2>&1
}

make_launch_brief() {  # <home> <id> <mode>
  local home=${1:?} id=${2:?} mode=${3:?}
  mkdir -p "$home/data/$id" || return 1
  printf 'Delivery contract: mode=%s\n' "$mode" > "$home/data/$id/brief.md"
}

# --- the watched red: what the fleet published ------------------------------
#
# This is the control that keeps every case below from going quietly vacuous. It
# removes nothing and stubs nothing: it simply makes a commit the way the
# pipeline made the contaminated ones, and asserts the published defect appears.
# If this case ever stops reproducing `Test <test@example.com>`, the positive
# cases are proving nothing and must not be believed.
test_an_unbound_gate_reproduces_the_published_defect() {
  local root out rc identity
  root=$(make_case unbound-red) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"

  identity=$(gate_commit_identity "$root") || fail "gate commit failed"
  [ "$identity" = "$POISON_IDENTITY|$POISON_IDENTITY" ] \
    || fail "the unbound gate must reproduce the published defect, got: $identity"

  out=$(run_cmd "$root" check); rc=$?
  expect_code 1 "$rc" "an unbound production commit path must refuse"
  assert_contains "$out" "NOT BOUND" "the refusal must name the unbound channel"
  assert_contains "$out" "$POISON_IDENTITY" "the refusal must name the identity that would have been used"
  pass "an unbound gate repository still commits as the poisoned global identity, and the check refuses"
}

# --- positive non-vacuity ---------------------------------------------------
test_binding_makes_an_ordinary_pipeline_commit_authoritative() {
  local root out rc identity
  root=$(make_case positive) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"

  out=$(run_cmd "$root" bind); rc=$?
  expect_code 0 "$rc" "binding an observable production path must succeed: $out"
  assert_contains "$out" "FM_CI_BOUND_EXACT" "a successful bind must state the allowing verdict"

  identity=$(gate_commit_identity "$root") || fail "gate commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] \
    || fail "a bound pipeline commit must carry the authoritative author AND committer, got: $identity"

  identity=$(commit_identity "$root/checkout" "worker implementation commit") || fail "checkout commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] \
    || fail "a bound worker commit must carry the authoritative author AND committer, got: $identity"
  pass "after binding, an ordinary commit on each production path carries the authoritative author and committer"
}

# --- ambient poisoning, one channel at a time -------------------------------
#
# The environment is git's STRONGEST selector, so it cannot be beaten by the
# config binding and is not pretended to be: the command refuses instead, before
# a commit object exists, naming the variable that would have won.
test_poisoned_identity_environment_refuses_before_any_commit() {
  local root out rc before after
  root=$(make_case env-poison) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"
  before=$(git -C "$root/gatewt" rev-list --count HEAD) || fail "count failed"

  out=$(env HOME="$root/home" PATH="$root/bin:$PATH" \
    FM_TEST_NM_STATUS="$root/nm-status" FM_HOME="$root" FM_CONFIG_OVERRIDE="$root/config" \
    GIT_AUTHOR_NAME=Poison GIT_AUTHOR_EMAIL=poison@example.invalid \
    GIT_COMMITTER_NAME=Poison GIT_COMMITTER_EMAIL=poison@example.invalid \
    "$CMD" bind "$root/checkout" 2>&1); rc=$?
  expect_code 1 "$rc" "a poisoned identity environment must refuse: $out"
  assert_contains "$out" "FM_CI_AMBIENT_OVERRIDE" "the refusal must carry its typed token"
  assert_contains "$out" "GIT_AUTHOR_NAME=Poison" "the refusal must name the variable that would have won"

  after=$(git -C "$root/gatewt" rev-list --count HEAD) || fail "count failed"
  [ "$before" = "$after" ] || fail "a refusal must create zero commit objects"
  pass "a poisoned GIT_AUTHOR/GIT_COMMITTER environment refuses by name and creates no commit"
}

test_matching_identity_environment_still_refuses_by_presence() {
  local root out rc
  root=$(make_case env-matching) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"

  out=$(run_cmd "$root" bind GIT_AUTHOR_NAME='Shane Bracewell'); rc=$?
  expect_code 1 "$rc" "a present matching identity variable must refuse: $out"
  assert_contains "$out" "GIT_AUTHOR_NAME=Shane Bracewell" "the refusal must name the present matching variable"

  out=$(run_cmd "$root" bind GIT_AUTHOR_EMAIL=); rc=$?
  expect_code 1 "$rc" "a present empty identity variable must refuse: $out"
  assert_contains "$out" "GIT_AUTHOR_EMAIL=" "the refusal must name the present empty variable"
  pass "any present invoking identity variable refuses by name regardless of value"
}

test_poisoned_repository_and_global_config_lose_to_the_binding() {
  local root out rc identity
  root=$(make_case config-poison) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"

  # Both config channels poisoned independently: the gate repository's own local
  # identity, and the global one it would otherwise fall through to.
  git --git-dir="$root/nm/repos/gate.git" config --local user.name 'Local Poison' || fail "poison failed"
  git --git-dir="$root/nm/repos/gate.git" config --local user.email 'local@example.invalid' || fail "poison failed"
  printf '[user]\n\temail = global@example.invalid\n\tname = Global Poison\n' > "$root/home/.gitconfig" || fail "poison failed"

  out=$(run_cmd "$root" bind); rc=$?
  expect_code 0 "$rc" "the binding must overwrite a poisoned local identity: $out"

  identity=$(gate_commit_identity "$root") || fail "gate commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] \
    || fail "neither poisoned config channel may redefine production provenance, got: $identity"
  pass "a poisoned repository-local identity and a poisoned global identity both lose to the binding"
}

test_fixture_identity_in_the_same_session_does_not_cross_the_boundary() {
  local root fixture identity out rc
  root=$(make_case fixture-bleed) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"

  # Legitimate fixture activity first, in its own disposable repository, using
  # the Test identity exactly as a test is entitled to.
  fixture="$root/disposable"
  git init -q "$fixture" || fail "fixture repo failed"
  identity=$(HOME="$root/home" commit_identity "$fixture" "fixture commit") || fail "fixture commit failed"
  [ "$identity" = "$POISON_IDENTITY|$POISON_IDENTITY" ] \
    || fail "the fixture control must genuinely establish a Test identity, got: $identity"

  out=$(run_cmd "$root" bind); rc=$?
  expect_code 0 "$rc" "binding after fixture activity must succeed: $out"
  identity=$(gate_commit_identity "$root") || fail "gate commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] \
    || fail "fixture identity must not cross into a production commit, got: $identity"
  pass "fixture identity established in the same session does not reach a production commit"
}

test_the_binding_survives_a_restart_between_commits() {
  local root identity out rc
  root=$(make_case restart) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 0 "$rc" "initial bind must succeed: $out"
  identity=$(gate_commit_identity "$root") || fail "first gate commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] || fail "first commit not bound: $identity"

  # A wholly new process, carrying none of the first one's state, standing in for
  # the resumed run that made the post-g2 CI-fix commits.
  # shellcheck disable=SC2016  # positional args inside bash -c, not expansions
  identity=$(env -i HOME="$root/home" PATH="$PATH" bash -c \
    'cd "$1" && git commit -q --allow-empty -m "resumed CI fix" && git log -1 --format="%an <%ae>|%cn <%ce>"' _ "$root/gatewt") \
    || fail "resumed commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] \
    || fail "restart-time state must not reselect provenance, got: $identity"
  pass "a restart between commits leaves the bound provenance as the sole selector"
}

# --- unobservable or unusable authoritative identity ------------------------
#
# Each of these is a REFUSAL before object creation, never a fall-through, and
# each carries its own token because the repairs differ: a home that declared no
# policy, a policy that governs other venues, an axis left unstated, an identity
# that is a placeholder, and one that does not parse are five different facts.
test_an_unusable_authoritative_identity_refuses_and_commits_nothing() {
  local root out rc before after case_name policy token
  while IFS='|' read -r case_name policy token; do
    [ -n "$case_name" ] || continue
    root=$(make_case "$case_name" "$policy") || fail "fixture setup failed for $case_name"
    start_daemon "$root" >/dev/null || fail "daemon fixture failed"
    before=$(git -C "$root/gatewt" rev-list --count HEAD) || fail "count failed"
    out=$(run_cmd "$root" bind); rc=$?
    [ "$rc" -ne 0 ] || fail "$case_name must not report a usable identity: $out"
    assert_contains "$out" "$token" "$case_name must carry its own typed token"
    after=$(git -C "$root/gatewt" rev-list --count HEAD) || fail "count failed"
    [ "$before" = "$after" ] || fail "$case_name must create zero commit objects"
  done <<EOF
policy-absent|none|FM_CI_POLICY_ABSENT
venue-ungoverned|{"generation":"g","venues":{"github.com/other/repo":{"identities":{}}}}|FM_CI_VENUE_UNGOVERNED
axis-unstated|{"generation":"g","venues":{"github.com/sbracewell64/firstmate":{"identities":{"author":"A Person <a@example.invalid>"}}}}|FM_CI_IDENTITY_UNSTATED
identity-placeholder|{"generation":"g","venues":{"github.com/sbracewell64/firstmate":{"identities":{"author":"Test <test@example.com>","committer":"Test <test@example.com>"}}}}|FM_CI_IDENTITY_PLACEHOLDER
identity-malformed|{"generation":"g","venues":{"github.com/sbracewell64/firstmate":{"identities":{"author":"no angle brackets","committer":"no angle brackets"}}}}|FM_CI_IDENTITY_MALFORMED
identity-trailing-content|{"generation":"g","venues":{"github.com/sbracewell64/firstmate":{"identities":{"author":"A Person <a@example.invalid> garbage","committer":"A Person <a@example.invalid> garbage"}}}}|FM_CI_IDENTITY_MALFORMED
identity-extra-delimiter|{"generation":"g","venues":{"github.com/sbracewell64/firstmate":{"identities":{"author":"A Person <a@example.invalid>junk>","committer":"A Person <a@example.invalid>junk>"}}}}|FM_CI_IDENTITY_MALFORMED
EOF
  pass "an unstated, placeholder, malformed, ungoverned or undeclared identity refuses before any commit object exists"
}

test_an_unreadable_policy_is_could_not_observe_not_a_refusal() {
  local root out rc
  root=$(make_case policy-unreadable) || fail "fixture setup failed"
  printf 'not json at all' > "$root/config/publication-identity.json" || fail "poison failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 2 "$rc" "an unreadable policy is could-not-observe, a third value: $out"
  assert_contains "$out" "FM_CI_POLICY_UNREADABLE" "the could-not-observe must carry its own token"
  pass "an unreadable identity policy is could-not-observe, distinct from a policy that refuses"
}

# --- the pipeline channel's three states ------------------------------------
#
# Not applicable, could-not-observe, and bound are three answers, and folding the
# first two together would make every delivery mode that never runs the pipeline
# refuse, or make a pipeline whose state could not be read look clean.
test_an_uninitialized_pipeline_is_not_applicable_rather_than_unobserved() {
  local root out rc
  root=$(make_case gate-uninitialized) || fail "fixture setup failed"
  printf "repo not initialized (run 'no-mistakes init' first)\n" > "$root/nm-status" || fail "status fixture failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 0 "$rc" "a checkout the pipeline was never set up in must still bind: $out"
  assert_contains "$out" "not applicable" "an uninitialized pipeline must be reported as not applicable"
  assert_not_contains "$out" "UNOBSERVED" "an uninitialized pipeline is not an unobservable one"
  pass "a checkout with no pipeline reports its gate channel as not applicable, not unobservable"
}

test_an_unreadable_gate_report_is_could_not_observe() {
  local root out rc
  root=$(make_case gate-unreadable) || fail "fixture setup failed"
  printf 'some future output shape with no gate line\n' > "$root/nm-status" || fail "status fixture failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 2 "$rc" "an unreadable gate report is could-not-observe: $out"
  assert_contains "$out" "UNOBSERVED" "the gate channel must be reported unobservable"
  pass "a pipeline that does not report its gate repository is could-not-observe, which is not a pass"
}

# --- the one channel this fleet can read but never set ----------------------
test_a_pipeline_daemon_carrying_an_identity_variable_refuses() {
  local root out rc
  root=$(make_case daemon-override) || fail "fixture setup failed"
  start_daemon "$root" GIT_AUTHOR_NAME=DaemonPoison >/dev/null || fail "daemon fixture failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 1 "$rc" "a daemon whose environment outranks the binding must refuse: $out"
  assert_contains "$out" "GIT_AUTHOR_NAME=DaemonPoison" "the refusal must name the variable it read"
  pass "a pipeline daemon carrying an identity variable refuses, because it would outrank the gate binding"
}

test_a_pipeline_daemon_carrying_empty_or_matching_variables_refuses() {
  local root out rc
  root=$(make_case daemon-empty-override) || fail "fixture setup failed"
  start_daemon "$root" GIT_AUTHOR_EMAIL= >/dev/null || fail "daemon fixture failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 1 "$rc" "an empty daemon identity assignment must refuse: $out"
  assert_contains "$out" "GIT_AUTHOR_EMAIL=" "the refusal must name the empty daemon variable"

  root=$(make_case daemon-matching-override) || fail "fixture setup failed"
  start_daemon "$root" GIT_COMMITTER_NAME='Shane Bracewell' >/dev/null || fail "daemon fixture failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 1 "$rc" "a matching daemon identity assignment must refuse: $out"
  assert_contains "$out" "GIT_COMMITTER_NAME=Shane" "the refusal must name the matching daemon variable"
  pass "empty and policy-matching daemon identity assignments both refuse by presence"
}

test_an_unidentifiable_daemon_is_could_not_observe() {
  local root out rc
  root=$(make_case daemon-absent) || fail "fixture setup failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 2 "$rc" "an unidentifiable daemon is could-not-observe: $out"
  assert_contains "$out" "UNOBSERVED" "the daemon channel must be reported unobservable"
  pass "a pipeline daemon that cannot be identified leaves its channel could-not-observe rather than clean"
}

test_a_reused_daemon_pid_is_could_not_observe() {
  local root out rc pid
  root=$(make_case daemon-reused-pid) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"
  pid=$(jq -r .pid "$root/nm/daemon.pid") || fail "pid read failed"
  printf '{"pid":%s,"started_at":"2001-01-01T00:00:00Z"}' "$pid" > "$root/nm/daemon.pid" || fail "pid record failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 2 "$rc" "a live pid from a different start must be unobservable: $out"
  assert_contains "$out" "no running pipeline daemon was identifiable" "the stale record must not certify the live process"
  pass "daemon PID reuse cannot attribute an unrelated process to the pipeline"
}

test_ps_metadata_without_environment_is_could_not_observe() {
  local root fake_proc out rc pid
  root=$(make_case daemon-ps-metadata) || fail "fixture setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"
  pid=$(jq -r .pid "$root/nm/daemon.pid") || fail "pid read failed"
  fake_proc="$root/no-proc"
  mkdir -p "$fake_proc" || fail "proc fixture failed"
  cat > "$root/bin/ps" <<'FAKE'
#!/usr/bin/env bash
case " $* " in
  *' -o lstart= '*) command /bin/ps "$@" ;;
  *) printf 'PID TTY STAT TIME COMMAND\n%s ? S 0:00 no-mistakes daemon\n' "${2:-0}" ;;
esac
FAKE
  chmod +x "$root/bin/ps" || fail "ps fixture failed"
  out=$(PATH="$root/bin:$PATH" bash -c '. "$1"; fm_commit_identity_daemon_env "$2" "$3"' \
    _ "$ROOT/bin/fm-commit-identity-lib.sh" "$pid" "$fake_proc" 2>&1); rc=$?
  expect_code 2 "$rc" "ps metadata without environment fields must be unobservable: $out"
  pass "ps process metadata alone cannot certify the daemon environment clean"
}

test_production_cannot_redirect_daemon_environment_observation() {
  local root fake_proc out rc pid
  root=$(make_case daemon-proc-redirect) || fail "fixture setup failed"
  start_daemon "$root" GIT_AUTHOR_NAME=DaemonPoison >/dev/null || fail "daemon fixture failed"
  pid=$(jq -r .pid "$root/nm/daemon.pid") || fail "pid read failed"
  fake_proc="$root/fabricated-proc"
  mkdir -p "$fake_proc/$pid" || fail "proc fixture failed"
  printf 'PATH=/fabricated\0' > "$fake_proc/$pid/environ" || fail "proc fixture failed"
  out=$(run_cmd "$root" bind FM_PROC_ROOT_OVERRIDE="$fake_proc"); rc=$?
  expect_code 1 "$rc" "production bind must ignore a proc-root redirection: $out"
  assert_contains "$out" "GIT_AUTHOR_NAME=DaemonPoison" "bind must inspect the real daemon environment"
  pass "the production command cannot redirect daemon observation to fabricated proc data"
}

# --- the strongest channel, for processes this fleet runs -------------------
test_the_env_verb_emits_the_channel_that_outranks_everything() {
  local root out identity
  root=$(make_case env-verb) || fail "fixture setup failed"
  out=$(run_cmd "$root" env) || fail "env verb failed"
  assert_contains "$out" "export GIT_AUTHOR_NAME='Shane Bracewell'" "the env block must carry the author name"
  assert_contains "$out" "export GIT_COMMITTER_EMAIL='sbracewell64@gmail.com'" "the env block must carry the committer email"

  # Evaluated over a poisoned environment, in a repository with no binding at
  # all, it still wins - which is what makes it the right channel for a process
  # this fleet owns.
  # shellcheck disable=SC2016  # positional args inside bash -c, not expansions
  identity=$(env HOME="$root/home" \
    GIT_AUTHOR_NAME=Poison GIT_AUTHOR_EMAIL=poison@example.invalid \
    GIT_COMMITTER_NAME=Poison GIT_COMMITTER_EMAIL=poison@example.invalid \
    bash -c 'eval "$1"; cd "$2" && git commit -q --allow-empty -m x && git log -1 --format="%an <%ae>|%cn <%ce>"' \
    _ "$out" "$root/gatewt") || fail "commit under the env block failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] \
    || fail "the emitted environment must outrank a poisoned one, got: $identity"
  pass "the emitted environment block outranks a poisoned environment for a process this fleet runs"
}

test_the_env_channel_preserves_distinct_author_and_committer() {
  local root out identity author committer
  author='A Person <a@example.invalid>'
  committer='C Person <c@example.invalid>'
  root=$(make_case env-distinct) || fail "fixture setup failed"
  write_policy "$root" "$author" "$committer" || fail "policy setup failed"
  out=$(run_cmd "$root" env) || fail "distinct identities must resolve for the environment channel: $out"
  # shellcheck disable=SC2016 # positional args inside bash -c, not expansions
  identity=$(env HOME="$root/home" bash -c \
    'eval "$1"; cd "$2" && git commit -q --allow-empty -m distinct && git log -1 --format="%an <%ae>|%cn <%ce>"' \
    _ "$out" "$root/gatewt") || fail "commit under the distinct environment failed"
  [ "$identity" = "$author|$committer" ] \
    || fail "the environment must preserve each authoritative role, got: $identity"
  pass "the environment channel preserves distinct authoritative author and committer identities"
}

test_the_repository_channel_clearly_refuses_distinct_roles() {
  local root out rc before after author committer
  author='A Person <a@example.invalid>'
  committer='C Person <c@example.invalid>'
  root=$(make_case repo-distinct) || fail "fixture setup failed"
  write_policy "$root" "$author" "$committer" || fail "policy setup failed"
  start_daemon "$root" >/dev/null || fail "daemon fixture failed"
  before=$(git -C "$root/gatewt" rev-list --count HEAD) || fail "count failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 1 "$rc" "the one-pair repository channel must refuse distinct roles: $out"
  assert_contains "$out" "FM_CI_REPO_IDENTITY_DISTINCT" "the refusal must carry its own typed token"
  assert_contains "$out" "$author" "the refusal must name the authoritative author"
  assert_contains "$out" "$committer" "the refusal must name the authoritative committer"
  assert_contains "$out" "one pair" "the refusal must state the repository channel limitation"
  assert_not_contains "$out" "UNVERIFIED" "a channel limitation must not be reported as failed re-observation"
  after=$(git -C "$root/gatewt" rev-list --count HEAD) || fail "count failed"
  [ "$before" = "$after" ] || fail "the repository-channel refusal must create zero commit objects"
  pass "the repository channel clearly refuses distinct roles before writing or committing"
}

# --- the launch owner is the admission, not the brief ------------------------
#
# THE CONTROL THE PREVIOUS CANDIDATE FAILED. Its binder worked, but the only
# thing that made a worker run it was a sentence in a generated brief. This
# drives the REAL launch path with no brief instruction anywhere and a policy
# whose identity cannot be bound, and requires that no production commit path is
# ever handed over: no task metadata, no endpoint, nothing for a worker to
# commit in. Before the launch gate existed this spawn succeeded, which is
# exactly the gap being closed.
test_a_launch_whose_identity_cannot_bind_is_mechanically_refused() {
  local rec home proj wt fakebin case_dir out rc id
  id=unbindable
  make_launch_case "$id" '{"generation":"g","venues":{"example.invalid/sbracewell64/firstmate":{"identities":{"author":"Test <test@example.com>","committer":"Test <test@example.com>"}}}}' \
    || fail "launch fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-$id"
  make_launch_brief "$home" "$id" no-mistakes || fail "brief fixture failed"

  out=$(run_launch "$case_dir" "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION); rc=$?
  [ "$rc" -ne 0 ] || fail "a launch whose production identity cannot be bound must refuse: $out"
  assert_contains "$out" "is not launching" "the refusal must say the task is not being launched"
  assert_contains "$out" "FM_CI_IDENTITY_PLACEHOLDER" "the refusal must carry the binder's own reason"
  assert_absent "$home/state/$id.meta" "a refused launch must publish no task record"
  assert_absent "$case_dir/endpoint-allocated" "a refused launch must allocate no endpoint"
  assert_absent "$case_dir/slot-allocated" "a refused launch must allocate no slot"
  pass "a launch whose authoritative identity cannot be bound is refused by the launch owner, with no brief instruction involved"
}

test_distinct_roles_refuse_before_any_launch_allocation() {
  local rec home proj wt fakebin case_dir out rc id author committer policy
  id=distinct-preallocation
  author='Author Person <author@example.invalid>'
  committer='Committer Person <committer@example.invalid>'
  policy=$(jq -n --arg a "$author" --arg c "$committer" '{generation:"g",venues:{
    "example.invalid/sbracewell64/firstmate":{identities:{author:$a,committer:$c}}
  }}') || fail "policy setup failed"
  make_launch_case "$id" "$policy" || fail "launch fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-$id"
  printf "repo not initialized (run 'no-mistakes init' first)\n" > "$case_dir/nm-status" || fail "pipeline status setup failed"
  make_launch_brief "$home" "$id" local-only || fail "brief fixture failed"

  out=$(run_launch "$case_dir" "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode local-only --yolo off --reason-code NL_RULE_CLASSIFICATION); rc=$?
  [ "$rc" -ne 0 ] || fail "distinct roles must refuse before allocation: $out"
  assert_contains "$out" "FM_CI_REPO_IDENTITY_DISTINCT" "the refusal must carry the distinct-role token"
  assert_contains "$out" "$author" "the refusal must name the author"
  assert_contains "$out" "$committer" "the refusal must name the committer"
  assert_absent "$home/state/$id.meta" "the refusal must publish no task record"
  assert_absent "$case_dir/endpoint-allocated" "the refusal must allocate no endpoint"
  assert_absent "$case_dir/slot-allocated" "the refusal must allocate no slot"
  pass "distinct roles refuse before any launch allocation"
}

test_an_unobservable_worktree_binding_refuses_before_any_launch_allocation() {
  local rec home proj wt fakebin case_dir out rc id
  id=unobservable-preallocation
  make_launch_case "$id" || fail "launch fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-$id"
  mkdir "$proj/.git/config.worktree" || fail "unobservable worktree setup failed"
  make_launch_brief "$home" "$id" local-only || fail "brief fixture failed"

  out=$(run_launch "$case_dir" "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode local-only --yolo off --reason-code NL_RULE_CLASSIFICATION); rc=$?
  [ "$rc" -ne 0 ] || fail "an unobservable worktree identity must refuse before allocation: $out"
  assert_contains "$out" "could not be installed and re-observed" "the refusal must identify the unobservable binding"
  assert_absent "$home/state/$id.meta" "the refusal must publish no task record"
  assert_absent "$case_dir/endpoint-allocated" "the refusal must allocate no endpoint"
  assert_absent "$case_dir/slot-allocated" "the refusal must allocate no slot"
  pass "an unobservable worktree identity refuses before any launch allocation"
}

test_a_retargeted_launch_binds_the_contribution_venue_and_unresolved_refuses() {
  local rec home proj wt fakebin case_dir out rc id target_identity origin_identity policy target identity
  id=retargeted
  target_identity='Target Lane <target@example.invalid>'
  origin_identity='Origin Lane <origin@example.invalid>'
  policy=$(jq -n --arg a "$origin_identity" --arg b "$target_identity" '{generation:"g",venues:{
    "example.invalid/sbracewell64/firstmate":{identities:{author:$a,committer:$a}},
    "example.invalid/target/project":{identities:{author:$b,committer:$b}}
  }}') || fail "policy setup failed"
  make_launch_case "$id" "$policy" || fail "launch fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-$id"
  git -C "$proj" remote add upstream git@example.invalid:target/project.git || fail "upstream setup failed"
  target=$(git -C "$proj" rev-parse HEAD) || fail "target setup failed"
  git -C "$proj" update-ref refs/remotes/upstream/main "$target" || fail "upstream ref setup failed"
  git -C "$proj" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/main || fail "upstream head setup failed"
  make_launch_brief "$home" "$id" no-mistakes || fail "brief fixture failed"
  out=$(run_launch "$case_dir" "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION --contribution-target "$target") || true
  assert_not_contains "$out" "is not launching" "the retargeted launch must be admitted"
  identity=$(HOME="$case_dir/home_env" commit_identity "$wt" "retargeted commit") || fail "retargeted commit failed"
  [ "$identity" = "$target_identity|$target_identity" ] || fail "the launch bound origin instead of the contribution venue: $identity"

  id=unresolved-venue
  make_launch_case "$id" "$policy" || fail "unresolved fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-$id"
  git -C "$proj" remote add upstream git@example.invalid:target/project.git || fail "unresolved upstream setup failed"
  target=$(git -C "$proj" rev-parse HEAD) || fail "unresolved target setup failed"
  make_launch_brief "$home" "$id" no-mistakes || fail "brief fixture failed"
  out=$(run_launch "$case_dir" "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION --contribution-target "$target"); rc=$?
  [ "$rc" -ne 0 ] || fail "an unresolved venue must refuse before allocation: $out"
  assert_contains "$out" "FM_CI_VENUE_UNOBSERVED" "the launch must carry the unresolved-venue token"
  assert_absent "$home/state/$id.meta" "an unresolved venue must publish no task record"
  pass "a retargeted launch binds its contribution venue and unresolved refuses"
}

# THE SHARED-GATE CUSTODY CONTROL.
#
# The validation pipeline's gate repository is shared per project and holds ONE
# identity pair, so two same-project lanes governed by different venues cannot
# both be served by it. Before this control the second lane was admitted, rebound
# that repository to its own identity, and the first lane's pipeline stages then
# committed as the second - a wrong immutable object with nothing wrong in
# either lane.
#
# This drives the real launch path for both lanes and asserts the whole shape:
# the second is refused, the refusal names who holds it and both venues, nothing
# is allocated for it, the first lane's own gate commit still carries its own
# identity, and - once the holder is released - the second lane is admitted and
# binds ITS identity, which is what proves the binding follows authority rather
# than a value baked in somewhere.
test_a_contended_shared_gate_refuses_the_second_lane_until_released() {
  local rec home proj first_wt fakebin case_dir second_wt upstream_identity fork_identity
  local policy upstream_target fork_target default_branch out rc identity shared_before shared_after gate
  upstream_identity='Upstream Lane <upstream@example.invalid>'
  fork_identity='Fork Lane <fork@example.invalid>'
  policy=$(jq -n --arg a "$fork_identity" --arg b "$upstream_identity" '{generation:"g",venues:{
    "example.invalid/sbracewell64/firstmate":{identities:{author:$a,committer:$a}},
    "example.invalid/upstream/project":{identities:{author:$b,committer:$b}}
  }}') || fail "policy setup failed"
  make_launch_case custody "$policy" || fail "launch fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj first_wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-custody"
  gate="$case_dir/nm/repos/gate.git"
  second_wt="$case_dir/wt-second"
  upstream_target=$(git -C "$proj" rev-parse HEAD) || fail "upstream target setup failed"
  git -C "$proj" remote add upstream git@example.invalid:upstream/project.git || fail "upstream setup failed"
  git -C "$proj" update-ref refs/remotes/upstream/main "$upstream_target" || fail "upstream ref setup failed"
  git -C "$proj" symbolic-ref refs/remotes/upstream/HEAD refs/remotes/upstream/main || fail "upstream head setup failed"
  git -C "$proj" worktree add -q -b custody-second "$second_wt" || fail "second worktree setup failed"
  git -C "$second_wt" -c user.name=Seed -c user.email=seed@example.invalid commit -q --allow-empty -m fork-only || fail "fork target setup failed"
  fork_target=$(git -C "$second_wt" rev-parse HEAD) || fail "fork target read failed"
  default_branch=$(git -C "$proj" symbolic-ref --quiet --short HEAD) || fail "default branch setup failed"
  git -C "$proj" update-ref "refs/remotes/origin/$default_branch" "$fork_target" || fail "fork ref setup failed"
  shared_before=$(git -C "$proj" config --local --get-regexp '^user\.' 2>/dev/null || true)

  # Lane A, governed by the upstream venue, is admitted and takes the gate.
  make_launch_brief "$home" custody-a no-mistakes || fail "first brief failed"
  printf 'Base contract: slot=%s contribution=%s\n' "$upstream_target" "$upstream_target" >> "$home/data/custody-a/brief.md" || fail "first base contract failed"
  out=$(run_launch "$case_dir" "$home" "$first_wt" "$fakebin" custody-a "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION --contribution-target "$upstream_target") || true
  assert_not_contains "$out" "is not launching" "the first lane must be admitted"
  assert_grep "commit_identity=$upstream_identity" "$home/state/custody-a.meta" "the admitted lane must record the identity it holds the gate under"

  # Lane B, same project, governed by the fork venue, contends for that one pair.
  make_launch_brief "$home" custody-b no-mistakes || fail "second brief failed"
  printf 'Base contract: slot=%s contribution=%s\n' "$upstream_target" "$fork_target" >> "$home/data/custody-b/brief.md" || fail "second base contract failed"
  out=$(run_launch "$case_dir" "$home" "$second_wt" "$fakebin" custody-b "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION --contribution-target "$fork_target"); rc=$?
  [ "$rc" -ne 0 ] || fail "a contended shared gate must refuse the second lane: $out"
  assert_contains "$out" "custody-a" "the refusal must name the lane holding the repository"
  assert_contains "$out" "$upstream_identity" "the refusal must name the holder's identity"
  assert_contains "$out" "$fork_identity" "the refusal must name this lane's own identity"
  assert_contains "$out" "example.invalid/upstream/project" "the refusal must name the holder's venue"
  assert_contains "$out" "example.invalid/sbracewell64/firstmate" "the refusal must name this lane's venue"
  assert_contains "$out" "WAIT, not a failure" "the refusal must say the dispatch is waiting rather than failed"
  assert_absent "$home/state/custody-b.meta" "a refused lane must publish no task record"
  assert_absent "$home/state/custody-b.attempt" "a refused lane must spend no attempt"

  # The holder's own pipeline path still commits as the holder.
  git --git-dir="$gate" worktree add -q "$case_dir/gatewt" main || fail "gate worktree failed"
  identity=$(HOME="$case_dir/home_env" commit_identity "$case_dir/gatewt" "pipeline stage commit") || fail "gate commit failed"
  [ "$identity" = "$upstream_identity|$upstream_identity" ] \
    || fail "the holder's pipeline repository must still carry the holder's identity, got: $identity"

  # Worktree isolation and the shared repository identity are both preserved.
  identity=$(HOME="$case_dir/home_env" commit_identity "$first_wt" "holder worker commit") || fail "holder worker commit failed"
  [ "$identity" = "$upstream_identity|$upstream_identity" ] || fail "the holder's worktree lost its binding: $identity"
  shared_after=$(git -C "$proj" config --local --get-regexp '^user\.' 2>/dev/null || true)
  [ "$shared_after" = "$shared_before" ] || fail "launches rewrote shared repository-local identity: $shared_before -> $shared_after"

  # RELEASE the holder, exactly as teardown does, and the contended lane becomes
  # admissible and binds its OWN identity - the composition proving the binding
  # follows authority and that custody is a wait rather than a permanent claim.
  rm -f "$home/state/custody-a.meta" || fail "release failed"
  out=$(run_launch "$case_dir" "$home" "$second_wt" "$fakebin" custody-b "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION --contribution-target "$fork_target") || true
  assert_not_contains "$out" "is not launching" "the contended lane must be admitted once the holder is released"
  identity=$(HOME="$case_dir/home_env" commit_identity "$case_dir/gatewt" "second lane pipeline commit") || fail "second gate commit failed"
  [ "$identity" = "$fork_identity|$fork_identity" ] \
    || fail "the released gate must be re-established to the new holder rather than reusing the stale binding, got: $identity"
  pass "a contended shared gate refuses the second lane naming both venues, and releases to it intact"
}

# The cone is exactly the contended resource. Two same-project lanes whose venues
# resolve to the SAME identity are not contending for anything, so they must both
# run - otherwise this control would be serializing ordinary parallel work.
test_same_identity_lanes_on_one_project_are_not_contended() {
  local rec home proj first_wt fakebin case_dir second_wt out identity
  make_launch_case uncontended || fail "launch fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj first_wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-uncontended"
  second_wt="$case_dir/wt-second"
  git -C "$proj" worktree add -q -b uncontended-second "$second_wt" || fail "second worktree setup failed"

  make_launch_brief "$home" uncontended-a no-mistakes || fail "first brief failed"
  out=$(run_launch "$case_dir" "$home" "$first_wt" "$fakebin" uncontended-a "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION) || true
  assert_not_contains "$out" "is not launching" "the first lane must be admitted"
  make_launch_brief "$home" uncontended-b no-mistakes || fail "second brief failed"
  out=$(run_launch "$case_dir" "$home" "$second_wt" "$fakebin" uncontended-b "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION) || true
  assert_not_contains "$out" "is not launching" "a same-identity lane must not be treated as contended"
  identity=$(HOME="$case_dir/home_env" commit_identity "$second_wt" "second same-identity commit") || fail "second commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] || fail "the second lane lost its binding: $identity"
  pass "two same-project lanes resolving one identity are admitted together"
}

# THE POSITIVE END-TO-END CONTROL. Ordinary lifecycle, no operator anywhere near
# the binder, and then real commit objects made the two ways production commits
# are actually made: by the worker in its own slot, and by a pipeline stage in
# the gate repository. Both must carry the authoritative author AND committer
# even though nothing in this test ever ran the binding command.
test_an_ordinary_launch_binds_both_production_paths_with_no_manual_step() {
  local rec home proj wt fakebin case_dir out id identity gate
  id=ordinary
  make_launch_case "$id" || fail "launch fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-$id"
  gate="$case_dir/nm/repos/gate.git"
  make_launch_brief "$home" "$id" no-mistakes || fail "brief fixture failed"

  # The launch is driven for real and its own completion is NOT the subject: a
  # stand-in terminal may or may not finish its handshake, and crediting this
  # control with that would be measuring the fixture. What is asserted is that
  # the launch was not stopped by the identity gate, and then what real commit
  # objects carry afterwards - which is the thing the ruling asks about.
  out=$(run_launch "$case_dir" "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION) || true
  assert_not_contains "$out" "is not launching" "the identity gate must admit a bindable launch"

  # The worker's own commit, in the slot the launch handed over.
  # shellcheck disable=SC2016  # positional args inside bash -c, not expansions
  identity=$(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME \
    -u GIT_COMMITTER_EMAIL HOME="$case_dir/home_env" bash -c \
    'cd "$1" && git commit -q --allow-empty -m "worker commit" && git log -1 --format="%an <%ae>|%cn <%ce>"' _ "$wt") \
    || fail "worker commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] \
    || fail "the worker path must carry the authoritative identity with no manual binding, got: $identity"

  # A pipeline stage's commit, in the gate repository the launch also bound.
  git --git-dir="$gate" worktree add -q "$case_dir/gatewt" main || fail "gate worktree failed"
  # shellcheck disable=SC2016  # positional args inside bash -c, not expansions
  identity=$(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME \
    -u GIT_COMMITTER_EMAIL HOME="$case_dir/home_env" bash -c \
    'cd "$1" && git commit -q --allow-empty -m "pipeline stage commit" && git log -1 --format="%an <%ae>|%cn <%ce>"' _ "$case_dir/gatewt") \
    || fail "gate commit failed"
  [ "$identity" = "$AUTHORITATIVE|$AUTHORITATIVE" ] \
    || fail "the pipeline path must carry the authoritative identity with no manual binding, got: $identity"
  pass "an ordinary launch binds the worker slot and the pipeline repository with no manual binding step"
}

# An ungoverned home is not a refusal. This fleet already reads an absent
# publication identity policy as "this home declared no governance" at the
# publication seam, and reversing that here would stop every dispatch in a home
# that never opted in - a verdict about a promise nobody made.
test_an_ungoverned_home_launches_and_says_so() {
  local rec home proj wt fakebin case_dir out id
  id=ungoverned
  make_launch_case "$id" none || fail "launch fixture setup failed"
  rec=$LAUNCH_CASE_REC
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  case_dir="$TMP_ROOT/launch-$id"
  make_launch_brief "$home" "$id" no-mistakes || fail "brief fixture failed"
  out=$(run_launch "$case_dir" "$home" "$wt" "$fakebin" "$id" "$proj" claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION) || true
  assert_not_contains "$out" "is not launching" "a home that declared no policy must not be refused by the identity gate"
  assert_contains "$out" "ungoverned" "an ungoverned launch must say so rather than pass silently"
  pass "a home with no publication identity policy launches and reports the provenance as ungoverned"
}

FM_CONTROLS=(
  test_an_unbound_gate_reproduces_the_published_defect
  test_binding_makes_an_ordinary_pipeline_commit_authoritative
  test_poisoned_identity_environment_refuses_before_any_commit
  test_matching_identity_environment_still_refuses_by_presence
  test_poisoned_repository_and_global_config_lose_to_the_binding
  test_fixture_identity_in_the_same_session_does_not_cross_the_boundary
  test_the_binding_survives_a_restart_between_commits
  test_an_unusable_authoritative_identity_refuses_and_commits_nothing
  test_an_unreadable_policy_is_could_not_observe_not_a_refusal
  test_an_uninitialized_pipeline_is_not_applicable_rather_than_unobserved
  test_an_unreadable_gate_report_is_could_not_observe
  test_a_pipeline_daemon_carrying_an_identity_variable_refuses
  test_a_pipeline_daemon_carrying_empty_or_matching_variables_refuses
  test_an_unidentifiable_daemon_is_could_not_observe
  test_a_reused_daemon_pid_is_could_not_observe
  test_ps_metadata_without_environment_is_could_not_observe
  test_production_cannot_redirect_daemon_environment_observation
  test_the_env_verb_emits_the_channel_that_outranks_everything
  test_the_env_channel_preserves_distinct_author_and_committer
  test_the_repository_channel_clearly_refuses_distinct_roles
  test_a_launch_whose_identity_cannot_bind_is_mechanically_refused
  test_distinct_roles_refuse_before_any_launch_allocation
  test_an_unobservable_worktree_binding_refuses_before_any_launch_allocation
  test_a_retargeted_launch_binds_the_contribution_venue_and_unresolved_refuses
  test_a_contended_shared_gate_refuses_the_second_lane_until_released
  test_same_identity_lanes_on_one_project_are_not_contended
  test_an_ordinary_launch_binds_both_production_paths_with_no_manual_step
  test_an_ungoverned_home_launches_and_says_so
)

for control in "${FM_CONTROLS[@]}"; do
  "$control"
done
fm_test_contract "${BASH_SOURCE[0]}"
