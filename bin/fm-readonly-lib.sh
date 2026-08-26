# shellcheck shell=bash
# Single owner of a task's EXECUTION SURFACE: whether the task was dispatched
# onto a pooled worktree it may mutate, or onto a sealed read-only subject it
# may only inspect.
# Usage: . bin/fm-readonly-lib.sh
#
# ONE FACT, ONE SPELLING. The wire spelling is `execution_surface` everywhere
# the fact appears - the `--readonly` flag that selects it, the
# `execution_surface=` line in state/<task-id>.meta, and the predicate every
# consumer reads it through. AGENTS.md section 7 owns what the surface is FOR;
# this library owns only its VALUES, the harnesses that can enforce it, and the
# tool set it denies.
#
# WHY THIS FILE EXISTS. Every non-mutating inspection still consumed a treehouse
# ship slot, because the only way to dispatch a worker was through the pool
# allocator. With the pool parked behind the publication quarantine, a read-only
# check could not run at all. A surface that allocates no slot needs exactly one
# place to declare what "read-only" means, because the claim is enforced in three
# different places - the launch flags, the Bash pre-tool guard, and the subject
# seal - and three copies of a deny list drift the moment one is edited.
#
# THE SURFACE VOCABULARY IS EXACTLY ONE MEMBER, and normalization is
# identity-or-refuse. `readonly` is the only value that ever means read-only:
# nothing folds `ro`, `read-only`, `RO`, or `true` onto it. An absent field is
# NOT a member of this vocabulary and never normalizes - it means the task
# predates this surface or was dispatched onto a worktree, which is the ordinary
# mutable case and must stay distinguishable from an unreadable one.
#
# A NOTE ON WHAT THIS IS NOT. This is a capability boundary, not a security
# boundary. It stops an agent that is trying to do its job correctly from
# mutating a subject it was told to inspect; it is not designed against a worker
# deliberately escaping it, and nothing here should ever be cited as if it were.
# capabilities/catalog.json makes the same distinction for the same reason.

# The one member. Quoted deliberately: `readonly` is also a shell builtin, and an
# unquoted bare word here reads as a call to it rather than as this value.
FM_READONLY_SURFACE='readonly'

# The meta field carrying it. Named once here so a producer and a consumer
# cannot disagree about the spelling the way `yolo=` once did
# (bin/fm-autonomy-lib.sh records that failure in full).
FM_READONLY_META_FIELD=execution_surface

# Identity-or-refuse. Prints the member on success; prints nothing and returns
# non-zero for every other input, INCLUDING the empty string.
fm_readonly_surface_normalize() {  # <value>
  case "${1-}" in
    "$FM_READONLY_SURFACE") printf '%s' "$FM_READONLY_SURFACE" ;;
    *) return 1 ;;
  esac
}

# Read the surface out of a task's metadata. Three-valued by construction, and
# the three values are deliberately not collapsed:
#   0 + "readonly"  the record says this is a read-only task
#   1 + ""          the record is readable and says otherwise (or says nothing),
#                   which is the ordinary mutable task
#   2 + ""          the record could not be read at all
# A consumer that treats 2 as 1 would silently run a read-only task's teardown
# down the pooled-worktree path, so the caller is made to tell them apart.
fm_readonly_meta_surface() {  # <meta-file>
  local meta=${1-} raw count grep_rc
  [ -n "$meta" ] && [ -f "$meta" ] && [ ! -L "$meta" ] || return 2
  # `grep -c` exits 1 when the count is legitimately ZERO and 2 only when it
  # actually failed, so a bare `|| return 2` would report every ordinary task -
  # every task that simply has no execution_surface line - as an unreadable
  # record. Branch on the exit STATUS, because a zero produced by "no match" and
  # a zero produced by "grep could not read this" are different observations.
  count=$(grep -c "^$FM_READONLY_META_FIELD=" "$meta" 2>/dev/null)
  grep_rc=$?
  [ "$grep_rc" -le 1 ] || return 2
  [ -n "$count" ] || count=0
  case "$count" in
    0) return 1 ;;
    1) ;;
    # An ambiguous record is unreadable, never "the last one wins": a second
    # line is exactly what a forged key line would look like.
    *) return 2 ;;
  esac
  raw=$(sed -n "s/^$FM_READONLY_META_FIELD=//p" "$meta" 2>/dev/null) || return 2
  fm_readonly_surface_normalize "$raw" || return 1
}

# True when this task's metadata declares the read-only surface. Kept as its own
# predicate so a consumer that genuinely only needs the yes/no is not made to
# spell the three-valued return, but note it folds could-not-observe onto "no":
# use it only where the ordinary mutable path is the SAFE default, and call
# fm_readonly_meta_surface directly everywhere else.
fm_readonly_meta_is_readonly() {  # <meta-file>
  fm_readonly_meta_surface "$1" >/dev/null 2>&1
}

# The tools a read-only launch denies outright, one per line.
#
# This is the deny list for the harness's OWN tool gate. It names the file
# mutators, not Bash: Bash cannot be denied wholesale, because inspection IS
# reading files and running read-only commands, so the Bash argv guard in
# bin/fm-readonly-pretool-check.sh carries that half of the enforcement.
#
# Claude's tool names are the vendor's, so this list is harness-coupled by
# nature. That is exactly why fm_readonly_harness_enforceable admits only
# harnesses whose deny vocabulary this repo has actually verified: a deny list
# spelled for one vendor and passed to another denies nothing and reports
# nothing, which is the silent-vacuity failure the firstmate-coding-guidelines
# skill's harness-dependent-checks section exists to refuse.
fm_readonly_denied_tools() {
  cat <<'EOF'
Edit
Write
MultiEdit
NotebookEdit
EOF
}

# The same list as one comma-separated argument, for a CLI that takes it that
# way. Derived from the list above rather than spelled twice.
fm_readonly_denied_tools_csv() {
  local out='' t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ -z "$out" ]; then out=$t; else out="$out,$t"; fi
  done <<EOF
$(fm_readonly_denied_tools)
EOF
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Whether a harness can MECHANICALLY enforce the read-only posture at its own
# launch boundary, which is the condition bin/fm-spawn.sh refuses a readonly
# dispatch on.
#
# Exactly one harness qualifies today, and the bar is empirical rather than
# hopeful: the installed CLI must expose both a non-prompting permission mode
# and a tool deny list, verified by running it, and its PreToolUse hook shape
# must be one bin/fm-readonly-pretool-check.sh actually speaks.
#
#   claude   verified on 2.1.246: `--permission-mode` accepts dontAsk, and
#            `--disallowedTools` takes the deny list above. Its PreToolUse hook
#            contract (exit 2 + a deny object on stderr, stdout kept empty) is
#            the one bin/fm-cd-pretool-check.sh already speaks, and
#            docs/verification/readonly-execution-surface.md records the run.
#
# Every other adapter is refused BY NAME rather than launched with a posture
# nobody proved. That is the whole point: a readonly dispatch that silently
# degraded to an ordinary autonomous launch would be a worker with write access
# to a subject it was told it could not touch, reported as read-only.
#
# Adding an adapter here REQUIRES the same evidence: run the installed CLI,
# record it in docs/verification/readonly-execution-surface.md, and extend
# tests/fm-readonly-surface.test.sh's refusal case so the new arm cannot go
# vacuous.
fm_readonly_harness_enforceable() {  # <harness>
  case "${1-}" in
    claude) return 0 ;;
    *) return 1 ;;
  esac
}

# Every harness the predicate above admits, one per line.
#
# The roster it filters is DERIVED from bin/fm-launch-lib.sh's launch_harnesses,
# never hand-listed here. A second copy of the adapter list would go vacuous the
# day an adapter is added rather than renamed - the same failure launch_harnesses
# itself was built to prevent, reintroduced one file over. A caller must source
# fm-launch-lib.sh first; without it the roster cannot be derived at all, and
# that is could-not-observe (non-zero), never an empty set of enforceable
# harnesses.
fm_readonly_enforceable_harnesses() {
  local h out=''
  command -v launch_harnesses >/dev/null 2>&1 || return 1
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    fm_readonly_harness_enforceable "$h" || continue
    out="$out$h"$'\n'
  done <<EOF
$(launch_harnesses)
EOF
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}
