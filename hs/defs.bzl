"""Public Haskell rules for rules_hs."""

load("//hs/private:cabal_library.bzl", _hs_cabal_library = "hs_cabal_library")
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
