# tests/

Empty at M1 by design. The correctness matrix — 10^6-cap-shape
round-trip fuzz + caps.decl parse-error corpus + rights-narrowing
invariant (widening always rejected) + receive-side extra-cap
rejection + signed-inode re-sign correctness — lands with
`libpdx-cap.M4-001` and `libpdx-cap.M4-002` per
`design/tooling/r49-r50-plan.md` §5.10 in paideia-os.

The M1 first-runnable example described in `design/architecture.md` §1
is carried by the first consumer to wire libpdx-cap at exec (`shell`
or `pkg`), not by this test tree.
