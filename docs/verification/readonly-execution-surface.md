# Read-only execution surface

Active empirical facts for the slot-free read-only worker/checker path.
`bin/fm-readonly-lib.sh` owns the surface itself; this file records what has actually been observed about it, and what has not.

Recorded 2026-08-26 against `bin/fm-spawn.sh` at `1f2141ad`.

## The claim, split into the half this repo decides and the half the vendor decides

A read-only task is dispatched with no treehouse slot and no worktree, onto a sealed subject it must not mutate.
Three mechanisms carry that: the launch flags, a Bash `PreToolUse` guard, and the subject seal.
Two of them are this repo's own logic and are proven by `tests/fm-readonly-surface.test.sh`.
The third depends on what the installed `claude` does at runtime, and that half is **not yet observed**.

Keeping the halves apart is the point of this record.
An unproven half that reads as proven is exactly the failure mode the `wrong-subject` skill names, and a deny list credited with an enforcement nobody watched happen would be one.

## Observed good

**Flag acceptance, claude 2.1.246.**
`claude --help` lists `--permission-mode` with the choices `acceptEdits, auto, bypassPermissions, manual, dontAsk, plan`, and lists both `--allowedTools` and `--disallowedTools`.
So `dontAsk` is a real mode rather than a plausible name, and the deny list has a real flag to travel on.

**The composed launch is accepted by the real binary.**
A readonly dispatch was run end to end and the process was observed live as:

```
claude --permission-mode dontAsk --disallowedTools Edit,Write,MultiEdit,NotebookEdit <encoded brief>
```

It started rather than exiting on a usage error, which is stronger than reading the help text: the flag combination is accepted together, in that order, with that deny-list spelling.

**A readonly dispatch takes no pool slot.**
The same run recorded `state/<id>.meta` with `execution_surface=readonly`, `readonly_subject=`, `readonly_head=`, and no `worktree=` line at all, while the treehouse pool was never consulted.
`tests/fm-readonly-surface.test.sh` keeps that as a differential against an ordinary scout, so "the pool guard was not called" is only ever asserted next to a control run in which it was.

**Canonical teardown reclaims nothing and leaves nothing.**
Teardown of that task refused first for a missing report, then refused again for the unresolved-decision completion gate, then completed once both were satisfied - reporting `worktree ` empty, removing `/tmp/fm-<id>` including the read-only seal, closing the window, and preserving `data/<id>/report.md`.

**The seal prevents and detects independently.**
Writing to a sealed file fails at the OS with `Permission denied`.
A forced change, an added file, and a removed file are each reported distinctly and exit 2; an unreadable subject exits 3 and is never folded onto either.

## Could not observe

**Runtime tool enforcement.**
That `--permission-mode dontAsk` combined with `--disallowedTools` actually REFUSES a denied tool mid-turn has not been observed, because proving it requires a real model turn and the task that built this surface was constrained to spend nothing.
This is could-not-observe, not observed-good.
Until it is run, no one should describe the tool-gate half as verified.

`tests/fm-readonly-live-harness.test.sh` is the command that closes it:

```
FM_READONLY_LIVE_E2E=1 bash tests/fm-readonly-live-harness.test.sh
```

It runs a positive control first - the same prompt under `bypassPermissions` must actually write the file - so a model that simply declines cannot be mistaken for a deny list that worked.
Re-run it after any claude upgrade and record the version and result here.

## Observed bad, and still open

**A readonly claude launch stops at the folder-trust dialog.**
Observed live: the launched process sat at `Quick safety check: Is this a project you created or one you trust?` and never began a turn.

This is structural rather than incidental, and it is not what `harness-adapters` currently records for claude ("Trust dialog | None on a clean first launch in a fresh pooled worktree").
That entry stays true for an ordinary crewmate only because every other claude template carries `--dangerously-skip-permissions`, which suppresses the dialog as a side effect.
The readonly template deliberately does not carry it, so the dialog is exposed - and because the work directory is created fresh for every readonly task, it is never an already-trusted path, so this happens on EVERY dispatch rather than only the first.

`bin/fm-spawn.sh` prints an explicit notice naming the directory and the expected handling.
It does not answer the dialog: granting folder trust automatically is a decision this repo does not make on the operator's behalf (`docs/sessionstart-nudge.md` states the same principle for a different surface).

Two candidate repairs, neither verified, both needing a live run this task could not spend:

1. Place the pane's working directory inside an already-trusted root - the task's own `data/<id>/` - and pass the sealed subject with `--add-dir`.
   That keeps the write allowance unchanged, since `data/<id>/` is already writable for the report.
2. Add an explicit, operator-approved trust step to the dispatch.

Until one lands, a readonly dispatch needs the dialog answered before the worker begins.

## What the portable suite pins

`tests/fm-readonly-surface.test.sh`, 27 cases, run green at `1f2141ad`:
the three-valued `execution_surface` read, the derived enforceable-harness roster, the readonly launch template carrying no bypass, seal exactness against a dirty working copy, create-only sealing, git's own reason on a failed seal, prevention, three-way detection, could-not-observe, the write-intent allow/deny matrix including the sealed-subject carve-out and the fail-closed arm, the authority-widening denials with the forge and backlog read verbs still allowed, the seal being reclaimable by its owner so teardown can remove it, the transport's deny shaping and empty stdout, every dispatch refusal, the by-name unenforceable-harness refusal, and endpoint validation accepting a readonly subject without widening the ordinary contract.
