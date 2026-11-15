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

/// FreeType without zlib/bzip2/png/brotli/harfbuzz. Core font drivers
/// (TrueType, CFF, Type 1, bitmap formats) and the smooth rasteriser are in.
pub fn freetype(b: *std.Build, upstream: *std.Build.Dependency, o: Options) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = o.target,
        .optimize = o.optimize,
        .link_libc = true,
        // Zig builds C with UBSan in Debug by default; third-party code is not ours to police.
        .sanitize_c = .off,
    });
    mod.addIncludePath(upstream.path("include"));
    mod.addCMacro("FT2_BUILD_LIBRARY", "1");
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
