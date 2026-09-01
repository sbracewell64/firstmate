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
# control checks canonical `name() {` definitions against explicitly accepted
# direct-call forms. A definition or call form outside that syntax is UNCHECKED,
# returns could-not-observe, and names the file and construct. Within the accepted
# syntax, a function with no call site is a defect, and the only way to keep one
# is to say so in writing at the definition itself.
#
# ACCEPTED SYNTAX. Definitions are unindented `name() {` lines. Calls begin a
# command after indentation and optional shell control words, follow an unquoted
# command boundary, occur in a command substitution, begin a canonical one-line
# function body, name a trap handler - written bare as `trap fn SIG` or as the
# first word of a quoted handler, `trap 'fn args' SIG` - or are declared by a
# SITE-PINNED `indirect-call:` mark this control re-reads and confirms. A `printf` command is
# accepted only as opaque data and never as call evidence.
# Heredocs and every other function definition or function-name use are UNCHECKED
# rather than interpreted or skipped.
#
# THE INDIRECT-CALL MARK, AND WHY IT CARRIES A SITE.
#
# A dynamic dispatch is a real call this control's syntax cannot resolve on its
# own: a handler string a `trap` re-evaluates, a validator handed to its caller by
# name. A mark at the source is how such a call is declared:
#
#   # indirect-call: <function> <file>:<line>
#
# The mark is DISCOVERY, never proof. A bare `# indirect-call: <function>` used to
# be counted on its own, so one fabricated comment naming a function nothing
# dispatches flipped that function from DEAD to ALIVE with no call anywhere in the
# tree. That is a proxy marker upgrading an unobserved construct into a positive
# fact, which is the exact failure this file exists to refuse, so the mark now
# only says WHERE to look and this control does the looking.
#
# A mark counts only when the control re-reads the exact `<file>:<line>` it names
# and observes the function there in an executable position. That site read is
# closed and enumerated:
#
#   - The site file must be one this control can parse. A mark may not rescue a
#     call site inside a heredoc or any other unreadable construct, because a
#     line-local read cannot tell an unreadable file's payload text from its code.
#     When a consumer becomes unreadable the repair is the construct that made it
#     unreadable, never a mark that hides the gap.
#   - BARE DISPATCH. The function begins a command after indentation and optional
#     shell control words, begins a command substitution, or begins a canonical
#     one-line function body. A bare argument counts only when the named callee's
#     own canonical definition dispatches that positional parameter directly, or
#     binds it exactly once in a local or plain assignment and uses the bound name
#     only through expansions before dispatching it at a command head. The whole
#     body must contain no `shift` or `set` command. A body containing `eval`,
#     `source`, or `.` is could-not-observe because this control does not interpret
#     the payload those commands execute, and its mark is refused rather than
#     credited as a dispatch.
#     Assignments, test expressions, output commands, and other arguments are data.
#   - HANDLER DISPATCH. The function is the quoted handler operand of `trap`.
#
# Bash locals are dynamically scoped. This body-local proof does not follow calls
# into helpers, so a helper that rebinds its caller's local is could-not-observe
# territory even when that helper is defined in the same file. A verified mark
# establishes only that the callee body itself does not rebind the dispatch name.
#
# Everything else is REFUSED and named: a mark with no site, an unparseable or
# unknown site file, a line past end of file, a line that never mentions the
# function, a line that mentions it only in a comment or in quoted data, and a
# line that is the function's own definition. A refused mark is not merely
# uncounted, it is a red verdict, because a mark is a written claim about how a
# call is made and a claim the code does not support is manufactured evidence
# rather than an oversight. The line number is part of that claim, so a mark left
# behind when its site moved refuses rather than drifting quietly onto whatever
# now sits at that line.
#
# WHERE MARKS ARE READ FROM, stated so this coverage cannot inflate either. Marks
# are read out of the same parseable consumer files everything else here is read
# from. A mark written inside an unparseable file is neither counted nor refused,
# because that file's syntax is not readable at all - it manufactures nothing,
# and the way to see it is the same as for every other line in that file, which
# is to repair the construct that made the file unreadable.
#
# WHAT THIS DOES NOT CATCH, STATED SO THE COVERAGE CANNOT INFLATE.
#
# This control answers exactly one question within its accepted syntax: is a
# function defined and never consulted. It does NOT catch the adjacent shape - a predicate
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
# WHEN A `DEAD` VERDICT MAY BE TRUSTED, AND HOW MUCH OF THE REPOSITORY IS READ.
#
# `DEAD` is issued only when EVERY file that could have held a call site was
# parseable. If any possible consumer is outside the accepted syntax, the
# predicate is COULD_NOT_OBSERVE instead - never `DEAD`. That is the property
# that makes a `DEAD` verdict actionable: it says the call site is absent, not
# merely that this control failed to find one. An earlier version counted call
# sites only inside ENROLLED files, so a predicate called solely from an
# unenrolled consumer was reported `DEAD` although it was live - a false positive
# in the direction that invites deleting working code, and a verdict that
# depended on which files happened to be enrolled rather than on the code.
#
# The cost is visibility, and it is large enough to state plainly: on this
# repository 119 consumer files parse and 233 do not, so most of the tree is
# currently unreadable to this control and could_not_observe is its honest answer
# for any predicate whose consumers live in that majority. That is a measurement
# rather than a failure - the way to shrink 233 is to make more files parse, and
# the `scanned=`/`unchecked=` summary below is what refreshes both numbers - but
# it must never be mistaken for a clean repository. Every unchecked consumer is
# named in the output, and the summary line always prints `alive=` and
# `could_not_observe=` counts, because "nothing is dead" and "nothing could be
# resolved" are different facts that a single ok line would otherwise conflate.
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
#   3  at least one function is defined and never consulted, or an indirect-call
#      mark could not be verified at the site it names
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

function_definitions() {  # <file>
  grep -nE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{' "$1" \
    | sed -E 's/^([0-9]+):([A-Za-z_][A-Za-z0-9_]*)\(\).*/\1:\2/'
}

function_has_call_site() {  # <function>
  local fn=$1
  # A VERIFIED mark, never the mark's text. The mark itself is a comment and the
  # stripped text has comments removed, which is correct: a declared call is
  # counted because this control re-read the site the mark named and saw the
  # function dispatched there, not because the comment exists.
  mark_verified "$fn" && return 0
  grep -Eq "^[[:space:]]*trap[[:space:]]+['\"][[:space:]]*$fn([^A-Za-z0-9_]|\$)" "$RAW_CALL_SITE_CORPUS" && return 0
  if awk -v fn="$fn" '
      BEGIN { term = "([[:space:];|&(){}<>]|$)" }
      # A line that does not contain the name as a SUBSTRING cannot match any
      # rule below, because every rule that concludes anything embeds the name.
      # Skipping the regex battery for those lines is a pure prefilter, not a
      # narrowing of the accepted syntax, and it is what makes a repo-wide run
      # cheap enough to sit on the automatic check path.
      index($0, fn) == 0 { next }
      $0 ~ ("^" fn "\\(\\)[[:space:]]*\\{") { next }
      $0 ~ ("^[[:space:]]*((if|then|elif|else|while|until|do|!|command|builtin|env)[[:space:]]+)*" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"?\\$\\(" fn term) { found = 1 }
      $0 ~ ("^[A-Za-z_][A-Za-z0-9_]*\\(\\)[[:space:]]*\\{[[:space:]]*" fn term) { found = 1 }
      $0 ~ ("^[^\"\047`]*([;|&(){}])[[:space:]]*" fn term) { found = 1 }
      $0 ~ ("\\$\\(" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\\$\\(.*[[:space:]]\\|[[:space:]]*" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*(if|while|until)[[:space:]].*[[:space:]](\\|\\||&&)[[:space:]]*(![[:space:]]*)?" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*[[:space:]](\\|\\||&&)[[:space:]]*" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*.*[[:space:]](\\|\\||&&)[[:space:]]*" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*if[[:space:]].*[[:space:]]\\|[[:space:]]*" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*\\{.*[[:space:]](&&|\\|\\|)[[:space:]]*!?[[:space:]]*" fn term) { found = 1 }
      $0 ~ ("[[:space:]]\\|\\|[[:space:]]*\\{[[:space:]]*" fn term) { found = 1 }
      # A CONTINUATION LINE that opens with || or && , optionally negated. This is
      # a genuine call site and a common idiom - measured at 65 occurrences across
      # bin/ - so its absence was the whitelist being under-specified rather than
      # the code being unusual. Added on that measurement, NOT to make a file pass:
      # widening an accepted-syntax list to silence a refusal is shaping a control
      # around its own answer, which is the failure this whitelist exists to avoid.
      $0 ~ ("^[[:space:]]*(\\|\\||&&)[[:space:]]*(![[:space:]]*)?" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*trap[[:space:]]+" fn term) { found = 1 }
      $0 ~ ("^[[:space:]]*(if|elif)[[:space:]].*;[[:space:]]*then[[:space:]]+" fn term) { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$STRIPPED_CALL_SITE_CORPUS"; then
    return 0
  fi
  return 1
}

# Blank every quoted span, so quoted text is DATA and never read as code.
#
# This is a real walk over two states rather than a per-line heuristic, because
# the heuristic was wrong in the direction that matters. Counting quotes per line
# treats a MULTI-LINE single-quoted string - a jq program, a multi-line constant -
# as unbalanced, which marked most of this repository unreadable and turned every
# predicate into could-not-observe. A single quote inside DOUBLE quotes is not a
# quote opener, which is why double-quote state is tracked too: without it the
# quote-escape dance this repo uses everywhere would desynchronise the walk.
#
# Prints the file with quoted spans blanked. Exits 1 if a span is still
# open at end of file, the one case this cannot resolve.
strip_quoted() {  # <file>; FM_STRIP_EMIT_COMMENTS=1 emits only real comments
  awk '
    BEGIN {
      mode = "normal"
      escaped = 0
      subdepth = 0
      saw_backtick = 0
      emit_comments = ENVIRON["FM_STRIP_EMIT_COMMENTS"] == "1"
    }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        nextc = substr($0, i + 1, 1)
        if (mode == "sq") { if (c == "\047") mode = "normal"; continue }
        if (mode == "subsq") { if (c == "\047") mode = "sub"; continue }
        if (mode == "ansi" || mode == "subansi") {
          if (escaped) { escaped = 0; continue }
          if (c == "\\") { escaped = 1; continue }
          if (c == "\047") mode = (mode == "ansi" ? "normal" : "sub")
          continue
        }
        if (mode == "dq" || mode == "subdq") {
          if (escaped) { escaped = 0; continue }
          if (c == "\\") { escaped = 1; continue }
          if (c == "$" && nextc == "(") {
            subdepth++
            parens[subdepth] = 1
            returns[subdepth] = mode
            mode = "sub"
            out = out "$("
            i++
            continue
          }
          if (c == "$" && nextc ~ /[A-Za-z_0-9]/) {
            out = out c
            for (j = i + 1; j <= n && substr($0, j, 1) ~ /[A-Za-z_0-9]/; j++)
              out = out substr($0, j, 1)
            i = j - 1
            continue
          }
          if (c == "`") saw_backtick = 1
          if (c == "\"") mode = (mode == "dq" ? "normal" : "sub")
          continue
        }
        # A comment ends the line. Shell ignores an apostrophe in prose, and
        # without this every "control\047s" or "doesn\047t" in a header opened a
        # quote that never closed, so the file read as unterminated and every
        # predicate in it became could-not-observe.
        if (c == "#" && (i == 1 || substr($0, i-1, 1) ~ /[ \t]/)) {
          if (emit_comments) out = substr($0, i)
          break
        }
        if (c == "$" && nextc == "\047") {
          mode = (mode == "sub" ? "subansi" : "ansi")
          i++
          continue
        }
        if (c == "\047") { mode = (mode == "sub" ? "subsq" : "sq"); continue }
        if (c == "\"") { mode = (mode == "sub" ? "subdq" : "dq"); continue }
        if (c == "`") saw_backtick = 1
        if (mode == "sub" && c == "(") parens[subdepth]++
        if (mode == "sub" && c == ")") {
          parens[subdepth]--
          if (parens[subdepth] == 0) {
            mode = returns[subdepth]
            delete parens[subdepth]
            delete returns[subdepth]
            subdepth--
          }
        }
        if (!emit_comments) out = out c
      }
      print out
    }
    END {
      if (mode != "normal" || subdepth != 0) exit 1
      if (saw_backtick) exit 2
    }
  ' "$1"
}

shell_comments() {  # <file> - one quote-aware comment field per source line
  FM_STRIP_EMIT_COMMENTS=1 strip_quoted "$1"
}

# ONE quote walk per FILE, not per (file x function).
#
# The walk above is char-by-char in awk and was re-run for every function under
# test against every consumer, so a repo-wide run cost files x functions walks -
# roughly nine thousand of them here. That is not merely slow: it is the reason
# the control was impractical to put on the repo-wide check path, and a control
# that is too expensive to run automatically is a control nobody runs, which is
# the same end state as the dead predicates it exists to catch.
#
# The cache lives ON DISK rather than in a shell array, because most call sites
# are the left side of a pipeline and a pipeline stage is a subshell: an
# in-memory cache written there is discarded when the stage ends, so every
# lookup would miss and the walk would be re-run exactly as before. The walk's
# EXIT STATUS is stored beside its output, because 0, 1 (unterminated span) and
# 2 (legacy backtick) are three different answers and file_parse_refusal
# branches on all three. The cache mirrors the source path under one scratch
# root, so the key is injective without hashing or truncation.
STRIP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-dead-predicate.XXXXXX") \
  || die "cannot create a work directory" 4
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
strip_cache_cleanup() { rm -rf "$STRIP_DIR" 2>/dev/null || true; }
trap strip_cache_cleanup EXIT

strip_cached() {  # <file> - stripped text on stdout, exit status of strip_quoted
  local f=$1 cache rcfile rc
  cache="$STRIP_DIR/files/$f"
  rcfile="$cache.rc"
  if [ ! -f "$rcfile" ]; then
    mkdir -p "${cache%/*}" || die "cannot cache the quote walk for $f" 4
    strip_quoted "$f" > "$cache.part" 2>/dev/null
    rc=$?
    # The status file is published LAST and by rename, so a cache entry is never
    # visible without the status that explains it.
    mv -f "$cache.part" "$cache" || die "cannot cache the quote walk for $f" 4
    printf '%s' "$rc" > "$rcfile.part"
    mv -f "$rcfile.part" "$rcfile" || die "cannot cache the quote walk for $f" 4
  fi
  read -r rc < "$rcfile"
  cat "$cache"
  return "$rc"
}

# Why a file may not be reasoned about at all. Returns the offending
# "<line>:<text>" on stdout and 1 when the file is outside the accepted syntax.
file_parse_refusal() {  # <file>
  local f=$1 hit strip_rc
  strip_cached "$f" >/dev/null
  strip_rc=$?
  case $strip_rc in
    0)
      hit=$(strip_cached "$f" | awk '
        index($0, "<<") && !index($0, "<<<") && !heredoc { heredoc = NR ":" $0 }
        /^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)\(\)[[:space:]]*(\{|$)|^[[:space:]]*function[[:space:]]+[A-Za-z_]/ && !definition { definition = NR ":" $0 }
        END {
          if (heredoc) print heredoc
          else if (definition) print definition
        }
      ')
      ;;
    1) hit="0:unterminated quoted string" ;;
    2) hit="0:legacy backtick substitution" ;;
    *) hit="0:quote walk failed" ;;
  esac
  [ -z "$hit" ] && return 0
  printf '%s\n' "$hit"
  return 1
}

# THE SITE READ. Everything below turns an `indirect-call:` mark from a claim
# into an observation, or refuses it.
#
# The mark's own text establishes NOTHING. It supplies a file and a line, and
# these functions go and read that line. What comes back is the file's own quote
# walk at that line - the same walk every other call form here is judged on - so a
# site cannot mean one thing to a mark and another to the direct-call rules.

# Which parseable consumer a site names, printed on stdout. A site file outside
# the parseable set is refused rather than read, because the line-local read
# cannot tell an unreadable file's payload text from its code, and a mark that
# could name a heredoc line would be exactly the "mark instead of repair" move
# that produced the fabricated marks this site pinning exists to stop.
site_file_parseable() {  # <path-as-written>
  local path=$1 candidate p
  [ -n "$path" ] || return 1
  for candidate in "$ROOT/$path" "$path"; do
    for p in "${PARSEABLE[@]}"; do
      [ "$p" = "$candidate" ] || continue
      printf '%s\n' "$p"
      return 0
    done
  done
  return 1
}

pass_by_name_dispatches() {  # <site-file> <raw-site-line> <function>
  local f=$1 raw=$2 fn=$3 callee arg_index=0 i def_line end_line body param_var executable payload
  local -a words=()
  read -r -a words <<<"$raw"
  [ "${#words[@]}" -gt 1 ] || return 1
  callee=${words[0]}
  case $callee in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  for ((i = 1; i < ${#words[@]}; i++)); do
    [ "${words[$i]}" = "$fn" ] || continue
    arg_index=$i
    break
  done
  [ "$arg_index" -gt 0 ] || return 1
  executable=$(strip_cached "$f")
  def_line=$(printf '%s\n' "$executable" \
    | awk -v callee="$callee" '
        $0 ~ ("^" callee "\\(\\)[[:space:]]*\\{") { line = NR }
        END { if (line) print line }
      ')
  [ -n "$def_line" ] || return 1
  end_line=$(printf '%s\n' "$executable" \
    | awk -v start="$def_line" '
        NR > start && /^}/ && !end { end = NR }
        END { if (end) print end }
      ')
  if [ -z "$end_line" ]; then
    body=$(printf '%s\n' "$executable" | sed -n "${def_line}p")
  else
    body=$(printf '%s\n' "$executable" | sed -n "${def_line},${end_line}p")
  fi
  payload=$(printf '%s\n' "$body" | awk '
    { text = text " " $0 }
    END {
      boundary = "(^|[[:space:];|&(){}<>])"
      term = "([[:space:];|&(){}<>]|$)"
      if (text ~ (boundary "(eval|source|[.])" term)) print "eval/source"
    }
  ')
  if [ -n "$payload" ]; then
    PASS_BY_NAME_CNO_REASON="hands $fn to a callee whose pass-by-name relation is could-not-observe because its body executes an $payload payload"
    return 2
  fi
  param_var=$(printf '%s\n' "$body" \
    | sed -nE "s/.*[[:space:]]([A-Za-z_][A-Za-z0-9_]*)=(\\\$${arg_index}([[:space:];]|$)|\\\$\\{${arg_index}:-[^}]*\\}).*/\\1/p" \
    | sed -n '1p')
  printf '%s\n' "$body" | awk -v n="$arg_index" -v var="$param_var" '
    { text = text " " $0 }
    END {
      boundary = "(^|[;&|{}])[;&|]?[[:space:]]*(![[:space:]]*)?"
      term = "([[:space:];|&(){}<>]|$)"
      positional_mutation = "(^|[;&|{}[:space:]])(shift|set)([[:space:];|&(){}<>]|$)"
      if (text ~ positional_mutation) exit 1
      direct = boundary "\\$" n term
      if (match(text, direct)) exit 0
      if (var == "") exit 1
      binding = "(^|[;{}[:space:]])" var "=(\\$" n "([;{}[:space:]]|$)|\\$\\{" n ":-[^}]*\\})"
      rest = text
      binding_count = 0
      binding_start = 0
      binding_length = 0
      offset = 0
      while (match(rest, binding)) {
        binding_count++
        if (binding_count > 1) exit 1
        binding_start = offset + RSTART
        binding_length = RLENGTH
        offset += RSTART + RLENGTH - 1
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (binding_count != 1) exit 1
      binding_end = binding_start + binding_length - 1
      after_binding = substr(text, binding_end + 1)
      dispatch = boundary "\\$" var term
      if (!match(after_binding, dispatch)) exit 1
      admitted = substr(text, 1, binding_start - 1) substr(text, binding_end + 1)
      braced_expansion = "\\$\\{" var "[^}]*\\}"
      simple_expansion = "\\$" var "([^A-Za-z0-9_]|$)"
      gsub(braced_expansion, "", admitted)
      gsub(simple_expansion, "", admitted)
      bare_name = "(^|[^A-Za-z0-9_])" var "([^A-Za-z0-9_]|$)"
      if (admitted ~ bare_name) exit 1
      exit 0
    }
  '
}

# Why a mark's site does not establish the call. Prints the reason and returns 1
# when the site cannot carry the mark, and returns 0 silently when it does.
mark_site_refusal() {  # <function> <site> <resolved-site-file-or-empty>
  local fn=$1 site=$2 resolved=$3 lineno total raw stripped reason pass_by_name=0 pass_by_name_cno=
  [ -n "$site" ] || { printf 'names no <file>:<line> dispatch site\n'; return 1; }
  case $site in
    *:*) ;;
    *) printf 'site "%s" is not a <file>:<line> reference\n' "$site"; return 1 ;;
  esac
  lineno=${site##*:}
  case $lineno in
    ''|*[!0-9]*) printf 'site "%s" is not a <file>:<line> reference\n' "$site"; return 1 ;;
  esac
  [ "$lineno" -gt 0 ] || { printf 'site "%s" names line 0\n' "$site"; return 1; }
  if [ -z "$resolved" ]; then
    printf 'site %s is not a file this control can parse, so no call site in it was read\n' \
      "${site%:*}"
    return 1
  fi
  total=$(strip_cached "$resolved" | awk 'END { print NR }')
  if [ "$lineno" -gt "${total:-0}" ]; then
    printf 'site %s is past the end of that file (%s lines)\n' "$site" "${total:-0}"
    return 1
  fi
  raw=$(sed -n "${lineno}p" "$resolved")
  stripped=$(strip_cached "$resolved" | sed -n "${lineno}p")
  PASS_BY_NAME_CNO_REASON=
  if pass_by_name_dispatches "$resolved" "$raw" "$fn"; then
    pass_by_name=1
  elif [ "$?" -eq 2 ]; then
    pass_by_name_cno=$PASS_BY_NAME_CNO_REASON
  fi
  # The two readings answer different halves of the question and neither is
  # sufficient alone. The STRIPPED line is the file-context truth about what the
  # shell executes there, so it is what a bare dispatch must survive; reading the
  # raw line for that would count a line in the middle of a multi-line string.
  # The RAW line is the only place a quoted handler's text still exists, so it is
  # what a handler dispatch is read from, and the dispatcher word that makes that
  # text executable is required OUTSIDE the quotes.
  reason=$(FM_SITE_RAW=$raw FM_SITE_STRIPPED=$stripped awk -v fn="$fn" -v pass_by_name="$pass_by_name" -v pass_by_name_cno="$pass_by_name_cno" '
    BEGIN {
      raw = ENVIRON["FM_SITE_RAW"]
      stripped = ENVIRON["FM_SITE_STRIPPED"]
      dq = sprintf("%c", 34)
      word = "(^|[^A-Za-z0-9_])" fn "([^A-Za-z0-9_]|$)"
      term = "([[:space:];|&(){}<>]|$)"
      controls = "((if|then|elif|else|while|until|do|!|command|builtin|env)[[:space:]]+)*"
      if (stripped ~ ("^[[:space:]]*(function[[:space:]]+)?" fn "[[:space:]]*(\\(\\)|\\{)")) {
        print "is the definition of " fn ", not a call to it"
        exit
      }
      if (stripped ~ ("^[[:space:]]*" controls fn "=")) {
        print "uses " fn " as an assignment, not a command word"
        exit
      }
      if (stripped ~ ("\\$\\([[:space:]]*" fn "=") || stripped ~ ("^[A-Za-z_][A-Za-z0-9_]*\\(\\)[[:space:]]*\\{[[:space:]]*" fn "=")) {
        print "uses " fn " as an assignment, not a command word"
        exit
      }
      if (stripped ~ ("^[[:space:]]*" controls fn term)) exit
      if (stripped ~ ("\\$\\([[:space:]]*" fn term)) exit
      if (stripped ~ ("^[A-Za-z_][A-Za-z0-9_]*\\(\\)[[:space:]]*\\{[[:space:]]*" fn term)) exit
      if (stripped ~ /^[[:space:]]*(test|\[\[?)([[:space:]]|$)/ && stripped ~ word) {
        print "places " fn " in data, not in an executable dispatch position"
        exit
      }
      if (stripped ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*([[:space:]]+[^;|&[:space:]]+)*[[:space:]]+" fn "([[:space:]]+[^;|&[:space:]]+)*[[:space:]]*([;|&]|$)")) {
        if (stripped ~ /^[[:space:]]*(echo|printf|cat|:)([[:space:]]|$)/)
          print "hands " fn " to an output command, which is opaque data and never call evidence"
        else if (stripped ~ /^[[:space:]]*(test|\[)([[:space:]]|$)/)
          print "places " fn " in data, not in an executable dispatch position"
        else if (stripped ~ /^[[:space:]]*(grep|cp|logger)([[:space:]]|$)/)
          print "hands " fn " to a non-dispatching command"
        else if (pass_by_name_cno != "")
          print pass_by_name_cno
        else if (pass_by_name)
          exit
        else
          print "hands " fn " to a callee with no proven command-head dispatch for that argument"
        exit
      }
      if (stripped ~ /^[[:space:]]*trap[[:space:]]+/ && raw ~ ("^[[:space:]]*trap[[:space:]]+\\047[[:space:]]*" fn "([[:space:]][^\\047]*)?\\047[[:space:]]+[^#]+([[:space:]]+#.*)?$")) exit
      if (stripped ~ /^[[:space:]]*trap[[:space:]]+/ && raw ~ ("^[[:space:]]*trap[[:space:]]+" dq "[[:space:]]*" fn "([[:space:]][^" dq "]*)?" dq "[[:space:]]+[^#]+([[:space:]]+#.*)?$")) exit
      if (raw ~ word) { print "names " fn " only where the shell does not dispatch it"; exit }
      print "does not mention " fn
    }')
  [ -n "$reason" ] || return 0
  printf 'site %s %s\n' "$site" "$reason"
  return 1
}

# Every mark in a file this control can parse, each one resolved against the site
# it names. A verified mark counts as a call; a refused one is reported and turns
# the run red. Marks naming something no enrolled file defines are left alone:
# they cannot upgrade any verdict here, so refusing them would be this control
# ruling on code it is not enforcing.
MARK_VERIFIED=()
MARK_VERIFIED_SITE=()
MARK_CLASSIFIED_DATA_SITE=()
REFUSED_MARKS=()
collect_marks() {
  local f hit lineno rest fn site path resolved reason
  for f in "${PARSEABLE[@]}"; do
    while IFS= read -r hit; do
      lineno=${hit%%:*}
      rest=${hit#*:}
      rest=${rest#*indirect-call:}
      read -r fn site _ <<<"$rest"
      [ -n "${fn:-}" ] || continue
      case $fn in
        [A-Za-z_]*) ;;
        *) continue ;;
      esac
      function_is_enrolled "$fn" || continue
      case ${site:-} in
        *:*) path=${site%:*} ;;
        *) path='' ;;
      esac
      resolved=$(site_file_parseable "$path") || resolved=''
      if reason=$(mark_site_refusal "$fn" "${site:-}" "$resolved"); then
        MARK_VERIFIED+=("$fn")
        MARK_VERIFIED_SITE+=("$fn|$resolved|${site##*:}")
      else
        REFUSED_MARKS+=("$f"$'\t'"$lineno"$'\t'"$fn"$'\t'"${site:-}"$'\t'"$reason")
        case $reason in
          *'opaque data'*|*'places '*"$fn"*' in data'*|*'non-dispatching command'*)
            [ -z "$resolved" ] || MARK_CLASSIFIED_DATA_SITE+=("$fn|$resolved|${site##*:}")
            ;;
        esac
      fi
    done < <(shell_comments "$f" | grep -nE '^#[[:space:]]*indirect-call:')
  done
}

function_is_enrolled() {  # <name>
  local fn=$1 known
  for known in "${FUNCTIONS[@]:-}"; do
    [ "$known" = "$fn" ] && return 0
  done
  return 1
}

mark_verified() {  # <function>
  local fn=$1 entry
  for entry in "${MARK_VERIFIED[@]:-}"; do
    [ "$entry" = "$fn" ] && return 0
  done
  return 1
}

mark_observed_lines() {  # <function> <file>
  local prefix="$1|$2|" entry
  for entry in "${MARK_VERIFIED_SITE[@]:-}" "${MARK_CLASSIFIED_DATA_SITE[@]:-}"; do
    case $entry in
      "$prefix"*) printf '%s ' "${entry##*|}" ;;
    esac
  done
}

proven_pass_by_name_lines() {  # <function> <file>
  local fn=$1 f=$2 lineno raw
  while IFS=: read -r lineno raw; do
    [ -n "$lineno" ] || continue
    pass_by_name_dispatches "$f" "$raw" "$fn" && printf '%s ' "$lineno"
  done < <(grep -nF "$fn" "$f")
}

# Every shell file a call site could live in. The scan is REPO-WIDE because the
# property is repo-wide: a predicate called from anywhere is not dead. Retreating
# to enrolled files narrowed the scope AND silently changed what DEAD means, so
# the same call produced a different verdict depending on which files happened to
# be enrolled - a verdict that depends on configuration rather than on the code.
consumer_files() {
  local d
  for d in "$ROOT/bin" "$ROOT/tests" "$ROOT/.agents"; do
    [ -d "$d" ] || continue
    find "$d" -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null
  done | sort -u
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
  [ -r "$f" ] || die "target is unreadable: $f" 4
  grep -qxF "$ENROL_MARKER" "$f" 2>/dev/null || die "target is not enrolled: $f" 4
  if ! refusal=$(file_parse_refusal "$f"); then
    die "UNCHECKED $f:${refusal%%:*} unsupported construct: ${refusal#*:}" 4
  fi
done

# Partition every consumer into those this control can reason about and those it
# cannot. An unchecked consumer is NAMED, not skipped: the list is the honest
# measurement of how much of the repository this control can actually see, and
# the way to shorten it is to make more files parse.
PARSEABLE=()
UNCHECKED_CONSUMERS=()
UNCHECKED_FILES=()
while IFS= read -r cf; do
  [ -n "$cf" ] || continue
  [ -r "$cf" ] || { UNCHECKED_CONSUMERS+=("$cf: unreadable"); UNCHECKED_FILES+=("$cf"); continue; }
  if refusal=$(file_parse_refusal "$cf"); then
    PARSEABLE+=("$cf")
  else
    UNCHECKED_CONSUMERS+=("$cf:${refusal%%:*} ${refusal#*:}")
    UNCHECKED_FILES+=("$cf")
  fi
done < <(consumer_files)

FUNCTIONS=()
for f in "${FILES[@]}"; do
  while IFS= read -r line; do FUNCTIONS+=("${line#*:}"); done < <(function_definitions "$f")
done

collect_marks

VALIDATED_SCANNABLE=()
for f in "${PARSEABLE[@]}"; do
  unsupported=''
  executable=$(strip_cached "$f")
  for fn in "${FUNCTIONS[@]}"; do
    # Most consumers mention none of the enrolled functions. Avoid launching
    # the per-function classifier unless this file can actually contribute a
    # use of that name.
    case $executable in
      *"$fn"*) ;;
      *) continue ;;
    esac
    # A mark whose VERIFIED site is in this file explains this file's use of that
    # name, so the unsupported-form complaint below is not raised for it. The
    # suppression follows the site rather than the comment: a mark that names no
    # dispatch here suppresses nothing, and the file goes unchecked as it would
    # have with no mark at all.
    observed_lines="$(mark_observed_lines "$fn" "$f")$(proven_pass_by_name_lines "$fn" "$f")"
    unsupported=$(printf '%s\n' "$executable" | awk -v fn="$fn" -v observed_lines="$observed_lines" '
      BEGIN { term = "([[:space:];|&(){}<>]|$)" }
      # A line that does not contain the name as a SUBSTRING cannot match any
      # rule below, because every rule that concludes anything embeds the name.
      # Skipping the regex battery for those lines is a pure prefilter, not a
      # narrowing of the accepted syntax, and it is what makes a repo-wide run
      # cheap enough to sit on the automatic check path.
      index($0, fn) == 0 { next }
      index(" " observed_lines, " " NR " ") { next }
      $0 ~ "^[[:space:]]*#" { next }
      $0 ~ ("^" fn "\\(\\)[[:space:]]*\\{") { next }
      $0 ~ ("^[[:space:]]*((if|then|elif|else|while|until|do|!|command|builtin|env)[[:space:]]+)*" fn term) { next }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"?\\$\\(" fn term) { next }
      $0 ~ ("^[A-Za-z_][A-Za-z0-9_]*\\(\\)[[:space:]]*\\{[[:space:]]*" fn term) { next }
      $0 ~ ("^[^\"\047`]*([;|&(){}])[[:space:]]*" fn term) { next }
      $0 ~ ("\\$\\(" fn term) { next }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\\$\\(.*[[:space:]]\\|[[:space:]]*" fn term) { next }
      $0 ~ ("^[[:space:]]*(if|while|until)[[:space:]].*[[:space:]](\\|\\||&&)[[:space:]]*(![[:space:]]*)?" fn term) { next }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*[[:space:]](\\|\\||&&)[[:space:]]*" fn term) { next }
      $0 ~ ("^[[:space:]]*.*[[:space:]](\\|\\||&&)[[:space:]]*" fn term) { next }
      $0 ~ ("^[[:space:]]*if[[:space:]].*[[:space:]]\\|[[:space:]]*" fn term) { next }
      $0 ~ ("^[[:space:]]*\\{.*[[:space:]](&&|\\|\\|)[[:space:]]*!?[[:space:]]*" fn term) { next }
      $0 ~ ("[[:space:]]\\|\\|[[:space:]]*\\{[[:space:]]*" fn term) { next }
      # A CONTINUATION LINE that opens with || or && , optionally negated. This is
      # a genuine call site and a common idiom - measured at 65 occurrences across
      # bin/ - so its absence was the whitelist being under-specified rather than
      # the code being unusual. Added on that measurement, NOT to make a file pass:
      # widening an accepted-syntax list to silence a refusal is shaping a control
      # around its own answer, which is the failure this whitelist exists to avoid.
      $0 ~ ("^[[:space:]]*(\\|\\||&&)[[:space:]]*(![[:space:]]*)?" fn term) { next }
      $0 ~ ("^[[:space:]]*trap[[:space:]]+" fn term) { next }
      $0 ~ ("^[[:space:]]*(if|elif)[[:space:]].*;[[:space:]]*then[[:space:]]+" fn term) { next }
      $0 ~ /^[[:space:]]*printf[[:space:]]/ { next }
      $0 ~ ("(^|[[:space:];|&(){}])" fn "([[:space:];|&(){}]|$)") { print NR ":" $0; exit }
    ')
    [ -z "$unsupported" ] || break
  done
  if [ -n "$unsupported" ]; then
    UNCHECKED_CONSUMERS+=("$f:${unsupported%%:*} unsupported call-site form for $fn: ${unsupported#*:}")
    UNCHECKED_FILES+=("$f")
  else
    VALIDATED_SCANNABLE+=("$f")
  fi
done
SCANNABLE=("${VALIDATED_SCANNABLE[@]}")

# Call identity does not depend on which parseable consumer contains the call.
# Build each corpus once so the verdict scan is functions + files rather than
# functions x files. Indirect-call comments are deliberately absent from the
# proof path: mark_verified above counts only marks whose exact site was re-read.
RAW_CALL_SITE_CORPUS="$STRIP_DIR/raw-call-sites"
STRIPPED_CALL_SITE_CORPUS="$STRIP_DIR/stripped-call-sites"
: > "$RAW_CALL_SITE_CORPUS"
: > "$STRIPPED_CALL_SITE_CORPUS"
for f in "${SCANNABLE[@]}"; do
  cat "$f" >> "$RAW_CALL_SITE_CORPUS"
  strip_cached "$f" >> "$STRIPPED_CALL_SITE_CORPUS"
done

# WHAT THE COMPLETENESS CLAIM COVERS, AND WHERE IT STOPS.
#
# The per-predicate universe check closes the class for THIS control's own
# enumeration path: every read it performs is three-valued, and a read that fails
# yields could-not-observe rather than a negative answer.
#
# It does NOT close the class for the shared landing library this control's
# callers use. fm_landed_candidate_refs returns success whenever ANY candidate ref
# resolved, so a push-target read that fails inside the library leaves that ref
# simply absent from a NON-EMPTY list. From outside, an incomplete candidate set
# is indistinguishable from a complete one, and no check here can detect it.
#
# That gap is filed as landed-lib-unreadable-push-target-collapses and is
# deliberately out of scope here: the library is shared with the worktree guard,
# teardown, the decision surface and the task-base library, and changing its
# landing semantics from a task about outbound transport would be an unreviewed
# change to the guards that protect unlanded work.
#
# So the claim is scoped rather than class-wide, and saying so is the point: a
# control named class-level that silently depended on someone else's unfixed
# read would be the coverage inflation this file's other scope note refuses.

# WHY THIS MATCH IS ALLOWED TO BE LOOSE, AND WHERE THAT STOPS.
#
# The grep below is a bare identifier match with no syntax analysis behind it. It
# is legitimate here, and ONLY here, because of what it is used FOR: it decides
# whether an unparseable file belongs in a predicate's candidate universe, and
# the answer is only ever used to EXCLUDE. A false positive costs a
# COULD_NOT_OBSERVE - the control says "I could not tell" about a predicate that
# may in fact be dead. That is a wasted opportunity and nothing worse.
#
# The identical looseness used to CONFIRM that a call exists would be the
# opposite: it would let a mention in a comment, a quoted string or a heredoc
# payload establish that a predicate is ALIVE, which is discovery mistaken for
# identity - the defect this file has been falsified over seven times. A false
# positive there does not cost an opportunity, it hides a dead guard behind
# evidence that was never a call.
#
# So the asymmetry is the licence, not an accident of implementation: loose to
# EXCLUDE, never to CONFIRM. Nothing may route a call-site confirmation through
# UNCHECKED_CANDIDATES or through function_has_unchecked_candidate. Confirmation
# goes through function_has_call_site, which reads quote-stripped text and
# accepts only the enumerated call forms.
UNCHECKED_CANDIDATES=()
for f in "${UNCHECKED_FILES[@]}"; do
  if [ ! -r "$f" ]; then
    UNCHECKED_CANDIDATES+=("${FUNCTIONS[@]}")
    continue
  fi
  for fn in "${FUNCTIONS[@]}"; do
    grep -Eq "(^|[^A-Za-z0-9_])$fn([^A-Za-z0-9_]|$)" "$f" \
      && UNCHECKED_CANDIDATES+=("$fn")
  done
done

function_has_unchecked_candidate() {  # <function>
  local fn=$1 candidate
  for candidate in "${UNCHECKED_CANDIDATES[@]}"; do
    [ "$candidate" = "$fn" ] && return 0
  done
  return 1
}

dead_json='[]'
marked_json='[]'
cno_json='[]'
DEAD=0
MARKED=0
CNO=0
ALIVE=0
REFUSED=${#REFUSED_MARKS[@]}
refused_json=$(printf '%s\n' "${REFUSED_MARKS[@]:-}" \
  | jq -R 'select(length > 0) | split("\t")
           | {file:.[0],line:(.[1]|tonumber),function:.[2],site:.[3],reason:.[4]}' \
  | jq -s .)

for f in "${FILES[@]}"; do
  [ -r "$f" ] || die "target is unreadable: $f" 4
  grep -qxF "$ENROL_MARKER" "$f" 2>/dev/null || die "target is not enrolled: $f" 4
  while IFS= read -r line; do
    lineno=${line%%:*}
    fn=${line#*:}
    [ -n "$fn" ] || continue
    if function_has_call_site "$fn"; then ALIVE=$((ALIVE + 1)); continue; fi
    prev=$((lineno - 1))
    if [ "$prev" -ge 1 ] && sed -n "${prev}p" "$f" | grep -qF "$KEEP_MARKER"; then
      reason=$(sed -n "${prev}p" "$f" | sed "s/.*${KEEP_MARKER}[[:space:]]*//")
      marked_json=$(printf '%s' "$marked_json" | jq --arg f "$f" --arg fn "$fn" \
        --argjson l "$lineno" --arg r "$reason" '. + [{file:$f,function:$fn,line:$l,reason:$r}]')
      MARKED=$((MARKED + 1))
      continue
    fi
    # No call site among the files this control can read. Whether that means
    # DEAD depends on whether it could read everywhere: with an unchecked
    # consumer outstanding, the call site may be in a file nobody looked at, and
    # asserting DEAD there would licence deleting live code. Missing a dead
    # predicate wastes an opportunity; deleting a live one is an outage.
    if function_has_unchecked_candidate "$fn"; then
      cno_json=$(printf '%s' "$cno_json" | jq --arg f "$f" --arg fn "$fn" --argjson l "$lineno" \
        '. + [{file:$f,function:$fn,line:$l}]')
      CNO=$((CNO + 1))
      continue
    fi
    dead_json=$(printf '%s' "$dead_json" | jq --arg f "$f" --arg fn "$fn" --argjson l "$lineno" \
      '. + [{file:$f,function:$fn,line:$l}]')
    DEAD=$((DEAD + 1))
  done < <(function_definitions "$f")
done

if [ "$JSON" -eq 1 ]; then
  jq -n --argjson dead "$dead_json" --argjson marked "$marked_json" \
    --argjson cno "$cno_json" \
    --argjson files "$(printf '%s\n' "${FILES[@]}" | jq -R . | jq -s .)" \
    --argjson unchecked "$(printf '%s\n' "${UNCHECKED_CONSUMERS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
    --argjson scanned "${#SCANNABLE[@]}" --argjson alive "$ALIVE" \
    --argjson refused "$refused_json" \
    '{schema:"fm-dead-predicate-check.v2",enrolled:$files,scanned_consumers:$scanned,
      unchecked_consumers:$unchecked,alive:$alive,dead:$dead,could_not_observe:$cno,
      refused_marks:$refused,marked:$marked}'
else
  printf '%s' "$marked_json" | jq -r '.[] |
    "  marked   \(.function)  \(.file):\(.line)  unused by design: \(.reason)"'
  printf '%s' "$refused_json" | jq -r '.[] |
    "  REFUSED  \(.function)  \(.file):\(.line)  indirect-call mark \(.reason)"'
  printf '%s' "$cno_json" | jq -r '.[] |
    "  CNO      \(.function)  \(.file):\(.line)  no call site among files this control can read"'
  printf '%s' "$dead_json" | jq -r '.[] |
    "  DEAD     \(.function)  \(.file):\(.line)  defined and never consulted"'
  if [ "${#UNCHECKED_CONSUMERS[@]}" -gt 0 ]; then
    printf '\n%s consumer file(s) UNCHECKED - outside the accepted syntax, so no call site in them was read:\n' \
      "${#UNCHECKED_CONSUMERS[@]}"
    printf '  %s\n' "${UNCHECKED_CONSUMERS[@]}"
    printf 'This list measures how much of the repository this control can see. Shorten it by making files parse.\n'
  fi
  if [ "$REFUSED" -gt 0 ]; then
    printf '\n%s indirect-call mark(s) REFUSED: the site each names does not dispatch the function.\n' "$REFUSED"
    printf 'A mark declares WHERE a call is made and is counted only when that site is re-read and the\n'
    printf 'function is found there in an executable position. Point each mark at the real dispatch, or\n'
    printf 'delete the mark and let the verdict the code supports stand.\n'
  fi
  if [ "$DEAD" -eq 0 ] && [ "$CNO" -eq 0 ] && [ "$REFUSED" -eq 0 ]; then
    # alive=, could_not_observe= and refused= are printed ALWAYS, including when
    # all three are zero. A line reading only "no dead predicates" is equally
    # consistent with every predicate resolved and with none of them being
    # resolvable, and those are different facts. A quiet control must never read
    # as a clean repository.
    printf 'fm-dead-predicate-check: ok enrolled=%s scanned=%s unchecked=%s alive=%s could_not_observe=%s refused=%s marked=%s\n' \
      "${#FILES[@]}" "${#SCANNABLE[@]}" "${#UNCHECKED_CONSUMERS[@]}" "$ALIVE" "$CNO" "$REFUSED" "$MARKED"
  elif [ "$DEAD" -gt 0 ]; then
    printf '\n%s function(s) exist but nothing consults them. A guard nothing calls is not a guard.\n' "$DEAD"
    printf 'Wire each one in, or mark the definition with "# %s <reason>" on the line above it.\n' "$KEEP_MARKER"
  elif [ "$CNO" -gt 0 ]; then
    printf '\n%s function(s) COULD NOT BE OBSERVED: no call site was found, but an unchecked consumer may hold one.\n' "$CNO"
    printf 'That is not a pass and not a dead predicate. Make the unchecked consumers parse to resolve it.\n'
  fi
fi

# Exit is three-valued and in that order of severity. Unchecked consumers ALONE
# never make this red: a control that is permanently red gets ignored and then
# removed, and every case it enforces would be lost with it. They are reported
# and counted, and only bite when a predicate's verdict actually depends on one.
#
# A REFUSED mark is red at the same severity as a dead predicate, and for the same
# reason: both are a written claim the code does not support. A mark whose site
# does not dispatch is manufactured call evidence, which is worse than a missing
# call site because it reads as proof.
if [ "$DEAD" -gt 0 ] || [ "$REFUSED" -gt 0 ]; then exit 3; fi
[ "$CNO" -eq 0 ] || exit 4
exit 0
