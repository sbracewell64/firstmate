#!/usr/bin/env bash
# fm-semantics.sh - the only interpreter of firstmate's semantics/ register.
#
# It reads the tracked semantic owner documents, checks their invariants, emits
# deterministic machine projections, and runs the four validators. It is a
# COMPILER and a CHECKER. It is not a runtime: it stores no task state, makes no
# runtime decision, schedules nothing, watches nothing, and has no daemon.
#
# THE ONE BOUNDARY THIS TOOL MAY NEVER CROSS
#
# bin/fm-decision-surface.sh answers what a task is DOING. This tool answers what
# a word MEANS and what may follow it. The moment it answers the first question
# the fleet has two answers to one question, and both get credited with the same
# sentence. semantics/schema.json refused_keys is the mechanical form of that
# boundary and this script enforces it at every depth of every document.
#
# WHY A COMPILER AND NOT A LIBRARY EVERY CONSUMER PARSES
#
# A consumer that parses the owner directly re-implements the reading of it, and
# two readers of one file eventually disagree about it. A projection is compiled
# once, byte-for-byte reproducibly, and drift-checked in CI, so a hand edit of a
# generated file is a red build rather than a silent second source of truth.
#
# Usage:
#   fm-semantics.sh check                      every owner invariant, drift, and
#                                              manifest check - the CI entry point
#   fm-semantics.sh validate                   owner-document invariants only
#   fm-semantics.sh compile                    write the three projections
#   fm-semantics.sh compile --check            refuse if any projection is stale
#   fm-semantics.sh show <document>            print one owner document
#   fm-semantics.sh reason <code>              resolve a reason code to its namespace
#   fm-semantics.sh preflight --manifest <p>   the deterministic design preflight
#   fm-semantics.sh preflight --concept <c> --name <n>
#                                              does an existing owner already cover this
#   fm-semantics.sh manifest --all             check every manifest
#   fm-semantics.sh manifest <id>              check one manifest
#   fm-semantics.sh adoption [<manifest-id>]   report each adoption prerequisite
#   fm-semantics.sh validate-state <record> [--for-effect] [--now <epoch>]
#   fm-semantics.sh validate-transition <record>
#   fm-semantics.sh validate-effect-commit <record> <phase>
#   fm-semantics.sh validate-identity-mapping <record>
#   fm-semantics.sh --help
#
# Exit codes follow the three-valued contract bin/fm-semantics-lib.sh owns:
#   0  PASS - the checked dimensions hold
#   2  usage
#   3  REFUSE - a checked dimension is violated
#   4  CNO - the question could not be answered from the inputs given
#
# GENERATED OUTPUTS, AND THE ONE COMPATIBILITY GUARANTEE
#
#   loopspecs/terminal-states.json
#     The compatibility projection. Its vocabulary, its four source mappings and
#     its invariants are reproduced UNCHANGED from what shipped, so
#     bin/fm-loopspec.sh, the loopspecs/schema.json external_enums pointer,
#     bin/fm-attempt.sh and bin/fm-loop-actuate.sh keep working with no edit.
#     The only added bytes are a generated block no consumer reads. A rename was
#     available and was deliberately not taken: a flag day would have made every
#     one of those consumers a migration.
#
#   semantics/generated/semantics.projection.json
#     The complete machine projection - families, successors, terminal reasons,
#     reason namespaces, identity namespaces and edges, protocols and versions.
#
#   semantics/generated/semantics.projection.sh
#     The same contract as sourceable shell constants, for an existing shell
#     owner that needs the vocabulary without a JSON parse on a hot path.
#
# Each carries the digest of exactly the owner documents it was compiled from -
# not of the whole register - so an unrelated owner edit does not churn a file
# whose content did not change.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

# shellcheck source=bin/fm-semantics-lib.sh
. "$SELF_DIR/fm-semantics-lib.sh"

SEM_DIR="$FM_SEMANTICS_DIR"
MANIFEST_DIR="$SEM_DIR/manifests"
GEN_DIR="$SEM_DIR/generated"
TERMINAL_TARGET="$ROOT/loopspecs/terminal-states.json"
PROJECTION_JSON="$GEN_DIR/semantics.projection.json"
PROJECTION_SH="$GEN_DIR/semantics.projection.sh"

PROJECTION_SCHEMA='fm-semantics-projection.v1'

die_usage() { printf 'fm-semantics: %s\n' "$1" >&2; exit "$FM_SEMANTICS_EXIT_USAGE"; }
say() { printf '%s\n' "$1"; }

need_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-semantics: jq is required\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
}

# Portable content digest over the concatenation of the named files, in the
# order given. The order is part of the digest on purpose: the same files in a
# different order are a different compilation input.
owner_digest() {  # <file>...
  if command -v sha256sum >/dev/null 2>&1; then
    cat "$@" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    cat "$@" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

usage() { sed -n '3,70p' "$SELF_DIR/fm-semantics.sh" | sed 's/^# \{0,1\}//'; }

# --- owner invariants ---------------------------------------------------------
#
# One jq program per document, each printing zero or more problem lines. A
# document that cannot be read at all is reported as could-not-observe by the
# caller rather than as zero problems, because an unreadable owner and a clean
# owner must never produce the same answer.

problems_state_families() {
  jq -r '
    def inlist($a): . as $v | ($a | index($v)) != null;
    . as $D
    | ($D.families | map(.name)) as $names
    | ($D.object_families | map({key: .name, value: .}) | from_entries) as $obj
    | ($D.terminal_reasons | map(.name)) as $terms
    | ($D.verdict_vocabularies.observation.members) as $obs
    | [
        ( ($names | group_by(.)[] | select(length > 1) | .[0])
          | "duplicate family name: \(.)" ),
        ( $D.families[] | select((.legal_successors | type) != "array")
          | "family \(.name) declares no legal_successors array" ),
        ( $D.families[] | . as $f | ($f.legal_successors // [])[]
          | . as $succ | select($succ | inlist($names) | not)
          | "family \($f.name) names successor \($succ), which is not a declared family" ),
        ( $D.families[] | select(.terminal == true)
          | select((.legal_successors // []) != (if .name == "SUPERSEDED" then [] else ["SUPERSEDED"] end))
          | "terminal family \(.name) may name only SUPERSEDED, and SUPERSEDED itself none" ),
        ( $D.families[] | select(.terminal == false)
          | select((.obligation_required != true)
                   or ((.owner_is // "") == "") or ((.wake_is // "") == "") or ((.reobservation_is // "") == ""))
          | "nonterminal family \(.name) must require an obligation and name owner_is, wake_is and reobservation_is" ),
        ( $D.terminal_reasons[] | select(.family | inlist($names) | not)
          | "terminal reason \(.name) maps to \(.family // "<absent>"), which is not a declared family" ),
        ( $D.terminal_reasons | group_by(.family)[] | select(length > 1)
          | select(([.[].kind] | unique | length) > 1) | .[]
          | select((.family_distinction // null) == null)
          | "terminal reason \(.name) shares family \(.family) with a reason of different kind and declares no family_distinction" ),
        ( $D.sources[] | . as $s | (.map | map(.state) | group_by(.)[] | select(length > 1) | .[0])
          | "source \($s.source) declares state \(.) more than once" ),
        ( $D.sources[] | . as $s | $s.map[] | . as $r
          | select(.unified != "OBSERVATION_RESULT")
          | select(
              ($s.maps_onto == "terminal_reason" and ($terms | index($r.unified)) == null)
              or ($s.maps_onto == "work_family" and ($names | index($r.unified)) == null)
              or ($s.maps_onto == "authority_state" and (($obj.AUTHORITY.states | index($r.unified)) == null))
              or (["terminal_reason","work_family","authority_state"] | index($s.maps_onto)) == null )
          | "source \($s.source) state \($r.state) maps to \($r.unified), which is not a declared member of \($s.maps_onto)" ),
        ( $D.sources[] | . as $s | $s.map[] | select(.unified == "OBSERVATION_RESULT")
          | select((.observation_verdict // "") | inlist($obs) | not)
          | "source \($s.source) state \(.state) is an OBSERVATION_RESULT and names no declared observation verdict" ),
        ( $names[] | . as $n
          | select(($D.families[] | select(.name == $n) | .no_source_reason // null) == null)
          | select(($n | inlist([$D.sources[] | select(.maps_onto == "work_family") | .map[] | .unified]
                                + [$D.terminal_reasons[] | .family])) | not)
          | "work family \($n) is unreachable: no source row and no terminal reason maps to it, and it declares no no_source_reason" ),
        ( $D.sources[] | . as $s | select($s.maps_onto == "work_family") | $s.map[]
          | select(.unified | inlist($obj.AUTHORITY.states))
          | "source \($s.source) maps state \(.state) onto authority member \(.unified) as a work family, which the authority-is-not-a-work-family invariant refuses" ),
        ( $names[] | select(inlist($obj.AUTHORITY.states))
          | "work family \(.) collides with a member of the AUTHORITY object family" )
      ] | .[]
  ' "$(fm_semantics_doc state-families)"
}

problems_reasons() {
  jq -r '
    def inlist($a): . as $v | ($a | index($v)) != null;
    . as $D
    | ($D.namespaces | map(.namespace)) as $ns
    | [ $D.namespaces[] | .codes[] | .code ] as $codes
    | [
        ( ($ns | group_by(.)[] | select(length > 1) | .[0]) | "duplicate namespace: \(.)" ),
        ( ($codes | group_by(.)[] | select(length > 1) | .[0])
          | "reason code \(.) is declared in more than one namespace, so its namespace cannot be resolved by lookup" ),
        ( $D.namespaces[] | .codes[] | select(.verdict | inlist(["REFUSE","CNO"]) | not)
          | "reason code \(.code) declares verdict \(.verdict // "<absent>"); only REFUSE and CNO are reasons, and PASS never is" ),
        ( $D.namespaces[] | .codes[] | select((.repair // "") == "")
          | "reason code \(.code) names no repair, so a refusal citing it cannot say what to fix" ),
        ( $D.namespaces[] | select((.owner_to_repair // "") == "")
          | "namespace \(.namespace) names no owner_to_repair" ),
        ( select(($ns | length) != 6)
          | "exactly six reason namespaces are declared; found \($ns | length)" )
      ] | .[]
  ' "$(fm_semantics_doc reasons)"
}

problems_identity() {
  jq -r '
    def inlist($a): . as $v | ($a | index($v)) != null;
    . as $D
    | ($D.namespaces | map(.id)) as $ids
    | ($D.canonical_subject.subject_types | map(.subject_type)) as $types
    | [
        ( ($ids | group_by(.)[] | select(length > 1) | .[0]) | "duplicate namespace id: \(.)" ),
        ( ($D.namespaces | map(.namespace) | group_by(.)[] | select(length > 1) | .[0])
          | "duplicate namespace name: \(.)" ),
        ( $D.namespaces[] | select((.owner // "") == "")
          | "namespace \(.id) names no owner" ),
        ( $D.edges[] | select((.owner // null) != null) | select((.provenance // "") == "")
          | "edge \(.edge) has an owner and records no provenance, so the mapping cannot be re-checked" ),
        ( $D.edges[] | select((.owner // null) == null) | select((.status // "") != "UNOWNED")
          | "edge \(.edge) names no owner and does not declare status UNOWNED" ),
        ( $D.edges[] | select((.status // "") == "UNOWNED") | select((.consequence // "") == "")
          | "edge \(.edge) is UNOWNED and states no consequence" ),
        ( ($D.edges | map(.edge) | group_by(.)[] | select(length > 1) | .[0])
          | "edge \(.) is declared more than once, which is the two-owner defect in a different costume" ),
        ( $D.canonical_subject.subject_types[] | select((.required_axes | type) != "array" or (.required_axes | length) == 0)
          | "subject type \(.subject_type) declares no required axes" ),
        ( $D.canonical_subject.subject_types[] | . as $t | ($t.mutable_axes // [])[]
          | . as $ax | select($ax | inlist($t.required_axes))
          | "subject type \($t.subject_type) declares \($ax) as both a required identity axis and a mutable one; an identity axis that moves produces a DIFFERENT subject, not a stale one, so the two sets must be disjoint" ),
        ( $D.canonical_subject.subject_types[] | . as $t | ($t.venue_axes // [])[]
          | . as $ax | select($ax | inlist(($t.required_axes // []) + ($t.mutable_axes // [])))
          | "subject type \($t.subject_type) declares \($ax) as both a venue axis and an identity axis; a transport cannot become a subject, and an overlap is exactly what lets a configured venue be read as the thing under review" ),
        ( $D.canonical_subject.subject_types[] | . as $t | ($t.referential_integrity // [])[]
          | . as $rule | select([(($t.required_axes // []) + ($t.venue_axes // []))[] | . as $ax | select($rule | test("\\b" + $ax + "\\b"))] | length == 0)
          | "subject type \($t.subject_type) states a referential-integrity rule naming no declared axis: \($rule)" ),
        ( select(($types | unique | length) != ($types | length))
          | "duplicate subject_type declared" )
      ] | .[]
  ' "$(fm_semantics_doc identity)"
}

problems_seams() {
  jq -r '
    . as $D
    | [
        ( select((($D.seam_states | length) != 4)
                 or (([$D.seam_states[] | select(.is_a_pass == true)] | length) != 1))
          | "exactly four seam states must be declared with exactly one pass; found \($D.seam_states | length) states and \([$D.seam_states[] | select(.is_a_pass == true)] | length) passes" ),
        ( ($D.protocols | map(.protocol) | group_by(.)[] | select(length > 1) | .[0])
          | "duplicate protocol: \(.)" ),
        ( $D.protocols[] | select((.owner // "") == "") | "protocol \(.protocol) names no owner" ),
        ( $D.protocols[] | select(((.producers // []) | length) == 0)
          | "protocol \(.protocol) declares no producer, so an undeclared producer could never be detected" ),
        ( $D.protocols[] | select(((.accepted_versions // []) | length) == 0)
          | "protocol \(.protocol) declares no accepted versions, so an unknown version would be parsed on a guess" )
      ] | .[]
  ' "$(fm_semantics_doc seams)"
}

problems_laws() {
  jq -r --slurpfile R "$(fm_semantics_doc reasons)" '
    def inlist($a): . as $v | ($a | index($v)) != null;
    . as $D
    | ($R[0].namespaces | map(.namespace)) as $ns
    | ["validate_state","validate_transition","validate_effect_commit","validate_identity_mapping"] as $validators
    | ($D.adoption_prerequisites.prerequisites | map(.id)) as $prereqs
    | ($D.adoption_prerequisites.machine_evaluable + $D.adoption_prerequisites.not_machine_evaluable) as $partition
    | [
        ( ($D.laws | map(.id) | group_by(.)[] | select(length > 1) | .[0]) | "duplicate law id: \(.)" ),
        ( select(($D.laws | length) != 5) | "exactly five laws are declared; found \($D.laws | length)" ),
        ( $D.laws[] | select(.reason_namespace | inlist($ns) | not)
          | "law \(.id) names reason namespace \(.reason_namespace // "<absent>"), which reasons does not declare" ),
        ( $D.laws[] | select((.validator // null) != null) | select(.validator | inlist($validators) | not)
          | "law \(.id) names validator \(.validator), which is not one of the four declared validators" ),
        ( select(($D.gate_placement | length) != 3)
          | "exactly three gate-placement predicates are declared; found \($D.gate_placement | length)" ),
        ( select(([$D.gate_placement[] | select(.may_grant == true)] | length) != 1
                 or ([$D.gate_placement[] | select(.may_grant == true) | .id] != ["G3"]))
          | "exactly one gate predicate may grant and it must be G3; found \([$D.gate_placement[] | select(.may_grant == true) | .id] | join(","))" ),
        ( $prereqs[] | . as $pr | select($pr | inlist($partition) | not)
          | "adoption prerequisite \($pr) appears in neither machine_evaluable nor not_machine_evaluable" ),
        ( $partition[] | . as $pa | select($pa | inlist($prereqs) | not)
          | "adoption partition names \($pa), which is not a declared prerequisite" ),
        ( ($partition | group_by(.)[] | select(length > 1) | .[0])
          | "adoption prerequisite \(.) appears in both halves of the partition" )
      ] | .[]
  ' "$(fm_semantics_doc laws)"
}

problems_census() {
  jq -r --slurpfile SF "$(fm_semantics_doc state-families)" '
    def inlist($a): . as $v | ($a | index($v)) != null;
    . as $D
    | ($D.axes) as $axes
    | ($D.classification_vocabulary | keys) as $classes
    | [
        ( ($D.rows | map(.id) | group_by(.)[] | select(length > 1) | .[0]) | "duplicate census row id: \(.)" ),
        ( $D.rows[] | select(.axis | inlist($axes) | not)
          | "census row \(.id) names axis \(.axis // "<absent>"), which is not declared" ),
        ( $D.rows[] | select(.classification | inlist($classes) | not)
          | "census row \(.id) names classification \(.classification // "<absent>"), which is not declared" ),
        ( $D.rows[] | select(.classification == "SUBJECT_SPECIFIC_EXTENSION")
          | select((.consumer_action_distinction // "") == "")
          | "census row \(.id) is a subject-specific extension and states no consumer-action distinction, so it is a synonym" ),
        ( $D.rows[] | select(.classification == "ADAPTER") | select((.retires_on // "") == "")
          | "census row \(.id) is an adapter and names nothing it retires on, so it is a permanent hidden second path" ),
        ( $D.rows[] | select(.classification == "GENERATED_PROJECTION") | select((.manifest // null) == null)
          | "census row \(.id) is a generated projection and names no manifest, so it cannot be traced to the owner that emits it" ),
        ( $D.rows[] | select((.rationale // "") == "")
          | "census row \(.id) states no rationale for its classification" )
      ] | .[]
  ' "$(fm_semantics_doc census)"
}

# Cross-document checks no single document can see.
problems_cross() {
  local doc path
  for doc in schema laws state-families reasons identity seams census; do
    path=$(fm_semantics_doc "$doc")
    jq -e --arg d "$doc" '.document == $d' "$path" >/dev/null 2>&1 \
      || printf 'document %s declares document=%s\n' "$doc" "$(jq -r '.document // "<absent>"' "$path")"
    jq -e '.semantics_schema_version == 1' "$path" >/dev/null 2>&1 \
      || printf 'document %s declares semantics_schema_version %s where 1 is required\n' \
           "$doc" "$(jq -r '.semantics_schema_version // "<absent>"' "$path")"
    jq -e '(.authority | type) == "string" or (.authority | type) == "object"' "$path" >/dev/null 2>&1 \
      || printf 'document %s declares no authority, so a reader cannot tell what it may rely on\n' "$doc"
  done
  # A refused key at ANY depth in ANY document or manifest. Refused outright
  # rather than ignored: an ignored field still reads to a human as the answer.
  local refused
  refused=$(jq -r '.refused_keys[]' "$(fm_semantics_doc schema)")
  local f
  for f in "$SEM_DIR"/*.json "$MANIFEST_DIR"/*.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$refused" | while IFS= read -r key; do
      [ -n "$key" ] || continue
      jq -e --arg k "$key" '[paths | .[-1] | select(type == "string")] | index($k) != null' \
        "$f" >/dev/null 2>&1 \
        && printf '%s carries refused key %s; this register may describe semantics and may never hold one\n' \
             "${f#"$ROOT"/}" "$key"
    done
  done
  # A census row may record where a semantics lives; it may never define one.
  jq -r --slurpfile SF "$(fm_semantics_doc state-families)" '
    def inlist($a): . as $v | ($a | index($v)) != null;
    ($SF[0].families | map(.name)) as $fams
    | .rows[] | . as $r | (.declares_family // null)
    | select(. != null) | . as $df | select($df | inlist($fams) | not)
    | "census row \($r.id) declares family \($df), which the owner documents do not - the census records where a semantics lives and never what it means"
  ' "$(fm_semantics_doc census)"
  # Every manifest a census row names must exist.
  jq -r '.rows[] | select((.manifest // null) != null) | "\(.id)\t\(.manifest)"' \
    "$(fm_semantics_doc census)" \
  | while IFS=$'\t' read -r row man; do
      [ -f "$MANIFEST_DIR/$man.json" ] \
        || printf 'census row %s names manifest %s, which does not exist under semantics/manifests/\n' "$row" "$man"
    done
}

cmd_validate() {
  need_jq
  fm_semantics_docs_readable schema laws state-families reasons identity seams census || {
    printf 'fm-semantics: an owner document is unreadable, so no invariant could be evaluated\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  local problems rc=0
  problems=$(
    problems_cross
    problems_state_families
    problems_reasons
    problems_identity
    problems_seams
    problems_laws
    problems_census
  ) || {
    printf 'fm-semantics: an invariant program failed to run, so the register could not be observed\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf 'refuse_invalid_owner %s\n' "$line" >&2
    done
    rc="$FM_SEMANTICS_EXIT_REFUSE"
  else
    say "fm-semantics validate: every declared owner invariant holds"
  fi
  return "$rc"
}

# --- compile ------------------------------------------------------------------

compile_terminal_projection() {  # <out-path>
  local out=$1 src digest
  src=$(fm_semantics_doc state-families)
  digest=$(owner_digest "$src") || return 1
  jq --indent 2 --arg d "$digest" '
    {
      generated: {
        by: "bin/fm-semantics.sh compile",
        from: ["semantics/state-families.json"],
        source_digest: $d,
        do_not_edit: "This file is a COMPATIBILITY PROJECTION. Its vocabulary, its source mappings and its invariants are owned by semantics/state-families.json and are reproduced here unchanged so every existing consumer keeps working with no edit. Edit the owner and run bin/fm-semantics.sh compile; a hand edit here is drift and CI refuses it.",
        authority: "authoritative - this projection carries semantics that were already authoritative before the owner moved"
      },
      loopspec_schema_version: .terminal_projection.loopspec_schema_version,
      description: .terminal_projection.description,
      unified: (.terminal_reasons | map({name, kind, costs_model_turn, description})),
      sources: (.sources | map(select(.projected_to_terminal_states) | {source, owner, description, map})),
      invariants: .terminal_projection.invariants
    }' "$src" > "$out"
}

projection_owner_files() {
  printf '%s\n' \
    "$(fm_semantics_doc laws)" \
    "$(fm_semantics_doc state-families)" \
    "$(fm_semantics_doc reasons)" \
    "$(fm_semantics_doc identity)" \
    "$(fm_semantics_doc seams)" \
    "$(fm_semantics_doc schema)"
}

compile_projection_json() {  # <out-path>
  local out=$1 digest
  local -a owners
  owners=()
  while IFS= read -r f; do owners+=("$f"); done < <(projection_owner_files)
  digest=$(owner_digest "${owners[@]}") || return 1
  jq --indent 2 -n \
    --arg schema "$PROJECTION_SCHEMA" \
    --arg d "$digest" \
    --slurpfile LAW "$(fm_semantics_doc laws)" \
    --slurpfile SF "$(fm_semantics_doc state-families)" \
    --slurpfile RE "$(fm_semantics_doc reasons)" \
    --slurpfile ID "$(fm_semantics_doc identity)" \
    --slurpfile SE "$(fm_semantics_doc seams)" '
    ($LAW[0]) as $law | ($SF[0]) as $sf | ($RE[0]) as $re | ($ID[0]) as $id | ($SE[0]) as $se
    | {
        generated: {
          by: "bin/fm-semantics.sh compile",
          from: ["semantics/laws.json","semantics/state-families.json","semantics/reasons.json","semantics/identity.json","semantics/seams.json","semantics/schema.json"],
          source_digest: $d,
          do_not_edit: "Compiled from the owner documents named above. Edit an owner and run bin/fm-semantics.sh compile; a hand edit here is drift and CI refuses it.",
          authority: "diagnostic - the terminal half of the state vocabulary is authoritative in its own compatibility projection; everything else here is diagnostic until the adoption prerequisites pass"
        },
        schema: $schema,
        versions: {
          law_set: $law.version.law_set_version,
          gate_predicate: $law.version.gate_predicate_version,
          family_vocabulary: $sf.version.family_vocabulary_version,
          transition: $sf.version.transition_version,
          terminal_vocabulary: $sf.version.terminal_vocabulary_version,
          source_mapping: $sf.version.source_mapping_version,
          reason_register: $re.version.reason_register_version,
          namespace_register: $id.version.namespace_register_version,
          subject_schema: $id.version.subject_schema_version,
          seam_contract: $se.version.seam_contract_version,
          protocol_register: $se.version.protocol_register_version
        },
        laws: ($law.laws | map({id, name, reason_namespace, validator})),
        gate_placement: ($law.gate_placement | map({id, name, may_grant, may_refuse})),
        gate_tension_resolution: $law.gate_tension_resolution.rule,
        observation_horizon: {predicate: $law.observation_horizon_dominance.predicate, reason_code: $law.observation_horizon_dominance.reason_code},
        adoption_prerequisites: ($law.adoption_prerequisites.prerequisites | map({id, requires})),
        adoption_machine_evaluable: $law.adoption_prerequisites.machine_evaluable,
        families: ($sf.families | map({name, terminal, obligation_required, consumer_action, legal_successors})),
        legal_successors: ($sf.families | map({key: .name, value: .legal_successors}) | from_entries),
        object_families: ($sf.object_families | map({name, states, transitions})),
        verdict_vocabularies: {
          observation: $sf.verdict_vocabularies.observation.members,
          validator: $sf.verdict_vocabularies.validator.members,
          validator_exit_codes: $sf.verdict_vocabularies.validator.exit_codes,
          validator_to_observation: $sf.verdict_vocabularies.total_mapping.validator_to_observation,
          observation_to_validator: $sf.verdict_vocabularies.total_mapping.observation_to_validator
        },
        terminal_reasons: ($sf.terminal_reasons | map({name, kind, costs_model_turn, family})),
        terminal_reason_to_family: ($sf.terminal_reasons | map({key: .name, value: .family}) | from_entries),
        source_mappings: ($sf.sources | map({source: .source, owner: .owner, maps_onto: .maps_onto, rows: (.map | map({state, unified, observation_verdict}))})),
        observation_result_literal: $sf.unmapped_row_encoding.literal,
        reason_namespaces: ($re.namespaces | map({namespace, law, owner_to_repair, codes: (.codes | map({code, verdict}))})),
        reason_namespace_of: ([$re.namespaces[] | . as $n | $n.codes[] | {key: .code, value: $n.namespace}] | from_entries),
        reason_verdict_of: ([$re.namespaces[] | .codes[] | {key: .code, value: .verdict}] | from_entries),
        identity_namespaces: ($id.namespaces | map({id, namespace, identity_rule, owner})),
        subject_types: ($id.canonical_subject.subject_types | map({subject_type, required_axes, mutable_axes, venue_axes, referential_integrity})),
        subject_compilation_rules: $id.canonical_subject.compilation_rules,
        edges: ($id.edges | map({edge, owner, status, provenance})),
        unowned_edges: ([$id.edges[] | select(.status == "UNOWNED") | .edge]),
        seam_states: ($se.seam_states | map({state, is_a_pass})),
        protocols: ($se.protocols | map({protocol, owner, producers, consumers, accepted_versions})),
        protocol_law: ($se.protocol_law | to_entries | map({rule_id: .key, rule: .value.rule}))
      }' > "$out"
}

compile_projection_sh() {  # <out-path>
  local out=$1 digest json
  local -a owners
  owners=()
  while IFS= read -r f; do owners+=("$f"); done < <(projection_owner_files)
  digest=$(owner_digest "${owners[@]}") || return 1
  json=$(fm_semantics_doc state-families)
  {
    printf '#!/usr/bin/env bash\n'
    printf '# semantics.projection.sh - GENERATED by bin/fm-semantics.sh compile. Do not edit.\n'
    printf '#\n'
    printf '# Compiled from semantics/laws.json, semantics/state-families.json,\n'
    printf '# semantics/reasons.json, semantics/identity.json, semantics/seams.json and\n'
    printf '# semantics/schema.json. Edit an owner and recompile; a hand edit here is drift\n'
    printf '# and CI refuses it.\n'
    printf '#\n'
    printf '# Source it. It defines constants and runs nothing:\n'
    printf '#   . semantics/generated/semantics.projection.sh\n'
    printf '#\n'
    printf '# Authority: DIAGNOSTIC, except the terminal vocabulary, which carried its\n'
    printf '# authority across from loopspecs/terminal-states.json unchanged. A consumer may\n'
    printf '# read the rest and may not yet rely on it.\n'
    printf '\n'
    printf '# shellcheck disable=SC2034  # contract constants consumed by sourcing callers\n'
    printf 'FM_SEMANTICS_PROJECTION_SCHEMA=%s\n' "$PROJECTION_SCHEMA"
    printf 'FM_SEMANTICS_PROJECTION_SOURCE_DIGEST=%s\n' "$digest"
    # A single quote cannot appear inside a single-quoted shell string, so the
    # quote the generated assignments need is passed in as $q rather than typed.
    jq -r --arg q "'" \
      '
      def words(f): [f] | join(" ");
      "FM_SEMANTICS_FAMILIES=\($q)\(words(.families[].name))\($q)",
      "FM_SEMANTICS_TERMINAL_FAMILIES=\($q)\(words(.families[] | select(.terminal) | .name))\($q)",
      "FM_SEMANTICS_NONTERMINAL_FAMILIES=\($q)\(words(.families[] | select(.terminal | not) | .name))\($q)",
      (.families[] | "FM_SEMANTICS_SUCCESSORS_\(.name)=\($q)\(.legal_successors | join(" "))\($q)"),
      "FM_SEMANTICS_TERMINAL_REASONS=\($q)\(words(.terminal_reasons[].name))\($q)",
      (.terminal_reasons[] | "FM_SEMANTICS_TERMINAL_FAMILY_\(.name)=\($q)\(.family)\($q)"),
      "FM_SEMANTICS_SOURCE_VOCABULARIES=\($q)\(words(.sources[].source))\($q)",
      "FM_SEMANTICS_OBSERVATION_RESULT_LITERAL=\($q)\(.unmapped_row_encoding.literal)\($q)",
      "FM_SEMANTICS_OBSERVATION_VERDICTS=\($q)\(.verdict_vocabularies.observation.members | join(" "))\($q)",
      "FM_SEMANTICS_VALIDATOR_VERDICTS=\($q)\(.verdict_vocabularies.validator.members | join(" "))\($q)",
      (.object_families[] | "FM_SEMANTICS_OBJECT_FAMILY_\(.name)=\($q)\(.states | join(" "))\($q)")
    ' "$json"
    jq -r --arg q "'" \
      '
      "FM_SEMANTICS_REASON_NAMESPACES=\($q)\([.namespaces[].namespace] | join(" "))\($q)",
      (.namespaces[] | "FM_SEMANTICS_REASON_CODES_\(.namespace | ascii_upcase)=\($q)\([.codes[].code] | join(" "))\($q)")
    ' "$(fm_semantics_doc reasons)"
    jq -r --arg q "'" \
      '
      "FM_SEMANTICS_IDENTITY_NAMESPACES=\($q)\([.namespaces[].id] | join(" "))\($q)",
      "FM_SEMANTICS_SUBJECT_TYPES=\($q)\([.canonical_subject.subject_types[].subject_type] | join(" "))\($q)",
      (.canonical_subject.subject_types[] | select((.venue_axes // []) | length > 0)
       | "FM_SEMANTICS_VENUE_AXES_\(.subject_type | ascii_upcase)=\($q)\(.venue_axes | join(" "))\($q)"),
      "FM_SEMANTICS_UNOWNED_EDGES=\($q)\([.edges[] | select(.status == "UNOWNED") | .edge] | join("; "))\($q)"
    ' "$(fm_semantics_doc identity)"
    jq -r --arg q "'" \
      '
      "FM_SEMANTICS_SEAM_STATES=\($q)\([.seam_states[].state] | join(" "))\($q)",
      "FM_SEMANTICS_SEAM_PASS_STATE=\($q)\([.seam_states[] | select(.is_a_pass) | .state] | join(" "))\($q)",
      "FM_SEMANTICS_PROTOCOLS=\($q)\([.protocols[].protocol] | join(" "))\($q)"
    ' "$(fm_semantics_doc seams)"
  } > "$out"
}

cmd_compile() {
  need_jq
  local check=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      *) die_usage "unknown option for compile: $1" ;;
    esac
  done
  fm_semantics_docs_readable schema laws state-families reasons identity seams || {
    printf 'fm-semantics: an owner document is unreadable, so nothing could be compiled\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-semantics.XXXXXX") || {
    printf 'fm-semantics: could not create a scratch directory\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  # shellcheck disable=SC2064  # expand tmp now, so the trap cannot clean a later value
  trap "rm -rf '$tmp'" EXIT
  compile_terminal_projection "$tmp/terminal-states.json" || {
    printf 'fm-semantics: the terminal projection could not be compiled\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  compile_projection_json "$tmp/semantics.projection.json" || {
    printf 'fm-semantics: the machine projection could not be compiled\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  compile_projection_sh "$tmp/semantics.projection.sh" || {
    printf 'fm-semantics: the shell projection could not be compiled\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  # A generated shell file escapes the canonical lint set because it is not under
  # bin/, so its parseability is proven here instead of being assumed.
  bash -n "$tmp/semantics.projection.sh" || {
    printf 'fm-semantics: the compiled shell projection does not parse\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  local stale=0 pair target src
  for pair in "$TERMINAL_TARGET:$tmp/terminal-states.json" \
              "$PROJECTION_JSON:$tmp/semantics.projection.json" \
              "$PROJECTION_SH:$tmp/semantics.projection.sh"; do
    target=${pair%%:*}
    src=${pair#*:}
    if [ "$check" -eq 1 ]; then
      if [ ! -f "$target" ]; then
        printf 'refuse_stale_projection %s is absent; run bin/fm-semantics.sh compile\n' \
          "${target#"$ROOT"/}" >&2
        stale=1
      elif ! cmp -s "$target" "$src"; then
        printf 'refuse_stale_projection %s differs from what the owners compile to; run bin/fm-semantics.sh compile\n' \
          "${target#"$ROOT"/}" >&2
        stale=1
      fi
    else
      mkdir -p "$(dirname "$target")"
      cp "$src" "$target"
      say "wrote ${target#"$ROOT"/}"
    fi
  done
  [ "$stale" -eq 0 ] || return "$FM_SEMANTICS_EXIT_REFUSE"
  [ "$check" -eq 1 ] && say "fm-semantics compile --check: every projection reproduces byte-for-byte"
  return 0
}

# --- manifests ----------------------------------------------------------------

manifest_problems() {  # <manifest-path>
  local path=$1
  jq -r \
    --slurpfile SCH "$(fm_semantics_doc inheritance-manifest)" \
    --slurpfile SF "$(fm_semantics_doc state-families)" \
    --slurpfile RE "$(fm_semantics_doc reasons)" \
    --slurpfile ID "$(fm_semantics_doc identity)" \
    --slurpfile SE "$(fm_semantics_doc seams)" \
    --slurpfile LAW "$(fm_semantics_doc laws)" \
    --arg base "$(basename "$path" .json)" '
    def inlist($a): . as $v | ($a | index($v)) != null;
    . as $m
    | ($SCH[0]) as $sch
    | ($SF[0].families | map(.name)) as $fams
    | ($RE[0].namespaces | map(.namespace)) as $ns
    | ($ID[0].namespaces | map(.id)) as $nsids
    | ($SE[0].protocols | map(.protocol)) as $protos
    | ($LAW[0].gate_placement | map(.id)) as $gates
    | ($sch.consumes_fields | keys | map(select(. != "gate_rules"))) as $required_consumes
    | [
        ( select(($m.manifest_schema_version // 0) != $sch.version.manifest_schema_version)
          | "manifest_schema_version is \($m.manifest_schema_version // "<absent>") where \($sch.version.manifest_schema_version) is required" ),
        ( select(($m.id // "") != $base)
          | "id \($m.id // "<absent>") does not match the file basename \($base)" ),
        ( ["mechanism","owner","load_bearing","authority_status","consumes","extensions","gate_rules"][]
          | . as $k | select(($m | has($k)) | not)
          | "required key \($k) is absent" ),
        ( select(($m.authority_status // "") | inlist(["authoritative","diagnostic"]) | not)
          | "authority_status is \($m.authority_status // "<absent>"); it must be authoritative or diagnostic" ),
        ( $required_consumes[] | . as $k | select((($m.consumes // {}) | has($k)) | not)
          | "consumes is missing \($k); an explicit none with a reason is accepted, an absent key is not" ),
        ( ($m.consumes // {}) | to_entries[] | select((.value | type) == "object")
          | select(((.value.version // null) == null) and ((.value.reason // "") == "") and ((.value.note // "") == "") and ((.value.vocabulary // "") == "") and ((.value.performs_effect // null) == null) and ((.value.requires_authority // null) == null) and ((.value.subject_type // "") == "") and ((.value.mutable_axes // null) == null))
          | "consumes.\(.key) declares neither a version nor an explicit reason" ),
        ( select((($m.consumes.state_families.version // null) != null)
                 and ($m.consumes.state_families.version != $SF[0].version.family_vocabulary_version))
          | "consumes.state_families claims version \($m.consumes.state_families.version) where the owner declares \($SF[0].version.family_vocabulary_version)" ),
        ( select((($m.consumes.transitions.version // null) != null)
                 and ($m.consumes.transitions.version != $SF[0].version.transition_version))
          | "consumes.transitions claims version \($m.consumes.transitions.version) where the owner declares \($SF[0].version.transition_version)" ),
        ( select((($m.consumes.reason_namespaces.version // null) != null)
                 and ($m.consumes.reason_namespaces.version != $RE[0].version.reason_register_version))
          | "consumes.reason_namespaces claims version \($m.consumes.reason_namespaces.version) where the owner declares \($RE[0].version.reason_register_version)" ),
        ( ($m.consumes.reason_namespaces.namespaces // [])[] | . as $v | select($v | inlist($ns) | not)
          | "consumes.reason_namespaces names \($v), which reasons does not declare" ),
        ( ($m.consumes.identity_namespaces.namespaces // [])[] | . as $v | select($v | inlist($nsids) | not)
          | "consumes.identity_namespaces names \($v), which identity does not declare" ),
        ( ($m.consumes.seam_protocol.protocols // [])[] | select(.protocol | inlist($protos) | not)
          | "consumes.seam_protocol names protocol \(.protocol), which seams does not declare" ),
        ( ($m.gate_rules // [])[] | . as $v | select($v | inlist($gates) | not)
          | "gate_rules names \($v), which laws does not declare" ),
        ( ($m.extensions // [])[] | select((.consumer_action_distinction // "") == "")
          | "extension \(.name // "<unnamed>") states no consumer_action_distinction, so it is a synonym rather than a distinction" ),
        ( ($m.extensions // [])[] | select((.why_canonical_reuse_fails // "") == "")
          | "extension \(.name // "<unnamed>") does not say which canonical member was considered and what it cannot express" ),
        ( ($m.extensions // [])[] | select(.extends == "state_family") | select(.name | inlist($fams))
          | "extension \(.name) shadows canonical family \(.name); a local redefinition of a shared word is the failure this manifest exists to prevent" ),
        ( ($m.extensions // [])[] | select(.extends == "reason_namespace") | select(.name | inlist($ns))
          | "extension \(.name) shadows canonical reason namespace \(.name)" ),
        ( $sch.refused_keys[] | . as $k
          | select($k | inlist([$m | paths | .[-1] | select(type == "string")]))
          | "manifest carries refused key \($k)" )
      ] | .[]
  ' "$path"
}

cmd_manifest() {
  need_jq
  fm_semantics_docs_readable inheritance-manifest state-families reasons identity seams laws || {
    printf 'fm-semantics: an owner document is unreadable, so no manifest could be checked\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  local all=0 want=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) all=1; shift ;;
      -*) die_usage "unknown option for manifest: $1" ;;
      *) want=$1; shift ;;
    esac
  done
  local -a paths
  paths=()
  if [ "$all" -eq 1 ]; then
    local f
    for f in "$MANIFEST_DIR"/*.json; do
      [ -f "$f" ] && paths+=("$f")
    done
    [ "${#paths[@]}" -gt 0 ] || {
      printf 'fm-semantics: no manifests exist under semantics/manifests/, so none could be checked\n' >&2
      exit "$FM_SEMANTICS_EXIT_CNO"
    }
  else
    [ -n "$want" ] || die_usage "manifest requires an id or --all"
    [ -f "$MANIFEST_DIR/$want.json" ] || {
      printf 'fm-semantics: no manifest %s under semantics/manifests/\n' "$want" >&2
      exit "$FM_SEMANTICS_EXIT_CNO"
    }
    paths=("$MANIFEST_DIR/$want.json")
  fi
  local rc=0 p problems
  for p in "${paths[@]}"; do
    problems=$(manifest_problems "$p") || {
      printf 'fm-semantics: manifest %s could not be read\n' "${p#"$ROOT"/}" >&2
      exit "$FM_SEMANTICS_EXIT_CNO"
    }
    if [ -n "$problems" ]; then
      printf '%s\n' "$problems" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'refuse_invalid_manifest %s: %s\n' "$(basename "$p" .json)" "$line" >&2
      done
      rc="$FM_SEMANTICS_EXIT_REFUSE"
    else
      say "manifest $(basename "$p" .json): inherits every shared semantics it declares"
    fi
  done
  return "$rc"
}

# --- preflight ----------------------------------------------------------------
#
# The deterministic design preflight. It answers ONE question before a new
# stateful mechanism is designed: does an existing family, reason, identity
# namespace, subject type, protocol or seam already cover this? Reuse is
# mandatory when it does, so a name that already exists REFUSES rather than being
# reported as a coincidence.

cmd_preflight() {
  need_jq
  local manifest='' concept='' name=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --manifest) [ "$#" -gt 1 ] || die_usage "--manifest requires a path"; manifest=$2; shift 2 ;;
      --concept) [ "$#" -gt 1 ] || die_usage "--concept requires a value"; concept=$2; shift 2 ;;
      --name) [ "$#" -gt 1 ] || die_usage "--name requires a value"; name=$2; shift 2 ;;
      *) die_usage "unknown option for preflight: $1" ;;
    esac
  done
  fm_semantics_docs_readable state-families reasons identity seams || {
    printf 'fm-semantics: an owner document is unreadable, so reuse could not be checked\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  if [ -n "$manifest" ]; then
    [ -f "$manifest" ] || {
      printf 'fm-semantics: no manifest at %s, and a mechanism with no manifest may not hold authority\n' "$manifest" >&2
      exit "$FM_SEMANTICS_EXIT_CNO"
    }
    local problems
    problems=$(manifest_problems "$manifest") || {
      printf 'fm-semantics: the manifest could not be read\n' >&2
      exit "$FM_SEMANTICS_EXIT_CNO"
    }
    if [ -n "$problems" ]; then
      printf '%s\n' "$problems" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'refuse_preflight %s\n' "$line" >&2
      done
      return "$FM_SEMANTICS_EXIT_REFUSE"
    fi
    say "preflight $(basename "$manifest" .json): every shared semantics is declared and every extension states a consumer-action distinction"
    return 0
  fi
  [ -n "$concept" ] && [ -n "$name" ] || die_usage "preflight requires --manifest, or --concept with --name"
  local hit=''
  case "$concept" in
    state_family)
      hit=$(jq -r --arg n "$name" '.families[] | select(.name == $n) | "family \(.name): \(.consumer_action)"' "$(fm_semantics_doc state-families)") ;;
    terminal_reason)
      hit=$(jq -r --arg n "$name" '.terminal_reasons[] | select(.name == $n) | "terminal reason \(.name) -> family \(.family)"' "$(fm_semantics_doc state-families)") ;;
    reason)
      hit=$(jq -r --arg n "$name" '.namespaces[] | . as $ns | .codes[] | select(.code == $n) | "reason \(.code) in namespace \($ns.namespace), repaired by \($ns.owner_to_repair)"' "$(fm_semantics_doc reasons)") ;;
    reason_namespace)
      hit=$(jq -r --arg n "$name" '.namespaces[] | select(.namespace == $n) | "reason namespace \(.namespace) for law \(.law)"' "$(fm_semantics_doc reasons)") ;;
    identity_namespace)
      hit=$(jq -r --arg n "$name" '.namespaces[] | select(.id == $n or .namespace == $n) | "identity namespace \(.id) \(.namespace), owned by \(.owner)"' "$(fm_semantics_doc identity)") ;;
    subject_type)
      hit=$(jq -r --arg n "$name" '.canonical_subject.subject_types[] | select(.subject_type == $n) | "subject type \(.subject_type) with axes \(.required_axes | join(","))"' "$(fm_semantics_doc identity)") ;;
    protocol)
      hit=$(jq -r --arg n "$name" '.protocols[] | select(.protocol == $n) | "protocol \(.protocol), owned by \(.owner)"' "$(fm_semantics_doc seams)") ;;
    seam_state)
      hit=$(jq -r --arg n "$name" '.seam_states[] | select(.state == $n) | "seam state \(.state), pass=\(.is_a_pass)"' "$(fm_semantics_doc seams)") ;;
    *) die_usage "unknown concept: $concept (state_family, terminal_reason, reason, reason_namespace, identity_namespace, subject_type, protocol, seam_state)" ;;
  esac
  if [ -n "$hit" ]; then
    printf 'refuse_preflight an existing owner already covers this: %s\n' "$hit" >&2
    printf 'refuse_preflight reuse is MANDATORY where a shared semantics applies; a new distinction needs a stated consumer-action difference and an extension of the shared contract first\n' >&2
    return "$FM_SEMANTICS_EXIT_REFUSE"
  fi
  say "preflight $concept $name: no canonical member of that name exists, so a new one may be proposed with a consumer-action distinction in an inheritance manifest"
  return 0
}

# --- adoption -----------------------------------------------------------------

cmd_adoption() {
  need_jq
  fm_semantics_docs_readable laws || {
    printf 'fm-semantics: laws is unreadable, so no prerequisite could be evaluated\n' >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  local want=${1:-state-seam-semantics}
  local manifest="$MANIFEST_DIR/$want.json"
  local ap1 ap2 ap3 ap4 ap5
  ap1=CNO; ap2=CNO; ap3=CNO; ap4=CNO; ap5=CNO
  [ -f "$manifest" ] && { manifest_problems "$manifest" | grep -q . && ap1=FAIL || ap1=PASS; }
  cmd_validate >/dev/null 2>&1 && ap2=PASS || ap2=FAIL
  cmd_compile --check >/dev/null 2>&1 && ap3=PASS || ap3=FAIL
  # AP4 and AP5 are facts about a REAL crossing and a witnessed red. This tool
  # cannot observe either from its own position, and answering them from a test
  # result would credit the test with the crossing.
  ap4=CNO
  ap5=CNO
  printf 'fm-semantics adoption: %s\n' "$want"
  printf '  AP1 inheritance manifest ............ %s\n' "$ap1"
  printf '  AP2 total mappings .................. %s\n' "$ap2"
  printf '  AP3 projections fresh ............... %s\n' "$ap3"
  printf '  AP4 real producer-boundary-consumer . %s (this tool cannot observe a production crossing from here; the seam owner reports it)\n' "$ap4"
  printf '  AP5 witnessed red ................... %s (a red observed in a test suite is evidence for the SUITE; the seam owner reports the crossing red)\n' "$ap5"
  printf '  AP6 no duplicate owner .............. CNO (a judgement about meaning, decided by review; semantics/census.json is its evidence base and not its verdict)\n'
  printf '  AP7 exact-head qualified review ..... CNO (owned by bin/fm-pr-check.sh and bin/fm-qualification.sh)\n'
  printf '  AP8 effect authorization ............ CNO (not applicable while this mechanism performs no effect; recorded as unobserved rather than as satisfied)\n'
  printf '  VERDICT ............................. NOT AUTHORITATIVE - prerequisites remain unobserved, so every output of this mechanism stays diagnostic\n'
  case "$ap1$ap2$ap3" in
    *FAIL*) return "$FM_SEMANTICS_EXIT_REFUSE" ;;
  esac
  return "$FM_SEMANTICS_EXIT_CNO"
}

# --- inspection ---------------------------------------------------------------

cmd_show() {
  need_jq
  local doc=${1:-} path
  path=$(fm_semantics_doc "$doc") || die_usage "unknown document: ${doc:-<absent>}"
  [ -f "$path" ] || {
    printf 'fm-semantics: %s is absent\n' "${path#"$ROOT"/}" >&2
    exit "$FM_SEMANTICS_EXIT_CNO"
  }
  cat "$path"
}

cmd_reason() {
  need_jq
  local code=${1:-} ns
  [ -n "$code" ] || die_usage "reason requires a code"
  ns=$(fm_semantics_reason_namespace "$code") || {
    printf 'fm-semantics: %s is not a declared reason code; a code that resolves to no namespace routes the repair to nobody\n' "$code" >&2
    exit "$FM_SEMANTICS_EXIT_REFUSE"
  }
  jq -r --arg c "$code" --arg n "$ns" '
    .namespaces[] | select(.namespace == $n) | . as $N | .codes[] | select(.code == $c)
    | "code=\(.code)\nnamespace=\($N.namespace)\nlaw=\($N.law)\nverdict=\(.verdict)\nowner_to_repair=\($N.owner_to_repair)\nmeans=\(.means)\nrepair=\(.repair)"
  ' "$(fm_semantics_doc reasons)"
}

cmd_check() {
  local rc=0 step
  for step in validate compile manifest; do
    case "$step" in
      validate) cmd_validate || rc=$? ;;
      compile) cmd_compile --check || rc=$? ;;
      manifest) cmd_manifest --all || rc=$? ;;
    esac
  done
  [ "$rc" -eq 0 ] && say "fm-semantics check: owners hold, projections are fresh, every manifest inherits"
  return "$rc"
}

main() {
  [ "$#" -gt 0 ] || die_usage "a subcommand is required (see --help)"
  local cmd=$1
  shift
  case "$cmd" in
    -h|--help|help) usage; exit "$FM_SEMANTICS_EXIT_PASS" ;;
    check) cmd_check "$@" ;;
    validate) cmd_validate "$@" ;;
    compile) cmd_compile "$@" ;;
    show) cmd_show "$@" ;;
    reason) cmd_reason "$@" ;;
    preflight) cmd_preflight "$@" ;;
    manifest) cmd_manifest "$@" ;;
    adoption) cmd_adoption "$@" ;;
    validate-state) fm_semantics_run validate_state "$@" ;;
    validate-transition) fm_semantics_run validate_transition "$@" ;;
    validate-effect-commit) fm_semantics_run validate_effect_commit "$@" ;;
    validate-identity-mapping) fm_semantics_run validate_identity_mapping "$@" ;;
    *) die_usage "unknown subcommand: $cmd (see --help)" ;;
  esac
}

main "$@"
