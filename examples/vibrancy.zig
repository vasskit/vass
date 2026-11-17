//! Window vibrancy on macOS: the sidebar is left translucent so the blurred desktop shows through
//! it, the main pane is opaque. Pick a material, or switch the effect off. On other systems it is
//! an ordinary opaque window.
//!
//!     zig build vibrancy                      run it
//!     zig build vibrancy -- --snapshot DIR    save DIR/vibrancy.bmp and exit
const std = @import("std");
const builtin = @import("builtin");
const vass = @import("vass");
const harness = @import("common/harness.zig");

const Ui = vass.Ui;
const Window = harness.Window;

const on_mac = builtin.os.tag == .macos;

const materials = [_]struct { name: []const u8, m: if (on_mac) vass.macos.Material else u8 }{
    .{ .name = "Sidebar", .m = if (on_mac) .sidebar else 0 },
    .{ .name = "HUD", .m = if (on_mac) .hud_window else 0 },
    .{ .name = "Under window", .m = if (on_mac) .under_window_background else 0 },
    .{ .name = "Popover", .m = if (on_mac) .popover else 0 },
};

const side_items = [_][]const u8{ "Overview", "Inbox", "Drafts", "Sent", "Archive", "Starred" };

const App = struct {
    win: ?*Window = null,
    material: usize = 0,
    enabled: bool = true,
    selected: usize = 0,

    fn apply(app: *App) void {
        if (!on_mac) return;
        const w = app.win orelse return;
        if (app.enabled) {
            _ = vass.macos.setVibrancy(w.nativeHandle(), materials[app.material].m, .dark);
        } else {
            vass.macos.clearVibrancy(w.nativeHandle());
        }
    }
};

pub fn setup(app: *App, win: *Window) !void {
    app.win = win;
    app.apply();
}

pub fn frame(app: *App, ui: *Ui) void {
    const t = ui.theme;
    const b = ui.bounds;
    const side_w: f32 = 220;
    const blurred = on_mac and app.enabled;

    // The sidebar: only a faint tint, so the blur stays visible (opaque without vibrancy).
    const side: vass.Rect = .{ .x = 0, .y = 0, .w = side_w, .h = b.h };
    ui.list.rect(side, if (blurred) t.card.alpha(40) else t.card);
    var rows = side.inset(12);
    for (side_items, 0..) |name, i| {
        const r = rows.cutTop(30);
        if (ui.listRow(r, .{ .selected = app.selected == i }).clicked) app.selected = i;
        ui.label(.{ .x = r.x + 10, .y = r.y + 7, .w = r.w - 20, .h = 18 }, name, .{});
    }

    // The main pane is opaque.
    const pane: vass.Rect = .{ .x = side_w, .y = 0, .w = b.w - side_w, .h = b.h };
    ui.list.rect(pane, t.bg);
    var area = pane.inset(24);
    ui.label(area.cutTop(24), "Window vibrancy", .{ .size = 16, .weight = .semibold });
    _ = area.cutTop(8);
    if (!on_mac) {
        ui.label(area.cutTop(20), "Vibrancy needs macOS.", .{ .color = t.dim });
        return;
    }
    ui.label(area.cutTop(20), "Material behind the sidebar", .{ .color = t.dim });
    _ = area.cutTop(8);
    var segs: [materials.len]vass.ui.Segment = undefined;
    for (materials, 0..) |m, i| segs[i] = .{ .label = m.name };
    if (ui.segmented(area.cutTop(32), &segs, &app.material, .{})) app.apply();
    _ = area.cutTop(16);
    const was = app.enabled;
    var row = area.cutTop(24);
    _ = ui.toggle(row.cutLeft(34), &app.enabled, .{ .label = "Vibrancy" });
    ui.label(.{ .x = row.x + 10, .y = row.y + 3, .w = 200, .h = 18 }, "Vibrancy", .{});
    if (app.enabled != was) app.apply();
}

pub fn main(init: std.process.Init) !void {
    const env = try harness.start(init, "vibrancy", .{}) orelse return;
    var app: App = .{};
    try harness.run(@This(), env, .{
        .window = .{ .title = "Vibrancy", .width = 760, .height = 460, .resizable = true, .transparent = on_mac },
        // Alpha 0 so the blur shows wherever the frame draws nothing.
        .background = if (on_mac) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else null,
    }, &app);
}
