# libpdx-cap.M4-002 — implementation notes

**Issue:** #9
**Status:** LANDED

## What landed

- `tests/m4_002_caps_decl_matrix.pdx` (NEW) — `M4CapsDeclMatrix`
  module publishing the witness function `m4_002_caps_decl_matrix`
  (22 stages), 10 caps.decl fixtures in `.data`, and three
  scratch buffers (`_m4mx_cap_buf`, `_m4mx_inode_buf`,
  `_m4mx_stage`).

- `tests/README.md` — extended with the M4-002 fingerprint
  contract + the four-sub-corpus stage table.

## Design decisions

### One witness for all four M4-002 sub-corpora

The plan doc names three deliverables for M4-002:

1. caps.decl parse-error corpus
2. narrowing invariant matrix
3. extra-cap rejection

The M4 milestone summary at §5.10 additionally names "signed-inode
re-sign correctness". Rather than four separate witness functions,
M4-002 bundles all four into a single 22-stage function so:

- One `call m4_002_caps_decl_matrix` covers the whole M4
  correctness gate (the smoke tree at the consumer runs one line,
  not four).
- The stage counter (`_m4mx_stage`) gives a single-diagnostic
  jump-to-line for any regression, regardless of sub-corpus.
- Cross-sub-corpus state hazards (a stray `caps_decl_parse`
  leaving CapsDecl populated for a later sub-corpus's
  `cap_manifest_verify` call) are impossible when the whole
  sequence is one function.

### Fixtures in `.data`, not `.rodata`

`caps_decl_parse` NUL-terminates each list-item identifier IN
PLACE at its boundary byte (`(`, `\n`, `\t`, ` `, or `@`). If a
fixture lives in `.rodata`, the write faults. If it lives in
`.data` (mutable initialized, via `pub let mut ... = "..."`), the
write lands safely.

paideia-as supports `pub let mut [u8; N] = "..."` — echoed by
`src/user/echo_client.pdx` line 124's `pub let mut req_payload
: [u8; 8] = "PAIDEIA!"`. The emit test at
`tools/paideia-as/crates/paideia-as/tests/build_emit/module_let_no_text_emission.rs`
confirms `let mut` lands in `.data`.

### Fixtures are re-runnable in the same process

`caps_decl_parse` writes `\0` over the `\n` that terminated each
identifier line. On a second parse of the same fixture, the
walker at `caps_item_walk_ident` treats `\0` as NOT a boundary
byte (only `(` `@` ` ` `\t` `\n` count), so it walks past the
NUL to the next real boundary — the next `\n` in the fixture, or
EOF. The stored `req_kind_names[k]` pointer still starts at the
identifier's first byte; the pointer's underlying C-string still
terminates at the same NUL because the byte is still `\0`. Result:
`kind_names_resolve(req_kind_names[k])` returns the same ordinal
on run 1 and run N.

Fixtures that never reach the item-recording arm
(`_m4mx_decl_ok1` because sections are empty inline, plus the
four MALFORMED_* and ITEM_OOS fixtures because parse fails
before recording) never trigger a NUL write. The overflow
fixtures write NULs only for the first 16 items (before the 17th
triggers overflow); on re-parse the same 16 items resolve
identically.

The witness is therefore re-runnable inside one process — a
property the plan does not require, but which cuts the smoke
loop's turnaround time when the wave harness lands.

### Widening as `(narrowed & ~original) != 0`

`cap_pack_narrowed`'s widen check is `(narrowed & ~original) == 0`
per src/cap.pdx line 242. The four narrowing stages exhaust the
truth table:

| S  | original | narrowed | narrowed & ~original | expected                    |
|----|----------|----------|----------------------|-----------------------------|
| 9  | `0xF`    | `0x3`    | `0x0`                | `CAP_OK` (subset)           |
| 10 | `0xF`    | `0xF`    | `0x0`                | `CAP_OK` (equal → subset)   |
| 11 | `0x3`    | `0x7`    | `0x4`                | `CAP_RIGHTS_WIDENING`       |
| 12 | `0x0`    | `0x1`    | `0x1`                | `CAP_RIGHTS_WIDENING`       |

The S12 case (empty original) catches the degenerate scenario
where the caller holds NO rights and tries to write a Cap with
ANY rights bit set — a case that would silently succeed if the
check were `narrowed <= original` (numeric compare) instead of
`(narrowed & ~original) == 0` (bitset compare).

### Extra-cap surface tested at both `cap_unpack_checked` and `cap_manifest_verify`

M2-003 and M2-001 both surface `CAP_MANIFEST_EXTRA`; the plan
doc lists them as separate primitives and the header of each
notes the other. The extra-cap sub-corpus tests both:

- S13/S14 — `cap_unpack_checked` at the per-cap consume site.
- S16 — `cap_manifest_verify` at the post-load bulk check.

Both should refuse a KIND_USER cap when the parsed decl names
only KIND_TTY, producing the same `CAP_MANIFEST_EXTRA` code.

### `CAP_KIND_UNKNOWN` reachable via a decl-side unknown

`cap_manifest_verify`'s Pass 1 resolves each declared name via
`kind_names_resolve` and surfaces `CAP_KIND_UNKNOWN` when the
name is not in the KindNames mirror. Stage 17 uses
`_m4mx_decl_unknown = "requires:\n- KIND_NOSUCH\n"`; the resolve
returns `KIND_NAMES_UNKNOWN (0xFFFFFFF4)` and `cap_manifest_
verify` returns the same numeric value (aliased as
`CAP_KIND_UNKNOWN`). Received count is 0 so Pass 1 fires before
any receive scan; the sub-corpus tests the decl-side path
explicitly.

### Signed-inode re-sign fixture

The M3-002 helper set is:
- `signed_inode_key_state_reset()` — clear the key-state flag.
- `signed_inode_key_state_set(state)` — write the flag verbatim.
- `signed_inode_can_resign()` — pure function of the flag.
- `signed_inode_has_signature(inode_ptr)` — byte-flag query at
  `[inode_ptr + 64]`.
- `signed_inode_mark_unsigned(inode_ptr)` — write 0 to
  `[inode_ptr + 64]`.

Stages S18/S19 verify the key-state fork; S20 verifies the
null-inode fail-fast on `has_signature`; S21 exercises the
happy-path round-trip (write `1` to the fixture inode's
sig_present byte via `mov_b`, query returns 1; mark_unsigned
returns OK; re-query returns 0); S22 verifies the null-inode
fail-fast on `mark_unsigned`. Together they cover every arm of
the five entry points except `key_state_set(state)` for values
other than 0 or 1 — that path is a store-through, no branch,
and is covered incidentally by S19's `set(1)`.

The re-sign PATH itself (the actual ML-DSA-65 sign) is
out-of-scope for M4-002 because it is out-of-scope for M3-002 —
the paideia-as v0.33-crypto intrinsic that would wrap the sign
is not yet linked. When the intrinsic ships and a follow-up
milestone adds `signed_inode_resign(src, dst, user_sk_slot)`,
that entry gets its own stage(s) here.

### Stage counter written BEFORE assertions

Each stage's first three instructions are:

```
mov rax, N;
lea r11, [rip + _m4mx_stage];
mov [r11], rax;
```

The stage number is durable in `.bss` before any assertion runs.
On a failure — whether from a subsequent `cmp` or from a nested
call that faults or aborts before returning — a caller reading
`_m4mx_stage` sees the failing stage. `_m4mx_fail` also re-loads
this slot to produce the return-in-rax value, so the two
diagnostics agree.

### One callee-save push (pure padding)

The witness holds no cross-call state in a callee-save register
— the stage counter lives in `.bss`. But it IS non-leaf (calls
into `caps_decl_reset`, `caps_decl_parse`, `cap_pack`, etc.), so
`rsp % 16 == 0` at each nested call site is required by SysV.

Entry `rsp % 16 == 8`; one push flips to 0. `push rbx` is a
one-byte encoding; `sub rsp, 8` is four bytes. Both work, but the
push idiom is a shape reviewers parse faster, and rbx is the
conventional "spare callee-save" scratch — no downstream reader
mistakes it for meaningful state.

## paideia-as conformance checklist

- Module name PascalCase basename (`M4CapsDeclMatrix`): yes.
- No `test` mnemonic: every zero-check uses `cmp rax, 0` or
  `cmp reg, imm` with small imm.
- `cmp reg, imm ≤ 0x7FFFFFFF`: yes — every `CAPS_DECL_*`, `CAP_*`,
  and `SIGNED_INODE_*` error code (all 0xFFFFFFxx values) is
  staged via `mov r11, imm32; cmp rax, r11` — the same pattern
  cap_manifest_verify uses for its `cmp rax, CAP_KIND_UNKNOWN`
  (src/cap.pdx line 580).
- Large-imm returns: N/A — return values are 0 or 1..22 (all
  fit imm32).
- `r11` scratch: yes — used both for imm staging AND for LEA of
  .bss slots + fixture addresses.
- Byte reads: N/A — no byte loads.
- Byte writes: `mov_b [r11], rax` (rax pre-set to 1) when
  preparing the inode fixture's sig_present flag — mirror of
  caps_decl.pdx's NUL-terminate stores.
- SysV push/pop parity: 1 push (rbx) with matched pop on both
  exits (`_m4mx_fail` and the all-pass tail).

## Fixture byte counts (verified)

| Fixture                | `[u8; N]` | Purpose                                     |
|------------------------|-----------|---------------------------------------------|
| `_m4mx_decl_ok1`       | 49        | OK; both sections empty inline              |
| `_m4mx_decl_ok2`       | 21        | OK; one requires item (KIND_TTY)            |
| `_m4mx_decl_malf_hdr1` | 7         | MALFORMED_HEADER; unknown word              |
| `_m4mx_decl_malf_hdr2` | 11        | MALFORMED_HEADER; bad tail after `requires:` |
| `_m4mx_decl_item_oos`  | 11        | ITEM_OUT_OF_SECTION; dash in TOP            |
| `_m4mx_decl_malf_item` | 12        | MALFORMED_ITEM; empty ident after `-`       |
| `_m4mx_decl_req_over`  | 95        | REQ_OVERFLOW; 17 items                      |
| `_m4mx_decl_sch_over`  | 110       | SCHEMA_OVERFLOW; 17 items                   |
| `_m4mx_decl_tty_user`  | 33        | Decl {KIND_TTY, KIND_USER} for MISSING test |
| `_m4mx_decl_unknown`   | 24        | Decl {KIND_NOSUCH} for KIND_UNKNOWN test    |

Verified against the string literals byte-for-byte.

## What's next

- M5-001 dual-signed release + `.pdxdoc` + mirror push. The M4
  witnesses become the source of the "acceptance criteria" section
  in `doc libpdx-cap`.
- When paideia-as v0.33-crypto intrinsic linkage lands, extend
  the S18..S22 range with a full-resign stage exercising the
  actual ML-DSA-65 sign call.
