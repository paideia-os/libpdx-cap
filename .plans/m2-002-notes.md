# libpdx-cap.M2-002 — implementation notes

**Issue:** #4
**Status:** LANDED

## What landed

- `src/cap.pdx`:
  - New constant `CAP_RIGHTS_WIDENING = 0xFFFFFFF5`.
  - New entry `cap_pack_narrowed(dst, slot, kind, original_rights,
    narrowed_rights, target_ptr) → rc`:
    - Widen check: `(narrowed & ~original) == 0`; violation → refuse
      with `CAP_RIGHTS_WIDENING` BEFORE any store to `dst` (fail-fast,
      matches cap_pack's slot-bound discipline).
    - Slot bound reuses cap_pack's `cmp rsi, 256; jge`.
    - Two-qword store body identical to cap_pack — same register
      plan, same paideia-as compliance.

## Design decisions

**Widen check via bitwise idiom.** `(narrowed & ~original)` computed
as `mov rax, rcx; not rax; and rax, r8` — no branch inside the check,
one instruction per operation, three total. Non-zero result names
exactly the bits the caller tried to widen. Alternative form
`(narrowed | original) != original` uses one fewer instruction but
loses the "which bits widened" info that a M3 diagnostic path might
want; the current form leaves the widened bits sitting in `rax` at
the reject site for a future `cap_pack_narrowed_diag` extension
without a re-computation.

**Widening check precedes slot check.** Both are fatal, but widening
names the more consequential fault: a broken narrowing policy is a
bug in the caller's cap-forwarding logic that must surface even if
the same call also passed a bad slot. Reversing the order would let
a bad-slot rc mask a widening bug in the caller's fuzz tests.

**New entry vs. flag on cap_pack.** Adding a "narrow?" flag on
cap_pack would have preserved a single entry point but forced every
existing call site to opt out — a wide diff for a small type change.
A new entry keeps M1's cap_pack signature and semantics intact and
makes the send-site narrowing site call itself out at every consumer.

## paideia-as conformance checklist

- No `test` mnemonic: `cmp rax, 0` for the widen-mask check.
- `cmp reg, imm`: `cmp rsi, 256` (256 ≤ 0x7FFFFFFF).
- Large-imm returns: `mov rax, 0xFFFFFFF5` / `mov rax, 0xFFFFFFFE`
  (same InitCap-BAD_SLOT precedent).
- `r11` scratch: yes.
- `not rax`: valid paideia-as mnemonic (see kernel `battery_monitor.pdx`,
  `endpoint_table.pdx`, etc. for prior art).
- Leaf function: no push/pop parity to preserve.

## What's next

- M3-001 rights-args-text refinement (fine-grained subtree/mode
  narrowing beyond the u32 rights-mask).
