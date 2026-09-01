#!/usr/bin/env python3
"""Build single-defect variants of the recurrence and mutation proof owner and
run each control against each one, so every control is watched failing for the
defect it claims to catch.

WHY THIS IS TRACKED RATHER THAN SCRATCH
=======================================

docs/verification/review-mutation-proof.md records a red matrix. A matrix
nobody else can reproduce is a self-attested result: the reader has only the
record's own word that any of it happened. Tracking the defect catalogue makes
each entry REPLAYABLE - anyone can rebuild the exact defect build the record
names and re-run the exact control against it:

    tests/review-mutation-red-matrix.py replay D01 test_a_matching_success_line_cannot_establish_that_the_target_ran

and compare what they get with the row. That is the difference between a record
that describes bytes and a record that describes itself.

WHAT AN ENTRY BINDS
===================

Each matrix entry carries the defect build's own sha256. That digest is what
ties a row to a specific mutant rather than to a name: two people running
`replay` on the same tracked catalogue and the same measured head build a
byte-identical defect and can compare digests before comparing outcomes. A row
whose defect digest does not reproduce is describing a build that is not the one
in front of you, whatever its prose says.

WHAT REPLAY DOES AND DOES NOT ESTABLISH
=======================================

It establishes that the named defect, built from the tracked catalogue against
the current bytes, still makes the named control fail. It does not establish
that the historical run happened - nothing replayable can, because a replay is a
new execution. What it removes is the need to take the record's word for it: a
row that no longer reproduces is a row to distrust, which is the only property a
verification record can honestly offer.

The catalogue patches are exact-substring edits against the tracked scripts. A
patch whose anchor no longer matches is a hard error, never a skip: an anchor
that silently stopped matching would turn a defect build into an unmodified
build, and an unmodified build reddens nothing, so the control would look
witnessed while measuring a defect that was never injected.

Usage:
    tests/review-mutation-red-matrix.py matrix [--defects D01,D02] [--json <out>]
    tests/review-mutation-red-matrix.py replay <defect> <control>
    tests/review-mutation-red-matrix.py list
    tests/review-mutation-red-matrix.py --help
"""
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROOF_OWNER = os.path.join(ROOT, "bin", "fm-review-mutation.sh")
VERIFY = os.path.join(ROOT, "bin", "fm-verify.sh")
SUITE = os.path.join(ROOT, "tests", "fm-review-mutation.test.sh")
RECORD = os.path.join(ROOT, "docs", "verification", "review-mutation-proof.md")
MAX_WORKERS = 6


class AnchorMissing(SystemExit):
    pass


def sub(text, old, new):
    """Exact-substring patch. A missing anchor is fatal, never a silent no-op."""
    if old not in text:
        raise AnchorMissing(
            "defect anchor no longer matches the tracked bytes; the catalogue "
            "must be repaired rather than run:\n" + old[:300])
    return text.replace(old, new, 1)


# --- the defect catalogue ----------------------------------------------------
#
# Each entry returns the three artifacts a build may perturb: the proof owner,
# the verify wrapper, and the verification record. A defect touches one of them.

def d01(s, v, r):
    """The retired defect, restored: the verdict is read from an `ok - ` line in
    the probe's captured output instead of from the differential."""
    return sub(s, '  read_execution "$dir/exec/baseline"; b=$EXEC_RESULT',
               '  if grep -q \'^ok - \' "$dir/exec/baseline/review.raw" 2>/dev/null; then\n'
               '    DERIVED_RESULT=PASS; DERIVED_REASON=verified; DERIVED_BASIS=label_seen\n'
               '    return 0\n'
               '  fi\n'
               '  read_execution "$dir/exec/baseline"; b=$EXEC_RESULT'), v, r


def d02(s, v, r):
    """Control is established by the falsifying direction alone."""
    return sub(s, '''  if [ "$s" = FAIL ]; then
    FOLD_RESULT=NO_VERIFIER_RAN
    FOLD_REASON=no_verdict_reached
    FOLD_BASIS=control_not_attributable
    return 0
  fi''', "  :"), v, r


def d03(s, v, r):
    """The occurrence guard accepts more than one site and uses the first."""
    s = sub(s, """print(len(positions), positions[0] if positions else -1)
if len(positions) != 1:
    sys.exit(3)""",
            """print(len(positions), positions[0] if positions else -1)
if len(positions) < 1:
    sys.exit(3)""")
    return sub(s, '  [ "$occurrences" = 1 ] || cno "target occurrence count is not one: $occurrences"',
               "  :"), v, r


def d04(s, v, r):
    """The clone is made locally and its isolation assumed rather than measured."""
    s = sub(s, '''  git clone --quiet --no-local "$source" "$staging" 2>/dev/null \\
    || cno "disposable mutation clone failed"
  prove_clone_isolated "$staging" \\
    || cno "disposable mutation clone is not isolated from the source"''',
            '''  git clone --quiet "$source" "$staging" 2>/dev/null \\
    || cno "disposable mutation clone failed"''')
    return sub(s, '  prove_clone_isolated "$staging" || return 0', "  :"), v, r


def d05(s, v, r):
    """The apparatus perturbs the baseline tree and nothing requires it not to."""
    s = sub(s, """for path, replacement in ((base_out, target), (fal_out, falsify), (sat_out, satisfy)):
    with open(path, "wb") as handle:
        handle.write(data[:start] + replacement + data[end:])""",
            """for path, replacement in ((base_out, target), (fal_out, falsify), (sat_out, satisfy)):
    with open(path, "wb") as handle:
        extra = b"\\n" if path == base_out else b""
        handle.write(data[:start] + replacement + data[end:] + extra)""")
    s = sub(s, '''  [ "$baseline_tree" = "$candidate_tree" ] \\
    || cno "the identity substitution did not reproduce the candidate tree, so the apparatus is not neutral"''',
            "  :")
    return sub(s, '  [ "$bt" = "$ct" ] || return 0', "  :"), v, r


def d06(s, v, r):
    """Mutation facts are read out of the record instead of re-proven."""
    s = sub(s, '''  [ "$(git -C "$staging" rev-parse --verify --quiet "$bc^{tree}" 2>/dev/null)" = "$bt" ] || return 0''',
            "  :")
    return sub(s, '''  read_execution "$dir/exec/baseline"; b=$EXEC_RESULT
  read_execution "$dir/exec/falsified"; n=$EXEC_RESULT
  read_execution "$dir/exec/satisfied"; s=$EXEC_RESULT''',
               '''  b=$(jq -r '.dimensions.baseline_execution.value.result' "$record" 2>/dev/null)
  n=$(jq -r '.dimensions.falsified_execution.value.result' "$record" 2>/dev/null)
  s=$(jq -r '.dimensions.satisfied_execution.value.result' "$record" 2>/dev/null)'''), v, r


def d07(s, v, r):
    """An occupied output directory is cleared and reused."""
    return sub(s, '    [ -z "$(ls -A "$out" 2>/dev/null)" ] || cno "output directory is not empty, and a record is written once: $out"',
               '    rm -rf "${out:?}"/*'), v, r


def d08(s, v, r):
    """The primary-checkout refusal is dropped."""
    return sub(s, '''  [ "$git_dir" != "$common_dir" ] \\
    || cno "mutation proof refuses a primary checkout as its source: $source"''', "  :"), v, r


def d09(s, v, r):
    """The catalogue fold reports a gap ahead of a failure."""
    return sub(s, '''      FAIL) folded=FAIL; reason=verifier_reported_failure; break ;;
    esac
  done
  if [ "$folded" != FAIL ]; then''',
               '''      NO_VERIFIER_RAN) folded=NO_VERIFIER_RAN; reason=verification_incomplete; break ;;
    esac
  done
  if [ "$folded" != NO_VERIFIER_RAN ]; then'''), v, r


def d10(s, v, r):
    """An unobserved dimension no longer outranks the fold."""
    return sub(s, '''  if [ -n "$missing" ]; then
    DERIVED_REASON=verification_incomplete
    DERIVED_BASIS=dimensions_unobserved
    DERIVED_MISSING=$missing
    return 0
  fi''', "  :"), v, r


def d11(s, v, r):
    """A caller declaration is read and reaches the verdict."""
    return sub(s, '  read_execution "$dir/exec/baseline"; b=$EXEC_RESULT',
               '''  if jq -e '.declared.text | test("executed and passed")' "$record" >/dev/null 2>&1; then
    DERIVED_RESULT=PASS; DERIVED_REASON=verified; DERIVED_BASIS=declared_by_caller
    return 0
  fi
  read_execution "$dir/exec/baseline"; b=$EXEC_RESULT'''), v, r


def d12(s, v, r):
    """The source is mutated in place and restored in a finally - every
    after-the-fact check is satisfied, a reader during the run is not."""
    s = sub(s, '''  local -a results=() reasons=()
  local exec_dir''',
            '''  cp "$work/falsified.bytes" "$source/$path"
  local -a results=() reasons=()
  local exec_dir''')
    return sub(s, '''  local record=$out/record.json
  jq -n \\''',
               '''  git -C "$source" checkout -- "$path" 2>/dev/null
  local record=$out/record.json
  jq -n \\'''), v, r


def d13(s, v, r):
    """An empty catalogue is folded as clean."""
    return sub(s, '  [ "$count" -gt 0 ] || cno "catalogue declares no cases, so nothing was observed: $catalogue"',
               "  :"), v, r


def d14(s, v, r):
    """Duplicate case identities are accepted."""
    return sub(s, '  [ "$ids" = unique ] || cno "catalogue declares duplicate case identities, so its fold is ambiguous"',
               "  :"), v, r


def d15(s, v, r):
    """The probe argv is recorded as a space-joined rendering of itself."""
    return sub(s, """  argv_json=$(
    for a in "${argv[@]}"; do
      printf '%s' "$a" | base64 | tr -d '\\n'
      printf '\\n'
    done | jq -Rs -c 'rtrimstr("\\n") | split("\\n") | map(@base64d)'
  ) || cno "probe argv could not be recorded\"""",
               """  argv_json=$(printf '%s ' "${argv[@]}" | jq -Rs -c 'rtrimstr(" ") | split(" ")') \\
    || cno "probe argv could not be recorded\""""), v, r


def d16(s, v, r):
    """The regular-file guard on the target path is dropped."""
    return sub(s, '''  case "$target_mode" in
    100644|100755) ;;
    *) cno "target path is not a regular file in the candidate tree: $path mode $target_mode" ;;
  esac''', "  :"), v, r


def d17(s, v, r):
    """With no execution substrate the build reports PASS itself rather than
    refusing - the exact fallback the law forbids."""
    return sub(s, '  [ -x "$SCRIPT_DIR/fm-review-exec.sh" ] || cno "the execution substrate is unavailable: $SCRIPT_DIR/fm-review-exec.sh"',
               '''  if [ ! -x "$SCRIPT_DIR/fm-review-exec.sh" ]; then
    mkdir -p "$out" 2>/dev/null
    printf 'verify[1]{verifier,result,reason,evidence_ref}:\\n  %s,%s,%s,%s\\n' \\
      review-mutation PASS verified "$out/record.json"
    exit 0
  fi'''), v, r


def d18(s, v, r):
    """The wrapper narrows any transported result to PASS."""
    # Anchored on the review-mutation wrapper's own run_verifier line rather
    # than on the section boundary that follows it. The boundary anchor bound
    # to whichever adapter happened to sit last before dispatch, so adding the
    # review-envelope adapter silently retargeted this defect at a different
    # wrapper: still one match, still green, measuring the wrong subject.
    # sub() is fatal on a missing anchor but takes the first of several, so an
    # anchor must identify its subject, not merely occur once today.
    return s, sub(v, '''  run_verifier "$SCRIPT_DIR/fm-review-mutation.sh" result "$dir" || {
    set_result NO_VERIFIER_RAN no_evidence
    return 0
  }
  if ! fm_verify_parse "$VERIFIER_OUT"; then
    set_result NO_VERIFIER_RAN no_evidence
    return 0
  fi
  set_result "$FM_VERIFY_RESULT" "$FM_VERIFY_REASON"
}''',
                  '''  run_verifier "$SCRIPT_DIR/fm-review-mutation.sh" result "$dir" || {
    set_result NO_VERIFIER_RAN no_evidence
    return 0
  }
  if ! fm_verify_parse "$VERIFIER_OUT"; then
    set_result NO_VERIFIER_RAN no_evidence
    return 0
  fi
  set_result PASS verified
}'''), r


def d19(s, v, r):
    """The label defect in its other direction: a FAILURE literal in the probe's
    own output is read as a failure."""
    return sub(s, '  read_execution "$dir/exec/baseline"; b=$EXEC_RESULT',
               '''  if grep -q 'review-mutation,FAIL' "$dir/exec/baseline/review.raw" 2>/dev/null; then
    DERIVED_RESULT=FAIL; DERIVED_REASON=verifier_reported_failure; DERIVED_BASIS=label_seen
    return 0
  fi
  read_execution "$dir/exec/baseline"; b=$EXEC_RESULT'''), v, r


def d20(s, v, r):
    """The unmutated baseline is ignored once control is established."""
    return sub(s, '''  if [ "$b" = PASS ]; then
    FOLD_RESULT=PASS
    FOLD_REASON=verified
    FOLD_BASIS=target_executed_and_concluded_pass
  else
    FOLD_RESULT=FAIL
    FOLD_REASON=verifier_reported_failure
    FOLD_BASIS=target_executed_and_concluded_fail
  fi''',
               '''  FOLD_RESULT=PASS
  FOLD_REASON=verified
  FOLD_BASIS=target_executed_and_concluded_pass'''), v, r


def d21(s, v, r):
    """A target that is not present is spliced in at the start of the file
    instead of refused - discovery failing open."""
    s = sub(s, """print(len(positions), positions[0] if positions else -1)
if len(positions) != 1:
    sys.exit(3)

start = positions[0]
end = start + len(target)""",
            """print(len(positions), positions[0] if positions else -1)
if len(positions) > 1:
    sys.exit(3)

start = positions[0] if positions else 0
end = start + (len(target) if positions else 0)""")
    return sub(s, '  [ "$occurrences" = 1 ] || cno "target occurrence count is not one: $occurrences"',
               "  :"), v, r


def d22(s, v, r):
    """The identical-substitution refusals are dropped."""
    return sub(s, '''  cmp -s "$work/falsify.bytes" "$work/satisfy.bytes" \\
    && cno "the falsifying and satisfying substitutions are identical, so no direction is tested"
  cmp -s "$work/falsify.bytes" "$work/target.bytes" \\
    && cno "the falsifying substitution is the target itself, so nothing is falsified"
  cmp -s "$work/satisfy.bytes" "$work/target.bytes" \\
    && cno "the satisfying substitution is the target itself, so nothing is satisfied"''',
               "  :"), v, r


def d23(s, v, r):
    """The record is believed even when the clone it names is gone."""
    s, v, r = d06(s, v, r)
    return sub(s, '  prove_clone_isolated "$staging" || return 0', "  :"), v, r


def d24(s, v, r):
    """Every execution record is accepted for every variant, so an execution
    belonging to another mutation can manufacture control."""
    return sub(s, '''  jq -e --arg commit "$commit" --arg tree "$tree" --argjson argv "$argv_json" ' ''' .rstrip() + '\n',
               "  return 0\n  jq -e --arg commit \"$commit\" --arg tree \"$tree\" --argjson argv \"$argv_json\" '\n"), v, r


def d25(s, v, r):
    """The mutation bytes are not re-derived: any mismatch is swallowed, so a
    record can describe arbitrary commits as the three exact-byte mutations."""
    return sub(s, "except (AttributeError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError):\n    sys.exit(1)",
               "except (AttributeError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError):\n    sys.exit(0)"), v, r


def d26(s, v, r):
    """The record's documented control count disagrees with the suite."""
    return s, v, re.sub(r"^inventory_control_count: \d+$",
                        "inventory_control_count: 1", r, count=1, flags=re.M)


def d27(s, v, r):
    """A documented file digest disagrees with the bytes it names."""
    return s, v, re.sub(r"^(inventory_sha256: bin/fm-review-mutation\.sh )[0-9a-f]{64}$",
                        r"\g<1>" + "0" * 64, r, count=1, flags=re.M)


def d28(s, v, r):
    """The record carries no parseable inventory count at all."""
    return s, v, re.sub(r"^inventory_control_count: \d+$", "", r, count=1, flags=re.M)


def d29(s, v, r):
    """The record's declared target path is never bound to where the mutants
    actually differ, so a record can name one file while its commits changed
    another. The binding lives in two places - the name-only diff and the
    re-derivation's path lookup - so defeating it takes both, which is one
    defect and not two."""
    s = sub(s, '''  local changed
  for changed in "$fc" "$sc"; do
    [ "$(git -C "$staging" -c core.quotePath=false diff --name-only "$cc" "$changed" 2>/dev/null)" = "$path" ] \\
      || return 0
  done''', "  :")
    return sub(s, "except (AttributeError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError):\n    sys.exit(1)",
               "except (AttributeError, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError):\n    sys.exit(0)"), v, r


def d30(s, v, r):
    """The output directory is claimed before the source is judged, so a caller
    naming a primary checkout with an output path inside it gets a directory
    written into the very checkout the next line refuses. The refusal text stays
    correct; the refusal leaves a trace in what it refused."""
    return sub(s, "  [ -d \"$source\" ] || cno \"source is not a directory: $source\"",
               "  mkdir -p \"$out\" 2>/dev/null\n"
               "  [ -d \"$source\" ] || cno \"source is not a directory: $source\""), v, r


def d31(s, v, r):
    """The closed `..` rejection is replaced by the old nearest-ancestor
    resolution, so traversal in a nonexistent suffix creates inside the source
    before the post-creation containment check refuses it."""
    return sub(s, '''  case "$out" in
    */../*|*/..|../*|..) cno "output path must not contain a .. component: $out" ;;
  esac''', "  :"), v, r


def d32(s, v, r):
    """The shared pre-creation output guard is omitted from catalogue only, so
    output inside a linked-worktree source is created before the backstop
    refuses it."""
    return sub(s, '''  [ "$cat_git_dir" != "$cat_common_dir" ] \\
    || cno "mutation proof refuses a primary checkout as its source: $source"

  guard_output_outside_source "$source_root" "$out"''', '''  [ "$cat_git_dir" != "$cat_common_dir" ] \\
    || cno "mutation proof refuses a primary checkout as its source: $source"'''), v, r


def d33(s, v, r):
    """The shared output guard refuses every path, so legitimate evidence
    output outside the source can never proceed."""
    return sub(s, '''guard_output_outside_source() {  # <resolved-source> <raw-output>
  local source=$1 out=$2 out_parent out_leaf out_resolved''', '''guard_output_outside_source() {  # <resolved-source> <raw-output>
  local source=$1 out=$2 out_parent out_leaf out_resolved
  cno "output path refused: $out"'''), v, r


def d34(s, v, r):
    """The record's measured digests no longer describe the current subject, so
    the matrix reports a measurement taken against bytes that have since
    changed."""
    return s, v, re.sub(r"^(measured_sha256: bin/fm-review-mutation\.sh )[0-9a-f]{64}$",
                        r"\g<1>" + "0" * 64, r, count=1, flags=re.M)


DEFECTS = [
    ("D01", d01), ("D02", d02), ("D03", d03), ("D04", d04), ("D05", d05),
    ("D06", d06), ("D07", d07), ("D08", d08), ("D09", d09), ("D10", d10),
    ("D11", d11), ("D12", d12), ("D13", d13), ("D14", d14), ("D15", d15),
    ("D16", d16), ("D17", d17), ("D18", d18), ("D19", d19), ("D20", d20),
    ("D21", d21), ("D22", d22), ("D23", d23), ("D24", d24), ("D25", d25),
    ("D26", d26), ("D27", d27), ("D28", d28), ("D29", d29), ("D30", d30),
    ("D31", d31), ("D32", d32), ("D33", d33), ("D34", d34),
]
BY_NAME = dict(DEFECTS)


def digest(data):
    return hashlib.sha256(data.encode() if isinstance(data, str) else data).hexdigest()


def controls():
    text = open(SUITE).read()
    block = re.search(r"FM_CONTROLS=\(\n(.*?)\n\)", text, re.S).group(1)
    return [line.strip() for line in block.splitlines() if line.strip()]


def build(name, workdir):
    """Materialize one defect build. Returns (env-overrides, defect digest)."""
    patch = BY_NAME[name]
    source, verify, record = open(PROOF_OWNER).read(), open(VERIFY).read(), open(RECORD).read()
    new_source, new_verify, new_record = patch(source, verify, record)
    if (new_source, new_verify, new_record) == (source, verify, record):
        raise SystemExit("defect %s produced no change; it would measure nothing" % name)

    os.makedirs(workdir, exist_ok=True)
    for helper in ("fm-review-exec.sh", "fm-verify-lib.sh"):
        shutil.copy2(os.path.join(ROOT, "bin", helper), workdir)
    bin_path = os.path.join(workdir, "fm-review-mutation.sh")
    verify_path = os.path.join(workdir, "fm-verify.sh")
    record_path = os.path.join(workdir, "record.md")
    for path, text in ((bin_path, new_source), (verify_path, new_verify), (record_path, new_record)):
        open(path, "w").write(text)
    os.chmod(bin_path, 0o755)
    os.chmod(verify_path, 0o755)
    for path in (bin_path, verify_path):
        if subprocess.run(["bash", "-n", path], capture_output=True).returncode != 0:
            raise SystemExit("defect %s does not parse: %s" % (name, path))
    env = {
        "FM_REVIEW_MUTATION_BIN": bin_path,
        "FM_VERIFY_BIN": verify_path,
        "FM_REVIEW_MUTATION_RECORD": record_path,
    }
    return env, digest(new_source + new_verify + new_record)


def run_control(env_overrides, control):
    env = dict(os.environ)
    env.update(env_overrides)
    env["FM_REVIEW_MUTATION_ONLY"] = control
    proc = subprocess.run(["bash", SUITE], capture_output=True, text=True,
                          env=env, timeout=1800)
    lines = (proc.stdout + proc.stderr).splitlines()
    red = next((l[len("not ok - "):] for l in lines if l.startswith("not ok - ")), "")
    return proc.returncode, red


def cmd_matrix(argv):
    selected = [n for n, _ in DEFECTS]
    out_json = None
    while argv:
        if argv[0] == "--defects":
            selected = argv[1].split(",")
            argv = argv[2:]
        elif argv[0] == "--json":
            out_json = argv[1]
            argv = argv[2:]
        else:
            raise SystemExit("unknown argument: " + argv[0])

    names = controls()
    print("controls declared: %d" % len(names))
    witnessed = {c: [] for c in names}
    matrix, digests = {}, {}
    tmp = tempfile.mkdtemp(prefix="fm-red-matrix-")
    try:
        for name in selected:
            env, defect_digest = build(name, os.path.join(tmp, name))
            digests[name] = defect_digest
            rows = {}
            with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
                futures = {pool.submit(run_control, env, c): c for c in names}
                for future in concurrent.futures.as_completed(futures):
                    control = futures[future]
                    code, red = future.result()
                    rows[control] = {"code": code, "red": red}
                    if code != 0:
                        witnessed[control].append(name)
            matrix[name] = rows
            reddened = [c for c in names if rows[c]["code"] != 0]
            print("=" * 78)
            print("%s (%s): reddened %d/%d" % (name, defect_digest[:12], len(reddened), len(names)))
            for c in names:
                if rows[c]["code"] != 0:
                    print("   %-62s %s" % (c, rows[c]["red"]))
            if not reddened:
                print("   *** NO CONTROL WENT RED - the defect is unwitnessed ***")
            sys.stdout.flush()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    orphans = [c for c in names if not witnessed[c]]
    print("=" * 78)
    print("CONTROLS WITH NO RED WITNESS: %d" % len(orphans))
    for c in orphans:
        print("   " + c)
    if out_json:
        open(out_json, "w").write(json.dumps(
            {"witnessed": witnessed, "matrix": matrix, "defect_digests": digests,
             "orphans": orphans}, indent=2))
    return 1 if orphans else 0


def cmd_replay(argv):
    if len(argv) != 2:
        raise SystemExit("replay needs a defect id and a control name")
    name, control = argv
    if name not in BY_NAME:
        raise SystemExit("unknown defect: " + name)
    if control not in controls():
        raise SystemExit("unknown control: " + control)
    tmp = tempfile.mkdtemp(prefix="fm-red-replay-")
    try:
        env, defect_digest = build(name, os.path.join(tmp, name))
        code, red = run_control(env, control)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("defect:        %s" % name)
    print("defect_sha256: %s" % defect_digest)
    print("control:       %s" % control)
    print("exit:          %d (%s)" % (code, "RED" if code else "GREEN"))
    print("observed_red:  %s" % (red or "(none - the control did NOT fail)"))
    return 0 if code else 1


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "matrix":
        return cmd_matrix(argv[1:])
    if argv[0] == "replay":
        return cmd_replay(argv[1:])
    if argv[0] == "list":
        for name, patch in DEFECTS:
            summary = (patch.__doc__ or "").strip().split("\n")[0]
            print("%s  %s" % (name, summary))
        return 0
    raise SystemExit("unknown subcommand: " + argv[0])


if __name__ == "__main__":
    sys.exit(main())
