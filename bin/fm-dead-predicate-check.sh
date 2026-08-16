#!/usr/bin/env bash
# fm-dead-predicate-check.sh - refuse a fail-closed predicate that nothing consults.
#
# WHY THIS EXISTS. A guard that is defined but never called is worse than a
# missing guard, because reading the file proves the check exists. Two such
# guards were found in one module family, across three separate review findings:
# fm_outbound_applicability, written correct - refusing a superseded record,
# refusing to default an unobservable head to applicable - and never invoked, so
# the sweep applied no applicability test at all; and fm_outbound_record_state_valid,
# likewise defined once and consulted nowhere.
#
# Two, not three: the third finding's other half was a missing branch rather than
# a dead function. The count is stated exactly because a control built to catch a
# class should not begin by miscounting its own founding evidence.
#
# Fixing three call sites leaves the mechanism that produced them intact, so this
# is the class control: in an ENROLLED file, a function with no call site anywhere
# in the repository is a defect, and the only way to keep one is to say so in
# writing at the definition itself.
#
# WHY EVERY FUNCTION AND NOT JUST THE PREDICATES. A naming heuristic - `_valid`,
# `_applicability` - is a rule an author can walk around by choosing another name,
# and it goes quietly vacuous the day someone does. Dead code in a library whose
# whole job is refusing unsafe states is a defect whatever it is called, so the
# rule needs no heuristic and has nothing to game.
#
# WHAT THIS DOES NOT CATCH, STATED SO THE COVERAGE CANNOT INFLATE.
#
# This control answers exactly one question: is a function defined and never
# consulted. It does NOT catch the adjacent and more common shape - a predicate
# that IS called but checks less than its name claims. The same review that found
# the two dead predicates here also found `record_read` validating only a record's
# schema while its name and every call site implied it validated the record, and
# no scanner would have flagged that: the function had call sites and looked
# consulted.
#
# That class is not mechanically decidable, and a control claiming to cover it
# would manufacture precision - the same error as scoring a check on an axis it
# never measured. It is caught by review, and this comment is the record that it
# is review's job rather than this file's.
#
# The checkable rule that came out of that finding, and which belongs with the
# code rather than here: any record retrieved BY KEY must have its content-derived
# identity verified against that key, and a mismatch must refuse rather than
# return the record. bin/fm-public-followup.sh already refuses a receipt whose
# .request_id does not match the request it was fetched for; that is the fleet
# pattern, not a new requirement.
#
# Usage:
#   fm-dead-predicate-check.sh [--json] [<file>...]
#       With no files, checks every enrolled file under the repo's bin/.
#
# ENROLLMENT is per file, by a marker line anywhere in it:
#   # fail-closed-predicates: enforced
# A file-level marker is what lets the repository adopt this one library at a
# time instead of on a flag day. It is deliberately NOT an exemption mechanism:
# removing enrollment to silence a finding is itself pinned by a test, so the
# quiet way out is closed.
#
# A DELIBERATELY UNUSED function is kept by marking the definition itself, on the
# line immediately above it:
#   # unused-by-design: <reason>
# The mark is per function and adjacent on purpose. There is no file-level or
# blanket exemption, because a blanket exemption would silence the next dead
# predicate along with the one someone actually reasoned about. Marked functions
# are REPORTED rather than hidden, so the list stays readable and a stale mark
# stays visible.
#
# Exit status is the verdict, so a caller that ignores stdout still stops safely:
#   0  every enrolled file's functions are consulted, or explicitly marked
#   2  usage error
#   3  at least one function is defined and never consulted
#   4  could-not-observe - no enrolled file was found, or a target was unreadable
#
# 4 IS NOT 0. A checker that finds nothing to check has not established that the
# code is clean, and reporting that as a pass is the same defect one level up.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# The full LINE, not a fragment, because enrolment is matched exactly.
ENROL_MARKER='# fail-closed-predicates: enforced'
KEEP_MARKER='unused-by-design:'

die() { printf 'fm-dead-predicate-check: %s\n' "$1" >&2; exit "${2:-2}"; }

JSON=0
TARGETS=()
while [ $# -gt 0 ]; do
  case $1 in
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option '$1'" ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

# Where a call site may live. Searching the whole repository rather than a
# declared consumer list is deliberate: a consumer list is another thing that can
# be wrong, and a function used anywhere is not dead.
search_roots() {
  for d in "$ROOT/bin" "$ROOT/tests" "$ROOT/.agents"; do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
}

shell_code() {  # <file>
  awk '
  function blank(s,    n) { n = length(s); return sprintf("%" n "s", "") }
  function heredoc_word(s,    c, escaped, i, q, word) {
    sub(/^[[:space:]]*/, "", s)
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (escaped) { word = word c; escaped = 0; continue }
      if (c == "\\") { escaped = 1; continue }
      if (q != "") { if (c == q) q = ""; else word = word c; continue }
      if (c == "\047" || c == "\"") { q = c; continue }
      if (c ~ /[[:space:];|&()<>]/) break
      word = word c
    }
    if (escaped || q != "" || word == "") return ""
    return word
  }
  {
    raw = $0
    if (heredoc != "") {
      end = raw
      if (strip_tabs) sub(/^\t+/, "", end)
      print NR ":" blank(raw)
      if (end == heredoc) { heredoc = ""; strip_tabs = 0 }
      next
    }
    out = ""
    for (i = 1; i <= length(raw); i++) {
      c = substr(raw, i, 1)
      if (quote == "ansi") {
        out = out " "
        if (c == "\\") { if (i < length(raw)) { out = out " "; i++ }; continue }
        if (c == "\047") quote = ""
        continue
      }
      if (quote == "\047") {
        out = out " "
        if (c == "\047") quote = ""
        continue
      }
      if (quote == "\"") {
        if (c == "$" && substr(raw, i + 1, 1) == "(") {
          out = out "$("
          i++
          substitution++
          resume_quote[substitution] = "\""
          quote = ""
          continue
        }
        out = out " "
        if (c == "\\") { if (i < length(raw)) { out = out " "; i++ }; continue }
        if (c == "\"") quote = ""
        continue
      }
      if (c == "\047" || c == "\"") { quote = c; out = out " "; continue }
      if (c == "$" && substr(raw, i + 1, 1) == "\047") {
        out = out "  "
        i++
        quote = "ansi"
        continue
      }
      if (c == "\\") { out = out " "; if (i < length(raw)) { out = out " "; i++ }; continue }
      if (c == "$" && substr(raw, i + 1, 1) == "(") {
        out = out "$("
        i++
        substitution++
        resume_quote[substitution] = ""
        continue
      }
      if (c == "#" && (i == 1 || substr(raw, i - 1, 1) ~ /[[:space:];|&(){}]/)) {
        out = out blank(substr(raw, i))
        break
      }
      out = out c
      if (substitution > 0 && c == "(") {
        substitution++
        resume_quote[substitution] = ""
      }
      if (substitution > 0 && c == ")") {
        quote = resume_quote[substitution]
        delete resume_quote[substitution]
        substitution--
      }
    }
    print NR ":" out
    probe = out
    if (match(probe, /<<-?[[:space:]]*/)) {
      if (substr(probe, RSTART, 3) == "<<<") next
      if (substr(probe, 1, RSTART - 1) ~ /\(\([^)]*$/ && substr(probe, RSTART) ~ /\)\)/) next
      token = substr(raw, RSTART, length(raw) - RSTART + 1)
      strip_tabs = token ~ /^<<-/
      sub(/^<<-?[[:space:]]*/, "", token)
      heredoc = heredoc_word(token)
      if (heredoc == "") exit 4
    }
  }
  END { if (heredoc != "") exit 4 }
  ' "$1"
}

function_definitions() {  # <file>
  shell_code "$1" | sed -nE \
    -e 's/^([0-9]+):[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*(\{|$).*/\1:\2/p' \
    -e 's/^([0-9]+):[[:space:]]*function[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)([[:space:]]*\(\))?[[:space:]]*(\{|$).*/\1:\2/p'
}

function_has_call_site() {  # <function>
  local fn=$1 d source
  while IFS= read -r d; do
    while IFS= read -r source; do
      if shell_code "$source" | awk -v fn="$fn" '
      {
        line = $0
        sub(/^[0-9]+:/, "", line)
        if (line ~ ("^[[:space:]]*" fn "[[:space:]]*\\(\\)[[:space:]]*(\\{|$)")) {
          sub("^[[:space:]]*" fn "[[:space:]]*\\(\\)[[:space:]]*\\{?[[:space:]]*", "", line)
        } else if (line ~ ("^[[:space:]]*function[[:space:]]+" fn "([[:space:]]*\\(\\))?[[:space:]]*(\\{|$)")) {
          sub("^[[:space:]]*function[[:space:]]+" fn "([[:space:]]*\\(\\))?[[:space:]]*\\{?[[:space:]]*", "", line)
        }
        if (line ~ ("(^|[;|&(){}])[[:space:]]*((if|then|elif|else|while|until|do|!|command|builtin|env)[[:space:]]+)*" fn "([^A-Za-z0-9_]|$)")) found = 1
        if (line ~ ("(^|[;|&(){}])[[:space:]]*trap[[:space:]]+[\047\"]?" fn "([^A-Za-z0-9_]|$)")) found = 1
      }
      END { exit(found ? 0 : 1) }
      '; then
        return 0
      fi
      grep -Eq "#[[:space:]]*indirect-call:[[:space:]]*$fn([^A-Za-z0-9_]|$)" "$source" \
        && return 0
    done < <(find "$d" -type f -print 2>/dev/null)
  done < <(search_roots)
  return 1
}

enrolled_files() {
  if [ "${#TARGETS[@]}" -gt 0 ]; then
    printf '%s\n' "${TARGETS[@]}"
    return 0
  fi
  # -x, an EXACT full-line match. A substring match self-enrolled this very
  # file, because its own header quotes the marker while documenting it; any
  # file that merely mentions the rule would have been enrolled by describing it.
  grep -rlxF "$ENROL_MARKER" "$ROOT/bin" 2>/dev/null | sort
}

FILES=()
while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(enrolled_files)

if [ "${#FILES[@]}" -eq 0 ]; then
  printf 'fm-dead-predicate-check: COULD-NOT-OBSERVE - no enrolled file found (marker: %s)\n' \
    "$ENROL_MARKER" >&2
  exit 4
fi

for f in "${FILES[@]}"; do
  shell_code "$f" >/dev/null || die "could not parse shell syntax in $f" 4
done
while IFS= read -r d; do
  while IFS= read -r f; do
    shell_code "$f" >/dev/null || die "could not parse shell syntax in $f" 4
  done < <(find "$d" -type f -print 2>/dev/null)
done < <(search_roots)

dead_json='[]'
marked_json='[]'
DEAD=0
MARKED=0

for f in "${FILES[@]}"; do
  [ -r "$f" ] || die "target is unreadable: $f" 4
  grep -qxF "$ENROL_MARKER" "$f" 2>/dev/null || die "target is not enrolled: $f" 4
  while IFS= read -r line; do
    lineno=${line%%:*}
    fn=${line#*:}
    [ -n "$fn" ] || continue
    function_has_call_site "$fn" && continue
    prev=$((lineno - 1))
    if [ "$prev" -ge 1 ] && sed -n "${prev}p" "$f" | grep -qF "$KEEP_MARKER"; then
      reason=$(sed -n "${prev}p" "$f" | sed "s/.*${KEEP_MARKER}[[:space:]]*//")
      marked_json=$(printf '%s' "$marked_json" | jq --arg f "$f" --arg fn "$fn" \
        --argjson l "$lineno" --arg r "$reason" '. + [{file:$f,function:$fn,line:$l,reason:$r}]')
      MARKED=$((MARKED + 1))
      continue
    fi
    dead_json=$(printf '%s' "$dead_json" | jq --arg f "$f" --arg fn "$fn" --argjson l "$lineno" \
      '. + [{file:$f,function:$fn,line:$l}]')
    DEAD=$((DEAD + 1))
  done < <(function_definitions "$f")
done

if [ "$JSON" -eq 1 ]; then
  jq -n --argjson dead "$dead_json" --argjson marked "$marked_json" \
    --argjson files "$(printf '%s\n' "${FILES[@]}" | jq -R . | jq -s .)" \
    '{schema:"fm-dead-predicate-check.v1",enrolled:$files,dead:$dead,marked:$marked}'
else
  printf '%s' "$marked_json" | jq -r '.[] |
    "  marked   \(.function)  \(.file):\(.line)  unused by design: \(.reason)"'
  printf '%s' "$dead_json" | jq -r '.[] |
    "  DEAD     \(.function)  \(.file):\(.line)  defined and never consulted"'
  if [ "$DEAD" -eq 0 ]; then
    printf 'fm-dead-predicate-check: ok enrolled=%s marked=%s\n' "${#FILES[@]}" "$MARKED"
  else
    printf '\n%s function(s) exist but nothing consults them. A guard nothing calls is not a guard.\n' "$DEAD"
    printf 'Wire each one in, or mark the definition with "# %s <reason>" on the line above it.\n' "$KEEP_MARKER"
  fi
fi

[ "$DEAD" -eq 0 ] || exit 3
exit 0
