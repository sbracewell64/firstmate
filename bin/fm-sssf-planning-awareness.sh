#!/usr/bin/env bash
# Typed SSSF planning-transition consumer for FirstMate.
# Non-ACTIVE events are awareness only. ACTIVE is normal-intake eligibility,
# never direct execution authority.
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

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
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
  local tmp hash
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-sssf-empty.XXXXXX") || return 1
  : > "$tmp"
  hash=$(sha256_file "$tmp") || { rm -f -- "$tmp"; return 1; }
  rm -f -- "$tmp"
  printf '%s\n' "$hash"
}

require_tools() {
  command -v gh >/dev/null 2>&1 || die "gh is required"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  sha256_file "$0" >/dev/null 2>&1 || die "SHA-256 tool is required"
}

safe_doc_ref() {
  case "$1" in docs/*) ;; *) return 1 ;; esac
  case "$1" in *'//'*) return 1 ;; esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
  case "$1" in *'\\'*|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  return 0
}

fetch_raw() { # <ref> <path> <destination>
  gh api -H 'Accept: application/vnd.github.raw+json' \
    "repos/$REPO/contents/$2?ref=$1" > "$3" 2>/dev/null
}

read_cursor() {
  CURSOR_OFFSET=0
  CURSOR_HASH=$(empty_hash) || return 1
  CURSOR_LAST=
  [ -e "$CURSOR" ] || return 0
  [ -f "$CURSOR" ] && [ ! -L "$CURSOR" ] || return 1
  local schema offset hash last count
  schema=$(sed -n 's/^schema=//p' "$CURSOR")
  offset=$(sed -n 's/^offset=//p' "$CURSOR")
  hash=$(sed -n 's/^prefix_sha256=//p' "$CURSOR")
  last=$(sed -n 's/^last_event_id=//p' "$CURSOR")
  count=$(grep -Ec '^(schema|offset|prefix_sha256|last_event_id)=' "$CURSOR" 2>/dev/null || true)
  [ "$schema" = fm-sssf-planning-cursor.v1 ] && [ "$count" -eq 4 ] || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  CURSOR_OFFSET=$offset
  CURSOR_HASH=$hash
  CURSOR_LAST=$last
}

write_cursor() { # <offset> <hash> <event-id>
  local tmp
  mkdir -p "$STATE" || return 1
  chmod 700 "$STATE" 2>/dev/null || true
  [ ! -L "$CURSOR" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.sssf-planning-cursor.XXXXXX") || return 1
  {
    printf 'schema=fm-sssf-planning-cursor.v1\n'
    printf 'offset=%s\n' "$1"
    printf 'prefix_sha256=%s\n' "$2"
    printf 'last_event_id=%s\n' "$3"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CURSOR"
}

pending_field() {
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || return 1
  [ "$(grep -c "^$1=" "$PENDING" 2>/dev/null || true)" -eq 1 ] || return 1
  grep "^$1=" "$PENDING" | cut -d= -f2-
}

pending_summary() {
  local event kind target action
  event=$(pending_field event_id) || return 1
  kind=$(pending_field kind) || return 1
  target=$(pending_field to 2>/dev/null || true)
  action=$(pending_field actionability) || return 1
  printf 'sssf-planning pending event_id=%s kind=%s' "$event" "$kind"
  [ -z "$target" ] || printf ' to=%s' "$target"
  printf ' actionability=%s\n' "$action"
}

validate_event() { # <json-file>
  local file=$1 kind action target ref
  jq -e 'type == "object" and .schema == "sssf-planning-event/v1" and (.event_id|type=="string") and (.source_commit|type=="string") and (.authoritative_refs|type=="array" and length>0)' "$file" >/dev/null 2>&1 || return 1
  [[ "$(jq -r '.event_id' "$file")" =~ ^plan-[0-9]{8}-[0-9]{4}$ ]] || return 1
  [[ "$(jq -r '.source_commit' "$file")" =~ ^[0-9a-f]{40}$ ]] || return 1
  kind=$(jq -r '.kind // empty' "$file")
  action=$(jq -r '.actionability // empty' "$file")
  case "$kind" in
    bootstrap)
      [ "$action" = awareness ] || return 1
      jq -e '(.states|type=="object" and length>0) and (has("item_id")|not) and (has("from")|not) and (has("to")|not)' "$file" >/dev/null 2>&1 || return 1
      ;;
    transition)
      jq -e '(.item_id|type=="string") and (.from|type=="string") and (.to|type=="string")' "$file" >/dev/null 2>&1 || return 1
      target=$(jq -r '.to' "$file")
      case "$target" in
        ACTIVE)
          [ "$action" = engineering ] || return 1
          jq -e '(.increments|type=="array" and length>0)' "$file" >/dev/null 2>&1 || return 1
          ;;
        EXPLORE|PRESERVE|CANDIDATE|DECIDED|SEQUENCED|PROVEN|DEFERRED|REJECTED|SUPERSEDED)
          [ "$action" = awareness ] || return 1
          ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  while IFS= read -r ref; do safe_doc_ref "$ref" || return 1; done < <(jq -r '.authoritative_refs[]' "$file")
}

verify_authority_refs() { # <json-file> <tmpdir>
  local source ref n=0
  source=$(jq -r '.source_commit' "$1")
  while IFS= read -r ref; do
    n=$((n + 1))
    fetch_raw "$source" "$ref" "$2/ref.$n" || return 1
    [ -s "$2/ref.$n" ] || return 1
  done < <(jq -r '.authoritative_refs[]' "$1")
}

write_pending() { # <event-file> <from-offset> <to-offset> <to-prefix-hash>
  local tmp event kind action target
  event=$(jq -r '.event_id' "$1")
  kind=$(jq -r '.kind' "$1")
  action=$(jq -r '.actionability' "$1")
  target=$(jq -r '.to // empty' "$1")
  [ ! -e "$PENDING" ] && [ ! -L "$PENDING" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.sssf-planning-pending.XXXXXX") || return 1
  {
    printf 'schema=fm-sssf-planning-pending.v1\n'
    printf 'event_id=%s\nkind=%s\nto=%s\nactionability=%s\n' "$event" "$kind" "$target" "$action"
    printf 'from_offset=%s\nto_offset=%s\nto_prefix_sha256=%s\n' "$2" "$3" "$4"
    printf 'event_json='; cat "$1"; printf '\n'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$PENDING"
}

# Subshell ownership makes EXIT cleanup local to this check. A function RETURN
# cannot tear down staging while helpers are still executing.
cmd_check() (
  require_tools
  mkdir -p "$STATE" || die "state directory unavailable"
  if [ -e "$PENDING" ] || [ -L "$PENDING" ]; then
    [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || { printf 'sssf-planning continuity/security failure=pending-unsafe\n'; exit 0; }
    pending_summary || printf 'sssf-planning continuity/security failure=pending-malformed\n'
    exit 0
  fi
  read_cursor || { printf 'sssf-planning continuity/security failure=cursor\n'; exit 0; }

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-sssf-planning.XXXXXX") || die "cannot create staging directory"
  trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
  if ! fetch_raw "$REF" "$FEED" "$tmp/feed"; then
    printf 'sssf-planning continuity failure=source-unavailable repo=%s ref=%s\n' "$REPO" "$REF"
    exit 0
  fi
  feed_size=$(wc -c < "$tmp/feed" | tr -d ' ')
  case "$feed_size" in ''|*[!0-9]*) printf 'sssf-planning continuity failure=source-size\n'; exit 0 ;; esac
  [ "$feed_size" -le "$MAX_FEED_BYTES" ] || { printf 'sssf-planning continuity failure=feed-too-large bytes=%s\n' "$feed_size"; exit 0; }
  [ "$feed_size" -ge "$CURSOR_OFFSET" ] || { printf 'sssf-planning continuity failure=truncated offset=%s size=%s\n' "$CURSOR_OFFSET" "$feed_size"; exit 0; }

  head -c "$CURSOR_OFFSET" "$tmp/feed" > "$tmp/prefix"
  actual=$(sha256_file "$tmp/prefix") || die "cannot hash feed prefix"
  [ "$actual" = "$CURSOR_HASH" ] || { printf 'sssf-planning continuity failure=prefix-changed offset=%s\n' "$CURSOR_OFFSET"; exit 0; }
  [ "$feed_size" -gt "$CURSOR_OFFSET" ] || exit 0

  tail -c "+$((CURSOR_OFFSET + 1))" "$tmp/feed" > "$tmp/remainder"
  lines=$(wc -l < "$tmp/remainder" | tr -d ' ')
  [ "$lines" -gt 0 ] || { printf 'sssf-planning continuity failure=incomplete-record\n'; exit 0; }
  line=$(sed -n '1p' "$tmp/remainder")
  bytes=$(printf '%s\n' "$line" | wc -c | tr -d ' ')
  [ "$bytes" -le "$MAX_EVENT_BYTES" ] || { printf 'sssf-planning continuity failure=event-too-large bytes=%s\n' "$bytes"; exit 0; }
  printf '%s\n' "$line" > "$tmp/event.json"
  validate_event "$tmp/event.json" || { printf 'sssf-planning invalid-event offset=%s\n' "$CURSOR_OFFSET"; exit 0; }
  verify_authority_refs "$tmp/event.json" "$tmp" || { printf 'sssf-planning stale-or-missing-authority event_id=%s\n' "$(jq -r '.event_id' "$tmp/event.json")"; exit 0; }

  next=$((CURSOR_OFFSET + bytes))
  head -c "$next" "$tmp/feed" > "$tmp/next-prefix"
  next_hash=$(sha256_file "$tmp/next-prefix") || die "cannot hash next feed prefix"
  write_pending "$tmp/event.json" "$CURSOR_OFFSET" "$next" "$next_hash" || { printf 'sssf-planning continuity/security failure=pending-publish\n'; exit 0; }
  pending_summary || printf 'sssf-planning continuity/security failure=pending-malformed\n'
)

cmd_inspect() {
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || die "no pending planning event"
  local line
  line=$(grep '^event_json=' "$PENDING" 2>/dev/null || true)
  [ -n "$line" ] || die "pending planning event is malformed"
  printf '%s\n' "${line#event_json=}"
}

cmd_acknowledge() {
  local expected=$1 event offset hash
  event=$(pending_field event_id) || die "no valid pending planning event"
  [ "$event" = "$expected" ] || die "pending event identity mismatch"
  offset=$(pending_field to_offset) || die "pending end offset unavailable"
  hash=$(pending_field to_prefix_sha256) || die "pending end hash unavailable"
  case "$offset" in ''|*[!0-9]*) die "pending end offset invalid" ;; esac
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "pending end hash invalid"
  write_cursor "$offset" "$hash" "$event" || die "could not advance planning cursor"
  rm -f -- "$PENDING" || die "could not retire pending planning event"
  printf 'acknowledged: %s\n' "$event"
}

cmd_install() {
  require_tools
  mkdir -p "$STATE" || die "state directory unavailable"
  chmod 700 "$STATE" 2>/dev/null || true
  [ ! -e "$CHECK" ] && [ ! -L "$CHECK" ] || die "planning check already exists; retire before reinstalling"
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
  printf 'sssf-planning continuity/security failure=adapter-hash-tool\n'; exit 0
fi
[ "\$ACTUAL" = "\$EXPECTED" ] || { printf 'sssf-planning continuity/security failure=adapter-drift\n'; exit 0; }
exec "\$ADAPTER" check
EOF
  chmod 700 "$tmp" || { rm -f -- "$tmp"; die "cannot secure planning check"; }
  mv -- "$tmp" "$CHECK" || die "cannot install planning check"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" "$ID" || { rm -f -- "$CHECK"; die "planning check registration failed"; }
  printf 'installed: state/%s.check.sh repo=%s ref=%s\n' "$ID" "$REPO" "$REF"
}

cmd_retire() {
  local path
  for path in "$CHECK" "$TRUST" "$CURSOR" "$PENDING"; do [ ! -L "$path" ] || die "refusing symlink state path: $path"; done
  rm -f -- "$CHECK" "$TRUST" "$CURSOR" "$PENDING"
  printf 'retired: %s planning awareness\n' "$ID"
}

case "${1:-}" in
  install) [ "$#" -eq 1 ] || usage; cmd_install ;;
  check) [ "$#" -eq 1 ] || usage; cmd_check ;;
  inspect) [ "$#" -eq 1 ] || usage; cmd_inspect ;;
  acknowledge) [ "$#" -eq 2 ] || usage; cmd_acknowledge "$2" ;;
  retire) [ "$#" -eq 1 ] || usage; cmd_retire ;;
  *) usage ;;
esac
