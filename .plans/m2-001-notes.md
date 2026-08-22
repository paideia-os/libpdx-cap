# libpdx-cap.M2-001 — implementation notes

**Issue:** #3
**Status:** LANDED

## What landed

- `src/kind_names.pdx` (NEW) — `KindNames` module:
  - 14 name-string literals in `.rodata` (see `design/architecture.md`
    §7 for the row table).
  - `_cap_cstr_eq(a, b) → rc` — leaf byte-by-byte C-string compare
    using the paideia-as `xor rax,rax; mov_b rax,[ptr]` #1248 pattern.
  - `kind_names_resolve(name_ptr) → ord` — linear scan of the 14 rows;
    hit paths return the KIND ordinal; miss returns
    `KIND_NAMES_UNKNOWN = 0xFFFFFFF4`.
  - One callee-save push (`r12`) at prologue → rsp % 16 == 0 at every
    nested `_cap_cstr_eq` call site.
- `src/cap.pdx`:
  - New constant `CAP_KIND_UNKNOWN = 0xFFFFFFF4` (same numeric value
    as `KindNames::KIND_NAMES_UNKNOWN` — two-module symmetry; see
    `design/architecture.md` §5).
  - Filled `cap_manifest_verify` body with the two-pass compare:
    - **Pass 1 (MISSING):** for each `CapsDecl::req_kind_names[i]`,
      resolve via `kind_names_resolve`; if `KIND_NAMES_UNKNOWN` →
      return `CAP_KIND_UNKNOWN`; else scan `received[]` for a matching
      kind lane (miss → `CAP_MANIFEST_MISSING`).
    - **Pass 2 (EXTRA):** for each `received[i]`, extract kind lane
      (qword0 shr 16, mask 0xFFFF), then scan
      `CapsDecl::req_kind_names[]` resolving each; miss → `CAP_MANIFEST_EXTRA`.
  - Five callee-save pushes (`r12/r13/r14/r15/rbx`) → rsp % 16 == 0
    at nested `kind_names_resolve` call sites.
  - `decl_ptr` is informational in M2 (drives compare off CapsDecl
    singleton). Signature preserved for M4's caller-owned variant.

## Design decisions

**Kind resolution via in-repo mirror.** The alternative — a caller-
supplied `(name, ord)` table — was rejected for M2 because every R49
tool imports libpdx-cap, so a caller-side table would multiply into
identical duplicates across 9 tool repos. Keeping the mirror here
gives ONE update site when paideia-os grows a new kind and ONE place a
reviewer checks. Multi-vendor extensibility comes via
`kind_names_register` at R51+ when a non-paideia-os tool ships.

**KIND_TTY not mirrored.** The plan doc §4.4 lead says softarch Round 2
confirms the ordinal from paideia-os HEAD; HEAD has no `KIND_TTY`
symbol. Rather than guess an ordinal, M2 leaves the row out — a tool
declaring `KIND_TTY` in caps.decl fails loudly with `CAP_KIND_UNKNOWN`.
When softarch Round 2 pins the ordinal, a one-line row lands here.

**Rights-args-text deferred.** M2-001 compares by KIND ORDINAL only.
The `(read, subtree=/home)` refinement in a caps.decl entry is stored
as an opaque pointer in `CapsDecl::req_args_texts[]` but is not read.
Rights narrowing at the SEND site (M2-002) enforces the coarse "no
widening" invariant; fine-grained subtree/mode compare lands at
M3-001 alongside `KIND_USER_ref` decode.

**Two-pass shape.** A single pass would need a per-name "was it
matched" bitmap; the two-pass form is memory-free and its O(n·m) cost
(n = req_count ≤ 16, m = received_count ≤ 16) is at most 256 name-
resolve calls per exec — well within the ~microsecond budget the
plan doc assumes for exec-time cap verification.

## paideia-as conformance checklist

- Module names PascalCase basename (`Cap`, `KindNames`): yes.
- No `test` mnemonic: verified — every zero check uses `cmp reg, 0`
  (kind_names_resolve: `cmp rax, 0` for _cap_cstr_eq result;
  cap_manifest_verify: no bare zero checks, only `cmp reg, reg` and
  `cmp reg, imm ≤ 0xFFFF`).
- `cmp reg, imm ≤ 0x7FFFFFFF`: yes — largest raw imm is 0xFFFF (kind
  mask); `CAP_KIND_UNKNOWN` comparison goes via `mov r11, 0xFFFFFFF4;
  cmp rax, r11`.
- Large-imm return codes: `mov rax, imm32` — same InitCap precedent.
- `r11` scratch: yes — every `lea r11, [rip + sym]` respects the
  reservation; no persistent r11 across a nested call.
- Byte reads: `xor rax, rax; mov_b rax, [ptr]` in `_cap_cstr_eq`.
- SysV push/pop parity: matched at every function; rsp % 16 == 0 at
  every nested-call site (kind_names_resolve: 1 push; cap_manifest_verify:
  5 pushes).

## What's next (M3 preview)

- M3-001: `KIND_USER_ref` decode — `ls --long` owner-column rendering.
- M3-002: signed-inode helpers — `cp`/`mv`/`rm` re-sign-under-invoker
  path.
