#!/usr/bin/env bash
# FirstMate consumer for the SSSF planning-transition feed.
#
# This adapter never infers authority from planning prose. It consumes one typed
# append-only event at a time. Non-ACTIVE events are awareness-only. ACTIVE is
# intake eligibility only; it is never direct execution authority.
#
# Usage:
#   fm-sssf-planning-awareness.sh install
#   fm-sssf-planning-awareness.sh check
#   fm-sssf-planning-awareness.sh inspect
#   fm-sssf-planning-awareness.sh acknowledge <event-id>
#   fm-sssf-planning-awareness.sh retire
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
MAX_FEED_BYTES=${FM_SSSF_PLANNING_MAX_FEED_BYTES:-1048576}
MAX_EVENT_BYTES=${FM_SSSF_PLANNING_MAX_EVENT_BYTES:-16384}

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { printf 'sssf-planning: error: %s\n' "$1" >&2; exit 1; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

empty_hash() {
  local t h
  t=$(mktemp "${TMPDIR:-/tmp}/fm-sssf-empty.XXXXXX") || return 1
  : > "$t"
  h=$(sha256_file "$t") || { rm -f -- "$t"; return 1; }
  rm -f -- "$t"
  printf '%s\n' "$h"
}

require_tools() {
  command -v gh >/dev/null 2>&1 || die "gh is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  sha256_file "$0" >/dev/null 2>&1 || die "SHA-256 tool is required"
}

safe_doc_ref() {
  case "$1" in
    docs/*) ;;
    *) return 1 ;;
  esac
  case "$1" in *'//'*) return 1 ;; esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
  case "$1" in *'\\'*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  return 0
}

fetch_raw() { # <ref> <path> <destination>
  local ref=$1 path=$2 dest=$3
  gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$REPO/contents/$path?ref=$ref" > "$dest" 2>/dev/null
}

read_cursor() {
  CURSOR_OFFSET=0
  CURSOR_HASH=$(empty_hash) || die "cannot establish empty cursor hash"
  CURSOR_LAST=
  [ -e "$CURSOR" ] || return 0
  [ -f "$CURSOR" ] && [ ! -L "$CURSOR" ] || die "cursor is unsafe"
  local schema offset hash last count
  schema=$(sed -n 's/^schema=//p' "$CURSOR")
  offset=$(sed -n 's/^offset=//p' "$CURSOR")
  hash=$(sed -n 's/^prefix_sha256=//p' "$CURSOR")
  last=$(sed -n 's/^last_event_id=//p' "$CURSOR")
  count=$(grep -Ec '^(schema|offset|prefix_sha256|last_event_id)=' "$CURSOR" 2>/dev/null || true)
  [ "$schema" = fm-sssf-planning-cursor.v1 ] && [ "$count" -eq 4 ] || die "cursor is malformed"
  case "$offset" in ''|*[!0-9]*) die "cursor offset is invalid" ;; esac
  case "$hash" in ''|*[!0-9a-f]*) die "cursor prefix hash is invalid" ;; esac
  [ "${#hash}" -eq 64 ] || die "cursor prefix hash length is invalid"
  CURSOR_OFFSET=$offset
  CURSOR_HASH=$hash
  CURSOR_LAST=$last
}

write_cursor() { # <offset> <hash> <event-id>
  local offset=$1 hash=$2 event=$3 tmp
  mkdir -p "$STATE" || return 1
  chmod 700 "$STATE" 2>/dev/null || true
  [ ! -L "$CURSOR" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.sssf-planning-cursor.XXXXXX") || return 1
  {
    printf 'schema=fm-sssf-planning-cursor.v1\n'
    printf 'offset=%s\n' "$offset"
    printf 'prefix_sha256=%s\n' "$hash"
    printf 'last_event_id=%s\n' "$event"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CURSOR"
}

pending_field() { # <field>
  local field=$1 count
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || return 1
  count=$(grep -c "^$field=" "$PENDING" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^$field=" "$PENDING" | cut -d= -f2-
}

pending_summary() {
  local event kind to action
  event=$(pending_field event_id) || return 1
  kind=$(pending_field kind) || return 1
  to=$(pending_field to 2>/dev/null || true)
  action=$(pending_field actionability) || return 1
  printf 'sssf-planning pending event_id=%s kind=%s' "$event" "$kind"
  [ -z "$to" ] || printf ' to=%s' "$to"
  printf ' actionability=%s\n' "$action"
}

validate_event() { # <json-file>
  local file=$1 schema kind event source action to ref increments
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || return 1
  schema=$(jq -r '.schema // empty' "$file")
  kind=$(jq -r '.kind // empty' "$file")
  event=$(jq -r '.event_id // empty' "$file")
  source=$(jq -r '.source_commit // empty' "$file")
  action=$(jq -r '.actionability // empty' "$file")
  [ "$schema" = sssf-planning-event/v1 ] || return 1
  [[ "$event" =~ ^plan-[0-9]{8}-[0-9]{4}$ ]] || return 1
  [[ "$source" =~ ^[0-9a-f]{40}$ ]] || return 1
  case "$kind" in
    bootstrap)
      [ "$action" = awareness ] || return 1
      jq -e '(.states | type == "object" and length > 0) and (has("from")|not) and (has("to")|not) and (has("item_id")|not)' "$file" >/dev/null 2>&1 || return 1
      ;;
    transition)
      jq -e '(.item_id|type=="string") and (.from|type=="string") and (.to|type=="string")' "$file" >/dev/null 2>&1 || return 1
      to=$(jq -r '.to' "$file")
      case "$to" in
        EXPLORE|PRESERVE|CANDIDATE|DECIDED|SEQUENCED|PROVEN|DEFERRED|REJECTED|SUPERSEDED)
          [ "$action" = awareness ] || return 1
          ;;
        ACTIVE)
          [ "$action" = engineering ] || return 1
          increments=$(jq -r 'if (.increments|type)=="array" and (.increments|length)>0 then "yes" else "no" end' "$file")
          [ "$increments" = yes ] || return 1
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  jq -e '(.authoritative_refs|type)=="array" and (.authoritative_refs|length)>0' "$file" >/dev/null 2>&1 || return 1
  while IFS= read -r ref; do
    safe_doc_ref "$ref" || return 1
  done < <(jq -r '.authoritative_refs[]' "$file")
  return 0
}

verify_authority_refs() { # <json-file> <tmpdir>
  local file=$1 tmp=$2 source ref n=0
  source=$(jq -r '.source_commit' "$file")
  while IFS= read -r ref; do
    n=$((n + 1))
    fetch_raw "$source" "$ref" "$tmp/ref.$n" || return 1
    [ -s "$tmp/ref.$n" ] || return 1
  done < <(jq -r '.authoritative_refs[]' "$file")
}

write_pending() { # <event-json> <from> <to> <prefix-hash>
  local event_file=$1 from=$2 to=$3 to_hash=$4 tmp event kind action target
  event=$(jq -r '.event_id' "$event_file")
  kind=$(jq -r '.kind' "$event_file")
  action=$(jq -r '.actionability' "$event_file")
  target=$(jq -r '.to // empty' "$event_file")
  [ ! -e "$PENDING" ] && [ ! -L "$PENDING" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.sssf-planning-pending.XXXXXX") || return 1
  {
    printf 'schema=fm-sssf-planning-pending.v1\n'
    printf 'event_id=%s\n' "$event"
    printf 'kind=%s\n' "$kind"
    printf 'to=%s\n' "$target"
    printf 'actionability=%s\n' "$action"
    printf 'from_offset=%s\n' "$from"
    printf 'to_offset=%s\n' "$to"
    printf 'to_prefix_sha256=%s\n' "$to_hash"
    printf 'event_json='; cat "$event_file"; printf '\n'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$PENDING"
}

cmd_check() {
  require_tools
  mkdir -p "$STATE" || die "state directory unavailable"
  if [ -e "$PENDING" ] || [ -L "$PENDING" ]; then
    [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || { printf 'sssf-planning continuity/security failure=pending-unsafe\n'; return 0; }
    pending_summary || printf 'sssf-planning continuity/security failure=pending-malformed\n'
    return 0
  fi

  read_cursor || { printf 'sssf-planning continuity/security failure=cursor\n'; return 0; }
  local tmp feed_size actual_prefix remainder_lines line bytes next to_hash
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-sssf-planning.XXXXXX") || die "cannot create staging directory"
  trap 'rm -rf -- "$tmp"' RETURN
  if ! fetch_raw "$REF" "$FEED" "$tmp/feed"; then
    printf 'sssf-planning continuity failure=source-unavailable repo=%s ref=%s\n' "$REPO" "$REF"
    return 0
  fi
  feed_size=$(wc -c < "$tmp/feed" | tr -d ' ')
  case "$feed_size" in ''|*[!0-9]*) printf 'sssf-planning continuity failure=source-size\n'; return 0 ;; esac
  if [ "$feed_size" -gt "$MAX_FEED_BYTES" ]; then
    printf 'sssf-planning continuity failure=feed-too-large bytes=%s\n' "$feed_size"
    return 0
  fi
  if [ "$feed_size" -lt "$CURSOR_OFFSET" ]; then
    printf 'sssf-planning continuity failure=truncated offset=%s size=%s\n' "$CURSOR_OFFSET" "$feed_size"
    return 0
  fi
  head -c "$CURSOR_OFFSET" "$tmp/feed" > "$tmp/prefix"
  actual_prefix=$(sha256_file "$tmp/prefix") || die "cannot hash feed prefix"
  if [ "$actual_prefix" != "$CURSOR_HASH" ]; then
    printf 'sssf-planning continuity failure=prefix-changed offset=%s\n' "$CURSOR_OFFSET"
    return 0
  fi
  [ "$feed_size" -gt "$CURSOR_OFFSET" ] || return 0
  tail -c "+$((CURSOR_OFFSET + 1))" "$tmp/feed" > "$tmp/remainder"
  remainder_lines=$(wc -l < "$tmp/remainder" | tr -d ' ')
  [ "$remainder_lines" -gt 0 ] || { printf 'sssf-planning continuity failure=incomplete-record\n'; return 0; }
  line=$(sed -n '1p' "$tmp/remainder")
  bytes=$(printf '%s\n' "$line" | wc -c | tr -d ' ')
  if [ "$bytes" -gt "$MAX_EVENT_BYTES" ]; then
    printf 'sssf-planning continuity failure=event-too-large bytes=%s\n' "$bytes"
    return 0
  fi
  printf '%s\n' "$line" > "$tmp/event.json"
  if ! validate_event "$tmp/event.json"; then
    printf 'sssf-planning invalid-event offset=%s\n' "$CURSOR_OFFSET"
    return 0
  fi
  if ! verify_authority_refs "$tmp/event.json" "$tmp"; then
    printf 'sssf-planning stale-or-missing-authority event_id=%s\n' "$(jq -r '.event_id' "$tmp/event.json")"
    return 0
  fi
  next=$((CURSOR_OFFSET + bytes))
  head -c "$next" "$tmp/feed" > "$tmp/next-prefix"
  to_hash=$(sha256_file "$tmp/next-prefix") || die "cannot hash next feed prefix"
  if ! write_pending "$tmp/event.json" "$CURSOR_OFFSET" "$next" "$to_hash"; then
    printf 'sssf-planning continuity/security failure=pending-publish\n'
    return 0
  fi
  pending_summary || printf 'sssf-planning continuity/security failure=pending-malformed\n'
}

cmd_inspect() {
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || die "no pending planning event"
  local line
  line=$(grep '^event_json=' "$PENDING" 2>/dev/null || true)
  [ -n "$line" ] || die "pending planning event is malformed"
  printf '%s\n' "${line#event_json=}"
}

cmd_acknowledge() {
  local expected=${1:-} event to hash
  [ -n "$expected" ] || usage
  event=$(pending_field event_id) || die "no valid pending planning event"
  [ "$event" = "$expected" ] || die "pending event identity mismatch"
  to=$(pending_field to_offset) || die "pending end offset unavailable"
  hash=$(pending_field to_prefix_sha256) || die "pending end hash unavailable"
  case "$to" in ''|*[!0-9]*) die "pending end offset invalid" ;; esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "pending end hash invalid"
  write_cursor "$to" "$hash" "$event" || die "could not advance planning cursor"
  rm -f -- "$PENDING" || die "could not retire pending planning event"
  printf 'acknowledged: %s\n' "$event"
}

cmd_install() {
  require_tools
  mkdir -p "$STATE" || die "state directory unavailable"
  chmod 700 "$STATE" 2>/dev/null || true
  [ ! -e "$CHECK" ] && [ ! -L "$CHECK" ] || die "planning check already exists; retire it before reinstalling"
  local adapter_hash tmp adapter_q
  adapter_hash=$(sha256_file "$0") || die "cannot hash planning adapter"
  adapter_q=$(printf '%q' "$0")
  tmp=$(umask 077; mktemp "$STATE/.sssf-planning-check.XXXXXX") || die "cannot stage planning check"
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
  printf 'sssf-planning continuity/security failure=adapter-hash-tool\n'
  exit 0
fi
if [ "\$ACTUAL" != "\$EXPECTED" ]; then
  printf 'sssf-planning continuity/security failure=adapter-drift\n'
  exit 0
fi
exec "\$ADAPTER" check
EOF
  chmod 700 "$tmp" || { rm -f -- "$tmp"; die "cannot secure planning check"; }
  mv -- "$tmp" "$CHECK" || die "cannot install planning check"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" "$ID" || { rm -f -- "$CHECK"; die "planning check registration failed"; }
  printf 'installed: state/%s.check.sh repo=%s ref=%s\n' "$ID" "$REPO" "$REF"
}

cmd_retire() {
  for path in "$CHECK" "$TRUST" "$CURSOR" "$PENDING"; do
    [ ! -L "$path" ] || die "refusing to remove symlink state path: $path"
  done
  rm -f -- "$CHECK" "$TRUST" "$CURSOR" "$PENDING"
  printf 'retired: %s planning awareness\n' "$ID"
}

case "${1:-}" in
  install) shift; [ "$#" -eq 0 ] || usage; cmd_install ;;
  check) shift; [ "$#" -eq 0 ] || usage; cmd_check ;;
  inspect) shift; [ "$#" -eq 0 ] || usage; cmd_inspect ;;
  acknowledge) shift; [ "$#" -eq 1 ] || usage; cmd_acknowledge "$1" ;;
  retire) shift; [ "$#" -eq 0 ] || usage; cmd_retire ;;
  *) usage ;;
esac
