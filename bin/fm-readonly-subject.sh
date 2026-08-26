#!/usr/bin/env bash
# Seal an exact commit into an immutable inspection subject, and prove later
# that nothing under it moved.
#
# This is the "explicit immutable inputs" half of the read-only execution
# surface (bin/fm-readonly-lib.sh owns the surface itself). A read-only task
# gets no worktree, so it needs a subject that is BOTH placed at an exact head
# and mechanically unable to drift while it is being inspected.
#
# Two independent mechanisms, deliberately, because they fail differently:
#   PREVENTION  every sealed file and directory is stripped of write permission,
#               so an ordinary mutation fails at the OS rather than at a policy.
#   DETECTION   a manifest of per-file digests plus the exact head/tree binding,
#               so a mutation that DID land - through a mode change, a tool
#               running as another user, or a permission the OS did not enforce -
#               is still observable afterwards.
# Prevention alone would be a claim nobody checks; detection alone would let a
# worker corrupt its own subject and only find out at teardown.
#
# Usage:
#   fm-readonly-subject.sh seal --repo <dir> --head <commit-ish> --dest <dir>
#                               [--path <repo-relative-path>]...
#   fm-readonly-subject.sh verify --dest <dir>
#   fm-readonly-subject.sh head --dest <dir>
#
# seal   Extracts <head> from <repo> into <dest>/subject via `git archive`, so
#        the content is the commit's own tree and never the working copy's
#        uncommitted state. --path restricts the extraction to those
#        repo-relative paths (repeatable); with none, the whole tree is sealed.
#        Writes <dest>/MANIFEST (the format below), then removes write
#        permission from everything under <dest>/subject.
#        CREATE-ONLY: it refuses a <dest> that already exists, so a seal can
#        never overwrite or partially rewrite an earlier subject.
# verify Recomputes every digest and compares against MANIFEST. Detects changed
#        bytes, added files, and removed files as three distinct, separately
#        reported outcomes.
# head   Prints the exact commit the subject was sealed from, for a caller that
#        needs to cite it.
#
# MANIFEST format (one record per line, tab-separated, LC_ALL=C sorted by path):
#   head<TAB><commit>            exactly once, first
#   tree<TAB><tree>              exactly once, second
#   file<TAB><rel-path><TAB><sha256>
# A path containing a tab, newline, or carriage return is REFUSED at seal time
# rather than written, because such a path cannot round-trip through this format
# and a manifest that cannot be re-read is not evidence.
#
# Exit status:
#   0  seal completed / subject verified intact
#   1  a usage or environment error (bad arguments, missing git, unreadable repo)
#   2  VERIFY FAILED: the subject moved. The differences are printed.
#   3  COULD-NOT-OBSERVE: the manifest or subject could not be read well enough
#      to judge. Never folded onto either of the other two, because "the subject
#      is intact" and "nobody could tell" are different facts and only one of
#      them is safe to act on (AGENTS.md hard rule 5).
set -u

usage() {
  sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "error: $*" >&2; exit 1; }

digest_file() {  # <path>
  local path=$1 out=
  [ -f "$path" ] && [ -r "$path" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$path" 2>/dev/null) || return 1
    out=${out%% *}
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$path" 2>/dev/null) || return 1
    out=${out%% *}
  elif command -v python3 >/dev/null 2>&1; then
    out=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$path" 2>/dev/null) || return 1
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Every regular file under a directory, repo-relative, LC_ALL=C sorted. Symlinks
# are listed but never followed: a digest of a link's target would attribute a
# file outside the seal to the seal.
list_subject_files() {  # <subject-dir>
  local dir=$1
  ( cd "$dir" 2>/dev/null && find . -type f -print 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort ) || return 1
}

path_is_recordable() {  # <path>
  case "$1" in
    *$'\t'*|*$'\n'*|*$'\r'*|'') return 1 ;;
    *) return 0 ;;
  esac
}

cmd_seal() {
  local repo='' head='' dest='' want='' rel abs digest tree resolved
  local -a paths=()
  while [ "$#" -gt 0 ]; do
    if [ -n "$want" ]; then
      case "$1" in --*) die "--$want requires a value" ;; esac
      case "$want" in
        repo) repo=$1 ;;
        head) head=$1 ;;
        dest) dest=$1 ;;
        path) paths+=("$1") ;;
      esac
      want=
      shift
      continue
    fi
    case "$1" in
      --repo) want=repo ;;
      --repo=*) repo=${1#--repo=} ;;
      --head) want='head' ;;
      --head=*) head=${1#--head=} ;;
      --dest) want=dest ;;
      --dest=*) dest=${1#--dest=} ;;
      --path) want=path ;;
      --path=*) paths+=("${1#--path=}") ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  [ -z "$want" ] || die "--$want requires a value"
  [ -n "$repo" ] || die "seal requires --repo"
  [ -n "$head" ] || die "seal requires --head"
  [ -n "$dest" ] || die "seal requires --dest"
  command -v git >/dev/null 2>&1 || die "git is required to seal a subject"
  [ -d "$repo" ] || die "not a directory: $repo"

  # CREATE-ONLY. A seal that could land in an existing directory could also
  # half-overwrite a subject another task is still inspecting, and the resulting
  # manifest would describe neither tree.
  [ ! -e "$dest" ] || die "refusing to seal into an existing path: $dest"

  resolved=$(git -C "$repo" rev-parse --verify --quiet "$head^{commit}" 2>/dev/null) \
    || die "cannot resolve '$head' to a commit in $repo"
  tree=$(git -C "$repo" rev-parse --verify --quiet "$resolved^{tree}" 2>/dev/null) \
    || die "cannot resolve the tree of $resolved in $repo"

  mkdir -p "$dest/subject" || die "cannot create $dest/subject"

  # git archive writes the COMMIT's tree, so uncommitted working-copy bytes can
  # never leak into a subject that claims to be an exact head.
  #
  # git's own stderr is carried into the refusal rather than discarded. A
  # swallowed message here reports "archive failed" for an untracked path, a bad
  # commit, and a full disk alike, which tells the caller nothing about which
  # one it was - and a path that is untracked AT THAT HEAD is the common case,
  # because a task frequently asks to seal a file its own branch just added.
  local archive_err archive_rc
  archive_err=$(mktemp) || die "cannot create a scratch file"
  if [ "${#paths[@]}" -gt 0 ]; then
    git -C "$repo" archive --format=tar "$resolved" -- "${paths[@]}" 2>"$archive_err" \
      | tar -x -C "$dest/subject"
    archive_rc=${PIPESTATUS[0]}
  else
    git -C "$repo" archive --format=tar "$resolved" 2>"$archive_err" \
      | tar -x -C "$dest/subject"
    archive_rc=${PIPESTATUS[0]}
  fi
  if [ "$archive_rc" -ne 0 ]; then
    echo "error: git archive of $resolved failed (exit $archive_rc):" >&2
    sed 's/^/  git: /' "$archive_err" >&2
    rm -f "$archive_err"
    # Undo the directory THIS invocation created. Seal refuses a pre-existing
    # --dest, so leaving the half-extracted one behind would make every retry
    # refuse with "already exists" and hide the real error above it. Removing
    # only the path we just made keeps that safe: it can never be a subject
    # another task is inspecting.
    rm -rf "$dest"
    exit 1
  fi
  rm -f "$archive_err"

  {
    printf 'head\t%s\n' "$resolved"
    printf 'tree\t%s\n' "$tree"
  } > "$dest/MANIFEST" || die "cannot write $dest/MANIFEST"

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    path_is_recordable "$rel" \
      || die "sealed path contains a tab, newline, or carriage return and cannot be recorded: $rel"
    abs="$dest/subject/$rel"
    digest=$(digest_file "$abs") || die "cannot digest sealed file: $rel"
    printf 'file\t%s\t%s\n' "$rel" "$digest" >> "$dest/MANIFEST" \
      || die "cannot append to $dest/MANIFEST"
  done <<EOF
$(list_subject_files "$dest/subject")
EOF

  # PREVENTION, applied last so the manifest is written while the tree is still
  # writable. Directories lose write permission too: without that a file could
  # be unlinked or a new one created beside it, which is precisely the "added or
  # removed file" case detection has to catch afterwards.
  chmod -R a-w "$dest/subject" 2>/dev/null \
    || echo "warning: could not remove write permission from $dest/subject; the seal is detectable but not prevented" >&2

  printf 'sealed head=%s tree=%s subject=%s\n' "$resolved" "$tree" "$dest/subject"
}

cmd_verify() {
  local dest='' want='' line kind rel recorded current
  local manifest expected_tmp actual_tmp changed=0 missing=0 added=0 rc=0
  while [ "$#" -gt 0 ]; do
    if [ -n "$want" ]; then
      case "$1" in --*) die "--$want requires a value" ;; esac
      dest=$1; want=; shift; continue
    fi
    case "$1" in
      --dest) want=dest ;;
      --dest=*) dest=${1#--dest=} ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  [ -z "$want" ] || die "--dest requires a value"
  [ -n "$dest" ] || die "verify requires --dest"

  manifest="$dest/MANIFEST"
  # Everything below this point that cannot be READ is exit 3, never exit 0.
  if [ ! -f "$manifest" ] || [ ! -r "$manifest" ]; then
    echo "COULD-NOT-OBSERVE: no readable manifest at $manifest" >&2
    return 3
  fi
  if [ ! -d "$dest/subject" ]; then
    echo "COULD-NOT-OBSERVE: no sealed subject directory at $dest/subject" >&2
    return 3
  fi

  # One scratch directory, removed on every exit path including a signal, so a
  # verify that fails or is interrupted does not leave working files behind.
  local scratch
  scratch=$(mktemp -d) || { echo "COULD-NOT-OBSERVE: cannot create a scratch directory" >&2; return 3; }
  trap 'rm -rf "$scratch"' RETURN
  expected_tmp="$scratch/expected"
  actual_tmp="$scratch/actual"
  : > "$expected_tmp" || { echo "COULD-NOT-OBSERVE: cannot write scratch" >&2; return 3; }

  while IFS= read -r line; do
    kind=${line%%	*}
    [ "$kind" = file ] || continue
    rel=${line#*	}
    recorded=${rel#*	}
    rel=${rel%%	*}
    printf '%s\t%s\n' "$rel" "$recorded" >> "$expected_tmp"
  done < "$manifest"

  if ! list_subject_files "$dest/subject" > "$actual_tmp"; then
    echo "COULD-NOT-OBSERVE: cannot enumerate $dest/subject" >&2
    return 3
  fi

  # Changed or unreadable bytes, and files the manifest recorded that are gone.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rel=${line%%	*}
    recorded=${line#*	}
    if [ ! -f "$dest/subject/$rel" ]; then
      echo "REMOVED: $rel"
      missing=$((missing + 1))
      continue
    fi
    if ! current=$(digest_file "$dest/subject/$rel"); then
      echo "COULD-NOT-OBSERVE: cannot digest $rel" >&2
      rc=3
      continue
    fi
    if [ "$current" != "$recorded" ]; then
      echo "CHANGED: $rel"
      changed=$((changed + 1))
    fi
  done < "$expected_tmp"

  # Files that appeared under the seal after it was taken.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if ! grep -qF "$(printf '%s\t' "$rel")" "$expected_tmp"; then
      echo "ADDED: $rel"
      added=$((added + 1))
    fi
  done < "$actual_tmp"

  [ "$rc" -ne 3 ] || { echo "verify: could not observe the whole subject" >&2; return 3; }
  if [ "$changed" -gt 0 ] || [ "$missing" -gt 0 ] || [ "$added" -gt 0 ]; then
    printf 'verify FAILED: changed=%s removed=%s added=%s\n' "$changed" "$missing" "$added" >&2
    return 2
  fi
  # A positive count, never "no differences found": an empty manifest would
  # otherwise report exactly like an intact one.
  printf 'verify OK: %s files match the sealed manifest\n' "$(grep -c '^file	' "$manifest" 2>/dev/null || echo 0)"
}

cmd_head() {
  local dest='' want=''
  while [ "$#" -gt 0 ]; do
    if [ -n "$want" ]; then dest=$1; want=; shift; continue; fi
    case "$1" in
      --dest) want=dest ;;
      --dest=*) dest=${1#--dest=} ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  [ -n "$dest" ] || die "head requires --dest"
  [ -f "$dest/MANIFEST" ] || { echo "COULD-NOT-OBSERVE: no manifest at $dest/MANIFEST" >&2; return 3; }
  sed -n 's/^head\t//p' "$dest/MANIFEST" | head -1
}

[ "$#" -gt 0 ] || { usage >&2; exit 1; }
SUB=$1
shift
case "$SUB" in
  seal) cmd_seal "$@" ;;
  verify) cmd_verify "$@" ;;
  head) cmd_head "$@" ;;
  -h|--help) usage ;;
  *) die "unknown subcommand: $SUB" ;;
esac
