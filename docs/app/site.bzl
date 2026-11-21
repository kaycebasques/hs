"""Hermetic Bazel rule compiling the rules_hs Hakyll + Pandoc documentation site."""

def _hs_docs_site_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name)

    args = ctx.actions.args()
    args.add("--content-dir", ctx.attr.content_dir)
    args.add("--templates-dir", ctx.attr.templates_dir)
    args.add("--static-dir", ctx.attr.static_dir)
    args.add("--bzl-dir", ctx.attr.bzl_dir)
    args.add("--out-dir", out_dir.path)

    all_inputs = depset(
        ctx.files.content + ctx.files.templates + ctx.files.static + ctx.files.bzl_srcs,
    )

    ctx.actions.run_shell(
        mnemonic = "HsDocsSite",
        progress_message = "Building Hakyll documentation site {}".format(ctx.label),
        inputs = all_inputs,
        tools = [ctx.executable.compiler],
        outputs = [out_dir],
        command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
COMPILER="$1"
shift
CACHE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/hs_docs_site.XXXXXX")"
trap 'rm -rf "$CACHE_WORK"' EXIT
export TMPDIR="$CACHE_WORK/tmp"
mkdir -p "$TMPDIR"
"$COMPILER" --cache-dir "$CACHE_WORK/hakyll" "$@"
""",
        arguments = [ctx.executable.compiler.path, args],
    )

    return [
        DefaultInfo(
            files = depset([out_dir]),
            runfiles = ctx.runfiles(files = [out_dir]),
        ),
    ]

hs_docs_site = rule(
    implementation = _hs_docs_site_impl,
    attrs = {
        "compiler": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
        ),
        "content": attr.label_list(allow_files = [".md"], mandatory = True),
        "templates": attr.label_list(allow_files = True, mandatory = True),
        "static": attr.label_list(allow_files = True, mandatory = True),
        "bzl_srcs": attr.label_list(allow_files = [".bzl"], mandatory = True),
        "content_dir": attr.string(default = "docs/content"),
        "templates_dir": attr.string(default = "docs/templates"),
        "static_dir": attr.string(default = "docs/static"),
        "bzl_dir": attr.string(default = "hs"),
    },
    doc = "Compiles Markdown and Starlark sources into a static HTML documentation TreeArtifact via Hakyll.",
)
