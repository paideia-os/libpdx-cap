# R90-XREPO.013.M1-002 — exec-time reconciliation client helper (#20)

Landed: 2026-09-13. Shipped in **v1.1.0**.

Note the milestone-ID collision: this repo already has an
`m1-002-notes.md` for libpdx-cap's *own* M1-002 (the `caps.decl`
parser, #2). This is a different wave's M1-002 — R90-XREPO.013, whose
plan lives in paideia-os `design/round-retrospectives/r90-xrepo-wave3-plan.md`
§5. Hence the fully-qualified filename.

## Deliverable

`src/cap_reconcile.pdx`, module `CapReconcile`, one entry point:

```
cap_reconcile_at_exec(child_pid, caps_decl_ptr, caps_decl_len) -> u64
    !{mem, sysreg} @{cap}
```

A client trampoline over SC+ syscall **118**
(`sys_exec_reconcile_caps`). Returns `0` on success or a negative errno
propagated verbatim.

## Naming deviation from the issue body

The issue names the file `src/exec_reconcile.pdx`. It landed as
`src/cap_reconcile.pdx` (module `CapReconcile`), matching the landing
instruction and — more importantly — this repo's invariant that every
public function is prefixed with its module's snake basename:
`caps_decl_*` in `caps_decl.pdx`, `kind_user_ref_*` in
`kind_user_ref.pdx`, `signed_inode_*` in `signed_inode.pdx`. With the
function named `cap_reconcile_at_exec` (which matches the kernel-side
entry it wraps, and is what the instruction specified),
`exec_reconcile.pdx` would have been the one file in `src/` whose
basename did not predict its symbols.

## What was verified against paideia-os HEAD, not assumed

| Piece | State | Evidence |
|---|---|---|
| Kernel body | **landed** | `src/kernel/core/cap/reconcile.pdx`, module `Reconcile` — R90-XREPO.013.M0-001 / paideia-os#2129, this issue's stated dependency |
| SC+ syscall ID | **allocated** | `src/user/syscall_shim.pdx`, `sys_exec_reconcile_caps` = 118 (shifted off the issue-requested 96, taken by `sys_sendto`) |
| Kernel dispatch arm | **absent** | `src/kernel/core/syscall/dispatch.pdx`: `cmp rdi, 115; ja dispatch_enosys`, chain ends at 115 |

The substrate is two-thirds built. Body and ID exist; only the arm
connecting them is missing, so sysno 118 falls to
`dispatch_enosys: mov rax, 0xFFFFFFFFFFFFFFDA; ret`.

This repo itself contained **no** reachable evidence of the syscall —
no syscall-number header, no vendored kernel ABI file, no doc
reference. (`tests/harness.pdx` open-codes `mov rax, 1` / `mov rax, 60`
with inline comments, which is the whole precedent available.)
`SC_EXEC_RECONCILE_CAPS = 118` is therefore defined locally, with the
`syscall_shim.pdx` quotation inline as its provenance record, and a
note to delete it in favour of a shared header should one ever land.

## Decisions worth re-reading before changing anything

1. **ENOSYS is `0xFFFFFFFFFFFFFFDA` (-38), not bare `38`.** The
   in-tree constant, matching `dispatch_enosys`, `NIC_ENOSYS`
   (`core/net/nic_dispatch.pdx`) and `UO_ENOSYS`
   (`tools/user/umount.pdxfs/src/unmount_op.pdx`). The contract is
   "propagate the errno directly", so the value a caller compares
   against must be what the kernel actually puts in `rax`.

2. **The stub is bit-identical to the wired trampoline at this HEAD.**
   Not a convenience — the point. A caller cannot distinguish them, so
   the -ENOSYS degrade branch every consumer must carry can be written
   and exercised for real today.

3. **The stub deliberately does not inspect its arguments.** Neither
   does the real trampoline: the kernel's bounds check fires before
   any argument reaches a body. Validating here would make the stub
   *less* faithful.

4. **Nothing allocated in the `0xFFFFFFxx` band.** The three
   `CAP_RECONCILE_*` constants are mirrors of kernel values. See
   `design/architecture.md` §5's new paragraph and §13.

5. **"WEAK stub" = real symbol, real linkage, placeholder body.**
   paideia-as exposes no `STB_WEAK` binding
   (`tools/user/libpdx-argv/src/version_backend.pdx`), and an UND
   reference to an unprovided symbol fails `ld --fatal-warnings`
   (`tools/user/cat/src/schema_wire.pdx`). Freezing the *shape* is the
   deliverable.

6. **The return-shape divergence is flagged, not averaged over.**
   `syscall_shim.pdx`'s summary line says the syscall returns
   "reconciled cap count or negative errno"; the kernel body it names
   returns `0` or a negative errno, no count. The body is
   authoritative. If a future wire-in really returns a count, this
   helper's success contract moves from `== 0` to `>= 0`.

## The hazard this landing exists to document

`tools/run-tests.sh` links every `src/*.pdx` and `tests/*.pdx` object
into a **hosted Linux ELF64** and runs it natively — which works
precisely because libpdx-cap's SC+ IDs coincide with Linux's.

**Linux x86-64 syscall 118 is `getresgid(gid_t *rgid, gid_t *egid,
gid_t *sgid)`** — three OUT pointers. Our shape is `(child_pid,
caps_decl_ptr, caps_decl_len)`. A real `syscall` under that harness
hands Linux a PID and a *length* where it expects writable pointers,
and Linux stores four bytes through each.

The placeholder emits no `syscall` instruction, so the hazard is
dormant *and* the library's documented "no entry point issues a
syscall" property is literally true of the shipped object code. It
becomes false at the body swap.

`tests/m1_002_reconcile_stub.pdx` is the tripwire: 3 stages asserting
-ENOSYS, wired into `tests/harness.pdx` as exit status 3, with
`run-tests.sh`'s exit-3 arm printing the hazard instead of a bare
failure. **Making it green by editing the expected value is the wrong
fix.**

## Fingerprint coverage — stated honestly

The issue's fingerprint asks the test to assert "a narrowed set is
reported and a missing expected cap raises." Neither is assertable
here and neither is claimed: both need the kernel to actually
reconcile, and there is no narrowed set and no `EACCES` while the
dispatch arm is missing. Faking them inside the witness would assert
only that a fake returns what the fake was written to return.

The three stages assert the published unwired contract across the
three argument shapes a caller can present — `(0,0,0)`,
`(pid, ptr, 21)`, `(pid, ptr, 0)`. Closing the other half is scoped to
the wire-in change, where it becomes both possible and safe.

## Architectural cost, recorded

This is the library's first impure module. Blast radius, in full:

- `src/cap_reconcile.pdx` — new, `!{mem, sysreg} @{cap}`.
- `tests/harness.pdx` `_start` — `@{fs, sched}` → `@{fs, sched, cap}`,
  because it calls the witness that calls the helper.

Everything else stays `!{mem} @{}`, and `caps.decl` stays
`requires: (none)` — correctly, for a reason that survives the body
swap: `@{cap}` is an effect class naming what the body touches, while
a `requires:` item names a KIND the library must itself *hold*. This
helper holds none; it asks the kernel to act on the caller's authority
over a child the caller forked. Both `caps.decl`'s header and
`design/architecture.md` §13.1 record this so a later reader does not
"fix" it.

## Follow-ups this landing does not close

- **Kernel dispatch arm for sysno 118** (paideia-os) — the actual
  blocker. Read `design/architecture.md` §13.4 first.
- **R90-XREPO.013.M2-001** — the `shell` wire-in that makes this
  helper's first real call site.
- **`manifest.pdxsig` regeneration** — stale as of 1.1.0; needs an
  assembler pass, which this landing was scoped not to run.
- **Rewriting the witness against the wired contract** — belongs in
  the same change as the dispatch arm.
