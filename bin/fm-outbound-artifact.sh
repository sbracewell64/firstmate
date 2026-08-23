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
#       Pull-request rows remain detect-only. Every selected item is attempted
#       and the report is rendered on the way out REGARDLESS, so one item's
#       refusal never hides another item's defect.
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
#
#   MATERIAL PUBLICATION - one request that carries exact bytes rather than only
#   a question, published as several comments and completed only once every one
#   of them reconstructs the subject that was prepared.
#   fm-outbound-artifact.sh material prepare <item-id> --manifest <path>
#                                            [--venue <owner/name>#<issue>]
#       Bind a generation: the venue, the declared universe, its content digests
#       and its deterministic parts. Idempotent for the same subject; a DIFFERENT
#       subject is refused here and becomes a successor instead.
#   fm-outbound-artifact.sh material emit --request <id>
#       Publish every part not already exact at the record's venue. Resumable,
#       bounded, and idempotent per part.
#   fm-outbound-artifact.sh material verify --request <id> [--json]
#       Reobserve every part and reconstruct the subject. Never mutates the venue.
#   fm-outbound-artifact.sh material complete --request <id>
#       The single completion transition: verify, then emit the successor request
#       exactly once.
#   fm-outbound-artifact.sh material succeed --request <id> --manifest <path>
#       Open ONE successor generation for a stale subject, preserving the prior
#       generation verbatim.
#   fm-outbound-artifact.sh material show <request-id> [--json]
#       What the record holds. Reading is not verification and says so.
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
# RECONCILE'S STATUS IS THE WORST THING THAT HAPPENED, NOT WHERE IT STOPPED.
# `reconcile` runs a poll, a sweep, one emit per selected item, and a second
# sweep. It does not stop at the first refusal, because stopping the WORK and
# suppressing the REPORT about work already done are different things and an
# early exit did both: the final render sits after the emit loop, so a single
# refused item printed its own un-prefixed reason and nothing else, at the one
# moment an operator is reading. Each phase's status is folded by the module's
# severity order - 4 outranks 3 outranks 0 - and the fold is what is returned.
# A refused emit therefore still leaves a complete report behind it.
#
# 3 AND 4 ARE NOT INTERCHANGEABLE. 3 says the fleet is provably wrong. 4 says the
# question was not answered. Reporting 4 as 0 is the exact conversion that hid
# the original defect, so an unreadable backlog, an unreachable forge, an
# unconfigured venue, and an unobservable head all reach 4 and never 0.
#
# THAT PARAGRAPH WAS TRUE OF THE RULE AND FALSE OF THE CODE, IN TWO PLACES, AND
# BOTH ARE FIXED HERE. This is the second way the originating incident happens:
# the first way was a waiting item nobody ever asked about, and the second is a
# verdict that answers a question this sweep never looked at.
#   1. sweep_exit tested `defects` first and returned, so the fold named
#      directly above it was skipped and a sweep holding 22 defects and 19
#      could-not-observes exited 3 - the fleet is provably wrong - when the
#      module's own order makes the honest answer 4.
#   2. An item whose exact head could not be READ was classified as a defect
#      under FM_OUTBOUND_HEAD_UNOBSERVED and rendered as "no applicable durable
#      artifact", a positive claim about the forge derived from a failed local
#      read, while three sibling tokens naming the identical condition all
#      reached 4.
# Neither repair quiets anything: a structurally unbindable item is still a
# defect, still drives the exit, and still renders as one.
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
#   FM_OUTBOUND_TIMEOUT         seconds per forge or git observation (default 15).
#                               ONE observation, never a whole sweep. A caller
#                               that needs to bound the whole run owns its own
#                               deadline under its own name - see
#                               FM_OUTBOUND_BOOTSTRAP_DEADLINE in
#                               bin/fm-bootstrap.sh - because a single name
#                               cannot mean both without one of them widening
#                               the other.
#   FM_OUTBOUND_MATERIAL_PART_BYTES
#                               wire bytes per published part (default 45600,
#                               chosen under a 65536-character comment body with
#                               room for the part's own binding header)
#   FM_OUTBOUND_MATERIAL_MAX_PARTS
#                               refuse a generation needing more parts than this
#                               (default 64). The bound is REPORTED, never
#                               silently applied by truncating the universe.
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

# The lock is released HERE rather than only from the EXIT trap. `reconcile`
# calls cmd_emit once per waiting item in one process, so a lock released only
# at process exit means each emit overwrites the previous EMIT_LOCK and every
# one of them outlives the run as a stale lock directory.
release_emit_lock() {
  [ -z "$EMIT_LOCK" ] || fm_lock_release "$EMIT_LOCK"
  EMIT_LOCK=
}

cleanup() {
  release_emit_lock
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

# The budget is reset at each PHASE BOUNDARY rather than divided in advance,
# because `reconcile` runs poll, sweep, emit and sweep again in one process and
# the phases have no fixed ratio to divide by. A cap that bounds this phase is a
# cap; a cap that a previous phase can spend on this one's behalf is a race, and
# it reports the later sweep as capped for work it never did.
probe_budget_reset() {
  printf '0' > "$PROBE_COUNT"
  : > "$PROBE_CAPPED"
}

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

# Exit 0 with the number, 1 for absent, 2 could-not-observe, 3 no venue, and 7
# for AMBIGUOUS: an exact head carrying more than one open pull request. That
# last one gets its own code because "several candidates and none choosable" is
# a different fact from "the forge could not be read", and an operator told the
# generic gap goes looking for a broken probe instead of two open requests.
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
  # Refuse rather than take one by position. Naming the count is what makes the
  # report actionable: the repair is to close or retarget the extra request, and
  # picking the first would bind the invariant to whichever the forge listed.
  if [ "$count" -ne 1 ]; then
    printf 'exact head %s has %s open pull requests in %s\n' "$sha" "$count" "$venue" >&2
    return 7
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
#                 deliverable, deliverable records disagree, the only record is
#                 unfinished, or the backlog could not be read.
#   exit 3 - COULD NOT OBSERVE: lifecycle records disagree.
#   exit 4 - COULD NOT OBSERVE: the done-archive exists and cannot be read.
#
# The last two are split out from exit 2 because they are ACTIONABLE and exit 2
# is not. No record is a gap in the corpus with nothing to do about it; an
# unreadable archive is a permissions or I/O fault someone can go and repair.
# Reporting the second as the first sends an operator hunting for missing data
# that is present all along.
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
#
# An archived completion says the work was finished AT SOME POINT. It does not
# say that the head being inspected IS that finished work. This catches the
# REOPENED case, where a completion row and an open row coexist. It does NOT
# catch new commits landing on a branch after completion, where no reopening
# occurs and the historical completion row still certifies the current head.
# Closing that needs completion evidence bound to an exact head, which the
# corpus cannot supply today: almost none of the archived completion rows record
# one, so REQUIRING a head would push nearly the whole fleet into
# could-not-observe. That is not a safety win - it is the instrument going dark,
# and a check that can never pass is the same defect as a check that can never
# fail, inverted. The path forward is for new completion rows to record their
# head so the corpus becomes bindable going forward while historical rows
# degrade to the treatment above. That belongs to the completion writer, not to
# this module, and is filed separately.
finished_work_evidence() {  # <project> <item>
  local project=$1 item=$2 backlog archive lines states kinds count
  backlog="${FM_OUTBOUND_BACKLOG_FILE:-$DATA/backlog.md}"
  archive="${FM_OUTBOUND_DONE_ARCHIVE:-$DATA/done-archive.md}"
  [ -n "$project" ] && [ -n "$item" ] || return 2
  [ -r "$backlog" ] || return 2
  # An archive that EXISTS but cannot be read compromises the candidate set, so
  # it is could-not-observe even when the backlog alone would have answered. An
  # archive that does not exist yet is simply a smaller corpus, not a failure.
  # Its own exit code, because the repair differs from every other gap here.
  if [ -e "$archive" ] && [ ! -r "$archive" ]; then
    return 4
  fi
  lines=$(cat "$backlog" "$archive" 2>/dev/null \
    | grep -F -e "- [x] $item " -e "- [ ] $item " ; true)
  [ -n "$lines" ] || return 2
  # Identity is (project, work item), never the item name alone - the same
  # collapse the sweep dedupe was fixed for. Project names are compared
  # case-insensitively because the records carry both cases for one project.
  lines=$(printf '%s\n' "$lines" \
    | grep -iF -- "(repo: $project)" ; true)
  [ -n "$lines" ] || return 2
  states=$(printf '%s\n' "$lines" \
    | sed -n 's/^- \[x\] .*/completed/p; s/^- \[ \] .*/unfinished/p' | sort -u)
  count=$(printf '%s\n' "$states" | grep -c . || true)
  case $count in ''|*[!0-9]*) count=0 ;; esac
  # Two different could-not-observe reasons, kept apart. Zero parsed states means
  # the candidate lines matched the row token but none of them was a lifecycle
  # row this parser can read - an indented row, or one quoted mid-line - so
  # nothing was observed. Two or more means rows WERE read and contradict each
  # other. Reporting the first as a conflict sends the reader looking for a
  # disagreement that does not exist.
  [ "$count" -ne 0 ] || return 2
  # Disagreeing lifecycle records are ambiguous identity, not a menu to choose from.
  [ "$count" -eq 1 ] || return 3
  [ "$states" = completed ] || return 2
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
        3) row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" \
             "$venue" "$sha" "" unevaluable "$FM_OUTBOUND_TOKEN_WORK_LIFECYCLE_CONFLICT" "" "" 0 >> "$out"
           continue ;;
        4) row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" \
             "$venue" "$sha" "" unevaluable "$FM_OUTBOUND_TOKEN_ARCHIVE_UNREADABLE" "" "" 0 >> "$out"
           continue ;;
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
        7) row_json "$item" CONTRIBUTION_SUBMISSION_REQUIRED inventory pull-request "$project" \
             "$venue" "$sha" "" unevaluable "$FM_OUTBOUND_TOKEN_AMBIGUOUS" "" "" 0 >> "$out" ;;
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
  local existing record_state applicability record_rc all_records

  probe_budget_reset

  if ! read_snapshot; then
    SWEEP=$(jq -n '{schema:"fm-outbound-sweep.v1",readable:false,capped:false,
                    rows:[],reason:"fleet backlog could not be read"}')
    return 1
  fi

  rows=$(mktemp "$SCRATCH/rows.XXXXXX")
  count=$(printf '%s' "$SNAPSHOT" | jq '.backlog.records | length')
  # ONE pass over the record store per sweep. Nothing in this loop writes a
  # record, and the per-row question is a filter over the same snapshot, so
  # re-reading and re-validating every record for every waiting row bought
  # nothing and cost a full store walk per row inside a bounded sweep.
  all_records=$(records_all)
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
    #
    # THAT ARGUMENT IS SOUND FOR ONE OF THE TWO CONDITIONS THIS BRANCH COVERS.
    # A binding missing a STRUCTURAL field - an untyped gate, no project, no
    # repo, no item - is unbindable by construction: no exact-head-bound
    # artifact can exist for it, so defect is right and stays right.
    # A binding missing ONLY its head is a failed OBSERVATION. observe_head
    # asked the declaration, the forge and the clone, and none answered. The
    # head exists, an artifact bound to it may well exist on the forge, and this
    # sweep did not look. Calling that a defect derives a positive claim about
    # the forge from a failed local read, which is the conversion this whole
    # module exists to remove - and it did so while LANDING_TARGET_UNOBSERVED,
    # WORK_STATE_UNOBSERVED and CLONE_UNREADABLE, three tokens naming the
    # identical epistemic condition, all reached unevaluable.
    #
    # An item that is BOTH untyped and headless keeps the stronger verdict: the
    # gate is a read that succeeded and found nothing, so the item is provably
    # unbindable whatever the head turns out to be.
    missing=$(fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" "$PROJECTS/$project" "$head_source" || true)
    if [ -n "$missing" ]; then
      if [ "$missing" = head ]; then
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "" \
          unevaluable "$FM_OUTBOUND_TOKEN_HEAD_UNOBSERVED" "$missing" "" 0 >> "$rows"
      else
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "" \
          defect "$FM_OUTBOUND_TOKEN_INCOMPLETE" \
          "$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')" "" 0 >> "$rows"
      fi
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
          # A record that is READABLE and says it belongs to another request is
          # not an unreadable record. One is a correlation defect with a known
          # repair; the other is an observation gap. Collapsing them sends the
          # operator hunting for corruption or permissions that are not there.
          case $record_rc in
            1) rc=4 ;;
            5) rc=6 ;;
            *) rc=5 ;;
          esac
        fi
      fi
    fi

    # A local record is consulted only to EXPLAIN an absence, never to create a
    # presence. A record bound to a different head is exactly the stale-request
    # case, so the operator is told the previous ask went inapplicable rather
    # than merely that none exists.
    stale=$(printf '%s' "$all_records" | jq --arg i "$item" --arg h "$head" \
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
      6)
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "$rid" \
          defect "$FM_OUTBOUND_TOKEN_IDENTITY" "" "comment/$present" "$stale" >> "$rows"
        ;;
      7)
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "$rid" \
          unevaluable "$FM_OUTBOUND_TOKEN_AMBIGUOUS" "" "" "$stale" >> "$rows"
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
# The optional scope splits one verdict into the answers it actually contains.
# `identity` selects the rows whose artifact was OBSERVED and whose local record
# names another request; `not-identity` selects the rest. A heading has to be
# true of every row beneath it, and one heading cannot be true of both an absent
# artifact and a present one.
render_section() {  # <verdict> <heading> [all|identity|not-identity]
  local verdict=$1 heading=$2 scope=${3:-all} n
  n=$(printf '%s' "$SWEEP" | jq --arg v "$verdict" --arg i "$FM_OUTBOUND_TOKEN_IDENTITY" \
    --arg s "$scope" '[.rows[] | select(.verdict==$v)
      | select($s == "all" or ($s == "identity") == (.token == $i))] | length')
  printf '\n%s (%s)\n' "$heading" "$n"
  if [ "$n" -eq 0 ]; then
    printf '  none\n'
    return
  fi
  printf '%s' "$SWEEP" | jq -r --arg v "$verdict" --arg i "$FM_OUTBOUND_TOKEN_IDENTITY" \
    --arg h "$FM_OUTBOUND_TOKEN_HEAD_UNOBSERVED" \
    --arg s "$scope" '.rows[] | select(.verdict==$v)
    | select($s == "all" or ($s == "identity") == (.token == $i)) |
    "  \(.item)",
    "         gate: \(.gate // "UNTYPED") · channel: \(.channel // "unknown") · recognised: \(.tier)",
    "         head: \(.head // "unobserved") · artifact: \(.artifact // "none") · \(.token)",
    (if .token == $h then
       "         the exact head could not be READ from the declaration, the forge or the clone, so no artifact was looked for"
     elif .missing then "         incomplete binding, missing: \(.missing)" else empty end),
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
  render_section defect 'DEFECT - waiting with no applicable durable artifact' not-identity
  render_section defect 'DEFECT - the artifact exists, but the correlation record filed under its request id names a different request' identity
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
  # An identity refusal is reached only after the artifact was OBSERVED, so it
  # must never borrow the no-artifact sentence. The three answers stay audibly
  # different: this one is missing, this one could not be read, this one is not
  # about this work - and only the first is an absence.
  printf '%s' "$SWEEP" | jq -r --arg identity "$FM_OUTBOUND_TOKEN_IDENTITY" \
    '.rows[] | select(.verdict=="defect") |
     if .token == $identity then
       "OUTBOUND: \(.item) has its artifact \(.artifact // "unnamed") on the forge, but the correlation record filed under \(.request_id // "an unnamed request") names a DIFFERENT request (\(.token)) - the artifact is present and its identity is refused, so the wait is not satisfied"
     else
       "OUTBOUND: \(.item) is waiting on \(.gate // "an untyped gate") with no applicable durable artifact (\(.token)) - head \(.head // "unobserved"), channel \(.channel // "unknown")"
     end'
  # A *_UNOBSERVED token must never be handed a sentence that asserts absence.
  # The head case gets its own words because the generic one leaves the operator
  # to guess WHAT could not be observed, and the repair for an unreadable head -
  # make the head readable - is nothing like the repair for a missing artifact.
  printf '%s' "$SWEEP" | jq -r --arg h "$FM_OUTBOUND_TOKEN_HEAD_UNOBSERVED" \
    '.rows[] | select(.verdict=="unevaluable") |
     if .token == $h then
       "OUTBOUND: \(.item) - its exact head could not be read from the declaration, the forge or the clone (\(.token)), so this sweep did not look for an artifact and is NOT reporting that none exists"
     else
       "OUTBOUND: \(.item) artifact state COULD-NOT-OBSERVE (\(.token)) - its waiting is neither confirmed legitimate nor confirmed defective"
     end'
  if [ "$(printf '%s' "$SWEEP" | jq -r '.capped')" = "true" ]; then
    printf 'OUTBOUND: probe cap %s reached - this sweep did not check every waiting item\n' "$MAX_PROBES"
  fi
}

# The module's severity order, in one place. 4 outranks 3 outranks 0: a question
# that was not answered outranks an answer that says the fleet is wrong, because
# the unanswered one may be hiding something worse. cmd_poll already folds its
# per-comment statuses this way; this is that rule with a name.
outbound_worst_status() {  # <status> <status> -> the worse of the two
  local a=$1 b=$2
  case $a in ''|*[!0-9]*) a=4 ;; esac
  case $b in ''|*[!0-9]*) b=4 ;; esac
  if [ "$a" -eq 4 ] || [ "$b" -eq 4 ]; then printf '4\n'; return 0; fi
  if [ "$a" -ne 0 ]; then printf '%s\n' "$a"; return 0; fi
  printf '%s\n' "$b"
}

# THE EXIT IS THAT FOLD, NOT A LADDER THAT SHORT-CIRCUITS ABOVE IT. This tested
# `defects` first and returned, so a sweep holding both answers never reached
# `unevaluable` at all and reported 3 where the order directly above says 4. The
# header invites a caller to read the exit status alone, and that caller was
# being told the fleet is provably wrong at the exact moment the honest answer
# was that the question had not been answered - the direction the module's own
# reasoning calls the one that hides the worse condition. Both counts are folded
# now, so the exit status and the declared order cannot disagree.
#
# A count that could not be read is itself could-not-observe, never zero: an
# unreadable count is exactly the input that would otherwise certify a sweep
# nobody measured.
sweep_exit() {
  local defects unevaluable defect_status unevaluable_status
  [ "$(printf '%s' "$SWEEP" | jq -r '.readable')" = "true" ] || return 4
  defects=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="defect")] | length')
  unevaluable=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="unevaluable")] | length')
  case $defects in ''|*[!0-9]*) return 4 ;; esac
  case $unevaluable in ''|*[!0-9]*) return 4 ;; esac
  if [ "$defects" -eq 0 ]; then defect_status=0; else defect_status=3; fi
  # A capped sweep did not look at everything, so it cannot certify the whole
  # fleet even when everything it did look at was fine.
  if [ "$unevaluable" -eq 0 ] && ! probes_capped; then
    unevaluable_status=0
  else
    unevaluable_status=4
  fi
  return "$(outbound_worst_status "$defect_status" "$unevaluable_status")"
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
  # THE BOUND, STATED: this pass is O(records in the store), by construction and
  # not by oversight. The store is content-addressed - a record is named
  # fm-ob-<digest>.json where the digest is over the canonical identity - so the
  # work item cannot be recovered from a filename and no cheap name filter can
  # narrow the walk. The jq below is what scopes the DECISION to this item and
  # to non-terminal records; reading every file is what it costs to reach that
  # decision. Narrowing this would mean indexing the store, which is a change to
  # the record format rather than to this loop.
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
    release_emit_lock
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
      release_emit_lock
      return 0
    fi
    found=$(sol_artifact_present "$rid" "$record"); retry_rc=$?
    if [ "$retry_rc" -eq 0 ]; then
      record=$(printf '%s' "$record" | jq --arg c "$found" --arg n "$(now_iso)" \
        '.comment_id = $c | .state = "emitted" | .updated = $n')
      record_write "$rid" "$record" || die "could not write the correlation record" 4
      printf 'requested: %s on %s#%s (accepted before transport response failed)\n' \
        "$rid" "$SOL_REPO" "$SOL_ISSUE"
      release_emit_lock
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
    exit 4
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
    # AMBIGUOUS, not MISMATCH. A mismatch says the one candidate found is not
    # about this work; ambiguity says several were found and none can be chosen.
    # Labelling this a mismatch sends the operator asking why a ruling was
    # misaddressed when the truth is that one comment carried two markers.
    if [ "$marker_count" -gt 1 ]; then
      printf '%s: comment %s carries %s ruling marker lines, so which request it rules is ambiguous\n' \
        "$FM_OUTBOUND_TOKEN_AMBIGUOUS" "$comment" "$marker_count" >&2
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

# --- material universe: multipart publication --------------------------------
#
# bin/fm-outbound-artifact-lib.sh owns the contract - why the material block
# lives inside this record, what the three digests separate, and what EXACT
# versus DERIVATIVE means. This section owns only the mechanics that contract
# excludes: reading the declared universe off disk, building the deterministic
# payload, cutting it into parts, publishing them idempotently, reobserving them
# at the record's own venue, and the single completion transition.
#
# THE ONE RULE THAT IS EASY TO LOSE HERE. Every material command addresses the
# venue stored in the RECORD. config/sol-control.json seeds a venue at
# preparation and is never consulted again, because a generation is published
# across many calls and a config edit between two of them would retarget a
# half-published generation - parts on one issue, the rest on another, and a
# completion that reconstructs from neither.

MATERIAL_PART_BYTES="${FM_OUTBOUND_MATERIAL_PART_BYTES:-45600}"
MATERIAL_MAX_PARTS="${FM_OUTBOUND_MATERIAL_MAX_PARTS:-64}"

# base64's decode flag is spelled -d by GNU coreutils and -D by the BSD tool, so
# it is probed against a known vector rather than assumed. An undeterminable
# flag refuses: guessing it would decode nothing and report a reconstruction
# mismatch, blaming the remote for a local capability gap.
B64_DECODE_FLAG=
require_base64() {
  [ -z "$B64_DECODE_FLAG" ] || return 0
  command -v base64 >/dev/null 2>&1 || return 1
  if [ "$(printf 'YQ==' | base64 -d 2>/dev/null)" = a ]; then B64_DECODE_FLAG=-d; return 0; fi
  if [ "$(printf 'YQ==' | base64 -D 2>/dev/null)" = a ]; then B64_DECODE_FLAG=-D; return 0; fi
  return 1
}

# The prepared wire form, kept beside the record it belongs to. It is a
# CHECKPOINT and never an authority: it is content-addressed by the generation's
# subject digest and re-verified against it on every read, so a corrupted or
# swapped payload is could-not-observe rather than a silently different
# publication. Keeping it here is also what stops this from becoming a second
# state store - same directory, same owner, same lifetime as the record.
material_payload_path() { printf '%s/%s.g%s.payload\n' "$RECORD_DIR" "$1" "$2"; }

# Read the declared universe and resolve every entry against the bytes on disk.
#   0 resolved · 1 the manifest is unreadable or malformed
#   2 an entry's source could not be observed
material_resolve_manifest() {  # <manifest-file>
  local file=$1 raw rows row path class source authority digest bytes resolved
  [ -n "$file" ] && [ -r "$file" ] || return 1
  raw=$(cat "$file" 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -e --arg s "$FM_OUTBOUND_MATERIAL_MANIFEST_SCHEMA" \
    '.schema == $s and (.entries | type) == "array" and (.subject | type) == "string"' \
    >/dev/null 2>&1 || return 1
  rows=$(printf '%s' "$raw" | jq -r \
    '.entries[] | [(.path // ""), (.classification // ""), (.source // ""), (.authority // "")] | @base64') \
    || return 1
  resolved='[]'
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    path=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[0]') || return 1
    class=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[1]') || return 1
    source=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[2]') || return 1
    authority=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[3]') || return 1
    [ -n "$path" ] || return 1
    fm_outbound_material_class_valid "$class" || return 1
    # BOTH classes resolve real local bytes. A derivative entry transmits
    # nothing, but its digest is still an observation of an artifact that exists
    # rather than a value someone typed, which is what lets the universe be
    # counted rather than merely declared.
    [ -n "$source" ] && [ -r "$source" ] && [ -f "$source" ] || return 2
    digest=$(fm_outbound_sha256 < "$source") || return 2
    bytes=$(wc -c < "$source" | tr -d ' ') || return 2
    case $bytes in ''|*[!0-9]*) return 2 ;; esac
    resolved=$(printf '%s' "$resolved" | jq \
      --arg p "$path" --arg c "$class" --arg d "$digest" --argjson b "$bytes" \
      --arg a "$authority" --arg s "$source" \
      '. + [{path:$p,classification:$c,digest:$d,bytes:$b,
             authority:(if $a == "" then null else $a end),source:$s}]') || return 1
  done <<< "$rows"
  printf '%s' "$raw" | jq -c --argjson e "$resolved" '.entries = $e'
}

# The deterministic payload byte stream. Entries in path order, a fixed header
# per entry, and bytes ONLY for an EXACT entry - the classification made real on
# the wire rather than merely recorded next to it.
material_build_payload() {  # <resolved-manifest-json> <manifest-identity> <out-file>
  local manifest=$1 identity=$2 out=$3 rows row path class digest bytes authority source
  rows=$(printf '%s' "$manifest" | jq -r \
    '.entries | sort_by(.path)[]
     | [.path, .classification, .digest, (.bytes | tostring), (.authority // "-"), .source] | @base64') \
    || return 1
  {
    printf '%s\n' "$FM_OUTBOUND_MATERIAL_PAYLOAD_SCHEMA"
    printf 'manifest-identity=%s\n' "$identity"
    printf 'subject=%s\n' "$(printf '%s' "$manifest" | jq -r '.subject')"
    printf 'required-total=%s\n' "$(printf '%s' "$manifest" | jq -r '.required_total')"
    printf 'entry-count=%s\n' "$(printf '%s' "$manifest" | jq -r '.entries | length')"
  } > "$out" || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    path=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[0]') || return 1
    class=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[1]') || return 1
    digest=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[2]') || return 1
    bytes=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[3]') || return 1
    authority=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[4]') || return 1
    source=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[5]') || return 1
    printf 'entry %s class=%s digest=%s bytes=%s authority=%s\n' \
      "$path" "$class" "$digest" "$bytes" "$authority" >> "$out" || return 1
    if [ "$class" = EXACT ]; then
      cat "$source" >> "$out" || return 2
    fi
    printf '\n' >> "$out" || return 1
  done <<< "$rows"
}

# The wire form: one unbroken base64 line, so a part boundary is a byte offset
# rather than a line count and the same payload always cuts the same way.
material_build_wire() {  # <payload-file> <out-file>
  base64 < "$1" | tr -d '\n' > "$2"
}

material_wire_total() {  # <wire-file>
  local size
  size=$(wc -c < "$1" | tr -d ' ') || return 1
  case $size in ''|*[!0-9]*) return 1 ;; esac
  [ "$size" -gt 0 ] || return 1
  printf '%s\n' "$(( (size + MATERIAL_PART_BYTES - 1) / MATERIAL_PART_BYTES ))"
}

# One part's canonical chunk: its byte slice plus exactly one newline, so what
# the fence encloses and what the digest covers are the same bytes.
material_cut_chunk() {  # <wire-file> <index> <out-file>
  dd if="$1" bs="$MATERIAL_PART_BYTES" skip="$(($2 - 1))" count=1 > "$3" 2>/dev/null || return 1
  printf '\n' >> "$3"
}

# The record's venue, and only the record's. Prints repository<TAB>issue.
material_record_venue() {  # <record-json>
  local repo issue
  repo=$(printf '%s' "$1" | jq -r '.material.venue.repository // ""')
  issue=$(printf '%s' "$1" | jq -r \
    'if (.material.venue.issue // null) == null then "" else (.material.venue.issue | tostring) end')
  fm_outbound_venue_valid "$repo" "$issue" || return 1
  printf '%s\t%s\n' "$repo" "$issue"
}

# The venue's COMPLETE comment collection, or a could-not-observe.
#
# Completeness is PROVED rather than assumed. The issue object states how many
# comments it has, and a listing returning fewer than that is a truncated read -
# exactly the input that would otherwise let a missing part read as a part that
# was never posted. A listing with MORE is a comment added between the two
# reads, which is not truncation.
material_read_venue_comments() {  # <repository> <issue> <out-file>
  local repo=$1 issue=$2 out=$3 declared observed
  probe_budget || return 2
  # fm-retrieval-audit: not-a-collection - this reads one issue object named by repository and number for its own declared comment count.
  declared=$(obs gh api "repos/$repo/issues/$issue" --jq '.comments') || return 2
  case $declared in ''|*[!0-9]*) return 2 ;; esac
  probe_budget || return 2
  # fm-retrieval-audit: complete-source - --paginate traverses every page and the returned count is reconciled against the issue's own declared comment total immediately below.
  obs gh api "repos/$repo/issues/$issue/comments" --paginate \
    --jq '.[] | [.id, .body] | @base64' > "$out" || return 2
  observed=$(grep -c . < "$out" || true)
  case $observed in ''|*[!0-9]*) return 2 ;; esac
  [ "$observed" -ge "$declared" ] || return 2
  return 0
}

# Observe ONE part in an already-complete collection, writing its exact chunk.
#   0 present and exact (prints the comment id) · 1 provably absent
#   2 could not observe · 6 identity collision · 8 binding mismatch
#   9 the part's own digest does not cover its own bytes
#   10 addressed to a different venue
#
# The refusal ORDER is the fold's severity, not the order the comments happened
# to arrive in: a collision outranks a bad digest, which outranks a wrong venue,
# which outranks a mismatched binding, which outranks an unreadable body, which
# outranks a match. Reading them in arrival order would let one well-formed
# duplicate certify a part that another comment is actively contradicting.
material_observe_part() {  # <comments-file> <record-json> <index> <identity> <out-chunk>
  local comments=$1 rec=$2 index=$3 identity=$4 out=$5
  local row id body claimed chunk actual
  local found_id='' found_digest='' collision=0 unreadable=0 mismatch=0 digestbad=0 venuebad=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[0] | tostring' 2>/dev/null) \
      || { unreadable=1; continue; }
    body=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[1]' 2>/dev/null) \
      || { unreadable=1; continue; }
    # Only a comment CLAIMING this part identity is judged here. Everything else
    # in the venue is another request, another generation, or another fleet's
    # traffic, and none of it is evidence about this part.
    printf '%s\n' "$body" | grep -Fqx "$FM_OUTBOUND_MATERIAL_BODY_MARKER $identity" || continue
    if ! fm_outbound_material_part_venue_binds "$body" "$rec"; then
      venuebad=1; continue
    fi
    if ! fm_outbound_material_part_binds "$body" "$rec" "$index" "$identity"; then
      mismatch=1; continue
    fi
    claimed=$(fm_outbound_material_part_claimed_digest "$body") || { unreadable=1; continue; }
    chunk=$(fm_outbound_material_part_chunk "$body") || { unreadable=1; continue; }
    actual=$(printf '%s\n' "$chunk" | fm_outbound_sha256) || { unreadable=1; continue; }
    if [ "$claimed" != "$actual" ]; then digestbad=1; continue; fi
    if [ -n "$found_id" ] && [ "$found_digest" != "$actual" ]; then collision=1; continue; fi
    found_id=$id
    found_digest=$actual
    printf '%s\n' "$chunk" > "$out" || { unreadable=1; continue; }
  done < "$comments"
  [ "$collision" -eq 0 ] || return 6
  [ "$digestbad" -eq 0 ] || return 9
  [ "$venuebad" -eq 0 ] || return 10
  [ "$mismatch" -eq 0 ] || return 8
  [ "$unreadable" -eq 0 ] || return 2
  [ -n "$found_id" ] || return 1
  printf '%s\n' "$found_id"
}

# Reobserve an entire generation and prove it reconstructs the exact subject.
# Prints a report row per part on stderr-free stdout via the caller; returns:
#   0 every part exact and the reconstruction matches
#   3 a refusal that names a wrong part, generation, venue or duplicate
#   4 could not observe
#
# THE TWO CHECKS ARE NOT REDUNDANT. Per-part digests catch a part whose bytes
# changed under a stale claim; the reconstruction catches a part whose claim was
# updated to match its new bytes. An attacker who can edit a comment can do the
# second, and only the subject digest - computed before anything was published -
# refuses it.
MATERIAL_VERIFIED=
MATERIAL_VERIFY_REASON=
material_verify_generation() {  # <record-json> <comments-file> <work-dir>
  local rec=$1 comments=$2 work=$3
  local total subject rid gen index identity comment rc verified joined actual
  MATERIAL_VERIFIED=
  MATERIAL_VERIFY_REASON=
  total=$(printf '%s' "$rec" | jq -r '.material.parts.total')
  subject=$(printf '%s' "$rec" | jq -r '.material.generation.subject_digest')
  rid=$(printf '%s' "$rec" | jq -r '.request_id')
  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')
  case $total in ''|*[!0-9]*) MATERIAL_VERIFY_REASON=$FM_OUTBOUND_TOKEN_MATERIAL_ABSENT; return 4 ;; esac
  verified='{}'
  : > "$work/joined" || { MATERIAL_VERIFY_REASON=$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE; return 4; }
  index=1
  while [ "$index" -le "$total" ]; do
    identity=$(fm_outbound_part_identity "$rid" "$gen" "$subject" "$index" "$total") \
      || { MATERIAL_VERIFY_REASON=$FM_OUTBOUND_TOKEN_PART_UNREADABLE; return 4; }
    comment=$(material_observe_part "$comments" "$rec" "$index" "$identity" "$work/chunk"); rc=$?
    case $rc in
      0) : ;;
      1) MATERIAL_VERIFY_REASON="$FM_OUTBOUND_TOKEN_PART_MISSING part $index/$total"; return 3 ;;
      6) MATERIAL_VERIFY_REASON="$FM_OUTBOUND_TOKEN_IDENTITY_COLLISION part $index/$total"; return 3 ;;
      8) MATERIAL_VERIFY_REASON="$FM_OUTBOUND_TOKEN_GENERATION_MISMATCH part $index/$total"; return 3 ;;
      9) MATERIAL_VERIFY_REASON="$FM_OUTBOUND_TOKEN_RECONSTRUCTION part $index/$total does not cover its own bytes"; return 3 ;;
      10) MATERIAL_VERIFY_REASON="$FM_OUTBOUND_TOKEN_VENUE_MISMATCH part $index/$total is addressed to another venue"; return 3 ;;
      *) MATERIAL_VERIFY_REASON="$FM_OUTBOUND_TOKEN_PART_UNREADABLE part $index/$total"; return 4 ;;
    esac
    cat "$work/chunk" >> "$work/joined" \
      || { MATERIAL_VERIFY_REASON=$FM_OUTBOUND_TOKEN_PART_UNREADABLE; return 4; }
    verified=$(printf '%s' "$verified" | jq \
      --arg k "$index" --arg c "$comment" --arg d "$(fm_outbound_sha256 < "$work/chunk")" \
      '.[$k] = {comment_id:$c, part_digest:$d}') \
      || { MATERIAL_VERIFY_REASON=$FM_OUTBOUND_TOKEN_PART_UNREADABLE; return 4; }
    index=$((index + 1))
  done
  require_base64 || { MATERIAL_VERIFY_REASON=$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE; return 4; }
  joined="$work/reconstructed"
  tr -d '\n' < "$work/joined" | base64 "$B64_DECODE_FLAG" > "$joined" 2>/dev/null \
    || { MATERIAL_VERIFY_REASON="$FM_OUTBOUND_TOKEN_RECONSTRUCTION the reassembled parts did not decode"; return 3; }
  actual=$(fm_outbound_sha256 < "$joined") \
    || { MATERIAL_VERIFY_REASON=$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE; return 4; }
  if [ "$actual" != "$subject" ]; then
    MATERIAL_VERIFY_REASON="$FM_OUTBOUND_TOKEN_RECONSTRUCTION reassembled $actual, generation declares $subject"
    return 3
  fi
  MATERIAL_VERIFIED=$verified
  return 0
}

# The prepared wire form for a generation, re-proved against the record's own
# subject digest before a single byte of it is used.
material_require_wire() {  # <record-json> <work-dir> -> prints the wire path
  local rec=$1 work=$2 rid gen subject payload actual
  rid=$(printf '%s' "$rec" | jq -r '.request_id')
  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')
  subject=$(printf '%s' "$rec" | jq -r '.material.generation.subject_digest')
  payload=$(material_payload_path "$rid" "$gen")
  [ -r "$payload" ] || return 1
  actual=$(fm_outbound_sha256 < "$payload") || return 1
  [ "$actual" = "$subject" ] || return 1
  material_build_wire "$payload" "$work/wire" || return 1
  printf '%s\n' "$work/wire"
}

# Has the subject this generation was prepared from moved since?
#   0 unchanged · 1 moved · 2 could not observe
#
# "Moved" is asked of the RECORD's own bound head against the item's head now,
# reusing the applicability rule the single-comment path already owns. There is
# no second staleness rule here, and deliberately so: two rules for "is this
# still about the same thing" is how a laundered generation gets published.
material_subject_moved() {  # <record-json>
  local rec=$1 item project pr_url head_observation head
  item=$(printf '%s' "$rec" | jq -r '.identity.item // ""')
  [ -n "$item" ] || return 2
  read_snapshot || return 2
  require_unique_backlog_record "$item"
  project=$(printf '%s' "$BACKLOG_RECORD" | jq -r '.repo // ""')
  pr_url=$(printf '%s' "$BACKLOG_RECORD" | jq -r '.pr_url // ""')
  head_observation=$(observe_head "$item" "$pr_url" "$project")
  head=$(printf '%s' "$head_observation" | cut -f1)
  [ -n "$head" ] || return 2
  case "$(fm_outbound_applicability \
    "$(printf '%s' "$rec" | jq -r '.identity.head // ""')" "$head" \
    "$(printf '%s' "$rec" | jq -r '.state')")" in
    applicable) return 0 ;;
    inapplicable) return 1 ;;
    *) return 2 ;;
  esac
}

# Mark the CURRENT generation stale, preserving it exactly. Nothing about the
# generation's own evidence is touched: its published parts, its digests and its
# identities stay as they were, because a stale generation is a historical fact
# about what was published rather than a draft to be corrected.
material_mark_stale() {  # <request-id> <record-json> <reason>
  local rid=$1 rec=$2 reason=$3
  rec=$(printf '%s' "$rec" | jq --arg r "$reason" --arg n "$(now_iso)" \
    '.material.stale = {reason:$r, at:$n} | .updated = $n') || return 1
  record_write "$rid" "$rec"
}

material_require_record() {  # <request-id>; sets RECORD or exits
  require_record "$1"
  printf '%s' "$RECORD" | jq -e --arg s "$FM_OUTBOUND_MATERIAL_SCHEMA" \
    '.material.schema? == $s' >/dev/null 2>&1 || {
      printf '%s: request %s carries no material generation to act on\n' \
        "$FM_OUTBOUND_TOKEN_MATERIAL_ABSENT" "$1" >&2
      exit 3
    }
}

# Every computed axis, refused if it falls outside its declared vocabulary.
material_render_states() {  # <record-json>
  local rec=$1 pub next disp
  pub=$(fm_outbound_material_publication_state "$rec") || return 1
  next=$(fm_outbound_material_next_request_state "$rec") || return 1
  disp=$(fm_outbound_material_disposition_state "$rec") || return 1
  fm_outbound_material_lifecycle_valid "$FM_OUTBOUND_PUBLICATION_STATES" "$pub" || return 1
  fm_outbound_material_lifecycle_valid "$FM_OUTBOUND_NEXT_REQUEST_STATES" "$next" || return 1
  fm_outbound_material_lifecycle_valid "$FM_OUTBOUND_DISPOSITION_STATES" "$disp" || return 1
  printf '%s\t%s\t%s\n' "$pub" "$next" "$disp"
}

cmd_material_prepare() {  # <item> <manifest-file> <declared-venue>
  local item=$1 manifest_file=$2 declared_venue=$3
  local rec gate channel project pr_ref pr_url head_observation head head_source
  local venue_repo venue_issue venue_pair missing rid manifest resolve_rc
  local accounting verdict required classified exact derivative omitted duplicates
  local identity payload wire total index part_identity identities record material now
  local subject_digest record_rc

  read_snapshot || die "fleet backlog could not be read" 4
  require_unique_backlog_record "$item"
  rec=$BACKLOG_RECORD
  gate=$(classify_record "$rec" | cut -f2)
  channel=$(fm_outbound_gate_channel "$gate")
  if [ -z "$channel" ]; then
    printf '%s: %s has no typed gate, so no material generation can be bound to it\n' \
      "$FM_OUTBOUND_TOKEN_INCOMPLETE" "$item" >&2
    exit 3
  fi
  if ! fm_outbound_channel_can_emit "$channel"; then
    printf '%s: %s is on the %s channel, which this mechanism detects but never creates.\n' \
      "$FM_OUTBOUND_TOKEN_DETECT_ONLY" "$item" "$channel" >&2
    exit 3
  fi

  # The venue is bound HERE, once. An explicit --venue wins; otherwise the
  # configured default seeds it. Neither is consulted again for this record.
  if [ -n "$declared_venue" ]; then
    venue_pair=$(fm_outbound_venue_split "$declared_venue") || {
      printf '%s: --venue %s is not a <owner/name>#<positive-issue> venue\n' \
        "$FM_OUTBOUND_TOKEN_VENUE_INVALID" "$declared_venue" >&2
      exit 3
    }
  else
    read_sol_config || {
      printf '%s: no --venue was given and config/sol-control.json is absent or incomplete\n' \
        "$FM_OUTBOUND_TOKEN_UNCONFIGURED" >&2
      exit 4
    }
    venue_pair=$(fm_outbound_venue_split "$(fm_outbound_venue_canonical "$SOL_REPO" "$SOL_ISSUE")") || {
      printf '%s: the configured venue %s#%s is not addressable\n' \
        "$FM_OUTBOUND_TOKEN_VENUE_INVALID" "$SOL_REPO" "$SOL_ISSUE" >&2
      exit 3
    }
  fi
  venue_repo=$(printf '%s' "$venue_pair" | cut -f1)
  venue_issue=$(printf '%s' "$venue_pair" | cut -f2)

  project=$(printf '%s' "$rec" | jq -r '.repo // ""')
  pr_url=$(printf '%s' "$rec" | jq -r '.pr_url // ""')
  pr_ref=$(printf '%s' "$rec" | jq -r '.pr_url // "-"')
  head_observation=$(observe_head "$item" "$pr_url" "$project")
  head=$(printf '%s' "$head_observation" | cut -f1)
  head_source=$(printf '%s' "$head_observation" | cut -f2)
  missing=$(fm_outbound_binding_missing "$gate" "$project" "$venue_repo" "$item" "$head" "$PROJECTS/$project" "$head_source" || true)
  if [ -n "$missing" ]; then
    printf '%s: cannot bind a material generation for %s - missing %s\n' \
      "$FM_OUTBOUND_TOKEN_INCOMPLETE" "$item" \
      "$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')" >&2
    exit 3
  fi
  rid=$(fm_outbound_request_id "$gate" "$project" "$venue_repo" "$item" "$pr_ref" "$head") \
    || die "could not compute a request identity" 4

  manifest=$(material_resolve_manifest "$manifest_file"); resolve_rc=$?
  case $resolve_rc in
    0) : ;;
    2) printf '%s: an entry in %s names bytes that could not be read\n' \
         "$FM_OUTBOUND_TOKEN_MANIFEST_UNREADABLE" "$manifest_file" >&2
       exit 4 ;;
    *) printf '%s: %s is not a readable %s document\n' \
         "$FM_OUTBOUND_TOKEN_MANIFEST_UNREADABLE" "$manifest_file" \
         "$FM_OUTBOUND_MATERIAL_MANIFEST_SCHEMA" >&2
       exit 4 ;;
  esac

  accounting=$(fm_outbound_material_accounting "$manifest")
  required=$(printf '%s' "$accounting" | cut -f1)
  classified=$(printf '%s' "$accounting" | cut -f2)
  exact=$(printf '%s' "$accounting" | cut -f3)
  derivative=$(printf '%s' "$accounting" | cut -f4)
  omitted=$(printf '%s' "$accounting" | cut -f5)
  duplicates=$(printf '%s' "$accounting" | cut -f6)
  verdict=$(printf '%s' "$accounting" | cut -f7)
  case $verdict in
    complete) : ;;
    incomplete)
      printf '%s: %s declares %s required artifacts and classified %s (%s omitted, %s duplicated)\n' \
        "$FM_OUTBOUND_TOKEN_UNIVERSE_INCOMPLETE" "$manifest_file" \
        "$required" "$classified" "$omitted" "$duplicates" >&2
      exit 3 ;;
    *)
      printf '%s: the universe declared by %s could not be counted, so its completeness is unknown\n' \
        "$FM_OUTBOUND_TOKEN_UNIVERSE_UNCERTAIN" "$manifest_file" >&2
      exit 4 ;;
  esac

  identity=$(fm_outbound_material_canonical "$manifest" | fm_outbound_sha256) \
    || die "the manifest identity could not be computed" 4
  payload="$SCRATCH/payload"
  material_build_payload "$manifest" "$identity" "$payload" || {
    printf '%s: the declared universe could not be assembled into a payload\n' \
      "$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE" >&2
    exit 4
  }
  subject_digest=$(fm_outbound_sha256 < "$payload") \
    || die "the subject digest could not be computed" 4
  require_base64 || die "$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE: no usable base64 decoder was found" 4
  wire="$SCRATCH/wire"
  material_build_wire "$payload" "$wire" || die "the wire form could not be built" 4
  total=$(material_wire_total "$wire") || die "the part count could not be computed" 4
  if ! fm_outbound_material_total_valid "$total" "$MATERIAL_MAX_PARTS"; then
    printf '%s: this universe needs %s parts and the bound is %s\n' \
      "$FM_OUTBOUND_TOKEN_PART_BOUND" "$total" "$MATERIAL_MAX_PARTS" >&2
    exit 3
  fi

  mkdir -p "$RECORD_DIR" || die "cannot create $RECORD_DIR" 4
  if ! fm_lock_try_acquire "$RECORD_DIR/.$rid.lock"; then
    printf '%s: another emit for %s is already in flight\n' \
      "$FM_OUTBOUND_TOKEN_IN_FLIGHT" "$rid" >&2
    exit 3
  fi
  EMIT_LOCK="$RECORD_DIR/.$rid.lock"

  record=$(record_read "$rid"); record_rc=$?
  case $record_rc in
    0) : ;;
    1) record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$venue_repo" \
         "$item" "$pr_ref" "$head" \
         "$(fm_outbound_venue_canonical "$venue_repo" "$venue_issue")" "$(now_iso)" "$head_source") ;;
    5) die "$FM_OUTBOUND_TOKEN_IDENTITY: correlation record $rid belongs to another request" 3 ;;
    *) die "$FM_OUTBOUND_TOKEN_UNREADABLE: correlation record $rid could not be validated" 4 ;;
  esac

  # RE-PREPARING THE SAME SUBJECT IS A NO-OP, and re-preparing a DIFFERENT one
  # is refused rather than applied. That asymmetry is the whole successor rule:
  # an interrupted preparation must be safe to repeat, and a changed universe
  # must never be written over a generation that has already published parts
  # under the old one. The second case is what `material succeed` exists for.
  if printf '%s' "$record" | jq -e --arg s "$FM_OUTBOUND_MATERIAL_SCHEMA" \
    '.material.schema? == $s' >/dev/null 2>&1; then
    if printf '%s' "$record" | jq -e --arg m "$identity" --arg d "$subject_digest" \
      '.material.generation.manifest_identity == $m and .material.generation.subject_digest == $d' \
      >/dev/null 2>&1; then
      cp "$payload" "$(material_payload_path "$rid" \
        "$(printf '%s' "$record" | jq -r '.material.generation.artifact_generation')")" \
        || die "the prepared payload could not be checkpointed" 4
      record_write "$rid" "$record" || die "could not write the correlation record" 4
      printf 'already prepared: %s generation %s, %s part(s)\n' "$rid" \
        "$(printf '%s' "$record" | jq -r '.material.generation.artifact_generation')" \
        "$(printf '%s' "$record" | jq -r '.material.parts.total')"
      release_emit_lock
      return 0
    fi
    printf '%s: %s already carries generation %s for a different subject\n' \
      "$FM_OUTBOUND_TOKEN_SUBJECT_MOVED" "$rid" \
      "$(printf '%s' "$record" | jq -r '.material.generation.artifact_generation')" >&2
    printf 'A changed universe becomes an explicit successor generation, never an overwrite: open one with material succeed.\n' >&2
    exit 3
  fi

  identities='[]'
  index=1
  while [ "$index" -le "$total" ]; do
    part_identity=$(fm_outbound_part_identity "$rid" 1 "$subject_digest" "$index" "$total") \
      || die "a part identity could not be computed" 4
    identities=$(printf '%s' "$identities" | jq --arg i "$part_identity" '. + [$i]') \
      || die "the part identity list could not be built" 4
    index=$((index + 1))
  done

  now=$(now_iso)
  material=$(fm_outbound_material_new "$venue_repo" "$venue_issue" "$rid" 1 \
    "$identity" "$subject_digest" "$total" "$identities" \
    "$(jq -n --argjson r "$required" --argjson c "$classified" --argjson x "$exact" \
        --argjson d "$derivative" --argjson o "$omitted" --argjson u "$duplicates" \
        --arg v "$verdict" \
        '{required:$r,classified:$c,exact:$x,derivative:$d,omitted:$o,duplicates:$u,verdict:$v}')" \
    "$now") || die "the material generation could not be built" 4
  record=$(printf '%s' "$record" | jq --argjson m "$material" --arg n "$now" \
    '.material = $m | .updated = $n') || die "the record could not be extended" 4
  cp "$payload" "$(material_payload_path "$rid" 1)" \
    || die "the prepared payload could not be checkpointed" 4
  record_write "$rid" "$record" || die "could not write the correlation record" 4
  printf 'prepared: %s generation 1 for %s#%s - %s part(s), %s exact, %s derivative, %s required\n' \
    "$rid" "$venue_repo" "$venue_issue" "$total" "$exact" "$derivative" "$required"
  release_emit_lock
}

cmd_material_emit() {  # <request-id>
  local rid=$1 rec venue_pair venue_repo venue_issue comments rc wire total subject gen
  local index identity comment attempt delay body posted=0 adopted=0 moved_rc

  material_require_record "$rid"; rec=$RECORD
  case "$(fm_outbound_material_publication_state "$rec")" in
    TERMINAL)
      printf '%s: request %s is closed or superseded; its generation is history\n' \
        "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" >&2
      exit 3 ;;
    STALE)
      printf '%s: generation %s of %s is stale; publish its successor, never more of it\n' \
        "$FM_OUTBOUND_TOKEN_SUBJECT_MOVED" \
        "$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')" "$rid" >&2
      exit 3 ;;
    COMPLETE_VERIFIED)
      printf 'already complete: %s generation %s needs no further parts\n' "$rid" \
        "$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')"
      return 0 ;;
  esac

  # THE SUBJECT IS RECHECKED BEFORE ANY BYTE IS ADDED, not only before
  # completion. Publishing one more part of a generation whose subject has
  # already moved manufactures evidence about a head nobody is asking about, and
  # it does so under an identity that still looks current.
  material_subject_moved "$rec"; moved_rc=$?
  case $moved_rc in
    0) : ;;
    1) material_mark_stale "$rid" "$rec" "the bound head moved before this generation finished publishing" \
         || die "could not record that generation went stale" 4
       printf '%s: the head %s was bound to has moved; generation %s is now stale\n' \
         "$FM_OUTBOUND_TOKEN_SUBJECT_MOVED" "$rid" \
         "$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')" >&2
       exit 3 ;;
    *) printf '%s: whether %s still describes its subject could not be observed; refusing to publish more of it\n' \
         "$FM_OUTBOUND_TOKEN_HEAD_UNOBSERVED" "$rid" >&2
       exit 4 ;;
  esac

  venue_pair=$(material_record_venue "$rec") || {
    printf '%s: the venue recorded for %s is not addressable\n' \
      "$FM_OUTBOUND_TOKEN_VENUE_INVALID" "$rid" >&2
    exit 3
  }
  venue_repo=$(printf '%s' "$venue_pair" | cut -f1)
  venue_issue=$(printf '%s' "$venue_pair" | cut -f2)

  require_base64 || die "$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE: no usable base64 decoder was found" 4
  wire=$(material_require_wire "$rec" "$SCRATCH") || {
    printf '%s: the prepared payload for %s is absent or no longer digests to its own generation\n' \
      "$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE" "$rid" >&2
    printf 'Re-run material prepare with the same manifest; the same universe produces the same bytes.\n' >&2
    exit 4
  }

  if ! fm_lock_try_acquire "$RECORD_DIR/.$rid.lock"; then
    printf '%s: another emit for %s is already in flight\n' \
      "$FM_OUTBOUND_TOKEN_IN_FLIGHT" "$rid" >&2
    exit 3
  fi
  EMIT_LOCK="$RECORD_DIR/.$rid.lock"

  total=$(printf '%s' "$rec" | jq -r '.material.parts.total')
  subject=$(printf '%s' "$rec" | jq -r '.material.generation.subject_digest')
  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')
  comments="$SCRATCH/venue-comments"
  material_read_venue_comments "$venue_repo" "$venue_issue" "$comments"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: the complete comment collection of %s#%s could not be read, so no part is provably absent\n' \
      "$FM_OUTBOUND_TOKEN_COLLECTION_TRUNCATED" "$venue_repo" "$venue_issue" >&2
    exit 4
  fi

  index=1
  while [ "$index" -le "$total" ]; do
    identity=$(fm_outbound_part_identity "$rid" "$gen" "$subject" "$index" "$total") \
      || die "a part identity could not be computed" 4
    comment=$(material_observe_part "$comments" "$rec" "$index" "$identity" "$SCRATCH/observed"); rc=$?
    case $rc in
      0)
        # ALREADY PUBLISHED AND EXACT. This is both ordinary duplicate
        # suppression and the resume path, because they are the same question,
        # and it is why an interrupted publication costs one reobservation
        # rather than a second copy of every part already on the venue.
        rec=$(printf '%s' "$rec" | jq --arg k "$index" --arg c "$comment" --arg n "$(now_iso)" \
          '.material.parts.published[$k] = $c | .updated = $n') \
          || die "the published part could not be recorded" 4
        record_write "$rid" "$rec" || die "could not write the correlation record" 4
        adopted=$((adopted + 1))
        index=$((index + 1))
        continue ;;
      1) : ;;
      6) die "$FM_OUTBOUND_TOKEN_IDENTITY_COLLISION: two comments claim part $index/$total of $rid with different bytes" 3 ;;
      8) die "$FM_OUTBOUND_TOKEN_GENERATION_MISMATCH: a comment claims part $index/$total of $rid but binds a different generation" 3 ;;
      9) die "$FM_OUTBOUND_TOKEN_RECONSTRUCTION: part $index/$total of $rid does not cover its own bytes" 3 ;;
      10) die "$FM_OUTBOUND_TOKEN_VENUE_MISMATCH: a comment claims part $index/$total of $rid but is addressed to another venue" 3 ;;
      *) die "$FM_OUTBOUND_TOKEN_PART_UNREADABLE: part $index/$total of $rid could not be observed; refusing to post over it" 4 ;;
    esac

    material_cut_chunk "$wire" "$index" "$SCRATCH/chunk" \
      || die "$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE: part $index could not be cut from the prepared payload" 4
    body=$(fm_outbound_material_part_body "$rec" "$index" "$identity" \
      "$(fm_outbound_sha256 < "$SCRATCH/chunk")" "$SCRATCH/chunk") \
      || die "part $index could not be rendered" 4

    attempt=0
    delay=$BACKOFF_BASE
    while [ "$attempt" -lt "$ATTEMPTS" ]; do
      attempt=$((attempt + 1))
      # fm-retrieval-audit: write - this creates a comment and draws no conclusion from a collection read.
      if jq -n --arg b "$body" '{body:$b}' | obs gh api \
        "repos/$venue_repo/issues/$venue_issue/comments" --input - >/dev/null; then
        break
      fi
      # A failed transport response is not a failed post. Reobserve before
      # retrying, exactly as the single-comment path does, so an accepted
      # comment whose response was lost is adopted instead of duplicated.
      material_read_venue_comments "$venue_repo" "$venue_issue" "$comments" \
        || die "$FM_OUTBOUND_TOKEN_PART_UNREADABLE: part $index presence could not be reobserved after a transport failure" 4
      if material_observe_part "$comments" "$rec" "$index" "$identity" "$SCRATCH/observed" >/dev/null; then
        break
      fi
      [ "$attempt" -lt "$ATTEMPTS" ] || \
        die "$FM_OUTBOUND_TOKEN_PART_MISSING: part $index/$total of $rid was not accepted after $ATTEMPTS attempts; every earlier part stays published" 4
      case $delay in ''|*[!0-9]*) delay=0 ;; esac
      if [ "$delay" -gt 0 ]; then sleep "$delay"; delay=$((delay * 2)); fi
    done

    material_read_venue_comments "$venue_repo" "$venue_issue" "$comments" \
      || die "$FM_OUTBOUND_TOKEN_PART_UNREADABLE: part $index could not be confirmed after posting" 4
    comment=$(material_observe_part "$comments" "$rec" "$index" "$identity" "$SCRATCH/observed"); rc=$?
    [ "$rc" -eq 0 ] || \
      die "$FM_OUTBOUND_TOKEN_PART_MISSING: part $index/$total of $rid was posted but could not be reobserved" 4
    rec=$(printf '%s' "$rec" | jq --arg k "$index" --arg c "$comment" --arg n "$(now_iso)" \
      '.material.parts.published[$k] = $c | .updated = $n') \
      || die "the published part could not be recorded" 4
    # CHECKPOINT PER PART, not per run. An interruption after part 7 of 9 must
    # cost two parts, not nine.
    record_write "$rid" "$rec" || die "could not write the correlation record" 4
    posted=$((posted + 1))
    index=$((index + 1))
  done

  printf 'published: %s generation %s on %s#%s - %s part(s) posted, %s already exact\n' \
    "$rid" "$gen" "$venue_repo" "$venue_issue" "$posted" "$adopted"
  release_emit_lock
}

cmd_material_verify() {  # <request-id> <json>
  local rid=$1 json=$2 rec venue_pair venue_repo venue_issue comments rc gen states
  material_require_record "$rid"; rec=$RECORD
  venue_pair=$(material_record_venue "$rec") || {
    printf '%s: the venue recorded for %s is not addressable\n' \
      "$FM_OUTBOUND_TOKEN_VENUE_INVALID" "$rid" >&2
    exit 3
  }
  venue_repo=$(printf '%s' "$venue_pair" | cut -f1)
  venue_issue=$(printf '%s' "$venue_pair" | cut -f2)
  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')
  comments="$SCRATCH/venue-comments"
  material_read_venue_comments "$venue_repo" "$venue_issue" "$comments"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: the complete comment collection of %s#%s could not be read, so this generation is NOT reported complete\n' \
      "$FM_OUTBOUND_TOKEN_COLLECTION_TRUNCATED" "$venue_repo" "$venue_issue" >&2
    exit 4
  fi
  material_verify_generation "$rec" "$comments" "$SCRATCH"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$MATERIAL_VERIFY_REASON" >&2
    printf 'Generation %s of %s is NOT complete and no transition follows from it.\n' "$gen" "$rid" >&2
    exit "$rc"
  fi
  rec=$(printf '%s' "$rec" | jq --argjson v "$MATERIAL_VERIFIED" --arg n "$(now_iso)" \
    '.material.parts.verified = $v | .updated = $n') \
    || die "the verification result could not be recorded" 4
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  if [ "$json" = 1 ]; then
    printf '%s' "$rec" | jq '.material'
    return 0
  fi
  states=$(material_render_states "$rec") || die "a computed lifecycle value fell outside its declared vocabulary" 4
  printf '%s: %s generation %s reconstructed the exact subject %s from %s part(s) at %s#%s\n' \
    "$FM_OUTBOUND_TOKEN_MATERIAL_COMPLETE" "$rid" "$gen" \
    "$(printf '%s' "$rec" | jq -r '.material.generation.subject_digest')" \
    "$(printf '%s' "$rec" | jq -r '.material.parts.total')" "$venue_repo" "$venue_issue"
  printf '  publication: %s · next request: %s · correlation: %s\n' \
    "$(printf '%s' "$states" | cut -f1)" \
    "$(printf '%s' "$states" | cut -f2)" \
    "$(printf '%s' "$states" | cut -f3)"
}

# THE COMPLETION TRANSITION, AND THE ONLY ONE.
#
# Completion is reached by evidence rather than by arriving here: the generation
# is reobserved and reconstructed inside this call, and the successor request is
# emitted by THAT result rather than by the shell reaching the next line. That is
# the difference the contract asks for - a publication that is complete because
# its bytes were proven, not because a script ran to the end.
cmd_material_complete() {  # <request-id>
  local rid=$1 rec venue_pair venue_repo venue_issue comments rc gen moved_rc
  local body found now
  material_require_record "$rid"; rec=$RECORD

  case "$(fm_outbound_material_publication_state "$rec")" in
    COMPLETE_VERIFIED)
      # EXACTLY ONE TRANSITION. A second call is refused rather than treated as
      # a repeat, because the transition has an outward effect and "do it again
      # if it already happened" is how one request becomes two.
      printf '%s: generation %s of %s already completed at %s\n' \
        "$FM_OUTBOUND_TOKEN_ALREADY_COMPLETE" \
        "$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')" "$rid" \
        "$(printf '%s' "$rec" | jq -r '.material.completed.at')" >&2
      exit 3 ;;
    TERMINAL)
      printf '%s: request %s is closed or superseded and cannot complete a generation\n' \
        "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" >&2
      exit 3 ;;
    STALE)
      printf '%s: generation %s of %s is stale and can never complete; its successor must\n' \
        "$FM_OUTBOUND_TOKEN_SUBJECT_MOVED" \
        "$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')" "$rid" >&2
      exit 3 ;;
  esac

  material_subject_moved "$rec"; moved_rc=$?
  case $moved_rc in
    0) : ;;
    1) material_mark_stale "$rid" "$rec" "the bound head moved before this generation completed" \
         || die "could not record that generation went stale" 4
       printf '%s: the head %s was bound to moved before completion; the generation is stale and no request follows it\n' \
         "$FM_OUTBOUND_TOKEN_SUBJECT_MOVED" "$rid" >&2
       exit 3 ;;
    *) printf '%s: whether %s still describes its subject could not be observed; refusing to complete it\n' \
         "$FM_OUTBOUND_TOKEN_HEAD_UNOBSERVED" "$rid" >&2
       exit 4 ;;
  esac

  venue_pair=$(material_record_venue "$rec") || {
    printf '%s: the venue recorded for %s is not addressable\n' \
      "$FM_OUTBOUND_TOKEN_VENUE_INVALID" "$rid" >&2
    exit 3
  }
  venue_repo=$(printf '%s' "$venue_pair" | cut -f1)
  venue_issue=$(printf '%s' "$venue_pair" | cut -f2)
  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')

  if ! fm_lock_try_acquire "$RECORD_DIR/.$rid.lock"; then
    printf '%s: another emit for %s is already in flight\n' \
      "$FM_OUTBOUND_TOKEN_IN_FLIGHT" "$rid" >&2
    exit 3
  fi
  EMIT_LOCK="$RECORD_DIR/.$rid.lock"

  comments="$SCRATCH/venue-comments"
  material_read_venue_comments "$venue_repo" "$venue_issue" "$comments"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: the complete comment collection of %s#%s could not be read, so completeness is unknown and completion is refused\n' \
      "$FM_OUTBOUND_TOKEN_COLLECTION_TRUNCATED" "$venue_repo" "$venue_issue" >&2
    exit 4
  fi
  # THE SAME FOLD `verify` USES. Not a second, lighter check that happens to run
  # at completion: one owner for "is this generation exact", so completion can
  # never accept what verification would refuse.
  material_verify_generation "$rec" "$comments" "$SCRATCH"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$MATERIAL_VERIFY_REASON" >&2
    printf 'Generation %s of %s is not complete, so no successor request is emitted.\n' "$gen" "$rid" >&2
    exit "$rc"
  fi

  now=$(now_iso)
  rec=$(printf '%s' "$rec" | jq --argjson v "$MATERIAL_VERIFIED" --arg n "$now" \
    '.material.parts.verified = $v
     | .material.completed = {at:$n, parts:(.material.parts.total)}
     | .updated = $n') || die "completion could not be recorded" 4
  # CHECKPOINT BEFORE THE OUTWARD EFFECT, the same order the single-comment emit
  # uses: a process killed between here and the post leaves durable evidence that
  # a successor may be in flight, and the adoption below reads the venue rather
  # than guessing from it.
  record_write "$rid" "$rec" || die "could not write the correlation record" 4

  body=$(fm_outbound_material_next_request_body "$rec") \
    || die "the successor request could not be rendered" 4
  found=$(sol_material_next_present "$comments" "$rid"); rc=$?
  if [ "$rc" -ne 0 ]; then
    # fm-retrieval-audit: write - this creates a comment and draws no conclusion from a collection read.
    jq -n --arg b "$body" '{body:$b}' | obs gh api \
      "repos/$venue_repo/issues/$venue_issue/comments" --input - >/dev/null \
      || die "$FM_OUTBOUND_TOKEN_ARTIFACT_UNOBSERVED: the successor request for $rid was not accepted; the generation stays complete and the transition stays untaken" 4
    material_read_venue_comments "$venue_repo" "$venue_issue" "$comments" \
      || die "$FM_OUTBOUND_TOKEN_ARTIFACT_UNOBSERVED: the successor request for $rid could not be confirmed" 4
    found=$(sol_material_next_present "$comments" "$rid") \
      || die "$FM_OUTBOUND_TOKEN_ARTIFACT_UNOBSERVED: the successor request for $rid was posted but could not be reobserved" 4
  fi
  rec=$(printf '%s' "$rec" | jq --arg c "$found" --arg n "$(now_iso)" \
    '.material.next_request = {comment_id:$c, at:$n}
     | .comment_id = (.comment_id // $c)
     | .state = (if .state == "emitting" then "emitted" else .state end)
     | .updated = $n') || die "the successor request could not be recorded" 4
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'complete: %s generation %s verified at %s#%s; successor request is comment %s\n' \
    "$rid" "$gen" "$venue_repo" "$venue_issue" "$found"
  release_emit_lock
}

# The successor request in an already-complete collection, matched on the
# request marker the single-comment path already owns.
sol_material_next_present() {  # <comments-file> <request-id>
  local comments=$1 rid=$2 row id body
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[0] | tostring' 2>/dev/null) || continue
    body=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[1]' 2>/dev/null) || continue
    printf '%s\n' "$body" | grep -Fqx "$FM_OUTBOUND_BODY_MARKER $rid" || continue
    printf '%s\n' "$id"
    return 0
  done < "$comments"
  return 1
}

# ONE EXPLICIT SUCCESSOR, AFTER A RECHECK, AND NEVER A REWRITE.
#
# The prior generation is pushed into history exactly as it stands - its parts,
# its comment ids, its digests, its staleness reason - and the successor starts
# clean at generation+1. Nothing about what was already published is edited,
# because the published parts are a true record of what a reviewer was shown and
# a corrected copy of that record would be a lie about the past.
cmd_material_succeed() {  # <request-id> <manifest-file>
  local rid=$1 manifest_file=$2 rec manifest resolve_rc accounting verdict
  local required classified exact derivative omitted duplicates identity payload
  local subject_digest wire total index part_identity identities gen next_gen now material
  material_require_record "$rid"; rec=$RECORD

  if [ "$(fm_outbound_material_publication_state "$rec")" != STALE ]; then
    printf '%s: generation %s of %s is not stale, so it has no successor to open\n' \
      "$FM_OUTBOUND_TOKEN_NOT_STALE" \
      "$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')" "$rid" >&2
    printf 'A successor is how a MOVED subject is republished; it is never a way to replace a generation that still stands.\n' >&2
    exit 3
  fi

  manifest=$(material_resolve_manifest "$manifest_file"); resolve_rc=$?
  case $resolve_rc in
    0) : ;;
    2) printf '%s: an entry in %s names bytes that could not be read\n' \
         "$FM_OUTBOUND_TOKEN_MANIFEST_UNREADABLE" "$manifest_file" >&2
       exit 4 ;;
    *) printf '%s: %s is not a readable %s document\n' \
         "$FM_OUTBOUND_TOKEN_MANIFEST_UNREADABLE" "$manifest_file" \
         "$FM_OUTBOUND_MATERIAL_MANIFEST_SCHEMA" >&2
       exit 4 ;;
  esac

  accounting=$(fm_outbound_material_accounting "$manifest")
  required=$(printf '%s' "$accounting" | cut -f1)
  classified=$(printf '%s' "$accounting" | cut -f2)
  exact=$(printf '%s' "$accounting" | cut -f3)
  derivative=$(printf '%s' "$accounting" | cut -f4)
  omitted=$(printf '%s' "$accounting" | cut -f5)
  duplicates=$(printf '%s' "$accounting" | cut -f6)
  verdict=$(printf '%s' "$accounting" | cut -f7)
  case $verdict in
    complete) : ;;
    incomplete)
      printf '%s: the successor universe declares %s required artifacts and classified %s (%s omitted, %s duplicated)\n' \
        "$FM_OUTBOUND_TOKEN_UNIVERSE_INCOMPLETE" "$required" "$classified" "$omitted" "$duplicates" >&2
      exit 3 ;;
    *)
      printf '%s: the successor universe could not be counted, so its completeness is unknown\n' \
        "$FM_OUTBOUND_TOKEN_UNIVERSE_UNCERTAIN" >&2
      exit 4 ;;
  esac

  identity=$(fm_outbound_material_canonical "$manifest" | fm_outbound_sha256) \
    || die "the manifest identity could not be computed" 4
  payload="$SCRATCH/payload"
  material_build_payload "$manifest" "$identity" "$payload" || {
    printf '%s: the successor universe could not be assembled into a payload\n' \
      "$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE" >&2
    exit 4
  }
  subject_digest=$(fm_outbound_sha256 < "$payload") \
    || die "the successor subject digest could not be computed" 4
  require_base64 || die "$FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE: no usable base64 decoder was found" 4
  wire="$SCRATCH/wire"
  material_build_wire "$payload" "$wire" || die "the wire form could not be built" 4
  total=$(material_wire_total "$wire") || die "the part count could not be computed" 4
  if ! fm_outbound_material_total_valid "$total" "$MATERIAL_MAX_PARTS"; then
    printf '%s: the successor universe needs %s parts and the bound is %s\n' \
      "$FM_OUTBOUND_TOKEN_PART_BOUND" "$total" "$MATERIAL_MAX_PARTS" >&2
    exit 3
  fi

  if ! fm_lock_try_acquire "$RECORD_DIR/.$rid.lock"; then
    printf '%s: another emit for %s is already in flight\n' \
      "$FM_OUTBOUND_TOKEN_IN_FLIGHT" "$rid" >&2
    exit 3
  fi
  EMIT_LOCK="$RECORD_DIR/.$rid.lock"

  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')
  case $gen in ''|*[!0-9]*) die "the current generation could not be read" 4 ;; esac
  next_gen=$((gen + 1))

  identities='[]'
  index=1
  while [ "$index" -le "$total" ]; do
    part_identity=$(fm_outbound_part_identity "$rid" "$next_gen" "$subject_digest" "$index" "$total") \
      || die "a successor part identity could not be computed" 4
    identities=$(printf '%s' "$identities" | jq --arg i "$part_identity" '. + [$i]') \
      || die "the successor part identity list could not be built" 4
    index=$((index + 1))
  done

  now=$(now_iso)
  material=$(fm_outbound_material_new \
    "$(printf '%s' "$rec" | jq -r '.material.venue.repository')" \
    "$(printf '%s' "$rec" | jq -r '.material.venue.issue')" \
    "$rid" "$next_gen" "$identity" "$subject_digest" "$total" "$identities" \
    "$(jq -n --argjson r "$required" --argjson c "$classified" --argjson x "$exact" \
        --argjson d "$derivative" --argjson o "$omitted" --argjson u "$duplicates" \
        --arg v "$verdict" \
        '{required:$r,classified:$c,exact:$x,derivative:$d,omitted:$o,duplicates:$u,verdict:$v}')" \
    "$now") || die "the successor generation could not be built" 4
  # The prior generation moves into history VERBATIM, with its own history
  # dropped so the list stays flat rather than nesting each ancestor inside the
  # next. Nothing else about it is touched.
  rec=$(printf '%s' "$rec" | jq --argjson m "$material" --arg n "$now" \
    '.material as $prior
     | .material = ($m | .history = ($prior.history + [$prior | del(.history)]))
     | .updated = $n') || die "the successor could not be recorded" 4
  cp "$payload" "$(material_payload_path "$rid" "$next_gen")" \
    || die "the successor payload could not be checkpointed" 4
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'succeeded: %s generation %s opened after generation %s went stale - %s part(s), %s exact, %s derivative\n' \
    "$rid" "$next_gen" "$gen" "$total" "$exact" "$derivative"
  release_emit_lock
}

# Material visibility, queryable from the owner that already holds it. Reading
# is not verification and says so: every count here is what the RECORD holds,
# and only `material verify` reobserves the venue.
cmd_material_show() {  # <request-id> <json>
  local rid=$1 json=$2 rec states published verified
  material_require_record "$rid"; rec=$RECORD
  if [ "$json" = 1 ]; then
    states=$(material_render_states "$rec") || die "a computed lifecycle value fell outside its declared vocabulary" 4
    printf '%s' "$rec" | jq --arg p "$(printf '%s' "$states" | cut -f1)" \
      --arg n "$(printf '%s' "$states" | cut -f2)" \
      --arg d "$(printf '%s' "$states" | cut -f3)" \
      '.material + {publication_state:$p, next_request_state:$n, disposition_state:$d}'
    return 0
  fi
  states=$(material_render_states "$rec") || die "a computed lifecycle value fell outside its declared vocabulary" 4
  published=$(printf '%s' "$rec" | jq -r '.material.parts.published | length')
  verified=$(printf '%s' "$rec" | jq -r '.material.parts.verified | length')
  printf '%s\n' "$rid"
  printf '  item: %s · head: %s\n' \
    "$(printf '%s' "$rec" | jq -r '.identity.item')" \
    "$(printf '%s' "$rec" | jq -r '.identity.head')"
  printf '  venue: %s#%s\n' \
    "$(printf '%s' "$rec" | jq -r '.material.venue.repository')" \
    "$(printf '%s' "$rec" | jq -r '.material.venue.issue')"
  printf '  generation: %s · manifest: %s · subject: %s\n' \
    "$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')" \
    "$(printf '%s' "$rec" | jq -r '.material.generation.manifest_identity')" \
    "$(printf '%s' "$rec" | jq -r '.material.generation.subject_digest')"
  printf '  parts: %s total · %s published · %s verified (record state, not a reobservation)\n' \
    "$(printf '%s' "$rec" | jq -r '.material.parts.total')" "$published" "$verified"
  printf '  universe: %s required · %s exact · %s derivative · %s omitted · %s duplicated · %s\n' \
    "$(printf '%s' "$rec" | jq -r '.material.accounting.required')" \
    "$(printf '%s' "$rec" | jq -r '.material.accounting.exact')" \
    "$(printf '%s' "$rec" | jq -r '.material.accounting.derivative')" \
    "$(printf '%s' "$rec" | jq -r '.material.accounting.omitted')" \
    "$(printf '%s' "$rec" | jq -r '.material.accounting.duplicates')" \
    "$(printf '%s' "$rec" | jq -r '.material.accounting.verdict')"
  printf '  publication: %s · next request: %s · correlation: %s\n' \
    "$(printf '%s' "$states" | cut -f1)" \
    "$(printf '%s' "$states" | cut -f2)" \
    "$(printf '%s' "$states" | cut -f3)"
  printf '  superseded generations: %s\n' \
    "$(printf '%s' "$rec" | jq -r '.material.history | length')"
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
    # The selected rows are read from a FILE rather than from the end of a
    # pipeline. A pipeline stage is a subshell whose status has to be recovered
    # by position from PIPESTATUS, which silently credits the wrong stage the
    # moment a stage is added - and did: index 1 named jq, not the loop, so
    # every emit refusal was discarded and reported as whatever the next sweep
    # happened to say.
    RECONCILE_ITEMS="$SCRATCH/reconcile-items"
    printf '%s' "$SWEEP" | jq -r '.rows[] | select(.verdict=="defect" and .channel=="sol-control" and .missing==null) | .item' \
      > "$RECONCILE_ITEMS" || die "the sweep rows could not be read for reconciliation" 4
    probe_budget_reset
    EMIT_RC=0
    while IFS= read -r ITEM; do
      [ -n "$ITEM" ] || continue
      # THIS LINE THREADS BETWEEN TWO HAZARDS THAT HAVE BOTH ALREADY BITTEN.
      #
      # It must not become `cmd_emit ... || exit $?`, and it must not rely on
      # cmd_emit exiting the shell by itself either. Both are the same early
      # exit, and the report below sits AFTER this loop: one item's refusal
      # would take every other item's defect line with it, and at status 3
      # bin/fm-bootstrap.sh prints no line of its own, so session start would
      # show an un-prefixed reason and no OUTBOUND: token at all.
      #
      # It must also not leak the per-request lock. cmd_emit releases the lock
      # on its own success paths, but its refusals exit, and a status can only
      # be captured here by running it in a subshell - where the parent's EXIT
      # trap does not fire and the parent can no longer see EMIT_LOCK. The
      # subshell therefore carries its own release trap.
      #
      # So: subshell for an EXPLICIT status at this line, own trap for the lock,
      # accumulator instead of control flow for the refusal.
      #
      # THE FORMATTING IS LOAD-BEARING. bin/fm-dead-predicate-check.sh reads call
      # sites by anchored syntax, and its trap rule anchors `trap` to the start
      # of a line. Written as `( trap release_emit_lock EXIT; cmd_emit ... )` the
      # `(` precedes `trap`, this whole file becomes an UNCHECKED consumer, and
      # every predicate whose only call site lives here goes could-not-observe.
      # The one-statement-per-line form below is the shape the other 121 traps in
      # bin/ already use; keep it.
      (
        trap release_emit_lock EXIT
        cmd_emit "$ITEM" "" 0
      )
      ITEM_RC=$?
      EMIT_RC=$(outbound_worst_status "$EMIT_RC" "$ITEM_RC")
    done < "$RECONCILE_ITEMS"
    # cmd_emit's refusals are un-prefixed by design - they name a token, not a
    # relay. bin/fm-bootstrap.sh and the bootstrap-diagnostics skill both key on
    # the OUTBOUND: prefix, so a refusal that never produced one would be a
    # refusal no handling procedure is loaded for.
    [ "$EMIT_RC" -eq 0 ] || printf 'OUTBOUND: reconciliation refused an emit (status %s) - its named reason is printed above, and the sweep below still reports every other item\n' "$EMIT_RC"
    sweep || true
    render_defects
    sweep_exit; SWEEP_RC=$?
    exit "$(outbound_worst_status "$(outbound_worst_status "$POLL_RC" "$EMIT_RC")" "$SWEEP_RC")"
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
  material)
    [ $# -gt 0 ] || die "material needs a subcommand"
    SUB=$1; shift
    RID=; ITEM=; MANIFEST=; VENUE=; MJSON=0
    while [ $# -gt 0 ]; do
      case $1 in
        --request) RID=${2:-}; shift 2 ;;
        --manifest) MANIFEST=${2:-}; shift 2 ;;
        --venue) VENUE=${2:-}; shift 2 ;;
        --json) MJSON=1; shift ;;
        -*) die "unknown option '$1'" ;;
        *) ITEM=$1; shift ;;
      esac
    done
    case $SUB in
      prepare)
        [ -n "$ITEM" ] || die "material prepare needs an item id"
        [ -n "$MANIFEST" ] || die "material prepare needs --manifest"
        cmd_material_prepare "$ITEM" "$MANIFEST" "$VENUE"
        ;;
      emit)
        [ -n "$RID" ] || die "material emit needs --request"
        cmd_material_emit "$RID"
        ;;
      verify)
        [ -n "$RID" ] || die "material verify needs --request"
        cmd_material_verify "$RID" "$MJSON"
        ;;
      complete)
        [ -n "$RID" ] || die "material complete needs --request"
        cmd_material_complete "$RID"
        ;;
      succeed)
        [ -n "$RID" ] || die "material succeed needs --request"
        [ -n "$MANIFEST" ] || die "material succeed needs --manifest"
        cmd_material_succeed "$RID" "$MANIFEST"
        ;;
      show)
        [ -n "$RID" ] || RID=$ITEM
        [ -n "$RID" ] || die "material show needs a request id"
        cmd_material_show "$RID" "$MJSON"
        ;;
      *) die "unknown material subcommand '$SUB'" ;;
    esac
    ;;
  *) die "unknown command '$CMD'" ;;
esac
