//! Resizable split panes: an app shell (left sidebar | centre | right inspector) with a
//! horizontal split inside the centre (editor over a bottom panel), all nested, each pane
//! showing its size. The sidebar collapses when dragged small (and back out), double-click
//! on a divider resets it, Tab to a divider and use the arrow keys, and the buttons in the
//! toolbar toggle a pane. The window is resizable and reflows live while the edge is dragged:
//! the panes keep their preferred sizes and squeeze only while there is no room.
//!
//!     zig build split                       run it
//!     zig build split -- --snapshot DIR     save split-default.bmp, split-dragged.bmp,
//!                                           split-collapsed.bmp, split-hover.bmp,
//!                                           split-inspector-hidden.bmp and split-narrow.bmp
//!                                           after scripted input (hidden window), then exit
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Ui = vass.Ui;
const ui_mod = vass.ui;
const split = vass.split;

const side_items = [_][]const u8{ "Overview", "Inbox", "Drafts", "Sent", "Archive", "Starred", "Projects", "Billing", "Settings" };

const left_opts: split.SplitterOpts = .{ .min = 160, .max = 420, .default = 240, .collapse_below = 110 };
const right_opts: split.SplitterOpts = .{ .min = 200, .max = 420, .default = 280, .invert = true };
const bottom_opts: split.SplitterOpts = .{ .axis = .horizontal, .min = 70, .max = 400, .default = 160, .invert = true };

const App = struct {
    state: ui_mod.State = .{},
    left: split.SplitState = .init(270),
    right: split.SplitState = .init(300),
    bottom: split.SplitState = .init(170),
    selected: usize = 0,
    /// Divider rectangles of the last frame, so the scripted input can aim at them.
    left_div: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    right_div: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    bottom_div: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Where the scripted pointer grabbed a divider (it must not follow the divider as it moves).
    anchor: [2]f32 = .{ 0, 0 },
    /// Toolbar buttons.
    left_btn: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    right_btn: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    bottom_btn: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

fn sizeText(buf: []u8, r: Rect) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.0} x {d:.0}", .{ r.w, r.h }) catch "";
}

/// A pane: a card with a title, its size, and a line of hint text.
fn pane(ui: *Ui, r: Rect, title: []const u8, hint: []const u8) void {
    if (r.w < 1 or r.h < 1) return;
    const t = ui.theme;
    ui.card(r);
    ui.pushClip(r);
    defer ui.popClip();
    var buf: [32]u8 = undefined;
    ui.label(.{ .x = r.x + 14, .y = r.y + 12, .w = r.w - 28, .h = 20 }, title, .{ .size = 14, .weight = .semibold });
    ui.label(.{ .x = r.x + 14, .y = r.y + 34, .w = r.w - 28, .h = 18 }, sizeText(&buf, r), .{ .size = 12, .color = t.accent });
    ui.label(.{ .x = r.x + 14, .y = r.y + 56, .w = r.w - 28, .h = 18 }, hint, .{ .size = 11.5, .color = t.dim });
}

fn frame(app: *App, ui: *Ui) void {
    const t = ui.theme;
    var area = (Rect{ .x = 0, .y = 0, .w = ui.bounds.w, .h = ui.bounds.h }).inset(12);

    // Toolbar.
    var bar = area.cutTop(34);
    _ = area.cutTop(10);
    app.left_btn = bar.cutLeft(120);
    _ = bar.cutLeft(8);
    app.bottom_btn = bar.cutLeft(120);
    _ = bar.cutLeft(8);
    app.right_btn = bar.cutLeft(120);
    if (ui.button(app.left_btn, "Sidebar", .{ .on = !app.left.collapsed() })) app.left.toggle();
    if (ui.button(app.bottom_btn, "Bottom panel", .{ .on = !app.bottom.collapsed() })) app.bottom.toggle();
    if (ui.button(app.right_btn, "Inspector", .{ .on = !app.right.collapsed() })) app.right.toggle();
    ui.label(.{ .x = bar.x + 8, .y = bar.y + 9, .w = bar.w - 8, .h = 18 }, "drag the dividers, double-click one to reset it", .{ .size = 12, .color = t.dim });

    // Pane rectangles from the stored sizes. The right pane gives way before the left one; the
    // centre keeps 260 points. Nothing here changes the stored sizes.
    var sh = split.three(area, app.left.size, app.right.size, .{ .min_centre = 260, .gap = 8 });
    // A pane squeezed below its own minimum is hidden (its stored size is kept for later), and the
    // centre takes its room.
    const right_vis = sh.right_size >= right_opts.min;
    if (!right_vis) sh = split.three(area, app.left.size, 0, .{ .min_centre = 260, .gap = 8 });
    const mid = split.two(sh.centre, app.bottom.size, .{ .axis = .horizontal, .side = .second, .min_other = 90, .gap = 8 });

    // Left: a list that runs to the pane's edge (so the divider's grab area overlaps it).
    if (sh.left.w > 0) {
        pane(ui, sh.left, "Sidebar", "collapses below 110");
        ui.pushClip(sh.left);
        var y = sh.left.y + 84;
        for (side_items, 0..) |name, i| {
            const rr: Rect = .{ .x = sh.left.x + 6, .y = y, .w = sh.left.w - 12, .h = 28 };
            y += 30;
            if (rr.y + rr.h > sh.left.y + sh.left.h) break;
            if (ui.listRow(rr, .{ .selected = app.selected == i, .radius = 7 }).clicked) app.selected = i;
            ui.label(.{ .x = rr.x + 10, .y = rr.y + 6, .w = rr.w - 20, .h = 18 }, name, .{});
        }
        ui.popClip();
    }
    pane(ui, mid.first, "Editor", "the centre keeps at least 260");
    pane(ui, mid.second, "Bottom panel", "a horizontal split, nested");
    if (right_vis) pane(ui, sh.right, "Inspector", "grows leftwards (invert)");

    // Dividers last, so their lines sit on top. `shown` makes a drag start from what is on
    // screen when the window is too small for the stored size.
    app.left_div = sh.left_divider;
    app.right_div = sh.right_divider;
    app.bottom_div = mid.divider;
    var o = left_opts;
    o.shown = sh.left_size;
    _ = ui.splitter(sh.left_divider, &app.left.size, o);
    app.left.remember();
    if (right_vis or ui.splitterDragging(&app.right.size)) {
        o = right_opts;
        o.shown = sh.right_size;
        _ = ui.splitter(sh.right_divider, &app.right.size, o);
        app.right.remember();
    }
    o = bottom_opts;
    o.shown = mid.size;
    _ = ui.splitter(mid.divider, &app.bottom.size, o);
    app.bottom.remember();
}

// ---- scripted run -----------------------------------------------------------------------------

const Step = struct { in: ui_mod.Input, snap: ?[]const u8 = null };

fn center(r: Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

fn pointer(x: f32, y: f32) ui_mod.Input {
    return .{ .mouse_x = x, .mouse_y = y };
}

fn pressAt(x: f32, y: f32) ui_mod.Input {
    return .{ .mouse_x = x, .mouse_y = y, .pressed = true, .down = true, .mouse_clicks = 1 };
}

fn heldAt(x: f32, y: f32) ui_mod.Input {
    return .{ .mouse_x = x, .mouse_y = y, .down = true };
}

fn liftAt(x: f32, y: f32) ui_mod.Input {
    return .{ .mouse_x = x, .mouse_y = y, .released = true };
}

/// The input of scripted frame `n`, aimed at where things were drawn the frame before.
fn script(app: *App, n: u32) ?Step {
    switch (n) {
        4, 11, 15 => app.anchor = center(if (n == 4 or n == 15) app.left_div else app.right_div),
        else => {},
    }
    const l = app.anchor;
    const r = if (n >= 21 and n <= 23) center(app.right_div) else app.anchor;
    switch (n) {
        0, 1, 2 => return .{ .in = pointer(-1e9, -1e9) },
        3 => return .{ .in = pointer(-1e9, -1e9), .snap = "default" },
        // Drag the sidebar divider 90 points to the right.
        4 => return .{ .in = pointer(l[0], l[1]) },
        5 => return .{ .in = pressAt(l[0], l[1]) },
        6 => return .{ .in = heldAt(l[0] + 30, l[1]) },
        7 => return .{ .in = heldAt(l[0] + 60, l[1]) },
        8 => return .{ .in = heldAt(l[0] + 90, l[1]) },
        9 => return .{ .in = liftAt(l[0] + 90, l[1]) },
        10 => return .{ .in = pointer(-1e9, -1e9), .snap = "dragged" },
        // Drag the inspector divider and the bottom divider a little (they stay for the next pictures).
        11 => return .{ .in = pointer(r[0], r[1]) },
        12 => return .{ .in = pressAt(r[0], r[1]) },
        13 => return .{ .in = heldAt(r[0] - 40, r[1]) },
        14 => return .{ .in = liftAt(r[0] - 40, r[1]) },
        // Drag the sidebar divider all the way left: it snaps shut.
        15 => return .{ .in = pointer(l[0], l[1]) },
        16 => return .{ .in = pressAt(l[0], l[1]) },
        17 => return .{ .in = heldAt(l[0] - 150, l[1]) },
        18 => return .{ .in = heldAt(40, l[1]) },
        19 => return .{ .in = liftAt(40, l[1]) },
        20 => return .{ .in = pointer(-1e9, -1e9), .snap = "collapsed" },
        // Hover the (new) inspector divider: the highlight.
        21 => return .{ .in = pointer(r[0], r[1]) },
        22 => return .{ .in = pointer(r[0], r[1] + 5) },
        23 => return .{ .in = pointer(r[0], r[1] + 5), .snap = "hover" },
        // Click the Inspector button: the pane goes away (and the right edge is the centre's).
        24 => return .{ .in = pressAt(center(app.right_btn)[0], center(app.right_btn)[1]) },
        25 => return .{ .in = liftAt(center(app.right_btn)[0], center(app.right_btn)[1]) },
        26 => return .{ .in = pointer(-1e9, -1e9), .snap = "inspector-hidden" },
        // Bring it back and re-open the sidebar from its toggle button.
        27 => return .{ .in = pressAt(center(app.right_btn)[0], center(app.right_btn)[1]) },
        28 => return .{ .in = liftAt(center(app.right_btn)[0], center(app.right_btn)[1]) },
        29 => return .{ .in = pressAt(center(app.left_btn)[0], center(app.left_btn)[1]) },
        30 => return .{ .in = liftAt(center(app.left_btn)[0], center(app.left_btn)[1]) },
        31 => return .{ .in = pointer(-1e9, -1e9) },
        else => return null,
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var snapshot_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--snapshot") and i + 1 < args.len) {
            i += 1;
            snapshot_dir = args[i];
        } else {
            std.debug.print("usage: split [--snapshot DIR]\n", .{});
            return;
        }
    }

    var app: App = .{};
    // The scripted run draws the full script in a wide window, then the same state (the sizes the
    // script left) squeezed into a narrow one: the panes shrink, the stored sizes do not.
    try run(gpa, arena, &app, 1100, 660, snapshot_dir, false);
    if (snapshot_dir != null) try run(gpa, arena, &app, 520, 560, snapshot_dir, true);
}

fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, app: *App, w: u32, h: u32, snapshot_dir: ?[]const u8, narrow: bool) !void {
    var win = try vass.platform.Window.init(gpa, .{ .title = "Split panes", .width = w, .height = h, .resizable = true, .hidden = snapshot_dir != null, .min_width = 360, .min_height = 300 });
    defer win.deinit();
    var list = vass.DisplayList.init(gpa);
    defer list.deinit();

    const theme: vass.ui.Theme = .{ .card_radius = 12 };
    var input: ui_mod.Input = .{};
    var live: Live = .{ .app = app, .win = &win, .list = &list, .input = &input, .theme = theme };
    win.setFrameCallback(&live, Live.onResize);

    var n: u32 = 0;
    var running = true;
    while (running) : (n += 1) {
        while (vass.platform.pollEvent()) |ev| switch (ev) {
            .quit, .close_requested => running = false,
            else => if (snapshot_dir == null) input.feed(ev, win.id()),
        };
        var snap: ?[]const u8 = null;
        if (snapshot_dir != null) {
            const time = @as(f64, @floatFromInt(n)) * 0.016;
            if (narrow) {
                input = pointer(-1e9, -1e9);
                if (n == 3) snap = "narrow";
                if (n >= 3) running = false;
            } else if (script(app, n)) |st| {
                input = st.in;
                snap = st.snap;
            } else running = false;
            input.time = time;
        } else input.time = @as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0;
        if (snap) |name| win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/split-{s}.bmp", .{ snapshot_dir.?, name }, 0);
        if (running or snap != null) live.draw(input);
        input.endFrame();
        vass.platform.sleepMs(if (snapshot_dir != null) 4 else 16);
    }
}

/// Draws one frame. The main loop and the window's resize callback both call it, so the
/// window keeps reflowing while the OS is dragging an edge (the loop is blocked then).
const Live = struct {
    app: *App,
    win: *vass.platform.Window,
    list: *vass.DisplayList,
    input: *ui_mod.Input,
    theme: vass.ui.Theme,

    fn draw(l: *Live, in: ui_mod.Input) void {
        l.list.reset();
        var ui = Ui.init(l.list, l.win, in, l.theme);
        ui.state = &l.app.state;
        frame(l.app, &ui);
        ui.finish();
        l.win.render(l.list, l.theme.bg);
    }

    /// Resize callback: an idle frame (no click or key replayed, clock untouched).
    fn onResize(ctx: ?*anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx.?));
        l.draw(l.input.idle());
    }
};
