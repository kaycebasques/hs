# `examples/repl`: interactive `ghci` (`hs_repl`), `runghc`, and C11 `terminfo`

Use this standalone Bazel 9 workspace to launch interactive `ghci` sessions, evaluate one-off expressions, and run standalone Haskell scripts with `runghc`. To explore other supported features, browse the [examples index](../README.md).

- **Workspace REPL (`hs_repl` via `//:calc_repl`):** Preload workspace modules into `*Module` bytecode scope (including `hidden_modules` and `compiled_deps`), run live `:reload` on workspace edits, debug with `:break`/`:continue`, call C/`CApiFFI` code (`HsLinkReplCbits`), run cross-library Template Haskell splices, access `data` [runfiles](https://bazel.build/extending/rules#runfiles), load `ghci_commands` and `.ghci` scripts, evaluate `-e` expressions, and use `-fexternal-interpreter` (`ghc-iserv-dyn`).
- **Standalone interpreter targets:** Run `@rules_haskell//tools/ghci` for ad-hoc `ghci` sessions and `@rules_haskell//tools/ghci:runghc` to execute standalone Haskell scripts.
- **Self-contained C11 `libtinfo`:** Use `@hs_boot//:terminfo` (`System.Console.Terminfo`) with built-in `xterm-256color`, `vt100`, and `dumb` capabilities and static `libtinfo.a` linking in executables.

## Run and test

From `examples/repl`, run the tests, start an interactive REPL, evaluate expressions, or run a script with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel run //:calc_repl
bazel run //:calc_repl -- -e 'calcTotal 5'
bazel run @rules_haskell//tools/ghci -- -e '2 ^ 64 :: Integer'
bazel run @rules_haskell//tools/ghci:runghc -- "$PWD/scripts/hello_script.hs" demo
```
