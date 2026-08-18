#!/usr/bin/env bash
# fm-review-envelope-lib.sh - the single owner of the review-envelope/v1
# contract: what an envelope binds, where each fact comes from, how the bytes
# are canonicalized and digested, and how a stored envelope is classified.
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-review-envelope-lib.sh
#   . "$SCRIPT_DIR/fm-review-envelope-lib.sh"
#
# WHAT AN ENVELOPE IS FOR
#
# One review decision needs one immutable statement of what is being reviewed
# and what has already been proven about it. Four distinct defects in a single
# day came from that statement living in prose instead:
#
#   - a green computed against a base far behind the trunk;
#   - recorded evidence citing a head that had since moved;
#   - a validation transcript whose own `git rev-parse HEAD` showed a
#     pre-rebase commit while claiming to prove the successor;
#   - a generic CI run cited as evidence for an acceptance dimension its gate
#     never invoked.
#
# Every one was caught by a human noticing. An envelope exists so that catching
# them is arithmetic: the facts are derived from the repository rather than
# retyped, they are bound together under one digest, and the classifier refuses
# any combination that contradicts readiness.
#
# THE OWNERSHIP BOUNDARY, WHICH IS THE WHOLE REASON THIS IS REUSABLE
#
# A project owns its verification contracts and its executable verifier truth.
# The control plane owns envelope compilation, classification and transport.
# So an envelope carries proof state BY STABLE IDENTITY AND DIGEST and never by
# layout: no project path convention, no registry file format, no repository's
# internal directory names reach this contract. Point it at a second project
# and nothing here has to change.
#
# That boundary is expressed in the schema itself. Every field carries a
# `source`, and there are exactly three:
#
#   derived    this compiler observed it in the repository. It is never read
#              from the inputs, and where the inputs assert it anyway the
#              assertion is checked and a mismatch is a refusal.
#   declared   the project stated it. Identities, digests, patterns, policy
#              bounds, candidate sets and results - things a repository cannot
#              observe about itself.
#   computed   this compiler derived it from the two above, in code, with no
#              agent judgement in the path. Required-contract selection is the
#              load-bearing case: which contracts apply is computed from the
#              observed changed files against declared rules, so an agent
#              cannot choose which required contract to omit.
#
# THE CLASSIFICATION IS NEVER STORED
#
# An envelope binds facts. It does not carry a verdict, and nothing writes one
# next to it. The readiness answer is derived on every read, from the bound
# facts plus a fresh look at the repository, because a stored verdict is a
# fact's substitute the moment the fact moves - which is exactly the staleness
# this artifact exists to catch. bin/fm-review-exec.sh applies the same law to
# its own execution records.
#
# Three values, never two, through bin/fm-verify-lib.sh's type:
#
#   REVIEW_READY       PASS             every required fact observed and good
#   REFUSED            FAIL             a bound fact contradicts readiness
#   COULD_NOT_OBSERVE  NO_VERIFIER_RAN  a required fact could not be observed
#
# REFUSED outranks COULD_NOT_OBSERVE, and that ordering differs deliberately
# from bin/fm-review-exec.sh, where an unobserved dimension outranks a clean
# exit. There, a missing dimension IS the contradiction of the claim "this
# review executed", so it has to win. Here the two are different categories: a
# refusal is a decided answer and stays decided however much else is learned,
# while could-not-observe is undecided and can still resolve either way.
# Reporting the answer that is stable under new information is the more useful
# of two equally non-passing results. Both lists are always emitted in full, so
# nothing is hidden by the ordering.
#
# CANONICAL FORM AND CONTENT ADDRESS
#
# The digest covers the canonical serialization of the envelope body alone:
# UTF-8, object keys sorted recursively, no insignificant whitespace, no
# trailing newline. Arrays whose order is not semantic are sorted by the
# compiler before they are bound, so the same facts always produce the same
# bytes.
#
# NOTHING TIME-VARYING IS INSIDE THE DIGESTED BODY. When the facts have not
# moved, recompiling produces the identical digest, which is what lets repeated
# scheduler wakes, retries and restart recovery resolve to one logical review
# request instead of manufacturing a new one each time. The compile timestamp
# lives beside the digest in the outer document, never inside the body.
#
# The digest is recomputed on every read; a body whose recomputed digest
# disagrees with the stored one is a refusal, not a fact.
#
# THE INPUTS DOCUMENT
#
# One `review-envelope-inputs/v1` JSON document supplies everything declared.
# `fm-review-envelope.sh schema` prints the field catalog and
# docs/contracts/review-envelope.md is generated from it, so there is one
# machine-readable owner and no second hand-written catalog to drift against.
#
# CODE-OWNED EXECUTABLE RESOLUTION
#
# A required executable is declared as a COMPLETE candidate set, never a single
# name. Every candidate is evaluated in declared order; the first that both
# resolves and yields a directly observed identity is selected, and its path
# and identity output are bound. Could-not-observe is reached only after the
# declared candidates are exhausted, and every probe outcome is recorded so the
# exhaustion is inspectable. A capability declared absent because one alias of
# a two-alias resolver was tried by hand is the failure this rule replaces.
#
# A candidate that resolves but will not state its identity is not a selection.
# Resolution continues to the next candidate, because "something with that name
# exists" is not the observation the contract asks for.
#
# MONOTONIC OBLIGATION PRESERVATION
#
# A successor envelope must account for every obligation its predecessor left
# active. Each prior obligation is classified PRESERVED, SATISFIED with named
# evidence that resolves and digests, RESOLVED with an explicit authority and
# reason, or SUPERSEDED by a named replacement that is itself active in the
# successor. An obligation that simply stops appearing is observed-bad and
# blocks advancement.
#
# The predecessor link is DECLARED, not inferred from whether a caller
# remembered a flag. An inputs document with no predecessor block at all is
# could-not-observe, so the failure mode where a successor silently starts a
# fresh chain - and every prior obligation evaporates with it - cannot happen
# by omission.
#
# RELATIONSHIP TO THE LIVE MERGE GUARD
#
# bin/fm-pr-merge.sh reduces live GitHub check runs for a merge decision and
# owns that reduction against the forge's own vocabulary. This library reduces
# already-normalized, forge-neutral check attempts for a review decision at an
# exact head. The reduction LAW is the same one - attempts are keyed by owning
# workflow plus check name so two workflows sharing a job name stay two checks,
# the current attempt is the one with the highest monotonic order, a tie is
# decided by the worst verdict, and a multi-attempt group with no usable
# ordering is undecidable rather than resolved. They are kept separate because
# a review envelope must classify a project's checks without assuming GitHub,
# and because rewriting a merge guard is not this contract's to do. Change one
# and read the other.

# fm_review_envelope_python <argv...> - run the compiler and classifier.
# Every entry point goes through here, so there is one program and one place
# where the contract is expressed.
fm_review_envelope_python() {
  python3 - "$@" <<'PY'
import argparse
import fnmatch
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

SCHEMA = "review-envelope/v1"
INPUTS_SCHEMA = "review-envelope-inputs/v1"
CLASSIFICATION_SCHEMA = "review-envelope-classification/v1"
CANONICALIZATION = "json-sorted-compact-utf8-v1"

# The evidence-handle synchronization seam. Both halves of its handshake are
# bounded by one number, and tests/fm-review-envelope.test.sh reads that number
# out of this file rather than carrying a second copy of it that could drift.
SEAM_DIRECTORY = "fm-review-envelope-seam"
SEAM_DEADLINE_SECONDS = 5

# A check attempt that reached an adverse verdict. A workflow that failed to
# start never clears by waiting, so it is a verdict rather than a silence.
ADVERSE_CONCLUSIONS = ("FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE")

# Ranked worst-first, so a tie between attempts at the same order can never
# manufacture a pass.
VERDICT_RANK = ("UNDECIDABLE", "FAILING", "NO_VERDICT", "SKIPPED", "PENDING", "SUCCESS")

DISPOSITIONS = ("PRESERVED", "SATISFIED", "RESOLVED", "SUPERSEDED")


class Unobservable(Exception):
    """A structural failure that stops compilation before any fact is bound."""

    def __init__(self, code, detail, subject=""):
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.subject = subject


def canonical_bytes(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")


def digest_of(value):
    return "sha256:" + hashlib.sha256(canonical_bytes(value)).hexdigest()


def sorted_records(records, identity_fields, label):
    for record in records:
        if not isinstance(record, dict):
            raise Unobservable("inputs_malformed", label + " contains a non-object")
    return sorted(
        records,
        key=lambda record: (
            tuple(str(record.get(field, "")) for field in identity_fields),
            canonical_bytes(record),
        ),
    )


def canonicalize_applicability_rules(rules):
    canonical = []
    for rule in rules:
        if not isinstance(rule, dict):
            raise Unobservable("inputs_malformed", "an applicability rule must be an object")
        record = dict(rule)
        if "paths" in record:
            record["paths"] = sorted_records(
                as_list(record, "paths"),
                ("type", "value"),
                "verification applicability paths",
            )
        canonical.append(record)
    return sorted_records(
        canonical,
        ("contract_id",),
        "verification applicability rules",
    )


def canonicalize_contracts(contracts):
    canonical = []
    for contract in contracts:
        if not isinstance(contract, dict):
            raise Unobservable("inputs_malformed", "verification contracts contains a non-object")
        record = dict(contract)
        if "execution_worlds" in record:
            record["execution_worlds"] = sorted(
                as_list(record, "execution_worlds"), key=canonical_bytes
            )
        canonical.append(record)
    return sorted_records(
        canonical,
        ("id", "version", "digest"),
        "verification contracts",
    )


def digest_handle(handle):
    hasher = hashlib.sha256()
    for chunk in iter(lambda: handle.read(65536), b""):
        hasher.update(chunk)
    return "sha256:" + hasher.hexdigest()


def digest_file(path):
    with open(path, "rb") as handle:
        return digest_handle(handle)


def seam_root():
    """The one directory this library will let the synchronization seam use.

    The seam is a measurement affordance, so the only thing an ambient
    environment variable may choose about it is a name STRICTLY INSIDE a
    directory this code owns. Anything else - including the directory itself,
    whose signal files would be siblings of it rather than entries in it - is
    refused rather than followed. The directory's own parent is whatever the
    process's temporary directory is, which is the ordinary contract every
    program on the machine already honours.
    """
    return os.path.realpath(os.path.join(tempfile.gettempdir(), SEAM_DIRECTORY))


def seam_prefix():
    configured = os.environ.get("FM_REVIEW_ENVELOPE_TEST_OPENED_SEAM")
    if not configured:
        return None
    root = seam_root()
    resolved = os.path.realpath(configured)
    if not resolved.startswith(root + os.sep):
        raise Unobservable(
            "evidence_seam_unusable",
            "the evidence synchronization seam is confined to names inside " + root,
            str(configured),
        )
    return resolved


def seam_signal(prefix, suffix):
    try:
        os.makedirs(os.path.dirname(prefix), exist_ok=True)
        with open(prefix + suffix, "x", encoding="utf-8") as handle:
            handle.write(suffix.lstrip(".") + "\n")
    except OSError as error:
        raise Unobservable(
            "evidence_seam_unusable",
            "the evidence synchronization seam could not signal " + suffix + ": " + str(error),
            prefix,
        )


def seam_await(prefix, suffix):
    deadline = time.monotonic() + SEAM_DEADLINE_SECONDS
    while not os.path.exists(prefix + suffix):
        if time.monotonic() >= deadline:
            raise Unobservable(
                "evidence_seam_unusable",
                "the evidence synchronization seam did not reach "
                + suffix.lstrip(".")
                + " within "
                + str(SEAM_DEADLINE_SECONDS)
                + "s",
                prefix,
            )
        time.sleep(0.01)


def digest_evidence_handle(handle, locator):
    """Digest an already-open evidence handle.

    The seam below lets a control repoint a name after this handle opens, which
    is the only way to observe that the bytes bound are the opened handle's
    rather than the pathname's. It is confined to seam_root(), bounded by
    SEAM_DEADLINE_SECONDS, and every way it can refuse is a classified
    could-not-observe, because a seam that answers with a traceback where the
    contract promises a three-valued classification is a hole rather than a
    seam.
    """
    prefix = seam_prefix()
    test_locator = os.environ.get("FM_REVIEW_ENVELOPE_TEST_OPENED_LOCATOR")
    if not prefix or locator != test_locator or os.path.exists(prefix + ".hashed"):
        return digest_handle(handle)
    seam_signal(prefix, ".opened")
    seam_await(prefix, ".continue")
    observed = digest_handle(handle)
    seam_signal(prefix, ".hashed")
    seam_await(prefix, ".restored")
    return observed


def now_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- the field catalog, from which the human contract is generated ----------

CATALOG = {
    "schema": SCHEMA,
    "inputs_schema": INPUTS_SCHEMA,
    "classification_schema": CLASSIFICATION_SCHEMA,
    "canonicalization": CANONICALIZATION,
    "summary": (
        "An immutable, content-addressed statement of one review candidate: "
        "what it is, what is in and out of scope, what has been proven about "
        "it, and what remains owed."
    ),
    "digest_scope": [
        "The body and outer integrity digests detect partial edits and drift, and provide content-addressed provenance aids.",
        "They do not establish signer identity and do not resist a whole-artifact rewrite with recomputed digests.",
    ],
    "sources": [
        {
            "name": "derived",
            "description": "Observed in the repository by the compiler and never read from the inputs.",
        },
        {
            "name": "declared",
            "description": "Stated by the project, because a repository cannot observe it about itself.",
        },
        {
            "name": "computed",
            "description": "Derived in code from observed and declared facts, with no agent judgement in the path.",
        },
    ],
    "sections": [
        {
            "name": "identity",
            "description": "Who is asking for what, under which policy.",
            "fields": [
                {"name": "project.id", "source": "declared", "required": True,
                 "description": "The project's stable identifier, opaque to this contract."},
                {"name": "project.root_commits", "source": "derived", "required": True,
                 "description": "The repository's root commits, a layout-free repository identity."},
                {"name": "project.origin_url", "source": "derived", "required": False,
                 "description": "The configured origin remote, recorded when one exists."},
                {"name": "work.id", "source": "declared", "required": True,
                 "description": "The work item this candidate belongs to."},
                {"name": "work.increment", "source": "declared", "required": False,
                 "description": "The increment within that work item."},
                {"name": "work.request", "source": "declared", "required": True,
                 "description": "The forge request this candidate is carried by, as kind, forge, id and url."},
                {"name": "policy.version", "source": "declared", "required": True,
                 "description": "The review-policy version this envelope was compiled under."},
                {"name": "policy.max_base_behind_main", "source": "declared", "required": True,
                 "description": "How far the base may trail the trunk before the envelope refuses."},
                {"name": "requested_decision", "source": "declared", "required": True,
                 "description": "The decision this envelope asks for, as an uppercase token."},
                {"name": "outer request_identity", "source": "computed", "required": True,
                 "description": "A derived identity beside the body digest, binding repository, work or forge request, exact head, envelope digest and policy version."},
                {"name": "outer declared_request_identity", "source": "declared", "required": True,
                 "description": "The request identity claimed by the inputs, or explicit null when none was claimed, preserved so every validation can distinguish absence and recheck a value."},
                {"name": "outer outer_digest", "source": "computed", "required": True,
                 "description": "An integrity digest over compile time, compiler, body digest value, computed request identity and declared request identity."},
            ],
        },
        {
            "name": "candidate",
            "description": "The exact bytes under review.",
            "fields": [
                {"name": "base_ref", "source": "declared", "required": True,
                 "description": "The reference the contribution is measured from."},
                {"name": "base_commit", "source": "derived", "required": True,
                 "description": "The commit that reference resolved to at compile time."},
                {"name": "head_ref", "source": "declared", "required": True,
                 "description": "The reference naming the candidate."},
                {"name": "head_commit", "source": "derived", "required": True,
                 "description": "The exact candidate commit."},
                {"name": "head_tree", "source": "derived", "required": True,
                 "description": "The exact candidate tree, which is the content identity a verifier result must bind to."},
                {"name": "merge_base", "source": "derived", "required": True,
                 "description": "The merge base of base and head, from which the contribution is measured."},
                {"name": "diff_digest", "source": "computed", "required": True,
                 "description": "A digest over the canonical changed-file table, stable across git versions because it names blobs rather than rendered patch text."},
                {"name": "changed_files", "source": "derived", "required": True,
                 "description": "Every changed path with its status, pre-image and post-image blob, and scope classification."},
                {"name": "declared_head_commit", "source": "declared", "required": False,
                 "description": "An optional assertion about the head, checked against the repository and refused on mismatch."},
            ],
        },
        {
            "name": "scope",
            "description": "What this review covers, and what it explicitly does not.",
            "fields": [
                {"name": "excluded", "source": "declared", "required": False,
                 "description": "Exclusion rules, each with an id, a match type of exact, prefix or glob, a value and a reason."},
                {"name": "in_scope_paths", "source": "computed", "required": True,
                 "description": "Changed paths no exclusion rule matched."},
                {"name": "excluded_paths", "source": "computed", "required": True,
                 "description": "Changed paths an exclusion rule matched, each naming the rule that matched it."},
                {"name": "unused_exclusions", "source": "computed", "required": True,
                 "description": "Declared exclusions that matched nothing in this contribution."},
            ],
        },
        {
            "name": "applicability",
            "description": "Where the candidate stands against the current trunk.",
            "fields": [
                {"name": "main_ref", "source": "declared", "required": True,
                 "description": "The trunk reference applicability is measured against."},
                {"name": "main_commit", "source": "derived", "required": True,
                 "description": "The commit that trunk reference resolved to."},
                {"name": "base_is_ancestor_of_main", "source": "derived", "required": True,
                 "description": "Whether the base is on the trunk's line at all."},
                {"name": "base_behind_main", "source": "derived", "required": True,
                 "description": "How many trunk commits the base trails by."},
                {"name": "base_is_ancestor_of_head", "source": "derived", "required": True,
                 "description": "Whether the contribution is measured from a base the candidate actually descends from."},
                {"name": "head_is_ancestor_of_main", "source": "derived", "required": True,
                 "description": "Whether the candidate has already landed."},
            ],
        },
        {
            "name": "verification",
            "description": "Verification contracts by identity and digest, and their exact-head results.",
            "fields": [
                {"name": "applicability_rules", "source": "declared", "required": True,
                 "description": "Either non-empty rules mapping changed paths to required contract ids, including a mandatory rule, or an explicit none with a reason; absence or an empty list is could-not-observe."},
                {"name": "required_contract_ids", "source": "computed", "required": True,
                 "description": "The contracts this candidate must satisfy, computed from the observed changed files against those rules."},
                {"name": "contracts", "source": "declared", "required": True,
                 "description": "Contract references by id, version and digest, plus their declared execution worlds."},
                {"name": "results", "source": "declared", "required": True,
                 "description": "One result per contract and world, each binding its contract id and digest, verifier id and digest, the head it ran against, its evidence locator and digest, and its red calibration."},
            ],
        },
        {
            "name": "capabilities",
            "description": "Executables a verifier needs, resolved by code over a complete candidate set.",
            "fields": [
                {"name": "id", "source": "declared", "required": True,
                 "description": "The capability's stable identifier."},
                {"name": "candidates", "source": "declared", "required": True,
                 "description": "The complete acceptable candidate set, in evaluation order; a bare name or an absolute path."},
                {"name": "identity_argv", "source": "declared", "required": True,
                 "description": "The arguments that make a candidate state its own identity."},
                {"name": "probes", "source": "derived", "required": True,
                 "description": "One outcome per candidate evaluated, so an exhausted set is inspectable rather than asserted."},
                {"name": "selected", "source": "derived", "required": False,
                 "description": "The selected candidate's resolved path and its directly observed identity output."},
                {"name": "candidates_exhausted", "source": "computed", "required": True,
                 "description": "Whether resolution ran out of declared candidates, which is the only route to could-not-observe."},
            ],
        },
        {
            "name": "ci",
            "description": "Continuous integration attempts, associated with the exact candidate head.",
            "fields": [
                {"name": "required_platforms", "source": "declared", "required": True,
                 "description": "Platforms that must carry a successful exact-head check."},
                {"name": "attempts", "source": "declared", "required": True,
                 "description": "Normalized attempts, each with a head, an owning workflow, a name, a monotonic order and a conclusion."},
                {"name": "checks", "source": "computed", "required": True,
                 "description": "Exact-head attempts reduced to one current verdict per check."},
                {"name": "wrong_head_attempts", "source": "computed", "required": True,
                 "description": "Attempts whose head is not the candidate head, kept visible rather than dropped."},
                {"name": "head_unknown_attempts", "source": "computed", "required": True,
                 "description": "Attempts that named no head at all, which can prove nothing about this candidate."},
            ],
        },
        {
            "name": "findings",
            "description": "What is already known to be wrong, and what is known to be unproven.",
            "fields": [
                {"name": "adverse", "source": "declared", "required": True,
                 "description": "Known adverse findings; a blocking one refuses."},
                {"name": "unproven", "source": "declared", "required": True,
                 "description": "Known could-not-observe dimensions; a required one cannot reach review-ready."},
            ],
        },
        {
            "name": "rulings",
            "description": "Prior rulings and whether they apply to this exact candidate.",
            "fields": [
                {"name": "id", "source": "declared", "required": True,
                 "description": "The ruling's identity in its own authority's namespace."},
                {"name": "applies_to", "source": "declared", "required": False,
                 "description": "The facts the ruling was issued against, as any of work_id, head, tree or envelope_digest; envelope_digest is the canonical digest of this envelope with rulings empty, so the identity is current and non-circular."},
                {"name": "relied_upon", "source": "declared", "required": False,
                 "description": "Whether this envelope leans on the ruling; a relied-upon ruling that does not apply refuses."},
                {"name": "applicability_established", "source": "computed", "required": True,
                 "description": "Whether applies_to names at least one candidate-identifying axis: head, tree or envelope_digest."},
                {"name": "applicable", "source": "computed", "required": True,
                 "description": "Whether applicability is established and every supplied fact matches this candidate."},
            ],
        },
        {
            "name": "obligations",
            "description": "The complete active obligation set, and the accounting for its predecessor's.",
            "fields": [
                {"name": "predecessor", "source": "declared", "required": True,
                 "description": "Either the predecessor envelope's digest or an explicit none with a reason; absence is could-not-observe, never a fresh chain."},
                {"name": "predecessor_active", "source": "derived", "required": True,
                 "description": "The obligation ids the predecessor envelope left active, read from that envelope's own bytes."},
                {"name": "active", "source": "declared", "required": True,
                 "description": "Every obligation still owed after this candidate."},
                {"name": "dispositions", "source": "declared", "required": True,
                 "description": "One accounting per predecessor obligation: PRESERVED, SATISFIED, RESOLVED or SUPERSEDED."},
            ],
        },
    ],
    "refusals": [
        {"code": "candidate_head_moved", "meaning": "The candidate reference no longer resolves to the bound head."},
        {"code": "candidate_tree_moved", "meaning": "The bound head no longer carries the bound tree."},
        {"code": "base_moved", "meaning": "The base reference no longer resolves to the bound base."},
        {"code": "declared_head_mismatch", "meaning": "An input asserted a head or base the repository contradicts."},
        {"code": "requested_decision_invalid", "meaning": "The requested decision is present but is not an uppercase token."},
        {"code": "project_identity_mismatch", "meaning": "The declared repository identity is not this repository's."},
        {"code": "base_not_on_main_line", "meaning": "The base is not an ancestor of the trunk."},
        {"code": "base_behind_main_exceeds_policy", "meaning": "The base trails the trunk by more than policy allows."},
        {"code": "base_not_ancestor_of_candidate", "meaning": "The candidate does not descend from its own base."},
        {"code": "changed_file_set_empty", "meaning": "The contribution changes nothing."},
        {"code": "scope_fully_excluded", "meaning": "Every changed path is excluded, so nothing is under review."},
        {"code": "missing_required_verification_contract", "meaning": "A computed-required contract has no reference, or its reference carries no digest."},
        {"code": "verification_contract_id_ambiguous", "meaning": "More than one verification contract reference carries the same stable id."},
        {"code": "missing_required_verifier_result", "meaning": "A required contract has no result for a required world."},
        {"code": "verification_result_contract_mismatch", "meaning": "A verifier result does not bind the selected contract's exact digest."},
        {"code": "verifier_identity_unpinned", "meaning": "A required result names no verifier id and digest, so what ran is not identified."},
        {"code": "required_verifier_failed", "meaning": "A required verifier reached an adverse verdict."},
        {"code": "required_verifier_wrong_head", "meaning": "A required verifier result binds a head or tree that is not the candidate's."},
        {"code": "missing_red_calibration", "meaning": "A required passing verifier was never observed failing."},
        {"code": "red_calibration_not_adverse", "meaning": "A red calibration records something other than an observed failure."},
        {"code": "evidence_locator_broken", "meaning": "An evidence locator escapes its root, is absent, or is unreadable."},
        {"code": "evidence_digest_mismatch", "meaning": "Evidence bytes no longer match the digest bound to them."},
        {"code": "ci_required_platform_uncovered", "meaning": "A required platform has no exact-head check at all."},
        {"code": "ci_required_check_failing", "meaning": "A required platform's current check failed."},
        {"code": "ci_required_check_skipped", "meaning": "A required platform's current check was skipped."},
        {"code": "ci_required_check_no_verdict", "meaning": "A required platform's current check completed without earning a verdict."},
        {"code": "ci_wrong_head", "meaning": "A required platform is covered only by checks against another head."},
        {"code": "ci_duplicate_attempt_undecidable", "meaning": "Repeated attempts at one check cannot be ordered, so none is current."},
        {"code": "capability_candidate_malformed", "meaning": "A capability candidate is neither a bare name nor an absolute path."},
        {"code": "adverse_finding_blocking", "meaning": "A known adverse finding is marked blocking."},
        {"code": "ruling_id_absent", "meaning": "A ruling carries no non-blank stable id."},
        {"code": "ruling_id_ambiguous", "meaning": "More than one ruling carries the same stable id."},
        {"code": "ruling_applicability_mismatch", "meaning": "A ruling this envelope relies on does not apply to this candidate."},
        {"code": "ruling_applicability_unestablished_relied_upon", "meaning": "A ruling this envelope relies on names no candidate-identifying applicability axis."},
        {"code": "request_identity_mismatch", "meaning": "A declared or stored request identity does not match the identity recomputed from the bound facts."},
        {"code": "forge_request_identity_invalid", "meaning": "The authoritative forge request identity is absent or incomplete."},
        {"code": "obligation_dropped", "meaning": "A predecessor obligation is unaccounted for."},
        {"code": "obligation_preserved_but_absent", "meaning": "An obligation was called preserved and is not in the active set."},
        {"code": "obligation_satisfied_without_evidence", "meaning": "A satisfied obligation names no evidence that resolves and digests."},
        {"code": "obligation_resolved_without_authority", "meaning": "A resolved obligation names no authority and reason."},
        {"code": "obligation_superseded_without_replacement", "meaning": "A superseded obligation names no active replacement."},
        {"code": "obligation_disposition_unknown", "meaning": "A disposition names an obligation the predecessor never held."},
        {"code": "obligation_disposition_duplicate", "meaning": "More than one disposition names the same predecessor obligation."},
        {"code": "obligation_disposition_contradicts_active_set", "meaning": "An obligation is both discharged and still active."},
        {"code": "obligation_duplicate_id", "meaning": "One obligation id is missing or appears twice."},
        {"code": "predecessor_contradiction", "meaning": "A predecessor envelope was supplied against inputs that declare none."},
        {"code": "envelope_digest_mismatch", "meaning": "The stored body does not match its stored digest."},
        {"code": "outer_integrity_digest_mismatch", "meaning": "The stored outer facts do not match their integrity digest."},
    ],
    "unobserved": [
        {"code": "usage_error", "meaning": "The call itself was malformed, so nothing was compiled or classified."},
        {"code": "inputs_malformed", "meaning": "The inputs document is unreadable or violates its schema."},
        {"code": "policy_undeclared", "meaning": "No review policy bound was declared, so staleness cannot be judged."},
        {"code": "repository_unreadable", "meaning": "The repository could not be inspected."},
        {"code": "candidate_unresolvable", "meaning": "The candidate reference does not resolve."},
        {"code": "base_unresolvable", "meaning": "The base reference does not resolve."},
        {"code": "main_unresolvable", "meaning": "The trunk reference does not resolve."},
        {"code": "envelope_unreadable", "meaning": "The envelope document could not be read."},
        {"code": "envelope_exists", "meaning": "An envelope is written once, and the output already holds one."},
        {"code": "required_verifier_unproven", "meaning": "A required verifier returned could-not-observe, where a pass is required."},
        {"code": "capability_unresolved", "meaning": "Every declared candidate for a required executable was exhausted."},
        {"code": "ci_required_check_pending", "meaning": "A required platform's current check has not completed."},
        {"code": "unproven_dimension_required", "meaning": "A declared required dimension is known to be unproven."},
        {"code": "predecessor_undeclared", "meaning": "The inputs carry no predecessor block, so obligation continuity cannot be judged."},
        {"code": "predecessor_unreadable", "meaning": "The declared predecessor envelope could not be read, or does not match its own digest."},
        {"code": "verification_applicability_undeclared", "meaning": "The inputs carry neither non-empty verification applicability rules nor an explicit none with a reason, so required contracts cannot be judged."},
        {"code": "evidence_recheck_declined", "meaning": "Validation was told not to re-read the evidence bytes, and did not."},
        {"code": "evidence_seam_unusable", "meaning": "The evidence-handle synchronization seam was pointed outside the directory it is confined to, or its bounded handshake did not complete."},
        {"code": "outer_integrity_digest_unobserved", "meaning": "The outer integrity digest is absent, so outer facts cannot be checked."},
        {"code": "request_identity_claim_unobserved", "meaning": "The declared request identity state is absent rather than an explicit value or null."},
        {"code": "ruling_applicability_unestablished", "meaning": "A ruling names no head, tree, or envelope digest, so its applicability to this candidate cannot be established."},
    ],
}


# --- git observation --------------------------------------------------------


def git(repo, *args):
    completed = subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, text=True, check=False
    )
    return completed.returncode, completed.stdout


def git_out(repo, *args):
    code, out = git(repo, *args)
    return out.strip() if code == 0 else None


def resolve_commit(repo, rev):
    return git_out(repo, "rev-parse", "--verify", "--quiet", str(rev) + "^{commit}")


def is_ancestor(repo, ancestor, descendant):
    code, _ = git(repo, "merge-base", "--is-ancestor", ancestor, descendant)
    if code == 0:
        return True
    if code == 1:
        return False
    return None


def commit_distance(repo, ancestor, descendant):
    out = git_out(repo, "rev-list", "--count", ancestor + ".." + descendant)
    if out is None or not out.isdigit():
        return None
    return int(out)


def changed_file_table(repo, base, head):
    code, out = git(
        repo, "diff", "--raw", "-z", "--no-renames", "--abbrev=40", base, head
    )
    if code != 0:
        raise Unobservable("repository_unreadable", "the contribution diff could not be read")
    fields = out.split("\0")
    rows = []
    index = 0
    while index < len(fields):
        meta = fields[index]
        if not meta:
            index += 1
            continue
        if not meta.startswith(":"):
            raise Unobservable("repository_unreadable", "the contribution diff is malformed")
        index += 1
        if index >= len(fields):
            raise Unobservable("repository_unreadable", "the contribution diff is truncated")
        path = fields[index]
        index += 1
        parts = meta[1:].split()
        if len(parts) < 5:
            raise Unobservable("repository_unreadable", "a contribution diff record is malformed")
        rows.append(
            {"path": path, "status": parts[4], "before": parts[2], "after": parts[3]}
        )
    rows.sort(key=lambda row: row["path"])
    return rows


# --- declared-input reading -------------------------------------------------


def require_object(mapping, key):
    value = mapping.get(key)
    if not isinstance(value, dict):
        raise Unobservable("inputs_malformed", "inputs are missing the " + key + " object", key)
    return value


def require_field(mapping, owner, key):
    value = mapping.get(key)
    if value is None or (isinstance(value, str) and not value.strip()):
        raise Unobservable("inputs_malformed", owner + " is missing " + key, key)
    return value


def as_list(mapping, key):
    value = mapping.get(key, [])
    if value is None:
        return []
    if not isinstance(value, list):
        raise Unobservable("inputs_malformed", key + " must be a list", key)
    return value


def as_dict(mapping, key):
    value = mapping.get(key, {})
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise Unobservable("inputs_malformed", key + " must be an object", key)
    return value


def rule_id(rule):
    return str(rule.get("id", rule.get("value", "")))


def path_matches(rule, path):
    if not isinstance(rule, dict):
        raise Unobservable("inputs_malformed", "a path rule is not an object")
    kind = rule.get("type", "glob")
    value = rule.get("value", "")
    if kind == "exact":
        return path == value
    if kind == "prefix":
        return path.startswith(value)
    if kind == "glob":
        return fnmatch.fnmatchcase(path, value)
    raise Unobservable("inputs_malformed", "unknown path match type: " + str(kind))


# --- code-owned executable resolution ---------------------------------------


def probe_capability(capability):
    """Evaluate the COMPLETE declared candidate set, in declared order, and stop
    at the first candidate that both resolves and states its own identity."""
    capability_id = str(capability.get("id"))
    candidates = capability.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise Unobservable(
            "inputs_malformed", "capability " + capability_id + " declares no candidate set"
        )
    identity_argv = capability.get("identity_argv")
    if not isinstance(identity_argv, list) or not identity_argv:
        raise Unobservable(
            "inputs_malformed", "capability " + capability_id + " declares no identity arguments"
        )
    timeout = capability.get("identity_timeout_seconds", 10)
    if not isinstance(timeout, int) or timeout <= 0:
        raise Unobservable(
            "inputs_malformed", "capability " + capability_id + " declares a bad identity timeout"
        )
    probes = []
    selected = None
    malformed = None
    for candidate in candidates:
        if not isinstance(candidate, str) or not candidate:
            malformed = str(candidate)
            probes.append({"candidate": str(candidate), "outcome": "malformed"})
            continue
        if "/" in candidate and not candidate.startswith("/"):
            malformed = candidate
            probes.append({"candidate": candidate, "outcome": "malformed"})
            continue
        if selected is not None:
            probes.append({"candidate": candidate, "outcome": "not_probed"})
            continue
        path = shutil.which(candidate)
        if path is None:
            probes.append({"candidate": candidate, "outcome": "absent"})
            continue
        try:
            completed = subprocess.run(
                [path, *[str(argument) for argument in identity_argv]],
                capture_output=True,
                text=True,
                check=False,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            # Recorded as its own outcome rather than folded into a failure,
            # because a deadline that reads as a verdict is the exit-124 defect.
            probes.append({"candidate": candidate, "path": path, "outcome": "identity_timed_out"})
            continue
        except OSError as error:
            probes.append(
                {"candidate": candidate, "path": path, "outcome": "identity_failed", "detail": str(error)}
            )
            continue
        identity = (completed.stdout + completed.stderr).strip()
        if completed.returncode != 0 or not identity:
            probes.append(
                {
                    "candidate": candidate,
                    "path": path,
                    "outcome": "identity_failed",
                    "exit_status": completed.returncode,
                }
            )
            continue
        probes.append({"candidate": candidate, "path": path, "outcome": "selected"})
        selected = {
            "candidate": candidate,
            "path": path,
            "identity": identity.splitlines()[0],
            "identity_argv": [str(argument) for argument in identity_argv],
        }
    return probes, selected, malformed


# --- continuous integration reduction ---------------------------------------


def verdict_of(attempt):
    conclusion = str(attempt.get("conclusion") or attempt.get("state") or "").upper()
    if conclusion in ADVERSE_CONCLUSIONS:
        return "FAILING"
    if conclusion == "SUCCESS":
        return "SUCCESS"
    if conclusion == "SKIPPED":
        return "SKIPPED"
    if conclusion == "":
        return "PENDING"
    return "NO_VERDICT"


def worst(verdicts):
    return min(verdicts, key=VERDICT_RANK.index)


def reduce_checks(attempts):
    """One current verdict per check, keyed by owning workflow and name so two
    workflows sharing a job name stay two checks."""
    groups = {}
    for index, attempt in enumerate(attempts):
        name = str(attempt.get("name") or "")
        workflow = str(attempt.get("workflow") or "")
        key = (workflow, name) if name else ("", "#" + str(index))
        groups.setdefault(key, []).append(attempt)
    checks = []
    for key in sorted(groups):
        members = groups[key]
        orders = [member.get("order") for member in members]
        usable = all(isinstance(order, int) for order in orders)
        if len(members) > 1 and not usable:
            checks.append(
                {
                    "workflow": key[0],
                    "name": key[1],
                    "platforms": sorted(
                        {str(m.get("platform") or "") for m in members if m.get("platform")}
                    ),
                    "attempts": len(members),
                    "verdict": "UNDECIDABLE",
                    "tie": False,
                }
            )
            continue
        current = [m for m in members if m.get("order") == max(orders)] if usable else members
        checks.append(
            {
                "workflow": key[0],
                "name": key[1],
                "platforms": sorted(
                    {str(m.get("platform") or "") for m in current if m.get("platform")}
                ),
                "attempts": len(members),
                "verdict": worst([verdict_of(member) for member in current]),
                "tie": len(current) > 1,
            }
        )
    return checks


# --- reading stored documents -----------------------------------------------


def read_json(path, code, detail):
    if not path:
        raise Unobservable("usage_error", detail + ": no path was given")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as error:
        raise Unobservable(code, detail + ": " + str(error), str(path))


def read_envelope(path, code):
    if path and os.path.isdir(path):
        path = os.path.join(path, "envelope.json")
    document = read_json(path, code, "envelope is unreadable")
    if not isinstance(document, dict) or document.get("schema") != SCHEMA:
        raise Unobservable(code, "not a " + SCHEMA + " document", str(path))
    body = document.get("envelope")
    stored = (document.get("digest") or {}).get("value")
    if not isinstance(body, dict) or not stored:
        raise Unobservable(code, "envelope document is incomplete", str(path))
    return document, body, stored, path


def open_evidence(root, locator):
    """A locator is a repository-independent relative path under one root. An
    absolute path or a parent traversal is refused rather than followed, so an
    envelope cannot borrow bytes from outside the evidence it was given."""
    if not isinstance(locator, str) or not locator:
        return None, "locator is empty"
    if os.path.isabs(locator):
        return None, "locator is absolute"
    if any(part in ("", ".", "..") for part in locator.split("/")):
        return None, "locator escapes its root"
    if root is None:
        return None, "no evidence root was supplied"
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        return None, "this platform cannot open evidence without following symlinks"
    try:
        directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | nofollow)
    except OSError:
        return None, "evidence root is unreadable"
    try:
        parts = locator.split("/")
        for part in parts[:-1]:
            next_fd = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | nofollow,
                dir_fd=directory_fd,
            )
            os.close(directory_fd)
            directory_fd = next_fd
        file_fd = os.open(
            parts[-1], os.O_RDONLY | nofollow, dir_fd=directory_fd
        )
        if not stat.S_ISREG(os.fstat(file_fd).st_mode):
            os.close(file_fd)
            return None, "locator names no readable file"
        # The containment check and the hash use this same open handle. A path
        # is only a mutable name and must never authorize a later path lookup.
        return os.fdopen(file_fd, "rb"), None
    except OSError:
        return None, "locator names no readable file"
    finally:
        os.close(directory_fd)


def request_identity(envelope, envelope_digest):
    project = envelope["identity"]["project"]
    work = envelope["identity"]["work"]
    work_identity = {"id": work["id"], "forge_request": work.get("request")}
    return digest_of(
        {
            "project": {
                "id": project["id"],
                "root_commits": project["root_commits"],
            },
            "work": work_identity,
            "candidate_head_commit": envelope["candidate"]["head_commit"],
            "envelope_digest": envelope_digest,
            "policy_version": envelope["identity"]["policy"]["version"],
        }
    )


def ruling_target_digest(envelope):
    target = json.loads(json.dumps(envelope))
    target["rulings"] = []
    return digest_of(target)


def ruling_applicability(applies_to, envelope, envelope_digest):
    candidate_axes = ("head", "tree", "envelope_digest")
    established = any(applies_to.get(axis) for axis in candidate_axes)
    mismatches = []
    if applies_to.get("work_id") and applies_to["work_id"] != envelope["identity"]["work"]["id"]:
        mismatches.append("work_id")
    if applies_to.get("head") and applies_to["head"] != envelope["candidate"]["head_commit"]:
        mismatches.append("head")
    if applies_to.get("tree") and applies_to["tree"] != envelope["candidate"]["head_tree"]:
        mismatches.append("tree")
    if (applies_to.get("envelope_digest")
            and applies_to["envelope_digest"] != envelope_digest):
        mismatches.append("envelope_digest")
    return established, mismatches


def outer_integrity_payload(document):
    return {
        "compiled_at": document.get("compiled_at"),
        "compiler": document.get("compiler"),
        "body_digest": (document.get("digest") or {}).get("value"),
        "request_identity": document.get("request_identity"),
        "declared_request_identity": document.get("declared_request_identity"),
    }


def bind_evidence(block, evidence_root):
    """Resolve and digest one evidence block at compile time, so what the
    envelope binds is a digest this compiler observed rather than one it was
    handed."""
    if not isinstance(block, dict):
        return
    handle, problem = open_evidence(evidence_root, block.get("locator"))
    block["resolved"] = problem is None
    block["resolution_detail"] = problem
    if handle is not None:
        with handle:
            observed = digest_evidence_handle(handle, block.get("locator"))
        block["observed_sha256"] = observed
        block["matches"] = observed == block.get("sha256")


# --- compilation ------------------------------------------------------------


def compile_envelope(repo, inputs, predecessor_path, evidence_root):
    if not isinstance(inputs, dict) or inputs.get("schema") != INPUTS_SCHEMA:
        raise Unobservable("inputs_malformed", "inputs are not a " + INPUTS_SCHEMA + " document")
    if git_out(repo, "rev-parse", "--is-inside-work-tree") != "true":
        raise Unobservable("repository_unreadable", "not a git checkout: " + str(repo))

    project = require_object(inputs, "project")
    require_field(project, "project", "id")
    work = require_object(inputs, "work")
    require_field(work, "work", "id")

    policy = as_dict(inputs, "policy")
    if not policy.get("version"):
        raise Unobservable("policy_undeclared", "policy must declare a version")
    bound = policy.get("max_base_behind_main")
    if not isinstance(bound, int) or isinstance(bound, bool) or bound < 0:
        raise Unobservable(
            "policy_undeclared", "policy must declare max_base_behind_main as a non-negative integer"
        )

    requested_decision = require_field(inputs, "inputs", "requested_decision")

    candidate_in = require_object(inputs, "candidate")
    base_ref = require_field(candidate_in, "candidate", "base_ref")
    head_ref = require_field(candidate_in, "candidate", "head_ref")

    base_commit = resolve_commit(repo, base_ref)
    if base_commit is None:
        raise Unobservable("base_unresolvable", "base does not resolve: " + str(base_ref), str(base_ref))
    head_commit = resolve_commit(repo, head_ref)
    if head_commit is None:
        raise Unobservable(
            "candidate_unresolvable", "candidate does not resolve: " + str(head_ref), str(head_ref)
        )
    head_tree = git_out(repo, "rev-parse", "--verify", head_commit + "^{tree}")
    if head_tree is None:
        raise Unobservable("repository_unreadable", "candidate commit has no readable tree")

    applicability_in = require_object(inputs, "applicability")
    main_ref = require_field(applicability_in, "applicability", "main_ref")
    main_commit = resolve_commit(repo, main_ref)
    if main_commit is None:
        raise Unobservable("main_unresolvable", "trunk does not resolve: " + str(main_ref), str(main_ref))

    merge_base = git_out(repo, "merge-base", base_commit, head_commit)
    if merge_base is None:
        raise Unobservable("repository_unreadable", "base and candidate share no history")

    behind = commit_distance(repo, base_commit, main_commit)
    if behind is None:
        raise Unobservable("repository_unreadable", "the base-to-trunk distance is unreadable")

    rows = changed_file_table(repo, merge_base, head_commit)

    exclusions = as_list(as_dict(inputs, "scope"), "excluded")
    matched_rules = set()
    for row in rows:
        row["in_scope"] = True
        row["excluded_by"] = None
        for rule in exclusions:
            if path_matches(rule, row["path"]):
                row["in_scope"] = False
                row["excluded_by"] = rule_id(rule)
                matched_rules.add(row["excluded_by"])
                break

    verification_in = as_dict(inputs, "verification")
    if "applicability_rules" not in verification_in:
        raise Unobservable(
            "verification_applicability_undeclared",
            "verification must declare non-empty applicability rules, or an explicit none with a reason",
        )
    applicability_rules = verification_in["applicability_rules"]
    if isinstance(applicability_rules, list):
        if not applicability_rules:
            raise Unobservable(
                "verification_applicability_undeclared",
                "verification applicability rules cannot be an empty list",
            )
        rules = applicability_rules
    elif isinstance(applicability_rules, dict) and applicability_rules.get("none") is True:
        reason = applicability_rules.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            raise Unobservable(
                "verification_applicability_undeclared",
                "explicitly declaring no verification contracts requires a reason",
            )
        rules = []
    else:
        raise Unobservable(
            "inputs_malformed",
            "verification.applicability_rules must be a non-empty list or an explicit none with a reason",
        )
    if rules and not any(isinstance(rule, dict) and rule.get("mandatory") is True for rule in rules):
        raise Unobservable(
            "verification_applicability_undeclared",
            "verification applicability rules must include a mandatory rule",
        )
    required_ids = set()
    for rule in rules:
        if not isinstance(rule, dict):
            raise Unobservable("inputs_malformed", "an applicability rule must be an object")
        contract_id = rule.get("contract_id")
        if not contract_id:
            raise Unobservable("inputs_malformed", "an applicability rule names no contract")
        if rule.get("mandatory"):
            required_ids.add(contract_id)
            continue
        for path_rule in as_list(rule, "paths"):
            if any(path_matches(path_rule, row["path"]) for row in rows if row["in_scope"]):
                required_ids.add(contract_id)
                break

    capabilities = []
    for capability in as_list(inputs, "capabilities"):
        if not isinstance(capability, dict) or not capability.get("id"):
            raise Unobservable("inputs_malformed", "a capability declares no id")
        probes, selected, malformed = probe_capability(capability)
        required = bool(capability.get("mandatory"))
        if not required:
            for path_rule in as_list(capability, "paths"):
                if any(path_matches(path_rule, row["path"]) for row in rows if row["in_scope"]):
                    required = True
                    break
        capabilities.append(
            {
                "id": str(capability["id"]),
                "required": required,
                "candidates": [str(entry) for entry in capability.get("candidates", [])],
                "identity_argv": [str(entry) for entry in capability.get("identity_argv", [])],
                "probes": probes,
                "selected": selected,
                "candidates_exhausted": selected is None,
                "malformed_candidate": malformed,
            }
        )
    capabilities = sorted_records(capabilities, ("id",), "capabilities")

    ci_in = as_dict(inputs, "ci")
    attempts = []
    for attempt in as_list(ci_in, "attempts"):
        if not isinstance(attempt, dict):
            raise Unobservable("inputs_malformed", "a continuous integration attempt is not an object")
        attempts.append(
            {
                "name": str(attempt.get("name") or ""),
                "workflow": str(attempt.get("workflow") or ""),
                "platform": str(attempt.get("platform") or ""),
                "head": str(attempt.get("head") or ""),
                "order": attempt.get("order"),
                "conclusion": str(attempt.get("conclusion") or attempt.get("state") or "").upper(),
            }
        )
    attempts = sorted_records(
        attempts,
        ("workflow", "name", "head", "order", "platform", "conclusion"),
        "continuous integration attempts",
    )
    exact, wrong_head, head_unknown = [], [], []
    for attempt in attempts:
        attempt_head = attempt.get("head")
        summary = {
            "name": str(attempt.get("name") or ""),
            "workflow": str(attempt.get("workflow") or ""),
            "platform": str(attempt.get("platform") or ""),
            "verdict": verdict_of(attempt),
        }
        if not attempt_head:
            head_unknown.append(summary)
        elif attempt_head == head_commit:
            exact.append(attempt)
        else:
            summary["head"] = str(attempt_head)
            wrong_head.append(summary)

    obligations_in = as_dict(inputs, "obligations")
    if "predecessor" not in obligations_in:
        raise Unobservable(
            "predecessor_undeclared",
            "obligations must declare a predecessor, or an explicit none with a reason",
        )
    predecessor = obligations_in["predecessor"]
    if not isinstance(predecessor, dict):
        raise Unobservable("inputs_malformed", "obligations.predecessor must be an object")
    predecessor_active = []
    predecessor_digest = None
    predecessor_contradiction = False
    if predecessor.get("none"):
        if not predecessor.get("reason"):
            raise Unobservable("predecessor_undeclared", "a none predecessor must carry a reason")
        if predecessor_path:
            predecessor_contradiction = True
    else:
        predecessor_digest = predecessor.get("envelope_digest")
        if not predecessor_digest:
            raise Unobservable(
                "predecessor_undeclared",
                "a predecessor must name an envelope_digest, or declare none with a reason",
            )
        if not predecessor_path:
            raise Unobservable(
                "predecessor_unreadable", "the declared predecessor envelope was not supplied"
            )
        _, prior_body, prior_stored, prior_path = read_envelope(predecessor_path, "predecessor_unreadable")
        recomputed = digest_of(prior_body)
        if recomputed != prior_stored:
            raise Unobservable(
                "predecessor_unreadable",
                "the predecessor envelope does not match its own digest",
                str(prior_path),
            )
        if recomputed != predecessor_digest:
            raise Unobservable(
                "predecessor_unreadable",
                "the supplied predecessor is " + recomputed + ", the inputs declare " + str(predecessor_digest),
                str(prior_path),
            )
        predecessor_active = sorted(
            str(entry.get("id"))
            for entry in as_list(as_dict(prior_body, "obligations"), "active")
        )

    envelope = {
        "identity": {
            "project": {
                "id": str(project["id"]),
                "declared_root_commit": project.get("root_commit"),
                "root_commits": sorted(
                    (git_out(repo, "rev-list", "--max-parents=0", head_commit) or "").split()
                ),
                "origin_url": git_out(repo, "config", "--get", "remote.origin.url"),
            },
            "work": {
                "id": str(work["id"]),
                "increment": work.get("increment"),
                "request": work.get("request"),
            },
            "policy": {"version": policy["version"], "max_base_behind_main": bound},
            "requested_decision": requested_decision,
        },
        "candidate": {
            "base_ref": base_ref,
            "base_commit": base_commit,
            "declared_base_commit": candidate_in.get("base_commit"),
            "head_ref": head_ref,
            "head_commit": head_commit,
            "declared_head_commit": candidate_in.get("head_commit"),
            "head_tree": head_tree,
            "merge_base": merge_base,
            "changed_files": rows,
            "changed_file_count": len(rows),
            "diff_digest": digest_of(
                [[row["status"], row["before"], row["after"], row["path"]] for row in rows]
            ),
        },
        "scope": {
            "excluded": exclusions,
            "in_scope_paths": sorted(row["path"] for row in rows if row["in_scope"]),
            "excluded_paths": sorted(
                (
                    {"path": row["path"], "excluded_by": row["excluded_by"]}
                    for row in rows
                    if not row["in_scope"]
                ),
                key=lambda entry: entry["path"],
            ),
            "unused_exclusions": sorted(
                rule_id(rule) for rule in exclusions if rule_id(rule) not in matched_rules
            ),
        },
        "applicability": {
            "main_ref": main_ref,
            "main_commit": main_commit,
            "base_is_ancestor_of_main": is_ancestor(repo, base_commit, main_commit),
            "base_behind_main": behind,
            "base_is_ancestor_of_head": is_ancestor(repo, base_commit, head_commit),
            "head_is_ancestor_of_main": is_ancestor(repo, head_commit, main_commit),
        },
        "verification": {
            "applicability_rules": (
                canonicalize_applicability_rules(applicability_rules)
                if isinstance(applicability_rules, list)
                else applicability_rules
            ),
            "required_contract_ids": sorted(required_ids),
            "contracts": canonicalize_contracts(as_list(verification_in, "contracts")),
            "results": sorted_records(
                as_list(verification_in, "results"),
                ("contract_id", "contract_digest", "world", "verifier_id", "verifier_digest"),
                "verification results",
            ),
        },
        "capabilities": capabilities,
        "ci": {
            "required_platforms": sorted(str(entry) for entry in as_list(ci_in, "required_platforms")),
            "attempts": attempts,
            "checks": reduce_checks(exact),
            "wrong_head_attempts": sorted_records(
                wrong_head,
                ("workflow", "name", "head", "platform", "verdict"),
                "wrong-head continuous integration attempts",
            ),
            "head_unknown_attempts": sorted_records(
                head_unknown,
                ("workflow", "name", "platform", "verdict"),
                "head-unknown continuous integration attempts",
            ),
        },
        "findings": {
            "adverse": sorted_records(
                as_list(as_dict(inputs, "findings"), "adverse"),
                ("id",),
                "adverse findings",
            ),
            "unproven": sorted_records(
                as_list(as_dict(inputs, "findings"), "unproven"),
                ("id",),
                "unproven findings",
            ),
        },
        "rulings": [],
        "obligations": {
            "predecessor": predecessor,
            "predecessor_digest": predecessor_digest,
            "predecessor_contradiction": predecessor_contradiction,
            "predecessor_active": predecessor_active,
            "active": sorted_records(
                as_list(obligations_in, "active"), ("id",), "active obligations"
            ),
            "dispositions": sorted_records(
                as_list(obligations_in, "dispositions"), ("id",), "obligation dispositions"
            ),
        },
    }

    for result in envelope["verification"]["results"]:
        if not isinstance(result, dict):
            raise Unobservable("inputs_malformed", "a verification result is not an object")
        bind_evidence(result.get("evidence"), evidence_root)
        bind_evidence(as_dict(result, "red_calibration").get("evidence"), evidence_root)
    for disposition in envelope["obligations"]["dispositions"]:
        if not isinstance(disposition, dict):
            raise Unobservable("inputs_malformed", "an obligation disposition is not an object")
        bind_evidence(disposition.get("evidence"), evidence_root)

    current_envelope_digest = ruling_target_digest(envelope)
    for ruling in as_list(inputs, "rulings"):
        applies_to = as_dict(ruling, "applies_to")
        established, mismatches = ruling_applicability(
            applies_to, envelope, current_envelope_digest
        )
        envelope["rulings"].append(
            {
                "id": "" if ruling.get("id") is None else str(ruling.get("id")),
                "source": ruling.get("source"),
                "disposition": ruling.get("disposition"),
                "relied_upon": bool(ruling.get("relied_upon")),
                "applies_to": applies_to,
                "applicability_established": established,
                "applicable": established and not mismatches,
                "mismatches": mismatches,
            }
        )
    envelope["rulings"] = sorted_records(envelope["rulings"], ("id",), "rulings")

    return envelope


# --- classification ---------------------------------------------------------


class Problems:
    def __init__(self):
        self.refusals = []
        self.unobserved = []

    def refuse(self, code, subject="", detail=""):
        self.refusals.append({"code": code, "subject": str(subject), "detail": detail})

    def unobserve(self, code, subject="", detail=""):
        self.unobserved.append({"code": code, "subject": str(subject), "detail": detail})


def classify_repository(problems, envelope, repo):
    candidate = envelope["candidate"]
    applicability = envelope["applicability"]
    if git_out(repo, "rev-parse", "--is-inside-work-tree") != "true":
        problems.unobserve("repository_unreadable", repo, "not a git checkout")
        return
    head_now = resolve_commit(repo, candidate["head_ref"])
    if head_now is None:
        problems.unobserve(
            "candidate_unresolvable", candidate["head_ref"], "the candidate reference is gone"
        )
    elif head_now != candidate["head_commit"]:
        problems.refuse(
            "candidate_head_moved",
            candidate["head_ref"],
            "bound " + candidate["head_commit"] + ", now " + head_now,
        )
    tree_now = git_out(
        repo, "rev-parse", "--verify", "--quiet", candidate["head_commit"] + "^{tree}"
    )
    if tree_now is None:
        problems.unobserve(
            "candidate_unresolvable",
            candidate["head_commit"],
            "the bound head is not in this repository",
        )
    elif tree_now != candidate["head_tree"]:
        problems.refuse(
            "candidate_tree_moved", candidate["head_commit"], "the bound tree does not match"
        )
    base_now = resolve_commit(repo, candidate["base_ref"])
    if base_now is None:
        problems.unobserve("base_unresolvable", candidate["base_ref"], "the base reference is gone")
    elif base_now != candidate["base_commit"]:
        problems.refuse(
            "base_moved",
            candidate["base_ref"],
            "bound " + candidate["base_commit"] + ", now " + base_now,
        )
    main_now = resolve_commit(repo, applicability["main_ref"])
    if main_now is None:
        problems.unobserve(
            "main_unresolvable", applicability["main_ref"], "the trunk reference is gone"
        )
        return
    allowed = envelope["identity"]["policy"]["max_base_behind_main"]
    behind = commit_distance(repo, candidate["base_commit"], main_now)
    if behind is None:
        problems.unobserve(
            "repository_unreadable", "base_behind_main", "the trunk distance is unreadable"
        )
    elif behind > allowed:
        problems.refuse(
            "base_behind_main_exceeds_policy",
            candidate["base_ref"],
            "the base trails the trunk by " + str(behind) + ", policy allows " + str(allowed),
        )
    if is_ancestor(repo, candidate["base_commit"], main_now) is False:
        problems.refuse(
            "base_not_on_main_line", candidate["base_ref"], "the base is not an ancestor of the trunk"
        )


def classify(envelope, repo, evidence_root, recheck_evidence):
    problems = Problems()
    candidate = envelope["candidate"]

    classify_repository(problems, envelope, repo)

    forge_request = envelope["identity"]["work"].get("request")
    request_fields_valid = isinstance(forge_request, dict) and all(
        isinstance(forge_request.get(field), str) and bool(forge_request[field].strip())
        for field in ("kind", "forge", "url")
    )
    request_id = forge_request.get("id") if isinstance(forge_request, dict) else None
    request_id_valid = (
        isinstance(request_id, str) and bool(request_id.strip())
    ) or (isinstance(request_id, int) and not isinstance(request_id, bool))
    if not request_fields_valid or not request_id_valid:
        problems.refuse(
            "forge_request_identity_invalid",
            envelope["identity"]["work"].get("id"),
            "work.request must carry non-empty kind, forge, id and url fields",
        )

    requested_decision = envelope["identity"].get("requested_decision")
    if not isinstance(requested_decision, str) or not re.fullmatch(
        r"[A-Z][A-Z0-9_]*", requested_decision
    ):
        problems.refuse(
            "requested_decision_invalid",
            requested_decision,
            "requested_decision must be an uppercase token",
        )

    declared_head = candidate.get("declared_head_commit")
    if declared_head and declared_head != candidate["head_commit"]:
        problems.refuse(
            "declared_head_mismatch",
            candidate["head_ref"],
            "inputs asserted " + str(declared_head) + ", the repository resolved " + candidate["head_commit"],
        )
    declared_base = candidate.get("declared_base_commit")
    if declared_base and declared_base != candidate["base_commit"]:
        problems.refuse(
            "declared_head_mismatch",
            candidate["base_ref"],
            "inputs asserted " + str(declared_base) + ", the repository resolved " + candidate["base_commit"],
        )
    project = envelope["identity"]["project"]
    if project.get("declared_root_commit") and project["declared_root_commit"] not in project["root_commits"]:
        problems.refuse(
            "project_identity_mismatch",
            project.get("id"),
            "the declared root commit is not one of this repository's",
        )

    if envelope["applicability"].get("base_is_ancestor_of_head") is False:
        problems.refuse(
            "base_not_ancestor_of_candidate",
            candidate["base_ref"],
            "the candidate does not descend from its base",
        )

    if candidate["changed_file_count"] == 0:
        problems.refuse(
            "changed_file_set_empty", candidate["head_ref"], "the contribution changes nothing"
        )
    elif not envelope["scope"]["in_scope_paths"]:
        problems.refuse(
            "scope_fully_excluded", candidate["head_ref"], "every changed path is excluded from review"
        )

    classify_verification(problems, envelope, evidence_root, recheck_evidence)
    classify_capabilities(problems, envelope)
    classify_ci(problems, envelope)

    for finding in envelope["findings"]["adverse"]:
        if isinstance(finding, dict) and finding.get("blocking"):
            problems.refuse(
                "adverse_finding_blocking", finding.get("id"), str(finding.get("statement") or "")
            )
    for finding in envelope["findings"]["unproven"]:
        if isinstance(finding, dict) and finding.get("required"):
            problems.unobserve(
                "unproven_dimension_required", finding.get("id"), str(finding.get("statement") or "")
            )

    current_envelope_digest = ruling_target_digest(envelope)
    ruling_ids = [str(ruling.get("id") or "") for ruling in envelope["rulings"]]
    if any(not ruling_id.strip() for ruling_id in ruling_ids):
        problems.refuse(
            "ruling_id_absent", "rulings", "a ruling carries no non-blank stable id"
        )
    ambiguous_ruling_ids = {
        ruling_id
        for ruling_id in ruling_ids
        if ruling_id.strip() and ruling_ids.count(ruling_id) > 1
    }
    for ruling_id in sorted(ambiguous_ruling_ids):
        problems.refuse(
            "ruling_id_ambiguous", ruling_id, "more than one ruling carries this stable id"
        )
    ruling_index = {
        str(ruling.get("id")): ruling
        for ruling in envelope["rulings"]
        if str(ruling.get("id") or "").strip()
        and str(ruling.get("id")) not in ambiguous_ruling_ids
    }
    for ruling in envelope["rulings"]:
        applies_to = ruling.get("applies_to") if isinstance(ruling.get("applies_to"), dict) else {}
        established, mismatches = ruling_applicability(
            applies_to, envelope, current_envelope_digest
        )
        ruling["applicability_established"] = established
        ruling["applicable"] = established and not mismatches
        ruling["mismatches"] = mismatches
        if not established:
            problems.unobserve(
                "ruling_applicability_unestablished",
                ruling.get("id"),
                "names no head, tree, or envelope digest",
            )
        if ruling.get("relied_upon") and not established:
            problems.refuse(
                "ruling_applicability_unestablished_relied_upon",
                ruling.get("id"),
                "relied upon without a candidate-identifying applicability axis",
            )
        elif ruling.get("relied_upon") and mismatches:
            problems.refuse(
                "ruling_applicability_mismatch",
                ruling.get("id"),
                "relied upon but does not apply: " + ", ".join(mismatches),
            )

    classify_obligations(problems, envelope, ruling_index, evidence_root, recheck_evidence)

    if problems.refusals:
        readiness, result, reason = "REFUSED", "FAIL", "verifier_reported_failure"
    elif problems.unobserved:
        readiness, result, reason = "COULD_NOT_OBSERVE", "NO_VERIFIER_RAN", "verification_incomplete"
    else:
        readiness, result, reason = "REVIEW_READY", "PASS", "verified"

    return {
        "schema": CLASSIFICATION_SCHEMA,
        "envelope_digest": digest_of(envelope),
        "readiness": readiness,
        "result": result,
        "reason": reason,
        "refusals": problems.refusals,
        "unobserved": problems.unobserved,
        "evidence_rechecked": bool(recheck_evidence),
        "observed_at": now_utc(),
    }


def classify_verification(problems, envelope, evidence_root, recheck_evidence):
    contracts = {}
    for entry in envelope["verification"]["contracts"]:
        if isinstance(entry, dict) and entry.get("id"):
            contract_id = str(entry["id"])
            if contract_id in contracts:
                problems.refuse(
                    "verification_contract_id_ambiguous",
                    contract_id,
                    "more than one contract reference carries this stable id",
                )
                continue
            contracts[contract_id] = entry
    results = {}
    for result in envelope["verification"]["results"]:
        if isinstance(result, dict):
            results.setdefault(str(result.get("contract_id")), []).append(result)

    for contract_id in envelope["verification"]["required_contract_ids"]:
        contract = contracts.get(str(contract_id))
        if contract is None:
            problems.refuse(
                "missing_required_verification_contract",
                contract_id,
                "this candidate requires a contract with no reference in the envelope",
            )
            continue
        if not contract.get("digest"):
            problems.refuse(
                "missing_required_verification_contract",
                contract_id,
                "the contract reference carries no digest, so its identity is not pinned",
            )
        worlds = contract.get("execution_worlds") or [None]
        for world in worlds:
            label = str(contract_id) + ("/" + str(world) if world else "")
            matching = [
                result
                for result in results.get(str(contract_id), [])
                if world is None or result.get("world") == world
            ]
            if not matching:
                problems.refuse(
                    "missing_required_verifier_result", label, "no verifier result covers this world"
                )
                continue
            for result in matching:
                if result.get("contract_digest") != contract.get("digest"):
                    problems.refuse(
                        "verification_result_contract_mismatch",
                        label,
                        "the result binds contract digest "
                        + str(result.get("contract_digest"))
                        + ", the selected contract binds "
                        + str(contract.get("digest")),
                    )
                    continue
                classify_result(problems, label, result, envelope["candidate"], evidence_root, recheck_evidence)


def classify_result(problems, label, result, candidate, evidence_root, recheck_evidence):
    if not result.get("verifier_id") or not result.get("verifier_digest"):
        problems.refuse(
            "verifier_identity_unpinned",
            label,
            "the result names no verifier id and digest, so what produced it is not identified",
        )
    if result.get("head") != candidate["head_commit"]:
        problems.refuse(
            "required_verifier_wrong_head",
            label,
            "the result binds head " + str(result.get("head")) + ", the candidate is " + candidate["head_commit"],
        )
        return
    if result.get("tree") != candidate["head_tree"]:
        problems.refuse(
            "required_verifier_wrong_head",
            label,
            "the result binds tree " + str(result.get("tree")) + ", the candidate tree is " + candidate["head_tree"],
        )
        return
    outcome = str(result.get("result") or "").upper()
    if outcome == "FAIL":
        problems.refuse("required_verifier_failed", label, str(result.get("detail") or ""))
        return
    if outcome != "PASS":
        problems.unobserve(
            "required_verifier_unproven", label, "the verifier returned " + (outcome or "no result")
        )
        return
    check_evidence(problems, label, result.get("evidence"), evidence_root, recheck_evidence)
    calibration = result.get("red_calibration")
    if not isinstance(calibration, dict):
        problems.refuse(
            "missing_red_calibration",
            label,
            "a passing required verifier that was never observed failing proves nothing",
        )
        return
    if str(calibration.get("observed_result") or "").upper() != "FAIL":
        problems.refuse(
            "red_calibration_not_adverse",
            label,
            "the calibration records " + str(calibration.get("observed_result")) + ", not an observed failure",
        )
    if not calibration.get("reason"):
        problems.refuse("missing_red_calibration", label, "the calibration names no intended reason")
    check_evidence(
        problems, label + " red calibration", calibration.get("evidence"), evidence_root, recheck_evidence
    )


def check_evidence(problems, label, block, evidence_root, recheck_evidence):
    if not isinstance(block, dict) or not block.get("locator") or not block.get("sha256"):
        problems.refuse("evidence_locator_broken", label, "no evidence locator and digest are bound")
        return
    if block.get("resolved") is False:
        problems.refuse("evidence_locator_broken", label, str(block.get("resolution_detail") or ""))
        return
    if block.get("matches") is False:
        problems.refuse(
            "evidence_digest_mismatch",
            label,
            "bound " + str(block.get("sha256")) + ", observed " + str(block.get("observed_sha256")),
        )
        return
    if not recheck_evidence:
        return
    handle, problem = open_evidence(evidence_root, block.get("locator"))
    if problem is not None:
        problems.refuse("evidence_locator_broken", label, problem)
        return
    with handle:
        observed = digest_evidence_handle(handle, block.get("locator"))
    if observed != block.get("sha256"):
        problems.refuse(
            "evidence_digest_mismatch",
            label,
            "bound " + str(block.get("sha256")) + ", observed " + observed,
        )


def classify_capabilities(problems, envelope):
    for capability in envelope["capabilities"]:
        if capability.get("malformed_candidate"):
            problems.refuse(
                "capability_candidate_malformed",
                capability["id"],
                "candidate "
                + str(capability["malformed_candidate"])
                + " is neither a bare name nor an absolute path",
            )
        if capability.get("required") and capability.get("selected") is None:
            problems.unobserve(
                "capability_unresolved",
                capability["id"],
                "every declared candidate was exhausted: "
                + ", ".join(
                    str(probe.get("candidate")) + "=" + str(probe.get("outcome"))
                    for probe in capability.get("probes", [])
                ),
            )


def classify_ci(problems, envelope):
    covered = {}
    for check in envelope["ci"]["checks"]:
        if check["verdict"] == "UNDECIDABLE":
            problems.refuse(
                "ci_duplicate_attempt_undecidable",
                check["workflow"] + "/" + check["name"],
                str(check["attempts"]) + " attempts at one check carry no usable ordering",
            )
        for platform in check.get("platforms", []):
            covered.setdefault(platform, []).append(check)
    wrong_head_platforms = {
        entry["platform"]: entry
        for entry in envelope["ci"]["wrong_head_attempts"]
        if entry.get("platform")
    }
    for platform in envelope["ci"]["required_platforms"]:
        members = covered.get(platform, [])
        if not members:
            if platform in wrong_head_platforms:
                problems.refuse(
                    "ci_wrong_head",
                    platform,
                    "the only checks for this platform ran against " + wrong_head_platforms[platform]["head"],
                )
            else:
                problems.refuse(
                    "ci_required_platform_uncovered", platform, "no check at the candidate head covers it"
                )
            continue
        verdict = worst([check["verdict"] for check in members])
        if verdict == "FAILING":
            problems.refuse("ci_required_check_failing", platform, "the current check failed")
        elif verdict == "SKIPPED":
            problems.refuse("ci_required_check_skipped", platform, "the current check was skipped")
        elif verdict == "NO_VERDICT":
            problems.refuse(
                "ci_required_check_no_verdict", platform, "the current check completed without a verdict"
            )
        elif verdict == "PENDING":
            problems.unobserve(
                "ci_required_check_pending", platform, "the current check has not completed"
            )


def classify_obligations(problems, envelope, ruling_index, evidence_root, recheck_evidence):
    obligations = envelope["obligations"]
    if obligations.get("predecessor_contradiction"):
        problems.refuse(
            "predecessor_contradiction",
            "obligations.predecessor",
            "a predecessor envelope was supplied against inputs that declare none",
        )
    seen = []
    for entry in obligations["active"]:
        entry_id = str(entry.get("id") or "") if isinstance(entry, dict) else ""
        if not entry_id:
            problems.refuse("obligation_duplicate_id", "", "an active obligation carries no id")
            continue
        if entry_id in seen:
            problems.refuse("obligation_duplicate_id", entry_id, "one obligation id appears twice")
        seen.append(entry_id)
    active = set(seen)
    prior = set(obligations.get("predecessor_active") or [])

    dispositions = {}
    for disposition in obligations["dispositions"]:
        target = str(disposition.get("id") or "") if isinstance(disposition, dict) else ""
        if target not in prior:
            problems.refuse(
                "obligation_disposition_unknown", target, "the predecessor never held this obligation"
            )
            continue
        if target in dispositions:
            problems.refuse(
                "obligation_disposition_duplicate",
                target,
                "one predecessor obligation has more than one disposition",
            )
            continue
        dispositions[target] = disposition

    for obligation_id in sorted(prior):
        disposition = dispositions.get(obligation_id)
        if disposition is None:
            problems.refuse(
                "obligation_dropped",
                obligation_id,
                "a predecessor obligation is unaccounted for; disappearance is not a disposition",
            )
            continue
        kind = str(disposition.get("disposition") or "").upper()
        if kind not in DISPOSITIONS:
            problems.refuse(
                "obligation_dropped",
                obligation_id,
                "disposition " + (kind or "(empty)") + " is not one of " + ", ".join(DISPOSITIONS),
            )
            continue
        if kind == "PRESERVED":
            if obligation_id not in active:
                problems.refuse(
                    "obligation_preserved_but_absent",
                    obligation_id,
                    "called preserved but absent from the active set",
                )
            continue
        if obligation_id in active:
            problems.refuse(
                "obligation_disposition_contradicts_active_set",
                obligation_id,
                "discharged as " + kind + " while still active",
            )
        if kind == "SATISFIED":
            block = disposition.get("evidence")
            if not isinstance(block, dict) or not block.get("locator") or not block.get("sha256"):
                problems.refuse(
                    "obligation_satisfied_without_evidence",
                    obligation_id,
                    "satisfaction must name evidence by locator and digest",
                )
            else:
                check_evidence(
                    problems, "obligation " + obligation_id, block, evidence_root, recheck_evidence
                )
        elif kind == "RESOLVED":
            authority = disposition.get("authority")
            if not authority or not disposition.get("reason"):
                problems.refuse(
                    "obligation_resolved_without_authority",
                    obligation_id,
                    "resolution must name an explicit authority and reason",
                )
            elif str(authority) in ruling_index and not ruling_index[str(authority)].get("applicable"):
                if ruling_index[str(authority)].get("applicability_established"):
                    problems.refuse(
                        "ruling_applicability_mismatch",
                        authority,
                        "cited to resolve " + obligation_id + " but it does not apply to this candidate",
                    )
                else:
                    problems.refuse(
                        "ruling_applicability_unestablished_relied_upon",
                        authority,
                        "cited to resolve " + obligation_id + " without established applicability",
                    )
        elif kind == "SUPERSEDED":
            replacement = str(disposition.get("replaced_by") or "")
            if not replacement or replacement not in active:
                problems.refuse(
                    "obligation_superseded_without_replacement",
                    obligation_id,
                    "supersession must name a replacement that is active in this envelope",
                )


# --- documentation generation -----------------------------------------------


def render_docs():
    lines = []
    add = lines.append
    add("# The review-envelope/v1 contract")
    add("")
    add("<!-- Generated by bin/fm-review-envelope.sh docs. Do not edit by hand. -->")
    add("")
    add(CATALOG["summary"])
    add("")
    add(
        "This page is generated from the field catalog inside "
        "[`bin/fm-review-envelope-lib.sh`](../../bin/fm-review-envelope-lib.sh), "
        "which is the contract's single machine-readable owner."
    )
    add("Regenerate it with `bin/fm-review-envelope.sh docs`, and never edit it by hand.")
    add("")
    add(
        "A complete worked inputs document is the baseline fixture in "
        "[`tests/fm-review-envelope.test.sh`](../../tests/fm-review-envelope.test.sh), "
        "which is executable and therefore cannot drift from the compiler it feeds."
    )
    add("")
    add("| Artifact | Schema |")
    add("| --- | --- |")
    add("| Envelope | `" + CATALOG["schema"] + "` |")
    add("| Inputs | `" + CATALOG["inputs_schema"] + "` |")
    add("| Classification | `" + CATALOG["classification_schema"] + "` |")
    add("| Canonicalization | `" + CATALOG["canonicalization"] + "` |")
    add("")
    add("The stored document is pretty-printed with sorted keys, and its `envelope` body is what the digest covers.")
    add("Those are not the same bytes: the digest is taken over the body serialized as UTF-8 with keys sorted recursively, no insignificant whitespace and no trailing newline, so recompute it that way rather than over the file.")
    add("Nothing time-varying sits inside the body, so unmoved facts always produce the same digest and repeated compilation resolves to one review request rather than a new one each time.")
    for statement in CATALOG["digest_scope"]:
        add(statement)
    add("")
    add("## Where each fact comes from")
    add("")
    add("| Source | Meaning |")
    add("| --- | --- |")
    for source in CATALOG["sources"]:
        add("| `" + source["name"] + "` | " + source["description"] + " |")
    add("")
    for section in CATALOG["sections"]:
        add("## " + section["name"])
        add("")
        add(section["description"])
        add("")
        add("| Field | Source | Required | Meaning |")
        add("| --- | --- | --- | --- |")
        for field in section["fields"]:
            add(
                "| `"
                + field["name"]
                + "` | `"
                + field["source"]
                + "` | "
                + ("yes" if field["required"] else "no")
                + " | "
                + field["description"]
                + " |"
            )
        add("")
    add("## Refusals")
    add("")
    add("Each of these is an observed contradiction of readiness, and reports `FAIL`.")
    add("")
    add("| Code | Meaning |")
    add("| --- | --- |")
    for entry in CATALOG["refusals"]:
        add("| `" + entry["code"] + "` | " + entry["meaning"] + " |")
    add("")
    add("## Could-not-observe")
    add("")
    add("Each of these is a required fact that could not be observed, and reports `NO_VERIFIER_RAN`.")
    add("")
    add("None of them is a pass, and none of them is skippable.")
    add("")
    add("| Code | Meaning |")
    add("| --- | --- |")
    for entry in CATALOG["unobserved"]:
        add("| `" + entry["code"] + "` | " + entry["meaning"] + " |")
    add("")
    return "\n".join(lines)


# --- entry points -----------------------------------------------------------


def emit(classification, args):
    if args.json:
        print(json.dumps(classification, indent=2, sort_keys=True))
    else:
        print("review-envelope: " + classification["readiness"])
        print("envelope: " + str(classification["envelope_digest"]))
        for problem in classification["refusals"]:
            print(
                "  refusal " + problem["code"] + " subject=" + problem["subject"] + ": " + problem["detail"]
            )
        for problem in classification["unobserved"]:
            print(
                "  unobserved " + problem["code"] + " subject=" + problem["subject"] + ": " + problem["detail"]
            )
    if args.summary_out:
        with open(args.summary_out, "w", encoding="utf-8") as handle:
            handle.write("result=" + classification["result"] + "\n")
            handle.write("reason=" + classification["reason"] + "\n")
            handle.write("readiness=" + classification["readiness"] + "\n")
            handle.write("digest=" + str(classification["envelope_digest"]) + "\n")
    return {"PASS": 0, "FAIL": 1}.get(classification["result"], 2)


def unobservable(error, args):
    emit(
        {
            "schema": CLASSIFICATION_SCHEMA,
            "envelope_digest": None,
            "readiness": "COULD_NOT_OBSERVE",
            "result": "NO_VERIFIER_RAN",
            "reason": "verification_incomplete",
            "refusals": [],
            "unobserved": [{"code": error.code, "subject": error.subject, "detail": error.detail}],
            "evidence_rechecked": False,
            "observed_at": now_utc(),
        },
        args,
    )
    return 2


def refused(code, subject, detail, digest, args):
    return emit(
        {
            "schema": CLASSIFICATION_SCHEMA,
            "envelope_digest": digest,
            "readiness": "REFUSED",
            "result": "FAIL",
            "reason": "verifier_reported_failure",
            "refusals": [{"code": code, "subject": subject, "detail": detail}],
            "unobserved": [],
            "evidence_rechecked": False,
            "observed_at": now_utc(),
        },
        args,
    )


def command_prepare(args):
    for name in ("repo", "inputs", "out", "evidence_root"):
        if not getattr(args, name):
            raise Unobservable("usage_error", "prepare requires --" + name.replace("_", "-"))
    target = os.path.join(args.out, "envelope.json")
    if os.path.exists(target):
        raise Unobservable(
            "envelope_exists",
            "an envelope is written once; supersede a generation, never overwrite one",
            target,
        )
    inputs = read_json(args.inputs, "inputs_malformed", "inputs are unreadable")
    # A document that parses as JSON can still be malformed in a way no
    # individual guard names - a rule whose value is a number where a pattern
    # belongs, say. That is an input this compiler could not observe, and it is
    # reported as one: the contract promises three values on every path, so no
    # path may answer with a traceback instead.
    try:
        envelope = compile_envelope(args.repo, inputs, args.predecessor, args.evidence_root)
        envelope_digest = digest_of(envelope)
        computed_request_identity = request_identity(envelope, envelope_digest)
    except Unobservable:
        raise
    except Exception as error:
        raise Unobservable(
            "inputs_malformed",
            "inputs are structurally malformed: " + str(error),
            str(args.inputs),
        )
    request_input = as_dict(inputs, "request")
    document = {
        "schema": SCHEMA,
        "compiled_at": now_utc(),
        "compiler": "fm-review-envelope-lib.sh",
        "request_identity": computed_request_identity,
        "declared_request_identity": request_input.get("identity"),
        "digest": {
            "algorithm": "sha256",
            "canonicalization": CANONICALIZATION,
            "value": envelope_digest,
        },
        "envelope": envelope,
    }
    document["outer_digest"] = {
        "algorithm": "sha256",
        "canonicalization": CANONICALIZATION,
        "value": digest_of(outer_integrity_payload(document)),
    }
    os.makedirs(args.out, exist_ok=True)
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    try:
        classification = classify(envelope, args.repo, args.evidence_root, True)
    except Unobservable:
        raise
    except Exception as error:
        raise Unobservable(
            "inputs_malformed",
            "inputs are structurally malformed: " + str(error),
            str(args.inputs),
        )
    if "identity" in request_input and request_input["identity"] != computed_request_identity:
        classification["refusals"].append(
            {
                "code": "request_identity_mismatch",
                "subject": str(request_input["identity"]),
                "detail": "declared identity does not match " + computed_request_identity,
            }
        )
        classification["readiness"] = "REFUSED"
        classification["result"] = "FAIL"
        classification["reason"] = "verifier_reported_failure"
    return emit(classification, args)


def command_validate(args):
    if not args.repo:
        raise Unobservable("usage_error", "validate requires --repo")
    if not args.evidence_root and not args.no_recheck:
        raise Unobservable(
            "usage_error",
            "validate requires --evidence-root, or an explicit --no-evidence-recheck",
        )
    if args.evidence_root and args.no_recheck:
        raise Unobservable(
            "usage_error", "--evidence-root and --no-evidence-recheck contradict each other"
        )
    document, body, stored, path = read_envelope(args.envelope, "envelope_unreadable")
    recomputed = digest_of(body)
    if recomputed != stored:
        return refused(
            "envelope_digest_mismatch",
            str(path),
            "stored " + stored + ", recomputed " + recomputed,
            recomputed,
            args,
        )
    outer_digest = document.get("outer_digest")
    if not isinstance(outer_digest, dict) or not outer_digest.get("value"):
        raise Unobservable(
            "outer_integrity_digest_unobserved",
            "the outer integrity digest is absent",
            str(path),
        )
    recomputed_outer_digest = digest_of(outer_integrity_payload(document))
    if outer_digest["value"] != recomputed_outer_digest:
        return refused(
            "outer_integrity_digest_mismatch",
            str(path),
            "stored " + str(outer_digest["value"]) + ", recomputed " + recomputed_outer_digest,
            recomputed,
            args,
        )
    if "declared_request_identity" not in document:
        raise Unobservable(
            "request_identity_claim_unobserved",
            "the declared request identity state is absent",
            str(path),
        )
    try:
        recomputed_request_identity = request_identity(body, recomputed)
    except Unobservable:
        raise
    except Exception as error:
        raise Unobservable(
            "envelope_unreadable",
            "envelope body is structurally malformed: " + str(error),
            str(path),
        )
    if document.get("request_identity") != recomputed_request_identity:
        return refused(
            "request_identity_mismatch",
            str(path),
            "stored " + str(document.get("request_identity")) + ", recomputed " + recomputed_request_identity,
            recomputed,
            args,
        )
    if (
        document["declared_request_identity"] is not None
        and document["declared_request_identity"] != recomputed_request_identity
    ):
        return refused(
            "request_identity_mismatch",
            str(document["declared_request_identity"]),
            "declared identity does not match " + recomputed_request_identity,
            recomputed,
            args,
        )
    recheck = not args.no_recheck
    try:
        classification = classify(body, args.repo, args.evidence_root, recheck)
    except Unobservable:
        raise
    except Exception as error:
        raise Unobservable(
            "envelope_unreadable",
            "envelope body is structurally malformed: " + str(error),
            str(path),
        )
    if not recheck:
        # An explicit, recorded declination. It can never reach review-ready,
        # because the bytes behind the bound digests were not looked at.
        classification["unobserved"].append(
            {
                "code": "evidence_recheck_declined",
                "subject": str(path),
                "detail": "validation was told not to re-read the evidence bytes",
            }
        )
        if classification["readiness"] == "REVIEW_READY":
            classification["readiness"] = "COULD_NOT_OBSERVE"
            classification["result"] = "NO_VERIFIER_RAN"
            classification["reason"] = "verification_incomplete"
    return emit(classification, args)


def main(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command")
    parser.add_argument("--repo")
    parser.add_argument("--inputs")
    parser.add_argument("--out")
    parser.add_argument("--envelope")
    parser.add_argument("--predecessor")
    parser.add_argument("--evidence-root", dest="evidence_root")
    parser.add_argument("--no-evidence-recheck", dest="no_recheck", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--summary-out", dest="summary_out")
    args = parser.parse_args(argv)

    if args.command == "schema":
        print(json.dumps(CATALOG, indent=2, sort_keys=True))
        return 0
    if args.command == "docs":
        sys.stdout.write(render_docs())
        return 0

    try:
        if args.command == "prepare":
            return command_prepare(args)
        if args.command == "validate":
            return command_validate(args)
        if args.command == "show":
            document, _, _, _ = read_envelope(args.envelope, "envelope_unreadable")
            print(json.dumps(document, indent=2, sort_keys=True))
            return 0
    except Unobservable as error:
        return unobservable(error, args)

    sys.stderr.write("fm-review-envelope: unknown command: " + str(args.command) + "\n")
    return 2


sys.exit(main(sys.argv[1:]))
PY
}
