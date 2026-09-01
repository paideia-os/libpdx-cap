# libpdx-cap — CHANGELOG

All notable changes to libpdx-cap are recorded here. The format
loosely follows Keep-a-Changelog with an M-milestone prefix so
each entry maps 1:1 to a GitHub milestone in this repo (see
`design/tooling/r49-r50-plan.md` §5.10 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo).

## Unreleased

**Milestone:** Enhancement v1.x — libpdx-cap. Follow-up to 1.0.1;
no version tag cut yet (see "Release-manifest note" below).

### Added

- **ENH-008 (#18):** additive caller-owned (re-entrant) context
  variants for fan-out consumers. New sixth module `CapCtx`
  (`src/cap_ctx.pdx`) ships five entry points alongside the M1
  singletons — the M1 API is unchanged and no existing consumer
  (`ls`) needs to move:
  - `cap_ctx_reset(ctx)` / `caps_decl_ctx_reset(ctx)` — zero the
    caller's context to a known-empty state (mirror of
    `Cap::cap_reset` / `CapsDecl::caps_decl_reset`).
  - `cap_unpack_into(ctx, src)` — writes the four unpacked lanes
    into the caller's 32-byte Cap context instead of the singleton.
  - `cap_unpack_checked_into(ctx, src, decl_ctx)` — same gate as
    `cap_unpack_checked`, but against a caller-owned CapsDecl
    context; on reject leaves the caller's cap ctx untouched
    (fail-fast, mirrored).
  - `caps_decl_parse_into(ctx, src, len)` — the M1 parser reworked
    to read/write from a caller-owned 416-byte CapsDecl context.
    Bit-identical grammar and state machine to `caps_decl_parse`
    (including the libpdx-cap#15 item-tail-dispatch-flag fix).
  - `cap_manifest_verify_into(decl_ctx, received_ptr, received_count)`
    — finally does what `cap_manifest_verify`'s reserved `decl_ptr`
    parameter documented at 1.0: reads `req_count` / `req_kind_names`
    from the caller's decl ctx. The 1.0 `cap_manifest_verify` entry
    keeps its behaviour (its `decl_ptr` remains informational).

  Context layouts are published as constants (`CAP_CTX_SIZE = 32`,
  `CAPS_DECL_CTX_SIZE = 416`, plus per-field `_OFF` constants) so a
  caller sizes its own buffer without a header —
  same discipline `SignedInode` uses for its inode-layout constants.
  Layouts are byte-identical to the singleton field shapes so a
  consumer that already reads the singletons can port by swapping
  `lea r11, [rip + <field>]` for `lea r11, [<ctx_reg> + <offset>]`.

  M4-002 gains a 10-stage sub-corpus (S31..S40) proving two live
  Cap contexts and two live CapsDecl contexts coexist in one
  process. Fingerprint stages: S33 (interleaved decl ctxs read
  back correct req_counts), S36 (interleaved cap ctxs read back
  correct kind/slot values), S40 (same received wire yields
  different `cap_manifest_verify_into` results under two different
  decl ctxs — the shape ENH-008 exists to enable).

  Return-code vocabulary unchanged; no new sentinels introduced.

### Release-manifest note

The 1.0.1 `manifest.pdxsig` hash tree does not yet cover
`src/cap_ctx.pdx` or the new `_m4mx_*_e8` fixture and S31..S40
stages in `tests/m4_002_caps_decl_matrix.pdx`. A follow-up issue
should cut 1.0.2 after `shell` (the natural design partner for
ENH-008 per its issue body) validates the context layout against
its real fan-out path and confirms no further shape adjustments.

## 1.0.1 — 2026-08-25

**Milestone:** Enhancement v1.x — libpdx-cap (ENH-001..009).
**Release manifest:** `manifest.pdxsig` (format v0.1; hash tree +
`@manifest-body-hash` regenerated against this tree).

**The `v1.0.0` tag is WITHDRAWN.** It points at `27c29e2`, a tree
that does not assemble (`src/cap.pdx:214` was missing a `;` before a
fall-through label; fixed three commits later at `da38a9e`, which
`v1.0.0` predates). `v1.0.1` is cut from a tree that has actually been
assembled with `paideia-as check` on every module and test file, and
whose M4 witnesses have actually been run and returned `0` — the
first time either has been true for a tagged release. Consumers
pinning `libpdx-cap @ ^1.0` pick up the fix automatically.

### Fixes

- **ENH-004 (#13):** `cap_pack` / `cap_pack_narrowed`'s slot bound used
  a signed `jge`; `slot >= 2^63` read as negative and fell through to
  a truncating store instead of `CAP_BAD_SLOT`. Now unsigned `jae`.
- **ENH-009 (#17):** `CAP_BAD_KIND` was declared and never returned —
  `cap_pack` / `cap_pack_narrowed` silently truncated an out-of-range
  `kind` (e.g. `0x10190`) to a well-formed but wrong `KIND_*`. Both
  now reject `kind >= 0x10000` before any store. The
  `KIND_TRANSFERABLE_TABLE` membership check remains a separate,
  still-open item (needs a paideia-os `cap/kind.pdx` mirror decision).
- **ENH-003 (#12):** `SIGNED_INODE_SIG_ABSENT` was declared
  (`0xFFFFFFF1`) but `signed_inode_has_signature`'s absent path
  returned literal `0`. Resolved as reserved-unused rather than
  redefining a frozen 1.0 return value; source, design doc, this
  CHANGELOG, and README now agree the real contract is `1` / `0` /
  `SIGNED_INODE_BAD_INODE`.
- **`caps_decl_parse` item-drop bug (found while landing ENH-006):**
  NUL-terminating a list item's `'\n'` boundary in place destroyed
  the sentinel the post-item scan needed to find the line's end, so
  the scan walked into the NEXT line and silently swallowed it —
  every OTHER item in any `requires:` / `declares_output_schemas:`
  section with 2+ plain-newline-terminated items was dropped without
  error. This means every 1.0.0 consumer with 2+ requires items in its
  `caps.decl` (the plan doc's own worked example — `pkg install` with
  6 requires items — would have retained only 3) was silently
  under-declaring. Fixed with a per-item dispatch flag (`r14`) so the
  parser only re-scans when the boundary genuinely has more line
  content ahead of it.

### Corrections (documentation / release hygiene)

- **ENH-002 (#11):** `CHANGELOG.md`'s 1.0.0 return-code table had five
  `CAPS_DECL_*` codes permuted against `src/caps_decl.pdx`; corrected.
  Entry-point count corrected 12 → 20 (grep-verified).
- **ENH-007 (#16):** added `doc/INTEGRATION.md` — a copy-pasteable
  exec-time wiring sequence, `ls`'s owner column cited as the one
  verified production integration, and the M1→M3 migration recipe for
  `ls`'s still-unmigrated M2-era shim. `design/architecture.md` §1 no
  longer reads as if the exec-time flow is universally wired — it
  isn't, yet, anywhere.

### Added

- **ENH-005 (#14):** 8 new `m4_002_caps_decl_matrix` stages (S23..S30)
  covering `CAP_BAD_SLOT` — `cap_pack`'s only failure mode had zero
  test coverage before this. Every rejecting stage also asserts `dst`
  is left byte-for-byte untouched.
- **ENH-006 (#15):** `tests/harness.pdx` + `tools/run-tests.sh` — links
  every `src/*.pdx` module and both M4 witnesses into one hosted ELF64
  executable and actually runs it. This is what caught the
  `caps_decl_parse` bug above; before this, the "10^6 LCG-driven
  iterations" claim in the 1.0.0 entry below had executed zero
  iterations.

### Deferred

- **ENH-008 (#18)** — additive caller-owned (re-entrant) `Cap`/`CapsDecl`
  context variants for fan-out consumers. Left open per the issue's
  own recommendation: `shell` is the natural design partner and the
  context layout should be settled against its real fan-out path
  rather than in the abstract; no consumer has yet confirmed the need
  in practice. *(Superseded: shipped in the Unreleased section above;
  see ENH-008 (#18) entry there.)*

## 1.0.0 — 2026-08-22

**Milestone:** M5-001 (Issue #10).
**Wave:** R49 shared library.
**Release manifest:** `manifest.pdxsig` (format v0.1;
see `design/tooling/plan.md` §6.3 in paideia-os).

First 1.0 signed release. Milestones M1..M5 all closed; the
library is now consumer-ready for the R49 tooling wave (`pkg`,
`shell`, `doc`) and, transitively, for every R50 coreutil
(`ls`, `cat`, `cp`, `mv`, `rm`, `mkdir`).

### Public surface at 1.0 (five modules, 20 entry points)

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
| `0xFFFFFFFA` | `CAPS_DECL_REQ_OVERFLOW`        | CapsDecl    |
| `0xFFFFFFF9` | `CAPS_DECL_SCHEMA_OVERFLOW`     | CapsDecl    |
| `0xFFFFFFF8` | `CAPS_DECL_MALFORMED_HEADER`    | CapsDecl    |
| `0xFFFFFFF7` | `CAPS_DECL_MALFORMED_ITEM`      | CapsDecl    |
| `0xFFFFFFF6` | `CAPS_DECL_ITEM_OUT_OF_SECTION` | CapsDecl    |
| `0xFFFFFFF5` | `CAP_RIGHTS_WIDENING`           | Cap (M2-002)|
| `0xFFFFFFF4` | `CAP_KIND_UNKNOWN` / `KIND_NAMES_UNKNOWN` | Cap + KindNames |
| `0xFFFFFFF3` | `USER_REF_WRONG_KIND`           | KindUserRef |
| `0xFFFFFFF2` | `USER_REF_BAD_ROW`              | KindUserRef |
| `0xFFFFFFF1` | `SIGNED_INODE_SIG_ABSENT` (reserved-unused; `signed_inode_has_signature` returns literal `0`/`1`) | SignedInode |
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
