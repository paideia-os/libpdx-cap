# libpdx-cap — architecture

**Wave:** R49 shared library
**Repo:** github.com/paideia-os/libpdx-cap
**Upstream design:** `design/tooling/r49-r50-plan.md` §3.1 and §5.10 in
[paideia-os](https://github.com/paideia-os/paideia-os).

This document describes the internal shape of libpdx-cap. It does not
repeat the wave-level rationale from the paideia-os plan doc; read that
first for the D4 (signed manifests) + I6 (capability handoff visible +
refusable) invariants and for why libpdx-cap is the earliest shared
library in the R49 wave.

## 1. Public surface

libpdx-cap exposes five modules to its consumers (M3-001 adds
`KindUserRef`, M3-002 adds `SignedInode`; M2-001 added the
`KindNames` module below):

- `Cap` (`src/cap.pdx`) — the wire-format record + five entry points
  the exec-time flow below is *specified* to use (this is the intended
  wiring, not a claim that every consumer already does it — see
  `doc/INTEGRATION.md` §1 for which of these six have a real
  production call site today):
  - `cap_pack(dst, slot, kind, rights, target_ptr) -> u64` — write a
    16-byte Cap record into `dst`; returns `CAP_OK` or `CAP_BAD_SLOT`.
  - `cap_pack_narrowed(dst, slot, kind, original_rights, narrowed_rights, target_ptr) -> u64`
    — pack a Cap only if `narrowed_rights` is a strict subset of
    `original_rights`; returns `CAP_OK | CAP_BAD_SLOT | CAP_RIGHTS_WIDENING`.
    **Landed at M2-002.** This is the primitive the shell (and every
    tool that forwards a cap to a child) uses at exec.
  - `cap_unpack(src) -> u64` — read a 16-byte Cap record from `src`;
    populates the `unpacked_*` singleton slots and returns `CAP_OK`.
  - `cap_unpack_checked(src) -> u64` — same as `cap_unpack`, but
    additionally verifies the received kind is named by the currently-
    parsed `CapsDecl`; returns `CAP_OK | CAP_MANIFEST_EXTRA`. On EXTRA
    the `unpacked_*` slots are left untouched (fail-fast).
    **Landed at M2-003.**
  - `cap_manifest_verify(decl_ptr, received_ptr, received_count) -> u64`
    — compare a callee's parsed caps.decl against the caps it actually
    received; returns `CAP_OK | CAP_MANIFEST_MISSING | CAP_MANIFEST_EXTRA
    | CAP_KIND_UNKNOWN`. **Body landed at M2-001** (two-pass compare;
    see §7 below). `decl_ptr` is informational in M2 (the parsed record
    lives in the singleton); it is reserved for the M4 caller-owned
    variant.
- `CapsDecl` (`src/caps_decl.pdx`) — the parser for the `caps.decl` text
  file every tool ships at its repo root (per invariant I6). One entry
  point + a singleton record every consumer reads after parse; see §4.
- `KindNames` (`src/kind_names.pdx`) — a mirror of the paideia-os KIND
  vocabulary (name → ordinal) covering the R49 tooling wave (**15 rows
  after M3-001**; the KIND_TTY row landed once paideia-os cf496fb pinned
  0x197 for R30-PREP #1631). `kind_names_resolve(name_ptr) -> ord` is
  the single public entry; used internally by `cap_manifest_verify`.
  See §7 below for the rationale for keeping the mirror inside libpdx-cap.
- `KindUserRef` (`src/kind_user_ref.pdx`) — landed at M3-001. Decodes
  a wire Cap into (`row_id`, `slot`, `rights`, `raw_target_ptr`) if
  the kind lane names `KIND_USER = 0x190`; provides a companion
  `kind_user_ref_render_hex(user_key)` that formats a fingerprint word
  as 16 lowercase hex digits in a NUL-terminated buffer. Consumers:
  `ls --long` (owner column), and any coreutil whose typed-record
  schema carries a `KIND_USER_ref` field per D2 literal (§4.4 of
  the plan doc). See §9 below.
- `SignedInode` (`src/signed_inode.pdx`) — landed at M3-002. Publishes
  the PdxFS v1 signed-inode layout constants
  (`INODE_HEAD_BYTES = 64`, `SIG_PRESENT_OFFSET = 64`,
  `SIG_BODY_OFFSET = 65`, `ML_DSA_65_SIG_LEN = 3309`), a key-state
  singleton the consumer sets after unlocking `user_sk`, a
  `signed_inode_has_signature(inode_ptr)` byte-flag query, a
  `signed_inode_can_resign()` fork-decision helper, and a
  `signed_inode_mark_unsigned(dst)` primitive for the degrade path.
  Consumers: `cp`, `mv`, `rm` (per §5.6, §5.7, §5.8 of the plan doc).
  The actual ML-DSA-65 sign primitive is a paideia-as v0.33-crypto
  intrinsic and is NOT wrapped by libpdx-cap yet; see §10 below.

The consumer wires libpdx-cap into its own exec path as follows
(post-M2 flow):

```
// 1. Parse own caps.decl at startup (once per process).
CapsDecl::caps_decl_reset()
let err = CapsDecl::caps_decl_parse(decl_src, decl_len)
if err != CapsDecl::CAPS_DECL_OK { exit 3 (I6 misconfigured) }

// 2a. On receiving a cap (raw path, e.g. for InitCap seed reads
//     where the callee has not yet parsed its caps.decl):
Cap::cap_reset()
Cap::cap_unpack(wire_ptr)
// walk Cap::unpacked_kind / unpacked_rights / unpacked_target_ptr

// 2b. On receiving a cap AFTER caps.decl has been parsed (checked
//     path, M2-003): the unpack rejects an EXTRA cap synchronously.
let rc = Cap::cap_unpack_checked(wire_ptr)
if rc != Cap::CAP_OK { exit 4 (I6 capability refused) }

// 3. At exec of a CHILD (shell → tool): forward narrowed caps to the
//    child's cap array. M2-002 refuses widening at the send site.
let rc = Cap::cap_pack_narrowed(
    slot_wire_addr, slot, kind,
    my_original_rights, narrowed_rights_for_child,
    target_ptr)
if rc != Cap::CAP_OK { exit 5 (send-side widening or bad slot) }

// 4. At startup of a CHILD (after its shell-populated cap array is
//    handed over): manifest-verify the full received set against the
//    child's own caps.decl. M2-001 body performs the two-way compare.
let rc = Cap::cap_manifest_verify(0, received_caps, received_count)
if rc != Cap::CAP_OK { exit 4 (I6 capability refused) }
```

The consumer never allocates a `Cap` itself in M1 — the singleton lives
in libpdx-cap's `.bss` (see §3 below). M4 introduces a caller-owned
struct variant so multiple cap unpacks can coexist inside one process;
M1 does not need that shape.

## 2. Wire-format record shape

libpdx-cap's on-wire Cap layout is **identical to the InitCap sidecar
record** (paideia-os `src/kernel/core/loader/init_caps.pdx` §Record
layout). This is deliberate: a cap seeded by the loader and a cap
received via `sys_cap_transfer` share one on-wire vocabulary, so the
sender/receiver code paths can share validators.

| offset | width | field         | notes                                              |
|-------:|------:|---------------|----------------------------------------------------|
|    +0  |    2  | `slot`        | target cap_table slot, 0..255 (`CAP_SLOT_MAX-1`)   |
|    +2  |    2  | `kind`        | `KIND_*` per paideia-os `cap/kind.pdx`             |
|    +4  |    4  | `rights`      | `RIGHTS_*` mask per paideia-os `cap/rights.pdx`    |
|    +8  |    8  | `target_ptr`  | kind-specific; often a kind-endpoint tail          |

Total 16 bytes, natural 8-byte alignment. The record is written as **two
qwords** — cap_pack fuses `slot | (kind<<16) | (rights<<32)` into a
single qword store to `[dst+0]` and copies `target_ptr` to `[dst+8]`;
cap_unpack mirrors with two qword loads plus shifts and masks. No
narrow-store mnemonic is used and the wire buffer never observes a
torn write between fields inside a single Cap. This is the same
two-quad idiom the InitCap validator uses when reading a sidecar entry.

**Alignment discipline.** `dst` and `src` MUST be 8-byte aligned by the
caller. libpdx-cap does not check; misaligned addresses degrade to slow
unaligned accesses on some cores and may fault on others (per the
paideia-os cap/table.pdx alignment rules). The InitCap sidecar layout
guarantees alignment by construction (16-byte stride + 8-byte header
pad); consumers that lay out their own Cap arrays are expected to do
the same.

## 3. Storage model

In M1 both modules keep their receive-side state in `.bss` — the
singleton pattern from `src/parsed_args.pdx` in libpdx-argv and
`src/user/tokenizer.pdx` in paideia-os. This is deliberate for
bootstrap:

- **One `cap_unpack` at a time.** Every M1 consumer path unpacks a Cap,
  reads the fields, then either narrows it further or dispatches on it
  — the "read the fields" step never crosses another `cap_unpack`.
  Multi-cap unpacking (needed once the shell fans out to N children in
  parallel) is a post-M4 concern.
- **One `caps_decl_parse` per process.** Every tool parses its own
  caps.decl exactly once at `_start`, then dispatches. Multi-parse
  (subshell, `mux` split) is a post-M4 concern.
- **Zero heap dependency.** libpdx-cap predates any allocator in the
  R49 wave; every buffer is a static array.

M4 (`libpdx-cap.M4-001`) reruns the round-trip fuzz against a
caller-owned `Cap*` variant so tests can build many contexts in one
process. That extension changes only the two module entry points —
consumers keep the same field names.

## 4. `caps.decl` parser (M1-002)

`CapsDecl::caps_decl_parse(src, len)` walks a caps.decl text buffer
left-to-right with a byte cursor. Each line is one of:

```
line     = SPACES? content '\n'
content  = ""                             (empty)
         | "#" ANYCHAR*                   (comment)
         | "requires:"                    (start requires-section)
         | "requires: (none)"             (empty requires-section, inline)
         | "declares_output_schemas:"     (start schemas-section)
         | "declares_output_schemas: (none)"  (empty schemas-section, inline)
         | "- " item                      (list item under current section)
item     = requires-form | schema-form
requires-form  = KIND_XXX ( "(" args-text ")" )?
schema-form    = SchemaName "@" version
```

State machine:

| state    | accepts                                                                |
|----------|------------------------------------------------------------------------|
| `TOP`    | headers only (`requires:` / `declares_output_schemas:` / their inline `(none)` forms) |
| `REQ`    | list items OR the schemas header                                       |
| `SCH`    | list items only                                                        |

Records populated in the `CapsDecl` singleton:

| slot                | type       | width  | meaning                                                    |
|---------------------|------------|-------:|------------------------------------------------------------|
| `req_kind_names`    | `[u64;16]` | 128 B  | pointer per requires item; interior pointer into src       |
| `req_args_texts`    | `[u64;16]` | 128 B  | pointer per requires item to the `(` byte, or 0 if absent  |
| `req_count`         | `u64`      |   8 B  | # of requires items                                        |
| `schema_names`      | `[u64;16]` | 128 B  | pointer per schemas item; interior pointer into src        |
| `schema_count`      | `u64`      |   8 B  | # of schemas items                                         |
| `error_code`        | `u64`      |   8 B  | 0 on success, else one of `CAPS_DECL_*` constants          |
| `error_line_index`  | `u64`      |   8 B  | 0-indexed line where the error was detected (on error)     |

**In-place null-termination.** For every list item the parser writes a
NUL at the byte that would otherwise terminate the identifier — either
the `(`, the `\n`, or a trailing space. This is the same tokenizer.pdx
precedent for in-place null-termination and is safe because the caller
owns the source buffer and libpdx-cap runs synchronously inside the
caller's process. The resulting `req_kind_names[k]` pointer is directly
consumable by a C-style string compare in M2-001.

**Section-switch on schemas header.** In state `REQ` the parser also
accepts the schemas header — a valid file can be

```
requires:
  - KIND_TTY(write)
declares_output_schemas:
  - PdxFsDirEntry@0.1
```

so the state transitions on encountering `declares_output_schemas:`
mid-file. The `TOP → REQ → SCH` shape is a directed graph, not a stack;
`requires:` cannot appear inside `SCH`.

**Overflow discipline.** Every write to `req_kind_names[k]` /
`schema_names[k]` compares against `CAPS_DECL_MAX_REQ` /
`CAPS_DECL_MAX_SCHEMAS` (both 16) **before** the write. Overflow sets
`error_code = CAPS_DECL_REQ_OVERFLOW` / `CAPS_DECL_SCHEMA_OVERFLOW` and
stops the walk. The limits fit inside `cmp reg, imm ≤ 0x7FFFFFFF` by
wide margin.

## 5. Return-code vocabulary

All modules use return codes in the 0xFFFFFFxx range for failures,
mirroring the InitCap validator's `INIT_CAPS_BAD_*` codes (paideia-os
`src/kernel/core/loader/init_caps.pdx`). The two families do not
collide — the InitCap validator's codes name failures during loader
seed; libpdx-cap's codes name failures during pack/unpack/manifest —
but a caller that stashes both without tagging can still keep them
apart by the code prefix families this document reserves:

- `0xFFFFFFFE / 0xFFFFFFFD` — Cap pack-side (`CAP_BAD_SLOT`, `CAP_BAD_KIND`).
- `0xFFFFFFFC / 0xFFFFFFFB` — Cap manifest-verify-side (`MISSING`, `EXTRA`).
- `0xFFFFFFFA .. 0xFFFFFFF6` — CapsDecl parser codes (see
  `CAPS_DECL_*` in `src/caps_decl.pdx`).
- `0xFFFFFFF5` — Cap M2-002 (`CAP_RIGHTS_WIDENING`).
- `0xFFFFFFF4` — Cap M2-001 / KindNames M2-001
  (`CAP_KIND_UNKNOWN` / `KIND_NAMES_UNKNOWN`, same numeric value in
  two modules because KindNames is a leaf Cap can call but not vice
  versa; each module declares its own copy of the constant with the
  matching value).
- `0xFFFFFFF3` — KindUserRef M3-001 (`USER_REF_WRONG_KIND`).
- `0xFFFFFFF2` — KindUserRef M3-001 (`USER_REF_BAD_ROW`).
- `0xFFFFFFF1` — SignedInode M3-002 (`SIGNED_INODE_SIG_ABSENT`,
  reserved-unused as of ENH-003/libpdx-cap#12 — see §10).
- `0xFFFFFFF0` — SignedInode M3-002 (`SIGNED_INODE_KEY_LOCKED`).
- `0xFFFFFFEF` — SignedInode M3-002 (`SIGNED_INODE_BAD_INODE`).

Future codes extend downward from `0xFFFFFFEF` (M3+ reservations
appear in the individual `.plans/m3-*-notes.md`); the sidecar
validator extends upward from `0xFFFFFFFF` (`INIT_CAPS_BAD_COUNT`).
The two families cannot collide before the code space is exhausted.

## 6. Compliance with paideia-as encoding constraints

Both modules follow the constraints called out in
`design/kernel/paideia-as-conformance.md` (paideia-os repo) as they
apply to the userspace toolchain at v0.33+:

- Module names are PascalCase basename (`Cap`, `CapsDecl`) — no
  directory prefix.
- No `test` mnemonic; every zero-check uses `cmp reg, 0`.
- Every `cmp reg, imm` uses an immediate ≤ 0x7FFFFFFF (or fits in the
  small-imm sign-extend window). The 0xFFFFFF-family constants appear
  only as `mov rax, imm32` return values — the same precedent InitCap
  uses. Large-immediate masks for `and` go via `r11` when needed
  (none needed in M1).
- Register `r11` is scratch and is never assumed live across a call.
- Byte loads use `xor rax, rax; mov_b rax, [ptr]` per the paideia-as
  #1248 mitigation pattern. This shows up in `caps_decl.pdx` (which
  walks source bytes) and not in `cap.pdx` (which uses qword loads
  only).
- Leaf functions in M1: `cap_reset`, `cap_pack`, `cap_unpack`,
  `cap_manifest_verify`, `caps_decl_reset`. `caps_decl_parse` is also
  leaf — it never calls another function. SysV push/pop parity is
  therefore trivially preserved throughout.

## 7. KindNames — the paideia-os KIND vocabulary mirror (M2-001)

`KindNames` (`src/kind_names.pdx`) is the third module libpdx-cap
ships as of M2. It carries a small MIRROR of paideia-os's
`src/kernel/core/cap/kind.pdx` — for each of the 14 kinds the R49
tooling wave actually names in a `caps.decl`, one row (name string
plus a `mov rax, ord; ret` epilogue). Its single public entry
`kind_names_resolve(name_ptr) -> ord` is called by
`Cap::cap_manifest_verify` (both passes) and — once M2-003 lands —
by `Cap::cap_unpack_checked`.

The 15 mirrored rows (M3-001 scope; the KIND_TTY row added
alongside `KindUserRef`):

| ord    | name                    | source in paideia-os cap/kind.pdx / kind_tty.pdx |
|-------:|-------------------------|--------------------------------------------------|
| 1      | KIND_PROCESS            | line 60                                          |
| 2      | KIND_THREAD             | line 61                                          |
| 3      | KIND_PAGE_TABLE         | line 62                                          |
| 4      | KIND_PAGE               | line 63 (also KIND_MEMORY alias)                 |
| 4      | KIND_MEMORY             | line 85 (alias of KIND_PAGE)                     |
| 5      | KIND_IPC_ENDPOINT       | line 72 (R20b)                                   |
| 6      | KIND_IPC_PORT           | line 73                                          |
| 8      | KIND_TIMER              | line 87                                          |
| 12     | KIND_NOTIFICATION       | line 91                                          |
| 13     | KIND_REPLY              | line 92                                          |
| 0x190  | KIND_USER               | line 2498 (R48.M1 #1517)                         |
| 0x191  | KIND_ELEVATE_CHANNEL    | line 2533 (R48b substrate-prep)                  |
| 0x195  | KIND_PDXFS_FILE         | line 2566 (R48b substrate-prep)                  |
| 0x196  | KIND_PDXFS_TXN          | line 2596 (R48b substrate-prep)                  |
| 0x197  | KIND_TTY                | kind_tty.pdx line 110 (R30-PREP #1631, cf496fb)  |

Explicitly NOT in this table (post-M3 scope):

- Every derived-kind tag above `0x197` (KIND_HW_INTERRUPT and
  friends). None of them appear in an R49-tool `caps.decl`; when a
  later-wave tool needs one, a row lands here.

**KIND_TTY history.** M2 deferred this row because paideia-os HEAD at
2026-08-21 had no `KIND_TTY` symbol; the M2 header explicitly noted
that a tool declaring `KIND_TTY` would fail with `CAP_KIND_UNKNOWN`
until softarch Round 2 pinned the ordinal. paideia-os cf496fb
(R30-PREP #1631) landed `KIND_TTY = 0x197` as a derived kind over
`KIND_IPC_ENDPOINT`, at which point M3-001 added the row (`shell`,
`doc`, `ls`, and `cat` all declare `KIND_TTY` in their caps.decl).

**Miss policy.** If a caps.decl names a kind not in the mirror,
`kind_names_resolve` returns `KIND_NAMES_UNKNOWN` (`0xFFFFFFF4`), and
`cap_manifest_verify`'s Pass 1 surfaces the failure as
`CAP_KIND_UNKNOWN` — a loud, deliberate refusal, NOT a silent success.
This is safer than the alternative (assume an unknown name resolves
to a "wildcard" ordinal) because a tool that misspells a kind name in
its own caps.decl would otherwise ship with a hole in its receive-side
gate that no compiler would catch.

**Why in-repo instead of caller-supplied.** A caller-supplied resolver
would decouple libpdx-cap from paideia-os KIND versioning, at the cost
of every consumer maintaining its own mirror. Since every R49-wave
tool imports libpdx-cap, keeping ONE mirror here means ONE place to
update when a new kind lands and ONE place a reviewer inspects for
correctness. When multi-vendor tools arrive at R51+, an extension
point (`kind_names_register(name, ord)`) can layer on without
breaking the current API.

## 8. What M1 explicitly does not do

Called out here so a reader of M1 code does not mistake absence for
bug:

- **~~cap_manifest_verify has no body.~~** ✓ Landed at M2-001 (this
  commit). Two-pass compare against the CapsDecl singleton driven by
  KindNames — see §7.
- **~~No kind range bound in cap_pack.~~** ✓ Landed at ENH-009
  (libpdx-cap#17): `cap_pack` and `cap_pack_narrowed` both reject
  `kind >= 0x10000` with `CAP_BAD_KIND` before any store, instead of
  silently truncating an out-of-range kind via the assemble step's
  `& 0xFFFF`. **Still open:** the `KIND_TRANSFERABLE_TABLE` check —
  whether a given in-range kind is *allowed* to cross a process
  boundary at all — needs a paideia-os `cap/kind.pdx` mirror decision
  and is out of scope for ENH-009; it belongs in its own issue.
- **~~No rights-narrowing at send site.~~** ✓ Landed at M2-002 (this
  commit) as `cap_pack_narrowed`. Widen-check `(narrowed & ~original)
  == 0` refuses before touching `dst` with `CAP_RIGHTS_WIDENING`.
- **~~No receive-side extra-cap rejection.~~** ✓ Landed at M2-003
  (this commit) as `cap_unpack_checked`. Fails fast with
  `CAP_MANIFEST_EXTRA` and leaves `unpacked_*` untouched when the
  received kind is not named by the parsed CapsDecl.
- **~~No `KIND_USER_ref` decode.~~** ✓ Landed at M3-001 in
  `src/kind_user_ref.pdx` — `kind_user_ref_decode(wire_ptr)`
  populates `user_ref_row_id` and companions;
  `kind_user_ref_render_hex(user_key)` produces the 16-hex-digit
  owner-column string.
- **~~No signed-inode helpers.~~** ✓ Landed at M3-002 in
  `src/signed_inode.pdx` — layout constants + key-state singleton
  + `has_signature` / `can_resign` / `mark_unsigned` helpers.
  The ML-DSA-65 sign primitive itself remains a paideia-as
  v0.33-crypto intrinsic and is NOT wrapped by libpdx-cap yet
  (see §10).
- **No round-trip fuzz.** M1 has no automated round-trip test in
  `tests/`. The 10^6-cap-shape fuzz lands at M4-001; M1 relies on the
  invariant that the pack + unpack lane definitions in §2 are
  bit-exact inverses (a property the two-qword layout makes verifiable
  by inspection). A single golden round-trip cap will accompany the
  first consumer (`shell` or `pkg`) that wires libpdx-cap at exec.

## 9. `KindUserRef` — KIND_USER wire decode + owner-column hex render (M3-001)

`KindUserRef` (`src/kind_user_ref.pdx`) is the fourth module libpdx-cap
ships. It has two entry points:

- `kind_user_ref_decode(cap_wire_ptr) -> rc` — verifies the wire
  record is a `KIND_USER` cap (kind lane == 0x190) and populates
  four singleton slots (`user_ref_row_id`, `user_ref_slot`,
  `user_ref_rights`, `user_ref_raw_target`). Returns `USER_REF_OK`,
  `USER_REF_WRONG_KIND`, or `USER_REF_BAD_ROW`. Fail-fast
  discipline: on refusal the singleton is UNTOUCHED (matches
  `cap_unpack_checked`'s M2-003 shape).
- `kind_user_ref_render_hex(user_key) -> len` — renders a u64
  fingerprint word (typically obtained by invoking the KIND_USER
  cap with `USER_OP_QUERY_FP0` per paideia-os
  `kind_user.pdx` line 133) as 16 lowercase hex digits + NUL into
  `user_ref_hex_buf`. Always returns 16.

**Two-step consumer flow.** `ls --long` uses the two together:

```
// Per directory entry, before rendering the row:
KindUserRef::kind_user_ref_reset()
let rc = KindUserRef::kind_user_ref_decode(wire_ptr)
if rc != KindUserRef::USER_REF_OK {
    render "?" as owner column
    continue
}
// Invoke KIND_USER cap at KindUserRef::user_ref_slot with
// USER_OP_QUERY_FP0 → fp0. (Consumer's own syscall path;
// libpdx-cap does not issue the invoke.)
let len = KindUserRef::kind_user_ref_render_hex(fp0)
// Owner column now sits at KindUserRef::user_ref_hex_buf, `len` bytes.
```

**Why decode + render are split.** Decode is pure wire inspection;
render is pure formatting. The step in the middle (invoking the cap
to obtain the fingerprint) requires a cap handle libpdx-cap does not
own. Keeping the boundary here lets the consumer batch fingerprint
queries across N ls entries in a single syscall pass at a later
milestone without changing this library.

**Why `user_ref_row_id` and NOT a fingerprint decode.** paideia-os's
KIND_USER wire encoding puts the kernel row_id in the low 16 bits of
`target_ptr` (per `kind_user.pdx` line 950 comment
`target_ptr = row_id`); the fingerprint itself is not on the wire.
A libpdx-cap that pretended to "decode a fingerprint" would have to
mirror the kernel's `_user_table` — a synchronization hazard we
refuse. The row_id + cap-invoke round trip is the honest path.

## 10. `SignedInode` — PdxFS v1 signed-inode helpers (M3-002)

`SignedInode` (`src/signed_inode.pdx`) is the fifth module libpdx-cap
ships. It publishes:

- **Layout constants** matching the PdxFS v1 signed-inode wire
  format from `design/user/model.md` §10.2:
  - `INODE_HEAD_BYTES = 64` — the fixed head at inode offset 0.
  - `SIG_PRESENT_OFFSET = 64` — one u8 flag (0/1).
  - `SIG_BODY_OFFSET = 65` — start of the ML-DSA-65 signature body
    when the flag is 1.
  - `ML_DSA_65_SIG_LEN = 3309` — NIST FIPS-204 published parameter.
  - `SIGNED_INODE_TOTAL_BYTES = 3374` = 64 + 1 + 3309.
  - `UNSIGNED_INODE_TOTAL_BYTES = 65` = 64 + 1.
- **A key-state singleton** (`signed_inode_key_state`) the consumer
  populates at session start from the paideia-os user-sk unlock
  query. Values: `0` = locked (fail-safe default), `1` = unlocked.
- **Four entry points**:
  - `signed_inode_key_state_reset()` — clear to 0.
  - `signed_inode_key_state_set(state)` — set to whatever the caller
    passes (validation-free; only the value `1` unlocks the resign
    path, so garbage values fail closed).
  - `signed_inode_has_signature(inode_ptr) -> rc` — byte-flag query
    (`1` present, `0` absent, `SIGNED_INODE_BAD_INODE` on null). The
    `0`/absent case is the literal integer, not the declared
    `SIGNED_INODE_SIG_ABSENT` constant — resolved at ENH-003
    (libpdx-cap#12) as reserved-unused rather than redefining a
    frozen 1.0 return value; the M4-002 witness (S20-S21) already
    asserts the 1/0 shape.
  - `signed_inode_can_resign() -> rc` — pure function of key-state
    (`SIGNED_INODE_OK` if unlocked, else `SIGNED_INODE_KEY_LOCKED`).
  - `signed_inode_mark_unsigned(dst) -> rc` — writes 0 to
    `[dst + 64]`, for the degrade path.

**Consumer flow (cp §5.6 of the plan doc):**

```
if SignedInode::signed_inode_has_signature(src_inode) == 1 {
    if SignedInode::signed_inode_can_resign() == SignedInode::SIGNED_INODE_OK {
        // Attempt re-sign via paideia-as v0.33-crypto intrinsic
        // (not in libpdx-cap yet — see "what this module does NOT do"
        // below). On success the destination carries a fresh signature
        // under the invoker's user_sk. On failure, fall to the
        // mark-unsigned path with a --verbose diagnostic.
    } else {
        // Key locked. Emit --verbose diagnostic:
        //   "cp: source has signature; destination unsigned (user_sk locked)"
        SignedInode::signed_inode_mark_unsigned(dst_inode)
    }
} else {
    // Source unsigned. Destination inherits the unsigned status;
    // mark_unsigned to keep the flag byte coherent (0, not stale).
    SignedInode::signed_inode_mark_unsigned(dst_inode)
}
```

**What this module does NOT do (M3 explicitly):**

- No ML-DSA-65 sign primitive. That is a paideia-as v0.33-crypto
  intrinsic (see plan doc §2.4 "paideia-as v0.33-crypto dependency");
  wrapping it lands at a later libpdx-cap milestone once the
  intrinsic's userspace linkage is published.
- No user_sk fetch. The consumer publishes the key-state flag; the
  material bytes never enter libpdx-cap. This keeps libpdx-cap
  dependency-free per §5.10 (libpdx-cap.M1 has no library dependencies;
  M3 preserves that).
- No source-signature verify. cp's read path relies on
  KIND_PDXFS_FILE's own signature-verify hook (R42-PREP substrate);
  libpdx-cap sees only inodes the kernel has already validated.

## §4 addendum — rights-args-text helpers (M3-001)

M2 stored `req_args_texts[k]` as an opaque pointer to `(`. M3-001
lifts the interior into two query entries that consumers use to
compare received rights-args-refinements without duplicating the
tokenizer:

- `caps_decl_args_has(args_ptr, needle_ptr) -> 0 | 1` — bare-token
  membership. `caps_decl_args_has(a, "read")` returns 1 for both
  `(read)` and `(read, subtree=/home)`.
- `caps_decl_args_get(args_ptr, key_ptr) -> 0 | 1` — key=value
  lookup. On hit populates `caps_decl_args_value_ptr` and
  `caps_decl_args_value_len` (value stays in place inside the source
  buffer — the getter does NOT NUL-terminate, so multiple gets
  against the same args-text work).

Both return 0 immediately when `args_ptr == 0` (the parser's "no
args-text" encoding), so callers can dispatch through them
uniformly. Grammar covered:

```
args-text = '(' token ( ',' SPACES? token )* ')'
token     = bare-ident              | key '=' value
value     = VCHAR*                  (stops at ',', ')', ws, EOF)
```

## 11. Cross-repo dependencies

Per `design/tooling/r49-r50-plan.md` §5.10 in paideia-os:
**libpdx-cap.M1 has no library dependencies**. It is the earliest
library in the R49 wave — every other R49 library (libpdx-semantic-pipe,
libpdx-elevate, and transitively libpdx-audit) links against it or
mirrors its Cap layout.

The one direct paideia-os dependency is the R20b InitCap sidecar
layout at `src/kernel/core/loader/init_caps.pdx` — libpdx-cap's Cap
record shape MUST stay bit-identical to InitCap's sidecar record, so
a change to one requires a coordinated change to the other. This is
the shape dependency the plan doc calls out at §2.1.

paideia-as ≥ v0.33 is required by the module encoder (needed for the
`mov_b` narrow-load mnemonic used by `CapsDecl` and for the `@align`
attribute on `.bss` slots).

## 12. M4 test-suite / smoke fixtures

M4 ships two witness functions under `tests/`, each self-contained
and callable from any consumer that links libpdx-cap:

- `M4RoundtripFuzz::m4_001_roundtrip_fuzz` (M4-001) — 10^6
  LCG-driven `cap_pack` + `cap_unpack` iterations proving every
  wire-lane packing (§2) is a bit-exact inverse. Deterministic
  seed (`M4RF_LCG_SEED = 0xC0FFEE5EA5CAB1E7`) so a failure at
  iteration `N` is reproducible.
- `M4CapsDeclMatrix::m4_002_caps_decl_matrix` (M4-002) —
  30-stage matrix covering:
  - **Parse-error corpus (S1..S8):** OK inline, OK one-item,
    MALFORMED_HEADER (x2), ITEM_OUT_OF_SECTION, MALFORMED_ITEM,
    REQ_OVERFLOW, SCHEMA_OVERFLOW — one fixture per
    `CAPS_DECL_*` code plus the two OK shapes.
  - **Narrowing invariant (S9..S12):** the truth table for
    `(narrowed & ~original) == 0`: subset OK, equal OK, superset
    WIDENING, empty-orig any-narrow WIDENING. The last case
    catches the edge where the caller holds NO rights and tries
    to write a Cap with ANY rights bit set.
  - **Extra-cap rejection (S13..S17):** both surfaces that raise
    `CAP_MANIFEST_EXTRA` — `cap_unpack_checked` (M2-003) at the
    per-cap consume site and `cap_manifest_verify` (M2-001) at
    the post-load bulk check — plus `CAP_MANIFEST_MISSING` and
    `CAP_KIND_UNKNOWN` (decl names a kind not in the KindNames
    mirror).
  - **Signed-inode re-sign (S18..S22):** end-to-end M3-002 helper
    exercise — `signed_inode_key_state_reset` /
    `_set(1)` → `signed_inode_can_resign` fork, `has_signature`
    + `mark_unsigned` round-trip, `SIGNED_INODE_BAD_INODE`
    fail-fast on null input for both entries.
  - **Slot-bound coverage (S23..S30):** added at ENH-005
    (libpdx-cap#14) as the regression guard for the ENH-004
    (libpdx-cap#13) signed-`jge` → unsigned-`jae` fix. `cap_pack`
    and `cap_pack_narrowed` each get slot=255 (last accepted),
    slot=256 and slot=`0xFFFF` (first-rejected and a mid-range
    reject), and slot=`0x8000000000000000` (the case a signed
    compare reads as negative and fails open). Every rejecting
    case also asserts `dst` is left byte-for-byte untouched — the
    fail-fast contract `src/cap.pdx:175` documents but which no
    earlier stage exercised.

### Fingerprint contract

Each witness returns `0` on all-pass; on the first failure it
returns a 1-based diagnostic index (iteration index for M4-001;
stage index for M4-002). Diagnostic `.bss` slots mirror the
return so a caller can also inspect them post-return:

- `_m4rf_fail_iter` + `_m4rf_fail_field` (M4-001; six lane-id
  values distinguish which of the four wire lanes diverged or
  which operation returned non-`CAP_OK`).
- `_m4mx_stage` (M4-002; matches the return value; also written
  BEFORE each stage's first assertion so an aborted stage — one
  that faults during a nested call — still leaves the slot at
  its stage number).

### Fixture storage discipline

Every caps.decl fixture is `pub let mut [u8; N] = "..."` — landing
in `.data`, not `.rodata`. `caps_decl_parse` NUL-terminates each
list-item identifier IN PLACE at its boundary byte; a `.rodata`
fixture would fault. The `.data` fixtures are still idempotent
under repeated parse because the parser's ident walker treats
`\0` as NOT a boundary byte (only `(` `@` ` ` `\t` `\n` count), so
re-parse walks past the NUL to the next real boundary and stores
the same identifier pointer.

### Runnable harness (ENH-006 / libpdx-cap#15)

`tests/harness.pdx` + `tools/run-tests.sh` link every `src/*.pdx`
module plus the two witnesses into one hosted ELF64 executable
(`ld`, exploiting that libpdx-cap's SC+ syscall IDs — `sys_write`
= 1, `sys_exit` = 60 — are also the native Linux x86-64 syscall
numbers, so the linked image runs directly with no paideia-os
kernel or QEMU involved) and RUN it, closing the "wave-level
harness is delivered by the first R49-wave tool" gap below —
`ls` linked libpdx-cap at M3 and never delivered one. Exit `0` =
both witnesses returned 0; exit `1` / `2` print the diverging
M4-001 iteration / M4-002 stage index to stdout before exiting.

Running this harness for the first time immediately caught a
real bug: `caps_decl_parse`'s item-boundary dispatch NUL-terminated
a list item's `'\n'` boundary in place and then unconditionally
re-scanned FORWARD from that same position looking for a `'\n'`
byte to find the line's end — but the boundary byte it needed to
find was the one it had just destroyed. The scan walked into the
next line instead, silently swallowing it as trailing content on
the current item, so every OTHER item in any `requires:` /
`declares_output_schemas:` section with 2+ items was dropped
without error. Fixed by giving the post-store dispatch
(`caps_item_tail`) a flag register (r14) distinguishing "boundary
was `'\n'`/EOF, already at line end" from "boundary was `'('`/`'@'`/
whitespace, real scan still needed" — see `src/caps_decl.pdx`'s
`caps_item_ident_done_*` handlers and `caps_item_tail`.

### Consumer contract

The two witnesses are:

- **Inspectable** — reviewers read the assertion sequence
  line-by-line to confirm coverage.
- **Callable** — any userspace consumer can `call
  m4_001_roundtrip_fuzz` and `call m4_002_caps_decl_matrix`
  from its `_start` and assert `rax == 0` — exactly what
  `tests/harness.pdx` does.
- **Re-runnable** — both witnesses can be re-invoked inside the
  same process. M4-001 is seed-deterministic; M4-002 is
  fixture-idempotent per the walker analysis above.

### paideia-as conformance in tests/

- Module names PascalCase basename (`M4RoundtripFuzz`,
  `M4CapsDeclMatrix`).
- No `test` mnemonic in either witness.
- Every `cmp reg, imm` uses immediate ≤ 0x7FFFFFFF; every
  `CAPS_DECL_*` / `CAP_*` / `SIGNED_INODE_*` sentinel is staged
  via `mov r11, imm32; cmp rax, r11` — matching
  `cap_manifest_verify`'s `cmp rax, CAP_KIND_UNKNOWN` idiom
  (src/cap.pdx line 580).
- LCG constants (multiplier, increment, seed) exceed the
  compare-imm window and are `mov r11, imm64`-staged before
  arithmetic use — the tsc.pdx precedent for large-imm operands.
- SysV push/pop parity: M4-001 uses three callee-save pushes
  (rbx, r12, r13) — odd count flips rsp % 16 == 8 → 0 at each
  nested call. M4-002 uses one pad push (rbx, unused) — one push
  is enough because all state lives in `.bss`.
