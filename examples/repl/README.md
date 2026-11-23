# `examples/repl` — Interactive `ghci` (`hs_repl`), `runghc`, and C11 `terminfo`

Minimal standalone Bazel 9 workspace demonstrating:

- `hs_repl` (`//:calc_repl`) preloading workspace modules into `*Module` bytecode scope (including `hidden_modules` and `compiled_deps`), live `:reload` on workspace edits, `:break`/`:continue` bytecode debugging, C/`CApiFFI` (`HsLinkReplCbits`), cross-library Template Haskell splices, `data` runfiles, `ghci_commands` & `.ghci` scripts, `-e` expression evaluation, and `-fexternal-interpreter` (`ghc-iserv-dyn`).
- Standalone `@rules_hs//tools/ghci` and `@rules_hs//tools/ghci:runghc` targets.
- Self-contained C11 `libtinfo` (`@hs_boot//:terminfo` `System.Console.Terminfo` with built-in `xterm-256color`, `vt100`, and `dumb` capabilities and static `libtinfo.a` linking in executables).

## Run & Test

```bash
bazel test //...
bazel run //:calc_repl
bazel run //:calc_repl -- -e 'calcTotal 5'
bazel run @rules_hs//tools/ghci -- -e '2 ^ 64 :: Integer'
bazel run @rules_hs//tools/ghci:runghc -- "$PWD/scripts/hello_script.hs" demo
```
