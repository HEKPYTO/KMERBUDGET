# results

Committed evidence for the host in the file. Each run names host, compiler, build mode, mask, and input
size; a different host must produce its own file rather than overwrite these.

| File | Content |
|---|---|
| `bench.jsonl` | `zig build bench -Doptimize=ReleaseFast -- 64` on Apple M2 |
| `bench-x86_64.jsonl` | the same benchmark on the GitHub x86-64 runner (AMD EPYC 9V45) |
| `gate-x86_64.json` | 8 MiB scan verdict on the same x86-64 runner |
| `parity.txt` | `tools/parity/run.sh` count checksums against pinned fisk, including an `N` corpus |
| `parity-x86_64.txt` | the same parity run on the GitHub x86-64 runner |

Regenerate:

```sh
zig build bench -Doptimize=ReleaseFast -- 64 > results/bench.jsonl
zig build -Doptimize=ReleaseFast
tools/parity/run.sh > results/parity.txt
```

These are measurements, not guarantees. The kill gate is 500 MB/s/core on the recorded host.
