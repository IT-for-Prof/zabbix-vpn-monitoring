#!/usr/bin/env bash
# Runs every tests/test-*.sh and reports PASS / SKIP / FAIL separately.
#
# SKIP is its own category ON PURPOSE. Several rigs need root, wireguard-tools, or the kernel
# module, and they self-report `SKIP: <reason>` with exit 0 when a precondition is missing. A
# runner that only looked at exit codes would count those as passes and coverage would erode
# silently — exactly the failure mode these tests exist to catch. So a skip is never a pass: it
# is printed, counted, and listed again in the summary with its reason.
#
# Classification is by the test's OWN report, not by inspecting its source. An earlier version
# grepped each file for the string `ip netns`, which meant a test that merely MENTIONED netns in
# a comment was silently reclassified as root-only and skipped forever.
#
# Exit status: non-zero only on a real failure. Skips do not fail the run (they are
# environmental), but `--strict` turns any skip into a failure for a full-coverage CI job.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
STRICT=${1:-}
pass=0; skip=0; fail=0; skipped=""; failed=""

for t in "$DIR"/test-*.sh; do
  name=$(basename "$t" .sh)
  out=$(bash "$t" 2>&1); rc=$?
  reason=$(printf '%s\n' "$out" | grep -m1 '^SKIP:' || true)
  if [ $rc -ne 0 ]; then
    printf '  FAIL  %-32s\n' "$name"
    printf '%s\n' "$out" | tail -4 | sed 's/^/          /'
    fail=$((fail + 1)); failed="$failed $name"
  elif [ -n "$reason" ]; then
    printf '  SKIP  %-32s %s\n' "$name" "${reason#SKIP: }"
    skip=$((skip + 1)); skipped="$skipped $name"
  else
    printf '  PASS  %-32s\n' "$name"
    pass=$((pass + 1))
  fi
done

echo "----------------------------------------------------------"
printf 'TOTAL: %d passed, %d skipped, %d failed\n' "$pass" "$skip" "$fail"
[ $skip -eq 0 ] || echo "SKIPPED (not a pass):$skipped"
[ $fail -eq 0 ] || { echo "FAILED:$failed"; exit 1; }
if [ "$STRICT" = --strict ] && [ $skip -gt 0 ]; then
  echo "--strict: skips count as failure (needs root, wireguard-tools, and ZVM_ALLOW_NETNS=1)"
  exit 1
fi
exit 0
