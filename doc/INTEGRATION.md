# libpdx-cap — Integration Guide

**Status:** ENH-007 (libpdx-cap#16). This document exists because
libpdx-cap shipped a helper (`kind_user_ref_decode`, M3-001) designed
for a named consumer (`ls`) and never told that consumer to migrate,
and because `design/architecture.md` §1 describes an exec-time
reconciliation flow that reads as established practice when it is, as
of this writing, wired by zero tools — `ls` included. Both gaps are
closed below: a copy-pasteable exec-time sequence, the `ls` owner-column
integration as the one verified reference, an M1→M3 migration table,
and an explicit statement of what is specified versus what actually
runs in production today.

---

## 1. What actually has production call sites today

Be precise about this before anything else, because
`design/architecture.md` §1 does not distinguish it well:

| Step | Specified in §1? | Any production call site? |
|---|---|---|
| `caps_decl_parse` (parse own caps.decl at `_start`) | Yes | **No** |
| `cap_unpack_checked` (per-cap receive-side gate) | Yes | **No** |
| `cap_manifest_verify` (once, post-load) | Yes | **No** |
| `cap_pack_narrowed` (send-site, shell → child) | Yes | **No** |
| `cap_unpack` + raw singleton reads (M1 API) | Superseded by M3 | **Yes** — `ls` (§3 below) |
| `kind_user_ref_decode` (M3-001, supersedes the above) | Yes | **No** — `ls` has not migrated |

In other words: the exec-time reconciliation flow in §2 below is a
correct description of what libpdx-cap's API is *for*, and every
primitive in it is real, tested code (`tests/harness.pdx` runs both
M4 witnesses end-to-end — see `tests/README.md`). But no tool in the
org runs that flow yet. The only genuine production integration is
`ls`'s owner column, and it uses the older M1 shape. Anyone integrating
libpdx-cap today is the first production caller of whichever piece
they wire up — plan accordingly (test your own call site; don't assume
an existing consumer has already shaken out the bugs).

---

## 2. Exec-time wiring — the specified flow

This is the sequence `design/architecture.md` §1 describes every tool
running at `_start`, before dispatching to its own logic. All calls
follow SysV: arguments in `rdi, rsi, rdx, rcx, r8, r9`; return in `rax`.

### 2.1 Parse your own `caps.decl`

```
call caps_decl_reset;
lea rdi, [rip + decl_text];     // caps.decl bytes, NUL not required
mov rsi, r13;                   // decl_len
call caps_decl_parse;           // NUL-terminates idents in place
cmp rax, 0;
jne decl_malformed;             // error_line_index names the bad line
```

`decl_text` is your own compiled-in `caps.decl` (embedded as a `.data`
fixture — see any `tests/m4_002_*` fixture for the pattern, or ship it
as a build-time-generated buffer). It must live in writable memory:
`caps_decl_parse` NUL-terminates each list-item identifier in place at
its boundary byte, so a `.rodata` placement faults.

### 2.2 Gate each received cap at consume time

For every `Cap` you pull off the wire (from the InitCap sidecar or a
`sys_cap_transfer`), gate it through `cap_unpack_checked` rather than
the raw `cap_unpack`:

```
lea rdi, [rip + wire_ptr];      // one 16-byte Cap record
call cap_unpack_checked;
cmp rax, 0;
jne cap_rejected;                // CAP_MANIFEST_EXTRA
// on success, unpacked_slot / _kind / _rights / _target_ptr are live
```

`cap_unpack_checked` refuses (leaving the four `unpacked_*` singletons
untouched) if the cap's kind is not named by the `caps.decl` you just
parsed. This is the same rejection code (`CAP_MANIFEST_EXTRA`) that
`cap_manifest_verify` uses for the bulk check below — one vocabulary
across both surfaces.

### 2.3 Verify the full received set once, after every cap has landed

```
xor rdi, rdi;                    // decl_ptr informational at 1.0 —
                                  // pass 0 or a lea; not dereferenced
lea rsi, [rip + received_caps];  // Cap[] from the InitCap sidecar
mov rdx, r14;                    // received_count
call cap_manifest_verify;
cmp rax, 0;
jne manifest_mismatch;           // MISSING | EXTRA | KIND_UNKNOWN
```

This is a bulk reconciliation, distinct from the per-cap gate in 2.2:
it catches a cap your `caps.decl` *requires* that never arrived
(`CAP_MANIFEST_MISSING`), which `cap_unpack_checked` — driven entirely
by what you already received — cannot detect on its own.

### 2.4 Forward a cap to a child with reduced rights

Any tool that execs a child (`shell` is the canonical case) narrows
rights at the send site rather than forwarding its own cap verbatim:

```
lea rdi, [rip + child_wire];
mov rsi, 1;                      // slot
mov rdx, 0x195;                  // KIND_PDXFS_FILE
mov rcx, 0x3;                    // original_rights: the mask held
mov r8,  0x1;                    // narrowed_rights: the subset requested
mov r9,  r12;                    // target_ptr (the parent's target)
call cap_pack_narrowed;          // CAP_RIGHTS_WIDENING if (r8 & ~rcx) != 0
```

A single-process consumer note (this is `design/architecture.md` §3's
documented limitation, not a bug): every step above reads and writes
module-owned `.bss` singletons. Interleaving two live `cap_unpack`s,
or parsing two `caps.decl`s, in the same process requires call-ordering
discipline the API does not (yet) give you a way to express — see
ENH-008 (libpdx-cap#18) if that is your situation (e.g. a fan-out
supervisor holding several caps live at once).

---

## 3. The one verified reference integration: `ls`'s owner column

`ls` is, at the time of writing, the only tool repo whose libpdx-cap
call site has actually been read and confirmed to link and call this
library in production:

- `manifest.pdxproj:66` — `libpdx-cap @ ^1.0`, a real version-pinned
  dependency declaration.
- `src/owner_col.pdx:259` — `call cap_unpack;` inside
  `owner_col_render_from_wire`'s decode block.
- `src/owner_col.pdx:262` and `:269` — `lea r11, [rip + unpacked_kind]`
  and `lea r11, [rip + unpacked_target_ptr]`, reading libpdx-cap's
  `.bss` singletons directly after the `cap_unpack` call.

`ls`'s own header comment (`src/owner_col.pdx:33-52`) is explicit about
why it looks like this: it is a deliberate **M2-era shim**, written
before `kind_user_ref_decode` existed, and it says so in its own words —
"When libpdx-cap.M3 lands `kind_user_ref_decode(cap_ptr) -> user_row`,
`owner_col_render_from_wire` drops the inline decode and calls the
library helper instead." `libpdx-cap.M3-001` shipped on 2026-08-22.
`ls` has not migrated, because nothing told it to — which is the gap
§4 below closes.

Note what `ls` does **not** call: `cap_unpack_checked`, `caps_decl_parse`,
or `cap_manifest_verify`. Its owner column is a pure decode (read a Cap,
render a string) with no exec-time reconciliation involved — a
legitimate, narrower use of the library than §2 describes, and a
reminder that not every consumer needs the full flow.

---

## 4. M1 → M3 migration: `ls`'s owner-column shim

The migration `ls`'s own header comment promises, made concrete. This
is the exact six-line-to-two-line collapse `ls`'s
`owner_col_render_from_wire` can make today (not applied here — this
repo does not touch `ls`'s source; this is the recipe for whoever picks
up the `ls`-side change).

**Before (M1 shim, `ls/src/owner_col.pdx:257-270`, paraphrased):**

```
call cap_unpack;                          // Step 1: decode

lea r11, [rip + unpacked_kind];
mov rax, [r11];
cmp rax, 0x190;                           // KIND_USER
jne owner_col_not_user;                   // Step 2: kind check

lea r11, [rip + unpacked_target_ptr];
mov rax, [r11];
and rax, 0xFFFF;                          // Step 3: extract row (low 16 bits)
mov r13, rax;                             // r13 = user_row
```

**After (M3 API):**

```
call kind_user_ref_decode;                // populates user_ref_row_id,
                                           // user_ref_slot, user_ref_rights,
                                           // user_ref_raw_target — or
                                           // returns USER_REF_WRONG_KIND /
                                           // USER_REF_BAD_ROW
cmp rax, 0;
jne owner_col_not_user;

lea r11, [rip + user_ref_row_id];
mov r13, [r11];                           // r13 = user_row
```

What changes semantically, not just syntactically:

- The kind check and the row extraction become one call instead of a
  manual `cmp` against `0x190` followed by a manual mask-and-shift —
  `kind_user_ref_decode` owns the KIND_USER wire-layout knowledge that
  `ls` was previously duplicating inline.
- `USER_REF_WRONG_KIND` (`0xFFFFFFF3`) replaces `ls`'s own
  `OC_ERR_NOT_USER` sentinel as the kind-mismatch signal from the
  library's side; `ls` still maps that to its own `OC_ERR_NOT_USER`
  at its call site if its callers expect that specific code — the
  library does not dictate the caller's own error vocabulary.
- `USER_REF_BAD_ROW` (`0xFFFFFFF2`) is new: a failure mode the M1 shim
  could not express (the M1 code had no row-validity check beyond the
  kind compare). A migrating caller should decide whether to treat it
  the same as `OC_ERR_NOT_USER` or surface it distinctly; this is a
  design decision this document does not make for `ls`.
- The wire format and the numeric row-id result are unchanged across
  the swap, per `ls`'s own header comment — no downstream consumer of
  `owner_col_render_from_wire`'s output sees a behavioral difference.

---

## 5. See also

- `README.md` — full public API reference (all 20 entry points,
  return-code table, wire format).
- `design/architecture.md` — internal spec; §1 is the source for the
  exec-time flow in §2 above; §9 is `KindUserRef`'s consumer-flow
  rationale.
- `tests/README.md` + `tests/harness.pdx` — the two M4 witnesses this
  guide's code sequences are exercised by (`bash tools/run-tests.sh`).
- `CHANGELOG.md` — the frozen return-code vocabulary this guide's
  sentinel names (`USER_REF_WRONG_KIND`, `CAP_MANIFEST_EXTRA`, etc.)
  are drawn from.
