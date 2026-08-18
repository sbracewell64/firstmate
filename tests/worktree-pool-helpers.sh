#!/usr/bin/env bash
# tests/worktree-pool-helpers.sh - shared fixtures for the suites that exercise
# a treehouse worktree pool: bin/fm-worktree-guard.sh's slot decision and the
# slot reservation that decision applies.
#
# These encode pool-shaped assumptions - a project plus numbered slot worktrees,
# and a fake `treehouse` whose `status --json` is canned per case - so they live
# here rather than in the generic tests/lib.sh, which deliberately bundles no
# behavior-specific mock.
#
# make_pool and its callers read $TMP_ROOT from the sourcing suite, which is the
# contract these were written against and is preserved verbatim so no call site
# changes. A sourcing suite must therefore set TMP_ROOT before calling them.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A project repo plus <n> pool-slot worktrees, mimicking a treehouse pool.
# Echoes the project dir; slots land at <proj>/../slots/<n>.
make_pool() {  # <case-name> <slot-count>
  local name=$1 count=$2 base proj i
  base="$TMP_ROOT/$name"
  proj="$base/proj"
  mkdir -p "$proj"
  git -C "$proj" init -q -b main
  printf 'base\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" commit -qm initial
  for i in $(seq 1 "$count"); do
    git -C "$proj" worktree add --quiet --detach "$base/slots/$i" main
  done
  printf '%s\n' "$proj"
}

slot_path() {  # <proj> <n>
  printf '%s/slots/%s\n' "$(dirname "$1")" "$2"
}


# Put <slot> on a branch carrying <n> commits that are not on main.
give_unlanded_branch() {  # <slot> <branch> [n]
  local slot=$1 branch=$2 n=${3:-1} i
  git -C "$slot" checkout -q -b "$branch" main
  for i in $(seq 1 "$n"); do
    printf 'work %s\n' "$i" > "$slot/work-$i.txt"
    git -C "$slot" add "work-$i.txt"
    git -C "$slot" commit -qm "unlanded $i"
  done
}


# A fake `treehouse` whose `status --json` echoes the fixture, on a PATH shim.
# `status --help` advertises --json, which is how the guard probes capability
# (treehouse v2.1.0 and newer). Any other subcommand fails loudly: the guard
# must never invoke one.
install_fake_treehouse() {  # <fakebin> <json>
  local fakebin=$1 json=$2
  printf '%s' "$json" > "$fakebin/../treehouse-status.json"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --help ]; then
  printf 'Usage:\n  treehouse status [flags]\n\nFlags:\n  -h, --help   help for status\n      --json   Print pool status as JSON\n'
  exit 0
fi
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  cat "$(dirname "$0")/../treehouse-status.json"
  exit 0
fi
echo "fake treehouse: unexpected invocation: $*" >&2
exit 3
SH
  chmod +x "$fakebin/treehouse"
}


slot_json() {  # <name> <status> <path> ...
  local out="" name status path
  while [ $# -gt 0 ]; do
    name=$1 status=$2 path=$3
    shift 3
    [ -z "$out" ] || out="$out,"
    out="$out{\"name\":\"$name\",\"status\":\"$status\",\"path\":\"$path\",\"processes\":[]}"
  done
  printf '[%s]' "$out"
}
