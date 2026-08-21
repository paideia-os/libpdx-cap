# libpdx-cap.M1-001 — implementation notes

**Issue:** #1
**Status:** LANDED
**Landed by:** Fix #1

## What landed

- `src/cap.pdx` — `Cap` module with:
  - Constants: `CAP_ENTRY_SIZE=16`, `CAP_ALIGN=8`, `CAP_SLOT_MAX=256`,
    return codes `CAP_OK`, `CAP_BAD_SLOT`, `CAP_BAD_KIND`,
    `CAP_MANIFEST_MISSING`, `CAP_MANIFEST_EXTRA`.
  - `.bss` singleton: `unpacked_slot`, `unpacked_kind`,
    `unpacked_rights`, `unpacked_target_ptr`.
  - `cap_reset()` — zero the four unpack slots.
  - `cap_pack(dst, slot, kind, rights, target_ptr)` — two-qword store,
    fail-fast on slot bound.
  - `cap_unpack(src)` — two qword loads, split qword0 into three lanes
    via shift + mask.
  - `cap_manifest_verify(decl, received, count)` — skeleton returning
    `CAP_OK` unconditionally; body lands at M2-001.
- `caps.decl` — libpdx-cap requires no caps; declares no output schemas.
- `design/architecture.md` — full M1 spec covering both M1-001 and
  M1-002 (§4 pre-describes the caps.decl parser that #2 implements).
- `README.md` — local layout.
- `STATUS.md` — M1-001 LANDED, M1-002 pending.
- `tests/README.md` — placeholder for the M4 fuzz.

## Wire-format decision

The two-qword store idiom (qword0 = slot|kind|rights,
qword1 = target_ptr) matches the InitCap sidecar layout in
paideia-os `src/kernel/core/loader/init_caps.pdx`. Rationale in
`design/architecture.md` §2 — a cap seeded by the loader and a cap
received via `sys_cap_transfer` share one on-wire vocabulary.

## paideia-as conformance checklist

- Module name PascalCase basename (`Cap`): yes.
- No `test` mnemonic: verified (only `cmp reg, 0` for zero checks — M1
  has no zero checks in cap.pdx, so this is vacuously satisfied here
  and enforced by convention in caps_decl.pdx).
- Every `cmp reg, imm` uses `imm ≤ 0x7FFFFFFF`: yes — the only immediate
  compare is `cmp rsi, 256` (`CAP_SLOT_MAX`).
- Large-immediate return codes (`0xFFFFFFFE` etc.) are `mov rax, imm32`
  emissions — same precedent as InitCap's `mov rax, 0xFFFFFFFE`.
- `r11` scratch: yes — every `lea r11, [rip + sym]` follows the
  ParsedArgs precedent from libpdx-argv.
- Byte reads (`xor rax, rax; mov_b rax, [ptr]`): none in cap.pdx (qword
  loads only); pattern appears in caps_decl.pdx.
- SysV push/pop parity: N/A — every entry point in M1 is a leaf
  function.

## What's next

- M1-002 (#2): `caps.decl` parser. Design already spec'd in
  `design/architecture.md` §4. Implements `src/caps_decl.pdx`.
- M2-001: fill `cap_manifest_verify` body (OK | MISSING | EXTRA compare
  between the parsed decl and the received cap array).
