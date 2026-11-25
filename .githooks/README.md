# Git hooks

`pre-commit` runs `zig fmt --check` on the build files and `src/`. It contains no tests.

Enable it once per clone:

```sh
git config core.hooksPath .githooks
```
