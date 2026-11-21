# punkroc's tests

The platform punk programs run on is `platforms/cli` (see its README). Build
its host, and the host of upstream's `test/fx/platform` that some examples
use, once (and after changing a host), from the repository root:

```
zig build roc
sh test/punk/setup.sh
```

## Golden tests

`golden.sh` runs every program in `examples/punk/` and compares its output
(stdout, exit code and any file it writes) with `golden/expected/`. Which
program runs with which input is in `golden/cases.txt`; a new example without
a case there makes the test fail.

```
zig build roc
sh test/punk/setup.sh
sh test/punk/golden.sh            # check
sh test/punk/golden.sh --update   # after an intended change in output
```

The `punkroc` workflow (`.github/workflows/punk.yml`) runs these, together
with `zig test src/punk/test.zig`, on every PR into `punkroc`. On the 1st and
15th of each month it also merges upstream Roc's `main` into a new branch,
runs the same tests, and opens a PR only when they pass (or an issue when
they do not).
