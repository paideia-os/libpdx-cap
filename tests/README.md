# tests/

libpdx-cap M4 test-suite: witness functions covering the correctness
matrix defined in `design/tooling/r49-r50-plan.md` §5.10 in paideia-os.

## Witness functions

| File                            | Symbol                          | Milestone | What it proves                                                                                                     |
|---------------------------------|---------------------------------|-----------|--------------------------------------------------------------------------------------------------------------------|
| `m4_001_roundtrip_fuzz.pdx`     | `m4_001_roundtrip_fuzz`         | M4-001    | `cap_pack` + `cap_unpack` round-trip preserves all four wire lanes across 10^6 LCG-derived cap shapes.             |

Pure userspace, non-leaf, self-contained. Returns `0` on all-pass,
or a diagnostic index on the first failure (the 1-based iteration
index for M4-001). A caller can also read the module's `.bss`
diagnostic slots (`_m4rf_fail_iter` + `_m4rf_fail_field`) after
the return.

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

## Consumer contract

libpdx-cap has no test harness of its own — the wave-level harness
(per `design/tooling/r49-r50-plan.md` §5.10) is delivered by the
first R49-wave tool that adopts libpdx-cap. Until that tool ships,
the M4 witnesses are:

- Inspectable — reviewers can read the assertion sequence line-by-line.
- Callable — any userspace program that links libpdx-cap can
  `call m4_001_roundtrip_fuzz` from its `_start` and check `rax`.
- Re-runnable — M4-001 is seed-deterministic, so a re-run produces
  the same lane trace.

The M4 gate is closed by the existence + shape of these witnesses;
a first consumer bringing up its own smoke tree will add a harness
that invokes them and produces a fingerprint line on serial (or a
syscall-exit code in a future test runtime).

## Coming with M4-002

`libpdx-cap.M4-002` will add a companion witness
`m4_002_caps_decl_matrix` covering: caps.decl parse-error corpus,
narrowing invariant matrix, extra-cap rejection, and signed-inode
re-sign correctness.
