# kmerbudget

![license](https://img.shields.io/badge/license-Apache--2.0-blue)
![zig](https://img.shields.io/badge/zig-0.17.1-orange)
![js](https://img.shields.io/badge/runtime%20JS-none-success)

Measured spaced-k-mer extraction for the machine you actually run. Input is a FASTA file and a spaced
mask. Output is a throughput measurement, canonical k-mer counts, and a reproduction command that names
host, compiler, build mode, input size, and the pinned reference.

The extraction core follows the bit-parallel algorithm from *Fast Iteration of Spaced k-mers*
(arXiv:2603.25417v3, MIT implementation at `lczech/fisk`). It packs bases two bits per symbol, rolls a
span-sized window, and compacts selected positions with BMI2 `PEXT` on supporting x86-64 hosts or a
six-stage butterfly network that also vectorizes four windows at a time. The UI is server-rendered HTML
with no JavaScript assets.

## Features

- Span up to 32, any nonzero mask weight, mask bit order documented by tests.
- Invalid bases only invalidate a window when the mask selects that position, matching the reference
  implementation; skipped positions never corrupt or drop a spaced k-mer.
- Reverse-complement canonical counts with deterministic key order.
- `PASS`, `FAIL`, or `INCONCLUSIVE` throughput verdict against a budget; `INCONCLUSIVE` is used below
  8 MiB of input instead of hiding unstable rates.
- Mask designer: deterministic hill-climb over planted substitutions and single-base indels. The score
  is a detection proxy, not a sensitivity guarantee.
- Zero JavaScript, no external assets, no retained input.

## Prerequisites

- Zig 0.17.1
- A 64-bit CPU. x86-64 with BMI2 uses hardware `PEXT`; AArch64 and other hosts use the butterfly path.

## Install

```sh
git clone <repo> kmerbudget && cd kmerbudget
zig build -Doptimize=ReleaseFast -Dcommit=$(git rev-parse --short HEAD)
install -m755 zig-out/bin/kmerbudget ~/.local/bin/kmerbudget
```

Container image (static binary, no runtime dependencies):

```sh
docker build -t kmerbudget .
docker run --rm -p 8080:8080 kmerbudget
```

The container entrypoint serves on `0.0.0.0:8080`; publish the port only on a trusted network because
the server has no authentication.

## Quick start

```sh
zig build -Doptimize=ReleaseFast
printf '>demo\nACGTACGTACGTACGTACGTACGTACGTACGT\n' > demo.fa
./zig-out/bin/kmerbudget scan demo.fa --mask 1100110011001100 --out counts.tsv --budget 500
./zig-out/bin/kmerbudget design demo.fa -k 16 -w 8 --error 0.02 --budget 500
./zig-out/bin/kmerbudget serve --port 8080
```

The scan command prints one JSON line. The design command prints the chosen mask, proxy, measured
throughput, and the exact command to reproduce it. The server listens on `127.0.0.1` only.

## Measured results

Kill gate: extraction of at least 500 MB of input per second per core on the test host.
Numbers come from `zig build bench -Doptimize=ReleaseFast -- 64` (64 MiB, extraction path); the raw
lines are committed in [`results/bench.jsonl`](results/bench.jsonl).

| Host | Compiler | Mode | Span | Weight | ns/window | MB/s/core |
|---|---|---|---|---|---|---|
| Apple M2 | Zig 0.17.1 | fast | 16 | 8 | 1.424 | 702.0 |
| Apple M2 | Zig 0.17.1 | fast | 24 | 12 | 1.404 | 712.1 |
| Apple M2 | Zig 0.17.1 | fast | 32 | 16 | 1.419 | **704.7** |

Count parity is byte-exact against pinned fisk `b242e7b65d2f72af36e30037954f3724ff7a57f2` on
1 MiB, 8 MiB, and 64 MiB seeded corpora, plus a 1 MiB corpus with `N` bases. Checksums are committed in
[`results/parity.txt`](results/parity.txt); the harness is in
[`tools/parity/README.md`](tools/parity/README.md).

The paper reports 520-750 MB/s/core across Xeon, EPYC, Ryzen, and M1 for its own implementations.
Its 3.4-4.2x and 3.2-9.5x comparisons are qualified; this project makes no general speedup claim
against other tools.

## Development

```sh
zig build test
zig build fmt
zig build bench -- 64
zig build
```

`zig build bench` prints extraction-only throughput for comparison; `scan` prints the product path
including rolling window and sink. Pass `-Dcommit=$(git rev-parse --short HEAD)` to stamp the source
revision into reports.

## Documentation

- [`src/README.md`](src/README.md): module map, mask bit order, throughput path, evidence limits.
- [`spec/README.md`](spec/README.md): pinned reference and corpus parameters.
- [`tools/parity/README.md`](tools/parity/README.md): independent count parity against fisk.
- [`results/README.md`](results/README.md): committed benchmark and parity evidence.

## License

Apache License 2.0. The referenced paper and its MIT implementation are attributed in `src/reference.zig`.
