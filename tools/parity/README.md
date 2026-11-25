# Count parity against fisk

This directory holds the independent reference used for the byte-exact count checks. It is not part of
the shipped binary and no reference code is vendored.

`parity.cpp` includes the MIT-licensed fisk headers at commit
`b242e7b65d2f72af36e30037954f3724ff7a57f2`, extracts spaced k-mers with the checked ASCII path, applies
the same reverse-complement canonicalization as the product, and prints `kmer<TAB>count` in numeric key
order. The product prints the same schema and order, so `sha256sum` equality is the parity check.

Run from a build tree with `zig-out/bin/kmerbudget` present:

```sh
zig build -Doptimize=ReleaseFast
tools/parity/run.sh
```

`run.sh` downloads the pinned fisk tarball into `.cache/fisk` on first use, compiles the harness with the
host C++ compiler, and compares 1 MiB, 8 MiB, and 64 MiB seeded corpora. Set `FISK_REF` to reuse an
existing checkout with an `include/` directory.

The corpus generator is `kmerbudget seed`; it is deterministic for a fixed seed. The parity mask is
`1100110011001101`; fisk requires the first and last mask positions to be set.

Recorded results live in `results/parity.txt`. The harness is not run in CI because it needs a C++
toolchain and network access for the first download.
