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

# Three-valued on purpose: absent and unreadable are different answers, and only
# the caller knows which of them is safe in its context.
record_valid_for_id() {
  local raw=$1 expected=$2 state stored gate project repo item pr head computed
  printf '%s' "$raw" | jq -e --arg s "$FM_OUTBOUND_RECORD_SCHEMA" \
    '.schema == $s' >/dev/null 2>&1 || return 1
  state=$(printf '%s' "$raw" | jq -er '.state // empty') || return 1
  fm_outbound_record_state_valid "$state" || return 1
  stored=$(printf '%s' "$raw" | jq -er '.request_id // empty') || return 1
  gate=$(printf '%s' "$raw" | jq -er '.identity.gate // empty') || return 1
  project=$(printf '%s' "$raw" | jq -er '.identity.project // empty') || return 1
  repo=$(printf '%s' "$raw" | jq -er '.identity.repo // empty') || return 1
  item=$(printf '%s' "$raw" | jq -er '.identity.item // empty') || return 1
  pr=$(printf '%s' "$raw" | jq -r '.identity.pr // "-"') || return 1
  head=$(printf '%s' "$raw" | jq -er '.identity.head // empty') || return 1
  fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" \
    >/dev/null 2>&1 || return 1
  computed=$(fm_outbound_request_id "$gate" "$project" "$repo" "$item" "$pr" "$head") \
    || return 1
  [ "$stored" = "$expected" ] && [ "$computed" = "$expected" ]
}

record_read() {  # <request-id> -> json on stdout; 1 absent, 2 unreadable
  local path raw
  path=$(record_path "$1")
  [ -f "$path" ] || return 1
  raw=$(cat "$path" 2>/dev/null) || return 2
  record_valid_for_id "$raw" "$1" || return 2
  printf '%s\n' "$raw"
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

pr_head() {  # <pr-url> -> sha or empty
  local url=$1 slug num
  case $url in *://*/*/*/pull/*) ;; *) return 0 ;; esac
  slug=$(printf '%s' "$url" | sed -n 's#.*://[^/]*/\([^/]*/[^/]*\)/pull/[0-9]*.*#\1#p')
  num=$(printf '%s' "$url" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p')
  [ -n "$slug" ] && [ -n "$num" ] || return 0
  probe_budget || return 0
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
observe_head() {  # <item> <pr-url> <project> -> sha or empty
  local item=$1 pr_url=$2 project=$3 head
  head=$(declared_field "$item" head)
  fm_outbound_is_sha "$head" && { printf '%s\n' "$head"; return 0; }
  if [ -n "$pr_url" ]; then
    head=$(pr_head "$pr_url")
    fm_outbound_is_sha "$head" && { printf '%s\n' "$head"; return 0; }
  fi
  if [ -n "$project" ] && [ -d "$PROJECTS/$project/.git" ]; then
    head=$(branch_head "$PROJECTS/$project" "$item")
    fm_outbound_is_sha "$head" && { printf '%s\n' "$head"; return 0; }
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

sol_artifact_present() {  # <request-id> -> comment id
  local rid=$1 out
  read_sol_config || return 3
  probe_budget || return 2
  out=$(obs gh api "repos/$SOL_REPO/issues/$SOL_ISSUE/comments" \
    --paginate --jq ".[] | select(.body | contains(\"$rid\")) | .id") || return 2
  if [ -n "$out" ]; then printf '%s\n' "$out" | head -1; return 0; fi
  return 1
}

pr_artifact_present() {  # <venue-slug> <head-sha> -> pull request number
  local venue=$1 sha=$2 out
  [ -n "$venue" ] || return 3
  [ -n "$sha" ] || return 2
  probe_budget || return 2
  out=$(obs gh api "repos/$venue/commits/$sha/pulls" \
    --jq '.[] | select(.state == "open") | .number') || return 2
  if [ -n "$out" ]; then printf '%s\n' "$out" | head -1; return 0; fi
  return 1
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

SWEEP=
row_json() {  # <item> <gate> <tier> <channel> <project> <repo> <head> <rid> <verdict> <token> <missing> <artifact> <stale>
  jq -n --arg item "$1" --arg gate "$2" --arg tier "$3" --arg channel "$4" \
    --arg project "$5" --arg repo "$6" --arg head "$7" --arg rid "$8" \
    --arg verdict "$9" --arg token "${10}" --arg missing "${11}" \
    --arg artifact "${12}" --argjson stale "${13:-0}" \
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
      superseded_records:$stale}'
}

sweep() {
  local rows count i rec verdict gate tier item project pr_url pr_ref head
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
    cls=$(fm_outbound_classify_record "$rec")
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
    [ -n "$gate" ] || gate=$(declared_field "$item" gate)
    channel=$(fm_outbound_gate_channel "$gate")
    head=$(observe_head "$item" "$pr_url" "$project")

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
    missing=$(fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" || true)
    if [ -n "$missing" ]; then
      if [ -z "$head" ]; then token=$FM_OUTBOUND_TOKEN_HEAD_UNOBSERVED
      else token=$FM_OUTBOUND_TOKEN_INCOMPLETE; fi
      row_json "$item" "$gate" "$tier" "$channel" "$project" "$repo" "$head" "" \
        defect "$token" "$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')" "" 0 >> "$rows"
      continue
    fi

    pr_ref=$(printf '%s' "$rec" | jq -r '.pr_url // "-"')
    rid=$(fm_outbound_request_id "$gate" "$project" "$repo" "$item" "$pr_ref" "$head") || rid=

    if [ "$channel" = "pull-request" ]; then
      present=$(pr_artifact_present "$venue" "$head"); rc=$?
    else
      present=$(sol_artifact_present "$rid"); rc=$?
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

  row=$(jq -s '.' < "$rows")
  if probes_capped; then capped=true; else capped=false; fi
  SWEEP=$(jq -n --argjson rows "$row" --argjson capped "$capped" \
    '{schema:"fm-outbound-sweep.v1",readable:true,capped:$capped,rows:$rows,reason:null}')
}

# --- rendering and verdict ---------------------------------------------------

render_human() {
  local defects unevaluable satisfied
  if [ "$(printf '%s' "$SWEEP" | jq -r '.readable')" != "true" ]; then
    printf 'UNEVALUABLE - %s\n' "$(printf '%s' "$SWEEP" | jq -r '.reason')"
    return
  fi
  defects=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="defect")] | length')
  unevaluable=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="unevaluable")] | length')
  satisfied=$(printf '%s' "$SWEEP" | jq '[.rows[] | select(.verdict=="satisfied")] | length')
  printf 'outbound artifacts: %s satisfied, %s defect, %s unevaluable\n\n' \
    "$satisfied" "$defects" "$unevaluable"
  printf '%s' "$SWEEP" | jq -r '.rows[] |
    "  \(.verdict | ascii_upcase)  \(.item)",
    "         gate: \(.gate // "UNTYPED") · channel: \(.channel // "unknown") · recognised: \(.tier)",
    "         head: \(.head // "unobserved") · artifact: \(.artifact // "none") · \(.token)",
    (if .missing then "         incomplete binding, missing: \(.missing)" else empty end),
    (if .superseded_records > 0 then "         \(.superseded_records) earlier request(s) bound to a different head" else empty end)'
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
  local item=$1 rid=$2 head=$3 f other rec
  [ -d "$RECORD_DIR" ] || return 0
  for f in "$RECORD_DIR"/*.json; do
    [ -f "$f" ] || continue
    rec=$(cat "$f" 2>/dev/null) || continue
    printf '%s' "$rec" | jq -e --arg i "$item" --arg h "$head" \
      '.identity.item == $i and .identity.head != $h and .state != "closed" and .state != "superseded"' \
      >/dev/null 2>&1 || continue
    other=$(printf '%s' "$rec" | jq -r '.request_id')
    rec=$(printf '%s' "$rec" | jq --arg s "$rid" --arg n "$(now_iso)" \
      '.state = "superseded" | .superseded_by = $s | .updated = $n')
    record_write "$other" "$rec" || true
    printf 'superseded: %s (bound to a head that moved)\n' "$other"
  done
}

cmd_emit() {
  local item=$1 rationale=$2 dry=$3
  local rec gate channel project pr_url pr_ref head venue missing rid record
  local attempt delay body found existing dedupe_rc retry_rc

  read_snapshot || die "fleet backlog could not be read" 4
  rec=$(printf '%s' "$SNAPSHOT" | jq -c --arg i "$item" \
    '.backlog.records[] | select(.structured == true and .id == $i)' | head -1)
  [ -n "$rec" ] || die "no durable backlog record for '$item'" 4

  gate=$(fm_outbound_classify_record "$rec" | cut -f2)
  [ -n "$gate" ] || gate=$(declared_field "$item" gate)
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
  head=$(observe_head "$item" "$pr_url" "$project")

  if ! read_sol_config; then
    printf '%s: config/sol-control.json is absent or incomplete, so no request can be addressed.\n' \
      "$FM_OUTBOUND_TOKEN_UNCONFIGURED" >&2
    printf '%s remains waiting with no artifact; this refusal does not clear it.\n' "$item" >&2
    exit 4
  fi
  venue=$SOL_REPO

  missing=$(fm_outbound_binding_missing "$gate" "$project" "$venue" "$item" "$head" || true)
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
      "$item" "$pr_ref" "$head" "$SOL_REPO#$SOL_ISSUE" "$(now_iso)")
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

  supersede_other_heads "$item" "$rid" "$head"

  # Dedupe against the forge FIRST. This is both ordinary duplicate suppression
  # and the crash-recovery path, because they are the same question: does an
  # artifact carrying this id already exist?
  found=$(sol_artifact_present "$rid"); dedupe_rc=$?
  if [ "$dedupe_rc" -eq 0 ]; then
    if existing=$(record_read "$rid"); then
      record=$(printf '%s' "$existing" | jq --arg c "$found" --arg n "$(now_iso)" \
        '.comment_id = $c | .state = (if .state == "emitting" then "emitted" else .state end) | .updated = $n')
    else
      record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$venue" \
        "$item" "$pr_ref" "$head" "$SOL_REPO#$SOL_ISSUE" "$(now_iso)")
      record=$(printf '%s' "$record" | jq --arg c "$found" '.comment_id = $c | .state = "emitted"')
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

  if ! record=$(record_read "$rid"); then
    record=$(fm_outbound_record_new "$rid" "$gate" "$channel" "$project" "$venue" \
      "$item" "$pr_ref" "$head" "$SOL_REPO#$SOL_ISSUE" "$(now_iso)")
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
    if jq -n --arg b "$body" '{body:$b}' | obs gh api \
      "repos/$SOL_REPO/issues/$SOL_ISSUE/comments" --input - >/dev/null; then
      record=$(printf '%s' "$record" | jq --arg n "$(now_iso)" '.state = "emitted" | .updated = $n')
      if found=$(sol_artifact_present "$rid"); then
        record=$(printf '%s' "$record" | jq --arg c "$found" '.comment_id = $c')
      fi
      record_write "$rid" "$record" || die "could not write the correlation record" 4
      printf 'requested: %s on %s#%s\n' "$rid" "$SOL_REPO" "$SOL_ISSUE"
      return 0
    fi
    found=$(sol_artifact_present "$rid"); retry_rc=$?
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
  if [ "$rc" -ne 0 ]; then
    printf '%s: the record for %s could not be read\n' \
      "$FM_OUTBOUND_TOKEN_UNREADABLE" "$1" >&2
    exit 4
  fi
}

require_record_applicable_now() {  # <request-id> <record-json>
  local rid=$1 rec=$2 item current gate channel project repo pr_url pr_ref head missing
  local stored_identity current_identity stored_venue current_venue
  item=$(printf '%s' "$rec" | jq -r '.identity.item')
  read_snapshot || die "fleet backlog could not be read while validating $rid" 4
  current=$(printf '%s' "$SNAPSHOT" | jq -c --arg i "$item" \
    '.backlog.records[] | select(.structured == true and .id == $i)' | head -1)
  [ -n "$current" ] || die "waiting item $item could not be observed while validating $rid" 4
  gate=$(fm_outbound_classify_record "$current" | cut -f2)
  [ -n "$gate" ] || gate=$(declared_field "$item" gate)
  channel=$(fm_outbound_gate_channel "$gate")
  [ -n "$channel" ] || die "the current gate for $item could not be observed" 4
  project=$(printf '%s' "$current" | jq -r '.repo // ""')
  pr_url=$(printf '%s' "$current" | jq -r '.pr_url // ""')
  pr_ref=$(printf '%s' "$current" | jq -r '.pr_url // "-"')
  head=$(observe_head "$item" "$pr_url" "$project")
  if [ "$channel" = "pull-request" ]; then
    repo=$(project_venue "$project" \
      "$(printf '%s' "$current" | jq -r '.contribution_venue // ""')")
  else
    read_sol_config || die "the configured control repository could not be observed" 4
    repo=$SOL_REPO
    current_venue="$SOL_REPO#$SOL_ISSUE"
  fi
  missing=$(fm_outbound_binding_missing "$gate" "$project" "$repo" "$item" "$head" || true)
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
  local rid=$1 comment=$2 issue=$3 rec state venue_repo venue_issue artifact body request_comment verdict
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
  printf '%s\n' "$body" | grep -Fqx "$FM_OUTBOUND_RULING_MARKER $rid" \
    && printf '%s\n' "$body" | grep -Fqx "gate: $(printf '%s' "$rec" | jq -r '.identity.gate')" \
    && printf '%s\n' "$body" | grep -Fqx "project: $(printf '%s' "$rec" | jq -r '.identity.project')" \
    && printf '%s\n' "$body" | grep -Fqx "repo: $(printf '%s' "$rec" | jq -r '.identity.repo')" \
    && printf '%s\n' "$body" | grep -Fqx "item: $(printf '%s' "$rec" | jq -r '.identity.item')" \
    && printf '%s\n' "$body" | grep -Fqx "pull-request: $(printf '%s' "$rec" | jq -r '.identity.pr // "-"')" \
    && printf '%s\n' "$body" | grep -Fqx "exact-head: $(printf '%s' "$rec" | jq -r '.identity.head')" \
    || {
      printf '%s: comment %s does not carry the exact request identity\n' \
        "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" >&2
      exit 3
    }
  verdict=$(printf '%s\n' "$body" | sed -n 's/^verdict: //p' | head -1)
  [ -n "$verdict" ] || {
    printf '%s: comment %s has no ruling verdict\n' "$FM_OUTBOUND_TOKEN_MISMATCH" "$comment" >&2
    exit 3
  }
  rec=$(printf '%s' "$rec" | jq --arg c "$comment" --arg v "$verdict" --arg n "$(now_iso)" \
    '.ruling = {comment_id:$c, verdict:$v, observed:$n} | .state = "ruled" | .updated = $n')
  record_write "$rid" "$rec" || die "could not write the correlation record" 4
  printf 'ruled: %s wakes %s\n' "$rid" "$(printf '%s' "$rec" | jq -r '.identity.item')"
}

cmd_poll() {
  local comments row rid comment rc failed=0 poll_record poll_state out
  read_sol_config || return 0
  probe_budget || die "the ruling poll probe budget is exhausted" 4
  comments=$(obs gh api "repos/$SOL_REPO/issues/$SOL_ISSUE/comments" --paginate \
    --jq '.[] | [.id, .body] | @base64') || die "ruling comments could not be observed" 4
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    comment=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[0] | tostring') \
      || { failed=4; continue; }
    rid=$(printf '%s' "$row" | jq -Rr '@base64d | fromjson | .[1]' \
      | sed -n "s/^$FM_OUTBOUND_RULING_MARKER \(fm-ob-[0-9a-f]*\)$/\1/p" | head -1)
    [ -n "$rid" ] || continue
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
  done <<EOF
$comments
EOF
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
