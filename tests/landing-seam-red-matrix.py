#!/usr/bin/env python3
"""Build single-defect variants of the landing seam and its two real merge gates,
and run the seam suite against each one, so every applicability control is
watched failing for the defect it claims to catch.

WHY THIS IS TRACKED RATHER THAN SCRATCH
=======================================

docs/verification/inbound-ruling-authorization.md records a red calibration for
this seam. A calibration nobody else can reproduce is a self-attested result:
the reader has only the record's own word that any of it happened. Tracking the
defect catalogue makes each row REPLAYABLE - anyone can rebuild the exact defect
the record names and re-run the suite against it:

    tests/landing-seam-red-matrix.py replay D01 test_pr_merge_refuses_an_in_domain_candidate_with_no_correlation

and compare what they get with the row.

WHAT THIS MEASURES, AND WHAT IT CANNOT
======================================

Each build stages `bin/` and `tests/` into a temporary root, applies exactly one
exact-substring patch, and runs the STAGED `tests/fm-landing-seam.test.sh`. That
suite drives the real `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` end to
end, so a red here is evidence about the production mutation path rather than
about the seam library in isolation - which is the entire point of the control
this catalogue calibrates.

It does not establish that the historical run happened; nothing replayable can,
because a replay is a new execution. What it removes is the need to take the
record's word for it.

A patch whose anchor no longer matches is a hard error, never a skip. An anchor
that silently stopped matching would produce an UNMODIFIED build, and an
unmodified build reddens nothing, so the control would look witnessed while
measuring a defect that was never injected.

Usage:
    tests/landing-seam-red-matrix.py matrix [--defects D01,D02] [--json <out>]
    tests/landing-seam-red-matrix.py replay <defect> [<control>]
    tests/landing-seam-red-matrix.py list
    tests/landing-seam-red-matrix.py --help
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
SEAM = os.path.join("bin", "fm-landing-seam-lib.sh")
PR_MERGE = os.path.join("bin", "fm-pr-merge.sh")
MERGE_LOCAL = os.path.join("bin", "fm-merge-local.sh")
AUTH = os.path.join("bin", "fm-landing-authorization.sh")
AUTH_LIB = os.path.join("bin", "fm-landing-authorization-lib.sh")
SUITE = os.path.join("tests", "fm-landing-seam.test.sh")
MAX_WORKERS = 4


class AnchorMissing(SystemExit):
    pass


def sub(text, old, new):
    """Exact-substring patch. A missing anchor is fatal, never a silent no-op."""
    if old not in text:
        raise AnchorMissing(
            "defect anchor no longer matches the tracked bytes; the catalogue "
            "must be repaired rather than run:\n" + old[:400])
    return text.replace(old, new, 1)


# --- the defect catalogue ----------------------------------------------------
#
# Each entry takes the staged tree's path and edits exactly one file in it.

def d00(_stage):
    """none - the staging control, which must be GREEN."""


def d01(stage):
    """LA-1's successor as found: an absent correlation is read as not-applicable
    instead of consulting the declared governed landing domain."""
    patch(stage, SEAM,
          "  fm_landing_seam_domain_read \"$config\"",
          "  fm_landing_seam_set not-applicable \"$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE\" \\\n"
          "    \"no live Browser Sol review request governs $item\"\n"
          "  return $?\n"
          "  fm_landing_seam_domain_read \"$config\"")


def d02(stage):
    """An undeclared landing domain is read as an empty one."""
    patch(stage, SEAM,
          "    FM_LANDING_SEAM_DOMAIN_STATE=undeclared",
          "    FM_LANDING_SEAM_DOMAIN_STATE=empty")


def d03(stage):
    """A malformed landing domain declaration is read as an empty one."""
    patch(stage, SEAM,
          "  FM_LANDING_SEAM_DOMAIN_STATE=unreadable\n  FM_LANDING_SEAM_DOMAIN_REPOS=",
          "  FM_LANDING_SEAM_DOMAIN_STATE=empty\n  FM_LANDING_SEAM_DOMAIN_REPOS=")


def d04(stage):
    """The DECLARATION side of the comparison becomes case-sensitive, so a domain
    entry written in another case stops matching the repository it names."""
    patch(stage, SEAM,
          "        else ($d.repos[] | ascii_downcase)",
          "        else ($d.repos[])")


def d12(stage):
    """The CANDIDATE side of the comparison becomes case-sensitive, so the domain
    is shed by how somebody typed a pull request url."""
    patch(stage, SEAM,
          "  repo=$(printf '%s' \"${1:-}\" | tr '[:upper:]' '[:lower:]')",
          "  repo=${1:-}")


def d05(stage):
    """A candidate whose repository could not be established is read as being
    outside the domain rather than as could-not-observe."""
    patch(stage, SEAM,
          "    fm_landing_seam_set unobserved \"$FM_LANDING_SEAM_TOKEN_CANDIDATE_REPO_UNOBSERVED\"",
          "    fm_landing_seam_set not-applicable \"$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE\"")


def d06(stage):
    """An explicitly empty landing domain refuses instead of landing, which is the
    non-vacuity direction: it proves the empty-domain landings are real."""
    patch(stage, SEAM,
          "    empty)\n      fm_landing_seam_set not-applicable",
          "    empty)\n      fm_landing_seam_set unobserved")


def d07(stage):
    """The pull-request gate stops telling the seam which repository it writes."""
    patch(stage, PR_MERGE,
          "\"$PR_OWNER/$PR_REPO\"; then",
          "-; then")


def d08(stage):
    """The local gate stops telling the seam which repository it writes."""
    patch(stage, MERGE_LOCAL,
          "\"$LANDING_HEAD\" - \"$LANDING_REPO\"",
          "\"$LANDING_HEAD\" - -")


def d09(stage):
    """The pull-request merge site ignores the seam's answer and always merges."""
    patch(stage, PR_MERGE,
          "case \"$LANDING_AUTHORIZATION\" in\n  not-applicable)",
          "case always-merge in\n  always-merge)")


def d10(stage):
    """The local merge site lands outside the spend."""
    patch(stage, MERGE_LOCAL,
          "case \"$FM_LANDING_SEAM_VERDICT\" in\n  not-applicable)",
          "case always-merge in\n  always-merge)")


def d11(stage):
    """The spend's exit status is read without the act receipt, so a spent
    authority reports success while merging nothing."""
    patch(stage, SEAM,
          "  if [ \"$rc\" -eq 0 ] && [ -s \"$receipt\" ]; then\n    return 0\n  fi",
          "  if [ \"$rc\" -eq 0 ]; then\n    return 0\n  fi")




# The pre-existing controls, whose defects belong in the same catalogue: a
# tracked matrix that witnessed only the newest increment would report the older
# half as unwitnessed forever, which is indistinguishable from those controls
# having no red at all.

def d13(stage):
    """A home with no control venue is refused instead of landing, which is the
    non-vacuity direction for the shipped default."""
    patch(stage, SEAM,
          "  if [ \"$venue\" -eq 0 ]; then\n    fm_landing_seam_set not-applicable",
          "  if [ \"$venue\" -eq 0 ]; then\n    fm_landing_seam_set unobserved")


def d14(stage):
    """An emitted-but-unruled request stops counting as live, so a review that was
    asked for and never answered no longer governs."""
    patch(stage, SEAM, "FM_LANDING_SEAM_LIVE_STATES='emitting\nemitted\n",
          "FM_LANDING_SEAM_LIVE_STATES='emitting\n")


def d15(stage):
    """A head no live request approved falls through as ungoverned instead of
    refusing, which makes moving the head the cheapest way to shed a ruling."""
    patch(stage, SEAM,
          "    if [ \"$granting\" -eq 0 ]; then\n      fm_landing_seam_set refused \"$FM_LANDING_SEAM_TOKEN_HEAD_UNAPPROVED\"",
          "    if [ \"$granting\" -eq 0 ]; then\n      fm_landing_seam_set not-applicable \"$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE\"")


def d16(stage):
    """Two live requests claiming one head resolve to the last one seen instead of
    refusing, so the authority a landing consumes is picked on no evidence."""
    patch(stage, SEAM, "    if [ \"$granting\" -gt 1 ]; then", "    if false; then")


def d17(stage):
    """A declining or unclassifiable ruling is treated as authorizing."""
    patch(stage, AUTH_LIB,
          "  [ -n \"$lower\" ] || { printf 'unrecognized\\n'; return 0; }",
          "  [ -n \"$lower\" ] || { printf 'unrecognized\\n'; return 0; }\n"
          "  printf 'authorizing\\n'\n  return 0")


def d18(stage):
    """An unreadable correlation record is skipped instead of refusing, so the one
    record that might have governed reads as an absence of rulings."""
    patch(stage, SEAM,
          "    if ! printf '%s' \"$raw\" | jq -e . >/dev/null 2>&1; then\n      fm_landing_seam_set unobserved",
          "    if ! printf '%s' \"$raw\" | jq -e . >/dev/null 2>&1; then\n      continue\n      fm_landing_seam_set unobserved")


def d19(stage):
    """Live governance with no configured control venue reads as ungoverned rather
    than as the configuration contradiction it is."""
    patch(stage, SEAM,
          "    if [ \"$venue\" -eq 0 ]; then\n      fm_landing_seam_set unobserved \"$FM_LANDING_SEAM_TOKEN_VENUE_UNCONFIGURED\"",
          "    if [ \"$venue\" -eq 0 ]; then\n      fm_landing_seam_set not-applicable \"$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE\"")


def d20(stage):
    """The pull-request gate stops enforcing its own check rollup, so a valid
    landing authority is all that stands between a red head and the forge. The
    seam must COMPOSE with the pre-existing guards, never replace them."""
    patch(stage, PR_MERGE,
          "  fm_verify_rollup_classify \"$output\" && rc=0 || rc=$?\n  head=$FM_VERIFY_ROLLUP_HEAD",
          "  fm_verify_rollup_classify \"$output\" && rc=0 || rc=$?\n  head=$FM_VERIFY_ROLLUP_HEAD\n"
          "  VERIFIED_HEAD=$head\n  return 0")


def d21(stage):
    """The forge's re-observed head is accepted whenever it differs from the
    approved one, so a pull request that moved after approval still lands."""
    patch(stage, AUTH,
          "  if [ \"$observed\" != \"$grant_head\" ]; then",
          "  if false; then")


DEFECTS = [("D00", d00), ("D01", d01), ("D02", d02), ("D03", d03), ("D04", d04),
           ("D05", d05), ("D06", d06), ("D07", d07), ("D08", d08), ("D09", d09),
           ("D10", d10), ("D11", d11), ("D12", d12), ("D13", d13), ("D14", d14),
           ("D15", d15), ("D16", d16), ("D17", d17), ("D18", d18),
           ("D19", d19), ("D20", d20), ("D21", d21)]
BY_NAME = dict(DEFECTS)


def patch(stage, relpath, old, new):
    path = os.path.join(stage, relpath)
    text = open(path).read()
    open(path, "w").write(sub(text, old, new))


def digest_tree(stage):
    """One digest over every staged file this catalogue may perturb, so two runs
    of the same defect against the same head can be compared before their
    outcomes are."""
    h = hashlib.sha256()
    for rel in (SEAM, PR_MERGE, MERGE_LOCAL, AUTH, AUTH_LIB, SUITE):
        h.update(rel.encode())
        h.update(open(os.path.join(stage, rel), "rb").read())
    return h.hexdigest()


def build(name, workdir):
    """Stage the tree and inject one defect. Returns (stage-path, digest)."""
    stage = os.path.join(workdir, "stage")
    os.makedirs(stage)
    for sub_dir in ("bin", "tests"):
        shutil.copytree(os.path.join(ROOT, sub_dir), os.path.join(stage, sub_dir))
    before = digest_tree(stage)
    BY_NAME[name](stage)
    after = digest_tree(stage)
    if name != "D00" and before == after:
        raise SystemExit("defect %s produced no change; it would measure nothing" % name)
    if name == "D00" and before != after:
        raise SystemExit("the staging control changed the tree; it would measure a defect")
    for rel in (SEAM, PR_MERGE, MERGE_LOCAL, AUTH, AUTH_LIB):
        if subprocess.run(["bash", "-n", os.path.join(stage, rel)],
                          capture_output=True).returncode != 0:
            raise SystemExit("defect %s does not parse: %s" % (name, rel))
    return stage, after


def controls():
    """The suite's own declared control set, read from the suite rather than
    restated here, so a control added there is measured here by construction."""
    text = open(os.path.join(ROOT, SUITE)).read()
    block = re.search(r"FM_CONTROLS=\(\n(.*?)\n\)", text, re.S).group(1)
    return [line.strip() for line in block.splitlines() if line.strip()]


def run_control(stage, control):
    env = dict(os.environ)
    env["FM_LANDING_SEAM_ONLY"] = control
    proc = subprocess.run(["bash", os.path.join(stage, SUITE)],
                          capture_output=True, text=True, env=env, timeout=1800)
    lines = (proc.stdout + proc.stderr).splitlines()
    red = next((line[len("not ok - "):] for line in lines if line.startswith("not ok - ")), "")
    return proc.returncode, red


def measure(name, names):
    """Run EVERY declared control against one defect build, so the row names all
    the controls that caught it rather than whichever one ran first."""
    tmp = tempfile.mkdtemp(prefix="fm-landing-red-")
    try:
        stage, sha = build(name, tmp)
        rows = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
            futures = {pool.submit(run_control, stage, c): c for c in names}
            for future in concurrent.futures.as_completed(futures):
                code, red = future.result()
                rows[futures[future]] = {"exit": code, "red": red}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    reddened = [c for c in names if rows[c]["exit"] != 0]
    return {"defect": name, "sha256": sha, "reddened": reddened,
            "green": len(names) - len(reddened), "controls": rows,
            "summary": (BY_NAME[name].__doc__ or "").strip().replace("\n", " ")}


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
    rows = {}
    witnessed = {c: [] for c in names}
    for name in selected:
        row = measure(name, names)
        rows[name] = row
        print("=" * 78)
        print("%s (%s): reddened %d/%d" % (name, row["sha256"][:12],
                                           len(row["reddened"]), len(names)))
        print("   %s" % row["summary"])
        for control in row["reddened"]:
            witnessed[control].append(name)
            print("   %-58s %s" % (control, row["controls"][control]["red"][:96]))
        sys.stdout.flush()

    unwitnessed = []
    if rows.get("D00") and rows["D00"]["reddened"]:
        unwitnessed.append("D00 - the staging control reddened %d control(s), so every row "
                           "here is evidence about the staging" % len(rows["D00"]["reddened"]))
    for name in selected:
        if name != "D00" and not rows[name]["reddened"]:
            unwitnessed.append("%s - no control went red, so the defect is unwitnessed" % name)
    orphans = [c for c in names if not witnessed[c]]

    print("=" * 78)
    if unwitnessed:
        print("UNWITNESSED DEFECTS: %d" % len(unwitnessed))
        for line in unwitnessed:
            print("   " + line)
    else:
        print("every defect was witnessed by a control, and the staging control is green")
    print("CONTROLS WITH NO RED WITNESS: %d" % len(orphans))
    for control in orphans:
        print("   " + control)
    if out_json:
        open(out_json, "w").write(json.dumps(
            {"matrix": rows, "witnessed": witnessed, "orphans": orphans}, indent=2, sort_keys=True))
    return 1 if unwitnessed else 0


def cmd_replay(argv):
    if len(argv) not in (1, 2):
        raise SystemExit("replay needs one defect id and an optional control name")
    name = argv[0]
    if name not in BY_NAME:
        raise SystemExit("unknown defect: " + name)
    names = controls()
    if len(argv) == 2:
        if argv[1] not in names:
            raise SystemExit("unknown control: " + argv[1])
        names = [argv[1]]
    row = measure(name, names)
    print("defect:        %s" % name)
    print("summary:       %s" % row["summary"])
    print("staged_sha256: %s" % row["sha256"])
    print("controls_run:  %d" % len(names))
    print("reddened:      %d" % len(row["reddened"]))
    for control in row["reddened"]:
        print("   not ok - %s: %s" % (control, row["controls"][control]["red"]))
    if name == "D00":
        return 0 if not row["reddened"] else 1
    return 0 if row["reddened"] else 1


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
        for name, fn in DEFECTS:
            print("%s  %s" % (name, (fn.__doc__ or "").strip().split("\n")[0]))
        return 0
    raise SystemExit("unknown subcommand: " + argv[0])


if __name__ == "__main__":
    sys.exit(main())
