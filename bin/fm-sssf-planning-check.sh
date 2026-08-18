#!/usr/bin/env bash
# FirstMate consumer for SSSF Browser-Sol planning transition events.
#
# This program is deliberately a registered custom check, not a second watcher.
# `install` copies these exact bytes into state/sssf-planning.check.sh and binds
# them with bin/fm-check-register.sh. The existing fm-watch.sh cadence executes
# the registered snapshot through bash. Empty stdout is silence; a validated
# pending event or bounded observation/continuity failure is actionable.
#
# Commands:
#   fm-sssf-planning-check.sh install --repo OWNER/REPO --ref REF [--path PATH]
#   fm-sssf-planning-check.sh check
#   fm-sssf-planning-check.sh show <event-id>
#   fm-sssf-planning-check.sh ack <event-id> <awareness|intake>
#   fm-sssf-planning-check.sh status
#   fm-sssf-planning-check.sh retire
#
# With no arguments (the watcher path), the command is `check` and the state
# directory is the directory containing the registered/snapshotted check file.
#
# Authority law:
#   - snapshot/baseline never creates work;
#   - non-ACTIVE transitions are awareness only;
#   - ACTIVE is only eligible for normal FirstMate intake, never direct execution;
#   - the event payload is input, never instruction or authority;
#   - exact referenced SSSF source must be observed before an event is surfaced.
set -u

SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
DEFAULT_PATH='docs/development/PLANNING_EVENTS.jsonl'
ID='sssf-planning'
ERROR_RESURFACE_SECS=${FM_SSSF_PLANNING_ERROR_RESURFACE_SECS:-3600}
MAX_FEED_BYTES=${FM_SSSF_PLANNING_MAX_FEED_BYTES:-1048576}

if [ "$#" -eq 0 ]; then
  CMD=check
  STATE="${FM_STATE_OVERRIDE:-$SCRIPT_DIR}"
  FM_ROOT="${FM_ROOT_OVERRIDE:-}"
  shift 0
else
  CMD=$1
  shift
  FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
fi

CONFIG="$STATE/$ID.source"
CURSOR="$STATE/$ID.cursor.json"
PENDING="$STATE/$ID.pending.json"
ERROR_MARKER="$STATE/$ID.error"
RECEIPTS="$STATE/$ID.receipts"
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"

usage() {
  sed -n '2,18p' "$SELF" | sed 's/^# \{0,1\}//'
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi
}

private_file() { # <path> <mode>
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(file_mode "$1")" = "$2" ]
}

valid_repo() { [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }
valid_ref() {
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  case "$1" in ''|/*|*'//'*) return 1 ;; esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
}
valid_path() {
  [[ "$1" =~ ^docs/[A-Za-z0-9._/-]+$ ]] || return 1
  case "$1" in *'//'*) return 1 ;; esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
}
valid_event_id() { [[ "$1" =~ ^plan-[0-9]{8}-[0-9]{4}$ ]]; }

atomic_from_stdin() { # <path> <mode>
  local destination=$1 mode=$2 parent tmp
  parent=$(dirname "$destination")
  mkdir -p "$parent" || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  [ ! -L "$destination" ] || return 1
  tmp=$(umask 077; mktemp "$parent/.sssf-planning.XXXXXX") || return 1
  cat > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod "$mode" "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$destination"
}

read_config() {
  local schema repo ref path extra
  private_file "$CONFIG" 600 || return 1
  schema=$(sed -n 's/^schema=//p' "$CONFIG")
  repo=$(sed -n 's/^repository=//p' "$CONFIG")
  ref=$(sed -n 's/^ref=//p' "$CONFIG")
  path=$(sed -n 's/^path=//p' "$CONFIG")
  extra=$(grep -Ev '^(schema|repository|ref|path)=' "$CONFIG" 2>/dev/null || true)
  [ "$schema" = fm-sssf-planning-source.v1 ] || return 1
  [ "$(grep -c '^schema=' "$CONFIG")" -eq 1 ] || return 1
  [ "$(grep -c '^repository=' "$CONFIG")" -eq 1 ] || return 1
  [ "$(grep -c '^ref=' "$CONFIG")" -eq 1 ] || return 1
  [ "$(grep -c '^path=' "$CONFIG")" -eq 1 ] || return 1
  [ -z "$extra" ] || return 1
  valid_repo "$repo" || return 1
  valid_ref "$ref" || return 1
  valid_path "$path" || return 1
  SOURCE_REPO=$repo
  SOURCE_REF=$ref
  SOURCE_PATH=$path
}

emit_episode() { # <closed-code>
  local code=$1 now prior_code prior_time
  now=$(date +%s)
  prior_code=
  prior_time=0
  if private_file "$ERROR_MARKER" 600; then
    prior_code=$(sed -n '1p' "$ERROR_MARKER" 2>/dev/null || true)
    prior_time=$(sed -n '2p' "$ERROR_MARKER" 2>/dev/null || echo 0)
    case "$prior_time" in ''|*[!0-9]*) prior_time=0 ;; esac
  fi
  if [ "$prior_code" = "$code" ] && [ $((now - prior_time)) -lt "$ERROR_RESURFACE_SECS" ]; then
    return 0
  fi
  printf '%s\n%s\n' "$code" "$now" | atomic_from_stdin "$ERROR_MARKER" 600 || true
  printf 'SSSF_PLANNING_%s\n' "$code"
}

clear_episode() { rm -f -- "$ERROR_MARKER" 2>/dev/null || true; }

fetch_feed() { # sets OBSERVED_FEED_COMMIT and writes destination
  local destination=$1 resolved bytes
  command -v gh >/dev/null 2>&1 || return 12
  resolved=$(gh api --method GET "repos/$SOURCE_REPO/commits/$SOURCE_REF" --jq '.sha' 2>/dev/null) || return 12
  case "$resolved" in ''|*[!0-9a-f]*|???????????????????????????????????????|?????????????????????????????????????????*) return 12 ;; esac
  [ "${#resolved}" -eq 40 ] || return 12
  gh api --method GET -H 'Accept: application/vnd.github.raw+json' \
    "repos/$SOURCE_REPO/contents/$SOURCE_PATH" -f "ref=$resolved" > "$destination" 2>/dev/null || return 12
  bytes=$(LC_ALL=C wc -c < "$destination" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) return 12 ;; esac
  [ "$bytes" -le "$MAX_FEED_BYTES" ] || return 13
  OBSERVED_FEED_COMMIT=$resolved
  return 0
}

python_check() { # <feed-file> <observed-feed-commit>
  python3 - "$STATE" "$1" "$2" "$SOURCE_REPO" <<'PY'
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile

state = Path(sys.argv[1])
feed_path = Path(sys.argv[2])
observed_feed_commit = sys.argv[3]
repo = sys.argv[4]
cursor_path = state / "sssf-planning.cursor.json"
pending_path = state / "sssf-planning.pending.json"

SCHEMA = "sssf-planning-event/v1"
STATES = {
    "EXPLORE", "PRESERVE", "CANDIDATE", "DECIDED", "SEQUENCED", "ACTIVE", "PROVEN",
    "DEFERRED", "REJECTED", "SUPERSEDED",
}
LEGAL = {
    "EXPLORE": {"PRESERVE", "CANDIDATE", "DEFERRED", "REJECTED"},
    "PRESERVE": {"CANDIDATE", "DEFERRED", "REJECTED", "SUPERSEDED"},
    "CANDIDATE": {"DECIDED", "DEFERRED", "REJECTED", "SUPERSEDED"},
    "DECIDED": {"SEQUENCED", "DEFERRED", "REJECTED", "SUPERSEDED"},
    "SEQUENCED": {"ACTIVE", "DEFERRED", "REJECTED", "SUPERSEDED"},
    "ACTIVE": {"PROVEN", "DEFERRED", "SUPERSEDED"},
    "PROVEN": {"SUPERSEDED"},
    "DEFERRED": {"CANDIDATE", "DECIDED", "SEQUENCED", "REJECTED", "SUPERSEDED"},
    "REJECTED": set(),
    "SUPERSEDED": set(),
}
EVENT_RE = re.compile(r"^plan-[0-9]{8}-[0-9]{4}$")
ITEM_RE = re.compile(r"^FUT-[0-9]{3}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
INCREMENT_RE = re.compile(r"^[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+$")
PATH_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
SNAPSHOT_FIELDS = ["schema", "event_id", "kind", "source_commit", "states", "authoritative_refs", "actionability"]
TRANSITION_FIELDS = ["schema", "event_id", "kind", "item_id", "from", "to", "source_commit", "authoritative_refs", "actionability"]
ACTIVE_FIELDS = TRANSITION_FIELDS + ["increment_id"]

class Invalid(Exception): pass
class Continuity(Exception): pass
class Gap(Exception): pass

def atomic_json(path: Path, obj: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink(): raise Continuity(f"unsafe local state path: {path.name}")
    fd, raw = tempfile.mkstemp(prefix=".sssf-planning.", dir=str(path.parent))
    tmp = Path(raw)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(obj, handle, separators=(",", ":"), ensure_ascii=False)
            handle.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        try: tmp.unlink()
        except FileNotFoundError: pass

def load_private_json(path: Path, *, missing_ok=False):
    if not path.exists():
        if missing_ok: return None
        raise Continuity(f"missing local state: {path.name}")
    if path.is_symlink() or not path.is_file(): raise Continuity(f"unsafe local state: {path.name}")
    mode = path.stat().st_mode & 0o777
    if mode != 0o600: raise Continuity(f"wrong local state mode: {path.name}")
    try: return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc: raise Continuity(f"unreadable local state: {path.name}") from exc

def safe_ref(value):
    if not isinstance(value, str) or not value or not PATH_RE.fullmatch(value): return False
    if not value.startswith("docs/") or value.startswith("/") or "//" in value: return False
    return all(part not in ("", ".", "..") for part in PurePosixPath(value).parts)

def gh(*args):
    try:
        proc = subprocess.run(["gh", "api", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15)
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise Gap("GitHub source could not be observed") from exc
    if proc.returncode != 0: raise Gap("GitHub source could not be observed")
    return proc.stdout.strip()

def verify_provenance(event):
    source = event.get("source_commit")
    refs = event.get("authoritative_refs")
    if not isinstance(source, str) or not COMMIT_RE.fullmatch(source): raise Invalid("invalid source commit")
    if not isinstance(refs, list) or not refs or any(not safe_ref(ref) for ref in refs): raise Invalid("invalid authoritative refs")
    observed = gh("--method", "GET", f"repos/{repo}/commits/{source}", "--jq", ".sha")
    if observed != source: raise Gap("bound source commit could not be observed exactly")
    for ref in refs:
        kind = gh("--method", "GET", f"repos/{repo}/contents/{ref}", "-f", f"ref={source}", "--jq", ".type")
        if kind != "file": raise Gap("authoritative ref could not be observed exactly")

def parse_line(raw: bytes):
    try:
        text = raw.decode("utf-8")
        obj = json.loads(text)
    except (UnicodeError, json.JSONDecodeError) as exc: raise Invalid("malformed event JSON") from exc
    if not isinstance(obj, dict): raise Invalid("event is not an object")
    if json.dumps(obj, separators=(",", ":"), ensure_ascii=False) != text: raise Invalid("event is not compact canonical JSON")
    if obj.get("schema") != SCHEMA: raise Invalid("wrong event schema")
    event_id = obj.get("event_id")
    if not isinstance(event_id, str) or not EVENT_RE.fullmatch(event_id): raise Invalid("invalid event id")
    return obj

def validate_snapshot(event):
    if list(event) != SNAPSHOT_FIELDS: raise Invalid("snapshot fields differ")
    if event.get("kind") != "snapshot" or event.get("actionability") != "baseline": raise Invalid("snapshot is actionable or wrong kind")
    raw_states = event.get("states")
    if not isinstance(raw_states, dict) or not raw_states or list(raw_states) != sorted(raw_states): raise Invalid("invalid snapshot states")
    for item, value in raw_states.items():
        if not ITEM_RE.fullmatch(item) or value not in STATES: raise Invalid("invalid snapshot state entry")
    verify_provenance(event)
    return dict(raw_states)

def validate_transition(event, states, last_event_id):
    to_state = event.get("to")
    expected = ACTIVE_FIELDS if to_state == "ACTIVE" else TRANSITION_FIELDS
    if list(event) != expected or event.get("kind") != "transition": raise Invalid("transition fields differ")
    event_id = event["event_id"]
    if event_id <= last_event_id: raise Invalid("event id is duplicate or out of order")
    item = event.get("item_id"); from_state = event.get("from")
    if not isinstance(item, str) or not ITEM_RE.fullmatch(item): raise Invalid("invalid item id")
    if from_state not in STATES or to_state not in STATES: raise Invalid("invalid planning state")
    current = states.get(item)
    if current is None:
        if from_state != "EXPLORE": raise Invalid("new item does not originate from EXPLORE")
    elif current != from_state:
        raise Invalid("stale from state")
    if to_state not in LEGAL[from_state]: raise Invalid("illegal planning transition")
    actionability = event.get("actionability")
    if to_state == "ACTIVE":
        if actionability != "engineering": raise Invalid("ACTIVE is not engineering")
        inc = event.get("increment_id")
        if not isinstance(inc, str) or not INCREMENT_RE.fullmatch(inc): raise Invalid("ACTIVE has no concrete increment")
        if not any(isinstance(ref, str) and ref.startswith(f"docs/increments/{inc}") for ref in event.get("authoritative_refs", [])):
            raise Invalid("ACTIVE does not reference its increment")
    else:
        if actionability != "awareness" or "increment_id" in event: raise Invalid("non-ACTIVE actionability is not awareness")
    verify_provenance(event)
    next_states = dict(states); next_states[item] = to_state
    return next_states

def summary(event):
    if event.get("kind") != "transition": raise Invalid("only transitions may surface")
    increment = event.get("increment_id", "-")
    return "SSSF_PLANNING_EVENT pending {event_id} {actionability} {item} {to} {source} {increment}".format(
        event_id=event["event_id"], actionability=event["actionability"], item=event["item_id"],
        to=event["to"], source=event["source_commit"], increment=increment)

try:
    data = feed_path.read_bytes()
    if not data or not data.endswith(b"\n") or b"\r" in data: raise Invalid("feed framing is invalid")
    pending = load_private_json(pending_path, missing_ok=True)
    cursor = load_private_json(cursor_path, missing_ok=True)

    if cursor is None:
        if pending is not None: raise Continuity("pending event exists without cursor")
        end = data.find(b"\n")
        if end < 0: raise Invalid("bootstrap line is incomplete")
        event = parse_line(data[:end])
        states = validate_snapshot(event)
        offset = end + 1
        atomic_json(cursor_path, {
            "schema": "fm-sssf-planning-cursor.v1",
            "offset": offset,
            "prefix_sha256": hashlib.sha256(data[:offset]).hexdigest(),
            "last_event_id": event["event_id"],
            "states": states,
            "observed_feed_commit": observed_feed_commit,
        })
        sys.exit(0)

    if not isinstance(cursor, dict) or list(cursor) != ["schema","offset","prefix_sha256","last_event_id","states","observed_feed_commit"]:
        raise Continuity("cursor shape is invalid")
    if cursor.get("schema") != "fm-sssf-planning-cursor.v1": raise Continuity("cursor schema is invalid")
    offset = cursor.get("offset"); prefix = cursor.get("prefix_sha256"); last = cursor.get("last_event_id"); states = cursor.get("states")
    if type(offset) is not int or offset < 0 or not isinstance(prefix, str) or not re.fullmatch(r"[0-9a-f]{64}", prefix): raise Continuity("cursor offset/hash is invalid")
    if not isinstance(last, str) or not EVENT_RE.fullmatch(last) or not isinstance(states, dict): raise Continuity("cursor identity/state is invalid")
    if len(data) < offset or hashlib.sha256(data[:offset]).hexdigest() != prefix: raise Continuity("feed prefix changed or truncated")

    if pending is not None:
        if not isinstance(pending, dict) or pending.get("schema") != "fm-sssf-planning-pending.v1": raise Continuity("pending state is invalid")
        event = pending.get("event")
        if not isinstance(event, dict): raise Continuity("pending event is invalid")
        print(summary(event))
        sys.exit(0)

    if len(data) == offset:
        sys.exit(0)
    end = data.find(b"\n", offset)
    if end < 0: raise Invalid("next event line is incomplete")
    event = parse_line(data[offset:end])
    next_states = validate_transition(event, states, last)
    to_offset = end + 1
    pending = {
        "schema": "fm-sssf-planning-pending.v1",
        "event": event,
        "from_offset": offset,
        "from_prefix_sha256": prefix,
        "to_offset": to_offset,
        "to_prefix_sha256": hashlib.sha256(data[:to_offset]).hexdigest(),
        "states_after": next_states,
        "observed_feed_commit": observed_feed_commit,
    }
    atomic_json(pending_path, pending)
    print(summary(event))
except Invalid as exc:
    print(f"invalid:{exc}", file=sys.stderr); sys.exit(10)
except Continuity as exc:
    print(f"continuity:{exc}", file=sys.stderr); sys.exit(11)
except Gap as exc:
    print(f"gap:{exc}", file=sys.stderr); sys.exit(12)
except OSError as exc:
    print(f"gap:{exc}", file=sys.stderr); sys.exit(12)
PY
}

cmd_check() {
  local tmp out rc
  mkdir -p "$STATE" || { emit_episode COULD_NOT_OBSERVE; return 0; }
  read_config || { emit_episode CONFIG_INVALID; return 0; }
  command -v python3 >/dev/null 2>&1 || { emit_episode TOOLING_GAP; return 0; }
  tmp=$(umask 077; mktemp "$STATE/.sssf-planning-feed.XXXXXX") || { emit_episode COULD_NOT_OBSERVE; return 0; }
  trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
  fetch_feed "$tmp"
  rc=$?
  case "$rc" in
    0) ;;
    12) emit_episode COULD_NOT_OBSERVE; return 0 ;;
    13) emit_episode FEED_TOO_LARGE; return 0 ;;
    *) emit_episode COULD_NOT_OBSERVE; return 0 ;;
  esac
  out=$(python_check "$tmp" "$OBSERVED_FEED_COMMIT" 2>/dev/null)
  rc=$?
  case "$rc" in
    0)
      clear_episode
      [ -z "$out" ] || printf '%s\n' "$out"
      ;;
    10) emit_episode EVENT_INVALID ;;
    11) emit_episode CONTINUITY_BROKEN ;;
    12) emit_episode COULD_NOT_OBSERVE ;;
    *) emit_episode CONSUMER_FAILED ;;
  esac
}

cmd_install() {
  local repo= ref= path=$DEFAULT_PATH
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) [ "$#" -ge 2 ] || usage; repo=$2; shift 2 ;;
      --ref) [ "$#" -ge 2 ] || usage; ref=$2; shift 2 ;;
      --path) [ "$#" -ge 2 ] || usage; path=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  valid_repo "$repo" || die "invalid repository"
  valid_ref "$ref" || die "invalid source ref"
  valid_path "$path" || die "invalid feed path"
  [ -n "$FM_ROOT" ] || die "FM_ROOT is required for install"
  [ -x "$FM_ROOT/bin/fm-check-register.sh" ] || die "custom-check registrar is unavailable"
  mkdir -p "$STATE" || die "cannot create state directory"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unsafe"
  printf 'schema=fm-sssf-planning-source.v1\nrepository=%s\nref=%s\npath=%s\n' "$repo" "$ref" "$path" \
    | atomic_from_stdin "$CONFIG" 600 || die "cannot write planning source config"
  cp "$SELF" "$CHECK" || die "cannot install planning check"
  chmod 0700 "$CHECK" || die "cannot protect planning check"
  FM_STATE_OVERRIDE="$STATE" "$FM_ROOT/bin/fm-check-register.sh" "$ID" >/dev/null \
    || die "cannot register planning check"
  printf 'installed: state/%s.check.sh repo=%s ref=%s path=%s\n' "$ID" "$repo" "$ref" "$path"
}

cmd_show() {
  local event_id=${1:-}
  valid_event_id "$event_id" || usage
  private_file "$PENDING" 600 || die "no pending planning event"
  python3 - "$PENDING" "$event_id" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); wanted=sys.argv[2]
obj=json.loads(p.read_text(encoding="utf-8")); event=obj.get("event")
if not isinstance(event,dict) or event.get("event_id") != wanted: raise SystemExit(1)
print(json.dumps(event,separators=(",",":"),ensure_ascii=False))
PY
}

cmd_ack() {
  local event_id=${1:-} disposition=${2:-}
  valid_event_id "$event_id" || usage
  case "$disposition" in awareness|intake) ;; *) usage ;; esac
  mkdir -p "$RECEIPTS" || die "cannot create planning receipt directory"
  chmod 0700 "$RECEIPTS" 2>/dev/null || true
  python3 - "$CURSOR" "$PENDING" "$RECEIPTS" "$event_id" "$disposition" <<'PY'
import json, os, re, sys, tempfile, time
from pathlib import Path
cursor_path,pending_path,receipts,event_id,disposition=Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]),sys.argv[4],sys.argv[5]
receipt=receipts/f"{event_id}.json"
def load(path):
    if path.is_symlink() or not path.is_file() or (path.stat().st_mode & 0o777) != 0o600: raise SystemExit("unsafe local state")
    return json.loads(path.read_text(encoding="utf-8"))
def write(path,obj):
    fd,raw=tempfile.mkstemp(prefix=".sssf-planning.",dir=str(path.parent)); tmp=Path(raw)
    try:
        with os.fdopen(fd,"w",encoding="utf-8",newline="\n") as h: json.dump(obj,h,separators=(",",":")); h.write("\n")
        os.chmod(tmp,0o600); os.replace(tmp,path)
    finally:
        try: tmp.unlink()
        except FileNotFoundError: pass
if receipt.exists() and not pending_path.exists():
    obj=load(receipt)
    if obj.get("event_id") != event_id: raise SystemExit("receipt identity mismatch")
    print(f"already-acknowledged: {event_id}")
    raise SystemExit(0)
pending=load(pending_path); cursor=load(cursor_path); event=pending.get("event")
if not isinstance(event,dict) or event.get("event_id") != event_id: raise SystemExit("pending event identity mismatch")
action=event.get("actionability")
if action == "engineering" and disposition != "intake": raise SystemExit("engineering event must be acknowledged as intake")
if action == "awareness" and disposition != "awareness": raise SystemExit("awareness event must be acknowledged as awareness")
if action not in ("engineering","awareness"): raise SystemExit("pending event actionability is invalid")
from_offset=pending.get("from_offset"); from_hash=pending.get("from_prefix_sha256")
to_offset=pending.get("to_offset"); to_hash=pending.get("to_prefix_sha256"); states=pending.get("states_after")
if cursor.get("offset") == from_offset and cursor.get("prefix_sha256") == from_hash:
    next_cursor={"schema":"fm-sssf-planning-cursor.v1","offset":to_offset,"prefix_sha256":to_hash,"last_event_id":event_id,"states":states,"observed_feed_commit":pending.get("observed_feed_commit")}
    write(cursor_path,next_cursor)
elif cursor.get("offset") == to_offset and cursor.get("prefix_sha256") == to_hash and cursor.get("last_event_id") == event_id:
    pass
else:
    raise SystemExit("cursor no longer matches pending transition")
if receipt.exists():
    prior=load(receipt)
    if prior.get("event_id") != event_id or prior.get("handled_as") != disposition: raise SystemExit("receipt conflicts with acknowledgement")
else:
    write(receipt,{"schema":"fm-sssf-planning-receipt.v1","event_id":event_id,"handled_as":disposition,"actionability":action,"source_commit":event.get("source_commit"),"handled_at_epoch":int(time.time())})
pending_path.unlink()
print(f"acknowledged: {event_id} as {disposition}")
PY
}

cmd_status() {
  if read_config; then printf 'source: %s %s %s\n' "$SOURCE_REPO" "$SOURCE_REF" "$SOURCE_PATH"; else printf 'source: unconfigured-or-invalid\n'; fi
  if private_file "$CURSOR" 600; then
    python3 - "$CURSOR" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8")); print(f"cursor: event={x.get('last_event_id','?')} offset={x.get('offset','?')}")
PY
  else printf 'cursor: none\n'; fi
  if private_file "$PENDING" 600; then
    python3 - "$PENDING" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding="utf-8")); e=x.get('event',{}); print(f"pending: {e.get('event_id','?')} {e.get('actionability','?')}")
PY
  else printf 'pending: none\n'; fi
}

cmd_retire() {
  rm -f -- "$CHECK" "$TRUST" "$CONFIG" "$CURSOR" "$PENDING" "$ERROR_MARKER"
  printf 'retired: %s planning check; receipts preserved at %s\n' "$ID" "$RECEIPTS"
}

case "$CMD" in
  check) [ "$#" -eq 0 ] || usage; cmd_check ;;
  install) cmd_install "$@" ;;
  show) [ "$#" -eq 1 ] || usage; cmd_show "$1" ;;
  ack) [ "$#" -eq 2 ] || usage; cmd_ack "$1" "$2" ;;
  status) [ "$#" -eq 0 ] || usage; cmd_status ;;
  retire) [ "$#" -eq 0 ] || usage; cmd_retire ;;
  *) usage ;;
esac
