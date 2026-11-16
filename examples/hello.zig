//! The smallest program: a label and a button over one window.
//!
//!     zig build hello                      run it
//!     zig build hello -- --snapshot DIR    save DIR/hello.bmp and exit
//!
//! The same frame without the command line handling, as it would sit in an app of your own, is in
//! the README.
const std = @import("std");
const vass = @import("vass");
const harness = @import("common/harness.zig");

const App = struct {
    clicks: u32 = 0,
};

pub fn frame(app: *App, ui: *vass.Ui) void {
    var area = ui.bounds.inset(24);
    ui.labelFmt(area.cutTop(28), "Clicks: {d}", .{app.clicks}, .{ .size = 16 });
    if (ui.button(area.cutTop(36), "Click me", .{})) app.clicks += 1;
}

pub fn main(init: std.process.Init) !void {
    const env = try harness.start(init, "hello", .{}) orelse return;
    var app: App = .{};
    try harness.run(@This(), env, .{ .window = .{ .title = "Hello", .width = 320, .height = 160 } }, &app);
}
