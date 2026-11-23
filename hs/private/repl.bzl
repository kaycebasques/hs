"""Interactive GHCi REPL (`hs_repl`) and script interpreter (`hs_runghc`) rules."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//hs:providers.bzl", "HsLinkInfo", "HsPackageInfo", "HsReplInfo")
load("//hs:toolchain.bzl", "TOOLCHAIN_TYPE")
load(
    "//hs/private:actions.bzl",
    "HsDocSourceInfo",
    "collect_deps",
    "compile_c_sources",
    "extract_cc_static_libs_and_flags",
    "get_hs_toolchain",
    "ghc_base_env",
    "resolve_cc_tools",
    "resolve_package_dir",
)

def _shell_quote(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"

def _sanitize_ident(name):
    return name.replace("-", "_").replace(".", "_").replace("/", "_").replace(":", "_")

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

def _runfiles_rel(file):
    """Returns path of `file` relative to $RUNFILES_DIR."""
    sp = file.short_path
    if sp.startswith("../"):
        return sp[3:]
    return "_main/" + sp

def _runfiles_expr(file):
    """Returns a double-quoted shell expression resolving `file` inside $RUNFILES_DIR."""
    return '"$RUNFILES_DIR"/' + _shell_quote(_runfiles_rel(file))

def _source_or_runfiles_expr(file):
    """Resolves main-workspace source files via $WS_ROOT (for live :reload) and generated/external files via $RUNFILES_DIR."""
    if file.is_source and not file.owner.workspace_root:
        return '"$WS_ROOT"/' + _shell_quote(file.short_path)
    return _runfiles_expr(file)

def _execroot_str_to_shell_expr(path_str, prefer_ws_root = False):
    """Converts an execroot-relative or absolute path string into a runtime shell expression."""
    if not path_str:
        return '""'
    if path_str.startswith("/"):
        return _shell_quote(path_str)
    if path_str.startswith("bazel-out/"):
        parts = path_str.split("/")
        if len(parts) >= 4 and parts[2] == "bin":
            rest = "/".join(parts[3:])
            if rest.startswith("external/"):
                return '"$RUNFILES_DIR"/' + _shell_quote(rest[len("external/"):])
            return '"$RUNFILES_DIR"/' + _shell_quote("_main/" + rest)
    if path_str.startswith("external/"):
        return '"$RUNFILES_DIR"/' + _shell_quote(path_str[len("external/"):])
    if prefer_ws_root:
        if path_str == ".":
            return '"$WS_ROOT"'
        return '"$WS_ROOT"/' + _shell_quote(path_str)
    if path_str == ".":
        return '"$RUNFILES_DIR/_main"'
    return '"$RUNFILES_DIR"/' + _shell_quote("_main/" + path_str)

def _toolchain_c_include_dirs(hs_tc):
    dirs = []
    seen = {}
    if hs_tc.rts_include_dir:
        dirs.append(hs_tc.rts_include_dir)
        seen[hs_tc.rts_include_dir] = True
    for f in hs_tc.rts_headers.to_list():
        d = f.dirname
        idx = d.rfind("/include")
        inc_d = d[:idx + len("/include")] if idx != -1 else d
        if inc_d and inc_d not in seen:
            seen[inc_d] = True
            dirs.append(inc_d)
    return dirs

def _cc_extra_args_shell_lines(cc_tools):
    """Formats RULES_HS_CC_IS_GCC and RULES_HS_CC_EXTRA_ARGS lines anchored to $RUNFILES_DIR."""
    lines = []
    if cc_tools.is_gcc:
        lines.append("export RULES_HS_CC_IS_GCC=1")
    extra_cc_args = cc_tools.extra_cc_args
    if not extra_cc_args:
        lines.append("export RULES_HS_CC_EXTRA_ARGS=''")
        return "\n".join(lines)
    exprs = []
    prev_sysroot = False
    for arg in extra_cc_args:
        if prev_sysroot:
            prev_sysroot = False
            exprs.append(_execroot_str_to_shell_expr(arg, prefer_ws_root = False))
        elif arg == "--sysroot":
            prev_sysroot = True
            exprs.append(_shell_quote(arg))
        elif arg.startswith("--sysroot="):
            raw = arg[len("--sysroot="):]
            exprs.append('"--sysroot="{}'.format(_execroot_str_to_shell_expr(raw, prefer_ws_root = False)))
        elif arg.startswith("-resource-dir="):
            raw = arg[len("-resource-dir="):]
            exprs.append('"-resource-dir="{}'.format(_execroot_str_to_shell_expr(raw, prefer_ws_root = False)))
        elif arg.startswith("-B") and len(arg) > 2:
            raw = arg[2:]
            exprs.append('"-B"{}'.format(_execroot_str_to_shell_expr(raw, prefer_ws_root = False)))
        elif arg.startswith("--ld-path=external/") or arg.startswith("--ld-path=bazel-out/"):
            raw = arg[len("--ld-path="):]
            exprs.append('"--ld-path="{}'.format(_execroot_str_to_shell_expr(raw, prefer_ws_root = False)))
        else:
            exprs.append(_shell_quote(arg))
    lines.append("CC_EXTRA_NL=''")
    for ex in exprs:
        lines.append('if [ -n "$CC_EXTRA_NL" ]; then CC_EXTRA_NL="${CC_EXTRA_NL}\n"%s; else CC_EXTRA_NL=%s; fi' % (ex, ex))
    lines.append('export RULES_HS_CC_EXTRA_ARGS="$CC_EXTRA_NL"')
    return "\n".join(lines)

def _repl_ghc_tool_flag_exprs(hs_tc, cc_tools):
    """Returns shell-quoted GHC -B / -pgm* / -opt* expressions resolved via $RUNFILES_DIR."""
    w = _runfiles_expr(hs_tc.cc_wrapper)
    libdir = _runfiles_expr(hs_tc.libdir)
    ar = _execroot_str_to_shell_expr(cc_tools.ar, prefer_ws_root = False)
    exprs = [
        '"-B"' + libdir,
        '"-pgmc"',
        w,
        '"-pgmcxx"',
        w,
        '"-pgml"',
        w,
        '"-pgma"',
        w,
        '"-pgmP"',
        w,
        '"-optP-E"',
        '"-optP-undef"',
        '"-optP-traditional"',
        '"-pgmCmmP"',
        w,
        '"-optCmmP-E"',
        '"-pgmar"',
        ar,
        '"-optl-Wl,--no-as-needed"',
    ]
    if cc_tools.ld:
        ld = _execroot_str_to_shell_expr(cc_tools.ld, prefer_ws_root = False)
        exprs.extend([
            '"-pgmlm"',
            ld,
            '"-optlm-r"',
        ])
    return exprs

def _sanitize_inherited_ghc_opts(opts):
    """Strips batch/link-only flags from upstream library/binary ghc_opts for GHCi bytecode."""
    cleaned = []
    skip_next = False
    for opt in opts:
        if skip_next:
            skip_next = False
            continue
        if opt in ("-with-rtsopts", "-main-is"):
            skip_next = True
            continue
        if opt in (
            "-O",
            "-O0",
            "-O1",
            "-O2",
            "-Werror",
            "-threaded",
            "-rtsopts",
            "-no-rtsopts",
            "-dynamic-too",
            "-optl-no-pie",
            "-staticlib",
        ):
            continue
        if (
            opt.startswith("-O") or
            opt.startswith("-Werror=") or
            opt.startswith("-with-rtsopts=") or
            opt.startswith("-main-is=")
        ):
            continue
        cleaned.append(opt)
    return cleaned

def _link_repl_cbits_so(ctx, hs_tc, cc_tools, cc_archives, cc_link_flags):
    """Links native C/C++ archives into a shared .so loadable by GHCi's dynamic linker."""
    safe_id = _sanitize_ident(ctx.label.name) + "_cbits"
    out_so = ctx.actions.declare_file("{}_repl_cbits/lib{}.so".format(ctx.label.name, safe_id))
    rt_shims = extract_cc_static_libs_and_flags(ctx.attr._rt_shims[CcInfo])[0]
    shim_archives = [f for f in rt_shims if f.path.endswith(".a")]

    args = ctx.actions.args()
    args.add("-shared")
    args.add("-fPIC")
    args.add("-Wl,-soname,lib{}.so".format(safe_id))
    args.add("-Wl,-Bsymbolic")
    args.add("-L{}/{}".format(hs_tc.libdir.path, hs_tc.arch_libdir))
    args.add("-Wl,--whole-archive")
    for a in cc_archives:
        args.add(a.path)
    args.add("-Wl,--no-whole-archive")
    for sa in shim_archives:
        args.add(sa.path)
    for lf in cc_link_flags:
        args.add(lf)
    args.add("-o", out_so.path)

    ctx.actions.run_shell(
        mnemonic = "HsLinkReplCbits",
        progress_message = "Linking GHCi C/C++ shared stub for {}".format(ctx.label),
        inputs = depset(
            list(cc_archives) + shim_archives,
            transitive = [hs_tc.all_files, cc_tools.all_files],
        ),
        tools = [hs_tc.cc_wrapper],
        outputs = [out_so],
        env = ghc_base_env(cc_tools),
        command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
EXECROOT="$(pwd)"
case "${RULES_HS_REAL_CC:-}" in
    ""|/*) ;;
    *) export RULES_HS_REAL_CC="$EXECROOT/$RULES_HS_REAL_CC" ;;
esac
WRAPPER="$1"
shift
"$WRAPPER" "$@"
""",
        arguments = [hs_tc.cc_wrapper.path, args],
    )
    return out_so, safe_id

# ==============================================================================
# hs_repl
# ==============================================================================

def _hs_repl_impl(ctx):
    hs_tc = get_hs_toolchain(ctx)
    cc_tools = resolve_cc_tools(ctx)

    compiled_labels = {dep.label: True for dep in ctx.attr.compiled_deps}
    interpreted_infos = []
    for dep in ctx.attr.deps:
        if dep.label in compiled_labels:
            continue
        if HsPackageInfo not in dep and HsDocSourceInfo in dep:
            # hs_binary / hs_test targets have no .pkgdb; always interpret from source.
            interpreted_infos.append(dep[HsDocSourceInfo])
        elif (
            ctx.attr.interpret_deps and
            not dep.label.workspace_root and
            HsDocSourceInfo in dep and
            dep[HsDocSourceInfo].doc_src_files
        ):
            interpreted_infos.append(dep[HsDocSourceInfo])

    all_dep_targets = list(ctx.attr.deps) + list(ctx.attr.compiled_deps)
    dep_info = collect_deps(all_dep_targets, ctx.attr.cc_deps)

    # Compile any C/C++ sources owned directly by the hs_repl target and merge with transitive CcInfo.
    merged_cc_info, _, _ = compile_c_sources(
        ctx = ctx,
        hs_tc = hs_tc,
        cc_tools = cc_tools,
        c_sources = ctx.files.c_sources,
        hdrs = ctx.files.hdrs,
        install_includes = [f.basename for f in ctx.files.hdrs],
        include_dirs = ctx.attr.include_dirs,
        configure_outputs = [],
        configure_include_dirs = [],
        cabal_macros_h = None,
        cc_options = ctx.attr.cc_options,
        dep_cc_info = dep_info.cc_info,
    )

    interpreted_unit_ids = {di.unit_id: True for di in interpreted_infos if di.unit_id}
    interpreted_pkg_dbs = {di.pkg_db.path: True for di in interpreted_infos if di.pkg_db}

    ext_pkg_dbs = [
        db
        for db in dep_info.pkg_dbs.to_list()
        if db.path not in interpreted_pkg_dbs
    ]

    direct_unit_ids = []
    seen_uids = {}
    for pkg in dep_info.direct_pkgs:
        if pkg.unit_id and pkg.unit_id not in interpreted_unit_ids and pkg.unit_id not in seen_uids:
            seen_uids[pkg.unit_id] = True
            direct_unit_ids.append(pkg.unit_id)

    for di in interpreted_infos:
        for uid in di.direct_unit_ids:
            if uid and uid not in interpreted_unit_ids and uid not in seen_uids:
                seen_uids[uid] = True
                direct_unit_ids.append(uid)

    if not ctx.attr.expose_boot_packages and not direct_unit_ids and "base" in hs_tc.boot_packages:
        base_uid = hs_tc.boot_packages["base"].get("id", "")
        if base_uid:
            direct_unit_ids.append(base_uid)

    own_doc_srcs = [
        f
        for f in ctx.files.srcs
        if not (f.path.endswith(".hs-boot") or f.path.endswith(".lhs-boot"))
    ]
    own_all_srcs = list(ctx.files.srcs)
    own_src_dirs_raw = ctx.attr.hs_source_dirs or (["."] if ctx.files.srcs else [])
    own_import_dirs = [resolve_package_dir(ctx, d) for d in own_src_dirs_raw]
    if any([not f.is_source for f in ctx.files.srcs]) and ctx.bin_dir.path:
        for d in list(own_import_dirs):
            own_import_dirs.append(ctx.bin_dir.path + "/" + d if d != "." else ctx.bin_dir.path)
    own_c_inc_dirs = [resolve_package_dir(ctx, d) for d in ctx.attr.include_dirs]

    repl_src_files = []
    seen_repl_srcs = {}
    all_hs_srcs = []
    seen_all_srcs = {}
    import_dirs = []
    seen_import_dirs = {}
    local_c_inc_dirs = []
    seen_local_c_inc = {}
    default_extensions = []
    seen_exts = {}
    cpp_options = []
    seen_cpp = {}
    cc_options = []
    seen_cc = {}
    inherited_ghc_opts = []
    seen_inh_opts = {}
    cabal_macros_files = []
    seen_macros = {}
    compile_data = []
    seen_compile_data = {}
    header_depsets = [depset(ctx.files.hdrs), dep_info.headers]
    inherited_language = ""

    for di in interpreted_infos:
        _append_unique_files(repl_src_files, seen_repl_srcs, di.doc_src_files)
        _append_unique_files(all_hs_srcs, seen_all_srcs, di.all_hs_srcs)
        _append_unique(import_dirs, seen_import_dirs, di.import_dirs)
        _append_unique(local_c_inc_dirs, seen_local_c_inc, di.c_include_dirs)
        _append_unique(default_extensions, seen_exts, di.default_extensions)
        _append_unique(cpp_options, seen_cpp, di.cpp_options)
        _append_unique(cc_options, seen_cc, di.cc_options)
        _append_unique(inherited_ghc_opts, seen_inh_opts, _sanitize_inherited_ghc_opts(di.ghc_opts))
        if di.cabal_macros_h:
            _append_unique_files(cabal_macros_files, seen_macros, [di.cabal_macros_h])
        _append_unique_files(compile_data, seen_compile_data, di.compile_data)
        header_depsets.append(di.headers)
        if not inherited_language and di.default_language:
            inherited_language = di.default_language

    _append_unique_files(repl_src_files, seen_repl_srcs, own_doc_srcs)
    _append_unique_files(all_hs_srcs, seen_all_srcs, own_all_srcs)
    _append_unique(import_dirs, seen_import_dirs, own_import_dirs)
    _append_unique(local_c_inc_dirs, seen_local_c_inc, own_c_inc_dirs)
    _append_unique(default_extensions, seen_exts, ctx.attr.default_extensions)
    _append_unique(cpp_options, seen_cpp, ctx.attr.cpp_options)
    _append_unique(cc_options, seen_cc, ctx.attr.cc_options)

    default_language = ctx.attr.default_language or inherited_language or "GHC2021"

    c_inc_dirs = []
    seen_c_inc = {}
    _append_unique(
        c_inc_dirs,
        seen_c_inc,
        local_c_inc_dirs + dep_info.include_dirs.to_list() + _toolchain_c_include_dirs(hs_tc),
    )

    cc_archives, cc_link_flags = extract_cc_static_libs_and_flags(merged_cc_info)
    cbits_so = None
    cbits_lib_name = ""
    if cc_archives and hs_tc.is_dynamic_ghc:
        cbits_so, cbits_lib_name = _link_repl_cbits_so(
            ctx = ctx,
            hs_tc = hs_tc,
            cc_tools = cc_tools,
            cc_archives = cc_archives,
            cc_link_flags = cc_link_flags,
        )

    # Write static user .ghci commands file (combined at startup with auto-discovered `*Module` scope).
    out_ghci_script = ctx.actions.declare_file(ctx.label.name + ".ghci")
    ghci_lines = [line for line in ctx.attr.ghci_commands]
    ctx.actions.write(
        output = out_ghci_script,
        content = ("\n".join(ghci_lines) + "\n") if ghci_lines else "",
    )

    # Assemble GHC base flag expressions for the launcher script.
    ghc_flag_exprs = [
        '"-fPIC"',
    ]
    if not ctx.attr.expose_boot_packages:
        ghc_flag_exprs.append('"-hide-all-packages"')
    if not ctx.attr.allow_dot_ghci:
        ghc_flag_exprs.append('"-ignore-dot-ghci"')

    for db in ext_pkg_dbs:
        ghc_flag_exprs.append('"-package-db"')
        ghc_flag_exprs.append(_runfiles_expr(db))

    for uid in direct_unit_ids:
        ghc_flag_exprs.append('"-package-id"')
        ghc_flag_exprs.append(_shell_quote(uid))

    if default_language:
        ghc_flag_exprs.append(_shell_quote("-X" + default_language))

    for ext in default_extensions:
        ghc_flag_exprs.append(_shell_quote("-X" + ext))

    if import_dirs:
        ghc_flag_exprs.append('"-i"')
        for d in import_dirs:
            prefer_ws = not (d.startswith("bazel-out/") or d.startswith("external/") or d.startswith("/"))
            ghc_flag_exprs.append('"-i"' + _execroot_str_to_shell_expr(d, prefer_ws_root = prefer_ws))

    for d in c_inc_dirs:
        prefer_ws = not (d.startswith("bazel-out/") or d.startswith("external/") or d.startswith("/"))
        ghc_flag_exprs.append('"-I"' + _execroot_str_to_shell_expr(d, prefer_ws_root = prefer_ws))

    for mf in cabal_macros_files:
        mf_expr = _runfiles_expr(mf)
        ghc_flag_exprs.extend([
            '"-optP-include"',
            '"-optP"' + mf_expr,
            '"-optc-include"',
            '"-optc"' + mf_expr,
        ])

    for opt in cpp_options:
        ghc_flag_exprs.append(_shell_quote("-optP" + opt))

    for opt in cc_options:
        if not (opt.startswith("-std=c++") or opt.startswith("-std=gnu++") or opt.startswith("-stdlib=")):
            ghc_flag_exprs.append(_shell_quote("-optc" + opt))

    ghc_flag_exprs.extend(_repl_ghc_tool_flag_exprs(hs_tc, cc_tools))

    if cbits_so:
        cbits_rel_dir = _runfiles_rel(cbits_so)
        idx = cbits_rel_dir.rfind("/")
        cbits_dir = cbits_rel_dir[:idx] if idx != -1 else "."
        ghc_flag_exprs.append('"-L$RUNFILES_DIR"/' + _shell_quote(cbits_dir))
        ghc_flag_exprs.append(_shell_quote("-l" + cbits_lib_name))

    for opt in inherited_ghc_opts:
        ghc_flag_exprs.append(_shell_quote(opt))
    for opt in ctx.attr.ghc_opts:
        ghc_flag_exprs.append(_shell_quote(opt))
    ghc_flag_exprs.append('"-Wno-missed-extra-shared-lib"')
    for opt in ctx.attr.ghci_opts:
        ghc_flag_exprs.append(_shell_quote(opt))

    src_exprs = [_source_or_runfiles_expr(f) for f in repl_src_files]
    user_script_expr = _runfiles_expr(ctx.file.ghci_script) if ctx.file.ghci_script else '""'
    use_working_dir = "1" if (not repl_src_files and ctx.attr.expose_boot_packages) else "0"

    out_launcher = ctx.actions.declare_file(ctx.label.name)
    launcher_content = """\
#!/usr/bin/env bash
set -euo pipefail

if [ -z "${{RUNFILES_DIR:-}}" ]; then
    if [ -n "${{TEST_SRCDIR:-}}" ] && [ -d "${{TEST_SRCDIR}}" ]; then
        RUNFILES_DIR="${{TEST_SRCDIR}}"
    elif [ -d "$0.runfiles" ]; then
        RUNFILES_DIR="$0.runfiles"
    fi
fi
case "${{RUNFILES_DIR:-}}" in
    "")
        echo "hs_repl: could not locate Bazel runfiles directory for $0" >&2
        exit 1
        ;;
    /*) ;;
    *) RUNFILES_DIR="$(cd "$RUNFILES_DIR" && pwd)" ;;
esac
export RUNFILES_DIR

if [ -n "${{BUILD_WORKSPACE_DIRECTORY:-}}" ] && [ -d "${{BUILD_WORKSPACE_DIRECTORY}}" ]; then
    WS_ROOT="${{BUILD_WORKSPACE_DIRECTORY}}"
else
    WS_ROOT="$RUNFILES_DIR/_main"
fi

GHC_BIN={ghc_expr}
export RULES_HS_REAL_CC={real_cc_expr}
export RULES_HS_FORCE_PIC=1
{cc_extra_setup}

# Handle standalone compiler query flags (--version, --numeric-version, --info, etc.) cleanly.
IS_INFO_QUERY=0
HAS_EVAL_MODE=0
HAS_EXT_ISERV={default_ext_iserv}
for uarg in "$@"; do
    case "$uarg" in
        --version|--numeric-version|--info|--supported-extensions|--supported-languages|--show-options|--print-libdir)
            IS_INFO_QUERY=1
            ;;
        -e|--run)
            HAS_EVAL_MODE=1
            ;;
        -e*)
            HAS_EVAL_MODE=1
            ;;
        -fexternal-interpreter)
            HAS_EXT_ISERV=1
            ;;
    esac
done

if [ "$IS_INFO_QUERY" = "1" ]; then
    exec "$GHC_BIN" "-B"{libdir_expr} {tool_flags_inline} "$@"
fi

REPL_WORK="$(mktemp -d "${{TMPDIR:-/tmp}}/hs_repl.XXXXXX")"
cleanup_repl() {{
    rm -rf "$REPL_WORK"
}}
trap cleanup_repl EXIT
export TMPDIR="$REPL_WORK/tmp"
mkdir -p "$TMPDIR"

BASE_ARGS=(
    {base_flags}
)

if [ "{is_dynamic_ghc}" = "1" ] && [ "$HAS_EXT_ISERV" = "1" ]; then
    BASE_ARGS+=("-dynamic")
fi

SRC_FILES=(
    {src_files}
)

# Build per-session startup .ghci script bringing all interpreted target modules into `*Module` scope.
SESSION_GHCI="$REPL_WORK/session.ghci"
: > "$SESSION_GHCI"

extract_hs_module_name() {{
    local file="$1"
    local lhs_flag=0
    case "$file" in
        *.lhs) lhs_flag=1 ;;
    esac
    awk -v is_lhs="$lhs_flag" '
    BEGIN {{
        in_code = !is_lhs;
        comment_depth = 0;
        expect_mod = 0;
        found = "";
    }}
    {{
        line = $0;
        if (is_lhs) {{
            if (line ~ /^\\\\begin\\{{code\\}}/) {{ in_code = 1; next; }}
            if (line ~ /^\\\\end\\{{code\\}}/) {{ in_code = 0; next; }}
            if (line ~ /^>/) {{
                sub(/^>[ \\t]?/, "", line);
            }} else if (!in_code) {{
                next;
            }}
        }}
        if (comment_depth == 0 && line ~ /^[ \\t]*#/) {{
            next;
        }}
        clean = "";
        i = 1;
        n = length(line);
        while (i <= n) {{
            two = substr(line, i, 2);
            if (comment_depth == 0 && two == "--") {{
                nxt = substr(line, i + 2, 1);
                if (nxt == "" || nxt ~ /[ \\tA-Za-z0-9_]/) {{
                    break;
                }}
            }}
            if (two == "{{-") {{
                comment_depth++;
                i += 2;
                continue;
            }}
            if (comment_depth > 0 && two == "-}}") {{
                comment_depth--;
                i += 2;
                continue;
            }}
            if (comment_depth == 0) {{
                clean = clean substr(line, i, 1);
            }}
            i++;
        }}
        if (clean ~ /^[ \\t]*$/) {{
            next;
        }}
        sub(/^[ \\t]+/, "", clean);
        if (expect_mod) {{
            if (match(clean, /^[A-Za-z][A-Za-z0-9_.\\047]*/)) {{
                found = substr(clean, RSTART, RLENGTH);
            }} else {{
                found = "Main";
            }}
            exit;
        }}
        if (clean == "module") {{
            expect_mod = 1;
            next;
        }}
        if (clean ~ /^module[ \\t(]/) {{
            sub(/^module[ \\t]+/, "", clean);
            if (match(clean, /^[A-Za-z][A-Za-z0-9_.\\047]*/)) {{
                found = substr(clean, RSTART, RLENGTH);
            }} else {{
                found = "Main";
            }}
            exit;
        }} else {{
            found = "Main";
            exit;
        }}
    }}
    END {{
        if (found == "") found = "Main";
        print found;
    }}
    ' "$file"
}}

if [ "${{#SRC_FILES[@]}}" -gt 0 ]; then
    LOAD_LINE=":load"
    MOD_LINE=":module +"
    SEEN_MODS=" "
    for sf in "${{SRC_FILES[@]}}"; do
        escaped_sf="$(printf '%s' "$sf" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g')"
        LOAD_LINE="$LOAD_LINE \\"$escaped_sf\\""
        if [ -f "$sf" ]; then
            mname="$(extract_hs_module_name "$sf")"
            case "$SEEN_MODS" in
                *" $mname "*) ;;
                *)
                    SEEN_MODS="$SEEN_MODS$mname "
                    MOD_LINE="$MOD_LINE *$mname"
                    ;;
            esac
        fi
    done
    printf '%s\\n' "$LOAD_LINE" >> "$SESSION_GHCI"
    if [ "$MOD_LINE" != ":module +" ]; then
        printf '%s\\n' "$MOD_LINE" >> "$SESSION_GHCI"
    fi
fi

STATIC_GHCI={static_ghci_expr}
if [ -s "$STATIC_GHCI" ]; then
    cat "$STATIC_GHCI" >> "$SESSION_GHCI"
fi

USER_GHCI={user_ghci_expr}
if [ -n "$USER_GHCI" ] && [ -f "$USER_GHCI" ]; then
    cat "$USER_GHCI" >> "$SESSION_GHCI"
fi

chmod go-w "$REPL_WORK" "$SESSION_GHCI" 2>/dev/null || true

FINAL_ARGS=()
if [ "$HAS_EVAL_MODE" = "0" ]; then
    FINAL_ARGS+=("--interactive")
fi
FINAL_ARGS+=("${{BASE_ARGS[@]}}")
if [ -s "$SESSION_GHCI" ]; then
    FINAL_ARGS+=("-ghci-script" "$SESSION_GHCI")
fi
FINAL_ARGS+=("$@")

if [ "{use_working_dir}" = "1" ] && [ -n "${{BUILD_WORKING_DIRECTORY:-}}" ] && [ -d "${{BUILD_WORKING_DIRECTORY}}" ]; then
    cd "${{BUILD_WORKING_DIRECTORY}}"
elif [ -d "$WS_ROOT" ]; then
    cd "$WS_ROOT"
fi

set +e
"$GHC_BIN" "${{FINAL_ARGS[@]}}"
EXIT_CODE=$?
exit "$EXIT_CODE"
""".format(
        ghc_expr = _runfiles_expr(hs_tc.ghc),
        libdir_expr = _runfiles_expr(hs_tc.libdir),
        tool_flags_inline = " ".join(_repl_ghc_tool_flag_exprs(hs_tc, cc_tools)),
        real_cc_expr = _execroot_str_to_shell_expr(cc_tools.cc, prefer_ws_root = False),
        cc_extra_setup = _cc_extra_args_shell_lines(cc_tools),
        default_ext_iserv = "1" if ("-fexternal-interpreter" in (inherited_ghc_opts + ctx.attr.ghc_opts + ctx.attr.ghci_opts)) else "0",
        is_dynamic_ghc = "1" if hs_tc.is_dynamic_ghc else "0",
        base_flags = "\n    ".join(ghc_flag_exprs),
        src_files = "\n    ".join(src_exprs),
        static_ghci_expr = _runfiles_expr(out_ghci_script),
        user_ghci_expr = user_script_expr,
        use_working_dir = use_working_dir,
    )

    ctx.actions.write(
        output = out_launcher,
        content = launcher_content,
        is_executable = True,
    )

    direct_runfiles = (
        list(all_hs_srcs) +
        list(cabal_macros_files) +
        list(compile_data) +
        list(ctx.files.data) +
        list(ext_pkg_dbs) +
        [hs_tc.cc_wrapper, out_ghci_script, out_launcher]
    )
    if ctx.file.ghci_script:
        direct_runfiles.append(ctx.file.ghci_script)
    if cbits_so:
        direct_runfiles.append(cbits_so)

    transitive_rf = [
        hs_tc.all_files,
        dep_info.pkg_dbs,
        dep_info.hs_libs,
        cc_tools.all_files,
    ] + header_depsets

    runfiles = ctx.runfiles(
        files = direct_runfiles,
        transitive_files = depset(transitive = transitive_rf),
    ).merge_all([
        dep[DefaultInfo].default_runfiles
        for dep in all_dep_targets + ctx.attr.cc_deps + ctx.attr.data
    ])

    return [
        DefaultInfo(
            executable = out_launcher,
            files = depset([out_launcher]),
            runfiles = runfiles,
        ),
        HsReplInfo(
            executable = out_launcher,
            ghci_script = out_ghci_script,
            interpreted_srcs = depset(repl_src_files),
            package_ids = depset(direct_unit_ids),
        ),
    ]

hs_repl = rule(
    implementation = _hs_repl_impl,
    doc = "Launches a hermetic interactive GHCi session (or `-e` expression evaluator) preloaded with target sources, packages, C/C++ FFI, and runfiles.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".hs", ".lhs", ".hs-boot", ".lhs-boot"],
            default = [],
            doc = "Optional Haskell source files loaded directly into GHCi bytecode.",
        ),
        "deps": attr.label_list(
            providers = [[HsPackageInfo], [HsDocSourceInfo], [CcInfo]],
            default = [],
            doc = "Haskell libraries, executables, tests, boot/Hackage packages, or CcInfo targets available in the REPL.",
        ),
        "compiled_deps": attr.label_list(
            providers = [[HsPackageInfo], [CcInfo]],
            default = [],
            doc = "Haskell library targets always loaded as precompiled packages (-package-id) rather than from source.",
        ),
        "interpret_deps": attr.bool(
            default = True,
            doc = "When True, in-workspace targets in deps are loaded from source into GHCi bytecode (supporting :reload, :break, and internal bindings); external @hs_boot/@hackage packages always load precompiled.",
        ),
        "expose_boot_packages": attr.bool(
            default = False,
            doc = "When True, omits -hide-all-packages so all GHC boot packages are visible without listing each in deps (used by @rules_hs//tools/ghci).",
        ),
        "cc_deps": attr.label_list(
            providers = [CcInfo],
            default = [],
            doc = "Native C/C++ libraries linked into a shared stub for FFI calls inside GHCi.",
        ),
        "c_sources": attr.label_list(
            allow_files = [".c", ".cc", ".cpp", ".S", ".s"],
            default = [],
            doc = "Inline C/C++/assembly files compiled and linked into a shared stub for FFI calls inside GHCi.",
        ),
        "hdrs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "C/C++ header files visible to c_sources, CPP, and CApiFFI inside GHCi.",
        ),
        "include_dirs": attr.string_list(
            default = [],
            doc = "Package-relative C header search directories (-I).",
        ),
        "hs_source_dirs": attr.string_list(
            default = [],
            doc = "Package-relative Haskell import root directories (-i) for srcs.",
        ),
        "default_language": attr.string(
            default = "",
            doc = "Haskell language edition (-X<lang>); inherits from interpreted deps when empty, or defaults to GHC2021.",
        ),
        "default_extensions": attr.string_list(
            default = [],
            doc = "GHC language extensions enabled for interpreted modules (-X<ext>).",
        ),
        "ghc_opts": attr.string_list(
            default = [],
            doc = "Additional GHC compiler flags passed to the interpreter.",
        ),
        "ghci_opts": attr.string_list(
            default = [],
            doc = "Additional GHCi-specific flags appended to the interpreter invocation.",
        ),
        "ghci_commands": attr.string_list(
            default = [],
            doc = "Startup GHCi commands or imports executed automatically before the prompt appears.",
        ),
        "ghci_script": attr.label(
            allow_single_file = True,
            doc = "Optional .ghci script file executed at session startup.",
        ),
        "allow_dot_ghci": attr.bool(
            default = False,
            doc = "When False (default), passes -ignore-dot-ghci for hermetic sessions; set True to read user .ghci files.",
        ),
        "cpp_options": attr.string_list(
            default = [],
            doc = "C Preprocessor flags (-optP) for CPP-enabled Haskell sources.",
        ),
        "cc_options": attr.string_list(
            default = [],
            doc = "Native C/C++ compiler flags for c_sources and CApiFFI stubs.",
        ),
        "data": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Runtime data files staged into Bazel runfiles (accessible via RUNFILES_DIR).",
        ),
        "_rt_shims": attr.label(
            default = Label("//hs/private:rt_shims"),
            providers = [CcInfo],
        ),
    },
    executable = True,
    toolchains = [TOOLCHAIN_TYPE] + use_cc_toolchain(),
    fragments = ["cpp"],
    provides = [HsReplInfo],
)

# ==============================================================================
# hs_runghc (standalone script-interpreter launcher for @rules_hs//tools/ghci:runghc)
# ==============================================================================

def _hs_runghc_impl(ctx):
    hs_tc = get_hs_toolchain(ctx)
    cc_tools = resolve_cc_tools(ctx)

    ghc_arg_exprs = []
    for flag_expr in _repl_ghc_tool_flag_exprs(hs_tc, cc_tools):
        ghc_arg_exprs.append('"--ghc-arg="' + flag_expr)
    if not ctx.attr.allow_dot_ghci:
        ghc_arg_exprs.append('"--ghc-arg=-ignore-dot-ghci"')

    out_launcher = ctx.actions.declare_file(ctx.label.name)
    content = """\
#!/usr/bin/env bash
set -euo pipefail

if [ -z "${{RUNFILES_DIR:-}}" ]; then
    if [ -n "${{TEST_SRCDIR:-}}" ] && [ -d "${{TEST_SRCDIR}}" ]; then
        RUNFILES_DIR="${{TEST_SRCDIR}}"
    elif [ -d "$0.runfiles" ]; then
        RUNFILES_DIR="$0.runfiles"
    fi
fi
case "${{RUNFILES_DIR:-}}" in
    "")
        echo "hs_runghc: could not locate Bazel runfiles directory for $0" >&2
        exit 1
        ;;
    /*) ;;
    *) RUNFILES_DIR="$(cd "$RUNFILES_DIR" && pwd)" ;;
esac
export RUNFILES_DIR

RUNGHC_BIN={runghc_expr}
GHC_BIN={ghc_expr}
export RULES_HS_REAL_CC={real_cc_expr}
export RULES_HS_FORCE_PIC=1
{cc_extra_setup}

for uarg in "$@"; do
    case "$uarg" in
        --version|--help)
            exec "$RUNGHC_BIN" "$uarg"
            ;;
    esac
done

WORK_ROOT="$(mktemp -d "${{TMPDIR:-/tmp}}/hs_runghc.XXXXXX")"
cleanup_runghc() {{
    rm -rf "$WORK_ROOT"
}}
trap cleanup_runghc EXIT
export TMPDIR="$WORK_ROOT/tmp"
mkdir -p "$TMPDIR"

GHC_ARGS=(
    {ghc_args}
)

if [ -n "${{BUILD_WORKING_DIRECTORY:-}}" ] && [ -d "${{BUILD_WORKING_DIRECTORY}}" ]; then
    cd "${{BUILD_WORKING_DIRECTORY}}"
elif [ -n "${{BUILD_WORKSPACE_DIRECTORY:-}}" ] && [ -d "${{BUILD_WORKSPACE_DIRECTORY}}" ]; then
    cd "${{BUILD_WORKSPACE_DIRECTORY}}"
elif [ -d "$RUNFILES_DIR/_main" ]; then
    cd "$RUNFILES_DIR/_main"
fi

set +e
"$RUNGHC_BIN" -f "$GHC_BIN" "${{GHC_ARGS[@]}}" "$@"
EXIT_CODE=$?
exit "$EXIT_CODE"
""".format(
        runghc_expr = _runfiles_expr(hs_tc.runghc),
        ghc_expr = _runfiles_expr(hs_tc.ghc),
        real_cc_expr = _execroot_str_to_shell_expr(cc_tools.cc, prefer_ws_root = False),
        cc_extra_setup = _cc_extra_args_shell_lines(cc_tools),
        ghc_args = "\n    ".join(ghc_arg_exprs),
    )

    ctx.actions.write(
        output = out_launcher,
        content = content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [hs_tc.cc_wrapper, out_launcher],
        transitive_files = depset(transitive = [hs_tc.all_files, cc_tools.all_files]),
    )

    return [
        DefaultInfo(
            executable = out_launcher,
            files = depset([out_launcher]),
            runfiles = runfiles,
        ),
    ]

hs_runghc = rule(
    implementation = _hs_runghc_impl,
    doc = "Hermetic `runghc` script-interpreter launcher wired to the active GHC and C/C++ toolchains.",
    attrs = {
        "allow_dot_ghci": attr.bool(default = False),
    },
    executable = True,
    toolchains = [TOOLCHAIN_TYPE] + use_cc_toolchain(),
    fragments = ["cpp"],
)
