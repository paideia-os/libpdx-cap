# libpdx-cap — enhancement plan (v1.x)

**Repo:** github.com/paideia-os/libpdx-cap
**Assessed at:** `f234fde` (2026-08-25), tag `v1.0.0` = `27c29e2`
**Scope:** design + issue plan only. No code changed by this pass.

This document is the output of a combined osarch/softarch audit of
libpdx-cap against its own source, its release artifacts, and its one
verified consumer (`ls`). Every claim below cites a file and line in a
repo that was read at the stated commit. Where a claim comes from
another pass rather than from this one's own reading, it says so.

---

## 1. Current state

libpdx-cap is a pure-userspace, dependency-free library that bridges
the two representations of a capability descriptor: the `caps.decl`
text a tool ships at its repo root, and the 16-byte binary Cap record
the loader's InitCap sidecar and `sys_cap_transfer` both speak.

Shipped surface, counted from source
(`grep -c 'pub let [a-z_0-9]* : ('` over `src/*.pdx`): **20 public
entry points across five modules** — `Cap`, `CapsDecl`, `KindNames`,
`KindUserRef`, `SignedInode`. Every one is annotated `!{mem} @{}`, and
the library's own `caps.decl` reads `requires: (none)`; no entry point
issues a syscall. That property is the load-bearing one: it is what
lets every tool link libpdx-cap without widening its own authority.

Milestones M1–M5 are closed (issues #1–#10, all CLOSED; **zero open
issues** at the time of this pass). Release artifacts — `CHANGELOG.md`,
`doc/libpdx-cap.pdxdoc`, `manifest.pdxsig` — all exist.

**The code is real.** A grep for `TODO|FIXME|XXX|stub|unimplemented`
over `src/` and `tests/` returns no stub markers — only the words
"reserved" and "preserved" inside register-plan prose. There is no
vaporware here: `caps_decl_parse` is an 883-line hand-written state
machine, `cap_manifest_verify` is a real two-pass reconciliation, and
the two M4 witnesses are 977 lines of genuine assertion sequences.
The gaps found below are gaps of *verification and release hygiene*,
not of missing implementation.

---

## 2. Real API completeness, with `ls` as the reference integration

### 2.1 The one verified consumer

`ls` is the only tool repo whose libpdx-cap call site this pass read
directly (`/tmp/pdx-readme-ls` at its current HEAD, read-only):

- `manifest.pdxproj:66` — `- libpdx-cap @ ^1.0`, a real version-pinned
  dependency declaration.
- `src/owner_col.pdx:259` — `call cap_unpack;` inside
  `owner_col_render_from_wire`'s `block:`. A genuine call.
- `src/owner_col.pdx:262` and `:269` — `lea r11, [rip + unpacked_kind]`
  and `lea r11, [rip + unpacked_target_ptr]`, reading libpdx-cap's
  `.bss` singletons directly.

So the "ls genuinely links libpdx-cap" finding is **confirmed true**.

### 2.2 What that integration also reveals

`ls` uses the **M1 API only**. Its own source explains why
(`src/owner_col.pdx:38-52`): it was written as a deliberate shim
against `cap_unpack` + the singleton reads *because* `kind_user_ref_decode`
had not landed, and it documents that "the six-line decode block below
collapses to a one-line `call kind_user_ref_decode`" once M3 ships.

M3-001 shipped on 2026-08-22. `ls` has not migrated. Nothing in this
repo told it to: there is no migration note, no `doc/INTEGRATION.md`,
and no CHANGELOG "consumers on M1 should now do X" line. **That is
libpdx-cap's own gap, not ls's** — a library that lands a helper
designed for one named consumer owes that consumer a migration note.
Filed as ENH-007.

Note also what `ls` does *not* call: `cap_unpack_checked`,
`caps_decl_parse`, or `cap_manifest_verify`. The exec-time
reconciliation that `design/architecture.md` §1 describes as the flow
"every consumer wires at exec" is, at the time of this pass, wired by
**no tool at all** — including the one adopter. The library's central
value proposition has zero production call sites.

### 2.3 The structural adoption blocker: `.bss` singletons

`design/architecture.md` §3 is candid that all receive-side state lives
in module-owned `.bss` singletons, and that this assumes "one
`cap_unpack` at a time" and "one `caps_decl_parse` per process". It
names the consequence itself: multi-cap unpacking is needed "once the
shell fans out to N children in parallel", and defers it post-M4.

Post-M4 arrived; the library froze at 1.0 without it. The single
process that most needs libpdx-cap — `shell`, which forwards narrowed
caps to every child it execs — is precisely the process the singleton
model cannot serve without careful call-ordering discipline it has no
API to express. `cap_manifest_verify`'s `decl_ptr` parameter is the
vestige of the planned fix: it is accepted and never dereferenced
(`src/cap.pdx:500`, `:527` — "informational; reserved for the M4
caller-owned variant").

This is the honest answer to "why is adoption low": for `ls`'s
one-cap-at-a-time owner column the API fits perfectly, and `ls`
adopted it. For fan-out consumers the API has a real ergonomic gap
that 1.0 froze in place. Filed as ENH-008 (additive, non-breaking).

### 2.4 Release-artifact integrity defects

Three findings here, all verified by recomputation, and all material
to whether a downstream `pkg install` could ever trust this release.

**(a) The `v1.0.0` tag does not assemble.** Tag `v1.0.0` points at
`27c29e2`. Commit `da38a9e` — three commits *after* the tag — is titled
"Fix build: cap_pack missing semicolon before fall-through label" and
adds a single `;` to `src/cap.pdx:214`, without which paideia-as
desyncs brace matching (P0100 at 216:24, cascading to 682:1). A
consumer resolving `libpdx-cap @ ^1.0` from the tag gets a tree the
assembler rejects.

**(b) `manifest.pdxsig`'s hash tree is stale for two of twelve
artifacts.** Recomputed with `sha256sum` at `f234fde`:

| artifact | manifest sha / bytes | actual sha / bytes |
|---|---|---|
| `README.md` | `a8506268…` / 2237 | `fd95ce84…` / 14943 |
| `src/cap.pdx` | `2a34fdb5…` / 32885 | `56a251f6…` / 32886 |

The other ten match. The `README.md` drift is the techdoc rewrite
(`f234fde`); the `src/cap.pdx` drift is the build fix (`da38a9e`) — so
the manifest attests the *broken* cap.pdx. `@manifest-body-hash`
(`c222bca3…`) covers the artifact block and is therefore also stale.

**(c) `CHANGELOG.md`'s "frozen at 1.0" return-code table is wrong.**
The five `CAPS_DECL_*` codes are permuted against source. Authoritative
values, `src/caps_decl.pdx:56-71`:

| symbol | source | CHANGELOG.md:61-65 |
|---|---|---|
| `CAPS_DECL_REQ_OVERFLOW` | `FA` | `F7` |
| `CAPS_DECL_SCHEMA_OVERFLOW` | `F9` | `F6` |
| `CAPS_DECL_MALFORMED_HEADER` | `F8` | `FA` |
| `CAPS_DECL_MALFORMED_ITEM` | `F7` | `F9` |
| `CAPS_DECL_ITEM_OUT_OF_SECTION` | `F6` | `F8` |

A consumer that codes its error branches from the CHANGELOG — the
document that calls itself the frozen vocabulary — mis-classifies
*every* parser error. The same entry also says "five modules, 12 entry
points"; the real count is 20. `README.md` already flags the
permutation, but the CHANGELOG is the release-of-record and is a
manifest-hashed artifact, so the fix belongs there.

### 2.5 Correctness defects in the validators themselves

**Slot bound is a signed compare (fail-open).** `src/cap.pdx:191-192`:

```
cmp rsi, 256;                       // CAP_SLOT_MAX = 256
jge cap_pack_bad_slot;
```

`jge` is signed. For any `slot >= 2^63` the compare reads as negative,
the branch is not taken, and `cap_pack` proceeds to pack
`slot & 0xFFFF` into the wire record instead of returning
`CAP_BAD_SLOT`. `cap_pack_narrowed` repeats the idiom at `:271-272`.
The correct mnemonic for an unsigned bound is `jae`. In-process
callers make this low-severity today, but a bound check in a
capability validator that silently truncates rather than refusing is
the wrong default. ENH-004.

**`CAP_BAD_KIND` is declared and never returned.** `src/cap.pdx:87`
declares `0xFFFFFFFD`; the only other mention is a comment at `:324`.
`cap_pack` masks kind with `and rax, r10` (`r10 = 0xFFFF`), so
`kind = 0x10190` silently packs as `KIND_USER` (`0x190`).
`design/architecture.md` §8 promised the check "at M2-001"; it never
landed. Wiring it is non-breaking (it only converts a silently-wrong
result into a refusal) and uses a code already reserved in the frozen
band. ENH-009.

**`SIGNED_INODE_SIG_ABSENT` is unreachable.** `src/signed_inode.pdx:99`
declares it as `0xFFFFFFF1`, but `signed_inode_has_signature`'s absent
path is `xor rax, rax` (`:265`) — it returns literal `0`, with a
comment that calls `0` "SIGNED_INODE_SIG_ABSENT numeric". A consumer
writing `cmp rax, SIGNED_INODE_SIG_ABSENT` never matches. One of the
two must give. ENH-003.

### 2.6 Test credibility

`tests/` ships two substantial witnesses. Neither has ever been run.

`design/architecture.md:610-612` and `tests/README.md` both state it
plainly: "libpdx-cap has no test harness of its own — the wave-level
harness is delivered by the first R49-wave tool that links
libpdx-cap." `ls` linked libpdx-cap and did not deliver that harness.
`tools/build.sh` only *assembles* `src/*.pdx` and `tests/*.pdx` to
`.o` files; nothing links a runnable image, and nothing checks a
return value. So the M4 gate was closed, as `tests/README.md` admits,
"by the existence + shape of these two witnesses" — by inspection.

The 10^6-iteration fuzz claim in the CHANGELOG has, to date, executed
zero iterations. This is the single largest credibility gap in the
repo, and — unlike the adoption gap — it is entirely libpdx-cap's own
to close. ENH-006.

Coverage has a concrete hole too: `tests/m4_001_roundtrip_fuzz.pdx:195`
derives the slot as `and rsi, 0xFF`, so the fuzz never produces a slot
`cap_pack` would reject. Cross-referencing the 22 stages documented in
`tests/README.md`, no stage exercises `CAP_BAD_SLOT` either. **The
only failure mode `cap_pack` has is untested** — which is exactly why
§2.5's signed-compare bug survived to 1.0. ENH-005.

---

## 3. Org-wide under-adoption assessment

Of nine tool repos, the README pass confirmed exactly one — `ls` —
genuinely links libpdx-cap. This pass re-verified `ls` (§2.1) and did
not independently re-verify the other eight; the survey in
`README.md`'s "Callers" section (`shell`, `cp`, `doc`, `pkg`) is that
pass's reading, reproduced here as attribution, not as this pass's own
finding.

**The verdict: mostly an adoption gap, with one genuine API cause.**
The API is not hard to call — `ls` wired it in six lines against the
M1 surface. The library's own defects (§2.4–2.6) are release-hygiene
and verification failures, none of which would have deterred an
integrator, because none of them are visible without recomputing
hashes. What *is* a genuine library-side cause is §2.3: the singleton
storage model does not serve fan-out consumers, and `shell` is the
most important non-adopter.

Tools that plausibly should adopt libpdx-cap, and why. **Each of these
fixes is scoped in that tool's own repo, and this pass files nothing
against them.** They are listed for the coordinating pass's awareness:

| tool | why it should adopt | strength |
|---|---|---|
| `shell` | It forwards caps to every child it execs. Rights-narrowing at the send site is the I6 invariant, and `cap_pack_narrowed` is the primitive for it. Per the README caller survey it reimplements `(child & ~parent) == 0` inline — a second copy of a security check that should have exactly one implementation. Blocked in part by §2.3. | strongest case |
| `rm`, `mv` | Destructive operations on paths that may be cap-gated; both are named in `design/architecture.md` §10 as `SignedInode` consumers for the preserve-or-degrade path. Exec-time `cap_manifest_verify` matters most where the failure mode is data loss. | strong |
| `cp` | Already declares the dependency and ships a stub `src/signed_inode.pdx` that unconditionally degrades (per the README caller survey). The helpers it is waiting on shipped at M3-002. | strong, nearly free |
| `cat` | Reads files that may be cap-gated; declares `KIND_TTY`. Exec-time reconciliation is the generic case. | moderate |
| `mkdir` | Creates inodes under paths that may be cap-gated; weakest of the coreutils case but still on the exec path. | moderate |
| `doc`, `pkg` | Both name libpdx-cap in comments as the narrowing path for `KIND_PDXFS_FILE` reads once R42 lands (per the README caller survey). Genuinely blocked on substrate, not on this library. | deferred, correctly |

The pattern worth flagging upward: **exec-time reconciliation
(`caps_decl_parse` → `cap_unpack_checked` → `cap_manifest_verify`) is
wired by zero tools**, including `ls`. `design/architecture.md` §1
presents it as the flow every consumer runs. It is, today, aspirational
prose. Closing that is nine small issues across nine repos, not one
issue here — but a paideia-os monorepo tracking issue would be the
right home for the campaign. This pass does not file it.

---

## 4. Issue plan

Nine issues would be over-filing; the list below is eight, each
traceable to a cited defect above. Ordering matters: the two
documentation corrections and the code fixes must land *before* the
manifest re-hash, or the manifest goes stale again on the next commit.

Filed into milestone **Enhancement v1.x — libpdx-cap** (#6):

| ID | Issue | Title | Effort | Deps |
|---|---|---|---|---|
| ENH-002 | [#11](https://github.com/paideia-os/libpdx-cap/issues/11) | Correct `CHANGELOG.md` 1.0 return-code table (5 permuted `CAPS_DECL_*`) + entry-point count | XS | none |
| ENH-003 | [#12](https://github.com/paideia-os/libpdx-cap/issues/12) | Resolve `SIGNED_INODE_SIG_ABSENT`: declared `0xFFFFFFF1`, returned as `0` | XS | none |
| ENH-004 | [#13](https://github.com/paideia-os/libpdx-cap/issues/13) | `cap_pack` slot bound uses signed `jge` — fail-open above `2^63` | S | none |
| ENH-005 | [#14](https://github.com/paideia-os/libpdx-cap/issues/14) | Add `CAP_BAD_SLOT` coverage — `cap_pack`'s only failure mode is untested | S | #13 |
| ENH-006 | [#15](https://github.com/paideia-os/libpdx-cap/issues/15) | Ship a runnable test harness — the M4 witnesses have never been executed | M | none |
| ENH-007 | [#16](https://github.com/paideia-os/libpdx-cap/issues/16) | `doc/INTEGRATION.md`: worked exec-time example + M1→M3 migration note | M | none |
| ENH-009 | [#17](https://github.com/paideia-os/libpdx-cap/issues/17) | Wire `CAP_BAD_KIND` — `cap_pack` silently truncates kind to 16 bits | S | #13 |
| ENH-008 | [#18](https://github.com/paideia-os/libpdx-cap/issues/18) | Additive caller-owned (re-entrant) variants for fan-out consumers | L | #15 |
| ENH-001 | [#19](https://github.com/paideia-os/libpdx-cap/issues/19) | Cut v1.0.1 — tagged tree does not assemble; refresh `manifest.pdxsig` | S | #11–#15, #17 |

A reasonable first cut is #11, #12 and #15 — the two one-line document
and constant corrections, plus the harness that makes every later
change verifiable. #18 is the only item that should wait for a consumer
to actually need it; `shell` is that consumer, and the context layout
should be settled against its real fan-out path rather than in the
abstract.

Adding this file does not disturb `manifest.pdxsig`: `design/` is not
in the artifact block.

---

## 5. Is the `v1.0.0` tag defensible?

**No — the tag is not defensible, though the library behind it very
nearly is.**

The distinction matters. The *code* is 1.0-quality: five coherent
modules, a frozen and internally consistent return-code band, real
fail-fast discipline, register plans and paideia-as conformance
argued line by line, and design documentation of unusually high
standard that is honest about its own exclusions. Nothing in §2 is a
design failure.

The *release* is not. A tag whose tree does not assemble
(§2.4a) is not a release; it is a snapshot taken one commit too early.
A manifest that attests hashes for two files it no longer describes
(§2.4b) provides negative assurance — a verifier that ran would fail,
and none ran. A frozen return-code table that permutes five of its
sixteen codes (§2.4c) is worse than no table. And a test suite that has
never executed (§2.6) cannot support the "10^6 iterations" claim the
CHANGELOG makes on its behalf.

Each of these is individually small; ENH-001 through ENH-006 close all
of them, and none requires design rework. The recommendation is to cut
**v1.0.1** promptly, from a tree that has actually been assembled and
whose witnesses have actually returned `0`, and to treat `v1.0.0` as
withdrawn. Consumers pinning `^1.0` pick up the fix automatically.
