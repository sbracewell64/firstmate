#!/usr/bin/env bash
# Tests for bin/fm-review-envelope.sh and bin/fm-review-envelope-lib.sh, the
# review-envelope/v1 contract, its compiler and its classifier.
#
# The envelope exists to make four specific defects arithmetic instead of
# noticed: a green computed against a base far behind the trunk, evidence
# citing a head that has since moved, a transcript proving one commit while
# claiming another, and a generic CI run cited for a dimension its gate never
# invoked. So most cases here are refusals, and each one is arranged so that a
# compiler which trusted what it was told would return REVIEW_READY. The
# assertion in each case is that this one does not.
#
# The scripts under test are resolvable through FM_REVIEW_ENVELOPE_BIN so the
# same controls can be re-run against a deliberately defective build to watch
# them go red. A defect build is a copy of BOTH bin/fm-review-envelope.sh and
# bin/fm-review-envelope-lib.sh into one scratch directory with exactly one
# edit, because the entrypoint sources its library from its own directory;
# docs/verification/review-envelope-controls.md records those runs.
set -u
export FM_TEST_IDENTITY_CONTRACT=1

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

BIN=${FM_REVIEW_ENVELOPE_BIN:-$ROOT/bin/fm-review-envelope.sh}
TMP_ROOT=$(fm_test_tmproot fm-review-envelope-tests)

# --- fixtures ---------------------------------------------------------------

# A repository with a trunk, a base on it, and a candidate branch that touches
# one path under bin/ and one under docs/. Returns the case directory.
make_case() {
  # Declared one per line on purpose: bash expands every right-hand side of a
  # single `local` before assigning any of them, so a chained form would build
  # these paths from an unset name.
  local name=$1
  local case_dir=$TMP_ROOT/$name
  local repo=$case_dir/repo
  # Every fixture command writes to stderr, because this function's stdout is
  # the case path a caller captures. A git command that unexpectedly prints -
  # `nothing to commit` is the one that bit here - would otherwise be prepended
  # to that path and passed to `git -C`, which is how a fixture helper turns a
  # small mistake into a command aimed somewhere unintended.
  {
    mkdir -p "$repo" "$case_dir/evidence" "$case_dir/fakebin"
    git -C "$repo" init -q -b main
    printf 'root\n' > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -qm root
    mkdir -p "$repo/src"
    printf 'base\n' > "$repo/src/base.txt"
    git -C "$repo" add src/base.txt
    git -C "$repo" commit -qm base
    git -C "$repo" checkout -q -b candidate
    mkdir -p "$repo/bin" "$repo/docs"
    printf 'tool\n' > "$repo/bin/tool.sh"
    printf 'notes\n' > "$repo/docs/notes.md"
    git -C "$repo" add bin/tool.sh docs/notes.md
    git -C "$repo" commit -qm candidate
    # A branch off the root that the candidate does not descend from, so a case
    # can measure a contribution from a base outside its own ancestry.
    git -C "$repo" checkout -q -b sidecar main~1
    printf 'side\n' > "$repo/side.txt"
    git -C "$repo" add side.txt
    git -C "$repo" commit -qm sidecar
    git -C "$repo" checkout -q main

    printf 'verifier output for repo-baseline\n' > "$case_dir/evidence/baseline.log"
    printf 'observed failure for repo-baseline\n' > "$case_dir/evidence/baseline-red.log"
    printf 'verifier output for shell-surface\n' > "$case_dir/evidence/shell.log"
    printf 'observed failure for shell-surface\n' > "$case_dir/evidence/shell-red.log"
    printf 'obligation discharge evidence\n' > "$case_dir/evidence/discharge.log"

    write_probe "$case_dir/fakebin/fm-probe-alpha" 'fm-probe-alpha 1.0.0'
  } >&2
  printf '%s\n' "$case_dir"
}

# A declared executable candidate that states its own identity, or refuses to.
write_probe() {  # <path> <identity-line> [exit-code]
  local path=$1 identity=$2 code=${3:-0}
  cat > "$path" <<EOF
#!/usr/bin/env bash
echo "${identity}"
exit ${code}
EOF
  chmod +x "$path"
}

# Write <case>/inputs.json: the baseline document, deep-merged with an optional
# JSON patch. Every SHA and digest in it is read from the fixture rather than
# hard-coded, so a fixture change cannot leave a stale assertion behind.
write_inputs() {  # <case-dir> [patch-json]
  local case_dir=$1
  local patch=${2:-}
  [ -n "$patch" ] || patch='{}'
  python3 - "$case_dir" "$patch" <<'PY'
import hashlib
import json
import subprocess
import sys

case_dir, patch = sys.argv[1], json.loads(sys.argv[2])
repo = case_dir + "/repo"


def rev(ref):
    return subprocess.run(
        ["git", "-C", repo, "rev-parse", "--verify", ref],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


def sha(name):
    with open(case_dir + "/evidence/" + name, "rb") as handle:
        return "sha256:" + hashlib.sha256(handle.read()).hexdigest()


def result(contract, contract_digest, world, log, red):
    return {
        "contract_id": contract,
        "contract_digest": contract_digest,
        "world": world,
        "verifier_id": contract + "-verifier",
        "verifier_digest": "sha256:" + hashlib.sha256(contract.encode()).hexdigest(),
        "result": "PASS",
        "head": rev("candidate"),
        "tree": rev("candidate^{tree}"),
        "evidence": {"locator": log, "sha256": sha(log)},
        "red_calibration": {
            "observed_result": "FAIL",
            "reason": "the verifier was observed failing with the guarded property removed",
            "evidence": {"locator": red, "sha256": sha(red)},
        },
    }


baseline = {
    "schema": "review-envelope-inputs/v1",
    "project": {"id": "fixture-project"},
    "work": {
        "id": "fixture-work",
        "increment": "A1",
        "request": {
            "kind": "change-request",
            "forge": "fixture-forge",
            "id": "42",
            "url": "https://fixture.invalid/project/requests/42",
        },
    },
    "policy": {"version": "review-policy/1", "max_base_behind_main": 0},
    "requested_decision": "SEMANTIC_REVIEW",
    "candidate": {"base_ref": "main", "head_ref": "candidate"},
    "applicability": {"main_ref": "main"},
    "scope": {"excluded": []},
    "verification": {
        "applicability_rules": [
            {"contract_id": "repo-baseline", "mandatory": True},
            {"contract_id": "shell-surface", "paths": [{"type": "glob", "value": "bin/*"}]},
        ],
        "contracts": [
            {"id": "repo-baseline", "version": "1", "digest": "sha256:aa", "execution_worlds": ["offline-ci"]},
            {"id": "shell-surface", "version": "1", "digest": "sha256:bb", "execution_worlds": ["offline-ci"]},
        ],
        "results": [
            result("repo-baseline", "sha256:aa", "offline-ci", "baseline.log", "baseline-red.log"),
            result("shell-surface", "sha256:bb", "offline-ci", "shell.log", "shell-red.log"),
        ],
    },
    "capabilities": [
        {
            "id": "probe",
            "mandatory": True,
            "candidates": ["fm-probe-alpha", "fm-probe-beta"],
            "identity_argv": ["--version"],
        }
    ],
    "ci": {
        "required_platforms": ["linux"],
        "attempts": [
            {
                "name": "test",
                "workflow": "CI",
                "platform": "linux",
                "head": rev("candidate"),
                "order": 100,
                "conclusion": "SUCCESS",
            }
        ],
    },
    "findings": {"adverse": [], "unproven": []},
    "rulings": [],
    "obligations": {
        "predecessor": {"none": True, "reason": "first envelope in this chain"},
        "active": [],
        "dispositions": [],
    },
}


# Objects merge and lists replace, except for the predecessor block: a patch
# that names a predecessor means exactly that predecessor, and merging it into
# the baseline's explicit "none" would leave a case declaring both.
REPLACE_WHOLE = {"predecessor"}


def merge(base, overlay):
    for key, value in overlay.items():
        if key not in REPLACE_WHOLE and isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value


merge(baseline, patch)
with open(case_dir + "/inputs.json", "w", encoding="utf-8") as handle:
    json.dump(baseline, handle, indent=2)
    handle.write("\n")
PY
}

# Substitute the fixture's own resolved SHAs into a patch, so a case can talk
# about the real candidate head without hard-coding one.
resolve() {  # <case-dir> <rev>
  git -C "$1/repo" rev-parse --verify "$2"
}

run_prepare() {  # <case-dir> <out-name> [extra args...]
  local case_dir=$1 out=$2
  shift 2
  PATH="$case_dir/fakebin:$PATH" "$BIN" prepare \
    --repo "$case_dir/repo" \
    --inputs "$case_dir/inputs.json" \
    --evidence-root "$case_dir/evidence" \
    --out "$case_dir/$out" "$@"
}

run_validate() {  # <case-dir> <out-name> [extra args...]
  local case_dir=$1 out=$2
  shift 2
  PATH="$case_dir/fakebin:$PATH" "$BIN" validate \
    --envelope "$case_dir/$out" \
    --repo "$case_dir/repo" \
    --evidence-root "$case_dir/evidence" "$@"
}

# Run and capture without letting a non-zero status stop the suite; the whole
# point of these cases is a non-zero status.
capture() {
  CAPTURED=$("$@" 2>&1)
  CAPTURED_CODE=$?
}

# assert_required_set <envelope> <id>... <message>: the computed required set
# must be exactly the listed ids.
assert_required_set() {
  local envelope=$1
  shift
  local message=${*: -1}
  local expected=("${@:1:$#-1}")
  python3 -c '
import json, sys
envelope, expected = sys.argv[1], sorted(sys.argv[2:])
required = json.load(open(envelope))["envelope"]["verification"]["required_contract_ids"]
if sorted(required) != expected:
    sys.stderr.write("required set is %r, expected %r\n" % (required, expected))
    sys.exit(1)
' "$envelope" "${expected[@]}" || fail "$message"
}

# --- the green baseline -----------------------------------------------------

test_a_complete_candidate_is_review_ready() {
  local case_dir
  case_dir=$(make_case ready)
  write_inputs "$case_dir"
  capture run_prepare "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" "a complete candidate is review-ready"
  assert_contains "$CAPTURED" 'review-envelope: REVIEW_READY' "the readiness must be stated"
  assert_contains "$CAPTURED" '  review-envelope,PASS,verified,' \
    "a review-ready envelope emits a passing verify record"
  assert_present "$case_dir/env/envelope.json" "prepare must write the envelope"

  # The bound facts have to be the repository's, not the inputs'.
  local head tree
  head=$(resolve "$case_dir" candidate)
  tree=$(resolve "$case_dir" 'candidate^{tree}')
  assert_grep "\"head_commit\": \"$head\"" "$case_dir/env/envelope.json" \
    "the envelope must bind the exact candidate commit"
  assert_grep "\"head_tree\": \"$tree\"" "$case_dir/env/envelope.json" \
    "the envelope must bind the exact candidate tree"
  assert_grep '"bin/tool.sh"' "$case_dir/env/envelope.json" \
    "the envelope must bind the changed-file scope"
  assert_grep '"diff_digest"' "$case_dir/env/envelope.json" \
    "the envelope must bind a content identity for the contribution"
  assert_grep '"required_contract_ids"' "$case_dir/env/envelope.json" \
    "the envelope must bind the computed required-contract set"
  pass "a complete candidate compiles to a review-ready envelope binding the repository's own facts"
}

test_required_contracts_are_computed_from_the_changed_files() {
  local case_dir
  case_dir=$(make_case computed-requirements)
  write_inputs "$case_dir"
  run_prepare "$case_dir" env >/dev/null 2>&1
  # Asserted as the exact computed set, not as a substring anywhere in the
  # document: every contract id also appears in the rules and references, so a
  # grep would still match a compiler that required nothing at all.
  assert_required_set "$case_dir/env/envelope.json" repo-baseline shell-surface \
    "a mandatory contract and a contract whose paths changed are both required"

  local other
  other=$(make_case computed-requirements-untouched)
  write_inputs "$other" '{"verification": {"applicability_rules": [
      {"contract_id": "repo-baseline", "mandatory": true},
      {"contract_id": "shell-surface", "paths": [{"type": "glob", "value": "nothing/*"}]}]}}'
  run_prepare "$other" env >/dev/null 2>&1
  assert_required_set "$other/env/envelope.json" repo-baseline \
    "a path-scoped contract whose paths did not change must not be required"
  pass "which contracts are required is computed from the observed changed files"
}

test_identical_facts_produce_an_identical_digest() {
  local case_dir first second
  case_dir=$(make_case idempotent)
  write_inputs "$case_dir"
  run_prepare "$case_dir" one >/dev/null 2>&1
  run_prepare "$case_dir" two >/dev/null 2>&1
  first=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"]["value"])' \
    "$case_dir/one/envelope.json")
  second=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"]["value"])' \
    "$case_dir/two/envelope.json")
  [ -n "$first" ] || fail "the envelope must carry a digest"
  [ "$first" = "$second" ] \
    || fail "unmoved facts must produce one digest, so repeated compilation resolves to one review request"
  # Two compilations inside one second would agree even with a timestamp in the
  # body, so equality alone is not the property. The body is searched directly
  # for any time-shaped value, and the compile time is required to be OUTSIDE it.
  python3 - "$case_dir/one/envelope.json" <<'PY' || fail "nothing time-varying may sit inside the digested body"
import json, re, sys

document = json.load(open(sys.argv[1]))
stamp = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def timestamps(node, trail=""):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from timestamps(value, trail + "." + key)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from timestamps(value, trail + "[%d]" % index)
    elif isinstance(node, str) and stamp.match(node):
        yield trail


found = list(timestamps(document["envelope"], "envelope"))
if found:
    sys.stderr.write("time-varying values inside the digested body: " + ", ".join(found) + "\n")
    sys.exit(1)
if not stamp.match(document.get("compiled_at", "")):
    sys.stderr.write("the outer document must record when it was compiled\n")
    sys.exit(1)
PY
  pass "unmoved facts compile to the identical digest, and no time-varying value sits inside the body"
}

test_order_insensitive_facts_produce_an_identical_identity() {
  local case_dir first_digest second_digest first_identity second_identity
  case_dir=$(make_case canonical-fact-order)
  write_inputs "$case_dir" '{"obligations": {"active": [{"id": "OBL-2"}, {"id": "OBL-1"}]}}'
  capture run_prepare "$case_dir" first
  expect_code 0 "$CAPTURED_CODE" "the first fact order compiles"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["verification"]["contracts"].reverse()
document["verification"]["results"].reverse()
document["obligations"]["active"].reverse()
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" second
  expect_code 0 "$CAPTURED_CODE" "the reordered facts compile"
  read -r first_digest first_identity < <(python3 - "$case_dir/first/envelope.json" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
print(document["digest"]["value"], document["request_identity"])
PY
)
  read -r second_digest second_identity < <(python3 - "$case_dir/second/envelope.json" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
print(document["digest"]["value"], document["request_identity"])
PY
)
  [ "$first_digest" = "$second_digest" ] \
    || fail "order-insensitive facts must have one envelope digest"
  [ "$first_identity" = "$second_identity" ] \
    || fail "order-insensitive facts must have one request identity"
  pass "order-insensitive facts have stable content identities"
}

test_a_structurally_malformed_envelope_is_could_not_observe() {
  local case_dir
  case_dir=$(make_case malformed-stored-envelope)
  write_inputs "$case_dir"
  capture run_prepare "$case_dir" malformed
  expect_code 0 "$CAPTURED_CODE" "the valid precursor envelope compiles"
  python3 - "$case_dir/malformed/envelope.json" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
document = json.load(open(path))
document["envelope"] = {}
canonical = json.dumps(document["envelope"], sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
document["digest"]["value"] = "sha256:" + hashlib.sha256(canonical).hexdigest()
payload = {
    "compiled_at": document.get("compiled_at"),
    "compiler": document.get("compiler"),
    "body_digest": document["digest"]["value"],
    "request_identity": document.get("request_identity"),
    "declared_request_identity": document.get("declared_request_identity"),
}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
document["outer_digest"]["value"] = "sha256:" + hashlib.sha256(canonical).hexdigest()
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
PY
  capture run_validate "$case_dir" malformed
  expect_code 2 "$CAPTURED_CODE" "a structurally malformed body is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved envelope_unreadable' \
    "the readable verify record must name the malformed envelope"
  assert_not_contains "$CAPTURED" 'Traceback' "validation must never end with a structural exception"

  capture run_prepare "$case_dir" unknown-verdict
  expect_code 0 "$CAPTURED_CODE" "the unknown-verdict precursor envelope compiles"
  python3 - "$case_dir/unknown-verdict/envelope.json" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
document = json.load(open(path))
body = document["envelope"]
body["ci"]["checks"][0]["verdict"] = "UNKNOWN"


def digest(value):
    canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return "sha256:" + hashlib.sha256(canonical).hexdigest()


body_digest = digest(body)
project = body["identity"]["project"]
work = body["identity"]["work"]
document["digest"]["value"] = body_digest
document["request_identity"] = digest({
    "project": {"id": project["id"], "root_commits": project["root_commits"]},
    "work": {"id": work["id"], "forge_request": work.get("request")},
    "candidate_head_commit": body["candidate"]["head_commit"],
    "envelope_digest": body_digest,
    "policy_version": body["identity"]["policy"]["version"],
})
document["outer_digest"]["value"] = digest({
    "compiled_at": document.get("compiled_at"),
    "compiler": document.get("compiler"),
    "body_digest": body_digest,
    "request_identity": document.get("request_identity"),
    "declared_request_identity": document.get("declared_request_identity"),
})
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
PY
  capture run_validate "$case_dir" unknown-verdict
  expect_code 2 "$CAPTURED_CODE" "an unknown stored verdict is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved envelope_unreadable' \
    "the readable verify record must classify every structural failure"
  assert_not_contains "$CAPTURED" 'Traceback' "an unknown verdict must never escape as an exception"
  pass "a structurally malformed envelope emits a readable could-not-observe record"
}

# --- staleness --------------------------------------------------------------

test_a_stale_envelope_refuses() {
  local case_dir
  case_dir=$(make_case stale)
  write_inputs "$case_dir"
  run_prepare "$case_dir" env >/dev/null 2>&1
  capture run_validate "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" "the envelope must validate before the candidate moves"

  git -C "$case_dir/repo" checkout -q candidate
  printf 'more\n' >> "$case_dir/repo/bin/tool.sh"
  git -C "$case_dir/repo" commit -qam "candidate moves"
  git -C "$case_dir/repo" checkout -q main

  capture run_validate "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a stale envelope refuses"
  assert_contains "$CAPTURED" 'refusal candidate_head_moved' \
    "the refusal must name the moved candidate"
  assert_contains "$CAPTURED" '  review-envelope,FAIL,verifier_reported_failure,' \
    "a refusal emits a failing verify record"
  pass "an envelope whose candidate has moved refuses instead of certifying stale bytes"
}

test_a_base_that_falls_behind_the_trunk_refuses() {
  local case_dir
  case_dir=$(make_case behind)
  write_inputs "$case_dir"
  run_prepare "$case_dir" env >/dev/null 2>&1
  printf 'advance\n' > "$case_dir/repo/src/advance.txt"
  git -C "$case_dir/repo" add src/advance.txt
  git -C "$case_dir/repo" commit -qm "trunk advances"
  capture run_validate "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a base that trails the trunk beyond policy refuses"
  assert_contains "$CAPTURED" 'refusal base_behind_main_exceeds_policy' \
    "the refusal must name the policy bound it exceeded"
  pass "a green computed against a base the trunk has moved past refuses"
}

test_an_asserted_head_the_repository_contradicts_refuses() {
  local case_dir
  case_dir=$(make_case asserted-head)
  write_inputs "$case_dir" '{"candidate": {"head_commit": "0000000000000000000000000000000000000000"}}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a head asserted in prose that the repository contradicts refuses"
  assert_contains "$CAPTURED" 'refusal declared_head_mismatch' \
    "the refusal must name the contradicted assertion"
  pass "a head asserted by the inputs is checked against the repository rather than believed"
}

test_a_tampered_envelope_body_refuses() {
  local case_dir
  case_dir=$(make_case tampered)
  write_inputs "$case_dir"
  run_prepare "$case_dir" env >/dev/null 2>&1
  python3 - "$case_dir/env/envelope.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["envelope"]["identity"]["requested_decision"] = "LANDING_AUTHORIZATION"
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
PY
  capture run_validate "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "an edited envelope body refuses"
  assert_contains "$CAPTURED" 'refusal envelope_digest_mismatch' \
    "the refusal must name the broken content address"
  pass "an envelope edited after compilation refuses rather than carrying the edit"
}

test_an_envelope_is_written_once() {
  local case_dir
  case_dir=$(make_case write-once)
  write_inputs "$case_dir"
  run_prepare "$case_dir" env >/dev/null 2>&1
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "overwriting an envelope is could-not-observe"
  assert_contains "$CAPTURED" 'envelope_exists' "the refusal must name the occupied output"
  pass "an envelope is written once, so a superseded generation cannot silently become the current one"
}

# --- verification contracts and their evidence ------------------------------

test_a_missing_required_contract_refuses() {
  local case_dir
  case_dir=$(make_case missing-contract)
  write_inputs "$case_dir" '{"verification": {"contracts": [
      {"id": "repo-baseline", "version": "1", "digest": "sha256:aa", "execution_worlds": ["offline-ci"]}]}}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a required contract with no reference refuses"
  assert_contains "$CAPTURED" 'refusal missing_required_verification_contract' \
    "the refusal must name the missing contract"
  assert_contains "$CAPTURED" 'shell-surface' "the refusal must identify which contract"
  pass "a contract the changed files require, with no reference in the envelope, refuses"
}

test_a_missing_required_verifier_result_refuses() {
  local case_dir
  case_dir=$(make_case missing-result)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
results = document["verification"]["results"]
document["verification"]["results"] = [r for r in results if r["contract_id"] != "shell-surface"]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a required contract with no result refuses"
  assert_contains "$CAPTURED" 'refusal missing_required_verifier_result' \
    "the refusal must name the uncovered world"
  pass "a required verification contract with no verifier result refuses"
}

test_verifier_results_bind_the_selected_contract_digest() {
  local case_dir variant
  for variant in missing mismatched; do
    case_dir=$(make_case "result-contract-digest-$variant")
    write_inputs "$case_dir"
    python3 - "$case_dir/inputs.json" "$variant" <<'PY'
import json, sys
path, variant = sys.argv[1:]
document = json.load(open(path))
result = document["verification"]["results"][1]
if variant == "missing":
    del result["contract_digest"]
else:
    result["contract_digest"] = "sha256:stale"
json.dump(document, open(path, "w"), indent=2)
PY
    capture run_prepare "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "$variant contract digest binding refuses during prepare"
    assert_contains "$CAPTURED" 'refusal verification_result_contract_mismatch' \
      "the refusal must name the result-to-contract mismatch"
    capture run_validate "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "$variant contract digest binding refuses during validate"
    assert_contains "$CAPTURED" 'refusal verification_result_contract_mismatch' \
      "validation must preserve the result-to-contract mismatch"
  done
  pass "verifier results require the selected contract's exact digest"
}

test_duplicate_contract_ids_are_ambiguous() {
  local case_dir variant
  for variant in identical conflicting; do
    case_dir=$(make_case "duplicate-contract-$variant")
    write_inputs "$case_dir"
    python3 - "$case_dir/inputs.json" "$variant" <<'PY'
import json, sys
path, variant = sys.argv[1:]
document = json.load(open(path))
duplicate = dict(document["verification"]["contracts"][0])
if variant == "conflicting":
    duplicate["digest"] = "sha256:conflicting"
document["verification"]["contracts"].append(duplicate)
json.dump(document, open(path, "w"), indent=2)
PY
    capture run_prepare "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "$variant duplicate contract id refuses during prepare"
    assert_contains "$CAPTURED" 'refusal verification_contract_id_ambiguous' \
      "the refusal must name the ambiguous stable contract id"
    capture run_validate "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "$variant duplicate contract id refuses during validate"
    assert_contains "$CAPTURED" 'refusal verification_contract_id_ambiguous' \
      "validation must preserve the ambiguous stable contract id"
  done
  pass "duplicate verification contract ids refuse independently of content"
}

test_forge_request_identity_is_required_and_complete() {
  local case_dir variant
  for variant in absent missing-forge empty-url missing-id; do
    case_dir=$(make_case "forge-request-$variant")
    write_inputs "$case_dir"
    python3 - "$case_dir/inputs.json" "$variant" <<'PY'
import json, sys
path, variant = sys.argv[1:]
document = json.load(open(path))
if variant == "absent":
    del document["work"]["request"]
elif variant == "missing-forge":
    del document["work"]["request"]["forge"]
elif variant == "empty-url":
    document["work"]["request"]["url"] = ""
else:
    del document["work"]["request"]["id"]
json.dump(document, open(path, "w"), indent=2)
PY
    capture run_prepare "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "$variant forge request identity refuses during prepare"
    assert_contains "$CAPTURED" 'refusal forge_request_identity_invalid' \
      "the refusal must name the invalid authoritative forge request identity"
    capture run_validate "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "$variant forge request identity refuses during validate"
    assert_contains "$CAPTURED" 'refusal forge_request_identity_invalid' \
      "validation must preserve the forge request identity refusal"
  done
  pass "authoritative forge request identity is required and structurally validated"
}

test_a_verifier_result_bound_to_another_head_refuses() {
  local case_dir
  case_dir=$(make_case verifier-wrong-head)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["verification"]["results"][1]["head"] = "1" * 40
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a result bound to another head refuses"
  assert_contains "$CAPTURED" 'refusal required_verifier_wrong_head' \
    "the refusal must name the foreign head"
  pass "a verifier result citing a head that is not the candidate refuses"
}

test_a_verifier_result_without_a_tree_refuses() {
  local case_dir
  case_dir=$(make_case verifier-missing-tree)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
del document["verification"]["results"][1]["tree"]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a result without a tree refuses"
  assert_contains "$CAPTURED" 'refusal required_verifier_wrong_head' \
    "the refusal must name the absent tree binding"
  capture run_validate "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "validation preserves the missing tree refusal"
  assert_contains "$CAPTURED" 'refusal required_verifier_wrong_head' \
    "validation must require the exact tree binding"
  pass "a required verifier result must bind the candidate tree"
}

test_a_missing_red_calibration_refuses() {
  local case_dir
  case_dir=$(make_case no-calibration)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
del document["verification"]["results"][1]["red_calibration"]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a passing verifier never observed failing refuses"
  assert_contains "$CAPTURED" 'refusal missing_red_calibration' \
    "the refusal must name the uncalibrated verifier"
  pass "a required verifier that passed but was never watched red refuses"
}

test_a_red_calibration_that_records_a_pass_refuses() {
  local case_dir
  case_dir=$(make_case calibration-not-red)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["verification"]["results"][1]["red_calibration"]["observed_result"] = "PASS"
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a calibration that never went red refuses"
  assert_contains "$CAPTURED" 'refusal red_calibration_not_adverse' \
    "the refusal must say the calibration recorded no failure"
  pass "a red calibration that records anything but an observed failure refuses"
}

test_a_could_not_observe_verifier_cannot_become_review_ready() {
  local case_dir
  case_dir=$(make_case cno-verifier)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["verification"]["results"][1]["result"] = "COULD_NOT_OBSERVE"
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "a could-not-observe verifier is not a pass"
  assert_contains "$CAPTURED" 'review-envelope: COULD_NOT_OBSERVE' \
    "the readiness must be could-not-observe"
  assert_contains "$CAPTURED" 'unobserved required_verifier_unproven' \
    "the unobserved dimension must be named"
  assert_not_contains "$CAPTURED" 'REVIEW_READY' "could-not-observe must never reach review-ready"
  pass "a required verifier that could not observe cannot reach review-ready"
}

test_a_broken_evidence_digest_refuses() {
  local case_dir
  case_dir=$(make_case evidence-digest)
  write_inputs "$case_dir"
  printf 'the bytes moved after the digest was taken\n' > "$case_dir/evidence/shell.log"
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "evidence that no longer matches its digest refuses"
  assert_contains "$CAPTURED" 'refusal evidence_digest_mismatch' \
    "the refusal must name the broken binding"
  pass "evidence whose bytes no longer match the digest bound to them refuses"
}

test_an_evidence_locator_that_escapes_its_root_refuses() {
  local case_dir
  case_dir=$(make_case evidence-escape)
  # The escaped target must EXIST and its digest must MATCH, or the refusal
  # would come from the file being missing and the traversal guard itself would
  # never be reached - a control that looks like evidence and measures nothing.
  printf 'bytes that live outside the evidence root\n' > "$case_dir/outside.log"
  write_inputs "$case_dir"
  python3 - "$case_dir" <<'PY'
import hashlib, json, sys
case_dir = sys.argv[1]
path = case_dir + "/inputs.json"
document = json.load(open(path))
digest = "sha256:" + hashlib.sha256(open(case_dir + "/outside.log", "rb").read()).hexdigest()
document["verification"]["results"][1]["evidence"] = {
    "locator": "../outside.log",
    "sha256": digest,
}
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a locator escaping its evidence root refuses"
  assert_contains "$CAPTURED" 'refusal evidence_locator_broken' \
    "the refusal must name the broken locator"
  assert_contains "$CAPTURED" 'escapes its root' \
    "the refusal must be about the traversal, not about a file that happened to be missing"
  pass "an evidence locator that reaches outside its root refuses rather than being followed"
}

test_an_evidence_symlink_that_escapes_its_root_refuses_before_reading() {
  local case_dir
  case_dir=$(make_case evidence-symlink-escape)
  printf 'external bytes that must not be read\n' > "$case_dir/outside.log"
  ln -s "$case_dir/outside.log" "$case_dir/evidence/linked.log"
  write_inputs "$case_dir"
  python3 - "$case_dir" <<'PY'
import hashlib, json, sys
case_dir = sys.argv[1]
path = case_dir + "/inputs.json"
document = json.load(open(path))
digest = "sha256:" + hashlib.sha256(open(case_dir + "/outside.log", "rb").read()).hexdigest()
document["verification"]["results"][1]["evidence"] = {
    "locator": "linked.log",
    "sha256": digest,
}
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a symlink outside the evidence root refuses"
  assert_contains "$CAPTURED" 'refusal evidence_locator_broken' \
    "the refusal must name the escaped evidence locator"
  python3 - "$case_dir/env/envelope.json" <<'PY' \
    || fail "escaped evidence must refuse before any bytes are read or digested"
import json, sys
block = json.load(open(sys.argv[1]))["envelope"]["verification"]["results"][1]["evidence"]
if block.get("resolved") or "observed_sha256" in block or "matches" in block:
    sys.exit(1)
PY
  pass "a symlink cannot carry evidence outside its root into the envelope"
}

test_a_result_that_does_not_identify_its_verifier_refuses() {
  local case_dir
  case_dir=$(make_case unpinned-verifier)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
del document["verification"]["results"][1]["verifier_digest"]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a result that does not identify what produced it refuses"
  assert_contains "$CAPTURED" 'refusal verifier_identity_unpinned' \
    "the refusal must say the verifier is not identified"
  pass "a verifier result with no pinned verifier identity refuses"
}

# --- continuous integration -------------------------------------------------

test_wrong_head_ci_refuses() {
  local case_dir
  case_dir=$(make_case ci-wrong-head)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["ci"]["attempts"][0]["head"] = "2" * 40
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a required platform covered only by another head's run refuses"
  assert_contains "$CAPTURED" 'refusal ci_wrong_head' "the refusal must name the foreign head"
  assert_contains "$CAPTURED" '2222222222222222222222222222222222222222' \
    "the refusal must show which head the run actually covered"
  pass "a CI run against a head that is not the candidate cannot cover a required platform"
}

test_a_skipped_required_check_refuses() {
  local case_dir
  case_dir=$(make_case ci-skipped)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["ci"]["attempts"][0]["conclusion"] = "SKIPPED"
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a skipped required check refuses"
  assert_contains "$CAPTURED" 'refusal ci_required_check_skipped' \
    "the refusal must name the skipped platform"
  pass "a required check that was skipped refuses rather than reading as clean"
}

test_an_absent_required_platform_refuses() {
  local case_dir
  case_dir=$(make_case ci-absent)
  write_inputs "$case_dir" '{"ci": {"required_platforms": ["linux", "windows"]}}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a required platform with no check at all refuses"
  assert_contains "$CAPTURED" 'refusal ci_required_platform_uncovered' \
    "the refusal must name the uncovered platform"
  assert_contains "$CAPTURED" 'windows' "the refusal must say which platform"
  pass "an empty check set for a required platform refuses, because absence is never green"
}

test_a_pending_required_check_is_could_not_observe() {
  local case_dir
  case_dir=$(make_case ci-pending)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["ci"]["attempts"][0]["conclusion"] = ""
document["ci"]["attempts"][0]["status"] = "IN_PROGRESS"
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "a check still running has reached no verdict"
  assert_contains "$CAPTURED" 'unobserved ci_required_check_pending' \
    "a running check is could-not-observe, not a failure and not a pass"
  pass "a required check that has not completed is could-not-observe rather than either verdict"
}

test_duplicate_attempts_with_no_ordering_refuse() {
  local case_dir
  case_dir=$(make_case ci-undecidable)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
first = document["ci"]["attempts"][0]
second = dict(first)
second["conclusion"] = "FAILURE"
del second["order"]
document["ci"]["attempts"] = [first, second]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "attempts that cannot be ordered refuse"
  assert_contains "$CAPTURED" 'refusal ci_duplicate_attempt_undecidable' \
    "the refusal must name the check whose current attempt is undecidable"
  pass "repeated attempts at one check with no usable ordering refuse rather than picking one"
}

test_a_superseded_failure_is_replaced_by_its_later_rerun() {
  local case_dir
  case_dir=$(make_case ci-rerun)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
current = document["ci"]["attempts"][0]
earlier = dict(current)
earlier["conclusion"] = "FAILURE"
earlier["order"] = 50
document["ci"]["attempts"] = [current, earlier]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" "a superseded failure must not block its own successful rerun"
  pass "an earlier failing attempt is superseded by the later attempt at the same check"
}

test_two_workflows_sharing_a_check_name_stay_two_checks() {
  local case_dir
  case_dir=$(make_case ci-two-workflows)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
passing = document["ci"]["attempts"][0]
failing = dict(passing)
failing["workflow"] = "Release"
failing["conclusion"] = "FAILURE"
# Deliberately EARLIER than the passing attempt, so a reduction that keyed on
# the name alone would fold them together and let the later pass supersede a
# failure that belongs to a different workflow entirely.
failing["order"] = 50
document["ci"]["attempts"] = [passing, failing]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "one workflow's pass must not mask another workflow's failure"
  assert_contains "$CAPTURED" 'refusal ci_required_check_failing' \
    "the failing workflow's check must still refuse"
  pass "two workflows sharing one job name stay two checks, so neither masks the other"
}

# --- code-owned executable resolution ---------------------------------------

test_alias_fallback_resolves_a_later_declared_candidate() {
  local case_dir
  case_dir=$(make_case alias-fallback)
  rm -f "$case_dir/fakebin/fm-probe-alpha"
  write_probe "$case_dir/fakebin/fm-probe-beta" 'fm-probe-beta 2.5.1'
  write_inputs "$case_dir"
  capture run_prepare "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" \
    "a capability whose first alias is absent and whose second is present is observed, not could-not-observe"
  # The whole point of the control: the SELECTED path and the DIRECTLY OBSERVED
  # identity, not merely that something was found.
  assert_grep '"candidate": "fm-probe-beta"' "$case_dir/env/envelope.json" \
    "the later declared alias must be the selected candidate"
  assert_grep '"identity": "fm-probe-beta 2.5.1"' "$case_dir/env/envelope.json" \
    "the envelope must bind the identity the executable itself stated"
  assert_grep '"outcome": "absent"' "$case_dir/env/envelope.json" \
    "the absent first alias must be recorded, so the search is inspectable"
  pass "a required executable resolves through its complete candidate set, not just the first alias"
}

test_an_exhausted_candidate_set_is_could_not_observe() {
  local case_dir
  case_dir=$(make_case alias-exhausted)
  rm -f "$case_dir/fakebin/fm-probe-alpha"
  write_inputs "$case_dir"
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "an exhausted candidate set is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved capability_unresolved' \
    "the unobserved capability must be named"
  assert_contains "$CAPTURED" 'fm-probe-alpha=absent' \
    "the refusal must show every candidate that was evaluated"
  assert_contains "$CAPTURED" 'fm-probe-beta=absent' \
    "could-not-observe is reached only after the declared candidates are exhausted"
  pass "could-not-observe for an executable is reached only after every declared candidate is exhausted"
}

test_a_candidate_that_will_not_state_its_identity_is_not_a_selection() {
  local case_dir
  case_dir=$(make_case alias-silent)
  write_probe "$case_dir/fakebin/fm-probe-alpha" 'unusable' 3
  write_probe "$case_dir/fakebin/fm-probe-beta" 'fm-probe-beta 2.5.1'
  write_inputs "$case_dir"
  capture run_prepare "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" "resolution must continue past a candidate that cannot be identified"
  assert_grep '"outcome": "identity_failed"' "$case_dir/env/envelope.json" \
    "the unusable candidate must be recorded as identity_failed, not as absent"
  assert_grep '"candidate": "fm-probe-beta"' "$case_dir/env/envelope.json" \
    "the next candidate must be selected"
  pass "an executable that exists but will not state its identity is not a selection"
}

# --- monotonic obligation preservation --------------------------------------

# Compile a predecessor envelope carrying two active obligations, and return
# its digest on stdout.
seed_predecessor() {  # <case-dir>
  local case_dir=$1
  write_inputs "$case_dir" '{"obligations": {"active": [
      {"id": "OBL-1", "statement": "the acceptance requirement must survive a rewrite"},
      {"id": "OBL-2", "statement": "the second requirement must survive too"}]}}'
  PATH="$case_dir/fakebin:$PATH" "$BIN" prepare \
    --repo "$case_dir/repo" --inputs "$case_dir/inputs.json" \
    --evidence-root "$case_dir/evidence" --out "$case_dir/prior" >/dev/null 2>&1
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"]["value"])' \
    "$case_dir/prior/envelope.json"
}

test_a_silently_dropped_obligation_refuses() {
  local case_dir prior
  case_dir=$(make_case obligation-dropped)
  prior=$(seed_predecessor "$case_dir")
  [ -n "$prior" ] || fail "the predecessor envelope must compile"
  # The successor keeps one obligation and simply stops mentioning the other,
  # which is exactly the rewrite this law exists to catch.
  write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [{"id": "OBL-1", "statement": "the acceptance requirement must survive a rewrite"}],
      "dispositions": [{"id": "OBL-1", "disposition": "PRESERVED"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "an obligation that simply disappears refuses"
  assert_contains "$CAPTURED" 'refusal obligation_dropped' \
    "the refusal must name the unaccounted obligation"
  assert_contains "$CAPTURED" 'OBL-2' "the refusal must say which obligation disappeared"
  pass "an obligation that disappears without a disposition blocks advancement"
}

test_every_prior_obligation_may_be_accounted_for_explicitly() {
  local case_dir prior sha
  case_dir=$(make_case obligation-accounted)
  prior=$(seed_predecessor "$case_dir")
  sha=$(python3 -c '
import hashlib, sys
print("sha256:" + hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
' "$case_dir/evidence/discharge.log")
  write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [{"id": "OBL-3", "statement": "the replacement obligation"}],
      "dispositions": [
        {"id": "OBL-1", "disposition": "SATISFIED",
         "evidence": {"locator": "discharge.log", "sha256": "'"$sha"'"}},
        {"id": "OBL-2", "disposition": "SUPERSEDED", "replaced_by": "OBL-3"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 0 "$CAPTURED_CODE" "explicit accounting for every prior obligation advances"
  assert_grep '"OBL-1"' "$case_dir/successor/envelope.json" \
    "the successor must record what happened to the discharged obligation"
  pass "a successor that classifies every prior obligation explicitly is review-ready"
}

test_a_satisfied_obligation_without_evidence_refuses() {
  local case_dir prior
  case_dir=$(make_case obligation-unevidenced)
  prior=$(seed_predecessor "$case_dir")
  write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "SATISFIED"},
        {"id": "OBL-2", "disposition": "SATISFIED"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "satisfaction asserted without evidence refuses"
  assert_contains "$CAPTURED" 'refusal obligation_satisfied_without_evidence' \
    "the refusal must say satisfaction needs named evidence"
  pass "an obligation called satisfied with no named evidence refuses"
}

test_a_preserved_obligation_missing_from_the_active_set_refuses() {
  local case_dir prior
  case_dir=$(make_case obligation-preserved-absent)
  prior=$(seed_predecessor "$case_dir")
  write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [{"id": "OBL-1", "statement": "kept"}],
      "dispositions": [
        {"id": "OBL-1", "disposition": "PRESERVED"},
        {"id": "OBL-2", "disposition": "PRESERVED"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "an obligation called preserved but absent refuses"
  assert_contains "$CAPTURED" 'refusal obligation_preserved_but_absent' \
    "the refusal must name the obligation that was called preserved"
  pass "an obligation called preserved while absent from the active set refuses"
}

test_a_superseded_obligation_without_a_replacement_refuses() {
  local case_dir prior
  case_dir=$(make_case obligation-no-replacement)
  prior=$(seed_predecessor "$case_dir")
  write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "SUPERSEDED", "replaced_by": "OBL-NOWHERE"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "supersession pointing at nothing refuses"
  assert_contains "$CAPTURED" 'refusal obligation_superseded_without_replacement' \
    "the refusal must say the named replacement is not active"
  pass "an obligation superseded by a replacement that is not active refuses"
}

test_a_resolution_without_an_authority_refuses() {
  local case_dir prior
  case_dir=$(make_case obligation-no-authority)
  prior=$(seed_predecessor "$case_dir")
  write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "RESOLVED", "reason": "no longer needed"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "a resolution with no authority refuses"
  assert_contains "$CAPTURED" 'refusal obligation_resolved_without_authority' \
    "the refusal must say resolution needs an explicit authority and reason"
  pass "an obligation resolved with no named authority refuses"
}

test_a_successor_that_declares_no_predecessor_is_could_not_observe() {
  local case_dir
  case_dir=$(make_case obligation-undeclared)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
del document["obligations"]["predecessor"]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "an undeclared predecessor is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved predecessor_undeclared' \
    "the unobserved continuity must be named"
  pass "an envelope that declares no predecessor at all cannot silently start a fresh obligation chain"
}

test_a_disposition_for_an_obligation_the_predecessor_never_held_refuses() {
  local case_dir prior
  case_dir=$(make_case obligation-laundered)
  prior=$(seed_predecessor "$case_dir")
  write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"},
        {"id": "OBL-INVENTED", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "a disposition for an obligation nobody held refuses"
  assert_contains "$CAPTURED" 'refusal obligation_disposition_unknown' \
    "the refusal must name the invented obligation"
  pass "a disposition naming an obligation the predecessor never held refuses"
}

test_duplicate_dispositions_refuse_in_both_orders() {
  local case_dir prior order dispositions
  for order in preserved-first resolved-first; do
    case_dir=$(make_case "obligation-duplicate-$order")
    prior=$(seed_predecessor "$case_dir")
    if [ "$order" = preserved-first ]; then
      dispositions='[
        {"id": "OBL-1", "disposition": "PRESERVED"},
        {"id": "OBL-1", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]'
    else
      dispositions='[
        {"id": "OBL-1", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"},
        {"id": "OBL-1", "disposition": "PRESERVED"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]'
    fi
    write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [{"id": "OBL-1", "statement": "still active"}],
      "dispositions": '"$dispositions"'}}'
    capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
    expect_code 1 "$CAPTURED_CODE" "duplicate dispositions refuse in $order order"
    assert_contains "$CAPTURED" 'refusal obligation_disposition_duplicate' \
      "the duplicate refusal must not depend on disposition order"
  done
  pass "duplicate obligation dispositions refuse independently of array order"
}

test_request_identity_is_recomputed_and_checked() {
  local case_dir identity
  case_dir=$(make_case request-identity)
  write_inputs "$case_dir"
  run_prepare "$case_dir" first >/dev/null 2>&1
  assert_grep '"declared_request_identity": null' "$case_dir/first/envelope.json" \
    "no declared claim must be recorded explicitly as null"
  capture run_validate "$case_dir" first
  expect_code 0 "$CAPTURED_CODE" "an explicit null claim is accepted"

  identity=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_identity"])' \
    "$case_dir/first/envelope.json")
  write_inputs "$case_dir" '{"request": {"identity": "'"$identity"'"}}'
  capture run_prepare "$case_dir" matching
  expect_code 0 "$CAPTURED_CODE" "a correctly recomputed request identity is accepted"
  assert_grep "\"declared_request_identity\": \"$identity\"" \
    "$case_dir/matching/envelope.json" \
    "the matching declared identity must remain visible in the outer document"
  capture run_validate "$case_dir" matching
  expect_code 0 "$CAPTURED_CODE" "a correct claim with intact digests validates"

  write_inputs "$case_dir" '{"request": {"identity": "sha256:'"$(printf 'f%.0s' $(seq 64))"'"}}'
  capture run_prepare "$case_dir" mismatching
  expect_code 1 "$CAPTURED_CODE" "a mismatched claimed request identity refuses"
  assert_contains "$CAPTURED" 'refusal request_identity_mismatch' \
    "the refusal must name the request identity mismatch"
  capture run_validate "$case_dir" mismatching
  expect_code 1 "$CAPTURED_CODE" "validation preserves the compile-time request identity refusal"
  assert_contains "$CAPTURED" 'refusal request_identity_mismatch' \
    "validation must reproduce the refusal from the preserved declared claim"

  capture run_prepare "$case_dir" claim-deleted
  python3 - "$case_dir/claim-deleted/envelope.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
del document["declared_request_identity"]
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
PY
  capture run_validate "$case_dir" claim-deleted
  expect_code 1 "$CAPTURED_CODE" "deleting a declared claim breaks outer integrity"
  assert_contains "$CAPTURED" 'refusal outer_integrity_digest_mismatch' \
    "deleting the claim must refuse as a partial outer edit"

  capture run_prepare "$case_dir" claim-replaced
  python3 - "$case_dir/claim-replaced/envelope.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["declared_request_identity"] = document["request_identity"]
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
PY
  capture run_validate "$case_dir" claim-replaced
  expect_code 1 "$CAPTURED_CODE" "replacing a declared claim breaks outer integrity"
  assert_contains "$CAPTURED" 'refusal outer_integrity_digest_mismatch' \
    "replacing the claim must refuse as a partial outer edit"

  capture run_prepare "$case_dir" claim-absent
  python3 - "$case_dir/claim-absent/envelope.json" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
document = json.load(open(path))
del document["declared_request_identity"]
payload = {
    "compiled_at": document.get("compiled_at"),
    "compiler": document.get("compiler"),
    "body_digest": document["digest"]["value"],
    "request_identity": document.get("request_identity"),
    "declared_request_identity": document.get("declared_request_identity"),
}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
document["outer_digest"]["value"] = "sha256:" + hashlib.sha256(canonical).hexdigest()
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
PY
  capture run_validate "$case_dir" claim-absent
  expect_code 2 "$CAPTURED_CODE" "an absent claim state is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved request_identity_claim_unobserved' \
    "missing and explicit null claim states must remain distinct"

  capture run_prepare "$case_dir" outer-digest-absent
  python3 - "$case_dir/outer-digest-absent/envelope.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
del document["outer_digest"]
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
PY
  capture run_validate "$case_dir" outer-digest-absent
  expect_code 2 "$CAPTURED_CODE" "an absent outer integrity digest is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved outer_integrity_digest_unobserved' \
    "missing outer integrity cannot validate cleanly"

  python3 - "$case_dir/matching/envelope.json" <<'PY'
import hashlib, json, sys
path = sys.argv[1]
document = json.load(open(path))
document["request_identity"] = "sha256:" + "0" * 64
payload = {
    "compiled_at": document.get("compiled_at"),
    "compiler": document.get("compiler"),
    "body_digest": document["digest"]["value"],
    "request_identity": document.get("request_identity"),
    "declared_request_identity": document.get("declared_request_identity"),
}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
document["outer_digest"]["value"] = "sha256:" + hashlib.sha256(canonical).hexdigest()
json.dump(document, open(path, "w"), indent=2, sort_keys=True)
PY
  capture run_validate "$case_dir" matching
  expect_code 1 "$CAPTURED_CODE" "validate recomputes the stored request identity"
  assert_contains "$CAPTURED" 'refusal request_identity_mismatch' \
    "validation must name the stored request identity mismatch"
  pass "request identity claims and stored identities are checked against recomputation"
}

test_a_predecessor_that_is_not_the_declared_one_is_could_not_observe() {
  local case_dir
  case_dir=$(make_case obligation-wrong-predecessor)
  seed_predecessor "$case_dir" >/dev/null
  write_inputs "$case_dir" '{"obligations": {
      "predecessor": {"envelope_digest": "sha256:'"$(printf 'f%.0s' $(seq 64))"'"},
      "active": [],
      "dispositions": []}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 2 "$CAPTURED_CODE" "a predecessor that is not the declared one is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved predecessor_unreadable' \
    "the unobserved predecessor must be named"
  pass "a supplied predecessor that is not the declared one is could-not-observe"
}

# --- rulings, findings and scope --------------------------------------------

test_a_ruling_that_does_not_apply_cannot_authorize_a_resolution() {
  local case_dir prior
  case_dir=$(make_case ruling-mismatch)
  prior=$(seed_predecessor "$case_dir")
  write_inputs "$case_dir" '{
    "rulings": [{"id": "5307931042", "source": "browser-sol", "disposition": "APPROVE",
                 "relied_upon": true,
                 "applies_to": {"head": "3333333333333333333333333333333333333333"}}],
    "obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "RESOLVED", "authority": "5307931042", "reason": "ruled moot"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "a ruling issued against another head cannot authorize anything here"
  assert_contains "$CAPTURED" 'refusal ruling_applicability_mismatch' \
    "the refusal must name the inapplicable ruling"
  pass "a ruling issued against a different candidate cannot authorize resolving an obligation"
}

test_duplicate_ruling_ids_are_ambiguous_in_both_orders() {
  local case_dir order rulings
  for order in applicable-first stale-first; do
    case_dir=$(make_case "ruling-duplicate-$order")
    if [ "$order" = applicable-first ]; then
      rulings='[
        {"id": "R-1", "source": "captain", "disposition": "APPROVE", "applies_to": {}},
        {"id": "R-1", "source": "browser-sol", "disposition": "REJECT",
         "applies_to": {"head": "3333333333333333333333333333333333333333"}}]'
    else
      rulings='[
        {"id": "R-1", "source": "browser-sol", "disposition": "REJECT",
         "applies_to": {"head": "3333333333333333333333333333333333333333"}},
        {"id": "R-1", "source": "captain", "disposition": "APPROVE", "applies_to": {}}]'
    fi
    write_inputs "$case_dir" '{"rulings": '"$rulings"'}'
    capture run_prepare "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "duplicate ruling ids refuse in $order order"
    assert_contains "$CAPTURED" 'refusal ruling_id_ambiguous' \
      "the refusal must name the ambiguous stable ruling id"
    capture run_validate "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "validation preserves duplicate ruling refusal in $order order"
    assert_contains "$CAPTURED" 'refusal ruling_id_ambiguous' \
      "validation must preserve the ambiguous stable ruling id"
  done
  pass "duplicate ruling ids refuse independently of array order"
}

test_a_ruling_without_a_stable_id_refuses() {
  local case_dir patch variant
  for variant in missing null empty blank; do
    case_dir=$(make_case "ruling-id-$variant")
    case "$variant" in
      missing) patch='{"rulings": [{"source": "captain", "applies_to": {}}]}' ;;
      null) patch='{"rulings": [{"id": null, "source": "captain", "applies_to": {}}]}' ;;
      empty) patch='{"rulings": [{"id": "", "source": "captain", "applies_to": {}}]}' ;;
      blank) patch='{"rulings": [{"id": "   ", "source": "captain", "applies_to": {}}]}' ;;
    esac
    write_inputs "$case_dir" "$patch"
    capture run_prepare "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "a $variant ruling id refuses"
    assert_contains "$CAPTURED" 'refusal ruling_id_absent' \
      "the refusal must name the absent stable ruling id"
    capture run_validate "$case_dir" env
    expect_code 1 "$CAPTURED_CODE" "validation preserves a $variant ruling id refusal"
    assert_contains "$CAPTURED" 'refusal ruling_id_absent' \
      "validation must preserve the absent stable ruling id"
  done
  pass "missing, null and blank ruling ids refuse before authority lookup"
}

test_a_ruling_envelope_digest_binds_the_current_envelope() {
  local case_dir prior target_digest
  case_dir=$(make_case ruling-envelope-digest)
  prior=$(seed_predecessor "$case_dir")
  write_inputs "$case_dir" '{
    "obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]}}'
  capture run_prepare "$case_dir" draft --predecessor "$case_dir/prior"
  expect_code 0 "$CAPTURED_CODE" "the draft envelope compiles"
  target_digest=$(python3 - "$case_dir/draft/envelope.json" <<'PY'
import hashlib, json, sys
document = json.load(open(sys.argv[1]))
body = document["envelope"]
body["rulings"] = []
encoded = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
print("sha256:" + hashlib.sha256(encoded).hexdigest())
PY
)
  write_inputs "$case_dir" '{
    "rulings": [{"id": "R-1", "source": "captain", "disposition": "APPROVE",
                 "relied_upon": true,
                 "applies_to": {"envelope_digest": "'"$target_digest"'"}}],
    "obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 0 "$CAPTURED_CODE" "a ruling bound to the current envelope applies"
  capture run_validate "$case_dir" successor
  expect_code 0 "$CAPTURED_CODE" "validation recomputes current-envelope applicability"
  pass "a ruling digest binds the current envelope without circularity"
}

test_a_blocking_adverse_finding_refuses() {
  local case_dir
  case_dir=$(make_case adverse)
  write_inputs "$case_dir" '{"findings": {"adverse": [
      {"id": "F-1", "statement": "the guard is bypassable", "blocking": true}]}}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a blocking adverse finding refuses"
  assert_contains "$CAPTURED" 'refusal adverse_finding_blocking' "the refusal must name the finding"
  pass "a known blocking adverse finding refuses"
}

test_a_required_unproven_dimension_is_could_not_observe() {
  local case_dir
  case_dir=$(make_case unproven)
  write_inputs "$case_dir" '{"findings": {"unproven": [
      {"id": "U-1", "dimension": "windows-behaviour", "statement": "never executed on windows",
       "required": true}]}}'
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "a required unproven dimension is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved unproven_dimension_required' \
    "the unobserved dimension must be named"
  pass "a dimension declared required and known unproven cannot reach review-ready"
}

test_a_fully_excluded_scope_refuses() {
  local case_dir
  case_dir=$(make_case fully-excluded)
  write_inputs "$case_dir" '{"scope": {"excluded": [
      {"id": "everything", "type": "glob", "value": "*", "reason": "deliberately out of scope"}]}}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "excluding everything refuses"
  assert_contains "$CAPTURED" 'refusal scope_fully_excluded' \
    "the refusal must say nothing is left under review"
  pass "a scope that excludes every changed path refuses instead of reviewing nothing"
}

test_excluded_scope_is_bound_explicitly() {
  local case_dir
  case_dir=$(make_case excluded-scope)
  write_inputs "$case_dir" '{"scope": {"excluded": [
      {"id": "generated-docs", "type": "prefix", "value": "docs/", "reason": "generated"}]},
      "verification": {"applicability_rules": [
        {"contract_id": "repo-baseline", "mandatory": true},
        {"contract_id": "shell-surface", "paths": [{"type": "glob", "value": "bin/*"}]}]}}'
  capture run_prepare "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" "a partial exclusion still leaves a reviewable scope"
  assert_grep '"excluded_by": "generated-docs"' "$case_dir/env/envelope.json" \
    "the envelope must name which rule excluded each path"
  assert_grep '"bin/tool.sh"' "$case_dir/env/envelope.json" "the in-scope path must remain bound"
  pass "excluded scope is bound explicitly, naming the rule that removed each path"
}

test_a_contribution_that_changes_nothing_refuses() {
  local case_dir
  case_dir=$(make_case empty-contribution)
  write_inputs "$case_dir" '{"candidate": {"base_ref": "candidate"}}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a contribution with no changed files refuses"
  assert_contains "$CAPTURED" 'refusal changed_file_set_empty' \
    "the refusal must say the contribution changes nothing"
  pass "a candidate with no changed-file scope at all refuses"
}

test_a_base_the_candidate_does_not_descend_from_refuses() {
  local case_dir
  case_dir=$(make_case foreign-base)
  write_inputs "$case_dir" '{"candidate": {"base_ref": "sidecar"}}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a base outside the candidate's ancestry refuses"
  assert_contains "$CAPTURED" 'refusal base_not_ancestor_of_candidate' \
    "the refusal must name the base the candidate does not descend from"
  pass "a contribution measured from a base the candidate does not descend from refuses"
}

test_a_declared_repository_identity_this_is_not_refuses() {
  local case_dir
  case_dir=$(make_case wrong-repository)
  write_inputs "$case_dir" '{"project": {"root_commit": "4444444444444444444444444444444444444444"}}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "compiling against the wrong repository refuses"
  assert_contains "$CAPTURED" 'refusal project_identity_mismatch' \
    "the refusal must say this is not the declared repository"
  pass "an envelope compiled against a repository that is not the declared one refuses"
}

test_a_check_that_names_no_head_cannot_cover_a_required_platform() {
  local case_dir
  case_dir=$(make_case ci-headless)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
del document["ci"]["attempts"][0]["head"]
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "a check with no head association cannot cover a platform"
  assert_contains "$CAPTURED" 'refusal ci_required_platform_uncovered' \
    "the refusal must say the platform has no exact-head check"
  python3 -c '
import json, sys
envelope = json.load(open(sys.argv[1]))["envelope"]
headless = envelope["ci"]["head_unknown_attempts"]
sys.exit(0 if len(headless) == 1 and headless[0]["name"] == "test" else 1)
' "$case_dir/env/envelope.json" \
    || fail "the headless attempt must be recorded by name rather than silently dropped"
  pass "a check that names no head proves nothing about this candidate"
}

# --- validation contract ----------------------------------------------------

test_validate_refuses_to_guess_about_evidence() {
  local case_dir
  case_dir=$(make_case validate-usage)
  write_inputs "$case_dir"
  run_prepare "$case_dir" env >/dev/null 2>&1
  capture "$BIN" validate --envelope "$case_dir/env" --repo "$case_dir/repo"
  expect_code 2 "$CAPTURED_CODE" "validation with no evidence decision is could-not-observe"
  assert_contains "$CAPTURED" 'usage_error' "the refusal must name the missing decision"
  pass "validation will not guess whether to re-read evidence, and refuses until told"
}

test_declining_the_evidence_recheck_cannot_reach_review_ready() {
  local case_dir
  case_dir=$(make_case validate-declined)
  write_inputs "$case_dir"
  run_prepare "$case_dir" env >/dev/null 2>&1
  capture "$BIN" validate --envelope "$case_dir/env" --repo "$case_dir/repo" --no-evidence-recheck
  expect_code 2 "$CAPTURED_CODE" "a declined evidence recheck cannot pass"
  assert_contains "$CAPTURED" 'unobserved evidence_recheck_declined' \
    "the declination itself must be recorded"
  assert_not_contains "$CAPTURED" 'REVIEW_READY' \
    "an envelope whose evidence was not read cannot be review-ready"
  pass "declining the evidence recheck is recorded and can never reach review-ready"
}

test_validate_rechecks_evidence_bytes() {
  local case_dir
  case_dir=$(make_case validate-evidence)
  write_inputs "$case_dir"
  run_prepare "$case_dir" env >/dev/null 2>&1
  printf 'the evidence was replaced after compilation\n' > "$case_dir/evidence/shell.log"
  capture run_validate "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "evidence replaced after compilation refuses at validation"
  assert_contains "$CAPTURED" 'refusal evidence_digest_mismatch' \
    "the refusal must name the evidence that moved"
  pass "validation re-reads the evidence bytes and refuses when they no longer match"
}

test_a_crashed_compiler_cannot_reach_a_verdict() {
  local case_dir
  case_dir=$(make_case crashed-compiler)
  write_inputs "$case_dir"
  mkdir -p "$case_dir/brokenbin"
  cat > "$case_dir/brokenbin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$case_dir/brokenbin/python3"
  capture env PATH="$case_dir/brokenbin:$PATH" "$BIN" prepare \
    --repo "$case_dir/repo" --inputs "$case_dir/inputs.json" \
    --evidence-root "$case_dir/evidence" --out "$case_dir/env"
  expect_code 2 "$CAPTURED_CODE" "a compiler that produced no result is could-not-observe"
  assert_contains "$CAPTURED" '  review-envelope,NO_VERIFIER_RAN,no_evidence,' \
    "a compiler that wrote no result must emit a could-not-observe record"
  assert_not_contains "$CAPTURED" ',PASS,' "a crashed compiler must never reach a pass"
  pass "a compiler that reaches no readable result is could-not-observe, whatever its exit status was"
}

# --- the generated contract page --------------------------------------------

test_the_generated_contract_page_matches_the_catalog() {
  local generated=$TMP_ROOT/review-envelope.md
  "$BIN" docs > "$generated" || fail "the contract page must generate"
  diff -u "$ROOT/docs/contracts/review-envelope.md" "$generated" \
    || fail "docs/contracts/review-envelope.md is stale; regenerate it with bin/fm-review-envelope.sh docs"
  pass "the tracked contract page is exactly what the field catalog generates"
}

test_the_verification_record_matches_the_executed_control_count() {
  local recorded executed actual
  recorded=$(sed -n 's/^\([0-9][0-9]*\) controls pass against the shipped scripts\.$/\1/p' \
    "$ROOT/docs/verification/review-envelope-controls.md")
  executed=$(printf '%s' "$FM_TEST_PASSED_TESTS" | awk 'NF' | LC_ALL=C sort -u | wc -l)
  actual=$((executed + 1))
  [ -n "$recorded" ] || fail "the verification record must state one numeric control count"
  [ "$actual" -gt 1 ] || fail "the control-count comparison must observe executed controls"
  [ "$recorded" -eq "$actual" ] \
    || fail "the verification record states $recorded controls, but the suite executed $actual"
  pass "the verification record matches the suite's executed control count"
}

test_a_complete_candidate_is_review_ready
test_required_contracts_are_computed_from_the_changed_files
test_identical_facts_produce_an_identical_digest
test_order_insensitive_facts_produce_an_identical_identity
test_a_structurally_malformed_envelope_is_could_not_observe
test_a_stale_envelope_refuses
test_a_base_that_falls_behind_the_trunk_refuses
test_an_asserted_head_the_repository_contradicts_refuses
test_a_tampered_envelope_body_refuses
test_an_envelope_is_written_once
test_a_missing_required_contract_refuses
test_a_missing_required_verifier_result_refuses
test_verifier_results_bind_the_selected_contract_digest
test_duplicate_contract_ids_are_ambiguous
test_forge_request_identity_is_required_and_complete
test_a_verifier_result_bound_to_another_head_refuses
test_a_verifier_result_without_a_tree_refuses
test_a_missing_red_calibration_refuses
test_a_red_calibration_that_records_a_pass_refuses
test_a_could_not_observe_verifier_cannot_become_review_ready
test_a_broken_evidence_digest_refuses
test_an_evidence_locator_that_escapes_its_root_refuses
test_an_evidence_symlink_that_escapes_its_root_refuses_before_reading
test_a_result_that_does_not_identify_its_verifier_refuses
test_wrong_head_ci_refuses
test_a_skipped_required_check_refuses
test_an_absent_required_platform_refuses
test_a_pending_required_check_is_could_not_observe
test_duplicate_attempts_with_no_ordering_refuse
test_a_superseded_failure_is_replaced_by_its_later_rerun
test_two_workflows_sharing_a_check_name_stay_two_checks
test_alias_fallback_resolves_a_later_declared_candidate
test_an_exhausted_candidate_set_is_could_not_observe
test_a_candidate_that_will_not_state_its_identity_is_not_a_selection
test_a_silently_dropped_obligation_refuses
test_every_prior_obligation_may_be_accounted_for_explicitly
test_a_satisfied_obligation_without_evidence_refuses
test_a_preserved_obligation_missing_from_the_active_set_refuses
test_a_superseded_obligation_without_a_replacement_refuses
test_a_resolution_without_an_authority_refuses
test_a_successor_that_declares_no_predecessor_is_could_not_observe
test_a_disposition_for_an_obligation_the_predecessor_never_held_refuses
test_duplicate_dispositions_refuse_in_both_orders
test_request_identity_is_recomputed_and_checked
test_a_predecessor_that_is_not_the_declared_one_is_could_not_observe
test_a_ruling_that_does_not_apply_cannot_authorize_a_resolution
test_duplicate_ruling_ids_are_ambiguous_in_both_orders
test_a_ruling_without_a_stable_id_refuses
test_a_ruling_envelope_digest_binds_the_current_envelope
test_a_blocking_adverse_finding_refuses
test_a_required_unproven_dimension_is_could_not_observe
test_a_fully_excluded_scope_refuses
test_excluded_scope_is_bound_explicitly
test_a_contribution_that_changes_nothing_refuses
test_a_base_the_candidate_does_not_descend_from_refuses
test_a_declared_repository_identity_this_is_not_refuses
test_a_check_that_names_no_head_cannot_cover_a_required_platform
test_validate_refuses_to_guess_about_evidence
test_declining_the_evidence_recheck_cannot_reach_review_ready
test_validate_rechecks_evidence_bytes
test_a_crashed_compiler_cannot_reach_a_verdict
test_the_generated_contract_page_matches_the_catalog
test_the_verification_record_matches_the_executed_control_count
fm_test_contract "${BASH_SOURCE[0]}"
