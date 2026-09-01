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

write_policy() {  # <root> <author> <committer>
  local root=${1:?} author=${2:-} committer=${3:-}
  jq -n --arg a "$author" --arg c "$committer" '{
    generation: "pol-test-g1",
    venues: { "github.com/sbracewell64/firstmate": { identities: (
      (if $a == "" then {} else { author: $a } end) +
      (if $c == "" then {} else { committer: $c } end) +
      { delivery_actor: "sbracewell64", maker: "m/one", reviewer: "r/two", ruling: "browser-sol" }
    ) } }
  }' > "$root/config/publication-identity.json"
}

# A live process standing in for the pipeline daemon, so the environment check
# reads a real one. Extra arguments are VAR=VALUE assignments placed into it.
start_daemon() {  # <root> [VAR=VALUE...]
  local root=${1:?} pid
  shift
  env "$@" sleep 300 &
  pid=$!
  fm_test_reap "$pid"
  printf '{"pid":%s,"started_at":"2026-09-01T00:00:00Z"}' "$pid" > "$root/nm/daemon.pid" || return 1
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

test_an_unidentifiable_daemon_is_could_not_observe() {
  local root out rc
  root=$(make_case daemon-absent) || fail "fixture setup failed"
  out=$(run_cmd "$root" bind); rc=$?
  expect_code 2 "$rc" "an unidentifiable daemon is could-not-observe: $out"
  assert_contains "$out" "UNOBSERVED" "the daemon channel must be reported unobservable"
  pass "a pipeline daemon that cannot be identified leaves its channel could-not-observe rather than clean"
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

FM_CONTROLS=(
  test_an_unbound_gate_reproduces_the_published_defect
  test_binding_makes_an_ordinary_pipeline_commit_authoritative
  test_poisoned_identity_environment_refuses_before_any_commit
  test_poisoned_repository_and_global_config_lose_to_the_binding
  test_fixture_identity_in_the_same_session_does_not_cross_the_boundary
  test_the_binding_survives_a_restart_between_commits
  test_an_unusable_authoritative_identity_refuses_and_commits_nothing
  test_an_unreadable_policy_is_could_not_observe_not_a_refusal
  test_an_uninitialized_pipeline_is_not_applicable_rather_than_unobserved
  test_an_unreadable_gate_report_is_could_not_observe
  test_a_pipeline_daemon_carrying_an_identity_variable_refuses
  test_an_unidentifiable_daemon_is_could_not_observe
  test_the_env_verb_emits_the_channel_that_outranks_everything
  test_the_env_channel_preserves_distinct_author_and_committer
  test_the_repository_channel_clearly_refuses_distinct_roles
)

for control in "${FM_CONTROLS[@]}"; do
  "$control"
done
fm_test_contract "${BASH_SOURCE[0]}"
