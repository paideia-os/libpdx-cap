# libpdx-cap.M1-002 — implementation notes

**Issue:** #2
**Status:** LANDED
**Landed by:** Fix #2

## What landed

- `src/caps_decl.pdx` — `CapsDecl` module implementing the caps.decl
  parser:
  - Return codes: `CAPS_DECL_OK`, `CAPS_DECL_REQ_OVERFLOW`,
    `CAPS_DECL_SCHEMA_OVERFLOW`, `CAPS_DECL_MALFORMED_HEADER`,
    `CAPS_DECL_MALFORMED_ITEM`, `CAPS_DECL_ITEM_OUT_OF_SECTION`.
  - Storage caps: `CAPS_DECL_MAX_REQ = 16`, `CAPS_DECL_MAX_SCHEMAS = 16`.
  - `.bss` singleton: `req_kind_names`, `req_args_texts`, `req_count`,
    `schema_names`, `schema_count`, `error_code`, `error_line_index`.
  - `caps_decl_reset()` — zero the four counters + two error slots.
  - `caps_decl_parse(src, len)` — line-oriented parser; state machine
    TOP → REQ → SCH; in-place NUL-termination at item boundaries.
- `STATUS.md` — M1 CLOSED, both issues LANDED.

## Grammar accepted by M1-002

Per design/architecture.md §4:

```
file    = line*
line    = SPACES? content NL
content = ""                                    (empty)
        | "#" ANYCHAR*                          (comment)
        | "requires:"                           (start REQ)
        | "requires: (none)"                    (empty REQ, stays TOP)
        | "declares_output_schemas:"            (start SCH)
        | "declares_output_schemas: (none)"     (empty SCH, stays TOP)
        | "-" SPACES item                       (list item)
item    = IDENT ( "(" ANYCHAR* ")" )? ( "@" IDENT )?
```

The parser recognises the canonical libpdx-cap/caps.decl file at repo
root: two headers, both `(none)`-terminated.

## State machine details

| state | valid inputs                                                        | transition                     |
|------:|---------------------------------------------------------------------|--------------------------------|
| TOP   | `requires:` / `requires: (none)` / `declares_output_schemas:` / `d…: (none)` / `#` / empty | TOP → {TOP|REQ|SCH} on header  |
| REQ   | list item / `declares_output_schemas:` / `d…: (none)` / `#` / empty | REQ → {REQ|TOP|SCH} on header  |
| SCH   | list item / `#` / empty                                             | SCH stays SCH                  |

A list item ('-') in TOP state raises `CAPS_DECL_ITEM_OUT_OF_SECTION`.
An unknown first-token in any state raises `CAPS_DECL_MALFORMED_HEADER`.

## Registers + calling convention

`caps_decl_parse` is a leaf function that uses two callee-save registers
(`r12` for line_index, `r13` for a per-line walk cursor). Two pushes at
entry, two pops at exit — SysV parity preserved. Because the function
makes NO nested calls, the resulting rsp % 16 offset is irrelevant.

`caps_decl_reset` is trivially leaf (four .bss zero-stores + ret).

All byte reads use the paideia-as `xor rax, rax; mov_b rax, [ptr]`
mitigation pattern (#1248). Every `cmp reg, imm` uses an immediate
≤ 0x7FFFFFFF (largest constant is 16 for the overflow gates).

## In-place NUL-termination

For every recorded list item the parser writes a NUL at the identifier
boundary byte — `(`, `@`, ` `, `\t`, or `\n`. This is the tokenizer.pdx
+ libpdx-argv parser.pdx precedent and is safe because the caller owns
the source buffer and libpdx-cap runs synchronously inside the caller's
process. Consumers (cap_manifest_verify at M2-001) can then C-string-
compare `req_kind_names[k]` against known KIND names.

When the boundary was `(`, the byte becomes NUL BUT the pointer to the
`(` is captured first (into `rcx` via `mov rcx, r13` before the
NUL-store) and recorded in `req_args_texts[k]`. Consumers that want to
inspect the args (`read, subtree=/home` etc.) walk from that pointer;
the NUL at the `(` byte does not affect them because they start at the
next byte.

## What's next

- M2-001: fill `Cap::cap_manifest_verify` body — walk req_count /
  received_count in a two-way compare, resolve KIND names via cap/kind.pdx
  lookup, produce OK | MISSING | EXTRA.
- M2-002: rights-narrowing at cap_pack send site.
- M2-003: extra-cap rejection at cap_unpack receive site.
