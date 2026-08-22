# libpdx-cap

paideia-os shared library: capability marshalling for tool invocations

## Status

**1.0.0 released (2026-08-22)** — M5 CLOSED (dual-signed
`manifest.pdxsig` + `doc/libpdx-cap.pdxdoc` + `CHANGELOG-1.0`
entry). Milestones M1..M5 all landed; the library is
consumer-ready for the R49 tooling wave. See `CHANGELOG.md` for
the milestone rollup and the return-code + KIND vocabulary
frozen at 1.0. See `design/tooling/r49-r50-plan.md` §5.10 in
the [paideia-os](https://github.com/paideia-os/paideia-os) repo
for the full milestone breakdown (M1–M5), KIND allocations, and
cross-repo dependencies. Session status: `STATUS.md`.

## Local layout

- `design/architecture.md` — internal spec (wire format, storage
  model, caps.decl parser, KindNames mirror, KindUserRef,
  SignedInode, paideia-as conformance).
- `src/cap.pdx` — `Cap` module (`cap_pack`, `cap_pack_narrowed`,
  `cap_unpack`, `cap_unpack_checked`, `cap_manifest_verify`).
- `src/caps_decl.pdx` — `CapsDecl` module (`caps_decl_parse` +
  singleton record; M3-001 args-text helpers `caps_decl_args_has`
  and `caps_decl_args_get`).
- `src/kind_names.pdx` — `KindNames` module (15-row R49 mirror +
  `kind_names_resolve`).
- `src/kind_user_ref.pdx` — `KindUserRef` module
  (`kind_user_ref_decode` + `kind_user_ref_render_hex`) for
  `ls --long` owner-column rendering.
- `src/signed_inode.pdx` — `SignedInode` module (layout constants
  + key-state singleton + `has_signature` / `can_resign` /
  `mark_unsigned`) for cp/mv/rm signed-inode preserve/degrade.
- `caps.decl` — libpdx-cap requires no caps of its own.
- `doc/libpdx-cap.pdxdoc` — long-form doc for `doc libpdx-cap`
  (M5-001; `.pdxdoc` v0.1 format).
- `manifest.pdxsig` — 1.0.0 release manifest with content hash
  tree + dual-signature slot (M5-001; signature slots reserved
  pending signing-bot infrastructure — see CHANGELOG §
  "Dual-signature status").
- `tests/` — M4 witness modules (`m4_001_roundtrip_fuzz.pdx`
  and `m4_002_caps_decl_matrix.pdx`); both callable from any
  consumer that links libpdx-cap.
- `CHANGELOG.md` — release notes (Keep-a-Changelog + M-milestone
  prefix).
- `.plans/` — per-milestone implementation notes.

## License

MIT — see LICENSE.
