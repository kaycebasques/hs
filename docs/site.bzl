"""Minimal Bazel rule building the Hakyll docs TreeArtifact and mounting hs_haddock outputs."""

def _hs_docs_site_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.label.name)
    pkg_prefix = ctx.label.package + "/" if ctx.label.package else ""

    src_specs = [
        "{}={}".format(f.short_path.removeprefix(pkg_prefix), f.path)
        for f in ctx.files.srcs
    ]

    haddock_dirs = []
    haddock_mounts = []
    for target, mount_rel in ctx.attr.haddocks.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("Expected single Haddock directory output from {}, got {}".format(target.label, files))
        haddock_dirs.append(files[0])
        haddock_mounts.append("{}={}".format(mount_rel.strip("/"), files[0].path))

    args = ctx.actions.args()
    args.add(ctx.executable.compiler.path)
    args.add(out_dir.path)
    args.add(str(len(src_specs)))
    args.add_all(src_specs)
    args.add_all(haddock_mounts)

    ctx.actions.run_shell(
        mnemonic = "HsDocsSite",
        progress_message = "Building Hakyll documentation site {}".format(ctx.label),
        inputs = depset(ctx.files.srcs + haddock_dirs),
        tools = [ctx.executable.compiler],
        outputs = [out_dir],
        command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
COMPILER="$1"; OUT_DIR="$2"; NUM_SRCS="$3"; shift 3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hs_docs_site.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
PROVIDER="$WORK/provider"
CACHE="$WORK/cache"
mkdir -p "$TMPDIR" "$PROVIDER" "$CACHE" "$OUT_DIR"

for ((i = 0; i < NUM_SRCS; i++)); do
    spec="$1"; shift
    rel="${spec%%=*}"; src="${spec#*=}"
    mkdir -p "$PROVIDER/$(dirname "$rel")"
    cp -L "$src" "$PROVIDER/$rel"
done

DOCS_PROVIDER_DIR="$PROVIDER" DOCS_OUT_DIR="$OUT_DIR" DOCS_CACHE_DIR="$CACHE" "$COMPILER" build

for spec in "$@"; do
    mount_rel="${spec%%=*}"; src_dir="${spec#*=}"
    mkdir -p "$OUT_DIR/$mount_rel"
    cp -R -L "$src_dir"/. "$OUT_DIR/$mount_rel"/
done
""",
        arguments = [args],
    )

    return [DefaultInfo(files = depset([out_dir]), runfiles = ctx.runfiles(files = [out_dir]))]

hs_docs_site = rule(
    implementation = _hs_docs_site_impl,
    attrs = {
        "compiler": attr.label(mandatory = True, executable = True, cfg = "target"),
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "haddocks": attr.label_keyed_string_dict(allow_files = True, default = {}),
    },
    doc = "Builds a static HTML documentation TreeArtifact via Hakyll and mounts hs_haddock subtrees.",
)
