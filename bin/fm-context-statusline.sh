#!/usr/bin/env bash
# Render Claude Code's host-computed context-window pressure for a Firstmate
# session without estimating from transcript text.
# Usage: fm-context-statusline.sh [--record <absolute-path>] [--ceiling <tokens>]
#
# Claude Code invokes a statusLine command with its JSON payload on stdin.
# This command reads context_window.remaining_percentage, used_percentage,
# total_tokens, and current_usage. It prints one compact display line and, when
# --record is present, atomically writes the reading plus the derived
# 70%-compaction advisory as JSON for the worker named by a generated brief.
#
# --ceiling is THE SMART-ZONE CEILING GOVERNING THIS SESSION, in tokens, as
# resolved by bin/fm-route-lib.sh: the minimum of the route's ceiling, the
# model's own smart zone, and the model's hard limit. A ceiling is an
# EXECUTION-GOVERNANCE limit and never a routing question - it says when a
# running session compacts, rotates or decomposes, and a model that exposes far
# more capacity than the ceiling is fully eligible and simply runs governed at
# it. This is the only place a ceiling changes behavior.
#
# The ceiling advises compaction the moment resident tokens reach it, which is
# usually EARLIER than the 70% host trigger and never later: the two are
# independent, either alone recommends compaction, and neither cancels the
# other. Resident tokens come from the host's own total_tokens and
# used_percentage; without total_tokens the ceiling CANNOT BE EVALUATED, and
# that is recorded as unevaluated rather than resolved either way. A ceiling
# that could not be checked has not been observed to be met, and it has not
# been observed to be exceeded either.
# Only used_percentage and remaining_percentage are required: they alone drive
# the display and the 70% trigger. total_tokens and current_usage are optional;
# when either is missing or invalid, the percentages and trigger still render,
# each missing optional field is named in the display, and the snapshot keeps
# only the fields actually present plus a missing_optional_fields list, so
# degradation is visible and no value is ever invented.
# Input without both valid percentages prints nothing, removes any requested
# stale snapshot, and exits zero so telemetry can never disrupt the host
# session.
# Snapshot persistence is best-effort: the parent directory is recreated when
# missing, and a failed write never suppresses the display line nor removes
# the last valid snapshot. Percentages display truncated to one decimal so a
# reading below 70 never shows as 70 without the compaction advisory.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

record=
ceiling=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --record)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      record=$2
      case "$record" in
        /*) ;;
        *) echo "error: --record requires an absolute path" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --ceiling)
      # A ceiling that cannot be read is refused rather than dropped. Silently
      # ignoring it would leave a session the operator believes is governed
      # running against the host default alone.
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ceiling=$2
      case "$ceiling" in
        ''|*[!0-9]*) echo "error: --ceiling requires a positive whole number of tokens" >&2; exit 2 ;;
      esac
      [ "$ceiling" -gt 0 ] 2>/dev/null || { echo "error: --ceiling requires a positive whole number of tokens" >&2; exit 2; }
      shift 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
done

IFS= read -r -d '' node_program <<'NODE' || true
const fs = require("fs");
const path = require("path");

const record = process.argv[1] || "";
const ceilingArg = process.argv[2] || "";
const ceiling = ceilingArg ? Number(ceilingArg) : null;

function clearStaleRecord() {
  if (!record) return;
  try {
    fs.unlinkSync(record);
  } catch (_) {}
}

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function formatPercentage(value) {
  let text = value.toFixed(1);
  if (Number(text) > value) text = (Number(text) - 0.1).toFixed(1);
  return text.replace(/\.0$/, "");
}

function formatTokens(value) {
  if (value >= 1000000) return `${(value / 1000000).toFixed(value % 1000000 === 0 ? 0 : 1)}m`;
  if (value >= 1000) return `${(value / 1000).toFixed(value % 1000 === 0 ? 0 : 1)}k`;
  return String(value);
}

try {
  const payload = JSON.parse(fs.readFileSync(0, "utf8"));
  const contextWindow = payload && payload.context_window;
  if (!contextWindow || typeof contextWindow !== "object" || Array.isArray(contextWindow)) throw new Error("missing context_window");

  const used = contextWindow.used_percentage;
  const remaining = contextWindow.remaining_percentage;
  const total = contextWindow.total_tokens;
  const currentUsage = contextWindow.current_usage;
  if (!finiteNumber(used) || used < 0 || used > 100) throw new Error("invalid used_percentage");
  if (!finiteNumber(remaining) || remaining < 0 || remaining > 100) throw new Error("invalid remaining_percentage");
  const hasTotal = finiteNumber(total) && total > 0;
  const hasCurrentUsage = Boolean(currentUsage) && typeof currentUsage === "object" && !Array.isArray(currentUsage);
  const missingOptional = [];
  if (!hasTotal) missingOptional.push("total_tokens");
  if (!hasCurrentUsage) missingOptional.push("current_usage");

  // The 70% host trigger, unchanged and unconditional.
  const usedPercentageTrigger = used >= 70;

  // The governed smart-zone ceiling, evaluated only against evidence the host
  // actually supplied. Three outcomes, never two: reached, not reached, and -
  // with no total_tokens to size the window - not evaluable at all. The third
  // is recorded as itself so a worker never reads an unchecked ceiling as a
  // ceiling with room left.
  let governedCeiling = null;
  if (ceiling !== null && Number.isFinite(ceiling)) {
    if (hasTotal) {
      const residentTokens = Math.round((total * used) / 100);
      governedCeiling = {
        ceiling_tokens: ceiling,
        resident_tokens: residentTokens,
        evaluated: true,
        reached: residentTokens >= ceiling,
      };
    } else {
      governedCeiling = {
        ceiling_tokens: ceiling,
        evaluated: false,
        unevaluated_reason: "total_tokens absent, so resident tokens cannot be derived",
      };
    }
  }
  const ceilingReached = Boolean(governedCeiling && governedCeiling.reached);

  // Either trigger alone recommends compaction; neither cancels the other.
  const compactRecommended = usedPercentageTrigger || ceilingReached;
  if (record) {
    try {
      const parent = path.dirname(record);
      fs.mkdirSync(parent, { recursive: true });
      const temporary = path.join(parent, `.${path.basename(record)}.${process.pid}.tmp`);
      const recordedWindow = { ...contextWindow };
      if (!hasTotal) delete recordedWindow.total_tokens;
      if (!hasCurrentUsage) delete recordedWindow.current_usage;
      const snapshot = {
        context_window: recordedWindow,
        compact_at_used_percentage: 70,
        compact_recommended: compactRecommended,
      };
      if (governedCeiling) snapshot.governed_ceiling = governedCeiling;
      if (missingOptional.length > 0) snapshot.missing_optional_fields = missingOptional;
      fs.writeFileSync(temporary, `${JSON.stringify(snapshot, null, 2)}\n`, { mode: 0o600 });
      try {
        fs.renameSync(temporary, record);
      } catch (error) {
        try { fs.unlinkSync(temporary); } catch (_) {}
        throw error;
      }
    } catch (_) {}
  }

  let line = `CTX ${formatPercentage(used)}% used / ${formatPercentage(remaining)}% left`;
  if (hasTotal) line += ` (${formatTokens(total)})`;
  if (governedCeiling) {
    line += governedCeiling.evaluated
      ? ` | zone ${formatTokens(governedCeiling.resident_tokens)}/${formatTokens(ceiling)}`
      : ` | zone ${formatTokens(ceiling)} unevaluated`;
  }
  if (missingOptional.length > 0) line += ` [missing: ${missingOptional.join(", ")}]`;
  if (compactRecommended) line += " | COMPACT NOW: /compact";
  process.stdout.write(line);
} catch (_) {
  clearStaleRecord();
}
NODE

node -e "$node_program" "$record" "$ceiling"
