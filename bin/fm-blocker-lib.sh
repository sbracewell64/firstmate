#!/usr/bin/env bash
# Dependency-driven re-evaluation of a declared wait: the single owner of "has
# the named blocker MOVED?", of the durable baseline that question is answered
# against (state/<task>.blockers), and of the refusal a cyclic blocker graph
# gets instead of a walk.
#
# WHY THIS EXISTS. A declared pause is re-surfaced on a bounded cadence
# (FM_PAUSE_RESURFACE_SECS, default 3600s) so a forgotten external wait cannot
# rot invisibly. That recheck asks a wait that CAN change on its own whether it
# still holds. Where the backlog records an exact upstream blocker, the wait
# cannot change until that blocker changes, so the recheck asks a question whose
# answer is fixed and spends a supervisor turn to hear "still waiting". Measured
# 2026-08-17 in the primary home: 22 externally-held items carried a real
# blocked-by edge, six of them with a live declared pause, every one of them
# re-surfacing on the hour. This library replaces that clock with the edge: the
# cadence becomes a cheap sampler, and the WAKE happens only when the blocker
# actually moved, could not be read, or turned out to be part of a cycle.
#
# WHAT IS DELIBERATELY NOT HERE. This changes CADENCE only. The hold keeps every
# other surface it already had - the backlog listing, the fleet snapshot, the
# session-start digest, the open-decision fold, the away-mode return catch-up -
# exactly as bin/fm-classify-lib.sh's captain-gated suppression does. Nothing
# here reads or writes hold_kind, and nothing here is a way to silence a hold:
# suppression is earned by a blocker that is BOTH named and observed unmoved, and
# it ends by itself the moment that blocker moves. Relabelling an engineering
# hold as captain-gated to mute a timer remains what it always was - a false
# authority fact, and worse than noisy polling.
#
# THREE VALUES, NEVER TWO. A blocker that cannot be read has not cleared. Every
# unreadable blocker, every blocker missing from the backlog, every first
# observation with no baseline to compare against, and every graph that ran past
# a bound before it could be enumerated is `unobserved`, which SURFACES. A
# failure outranks could-not-observe, which outranks pass: a mix of one moved
# blocker and one unreadable one is `moved`, and a mix of one unreadable blocker
# and one unchanged one is `unobserved`. `unchanged` - the only verdict that
# suppresses a wake - is reachable only when every recorded blocker was
# enumerated and every one of them was observed on BOTH sides of the comparison.
#
# TWO BOUNDS, BOTH DISCOVERABLE. (1) Movement is detected within one
# FM_PAUSE_RESURFACE_SECS window, because the consumers evaluate at that cadence;
# this library imposes no cadence of its own and answers whenever it is asked.
# (2) The cycle walk is bounded by FM_BLOCKER_MAX_DEPTH and FM_BLOCKER_MAX_NODES.
# Hitting either bound is could-not-observe and names the bound it hit in the
# detail the supervisor reads, because "no cycle" is a negative claim and a
# negative claim needs a complete observable universe.
#
# CRASH SAFETY. Observing and RECORDING are separate calls. fm_blocker_movement
# stages what it saw; fm_blocker_commit promotes that staging file to the
# baseline, and a consumer calls it only after the wake it decided on is durably
# queued. A process killed in between leaves the old baseline, so the next window
# recomputes the same verdict and the wake repeats. That is the same discipline
# the watcher applies to its .seen-* signatures, and for the same reason: a
# swallowed wake is unrecoverable while a repeated one costs a glance.
#
# NOT A PURE LIBRARY. fm_blocker_set and fm_blocker_disposition shell out to the
# backlog reader in FM_HOME - the same tool and the same record
# bin/fm-classify-lib.sh's task_hold_kind reads. Consumers call this only once a
# declared pause has already aged past its window, never on every wake.

FM_BLOCKER_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$FM_BLOCKER_LIB_DIR" != "${BASH_SOURCE[0]}" ] || FM_BLOCKER_LIB_DIR=.
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_BLOCKER_LIB_DIR/fm-pr-lib.sh"

# The COMPLETE movement vocabulary. Every consumer must handle all five; a
# consumer that silently defaults an unlisted verdict is how a correct reader
# still produces a wrong supervision outcome, so the conformance case in
# tests/fm-blocker-lib.test.sh walks this list.
#   none        no blocker is recorded, so there is no edge to drive the wake and
#               the caller keeps its existing timer behavior unchanged;
#   unchanged   every recorded blocker was enumerated and observed on both sides,
#               and none of them moved - the ONLY verdict that suppresses;
#   moved       at least one blocker's disposition changed, or the active blocker
#               set itself gained or lost a member;
#   unobserved  could-not-observe, which is never a pass and always surfaces;
#   cycle       the blocker graph loops, so waiting for movement is unsound - the
#               edge is refused rather than followed, and the wait surfaces.
FM_BLOCKER_MOVEMENT_VOCABULARY='none unchanged moved unobserved cycle'

# 0 if <verdict> is a member of that vocabulary.
fm_blocker_movement_is_known() {  # <verdict>
  [ -n "${1:-}" ] || return 1
  case " $FM_BLOCKER_MOVEMENT_VOCABULARY " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# How far the cycle walk follows blocked-by edges, and how many nodes it may
# expand in total. Both are safety bounds on an external graph this library does
# not own, not tuning knobs: a real backlog chain is a handful of links deep, and
# a walk that reaches either bound has failed to enumerate the graph rather than
# proved it acyclic. Overridable so a home with a genuinely deeper chain can
# raise them rather than live with a permanent could-not-observe.
FM_BLOCKER_MAX_DEPTH_DEFAULT=32
FM_BLOCKER_MAX_NODES_DEFAULT=256

# The disposition string recorded for a blocker that could not be observed.
# Never confusable with a real disposition, which always begins `state=`.
FM_BLOCKER_UNOBSERVED='could-not-observe'

# The first line of a baseline record. A file that does not start with exactly
# this is not a baseline this version wrote, and is treated as absent - which
# yields `unobserved` rather than a comparison against bytes we cannot vouch for.
FM_BLOCKER_RECORD_MAGIC='fm-blocker-baseline.v1'

# --- reading the backlog -----------------------------------------------------

# The backlog reader. Resolved through PATH, like task_hold_kind's, so a test
# drives the real grammar or an explicit double and never a code path that skips
# the reader entirely.
_fm_blocker_reader() { command -v tasks-axi >/dev/null 2>&1; }

# 0 if <item> appears as a whole line in the newline-separated <list>.
_fm_blocker_in_list() {  # <list> <item>
  local list=$1 item=$2 line
  [ -n "$item" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$item" ] && return 0
  done <<EOF
$list
EOF
  return 1
}

# One field out of `tasks-axi show <id> --full`, with a single layer of
# surrounding double quotes removed. The reader quotes a value that contains a
# comma or is the literal placeholder, so `blocked_by: "a,b"` and `hold_kind: "-"`
# both have to come back unquoted for a comparison to mean anything.
_fm_blocker_field() {  # <show-output> <field> -> value, or empty
  local v
  v=$(printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2: //p" | head -1)
  case "$v" in
    '"'*'"') v=${v#\"}; v=${v%\"} ;;
  esac
  printf '%s' "$v"
}

# Make a field value safe to store as one TAB-delimited, semicolon-joined record
# field. The fields read here are constrained identifiers, dates, and yes/no
# tokens, so this guards against a future reader change rather than today's
# output.
_fm_blocker_safe() {  # <value>
  printf '%s' "${1:-}" | tr '\t\n;' '   '
}

# The backlog record for <id>, or rc 2 when it could not be observed: no reader,
# an unusable id, an unreadable home, a reader error (including a not-found id),
# or a response that is not a task record at all. Every one of those is
# could-not-observe rather than "no such blocker", because the caller's next step
# is a claim about whether a wait still holds and none of them supports one.
_fm_blocker_show() {  # <id> [home] -> show output on stdout; rc 2 = could-not-observe
  local id=${1:-} home=${2:-${FM_HOME:-}} out
  fm_task_id_path_safe "$id" || return 2
  _fm_blocker_reader || return 2
  if [ -n "$home" ]; then
    [ -d "$home" ] && [ -r "$home" ] || return 2
    out=$(cd "$home" && tasks-axi show "$id" --full 2>/dev/null) || return 2
  else
    out=$(tasks-axi show "$id" --full 2>/dev/null) || return 2
  fi
  [ -n "$out" ] || return 2
  printf '%s\n' "$out" | grep -q '^[[:space:]]*id: ' || return 2
  printf '%s' "$out"
  return 0
}

# The ACTIVE blocker ids recorded for <task-id>, one per line, in the order the
# backlog reports them. Empty output with rc 0 means the item genuinely records
# no blocker; rc 2 means the set could not be enumerated and no claim about it is
# available. `blocked_by` is the active set, deliberately not `deps`, which
# retains edges that have already been cleared.
#
# A member with characters outside the id grammar makes the whole set
# unenumerable rather than being skipped: dropping it would narrow
# could-not-observe into a smaller set that then compares equal.
fm_blocker_set() {  # <task-id> [home] -> one blocker id per line; rc 2 = could-not-observe
  local out v rest b
  out=$(_fm_blocker_show "${1:-}" "${2:-}") || return 2
  v=$(_fm_blocker_field "$out" blocked_by)
  case "$v" in ''|'-'|none) return 0 ;; esac
  rest=$v
  while [ -n "$rest" ]; do
    b=${rest%%,*}
    if [ "$b" = "$rest" ]; then rest=; else rest=${rest#*,}; fi
    b=${b#"${b%%[![:space:]]*}"}
    b=${b%"${b##*[![:space:]]}"}
    [ -n "$b" ] || continue
    fm_task_id_path_safe "$b" || return 2
    printf '%s\n' "$b"
  done
  return 0
}

# The DISPOSITION of one blocker: the fields that decide whether it still blocks,
# and nothing else. Prose is excluded on purpose - re-wording a hold reason, a
# title, or a body is not movement, and fingerprinting the whole record would
# make every note edit look like one. That is the proxy trap this mechanism
# exists to avoid: assert the property, never something that merely changes
# alongside it.
#
# blocked_by is part of a blocker's own disposition, and that is what carries
# transitive movement into a direct comparison: when a grandparent clears, the
# direct blocker's own active set changes and this string changes with it. Which
# is why movement needs no transitive walk of its own.
fm_blocker_disposition() {  # <blocker-id> [home] -> one canonical line; rc 2 = could-not-observe
  local out f v line=''
  out=$(_fm_blocker_show "${1:-}" "${2:-}") || return 2
  for f in state blocked blocked_by held hold_kind closed; do
    v=$(_fm_blocker_field "$out" "$f")
    [ -n "$v" ] || v='-'
    [ -z "$line" ] || line="$line;"
    line="$line$f=$(_fm_blocker_safe "$v")"
  done
  printf '%s' "$line"
  return 0
}

# --- cycle refusal -----------------------------------------------------------
#
# A blocker graph that loops describes a wait that can never clear on its own, so
# "wake when the blocker moves" would mean "never wake" - the exact silent
# failure this mechanism must not introduce. The loop is REFUSED: the walk stops
# at the repeat, names the path, and the caller surfaces the wait instead of
# suppressing it.
#
# Depth-first with an explicit ancestor path plus a finished set, both plain
# newline-separated strings rather than associative arrays so this runs on bash
# 3.2 as well as 4+. The two globals are per-invocation scratch; every consumer
# calls fm_blocker_cycle inside a command substitution, so they die with that
# subshell.

# 0 a cycle was found (prints the path), 1 no cycle within the bounds, 2
# could-not-observe (prints the bound or the unreadable node that stopped it).
fm_blocker_cycle() {  # <task-id> [home]
  local root=${1:-} home=${2:-${FM_HOME:-}}
  local done='' expanded=0 depth_max nodes_max stack frame kind rest node path depth
  local set rc child frames child_path
  depth_max=${FM_BLOCKER_MAX_DEPTH:-$FM_BLOCKER_MAX_DEPTH_DEFAULT}
  nodes_max=${FM_BLOCKER_MAX_NODES:-$FM_BLOCKER_MAX_NODES_DEFAULT}
  stack="enter"$'\t'"$root"$'\t'"$root"$'\t'"$depth_max"
  while [ -n "$stack" ]; do
    frame=${stack%%$'\n'*}
    if [ "$frame" = "$stack" ]; then stack=; else stack=${stack#*$'\n'}; fi
    kind=${frame%%$'\t'*}; rest=${frame#*$'\t'}
    node=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    path=${rest%%$'\t'*}; depth=${rest#*$'\t'}
    if [ "$kind" = exit ]; then
      if [ -z "$done" ]; then done=$node; else done="$done"$'\n'"$node"; fi
      continue
    fi
    _fm_blocker_in_list "$done" "$node" && continue
    if [ "$depth" -le 0 ]; then
      printf 'the blocker chain below %s is deeper than FM_BLOCKER_MAX_DEPTH=%s, so it was not fully enumerated and no cycle claim is available' \
        "$node" "$depth_max"
      return 2
    fi
    expanded=$(( expanded + 1 ))
    if [ "$expanded" -gt "$nodes_max" ]; then
      printf 'the blocker graph reached FM_BLOCKER_MAX_NODES=%s before it was enumerated, so no cycle claim is available' \
        "$nodes_max"
      return 2
    fi
    set=$(fm_blocker_set "$node" "$home"); rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'the blocker set of %s could not be read, so no cycle claim is available' "$node"
      return 2
    fi
    frames=''
    while IFS= read -r child; do
      [ -n "$child" ] || continue
      child_path="$path>$child"
      case ">$path>" in
        *">$child>"*)
          printf '%s' "$child_path"
          return 0
          ;;
      esac
      _fm_blocker_in_list "$done" "$child" && continue
      if [ -z "$frames" ]; then
        frames="enter"$'\t'"$child"$'\t'"$child_path"$'\t'"$(( depth - 1 ))"
      else
        frames="$frames"$'\n'"enter"$'\t'"$child"$'\t'"$child_path"$'\t'"$(( depth - 1 ))"
      fi
    done <<EOF
$set
EOF
    frame="exit"$'\t'"$node"$'\t'"$path"$'\t'"$depth"
    if [ -n "$frames" ]; then frame="$frames"$'\n'"$frame"; fi
    if [ -n "$stack" ]; then stack="$frame"$'\n'"$stack"; else stack=$frame; fi
  done
  return 1
}

# --- the durable baseline ----------------------------------------------------

# Path of the baseline record, and of the staging file a pending observation
# waits in until its consumer commits it.
fm_blocker_record_path() {  # <state-dir> <task-id>
  fm_task_id_path_safe "${2:-}" || return 1
  printf '%s/%s.blockers' "${1:-}" "${2:-}"
}
fm_blocker_pending_path() {  # <state-dir> <task-id>
  fm_task_id_path_safe "${2:-}" || return 1
  printf '%s/%s.blockers.pending' "${1:-}" "${2:-}"
}

_fm_blocker_discard_pending() {  # <state-dir> <task-id>
  local state=${1:-} task=${2:-}
  [ -d "$state" ] || return 0
  fm_task_id_path_safe "$task" || return 0
  rm -f "$(fm_blocker_pending_path "$state" "$task")" 2>/dev/null || return 1
}

_fm_blocker_stage() {  # <pending-path> <record-bytes>
  local pend=$1 bytes=$2 tmp
  tmp="$pend.tmp.$$"
  if ! (umask 077; printf '%s' "$bytes" > "$tmp") 2>/dev/null \
    || ! mv -f "$tmp" "$pend" 2>/dev/null; then
    rm -f "$tmp" "$pend" 2>/dev/null || true
    return 1
  fi
  return 0
}

# The disposition recorded for <blocker> in a baseline file, or empty when the
# file is absent, is not a baseline this version wrote, or holds no line for that
# blocker. Empty is therefore always "no usable prior observation", never "the
# prior observation was empty".
_fm_blocker_recorded() {  # <record-file> <blocker-id>
  local f=$1 b=$2 first line
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  IFS= read -r first < "$f" || return 0
  [ "$first" = "$FM_BLOCKER_RECORD_MAGIC" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "blocker=$b"$'\t'*) printf '%s' "${line#*$'\t'}"; return 0 ;;
    esac
  done < "$f"
  return 0
}

# Every blocker id a baseline file records, one per line. Used to detect a
# blocker that LEFT the active set, which is movement just as surely as one whose
# disposition changed.
_fm_blocker_recorded_ids() {  # <record-file>
  local f=$1 first line rest
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  IFS= read -r first < "$f" || return 0
  [ "$first" = "$FM_BLOCKER_RECORD_MAGIC" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      blocker=*$'\t'*) rest=${line#blocker=}; printf '%s\n' "${rest%%$'\t'*}" ;;
    esac
  done < "$f"
  return 0
}

# Promote the staged observation to the baseline. A consumer calls this only
# after the wake it decided on is durably queued, so a crash before this point
# repeats the wake instead of losing it. A no-op when nothing was staged, which
# is exactly what a refused cycle leaves behind.
fm_blocker_commit() {  # <state-dir> <task-id> <stage-token>
  local state=${1:-} task=${2:-} pend record token=${3:-} staged
  [ -n "$token" ] || return 0
  [ -d "$state" ] || return 0
  fm_task_id_path_safe "$task" || return 0
  pend=$(fm_blocker_pending_path "$state" "$task") || return 0
  record=$(fm_blocker_record_path "$state" "$task") || return 0
  [ -f "$pend" ] || return 0
  staged=$(sed -n 's/^stage=//p' "$pend" 2>/dev/null | head -1)
  [ "$staged" = "$token" ] || return 0
  mv -f "$pend" "$record" 2>/dev/null || return 1
  return 0
}

# --- the verdict -------------------------------------------------------------

# "blocker" or "blockers" for a newline- or space-separated list, so a detail
# line reads as English at one blocker and at four.
_fm_blocker_noun() {  # <list>
  local n
  n=$(printf '%s' "${1:-}" | wc -w | tr -d '[:space:]')
  [ "${n:-0}" -eq 1 ] && { printf 'blocker'; return 0; }
  printf 'blockers'
}

# The same list rendered inline for a detail sentence.
_fm_blocker_names() {  # <list>
  local s
  s=$(printf '%s' "${1:-}" | tr '\n' ' ')
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# Has the named blocker moved since the last recorded observation?
#
# Prints "<verdict>\t<detail>[\t<stage-token>]" - one vocabulary member, one
# short human sentence, and a commit token only when this call staged an
# observation - and always returns 0, so a consumer branches on the verdict.
#
# Stages what it observed for fm_blocker_commit, except on `cycle`, where nothing
# is staged: a refused graph must keep surfacing until the loop is broken.
fm_blocker_movement() {  # <task-id> <state-dir> [home]
  local task=${1:-} state=${2:-} home=${3:-${FM_HOME:-}}
  local set rc cyc b disp prior pending record pend token
  local moved='' cno='' gone='' first=0 walk_cno=''

  _fm_blocker_discard_pending "$state" "$task" || true
  if ! fm_task_id_path_safe "$task"; then
    printf 'unobserved\tthe task id is not usable, so its blocker set could not be read'
    return 0
  fi
  if [ -z "$state" ] || [ ! -d "$state" ]; then
    printf 'unobserved\tthere is no durable record directory, so no prior blocker observation could be read'
    return 0
  fi
  record=$(fm_blocker_record_path "$state" "$task")
  pend=$(fm_blocker_pending_path "$state" "$task")

  set=$(fm_blocker_set "$task" "$home"); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'unobserved\tthe blocker set recorded for %s could not be read, so an unmoved blocker cannot be claimed' "$task"
    return 0
  fi
  if [ -z "$set" ]; then
    # An EMPTY active set is not automatically "no dependency". The backlog drops
    # a blocker from blocked_by the moment it is cleared or completed, so the
    # last blocker clearing looks exactly like an item that never had one. The
    # baseline is what separates them: blockers recorded last time and none now
    # is the movement this whole mechanism exists to catch, and reading it as
    # `none` would suppress the one wake that matters most. The emptied baseline
    # is staged so the NEXT window legitimately falls back to the timer.
    gone=$(_fm_blocker_names "$(_fm_blocker_recorded_ids "$record")")
    if [ -n "$gone" ]; then
      token="$$.$(date +%s).$RANDOM"
      pending="$FM_BLOCKER_RECORD_MAGIC"$'\n'"task=$task"$'\n'"stage=$token"$'\n'"observed=$(date +%s)"$'\n'
      if ! _fm_blocker_stage "$pend" "$pending"; then
        printf 'unobserved\tthe current blocker observation for %s could not be recorded durably' "$task"
        return 0
      fi
      printf 'moved\t%s %s no longer block %s\t%s' "$(_fm_blocker_noun "$gone")" "$gone" "$task" "$token"
      return 0
    fi
    printf 'none\tno upstream blocker is recorded for %s, so this wait keeps its ordinary recheck' "$task"
    return 0
  fi

  # A loop is refused outright: it says the wait can never clear on its own, so
  # nothing downstream may suppress it and no baseline is recorded that later
  # could. A walk that ran out of bound is only could-not-observe, and is carried
  # forward rather than returned here, so it cannot mask a blocker that actually
  # moved - a failure outranks could-not-observe.
  cyc=$(fm_blocker_cycle "$task" "$home"); rc=$?
  case "$rc" in
    0)
      printf 'cycle\tthe recorded blocker graph loops (%s), so waiting for it to move would wait forever' "$cyc"
      return 0
      ;;
    2) walk_cno=$cyc ;;
  esac

  [ -f "$record" ] || first=1
  token="$$.$(date +%s).$RANDOM"
  pending="$FM_BLOCKER_RECORD_MAGIC"$'\n'"task=$task"$'\n'"stage=$token"$'\n'"observed=$(date +%s)"$'\n'
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    disp=$(fm_blocker_disposition "$b" "$home") || disp=$FM_BLOCKER_UNOBSERVED
    [ -n "$disp" ] || disp=$FM_BLOCKER_UNOBSERVED
    pending="$pending""blocker=$b"$'\t'"$disp"$'\n'
    prior=$(_fm_blocker_recorded "$record" "$b")
    if [ -z "$prior" ] \
      || [ "$prior" = "$FM_BLOCKER_UNOBSERVED" ] \
      || [ "$disp" = "$FM_BLOCKER_UNOBSERVED" ]; then
      # Only two real observations support a movement claim OR a not-moved
      # claim. A missing baseline, an unreadable blocker now, and an unreadable
      # blocker last time all leave the property unobserved.
      cno="$cno $b"
    elif [ "$prior" != "$disp" ]; then
      moved="$moved $b"
    fi
  done <<EOF
$set
EOF

  # A blocker that LEFT the active set moved, and the set above was enumerated,
  # so this is a real observation rather than an absence.
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    _fm_blocker_in_list "$set" "$b" || gone="$gone $b"
  done <<EOF
$(_fm_blocker_recorded_ids "$record")
EOF

  if [ -n "$moved" ]; then
    if ! _fm_blocker_stage "$pend" "$pending"; then
      printf 'unobserved\tthe current blocker observation for %s could not be recorded durably' "$task"
      return 0
    fi
    printf 'moved\t%s %s moved\t%s' "$(_fm_blocker_noun "$moved")" "$(_fm_blocker_names "$moved")" "$token"
    return 0
  fi
  if [ -n "$gone" ]; then
    if ! _fm_blocker_stage "$pend" "$pending"; then
      printf 'unobserved\tthe current blocker observation for %s could not be recorded durably' "$task"
      return 0
    fi
    printf 'moved\t%s %s no longer block %s\t%s' \
      "$(_fm_blocker_noun "$gone")" "$(_fm_blocker_names "$gone")" "$task" "$token"
    return 0
  fi
  if [ -n "$walk_cno" ]; then
    printf 'unobserved\t%s' "$walk_cno"
    return 0
  fi
  if ! _fm_blocker_stage "$pend" "$pending"; then
    printf 'unobserved\tthe current blocker observation for %s could not be recorded durably' "$task"
    return 0
  fi
  if [ "$first" -eq 1 ]; then
    printf 'unobserved\tno prior observation of %s %s was recorded, so movement could not be judged\t%s' \
      "$(_fm_blocker_noun "$set")" "$(_fm_blocker_names "$set")" "$token"
    return 0
  fi
  if [ -n "$cno" ]; then
    printf 'unobserved\t%s %s could not be observed, and an unread blocker has not cleared\t%s' \
      "$(_fm_blocker_noun "$cno")" "$(_fm_blocker_names "$cno")" "$token"
    return 0
  fi
  printf 'unchanged\t%s %s have not moved, so this wait cannot have changed\t%s' \
    "$(_fm_blocker_noun "$set")" "$(_fm_blocker_names "$set")" "$token"
  return 0
}

# The verdict half of an fm_blocker_movement result, and the detail half. Named
# here so every consumer splits the record the same way instead of each one
# spelling the delimiter.
fm_blocker_verdict_of() {  # <movement-result>
  printf '%s' "${1%%$'\t'*}"
}
fm_blocker_detail_of() {  # <movement-result>
  local r=${1:-} detail
  case "$r" in
    *$'\t'*) detail=${r#*$'\t'}; printf '%s' "${detail%%$'\t'*}" ;;
    *) printf '' ;;
  esac
}
fm_blocker_token_of() {  # <movement-result>
  local r=${1:-} rest
  case "$r" in
    *$'\t'*) rest=${r#*$'\t'} ;;
    *) return 0 ;;
  esac
  case "$rest" in *$'\t'*) printf '%s' "${rest#*$'\t'}" ;; esac
}
