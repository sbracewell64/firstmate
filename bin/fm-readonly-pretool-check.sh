#!/usr/bin/env bash
# PreToolUse transport for the read-only execution surface's Bash guard.
#
# A read-only task's harness tool gate already denies the file-mutating tools
# (bin/fm-readonly-lib.sh owns that list), but Bash cannot be denied wholesale:
# inspection IS reading files and running read-only commands. This transport
# carries the Bash half. bin/fm-readonly-command-policy.mjs is the sole owner of
# the allow/deny decision; this wrapper only acquires the harness payload,
# invokes that policy, and renders the harness response. It never executes,
# sources, evaluates, or expands the command.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-readonly-pretool-check.sh \
#       --home <firstmate-home> --task <task-id> --tasktmp <dir> \
#       [--subject <sealed-dir>] [--claude]
#   bin/fm-readonly-pretool-check.sh --command '<cmd>' --home ... --task ... --tasktmp ...
#
# Stdin mode extracts .tool_input.command (Claude and Codex) or
# .toolInput.command (Grok), plus .cwd when the harness supplies it, so a
# relative write can be located.
#
# Exit/output contract:
#   ALLOW - exit 0 and no output.
#   DENY  - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#           deny object on stdout unless --claude was supplied.
#
# IT FAILS CLOSED. This is the deliberate difference from its sibling
# bin/fm-cd-pretool-check.sh, which fails OPEN on malformed input, a missing jq,
# or an unavailable classifier runtime. That sibling is a seatbelt against an
# agent mistake, where a false block costs a working command. This guard is the
# mechanism that makes "read-only" TRUE for a task that was dispatched with no
# worktree and told it may not mutate its subject. A command it cannot classify
# is therefore DENIED, because an unclassifiable command that gets allowed is
# precisely the hole that turns a read-only claim into a claim nobody checked.
#
# The cost of that choice is real and is paid at dispatch instead: because a
# missing jq or node would deny EVERY Bash call and leave the worker unable to
# do anything, bin/fm-spawn.sh verifies both are present before it will dispatch
# a readonly task at all. A guard that denies everything is a broken environment
# to fix, never a read-only task quietly making no progress.
#
# This is a capability boundary, not a security boundary; see the policy owner.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
HOME_DIR=""
TASK_ID=""
TASK_TMP=""
SUBJECT=""
CWD=""

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Every refusal path funnels through here so a deny can never accidentally be
# rendered as an allow by an early `exit`.
render_deny() {  # <code> <reason>
  local detail escaped
  detail="[$1] $2"
  escaped=$(printf '%s' "$detail" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2; CMD_SET=1; shift 2 ;;
    --command=*) CMD=${1#--command=}; CMD_SET=1; shift ;;
    --home)
      [ "$#" -gt 1 ] || { echo "error: --home requires a value" >&2; exit 2; }
      HOME_DIR=$2; shift 2 ;;
    --home=*) HOME_DIR=${1#--home=}; shift ;;
    --task)
      [ "$#" -gt 1 ] || { echo "error: --task requires a value" >&2; exit 2; }
      TASK_ID=$2; shift 2 ;;
    --task=*) TASK_ID=${1#--task=}; shift ;;
    --tasktmp)
      [ "$#" -gt 1 ] || { echo "error: --tasktmp requires a value" >&2; exit 2; }
      TASK_TMP=$2; shift 2 ;;
    --tasktmp=*) TASK_TMP=${1#--tasktmp=}; shift ;;
    --subject)
      [ "$#" -gt 1 ] || { echo "error: --subject requires a value" >&2; exit 2; }
      SUBJECT=$2; shift 2 ;;
    --subject=*) SUBJECT=${1#--subject=}; shift ;;
    --cwd)
      [ "$#" -gt 1 ] || { echo "error: --cwd requires a value" >&2; exit 2; }
      CWD=$2; shift 2 ;;
    --cwd=*) CWD=${1#--cwd=}; shift ;;
    --claude) CLAUDE_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# The task identity this guard is enforcing FOR. Without it the policy cannot
# build the write allowances, so every write would be denied for the wrong
# reason - and a guard that denies for the wrong reason teaches a worker to
# ignore it. Refuse loudly instead.
if [ -z "$HOME_DIR" ] || [ -z "$TASK_ID" ]; then
  render_deny "guard-misconfigured" \
    "the read-only Bash guard was invoked without --home/--task, so it cannot tell this task's own report and status paths from any other write"
fi

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  # An empty payload is nothing to run, so there is nothing to deny. Every other
  # unreadable state below is a denial.
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || render_deny "guard-unavailable" \
    "jq is required to read the tool payload and is not installed; a read-only task denies what it cannot classify"
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) \
    || render_deny "guard-unreadable" "the tool payload could not be parsed"
  # cwd is optional; a harness that supplies it lets a relative write be located.
  [ -n "$CWD" ] || CWD=$(printf '%s' "$PAYLOAD" | jq -r '(.cwd // .workingDirectory // empty)' 2>/dev/null || true)
fi

# No command in the payload means this was not a shell invocation at all.
[ -n "$CMD" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) \
  || render_deny "guard-unavailable" "the read-only guard could not resolve its own location"
POLICY="$SCRIPT_DIR/fm-readonly-command-policy.mjs"

command -v node >/dev/null 2>&1 || render_deny "guard-unavailable" \
  "node is required to classify the command and is not installed; a read-only task denies what it cannot classify"
[ -f "$POLICY" ] || render_deny "guard-unavailable" \
  "the read-only command policy is missing at $POLICY"

POLICY_ARGS=(--command "$CMD" --home "$HOME_DIR" --task "$TASK_ID")
[ -z "$TASK_TMP" ] || POLICY_ARGS+=(--tasktmp "$TASK_TMP")
[ -z "$SUBJECT" ] || POLICY_ARGS+=(--subject "$SUBJECT")
[ -z "$CWD" ] || POLICY_ARGS+=(--cwd "$CWD")

POLICY_OUTPUT=$(node "$POLICY" "${POLICY_ARGS[@]}" 2>/dev/null) \
  || render_deny "guard-unavailable" "the read-only command policy could not be run"
[ -n "$POLICY_OUTPUT" ] || render_deny "guard-unreadable" "the read-only command policy returned nothing"

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
case "$DECISION" in
  allow) exit 0 ;;
  deny) ;;
  # Anything else is a policy this transport does not understand, which is
  # could-not-observe, which denies.
  *) render_deny "guard-unreadable" "the read-only command policy returned an unrecognized decision" ;;
esac

REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || render_deny "guard-unreadable" "the read-only command policy returned a malformed denial"
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] \
  || render_deny "guard-unreadable" "the read-only command policy returned a malformed denial"

render_deny "$CODE" "$REASON"
