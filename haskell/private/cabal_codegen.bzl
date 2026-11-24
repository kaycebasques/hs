"""Hermetic source-bootstrapped Alex (.x) and Happy (.y/.ly) codegen for Cabal packages.

Both Alex and Happy ship pre-bootstrapped Haskell parser/scanner sources in their
official Hackage release tarballs and depend strictly on GHC boot libraries
(@hs_boot), so rules_haskell builds them lazily from source with zero host tools and
zero extra non-dev Bzlmod dependencies.
"""

def _hs_alex_gen_impl(ctx):
    out_hs = ctx.actions.declare_file(ctx.attr.out)
    data_files = ctx.files.alex_data
    if not data_files:
        fail("hs_alex_gen requires alex_data template files")
    template_dir = data_files[0].dirname

    args = ctx.actions.args()
    args.add("--template=" + template_dir)
    args.add("-g")
    args.add("-o", out_hs.path)
    args.add(ctx.file.src.path)

    ctx.actions.run(
        mnemonic = "HsAlex",
        progress_message = "Running hermetic alex on {}".format(ctx.file.src.short_path),
        executable = ctx.executable.alex,
        arguments = [args],
        inputs = depset([ctx.file.src] + data_files),
        outputs = [out_hs],
        env = {"alex_datadir": template_dir},
    )
    return [DefaultInfo(files = depset([out_hs]))]

hs_alex_gen = rule(
    implementation = _hs_alex_gen_impl,
    attrs = {
        "src": attr.label(mandatory = True, allow_single_file = [".x"]),
        "out": attr.string(mandatory = True),
        "alex": attr.label(mandatory = True, executable = True, cfg = "exec"),
        "alex_data": attr.label_list(mandatory = True, allow_files = True),
    },
    doc = "Generates a Haskell lexer module (.hs) from an Alex grammar (.x).",
)

def _hs_happy_gen_impl(ctx):
    out_hs = ctx.actions.declare_file(ctx.attr.out)
    data_files = ctx.files.happy_data
    if not data_files:
        fail("hs_happy_gen requires happy_data template files")
    template_dir = data_files[0].dirname

    args = ctx.actions.args()
    args.add("-t", template_dir)
    args.add("-o", out_hs.path)
    args.add(ctx.file.src.path)

    ctx.actions.run(
        mnemonic = "HsHappy",
        progress_message = "Running hermetic happy on {}".format(ctx.file.src.short_path),
        executable = ctx.executable.happy,
        arguments = [args],
        inputs = depset([ctx.file.src] + data_files),
        outputs = [out_hs],
        env = {"happy_datadir": template_dir},
    )
    return [DefaultInfo(files = depset([out_hs]))]

hs_happy_gen = rule(
    implementation = _hs_happy_gen_impl,
    attrs = {
        "src": attr.label(mandatory = True, allow_single_file = [".y", ".ly"]),
        "out": attr.string(mandatory = True),
        "happy": attr.label(mandatory = True, executable = True, cfg = "exec"),
        "happy_data": attr.label_list(mandatory = True, allow_files = True),
    },
    doc = "Generates a Haskell parser module (.hs) from a Happy grammar (.y / .ly).",
)

def _alex_bootstrap_repo_impl(repository_ctx):
    repository_ctx.download_and_extract(
        url = "https://hackage.haskell.org/package/alex-3.5.4.2/alex-3.5.4.2.tar.gz",
        sha256 = "df481dc960e2c59a30395f7335031fd4ef8773b8a42894a4f2320e00ff474418",
        stripPrefix = "alex-3.5.4.2",
    )
    repository_ctx.file(
        "autogen/Paths_alex.hs",
        """\
module Paths_alex (version, getDataDir) where
import Data.Maybe (fromMaybe)
import Data.Version (Version(..))
import System.Environment (lookupEnv)

version :: Version
version = Version [3, 5, 4, 2] []

getDataDir :: IO FilePath
getDataDir = fmap (fromMaybe "data") (lookupEnv "alex_datadir")
""",
    )
    repository_ctx.file(
        "BUILD.bazel",
        """\
load("@rules_haskell//haskell:defs.bzl", "hs_binary")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "data_files",
    srcs = glob(["data/**"]),
)

hs_binary(
    name = "alex",
    srcs = glob(["src/**/*.hs"]) + ["autogen/Paths_alex.hs"],
    hs_source_dirs = [
        "src",
        "autogen",
    ],
    default_language = "Haskell2010",
    default_extensions = [
        "DeriveFunctor",
        "PatternSynonyms",
        "ScopedTypeVariables",
        "TupleSections",
    ],
    deps = [
        "@hs_boot//:array",
        "@hs_boot//:base",
        "@hs_boot//:containers",
        "@hs_boot//:directory",
    ],
)
""",
    )

alex_bootstrap_repo = repository_rule(
    implementation = _alex_bootstrap_repo_impl,
    doc = "Lazily downloads and bootstraps alex-3.5.4.2 from @hs_boot.",
)

def _happy_bootstrap_repo_impl(repository_ctx):
    repository_ctx.download_and_extract(
        url = "https://hackage.haskell.org/package/happy-lib-2.1.7/happy-lib-2.1.7.tar.gz",
        sha256 = "f625b2c4a3f2b5fafa3c560fa8757502cc8de83d9a84c2692fc943380900f269",
        stripPrefix = "happy-lib-2.1.7",
        output = "happy-lib",
    )
    repository_ctx.download_and_extract(
        url = "https://hackage.haskell.org/package/happy-2.1.7/happy-2.1.7.tar.gz",
        sha256 = "9e390f0ab082d11d46598f6215b2f6e8253059721860f81082409091532d7e2a",
        stripPrefix = "happy-2.1.7",
        output = "happy",
    )
    paths_body = """\
import Data.Maybe (fromMaybe)
import Data.Version (Version(..))
import System.Environment (lookupEnv)

version :: Version
version = Version [2, 1, 7] []

getDataDir :: IO FilePath
getDataDir = fmap (fromMaybe "happy-lib/data") (lookupEnv "happy_datadir")
"""
    repository_ctx.file(
        "autogen/Paths_happy.hs",
        "module Paths_happy (version, getDataDir) where\n" + paths_body,
    )
    repository_ctx.file(
        "autogen/Happy/Paths.hs",
        "module Happy.Paths (version, getDataDir) where\n" + paths_body,
    )
    repository_ctx.file(
        "BUILD.bazel",
        """\
load("@rules_haskell//haskell:defs.bzl", "hs_binary")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "data_files",
    srcs = glob(["happy-lib/data/**"]),
)

hs_binary(
    name = "happy",
    srcs = glob(
        [
            "happy/app/**/*.lhs",
            "happy-lib/grammar/src/**/*.hs",
            "happy-lib/grammar/src/**/*.lhs",
            "happy-lib/frontend/src/**/*.hs",
            "happy-lib/frontend/src/**/*.lhs",
            "happy-lib/tabular/src/**/*.hs",
            "happy-lib/tabular/src/**/*.lhs",
            "happy-lib/backend-lalr/src/**/*.hs",
            "happy-lib/backend-lalr/src/**/*.lhs",
            "happy-lib/backend-glr/src/**/*.hs",
            "happy-lib/backend-glr/src/**/*.lhs",
        ],
        allow_empty = True,
    ) + [
        "autogen/Happy/Paths.hs",
        "autogen/Paths_happy.hs",
    ],
    hs_source_dirs = [
        "happy/app",
        "happy-lib/grammar/src",
        "happy-lib/frontend/src",
        "happy-lib/tabular/src",
        "happy-lib/backend-lalr/src",
        "happy-lib/backend-glr/src",
        "autogen",
    ],
    default_language = "Haskell98",
    default_extensions = [
        "CPP",
        "FlexibleContexts",
        "MagicHash",
        "NamedFieldPuns",
        "PatternGuards",
    ],
    deps = [
        "@hs_boot//:array",
        "@hs_boot//:base",
        "@hs_boot//:containers",
        "@hs_boot//:mtl",
        "@hs_boot//:transformers",
    ],
)
""",
    )

happy_bootstrap_repo = repository_rule(
    implementation = _happy_bootstrap_repo_impl,
    doc = "Lazily downloads and bootstraps happy-2.1.7 + happy-lib-2.1.7 from @hs_boot.",
)
