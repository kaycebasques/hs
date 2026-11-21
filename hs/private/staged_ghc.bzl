"""Hermetic $ORIGIN staging rule for GHC bindists + GMP + libtinfo.so.6 stub."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//hs:providers.bzl", "HsToolchainInfo")

def _find_static_archives(cc_info, desc):
    """Returns (pic_archive, static_archive) from a CcInfo provider."""
    pic_a = None
    static_a = None
    for li in cc_info.linking_context.linker_inputs.to_list():
        for lib in li.libraries:
            if lib.pic_static_library:
                pic_a = lib.pic_static_library
            if lib.static_library:
                static_a = lib.static_library
    if not pic_a and static_a:
        pic_a = static_a
    if not static_a and pic_a:
        static_a = pic_a
    if not pic_a:
        fail("Could not find static archive in {} CcInfo".format(desc))
    return pic_a, static_a

def _get_cc_link_tool_and_flags(ctx, cc_toolchain):
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    cc_bin = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_link_dynamic_library,
    )
    return cc_bin, feature_configuration

def _staged_ghc_impl(ctx):
    ver = ctx.attr.version
    arch_libdir = ctx.attr.arch_libdir
    prefix = ctx.label.name

    cc_toolchain = find_cc_toolchain(ctx)
    cc_bin, _ = _get_cc_link_tool_and_flags(ctx, cc_toolchain)

    # 1. Prepare hermetic GMP artifacts when using GMP bignum backend:
    #    - gmp_static/libgmp.a (static ONLY, linked into user executables via -L)
    #    - libgmp.so.10 (staged next to libHS*.so for GHC compiler's own $ORIGIN RUNPATH)
    gmp_static_lib = None
    gmp_static_dir = None
    gmp_shared_so = None
    stage_extra_inputs = []

    if ctx.attr.bignum == "gmp":
        gmp_pic_a, gmp_static_a = _find_static_archives(ctx.attr.gmp[CcInfo], "@gmp//:gmp")

        # Clean static-only directory containing strictly static archives (no .so!).
        gmp_static_lib = ctx.actions.declare_file(prefix + "/gmp_static/libgmp.a")
        gmp_static_dir = gmp_static_lib.dirname
        ctx.actions.symlink(
            output = gmp_static_lib,
            target_file = gmp_static_a,
        )

        # Build libgmp.so.10 for GHC compiler binary's $ORIGIN RUNPATH.
        if ctx.attr.is_dynamic_ghc:
            gmp_shared_so = ctx.actions.declare_file(prefix + "/_gmp_so/libgmp.so.10")
            ctx.actions.run_shell(
                mnemonic = "HsLinkGmpShared",
                progress_message = "Building hermetic libgmp.so.10 for GHC {}".format(ver),
                inputs = depset([gmp_pic_a], transitive = [cc_toolchain.all_files]),
                outputs = [gmp_shared_so],
                command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
"$1" -shared -fPIC -Wno-unused-command-line-argument \
    -Wl,-soname,libgmp.so.10 \
    -Wl,--whole-archive "$2" -Wl,--no-whole-archive \
    -o "$3"
""",
                arguments = [cc_bin, gmp_pic_a.path, gmp_shared_so.path],
            )
            stage_extra_inputs.append(gmp_shared_so)

    tinfo_so = None
    tinfo_static_lib = None
    if ctx.attr.needs_tinfo_stub and ctx.file.tinfo_stub:
        tinfo_so = ctx.file.tinfo_stub
        stage_extra_inputs.append(tinfo_so)
        if ctx.attr.tinfo_stub_static:
            _, tinfo_static_a = _find_static_archives(ctx.attr.tinfo_stub_static[CcInfo], "tinfo_stub_static")
            tinfo_static_lib = ctx.actions.declare_file(prefix + "/gmp_static/libtinfo.a")
            if not gmp_static_dir:
                gmp_static_dir = tinfo_static_lib.dirname
            ctx.actions.symlink(
                output = tinfo_static_lib,
                target_file = tinfo_static_a,
            )

    # 2. Declare sibling bin/* executables and lib/ directory under the SAME prefix
    #    so GHC's baked-in ELF RUNPATH ($ORIGIN/../lib/<arch_libdir>) and ${pkgroot}/../lib
    #    both resolve cleanly with ZERO LD_LIBRARY_PATH and ZERO patchelf!
    out_ghc = ctx.actions.declare_file(prefix + "/bin/ghc-" + ver)
    out_ghc_pkg = ctx.actions.declare_file(prefix + "/bin/ghc-pkg-" + ver)
    out_hsc2hs = ctx.actions.declare_file(prefix + "/bin/hsc2hs-ghc-" + ver)
    out_unlit = ctx.actions.declare_file(prefix + "/bin/unlit")
    out_lib = ctx.actions.declare_directory(prefix + "/lib")

    outputs = [out_ghc, out_ghc_pkg, out_hsc2hs, out_unlit, out_lib]
    inputs = [ctx.file.ghc, ctx.file.ghc_pkg, ctx.file.hsc2hs, ctx.file.unlit] + stage_extra_inputs

    out_iserv = None
    iserv_src = ""
    iserv_dst = ""
    if ctx.file.ghc_iserv:
        out_iserv = ctx.actions.declare_file(prefix + "/bin/ghc-iserv-dyn-ghc-" + ver)
        outputs.append(out_iserv)
        inputs.append(ctx.file.ghc_iserv)
        iserv_src = ctx.file.ghc_iserv.path
        iserv_dst = out_iserv.path

    # Locate bindist lib root from template-hsc.h (always at <bindist>/lib/template-hsc.h).
    src_lib_dir = ctx.file.template_hsc_h.dirname

    ctx.actions.run_shell(
        mnemonic = "HsStageGhc",
        progress_message = "Staging hermetic GHC {} ($ORIGIN layout)".format(ver),
        inputs = depset(
            inputs + [ctx.file.template_hsc_h],
            transitive = [depset(ctx.files.lib_files)],
        ),
        outputs = outputs,
        command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
SRC_LIB="$1"
OUT_LIB="$2"
ARCH_LIBDIR="$3"
GHC_SRC="$4"
GHC_DST="$5"
GHCPKG_SRC="$6"
GHCPKG_DST="$7"
HSC2HS_SRC="$8"
HSC2HS_DST="$9"
UNLIT_SRC="${10}"
UNLIT_DST="${11}"
ISERV_SRC="${12}"
ISERV_DST="${13}"
GMP_SO="${14}"
TINFO_SO="${15}"

cp -L "$GHC_SRC" "$GHC_DST" && chmod +x "$GHC_DST"
cp -L "$GHCPKG_SRC" "$GHCPKG_DST" && chmod +x "$GHCPKG_DST"
cp -L "$HSC2HS_SRC" "$HSC2HS_DST" && chmod +x "$HSC2HS_DST"
cp -L "$UNLIT_SRC" "$UNLIT_DST" && chmod +x "$UNLIT_DST"
if [ -n "$ISERV_SRC" ]; then
    cp -L "$ISERV_SRC" "$ISERV_DST" && chmod +x "$ISERV_DST"
fi

mkdir -p "$OUT_LIB"
# Copy bindist lib/ preserving internal symlinks so the TreeArtifact is 100% self-contained.
cp -R -P "$SRC_LIB"/. "$OUT_LIB"/
chmod -R u+w "$OUT_LIB"

if [ -n "$GMP_SO" ]; then
    cp -L "$GMP_SO" "$OUT_LIB/$ARCH_LIBDIR/libgmp.so.10"
    ln -sf libgmp.so.10 "$OUT_LIB/$ARCH_LIBDIR/libgmp.so"
fi

if [ -n "$TINFO_SO" ]; then
    cp -L "$TINFO_SO" "$OUT_LIB/$ARCH_LIBDIR/libtinfo.so.6"
    ln -sf libtinfo.so.6 "$OUT_LIB/$ARCH_LIBDIR/libtinfo.so"
fi

# Refresh package.cache (removing sandbox input symlinks first so ghc-pkg can create & lock writable files).
rm -f "$OUT_LIB/package.conf.d/package.cache" "$OUT_LIB/package.conf.d/package.cache.lock"
"$GHCPKG_DST" --global-package-db="$OUT_LIB/package.conf.d" recache
rm -f "$OUT_LIB/package.conf.d/package.cache.lock"
""",
        arguments = [
            src_lib_dir,
            out_lib.path,
            arch_libdir,
            ctx.file.ghc.path,
            out_ghc.path,
            ctx.file.ghc_pkg.path,
            out_ghc_pkg.path,
            ctx.file.hsc2hs.path,
            out_hsc2hs.path,
            ctx.file.unlit.path,
            out_unlit.path,
            iserv_src,
            iserv_dst,
            gmp_shared_so.path if gmp_shared_so else "",
            tinfo_so.path if tinfo_so else "",
        ],
    )

    # Compute execroot-relative RTS include dir directly from bindist rts_headers
    # so cc_common.compile gets real Bazel-tracked File objects.
    rts_include_dir = ""
    for f in ctx.files.rts_headers:
        if f.basename == "Rts.h":
            rts_include_dir = f.dirname
            break
    if not rts_include_dir:
        fail("Could not find Rts.h in bindist rts_headers")

    all_files_list = [out_ghc, out_ghc_pkg, out_hsc2hs, out_unlit, out_lib, ctx.file.template_hsc_h]
    if out_iserv:
        all_files_list.append(out_iserv)
    if gmp_static_lib:
        all_files_list.append(gmp_static_lib)
    if tinfo_static_lib:
        all_files_list.append(tinfo_static_lib)

    return [
        DefaultInfo(files = depset(all_files_list)),
        HsToolchainInfo(
            version = ver,
            ghc = out_ghc,
            ghc_pkg = out_ghc_pkg,
            hsc2hs = out_hsc2hs,
            ghc_iserv = out_iserv,
            libdir = out_lib,
            template_hsc_h = ctx.file.template_hsc_h,
            rts_include_dir = rts_include_dir,
            rts_headers = depset(ctx.files.rts_headers),
            all_files = depset(all_files_list, transitive = [depset(ctx.files.rts_headers)]),
            cc_wrapper = None,  # Populated by hs_toolchain rule
            gmp_static_dir = gmp_static_dir,
            gmp_static_lib = gmp_static_lib,
            boot_packages = {},  # Populated by hs_toolchain rule
            bignum = ctx.attr.bignum,
            is_dynamic_ghc = ctx.attr.is_dynamic_ghc,
            target_os = "",
            target_cpu = "",
            arch_libdir = arch_libdir,
        ),
    ]

staged_ghc = rule(
    implementation = _staged_ghc_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "arch_libdir": attr.string(mandatory = True),
        "rts_include_rel": attr.string(mandatory = True),
        "bignum": attr.string(default = "gmp"),
        "is_dynamic_ghc": attr.bool(default = True),
        "needs_tinfo_stub": attr.bool(default = True),
        "ghc": attr.label(mandatory = True, allow_single_file = True),
        "ghc_pkg": attr.label(mandatory = True, allow_single_file = True),
        "hsc2hs": attr.label(mandatory = True, allow_single_file = True),
        "unlit": attr.label(mandatory = True, allow_single_file = True),
        "ghc_iserv": attr.label(allow_single_file = True),
        "template_hsc_h": attr.label(mandatory = True, allow_single_file = True),
        "lib_files": attr.label_list(allow_files = True, mandatory = True),
        "rts_headers": attr.label_list(allow_files = True, mandatory = True),
        "gmp": attr.label(mandatory = True, providers = [CcInfo]),
        "tinfo_stub": attr.label(allow_single_file = True),
        "tinfo_stub_static": attr.label(providers = [CcInfo]),
    },
    toolchains = use_cc_toolchain(),
    fragments = ["cpp"],
    provides = [HsToolchainInfo],
)
