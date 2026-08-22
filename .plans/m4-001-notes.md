# libpdx-cap.M4-001 — implementation notes

**Issue:** #8
**Status:** LANDED

## What landed

- `tests/m4_001_roundtrip_fuzz.pdx` (NEW) — `M4RoundtripFuzz`
  module publishing the witness function `m4_001_roundtrip_fuzz`
  and three seed constants (`M4RF_LCG_MULT`, `M4RF_LCG_INCR`,
  `M4RF_LCG_SEED`) plus two diagnostic slots (`_m4rf_fail_iter`,
  `_m4rf_fail_field`) and a 16-byte wire buffer
  (`_m4rf_wire_buf`).

- `tests/README.md` — describes the fingerprint contract for both
  M4 witnesses; lists the four lane-id values M4-001 can report.

## Design decisions

### Runtime LCG loop, not source-time corpus

The plan rubric names "10^6 random cap shapes". Two ways to
honour that:

1. Source-time corpus — hand-write (or code-generate) 10^6
   `(slot, kind, rights, target_ptr)` tuples as `.rodata`
   constants and iterate. Rejected: 10^6 × 32 bytes = 32 MB of
   `.rodata` doubles the library's on-disk footprint. Reviewers
   cannot inspect a 32 MB corpus by reading source.

2. **Runtime LCG (chosen).** A 64-bit LCG advances state in three
   x86-64 instructions per iteration; deriving `(slot, kind,
   rights, target_ptr)` is another six. The whole loop runs
   ~30M ops on modern silicon — well under a second — and the
   source stays under 400 lines including the header block.

The Knuth 64-bit MMIX LCG (Numerical Recipes 3rd ed., Table 7.1.1)
has full period `2^64` and passes standard uniformity tests to
much higher than the 10^6 samples we draw. Any bit-level regression
in the pack/unpack lane packing (e.g. an off-by-one shift or a
mask that leaks into an adjacent lane) surfaces at or before
iteration 10^6 with overwhelming probability.

### Fixed seed, published constant

`M4RF_LCG_SEED = 0xC0FFEE5EA5CAB1E7` is a `pub let` constant so a
reproducer harness that observes a failure at iteration `N` can
advance the LCG `N-1` times from the seed and compute the exact
inputs `cap_pack` was called with. A truly random seed would be
faster to file spurious bugs against but harder to reproduce; the
plan doc explicitly names determinism as a goal at §5.10 M4
("preserved" not "sampled").

### Lane recomputation from rbx, no shadow storage

The naive path saves `(slot, kind, rights, target_ptr)` into
`.bss` slots after computing them (before the `cap_pack` call)
and re-loads them after `cap_unpack` for comparison. That works
but adds 4 loads + 4 stores per iteration.

Instead: `rbx` holds the LCG state, is callee-save, and is
preserved across `cap_pack` and `cap_unpack` (both are leaf
functions per their published register plans — cap_pack touches
only `rax`, `r10`, `r11` and its input regs; cap_unpack touches
only `rax`, `r9`, `r10`, `r11` and its input reg). After
`cap_unpack` returns, the same shift-and-mask lane derivation
re-runs to produce the expected value, and the `cmp` compares
against `unpacked_*`. This saves ~30M memory accesses across the
full run.

### Odd-number callee-save push count

`m4_001_roundtrip_fuzz` uses 3 callee-save pushes (rbx, r12, r13).
Entry rsp % 16 == 8; three pushes shift to rsp % 16 == 0, which
is the SysV-required alignment at every nested `call`. Even-count
push would need a `sub rsp, 8` pad; odd count without a pad is the
same idiom `kind_names_resolve` uses (one push, entry 8 → 0 at
call sites).

### Lane-id vocabulary

`_m4rf_fail_field` carries 0..5 to distinguish which of the four
wire lanes diverged, plus the two operation-level failures
(`cap_pack` and `cap_unpack` returning non-`CAP_OK`). This lets a
regression triage jump straight to the failing check without a
bisection over the round-trip. The vocabulary is documented in
the module header AND in `tests/README.md`.

### `imul rbx, r11` is the 2-operand truncated form

paideia-as ships `imul reg, reg` as a 64x64→64 truncated multiply
(see `src/kernel/core/time/tsc.pdx` line 190 and
`hpet.pdx` line 263 for precedent). The LCG advance
`state = state * mult + incr` is exactly this: `imul rbx, r11;
add rbx, r11` (with the multiplier and increment staged into r11
in turn). No `mul r11` (single-operand unsigned) is needed
because we don't care about the high 64 bits — LCGs sample the
low bits and the top bits carry no signal.

## paideia-as conformance checklist

- Module name PascalCase basename (`M4RoundtripFuzz`): yes.
- No `test` mnemonic: every zero-check uses `cmp rax, 0` or
  `cmp reg, imm` with small imm; the `cmp r12, r13` loop-head is
  reg-reg.
- `cmp reg, imm ≤ 0x7FFFFFFF`: yes — direct compare imms are
  `0`, `0xFF`, `0xFFFF`; the LCG multiplier + increment + seed
  and the iteration count are all staged via `mov r11, imm`
  before use as arithmetic operands.
- Large-imm return: N/A — the function returns iteration index
  (u64 up to 10^6, fits imm32) or 0.
- `r11` scratch: yes — used both for imm staging AND for LEA of
  the .bss diagnostic + wire buffer slots.
- Byte reads: N/A — every wire-buffer access is via `cap_pack`
  and `cap_unpack`, both qword-oriented.
- SysV push/pop parity: 3 pushes (rbx, r12, r13) with matched
  pops on both exits (all-pass and record-fail).

## What's next

- M5-001 dual-signed release + `.pdxdoc` for `doc libpdx-cap` +
  mirror push. The witness functions become the first `.pdxdoc`
  "examples" section — `doc libpdx-cap` pulls their fingerprints
  and shows the acceptance criteria.
- The first R49-wave tool to link libpdx-cap (`shell` at §5.2 or
  `pkg` at §5.1) adds a smoke wrapper that invokes both
  witnesses at build time and asserts `rax == 0`. Failure surfaces
  as the standard "libpdx-cap M4 regression" exit code the
  wave-level CI catches.
