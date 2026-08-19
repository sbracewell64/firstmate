#!/usr/bin/env bash
# Typed SSSF planning-transition consumer for FirstMate (increment FM-FP-001).
#
# FirstMate consumes typed planning transitions. It never derives execution
# authority from planning prose. This adapter reads one append-only feed,
# validates one event mechanically, and surfaces it through the EXISTING
# authenticated custom-check/watch path. It is not a second polling daemon and
# it NEVER creates a task: even an ACTIVE event only becomes engineering
# eligibility that ordinary FirstMate admission must still grant.
#
# Usage:
#   fm-sssf-planning-awareness.sh install     arm the registered custom check
#   fm-sssf-planning-awareness.sh check       one bounded poll (watcher entry)
#   fm-sssf-planning-awareness.sh inspect     print the exact pending event JSON
#   fm-sssf-planning-awareness.sh acknowledge <event-id>
#   fm-sssf-planning-awareness.sh retire      remove check, cursor, and residue
#
# `install` refuses unless FM_SSSF_PLANNING_ENABLE=1 is set in its environment.
# Live enablement against the production SSSF feed is a separate, explicitly
# gated step that this increment does not perform (FP-001, "Current
# restrictions"), so arming is deliberate rather than incidental.
#
# CHECK-MODE OUTPUT IS THE OBSERVATION, and it carries three values, never two
# (bin/fm-verify-lib.sh owns the type). The watcher captures stdout only and
# turns any nonempty single line into a durable wake:
#
#   (no output)                        observed-good: no unseen valid event.
#   sssf-planning pending ...          observed-good: one bounded event awaits
#                                      handling under the sssf-planning-awareness
#                                      skill. Not authority; not a task.
#   sssf-planning continuity failure=  observed-bad: the feed's append-only
#   sssf-planning security failure=    contract or local state integrity broke.
#   sssf-planning invalid-event ...    observed-bad: the record is malformed.
#   sssf-planning stale-or-missing-authority ...
#                                      observed-bad: a named authoritative ref
#                                      does not exist at the named source commit.
#   sssf-planning could-not-observe reason=...
#                                      THE THIRD VALUE: the observation did not
#                                      happen. Never silence, and never a defect
#                                      claim against the feed.
#
# Nothing here ever advances the cursor on any value but a handled event, and
# nothing ever resets it to the current tail.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REPO=${FM_SSSF_PLANNING_REPO:-sbracewell64/inkwell-agent-sandboxes-and-software-factory}
REF=${FM_SSSF_PLANNING_REF:-planning/future-sssf}
FEED=${FM_SSSF_PLANNING_FEED:-docs/development/PLANNING_EVENTS.jsonl}
ID=sssf-planning
CURSOR="$STATE/$ID.cursor"
PENDING="$STATE/$ID.pending"
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
STAGING_PREFIX=".sssf-planning-"
MAX_FEED_BYTES=${FM_SSSF_PLANNING_MAX_FEED_BYTES:-1048576}
MAX_EVENT_BYTES=${FM_SSSF_PLANNING_MAX_EVENT_BYTES:-16384}
# A single check must finish inside the watcher's FM_CHECK_TIMEOUT, so the
# per-event remote work is bounded by construction rather than by trust in the
# producer: authoritative_refs has no upper bound in the producer schema.
MAX_REFS=${FM_SSSF_PLANNING_MAX_REFS:-32}
MAX_INCREMENTS=${FM_SSSF_PLANNING_MAX_INCREMENTS:-32}
# A wall-clock budget, because MAX_REFS bounds call count and not elapsed time.
# The whole-check deadline stays below the watcher's FM_CHECK_TIMEOUT (30s) so
# a hung endpoint surfaces as a typed could-not-observe line instead of the
# watcher killing the check into empty output, which would read as "nothing
# new". Each remote call is additionally bounded so no single connection can
# consume the whole budget.
DEADLINE_SECS=${FM_SSSF_PLANNING_DEADLINE:-20}
CALL_TIMEOUT_SECS=${FM_SSSF_PLANNING_CALL_TIMEOUT:-8}
# SHA-256 of the empty input. A constant, so an empty-cursor read cannot fail
# for want of a writable temp directory.
EMPTY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

# The closed planning-state set (SSSF docs/development/PLANNING_LIFECYCLE.md).
# Only ACTIVE is engineering-intake eligible; every other state is awareness.
# An unrecognized state is refused rather than defaulted, so a state this
# consumer has never heard of can never arrive as awareness OR as activation.
PLANNING_STATES='EXPLORE PRESERVE CANDIDATE DECIDED SEQUENCED ACTIVE PROVEN DEFERRED REJECTED SUPERSEDED'

usage() { # <exit-code>
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
  exit "${1:-2}"
}

die() { printf 'sssf-planning: error: %s\n' "$1" >&2; exit 1; }

# Check-mode reporters. Each prints exactly one line on stdout and stops the
# poll; the watcher turns that line into one durable wake.
emit() { printf 'sssf-planning %s\n' "$1"; }
unobserved() { emit "could-not-observe reason=$1"; exit 0; }

planning_state_known() {
  case " $PLANNING_STATES " in *" $1 "*) return 0 ;; esac
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

have_tools() {
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || return 1
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
    || command -v perl >/dev/null 2>&1 || return 1
}

state_dir_usable() { [ -d "$STATE" ] && [ ! -L "$STATE" ]; }

# The feed is untrusted input interpolated into a request path, so this is a
# character WHITELIST rather than a list of known-bad characters: a ref that
# cannot express `?`, `&`, `%`, or `#` cannot inject a competing ref= query
# parameter and cannot spell an encoded traversal past docs/. Dot-led,
# doubled, and empty segments are refused on top of the character set.
safe_doc_ref() {
  [[ "$1" =~ ^docs/[A-Za-z0-9._/-]+$ ]] || return 1
  case "/$1/" in *'//'*|*'/.'*) return 1 ;; esac
  return 0
}

# Bound one subprocess in wall-clock time, the same way bin/fm-watch.sh bounds
# a whole check: timeout(1), then gtimeout, then a perl alarm. Exit 124 means
# the bound fired.
run_bounded() { # <seconds> <command...>
  if command -v timeout >/dev/null 2>&1; then
    timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { exec @ARGV; exit 127 } my $stop = sub { kill "TERM", $pid; select undef, undef, undef, 0.2; kill "KILL", $pid; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; alarm $t; waitpid $pid, 0; my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8)' "$@"
  fi
}

# Every remote call passes through here: bounded per call, and refused outright
# once the whole-check deadline is spent. 124 in either shape means the clock
# decided, and the caller must type it as could-not-observe, never as a verdict
# about the thing that was not read.
remote() { # <command...>
  local left=$((DEADLINE_SECS - SECONDS))
  [ "$left" -ge 1 ] || return 124
  [ "$left" -le "$CALL_TIMEOUT_SECS" ] || left=$CALL_TIMEOUT_SECS
  run_bounded "$left" "$@"
}

# Prove one repository path exists as a file at one exact commit. Reads the
# bounded contents metadata rather than the blob: existence is the question, and
# a metadata response cannot be made large by the thing it describes.
ref_exists() { # <commit> <path>
  remote gh api "repos/$REPO/contents/$2?ref=$1" --jq '.sha' >/dev/null 2>&1  # fm-retrieval-audit: not-a-collection - one named path's contents metadata at one exact commit; there is no extent to enumerate
}

commit_reachable() { # <commit>
  remote gh api "repos/$REPO/commits/$1" --jq '.sha' >/dev/null 2>&1  # fm-retrieval-audit: not-a-collection - one commit object's reachability; there is no extent to enumerate
}

# Download the feed with the transfer itself bounded, so an oversized or
# unbounded body cannot be written to disk before the size is judged. Reading
# one byte past the cap is what distinguishes "at the cap" from "over" it.
fetch_feed() { # <destination>
  local status
  # fm-retrieval-audit: not-a-collection - one named feed file at one ref fetched whole to a file; the caller judges the cap and types over-cap as a continuity failure, never as absence
  remote gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$REPO/contents/$FEED?ref=$REF" 2>/dev/null \
    | head -c "$((MAX_FEED_BYTES + 1))" > "$1"
  status=${PIPESTATUS[0]}
  return "$status"
}

read_cursor() {
  CURSOR_OFFSET=0
  CURSOR_HASH=$EMPTY_SHA256
  CURSOR_LAST=
  CURSOR_SEQUENCE=0
  [ -e "$CURSOR" ] || [ -L "$CURSOR" ] || return 0
  [ -f "$CURSOR" ] && [ ! -L "$CURSOR" ] || return 2
  local schema offset hash last sequence count
  schema=$(sed -n 's/^schema=//p' "$CURSOR")
  offset=$(sed -n 's/^offset=//p' "$CURSOR")
  hash=$(sed -n 's/^prefix_sha256=//p' "$CURSOR")
  last=$(sed -n 's/^last_event_id=//p' "$CURSOR")
  sequence=$(sed -n 's/^last_sequence=//p' "$CURSOR")
  count=$(grep -Ec '^(schema|offset|prefix_sha256|last_event_id|last_sequence)=' "$CURSOR" 2>/dev/null || true)
  [ "$schema" = fm-sssf-planning-cursor.v2 ] && [ "$count" -eq 5 ] || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  case "$sequence" in ''|*[!0-9]*) return 1 ;; esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  CURSOR_OFFSET=$offset
  CURSOR_HASH=$hash
  CURSOR_LAST=$last
  CURSOR_SEQUENCE=$sequence
}

write_cursor() { # <offset> <hash> <event-id> <sequence>
  local tmp
  state_dir_usable || return 1
  [ ! -L "$CURSOR" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/${STAGING_PREFIX}cursor.XXXXXX") || return 1
  {
    printf 'schema=fm-sssf-planning-cursor.v2\n'
    printf 'offset=%s\n' "$1"
    printf 'prefix_sha256=%s\n' "$2"
    printf 'last_event_id=%s\n' "$3"
    printf 'last_sequence=%s\n' "$4"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CURSOR"
}

pending_field() { # <field>
  local field=$1
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || return 1
  [ "$(grep -c "^$field=" "$PENDING" 2>/dev/null || true)" -eq 1 ] || return 1
  grep "^$field=" "$PENDING" | sed "s/^$field=//"
}

pending_summary() {
  local event kind target action
  event=$(pending_field event_id) || return 1
  kind=$(pending_field kind) || return 1
  target=$(pending_field to) || return 1
  action=$(pending_field actionability) || return 1
  printf 'sssf-planning pending event_id=%s kind=%s' "$event" "$kind"
  [ -z "$target" ] || printf ' to=%s' "$target"
  printf ' actionability=%s\n' "$action"
}

# Mechanical shape validation against the producer's published schema
# (SSSF docs/development/planning_event.schema.json). Deliberately no looser
# than the producer, and stricter where a looser reading could let an unknown
# state or an unbounded list through.
validate_event() { # <json-file>
  local file=$1 kind action target origin ref inc
  jq -e '
    type == "object"
    and .schema == "sssf-planning-event/v1"
    and (.event_id | type == "string")
    and (.source_commit | type == "string")
    and (.sequence | type == "number" and . >= 1 and . <= 1e15 and (. | floor) == .)
    and (.authoritative_refs | type == "array" and length > 0)
  ' "$file" >/dev/null 2>&1 || return 1
  [[ "$(jq -r '.event_id' "$file")" =~ ^plan-[0-9]{8}-[0-9]{4}$ ]] || return 1
  [[ "$(jq -r '.source_commit' "$file")" =~ ^[0-9a-f]{40}$ ]] || return 1
  # The sequence must extract in plain digit form: an exponent-form declaration
  # is a malformed record, not a feed-continuity defect, and typing it here is
  # what keeps the later ordering comparison an ordering comparison.
  [[ "$(jq -r '.sequence' "$file")" =~ ^[0-9]+$ ]] || return 1
  jq -e --argjson n "$MAX_REFS" '.authoritative_refs | length <= $n' "$file" >/dev/null 2>&1 || return 1
  kind=$(jq -r '.kind // empty' "$file")
  action=$(jq -r '.actionability // empty' "$file")
  case "$kind" in
    bootstrap)
      # A snapshot synchronizes the cursor. It carries no edge and, by the
      # producer's own schema, can never be actionable.
      [ "$action" = awareness ] || return 1
      jq -e '(.states | type == "object" and length > 0)
        and (has("item_id") | not) and (has("from") | not) and (has("to") | not)' \
        "$file" >/dev/null 2>&1 || return 1
      while IFS= read -r target; do planning_state_known "$target" || return 1; done \
        < <(jq -r '.states[]' "$file")
      ;;
    transition)
      jq -e '(.item_id | type == "string") and (.from | type == "string") and (.to | type == "string")' \
        "$file" >/dev/null 2>&1 || return 1
      [[ "$(jq -r '.item_id' "$file")" =~ ^FUT-[0-9]{3}$ ]] || return 1
      origin=$(jq -r '.from' "$file")
      target=$(jq -r '.to' "$file")
      planning_state_known "$origin" || return 1
      planning_state_known "$target" || return 1
      [ "$origin" != "$target" ] || return 1
      if [ "$target" = ACTIVE ]; then
        # Engineering eligibility must name what it would activate. It still
        # activates nothing here.
        [ "$action" = engineering ] || return 1
        jq -e --argjson n "$MAX_INCREMENTS" \
          '(.increments | type == "array" and length > 0 and length <= $n)' \
          "$file" >/dev/null 2>&1 || return 1
        while IFS= read -r inc; do
          [[ "$inc" =~ ^[A-Z][A-Z0-9-]*[0-9][A-Z0-9-]*$ ]] || return 1
        done < <(jq -r '.increments[]' "$file")
      else
        [ "$action" = awareness ] || return 1
      fi
      ;;
    *) return 1 ;;
  esac
  while IFS= read -r ref; do safe_doc_ref "$ref" || return 1; done \
    < <(jq -r '.authoritative_refs[]' "$file")
}

# Prove every named authoritative document exists at the exact named source
# commit. Returns 0 proven, 1 observed missing, 2 could-not-observe, 3 the
# deadline decided. The distinction is structural rather than a parse of the
# vendor's error text: a ref that will not resolve at a commit that itself will
# not resolve says nothing about the ref, and a call the clock stopped says
# nothing about either.
verify_authority_refs() { # <json-file>
  local source ref status
  source=$(jq -r '.source_commit' "$1")
  while IFS= read -r ref; do
    status=0
    ref_exists "$source" "$ref" || status=$?
    [ "$status" -ne 0 ] || continue
    [ "$status" -ne 124 ] || return 3
    status=0
    commit_reachable "$source" || status=$?
    [ "$status" -ne 124 ] || return 3
    [ "$status" -eq 0 ] || return 2
    return 1
  done < <(jq -r '.authoritative_refs[]' "$1")
}

write_pending() { # <event-file> <from-offset> <to-offset> <to-prefix-hash>
  local tmp event kind action target sequence
  event=$(jq -r '.event_id' "$1")
  kind=$(jq -r '.kind' "$1")
  action=$(jq -r '.actionability' "$1")
  target=$(jq -r '.to // empty' "$1")
  sequence=$(jq -r '.sequence' "$1")
  [ ! -e "$PENDING" ] && [ ! -L "$PENDING" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/${STAGING_PREFIX}pending.XXXXXX") || return 1
  {
    printf 'schema=fm-sssf-planning-pending.v1\n'
    printf 'event_id=%s\nkind=%s\nto=%s\nactionability=%s\nsequence=%s\n' \
      "$event" "$kind" "$target" "$action" "$sequence"
    printf 'from_offset=%s\nto_offset=%s\nto_prefix_sha256=%s\n' "$2" "$3" "$4"
    printf 'event_json='
    jq -c . "$1"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$PENDING"
}

# Subshell ownership makes EXIT cleanup local to this check. A function RETURN
# cannot tear down staging while helpers are still executing.
cmd_check() (
  have_tools || unobserved gh-jq-or-sha256-unavailable
  mkdir -p "$STATE" 2>/dev/null || true
  state_dir_usable || unobserved state-directory-unavailable

  # An already-published generation is the whole answer: it is re-surfaced until
  # it is acknowledged, and nothing new is read past it.
  if [ -e "$PENDING" ] || [ -L "$PENDING" ]; then
    [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || { emit 'security failure=pending-unsafe'; exit 0; }
    pending_summary || emit 'security failure=pending-malformed'
    exit 0
  fi

  read_cursor
  case $? in
    0) ;;
    2) emit 'security failure=cursor-unsafe'; exit 0 ;;
    *) emit 'continuity failure=cursor-malformed'; exit 0 ;;
  esac

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-sssf-planning.XXXXXX") || unobserved staging-unavailable
  trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

  fetch_status=0
  fetch_feed "$tmp/feed" || fetch_status=$?
  feed_size=$(wc -c < "$tmp/feed" 2>/dev/null | tr -d ' ')
  case "$feed_size" in ''|*[!0-9]*) unobserved feed-size-unreadable ;; esac
  # Size decides before status: reading one byte past the cap closes the pipe,
  # so an oversized feed can surface as a transfer error that is not one.
  [ "$feed_size" -le "$MAX_FEED_BYTES" ] \
    || { emit "continuity failure=feed-too-large bytes=$feed_size"; exit 0; }
  [ "$fetch_status" -ne 124 ] || unobserved deadline
  [ "$fetch_status" -eq 0 ] || unobserved "source-unreachable repo=$REPO ref=$REF"

  # Truncation and prefix mutation are the append-only contract breaking. Each
  # is its own typed continuity failure, and neither advances the cursor.
  [ "$feed_size" -ge "$CURSOR_OFFSET" ] \
    || { emit "continuity failure=truncated offset=$CURSOR_OFFSET size=$feed_size"; exit 0; }
  head -c "$CURSOR_OFFSET" "$tmp/feed" > "$tmp/prefix" 2>/dev/null || unobserved prefix-unreadable
  actual=$(sha256_file "$tmp/prefix") || unobserved prefix-hash-unavailable
  [ "$actual" = "$CURSOR_HASH" ] \
    || { emit "continuity failure=prefix-changed offset=$CURSOR_OFFSET"; exit 0; }
  [ "$feed_size" -gt "$CURSOR_OFFSET" ] || exit 0

  tail -c "+$((CURSOR_OFFSET + 1))" "$tmp/feed" > "$tmp/remainder" 2>/dev/null \
    || unobserved remainder-unreadable
  # Take the first record as bytes. Its exact length, including its terminator,
  # is what the cursor advances by, so it is measured on the file rather than
  # round-tripped through a shell variable that would drop a NUL.
  head -n 1 "$tmp/remainder" > "$tmp/event.json" 2>/dev/null || unobserved record-unreadable
  bytes=$(wc -c < "$tmp/event.json" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) unobserved record-size-unreadable ;; esac
  # A record with no terminator is a partially appended write, not a record.
  [ "$(wc -l < "$tmp/event.json" | tr -d ' ')" -eq 1 ] \
    || { emit 'continuity failure=incomplete-record'; exit 0; }
  [ "$bytes" -le "$MAX_EVENT_BYTES" ] \
    || { emit "continuity failure=event-too-large bytes=$bytes"; exit 0; }

  validate_event "$tmp/event.json" \
    || { emit "invalid-event offset=$CURSOR_OFFSET"; exit 0; }

  event_id=$(jq -r '.event_id' "$tmp/event.json")
  sequence=$(jq -r '.sequence' "$tmp/event.json")
  # Ordered delivery, and a replay that cannot re-fire. A declared sequence that
  # does not advance means the feed was rewritten in place rather than appended
  # to, whatever its bytes say.
  [ "$sequence" -gt "$CURSOR_SEQUENCE" ] \
    || { emit "continuity failure=out-of-order sequence=$sequence last=$CURSOR_SEQUENCE"; exit 0; }
  [ "$event_id" != "$CURSOR_LAST" ] \
    || { emit "continuity failure=duplicate-event event_id=$event_id"; exit 0; }

  verify_authority_refs "$tmp/event.json"
  case $? in
    0) ;;
    2) unobserved "authority-unreadable event_id=$event_id" ;;
    3) unobserved deadline ;;
    *) emit "stale-or-missing-authority event_id=$event_id"; exit 0 ;;
  esac

  next=$((CURSOR_OFFSET + bytes))
  head -c "$next" "$tmp/feed" > "$tmp/next-prefix" 2>/dev/null || unobserved next-prefix-unreadable
  next_hash=$(sha256_file "$tmp/next-prefix") || unobserved next-prefix-hash-unavailable
  write_pending "$tmp/event.json" "$CURSOR_OFFSET" "$next" "$next_hash" \
    || { emit 'security failure=pending-publish'; exit 0; }
  pending_summary || emit 'security failure=pending-malformed'
)

cmd_inspect() {
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || die "no pending planning event"
  local line
  line=$(grep '^event_json=' "$PENDING" 2>/dev/null || true)
  [ -n "$line" ] || die "pending planning event is malformed"
  printf '%s\n' "${line#event_json=}"
}

cmd_acknowledge() {
  local expected=$1 event offset hash sequence
  event=$(pending_field event_id) || die "no valid pending planning event"
  [ "$event" = "$expected" ] || die "pending event identity mismatch"
  offset=$(pending_field to_offset) || die "pending end offset unavailable"
  hash=$(pending_field to_prefix_sha256) || die "pending end hash unavailable"
  sequence=$(pending_field sequence) || die "pending sequence unavailable"
  case "$offset" in ''|*[!0-9]*) die "pending end offset invalid" ;; esac
  case "$sequence" in ''|*[!0-9]*) die "pending sequence invalid" ;; esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "pending end hash invalid"
  write_cursor "$offset" "$hash" "$event" "$sequence" || die "could not advance planning cursor"
  rm -f -- "$PENDING" || die "could not retire pending planning event"
  printf 'acknowledged: %s\n' "$event"
}

cmd_install() {
  [ "${FM_SSSF_PLANNING_ENABLE:-0}" = 1 ] || die \
    "refusing to arm the planning check: live enablement is a separate gated step (set FM_SSSF_PLANNING_ENABLE=1 to arm deliberately)"
  have_tools || die "gh, jq, and a SHA-256 tool are required"
  mkdir -p "$STATE" 2>/dev/null || true
  state_dir_usable || die "state directory is unavailable"
  chmod 700 "$STATE" 2>/dev/null || true
  [ ! -e "$CHECK" ] && [ ! -L "$CHECK" ] || die "planning check already exists; retire before reinstalling"
  local adapter adapter_hash tmp adapter_q repo_q ref_q feed_q
  # The baked path must be absolute: the watcher runs the check from its own
  # working directory, and a path that resolves against a cwd would read as
  # adapter drift on every poll.
  adapter="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
  adapter_hash=$(sha256_file "$adapter") || die "cannot hash planning adapter"
  adapter_q=$(printf '%q' "$adapter")
  repo_q=$(printf '%q' "$REPO")
  ref_q=$(printf '%q' "$REF")
  feed_q=$(printf '%q' "$FEED")
  tmp=$(umask 077; mktemp "$STATE/${STAGING_PREFIX}check.XXXXXX") || die "cannot stage planning check"
  # The check the watcher runs is byte-bound to this adapter, so replacing the
  # adapter after registration cannot inherit the registration. The watcher
  # separately binds the check file itself through fm-check-register.sh. The
  # poll target is baked into the same bytes: the watcher's environment cannot
  # move a registered check onto a different repo, ref, or feed, and
  # retargeting requires retire, reinstall, and re-registration.
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -u
ADAPTER=$adapter_q
EXPECTED='$adapter_hash'
if command -v shasum >/dev/null 2>&1; then
  ACTUAL=\$(shasum -a 256 "\$ADAPTER" 2>/dev/null | awk '{print \$1}')
elif command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=\$(sha256sum "\$ADAPTER" 2>/dev/null | awk '{print \$1}')
else
  printf 'sssf-planning could-not-observe reason=adapter-hash-tool\n'; exit 0
fi
[ "\$ACTUAL" = "\$EXPECTED" ] || { printf 'sssf-planning security failure=adapter-drift\n'; exit 0; }
FM_SSSF_PLANNING_REPO=$repo_q \\
FM_SSSF_PLANNING_REF=$ref_q \\
FM_SSSF_PLANNING_FEED=$feed_q \\
  exec "\$ADAPTER" check
EOF
  chmod 700 "$tmp" || { rm -f -- "$tmp"; die "cannot secure planning check"; }
  mv -- "$tmp" "$CHECK" || die "cannot install planning check"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" "$ID" \
    || { rm -f -- "$CHECK"; die "planning check registration failed"; }
  printf 'installed: state/%s.check.sh repo=%s ref=%s feed=%s\n' "$ID" "$REPO" "$REF" "$FEED"
}

# Retirement restores pre-bridge behavior exactly: the watcher stops seeing a
# check, and no private planning state or staging residue is left behind. SSSF
# planning truth is untouched by this, as it is by everything else here.
cmd_retire() {
  local path
  for path in "$CHECK" "$TRUST" "$CURSOR" "$PENDING"; do
    [ ! -L "$path" ] || die "refusing symlink state path: $path"
  done
  rm -f -- "$CHECK" "$TRUST" "$CURSOR" "$PENDING"
  if state_dir_usable; then
    for path in "$STATE/$STAGING_PREFIX"*; do
      [ -e "$path" ] || continue
      [ ! -L "$path" ] || die "refusing symlink staging path: $path"
      rm -f -- "$path"
    done
  fi
  printf 'retired: %s planning awareness\n' "$ID"
}

case "${1:-}" in
  -h|--help|help) usage 0 ;;
  install) [ "$#" -eq 1 ] || usage; cmd_install ;;
  check) [ "$#" -eq 1 ] || usage; cmd_check ;;
  inspect) [ "$#" -eq 1 ] || usage; cmd_inspect ;;
  acknowledge) [ "$#" -eq 2 ] || usage; cmd_acknowledge "$2" ;;
  retire) [ "$#" -eq 1 ] || usage; cmd_retire ;;
  *) usage ;;
esac
