#!/usr/bin/env bash
# fm-pool-lib.sh - the single owner of WHERE one worktree pool's machine-private
# state lives, and of the key that names that pool.
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-pool-lib.sh
#   . "$SCRIPT_DIR/fm-pool-lib.sh"
#
# WHY THIS IS NOT UNDER $FM_HOME. A treehouse pool is keyed by the project path
# it pools worktrees for, and more than one firstmate home can be pointed at the
# same path. Every contender for a slot in that pool must therefore see the same
# state, so pool-scoped state cannot live under one home's state/ directory: a
# lock only one home can take serializes nothing, and a reservation only one home
# can read reserves nothing.
#
# WHY IT IS VALIDATED BEFORE USE. The namespace is a fixed path in a shared
# world-writable directory, so its existence proves nothing about who created it.
# Every resolution therefore re-checks that the directory is a real directory
# (not a symlink), owned by this user, and mode 700, and refuses otherwise
# rather than writing into whatever is sitting at that path. That is the same
# shape and the same validation the herdr presentation lock uses
# (bin/backends/herdr.sh).
#
# WHY THE STATE IS VOLATILE, AND WHY THAT IS CORRECT. Everything keyed here
# describes the CURRENT occupancy of a live pool: which spawn is choosing a slot
# right now, which queued repair the next free slot is held for. None of it
# outlives the machine it describes, so losing it on a reboot loses nothing that
# was still true. Consumers must treat an absent record as "no such state", never
# as an error, and must never store a conclusion here that has to survive.
#
# FM_POOL_NAMESPACE_DIR overrides the namespace root, which exists so a test can
# key a throwaway pool somewhere it owns. It changes WHERE, never WHETHER: the
# ownership and mode validation below runs against the override exactly as it
# runs against the default, so pointing it at a directory this user does not own
# refuses instead of writing there.
set -u

FM_POOL_NAMESPACE_DEFAULT=/tmp/firstmate-worktree-pool

fm_pool_namespace_mode() {  # <dir>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

fm_pool_namespace_uid() {  # <dir>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%u' "$1" 2>/dev/null
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

fm_pool_namespace_valid() {  # <dir>
  local dir=$1 expected_uid owner mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  expected_uid=$(id -u 2>/dev/null) || return 1
  owner=$(fm_pool_namespace_uid "$dir") || return 1
  mode=$(fm_pool_namespace_mode "$dir") || return 1
  [ "$owner" = "$expected_uid" ] && [ "$mode" = 700 ]
}

# The validated namespace directory, created mode-700 when nothing is there yet.
# Non-zero when it neither exists in the required shape nor could be created in
# it, which every caller must treat as a refusal rather than a path to use.
fm_pool_namespace_dir() {
  local dir=${FM_POOL_NAMESPACE_DIR:-$FM_POOL_NAMESPACE_DEFAULT}
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    if ! mkdir -m 700 "$dir" 2>/dev/null; then
      fm_pool_namespace_valid "$dir" || return 1
    fi
  fi
  fm_pool_namespace_valid "$dir" || return 1
  printf '%s\n' "$dir"
}

# The stable key naming one pool, derived from its resolved project path. A hash
# rather than the path itself because the path is arbitrary and this becomes a
# filename; truncated to 32 hex characters because it identifies a pool on one
# machine, not a commit.
fm_pool_key() {  # <pool-real>
  local pool=$1 hash
  [ -n "$pool" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$pool" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$pool" | sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  [ -n "$hash" ] || return 1
  printf '%s\n' "${hash:0:32}"
}

# The path one kind of pool state takes for <pool-real>, as
# "<namespace>/<prefix>-<key><suffix>". Non-zero when the namespace or the key
# could not be resolved, so a caller that ignores the status writes nowhere.
fm_pool_state_path() {  # <pool-real> <prefix> <suffix>
  local pool=$1 prefix=$2 suffix=$3 dir key
  dir=$(fm_pool_namespace_dir) || return 1
  key=$(fm_pool_key "$pool") || return 1
  printf '%s/%s-%s%s\n' "$dir" "$prefix" "$key" "$suffix"
}
