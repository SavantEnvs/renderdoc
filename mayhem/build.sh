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

# RenderDoc is built as the shared library librenderdoc.so (only the public C API is exported). The harness
# links it for the RENDERDOC_* calls the config loader makes. The Qt UI as a whole and the Python bindings
# are not built (step 2 builds only the loader's sources). ENABLE_ASAN only adds the compile flags and skips -Wl,--no-undefined on the shared library,
# which the sanitizer runtimes need; it follows $SANITIZER_FLAGS so an empty value builds without it.
# The compiler comes from the exported CC/CXX (by name), not -DCMAKE_CXX_COMPILER: a re-run that resolves it
# through a different PATH would otherwise make CMake wipe the cache and drop the -D options below.
ASAN=OFF
case "$SANITIZER_FLAGS" in *address*) ASAN=ON ;; esac

# 1) Sanitized + SanCov library. -fno-sanitize=nonnull-attribute,pointer-overflow: upstream's rdcarray.h does
#    memcpy(dst, NULL, 0) for every empty array copy, and the bundled zstd adds a zero offset to NULL (both benign, and they fire on every capture).
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=nonnull-attribute,pointer-overflow"
cmake -S . -B build-fuzz -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DCMAKE_C_FLAGS_RELEASE="-O1" -DCMAKE_CXX_FLAGS_RELEASE="-O1" \
  -DCMAKE_SHARED_LINKER_FLAGS="$SANITIZER_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
  -DENABLE_ASAN="$ASAN" -DENABLE_QRENDERDOC=OFF -DENABLE_PYRENDERDOC=OFF
cmake --build build-fuzz --target renderdoc -j"$MAYHEM_JOBS"

# 2) The harness: a libFuzzer binary and a run-once standalone reproducer, both with LSan switched off.
#    It links qrenderdoc's real configuration loader (PersistantConfig and the sources it calls into),
#    compiled with the same sanitizer and SanCov flags as the library, against the system Qt5 (left
#    uninstrumented). The rest of the GUI is not built: those are the only qrenderdoc sources the loader needs.
#    -DRELEASE=1 leaves the Catch unit-test sections of those sources out; they have no use in a fuzz binary.
QT_CFLAGS="$(pkg-config --cflags Qt5Widgets Qt5Core Qt5Gui)"
QT_LIBS="$(pkg-config --libs Qt5Widgets Qt5Core Qt5Gui)"
QFLAGS="$FUZZ_FLAGS -O1 -std=c++14 -fPIC -w -DQT_NO_CAST_FROM_ASCII -DQT_NO_CAST_TO_ASCII -DRELEASE=1 -DRENDERDOC_PLATFORM_LINUX -DRENDERDOC_PLATFORM_POSIX -Iqrenderdoc -Iqrenderdoc/Code -Iqrenderdoc/3rdparty -Irenderdoc/api/replay -Irenderdoc/api $QT_CFLAGS"
MOCFLAGS="-DRELEASE=1 -DRENDERDOC_PLATFORM_LINUX -DRENDERDOC_PLATFORM_POSIX -Iqrenderdoc -Iqrenderdoc/Code -Iqrenderdoc/3rdparty -Irenderdoc/api/replay -Irenderdoc/api $QT_CFLAGS"
QSRC="qrenderdoc/Code/Interface/PersistantConfig.cpp qrenderdoc/Code/Interface/RemoteHost.cpp qrenderdoc/Code/QRDUtils.cpp
  qrenderdoc/Code/BufferFormatter.cpp qrenderdoc/Code/Resources.cpp qrenderdoc/Styles/StyleData.cpp
  qrenderdoc/Styles/RDStyle/RDStyle.cpp qrenderdoc/Styles/RDTweakedNativeStyle/RDTweakedNativeStyle.cpp
  qrenderdoc/Widgets/Extended/RDListWidget.cpp qrenderdoc/Widgets/Extended/RDTreeWidget.cpp
  qrenderdoc/Widgets/Extended/RDTreeView.cpp"
QMOC="qrenderdoc/Code/QRDUtils.h qrenderdoc/Styles/RDStyle/RDStyle.h qrenderdoc/Styles/RDTweakedNativeStyle/RDTweakedNativeStyle.h
  qrenderdoc/Widgets/Extended/RDListWidget.h qrenderdoc/Widgets/Extended/RDTreeWidget.h qrenderdoc/Widgets/Extended/RDTreeView.h"
QDIR=build-fuzz/qrd
mkdir -p "$QDIR"
for h in $QMOC; do
  moc $MOCFLAGS "$h" -o "$QDIR/moc_$(basename "$h" .h).cpp"
  QSRC="$QSRC $QDIR/moc_$(basename "$h" .h).cpp"
done
QOBJ=""
for s in $QSRC; do QOBJ="$QOBJ $QDIR/$(echo "$s" | tr '/' '_').o"; done
for s in $QSRC; do
  echo "$CXX $QFLAGS -c $s -o $QDIR/$(echo "$s" | tr '/' '_').o"
done | xargs -P "$MAYHEM_JOBS" -I{} sh -c '{}'

HFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=nonnull-attribute,pointer-overflow -std=c++14 -fPIC -w -DRELEASE=1 -Iqrenderdoc -Iqrenderdoc/Code -Iqrenderdoc/3rdparty -Irenderdoc/api -Irenderdoc/api/replay -DRENDERDOC_PLATFORM_LINUX -DRENDERDOC_PLATFORM_POSIX $QT_CFLAGS"
LIBS="-rdynamic -Lbuild-fuzz/lib -lrenderdoc -Wl,-rpath,$SRC/build-fuzz/lib $QT_LIBS"
$CXX $HFLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
t=fuzz_config
$CXX $HFLAGS $LIB_FUZZING_ENGINE mayhem/$t.cpp $QOBJ /tmp/lsan_off.o $LIBS -o "$SRC/$t"
$CXX $HFLAGS mayhem/$t.cpp $QOBJ /tmp/standalone_main.o /tmp/lsan_off.o $LIBS -o "$SRC/$t-standalone"

# 3) The project's own unit tests (Catch, compiled into renderdoccmd in a non-release build), with normal flags.
cmake -S . -B build-tests -G Ninja -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DENABLE_QRENDERDOC=OFF -DENABLE_PYRENDERDOC=OFF
cmake --build build-tests --target renderdoccmd -j"$MAYHEM_JOBS"
