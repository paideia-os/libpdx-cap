# libpdx-cap.M3-002 — implementation notes

**Issue:** #7
**Status:** LANDED

## What landed

- `src/signed_inode.pdx` (NEW) — `SignedInode` module:
  - Layout constants for PdxFS v1 signed-inode wire format:
    - `INODE_HEAD_BYTES = 64`
    - `SIG_PRESENT_OFFSET = 64`
    - `SIG_BODY_OFFSET = 65`
    - `ML_DSA_65_SIG_LEN = 3309`
    - `SIGNED_INODE_TOTAL_BYTES = 3374`
    - `UNSIGNED_INODE_TOTAL_BYTES = 65`
    - `SIG_FLAG_ABSENT = 0`, `SIG_FLAG_PRESENT = 1`
  - Key-state singleton `signed_inode_key_state` (u64; 0 = locked,
    1 = unlocked, any other value = locked). Consumer contract:
    populate at session start from the paideia-os user-sk unlock
    query.
  - Five entry points:
    - `signed_inode_key_state_reset()` — zero the flag.
    - `signed_inode_key_state_set(state)` — store rdi verbatim.
    - `signed_inode_has_signature(inode_ptr) → rc`:
      - `SIGNED_INODE_BAD_INODE` (0xFFFFFFEF) if inode_ptr == 0.
      - 1 if `[inode_ptr + 64] == 1`.
      - 0 otherwise (fail-safe: only literal 1 counts as present).
    - `signed_inode_can_resign() → rc`:
      - `SIGNED_INODE_OK` (0) if `signed_inode_key_state == 1`.
      - `SIGNED_INODE_KEY_LOCKED` (0xFFFFFFF0) otherwise.
    - `signed_inode_mark_unsigned(dst_inode_ptr) → rc`:
      - `SIGNED_INODE_BAD_INODE` if dst == 0.
      - `SIGNED_INODE_OK` after writing 0 to `[dst + 64]`.
  - All entries are LEAF — no callee-save touched, no push/pop
    parity to preserve, no nested-call rsp alignment obligation.

## Design decisions

**No ML-DSA-65 sign primitive.** The actual re-sign is a paideia-as
v0.33-crypto intrinsic (`ml_dsa_65_sign`) and its userspace linkage
is on the paideia-as team's roadmap. Wrapping it in libpdx-cap
today would either (a) inline the assembly, which duplicates
crypto material across libpdx-cap and the crypto-primitive
library — a maintenance hazard, or (b) call through a linker symbol
that does not yet exist — which would fail to link every consumer.
Publishing the layout constants + the query surface today lets
cp/mv/rm wire the DEGRADE path completely (has_signature + can_resign
+ mark_unsigned) while a follow-up milestone adds the RE-SIGN path
once the intrinsic ships. This matches the plan doc §5.10 M3 rubric
("M3 lands the audit + KIND_USER_ref decode + signed-inode helpers")
— "helpers" is the noun the plan uses, not "sign primitive".

**Fail-safe key state.** Any value other than literal 1 in the
key-state singleton makes `can_resign` return KEY_LOCKED. A consumer
that forgets to call `signed_inode_key_state_set(1)` after an
unlock — or passes garbage from an uninit memory read — produces
UNSIGNED destinations, NOT a false-positive "we can sign" that
would fail deep in the crypto path (or worse, produce a signature
under a stale key). The `_reset` entry exists so a session teardown
cannot leave a stale unlocked flag for a subsequent process
(assuming shared .bss — the normal `_start` re-init path
supersedes anyway).

**Constants over enums.** The layout constants are `pub let ... : u64`
rather than an enum because paideia-as's `[u8; N]` literal syntax
takes a numeric N — `[u8; INODE_HEAD_BYTES]` in a consumer's
buffer declaration is a natural expression. An enum would need a
`.into()` conversion at every use site.

**Fail-fast on null inode_ptr.** Both `has_signature` and
`mark_unsigned` refuse `inode_ptr == 0` with `SIGNED_INODE_BAD_INODE`
before touching memory. This mirrors `cap_pack`'s slot-bound
discipline (`cap_pack_bad_slot` before any store to dst) and
matches libpdx-cap's convention that the caller must own the buffer
before passing it to any library entry.

**No source-signature verify.** cp's read path relies on
KIND_PDXFS_FILE's own signature-verify hook (part of the R42 substrate
prep). libpdx-cap sees only inodes the kernel has already validated.
Duplicating the verify here would either use the same paideia-as
crypto intrinsic (which is not yet linked — see "No ML-DSA-65 sign
primitive" above) or a re-implementation (which is a maintenance
hazard).

**Consumer degrade path.** The three helpers compose into a
straightforward fork:

```
if has_signature(src) == 1 {
    if can_resign() == OK {
        // FUTURE: resign via paideia-as crypto intrinsic
    } else {
        // Emit --verbose diagnostic
        mark_unsigned(dst)
    }
} else {
    mark_unsigned(dst)   // keep dst flag coherent even for unsigned src
}
```

Consumers can adopt the degrade path TODAY; the re-sign branch
becomes a real code path when the intrinsic ships.

## paideia-as conformance checklist

- Module name PascalCase basename (`SignedInode`): yes.
- No `test` mnemonic: every zero check uses `cmp reg, 0` or `cmp
  rax, 1`.
- `cmp reg, imm ≤ 0x7FFFFFFF`: yes — largest immediates are single-
  byte values (0, 1) and 64 (SIG_PRESENT_OFFSET added as `add r11,
  64` which fits imm8).
- Large-imm returns: `mov rax, 0xFFFFFFF0` (KEY_LOCKED), `mov rax,
  0xFFFFFFEF` (BAD_INODE) — same InitCap-BAD_KIND precedent.
- `r11` scratch: yes — every `lea r11, [rip + sym]` respects the
  reservation; `add r11, 64` for the sig_present offset is scratch
  use in leaf context.
- Byte reads: `xor rax, rax; mov_b rax, [r11]` in
  `signed_inode_has_signature` (#1248 mitigation).
- Byte writes: `mov_b [r11], rax` (rax pre-zeroed) in
  `signed_inode_mark_unsigned` — mirror pattern from caps_decl.pdx.
- SysV push/pop parity: N/A — all entries are LEAF.

## What's next

- M4-001 round-trip fuzz — extended to cover the SignedInode
  layout: pack an inode with a known sig_present byte, query with
  `has_signature`, verify the result.
- Follow-up milestone (post-paideia-as v0.33-crypto intrinsic
  linkage) — wrap `ml_dsa_65_sign` as
  `signed_inode_resign(src, dst, user_sk_slot)` using the layout
  constants published today.
