# results

Committed evidence for the host in the file. Each run names host, compiler, build mode, mask, and input
size; a different host must produce its own file rather than overwrite these.

| File | Content |
|---|---|
| `bench.jsonl` | `zig build bench -Doptimize=ReleaseFast -- 64` on the recorded host |
| `parity.txt` | `tools/parity/run.sh` count checksums against pinned fisk, including an `N` corpus |

Regenerate:

```sh
zig build bench -Doptimize=ReleaseFast -- 64 > results/bench.jsonl
zig build -Doptimize=ReleaseFast
tools/parity/run.sh > results/parity.txt
```

These are measurements, not guarantees. The kill gate is 500 MB/s/core on the recorded host.
