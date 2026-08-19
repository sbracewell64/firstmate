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
  # `|| fail` is not optional here: a malformed patch used to leave the previous
  # inputs.json in place, and the case then ran green against stale input.
  python3 - "$case_dir" "$patch" <<'PY' || fail "write_inputs could not build the inputs document"
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

# The evidence-handle synchronization seam's bound and its confinement root
# belong to the library, and are read out of the build under test rather than
# restated here. Two halves of one handshake carrying two numbers is how a
# control ends up polling for a fraction of the deadline it is synchronizing
# against, and then reporting a slow machine as a broken property.
seam_library() {
  printf '%s\n' "$(dirname "$BIN")/fm-review-envelope-lib.sh"
}

seam_deadline() {
  sed -n 's/^SEAM_DEADLINE_SECONDS = \([0-9][0-9]*\)$/\1/p' "$(seam_library)"
}

run_prepare_with_seam() {  # <case-dir> <out-name> <seam> <locator>
  local case_dir=$1 out=$2 seam=$3 locator=$4
  FM_REVIEW_ENVELOPE_TEST_OPENED_SEAM=$seam \
  FM_REVIEW_ENVELOPE_TEST_OPENED_LOCATOR=$locator \
  PATH="$case_dir/fakebin:$PATH" "$BIN" prepare \
    --repo "$case_dir/repo" \
    --inputs "$case_dir/inputs.json" \
    --evidence-root "$case_dir/evidence" \
    --out "$case_dir/$out"
}

seam_root() {
  local name
  name=$(sed -n 's/^SEAM_DIRECTORY = "\([^"]*\)"$/\1/p' "$(seam_library)")
  [ -n "$name" ] || return 1
  python3 -c \
    'import os, sys, tempfile; print(os.path.realpath(os.path.join(tempfile.gettempdir(), sys.argv[1])))' \
    "$name"
}

check_array_registry() {  # <envelope> <registry> <current|extra|stale|contradict-summary|attempt-exemption>
  python3 - "$@" <<'PY'
import copy, json, sys

envelope_path, registry_path, mode = sys.argv[1:]
body = json.load(open(envelope_path))["envelope"]
registry = json.load(open(registry_path))
if registry.get("schema") != "review-envelope-array-classifications/v1":
    sys.stderr.write("array registry has an unknown schema\n")
    sys.exit(1)
entries = copy.deepcopy(registry.get("classifications", []))
if not isinstance(entries, list):
    sys.stderr.write("array registry classifications must be a list\n")
    sys.exit(1)

if mode == "extra":
    body["future_array"] = []
elif mode == "stale":
    entries.append({
        "path": "retired_array",
        "order": "canonicalized",
        "reason": "deliberately stale test entry",
        "experiment": {
            "kind": "body-canonical",
            "sort_key": "scalar",
        },
    })
elif mode == "contradict-summary":
    registry["summary"] = {"exempt_paths": ["candidate.changed_files"]}
elif mode == "attempt-exemption":
    entries[0]["experiment"] = {
        "kind": "exempt",
        "condition": "contract-max-items-at-most-one",
    }
elif mode != "current":
    sys.stderr.write("unknown array-registry check mode: " + mode + "\n")
    sys.exit(1)

observed = set()


def walk(node, path=""):
    if isinstance(node, list):
        observed.add(path)
        for item in node:
            walk(item, path + "[]")
    elif isinstance(node, dict):
        for key, value in node.items():
            walk(value, path + "." + key if path else key)


walk(body)
declared = set()
exempt_paths = set()
for entry in entries:
    path = entry.get("path")
    order = entry.get("order")
    reason = entry.get("reason")
    if not isinstance(path, str) or not path or path in declared:
        sys.stderr.write("array registry contains an absent or duplicate path\n")
        sys.exit(1)
    if order not in ("canonicalized", "order-meaningful"):
        sys.stderr.write("array registry has an invalid order classification: " + path + "\n")
        sys.exit(1)
    if not isinstance(reason, str) or not reason.strip():
        sys.stderr.write("array registry has no reason: " + path + "\n")
        sys.exit(1)
    experiment = entry.get("experiment")
    if not isinstance(experiment, dict):
        sys.stderr.write("array registry has no experiment: " + path + "\n")
        sys.exit(1)
    kind = experiment.get("kind")
    if kind == "input-recompile":
        if not isinstance(experiment.get("input_path"), str) or not experiment["input_path"]:
            sys.stderr.write("array input experiment has no input path: " + path + "\n")
            sys.exit(1)
    elif kind == "body-recompute":
        pass
    elif kind == "body-canonical":
        if experiment.get("sort_key") not in ("id", "mismatch", "path", "scalar"):
            sys.stderr.write("array canonical experiment has no stable sort key: " + path + "\n")
            sys.exit(1)
    else:
        sys.stderr.write("array registry has an invalid experiment: " + path + "\n")
        sys.exit(1)
    declared.add(path)

summary = registry.get("summary")
if not isinstance(summary, dict) or summary.get("exempt_paths") != sorted(exempt_paths):
    sys.stderr.write("array registry summary contradicts its classifications\n")
    sys.exit(1)

missing = sorted(observed - declared)
stale = sorted(declared - observed)
if missing:
    sys.stderr.write("unclassified array paths: " + ", ".join(missing) + "\n")
if stale:
    sys.stderr.write("stale array classifications: " + ", ".join(stale) + "\n")
if missing or stale:
    sys.exit(1)
PY
}

exercise_array_registry() {  # <case-dir> <envelope> <registry> <binary> <mode>
  python3 - "$@" <<'PY'
import copy, hashlib, json, os, subprocess, sys

case_dir, envelope_path, registry_path, binary, mode = sys.argv[1:]
baseline = json.load(open(envelope_path))
registry = json.load(open(registry_path))
entries = copy.deepcopy(registry["classifications"])

if mode == "canonical-as-meaningful":
    entry = next(item for item in entries
                 if item["order"] == "canonicalized"
                 and item["experiment"]["kind"] == "input-recompile")
    entry["order"] = "order-meaningful"
elif mode == "meaningful-as-canonical":
    entry = next(item for item in entries
                 if item["order"] == "order-meaningful"
                 and item["experiment"]["kind"] == "input-recompile")
    entry["order"] = "canonicalized"
elif mode == "fixture-short":
    baseline["envelope"]["ci"]["wrong_head_attempts"] = baseline["envelope"]["ci"]["wrong_head_attempts"][:1]
elif mode != "current":
    sys.stderr.write("unknown array exercise mode: " + mode + "\n")
    sys.exit(1)


def arrays_at(document, path):
    nodes = [document]
    parts = path.split(".")
    for index, part in enumerate(parts):
        expand = part.endswith("[]")
        key = part[:-2] if expand else part
        last = index == len(parts) - 1
        values = []
        for node in nodes:
            if not isinstance(node, dict) or key not in node:
                continue
            value = node[key]
            if last:
                values.append(value)
            elif expand and isinstance(value, list):
                values.extend(value)
            else:
                values.append(value)
        nodes = values
    return [node for node in nodes if isinstance(node, list)]


def digest(value):
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def identity(body):
    project = body["identity"]["project"]
    work = body["identity"]["work"]
    return digest({
        "project": {"id": project["id"], "root_commits": project["root_commits"]},
        "work": {"id": work["id"], "forge_request": work.get("request")},
        "candidate_head_commit": body["candidate"]["head_commit"],
        "envelope_digest": digest(body),
        "policy_version": body["identity"]["policy"]["version"],
    })


def distinct_count(array):
    return len({json.dumps(item, sort_keys=True) for item in array})


def canonicalize(array, sort_key):
    if sort_key == "scalar":
        return sorted(array)
    if sort_key == "mismatch":
        ranks = {name: index for index, name in enumerate(
            ("work_id", "head", "tree", "envelope_digest"))}
        return sorted(array, key=lambda item: ranks[item])
    return sorted(array, key=lambda item: item[sort_key])


baseline_identity = identity(baseline["envelope"])
for entry in entries:
    arrays = arrays_at(baseline["envelope"], entry["path"])
    supplied = max((distinct_count(array) for array in arrays), default=0)
    if supplied < 2:
        sys.stderr.write(
            "fixture defect " + entry["path"]
            + ": contract permits at least 2 distinct elements; fixture supplied "
            + str(supplied) + "\n"
        )
        sys.exit(1)


for index, entry in enumerate(entries):
    path = entry["path"]
    experiment = entry["experiment"]
    if experiment["kind"] in ("body-recompute", "body-canonical"):
        body = copy.deepcopy(baseline["envelope"])
        candidates = arrays_at(body, path)
        target = next(
            (array for array in candidates
             if distinct_count(array) >= 2),
            None,
        )
        if target is None:
            supplied = max((distinct_count(array) for array in candidates), default=0)
            sys.stderr.write(
                "fixture defect " + path + ": contract permits at least 2 distinct elements;"
                + " fixture supplied " + str(supplied) + "\n"
            )
            sys.exit(1)
        target.reverse()
        if experiment["kind"] == "body-canonical":
            target[:] = canonicalize(target, experiment["sort_key"])
        observed_identity = identity(body)
        changed = observed_identity != baseline_identity
        expected_changed = entry["order"] == "order-meaningful"
        if changed != expected_changed:
            expectation = "change" if expected_changed else "remain stable"
            sys.stderr.write("isolated reorder of " + path + " expected identity to " + expectation + "\n")
            sys.exit(1)
        print("exercised " + path + ": identity " + ("changed" if changed else "stable"))
        continue
    inputs = json.load(open(os.path.join(case_dir, "inputs.json")))
    candidates = arrays_at(inputs, experiment["input_path"])
    target = next(
        (array for array in candidates
         if len(array) >= 2
         and json.dumps(array[0], sort_keys=True) != json.dumps(array[1], sort_keys=True)),
        None,
    )
    if target is None:
        supplied = max((distinct_count(array) for array in candidates), default=0)
        sys.stderr.write(
            "fixture defect " + path + ": contract permits at least 2 distinct elements;"
            + " fixture supplied " + str(supplied) + "\n"
        )
        sys.exit(1)
    target.reverse()
    input_path = os.path.join(case_dir, "array-input-%s-%d.json" % (mode, index))
    output_path = os.path.join(case_dir, "array-output-%s-%d" % (mode, index))
    with open(input_path, "w", encoding="utf-8") as handle:
        json.dump(inputs, handle, indent=2)
    environment = os.environ.copy()
    environment["PATH"] = os.path.join(case_dir, "fakebin") + os.pathsep + environment["PATH"]
    command = [binary, "prepare", "--repo", os.path.join(case_dir, "repo"),
               "--inputs", input_path, "--evidence-root", os.path.join(case_dir, "evidence"),
               "--out", output_path]
    predecessor = os.path.join(case_dir, "prior")
    if os.path.isfile(os.path.join(predecessor, "envelope.json")):
        command.extend(["--predecessor", predecessor])
    completed = subprocess.run(
        command,
        env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    envelope_file = os.path.join(output_path, "envelope.json")
    if not os.path.isfile(envelope_file):
        sys.stderr.write("array experiment produced no envelope for " + path + "\n")
        sys.exit(1)
    observed_identity = json.load(open(envelope_file))["request_identity"]
    changed = observed_identity != baseline_identity
    expected_changed = entry["order"] == "order-meaningful"
    if changed != expected_changed:
        expectation = "change" if expected_changed else "remain stable"
        sys.stderr.write("isolated reorder of " + path + " expected identity to " + expectation + "\n")
        sys.exit(1)
    print("exercised " + path + ": identity " + ("changed" if changed else "stable"))
PY
}

write_array_registry_inputs() {  # <case-dir>
  local case_dir=$1 prior
  prior=$(seed_predecessor "$case_dir")
  git -C "$case_dir/repo" checkout -q candidate
  mkdir -p "$case_dir/repo/src" "$case_dir/repo/generated"
  printf '%s\n' 'registry source' >"$case_dir/repo/src/registry.txt"
  printf '%s\n' 'registry output' >"$case_dir/repo/generated/registry.txt"
  git -C "$case_dir/repo" add src/registry.txt generated/registry.txt
  git -C "$case_dir/repo" commit -qm 'populate registry scope'
  git -C "$case_dir/repo" checkout -q --orphan registry-second-root
  git -C "$case_dir/repo" rm -qrf .
  printf '%s\n' 'second root' >"$case_dir/repo/second-root.txt"
  git -C "$case_dir/repo" add second-root.txt
  git -C "$case_dir/repo" commit -qm 'create second project root'
  git -C "$case_dir/repo" checkout -q candidate
  git -C "$case_dir/repo" merge -q --allow-unrelated-histories registry-second-root -m 'merge second project root'
  git -C "$case_dir/repo" checkout -q main
  write_probe "$case_dir/fakebin/fm-probe-beta" 'fm-probe-beta 2.0.0'
  write_inputs "$case_dir" '{
    "scope": {"excluded": [
      {"id": "docs-first", "type": "prefix", "value": "docs/", "reason": "docs"},
      {"id": "docs-second", "type": "glob", "value": "docs/*", "reason": "docs fallback"},
      {"id": "generated", "type": "prefix", "value": "generated/", "reason": "generated"},
      {"id": "unused-a", "type": "exact", "value": "absent-a", "reason": "unused"},
      {"id": "unused-b", "type": "exact", "value": "absent-b", "reason": "unused"}]},
    "verification": {"applicability_rules": [
      {"contract_id": "repo-baseline", "mandatory": true},
      {"contract_id": "shell-surface", "paths": [
        {"type": "glob", "value": "bin/*"},
        {"type": "glob", "value": "src/*"}]}]},
    "capabilities": [
      {"id": "probe-a", "mandatory": true, "candidates": ["fm-probe-alpha", "fm-probe-beta"],
       "identity_argv": ["--version", "--verbose"]},
      {"id": "probe-z", "mandatory": true, "candidates": ["fm-probe-beta", "fm-probe-alpha"],
       "identity_argv": ["--verbose", "--version"]}],
    "findings": {
      "adverse": [{"id": "F-2", "blocking": false}, {"id": "F-1", "blocking": false}],
      "unproven": [{"id": "U-2", "required": false}, {"id": "U-1", "required": false}]},
    "rulings": [
      {"id": "R-2", "source": "captain", "relied_upon": false, "applies_to": {
        "work_id": "other-work", "head": "0000000000000000000000000000000000000000",
        "tree": "1111111111111111111111111111111111111111",
        "envelope_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"}},
      {"id": "R-1", "source": "captain", "relied_upon": false,
       "applies_to": {"head": "'"$(git -C "$case_dir/repo" rev-parse candidate)"'"}}],
    "obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [{"id": "OBL-2"}, {"id": "OBL-1"}],
      "dispositions": [
        {"id": "OBL-2", "disposition": "PRESERVED"},
        {"id": "OBL-1", "disposition": "PRESERVED"}]}}'
  python3 - "$case_dir/inputs.json" <<'PY'
import copy, json, sys
path = sys.argv[1]
document = json.load(open(path))
document["ci"]["required_platforms"] = ["linux", "windows"]
linux = document["ci"]["attempts"][0]
windows = copy.deepcopy(linux)
windows.update({"platform": "windows"})
lint = copy.deepcopy(linux)
lint.update({"name": "lint", "order": 93})
headless_a = copy.deepcopy(linux)
headless_a.update({"name": "headless-a", "head": None, "order": 91})
headless_b = copy.deepcopy(linux)
headless_b.update({"name": "headless-b", "head": None, "order": 92})
wrong = copy.deepcopy(linux)
wrong.update({"name": "wrong-head", "head": "8" * 40, "order": 80})
wrong_two = copy.deepcopy(wrong)
wrong_two.update({"name": "wrong-head-two", "order": 81})
document["ci"]["attempts"].extend([windows, lint, headless_a, headless_b, wrong, wrong_two])
additional = []
for contract in document["verification"]["contracts"]:
    contract["execution_worlds"] = ["offline-ci", "portable-ci"]
for result in document["verification"]["results"]:
    portable = copy.deepcopy(result)
    portable["world"] = "portable-ci"
    additional.append(portable)
document["verification"]["results"].extend(additional)
json.dump(document, open(path, "w"), indent=2)
PY
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

test_verification_applicability_must_be_declared_explicitly() {
  local case_dir
  case_dir=$(make_case verification-applicability-absent)
  write_inputs "$case_dir"
  python3 - "$case_dir/inputs.json" <<'PY' || fail "the absent-rules fixture must be writable"
import json
import sys

path = sys.argv[1]
document = json.load(open(path))
del document["verification"]["applicability_rules"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "absent applicability rules are could-not-observe"
  assert_contains "$CAPTURED" 'unobserved verification_applicability_undeclared' \
    "the absent applicability declaration must be named"

  case_dir=$(make_case verification-applicability-empty)
  write_inputs "$case_dir" '{"verification": {"applicability_rules": []}}'
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "empty applicability rules are could-not-observe"
  assert_contains "$CAPTURED" 'unobserved verification_applicability_undeclared' \
    "the empty applicability declaration must be named"

  case_dir=$(make_case verification-applicability-no-baseline)
  write_inputs "$case_dir" '{"verification": {"applicability_rules": [
      {"contract_id": "shell-surface", "paths": [{"type": "glob", "value": "nothing/*"}]}]}}'
  capture run_prepare "$case_dir" env
  expect_code 2 "$CAPTURED_CODE" "applicability rules without a mandatory baseline are could-not-observe"
  assert_contains "$CAPTURED" 'unobserved verification_applicability_undeclared' \
    "the missing mandatory applicability rule must be named"
  pass "verification applicability cannot disappear into an empty required-contract set"
}

test_no_verification_contracts_requires_an_explicit_reason() {
  local case_dir
  case_dir=$(make_case verification-applicability-none)
  write_inputs "$case_dir" '{"verification": {
      "applicability_rules": {"none": true, "reason": "this project declares no verification contracts"},
      "contracts": [],
      "results": []}}'
  capture run_prepare "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" "an explicit reason may declare that no contracts are required"
  assert_contains "$CAPTURED" 'review-envelope: REVIEW_READY' \
    "an explicit no-contracts declaration must not be vacuously rejected"
  assert_grep '"reason": "this project declares no verification contracts"' \
    "$case_dir/env/envelope.json" "the envelope must bind the no-contracts reason"
  assert_required_set "$case_dir/env/envelope.json" \
    "the explicit no-contracts declaration must compute an empty required set"
  pass "an explicit no-contracts declaration and its reason are preserved"
}

test_requested_decision_is_an_uppercase_token() {
  local case_dir
  case_dir=$(make_case requested-decision-token)
  write_inputs "$case_dir" '{"requested_decision": "semantic-review"}'
  capture run_prepare "$case_dir" malformed
  expect_code 1 "$CAPTURED_CODE" "a malformed requested decision refuses"
  assert_contains "$CAPTURED" 'refusal requested_decision_invalid' \
    "the malformed requested decision must be named"

  write_inputs "$case_dir" '{"requested_decision": "LANDING_AUTHORIZATION"}'
  capture run_prepare "$case_dir" valid
  expect_code 0 "$CAPTURED_CODE" "an uppercase requested-decision token is accepted"
  assert_contains "$CAPTURED" 'review-envelope: REVIEW_READY' \
    "the valid token control must reach review-ready"
  pass "requested decisions accept only documented uppercase tokens"
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
  write_inputs "$case_dir" '{
    "capabilities": [
      {"id": "probe-z", "mandatory": true, "candidates": ["fm-probe-alpha"], "identity_argv": ["--version"]},
      {"id": "probe-a", "mandatory": true, "candidates": ["fm-probe-alpha"], "identity_argv": ["--version"]}],
    "ci": {"attempts": [
      {"name": "test", "workflow": "CI", "platform": "linux", "head": "", "order": 98, "conclusion": "SUCCESS", "provider_timestamp": "2026-08-17T12:00:00Z"},
      {"name": "test", "workflow": "CI", "platform": "linux", "head": "1111111111111111111111111111111111111111", "order": 97, "conclusion": "FAILURE"},
      {"name": "test", "workflow": "CI", "platform": "linux", "head": "candidate", "order": 99, "conclusion": "FAILURE"},
      {"name": "test", "workflow": "CI", "platform": "linux", "head": "candidate", "order": 100, "conclusion": "SUCCESS"}]},
    "findings": {
      "adverse": [{"id": "F-2", "blocking": false}, {"id": "F-1", "blocking": false}],
      "unproven": [{"id": "U-2", "required": false}, {"id": "U-1", "required": false}]},
    "rulings": [
      {"id": "R-2", "source": "captain", "applies_to": {"head": "candidate"}},
      {"id": "R-1", "source": "captain", "applies_to": {"head": "candidate"}}],
    "obligations": {"active": [{"id": "OBL-2"}, {"id": "OBL-1"}]}}'
  python3 - "$case_dir/inputs.json" "$case_dir/repo" <<'PY'
import json, subprocess, sys
path, repo = sys.argv[1:]
document = json.load(open(path))
head = subprocess.run(
    ["git", "-C", repo, "rev-parse", "candidate"], capture_output=True, text=True, check=True
).stdout.strip()
for attempt in document["ci"]["attempts"]:
    if attempt["head"] == "candidate":
        attempt["head"] = head
for ruling in document["rulings"]:
    if ruling["applies_to"].get("head") == "candidate":
        ruling["applies_to"]["head"] = head
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" first
  expect_code 0 "$CAPTURED_CODE" "the first fact order compiles"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["verification"]["contracts"].reverse()
document["verification"]["results"].reverse()
document["verification"]["applicability_rules"].reverse()
document["capabilities"].reverse()
document["ci"]["attempts"].reverse()
document["findings"]["adverse"].reverse()
document["findings"]["unproven"].reverse()
document["rulings"].reverse()
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

test_nested_order_insensitive_facts_produce_an_identical_identity() {
  local case_dir first_digest first_identity second_digest second_identity third_digest third_identity
  case_dir=$(make_case canonical-nested-fact-order)
  write_inputs "$case_dir" '{"verification": {"applicability_rules": [
    {"contract_id": "repo-baseline", "mandatory": true},
    {"contract_id": "shell-surface", "paths": [
      {"type": "glob", "value": "bin/*"},
      {"type": "glob", "value": "docs/*"}]}]}}'
  python3 - "$case_dir/inputs.json" <<'PY'
import copy, json, sys
path = sys.argv[1]
document = json.load(open(path))
additional = []
for contract in document["verification"]["contracts"]:
    contract["execution_worlds"] = ["offline-ci", "portable-ci"]
for result in document["verification"]["results"]:
    portable = copy.deepcopy(result)
    portable["world"] = "portable-ci"
    additional.append(portable)
document["verification"]["results"].extend(additional)
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" first
  expect_code 0 "$CAPTURED_CODE" "the first nested fact order compiles"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["verification"]["applicability_rules"][1]["paths"].reverse()
for contract in document["verification"]["contracts"]:
    contract["execution_worlds"].reverse()
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" second
  expect_code 0 "$CAPTURED_CODE" "the reordered nested facts compile"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["verification"]["applicability_rules"][1]["paths"][0]["value"] = "src/*"
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" third
  expect_code 0 "$CAPTURED_CODE" "the meaningfully changed nested facts compile"
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
  read -r third_digest third_identity < <(python3 - "$case_dir/third/envelope.json" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
print(document["digest"]["value"], document["request_identity"])
PY
)
  [ "$first_digest" = "$second_digest" ] \
    || fail "nested order-insensitive facts must have one envelope digest"
  [ "$first_identity" = "$second_identity" ] \
    || fail "nested order-insensitive facts must have one request identity"
  [ "$second_digest" != "$third_digest" ] \
    || fail "a meaningful nested fact difference must change the envelope digest"
  [ "$second_identity" != "$third_identity" ] \
    || fail "a meaningful nested fact difference must change the request identity"
  pass "nested order-insensitive facts preserve stable, non-vacuous identities"
}

test_array_classification_registry_is_total() {
  local case_dir registry
  case_dir=$(make_case array-registry)
  registry=$ROOT/docs/verification/review-envelope-array-classifications.json
  write_array_registry_inputs "$case_dir"
  capture run_prepare "$case_dir" env --predecessor "$case_dir/prior"
  expect_code 0 "$CAPTURED_CODE" "the populated registry fixture compiles to a classified envelope"
  assert_present "$case_dir/env/envelope.json" "the populated registry fixture must emit an envelope"

  capture check_array_registry "$case_dir/env/envelope.json" "$registry" current
  expect_code 0 "$CAPTURED_CODE" "every current array path is classified"

  capture check_array_registry "$case_dir/env/envelope.json" "$registry" extra
  expect_code 1 "$CAPTURED_CODE" "an unclassified future array path fails"
  assert_contains "$CAPTURED" 'unclassified array paths: future_array' \
    "the missing classification must name the newly observed array path"

  capture check_array_registry "$case_dir/env/envelope.json" "$registry" stale
  expect_code 1 "$CAPTURED_CODE" "a stale registry path fails"
  assert_contains "$CAPTURED" 'stale array classifications: retired_array' \
    "the stale classification must name the path no longer observed"

  capture check_array_registry "$case_dir/env/envelope.json" "$registry" contradict-summary
  expect_code 1 "$CAPTURED_CODE" "a registry summary that contradicts its entries fails"
  assert_contains "$CAPTURED" 'array registry summary contradicts its classifications' \
    "the registry summary must be derived from its classifications"

  capture check_array_registry "$case_dir/env/envelope.json" "$registry" attempt-exemption
  expect_code 1 "$CAPTURED_CODE" "a path without a contract cardinality anchor cannot be exempted"
  assert_contains "$CAPTURED" 'array registry has an invalid experiment: candidate.changed_files' \
    "an attempted unanchored exemption must fail by path"
  pass "the recursive array registry is total in both directions"
}

test_array_classifications_are_exercised_in_isolation() {
  local case_dir registry
  case_dir=$(make_case array-registry-exercises)
  registry=$ROOT/docs/verification/review-envelope-array-classifications.json
  write_array_registry_inputs "$case_dir"
  capture run_prepare "$case_dir" baseline --predecessor "$case_dir/prior"
  expect_code 0 "$CAPTURED_CODE" "the array experiment baseline emits a classified envelope"
  assert_present "$case_dir/baseline/envelope.json" "the array experiment baseline must emit an envelope"

  capture exercise_array_registry "$case_dir" "$case_dir/baseline/envelope.json" \
    "$registry" "$BIN" current
  expect_code 0 "$CAPTURED_CODE" "every observable registry path has the declared isolated outcome"
  assert_contains "$CAPTURED" 'exercised candidate.changed_files: identity stable' \
    "changed-file order must be exercised with a populated fixture"
  assert_contains "$CAPTURED" 'exercised capabilities[].probes: identity changed' \
    "probe order must be exercised alone in the compiled body"
  assert_contains "$CAPTURED" 'exercised capabilities[].selected.identity_argv: identity changed' \
    "selected identity arguments must be exercised alone in the compiled body"

  capture exercise_array_registry "$case_dir" "$case_dir/baseline/envelope.json" \
    "$registry" "$BIN" fixture-short
  expect_code 1 "$CAPTURED_CODE" "a contract-reorderable path cannot be exempted by thinning its fixture"
  assert_contains "$CAPTURED" \
    'fixture defect ci.wrong_head_attempts: contract permits at least 2 distinct elements; fixture supplied 1' \
    "the fixture defect must name its contract capacity and supplied cardinality"

  capture exercise_array_registry "$case_dir" "$case_dir/baseline/envelope.json" \
    "$registry" "$BIN" canonical-as-meaningful
  expect_code 1 "$CAPTURED_CODE" "misclassifying a canonical path as meaningful fails"
  assert_contains "$CAPTURED" 'expected identity to change' \
    "the false order-meaningful declaration must fail for its observed stable identity"

  capture exercise_array_registry "$case_dir" "$case_dir/baseline/envelope.json" \
    "$registry" "$BIN" meaningful-as-canonical
  expect_code 1 "$CAPTURED_CODE" "misclassifying a meaningful path as canonical fails"
  assert_contains "$CAPTURED" 'expected identity to remain stable' \
    "the false canonical declaration must fail for its observed identity change"
  pass "registry-driven isolated reorder experiments enforce every observable classification"
}

test_ci_canonicalization_preserves_meaningful_differences() {
  local case_dir first_digest first_identity second_digest second_identity
  case_dir=$(make_case canonical-ci-meaning)
  write_inputs "$case_dir"
  capture run_prepare "$case_dir" first
  expect_code 0 "$CAPTURED_CODE" "the passing CI attempt compiles"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["ci"]["attempts"][0]["conclusion"] = "SKIPPED"
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" second
  expect_code 1 "$CAPTURED_CODE" "the meaningfully different CI attempt refuses"
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
  [ "$first_digest" != "$second_digest" ] \
    || fail "a meaningful CI verdict difference must change the envelope digest"
  [ "$first_identity" != "$second_identity" ] \
    || fail "a meaningful CI verdict difference must change the request identity"
  pass "CI canonicalization preserves meaningful verdict differences"
}

test_exclusion_rule_order_remains_meaningful() {
  local case_dir first_rule second_rule first_identity second_identity
  case_dir=$(make_case meaningful-exclusion-order)
  write_inputs "$case_dir" '{"scope": {"excluded": [
    {"id": "docs-first", "type": "prefix", "value": "docs/", "reason": "docs"},
    {"id": "all-second", "type": "glob", "value": "*", "reason": "all"}]}}'
  capture run_prepare "$case_dir" first
  expect_code 1 "$CAPTURED_CODE" "the first exclusion order compiles to a refusal"
  python3 - "$case_dir/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
document = json.load(open(path))
document["scope"]["excluded"].reverse()
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" second
  expect_code 1 "$CAPTURED_CODE" "the reversed exclusion order compiles to a refusal"
  first_rule=$(python3 -c 'import json,sys; print(next(row["excluded_by"] for row in json.load(open(sys.argv[1]))["envelope"]["candidate"]["changed_files"] if row["path"] == "docs/notes.md"))' "$case_dir/first/envelope.json")
  second_rule=$(python3 -c 'import json,sys; print(next(row["excluded_by"] for row in json.load(open(sys.argv[1]))["envelope"]["candidate"]["changed_files"] if row["path"] == "docs/notes.md"))' "$case_dir/second/envelope.json")
  first_identity=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_identity"])' "$case_dir/first/envelope.json")
  second_identity=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request_identity"])' "$case_dir/second/envelope.json")
  [ "$first_rule" = docs-first ] || fail "the first matching exclusion rule must receive credit"
  [ "$second_rule" = all-second ] || fail "reordering matching exclusions must change the credited rule"
  [ "$first_identity" != "$second_identity" ] \
    || fail "reordering first-match-wins exclusions must change request identity"
  pass "exclusion rules retain first-match-wins order"
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
  local case_dir seam seam_dir prepare_pid prepare_code seam_polls seam_deadline_seconds
  seam_deadline_seconds=$(seam_deadline)
  [ -n "$seam_deadline_seconds" ] \
    || fail "the library must publish one synchronization seam deadline"
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

  rm "$case_dir/evidence/linked.log"
  printf 'internal bytes bound through the opened handle\n' > "$case_dir/evidence/linked.log"
  python3 - "$case_dir" <<'PY'
import hashlib, json, sys
case_dir = sys.argv[1]
path = case_dir + "/inputs.json"
document = json.load(open(path))
digest = "sha256:" + hashlib.sha256(
    open(case_dir + "/evidence/linked.log", "rb").read()
).hexdigest()
document["verification"]["results"][1]["evidence"]["sha256"] = digest
json.dump(document, open(path, "w"), indent=2)
PY
  capture run_prepare "$case_dir" seam-unset
  expect_code 0 "$CAPTURED_CODE" "the inert synchronization seam must not change evidence binding"
  assert_contains "$CAPTURED" 'REVIEW_READY' \
    "ordinary evidence binding must remain review-ready with the seam unset"

  # Both halves of the handshake are bounded by the library's own number, read
  # out of the library rather than restated here: a control that polls for a
  # fraction of the deadline it is synchronizing against reports a slow machine
  # as a broken property.
  seam_polls=$((seam_deadline_seconds * 100))
  seam_dir=$(seam_root)
  [ -n "$seam_dir" ] \
    || fail "the seam_root helper could not read SEAM_DIRECTORY out of the library under test"
  seam=$seam_dir/opened-$$
  mkdir -p "$seam_dir"
  rm -f "$seam".*
  run_prepare_with_seam "$case_dir" seam-engaged "$seam" linked.log \
    > "$case_dir/seam.out" 2>&1 &
  prepare_pid=$!
  fm_test_reap "$prepare_pid"
  for _ in $(seq 1 "$seam_polls"); do
    [ -f "$seam.opened" ] && break
    sleep 0.01
  done
  [ -f "$seam.opened" ] || fail "the evidence-opened synchronization seam was never reached"
  mv "$case_dir/evidence/linked.log" "$case_dir/evidence/opened.log"
  cp "$case_dir/outside.log" "$case_dir/evidence/linked.log"
  printf 'continue\n' > "$seam.continue"
  for _ in $(seq 1 "$seam_polls"); do
    [ -f "$seam.hashed" ] && break
    sleep 0.01
  done
  [ -f "$seam.hashed" ] || fail "the opened evidence handle was never hashed"
  rm "$case_dir/evidence/linked.log"
  mv "$case_dir/evidence/opened.log" "$case_dir/evidence/linked.log"
  printf 'restored\n' > "$seam.restored"
  if wait "$prepare_pid"; then
    prepare_code=0
  else
    prepare_code=$?
  fi
  expect_code 0 "$prepare_code" "a pathname swap after opening must not change the bound bytes"
  assert_grep 'review-envelope: REVIEW_READY' "$case_dir/seam.out" \
    "the opened in-root evidence must remain review-ready after its pathname is swapped"
  python3 - "$case_dir" <<'PY' \
    || fail "the evidence digest must come from the opened handle, not its swapped pathname"
import hashlib, json, sys
case_dir = sys.argv[1]
block = json.load(open(case_dir + "/seam-engaged/envelope.json"))[
    "envelope"
]["verification"]["results"][1]["evidence"]
opened = "sha256:" + hashlib.sha256(
    open(case_dir + "/evidence/linked.log", "rb").read()
).hexdigest()
swapped = "sha256:" + hashlib.sha256(
    open(case_dir + "/outside.log", "rb").read()
).hexdigest()
if block.get("observed_sha256") != opened or block.get("observed_sha256") == swapped:
    sys.exit(1)
PY
  pass "a symlink cannot carry evidence outside its root into the envelope"
}

# The seam is reached through ambient environment variables, so the only thing
# a leaked variable may choose about it is a name inside a directory the library
# owns. A seam pointed anywhere else must refuse where it stands, must write
# nothing at the path it was handed, and must refuse as the contract's
# could-not-observe: a seam that answers a refusal with a traceback is a hole in
# the three-valued promise rather than a measurement affordance.
test_a_synchronization_seam_outside_its_root_refuses() {
  local case_dir seam seam_dir
  case_dir=$(make_case seam-outside-root)
  write_inputs "$case_dir"
  seam=$case_dir/caller-directed-seam
  capture run_prepare_with_seam "$case_dir" env "$seam" baseline.log
  expect_code 2 "$CAPTURED_CODE" \
    "a synchronization seam outside its root is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved evidence_seam_unusable' \
    "the refusal must name the seam in the contract's own closed vocabulary"
  assert_not_contains "$CAPTURED" 'Traceback' \
    "a seam refusal must never escape as a Python traceback"
  if [ -e "$seam.opened" ] || [ -e "$seam.hashed" ]; then
    fail "a refused seam must write nothing at the path it was pointed at"
  fi

  # The confinement root itself is not inside the confinement root. A seam
  # pointed exactly at it would put its signal files alongside the directory
  # rather than in it, which is the containment claim failing on its own
  # boundary.
  seam_dir=$(seam_root)
  [ -n "$seam_dir" ] \
    || fail "the seam_root helper could not read SEAM_DIRECTORY out of the library under test"
  rm -f "$seam_dir.opened" "$seam_dir.hashed"
  capture run_prepare_with_seam "$case_dir" root-exact "$seam_dir" baseline.log
  expect_code 2 "$CAPTURED_CODE" \
    "a synchronization seam pointed at the confinement root is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved evidence_seam_unusable' \
    "the boundary refusal must name the seam in the contract's own closed vocabulary"
  if [ -e "$seam_dir.opened" ] || [ -e "$seam_dir.hashed" ]; then
    rm -f "$seam_dir.opened" "$seam_dir.hashed"
    fail "a seam pointed at the confinement root must not write siblings of it"
  fi
  pass "a synchronization seam not strictly inside its confinement root refuses"
}

# The contract promises three values on EVERY path. An inputs document that
# parses as JSON but is malformed inside - an exclusion rule whose value is a
# number where a pattern belongs - reached a Python traceback instead: no
# classification, no summary file, and nothing for a --json consumer to read.
test_a_malformed_but_parseable_inputs_document_is_could_not_observe() {
  local case_dir
  case_dir=$(make_case inputs-malformed-within)
  write_inputs "$case_dir" '{"scope": {"excluded": [{"type": "prefix", "value": 123}]}}'
  capture run_prepare "$case_dir" env --json --summary-out "$case_dir/summary"
  expect_code 2 "$CAPTURED_CODE" \
    "inputs that parse but are malformed within are could-not-observe"
  assert_not_contains "$CAPTURED" 'Traceback' \
    "a malformed inputs document must never answer with a traceback"
  assert_contains "$CAPTURED" '"code": "inputs_malformed"' \
    "the classification must name the malformed inputs in the closed vocabulary"
  assert_contains "$CAPTURED" '"readiness": "COULD_NOT_OBSERVE"' \
    "a document this compiler could not observe must classify as could-not-observe"
  assert_grep 'result=NO_VERIFIER_RAN' "$case_dir/summary" \
    "the summary a caller reads must be written even when the inputs are malformed"
  pass "an inputs document that parses but is malformed within classifies rather than crashing"
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

test_a_relied_upon_ruling_with_empty_applicability_refuses() {
  local case_dir
  case_dir=$(make_case ruling-empty-applicability)
  write_inputs "$case_dir" '{"rulings": [
      {"id": "R-1", "source": "captain", "relied_upon": true, "applies_to": {}}]}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "an empty relied-upon ruling applicability refuses"
  assert_contains "$CAPTURED" 'unobserved ruling_applicability_unestablished' \
    "the absent candidate binding must remain could-not-establish"
  assert_contains "$CAPTURED" 'refusal ruling_applicability_unestablished_relied_upon' \
    "reliance on the unestablished ruling must refuse"
  pass "an empty applicability cannot authorize a relied-upon ruling"
}

test_work_identity_alone_does_not_establish_ruling_applicability() {
  local case_dir
  case_dir=$(make_case ruling-work-only-applicability)
  write_inputs "$case_dir" '{"rulings": [
      {"id": "R-1", "source": "captain", "relied_upon": true,
       "applies_to": {"work_id": "fixture-work"}}]}'
  capture run_prepare "$case_dir" env
  expect_code 1 "$CAPTURED_CODE" "work identity alone cannot bind a relied-upon ruling"
  assert_contains "$CAPTURED" 'unobserved ruling_applicability_unestablished' \
    "a work-only applicability must remain could-not-establish"
  assert_contains "$CAPTURED" 'refusal ruling_applicability_unestablished_relied_upon' \
    "reliance on the work-only ruling must refuse"
  pass "work identity alone cannot establish ruling applicability"
}

test_matching_candidate_axes_establish_ruling_applicability() {
  local case_dir head tree
  case_dir=$(make_case ruling-matching-applicability)
  head=$(git -C "$case_dir/repo" rev-parse candidate)
  tree=$(git -C "$case_dir/repo" rev-parse 'candidate^{tree}')
  write_inputs "$case_dir" '{"rulings": [
      {"id": "R-1", "source": "captain", "relied_upon": true,
       "applies_to": {"work_id": "fixture-work", "head": "'"$head"'", "tree": "'"$tree"'"}}]}'
  capture run_prepare "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" "matching candidate axes establish ruling applicability"
  assert_contains "$CAPTURED" 'review-envelope: REVIEW_READY' \
    "a candidate-bound ruling must remain accepted"
  pass "matching candidate axes establish ruling applicability"
}

test_unestablished_ruling_cannot_authorize_a_resolution() {
  local case_dir prior
  case_dir=$(make_case ruling-unestablished-authority)
  prior=$(seed_predecessor "$case_dir")
  write_inputs "$case_dir" '{
    "rulings": [{"id": "R-1", "source": "captain", "applies_to": {}}],
    "obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "RESOLVED", "authority": "R-1", "reason": "ruled moot"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]}}'
  capture run_prepare "$case_dir" successor --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "an unestablished ruling cannot authorize a resolution"
  assert_contains "$CAPTURED" 'refusal ruling_applicability_unestablished_relied_upon' \
    "the authority lookup must refuse an unestablished ruling"
  pass "an unestablished ruling cannot discharge an obligation"
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

  # THE CONTROL. The two assertions above are the non-vacuity anchor: they prove
  # the binding does not refuse spuriously. They cannot prove it ever refuses,
  # because acceptance is the path that still works with the guard deleted -
  # measured by removing both applicability sites and watching this suite stay
  # green. A guard's whole job is refusal, so the refusing assertion is the
  # measurement and the accepting one only shows the measurement is not trivial.
  write_inputs "$case_dir" '{
    "rulings": [{"id": "R-2", "source": "captain", "disposition": "APPROVE",
                 "relied_upon": true,
                 "applies_to": {"envelope_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"}}],
    "obligations": {
      "predecessor": {"envelope_digest": "'"$prior"'"},
      "active": [],
      "dispositions": [
        {"id": "OBL-1", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"},
        {"id": "OBL-2", "disposition": "RESOLVED", "authority": "captain", "reason": "withdrawn"}]}}'
  capture run_prepare "$case_dir" foreign --predecessor "$case_dir/prior"
  expect_code 1 "$CAPTURED_CODE" "a relied-upon ruling bound to another envelope must refuse"
  assert_contains "$CAPTURED" 'refusal ruling_applicability_mismatch' \
    "the refusal must name the applicability mismatch"
  assert_contains "$CAPTURED" 'envelope_digest' \
    "the refusal must say which applicability axis mismatched"

  pass "a ruling digest binds the current envelope, refusing a ruling bound to another"
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

# Rewrite one part of a compiled envelope's BODY and re-seal every digest that
# covers it. Without this a case cannot present a body the compiler would never
# emit: the body digest, the request identity and the outer integrity digest all
# refuse first, and the case would never reach the property it is aimed at.
reseal_envelope() {  # <envelope.json> <python statements over `body`>
  python3 - "$1" "$2" <<'PY' || fail "reseal_envelope could not rewrite the envelope"
import hashlib, json, sys

path, statements = sys.argv[1:]
document = json.load(open(path))
body = document["envelope"]
exec(statements, {}, {"body": body})


def digest(value):
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


body_digest = digest(body)
document["digest"]["value"] = body_digest
document["request_identity"] = digest({
    "project": {
        "id": body["identity"]["project"]["id"],
        "root_commits": body["identity"]["project"]["root_commits"],
    },
    "work": {
        "id": body["identity"]["work"]["id"],
        "forge_request": body["identity"]["work"].get("request"),
    },
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
}

# Validate <out> and require the digest the classification REPORTS to recompute
# from the body the classification READ. The comparison is against the bytes on
# disk rather than against the document's own stored digest field, so a
# classifier that edited its subject in flight cannot satisfy it by agreeing
# with a field it also rewrote.
assert_reported_digest_names_the_body() {  # <case-dir> <out-name> <message>
  local case_dir=$1 out=$2 message=$3
  capture run_validate "$case_dir" "$out" --json
  python3 - "$case_dir/$out/envelope.json" "$CAPTURED" <<'PY' || fail "$message"$'\n'"--- output ---"$'\n'"$CAPTURED"
import hashlib, json, sys

path, output = sys.argv[1:]
body = json.load(open(path))["envelope"]
encoded = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
recomputed = "sha256:" + hashlib.sha256(encoded).hexdigest()
# The entrypoint appends its own verify record after the JSON document, so the
# object is decoded from the start of the stream rather than from the whole of
# it.
start = output.find("{")
try:
    classification, _ = json.JSONDecoder().raw_decode(output[start:] if start >= 0 else output)
except ValueError:
    sys.stderr.write("the classification was not readable JSON\n")
    sys.exit(1)
reported = classification.get("envelope_digest")
if reported != recomputed:
    sys.stderr.write(
        "the classification reports %s for a body that digests to %s\n" % (reported, recomputed))
    sys.exit(1)
PY
}

# The contract binds by digest, so a classification's digest has to name the
# body it classified. A classifier that annotated the envelope in place before
# digesting it would report an identity for bytes that exist nowhere: not the
# input whose digest was just validated, and not anything on disk.
test_the_classification_digest_names_the_envelope_it_classified() {
  local case_dir head
  case_dir=$(make_case classification-digest-subject)
  head=$(git -C "$case_dir/repo" rev-parse candidate)
  write_inputs "$case_dir" '{"rulings": [
      {"id": "R-1", "source": "captain", "disposition": "APPROVE", "relied_upon": true,
       "applies_to": {"head": "'"$head"'"}}]}'
  capture run_prepare "$case_dir" env
  expect_code 0 "$CAPTURED_CODE" "the envelope under this case must compile"

  # NON-VACUITY. An untouched envelope reports its own digest, so the assertion
  # below is not one that rejects every classification it is shown.
  assert_reported_digest_names_the_body "$case_dir" env \
    "an untouched envelope's classification must report that envelope's digest"

  # THE CONTROL. The stored applicability is made to DISAGREE with what
  # classification re-derives, which is the only state in which annotating the
  # body in place changes its digest - and is exactly the state an envelope
  # compiled by an older build arrives in. Re-derivation itself is required and
  # is not what this measures; what it measures is that re-deriving does not
  # silently rewrite the subject whose identity is being reported.
  reseal_envelope "$case_dir/env/envelope.json" '
body["rulings"][0]["applicability_established"] = False
body["rulings"][0]["applicable"] = False
body["rulings"][0]["mismatches"] = ["work_id"]
'
  assert_reported_digest_names_the_body "$case_dir" env \
    "a classification must never report a digest for a body it rewrote in flight"
  pass "the digest a classification reports is the digest of the envelope it classified"
}

# git answers an ancestry question with yes, no, or nothing at all. The third
# answer is not the second: an ancestry that could not be computed is
# could-not-observe, and reading it as "does not contradict readiness" is
# absence read as satisfaction on an axis this compiler exists to refuse.
test_an_unreadable_ancestry_is_could_not_observe() {
  local case_dir real_git
  case_dir=$(make_case unreadable-ancestry)
  write_inputs "$case_dir"

  # NON-VACUITY, taken first so the shim below cannot be what makes it pass: a
  # readable ancestry still reaches review-ready.
  capture run_prepare "$case_dir" readable
  expect_code 0 "$CAPTURED_CODE" "a readable ancestry must still reach a verdict"
  assert_contains "$CAPTURED" 'review-envelope: REVIEW_READY' \
    "an ancestry git can answer must remain accepted"

  # THE CONTROL, first consumer: the base-to-trunk ancestry re-derived at
  # classification time. The shim refuses only `--is-ancestor` and delegates
  # every other command to the real git, so the ancestry answer is the single
  # thing the case changes.
  real_git=$(command -v git) || fail "this case needs a real git to delegate to"
  cat > "$case_dir/fakebin/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = --is-ancestor ]; then
    exit 128
  fi
done
exec "$real_git" "\$@"
EOF
  chmod +x "$case_dir/fakebin/git"
  capture run_prepare "$case_dir" unreadable
  expect_code 2 "$CAPTURED_CODE" "an ancestry git could not answer is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved repository_unreadable subject=base_is_ancestor_of_main' \
    "the unreadable base-to-trunk ancestry must be named as unobserved"
  assert_not_contains "$CAPTURED" 'REVIEW_READY' \
    "an ancestry nobody could read cannot support a review-ready verdict"
  rm -f "$case_dir/fakebin/git"

  # THE CONTROL, second consumer: the base-to-candidate ancestry BOUND at
  # compile time and read back at validation. A fix at one consumer leaves the
  # other authoritative, so this half runs against a real git and manufactures
  # the unread answer in the stored body instead.
  capture run_prepare "$case_dir" unread-binding
  expect_code 0 "$CAPTURED_CODE" "the envelope for the second consumer must compile"
  reseal_envelope "$case_dir/unread-binding/envelope.json" '
body["applicability"]["base_is_ancestor_of_head"] = None
'
  capture run_validate "$case_dir" unread-binding
  expect_code 2 "$CAPTURED_CODE" "an unread base-to-candidate ancestry is could-not-observe"
  assert_contains "$CAPTURED" 'unobserved repository_unreadable subject=base_is_ancestor_of_head' \
    "the unread base-to-candidate ancestry must be named as unobserved"
  assert_not_contains "$CAPTURED" 'REVIEW_READY' \
    "an ancestry bound as unread cannot support a review-ready verdict"
  pass "an ancestry git could not answer is could-not-observe at both consumers"
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

# A control count is a claim about a run that REACHED THE SUITE'S END, and this
# suite halts at its first failing control. So the record is allowed exactly two
# states, and absence is not one of them: a number, which must match, or an
# EXPLICIT declaration with a reason that no count is asserted yet. Demanding a
# number unconditionally is what once put an unmeasured number in the one
# section reserved for what was measured - the record had no way to say "not
# observed yet", so it said something nobody had seen.
#
# The deferral is not free-standing. It must NAME the stale subjects that make a
# count unobservable, and those must be the stale subjects this tree actually
# has - so the moment the campaign matches the shipped bytes again, the deferral
# is refused and a number is required. A REMEDY STATE MUST CARRY THE CONDITION
# THAT JUSTIFIES IT, CHECKED AGAINST THE WORLD, OR IT OUTLIVES IT.
check_recorded_control_count() {  # <record> <actual-count> <artifact> <root>
  python3 - "$@" <<'PYEOF'
import hashlib, json, re, sys

record_path, actual, artifact_path, root = sys.argv[1:]
record = open(record_path, encoding="utf-8").read()
try:
    artifact = json.load(open(artifact_path, encoding="utf-8"))
except (OSError, ValueError) as error:
    sys.stderr.write("campaign artifact is unreadable: %s\n" % error)
    sys.exit(1)

# The world the pending state is pending ON. A remedy state that does not carry
# its own condition outlives it: once the artifact matches the shipped bytes the
# suite can reach its end, a count IS observable, and an honest "not measurable
# yet" would quietly become "never measured".
stale = []
for path, recorded in sorted((artifact.get("subjects") or {}).items()):
    try:
        shipped = "sha256:" + hashlib.sha256(open(root + "/" + path, "rb").read()).hexdigest()
    except OSError as error:
        sys.stderr.write("measured subject is unreadable: %s\n" % error)
        sys.exit(1)
    if shipped != recorded:
        stale.append((path, recorded, shipped))

stated = re.findall(r"^([0-9]+) controls pass against the shipped scripts\.$", record, re.M)
pending = re.findall(r"^No control count is asserted at this head: (.+)$", record, re.M)
declared = re.findall(
    r"^- `([^`]+)` \u2014 artifact `(sha256:[0-9a-f]{64})`, shipped `(sha256:[0-9a-f]{64})`$",
    record, re.M)
if stated and pending:
    sys.stderr.write(
        "the record both states a control count and declares none asserted; one or the other\n")
    sys.exit(1)
if not stated and not pending:
    sys.stderr.write(
        "the record neither states a control count nor declares that none is asserted\n")
    sys.exit(1)
if pending:
    if len(pending) > 1:
        sys.stderr.write("the record declares no-count-asserted more than once\n")
        sys.exit(1)
    if not pending[0].strip():
        sys.stderr.write("the no-count-asserted declaration carries no reason\n")
        sys.exit(1)
    if not stale:
        sys.stderr.write(
            "the campaign artifact matches every shipped subject, so a run reaches the end of "
            "the suite and the control count is observable; it must be stated, not deferred\n")
        sys.exit(1)
    if declared != stale:
        sys.stderr.write(
            "the pending declaration does not name the stale subjects it is pending on: "
            "declared %r, observed %r\n" % (declared, stale))
        sys.exit(1)
    sys.exit(0)
if len(stated) > 1:
    sys.stderr.write("the record states more than one control count\n")
    sys.exit(1)
if stated[0] != actual:
    sys.stderr.write(
        "the verification record states %s controls, but the suite executed %s\n"
        % (stated[0], actual))
    sys.exit(1)
PYEOF
}

test_the_verification_record_matches_the_executed_control_count() {
  local record=$ROOT/docs/verification/review-envelope-controls.md
  local artifact=$ROOT/docs/verification/review-envelope-campaign.json
  local mutant=$TMP_ROOT/control-count-mutant.md
  local fresh_artifact=$TMP_ROOT/control-count-fresh-artifact.json
  local executed actual
  executed=$(printf '%s' "$FM_TEST_PASSED_TESTS" | awk 'NF' | LC_ALL=C sort -u | wc -l)
  actual=$((executed + 1))
  [ "$actual" -gt 1 ] || fail "the control-count comparison must observe executed controls"
  check_recorded_control_count "$record" "$actual" "$artifact" "$ROOT" \
    || fail "the verification record's control-count state is not one this suite can accept"

  # NON-VACUITY for the numeric branch, which the shipped record does not
  # exercise while the count is pending: a record stating the count this run
  # actually executed is accepted.
  count_mutant() {  # <replacement-block>
    python3 - "$record" "$mutant" "$1" <<'PYEOF'
import re, sys
source, target, replacement = sys.argv[1:]
record = open(source, encoding="utf-8").read()
pattern = r"^(?:[0-9]+ controls pass against the shipped scripts\.|No control count is asserted at this head: .+)$"
rewritten, count = re.subn(pattern, replacement.replace("\\", "\\\\"), record, count=1, flags=re.M)
if count != 1:
    sys.stderr.write("the record carries no control-count statement to replace\n")
    sys.exit(1)
open(target, "w", encoding="utf-8").write(rewritten)
PYEOF
  }
  count_mutant "$actual controls pass against the shipped scripts." \
    || fail "the correct-count mutant must build"
  check_recorded_control_count "$mutant" "$actual" "$artifact" "$ROOT" \
    || fail "a record stating the count this run executed must be accepted"

  # THE CONTROL. Drift in the number is what this exists to catch.
  count_mutant "1 controls pass against the shipped scripts." \
    || fail "the wrong-count mutant must build"
  capture check_recorded_control_count "$mutant" "$actual" "$artifact" "$ROOT"
  expect_code 1 "$CAPTURED_CODE" "a record stating a count the suite did not execute must fail"
  assert_contains "$CAPTURED" 'but the suite executed' \
    "the failure must name both the stated and the executed count"

  # Neither state. An absent count must not read as a satisfied one.
  count_mutant "The record says nothing about how many controls ran." \
    || fail "the absent-count mutant must build"
  capture check_recorded_control_count "$mutant" "$actual" "$artifact" "$ROOT"
  expect_code 1 "$CAPTURED_CODE" "a record asserting no count and declaring none must fail"
  assert_contains "$CAPTURED" 'neither states a control count nor declares' \
    "the failure must say the record declared nothing"

  # Both states. A pending declaration standing beside a number would let a
  # reader take the number as measured and the control as satisfied.
  count_mutant "$actual controls pass against the shipped scripts."$'\n'"No control count is asserted at this head: measured subjects changed." \
    || fail "the both-states mutant must build"
  capture check_recorded_control_count "$mutant" "$actual" "$artifact" "$ROOT"
  expect_code 1 "$CAPTURED_CODE" "a record both stating and disclaiming a count must fail"
  assert_contains "$CAPTURED" 'both states a control count and declares none asserted' \
    "the failure must name the contradiction"

  # THE DEFERRAL'S EXIT CONDITION. Against an artifact that matches the shipped
  # subjects, a run reaches the end of the suite and a count IS observable, so
  # the pending state must be refused from that moment rather than standing on
  # its own reasonableness. BOTH halves of the condition are built here rather
  # than borrowed: the artifact mutant because the shipped one is stale by
  # design, and the pending record mutant because the shipped record leaves the
  # pending state the moment the campaign is re-measured - a control that only
  # refuses while an ambient fact happens to hold measures nothing.
  python3 - "$artifact" "$fresh_artifact" "$ROOT" <<'PYEOF'
import hashlib, json, sys
source, target, root = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
artifact["subjects"] = {
    path: "sha256:" + hashlib.sha256(open(root + "/" + path, "rb").read()).hexdigest()
    for path in artifact.get("subjects", {})
}
with open(target, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle)
PYEOF
  count_mutant "No control count is asserted at this head: measured subjects changed." \
    || fail "the deferred-count mutant must build"
  capture check_recorded_control_count "$mutant" "$actual" "$fresh_artifact" "$ROOT"
  expect_code 1 "$CAPTURED_CODE" "a deferred count must be refused once the campaign matches the tree"
  assert_contains "$CAPTURED" 'it must be stated, not deferred' \
    "the failure must say the count is observable again"

  # And the deferral must name the stale subjects THIS TREE has, not a set it
  # chose. A declaration naming nothing is a reason without a condition. The
  # condition is MANUFACTURED whole: a pending record carrying no subject
  # bullets, against an artifact made stale by construction, so the case holds
  # whichever state the shipped record and campaign happen to be in.
  count_mutant "No control count is asserted at this head: measured subjects changed." \
    || fail "the unnamed-subjects mutant must build"
  python3 - "$mutant" <<'PYEOF'
import re, sys
path = sys.argv[1]
record = open(path, encoding="utf-8").read()
record = re.sub(
    r"^- `[^`]+` \u2014 artifact `sha256:[0-9a-f]{64}`, shipped `sha256:[0-9a-f]{64}`\n",
    "", record, flags=re.M)
open(path, "w", encoding="utf-8").write(record)
PYEOF
  python3 - "$artifact" "$fresh_artifact" <<'PYEOF'
import json, sys
source, target = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
subject = sorted(artifact.get("subjects", {}))[0]
artifact["subjects"][subject] = "sha256:" + "0" * 64
with open(target, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle)
PYEOF
  capture check_recorded_control_count "$mutant" "$actual" "$fresh_artifact" "$ROOT"
  expect_code 1 "$CAPTURED_CODE" "a deferral that names no stale subject must fail"
  assert_contains "$CAPTURED" 'does not name the stale subjects it is pending on' \
    "the failure must say the condition was not declared"
  pass "the verification record states a control count this run executed, or defers it on stale subjects this tree actually has"
}

# The mutation table is prose, and prose is not the evidence. Every row in it
# claims a red somebody watched, so every row must correspond to an expected-red
# entry in the campaign artifact and every expected-red entry must have a row.
# Nothing checked that, and both directions had already drifted: one row outlived
# its mutation's REMOVAL from the campaign, and two measured entries had no row
# at all. A reader believes whichever of the two the record reaches them with.
check_mutation_table() {  # <artifact> <record>
  python3 - "$@" <<'PYEOF'
import json, re, sys

artifact_path, record_path = sys.argv[1:]
try:
    artifact = json.load(open(artifact_path, encoding="utf-8"))
except (OSError, ValueError) as error:
    sys.stderr.write("campaign artifact is unreadable: %s\n" % error)
    sys.exit(1)
record = open(record_path, encoding="utf-8").read()

# Only the four-column mutation rows. The direct-measurement and record-control
# tables carry three columns and make a different claim, which is why they are
# separate tables rather than more rows here.
ROW = re.compile(
    r"^\| (.*?) \| .*? \| `(test_[a-z0-9_]+)` \| `(.*)` \|$", re.M)
rows = [match.groups() for match in ROW.finditer(record)]
if not rows:
    sys.stderr.write("the record carries no mutation-table rows to check\n")
    sys.exit(1)

# The row's FIRST column is part of the binding, not decoration. A row that
# matched on the control and the observed line alone would be credited with a
# measured red while naming a different property under test - a real red
# establishing something nobody examined, which is the wrong-subject shape this
# component has already produced three times elsewhere.
#
# The record's observed cell is the artifact's observed line truncated to the
# table's width, so a row is backed when its cell is a PREFIX of a measured
# line. Matching on the prefix keeps this checking the claim the record makes
# rather than assuming a truncation width.
unmatched = [
    (entry.get("property") or "", entry.get("observed_control"), entry.get("observed") or "")
    for entry in artifact.get("mutations", [])
    if entry.get("expected", "red") == "red"
]
status = 0
for prop, control, observed in rows:
    for index, (measured_property, measured_control, measured_observed) in enumerate(unmatched):
        if (measured_property == prop and measured_control == control
                and measured_observed.startswith(observed)):
            unmatched.pop(index)
            break
    else:
        # Separate the two failures, because they are different facts: a red
        # nobody measured, and a red measured for another property.
        misattributed = [
            measured_property
            for measured_property, measured_control, measured_observed in unmatched
            if measured_control == control and measured_observed.startswith(observed)
        ]
        if misattributed:
            sys.stderr.write(
                "the record credits a red to the wrong property: row says %r, the campaign "
                "measured it for %r\n" % (prop, misattributed[0]))
        else:
            sys.stderr.write(
                "the record claims a red no campaign entry backs: %s / %s\n" % (control, observed))
        status = 1
for prop, control, observed in unmatched:
    sys.stderr.write(
        "the campaign measured a red the record has no row for: %s / %s\n" % (control, observed))
    status = 1
sys.exit(status)
PYEOF
}

test_the_mutation_table_matches_the_campaign_artifact() {
  local artifact=$ROOT/docs/verification/review-envelope-campaign.json
  local record=$ROOT/docs/verification/review-envelope-controls.md
  local mutant_record=$TMP_ROOT/mutation-table-mutant.md
  [ -f "$artifact" ] || fail "the campaign artifact is absent, so no table row is checkable"
  check_mutation_table "$artifact" "$record" \
    || fail "the mutation table does not match the campaign artifact"

  # A row the campaign never measured. This is the direction that already
  # happened: a mutation was removed from the campaign and its row was left.
  python3 - "$record" "$mutant_record" <<'PYEOF'
import sys
source, target = sys.argv[1:]
record = open(source, encoding="utf-8").read()
row = "| a property nobody measured | a mutation nobody built | `test_a_complete_candidate_is_review_ready` | `not ok - a red nobody watched` |\n"
marker = "| Property under test | Mutation injected | Control observed red | Observed result |\n"
if marker not in record:
    sys.stderr.write("the mutation table header was not found\n")
    sys.exit(1)
head, _, tail = record.partition(marker)
open(target, "w", encoding="utf-8").write(head + marker + tail.split("\n", 1)[0] + "\n" + row + tail.split("\n", 1)[1])
PYEOF
  capture check_mutation_table "$artifact" "$mutant_record"
  expect_code 1 "$CAPTURED_CODE" "a row no campaign entry backs must fail"
  assert_contains "$CAPTURED" 'the record claims a red no campaign entry backs' \
    "the failure must name the unbacked row"

  # A measured red with no row. This is the other direction, and it drifted too.
  python3 - "$record" "$mutant_record" <<'PYEOF'
import re, sys
source, target = sys.argv[1:]
record = open(source, encoding="utf-8").read()
rows = re.findall(r"^\| .*? \| .*? \| `test_[a-z0-9_]+` \| `.*` \|$", record, re.M)
if not rows:
    sys.stderr.write("the mutation table carries no row to drop\n")
    sys.exit(1)
open(target, "w", encoding="utf-8").write(record.replace(rows[0] + "\n", "", 1))
PYEOF
  capture check_mutation_table "$artifact" "$mutant_record"
  expect_code 1 "$CAPTURED_CODE" "a measured red with no row must fail"
  assert_contains "$CAPTURED" 'the campaign measured a red the record has no row for' \
    "the failure must name the measured entry with no row"

  # A row that keeps a real measured red and renames the property it is credited
  # with establishing. The red happened; the claim built on it did not. This is
  # the direction a binding on control-plus-observed-line alone cannot see.
  python3 - "$record" "$mutant_record" <<'PYEOF'
import re, sys
source, target = sys.argv[1:]
record = open(source, encoding="utf-8").read()
match = re.search(r"^\| (.*?) \| (.*? \| `test_[a-z0-9_]+` \| `.*` \|)$", record, re.M)
if not match:
    sys.stderr.write("the mutation table carries no row to re-credit\n")
    sys.exit(1)
rewritten = "| a property this red never examined | " + match.group(2)
open(target, "w", encoding="utf-8").write(record.replace(match.group(0), rewritten, 1))
PYEOF
  capture check_mutation_table "$artifact" "$mutant_record"
  expect_code 1 "$CAPTURED_CODE" "a red credited to the wrong property must fail"
  assert_contains "$CAPTURED" 'the record credits a red to the wrong property' \
    "the failure must say the row names a property the campaign measured for another"
  pass "every mutation-table row is backed by a campaign entry for its own property, and every entry has a row"
}

# The measurement record's claims are checked against a durable artifact rather
# than taken on their own word. A prior commit on this branch retitled itself
# "record final-head mutation campaign", ran nothing, and relabelled
# measurements taken at one head as taken at another - and every check in this
# suite still passed, because nothing bound the prose to the experiment.
#
# The binding is by CONTENT DIGEST of the measured subjects, not by a commit
# label, because a label can be rewritten as cheaply as the sentence it appears
# in. This deliberately couples to subject identity rather than to subject text:
# it never asserts what any source byte is, only that the bytes measured are the
# bytes shipped.
test_the_measurement_record_is_backed_by_the_campaign_artifact() {
  local artifact=$ROOT/docs/verification/review-envelope-campaign.json
  local record=$ROOT/docs/verification/review-envelope-controls.md
  local replay_root=$TMP_ROOT/campaign-replay
  [ -f "$artifact" ] || fail "the campaign artifact is absent, so no measurement claim is checkable"
  check_campaign_artifact "$artifact" "$record" "$ROOT" "$replay_root" \
    || fail "the measurement record is not backed by the campaign artifact"

  local mutant=$TMP_ROOT/campaign-mutant.json
  local mutant_record=$TMP_ROOT/campaign-mutant-record.md

  # An artifact that simply stops naming a subject would satisfy a check that
  # only compares what it does name, and would say nothing about the rest.
  python3 - "$artifact" "$mutant" <<'PYEOF'
import json, sys
source, target = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
del artifact["subjects"]["tests/fm-review-envelope.test.sh"]
with open(target, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle)
PYEOF
  capture check_campaign_artifact "$mutant" "$record" "$ROOT" "$TMP_ROOT/campaign-subject-absent"
  assert_contains "$CAPTURED" 'records no digest for tests/fm-review-envelope.test.sh' \
    "an artifact that drops a measured subject must fail for the missing subject"

  # The citation is the subject digests. A record citing a digest the artifact
  # never measured is the relabelling defect wearing the new citation.
  python3 - "$record" "$mutant_record" <<'PYEOF'
import re, sys
source, target = sys.argv[1:]
record = open(source, encoding="utf-8").read()
record = re.sub(
    r"^(- `bin/fm-review-envelope\.sh` \u2014 `)sha256:[0-9a-f]{64}`$",
    r"\1sha256:" + "0" * 64 + "`",
    record,
    flags=re.M,
)
open(target, "w", encoding="utf-8").write(record)
PYEOF
  if cmp -s "$record" "$mutant_record"; then
    fail "the citation mutant must actually change the record's cited digest"
  fi
  capture check_campaign_artifact "$artifact" "$mutant_record" "$ROOT" "$TMP_ROOT/campaign-citation"
  assert_contains "$CAPTURED" 'record cites sha256:0000000000000000000000000000000000000000000000000000000000000000' \
    "a record citing a digest the artifact never measured must fail"

  # A head offered as a replay coordinate has to resolve. The condition is
  # MANUFACTURED here rather than borrowed from whatever the record happens to
  # cite: an earlier version of this control stripped the provenance-only label
  # and relied on the cited head being stranded by a past rebase, so it went
  # vacuous the moment the campaign was re-measured at a reachable head. A
  # control that only refuses while an ambient fact happens to hold is not
  # measuring the property it names.
  python3 - "$record" "$mutant_record" <<'PYEOF'
import re, sys
source, target = sys.argv[1:]
record = open(source, encoding="utf-8").read()
record = re.sub(
    r"^Campaign head: `([0-9a-f]{7,40})`( \(provenance only\))?\.$",
    "Campaign head: `deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`.",
    record,
    flags=re.M,
)
open(target, "w", encoding="utf-8").write(record)
PYEOF
  if cmp -s "$record" "$mutant_record"; then
    fail "the head mutant must actually replace the cited head"
  fi
  # The artifact's head moves with it. A record disagreeing with the artifact is
  # already refused by the check above, and that refusal would satisfy a
  # reachability assertion without ever reaching the reachability question - so
  # the pair is made CONSISTENT and unreachable, leaving reachability as the only
  # thing left to fail on.
  python3 - "$artifact" "$mutant" <<'PYEOF'
import json, sys
source, target = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
artifact["head"] = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
json.dump(artifact, open(target, "w", encoding="utf-8"), indent=2, sort_keys=True)
PYEOF
  capture check_campaign_artifact "$mutant" "$mutant_record" "$ROOT" "$TMP_ROOT/campaign-head"
  assert_contains "$CAPTURED" 'is not reachable from this branch' \
    "a head offered as a replay coordinate that the branch does not carry must fail"

  # NON-VACUITY: the refusal above must be about REACHABILITY, not about the
  # label. An unlabelled head that IS reachable is accepted; without this the
  # check could refuse every unlabelled head and still pass. This condition is
  # MANUFACTURED for the same reason its refusing twin is: an earlier version
  # stripped the label off the record's own head and relied on that head still
  # being an ancestor of HEAD, which any rebase ends, so the anchor passed or
  # failed on where the campaign happened to be measured rather than on the
  # check. HEAD is reachable from HEAD under every lineage, so the pair is
  # rewritten to cite it - record and artifact together, per entry included,
  # since a head/artifact disagreement would refuse before reachability is ever
  # reached.
  local current_head
  current_head=$(git -C "$ROOT" rev-parse HEAD) \
    || fail "the reachable-head case needs this branch's head to manufacture its condition"
  python3 - "$record" "$mutant_record" "$current_head" <<'PYEOF'
import re, sys
source, target, head = sys.argv[1:]
record = open(source, encoding="utf-8").read()
record, replaced = re.subn(
    r"^Campaign head: `[0-9a-f]{7,40}`( \(provenance only\))?\.$",
    "Campaign head: `%s`." % head,
    record,
    flags=re.M,
)
if replaced != 1:
    sys.stderr.write("expected exactly one campaign head line, rewrote %d\n" % replaced)
    sys.exit(1)
open(target, "w", encoding="utf-8").write(record)
PYEOF
  # The label assertion is scoped to the campaign-head line, because the label
  # this guard is about lives there; the record legitimately labels other
  # citations provenance-only, and a whole-document grep would fail on prose
  # this control makes no claim about.
  if grep -E '^Campaign head: ' "$mutant_record" | grep -q 'provenance only' \
    || ! grep -qF "Campaign head: \`$current_head\`." "$mutant_record"; then
    fail "the non-vacuity mutant must cite this branch's head with no provenance-only label"
  fi
  python3 - "$artifact" "$mutant" "$current_head" <<'PYEOF'
import json, sys
source, target, head = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
artifact["head"] = head
for entry in artifact["mutations"]:
    entry["head"] = head
json.dump(artifact, open(target, "w", encoding="utf-8"), indent=2, sort_keys=True)
PYEOF
  FM_REVIEW_ENVELOPE_SKIP_CAMPAIGN_REPLAY=1 \
    capture check_campaign_artifact "$mutant" "$mutant_record" "$ROOT" "$TMP_ROOT/campaign-head-reachable"
  expect_code 0 "$CAPTURED_CODE" \
    "a reachable head cited without the provenance label is still accepted"

  python3 - "$artifact" "$mutant" missing <<'PYEOF'
import json, sys
source, target, mutation = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
entry = min(artifact["mutations"], key=lambda item: item["id"])
if mutation == "missing":
    del entry["replay_patch"]
with open(target, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle)
PYEOF
  capture check_campaign_artifact "$mutant" "$record" "$ROOT" "$TMP_ROOT/campaign-missing"
  assert_contains "$CAPTURED" 'carries no replay_patch' \
    "an entry with no replay patch must fail for the missing replay material"

  python3 - "$artifact" "$mutant" <<'PYEOF'
import json, sys
source, target = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
entry = min(artifact["mutations"], key=lambda item: item["id"])
entry["replay_patch"] += "\n"
with open(target, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle)
PYEOF
  capture check_campaign_artifact "$mutant" "$record" "$ROOT" "$TMP_ROOT/campaign-mismatch"
  assert_contains "$CAPTURED" 'replay patch digest does not match' \
    "an entry whose replay patch digest is stale must fail for that mismatch"

  python3 - "$artifact" "$mutant" <<'PYEOF'
import hashlib, json, sys
source, target = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
entry = min(artifact["mutations"], key=lambda item: item["id"])
entry["replay_patch"] = entry["replay_patch"].replace("@@ ", "@@ broken ", 1)
entry["replay_patch_sha256"] = "sha256:" + hashlib.sha256(
    entry["replay_patch"].encode("utf-8")
).hexdigest()
with open(target, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle)
PYEOF
  capture check_campaign_artifact "$mutant" "$record" "$ROOT" "$TMP_ROOT/campaign-corrupt"
  assert_contains "$CAPTURED" 'replay patch could not rebuild its variant' \
    "a correctly digested patch that cannot rebuild its variant must fail the deep replay"

  python3 - "$artifact" "$mutant" <<'PYEOF'
import json, sys
source, target = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
artifact["control_order"] = ["matching-control", "test_array_classifications_are_exercised_in_isolation"]
for item in artifact["mutations"]:
    # This fixture stamps a FAILING captured run onto every entry, so every entry
    # it produces is red-shaped. An expected-green entry carrying a failing run
    # would contradict itself, and the contradiction would be the fixture's
    # rather than the validator's - so the expectation is normalised with the
    # shape, not left to disagree with it.
    item["expected"] = "red"
    item["captured_output"] = "not ok - synthetic\n"
    item["output_sha256"] = "sha256:" + __import__("hashlib").sha256(item["captured_output"].encode()).hexdigest()
    item["observed_control"] = item["target_control"] = "matching-control"
entry = next(item for item in artifact["mutations"] if item["id"] == "exact-head-association-lost")
entry["captured_output"] = "ok - earlier control\nnot ok - real mismatched control\n"
entry["output_sha256"] = "sha256:" + __import__("hashlib").sha256(entry["captured_output"].encode()).hexdigest()
entry["observed_control"] = "test_array_classifications_are_exercised_in_isolation"
entry["target_control"] = "test_wrong_head_ci_refuses"
with open(target, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle)
PYEOF
  capture check_campaign_artifact "$mutant" "$record" "$ROOT" "$TMP_ROOT/campaign-wrong-control"
  assert_contains "$CAPTURED" 'targeted test_wrong_head_ci_refuses but observed test_array_classifications_are_exercised_in_isolation' \
    "a real campaign mismatch must fail instead of counting as property coverage"

  python3 - "$artifact" "$mutant" <<'PYEOF'
import json, sys
source, target = sys.argv[1:]
artifact = json.load(open(source, encoding="utf-8"))
artifact["control_order"] = ["matching-control"]
for entry in artifact["mutations"]:
    # Red-shaped by construction, so the expectation is normalised with it: an
    # entry declaring green while carrying a failure is the fixture's
    # contradiction, not the validator's.
    entry["expected"] = "red"
    entry["captured_output"] = "not ok - matching control\n"
    entry["output_sha256"] = "sha256:" + __import__("hashlib").sha256(entry["captured_output"].encode()).hexdigest()
    entry["target_control"] = entry["observed_control"] = "matching-control"
with open(target, "w", encoding="utf-8") as handle:
    json.dump(artifact, handle)
PYEOF
  FM_REVIEW_ENVELOPE_SKIP_CAMPAIGN_REPLAY=1 \
    check_campaign_artifact "$mutant" "$record" "$ROOT" "$TMP_ROOT/campaign-matching" \
    || fail "an agreeing target and observed control must pass"
  pass "the measurement record's claims are backed by the campaign artifact"
}

check_campaign_artifact() {
  python3 - "$@" <<'PYEOF'
import hashlib, json, os, re, shutil, subprocess, sys

artifact_path, record_path, root, replay_root = sys.argv[1:]
try:
    artifact = json.load(open(artifact_path, encoding="utf-8"))
except (OSError, ValueError) as error:
    sys.stderr.write("campaign artifact is unreadable: %s\n" % error)
    sys.exit(1)
record = open(record_path, encoding="utf-8").read()

# The subjects the campaign measured. Naming them here rather than accepting
# whatever the artifact happens to list is the difference between "every subject
# recorded still matches" and "every subject measured is recorded": an artifact
# that simply drops a subject would satisfy the first and say nothing.
REQUIRED_SUBJECTS = (
    "bin/fm-review-envelope-lib.sh",
    "bin/fm-review-envelope.sh",
    "tests/fm-review-envelope.test.sh",
)
subjects = artifact.get("subjects") or {}
for required in REQUIRED_SUBJECTS:
    if required not in subjects:
        sys.stderr.write("the campaign artifact records no digest for %s\n" % required)
        sys.exit(1)

# The measured subjects must still be the shipped subjects, byte for byte.
for path, recorded in sorted(subjects.items()):
    try:
        actual = "sha256:" + hashlib.sha256(open(root + "/" + path, "rb").read()).hexdigest()
    except OSError as error:
        sys.stderr.write("measured subject is unreadable: %s\n" % error)
        sys.exit(1)
    if actual != recorded:
        sys.stderr.write(
            "%s changed since the campaign: measured %s, shipped %s\n" % (path, recorded, actual))
        sys.exit(1)

# The CITATION is the subject digests, because a record about a subject names
# the subject. Checking that the prose cites them is what makes the record
# replayable from the branch alone; comparing two fields of the same artifact to
# each other would establish only that the artifact agrees with itself.
for path, recorded in sorted(subjects.items()):
    cited = re.search(
        r"^- `" + re.escape(path) + r"` \u2014 `(sha256:[0-9a-f]{64})`$", record, re.M)
    if not cited:
        sys.stderr.write("the record cites no subject digest for %s\n" % path)
        sys.exit(1)
    if cited.group(1) != recorded:
        sys.stderr.write(
            "record cites %s for %s, artifact measured %s\n" % (cited.group(1), path, recorded))
        sys.exit(1)

# The record's stated head must be the artifact's, so relabelling the prose
# alone contradicts the experiment instead of quietly redescribing it. A head is
# additionally either RESOLVABLE or explicitly labelled provenance-only, because
# an unresolvable commit offered as a replay coordinate sends an independent
# party somewhere that does not exist. A rebase strands a head while changing no
# measured byte, so the label is the honest answer rather than a re-stamp.
stated = re.search(
    r"^Campaign head: `([0-9a-f]{7,40})`( \(provenance only\))?\.$", record, re.M)
if not stated:
    sys.stderr.write("the record states no campaign head in the required form\n")
    sys.exit(1)
if stated.group(1) != artifact.get("head"):
    sys.stderr.write(
        "record states campaign head %s, artifact was produced at %s\n"
        % (stated.group(1), artifact.get("head")))
    sys.exit(1)
if not stated.group(2):
    # Reachability from this branch, not mere object presence. The stranded head
    # is still an object in THIS clone, held alive by a local pre-rebase backup
    # ref, so asking whether it resolves would answer yes here and no for
    # everyone who fetches the branch - which is the whole defect.
    reachable = subprocess.run(
        ["git", "-C", root, "merge-base", "--is-ancestor", stated.group(1), "HEAD"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if reachable.returncode:
        sys.stderr.write(
            "record offers campaign head %s as a replay coordinate and it is not reachable from "
            "this branch; label it provenance-only or cite something that is\n" % stated.group(1))
        sys.exit(1)

built = re.search(r"^Mutations built: ([0-9]+)\.$", record, re.M)
if not built:
    sys.stderr.write("the record states no mutation count in the required form\n")
    sys.exit(1)
mutations = artifact.get("mutations", [])
if int(built.group(1)) != len(mutations):
    sys.stderr.write(
        "record states %s mutations, artifact holds %d\n"
        % (built.group(1), len(mutations)))
    sys.exit(1)
control_order = artifact.get("control_order")
if not isinstance(control_order, list) or not control_order or any(
        not isinstance(control, str) or not control for control in control_order):
    sys.stderr.write("the campaign artifact carries no usable control invocation order\n")
    sys.exit(1)

# Each entry records the head it was measured at, so relabelling the artifact's
# single head cannot silently re-attribute entries measured somewhere else. That
# is not hypothetical: a commit on this branch did exactly that to 69 entries,
# and every check in this suite passed because only one head was written down.
for entry in mutations:
    if entry.get("head") != artifact.get("head"):
        sys.stderr.write(
            "mutation %s was measured at %s, artifact claims %s\n"
            % (entry.get("id"), entry.get("head"), artifact.get("head")))
        sys.exit(1)
    # Material that cannot be produced without executing, and that an
    # independent party can replay: the patch that rebuilds the variant, and a
    # digest of the whole captured run to compare against.
    for field in ("observed", "captured_output", "output_sha256", "replay_patch", "replay_patch_sha256"):
        if not entry.get(field):
            sys.stderr.write(
                "mutation %s carries no %s, so its result is self-attested\n"
                % (entry.get("id"), field))
            sys.exit(1)
    replay_patch_sha256 = "sha256:" + hashlib.sha256(
        entry["replay_patch"].encode("utf-8")
    ).hexdigest()
    if replay_patch_sha256 != entry["replay_patch_sha256"]:
        sys.stderr.write(
            "mutation %s replay patch digest does not match: recorded %s, observed %s\n"
            % (entry.get("id"), entry["replay_patch_sha256"], replay_patch_sha256)
        )
        sys.exit(1)
    # A campaign in which EVERY mutation reddens cannot show that this harness is
    # able to report green at all, which is the vacuous-pass defect inverted: a
    # suite that fails on everything produces a perfect-looking record and proves
    # nothing. So the campaign carries its own non-vacuity control - a mutation
    # chosen so that green is the CORRECT answer - and that entry is judged
    # against the opposite expectation rather than exempted from judgement.
    expected = entry.get("expected", "red")
    if expected not in ("red", "green"):
        sys.stderr.write(
            "mutation %s declares an unknown expectation %r\n" % (entry.get("id"), expected))
        sys.exit(1)
    if expected == "green":
        if any(line.startswith("not ok") for line in entry["captured_output"].splitlines()):
            sys.stderr.write(
                "mutation %s expected green and its captured run contains a failure\n"
                % entry.get("id"))
            sys.exit(1)
        if entry.get("observed_control") or entry.get("target_control"):
            sys.stderr.write(
                "mutation %s expected green and must name no control\n" % entry.get("id"))
            sys.exit(1)
        captured_output_sha256 = "sha256:" + hashlib.sha256(
            entry["captured_output"].encode("utf-8")).hexdigest()
        if captured_output_sha256 != entry["output_sha256"]:
            sys.stderr.write(
                "mutation %s captured output digest does not match\n" % entry.get("id"))
            sys.exit(1)
        continue
    target_control = entry.get("target_control")
    observed_control = entry.get("observed_control")
    if not target_control or not observed_control:
        sys.stderr.write(
            "mutation %s does not bind its target control to its observed control\n"
            % entry.get("id")
        )
        sys.exit(1)
    captured_output_sha256 = "sha256:" + hashlib.sha256(
        entry["captured_output"].encode("utf-8")
    ).hexdigest()
    if captured_output_sha256 != entry["output_sha256"]:
        sys.stderr.write(
            "mutation %s captured output digest does not match\n" % entry.get("id")
        )
        sys.exit(1)
    success_count = sum(
        line.startswith("ok - ") for line in entry["captured_output"].splitlines()
    )
    if success_count >= len(control_order):
        sys.stderr.write(
            "mutation %s captured output does not identify a failing control\n" % entry.get("id")
        )
        sys.exit(1)
    derived_control = control_order[success_count]
    if observed_control != derived_control:
        sys.stderr.write(
            "mutation %s records observed control %s but captured output identifies %s\n"
            % (entry.get("id"), observed_control, derived_control)
        )
        sys.exit(1)
    if target_control != observed_control:
        sys.stderr.write(
            "mutation %s targeted %s but observed %s\n"
            % (entry.get("id"), target_control, observed_control)
        )
        sys.exit(1)

if (os.environ.get("FM_REVIEW_ENVELOPE_CAMPAIGN_REPLAY_CHILD") == "1"
        or os.environ.get("FM_REVIEW_ENVELOPE_SKIP_CAMPAIGN_REPLAY") == "1"):
    sys.exit(0)

# An artifact with no entries records no measurements, which is a clean refusal
# rather than a crash: raising here would report a broken control where the real
# fact is an empty campaign, and the two must not be confused.
if not mutations:
    sys.stderr.write("the campaign artifact records no measurements, so nothing is backed by it\n")
    sys.exit(1)

# Replay the lexically first mutation id, so every verifier exercises the same
# deep proof and its result never depends on chance or artifact ordering.
entry = min(mutations, key=lambda item: item["id"])
shutil.rmtree(replay_root, ignore_errors=True)
shutil.copytree(root, replay_root, symlinks=True)
variant_root = os.path.join(replay_root, "campaign-variant")
os.makedirs(os.path.join(variant_root, "bin"))
for subject in ("bin/fm-review-envelope.sh", "bin/fm-review-envelope-lib.sh"):
    shutil.copy2(os.path.join(root, subject), os.path.join(variant_root, subject))

patch_lines = entry["replay_patch"].splitlines(keepends=True)
for index, prefix in ((0, "--- "), (1, "+++ ")):
    if index >= len(patch_lines) or not patch_lines[index].startswith(prefix):
        sys.stderr.write("mutation %s replay patch could not rebuild its variant\n" % entry["id"])
        sys.exit(1)
    original = patch_lines[index][len(prefix):].split("\t", 1)[0]
    subject = next((path for path in artifact["subjects"] if original.endswith("/" + path)), None)
    if subject not in ("bin/fm-review-envelope.sh", "bin/fm-review-envelope-lib.sh"):
        sys.stderr.write("mutation %s replay patch could not rebuild its variant\n" % entry["id"])
        sys.exit(1)
    patch_lines[index] = prefix + subject + "\n"
applied = subprocess.run(
    ["patch", "-p0", "--batch", "--forward"], cwd=variant_root,
    input="".join(patch_lines).encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
)
if applied.returncode:
    sys.stderr.write("mutation %s replay patch could not rebuild its variant\n" % entry["id"])
    sys.exit(1)

environment = os.environ.copy()
environment["FM_REVIEW_ENVELOPE_BIN"] = os.path.join(
    variant_root, "bin", "fm-review-envelope.sh"
)
environment["FM_REVIEW_ENVELOPE_CAMPAIGN_REPLAY_CHILD"] = "1"
replayed = subprocess.run(
    ["bash", os.path.join(replay_root, "tests", "fm-review-envelope.test.sh")],
    cwd=replay_root, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
)
observed_output_sha256 = "sha256:" + hashlib.sha256(replayed.stdout).hexdigest()
if observed_output_sha256 != entry["output_sha256"]:
    sys.stderr.write(
        "mutation %s replayed output digest does not match: recorded %s, observed %s\n"
        % (entry["id"], entry["output_sha256"], observed_output_sha256)
    )
    sys.exit(1)
PYEOF
}

test_a_complete_candidate_is_review_ready
test_required_contracts_are_computed_from_the_changed_files
test_verification_applicability_must_be_declared_explicitly
test_no_verification_contracts_requires_an_explicit_reason
test_requested_decision_is_an_uppercase_token
test_identical_facts_produce_an_identical_digest
test_order_insensitive_facts_produce_an_identical_identity
test_nested_order_insensitive_facts_produce_an_identical_identity
test_array_classification_registry_is_total
test_array_classifications_are_exercised_in_isolation
test_ci_canonicalization_preserves_meaningful_differences
test_exclusion_rule_order_remains_meaningful
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
test_a_synchronization_seam_outside_its_root_refuses
test_a_malformed_but_parseable_inputs_document_is_could_not_observe
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
test_a_relied_upon_ruling_with_empty_applicability_refuses
test_work_identity_alone_does_not_establish_ruling_applicability
test_matching_candidate_axes_establish_ruling_applicability
test_unestablished_ruling_cannot_authorize_a_resolution
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
test_the_classification_digest_names_the_envelope_it_classified
test_an_unreadable_ancestry_is_could_not_observe
test_a_check_that_names_no_head_cannot_cover_a_required_platform
test_validate_refuses_to_guess_about_evidence
test_declining_the_evidence_recheck_cannot_reach_review_ready
test_validate_rechecks_evidence_bytes
test_a_crashed_compiler_cannot_reach_a_verdict
test_the_generated_contract_page_matches_the_catalog
test_the_mutation_table_matches_the_campaign_artifact
test_the_measurement_record_is_backed_by_the_campaign_artifact
test_the_verification_record_matches_the_executed_control_count
fm_test_contract "${BASH_SOURCE[0]}"
