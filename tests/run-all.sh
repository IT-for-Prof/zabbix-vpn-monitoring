#!/usr/bin/env bash
# Runs every tests/test-*.sh and reports PASS / SKIP / FAIL separately.
#
# SKIP is reported as its own category ON PURPOSE. Two tests here need root + network
# namespaces, and test-gate-amneziawg.sh exits 0 with "SKIP: awg(8) not installed" when the
# tool is absent. A runner that only looks at exit codes would count all three as passes, and
# coverage would erode silently — exactly the failure mode these tests exist to catch. So a
# skip is never a pass: it is printed, counted, and listed again in the summary.
#
# Exit status: non-zero only on a real failure. Skips do not fail the run (they are
# environmental), but `--strict` turns any skip into a failure for a full-fidelity CI job.
set -u
DIR=$(cd "$(dirname "$0")" && pwd)
STRICT=${1:-}
pass=0; skip=0; fail=0; skipped=""; failed=""

for t in "$DIR"/test-*.sh; do
  name=$(basename "$t" .sh)
  # Root-gated by construction: netns rigs cannot run unprivileged. Classify up front rather
  # than letting them fail with a permission error that reads like a real defect.
  if grep -q 'ip netns' "$t" && [ "$(id -u)" != 0 ]; then
    printf '  SKIP  %-32s требует root (network namespaces)\n' "$name"
    skip=$((skip + 1)); skipped="$skipped $name(root)"; continue
  fi
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

echo "──────────────────────────────────────────────────────────"
printf 'ИТОГО: %d прошло, %d пропущено, %d упало\n' "$pass" "$skip" "$fail"
[ $skip -eq 0 ] || echo "ПРОПУЩЕНО (не считается успехом):$skipped"
[ $fail -eq 0 ] || { echo "УПАЛО:$failed"; exit 1; }
if [ "$STRICT" = --strict ] && [ $skip -gt 0 ]; then
  echo "--strict: пропуски считаются провалом (нужен root и полный набор инструментов)"
  exit 1
fi
exit 0
