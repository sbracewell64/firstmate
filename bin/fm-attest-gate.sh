#!/usr/bin/env bash
# The ACCEPTANCE RUNNER for the "PR must be raised via no-mistakes" check: the
# program that addresses the repositories the evidence lives in, states which
# policy generation is judging, sequences the verify/reconcile evaluation, and
# speaks the contributor-facing error model. It exists as a script in bin/ so
# that ALL of that - the control flow, not only the verifier payload - is owned
# by the governed policy generation and arrives at the check from it.
#
# Browser Sol 19/5431020714 requires that an acceptance gate never let the
# candidate under judgment supply the executable semantics that decide whether
# that candidate satisfies the gate, and the exact-head REVISE on PR #134
# (SOL-FM-NO-MISTAKES-PR134-EXACT-HEAD-REVIEW-C2E00EE-20260830) found that
# protecting bin/fm-attest.sh alone left the workflow wrapper - the code that
# selects, sequences, or could bypass the verifier - in candidate hands. This
# script is that wrapper, extracted so it can be taken from the policy
# generation exactly like the verifier: on a `pull_request_target` event the
# workflow file itself comes from the governed branch and runs this script out
# of its own checkout, and on the transitional `pull_request` leg the workflow
# fetches the governed generation and runs THIS SCRIPT FROM THE FETCHED
# GENERATION, never from the candidate tree.
#
# The verifier is this script's SIBLING fm-attest.sh - the same generation's,
# by construction, because the workflow extracts the governed generation's
# whole bin/. A gate assembled from two generations is a third generation
# nobody reviewed, and this script refuses to be part of one: it runs only the
# fm-attest.sh beside itself.
#
# Inputs, all environment because the caller is a workflow step:
#   HEAD_SHA     the pull request head under judgment - DATA, never executed
#   HEAD_REPO    owner/name holding that head (the attestation's repository)
#   BASE_REPO    owner/name of the governed venue holding refs/pull/*
#   PR_NUMBER    the pull request number at BASE_REPO
#   PR_AUTHOR    login named in contributor-facing guidance
#   GH_TOKEN     the job's token; put into the base URL exactly as the
#                workflow's addressing step always has, and never printed
#   FM_GATE_POLICY_SHA  the policy generation stated in this log; informative
#
# Exit 0: the head carries a verified attestation. Exit 1: the check is red,
# in one of the two distinct voices below - a REFUSAL (evidence examined and
# found wanting) or a NO-VERDICT (the gate could not look) - which are never
# collapsed, because collapsing evidence never examined into "no evidence" is
# the defect the whole check exists to remove.
set -eu

fail_env() {
  echo "::error::$1" >&2
  exit 1
}

[ -n "${HEAD_SHA:-}" ] || fail_env "The acceptance gate was given no head commit to judge."

# Exactly one owner/name path: one slash, neither end bare, no doubled slash,
# and nothing outside the character set a repository path may carry. Each
# property is its own case so no arm shadows another.
repo_path_shaped() {  # <candidate>
  case $1 in '') return 1 ;; esac
  case $1 in *//*) return 1 ;; esac
  case $1 in */*/*) return 1 ;; esac
  case $1 in /*) return 1 ;; esac
  case $1 in */) return 1 ;; esac
  case $1 in */*) return 0 ;; esac
  return 1
}

case "${HEAD_REPO:-}" in
  *[!A-Za-z0-9._/-]*)
    fail_env "The pull request head repository name is not a usable repository path."
    ;;
esac
repo_path_shaped "${HEAD_REPO:-}" \
  || fail_env "The pull request head repository is unavailable, so its attestation cannot be read."
case "${BASE_REPO:-}" in
  *[!A-Za-z0-9._/-]*)
    fail_env "The governed base repository name is not a usable repository path."
    ;;
esac
repo_path_shaped "${BASE_REPO:-}" \
  || fail_env "The governed base repository name is not a usable repository path."

# The attestation is published to the head repository; refs/pull/* lives in
# the base repository, which is why these are two remotes even when they are
# one repository. The base is addressed through an explicit token URL; a fork
# through its plain https URL. Every remote call is made with output
# suppressed, because a URL embedding the token is quoted back by git in its
# own errors; Actions redacts it from logs, which makes this defence in depth.
if [ "${HEAD_REPO}" = "${BASE_REPO}" ] && [ -n "${GH_TOKEN:-}" ]; then
  attestation_url="https://x-access-token:${GH_TOKEN}@github.com/${HEAD_REPO}.git"
else
  attestation_url="https://github.com/${HEAD_REPO}.git"
fi
if [ -n "${GH_TOKEN:-}" ]; then
  pullrequest_url="https://x-access-token:${GH_TOKEN}@github.com/${BASE_REPO}.git"
else
  pullrequest_url="https://github.com/${BASE_REPO}.git"
fi
git remote add attestation-source "$attestation_url" >/dev/null 2>&1 \
  || git remote set-url attestation-source "$attestation_url" >/dev/null 2>&1
git remote add pullrequest-source "$pullrequest_url" >/dev/null 2>&1 \
  || git remote set-url pullrequest-source "$pullrequest_url" >/dev/null 2>&1
echo "Reading the attestation from ${HEAD_REPO} and the pull request head from ${BASE_REPO}."

# The verifier is the sibling of this script, and this script states which
# generation both came from. An unusable sibling is could-not-observe - never
# a pass, and never a reason to go looking for another copy, least of all the
# candidate's.
gate_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verifier="$gate_dir/fm-attest.sh"
if [ ! -f "$verifier" ]; then
  {
    echo "::error::This check could not obtain the authoritative no-mistakes verifier, so it reached no verdict."
    echo
    echo "The policy generation this gate ran from (${FM_GATE_POLICY_SHA:-unstated}) carries no"
    echo "bin/fm-attest.sh beside its acceptance gate. Nothing here says anything about"
    echo "whether this head carries an attestation, and this check will not fall back to"
    echo "the copy in the pull request: a candidate may not supply the program that"
    echo "decides whether to accept it."
    echo
    echo "PR author: ${PR_AUTHOR:-unknown}"
  } >&2
  exit 1
fi
if ! bash "$verifier" --supports reconcile >/dev/null 2>&1; then
  {
    echo "::error::This check could not obtain the authoritative no-mistakes verifier, so it reached no verdict."
    echo
    echo "The policy generation ${FM_GATE_POLICY_SHA:-unstated} does not support the reconcile"
    echo "contract this gate requires. That is an unsupported version combination, which is"
    echo "could-not-observe: it says nothing about the evidence, and this check will not"
    echo "fall back to the candidate's copy of the verifier."
    echo
    echo "PR author: ${PR_AUTHOR:-unknown}"
  } >&2
  exit 1
fi
echo "Judging with ${BASE_REPO} policy generation ${FM_GATE_POLICY_SHA:-unstated}; the candidate supplies neither the verifier nor the control flow that runs it."

# A genuinely pipeline-raised head is pushed before its attestation exists, so
# this check's first look at one can be a near miss rather than anything about
# the change. `reconcile` re-reads the ref for a short bounded window while -
# and only while - no attestation for this head has arrived, and then reaches
# its verdict through `verify`. The window is for absence: evidence already
# seen to be invalid, unbound or unreadable is refused on the first look.
verify_rc=0
bash "$verifier" reconcile --head "$HEAD_SHA" \
  --remote attestation-source \
  --pr "$PR_NUMBER" --pr-remote pullrequest-source || verify_rc=$?
if [ "$verify_rc" -eq 0 ]; then
  exit 0
fi
if [ "$verify_rc" -ne 1 ]; then
  {
    echo "::error::This check could not evaluate the no-mistakes attestation for its head commit."
    echo
    echo "bin/fm-attest.sh exited ${verify_rc}, which is not a verdict on the evidence."
    echo "It reached no conclusion, so this says nothing about whether this head carries"
    echo "an attestation: it says the check was unable to look. Do not read it as an"
    echo "absent attestation, and do not publish one expecting it to clear this."
    echo
    echo "The lines above name the cause in the verifier's own words. What reaches"
    echo "here is a repository or a ref this gate could not read, which is a question"
    echo "that went unanswered rather than an answer, and re-running this run is the"
    echo "repair."
    echo
    echo "It is not something to repair in the pull request. Both the verifier and this"
    echo "gate run from the governed policy generation (${FM_GATE_POLICY_SHA:-unstated}), so"
    echo "neither the age of this head nor anything it changes under .github/ or bin/"
    echo "can cause or clear this outcome."
    echo
    echo "The check fails, because a check that could not look must not report a pass."
    echo
    echo "See docs/no-mistakes-attestation.md for the error model these exits belong to."
    echo
    echo "PR author: ${PR_AUTHOR:-unknown}"
  } >&2
  exit 1
fi
{
  echo "::error::This pull request carries no verified no-mistakes attestation for its head commit."
  echo
  echo "Contributions to this repository must be validated by 'git push no-mistakes',"
  echo "which reviews, tests and lints the change before it is pushed. The proof of"
  echo "that is a git note on refs/notes/no-mistakes naming the exact commit it covers:"
  echo
  bash "$verifier" --print-format | sed 's/^/    /'
  echo
  echo "Publish it for the head under review with:"
  echo
  echo "    bin/fm-attest.sh write --publish-repo github.com/${HEAD_REPO}"
  echo
  echo "--publish-repo names the repository the note is published to. It is required"
  echo "because the attestation is evidence only on the repository holding this head,"
  echo "and a remote name in a local checkout is configuration rather than authority"
  echo "over which repository that is."
  echo
  echo "It reads the pipeline's own run record and refuses unless that run validated"
  echo "this exact commit, so it cannot be satisfied by editing text. A new commit is"
  echo "a new head and needs its own attestation."
  echo
  echo "If it refuses because no pipeline run validated this commit, then nothing has"
  echo "validated this head and no attestation for it can exist yet."
  echo "Publishing is not the repair, and repeating it will not become one."
  echo "Validate this head first with 'git push no-mistakes', then publish the"
  echo "attestation for the head that run pushed."
  echo "Do not add a commit merely to restart this check: that advances the head past"
  echo "the one the last run validated, and this check refuses the new head for the"
  echo "same reason as the old one."
  echo
  echo "Publishing the note does not re-run this check by itself. refs/notes/no-mistakes"
  echo "is not a pull request head, so pushing it fires no pull request event of its own."
  echo "That gap is why 'bin/fm-attest.sh write' re-runs the run that judged this head as"
  echo "its last step: the same event replays against the same head commit, and because"
  echo "the verdict is bound to that commit an unchanged head simply re-derives its"
  echo "result from the evidence now present. Publishing an attestation converges here"
  echo "on its own, and nothing about this pull request needs editing to make it."
  echo
  echo "If that step reported that it could not reach GitHub Actions, nothing has re-read"
  echo "this head yet. It says so in its own words, and the two causes are gh missing or"
  echo "unauthenticated, and no write access to this repository's Actions - which the"
  echo "author of a pull request raised from a fork does not hold on the parent. In that"
  echo "case re-run this workflow run from the Actions tab, or ask someone who holds that"
  echo "access to. Do not publish the attestation again: it names this commit already."
  echo
  echo "See CONTRIBUTING.md for setup and docs/no-mistakes-attestation.md for what"
  echo "this check does and does not establish."
  echo
  echo "PR author: ${PR_AUTHOR:-unknown}"
} >&2
exit 1
