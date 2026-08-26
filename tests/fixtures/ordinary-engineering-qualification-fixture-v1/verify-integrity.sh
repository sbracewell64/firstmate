#!/usr/bin/env bash
# verify-integrity.sh [<expected-digest>] - prove this package is the one a
# record was graded by.
#
# Prints the manifest digest. With an argument, compares and exits non-zero on a
# mismatch. A qualification record cites a digest so the observation binds to
# EXACT BYTES: if the tasks or the grading key change, the record describes a
# measurement that no longer exists, and the register must see that as a
# freshness dependency having moved rather than silently keep reading.
#
# The digest covers every file the grading depends on - the cases, the oracle,
# the setup, the controls, and the synthetic material - and deliberately not this
# script or the README, which cannot change a verdict.
set -u

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED=${1:-}

command -v sha256sum >/dev/null 2>&1 || {
  printf 'verify-integrity: sha256sum is required and is not installed\n' >&2
  exit 2
}

# A fixed, sorted file list read from the filesystem rather than a stored
# manifest of names: a stored list would let a file ADDED to material/ change
# what the candidate sees while the digest stayed put.
DIGEST=$(
  {
    for f in cases.json setup.sh verify.sh run-controls.sh; do
      [ -f "$PKG/$f" ] || { printf 'MISSING %s\n' "$f"; continue; }
      sha256sum "$PKG/$f" | awk -v n="$f" '{print $1" "n}'
    done
    if [ -d "$PKG/material" ]; then
      find "$PKG/material" -type f -print0 2>/dev/null \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' f; do
            sha256sum "$f" | awk -v n="material/${f##*/}" '{print $1" "n}'
          done
    fi
  } | LC_ALL=C sort | sha256sum | awk '{print $1}'
)

if [ -z "$DIGEST" ]; then
  printf 'verify-integrity: could not compute a digest\n' >&2
  exit 2
fi

printf '%s\n' "$DIGEST"

if [ -n "$EXPECTED" ] && [ "$DIGEST" != "$EXPECTED" ]; then
  printf 'verify-integrity: package digest %s does not match the expected %s\n' \
    "$DIGEST" "$EXPECTED" >&2
  exit 1
fi
