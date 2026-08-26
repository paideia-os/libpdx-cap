# tests/

libpdx-cap M4 test-suite: two witness functions covering the
correctness matrix defined in `design/tooling/r49-r50-plan.md`
§5.10 in paideia-os.

## Witness functions

| File                            | Symbol                          | Milestone | What it proves                                                                                                     |
|---------------------------------|---------------------------------|-----------|--------------------------------------------------------------------------------------------------------------------|
| `m4_001_roundtrip_fuzz.pdx`     | `m4_001_roundtrip_fuzz`         | M4-001    | `cap_pack` + `cap_unpack` round-trip preserves all four wire lanes across 10^6 LCG-derived cap shapes.             |
| `m4_002_caps_decl_matrix.pdx`   | `m4_002_caps_decl_matrix`       | M4-002    | 30-stage matrix: caps.decl parse-error corpus + narrowing-invariant matrix + extra-cap rejection + signed-inode + slot-bound coverage. |

Both are pure userspace, non-leaf, self-contained. Each function
returns `0` on all-pass, or a diagnostic index on the first failure
(the 1-based iteration index for M4-001; the 1-based stage index
for M4-002). A caller can also read the module's `.bss` diagnostic
slots (`_m4rf_fail_iter` + `_m4rf_fail_field` for M4-001;
`_m4mx_stage` for M4-002) after the return.

## Fingerprint contracts

### M4-001 — `m4_001_roundtrip_fuzz() -> u64`

- `0` — all 10^6 iterations round-tripped without divergence.
- `N` — 1-based iteration index of the first divergence.
- `_m4rf_fail_iter`  mirrors the return value.
- `_m4rf_fail_field` names the lane that diverged:
  - `0` = slot
  - `1` = kind
  - `2` = rights
  - `3` = target_ptr
  - `4` = `cap_pack` returned non-`CAP_OK`
  - `5` = `cap_unpack` returned non-`CAP_OK`

The LCG is fully deterministic (Knuth 64-bit MMIX with seed
`M4RF_LCG_SEED = 0xC0FFEE5EA5CAB1E7`); a reproducer harness can
advance the LCG `N-1` times from the seed to re-derive the
offending iteration's `(slot, kind, rights, target_ptr)` tuple.

### M4-002 — `m4_002_caps_decl_matrix() -> u64`

- `0` — every stage passed.
- `N` — 1-based stage index of the first failure. The stage's
  meaning is documented in the corresponding
  `// ---- Stage N: <desc>` comment in the function body.
- `_m4mx_stage` mirrors the return value.

The 30 stages cover five sub-corpora:

| Range     | Sub-corpus                    | Fixtures / cases                                                                                    |
|-----------|-------------------------------|-----------------------------------------------------------------------------------------------------|
| S1..S8    | Parse-error corpus            | OK inline, OK one-item, MALFORMED_HEADER x2, ITEM_OUT_OF_SECTION, MALFORMED_ITEM, REQ_OVERFLOW, SCHEMA_OVERFLOW |
| S9..S12   | Narrowing invariant           | subset OK, equal OK, superset WIDENING, empty-orig any-narrow WIDENING                              |
| S13..S17  | Extra-cap rejection           | `cap_unpack_checked` EXTRA + OK; `cap_manifest_verify` MISSING + EXTRA + KIND_UNKNOWN               |
| S18..S22  | Signed-inode re-sign          | KEY_LOCKED after reset; OK after set(1); has_signature+mark_unsigned round-trip; BAD_INODE fail-fast (x2) |
| S23..S30  | Slot-bound coverage           | `cap_pack` + `cap_pack_narrowed`, each: slot=255 accept, slot=256/0xFFFF/2^63 CAP_BAD_SLOT with dst asserted untouched (libpdx-cap#14, regression guard for #13) |

## Runnable harness (ENH-006 / libpdx-cap#15)

`tests/harness.pdx` + `tools/run-tests.sh` actually RUN both
witnesses, closing the credibility gap the section below used to
describe ("libpdx-cap has no test harness of its own"). Before
ENH-006, `tools/build.sh` only assembled each `.pdx` to a
standalone `.o`; nothing linked or executed anything, so the
CHANGELOG's "10^6 LCG-driven iterations" claim had executed zero
iterations.

`bash tools/run-tests.sh` links every `src/*.pdx` module plus
`tests/harness.pdx`'s two witness objects into one hosted ELF64
executable (via `ld`; libpdx-cap's SC+ syscall IDs — `sys_write`
= 1, `sys_exit` = 60 — are also the native Linux x86-64 syscall
numbers, so the linked image runs directly, no paideia-os kernel
or QEMU involved) and runs it:

- Exit `0` — both witnesses returned `0`. Prints a `PASS:` line.
- Exit `1` — `m4_001_roundtrip_fuzz` diverged. Prints
  `M4-001 FAIL iter=<N>` (the 1-based iteration index, decimal)
  before exiting.
- Exit `2` — `m4_002_caps_decl_matrix` failed. Prints
  `M4-002 FAIL stage=<N>` (the 1-based stage index, decimal)
  before exiting.

Running this harness for the first time is what caught
`caps_decl_parse`'s item-boundary bug (libpdx-cap#15 fix, same
commit): NUL-terminating a list item at its `'\n'` boundary
destroyed the very sentinel the old post-item scan needed, so
every OTHER item in a 2+-item `requires:` / `declares_output_schemas:`
section was silently dropped without error. Every caps.decl with
2+ items in either section was affected; the M4-002 witness
itself (stage 7, `REQ_OVERFLOW`) is what surfaced it, and only
because this harness finally executed it.

## Consumer contract

The two witness functions are:

- Inspectable — reviewers can read the assertion sequence
  line-by-line to confirm coverage.
- Callable — any userspace program that links libpdx-cap can
  `call m4_001_roundtrip_fuzz` and `call m4_002_caps_decl_matrix`
  from its `_start` and check `rax` after each — exactly what
  `tests/harness.pdx` does.
- Re-runnable — every fixture in `m4_002_*.pdx` is idempotent
  under repeated parse (see the module header's "Fixtures"
  section for the invariant that makes this work). M4-001 is
  seed-deterministic, so a re-run produces the same lane trace.

## Test fixtures

Every caps.decl fixture is a `pub let mut [u8; N]` initialized
from a string literal — `.data` (mutable initialized), not
`.rodata` — because `CapsDecl::caps_decl_parse` NUL-terminates
each list-item identifier in place at its boundary byte. Writing
into `.rodata` would fault; writing into `.data` is safe. The
fixtures are still idempotent under repeated parse per the walker
analysis in `m4_002_caps_decl_matrix.pdx`'s header.
