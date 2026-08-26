#!/usr/bin/env bash
# tests/watch-lock-helpers.sh - the watcher singleton lock's residue classifier,
# shared by the suites that assert about it (tests/fm-watcher-lock.test.sh and
# tests/fm-watch-checkpoint.test.sh).
#
# It lives here rather than in tests/lib.sh for two reasons. It is not a generic
# assertion - it encodes what a firstmate watch lock is and how its residue is
# read - and tests/lib.sh is a fixture dependency of every parallel-proof
# subject, so a change there invalidates docs/fm-test-isolation-proof.json for
# 24 suites that never use this.
#
# Source it AFTER tests/lib.sh (directly or via tests/wake-helpers.sh); it uses
# that library's fail() and does not source it itself, so a suite's single
# source of lib.sh keeps its one set of side effects.

# A lock still present after its holder was signalled means two completely
# different things, and a bare assert_absent prints the same message for both:
# a cleanup that is still in flight and about to finish, and a lock whose holder
# is ALREADY DEAD, which then survives until some later acquirer happens to
# steal it. Only the second is a product defect.
#
# So the verdict comes from the classification, never from the bound. A spent
# bound with a live holder is a fact about this machine and is reported as
# could-not-observe; a dead or unreadable holder is a product FAIL under any
# load, and widening the bound must never be able to turn one into a pass.
#
# Liveness is read from the process table only. A pid that came out of a lock
# file is never signalled - not even with kill -0.

# fm_test_pid_visible <pid>: true when the process table still shows <pid>.
fm_test_pid_visible() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -d /proc ]; then
    [ -d "/proc/$pid" ]
    return
  fi
  ps -p "$pid" -o pid= >/dev/null 2>&1
}

# fm_test_watch_lock_holder <lockdir> -> alive | dead | unreadable
# "unreadable" covers the empty or non-numeric pid file a signal landing inside
# a truncating rewrite used to leave behind; it is a durable residue too, so it
# must never be classified as anything softer than a dead holder.
fm_test_watch_lock_holder() {
  local lockdir=$1 pid
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) printf 'unreadable\n'; return 0 ;;
  esac
  if fm_test_pid_visible "$pid"; then
    printf 'alive\n'
  else
    printf 'dead\n'
  fi
}

# assert_watch_lock_cleared <lockdir> <polls> <label>
# Returns 0 as soon as the lock is gone, so a healthy case costs one poll.
# On expiry it classifies:
#   dead / unreadable holder -> fail, a durable orphan and a product defect
#   live holder              -> one typed could-not-observe line, return 1
# The caller ends a could-not-observe case with `|| return` rather than
# asserting a property it never got to observe.
# The failure prints the lock's symlink target and the owner directory's file
# list, which is the attribution the bare assertion could not make: a lock
# holding only `pid` was published by a process that died inside its own
# acquire, while one that also holds fm-home / watcher-path / pid-identity was
# owned by a fully started watcher.
assert_watch_lock_cleared() {
  local lockdir=$1 polls=$2 label=$3 i=0 holder link files entry
  while [ "$i" -lt "$polls" ]; do
    [ -e "$lockdir/pid" ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  [ -e "$lockdir/pid" ] || return 0
  holder=$(fm_test_watch_lock_holder "$lockdir")
  link=$(readlink "$lockdir" 2>/dev/null || printf 'not-a-symlink')
  files=
  for entry in "$lockdir"/*; do
    [ -e "$entry" ] || continue
    files="$files${entry##*/} "
  done
  [ -n "$files" ] || files='(none) '
  if [ "$holder" = alive ]; then
    printf 'cno - %s: TEST_ENVIRONMENT_RESOURCE_TIMEOUT watch lock still held by a live holder after %s polls (owner=%s files=%s)\n' \
      "$label" "$polls" "$link" "$files"
    return 1
  fi
  fail "$label: watch lock survived with no live holder (holder=$holder owner=$link files=$files)"
}
