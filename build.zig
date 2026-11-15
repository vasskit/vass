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
}
