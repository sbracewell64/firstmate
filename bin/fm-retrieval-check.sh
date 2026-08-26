#!/usr/bin/env bash
# fm-retrieval-check.sh - reject a new load-bearing pagination-sensitive direct
# read, and enumerate the whole candidate universe of such reads for audit.
#
# WHY A CHECK RATHER THAN AN INSTRUCTION
#
# "Remember to paginate" has now failed twice in this fleet on the same defect,
# once as "read the newest record" and once as "scan by timestamp". Both fixes
# were correct instructions and both were applied to the wrong layer, because an
# instruction is only consulted by whoever remembers it exists. Five separate
# scripts here independently re-derived a correct completeness proof - Link
# traversal, hasNextPage, total_count reconciliation, an n+1 cap sentinel, an
# escalation from a bounded tail to a full read - which is strong evidence that
# the discipline is understood and weak evidence that it will be applied next
# time. This check is what makes the next time mechanical.
#
# THE AXIS, NOT THE EXAMPLE
#
# A site is in scope when it reads a collection from outside this process where
# the returned extent is decided by the SOURCE - a page, a cap, a limit, a
# window, a scrollback bound - rather than by the caller, and its result can
# reach a conclusion of the form "no X exists", "nothing pending", "nothing
# new", "not present", or "already handled".
#
# The discovery pattern is deliberately over-broad against that axis: it matches
# every forge, relay, backlog, pipeline, and terminal read form in the tree,
# every explicit page or limit parameter, and message text that merely mentions
# one. Over-matching costs a one-line classification; under-matching costs the
# defect. The pattern is therefore never narrowed to make violations disappear.
#
# TWO PATTERNS, AND WHY THEY DIFFER
#
#   --check enforces classification on READ FORMS: an invocation, a chokepoint
#           call, or an explicit page/limit parameter.
#   --audit adds COMPLETENESS-PROOF TOKENS - total_count, totalCount,
#           hasNextPage, pageInfo, a GraphQL first:/last: - and bare forge
#           command names. Those tokens are evidence that a site already proves
#           its own extent, which is what an audit wants to find; they are not
#           themselves reads, and they occur inside multi-line quoted query
#           bodies where no comment can be placed. Enforcing them would demand an
#           annotation in a position the shell has no syntax for.
#
# The census is therefore strictly broader than the enforced set, and
# tests/fm-retrieval-contract.test.sh asserts that it stays that way.
#
# CLASSIFICATION
#
# Every enforced site carries an annotation either as a trailing comment on the
# site or as the whole-line comment immediately above it:
#
#   # fm-retrieval-audit: <class> - <reason>
#
# The class comes from a closed vocabulary and the reason is required, because a
# class with no reason is an assertion nobody can check:
#
#   contract              routed through bin/fm-control-read.sh or
#                         bin/fm-retrieval-lib.sh, which owns the completeness
#                         proof on this site's behalf.
#   complete-source       proves completeness by its own equivalent mechanism.
#                         The reason must name that mechanism.
#   chokepoint            a transport wrapper carrying no collection semantics
#                         of its own; its callers carry the classification.
#   not-a-collection      reads one object, pops a single-item queue, or fetches
#                         one named artifact. There is no extent to enumerate.
#   window-is-the-subject the claim's universe IS the bounded window, so nothing
#                         is concluded about records outside it.
#   bound-disclosed       bounded, and the bound travels with the result, so no
#                         caller can read the result as absence.
#   conservative-negative a false negative tightens the gate this feeds rather
#                         than loosening it. The reason must name the gate.
#   no-negative           the result cannot reach a negative conclusion:
#                         display-only, enrichment of an already-decided
#                         refusal, or a positive-only use.
#   not-a-read            the match is message text, a tool-presence probe, a
#                         definition line, or documentation. Nothing is read.
#   write                 an action, which has no observation type at all.
#
# A NEW CHOKEPOINT CANNOT ESCAPE BY NOT BEING LISTED. The enforced pattern names
# this tree's existing gh wrappers, but a new wrapper must still eventually call
# a forge or transport command, and that call is matched on its own line. The
# list is a convenience for naming callers, not the boundary.
#
# Usage:
#   fm-retrieval-check.sh --check [--root <dir>]   enforce classification
#   fm-retrieval-check.sh --audit [--root <dir>]   print the broad census
#   fm-retrieval-check.sh --list-classes
#   fm-retrieval-check.sh --pattern [--audit]      print the pattern in use
#   fm-retrieval-check.sh -h | --help
#
# Exit status: 0 when every scannable enforced site is classified and every
# tracked file is covered, 1 for an unclassified, unknown, or unreasoned site,
# and 2 for incomplete file coverage or a usage or environment error.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SELF_DIR/.." && pwd)"

MODE=
ROOT=$DEFAULT_ROOT
WANT_AUDIT_PATTERN=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  printf 'fm-retrieval-check: %s\n' "$1" >&2
  printf 'Run fm-retrieval-check.sh --help for usage.\n' >&2
  exit 2
}

CLASSES='contract complete-source chokepoint not-a-collection window-is-the-subject bound-disclosed conservative-negative no-negative not-a-read write'

# The enforced read forms. Each alternative is anchored on a non-identifier
# character so a longer name that merely contains one of these words is not a
# read: recheck_gh_rc is not recheck_gh, and a variable named curl_url is not
# curl.
ENFORCED_PATTERN='(^|[^A-Za-z0-9_.-])(gh|gh-axi|glab)[[:space:]]+(api|pr|issue|mr|run|release|repo|search|browse)([[:space:]]|$)'
ENFORCED_PATTERN=$ENFORCED_PATTERN'|(^|[^A-Za-z0-9_.-])(gh|gh-axi|glab)[[:space:]]+"[$]@"'
ENFORCED_PATTERN=$ENFORCED_PATTERN'|(^|[^A-Za-z0-9_.-])(gh_get|gh_bounded|recheck_gh)[[:space:]]'
ENFORCED_PATTERN=$ENFORCED_PATTERN'|(^|[^A-Za-z0-9_.-])curl[[:space:]]'
ENFORCED_PATTERN=$ENFORCED_PATTERN'|(^|[^A-Za-z0-9_.-])orca[[:space:]]+terminal[[:space:]]+read'
ENFORCED_PATTERN=$ENFORCED_PATTERN'|(^|[^A-Za-z0-9_.-])(tasks-axi|no-mistakes|nm_run)[[:space:]]+(list|ready|runs)'
ENFORCED_PATTERN=$ENFORCED_PATTERN'|per_page='  # fm-retrieval-audit: not-a-read - the enforced pattern's own text; nothing is read on this line
ENFORCED_PATTERN=$ENFORCED_PATTERN'|[?&]page='
ENFORCED_PATTERN=$ENFORCED_PATTERN'|--limit[[:space:]=]'
ENFORCED_PATTERN=$ENFORCED_PATTERN'|--paginate'  # fm-retrieval-audit: not-a-read - the enforced pattern's own text; nothing is read on this line

# The census adds the completeness-proof tokens and the bare forge command
# names, so an audit sees both the reads and the proofs.
AUDIT_PATTERN=$ENFORCED_PATTERN
AUDIT_PATTERN=$AUDIT_PATTERN'|total_count|totalCount|hasNextPage|pageInfo'
AUDIT_PATTERN=$AUDIT_PATTERN'|[(](first|last):'
AUDIT_PATTERN=$AUDIT_PATTERN'|(^|[^A-Za-z0-9_.-])(gh|gh-axi|glab)[[:space:]]'

NATIVE_PATTERN='(^|[^A-Za-z0-9_.-])(fetch|XMLHttpRequest)[[:space:]]*[(]'
NATIVE_PATTERN=$NATIVE_PATTERN'|(^|[^A-Za-z0-9_.-])(axios|octokit|urllib|requests|http[.]client)([^A-Za-z0-9_.-]|$)'
NATIVE_PATTERN=$NATIVE_PATTERN'|(^|[^A-Za-z0-9_.-])(child_process|subprocess).*([^A-Za-z0-9_.-]|^)(gh|gh-axi|glab)([^A-Za-z0-9_.-]|$)'

ANNOTATION='fm-retrieval-audit:'

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check) MODE=check; shift ;;
    --audit) MODE=${MODE:-audit}; WANT_AUDIT_PATTERN=1; shift ;;
    --pattern) MODE=${MODE:-pattern}; shift ;;
    --list-classes) printf '%s\n' "$CLASSES" | tr ' ' '\n'; exit 0 ;;
    --root) [ "$#" -ge 2 ] || die_usage "--root needs a directory"; ROOT=$2; shift 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

[ -n "$MODE" ] || die_usage "name a mode: --check or --audit"
[ -d "$ROOT" ] || die_usage "no such root: $ROOT"

if [ "$MODE" = pattern ]; then
  if [ "$WANT_AUDIT_PATTERN" = 1 ]; then
    printf '%s\n' "$AUDIT_PATTERN"
  else
    printf '%s\n' "$ENFORCED_PATTERN"
  fi
  exit 0
fi

# The universe is every tracked file, not a list of known implementations.
collect_files() {
  local listed=
  if [ -d "$ROOT/.git" ] || git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    listed=$(git -C "$ROOT" ls-files 2>/dev/null)
  fi
  if [ -z "$listed" ]; then
    listed=$(cd "$ROOT" && find . -type f 2>/dev/null | sed 's#^./##' | LC_ALL=C sort)
  fi
  printf '%s\n' "$listed" | awk 'NF'
}

UNIVERSE=$(collect_files)
if [ -z "$UNIVERSE" ]; then
  printf 'fm-retrieval-check: no files found under %s, so nothing was examined\n' \
    "$ROOT" >&2
  exit 2
fi

FILES=
OUT_OF_SCOPE=
UNCHECKED=
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if [ -L "$ROOT/$file" ]; then
    OUT_OF_SCOPE="${OUT_OF_SCOPE}${OUT_OF_SCOPE:+
}$file\tsymlink has no executable content of its own"
    continue
  fi
  case "$file" in
    docs/*|data/*|assets/*|tests/*|commitments/*|loopspecs/*|capabilities/*|LICENSE|*.md|*.txt|.gitignore|.gitattributes|.github/no-mistakes-attestation)
      OUT_OF_SCOPE="${OUT_OF_SCOPE}${OUT_OF_SCOPE:+
}$file\tfile is maintained prose, inert data, a static asset, or a test fixture"
      ;;
    *.sh|*.bash)
      FILES="${FILES}${FILES:+
}$file"$'\t'"shell"
      ;;
    .github/workflows/*.yml|.github/workflows/*.yaml)
      FILES="${FILES}${FILES:+
}$file"$'\t'"workflow"
      ;;
    *.py|*.js|*.mjs|*.cjs|*.ts|*.tsx|*.bat)
      FILES="${FILES}${FILES:+
}$file"$'\t'"native"
      ;;
    *.json|*.toml|*.yml|*.yaml)
      FILES="${FILES}${FILES:+
}$file"$'\t'"config"
      ;;
    *)
      UNCHECKED="${UNCHECKED}${UNCHECKED:+
}$file"
      ;;
  esac
done <<EOF
$UNIVERSE
EOF

# One awk pass per file. An annotation is accepted only in the applicable
# language's comment syntax and is consumed by exactly one read site.
scan_file() {  # <file> <classifier>
  local file=$1 classifier=$2 pattern=$ENFORCED_PATTERN
  [ "$MODE" = check ] || pattern=$AUDIT_PATTERN
  case "$classifier" in
    shell|workflow) ;;
    native) pattern="$pattern|$NATIVE_PATTERN" ;;
    config) pattern="$pattern|$NATIVE_PATTERN" ;;
    *) return 1 ;;
  esac
  awk -v file="$file" -v classifier="$classifier" -v pat="$pattern" -v anno="$ANNOTATION" -v classes="$CLASSES" '
    BEGIN {
      n = split(classes, c, " ")
      for (i = 1; i <= n; i++) known[c[i]] = 1
    }
    {
      lines[NR] = $0
    }
    END {
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        if (line !~ pat) continue
        statement_start = i
        while (statement_start > 1 && lines[statement_start - 1] ~ /\\[[:space:]]*$/) {
          statement_start--
        }
        if (statement_seen[statement_start]) continue
        statement_seen[statement_start] = 1
        # A whole-line comment reads nothing, so it is not a read site. This is
        # the axis applied, not the pattern narrowed: the axis is constructs that
        # READ a collection, and shell evaluates none of this line. Header prose
        # in this tree discusses gh flags and page parameters at length, and
        # demanding a classification for a sentence would price the check out of
        # being kept.
        if (line ~ /^[[:space:]]*#/) continue
        # A line whose ONLY match is inside its own annotation is the annotation,
        # not a read: classifying a classification would be circular.
        stripped = line
        if (index(line, anno) > 0) {
          sub(/#.*$/, "", stripped)
          if (stripped !~ pat) continue
        }
        found = ""
        reason = ""
        annotation_line = 0
        if (classifier == "native" && file ~ /[.](js|mjs|cjs|ts|tsx)$/) {
          whole_comment = "^[[:space:]]*//[[:space:]]*"
          trailing_comment = "//[[:space:]]*"
        } else if (classifier == "native" && file ~ /[.]bat$/) {
          whole_comment = "^[[:space:]]*(REM[[:space:]]+|::[[:space:]]*)"
          trailing_comment = ""
        } else {
          whole_comment = "^[[:space:]]*#[[:space:]]*"
          trailing_comment = "#[[:space:]]*"
        }
        at = index(line, anno)
        prefix = at > 0 ? substr(line, 1, at - 1) : ""
        if (at > 0 && trailing_comment != "" && prefix ~ trailing_comment) {
          annotation_line = i
        } else if (statement_start > 1 && lines[statement_start - 1] ~ whole_comment && index(lines[statement_start - 1], anno) > 0) {
          annotation_line = statement_start - 1
        }
        if (annotation_line > 0 && !claimed[annotation_line]) {
          claimed[annotation_line] = 1
          at = index(lines[annotation_line], anno)
          rest = substr(lines[annotation_line], at + length(anno))
          sub(/^[[:space:]]+/, "", rest)
          split(rest, w, " ")
          found = w[1]
          reason = rest
          sub(/^[^[:space:]]+[[:space:]]*-?[[:space:]]*/, "", reason)
        }
        if (found == "") {
          printf "UNCLASSIFIED\t%s:%d\t%s\n", file, i, line
          continue
        }
        if (!(found in known)) {
          printf "UNKNOWN-CLASS\t%s:%d\t%s\t%s\n", file, i, found, line
          continue
        }
        if (reason == "") {
          printf "NO-REASON\t%s:%d\t%s\t%s\n", file, i, found, line
          continue
        }
        printf "%s\t%s:%d\t%s\n", found, file, i, reason
      }
    }
  ' "$ROOT/$file"
}

RESULTS=$(printf '%s\n' "$FILES" | while IFS=$'\t' read -r f classifier; do
  [ -n "$f" ] || continue
  scan_file "$f" "$classifier"
done)

COVERAGE=complete
[ -z "$UNCHECKED" ] || COVERAGE=incomplete

emit_coverage() {
  printf 'fm-retrieval-check: coverage=%s scanned=%s out_of_scope=%s universe=%s\n' \
    "$COVERAGE" "$(printf '%s\n' "$FILES" | awk 'NF' | wc -l | tr -d ' ')" \
    "$(printf '%s\n' "$OUT_OF_SCOPE" | awk 'NF' | wc -l | tr -d ' ')" \
    "$(printf '%s\n' "$UNIVERSE" | awk 'NF' | wc -l | tr -d ' ')"
  [ -z "$UNCHECKED" ] || printf '%s\n' "$UNCHECKED" | sed 's/^/UNCHECKED\t/'
}

SITES=$(printf '%s\n' "$RESULTS" | awk 'NF' | wc -l | tr -d ' ')
VIOLATIONS=$(printf '%s\n' "$RESULTS" \
  | awk -F '\t' '$1 == "UNCLASSIFIED" || $1 == "UNKNOWN-CLASS" || $1 == "NO-REASON"')

if [ "$MODE" = audit ]; then
  printf 'fm-retrieval-check: census root=%s sites=%s\n' "$ROOT" "$SITES"
  printf '\nclassification census:\n'
  printf '%s\n' "$RESULTS" | awk -F '\t' 'NF { print $1 }' \
    | LC_ALL=C sort | uniq -c | LC_ALL=C sort -rn | sed 's/^/  /'
  printf '\nsites:\n'
  printf '%s\n' "$RESULTS" | awk -F '\t' 'NF { printf "  %s\t%s\t%s\n", $2, $1, $3 }'
  emit_coverage
  [ "$COVERAGE" = complete ] && exit 0
  exit 2
fi

if [ -n "$VIOLATIONS" ]; then
  printf 'fm-retrieval-check: %s read site(s) reach a negative conclusion with no recorded classification.\n' \
    "$(printf '%s\n' "$VIOLATIONS" | wc -l | tr -d ' ')" >&2
  printf '\n' >&2
  printf '%s\n' "$VIOLATIONS" | while IFS=$'\t' read -r kind where rest; do
    case "$kind" in
      UNCLASSIFIED)
        printf '  %s: no %s annotation\n    %s\n' "$where" "$ANNOTATION" "$rest" >&2
        ;;
      UNKNOWN-CLASS)
        printf '  %s: class "%s" is not in the closed vocabulary\n' "$where" "$rest" >&2
        ;;
      NO-REASON)
        printf '  %s: class "%s" carries no reason\n' "$where" "$rest" >&2
        ;;
    esac
  done
  cat >&2 <<EOF

Each site must either route its read through bin/fm-control-read.sh, which owns
the completeness proof, or carry the reason it does not need to:

  # $ANNOTATION <class> - <why a negative conclusion here is sound>

as a trailing comment or the whole-line comment immediately above it. Run
'fm-retrieval-check.sh --list-classes' for the vocabulary and this script's
header for what each class means.
EOF
  emit_coverage >&2
  exit 1
fi

if [ "$COVERAGE" != complete ]; then
  emit_coverage >&2
  exit 2
fi

emit_coverage
printf 'fm-retrieval-check: ok sites=%s root=%s\n' "$SITES" "$ROOT"
# The class breakdown is printed on the passing path too, because "every site is
# classified" and "which reasons the tree is relying on" are different facts and
# only the second one tells a reader whether the mix looks right.
printf '%s\n' "$RESULTS" | awk -F '\t' 'NF { print $1 }' \
  | LC_ALL=C sort | uniq -c | LC_ALL=C sort -rn | sed 's/^/  /'
exit 0
