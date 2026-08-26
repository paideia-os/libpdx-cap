#!/usr/bin/env bash
# tools/run-tests.sh — libpdx-cap.ENH-006
#
# Ships the runnable test harness ENH-006 exists to add: links the two
# M4 witnesses (tests/m4_001_roundtrip_fuzz.pdx,
# tests/m4_002_caps_decl_matrix.pdx) plus every src/*.pdx module and
# tests/harness.pdx into ONE hosted ELF64 executable, then actually
# RUNS it and checks its exit status. Before this script existed,
# tools/build.sh only assembled each .pdx to a standalone .o and never
# linked or executed anything — the M4 gate was closed "by the
# existence + shape" of the two witnesses, never by evidence they ran.
#
# Why a hosted ELF (not QEMU / not the paideia-os kernel): libpdx-cap's
# SC+ syscall IDs are deliberately the same numbers paideia-os userland
# uses (sys_write = 1, sys_exit = 60 — see src/user/true.pdx in
# paideia-os), which are ALSO the native Linux x86-64 syscall numbers.
# paideia-as's `--emit elf64` output is a standard relocatable ELF64
# object with unmangled global symbols (verified: `readelf -s` on a
# built .o shows plain `FUNC GLOBAL` / `OBJECT WEAK` symbols, no name
# mangling), so the objects link with an ordinary System V linker
# (`ld`) into a normal static executable that runs directly on this
# host — no paideia-os kernel, no loader, no QEMU. This script is
# therefore a plain userspace build+link+run step, not a paideia-os
# build or boot smoke.
#
# Requires paideia-as >= 0.21.0, resolved the same way tools/build.sh
# does, plus a working `ld` (binutils) on PATH.

set -euo pipefail
cd "$(dirname "$0")/.."

MIN_VERSION="0.21.0"

resolve_paideia_as() {
    if [ -n "${PAIDEIA_AS:-}" ] && [ -x "$PAIDEIA_AS" ]; then
        echo "$PAIDEIA_AS"; return
    fi
    for cand in \
        "../paideia-os/tools/paideia-as/target/release/paideia-as" \
        "$HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as"
    do
        if [ -x "$cand" ]; then
            echo "$cand"; return
        fi
    done
    if command -v paideia-as >/dev/null 2>&1; then
        command -v paideia-as; return
    fi
    return 1
}

version_ge() {
    # $1 = have, $2 = want ; returns 0 if have >= want
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

PA="$(resolve_paideia_as || true)"
if [ -z "$PA" ]; then
    echo "[run-tests] FAIL: paideia-as not found. Set PAIDEIA_AS or clone paideia-os as a sibling." >&2
    exit 2
fi
VER="$("$PA" --version | awk '{print $2}')"
if ! version_ge "$VER" "$MIN_VERSION"; then
    echo "[run-tests] FAIL: paideia-as $VER is too old, need >= $MIN_VERSION (found $PA)" >&2
    exit 2
fi
if ! command -v ld >/dev/null 2>&1; then
    echo "[run-tests] FAIL: 'ld' not found on PATH (binutils required to link the harness)." >&2
    exit 2
fi
echo "[run-tests] paideia-as $VER at $PA"

BUILD_DIR="build-out"
mkdir -p "$BUILD_DIR"

OBJS=()
for pdx in src/*.pdx tests/*.pdx; do
    [ -f "$pdx" ] || continue
    obj="$BUILD_DIR/harness-$(basename "$pdx" .pdx).o"
    "$PA" build --emit elf64 "$pdx" -o "$obj"
    OBJS+=("$obj")
done

HARNESS_BIN="$BUILD_DIR/harness"
ld -static -o "$HARNESS_BIN" "${OBJS[@]}"
echo "[run-tests] linked $HARNESS_BIN from ${#OBJS[@]} object(s)"

set +e
"$HARNESS_BIN"
RC=$?
set -e

case "$RC" in
    0)
        echo "[run-tests] OK: both M4 witnesses returned 0"
        ;;
    1)
        echo "[run-tests] FAIL: m4_001_roundtrip_fuzz diverged (see iteration index printed above)" >&2
        ;;
    2)
        echo "[run-tests] FAIL: m4_002_caps_decl_matrix failed (see stage index printed above)" >&2
        ;;
    *)
        echo "[run-tests] FAIL: harness exited $RC (unexpected — expected 0, 1, or 2)" >&2
        ;;
esac

exit "$RC"
