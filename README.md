# libpdx-cap

paideia-os shared library: capability marshalling for tool invocations

## Status

M1 in progress. See `design/tooling/r49-r50-plan.md` §5.10 in the
[paideia-os](https://github.com/paideia-os/paideia-os) repo for the
milestone breakdown, KIND allocations, cross-repo dependencies, and
per-milestone issue set.

## Local layout

- `design/architecture.md` — internal spec (wire format, storage
  model, caps.decl parser, paideia-as conformance).
- `src/cap.pdx` — `Cap` module (`cap_pack`, `cap_unpack`,
  `cap_manifest_verify` skeleton).
- `src/caps_decl.pdx` — `CapsDecl` module (`caps_decl_parse` +
  singleton record).
- `caps.decl` — libpdx-cap requires no caps of its own.
- `tests/` — empty until `libpdx-cap.M4-001` lands the 10^6-cap-shape
  round-trip fuzz.
- `.plans/` — per-milestone implementation notes.

## License

MIT — see LICENSE.
