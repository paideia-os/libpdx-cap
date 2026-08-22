# libpdx-cap — CHANGELOG

All notable changes to libpdx-cap are recorded here. The format
loosely follows Keep-a-Changelog with an M-milestone prefix so
each entry maps 1:1 to a GitHub milestone in this repo (see
`design/tooling/r49-r50-plan.md` §5.10 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo).

## 1.0.0 — 2026-08-22

**Milestone:** M5-001 (Issue #10).
**Wave:** R49 shared library.
**Release manifest:** `manifest.pdxsig` (format v0.1;
see `design/tooling/plan.md` §6.3 in paideia-os).

First 1.0 signed release. Milestones M1..M5 all closed; the
library is now consumer-ready for the R49 tooling wave (`pkg`,
`shell`, `doc`) and, transitively, for every R50 coreutil
(`ls`, `cat`, `cp`, `mv`, `rm`, `mkdir`).

### Public surface at 1.0 (five modules, 12 entry points)

- `Cap` (`src/cap.pdx`) — `cap_pack`, `cap_pack_narrowed`,
  `cap_unpack`, `cap_unpack_checked`, `cap_manifest_verify`.
- `CapsDecl` (`src/caps_decl.pdx`) — `caps_decl_parse` +
  singleton record; `caps_decl_args_has` and
  `caps_decl_args_get` for rights-args-text refinements.
- `KindNames` (`src/kind_names.pdx`) — `kind_names_resolve`
  over a 15-row R49 KIND mirror (rows M2-001 + KIND_TTY at
  M3-001).
- `KindUserRef` (`src/kind_user_ref.pdx`) — `kind_user_ref_decode`
  + `kind_user_ref_render_hex` for `ls --long` owner column.
- `SignedInode` (`src/signed_inode.pdx`) — PdxFS v1 layout
  constants + key-state singleton + `signed_inode_has_signature`
  / `signed_inode_can_resign` / `signed_inode_mark_unsigned`
  for cp/mv/rm signed-inode preserve-or-degrade.

### Milestone roll-up

| Milestone | Issues | Landed         | Summary                                                  |
|-----------|--------|----------------|----------------------------------------------------------|
| M1        | #1, #2 | b04b85c c147586| Scaffold + `Cap` + `CapsDecl` parser.                    |
| M2        | #3–#5  | d9f0784..9a0eef3| `cap_manifest_verify` body + narrow + extra-cap reject. |
| M3        | #6, #7 | 0a5bad6 3673dec| `KindUserRef` + `SignedInode` + rights-args-text.        |
| M4        | #8, #9 | 2236126 54fe719| Round-trip fuzz (10^6) + caps.decl matrix (22 stages).   |
| M5        | #10    | (this release) | 1.0 signed release + `.pdxdoc` + mirror push (deferred). |

### Return-code vocabulary (frozen at 1.0)

Range `0xFFFFFFEF..0xFFFFFFFE` is reserved by libpdx-cap; the
sidecar validator's `INIT_CAPS_BAD_*` codes extend from
`0xFFFFFFFF` upward and the two families do not collide.
Future codes extend downward from `0xFFFFFFEF`.

| Code         | Symbol                          | Module      |
|--------------|---------------------------------|-------------|
| `0xFFFFFFFE` | `CAP_BAD_SLOT`                  | Cap         |
| `0xFFFFFFFD` | `CAP_BAD_KIND`                  | Cap         |
| `0xFFFFFFFC` | `CAP_MANIFEST_MISSING`          | Cap         |
| `0xFFFFFFFB` | `CAP_MANIFEST_EXTRA`            | Cap         |
| `0xFFFFFFFA` | `CAPS_DECL_MALFORMED_HEADER`    | CapsDecl    |
| `0xFFFFFFF9` | `CAPS_DECL_MALFORMED_ITEM`      | CapsDecl    |
| `0xFFFFFFF8` | `CAPS_DECL_ITEM_OUT_OF_SECTION` | CapsDecl    |
| `0xFFFFFFF7` | `CAPS_DECL_REQ_OVERFLOW`        | CapsDecl    |
| `0xFFFFFFF6` | `CAPS_DECL_SCHEMA_OVERFLOW`     | CapsDecl    |
| `0xFFFFFFF5` | `CAP_RIGHTS_WIDENING`           | Cap (M2-002)|
| `0xFFFFFFF4` | `CAP_KIND_UNKNOWN` / `KIND_NAMES_UNKNOWN` | Cap + KindNames |
| `0xFFFFFFF3` | `USER_REF_WRONG_KIND`           | KindUserRef |
| `0xFFFFFFF2` | `USER_REF_BAD_ROW`              | KindUserRef |
| `0xFFFFFFF1` | `SIGNED_INODE_SIG_ABSENT`       | SignedInode |
| `0xFFFFFFF0` | `SIGNED_INODE_KEY_LOCKED`       | SignedInode |
| `0xFFFFFFEF` | `SIGNED_INODE_BAD_INODE`        | SignedInode |

### Test contract at 1.0

- `M4RoundtripFuzz::m4_001_roundtrip_fuzz` — 10^6-iteration LCG
  round-trip witness (Knuth 64-bit MMIX; seed
  `M4RF_LCG_SEED = 0xC0FFEE5EA5CAB1E7`). Returns 0 on pass; else
  the 1-based iteration index of the first divergence.
  Diagnostic slots `_m4rf_fail_iter` + `_m4rf_fail_field`.
- `M4CapsDeclMatrix::m4_002_caps_decl_matrix` — 22-stage matrix
  covering the parse-error corpus (S1..S8), narrowing invariant
  (S9..S12), extra-cap rejection at both surfaces (S13..S17),
  and signed-inode helpers (S18..S22). Returns 0 on pass; else
  the 1-based stage index. Diagnostic slot `_m4mx_stage`.

Both witnesses are self-contained, re-runnable inside one
process, and callable from any userspace consumer that links
libpdx-cap.

### Dual-signature status

Per §6.2 of `design/tooling/plan.md`, packages ship dual-signed
under `author_pk` + `paideia_root_pk` (both ML-DSA-65). The
`manifest.pdxsig` in this release carries the full artifact
hash tree; the two 3309-byte signature slots are RESERVED
(all-zero placeholders) pending:

1. The paideia-as v0.33-crypto ML-DSA-65 sign primitive's
   userspace linkage (paideia-as issues #1302–#1306; not yet
   published — see `.plans/m3-002-notes.md`).
2. `pkg` reaching M4 and `pkgs.paideia-os` +
   `T-INFRA-001` / `T-INFRA-002` (signing bot host) coming
   online.

When both land the signing bot re-signs the manifest in place
without altering the hash tree; downstream verifiers ingest the
same file. The reserved-slot shape is documented in
`manifest.pdxsig` itself and mirrored in
`.plans/m5-001-notes.md`.

### Mirror-push status

`pkgs.paideia-os` (paideia-os issue T-INFRA-001) does not yet
exist. `git push --tags` publishes v1.0.0 to
`github.com/paideia-os/libpdx-cap`; the mirror push to
`pkgs.paideia-os/main/libpdx-cap/1.0.0/` lands automatically
once the repository infrastructure is stood up (no libpdx-cap
change needed at that point beyond the signing bot's
re-signature).

### paideia-as toolchain requirement

paideia-as ≥ v0.33 (`mov_b` narrow-load mnemonic + `@align`
attribute on `.bss` slots). No new toolchain feature is
required by 1.0 that was not already required by M1.
