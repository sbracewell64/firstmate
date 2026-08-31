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
  printf 'main\n' > "$1/forge/base_ref"
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
    case " $* " in *" .base.ref "*) cat "$F/base_ref"; exit 0 ;; esac
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

# A ruling body is derived from the request it answers, so any sender the
# REQUEST carried is stripped before the responder's own is added. A canonical
# writer states its own role and never inherits the other side's - and leaving
# the original in would make every fixture carry two `from:` lines, which is
# itself invalid.
write_ruling() {  # <case-dir> <request-id> <comment-id> [<verdict>] [<sender>]
  local dir=$1 rid=$2 comment=$3 verdict=${4:-approved} sender=${5:-browser-sol}
  write_typed_ruling "$dir" "$rid" waiting-item \
    "$(jq -r '.identity.head' "$dir/home/data/outbound-artifacts/$rid.json")" \
    "$comment" "$verdict"
  sed -i "s/^from: .*/from: $sender/" "$dir/forge/ruling_body"
}

write_foreign_ruling() {  # <case-dir> <request-id> <comment-id>
  local dir=$1 rid=$2 comment=$3
  printf 'protocol: fm-sol-control/v1\nkind: ruling\n\nin_reply_to: %s\nfrom: browser-sol\n\ndecision: rejected\n' \
    "$rid" > "$dir/forge/foreign_ruling_body"
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
    {order:1,state:"done",structured:true,id:"never-submitted",title:"finished work",
     hold_kind:null,hold_reason:null,repo:"demo",pr_url:null,body_excerpt:null,
     raw:"- [x] never-submitted - finished work (repo: demo)"}]}}' > "$dir/snap.json"
  # The durable completion record. This is what makes the branch a DEFECT rather
  # than could-not-observe: it establishes the work was finished and was ship
  # work, so a missing pull request is a real transport failure. Without it the
  # honest answer is that we cannot tell, which its own control asserts below.
  printf -- '- [x] never-submitted - finished work (repo: demo) (kind: ship) (done 2026-08-16)\n' \
    > "$dir/home/data/backlog.md"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "inventory: an unannotated unsubmitted branch was not found, exit $rc: $out"
  printf '%s' "$out" | grep -q 'never-submitted' \
    || fail "inventory: the branch was not named: $out"
  printf '%s' "$out" | grep -q 'recognised: inventory' \
    || fail "inventory: found by annotation rather than by enumeration: $out"
  pass "inventory: a branch nobody annotated is found by enumeration, not by prose"
}

test_branch_inventory_dedupes_only_complete_identity() {
  local dir project repo sha out rc
  dir=$(new_case cinventory-identity)
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n- other [no-mistakes] - other project (added 2026-08-16)\n' \
    > "$dir/home/data/projects.md"
  for project in demo other; do
    repo="$dir/home/projects/$project"
    if [ "$project" = other ]; then
      git clone -q --no-hardlinks "$HEAD_REPO" "$repo" 2>/dev/null
    fi
    git -C "$repo" config user.email fixture@example.com
    git -C "$repo" config user.name Fixture
    git -C "$repo" remote set-url origin "https://github.com/o/$project.git"
    git -C "$repo" checkout -q -b fm/shared-item
    printf '%s work\n' "$project" > "$repo/$project"
    git -C "$repo" add "$project"
    git -C "$repo" -c commit.gpgsign=false commit -qm "$project work"
    sha=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" checkout -q master
    if [ "$project" = demo ]; then
      printf '%s\n' "$sha" > "$dir/forge/head"
      printf '%s\n' "$sha" > "$dir/forge/pr_head"
      printf '101\n' > "$dir/forge/pr_number"
    fi
  done
  write_snapshot "$dir/snap.json" external \
    "never submitted - no pull request exists for this branch"
  jq '.backlog.records[0].id = "shared-item"
      | .backlog.records[0].repo = "demo"' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  # Completion records for BOTH projects' identically named branches. They share
  # an item name and differ only by project, which is the whole point of the
  # control: the evidence lookup must join on (project, item) exactly as the
  # dedupe does, or one project's record answers for the other's branch.
  printf -- '- [x] shared-item - demo work (repo: demo) (kind: ship) (done 2026-08-16)\n- [x] shared-item - other work (repo: other) (kind: ship) (done 2026-08-16)\n' \
    > "$dir/home/data/backlog.md"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "inventory identity: other project's unsubmitted branch was hidden, exit $rc: $out"
  printf '%s' "$out" | grep -q 'recognised: inventory' \
    || fail "inventory identity: the cross-project inventory defect was suppressed: $out"
  pass "inventory identity: a shared branch name cannot suppress another project"
}

test_branch_inventory_dedupes_duplicate_refs_before_probing() {
  local dir repo duplicate_head out rc
  dir=$(new_case cinventory-duplicate-refs)
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n' > "$dir/home/data/projects.md"
  repo="$dir/home/projects/demo"
  git -C "$repo" config user.email fixture@example.com
  git -C "$repo" config user.name Fixture
  git -C "$repo" checkout -q -b fm/duplicate
  printf 'duplicate\n' > "$repo/duplicate"
  git -C "$repo" add duplicate
  git -C "$repo" -c commit.gpgsign=false commit -qm duplicate
  duplicate_head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref refs/remotes/origin/fm/duplicate "$duplicate_head"
  git -C "$repo" checkout -q master
  git -C "$repo" checkout -q -b fm/unique
  printf 'unique\n' > "$repo/unique"
  git -C "$repo" add unique
  git -C "$repo" -c commit.gpgsign=false commit -qm unique
  git -C "$repo" checkout -q master
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[]}}' > "$dir/snap.json"
  # Both enumerated branches are completed ship work. Without these durable
  # records Option C correctly classifies them as could-not-observe, so the
  # fixture would never reach the duplicate-ref probe-budget behavior it owns.
  printf -- '- [x] duplicate - duplicate work (repo: demo) (kind: ship) (done 2026-08-16)\n- [x] unique - unique work (repo: demo) (kind: ship) (done 2026-08-16)\n' \
    > "$dir/home/data/backlog.md"
  out=$(FM_OUTBOUND_MAX_PROBES=2 run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "inventory duplicate refs: unique heads did not fit two probes, exit $rc: $out"
  [ "$(printf '%s' "$out" | grep -c '^  duplicate$')" -eq 1 ] \
    || fail "inventory duplicate refs: duplicate identity produced multiple findings: $out"
  printf '%s' "$out" | grep -q '^  unique$' \
    || fail "inventory duplicate refs: duplicate refs hid the unique head: $out"
  printf '%s' "$out" | grep -q 'PROBE CAP REACHED' \
    && fail "inventory duplicate refs: duplicate refs exhausted the probe budget: $out"
  pass "inventory: duplicate local and remote refs consume one probe"
}

# Build a project with one unlanded, unsubmitted fm/<item> branch and no pull
# request, so the only thing under test is what the durable record says.
inventory_case() {  # <case-name> <item> -> prints case dir
  local dir repo item=$2
  dir=$(new_case "$1")
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
  git -C "$repo" checkout -q -b "fm/$item"
  printf 'work\n' > "$repo/f"; git -C "$repo" add f
  git -C "$repo" -c commit.gpgsign=false commit -qm 'work on a branch'
  git -C "$repo" checkout -q main
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[]}}' > "$dir/snap.json"
  printf '%s\n' "$dir"
}

test_inventory_unfinished_work_is_not_a_defect() {
  local dir out rc
  # THE FINDING THAT PRODUCED OPTION C. An ordinary in-progress branch has no
  # pull request and should not, so calling it a transport defect would make this
  # control fire on every startup for every active branch - and a control that
  # cries wolf is discounted, which is the same silence as reporting nothing.
  dir=$(inventory_case cinv-wip in-progress)
  printf -- '- [ ] in-progress - still being worked on (repo: demo) (kind: ship)\n' \
    > "$dir/home/data/backlog.md"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  printf '%s' "$out" | grep -q 'DEFECT - waiting with no applicable durable artifact (0)' \
    || fail "unfinished: in-progress work was reported as a transport defect: $out"
  [ "$rc" -eq 4 ] \
    || fail "unfinished: expected could-not-observe rather than clean or defect, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WORK_STATE_UNOBSERVED' \
    || fail "unfinished: the reason was not named: $out"
  pass "unfinished: an in-progress branch is could-not-observe, not a defect"
}

test_inventory_conflicting_lifecycle_is_could_not_observe() {
  local dir out rc
  dir=$(inventory_case cinv-reopened reopened-work)
  printf -- '- [x] reopened-work - once finished (repo: demo) (kind: ship) (done 2026-08-15)\n- [ ] reopened-work - reopened for more work (repo: demo) (kind: ship)\n' \
    > "$dir/home/data/backlog.md"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "lifecycle conflict: expected could-not-observe, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WORK_LIFECYCLE_CONFLICT' \
    || fail "lifecycle conflict: the conflicting records were not named: $out"
  printf '%s' "$out" | grep -q 'DEFECT - waiting with no applicable durable artifact (0)' \
    || fail "lifecycle conflict: reopened work was reported as a defect: $out"
  printf '%s' "$out" | grep -q 'SATISFIED (0)' \
    || fail "lifecycle conflict: reopened work was reported as clean: $out"
  pass "lifecycle conflict: completed and open records are could-not-observe"
}

test_inventory_unparsable_lifecycle_row_is_unobserved_not_a_conflict() {
  # TWO DIFFERENT COULD-NOT-OBSERVE REASONS, KEPT APART. The candidate match is a
  # substring search while the state extraction is anchored to the start of the
  # line, so an indented row is a candidate whose state cannot be parsed. That is
  # "nothing could be read", not "the records disagree": told there is a
  # conflict, a reader goes looking for a second row that contradicts this one
  # and there is no second row.
  local dir out rc
  dir=$(inventory_case cinv-indented indented-row)
  printf -- '  - [x] indented-row - finished but written indented (repo: demo) (kind: ship)\n' \
    > "$dir/home/data/backlog.md"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "unparsable lifecycle: expected could-not-observe, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WORK_STATE_UNOBSERVED' \
    || fail "unparsable lifecycle: an unreadable state was not named as unobserved: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WORK_LIFECYCLE_CONFLICT' \
    && fail "unparsable lifecycle: one unreadable row was reported as a disagreement: $out"
  pass "unparsable lifecycle: an unreadable row is unobserved, never a conflict"
}

test_inventory_non_ship_work_is_not_a_defect() {
  local dir out rc
  # An investigation produces a report and never a pull request, so its branch
  # having none is CORRECT. This is the exclusion that pays for reading the
  # record at all: without it every completed investigation is a false defect.
  dir=$(inventory_case cinv-scout an-investigation)
  printf -- '- [x] an-investigation - looked into it (repo: demo) (kind: scout) (done 2026-08-16)\n' \
    > "$dir/home/data/backlog.md"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  printf '%s' "$out" | grep -q 'an-investigation' \
    && fail "non-ship: an investigation branch was reported at all: $out"
  [ "$rc" -eq 0 ] || fail "non-ship: expected a clean sweep, exit $rc: $out"
  printf '%s' "$out" | grep -q 'COULD NOT OBSERVE.*(0)' \
    || fail "non-ship: the empty could-not-observe section vanished: $out"
  pass "non-ship: a completed investigation branch is neither a defect nor a gap"
}

test_inventory_reads_the_rotated_archive() {
  local dir out rc
  # The backlog keeps only a fixed number of completed entries and rotates the
  # rest into the archive, which holds the large majority of them. Reading only
  # the backlog would make everything older than that handful could-not-observe
  # and would collapse this control to almost nothing.
  dir=$(inventory_case cinv-archive long-since-done)
  : > "$dir/home/data/backlog.md"
  printf -- '- [x] long-since-done - finished ages ago (repo: demo) (kind: ship) (done 2026-07-01)\n' \
    > "$dir/home/data/done-archive.md"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] \
    || fail "archive: rotated completion evidence was not read, exit $rc: $out"
  printf '%s' "$out" | grep -q 'long-since-done' \
    || fail "archive: the unsubmitted branch was not named: $out"
  pass "archive: completion evidence rotated out of the backlog is still read"
}

test_inventory_unreadable_archive_is_could_not_observe() {
  local dir out rc
  # An archive that exists but cannot be read leaves the candidate set
  # incomplete. Answering from the backlog alone would be a confident verdict
  # built on a corpus we know we could not finish reading.
  #
  # It is named as an UNREADABLE ARCHIVE rather than as an unobserved work
  # state, because the two carry different repairs. No record is a gap in the
  # corpus with nothing to do; an unreadable archive is a permissions or I/O
  # fault someone can go and fix. Reported as the former, an operator hunts for
  # missing data that was present the whole time.
  dir=$(inventory_case cinv-archive-unreadable some-work)
  printf -- '- [x] some-work - finished (repo: demo) (kind: ship) (done 2026-08-16)\n' \
    > "$dir/home/data/backlog.md"
  printf -- '- [x] other - x (repo: demo) (kind: ship)\n' > "$dir/home/data/done-archive.md"
  chmod 000 "$dir/home/data/done-archive.md"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  chmod 644 "$dir/home/data/done-archive.md"
  if [ "$(id -u)" -eq 0 ]; then
    pass "archive unreadable: skipped, root can read anything"
    return
  fi
  [ "$rc" -eq 4 ] \
    || fail "archive unreadable: an unreadable corpus produced a confident verdict, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_DONE_ARCHIVE_UNREADABLE' \
    || fail "archive unreadable: the unreadable archive was not named: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WORK_STATE_UNOBSERVED' \
    && fail "archive unreadable: a readable-but-absent corpus was claimed instead: $out"
  pass "archive unreadable: an incomplete corpus is could-not-observe, not a verdict"
}

test_could_not_observe_has_its_own_section() {
  local dir out defect_body gap_body
  # If could-not-observe renders inline among defects it reads as a defect; if
  # it is dropped or folded into clean it disappears. Its own headed, counted
  # section is what keeps the third answer a third answer - and for THIS control
  # it is the primary signal, because released work with no record lands here.
  dir=$(inventory_case cinv-sections unknown-state)
  : > "$dir/home/data/backlog.md"
  out=$(run_ob "$dir" check 2>&1) || true
  printf '%s' "$out" | grep -q 'COULD NOT OBSERVE' \
    || fail "sections: could-not-observe has no section of its own: $out"
  printf '%s' "$out" | grep -q 'DEFECT - waiting with no applicable durable artifact (0)' \
    || fail "sections: the gap was counted as a defect: $out"
  printf '%s' "$out" | grep -q 'could-not-observe' \
    || fail "sections: the summary line does not count it separately: $out"
  # Headings existing is not the property. The property is WHICH SECTION THE ROW
  # LANDS IN, so read the section bodies and check membership. An earlier version
  # of this control only asserted that the headings were present, and a mutation
  # that rendered the gap under the defect heading as well passed it unchanged.
  defect_body=$(printf '%s\n' "$out" | awk '/^DEFECT - /{f=1;next} /^COULD NOT OBSERVE/{f=0} f')
  printf '%s' "$defect_body" | grep -q 'unknown-state' \
    && fail "sections: the gap was rendered inside the defect section: $out"
  gap_body=$(printf '%s\n' "$out" | awk '/^COULD NOT OBSERVE/{f=1;next} /^SATISFIED/{f=0} f')
  printf '%s' "$gap_body" | grep -q 'unknown-state' \
    || fail "sections: the gap was not rendered in its own section: $out"
  # The empty sections must still print, or "nothing here" and "nobody looked"
  # become the same output.
  printf '%s' "$out" | grep -q 'SATISFIED (0)' \
    || fail "sections: an empty section vanished instead of reporting zero: $out"
  pass "sections: could-not-observe is counted and sectioned apart from defects"
}

test_inbound_sender_must_be_exactly_one_closed_value() {
  local lib out
  lib="$ROOT/bin/fm-outbound-artifact-lib.sh"
  # Watched red in both directions. The malformed value from the live incident
  # carries the valid role as a PREFIX, so anything less than whole-value
  # equality accepts it and lets a body addressed elsewhere wake this fleet.
  out=$(
    # shellcheck disable=SC1090
    . "$lib"
    for body in \
      'from: browser-sol' \
      'from:   browser-sol   '
    do
      fm_outbound_sender_valid "$body" browser-sol || printf 'REJECTED-VALID:%s\n' "$body"
    done
    for body in \
      'from: browser-sol-recipient: firstmate' \
      'from: browser-solo' \
      'from: firstmate' \
      'from: nobody' \
      'verdict: approved' \
      'from: browser-sol
from: firstmate' \
      'from: browser-sol
from: browser-sol'
    do
      fm_outbound_sender_valid "$body" browser-sol && printf 'ACCEPTED-INVALID:%s\n' "$body"
    done
    printf 'done\n'
  )
  printf '%s' "$out" | grep -q 'REJECTED-VALID' \
    && fail "sender: a well-formed sender was refused: $out"
  printf '%s' "$out" | grep -q 'ACCEPTED-INVALID' \
    && fail "sender: an invalid sender was accepted: $out"
  printf '%s' "$out" | grep -q '^done$' \
    || fail "sender: the control did not run to completion: $out"
  pass "sender: exactly one whole-value closed-enum sender, prefix and duplicate refused"
}

test_inbound_ruling_with_wrong_sender_wakes_nothing() {
  local dir rid out rc state
  # End to end, not just the predicate: a ruling whose sender is firstmate must
  # not advance the request. An unidentified instruction waking nothing is the
  # only safe thing it can do.
  dir=$(new_case csender)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "sender e2e: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 563 approved firstmate
  out=$(run_ob "$dir" ruling --request "$rid" --comment 563 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "sender e2e: invalid sender was not could-not-observe, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_SENDER_INVALID' \
    || fail "sender e2e: the refusal was not named: $out"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "emitted" ] \
    || fail "sender e2e: the request advanced to '$state' despite an invalid sender"
  # The non-vacuity half: the SAME request accepts a correctly-sent ruling, so
  # this control cannot pass by refusing everything.
  write_ruling "$dir" "$rid" 564 approved
  run_ob "$dir" ruling --request "$rid" --comment 564 --issue 2 >/dev/null 2>&1 \
    || fail "sender e2e: a correctly-sent ruling was also refused"
  [ "$(run_ob "$dir" show "$rid" | jq -r '.state')" = "ruled" ] \
    || fail "sender e2e: a valid ruling did not advance the request"

  dir=$(new_case csender-poll)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "sender poll: emit failed"
  rid=$(emitted_request_id "$dir")
  write_ruling "$dir" "$rid" 565 approved firstmate
  out=$(run_ob "$dir" poll 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "sender poll: invalid sender was not could-not-observe, exit $rc: $out"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "emitted" ] \
    || fail "sender poll: request advanced to '$state' despite an invalid sender"
  pass "sender e2e: a wrong sender wakes nothing, a right one still does"
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

test_reconcile_reports_the_emit_status_it_produced() {
  # THE STATUS MUST COME FROM THE STAGE THAT PRODUCED IT. The emit refuses here
  # with could-not-observe (4) after exhausting its transport attempts. If
  # reconcile reads its status from the wrong place, that refusal is discarded
  # and the still-unsatisfied row is reported by the following sweep as a proven
  # defect (3) - the exact 3-versus-4 collapse this command exists to refuse,
  # reached through its own plumbing rather than through an observation.
  local dir out rc
  dir=$(new_case cadence-emit-status)
  printf '99\n' > "$dir/forge/fail_remaining"
  out=$(run_ob "$dir" reconcile 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "cadence: reconcile reported $rc for an emit that could not observe: $out"
  printf '%s' "$out" | grep -q 'transport failed after' \
    || fail "cadence: reconcile discarded the emit's own refusal: $out"
  pass "cadence: reconcile reports the emit's own verdict, never the next sweep's"
}

test_reconcile_reports_every_item_after_one_refuses() {
  # EARLY EXIT MAY STOP WORK; IT MAY NEVER SUPPRESS THE REPORT ABOUT WORK ALREADY
  # DONE. Two waiting items, the first of which exhausts its transport and
  # refuses. Before this control the refusal exited the shell, so the final
  # sweep and the whole OUTBOUND report never ran - and at status 3
  # bin/fm-bootstrap.sh prints no relay line of its own, so session start showed
  # an un-prefixed reason and no OUTBOUND: token at all, which is the token the
  # handling skill is loaded on. One item's refusal must not blind the operator
  # to every other item.
  local dir out rc posts
  dir=$(new_case cadence-partial)
  jq '.backlog.records += [(.backlog.records[0] | .order = 3 | .id = "waiting-item-two")]' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  printf '3\n' > "$dir/forge/fail_remaining"
  out=$(run_ob "$dir" reconcile 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "cadence partial: worst-of status was $rc, not the refused emit's 4: $out"
  printf '%s' "$out" | grep -q 'transport failed after' \
    || fail "cadence partial: the refusal's own reason was lost: $out"
  printf '%s' "$out" | grep -q 'OUTBOUND: reconciliation refused an emit (status 4)' \
    || fail "cadence partial: the refusal produced no OUTBOUND-prefixed line: $out"
  printf '%s' "$out" | grep -q '^OUTBOUND: waiting-item ' \
    || fail "cadence partial: the report was suppressed by one item's refusal: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] \
    || fail "cadence partial: reconcile stopped instead of attempting the second item ($posts posts)"
  pass "cadence partial: a refused emit still leaves a complete report for every other item"
}

test_reconcile_releases_every_emit_lock() {
  # cmd_emit takes a per-request lock. Under reconcile it is called once per
  # waiting item in ONE process, so a lock released only at process exit leaves
  # every item but the last holding its lock forever. Recovery still works - a
  # lock held by a dead pid is stolen - so the symptom is silent accumulation
  # rather than a hang, which is why it is asserted rather than trusted. Two
  # waiting items, because one cannot show the difference.
  local dir out rc leftover posts
  dir=$(new_case cadence-locks)
  jq '.backlog.records += [(.backlog.records[0] | .order = 3 | .id = "waiting-item-two")]' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" reconcile 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "cadence locks: reconcile did not satisfy both waits, exit $rc: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 2 ] || fail "cadence locks: reconcile posted $posts requests, expected two"
  leftover=$(find "$dir/home/data/outbound-artifacts" -maxdepth 1 -name '.*.lock' 2>/dev/null | wc -l)
  [ "$leftover" -eq 0 ] \
    || fail "cadence locks: reconcile left $leftover emit lock(s) behind"
  pass "cadence locks: every emit releases its own lock rather than waiting for process exit"
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
  # The branch this row is about. Without it the sweep cannot bind an exact head
  # at all, so it never reaches the pull-request probe - and this case would be
  # asserting an unbindable identity while claiming to assert a missing pull
  # request. A MISSING artifact is only provable once the head is observable.
  git -C "$dir/home/projects/demo" branch "fm/waiting-item" "$HEAD_A"
  : > "$dir/forge/post_log"
  out=$(run_ob "$dir" reconcile 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "cadence: detect-only missing PR did not remain red: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "cadence: red for a reason other than the missing pull request: $out"
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
  printf 'decision: rejected\n' >> "$dir/forge/ruling_body"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 561 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "verdict: an ambiguous body was resolved rather than refused, exit $rc: $out"
  printf '%s' "$out" | grep -q '2 decision lines' \
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
  grep -v '^decision: ' "$dir/forge/ruling_body" > "$dir/forge/ruling_body.x"
  mv "$dir/forge/ruling_body.x" "$dir/forge/ruling_body"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 563 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "verdict: a body with no verdict was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q '0 decision lines' \
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
  sed "1s/^.*$/FM-SOL-RULING $rid/" "$dir/forge/last_request_body" \
    | grep -v '^from:' > "$dir/forge/ruling_body"
  printf 'from: browser-sol\nverdict: accepted\n' >> "$dir/forge/ruling_body"
  printf '570\n' > "$dir/forge/ruling_id"
  out=$(run_ob "$dir" poll 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "legacy ruling: non-authoritative rendering returned $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_LEGACY_NONAUTHORITATIVE' \
    || fail "legacy ruling: refusal was not explicit and named: $out"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "emitted" ] || fail "legacy ruling: marker rendering advanced state to $state"

  write_ruling "$dir" "$rid" 570 accepted
  run_ob "$dir" poll >/dev/null 2>&1 \
    || fail "legacy ruling: paired typed envelope was refused"
  state=$(run_ob "$dir" show "$rid" | jq -r '.state')
  [ "$state" = "ruled" ] || fail "legacy ruling: typed envelope left state $state"
  pass "legacy ruling: marker rendering is diagnosed but cannot transition, while typed input can"
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
  # The SWEEP has to keep the same two answers apart that emit and ruling do. A
  # record that is perfectly readable and says it belongs to another request is
  # a correlation defect with a known repair, not an unreadable file; reported
  # as unreadable it sends the operator looking for corruption or permissions
  # that are not there.
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "correlation: sweep did not report a foreign keyed record as a defect, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_IDENTITY_REFUSED' \
    || fail "correlation: sweep did not name the foreign keyed record as an identity refusal: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RECORD_UNREADABLE' \
    && fail "correlation: sweep reported a readable foreign record as unreadable: $out"
  # This branch is reached only after the artifact was OBSERVED, so describing
  # it as absent would be false in the same way the unreadable collapse was.
  printf '%s' "$out" | grep -q 'artifact: comment/' \
    || fail "correlation: the row rendered an observed artifact as none: $out"
  # A heading has to be true of every row beneath it. Filing an observed
  # artifact under a heading that asserts its absence puts the two renderers in
  # contradiction about the same row, which is the misdescription this split
  # exists to remove rather than to relocate.
  printf '%s' "$out" | grep -q 'DEFECT - waiting with no applicable durable artifact (0)' \
    || fail "correlation: an observed artifact was counted under the missing-artifact heading: $out"
  printf '%s' "$out" | grep -q 'DEFECT - the artifact exists, but the correlation record filed under its request id names a different request (1)' \
    || fail "correlation: the identity refusal had no heading true of it: $out"
  out=$(run_ob "$dir" defects 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "correlation: the relay line did not carry the defect verdict, exit $rc: $out"
  printf '%s' "$out" | grep -q 'no applicable durable artifact' \
    && fail "correlation: an observed artifact was relayed as missing: $out"
  printf '%s' "$out" | grep -q 'has its artifact comment/' \
    || fail "correlation: the relay did not name the artifact it observed: $out"
  printf '%s' "$out" | grep -q 'names a DIFFERENT request' \
    || fail "correlation: the relay did not say what was actually refused: $out"
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
  # EMITTING and OBSERVING ask different questions of the same binding, so they
  # get different answers. Emit is an ACTION: a request cannot be constructed
  # without a head, so it refuses at 3 and the item stays red. Check is an
  # OBSERVATION: the head could not be READ, so the sweep never looked at the
  # forge and may not report an absence. It reaches 4, which is still not clean
  # and still not zero.
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "control 8: the unbindable item did not stay non-clean, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_HEAD_UNOBSERVED' \
    || fail "control 8: an unreadable head was not reported as unobserved: $out"
  pass "control 8: an incomplete binding refuses to emit and leaves the item non-clean"
}

# A sweep that holds BOTH answers. This is the case the exit fold was skipping:
# sweep_exit tested `defects` first and returned, so `unevaluable` was never
# consulted and the command reported 3 - the fleet is provably wrong - while the
# module's own severity order, written directly above that function, makes the
# honest answer 4. A caller reading only the exit status is exactly the caller
# the file header invites, and it was being told the wrong one of the two.
#
# An unevaluable-ONLY sweep already reached 4 before this fix, so it cannot be
# the red control: only the mixed sweep can distinguish the fold from the ladder.
test_exit_status_is_the_declared_fold_not_a_defect_shortcut() {
  local dir out rc json defects unevaluable
  dir=$(new_case exit-fold)
  # The could-not-observe half: a free-form backlog row carries no typed state,
  # so the recognizer genuinely cannot say whether it is waiting.
  jq '.backlog.records += [{order:3,state:"queued",structured:false,
        id:"free-form-row",title:null,hold_kind:null,hold_reason:null,
        repo:"demo",pr_url:null,body_excerpt:null}]' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"

  json=$(run_ob "$dir" check --json 2>/dev/null)
  defects=$(printf '%s' "$json" | jq '[.rows[] | select(.verdict=="defect")] | length')
  unevaluable=$(printf '%s' "$json" | jq '[.rows[] | select(.verdict=="unevaluable")] | length')
  # Non-vacuity: this case proves nothing unless the sweep really does hold both.
  [ "$defects" -ge 1 ] \
    || fail "exit fold: the fixture produced no defect row, so the fold is untested ($json)"
  [ "$unevaluable" -ge 1 ] \
    || fail "exit fold: the fixture produced no could-not-observe row, so the fold is untested ($json)"

  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "exit fold: $defects defect + $unevaluable could-not-observe exited $rc, not the folded 4: $out"
  # The 4 must not have cost the defect its own report.
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "exit fold: folding to 4 lost the defect's line: $out"

  # NON-VACUITY, the other direction: a defect with nothing unobserved beside it
  # still drives the exit, and still drives it to 3 rather than being folded away.
  write_snapshot "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] \
    || fail "exit fold: a defect-only sweep no longer exits 3, got $rc: $out"
  pass "exit fold: the exit is the module's severity fold over both counts, not a defect shortcut"
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

# An exact head that could not be READ is a failed observation, and a failed
# observation may not be rendered as an observed absence. The sweep asked the
# declaration, the forge and the clone; none answered; it never looked at the
# forge for an artifact at all. Reporting that as "no applicable durable
# artifact" derives a claim about the forge from a failed local read - while
# three sibling tokens naming the identical condition all reach unevaluable.
#
# The three arms below are one control: the head-only case must move, and the
# two structural cases must NOT, or the repair is just a quieter sweep.
test_unreadable_head_is_could_not_observe_not_an_absent_artifact() {
  local dir out rc json verdict
  dir=$(new_case head-unreadable)
  # A TYPED gate, so the head is the only thing the binding lacks. The gate file
  # declares no head on purpose, and the forge answers nothing for the pull
  # request, and the clone carries no fm/waiting-item ref.
  write_snapshot "$dir/snap.json" outbound "awaiting Browser Sol"
  mkdir -p "$dir/home/data/waiting-item"
  jq -n '{gate:"AWAITING_BROWSER_SOL"}' > "$dir/home/data/waiting-item/outbound-gate.json"
  : > "$dir/forge/head"

  json=$(run_ob "$dir" check --json 2>/dev/null)
  [ "$(printf '%s' "$json" | jq -r '[.rows[] | select(.item=="waiting-item")] | length')" -eq 1 ] \
    || fail "unreadable head: the fixture did not produce exactly one row for the item: $json"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.item=="waiting-item") | .missing')" = head ] \
    || fail "unreadable head: the fixture left more than the head unbound, so it tests the wrong case: $json"
  verdict=$(printf '%s' "$json" | jq -r '.rows[] | select(.item=="waiting-item") | .verdict')
  [ "$verdict" = unevaluable ] \
    || fail "unreadable head: classified as '$verdict', not could-not-observe: $json"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.item=="waiting-item") | .token')" \
    = FM_OUTBOUND_HEAD_UNOBSERVED ] \
    || fail "unreadable head: wrong token: $json"

  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "unreadable head: exited $rc rather than could-not-observe: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_INCOMPLETE_BINDING' \
    && fail "unreadable head: still rendered as an incomplete binding: $out"
  # The RENDERED sentence, not just the token. The defect wording and the
  # unobserved token contradicted each other inside a single line, and an
  # operator acts on the sentence.
  printf '%s' "$out" | grep -q 'could not be READ' \
    || fail "unreadable head: the line does not say the head could not be read: $out"
  out=$(run_ob "$dir" defects 2>&1)
  printf '%s' "$out" | grep -q 'waiting-item.*no applicable durable artifact' \
    && fail "unreadable head: the relay still asserts an absent artifact: $out"
  printf '%s' "$out" | grep -q 'NOT reporting that none exists' \
    || fail "unreadable head: the relay line does not refuse the absence claim: $out"

  # NON-VACUITY 1: a structurally absent field is still a defect, even when the
  # head is unreadable too. A read that succeeded and found no gate is not the
  # same fact as a read that failed.
  dir=$(new_case head-unreadable-and-untyped)
  write_snapshot "$dir/snap.json" outbound "awaiting Browser Sol"
  mkdir -p "$dir/home/data/waiting-item"
  jq -n '{gate:"NOT_A_GATE"}' > "$dir/home/data/waiting-item/outbound-gate.json"
  : > "$dir/forge/head"
  json=$(run_ob "$dir" check --json 2>/dev/null)
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.item=="waiting-item") | .verdict')" = defect ] \
    || fail "untyped and headless: no longer a defect, which is a quieter sweep: $json"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.item=="waiting-item") | .token')" \
    = FM_OUTBOUND_INCOMPLETE_BINDING ] \
    || fail "untyped and headless: wrong token: $json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "untyped and headless: exited $rc rather than defect: $out"

  # NON-VACUITY 2: a structurally absent field with a perfectly readable head is
  # untouched by the split.
  dir=$(new_case untyped-readable-head)
  write_snapshot "$dir/snap.json" outbound "awaiting Browser Sol"
  mkdir -p "$dir/home/data/waiting-item"
  jq -n --arg h "$HEAD_A" '{gate:"NOT_A_GATE",head:$h}' \
    > "$dir/home/data/waiting-item/outbound-gate.json"
  json=$(run_ob "$dir" check --json 2>/dev/null)
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.item=="waiting-item") | .missing')" = gate ] \
    || fail "untyped with a readable head: the fixture is not the structural case: $json"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.item=="waiting-item") | .verdict')" = defect ] \
    || fail "untyped with a readable head: no longer a defect: $json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "untyped with a readable head: exited $rc rather than defect: $out"
  pass "unreadable head: an unread head is could-not-observe, while a structurally absent field stays a defect"
}

# Every other *_UNOBSERVED token in this vocabulary reaches unevaluable. The one
# that did not was the defect. This pins the class rather than the instance, so
# a future token cannot re-enter through the same door.
test_no_unobserved_token_is_ever_rendered_as_a_defect() {
  local dir json offenders
  dir=$(new_case unobserved-class)
  write_snapshot "$dir/snap.json" outbound "awaiting Browser Sol"
  mkdir -p "$dir/home/data/waiting-item"
  jq -n '{gate:"AWAITING_BROWSER_SOL"}' > "$dir/home/data/waiting-item/outbound-gate.json"
  : > "$dir/forge/head"
  json=$(run_ob "$dir" check --json 2>/dev/null)
  # Non-vacuity: the sweep must actually carry an *_UNOBSERVED row.
  [ "$(printf '%s' "$json" | jq '[.rows[] | select(.token | test("_UNOBSERVED$"))] | length')" -ge 1 ] \
    || fail "unobserved class: no *_UNOBSERVED row was produced, so this control measured nothing: $json"
  offenders=$(printf '%s' "$json" | jq -r \
    '[.rows[] | select(.verdict=="defect") | select(.token | test("_UNOBSERVED$")) | .token] | join(",")')
  [ -z "$offenders" ] \
    || fail "unobserved class: a could-not-observe token was rendered as a defect: $offenders"
  pass "unobserved class: no *_UNOBSERVED token reaches a defect verdict"
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
  # Named as ambiguity rather than as an unobserved artifact. Both refuse, but
  # only one is true: the forge answered, and it answered with two candidates.
  # Reported as a gap, the operator debugs a probe that worked fine.
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_AMBIGUOUS_CANDIDATES' \
    || fail "PR duplicate head: several candidates were not classified as ambiguous: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_ARTIFACT_UNOBSERVED' \
    && fail "PR duplicate head: a readable forge was reported as unobserved: $out"
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
  [ "$rc" -eq 4 ] || fail "forge error: expected could-not-observe, got $rc: $out"
  printf '%s' "$out" | grep -q 'Not Found' \
    && fail "forge error: a 404 body was carried forward as the exact head: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_HEAD_UNOBSERVED' \
    || fail "forge error: not reported as an unobserved head: $out"
  # A failed read is not evidence about the forge. The verdict must be the third
  # value, not the defect one: nothing here establishes that no artifact exists.
  printf '%s' "$out" | grep -q 'COULD NOT OBSERVE' \
    || fail "forge error: an unobserved head was not sectioned as could-not-observe: $out"
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

test_forge_observed_head_need_not_exist_locally() {
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  local remote_head
  remote_head=$(printf '%040d' 0 | tr 0 c)
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i \
    "$remote_head" "$HEAD_REPO" forge >/dev/null 2>&1 \
    || fail "forge head: an authoritative exact PR head was required to exist locally"
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i \
    "$remote_head" "$HEAD_REPO" local >/dev/null 2>&1 \
    && fail "forge head: local provenance bypassed object resolution"
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i \
    "${remote_head}c" "$HEAD_REPO" forge >/dev/null 2>&1 \
    && fail "forge head: authoritative provenance bypassed repository-specific width"
  pass "forge head: authoritative PR heads keep strict width without local resolution"
}

test_forge_head_provenance_survives_record_lifecycle() {
  local dir remote_head rid rec out rc
  dir=$(new_case forge-record-head)
  remote_head=$(printf '%040d' 0 | tr 0 d)
  set_head "$dir" "$remote_head"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
    || fail "forge record: initial emit rejected the unfetched PR head"
  rid=$(emitted_request_id "$dir")
  rec=$(run_ob "$dir" show "$rid") \
    || fail "forge record: persisted correlation could not be reread"
  [ "$(printf '%s' "$rec" | jq -r '.identity.head_source')" = forge ] \
    || fail "forge record: persisted correlation lost forge provenance"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'already requested'; then
    :
  else
    fail "forge record: deduplication could not reread the correlation: $out"
  fi
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "forge record: sweep rejected the correlation: $out"
  write_ruling "$dir" "$rid" 556
  run_ob "$dir" ruling --request "$rid" --comment 556 --issue 2 >/dev/null 2>&1 \
    || fail "forge record: ruling could not reread the correlation"
  run_ob "$dir" resume --request "$rid" >/dev/null 2>&1 \
    || fail "forge record: resume could not reread the correlation"
  pass "forge record: provenance survives dedupe, sweep, ruling, and resume"
}

# --- vocabulary properties ----------------------------------------------------

test_every_declared_token_has_an_emit_site() {
  # The lib presents its FM_OUTBOUND_TOKEN_* block as the closed vocabulary of
  # answers this mechanism can give, and its header states that every token in
  # the block has an emit site. This is what makes that statement true rather
  # than aspirational.
  #
  # Nothing else can check it. The dead-predicate control scans function
  # definitions for call sites, so a CONSTANT that is declared and never
  # expanded is outside its universe by construction, not by oversight - and two
  # tokens were already dead this way while the conditions they name were being
  # reported under a neighbouring token, so the classification was wrong rather
  # than merely missing.
  #
  # Deliberately module-local: it reads THIS block out of THIS lib and searches
  # only the two files that implement this mechanism. The general form - every
  # declared vocabulary in the repository - belongs with the dead-predicate
  # control and is filed separately as dead-token-detection.
  local lib="$ROOT/bin/fm-outbound-artifact-lib.sh"
  local cmd="$ROOT/bin/fm-outbound-artifact.sh"
  local names name count dead=
  names=$(sed -n 's/^\(FM_OUTBOUND_TOKEN_[A-Z0-9_]*\)=.*/\1/p' "$lib")
  # An empty vocabulary would pass the loop below while measuring nothing, which
  # is the vacuous-control failure this suite exists to refuse.
  [ -n "$names" ] \
    || fail "token vocabulary: no token declarations were read from $lib, so this control measured nothing"
  for name in $names; do
    # An emit site is an EXPANSION - $NAME or ${NAME} - so a declaration can
    # never satisfy its own check, and the trailing boundary keeps one token
    # from being satisfied by a longer token that starts with its name.
    grep -qE '\$\{?'"$name"'([^A-Za-z0-9_]|$)' "$lib" "$cmd" || dead="$dead $name"
  done
  # Every violation by name in one failure: a reader learns the full set from a
  # single run rather than rediscovering it one token per run.
  [ -z "$dead" ] \
    || fail "token vocabulary: declared and never emitted:$dead"
  count=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
  pass "token vocabulary: all $count declared tokens have an emit site"
}

# --- the governed subject is not the transport venue -------------------------
#
# THE DEFECT, RULED THREE TIMES. Requests fm-ob-6267e1c729b9,
# fm-ob-26660534cd52 and fm-ob-7804557b2dfe each persisted
# `repo: sbracewell64/firstmate-sol-control` - the CONTROL issue's own
# repository - while binding a head that exists only in the governed repository
# the work lives in. Browser Sol ruled all three non-actionable in the same
# words: a repository/head tuple that cannot identify one real subject is not a
# request. The producer had been reading its transport venue as its subject.
#
# The controls below are built on that exact shape, and every refusal is
# asserted to happen with the record store and the forge both untouched -
# "refuse before durable actionable request and before waiting-state
# transition" is the requirement, and a refusal that already wrote something
# would not meet it.

# A demo clone that knows one governed repository, distinct from the control
# venue the fixtures already configure at o/control.
declare_subject() {  # <case-dir> <gate> <head> [<repo>] [<tree>] [<policy>]
  local dir=$1 gate=$2 head=$3 repo=${4:-} tree=${5:-} policy=${6:-}
  mkdir -p "$dir/home/data/waiting-item"
  jq -n --arg g "$gate" --arg h "$head" --arg r "$repo" --arg t "$tree" --arg p "$policy" \
    '{gate:$g,head:$h}
     + (if $r == "" then {} else {repo:$r} end)
     + (if $t == "" then {} else {tree:$t} end)
     + (if $p == "" then {} else {policy_generation:$p} end)' \
    > "$dir/home/data/waiting-item/outbound-gate.json"
}

prepare_subject_case() {  # <name> -> case dir
  local dir
  dir=$(new_case "$1")
  # The clone is created by `git clone` from a local path, so its origin names a
  # directory rather than a repository. Point it at the governed repository the
  # cases declare, so the clone can actually answer whether it knows that
  # subject; the remote-tracking refs the heads resolve against already exist.
  git -C "$dir/home/projects/demo" remote set-url origin https://github.com/o/demo.git
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  printf '%s\n' "$dir"
}

store_size() {  # <case-dir>
  find "$1/home/data/outbound-artifacts" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l
}

test_a_request_refuses_before_it_can_name_a_transport_venue_as_its_subject() {
  local dir shape out rc records posts head rid
  # WATCHED RED ON THE HISTORICAL SHAPE ITSELF, plus every neighbouring way a
  # subject can fail to identify one real thing. Each asserts the store and the
  # forge are exactly as they were, because the ruling requires the refusal to
  # land before any durable effect rather than after one.
  for shape in venue-as-subject unknown-repository contradicting-remotes malformed-repository \
               contradicting-tree; do
    dir=$(prepare_subject_case "subject-$shape")
    head=$HEAD_A
    case $shape in
      # THE EXACT DEFECT: the control repository named as the subject.
      venue-as-subject)      declare_subject "$dir" AWAITING_BROWSER_SOL "$head" o/control ;;
      unknown-repository)    declare_subject "$dir" AWAITING_BROWSER_SOL "$head" o/nothing-here ;;
      # NOTHING DECLARED AND THE CLONE NAMES TWO REPOSITORIES. This is the live
      # shape in the FirstMate home itself, which carries both a fork and the
      # upstream it was forked from. The venue rule prefers upstream, so a
      # producer that derived silently would have emitted a governed request
      # against the maintainer's repository - a repository nobody chose.
      contradicting-remotes)
        git -C "$dir/home/projects/demo" remote add upstream https://github.com/o/other.git
        declare_subject "$dir" AWAITING_BROWSER_SOL "$head" ;;
      malformed-repository)  declare_subject "$dir" AWAITING_BROWSER_SOL "$head" 'not-a-slug' ;;
      contradicting-tree)    declare_subject "$dir" AWAITING_BROWSER_SOL "$head" o/demo "$HEAD_B" ;;
    esac
    records=$(store_size "$dir"); posts=$(wc -l < "$dir/forge/post_log")
    out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
    [ "$rc" -ne 0 ] \
      || fail "subject/$shape: a request without a validated governed subject was emitted: $out"
    [ "$(store_size "$dir")" -eq "$records" ] \
      || fail "subject/$shape: a durable record was created by a refused request"
    [ "$(wc -l < "$dir/forge/post_log")" -eq "$posts" ] \
      || fail "subject/$shape: a refused request still reached the forge"
    case $shape in
      venue-as-subject)
        printf '%s' "$out" | grep -q 'subject-repo-is-transport-venue' \
          || fail "subject/$shape: the historical defect was not refused by name: $out" ;;
      unknown-repository)
        printf '%s' "$out" | grep -q 'subject-repo-unknown-to-clone' \
          || fail "subject/$shape: an unresolvable repository was not named: $out" ;;
      contradicting-remotes)
        printf '%s' "$out" | grep -q 'subject-repo-ambiguous' \
          || fail "subject/$shape: a clone naming two repositories was not refused by name: $out" ;;
      malformed-repository)
        printf '%s' "$out" | grep -q 'subject-repo-malformed' \
          || fail "subject/$shape: a subject that is not a repository name was not named: $out" ;;
      contradicting-tree)
        printf '%s' "$out" | grep -q 'subject-tree-not-of-head' \
          || fail "subject/$shape: a tree that is not the head's was not named: $out" ;;
    esac
  done

  # PAIRED GREEN FOR THE AMBIGUITY RULE. The same undeclared case, with the
  # clone naming exactly one repository, is an OBSERVATION rather than a guess,
  # so it emits and records that repository as the subject. Without this half
  # the rule above would be satisfied by refusing every derived subject.
  dir=$(prepare_subject_case subject-derived)
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A"
  posts=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "subject derived: one unambiguous remote was refused, exit $rc: $out"
  [ "$(posts_since "$dir" "$posts")" -eq 1 ] \
    || fail "subject derived: expected exactly one logical request"
  rid=$(printf '%s' "$out" | sed -n 's/^requested: \([^ ]*\).*/\1/p')
  [ "$(jq -r '.identity.repo' "$dir/home/data/outbound-artifacts/$rid.json")" = o/demo ] \
    || fail "subject derived: the clone's own repository was not recorded as the subject"

  # PAIRED GREEN: the same fixture with a validated governed subject and a
  # separate transport venue emits exactly one request, and the identity it
  # records is the SUBJECT repository while the venue stays transport metadata.
  dir=$(prepare_subject_case subject-valid)
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/demo \
    "$(git -C "$dir/home/projects/demo" rev-parse "$HEAD_A^{tree}")" pol-2026-08-23-g1
  posts=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "subject valid: a validated governed subject was refused, exit $rc: $out"
  [ "$(posts_since "$dir" "$posts")" -eq 1 ] \
    || fail "subject valid: expected exactly one logical request"
  rid=$(printf '%s' "$out" | sed -n 's/^requested: \([^ ]*\).*/\1/p')
  [ "$(jq -r '.identity.repo' "$dir/home/data/outbound-artifacts/$rid.json")" = o/demo ] \
    || fail "subject valid: the identity did not record the governed subject repository"
  [ "$(jq -r '.venue' "$dir/home/data/outbound-artifacts/$rid.json")" = 'o/control#2' ] \
    || fail "subject valid: the transport venue was not kept as venue metadata"
  [ "$(jq -r '.identity.policy' "$dir/home/data/outbound-artifacts/$rid.json")" = pol-2026-08-23-g1 ] \
    || fail "subject valid: the policy generation is not part of the recorded identity"
  pass "subject: a venue, unknown, ambiguous, malformed or self-contradicting subject refuses before any durable effect, and a validated one emits once"
}

test_a_moved_policy_generation_is_a_different_question() {
  local dir first second out rc expected
  # STALE POLICY OR TREE CANNOT ANSWER A SUCCESSOR. Both are part of the
  # identity, so a request under a superseded policy generation is a different
  # request - which is what stops a finished one being handed back.
  dir=$(prepare_subject_case subject-policy)
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/demo "" pol-g1
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "policy: first emit failed"
  first=$(awk '{print $2}' "$dir/forge/comments" | tail -1)
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/demo "" pol-g2
  write_typed_ruling "$dir" "$first" waiting-item "$HEAD_A" 74 approved
  out=$(run_ob "$dir" ruling --request "$first" --comment 74 --issue 2 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "policy: a ruling joined after its policy generation moved: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$first.json")" = superseded ] \
    || fail "policy: ruling-time freshness left the old policy request live"
  expected=$(jq -r '.superseded_by' "$dir/home/data/outbound-artifacts/$first.json")
  [ -n "$expected" ] && [ "$expected" != null ] \
    || fail "policy: ruling-time freshness did not link the successor identity"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "policy: second emit failed"
  second=$(awk '{print $2}' "$dir/forge/comments" | tail -1)
  [ -n "$first" ] && [ "$first" != "$second" ] \
    || fail "policy: a moved policy generation reused the previous identity ($first)"
  # And the predecessor is retired rather than left applicable beside it.
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$first.json")" = superseded ] \
    || fail "policy: the previous policy generation's request stayed live"
  [ "$expected" = "$second" ] \
    || fail "policy: freshness linked $expected but the canonical successor is $second"
  pass "policy: a moved policy generation asks its own question and retires its predecessor"
}

test_an_undecidable_subject_is_could_not_observe_rather_than_a_defect() {
  local dir out rc
  # THE THREE-VALUE RULE, ON THE SUBJECT. A subject that is positively wrong is
  # a defect. A subject that is merely UNDECIDED is not: with two repositories
  # named and nothing declaring which one the review governs, the sweep cannot
  # compute the identity an artifact would carry, so it never looked for one.
  # Calling that a defect would assert the invariant is violated on the strength
  # of a read that did not happen - the exact conversion this module exists to
  # remove.
  dir=$(prepare_subject_case subject-undecidable)
  git -C "$dir/home/projects/demo" remote add upstream https://github.com/o/other.git
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "undecidable subject: expected could-not-observe, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_SUBJECT_UNRESOLVED' \
    || fail "undecidable subject: the unresolved subject was not named: $out"
  printf '%s' "$out" | sed -n '/^DEFECT/,/^$/p' | grep -q 'waiting-item' \
    && fail "undecidable subject: an unread question was reported as a violation: $out"

  # PAIRED HALF: remove the ambiguity and the same fixture reaches a verdict.
  # Without this the rule above is satisfied by never deciding anything.
  git -C "$dir/home/projects/demo" remote remove upstream
  out=$(run_ob "$dir" check 2>&1)
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_SUBJECT_UNRESOLVED' \
    && fail "undecidable subject: one unambiguous remote still refused to decide: $out"
  pass "subject: an undecidable subject is could-not-observe, and one unambiguous remote decides"
}
test_an_undecidable_subject_is_could_not_observe_rather_than_a_defect
test_a_malformed_request_is_retired_through_the_owner_and_never_resurrected() {
  local dir rid out rc before records posts
  # THE OWNER RETIRES IT; NOTHING HAND-EDITS IT. The ruling forbids editing a
  # malformed request into validity and equally forbids leaving it sustaining a
  # wait, so the owner marks it terminal and records under which ruling.
  dir=$(prepare_subject_case subject-quarantine)
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/demo
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "quarantine: emit failed"
  rid=$(awk '{print $2}' "$dir/forge/comments" | tail -1)
  [ -n "$rid" ] || fail "quarantine: no request was recorded"
  before=$(jq -r '.identity.head + " " + (.comment_id // "-")' "$dir/home/data/outbound-artifacts/$rid.json")

  out=$(run_ob "$dir" quarantine --request "$rid" --ruling comment/5387155383 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "quarantine: the owner could not retire the request, exit $rc: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = quarantined \
    ] || fail "quarantine: the record was not retired"
  # EVIDENCE PRESERVED. Retiring is not erasing: identity and artifact stay.
  [ "$(jq -r '.identity.head + " " + (.comment_id // "-")' "$dir/home/data/outbound-artifacts/$rid.json")" = "$before" ] \
    || fail "quarantine: retiring the request altered its evidence"
  printf '%s' "$(jq -r '.disposition' "$dir/home/data/outbound-artifacts/$rid.json")" \
    | grep -q '5387155383' \
    || fail "quarantine: the ruling that retired the request was not recorded"

  # IT CANNOT SATISFY THE WAIT ANY MORE. The item goes back to having no
  # applicable artifact, which is the honest red state - not a wait quietly
  # resting on a request that was ruled non-actionable.
  out=$(run_ob "$dir" check 2>&1)
  printf '%s' "$out" | sed -n '/^SATISFIED/,$p' | grep -q 'waiting-item' \
    && fail "quarantine: a retired request still satisfied the item: $out"

  # RESTART CANNOT REBUILD IT. Replaying the emit converges on the same refusal
  # rather than reconstructing a wait, and posts nothing.
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/control
  records=$(store_size "$dir"); posts=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "quarantine restart: the malformed shape emitted again: $out"
  [ "$(store_size "$dir")" -eq "$records" ] \
    || fail "quarantine restart: a replay created a durable record"
  [ "$(wc -l < "$dir/forge/post_log")" -eq "$posts" ] \
    || fail "quarantine restart: a replay reached the forge"

  # IDEMPOTENT, and never a way to rewrite a completion.
  out=$(run_ob "$dir" quarantine --request "$rid" --ruling comment/5387155383 2>&1) \
    || fail "quarantine: a repeat retirement errored: $out"
  printf '%s' "$out" | grep -q 'already quarantined' \
    || fail "quarantine: a repeat retirement did not report the existing one: $out"
  pass "quarantine: the owner retires a malformed request, preserves its evidence, and no restart rebuilds its wait"
}

test_a_finished_request_is_annotated_rather_than_relabelled() {
  local dir rid out rc
  # TWO OF THE THREE RULED REQUESTS WERE ALREADY SUPERSEDED. They apply to
  # nothing already, so retiring them again would only overwrite the successor
  # linkage that records which request replaced them. The ruling is recorded and
  # the state is left alone.
  dir=$(prepare_subject_case subject-annotate)
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/demo
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "annotate: emit failed"
  rid=$(awk '{print $2}' "$dir/forge/comments" | tail -1)
  # Move the head so the emit supersedes it, exactly as the live pair were.
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_B" o/demo
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "annotate: successor emit failed"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = superseded \
    ] || fail "annotate: the fixture did not supersede the predecessor"

  out=$(run_ob "$dir" quarantine --request "$rid" --ruling comment/5385612078 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "annotate: recording a ruling on a finished request failed: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = superseded ] \
    || fail "annotate: a finished request was relabelled instead of annotated"
  [ "$(jq -r '.superseded_by' "$dir/home/data/outbound-artifacts/$rid.json")" != null ] \
    || fail "annotate: the successor linkage was destroyed"
  printf '%s' "$(jq -r '.disposition' "$dir/home/data/outbound-artifacts/$rid.json")" \
    | grep -q '5385612078' \
    || fail "annotate: the ruling was not recorded"
  pass "annotate: a already-finished request records its ruling without losing its successor linkage"
}

# --- a moved gate is a new question ------------------------------------------
#
# THE SHAPE THIS REPAIRS, from the live store. fm-ob-25c701e04893 asked
# AWAITING_BROWSER_SOL for candidate-publication-effect-guard at head
# cf4c640b..., was ruled HOLD, was self-handled by the evidence bundle, and was
# CLOSED. The item then moved to EXACT_HEAD_BROWSER_REVIEW_REQUIRED at the SAME
# head - a different question about the same bytes - and emit answered
# "already requested: fm-ob-25c701e04893", handing back a finished correlation
# instead of asking the new question.
#
# Two faults, and both are needed to produce it:
#   the item's typed gate declaration was ignored while its hold-kind was still
#   `external`, so the stale hold sentence recomputed the PREDECESSOR's identity;
#   and the dedupe path adopted a `closed` record, which
#   fm_outbound_applicability has always called inapplicable but which this path
#   never asked about.

prepare_gate_move_case() {  # <name> <declared-gate> <predecessor-state> -> case dir
  local dir=$1 gate=$2 state=$3 rid head
  dir=$(new_case "$1")
  # The row stays `external` with a hold sentence naming the OLD gate, exactly
  # as the live backlog row did.
  write_snapshot "$dir/snap.json" external 'Awaiting Browser Sol exact-head publication ruling'
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "gate move: predecessor emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  [ -n "$rid" ] || fail "gate move: no predecessor was recorded"
  jq --arg s "$state" '.state = $s' "$dir/home/data/outbound-artifacts/$rid.json" > "$dir/tmp.json"
  mv "$dir/tmp.json" "$dir/home/data/outbound-artifacts/$rid.json"
  # The item's declaration moves; its prose does not.
  jq -n --arg g "$gate" --arg h "$head" '{gate:$g,head:$h}' \
    > "$dir/home/data/waiting-item/outbound-gate.json"
  printf '%s %s %s\n' "$dir" "$rid" "$head"
}

test_a_moved_gate_asks_its_own_question() {
  local dir rid head out rc posts before successor live
  # RED FIRST, from the opposite structured state: with the declaration still at
  # the OLD gate, the identity is genuinely unchanged and the finished record
  # must NOT be handed back as an answer.
  read -r dir rid head <<< "$(prepare_gate_move_case gatemove-same AWAITING_BROWSER_SOL closed)"
  [ -n "$dir" ] || fail "gate move: fixture produced no case"
  before=$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")
  posts=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "gate move RED: a closed request answered a fresh one: $out"
  printf '%s' "$out" | grep -q 'closed and cannot answer a new request' \
    || fail "gate move RED: refused for the wrong reason: $out"
  [ "$(posts_since "$dir" "$posts")" -eq 0 ] \
    || fail "gate move RED: a request was posted against a finished correlation"
  [ "$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")" = "$before" ] \
    || fail "gate move RED: the finished record was rewritten"

  # GREEN: the declaration moves to a new gate at the SAME item and head. That
  # is a different question, so it gets its own request - and the closed
  # predecessor is left exactly as it was.
  read -r dir rid head <<< "$(prepare_gate_move_case gatemove-new EXACT_HEAD_BROWSER_REVIEW_REQUIRED closed)"
  before=$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")
  posts=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "gate move GREEN: the new gate was refused, exit $rc: $out"
  [ "$(posts_since "$dir" "$posts")" -eq 1 ] \
    || fail "gate move GREEN: expected exactly one posted request"
  successor=$(printf '%s' "$out" | sed -n 's/^requested: \([^ ]*\).*/\1/p')
  [ -n "$successor" ] && [ "$successor" != "$rid" ] \
    || fail "gate move GREEN: the successor reused the predecessor's identity: $out"
  [ "$(jq -r '.identity.gate' "$dir/home/data/outbound-artifacts/$successor.json")" \
    = EXACT_HEAD_BROWSER_REVIEW_REQUIRED ] \
    || fail "gate move GREEN: the successor is not bound to the declared gate"
  [ "$(jq -r '.identity.head' "$dir/home/data/outbound-artifacts/$successor.json")" = "$head" ] \
    || fail "gate move GREEN: the successor moved the head as well as the gate"
  [ "$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")" = "$before" ] \
    || fail "gate move GREEN: the closed predecessor was rewritten"

  # REPLAY: the same gate, item and head stays idempotent.
  posts=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1) \
    || fail "gate move REPLAY: a repeat cycle errored: $out"
  printf '%s' "$out" | grep -q 'already requested' \
    || fail "gate move REPLAY: the repeat cycle did not report the existing request: $out"
  [ "$(posts_since "$dir" "$posts")" -eq 0 ] \
    || fail "gate move REPLAY: a second request was posted for one identity"
  pass "gate move: a moved gate gets its own request, a finished one answers nothing, and a replay posts nothing"
}

test_a_live_predecessor_is_retired_before_its_successor() {
  local dir rid head out rc successor live
  # NEVER TWO APPLICABLE REQUESTS. When the old gate's request is still LIVE, it
  # is superseded as part of the same emit, so the item is never left with two
  # requests differing only in what they asked.
  read -r dir rid head <<< "$(prepare_gate_move_case gatemove-live EXACT_HEAD_BROWSER_REVIEW_REQUIRED emitted)"
  [ -n "$dir" ] || fail "live predecessor: fixture produced no case"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "live predecessor: the successor was refused, exit $rc: $out"
  printf '%s' "$out" | grep -q "superseded: $rid" \
    || fail "live predecessor: the live old-gate request was not retired: $out"
  printf '%s' "$out" | grep -q 'gate that moved' \
    || fail "live predecessor: the retirement did not name what moved: $out"
  successor=$(printf '%s' "$out" | sed -n 's/^requested: \([^ ]*\).*/\1/p')
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = superseded \
    ] || fail "live predecessor: the predecessor is not superseded"
  # LAWFUL LINKAGE, in both directions of reading: the retired record names the
  # request that replaced it.
  [ "$(jq -r '.superseded_by' "$dir/home/data/outbound-artifacts/$rid.json")" = "$successor" ] \
    || fail "live predecessor: the predecessor does not name its successor"
  live=$(grep -l '"item": "waiting-item"' "$dir/home/data/outbound-artifacts"/*.json 2>/dev/null \
    | xargs -r jq -r 'select(.state != "closed" and .state != "superseded") | .request_id' | tr '\n' ' ')
  [ "$(printf '%s' "$live" | wc -w)" -eq 1 ] \
    || fail "live predecessor: the item was left with more than one live request: $live"
  pass "live predecessor: a live old-gate request is retired and linked, leaving exactly one live request"
}

test_a_typed_gate_declaration_outranks_stale_hold_prose() {
  local lib out
  lib="$ROOT/bin/fm-outbound-artifact-lib.sh"
  # THE UPSTREAM HALF. A hold sentence is written once and rarely rewritten,
  # while the gate an item is at moves as the work moves. Reading the sentence
  # in preference to a current declaration is what recomputed a predecessor's
  # identity in the first place.
  out=$(
    # shellcheck disable=SC1090
    . "$lib"
    row='{"structured":true,"state":"queued","hold_kind":"external","hold_reason":"Awaiting Browser Sol exact-head publication ruling","title":"t","raw":"r"}'
    printf 'declared=%s\n' "$(fm_outbound_classify_record "$row" EXACT_HEAD_BROWSER_REVIEW_REQUIRED | cut -f2)"
    printf 'tier=%s\n' "$(fm_outbound_classify_record "$row" EXACT_HEAD_BROWSER_REVIEW_REQUIRED | cut -f3)"
    # With no declaration, the prose still decides exactly as before.
    printf 'prose_only=%s\n' "$(fm_outbound_classify_record "$row" | cut -f2)"
    # An INVALID declaration is not a licence to invent a gate.
    printf 'invalid=%s\n' "$(fm_outbound_classify_record "$row" NOT_A_GATE | cut -f2)"
    printf 'done\n'
  )
  printf '%s' "$out" | grep -qx 'declared=EXACT_HEAD_BROWSER_REVIEW_REQUIRED' \
    || fail "declaration: stale hold prose outranked the typed declaration: $out"
  printf '%s' "$out" | grep -qx 'tier=prose' \
    || fail "declaration: the recognition tier stopped naming what recognised the row: $out"
  printf '%s' "$out" | grep -qx 'prose_only=AWAITING_BROWSER_SOL' \
    || fail "declaration: prose stopped deciding when no declaration exists: $out"
  printf '%s' "$out" | grep -qx 'invalid=AWAITING_BROWSER_SOL' \
    || fail "declaration: an invalid declaration displaced the prose gate: $out"
  printf '%s' "$out" | grep -qx 'done' \
    || fail "declaration: the control did not run to completion: $out"
  pass "declaration: a valid typed gate outranks stale hold prose, and absent or invalid leaves prose deciding"
}

# --- the governed typed ruling wire form -------------------------------------
#
# A REAL RULING WAS LOST TO THIS GAP. Browser Sol answered fm-ob-25c701e04893 in
# control comment 5383943043 with `protocol: fm-sol-control/v1`, `kind: ruling`
# and `in_reply_to`/`expected_item`/`expected_head_sha`. The reader accepted only
# the legacy `FM-SOL-RULING` marker plus the request's echoed binding lines, so
# `ruling` returned FM_OUTBOUND_RULING_IDENTITY_MISMATCH - a claim that the
# comment was about other work - and `poll` never selected the comment at all.
#
# THE BODY ITSELF IS THE HARD PART, and these fixtures keep its exact hazards.
# That comment quotes a DIFFERENT head (25427e9e...) in prose while explaining
# that the prior hold does not transfer, quotes its own head three more times,
# and carries `captain_required` TWICE. So a reader that searches the body for a
# sha has several to choose from, and a reader that demands every key appear once
# rejects a real ruling over a field it never needed. Both traps are asserted.

# The literal body of control comment 5383943043, byte for byte.
TYPED_RULING_REAL_BODY='protocol: fm-sol-control/v1
kind: ruling

in_reply_to: fm-ob-25c701e04893
from: browser-sol

decision: HOLD
authority: captain-delegated-browser-sol
captain_required: false

expected_item: candidate-publication-effect-guard
expected_head_sha: cf4c640bb1c7561b6c65f28cb1346c25ebe36d40
expected_tree_sha: 7bea6e5ac64d76768e60decd5a22a0db66ca6b5e
expected_policy_generation: pol-2026-08-23-g1

observed:
  - This is a fresh exact-head request; the prior HOLD for 25427e9e39931d25984227943c892d59edf5c072 does not transfer.
  - Direct GitHub retrieval still cannot resolve FirstMate commit cf4c640bb1c7561b6c65f28cb1346c25ebe36d40, consistent with the request'"'"'s expected remote tip being absent.

ruling:
  - Until those artifacts are independently inspectable, APPROVE_EXACT is not available.

stale_state_protection:
  - This HOLD applies only to head cf4c640bb1c7561b6c65f28cb1346c25ebe36d40 / tree 7bea6e5ac64d76768e60decd5a22a0db66ca6b5e / policy pol-2026-08-23-g1.

captain_required: false'

test_typed_ruling_form_is_read_field_by_field() {
  local lib out
  lib="$ROOT/bin/fm-outbound-artifact-lib.sh"
  out=$(
    # shellcheck disable=SC1090
    . "$lib"
    envelope=
    body=$TYPED_RULING_REAL_BODY
    envelope=$(fm_outbound_ruling_envelope "$body")
    printf 'form=%s\n' "$(fm_outbound_ruling_form "$body")"
    printf 'request=%s\n' "$(fm_outbound_typed_ruling_request "$body")"
    printf 'item=%s\n' "$(fm_outbound_envelope_field "$envelope" expected_item)"
    printf 'head=%s\n' "$(fm_outbound_envelope_field "$envelope" expected_head_sha)"
    printf 'decision=%s\n' "$(fm_outbound_envelope_field "$envelope" decision)"
    # A field the envelope never carries is ABSENT, which is not a contradiction.
    fm_outbound_envelope_field "$envelope" expected_gate >/dev/null 2>&1
    printf 'gate_rc=%s\n' "$?"
    # THE ENVELOPE ENDS BEFORE THE PROSE, so the second `captain_required` -
    # which sits after the content sections - is outside it and the field reads
    # cleanly. Body-wide this was a duplicate; that is the whole difference.
    fm_outbound_envelope_field "$envelope" captain_required >/dev/null 2>&1
    printf 'captain_rc=%s\n' "$?"
    # ...and must still not disqualify the ruling, or a real body is refused
    # over a key the join never reads.
    printf 'form_again=%s\n' "$(fm_outbound_ruling_form "$body")"
    # Form boundaries.
    # A marker appended AFTER the content sections is a quotation, not a second
    # declaration - the case that made real rulings unreadable body-wide.
    printf 'quoted_marker=%s\n' "$(fm_outbound_ruling_form "$body
FM-SOL-RULING fm-ob-25c701e04893")"
    printf 'legacy=%s\n' "$(fm_outbound_ruling_form 'FM-SOL-RULING fm-ob-25c701e04893
verdict: approved')"
    printf 'none=%s\n' "$(fm_outbound_ruling_form 'just some prose')"
    printf 'done\n'
  )
  printf '%s' "$out" | grep -qx 'form=typed' \
    || fail "typed shape: the real comment was not read as the typed form: $out"
  printf '%s' "$out" | grep -qx 'request=fm-ob-25c701e04893' \
    || fail "typed shape: in_reply_to was not read: $out"
  printf '%s' "$out" | grep -qx 'item=candidate-publication-effect-guard' \
    || fail "typed shape: expected_item was not read: $out"
  # THE SUBSTRING TRAP. The body names 25427e9e... in prose; only the field is
  # the head, and any reader that searched the body could have taken the other.
  printf '%s' "$out" | grep -qx 'head=cf4c640bb1c7561b6c65f28cb1346c25ebe36d40' \
    || fail "typed shape: expected_head_sha was not read from its own field: $out"
  printf '%s' "$out" | grep -q '25427e9e' \
    && fail "typed shape: a head quoted in prose was read as a field: $out"
  printf '%s' "$out" | grep -qx 'decision=HOLD' \
    || fail "typed shape: the decision was not read: $out"
  printf '%s' "$out" | grep -qx 'gate_rc=1' \
    || fail "typed shape: an absent optional binding was not reported absent: $out"
  printf '%s' "$out" | grep -qx 'captain_rc=0' \
    || fail "typed shape: a key repeated only outside the envelope was still read as duplicated: $out"
  printf '%s' "$out" | grep -qx 'form_again=typed' \
    || fail "typed shape: a key repeated after the envelope disqualified a real ruling: $out"
  printf '%s' "$out" | grep -qx 'quoted_marker=typed' \
    || fail "typed shape: a marker quoted after the envelope changed the body's form: $out"
  printf '%s' "$out" | grep -qx 'legacy=legacy' \
    || fail "typed shape: the legacy marker stopped being recognised: $out"
  printf '%s' "$out" | grep -qx 'none=none' \
    || fail "typed shape: an unrelated body was claimed as a ruling: $out"
  printf '%s' "$out" | grep -qx 'done' \
    || fail "typed shape: the control did not run to completion: $out"
  pass "typed shape: comment 5383943043's exact form is read field by field, and prose is never a field"
}

# The same shape as comment 5383943043, bound to whatever the fixture actually
# emitted. The foreign head quoted in prose is kept, so every end-to-end case
# below also carries the substring trap.
write_typed_ruling() {  # <case-dir> <request-id> <item> <head> <comment-id> [<decision>]
  local dir=$1 rid=$2 item=$3 head=$4 comment=$5 decision=${6:-HOLD}
  local rec gate project repo pr tree policy
  rec="$dir/home/data/outbound-artifacts/$rid.json"
  gate=$(jq -r '.identity.gate' "$rec")
  project=$(jq -r '.identity.project' "$rec")
  repo=$(jq -r '.identity.repo' "$rec")
  pr=$(jq -r '.identity.pr // "-"' "$rec")
  tree=$(jq -r '.identity.tree // ""' "$rec")
  policy=$(jq -r '.identity.policy // ""' "$rec")
  cat > "$dir/forge/ruling_body" <<TYPED
protocol: fm-sol-control/v1
kind: ruling

in_reply_to: $rid
from: browser-sol

decision: $decision
authority: captain-delegated-browser-sol
captain_required: false

expected_gate: $gate
expected_project: $project
expected_repo: $repo
expected_item: $item
expected_pull_request: $pr
expected_head_sha: $head
$(if [ -n "$tree" ]; then printf 'expected_tree_sha: %s' "$tree"; fi)
$(if [ -n "$policy" ]; then printf 'expected_policy_generation: %s' "$policy"; fi)

observed:
  - The prior HOLD for 25427e9e39931d25984227943c892d59edf5c072 does not transfer.

captain_required: false
TYPED
  printf '%s\n' "$comment" > "$dir/forge/ruling_id"
}

emitted_rid_and_head() {  # <case-dir> -> prints "<rid> <head>"
  local dir=$1 rid head
  rid=$(awk '{print $2}' "$dir/forge/comments" | tail -1)
  head=$(jq -r '.identity.head' "$dir/home/data/outbound-artifacts/$rid.json" 2>/dev/null)
  [ -n "$rid" ] && [ -n "$head" ] || return 1
  printf '%s %s\n' "$rid" "$head"
}

# Real shapes from the control issue that a body-wide reader got wrong. Each is
# the exact envelope plus the exact hazard region of the comment it names; the
# discussion in between is elided because it is precisely what must NOT be read.
#
#   5385768382  a compatibility REQUEST whose fenced ```text block contains the
#               canonical legacy marker. Read body-wide it became a `legacy`
#               ruling for fm-ob-25c701e04893 - a request re-read as its own
#               answer.
#   5351039509  a genuine typed ruling that later quotes `protocol:` at column 0
#               while explaining the format. Read body-wide the duplicate made
#               its form `both`, so a real ruling was refused.
#   5301874460  a genuine typed ruling answering a FOREIGN identity. 37 of the
#               43 typed rulings on this issue are like it, and calling each one
#               ambiguous is what produced the report storm.
#   5384189401  a genuine typed ruling for one of our requests whose exact head
#               lives in a nested `exact_subject:` block, so its envelope states
#               no top-level head at all.
# shellcheck disable=SC2016  # a verbatim fixture: backticks are the comment's own markdown
FIXTURE_5385768382='Browser Sol protocol compatibility follow-up for existing request `fm-ob-25c701e04893`.

Please re-emit the same HOLD in a new comment that includes these exact standalone lines:

```text
FM-SOL-RULING fm-ob-25c701e04893
gate: AWAITING_BROWSER_SOL
project: kun-agent-workspace
repo: sbracewell64/firstmate-sol-control
item: candidate-publication-effect-guard
pull-request: -
exact-head: cf4c640bb1c7561b6c65f28cb1346c25ebe36d40
```'

FIXTURE_5351039509='protocol: fm-sol-control/v1
kind: ruling

in_reply_to: fm-ob-aaaaaaaaaaaa
from: browser-sol

decision: HOLD

observed:
  - Something worth recording.

Continue using:

sbracewell64/firstmate-sol-control
protocol: fm-sol-control/v1

For genuine BROWSER_SOL decisions:'

FIXTURE_5301874460='protocol: fm-sol-control/v1
kind: ruling

in_reply_to: SOL-FM-AUTOMATION-001
from: browser-sol

decision: PROCEED_WITH_CONDITIONS
authority: captain-delegated-browser-sol'

FIXTURE_5384189401='protocol: fm-sol-control/v1
kind: ruling

id: SOL-FM-SSSF-LAUNCH1-R1-CURRENT-MAIN-REBASE-FIRST-20260823
in_reply_to: fm-ob-badaf425089f
from: browser-sol
to: firstmate

project: SSSF
repository: sbracewell64/inkwell-agent-sandboxes-and-software-factory
item: sssf-launch-1-r1
authority: captain-delegated-browser-sol
captain_required: false

decision: REVISE_REBASE_BEFORE_SEMANTIC_REVIEW

exact_subject:
  pr: 19
  head: 6f409ff111ddca747e76f1fde20645f98e09d7d2

observed:
  - GitHub exposes PR #19 open and mergeable at the exact head above.'

test_ruling_form_is_bounded_by_the_envelope() {
  local lib out
  lib="$ROOT/bin/fm-outbound-artifact-lib.sh"
  # A CONTROL ISSUE IS A CONVERSATION. Rulings quote their predecessors,
  # requests carry worked examples of the wire format, and operators paste
  # protocol snippets while discussing them. Every case below is a body whose
  # DISCUSSION contains something a body-wide reader mistook for a declaration.
  out=$(
    # shellcheck disable=SC1090
    . "$lib"
    printf 'fenced_request_form=%s\n' "$(fm_outbound_ruling_form "$FIXTURE_5385768382")"
    printf 'quoting_ruling_form=%s\n' "$(fm_outbound_ruling_form "$FIXTURE_5351039509")"
    printf 'foreign_form=%s\n' "$(fm_outbound_ruling_form "$FIXTURE_5301874460")"
    printf 'nested_head_form=%s\n' "$(fm_outbound_ruling_form "$FIXTURE_5384189401")"
    # The quoting ruling still states its own request exactly once.
    printf 'quoting_request=%s\n' "$(fm_outbound_typed_ruling_request "$FIXTURE_5351039509")"
    # A foreign identity is NOT OURS (3), never ambiguity (2).
    fm_outbound_typed_ruling_request "$FIXTURE_5301874460" >/dev/null 2>&1
    printf 'foreign_rc=%s\n' "$?"
    # The nested block is outside the envelope, so its head is not a field.
    printf 'nested_envelope_head=[%s]\n' \
      "$(fm_outbound_envelope_field "$(fm_outbound_ruling_envelope "$FIXTURE_5384189401")" head)"
    printf 'nested_envelope_item=%s\n' \
      "$(fm_outbound_envelope_field "$(fm_outbound_ruling_envelope "$FIXTURE_5384189401")" item)"
    # An envelope declaring both forms has two declarations and no precedence.
    printf 'mixed=%s\n' "$(fm_outbound_ruling_form 'FM-SOL-RULING fm-ob-aaaaaaaaaaaa
protocol: fm-sol-control/v1
kind: ruling')"
    # The preamble must BEGIN the envelope, not merely appear in it.
    printf 'late_preamble=%s\n' "$(fm_outbound_ruling_form 'id: SOL-X
protocol: fm-sol-control/v1
kind: ruling')"
    printf 'done\n'
  )
  printf '%s' "$out" | grep -qx 'fenced_request_form=none' \
    || fail "envelope: a fenced example promoted a REQUEST into a ruling: $out"
  printf '%s' "$out" | grep -qx 'quoting_ruling_form=typed' \
    || fail "envelope: a ruling quoting the protocol in prose was not read as itself: $out"
  printf '%s' "$out" | grep -qx 'quoting_request=fm-ob-aaaaaaaaaaaa' \
    || fail "envelope: the quoting ruling's own request was not read: $out"
  printf '%s' "$out" | grep -qx 'foreign_form=typed' \
    || fail "envelope: a genuine foreign-scheme ruling was not read as typed: $out"
  printf '%s' "$out" | grep -qx 'foreign_rc=3' \
    || fail "envelope: a foreign identity was not reported as not-ours: $out"
  printf '%s' "$out" | grep -qx 'nested_head_form=typed' \
    || fail "envelope: a ruling with a nested subject block was not read as typed: $out"
  printf '%s' "$out" | grep -qx 'nested_envelope_head=\[\]' \
    || fail "envelope: an indented value inside a nested block was read as an envelope field: $out"
  printf '%s' "$out" | grep -qx 'nested_envelope_item=sssf-launch-1-r1' \
    || fail "envelope: a bare top-level item was not read: $out"
  printf '%s' "$out" | grep -qx 'mixed=both' \
    || fail "envelope: an envelope declaring both forms was resolved instead of refused: $out"
  printf '%s' "$out" | grep -qx 'late_preamble=none' \
    || fail "envelope: a preamble that does not begin the envelope was accepted: $out"
  printf '%s' "$out" | grep -qx 'done' \
    || fail "envelope: the control did not run to completion: $out"
  pass "envelope: form and fields come from the canonical envelope, never from quoted, fenced or nested text"
}

test_a_ruling_without_a_top_level_head_refuses_without_writing() {
  local dir rid head out rc before
  # 5384188549 and 5384189401 are genuine rulings for our own requests whose
  # exact head lives in a nested block. Their envelope states no head, so the
  # identity cannot be joined - and a ruling that cannot be joined must leave
  # the record exactly as it found it.
  dir=$(new_case nestedhead)
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "nested head: emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  [ -n "$rid" ] || fail "nested head: the fixture recorded no request"
  before=$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 71 REVISE
  sed -i "s/^expected_head_sha: .*/exact_subject:\n  head: $head/" "$dir/forge/ruling_body"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 71 --issue 2 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "nested head: a ruling stating no top-level head was joined: $out"
  [ "$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")" = "$before" ] \
    || fail "nested head: a refused ruling mutated the record"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = emitted ] \
    || fail "nested head: the record left its pre-ruling state"

  # PAIRED GREEN: the same ruling with the head lifted into its envelope joins,
  # so the refusal is the missing top-level identity and not the fixture.
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 71 REVISE
  out=$(run_ob "$dir" ruling --request "$rid" --comment 71 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "nested head GREEN: the same ruling with a top-level head was refused, exit $rc: $out"
  [ "$(jq -r '.ruling.verdict' "$dir/home/data/outbound-artifacts/$rid.json")" = REVISE \
    ] || fail "nested head GREEN: the verdict was not recorded verbatim"
  pass "nested head: an envelope with no top-level head refuses untouched; the same ruling stating one joins"
}

test_typed_ruling_joins_and_records_its_verdict_verbatim() {
  local dir rid head out rc before after
  dir=$(new_case typedjoin)
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "typed join: emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  [ -n "$rid" ] || fail "typed join: the fixture recorded no request"
  before=$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")

  # RED FIRST: the identical body with its protocol line removed is no longer a
  # form this reader claims to understand, so it refuses and writes nothing.
  # This is the pre-repair condition reproduced from the opposite direction.
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 61
  grep -v '^protocol: ' "$dir/forge/ruling_body" > "$dir/forge/ruling_body.tmp"
  mv "$dir/forge/ruling_body.tmp" "$dir/forge/ruling_body"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 61 --issue 2 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "typed join RED: an unreadable form was joined anyway: $out"
  [ "$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")" = "$before" ] \
    || fail "typed join RED: a refused ruling mutated the record"

  # GREEN: the governed shape, joined, with the verdict recorded VERBATIM.
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 61
  out=$(run_ob "$dir" ruling --request "$rid" --comment 61 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "typed join GREEN: the governed ruling was refused, exit $rc: $out"
  after=$(jq -r '.state + " " + .ruling.verdict + " " + .ruling.comment_id' \
    "$dir/home/data/outbound-artifacts/$rid.json")
  [ "$after" = "ruled HOLD 61" ] \
    || fail "typed join GREEN: expected 'ruled HOLD 61', got '$after'"
  pass "typed join: the governed form joins and its verdict is recorded verbatim"
}

test_typed_ruling_refuses_every_unjoinable_shape() {
  local dir rid head shape out rc before
  # EVERY WAY THE JOIN CAN FAIL TO BE UNIQUE AND NON-CONTRADICTORY. Each one must
  # refuse with the record byte-identical afterwards, because a ruling this end
  # could not join must leave no trace that it did.
  for shape in wrong-item wrong-head wrong-request missing-gate missing-head duplicate-head \
               contradicting-project malformed-request both-forms both-verdicts; do
    dir=$(new_case "typedbad-$shape")
    declare_gate "$dir/home" AWAITING_BROWSER_SOL
    write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
    run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
      || fail "typed refusal/$shape: emit failed"
    read -r rid head <<< "$(emitted_rid_and_head "$dir")"
    [ -n "$rid" ] || fail "typed refusal/$shape: the fixture recorded no request"
    before=$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")
    write_typed_ruling "$dir" "$rid" waiting-item "$head" 62
    case $shape in
      wrong-item)    sed -i "s/^expected_item: .*/expected_item: another-item/" "$dir/forge/ruling_body" ;;
      wrong-head)    sed -i "s/^expected_head_sha: .*/expected_head_sha: $HEAD_B/" "$dir/forge/ruling_body" ;;
      wrong-request) sed -i "s/^in_reply_to: .*/in_reply_to: fm-ob-000000000000/" "$dir/forge/ruling_body" ;;
      missing-gate)  sed -i "/^expected_gate: /d" "$dir/forge/ruling_body" ;;
      missing-head)  sed -i "/^expected_head_sha: /d" "$dir/forge/ruling_body" ;;
      # INSIDE the envelope, not appended. A field repeated after the content
      # sections is a quotation the envelope rule deliberately ignores, so
      # appending would test the opposite of what this case is named for.
      duplicate-head) sed -i "/^expected_head_sha: /a expected_head_sha: $HEAD_B" "$dir/forge/ruling_body" ;;
      contradicting-project) sed -i "s/^expected_project: .*/expected_project: not-the-project/" "$dir/forge/ruling_body" ;;
      malformed-request) sed -i "s/^in_reply_to: .*/in_reply_to: not-a-request-id/" "$dir/forge/ruling_body" ;;
      both-forms)    sed -i "/^in_reply_to: /a FM-SOL-RULING $rid" "$dir/forge/ruling_body" ;;
      # The verdict is read from the whole body, not the envelope: a legacy
      # ruling states `verdict:` after its prose, so an envelope-only read would
      # stop seeing legacy verdicts entirely. A typed body carrying the other
      # form's verdict key anywhere is therefore still refused.
      both-verdicts) printf 'verdict: approved\n' >> "$dir/forge/ruling_body" ;;
    esac
    out=$(run_ob "$dir" ruling --request "$rid" --comment 62 --issue 2 2>&1); rc=$?
    [ "$rc" -ne 0 ] \
      || fail "typed refusal/$shape: an unjoinable ruling was accepted: $out"
    [ "$(cksum < "$dir/home/data/outbound-artifacts/$rid.json")" = "$before" ] \
      || fail "typed refusal/$shape: a refused ruling mutated the record"
    [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = emitted ] \
      || fail "typed refusal/$shape: the record left its pre-ruling state"

    # PAIRED GREEN, so no shape can pass by the fixture never joining anything.
    write_typed_ruling "$dir" "$rid" waiting-item "$head" 62
    out=$(run_ob "$dir" ruling --request "$rid" --comment 62 --issue 2 2>&1); rc=$?
    [ "$rc" -eq 0 ] \
      || fail "typed refusal/$shape: the paired joinable ruling was refused, exit $rc: $out"
  done
  pass "typed refusal: wrong item, head, request, missing, duplicated, contradicting, malformed and both-form bodies all refuse with the record untouched"
}

test_typed_ruling_is_discovered_by_poll() {
  local dir rid head out rc
  dir=$(new_case typedpoll)
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "typed poll: emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  [ -n "$rid" ] || fail "typed poll: the fixture recorded no request"

  # THE SYMPTOM THAT HID THE REAL RULING. Discovery read only the legacy marker,
  # so a typed comment was not selected at all: no join, no mismatch, no line -
  # the fleet simply never saw it. Silence is the failure being controlled here,
  # so the assertion is that the record MOVED, not that a message appeared.
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 63
  out=$(run_ob "$dir" poll 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "typed poll: poll reported a failure, exit $rc: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = ruled ] \
    || fail "typed poll: the typed ruling was never selected by discovery: $out"
  [ "$(jq -r '.ruling.verdict' "$dir/home/data/outbound-artifacts/$rid.json")" = HOLD ] \
    || fail "typed poll: the joined verdict is not the one the body stated: $out"
  pass "typed poll: discovery selects the governed form instead of skipping it in silence"
}

test_a_hold_ruling_never_becomes_a_landing_authority() {
  local dir rid head out rc auth
  auth="$ROOT/bin/fm-landing-authorization.sh"
  [ -x "$auth" ] || { printf 'skip: %s is not executable\n' "$auth"; return 0; }
  dir=$(new_case typedhold)
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "hold: emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  [ -n "$rid" ] || fail "hold: the fixture recorded no request"

  # JOINING A RULING IS NOT ACCEPTING ITS VERDICT. HOLD is recorded, and the
  # authority owner's closed list refuses to read it as approval.
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 64 HOLD
  run_ob "$dir" ruling --request "$rid" --comment 64 --issue 2 >/dev/null 2>&1 \
    || fail "hold: the HOLD ruling did not join"
  # THE PLAN IS COMPLETE AND VALID, so the refusal below is the VERDICT being
  # classified rather than a missing effect plan stopping the act one step
  # earlier. A landing authority now permits an exact ACT, and an authority with
  # no effect plan authorizes nothing - so a mint with no `--effect` is refused
  # for that reason and would never reach the verdict this case is controlling.
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$auth" mint "$rid" \
    --effect pr-merge --method squash 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "hold: a HOLD ruling minted a landing authority: $out"
  printf '%s' "$out" | grep -q 'FM_AUTH_VERDICT_UNRECOGNIZED' \
    || fail "hold: refused for the wrong reason: $out"
  [ -z "$(ls -A "$dir/home/data/landing-authorizations" 2>/dev/null)" ] \
    || fail "hold: a HOLD ruling left a landing authority behind"

  # PAIRED GREEN: the same path with an approving verdict does mint, so the
  # refusal above is the verdict being classified and not the fixture failing.
  dir=$(new_case typedapprove)
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "hold GREEN: emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 65 approved
  run_ob "$dir" ruling --request "$rid" --comment 65 --issue 2 >/dev/null 2>&1 \
    || fail "hold GREEN: the approving ruling did not join"
  out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$auth" mint "$rid" \
    --effect pr-merge --method squash 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "hold GREEN: an approving ruling failed to mint, exit $rc: $out"
  pass "hold: a joined HOLD is recorded and refused as authority, while an approving verdict still mints"
}

# --- record isolation: one broken record is not every item's blocker ---------
#
# THE DEFECT THESE CONTROL. Superseding an item's older heads is a decision
# about THAT item, but reaching it validated every record in the store first, so
# a single preserved adverse record refused every NEW request in the fleet. It
# was measured on the live store: an exact, complete, well-bound request for
# candidate-publication-effect-guard returned FM_OUTBOUND_RECORD_UNREADABLE
# before transport because fm-ob-18a4c958c445.json - whose own identity names
# ae-xp1-registered-external-target - could not be validated.
#
# The repair is a SCOPE test that runs before the validity test, and the whole
# safety argument rests on its direction: unrelatedness must be POSITIVELY
# established from the record's own bytes, and every other outcome keeps the
# record in scope. So each control below is a PAIR over one fixture with one
# field changed - the same store record, once naming another item and once not,
# or once readable and once not - because a control that only ever answers one
# way cannot tell the scope test from a mechanism that skips everything.

# A home with two waiting items on two different projects. The second project's
# record is the one driven adverse; the first item's request is the one that
# must still be reachable.
prepare_isolation_case() {  # <name> -> prints case dir
  local dir
  dir=$(new_case "$1")
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n' > "$dir/home/data/projects.md"
  printf -- '- other [no-mistakes] - other project (added 2026-08-16)\n' >> "$dir/home/data/projects.md"
  git clone -q --no-hardlinks "$HEAD_REPO" "$dir/home/projects/other" 2>/dev/null
  jq -n --arg h "$HEAD_A" '
    {schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[
      {order:1,state:"queued",structured:true,id:"waiting-item",
       title:"needs independent review",hold_kind:"outbound",
       hold_reason:"awaiting browser sol",repo:"demo",
       pr_url:"https://github.com/o/r/pull/4",body_excerpt:null},
      {order:2,state:"queued",structured:true,id:"other-item",
       title:"a different work item entirely",hold_kind:"outbound",
       hold_reason:"awaiting browser sol",repo:"other",
       pr_url:null,body_excerpt:null},
      {order:3,state:"queued",structured:true,id:"ordinary-item",
       title:"ordinary queued work",hold_kind:null,hold_reason:null,
       repo:"demo",pr_url:null,body_excerpt:null}]}}' > "$dir/snap.json"
  mkdir -p "$dir/home/data/waiting-item" "$dir/home/data/other-item"
  jq -n --arg h "$HEAD_A" '{gate:"INDEPENDENT_BROWSER_REVIEW_REQUIRED",head:$h}' \
    > "$dir/home/data/waiting-item/outbound-gate.json"
  jq -n --arg h "$HEAD_A" '{gate:"INDEPENDENT_BROWSER_REVIEW_REQUIRED",head:$h}' \
    > "$dir/home/data/other-item/outbound-gate.json"
  printf '%s\n' "$dir"
}

# The store record another item owns, after one real emit for that item. It is
# produced by the command under test rather than hand-authored, so its identity
# digest, filename and content agree exactly as the live one does.
other_item_record() {  # <case-dir> -> prints the record path
  local dir=$1 rid
  run_ob "$dir" emit other-item >/dev/null 2>&1 \
    || fail "isolation fixture: the unrelated item's own emit failed"
  rid=$(grep ' ' "$dir/forge/comments" | awk '$2 != "" {print $2}' | tail -1)
  [ -n "$rid" ] || fail "isolation fixture: no request id was recorded for the unrelated item"
  [ -f "$dir/home/data/outbound-artifacts/$rid.json" ] \
    || fail "isolation fixture: the unrelated item left no correlation record"
  printf '%s\n' "$dir/home/data/outbound-artifacts/$rid.json"
}

posts_since() {  # <case-dir> <before-count> -> prints posts added
  printf '%s\n' "$(( $(wc -l < "$1/forge/post_log") - $2 ))"
}

# `fail` inside a command substitution kills only the subshell, so a fixture
# that echoes its path hands the caller an empty string and sails on. Every
# caller of other_item_record runs this, which is what turns that swallowed
# refusal back into a failure instead of an empty path fed to jq and git.
require_record_path() {  # <path> <label>
  [ -n "$1" ] && [ -f "$1" ] \
    || fail "$2: the fixture produced no correlation record path"
}

test_unrelated_broken_record_does_not_block_an_exact_request() {
  local dir record before rc out bytes_before bytes_after posts
  dir=$(prepare_isolation_case iso-unrelated)
  record=$(other_item_record "$dir")
  require_record_path "$record" "isolation"

  # Drive the unrelated record adverse the way the live one is: its project's
  # clone stops being readable, so the object format is undeterminable, so its
  # own binding no longer resolves. Nothing about the record's bytes changes.
  rm -rf "$dir/home/projects/other"
  bytes_before=$(cksum < "$record")

  # RED HALF. The identical record, differing only in the item it names. With
  # this item as its subject it is in scope, it fails to validate, and the
  # request must not be posted. This is the half that proves the green half is
  # the scope test rather than a mechanism that skips every record.
  jq '.identity.item = "waiting-item"' "$record" > "$record.red"
  cp "$record" "$record.orig"
  mv "$record.red" "$record"
  before=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "isolation RED: a same-item record that does not validate still permitted an emit: $out"
  printf '%s' "$out" | grep -qE 'FM_OUTBOUND_RECORD_UNREADABLE|FM_OUTBOUND_IDENTITY_REFUSED' \
    || fail "isolation RED: refused for the wrong reason: $out"
  posts=$(posts_since "$dir" "$before")
  [ "$posts" -eq 0 ] \
    || fail "isolation RED: $posts request(s) were posted while a same-item record was unvalidatable"

  # GREEN HALF. One field back to what it was. The record is exactly as broken,
  # and it is now provably about other work.
  mv "$record.orig" "$record"
  [ "$(cksum < "$record")" = "$bytes_before" ] \
    || fail "isolation: the fixture failed to restore the unrelated record"
  before=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "isolation GREEN: an exact request for unrelated work was refused, exit $rc: $out"
  posts=$(posts_since "$dir" "$before")
  [ "$posts" -eq 1 ] \
    || fail "isolation GREEN: expected exactly one posted request, got $posts"

  # PRESERVED BYTE FOR BYTE. Skipping a record is not touching it: a pass that
  # quietly repaired, superseded or rewrote the adverse record would satisfy
  # every assertion above while destroying the evidence it names.
  bytes_after=$(cksum < "$record")
  [ "$bytes_after" = "$bytes_before" ] \
    || fail "isolation: the skipped record was rewritten rather than left alone"
  pass "isolation: an unrelated unvalidatable record permits an exact request and is left untouched"
}

test_unrelated_identity_mismatch_does_not_block_an_exact_request() {
  local dir record before out rc posts
  # THE OTHER ADVERSE CLASS, kept apart on purpose. The case above is
  # could-not-observe: the record's binding stops resolving. This one is a true
  # IDENTITY MISMATCH - perfectly readable, its binding resolves, and its
  # recomputed identity simply does not match the id it is filed under. The two
  # need different repairs, so a control that only ever produced one of them
  # would leave the other unmeasured.
  dir=$(prepare_isolation_case iso-mismatch)
  record=$(other_item_record "$dir")
  require_record_path "$record" "mismatch"

  # RED HALF: the mismatch names THIS item, so it is in scope and must refuse
  # with the identity token rather than the unreadable one.
  jq '.identity.item = "waiting-item"' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  before=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 3 ] \
    || fail "mismatch RED: a same-item identity mismatch did not refuse with a verdict, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_IDENTITY_REFUSED' \
    || fail "mismatch RED: refused for the wrong reason: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RECORD_UNREADABLE' \
    && fail "mismatch RED: a readable foreign record was reported as unreadable: $out"
  posts=$(posts_since "$dir" "$before")
  [ "$posts" -eq 0 ] \
    || fail "mismatch RED: $posts request(s) posted against a same-item identity mismatch"

  # GREEN HALF: still a mismatch, still unrepaired, but its subject is once more
  # provably another item. Mutating the HEAD keeps the record readable and its
  # binding resolvable, so the adverse class here is mismatch and not absence.
  jq --arg h "$HEAD_B" '.identity.item = "other-item" | .identity.head = $h' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  before=$(wc -l < "$dir/forge/post_log")
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "mismatch GREEN: an exact request was blocked by another item's mismatch, exit $rc: $out"
  posts=$(posts_since "$dir" "$before")
  [ "$posts" -eq 1 ] \
    || fail "mismatch GREEN: expected exactly one posted request, got $posts"
  [ "$(jq -r '.identity.item' "$record")" = "other-item" ] \
    || fail "mismatch GREEN: the skipped record was rewritten"
  [ "$(jq -r '.identity.head' "$record")" = "$HEAD_B" ] \
    || fail "mismatch GREEN: the skipped record's head was superseded by another item's emit"
  [ "$(jq -r '.state' "$record")" != "superseded" ] \
    || fail "mismatch GREEN: another item's emit superseded a record it does not own"
  pass "mismatch: an unrelated identity mismatch permits an exact request; the same mismatch on this item refuses"
}

test_skipped_record_stays_adverse_everywhere_else() {
  local dir record rid out rc
  dir=$(prepare_isolation_case iso-adverse)
  record=$(other_item_record "$dir")
  require_record_path "$record" "adverse"
  rid=$(basename "$record" .json)
  rm -rf "$dir/home/projects/other"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
    || fail "adverse: the exact unrelated request was refused"

  # THE SKIP IS SCOPED TO ONE DECISION AND GRANTS NOTHING. The record must still
  # be adverse on every surface that reports it, or this repair would have
  # converted a loud blocker into silence - which is the failure this whole
  # module exists to refuse.
  out=$(run_ob "$dir" show "$rid" 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "adverse: show treated the skipped record as readable, exit $rc: $out"

  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "adverse: the sweep did not stay could-not-observe, exit $rc: $out"
  # Reported against the item it actually belongs to, which is where an operator
  # repairs a correlation fault. Asserted by SECTION rather than by total count:
  # the count also carries the project's own unreadable-clone row, and pinning
  # it would make this control fail for a reason it is not about.
  printf '%s' "$out" | sed -n '/^COULD NOT OBSERVE/,/^SATISFIED/p' | grep -q 'other-item' \
    || fail "adverse: the broken record's item was not filed under could-not-observe: $out"
  # And it can never read as satisfied - not the item holding it, and not by
  # lending its presence to the item whose request did go through.
  printf '%s' "$out" | grep -q 'SATISFIED (1)' \
    || fail "adverse: the item that DID get its request is not reported satisfied: $out"
  printf '%s' "$out" | sed -n '/^SATISFIED/,$p' | grep -q 'other-item' \
    && fail "adverse: the item holding the broken record was reported satisfied: $out"
  pass "adverse: a skipped record stays could-not-observe on show and in the sweep, and never satisfied"
}

test_unpositionable_subject_always_refuses() {
  local dir record shape content before out rc posts good
  # EVERY WAY A SUBJECT CAN FAIL TO BE ESTABLISHED. None of these records is
  # about the item being requested, and every one of them must still refuse:
  # the skip requires unrelatedness POSITIVELY established, so "cannot tell"
  # keeps the record in scope. Each shape is paired with the same bytes made
  # readable, so no shape can pass by being ignored.
  for shape in malformed missing-item null-item empty-item duplicate-item \
               duplicate-identity two-documents unknown-schema missing-schema; do
    dir=$(prepare_isolation_case "iso-subject-$shape")
    record=$(other_item_record "$dir")
    require_record_path "$record" "subject/$shape"
    good=$(cat "$record")
    case $shape in
      malformed)         content=$(printf '%s' "$good" | head -c 40) ;;
      missing-item)      content=$(printf '%s' "$good" | jq 'del(.identity.item)') ;;
      null-item)         content=$(printf '%s' "$good" | jq '.identity.item = null') ;;
      empty-item)        content=$(printf '%s' "$good" | jq '.identity.item = ""') ;;
      duplicate-item)    content=$(printf '%s' "$good" | jq -c '.' | sed 's/"item":"[^"]*"/"item":"alpha","item":"beta"/') ;;
      duplicate-identity) content=$(printf '%s\n%s' \
                            "$(printf '%s' "$good" | jq -c '.' | sed 's/}$//')" \
                            "$(printf '%s' "$good" | jq -c '{identity:.identity}' | sed -e 's/^{/,/')") ;;
      two-documents)     content=$(printf '%s\n%s' "$(printf '%s' "$good" | jq -c '.')" \
                            "$(printf '%s' "$good" | jq -c '.identity.item = "second"')") ;;
      unknown-schema)    content=$(printf '%s' "$good" | jq '.schema = "some-other-record.v9"') ;;
      missing-schema)    content=$(printf '%s' "$good" | jq 'del(.schema)') ;;
    esac
    printf '%s\n' "$content" > "$record"
    # NON-VACUITY: every shape but one must still be PARSABLE. Without this the
    # first fixture that accidentally emitted unbalanced bytes would refuse for
    # the malformed reason while wearing another shape's name, and the case
    # would report a control it never ran. One of these did exactly that.
    if [ "$shape" = malformed ]; then
      jq -e . "$record" >/dev/null 2>&1 \
        && fail "subject/$shape: the fixture produced parsable JSON, so nothing here is testing malformed bytes"
    else
      jq -e . "$record" >/dev/null 2>&1 \
        || fail "subject/$shape: the fixture produced unparsable JSON, so this case is testing malformed bytes rather than $shape"
    fi
    before=$(wc -l < "$dir/forge/post_log")
    out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
    [ "$rc" -ne 0 ] \
      || fail "subject/$shape: a record with no establishable subject permitted an emit: $out"
    posts=$(posts_since "$dir" "$before")
    [ "$posts" -eq 0 ] \
      || fail "subject/$shape: $posts request(s) posted while a subject could not be established"

    # THE PAIRED GREEN. The same store, the same request, the same everything
    # except that the record now says plainly whose it is. Without this half a
    # shape could "pass" because the fixture never let any emit through.
    printf '%s\n' "$good" > "$record"
    before=$(wc -l < "$dir/forge/post_log")
    out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
    [ "$rc" -eq 0 ] \
      || fail "subject/$shape: the paired readable record refused the same request, exit $rc: $out"
    posts=$(posts_since "$dir" "$before")
    [ "$posts" -eq 1 ] \
      || fail "subject/$shape: the paired readable case posted $posts requests, expected 1"
  done
  pass "subject: malformed, absent, empty, ambiguous and foreign-schema records all refuse, and their readable pairs do not"
}

test_isolation_preserves_head_and_idempotency() {
  local dir record before out rc posts
  dir=$(prepare_isolation_case iso-head)
  record=$(other_item_record "$dir")
  require_record_path "$record" "isolation head"
  rm -rf "$dir/home/projects/other"

  run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
    || fail "isolation head: the first exact request was refused"

  # IDEMPOTENCY IS NOT WEAKENED BY THE SKIP. Five further cycles at the same
  # identity, exactly as a repeating scheduler produces them.
  before=$(wc -l < "$dir/forge/post_log")
  for _ in 1 2 3 4 5; do
    out=$(run_ob "$dir" emit waiting-item 2>&1) \
      || fail "isolation head: a repeat cycle errored: $out"
    printf '%s' "$out" | grep -q 'already requested' \
      || fail "isolation head: a repeat cycle did not report the existing request: $out"
  done
  posts=$(posts_since "$dir" "$before")
  [ "$posts" -eq 0 ] \
    || fail "isolation head: five repeat cycles posted $posts further requests, expected 0"

  # AND THE WRONG HEAD IS STILL THE WRONG HEAD. Exact-head binding is the one
  # thing a scope test must never loosen: the request just made says nothing
  # about a head it was not bound to.
  #
  # Moved at the DECLARATION, which is what a typed gate binds to. Moving the
  # forge shim instead would leave the declared head standing and the item
  # satisfied, and the control would then be measuring the fixture.
  jq -n --arg h "$HEAD_B" '{gate:"INDEPENDENT_BROWSER_REVIEW_REQUIRED",head:$h}' \
    > "$dir/home/data/waiting-item/outbound-gate.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "isolation head: expected the sweep to stay could-not-observe alongside the broken record, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_STALE_HEAD' \
    || fail "isolation head: a moved head no longer reports its previous request inapplicable: $out"
  pass "isolation: repeat cycles still dedupe, and a moved head still invalidates the request"
}

# --- sweep size --------------------------------------------------------------

test_sweep_survives_a_row_set_larger_than_one_argument() {
  local dir repo out rc bytes rows limit=131072 i item base
  # A ROW SET HAS NO BOUND THIS COMMAND CONTROLS - it is however many branches
  # and waiting items a fleet has. The fold used to hand its result to a second
  # jq as `--argjson rows "$row"`, and Linux caps ONE argument at
  # MAX_ARG_STRLEN (128KB), far below the 2MB total, so past that size the
  # sweep died with "Argument list too long" and printed no rows and no reason
  # - a sweep that reports nothing while looking exactly like a quiet fleet.
  #
  # This was unreachable while firstmate's own repository could not be resolved
  # and contributed one clone-unreadable row. It became reachable the moment it
  # could: that repository alone carries a few hundred candidate branches.
  dir=$(new_case sweepsize)
  printf -- '- demo [no-mistakes] - demo project (added 2026-08-16)\n' > "$dir/home/data/projects.md"
  repo="$dir/home/projects/demo"
  git -C "$repo" remote add origin https://github.com/o/demo.git 2>/dev/null || true
  git -C "$repo" branch -M main
  # Unlanded work with no lifecycle record: each ref becomes one
  # WORK_STATE_UNOBSERVED row and spends no forge probe, so the row set grows
  # without the sweep going anywhere near the network.
  git -C "$repo" checkout -q -b unlanded
  printf 'unlanded\n' > "$repo/f"
  git -C "$repo" add f
  git -C "$repo" -c commit.gpgsign=false commit -qm 'never landed'
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  # Long names so the byte target is reached with few refs; one batched update
  # rather than several hundred git invocations.
  item=$(printf 'w%.0s' $(seq 1 200))
  {
    for i in $(seq 1 350); do printf 'create refs/heads/fm/%s-%s %s\n' "$item" "$i" "$base"; done
  } | git -C "$repo" update-ref --stdin \
    || fail "sweep size: the fixture could not create its refs"
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[]}}' > "$dir/snap.json"

  out=$(run_ob "$dir" check --json 2>"$dir/sweep.err"); rc=$?
  grep -q 'Argument list too long' "$dir/sweep.err" \
    && fail "sweep size: the sweep died on argument size: $(cat "$dir/sweep.err")"
  [ "$rc" -eq 4 ] \
    || fail "sweep size: expected could-not-observe over unrecorded work, exit $rc"
  rows=$(printf '%s' "$out" | jq '.rows | length' 2>/dev/null) \
    || fail "sweep size: the sweep produced no readable document"
  [ "$rows" -ge 350 ] \
    || fail "sweep size: expected at least 350 rows, got $rows"

  # NON-VACUITY: the fixture has to actually reach the regime that used to fail.
  # A row set comfortably under the cap would pass this case without exercising
  # anything it is about.
  bytes=$(printf '%s' "$out" | jq -c '.rows' | wc -c)
  [ "$bytes" -gt "$limit" ] \
    || fail "sweep size: the row set is only $bytes bytes, under the $limit-byte single-argument cap, so this control did not reach the failing regime"
  pass "sweep size: a row set past the $limit-byte single-argument cap still reports every row"
}

# --- the operational home's own repository -----------------------------------

# A home that IS the checkout of one registered project - firstmate's own shape,
# and the only project whose clone is not under $PROJECTS.
prepare_home_repo_case() {  # <name> <register:yes|no> -> prints case dir
  local name=$1 register=$2 dir home head
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  make_gh "$dir"
  # The home directory's NAME is the project name, and the home is the top level
  # of that repository.
  home="$dir/selfrepo"
  mkdir -p "$home/data" "$home/config" "$home/state" "$home/projects"
  git -C "$home" init -q
  git -C "$home" config user.email fixture@example.com
  git -C "$home" config user.name Fixture
  printf 'a\n' > "$home/f"
  git -C "$home" add f
  git -C "$home" -c commit.gpgsign=false commit -qm a
  git -C "$home" checkout -q -b fm/self-item
  printf 'b\n' > "$home/f"
  git -C "$home" add f
  git -C "$home" -c commit.gpgsign=false commit -qm 'work on firstmate itself'
  head=$(git -C "$home" rev-parse HEAD)
  : > "$home/data/projects.md"
  if [ "$register" = yes ]; then
    printf -- '- selfrepo [no-mistakes] - firstmate itself (added 2026-08-04)\n' \
      > "$home/data/projects.md"
  fi
  configure_venue "$home"
  mkdir -p "$home/data/self-item"
  jq -n --arg gate INDEPENDENT_BROWSER_REVIEW_REQUIRED --arg head "$head" \
    '{gate:$gate,head:$head}' > "$home/data/self-item/outbound-gate.json"
  jq -n '{schema:"fm-fleet-snapshot.v1",backlog:{present:true,records:[
    {order:1,state:"queued",structured:true,id:"self-item",
     title:"work on firstmate itself",hold_kind:"outbound",
     hold_reason:"awaiting browser sol",repo:"selfrepo",
     pr_url:null,body_excerpt:null}]}}' > "$dir/snap.json"
  printf '%s\n' "$dir"
}

run_home_repo() {  # <case-dir> <args...>
  local dir=$1; shift
  PATH="$dir/bin:$PATH" FORGE_DIR="$dir/forge" \
    FM_HOME="$dir/selfrepo" FM_OUTBOUND_SNAPSHOT="$dir/snap.json" \
    FM_OUTBOUND_BACKOFF_BASE=0 REAL_GIT="$(command -v git)" \
    "$OB" "$@"
}

test_operational_home_repository_needs_no_environment_override() {
  local dir out rc posts
  # RED FIRST, and for the RIGHT reason. The identical home with the project
  # absent from the registry: the resolution requires registry evidence, so the
  # exact head is unreadable, the binding is incomplete, and nothing is posted.
  # This is what makes the green half evidence of a registry-backed resolution
  # rather than of a home path being adopted on sight.
  dir=$(prepare_home_repo_case selfrepo-unregistered no)
  out=$(run_home_repo "$dir" emit self-item 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "home repo RED: an unregistered project resolved to the home anyway: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_INCOMPLETE_BINDING' \
    || fail "home repo RED: refused for the wrong reason: $out"
  printf '%s' "$out" | grep -q 'missing head' \
    || fail "home repo RED: the refusal did not name the unreadable head: $out"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 0 ] \
    || fail "home repo RED: a request was posted from an unresolvable binding"

  # GREEN. Registered, and the home is that repository's top level. No
  # FM_PROJECTS_OVERRIDE is set anywhere in run_home_repo - that variable is
  # test isolation, and needing it to reach this project in production was the
  # defect.
  dir=$(prepare_home_repo_case selfrepo-registered yes)
  [ -z "${FM_PROJECTS_OVERRIDE:-}" ] \
    || fail "home repo: the environment already carried FM_PROJECTS_OVERRIDE, so this proves nothing"
  out=$(run_home_repo "$dir" emit self-item 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "home repo GREEN: the home's own repository still could not be resolved, exit $rc: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] \
    || fail "home repo GREEN: expected one posted request, got $posts"
  out=$(run_home_repo "$dir" check 2>&1)
  # THE RESOLUTION'S OWN SIGNATURE, asserted instead of the whole-sweep exit.
  # Resolving this project also makes its branches visible to the inventory
  # pass for the first time, so the sweep legitimately carries rows this
  # control is not about; pinning the exit would make it fail for them.
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CLONE_UNREADABLE' \
    && fail "home repo GREEN: the project's clone is still unreadable, so nothing was resolved: $out"
  printf '%s' "$out" | sed -n '/^SATISFIED/,$p' | grep -q 'self-item' \
    || fail "home repo GREEN: the resolved request is not reported satisfied: $out"
  pass "home repo: a registered project whose checkout IS the home resolves with no environment override"
}

test_home_repository_never_displaces_an_ordinary_clone() {
  local dir out rc head_clone head_home
  # ALL OTHER PROJECT RESOLUTION IS UNCHANGED, and the precedence is the reason.
  # A real clone under $PROJECTS always wins, so a home that does keep one is
  # untouched by this resolution. Driven by giving the clone and the home
  # DIFFERENT heads for the same branch and asserting which one was read.
  dir=$(prepare_home_repo_case selfrepo-clone-wins yes)
  # Cloned from an UNRELATED repository on purpose. Cloning the home instead
  # shares its objects, so the home's head resolves in the clone too and the
  # case cannot tell which repository was read - it passes either way, which is
  # no control at all.
  git clone -q --no-hardlinks "$HEAD_REPO" "$dir/selfrepo/projects/selfrepo" 2>/dev/null \
    || fail "clone precedence: the fixture clone could not be created"
  head_home=$(git -C "$dir/selfrepo" rev-parse refs/heads/fm/self-item)
  git -C "$dir/selfrepo/projects/selfrepo" rev-parse --verify --quiet "$head_home^{object}" >/dev/null 2>&1 \
    && fail "clone precedence: the fixture clone already contains the home's head, so it proves nothing"
  head_clone=$(git -C "$dir/selfrepo/projects/selfrepo" rev-parse HEAD)
  [ "$head_clone" != "$head_home" ] \
    || fail "clone precedence: the fixture failed to make the two repositories differ"

  # The declared head is the home's, and it does NOT exist in the clone. If the
  # clone is what gets read - which is the unchanged behaviour - that head does
  # not resolve and the binding is refused.
  out=$(run_home_repo "$dir" emit self-item 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "clone precedence: the home displaced a real clone under \$PROJECTS: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_INCOMPLETE_BINDING' \
    || fail "clone precedence: refused for the wrong reason: $out"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 0 ] \
    || fail "clone precedence: a request was posted against the wrong repository"
  pass "clone precedence: an existing clone under \$PROJECTS still wins over the home"
}

# --- run ---------------------------------------------------------------------

test_no_request_is_red
test_branch_inventory_finds_an_unannotated_unsubmitted_branch
test_branch_inventory_dedupes_only_complete_identity
test_branch_inventory_dedupes_duplicate_refs_before_probing
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
test_reconcile_reports_the_emit_status_it_produced
test_reconcile_releases_every_emit_lock
test_reconcile_reports_every_item_after_one_refuses
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
test_exit_status_is_the_declared_fold_not_a_defect_shortcut
test_unobservable_forge_is_not_a_pass
test_unreadable_head_is_could_not_observe_not_an_absent_artifact
test_no_unobserved_token_is_ever_rendered_as_a_defect
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
test_forge_observed_head_need_not_exist_locally
test_forge_head_provenance_survives_record_lifecycle
test_inventory_unfinished_work_is_not_a_defect
test_inventory_conflicting_lifecycle_is_could_not_observe
test_inventory_unparsable_lifecycle_row_is_unobserved_not_a_conflict
test_inventory_non_ship_work_is_not_a_defect
test_inventory_reads_the_rotated_archive
test_inventory_unreadable_archive_is_could_not_observe
test_could_not_observe_has_its_own_section
test_inbound_sender_must_be_exactly_one_closed_value
test_inbound_ruling_with_wrong_sender_wakes_nothing
test_every_declared_token_has_an_emit_site


# --- clause 6: an exact ruling wakes once, and a replay writes nothing -------

test_replaying_the_same_ruling_writes_nothing() {
  local dir rid head before after out rc
  dir=$(new_case rulingreplay)
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "replay: emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 90 approved
  run_ob "$dir" ruling --request "$rid" --comment 90 --issue 2 >/dev/null 2>&1 \
    || fail "replay: the ruling did not join"
  before=$(jq -S . "$dir/home/data/outbound-artifacts/$rid.json")

  # A wake can arrive twice - a re-poll, a retried check, a restart mid-drain.
  # Rejoining the identical comment rewrote `observed` and `updated` every time,
  # so the record's own bytes stopped answering "has anything happened since?"
  # and anything comparing it across a replay saw movement that was only the
  # clock. This was caught by an end-to-end walk of the seam, not by a fixture:
  # the two writes landed in the same second until the walk got slower.
  out=$(run_ob "$dir" ruling --request "$rid" --comment 90 --issue 2 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "replay: rejoining the same ruling failed, exit $rc: $out"
  after=$(jq -S . "$dir/home/data/outbound-artifacts/$rid.json")
  [ "$before" = "$after" ] \
    || fail "replay: rejoining the same ruling changed the record: $out"

  # PAIRED: a DIFFERENT verdict on the same request is not a replay and must
  # still be able to move the record, so the convergence above is recognition
  # of sameness rather than a second ruling being ignored.
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 91 approved
  run_ob "$dir" ruling --request "$rid" --comment 91 --issue 2 >/dev/null 2>&1 \
    || fail "replay GREEN: a different ruling comment did not join"
  [ "$(jq -r '.ruling.comment_id' "$dir/home/data/outbound-artifacts/$rid.json")" = 91 ] \
    || fail "replay GREEN: a different ruling comment was ignored as a replay"
  pass "replay: an identical ruling writes nothing, while a different one still joins"
}

# --- clause 1: the generation a request is bound to is ON THE WIRE ------------

test_a_request_states_the_generation_it_is_bound_to() {
  local dir body tree
  dir=$(new_case wiregen)
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  tree=$(git -C "$dir/home/projects/demo" rev-parse "$HEAD_A^{tree}")
  mkdir -p "$dir/home/data/waiting-item"
  jq -n --arg gate AWAITING_BROWSER_SOL --arg head "$HEAD_A" \
        --arg tree "$tree" --arg pol gen-7 \
    '{gate:$gate,head:$head,tree:$tree,policy_generation:$pol}' \
    > "$dir/home/data/waiting-item/outbound-gate.json"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "wire: emit failed"
  body=$(cat "$dir/forge/last_request_body")

  # A REVIEWER MUST BE ABLE TO SEE WHICH GENERATION THEY ARE ANSWERING. The
  # tree and the policy generation already join the request IDENTITY, so a
  # request under a moved generation is a different question and gets a
  # different id - but only the digest knew that. A ruling that cannot name the
  # generation it rests on cannot be checked against a later movement by
  # anything a human or a reviewer can read.
  printf '%s' "$body" | grep -q "^exact-tree: $tree\$" \
    || fail "wire: the request does not state the tree it is bound to: $body"
  printf '%s' "$body" | grep -q '^policy-generation: gen-7$' \
    || fail "wire: the request does not state the policy generation it is bound to: $body"

  # PAIRED: a request carrying no governed generation keeps exactly the body it
  # has always had, so this is an addition and not a wire change for everyone.
  local dir2 body2
  dir2=$(new_case wirebare)
  declare_gate "$dir2/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir2/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir2" emit waiting-item >/dev/null 2>&1 || fail "wire bare: emit failed"
  body2=$(cat "$dir2/forge/last_request_body")
  printf '%s' "$body2" | grep -q '^exact-tree:' \
    && fail "wire bare: a request with no governed tree still stated one: $body2"
  printf '%s' "$body2" | grep -q '^policy-generation:' \
    && fail "wire bare: a request with no policy generation still stated one: $body2"
  printf '%s' "$body2" | grep -q "^exact-head: $HEAD_A\$" \
    || fail "wire bare: the unchanged body lost its exact head: $body2"
  pass "wire: a request states the generation it is bound to, and omits it when it has none"
}

# --- clause 10: closure is an observation, not an announcement ---------------

# Drive one request all the way to `resumed` with a landing authority minted for
# it, and hand back "<case-dir> <rid> <head> <auth-id>".
#
# THE MINT IS REAL; ONLY THE ACT IS NOT. Performing an actual merge here would
# test the forge, not this closure, so the authority is minted through its own
# owner and then moved to the state a completed act would have left it in. That
# keeps the thing under test - whether closure CHECKS the chain and re-observes
# the target - separate from the thing being simulated.
resumed_with_authority() {  # <name> [<head>] -> "<dir> <rid> <head> <auth>"
  local name=$1 want=${2:-$HEAD_A} dir rid head auth_bin auth_id f
  auth_bin="$ROOT/bin/fm-landing-authorization.sh"
  dir=$(new_case "$name")
  git -C "$dir/home/projects/demo" symbolic-ref --short HEAD > "$dir/forge/base_ref"
  # THE HEAD IS A PARAMETER because the request identity is DERIVED from the
  # governed subject, so two fixtures built the same way are not two requests -
  # they are the same request id computed twice. A control that needs a foreign
  # authority has to make the subject genuinely different, and the head is the
  # load-bearing member of that identity.
  mkdir -p "$dir/home/data/waiting-item"
  jq -n --arg gate AWAITING_BROWSER_SOL --arg head "$want" '{gate:$gate,head:$head}' \
    > "$dir/home/data/waiting-item/outbound-gate.json"
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || return 1
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 80 approved
  run_ob "$dir" ruling --request "$rid" --comment 80 --issue 2 >/dev/null 2>&1 || return 1
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$auth_bin" mint "$rid" \
    --effect pr-merge --method squash >/dev/null 2>&1 || return 1
  run_ob "$dir" resume --request "$rid" >/dev/null 2>&1 || return 1
  for f in "$dir/home/data/landing-authorizations"/*.json; do
    [ -f "$f" ] || continue
    auth_id=$(jq -r '.authorization_id' "$f") || return 1
    jq '.state = "spent"
        | .spend = {started:"2026-08-30T00:00:00Z", act_digest:"x",
                    observed_head:.grant.head, outcome:"applied",
                    finished:"2026-08-30T00:00:01Z", evidence:null}' \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f" || return 1
    break
  done
  [ -n "$auth_id" ] || return 1
  printf '%s %s %s %s\n' "$dir" "$rid" "$head" "$auth_id"
}

test_a_closure_may_not_omit_an_effect_it_had() {
  local dir rid head auth out rc
  read -r dir rid head auth <<< "$(resumed_with_authority closeomit)" \
    || fail "closure: the fixture could not reach a resumed request with an authority"

  # RED: a landing authority was minted and spent for this request, and the
  # closure says only that somebody believes it went well. If naming the
  # authority were optional, every post-effect closure could become an
  # effect-free one by leaving it out - and the verification would be skipped
  # exactly when it matters.
  out=$(run_ob "$dir" close --request "$rid" --disposition 'landed, all good' 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "closure RED: a spent landing authority closed on prose alone: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CLOSURE_UNPROVEN' \
    || fail "closure RED: refused for the wrong reason: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = resumed ] \
    || fail "closure RED: the refused closure still moved the record"
  pass "closure: a request that had an effect authorized may not close on a disposition sentence"
}

test_a_closure_checks_the_chain_and_re_observes_the_target() {
  local dir rid head auth out rc clone ref gen other auth_file saved_auth
  read -r dir rid head auth <<< "$(resumed_with_authority closechain)" \
    || fail "chain: the fixture could not reach a resumed request with an authority"
  clone="$dir/home/projects/demo"
  ref="refs/heads/$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  gen=$(git -C "$clone" rev-parse HEAD)

  auth_file="$dir/home/data/landing-authorizations/$auth.json"
  saved_auth=$(jq -c . "$auth_file")
  jq '.effect.digest = ("0" * 64)' "$auth_file" > "$dir/substituted.json"
  mv "$dir/substituted.json" "$auth_file"
  out=$(run_ob "$dir" close --request "$rid" --disposition landed \
    --authorization "$auth" --target-ref "$ref" --target-generation "$gen" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "chain RED: a substituted authorization returned $rc: $out"
  printf '%s' "$out" | grep -q 'FM_AUTH_RECORD_UNREADABLE' \
    || fail "chain RED: canonical authorization refusal was not named: $out"
  printf '%s\n' "$saved_auth" > "$auth_file"

  # RED 1: an authority that is real, valid and belongs to ANOTHER request is
  # foreign to this closure however good it is in its own right.
  local orid
  read -r _ orid _ other <<< "$(resumed_with_authority closeother "$HEAD_B")" \
    || fail "chain: the second fixture failed"
  [ "$orid" != "$rid" ] \
    || fail "chain: the foreign fixture produced this same request, so it controls nothing"
  cp "$TMP_ROOT/closeother/home/data/landing-authorizations/$other.json" \
     "$dir/home/data/landing-authorizations/$other.json"
  out=$(run_ob "$dir" close --request "$rid" --disposition landed \
    --authorization "$other" --target-ref "$ref" --target-generation "$gen" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "chain RED: a foreign authority closed this request: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_AUTHORITY_FOREIGN' \
    || fail "chain RED: refused for the wrong reason: $out"

  # RED 2: a generation the target ref is NOT actually at. This is the step the
  # disposition sentence was standing in for - a merge command exits 0 for a
  # merge that was queued, superseded, or performed against another head.
  #
  # The wrong value is chosen against what the ref is OBSERVED at rather than
  # picked from the fixture's two heads: the clone's branch happens to sit at
  # HEAD_B, so naming HEAD_B here would have asserted the ref was wrong while
  # handing it the right answer, and the control would have passed by agreeing.
  local wrong=$HEAD_A
  [ "$wrong" != "$gen" ] || wrong=$HEAD_B
  [ "$wrong" != "$gen" ] \
    || fail "chain: no generation distinct from the observed ref was available"
  out=$(run_ob "$dir" close --request "$rid" --disposition landed \
    --authorization "$auth" --target-ref "$ref" --target-generation "$wrong" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "chain RED: a generation the ref is not at was accepted: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CLOSURE_UNPROVEN' \
    || fail "chain RED: refused for the wrong reason: $out"

  git -C "$clone" branch closure-decoy "$gen"
  out=$(run_ob "$dir" close --request "$rid" --disposition landed \
    --authorization "$auth" --target-ref refs/heads/closure-decoy --target-generation "$gen" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "chain RED: an unbound PR target ref closed the merge: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CLOSURE_UNPROVEN' \
    || fail "chain RED: the unbound PR target was refused for the wrong reason: $out"

  # RED 3: an authority that was granted but never spent is permission, not a
  # landing.
  jq '.state = "granted" | .spend = null' \
    "$dir/home/data/landing-authorizations/$auth.json" > "$dir/g.json" \
    && cp "$dir/g.json" "$dir/home/data/landing-authorizations/$auth.json"
  out=$(run_ob "$dir" close --request "$rid" --disposition landed \
    --authorization "$auth" --target-ref "$ref" --target-generation "$gen" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "chain RED: an unspent authority closed an effect: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CLOSURE_UNPROVEN' \
    || fail "chain RED: refused for the wrong reason: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = resumed ] \
    || fail "chain RED: a refused closure still moved the record"

  # GREEN: the spent authority for this exact request, and the generation the
  # ref is genuinely observed at.
  jq '.state = "spent"
      | .spend = {started:"2026-08-30T00:00:00Z", act_digest:"x",
                  observed_head:.grant.head, outcome:"applied",
                  finished:"2026-08-30T00:00:01Z", evidence:null}' \
    "$dir/home/data/landing-authorizations/$auth.json" > "$dir/s.json" \
    && cp "$dir/s.json" "$dir/home/data/landing-authorizations/$auth.json"
  out=$(run_ob "$dir" close --request "$rid" --disposition landed \
    --authorization "$auth" --target-ref "$ref" --target-generation "$gen" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "chain GREEN: a correct post-effect closure was refused, exit $rc: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = closed ] \
    || fail "chain GREEN: the closure did not complete"
  [ "$(jq -r '.disposition.effect.target_generation' "$dir/home/data/outbound-artifacts/$rid.json")" = "$gen" ] \
    || fail "chain GREEN: the closure is not bound to the generation it observed"
  [ "$(jq -r '.disposition.effect.authorization' "$dir/home/data/outbound-artifacts/$rid.json")" = "$auth" ] \
    || fail "chain GREEN: the closure is not bound to the authority it consumed"
  pass "closure: the consumed chain is checked and the target generation is re-observed"
}

# --- clause 3: a wait may not be entered without a request backing it --------

test_a_wait_may_not_be_declared_without_a_backing_request() {
  local dir out rc rid head
  dir=$(new_case declareunbacked)
  # A PROSE row, deliberately: this is the state an item is in BEFORE anything
  # was asked. `declare` is the promotion to a typed declaration, and it is that
  # promotion which must refuse while nothing backs it.
  write_snapshot "$dir/snap.json" external 'awaiting browser sol'

  # RED: nothing has been asked, so the item may not enter the wait. This is the
  # condition seven real items sat in - waiting with no artifact - and it is
  # refused HERE rather than reported by a later sweep.
  out=$(run_ob "$dir" declare waiting-item --gate AWAITING_BROWSER_SOL --head "$HEAD_A" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "declare RED: an unbacked wait was declared: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WAIT_UNBACKED' \
    || fail "declare RED: refused for the wrong reason: $out"
  [ ! -e "$dir/home/data/waiting-item/outbound-gate.json" ] \
    || fail "declare RED: a refused declaration still wrote the wait"

  # GREEN: the same call once the question has actually been asked.
  out=$(run_ob "$dir" emit waiting-item 2>&1) || fail "declare: emit failed: $out"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  out=$(run_ob "$dir" declare waiting-item --gate AWAITING_BROWSER_SOL --head "$head" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "declare GREEN: a backed wait was refused, exit $rc: $out"
  [ "$(jq -r '.request' "$dir/home/data/waiting-item/outbound-gate.json")" = "$rid" ] \
    || fail "declare GREEN: the declaration does not name the request backing it"

  # RED: a DIFFERENT head is a different question, and the request that exists
  # does not back it.
  out=$(run_ob "$dir" declare waiting-item --gate AWAITING_BROWSER_SOL --head "$HEAD_B" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "declare head RED: a wait on an unasked head was declared: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WAIT_UNBACKED' \
    || fail "declare head RED: refused for the wrong reason: $out"
  pass "declare: a wait is refused until a live request backs that exact gate and head"
}

test_declare_preserves_the_generation_binding() {
  local dir rid out rc tree
  dir=$(prepare_subject_case declare-generation)
  tree=$(git -C "$dir/home/projects/demo" rev-parse "$HEAD_A^{tree}")
  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/demo "$tree" pol-g1
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "declare generation: emit failed"
  rid=$(emitted_request_id "$dir")

  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/demo "$tree" pol-g2
  out=$(run_ob "$dir" declare waiting-item --gate AWAITING_BROWSER_SOL --head "$HEAD_A" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "declare generation RED: a request for another policy backed this wait: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WAIT_UNBACKED' \
    || fail "declare generation RED: refused for the wrong reason: $out"

  declare_subject "$dir" AWAITING_BROWSER_SOL "$HEAD_A" o/demo "$tree" pol-g1
  run_ob "$dir" declare waiting-item --gate AWAITING_BROWSER_SOL --head "$HEAD_A" >/dev/null 2>&1 \
    || fail "declare generation GREEN: the exact generation did not admit its wait"
  jq -e --arg r "$rid" --arg t "$tree" \
    '.repo == "o/demo" and .tree == $t and .policy_generation == "pol-g1" and .request == $r' \
    "$dir/home/data/waiting-item/outbound-gate.json" >/dev/null \
    || fail "declare generation GREEN: adding the request erased an applicability field"
  write_typed_ruling "$dir" "$rid" waiting-item "$HEAD_A" 81 approved
  run_ob "$dir" ruling --request "$rid" --comment 81 --issue 2 >/dev/null 2>&1 \
    || fail "declare generation GREEN: the preserved generation read as stale at ruling time"
  pass "declare generation: mismatched policy refuses and exact fields survive promotion"
}

test_a_retired_request_backs_no_wait() {
  local dir out rc rid head
  dir=$(new_case declareterminal)
  write_snapshot "$dir/snap.json" external 'awaiting browser sol'
  out=$(run_ob "$dir" emit waiting-item 2>&1) || fail "terminal: emit failed: $out"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"

  # GREEN half first: while the request is live it backs the wait.
  run_ob "$dir" declare waiting-item --gate AWAITING_BROWSER_SOL --head "$head" >/dev/null 2>&1 \
    || fail "terminal GREEN: a live request did not back the wait"
  rm -f "$dir/home/data/waiting-item/outbound-gate.json"

  # RED: retiring it as malformed must not leave something a wait can rest on.
  # A quarantined request is preserved as evidence precisely because it is NOT
  # an artifact, and this is the path where that distinction is load-bearing.
  run_ob "$dir" quarantine --request "$rid" --ruling 'https://example.invalid/c/1' >/dev/null 2>&1 \
    || fail "terminal: quarantine failed"
  out=$(run_ob "$dir" declare waiting-item --gate AWAITING_BROWSER_SOL --head "$head" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "terminal RED: a quarantined request backed a wait: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WAIT_UNBACKED' \
    || fail "terminal RED: refused for the wrong reason: $out"
  [ ! -e "$dir/home/data/waiting-item/outbound-gate.json" ] \
    || fail "terminal RED: a refused declaration still wrote the wait"
  pass "declare: a retired request is evidence and never backs a wait"
}

# --- clause 7: REVISE routes to correction, and transfers nothing ------------

test_a_revision_never_resumes_the_candidate_it_judged() {
  local dir out rc rid head
  dir=$(new_case revise)
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "revise: emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 70 REVISE
  run_ob "$dir" ruling --request "$rid" --comment 70 --issue 2 >/dev/null 2>&1 \
    || fail "revise: the REVISE ruling did not join"

  # RED: `ruled` says a verdict arrived, never that it let the work continue.
  # Resuming here is how a body that said "change this" clears the wait it
  # should have extended.
  out=$(run_ob "$dir" resume --request "$rid" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "revise RED: a REVISE ruling resumed the item it rejected: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_REVISION_REQUIRED' \
    || fail "revise RED: refused for the wrong reason: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = ruled ] \
    || fail "revise RED: the refused resume still moved the record"

  # PAIRED GREEN: the same path with a non-revising verdict still resumes, so
  # the refusal above is the verdict being classified and not resume breaking.
  local dir2 rid2 head2
  dir2=$(new_case reviseok)
  declare_gate "$dir2/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir2/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir2" emit waiting-item >/dev/null 2>&1 || fail "revise GREEN: emit failed"
  read -r rid2 head2 <<< "$(emitted_rid_and_head "$dir2")"
  write_typed_ruling "$dir2" "$rid2" waiting-item "$head2" 71 approved
  run_ob "$dir2" ruling --request "$rid2" --comment 71 --issue 2 >/dev/null 2>&1 \
    || fail "revise GREEN: the approving ruling did not join"
  out=$(run_ob "$dir2" resume --request "$rid2" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "revise GREEN: a non-revising verdict failed to resume, exit $rc: $out"
  pass "revise: a revising verdict refuses to resume, while another verdict still does"
}

test_a_revision_is_retired_for_correction_and_transfers_nothing() {
  local dir out rc rid head auth
  dir=$(new_case revisecorrect)
  declare_gate "$dir/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "correct: emit failed"
  read -r rid head <<< "$(emitted_rid_and_head "$dir")"
  write_typed_ruling "$dir" "$rid" waiting-item "$head" 72 REVISE
  run_ob "$dir" ruling --request "$rid" --comment 72 --issue 2 >/dev/null 2>&1 \
    || fail "correct: the REVISE ruling did not join"

  # A REVISE RULING IS NOT AUTHORITY. The closed list in the authorization owner
  # cannot classify it, so it grants nothing - checked here rather than assumed,
  # because "REVISE authorizes nothing" is a claim about a different module.
  auth="$ROOT/bin/fm-landing-authorization.sh"
  if [ -x "$auth" ]; then
    out=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$auth" mint "$rid" \
      --effect pr-merge --method squash 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "correct: a REVISE ruling minted a landing authority: $out"
  fi

  out=$(run_ob "$dir" correct --request "$rid" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "correct: retiring a revised request failed, exit $rc: $out"
  [ "$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")" = revised ] \
    || fail "correct: the record was not retired for correction"
  # THE EVIDENCE SURVIVES. A revision retires the request; it never erases the
  # ruling that demanded it.
  [ "$(jq -r '.ruling.verdict' "$dir/home/data/outbound-artifacts/$rid.json")" = REVISE ] \
    || fail "correct: retiring the request lost the ruling that demanded it"

  # NOTHING TRANSFERS: the retired request backs no wait and is adopted by no
  # fresh emit, so the corrected candidate must ask its own question.
  rm -f "$dir/home/data/waiting-item/outbound-gate.json"
  out=$(run_ob "$dir" declare waiting-item --gate AWAITING_BROWSER_SOL --head "$head" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "correct: a revised request still backed a wait: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_WAIT_UNBACKED' \
    || fail "correct: the revised request was refused for the wrong reason: $out"

  # RED: correction is not a way to discard an inconvenient verdict.
  local dir2 rid2 head2
  dir2=$(new_case correctwrong)
  declare_gate "$dir2/home" AWAITING_BROWSER_SOL
  write_snapshot "$dir2/snap.json" outbound 'awaiting browser sol'
  run_ob "$dir2" emit waiting-item >/dev/null 2>&1 || fail "correct RED: emit failed"
  read -r rid2 head2 <<< "$(emitted_rid_and_head "$dir2")"
  write_typed_ruling "$dir2" "$rid2" waiting-item "$head2" 73 approved
  run_ob "$dir2" ruling --request "$rid2" --comment 73 --issue 2 >/dev/null 2>&1 \
    || fail "correct RED: the approving ruling did not join"
  out=$(run_ob "$dir2" correct --request "$rid2" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "correct RED: an approved request was retired as revised: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RULING_IDENTITY_MISMATCH' \
    || fail "correct RED: refused for the wrong reason: $out"
  [ "$(jq -r '.state' "$dir2/home/data/outbound-artifacts/$rid2.json")" = ruled ] \
    || fail "correct RED: the refused correction still moved the record"
  pass "revise: a revision is retired for correction, keeps its evidence, and hands on no authority"
}

test_a_wait_may_not_be_declared_without_a_backing_request
test_declare_preserves_the_generation_binding
test_replaying_the_same_ruling_writes_nothing
test_a_request_states_the_generation_it_is_bound_to
test_a_closure_may_not_omit_an_effect_it_had
test_a_closure_checks_the_chain_and_re_observes_the_target
test_a_retired_request_backs_no_wait
test_a_revision_never_resumes_the_candidate_it_judged
test_a_revision_is_retired_for_correction_and_transfers_nothing
test_a_request_refuses_before_it_can_name_a_transport_venue_as_its_subject
test_a_moved_policy_generation_is_a_different_question
test_a_malformed_request_is_retired_through_the_owner_and_never_resurrected
test_a_finished_request_is_annotated_rather_than_relabelled
test_a_typed_gate_declaration_outranks_stale_hold_prose
test_a_moved_gate_asks_its_own_question
test_a_live_predecessor_is_retired_before_its_successor
test_typed_ruling_form_is_read_field_by_field
test_ruling_form_is_bounded_by_the_envelope
test_a_ruling_without_a_top_level_head_refuses_without_writing
test_typed_ruling_joins_and_records_its_verdict_verbatim
test_typed_ruling_refuses_every_unjoinable_shape
test_typed_ruling_is_discovered_by_poll
test_a_hold_ruling_never_becomes_a_landing_authority
test_unrelated_broken_record_does_not_block_an_exact_request
test_unrelated_identity_mismatch_does_not_block_an_exact_request
test_skipped_record_stays_adverse_everywhere_else
test_unpositionable_subject_always_refuses
test_isolation_preserves_head_and_idempotency
test_sweep_survives_a_row_set_larger_than_one_argument
test_operational_home_repository_needs_no_environment_override
test_home_repository_never_displaces_an_ordinary_clone

printf '\nall fm-outbound-artifact tests passed\n'
