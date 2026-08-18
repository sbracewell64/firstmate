#!/usr/bin/env bash
# fm-outbound-artifact.sh - the OUTBOUND transport invariant: deterministic
# ownership of whether the artifact an item is waiting on actually exists.
#
# bin/fm-outbound-artifact-lib.sh is the single owner of the invariant statement,
# the gate vocabulary, the identity rule, the two-tier recognizer, and the record
# shape. Read its header first; this file owns only what that one deliberately
# excludes: observation, transport, cadence, retry, checkpointing, and verdicts.
#
# WHAT THIS COMMAND IS FOR
#
# Firstmate had an INBOUND detector - it woke when Browser Sol replied to a
# control issue that already existed - and nothing at all on the way out. Seven
# items were found sitting in a waiting state with no artifact ever created: four
# SSSF pull requests never submitted for review, and three finished branches with
# no pull request opened anywhere. This command makes that condition a verdict
# instead of a silence.
#
# Usage:
#   fm-outbound-artifact.sh check [--json]
#       THE INVARIANT. Every item whose durable state implies an outstanding
#       outbound artifact, joined against whether an applicable one exists.
#   fm-outbound-artifact.sh status [--json]
#       The same sweep, rendered in full including satisfied items.
#   fm-outbound-artifact.sh defects
#       One line per defect, for a relay such as bin/fm-bootstrap.sh. Silent when
#       the invariant holds, and never silent when it could not be checked.
#   fm-outbound-artifact.sh reconcile
#       Emit every complete sol-control request found missing by one sweep.
#       Pull-request rows remain detect-only.
#   fm-outbound-artifact.sh emit <item-id> [--rationale-file <path>] [--dry-run]
#       Create or adopt the durable artifact for one item, on an emit-capable
#       channel. Idempotent on the request identity.
#   fm-outbound-artifact.sh ruling --request <id> --comment <n> [--issue <n>]
#       Join an inbound ruling to the request that asked for it.
#   fm-outbound-artifact.sh poll
#       Poll the configured control issue and join every attributable ruling.
#   fm-outbound-artifact.sh resume --request <id>
#       Record that the waiting item resumed on that ruling.
#   fm-outbound-artifact.sh close --request <id> --disposition <text>
#       Complete the correlation with the outcome.
#   fm-outbound-artifact.sh show <request-id>
#   fm-outbound-artifact.sh --help
#
# Exit status is the verdict, so a caller that ignores stdout still stops safely:
#   0  the invariant holds, or the command succeeded
#   2  usage error
#   3  CONTROL-TRANSPORT DEFECT - an item is waiting and no applicable artifact
#      exists, or a refusal that must not be worked around
#   4  unevaluable - the sweep could not observe what it needed, so the invariant
#      may not be asserted either way
#
# 3 AND 4 ARE NOT INTERCHANGEABLE. 3 says the fleet is provably wrong. 4 says the
# question was not answered. Reporting 4 as 0 is the exact conversion that hid
# the original defect, so an unreadable backlog, an unreachable forge, an
# unconfigured venue, and an unobservable head all reach 4 and never 0.
#
# WHAT THIS COMMAND WILL NOT DO
#
# It does not open pull requests. The pull-request channel is detect-only: the
# library's header owns that boundary and why it exists. It does not merge, does
# not push, does not write to any project, and does not decide whether waiting is
# justified - only whether the artifact that waiting depends on is there.
#
# Environment:
#   FM_HOME                     operational home (default: repo root)
#   FM_OUTBOUND_SNAPSHOT        read this fm-fleet-snapshot.v1 file instead of
#                               running bin/fm-fleet-snapshot.sh
#   FM_OUTBOUND_DIR             correlation record directory
#                               (default: $FM_HOME/data/outbound-artifacts)
#   FM_OUTBOUND_ATTEMPTS        transport attempts per emit (default 3)
#   FM_OUTBOUND_BACKOFF_BASE    seconds for the first backoff, doubling
#                               (default 1; 0 disables sleeping)
#   FM_OUTBOUND_MAX_PROBES      cap on forge probes per sweep (default 40).
#                               Reaching it is REPORTED, never silently applied.
#   FM_OUTBOUND_TIMEOUT         seconds per forge or git observation (default 15)
# fail-closed-predicates: enforced
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
RECORD_DIR="${FM_OUTBOUND_DIR:-$DATA/outbound-artifacts}"
ATTEMPTS="${FM_OUTBOUND_ATTEMPTS:-3}"
BACKOFF_BASE="${FM_OUTBOUND_BACKOFF_BASE:-1}"
MAX_PROBES="${FM_OUTBOUND_MAX_PROBES:-40}"
PROBE_TIMEOUT="${FM_OUTBOUND_TIMEOUT:-15}"

# shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-outbound-artifact-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-landed-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-landed-lib.sh"

die() { printf 'fm-outbound-artifact: %s\n' "$1" >&2; exit "${2:-2}"; }

command -v jq >/dev/null 2>&1 || die "jq is required" 4

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Every observation is bounded. An unbounded forge read inside a session-start
# sweep is how a detector becomes the thing that wedges the session it protects.
obs() { timeout "$PROBE_TIMEOUT" "$@" 2>/dev/null; }

# --- probe budget ------------------------------------------------------------
#
# The counter lives in a FILE, not a variable, because every probe in this script
# is called from a command substitution and a variable incremented in a subshell
# dies with it. A budget that silently never decrements is a cap that reads as
# enforced while enforcing nothing - the same defect class this command exists
# for, one level down.

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-outbound.XXXXXX") || die "cannot create a work directory" 4
PROBE_COUNT="$SCRATCH/probes"
PROBE_CAPPED="$SCRATCH/capped"
EMIT_LOCK=
cleanup() {
  [ -z "$EMIT_LOCK" ] || fm_lock_release "$EMIT_LOCK"
  rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT
printf '0' > "$PROBE_COUNT"

probe_budget() {
  local used
  used=$(cat "$PROBE_COUNT" 2>/dev/null || printf '0')
  case $used in ''|*[!0-9]*) used=0 ;; esac
  if [ "$used" -ge "$MAX_PROBES" ]; then
    printf 'capped' > "$PROBE_CAPPED"
    return 1
  fi
  printf '%s' "$((used + 1))" > "$PROBE_COUNT"
  return 0
}

probes_capped() { [ -s "$PROBE_CAPPED" ]; }

# --- durable records ---------------------------------------------------------

record_path() { printf '%s/%s.json\n' "$RECORD_DIR" "$1"; }

# Atomic by rename, so a reader never sees a half-written record and a crash
# mid-write leaves the previous record intact rather than a truncated one.
record_write() {  # <request-id> <json>
  local path tmp
  path=$(record_path "$1")
  mkdir -p "$RECORD_DIR" || return 1
  tmp="$path.tmp.$$"
  printf '%s\n' "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

record_identity_cno() { printf '%s\n' "$FM_OUTBOUND_IDENTITY_CNO"; }

# Three-valued on purpose: absent and unreadable are different answers, and only
# the caller knows which of them is safe in its context.
# Prints one of the three identity verdicts. It recomputes the identity from the
# record's own fields rather than merely comparing the stored string, so a record
# whose id was rewritten to match its filename is still caught by its content.
#
# The verdict is PRINTED rather than returned as an exit status because the two
# refusals must stay distinguishable: a status can carry "not valid", but the
# caller then cannot tell a foreign record from an unreadable one, and those need
# different repairs.
record_identity_verdict() {  # <record-json> <expected-id>
  local raw=$1 expected=$2 state stored gate project repo item pr head head_source computed
  printf '%s' "$raw" | jq -e --arg s "$FM_OUTBOUND_RECORD_SCHEMA" \
    '.schema == $s' >/dev/null 2>&1 || { record_identity_cno; return 0; }
  state=$(printf '%s' "$raw" | jq -er '.state // empty') || { record_identity_cno; return 0; }
  fm_outbound_record_state_valid "$state" || { record_identity_cno; return 0; }
  stored=$(printf '%s' "$raw" | jq -er '.request_id // empty') || { record_identity_cno; return 0; }
  gate=$(printf '%s' "$raw" | jq -er '.identity.gate // empty') || { record_identity_cno; return 0; }
  project=$(printf '%s' "$raw" | jq -er '.identity.project // empty') || { record_identity_cno; return 0; }
  repo=$(printf '%s' "$raw" | jq -er '.identity.repo // empty') || { record_identity_cno; return 0; }
  item=$(printf '%s' "$raw" | jq -er '.identity.item // empty') || { record_identity_cno; return 0; }
  pr=$(printf '%s' "$raw" | jq -r '.identity.pr // "-"') || { record_identity_cno; return 0; }
  head=$(printf '%s' "$raw" | jq -er '.identity.head // empty') || { record_identity_cno; return 0; }
  head_source=$(printf '%s' "$raw" | jq -r '.identity.head_source // ""') \
    || { record_identity_cno; return 0; }
  case $head_source in ""|declared|forge|local) ;; *) record_identity_cno; return 0 ;; esac
  # An identity that cannot be bound cannot be compared: that is an absent
  # identity, not one naming something else.
  fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" "$PROJECTS/$project" "$head_source" \
    >/dev/null 2>&1 || { record_identity_cno; return 0; }
  computed=$(fm_outbound_request_id "$gate" "$project" "$repo" "$item" "$pr" "$head") \
    || { record_identity_cno; return 0; }
  if [ "$stored" = "$expected" ] && [ "$computed" = "$expected" ]; then
    printf '%s\n' "$FM_OUTBOUND_IDENTITY_VALID"
  else
    printf '%s\n' "$FM_OUTBOUND_IDENTITY_MISMATCH"
  fi
}

record_valid_for_id() {  # <record-json> <expected-id> - kept for callers wanting a boolean
  [ "$(record_identity_verdict "$1" "$2")" = "$FM_OUTBOUND_IDENTITY_VALID" ]
}

record_read() {  # <request-id> -> json on stdout
  # 0 valid · 1 absent · 2 could-not-observe · 5 identity mismatch
  local path raw
  path=$(record_path "$1")
  [ -f "$path" ] || return 1
  raw=$(cat "$path" 2>/dev/null) || return 2
  case "$(record_identity_verdict "$raw" "$1")" in
    "$FM_OUTBOUND_IDENTITY_VALID") printf '%s\n' "$raw"; return 0 ;;
    "$FM_OUTBOUND_IDENTITY_MISMATCH") return 5 ;;
    *) return 2 ;;
  esac
}

# Every record as one JSON array. An unreadable record is carried as an explicit
# marker rather than dropped - a record this cannot parse is a correlation that
# cannot be checked, which is a finding rather than an absence.
records_all() {
  local f raw rid
  if [ ! -d "$RECORD_DIR" ]; then printf '[]\n'; return 0; fi
  {
    for f in "$RECORD_DIR"/*.json; do
      [ -f "$f" ] || continue
      raw=$(cat "$f" 2>/dev/null) || raw=
      rid=${f##*/}
      rid=${rid%.json}
      if record_valid_for_id "$raw" "$rid"; then
        printf '%s\n' "$raw"
      else
        jq -n --arg p "$f" '{schema:"unreadable",path:$p}'
      fi
    done
  } | jq -s '.'
}

# --- configuration -----------------------------------------------------------
#
# The sol-control channel needs a venue: which repository and issue a request is
# posted to. Absent configuration does NOT make a waiting item clear - it makes
# emission impossible while the item stays surfaced, which is the whole point of
# separating "is the artifact there" from "can I create it".

SOL_REPO=
SOL_ISSUE=
read_sol_config() {
  local file raw
  file="$CONFIG/sol-control.json"
  [ -f "$file" ] || return 1
  raw=$(cat "$file" 2>/dev/null) || return 1
  SOL_REPO=$(printf '%s' "$raw" | jq -r '.repo // ""' 2>/dev/null) || return 1
  SOL_ISSUE=$(printf '%s' "$raw" | jq -r 'if .issue == null then "" else (.issue|tostring) end' 2>/dev/null) || return 1
  [ -n "$SOL_REPO" ] && [ -n "$SOL_ISSUE" ]
}

# --- the fleet's durable rows ------------------------------------------------

SNAPSHOT=
SNAPSHOT_OK=0
read_snapshot() {
  [ "$SNAPSHOT_OK" -eq 0 ] || return 0
  local raw
  if [ -n "${FM_OUTBOUND_SNAPSHOT:-}" ]; then
    [ -r "$FM_OUTBOUND_SNAPSHOT" ] || return 1
    raw=$(cat "$FM_OUTBOUND_SNAPSHOT") || return 1
  else
    raw=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || return 1
  fi
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e 'has("backlog")' >/dev/null 2>&1 || return 1
  SNAPSHOT=$raw
  SNAPSHOT_OK=1
}

# --- head observation --------------------------------------------------------
#
# The cascade is stated in one place and in one order, so two readers cannot
# disagree about what "the exact head" of an item means:
#   1. a typed gate declaration's own head, when the item declares one;
#   2. the pull request's current head, when the row names a pull request;
#   3. the fm/<item> branch head in the project clone;
#   4. otherwise unobservable - a real answer, and never a pass.

gate_file() { printf '%s/%s/outbound-gate.json\n' "$DATA" "$1"; }

declared_field() {  # <item> <field> -> value or empty
  local f
  f=$(gate_file "$1")
  [ -f "$f" ] || return 0
  jq -r --arg k "$2" '.[$k] // ""' "$f" 2>/dev/null || true
}

classify_record() {  # <record-json>
  local rec=$1 item declared_gate
  item=$(printf '%s' "$rec" | jq -r '.id // ""' 2>/dev/null || true)
  declared_gate=$(declared_field "$item" gate)
  fm_outbound_classify_record "$rec" "$declared_gate"
}

pr_head() {  # <pr-url> -> sha or empty
  local url=$1 slug num
  case $url in *://*/*/*/pull/*) ;; *) return 0 ;; esac
  slug=$(printf '%s' "$url" | sed -n 's#.*://[^/]*/\([^/]*/[^/]*\)/pull/[0-9]*.*#\1#p')
  num=$(printf '%s' "$url" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p')
  [ -n "$slug" ] && [ -n "$num" ] || return 0
  probe_budget || return 0
  # fm-retrieval-audit: not-a-collection - this reads one pull request named by repository and number.
  obs gh api "repos/$slug/pulls/$num" --jq '.head.sha' || true
}

branch_head() {  # <clone-dir> <item> -> sha or empty
  local dir=$1 item=$2 ref sha
  for ref in "refs/remotes/origin/fm/$item" "refs/remotes/fork/fm/$item" "refs/heads/fm/$item"; do
    sha=$(obs git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$ref") || sha=
    if [ -n "$sha" ]; then printf '%s\n' "$sha"; return 0; fi
  done
  return 0
}

# Each step yields only something that IS an exact head. A step that produced
# anything else - a forge error body, an abbreviated ref, a stray line - falls
# through to the next step and finally to unobservable, rather than handing a
# non-identity to the binding check and letting it surface as evidence.
observe_head() {  # <item> <pr-url> <project> -> sha<TAB>source or empty
  local item=$1 pr_url=$2 project=$3 head width dir=
  [ -z "$project" ] || dir="$PROJECTS/$project"
  # The width comes from the target repository, so it is resolved ONCE here and
  # every step of the cascade is judged against it. With no readable repository
  # the width is undeterminable, and an undeterminable width refuses every
  # candidate rather than falling back to a guessed default.
  width=$(fm_outbound_object_width "$dir")
  head=$(declared_field "$item" head)
  fm_outbound_is_sha "$head" "$width" && { printf '%s\tdeclared\n' "$head"; return 0; }
  if [ -n "$pr_url" ]; then
    head=$(pr_head "$pr_url")
    fm_outbound_is_sha "$head" "$width" && { printf '%s\tforge\n' "$head"; return 0; }
  fi
  if [ -n "$dir" ] && [ -d "$dir/.git" ]; then
    head=$(branch_head "$dir" "$item")
    fm_outbound_is_sha "$head" "$width" && { printf '%s\tlocal\n' "$head"; return 0; }
  fi
  printf ''
}

# --- artifact existence, observed on the forge -------------------------------
#
# The forge is the authority for whether an artifact exists; the local record is
# correlation and crash-safe checkpoint, never proof. A record claiming `emitted`
# while nothing was posted is the precise shape of a control plane that reads as
# working, so existence is never taken from it.
#
# Return 0 found (prints the forge identity), 1 provably absent, 2 could not
# observe, 3 the channel's venue is not configured at all.

artifact_body_matches_identity() {  # <body> <record-json> <marker>
  local body=$1 rec=$2 marker=$3
  printf '%s\n' "$body" | grep -Fqx "$marker $(printf '%s' "$rec" | jq -r '.request_id')" \
    && printf '%s\n' "$body" | grep -Fqx "gate: $(printf '%s' "$rec" | jq -r '.identity.gate')" \
    && printf '%s\n' "$body" | grep -Fqx "project: $(printf '%s' "$rec" | jq -r '.identity.project')" \
    && printf '%s\n' "$body" | grep -Fqx "repo: $(printf '%s' "$rec" | jq -r '.identity.repo')" \
    && printf '%s\n' "$body" | grep -Fqx "item: $(printf '%s' "$rec" | jq -r '.identity.item')" \
    && printf '%s\n' "$body" | grep -Fqx "pull-request: $(printf '%s' "$rec" | jq -r '.identity.pr // "-"')" \
    && printf '%s\n' "$body" | grep -Fqx "exact-head: $(printf '%s' "$rec" | jq -r '.identity.head')"
}

sol_artifact_present() {  # <request-id> <record-json> -> comment id
  local rid=$1 rec=$2 comments row id body
  read_sol_config || return 3
  probe_budget || return 2
  # fm-retrieval-audit: complete-source - --paginate traverses every issue-comment page before absence is concluded.
  comments=$(obs gh api "repos/$SOL_REPO/issues/$SOL_ISSUE/comments" \
    --paginate --jq '.[] | [.id, .body] | @base64') || return 2
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[0] | tostring') || return 2
    body=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[1]') || return 2
    printf '%s\n' "$body" | grep -Fqx "$FM_OUTBOUND_BODY_MARKER $rid" || continue
    artifact_body_matches_identity "$body" "$rec" "$FM_OUTBOUND_BODY_MARKER" || continue
    printf '%s\n' "$id"
    return 0
  done <<< "$comments"
  return 1
}

pr_artifact_present() {  # <venue-slug> <head-sha> -> pull request number
  local venue=$1 sha=$2 out count
  [ -n "$venue" ] || return 3
  [ -n "$sha" ] || return 2
  probe_budget || return 2
  # fm-retrieval-audit: complete-source - --paginate traverses every commit-pull page before exact-head absence is concluded.
  out=$(obs gh api "repos/$venue/commits/$sha/pulls" \
    --paginate \
    --jq ".[] | select(.state == \"open\" and .head.sha == \"$sha\") | .number") || return 2
  [ -n "$out" ] || return 1
  count=$(printf '%s\n' "$out" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    printf 'exact head %s has %s open pull requests in %s\n' "$sha" "$count" "$venue" >&2
    return 2
  fi
  printf '%s\n' "$out"
  return 0
}

# The venue a project's contributions are offered to. Read from the clone's own
# remotes rather than guessed from a name, because this fleet's projects
# routinely fetch from upstream and push to a fork.
project_venue() {  # <project> [<declared-venue>] -> owner/name or empty
  local dir=$PROJECTS/$1 declared=${2:-} url
  if [ -n "$declared" ]; then printf '%s\n' "$declared"; return 0; fi
  [ -d "$dir/.git" ] || return 0
  url=$(obs git --no-optional-locks -C "$dir" remote get-url upstream) || url=
  [ -n "$url" ] || url=$(obs git --no-optional-locks -C "$dir" remote get-url origin) || url=
  [ -n "$url" ] || return 0
  printf '%s' "$url" | sed -e 's#\.git$##' -e 's#^git@[^:]*:##' -e 's#^[a-z+]*://[^/]*/##'
}

# --- the sweep ---------------------------------------------------------------
#
# One row per item whose durable state implies an outstanding artifact, each
# carrying its identity, what was observed, and the verdict. Nothing here decides
# policy and nothing here mutates: `check` reads these rows and turns them into
# an exit status.

# --- branch inventory -------------------------------------------------------
#
# WHY THIS EXISTS, and why the backlog sweep alone is not the invariant.
#
# The backlog sweep can only report what a durable row already SAYS. For the
# sol-control channel that is enough, because an item waiting on a review is
# recorded as waiting. For the pull-request channel it is not: a finished branch
# nobody ever submitted produces no annotation at all, so the sweep sees nothing
# and reports nothing. The three never-submitted items this invariant was
# commissioned from were found in a live run ONLY because a person had already
# found them and written it into the hold text - strip that sentence and the
# mechanism goes silent on exactly the population it exists for.
#
# Under the completeness law that claim is not even assertable: with no
# enumeration the sweep can say "nothing is ANNOTATED as unsubmitted", which is a
# statement about the backlog rather than about the fleet. This pass enumerates
# the candidate universe so the negative claim has something to be true of.
#
# BOUNDED DELIBERATELY. Strictly read-only - it writes to no clone and mutates no
# ref. It enumerates only the fm/<item> pattern, only in registered projects
# whose posture is not local-only, and it reuses the exact-head existence check
# the rest of this command already uses rather than adding a second one. A clone
# it cannot read, or a venue it cannot reach, is COULD_NOT_OBSERVE for that item
# BY NAME - never folded into a no-unsubmitted-work conclusion, which would be
# the completeness defect this pass exists to remove.
registered_pr_projects() {
  local reg="$DATA/projects.md"
  [ -r "$reg" ] || return 1
  sed -n 's/^- \([A-Za-z0-9_.-]*\).*/\1/p' "$reg"
}

# Is this head already contained in what the project lands onto? Landed work is
# not unsubmitted work, so it is excluded before anything is reported.
head_already_landed() {  # <clone-dir> <sha>
  local dir=$1 sha=$2 name refs ref ref_tree merged rc uncertain=0
  name=$(fm_landed_default_branch_name "$dir" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$name" ] || return 2
  refs=$(fm_landed_candidate_refs "$dir" "$name" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$refs" ] || return 2
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    ref_tree=$(git --no-optional-locks -C "$dir" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || {
      uncertain=1
      continue
    }
    merged=$(git --no-optional-locks -C "$dir" merge-tree --write-tree "$ref" "$sha" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$merged" ]; then
      uncertain=1
      continue
    fi
    # NOT a choice among candidates, which is why first-match is safe here and
    # is written down rather than left to be re-derived. `merge-tree --write-tree`
    # prints the resulting tree OID on its FIRST line by definition, and any
    # conflict detail follows it; taking line one is reading a fixed field, not
    # picking one of several answers. Every other single-value selection on this
    # surface refuses and names its count instead.
    merged=$(printf '%s\n' "$merged" | head -1)
    [ "$merged" = "$ref_tree" ] && return 0
  done <<< "$refs"
  [ "$uncertain" -eq 0 ] || return 2
  return 1
}

# Does a durable record say this branch is FINISHED SHIP WORK?
#
#   exit 0 - yes: a record names this work and its deliverable is a ship.
#   exit 1 - no:  a record names it and its deliverable is NOT a ship, so the
#                 absence of a pull request is correct rather than a defect.
#                 An investigation produces a report; it never has one.
#   exit 2 - COULD NOT OBSERVE: no record names this work, the record names no
#                 deliverable, records disagree, or a source could not be read.
#
# WHY THIS IS THE PRIMARY SIGNAL AND NOT A FOOTNOTE, for this control above all
# others. This pass exists because three items sat with finished work and no
# pull request anywhere. Those three were RELEASED tasks: the live records had
# already been cleaned up when the defect was found. So the population this
# control was commissioned for is exactly the population most likely to land in
# could-not-observe - and if could-not-observe is rendered as a footnote, folded
# into a clean result, or dropped, this control goes quiet about precisely the
# case it was built for. That is why the caller gives it its own count and its
# own section, and why a sweep carrying any of it cannot exit clean.
#
# WHAT BOUNDS IT, established by measurement rather than assumed:
#   - Retention does NOT bound it. The backlog keeps a fixed number of completed
#     entries and rotates the rest into the archive, which is append-only and
#     unpruned, so this evidence survives release indefinitely.
#   - RECORD COMPLETENESS bounds it. Entries that name no deliverable cannot
#     answer the question and are could-not-observe by construction.
#   - HOME LOCALITY bounds it, and this is the larger one. Records are per-home,
#     so a branch produced by a secondmate has its record in THAT home and is
#     invisible here. Measured live: one project matched none of its branches
#     for exactly this reason. Those are could-not-observe, never clean.
#
# Both durable sources are read as TEXT rather than through the structured fleet
# reader, on purpose: the archive holds the large majority of the evidence and
# has no structured reader at all, and the two files carry the same row format
# because the archive IS the backlog's rotated rows. One parser over both beats
# two parsers that can drift apart on the same line.
finished_work_evidence() {  # <project> <item>
  local project=$1 item=$2 backlog archive lines kinds count
  backlog="${FM_OUTBOUND_BACKLOG_FILE:-$DATA/backlog.md}"
  archive="${FM_OUTBOUND_DONE_ARCHIVE:-$DATA/done-archive.md}"
  [ -n "$project" ] && [ -n "$item" ] || return 2
  [ -r "$backlog" ] || return 2
  # An archive that EXISTS but cannot be read compromises the candidate set, so
  # it is could-not-observe even when the backlog alone would have answered. An
  # archive that does not exist yet is simply a smaller corpus, not a failure.
  if [ -e "$archive" ] && [ ! -r "$archive" ]; then
    return 2
  fi
  lines=$(cat "$backlog" "$archive" 2>/dev/null \
    | grep -F -- "- [x] $item " ; true)
  [ -n "$lines" ] || return 2
  # Identity is (project, work item), never the item name alone - the same
  # collapse the sweep dedupe was fixed for. Project names are compared
  # case-insensitively because the records carry both cases for one project.
  lines=$(printf '%s\n' "$lines" \
    | grep -iF -- "(repo: $project)" ; true)
  [ -n "$lines" ] || return 2
  kinds=$(printf '%s\n' "$lines" | grep -o '(kind: [^)]*)' | sort -u)
  [ -n "$kinds" ] || return 2
  count=$(printf '%s\n' "$kinds" | grep -c . || true)
  case $count in ''|*[!0-9]*) count=0 ;; esac
  # Disagreeing records are ambiguous identity, not a menu to choose from.
  [ "$count" -eq 1 ] || return 2
  [ "$kinds" = "(kind: ship)" ] || return 1
  return 0
}

branch_inventory_rows() {  # appends row_json lines to $1
  local out=$1 project dir venue ref sha item present rc projects mode refs width identity
  local seen="$SCRATCH/inventory-identities"
  local project_mode_command=${FM_OUTBOUND_PROJECT_MODE_COMMAND:-$SCRIPT_DIR/fm-project-mode.sh}
  : > "$seen"
  projects=$(registered_pr_projects); rc=$?
  if [ "$rc" -ne 0 ]; then
    row_json project-registry "" inventory pull-request "" "" "" "" \
      unevaluable "$FM_OUTBOUND_TOKEN_REGISTRY_UNREADABLE" "" "" 0 >> "$out"
    return
  fi
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    mode=$("$project_mode_command" "$project" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$mode" ]; then
      row_json "$project" "" inventory pull-request "$project" "" "" "" \
        unevaluable "$FM_OUTBOUND_TOKEN_POSTURE_UNOBSERVED" "" "" 0 >> "$out"
      continue
    fi
    mode=${mode%% *}
    [ "$mode" = "local-only" ] && continue
    dir="$PROJECTS/$project"
    if [ ! -d "$dir/.git" ]; then
      row_json "$project" "" inventory pull-request "$project" "" "" "" \
        unevaluable "$FM_OUTBOUND_TOKEN_CLONE_UNREADABLE" "" "" 0 >> "$out"
      continue
    fi
    venue=$(project_venue "$project")
    refs=$(git --no-optional-locks -C "$dir" for-each-ref --format='%(refname)' \
             'refs/remotes/*/fm/*' 'refs/heads/fm/*' 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then
      row_json "$project" "" inventory pull-request "$project" "$venue" "" "" \
        unevaluable "$FM_OUTBOUND_TOKEN_REFS_UNOBSERVED" "" "" 0 >> "$out"
      continue
    fi
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      item=${ref##*/fm/}
      [ -n "$item" ] || continue
      sha=$(obs git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$ref"); rc=$?
      width=$(fm_outbound_object_width "$dir")
      if [ "$rc" -ne 0 ] || [ -z "$sha" ] || [ -z "$width" ] \
        || ! fm_outbound_is_sha "$sha" "$width"; then
        row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" \
          "$venue" "$sha" "" unevaluable "$FM_OUTBOUND_TOKEN_REF_UNOBSERVED" "" "" 0 >> "$out"
        continue
      fi
      identity=$(fm_outbound_identity_canonical CONTRIBUTION_SUBMISSION_REQUIRED \
        "$project" "$venue" "$item" - "$sha" | fm_outbound_digest) || identity=
      if [ -n "$identity" ] && grep -Fqx "$identity" "$seen"; then
        continue
      fi
      [ -z "$identity" ] || printf '%s\n' "$identity" >> "$seen"
      head_already_landed "$dir" "$sha"; rc=$?
      case $rc in
        0) continue ;;
        1) : ;;
        *) row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" \
             "$venue" "$sha" "" unevaluable "$FM_OUTBOUND_TOKEN_LANDING_UNOBSERVED" "" "" 0 >> "$out"
           continue ;;
      esac
      # Is this finished work at all? An unlanded branch with no pull request is
      # only a transport defect if the work was FINISHED and was the kind of work
      # that produces one. Without this, an ordinary in-progress branch is a
      # standing defect at every startup, and a control that cries wolf on every
      # run gets discounted - which is the same silence as reporting nothing,
      # reached more slowly.
      #
      # The three outcomes stay genuinely three. Only recorded ship work can be
      # a defect; recorded non-ship work is skipped because its missing pull
      # request is correct; and work whose state cannot be established is
      # could-not-observe BY NAME. That last one is not the safe default - it is
      # the answer for the population this pass exists to catch, so it is
      # reported, counted and sectioned rather than quietly passed over.
      finished_work_evidence "$project" "$item"; rc=$?
      case $rc in
        0) : ;;
        1) continue ;;
        *) row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" \
             "$venue" "$sha" "" unevaluable "$FM_OUTBOUND_TOKEN_WORK_STATE_UNOBSERVED" "" "" 0 >> "$out"
           continue ;;
      esac
      if [ -z "$venue" ]; then
        row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" "" \
          "$sha" "" unevaluable "$FM_OUTBOUND_TOKEN_VENUE_UNRESOLVED" "" "" 0 >> "$out"
        continue
      fi
      present=$(pr_artifact_present "$venue" "$sha"); rc=$?
      case $rc in
        0) : ;;
        1) row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" \
             "$venue" "$sha" "" defect "$FM_OUTBOUND_TOKEN_NO_ARTIFACT" "" "" 0 >> "$out" ;;
        *) row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" \
             "$venue" "$sha" "" unevaluable "$FM_OUTBOUND_TOKEN_ARTIFACT_UNOBSERVED" "" "" 0 >> "$out" ;;
      esac
    done <<< "$refs"
  done <<< "$projects"
}

SWEEP=
row_json() {  # <item> <gate> <tier> <channel> <project> <repo> <head> <rid> <verdict> <token> <missing> <artifact> <stale>
  local identity
  identity=$(fm_outbound_identity_canonical "$2" "$5" "$6" "$1" "-" "$7")
  jq -n --arg item "$1" --arg gate "$2" --arg tier "$3" --arg channel "$4" \
    --arg project "$5" --arg repo "$6" --arg head "$7" --arg rid "$8" \
    --arg verdict "$9" --arg token "${10}" --arg missing "${11}" \
    --arg artifact "${12}" --argjson stale "${13:-0}" --arg identity "$identity" \
    '{item:$item,
      gate:(if $gate == "" then null else $gate end),
      tier:$tier,
      channel:(if $channel == "" then null else $channel end),
      project:$project,
      repo:$repo,
      head:(if $head == "" then null else $head end),
      request_id:(if $rid == "" then null else $rid end),
      verdict:$verdict,
      token:$token,
      missing:(if $missing == "" then null else $missing end),
      artifact:(if $artifact == "" then null else $artifact end),
      superseded_records:$stale,
      _identity:$identity}'
}

sweep() {
  local rows count i rec verdict gate tier item project pr_url pr_ref head_observation head head_source
  local channel venue repo rid missing stale present rc row token capped cls
  local existing record_state applicability record_rc

  if ! read_snapshot; then
    SWEEP=$(jq -n '{schema:"fm-outbound-sweep.v1",readable:false,capped:false,
                    rows:[],reason:"fleet backlog could not be read"}')
    return 1
  fi

  rows=$(mktemp "$SCRATCH/rows.XXXXXX")
  count=$(printf '%s' "$SNAPSHOT" | jq '.backlog.records | length')
  i=0
  while [ "$i" -lt "$count" ]; do
    rec=$(printf '%s' "$SNAPSHOT" | jq -c ".backlog.records[$i]")
    i=$((i + 1))
    # cut, not `IFS=$'\t' read`. Tab is an IFS WHITESPACE character, so read
    # collapses a run of tabs into one delimiter and an untyped gate - the empty
    # middle field, which is precisely the case that must be reported - silently
    # shifts the tier into it. Observed against the live backlog as "gate: prose".
    cls=$(classify_record "$rec")
    verdict=$(printf '%s' "$cls" | cut -f1)
    gate=$(printf '%s' "$cls" | cut -f2)
    tier=$(printf '%s' "$cls" | cut -f3)
    if [ "$verdict" = "unreadable" ]; then
      item=$(printf '%s' "$rec" | jq -r \
        'if type == "object" then (.id // empty) else empty end')
      [ -n "$item" ] || item="backlog-row-$i"
      row_json "$item" "" unreadable "" "" "" "" "" \
        unevaluable "$FM_OUTBOUND_TOKEN_BACKLOG_UNREADABLE" "" "" 0 >> "$rows"
      continue
    fi
    [ "$verdict" = "waiting" ] || continue

    item=$(printf '%s' "$rec" | jq -r '.id // ""')
    project=$(printf '%s' "$rec" | jq -r '.repo // ""')
    pr_url=$(printf '%s' "$rec" | jq -r '.pr_url // ""')
    pr_ref=$(printf '%s' "$rec" | jq -r '.pr_url // "-"')
    channel=$(fm_outbound_gate_channel "$gate")
    head_observation=$(observe_head "$item" "$pr_url" "$project")
    head=$(printf '%s' "$head_observation" | cut -f1)
    head_source=$(printf '%s' "$head_observation" | cut -f2)

    if [ "$channel" = "pull-request" ]; then
      venue=$(project_venue "$project" "$(printf '%s' "$rec" | jq -r '.contribution_venue // ""')")
    else
      venue=
      read_sol_config && venue=$SOL_REPO
    fi
    repo=${venue:-$project}

    # Fail closed on an incomplete binding BEFORE anything else. An item whose
    # binding cannot be constructed cannot have an exact-head-bound artifact, so
    # it is a defect regardless of what happens to be on the forge.
    missing=$(fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" "$PROJECTS/$project" "$head_source" || true)
    if [ -n "$missing" ]; then
      if [ -z "$head" ]; then token=$FM_OUTBOUND_TOKEN_HEAD_UNOBSERVED
      else token=$FM_OUTBOUND_TOKEN_INCOMPLETE; fi
      row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "" \
        defect "$token" "$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')" "" 0 >> "$rows"
      continue
    fi

    rid=$(fm_outbound_request_id "$gate" "$project" "$repo" "$item" "$pr_ref" "$head") || rid=

    if [ "$channel" = "pull-request" ]; then
      present=$(pr_artifact_present "$venue" "$head"); rc=$?
    else
      existing=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$repo" \
        "$item" "$pr_ref" "$head" "$SOL_REPO#$SOL_ISSUE" "$(now_iso)" "$head_source")
      present=$(sol_artifact_present "$rid" "$existing"); rc=$?
      if [ "$rc" -eq 0 ]; then
        if existing=$(record_read "$rid"); then
          record_state=$(printf '%s' "$existing" | jq -r '.state')
          applicability=$(fm_outbound_applicability \
            "$(printf '%s' "$existing" | jq -r '.identity.head // ""')" \
            "$head" "$record_state")
          [ "$applicability" = "applicable" ] || rc=1
        else
          record_rc=$?
          case $record_rc in
            1) rc=4 ;;
            *) rc=5 ;;
          esac
        fi
      fi
    fi

    # A local record is consulted only to EXPLAIN an absence, never to create a
    # presence. A record bound to a different head is exactly the stale-request
    # case, so the operator is told the previous ask went inapplicable rather
    # than merely that none exists.
    stale=$(records_all | jq --arg i "$item" --arg h "$head" \
      '[.[] | select(.identity.item? == $i and .identity.head != $h)] | length')
    case $stale in ''|*[!0-9]*) stale=0 ;; esac

    case $rc in
      0)
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "$rid" \
          satisfied "$FM_OUTBOUND_TOKEN_SATISFIED" "" \
          "$([ "$channel" = pull-request ] && printf 'pull/%s' "$present" || printf 'comment/%s' "$present")" \
          "$stale" >> "$rows"
        ;;
      1)
        if [ "$stale" -gt 0 ]; then token=$FM_OUTBOUND_TOKEN_STALE_HEAD
        else token=$FM_OUTBOUND_TOKEN_NO_ARTIFACT; fi
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "$rid" \
          defect "$token" "" "" "$stale" >> "$rows"
        ;;
      3)
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "$rid" \
          unevaluable "$FM_OUTBOUND_TOKEN_UNCONFIGURED" "" "" "$stale" >> "$rows"
        ;;
      4)
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "$rid" \
          defect "$FM_OUTBOUND_TOKEN_MISSING_CORRELATION" "" "" "$stale" >> "$rows"
        ;;
      5)
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "$rid" \
          unevaluable "$FM_OUTBOUND_TOKEN_UNREADABLE" "" "" "$stale" >> "$rows"
        ;;
      *)
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "$rid" \
          unevaluable "$FM_OUTBOUND_TOKEN_ARTIFACT_UNOBSERVED" "" "" "$stale" >> "$rows"
        ;;
    esac
  done

  # Enumerate branches too, so a negative claim has a candidate universe rather
  # than only the rows somebody already annotated. A backlog row wins on a
  # collision: it carries gate and correlation context the ref alone does not.
  branch_inventory_rows "$rows"
  row=$(jq -s 'reduce .[] as $r ([];
                 if $r.tier == "inventory" and $r.verdict != "unevaluable"
                    and any(.[]; ._identity == $r._identity and .tier != "inventory")
                 then . else . + [$r] end) | map(del(._identity))' < "$rows")
  if probes_capped; then capped=true; else capped=false; fi
  SWEEP=$(jq -n --argjson rows "$row" --argjson capped "$capped" \
    '{schema:"fm-outbound-sweep.v1",readable:true,capped:$capped,rows:$rows,reason:null}')
}

# --- rendering and verdict ---------------------------------------------------

# One verdict's rows under one heading, or a heading that says plainly that this
# section is empty. Printing the heading either way is deliberate: a section that
# vanishes when empty cannot be distinguished from a section nobody rendered.
render_section() {  # <verdict> <heading>
  local verdict=$1 heading=$2 n
  n=$(printf '%s' "$SWEEP" | jq --arg v "$verdict" '[.rows[] | select(.verdict==$v)] | length')
  printf '\n%s (%s)\n' "$heading" "$n"
  if [ "$n" -eq 0 ]; then
    printf '  none\n'
    return
  fi
  printf '%s' "$SWEEP" | jq -r --arg v "$verdict" '.rows[] | select(.verdict==$v) |
    "  \(.item)",
    "         gate: \(.gate // "UNTYPED") · channel: \(.channel // "unknown") · recognised: \(.tier)",
    "         head: \(.head // "unobserved") · artifact: \(.artifact // "none") · \(.token)",
    (if .missing then "         incomplete binding, missing: \(.missing)" else empty end),
    (if .superseded_records > 0 then "         \(.superseded_records) earlier request(s) bound to a different head" else empty end)'
}

render_human() {
  local defects unevaluable satisfied
  if [ "$(printf '%s' "$SWEEP" | jq -r '.readable')" != "true" ]; then
    printf 'UNEVALUABLE - %s\n' "$(printf '%s' "$SWEEP" | jq -r '.reason')"
    return
  fi
  defects=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="defect")] | length')
  unevaluable=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="unevaluable")] | length')
  satisfied=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="satisfied")] | length')
  printf 'outbound artifacts: %s satisfied, %s defect, %s could-not-observe\n' \
    "$satisfied" "$defects" "$unevaluable"
  # THREE SECTIONS, never one list. A could-not-observe rendered inline among
  # defects reads as a defect, and a reader who learns to discount the noisy
  # list discounts both. Rendered as its own section it stays a distinct third
  # answer that can be acted on differently - and it must never be omitted when
  # empty-looking, because "nothing here" and "we could not look" are the two
  # things this whole control exists to keep apart.
  render_section defect 'DEFECT - waiting with no applicable durable artifact'
  render_section unevaluable 'COULD NOT OBSERVE - neither confirmed waiting legitimately nor confirmed defective'
  render_section satisfied 'SATISFIED'
  if [ "$(printf '%s' "$SWEEP" | jq -r '.capped')" = "true" ]; then
    printf '\nPROBE CAP REACHED at %s observations - this sweep did not check every item.\n' "$MAX_PROBES"
  fi
}

# The relay form. One line per defect and nothing at all when the invariant
# holds, so a session-start section stays silent-when-good without ever going
# silent-when-blind: an unevaluable sweep prints too.
render_defects() {
  if [ "$(printf '%s' "$SWEEP" | jq -r '.readable')" != "true" ]; then
    printf 'OUTBOUND: sweep unevaluable - %s\n' "$(printf '%s' "$SWEEP" | jq -r '.reason')"
    return
  fi
  printf '%s' "$SWEEP" | jq -r '.rows[] | select(.verdict=="defect") |
    "OUTBOUND: \(.item) is waiting on \(.gate // "an untyped gate") with no applicable durable artifact (\(.token)) - head \(.head // "unobserved"), channel \(.channel // "unknown")"'
  printf '%s' "$SWEEP" | jq -r '.rows[] | select(.verdict=="unevaluable") |
    "OUTBOUND: \(.item) artifact state COULD-NOT-OBSERVE (\(.token)) - its waiting is neither confirmed legitimate nor confirmed defective"'
  if [ "$(printf '%s' "$SWEEP" | jq -r '.capped')" = "true" ]; then
    printf 'OUTBOUND: probe cap %s reached - this sweep did not check every waiting item\n' "$MAX_PROBES"
  fi
}

sweep_exit() {
  local defects unevaluable
  [ "$(printf '%s' "$SWEEP" | jq -r '.readable')" = "true" ] || return 4
  defects=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="defect")] | length')
  unevaluable=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="unevaluable")] | length')
  [ "$defects" -eq 0 ] || return 3
  # A capped sweep did not look at everything, so it cannot certify the whole
  # fleet even when everything it did look at was fine.
  { [ "$unevaluable" -eq 0 ] && ! probes_capped; } || return 4
  return 0
}

# --- emit --------------------------------------------------------------------
#
# Idempotency, retry, and crash safety are ONE mechanism rather than three:
#
#   The request id is a digest of the identity, so the same item at the same head
#   always computes the same id no matter how many schedulers ask.
#   A per-id lock makes concurrent emits single-flight, so one cycle cannot post
#   twice.
#   The record is checkpointed as `emitting` BEFORE the transport call, so a
#   process killed mid-post leaves durable evidence that a post may be in flight.
#   Recovery does not guess from that evidence: it re-reads the forge for the id,
#   which is authoritative, and adopts whatever it finds.
#
# A transport failure therefore never loses the request: attempts are recorded in
# the durable record and the item stays red until an artifact is observed.

supersede_other_heads() {  # <item> <current-request-id> <current-head>
  local item=$1 rid=$2 head=$3 f other rec read_rc
  [ -d "$RECORD_DIR" ] || return 0
  for f in "$RECORD_DIR"/*.json; do
    [ -f "$f" ] || continue
    other=${f##*/}
    other=${other%.json}
    rec=$(record_read "$other"); read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
      case $read_rc in
        1|2) return 2 ;;
        5) return 5 ;;
        *) return 2 ;;
      esac
    fi
    printf '%s' "$rec" | jq -e --arg i "$item" --arg h "$head" \
      '.identity.item == $i and .identity.head != $h and .state != "closed" and .state != "superseded"' \
      >/dev/null 2>&1 || continue
    rec=$(printf '%s' "$rec" | jq --arg s "$rid" --arg n "$(now_iso)" \
      '.state = "superseded" | .superseded_by = $s | .updated = $n')
    record_write "$other" "$rec" || return 2
    printf 'superseded: %s (bound to a head that moved)\n' "$other"
  done
}

BACKLOG_RECORD=
require_unique_backlog_record() {  # <item>
  local item=$1 matches count
  matches=$(printf '%s' "$SNAPSHOT" | jq -c --arg i "$item" \
    '[.backlog.records[] | select(.structured == true and .id == $i)]') \
    || die "durable backlog records for '$item' could not be read" 4
  count=$(printf '%s' "$matches" | jq 'length') \
    || die "durable backlog records for '$item' could not be counted" 4
  if [ "$count" -ne 1 ]; then
    die "durable backlog id '$item' matched $count records; refusing to choose by position" 4
  fi
  BACKLOG_RECORD=$(printf '%s' "$matches" | jq -c '.[0]') \
    || die "durable backlog record for '$item' could not be read" 4
}

cmd_emit() {
  local item=$1 rationale=$2 dry=$3
  local rec gate channel project pr_url pr_ref head_observation head head_source venue missing rid record
  local attempt delay body found existing dedupe_rc retry_rc record_rc supersede_rc

  read_snapshot || die "fleet backlog could not be read" 4
  require_unique_backlog_record "$item"
  rec=$BACKLOG_RECORD

  gate=$(classify_record "$rec" | cut -f2)
  channel=$(fm_outbound_gate_channel "$gate")

  if [ -z "$channel" ]; then
    printf '%s: %s has no typed gate, so no artifact can be constructed for it\n' \
      "$FM_OUTBOUND_TOKEN_INCOMPLETE" "$item" >&2
    exit 3
  fi
  if ! fm_outbound_channel_can_emit "$channel"; then
    printf '%s: %s is on the %s channel, which this mechanism detects but never creates.\n' \
      "$FM_OUTBOUND_TOKEN_DETECT_ONLY" "$item" "$channel" >&2
    printf 'Opening it is a delivery action owned by the task delivery path, not by this command.\n' >&2
    exit 3
  fi

  project=$(printf '%s' "$rec" | jq -r '.repo // ""')
  pr_url=$(printf '%s' "$rec" | jq -r '.pr_url // ""')
  pr_ref=$(printf '%s' "$rec" | jq -r '.pr_url // "-"')
  head_observation=$(observe_head "$item" "$pr_url" "$project")
  head=$(printf '%s' "$head_observation" | cut -f1)
  head_source=$(printf '%s' "$head_observation" | cut -f2)

  if ! read_sol_config; then
    printf '%s: config/sol-control.json is absent or incomplete, so no request can be addressed.\n' \
      "$FM_OUTBOUND_TOKEN_UNCONFIGURED" >&2
    printf '%s remains waiting with no artifact; this refusal does not clear it.\n' "$item" >&2
    exit 4
  fi
  venue=$SOL_REPO

  missing=$(fm_outbound_binding_missing "$gate" "$project" "$venue" "$item" "$head" "$PROJECTS/$project" "$head_source" || true)
  if [ -n "$missing" ]; then
    printf '%s: cannot construct an exact-head-bound request for %s - missing %s\n' \
      "$FM_OUTBOUND_TOKEN_INCOMPLETE" "$item" \
      "$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')" >&2
    printf 'Refusing to emit a vague request. %s stays red until the binding is complete.\n' "$item" >&2
    exit 3
  fi

  rid=$(fm_outbound_request_id "$gate" "$project" "$venue" "$item" "$pr_ref" "$head") \
    || die "could not compute a request identity" 4

  if [ "$dry" = "1" ]; then
    record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$venue" \
      "$item" "$pr_ref" "$head" "$SOL_REPO#$SOL_ISSUE" "$(now_iso)" "$head_source")
    fm_outbound_request_body "$record" "$rationale"
    return 0
  fi

  mkdir -p "$RECORD_DIR" || die "cannot create $RECORD_DIR" 4
  if ! fm_lock_try_acquire "$RECORD_DIR/.$rid.lock"; then
    printf '%s: another emit for %s is already in flight\n' \
      "$FM_OUTBOUND_TOKEN_IN_FLIGHT" "$rid" >&2
    exit 3
  fi
  EMIT_LOCK="$RECORD_DIR/.$rid.lock"

  supersede_other_heads "$item" "$rid" "$head"; supersede_rc=$?
  if [ "$supersede_rc" -ne 0 ]; then
    case $supersede_rc in
      5) die "$FM_OUTBOUND_TOKEN_IDENTITY: a keyed correlation record belongs to another request" 3 ;;
      *) die "$FM_OUTBOUND_TOKEN_UNREADABLE: could not validate every keyed correlation record" 4 ;;
    esac
  fi

  # Dedupe against the forge FIRST. This is both ordinary duplicate suppression
  # and the crash-recovery path, because they are the same question: does an
  # artifact carrying this id already exist?
  record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$venue" \
    "$item" "$pr_ref" "$head" "$SOL_REPO#$SOL_ISSUE" "$(now_iso)" "$head_source")
  found=$(sol_artifact_present "$rid" "$record"); dedupe_rc=$?
  if [ "$dedupe_rc" -eq 0 ]; then
    existing=$(record_read "$rid"); record_rc=$?
    if [ "$record_rc" -eq 0 ]; then
      record=$(printf '%s' "$existing" | jq --arg c "$found" --arg n "$(now_iso)" \
        '.comment_id = $c | .state = (if .state == "emitting" then "emitted" else .state end) | .updated = $n')
    else
      case $record_rc in
        1)
          record=$(printf '%s' "$record" | jq --arg c "$found" '.comment_id = $c | .state = "emitted"')
          ;;
        5) die "$FM_OUTBOUND_TOKEN_IDENTITY: correlation record $rid belongs to another request" 3 ;;
        *) die "$FM_OUTBOUND_TOKEN_UNREADABLE: correlation record $rid could not be validated" 4 ;;
      esac
    fi
    record_write "$rid" "$record" || die "could not write the correlation record" 4
    printf 'already requested: %s (comment %s)\n' "$rid" "$found"
    return 0
  fi
  if [ "$dedupe_rc" -ne 1 ]; then
    printf '%s: could not conclusively establish that request %s is absent; refusing to post\n' \
      "$FM_OUTBOUND_TOKEN_ARTIFACT_UNOBSERVED" "$rid" >&2
    exit 4
  fi

  record=$(record_read "$rid"); record_rc=$?
  if [ "$record_rc" -ne 0 ]; then
    case $record_rc in
      1)
        record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$venue" \
          "$item" "$pr_ref" "$head" "$SOL_REPO#$SOL_ISSUE" "$(now_iso)" "$head_source")
        ;;
      5) die "$FM_OUTBOUND_TOKEN_IDENTITY: correlation record $rid belongs to another request" 3 ;;
      *) die "$FM_OUTBOUND_TOKEN_UNREADABLE: correlation record $rid could not be validated" 4 ;;
    esac
  fi
  # CHECKPOINT BEFORE TRANSPORT. If this process dies after the post and before
  # the success write, the record already names the id the recovery path needs.
  record_write "$rid" "$record" || die "could not write the correlation record" 4

  body=$(fm_outbound_request_body "$record" "$rationale")
  attempt=0
  delay=$BACKOFF_BASE
  while [ "$attempt" -lt "$ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    record=$(printf '%s' "$record" | jq --argjson a "$attempt" --arg n "$(now_iso)" \
      '.attempts = $a | .updated = $n')
    record_write "$rid" "$record" || die "could not write the correlation record" 4
    # fm-retrieval-audit: write - this creates a comment and draws no conclusion from a collection read.
    if jq -n --arg b "$body" '{body:$b}' | obs gh api \
      "repos/$SOL_REPO/issues/$SOL_ISSUE/comments" --input - >/dev/null; then
      record=$(printf '%s' "$record" | jq --arg n "$(now_iso)" '.state = "emitted" | .updated = $n')
      if found=$(sol_artifact_present "$rid" "$record"); then
        record=$(printf '%s' "$record" | jq --arg c "$found" '.comment_id = $c')
      fi
      record_write "$rid" "$record" || die "could not write the correlation record" 4
      printf 'requested: %s on %s#%s\n' "$rid" "$SOL_REPO" "$SOL_ISSUE"
      return 0
    fi
    found=$(sol_artifact_present "$rid" "$record"); retry_rc=$?
    if [ "$retry_rc" -eq 0 ]; then
      record=$(printf '%s' "$record" | jq --arg c "$found" --arg n "$(now_iso)" \
        '.comment_id = $c | .state = "emitted" | .updated = $n')
      record_write "$rid" "$record" || die "could not write the correlation record" 4
      printf 'requested: %s on %s#%s (accepted before transport response failed)\n' \
        "$rid" "$SOL_REPO" "$SOL_ISSUE"
      return 0
    fi
    if [ "$retry_rc" -ne 1 ]; then
      printf '%s: transport failed and request presence could not be observed; refusing to retry %s\n' \
        "$FM_OUTBOUND_TOKEN_ARTIFACT_UNOBSERVED" "$rid" >&2
      exit 4
    fi
    [ "$attempt" -lt "$ATTEMPTS" ] || break
    case $delay in ''|*[!0-9]*) delay=0 ;; esac
    if [ "$delay" -gt 0 ]; then sleep "$delay"; delay=$((delay * 2)); fi
  done

  printf 'transport failed after %s attempts; the request is NOT lost - %s is checkpointed at %s\n' \
    "$ATTEMPTS" "$rid" "$(record_path "$rid")" >&2
  printf '%s remains waiting with no artifact.\n' "$item" >&2
  exit 4
}

# --- correlation -------------------------------------------------------------
#
# The chain a ruling has to complete: request -> ruling -> resumed item ->
# disposition. Each step refuses an identity it cannot join, which is what stops
# an unrelated ruling from waking an item that was never asking.

# Answers through a GLOBAL rather than stdout, deliberately. A refusal here has
# to stop the command, and `exit` inside a command substitution kills only the
# subshell - the caller would sail on with an empty record and reach some later
# guard instead. That still refuses, which is why the mistake survives review,
# but it refuses with the WRONG verdict: an unreadable record (could-not-observe,
# exit 4) would be reported as an identity mismatch (a verdict, exit 3). Which is
# the three-value collapse this whole mechanism exists to prevent, one level down.
RECORD=
require_record() {  # <request-id>; sets RECORD or exits
  local rc
  RECORD=$(record_read "$1"); rc=$?
  if [ "$rc" -eq 1 ]; then
    printf '%s: no request %s exists, so nothing is waiting on this ruling\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$1" >&2
    exit 3
  fi
  if [ "$rc" -eq 5 ]; then
    printf '%s: the record filed under %s identifies a different request\n' \
      "$FM_OUTBOUND_TOKEN_IDENTITY" "$1" >&2
    printf 'Its path located it; its own contents refuse it, so the wait stays unsatisfied.\n' >&2
    exit 3
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s: the record for %s could not be read\n' \
      "$FM_OUTBOUND_TOKEN_UNREADABLE" "$1" >&2
    exit 4
  fi
}

require_record_applicable_now() {  # <request-id> <record-json>
  local rid=$1 rec=$2 item current gate channel project repo pr_url pr_ref head_observation head head_source missing
  local stored_identity current_identity stored_venue current_venue
  item=$(printf '%s' "$rec" | jq -r '.identity.item')
  read_snapshot || die "fleet backlog could not be read while validating $rid" 4
  require_unique_backlog_record "$item"
  current=$BACKLOG_RECORD
  gate=$(classify_record "$current" | cut -f2)
  channel=$(fm_outbound_gate_channel "$gate")
  [ -n "$channel" ] || die "$FM_OUTBOUND_TOKEN_INCOMPLETE: the current gate for $item is incomplete" 3
  project=$(printf '%s' "$current" | jq -r '.repo // ""')
  pr_url=$(printf '%s' "$current" | jq -r '.pr_url // ""')
  pr_ref=$(printf '%s' "$current" | jq -r '.pr_url // "-"')
  head_observation=$(observe_head "$item" "$pr_url" "$project")
  head=$(printf '%s' "$head_observation" | cut -f1)
  head_source=$(printf '%s' "$head_observation" | cut -f2)
  if [ "$channel" = "pull-request" ]; then
    repo=$(project_venue "$project" \
      "$(printf '%s' "$current" | jq -r '.contribution_venue // ""')")
  else
    read_sol_config || die "the configured control repository could not be observed" 4
    repo=$SOL_REPO
    current_venue="$SOL_REPO#$SOL_ISSUE"
  fi
  missing=$(fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" "$PROJECTS/$project" "$head_source" || true)
  [ -z "$missing" ] || die "the current identity for $item is incomplete: $(printf '%s' "$missing" | tr '\n' ',')" 4
  stored_identity=$(printf '%s' "$rec" | jq -r \
    '[.identity.gate,.identity.project,.identity.repo,.identity.item,(.identity.pr // "-"),.identity.head] | @tsv')
  current_identity=$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$gate" "$project" "$repo" "$item" "$pr_ref" "$head")
  stored_venue=$(printf '%s' "$rec" | jq -r '.venue // ""')
  if [ "$current_identity" != "$stored_identity" ] \
    || { [ "$channel" = "sol-control" ] && [ "$current_venue" != "$stored_venue" ]; }; then
    rec=$(printf '%s' "$rec" | jq --arg n "$(now_iso)" \
      '.state = "superseded" | .updated = $n')
    record_write "$rid" "$rec" || die "could not invalidate stale request $rid" 4
    printf '%s: request %s no longer matches the complete current identity\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" >&2
    exit 3
  fi
}

cmd_ruling() {  # <request-id> <comment-id> <issue>
  local rid=$1 comment=$2 issue=$3 rec state venue_repo venue_issue artifact body request_comment verdict verdict_count
  require_record "$rid"; rec=$RECORD
  state=$(printf '%s' "$rec" | jq -r '.state')
  case $state in
    emitted|ruled) ;;
    *)
      printf '%s: request %s is %s, which is not a state that can receive a ruling\n' \
        "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" "$state" >&2
      exit 3 ;;
  esac
  require_record_applicable_now "$rid" "$rec"
  request_comment=$(printf '%s' "$rec" | jq -r '.comment_id // ""')
  if [ -n "$request_comment" ] && [ "$comment" = "$request_comment" ]; then
    printf '%s: request comment %s cannot rule on itself\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" >&2
    exit 3
  fi
  venue_repo=$(printf '%s' "$rec" | jq -r '.venue' | sed 's/#.*//')
  venue_issue=$(printf '%s' "$rec" | jq -r '.venue' | sed 's/.*#//')
  if [ "$issue" != "$venue_issue" ]; then
    printf '%s: ruling arrived on issue %s but %s was asked on issue %s\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$issue" "$rid" "$venue_issue" >&2
    exit 3
  fi
  read_sol_config || die "the configured ruling venue could not be observed" 4
  [ "$SOL_REPO" = "$venue_repo" ] && [ "$SOL_ISSUE" = "$venue_issue" ] \
    || die "the configured ruling venue no longer matches request $rid" 4
  # fm-retrieval-audit: not-a-collection - this reads one comment named by its durable correlation identity.
  artifact=$(obs gh api "repos/$venue_repo/issues/comments/$comment") \
    || die "ruling comment $comment could not be observed" 4
  printf '%s' "$artifact" | jq -e --arg c "$comment" --arg i "$issue" \
    '(.id|tostring) == $c and (.issue_url | endswith("/issues/" + $i)) and (.body|type) == "string"' \
    >/dev/null 2>&1 || {
      printf '%s: comment %s is not the requested inbound artifact\n' \
        "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" >&2
      exit 3
    }
  body=$(printf '%s' "$artifact" | jq -r '.body')
  if ! artifact_body_matches_identity "$body" "$rec" "$FM_OUTBOUND_RULING_MARKER"; then
      printf '%s: comment %s does not carry the exact request identity\n' \
        "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" >&2
      exit 3
  fi
  # THE SENDER, before the verdict. A body that does not establish who sent it
  # cannot be read for what it decided, so this refuses ahead of any verdict
  # parsing rather than after it.
  #
  # This is not hypothetical hardening. A live malformed sender demonstrated that
  # discovery by prefix lets a body addressed to someone else wake this fleet, so
  # the test is exactly one `from:` line whose WHOLE trimmed value equals the one
  # role an inbound ruling may carry. Prefix, substring, duplicate, unknown, and
  # a body claiming to come from firstmate itself are all invalid.
  #
  # An invalid sender is COULD-NOT-OBSERVE, not a defect and not a rejection of
  # the ruling's content: we did not learn that the ruling is wrong, we learned
  # that we cannot tell who sent it. It wakes nothing, which is the only safe
  # thing an unidentified instruction can be allowed to do.
  if ! fm_outbound_sender_valid "$body" "$FM_OUTBOUND_INBOUND_SENDER"; then
    printf '%s: comment %s does not carry exactly one "from: %s" sender line\n' \
      "$FM_OUTBOUND_TOKEN_SENDER_INVALID" "$comment" "$FM_OUTBOUND_INBOUND_SENDER" >&2
    printf 'Refusing rather than guessing the sender. Nothing is woken by a body whose origin is ambiguous.\n' >&2
    exit 3
  fi
  # EXACTLY ONE verdict line, or refuse. Not the first, and not the last: both
  # resolve ambiguity by POSITION, which is a guess wearing the clothes of a
  # policy. Rulings on this control plane quote prior rulings as a matter of
  # course, so a body carrying two verdict lines is the ORDINARY shape rather
  # than an attack, and reading the first would silently adopt whatever the
  # ruling was quoting instead of what it decided.
  #
  # Same rule as a duplicate disposition refusing rather than resolving by array
  # order, and as an unparseable construct reporting could-not-observe rather
  # than being skipped: an ambiguous input is refused loudly and then fixed, and
  # is never resolved into a confident answer nobody chose.
  verdict_count=$(printf '%s\n' "$body" | grep -c '^verdict: ' || true)
  case $verdict_count in ''|*[!0-9]*) verdict_count=0 ;; esac
  if [ "$verdict_count" -ne 1 ]; then
    printf '%s: comment %s carries %s verdict lines; exactly one is required\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" "$verdict_count" >&2
    printf 'Refusing rather than reading one by position. A ruling that quotes another must state its own verdict once.\n' >&2
    exit 3
  fi
  verdict=$(printf '%s\n' "$body" | sed -n 's/^verdict: //p')
  rec=$(printf '%s' "$rec" | jq --arg c "$comment" --arg v "$verdict" --arg n "$(now_iso)" \
    '.ruling = {comment_id:$c, verdict:$v, observed:$n} | .state = "ruled" | .updated = $n')
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'ruled: %s wakes %s\n' "$rid" "$(printf '%s' "$rec" | jq -r '.identity.item')"
}

cmd_poll() {
  local comments row body rid marker_count comment rc failed=0 poll_record poll_state out
  read_sol_config || return 0
  probe_budget || die "the ruling poll probe budget is exhausted" 4
  # fm-retrieval-audit: complete-source - --paginate traverses every issue-comment page before absence is concluded.
  comments=$(obs gh api "repos/$SOL_REPO/issues/$SOL_ISSUE/comments" --paginate \
    --jq '.[] | [.id, .body] | @base64') || die "ruling comments could not be observed" 4
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    comment=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[0] | tostring') \
      || { failed=4; continue; }
    body=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[1]') \
      || { failed=4; continue; }
    rid=$(printf '%s\n' "$body" \
      | sed -n "s/^$FM_OUTBOUND_RULING_MARKER \($FM_OUTBOUND_REQUEST_ID_PATTERN\)$/\1/p")
    marker_count=$(printf '%s\n' "$rid" | grep -c . || true)
    [ "$marker_count" -ne 0 ] || continue
    if [ "$marker_count" -gt 1 ]; then
      printf '%s: comment %s carries %s ruling marker lines, so which request it rules is ambiguous\n' \
        "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" "$marker_count" >&2
      printf 'Refusing rather than reading one by position. A ruling that quotes another must state its own request once.\n' >&2
      [ "$failed" -ne 0 ] || failed=3
      continue
    fi
    poll_record=$(record_read "$rid") || poll_record=
    if [ -n "$poll_record" ]; then
      poll_state=$(printf '%s' "$poll_record" | jq -r '.state')
      case $poll_state in
        resumed|closed|superseded) continue ;;
        ruled) continue ;;
      esac
    fi
    out=$("$0" ruling --request "$rid" --comment "$comment" --issue "$SOL_ISSUE" 2>&1)
    rc=$?
    [ -z "$out" ] || printf '%s\n' "$out"
    if [ "$rc" -eq 4 ] || { [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; }; then
      failed=$rc
    fi
  done <<< "$comments"
  return "$failed"
}

cmd_resume() {  # <request-id>
  local rid=$1 rec state
  require_record "$rid"; rec=$RECORD
  state=$(printf '%s' "$rec" | jq -r '.state')
  if [ "$state" != "ruled" ]; then
    printf '%s: request %s is %s; only a ruled request can resume its item\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" "$state" >&2
    exit 3
  fi
  require_record_applicable_now "$rid" "$rec"
  rec=$(printf '%s' "$rec" | jq --arg n "$(now_iso)" \
    '.resumed = {at:$n} | .state = "resumed" | .updated = $n')
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'resumed: %s\n' "$(printf '%s' "$rec" | jq -r '.identity.item')"
}

cmd_close() {  # <request-id> <disposition>
  local rid=$1 disp=$2 rec state
  require_record "$rid"; rec=$RECORD
  state=$(printf '%s' "$rec" | jq -r '.state')
  if [ "$state" != "resumed" ]; then
    printf '%s: request %s is %s; only a resumed request can be closed\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" "$state" >&2
    exit 3
  fi
  rec=$(printf '%s' "$rec" | jq --arg d "$disp" --arg n "$(now_iso)" \
    '.disposition = {outcome:$d, at:$n} | .state = "closed" | .updated = $n')
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'closed: %s - %s\n' "$rid" "$disp"
}

# --- entry -------------------------------------------------------------------

usage() { sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

[ $# -gt 0 ] || { usage; exit 2; }
CMD=$1; shift
case $CMD in
  -h|--help|help) usage; exit 0 ;;
  check|status|defects)
    JSON=0
    if [ $# -gt 0 ]; then
      [ "$1" = "--json" ] || die "unknown option '$1'"
      JSON=1; shift
    fi
    [ $# -eq 0 ] || die "unexpected argument '$1'"
    sweep || true
    if [ "$JSON" -eq 1 ]; then printf '%s\n' "$SWEEP"
    elif [ "$CMD" = "defects" ]; then render_defects
    else render_human; fi
    sweep_exit; exit $?
    ;;
  reconcile)
    [ $# -eq 0 ] || die "reconcile takes no arguments"
    cmd_poll
    POLL_RC=$?
    sweep || true
    printf '%s' "$SWEEP" | jq -r '.rows[] | select(.verdict=="defect" and .channel=="sol-control" and .missing==null) | .item' \
      | while IFS= read -r ITEM; do
          [ -n "$ITEM" ] || continue
          cmd_emit "$ITEM" "" 0 || exit $?
        done
    RECONCILE_RC=${PIPESTATUS[1]}
    [ "$RECONCILE_RC" -eq 0 ] || exit "$RECONCILE_RC"
    sweep || true
    render_defects
    sweep_exit; SWEEP_RC=$?
    [ "$POLL_RC" -eq 0 ] || exit "$POLL_RC"
    exit "$SWEEP_RC"
    ;;
  poll)
    [ $# -eq 0 ] || die "poll takes no arguments"
    cmd_poll
    ;;
  emit)
    ITEM=; RATIONALE=; DRY=0
    while [ $# -gt 0 ]; do
      case $1 in
        --rationale-file) RATIONALE=${2:-}; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -*) die "unknown option '$1'" ;;
        *) ITEM=$1; shift ;;
      esac
    done
    [ -n "$ITEM" ] || die "emit needs an item id"
    cmd_emit "$ITEM" "$RATIONALE" "$DRY"
    ;;
  ruling)
    RID=; COMMENT=; ISSUE=
    while [ $# -gt 0 ]; do
      case $1 in
        --request) RID=${2:-}; shift 2 ;;
        --comment) COMMENT=${2:-}; shift 2 ;;
        --issue) ISSUE=${2:-}; shift 2 ;;
        *) die "unknown option '$1'" ;;
      esac
    done
    [ -n "$RID" ] && [ -n "$COMMENT" ] && [ -n "$ISSUE" ] \
      || die "ruling needs --request, --comment, and --issue"
    cmd_ruling "$RID" "$COMMENT" "$ISSUE"
    ;;
  resume)
    RID=
    while [ $# -gt 0 ]; do
      case $1 in --request) RID=${2:-}; shift 2 ;; *) die "unknown option '$1'" ;; esac
    done
    [ -n "$RID" ] || die "resume needs --request"
    cmd_resume "$RID"
    ;;
  close)
    RID=; DISP=
    while [ $# -gt 0 ]; do
      case $1 in
        --request) RID=${2:-}; shift 2 ;;
        --disposition) DISP=${2:-}; shift 2 ;;
        *) die "unknown option '$1'" ;;
      esac
    done
    [ -n "$RID" ] && [ -n "$DISP" ] || die "close needs --request and --disposition"
    cmd_close "$RID" "$DISP"
    ;;
  show)
    [ $# -gt 0 ] || die "show needs a request id"
    record_read "$1" || die "no readable record for '$1'" 4
    ;;
  *) die "unknown command '$CMD'" ;;
esac
