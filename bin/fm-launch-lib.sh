#!/usr/bin/env bash
# fm-launch-lib.sh - the single owner of firstmate's verified launch commands.
#
# Every firstmate-launched agent session composes its command from exactly these
# three functions. There is no second copy anywhere, and a caller must never
# hand-write a launch string: the drift that causes is not hypothetical. A
# downstream registry once hand-copied claude's command as
# `claude --dangerously-skip-permissions`, dropping the ghost-text suppression
# variable documented in launch_template() below - the exact omission that makes
# firstmate read predicted-prompt text as real typed input when it captures a
# pane. One owner, or that happens again.
#
# Sourced by bin/fm-spawn.sh (crewmate, scout, and secondmate sessions).
#
#   launch_template <harness> [<kind>]      the verified launch command, with
#                                           placeholders the caller substitutes
#   model_flag_for_harness <harness> <model>    resolved --model flag, or empty
#   effort_flag_for_harness <harness> <effort>  resolved effort flag, or empty
#
# The knowledge half of each adapter (busy-state source, exit command, dialogs,
# quirks) lives in the harness-adapters skill, not here.
#
# shell_quote lives here because both flag resolvers depend on it; sourcing this
# library is what makes it available to bin/fm-spawn.sh.

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# The verified launch command per adapter, as a template. A non-zero return has
# two distinct causes, and a caller reporting the refusal must tell them apart:
#   1. the harness has no verified adapter at all - the unverified-adapter guard
#      every caller relies on, whose remedy is a raw launch command;
#   2. the harness is verified but this kind is deliberately unsupported for it -
#      today only kimi with kind=primary, whose remedy is a different harness,
#      NOT the raw-launch escape hatch.
# Never add a permissive default arm to either case. bin/fm-spawn.sh:466 and :470
# name only cause 1 because fm-spawn never passes kind=primary; a consumer that
# does pass it owes the user the cause-2 wording.
#
# kind selects the session shape:
#   ship|scout   a crewmate working one task in an isolated worktree
#   secondmate   a firstmate PRIMARY launched in a provisioned secondmate home
#   primary      a firstmate PRIMARY launched in this home by the fleet launcher
#
# ship, scout, and secondmate all receive a launch brief, so their templates end
# in the encoded brief argument. A primary has no task, no worktree, no brief,
# and no status file, so it launches bare and is greeted by the session-start
# adapters already installed in the home (for pi and opencode those are the
# project-local extensions the harness auto-discovers once trusted, which is why
# a primary needs no explicit extension flag). A primary template therefore
# carries only its flag placeholders plus whatever briefless-launch flag that
# adapter was verified to need, and an unset flag leaves one trailing space; that
# is cosmetic in a shell command, and consumers may trim it.
#
# Placeholders every caller substitutes before launch:
#   __MODELFLAG__  model_flag_for_harness output, or empty (see below)
#   __EFFORTFLAG__ effort_flag_for_harness output, or empty (see below)
#   __KIMIBIN__    shell-quoted absolute path to the resolved kimi binary
# Placeholders only a task-scoped (ship|scout|secondmate) launch substitutes:
#   __BRIEF__     absolute path to data/<task-id>/brief.md
#   __TURNEND__   absolute path to state/<task-id>.turn-ended (for harnesses whose
#                 turn-end signal rides the launch command, e.g. codex -c notify=[...])
#   __PIEXT__     absolute path to state/<task-id>.pi-ext.ts (pi turn-end extension,
#                 written by fm-spawn.sh; outside the worktree to avoid pi's trust gate)
#   __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#   __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#   __OPINPUT__   absolute path to the canonical operational-input encoder
#
# __KIMIBIN__ is resolved by bin/fm-spawn.sh alone, deliberately: the fleet
# launcher reaches Kimi through the pi harness rather than a native kimi binary,
# so there is no second caller to drift from.
# Revisit that only if a native kimi launch ever becomes a launcher entry.
# That same reasoning is why kimi has no primary arm: only bin/fm-spawn.sh can
# substitute __KIMIBIN__, and it only ever launches crewmates, so a primary kimi
# template could not be substituted by the caller that would ask for it.
#
# No primary template below is the crewmate command with its brief argument
# subtracted; each arm cites the specific in-repo evidence that fixes its flags,
# and tests/fm-launch-lib.test.sh pins each one against those same citations.
# The evidence is not uniform, and each arm says which kind it rests on: opencode
# and grok are pinned to an empirical briefless PRIMARY launch in a live e2e test,
# pi to the documented bare launch, and claude and codex to the secondmate
# precedent - this file's own `secondmate` kind is a firstmate PRIMARY (see the
# kind list above), and its shipped crewmate templates - the claude arm and the
# codex `kind = secondmate` arm in the second case block below - launch that
# interactive primary with exactly the autonomy flags those two arms carry.
#
# CONSUMER OBLIGATION (binding, not advisory). The rule, which governs whatever
# the templates below happen to say: EVERY primary template here starts a session
# that runs without permission prompts, and a consumer composing a primary launch
# MUST surface that to the captain at launch time. One short line at launch or in
# the menu row is enough. The captain is entitled to know the posture of the
# session their front door starts. There are no exempt adapters. The rule binds on
# the posture, not on the presence of a particular flag, so a consumer cannot
# satisfy the letter of this note while silently shipping a no-prompt session.
#
# All six reach that posture, claude by ENFORCED refusal, three by an explicit
# bypass, and the pi family structurally:
#   claude    --permission-mode dontAsk plus the generated allow rules, both
#             composed by the canonical-posture block below. claude is the one
#             adapter here whose no-prompt posture is NOT a bypass: its
#             permission rules still decide, and an action they do not allow is
#             REFUSED with a typed message instead of asked. A bypass would be
#             strictly WORSE for an unattended worker, because
#             --dangerously-skip-permissions does not suppress claude's
#             bypassImmune circuit breakers - a bypassed worker still stops on an
#             ask that no permission rule is allowed to answer. See the canonical
#             posture block below for the measured evidence.
#   codex     --dangerously-bypass-approvals-and-sandbox
#   opencode  OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}', which
#             pre-allows every permission before the TUI starts
#   grok      --always-approve, which .agents/skills/harness-adapters/SKILL.md:314
#             records as auto-approving every tool execution, verified to run
#             fully unattended and equivalent to --permission-mode bypassPermissions
#   pi        (and pi-signed, which shares its arm) no flag, because none exists
#             to pass: SKILL.md:277 records that pi has no permission system at
#             all, so a pi session is autonomous by construction. Its template -
#             the bare selected binary plus the FM_PI_HARNESS identity marker,
#             which changes no permission posture - is complete, NOT missing an
#             autonomy flag its siblings carry - do not add one.
# Pi's first-run project trust dialog (SKILL.md:286) is folder trust, not a
# permission prompt, and is a separate concern that neither satisfies nor softens
# this obligation.
#
# launch_permission_posture publishes that same list as a value a caller can act
# on, so the obligation above stops being prose only. It exists because a
# commitment about the permission posture of launched agents needs a probe that
# reads THIS file's own decision rather than grepping for a vendor flag string:
# a grep would go quietly vacuous the day an adapter renames its flag, which is
# the exact shape of failure the commitment register was built to refuse.
# It is not a harness-dependent check in the sense the firstmate-coding-guidelines
# skill governs: it reports a posture this repo chose and encoded in the
# templates below, and reads no vendor process, output, or rendered surface.
#
# The ROSTER it walks is derived, never hand-maintained. A second copy of the
# adapter list would go vacuous the day an adapter is ADDED rather than renamed -
# the same failure one step over, and a hand-maintained literal inside the very
# accessor that exists to stop hand-maintaining state. launch_harnesses reads the
# case arms launch_template itself dispatches on, so an adapter that can be
# launched is in the roster by construction.

# Every harness launch_template can compose a command for, one per line, read out
# of that function's own case arms. A candidate is only accepted once
# launch_template actually answers for it, so a pattern that merely looks like an
# arm ("*", "primary", a stray line ending in a parenthesis) cannot enter the
# roster. A non-zero return means the roster could not be derived at all, which
# every consumer must treat as could-not-observe rather than as an empty fleet.
#
# launch_template's OWN ANSWER is the only filter, deliberately. An earlier version
# also required each arm to be a plain alternation of lower-case literals and
# silently skipped anything else, which reintroduced the failure this derivation
# exists to prevent one step over: an adapter written as `Kimi)` or `kimi|kimi-*)`
# would vanish from the roster entirely, and once the recorded adapters flip to
# enforced the permission probe would find nothing unrestricted and nothing
# unknown and PASS over a harness that is still launchable. So every token of
# every arm is offered to launch_template, and one it answers for is a member -
# with posture unknown until someone records one, which is could-not-observe
# rather than silent exclusion. One it refuses ("*", "primary", "secondmate") is
# not an adapter and was never a roster member to lose.
launch_harnesses() {
  local decl line arm rest tok out='' seen=' '
  decl=$(declare -f launch_template 2>/dev/null) || return 1
  [ -n "$decl" ] || return 1
  while IFS= read -r line; do
    case "$line" in *')') ;; *) continue ;; esac
    arm=${line%)}
    arm=${arm#"${arm%%[![:space:]]*}"}
    arm=${arm%"${arm##*[![:space:]]}"}
    [ -n "$arm" ] || continue
    rest=$arm
    while [ -n "$rest" ]; do
      case "$rest" in
        *'|'*) tok=${rest%%'|'*}; rest=${rest#*'|'} ;;
        *) tok=$rest; rest='' ;;
      esac
      tok=${tok#"${tok%%[![:space:]]*}"}
      tok=${tok%"${tok##*[![:space:]]}"}
      [ -n "$tok" ] || continue
      case "$seen" in *" $tok "*) continue ;; esac
      launch_template "$tok" >/dev/null 2>&1 || continue
      seen="$seen$tok "
      out="$out$tok"$'\n'
    done
  done <<EOF
$decl
EOF
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# The postures this repo has actually RECORDED, and nothing else. A harness absent
# from here is not excluded and is never called enforced: launch_permission_posture
# reports it unknown, which is the honest third value.
#
# kimi is the standing example. The CONSUMER OBLIGATION above accounts for six
# adapters and kimi is not one of them: no record in this repo or in
# .agents/skills/harness-adapters/SKILL.md states what `--auto` does to kimi's
# permission gate. An unverified posture reading as protection is the failure this
# accessor was added to make impossible, and that holds for the next adapter added
# to launch_template exactly as it holds for kimi.
launch_permission_recorded() {  # <harness> -> recorded posture, or non-zero
  case "$1" in
    # claude is the one adapter whose launch keeps permission enforcement ON.
    # The canonical-posture block below composes its rules, and its no-prompt
    # guarantee comes from REFUSAL rather than from a bypass, so calling it
    # unrestricted would misreport a session whose rules genuinely decide.
    claude) printf 'enforced' ;;
    # The three remaining explicit bypasses and the two structurally-autonomous
    # pi arms, exactly as the CONSUMER OBLIGATION above enumerates them.
    codex|opencode|grok|pi|pi-signed) printf 'unrestricted' ;;
    *) return 1 ;;
  esac
}

# --------------------------------------------------------------------------
# THE CANONICAL CLAUDE NO-PROMPT POSTURE, and the preflight that enforces it.
#
# An unattended claude worker must never be able to reach an interactive
# permission gate, because nobody is at its pane to answer one: the task simply
# stops, and supervision sees a healthy-looking idle pane rather than a refusal.
#
# The naive fix - --dangerously-skip-permissions - does NOT achieve this, and
# that is the whole reason this block exists. Claude Code carries permission
# circuit breakers flagged bypassImmune, whose ask a bypass does not suppress and
# which, in the CLI's own words, "cannot be auto-allowed by permission rules".
# Measured on the installed Claude Code 2.1.246 (2026-08-26,
# docs/verification/claude-permission-posture.md): the breaker registry is
# dangerousRemoval{bypassImmune:true}, isolatePeerMachines{bypassImmune:true},
# backgroundOperator{bypassImmune:false}, suspiciousWindowsPath{bypassImmune:false}.
# Under --dangerously-skip-permissions a triggering command still produced an
# approval request; under the posture below the SAME command produced a typed
# denial and no request at all. That measured pair is the evidence, and the
# live-harness guard named in that record is what refreshes it.
#
# The posture has two halves and needs BOTH:
#   - the mode, which makes an un-allowed action a refusal instead of an ask;
#   - the allow rules, without which the mode denies ordinary work too. Measured
#     on 2.1.246: the mode alone denied an ordinary shell write, so a worker
#     launched with the mode and no rules is not unattended, it is inert.
#
# One owner, three carriers. The launch flags below, the per-task settings file
# bin/fm-spawn.sh generates, and the preflight all read THESE functions, so the
# posture cannot be changed in one carrier and silently left stale in another.
launch_claude_permission_mode() { printf '%s' 'dontAsk'; }

# The tools a firstmate worker needs to do its job, and nothing else. This is one
# fleet-wide generated posture: it is never specialized per task, because a
# task-local rule is exactly the ad hoc approval the captain's standing
# instruction refuses. Agent-shaped tool names are deliberately absent, leaving
# the existing subagent guard as the owner of that refusal.
launch_claude_permission_allow() {
  printf '%s\n' Bash Read Edit Write MultiEdit Glob Grep WebFetch WebSearch
}

# The permissions OBJECT, which is what a settings file holds under its own
# "permissions" key. Bare tool names are the rule syntax measured to work on
# 2.1.246; "Bash(*)" was measured to work too, and the bare form is kept because
# it is the narrower claim.
launch_claude_permissions_json() {
  local rule out=''
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    out="$out,\"$rule\""
  done <<EOF
$(launch_claude_permission_allow)
EOF
  printf '{"allow":[%s],"defaultMode":"%s"}' "${out#,}" "$(launch_claude_permission_mode)"
}

# The whole settings DOCUMENT, which is what --settings takes. The wrapper is not
# cosmetic and the two shapes are not interchangeable: a --settings value handed
# the bare permissions object carries no rules claude recognises, so the mode
# denies ordinary work and the worker is inert - refusing everything, which reads
# like a working no-prompt posture until someone checks that the worker can still
# do its job. tests/fm-claude-permission-posture-live-e2e.test.sh checks exactly
# that, against the real harness, which is how this distinction was found.
launch_claude_settings_json() {
  printf '{"permissions":%s}' "$(launch_claude_permissions_json)"
}

# The flags a claude launch command carries. The JSON contains no single quote
# and no space, so single-quoting it is complete.
launch_claude_permission_flags() {
  printf -- "--permission-mode %s --settings '%s'" \
    "$(launch_claude_permission_mode)" "$(launch_claude_settings_json)"
}

# The refusal itself. Deliberately a REFUSAL and not a warning: a launch that
# could reach a permission gate must not produce a worker at all, because a
# worker that stops on an unanswerable ask consumes a slot and reports nothing.
# Every refusal names the offending token, so the remedy is never a guess.
launch_claude_posture_refuse() {  # <label> <reason>
  printf 'error: FM_CLAUDE_PROMPT_POSTURE: %s %s\n' "$1" "$2" >&2
  printf '  the canonical posture is: %s\n' "$(launch_claude_permission_flags)" >&2
  return 1
}

# Strip one layer of surrounding single or double quotes from a token, so a
# quoted flag VALUE compares against the unquoted canonical form.
launch_unquote_token() {
  local t=$1
  case "$t" in
    "'"*"'") t=${t#\'}; t=${t%\'} ;;
    '"'*'"') t=${t#\"}; t=${t%\"} ;;
  esac
  printf '%s' "$t"
}

# The watched-red. Answers one question about an EFFECTIVE claude launch command:
# could this session reach an interactive permission gate? A non-zero return
# means it could, or that this function could not establish that it could not -
# those are the same answer here, because an unestablished posture must never
# read as a safe one.
#
# It is deliberately allow-list shaped. It does not hunt for known-bad flags and
# pass everything else; it requires the exact canonical posture and refuses
# anything that adds to, replaces, or contradicts it. A launch command is a small
# closed thing, so demanding the exact posture costs nothing and cannot go
# vacuous the day a vendor adds a new way to reach a prompt.
launch_claude_posture_preflight() {  # <launch-command> [<label>] -> 0, or 1 refusing
  local cmd=$1 label=${2:-launch command} w prev='' val
  local mode_seen='' settings_seen=0 settings_val='' want_mode want_settings
  local -a words=()
  want_mode=$(launch_claude_permission_mode)
  want_settings=$(launch_claude_settings_json)
  # read -ra splits on IFS without globbing and without quote removal, so a token
  # keeps the quotes the shell would later strip; launch_unquote_token undoes
  # exactly one layer when a value is compared.
  #
  # Newlines are flattened to spaces FIRST, because `read` stops at the first one:
  # without this a second line would be invisible to every check below while the
  # shell still ran it, which is a guard that can be stepped over rather than a
  # guard. A command separator becomes ordinary whitespace here, which is exactly
  # right - this function reads tokens, never structure.
  read -ra words <<<"${cmd//$'\n'/ }"
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in
      --dangerously-skip-permissions|--allow-dangerously-skip-permissions)
        launch_claude_posture_refuse "$label" \
          "carries the bypass flag '$w'. A bypass does not suppress claude's bypassImmune circuit breakers, so an unattended worker launched this way can still stop on an ask nothing may auto-approve."
        return 1 ;;
      --permission-prompt-tool|--permission-prompt-tool=*)
        launch_claude_posture_refuse "$label" \
          "carries '$w', which routes permission asks to a prompt tool instead of refusing them."
        return 1 ;;
      --permission-mode=*)
        val=$(launch_unquote_token "${w#--permission-mode=}")
        mode_seen=$val ;;
      --settings=*)
        settings_seen=$((settings_seen + 1))
        settings_val=$(launch_unquote_token "${w#--settings=}") ;;
      *)
        case "$prev" in
          --permission-mode) mode_seen=$(launch_unquote_token "$w") ;;
          --settings) settings_seen=$((settings_seen + 1)); settings_val=$(launch_unquote_token "$w") ;;
        esac ;;
    esac
    # A broad removal has no business in a launch command, and the shapes that
    # reach a bypassImmune breaker are exactly this class, so a launch carrying
    # one is a posture defect rather than something to approve. Matched on the
    # token's basename so an ordinary word that merely contains "rm" is not one.
    case "${w##*/}" in
      rm|rmdir)
        launch_claude_posture_refuse "$label" \
          "invokes '${w##*/}'. A launch command never removes anything, and a broad removal is the shape that reaches a bypassImmune circuit breaker."
        return 1 ;;
    esac
    prev=$w
  done
  if [ -z "$mode_seen" ]; then
    launch_claude_posture_refuse "$label" \
      "carries no --permission-mode, so an un-allowed action would be ASKED rather than refused."
    return 1
  fi
  if [ "$mode_seen" != "$want_mode" ]; then
    launch_claude_posture_refuse "$label" \
      "carries --permission-mode '$mode_seen', which is not the canonical '$want_mode'."
    return 1
  fi
  if [ "$settings_seen" -eq 0 ]; then
    launch_claude_posture_refuse "$label" \
      "carries no --settings, so --permission-mode $want_mode would deny ordinary work and the worker would be inert rather than unattended."
    return 1
  fi
  if [ "$settings_seen" -gt 1 ]; then
    launch_claude_posture_refuse "$label" \
      "carries $settings_seen --settings flags, so which permission rules actually apply could not be established."
    return 1
  fi
  if [ "$settings_val" != "$want_settings" ]; then
    launch_claude_posture_refuse "$label" \
      "carries a --settings value that is not the canonical generated posture: $settings_val"
    return 1
  fi
  return 0
}

launch_permission_posture() {  # [<harness>] -> "<posture>" | "<harness> <posture>" lines
  local harness=${1:-} h
  if [ -z "$harness" ]; then
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      printf '%s %s\n' "$h" "$(launch_permission_posture "$h")"
    done <<EOF
$(launch_harnesses)
EOF
    return 0
  fi
  # A harness launch_template refuses is not an adapter at all, so it has no
  # posture to report; that refusal is distinct from a launchable adapter whose
  # posture nobody recorded, which is unknown.
  launch_template "$harness" >/dev/null 2>&1 || return 1
  launch_permission_recorded "$harness" || printf 'unknown'
}

launch_template() {
  local harness=$1 kind=${2:-ship}
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$kind" in
    primary)
      case "$harness" in
        # The ghost-text suppression prefix is firstmate-required on every claude
        # launch, primary included (see the crewmate arm below for why).
        # The permission flags come from launch_claude_permission_flags, the single
        # owner above, so a primary and a crewmate cannot drift apart. The
        # supervision contract is what fixes them: a firstmate stalled on a
        # permission prompt cannot drain its wake queue or arm its own watcher, and
        # the measured evidence in that block is that a BYPASS does not deliver
        # that guarantee while this posture does. A primary carries the flags on its
        # argv rather than in a settings file because the launcher writes no
        # per-session settings for it. See the CONSUMER OBLIGATION in the header:
        # a consumer must tell the captain this session has no permission prompts.
        claude) printf '%s%s' \
          "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude $(launch_claude_permission_flags) " \
          '__MODELFLAG____EFFORTFLAG__' ;;
        # --dangerously-bypass-approvals-and-sandbox rests on the same secondmate
        # precedent: the codex `kind = secondmate` arm in the crewmate case block
        # below is the SECONDMATE template, and it launches an
        # interactive firstmate primary with exactly this flag. The same status-quo
        # and supervision-contract reasoning as the claude arm applies. It is worth
        # recording what is NOT the evidence here:
        # tests/fm-codex-continuity-live-e2e.test.sh:40 runs `codex exec`, headless,
        # so it says nothing about the interactive primary TUI shape. The header's
        # CONSUMER OBLIGATION covers this arm too.
        codex) printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox' ;;
        # --prompt carries the crewmate's brief, so it has no place in a briefless
        # primary; --auto is the empirically verified briefless form (a primary
        # opencode TUI is launched that way in
        # tests/fm-opencode-primary-live-e2e.test.sh:256 and :310). The
        # OPENCODE_CONFIG_CONTENT JSON pre-allows every permission, so the header's
        # CONSUMER OBLIGATION covers this arm too.
        opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--auto' ;;
        # Bare `pi` is the documented primary launch (README.md:102); the project
        # trust prompt approved once per clone is what makes the tracked
        # .pi/extensions/*.ts auto-load (README.md:108), so a primary needs no
        # explicit -e flag. tests/fm-pi-primary-live-e2e.test.sh:266 adds
        # --approve --no-session --no-context-files --no-extensions with explicit
        # -e paths, but those are that test's isolation scaffolding - it runs
        # against a throwaway clone - not the verified primary form, so they are
        # deliberately not copied here. This template carries no autonomy flag
        # because pi has none to carry: SKILL.md:277 records that pi has no
        # permission system, so the session is autonomous by construction. The
        # header's CONSUMER OBLIGATION therefore covers this arm like every other -
        # a pi primary runs without permission prompts too, it just gets there
        # structurally rather than by a bypass flag. Nothing is missing here.
        # The FM_PI_HARNESS identity marker rides every Pi-family launch, primary
        # included (README.md:104 documents the signed primary as
        # `FM_PI_HARNESS=pi-signed pi-signed`): the selected $harness is both the
        # invoked binary and the marker, so a signed primary's environment cannot
        # relabel a plain Pi session.
        pi|pi-signed) printf '%s%s' "FM_PI_HARNESS=$harness $harness" ' __MODELFLAG____EFFORTFLAG__' ;;
        # --trust is supervision-safety knowledge, not one-time setup trivia:
        # without folder trust the primary turn-end guard FAILS OPEN
        # (.agents/skills/harness-adapters/SKILL.md:355), and because trust is
        # granted once per clone a fresh clone is exactly when its absence bites
        # (README.md:107, docs/turnend-guard.md:71). The empirical primary launch
        # is tests/fm-grok-continuity-live-e2e.test.sh:76,
        # `grok --trust --always-approve --reasoning-effort low`, where
        # --reasoning-effort is what __EFFORTFLAG__ resolves to; README.md:96
        # documents the same `grok --trust`. --always-approve auto-approves every
        # tool execution (.agents/skills/harness-adapters/SKILL.md:314), so the
        # header's CONSUMER OBLIGATION covers this arm: a consumer must tell the
        # captain this session has no permission prompts.
        grok) printf '%s' 'grok --trust --always-approve __MODELFLAG____EFFORTFLAG__' ;;
        # kimi refuses rather than emitting an unsubstitutable command: README.md:61
        # lists only Claude Code, Grok, Pi, pi-signed, Codex, and OpenCode as verified
        # primary harnesses (docs/configuration.md:191 defers that narrower set to README),
        # and only bin/fm-spawn.sh can resolve __KIMIBIN__ (see the header above).
        # A non-zero return is the same refusal an unverified adapter gets.
        kimi) return 1 ;;
        *) return 1 ;;
      esac
      return 0
      ;;
  esac
  # shellcheck disable=SC2016  # single quotes are deliberate: $(cat ...) expands in the crewmate pane, not here
  case "$harness" in
    # CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false disables claude's interactive
    # predicted-next-prompt ghost text, which renders as dim/faint text inside an
    # otherwise-empty composer and would otherwise read like real typed input when
    # firstmate captures the pane (see the harness-adapters skill). It is a per-launch env
    # prefix scoped to this firstmate-launched agent; it never touches the captain's
    # global config. The CLI's --prompt-suggestions flag is print/SDK-mode only and
    # does NOT suppress the interactive ghost text (verified empirically), so the env
    # var is the correct control. The dim-aware composer reader in fm-tmux-lib.sh is
    # the defense-in-depth backstop for any pane this flag cannot reach.
    #
    # The permission flags come from launch_claude_permission_flags above. They
    # ride the ARGV, not only the per-task settings file bin/fm-spawn.sh
    # generates, because this one arm serves ship, scout AND secondmate, and a
    # secondmate is launched in a provisioned home where no such file is written:
    # a posture carried only by that file would leave every secondmate launch
    # denying ordinary work. The two carriers read one owner, so they agree.
    claude) printf '%s%s' \
      "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude $(launch_claude_permission_flags) " \
      '__MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    codex)
      if [ "$kind" = secondmate ]; then
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch __TURNEND__\"]" "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\''{"permission":{"*":"allow"}}'\'' opencode __MODELFLAG__--prompt "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # pi-signed is a distinct executable identity that shares pi's verified flag
    # surface, never an alias: the selected $harness is both the invoked binary
    # and the FM_PI_HARNESS identity marker, so a signed primary's environment
    # cannot relabel a plain Pi worker (or vice versa). The marker is part of
    # the verified command, so it lives here, not in any caller.
    pi|pi-signed)
      if [ "$kind" = secondmate ]; then
        printf '%s%s' "FM_PI_HARNESS=$harness $harness" ' __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      else
        printf '%s%s' "FM_PI_HARNESS=$harness $harness" ' __MODELFLAG____EFFORTFLAG__-e __PIEXT__ "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
      fi
      ;;
    # grok (Grok Build TUI): a positional prompt starts the supervised interactive
    # session. --always-approve auto-approves every tool execution (verified: the
    # crewmate runs fully autonomously, no permission gate), which an unattended
    # crewmate needs; it is the targeted equivalent of claude's
    # --dangerously-skip-permissions. grok's turn-end signal does NOT ride the
    # launch command - it is a Stop-event hook installed by fm-spawn.sh (global hook +
    # per-task pointer), so the template is identical for ship/scout/secondmate.
    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__"$(__OPINPUT__ encode launch-brief < __BRIEF__)"' ;;
    # Kimi Code rejects a positional prompt, so it launches bare and receives
    # only an absolute brief pointer after fm-spawn.sh's TUI readiness gate.
    # Its turn-end signal is a globally configured Stop hook plus a guarded
    # per-task worktree token, so no launch placeholder belongs here.
    kimi) printf '%s' '__KIMIBIN__ __MODELFLAG__--auto' ;;
    *) return 1 ;;
  esac
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi)
      printf -- '--model %s ' "$(shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      # The installed codex config schema uses model_reasoning_effort. Verified
      # 2026-08-10 on codex-cli 0.146.0: the model catalog advertises max for
      # gpt-5.6-luna, gpt-5.6-sol, gpt-5.6-sol-wm, gpt-5.6-terra, and
      # codex-auto-review, and a real max run was accepted (rollout
      # 019feb90-c855). Which levels a given model accepts is a routing concern,
      # not this flag's: max on a model that lacks it is refused with a visible
      # 400 unsupported_value, which is the right failure rather than the silent
      # downgrade this case used to produce. ultra stays out until sol and terra
      # have their own evidence.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '-c %s ' "$(shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      # grok exposes both --effort and --reasoning-effort; firstmate's profile
      # axis is the reasoning knob. As of grok 0.2.99, --reasoning-effort accepts
      # only low|medium|high and rejects both xhigh and max, so omit those rather
      # than passing a known-bad value.
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    pi|pi-signed)
      # Pi 0.80.6 accepts the full shared effort vocabulary, including max, through
      # its --thinking flag.
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(shell_quote "$effort")" ;;
      esac
      ;;
    # opencode's interactive `opencode --prompt` launch has a verified --model
    # flag but no verified effort flag. Its `opencode run --variant` flag belongs
    # to a different, non-interactive launch mode, so fm-spawn does not pass it.
    # kimi likewise has no reasoning-effort flag; the requested axis stays in
    # task metadata but never reaches the launch command.
  esac
}
