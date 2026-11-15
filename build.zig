const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module. For now the only backend is SDL3 (+ SDL3_ttf for
    // text), with macOS extras through the Objective-C runtime.
    const vass = b.addModule("vass", .{
        .root_source_file = b.path("src/vass.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vass.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    vass.linkSystemLibrary("SDL3", .{});
    vass.linkSystemLibrary("SDL3_ttf", .{});
    vass.linkSystemLibrary("objc", .{});
    vass.linkFramework("AppKit", .{});

    const tests = b.addTest(.{ .root_module = vass });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
