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

libpdx-cap exposes two modules to its consumers:

- `Cap` (`src/cap.pdx`) — the wire-format record + three entry points
  every consumer wires at exec:
  - `cap_pack(dst, slot, kind, rights, target_ptr) -> u64` — write a
    16-byte Cap record into `dst`; returns `CAP_OK` or `CAP_BAD_SLOT`.
  - `cap_unpack(src) -> u64` — read a 16-byte Cap record from `src`;
    populates the `unpacked_*` singleton slots and returns `CAP_OK`.
  - `cap_manifest_verify(decl_ptr, received_ptr, received_count) -> u64`
    — compare a callee's parsed caps.decl against the caps it actually
    received; returns `CAP_OK | CAP_MANIFEST_MISSING | CAP_MANIFEST_EXTRA`.
    **M1 ships the skeleton (returns CAP_OK unconditionally); M2-001
    fills the body.**
- `CapsDecl` (`src/caps_decl.pdx`) — the parser for the `caps.decl` text
  file every tool ships at its repo root (per invariant I6). One entry
  point + a singleton record every consumer reads after parse; see §4.

The consumer wires libpdx-cap into its own exec path as follows:

```
// 1. Parse own caps.decl at startup (once per process).
CapsDecl::caps_decl_reset()
let err = CapsDecl::caps_decl_parse(decl_src, decl_len)
if err != CapsDecl::CAPS_DECL_OK { exit 3 (I6 misconfigured) }

// 2. On receiving a cap (e.g. from sys_cap_transfer or InitCap seed):
Cap::cap_reset()
Cap::cap_unpack(wire_ptr)
// walk Cap::unpacked_kind / unpacked_rights / unpacked_target_ptr

// 3. At exec of a child (shell → tool):
let rc = Cap::cap_manifest_verify(child_decl, received_caps, received_count)
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

Both modules use return codes in the 0xFFFFFFxx range for failures,
mirroring the InitCap validator's `INIT_CAPS_BAD_*` codes (paideia-os
`src/kernel/core/loader/init_caps.pdx`). The two families do not
collide — the InitCap validator's codes name failures during loader
seed; libpdx-cap's codes name failures during pack/unpack/manifest —
but a caller that stashes both without tagging can still keep them
apart by the two-code prefix families this document reserves:

- `0xFFFFFFFE / 0xFFFFFFFD` — pack-side (`CAP_BAD_SLOT`, `CAP_BAD_KIND`).
- `0xFFFFFFFC / 0xFFFFFFFB` — manifest-verify-side (`MISSING`, `EXTRA`).
- `0xFFFFFFFA .. 0xFFFFFFF6` — caps.decl parser codes (see
  `CAPS_DECL_*` in `src/caps_decl.pdx`).

Future codes extend downward from `0xFFFFFFF6`; the sidecar validator
extends upward from `0xFFFFFFFF` (`INIT_CAPS_BAD_COUNT`). The two
families cannot collide before the code space is exhausted.

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

## 7. What M1 explicitly does not do

Called out here so a reader of M1 code does not mistake absence for
bug:

- **cap_manifest_verify has no body.** M1 ships the skeleton; the
  actual OK | MISSING | EXTRA compare lands at M2-001. The signature
  is frozen at M1 so the M2 change is a body-only edit; consumers can
  already wire the call site.
- **No kind-transferable check in cap_pack.** M1 accepts any u16 kind.
  M2-001 wires `CAP_BAD_KIND` up alongside manifest_verify's full logic
  (the two features share the same `KIND_TRANSFERABLE_TABLE` — the
  cap/kind.pdx analog to `KIND_SEEDABLE_TABLE`).
- **No rights-narrowing at send site.** cap_pack in M1 writes whatever
  rights the caller passes. Narrowing (widening → reject) lands at
  M2-002.
- **No receive-side extra-cap rejection.** cap_unpack in M1 accepts
  any kind. M2-003 wires the extra-cap rejection into the unpack path.
- **No `KIND_USER_ref` decode.** `unpacked_kind == KIND_USER` yields a
  raw `unpacked_target_ptr` that consumers cannot render as a user
  name. `ls --long` owner rendering lands at M3-001.
- **No signed-inode helpers.** cp/mv/rm's re-sign-under-invoker path
  lands at M3-002.
- **No round-trip fuzz.** M1 has no automated round-trip test in
  `tests/`. The 10^6-cap-shape fuzz lands at M4-001; M1 relies on the
  invariant that the pack + unpack lane definitions in §2 are
  bit-exact inverses (a property the two-qword layout makes verifiable
  by inspection). A single golden round-trip cap will accompany the
  first consumer (`shell` or `pkg`) that wires libpdx-cap at exec.

## 8. Cross-repo dependencies

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
