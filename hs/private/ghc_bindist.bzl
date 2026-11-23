"""Pure-Starlark GHC bindist repository rules (zero ./configure && make install)."""

load("//hs/private:ghc_versions.bzl", "BOOT_PACKAGE_NAMES", "GHC_BINDISTS")

def _sanitize_settings(content):
    """Rewrites hardcoded host paths in GHC's lib/settings.

    Ensures GHC can never accidentally invoke host /usr/bin/{gcc,g++,ld.gold,ar,ranlib,llc,opt,clang}
    or pass -fuse-ld=gold. Real tool paths are injected per-action from Bazel's
    resolved cc_toolchain via -pgmc/-pgml/-pgma/-pgmP/-pgmar/-pgmlm.
    """
    cmd_overrides = {
        "C compiler command": "/nonexistent/cc",
        "C++ compiler command": "/nonexistent/cxx",
        "CPP command": "/nonexistent/cpp",
        "Haskell CPP command": "/nonexistent/hs-cpp",
        "JavaScript CPP command": "/nonexistent/js-cpp",
        "C-- CPP command": "/nonexistent/cmm-cpp",
        "Merge objects command": "/nonexistent/ld",
        "ar command": "/nonexistent/ar",
        "ranlib command": "/nonexistent/ranlib",
        "LLVM llc command": "/nonexistent/llc",
        "LLVM opt command": "/nonexistent/opt",
        "LLVM llvm-as command": "/nonexistent/llvm-as",
    }
    flag_replacements = [
        ('"-fuse-ld=gold -Wl,--no-as-needed -Wl,-z,noexecstack"', '"-Wl,--no-as-needed -Wl,-z,noexecstack"'),
        ('"-fuse-ld=gold -Wl,--no-as-needed"', '"-Wl,--no-as-needed"'),
        ('"-fuse-ld=gold"', '""'),
    ]
    out_lines = []
    for line in content.splitlines():
        rewritten = line
        for key, replacement in cmd_overrides.items():
            marker = '("' + key + '", "'
            idx = rewritten.find(marker)
            if idx != -1:
                prefix = rewritten[:idx + len(marker)]
                rest = rewritten[idx + len(marker):]
                end_quote = rest.find('"')
                if end_quote != -1:
                    rewritten = prefix + replacement + rest[end_quote:]
                break
        for old, new in flag_replacements:
            rewritten = rewritten.replace(old, new)
        out_lines.append(rewritten)
    return "\n".join(out_lines) + ("\n" if content.endswith("\n") else "")

def _parse_pkg_conf(text):
    """Parses key fields from a GHC installed package .conf file in pure Starlark."""
    fields = {}
    current_key = None
    for raw_line in text.splitlines():
        if not raw_line.strip():
            continue
        if raw_line[0] == " " or raw_line[0] == "\t":
            if current_key != None:
                fields[current_key] = fields[current_key] + " " + raw_line.strip()
        elif ":" in raw_line:
            idx = raw_line.find(":")
            key = raw_line[:idx].strip().lower()
            val = raw_line[idx + 1:].strip()
            fields[key] = val
            current_key = key
        else:
            current_key = None

    name = fields.get("name", "").strip()
    if not name:
        return None

    version = fields.get("version", "").strip()
    unit_id = fields.get("id", "").strip() or name

    raw_depends = fields.get("depends", "").replace(",", " ")
    depends = [tok for tok in raw_depends.split(" ") if tok]

    raw_exposed = fields.get("exposed-modules", "").replace(",", " ")
    exposed_modules = []
    tokens = [tok for tok in raw_exposed.split(" ") if tok]

    # Handle "Mod from pkg:Orig" syntax if present; keep the exposed module name.
    skip_next = 0
    for tok in tokens:
        if skip_next > 0:
            skip_next -= 1
            continue
        if tok == "from":
            skip_next = 1
            continue
        exposed_modules.append(tok)

    return {
        "name": name,
        "version": version,
        "id": unit_id,
        "depends": depends,
        "exposed_modules": exposed_modules,
    }

def _ghc_bindist_repo_impl(repository_ctx):
    ver = repository_ctx.attr.ghc_version
    arch_libdir = repository_ctx.attr.arch_libdir

    repository_ctx.download_and_extract(
        url = repository_ctx.attr.url,
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
    )

    # GHC 9.12+ Hadrian bindists append an ABI hash suffix to arch_libdir
    # (e.g. x86_64-linux-ghc-9.12.4-38d1). Auto-detect the exact directory name.
    if not repository_ctx.path("lib/" + arch_libdir).exists:
        candidates = sorted([
            entry.basename
            for entry in repository_ctx.path("lib").readdir()
            if entry.basename.startswith(arch_libdir + "-")
        ])
        if candidates:
            arch_libdir = candidates[0]

    # 1. Sanitize lib/settings so GHC can never invoke host /usr/bin/* or -fuse-ld=gold.
    settings_path = repository_ctx.path("lib/settings")
    if settings_path.exists:
        original = repository_ctx.read(settings_path)
        repository_ctx.file("lib/settings", _sanitize_settings(original), executable = False)

    # 2. Parse lib/package.conf.d/*.conf to extract exact boot package unit IDs & metadata.
    pkgdb_dir = repository_ctx.path("lib/package.conf.d")
    boot_packages = {}
    rts_version = "1.0.2"
    for entry in pkgdb_dir.readdir():
        fname = entry.basename
        if not fname.endswith(".conf"):
            continue
        parsed = _parse_pkg_conf(repository_ctx.read(entry))
        if parsed:
            boot_packages[parsed["name"]] = parsed
            if parsed["name"] == "rts" and parsed["version"]:
                rts_version = parsed["version"]

    boot_packages_json_dict = {
        k: json.encode(v)
        for k, v in sorted(boot_packages.items())
    }

    rts_include_rel = "lib/{}/rts-{}/include".format(arch_libdir, rts_version)
    iserv_label = '":bin/ghc-iserv-dyn-ghc-{}"'.format(ver) if repository_ctx.attr.is_dynamic_ghc else "None"
    haddock_rel = "bin/haddock-ghc-{}".format(ver)
    if not repository_ctx.path(haddock_rel).exists:
        haddock_rel = "bin/haddock"

    # Note: Keep the repository BUILD clean and expose both raw bindist files and
    # the $ORIGIN-staged GHC + hs_toolchain target.
    build_content = """\
load("@rules_hs//hs:toolchain.bzl", "hs_toolchain")
load("@rules_hs//hs/private:staged_ghc.bzl", "staged_ghc")

package(default_visibility = ["//visibility:public"])

exports_files([
    "bin/ghc-{ver}",
    "bin/ghc-pkg-{ver}",
    "bin/hsc2hs-ghc-{ver}",
    "{haddock_rel}",
    "bin/unlit-ghc-{ver}",
    "lib/settings",
    "lib/template-hsc.h",
] + ({iserv_exports}))

filegroup(
    name = "lib_files",
    srcs = glob(
        ["lib/**"],
        exclude = [
            "lib/html/js-src/**",
            "lib/html/package-lock.json",
            "lib/latex/**",
        ],
    ),
)

filegroup(
    name = "boot_haddock_files",
    srcs = glob(
        ["doc/html/libraries/**/*.haddock"],
        allow_empty = True,
    ),
)

filegroup(
    name = "rts_headers",
    srcs = glob(["lib/{arch_libdir}/*/include/**"]),
)

staged_ghc(
    name = "staged_ghc",
    version = "{ver}",
    arch_libdir = "{arch_libdir}",
    rts_include_rel = "{rts_include_rel}",
    bignum = "{bignum}",
    is_dynamic_ghc = {is_dynamic_ghc},
    needs_tinfo_stub = {needs_tinfo_stub},
    ghc = ":bin/ghc-{ver}",
    ghc_pkg = ":bin/ghc-pkg-{ver}",
    hsc2hs = ":bin/hsc2hs-ghc-{ver}",
    haddock = ":{haddock_rel}",
    unlit = ":bin/unlit-ghc-{ver}",
    ghc_iserv = {iserv_label},
    template_hsc_h = ":lib/template-hsc.h",
    lib_files = [":lib_files"],
    boot_haddock_files = [":boot_haddock_files"],
    rts_headers = [":rts_headers"],
    gmp = "@gmp//:gmp",
    tinfo_stub = "@rules_hs//hs/private:libtinfo.so.6",
    tinfo_stub_static = "@rules_hs//hs/private:tinfo_stub_static",
)

hs_toolchain(
    name = "toolchain_impl",
    version = "{ver}",
    staged_ghc = ":staged_ghc",
    boot_packages_json = {boot_packages_json},
    bignum = "{bignum}",
    is_dynamic_ghc = {is_dynamic_ghc},
    target_os = "{target_os}",
    target_cpu = "{target_cpu}",
    arch_libdir = "{arch_libdir}",
)
""".format(
        ver = ver,
        arch_libdir = arch_libdir,
        rts_include_rel = rts_include_rel,
        bignum = repository_ctx.attr.bignum,
        is_dynamic_ghc = repository_ctx.attr.is_dynamic_ghc,
        needs_tinfo_stub = repository_ctx.attr.needs_tinfo_stub,
        iserv_exports = '["bin/ghc-iserv-dyn-ghc-{}"]'.format(ver) if repository_ctx.attr.is_dynamic_ghc else "[]",
        iserv_label = iserv_label,
        haddock_rel = haddock_rel,
        boot_packages_json = repr(boot_packages_json_dict),
        target_os = repository_ctx.attr.target_os,
        target_cpu = repository_ctx.attr.target_cpu,
    )

    repository_ctx.file("BUILD.bazel", build_content, executable = False)

ghc_bindist_repo = repository_rule(
    implementation = _ghc_bindist_repo_impl,
    attrs = {
        "ghc_version": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(mandatory = True),
        "arch_libdir": attr.string(mandatory = True),
        "bignum": attr.string(default = "gmp"),
        "is_dynamic_ghc": attr.bool(default = True),
        "needs_tinfo_stub": attr.bool(default = True),
        "target_os": attr.string(mandatory = True),
        "target_cpu": attr.string(mandatory = True),
    },
    doc = "Downloads and unpacks an official GHC bindist purely in Starlark (zero ./configure && make install).",
)

def _hs_toolchains_repo_impl(repository_ctx):
    ver = repository_ctx.attr.ghc_version
    version_map = GHC_BINDISTS[ver]
    lines = [
        'package(default_visibility = ["//visibility:public"])',
        "",
    ]
    for plat, repo_name in sorted(repository_ctx.attr.platform_repos.items()):
        spec = version_map[plat]
        lines.append("""\
toolchain(
    name = "ghc_{plat}",
    exec_compatible_with = {exec_c},
    target_compatible_with = {target_c},
    toolchain = "@{repo}//:toolchain_impl",
    toolchain_type = "@rules_hs//hs:toolchain_type",
)
""".format(
            plat = plat,
            exec_c = repr(spec["exec_constraints"]),
            target_c = repr(spec["target_constraints"]),
            repo = repo_name,
        ))

    repository_ctx.file("BUILD.bazel", "\n".join(lines), executable = False)

hs_toolchains_repo = repository_rule(
    implementation = _hs_toolchains_repo_impl,
    attrs = {
        "ghc_version": attr.string(mandatory = True),
        "platform_repos": attr.string_dict(mandatory = True),
    },
    doc = "Generates the @hs_toolchains repository containing registerable Bazel toolchain() targets.",
)

def _hs_boot_repo_impl(repository_ctx):
    ver = repository_ctx.attr.ghc_version
    pkg_names = BOOT_PACKAGE_NAMES.get(ver, [])
    lines = [
        'load("@rules_hs//hs:defs.bzl", "hs_toolchain_library")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
    ]
    for pkg in pkg_names:
        lines.append("""\
hs_toolchain_library(
    name = "{pkg}",
    package_name = "{pkg}",
)
""".format(pkg = pkg))

    repository_ctx.file("BUILD.bazel", "\n".join(lines), executable = False)

hs_boot_repo = repository_rule(
    implementation = _hs_boot_repo_impl,
    attrs = {
        "ghc_version": attr.string(mandatory = True),
    },
    doc = "Generates the @hs_boot repository exposing hs_toolchain_library targets for all GHC boot packages.",
)
