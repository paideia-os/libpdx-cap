# libpdx-cap.M5-001 — implementation notes

**Issue:** #10
**Status:** LANDED (1.0.0)

## What landed

- `CHANGELOG.md` (NEW) — Keep-a-Changelog + M-milestone-prefix
  format. The 1.0.0 entry summarises M1..M5 (issues + landing
  commits), publishes the frozen return-code table (16
  codes across five modules), publishes the M4 witness
  fingerprint contract, and documents the dual-signature and
  mirror-push status.
- `doc/libpdx-cap.pdxdoc` (NEW) — long-form documentation for
  `doc libpdx-cap`. Uses `.pdxdoc` v0.1 (an @-directive-driven
  text format with `## SECTION` headers and `[[TARGET]]`
  cross-refs). doc.M1-002 will land the formal grammar; the
  directive set here is a superset chosen to survive without
  loss when the parser arrives (unrecognised directives are
  informational for human readers).
- `manifest.pdxsig` (NEW) — v0.1 dual-signed release manifest
  per `design/tooling/plan.md` §6.3. Carries the SHA-256 hash
  tree over the 12 shipped artifacts (caps.decl, LICENSE,
  README.md, CHANGELOG.md, doc/libpdx-cap.pdxdoc, five src
  modules, both M4 witness modules), the `@manifest-body-hash`
  over the entire artifact block, and two RESERVED 3309-byte
  ML-DSA-65 signature slots (author + paideia_root).
- `README.md` — updated status line to "1.0.0 released" and
  added `CHANGELOG.md`, `doc/libpdx-cap.pdxdoc`, and
  `manifest.pdxsig` to the local-layout listing.
- `STATUS.md` — M5-001 marked LANDED; milestone rollup extended.

## Design decisions

### Why ship a release manifest with unsigned sig slots

The plan doc §5.10 M5 rubric calls for a "dual-signed
`manifest.pdxsig`". Two constraints prevent 1.0.0 from
producing real signatures:

1. **No userspace sign primitive.** The M3-002 notes
   explicitly flag that the ML-DSA-65 sign call is a
   paideia-as v0.33-crypto intrinsic whose userspace linkage
   is a paideia-as-team deliverable. VERIFY is exposed;
   SIGN is not.

2. **No signing bot + mirror.** paideia-os `T-INFRA-001`
   (`pkgs.paideia-os`) and `T-INFRA-002` (signing bot host +
   root-key policy) are un-scheduled infrastructure issues.
   The bot is the load-bearing part of the dual-signature
   trust model per §9.3 step 4: the author tags + signs, the
   bot re-signs with the root key.

Two shapes were considered:

- **Shape A (defer M5).** Wait for the intrinsic + the bot,
  release 1.0.0 signed. Cost: every downstream tool that
  wants `libpdx-cap ≥ 1.0` at deps.list resolution blocks on
  paideia-as-team + infra work outside R49's scope.

- **Shape B (chosen).** Ship 1.0.0 with an unsigned but
  hash-tree-stable manifest; document the signature-slot shape
  and the byte-count-preserving overwrite the bot will
  perform later. Downstream tools can pin `libpdx-cap 1.0.0`
  by hash tree; the trust upgrade lands transparently when
  the bot re-signs.

Shape B preserves M5's atomic-milestone contract (the tag
lands, the CHANGELOG lands, the mirror slot exists) while
being honest about the two open dependencies. The manifest's
top-of-file comment names the exact bytes the bot will
overwrite and the exact input (`@manifest-body-hash`) it will
sign over — no ambiguity when the bot arrives.

### Byte-count-preserving sig slots

The two `@-sig-slot-*` blocks reserve exactly the shape
ML-DSA-65 will produce: a 3309-byte body base64-encoded (so
distributed as ~4412 base64 chars once expanded, plus the
per-line 80-char folding the current placeholder shape uses).
The signing bot overwrites bytes in place; the file's SHA-256
naturally changes on re-sign but its length does not, so:

- The URL `pkgs.paideia-os/main/libpdx-cap/1.0.0/manifest.pdxsig`
  serves one canonical file at any point in time.
- The `@manifest-body-hash` is stable across re-sign — it hashes
  the artifact block, not the sig slots, so downstream
  verifiers can re-derive it and compare against
  `sha256(concat(shipped artifacts))`.

### `@manifest-body-hash` boundaries

The hash covers from `@manifest libpdx-cap 1.0.0` (inclusive)
through the terminating `\n` of the `@end-artifacts` line. That
means:

- **Included:** all `@-metadata` directives, `@milestones-closed`
  block, `@artifacts`..`@end-artifacts` block.
- **Excluded:** the # comment preamble at the top (human-oriented,
  edited freely), the `@manifest-body-hash` line itself (would
  cause a cycle), the two `@-sig-slot-*` blocks (overwritten by
  the bot; excluding them keeps the body-hash stable across
  re-sign), and the trailing `# End of manifest.pdxsig` comment.

The hash was computed as:

    sed -n '39,/^@end-artifacts$/p' manifest.pdxsig | sha256sum
    → c222bca34f44e39b9ed4902e18fcc22683c4c9ae2fc68a6a30e6ca1f23f435c0

Line 39 is the first line beginning with `@manifest `; the
awk-style range terminator matches the literal `@end-artifacts`
line. This exact command is reproducible on any Linux host with
GNU coreutils, so downstream verifiers can re-derive the value
without a specialised tool. Once `pkg verify` lands the same
byte range will be extracted programmatically.

### `.pdxdoc` v0.1 format decision

The `.pdxdoc` format is defined by `doc.M1-002` (not yet
landed). This file is written to a shape that:

- **Survives an @-directive parser** — every metadata field is a
  `@key value` line, so a strict directive parser can extract
  metadata without prose-mode.
- **Survives a header-scanning parser** — `## SECTION` headers
  are the same shape as Markdown H2, so a lax scanner emits a
  reasonable outline.
- **Survives a POSIX-difference-aware parser** — `!! POSIX:`
  lines follow the exact prefix the plan doc §I7 describes for
  historical-context annotations.

When doc.M1-002 lands with a grammar, we re-visit this file
against the formal spec; no libpdx-cap change is expected
unless the grammar rejects one of the three shapes above.

### Artifact set (what ships in the pkg tarball)

Per plan.md §6.4 a library package ships `caps.decl` +
`doc/*.pdxdoc` + `manifest.pdxsig` plus its content. For a
source-shipped library like libpdx-cap the "content" is the
five `src/*.pdx` modules a consumer's paideia-as build will
import. LICENSE + README.md + CHANGELOG.md ship as human-facing
metadata; the two `tests/*.pdx` witness modules ship because
they are consumer-callable per the M4 contract (see
`.plans/m4-002-notes.md` "Consumer contract"). What DOES NOT
ship in the manifest: `STATUS.md` (session-only tracker),
`.plans/` (implementation notes), `design/architecture.md`
(internal spec; the plan doc is authoritative for
consumers), and `manifest.pdxsig` itself (would recurse).

### Mirror push — deferred, not skipped

`git push --tags` to `github.com/paideia-os/libpdx-cap` is the
authoritative distribution channel at 1.0.0. The mirror push to
`pkgs.paideia-os/main/libpdx-cap/1.0.0/` is a follow-up gated
on `T-INFRA-001` (repository infrastructure) coming online. The
`@mirror-target` directive in `manifest.pdxsig` names the exact
path a future automation will publish to; no libpdx-cap change
is needed at that point.

## paideia-as conformance

M5-001 touches no `.pdx` files. The `.pdxdoc`, CHANGELOG, and
manifest are all `#`- or `//`-comment-friendly text; none is
processed by paideia-as. The paideia-as compliance checklist
therefore does not apply here.

## Verification

Reproducible by:

    cd libpdx-cap
    for f in caps.decl LICENSE README.md CHANGELOG.md \
             doc/libpdx-cap.pdxdoc src/cap.pdx src/caps_decl.pdx \
             src/kind_names.pdx src/kind_user_ref.pdx \
             src/signed_inode.pdx tests/m4_001_roundtrip_fuzz.pdx \
             tests/m4_002_caps_decl_matrix.pdx; do
        sha256sum "$f"
    done
    # Should match the @artifacts block in manifest.pdxsig.

    sed -n '39,/^@end-artifacts$/p' manifest.pdxsig | sha256sum
    # Should equal @manifest-body-hash in the file.

## What's next

- No further libpdx-cap milestones planned. Post-1.0 changes
  land as `1.0.x` (bugfix) or `1.1.0` (feature) per semver;
  each release publishes a new `manifest.pdxsig` under the
  same trust model.
- When the ML-DSA-65 sign intrinsic ships (paideia-as
  v0.33-crypto SIGN linkage), the signing bot re-signs
  1.0.0's `manifest.pdxsig` in place; no libpdx-cap change.
- When `pkgs.paideia-os` (T-INFRA-001) comes online, a mirror
  push publishes to `pkgs.paideia-os/main/libpdx-cap/1.0.0/`;
  no libpdx-cap change.
- Downstream consumers unblock: `pkg`, `shell`, `doc`, and
  transitively every R50 coreutil can now pin
  `libpdx-cap = 1.0.0` in their `deps.list`.
