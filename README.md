# libpdx-cap

paideia-os shared library: capability marshalling for tool invocations

## Status

M3 CLOSED (audit + KIND_USER_ref decode + signed-inode helpers +
rights-args-text refinement + KIND_TTY row). Ready for M4 (round-trip
fuzz + smoke matrix). See `design/tooling/r49-r50-plan.md` §5.10 in
the [paideia-os](https://github.com/paideia-os/paideia-os) repo for
the full milestone breakdown (M1–M5), KIND allocations, and
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
- `tests/` — empty until `libpdx-cap.M4-001` lands the 10^6-cap-shape
  round-trip fuzz.
- `.plans/` — per-milestone implementation notes.

## License

MIT — see LICENSE.
