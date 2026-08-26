# libpdx-cap — status

**Wave:** R49 shared library
**Current milestone:** Enhancement v1.x — libpdx-cap (ENH-001..009) —
CLOSED except ENH-008 (#18, deferred pending a confirmed `shell`
fan-out need).
**Released:** 1.0.1 (2026-08-25). **1.0.0 is WITHDRAWN** — that tag's
tree does not assemble (missing `;` at `src/cap.pdx:214`, fixed three
commits later). See `CHANGELOG.md`'s 1.0.1 entry for the full fix list:
signed-jge slot-bound fail-open (#13), unwired CAP_BAD_KIND (#17),
unreachable SIGNED_INODE_SIG_ABSENT (#12), a permuted CHANGELOG
return-code table (#11), a `caps_decl_parse` item-drop bug found while
landing the first-ever runnable test harness (#15), new CAP_BAD_SLOT
test coverage (#14), and `doc/INTEGRATION.md` (#16).
All planned milestones (M1..M5) remain closed; library is
consumer-ready. Public surface and return-code vocabulary are
unchanged from 1.0 — 1.0.1 is fixes + release hygiene, not a new API.

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
| M4-002 (#9)     | caps.decl parse-error corpus + narrowing/extra-cap invariant matrix            | LANDED |
| M5-001 (#10)    | dual-signed release + .pdxdoc + mirror push                                    | LANDED |

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

## M4 summary

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

### M4-002 (caps.decl matrix witness)

- `tests/m4_002_caps_decl_matrix.pdx` (NEW) — `M4CapsDeclMatrix`
  module with witness `m4_002_caps_decl_matrix` (22 stages across
  four sub-corpora: 8 parse-error / 4 narrowing / 5 extra-cap
  rejection / 5 signed-inode). Fingerprint contract: `rax == 0`
  on all-pass; else the 1-based stage index of the first failure.
  Companion diagnostic slot `_m4mx_stage` mirrors the return.
- 10 `.data` (mutable initialized) caps.decl fixtures cover the
  full `CAPS_DECL_*` error vocabulary + the two OK shapes.
- Sub-corpus C (extra-cap rejection) exercises both surfaces
  that raise `CAP_MANIFEST_EXTRA` — `cap_unpack_checked` at the
  per-cap consume site (M2-003) and `cap_manifest_verify` at the
  post-load bulk check (M2-001) — plus the `CAP_MANIFEST_MISSING`
  and `CAP_KIND_UNKNOWN` paths.
- Sub-corpus D (signed-inode) exercises the M3-002 helper set
  end-to-end: key-state locked/unlocked transitions, `has_signature`
  + `mark_unsigned` round-trip, `BAD_INODE` fail-fast on null
  input for both.
- `design/architecture.md` — new §12 documenting the M4 witness
  contract, the four sub-corpora, and the future
  wave-harness invocation shape.

## M5 summary

### M5-001 (dual-signed release + .pdxdoc + mirror push)

- `CHANGELOG.md` (NEW) — 1.0.0 entry: milestone rollup,
  frozen return-code table (16 codes across five modules),
  M4 witness fingerprint contract, dual-signature status,
  mirror-push status.
- `doc/libpdx-cap.pdxdoc` (NEW) — long-form doc for
  `doc libpdx-cap` (`.pdxdoc` v0.1 — @-directive-driven
  text with `## SECTION` headers and `[[TARGET]]` cross-refs;
  survives lax parsers until doc.M1-002 lands the grammar).
- `manifest.pdxsig` (NEW) — v0.1 release manifest with
  SHA-256 hash tree over 12 shipped artifacts,
  `@manifest-body-hash` over the artifact block, two
  RESERVED 3309-byte ML-DSA-65 sig slots (author +
  paideia_root) documented as byte-count-preserving
  overwrite targets for the signing bot (paideia-os
  T-INFRA-002) once the sign primitive's userspace linkage
  lands (paideia-as v0.33-crypto).
- `README.md` — status line advanced to "1.0.0 released";
  new artifacts added to layout listing.
- Git tag `v1.0.0` published on `github.com/paideia-os/libpdx-cap`
  (authoritative distribution; `pkgs.paideia-os` mirror push
  deferred pending T-INFRA-001).

## Consumer wiring (after 1.0.1 / ENH-001)

libpdx-cap's public surface stays 1.0-frozen; consumers pin
`libpdx-cap = 1.0.1` (or `^1.0`, which now resolves past the withdrawn
`v1.0.0` tag) in their `deps.list` and consume the artifact set — now
14 entries, `doc/INTEGRATION.md` and `tests/harness.pdx` added —
enumerated in `manifest.pdxsig`. The `@manifest-body-hash` in that
file is
`69299f1c380c78c3f1085e3cac281277e20a6e960985c72d798867af51a81848`;
downstream verifiers re-derive it via
`sed -n '54,/^@end-artifacts$/p' manifest.pdxsig | sha256sum`
until `pkg verify` lands.

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
