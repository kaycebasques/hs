"""Public Haskell rules for rules_haskell."""

load("//hs/private:cabal_library.bzl", _hs_cabal_library = "hs_cabal_library")
load("//hs/private:haddock.bzl", _hs_haddock = "hs_haddock")
load("//hs/private:repl.bzl", _hs_repl = "hs_repl")
load(
    "//hs/private:rules.bzl",
    _hs_binary = "hs_binary",
    _hs_library = "hs_library",
    _hs_test = "hs_test",
    _hs_toolchain_library = "hs_toolchain_library",
)

hs_library = _hs_library
hs_binary = _hs_binary
hs_test = _hs_test
hs_toolchain_library = _hs_toolchain_library
hs_cabal_library = _hs_cabal_library
hs_haddock = _hs_haddock
hs_repl = _hs_repl
