"""Public Haskell rules for rules_haskell."""

load(
    "//haskell/private:cabal_codegen.bzl",
    _hs_alex_gen = "hs_alex_gen",
    _hs_happy_gen = "hs_happy_gen",
)
load("//haskell/private:cabal_library.bzl", _hs_cabal_library = "hs_cabal_library")
load("//haskell/private:haddock.bzl", _hs_haddock = "hs_haddock")
load("//haskell/private:repl.bzl", _hs_repl = "hs_repl")
load(
    "//haskell/private:rules.bzl",
    _hs_binary = "hs_binary",
    _hs_library = "hs_library",
    _hs_test = "hs_test",
    _hs_toolchain_library = "hs_toolchain_library",
)

def hs_cabal_library(extra_cc_deps = [], **kwargs):
    """Builds a Cabal/Hackage Haskell (or C-only) library with fine-grained Bazel actions."""
    if type(extra_cc_deps) == "list":
        extra_cc_deps = [
            Label(d) if type(d) == "string" and d.startswith("@@") else d
            for d in extra_cc_deps
        ]
    _hs_cabal_library(
        extra_cc_deps = extra_cc_deps,
        **kwargs
    )

hs_library = _hs_library
hs_binary = _hs_binary
hs_test = _hs_test
hs_toolchain_library = _hs_toolchain_library
hs_haddock = _hs_haddock
hs_repl = _hs_repl
hs_alex_gen = _hs_alex_gen
hs_happy_gen = _hs_happy_gen
