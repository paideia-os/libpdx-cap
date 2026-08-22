# libpdx-cap.M2-003 — implementation notes

**Issue:** #5
**Status:** LANDED

## What landed

- `src/cap.pdx`:
  - New entry `cap_unpack_checked(src) → rc`:
    - Extracts recv kind from wire (qword0 shr 16, mask 0xFFFF).
    - Scans `CapsDecl::req_kind_names[]` with `kind_names_resolve`.
    - If the recv kind matches any declared name: perform the four-
      lane unpack (identical to `cap_unpack`) and return `CAP_OK`.
    - If NO declared name resolves to the recv kind: leave
      `unpacked_*` UNTOUCHED and return `CAP_MANIFEST_EXTRA`
      (fail-fast; mirrors cap_pack's leave-dst-untouched-on-bad-slot).
  - Three callee-save pushes (`r12/r13/r14`) → rsp % 16 == 0 at nested
    `kind_names_resolve` call site.

## Design decisions

**Guarded entry alongside raw cap_unpack.** The M1 raw `cap_unpack`
is preserved because InitCap-seed reads happen BEFORE the callee has
parsed its `caps.decl` — the sidecar tail is validated against a
statically-known kind set at loader time (paideia-os
`init_caps.pdx`), not against the callee's decl. `cap_unpack_checked`
is for the runtime path AFTER `caps_decl_parse` has populated the
singleton: shell-forwarded caps, sys_cap_transfer receives, etc.

**Redundant with cap_manifest_verify — deliberately.** A tool that
lazily unpacks caps as it uses them would otherwise have to pre-scan
the whole received array with `cap_manifest_verify` before touching
any single cap. `cap_unpack_checked` catches the EXTRA at consume
time, letting the tool defer manifest_verify to a later checkpoint
(or skip it entirely if it consumes every cap through the checked
path). Both use the same rejection code so a caller sees ONE
vocabulary.

**No CAP_KIND_UNKNOWN surface here.** If a decl entry resolves to
`KIND_NAMES_UNKNOWN`, that entry simply fails the inner compare and
the scan continues to the next entry. The loud "your caps.decl names
an unknown kind" surface is at `cap_manifest_verify`'s Pass 1, which
runs once at exec. Firing `CAP_KIND_UNKNOWN` per-unpack would spam
the error path for a tool whose decl mostly names known kinds plus
one that libpdx-cap does not yet mirror.

**Fail-fast leaves unpacked_* untouched.** Same discipline as
cap_pack's bad-slot path: a rejected unpack does not corrupt the
singleton, so the caller can inspect `unpacked_*` fields after any
previous successful unpack without a defensive reset in between.

## paideia-as conformance checklist

- No `test` mnemonic: all zero checks use `cmp reg, reg` or
  `cmp reg, imm ≤ 0xFFFF`.
- `cmp reg, imm ≤ 0x7FFFFFFF`: largest imm is 0xFFFF.
- Large-imm return: `mov rax, 0xFFFFFFFB` (CAP_MANIFEST_EXTRA).
- `r11` scratch: yes.
- SysV push/pop parity: 3 callee-save pushes, matched pops on both
  exit paths (hit + extra).
- rsp % 16 == 0 at nested `call kind_names_resolve`: 3 pushes from
  entry rsp % 16 == 8 → 0. Aligned.

## What's next

- Round-trip fuzz for cap_pack_narrowed → cap_unpack_checked landing
  at M4-001.
