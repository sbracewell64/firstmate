# shellcheck shell=bash
# fm-qualification-lib.sh - the single owner of the ROLE QUALIFICATION decision:
# "has this exact binding been OBSERVED to do this named job, and does that
# observation still apply?"
# Usage: . bin/fm-qualification-lib.sh
#
# WHY THIS EXISTS. A route can require a capability nothing in this fleet could
# answer. When it did, the only available outcome was to ask the captain for a
# task-specific floor exception, over and over, for the same missing evidence -
# because missing qualification and incapability were the same value. The
# 2026-08-13 captain ruling separates them: missing qualification is an
# engineering state to resolve, a candidate that may satisfy a blocked route is
# qualified empirically through a bounded representative workflow, and that
# evidence is REUSED. Model names are bindings to capability contracts, not the
# contracts themselves.
#
# ONE OWNER PER QUESTION, and this library owns exactly one of them:
#
#   CONTRACT      qualifications/contracts/*.json   what the job IS, as an
#                                     executable predicate plus a reusable
#                                     role/risk version. Vendor-neutral by
#                                     validation, not by convention.
#   RECORD        qualifications/records/*.json plus the gitignored
#                                     data/qualifications/records/ overlay - what
#                                     was OBSERVED, once, against named bytes.
#   STATE         this library        the value a reader acts on, COMPUTED on
#                                     every read from the record plus a fresh
#                                     dependency observation. Never stored.
#   ELIGIBLE      bin/fm-route-lib.sh merges the state this library produces into
#                                     candidate eligibility, exactly as it merges
#                                     the model registry's verdict and the
#                                     capacity observation. It re-decides none of
#                                     them.
#
# What this library deliberately does NOT own, because each already has an owner
# and qualifications/schema.json's `axes` block refuses the collapse: cost and
# routability and concurrency (bin/fm-model-registry-lib.sh), availability
# (bin/fm-route-lib.sh over state/model-health.json), capacity
# (bin/fm-capacity-lib.sh), entitlement (bin/fm-model-verify.sh), attempt and
# custody accounting (bin/fm-attempt.sh), and the pipeline-derived per-run
# verifier independence verdict (bin/fm-independence-lib.sh). A qualified binding
# is not an available one and an available binding is not a qualified one; that
# second reading is the one the ruling names, because one vendor being reachable
# is not evidence that runtime engineering can proceed, and one vendor being
# unreachable is not evidence that it cannot when another binding satisfies the
# same predicates.
#
# FIVE VALUES, NEVER TWO, AND NEVER THREE.
# bin/fm-verify-lib.sh owns this fleet's three-valued observation type and is the
# right shape for "did the predicate run?". It is not enough for "may this
# candidate be routed?", because three distinct non-pass answers demand three
# different actions:
#
#   QUALIFIED               route it.
#   FAILED                  exclude it, and keep the evidence. Never delete an
#                           adverse observation.
#   QUALIFICATION_REQUIRED  qualify it. Missing evidence, not incapability.
#   QUALIFICATION_STALE     qualify it again. Stale evidence, not incapability.
#   COULD_NOT_OBSERVE       repair the observation. Neither a pass nor a negative,
#                           and never a reputation.
#
# Collapsing the middle three into one is the defect this whole register exists
# to close: it is what made "we have no evidence" arrive at the captain as "no
# model can do this".
#
# THREE AXES, NOT ONE, and the state above is only the first of them. A second
# measured defect came from reading the state as though it also answered the
# other two: two bindings held FAILED records, a contract generation was bumped,
# and because a contract version is a declared freshness dependency EVERY FAILED
# record read QUALIFICATION_REQUIRED - which is the one classification
# `activate` accepts. A version bump alone turned bindings that had been tried
# and rejected into automatically activatable ones.
#
#   state              what was OBSERVED about this binding. Five values.
#   applicability      whether that observation still APPLIES, from the declared
#                      freshness dependencies alone. CURRENT, STALE, or
#                      COULD_NOT_OBSERVE.
#   retry_disposition  whether another INVOCATION of this binding is permitted.
#                      permitted, not-permitted, or unknown.
#
# The bump moves the second. It must never move the first, and it moves the
# third only through an explicit material-change predicate: the contract's
# declared predicate generation differing from the one the adverse record was
# graded by, with the new generation's manifest not declaring the failed
# predicates carried forward unchanged. Absent either declaration the answer is
# `unknown`, which withholds the retry without ever recording that the binding
# changed. Only an ADVERSE record can withhold one; a stale pass stays retryable,
# because refusing there would freeze it forever.
#
# ENFORCEMENT SCOPE - the same deliberate asymmetry the model registry and the
# routed pools use:
#
#   No floor declares requires_capabilities -> inert. Nothing is read, no
#                           candidate is withheld, and a home that never opted in
#                           behaves exactly as it did before this existed.
#   A floor declares it     -> fail CLOSED. An unreadable register, an absent
#                           record, an inadmissible record and an unobservable
#                           dependency all WITHHOLD the candidate.
#
# That is the opposite of the quota gate, which fails toward dispatch, and the
# difference is a property of the input rather than a preference. An unobserved
# quota can only ever REMOVE a candidate the policy already admitted. This is the
# requirement ITSELF: failing to observe it would admit a candidate on no
# evidence, which is the exact substitution the ruling forbids.
#
# HOW EXACT THE MATCH IS DEPENDS ON WHO IS ASKING, and both callers use one
# function. A record's KEY is the whole tuple - contract, model, harness, native
# effort - because a different harness or a different effort band is a different
# thing that was never observed, not a stale version of something that was.
# `fm-route.sh eligible` asks at POOL level and names no harness or effort, so it
# gets the model-level answer with the record's own harness and effort reported.
# The spawn chokepoint knows both and passes both, so it gets the exact-tuple
# answer. A pool-level QUALIFIED that the chokepoint then refuses is the same
# relationship routing eligibility already has with the registry and the Luna
# binding, and the near-miss list is printed precisely so the difference is
# visible rather than surprising.
#
# qualifications/schema.json owns the field contract, the state computation and
# the closed vocabularies. This header owns the mechanics.

# Idempotent guard: the route library, the spawn chokepoint and the standalone
# command may all be in one process tree.
if [ -n "${FM_QUALIFICATION_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_QUALIFICATION_LIB_SOURCED=1

FM_QUALIFICATION_SCHEMA_VERSION=1
FM_QUALIFICATION_STATE_SCHEMA='fm-qualification-state.v1'

# Stable tokens. Tests and callers match these rather than prose.
# shellcheck disable=SC2034 # Contract constants are consumed by sourcing callers.
{
FM_QUAL_TOKEN_UNREADABLE=FM_QUALIFICATION_REGISTER_UNREADABLE
FM_QUAL_TOKEN_CONTRACT_UNKNOWN=FM_QUALIFICATION_CONTRACT_UNKNOWN
FM_QUAL_TOKEN_INADMISSIBLE=FM_QUALIFICATION_RECORD_INADMISSIBLE
FM_QUAL_TOKEN_SELF_REVIEW=FM_QUALIFICATION_SELF_REVIEW_REFUSED
FM_QUAL_TOKEN_REQUIRED=FM_QUALIFICATION_REQUIRED
FM_QUAL_TOKEN_STALE=FM_QUALIFICATION_STALE
FM_QUAL_TOKEN_DUPLICATE=FM_QUALIFICATION_ALREADY_ACTIVE
FM_QUAL_TOKEN_NO_PROMISING=FM_QUALIFICATION_NO_PROMISING_CANDIDATE
FM_QUAL_TOKEN_RETRY_REFUSED=FM_QUALIFICATION_RETRY_NOT_PERMITTED
}

# The five-value result vocabulary, spelled once. A synonym is refused rather
# than normalized: the measured failure this register was built from was a
# candidate emitting `inconclusive` and an evaluator being tempted to read it
# charitably as could-not-observe.
FM_QUALIFICATION_RESULTS='QUALIFIED
FAILED
QUALIFICATION_REQUIRED
QUALIFICATION_STALE
COULD_NOT_OBSERVE'

# The nine axes, spelled once. A contract declares exactly one.
FM_QUALIFICATION_AXES='maker_qualification
design_challenge
exact_change_review
assignment_independence
provider_account_pool_identity
availability
cost
entitlement
attempt_custody_accounting'

# Dependency kinds whose current value this fleet can actually probe, and the
# ones it deliberately cannot. An uncovered kind is always MARKED and never read
# as unchanged; a record declaring one must also declare a time_bound, which is
# how an unprobeable dependency is bounded rather than either ignored or fatal.
FM_QUALIFICATION_PROBED_KINDS='file_digest
contract_version
time_bound'
FM_QUALIFICATION_UNCOVERED_KINDS='harness_semantics
binding_semantics
native_effort_mapping'

FM_QUALIFICATION_REFUSED_RECORD_KEYS='state
current_state
derived_state
qualification_state
key
tuple_key
fresh
stale
eligible
score
reputation
rank
verdict
applicability
retry_disposition'

# The three values of the SEPARATED retry axis, and the two a record may DECLARE.
# The declared vocabulary is deliberately narrower: a record may say that a
# retry is settled or that it is not, and the interpreter alone may say that the
# answer could not be observed. `not-permitted-unchanged-predicate` spells its own
# ground in its name so a reader never has to go looking for why.
FM_QUALIFICATION_DECLARED_DISPOSITIONS='permitted
not-permitted-unchanged-predicate'

FM_QUALIFICATION_REFUSED_CONTRACT_KEYS='models
bindings
binding
providers
provider
vendors
vendor
harnesses
harness
model'

# ---------------------------------------------------------------------------
# Location
# ---------------------------------------------------------------------------

# The tracked code root. Resolved from this file's own location so a sourcing
# caller in any directory agrees, and overridable only through the same variable
# every other script in this repo honours.
fm_qualification_code_root() {
  printf '%s\n' "${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
}

fm_qualification_home() {
  printf '%s\n' "${FM_HOME:-$(fm_qualification_code_root)}"
}

# Every location is overridable as a WHOLE DIRECTORY rather than as a root with a
# suffix bolted on, so a test or a secondmate home names exactly the directory it
# means and no caller has to know this layout to redirect it.
fm_qualification_contract_dir() {
  if [ -n "${FM_QUALIFICATION_CONTRACT_DIR:-}" ]; then
    printf '%s\n' "$FM_QUALIFICATION_CONTRACT_DIR"
    return 0
  fi
  printf '%s/qualifications/contracts\n' "$(fm_qualification_code_root)"
}

# Records come from two places and the difference is deliberate. The tracked
# register ships to every home; the gitignored overlay is for a binding or an
# evidence trail a home must not publish into a shared template repo. The
# overlay's ABSENCE is silent - a home with nothing private has nothing to say -
# while a tracked register that exists and cannot be read is could-not-observe.
fm_qualification_record_dirs() {
  local tracked overlay
  tracked="${FM_QUALIFICATION_RECORD_DIR:-$(fm_qualification_code_root)/qualifications/records}"
  overlay="${FM_QUALIFICATION_OVERLAY_DIR:-$(fm_qualification_home)/data/qualifications/records}"
  printf '%s\n' "$tracked"
  [ "$overlay" = "$tracked" ] || printf '%s\n' "$overlay"
}

# ---------------------------------------------------------------------------
# Path resolution for a declared target
# ---------------------------------------------------------------------------

# fm_qualification_resolve_target <code:rel|home:rel>
# The one place a declared path becomes a real one. Prints the absolute path and
# returns 0; prints the refusal reason on stdout and returns 1 when the target is
# not one this register may name.
#
# The rule is commitments/schema.json's, restated in code because the hazard is
# the same one: a record can arrive from a gitignored overlay nobody reviewed, so
# an absolute path, an upward traversal and a symlink are each refused. What a
# symlink resolves to is not what was audited, so being inside the root does not
# save it. An ABSENT target is NOT refused here - absence is an observation the
# caller reports as could-not-observe, and refusing it would report a missing
# fixture as a malformed record.
fm_qualification_resolve_target() {
  local spec=$1 root rel abs
  case "$spec" in
    code:*) root=$(fm_qualification_code_root); rel=${spec#code:} ;;
    home:*) root=$(fm_qualification_home); rel=${spec#home:} ;;
    *) printf 'target must begin with code: or home:, got %s\n' "$spec"; return 1 ;;
  esac
  case "$rel" in
    '') printf 'target names no path\n'; return 1 ;;
    /*) printf 'absolute target refused: %s\n' "$rel"; return 1 ;;
    *..*) printf 'upward traversal refused: %s\n' "$rel"; return 1 ;;
  esac
  abs="$root/$rel"
  if [ -L "$abs" ]; then
    printf 'symlinked target refused: %s\n' "$rel"
    return 1
  fi
  printf '%s\n' "$abs"
}

fm_qualification_sha256() {  # <file>
  [ -f "$1" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 2
  fi
}

fm_qualification_today() {
  printf '%s\n' "${FM_QUALIFICATION_TODAY:-$(date -u +%Y-%m-%d)}"
}

# ---------------------------------------------------------------------------
# Reading contracts and records
# ---------------------------------------------------------------------------

fm_qualification_contract_file() {  # <contract-id>
  printf '%s/%s.json\n' "$(fm_qualification_contract_dir)" "$1"
}

# fm_qualification_contract <contract-id>
# Print the contract JSON. 0 read, 1 absent, 2 present and unreadable.
fm_qualification_contract() {
  local file=$1
  file=$(fm_qualification_contract_file "$1")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  jq -c . "$file" 2>/dev/null || return 2
}

# Every record file in both dirs, one path per line. An unreadable DIRECTORY is
# reported by exit 2 rather than as an empty listing, because "no records" and "I
# could not look" are the answers this whole file exists to keep apart.
fm_qualification_record_files() {
  local dir f found=0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] || continue
    if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
      return 2
    fi
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      printf '%s\n' "$f"
      found=1
    done
  done <<EOF
$(fm_qualification_record_dirs)
EOF
  [ "$found" -eq 1 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# One violation per line, nothing when sound, exit 2 when the file could not be
# read at all. An inadmissible contract or record is never used: a safety record
# that cannot be validated must not read as one that passed.
#
# VENDOR NEUTRALITY IS ENFORCED HERE, in two layers. The refused keys catch the
# obvious shape. The second layer refuses any string value in the contract that
# equals a model or provider this home's routing config configures, which is what
# catches a vendor smuggled into a purpose sentence or a predicate argument. A
# contract that names a vendor stops being re-runnable against the next
# candidate, and re-running it against the next candidate is the entire point of
# having qualified one.
fm_qualification_contract_problems() {  # <contract-file> [<routed-names-file>]
  local file=$1 names=${2:-}
  command -v jq >/dev/null 2>&1 || return 2
  jq -e . "$file" >/dev/null 2>&1 || { printf 'not readable JSON\n'; return 0; }
  local names_json='[]'
  if [ -n "$names" ] && [ -f "$names" ]; then
    # An EMPTY names file makes `jq -R -s` print nothing and still exit 0, so the
    # `||` fallback never fires and --argjson would be handed an empty string -
    # which jq refuses, turning "this home configures no routed model" into "the
    # validator could not run" for every file. Emptiness is checked outright.
    names_json=$(jq -R -s -c '[split("\n")[] | select(length > 0)]' <"$names" 2>/dev/null) || names_json=
    [ -n "$names_json" ] || names_json='[]'
  fi
  # NAMED args, and the file is the INPUT. jq's --args makes every remaining
  # argument a positional STRING and switches the input to stdin - so a file
  # passed alongside it is silently never read, the program evaluates against an
  # empty stdin, and the validator reports no problems for every file it is given.
  # That is a pass produced by absence, which is the exact failure class this
  # register exists inside, so the vocabularies are passed by name instead.
  jq -r \
    --arg version "$FM_QUALIFICATION_SCHEMA_VERSION" \
    --arg base "$(basename "${file%.json}")" \
    --argjson names "$names_json" \
    --arg axes_raw "$FM_QUALIFICATION_AXES" \
    --arg refused_raw "$FM_QUALIFICATION_REFUSED_CONTRACT_KEYS" \
    --arg depkinds_raw "$FM_QUALIFICATION_PROBED_KINDS
$FM_QUALIFICATION_UNCOVERED_KINDS" \
    '
    def lines($s): [$s | split("\n")[] | select(length > 0)];
    . as $c
    | (lines($axes_raw)) as $axes
    | (lines($refused_raw)) as $refused
    | (lines($depkinds_raw)) as $depkinds
    | [
        (select(($c.qualification_schema_version | tostring) != $version)
         | "qualification_schema_version must be \($version)"),
        (select($c.id != $base) | "id \"\($c.id // "absent")\" does not match its filename \"\($base)\""),
        (["role","risk_class","contract_version","axis","purpose","grants"][]
         | select((($c[.] // "") | type) != "string" or (($c[.] // "") | length) == 0)
         | "missing or empty required field: \(.)"),
        (select(($c.does_not_grant | type) != "array" or ($c.does_not_grant | length) == 0
                or (any($c.does_not_grant[]?; (type != "string") or (length == 0))))
         | "does_not_grant must be a non-empty array of non-empty strings"),
        (select(($axes | index($c.axis)) == null)
         | "axis \"\($c.axis // "absent")\" is not one of the nine declared axes"),
        ($refused[] as $k | select($c | has($k)) | "refused vendor-bearing key: \($k)"),
        (select(($c.executable_predicate | type) != "object")
         | "executable_predicate must be an object naming a predicate this repository can run"),
        (select(($c.executable_predicate.kind? // "") | IN("fixture_oracle","declared_deterministic") | not)
         | "executable_predicate.kind \"\($c.executable_predicate.kind? // "absent")\" is not a declared predicate kind"),
        # `// ""` alone would make an ABSENT field a string of length zero and
        # pass the type test, so the length is checked too. A required field that
        # is missing and a required field that is empty are the same defect here
        # and both must be named.
        (select(($c.executable_predicate.kind? // "") == "fixture_oracle")
         | (["fixture","fixture_version","manifest_digest","root","integrity","setup","verify","controls"][] as $k
            | select((($c.executable_predicate[$k] // "") | type) != "string"
                     or (($c.executable_predicate[$k] // "") | length) == 0)
            | "fixture_oracle predicate is missing executable_predicate.\($k)")),
        (select(($c.executable_predicate.kind? // "") == "declared_deterministic")
         | (["check","expect"][] as $k
            | select((($c.executable_predicate[$k] // "") | type) != "string"
                     or (($c.executable_predicate[$k] // "") | length) == 0)
            | "declared_deterministic predicate is missing executable_predicate.\($k)")),
        (select(($c.adjudication? | type) == "object" and ($c.adjudication.required? == true))
         | (select((($c.adjudication.adjudicator_contract? // "") | length) == 0)
            | "adjudication.required is true but no adjudicator_contract is named, so nothing says who may grade"),
           (select(($c.adjudication.independence_dimensions? | type) != "array"
                   or (($c.adjudication.independence_dimensions | index("binding")) == null))
            | "adjudication.independence_dimensions must be an array containing \"binding\"; that dimension IS the self-review refusal")),
        (select(($c.required_freshness_dependencies? | type) == "array")
         | ($c.required_freshness_dependencies[] as $k | select(($depkinds | index($k)) == null)
            | "required_freshness_dependencies names unknown kind \"\($k)\"")),
        # SUBSTRING, not equality. A vendor reaches a contract inside a purpose
        # sentence or a predicate argument far more easily than as a whole field
        # value, and equality would miss every one of those. The over-match is
        # deliberate and in the safe direction: it refuses rather than admits, and
        # the message names the exact string so the fix is one edit.
        ( [ $c | .. | strings ] as $all
          | $names[] as $n
          | select(any($all[]; contains($n)))
          | "contract names the configured binding or provider \"\($n)\"; a capability contract names a job, never who does it" )
      ] | .[]
    ' "$file" 2>/dev/null || return 2
}

fm_qualification_record_problems() {  # <record-file>
  local file=$1 contract_id contract='{}' rc
  command -v jq >/dev/null 2>&1 || return 2
  jq -e . "$file" >/dev/null 2>&1 || { printf 'not readable JSON\n'; return 0; }
  contract_id=$(jq -r '.contract // ""' "$file" 2>/dev/null)
  if [ -n "$contract_id" ]; then
    contract=$(fm_qualification_contract "$contract_id") || rc=$?
    case "${rc:-0}" in
      1) printf 'contract "%s" is not in the register, so nothing says what this record observed\n' "$contract_id" ;;
      2) printf 'contract "%s" exists and could not be read, so this record cannot be validated against it\n' "$contract_id" ;;
    esac
    [ "${rc:-0}" -eq 0 ] || contract='{}'
  fi
  # Named args and the file as input, for the reason spelled out on the contract
  # validator above: --args would switch the input to stdin and make this report
  # a clean bill of health for every record it never read.
  jq -r \
    --arg version "$FM_QUALIFICATION_SCHEMA_VERSION" \
    --arg base "$(basename "${file%.json}")" \
    --argjson contract "$contract" \
    --arg results_raw "$FM_QUALIFICATION_RESULTS" \
    --arg refused_raw "$FM_QUALIFICATION_REFUSED_RECORD_KEYS" \
    --arg probed_raw "$FM_QUALIFICATION_PROBED_KINDS" \
    --arg uncovered_raw "$FM_QUALIFICATION_UNCOVERED_KINDS" \
    --arg declared_dispositions_raw "$FM_QUALIFICATION_DECLARED_DISPOSITIONS" \
    '
    def lines($s): [$s | split("\n")[] | select(length > 0)];
    . as $r
    | (lines($results_raw)) as $results
    | (lines($refused_raw)) as $refused
    | (lines($probed_raw)) as $probed
    | (lines($uncovered_raw)) as $uncovered
    | (lines($declared_dispositions_raw)) as $dispositions
    | ($probed + $uncovered) as $kinds
    | [ ($r.freshness_dependencies? // []) | .[]? | .kind ] as $declared
    | [
        (select(($r.qualification_schema_version | tostring) != $version)
         | "qualification_schema_version must be \($version)"),
        (select($r.id != $base) | "id \"\($r.id // "absent")\" does not match its filename \"\($base)\""),
        (["contract","contract_version","role","risk_class","result","result_evidence","observed_at"][]
         | select((($r[.] // "") | type) != "string" or (($r[.] // "") | length) == 0)
         | "missing or empty required field: \(.)"),
        (select(($results | index($r.result)) == null)
         | "result \"\($r.result // "absent")\" is not one of the five declared values; a synonym is refused rather than normalized"),
        ($refused[] as $k | select($r | has($k))
         | "refused key: \($k). The state a reader acts on is COMPUTED on every read and never stored"),
        (select(($r.binding | type) != "object") | "binding must be an object; it is the key of this record"),
        (select(($r.binding | type) == "object")
         | (["provider","model","harness","harness_version","native_effort"][]
            | select((($r.binding[.] // "") | type) != "string" or (($r.binding[.] // "") | length) == 0)
            | "missing or empty binding.\(.)")),
        (select(($r.binding.model? // "") | test("/") | not)
         | "binding.model must be fully qualified as provider/model-id, got \"\($r.binding.model? // "absent")\""),
        (select((($r.measured_context | type) != "number")
                and ($r.measured_context != "COULD_NOT_OBSERVE"))
         | "measured_context must be a token count or exactly COULD_NOT_OBSERVE; an estimate is never substituted for a measurement"),
        (select(($r.observed_at // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)
         | "observed_at must be an ISO date (YYYY-MM-DD)"),
        (select(($r.known_limitations | type) != "array" or ($r.known_limitations | length) == 0
                or (any($r.known_limitations[]?; (type != "string") or (length == 0))))
         | "known_limitations must be a non-empty array of non-empty strings; every real qualification run has a boundary"),
        (select(($r.freshness_dependencies | type) != "array" or ($r.freshness_dependencies | length) == 0)
         | "freshness_dependencies must be a non-empty array; a record with no declared dependency could never be judged stale"),
        ($r.freshness_dependencies[]? as $d | select(($kinds | index($d.kind)) == null)
         | "freshness dependency kind \"\($d.kind // "absent")\" is not declared"),
        ($r.freshness_dependencies[]? | select(.kind == "file_digest")
         | (select((.path // "") | length == 0) | "file_digest dependency names no path"),
           (select((.digest // "") | test("^[0-9a-f]{64}$") | not)
            | "file_digest dependency carries no sha256 digest")),
        ($r.freshness_dependencies[]? | select(.kind == "time_bound")
         | (select((.until // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)
            | "time_bound dependency needs an ISO until date"),
           (select((.justification // "") | length == 0)
            | "time_bound dependency needs a justification; a round number nobody derived is not a bound")),
        ( ([ $uncovered[] as $k | select(($declared | index($k)) != null) | $k ]) as $u
          | select(($u | length) > 0 and (($declared | index("time_bound")) == null))
          | "declares the uncovered dependency \($u | join(", ")) without a time_bound; what cannot be probed is bounded in time instead" ),
        (select(($r.adjudication? | type) == "object"
                and (($r.adjudication.adjudicator_binding? // null) != null)
                and ($r.adjudication.adjudicator_binding == ($r.binding.model? // null)))
         | "adjudicator_binding equals binding.model: no binding independently reviews its own mutation merely because it qualified as maker"),
        (select(($r.adjudication? | type) == "object"
                and (($r.adjudication.adjudicator_result? // "") | length) > 0
                and (($results | index($r.adjudication.adjudicator_result)) == null))
         | "adjudication.adjudicator_result \"\($r.adjudication.adjudicator_result)\" is not one of the five declared values"),
        (select(($contract | has("role")) and $r.role != $contract.role)
         | "role \"\($r.role)\" does not match contract role \"\($contract.role)\""),
        (select(($contract | has("risk_class")) and $r.risk_class != $contract.risk_class)
         | "risk_class \"\($r.risk_class)\" does not match contract risk_class \"\($contract.risk_class)\""),
        (select(($contract.executable_predicate.kind? // "") == "fixture_oracle"
                and ($r.fixture | type) != "object")
         | "the contract predicate is a fixture oracle, so this record must carry a fixture object identifying the package it was graded by"),
        (select(($contract.required_freshness_dependencies? | type) == "array")
         | ($contract.required_freshness_dependencies[] as $k
            | select(($declared | index($k)) == null)
            | "contract requires freshness dependency \"\($k)\" and this record declares none")),
        (select($r | has("predicate_generation"))
         | select(if ($r.predicate_generation | type) == "string"
                  then ($r.predicate_generation | test("^[0-9a-f]{64}$") | not) else true end)
         | "predicate_generation must be the sha256 digest of the material predicate this record was graded by; a version label names a generation without identifying it"),
        (select($r | has("failed_predicates"))
         | select(if ($r.failed_predicates | type) == "array"
                  then (($r.failed_predicates | length) == 0
                        or any($r.failed_predicates[]; (type != "string") or (length == 0)))
                  else true end)
         | "failed_predicates must be a non-empty array of non-empty claim ids naming what the predicate rejected; a later generation can only carry an adverse observation forward for claims it can name"),
        (select($r | has("disposition"))
         | select(($r.disposition | type) != "object")
         | "disposition must be an object carrying retry, reason and authority"),
        (select(($r.disposition? | type) == "object")
         | (select(($dispositions | index($r.disposition.retry // "")) == null)
            | "disposition.retry \"\($r.disposition.retry // "absent")\" is not one of the two declared values; a synonym is refused rather than normalized"),
           (["reason","authority"][]
            | select((($r.disposition[.] // "") | type) != "string" or (($r.disposition[.] // "") | length) == 0)
            | "disposition needs a \(.); a do-not-retry nobody attributed is a preference rather than a durable decision"))
      ] | .[]
    ' "$file" 2>/dev/null || return 2
}

# ---------------------------------------------------------------------------
# Freshness
# ---------------------------------------------------------------------------

# fm_qualification_dependency_observations <record-json> <contract-json>
# One JSON array of dependency observations. Each row carries the kind, one of
# unchanged / changed / could-not-observe / declared-uncovered, and the detail a
# reader needs to act on it.
#
# NOTHING outside the declared dependencies is consulted. Not the repository
# head, not an unrelated tracked file, not a vendor label. A register that went
# stale on every commit would be one nobody could rely on, and the reflex repair
# is to stop checking it.
fm_qualification_dependency_observations() {
  local record=$1 contract=${2:-'{}'} rows='[]' kind path digest abs cur until_date today err
  today=$(fm_qualification_today)
  # U+001F, not a tab. Tab is IFS WHITESPACE, and bash `read` collapses runs of
  # IFS whitespace into one delimiter and strips it at the ends - so a row whose
  # middle field is legitimately empty silently shifts every later field left.
  # That is not a style choice: it read a time bound as absent while the record
  # carried one, which would have made a bounded record look unbounded.
  while IFS=$'\x1f' read -r kind path digest until_date; do
    [ -n "$kind" ] || continue
    local obs detail
    case "$kind" in
      file_digest)
        if ! abs=$(fm_qualification_resolve_target "$path"); then
          obs=could-not-observe
          detail="declared target could not be resolved: $abs"
        elif [ ! -f "$abs" ]; then
          obs=could-not-observe
          detail="$path is absent from this checkout, so whether its bytes changed could not be observed; an absent file is not an unchanged one"
        elif ! cur=$(fm_qualification_sha256 "$abs"); then
          obs=could-not-observe
          detail="no sha256 tool is available, so $path could not be digested"
        elif [ "$cur" = "$digest" ]; then
          obs=unchanged
          detail="$path still digests to the recorded ${digest:0:16}"
        else
          obs=changed
          detail="$path now digests to ${cur:0:16}, recorded ${digest:0:16}"
        fi
        ;;
      contract_version)
        cur=$(printf '%s' "$contract" | jq -r '.contract_version // ""' 2>/dev/null) || cur=
        if [ -z "$cur" ]; then
          obs=could-not-observe
          detail="the contract's own version could not be read"
        elif [ "$cur" = "$digest" ]; then
          obs=unchanged
          detail="contract still at version $cur"
        else
          obs=changed
          detail="contract is now version $cur, observed against $digest"
        fi
        ;;
      time_bound)
        if [ -z "$until_date" ]; then
          obs=could-not-observe
          detail="the declared time bound carries no date"
        elif [ "$today" \> "$until_date" ]; then
          obs=changed
          detail="the declared bound expired on $until_date (today is $today)"
        else
          obs=unchanged
          detail="within the declared bound, which runs to $until_date"
        fi
        ;;
      harness_semantics|binding_semantics|native_effort_mapping)
        obs=declared-uncovered
        detail="$kind is declared and deliberately not probed; the record's time bound is what limits it"
        ;;
      *)
        obs=could-not-observe
        detail="unknown dependency kind"
        ;;
    esac
    rows=$(printf '%s' "$rows" | jq -c --arg k "$kind" --arg o "$obs" --arg d "$detail" \
      '. + [{kind:$k, observation:$o, detail:$d}]' 2>/dev/null) || { err=1; break; }
  done <<EOF
$(printf '%s' "$record" | jq -r '
  (.freshness_dependencies // [])[]
  | [ (.kind // ""),
      (.path // ""),
      ((.digest // .version // "")),
      (.until // "") ] | join("\u001f")' 2>/dev/null)
EOF
  [ -z "${err:-}" ] || return 1
  printf '%s\n' "$rows"
}

# The one fold, so no caller invents a second. changed beats could-not-observe
# beats unchanged, and declared-uncovered never drives the verdict on its own -
# it is surfaced, and the time bound is what bounds it. Inverting that order
# would let a gap launder a known change into an unknown one, which reads as the
# milder of the two while being strictly worse.
fm_qualification_freshness_verdict() {  # <observations-json>
  local obs=$1
  printf '%s' "$obs" | jq -r '
    if any(.[]?; .observation == "changed") then "changed"
    elif any(.[]?; .observation == "could-not-observe") then "could-not-observe"
    else "unchanged" end' 2>/dev/null
}

# APPLICABILITY is the freshness verdict said in the reader's terms, and nothing
# more. It is separated from the state so a generation bump can move whether an
# observation still applies WITHOUT moving what was observed. Three values rather
# than two, for this fleet's standing reason: a dependency nobody could read
# leaves applicability unobserved, and narrowing that into either CURRENT or
# STALE would report a gap as one of the two answers it is not.
fm_qualification_applicability() {  # <freshness-verdict>
  case "$1" in
    changed) printf 'STALE\n' ;;
    could-not-observe) printf 'COULD_NOT_OBSERVE\n' ;;
    *) printf 'CURRENT\n' ;;
  esac
}

# fm_qualification_retry_disposition <record-json> <contract-json>
# "<disposition>\x1f<reason>" for a record whose result is FAILED. No other
# result reaches here: only an ADVERSE observation can withhold another
# invocation, and a stale or missing one never does.
#
# THE LADDER, and why each rung answers the way it does:
#
#   record names no predicate generation   -> unknown. Which material predicate
#       this binding failed was never recorded, so whether it has since changed
#       cannot be observed. This is every record written before the field
#       existed, and it is deliberately not `permitted`: the captain's law allows
#       a retry only through an EXPLICIT material-change predicate, and silence
#       is not one.
#   contract declares none                 -> unknown, from the other side.
#   generations equal                      -> not-permitted. The predicate this
#       binding was graded by is the one still in force, whatever the contract
#       VERSION now says. This is the rung that closes the laundering.
#   generations differ, no carry-forward
#       declaration for the record's base  -> permitted. THE ABSENCE OF THE
#       DECLARATION IS THE MATERIAL-CHANGE PREDICATE: a new generation that says
#       nothing about a base generation's claims has replaced them.
#   generations differ, and every predicate
#       this binding failed is declared
#       unchanged from its base            -> not-permitted, carried over.
#   generations differ and at least one
#       failed predicate is not declared   -> permitted. One changed claim it
#       failed is enough; the binding may now pass.
#
# A record may also DECLARE a disposition, which is the durable do-not-retry the
# deployment ruling asked for so refusing a known failed binding stops depending
# on firstmate remembering to. It may only ever make the answer STRICTER. A
# hand-written `permitted` never overrides a computed refusal, for exactly the
# reason a hand-written state may not answer the question the interpreter
# computes: a claim anyone can write is one that will eventually be written
# wrongly, and this is the claim that spends a model call on a binding already
# known to fail.
fm_qualification_retry_disposition() {
  local record=$1 contract=${2:-'{}'}
  local rec_gen con_gen declared_retry kind base root abs decl failed named
  local computed reason declared_d declared_reason='' final final_reason

  rec_gen=$(printf '%s' "$record" | jq -r '.predicate_generation // ""' 2>/dev/null) || rec_gen=
  con_gen=$(printf '%s' "$contract" | jq -r '.executable_predicate.predicate_generation // ""' 2>/dev/null) || con_gen=

  if [ -z "$rec_gen" ]; then
    computed=unknown
    reason="the adverse record names no predicate generation, so whether the material predicate it failed has since changed could not be observed; an unobserved change is never a permission to spend another invocation"
  elif [ -z "$con_gen" ]; then
    computed=unknown
    reason="the contract declares no predicate generation in force, so the generation the adverse record was graded by (${rec_gen:0:16}) could not be compared against it"
  elif [ "$rec_gen" = "$con_gen" ]; then
    computed=not-permitted
    reason="the material predicate this binding was graded by is the one still in force (${rec_gen:0:16}), so the adverse observation stands whatever the contract version now reads"
  else
    kind=$(printf '%s' "$contract" | jq -r '.executable_predicate.kind // ""' 2>/dev/null) || kind=
    base=$(printf '%s' "$record" | jq -r '.fixture.manifest_digest // ""' 2>/dev/null) || base=
    root=$(printf '%s' "$contract" | jq -r '.executable_predicate.root // ""' 2>/dev/null) || root=
    if [ "$kind" != fixture_oracle ]; then
      computed=permitted
      reason="the material predicate moved from ${rec_gen:0:16} to ${con_gen:0:16}, and this predicate kind carries no generation manifest that could declare it unchanged, so re-qualification is lawful"
    elif [ -z "$base" ]; then
      computed=unknown
      reason="the material predicate moved from ${rec_gen:0:16} to ${con_gen:0:16}, and the adverse record names no base manifest, so whether the new generation carried its failed predicates forward could not be observed"
    elif ! abs=$(fm_qualification_resolve_target "$root"); then
      computed=unknown
      reason="the material predicate moved and the package root could not be resolved ($abs), so whether the new generation carried this binding's failed predicates forward could not be observed"
    elif [ ! -f "$abs/MANIFEST.json" ] || ! decl=$(jq -c --arg b "$base" \
           '.predicates_unchanged_from[$b] // null' "$abs/MANIFEST.json" 2>/dev/null); then
      computed=unknown
      reason="the material predicate moved from ${rec_gen:0:16} to ${con_gen:0:16}, and the generation manifest now in force could not be read, so whether it carried this binding's failed predicates forward could not be observed"
    elif [ "$decl" = null ]; then
      computed=permitted
      reason="the material predicate moved from ${rec_gen:0:16} to ${con_gen:0:16} and the generation now in force declares nothing carried forward unchanged from ${base:0:16}, so the predicate this binding failed materially changed and re-qualification is lawful"
    elif [ "$(printf '%s' "$decl" | jq -r 'type' 2>/dev/null)" != array ]; then
      computed=unknown
      reason="the generation now in force declares a carry-forward from ${base:0:16} that is not a list of claim ids, so whether this binding's failed predicates are among them could not be observed"
    else
      failed=$(printf '%s' "$record" | jq -c '.failed_predicates // null' 2>/dev/null) || failed=null
      named=$(printf '%s' "$failed" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null) || named=0
      if [ "${named:-0}" -eq 0 ]; then
        computed=unknown
        reason="the generation now in force declares predicates carried forward unchanged from ${base:0:16}, and the adverse record names no failed predicate, so whether the claims this binding failed are among them could not be observed"
      elif [ "$(jq -n --argjson f "$failed" --argjson d "$decl" \
                 'all($f[]; . as $c | ($d | index($c)) != null)' 2>/dev/null)" = true ]; then
        computed=not-permitted
        reason="every predicate this binding failed ($(printf '%s' "$failed" | jq -r 'join(", ")')) is declared unchanged from ${base:0:16} by the generation now in force, so the adverse observation carries over to it"
      else
        computed=permitted
        reason="at least one predicate this binding failed ($(printf '%s' "$failed" | jq -r 'join(", ")')) is not declared unchanged by the generation now in force, so it materially changed and re-qualification is lawful"
      fi
    fi
  fi

  declared_retry=$(printf '%s' "$record" | jq -r '.disposition.retry // ""' 2>/dev/null) || declared_retry=
  case "$declared_retry" in
    ''|permitted) declared_d=permitted ;;
    not-permitted-unchanged-predicate)
      declared_d=not-permitted
      declared_reason="the record carries a durable do-not-retry disposition: $(printf '%s' "$record" | jq -r '.disposition.reason // "no reason recorded"' 2>/dev/null) (authority: $(printf '%s' "$record" | jq -r '.disposition.authority // "none recorded"' 2>/dev/null))" ;;
    *)
      declared_d=unknown
      declared_reason="the record's declared retry disposition \"$declared_retry\" is not one of the two registered values, so what it meant could not be read" ;;
  esac

  # Strictest wins, and only ever in that direction.
  final=$computed
  final_reason=$reason
  if [ "$declared_d" = not-permitted ] && [ "$final" != not-permitted ]; then
    final=not-permitted
    final_reason=$declared_reason
  elif [ "$declared_d" = unknown ] && [ "$final" = permitted ]; then
    final=unknown
    final_reason=$declared_reason
  fi
  printf '%s\x1f%s\n' "$final" "$final_reason"
}

# ---------------------------------------------------------------------------
# The state decision
# ---------------------------------------------------------------------------

# fm_qualification_state <contract-id> <model> [<harness>] [<native-effort>]
# Print one fm-qualification-state.v1 record. Always exits 0 with a record: the
# ANSWER is the state field, and there is no failure mode that prints nothing,
# because a caller reading an empty result would have to invent a value.
fm_qualification_state() {
  local contract_id=$1 model=$2 harness=${3:-} effort=${4:-}
  local contract rc=0 files record='' record_id='' near='[]' problems
  local state reason obs='[]' verdict recorded='' excluded=null

  if ! command -v jq >/dev/null 2>&1; then
    fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
      COULD_NOT_OBSERVE "jq is required to read the qualification register" '' '' '[]' '[]'
    return 0
  fi

  contract=$(fm_qualification_contract "$contract_id") || rc=$?
  case "$rc" in
    1)
      fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
        COULD_NOT_OBSERVE "$FM_QUAL_TOKEN_CONTRACT_UNKNOWN: no contract $contract_id in $(fm_qualification_contract_dir), so what this route requires could not be read; a declared requirement whose contract is missing has not been met" \
        '' '' '[]' '[]'
      return 0 ;;
    2)
      fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
        COULD_NOT_OBSERVE "$FM_QUAL_TOKEN_UNREADABLE: contract $contract_id exists and could not be read" \
        '' '' '[]' '[]'
      return 0 ;;
  esac

  rc=0
  files=$(fm_qualification_record_files) || rc=$?
  if [ "$rc" -eq 2 ]; then
    fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
      COULD_NOT_OBSERVE "$FM_QUAL_TOKEN_UNREADABLE: a qualification record directory exists and could not be listed, so whether a record exists could not be observed" \
      '' '' '[]' '[]'
    return 0
  fi

  local chain chain_status chain_tip
  # shellcheck disable=SC2016 # The dollar-prefixed names belong to jq and must reach it unexpanded.
  chain=$(printf '%s\n' "$files" | xargs -r jq -s -r \
    --arg contract "$contract_id" --arg model "$model" --arg harness "$harness" --arg effort "$effort" '
      [ .[] | select(.contract == $contract and .binding.model == $model)
        | select(($harness == "") or (.binding.harness == $harness))
        | select(($effort == "") or (.binding.native_effort == $effort)) ] as $records
      | ($records | map(.id)) as $ids
      | ($records | map(select((.supersedes? // "") != ""))) as $edges
      | ($ids - ($edges | map(.supersedes))) as $tips
      | if ($records | length) <= 1 then "ok\u001f" + ($records[0].id // "")
        elif (all($edges[]; .supersedes as $superseded | ($ids | index($superseded)) != null) | not) then "invalid\u001fsupersedes names a record outside the same tuple"
        elif (($edges | map(.supersedes) | unique | length) != ($edges | length)) then "invalid\u001fmore than one record supersedes the same predecessor"
        elif ($edges | length) != (($records | length) - 1) or ($tips | length) != 1 then "invalid\u001fthe supersession graph is not one complete acyclic chain"
        else "ok\u001f" + $tips[0] end' 2>/dev/null) || chain='invalidthe supersession chain could not be read'
  IFS=$'\x1f' read -r chain_status chain_tip <<EOF
$chain
EOF
  if [ "$chain_status" = invalid ]; then
    fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
      COULD_NOT_OBSERVE "$FM_QUAL_TOKEN_INADMISSIBLE: $chain_status: $chain_tip" '' '' '[]' '[]'
    return 0
  fi

  # The applicable record and the near misses, in one pass. A record for the same
  # contract and model under a DIFFERENT harness or native effort is a near miss
  # and never a match: it observed a different thing. Reporting it is what stops
  # "there is no record" from being indistinguishable from "there is a record for
  # a tuple you did not ask about".
  local f rid rmodel rharness rharness_version reffort rcontract rresult rsupersedes
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # U+001F for the same reason the dependency reader uses it: an empty middle
    # field under a tab IFS shifts every later field left, and here that would
    # silently compare a record's result against its native effort.
    IFS=$'\x1f' read -r rid rcontract rmodel rharness rharness_version reffort rresult rsupersedes <<EOF2
$(jq -r '[ (.id // ""), (.contract // ""), (.binding.model // ""), (.binding.harness // ""),
           (.binding.harness_version // ""), (.binding.native_effort // ""), (.result // ""),
           (.supersedes // "") ] | join("\u001f")' "$f" 2>/dev/null)
EOF2
    [ "$rcontract" = "$contract_id" ] || continue
    [ "$rmodel" = "$model" ] || continue
    if { [ -z "$harness" ] || [ "$rharness" = "$harness" ]; } &&
       { [ -z "$effort" ] || [ "$reffort" = "$effort" ]; }; then
      [ "$rid" = "$chain_tip" ] || continue
      # A later record for the same tuple wins only when it declares that it
      # supersedes the earlier one; otherwise two records for one tuple is a
      # register defect, reported rather than resolved by filename order.
      if [ -n "$record" ] && [ "$rsupersedes" = "$record_id" ]; then
        :
      elif [ -n "$record" ] && [ "$(printf '%s' "$record" | jq -r '.supersedes // ""')" = "$rid" ]; then
        continue
      elif [ -n "$record" ]; then
        fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
          COULD_NOT_OBSERVE "$FM_QUAL_TOKEN_INADMISSIBLE: more than one record claims contract $contract_id on $model for this tuple ($record_id and $rid); which observation applies could not be determined" \
          '' '' '[]' '[]'
        return 0
      fi
      record=$(jq -c . "$f" 2>/dev/null)
      record_id=$rid
      recorded=$rresult
    else
      near=$(printf '%s' "$near" | jq -c --arg id "$rid" --arg h "$rharness" --arg hv "$rharness_version" --arg e "$reffort" --arg r "$rresult" \
        '. + [{record:$id, harness:$h, harness_version:$hv, native_effort:$e, result:$r}]' 2>/dev/null)
    fi
  done <<EOF
$files
EOF

  if [ -z "$record" ]; then
    reason="no record in the qualification register observes $model against contract $contract_id"
    if [ "$(printf '%s' "$near" | jq -r 'length')" != 0 ]; then
      reason="$reason for harness ${harness:-any} at native effort ${effort:-any}; $(printf '%s' "$near" | jq -r '[.[] | .record + " (harness " + .harness + ", effort " + .native_effort + ", " + .result + ")"] | join("; ")') observes a different tuple, which is a different thing and not a stale version of this one"
    fi
    # No record at all means nothing adverse was ever observed against this
    # tuple, so nothing withholds a first qualification of it. Applicability is
    # null rather than CURRENT: there is no observation whose currency to report.
    fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
      QUALIFICATION_REQUIRED "$reason" '' "$recorded" '[]' "$near" null \
      "$(fm_qualification_separated '' permitted \
         "no adverse observation stands against this tuple, so nothing withholds a bounded qualification of it")"
    return 0
  fi

  # An inadmissible record is never used. A safety record that cannot be
  # validated must not read as one that passed, and the state is could-not-observe
  # rather than a refusal, because nothing about the BINDING was established.
  problems=$(fm_qualification_record_problems "$(printf '%s\n' "$files" | grep -F "/$record_id.json" | head -1)") || problems='could not be validated'
  if [ -n "$problems" ]; then
    fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
      COULD_NOT_OBSERVE "$FM_QUAL_TOKEN_INADMISSIBLE: record $record_id is inadmissible ($(printf '%s' "$problems" | tr '\n' ';' | sed 's/;$//')), so what it observed could not be read" \
      "$record_id" "$recorded" '[]' "$near"
    return 0
  fi

  obs=$(fm_qualification_dependency_observations "$record" "$contract") || obs='[]'
  verdict=$(fm_qualification_freshness_verdict "$obs")

  # The two separated facts, computed from the same record and never from the
  # state below. Applicability moves with the declared dependencies; the retry
  # disposition moves only with the material predicate, and only an ADVERSE
  # observation can withhold one - a stale pass stays retryable or it would be
  # frozen forever.
  local applicability retry_disposition='' retry_reason='' separated
  applicability=$(fm_qualification_applicability "$verdict")
  if [ "$recorded" = FAILED ]; then
    IFS=$'\x1f' read -r retry_disposition retry_reason <<EOF3
$(fm_qualification_retry_disposition "$record" "$contract")
EOF3
    # The adverse record is named HERE rather than inside the ladder, so every
    # branch of it - and every reader downstream, including the route merge that
    # carries only this sentence - is told which observation is doing the
    # withholding.
    retry_reason="record $record_id observed this binding FAILED, and $retry_reason"
  else
    retry_disposition=permitted
    retry_reason="record $record_id records $recorded, which is not an adverse observation, so nothing withholds another qualification of this tuple"
  fi
  separated=$(fm_qualification_separated "$applicability" "${retry_disposition:-unknown}" "$retry_reason")

  # A contract that requires adjudication is not satisfied by a predicate result
  # alone, however good it was. This is the one place where a self-declared pass
  # is turned back into missing evidence, and it is deliberately not a failure:
  # nothing adverse was observed about the binding.
  local adj_required adj_result adj_binding adj_contract adj_dimensions adj_refusal
  adj_required=$(printf '%s' "$contract" | jq -r '.adjudication.required // false' 2>/dev/null)
  adj_result=$(printf '%s' "$record" | jq -r '.adjudication.adjudicator_result // ""' 2>/dev/null)
  adj_binding=$(printf '%s' "$record" | jq -r '.adjudication.adjudicator_binding // ""' 2>/dev/null)
  adj_contract=$(printf '%s' "$contract" | jq -r '.adjudication.adjudicator_contract // ""' 2>/dev/null)
  adj_dimensions=$(printf '%s' "$contract" | jq -r '(.adjudication.independence_dimensions // []) | join(",")' 2>/dev/null)

  case "$recorded" in
    COULD_NOT_OBSERVE)
      state=COULD_NOT_OBSERVE
      reason="record $record_id observed could-not-observe: $(printf '%s' "$record" | jq -r '.result_evidence')" ;;
    QUALIFICATION_REQUIRED|QUALIFICATION_STALE)
      state=$recorded
      reason="record $record_id records $recorded: $(printf '%s' "$record" | jq -r '.result_evidence')" ;;
    FAILED)
      if [ "$verdict" = changed ]; then
        # The state reopens because the observation no longer applies. Whether
        # another invocation is PERMITTED is the separate axis above, and it is
        # what governs activation - so a contract version bump alone moves this
        # line without ever making the binding activatable again.
        state=QUALIFICATION_REQUIRED
        excluded='"prior-failed-superseded-by-material-change"'
        reason="record $record_id excluded this binding, and a declared material dependency has since changed ($(printf '%s' "$obs" | jq -r '[.[] | select(.observation == "changed") | .detail] | join("; ")')), so the exclusion no longer applies; the FAILED record is retained rather than removed, and whether re-qualification may be spent is the retry disposition (${retry_disposition:-unknown}): $retry_reason"
      else
        state=FAILED
        excluded='"failed"'
        reason="record $record_id excluded this binding and no declared dependency has changed: $(printf '%s' "$record" | jq -r '.result_evidence')"
      fi ;;
    QUALIFIED)
      if [ "$adj_required" = true ] && [ "$adj_result" != QUALIFIED ]; then
        state=QUALIFICATION_REQUIRED
        reason="record $record_id records a predicate pass, and contract $contract_id requires assignment-distinct adjudication which returned ${adj_result:-nothing}; a maker run never certifies itself"
      elif [ "$adj_required" = true ] &&
           ! adj_refusal=$(fm_qualification_adjudicator_refusal "$model" "$adj_binding" "$adj_contract" "$adj_dimensions"); then
        state=QUALIFICATION_REQUIRED
        reason="record $record_id carries an adjudicator pass that did not pass the reviewer qualification and independence guard: $adj_refusal"
      elif [ "$verdict" = changed ]; then
        state=QUALIFICATION_STALE
        reason="record $record_id qualified this binding, and a declared material dependency has since changed: $(printf '%s' "$obs" | jq -r '[.[] | select(.observation == "changed") | .detail] | join("; ")')"
      elif [ "$verdict" = could-not-observe ]; then
        state=COULD_NOT_OBSERVE
        reason="record $record_id qualified this binding, and a declared dependency could not be observed: $(printf '%s' "$obs" | jq -r '[.[] | select(.observation == "could-not-observe") | .detail] | join("; ")')"
      else
        state=QUALIFIED
        reason="record $record_id qualified this binding and every declared dependency is unchanged"
      fi ;;
    *)
      state=COULD_NOT_OBSERVE
      reason="record $record_id carries the unregistered result \"$recorded\"" ;;
  esac

  fm_qualification_state_record "$contract_id" "$model" "$harness" "$effort" \
    "$state" "$reason" "$record_id" "$recorded" "$obs" "$near" "$excluded" "$separated"
}

# fm_qualification_separated <applicability|""> <retry-disposition> <retry-reason>
# The two facts the five-value state deliberately does not carry, in the one
# shape the renderer takes. Built here rather than inline at each call site so a
# caller cannot emit half of a separated fact.
fm_qualification_separated() {
  command -v jq >/dev/null 2>&1 || { printf 'null\n'; return 0; }
  jq -n -c --arg a "${1:-}" --arg d "${2:-unknown}" --arg r "${3:-}" \
    '{applicability:(if $a == "" then null else $a end),
      retry_disposition:$d, retry_reason:$r}'
}

# The one renderer, so every caller reads the same shape.
#
# The separated default is deliberately the SAFE one: an early return that could
# not read the register reports `unknown`, never `permitted`. Every such return
# is a path on which whether an adverse observation stands could not be
# established, and defaulting the other way would let an unreadable register
# authorize the invocation a readable one refuses.
fm_qualification_state_record() {
  # <contract> <model> <harness> <effort> <state> <reason> <record-id>
  # <recorded-result> <observations-json> <near-json> [<excluded-json>]
  # [<separated-json>]
  local contract=$1 model=$2 harness=$3 effort=$4 state=$5 reason=$6
  local record=$7 recorded=$8 obs=${9:-'[]'} near=${10:-'[]'} excluded=${11:-null}
  local separated=${12:-}
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"schema":"%s","state":"COULD_NOT_OBSERVE"}\n' "$FM_QUALIFICATION_STATE_SCHEMA"
    return 0
  fi
  [ -n "$separated" ] || separated=$(fm_qualification_separated '' unknown \
    "the register could not be read for this tuple, so whether an adverse observation withholds another invocation could not be observed")
  jq -n -c \
    --arg schema "$FM_QUALIFICATION_STATE_SCHEMA" \
    --arg contract "$contract" --arg model "$model" \
    --arg harness "$harness" --arg effort "$effort" \
    --arg state "$state" --arg reason "$reason" \
    --arg record "$record" --arg recorded "$recorded" \
    --argjson obs "${obs:-[]}" --argjson near "${near:-[]}" \
    --argjson excluded "${excluded:-null}" \
    --argjson separated "$separated" \
    '{schema:$schema, contract:$contract, model:$model,
      harness:(if $harness == "" then null else $harness end),
      native_effort:(if $effort == "" then null else $effort end),
      state:$state, reason:$reason,
      record:(if $record == "" then null else $record end),
      recorded_result:(if $recorded == "" then null else $recorded end),
      applicability:($separated.applicability // null),
      retry_disposition:($separated.retry_disposition // "unknown"),
      retry_reason:($separated.retry_reason // ""),
      dependencies:$obs, near_miss:$near, excluded_by:$excluded}'
}

# ---------------------------------------------------------------------------
# Assignment independence
# ---------------------------------------------------------------------------

# fm_qualification_independence <maker-model> <reviewer-model> [<config-dir>]
# The DERIVED per-assignment verdict, on three dimensions, in this fleet's own
# three-valued vocabulary. There is no argument anywhere that can assert it.
#
# This is not bin/fm-independence-lib.sh and must not be confused with it. That
# library derives whether a VALIDATION RUN's reviewer was independent, from the
# pipeline's invocation-time records. This answers the narrower question a
# qualification-gated dispatch has to answer BEFORE anything runs: given these
# two bindings, may one review the other's work at all? The dimensions are named
# the same way and the asymmetry is the same - what was never observed may only
# ever weaken a claim of independence, never a finding of dependence.
fm_qualification_independence() {
  local maker=$1 reviewer=$2 cfg=${3:-}
  local binding=PASS provider=NO_VERIFIER_RAN pool=NO_VERIFIER_RAN
  local mp rp mpool rpool

  if [ -z "$maker" ] || [ -z "$reviewer" ]; then
    printf 'binding=NO_VERIFIER_RAN provider=NO_VERIFIER_RAN pool=NO_VERIFIER_RAN overall=NO_VERIFIER_RAN\n'
    return 0
  fi
  [ "$maker" != "$reviewer" ] || binding=FAIL

  # Provider and pool come from the model registry, which already owns them. A
  # name that differs is NOT evidence of two accounts and a name that matches is
  # not evidence of one: only a declaration this fleet made may relate them, so
  # an undeclared model is could-not-observe on both dimensions rather than
  # independent.
  if declare -F fm_model_registry_provider_of >/dev/null 2>&1; then
    mp=$(fm_model_registry_provider_of "$maker" 2>/dev/null || true)
    rp=$(fm_model_registry_provider_of "$reviewer" 2>/dev/null || true)
    if [ -n "$mp" ] && [ -n "$rp" ]; then
      if [ "$mp" = "$rp" ]; then provider=FAIL; else provider=PASS; fi
    fi
  fi
  if declare -F fm_model_pool_of >/dev/null 2>&1; then
    mpool=$(fm_model_pool_of "$maker" 2>/dev/null || true)
    rpool=$(fm_model_pool_of "$reviewer" 2>/dev/null || true)
    if [ -n "$mpool" ] && [ -n "$rpool" ]; then
      if [ "$mpool" = "$rpool" ]; then pool=FAIL; else pool=PASS; fi
    fi
  fi
  : "${cfg:-}"

  local overall=PASS
  case "$binding$provider$pool" in
    *FAIL*) overall=FAIL ;;
    *NO_VERIFIER_RAN*) overall=NO_VERIFIER_RAN ;;
  esac
  printf 'binding=%s provider=%s pool=%s overall=%s\n' "$binding" "$provider" "$pool" "$overall"
}

# fm_qualification_reviewer_refusal <maker-model> <reviewer-model> <contract-id>...
# The refusal for a reviewer that may not take this assignment, or nothing and 0
# when it may. Prints the FIRST reason only: a reviewer refused for self-review
# does not need to be told about its credential pool as well.
#
# ONE REVIEWER MAY HOLD SEVERAL CONTRACTS, and may then perform each of those
# jobs on one assignment. Holding them is never itself independence, which is why
# both checks run and the self-review refusal comes first.
fm_qualification_reviewer_refusal() {
  local maker=$1 reviewer=$2
  shift 2
  local contract state st dims binding
  if [ "$maker" = "$reviewer" ]; then
    printf '%s: %s made this candidate, so it may not review it; no binding independently reviews its own mutation merely because it qualified for the reviewing contract\n' \
      "$FM_QUAL_TOKEN_SELF_REVIEW" "$reviewer"
    return 1
  fi
  for contract in "$@"; do
    [ -n "$contract" ] || continue
    state=$(fm_qualification_state "$contract" "$reviewer")
    st=$(printf '%s' "$state" | jq -r '.state' 2>/dev/null)
    if [ "$st" != QUALIFIED ]; then
      printf '%s is %s for contract %s, so it may not perform that review: %s\n' \
        "$reviewer" "$st" "$contract" \
        "$(printf '%s' "$state" | jq -r '.reason' 2>/dev/null)"
      return 1
    fi
  done
  dims=$(fm_qualification_independence "$maker" "$reviewer")
  binding=${dims#binding=}
  binding=${binding%% *}
  if [ "$binding" = FAIL ]; then
    printf '%s: assignment independence does not hold on the binding dimension (%s)\n' \
      "$FM_QUAL_TOKEN_SELF_REVIEW" "$dims"
    return 1
  fi
  return 0
}

fm_qualification_adjudicator_refusal() {  # <maker> <adjudicator> <contract> <comma-dimensions>
  local maker=$1 adjudicator=$2 contract=$3 dimensions=$4 verdict dimension value
  fm_qualification_reviewer_refusal "$maker" "$adjudicator" "$contract" || return 1
  verdict=$(fm_qualification_independence "$maker" "$adjudicator")
  while IFS= read -r dimension; do
    [ -n "$dimension" ] || continue
    value=$(printf '%s\n' "$verdict" | tr ' ' '\n' | awk -F= -v key="$dimension" '$1 == key { print $2; exit }')
    if [ "$value" != PASS ]; then
      printf 'assignment independence dimension %s is %s (%s)\n' "$dimension" "${value:-COULD_NOT_OBSERVE}" "$verdict"
      return 1
    fi
  done <<EOF
$(printf '%s' "$dimensions" | tr ',' '\n')
EOF
  return 0
}

# ---------------------------------------------------------------------------
# Route integration
# ---------------------------------------------------------------------------

# fm_qualification_floor_contracts <config-file> <floor-id>
# The contract ids a floor declares, one per line. Nothing and exit 1 when the
# floor declares none, which is what keeps this inert for every home that never
# opted in. Exit 2 when the declaration exists and cannot be interpreted: a
# malformed requirement is refused by name rather than enforcing nothing, exactly
# as every other floor axis is.
fm_qualification_floor_contracts() {
  local file=$1 floor=$2 raw
  [ -n "$floor" ] || return 1
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  raw=$(jq -c --arg f "$floor" '(._floors // {})[$f].requires_capabilities // null' "$file" 2>/dev/null) || return 2
  [ -n "$raw" ] || return 2
  [ "$raw" != null ] || return 1
  printf '%s' "$raw" | jq -e '
    (type == "array") and (length > 0) and all(.[]; (type == "string") and (length > 0))
  ' >/dev/null 2>&1 || return 2
  printf '%s' "$raw" | jq -r '.[]' 2>/dev/null || return 2
}

# fm_qualification_cost_rank <model>
# The ordering key for "cheapest". Prints "<rank>" where a lower rank is cheaper,
# and prints the sentinel rank for a model whose cost could not be observed.
#
# UNMEASURED COST NEVER READS AS CHEAP. A model with no registry entry, an
# unreadable registry or no recorded price sorts LAST among promising candidates
# rather than first, which is the same rule the registry already applies when it
# refuses a provider whose cost posture is unclassified. Cheapest is an ordering
# over observed prices, not over silence.
FM_QUALIFICATION_COST_UNOBSERVED=999999999
fm_qualification_cost_rank() {  # <model>
  local model=$1 file rank
  if ! declare -F fm_model_registry_path >/dev/null 2>&1; then
    printf '%s\n' "$FM_QUALIFICATION_COST_UNOBSERVED"; return 0
  fi
  file=$(fm_model_registry_path 2>/dev/null) || file=
  if [ -z "$file" ] || [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$FM_QUALIFICATION_COST_UNOBSERVED"; return 0
  fi
  rank=$(jq -r --arg m "$model" --argjson none "$FM_QUALIFICATION_COST_UNOBSERVED" '
    (.models[$m] // null) as $e
    | (.zero_budget.allowlist[$m] // null) as $a
    | ($e.price_at_verification // $a.price_at_verification // null) as $p
    | if $e == null and $a == null then $none
      elif ($p | type) == "object" and (($p.input | type) == "number") and (($p.output | type) == "number")
      then (($p.input + $p.output) * 1000 | floor)
      elif ($e.cost_class // "") == "subscription-flat" then 0
      else $none end' "$file" 2>/dev/null) || rank=
  case "$rank" in
    ''|*[!0-9]*) printf '%s\n' "$FM_QUALIFICATION_COST_UNOBSERVED" ;;
    *) printf '%s\n' "$rank" ;;
  esac
}

# fm_qualification_route_lines <config-file> <floor-id> <route-id> <harness> <native-effort> <subject-model> <models...>
# The merge lines bin/fm-route-lib.sh consumes, one per model:
#
#   <model><TAB><state><TAB><contracts><TAB><cost-rank><TAB><retry><TAB><applicability><TAB><evidence>
#
# Evidence stays LAST because it is the only free-text field; every typed field
# is positional ahead of it, so adding one never depends on what the prose
# happens to contain.
#
# Prints nothing and exits 1 when the floor declares no capability requirement,
# which is the inert path. Exits 2 when the declaration itself is malformed, so
# the caller refuses by name rather than enforcing nothing.
#
# A model needing SEVERAL contracts gets the WEAKEST of its per-contract states,
# by the same ranking the freshness fold uses: FAILED beats COULD_NOT_OBSERVE
# beats QUALIFICATION_STALE beats QUALIFICATION_REQUIRED beats QUALIFIED. A
# candidate qualified as maker and unqualified as reviewer is not half eligible.
#
# THE RETRY DISPOSITION FOLDS INDEPENDENTLY, over the same contracts, because it
# is a separate axis: a candidate whose weakest state comes from one contract may
# be the one whose retry another contract refuses, and reporting only the
# disposition that happened to accompany the weakest state would lose that. Same
# direction as every fold here - the strictest answer wins.
fm_qualification_route_lines() {
  local file=$1 floor=$2 route=$3 dispatch_harness=$4 dispatch_effort=$5 subject_model=$6
  shift 6
  local contracts rc=0
  contracts=$(fm_qualification_floor_contracts "$file" "$floor") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  local model contract state st worst worst_rank rank evidence names harness effort
  local retry retry_worst retry_rank retry_worst_rank retry_evidence
  local applicability applicability_worst
  names=$(printf '%s' "$contracts" | tr '\n' ',' | sed 's/,$//')
  for model in "$@"; do
    [ -n "$model" ] || continue
    IFS=$'\x1f' read -r harness effort <<EOF2
$(jq -r --arg route "$route" --arg model "$model" --arg h "$dispatch_harness" --arg e "$dispatch_effort" --arg subject "$subject_model" '
  ([((.rules // [])[]? | select(.route == $route)),
     (.default // empty | select(.route == $route))] | first) as $r
  | (if ($r.use | type) == "array"
     then ([$r.use[] | select((.model // "") == $model)] | first // {})
     elif ($r.use | type) == "object" then $r.use
     else {} end) as $p
  | [if $model == $subject and ($h | length) > 0 then $h else ($p.harness // "") end,
     if $model == $subject and ($e | length) > 0 then $e else ($p.effort // "") end]
  | join("\u001f")' "$file" 2>/dev/null)
EOF2
    worst=QUALIFIED
    worst_rank=0
    evidence=
    retry_worst=permitted
    retry_worst_rank=0
    retry_evidence=
    applicability_worst=
    while IFS= read -r contract; do
      [ -n "$contract" ] || continue
      state=$(fm_qualification_state "$contract" "$model" "$harness" "$effort")
      st=$(printf '%s' "$state" | jq -r '.state' 2>/dev/null)
      case "$st" in
        QUALIFIED) rank=0 ;;
        QUALIFICATION_REQUIRED) rank=1 ;;
        QUALIFICATION_STALE) rank=2 ;;
        COULD_NOT_OBSERVE) rank=3 ;;
        FAILED) rank=4 ;;
        *) rank=3; st=COULD_NOT_OBSERVE ;;
      esac
      if [ "$rank" -gt "$worst_rank" ]; then
        worst_rank=$rank
        worst=$st
        evidence=$(printf '%s' "$state" | jq -r '.reason' 2>/dev/null | tr '\n\t' '  ')
        applicability_worst=$(printf '%s' "$state" | jq -r '.applicability // ""' 2>/dev/null)
      fi
      retry=$(printf '%s' "$state" | jq -r '.retry_disposition // "unknown"' 2>/dev/null)
      case "$retry" in
        permitted) retry_rank=0 ;;
        unknown) retry_rank=1 ;;
        not-permitted) retry_rank=2 ;;
        *) retry_rank=1; retry=unknown ;;
      esac
      if [ "$retry_rank" -gt "$retry_worst_rank" ]; then
        retry_worst_rank=$retry_rank
        retry_worst=$retry
        # The refusal a reader acts on must name the contract it came from, or a
        # candidate refused on one of several contracts is refused anonymously.
        retry_evidence="$contract: $(printf '%s' "$state" | jq -r '.retry_reason // ""' 2>/dev/null | tr '\n\t' '  ')"
      fi
    done <<EOF
$contracts
EOF
    [ -n "$evidence" ] || evidence="every declared capability contract ($names) is qualified for this binding"
    # Both facts reach the reader, because the weakest STATE and the withheld
    # RETRY can come from different contracts on the same candidate. Replacing
    # one with the other would report a candidate excluded on contract A with
    # the reason contract B refuses to re-run it.
    [ "$retry_worst" = permitted ] || evidence="$evidence · retry $retry_worst - $retry_evidence"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$model" "$worst" "$names" \
      "$(fm_qualification_cost_rank "$model")" "$retry_worst" "$applicability_worst" "$evidence"
  done
  return 0
}
