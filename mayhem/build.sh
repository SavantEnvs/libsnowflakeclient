#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# libsnowflakeclient's full build needs openssl, curl, the AWS/Azure SDKs, Arrow and Boost built from
# source (scripts/build_dependencies.sh, network). Fuzzing and the unit tests only need the part of the
# library that parses untrusted text, so this builds exactly that slice straight from the upstream
# sources against the apt Boost/curl/openssl headers baked into the image. Nothing is fetched here: the
# cJSON release (which upstream's own build script git-clones) lives in the image at $CJSON_SRC.
: "${CJSON_SRC:=/opt/toolchains/deps/cJSON-1.7.19}"

# Upstream's generated lib/cJSON.{c,h} (cJSON + patches/libsfc-cJSON-1.7.19.patch), built into build/ (gitignored).
rm -rf build/cjson && mkdir -p build/cjson
cp "$CJSON_SRC/cJSON.c" "$CJSON_SRC/cJSON.h" build/cjson/
patch -s -p1 -d build/cjson < patches/libsfc-cJSON-1.7.19.patch

INCS=(-I"$SRC/include" -I"$SRC/lib" -I"$SRC/build/cjson" -I"$SRC/cpp" -I"$SRC/deps/picojson" -I"$SRC/deps/tomlplusplus/include")
C_STD=(-w -std=gnu99 -D_LARGEFILE64_SOURCE -DLOG_USE_COLOR)
CXX_STD=(-w -std=c++17 -D_LARGEFILE64_SOURCE -DLOG_USE_COLOR)

SLICE_C=(
  lib/arraylist.c lib/basic_types.c lib/error.c lib/logger.c lib/memory.c lib/platform.c
  lib/rbtree.c lib/snowflake_util.c lib/treemap.c lib/uuid4.c build/cjson/cJSON.c
)
SLICE_CXX=(
  cpp/logger/ISFLogger.cpp cpp/logger/SFLogger.cpp cpp/logger/SecretDetector.cpp
  cpp/util/Base64.cpp cpp/util/SFURL.cpp cpp/util/SnowflakeCommon.cpp cpp/util/Proxy.cpp cpp/util/LogFileUtil.cpp
  cpp/util/SnowflakeCppUtil.cpp
  cpp/lib/QueryContextCache.cpp cpp/lib/ClientQueryContextCache.cpp
  cpp/lib/client_config_parser.cpp cpp/lib/TomlConfigParser.cpp mayhem/slice_stubs.cpp
)

# build_slice <dir> <flags...>: compile the slice into <dir>/libsfslice.a with the given extra flags.
build_slice() {
  local dir="$1"; shift
  rm -rf "$dir" && mkdir -p "$dir/obj"
  local jobs=()
  local f
  for f in "${SLICE_C[@]}"; do
    jobs+=("$CC ${C_STD[*]} ${INCS[*]} $* -c $f -o $dir/obj/$(echo "$f" | tr / _).o")
  done
  for f in "${SLICE_CXX[@]}"; do
    jobs+=("$CXX ${CXX_STD[*]} ${INCS[*]} $* -c $f -o $dir/obj/$(echo "$f" | tr / _).o")
  done
  printf '%s\n' "${jobs[@]}" | xargs -P "$MAYHEM_JOBS" -I{} bash -c '{}'
  ar rcs "$dir/libsfslice.a" "$dir"/obj/*.o
}

SLICE_LIBS=(-lboost_regex -lboost_filesystem -lboost_url -lcrypto -lssl -lcurl -lz -lm -ldl -lpthread)

# 1) The sanitized, DWARF-3 build of the slice, twice: with libFuzzer coverage instrumentation (fuzz targets,
#    so the fuzzed library code reports edges) and without (the run-once -standalone reproducers).
# -DNDEBUG matches upstream's Release build (cmake default for -DCMAKE_BUILD_TYPE=Release); without it the vendored
# toml++ parser's debug-only assert()s abort on malformed documents that a Release client simply rejects.
build_slice build/fuzz $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 -DNDEBUG
build_slice build/standalone $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -DNDEBUG

# 2) Fuzz harnesses, each twice: libFuzzer engine, and the run-once standalone reproducer.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
for t in fuzz_secret_detector fuzz_base64 fuzz_sfurl fuzz_query_context_cache fuzz_client_config fuzz_toml_config fuzz_cjson; do
  if [ -f "mayhem/$t.cpp" ]; then COMPILE=("$CXX" "${CXX_STD[@]}" "mayhem/$t.cpp"); else COMPILE=("$CC" "${C_STD[@]}" "mayhem/$t.c"); fi
  "${COMPILE[@]}" "${INCS[@]}" $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -O1 -DNDEBUG -c -o "build/fuzz/$t.o"
  "${COMPILE[@]}" "${INCS[@]}" $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -DNDEBUG -c -o "build/standalone/$t.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "build/fuzz/$t.o" build/lsan_off.o \
      build/fuzz/libsfslice.a "${SLICE_LIBS[@]}" -o "$SRC/$t"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "build/standalone/$t.o" build/standalone_main.o build/lsan_off.o \
      build/standalone/libsfslice.a "${SLICE_LIBS[@]}" -o "$SRC/$t-standalone"
done

# 3) Upstream's own cmocka unit tests for the same code, built with the project's normal flags.
build_slice build/tests -O1
mkdir -p build/tests/bin
$CC "${C_STD[@]}" "${INCS[@]}" -I"$SRC/tests" -O1 -c mayhem/test_shims.c -o build/tests/test_shims.o
for t in $(cat mayhem/unit-tests.txt); do
  src="tests/$t.c"; [ -f "$src" ] || src="tests/$t.cpp"
  if [[ "$src" == *.cpp ]]; then
    $CXX "${CXX_STD[@]}" "${INCS[@]}" -I"$SRC/tests" -O1 "$src" build/tests/test_shims.o tests/utils/TestSetup.cpp \
        build/tests/libsfslice.a "${SLICE_LIBS[@]}" -lcmocka -o "build/tests/bin/$t"
  else
    $CC "${C_STD[@]}" "${INCS[@]}" -I"$SRC/tests" -O1 "$src" build/tests/test_shims.o \
        build/tests/libsfslice.a "${SLICE_LIBS[@]}" -lstdc++ -lcmocka -o "build/tests/bin/$t"
  fi
done
