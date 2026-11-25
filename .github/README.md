# CI and dependency automation

`workflows/ci.yml` runs on every push and pull request:

1. `zig build test` on Ubuntu and macOS.
2. `zig build fmt` (includes `build.zig.zon`).
3. `zig build bench -- 1` as a fast smoke of the benchmark executable.

`dependabot.yml` updates GitHub Actions weekly. No other automation is enabled; publication and tags are
owner-gated and never triggered by CI.
