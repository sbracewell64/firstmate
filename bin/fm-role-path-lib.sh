#!/usr/bin/env bash
# fm-role-path-lib.sh - the ONE owner of the pre-reservation role-path and
# custody preflight product (ARC-1).
#
# WHAT THIS ANSWERS. Before a dispatch is allowed to allocate anything, one
# product must establish, together and for the SAME generation: which exact
# semantic work this is, which roles must act on it and with which binding on
# which resource path, whether each of those bindings is currently qualified,
# whether the assignments are distinct, which bases and venue the work lands
# against, and WHO - singularly - currently owns mutation of the candidate.
# Each of those facts already had an owner; none of them had a JOINT answer, so
# a dispatch could be admitted on a route decision taken against one generation
# while custody had already moved under another.
#
# WHAT THIS IS NOT. It is not a scheduler, a registry, a reservation store, a
# capability authority, a custody database, a route, or a control plane. It
# holds no durable state, writes nothing, allocates nothing, and reserves
# nothing - on EVERY verdict, including PERMITTED. It decides no fact of its
# own: every axis is asked of the owner that already answers it, and an axis
# that owner could not establish is COULD-NOT-OBSERVE rather than permitted.
# On PERMITTED it NAMES the one reservation identity the caller is thereby
# authorized to allocate through the existing allocator; naming is not holding.
#
#   route, floor, pool and policy digest    bin/fm-route-lib.sh
#   role qualification and independence     bin/fm-qualification-lib.sh
#   source and contribution bases, venue    bin/fm-task-base-lib.sh
#   execution incarnation and lineage       bin/fm-attempt.sh execution
#   worktree custody and process quiescence bin/fm-worktree-guard.sh owner-state
#   complete no-mistakes run census         fm_nm_census (bin/fm-nm-run-lib.sh)
#
# WHAT THIS PRODUCT DOES NOT COVER, so nothing credits it with them. Fleet
# admission (bin/fm-admission.sh) and provider capacity (bin/fm-capacity-lib.sh)
# are separate gates that bin/fm-spawn.sh already applies at this same chokepoint,
# ahead of allocation. They answer properties of the FLEET and of a PROVIDER, not
# of this candidate's role path or custody, and folding them in here would give
# each of them a second decision procedure that could disagree with its owner. A
# PERMITTED verdict therefore means "no role, qualification, generation or
# custody fact refuses this candidate", never "this dispatch may start".
#
# PRECEDENCE IS PROPERTY-LOCAL FAIL > CNO > PASS, and the product records every
# axis it could evaluate rather than stopping at the first refusal, because the
# point of a joint product is that the whole path is visible at once. The
# VERDICT is the fold: any REFUSED beats any COULD-NOT-OBSERVE, which beats
# PERMITTED, and among equals the earliest axis in the fixed order below is the
# one reported. A later refusal overrides an earlier could-not-observe, because
# an established violation is a stronger fact than an unread one.
#
# AXIS ORDER, fixed so the reported reason is deterministic:
#   1 work identity          2 role path completeness
#   3 role path permission   4 assignment distinction
#   5 role qualification     6 candidate generation
#   7 execution generation   8 worktree custody
#   9 no-mistakes census    10 singular mutation owner
#
# REASON CODES, closed:
#   PERMITTED                    every axis established; one reservation named.
#   INCOMPLETE_WORK_IDENTITY     CNO. Which work this is was not fully stated.
#   INCOMPLETE_ROLE_PATH         CNO. A required role, binding or resource path
#                                is missing, so the path is not fully stated.
#   ROLE_PATH_NOT_PERMITTED      REFUSED. A role may not act on that path, or is
#                                not currently qualified for the contract it needs.
#   ASSIGNMENT_NOT_DISTINCT      REFUSED. Two roles collapse to one assignment.
#   ROLE_QUALIFICATION_UNOBSERVED  CNO. A declared requirement could not be read.
#   STALE_CANDIDATE_GENERATION   REFUSED. The candidate head moved under the
#                                generation this product was computed for.
#   STALE_EXECUTION              REFUSED. The lane's open execution is not the
#                                one this dispatch claims.
#   EXECUTION_UNOBSERVED         CNO. The lane's execution lineage could not be
#                                read, so which producer holds it is unknown.
#   WORKTREE_UNOBSERVED          CNO. Worktree custody could not be read at all.
#   TREEHOUSE_CUSTODY_AMBIGUOUS  CNO. It was read and named no single owner.
#   NM_CENSUS_INCOMPLETE         CNO. The run population could not be covered.
#   PARTICIPANT_OWNS_MUTATION    REFUSED. A live no-mistakes run owns the
#                                candidate, so firstmate must leave it alone.
#   DUPLICATE_MUTATION_OWNER     REFUSED. More than one live owner, or one that
#                                is not this dispatch's to take.
#
# QUALIFICATION IS FOUR-VALUED HERE, deliberately. QUALIFIED, NOT_QUALIFIED and
# CNO are the three values of a requirement that EXISTS. NOT_APPLICABLE is the
# absence of the requirement, and it is not a fourth shade of observation: a
# home whose floors declare no capability contract has nothing to observe, and
# recording that as CNO would make an opted-out home permanently unobservable.
#
# REQUEST FORMAT, one key=value per line, passed as a single argument:
#   work=<semantic work id>          repository=<dir>
#   branch=<name>                    base=<sha>
#   candidate_head=<sha>             (omit when the candidate is not yet created)
#   venue=<contribution venue>       route=<route id>
#   task=<task id>                   worktree=<path>
#   config=<config dir>              (only to stamp the route policy digest)
#   slot=<slot name>                 mode=<delivery mode>
#   nm_applicable=yes|no             whether no-mistakes owns mutation for this
#                                    work's delivery. Only `yes` consults the run
#                                    census; anything else records the census as
#                                    not-applicable rather than as covered.
#   succeeds_execution=<execution id>  (a replacement, not a new dispatch)
#   require=<role|base>              repeatable; what THIS product must cover.
#                                    A role name requires that leg of the path;
#                                    the literal `base` requires a resolved
#                                    source base. Declaring none asks only the
#                                    custody and generation question, and the
#                                    product says so rather than looking complete.
#   role=<role>|<binding>|<resource path>      repeatable
#   contract=<role>|<contract id>              repeatable
#
# Exit status is the verdict, so a caller that ignores stdout still stops safely:
#   0  PERMITTED   1  REFUSED   4  COULD_NOT_OBSERVE (the CLI adds 2 for usage)
set -u

FM_ROLE_PATH_SCHEMA=fm-role-path-custody-preflight.v1
FM_ROLE_PATH_EXIT_PERMITTED=0
FM_ROLE_PATH_EXIT_REFUSED=1
FM_ROLE_PATH_EXIT_CNO=4
# Every role name this product understands. WHICH of them a given product must
# cover is the CALLER's declaration (`require=` below), never a constant here: a
# caller that requires maker and checker and a caller that requires neither are
# asking different questions, and one rule that quietly answered the weaker one
# for both would hand every caller the weakest guarantee any of them accepted.
# The required set is recorded in the product, so a product that required
# nothing can never be read as having established a role path.
FM_ROLE_PATH_ROLES='maker checker adjudicator publisher'
# Census bound. High enough that a complete listing is the normal answer, and
# the truncation footer still refuses rather than silently covering a prefix.
FM_ROLE_PATH_CENSUS_LIMIT=${FM_ROLE_PATH_CENSUS_LIMIT:-1000}
FM_ROLE_PATH_CENSUS_TIMEOUT=${FM_ROLE_PATH_CENSUS_TIMEOUT:-120}

_rp_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

# Value of <key> from the request, or empty. First occurrence wins.
_rp_get() {  # <request> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# Every value of a repeatable <key>.
_rp_all() {  # <request> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# One role's field: 1=binding, 2- resource path (2- rather than 2 so a path that
# itself contains the separator reaches the path check whole instead of being
# silently shortened into one that could never match).
_rp_role_field() {  # <request> <role> <field-index>
  printf '%s\n' "$1" | sed -n "s/^role=$2|//p" | head -1 | cut -d'|' -f"$3"
}

_rp_role_declared() {  # <request> <role>
  printf '%s\n' "$1" | grep -q "^role=$2|"
}

_rp_role_contracts() {  # <request> <role>
  printf '%s\n' "$1" | sed -n "s/^contract=$2|//p"
}

_rp_json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g'; }

# ---------------------------------------------------------------------------
# The single fold
# ---------------------------------------------------------------------------
#
# Outputs (set by fm_role_path_preflight, read by its callers):
FM_ROLE_PATH_VERDICT=''
FM_ROLE_PATH_REASON_CODE=''
FM_ROLE_PATH_REASON=''
FM_ROLE_PATH_PRODUCT=''
FM_ROLE_PATH_RESERVATION=''
FM_ROLE_PATH_MUTATION_OWNER=''

# Verdict accumulators. rp_fail always wins over rp_cno; among equals the
# earliest axis is kept, which is what makes the reported reason deterministic.
_rp_fail() {  # <code> <reason>
  [ "$FM_ROLE_PATH_VERDICT" = REFUSED ] && return 0
  FM_ROLE_PATH_VERDICT=REFUSED
  FM_ROLE_PATH_REASON_CODE=$1
  FM_ROLE_PATH_REASON=$2
  return 0
}

_rp_cno() {  # <code> <reason>
  case "$FM_ROLE_PATH_VERDICT" in REFUSED|CNO) return 0 ;; esac
  FM_ROLE_PATH_VERDICT=CNO
  FM_ROLE_PATH_REASON_CODE=$1
  FM_ROLE_PATH_REASON=$2
  return 0
}

# Every live effect-holder found, one "<kind>:<identity>" per line. The set's
# SIZE is the singularity test and its MEMBER is what names the refusal, so both
# questions are answered from one collection rather than from two walks that
# could disagree.
_RP_OWNERS=''
_rp_owner() {  # <kind> <identity>
  _RP_OWNERS="${_RP_OWNERS}$1:$2
"
}

fm_role_path_preflight() {  # <request>
  local req=${1:-}
  local work repository branch base candidate_head venue route task worktree slot mode succeeds
  local binding resource contracts contract state st qual reason
  local roles_json='' custody_json='' owner_count=0 owner_line owner_kind
  local dir; dir=$(_rp_dir)

  FM_ROLE_PATH_VERDICT=PERMITTED
  FM_ROLE_PATH_REASON_CODE=PERMITTED
  FM_ROLE_PATH_REASON='every axis was established for one generation and no live owner holds the candidate'
  FM_ROLE_PATH_PRODUCT=''
  FM_ROLE_PATH_RESERVATION=''
  FM_ROLE_PATH_MUTATION_OWNER=''
  _RP_OWNERS=''

  work=$(_rp_get "$req" work)
  repository=$(_rp_get "$req" repository)
  branch=$(_rp_get "$req" branch)
  base=$(_rp_get "$req" base)
  candidate_head=$(_rp_get "$req" candidate_head)
  venue=$(_rp_get "$req" venue)
  route=$(_rp_get "$req" route)
  task=$(_rp_get "$req" task)
  worktree=$(_rp_get "$req" worktree)
  slot=$(_rp_get "$req" slot)
  mode=$(_rp_get "$req" mode)
  succeeds=$(_rp_get "$req" succeeds_execution)

  # --- 1. work identity ----------------------------------------------------
  # Every later axis is ABOUT this identity, so an unstated one is not a weaker
  # answer to the same question - it is a different question, and no git command
  # runs against an unstated repository path.
  local missing=''
  [ -n "$work" ] || missing="$missing work"
  [ -n "$repository" ] || missing="$missing repository"
  [ -n "$branch" ] || missing="$missing branch"
  # The BASE is recorded but refused only on request. bin/fm-task-base-lib.sh
  # already rules on an unresolvable base: it reports `unresolved` and the
  # dispatch proceeds on a warning, leaving the slot at whatever commit it last
  # held. Converting that owner's deliberate disposition into a refusal here
  # would give one input two rulings, and the newer one would win by accident of
  # ordering rather than by anyone deciding it should. A caller that genuinely
  # needs a resolved base asks for one with `require=base`; the product records
  # the truth either way, so nothing can read an unresolved base as a resolved.
  case " $(_rp_all "$req" require | tr '\n' ' ') " in
    *" base "*) [ -n "$base" ] || missing="$missing base" ;;
  esac
  if [ -n "$missing" ]; then
    _rp_cno INCOMPLETE_WORK_IDENTITY \
      "the semantic work generation is not fully stated (missing:${missing}), so no axis below could be about a known subject"
  elif [ ! -d "$repository" ]; then
    _rp_cno INCOMPLETE_WORK_IDENTITY \
      "repository $repository is not a readable directory, so this work's own code identity could not be observed"
  fi

  # --- 2/3/4/5. the role path ---------------------------------------------
  local declared_roles='' required_roles='' r
  for r in $FM_ROLE_PATH_ROLES; do
    _rp_role_declared "$req" "$r" && declared_roles="$declared_roles $r"
  done
  # `require=` carries both role names and the literal `base`. Only role names
  # belong to the role-path completeness check; requiring `base` there would
  # look for a role nothing can ever declare.
  required_roles=''
  for r in $(_rp_all "$req" require); do
    case " $FM_ROLE_PATH_ROLES " in
      *" $r "*) required_roles="$required_roles$r " ;;
    esac
  done
  for r in $required_roles; do
    case " $declared_roles " in
      *" $r "*) ;;
      *) _rp_cno INCOMPLETE_ROLE_PATH \
           "this product is required to cover the $r role and the path declares none, so who performs that job on this work is unstated; an omitted axis is unobserved, never vacuously satisfied" ;;
    esac
  done

  local assignments='' assignment dup_reported=0
  for r in $declared_roles; do
    binding=$(_rp_role_field "$req" "$r" 1)
    resource=$(_rp_role_field "$req" "$r" 2-)
    if [ -z "$binding" ] || [ -z "$resource" ]; then
      _rp_cno INCOMPLETE_ROLE_PATH \
        "role $r states $( [ -z "$binding" ] && printf 'no binding' || printf 'no resource path' ), so its protocol axes are incomplete"
    fi
    # 3. A role may act only on the resource path this work covers. A role
    # pointed at another repository or another branch is not a weaker claim on
    # this path; it is a claim on a path this product does not govern.
    if [ -n "$resource" ] && [ -n "$branch" ] && [ -n "$repository" ]; then
      case "$resource" in
        "$repository:$branch") ;;
        *) _rp_fail ROLE_PATH_NOT_PERMITTED \
             "role $r declares resource path $resource, which is not this work's governed path $repository:$branch; a role may not act outside the path the product covers" ;;
      esac
    fi
    # 4. Assignment identity is binding-on-path: the same binding acting on the
    # same path is ONE assignment however many role names it is given, which is
    # exactly the collapse a maker reviewing its own mutation performs.
    assignment="$binding@$resource"
    if [ -n "$binding" ] && [ -n "$resource" ]; then
      case "$assignments" in
        *"|$assignment|"*)
          [ "$dup_reported" -eq 1 ] || _rp_fail ASSIGNMENT_NOT_DISTINCT \
            "role $r resolves to assignment $assignment, which another role in this path already holds; two roles that are one assignment provide one act of judgement, not two"
          dup_reported=1
          ;;
        *) assignments="$assignments|$assignment|" ;;
      esac
    fi
  done

  # 5. Current qualification, asked of the register rather than remembered. A
  # role with no declared contract has no requirement to meet, which is what
  # keeps this whole axis inert for a home that never opted in.
  # shellcheck source=bin/fm-qualification-lib.sh
  declare -F fm_qualification_state >/dev/null 2>&1 || . "$dir/fm-qualification-lib.sh"
  local maker_binding checker_binding
  maker_binding=$(_rp_role_field "$req" maker 1)
  checker_binding=$(_rp_role_field "$req" checker 1)
  for r in $declared_roles; do
    binding=$(_rp_role_field "$req" "$r" 1)
    resource=$(_rp_role_field "$req" "$r" 2-)
    contracts=$(_rp_role_contracts "$req" "$r")
    qual=NOT_APPLICABLE
    reason='no capability contract is declared for this role, so it carries no qualification requirement'
    if [ -n "$contracts" ] && [ -n "$binding" ]; then
      qual=QUALIFIED
      reason='every declared contract is currently recorded QUALIFIED for this binding'
      while IFS= read -r contract; do
        [ -n "$contract" ] || continue
        state=$(fm_qualification_state "$contract" "$binding" 2>/dev/null) || state=''
        st=$(printf '%s' "$state" | jq -r '.state // "COULD_NOT_OBSERVE"' 2>/dev/null) || st=COULD_NOT_OBSERVE
        [ -n "$st" ] || st=COULD_NOT_OBSERVE
        case "$st" in
          QUALIFIED) ;;
          COULD_NOT_OBSERVE)
            # Property-local FAIL > CNO > PASS: an unreadable requirement never
            # overwrites an already-established failure on the same role.
            [ "$qual" = NOT_QUALIFIED ] || qual=CNO
            reason="contract $contract could not be observed for $binding: $(printf '%s' "$state" | jq -r '.reason // "no reason recorded"' 2>/dev/null)"
            ;;
          *)
            qual=NOT_QUALIFIED
            reason="contract $contract is $st for $binding: $(printf '%s' "$state" | jq -r '.reason // "no reason recorded"' 2>/dev/null)"
            ;;
        esac
      done <<EOF
$contracts
EOF
      case "$qual" in
        NOT_QUALIFIED) _rp_fail ROLE_PATH_NOT_PERMITTED "role $r may not take this assignment: $reason" ;;
        CNO) _rp_cno ROLE_QUALIFICATION_UNOBSERVED "role $r declares a capability contract that could not be read: $reason" ;;
      esac
    fi
    roles_json="$roles_json{\"role\":\"$(_rp_json_escape "$r")\",\"binding\":\"$(_rp_json_escape "$binding")\",\"resource_path\":\"$(_rp_json_escape "$resource")\",\"qualification\":\"$qual\",\"qualification_reason\":\"$(_rp_json_escape "$reason")\",\"assignment_identity\":\"$(_rp_json_escape "$binding@$resource")\"},"
  done

  # The independence the register already owns, for the one pair whose collapse
  # this preflight is about. Asked only when both halves are named and carry a
  # contract, because the refusal it produces is a qualification refusal and an
  # undeclared requirement has none to give.
  if [ -n "$maker_binding" ] && [ -n "$checker_binding" ]; then
    local checker_contracts
    checker_contracts=$(_rp_role_contracts "$req" checker)
    if [ -n "$checker_contracts" ]; then
      local refusal
      # shellcheck disable=SC2046
      if ! refusal=$(fm_qualification_reviewer_refusal "$maker_binding" "$checker_binding" $(printf '%s' "$checker_contracts" | tr '\n' ' ') 2>/dev/null); then
        case "$refusal" in
          *COULD_NOT_OBSERVE*) _rp_cno ROLE_QUALIFICATION_UNOBSERVED "the checker's independence from the maker could not be established: $refusal" ;;
          *SELF_REVIEW*)       _rp_fail ASSIGNMENT_NOT_DISTINCT "the checker does not independently review the maker's mutation: $refusal" ;;
          *)                   _rp_fail ROLE_PATH_NOT_PERMITTED "the checker may not take this assignment: $refusal" ;;
        esac
      fi
    fi
  fi

  # --- 6. candidate generation --------------------------------------------
  # A product computed for one candidate must not be spent on another. An
  # absent candidate head is the ordinary shape of work not yet cut and is
  # recorded as such; a STATED head that no longer matches the branch is the
  # generation having moved underneath this decision.
  local observed_head='not-yet-created'
  if [ -n "$repository" ] && [ -d "$repository" ] && [ -n "$branch" ]; then
    observed_head=$(git -C "$repository" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null) || observed_head=''
    [ -n "$observed_head" ] || observed_head='not-yet-created'
  fi
  if [ -n "$candidate_head" ]; then
    if [ "$observed_head" = 'not-yet-created' ]; then
      _rp_fail STALE_CANDIDATE_GENERATION \
        "this product claims candidate head $candidate_head but branch $branch resolves to no commit in $repository, so the generation it was computed for is gone"
    elif [ "$observed_head" != "$candidate_head" ]; then
      _rp_fail STALE_CANDIDATE_GENERATION \
        "this product claims candidate head $candidate_head but branch $branch is now at $observed_head, so the candidate moved under the generation this decision was computed for"
    fi
  fi

  # --- 7. execution generation --------------------------------------------
  # The lane's own producer identity, from the owner that records it. An open
  # execution the dispatch does not claim is a lane already under way, and
  # launching a second producer onto it is what execution lineage exists to stop.
  local exec_line exec_id exec_dispatch
  exec_id=''
  exec_dispatch=''
  if [ -n "$task" ] && [ -x "$dir/fm-attempt.sh" ]; then
    if exec_line=$("$dir/fm-attempt.sh" execution "$task" 2>/dev/null); then
      exec_id=$(printf '%s' "$exec_line" | sed -n 's/.*execution_id=\([^ ]*\).*/\1/p')
      exec_dispatch=$(printf '%s' "$exec_line" | sed -n 's/.*execution_dispatch=\([^ ]*\).*/\1/p')
    else
      _rp_cno EXECUTION_UNOBSERVED \
        "bin/fm-attempt.sh could not report $task's execution lineage, so which producer currently holds this lane is unestablished"
    fi
  fi
  # A lane's OWN open execution is not a rival claim on the candidate - it IS
  # that lane. A relaunch after a lost runtime re-enters it and continues the
  # attempt already open, which bin/fm-attempt.sh owns and never refuses, so
  # counting it as a competing owner here would make every restart look like a
  # collision. What this axis establishes is narrower: a dispatch claiming to
  # succeed an execution the lane does not actually hold.
  case "$exec_dispatch" in
    launching|active|adopted)
      if [ -n "$succeeds" ] && [ "$succeeds" != "$exec_id" ]; then
        _rp_fail STALE_EXECUTION \
          "this dispatch claims to succeed execution $succeeds but $task's open execution is $exec_id; only the execution a gate sanctioned may be succeeded"
      fi
      ;;
  esac
  if [ -n "$succeeds" ] && [ -z "$exec_id" ]; then
    _rp_fail STALE_EXECUTION \
      "this dispatch claims to succeed execution $succeeds but $task records no execution lineage at all, so there is nothing it could be succeeding"
  fi

  # --- 8. worktree custody -------------------------------------------------
  # Asked of the guard that already publishes it, never re-derived. An absent
  # worktree input is the ordinary shape of work whose slot is not allocated
  # yet - nothing claims it, which is a real answer. A STATED worktree that
  # cannot be read is not that answer.
  local wt_state='none' wt_owner='none' wt_line
  if [ -n "$worktree" ]; then
    if wt_line=$("$dir/fm-worktree-guard.sh" owner-state "$worktree" 2>/dev/null); then
      wt_state=${wt_line%%$'\t'*}
      wt_owner=${wt_line#*$'\t'}
      wt_owner=${wt_owner%%$'\t'*}
      case "$wt_state" in
        alive)
          # Whose it is settles before what state it is in: a slot another lane
          # holds is never this dispatch's to take, whatever else is true.
          if [ -n "$task" ] && [ "$wt_owner" = "$task" ] && [ -n "$succeeds" ]; then
            : # the lane keeping its own slot across a sanctioned replacement
          else
            _rp_owner worktree "$wt_owner"
          fi
          ;;
        dead) ;;
        unclaimed)
          _rp_cno TREEHOUSE_CUSTODY_AMBIGUOUS \
            "no task record claims $worktree, so who owns that slot is not established and a dispatch cannot be told it may take it" ;;
        unresolved)
          _rp_cno TREEHOUSE_CUSTODY_AMBIGUOUS \
            "$worktree is claimed by ${wt_owner:-an unrecorded owner} but no owner process identity was ever recorded, so whether anything still holds an effect there could not be established" ;;
        *)
          _rp_cno TREEHOUSE_CUSTODY_AMBIGUOUS \
            "bin/fm-worktree-guard.sh reported $worktree as '$wt_state', which this preflight has no rule for" ;;
      esac
      if [ "$wt_state" != unclaimed ] && [ -n "$task" ] && [ -n "$wt_owner" ] \
         && [ "$wt_owner" != none ] && [ "$wt_owner" != "$task" ]; then
        _rp_fail DUPLICATE_MUTATION_OWNER \
          "$worktree is held by $wt_owner, not $task; no lane is ever taken from another"
      fi
    else
      wt_state=unreadable
      wt_owner=''
      _rp_cno WORKTREE_UNOBSERVED \
        "bin/fm-worktree-guard.sh could not report who owns $worktree, so custody of this candidate's slot is unobserved and nothing may be allocated against it"
    fi
  fi

  # --- 9. the complete no-mistakes census ----------------------------------
  # A run that owns the candidate is a PARTICIPANT holding mutation, and the
  # only honest way to know none does is to cover the whole population. A
  # census that could not be covered is could-not-observe, never "no run found".
  # shellcheck source=bin/fm-nm-run-lib.sh
  declare -F fm_nm_census >/dev/null 2>&1 || . "$dir/fm-nm-run-lib.sh"
  local census='' census_digest='not-applicable' census_rc=0 nm_run='not-applicable'
  local nm_applicable
  nm_applicable=$(_rp_get "$req" nm_applicable)
  if [ "$nm_applicable" != yes ]; then
    # No-mistakes owns mutation only where this work's delivery actually routes
    # through it. Reading a census for a candidate the pipeline never touches
    # would refuse every project that does not run it, on the strength of a
    # question that does not apply to that project.
    census_digest='not-applicable'
    nm_run='not-applicable'
  elif [ -n "$repository" ] && [ -d "$repository" ] && command -v no-mistakes >/dev/null 2>&1; then
    nm_run='none'
    census=$(fm_nm_census "$repository" "$FM_ROLE_PATH_CENSUS_TIMEOUT" "$FM_ROLE_PATH_CENSUS_LIMIT") || census_rc=$?
    if [ "$census_rc" -eq 3 ]; then
      # An ESTABLISHED absence, not an unread population: this repository runs no
      # pipeline, so no pipeline run can hold this candidate. Recorded under its
      # own name so nothing reads it as a census that was taken and came back
      # empty - and so a delivery that expects the pipeline still shows that the
      # repository does not currently have one.
      census_digest='not-initialized'
      nm_run='not-initialized'
      census=''
    elif [ "$census_rc" -ne 0 ]; then
      # Applicable and UNREAD. Recorded as unobserved rather than left on the
      # not-applicable initializer, which would credit a census nobody could
      # take with a question that did not apply.
      census_digest='unobserved'
      nm_run='unobserved'
      _rp_cno NM_CENSUS_INCOMPLETE \
        "the no-mistakes run population could not be covered, so whether a run owns this candidate is unobserved: $census"
      census=''
    else
      census_digest=$(fm_nm_census_digest "$census")
      local c_status c_branch c_head
      while IFS=$'\t' read -r c_status c_branch c_head; do
        [ -n "$c_status" ] || continue
        [ "$c_branch" = "$branch" ] || continue
        fm_nm_census_terminal "$c_status" && continue
        nm_run="$c_status@$c_head"
        _rp_owner no-mistakes "$nm_run"
      done <<EOF
$census
EOF
    fi
  else
    _rp_cno NM_CENSUS_INCOMPLETE \
      "this work's delivery routes through no-mistakes and no-mistakes could not be reached in $repository, so whether a run owns this candidate could not be observed at all"
    census_digest='unobserved'
    nm_run='unobserved'
  fi

  # --- 10. the singular mutation owner -------------------------------------
  # One collection, two questions: how many live owners there are, and which one
  # names the refusal. A dispatch may allocate only into an EMPTY set, because
  # the thing it is asking for is to become that set's single member.
  owner_count=$(printf '%s' "$_RP_OWNERS" | grep -c . || true)
  if [ "$owner_count" -gt 1 ]; then
    _rp_fail DUPLICATE_MUTATION_OWNER \
      "more than one live owner holds this candidate ($(printf '%s' "$_RP_OWNERS" | tr '\n' ' ' | sed 's/ $//')), so no single identity may be given the right to mutate it"
  elif [ "$owner_count" -eq 1 ]; then
    owner_line=$(printf '%s' "$_RP_OWNERS" | grep . | head -1)
    owner_kind=${owner_line%%:*}
    case "$owner_kind" in
      no-mistakes)
        _rp_fail PARTICIPANT_OWNS_MUTATION \
          "a live no-mistakes run ($owner_line) owns branch $branch, so the pipeline holds mutation of this candidate and firstmate must leave it alone rather than allocate against it" ;;
      *)
        _rp_fail DUPLICATE_MUTATION_OWNER \
          "$owner_line already holds mutation of this candidate, so this dispatch cannot become its single owner" ;;
    esac
  fi

  # The mutation owner this product settles on. On PERMITTED it is the identity
  # the caller is authorized to become; on any refusal it is whoever already is.
  if [ "$FM_ROLE_PATH_VERDICT" = PERMITTED ]; then
    FM_ROLE_PATH_MUTATION_OWNER="${succeeds:-${task:-$work}}"
    FM_ROLE_PATH_RESERVATION="$work/${task:-unassigned}/${candidate_head:-not-yet-created}"
  else
    FM_ROLE_PATH_MUTATION_OWNER=$(printf '%s' "$_RP_OWNERS" | grep . | head -1)
    FM_ROLE_PATH_RESERVATION=''
  fi

  # --- the product ---------------------------------------------------------
  # One record, so prose and JSON can never disagree, and so a decision can be
  # shown to have been made against THIS generation rather than a later one.
  local qual_generation route_digest
  qual_generation=$(fm_nm_census_digest "$roles_json") || qual_generation=unobserved
  route_digest='unobserved'
  local config_dir
  config_dir=$(_rp_get "$req" config)
  if [ -n "$route" ] && [ -n "$config_dir" ] && declare -F fm_route_policy_digest >/dev/null 2>&1; then
    route_digest=$(fm_route_policy_digest "$config_dir" 2>/dev/null) || route_digest=unobserved
  fi
  [ -n "$route_digest" ] || route_digest=unobserved

  custody_json="{\"firstmate_execution\":\"$(_rp_json_escape "${exec_id:-none}")\",\"no_mistakes_run\":\"$(_rp_json_escape "$nm_run")\",\"worktree_owner\":\"$(_rp_json_escape "${wt_owner:-none}")\",\"worktree_state\":\"$(_rp_json_escape "$wt_state")\",\"treehouse_slot\":\"$(_rp_json_escape "${slot:-none}")\",\"mutation_owner\":\"$(_rp_json_escape "${FM_ROLE_PATH_MUTATION_OWNER:-none}")\",\"live_owner_count\":$owner_count}"

  FM_ROLE_PATH_PRODUCT=$(cat <<JSON
{"schema":"$FM_ROLE_PATH_SCHEMA",
 "verdict":"$FM_ROLE_PATH_VERDICT",
 "reason_code":"$FM_ROLE_PATH_REASON_CODE",
 "reason":"$(_rp_json_escape "$FM_ROLE_PATH_REASON")",
 "generation":{"route_policy_digest":"$(_rp_json_escape "$route_digest")",
   "qualification_generation":"$(_rp_json_escape "$qual_generation")",
   "task_execution_id":"$(_rp_json_escape "${exec_id:-none}")",
   "candidate_head":"$(_rp_json_escape "${candidate_head:-not-yet-created}")",
   "no_mistakes_census_digest":"$(_rp_json_escape "$census_digest")"},
 "work":{"semantic_work_id":"$(_rp_json_escape "$work")",
   "repository":"$(_rp_json_escape "$repository")",
   "contribution_venue":"$(_rp_json_escape "${venue:-unresolved}")",
   "base":"$(_rp_json_escape "$base")",
   "branch":"$(_rp_json_escape "$branch")",
   "candidate_head":"$(_rp_json_escape "${candidate_head:-not-yet-created}")",
   "observed_head":"$(_rp_json_escape "$observed_head")",
   "delivery_mode":"$(_rp_json_escape "${mode:-unstated}")"},
 "required_roles":[$(printf '%s' "$required_roles" | awk '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i>1?",":""), $i}')],
 "role_path":[${roles_json%,}],
 "custody":$custody_json,
 "reservation":$( [ -n "$FM_ROLE_PATH_RESERVATION" ] && printf '"%s"' "$(_rp_json_escape "$FM_ROLE_PATH_RESERVATION")" || printf 'null' )}
JSON
)
  # Normalize through jq where it is available, so consumers get one shape. A
  # host without jq still gets the record; it is the same bytes, just unpretty.
  if command -v jq >/dev/null 2>&1; then
    local normalized
    if normalized=$(printf '%s' "$FM_ROLE_PATH_PRODUCT" | jq -c '.' 2>/dev/null); then
      FM_ROLE_PATH_PRODUCT=$normalized
    fi
  fi

  case "$FM_ROLE_PATH_VERDICT" in
    PERMITTED) return "$FM_ROLE_PATH_EXIT_PERMITTED" ;;
    REFUSED)   return "$FM_ROLE_PATH_EXIT_REFUSED" ;;
    *)         return "$FM_ROLE_PATH_EXIT_CNO" ;;
  esac
}
