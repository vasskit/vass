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
        if (sdl_dep != null and ft_dep != null and ttf_dep != null and hb_dep != null) {
            const o: deps.Options = .{ .target = target, .optimize = optimize };
            const sdl = sdl_dep.?.artifact("SDL3");
            const ft = deps.freetype(b, ft_dep.?, o);
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
            .file = b.path("src/stb_impl.c"),
            .flags = &.{ "-fno-sanitize=undefined", "-fno-strict-aliasing" },
        });
    }
    addMacosSdkPaths(b, vass, target);
    vass.linkSystemLibrary("objc", .{});
    vass.linkFramework("AppKit", .{});

    const tests = b.addTest(.{ .root_module = vass });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // Example: a notes app. `zig build notes -- --snapshot DIR [--script]`.
    const notes = b.addExecutable(.{
        .name = "notes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/notes.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vass", .module = vass }},
        }),
    });
    const run_notes = b.addRunArtifact(notes);
    run_notes.addPassthruArgs();
    b.step("notes", "Run the notes example").dependOn(&run_notes.step);
    // Keep the example compiling as part of `zig build test`.
    test_step.dependOn(&notes.step);

    // Example: the form controls. `zig build controls -- --snapshot DIR`.
    const controls = b.addExecutable(.{
        .name = "controls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/controls.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vass", .module = vass }},
        }),
    });
    const run_controls = b.addRunArtifact(controls);
    run_controls.addPassthruArgs();
    b.step("controls", "Run the controls showcase").dependOn(&run_controls.step);
    test_step.dependOn(&controls.step);

    // Example: images. `zig build images -- --snapshot DIR`.
    const images = b.addExecutable(.{
        .name = "images",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/images.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vass", .module = vass }},
        }),
    });
    const run_images = b.addRunArtifact(images);
    run_images.addPassthruArgs();
    b.step("images", "Run the images showcase").dependOn(&run_images.step);
    test_step.dependOn(&images.step);

    // Example: SVG icons. `zig build icons -- --snapshot DIR`.
    const icons_ex = b.addExecutable(.{
        .name = "icons",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/icons.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vass", .module = vass }},
        }),
    });
    const run_icons = b.addRunArtifact(icons_ex);
    run_icons.addPassthruArgs();
    b.step("icons", "Run the SVG icons showcase").dependOn(&run_icons.step);
    test_step.dependOn(&icons_ex.step);
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
