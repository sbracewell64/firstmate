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
#                                 [--authorization <id> --target-ref <ref>
#                                  --target-generation <sha>]
#       Complete the correlation with the outcome. When a landing authorization
#       was minted for this request, closure MUST name it and the generation the
#       effect produced: the authority is checked to have been spent for this
#       exact request and head, and the target ref is READ AGAIN in the governed
#       clone and bound into the record at the generation it is actually at. A
#       disposition sentence alone would record a landing nobody observed.
#   fm-outbound-artifact.sh correct --request <id>
#       Retire a request whose ruling demanded a corrected candidate. The record
#       is preserved and becomes terminal, so no wait rests on it and no fresh
#       emit adopts it. The correction is a different head and therefore a new
#       request, which inherits nothing from this ruling.
#   fm-outbound-artifact.sh declare <item-id> --gate <gate> --head <sha>
#       Enter the wait state for one item, and REFUSE to enter it unless a
#       durable, valid, applicable request already backs that exact gate and
#       head. This is the only point at which a bare wait can still be
#       prevented rather than merely reported by a later sweep.
#   fm-outbound-artifact.sh quarantine --request <id> --ruling <ref>
#       Retire a MALFORMED request as non-actionable under the ruling that said
#       so. The record is preserved unchanged and stays diagnostic; it simply
#       stops being applicable, so no wait rests on it and no restart rebuilds
#       one from it. Never a repair, and never a substitute for hand-editing a
#       request into validity - which the ruling forbids.
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
# shellcheck source=bin/fm-sol-control-config-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-sol-control-config-lib.sh"
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

# --- project clone resolution ------------------------------------------------
#
# WHERE A REGISTERED PROJECT'S CLONE ACTUALLY IS.
#
# Nearly always $PROJECTS/<name>, and for every project but one that is the
# whole rule. The exception is firstmate's OWN repository: the operational home
# IS that checkout, so $PROJECTS/<name> names a directory that has never
# existed. The consequence is not cosmetic - the object format is read from the
# clone, an undeterminable width refuses every candidate head by contract, and
# so every exact head for that project was unobservable and no request for it
# could be bound at all.
#
# The only way to observe one was to point FM_PROJECTS_OVERRIDE at the home's
# parent directory. That variable is TEST isolation (docs/configuration.md), and
# using it as configuration resolves this project by BREAKING every other one:
# with the override in place a sibling project's clone is no longer under
# $PROJECTS at all, so its stored correlation records stop validating and turn
# could-not-observe. The two defects this file was repaired for are that trade,
# seen from its two ends.
#
# So the home's own repository is resolved here, from evidence, under three
# conditions that must ALL hold. Each one closes a different way of guessing:
#
#   1. $PROJECTS/<name> does not exist. A real clone always wins, so no existing
#      resolution changes and a home that does keep one is untouched.
#   2. The project is REGISTERED in data/projects.md, read through the same
#      registry reader the inventory pass already uses. An unreadable registry
#      is could-not-observe and never an empty one, so a caller-supplied name
#      can never reach the home through a registry nobody could read.
#   3. $FM_HOME is itself the TOP LEVEL of a git repository whose directory name
#      is that project. Read from git and compared as resolved physical paths,
#      never inferred from a name matching - a home that merely sits somewhere
#      inside a repository is not that repository's clone.
#
# Anything short of all three is could-not-observe, which leaves the ordinary
# path in place and the head unobserved - the same answer as before this
# resolution existed. Nothing here writes, and every read it enables is a read.

# Resolved ONCE at startup rather than per call. Every consumer below runs
# inside a command substitution, and a global assigned in a subshell dies with
# it, so a lazily memoized answer would be recomputed on every single call while
# reading as if it were cached.
HOME_REPO_PROJECT=
resolve_home_repo_project() {
  local top home_phys top_phys
  top=$(git --no-optional-locks -C "$FM_HOME" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$top" ] || return 0
  home_phys=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 0
  top_phys=$(cd "$top" 2>/dev/null && pwd -P) || return 0
  [ "$home_phys" = "$top_phys" ] || return 0
  HOME_REPO_PROJECT=${top_phys##*/}
}
resolve_home_repo_project

registered_projects() {
  local reg="$DATA/projects.md"
  [ -r "$reg" ] || return 1
  sed -n 's/^- \([A-Za-z0-9_.-]*\).*/\1/p' "$reg"
}

# The ONE place a project name becomes a directory. Prints the ordinary
# $PROJECTS path unless all three conditions above hold, so a caller that gets
# an unusable directory back is in exactly the position it was in before.
project_dir() {  # <project> -> clone directory
  local project=$1
  if [ ! -d "$PROJECTS/$project" ] && [ -n "$HOME_REPO_PROJECT" ] \
     && [ "$project" = "$HOME_REPO_PROJECT" ] \
     && registered_projects 2>/dev/null | grep -qxF -- "$project"; then
    printf '%s\n' "$FM_HOME"
    return 0
  fi
  printf '%s\n' "$PROJECTS/$project"
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
  local raw=$1 expected=$2 state stored gate project repo item pr head head_source computed tree policy
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
  # Absent tree and policy stay absent, so a record written before those axes
  # existed recomputes to exactly the id it was filed under.
  tree=$(printf '%s' "$raw" | jq -r '.identity.tree // ""') || { record_identity_cno; return 0; }
  policy=$(printf '%s' "$raw" | jq -r '.identity.policy // ""') || { record_identity_cno; return 0; }
  case $head_source in ""|declared|forge|local) ;; *) record_identity_cno; return 0 ;; esac
  # An identity that cannot be bound cannot be compared: that is an absent
  # identity, not one naming something else.
  fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" "$(project_dir "$project")" "$head_source" \
    >/dev/null 2>&1 || { record_identity_cno; return 0; }
  computed=$(fm_outbound_request_id "$gate" "$project" "$repo" "$item" "$pr" "$head" "$tree" "$policy") \
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
  local file
  file="$CONFIG/sol-control.json"
  if ! fm_sol_control_config_read "$file"; then
    if [ "$FM_SOL_CONTROL_CONFIG_STATE" = invalid ]; then
      printf 'FM_LANDING_VENUE_INVALID: config/sol-control.json has an invalid schema.\n' >&2
    fi
    return 1
  fi
  SOL_REPO=$FM_SOL_CONTROL_CONFIG_REPO
  SOL_ISSUE=$FM_SOL_CONTROL_CONFIG_ISSUE
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
  [ -z "$project" ] || dir=$(project_dir "$project")
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

# The envelope spellings this fleet has actually received for each binding.
#
# A MIGRATION SURFACE, not an extension point. Every name here was observed on
# the live control issue; adding one to make a body join is how the join stops
# meaning anything. Where an envelope carries more than one spelling of the same
# binding they must agree, so a longer list never loosens the join - it only
# lets a genuine ruling be read.
ruling_field_aliases() {  # <binding> -> the envelope keys that state it
  case $1 in
    request) printf 'in_reply_to\n' ;;
    item)    printf 'expected_item\nitem\n' ;;
    head)    printf 'expected_head_sha\nhead\n' ;;
    gate)    printf 'expected_gate\n' ;;
    project) printf 'expected_project\n' ;;
    repo)    printf 'expected_repo\n' ;;
    pr)      printf 'expected_pull_request\n' ;;
    tree)    printf 'expected_tree_sha\n' ;;
    policy)  printf 'expected_policy_generation\n' ;;
  esac
}

# THE RULING-IDENTITY JOIN.
#
# The typed reader uses the module's own field primitive from
# bin/fm-outbound-artifact-lib.sh. The legacy form remains readable for
# diagnosis but is not an acceptance-bearing input.
#
# EVERY APPLICABILITY BINDING IS JOINED. Request, gate, project, repository,
# item, pull request and exact head are required. Tree and policy generation are
# required when the request identity carries them.
#
# Nothing here is resolved by position or precedence. A required field that is
# absent, duplicated, or malformed refuses, and so does a body whose form is
# itself ambiguous - and every one of those refusals happens before any record
# is written, so a refused ruling mutates nothing.
#
# Returns 0 joined · 1 the body names other work · 2 ambiguous or unreadable ·
# 3 legacy rendering that cannot carry authority.
# Set by ruling_identity_join to name the binding that stopped it, so a refusal
# points at the repair. "no exact head" and "two items" are different fixes, and
# a single ambiguity sentence sends an operator looking for the wrong one.
RULING_JOIN_DETAIL=
ruling_identity_join() {  # <body> <record-json> [<form>]
  local body=$1 rec=$2 form=${3:-} envelope value rc key want alias found
  RULING_JOIN_DETAIL=
  [ -n "$form" ] || form=$(fm_outbound_ruling_form "$body")
  case $form in
    legacy) RULING_JOIN_DETAIL="legacy marker rulings are non-authoritative rendering"; return 3 ;;
    typed) ;;
    both) RULING_JOIN_DETAIL="its envelope declares more than one ruling form"; return 2 ;;
    *) RULING_JOIN_DETAIL="it declares no ruling form"; return 1 ;;
  esac
  envelope=$(fm_outbound_ruling_envelope "$body")

  # Required bindings. Absent or duplicated is could-not-observe, never a
  # mismatch: we did not learn the envelope is about other work, we learned it
  # did not say once which work it is about.
  #
  # TWO SPELLINGS PER BINDING, because the governed sender uses both. Comment
  # 5383943043 states `expected_item`/`expected_head_sha`; comments 5384188549
  # and 5384189401 state a bare `item`. Reading only one vocabulary would refuse
  # genuine rulings for a naming choice. Where an envelope states BOTH, they must
  # agree - two spellings disagreeing is a contradiction inside one envelope and
  # is refused rather than resolved by preferring either.
  for key in request gate project repo item pr head; do
    case $key in
      request) want=$(printf '%s' "$rec" | jq -r '.request_id') ;;
      gate)    want=$(printf '%s' "$rec" | jq -r '.identity.gate') ;;
      project) want=$(printf '%s' "$rec" | jq -r '.identity.project') ;;
      repo)    want=$(printf '%s' "$rec" | jq -r '.identity.repo') ;;
      item)    want=$(printf '%s' "$rec" | jq -r '.identity.item') ;;
      pr)      want=$(printf '%s' "$rec" | jq -r '.identity.pr // "-"') ;;
      head)    want=$(printf '%s' "$rec" | jq -r '.identity.head') ;;
    esac
    found=0
    for alias in $(ruling_field_aliases "$key"); do
      value=$(fm_outbound_envelope_field "$envelope" "$alias"); rc=$?
      case $rc in
        1) continue ;;
        2) RULING_JOIN_DETAIL="its envelope states $alias more than once"; return 2 ;;
      esac
      [ -n "$value" ] || { RULING_JOIN_DETAIL="its envelope states an empty $alias"; return 2; }
      [ "$value" = "$want" ] || { RULING_JOIN_DETAIL="its $alias names $value, not $want"; return 1; }
      found=1
    done
    if [ "$found" -ne 1 ]; then
      RULING_JOIN_DETAIL="its envelope states no $key"
      return 2
    fi
  done

  for key in tree policy; do
    case $key in
      tree)   want=$(printf '%s' "$rec" | jq -r '.identity.tree // ""') ;;
      policy) want=$(printf '%s' "$rec" | jq -r '.identity.policy // ""') ;;
    esac
    [ -n "$want" ] || continue
    found=0
    for alias in $(ruling_field_aliases "$key"); do
      value=$(fm_outbound_envelope_field "$envelope" "$alias"); rc=$?
      case $rc in
        1) continue ;;
        2) RULING_JOIN_DETAIL="its envelope states $alias more than once"; return 2 ;;
      esac
      [ "$value" = "$want" ] || { RULING_JOIN_DETAIL="its $alias names $value, not $want"; return 1; }
      found=1
    done
    [ "$found" -eq 1 ] || { RULING_JOIN_DETAIL="its envelope states no $key"; return 2; }
  done
  return 0
}

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
  local declared=${2:-} url dir
  # Split from the assignments above deliberately: bash expands every `local`
  # right-hand side before assigning any of them, so a path built from a
  # positional in the same declaration is a standing hazard.
  dir=$(project_dir "$1")
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
#
# It reads its project list through registered_projects, which lives with the
# clone resolution above because project_dir consults the same registry.

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
  projects=$(registered_projects); rc=$?
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
    dir=$(project_dir "$project")
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
  local channel venue repo rid missing stale present rc token capped cls subject_tree subject_policy subject_declared subject_missing
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
      # For a contribution the venue IS the subject: the pull request lives in
      # the repository it is offered to.
      repo=${venue:-$project}
    else
      venue=
      read_sol_config && venue=$SOL_REPO
      # THE SAME SUBJECT THE EMITTER COMPILES, or this sweep computes an identity
      # emit will never produce and reports every item as missing its artifact.
      # It used to take the control repository here too, which is how the sweep
      # agreed with the malformed requests it should have been contradicting.
      subject_declared=$(declared_field "$item" repo)
      repo=$(subject_repo_for "$item" "$project")
    fi
    subject_tree=$(declared_field "$item" tree)
    subject_policy=$(declared_field "$item" policy_generation)

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
    missing=$(fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" "$(project_dir "$project")" "$head_source" || true)
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

    if [ "$channel" != "pull-request" ]; then
      subject_missing=$(fm_outbound_subject_missing "$repo" "$SOL_REPO" \
        "$(project_dir "$project")" "$subject_tree" "$head" "$subject_declared" || true)
    else
      subject_missing=
    fi
    if [ -n "$subject_missing" ]; then
      # TWO OUTCOMES, NOT ONE. A subject that is positively WRONG - the venue
      # itself, a name the clone does not know, a tree that is not the head's -
      # is a defect: no request can exist for it, and saying so is a claim the
      # evidence supports.
      #
      # A subject that is merely UNDECIDED is not. When the clone names two
      # repositories and nothing declares which one the review governs, this
      # sweep cannot compute the identity an artifact would carry, so it cannot
      # look for one either. Reporting a defect there would assert the invariant
      # is violated on the strength of a read that never happened.
      if printf '%s' "$subject_missing" | grep -qxF subject-repo-ambiguous; then
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "" \
          unevaluable "$FM_OUTBOUND_TOKEN_SUBJECT_UNRESOLVED" \
          "$(printf '%s' "$subject_missing" | tr '\n' ',' | sed 's/,$//')" "" 0 >> "$rows"
      else
        row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "" \
          defect "$FM_OUTBOUND_TOKEN_INCOMPLETE" \
          "$(printf '%s' "$subject_missing" | tr '\n' ',' | sed 's/,$//')" "" 0 >> "$rows"
      fi
      continue
    fi
    rid=$(fm_outbound_request_id "$gate" "$project" "$repo" "$item" "$pr_ref" "$head" \
      "$subject_tree" "$subject_policy") || rid=

    if [ "$channel" = "pull-request" ]; then
      present=$(pr_artifact_present "$venue" "$head"); rc=$?
    else
      existing=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$repo" \
        "$item" "$pr_ref" "$head" "$SOL_REPO#$SOL_ISSUE" "$(now_iso)" "$head_source" \
        "$subject_tree" "$subject_policy")
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
  if probes_capped; then capped=true; else capped=false; fi
  # THE ROWS REACH jq THROUGH stdin, NEVER THROUGH argv. They used to be folded
  # in one jq and then handed to a second as `--argjson rows "$row"`, which
  # Linux caps at MAX_ARG_STRLEN - 128KB for ONE argument, well under the 2MB
  # total - so a sweep simply died with "Argument list too long", printing no
  # rows and no reason. Observed the moment this command could read firstmate's
  # own repository: ~250 candidate branches is already past the cap, and the
  # sweep that was meant to report them reported nothing at all.
  #
  # A row set has no bound this file controls - it is however many branches and
  # waiting items a fleet has - so the fix is structural rather than a bigger
  # number: one jq, rows read from the file, nothing large on a command line.
  SWEEP=$(jq -s --argjson capped "$capped" '
    (reduce .[] as $r ([];
       if $r.tier == "inventory" and $r.verdict != "unevaluable"
          and any(.[]; ._identity == $r._identity and .tier != "inventory")
       then . else . + [$r] end) | map(del(._identity))) as $rows
    | {schema:"fm-outbound-sweep.v1",readable:true,capped:$capped,rows:$rows,reason:null}' \
    < "$rows")
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

# SUPERSEDING THIS ITEM'S OLDER HEADS IS A DECISION ABOUT THIS ITEM. Reaching it
# used to require VALIDATING every record in the store first, and that ordering
# is the defect repaired here: one preserved adverse record - kept deliberately,
# filed for a completely different work item, and correctly classified adverse
# everywhere it is reported - refused every NEW request in the fleet, including
# an exact, complete, well-bound one for work it says nothing about. Measured:
# an exact request for candidate-publication-effect-guard returned
# FM_OUTBOUND_RECORD_UNREADABLE before transport because
# fm-ob-18a4c958c445.json, whose own identity names ae-xp1-registered-external-
# target, could not be validated. A record's own brokenness became every other
# item's blocker, which is a fleet-wide outage produced by a correlation fault
# in one row.
#
# So the scope test now runs BEFORE the validity test, and only in that
# direction. A record this pass can positively read as belonging to ANOTHER item
# is skipped for THIS decision, because superseding is defined over records for
# THIS item and such a record was never a candidate for it.
#
# WHAT THE SKIP IS NOT. It is not a repair, not a certification, and not a
# narrowing of the invariant. The record is untouched, still adverse to
# record_read and `show`, and still reported through the item it actually
# belongs to by the sweep - which is where a correlation fault is an operator's
# to fix. Nothing here can make a record satisfy anything.
#
# SAME-ITEM SAFETY IS UNCHANGED, and the asymmetry is what preserves it. The
# skip needs unrelatedness POSITIVELY established from the record's own bytes;
# every other outcome keeps the record in scope and reaches the identical
# refusal as before. A record for this item whose identity mismatches, one whose
# subject is absent, ambiguous or duplicated, and one that will not parse at all
# are all still validated here and still refuse with zero posted.
#
# THE BOUND, STATED: this pass is O(records in the store), by construction and
# not by oversight. The store is content-addressed - a record is named
# fm-ob-<digest>.json where the digest is over the canonical identity - so the
# work item cannot be recovered from a filename and no cheap name filter can
# narrow the walk. The jq below is what scopes the WRITE to this item and to
# non-terminal records; reading every file is what it costs to reach that
# decision. Narrowing this would mean indexing the store, which is a change to
# the record format rather than to this loop.
supersede_other_heads() {  # <item> <current-request-id> <current-head> <current-gate>
  local item=$1 rid=$2 head=$3 gate=$4 f other rec read_rc raw subject reason state
  [ -d "$RECORD_DIR" ] || return 0
  for f in "$RECORD_DIR"/*.json; do
    [ -f "$f" ] || continue
    other=${f##*/}
    other=${other%.json}
    raw=$(cat "$f" 2>/dev/null) || raw=
    if subject=$(fm_outbound_record_subject "$raw"); then
      # Positively another item's record: outside this decision entirely. Note
      # this consults the record's OWN bytes, never its filename - a filename is
      # what a record can disagree with, which is the condition being guarded.
      [ "$subject" = "$item" ] || continue
    else
      # THE SUBJECT COULD NOT BE ESTABLISHED, so this record can be shown
      # neither to be another item's nor to be readable as this one's. It
      # refuses HERE rather than falling through, because the validator below
      # resolves a duplicated key by write order: handed a record carrying two
      # subjects it reads the last one, finds it consistent, and returns a
      # confident verdict about a record whose subject is ambiguous - which is
      # then skipped as another item's without anything ever refusing. Measured
      # as exactly that: a duplicated `identity` permitted an emit while the
      # scope test above had already declined to read it.
      return 2
    fi
    rec=$(record_read "$other"); read_rc=$?
    if [ "$read_rc" -ne 0 ]; then
      case $read_rc in
        1|2) return 2 ;;
        5) return 5 ;;
        *) return 2 ;;
      esac
    fi
    # A PREDECESSOR IS ANY LIVE REQUEST FOR THIS ITEM AT A DIFFERENT IDENTITY,
    # and the test for that is the REQUEST ID, not a field-by-field comparison.
    # The id is the digest OVER the whole identity, so a different id is exactly
    # what "a different question" means - and it stays right as identity grows.
    # It was written as a head-and-gate comparison, and every field added since
    # slipped through it: a moved policy generation asked a new question while
    # its predecessor stayed live beside it, which is the two-applicable-request
    # state this linkage exists to make impossible.
    #
    # TERMINAL RECORDS ARE PRESERVED, not rewritten. A finished predecessor is
    # history and this linkage only ever retires something still live.
    state=$(printf '%s' "$rec" | jq -r '.state') || continue
    fm_outbound_state_terminal "$state" && continue
    printf '%s' "$rec" | jq -e --arg i "$item" --arg r "$rid" \
      '.identity.item == $i
       and .request_id != $r' \
      >/dev/null 2>&1 || continue
    # Name WHICH binding moved, because "superseded" alone does not say whether
    # the work changed or only the question did.
    reason='bound to an identity that moved'
    printf '%s' "$rec" | jq -e --arg h "$head" '.identity.head != $h' >/dev/null 2>&1 \
      && reason='bound to a head that moved'
    printf '%s' "$rec" | jq -e --arg h "$head" --arg g "$gate" \
      '.identity.head == $h and .identity.gate != $g' >/dev/null 2>&1 \
      && reason='bound to a gate that moved'
    rec=$(printf '%s' "$rec" | jq --arg s "$rid" --arg n "$(now_iso)" \
      '.state = "superseded" | .superseded_by = $s | .updated = $n')
    record_write "$other" "$rec" || return 2
    printf 'superseded: %s (%s)\n' "$other" "$reason"
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
  local subject_repo subject_declared subject_tree subject_policy subject_missing clone
  local attempt delay body found existing dedupe_rc retry_rc record_rc supersede_rc existing_state

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
  venue="$SOL_REPO#$SOL_ISSUE"

  # THE SUBJECT, COMPILED ONCE AND VALIDATED BEFORE ANY DURABLE EFFECT.
  #
  # The identity's repository is what the request is ABOUT. It used to be
  # $SOL_REPO - the control issue's own repository - so three requests in a row
  # persisted `repo: sbracewell64/firstmate-sol-control` while binding a head
  # that exists only in the governed repository the work lives in, and Browser
  # Sol ruled every one of them non-actionable for the same reason.
  #
  # Everything below happens BEFORE the record directory, the lock, supersession
  # and the transport call, so a subject that cannot represent one real thing
  # refuses with zero durable actionable request and zero waiting-state
  # transition - which is what the ruling requires and what a later refusal,
  # after the record exists, would not have given.
  subject_declared=$(declared_field "$item" repo)
  subject_tree=$(declared_field "$item" tree)
  subject_policy=$(declared_field "$item" policy_generation)
  clone=$(project_dir "$project")
  subject_repo=$(subject_repo_for "$item" "$project")

  missing=$(fm_outbound_binding_missing "$gate" "$project" "$subject_repo" "$item" "$head" "$clone" "$head_source" || true)
  if [ -n "$missing" ]; then
    printf '%s: cannot construct an exact-head-bound request for %s - missing %s\n' \
      "$FM_OUTBOUND_TOKEN_INCOMPLETE" "$item" \
      "$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')" >&2
    printf 'Refusing to emit a vague request. %s stays red until the binding is complete.\n' "$item" >&2
    exit 3
  fi

  subject_missing=$(fm_outbound_subject_missing "$subject_repo" "$SOL_REPO" "$clone" "$subject_tree" "$head" "$subject_declared" || true)
  if [ -n "$subject_missing" ]; then
    printf '%s: %s has no validated governed subject - %s\n' \
      "$FM_OUTBOUND_TOKEN_INCOMPLETE" "$item" \
      "$(printf '%s' "$subject_missing" | tr '\n' ',' | sed 's/,$//')" >&2
    printf 'The control repository is where the question is asked, never what it is about.\n' >&2
    printf 'Nothing was written and no wait was created.\n' >&2
    exit 3
  fi

  rid=$(fm_outbound_request_id "$gate" "$project" "$subject_repo" "$item" "$pr_ref" "$head" \
    "$subject_tree" "$subject_policy") \
    || die "could not compute a request identity" 4

  if [ "$dry" = "1" ]; then
    record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$subject_repo" \
      "$item" "$pr_ref" "$head" "$venue" "$(now_iso)" "$head_source" "$subject_tree" "$subject_policy")
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

  supersede_other_heads "$item" "$rid" "$head" "$gate"; supersede_rc=$?
  if [ "$supersede_rc" -ne 0 ]; then
    case $supersede_rc in
      5) die "$FM_OUTBOUND_TOKEN_IDENTITY: a keyed correlation record belongs to another request" 3 ;;
      *) die "$FM_OUTBOUND_TOKEN_UNREADABLE: could not validate every keyed correlation record" 4 ;;
    esac
  fi

  # Dedupe against the forge FIRST. This is both ordinary duplicate suppression
  # and the crash-recovery path, because they are the same question: does an
  # artifact carrying this id already exist?
  record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$subject_repo" \
    "$item" "$pr_ref" "$head" "$venue" "$(now_iso)" "$head_source" "$subject_tree" "$subject_policy")
  found=$(sol_artifact_present "$rid" "$record"); dedupe_rc=$?
  if [ "$dedupe_rc" -eq 0 ]; then
    existing=$(record_read "$rid"); record_rc=$?
    if [ "$record_rc" -eq 0 ]; then
      # A FINISHED REQUEST CANNOT ANSWER A FRESH ONE. `closed` and `superseded`
      # are terminal, and fm_outbound_applicability has always called them
      # INAPPLICABLE - but this adoption path never asked, so a completed
      # correlation was reported as "already requested" and the item went on
      # waiting on an artifact whose question had already been answered and
      # retired. Measured on fm-ob-25c701e04893, closed after its HOLD was
      # self-handled, adopted by a later request at the same identity.
      #
      # Refusing here rather than reopening: the identity is deterministic, so
      # the same gate, item and head always name this same finished record. What
      # has to move is the item's own state, and saying so is the repair.
      existing_state=$(printf '%s' "$existing" | jq -r '.state')
      if fm_outbound_state_terminal "$existing_state"; then
          printf '%s: %s already names %s, which is %s and cannot answer a new request\n' \
            "$FM_OUTBOUND_TOKEN_MISMATCH" "$item" "$rid" "$existing_state" >&2
          printf 'Its gate, head and item are unchanged, so a fresh request would carry the same identity.\n' >&2
          printf 'Nothing was posted and the finished record is untouched.\n' >&2
          exit 3
      fi
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
        record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$subject_repo" \
          "$item" "$pr_ref" "$head" "$venue" "$(now_iso)" "$head_source" "$subject_tree" "$subject_policy")
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

# RETIRING A MALFORMED REQUEST THROUGH THIS OWNER, never by hand.
#
# Three requests were emitted with the control repository as their subject and
# ruled non-actionable. The ruling is explicit that they must not be hand-edited
# into validity and must not keep sustaining a wait - two requirements that pull
# in opposite directions unless the owner itself can retire one.
#
# So this marks the record terminal and records WHY, under WHICH ruling. Nothing
# about its identity, its comment, or its evidence changes: the record stays
# readable, stays diagnostic, and stays exactly as adverse as it was. What it
# stops being is APPLICABLE - fm_outbound_applicability has always called a
# terminal record inapplicable, so after this no wait rests on it and no restart
# can reconstruct one from it.
#
# It is deliberately NOT a repair. A quarantined request answers nothing; the
# item it belonged to goes back to having no applicable artifact, which is the
# invariant's red condition and the honest state to be in.
cmd_quarantine() {  # <request-id> <ruling-ref>
  local rid=$1 ruling=$2 rec state
  [ -n "$ruling" ] || die "quarantine needs the ruling that retires the request" 2
  require_record "$rid"; rec=$RECORD
  state=$(printf '%s' "$rec" | jq -r '.state')
  if [ "$state" = quarantined ]; then
    printf 'already quarantined: %s (%s)\n' "$rid" \
      "$(printf '%s' "$rec" | jq -r '.disposition // "no ruling recorded"')"
    return 0
  fi
  # AN ALREADY-FINISHED REQUEST IS ANNOTATED, NOT RELABELLED. Two of the three
  # requests this was built for had already been superseded by the time the
  # ruling arrived. They are inapplicable already, so nothing needs retiring -
  # but WHY they are non-actionable is worth recording, and overwriting
  # `superseded` would throw away the successor linkage that says which request
  # replaced them. So the ruling is appended to the disposition and the state is
  # left exactly as it stands.
  if fm_outbound_state_terminal "$state"; then
    rec=$(printf '%s' "$rec" | jq --arg r "$ruling" --arg n "$(now_iso)" \
      '.disposition = ((.disposition // "")
                       | if . == "" then "" else . + "; " end)
                      + "ruled malformed under " + $r
       | .updated = $n')
    record_write "$rid" "$rec" || die "could not write the correlation record" 4
    printf 'already terminal: %s is %s and applies to nothing; recorded the ruling %s\n' \
      "$rid" "$state" "$ruling"
    return 0
  fi
  rec=$(printf '%s' "$rec" | jq --arg r "$ruling" --arg n "$(now_iso)" \
    '.state = "quarantined"
     | .disposition = ("retired as malformed under " + $r)
     | .updated = $n')
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'quarantined: %s retired as malformed under %s\n' "$rid" "$ruling"
  printf 'Its identity, comment and evidence are unchanged; it is no longer applicable to any wait.\n'
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

# THE GOVERNED SUBJECT, DERIVED IN EXACTLY ONE PLACE.
#
# Every caller that computes a request identity - emit, the sweep, and the
# ruling join that re-checks a stored identity against the current one - must
# agree on what the request is ABOUT, or a genuine ruling for our own request is
# refused as a mismatch. It is derived here so there is one answer rather than
# three: a declaration wins, otherwise it is the repository this project's work
# actually lives in, and it is never $SOL_REPO, which is only where the question
# gets asked. Prints the subject repository; the caller validates it.
subject_repo_for() {  # <item> <project> -> owner/name or project name
  local declared
  declared=$(declared_field "$1" repo)
  [ -n "$declared" ] || declared=$(project_venue "$2")
  [ -n "$declared" ] || declared=$2
  printf '%s\n' "$declared"
}

require_record_applicable_now() {  # <request-id> <record-json>
  local rid=$1 rec=$2 item current gate channel project repo pr_url pr_ref head_observation head head_source missing
  local stored_identity current_identity stored_venue current_venue tree policy successor
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
  tree=$(declared_field "$item" tree)
  policy=$(declared_field "$item" policy_generation)
  if [ "$channel" = "pull-request" ]; then
    repo=$(project_venue "$project" \
      "$(printf '%s' "$current" | jq -r '.contribution_venue // ""')")
  else
    read_sol_config || die "the configured control repository could not be observed" 4
    # NOT $SOL_REPO. The stored identity records the governed subject, so
    # recomputing it from the transport venue would refuse every ruling for a
    # request emitted after that repair - the join would compare the subject
    # against the venue and correctly find them different.
    repo=$(subject_repo_for "$item" "$project")
    current_venue="$SOL_REPO#$SOL_ISSUE"
  fi
  missing=$(fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" "$(project_dir "$project")" "$head_source" || true)
  [ -z "$missing" ] || die "the current identity for $item is incomplete: $(printf '%s' "$missing" | tr '\n' ',')" 4
  # VALIDATE THE SUBJECT BEFORE COMPARING AGAINST IT. Everything below this line
  # can WRITE - a mismatch supersedes the stored record - so a subject that was
  # merely derived and never checked would let this retire a live request on the
  # strength of a guess. When the subject cannot be established the honest answer
  # is could-not-observe: the ruling is not joined, and the record is left
  # exactly as it stands rather than being retired by an unread comparison.
  if [ "$channel" != "pull-request" ]; then
    missing=$(fm_outbound_subject_missing "$repo" "$SOL_REPO" "$(project_dir "$project")" \
      "$tree" "$head" "$(declared_field "$item" repo)" || true)
    [ -z "$missing" ] || die \
      "$FM_OUTBOUND_TOKEN_SUBJECT_UNRESOLVED: $item has no validated governed subject - $(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//'); $rid was left untouched" 4
  fi
  stored_identity=$(printf '%s' "$rec" | jq -r \
    '[.identity.gate,.identity.project,.identity.repo,.identity.item,(.identity.pr // "-"),.identity.head,(.identity.tree // ""),(.identity.policy // "")] | @tsv')
  current_identity=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$gate" "$project" "$repo" "$item" "$pr_ref" "$head" "$tree" "$policy")
  stored_venue=$(printf '%s' "$rec" | jq -r '.venue // ""')
  if [ "$current_identity" != "$stored_identity" ] \
    || { [ "$channel" = "sol-control" ] && [ "$current_venue" != "$stored_venue" ]; }; then
    successor=$(fm_outbound_request_id "$gate" "$project" "$repo" "$item" "$pr_ref" "$head" "$tree" "$policy") \
      || die "the successor identity for $item could not be compiled" 4
    rec=$(printf '%s' "$rec" | jq --arg n "$(now_iso)" --arg s "$successor" \
      '.state = "superseded" | .superseded_by = $s | .updated = $n')
    record_write "$rid" "$rec" || die "could not invalidate stale request $rid" 4
    printf '%s: request %s no longer matches the complete current identity\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" >&2
    exit 3
  fi
}

cmd_ruling() {  # <request-id> <comment-id> <issue>
  local rid=$1 comment=$2 issue=$3 rec state venue_repo venue_issue artifact body request_comment verdict verdict_count
  local form join_rc verdict_key other_key other_count
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
  form=$(fm_outbound_ruling_form "$body")
  ruling_identity_join "$body" "$rec" "$form"; join_rc=$?
  if [ "$join_rc" -eq 3 ]; then
    printf '%s: comment %s uses the legacy marker form, which cannot drive a ruling transition\n' \
      "$FM_OUTBOUND_TOKEN_LEGACY_NONAUTHORITATIVE" "$comment" >&2
    printf 'Submit a complete typed RulingEnvelope. Nothing was written.\n' >&2
    exit 3
  fi
  if [ "$join_rc" -eq 2 ]; then
    # AMBIGUOUS, not MISMATCH. The body may well be this request's ruling; what
    # we could not do is read WHICH request it names once. Reporting that as a
    # mismatch sends an operator looking for a misaddressed ruling instead of
    # for the duplicated or missing field that is actually there.
    printf '%s: comment %s cannot be joined - %s\n' \
      "$FM_OUTBOUND_TOKEN_AMBIGUOUS" "$comment" \
      "${RULING_JOIN_DETAIL:-its envelope does not state the request identity once}" >&2
    printf 'Refusing rather than choosing a field by position. Nothing was written.\n' >&2
    exit 4
  fi
  if [ "$join_rc" -ne 0 ]; then
      printf '%s: comment %s does not carry the exact request identity - %s\n' \
        "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" \
        "${RULING_JOIN_DETAIL:-its envelope names other work}" >&2
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
  # EACH FORM STATES ITS VERDICT UNDER ITS OWN KEY - `verdict:` on the legacy
  # form, `decision:` on the typed one - and a body carrying BOTH keys is
  # refused rather than resolved by preferring either. Two verdict channels in
  # one body is the same ambiguity as two verdict lines, arriving one level up.
  if [ "$form" = typed ]; then verdict_key='decision'; other_key='verdict'
  else verdict_key='verdict'; other_key='decision'; fi
  other_count=$(printf '%s\n' "$body" | grep -c "^$other_key: " || true)
  case $other_count in ''|*[!0-9]*) other_count=0 ;; esac
  if [ "$other_count" -ne 0 ]; then
    printf '%s: comment %s is a %s-form ruling that also carries %s "%s:" line(s)\n' \
      "$FM_OUTBOUND_TOKEN_AMBIGUOUS" "$comment" "$form" "$other_count" "$other_key" >&2
    printf 'Refusing rather than preferring one verdict key over the other. Nothing was written.\n' >&2
    exit 4
  fi
  verdict_count=$(printf '%s\n' "$body" | grep -c "^$verdict_key: " || true)
  case $verdict_count in ''|*[!0-9]*) verdict_count=0 ;; esac
  if [ "$verdict_count" -ne 1 ]; then
    printf '%s: comment %s carries %s %s lines; exactly one is required\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" "$verdict_count" "$verdict_key" >&2
    printf 'Refusing rather than reading one by position. A ruling that quotes another must state its own verdict once.\n' >&2
    exit 3
  fi
  # Recorded VERBATIM. This module never decides what a word authorizes; the
  # closed list in bin/fm-landing-authorization-lib.sh does, and a word outside
  # it - HOLD included - is unrecognized there and stops the act.
  verdict=$(printf '%s\n' "$body" | sed -n "s/^$verdict_key: //p")
  # A REPLAY OF THE SAME RULING WRITES NOTHING. A wake can arrive twice - a
  # re-poll, a retried check, a restart mid-drain - and rejoining the identical
  # comment used to rewrite `observed` and `updated` each time. That is a
  # durable change with no new information in it, so the record's own bytes
  # stopped being a reliable answer to "has anything happened since?", and
  # anything comparing the record across a replay saw movement that was purely
  # the clock. Converging silently here is what makes the replay idempotent
  # rather than merely harmless.
  if [ "$state" = ruled ] \
    && printf '%s' "$rec" | jq -e --arg c "$comment" --arg v "$verdict" \
      '.ruling.comment_id == $c and .ruling.verdict == $v' >/dev/null 2>&1; then
    printf 'ruled: %s already carries this exact ruling; nothing was written\n' "$rid"
    return 0
  fi
  rec=$(printf '%s' "$rec" | jq --arg c "$comment" --arg v "$verdict" --arg n "$(now_iso)" \
    '.ruling = {comment_id:$c, verdict:$v, observed:$n} | .state = "ruled" | .updated = $n')
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'ruled: %s wakes %s\n' "$rid" "$(printf '%s' "$rec" | jq -r '.identity.item')"
}

cmd_poll() {
  local comments row body rid comment rc failed=0 poll_record poll_state out form marker_count
  if ! read_sol_config; then
    [ "$FM_SOL_CONTROL_CONFIG_STATE" = absent ] && return 0
    return 4
  fi
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
    # DISCOVERY READS BOTH WIRE FORMS so legacy rendering is diagnosed rather
    # than silently disappearing, while only the typed form can transition.
    form=$(fm_outbound_ruling_form "$body")
    case $form in
      both)
        marker_count=$(fm_outbound_ruling_envelope "$body" \
          | grep -c "^$FM_OUTBOUND_RULING_MARKER " || true)
        case $marker_count in ''|*[!0-9]*) marker_count=0 ;; esac
        printf '%s: comment %s declares more than one ruling form in its envelope (%s ruling marker lines)\n' \
          "$FM_OUTBOUND_TOKEN_AMBIGUOUS" "$comment" "$marker_count" >&2
        printf 'Refusing rather than preferring one declaration over the other.\n' >&2
        [ "$failed" -ne 0 ] || failed=3
        continue ;;
      none) continue ;;
    esac
    if [ "$form" = typed ]; then
      rid=$(fm_outbound_typed_ruling_request "$body"); rc=$?
    else
      rid=$(fm_outbound_legacy_ruling_request "$body"); rc=$?
    fi
    # NOT OURS IS NOT AMBIGUOUS. An envelope with no request, or one naming an
    # identity this mechanism does not correlate, is passed over in silence -
    # this control issue carries far more conversation than correlation records,
    # and treating every other participant's ruling as a defect is what turned
    # one poll into dozens of ambiguity reports and a failing status.
    case $rc in
      0) ;;
      1|3) continue ;;
      *)
        # The one genuinely unresolvable case: the envelope addresses us and
        # states its request more than once, so which one it rules cannot be
        # chosen without choosing for the sender.
        printf '%s: comment %s states its request more than once in its envelope\n' \
          "$FM_OUTBOUND_TOKEN_AMBIGUOUS" "$comment" >&2
        printf 'Refusing rather than reading one by position.\n' >&2
        [ "$failed" -ne 0 ] || failed=3
        continue ;;
    esac
    poll_record=$(record_read "$rid") || poll_record=
    if [ -n "$poll_record" ]; then
      poll_state=$(printf '%s' "$poll_record" | jq -r '.state')
      case $poll_state in
        resumed|ruled) continue ;;
      esac
      # A finished request cannot receive a ruling, so a late or duplicate
      # delivery for one is passed over rather than woken.
      fm_outbound_state_terminal "$poll_state" && continue
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
  local rid=$1 rec state verdict
  require_record "$rid"; rec=$RECORD
  state=$(printf '%s' "$rec" | jq -r '.state')
  if [ "$state" != "ruled" ]; then
    printf '%s: request %s is %s; only a ruled request can resume its item\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" "$state" >&2
    exit 3
  fi
  # A REVISION IS NOT A RESUMPTION. `ruled` says a verdict arrived, never that
  # the verdict let the work continue, and resuming on the strength of the state
  # alone is how a body that said "change this" clears the wait it should have
  # extended. The item goes back to work on a CORRECTED candidate, which is a
  # different head, so it is a different identity and a different request - and
  # this one is retired through `correct` rather than resumed here.
  verdict=$(printf '%s' "$rec" | jq -r '.ruling.verdict // ""')
  if fm_outbound_verdict_revising "$verdict"; then
    printf '%s: the ruling on %s returned "%s", which demands a corrected candidate rather than resuming this one\n' \
      "$FM_OUTBOUND_TOKEN_REVISION_REQUIRED" "$rid" "$verdict" >&2
    printf 'Retire it for correction, then emit the corrected candidate. It inherits nothing from this ruling.\n' >&2
    exit 3
  fi
  require_record_applicable_now "$rid" "$rec"
  rec=$(printf '%s' "$rec" | jq --arg n "$(now_iso)" \
    '.resumed = {at:$n} | .state = "resumed" | .updated = $n')
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'resumed: %s\n' "$(printf '%s' "$rec" | jq -r '.identity.item')"
}

# --- entering the wait state -------------------------------------------------
#
# THE ONLY MOMENT A BARE WAIT CAN STILL BE PREVENTED. Everything else in this
# file reports the condition after it exists: the sweep finds an item waiting
# with no artifact and calls it a defect, which is a repair notice rather than a
# guard. Seven items reached that state and stayed in it, because nothing was
# ever asked at the point the wait was CREATED.
#
# So the declaration that puts an item into a wait state is written HERE, and
# only after a durable request that backs that exact gate and head is found to
# exist. The order is the whole mechanism: ask first, then wait. An item cannot
# enter AWAITING_BROWSER_SOL because somebody wrote a hold sentence saying it
# is waiting - it enters because a question was demonstrably asked.
#
# THIS IS A PROMOTION, WHICH IS WHY IT DOES NOT TYPE THE GATE ITSELF. A row that
# has not been asked yet is recognised by its hold PROSE, and that prose is what
# lets the request be emitted in the first place. This command turns that
# recognised-by-prose wait into a TYPED declaration, and the typed form is
# exactly the one an emit reads as authoritative - so promoting a wait that
# nothing backs would manufacture the authoritative form of a question nobody
# asked. It never invents a gate and never rewrites prose; it refuses, and the
# prose row stays exactly as it was for a later sweep to report.
#
# A TERMINAL REQUEST BACKS NOTHING. Quarantined, revised, superseded and closed
# records are preserved as evidence and are deliberately not applicable, so a
# wait may not rest on one. That is the case worth naming: a request retired as
# malformed is exactly the shape that would otherwise look like an artifact and
# hold an item waiting forever on a question that was never validly asked.
cmd_declare() {  # <item> <gate> <head>
  local item=$1 gate=$2 head=$3 f other raw subject rec read_rc state backing dir tmp
  local declaration declared_repo declared_tree declared_policy
  if ! fm_outbound_gate_valid "$gate"; then
    printf '%s: %s is not a gate this mechanism recognises\n' \
      "$FM_OUTBOUND_TOKEN_INCOMPLETE" "$gate" >&2
    exit 3
  fi
  # SHAPE ONLY, and both object widths. The head's real width belongs to the
  # target repository's object format, which emit already established against
  # the clone - this declaration is not the place to re-derive it, and the
  # binding check below is the strong test anyway: a head no live request names
  # is refused whatever it looks like.
  if ! fm_outbound_is_sha "$head" 40 && ! fm_outbound_is_sha "$head" 64; then
    printf '%s: %s cannot be an exact head\n' \
      "$FM_OUTBOUND_TOKEN_INCOMPLETE" "$head" >&2
    exit 3
  fi

  # An unreadable store is could-not-observe, never "no backing request exists".
  # Reading it the other way would let an unreadable directory authorize the
  # very wait this refuses.
  if [ -d "$RECORD_DIR" ] && { [ ! -r "$RECORD_DIR" ] || [ ! -x "$RECORD_DIR" ]; }; then
    printf '%s: the request store could not be read, so it is unknown whether %s is backed\n' \
      "$FM_OUTBOUND_TOKEN_UNREADABLE" "$item" >&2
    exit 4
  fi
  declaration='{}'
  if [ -e "$(gate_file "$item")" ]; then
    declaration=$(jq -e 'select(type == "object")' "$(gate_file "$item")" 2>/dev/null) \
      || die "the existing declaration for $item could not be read" 4
  fi
  declared_repo=$(printf '%s' "$declaration" | jq -r '.repo // ""')
  declared_tree=$(printf '%s' "$declaration" | jq -r '.tree // ""')
  declared_policy=$(printf '%s' "$declaration" | jq -r '.policy_generation // ""')
  backing=
  if [ -d "$RECORD_DIR" ]; then
    for f in "$RECORD_DIR"/*.json; do
      [ -f "$f" ] || continue
      other=${f##*/}; other=${other%.json}
      raw=$(cat "$f" 2>/dev/null) || {
        printf '%s: %s could not be read, so it is unknown whether %s is backed\n' \
          "$FM_OUTBOUND_TOKEN_UNREADABLE" "$other" "$item" >&2
        exit 4
      }
      subject=$(fm_outbound_record_subject "$raw") || continue
      [ "$subject" = "$item" ] || continue
      rec=$(record_read "$other"); read_rc=$?
      # A record filed for THIS item that cannot be validated is not passed
      # over: it is the one record whose unreadability decides this answer.
      if [ "$read_rc" -ne 0 ]; then
        printf '%s: %s is filed for %s and could not be validated, so it is unknown whether the wait is backed\n' \
          "$FM_OUTBOUND_TOKEN_UNREADABLE" "$other" "$item" >&2
        exit 4
      fi
      printf '%s' "$rec" | jq -e --arg g "$gate" --arg h "$head" \
        --arg r "$declared_repo" --arg t "$declared_tree" --arg p "$declared_policy" \
        '.identity.gate == $g and .identity.head == $h
         and ($r == "" or .identity.repo == $r)
         and ($t == "" or .identity.tree == $t)
         and ($p == "" or .identity.policy == $p)' >/dev/null 2>&1 || continue
      state=$(printf '%s' "$rec" | jq -r '.state')
      fm_outbound_state_terminal "$state" && continue
      backing=$other
      break
    done
  fi

  if [ -z "$backing" ]; then
    printf '%s: %s has no live request at %s for head %s, so it may not enter that wait\n' \
      "$FM_OUTBOUND_TOKEN_WAIT_UNBACKED" "$item" "$gate" "$head" >&2
    printf 'Emit the request first. A wait with nothing to wait for is the condition this refuses to create.\n' >&2
    exit 3
  fi

  dir="$DATA/$item"
  mkdir -p "$dir" || die "could not create the declaration directory for $item" 4
  tmp="$dir/.outbound-gate.json.$$"
  printf '%s' "$declaration" | jq --arg gate "$gate" --arg head "$head" --arg r "$backing" \
    '. + {gate:$gate, head:$head, request:$r}' > "$tmp" \
    || { rm -f "$tmp"; die "could not write the declaration for $item" 4; }
  mv -f "$tmp" "$(gate_file "$item")" \
    || { rm -f "$tmp"; die "could not install the declaration for $item" 4; }
  printf 'declared: %s waits at %s on %s\n' "$item" "$gate" "$backing"
}

# THE CORRECTION ROUTE. A revision is the one ruling that answers the question
# and still leaves the item waiting, so it needs a terminal of its own: the
# request was well formed and was ruled, and what must change is the CANDIDATE.
#
# Retiring it here is what stops the correction being silently dropped. While
# the record stands `ruled` it is still applicable, so a sweep sees a live
# request, a fresh emit adopts it, and the item waits on a question that was
# already answered. `revised` is terminal, so applicability says inapplicable
# once and every one of those paths follows without a second rule.
#
# NOTHING TRANSFERS. The corrected candidate is a different head, so it computes
# a different identity and a different request id, and the ruling recorded here
# stays attached to the head it actually judged. That is the whole reason the
# successor is left to an ordinary `emit` rather than minted here: a successor
# this command wrote would be a request nobody asked, carrying an approval
# nobody gave for a head nobody reviewed.
cmd_correct() {  # <request-id>
  local rid=$1 rec state verdict
  require_record "$rid"; rec=$RECORD
  state=$(printf '%s' "$rec" | jq -r '.state')
  if [ "$state" != "ruled" ]; then
    printf '%s: request %s is %s; only a ruled request can be retired for correction\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" "$state" >&2
    exit 3
  fi
  verdict=$(printf '%s' "$rec" | jq -r '.ruling.verdict // ""')
  # ONLY a revision is retired this way. A request whose ruling approved or
  # declined it has a different ending, and letting this command retire one
  # would turn a correction route into a way to discard an inconvenient verdict.
  if ! fm_outbound_verdict_revising "$verdict"; then
    printf '%s: the ruling on %s returned "%s", which is not a demand for a corrected candidate\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" "$verdict" >&2
    printf 'Only a revising verdict is retired for correction. Nothing was written.\n' >&2
    exit 3
  fi
  rec=$(printf '%s' "$rec" | jq --arg n "$(now_iso)" \
    '.state = "revised" | .updated = $n')
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'revised: %s retired for correction - emit the corrected candidate to ask a new question\n' "$rid"
}

# --- post-effect closure -----------------------------------------------------
#
# CLOSURE IS AN OBSERVATION, NOT AN ANNOUNCEMENT. A disposition sentence is
# whatever the caller typed, so a correlation that closes on prose alone records
# that somebody BELIEVED the effect landed. That is exactly the evidence class
# this fleet keeps mistaking for a measurement: a merge command exits 0 for a
# merge that was queued, superseded, or performed against another head.
#
# So when an effect was actually authorized for this request, closure re-reads
# the world: the authority is checked to have been spent for THIS request and
# THIS head, and the target ref is observed again in the governed clone and
# bound into the record at the generation it is actually at.
#
# WHAT IS AND IS NOT PROVEN HERE, stated because the strength differs by effect
# and a uniform claim would be false. A fast-forward landing is exactly
# checkable: ff-only makes the target BECOME the authorized head, so anything
# else at the ref means something other than the authorized act moved it. A
# squash or rebase merge produces a forge-authored commit that no local rule
# predicts, so for those this binds the observed generation and does NOT claim
# the head is contained in it. The record says which was achieved rather than
# letting the stronger reading be assumed.
auth_store_dir() {
  printf '%s\n' "${FM_LANDING_AUTH_DIR:-$DATA/landing-authorizations}"
}

# The authorization this request had minted for it, if any. Prints its id, or
# nothing. A store that exists and cannot be read is could-not-observe and is
# reported by the caller rather than being read as "no authority was minted".
#
# THIS REFUSES ON ANY UNREADABLE RECORD, and that is deliberately not the same
# call as `supersede_other_heads`, which scopes to one item and passes over
# records positively identified as another item's. The difference is what the
# unreadable record could be. There, a record whose subject reads cleanly as
# another item is provably outside the decision. Here, an authorization is
# named by a digest over its own identity, so a record that cannot be read
# cannot be shown to belong to another request either - it might be this
# request's spent landing authority, and passing over it would close an effect
# by failing to see it. The blast radius is real and the repair is one named
# file, which is why the caller prints the file it could not read.
auth_for_request() {  # <request-id> -> auth-id
  local dir f id auth_json request
  dir=$(auth_store_dir)
  [ -d "$dir" ] || return 0
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then return 2; fi
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    id=${f##*/}
    id=${id%.json}
    auth_json=$(FM_HOME="$FM_HOME" FM_LANDING_AUTH_DIR="$dir" \
      "$SCRIPT_DIR/fm-landing-authorization.sh" inspect "$id") || return 2
    request=$(printf '%s' "$auth_json" | jq -r '.request_id') || return 2
    [ "$request" = "$1" ] || continue
    printf '%s\n' "$id"
    return 0
  done
  return 0
}

cmd_close() {  # <request-id> <disposition> [<authorization>] [<target-ref>] [<target-generation>]
  local rid=$1 disp=$2 auth_id=${3:-} target_ref=${4:-} target_gen=${5:-}
  local rec state minted rc auth_json dir head item plan_kind plan_mode plan_head plan_ref plan_repo plan_pr base_ref
  local clone project observed verification

  require_record "$rid"; rec=$RECORD
  state=$(printf '%s' "$rec" | jq -r '.state')
  if [ "$state" != "resumed" ]; then
    printf '%s: request %s is %s; only a resumed request can be closed\n' \
      "$FM_OUTBOUND_TOKEN_MISMATCH" "$rid" "$state" >&2
    exit 3
  fi

  # A CLOSURE MAY NOT OMIT AN EFFECT IT HAD. Naming the authority is not a
  # courtesy flag: if it were optional, every post-effect closure could become
  # an effect-free one by leaving it out, and the verification below would be
  # skipped precisely when it matters. So the store is asked, not the caller.
  minted=$(auth_for_request "$rid"); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s: the landing authorization store could not be read, so it is unknown whether %s had an effect authorized\n' \
      "$FM_OUTBOUND_TOKEN_UNREADABLE" "$rid" >&2
    exit 4
  fi
  if [ -n "$minted" ] && [ -z "$auth_id" ]; then
    printf '%s: %s had landing authorization %s minted for it, so this closure must name it and the generation the effect produced\n' \
      "$FM_OUTBOUND_TOKEN_CLOSURE_UNPROVEN" "$rid" "$minted" >&2
    printf 'Closing on a disposition sentence alone would record a landing nobody observed.\n' >&2
    exit 3
  fi

  if [ -n "$auth_id" ]; then
    [ -n "$target_ref" ] && [ -n "$target_gen" ] \
      || die "--authorization needs --target-ref and --target-generation naming what the effect produced" 2
    dir=$(auth_store_dir)
    auth_json=$(FM_HOME="$FM_HOME" FM_LANDING_AUTH_DIR="$dir" \
      "$SCRIPT_DIR/fm-landing-authorization.sh" inspect "$auth_id"); rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"

    # THE CHAIN, not the caller's word about it. An authority for another
    # request, another item, or another head is foreign to this closure however
    # valid it is in its own right.
    head=$(printf '%s' "$rec" | jq -r '.identity.head')
    item=$(printf '%s' "$rec" | jq -r '.identity.item')
    printf '%s' "$auth_json" | jq -e --arg r "$rid" --arg h "$head" --arg i "$item" \
      '.request_id == $r and .grant.head == $h and .grant.item == $i' >/dev/null 2>&1 \
      || { printf '%s: authorization %s does not belong to request %s at head %s\n' \
             "$FM_OUTBOUND_TOKEN_AUTHORITY_FOREIGN" "$auth_id" "$rid" "$head" >&2
           printf 'Nothing was written.\n' >&2; exit 3; }

    # SPENT AND APPLIED. A granted authority is permission that was never used,
    # and a spend that failed or is still in flight is not a landing.
    printf '%s' "$auth_json" | jq -e \
      '.state == "spent" and .spend.outcome == "applied"' >/dev/null 2>&1 \
      || { printf '%s: authorization %s is %s and its act is %s; only a spent, applied authority closes an effect\n' \
             "$FM_OUTBOUND_TOKEN_CLOSURE_UNPROVEN" "$auth_id" \
             "$(printf '%s' "$auth_json" | jq -r '.state // "unreadable"')" \
             "$(printf '%s' "$auth_json" | jq -r '.spend.outcome // "unrecorded"')" >&2
           exit 3; }

    plan_kind=$(printf '%s' "$auth_json" | jq -r '.effect.kind // ""')
    plan_mode=$(printf '%s' "$auth_json" | jq -r '.effect.mode // ""')
    plan_head=$(printf '%s' "$auth_json" | jq -r '.grant.head // ""')
    if [ "$plan_kind" = local-fast-forward ]; then
      plan_ref=$(printf '%s' "$auth_json" | jq -r '.effect.target_ref // ""')
      [ -n "$plan_ref" ] && [ "$target_ref" = "$plan_ref" ] \
        || { printf '%s: closure target %s is not the authorized effect target %s\n' \
               "$FM_OUTBOUND_TOKEN_CLOSURE_UNPROVEN" "$target_ref" "${plan_ref:-unobserved}" >&2
             printf 'Nothing was written.\n' >&2; exit 3; }
    elif [ "$plan_kind" = pr-merge ]; then
      plan_repo=$(printf '%s' "$auth_json" | jq -r '.effect.repo // ""')
      plan_pr=$(printf '%s' "$auth_json" | jq -r '.effect.pr // ""')
      [ -n "$plan_repo" ] && [ -n "$plan_pr" ] \
        || { printf '%s: the consumed merge plan does not identify its pull request\n' \
               "$FM_OUTBOUND_TOKEN_CLOSURE_UNPROVEN" >&2; exit 4; }
      # fm-retrieval-audit: not-a-collection - the repository and pull request number select exactly one pull request object.
      base_ref=$(obs gh api "repos/$plan_repo/pulls/$plan_pr" --jq '.base.ref') || base_ref=''
      [ -n "$base_ref" ] && [ "$(printf '%s\n' "$base_ref" | wc -l | tr -d ' ')" -eq 1 ] \
        || { printf '%s: the base ref for %s#%s could not be observed exactly once\n' \
               "$FM_OUTBOUND_TOKEN_REF_UNOBSERVED" "$plan_repo" "$plan_pr" >&2; exit 4; }
      plan_ref="refs/heads/$base_ref"
      git check-ref-format "$plan_ref" >/dev/null 2>&1 \
        || { printf '%s: the observed merge target %s is not a valid ref\n' \
               "$FM_OUTBOUND_TOKEN_REF_UNOBSERVED" "$plan_ref" >&2; exit 4; }
      [ "$target_ref" = "$plan_ref" ] \
        || { printf '%s: closure target %s is not the merge plan target %s\n' \
               "$FM_OUTBOUND_TOKEN_CLOSURE_UNPROVEN" "$target_ref" "$plan_ref" >&2
             printf 'Nothing was written.\n' >&2; exit 3; }
    else
      printf '%s: authorization %s carries unsupported effect kind %s\n' \
        "$FM_OUTBOUND_TOKEN_CLOSURE_UNPROVEN" "$auth_id" "${plan_kind:-unobserved}" >&2
      exit 4
    fi

    # RE-OBSERVE THE TARGET. This is the step the disposition sentence was
    # standing in for.
    project=$(printf '%s' "$rec" | jq -r '.identity.project')
    clone=$(project_dir "$project")
    [ -n "$clone" ] && [ -d "$clone" ] \
      || { printf '%s: the governed clone for %s could not be located, so the generation %s reports could not be observed\n' \
             "$FM_OUTBOUND_TOKEN_CLONE_UNREADABLE" "$project" "$target_ref" >&2; exit 4; }
    observed=$(obs git --no-optional-locks -C "$clone" rev-parse --verify "$target_ref^{commit}") || observed=''
    [ -n "$observed" ] \
      || { printf '%s: %s could not be read in the governed clone, so this closure cannot say where the effect landed\n' \
             "$FM_OUTBOUND_TOKEN_REF_UNOBSERVED" "$target_ref" >&2; exit 4; }
    if [ "$observed" != "$target_gen" ]; then
      printf '%s: %s is at %s, not the %s this closure claims the effect produced\n' \
        "$FM_OUTBOUND_TOKEN_CLOSURE_UNPROVEN" "$target_ref" "$observed" "$target_gen" >&2
      printf 'Nothing was written.\n' >&2
      exit 3
    fi

    # THE STRICT CASE. A fast-forward landing makes the target exactly the head
    # it landed, so here the generation is checkable against the authority and
    # is not merely observed.
    verification=observed
    if [ "$plan_kind" = local-fast-forward ] || [ "$plan_mode" = ff-only ]; then
      if [ "$target_gen" != "$plan_head" ]; then
        printf '%s: a fast-forward landing of %s must leave %s at that head, and it is at %s\n' \
          "$FM_OUTBOUND_TOKEN_CLOSURE_UNPROVEN" "$plan_head" "$target_ref" "$target_gen" >&2
        printf 'Something other than the authorized act moved this ref. Nothing was written.\n' >&2
        exit 3
      fi
      verification=exact
    fi

    rec=$(printf '%s' "$rec" | jq --arg d "$disp" --arg n "$(now_iso)" \
      --arg a "$auth_id" --arg r "$target_ref" --arg g "$target_gen" --arg v "$verification" \
      '.disposition = {outcome:$d, at:$n,
                       effect:{authorization:$a, target_ref:$r,
                               target_generation:$g, verification:$v}}
       | .state = "closed" | .updated = $n')
    record_write "$rid" "$rec" || die "could not write the correlation record" 4
    printf 'closed: %s - %s (%s at %s, %s)\n' "$rid" "$disp" "$target_ref" "$target_gen" "$verification"
    return 0
  fi

  # No effect was authorized for this request, and the record says so explicitly
  # rather than leaving an absent field to be read either way.
  rec=$(printf '%s' "$rec" | jq --arg d "$disp" --arg n "$(now_iso)" \
    '.disposition = {outcome:$d, at:$n, effect:null} | .state = "closed" | .updated = $n')
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
    RID=; DISP=; AUTH=; TREF=; TGEN=
    while [ $# -gt 0 ]; do
      case $1 in
        --request) RID=${2:-}; shift 2 ;;
        --disposition) DISP=${2:-}; shift 2 ;;
        --authorization) AUTH=${2:-}; shift 2 ;;
        --target-ref) TREF=${2:-}; shift 2 ;;
        --target-generation) TGEN=${2:-}; shift 2 ;;
        *) die "unknown option '$1'" ;;
      esac
    done
    [ -n "$RID" ] && [ -n "$DISP" ] || die "close needs --request and --disposition"
    cmd_close "$RID" "$DISP" "$AUTH" "$TREF" "$TGEN"
    ;;
  correct)
    RID=
    while [ $# -gt 0 ]; do
      case $1 in
        --request) RID=${2:-}; shift 2 ;;
        *) die "unknown option '$1'" ;;
      esac
    done
    [ -n "$RID" ] || die "correct needs --request"
    cmd_correct "$RID"
    ;;
  declare)
    ITEM=; GATE=; HEAD=
    while [ $# -gt 0 ]; do
      case $1 in
        --gate) GATE=${2:-}; shift 2 ;;
        --head) HEAD=${2:-}; shift 2 ;;
        -*) die "unknown option '$1'" ;;
        *) [ -z "$ITEM" ] || die "unexpected argument '$1'"; ITEM=$1; shift ;;
      esac
    done
    [ -n "$ITEM" ] && [ -n "$GATE" ] && [ -n "$HEAD" ] \
      || die "declare needs <item-id> --gate <gate> --head <sha>"
    cmd_declare "$ITEM" "$GATE" "$HEAD"
    ;;
  quarantine)
    RID=; RULING=
    while [ $# -gt 0 ]; do
      case $1 in
        --request) RID=${2:-}; shift 2 ;;
        --ruling) RULING=${2:-}; shift 2 ;;
        *) die "unknown option '$1'" ;;
      esac
    done
    [ -n "$RID" ] && [ -n "$RULING" ] || die "quarantine needs --request and --ruling"
    cmd_quarantine "$RID" "$RULING"
    ;;
  show)
    [ $# -gt 0 ] || die "show needs a request id"
    record_read "$1" || die "no readable record for '$1'" 4
    ;;
  *) die "unknown command '$CMD'" ;;
esac
