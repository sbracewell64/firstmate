# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic.
# Usage: . bin/fm-quota-axi-lib.sh
#
# 0.1.16 is the floor because it is the first build that reports each provider's
# credential sources independently and exposes Grok `state.authStatus`. Without
# those fields a dispatch candidate cannot be checked against the authentication
# surface it actually uses, which is how one harness's expired CLI token used to
# produce a captain-facing sign-out claim for a candidate that never read it.
# 0.1.16 already emits schemaVersion 3 with per-model effectiveAvailability;
# 0.1.17 only adds optional runway under that same schema. quota-array-dispatch
# treats absent runway or pace as disclosed uncertainty, so the floor stays
# 0.1.16 rather than tracking the latest additive field.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.

FM_QUOTA_AXI_MIN=0.1.16

# fm_quota_axi_bounded <timeout-seconds-or-empty> <quota-axi-args...>
# One bounded quota-axi invocation, printing its stdout and returning its exit
# status. An empty timeout runs it unbounded; a non-numeric or zero timeout is
# refused rather than silently ignored, because a caller that asked for a bound
# and did not get one would block a dispatch indefinitely.
#
# Spelled here because the version check and the availability read both need the
# same fallback ladder, and a second copy would eventually bound one caller and
# not the other. The ladder itself is unchanged: coreutils timeout, then the
# macOS-installed gtimeout, then a perl process-group alarm, and a refusal when
# none of the three exists rather than an unbounded run.
fm_quota_axi_bounded() {
  local timeout=${1:-}
  shift || return 1
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -z "$timeout" ]; then
    quota-axi "$@" 2>/dev/null </dev/null
    return $?
  fi
  case "$timeout" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
      "$timeout" quota-axi "$@" 2>/dev/null </dev/null
  else
    return 1
  fi
}

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  output=$(fm_quota_axi_bounded "$timeout" --version) || return 1
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}
