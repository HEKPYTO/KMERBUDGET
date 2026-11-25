# KmerBudget

![license](https://img.shields.io/badge/license-Apache--2.0-blue)
![zig](https://img.shields.io/badge/zig-0.17.1-orange)


Measured spaced k-mer extraction for the machine you actually run. Input is a FASTA file and a spaced
mask. Output is a throughput measurement, canonical k-mer counts, and a reproduction command that names
host, compiler, build mode, input size, and the pinned reference.

**Status: v0.1.0.** Extractor, designer, CLI, and no-JS UI are implemented. Every throughput and parity
claim below is reproducible from committed artifacts.

Product direction follows:

> Lucas Czech, *Fast Iteration of Spaced k-mers*,
> arXiv:2603.25417v3, 26 March 2026.
> https://arxiv.org/abs/2603.25417

Independent work. Not affiliated with or endorsed by the author.

## Features

- BMI2 `PEXT` on x86-64 and a six-stage butterfly fallback elsewhere, including four-window vector
  compaction.
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
git clone https://github.com/HEKPYTO/KMERBUDGET.git kmerbudget && cd kmerbudget
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
throughput, and the exact command to reproduce it. The server binds `127.0.0.1` by default; `--host
0.0.0.0` exposes the unauthenticated page to the network.

## Measured results

Kill gate: extraction of at least 500 MB/s/core on each recorded host. Numbers come from
`zig build bench -Doptimize=ReleaseFast -- 64` (64 MiB, extraction path); the raw lines are committed in
[`results/bench.jsonl`](results/bench.jsonl) and [`results/bench-x86_64.jsonl`](results/bench-x86_64.jsonl).

| Host | Compiler | Engine | Span | Weight | ns/window | MB/s/core |
|---|---|---|---|---|---|---|
| Apple M2 | Zig 0.17.1 | butterfly | 16 | 8 | 1.424 | 702.0 |
| Apple M2 | Zig 0.17.1 | butterfly | 24 | 12 | 1.404 | 712.1 |
| Apple M2 | Zig 0.17.1 | butterfly | 32 | 16 | 1.419 | 704.7 |
| AMD EPYC 9V45 | Zig 0.17.1 | butterfly | 16 | 8 | 1.087 | 920.3 |
| AMD EPYC 9V45 | Zig 0.17.1 | PEXT | 16 | 8 | 0.909 | **1099.5** |
| AMD EPYC 9V45 | Zig 0.17.1 | PEXT | 24 | 12 | 0.912 | 1096.8 |
| AMD EPYC 9V45 | Zig 0.17.1 | PEXT | 32 | 16 | 0.910 | 1098.4 |

Count parity is byte-exact against pinned fisk `b242e7b65d2f72af36e30037954f3724ff7a57f2` on
1 MiB, 8 MiB, and 64 MiB seeded corpora, plus a 1 MiB corpus with `N` bases. Checksums are committed in
[`results/parity.txt`](results/parity.txt); the harness is in
[`tools/parity/README.md`](tools/parity/README.md).

Host-labelled gate verdicts are committed in [`results/gate-arm64.json`](results/gate-arm64.json)
(Apple M2, 566.5 MB/s/core) and [`results/gate-x86_64.json`](results/gate-x86_64.json) (AMD EPYC 9V45,
PEXT, 1109.5 MB/s/core). Both PASS the 500 MB/s/core threshold.

The paper reports 520-750 MB/s/core across Xeon, EPYC, Ryzen, and M1 for its own implementations.
Its 3.4-4.2x and 3.2-9.5x comparisons are qualified; this project makes no general speedup claim
against other tools.

## Trust and maintenance

- **Security response.** Report vulnerabilities privately through GitHub Security Advisories on this
  repository. Private reporting and vulnerability alerts are enabled. The server has no authentication;
  keep the default `127.0.0.1` bind unless the network is trusted.
- **Dependencies.** Dependabot checks GitHub Actions weekly. Zig is pinned to 0.17.1 and upgraded only
  with a full CI run and refreshed artifacts.
- **Regression monitoring.** Every push and pull request runs tests on Ubuntu and macOS, the x86-64
  benchmark gate, byte-exact parity, the no-JS UI check, and the container smoke test. Artifacts are kept
  30 days; committed results are the durable record.
- **Future work.** SIMD and multi-mask extraction, sensitivity on real mutations, and real-genome
  throughput are not claimed in v0.1.0. They belong in later releases after the matched-throughput
  baseline stays green.

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
