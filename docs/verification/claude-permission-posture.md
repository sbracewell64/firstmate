# Claude worker permission posture

Active empirical record for the guarantee that a firstmate-launched claude agent cannot reach an interactive permission gate.
`bin/fm-launch-lib.sh` owns the posture itself; this file records what was measured, on which version, and the command that re-measures it.

Verified 2026-08-26 against the installed Claude Code **2.1.246** (`/home/shane/.local/share/claude/versions/2.1.246`).

## What the guarantee has to survive

A bypass flag is not sufficient, which is the reason the shipped posture is not one.
Claude Code carries permission circuit breakers whose ask a bypass does not suppress and which the CLI itself describes as something that "cannot be auto-allowed by permission rules".
The registry is a literal in the installed bundle:

```
dangerousRemoval:      { bypassImmune: true,  classifierRouted: true }
backgroundOperator:    { bypassImmune: false, classifierRouted: true }
suspiciousWindowsPath: { bypassImmune: false, classifierRouted: true }
isolatePeerMachines:   { bypassImmune: true,  classifierRouted: false }
```

The accepted `--permission-mode` values in the same bundle are `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, `plan`.
In headless mode an unanswerable ask surfaces as the bundle's own `"tool requires user interaction; no prompt available in headless mode"`; in an interactive pane the same ask is the prompt an unattended worker stops on.

## The measured pair

Both runs used the same command, the same allow rules, and the same disposable tree, and differed only in the launch posture.
`rm -rf x/*/*` is a live `dangerousRemoval` trigger on this version (the "glob pattern traverses directories that cannot be statically enumerated" arm).

```
# RED CONTROL - the bypass posture. The ask still reaches the user.
cd "$PROBE" && claude -p '... run: rm -rf x/*/* ...' --output-format json \
  --dangerously-skip-permissions
```

```
Dangerous rm operation detected: '<probe>/x/*/*'

This command's glob pattern traverses directories that cannot be statically enumerated.
This requires explicit approval and cannot be auto-allowed by permission rules.
```

```
# THE SHIPPED POSTURE. The same ask becomes a typed denial, and nothing is asked.
cd "$PROBE" && claude -p '... run: rm -rf x/*/* ...' --output-format json \
  --permission-mode dontAsk
```

```
Permission to use Bash has been denied because Claude Code is running in don't ask mode.
```

In both runs the target files were still present afterwards, and in both runs `permission_denials` in the JSON result named the same one `Bash` call.
The difference is only in what the worker is asked to do about it: the first needs a human, the second does not.

## Both halves are load-bearing

The mode alone is not the posture.
With `--permission-mode dontAsk` and no allow rules, an ordinary `printf 'ok\n' > written.txt` was denied with the same "don't ask mode" message, while `ls` was allowed.
A worker launched that way is not unattended, it is inert, which is why `launch_claude_permission_flags` always emits the rules alongside the mode.

The rules alone are not the posture either.
`defaultMode: "dontAsk"` inside `.claude/settings.local.json` was measured to be honored on its own, with no `--permission-mode` flag present, so the settings carrier is real rather than decorative.
Both spellings of an allow rule were accepted: bare `Bash` and parenthesised `Bash(*)`.
The bare form is what ships, because it is the narrower claim.

The two carriers take different SHAPES, and confusing them fails quietly in the direction that looks safe.
`--settings` takes a whole settings document, `{"permissions":{"allow":[...],"defaultMode":"dontAsk"}}`, while the settings file holds only the inner object under its own `permissions` key.
Handing `--settings` the bare inner object was measured to leave the session with no allow rules it recognises: the trigger above was still refused, and an ordinary shell write was refused with it.
That reads exactly like a working no-prompt posture until someone checks that the worker can still do its job, which is why the live guard checks ordinary work as a case of its own.
`launch_claude_settings_json` and `launch_claude_permissions_json` are the two shapes, and each carrier reads the one it needs.

## Coexistence with the busy-state hooks

`permissions`, `hooks`, and `statusLine` were measured to coexist in one generated `.claude/settings.local.json`: under the shipped posture a `Stop` hook still fired and created its sentinel file.
That matters because the generated file is shared, and a worktree whose hooks were displaced would report its worker as permanently busy.

## What could NOT be observed

The trigger recorded against 2.1.245 - `cd <dir> && rm -rf x/*`, a relative glob after a directory change - **does not reproduce on 2.1.246**.
It was run three ways (bypass with no rules, bypass with rules, and the shipped posture) and was allowed every time, so that pair established nothing and is not evidence for anything here.
The `dangerousRemoval` predicate in 2.1.246 resolves an absolute `cd` target statically, which is the likely cause; the arm still exists in the source, so this is a narrowed trigger rather than a removed breaker.
Nothing in this record rests on that shape.
Do not build a check on it.

## Refreshing this record

The portable half runs with no harness installed and is enforced in CI:

```
bin/fm-test-run.sh tests/fm-claude-no-prompt-posture.test.sh
```

That suite pins the composed launch command, the generated settings, and the preflight refusals, but it cannot see the harness.
The vendor half above is what goes stale on a Claude Code upgrade, and it has its own guard, credentialed and opt-in:

```
FM_CLAUDE_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-claude-permission-posture-live-e2e.test.sh
```

It runs the red control, the shipped posture, and the ordinary-work case against the real installed harness, and it fails naming the harness and version.
Run it after every Claude Code upgrade and record the dated result here.
Last green: 2026-08-26, Claude Code 2.1.246, all three cases.

A control that no longer goes red means the trigger moved, not that the posture is safe, and the guard fails rather than passing when that happens.
Find a live trigger from the `dangerousRemoval` predicate in the installed bundle before recording another result.
