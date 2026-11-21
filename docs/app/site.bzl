"""Hermetic Bazel rule building the vanilla Hakyll documentation site + mounted Haddock subtrees."""

def _hs_docs_site_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name)

    haddock_mounts = []
    haddock_dirs = []
    for target, mount_rel in ctx.attr.haddocks.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("Expected single Haddock directory output from {}, got {}".format(target.label, files))
        hdir = files[0]
        haddock_dirs.append(hdir)
        haddock_mounts.append("{}={}".format(mount_rel.strip("/"), hdir.path))

    all_inputs = depset(
        ctx.files.content + ctx.files.templates + ctx.files.static + haddock_dirs,
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
CONTENT_DIR="$2"
TEMPLATES_DIR="$3"
STATIC_DIR="$4"
OUT_DIR="$5"
shift 5

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hs_docs_site.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
PROVIDER="$WORK/provider"
CACHE="$WORK/cache"
mkdir -p "$TMPDIR" "$PROVIDER/content" "$PROVIDER/templates" "$PROVIDER/static" "$CACHE" "$OUT_DIR"

cp -R -L "$CONTENT_DIR"/. "$PROVIDER/content"/
cp -R -L "$TEMPLATES_DIR"/. "$PROVIDER/templates"/
cp -R -L "$STATIC_DIR"/. "$PROVIDER/static"/
chmod -R u+w "$PROVIDER"

DOCS_PROVIDER_DIR="$PROVIDER" \
DOCS_OUT_DIR="$OUT_DIR" \
DOCS_CACHE_DIR="$CACHE" \
"$COMPILER" build

for mount_spec in "$@"; do
    mount_rel="${mount_spec%%=*}"
    src_dir="${mount_spec#*=}"
    dst_dir="$OUT_DIR/$mount_rel"
    mkdir -p "$dst_dir"
    cp -R -L "$src_dir"/. "$dst_dir"/
done
""",
        arguments = [
            ctx.executable.compiler.path,
            ctx.attr.content_dir,
            ctx.attr.templates_dir,
            ctx.attr.static_dir,
            out_dir.path,
        ] + haddock_mounts,
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
        "haddocks": attr.label_keyed_string_dict(
            allow_files = True,
            default = {},
            doc = "Map of hs_haddock target -> site-relative mount path (e.g. 'haddock/lock').",
        ),
        "content_dir": attr.string(default = "docs/content"),
        "templates_dir": attr.string(default = "docs/templates"),
        "static_dir": attr.string(default = "docs/static"),
    },
    doc = "Builds a static HTML documentation TreeArtifact via vanilla Hakyll and mounts hs_haddock subtrees.",
)
