# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent hook-nudge use; `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print the read-only structured fleet snapshot JSON (schema `fm-fleet-snapshot.v1`)   |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the fleet snapshot to the compact TOON bearings view; local-only unless `--include-prs` |
| `fm-admission.sh`        | Decide the task-independent fleet admission band from a fresh census, with the exact per-rule explanation |
| `fm-admission-lib.sh`    | Shared fleet-admission policy reader and `_scheduling.admission_control` schema validator |
| `fm-decision-surface.sh` | Compose the read-only operational decision surface, including the compiled landing-authority verdict, and refuse a claim structured state contradicts |
| `fm-dead-predicate-check.sh` | Refuse enrolled shell files containing functions with no repository-wide call site, and report unevaluable syntax or enrollment |
| `fm-outbound-artifact-lib.sh` | Own the outbound-artifact invariant, gate vocabulary, identity rule, recognizer, and correlation-record shape |
| `fm-outbound-artifact.sh` | Compile waiting-item requests, typed rulings, correction, authorization-bound closure, and disposition |
| `fm-outbound-seam-proof.sh` | Exercise the typed outbound return path through a real fast-forward on a throwaway repository |
| `fm-certify.sh`          | Derive whether the applicable certification predicates hold for a task's exact bytes |
| `fm-independence-lib.sh` | Derive verifier identity and independence from validation-pipeline invocation records |
| `fm-update.sh`           | Fast-forward-only self-update of firstmate and local or remote secondmate homes       |
| `fm-on.sh`               | Execute one tracked Firstmate command in a configured remote secondmate home, using its job worker except for the doctor bootstrap |
| `fm-remote-job-lib.sh`   | Shared bounded remote job queue, worker readiness, LaunchAgent contract, and filesystem-composed PATH |
| `fm-remote-job-worker.sh` | Long-lived remote queue worker for tracked `fm-*.sh` commands in the account runtime |
| `fm-remote-doctor.sh`    | Check, and with `--fix` repair, one remote account's second-mate readiness (remote job worker, Herdr, Aqua launch agents, PATH, and required tools) |
| `fm-backlog-handoff.sh`  | Validate and delegate queued backlog-item moves into a secondmate home               |
| `fm-backlog-receive.sh`  | Idempotently ingest one confined remote handoff outbox through tasks-axi             |
| `fm-decision-hold.sh`    | Create, verify, complete, dispose, and resolve durable captain-held decisions        |
| `fm-ruling-reconcile.sh` | Match open captain decision holds against the ruling documents that name them, and apply the captain's two-condition closure test without ever closing a hold |
| `fm-commitment-register.sh` | Compute every recorded commitment's state from its own probes, and gate a keyed decision's closure on the probe pinned into its decision file |
| `fm-brief.sh`            | Scaffold ship (explicit `--mode`), scout, secondmate-charter, and Herdr-lab briefs   |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `fm-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `fm-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `fm-lab-*` sessions in the Herdr CI lane       |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, proven-isolated `--jobs`, coverage guard, timing/JSON |
| `fm-test-isolation-proof.sh` | Concurrent isolation proof harness: measures the candidate set it owns and records the proven set into `docs/fm-test-isolation-proof.json` |
| `fm-test-isolation-lib.sh` | Single owner of the isolation measurement contract and the proof freshness model: what a proof binds to and when it has gone stale |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` symlink, and the canonical self-governance section |
| `fm-attest.sh`           | Emit and verify the head-bound no-mistakes attestation the `Require no-mistakes` check reads (docs/no-mistakes-attestation.md) |
| `fm-guard.sh`            | Warn on primary-checkout tangles, pending queued wakes, and unhealthy supervision    |
| `fm-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `fm-session-lock-lib.sh` | Shared session-lock harness identity (ancestry walk and holder liveness) for fm-lock.sh and the Claude Stop auto-arm |
| `fm-claude-stop-autoarm.sh` | Claude Stop `asyncRewake` hook owning tokenless watcher continuity with single-flight exit-2 rewake (docs/watcher-continuity.md) |
| `fm-context-statusline.sh` | Render Claude's host-computed context pressure and optional task snapshot with the 70-percent compaction advisory |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-kimi-turnend-hook.sh` | Surgically install or remove Kimi's guarded global crew turn-end hook                |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a local secondmate home and maintain `data/secondmates.md` |
| `fm-remote-home-seed.sh` | Register and provision a whole secondmate home on an SSH-reachable host              |
| `fm-remote-readiness-lib.sh` | Shared remote second-mate readiness gate: check and, when needed, repair then re-check through `fm-remote-doctor.sh` |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-worktree-guard.sh`   | Choose the demonstrably empty Treehouse slot a spawn may use, refuse when no available slot is one, and publish who apparently owns an occupied one |
| `fm-pool-lib.sh`         | Single owner of where one worktree pool's machine-private state lives and of the key naming that pool |
| `fm-slot-reservation.sh` | Reserve a pool's next free slot for one queued trunk repair, and read, claim or release that slot reservation |
| `fm-slot-reservation-lib.sh` | Single owner of the slot-reservation record, what may open one, and how its state is computed on read |
| `fm-launch-lib.sh`       | Single owner of every verified harness launch command for crewmate, scout, secondmate, and primary sessions |
| `fm-launch.sh`           | The captain's front door: probe the harness menu, then start and attach to one primary session in this home (docs/launcher.md) |
| `fm-wsl-entry.sh`        | Enter the fleet launcher deterministically from the repository-root Windows batch bridge |
| `fm-unattended-session.sh` | Own the queued-trigger-to-session-start path and the durable record that makes such a session attributable (docs/configuration.md) |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer-content classification for all backends          |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inherited local material to live local or remote secondmates and send the placement-specific config reread when changed |
| `fm-project-mode.sh`     | Resolve a project's registered delivery and autonomy posture from `data/projects.md`, with optional source attribution |
| `fm-merge-local.sh`      | Compile landing authority and guardedly fast-forward a `local-only` project's local default branch |
| `fm-review-diff.sh`      | Review a crewmate branch or resolved PR head against the authoritative base          |
| `fm-review-exec.sh`      | Launch and capture a reviewer in a disposable pinned clone, and own that review's execution evidence ([verification](verification/review-execution-evidence.md)) |
| `fm-review-mutation.sh`  | Prove from execution, not from a label, that a named target assertion ran and what it concluded ([verification](verification/review-mutation-proof.md)) |
| `fm-research-scan.sh`    | Model-free prefilter over `data/**/report.md` plus the separate approval, implementation, and delivery evidence provers |
| `fm-attribution-sweep.sh` | Read-only sweep listing GitHub writes under the captain's account that lack the model-write attribution token ([convention](model-write-attribution.md)) |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and one-shot escalation |
| `fm-secondmate-report.sh` | Optional helper to append a correlated parent status or document-pointer report       |
| `fm-procevent-remote-reply.sh` | Relay non-destructive correlated remote-secondmate reply deltas through process events |
| `fm-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe always-on watcher: absorb benign wakes, queue and exit on actionable ones |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away-mode entry, exit, rollback, and any backend terminal lifecycle                 |
| `fm-afk-return.sh`       | Own deterministic return shutdown, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, guard injection by the detected primary harness, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew (`--json` for typed fields)    |
| `fm-nm-run-lib.sh`       | Shared bounded reading and branch-and-code-identity attribution of no-mistakes run records |
| `fm-timeout-lib.sh`      | Single owner of hard-bounded command execution and its fallback watchdog |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-verify.sh`           | Run one declared verifier and return `PASS`, `FAIL`, or `NO_VERIFIER_RAN`, with exit 0 reserved for `PASS` alone |
| `fm-verify-lib.sh`       | Single owner of the three-valued observation type, its consumer and coercion rules, and the one fold answering "is this exact head green?" |
| `fm-wrong-subject.sh`    | Render and form-check a wrong-subject finding, naming the claim a check establishes beside the claim its verdict is credited with |
| `fm-control-read.sh`     | The retrieval contract for a control-plane read: enumerate the whole collection, prove it, and refuse a negative conclusion it cannot support |
| `fm-retrieval-lib.sh`    | Single owner of the remote-collection retrieval type: page traversal, continuation, deduplication by remote identity, bounded retry, completeness state, provenance, and the conclusion algebra |
| `fm-retrieval-check.sh`  | Reject a new load-bearing pagination-sensitive direct read, and print the classified audit census of every candidate site |
| `fm-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and local secondmate syncs       |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-landed-lib.sh`       | Shared "has this content already landed?" containment test, default-branch name, push-remote landing target, and landing-target candidate refs |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-quota-axi-lib.sh`    | Shared `quota-axi` compatibility floor and bounded JSON reader for bootstrap and capacity routing |
| `fm-vendor-auth-probe.sh`| Run one hard-bounded, non-destructive authentication probe of a named vendor CLI and report the fact |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes, emit bounded best-effort status-event annotations and a fleet-wide OPEN DECISIONS section, record the ledger's wake half, then assert supervision health |
| `fm-wake-ledger.sh`      | Own the append-only wake-outcome and terminal-task evidence record, and summarize it |
| `fm-wake-lib.sh`         | Shared durable wake queue, portable locks, and watcher identity/health helpers       |
| `fm-classify-lib.sh`     | Shared wake-classification vocabulary, the crew-state verdict set every consumer must handle, and durable keyed-decision folds and scans |
| `fm-blocker-lib.sh`      | Detect blocker movement for dependency-driven pause re-evaluation and maintain its durable baseline |
| `fm-status-event-lib.sh` | Single owner of the `fm-status-event.v1` typed status-event wire format and its only parser |
| `fm-task-axis-lib.sh`    | Single owner of a task's role, deliverable, and stage axes, their derivation, and the stale-writer refusal |
| `fm-autonomy-lib.sh`     | Single owner of the task autonomy-state (`yolo=`) vocabulary, producer validation, comparison, and effective-posture resolution |
| `fm-send.sh`             | Send one verified literal line or supported key through the target's recorded backend |
| `fm-busy-lib.sh`         | Single owner of the semantic busy-state contract: verdicts, source attribution, and per-harness sources |
| `fm-busy-event.sh`       | The only writer of a task's semantic busy-state record; arms an incarnation and applies lifecycle events |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for composer capture, verified submit, and the submit-time busy check |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-model-registry-lib.sh` | Parse and validate the model registry and own the zero-budget and concurrency routing decisions |
| `fm-model-verify.sh`     | Live entitlement probes and local price-drift checks for routed models              |
| `fm-route.sh`            | Read a route's floor, pool, eligible candidates and same-pool failover substitute, and record model or provider availability holds |
| `fm-route-lib.sh`        | Own the routed-pool, capability-floor and availability rules every route decision applies |
| `fm-capacity-lib.sh`     | Map current `quota-axi` evidence to three-valued routed-model capacity without changing the capability floor |
| `fm-capacity-retry.sh`   | Persist, back off, inspect and automatically resume dispatches deferred for provider capacity |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-sssf-planning-awareness.sh` | Gated custom check consuming typed SSSF planning transitions as awareness or intake eligibility, never task creation |
| `fm-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll publication and identity-bound retirement |
| `fm-pr-poll.sh`          | Provide the byte-static watcher program reporting merged and conflicted PR/MR-poll sidecars |
| `fm-pr-check-migrate.sh` | Quarantine older task polls without execution and rebuild only canonical polls       |
| `fm-pr-check.sh`         | Record validated PR identity in live meta or a landing record, then atomically arm a static PR poll |
| `fm-pr-merge.sh`         | Forge-verify landing identity, re-verify a PR's current head, then merge a task's canonical full GitHub URL |
| `fm-landing-authorization.sh` | Mint a one-use landing authorization carrying a typed effect plan from a ruled Browser Sol request, and perform that plan's own act exactly once against the exact head it names |
| `fm-landing-authorization-lib.sh` | Shared landing, candidate-publication, custody-replication and attestation-evidence authorization identity, state vocabulary, typed effect-plan contract, and pure mint and spend predicates |
| `fm-landing-seam-lib.sh` | Single owner of compiled landing authority, Browser Sol governance applicability, and the one-use authorization spend |
| `fm-publication-guard.sh` | Compile the eligibility verdict and effect class for one exact remote-changing act, mint the one-use authority it must spend, run the effect inside that spend, and project candidate state where applicable |
| `fm-publication-seam-lib.sh` | Single owner of whether a guarded candidate or attestation-evidence publication may proceed, and the only wiring FirstMate's own publication paths reach it through |
| `fm-rebase-equivalence.sh` | Diagnostic: report whether a rebase dropped content a pipeline validated, naming the losing paths |
| `fm-reflag.sh`           | Reflag a scout task in place as a protected ship task with an explicit delivery mode |
| `fm-attempt.sh`          | Own a task's durable work-attempt count and retry budget, its execution-attempt lineage, and the gate that sanctions replacing one execution attempt in the same lane |
| `fm-teardown.sh`         | Fail-closed teardown: return ship worktrees whose work is published or landed, require completed scout deliverables, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness and resolve crew or secondmate harness, model, and effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared X-mode config, relay, and reply-threading helpers                             |
| `fm-x-poll.sh`           | One bounded X relay poll: stash newly offered mentions and emit their once-only wake |
| `fm-x-reply.sh`          | Post or dry-run preview a composed X-mode reply or follow-up                         |
| `fm-x-dismiss.sh`        | Dismiss a skipped X-mode mention at the relay without replying                       |
| `fm-x-link.sh`           | Link a spawned task to its originating X-mode mention in task meta                   |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for an X-mode-linked task                |
| `fm-public-followup-lib.sh` | Shared relay-activation gate, O(1) presence checks, and private transport paths for promised public replies |
| `fm-public-followup.sh`  | Reconcile typed terminal work results into a public commitment and deliver its final reply once |
| `fm-public-followup-emit.sh` | Report one typed terminal work result into the home that owes the public reply    |
