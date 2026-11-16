#!/usr/bin/env bash
#
# mayhem/deps.sh — build libsnowflakeclient's third-party dependencies ONCE, at image-build time (network
# available), into /opt/toolchains/deps/<name>-<version>/{src,include,lib}. Called by mayhem/Dockerfile as
# root; NOT called by mayhem/build.sh, which only consumes the result and therefore runs air-gapped.
#
# It runs upstream's own per-dependency scripts (scripts/build_*.sh -t Release — what
# scripts/build_dependencies.sh runs, and what deps/README.rst documents) unmodified, from a staged copy of
# the checkout's scripts/ deps/ patches/ include/, so the libraries are exactly the ones upstream links:
# OpenSSL, curl carrying Snowflake's OCSP/telemetry patches, zlib, uuid, the OOB telemetry lib, libxml2,
# the AWS and Azure SDKs, Boost, Arrow (+ its jemalloc), cmocka, picojson and toml++.
#
# Usage: deps.sh <stage-dir>      (stage-dir holds scripts/ deps/ patches/ include/; default: this
#                                  script's directory)
# Env:   DEPS_ROOT   install root (default /opt/toolchains/deps)
#        DEPS_JOBS   make parallelism (default nproc)
set -euo pipefail

STAGE="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")}" && pwd)"
DEPS_ROOT="${DEPS_ROOT:-/opt/toolchains/deps}"
JOBS="${DEPS_JOBS:-$(nproc)}"
OUT="$STAGE/deps-build/linux/Release"     # where upstream's scripts install (DEPENDENCY_DIR in _init.sh)
DONE="$STAGE/.done"; mkdir -p "$DONE"

# ---- pins ------------------------------------------------------------------------------------------
# Upstream's scripts fetch by tag/branch name; these are the commits/digests those names resolved to when
# this layer was written. A moved tag or a changed tarball fails the image build instead of silently
# changing what the fuzzers link.
OPENSSL_VER=3.5.7 ; OPENSSL_SHA=8cf17aaeb4599f8af87fefd810b5b5fee90fe69e          # openssl/openssl openssl-3.5.7
CURL_VER=8.21.0   ; CURL_SHA256=d9b327997999045a24cda50f3983e69e51c516bd8be6ef9842fc7f99135e33bb  # curl.se tarball
CJSON_VER=1.7.19  ; CJSON_SHA=c859b25da02955fef659d658b8f324b5cde87be3            # DaveGamble/cJSON v1.7.19
XML2_VER=2.15.3   ; XML2_SHA=c94eb0210183b9d7cb43f8e7fddc6be55843ef49             # gnome/libxml2 v2.15.3
AWS_VER=1.11.806  ; AWS_SHA=7b340699b752dd0d9a130dde1eb8bf0671f7418c              # aws/aws-sdk-cpp 1.11.806
AZURE_VER=12.18.0 ; AZURE_SHA=1c32f92de06445c467715b55860083202194aee4            # Azure/azure-sdk-for-cpp azure-storage-blobs_12.18.0
BOOST_VER=1.81.0  ; BOOST_SHA=17d98fc330b3dd0c794a25e09bc848f875fef44a            # snowflakedb/libsnowflakeclient deps/boost-1.81.0
ZLIB_VER=1.3.1 ; UUID_VER=2.39.0 ; OOB_VER=1.0.4 ; ARROW_VER=15.0.0 ; JEMALLOC_VER=5.3.0     # bundled in deps/
CMOCKA_VER=1.1.1 ; PICOJSON_VER=1.3.0 ; TOMLPP_VER=3.4.0                                     # bundled in deps/

# ---- compiler ----------------------------------------------------------------------------------------
# Upstream's scripts choose gcc/g++ by name and set their own CFLAGS, so the uniform way to build with the
# image's compiler and add debug info is a wrapper directory: gcc/cc -> clang, g++/c++ -> clang++, every
# compile with -g -gdwarf-3 (Mayhem's triage cannot read DWARF >= 4), so backtraces through a dependency
# resolve to /opt/toolchains/deps/<name>-<version>/src. DEPS_COMPILER=gcc builds with the real gcc instead.
WRAP="$STAGE/.wrap"; mkdir -p "$WRAP"
DEPS_COMPILER="${DEPS_COMPILER:-clang}"; DEPS_DEBUG_FLAGS="${DEPS_DEBUG_FLAGS:--g -gdwarf-3}"
case "$DEPS_COMPILER" in
  # -Wno-unknown-warning-option: upstream's scripts pass gcc-only -Wno-error=<warning> options, which
  # clang otherwise turns into errors under the SDKs' own -Werror.
  clang) real_c="$(command -v clang)"; real_cxx="$(command -v clang++)"
         DEPS_DEBUG_FLAGS="$DEPS_DEBUG_FLAGS -Wno-unknown-warning-option" ;;
  gcc)   real_c=/usr/bin/gcc;          real_cxx=/usr/bin/g++ ;;
  *) echo "deps.sh: DEPS_COMPILER must be clang or gcc" >&2; exit 2 ;;
esac
for c in gcc cc;  do printf '#!/bin/sh\nexec %s "$@" %s\n' "$real_c"   "$DEPS_DEBUG_FLAGS" > "$WRAP/$c"; chmod +x "$WRAP/$c"; done
for c in g++ c++; do printf '#!/bin/sh\nexec %s "$@" %s\n' "$real_cxx" "$DEPS_DEBUG_FLAGS" > "$WRAP/$c"; chmod +x "$WRAP/$c"; done

# The base image exports CC=clang/CXX=clang++; upstream's scripts expect to choose gcc themselves (curl's
# configure fails otherwise), so drop them. HOME is redirected so `git config --global` (build_curl.sh)
# leaves nothing behind in the image; the identity is for the throwaway commits build_curl.sh makes.
run() {  # run <script> [env assignments...]
  local script="$1"; shift
  env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      HOME="$STAGE/.home" PATH="$WRAP:$PATH" GCC="$WRAP/gcc" GXX="$WRAP/g++" \
      MAKEFLAGS="-j$JOBS" ARROW_FROM_SOURCE=1 \
      GIT_AUTHOR_NAME=mayhem GIT_AUTHOR_EMAIL=mayhem@localhost \
      GIT_COMMITTER_NAME=mayhem GIT_COMMITTER_EMAIL=mayhem@localhost \
      "$@" bash -e "$STAGE/scripts/$script" -t Release     # -e as in the scripts' own #!/bin/bash -e
}
step() {  # step <name> <command...>: run once; a re-run of this script resumes after the last finished step
  local name="$1"; shift
  [ -e "$DONE/$name" ] && return 0
  echo "=== deps.sh: $name ($(date -u +%H:%M:%S))"
  "$@" > "$STAGE/.log-$name" 2>&1 || { tail -60 "$STAGE/.log-$name"; echo "deps.sh: $name FAILED" >&2; exit 1; }
  touch "$DONE/$name"
}
pin_git() {  # pin_git <dir> <sha>
  local got; got="$(git -C "$1" rev-parse HEAD)"
  [ "$got" = "$2" ] || { echo "deps.sh: $1 is at $got, expected pinned $2" >&2; exit 1; }
}

trim() {  # trim <deps/ dir> [build subdirs...]: drop objects, build trees and VCS data once a step is installed
  local d="deps/$1"; shift
  [ -d "$d" ] || return 0
  local b; for b in "$@"; do rm -rf "${d:?}/$b"; done
  find "$d" \( -name .git -o -name .github \) -prune -exec rm -rf {} +
  find "$d" -type f \( -name '*.o' -o -name '*.lo' -o -name '*.a' -o -name '*.la' -o -name '*.so' -o -name '*.so.*' -o -name '*.d' \) -delete
  find "$d" -type f -perm -u+x -size +512k -exec sh -c 'head -c4 "$1" | grep -q ELF && rm -f "$1"' _ {} \;
}

mkdir -p "$STAGE/.home"
cd "$STAGE"
# build_curl.sh applies patches/curl-*.patch with `git apply` from the tree root, so the stage must be a repo.
[ -d .git ] || { git init -q . && git -c user.name=mayhem -c user.email=mayhem@localhost commit -q --allow-empty -m stage; }
printf '.done/\n.wrap/\n.home/\n.log-*\ndeps-build/\nartifacts/\n' > .git/info/exclude

curl_sha() { echo "$CURL_SHA256  deps/curl-$CURL_VER.tar.gz" | sha256sum -c -; }

step uuid         run build_uuid.sh
step openssl      run build_openssl.sh
step openssl.pin  pin_git deps/openssl "$OPENSSL_SHA"
step openssl.trim trim openssl test doc demos fuzz
step zlib         run build_zlib.sh
step oob          run build_oob.sh
step curl         run build_curl.sh
step curl.pin     curl_sha
step cjson.pin    pin_git "deps/cJSON-$CJSON_VER" "$CJSON_SHA"
# build_oob.sh/build_curl.sh patch this checkout in place for curl (patches/curl-cJSON-*.patch); put it
# back to the pristine tag, which is what mayhem/build.sh applies patches/libsfc-cJSON-*.patch to.
step cjson.reset  git -C "deps/cJSON-$CJSON_VER" reset -q --hard "$CJSON_SHA"
step curl.trim    trim curl
step cjson.trim   trim "cJSON-$CJSON_VER"
step xml2         run build_xml2.sh
step xml2.pin     pin_git deps/xml2 "$XML2_SHA"
step xml2.trim    trim xml2
step aws          run build_awssdk.sh
step aws.pin      pin_git "deps/aws-sdk-cpp-$AWS_VER" "$AWS_SHA"
step aws.trim     trim "aws-sdk-cpp-$AWS_VER" cmake-build-Release
# build_azuresdk.sh does `export CXXFLAGS+=$ADDITIONAL_CXXFLAGS` (no separator), hence the trailing space.
# -Wno-error=self-move: the SDK builds with -Werror, and newer compilers than upstream's warn on a self-move.
step azure        run build_azuresdk.sh CXXFLAGS="-Wno-error=self-move "
step azure.pin    pin_git deps/azure-sdk-for-cpp "$AZURE_SHA"
step azure.trim   trim azure-sdk-for-cpp cmake-build
step picojson     run build_picojson.sh
step cmocka       run build_cmocka.sh
# build_arrow.sh = build_boost_source.sh + build_arrow_source.sh (ARROW_FROM_SOURCE). Arrow's own build
# downloads jemalloc, pinned by sha256 in deps/arrow-15.0.0/cpp/thirdparty/versions.txt.
step arrow        run build_arrow.sh
step boost.pin    pin_git "deps/boost-$BOOST_VER" "$BOOST_SHA"
step boost.trim   trim "boost-$BOOST_VER" bin.v2 doc
step arrow.trim   trim "arrow-$ARROW_VER" cpp/cmake-build
step toml      run build_tomlplusplus.sh

# Upstream's scripts do not all stop on a failed make, so check for every archive the client links.
missing=0
for a in uuid/lib/libuuid.a openssl/lib/libssl.a openssl/lib/libcrypto.a zlib/lib/libz.a oob/lib/libtelemetry.a \
         curl/lib/libcurl.a xml2/lib/libxml2.a cmocka/lib/libcmocka.a arrow/lib64/libarrow.a \
         arrow_deps/lib/libjemalloc_pic.a boost/lib/libboost_filesystem.a boost/lib/libboost_regex.a \
         boost/lib/libboost_system.a boost/lib/libboost_url.a \
         azure/lib/libazure-core.a azure/lib/libazure-storage-common.a azure/lib/libazure-storage-blobs.a \
         aws/lib64/libaws-cpp-sdk-core.a aws/lib64/libaws-cpp-sdk-s3.a aws/lib64/libaws-cpp-sdk-sts.a \
         aws/lib64/libaws-crt-cpp.a aws/lib64/libaws-c-auth.a aws/lib64/libaws-c-cal.a aws/lib64/libaws-c-common.a \
         aws/lib64/libaws-c-compression.a aws/lib64/libaws-c-event-stream.a aws/lib64/libaws-checksums.a \
         aws/lib64/libaws-c-http.a aws/lib64/libaws-c-io.a aws/lib64/libaws-c-mqtt.a aws/lib64/libaws-c-s3.a \
         aws/lib64/libaws-c-sdkutils.a aws/lib64/libs2n.a \
         picojson/include/picojson.h tomlplusplus/include/toml++/toml.hpp; do
  [ -e "$DONE/layout" ] || [ -s "$OUT/$a" ] || { echo "deps.sh: missing $OUT/$a" >&2; missing=1; }
done
[ "$missing" = 0 ] || exit 1

# ---- lay the result out as /opt/toolchains/deps/<name>-<version>/{src,include,lib} --------------------
# place <name-version> <deps-build name|-> <stage deps/ source dir|->
place() {
  local d="$DEPS_ROOT/$1" built="$2" src="$3"
  mkdir -p "$d"
  if [ "$built" != - ]; then
    ( cd "$OUT/$built" && for e in include lib lib64; do [ -e "$e" ] && mv "$e" "$d/"; done; true )
    # upstream's CMakeLists.txt reads the AWS SDK and Arrow from lib64/; give every entry a lib/ as well
    [ -e "$d/lib" ] || [ ! -e "$d/lib64" ] || ln -s lib64 "$d/lib"
    rm -rf "${OUT:?}/$built"; ln -s "$d" "$OUT/$built"
  fi
  if [ "$src" != - ]; then
    rm -rf "$STAGE/deps/$src/.git"
    mv "$STAGE/deps/$src" "$d/src"
    ln -s "$d/src" "$STAGE/deps/$src"     # debug info recorded the stage path; keep it resolving
  fi
}
if [ ! -e "$DONE/layout" ]; then
  echo "=== deps.sh: layout"
  # Trim what the sources carry beyond source: build trees, objects, VCS data, and the ~400 AWS service
  # clients upstream's -DBUILD_ONLY="s3;sts" never compiles.
  rm -rf deps/aws-sdk-cpp-$AWS_VER/cmake-build-Release deps/azure-sdk-for-cpp/cmake-build \
         deps/arrow-$ARROW_VER/cpp/cmake-build deps/boost-$BOOST_VER/bin.v2 deps/cmocka-$CMOCKA_VER/cmake-build-Release \
         deps/curl-$CURL_VER.tar.gz /tmp/cmocka
  find deps/aws-sdk-cpp-$AWS_VER/generated/src -mindepth 1 -maxdepth 1 -type d \
       ! -name aws-cpp-sdk-s3 ! -name aws-cpp-sdk-sts -exec rm -rf {} +
  rm -rf deps/aws-sdk-cpp-$AWS_VER/generated/tests deps/aws-sdk-cpp-$AWS_VER/tools/code-generation
  find deps \( -name .git -o -name .github \) -prune -exec rm -rf {} +
  find deps -type f \( -name '*.o' -o -name '*.lo' -o -name '*.a' -o -name '*.la' -o -name '*.so' -o -name '*.so.*' -o -name '*.d' \) -delete
  # Static archives only: tiers that lock /opt/toolchains cannot load a .so (OpenSSL's fips/legacy provider
  # modules and cmocka's shared lib are not linked by anything here).
  find "$OUT" \( -name '*.so' -o -name '*.so.*' \) -delete
  rm -rf "$OUT"/openssl/lib/ossl-modules "$OUT"/openssl/lib/engines-3

  place "openssl-$OPENSSL_VER"            openssl      openssl
  place "curl-$CURL_VER"                  curl         curl
  place "zlib-$ZLIB_VER"                  zlib         "zlib-$ZLIB_VER"
  place "uuid-$UUID_VER"                  uuid         uuid
  place "oob-$OOB_VER"                    oob          "oob-$OOB_VER"
  place "libxml2-$XML2_VER"               xml2         xml2
  place "aws-sdk-cpp-$AWS_VER"            aws          "aws-sdk-cpp-$AWS_VER"
  place "azure-sdk-for-cpp-$AZURE_VER"    azure        azure-sdk-for-cpp
  place "boost-$BOOST_VER"                boost        "boost-$BOOST_VER"
  place "arrow-$ARROW_VER"                arrow        "arrow-$ARROW_VER"
  place "jemalloc-$JEMALLOC_VER"          arrow_deps   -
  place "cmocka-$CMOCKA_VER"              cmocka       "cmocka-$CMOCKA_VER"
  place "picojson-$PICOJSON_VER"          picojson     picojson
  place "tomlplusplus-$TOMLPP_VER"        tomlplusplus tomlplusplus
  place "cJSON-$CJSON_VER"                -            "cJSON-$CJSON_VER"

  # What mayhem/build.sh links ./deps-build to: upstream's CMakeLists.txt finds every dependency at
  # deps-build/linux/Release/<name>/{include,lib}, so this is that tree, as symlinks into the entries above.
  mkdir -p "$DEPS_ROOT/libsnowflakeclient-deps-build/linux"
  mv "$OUT" "$DEPS_ROOT/libsnowflakeclient-deps-build/linux/Release"
  rm -rf "$STAGE/deps-build" "$STAGE/artifacts" "$STAGE/.home" "$STAGE/.wrap" "$STAGE/.git"
  if find "$DEPS_ROOT" \( -name '*.so' -o -name '*.so.*' \) | grep -q .; then
    echo "deps.sh: shared objects left under $DEPS_ROOT" >&2; exit 1
  fi
  chmod -R a+rX,go-w "$DEPS_ROOT"
  touch "$DONE/layout"
fi
echo "=== deps.sh: done"; du -sh "$DEPS_ROOT"/* 2>/dev/null || true
