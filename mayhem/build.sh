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

# libsnowflakeclient links OpenSSL, a Snowflake-patched curl, the AWS and Azure SDKs, Arrow, Boost and a few
# smaller libraries, all of which upstream builds from source over the network
# (scripts/build_dependencies.sh). mayhem/Dockerfile runs that once (mayhem/deps.sh) and bakes the result
# into /opt/toolchains/deps/<name>-<version>/; nothing is fetched here, so this script re-runs air-gapped.
# What it builds is upstream's real `snowflakeclient` CMake target (the whole client, not a subset), which
# the harnesses and upstream's own unit tests then link.
: "${SFC_DEPS:=/opt/toolchains/deps}"
[ -d "$SFC_DEPS/libsnowflakeclient-deps-build/linux/Release" ] \
  || { echo "build.sh: $SFC_DEPS/libsnowflakeclient-deps-build is missing (mayhem/deps.sh builds it in the image)" >&2; exit 1; }

# Upstream's CMakeLists.txt reads every dependency from ./deps-build/linux/Release/<name>/{include,lib};
# deps-build/ is upstream's directory. The link is replaced on every build, so it does not matter
# whether a `git clean -ffdX` leaves it behind (upstream's deps-build/.gitignore lists `linux/`, which
# matches a directory but not this symlink).
ln -sfn "$SFC_DEPS/libsnowflakeclient-deps-build/linux" deps-build/linux
DEPS="$SRC/deps-build/linux/Release"

# lib/cJSON.{c,h} are generated, and gitignored: upstream's build_libsnowflakeclient.sh clones cJSON, applies
# patches/libsfc-cJSON-*.patch and copies the two files into lib/. Same here, from the baked source.
cjson_src="$(echo "$SFC_DEPS"/cJSON-*/src)"
gen="$SRC/build/cjson-gen"; rm -rf "$gen"; mkdir -p "$gen"
cp "$cjson_src/cJSON.c" "$cjson_src/cJSON.h" "$gen/"
patch -s -p1 -d "$gen" < "$(echo patches/libsfc-cJSON-*.patch)"
for f in cJSON.c cJSON.h; do cmp -s "$gen/$f" "lib/$f" || cp "$gen/$f" "lib/$f"; done   # keep mtimes on a re-run

# configure_and_build <dir> "<extra C/C++ flags>" <cmake args...> -- <targets...>
# Upstream's CMake build, Release (its documented default: -O3 -DNDEBUG). -w because upstream adds -Werror
# for the gcc it pins, and clang's warning set differs. ARROW_FROM_SOURCE selects the from-source Arrow
# library set in CMakeLists.txt, which is what deps.sh built. The compiler comes from $CC/$CXX.
configure_and_build() {
  local dir="$1" flags="$2"; shift 2
  local args=()
  while [ "$1" != "--" ]; do args+=("$1"); shift; done; shift
  ARROW_FROM_SOURCE=1 cmake -S "$SRC" -B "$SRC/build/$dir" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_VERBOSE_MAKEFILE=OFF \
      -DCMAKE_C_FLAGS="-w $flags" -DCMAKE_CXX_FLAGS="-w $flags" "${args[@]}" > "$SRC/build/$dir.cmake.log" 2>&1 \
    || { tail -40 "$SRC/build/$dir.cmake.log" >&2; exit 1; }
  ARROW_FROM_SOURCE=1 cmake --build "$SRC/build/$dir" -j "$MAYHEM_JOBS" --target "$@" -- --no-print-directory VERBOSE= \
      > "$SRC/build/$dir.build.log" 2>&1 \
    || { grep -B2 -A12 -m5 'error' "$SRC/build/$dir.build.log" >&2; tail -15 "$SRC/build/$dir.build.log" >&2; exit 1; }
}
mkdir -p build

# 1) The client library, sanitized and DWARF-3, twice: with libFuzzer's coverage instrumentation
#    (-fsanitize=fuzzer-no-link, always: without it Mayhem sees no edges in the library) for the fuzz
#    targets, and without it for the run-once -standalone reproducers. TRY_COMPILE as a static library
#    because fuzzer-no-link objects only link once libFuzzer or a sanitizer runtime is present.
configure_and_build fuzz "$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
    -DBUILD_TESTS=OFF -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -- snowflakeclient
configure_and_build standalone "$SANITIZER_FLAGS $DEBUG_FLAGS" \
    -DBUILD_TESTS=OFF -- snowflakeclient

# What a program using libsnowflakeclient.a links, from tests/CMakeLists.txt (TESTLIB_OPTS_CXX), as a group
# so only the objects a harness actually reaches are pulled in. Dependencies stay uninstrumented.
A="$DEPS/aws/lib64"
DEP_LIBS=(
  -Wl,--start-group
  "$DEPS/arrow/lib64/libarrow.a" "$DEPS/arrow_deps/lib/libjemalloc_pic.a"
  "$DEPS/boost/lib/libboost_filesystem.a" "$DEPS/boost/lib/libboost_system.a"
  "$DEPS/boost/lib/libboost_url.a" "$DEPS/boost/lib/libboost_regex.a"
  "$DEPS/azure/lib/libazure-storage-blobs.a" "$DEPS/azure/lib/libazure-storage-common.a"
  "$DEPS/azure/lib/libazure-core.a" "$DEPS/xml2/lib/libxml2.a"
  "$A/libaws-cpp-sdk-s3.a" "$A/libaws-cpp-sdk-sts.a" "$A/libaws-cpp-sdk-core.a" "$A/libaws-crt-cpp.a"
  "$A/libaws-c-event-stream.a" "$A/libaws-checksums.a" "$A/libaws-c-s3.a" "$A/libaws-c-auth.a"
  "$A/libaws-c-http.a" "$A/libaws-c-compression.a" "$A/libaws-c-io.a" "$A/libaws-c-cal.a"
  "$A/libaws-c-mqtt.a" "$A/libs2n.a" "$A/libaws-c-sdkutils.a" "$A/libaws-c-common.a"
  "$DEPS/oob/lib/libtelemetry.a" "$DEPS/curl/lib/libcurl.a" "$DEPS/openssl/lib/libssl.a"
  "$DEPS/openssl/lib/libcrypto.a" "$DEPS/uuid/lib/libuuid.a" "$DEPS/zlib/lib/libz.a"
  -Wl,--end-group -pthread -lrt -ldl -lm
)
# The include path upstream's CMakeLists.txt gives its own sources (headers only; no upstream file is edited).
INCS=(-I"$SRC/include" -I"$SRC/lib" -I"$SRC/cpp")
for d in oob curl openssl zlib boost arrow aws azure uuid picojson tomlplusplus; do INCS+=(-isystem "$DEPS/$d/include"); done
HARNESS_FLAGS=(-w -O1 -D_LARGEFILE64_SOURCE -DLOG_USE_COLOR -pthread)

# 2) Fuzz harnesses, each twice: libFuzzer engine, and the run-once standalone reproducer. lsan_off.o turns
#    LeakSanitizer off at build time in every binary (ASan and UBSan stay on and halting).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
link_harness() {
  local t="$1" COMPILE
  if [ -f "mayhem/$t.cpp" ]; then COMPILE=("$CXX" -std=c++17 "mayhem/$t.cpp"); else COMPILE=("$CC" -std=gnu99 "mayhem/$t.c"); fi
  "${COMPILE[@]}" "${HARNESS_FLAGS[@]}" "${INCS[@]}" $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -c -o "build/fuzz/$t.o"
  "${COMPILE[@]}" "${HARNESS_FLAGS[@]}" "${INCS[@]}" $SANITIZER_FLAGS $DEBUG_FLAGS -c -o "build/standalone/$t.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "build/fuzz/$t.o" build/lsan_off.o \
      build/fuzz/libsnowflakeclient.a "${DEP_LIBS[@]}" -o "$SRC/$t"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "build/standalone/$t.o" build/standalone_main.o build/lsan_off.o \
      build/standalone/libsnowflakeclient.a "${DEP_LIBS[@]}" -o "$SRC/$t-standalone"
}
TARGETS=(fuzz_secret_detector fuzz_base64 fuzz_sfurl fuzz_query_context_cache fuzz_client_config fuzz_toml_config fuzz_cjson fuzz_result_set_json)
pids=()
for t in "${TARGETS[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n; done
  link_harness "$t" & pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

# 3) Upstream's own cmocka unit tests (the ones listed in mayhem/unit-tests.txt: those that need no
#    Snowflake account or network), built by upstream's tests/CMakeLists.txt against a third, clean build
#    of the library with the project's normal flags: no sanitizers, no fuzz or DWARF flags. mayhem/test.sh
#    runs them from build/tests/tests, where CMake also stages tests/data.
mapfile -t UNIT_TESTS < <(grep -v '^[[:space:]]*\(#\|$\)' mayhem/unit-tests.txt)
#    Each test statically links the whole dependency set, debug info included (hundreds of MB per
#    binary), so the test executables are linked without debug sections; nothing reads them.
configure_and_build tests "$COVERAGE_FLAGS" -DBUILD_TESTS=ON -DCMAKE_EXE_LINKER_FLAGS=-Wl,--strip-debug \
    -- "${UNIT_TESTS[@]}"
