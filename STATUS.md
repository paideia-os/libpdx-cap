# libpdx-cap — status

**Wave:** R49 shared library
**Current milestone:** M4 (test suite / smoke fixtures) — M4-001
LANDED. M4-002 in flight.

## Milestone rollup

| ID              | Title                                                                          | State  |
|-----------------|--------------------------------------------------------------------------------|--------|
| M1-001 (#1)     | scaffold + module boundary (cap_pack, cap_unpack, cap_manifest_verify)         | LANDED |
| M1-002 (#2)     | caps.decl parser (per design/tooling/plan.md invariant I6)                     | LANDED |
| M2-001 (#3)     | cap_manifest_verify: OK | MISSING | EXTRA against callee caps.decl              | LANDED |
| M2-002 (#4)     | rights-narrowing at send site (widening → reject)                              | LANDED |
| M2-003 (#5)     | rights-check at receive site (extra cap → reject)                              | LANDED |
| M3-001 (#6)     | KIND_USER_ref decode helpers for ls --long owner rendering                     | LANDED |
| M3-002 (#7)     | signed-inode helpers (re-sign under invoker user_sk if unlocked)               | LANDED |
| M4-001 (#8)     | round-trip fuzz (10^6 random cap shapes)                                       | LANDED |
| M4-002 (#9)     | caps.decl parse-error corpus + narrowing/extra-cap invariant matrix            | OPEN   |

See `design/tooling/r49-r50-plan.md` §5.10 in paideia-os for the full
milestone breakdown (M1–M5) and cross-repo dependencies.

## M3 summary

### M3-001 (KIND_USER_ref decode + rights-args-text + KIND_TTY row)

- `src/kind_user_ref.pdx` (NEW) — `KindUserRef` module with
  `kind_user_ref_decode(wire_ptr) → rc` (populates
  `user_ref_{row_id, slot, rights, raw_target}` singletons on OK;
  UNTOUCHED on WRONG_KIND or BAD_ROW per fail-fast discipline), plus
  `kind_user_ref_render_hex(user_key) → 16` (renders a fingerprint
  word into a 17-byte `user_ref_hex_buf` with trailing NUL). New
  return codes `USER_REF_WRONG_KIND = 0xFFFFFFF3` and
  `USER_REF_BAD_ROW = 0xFFFFFFF2`.
- `src/kind_names.pdx` — added Row 15 `KIND_TTY = 0x197` and
  `_kn_str_tty` literal now that paideia-os cf496fb (R30-PREP #1631)
  pinned the ordinal. `shell`, `doc`, `ls`, `cat` — all of which
  declare `KIND_TTY` in `caps.decl` — pass `cap_manifest_verify`'s
  Pass 1 without the M2-scope `CAP_KIND_UNKNOWN` fallback.
- `src/caps_decl.pdx` — added the two rights-args-text helpers
  `caps_decl_args_has(args_ptr, needle_ptr)` (bare-token membership)
  and `caps_decl_args_get(args_ptr, key_ptr)` (key=value lookup, with
  singleton `caps_decl_args_value_ptr` + `_len`). Both are leaf,
  fail-fast on `args_ptr == 0`, and share the walker shape defined in
  the module header addendum.
- `design/architecture.md`: §1 (public-surface expanded; KindUserRef
  named), §5 (return-code table extended with the two new codes),
  §7 (KindNames row table now 15 rows with KIND_TTY row), §8
  (KIND_USER_ref exclusion marked ✓ landed at M3-001), §9 (NEW —
  KindUserRef consumer flow + why decode + render are split),
  §4 addendum (rights-args-text helpers).

### M3-002 (signed-inode helpers)

- `src/signed_inode.pdx` (NEW) — `SignedInode` module publishing the
  PdxFS v1 signed-inode layout constants
  (`INODE_HEAD_BYTES = 64`, `SIG_PRESENT_OFFSET = 64`,
  `SIG_BODY_OFFSET = 65`, `ML_DSA_65_SIG_LEN = 3309`,
  `SIGNED_INODE_TOTAL_BYTES = 3374`), a `signed_inode_key_state`
  singleton the consumer sets after unlocking `user_sk`, and five
  entry points: `signed_inode_key_state_reset`, `_set(state)`,
  `signed_inode_has_signature(inode_ptr)`, `signed_inode_can_resign()`,
  `signed_inode_mark_unsigned(dst_inode_ptr)`. New return codes
  `SIGNED_INODE_SIG_ABSENT = 0xFFFFFFF1`,
  `SIGNED_INODE_KEY_LOCKED = 0xFFFFFFF0`,
  `SIGNED_INODE_BAD_INODE = 0xFFFFFFEF`.
- Explicitly OUT of scope for M3-002: the ML-DSA-65 sign primitive
  itself (a paideia-as v0.33-crypto intrinsic whose userspace linkage
  is a paideia-as-team deliverable). cp/mv/rm wire the DEGRADE path
  (has_signature + can_resign + mark_unsigned) today; the RE-SIGN
  branch becomes a real code path when the intrinsic ships.
- `design/architecture.md`: §1 (SignedInode named alongside
  KindUserRef; "five modules" count), §5 (three new return codes),
  §8 (signed-inode exclusion marked ✓ landed at M3-002), §10 (NEW —
  SignedInode layout + consumer degrade path + explicit non-goals).

## M4 summary (partial — through M4-001)

### M4-001 (round-trip fuzz)

- `tests/m4_001_roundtrip_fuzz.pdx` (NEW) — `M4RoundtripFuzz`
  module with witness `m4_001_roundtrip_fuzz` (10^6 LCG-driven
  `cap_pack` + `cap_unpack` iterations). Fingerprint contract:
  `rax == 0` on all-pass; else the 1-based iteration index of
  the first divergence. Companion diagnostic slots
  `_m4rf_fail_iter` + `_m4rf_fail_field` (lane id: 0=slot,
  1=kind, 2=rights, 3=target_ptr, 4=pack_rc, 5=unpack_rc).
- `tests/README.md` — describes the M4-001 fingerprint contract
  + the six lane-id values M4-001 can report.
- LCG parameters (Knuth 64-bit MMIX; Numerical Recipes 3rd ed.,
  Table 7.1.1) are `pub let` constants so a reproducer harness
  can re-derive the offending iteration's inputs from
  `M4RF_LCG_SEED = 0xC0FFEE5EA5CAB1E7` by advancing the LCG
  `N-1` times.

## Consumer wiring (after M3)

Every R49-wave tool now wires libpdx-cap into its exec path per
`design/architecture.md` §1: parse own caps.decl at `_start` →
`cap_unpack_checked` on each received cap → `cap_manifest_verify` once
after every cap has landed → `cap_pack_narrowed` at each `shell → child`
handoff to prevent widening. `ls --long` additionally uses
`kind_user_ref_decode` + `kind_user_ref_render_hex` for the owner
column (M3-001). Consumers whose caps.decl carries rights-args-text
refinements (subtree=…, mode=…) use `caps_decl_args_has` +
`caps_decl_args_get` (M3-001) to compare received rights-args at
exec. cp/mv/rm use `SignedInode::signed_inode_has_signature` +
`signed_inode_can_resign` + `signed_inode_mark_unsigned` (M3-002)
to preserve or degrade destination-inode signatures per PdxFS v1
layout constants published by the module.
