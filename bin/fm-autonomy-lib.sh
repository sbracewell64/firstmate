# shellcheck shell=bash
# Single owner of a task's AUTONOMY STATE: whether firstmate holds standing
# routine approval authority for that task, or the captain does.
# Usage: . bin/fm-autonomy-lib.sh
#
# ONE FACT, ONE SPELLING. The wire spelling is `yolo` everywhere the fact
# appears - the `--yolo <on|off>` flag, the `yolo=` line in
# state/<task-id>.meta, the `yolo=` field in a capacity-deferral record, and the
# `+yolo` marker in data/projects.md. "Autonomy state" is this library's name
# for that same fact and never a second concept, so nothing here belongs in
# docs/vocabulary-collisions.md. AGENTS.md section 7 owns what the posture
# AUTHORIZES; this library owns only its VALUES and the one comparison that
# reads them.
#
# WHY THIS FILE EXISTS. The producer and the consumer of `yolo=` did not agree
# on its values, and nothing refused the disagreement. bin/fm-spawn.sh wrote
# `yolo=on`; the decision-disposition fold in bin/fm-classify-lib.sh tested
# `yolo= 1`. The SELF_HANDLE branch was therefore unreachable by any value the
# fleet writes: every routine decision on a task that carried standing routine
# authority was rendered as owed by the captain rather than as firstmate's own
# move. Measured live when the defect was found, 48 of 49 open decisions were
# addressed to the captain that way, and by the fleet's own rule 1 should have
# been. The comparison was never wrong about its own operands - it was
# comparing against a vocabulary its producer does not use.
#
# So the repair is not the comparison. It is that there is now exactly ONE
# place where a value of this fact is declared, one place where a producer
# validates it before writing it, and one place where a consumer decides what
# it means. tests/fm-task-delivery.test.sh pairs the two ends by RUNNING the
# real producer and feeding what it wrote to the real consumer, so the two
# cannot drift apart again without a red suite.
#
# THE VOCABULARY IS EXACTLY TWO MEMBERS AND NORMALIZATION IS NOT PERMISSIVE.
# fm_autonomy_state_normalize is identity-or-refuse: it does not fold `1`,
# `true`, `yes`, or `ON` onto a member. Accepting those would be a second
# vocabulary living inside the owner of the first, which is the drift this
# library exists to end rather than to relocate.
#
# RECORDED IS NOT EFFECTIVE, and that is the second drift this library ends.
# `yolo=` in state/<task-id>.meta is a SNAPSHOT taken when the task was
# dispatched. The captain's standing posture lives at its canonical owner,
# data/projects.md, read by bin/fm-project-mode.sh. When the captain changed the
# standing posture, every task already under way kept projecting the snapshot,
# and a fleet whose registry granted standing routine authority for every
# project went on addressing its decisions to the captain because a record
# written days earlier still said `off`. A snapshot that outranks the canonical
# owner is a second owner of the same fact.
#
# So fm_autonomy_state_effective below resolves the posture the way an authority
# is resolved rather than the way a record is read: it asks the canonical owner,
# every time, and the snapshot answers only where the canonical owner is silent
# about the project. bin/fm-classify-lib.sh's disposition fold and
# bin/fm-landing-seam-lib.sh's authority compile both consume it, so there is one
# resolution and not one per consumer. THIS LIBRARY IS STILL PURE AT SOURCE TIME:
# nothing runs until a caller asks for the effective value, so a consumer that
# only needs the vocabulary or the comparison still pays nothing.

# Directory of this library, used to locate the sibling canonical posture owner.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a bin/
# script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_AUTONOMY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_AUTONOMY_LIB_DIR="."

# The two members, and the closed set built from them so no caller spells the
# set itself.
FM_AUTONOMY_STATE_SELF=on
FM_AUTONOMY_STATE_CAPTAIN=off
# shellcheck disable=SC2034 # Read by sourcing callers (tests/fm-task-delivery.test.sh).
FM_AUTONOMY_STATE_VOCABULARY="$FM_AUTONOMY_STATE_SELF $FM_AUTONOMY_STATE_CAPTAIN"

# 0 if <value> is a member of that vocabulary.
fm_autonomy_state_is_known() {  # <value>
  [ -n "${1-}" ] || return 1
  case "$1" in
    "$FM_AUTONOMY_STATE_SELF" | "$FM_AUTONOMY_STATE_CAPTAIN") return 0 ;;
  esac
  return 1
}

# The canonical member for <value>, for a PRODUCER about to record it: prints
# the member and returns 0, or prints nothing and returns 1. A producer calls
# this so it refuses rather than writing a value no consumer accepts.
fm_autonomy_state_normalize() {  # <value>
  fm_autonomy_state_is_known "${1-}" || return 1
  printf '%s' "$1"
}

# THE COMPARISON BOUNDARY, and the only one. Three answers, never two:
#   0  firstmate holds standing routine authority for this task
#   1  the captain holds it
#   2  the value is outside the vocabulary, which is could-not-observe - a
#      caller must not narrow it into either of the other two, because "this
#      task is the captain's" and "this record cannot be read" are different
#      facts and only one of them is about the task.
fm_autonomy_self_handles() {  # <value>
  case "${1-}" in
    "$FM_AUTONOMY_STATE_SELF") return 0 ;;
    "$FM_AUTONOMY_STATE_CAPTAIN") return 1 ;;
  esac
  return 2
}

# The autonomy state recorded in <meta-file>. Three answers, never two:
#   0  a `yolo=` line is present and its value is a member; stdout is that
#      member.
#   1  the file is readable and carries NO `yolo=` line. This is a LIVE
#      producer state and not an error: bin/fm-spawn.sh deliberately records no
#      posture for a scout, whose deliverable is a report rather than a merge.
#      Nothing recorded standing authority, so the captain holds it.
#   2  could-not-observe: the file is absent or unreadable, or a `yolo=` line
#      is present carrying a value outside the vocabulary - including the
#      empty value a truncated write leaves behind, which is a broken record
#      rather than an absent field. stdout is the raw value when there was one,
#      so a caller can name what it could not read.
#
# The LAST `yolo=` line wins, matching every other reader of this file
# (fm_meta_get in bin/fm-backend.sh).
fm_autonomy_state_of_meta() {  # <meta-file>
  local meta=${1-}
  local line raw
  [ -n "$meta" ] && [ -r "$meta" ] || return 2
  line=$(grep '^yolo=' "$meta" 2>/dev/null | tail -1) || true
  # No line at all and a line spelling an empty value are different facts, so
  # the presence test is on the whole line rather than on the stripped value.
  [ -n "$line" ] || return 1
  raw=${line#yolo=}
  if fm_autonomy_state_is_known "$raw"; then
    printf '%s' "$raw"
    return 0
  fi
  printf '%s' "$raw"
  return 2
}

# --- the EFFECTIVE posture ---------------------------------------------------
#
# The canonical owner is bin/fm-project-mode.sh over data/projects.md. This
# resolver never parses that registry itself: a second parser is a second owner,
# and the registry's line format is that script's contract. Overridable so a
# caller can point at a resolver it controls; absent, the real sibling.
FM_AUTONOMY_PROJECT_MODE_BIN="${FM_AUTONOMY_PROJECT_MODE_BIN:-$_FM_AUTONOMY_LIB_DIR/fm-project-mode.sh}"

# WHY ONE MEMO PER PROCESS, and why it is a correctness choice rather than an
# optimization. A single fold - one open-decision listing, one landing decision -
# must see ONE registry. Re-invoking the owner mid-fold could answer two
# different postures for the same project inside one listing, which is a listing
# that contradicts itself. So the answer is resolved at most once per project per
# process, and every new process resolves it again: the canonical owner is a FILE
# READ on each resolution, which is exactly what makes the posture survive a
# restart without anything having to remember it.
_FM_AUTONOMY_REGISTRY_MEMO=
_FM_AUTONOMY_REG_YOLO=
_FM_AUTONOMY_REG_SOURCE=

# 0 when the canonical owner produced a readable answer for <project-name>,
# setting _FM_AUTONOMY_REG_YOLO and _FM_AUTONOMY_REG_SOURCE; 1 when it could not
# be asked at all, which is could-not-observe about the posture rather than a
# posture of `off`.
_fm_autonomy_registry_posture() {  # <project-name>
  local name=${1-} entry line out yolo source
  [ -n "$name" ] || return 1
  _FM_AUTONOMY_REG_YOLO=
  _FM_AUTONOMY_REG_SOURCE=
  # The memo is matched by exact field, never by pattern: a project name is
  # operator-supplied text and would otherwise be read as a regular expression.
  while IFS=$'\t' read -r entry yolo source; do
    [ "$entry" = "$name" ] || continue
    _FM_AUTONOMY_REG_YOLO=$yolo
    _FM_AUTONOMY_REG_SOURCE=$source
    return 0
  done <<EOF
$_FM_AUTONOMY_REGISTRY_MEMO
EOF
  [ -x "$FM_AUTONOMY_PROJECT_MODE_BIN" ] || return 1
  # FM_HOME is passed explicitly rather than left to the ambient environment: a
  # caller resolving a posture for one home sets it as a shell variable, and a
  # shell variable is invisible to a child process. Without this the canonical
  # owner would be read out of whichever home the environment happened to name.
  out=$(FM_HOME="${FM_HOME:-}" "$FM_AUTONOMY_PROJECT_MODE_BIN" --with-source "$name" 2>/dev/null) || return 1
  line=$(printf '%s\n' "$out" | awk 'NF {print; exit}')
  yolo=$(printf '%s' "$line" | awk '{print $2}')
  source=$(printf '%s' "$line" | awk '{print $3}')
  case "$source" in
    registered|unregistered|no-registry) ;;
    *) return 1 ;;
  esac
  _FM_AUTONOMY_REGISTRY_MEMO="${_FM_AUTONOMY_REGISTRY_MEMO}${name}"$'\t'"${yolo}"$'\t'"${source}"$'\n'
  _FM_AUTONOMY_REG_YOLO=$yolo
  _FM_AUTONOMY_REG_SOURCE=$source
  return 0
}

# The project a task record names, as the registry spells it. The meta carries a
# clone PATH and the registry carries a NAME; bin/fm-spawn.sh already derives one
# from the other with basename at dispatch, so the same derivation is used here
# rather than a second convention.
fm_autonomy_meta_project() {  # <meta-file>
  local meta=${1-} line
  [ -n "$meta" ] && [ -r "$meta" ] || return 1
  line=$(grep '^project=' "$meta" 2>/dev/null | tail -1) || true
  [ -n "$line" ] || return 1
  line=${line#project=}
  line=${line%/}
  [ -n "$line" ] || return 1
  printf '%s' "${line##*/}"
}

# Where the effective answer came from, for a caller that must report it, and
# the answer itself. One of: registry, task-record, none.
#
# STDOUT AND THESE GLOBALS ARE THE SAME ANSWER, published twice on purpose. A
# caller that needs only the value reads stdout in a command substitution, which
# is a SUBSHELL and therefore cannot see any of these; a caller that must report
# WHERE the answer came from calls the function in the current shell, discards
# stdout, and reads them here. Publishing the value as a global too is what keeps
# that second caller from having to run the resolution twice to get both halves.
FM_AUTONOMY_EFFECTIVE_SOURCE=
FM_AUTONOMY_EFFECTIVE_PROJECT=
FM_AUTONOMY_EFFECTIVE_STATE=

# The autonomy state that APPLIES to this task now. Same three answers as
# fm_autonomy_state_of_meta, so a caller already reading that one changes only
# which function it calls:
#   0  stdout is a vocabulary member - the posture in force
#   1  nothing granted standing authority anywhere, so the captain holds it
#   2  could-not-observe: the record is absent or unreadable, the canonical owner
#      could not be asked, or a recorded value is outside the vocabulary
#
# PRECEDENCE. The canonical owner wins wherever it speaks about the project,
# because it is where the captain records the standing choice and it is current.
# A registry that omits the project has spoken: the conservative `off` it
# returns outranks the task record. Only a home with no registry is silent, and
# there the task's own record stands. Where neither speaks, the captain holds it.
# shellcheck disable=SC2034 # the three globals are read by sourcing callers
fm_autonomy_state_effective() {  # <meta-file>
  local meta=${1-} name recorded rc=0
  FM_AUTONOMY_EFFECTIVE_SOURCE=none
  FM_AUTONOMY_EFFECTIVE_PROJECT=
  FM_AUTONOMY_EFFECTIVE_STATE=
  [ -n "$meta" ] && [ -r "$meta" ] || return 2
  if name=$(fm_autonomy_meta_project "$meta"); then
    FM_AUTONOMY_EFFECTIVE_PROJECT=$name
    if ! _fm_autonomy_registry_posture "$name"; then
      # The canonical owner could not be asked. That is could-not-observe about
      # the posture, and narrowing it into the snapshot would put the second
      # owner back in exactly the case where the first one is unavailable.
      return 2
    fi
    if [ "$_FM_AUTONOMY_REG_SOURCE" = registered ] \
      || [ "$_FM_AUTONOMY_REG_SOURCE" = unregistered ]; then
      fm_autonomy_state_is_known "$_FM_AUTONOMY_REG_YOLO" || return 2
      FM_AUTONOMY_EFFECTIVE_SOURCE=registry
      FM_AUTONOMY_EFFECTIVE_STATE=$_FM_AUTONOMY_REG_YOLO
      printf '%s' "$_FM_AUTONOMY_REG_YOLO"
      return 0
    fi
  fi
  recorded=$(fm_autonomy_state_of_meta "$meta") || rc=$?
  # Only a record that actually carries a member is a source. A meta with no
  # `yolo=` line granted nothing, and saying `task-record` there would name a
  # source that said nothing.
  if [ "$rc" -eq 0 ]; then
    FM_AUTONOMY_EFFECTIVE_SOURCE=task-record
    FM_AUTONOMY_EFFECTIVE_STATE=$recorded
  fi
  printf '%s' "$recorded"
  return "$rc"
}
