# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `FM_HOME` contains private operational directories.
`data/` holds durable private fleet records such as the project and secondmate registries, captain preferences, optional shared captain preferences, learnings, backlog, briefs, scout reports, and the wake-outcome ledger.
`state/` holds volatile runtime records such as task metadata, append-only status events, endpoint signals, watcher and wake-queue coordination, away-mode state, generated X-mode artifacts, private secondmate config-reread generations with their retry and quarantine state, and parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).
`config/` holds local gitignored operating choices, and `projects/` holds the local project clones that Firstmate reads but changes only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.

`bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR and X helpers own the fields they append, `bin/fm-classify-lib.sh` owns status-event vocabulary, and `bin/fm-crew-state.sh` owns current-state reconciliation.
Wake, watcher, away-mode, and X-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`docs/sessionstart-nudge.md` owns the native session-open adapter mechanics that nudge the digest command.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Ordinary dead-direct-report recovery is owned by `stuck-crewmate-recovery`, while persistent-secondmate recovery is owned by `secondmate-provisioning`.

## Pi Calm preference (config/calm)

The Pi Calm extension stores the captain's home-local presentation choice in gitignored `config/calm` under the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `FM_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
The only values it writes are `on` and `off`, each followed by one newline; an absent, unreadable, or unrecognized value defaults to off.
The `/calm` command replaces the file atomically before changing live presentation, so a failed write leaves the current choice unchanged rather than claiming persistence.
The extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.
This preference is local to each Firstmate home and is not part of secondmate inherited configuration.

## Fleet launcher menu (config/launch-presets.json / state/.launch-last)

`bin/fm-launch.sh` reads its menu from gitignored `config/launch-presets.json` under the effective Firstmate home, and falls back to a built-in five-entry menu when that file is absent, so a fresh home needs no configuration.
Each entry is an object with `id`, `label`, and `harness`, plus optional `model` and `effort` that both default to `default`; an entry never carries a launch command, because `bin/fm-launch-lib.sh` remains the single owner of every verified launch command.
A present but malformed file refuses at the door rather than silently falling back to the built-in menu, and an entry naming an adapter with no verified primary shape renders unavailable rather than launching.
The launcher records the last successfully launched entry id in `state/.launch-last`, written atomically so an interrupted launcher cannot corrupt the default.
Neither file is part of secondmate inherited configuration: a secondmate home is provisioned and launched by the primary through `bin/fm-spawn.sh`, never through this front door, so there is no consumer for an inherited menu there.
[docs/launcher.md](launcher.md) is the operator-facing owner of launcher behavior and setup.

## Unattended session execution (config/unattended-session / state/.session-origin)

Firstmate can start its own session for a trigger that was queued while nobody was home, under the captain's 2026-08-03 ruling recorded in `data/loop-lc-autonomy-substrate/captain-ruling-unattended-session-2026-08-03.md`.
[`bin/fm-unattended-session.sh`](../bin/fm-unattended-session.sh) is the whole of that path, and its header owns the commands, the refusal tokens, and the record formats.
It adds no watcher, no scheduler, and no queue: the durable wake queue is the trigger inbox, and any producer can append to it with no session live.
That ruling grants execution only, and widens no approval authority whatsoever; an unattended session inherits exactly what a captain-started session has, and parks anything it cannot approve.

Arm it with any OS timer - `cron`, a systemd user timer, Task Scheduler through the WSL bridge - running `bin/fm-unattended-session.sh start` with `FM_HOME` set to the home it should wake.
Each run refuses unless the durable queue already holds a record, so a timer over an idle home starts nothing and costs one file read.
It also refuses when a live session holds the per-home session lock, when a healthy supervision cycle is already running, and when a previous start is still in flight, so a timer can never produce a second session or a second supervision cycle beside a live one.
Away mode is gated on its supervisor's liveness rather than on the presence of the durable `state/.afk` flag, under the captain's 2026-08-10 ruling: the start reads the away daemon's own single-instance lock and answers alive, dead, or could-not-observe.
An away supervisor observed alive refuses with `refuse_away_mode`, because it owns supervision here.
An away supervisor observed dead allows the start and surfaces one `UNATTENDED_AWAY_SUPERVISOR_DEAD` line naming the daemon, its recorded pid, and its last activity, and records an `away-supervisor-dead` line in the attribution log, so a crashed supervisor is never allowed past silently.
A supervisor whose liveness cannot be determined refuses with the distinct `refuse_away_liveness_unknown`, naming what could not be read, because starting beside a live away supervisor is the failure this gate exists to prevent.
Every refusal prints one `refuse_<token>` line on stderr and exits 1; a timer that mails its output should expect these as the ordinary quiet outcomes.

Which entry it launches comes from the local, gitignored `config/unattended-session`, holding one launch entry id from the fleet launcher menu above, and falls back to `state/.launch-last`.
With neither present it refuses rather than guessing a harness.
The launch itself goes through `bin/fm-launch.sh --entry <id> --detach`, so the launcher's Herdr gate, launch lock, and already-running refusal remain the single owner of every launch mechanic.

Before launching, the path writes `state/.session-origin`, a flat `key=value` record naming the origin id, the trigger, and the declaring time, and appends a `declared` line to the append-only `state/unattended-sessions.log`.
The started session receives that origin id as `FM_SESSION_ORIGIN_ID` and claims the record at session start, binding it to the session-lock holder and appending a `claimed` line, which is what makes the session's later actions attributable.
Claiming is the only write the started session makes here, and it is refused unless that session verifiably owns the lock, so a lock-refused unattended session stays read-only exactly like any other while still being announced as unattended in its digest.
`state/unattended-sessions.log` is durable evidence, never authority; `bin/fm-unattended-session.sh status`, `session`, and `log` read it and the record without mutating either.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
Secondmate handoffs are separate and unconditional: `fm-backlog-handoff.sh` keeps only its own fleet-level validation and always delegates the item move to `tasks-axi mv`, the single owner of the backlog format.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the installed build passes the shared version and feature probe owned by [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend (config/backend / FM_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.
Every Treehouse-backed crewmate or scout spawn inspects Treehouse's pool status before allocation, and allocates only a pool slot that is demonstrably empty.
It prefers `treehouse status --json`, which needs `jq`; on Treehouse builds older than v2.1.0, which have no `--json` flag, it reads the human-readable table instead and needs no `jq`.
A slot that still holds work is skipped, by entering the chosen empty slot by name; the spawn is refused when no available slot is empty, because `treehouse get` would then hand out one of them.
A pool can additionally hold its next free slot for one queued trunk repair, so any dispatch other than the one task that hold names is refused that slot until the holder takes it or the hold releases; `bin/fm-slot-reservation.sh` owns opening, reading, and releasing one.
The guard never releases, resets, or cleans a slot, and leaves release decisions to `fm-teardown.sh`; [`verification/worktree-allocation.md`](verification/worktree-allocation.md) owns the empirical Treehouse behavior behind that boundary.
New spawns choose the backend in this order: an explicit `--backend` flag that current authority for that exact task alone has authorized (a present captain instruction or the task's own accepted brief; never later-task precedent by analogy), then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `FM_BACKEND=<name>`, or by telling the first mate in chat.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for ship and scout tasks; `backend=orca` and `backend=cmux` both still refuse `--secondmate` until secondmate launch semantics are designed for each.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start secondmate liveness sweep uses the recovery-grade `fm_backend_agent_state` classifier where verified.
The comment above that function in `bin/fm-backend.sh` is the single owner of its detailed state contract and recovery authorization.
The compatibility helper `fm_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry from-firstmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
Legacy tmux metadata remains cleanup-compatible when its exact window name is `fm-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding.
`FM_HOME` determines Herdr's home label: the primary home uses `firstmate`, and a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`.
[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.
The local `config/herdr-presentation-spaces` file instead opts a home out of Herdr's default-on disposable single-task visual projection; [Presentation spaces](herdr-backend.md#presentation-spaces) owns its accepted values, default, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The setting is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Test cleanup must use the guarded path in [`docs/cmux-backend.md`](cmux-backend.md#current-operation-and-safety), never enumerate-and-close every workspace.
`config/backend` is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `firstmate:0` tmux fallback with a warning.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.
`FM_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.
When launching a Secondmate, the primary copies the presence flag into its home and passes the primary session's frozen decision as a non-empty `FM_TRACE_CONTEXT=on|off` override for the Secondmate's own session start.
A Secondmate on a remote route is covered the same way: the primary resolves and records that task's carrier, and the configured host exports it and receives the same enablement snapshot.
The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running home.
See [`trace-context.md`](trace-context.md) for carrier semantics, supported routes, the manual fleet-restart requirement, the session boundary, and safety limits; `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records repeatable evidence.

## Platform decision-surface seam (config/decision-surface-platform)

`bin/fm-decision-surface.sh` composes the fleet's own landed deterministic owners and stands alone with no configuration.
A deterministic platform can publish a richer projection of the same surface - `why_not_now`, allowed and forbidden transitions, path health, authority, and whether reasoning is required - through its own AXI launcher.
The optional local, gitignored `config/decision-surface-platform` points at that launcher so the seam can be probed.

The file holds one value: the path to the platform's AXI launcher executable, on the first non-empty, non-comment line.
It is a path and never a command line, because the arguments belong to `fm-decision-surface.sh`; a private config file must not become a shell-execution seam.
A path containing spaces needs no quoting and no escaping.
`FM_DECISION_SURFACE_PLATFORM` overrides the file with a single path.

An absent file means the seam is unconfigured, which is the shipped default and changes no behavior.
`fm-decision-surface.sh platform-seam` prints the seam contract; adding `--probe-platform` runs the launcher's read-only fleet query and reports what it measured rather than what was assumed.
The seam reports `wiring: not-wired` until the platform projection resolves this home's fleet task ids: a reachable launcher that names none of this fleet's work is projecting other identities, so consuming it as fleet truth would be the same silent contradiction the surface exists to prevent.
[`verification/decision-surface.md`](verification/decision-surface.md) records the dated probe evidence and the command that refreshes it.

## Browser Sol control venue (config/sol-control.json)

[`bin/fm-outbound-artifact-lib.sh`](../bin/fm-outbound-artifact-lib.sh) owns the outbound transport invariant, while `bin/fm-outbound-artifact.sh` enforces it.
Detecting that condition needs no configuration and always runs.
Creating the missing artifact on the `sol-control` channel needs to know where to address it, and that is what this optional local, gitignored file holds.

The file is one JSON object with exactly the three fields shown below when used by a landing path.

```json
{ "repo": "owner/name", "issue": 2, "landing_domain": { "repos": ["owner/product"] } }
```

`repo` is the control repository in exact `owner/name` form, and `issue` is the control issue number a request is posted to as a comment.
`issue` may be a JSON number or a non-empty string of digits; both are read the same way.

`landing_domain.repos` names the repositories whose landings this home has placed under Browser Sol control, each as the venue's own `owner/name` path.
It is compared case-insensitively, because a forge path is case-insensitive and a case difference that read as a different repository would shed the domain by renaming nothing.
Inside that domain a landing needs a live review request covering its exact head and REFUSES without one; outside it, the landing is not-applicable on positive grounds and proceeds through the ordinary gates.
`{"repos": []}` declares that no landing in this home is governed, which is the way to keep a control venue for review correspondence without placing any landing under it.

Omitting `landing_domain` entirely is NOT the same as declaring it empty.
A home that configured Sol control and never said what it governs has an invalid venue configuration, so both landing paths report `FM_LANDING_VENUE_INVALID` and refuse rather than reading the silence as permission.
A home with no `config/sol-control.json` at all has placed nothing under Sol control and is unaffected, which is the shipped default.

An absent or incomplete file does not make a waiting item clear.
It makes that item's artifact state could-not-observe - reported as `FM_OUTBOUND_TRANSPORT_UNCONFIGURED`, exit 4 - because the sweep genuinely cannot see the venue it would have to look at.
Detection and emission are separated exactly so an unconfigured venue can never read as a satisfied invariant.
The `pull-request` channel ignores this file entirely: it resolves each project's venue from that clone's own push remote, and it never creates the artifact at all.

The same venue is what makes a candidate publication and a landing ruling-governed.
[`bin/fm-landing-seam-lib.sh`](../bin/fm-landing-seam-lib.sh) reads this file and the correlation store at both merge chokepoints, so a candidate a live Sol review request governs cannot land without consuming the one-use authorization that request's ruling grants, while a candidate PROVEN outside the declared landing domain lands through the ordinary gates and reports that explicitly.
That proof is what `landing_domain` supplies: without it the seam would have to read an absent correlation record as an absence of governance, which is how an obligation that was never written down becomes indistinguishable from work no ruling was going to cover.
A home holding live Sol requests with this file absent is a contradiction rather than an ungoverned home, and both landing paths refuse it as could-not-observe.

`fm-outbound-artifact.sh check` reports the invariant, and `bin/fm-bootstrap.sh` relays its defects and unevaluable observations at every session start so a stranded item or a blind sweep surfaces without anyone going looking.
Configuring this file is therefore also what lets a session start POST: a session holding the fleet lock reconciles the missing sol-control requests it finds, while a lock-refused or detect-only session performs the same bounded read and emits nothing.
`bin/fm-bootstrap.sh`'s header owns that mutating-sweep list.
[`verification/outbound-transport-invariant.md`](verification/outbound-transport-invariant.md) records the dated watched-red evidence for each control and the commands that refresh it.

Two timeouts bound that session-start relay, and they are deliberately separate names for separate things.
`FM_OUTBOUND_TIMEOUT` (default 15) bounds **one** forge or git observation inside the sweep; `bin/fm-outbound-artifact.sh` owns it and never applies it to a whole run.
`FM_OUTBOUND_BOOTSTRAP_DEADLINE` (default 60) bounds the **whole** sweep that `bin/fm-bootstrap.sh` starts, and must stay several probe timeouts wide so a single slow observation cannot consume the run.
When the deadline expires the sweep is terminated and reported as unevaluable rather than partially believed, because a sweep that was cut short did not answer the question either way.
[`vocabulary-collisions.md`](vocabulary-collisions.md) carries the ruling that split the two names and the condition under which the split retires.

## Publication identity policy (config/publication-identity.json)

[`bin/fm-publication-seam-lib.sh`](../bin/fm-publication-seam-lib.sh) decides whether a guarded remote-changing act may proceed, and this optional local, gitignored file is where a home declares trusted publication venues and the parties governing candidate work on them.
It names real people and real delivery actors, so it is home-private and never ships in a template repo.

```json
{
  "generation": "pol-2026-08-22",
  "placeholders": ["Nobody <nobody@example.invalid>"],
  "venues": {
    "github.com/owner/name": {
      "identities": {
        "author": "A Person <person@example.invalid>",
        "committer": "A Person <person@example.invalid>",
        "delivery_actor": "forge-login",
        "maker": "maker/binding",
        "reviewer": "reviewer/binding",
        "ruling": "browser-sol"
      },
      "review_contracts": ["runtime-change-review"],
      "protected_refs": ["refs/heads/release/*"],
      "work": {
        "refs/heads/some-branch": { "item": "work-id", "role": "canonical" }
      }
    }
  }
}
```

`generation` is required and is part of what an authority binds, so bumping it retires every authority granted under the previous one.
A venue named here is trusted and governed for publication; a venue absent from the file is not governed by this policy, though a live Browser Sol request may still govern candidate work.
All six `identities` axes are required for candidate publication on a governed venue: a policy declaring four of them has not made a weaker promise, it has left two unstated, and an unstated axis is could-not-observe.
`maker` and `reviewer` must name different parties.
`review_contracts` names the capability contracts a governed venue requires its `reviewer` to hold for candidate publication, checked against the role qualification register at publication time.
It is required for candidate publication on a governed venue on the same terms as the identity axes: a venue declaring none has not promised a lighter review, it has left unstated what its reviewer had to be qualified for, and that is could-not-observe.
A governed candidate publication also requires a ruling bound to the exact head being published; declaring a venue governed says a review is REQUIRED and never that one happened.
Attestation-evidence publication uses the venue declaration only as destination trust: it may update only `refs/notes/no-mistakes`, carries no semantic work identity, and is not authorized by candidate identities or rulings.
`protected_refs` adds glob patterns to the built-in set of refs custody replication may never address, and a home may add to that set but not subtract from it.
`work` maps each publishable ref to the semantic work identity it carries and its `role`; only `canonical` is actionable, so a retained predecessor stays readable and stays unable to publish.
`placeholders` adds identities to the built-in list that is never a governed party whatever a policy says; that list is built in rather than configured because a placeholder a home could switch off is not a floor.

A GitHub email association is never maker proof: the mapping is what this file states, and an identity it does not state refuses.

An absent file means this home has declared no publication governance, and a publication no live request holds proceeds and reports that it was ungoverned.
Once the file exists, a publication whose venue it does not name and whose work is unstated is could-not-observe rather than ungoverned, because an unidentifiable subject must not become the way around governance a home has opted into.
[`verification/candidate-publication-effect-guard.md`](verification/candidate-publication-effect-guard.md) records the dated watched-red evidence for each control.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` keeps test evidence outside the repo and pins `commands.lint` to `bin/fm-lint.sh` so local lint matches CI.
That evidence policy is specific to the firstmate repo: target projects may legitimately commit `.no-mistakes/evidence/` from their own no-mistakes pipeline, but firstmate keeps `.no-mistakes/` local and CI rejects tracked entries under that path.
It does not set `commands.test` to a complete `tests/*.test.sh` walk.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.
Portable shard evidence and coverage rules are in [fm-test-portable-shards.md](fm-test-portable-shards.md); [herdr-backend.md](herdr-backend.md#destructive-lab-safety) owns the real-Herdr lane's isolation boundary, and [runtime-backends.md](verification/runtime-backends.md#herdr) owns active evidence.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and rewrite or prune the matching bullet in place; add a new bullet only for a genuinely new durable preference.
Shared captain preferences that apply across secondmate domains live only in the primary home's optional `data/captain-shared.md`.
`secondmate-provisioning` owns its propagation contract, including the required header, read-only secondmate copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/captain.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/captain.md`: inspect the current file first, then rewrite or prune stale entries instead of appending forever.
There is no shared learnings file by captain decision.

## Home-private commitments (data/commitments/)

The tracked `commitments/` registry holds commitments about firstmate's own shared code and ships to every home.
`data/commitments/` is an optional, gitignored overlay for commitments that are private to one home - a captain authorisation, a local exception - which must not reach a shared template repo.
Entries use the same field contract, validated against the tracked `commitments/schema.json`, and an id must be unique across the two sources.

The two sources differ deliberately in what their absence means.
An absent tracked registry is could-not-observe and is reported, because that directory ships with `bin/`, so a missing one means the register itself is not working.
An absent overlay is silent, because most homes have no private commitments.

`bin/fm-commitment-register.sh` is the only interpreter, and its header and `--help` own the mechanics.
Every state it prints is computed from that entry's probes on the spot and is never stored, so an entry retires by itself when its commitment becomes real, and no hand-written status word can satisfy one.
A commitment with more than one half declares more than one probe and is satisfied only when every half is observed good, so a half nobody could observe withholds satisfaction rather than being carried by the halves that passed.

The one thing it writes is `state/commitment-probe-cache/`, and only for the probes pinned into decision files, which are consulted on the open-decision fold's hot path rather than once per session.
That cache is an accelerator for an answer and never a substitute for one: a stored result carries its observation time into whatever reads it, and past `FM_COMMITMENT_PROBE_CACHE_TTL` seconds (default 3600, `0` to disable) it is not served at all.
It is keyed on what the probe's answer depends on - the decision file's bytes, the task worktree, and that worktree's head - and deliberately not on the task's status stream, because the open-decision fold is driven by status appends, so keying on those would invalidate the entry precisely on the append where the cache was meant to help while saying nothing about the worktree the answer actually lives in.
`bin/fm-teardown.sh` reaps a task's stored results with the task, and the directory is listed in the `AGENTS.md` state inventory.

There are two kinds of probe here and they are not the same question, so they do not share a switch.
The register's own typed probes are a closed set this repository owns, can audit, and bounds at 10 seconds, so running one is a cost decision.
A decision file's `run:` is arbitrary text written by whoever authored a ruling and executed by `bash -c` inside a task worktree, so running one is a trust decision.

The probe kinds are closed but their targets are not, so every path a typed probe names is resolved only under the tracked code root.
Which args are paths is derived from `commitments/schema.json`, which marks each one, rather than restated in the script where a second list could go vacuous the day a kind is added.
An absolute path is refused verbatim, upward traversal is refused, and a symlinked target is refused wherever it points, because what a symlink resolves to is not what the register audited; a refused target makes the entry inadmissible and is reported, never silently skipped and never a pass.
An absent target is not refused, because an owner or test that does not exist is an observed absence rather than an unobservable one.
That constraint is what makes running typed probes at session start a cost decision rather than a trust one, because the overlay at `data/commitments/` is gitignored and unreviewed.

Session start runs typed probes and never a decision file's `run:`, and that is a safety requirement rather than a performance one.
`bin/fm-session-start.sh` sets `FM_COMMITMENT_NO_DECISION_RUN=1` on exactly the calls that reach the open-decision fold - its wake drain, its admission read through `fm-fleet-snapshot.sh`, its bootstrap relay, and its deferred network stage, the last two of which reach the fold through `fm-send.sh` - and on nothing else.
Which calls those are is derived in `tests/fm-session-start.test.sh` rather than restated anywhere, because the set grows the day a script session start already invokes gains a fold read.
It is deliberately not exported over the whole subtree, because that subtree relaunches secondmates through `bin/fm-spawn.sh`, which scrubs no environment, and a safety flag that escaped into a long-lived agent would wedge closure there for that agent's whole life.
The typed probes keep running at session start, which is how an entry whose commitment became real still retires there with no hand edit rather than printing forever.
Not running is not accepting: a criterion whose `run:` was not executed answers could-not-observe and no stored verdict stands in for it, so the resolution stays visibly unverified and still open.
A wake drain, a decision-hold read, or a fleet snapshot run outside session start evaluates decision probes normally, while session start's own wake drain and admission read are inside the guard and report those keys as still open; `--no-decision-run` requests the same mode explicitly.

The register's own typed probes are bounded by `FM_COMMITMENT_PROBE_TIMEOUT` (default 10 seconds) and a decision file's `run:` by `FM_COMMITMENT_DECISION_PROBE_TIMEOUT` (default 60 seconds).
The larger second bound is derived rather than picked, and `commitments/schema.json`'s `probe_bounds` carries the same two numbers and the same derivation: the 2026-08-10 ruling makes `cited-control` the default tier and its `run` is a test invocation, `tests/fm-commitment-register.test.sh` runs in 7.8 seconds here and a pinned `cited-control` probe invokes it twice, so one probe costs about 15.6 seconds and 60 is roughly 4x observed with headroom for machine load.
A probe stopped at its bound is reported as a `TIMEOUT`, distinct from every other could-not-observe cause, because could-not-observe cannot close a key and a chronically timing-out probe would otherwise block a closure forever while reading as an ordinary open item.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for the startup prompt-memory surface: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.
To select another allowance, replace the primary home's file with one valid positive value in the exact format below; the next locked bootstrap convergence or `bin/fm-config-push.sh` propagates it to registered secondmates.
A secondmate does not create an independent default and instead receives the primary value through the inherited-local-material contract in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.
Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.
An inherited `data/captain-shared.md` counts in a secondmate's total but remains primary-owned and read-only there.
The internal `/stow` skill curates only the editable local files in that case and reports the primary-owned shared file as a concrete exception if it alone exceeds the budget.
The helper's header owns exact parsing, publication, and report output mechanics.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
The concise single-line route contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.
A remote route adds `host:` and `root:` before the existing fields and places the whole secondmate home on that SSH host; it does not make ordinary workers remotely placeable.
[`remote-secondmates.md`](remote-secondmates.md) owns current remote setup, operation, and safety behavior.
Use `fm-home-seed.sh validate` to check the complete operational registry contract documented by the command itself.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh local firstmate worktree for the secondmate home.
Use `fm-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>...|--no-projects}` to provision a whole home on an SSH-reachable host.
Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses In flight, Done, or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
The seeded home's `data/charter.md` owns the standard secondmate lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.
Each seed writes an `.fm-secondmate-home` identity marker at the home root.
The tracked root `.gitignore` ignores that marker, so validation can read it without making a freshly seeded home appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` persists a path or passes it to another process, it resolves each applicable relative `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory against the caller's working directory, preserves absolute spellings unchanged, and rejects an unresolvable relative directory with the offending variable named.
Bootstrap applies the same relative `FM_HOME` resolution only when embedding that home in the generated X-mode poll shim; other transient consumers retain their existing shell-relative behavior.
For the herdr backend, `FM_HOME` also determines the workspace label used by the adapter.
For the zellij backend, `FM_HOME` does not split containers, but it determines the readable home prefix embedded in visible tab titles; use `FM_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij home label also includes a short hash of the resolved `FM_ROOT` path.
For the cmux backend, `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `FM_HOME` determines the default config path and readable home prefix embedded in workspace titles.
The full cmux home label also includes a short hash of the resolved `FM_ROOT` path, and there is no per-home container split.

## Harness support

claude, codex, opencode, pi, pi-signed, grok, and kimi are empirically verified for crewmate and secondmate launches; [README requirements](../README.md#requirements) own the set supported for the primary session.
New harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - each harness's busy-state source, interrupt and exit commands, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
The verified launch command templates have one owner, [`bin/fm-launch-lib.sh`](../bin/fm-launch-lib.sh); the remaining per-task launch mechanics live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh), which sources it.
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate captain-approved crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When pi-signed is selected, Firstmate launches the executable named `pi-signed` from `PATH` with `FM_PI_HARNESS=pi-signed` and refuses the launch if it is unavailable rather than falling back to pi.
Plain Pi launches set `FM_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`fm-harness.sh secondmate-model` and `fm-harness.sh secondmate-effort` expose only the optional tokens from `config/secondmate-harness`; `config/crew-harness` remains a bare adapter-name file.
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; for a local route, an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
Remote secondmate routes accept verified harness adapters only and reject raw launch commands.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The inherited-local-material contract is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `fm-spawn.sh` runs `fm-kimi-turnend-hook.sh install`, drops a per-task `.fm-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.
Kimi continues to use the captain's normal Kimi home, including the existing config, skills, and memory; Firstmate does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the captain's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.
Its `remove` action excises only the marker-delimited Firstmate region and removes Firstmate's hook files.
For Pi and pi-signed secondmate launches, `fm-spawn.sh` starts the selected executable with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree.

### Claude context-pressure telemetry

Claude Code passes a host-computed `context_window` object to status-line commands with `remaining_percentage`, `used_percentage`, `total_tokens`, and `current_usage`.
Firstmate's tracked Claude settings send that payload to [`bin/fm-context-statusline.sh`](../bin/fm-context-statusline.sh), which displays the real used and remaining percentages rather than estimating pressure from transcript text.
At 70 percent used or higher, the display adds `COMPACT NOW: /compact` so the existing compaction doctrine has an instrument-backed trigger.
Only `used_percentage` and `remaining_percentage` are required; when the optional `total_tokens` or `current_usage` is missing or invalid, the real percentages and the 70 percent trigger keep rendering and each missing optional field is named in the display, so the instrument never invents a value and never degrades silently.
A spawned Claude crewmate also receives a git-excluded local setting that writes the `context_window` fields actually present, a `missing_optional_fields` list when any optional field is absent, and the derived `compact_recommended` boolean atomically to `/tmp/fm-<task-id>/context-pressure.json`.
Generated crewmate instructions tell the worker to use that snapshot as the source of truth at phase boundaries and run `/compact` when the boolean becomes true.
The snapshot stays in the existing per-task temporary root, so ordinary cleanup removes it without adding fleet state or a new completion signal.
Payloads without both valid percentages produce no display, remove the optional stale snapshot, and leave the Claude session running normally.
This is presentation and worker advisory only: it does not emit fleet notifications or change routing, supervision, worker lifecycle, isolation, or completion detection.
The other verified worker runtimes do not expose this verified Claude `statusLine` payload contract, so their adapters and behavior remain unchanged.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves its profile object or array under the operating contract in `AGENTS.md` section 4 and `quota-array-dispatch`, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`, plus the `--route` a dispatch claims once this home configures routed pools ([below](#routed-pools-optional)).
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "_floors": {
    "<floor name>": "<free-form note about what this capability floor means>"
  },
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "floor": "<optional capability floor this route resolves against>",
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>", "floor": "<optional floor>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
The optional top-level `_floors` object declares this home's capability floor vocabulary: each key names a floor, and each value is a free-form note the shell scripts never read unless this home also configures routed pools, where an object value declares axes they do check ([below](#routed-pools-optional)).
The optional `floor` field names the capability floor a route resolves against, and it is accepted on a rule, on any `use` profile, and on `default` in either its object or its array form.
[`bin/fm-reasoning-lib.sh`](../bin/fm-reasoning-lib.sh) reads the vocabulary as the union of the `_floors` keys and every `floor` value the file defines, and `fm-spawn.sh` refuses a `--capability-floor` outside it rather than recording a capability band this config never granted.
A dispatch that names no floor inherits the default route's floor, which for an array-form `default` is the first floor its profiles define.
A home whose config defines no floor at all records `capability_floor=unconfigured`, and a config that exists but cannot be read fails closed as unverifiable so that a recorded floor is never checked against nothing.
If a selected profile carries an effort value the chosen harness does not accept, `fm-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
The Luna Max production binding below is the fail-closed exception to that generic compatibility behavior.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

### Routed pools (optional)

A rule may additionally carry a `route` id and an ordered `pool`, which turns that rule into a route the shell scripts enforce.
This is the one part of this file the scripts read as route policy rather than as prose, so it is opt-in per home except for the global Luna Max production binding described below.
A config with no `pool` anywhere, or a home with no config at all, otherwise behaves exactly as the section above describes.

```json
{
  "_floors": {
    "<floor name>": { "effort_floor": "<band|WAIVED - why>", "context_ceiling": 0,
                      "tool_loop": "<verified-agentic|required|not-required>",
                      "selectable_by_crew_rule": true }
  },
  "_models": {
    "<provider>/<model-id>": { "smart_zone": 0, "effort_expressible": ["<band>"],
                               "tool_loop": "<verified-agentic|required|not-required>" }
  },
  "rules": [
    { "when": "...", "route": "<ROUTE-ID>", "floor": "<floor name>",
      "use": { "harness": "<adapter>", "model": "<name>", "effort": "<band>" },
      "pool": ["<provider>/<model-id>"], "promotion_target": "<ROUTE-ID|NONE - terminal rung>" }
  ]
}
```

A route id is defined by a rule, or by the top-level `default` in either its object or its array form; a `default` pointing at an existing rule is not a second definition.
Every reader agrees on that one rule: `fm-route.sh routes` lists a route defined only under `default` alongside the rest with its `defined_at` path, and a pool that lives only under `default` turns enforcement on exactly as a pool on a rule does.
The same id on two rules is refused, because every check against it would be meaningless.
Pool entries and `_models` keys always use the fully qualified `provider/model-id` form; a bare model name resolves against the pool by its model half and is refused when it matches more than one entry.
Pool order is the failover order, and `promotion_target` names the route a promotion escalates to; neither is traversed automatically.

`_floors` values may stay free-form strings, in which case there is nothing to check.
An object value declares the three axes a check can mechanically test against `_models`: `effort_floor` as a minimum band that a higher band satisfies and a provider default never establishes, `context_ceiling` as the minimum `smart_zone` a candidate must carry, and `tool_loop` as the minimum recorded loop evidence.
An `effort_floor` string beginning `WAIVED` waives the effort axis outright, and `selectable_by_crew_rule: false` puts the floor out of reach of every rule.
A candidate the config lists in a pool but records no evidence for is refused as unverifiable rather than admitted, because unmeasured is not the same as met - including when the config carries no `_models` block at all, which records no evidence for anything.
A missing input is a refusal and never a skipped check: a dispatch that names no model is refused as unverifiable against the pool it claims, and a rule whose `floor` names an id `_floors` does not define is refused rather than enforcing nothing.
An axis value the vocabulary does not contain is the same refusal, on every axis: a misspelled `tool_loop`, a non-numeric `context_ceiling` and an `effort_floor` outside the band list are each refused by name with the value that could not be interpreted, because an axis that silently enforces nothing is a floor an operator believes is armed.
A model or provider the availability record currently holds is refused at the same point, naming the held state, the scope, the subject and its recorded expiry, so `check` and `eligible` can never give opposite answers about one model.

An object floor may additionally declare `requires_capabilities`: an array of capability-contract ids from the role qualification register that every candidate must hold a current `QUALIFIED` record for.
That axis is not checked against `_models`, because no per-model field can answer "was this binding ever observed to do this job"; ["Role qualification register"](#role-qualification-register-qualifications) below owns it.
An absent `requires_capabilities` leaves the register unread and changes nothing, which is how a home that never opted in stays exactly as capable as it was.
A present one that is not a non-empty array of non-empty strings is refused as `requires_capabilities_malformed` against its exact config path, by the same rule every other axis follows: a floor that silently enforces nothing is a floor an operator believes is armed.

Every production selection of Luna has one accepted invocation binding: profile `luna-max`, exact model `openai-codex/gpt-5.6-luna`, harness `pi` or `pi-signed`, and effective effort `max`.
`fm-spawn.sh` applies that binding even when routed pools are not configured and refuses a provider-default, `high`, unknown, noncanonical-model, or unsupported-harness Luna invocation before launch; OpenCode is not a supported Luna Max harness.
In a routed config, the Luna model record must also carry `effort_lock: "max"` and include `max` in `effort_expressible`, while the selected route must resolve to an object floor with `effort_floor: "max"` and a matching `use` profile whose effort is `max` and whose harness is `pi` or `pi-signed`.
Route `check`, `eligible`, and `next` all apply those same requirements to the effective matching profile, including a matching entry later in a `use` array, so removal or downgrade makes Luna ineligible rather than silently changing its invocation.
This binding validates how an already-selected Luna dispatch launches; it does not qualify a task for Luna or replace firstmate's separate natural-language rule and role-selection judgment.

`bin/fm-route-lib.sh` owns these rules, `bin/fm-route.sh` reads them, and `fm-spawn.sh` enforces them at the chokepoint: a ship or scout dispatch in a home with routed pools must name the route it claims with `--route` - or an explicit `--capability-floor` naming exactly one route - and a dispatch outside that route's pool or below its floor is refused naming the route, the exact JSON config path, the configured value and the observed one.
A resolved Luna binding lands in `state/<id>.meta` as `profile=luna-max`, including for an unrouted or secondmate launch.
For a routed dispatch, the route and a digest of the enforced policy surface additionally land as `route=` and `route_policy_digest=`, and the recorded `capability_floor=` becomes the route's own.
Enforcement applies to the next dispatch only; work already under way keeps the record it was dispatched under.

### Quota-aware routing (`_providers`, `_availability.quota_gate`)

The availability record above remembers what FAILED.
This is the other half: what the provider says BEFORE anything is dispatched, so an exhausted window removes a candidate instead of producing a dead worker.
`bin/fm-capacity-lib.sh` owns the observation, `bin/fm-route-lib.sh` merges it into eligibility, and `bin/fm-spawn.sh` enforces it at the same chokepoint as the route and the floor.

Availability is read from `quota-axi`, which owns the window semantics entirely.
Each provider's `quotaSemantics.effectiveAvailability[]` already carries, per scope, the effective remaining percentage after taking the minimum across every window that bounds it.
Firstmate reads the entry for the most specific scope quota-axi publishes for a model - `model:<model-id>` when there is one, else `all_models` - and never combines windows itself.

The join between the two vocabularies is DECLARED, never inferred.
quota-axi names providers under its own identifiers and a routed pool names them under this config's, and the two overlap by coincidence rather than by contract.

```json
{
  "_providers": {
    "<provider>": { "quota_observable": true, "quota_axi_provider": "<quota-axi provider id>" }
  },
  "_availability": {
    "quota_gate": { "exhausted_at_percent_remaining": 0 }
  }
}
```

`quota_axi_provider` names the quota-axi provider whose windows actually meter this provider's usage, recorded from evidence such as compared credential claims rather than from a matching prefix.
`exhausted_at_percent_remaining` is the percentage at or below which a published window counts as spent; it defaults to `0`, so the gate removes a candidate only when the provider itself reports nothing left, and an operator who wants a reserve raises it.

Every candidate gets one of exactly three verdicts, and the third is a real result rather than a missing one.

| verdict | meaning | effect on eligibility |
| --- | --- | --- |
| `available` | an observed bound says capacity remains | eligible |
| `exhausted` | an observed bound says capacity is spent | removed from the schedulable set |
| `could_not_observe` | neither could be established | eligible, with the reason and its repair recorded |

`could_not_observe` is neither "available" nor "unavailable", and it arises whenever `quota-axi` is absent, older than its compatibility floor, unreadable or slow; a provider declares `quota_observable: false`; a provider declares readable quota but no `quota_axi_provider`; quota-axi reports no such provider, or reports it with unknown semantics; or no published scope covers the model.
Each case names the exact field or repair, because a disclosure nobody can act on is not a disclosure.
A home where no provider declares a `quota_axi_provider` skips the read entirely, because no verdict could change either way; the per-model disclosures are identical and the gate costs nothing until a binding exists.
This one gate therefore fails toward dispatch, which is the opposite of every other safety input in this repo and is deliberate: the observation can only ever remove a candidate the routing policy already admitted, so failing to observe removes nothing and leaves a home exactly as capable as it was before.

Availability may remove a candidate from the currently schedulable set.
It never lowers the required capability floor.
The candidates it filters are the claimed route's pool as the floor already filtered it, so when the filtering empties that set the lawful outcomes are to wait or to escalate - never a weaker model.

A capacity substitution must also preserve the RUNNING EFFORT BAND.
Anything offered in place of a spent model has to express the band the dispatch is actually running at - the effort it named, or the one its floor states - and a candidate whose `_models.<model>.effort_expressible` evidence does not cover that band, or is absent, is not offered at all.
This is a substitution invariant rather than a floor axis, so it holds even where a route floor states no `effort_floor` or waives it: a floor that requires no particular band still leaves a running band that substitution must not silently change.
Unverifiable expressibility withholds the candidate rather than admitting it, because declining to substitute leaves the work waiting, which is lawful, while substituting on unverified band evidence is the degradation this gate exists to prevent.
Because the rule lives in candidate eligibility itself, the spawn chokepoint, `bin/fm-route.sh eligible`, `bin/fm-route.sh next` and the deferred-retry driver all read one answer, and a withheld sibling is named in the refusal rather than silently missing from a shorter list.

The gate is asked in the declared intake order `ROUTE -> ADMIT -> ELIGIBLE`.
Capacity is therefore evaluated after fleet admission and before anything is allocated: a deferral is durable, resumable state, so recording one before admission has decided the fleet accepts this work at all would let eligibility create an obligation admission never authorized.

Every ship and scout dispatch in a home with routed pools records `capacity_observed=` and `capacity_evidence=` in `state/<id>.meta`, including when the verdict was `could_not_observe`.
An absent pair means the home enforces no routed pool, which is a different fact from an unobserved one and is never written as one.

Run `bin/fm-route.sh capacity [--route <id>]` to see the current observation for every routed model, and `bin/fm-route.sh eligible --route <id>` for the pool filtered by all four owners at once.

### Capacity deferral record (state/<task-id>.capacity)

When every floor-meeting candidate in a route's pool is out of capacity, the dispatch is DEFERRED rather than refused: the work is recorded, held in the backlog as a `load` hold, and resumed automatically once capacity returns.
`bin/fm-capacity-retry.sh` owns the record and the resume; nothing else writes it.

The record is a private key=value file holding the route, floor, pool, reason, retry condition and the typed dispatch fields of the call that was deferred.
Every command refuses a record that is not an ordinary regular file with exactly one link, and leaves the suspect path untouched.
It stores no command line: every field is re-validated against its own closed vocabulary or path-safety rule and passed as a separate argument to `bin/fm-spawn.sh`, so a state file can never name something to run.
Because it is a file and keys on the task id rather than a pid, a deferral survives firstmate restart, terminal closure, host reboot and session replacement.

`retry_after` is the earliest recovery time any provider published for the blocked candidates.
A deferral is re-checked no earlier than that; with no published reset it is re-checked on a doubling backoff from `FM_CAPACITY_RECHECK_BASE` (900 seconds) toward `FM_CAPACITY_RECHECK_CAP` (10800 seconds).
The check itself is `bin/fm-capacity-retry.sh tick`, which the watcher runs each cycle and session start runs once, and which re-offers the recorded dispatch to `bin/fm-spawn.sh` so ROUTE, capacity, admission, the model registry and the attempt budget are all evaluated again.
When the recorded model is spent but the pool is not, the substitute is named by the route owner through `bin/fm-route.sh next --after <recorded model>`, which returns the eligible candidates FOLLOWING it in pool order.
The driver applies no candidate rule of its own: ordering and every eligibility term, band expressibility included, come from the one owner the spawn chokepoint also consults, so a resume can never select a candidate the fresh dispatch would have refused, nor one sitting ahead of the model that failed.
If no candidate qualifies, the work keeps waiting rather than degrading.
No model turn is spent asking whether capacity has returned, and the resume records the selected candidate, route and confirmed effort band on the task status log.

Every deferral is counted by `bin/fm-attempt.sh defer`, which owns both bounds and spends no retry attempt, because a task the fleet had no capacity for did not fail.
`deferral_budget` (default 24) bounds the total so a wait can never become an infinite poll, and `defer_stagnant` against `FM_ATTEMPT_DEFER_STAGNATION_DEFAULT` (default 8) stops a wait whose observed capacity picture has not moved for that many consecutive checks.
Each counted retry recomputes and stores the sorted candidate, verdict and recovery-time signature from the current route-pool observation, while an unreadable observation uses one stable `could_not_observe` signature so repeated blindness can still stagnate.
Both bounds belong to the WORK ITEM rather than to a model, so a substitution inside the pool spends from the budget it inherited and never resets one; otherwise N pool members would multiply into N budgets and the wait would be unbounded while each individual count still looked correct.
Either bound reaching its limit is the unified terminal state `budget_exhausted`, declared as one `failed:` line on the task's status log, and session start reports those stopped waits as a `CAPACITY_DEFERRED:` diagnostic.

A wait the canonical attempt owner cannot durably count is stopped visibly rather than retained, and it stops in a DIFFERENT terminal state from a wait that reached its bound.
A spent bound is observed-bad: the pool was tried and the limit was reached, which is a routing fact worth acting on.
A count that cannot be written is could-not-observe, and the could-not-observe lands on the bound itself rather than on a detail beside it - nothing established that any model was tried and found out of capacity, only that how long the task waited is unknown.
Recording the second as the first would make a broken recorder indistinguishable from an exhausted pool, so `bin/fm-attempt.sh stop-defer` requires `--observation observed-bad|could-not-observe` with no default and records `budget_exhausted` or `blocked_by_evidence_integrity` accordingly; `loopspecs/terminal-states.json` carries the pair as source `capacity-wait` and its validator refuses a build that maps them onto one unified state.
Session start reports the unmeasurable stops as a separate `CAPACITY_UNMEASURED:` diagnostic, because repairing a recorder and deciding a wait share no action.
`bin/fm-attempt.sh stop-defer` is asked for the terminal stop it owns - no second counter, selector or stop authority exists - and the deferral record is then either marked terminal atomically or REMOVED, because a record with no terminal marker reads as an active wait and every later tick would resume it.
A record that can be neither marked nor removed is reported as needing to be cleared by hand, never left behind quietly.
If `bin/fm-attempt.sh defer` cannot record the count, the deferral fails closed, marks the capacity record terminal and declares the failed command and attempt-record path on the task status log.
After any original-model refusal that leaves work undispatched, the retry driver asks the route owner for the next eligible candidate at the recorded floor and effort band.
If every offered substitute is refused by another dispatch gate, the wait remains active and gains one durable deferral count, while the first distinct refusal is recorded once as a `blocked:` status line.
Every due retry must durably resume, retain a later check or stop for an invalid durable record, and a failure to refresh the deferral record after counting stops through the attempt owner's unified terminal state with the failed record path declared.
The work was never dispatched into a pool that could not run it and is not lost; a terminal capacity record requires explicit repair or release rather than silently resuming from unsafe state.

### Model availability record (state/model-health.json)

A private, gitignored, mode-0600 record of which models and providers the fleet currently cannot reach.
`bin/fm-route-lib.sh` is its only writer, through `bin/fm-route.sh availability hold|release`, and it writes availability alone: a model that keeps failing is recorded unavailable, never demoted, because demotion is a policy change that belongs in the routing config under review.
Concurrent holds and releases are serialized as whole-record transactions, so each mutation starts from the latest valid record, changes only its named model or provider binding, and atomically replaces the private record without erasing an independent mutation.

A hold names a model by default and is resolved against the configured pools exactly as a dispatch's `--model` is: a fully qualified name must be a pool entry, and a bare name must match exactly one.
Holding a whole provider is asked for with `--scope provider`, and the provider must be one a pool entry names.
Scope is never inferred from the presence of a slash, and a subject that could not remove any candidate is refused rather than recorded, so the command never reports a hold that silently does nothing.
A release resolves against what is actually recorded first, so a hold can still be cleared after a config edit dropped its subject from every pool.
Releasing a binding that is already absent is an idempotent no-op and does not create an empty availability record.

```json
{
  "schema": "fm-model-health.v1",
  "models":    { "<provider>/<model-id>": { "state": "<state>", "until": 0, "recorded_at": 0, "evidence": "<text>" } },
  "providers": { "<provider>":            { "state": "<state>", "until": null, "recorded_at": 0, "evidence": "<text>" } }
}
```

The state vocabulary is closed to the states the routing config's own failover conditions set: `degraded`, `rate_limited`, `model_unavailable`, `provider_unavailable`, `auth_failure`, `subscription_quota_exhausted`, `daily_quota_exhausted`, and `admin_disabled`.
A hold with a numeric `until` stops binding on read once that epoch passes, so nothing has to run to forget it; a `null` `until` holds until released explicitly, which is what an authentication failure needs.
An absent file means no remembered cooldown and never that a model is healthy, while a file that exists and cannot be parsed refuses rather than reading as an empty one.
That refusal names this record and not `crew-dispatch.json`: the two inputs fail independently and are repaired differently, so a refusal that points at the file which parses perfectly costs the whole diagnosis.
Reading this record never probes: the failure-based availability term is a local lookup, independent of the bounded `quota-axi` read that the quota-aware eligibility term performs before dispatch.
Route `check` and `routes` remain local reads, while `eligible`, `next`, and `capacity` request a current quota observation as described in "Quota-aware routing" above.

## Model registry (config/models.json)

`config/models.json` is an optional local, gitignored registry of the models this home is allowed to route work to, and the enforced copy of its zero-budget rule.
This section is the single owner of the schema and its per-field semantics.
`.agents/skills/model-onboarding/SKILL.md` owns the admission policy that decides what belongs here, and `bin/fm-model-registry-lib.sh` owns the enforcement mechanics.

The registry exists to make one safety rule checkable by a machine rather than by memory: an API-key provider may be routed only to a model on an explicit verified-free allowlist.
One credential commonly reaches both free and metered models on the same provider, rendered identically in every catalogue listing, so a single plausible model name is a charge.
The unit of authorization is therefore the model, never the provider and never the credential.

Keeping the registry separate from `config/crew-dispatch.json` is what enables the referential-integrity check: bootstrap refuses when a dispatch rule names a model that is absent from the registry, carries a non-approved status, or has no live-probe record.
That catches a bad model at config-edit time, before any worker is launched against it.

```json
{
  "schema": "fm-model-registry.v1",
  "providers": {
    "<provider-id>": {
      "access_class": "<A|B|C|D>",
      "cost_posture": "<subscription-flat|api-key|self-hosted>",
      "credential_env": "<ENV VAR NAME ONLY, never a value>",
      "catalogue_sources": ["<path to a harness price catalogue>"],
      "status": "<active|blocked|dropped>",
      "status_reason": "<required when status is not active>",
      "pipeline_providers": ["<vendor name another system records for this pool>"]
    }
  },
  "models": {
    "<provider>/<model-id>": {
      "provider": "<provider-id>",
      "model_id": "<model-id>",
      "harness": "<adapter that can reach it>",
      "cost_class": "<subscription-flat|verified-free|metered|unknown>",
      "status": "<rejected|blocked|experimental|approved-fallback|approved-specialist|approved-primary>",
      "status_reason": "<required for rejected and blocked>",
      "price_at_verification": { "input": 0, "output": 0 },
      "eligible_routes": [], "prohibited_routes": [],
      "context": { "advertised": 0, "operational_ceiling": 0, "max_output": 0 },
      "controls": { "effort_bands": [], "tool_calling": true, "structured_output": true },
      "limits": { "concurrency": null, "shared_quota_pool": "<pool id>" },
      "pipeline_model_ids": ["<model id another system records for this model>"],
      "observation_level": "<O1|O2|O3|O4>",
      "evidence": {
        "probe": { "result": "ok", "rc": 0, "latency_s": 0, "at": "<ISO8601>" },
        "price": { "at": "<ISO8601>", "sources": ["<source kind>"] },
        "dossier": "<path to the dossier>"
      },
      "last_verified": "<ISO8601>"
    }
  },
  "zero_budget": {
    "allowlist": {
      "<provider>/<model-id>": {
        "price_at_verification": { "input": 0, "output": 0 },
        "verified_at": "<ISO8601>",
        "sources": ["<source kind>"],
        "hard_ceiling": "<provider-side mechanism that refuses rather than bills>"
      }
    }
  },
  "observation": { "levels": { "<O1|O2|O3|O4>": { "probe_max_age_days": 0 } } },
  "promotion": {
    "enabled": false,
    "requires_instrument": "<named evidence instrument>",
    "thresholds": {},
    "authority": {
      "t4_to_t3": "automatic-notify-immediate",
      "t3_to_t2": "captain-confirm",
      "t2_to_t1": "never-by-evidence",
      "t1_to_t0": "never-by-evidence"
    }
  }
}
```

`schema` is required and must be exactly `fm-model-registry.v1`; an unrecognized value is refused rather than best-effort parsed, so a future format change fails loudly instead of being silently misread.
Every other top-level block is optional, and an absent block simply has nothing to enforce.

`providers` classifies each provider's cost posture, and it is what lets enforcement answer "can this call cost money" for a model that is not in `models` at all.
A `subscription-flat` or `self-hosted` provider is allowed without an allowlist entry, because no per-call charge exists.
An `api-key` provider is allowed only for models named in `zero_budget.allowlist`.
A provider absent from this block is **refused**: an unknown cost posture is never treated as a default-allow.
A provider whose `status` is `blocked` or `dropped` is refused with its recorded `status_reason`.

`price_at_verification` stores the price numerically rather than only a cost class, because that is what makes a later repricing detectable; a name-only allowlist is structurally blind to one.
`catalogue_sources` names the harness price catalogues to compare against, as local data rather than a path hardcoded in tracked code, since those paths are version-pinned and move on every harness upgrade.
Both the pinned per-provider catalogue shape and the provider-fetched store shape are understood.

Evidence `sources` accept `probe`, `provider-entitlement`, `provider-doc`, `harness-static-catalogue`, `harness-fetched-cache`, `third-party`, and `inference`, in descending authority.
An allowlist entry must carry at least one genuinely price-bearing source - `provider-doc` or `harness-static-catalogue` - or it **fails validation**.
A `harness-fetched-cache` price is refreshed by the provider underneath you and cannot establish one, and a `probe` deliberately does not count either: it proves the account gets an answer, not what that answer costs.
An allowlist entry must also record `verified_at` and a `price_at_verification` that is zero in every field.

`limits.concurrency` caps how many workers may run on a model at once, and `limits.shared_quota_pool` makes siblings that draw on one free-tier pool count against the same cap, so several workers cannot collectively breach one quota.
`shared_quota_pool` is also the credential pool `bin/fm-independence-lib.sh` compares when deriving whether a checker was billed to the maker's own account, which is the fact a harness name cannot answer.

`pipeline_providers` and `pipeline_model_ids` are the optional declared mapping from another system's model vocabulary onto this registry's.
The validation pipeline records the vendor and model that actually ran in its own names (`anthropic`, `claude-opus-5`) while this registry names the same things in the fleet's routing vocabulary (`claude`, `opus`).
Two names that differ are not evidence of two vendors, and two names that match are not evidence of one, so only this declaration may relate them.
Where it is absent the independence dimensions that depend on it read could-not-observe rather than independent, which keeps an undeclared mapping honest instead of turning it into a false independence claim.
Both fields are validated as arrays of strings, because a broken safety declaration must never read as an absent one.
`observation.levels[<level>].probe_max_age_days` sets how stale a model's probe evidence may become before it is reported, which is what keeps the session-start probe sweep interval-gated rather than probing every routed model every time.

`promotion.authority` is validated as a ceiling in each direction: a home may be equally or more conservative than the values above, never more permissive.
`t2_to_t1` and `t1_to_t0` must be `never-by-evidence`, because Tier 1 is triggered by risk rather than capability rank and no accumulation of evidence may enter it.
Promotion stays dormant until both `promotion.enabled` is true and the named instrument is producing records, so activating it is a configuration and data change rather than a code change.

Enforcement is deliberately asymmetric about the file's absence.
With **no** `config/models.json`, the spawn-time check is inert and spawns behave exactly as they did before the registry existed, so nothing is forced on a home that never opted in; bootstrap then reports `MODEL_REGISTRY: no config/models.json ...` whenever the dispatch config routes to a provider-prefixed model, so the unenforced state is never silent.
With the file **present**, every unclear answer refuses: malformed JSON, an unsupported schema, an unclassified provider, a stale-evidence allowlist entry, and a missing `jq` all refuse rather than pass, because a broken safety file must never read as an absent one.
A bare model name with no provider prefix is a harness-native selector and is always allowed.

Routability is a separate axis from cost, and the two are enforced independently.
A model recorded as `rejected` or `blocked` is refused at spawn even when it carries no cost risk at all, because a model on a flat subscription can still be one the account is not entitled to use.
Availability is a third axis again: a rate-limited or cooling-down model is unavailable rather than rejected, lives in `state/model-health.json`, and never changes the routing status recorded here.

A live probe is itself a billable act on a metered provider, so `bin/fm-model-verify.sh` consults the same zero-budget decision before issuing any request, on the interval-gated sweep and on an explicit `--model` alike - a typed model name is not authorization to spend money.
A refused model is reported as `MODEL_VERIFY: refusing to probe <model> - <reason>`, no request is issued, and its prior record in `state/model-health.json` is left untouched.
`--force-probe` is the only override, and a forced probe announces itself on stdout so an authorized billable probe is never invisible.
Bootstrap reports registry problems as `MODEL_REGISTRY: invalid config/models.json - <reason>` for schema failures, `MODEL_REGISTRY: <model> ...` for integrity failures, `MODEL_PRICE: <model> ...` for drift, and `MODEL_VERIFY: <model> ...` for probe results.
Valid, current registries stay silent.
See [`docs/examples/models.json`](examples/models.json) for a starting point to copy into local `config/models.json`, and `bin/fm-model-verify.sh --help` for the probe and drift mechanics.
Rollback is deleting the file: every check becomes a no-op.

## Role qualification register (qualifications/)

`qualifications/` is a committed register answering one question a route floor cannot: has this exact binding been OBSERVED to do the job this route requires, and does that observation still apply?
It exists because missing capability evidence and incapability used to be the same value, so a route whose one plausible candidate had no evidence could only produce a captain floor-exception request - repeatedly, for the same missing evidence.
The captain ruling of 2026-08-13 separates them: missing qualification is an engineering state to resolve, and model names are bindings to capability contracts rather than the contracts themselves.

`qualifications/schema.json` is the single owner of the field contract, the five-value vocabulary, the state computation and every closed vocabulary in it.
`bin/fm-qualification-lib.sh` owns the decision, `bin/fm-qualification.sh --help` owns the mechanics, and [`role-qualification`](../.agents/skills/role-qualification/SKILL.md) owns what firstmate does with each answer.

- `qualifications/contracts/<id>.json` is one capability contract: the reusable role and risk version, exactly one of the nine axes the schema declares, and an executable predicate. A contract names a JOB and never who does it - the validator refuses a vendor-bearing key and refuses any value equal to a model or provider this home's routing config configures, because a contract naming a vendor cannot be re-run against the next candidate.
- `qualifications/records/<id>.json` is one observation of one binding against one contract, keyed by contract, fully qualified model, harness and native effort; provider is implied by the required fully qualified model and remains recorded as binding evidence. Harness version is recorded context rather than a key axis because its semantics cannot be probed on read, so that drift is bounded only by the declared `harness_semantics` dependency and its required `time_bound`; a later harness-version observation supersedes the earlier record for the same binding.
- `data/qualifications/records/` is an optional home-private overlay with the same schema, for a binding or an evidence trail a home must not publish into a shared template repo. Its absence is silent; a tracked register that exists and cannot be read is could-not-observe.

A record stores what was OBSERVED and the dependencies that observation rests on.
It never stores the state a reader acts on: the interpreter computes that on every read, and a record carrying `state`, `verdict`, `score` or any other hand-written status word is refused outright.
Five values are distinguished and none may collapse into another.

| state | meaning | effect on eligibility |
| --- | --- | --- |
| `QUALIFIED` | the predicate passed and the required assignment-distinct adjudication agreed | eligible |
| `FAILED` | the predicate ran and rejected this binding | excluded, with the evidence preserved |
| `QUALIFICATION_REQUIRED` | no applicable observation exists, or one exists without its adjudication | withheld; one bounded workflow resolves it |
| `QUALIFICATION_STALE` | a declared material dependency changed since the observation | withheld; one bounded workflow resolves it |
| `COULD_NOT_OBSERVE` | the predicate, the adjudication or a dependency could not be observed | withheld, with nothing recorded against the binding |

Freshness is computed only from the dependencies a record declares - a named file's digest, the contract's own version, and a justified time bound.
Unrelated repository bytes, a new commit, and a vendor or model label are explicitly not dependencies, because a register that went stale on every commit is one nobody can rely on.
Some dependencies cannot be probed at all: harness semantics, provider-side binding semantics and the native effort mapping have no reader this fleet can trust, so they are always marked uncovered and a record declaring one is INADMISSIBLE without a `time_bound`.
What cannot be probed is bounded in time instead, which is the third option between shouting forever and going quietly wrong.
A `FAILED` record reopens as `QUALIFICATION_REQUIRED` when a declared dependency materially changes, and the adverse record is retained rather than deleted.

Unlike the quota gate, this gate fails CLOSED where a floor declares a requirement, and the asymmetry is a property of the input rather than a preference.
An unobserved quota can only remove a candidate the policy already admitted, so failing to observe it removes nothing; a capability requirement IS the admission, so admitting on unread evidence would route work on no evidence at all.

### Zero-route classification and the bounded workflow

`bin/fm-route.sh zero-route --route <id>` says WHY a route has no eligible candidate, as one of four classifications with four different actions, derived from the per-candidate blocker sets.
`bin/fm-decision-surface.sh check route-qualified <route-id>` composes the same answer as a refusal, so firstmate never reconstructs it.

| classification | action | exit | escalates |
| --- | --- | --- | --- |
| `QUALIFICATION_REQUIRED` | activate one bounded workflow for the cheapest promising candidate | 3 | no |
| `QUALIFICATION_COULD_NOT_OBSERVE` | repair the observation; nothing is recorded against any binding | 3 | no |
| `AWAITING_AVAILABILITY` | wait; the availability hold and capacity deferral own it | 3 | no |
| `NO_MODEL_CAN_SATISFY_ROUTE` | stop and report | 1 | `CAPTAIN_EXCEPTION_REQUIRED` |

A candidate is promising only when its ONLY blocker is missing or stale qualification: one that also misses a floor axis is not made eligible by qualifying it.
Promising candidates are ordered by recorded price ascending and then by pool position, and a candidate whose price cannot be observed sorts LAST rather than first - unmeasured cost is never read as cheap.

`bin/fm-qualification.sh activate --route <id> --blocks <work-id>` creates or reuses ONE bounded workflow for that candidate.
It refuses every classification other than `QUALIFICATION_REQUIRED`, derives a deterministic tuple identity from the whole record key so two distinct tuples can never collide, suppresses activation while any incarnation for that tuple remains open, and allocates the next numeric incarnation after a prior workflow is Done so stale or materially changed evidence can be qualified again.

**The workflow is a backlog task, and that is the whole design.**
A bounded qualification run is a work item, so it is registered as one through the existing backlog owner - which is what makes `tasks-axi block --by` meet its documented precondition that the blocker must already exist, rather than working around it.
Its backlog record is then the ONLY fact about whether it is live: the blocked work's dependency is not a second copy, because `unresolved_blocker_ids` is recomputed on every read and resolves a blocker exactly when its structured record is Done.
The relationship is therefore derived on read by an owner that already exists, exactly as qualification state is computed on read and expired availability holds are dropped on read rather than swept.
`state/qualification/<activation-id>.activation` holds the workflow's inert parameters and no state at all.

There is deliberately **no transfer, compensation or reconciliation logic**, and a reader who goes looking for it should find this paragraph rather than an absence.
An earlier design mirrored the workflow's liveness into both its own record and a backlog edge, and every defect it produced was a different way for those two facts to disagree.
That machinery exists only because something is mirrored; nothing is mirrored now, so those failures are closed by construction and there is nothing left to reconcile.
Do not add a compensation path back without first re-introducing a second liveness fact, which is the thing to avoid.

No second scheduler, router, issue store, event system or polling loop exists: `bin/fm-qualification.sh dispatch` launches the worker through `bin/fm-spawn.sh`, the one chokepoint, and the bound is `bin/fm-attempt.sh` over the ACTIVATION's own identity - a qualification workflow never reads, spends or resets the accounting of the work it would release.
The CANDIDATE is the worker, dispatched on a bootstrap route it already qualifies for whose floor meets the target floor's axes; the already-qualified binding supplies only the route, never the run, and a candidate with no bootstrap route is a stop-and-report rather than a licence to self-certify.

`bin/fm-qualification.sh resolve <activation-id> --result <RESULT>` closes it.
`QUALIFIED` is verified against the register before it is accepted and then closes the workflow item - and closing it is what returns the same work identity to normal eligibility, with its identity, custody and budget unchanged and no unblock call that could fail afterwards.
`FAILED` preserves the exclusion, derives every dependent identity from the fleet snapshot's backlog edges, activates the next promising candidate FIRST for each dependent so the successor already holds every dependency, and only then closes this item.
`COULD_NOT_OBSERVE` is nonterminal: it spends one attempt, records nothing against the binding, and leaves the item open.
`loopspecs/terminal-states.json` carries these outcomes as source `role-qualification`, and deliberately gives could-not-observe no row, because an unmade observation is not an ending; an exhausted qualification bound leaves the workflow open under a `parked` backlog hold whose reason assigns Firstmate the operational decision to raise the bound or abandon the qualification.

Every ship and scout dispatch through a floor that declares a capability records `qualification_contracts=` and `qualification_observed=` in `state/<id>.meta`.
An absent pair means no floor in this home declared a requirement, which is a different fact from a requirement that went unchecked.

## Fleet admission control (`_scheduling.admission_control`)

Admission control is the third layer above routing and scheduling.
Routing decides who is capable, scheduling decides when accepted work runs, and admission decides whether the fleet should accept another task at all right now.
It is a property of the fleet, not of any task: admission reads only the fleet snapshot, never the incoming task's tier, project, model, priority, urgency, token estimate, or file overlap, so the same snapshot returns the same band for every task.
That boundary is what keeps it a separate layer instead of scheduling under a new name.

The policy lives in the optional local, gitignored `config/crew-dispatch.json` under `_scheduling.admission_control`, alongside the dispatch rules above.
This section is the single owner of the schema and its per-field semantics.
`bin/fm-admission-lib.sh` owns the executable check of that schema, `bin/fm-admission.sh` owns the evaluator and its decision record, and [`fleet-admission`](../.agents/skills/fleet-admission/SKILL.md) owns what firstmate does with each band.

Admission ships inert, and activation is an explicit per-home opt-in.
A home with no `admission_control` object, one carrying only `_`-prefixed operator notes, or one whose `enabled` is `false` changes nothing about dispatch and costs one cheap config read.
[`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) therefore ships the whole block with `"enabled": false`, so copying that file is never what switches admission on: setting `enabled` to `true` is a deliberate act, and it is what makes every ship and scout spawn consult the fleet band before allocating anything.
An enabled policy's `authority.single_primary` rule bands an invocation that does not hold this home's session lock, so switching it on changes when spawns are admitted and not only what is reported.
Enabling it adds no concurrency cap: every numeric threshold ships `null` with `enforce: false`, and `enforcement_mode: "safety-only"` makes numeric enforcement structurally unreachable until an evidence-gated mode is added.
The standing contract that isolated work dispatches immediately with no concurrency cap is therefore unchanged.

```json
{
  "_scheduling": {
    "admission_control": {
      "schema_version": 1,
      "enabled": true,
      "enforcement_mode": "safety-only",
      "fleet_id": "<fleet-id>",
      "combine": "most_restrictive",
      "severity_order": ["preferred", "soft", "hard"],
      "unknown_band": "hard",

      "bands": {
        "preferred": { "action": "admit" },
        "soft": { "action": "queue", "hold_kind": "load", "auto_reconsider": true },
        "hard": { "action": "refuse", "hold_kind": "load", "auto_reconsider": true }
      },

      "signals": {
        "census_integrity": {
          "enabled": true, "required": true,
          "source": "fresh-authority-census",
          "unknown_band": "hard",
          "max_snapshot_age_seconds": null
        },
        "backlog_consistency": {
          "enabled": true, "enforce": false,
          "source": "main-inventory",
          "unknown_band": "hard"
        },
        "admission_queue_pressure": {
          "enabled": true, "enforce": false,
          "source": "tasks-axi-load-holds-plus-ledger",
          "queued_soft_count": null, "queued_hard_count": null,
          "oldest_wait_soft_seconds": null, "oldest_wait_hard_seconds": null
        },
        "active_workers": {
          "enabled": true, "enforce": false,
          "source": "fresh-authority-census",
          "soft_count": null, "hard_count": null
        },
        "coordination_debt": {
          "enabled": false, "enforce": false,
          "source": "wake-outcome-ledger",
          "pending_wakes_soft_count": null, "pending_wakes_hard_count": null,
          "oldest_unhandled_wake_soft_seconds": null, "oldest_unhandled_wake_hard_seconds": null,
          "handled_wake_latency_window_seconds": null,
          "handled_wake_latency_soft_seconds": null, "handled_wake_latency_hard_seconds": null
        },
        "host_resources": {
          "enabled": false, "enforce": false,
          "source": "node-summaries",
          "metrics": {}
        },
        "reservation_pressure": {
          "enabled": false, "enforce": false,
          "source": "admission-registry",
          "soft_count": null, "hard_count": null
        }
      },

      "authority": {
        "mode": "single-primary",
        "authority_id": "<authority-id>",
        "config_mismatch_band": "hard",
        "unreachable_band": "hard"
      },
      "reservations": {
        "enabled": false,
        "ttl_seconds": null, "heartbeat_seconds": null, "clock_skew_tolerance_seconds": null,
        "release_on": ["spawn-failure", "teardown"],
        "reconcile_on": ["session-start"]
      },
      "queue": {
        "substrate": "tasks-axi hold --kind load",
        "release_triggers": ["teardown", "session-start"],
        "already_empty_fleet_recheck": "session-start-only"
      },
      "notifications": {
        "policy_ref": "/_scheduling/notification_bands",
        "episode_dedupe_seconds": null
      },
      "telemetry": {
        "sink": "wake-outcome-ledger",
        "record_every_decision": true, "record_signal_values": true,
        "record_config_paths": true, "record_config_digest": true,
        "credentials_forbidden": true
      },
      "dormant_triggers": {
        "<trigger-name>": { "<measurable-condition>": 1, "checkpoint": "<named review point>" }
      }
    }
  }
}
```

Values shown as `<...>` are operator-supplied, not defaults.
`null` means unmeasured or disabled; it never means zero or infinity.
Keys beginning with `_` are operator notes and are ignored, matching the surrounding scheduling config's convention.

### Fields

`schema_version` must be `1`, and `enabled` turns the whole layer on.
`enforcement_mode` accepts only `safety-only` today: the deterministic safety conditions (admission authority, census integrity, snapshot freshness) may set a band, and no other signal may.
`fleet_id` names the set of sessions sharing this policy and capacity.
`combine` accepts only `most_restrictive` and `severity_order` only `["preferred","soft","hard"]`, so no combination rule can average a hard result away.
`unknown_band` is the band a missing or contradictory required signal maps to; it accepts only `soft` or `hard`, because missing evidence must never resolve to "probably fine".

`bands` binds each band to its action: `preferred` admits, `soft` queues, and `hard` refuses.
Both non-preferred bands must name `hold_kind: "load"` - admission never opens a second queue, and a load hold can never masquerade as a captain decision.
The `preferred` band admits and therefore has no hold at all: it carries only `action`, and a `hold_kind` or `auto_reconsider` there is refused as misleading configuration.

Each entry under `signals` carries `enabled`, a fixed recognized `source`, and its own thresholds.
`census_integrity` is the required safety signal and is the only one that may set a band under `safety-only`; its `max_snapshot_age_seconds` bounds how old a reused snapshot may be before the decision is treated as unknown.
When a limit is configured and the snapshot's age cannot be measured, the freshness rule fails closed to the configured unknown band instead of admitting; with no configured limit an unmeasurable age is only recorded.
`backlog_consistency` is deliberately separate from `census_integrity`: a backlog record that contradicts task metadata must be reported and repaired, but it is not evidence that the fleet is physically saturated, and collapsing both into one health bit would close the fleet for an unrelated bookkeeping error.
`admission_queue_pressure` counts `hold_kind=load` requests; its oldest-wait age stays unmeasured because backlog age is task age, not admission wait age.
`active_workers` records the live worker count as an explanatory baseline with no cap.
`coordination_debt`, `host_resources`, and `reservation_pressure` have no collector in this home yet and must stay `enabled: false`; enabling one would record an invented value instead of an observation.

`authority` accepts only `mode: "single-primary"`.
The existing per-home session lock supplies that authority, so admission adds no new process, daemon, or admission reservation store; a session that does not hold the lock is not the admission authority and gets `unreachable_band`.
`reservations` must stay disabled until a second intake authority or a remote node is registered; its durations exist so the distributed contract is settled in advance, not so it can be switched on early.
`queue` pins the substrate and the two release triggers, and names the known already-empty-fleet gap that is deliberately left to session start rather than cured with a timer.
`telemetry` names the sink for decision records; while admission is enabled, `record_every_decision` and `credentials_forbidden` must both be true.
Each entry under `dormant_triggers` needs a named `checkpoint`, so no dormant mechanism can be reconsidered without a stated review point.

### Validation

When the file exists, bootstrap validates the policy with `jq` on every session start, including in a read-only session that did not get the fleet lock.
A home with no policy, or a note-only policy, stays silent; with `FM_BOOTSTRAP_VERBOSE_FACTS=1` bootstrap emits `BOOTSTRAP_INFO: fleet admission control inert|active` for a policy that exists, while an absent policy stays silent even then.
Anything malformed is reported as `ADMISSION_CONTROL: invalid config/crew-dispatch.json _scheduling.admission_control - <reason>` and must be corrected rather than worked around.

Validation refuses a policy that has an unknown field at any level, a threshold that is not null or a non-negative number, a soft threshold more restrictive than its hard counterpart, a threshold key without a `_count` or `_seconds` unit suffix, an unrecognized signal source, a signal enabled while its source is uncollectable, `enforce` set while its signal is disabled or while `enforcement_mode` is `safety-only`, a queue action naming any hold kind other than `load`, a `hold_kind` or `auto_reconsider` on the admitting `preferred` band, a `queue.release_triggers` value other than exactly `["teardown", "session-start"]`, a second queue substrate, telemetry disabled while admission is enabled, reservations or a non-single-primary authority enabled before their dormant trigger fires, or a dormant trigger with no named checkpoint.
Unknown fields are refused rather than ignored so a typo cannot silently disable a safety condition.

`bin/fm-admission.sh` prints the band and its explanation and exits `0` for preferred, `3` for soft, `4` for hard, and `2` when the policy is malformed or the census cannot be evaluated, so a caller that ignores the output still stops safely.
Every rule in that explanation names the observed value, its source and freshness, the exact JSON configuration path, the configured value, and the resulting band.
The decision record from `--json` is the unit of admission telemetry; when the wake-outcome ledger exposes its extension seam, that record is what gets appended, and admission never opens a competing store.

See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a copyable starting point; its `_scheduling.admission_control` block is complete but switched off, so it is a schema reference until a home turns it on.
Secondmate homes inherit `config/crew-dispatch.json` from the primary, so an admission policy applies in each inheriting home against that home's own fleet - which is the other reason activation is deliberate rather than inherited from an example.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, no-mistakes v1.31.2 or newer, compatible gh-axi, chrome-devtools-axi, lavish-axi, compatible tasks-axi per "Backlog backend" above, and compatible quota-axi.
The exact gh-axi floor is owned inline by [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh), while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh) own their tools' compatibility floors and rationale.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `fm_backend_required_tools` in `bin/fm-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), the `treehouse` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`), and `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse backend output.
Independently of that backend-output requirement, a Treehouse-backed crewmate or scout spawn needs `jq` for its pre-allocation pool inspection only when the installed Treehouse offers `status --json` (v2.1.0 and newer); older builds are inspected through the human-readable table without it.
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation, and when `config/models.json` exists, `jq` is required for model registry validation and the spawn-time zero-budget check refuses without it.
When X mode is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual` and compatible `tasks-axi` is on `PATH`, bootstrap stays silent and firstmate uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent or incompatible `gh-axi` reports `MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)`.
An absent or too-old `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; firstmate cannot resolve a profile array without a compatible binary.
That floor exists because it is the first build reporting per-credential auth sources, without which a candidate cannot be judged against the authentication surface it actually uses.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
Bootstrap also checks the shared no-mistakes validation daemon without invoking its CLI or changing its lifecycle, including in read-only sessions.
A healthy daemon and a daemon root that has never existed stay silent, while `VALIDATION_DAEMON:` reports a down daemon or an unreadable pid record; `bin/fm-bootstrap.sh`'s header owns the line format and `bin/fm-validation-daemon-lib.sh` owns the state contract.
The locked session-start bootstrap step also runs a best-effort project clone refresh through `fm-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The locked session-start bootstrap step also runs the guarded secondmate sync for recorded live homes, then propagates declared inherited local material into each validated live home.
Local routes use direct guarded filesystem operations, while remote routes delegate sync and allowlisted transfer through their configured SSH host without probing any unconfigured fleet.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a registered secondmate is skipped or its relaunch fails; already-live and successfully relaunched secondmates are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-dispatch.json`, `models.json`, `crew-harness`, `backlog-backend`, `backend`, `herdr-presentation-spaces`, `startup-memory-budget`, `trace-context`, and `data/captain-shared.md` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
When an allowlisted config item changes for an already-running local home, it sends the literal-content reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
A changed remote home instead receives one durably recorded marked re-read instruction after the allowlisted bytes have transferred because primary-local generation paths are not meaningful on another host.
The locked bootstrap inheritance pass uses the same placement-specific behavior; see `secondmate-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `role=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## X mode (.env)

X mode lets a firstmate instance answer public `@myfirstmate` mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while parent-thread context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the X-mode cadence contract: an X instance polls every 30 seconds instead of the default 300, only an X instance speeds up because a non-X home has no `config/x-mode.env`, and the session-start supervision operating block includes the cadence instruction when that file exists.
The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
While away mode is active the daemon owns the watcher and its default cadence applies; away-mode X cadence is a deferred follow-up.
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
X mode remains additive to non-X lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the X poll.
Its request handling remains in X-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.
Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, finishing with a `--final` one for ordinary X-linked work. When a typed promised-final commitment is registered, `bin/fm-public-followup.sh` owns the terminal reply and clears the legacy link after its receipt is validated.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
`bin/fm-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/fm-x-link.sh` prints a loud warning; and when either a follow-up's platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - firstmate holds and retries it once both values are recoverable.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.
Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_DISCORD_REPLY_MAX_CHARS` defaults to 1900, clamps to a minimum of 50, and resets values above Discord's 2000-character limit back to 1900.
`FMX_X_THREAD_MAX` defaults to 25 and caps oversized reply threads for every platform, marking the last retained message with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 604800 (7 days) and controls the local completion follow-up window; `FMX_FOLLOWUP_MAX_COUNT` defaults to 3 and controls the local follow-up cap.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

### Promised public replies (state/public-followup)

A relay request that spawns real work can leave firstmate owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation owned entirely by `tasks-axi public-followup`, with the full private request context staying in `state/x-context/`; firstmate keeps no parallel copy of either.
`bin/fm-public-followup.sh` is firstmate's side: it registers a commitment, reconciles typed terminal work results into it, and posts the final reply through `bin/fm-x-reply.sh --followup`.
Run `bin/fm-public-followup.sh --help` for the exact subcommands and flags.

Registration is what creates this home's private transport under `state/public-followup/` (mode 0700): `registry/` for the bounded public-safe binding of each live commitment, `events/` for typed terminal results awaiting reconciliation, `consumed/` for the accepted-event ledger, `rejected/` for refusals kept with a one-line reason, and `surfaced` for the poll's last-surfaced signature.
The home that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Work routed elsewhere reports a typed terminal result with `bin/fm-public-followup-emit.sh` and never looks for the thread; that emitter refuses to write into a home with no registration for the named obligation.
A terminal event's id is derived from its identity tuple, so a duplicate report, a retry, or a replay after restart resolves to the same event and changes nothing.

Activation is the same `.env` `FMX_PAIRING_TOKEN` contract as the rest of X mode, with no second flag.
A home without that token runs one file test and stops: no `tasks-axi` call, no backlog or request-context scan, and no `state/public-followup/` directory.
Ordinary startup, polling, cleanup, and silent read-side subcommands also produce no output; commands that require an active relay report that configuration error after the same gate.
A relay-enabled home with no registered commitment stops at an O(1) directory presence check, so the empty state costs no CLI call and adds no periodic scan.
Unreconciled terminal results ride the existing 30-second relay poll rather than a new process or timer: `bin/fm-x-poll.sh` compares the pending-event signature against `surfaced` and wakes firstmate once per new result set.
The session-start digest separately prints an "Public commitments awaiting delivery" subsection from disk when, and only when, this home is relay-active and still owes a reply, so compaction and restart are non-events.
`bin/fm-teardown.sh` refuses to clean up a task while this home still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.
`FM_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](verification/public-followup.md) for the current maintainer evidence behind the restart end-to-end and the relay-disabled zero-overhead guarantee.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; `bin/fm-procevent-lavish.sh` is the first adapter and wraps only the currently published `lavish-axi poll` interface.

This section is the single owner of the runner's operating contract.
Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before it is published.
Results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a captured result reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
Delivery is reported at most once per captured source and sequence while any records for that key remain queued.
A durable handled acknowledgement stops future re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain consumes it.

Discovery is never a timer.
Each registered source has its own child process blocking on that source, and the watcher's per-cycle `reconcile` republishes every captured result with no durable handled acknowledgement yet - regardless of any earlier publication - restarts a source whose owner is gone, and stops this home's runner when reconciliation runs after its registration disappeared unexpectedly.
In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

Whether a captured result ends its source is adapter knowledge, never the runner's.
After publishing a result the runner calls `bin/fm-procevent-<adapter>.sh terminal <result-file>` and retires the registration on exit 0 alone, dropping only the exact registration generation captured by its claim and releasing that claim only after removal succeeds under one source boundary; a missing command, an error, or any other exit keeps the source armed, so an adapter with no notion of ending needs no change.
A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work, while explicit `retire` stays the supported and idempotent path afterwards.
For Lavish that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.
Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
Each claim binds its home and runner PID to a process identity, unique claim generation, and exact registration-file generation.
Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.
Retirement and orphan reconciliation signal a runner process group only while its recorded process identity still matches, or when the recorded leader is gone and only its own owned group survives.
A runner leads its own process group, so a claim counts as reclaimable only when that whole generation is gone: a crashed leader whose group still has members is not stale, and reconcile stops that surviving group and releases its generation before starting any replacement.
If identity cannot be established for a live PID, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
A live PID whose identity no longer matches is a reused PID, so it is treated as stale and its process group is never signalled.

Supported secondmate retirement preflights each target home's bounded `sweep-home` command before destructive teardown, snapshots its registrations outside the target, then runs the sweep at that home's final deletion or return boundary.
If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
The sweep retires local registrations and machine-wide claims physically owned by that home through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.
Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.
`bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
Wake publication itself is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
The published `lavish-axi poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
Never describe this path as at-least-once, no-loss, or lossless.
`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity, environ, and cwd reads in fm-wake-lib.sh, fm-worktree-guard.sh, and fm-teardown.sh, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support ship/scout spawns, codex-app is not accepted
FM_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_COMPOSER_LINES=20  # herdr-only: tail lines scanned by composer-state guard/fallback paths; idle-baseline submit confirmation uses agent-state
FM_BACKEND_HERDR_IDLE_RE='^Type a message\.\.\.$'  # herdr-only: empty-composer placeholder regex after shared ghost extraction plus border and prompt stripping
FM_BACKEND_HERDR_BARE_PROMPT_RE='^(❯|›)'  # herdr-only: verified agent glyphs recognized as an UNBORDERED (bare) composer row, e.g. Claude's ❯ or Codex's ›; an alternation, not a `[...]` bracket expression, so a C-locale byte-decomposed match can never misfire on an unrelated multibyte glyph; shell glyphs remain unknown rather than empty, and de-emphasised ghost/placeholder text reads empty through shared fm_composer_strip_ghost (docs/herdr-backend.md "Composer and injection safety")
FM_BACKEND_HERDR_PI_COMPOSER_MAX_LINES=8  # herdr-only: maximum rows admitted between Pi's native-identity-corroborated separator pair; taller or ambiguous candidates stay unknown (docs/herdr-backend.md "Composer and injection safety")
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_BACKEND_ORCA_COMPOSER_LINES=200  # orca-only: terminal-read lines scanned to locate the composer row for submit verification
FM_BACKEND_ORCA_IDLE_RE='^Type a message\.\.\.$'  # orca-only: empty-composer placeholder regex after border/prompt stripping
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
FM_BACKEND_CMUX_COMPOSER_LINES=20  # cmux-only: tail lines scanned to locate the composer row for submit verification
FM_BACKEND_CMUX_IDLE_RE='^Type a message\.\.\.$'  # cmux-only: empty-composer placeholder regex after border/prompt stripping
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or X-mode dispatch)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_TEARDOWN_NM_TIMEOUT=10    # seconds allowed per no-mistakes query or abort inside fm-teardown.sh
FM_ATTEST_NM_TIMEOUT=20   # seconds allowed per no-mistakes run-record read inside fm-attest.sh; a read that hits the bound refuses as run-record-unreadable, and a non-positive value falls back to the default because zero disables the deadline rather than shortening it (docs/no-mistakes-attestation.md)
FM_ATTEST_RECHECK_WAIT=180   # seconds fm-attest.sh recheck waits, on this machine and never in CI, for a run already in flight on the head to finish before reporting run-in-progress; 0 is a real value here meaning "do not wait", unlike FM_ATTEST_NM_TIMEOUT above, and anything that is not a non-negative integer falls back to the default (docs/no-mistakes-attestation.md)
FM_ATTEST_RECHECK_POLL=10   # seconds between those re-reads; a non-positive or unusable value falls back to the default because zero would poll GitHub without pause
FM_ATTEST_RECHECK_LOCK_WAIT=10   # seconds fm-attest.sh recheck waits for the shared ledger lock; 0 means fail immediately when it is held, and an unusable value falls back to the default
FM_ATTEST_RECONCILE_WINDOW=60   # seconds the required check re-reads the attestation ref for before reporting a head unattested, and only while no attestation for that head has arrived; measured against this repository's own publication history, so change it against that rather than by feel (docs/no-mistakes-attestation.md); 0 is a real value meaning "look once, do not wait", and an unusable value falls back to the default
FM_ATTEST_RECONCILE_POLL=15   # seconds between those re-reads; a non-positive or unusable value falls back to the default because zero would spin
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed to the current code
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage and the fleet snapshot
FM_BUSY_MAX_BUSY_AGE_SECS=3600  # age after which a BUSY turn record is reported stale instead of live; idle records never expire; distinct from FM_BUSY_TURN_MAX_SECS below, which ages a pane already believed busy and so never arms for a stopped worker
FMX_PAIRING_TOKEN=      # X mode pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional X relay override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct X client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews X replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting X-mode completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on X-mode completion follow-ups per linked mention
FM_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
FM_WAKE_LEDGER=         # alternate wake-outcome ledger path, default data/wake-ledger.tsv (bin/fm-wake-ledger.sh)
FM_PIPELINE_STATE_DB=   # alternate validation-pipeline state database, default ~/.no-mistakes/state.sqlite; read-only, for the invocation-time evidence of which vendor and model reviewed a task, and could-not-observe when it cannot be read (bin/fm-independence-lib.sh)
FM_CERTIFY_ATTEST=      # alternate head-bound attestation verifier, default bin/fm-attest.sh (bin/fm-certify.sh)
FM_CERTIFY_PR_VERIFIER= # alternate pull-request check verifier, default bin/fm-verify.sh (bin/fm-certify.sh)
FM_CERTIFY_LEDGER=      # alternate terminal-record reader, default bin/fm-wake-ledger.sh; read for a task whose task-local state teardown already removed (bin/fm-certify.sh)
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_SPAWN_POOL_LOCK_POLLS=1200   # 0.1s attempts fm-spawn.sh waits for the cross-home worktree pool slot-selection lock before refusing the spawn
FM_SLOT_RESERVATION_LOCK_POLLS=1200   # 0.1s attempts fm-slot-reservation.sh open waits for that same pool slot-selection lock before refusing with could-not-observe (bin/fm-slot-reservation.sh)
FM_POOL_NAMESPACE_DIR=  # alternate root for one worktree pool's machine-private state, default /tmp/firstmate-worktree-pool; it changes where, never whether, since the same this-user mode-700 validation runs against the override (bin/fm-pool-lib.sh)
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded Stop-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for watcher health, a role-verified Stop auto-arm claim, or a fresh epoch before deciding recovery ownership or failure progression
FM_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
FM_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED; default 30 on Git Bash/MSYS
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows to stay above the MSYS confirm budget
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:'   # opt-in custom captain-relevant vocabulary for a home whose crews use their own verbs; setting it replaces the default and reinstates prose matching, which the default classification no longer does at all
FM_CLASSIFY_PAUSED_VERB=paused     # status verb for a declared external wait; never captain-relevant, and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates in the watcher; stale panes whose crew is not provably working surface immediately unless they declare the pause verb; in the away-mode daemon it is the wedge-aging interval instead, where an aged marker escalates only if its crew is not provably working at that point and is otherwise refreshed for another interval
FM_BUSY_TURN_MAX_SECS=3600         # maximum age of a provably-working pane's latest state/<id>.turn-ended marker, or its state/<id>.meta spawn record before any turn completes, before the same wedge escalation takes over; proof may be a busy harness or advancing descendant CPU; inspection-only, never an automatic interrupt or restart
FM_CHILD_CPU_MIN_TICKS=100         # minimum descendant CPU growth between samples that proves work; Linux kernel ticks, normally 100 per CPU-second
FM_CHILD_CPU_MAX_SAMPLE_AGE=120    # maximum age in seconds of a descendant CPU baseline eligible for comparison
FM_CHILD_CPU_SAMPLE_INTERVAL=5     # minimum age in seconds before replacing a descendant CPU baseline, so repeated probes in one watcher cycle compare against the same sample
FM_PAUSE_RESURFACE_SECS=3600       # seconds between re-evaluations of an idle declared external wait in the watcher or away-mode daemon, and therefore the bound on how late a blocker's movement can be noticed; the away-mode daemon skips the recheck entirely for a wait the backlog records as captain-gated, because only the captain can clear it
FM_BLOCKER_MAX_DEPTH=32            # how many blocked-by links the dependency cycle check follows before it stops; a chain that runs past this was not enumerated, so it is could-not-observe and the wait surfaces naming the bound (bin/fm-blocker-lib.sh)
FM_BLOCKER_MAX_NODES=256           # how many blocker records that same check may read in one evaluation, on the same could-not-observe terms
FM_PR_DIRTY_RESURFACE_SECS=3600    # seconds before a monitored pull request still conflicting at the same head commit re-surfaces; a changed head is a new conflict and wakes immediately
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after ghost and border stripping
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, shared by the tmux and herdr composer readers)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
FM_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_STALE_WORKING_GATE_READS=3      # max provably-working crew-state reads one housekeeping pass may make before aged wedge markers escalate; a marker past the budget stays aged for the next pass, so the budget delays an escalation and never suppresses one; unset, blank, or not a nonnegative integer uses the default of 3, and an invalid value is logged to the daemon log rather than applied silently - on first sight, again whenever the supplied value changes, and otherwise at most hourly so a standing typo cannot crowd the log's retained window; 0 floors to 1
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
