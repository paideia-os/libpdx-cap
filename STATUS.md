# libpdx-cap — status

**Wave:** R49 shared library
**Current milestone:** M2 (cap-narrowing helpers + cap-transfer client)
— IN PROGRESS.

## Milestone rollup

| ID              | Title                                                                          | State  |
|-----------------|--------------------------------------------------------------------------------|--------|
| M1-001 (#1)     | scaffold + module boundary (cap_pack, cap_unpack, cap_manifest_verify)         | LANDED |
| M1-002 (#2)     | caps.decl parser (per design/tooling/plan.md invariant I6)                     | LANDED |
| M2-001 (#3)     | cap_manifest_verify: OK | MISSING | EXTRA against callee caps.decl              | LANDED |
| M2-002 (#4)     | rights-narrowing at send site (widening → reject)                              | OPEN   |
| M2-003 (#5)     | rights-check at receive site (extra cap → reject)                              | OPEN   |

See `design/tooling/r49-r50-plan.md` §5.10 in paideia-os for the full
milestone breakdown (M1–M5) and cross-repo dependencies.
