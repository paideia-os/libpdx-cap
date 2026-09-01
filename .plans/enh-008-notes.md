# libpdx-cap.ENH-008 — implementation notes

**Issue:** #18
**Milestone:** Enhancement v1.x — libpdx-cap
**Status:** LANDED (follow-up to 1.0.1; no new tag cut — see CHANGELOG)

## What landed

- `src/cap_ctx.pdx` — new sixth module `CapCtx`. Five entry points
  and two layout-constant groups. Additive; no M1 API changed.
  - Layout constants:
    - Cap ctx (32 B): `CAP_CTX_SIZE`, `CAP_CTX_ALIGN`,
      `CAP_CTX_SLOT_OFF=0`, `CAP_CTX_KIND_OFF=8`,
      `CAP_CTX_RIGHTS_OFF=16`, `CAP_CTX_TARGET_PTR_OFF=24`.
    - CapsDecl ctx (416 B): `CAPS_DECL_CTX_SIZE`,
      `CAPS_DECL_CTX_ALIGN`, plus offsets for `req_kind_names` (0),
      `req_args_texts` (128), `req_count` (256), `schema_names` (264),
      `schema_count` (392), `error_code` (400), `error_line_index`
      (408).
  - Entry points:
    - `cap_ctx_reset(ctx)` / `caps_decl_ctx_reset(ctx)` — leaf,
      zero the counters (matches the singleton reset shape).
    - `cap_unpack_into(ctx, src)` — leaf; same shift-and-mask
      lane extraction as `cap_unpack`, stores land at `[ctx + off]`.
    - `cap_unpack_checked_into(ctx, src, decl_ctx)` — 5
      callee-save pushes (r12/r13/r14/r15/rbx), non-leaf (calls
      `kind_names_resolve`); rejects with `CAP_MANIFEST_EXTRA` and
      leaves ctx untouched, mirroring the singleton fail-fast.
    - `caps_decl_parse_into(ctx, src, src_len)` — 4 callee-save
      pushes (r12/r13/r14/r15), leaf (no nested calls). Parallel
      body of `caps_decl_parse` with mechanical substitution
      `[rip + <singleton>]` → `[r15 + <off>]`. Preserves the
      libpdx-cap#15 item-tail-dispatch-flag fix (r14).
    - `cap_manifest_verify_into(decl_ctx, received_ptr, received_count)`
      — 6 callee-save pushes (r12/r13/r14/r15/rbx/rbp) plus a
      `sub rsp, 8` alignment pad, non-leaf. Two-pass compare,
      same vocabulary as `cap_manifest_verify`.
- `tests/m4_002_caps_decl_matrix.pdx` — 10 new stages S31..S40
  (see CHANGELOG for the per-stage breakdown), plus four new
  buffer fixtures (`_m4mx_capctx_a`, `_m4mx_capctx_b`,
  `_m4mx_declctx_a`, `_m4mx_declctx_b`) and one fresh decl-text
  fixture `_m4mx_decl_tty_user_e8` (see "Fixture idempotence"
  below).
- `design/architecture.md` §3 — added "ENH-008 landed" note;
  §12 — S23..S30 slot-bound entry now sits alongside a new
  S31..S40 caller-owned re-entrancy entry, and the M4-002 stage
  count is bumped to 40.
- `CHANGELOG.md` — new "Unreleased" section (ENH-008 shipped);
  1.0.1's "Deferred: ENH-008" line marked superseded.

## Design decisions

1. **New module, not inline extension.** ENH-008 lives in a sixth
   module (`src/cap_ctx.pdx`) rather than extending `Cap` /
   `CapsDecl` in place. Two reasons:
   - The 1.0 API surface is frozen — modifying the existing entry
     points would risk subtle regressions and would need a version
     bump for callers.
   - Consumers who don't need re-entrancy (like `ls`) don't have
     to know CapCtx exists; consumers who do can import it
     explicitly.
2. **Parallel `caps_decl_parse_into` body rather than refactor.**
   The alternative — refactor `caps_decl_parse` to take an
   implicit ctx pointer and have the singleton case wrap it —
   requires the singleton fields to be contiguous in `.bss`
   (paideia-as's declaration order does not guarantee this) OR
   an extra layer of indirection that would be more error-prone
   than the ~400 lines of mechanical duplication. The two paths
   are documented as bit-identical in the module header.
3. **No new return codes.** `_into` variants return the same
   vocabulary as their singleton counterparts. Callers see one
   error surface.
4. **`cap_manifest_verify`'s reserved `decl_ptr` stays
   informational.** ENH-008 delivers the promised
   caller-owned variant under the `_into` name; the 1.0 entry
   point keeps its documented behaviour (decl_ptr accepted, not
   dereferenced). Changing the 1.0 entry to conditionally
   dereference decl_ptr would be a subtle ABI change even if
   backwards-compatible for the "pass 0" case.
5. **Alignment pad in `cap_manifest_verify_into` uses
   `sub rsp, 8` rather than a 7th push.** 6 real callee-saves +
   4-byte `sub rsp, 8` is more explicit about the pad's purpose
   than 7 pushes with one dummy. Matched `add rsp, 8` before
   the pop sequence.

## Fixture idempotence caveat surfaced

The M4-002 module header claims caps.decl fixtures are idempotent
under repeated parse because "the parser's ident walker treats
`\0` as NOT a boundary byte ... so re-parse walks past the NUL to
the next real boundary and stores the same identifier pointer."

**This is only true for single-item fixtures.** For a multi-item
fixture like `_m4mx_decl_tty_user`
(`"requires:\n- KIND_TTY\n- KIND_USER\n"`), the first parse
NUL-terminates BOTH item boundaries — the `\n` after KIND_TTY at
pos 20 AND the `\n` after KIND_USER at pos 32. On second parse
there are no `\n` bytes left in the buffer, so the ident walker
starts at "KIND_TTY", walks past the NUL at pos 20, past the "-"
and " " (which IS a boundary — space at pos 22), and records ONE
item whose ident-pointer starts at pos 12 and terminates at pos
22 after a fresh NUL. `req_count` reads back as 1, not 2.

This shows up ONLY when a multi-item fixture is parsed twice
inside a single witness invocation — which happens exactly once,
at S33 (which reparses `_m4mx_decl_tty_user` after S15 already
consumed it). Fixed for S33 by adding a fresh
`_m4mx_decl_tty_user_e8` copy dedicated to the ENH-008 sub-corpus,
same discipline S23..S30 use to keep `_m4mx_slot_buf` isolated
from `_m4mx_cap_buf`.

Every other fixture in the matrix is either single-item (ok2),
zero-item (ok1, all overflow / malformed cases stop before item
recording), or exercised only once. No other stage was affected.

## Verification

- `bash tools/run-tests.sh` → both witnesses return 0. 40 stages
  pass (up from 30).
- No `@no_frame`, no `test` mnemonic, no `cmp reg,imm > 0x7FFFFFFF`
  (all 0xFFFFFFxx sentinels stage via `mov r11, imm32` before
  `cmp` or land as `mov rax, imm32` return-store values).
- Every `mov_b rax, [...]` is preceded by `xor rax, rax`
  (#1248 mitigation, exhaustive).
- push/pop parity confirmed per function.
- rsp alignment at nested-call sites confirmed per function
  (entry rsp % 16 == 8; pushes flip to 0 at each call site).

## Not in scope for ENH-008

- No consumer migration. `shell`'s fan-out path is the natural
  design partner (per the issue body) and will drive any layout
  refinements before 1.0.2 is cut.
- No refresh of `manifest.pdxsig`. The 1.0.1 manifest is stale
  for the new `src/cap_ctx.pdx` and the additions to
  `tests/m4_002_caps_decl_matrix.pdx`. A follow-up (see
  CHANGELOG "Release-manifest note") cuts 1.0.2 after
  consumer validation.
- No `KIND_TRANSFERABLE_TABLE` check. That remains the still-open
  successor to ENH-009 per `src/cap.pdx:85-87`.
