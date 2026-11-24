"""Hermetic GHC Haddock documentation rule (`hs_haddock`)."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("//haskell:providers.bzl", "HsHaddockInfo", "HsLinkInfo", "HsPackageInfo")
load("//haskell:toolchain.bzl", "TOOLCHAIN_TYPE")
load(
    "//haskell/private:actions.bzl",
    "HsDocSourceInfo",
    "collect_deps",
    "get_hs_toolchain",
    "ghc_base_env",
    "ghc_tool_flags",
    "resolve_cc_tools",
)

def _append_unique(dst, seen, items):
    for item in items:
        if item and item not in seen:
            seen[item] = True
            dst.append(item)

def _append_unique_files(dst, seen, files):
    for f in files:
        if f and f.path not in seen:
            seen[f.path] = True
            dst.append(f)

def _expand_boot_package_names(hs_tc, seed_names):
    """Expands boot package names transitively across boot_packages[pkg]['depends']."""
    uid_to_name = {}
    for name, meta in hs_tc.boot_packages.items():
        uid = meta.get("id", "")
        if uid:
            uid_to_name[uid] = name

    visited = {}
    frontier = []
    for s in seed_names:
        if s in hs_tc.boot_packages and s not in visited:
            visited[s] = True
            frontier.append(s)

    if not frontier and "base" in hs_tc.boot_packages:
        visited["base"] = True
        frontier.append("base")

    for _ in range(len(hs_tc.boot_packages) + 1):
        if not frontier:
            break
        next_frontier = []
        for bname in frontier:
            meta = hs_tc.boot_packages.get(bname)
            if not meta:
                continue
            for dep_uid in meta.get("depends", []):
                dep_name = uid_to_name.get(dep_uid, "")
                if dep_name and dep_name not in visited:
                    visited[dep_name] = True
                    next_frontier.append(dep_name)
        frontier = next_frontier

    return sorted(visited.keys())

def _hs_haddock_impl(ctx):
    hs_tc = get_hs_toolchain(ctx)
    cc_tools = resolve_cc_tools(ctx)
    dep_info = collect_deps(ctx.attr.deps)

    doc_infos = []
    for dep in ctx.attr.deps:
        if HsDocSourceInfo not in dep:
            fail("Target {} in hs_haddock.deps does not provide Haskell library sources (expected hs_library or hs_cabal_library).".format(dep.label))
        di = dep[HsDocSourceInfo]
        if di.doc_src_files:
            doc_infos.append(di)

    if not doc_infos:
        fail("hs_haddock target {} found no Haskell source modules in deps.".format(ctx.label))

    documented_unit_ids = {di.unit_id: True for di in doc_infos if di.unit_id}
    documented_pkg_dbs = {di.pkg_db.path: True for di in doc_infos if di.pkg_db}

    doc_src_files = []
    seen_doc_srcs = {}
    all_hs_srcs = []
    seen_all_srcs = {}
    import_dirs = []
    seen_import_dirs = {}
    local_c_inc_dirs = []
    seen_c_inc_dirs = {}
    hidden_modules = []
    seen_hidden = {}
    default_extensions = []
    seen_exts = {}
    cpp_options = []
    seen_cpp = {}
    cc_options = []
    seen_cc_opts = {}
    lib_ghc_opts = []
    seen_ghc_opts = {}
    direct_unit_ids = []
    seen_uids = {}
    cabal_macros_files = []
    seen_macros = {}
    compile_data = []
    seen_data = {}
    local_headers = []
    default_language = ""
    pkg_root = "."

    for di in doc_infos:
        _append_unique_files(doc_src_files, seen_doc_srcs, di.doc_src_files)
        _append_unique_files(all_hs_srcs, seen_all_srcs, di.all_hs_srcs)
        _append_unique(import_dirs, seen_import_dirs, di.import_dirs)
        _append_unique(local_c_inc_dirs, seen_c_inc_dirs, di.c_include_dirs)
        _append_unique(hidden_modules, seen_hidden, di.hidden_modules)
        _append_unique(default_extensions, seen_exts, di.default_extensions)
        _append_unique(cpp_options, seen_cpp, di.cpp_options)
        _append_unique(cc_options, seen_cc_opts, di.cc_options)
        _append_unique(lib_ghc_opts, seen_ghc_opts, di.ghc_opts)
        for uid in di.direct_unit_ids:
            if uid and uid not in documented_unit_ids and uid not in seen_uids:
                seen_uids[uid] = True
                direct_unit_ids.append(uid)
        if di.cabal_macros_h:
            _append_unique_files(cabal_macros_files, seen_macros, [di.cabal_macros_h])
        _append_unique_files(compile_data, seen_data, di.compile_data)
        local_headers.append(di.headers)
        if not default_language and di.default_language:
            default_language = di.default_language
        if pkg_root == "." and di.pkg_root and di.pkg_root != ".":
            pkg_root = di.pkg_root

    c_inc_dirs = []
    seen_all_c_inc = {}
    _append_unique(
        c_inc_dirs,
        seen_all_c_inc,
        local_c_inc_dirs + dep_info.include_dirs.to_list() + [hs_tc.rts_include_dir],
    )

    ext_pkg_dbs = [
        db
        for db in dep_info.pkg_dbs.to_list()
        if db.path not in documented_pkg_dbs
    ]

    html_dir = ctx.actions.declare_directory(ctx.label.name)
    interface = ctx.actions.declare_file(ctx.label.name + ".haddock")

    if len(doc_infos) == 1:
        pkg_name = doc_infos[0].package_name
        pkg_ver = doc_infos[0].version
    else:
        pkg_name = ctx.label.name.replace("_", "-")
        pkg_ver = "0.0.0"

    title = ctx.attr.title if ctx.attr.title else ctx.label.name

    haddock_args = ctx.actions.args()
    haddock_args.add("-B", hs_tc.libdir.path)
    haddock_args.add("-l", hs_tc.libdir.path)
    haddock_args.add("--odir=" + html_dir.path)
    haddock_args.add("--dump-interface=" + interface.path)
    haddock_args.add("--html")
    haddock_args.add("--use-unicode")
    haddock_args.add("--package-name=" + pkg_name)
    haddock_args.add("--package-version=" + pkg_ver)
    haddock_args.add("--title=" + title)

    if ctx.attr.quickjump:
        haddock_args.add("--quickjump")
    if ctx.attr.hyperlinked_source:
        haddock_args.add("--hyperlinked-source")
    if ctx.attr.hoogle:
        haddock_args.add("--hoogle")

    extra_in = list(all_hs_srcs) + list(cabal_macros_files) + list(compile_data)
    if ctx.file.prologue:
        haddock_args.add("--prologue=" + ctx.file.prologue.path)
        extra_in.append(ctx.file.prologue)

    for hm in hidden_modules:
        haddock_args.add("--hide=" + hm)

    # Link transitive GHC boot package interfaces to official Hackage documentation URLs.
    boot_names = _expand_boot_package_names(hs_tc, dep_info.boot_pkg_names.to_list())
    for bname in boot_names:
        if bname in hs_tc.boot_haddocks:
            bfile = hs_tc.boot_haddocks[bname]
            bver = hs_tc.boot_packages[bname].get("version", "")
            if bver:
                haddock_args.add(
                    "--read-interface=https://hackage.haskell.org/package/{}-{}/docs,{}".format(
                        bname,
                        bver,
                        bfile.path,
                    ),
                )
                extra_in.append(bfile)

    # Link upstream hs_haddock targets via relative sibling URLs.
    upstream_haddock_sets = [
        hd[HsHaddockInfo].transitive_haddocks
        for hd in ctx.attr.haddock_deps
    ]
    upstream_haddocks = depset(transitive = upstream_haddock_sets)
    for entry in upstream_haddocks.to_list():
        haddock_args.add(
            "--read-interface=../{},{}".format(
                entry.html_dir.basename,
                entry.interface.path,
            ),
        )
        extra_in.append(entry.interface)

    # Forward hermetic GHC flags via --optghc=.
    ghc_tokens = [
        "-fPIC",
        "-hide-all-packages",
    ]
    if len(doc_infos) == 1 and doc_infos[0].unit_id:
        ghc_tokens.extend(["-this-unit-id", doc_infos[0].unit_id])
    for db in ext_pkg_dbs:
        ghc_tokens.extend(["-package-db", db.path])
    for uid in direct_unit_ids:
        ghc_tokens.extend(["-package-id", uid])
    if default_language:
        ghc_tokens.append("-X" + default_language)
    for ext in default_extensions:
        ghc_tokens.append("-X" + ext)
    ghc_tokens.append("-i")
    for d in import_dirs:
        ghc_tokens.append("-i" + d)
    for d in c_inc_dirs:
        ghc_tokens.append("-I" + d)
    for mf in cabal_macros_files:
        ghc_tokens.extend([
            "-optP-include",
            "-optP" + mf.path,
            "-optc-include",
            "-optc" + mf.path,
        ])
    for opt in cpp_options:
        ghc_tokens.append("-optP" + opt)
    for opt in cc_options:
        if not (opt.startswith("-std=c++") or opt.startswith("-std=gnu++") or opt.startswith("-stdlib=")):
            ghc_tokens.append("-optc" + opt)
    ghc_tokens.extend(ghc_tool_flags(hs_tc, cc_tools))
    ghc_tokens.extend(lib_ghc_opts)
    ghc_tokens.extend(ctx.attr.ghc_opts)

    for tok in ghc_tokens:
        haddock_args.add("--optghc=" + tok)

    for hopt in ctx.attr.haddock_opts:
        haddock_args.add(hopt)

    for src_f in doc_src_files:
        haddock_args.add(src_f.path)

    has_compile_data = "1" if compile_data else "0"

    ctx.actions.run_shell(
        mnemonic = "HsHaddock",
        progress_message = "Generating Haddock documentation {}".format(ctx.label),
        inputs = depset(
            extra_in,
            transitive = [
                hs_tc.all_files,
                dep_info.pkg_dbs,
                dep_info.hs_libs,
                dep_info.headers,
                cc_tools.all_files,
            ] + local_headers,
        ),
        tools = [hs_tc.haddock, hs_tc.cc_wrapper],
        outputs = [html_dir, interface],
        env = ghc_base_env(cc_tools),
        command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY

HADDOCK="$1"
HTML_DIR="$2"
HAS_COMPILE_DATA="$3"
PKG_ROOT="$4"
shift 4

EXECROOT="$(pwd)"
case "${RULES_HASKELL_REAL_CC:-}" in
    ""|/*) ;;
    *) export RULES_HASKELL_REAL_CC="$EXECROOT/$RULES_HASKELL_REAL_CC" ;;
esac
case "$HADDOCK" in
    /*) HADDOCK_ABS="$HADDOCK" ;;
    *) HADDOCK_ABS="$EXECROOT/$HADDOCK" ;;
esac

mkdir -p "$HTML_DIR"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hs_haddock.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT
export TMPDIR="$WORK_ROOT/tmp"
mkdir -p "$TMPDIR"

GHC_CWD="$EXECROOT"
if [ "$HAS_COMPILE_DATA" = "1" ] && [ "$PKG_ROOT" != "." ] && [ -d "$EXECROOT/$PKG_ROOT" ]; then
    GHC_CWD="$WORK_ROOT/pkg_cwd"
    mkdir -p "$GHC_CWD"
    for top in "$EXECROOT"/*; do
        [ -e "$top" ] || [ -L "$top" ] || continue
        ln -s "$top" "$GHC_CWD/$(basename "$top")"
    done
    for item in "$EXECROOT/$PKG_ROOT"/* "$EXECROOT/$PKG_ROOT"/.*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        iname="$(basename "$item")"
        [ "$iname" = "." ] || [ "$iname" = ".." ] && continue
        if [ "$iname" != "bazel-out" ] && [ "$iname" != "external" ]; then
            ln -snf "$item" "$GHC_CWD/$iname"
        fi
    done
fi

(cd "$GHC_CWD" && "$HADDOCK_ABS" "$@")
""",
        arguments = [
            hs_tc.haddock.path,
            html_dir.path,
            has_compile_data,
            pkg_root,
            haddock_args,
        ],
    )

    own_entry = struct(
        html_dir = html_dir,
        interface = interface,
    )

    return [
        DefaultInfo(
            files = depset([html_dir]),
            runfiles = ctx.runfiles(files = [html_dir]),
        ),
        HsHaddockInfo(
            html_dir = html_dir,
            interface = interface,
            unit_ids = depset(sorted(documented_unit_ids.keys())),
            transitive_haddocks = depset([own_entry], transitive = upstream_haddock_sets),
        ),
        OutputGroupInfo(
            haddock_interface = depset([interface]),
        ),
    ]

hs_haddock = rule(
    implementation = _hs_haddock_impl,
    doc = "Generates hermetic HTML API documentation, QuickJump search index, and hyperlinked source via GHC's bundled Haddock.",
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            allow_empty = False,
            providers = [HsPackageInfo, HsLinkInfo],
            doc = "One or more hs_library (or hs_cabal_library) targets whose modules are documented together.",
        ),
        "haddock_deps": attr.label_list(
            default = [],
            providers = [HsHaddockInfo],
            doc = "Optional upstream hs_haddock targets linked via --read-interface.",
        ),
        "title": attr.string(
            default = "",
            doc = "HTML heading (--title); defaults to the target name.",
        ),
        "prologue": attr.label(
            allow_single_file = [".md", ".txt", ".prologue"],
            doc = "Optional prologue file (--prologue) rendered on index.html.",
        ),
        "hyperlinked_source": attr.bool(
            default = True,
            doc = "Emit syntax-highlighted hyperlinked source in src/ (--hyperlinked-source).",
        ),
        "quickjump": attr.bool(
            default = True,
            doc = "Emit doc-index.json and QuickJump interactive search assets (--quickjump).",
        ),
        "hoogle": attr.bool(
            default = False,
            doc = "Also emit a Hoogle text database (--hoogle) in the output directory.",
        ),
        "haddock_opts": attr.string_list(
            default = [],
            doc = "Additional flags passed directly to haddock.",
        ),
        "ghc_opts": attr.string_list(
            default = [],
            doc = "Additional GHC flags forwarded to haddock via --optghc=.",
        ),
    },
    toolchains = [TOOLCHAIN_TYPE] + use_cc_toolchain(),
    fragments = ["cpp"],
    provides = [HsHaddockInfo],
)
