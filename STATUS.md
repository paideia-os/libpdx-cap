# libpdx-cap — status

**Wave:** R49 shared library
**Current milestone:** M2 (cap-narrowing helpers + cap-transfer client)
— CLOSED. Ready for M3 (KIND_USER_ref decode + signed-inode helpers).

## Milestone rollup

| ID              | Title                                                                          | State  |
|-----------------|--------------------------------------------------------------------------------|--------|
| M1-001 (#1)     | scaffold + module boundary (cap_pack, cap_unpack, cap_manifest_verify)         | LANDED |
| M1-002 (#2)     | caps.decl parser (per design/tooling/plan.md invariant I6)                     | LANDED |
| M2-001 (#3)     | cap_manifest_verify: OK | MISSING | EXTRA against callee caps.decl              | LANDED |
| M2-002 (#4)     | rights-narrowing at send site (widening → reject)                              | LANDED |
| M2-003 (#5)     | rights-check at receive site (extra cap → reject)                              | LANDED |

See `design/tooling/r49-r50-plan.md` §5.10 in paideia-os for the full
milestone breakdown (M1–M5) and cross-repo dependencies.

## M2 summary

- `src/kind_names.pdx` (NEW at M2-001) — `KindNames` module with a
  14-row mirror of paideia-os `cap/kind.pdx`, plus
  `kind_names_resolve(name_ptr) → ord` and a leaf `_cap_cstr_eq(a, b)`
  helper. See `design/architecture.md` §7 for the row table + miss
  policy.
- `src/cap.pdx`: filled `cap_manifest_verify` body (M2-001), added
  `cap_pack_narrowed` (M2-002) and `cap_unpack_checked` (M2-003).
  New return codes `CAP_RIGHTS_WIDENING = 0xFFFFFFF5` and
  `CAP_KIND_UNKNOWN = 0xFFFFFFF4`.
- `design/architecture.md`: §1 (public-surface expanded to five Cap
  entries; KindNames module named), §5 (return-code table updated
  with the two new codes), §7 (KindNames rationale), §8 (each M1
  exclusion now marked ✓ landed at the appropriate M2 milestone).

## Consumer wiring (after M2)

Every R49-wave tool now wires libpdx-cap into its exec path per
`design/architecture.md` §1: parse own caps.decl at `_start` →
`cap_unpack_checked` on each received cap → `cap_manifest_verify` once
after every cap has landed → `cap_pack_narrowed` at each `shell → child`
handoff to prevent widening. Rights-args-text refinement (subtree=…,
mode= etc.) lands at M3-001; M2's kind-ordinal-plus-widen-mask compare
is a strict lower bound on receive-side security.
