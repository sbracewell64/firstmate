#!/usr/bin/env node
// Semantic policy for the read-only execution surface: does a shell command
// attempt to WRITE anything outside the narrow set of paths a read-only task
// legitimately owns?
//
// A read-only task is dispatched onto a sealed subject with no worktree
// (bin/fm-readonly-lib.sh owns that surface). Its harness tool gate already
// denies Edit/Write/MultiEdit/NotebookEdit, but Bash cannot be denied wholesale
// - inspection IS reading files and running read-only commands - so this policy
// carries the Bash half of the enforcement. The environmental scoping and the
// harness response shape live in the bin/fm-readonly-pretool-check.sh transport,
// not here.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, exactly as bin/fm-cd-command-policy.mjs does. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command.
//
// IT FAILS CLOSED, and that is the one place it deliberately parts company with
// its cd-guard sibling. The cd-guard fails OPEN because it is a seatbelt against
// an agent mistake and a false block there costs a working command. This guard
// is the mechanism that makes "read-only" true, so a command it cannot classify
// is denied rather than waved through: an unparseable command that gets allowed
// is exactly the hole that turns a read-only claim into a claim nobody checked.
//
// WHAT IS ALLOWED TO BE WRITTEN. A read-only task still has to produce its
// deliverable, so a flat "no writes" would make the surface useless. Exactly
// three destinations are writable, all of them the task's own:
//   <home>/data/<task-id>/**     the report - the entire work product
//   <home>/state/<task-id>.status the task's own status file
//   <task-tmp>/**                the task's own scratch root
// Every other path is denied, which subsumes the enumerated protected trees
// (the home's config/, data/, state/, qualifications/, bin/, and any project
// path): they are denied because they are not one of the three, so the rule
// cannot go stale when a new protected directory is added.
//
// AND NO AUTHORITY WIDENING. Writing files is not the only way to change fleet
// state: minting a decision, a landing authorization, or a control comment is
// done by firstmate's own lifecycle scripts and by the forge CLIs, several of
// which reach the network rather than the disk. Those are denied by the NAME of
// the program being run, because no path rule can see them. A readonly task
// reports, and firstmate acts on the report.
//
// THIS IS A CAPABILITY BOUNDARY, NOT A SECURITY BOUNDARY. It is a deny-list
// over write verbs plus a write-target allowance, and a deny-list is never
// exhaustive - a determined escape has many shapes this does not model. It
// stops a worker that is trying to do its job from mutating a subject it was
// told to inspect. Nothing here should ever be cited as containment.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import path from "node:path";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "write-outside-allowance":
    "a read-only task may write only its own report (data/<task-id>/), its own status file, and its own scratch root; this command writes somewhere else",
  "mutating-git":
    "a read-only task may not run a git subcommand that writes: it has no worktree to change and no authority to publish",
  "authority-widening":
    "a read-only task may not mint decisions, landing authorizations, control comments, or other fleet state; it reports, and firstmate acts on the report",
  "unclassifiable-command":
    "this command could not be classified, and a read-only surface denies what it cannot read rather than allowing it",
};

// Commands whose ordinary purpose is to change the filesystem. `tee` is here
// because it writes its operands; `cp` because it writes a destination.
const MUTATORS = new Set([
  "rm", "rmdir", "unlink", "mv", "cp", "dd", "truncate", "shred",
  "chmod", "chown", "chgrp", "ln", "mkdir", "touch", "install",
  "tee", "rsync", "patch", "mktemp",
]);

// git subcommands that write to refs, the object store, the index, the working
// tree, or a remote. Anything not listed is treated as read-only (log, show,
// diff, status, rev-parse, cat-file, ls-files, grep, blame, describe...), which
// is what an inspection actually needs.
const GIT_MUTATING = new Set([
  "push", "commit", "checkout", "switch", "branch", "merge", "rebase", "reset",
  "clean", "add", "stash", "tag", "am", "apply", "cherry-pick", "revert",
  "worktree", "gc", "config", "fetch", "pull", "remote", "update-ref",
  "symbolic-ref", "mv", "rm", "init", "clone", "submodule", "notes", "replace",
  "filter-branch", "prune", "repack", "restore", "update-index", "write-tree",
  "commit-tree", "hash-object", "fast-import", "bisect",
]);

// Editors that rewrite their input in place when given the in-place flag.
const INPLACE_EDITORS = new Set(["sed", "perl", "ruby", "gawk", "awk"]);

// NO AUTHORITY WIDENING. A read-only task may not mint a decision, a landing
// authorization, or a control comment, and those are not FILE writes the
// allowance rule above can see: they are actions taken by firstmate's own
// lifecycle scripts and by the forge CLIs, several of which reach the network
// rather than the disk.
//
// These are denied by the name of the program being RUN, not by what it writes.
// An inspection reads these scripts; it does not execute them. Denying them by
// name is what keeps a readonly worker from doing through a tool what it cannot
// do through a file.
const AUTHORITY_SCRIPTS = new Set([
  "fm-spawn.sh", "fm-teardown.sh", "fm-reflag.sh", "fm-attempt.sh",
  "fm-decision-hold.sh", "fm-landing-authorization.sh", "fm-outbound-artifact.sh",
  "fm-pr-merge.sh", "fm-merge-local.sh", "fm-pr-check.sh", "fm-qualification.sh",
  "fm-commitment-register.sh", "fm-public-followup.sh", "fm-send.sh",
  "fm-check-register.sh", "fm-watch-arm.sh", "fm-loop-actuate.sh",
  "no-mistakes",
]);

// The forge and backlog CLIs are not denied outright, because reading issues and
// the backlog is ordinary inspection work. Only their READ subcommands are
// allowed, and anything else - including a subcommand this policy has never
// heard of - is denied, so the list fails closed as those tools grow.
const GUARDED_CLI_READ_SUBCOMMANDS = {
  gh: new Set(["list", "view", "status", "search", "diff", "checks"]),
  "gh-axi": new Set(["list", "view", "status", "search", "diff", "checks"]),
  "tasks-axi": new Set(["list", "show", "ready", "view", "status"]),
};

// Redirection operators that can create or extend a file.
const WRITE_REDIRS = new Set([">", ">>", ">|", "&>", "&>>", "<>", ">&"]);

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

const ALLOW = { decision: "allow" };

function basename(value) {
  const trimmed = String(value || "");
  const slash = trimmed.lastIndexOf("/");
  return slash === -1 ? trimmed : trimmed.slice(slash + 1);
}

// Resolve a path operand for comparison. Relative operands resolve against the
// declared cwd; with no cwd declared a relative write cannot be located at all,
// and an unlocatable write is denied rather than assumed harmless.
function resolveOperand(operand, cwd) {
  if (!operand) return null;
  if (operand.startsWith("/")) return path.resolve(operand);
  if (!cwd) return null;
  return path.resolve(cwd, operand);
}

function isWithin(child, parent) {
  if (!child || !parent) return false;
  const rel = path.relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

// The three destinations a read-only task owns. A write is allowed only when its
// target lies inside one of them.
function buildAllowances({ home, task, tasktmp }) {
  const allowances = [];
  if (home && task) {
    allowances.push({ kind: "dir", path: path.resolve(home, "data", task) });
    allowances.push({ kind: "file", path: path.resolve(home, "state", `${task}.status`) });
  }
  if (tasktmp) allowances.push({ kind: "dir", path: path.resolve(tasktmp) });
  return allowances;
}

// The sealed subject is EXCLUDED even though it lives inside the task's own
// writable temp root, which is where it has to live so one teardown removes
// everything. Without this carve-out the scratch allowance would hand back write
// access to the very tree the surface exists to protect. The OS permissions the
// seal applies already refuse these writes; this is the second, independent
// mechanism, and it is the one that still refuses if the permissions were
// somehow not applied.
function targetIsAllowed(target, allowances, subject) {
  if (!target) return false;
  if (subject && isWithin(target, subject)) return false;
  for (const allowance of allowances) {
    if (allowance.kind === "file") {
      if (target === allowance.path) return true;
      continue;
    }
    if (isWithin(target, allowance.path)) return true;
  }
  return false;
}

// A word that carries a command or process substitution hides commands this
// classifier must still judge. Returning them lets the caller recurse instead of
// treating `$(rm -rf /)` as an inert string.
function substitutionPayloads(word) {
  if (!word || !Array.isArray(word.subs)) return [];
  return word.subs
    .filter((sub) => sub && (sub.kind === "command" || sub.kind === "process"))
    .map((sub) => sub.content)
    .filter(Boolean);
}

function looksLikeOption(value) {
  return typeof value === "string" && value.startsWith("-") && value !== "-";
}

function hasInplaceFlag(words, startIndex) {
  for (let i = startIndex; i < words.length; i += 1) {
    const value = words[i].value;
    if (!looksLikeOption(value)) continue;
    if (value === "-i" || value.startsWith("-i.") || value.startsWith("--in-place")) return true;
    // Bundled short options such as -ne combined with i, e.g. `sed -ni`.
    if (/^-[a-zA-Z]*i/.test(value) && !value.startsWith("--")) return true;
  }
  return false;
}

function decision(command, context, depth = 0) {
  // A substitution nested this deep is pathological rather than ordinary work,
  // and refusing to keep descending is the fail-closed direction.
  if (depth > 8) return deny("unclassifiable-command");

  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return deny("unclassifiable-command");

  const allowances = buildAllowances(context);
  const subject = context.subject ? path.resolve(context.subject) : null;
  const { nodes } = splitProgram(lexed.tokens);

  for (const nodeTokens of nodes) {
    // 1. Write redirections. wordsInNode drops the redirection target, so the
    //    raw token stream is where a `> path` is visible at all.
    for (let i = 0; i < nodeTokens.length; i += 1) {
      const token = nodeTokens[i];
      if (!token || token.type !== "redir") continue;
      if (!WRITE_REDIRS.has(token.value)) continue;
      // `>&2` / `2>&1` duplicate a descriptor rather than naming a file.
      const targetToken = token.inlineTarget ? null : nodeTokens[i + 1];
      const raw = token.inlineTarget || (targetToken && targetToken.value) || "";
      if (/^&?\d+$/.test(String(raw))) continue;
      if (String(raw) === "/dev/null" || String(raw).startsWith("/dev/std")) continue;
      const resolved = resolveOperand(String(raw), context.cwd);
      if (!targetIsAllowed(resolved, allowances, subject)) return deny("write-outside-allowance");
    }

    const position = commandPosition(nodeTokens);

    // 2. Commands hidden inside substitutions are judged on their own terms.
    for (const word of position.words) {
      for (const payload of substitutionPayloads(word)) {
        const nested = decision(payload, context, depth + 1);
        if (nested.decision === "deny") return nested;
      }
    }

    const commandWord = position.command;
    if (!commandWord) continue;
    const name = basename(commandWord.value);
    const operands = position.words.slice(position.index + 1);

    // 3. git, judged by its subcommand rather than by the bare program name, so
    //    `git log` stays available to an inspection.
    if (name === "git") {
      let subIndex = 0;
      // Skip global options and their values (-C <dir>, -c k=v, --git-dir=...).
      while (subIndex < operands.length) {
        const value = operands[subIndex].value;
        if (!looksLikeOption(value)) break;
        subIndex += (value === "-C" || value === "-c" || value === "--git-dir" || value === "--work-tree") ? 2 : 1;
      }
      const sub = operands[subIndex] && operands[subIndex].value;
      if (sub && GIT_MUTATING.has(sub)) return deny("mutating-git");
      continue;
    }

    // 4. No authority widening: firstmate's own lifecycle scripts, and the
    //    non-read subcommands of the forge and backlog CLIs.
    if (AUTHORITY_SCRIPTS.has(name)) return deny("authority-widening");
    if (Object.prototype.hasOwnProperty.call(GUARDED_CLI_READ_SUBCOMMANDS, name)) {
      let subIndex = 0;
      while (subIndex < operands.length && looksLikeOption(operands[subIndex].value)) subIndex += 1;
      // A bare `gh` prints help and is harmless; a subcommand must be a known
      // read one. An unrecognized subcommand denies rather than passing, so this
      // list stays fail-closed as those CLIs grow.
      if (subIndex < operands.length) {
        const readSet = GUARDED_CLI_READ_SUBCOMMANDS[name];
        // These CLIs nest a noun before the verb and often take a bare argument
        // after it, so neither the first nor the last bare word is reliably the
        // ACTION. The two shapes that forces, written out:
        //   gh pr list  // fm-retrieval-audit: not-a-read - a documentation example in a comment; this line invokes nothing and enumerates no collection
        //   gh pr view 12  // fm-retrieval-audit: not-a-read - a documentation example in a comment; this line invokes nothing and enumerates no collection
        // Accept when a read verb appears anywhere among the bare words that
        // precede the first option; a mutating verb never does, so this stays
        // fail-closed.
        let sawRead = false;
        for (let i = subIndex; i < operands.length; i += 1) {
          const value = operands[i].value;
          if (looksLikeOption(value)) break;
          if (readSet.has(value)) { sawRead = true; break; }
        }
        if (!sawRead) return deny("authority-widening");
      }
    }

    // 5. In-place editors.
    if (INPLACE_EDITORS.has(name) && hasInplaceFlag(position.words, position.index + 1)) {
      return deny("write-outside-allowance");
    }

    // 6. Filesystem mutators. Every path-like operand must land in an allowance;
    //    an operand that cannot be resolved is not allowed, so a relative write
    //    with no declared cwd denies rather than passing unlocated.
    if (MUTATORS.has(name)) {
      const targets = operands.filter((word) => !looksLikeOption(word.value));
      // A mutator with no operand at all (or only options) is not something this
      // policy can locate, and it fails closed like everything else here.
      if (targets.length === 0) return deny("write-outside-allowance");
      for (const target of targets) {
        const resolved = resolveOperand(target.value, context.cwd);
        if (!targetIsAllowed(resolved, allowances, subject)) return deny("write-outside-allowance");
      }
    }
  }

  return ALLOW;
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, home: "", task: "", tasktmp: "", cwd: "", subject: "" };
  const names = new Set(["--command", "--home", "--task", "--tasktmp", "--cwd", "--subject"]);
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (names.has(name)) {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      const key = name.slice(2);
      result[key] = argv[i + 1];
      if (name === "--command") result.commandSet = true;
      i += 1;
      continue;
    }
    const eq = [...names].find((candidate) => name.startsWith(`${candidate}=`));
    if (eq) {
      const key = eq.slice(2);
      result[key] = name.slice(eq.length + 1);
      if (eq === "--command") result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    // An empty command is nothing to run, so there is nothing to deny. Every
    // other unreadable state below denies.
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, {
        home: args.home,
        task: args.task,
        tasktmp: args.tasktmp,
        cwd: args.cwd,
        subject: args.subject,
      });
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
