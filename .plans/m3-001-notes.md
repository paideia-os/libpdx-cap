# libpdx-cap.M3-001 — implementation notes

**Issue:** #6
**Status:** LANDED

## What landed

- `src/kind_user_ref.pdx` (NEW) — `KindUserRef` module:
  - `kind_user_ref_reset()` — clears the four singleton slots.
  - `kind_user_ref_decode(cap_wire_ptr) → rc`:
    - Verifies wire's kind lane == `KIND_USER = 0x190`.
    - On WRONG_KIND: singleton UNTOUCHED, returns
      `USER_REF_WRONG_KIND = 0xFFFFFFF3`.
    - Verifies row_id (target_ptr & 0xFFFF) < `USER_MAX = 16`.
    - On BAD_ROW: singleton UNTOUCHED, returns
      `USER_REF_BAD_ROW = 0xFFFFFFF2`. Catches USER_ROW_NONE (0xFF).
    - On OK: populates `user_ref_row_id`, `user_ref_slot`,
      `user_ref_rights`, `user_ref_raw_target`; returns `USER_REF_OK`.
    - Leaf function; no callee-save touched.
  - `kind_user_ref_render_hex(user_key) → 16`:
    - 16-iteration loop renders u64 as 16 lowercase hex digits (MSN
      first) into `user_ref_hex_buf`, followed by NUL at byte 16.
    - Shift-left-by-4 idiom: extract top nibble via `shr rax, 60`,
      index `_kur_hex[nibble]` via #1248-safe byte read, store at
      `hex_buf[i]` via `mov_b [ptr], reg`, then `shl r10, 4`.
    - Leaf function; no callee-save touched.
- `src/kind_names.pdx` — added Row 15:
  - `_kn_str_tty : [u8; 9] = "KIND_TTY\0"` string literal.
  - `_knres_hit_tty` epilogue returns `mov rax, 0x197; pop r12; ret`.
  - Header comment table + row-count updated (13 → 15; also documents
    the historical M2 deferral now closed by paideia-os cf496fb).
- `src/caps_decl.pdx` — added rights-args-text refinement helpers:
  - `caps_decl_args_value_ptr` + `_len` singleton slots (populated
    on `caps_decl_args_get` hit; UNTOUCHED on miss).
  - `caps_decl_args_has(args_ptr, needle_ptr) → 0 | 1` — bare-token
    membership scan. Three callee-save pushes (r12/r13/r14).
  - `caps_decl_args_get(args_ptr, key_ptr) → 0 | 1` — key=value
    lookup + value pointer/length population. Four callee-save
    pushes (r12/r13/r14/r15).
- `design/architecture.md`:
  - §1 public-surface list extended with `KindUserRef` (M3-001)
    and `SignedInode` (M3-002); the "three modules" count is now
    "five modules".
  - §5 return-code vocabulary extended with `USER_REF_WRONG_KIND`
    (0xFFFFFFF3), `USER_REF_BAD_ROW` (0xFFFFFFF2), and the three
    SignedInode codes (0xFFFFFFF1 / 0xFFFFFFF0 / 0xFFFFFFEF).
  - §7 KindNames row table extended from 14 to 15 rows; KIND_TTY
    at 0x197 documented with its cf496fb R30-PREP #1631 provenance.
  - §8 exclusions for KIND_USER_ref and signed-inode marked
    LANDED at M3-001 and M3-002.
  - §9 NEW — KindUserRef consumer flow, decode + render split
    rationale, why row_id is exposed (not a fingerprint decode).
  - §4 addendum — rights-args-text helper API surface + covered
    grammar subset.
  - §11 renumbered (was §8 Cross-repo deps, before the M3 sections
    landed §9 and §10).

## Design decisions

**Decode + render split.** `kind_user_ref_decode` is pure wire
inspection; `kind_user_ref_render_hex` is pure formatting. The middle
step — invoking a KIND_USER cap to obtain the fingerprint — requires
a cap handle libpdx-cap does not own. Keeping the boundary here lets
`ls --long` batch fingerprint queries across N entries in a single
syscall pass at a later milestone (only the render-hex loop is
per-entry work).

**Row_id, not fingerprint, exposed.** paideia-os's KIND_USER wire
puts the kernel row_id in target_ptr[15:0]; the fingerprint itself is
NOT on the wire. A libpdx-cap that pretended to "decode a fingerprint"
would mirror the kernel's `_user_table` — a synchronization hazard we
refuse. The row_id + cap-invoke round trip is the honest path.

**Fail-fast on WRONG_KIND / BAD_ROW.** Mirrors `cap_unpack_checked`'s
CAP_MANIFEST_EXTRA discipline (M2-003): on rejection the singleton is
UNTOUCHED so a caller inspecting `user_ref_row_id` sees the previous
decode's values (or 0 after `kind_user_ref_reset`), not stale garbage
from the rejected wire record. This lets the caller distinguish
"decode succeeded, this is the row" from "decode was rejected, fall
back to '?'" without a defensive reset in between.

**KIND_TTY row lands now.** M2 deferred the row because paideia-os
HEAD had no `KIND_TTY` symbol. paideia-os cf496fb (R30-PREP #1631)
pinned the ordinal at 0x197 as a derived kind over
`KIND_IPC_ENDPOINT`. `shell`, `doc`, `ls`, and `cat` all declare
KIND_TTY in their caps.decl, so the M2 loud-refusal path
(CAP_KIND_UNKNOWN) would otherwise fire for every R49-wave tool at
exec.

**Rights-args-text via `has` + `get`, not a full parse.** A full
parse would produce an AST of tokens the caller would then walk;
`has` + `get` are the two questions R49-wave consumers actually
need to ask (D3 "cp uses subtree=…" and "ls uses read"). Both
share the walker shape, so a follow-up milestone can factor the
walker into a private helper without changing the public API.

**Get does NOT NUL-terminate the value.** A subsequent `get` for a
different key against the same args-text buffer would then walk
past the injected NUL and read stale bytes. Consumers copy the
value out using the (ptr, len) pair.

## paideia-as conformance checklist

- Module name PascalCase basename (`KindUserRef`): yes.
- No `test` mnemonic: verified — every zero check uses `cmp reg, 0`
  or `cmp reg, imm ≤ 0xFFFF`.
- `cmp reg, imm ≤ 0x7FFFFFFF`: yes — largest immediates are 0xFFFF
  (kind mask), 0x190 (KIND_USER), 16 (USER_MAX), single-byte ASCII
  (0x28/0x29/0x2C/0x3D/etc), 60 (shr count).
- Large-imm returns: `mov rax, 0xFFFFFFF3` / `mov rax, 0xFFFFFFF2`
  — same InitCap-BAD_KIND precedent.
- `r11` scratch: yes — every `lea r11, [rip + sym]` respects the
  reservation; no persistent r11 across a call (there are no
  nested calls in KindUserRef).
- Byte reads: `xor rax, rax; mov_b rax, [ptr]` in
  `kind_user_ref_render_hex` (hex-table lookup) and in both
  caps_decl_args helpers (needle/args byte compare).
- Byte writes: `mov_b [ptr], rax` in `kind_user_ref_render_hex`
  (digit + NUL stores) — mirror of caps_decl.pdx's in-place
  NUL-terminate.
- SysV push/pop parity: matched at every function. `kind_user_ref_*`
  entries are leaf (0 pushes). `caps_decl_args_has` uses 3 pushes;
  `caps_decl_args_get` uses 4 pushes. Both are leaf (no nested
  calls) so alignment at call site is not an obligation; only
  push/pop parity matters, and every exit path has matched pops.

## What's next

- M3-002 `SignedInode` (issue #7) — landed alongside this issue;
  see `m3-002-notes.md`.
- M4-001 round-trip fuzz (10^6 random cap shapes) — extended to
  cover the M3-001 wire-decode entry alongside the M1/M2 pack/unpack
  paths.
- M4-002 caps.decl parse-error corpus — extended to exercise the
  M3-001 args-text helpers against every well-formed and
  malformed args-text shape.
