#!/usr/bin/env bash
# Behavior tests for the pre-reservation role-path and custody preflight
# (bin/fm-role-path-lib.sh), driven through its two public interfaces:
# `bin/fm-route.sh role-path` and the `bin/fm-spawn.sh` chokepoint.
#
# The point of this suite is not that a refusal is PRINTED. It is that a refusal
# ALLOCATES NOTHING. Before this product existed, the facts a dispatch rested on
# were each owned somewhere, but no single answer joined them, so a route
# decision taken against one generation could admit a dispatch whose custody had
# already moved under another. Every red below is a way that used to be able to
# happen, and each one asserts the effect count as well as the verdict.
#
# Every case drives an executable interface. Nothing here reads the library's
# source, because a test that asserts implementation bytes passes for a
# reimplementation that does the wrong thing.
set -u

# Opt into the identity ledger: this suite's whole subject is vacuity, so a case
# that is declared and never invoked must fail the suite rather than quietly
# reduce what it proves.
FM_TEST_IDENTITY_CONTRACT=1

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-route.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SURFACE="$ROOT/bin/fm-decision-surface.sh"
TMP_ROOT=$(fm_test_tmproot fm-role-path)

# --- fixtures ---------------------------------------------------------------

# One candidate: a repository with a base commit and a branch carrying work, a
# home, and a `no-mistakes` stub whose run listing this case controls.
make_case() {  # <name> -> "<dir>|<repo>|<home>|<fakebin>|<base>|<head>"
  local name=$1 dir repo home fakebin base head
  dir="$TMP_ROOT/$name"
  repo="$dir/repo"
  home="$dir/home"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$repo" "$home/state" "$home/config" "$home/data"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q -b feat
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
  head=$(git -C "$repo" rev-parse HEAD)
  # Default: a COMPLETE census reporting no runs at all. A case that needs a
  # different population overwrites this stub.
  census_stub "$fakebin" ''
  printf '%s|%s|%s|%s|%s|%s' "$dir" "$repo" "$home" "$fakebin" "$base" "$head"
}

# A `no-mistakes` whose `runs` prints exactly <rows> and nothing else, so a case
# states the run population it is about instead of depending on the host's.
census_stub() {  # <fakebin> <rows>
  local fakebin=$1 rows=$2
  { printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = runs ]; then\n'
    printf '  cat <<'"'"'ROWS'"'"'\n%s\nROWS\n' "$rows"
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'exit 0\n'
  } > "$fakebin/no-mistakes"
  chmod +x "$fakebin/no-mistakes"
}

# The product, through the read interface. Echoes the JSON; sets RP_RC.
RP_RC=0
role_path() {  # <fakebin> <home> <args...>
  local fakebin=$1 home=$2
  shift 2
  RP_RC=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json "$@" >/dev/null 2>&1 || RP_RC=$?
}

field() { printf '%s' "$1" | jq -r "$2"; }

# Everything a refusal is forbidden to create. Captured as one string so a case
# can assert the WHOLE effect surface is unchanged rather than the one part it
# happened to think of.
effect_snapshot() {  # <home> <repo>
  local home=$1 repo=$2
  {
    printf 'state:\n';    ls -1A "$home/state" 2>/dev/null | LC_ALL=C sort
    printf 'data:\n';     ls -1A "$home/data" 2>/dev/null | LC_ALL=C sort
    printf 'branches:\n'; git -C "$repo" for-each-ref --format='%(refname) %(objectname)' 2>/dev/null | LC_ALL=C sort
    printf 'worktrees:\n'; git -C "$repo" worktree list --porcelain 2>/dev/null | LC_ALL=C sort
    printf 'status:\n';   git -C "$repo" status --porcelain 2>/dev/null | LC_ALL=C sort
  }
}

# --- non-vacuity: the complete eligible product proceeds, exactly once -------

test_complete_eligible_product_is_permitted_and_names_one_reservation() {
  local rec dir repo home fakebin base head out
  rec=$(make_case positive)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  role_path "$fakebin" "$home" \
    --work W-positive --repository "$repo" --branch feat --base "$base" \
    --candidate-head "$head" --venue github.com/x/y --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat"
  out=$RP_RC
  [ "$out" -eq 0 ] || fail "a complete eligible product must be PERMITTED, got exit $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W-positive --repository "$repo" --branch feat --base "$base" \
    --candidate-head "$head" --venue github.com/x/y --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null)
  [ "$(field "$out" .verdict)" = PERMITTED ] || fail "verdict must be PERMITTED: $out"
  # EXACTLY ONE reservation, and exactly one mutation owner. A product that
  # named two of either would be authorizing a race rather than preventing one.
  [ "$(field "$out" '.reservation | if . == null then 0 else 1 end')" = 1 ] \
    || fail "PERMITTED must name exactly one reservation identity: $out"
  [ "$(field "$out" '.custody.mutation_owner')" = W-positive ] \
    || fail "PERMITTED must settle one mutation owner: $out"
  [ "$(field "$out" '.custody.live_owner_count')" = 0 ] \
    || fail "PERMITTED requires an empty live-owner set, so this dispatch can become its single member: $out"
  # The generation this decision was computed for is recorded, so it can be
  # shown to have been made against THIS candidate and not a later one.
  [ "$(field "$out" '.generation.candidate_head')" = "$head" ] \
    || fail "the product must record the candidate generation it was computed for: $out"
  [ "$(field "$out" '.generation.no_mistakes_census_digest')" != not-applicable ] \
    || fail "a no-mistakes delivery must record a real census digest, not not-applicable: $out"
  # And every required role really was covered, so this pass is not vacuous.
  [ "$(field "$out" '.required_roles | length')" = 2 ] \
    || fail "the default read interface must require maker and checker: $out"
  [ "$(field "$out" '.role_path | length')" = 2 ] \
    || fail "both roles must appear in the product: $out"
  pass "role-path: one complete eligible product is PERMITTED and names exactly one reservation"
}

test_a_permitted_product_still_allocates_nothing_by_itself() {
  local rec dir repo home fakebin base head before after
  rec=$(make_case permitted-no-effect)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  before=$(effect_snapshot "$home" "$repo")
  role_path "$fakebin" "$home" \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat"
  [ "$RP_RC" -eq 0 ] || fail "fixture must be PERMITTED for this control to mean anything"
  after=$(effect_snapshot "$home" "$repo")
  # The product NAMES a reservation; naming is not holding. Even the permitted
  # verdict must leave the effect surface untouched, because the allocation
  # belongs to the existing allocator and not to the thing that authorized it.
  [ "$before" = "$after" ] \
    || fail "computing the product changed the effect surface:"$'\n'"--- before"$'\n'"$before"$'\n'"--- after"$'\n'"$after"
  pass "role-path: even a PERMITTED product allocates nothing itself"
}

# --- reds: the role path ----------------------------------------------------

test_omitted_maker_is_could_not_observe_not_a_pass() {
  local rec dir repo home fakebin base head out
  rec=$(make_case omit-maker)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir" "$head"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --mode no-mistakes \
    --role "checker|codex/gpt|$repo:feat" 2>/dev/null) && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 4 ] || fail "an omitted maker must be could-not-observe (exit 4), got $RP_RC"
  [ "$(field "$out" .verdict)" = CNO ] || fail "verdict must be CNO: $out"
  [ "$(field "$out" .reason_code)" = INCOMPLETE_ROLE_PATH ] \
    || fail "an omitted role axis must report INCOMPLETE_ROLE_PATH: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "CNO must name no reservation: $out"
  pass "role-path: an omitted maker is INCOMPLETE_ROLE_PATH with no reservation"
}

test_omitted_checker_is_could_not_observe_not_a_pass() {
  local rec dir repo home fakebin base head out
  rec=$(make_case omit-checker)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir" "$head"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" 2>/dev/null) && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 4 ] || fail "an omitted checker must be could-not-observe (exit 4), got $RP_RC"
  [ "$(field "$out" .reason_code)" = INCOMPLETE_ROLE_PATH ] \
    || fail "an omitted checker must report INCOMPLETE_ROLE_PATH: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "CNO must name no reservation: $out"
  pass "role-path: an omitted checker is INCOMPLETE_ROLE_PATH with no reservation"
}

test_maker_and_checker_collapsing_to_one_assignment_is_refused() {
  local rec dir repo home fakebin base head out
  rec=$(make_case assignment-collapse)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|claude/opus|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "an assignment collapse must be REFUSED (exit 1), got $RP_RC"
  [ "$(field "$out" .reason_code)" = ASSIGNMENT_NOT_DISTINCT ] \
    || fail "two roles that are one assignment must report ASSIGNMENT_NOT_DISTINCT: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "REFUSED must name no reservation: $out"
  # Both roles are declared and both are qualified-inert; what is refused is the
  # IDENTITY collapse, not a missing declaration. Asserting that keeps this case
  # from passing for the wrong reason if the completeness check ever regressed.
  [ "$(field "$out" '.role_path | length')" = 2 ] \
    || fail "both roles must be declared, so the refusal is about identity and not absence: $out"
  pass "role-path: a maker reviewing its own mutation is ASSIGNMENT_NOT_DISTINCT"
}

test_a_role_outside_the_governed_path_is_refused() {
  local rec dir repo home fakebin base head out
  rec=$(make_case forbidden-path)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" \
    --role "checker|codex/gpt|/elsewhere/repo:main" 2>/dev/null) && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "a role on an ungoverned path must be REFUSED, got $RP_RC"
  [ "$(field "$out" .reason_code)" = ROLE_PATH_NOT_PERMITTED ] \
    || fail "a role acting outside the covered path must report ROLE_PATH_NOT_PERMITTED: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "REFUSED must name no reservation: $out"
  pass "role-path: a role acting outside the governed resource path is ROLE_PATH_NOT_PERMITTED"
}

test_a_declared_contract_that_cannot_be_read_is_could_not_observe() {
  local rec dir repo home fakebin base head out
  rec=$(make_case qual-unreadable)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # A capability contract the register does not hold. The requirement is real
  # and its evidence is unreadable, which is neither met nor disproved - and a
  # declared requirement whose contract is missing has certainly not been met.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" \
    --contract "maker|no-such-contract" 2>/dev/null) && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 4 ] || fail "an unreadable capability contract must be could-not-observe, got $RP_RC"
  [ "$(field "$out" .reason_code)" = ROLE_QUALIFICATION_UNOBSERVED ] \
    || fail "an unreadable contract must report ROLE_QUALIFICATION_UNOBSERVED: $out"
  [ "$(field "$out" '.role_path[] | select(.role == "maker") | .qualification')" = CNO ] \
    || fail "the role must carry its own could-not-observe qualification: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "CNO must name no reservation: $out"
  pass "role-path: a declared contract the register cannot read is ROLE_QUALIFICATION_UNOBSERVED"
}

test_an_unqualified_binding_may_not_take_the_assignment() {
  local rec dir repo home fakebin base head out
  rec=$(make_case qual-required)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # A real contract from this repo's register, against a binding the register
  # holds no observation for. Missing evidence is an engineering state rather
  # than a capability judgement, but it is emphatically not a qualification, so
  # the binding may not take the assignment on the strength of its name.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" \
    --contract "maker|runtime-change-review" 2>/dev/null) && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "an unqualified maker must be REFUSED, got $RP_RC"
  [ "$(field "$out" .reason_code)" = ROLE_PATH_NOT_PERMITTED ] \
    || fail "an unqualified binding must report ROLE_PATH_NOT_PERMITTED: $out"
  [ "$(field "$out" '.role_path[] | select(.role == "maker") | .qualification')" = NOT_QUALIFIED ] \
    || fail "the role must carry its own NOT_QUALIFIED state: $out"
  # NEGATIVE CONTROL: the checker declares no contract, so it carries no
  # requirement at all. NOT_APPLICABLE is the absence of a requirement and must
  # never be confused with an unmet or unread one.
  [ "$(field "$out" '.role_path[] | select(.role == "checker") | .qualification')" = NOT_APPLICABLE ] \
    || fail "a role with no declared contract must be NOT_APPLICABLE, not CNO: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "REFUSED must name no reservation: $out"
  pass "role-path: a binding the register has not observed may not take the assignment"
}

# --- reds: generation -------------------------------------------------------

test_a_candidate_that_moved_under_the_decision_is_refused() {
  local rec dir repo home fakebin base head out
  rec=$(make_case stale-candidate)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # The generation this product was computed for is no longer the branch tip.
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m moved
  [ "$(git -C "$repo" rev-parse HEAD)" != "$head" ] \
    || fail "fixture did not actually move the candidate"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "a moved candidate must be REFUSED, got $RP_RC"
  [ "$(field "$out" .reason_code)" = STALE_CANDIDATE_GENERATION ] \
    || fail "a candidate that moved must report STALE_CANDIDATE_GENERATION: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "REFUSED must name no reservation: $out"
  # Exact-head applicability: the product names BOTH heads, so the disagreement
  # is inspectable rather than merely asserted.
  [ "$(field "$out" '.work.candidate_head')" = "$head" ] || fail "claimed head must be recorded: $out"
  [ "$(field "$out" '.work.observed_head')" != "$head" ] || fail "observed head must differ: $out"
  pass "role-path: a candidate that moved under the decision is STALE_CANDIDATE_GENERATION"
}

test_the_same_product_is_permitted_at_the_head_it_was_computed_for() {
  local rec dir repo home fakebin base head moved
  rec=$(make_case exact-head-control)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # NEGATIVE CONTROL for the case above: the identical request at the head the
  # branch actually carries must pass, so STALE_CANDIDATE_GENERATION is proven
  # to discriminate on the head rather than refusing every stated head.
  role_path "$fakebin" "$home" \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat"
  [ "$RP_RC" -eq 0 ] || fail "the head the branch carries must be PERMITTED, got $RP_RC"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m moved
  moved=$(git -C "$repo" rev-parse HEAD)
  role_path "$fakebin" "$home" \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$moved" \
    --mode no-mistakes --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat"
  [ "$RP_RC" -eq 0 ] || fail "the NEW head must also be PERMITTED once it is the tip, got $RP_RC"
  pass "role-path: the staleness axis discriminates on the exact head rather than refusing any head"
}

# --- reds: custody ----------------------------------------------------------

test_a_live_no_mistakes_run_owning_the_branch_is_refused() {
  local rec dir repo home fakebin base head out
  rec=$(make_case participant-owns)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  census_stub "$fakebin" "  running    feat ${head:0:8}  2026-01-01"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "a live run owning the branch must be REFUSED, got $RP_RC"
  [ "$(field "$out" .reason_code)" = PARTICIPANT_OWNS_MUTATION ] \
    || fail "a pipeline holding the candidate must report PARTICIPANT_OWNS_MUTATION: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "REFUSED must name no reservation: $out"
  pass "role-path: a live no-mistakes run owning the candidate is PARTICIPANT_OWNS_MUTATION"
}

test_a_terminal_run_on_the_same_branch_does_not_own_it() {
  local rec dir repo home fakebin base head st
  rec=$(make_case terminal-runs)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # NEGATIVE CONTROL for the case above. A finished run must NOT read as an
  # owner, or the refusal would be triggered by the branch appearing at all and
  # would block every candidate that has ever been validated.
  for st in completed failed cancelled; do
    census_stub "$fakebin" "  $st    feat ${head:0:8}  2026-01-01"
    role_path "$fakebin" "$home" \
      --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
      --mode no-mistakes --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat"
    [ "$RP_RC" -eq 0 ] || fail "a $st run must not own the candidate, got exit $RP_RC"
  done
  # And a run on ANOTHER branch is not this candidate's owner either.
  census_stub "$fakebin" "  running    other-branch ${head:0:8}  2026-01-01"
  role_path "$fakebin" "$home" \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat"
  [ "$RP_RC" -eq 0 ] || fail "a live run on another branch must not own this candidate, got $RP_RC"
  pass "role-path: only a LIVE run on THIS branch owns the candidate"
}

test_an_unrecognised_run_status_is_treated_as_live() {
  local rec dir repo home fakebin base head out
  rec=$(make_case unknown-status)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # A status this fleet has never seen might be a run that still owns an effect.
  # Reading it as finished is the fail-open direction, and it is the direction
  # that lets a dispatch land on top of a live pipeline.
  census_stub "$fakebin" "  quiescing    feat ${head:0:8}  2026-01-01"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "an unrecognised run status must fail closed, got $RP_RC"
  [ "$(field "$out" .reason_code)" = PARTICIPANT_OWNS_MUTATION ] \
    || fail "an unrecognised status must be treated as a live owner: $out"
  pass "role-path: an unrecognised run status is treated as live, not as finished"
}

test_an_incomplete_census_is_could_not_observe() {
  local rec dir repo home fakebin base head out
  rec=$(make_case census-incomplete)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # The listing says more runs exist than it showed. The population this census
  # would have to cover is exactly the part it did not print.
  census_stub "$fakebin" "  completed    other 1111aaaa  2026-01-01
  (9 more runs, use --limit to see more)"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 4 ] || fail "a truncated census must be could-not-observe (exit 4), got $RP_RC"
  [ "$(field "$out" .reason_code)" = NM_CENSUS_INCOMPLETE ] \
    || fail "a truncated run listing must report NM_CENSUS_INCOMPLETE: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "CNO must name no reservation: $out"
  # An APPLICABLE census that could not be read must record that it was unread.
  # Recording not-applicable here would credit a census nobody could take with a
  # question that did not apply to this work.
  [ "$(field "$out" '.generation.no_mistakes_census_digest')" = unobserved ] \
    || fail "an unread but applicable census must record unobserved: $out"
  [ "$(field "$out" '.custody.no_mistakes_run')" = unobserved ] \
    || fail "custody must not claim no run when the census was unread: $out"
  pass "role-path: a truncated run census is NM_CENSUS_INCOMPLETE, never an empty one"
}

test_a_tool_refusal_that_exits_zero_is_not_an_empty_census() {
  local rec dir repo home fakebin base head out
  rec=$(make_case census-refusal)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # Measured behaviour of the real tool: it writes a refusal to stdout and does
  # NOT always exit non-zero for one. A reader judging the status alone sees a
  # clean run that listed nothing, which is a refusal promoted to a pass. The
  # uninitialized refusal is classified separately (see the case above); every
  # OTHER exit-zero refusal must remain could-not-observe.
  { printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = runs ]; then echo "error: run store unavailable"; exit 0; fi\n'
    printf 'exit 0\n'
  } > "$fakebin/no-mistakes"
  chmod +x "$fakebin/no-mistakes"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 4 ] || fail "an exit-zero tool refusal must be could-not-observe, got $RP_RC"
  [ "$(field "$out" .reason_code)" = NM_CENSUS_INCOMPLETE ] \
    || fail "an exit-zero refusal must report NM_CENSUS_INCOMPLETE: $out"
  pass "role-path: a run listing that refuses while exiting zero is could-not-observe"
}

test_an_uninitialized_repository_is_an_established_absence_not_an_unread_one() {
  local rec dir repo home fakebin base head out
  rec=$(make_case census-uninitialized)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # Measured behaviour: `no-mistakes runs` refuses an uninitialized repository on
  # STDERR while exiting 1, and `axi status` refuses the same condition on STDOUT
  # while exiting 0. Reading only the status calls one a broken read and the
  # other a clean empty census. Both are the same fact, and that fact is that no
  # pipeline exists here to own anything - an established absence.
  { printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = runs ]; then\n'
    printf '  echo "repo not initialized (run '"'"'no-mistakes init'"'"' first)" >&2\n'
    printf '  exit 1\n'
    printf 'fi\n'
    printf 'exit 0\n'
  } > "$fakebin/no-mistakes"
  chmod +x "$fakebin/no-mistakes"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 0 ] || fail "a repository with no pipeline must not be refused on the run census, got $RP_RC"
  # It must be recorded under its OWN name: neither a covered census nor an
  # unread one, so no later reader can credit it with either.
  [ "$(field "$out" '.generation.no_mistakes_census_digest')" = not-initialized ] \
    || fail "an uninitialized repository must be recorded as not-initialized: $out"
  [ "$(field "$out" '.custody.no_mistakes_run')" = not-initialized ] \
    || fail "custody must name the uninitialized repository rather than claiming no run: $out"
  # NEGATIVE CONTROL: an unrecognised failure from the same command still
  # refuses, so the classification above is narrow rather than a blanket pass.
  { printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = runs ]; then echo "database is locked" >&2; exit 1; fi\n'
    printf 'exit 0\n'
  } > "$fakebin/no-mistakes"
  chmod +x "$fakebin/no-mistakes"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 4 ] || fail "an unrecognised listing failure must stay could-not-observe, got $RP_RC"
  [ "$(field "$out" .reason_code)" = NM_CENSUS_INCOMPLETE ] \
    || fail "an unrecognised listing failure must report NM_CENSUS_INCOMPLETE: $out"
  pass "role-path: an uninitialized repository is an established absence, and any other failure still refuses"
}

test_the_census_is_not_consulted_where_no_mistakes_owns_nothing() {
  local rec dir repo home fakebin base head out
  rec=$(make_case census-not-applicable)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # Applicability is a real axis, not a convenience. A project whose delivery
  # never routes through the pipeline must not be refused on the strength of a
  # question that does not apply to it - and the product must SAY the census was
  # not applicable rather than leaving it looking covered.
  census_stub "$fakebin" "  running    feat ${head:0:8}  2026-01-01"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode direct-PR \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 0 ] || fail "a non-pipeline delivery must not be refused on the run census, got $RP_RC"
  [ "$(field "$out" '.generation.no_mistakes_census_digest')" = not-applicable ] \
    || fail "an inapplicable census must be recorded as not-applicable, never as covered: $out"
  pass "role-path: the run census is consulted only where no-mistakes owns mutation"
}

test_unreadable_worktree_custody_is_could_not_observe() {
  local rec dir repo home fakebin base head out
  rec=$(make_case worktree-unreadable)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes --worktree "$dir/no-such-worktree" \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 4 ] || fail "unreadable custody must be could-not-observe (exit 4), got $RP_RC"
  case "$(field "$out" .reason_code)" in
    WORKTREE_UNOBSERVED|TREEHOUSE_CUSTODY_AMBIGUOUS) ;;
    *) fail "unreadable worktree custody must report an unobserved-custody code: $out" ;;
  esac
  [ "$(field "$out" .reservation)" = null ] || fail "CNO must name no reservation: $out"
  pass "role-path: worktree custody that cannot be read is could-not-observe, not free"
}

test_a_worktree_another_task_holds_is_refused() {
  local rec dir repo home fakebin base head wt out
  rec=$(make_case worktree-other-owner)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  wt="$dir/slot"
  git -C "$repo" worktree add --quiet -b slot-branch "$wt"
  # Another task's live claim on this slot. Whose it is settles before what
  # state it is in: a provider refusing THIS dispatch says nothing about that
  # lane's work, and no lane is ever taken from another.
  cat > "$home/state/other-task.meta" <<META
worktree=$wt
worktree_owner_pid=$$
worktree_owner_identity=fixture
META
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes --task mine --worktree "$wt" \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -ne 0 ] || fail "a slot another task holds must never be PERMITTED"
  [ "$(field "$out" .reservation)" = null ] || fail "a contested slot must name no reservation: $out"
  pass "role-path: a worktree another task holds is never this dispatch's to take"
}

test_a_stale_execution_claim_is_refused() {
  local rec dir repo home fakebin base head out
  rec=$(make_case stale-execution)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # This dispatch claims to succeed an execution the lane does not have open.
  # Only the execution a gate sanctioned may be succeeded; anything else would
  # rebind a lane from a command line.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes --task lane-1 --succeeds-execution exec-does-not-exist \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "a stale execution claim must be REFUSED, got $RP_RC"
  [ "$(field "$out" .reason_code)" = STALE_EXECUTION ] \
    || fail "succeeding an execution the lane does not hold must report STALE_EXECUTION: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "REFUSED must name no reservation: $out"
  pass "role-path: succeeding an execution the lane never opened is STALE_EXECUTION"
}

test_two_live_owners_refuse_as_duplicate_rather_than_picking_one() {
  local rec dir repo home fakebin base head out
  rec=$(make_case duplicate-owner)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # TWO genuinely live owners: two pipeline runs both live on this candidate.
  # Two live owners is not a harder version of one; it is the state in which no
  # single identity can be given the right to mutate, so it must refuse rather
  # than choose between them.
  #
  # A lane's own open execution is deliberately NOT one of these. It is that
  # lane rather than a rival claim on it, and counting it would make every
  # relaunch after a lost runtime look like a collision.
  FM_HOME="$home" "$ROOT/bin/fm-attempt.sh" open lane-dup >/dev/null 2>&1 \
    || fail "fixture could not open an execution for the lane"
  census_stub "$fakebin" "  running    feat ${head:0:8}  2026-01-01
  fixing    feat ${head:0:8}  2026-01-02"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes --task lane-dup \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "two live owners must be REFUSED, got $RP_RC"
  [ "$(field "$out" .reason_code)" = DUPLICATE_MUTATION_OWNER ] \
    || fail "more than one live owner must report DUPLICATE_MUTATION_OWNER: $out"
  [ "$(field "$out" '.custody.live_owner_count | . > 1')" = true ] \
    || fail "the product must record that more than one live owner was found: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "REFUSED must name no reservation: $out"
  # NEGATIVE CONTROL on the same fixture: with one run finished, a single live
  # owner remains and the verdict is about THAT owner rather than a duplicate,
  # so the count is doing real work here. The lane's own open execution is still
  # present throughout, which is what proves it is not being counted.
  census_stub "$fakebin" "  running    feat ${head:0:8}  2026-01-01
  completed    feat ${head:0:8}  2026-01-02"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes --task lane-dup \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$(field "$out" '.custody.live_owner_count')" = 1 ] \
    || fail "removing one live owner must leave exactly one: $out"
  pass "role-path: two live owners refuse as DUPLICATE_MUTATION_OWNER rather than picking one"
}

# --- precedence -------------------------------------------------------------

test_an_established_violation_outranks_an_unread_axis() {
  local rec dir repo home fakebin base head out
  rec=$(make_case precedence)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # One axis cannot be read (a truncated census) and another is an established
  # violation (the maker reviewing itself). Property-local FAIL > CNO > PASS
  # means the REFUSAL is what gets reported: an established violation is a
  # stronger fact than an unread one, and reporting the unread one would make
  # this look like a repair job rather than a refusal.
  census_stub "$fakebin" "  completed    other 1111aaaa  2026-01-01
  (9 more runs, use --limit to see more)"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|claude/opus|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 1 ] || fail "an established violation must outrank an unread axis, got $RP_RC"
  [ "$(field "$out" .verdict)" = REFUSED ] || fail "verdict must be REFUSED: $out"
  [ "$(field "$out" .reason_code)" = ASSIGNMENT_NOT_DISTINCT ] \
    || fail "FAIL must outrank CNO in the reported reason: $out"
  pass "role-path: FAIL outranks CNO, so an established violation is what gets reported"
}

test_an_unresolved_base_refuses_only_where_it_was_required() {
  local rec dir repo home fakebin base head out
  rec=$(make_case base-requirement)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir" "$base"
  # bin/fm-task-base-lib.sh already rules on an unresolvable base: it reports
  # `unresolved` and the dispatch proceeds on a warning. This product records
  # that truth but does not overturn it, because one input with two rulings is
  # decided by whichever happens to run last rather than by anyone choosing.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --require maker --require checker \
    --work W1 --repository "$repo" --branch feat --candidate-head "$head" --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 0 ] || fail "an unresolved base must not refuse a caller that did not require one, got $RP_RC"
  [ "$(field "$out" '.work.base')" = "" ] \
    || fail "the product must record the base it actually had: $out"
  # A caller that genuinely needs a resolved base asks for one, and then the
  # same request refuses. Without this half the requirement would be decorative.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json \
    --require maker --require checker --require base \
    --work W1 --repository "$repo" --branch feat --candidate-head "$head" --mode no-mistakes \
    --role "maker|claude/opus|$repo:feat" --role "checker|codex/gpt|$repo:feat" 2>/dev/null) \
    && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 4 ] || fail "a caller requiring a resolved base must get could-not-observe, got $RP_RC"
  [ "$(field "$out" .reason_code)" = INCOMPLETE_WORK_IDENTITY ] \
    || fail "a missing required base must report INCOMPLETE_WORK_IDENTITY: $out"
  [ "$(field "$out" .reservation)" = null ] || fail "CNO must name no reservation: $out"
  pass "role-path: an unresolved base is recorded always and refuses only where the caller required one"
}

test_a_product_that_required_no_role_says_so() {
  local rec dir repo home fakebin base head out
  rec=$(make_case require-none)
  IFS='|' read -r dir repo home fakebin base head <<EOF
$rec
EOF
  : "$dir"
  # A caller may ask only the custody question. What it must never be able to do
  # is get an answer that LOOKS like a covered role path. The required set is
  # recorded, so a product that required nothing cannot be read as having
  # established one.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROUTE" role-path --json --require-none \
    --work W1 --repository "$repo" --branch feat --base "$base" --candidate-head "$head" \
    --mode no-mistakes 2>/dev/null) && RP_RC=0 || RP_RC=$?
  [ "$RP_RC" -eq 0 ] || fail "the custody-only question must be answerable, got $RP_RC"
  [ "$(field "$out" '.required_roles | length')" = 0 ] \
    || fail "a custody-only product must record that it required no role: $out"
  [ "$(field "$out" '.role_path | length')" = 0 ] \
    || fail "a custody-only product must carry no role path: $out"
  pass "role-path: a product that required no role records that, so it cannot read as a covered path"
}

# --- the spawn chokepoint ---------------------------------------------------
#
# The read interface answers the question; the chokepoint is what makes the
# answer bind. These cases drive bin/fm-spawn.sh itself, so what is asserted is
# the state of the world after a refusal rather than a library return value.

make_spawn_case() {  # <name> -> "<home>|<proj>|<wt>|<fakebin>"
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  census_stub "$fakebin" ''
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s' "$home" "$proj" "$wt" "$fakebin"
}

write_spawn_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  printf 'brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$2" > "$1/data/$2/brief.md"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$wt" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_records_the_preflight_it_was_admitted_against() {
  local rec home proj wt fakebin id out meta
  rec=$(make_spawn_case spawn-records)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  id=spawn-records-a1
  write_spawn_brief "$home" "$id"
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --reason-code CONTRACT_SCOPE_JUDGMENT) || true
  meta="$home/state/$id.meta"
  [ -f "$meta" ] || fail "the spawn must have published metadata: $out"
  # A dispatch that was never preflighted and one that passed a preflight are
  # different facts. Recording it even on PERMITTED is what keeps an absent
  # field from reading as the second.
  [ "$(sed -n 's/^role_path_verdict=//p' "$meta" | tail -1)" = PERMITTED ] \
    || fail "the admitted preflight verdict must be recorded on the task: $(cat "$meta")"
  [ -n "$(sed -n 's/^mutation_owner=//p' "$meta" | tail -1)" ] \
    || fail "the singular mutation owner must be recorded on the task: $(cat "$meta")"
  pass "fm-spawn: the preflight a dispatch was admitted against is durably recorded"
}

test_spawn_refuses_a_participant_owned_candidate_with_zero_side_effects() {
  local rec home proj wt fakebin id out before after rc
  rec=$(make_spawn_case spawn-refuses)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  id=spawn-refuses-a1
  write_spawn_brief "$home" "$id"
  # A live pipeline run already owns this task's branch.
  census_stub "$fakebin" "  running    fm/$id 1111aaaa  2026-01-01"
  before=$(effect_snapshot "$home" "$proj")
  rc=0
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --reason-code CONTRACT_SCOPE_JUDGMENT) || rc=$?
  [ "$rc" -ne 0 ] || fail "a candidate a live run owns must not be dispatched: $out"
  assert_contains "$out" "PARTICIPANT_OWNS_MUTATION" "the refusal must name the axis that stopped it"
  # THE POINT OF THE WHOLE PRODUCT: the refusal left nothing behind. No task
  # metadata, no branch, no worktree change, no pool slot, no worker.
  assert_absent "$home/state/$id.meta" "a refused dispatch must publish no task metadata"
  after=$(effect_snapshot "$home" "$proj")
  [ "$before" = "$after" ] \
    || fail "a refused dispatch changed the effect surface:"$'\n'"--- before"$'\n'"$before"$'\n'"--- after"$'\n'"$after"
  pass "fm-spawn: a refused dispatch allocates nothing - metadata, branch, worktree and slot are untouched"
}

test_spawn_refusal_is_not_caused_merely_by_the_gate_existing() {
  local rec home proj wt fakebin id out rc
  rec=$(make_spawn_case spawn-nonvacuous)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  id=spawn-nonvacuous-a1
  write_spawn_brief "$home" "$id"
  # NEGATIVE CONTROL for the case above, on the SAME fixture shape: with the
  # live run removed and nothing else changed, the identical dispatch proceeds.
  # Without this, a gate that refused everything would pass that test.
  census_stub "$fakebin" "  completed    fm/$id 1111aaaa  2026-01-01"
  rc=0
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --reason-code CONTRACT_SCOPE_JUDGMENT) || rc=$?
  [ "$rc" -eq 0 ] || fail "the same dispatch must proceed once no live run owns the candidate: $out"
  assert_present "$home/state/$id.meta" "the permitted dispatch must publish task metadata"
  pass "fm-spawn: the gate discriminates - the same dispatch proceeds when no live owner holds the candidate"
}

test_a_waiver_covers_only_the_axis_it_names() {
  local rec home proj wt fakebin id out rc meta
  rec=$(make_spawn_case spawn-waiver)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  id=spawn-waiver-a1
  write_spawn_brief "$home" "$id"
  census_stub "$fakebin" "  running    fm/$id 1111aaaa  2026-01-01"
  # Waiving a DIFFERENT axis must not clear this one. A waiver that opened the
  # gate rather than one named axis would be a standing bypass.
  rc=0
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --reason-code CONTRACT_SCOPE_JUDGMENT \
        --allow-unpreflighted NM_CENSUS_INCOMPLETE) || rc=$?
  [ "$rc" -ne 0 ] || fail "waiving another axis must not clear PARTICIPANT_OWNS_MUTATION: $out"
  assert_absent "$home/state/$id.meta" "a refusal that was not waived must still allocate nothing"
  # Waiving the axis that actually stopped it does proceed, and says so on the task.
  rc=0
  out=$(run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --reason-code CONTRACT_SCOPE_JUDGMENT \
        --allow-unpreflighted PARTICIPANT_OWNS_MUTATION) || rc=$?
  [ "$rc" -eq 0 ] || fail "waiving the axis that stopped it must proceed: $out"
  meta="$home/state/$id.meta"
  [ "$(sed -n 's/^role_path_waived=//p' "$meta" | tail -1)" = PARTICIPANT_OWNS_MUTATION ] \
    || fail "an allocation on a waived axis must be written down by name: $(cat "$meta")"
  pass "fm-spawn: a waiver clears exactly the axis it names and is recorded on the task"
}

test_the_decision_surface_reads_the_recorded_preflight() {
  local rec home proj wt fakebin id out rc
  rec=$(make_spawn_case surface-read)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  id=surface-read-a1
  write_spawn_brief "$home" "$id"
  run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --reason-code CONTRACT_SCOPE_JUDGMENT >/dev/null 2>&1 || true
  rc=0
  out=$(FM_HOME="$home" "$SURFACE" check role-path "$id" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a PERMITTED allocation must not be contradicted by the surface (exit $rc): $out"
  # A task with no record at all must be UNEVALUABLE, never a quiet pass: an
  # absent preflight is not a passed one.
  rc=0
  out=$(FM_HOME="$home" "$SURFACE" check role-path never-dispatched 2>&1) || rc=$?
  [ "$rc" -eq 4 ] || fail "an unpreflighted identity must be unevaluable (exit 4), got $rc: $out"
  pass "fm-decision-surface: check role-path reads the recorded preflight and refuses to guess"
}

test_complete_eligible_product_is_permitted_and_names_one_reservation
test_a_permitted_product_still_allocates_nothing_by_itself
test_omitted_maker_is_could_not_observe_not_a_pass
test_omitted_checker_is_could_not_observe_not_a_pass
test_maker_and_checker_collapsing_to_one_assignment_is_refused
test_a_role_outside_the_governed_path_is_refused
test_a_declared_contract_that_cannot_be_read_is_could_not_observe
test_an_unqualified_binding_may_not_take_the_assignment
test_a_candidate_that_moved_under_the_decision_is_refused
test_the_same_product_is_permitted_at_the_head_it_was_computed_for
test_a_live_no_mistakes_run_owning_the_branch_is_refused
test_a_terminal_run_on_the_same_branch_does_not_own_it
test_an_unrecognised_run_status_is_treated_as_live
test_an_incomplete_census_is_could_not_observe
test_a_tool_refusal_that_exits_zero_is_not_an_empty_census
test_an_uninitialized_repository_is_an_established_absence_not_an_unread_one
test_the_census_is_not_consulted_where_no_mistakes_owns_nothing
test_unreadable_worktree_custody_is_could_not_observe
test_a_worktree_another_task_holds_is_refused
test_a_stale_execution_claim_is_refused
test_two_live_owners_refuse_as_duplicate_rather_than_picking_one
test_an_established_violation_outranks_an_unread_axis
test_an_unresolved_base_refuses_only_where_it_was_required
test_a_product_that_required_no_role_says_so
test_spawn_records_the_preflight_it_was_admitted_against
test_spawn_refuses_a_participant_owned_candidate_with_zero_side_effects
test_spawn_refusal_is_not_caused_merely_by_the_gate_existing
test_a_waiver_covers_only_the_axis_it_names
test_the_decision_surface_reads_the_recorded_preflight

fm_test_contract "${BASH_SOURCE[0]}"
