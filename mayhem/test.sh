#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Upstream's cmocka unit tests that need no Snowflake account or network (mayhem/unit-tests.txt), built by
# mayhem/build.sh with upstream's tests/CMakeLists.txt into build/tests/tests, and run from there because
# that is where CMake stages tests/data. Every test function is a set of cmocka assert_*() calls on values
# the library computed, and the counts below are cmocka's own summary, not the exit status: a binary that
# exits without printing a consistent summary (a crash, or a no-op exit(0)) counts as one failure.
bindir="$SRC/build/tests/tests"
mapfile -t UNIT_TESTS < <(grep -v '^[[:space:]]*\(#\|$\)' mayhem/unit-tests.txt)
[ "${#UNIT_TESTS[@]}" -gt 0 ] || { echo "mayhem/unit-tests.txt lists no tests" >&2; emit_ctrf "cmocka" 0 1 0; exit 1; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/sfc-test.XXXXXX")"; trap 'rm -rf "$scratch"' EXIT
passed=0; failed=0
for t in "${UNIT_TESTS[@]}"; do
  bin="$bindir/$t"
  if [ ! -x "$bin" ]; then echo "missing test binary $bin (build.sh should have produced it)" >&2; failed=$((failed + 1)); continue; fi
  # HOME points at an empty scratch dir so tests that read or write per-user files (token cache, config)
  # see the same clean state on every run.
  mkdir -p "$scratch/$t"
  out=$(cd "$bindir" && HOME="$scratch/$t" "./$t" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^\[( +(OK|FAILED|PASSED|SKIPPED) +|=+)\]' || true
  # cmocka 1.1.1 prints "[==========] N test(s) run."; newer releases print "[==========] tests: N test(s) run."
  ran=$(printf '%s\n' "$out" | sed -n 's/^\[=*\] \(tests: \)\{0,1\}\([0-9][0-9]*\) test(s) run\./\2/p' | tail -1)
  p=$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) test(s)\./\1/p' | tail -1)
  f=$(printf '%s\n' "$out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) test(s).*/\1/p' | tail -1)
  if [ -z "$ran" ] || [ "$ran" -eq 0 ] || { [ -z "$f" ] && [ "${p:-0}" -ne "$ran" ]; }; then
    echo "$t: no consistent cmocka summary (rc=$rc)" >&2; failed=$((failed + 1)); continue
  fi
  passed=$((passed + ${p:-0})); failed=$((failed + ${f:-0}))
  [ "$rc" -eq 0 ] || [ "${f:-0}" -gt 0 ] || failed=$((failed + 1))
done
emit_ctrf "cmocka" "$passed" "$failed" 0
