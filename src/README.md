# src modules

| File | Role |
|---|---|
| `pack.zig` | Base encoding table and rolling 2-bit window with invalid-base reset |
| `extract.zig` | Mask parsing, naive reference extraction, six-stage butterfly, scalar and 4-lane vector forms, BMI2 `PEXT` |
| `scan.zig` | Engine dispatch and the per-record scanner; four valid windows are compacted per vector step |
| `canon.zig` | Reverse complement, canonical key, and key decoding |
| `count.zig` | Sorted canonical key collector with run-length grouping |
| `fasta.zig` | FASTA parser with record boundaries, whitespace handling, and a base cap |
| `design.zig` | Deterministic hill-climb over masks against planted substitutions and indels |
| `report.zig` | JSON report card, verdict rules, and TSV count writer |
| `server.zig` | Server-rendered HTML form and result page, zero JavaScript |
| `main.zig` | `scan`, `design`, `seed`, `serve`, and `version` commands |

## Mask bit order

The mask string is written left to right over the span. The rightmost character is symbol 0, the
rightmost (most recent) base in the rolling window. Thus `1011` selects the first, second, and fourth
symbols counted from the right of the window: positions 0, 1, and 3 in 2-bit packed order. Selected
symbols are compacted in increasing symbol index, so the low two bits of the extracted value are the
rightmost selected base. `canon.zig` decodes in sequence order.

## Throughput path

`scan.Butterfly` pushes four bases, checks per-mask validity, compacts four windows in one
`@Vector(4, u64)` butterfly pass when all four windows are valid, and falls back to scalar extraction
across invalid windows. On x86-64 with the `bmi2` feature the scanner dispatches to one `PEXT` per
window. There is no runtime CPUID check; the binary must be built for a target that includes `bmi2` to
use `PEXT`.

## Evidence limits

- The kill gate is host-specific. Report cards always carry host, compiler, mode, and input size.
- The designer proxy is a simulation of planted substitutions and indels scored by exact spaced-key
  matches within a one-window neighborhood. It is not a published sensitivity guarantee.
- Counts cover `ACGT` only. A window is skipped when an invalid base sits at a position the mask
  selects; invalid bases at skipped positions do not affect the spaced k-mer.
