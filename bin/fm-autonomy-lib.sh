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
