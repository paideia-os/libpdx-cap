# libpdx-cap

paideia-os shared library: capability marshalling for tool invocations.

## Purpose

Every PaideiaOS tool declares the capabilities it consumes in a
`caps.decl` at its repo root, and receives them at exec either from the
loader's InitCap sidecar or from its parent via `sys_cap_transfer`. Two
representations therefore exist for the same thing: **text**
(`- KIND_TTY (write)`) and **bytes** (a 16-byte record carrying a `u16`
kind ordinal). libpdx-cap is the bridge, and "marshalling" here means
three concrete jobs, all pure userspace:

1. **Serialize / deserialize** a capability descriptor to and from the
   16-byte wire record (`cap_pack`, `cap_unpack`).
2. **Parse** `caps.decl` into a machine-readable record — required
   kinds, their rights-args refinements, declared output schemas
   (`caps_decl_parse`, `caps_decl_args_has/_get`).
3. **Reconcile** the two: check at exec that the received cap set
   matches the declared one in both directions — nothing MISSING,
   nothing EXTRA (`cap_manifest_verify`, `cap_unpack_checked`) — and,
   on the send side, refuse to hand a child more rights than the sender
   holds (`cap_pack_narrowed`).

It does **not** transport capabilities. No entry point issues a syscall
or invokes a cap; every function is annotated `!{mem} @{}` and the
repo's own `caps.decl` reads `requires: (none)`. It reads and writes
caller-owned buffers backed by caps the *caller* holds, which is what
keeps it linkable into every tool without widening any tool's
authority. Two further modules extend the same record: `KindUserRef`
(decode a `KIND_USER` cap for `ls --long`'s owner column) and
`SignedInode` (PdxFS v1 signed-inode layout plus the key-state gate
`cp`/`mv`/`rm` use to choose between re-signing a destination and
degrading to unsigned).

## Wire format and return codes

One `Cap` is 16 bytes, naturally 8-byte aligned — byte-identical to the
InitCap sidecar record in paideia-os `src/kernel/core/loader/init_caps.pdx`,
so a cap seeded by the loader and one received via `sys_cap_transfer`
share a single vocabulary.

| offset | width | field        | notes                                       |
|-------:|------:|--------------|---------------------------------------------|
|   `+0` |   2   | `slot`       | target `cap_table` slot, `0..255`           |
|   `+2` |   2   | `kind`       | `KIND_*` ordinal per paideia-os `cap/kind.pdx` |
|   `+4` |   4   | `rights`     | `RIGHTS_*` mask                             |
|   `+8` |   8   | `target_ptr` | kind-specific (e.g. `KIND_USER` row_id in the low 16 bits) |

Both halves move as whole qwords: `cap_pack` fuses
`slot | (kind << 16) | (rights << 32)` into one store at `[dst+0]` and
copies `target_ptr` to `[dst+8]`; `cap_unpack` mirrors with two loads
plus shifts and masks. No narrow store is used, so a Cap on the wire is
never observed torn between fields. Callers must supply 8-byte-aligned
buffers — the library does not check.

Success is `0`. Failures use the `0xFFFFFFEF..0xFFFFFFFE` band reserved
for this library — the loader's `INIT_CAPS_BAD_*` family extends upward
from `0xFFFFFFFF` and cannot collide. All codes below carry an implicit
`0xFFFFFF` prefix, and are read from `src/*.pdx`.

| code | symbol | code | symbol |
|------|--------|------|--------|
| `FE` | `CAP_BAD_SLOT` | `F6` | `CAPS_DECL_ITEM_OUT_OF_SECTION` |
| `FD` | `CAP_BAD_KIND` | `F5` | `CAP_RIGHTS_WIDENING` |
| `FC` | `CAP_MANIFEST_MISSING` | `F4` | `CAP_KIND_UNKNOWN` / `KIND_NAMES_UNKNOWN` |
| `FB` | `CAP_MANIFEST_EXTRA` | `F3` | `USER_REF_WRONG_KIND` |
| `FA` | `CAPS_DECL_REQ_OVERFLOW` | `F2` | `USER_REF_BAD_ROW` |
| `F9` | `CAPS_DECL_SCHEMA_OVERFLOW` | `F1` | `SIGNED_INODE_SIG_ABSENT` |
| `F8` | `CAPS_DECL_MALFORMED_HEADER` | `F0` | `SIGNED_INODE_KEY_LOCKED` |
| `F7` | `CAPS_DECL_MALFORMED_ITEM` | `EF` | `SIGNED_INODE_BAD_INODE` |

`CAP_KIND_UNKNOWN` and `KIND_NAMES_UNKNOWN` are one value declared in
two modules, since `KindNames` is a leaf that `Cap` calls and not the
reverse. Rejection is uniformly fail-fast: a refused `cap_pack` leaves
the destination buffer untouched, and a refused `cap_unpack_checked` or
`kind_user_ref_decode` leaves the `.bss` singletons untouched — so a
caller distinguishes a rejected operation from a successful one without
a defensive pre-clear.

## API surface

Twenty public entry points across five modules, every one `!{mem} @{}`
— memory effect only, zero capabilities. Receive-side results land in
module-owned `.bss` singletons (the `libpdx-argv` `ParsedArgs`
pattern); a caller-owned variant is deferred past 1.0.

**`src/cap.pdx` — module `Cap`** (wire record + manifest reconciliation)

```
cap_reset() -> () !{mem} @{}
    Zero the four unpacked_* slots before the next unpack.
cap_pack(dst, slot, kind, rights, target_ptr) -> u64 !{mem} @{}
    Write a 16-byte Cap to dst. CAP_OK | CAP_BAD_SLOT (slot >= 256).
cap_pack_narrowed(dst, slot, kind, original_rights, narrowed_rights, target_ptr) -> u64 !{mem} @{}
    Forward with reduced rights; CAP_RIGHTS_WIDENING unless (narrowed & ~original) == 0.
cap_unpack(src) -> u64 !{mem} @{}
    Split a wire record into the unpacked_* slots. Always CAP_OK; no validation.
cap_unpack_checked(src) -> u64 !{mem} @{}
    As cap_unpack, but CAP_MANIFEST_EXTRA if the parsed CapsDecl omits that kind.
cap_manifest_verify(decl_ptr, received_ptr, received_count) -> u64 !{mem} @{}
    Two-pass declared-vs-received reconciliation over the CapsDecl singleton.
    CAP_OK | CAP_MANIFEST_MISSING | CAP_MANIFEST_EXTRA | CAP_KIND_UNKNOWN.
```

`decl_ptr` is informational at 1.0 and never dereferenced. Constants
`CAP_ENTRY_SIZE = 16`, `CAP_ALIGN = 8`, `CAP_SLOT_MAX = 256`; singletons
`unpacked_slot`, `unpacked_kind`, `unpacked_rights`, `unpacked_target_ptr`.

**`src/caps_decl.pdx` — module `CapsDecl`** (`caps.decl` text parser)

```
caps_decl_reset() -> () !{mem} @{}
    Zero the two counters and the two diagnostic slots.
caps_decl_parse(src, src_len) -> u64 !{mem} @{}
    Parse caps.decl into req_kind_names[] / req_args_texts[] / schema_names[],
    NUL-terminating identifiers in place. CAPS_DECL_OK or a CAPS_DECL_* code,
    also recorded in error_code + error_line_index.
caps_decl_args_has(args_ptr, needle_ptr) -> u64 !{mem} @{}
    1 iff needle is a token in the "(...)" suffix, bare or as a key= half.
caps_decl_args_get(args_ptr, key_ptr) -> u64 !{mem} @{}
    1 iff key=value present; publishes caps_decl_args_value_ptr / _len as an
    interior, non-NUL-terminated slice. Bare tokens miss.
```

Both args helpers return 0 when `args_ptr == 0`, so callers need no null
guard. Grammar: `requires:` / `declares_output_schemas:` headers (each
with an inline `(none)` form), `#` comments, blank lines, and
`- IDENT ("(" args ")")? ("@" IDENT)?` items, 16 per section max.

**`src/kind_names.pdx` — module `KindNames`** (name → ordinal mirror)

```
_cap_cstr_eq(a, b) -> u64 !{mem} @{}
    NUL-terminated byte compare; 0 if equal, 1 otherwise.
kind_names_resolve(name_ptr) -> u64 !{mem} @{}
    Linear scan of the 15-row R49 KIND mirror; the ordinal, or
    KIND_NAMES_UNKNOWN (0xFFFFFFF4) on miss.
```

The table mirrors paideia-os `src/kernel/core/cap/kind.pdx`, covering
only the kinds R49-wave tools name: `KIND_PROCESS` 1, `KIND_THREAD` 2,
`KIND_PAGE_TABLE` 3, `KIND_PAGE` / `KIND_MEMORY` both 4,
`KIND_IPC_ENDPOINT` 5, `KIND_IPC_PORT` 6, `KIND_TIMER` 8,
`KIND_NOTIFICATION` 12, `KIND_REPLY` 13, `KIND_USER` 0x190,
`KIND_ELEVATE_CHANNEL` 0x191, `KIND_PDXFS_FILE` 0x195,
`KIND_PDXFS_TXN` 0x196, `KIND_TTY` 0x197. A `caps.decl` naming a kind
outside the mirror fails loudly at `cap_manifest_verify`.

**`src/kind_user_ref.pdx` — module `KindUserRef`** (`ls --long` owner column)

```
kind_user_ref_reset() -> () !{mem} @{}
    Zero the four user_ref_* slots.
kind_user_ref_decode(cap_wire_ptr) -> u64 !{mem} @{}
    Require kind == KIND_USER (0x190) and row_id = target_ptr & 0xFFFF < 16,
    then publish row_id / slot / rights / raw_target.
    USER_REF_OK | USER_REF_WRONG_KIND | USER_REF_BAD_ROW.
kind_user_ref_render_hex(user_key) -> u64 !{mem} @{}
    Render a u64 fingerprint as 16 lowercase hex digits + NUL into
    user_ref_hex_buf. Always returns 16.
```

The middle step — invoking the `KIND_USER` cap to turn a row_id into a
fingerprint — is deliberately the caller's, since it needs a cap handle
this library does not own; both entries stay pure.

**`src/signed_inode.pdx` — module `SignedInode`** (cp/mv/rm re-sign path)

```
signed_inode_key_state_reset() -> () !{mem} @{}
    Clear the key-state flag to 0 (locked).
signed_inode_key_state_set(state) -> () !{mem} @{}
    Publish the user_sk unlock state; 1 = unlocked, anything else locked.
signed_inode_has_signature(inode_ptr) -> u64 !{mem} @{}
    Read sig_present at [inode_ptr + 64]. 1 | 0 | SIGNED_INODE_BAD_INODE.
signed_inode_can_resign() -> u64 !{mem} @{}
    SIGNED_INODE_OK if key_state == 1, else SIGNED_INODE_KEY_LOCKED.
signed_inode_mark_unsigned(dst_inode_ptr) -> u64 !{mem} @{}
    Clear sig_present at [dst + 64]. SIGNED_INODE_OK | SIGNED_INODE_BAD_INODE.
```

Layout constants: `INODE_HEAD_BYTES = 64`, `SIG_PRESENT_OFFSET = 64`,
`SIG_BODY_OFFSET = 65`, `ML_DSA_65_SIG_LEN = 3309` (FIPS-204),
`SIGNED_INODE_TOTAL_BYTES = 3374`, `UNSIGNED_INODE_TOTAL_BYTES = 65`.
The module supplies the layout and the gate, not the signature: the
ML-DSA-65 sign primitive is a paideia-as `v0.33-crypto` intrinsic whose
userspace linkage has not landed, so no `signed_inode_resign` exists
yet and key material never enters this library. Note also that
`signed_inode_has_signature` reports absence as literal `0`, not as the
declared `SIGNED_INODE_SIG_ABSENT`.

## Schemas exposed

**None.** libpdx-cap declares no semantic-pipe output schemas — its own
`caps.decl` carries `declares_output_schemas: (none)` and no module
emits records to a pipe. `cap_pack` hands back raw wire bytes; the
schema wrapping a capability for semantic-pipe transport is `PdxCap`,
declared in
[libpdx-semantic-pipe](https://github.com/paideia-os/libpdx-semantic-pipe).
What it *does* define is the 16-byte binary Cap record above — a wire
layout, identical to the kernel's InitCap sidecar entry, rather than a
schema — and it consumes, without emitting, the `caps.decl` text format
specified in `design/architecture.md` §4.

## Callers

Verified by reading source in the consuming repos at their current HEAD:

- [`ls`](https://github.com/paideia-os/ls) — **linked.**
  `src/owner_col.pdx` calls `cap_unpack` and reads `unpacked_kind` and
  `unpacked_target_ptr` to render the `--long` owner column; its
  comments describe collapsing that block to one `kind_user_ref_decode`
  call now that M3-001 has shipped.
- [`shell`](https://github.com/paideia-os/shell) — **format consumer,
  not yet linked.** `src/exec.pdx` reimplements the widening check
  `(child & ~parent) == 0` inline and lays its sidecar records out in
  the Cap wire format, citing `cap_pack_narrowed` and
  `cap_manifest_verify` as the authority; `tests/test_caps_narrow.pdx`
  mirrors the same record. Its planned exec path calls
  `cap_manifest_verify` directly.
- [`cp`](https://github.com/paideia-os/cp) — **declared dependency, not
  yet linked.** `src/signed_inode.pdx` is a stub that unconditionally
  degrades to an unsigned destination, with a documented cross-repo
  dependency on this library's M3 signed-inode helpers.
- [`doc`](https://github.com/paideia-os/doc) and
  [`pkg`](https://github.com/paideia-os/pkg) — **planned.** Both name
  libpdx-cap in comments as the narrowing path for their
  `KIND_PDXFS_FILE` reads once the R42 substrate lands; no call sites.

Inferred, not individually verified: the remaining R50 coreutils
(`cat`, `mkdir`, `mv`, `rm`), since exec-time reconciliation sits on the
invocation path every tool with a `caps.decl` takes.

## Version

**v1.0.0**, tagged 2026-08-22 — milestones M1–M5 closed, public surface
and return-code vocabulary frozen. See [`CHANGELOG.md`](CHANGELOG.md)
for the milestone roll-up, the test contract, and the dual-signature
status (the two ML-DSA-65 slots in `manifest.pdxsig` are reserved
placeholders pending signing-bot infrastructure).
`design/architecture.md` is the internal spec; `STATUS.md` carries
session state. Requires paideia-as ≥ v0.33 (`mov_b` narrow load,
`@align` on `.bss` slots).

`tests/` ships two self-contained witnesses linkable by any consumer:
`m4_001_roundtrip_fuzz.pdx` (10^6-iteration pack/unpack round-trip) and
`m4_002_caps_decl_matrix.pdx` (22-stage parser, narrowing, extra-cap,
signed-inode matrix). Both return 0 on pass, else the 1-based index of
the first failure.

## Examples

Calls follow SysV — arguments in `rdi, rsi, rdx, rcx, r8, r9`, return in
`rax`. Round-trip a capability through the wire format:

```
// wire_buf is a caller-owned, 8-byte-aligned 16-byte buffer.
lea rdi, [rip + wire_buf];
mov rsi, 3;                     // slot
mov rdx, 0x197;                 // KIND_TTY
mov rcx, 0x2;                   // rights mask (RIGHTS_* per paideia-os)
mov r8,  0x1000;                // target_ptr
call cap_pack;
cmp rax, 0;
jne pack_failed;                // CAP_BAD_SLOT

call cap_reset;
lea rdi, [rip + wire_buf];
call cap_unpack;                // publishes the four unpacked_* slots
lea r11, [rip + unpacked_kind];
mov rax, [r11];                 // rax == 0x197
```

Reconcile received against declared at `_start` — the exec-time check
every tool runs before dispatch:

```
call caps_decl_reset;
lea rdi, [rip + decl_text];     // caps.decl bytes, NUL not required
mov rsi, r13;                   // decl_len
call caps_decl_parse;           // NUL-terminates idents in place
cmp rax, 0;
jne decl_malformed;             // error_line_index names the bad line

xor rdi, rdi;                   // decl_ptr informational at 1.0
lea rsi, [rip + received_caps]; // Cap[] from the InitCap sidecar
mov rdx, r14;                   // received_count
call cap_manifest_verify;
cmp rax, 0;
jne manifest_mismatch;          // MISSING | EXTRA | KIND_UNKNOWN
```

Forward a cap to a child with reduced rights, then read a rights-args
refinement (`subtree=/home`) out of the decl item:

```
lea rdi, [rip + child_wire];
mov rsi, 1;                     // slot
mov rdx, 0x195;                 // KIND_PDXFS_FILE
mov rcx, 0x3;                   // original_rights: the mask held
mov r8,  0x1;                   // narrowed_rights: the subset requested
mov r9,  r12;                   // target_ptr (the parent's target)
call cap_pack_narrowed;         // CAP_RIGHTS_WIDENING if (r8 & ~rcx) != 0
lea r11, [rip + req_args_texts];
mov rdi, [r11 + 0];             // args ptr for decl item 0, or 0
lea rsi, [rip + key_subtree];   // "subtree\0"
call caps_decl_args_get;        // 1 -> caps_decl_args_value_ptr/_len
```

## License

MIT — see [LICENSE](LICENSE).
