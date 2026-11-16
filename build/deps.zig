//! Build helpers that compile Vass's C dependencies from source, so that apps
//! are a single static binary. SDL3 comes from the castholm/SDL Zig package;
//! FreeType and SDL_ttf are plain release sources compiled here.
//!
//! Each function returns a static library. Source lists are per-OS-agnostic
//! except where noted, so other platforms can be added next to the macOS bits.

const std = @import("std");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

/// zlib (inflate and deflate; no gz* file API). Needed by libpng and, as FreeType's system zlib,
/// by its .gz font streams.
pub fn zlib(b: *std.Build, upstream: *std.Build.Dependency, o: Options) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("."));
    mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &.{
            "adler32.c", "compress.c", "crc32.c",   "deflate.c", "infback.c", "inffast.c",
            "inflate.c", "inftrees.c", "trees.c",   "uncompr.c", "zutil.c",
        },
        .flags = &.{ "-fno-sanitize=undefined", "-DHAVE_UNISTD_H", "-DHAVE_STDARG_H" },
    });
    const lib = b.addLibrary(.{ .name = "z", .linkage = .static, .root_module = mod });
    lib.installHeader(upstream.path("zlib.h"), "zlib.h");
    lib.installHeader(upstream.path("zconf.h"), "zconf.h");
    return lib;
}

/// libpng (read and write sides) on top of `z`, with the portable C code only (no NEON/SSE
/// shortcuts). `pnglibconf.h` is the project's prebuilt default configuration.
pub fn libpng(b: *std.Build, upstream: *std.Build.Dependency, z: *std.Build.Step.Compile, z_upstream: *std.Build.Dependency, o: Options) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    const conf = b.addWriteFiles();
    _ = conf.addCopyFile(upstream.path("scripts/pnglibconf.h.prebuilt"), "pnglibconf.h");
    mod.addIncludePath(upstream.path("."));
    mod.addIncludePath(conf.getDirectory());
    mod.addIncludePath(z_upstream.path("."));
    mod.linkLibrary(z);
    mod.addCMacro("PNG_ARM_NEON_OPT", "0");
    mod.addCMacro("PNG_INTEL_SSE_OPT", "0");
    mod.addCMacro("PNG_MIPS_MSA_OPT", "0");
    mod.addCMacro("PNG_POWERPC_VSX_OPT", "0");
    mod.addCMacro("PNG_LOONGARCH_LSX_OPT", "0");
    mod.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = &.{
            "png.c",      "pngerror.c", "pngget.c",   "pngmem.c",   "pngpread.c", "pngread.c",
            "pngrio.c",   "pngrtran.c", "pngrutil.c", "pngset.c",   "pngtrans.c", "pngwio.c",
            "pngwrite.c", "pngwtran.c", "pngwutil.c",
        },
        .flags = &.{"-fno-sanitize=undefined"},
    });
    const lib = b.addLibrary(.{ .name = "png", .linkage = .static, .root_module = mod });
    lib.installHeader(upstream.path("png.h"), "png.h");
    lib.installHeader(upstream.path("pngconf.h"), "pngconf.h");
    lib.installHeader(conf.getDirectory().path(b, "pnglibconf.h"), "pnglibconf.h");
    return lib;
}

/// What FreeType's PNG support is built against.
pub const PngSupport = struct {
    png: *std.Build.Step.Compile,
    png_upstream: *std.Build.Dependency,
    z: *std.Build.Step.Compile,
    z_upstream: *std.Build.Dependency,
};

/// FreeType without bzip2/brotli/harfbuzz. Core font drivers (TrueType, CFF, Type 1, bitmap
/// formats) and the smooth rasteriser are in, plus PNG bitmaps (colour emoji `sbix`/`CBDT`)
/// and gzip streams through `png_support`'s libpng and zlib.
pub fn freetype(b: *std.Build, upstream: *std.Build.Dependency, png_support: PngSupport, o: Options) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        // Zig builds C with UBSan in Debug by default; third-party code is not ours to police.
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("include"));
    mod.addCMacro("FT2_BUILD_LIBRARY", "1");
    mod.addCMacro("FT_CONFIG_OPTION_USE_PNG", "1");
    mod.addCMacro("FT_CONFIG_OPTION_SYSTEM_ZLIB", "1"); // one zlib in the binary: libpng's
    mod.addIncludePath(png_support.png_upstream.path("."));
    mod.addIncludePath(png_support.png.getEmittedIncludeTree());
    mod.addIncludePath(png_support.z_upstream.path("."));
    mod.linkLibrary(png_support.png);
    mod.linkLibrary(png_support.z);
    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &.{
            "base/ftbase.c",    "base/ftinit.c",   "base/ftsystem.c", "base/ftdebug.c",
            "base/ftbbox.c",    "base/ftbitmap.c", "base/ftcid.c",    "base/ftfstype.c",
            "base/ftgasp.c",    "base/ftglyph.c",  "base/ftgxval.c",  "base/ftmm.c",
            "base/ftotval.c",   "base/ftpatent.c", "base/ftpfr.c",    "base/ftstroke.c",
            "base/ftsynth.c",   "base/fttype1.c",  "base/ftwinfnt.c",
            // Modules listed in include/freetype/config/ftmodule.h.
            "autofit/autofit.c",   "bdf/bdf.c",       "cff/cff.c",       "cid/type1cid.c",
            "pcf/pcf.c",           "pfr/pfr.c",       "psaux/psaux.c",   "pshinter/pshinter.c",
            "psnames/psnames.c",   "raster/raster.c", "sdf/sdf.c",       "sfnt/sfnt.c",
            "smooth/smooth.c",     "svg/svg.c",       "truetype/truetype.c", "type1/type1.c",
            "type42/type42.c",     "winfonts/winfnt.c",
            // Compressed .pcf.gz / .Z font streams (built-in zlib/LZW; referenced by the pcf driver).
            "gzip/ftgzip.c",       "lzw/ftlzw.c",
        },
        .flags = &.{"-fno-sanitize=undefined"},
    });
    return b.addLibrary(.{ .name = "freetype", .linkage = .static, .root_module = mod });
}

/// HarfBuzz from its single-file amalgamation (C++), with the FreeType glue
/// (hb-ft) but no CoreText/ICU/GLib. hb's own AAT layout handles `trak`/`kern`.
pub fn harfbuzz(b: *std.Build, upstream: *std.Build.Dependency, ft_upstream: *std.Build.Dependency, o: Options) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("src"));
    mod.addIncludePath(ft_upstream.path("include"));
    mod.addCMacro("HAVE_FREETYPE", "1");
    mod.addCMacro("HB_NO_PRAGMA_GCC_DIAGNOSTIC_ERROR", "1");
    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &.{"harfbuzz.cc"},
        .flags = &.{ "-fno-sanitize=undefined", "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics" },
    });
    return b.addLibrary(.{ .name = "harfbuzz", .linkage = .static, .root_module = mod });
}

/// SDL_ttf 3.x on top of `sdl` (static), `ft` and HarfBuzz, built without
/// PlutoSVG (no colour SVG emoji).
pub fn sdlTtf(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    sdl: *std.Build.Step.Compile,
    ft: *std.Build.Step.Compile,
    ft_upstream: *std.Build.Dependency,
    hb: *std.Build.Step.Compile,
    hb_upstream: *std.Build.Dependency,
    o: Options,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("include"));
    mod.addIncludePath(upstream.path("src"));
    mod.addIncludePath(ft_upstream.path("include"));
    mod.linkLibrary(sdl); // SDL3 headers
    mod.linkLibrary(ft);
    mod.linkLibrary(hb);
    mod.addIncludePath(hb_upstream.path("src"));
    mod.addCMacro("TTF_USE_HARFBUZZ", "1");
    mod.addCMacro("TTF_USE_PLUTOSVG", "0");
    mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &.{
            "SDL_ttf.c",
            "SDL_hashtable.c",
            "SDL_hashtable_ttf.c",
            "SDL_gpu_textengine.c",
            "SDL_renderer_textengine.c",
            "SDL_surface_textengine.c",
        },
        .flags = &.{"-fno-sanitize=undefined"},
    });
    return b.addLibrary(.{ .name = "SDL3_ttf", .linkage = .static, .root_module = mod });
}
