"""Bzlmod module extension and repository rules for Hackage dependencies.

Reads a deterministic ``hackage.lock.json`` lockfile (generated offline by
``//tools/lock``) using pure Starlark ``json.decode`` with zero host
``cabal``, ``stack``, or ``python`` tools at build time.

Creates:
  * One hub repository (default ``@hackage``) exposing uniform targets for
    both GHC boot libraries (via ``hs_toolchain_library``) and pinned Hackage
    packages (via ``alias``).
  * One lazy per-package repository (``@<hub>__<sanitized_pkg>``) per locked
    Hackage package, fetched only when referenced in the build graph.
"""

load("//haskell/private:cabal_codegen.bzl", "alex_bootstrap_repo", "happy_bootstrap_repo")

_PLATFORM_CONFIGS = [
    ("linux_x86_64", "_linux_x86_64", ["@platforms//os:linux", "@platforms//cpu:x86_64"]),
    ("linux_arm64", "_linux_arm64", ["@platforms//os:linux", "@platforms//cpu:arm64"]),
    ("macos_arm64", "_macos_arm64", ["@platforms//os:macos", "@platforms//cpu:arm64"]),
    ("macos_x86_64", "_macos_x86_64", ["@platforms//os:macos", "@platforms//cpu:x86_64"]),
]

_HDR_GLOB_PATTERNS = [
    "**/*.h",
    "**/*.hpp",
    "**/*.inc",
    "cbits/**/*.c",
    "cbits-extra/**/*.c",
    "cbits-unix/**/*.c",
    "cbits-apple/**/*.c",
    "include/**/*.c",
    "src/cbits/**/*.c",
]

_HDR_GLOB_EXCLUDES = [
    "Setup.hs",
    "Setup.lhs",
    "**/*.hs-boot",
    "**/*.hsc",
    "**/*.in",
    "**/*.lhs",
    "**/*.lhs-boot",
    "app/**",
    "bench/**",
    "benchmarks/**",
    "bin/**",
    "example/**",
    "examples/**",
    "test/**",
    "tests/**",
]

def _sanitize_repo_suffix(pkg_name):
    return pkg_name.replace("-", "_").replace(".", "_")

def _pkg_repo_name(hub_name, pkg_name):
    return "{}__{}".format(hub_name, _sanitize_repo_suffix(pkg_name))

def _format_str_list(items, indent = "    "):
    if not items:
        return "[]"
    lines = ["["]
    for item in items:
        lines.append("{}{},".format(indent + "    ", repr(item)))
    lines.append("{}]".format(indent))
    return "\n".join(lines)

def _format_selectable_list(base_items, select_map, indent = "    "):
    """Formats a list expression, appending select({...}) only when non-empty."""
    has_delta = False
    if select_map:
        for plat_key, _, _ in _PLATFORM_CONFIGS:
            if select_map.get(plat_key):
                has_delta = True
                break

    if not has_delta:
        return _format_str_list(base_items, indent = indent)

    sel_lines = ["select({"]
    for plat_key, cfg_name, _ in _PLATFORM_CONFIGS:
        vals = select_map.get(plat_key, [])
        sel_lines.append(
            '{indent}    ":{cfg}": {vals},'.format(
                indent = indent,
                cfg = cfg_name,
                vals = _format_str_list(vals, indent = indent + "    "),
            ),
        )
    sel_lines.append('{indent}    "//conditions:default": [],'.format(indent = indent))
    sel_lines.append("{indent}}})".format(indent = indent))
    sel_expr = "\n".join(sel_lines)

    if not base_items:
        return sel_expr
    return "{} + {}".format(_format_str_list(base_items, indent = indent), sel_expr)

def _find_module_files(repository_ctx, hs_source_dirs, modules):
    """Resolves Haskell module names to on-disk source paths under hs_source_dirs.

    Only matches files for the explicit active module list, avoiding Windows
    .hsc files, test suites, benchmarks, and Setup.hs. Also detects Alex (.x)
    and Happy (.y / .ly) grammar sources so build-time preprocessors can run.
    """
    hs_srcs = []
    hsc_srcs = []
    alex_srcs = []
    happy_srcs = []
    seen_hs = {}
    seen_hsc = {}
    seen_alex = {}
    seen_happy = {}
    search_dirs = hs_source_dirs if hs_source_dirs else ["."]

    for mod in modules:
        mod_rel = mod.replace(".", "/")
        found_primary = False
        for raw_dir in search_dirs:
            d = raw_dir.strip("/")
            prefix = "" if (d == "" or d == ".") else (d + "/")
            base_path = prefix + mod_rel

            if not found_primary:
                hsc_cand = base_path + ".hsc"
                hs_cand = base_path + ".hs"
                lhs_cand = base_path + ".lhs"
                alex_cand = base_path + ".x"
                happy_cand = base_path + ".y"
                lhappy_cand = base_path + ".ly"
                if repository_ctx.path(hsc_cand).exists:
                    if hsc_cand not in seen_hsc:
                        seen_hsc[hsc_cand] = True
                        hsc_srcs.append(hsc_cand)
                    found_primary = True
                elif repository_ctx.path(hs_cand).exists:
                    if hs_cand not in seen_hs:
                        seen_hs[hs_cand] = True
                        hs_srcs.append(hs_cand)
                    found_primary = True
                elif repository_ctx.path(lhs_cand).exists:
                    if lhs_cand not in seen_hs:
                        seen_hs[lhs_cand] = True
                        hs_srcs.append(lhs_cand)
                    found_primary = True
                elif repository_ctx.path(alex_cand).exists:
                    if alex_cand not in seen_alex:
                        seen_alex[alex_cand] = True
                        alex_srcs.append((alex_cand, base_path + ".hs"))
                    found_primary = True
                elif repository_ctx.path(happy_cand).exists:
                    if happy_cand not in seen_happy:
                        seen_happy[happy_cand] = True
                        happy_srcs.append((happy_cand, base_path + ".hs"))
                    found_primary = True
                elif repository_ctx.path(lhappy_cand).exists:
                    if lhappy_cand not in seen_happy:
                        seen_happy[lhappy_cand] = True
                        happy_srcs.append((lhappy_cand, base_path + ".hs"))
                    found_primary = True

            # Always check for companion .hs-boot / .lhs-boot files (e.g. cborg, tls).
            for boot_ext in (".hs-boot", ".lhs-boot"):
                boot_cand = base_path + boot_ext
                if repository_ctx.path(boot_cand).exists and boot_cand not in seen_hs:
                    seen_hs[boot_cand] = True
                    hs_srcs.append(boot_cand)

    return sorted(hs_srcs), sorted(hsc_srcs), sorted(alex_srcs), sorted(happy_srcs)

def _collect_field_select(select_raw, field_name):
    out = {}
    for plat_key, _, _ in _PLATFORM_CONFIGS:
        delta = select_raw.get(plat_key, {})
        vals = delta.get(field_name, [])
        if vals:
            out[plat_key] = vals
    return out

def _format_dep_labels(hub_name, deps, sublib_deps):
    labels = ["@{}//:{}".format(hub_name, d) for d in deps]
    for s in sublib_deps:
        labels.append(":{}".format(s))
    return sorted(labels)

def _emit_component_rule(
        repository_ctx,
        hub_name,
        pkg_name,
        component_name,
        version,
        comp,
        build_type,
        configure_script,
        configure_srcs,
        configure_outputs,
        overrides):
    """Renders one hs_cabal_library(...) rule block."""
    target_name = component_name if component_name else pkg_name
    select_raw = comp.get("select", {})

    base_src_dirs = comp.get("hs_source_dirs", ["."])
    base_exposed = comp.get("exposed_modules", [])
    base_other = comp.get("other_modules", [])
    base_hs, base_hsc, base_alex, base_happy = _find_module_files(
        repository_ctx,
        base_src_dirs,
        base_exposed + base_other,
    )

    codegen_blocks = []
    for idx in range(len(base_alex)):
        x_src, hs_out = base_alex[idx]
        gen_name = "{}_alex_{}".format(_sanitize_repo_suffix(target_name), idx)
        codegen_blocks.append(
            """\
hs_alex_gen(
    name = {name},
    src = {src},
    out = {out},
    alex = "@{hub}__bootstrap_alex//:alex",
    alex_data = ["@{hub}__bootstrap_alex//:data_files"],
)""".format(
                name = repr(gen_name),
                src = repr(x_src),
                out = repr(hs_out),
                hub = hub_name,
            ),
        )
        base_hs.append(":" + gen_name)

    for idx in range(len(base_happy)):
        y_src, hs_out = base_happy[idx]
        gen_name = "{}_happy_{}".format(_sanitize_repo_suffix(target_name), idx)
        codegen_blocks.append(
            """\
hs_happy_gen(
    name = {name},
    src = {src},
    out = {out},
    happy = "@{hub}__bootstrap_happy//:happy",
    happy_data = ["@{hub}__bootstrap_happy//:data_files"],
)""".format(
                name = repr(gen_name),
                src = repr(y_src),
                out = repr(hs_out),
                hub = hub_name,
            ),
        )
        base_hs.append(":" + gen_name)

    hs_select = {}
    hsc_select = {}
    seen_alex = {base_alex[i][0]: ":" + "{}_alex_{}".format(_sanitize_repo_suffix(target_name), i) for i in range(len(base_alex))}
    seen_happy = {base_happy[i][0]: ":" + "{}_happy_{}".format(_sanitize_repo_suffix(target_name), i) for i in range(len(base_happy))}
    next_alex_idx = len(base_alex)
    next_happy_idx = len(base_happy)
    if select_raw:
        base_hs_set = {f: True for f in base_hs}
        base_hsc_set = {f: True for f in base_hsc}
        for plat_key, _, _ in _PLATFORM_CONFIGS:
            delta = select_raw.get(plat_key, {})
            plat_mods = delta.get("exposed_modules", []) + delta.get("other_modules", [])
            plat_dirs = delta.get("hs_source_dirs", [])
            if plat_mods or plat_dirs:
                p_hs, p_hsc, p_alex, p_happy = _find_module_files(
                    repository_ctx,
                    base_src_dirs + plat_dirs,
                    base_exposed + base_other + plat_mods,
                )
                for x_src, hs_out in p_alex:
                    if x_src not in seen_alex:
                        gen_name = "{}_alex_{}".format(_sanitize_repo_suffix(target_name), next_alex_idx)
                        next_alex_idx += 1
                        seen_alex[x_src] = ":" + gen_name
                        codegen_blocks.append(
                            """\
hs_alex_gen(
    name = {name},
    src = {src},
    out = {out},
    alex = "@{hub}__bootstrap_alex//:alex",
    alex_data = ["@{hub}__bootstrap_alex//:data_files"],
)""".format(
                                name = repr(gen_name),
                                src = repr(x_src),
                                out = repr(hs_out),
                                hub = hub_name,
                            ),
                        )
                    p_hs.append(seen_alex[x_src])
                for y_src, hs_out in p_happy:
                    if y_src not in seen_happy:
                        gen_name = "{}_happy_{}".format(_sanitize_repo_suffix(target_name), next_happy_idx)
                        next_happy_idx += 1
                        seen_happy[y_src] = ":" + gen_name
                        codegen_blocks.append(
                            """\
hs_happy_gen(
    name = {name},
    src = {src},
    out = {out},
    happy = "@{hub}__bootstrap_happy//:happy",
    happy_data = ["@{hub}__bootstrap_happy//:data_files"],
)""".format(
                                name = repr(gen_name),
                                src = repr(y_src),
                                out = repr(hs_out),
                                hub = hub_name,
                            ),
                        )
                    p_hs.append(seen_happy[y_src])
                extra_hs = [f for f in p_hs if f not in base_hs_set]
                extra_hsc = [f for f in p_hsc if f not in base_hsc_set]
                if extra_hs:
                    hs_select[plat_key] = extra_hs
                if extra_hsc:
                    hsc_select[plat_key] = extra_hsc

    # Collect all c_sources across platforms so hdrs glob excludes compiled .c files
    # while retaining textual #include'd .c helpers (e.g. crypton's cbits/*_impl.c)
    # and extensionless CPP include files inside include_dirs (e.g. vector's
    # internal/unbox-tuple-instances).
    base_c_sources = comp.get("c_sources", [])
    c_sources_select = _collect_field_select(select_raw, "c_sources")
    all_compiled_files_map = {c: True for c in base_c_sources}
    for vals in c_sources_select.values():
        for c in vals:
            all_compiled_files_map[c] = True
    for hs_f in base_hs:
        if not hs_f.startswith(":"):
            all_compiled_files_map[hs_f] = True
    for vals in hs_select.values():
        for hs_f in vals:
            if not hs_f.startswith(":"):
                all_compiled_files_map[hs_f] = True
    hdr_excludes = sorted(_HDR_GLOB_EXCLUDES + list(all_compiled_files_map.keys()))

    inc_base = comp.get("include_dirs", [])
    inc_sel = _collect_field_select(select_raw, "include_dirs")
    hdr_patterns_map = {p: True for p in _HDR_GLOB_PATTERNS}
    all_src_dirs = list(base_src_dirs)
    for vals in _collect_field_select(select_raw, "hs_source_dirs").values():
        all_src_dirs.extend(vals)
    for raw_sdir in all_src_dirs:
        norm_sdir = raw_sdir.strip("/")
        if norm_sdir and norm_sdir != ".":
            hdr_patterns_map[norm_sdir + "/**/*.hs"] = True
            hdr_patterns_map[norm_sdir + "/**/*.h"] = True
            hdr_patterns_map[norm_sdir + "/**/*.inc"] = True
        else:
            hdr_patterns_map["**/*.hs"] = True
    all_inc_dirs = list(inc_base)
    for vals in inc_sel.values():
        all_inc_dirs.extend(vals)
    for raw_inc_dir in all_inc_dirs:
        norm_dir = raw_inc_dir.strip("/")
        if norm_dir and norm_dir != ".":
            hdr_patterns_map[norm_dir + "/**"] = True
    hdr_patterns = sorted(hdr_patterns_map.keys())

    # Dependencies (common + per-platform)
    base_deps = _format_dep_labels(
        hub_name,
        comp.get("deps", []),
        comp.get("sublib_deps", []),
    )
    deps_select = {}
    if select_raw:
        for plat_key, _, _ in _PLATFORM_CONFIGS:
            delta = select_raw.get(plat_key, {})
            p_deps = _format_dep_labels(
                hub_name,
                delta.get("deps", []),
                delta.get("sublib_deps", []),
            )
            if p_deps:
                deps_select[plat_key] = p_deps

    # Apply package-level overrides to main library and sublibraries.
    is_main = (component_name == "")
    extra_ghc_opts = overrides.get("extra_ghc_opts", [])
    extra_cpp_options = overrides.get("extra_cpp_options", [])
    extra_cc_options = overrides.get("extra_cc_options", [])
    extra_cc_deps = overrides.get("extra_cc_deps", [])
    configure_args = overrides.get("configure_args", []) if is_main else []

    ghc_opts_base = comp.get("ghc_opts", []) + extra_ghc_opts
    cpp_opts_base = comp.get("cpp_options", []) + extra_cpp_options
    cc_opts_base = comp.get("cc_options", []) + extra_cc_options

    lines = [
        "hs_cabal_library(",
        "    name = {},".format(repr(target_name)),
        "    package_name = {},".format(repr(pkg_name)),
    ]
    if component_name:
        lines.append("    component_name = {},".format(repr(component_name)))
    lines.append("    version = {},".format(repr(version)))
    lines.append("    srcs = {},".format(_format_selectable_list(base_hs, hs_select)))

    if base_hsc or hsc_select:
        lines.append("    hsc_srcs = {},".format(_format_selectable_list(base_hsc, hsc_select)))
    if base_c_sources or c_sources_select:
        lines.append("    c_sources = {},".format(_format_selectable_list(base_c_sources, c_sources_select)))

    lines.append(
        "    hdrs = glob(\n        {},\n        exclude = {},\n        allow_empty = True,\n    ),".format(
            _format_str_list(hdr_patterns, indent = "        "),
            _format_str_list(hdr_excludes, indent = "        "),
        ),
    )

    inst_base = comp.get("install_includes", [])
    inst_sel = _collect_field_select(select_raw, "install_includes")
    if inst_base or inst_sel:
        lines.append("    install_includes = {},".format(_format_selectable_list(inst_base, inst_sel)))

    if inc_base or inc_sel:
        lines.append("    include_dirs = {},".format(_format_selectable_list(inc_base, inc_sel)))

    src_dirs_sel = _collect_field_select(select_raw, "hs_source_dirs")
    lines.append("    hs_source_dirs = {},".format(_format_selectable_list(base_src_dirs, src_dirs_sel)))

    exp_sel = _collect_field_select(select_raw, "exposed_modules")
    lines.append("    exposed_modules = {},".format(_format_selectable_list(base_exposed, exp_sel)))

    oth_sel = _collect_field_select(select_raw, "other_modules")
    if base_other or oth_sel:
        lines.append("    other_modules = {},".format(_format_selectable_list(base_other, oth_sel)))

    reex_base = comp.get("reexported_modules", [])
    reex_sel = _collect_field_select(select_raw, "reexported_modules")
    if reex_base or reex_sel:
        lines.append("    reexported_modules = {},".format(_format_selectable_list(reex_base, reex_sel)))

    lines.append("    default_language = {},".format(repr(comp.get("default_language", "Haskell98"))))

    exts_base = comp.get("default_extensions", [])
    exts_sel = _collect_field_select(select_raw, "default_extensions")
    if exts_base or exts_sel:
        lines.append("    default_extensions = {},".format(_format_selectable_list(exts_base, exts_sel)))

    ghc_sel = _collect_field_select(select_raw, "ghc_opts")
    if ghc_opts_base or ghc_sel:
        lines.append("    ghc_opts = {},".format(_format_selectable_list(ghc_opts_base, ghc_sel)))

    cpp_sel = _collect_field_select(select_raw, "cpp_options")
    if cpp_opts_base or cpp_sel:
        lines.append("    cpp_options = {},".format(_format_selectable_list(cpp_opts_base, cpp_sel)))

    cc_sel = _collect_field_select(select_raw, "cc_options")
    if cc_opts_base or cc_sel:
        lines.append("    cc_options = {},".format(_format_selectable_list(cc_opts_base, cc_sel)))

    elib_base = comp.get("extra_libraries", [])
    elib_sel = _collect_field_select(select_raw, "extra_libraries")
    if (elib_base or elib_sel) and not extra_cc_deps:
        lines.append("    extra_libraries = {},".format(_format_selectable_list(elib_base, elib_sel)))

    eff_build_type = build_type if is_main else "Simple"
    if eff_build_type != "Simple":
        lines.append("    build_type = {},".format(repr(eff_build_type)))
    if is_main and eff_build_type == "Configure" and configure_script:
        lines.append("    configure_script = {},".format(repr(configure_script)))
        if configure_srcs:
            lines.append("    configure_srcs = {},".format(_format_str_list(configure_srcs)))
        if configure_outputs:
            lines.append("    configure_outputs = {},".format(_format_str_list(configure_outputs)))
        if configure_args:
            lines.append("    configure_args = {},".format(_format_str_list(configure_args)))

    if comp.get("generate_paths_module", False):
        lines.append("    generate_paths_module = True,")

    lines.append("    deps = {},".format(_format_selectable_list(base_deps, deps_select)))

    if extra_cc_deps:
        lines.append("    extra_cc_deps = resolve_override_labels({}),".format(_format_str_list(extra_cc_deps)))

    raw_dep_names = list(comp.get("deps", []))
    for plat_key, _, _ in _PLATFORM_CONFIGS:
        raw_dep_names.extend(select_raw.get(plat_key, {}).get("deps", []))
    if "file-embed" in raw_dep_names or "template-haskell" in raw_dep_names:
        data_excludes = sorted(_HDR_GLOB_EXCLUDES + [
            "BUILD",
            "BUILD.bazel",
            "REPO.bazel",
            "WORKSPACE",
            "WORKSPACE.bazel",
            "**/*.c",
            "**/*.h",
            "**/*.hpp",
        ])
        lines.append(
            "    data = glob(\n        [\"**/.*\", \"**\"],\n        exclude = {},\n        allow_empty = True,\n    ),".format(
                _format_str_list(data_excludes, indent = "        "),
            ),
        )

    lines.append(")")
    has_alex = next_alex_idx > 0
    has_happy = next_happy_idx > 0
    full_block = "\n\n".join(codegen_blocks + ["\n".join(lines)])
    return full_block, has_alex, has_happy

def _component_uses_select(comp):
    select_raw = comp.get("select", {})
    if not select_raw:
        return False
    for plat_key, _, _ in _PLATFORM_CONFIGS:
        delta = select_raw.get(plat_key, {})
        for v in delta.values():
            if v:
                return True
    return False

def _hackage_package_repo_impl(repository_ctx):
    spec = json.decode(repository_ctx.attr.spec_json)
    overrides = json.decode(repository_ctx.attr.overrides_json)
    hub_name = repository_ctx.attr.hub_name
    pkg_name = repository_ctx.attr.package_name

    repository_ctx.download_and_extract(
        url = spec["url"],
        sha256 = spec["sha256"],
        stripPrefix = spec.get("strip_prefix", "{}-{}".format(pkg_name, spec["version"])),
    )

    build_type = spec.get("build_type", "Simple")
    configure_script = spec.get("configure_script", "")
    configure_srcs = spec.get("configure_srcs", [])
    configure_outputs = spec.get("configure_outputs", [])

    # Hackage tarballs (e.g. network, old-time) often ship configure / config.sub /
    # config.guess with mode 0644; rewrite them executable in pure Starlark.
    if build_type == "Configure":
        for helper_script in [configure_script, "config.guess", "config.sub", "install-sh"]:
            if helper_script and repository_ctx.path(helper_script).exists:
                repository_ctx.file(
                    helper_script,
                    content = repository_ctx.read(helper_script),
                    executable = True,
                )
    main_lib = spec.get("library", None)
    sublibs = spec.get("sublibraries", {})

    needs_select = False
    if main_lib and _component_uses_select(main_lib):
        needs_select = True
    for sub_comp in sublibs.values():
        if _component_uses_select(sub_comp):
            needs_select = True

    sections = [
        'package(default_visibility = ["//visibility:public"])',
    ]

    if needs_select:
        sections.append("")
        for _, cfg_name, constraints in _PLATFORM_CONFIGS:
            sections.append(
                "config_setting(\n    name = {},\n    constraint_values = {},\n)".format(
                    repr(cfg_name),
                    _format_str_list(constraints),
                ),
            )

    used_alex = False
    used_happy = False

    # Emit internal sublibraries first so the main library can depend on ":<sublib>".
    for sub_name in sorted(sublibs.keys()):
        sections.append("")
        blk, ha, hh = _emit_component_rule(
            repository_ctx = repository_ctx,
            hub_name = hub_name,
            pkg_name = pkg_name,
            component_name = sub_name,
            version = spec["version"],
            comp = sublibs[sub_name],
            build_type = "Simple",
            configure_script = "",
            configure_srcs = [],
            configure_outputs = [],
            overrides = overrides,
        )
        used_alex = used_alex or ha
        used_happy = used_happy or hh
        sections.append(blk)

    if main_lib != None:
        sections.append("")
        blk, ha, hh = _emit_component_rule(
            repository_ctx = repository_ctx,
            hub_name = hub_name,
            pkg_name = pkg_name,
            component_name = "",
            version = spec["version"],
            comp = main_lib,
            build_type = build_type,
            configure_script = configure_script,
            configure_srcs = configure_srcs,
            configure_outputs = configure_outputs,
            overrides = overrides,
        )
        used_alex = used_alex or ha
        used_happy = used_happy or hh
        sections.append(blk)

    loads = ['load("@rules_haskell//haskell:defs.bzl", "hs_cabal_library")']
    if overrides.get("extra_cc_deps", []):
        loads.append('load("@rules_haskell//haskell/private:cabal_library.bzl", "resolve_override_labels")')
    codegen_syms = []
    if used_alex:
        codegen_syms.append('"hs_alex_gen"')
    if used_happy:
        codegen_syms.append('"hs_happy_gen"')
    if codegen_syms:
        loads.append('load("@rules_haskell//haskell/private:cabal_codegen.bzl", {})'.format(", ".join(codegen_syms)))

    repository_ctx.file("BUILD.bazel", "\n".join(loads + [""] + sections) + "\n")

_hackage_package_repo = repository_rule(
    implementation = _hackage_package_repo_impl,
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "package_name": attr.string(mandatory = True),
        "spec_json": attr.string(mandatory = True),
        "overrides_json": attr.string(default = "{}"),
    },
    doc = "Downloads a single pinned Hackage package tarball and generates its BUILD.bazel.",
)

def _hackage_hub_repo_impl(repository_ctx):
    hub_name = repository_ctx.attr.hub_name
    boot_pkgs = json.decode(repository_ctx.attr.boot_packages_json)
    pkg_names = repository_ctx.attr.package_names
    main_pkg_names = repository_ctx.attr.main_package_names
    sublib_entries = json.decode(repository_ctx.attr.sublibraries_json)

    pkg_set = {p: True for p in pkg_names}

    sections = [
        'load("@rules_haskell//haskell:defs.bzl", "hs_toolchain_library")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
        "# GHC boot packages resolved via the active hs_toolchain.",
    ]

    for boot_pkg in sorted(boot_pkgs.keys()):
        if boot_pkg in pkg_set:
            continue
        sections.append(
            "hs_toolchain_library(\n    name = {n},\n    package_name = {n},\n)".format(
                n = repr(boot_pkg),
            ),
        )

    sections.append("")
    sections.append("# Pinned Hackage packages (lazy per-package repositories).")
    for pkg_name in sorted(main_pkg_names):
        repo = _pkg_repo_name(hub_name, pkg_name)
        sections.append(
            "alias(\n    name = {},\n    actual = {},\n)".format(
                repr(pkg_name),
                repr("@{}//:{}".format(repo, pkg_name)),
            ),
        )

    if sublib_entries:
        sections.append("")
        sections.append("# Internal and public Cabal sublibraries exposed for explicit reference.")
        for entry in sorted(sublib_entries):
            pkg_name, sub_name = entry[0], entry[1]
            repo = _pkg_repo_name(hub_name, pkg_name)
            alias_name = "{}__{}".format(pkg_name, sub_name)
            sections.append(
                "alias(\n    name = {},\n    actual = {},\n)".format(
                    repr(alias_name),
                    repr("@{}//:{}".format(repo, sub_name)),
                ),
            )

    repository_ctx.file("BUILD.bazel", "\n".join(sections) + "\n")

_hackage_hub_repo = repository_rule(
    implementation = _hackage_hub_repo_impl,
    attrs = {
        "hub_name": attr.string(mandatory = True),
        "boot_packages_json": attr.string(mandatory = True),
        "package_names": attr.string_list(mandatory = True),
        "main_package_names": attr.string_list(mandatory = True),
        "sublibraries_json": attr.string(default = "[]"),
    },
    doc = "Hub repository exposing uniform targets for GHC boot and pinned Hackage packages.",
)

def _merge_override(existing, tag):
    merged = {
        "extra_cc_deps": list(existing.get("extra_cc_deps", [])),
        "extra_ghc_opts": list(existing.get("extra_ghc_opts", [])),
        "extra_cpp_options": list(existing.get("extra_cpp_options", [])),
        "extra_cc_options": list(existing.get("extra_cc_options", [])),
        "configure_args": list(existing.get("configure_args", [])),
    }
    for lbl in tag.extra_cc_deps:
        s = str(lbl)
        if s not in merged["extra_cc_deps"]:
            merged["extra_cc_deps"].append(s)
    merged["extra_ghc_opts"].extend(tag.extra_ghc_opts)
    merged["extra_cpp_options"].extend(tag.extra_cpp_options)
    merged["extra_cc_options"].extend(tag.extra_cc_options)
    merged["configure_args"].extend(tag.configure_args)
    return merged

def _hackage_impl(module_ctx):
    hubs = {}
    overrides = {}

    for mod in module_ctx.modules:
        for ov in mod.tags.override:
            key = (ov.hub, ov.package)
            overrides[key] = _merge_override(overrides.get(key, {}), ov)

        for fl in mod.tags.from_lock:
            hub_name = fl.name
            if hub_name in hubs and not mod.is_root:
                continue
            hubs[hub_name] = fl.lockfile

    for hub_name in sorted(hubs.keys()):
        lock_label = hubs[hub_name]
        lock_data = json.decode(module_ctx.read(lock_label))

        schema_ver = lock_data.get("schema_version", 0)
        if schema_ver != 1:
            fail("Unsupported hackage.lock.json schema_version {} in {} (expected 1)".format(
                schema_ver,
                lock_label,
            ))

        boot_pkgs = lock_data.get("boot_packages", {})
        pkgs = lock_data.get("packages", {})
        sublib_entries = []

        for pkg_name in sorted(pkgs.keys()):
            spec = pkgs[pkg_name]
            pkg_ov = overrides.get((hub_name, pkg_name), {})
            _hackage_package_repo(
                name = _pkg_repo_name(hub_name, pkg_name),
                hub_name = hub_name,
                package_name = pkg_name,
                spec_json = json.encode(spec),
                overrides_json = json.encode(pkg_ov),
            )
            for sub_name in sorted(spec.get("sublibraries", {}).keys()):
                sublib_entries.append([pkg_name, sub_name])

        alex_bootstrap_repo(
            name = hub_name + "__bootstrap_alex",
        )
        happy_bootstrap_repo(
            name = hub_name + "__bootstrap_happy",
        )

        _hackage_hub_repo(
            name = hub_name,
            hub_name = hub_name,
            boot_packages_json = json.encode(boot_pkgs),
            package_names = sorted(pkgs.keys()),
            main_package_names = sorted([p for p in pkgs.keys() if pkgs[p].get("library") != None]),
            sublibraries_json = json.encode(sublib_entries),
        )

    return module_ctx.extension_metadata(reproducible = True)

_from_lock_tag = tag_class(
    attrs = {
        "name": attr.string(
            default = "hackage",
            doc = "Name of the hub repository exposed via use_repo.",
        ),
        "lockfile": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Label of the deterministic hackage.lock.json generated by //tools/lock.",
        ),
    },
    doc = "Load pinned Hackage dependencies from a hackage.lock.json file.",
)

_override_tag = tag_class(
    attrs = {
        "hub": attr.string(
            default = "hackage",
            doc = "Hub repository name this override applies to.",
        ),
        "package": attr.string(
            mandatory = True,
            doc = "Hackage package name to override.",
        ),
        "extra_cc_deps": attr.label_list(
            default = [],
            doc = "Additional Bazel cc_library labels linked into this Hackage package.",
        ),
        "extra_ghc_opts": attr.string_list(
            default = [],
            doc = "Additional GHC flags appended to ghc_opts.",
        ),
        "extra_cpp_options": attr.string_list(
            default = [],
            doc = "Additional CPP flags appended to cpp_options.",
        ),
        "extra_cc_options": attr.string_list(
            default = [],
            doc = "Additional C compiler flags appended to cc_options.",
        ),
        "configure_args": attr.string_list(
            default = [],
            doc = "Additional arguments passed to ./configure for Configure packages.",
        ),
    },
    doc = "Attach per-package C library deps or flag overrides to a locked Hackage package.",
)

hackage = module_extension(
    implementation = _hackage_impl,
    tag_classes = {
        "from_lock": _from_lock_tag,
        "override": _override_tag,
    },
    doc = "Bzlmod extension providing hermetic, lockfile-pinned Hackage dependencies.",
)
