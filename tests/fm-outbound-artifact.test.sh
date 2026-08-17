#!/usr/bin/env bash
# Behavior tests for bin/fm-outbound-artifact.sh - the OUTBOUND transport
# invariant: an item may not remain in a state implying an outstanding outbound
# artifact while no applicable durable artifact exists.
#
# WATCHED-RED DISCIPLINE. Every control here is driven to RED first, for its
# intended reason, and only then to green from the opposite structured state. A
# control that only ever answers one way enforces nothing, and this fleet has
# already shipped a probe that failed unconditionally while measuring nothing.
# So each case asserts BOTH the red verdict AND its specific token, because a red
# reached for the wrong reason is not the control anyone thought they had.
#
# The seven controls the task contract names, each paired here with its negative:
#   1. review-required with no control request goes RED
#   2. an exact head change makes the previous request inapplicable
#   3. one scheduler cycle cannot create duplicate requests
#   4. a transient forge failure retries without losing the request
#   5. a ruling wakes the exact waiting item
#   6. an UNRELATED ruling cannot wake that item
#   7. disposition and closure complete the correlation
#
# The forge is a PATH shim, so every case drives the real code path - the real
# identity digest, the real record writes, the real retry loop - and only the
# network is fake. Fleet state is a canned fm-fleet-snapshot.v1 document through
# FM_OUTBOUND_SNAPSHOT, so no case depends on a live fleet or a spawned worker.
# A behavior control cannot prove that a future read bypasses the observed path.
# The class-level control therefore covers every injectable read boundary owned by this path, while review remains responsible for detecting a newly added boundary.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-outbound-artifact-tests)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

OB="$ROOT/bin/fm-outbound-artifact.sh"

# --- fixtures ---------------------------------------------------------------

# Real commit ids from a real repository, not invented hex.
#
# An exact head's WIDTH comes from the target repository's object format and the
# value must resolve there, so a fixture with no clone has an undeterminable
# width and every head is refused. Inventing 1111... and pointing at no
# repository tested a rule that no longer exists. These are seeded once from an
# actual sha1 repository and reused by every case.
HEAD_REPO="$TMP_ROOT/head-source"
seed_head_repo() {
  mkdir -p "$HEAD_REPO"
  git -C "$HEAD_REPO" init -q
  git -C "$HEAD_REPO" config user.email fixture@example.com
  git -C "$HEAD_REPO" config user.name Fixture
  printf 'a\n' > "$HEAD_REPO/f"
  git -C "$HEAD_REPO" add f
  git -C "$HEAD_REPO" -c commit.gpgsign=false commit -qm a
  HEAD_A=$(git -C "$HEAD_REPO" rev-parse HEAD)
  printf 'b\n' > "$HEAD_REPO/f"
  git -C "$HEAD_REPO" add f
  git -C "$HEAD_REPO" -c commit.gpgsign=false commit -qm b
  HEAD_B=$(git -C "$HEAD_REPO" rev-parse HEAD)
}
seed_head_repo
[ -n "${HEAD_A:-}" ] && [ -n "${HEAD_B:-}" ] && [ "$HEAD_A" != "$HEAD_B" ] \
  || { printf 'not ok - fixture repository produced no distinct heads\n' >&2; exit 1; }

make_home() {  # <name> -> prints home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/config" "$home/state" "$home/projects"
  : > "$home/data/projects.md"
  printf '%s\n' "$home"
}

# One item at a Browser Sol review gate with a pull request, and one ordinary
# queued row that must never be flagged. The ordinary row is the fixture's own
# negative control: a sweep that flags everything is as useless as one that
# flags nothing.
write_snapshot() {  # <path> [<hold-kind>] [<hold-reason>]
  local path=$1
  local kind=${2:-external}
  local reason=${3:-SUBMITTED FOR INDEPENDENT REVIEW as SOL-FM-X-001}
  jq -n --arg kind "$kind" --arg reason "$reason" '
    {schema:"fm-fleet-snapshot.v1",
     backlog:{present:true,records:[
       {order:1,state:"queued",structured:true,id:"waiting-item",
        title:"needs independent review",hold_kind:$kind,hold_reason:$reason,
        repo:"demo",pr_url:"https://github.com/o/r/pull/4",body_excerpt:null},
       {order:2,state:"queued",structured:true,id:"ordinary-item",
        title:"ordinary queued work",hold_kind:null,hold_reason:null,
        repo:"demo",pr_url:null,body_excerpt:null}]}}' > "$path"
}

configure_venue() {  # <home>
  printf '{"repo":"o/control","issue":2}\n' > "$1/config/sol-control.json"
}

declare_gate() {  # <home> <gate>
  mkdir -p "$1/data/waiting-item"
  jq -n --arg gate "$2" --arg head "$HEAD_A" '{gate:$gate,head:$head}' \
    > "$1/data/waiting-item/outbound-gate.json"
}

# The forge shim. Behavior is driven entirely by files in its own state dir, so a
# case can change what the forge does between two invocations of the command
# under test - which is what makes the retry and crash-recovery cases real.
#
#   head            the sha reported for pull request 4
#   comments        one "<id> <body-substring>" per line, the issue's comments
#   fail_remaining  N post attempts fail before any succeed
#   post_log        appended once per POST that the shim accepted
make_gh() {  # <dir>
  mkdir -p "$1/bin" "$1/forge"
  printf '%s\n' "$HEAD_A" > "$1/forge/head"
  : > "$1/forge/comments"
  printf '0\n' > "$1/forge/fail_remaining"
  : > "$1/forge/post_log"
  : > "$1/forge/last_request_body"
  : > "$1/forge/ruling_body"
  : > "$1/forge/ruling_id"
  : > "$1/forge/foreign_ruling_body"
  : > "$1/forge/foreign_ruling_id"
  : > "$1/forge/poll_prefix"
  printf '0\n' > "$1/forge/lose_response_remaining"
  cat > "$1/bin/gh" <<'SH'
#!/usr/bin/env bash
# Minimal gh api shim: pull request head reads, issue comment listing, and
# comment creation with a scripted failure budget.
F="$FORGE_DIR"
path=
for a in "$@"; do case $a in repos/*) path=$a ;; esac; done
is_post=0
case " $* " in *" --input "*) is_post=1 ;; esac

case "$path" in
  */pulls/4|*/pulls/5)
    cat "$F/head"; exit 0 ;;
  */issues/comments/*)
    id=${path##*/}
    if [ -s "$F/foreign_ruling_id" ] && [ "$id" = "$(cat "$F/foreign_ruling_id")" ]; then
      body_file="$F/foreign_ruling_body"
    elif [ -s "$F/ruling_id" ] && [ "$id" = "$(cat "$F/ruling_id")" ]; then
      body_file="$F/ruling_body"
    else
      body_file="$F/last_request_body"
    fi
    jq -n --argjson id "$id" --arg issue "${RULING_ISSUE:-2}" \
      --rawfile body "$body_file" \
      '{id:$id,issue_url:("https://api.github.com/repos/o/control/issues/"+$issue),body:$body}'
    exit 0 ;;
  */commits/*/pulls)
    query=
    prev=
    for a in "$@"; do
      case $prev in --jq) query=$a ;; esac
      prev=$a
    done
    current=$(cat "$F/pr_head" 2>/dev/null || true)
    case $query in
      *".head.sha == \"$current\""*) cat "$F/pr_number" 2>/dev/null || true ;;
    esac
    exit 0 ;;
  */issues/*/comments)
    if [ "$is_post" = 1 ]; then
      payload=$(cat)
      body=$(printf '%s' "$payload" | jq -r '.body')
      left=$(cat "$F/fail_remaining" 2>/dev/null || echo 0)
      if [ "$left" -gt 0 ]; then
        printf '%s\n' "$((left - 1))" > "$F/fail_remaining"
        echo "simulated transport failure" >&2
        exit 1
      fi
      rid=$(printf '%s' "$body" | sed -n 's/.*\(fm-ob-[0-9a-f]*\).*/\1/p' | head -1)
      id=$(( $(wc -l < "$F/comments") + 900 ))
      printf '%s %s\n' "$id" "$rid" >> "$F/comments"
      printf '%s\n' "$body" > "$F/last_request_body"
      printf '%s\n' "$body" > "$F/comment-$id.body"
      printf 'posted %s\n' "$rid" >> "$F/post_log"
      lost=$(cat "$F/lose_response_remaining")
      if [ "$lost" -gt 0 ]; then
        printf '%s\n' "$((lost - 1))" > "$F/lose_response_remaining"
        exit 1
      fi
      printf '{"id":%s}\n' "$id"
      exit 0
    fi
    # Listing: --jq carries a contains("<rid>") filter; honour it literally.
    want=
    prev=
    for a in "$@"; do
      case $prev in --jq) want=$(printf '%s' "$a" | sed -n 's/.*contains("\([^"]*\)").*/\1/p') ;; esac
      prev=$a
    done
    if printf '%s' "$*" | grep -q '@base64'; then
      cat "$F/poll_prefix"
      while read -r id rid; do
        [ -n "$id" ] || continue
        body_file="$F/comment-$id.body"
        [ -f "$body_file" ] || body_file="$F/last_request_body"
        jq -nr --argjson id "$id" --rawfile body "$body_file" \
          '[$id,$body] | @base64'
      done < "$F/comments"
      if [ -s "$F/foreign_ruling_id" ]; then
        jq -nr --argjson id "$(cat "$F/foreign_ruling_id")" \
          --rawfile body "$F/foreign_ruling_body" '[$id,$body] | @base64'
      fi
      if [ -s "$F/ruling_id" ]; then
        jq -nr --argjson id "$(cat "$F/ruling_id")" --rawfile body "$F/ruling_body" \
          '[$id,$body] | @base64'
      fi
      exit 0
    fi
    while read -r id rid; do
      [ -n "$id" ] || continue
      if [ -z "$want" ] || [ "$rid" = "$want" ]; then printf '%s\n' "$id"; fi
    done < "$F/comments"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/bin/gh"
}

write_ruling() {  # <case-dir> <request-id> <comment-id> [<verdict>]
  local dir=$1 rid=$2 comment=$3 verdict=${4:-approved}
  sed "1s/^.*$/FM-SOL-RULING $rid/" "$dir/forge/last_request_body" \
    > "$dir/forge/ruling_body"
  printf 'verdict: %s\n' "$verdict" >> "$dir/forge/ruling_body"
  printf '%s\n' "$comment" > "$dir/forge/ruling_id"
}

write_foreign_ruling() {  # <case-dir> <request-id> <comment-id>
  local dir=$1 rid=$2 comment=$3
  sed "1s/^.*$/FM-SOL-RULING $rid/" "$dir/forge/last_request_body" \
    > "$dir/forge/foreign_ruling_body"
  printf 'verdict: rejected\n' >> "$dir/forge/foreign_ruling_body"
  printf '%s\n' "$comment" > "$dir/forge/foreign_ruling_id"
}

# Run the command under test against one case directory.
run_ob() {  # <case-dir> <args...>
  local dir=$1; shift
  PATH="$dir/bin:$PATH" FORGE_DIR="$dir/forge" \
    FM_HOME="$dir/home" FM_OUTBOUND_SNAPSHOT="$dir/snap.json" \
    FM_OUTBOUND_BACKOFF_BASE=0 REAL_GIT="$(command -v git)" \
    "$OB" "$@"
}

install_inventory_git_fault() {  # <case-dir> <fault>
  printf '%s\n' "$2" > "$1/forge/git_fault"
  cat > "$1/bin/git" <<'SH'
#!/usr/bin/env bash
fault=$(cat "$FORGE_DIR/git_fault")
case "$fault:$*" in
  for-each-ref:*for-each-ref*) exit 128 ;;
  ref-head:*rev-parse*refs/heads/fm/faulty*) exit 128 ;;
  object-width:*rev-parse*--show-object-format*) exit 128 ;;
  default-branch:*symbolic-ref*refs/remotes/origin/HEAD*) exit 128 ;;
  default-branch:*rev-parse*refs/heads/main*|default-branch:*rev-parse*refs/remotes/origin/main*|default-branch:*rev-parse*refs/heads/master*|default-branch:*rev-parse*refs/remotes/origin/master*) exit 128 ;;
  candidate-refs:*rev-parse*refs/heads/main) exit 128 ;;
esac
exec "$REAL_GIT" "$@"
SH
  chmod +x "$1/bin/git"
}

prepare_inventory_fault_case() {  # <name>
  local dir repo
  dir=$(new_case "$1")
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n' > "$dir/home/data/projects.md"
  repo="$dir/home/projects/demo"
  git -C "$repo" branch fm/faulty
  git -C "$repo" branch -M main
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/heads/main
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[]}}' > "$dir/snap.json"
  printf '%s\n' "$dir"
}

new_case() {  # <name> -> prints case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  make_gh "$dir"
  make_home "$1/home" >/dev/null
  # The project clone the heads resolve against. Cloned rather than re-created so
  # every case sees the same object ids.
  git clone -q --no-hardlinks "$HEAD_REPO" "$dir/home/projects/demo" 2>/dev/null
  configure_venue "$dir/home"
  write_snapshot "$dir/snap.json"
  printf '%s\n' "$dir"
}

set_head() { printf '%s\n' "$2" > "$1/forge/head"; }

# --- control 1: waiting with no request goes RED ----------------------------

test_branch_inventory_finds_an_unannotated_unsubmitted_branch() {
  local dir repo out rc
  # THE ANCHOR CONTROL. This is the experiment that exposed the vacuity, so it is
  # the one that proves the fix: a branch carrying real unsubmitted work whose
  # backlog row says NOTHING about it. Before the inventory the sweep reported
  # 0 defects and exit 0 here, because it could only ever report what a person
  # had already annotated - a statement about the backlog rather than the fleet.
  dir=$(new_case cinventory)
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n' > "$dir/home/data/projects.md"
  repo="$dir/home/projects/demo"
  rm -rf "$repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name Fixture
  printf 'base\n' > "$repo/f"; git -C "$repo" add f
  git -C "$repo" -c commit.gpgsign=false commit -qm base
  git -C "$repo" branch -M main
  git -C "$repo" remote add origin https://github.com/o/demo.git
  git -C "$repo" checkout -q -b fm/never-submitted
  printf 'work\n' > "$repo/f"; git -C "$repo" add f
  git -C "$repo" -c commit.gpgsign=false commit -qm 'finished work nobody submitted'
  git -C "$repo" checkout -q main
  # A row with no hold, no annotation, nothing to recognise from prose.
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[
    {order:1,state:"queued",structured:true,id:"never-submitted",title:"ordinary queued work",
     hold_kind:null,hold_reason:null,repo:"demo",pr_url:null,body_excerpt:null,
     raw:"- [ ] never-submitted - ordinary queued work (repo: demo)"}]}}' > "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "inventory: an unannotated unsubmitted branch was not found, exit $rc: $out"
  printf '%s' "$out" | grep -q 'never-submitted' \
    || fail "inventory: the branch was not named: $out"
  printf '%s' "$out" | grep -q 'recognised: inventory' \
    || fail "inventory: found by annotation rather than by enumeration: $out"
  pass "inventory: a branch nobody annotated is found by enumeration, not by prose"
}

test_branch_inventory_excludes_landed_work() {
  local dir repo out rc
  # The negative control. Landed work is not unsubmitted work, and without this
  # the inventory would report every merged branch forever and be switched off.
  dir=$(new_case cinvlanded)
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n' > "$dir/home/data/projects.md"
  repo="$dir/home/projects/demo"
  rm -rf "$repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name Fixture
  printf 'base\n' > "$repo/f"; git -C "$repo" add f
  git -C "$repo" -c commit.gpgsign=false commit -qm base
  git -C "$repo" branch -M main
  git -C "$repo" remote add origin https://github.com/o/demo.git
  # the branch points at a commit main already contains
  git -C "$repo" branch fm/already-landed main
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[]}}' > "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  printf '%s' "$out" | grep -q 'already-landed' \
    && fail "inventory: landed work was reported as unsubmitted: $out"
  [ "$rc" -eq 0 ] || fail "inventory: a clean landed-only clone did not pass, exit $rc: $out"
  pass "inventory: a branch already contained in the landing target is not unsubmitted work"
}

test_branch_inventory_excludes_squash_landed_work() {
  local dir repo out rc
  dir=$(new_case cinvsquash)
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n' > "$dir/home/data/projects.md"
  repo="$dir/home/projects/demo"
  rm -rf "$repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name Fixture
  printf 'base\n' > "$repo/f"; git -C "$repo" add f
  git -C "$repo" -c commit.gpgsign=false commit -qm base
  git -C "$repo" branch -M main
  git -C "$repo" remote add origin https://github.com/o/demo.git
  git -C "$repo" checkout -q -b fm/squash-landed
  printf 'landed content\n' > "$repo/f"; git -C "$repo" add f
  git -C "$repo" -c commit.gpgsign=false commit -qm work
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --squash fm/squash-landed
  git -C "$repo" -c commit.gpgsign=false commit -qm 'squash landed work'
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[]}}' > "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  printf '%s' "$out" | grep -q 'squash-landed' \
    && fail "inventory squash landing: landed content was reported: $out"
  [ "$rc" -eq 0 ] || fail "inventory squash landing: expected clean exit, got $rc: $out"
  pass "inventory squash landing: content containment excludes a squash-merged branch"
}

test_branch_inventory_unresolvable_landing_target_is_unevaluable() {
  local dir repo out rc
  dir=$(new_case cinvtarget)
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n' > "$dir/home/data/projects.md"
  repo="$dir/home/projects/demo"
  rm -rf "$repo"; mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name Fixture
  printf 'work\n' > "$repo/f"; git -C "$repo" add f
  git -C "$repo" -c commit.gpgsign=false commit -qm work
  git -C "$repo" branch -M fm/no-landing-target
  git -C "$repo" remote add origin https://github.com/o/demo.git
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[]}}' > "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "inventory landing target: expected unevaluable, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_LANDING_TARGET_UNOBSERVED' \
    || fail "inventory landing target: observation gap was collapsed: $out"
  pass "inventory landing target: an unresolvable target is could-not-observe"
}

test_branch_inventory_absent_registry_is_unevaluable() {
  local dir out rc
  dir=$(new_case cinvregistry)
  rm "$dir/home/data/projects.md"
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[]}}' > "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "inventory registry: expected unevaluable, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_PROJECT_REGISTRY_UNREADABLE' \
    || fail "inventory registry: absent inventory looked empty: $out"
  pass "inventory registry: an absent registry is not an empty inventory"
}

test_branch_inventory_failing_ref_enumeration_is_unevaluable() {
  local dir out rc
  dir=$(prepare_inventory_fault_case cinvrefs)
  install_inventory_git_fault "$dir" for-each-ref
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "inventory refs: expected unevaluable, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_REFS_UNOBSERVED' \
    || fail "inventory refs: failed enumeration looked empty: $out"
  pass "inventory refs: a failing for-each-ref is could-not-observe"
}

test_branch_inventory_failing_head_reads_are_unevaluable() {
  local fault dir out rc
  for fault in ref-head object-width; do
    dir=$(prepare_inventory_fault_case "cinv-$fault")
    install_inventory_git_fault "$dir" "$fault"
    out=$(run_ob "$dir" check 2>&1); rc=$?
    [ "$rc" -eq 4 ] || fail "inventory $fault: expected unevaluable, got $rc: $out"
    printf '%s' "$out" | grep -q 'FM_OUTBOUND_REF_UNOBSERVED' \
      || fail "inventory $fault: failed head read was skipped: $out"
  done
  pass "inventory head: failing ref and object-width reads are could-not-observe"
}

test_branch_inventory_unreadable_posture_is_unevaluable() {
  local dir out rc
  dir=$(prepare_inventory_fault_case cinvposture)
  cat > "$dir/bin/project-mode-fail" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/bin/project-mode-fail"
  out=$(FM_OUTBOUND_PROJECT_MODE_COMMAND="$dir/bin/project-mode-fail" run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "inventory posture: expected unevaluable, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_PROJECT_POSTURE_UNOBSERVED' \
    || fail "inventory posture: failed posture read became permissive: $out"
  pass "inventory posture: an unreadable project mode is could-not-observe"
}

test_branch_inventory_failing_default_branch_read_is_unevaluable() {
  local dir out rc
  dir=$(prepare_inventory_fault_case cinvdefault)
  install_inventory_git_fault "$dir" default-branch
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "inventory default branch: expected unevaluable, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_LANDING_TARGET_UNOBSERVED' \
    || fail "inventory default branch: read failure became not-landed: $out"
  pass "inventory default branch: a failed name read is could-not-observe"
}

test_branch_inventory_failing_candidate_refs_is_unevaluable() {
  local dir out rc
  dir=$(prepare_inventory_fault_case cinvcandidates)
  install_inventory_git_fault "$dir" candidate-refs
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "inventory candidate refs: expected unevaluable, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_LANDING_TARGET_UNOBSERVED' \
    || fail "inventory candidate refs: read failure became an empty target list: $out"
  pass "inventory candidate refs: failed target enumeration is could-not-observe"
}

test_branch_inventory_read_failures_never_certify_empty() {
  local fault dir out rc
  for fault in for-each-ref ref-head object-width default-branch candidate-refs; do
    dir=$(prepare_inventory_fault_case "cinvclass-$fault")
    install_inventory_git_fault "$dir" "$fault"
    out=$(run_ob "$dir" check 2>&1); rc=$?
    [ "$rc" -eq 4 ] || fail "inventory read class: $fault certified empty at exit $rc: $out"
  done
  dir=$(prepare_inventory_fault_case cinvclass-posture)
  cat > "$dir/bin/project-mode-fail" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/bin/project-mode-fail"
  out=$(FM_OUTBOUND_PROJECT_MODE_COMMAND="$dir/bin/project-mode-fail" run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "inventory read class: posture certified empty at exit $rc: $out"
  pass "inventory read class: every owned read boundary fails closed"
}

test_no_request_is_red() {
  local dir out rc
  dir=$(new_case c1)
  # RED: the item is at a review gate and the forge holds no request for it.
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 1: expected defect exit 3, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "control 1: red for the wrong reason: $out"
  printf '%s' "$out" | grep -q 'waiting-item' \
    || fail "control 1: the waiting item was not named: $out"
  # The sweep must not flag the ordinary row - a control that flags everything
  # proves nothing about the one it was built for.
  printf '%s' "$out" | grep -q 'ordinary-item' \
    && fail "control 1: an ordinary queued row was flagged: $out"
  pass "control 1 RED: a review-required item with no request is a defect"
}

test_request_present_is_green() {
  local dir out rc
  dir=$(new_case c1n)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
    || fail "control 1 negative: emit failed"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "control 1 negative: expected 0 once requested, got $rc: $out"
  printf '%s' "$out" | grep -q '1 satisfied' \
    || fail "control 1 negative: not reported satisfied: $out"
  pass "control 1 GREEN: the same item with a request on the forge is satisfied"
}

test_request_presence_requires_exact_validated_identity() {
  local dir rid body posts

  dir=$(new_case presence-mention)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "presence identity: seed emit failed"
  rid=$(emitted_request_id "$dir")
  body=$(cat "$dir/forge/last_request_body")
  : > "$dir/forge/comments"
  rm -f "$dir/home/data/outbound-artifacts"/*.json
  printf '901 %s\n' "$rid" > "$dir/forge/comments"
  printf 'discussion merely mentions %s\n' "$rid" > "$dir/forge/comment-901.body"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "presence identity: mention blocked emission"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 2 ] || fail "presence identity: a mere mention satisfied presence"

  dir=$(new_case presence-prefix)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "presence identity: prefix seed emit failed"
  rid=$(emitted_request_id "$dir")
  body=$(cat "$dir/forge/last_request_body")
  : > "$dir/forge/comments"
  rm -f "$dir/home/data/outbound-artifacts"/*.json
  printf '902 %s-extra\n' "$rid" > "$dir/forge/comments"
  printf '%s\n' "$body" | sed "1s/$rid/$rid-extra/" > "$dir/forge/comment-902.body"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "presence identity: prefix blocked emission"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 2 ] \
    || fail "presence identity: a longer prefix-sharing id satisfied presence"

  dir=$(new_case presence-mismatch)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "presence identity: mismatch seed emit failed"
  rid=$(emitted_request_id "$dir")
  body=$(cat "$dir/forge/last_request_body")
  : > "$dir/forge/comments"
  rm -f "$dir/home/data/outbound-artifacts"/*.json
  printf '903 %s\n' "$rid" > "$dir/forge/comments"
  printf '%s\n' "$body" | sed 's/^item: waiting-item$/item: another-item/' > "$dir/forge/comment-903.body"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "presence identity: mismatch blocked emission"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 2 ] \
    || fail "presence identity: a mismatched embedded identity satisfied presence"

  dir=$(new_case presence-exact)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "presence identity: exact seed emit failed"
  rid=$(emitted_request_id "$dir")
  rm -f "$dir/home/data/outbound-artifacts"/*.json
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "presence identity: exact request was refused"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 1 ] \
    || fail "presence identity: an exact validated request was duplicated"
  pass "presence identity: exact marker and complete embedded identity are required"
}

# --- control 2: an exact head change invalidates the previous request --------

test_head_change_invalidates() {
  local dir out rc before
  dir=$(new_case c2)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 2: emit failed"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "control 2: precondition not green, got $rc: $out"
  before=$(cat "$dir/forge/comments")

  # The reviewed head moves. The old request still exists on the forge and is
  # untouched; it simply no longer describes this item.
  set_head "$dir" "$HEAD_B"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 2: a moved head did not go red, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_STALE_HEAD' \
    || fail "control 2: red for the wrong reason: $out"
  [ "$(cat "$dir/forge/comments")" = "$before" ] \
    || fail "control 2: the previous request was mutated rather than left inapplicable"
  pass "control 2 RED: a moved head makes the previous request inapplicable"
}

test_head_change_fresh_request_is_green() {
  local dir out rc first second
  dir=$(new_case c2n)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 2 negative: emit failed"
  first=$(awk '{print $2}' "$dir/forge/comments" | head -1)
  set_head "$dir" "$HEAD_B"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
    || fail "control 2 negative: fresh emit failed"
  second=$(awk '{print $2}' "$dir/forge/comments" | tail -1)
  [ "$first" != "$second" ] \
    || fail "control 2 negative: the new head reused the old request id ($first)"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "control 2 negative: fresh request not accepted, got $rc: $out"
  pass "control 2 GREEN: the moved head generates a fresh request with a new identity"
}

# --- control 3: one scheduler cycle cannot duplicate -------------------------

test_no_duplicate_requests() {
  local dir posts out
  dir=$(new_case c3)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 3: first emit failed"
  # Five further cycles at the same identity, exactly as a repeating scheduler
  # would produce.
  for _ in 1 2 3 4 5; do
    out=$(run_ob "$dir" emit waiting-item 2>&1) \
      || fail "control 3: repeat emit errored: $out"
    printf '%s' "$out" | grep -q 'already requested' \
      || fail "control 3: a repeat emit did not report the existing request: $out"
  done
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] || fail "control 3: $posts requests posted for one identity, expected 1"
  pass "control 3: six cycles at one identity posted exactly one request"
}

test_duplicate_control_can_fail() {
  local dir posts
  dir=$(new_case c3n)
  # The negative control for the DEDUPE MECHANISM itself: with the forge unable
  # to report existing comments, the mechanism has nothing to dedupe against and
  # a second post appears. Watching this go wrong is what proves the passing case
  # is the dedupe working rather than the shim never posting twice at all.
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 3 negative: emit failed"
  : > "$dir/forge/comments"          # the forge forgets the request
  rm -f "$dir/home/data/outbound-artifacts"/*.json
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 3 negative: emit failed"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 2 ] \
    || fail "control 3 negative: expected the un-dedupable case to post twice, got $posts"
  pass "control 3 NEGATIVE: with no observable prior request the same path does post again"
}

# --- control 4: transport failure retries without losing the request ---------

test_transient_failure_retries() {
  local dir out posts state
  dir=$(new_case c4)
  printf '2\n' > "$dir/forge/fail_remaining"   # two failures, then success
  out=$(run_ob "$dir" emit waiting-item 2>&1) \
    || fail "control 4: emit gave up on a transient failure: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] || fail "control 4: expected exactly one accepted post, got $posts"
  state=$(cat "$dir/home/data/outbound-artifacts"/*.json | jq -r '.state')
  [ "$state" = "emitted" ] || fail "control 4: record state is $state, expected emitted"
  pass "control 4 GREEN: two transient failures retried through to one request"
}

test_exhausted_transport_keeps_the_request() {
  local dir out rc attempts state
  dir=$(new_case c4n)
  # RED: every attempt fails. The request must NOT be lost, and the item must NOT
  # be reported as satisfied - the two ways this could quietly go wrong.
  printf '99\n' > "$dir/forge/fail_remaining"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "control 4 negative: expected unevaluable exit 4, got $rc: $out"
  printf '%s' "$out" | grep -q 'NOT lost' \
    || fail "control 4 negative: exhaustion did not report the checkpoint: $out"
  attempts=$(cat "$dir/home/data/outbound-artifacts"/*.json | jq -r '.attempts')
  [ "$attempts" -eq 3 ] || fail "control 4 negative: recorded $attempts attempts, expected 3"
  state=$(cat "$dir/home/data/outbound-artifacts"/*.json | jq -r '.state')
  [ "$state" = "emitting" ] \
    || fail "control 4 negative: a failed transport left state $state, not the emitting checkpoint"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 4 negative: item not still red after a failed emit, got $rc"
  pass "control 4 RED: an exhausted transport keeps the checkpoint and leaves the item red"
}

test_crash_recovery_adopts_its_own_request() {
  local dir posts state
  dir=$(new_case c4r)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 4 recovery: emit failed"
  # Simulate a crash between the accepted post and the success write: the record
  # is left at the pre-transport checkpoint while the forge already holds the
  # request. Recovery must adopt it, never post a second one.
  local f
  f=$(find "$dir/home/data/outbound-artifacts" -maxdepth 1 -type f -name '*.json' -print -quit)
  jq '.state = "emitting" | .comment_id = null' "$f" > "$f.x" && mv "$f.x" "$f"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 4 recovery: recovery emit failed"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] || fail "control 4 recovery: recovery posted again ($posts total)"
  state=$(jq -r '.state' "$f")
  [ "$state" = "emitted" ] || fail "control 4 recovery: record left at $state, expected emitted"
  pass "control 4 RECOVERY: a crashed emit adopts its own posted request instead of duplicating"
}

test_ambiguous_post_is_observed_before_retry() {
  local dir posts state
  dir=$(new_case c4ambiguous)
  printf '1\n' > "$dir/forge/lose_response_remaining"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
    || fail "ambiguous post: accepted request with lost response was not recovered"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] || fail "ambiguous post: accepted request was duplicated ($posts posts)"
  state=$(jq -r '.state' "$dir/home/data/outbound-artifacts"/*.json)
  [ "$state" = "emitted" ] || fail "ambiguous post: recovered record remained $state"
  pass "ambiguous post: retry re-observes an accepted request before posting again"
}

test_dedupe_observation_failure_refuses_to_post() {
  local dir out rc posts
  dir=$(new_case c4dedupe)
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" /pulls/4 "*) cat "$FORGE_DIR/head"; exit 0 ;;
esac
for arg in "$@"; do
  case $arg in */pulls/4) cat "$FORGE_DIR/head"; exit 0 ;; esac
done
exit 1
SH
  chmod +x "$dir/bin/gh"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "dedupe observation: expected could-not-observe, got $rc: $out"
  printf '%s' "$out" | grep -q 'could not conclusively establish' \
    || fail "dedupe observation: refusal did not name inconclusive absence: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 0 ] || fail "dedupe observation: posted despite a failed preflight"
  pass "dedupe observation: emission fails closed unless absence is conclusive"
}

test_reconcile_emits_sol_control_only() {
  local dir out rc posts
  dir=$(new_case cadence)
  out=$(run_ob "$dir" reconcile 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "cadence: reconcile did not satisfy the sol-control wait: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] || fail "cadence: reconcile posted $posts requests, expected one"
  write_snapshot "$dir/snap.json" external "never submitted - no pull request exists for this branch"
  jq '.backlog.records[0].contribution_venue = "o/r"
    | .backlog.records[0].pr_url = null' "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  : > "$dir/forge/post_log"
  out=$(run_ob "$dir" reconcile 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "cadence: detect-only missing PR did not remain red: $out"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 0 ] \
    || fail "cadence: reconcile gained pull-request delivery authority"
  pass "cadence: reconcile emits sol-control and leaves pull requests detect-only"
}

# --- controls 5-7: correlation ----------------------------------------------

emitted_request_id() {  # <case-dir>
  jq -r '.request_id' "$(find "$1/home/data/outbound-artifacts" -maxdepth 1 -type f -name '*.json' -print -quit)"
}

test_quoted_prior_verdict_makes_the_ruling_ambiguous() {
  local dir rid out rc
  dir=$(new_case cverdict)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "verdict: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 561 approved
  # A ruling that QUOTES a prior ruling before stating its own. On this control
  # plane that is the ordinary shape, not an attack: rulings cite rulings. Taking
  # the first verdict line would adopt the quoted one silently.
  printf 'verdict: rejected\n' >> "$dir/forge/ruling_body"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 561 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "verdict: an ambiguous body was resolved rather than refused, exit $rc: $out"
  printf '%s' "$out" | grep -q '2 verdict lines' \
    || fail "verdict: the refusal did not name the count: $out"
  [ "$(run_ob "$dir" show "$rid" | jq -r '.state')" = "emitted" ] \
    || fail "verdict: an ambiguous ruling advanced the request anyway"
  pass "verdict: two verdict lines refuse and name the count, rather than resolving by position"
}

test_single_verdict_is_read_and_no_verdict_refuses() {
  local dir rid out rc
  # The non-vacuity half. Without this, the ambiguity control would pass on a
  # command that refused every ruling.
  dir=$(new_case cverdict1)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "verdict: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 562 approved
  run_ob "$dir" ruling --request "$rid" --comment 562 --issue 2 >/dev/null 2>&1 \
    || fail "verdict: a single verdict line was refused"
  [ "$(run_ob "$dir" show "$rid" | jq -r '.ruling.verdict')" = "approved" ] \
    || fail "verdict: the single verdict was not recorded"

  dir=$(new_case cverdict0)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "verdict: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 563 approved
  grep -v '^verdict: ' "$dir/forge/ruling_body" > "$dir/forge/ruling_body.x"
  mv "$dir/forge/ruling_body.x" "$dir/forge/ruling_body"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 563 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "verdict: a body with no verdict was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q '0 verdict lines' \
    || fail "verdict: the zero-verdict refusal did not name the count: $out"
  pass "verdict: exactly one verdict is read, and zero refuses while naming the count"
}

test_ruling_wakes_the_exact_item() {
  local dir rid out
  dir=$(new_case c5)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 5: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 555
  out=$(run_ob "$dir" ruling --request "$rid" --comment 555 --issue 2 2>&1) \
    || fail "control 5: ruling refused its own request: $out"
  printf '%s' "$out" | grep -q 'wakes waiting-item' \
    || fail "control 5: the ruling did not name the waiting item: $out"
  [ "$(run_ob "$dir" show "$rid" | jq -r '.ruling.comment_id')" = "555" ] \
    || fail "control 5: the ruling was not correlated onto the request"
  pass "control 5: a ruling on the request wakes exactly the item that asked"
}

test_unrelated_ruling_cannot_wake_the_item() {
  local dir rid out rc
  dir=$(new_case c6)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 6: emit failed"
  rid=$(emitted_request_id "$dir")

  out=$(run_ob "$dir" ruling --request "$rid" --comment 900 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 6: the outbound request comment ruled on itself: $out"

  # RED 1: a ruling for an identity nobody asked under.
  out=$(run_ob "$dir" ruling --request fm-ob-deadbeefcafe --comment 777 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 6: an unknown request id was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RULING_IDENTITY_MISMATCH' \
    || fail "control 6: refused for the wrong reason: $out"

  # RED 2: the right request, but a ruling that arrived on a different issue.
  out=$(run_ob "$dir" ruling --request "$rid" --comment 778 --issue 99 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 6: a foreign-issue ruling was accepted, exit $rc: $out"

  printf 'unrelated ruling\n' > "$dir/forge/ruling_body"
  printf '779\n' > "$dir/forge/ruling_id"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 779 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 6: an unrelated same-issue comment was accepted: $out"

  # Neither refusal may have touched the record.
  [ "$(run_ob "$dir" show "$rid" | jq -r '.ruling')" = "null" ] \
    || fail "control 6: an unrelated ruling mutated the waiting item's record"
  [ "$(run_ob "$dir" show "$rid" | jq -r '.state')" = "emitted" ] \
    || fail "control 6: an unrelated ruling advanced the request's state"
  pass "control 6 RED: an unrelated ruling refuses and cannot wake the waiting item"
}

test_inbound_poll_advances_only_matching_ruling() {
  local dir rid out rc state
  dir=$(new_case poll)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "poll: emit failed"
  rid=$(emitted_request_id "$dir")
  run_ob "$dir" poll >/dev/null 2>&1 || fail "poll: request-only issue failed polling"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "emitted" ] || fail "poll: outbound request comment advanced state to $state"
  write_ruling "$dir" "$rid" 556 accepted
  run_ob "$dir" poll >/dev/null 2>&1 || fail "poll: matching ruling was not ingested"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "ruled" ] || fail "poll: matching ruling falsely recorded state $state"
  run_ob "$dir" resume --request "$rid" >/dev/null 2>&1 \
    || fail "poll: explicit work resumption could not advance the ruled request"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "resumed" ] || fail "poll: explicit resume left state $state"

  dir=$(new_case poll-unrelated)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "poll unrelated: emit failed"
  rid=$(emitted_request_id "$dir")
  write_foreign_ruling "$dir" fm-ob-deadbeefcafe 557
  write_ruling "$dir" "$rid" 558 accepted
  out=$(run_ob "$dir" poll 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "poll unrelated: unrelated marker returned $rc: $out"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "ruled" ] \
    || fail "poll unrelated: earlier foreign marker blocked the later valid ruling ($state)"
  pass "poll: inbound path records exact rulings without claiming work resumed"
}

test_poll_requires_exactly_one_ruling_marker() {
  local dir rid out rc state
  dir=$(new_case poll-marker-count)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "poll marker count: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 570 accepted
  printf 'FM-SOL-RULING fm-ob-deadbeefcafe\n' >> "$dir/forge/ruling_body"
  out=$(run_ob "$dir" poll 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "poll marker count: two markers returned $rc: $out"
  printf '%s' "$out" | grep -q '2 ruling marker lines' \
    || fail "poll marker count: refusal did not name the count: $out"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "emitted" ] || fail "poll marker count: ambiguous marker advanced state to $state"

  write_ruling "$dir" "$rid" 570 accepted
  run_ob "$dir" poll >/dev/null 2>&1 \
    || fail "poll marker count: exactly one marker was refused"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "ruled" ] || fail "poll marker count: one marker left state $state"

  dir=$(new_case poll-marker-malformed-and-valid)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "poll marker count: malformed companion emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 573 accepted
  printf 'FM-SOL-RULING fm-ob-\nFM-SOL-RULING fm-ob-deadbeef\n' >> "$dir/forge/ruling_body"
  run_ob "$dir" poll >/dev/null 2>&1 \
    || fail "poll marker count: malformed markers blocked one complete identity"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "ruled" ] || fail "poll marker count: malformed companions left state $state"

  dir=$(new_case poll-marker-none)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "poll marker count: second emit failed"
  rid=$(emitted_request_id "$dir")
  printf 'FM-SOL-RULING fm-ob-\nFM-SOL-RULING fm-ob-deadbeef\n' > "$dir/forge/ruling_body"
  printf '571\n' > "$dir/forge/ruling_id"
  run_ob "$dir" poll >/dev/null 2>&1 || fail "poll marker count: malformed-only markers were not ignored"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "emitted" ] || fail "poll marker count: malformed marker advanced state to $state"
  pass "poll: exactly one complete ruling identity is required and ambiguity names its count"
}

test_duplicate_backlog_ids_refuse_identity_joins() {
  local dir rid out rc
  dir=$(new_case duplicate-emit-id)
  jq '.backlog.records += [.backlog.records[0]]' "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "duplicate id emit: duplicate records returned $rc: $out"
  printf '%s' "$out" | grep -q "matched 2 records" \
    || fail "duplicate id emit: refusal did not name the count: $out"

  dir=$(new_case duplicate-ruling-id)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "duplicate id ruling: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 572 accepted
  jq '.backlog.records += [.backlog.records[0]]' "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 572 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "duplicate id ruling: duplicate records returned $rc: $out"
  printf '%s' "$out" | grep -q "matched 2 records" \
    || fail "duplicate id ruling: refusal did not name the count: $out"
  pass "backlog identity joins refuse duplicate ids and name the count"
}

test_stale_ruling_is_invalidated_before_fresh_emission() {
  local dir rid out rc old_state posts
  dir=$(new_case stale-ruling)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "stale ruling: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 559 accepted
  set_head "$dir" "$HEAD_B"
  out=$(run_ob "$dir" reconcile 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "stale ruling: expected aggregate refusal, got $rc: $out"
  old_state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$old_state" = "superseded" ] || fail "stale ruling: old request remained $old_state"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 2 ] || fail "stale ruling: fresh head was not emitted after refusal ($posts posts)"
  [ "$(find "$dir/home/data/outbound-artifacts" -type f -name '*.json' | wc -l)" -eq 2 ] \
    || fail "stale ruling: fresh head did not receive a distinct record"
  pass "stale ruling: moved head is refused before fresh reconciliation"
}

test_complete_identity_is_rechecked_at_ruling_and_resume() {
  local dir rid out rc state
  dir=$(new_case ruling-gate)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "identity ruling gate: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 560 accepted
  jq '.backlog.records[0].hold_reason = "architecture_ruling_required" | .backlog.records[0].title = "architecture decision"' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 560 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "identity ruling gate: changed gate returned $rc: $out"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "superseded" ] || fail "identity ruling gate: stale record remained $state"

  dir=$(new_case ruling-pr)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "identity ruling PR: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 561 accepted
  jq '.backlog.records[0].pr_url = "https://github.com/o/r/pull/5"' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 561 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "identity ruling PR: changed PR returned $rc: $out"

  dir=$(new_case resume-gate)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "identity resume gate: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 562 accepted
  run_ob "$dir" ruling --request "$rid" --comment 562 --issue 2 >/dev/null 2>&1 \
    || fail "identity resume gate: ruling failed"
  jq '.backlog.records[0].hold_reason = "architecture_ruling_required" | .backlog.records[0].title = "architecture decision"' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" resume --request "$rid" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "identity resume gate: changed gate returned $rc: $out"

  dir=$(new_case resume-config)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "identity resume config: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 563 accepted
  run_ob "$dir" ruling --request "$rid" --comment 563 --issue 2 >/dev/null 2>&1 \
    || fail "identity resume config: ruling failed"
  printf '{"repo":"o/control","issue":3}\n' > "$dir/home/config/sol-control.json"
  out=$(run_ob "$dir" resume --request "$rid" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "identity resume config: changed config returned $rc: $out"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "superseded" ] || fail "identity resume config: stale record remained $state"
  pass "identity transitions: ruling and resume require every bound axis"
}

test_poll_aggregate_preserves_unevaluable_precedence() {
  local dir out rc
  dir=$(new_case poll-severity)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "poll severity: emit failed"
  printf 'not-base64\n' > "$dir/forge/poll_prefix"
  write_foreign_ruling "$dir" fm-ob-deadbeefcafe 564
  out=$(run_ob "$dir" poll 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "poll severity: later defect downgraded status 4 to $rc: $out"
  pass "poll severity: could-not-observe outranks later defects"
}

test_disposition_completes_the_correlation() {
  local dir rid rec out rc
  dir=$(new_case c7)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 7: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 555

  # RED: closure cannot skip the chain. An emitted-but-unruled request has no
  # outcome to record, so closing it must refuse.
  out=$(run_ob "$dir" close --request "$rid" --disposition approved 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 7: closure skipped the ruling step, exit $rc: $out"

  run_ob "$dir" ruling --request "$rid" --comment 555 --issue 2 >/dev/null 2>&1 \
    || fail "control 7: ruling failed"
  run_ob "$dir" resume --request "$rid" >/dev/null 2>&1 || fail "control 7: resume failed"
  run_ob "$dir" close --request "$rid" --disposition approved >/dev/null 2>&1 \
    || fail "control 7: close failed"

  rec=$(run_ob "$dir" show "$rid")
  [ "$(printf '%s' "$rec" | jq -r '.state')" = "closed" ] \
    || fail "control 7: final state is not closed"
  [ "$(printf '%s' "$rec" | jq -r '.identity.item')" = "waiting-item" ] \
    || fail "control 7: the closed record lost the item it correlates to"
  [ "$(printf '%s' "$rec" | jq -r '.identity.head')" = "$HEAD_A" ] \
    || fail "control 7: the closed record lost the exact head it was bound to"
  printf '%s' "$rec" | jq -e '.ruling.comment_id and .resumed.at and .disposition.outcome' \
    >/dev/null || fail "control 7: the correlation chain is incomplete: $rec"
  pass "control 7: request, ruling, resumed item and disposition form one closed chain"
}

test_terminal_request_is_not_applicable() {
  local dir rid out rc
  dir=$(new_case c7terminal)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "terminal: emit failed"
  rid=$(awk '{print $2}' "$dir/forge/comments")
  write_ruling "$dir" "$rid" 44
  run_ob "$dir" ruling --request "$rid" --comment 44 --issue 2 >/dev/null 2>&1 \
    || fail "terminal: ruling failed"
  run_ob "$dir" resume --request "$rid" >/dev/null 2>&1 || fail "terminal: resume failed"
  run_ob "$dir" close --request "$rid" --disposition accepted >/dev/null 2>&1 \
    || fail "terminal: close failed"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "terminal: closed request satisfied a new wait: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "terminal: closed request failed for the wrong reason: $out"
  pass "terminal: a closed request cannot satisfy a current wait"
}

test_request_requires_readable_correlation() {
  local dir rid record valid_record out rc
  dir=$(new_case c7correlation)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "correlation: emit failed"
  rid=$(awk '{print $2}' "$dir/forge/comments")
  record="$dir/home/data/outbound-artifacts/$rid.json"
  rm "$record"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "correlation: missing record returned $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CORRELATION_RECORD_MISSING' \
    || fail "correlation: missing record satisfied the wait: $out"

  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "correlation: adoption failed"
  valid_record="$dir/valid-record.json"
  cp "$record" "$valid_record"
  jq '.state = "unknown"' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "correlation: invalid state returned $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RECORD_UNREADABLE' \
    || fail "correlation: invalid lifecycle state satisfied the wait: $out"

  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "correlation: emit overwrote an unreadable record: $out"
  [ "$(jq -r '.state' "$record")" = "unknown" ] \
    || fail "correlation: refused emit mutated the unreadable record"
  cp "$valid_record" "$record"
  jq '.identity.item = "another-item"' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "correlation: emit did not refuse a foreign keyed record: $out"
  [ "$(jq -r '.identity.item' "$record")" = "another-item" ] \
    || fail "correlation: refused emit overwrote the foreign keyed record"
  # A MISMATCH is not could-not-observe. This record is perfectly readable and
  # says plainly that it belongs to another request, which is a correlation
  # defect (exit 3) and not a failure to observe (exit 4). The distinction is not
  # cosmetic: told only "could not read it", an operator goes looking for a
  # corrupt file or a permissions problem and finds neither, while the actual
  # repair is elsewhere entirely. This assertion previously expected 4 - it
  # passed because the two verdicts were collapsed, which is the defect the
  # captain ruling of 2026-08-16 names, not a behaviour to preserve.
  out=$(run_ob "$dir" ruling --request "$rid" --comment 46 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "correlation: mismatched identity did not refuse as a mismatch: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_IDENTITY_REFUSED' \
    || fail "correlation: mismatched identity was not reported as a mismatch: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RECORD_UNREADABLE' \
    && fail "correlation: a readable foreign record was reported as unreadable: $out"
  pass "correlation: missing, invalid, and mismatched records refuse without overwrite"
}

test_close_requires_resumed_work() {
  local dir rid out rc state
  dir=$(new_case c7resume)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "resume chain: emit failed"
  rid=$(awk '{print $2}' "$dir/forge/comments")
  write_ruling "$dir" "$rid" 45
  run_ob "$dir" ruling --request "$rid" --comment 45 --issue 2 >/dev/null 2>&1 \
    || fail "resume chain: ruling failed"
  out=$(run_ob "$dir" close --request "$rid" --disposition accepted 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "resume chain: close skipped resume: $out"
  state=$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")
  [ "$state" = "ruled" ] || fail "resume chain: refused close mutated state to $state"
  pass "resume chain: disposition cannot bypass resumed work"
}

# --- fail-closed properties --------------------------------------------------

test_incomplete_binding_refuses_rather_than_emitting_vaguely() {
  local dir out rc posts
  dir=$(new_case c8)
  # The head becomes unobservable: the pull request read returns nothing and no
  # clone or declaration supplies one.
  : > "$dir/forge/head"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 8: a headless emit was not refused, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_INCOMPLETE_BINDING' \
    || fail "control 8: refused for the wrong reason: $out"
  printf '%s' "$out" | grep -q 'head' || fail "control 8: the missing field was not named: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 0 ] || fail "control 8: a vague request was posted anyway ($posts)"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 8: the unbindable item was not left red, exit $rc"
  pass "control 8: an incomplete binding refuses to emit and leaves the item red"
}

test_unobservable_forge_is_not_a_pass() {
  local dir out rc
  dir=$(new_case c9)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 9: emit failed"
  # The venue configuration disappears. The artifact may well still exist, but
  # this sweep cannot see it - which must never read as satisfied.
  rm -f "$dir/home/config/sol-control.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "control 9: an unobservable forge did not reach 4, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_TRANSPORT_UNCONFIGURED' \
    || fail "control 9: unevaluable for the wrong reason: $out"
  printf '%s' "$out" | grep -q '0 satisfied' \
    || fail "control 9: an unobservable artifact was counted as satisfied: $out"
  pass "control 9: an unobservable artifact is could-not-observe, never a pass"
}

test_detect_only_channel_refuses_to_emit() {
  local dir out rc
  dir=$(new_case c10)
  write_snapshot "$dir/snap.json" external "never submitted - no pull request exists for this branch"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 10: the detect-only channel emitted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CHANNEL_DETECT_ONLY' \
    || fail "control 10: refused for the wrong reason: $out"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 0 ] \
    || fail "control 10: the detect-only channel posted something"
  pass "control 10: the pull-request channel detects but never creates the artifact"
}

test_independent_review_precedes_handoff_submission() {
  local dir out rc
  dir=$(new_case combined-review-handoff)
  write_snapshot "$dir/snap.json" external \
    "released for handoff pending independent acceptance"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "combined prose: an existing pull request satisfied missing independent review: $out"
  printf '%s' "$out" | grep -q 'INDEPENDENT_BROWSER_REVIEW_REQUIRED' \
    || fail "combined prose: independent review did not take precedence: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "combined prose: the missing Sol request was not reported: $out"
  pass "combined prose: independent review takes precedence over contribution handoff"
}

test_architecture_ruling_precedes_handoff_submission() {
  local dir out rc
  dir=$(new_case combined-architecture-handoff)
  write_snapshot "$dir/snap.json" external \
    "released for handoff awaiting architecture ruling"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "combined architecture prose: an existing pull request satisfied the missing ruling request: $out"
  printf '%s' "$out" | grep -q 'ARCHITECTURE_RULING_REQUIRED' \
    || fail "combined architecture prose: architecture ruling did not take precedence: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "combined architecture prose: the missing Sol request was not reported: $out"
  pass "combined architecture prose: architecture ruling takes precedence over contribution handoff"
}

test_typed_gate_uses_declaration_over_prose() {
  local dir out rc
  dir=$(new_case typed-declaration)
  write_snapshot "$dir/snap.json" outbound "awaiting Browser Sol architecture ruling"
  declare_gate "$dir/home" CONTRIBUTION_SUBMISSION_REQUIRED
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "typed declaration: conflicting prose selected an emitting channel: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CHANNEL_DETECT_ONLY' \
    || fail "typed declaration: declaration did not select the detect-only channel: $out"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 0 ] \
    || fail "typed declaration: conflicting prose caused a public post"
  pass "typed declaration: declaration is authoritative over conflicting prose"
}

test_typed_gate_requires_valid_declaration() {
  local dir out rc gate
  for gate in missing unreadable NOT_A_GATE; do
    dir=$(new_case "typed-$gate")
    write_snapshot "$dir/snap.json" outbound "awaiting Browser Sol architecture ruling"
    if [ "$gate" = unreadable ]; then
      mkdir -p "$dir/home/data/waiting-item"
      printf '{not-json\n' > "$dir/home/data/waiting-item/outbound-gate.json"
    elif [ "$gate" != missing ]; then
      declare_gate "$dir/home" "$gate"
    fi
    out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
    [ "$rc" -eq 3 ] || fail "typed $gate declaration: incomplete binding returned $rc: $out"
    printf '%s' "$out" | grep -q 'FM_OUTBOUND_INCOMPLETE_BINDING' \
      || fail "typed $gate declaration: refused for the wrong reason: $out"
    [ "$(wc -l < "$dir/forge/post_log")" -eq 0 ] \
      || fail "typed $gate declaration: incomplete binding caused a public post"
  done
  pass "typed declaration: missing and invalid gates are incomplete bindings"
}

test_pull_request_probe_prefers_contribution_target() {
  local dir out rc
  dir=$(new_case upstream)
  write_snapshot "$dir/snap.json" external "never submitted - no pull request exists for this branch"
  jq '.backlog.records[0].contribution_venue = "upstream/project"' "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  printf '101\n' > "$dir/forge/pr_number"
  printf '%s\n' "$HEAD_A" > "$dir/forge/pr_head"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "PR venue: declared contribution target was not probed: $out"
  printf '%s' "$out" | grep -q 'pull/101' \
    || fail "PR venue: upstream pull request was not reported: $out"
  pass "PR venue: detection uses the declared contribution target"
}

test_pull_request_must_match_exact_head() {
  local dir out rc
  dir=$(new_case pr-exact-head)
  write_snapshot "$dir/snap.json" external "never submitted - no pull request exists for this branch"
  printf '101\n' > "$dir/forge/pr_number"
  printf '%s\n' "$HEAD_B" > "$dir/forge/pr_head"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "PR exact head: a PR advanced beyond the requested commit satisfied the wait: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "PR exact head: the advanced PR was refused for the wrong reason: $out"
  pass "PR detection requires the pull request head to equal the waiting head"
}

test_pull_request_probe_refuses_multiple_exact_head_matches() {
  local dir out rc
  dir=$(new_case pr-duplicate-head)
  write_snapshot "$dir/snap.json" external "never submitted - no pull request exists for this branch"
  printf '101\n102\n' > "$dir/forge/pr_number"
  printf '%s\n' "$HEAD_A" > "$dir/forge/pr_head"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "PR duplicate head: multiple exact-head PRs returned $rc: $out"
  printf '%s' "$out" | grep -q 'has 2 open pull requests' \
    || fail "PR duplicate head: ambiguity did not name the count: $out"
  pass "PR detection refuses multiple exact-head matches and names the count"
}

test_never_submitted_branch_is_recognised() {
  local dir out rc
  dir=$(new_case c11)
  # The shape of the three items found finished on a branch with no pull request
  # anywhere. It must be recognised as a defect, not as legitimate waiting.
  write_snapshot "$dir/snap.json" external "RECLASSIFIED: valid unfinished work, never submitted. No pull request on the fork or upstream."
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "control 11: a never-submitted item passed the invariant: $out"
  printf '%s' "$out" | grep -q 'CONTRIBUTION_SUBMISSION_REQUIRED' \
    || fail "control 11: the never-submitted gate was not typed: $out"
  pass "control 11: a finished branch with no pull request is a transport defect"
}

test_done_rows_are_not_waiting() {
  local dir out rc
  dir=$(new_case c12)
  # The recognizer's own negative control: the identical hold prose on a landed
  # row is history, not an outstanding ask. Without this the sweep would report
  # every historical hold forever and be turned off.
  jq '.backlog.records[0].state = "done"' "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "control 12: a done row was still treated as waiting, exit $rc: $out"
  pass "control 12: a landed row carrying the same hold prose is not waiting"
}

test_unstructured_row_is_not_silently_clear() {
  local dir out rc v
  # A row this parser cannot read must not read as clear. It is classified
  # unreadable, which is the third value rather than a quiet pass.
  v=$(
    # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
    . "$ROOT/bin/fm-outbound-artifact-lib.sh"
    fm_outbound_classify_record '{"structured":false,"raw":"a free-form line"}' | cut -f1
  )
  [ "$v" = "unreadable" ] \
    || fail "control 13: an unparseable row classified as '$v', not unreadable"
  out=$(
    # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
    . "$ROOT/bin/fm-outbound-artifact-lib.sh"
    fm_outbound_classify_record 'not json at all' | cut -f1
  )
  [ "$out" = "unreadable" ] \
    || fail "control 13: unparseable JSON classified as '$out', not unreadable"
  dir=$(new_case c13)
  jq '.backlog.records = [{structured:false,raw:"a free-form line"}]' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "control 13: unreadable backlog row returned $rc instead of unevaluable: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_BACKLOG_ROW_UNREADABLE' \
    || fail "control 13: sweep silently omitted its unreadable row: $out"
  pass "control 13: an unreadable backlog row is could-not-observe, never clear"
}

test_recognition_survives_a_truncated_hold_reason() {
  local v hay
  # The backlog parser captures a hold with `[^,)]*`, so a hold reason stops at
  # its first comma. On the live backlog that cut "VALID UNFINISHED WORK, never
  # submitted" down to "...WORK" and made this recognizer blind to the exact
  # never-submitted items it exists to catch. The recognizer therefore reads the
  # untruncated raw row, and this pins that: the parsed hold_reason here is
  # truncated exactly as the real parser truncates it, and only `raw` carries the
  # signal.
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  local rec='{"structured":true,"state":"queued","id":"x","hold_kind":"external",
    "hold_reason":"RECLASSIFIED by the sweep: VALID UNFINISHED WORK",
    "title":"some work","body_excerpt":null,
    "raw":"- [ ] x - some work (hold: RECLASSIFIED by the sweep: VALID UNFINISHED WORK, never submitted. No pull request exists.) (hold-kind: external)"}'

  # RED first: reading only the truncated hold_reason misses it entirely.
  fm_outbound_prose_matches "RECLASSIFIED by the sweep: VALID UNFINISHED WORK" \
    && fail "truncation: the truncated hold_reason should carry no signal, but matched"

  hay=$(fm_outbound_haystack "$rec")
  printf '%s' "$hay" | grep -q 'never submitted' \
    || fail "truncation: the raw row was not read into the recognizer's text"
  v=$(fm_outbound_classify_record "$rec" | cut -f1)
  [ "$v" = "waiting" ] || fail "truncation: a comma in the hold reason hid the gate ($v)"
  v=$(fm_outbound_classify_record "$rec" | cut -f2)
  [ "$v" = "CONTRIBUTION_SUBMISSION_REQUIRED" ] \
    || fail "truncation: gate typed as '$v' rather than the never-submitted gate"
  pass "truncation: a hold reason cut off at its first comma is still recognised"
}

test_forge_error_body_is_not_a_head() {
  local dir out rc
  dir=$(new_case c14)
  # `gh api` prints its error payload to STDOUT and exits non-zero. Observed
  # against a live backlog, an unvalidated read carried a 404 body forward as the
  # exact head and rendered it as evidence. The cascade must treat that as no
  # observation at all.
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '{"message":"Not Found","status":"404"}\n'
exit 1
SH
  chmod +x "$dir/bin/gh"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "forge error: expected a defect, got $rc: $out"
  printf '%s' "$out" | grep -q 'Not Found' \
    && fail "forge error: a 404 body was carried forward as the exact head: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_HEAD_UNOBSERVED' \
    || fail "forge error: not reported as an unobserved head: $out"
  pass "forge error: an error payload is no observation, not a head"
}

test_untyped_gate_is_reported_as_untyped() {
  local cls
  # The empty middle field. `IFS=$'\t' read` collapses runs of tabs because tab
  # is IFS whitespace, which silently shifted the tier into the gate and printed
  # "gate: prose" against the live backlog. An untyped gate must survive as
  # empty, because untyped is the condition the binding check refuses on.
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  cls=$(fm_outbound_classify_record '{"structured":true,"state":"queued","id":"y",
    "hold_kind":"external","hold_reason":"Browser Sol something unclassified",
    "title":"t","body_excerpt":null,"raw":"raw"}')
  [ "$(printf '%s' "$cls" | cut -f1)" = "waiting" ] || fail "untyped: not recognised as waiting"
  [ -z "$(printf '%s' "$cls" | cut -f2)" ] \
    || fail "untyped: gate field is '$(printf '%s' "$cls" | cut -f2)', expected empty"
  [ "$(printf '%s' "$cls" | cut -f3)" = "prose" ] \
    || fail "untyped: tier field lost, got '$(printf '%s' "$cls" | cut -f3)'"
  pass "untyped: an unclassifiable gate stays empty and does not absorb the tier"
}

# --- identity properties -----------------------------------------------------

test_identity_binds_every_named_axis() {
  # Each axis the contract names must change the request id on its own. An axis
  # that does not is an axis the identity does not actually bind, and dedupe
  # would then merge two genuinely different asks.
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  local base axis id
  base=$(fm_outbound_request_id AWAITING_BROWSER_SOL proj o/r item 4 "$HEAD_A")
  [ -n "$base" ] || fail "identity: no request id produced"
  for axis in \
    "ARCHITECTURE_RULING_REQUIRED proj o/r item 4 $HEAD_A" \
    "AWAITING_BROWSER_SOL other o/r item 4 $HEAD_A" \
    "AWAITING_BROWSER_SOL proj o/other item 4 $HEAD_A" \
    "AWAITING_BROWSER_SOL proj o/r other 4 $HEAD_A" \
    "AWAITING_BROWSER_SOL proj o/r item 5 $HEAD_A" \
    "AWAITING_BROWSER_SOL proj o/r item 4 $HEAD_B"
  do
    # shellcheck disable=SC2086
    id=$(fm_outbound_request_id $axis)
    [ "$id" != "$base" ] || fail "identity: '$axis' did not change the request id"
  done
  # And it must be stable: the same identity twice is the same id, or dedupe
  # cannot work at all.
  [ "$(fm_outbound_request_id AWAITING_BROWSER_SOL proj o/r item 4 "$HEAD_A")" = "$base" ] \
    || fail "identity: the same identity produced two different ids"
  pass "identity: gate, project, repo, item, pull request and head each bind, and are stable"
}

test_binding_refuses_a_vague_head() {
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  local bad
  [ "$(git -C "$HEAD_REPO" rev-parse --show-object-format)" = sha1 ] \
    || fail "binding: the fixture repository is not sha1, so this case proves nothing"
  for bad in "" "main" "the current head" "HEAD" "latest" \
    "${HEAD_A%?????????????????????????????????}" \
    "${HEAD_A%?}"; do
    fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i "$bad" "$HEAD_REPO" >/dev/null 2>&1 \
      && fail "binding: '$bad' was accepted as an exact head"
  done
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i "$HEAD_A" "$HEAD_REPO" >/dev/null 2>&1 \
    || fail "binding: this repository's own full object id was rejected"

  # THE DISTINGUISHING CASE. A 64-character value is a valid object id in a
  # sha256 repository and is NOT one here. This assertion previously required
  # such a value to be ACCEPTED, which is the bare 40-or-64 predicate: it would
  # let a content digest - and this fleet writes those routinely - be read as an
  # exact head. Width comes from the target repository, so the same string is
  # correct in one repository and wrong in another.
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i \
    "${HEAD_A}${HEAD_A%????????????????}" "$HEAD_REPO" >/dev/null 2>&1 \
    && fail "binding: a 64-character value was accepted by a sha1 repository"

  # A well-formed id of the right width that names no object here is not this
  # repository's head either: shape is the cheap pre-filter, resolvability is the
  # evidence.
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i \
    "$(printf '%040d' 0 | tr 0 b)" "$HEAD_REPO" >/dev/null 2>&1 \
    && fail "binding: an unresolvable but well-shaped id was accepted"

  # And with no repository the width is undeterminable, which refuses rather
  # than falling back to a guessed default.
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i "$HEAD_A" "" >/dev/null 2>&1 \
    && fail "binding: an undeterminable object format was treated as a default width"
  pass "binding: head width comes from the target repository, and resolvability beats shape"
}

# --- run ---------------------------------------------------------------------

test_no_request_is_red
test_branch_inventory_finds_an_unannotated_unsubmitted_branch
test_branch_inventory_excludes_landed_work
test_branch_inventory_excludes_squash_landed_work
test_branch_inventory_unresolvable_landing_target_is_unevaluable
test_branch_inventory_absent_registry_is_unevaluable
test_branch_inventory_failing_ref_enumeration_is_unevaluable
test_branch_inventory_failing_head_reads_are_unevaluable
test_branch_inventory_unreadable_posture_is_unevaluable
test_branch_inventory_failing_default_branch_read_is_unevaluable
test_branch_inventory_failing_candidate_refs_is_unevaluable
test_branch_inventory_read_failures_never_certify_empty
test_request_present_is_green
test_request_presence_requires_exact_validated_identity
test_head_change_invalidates
test_head_change_fresh_request_is_green
test_no_duplicate_requests
test_duplicate_control_can_fail
test_transient_failure_retries
test_exhausted_transport_keeps_the_request
test_crash_recovery_adopts_its_own_request
test_ambiguous_post_is_observed_before_retry
test_dedupe_observation_failure_refuses_to_post
test_reconcile_emits_sol_control_only
test_ruling_wakes_the_exact_item
test_quoted_prior_verdict_makes_the_ruling_ambiguous
test_single_verdict_is_read_and_no_verdict_refuses
test_unrelated_ruling_cannot_wake_the_item
test_inbound_poll_advances_only_matching_ruling
test_poll_requires_exactly_one_ruling_marker
test_duplicate_backlog_ids_refuse_identity_joins
test_stale_ruling_is_invalidated_before_fresh_emission
test_complete_identity_is_rechecked_at_ruling_and_resume
test_poll_aggregate_preserves_unevaluable_precedence
test_disposition_completes_the_correlation
test_terminal_request_is_not_applicable
test_request_requires_readable_correlation
test_close_requires_resumed_work
test_incomplete_binding_refuses_rather_than_emitting_vaguely
test_unobservable_forge_is_not_a_pass
test_detect_only_channel_refuses_to_emit
test_independent_review_precedes_handoff_submission
test_architecture_ruling_precedes_handoff_submission
test_typed_gate_uses_declaration_over_prose
test_typed_gate_requires_valid_declaration
test_pull_request_probe_prefers_contribution_target
test_pull_request_must_match_exact_head
test_pull_request_probe_refuses_multiple_exact_head_matches
test_never_submitted_branch_is_recognised
test_done_rows_are_not_waiting
test_unstructured_row_is_not_silently_clear
test_forge_error_body_is_not_a_head
test_recognition_survives_a_truncated_hold_reason
test_untyped_gate_is_reported_as_untyped
test_identity_binds_every_named_axis
test_binding_refuses_a_vague_head

printf '\nall fm-outbound-artifact tests passed\n'
