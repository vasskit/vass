const std = @import("std");
const builtin = @import("builtin");
const deps = @import("build/deps.zig");

/// The target Vass is meant to be built for when the user does not pass
/// `-Dtarget`: the host, with a macOS deployment target of 13.0 (so binaries
/// run on macOS 13 and later instead of only on the build machine's OS).
///
/// Apps that depend on Vass should use the same default so their own code gets
/// the same deployment target (see README.md):
///
///     const vass_build = @import("vass");
///     const target = b.standardTargetOptions(.{ .default_target = vass_build.default_target });
pub const default_target: std.Target.Query = if (builtin.os.tag == .macos)
    .{ .os_tag = .macos, .os_version_min = .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } } }
else
    .{};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const system_sdl = b.option(
        bool,
        "system-sdl",
        "Link the system SDL3 and SDL3_ttf (Homebrew, /opt/homebrew/lib) instead of building them from source",
    ) orelse false;

    // The library module. The only backend is SDL3 (+ SDL3_ttf for text),
    // with macOS extras through the Objective-C runtime.
    const vass = b.addModule("vass", .{
        .root_source_file = b.path("src/vass.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (system_sdl) {
        vass.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        vass.linkSystemLibrary("SDL3", .{});
        vass.linkSystemLibrary("SDL3_ttf", .{});
    } else {
        // SDL3, FreeType and SDL_ttf are compiled from the pinned sources in
        // build.zig.zon and linked statically. They are lazy dependencies, so
        // -Dsystem-sdl=true never downloads them.
        const sdl_dep = sdlDependency(b, target, optimize);
        const ft_dep = b.lazyDependency("freetype", .{});
        const ttf_dep = b.lazyDependency("sdl_ttf", .{});
        const hb_dep = b.lazyDependency("harfbuzz", .{});
        const z_dep = b.lazyDependency("zlib", .{});
        const png_dep = b.lazyDependency("libpng", .{});
        if (sdl_dep != null and ft_dep != null and ttf_dep != null and hb_dep != null and z_dep != null and png_dep != null) {
            const o: deps.Options = .{ .target = target, .optimize = optimize };
            const sdl = sdl_dep.?.artifact("SDL3");
            const z = deps.zlib(b, z_dep.?, o);
            const png = deps.libpng(b, png_dep.?, z, z_dep.?, o);
            const ft = deps.freetype(b, ft_dep.?, .{ .png = png, .png_upstream = png_dep.?, .z = z, .z_upstream = z_dep.? }, o);
            const hb = deps.harfbuzz(b, hb_dep.?, ft_dep.?, o);
            const ttf = deps.sdlTtf(b, ttf_dep.?, sdl, ft, ft_dep.?, hb, hb_dep.?, o);
            addMacosSdkPaths(b, ttf.root_module, target);
            vass.linkLibrary(ttf);
            vass.linkLibrary(sdl);
        }
    }
    // stb_image, compiled as one C file (decoding PNG/JPEG/BMP/GIF). Independent of SDL,
    // so it is needed with -Dsystem-sdl=true as well.
    if (b.lazyDependency("stb", .{})) |stb_dep| {
        vass.addIncludePath(stb_dep.path("."));
        vass.addCSourceFile(.{
            .file = b.path("src/image/stb_impl.c"),
            .flags = &.{ "-fno-sanitize=undefined", "-fno-strict-aliasing" },
        });
    }
    // Audio decoders: stb_vorbis (from the same stb checkout) and dr_mp3, in one C file.
    if (b.lazyDependency("stb", .{})) |stb_dep| {
        if (b.lazyDependency("dr_libs", .{})) |dr_dep| {
            vass.addIncludePath(dr_dep.path("."));
            vass.addCSourceFile(.{
                .file = b.path("src/audio/audio_impl.c"),
                .flags = &.{ "-fno-sanitize=undefined", "-fno-strict-aliasing" },
            });
            _ = stb_dep;
        }
    }
    if (target.result.os.tag == .macos) {
        addMacosSdkPaths(b, vass, target);
        vass.linkSystemLibrary("objc", .{});
        vass.linkFramework("AppKit", .{});
    }

    const tests = b.addTest(.{ .root_module = vass });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    addExamples(b, vass, target, optimize, test_step);
}

/// Examples are discovered, not listed: every `examples/*.zig` is a program, and gets an
/// executable and a `zig build <name> -- <args>` step that runs it. Subfolders (`common/`, the
/// `assets/` the examples `@embedFile`) are never examples. All of them are built by
/// `zig build examples` and, to keep them compiling, by `zig build test`.
fn addExamples(
    b: *std.Build,
    vass: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const io = b.graph.io;
    var dir = b.root.openDir(io, "examples", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return, // a package without its examples
        else => std.debug.panic("cannot open the examples directory: {t}", .{err}),
    };
    defer dir.close(io);
    // The configure result is cached; without this a file added to or removed from `examples/`
    // is not seen until the cache is cleared. Only declared once the directory exists, since
    // tracking a missing one fails the configure phase.
    b.dependOnDirectoryContents(b.path("examples"));

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot read the examples directory: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        names.append(b.allocator, b.dupe(entry.name[0 .. entry.name.len - ".zig".len])) catch @panic("OOM");
    }
    // The directory order is the file system's; sort so `zig build -l` is stable.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    const all = b.step("examples", "Build all the examples");
    for (names.items) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "vass", .module = vass }},
            }),
        });
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(name, b.fmt("Run the {s} example (examples/{s}.zig)", .{ name, name })).dependOn(&run.step);
        all.dependOn(&exe.step);
        test_step.dependOn(&exe.step);
    }
}

/// castholm/SDL only auto-detects the macOS SDK when the target is exactly the
/// native one. Our default target pins a lower deployment target, which makes
/// it "non-native", so hand it the SDK paths explicitly.
fn macosSdk(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (target.result.os.tag != .macos or builtin.os.tag != .macos) return null;
    return std.zig.system.darwin.getSdk(b.allocator, b.graph.io, &target.result);
}

/// Zig only finds the macOS SDK by itself for the exact native target; with a
/// pinned deployment target we add the framework and library paths ourselves.
fn addMacosSdkPaths(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const sdk = macosSdk(b, target) orelse return;
    mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}

fn sdlDependency(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Dependency {
    if (macosSdk(b, target)) |sdk| {
        return b.lazyDependency("sdl", .{
            .target = target,
            .optimize = optimize,
            .system_include_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) },
            .system_framework_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) },
            .library_path = std.Build.LazyPath{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) },
        });
    }
    return b.lazyDependency("sdl", .{ .target = target, .optimize = optimize });
}
