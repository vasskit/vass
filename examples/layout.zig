//! A small app shell built entirely with `vass.Layout`: a toolbar, a sidebar with a list, a
//! scrolling content column (a wrapped paragraph, a wrapping row of chips, a form, an activity
//! list) and a footer with `space_between`. No rectangle is computed by hand: the tree is
//! declared, solved for the window, and the widgets are then called with the rects. The
//! window is resizable and reflows live while the edge is dragged.
//!
//!     zig build layout                      run it (the Outlines checkbox draws every node's rect)
//!     zig build layout -- --snapshot DIR    save DIR/layout-wide.bmp, layout-narrow.bmp and
//!                                           layout-outlines.bmp (narrow, outlines on, scrolled), exit
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Ui = vass.Ui;
const Node = vass.layout.Node;
const ui_mod = vass.ui;

const sidebar_items = [_][]const u8{
    "Overview", "Inbox",    "Drafts",   "Sent",      "Archive", "Starred",  "Projects",
    "Billing",  "Settings", "Team",     "Reports",   "Imports", "Exports",  "Templates",
    "Audit log", "Trash",
};
const chip_labels = [_][]const u8{ "design", "layout", "zig", "flex", "immediate mode", "no arithmetic", "wrap", "reflow", "resize", "hug", "grow", "measured" };
const paragraph =
    "Every box below is placed by the layout pass. Resize the window and this paragraph rewraps, " ++
    "the chips flow onto new lines, the sidebar takes a share of the width, and the content column " ++
    "scrolls once it no longer fits. Widgets are still called with a Rect each frame; the app just " ++
    "stopped doing the arithmetic.";
const activity = [_]struct { what: []const u8, when: []const u8 }{
    .{ .what = "Layout solved in one pass", .when = "now" },
    .{ .what = "Chips reflowed to 3 lines", .when = "1 min" },
    .{ .what = "Sidebar resized to 27%", .when = "4 min" },
    .{ .what = "Footer re-spaced", .when = "9 min" },
    .{ .what = "Paragraph rewrapped", .when = "12 min" },
    .{ .what = "Form fields stretched", .when = "1 h" },
};

const App = struct {
    state: ui_mod.State = .{},
    side_scroll: ui_mod.ScrollState = .{},
    content_scroll: ui_mod.ScrollState = .{ .arrow_keys = false },
    selected: usize = 0,
    chips_on: [chip_labels.len]bool = .{ true, false, true, false, false, true, false, false, false, false, false, false },
    name: ui_mod.TextFieldState,
    volume: f32 = 0.6,
    notify: bool = true,
    mode: usize = 0,
    outlines: bool = false,
    show_sidebar: bool = true,

    fn deinit(app: *App) void {
        app.name.deinit();
    }
};

fn dimLabel(ui: *Ui, lay: *vass.Layout, str: []const u8) Node {
    return ui.layTextWeighted(lay, str, 11, .semibold, .{});
}

fn outline(ui: *Ui, r: Rect, c: vass.Color) void {
    if (r.w < 1 or r.h < 1) return;
    ui.list.rect(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, c);
    ui.list.rect(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, c);
    ui.list.rect(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, c);
    ui.list.rect(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, c);
}

/// Outlines the nodes `from .. to` (declaration order), coloured by nesting depth.
fn outlines(ui: *Ui, lay: *const vass.Layout, from: usize, to: usize) void {
    const palette = [_]vass.Color{ vass.Color.hex(0xff5c8a), vass.Color.hex(0x4fc3f7), vass.Color.hex(0xffd54f), vass.Color.hex(0x81c784), vass.Color.hex(0xba68c8) };
    for (from..to) |i| {
        const n = lay.at(i);
        outline(ui, lay.rect(n), palette[lay.depthOf(n) % palette.len].alpha(200));
    }
}

fn frame(app: *App, ui: *Ui, arena: std.mem.Allocator) void {
    const t = ui.theme;
    const wide = ui.bounds.w >= 720;
    var lay = vass.Layout.init(arena);

    // ---- declare ------------------------------------------------------------------------
    _ = lay.begin(.{ .dir = .col, .w = .grow(1), .h = .grow(1), .padding = .all(14), .gap = 10 });

    const toolbar = lay.begin(.{ .dir = .row, .h = .fixed(44), .padding = .xy(10, 0), .gap = 8, .cross = .center });
    const side_btn = lay.leaf(.{ .w = .fixed(30), .h = .fixed(30) });
    const title = ui.layTextWeighted(&lay, "Layout demo", 15, .semibold, .{ .w = .grow(1) });
    const seg = if (wide) lay.leaf(.{ .w = .fixed(210), .h = .fixed(28) }) else Node.none;
    const outl = lay.leaf(.{ .w = .fixed(92), .h = .fixed(24) });
    lay.end();

    _ = lay.begin(.{ .dir = .row, .h = .grow(1), .gap = 12 });

    // Sidebar: a share of the width, clamped; a header and a scrolling list.
    var side = Node.none;
    var side_head = Node.none;
    var side_list = Node.none;
    var side_rows: [sidebar_items.len]Node = undefined;
    if (app.show_sidebar) {
        side = lay.begin(.{ .dir = .col, .w = .percent(0.27), .min_w = 150, .max_w = 250, .padding = .all(10), .gap = 8 });
        side_head = dimLabel(ui, &lay, "FILES");
        side_list = lay.begin(.{ .dir = .col, .h = .grow(1), .scroll = .y, .gap = 2, .padding = .{ .right = 8 } });
        for (&side_rows) |*r| r.* = lay.leaf(.{ .h = .fixed(28) });
        lay.end();
        lay.end();
    }

    // Content column: scrolls when it does not fit.
    const content = lay.begin(.{ .dir = .col, .w = .grow(1), .scroll = .y, .padding = .{ .left = 18, .top = 16, .right = 24, .bottom = 18 }, .gap = 12 });
    const heading = ui.layTextWeighted(&lay, "Project overview", 20, .semibold, .{});
    const para = ui.layWrapped(&lay, paragraph, 13, .{});
    const tags_head = dimLabel(ui, &lay, "TAGS");
    _ = lay.begin(.{ .dir = .row, .wrap = true, .gap = 6, .line_gap = 6 });
    var chip_nodes: [chip_labels.len]Node = undefined;
    for (&chip_nodes, chip_labels) |*c, lbl| c.* = lay.leaf(.{ .w = .fixed(ui.chipWidth(lbl, .{}, 11)), .h = .fixed(24) });
    lay.end();
    const form_head = dimLabel(ui, &lay, "SETTINGS");
    const form = lay.begin(.{ .dir = .col, .padding = .all(14), .gap = 10 });
    const name_lbl, const name_f = formRow(ui, &lay, "Name", .{ .w = .grow(1), .h = .fixed(30) });
    const vol_lbl, const vol_f = formRow(ui, &lay, "Volume", .{ .w = .grow(1), .h = .fixed(26) });
    const notify_lbl, const notify_f = formRow(ui, &lay, "Notifications", .{ .w = .fixed(44), .h = .fixed(26) });
    const mode_lbl, const mode_f = formRow(ui, &lay, "Mode", .{ .w = .grow(1), .max_w = 260, .h = .fixed(30) });
    lay.end();
    const act_head = dimLabel(ui, &lay, "ACTIVITY");
    const act = lay.begin(.{ .dir = .col, .padding = .xy(14, 6) });
    var act_dot: [activity.len]Node = undefined;
    var act_what: [activity.len]Node = undefined;
    var act_when: [activity.len]Node = undefined;
    for (activity, 0..) |a, i| {
        _ = lay.begin(.{ .dir = .row, .h = .fixed(30), .gap = 10, .cross = .center });
        act_dot[i] = lay.leaf(.{ .w = .fixed(8), .h = .fixed(8) });
        act_what[i] = ui.layText(&lay, a.what, 12.5, .{ .w = .grow(1) });
        act_when[i] = ui.layText(&lay, a.when, 11.5, .{});
        lay.end();
    }
    lay.end();
    lay.end(); // content
    lay.end(); // body

    // Footer: three things spread across the width.
    _ = lay.begin(.{ .dir = .row, .h = .fixed(30), .main = .space_between, .cross = .center, .padding = .xy(6, 0) });
    var count_buf: [48]u8 = undefined;
    const count_txt = std.fmt.bufPrint(&count_buf, "{d} of {d} files", .{ app.selected + 1, sidebar_items.len }) catch "";
    const foot_l = ui.layText(&lay, count_txt, 12, .{});
    const foot_btn = lay.leaf(.{ .w = .fixed(96), .h = .fixed(26) });
    const foot_r = ui.layText(&lay, "vass.Layout", 12, .{});
    lay.end();
    lay.end(); // root

    // ---- solve --------------------------------------------------------------------------
    lay.solve(ui.bounds);

    // ---- draw ---------------------------------------------------------------------------
    ui.card(lay.rect(toolbar));
    if (ui.iconButton(lay.rect(side_btn), .sidebar, .{ .icon_size = 18, .active = app.show_sidebar }).clicked) app.show_sidebar = !app.show_sidebar;
    ui.label(lay.rect(title), "Layout demo", .{ .size = 15, .weight = .semibold });
    if (seg != .none) _ = ui.tabs(lay.rect(seg), &.{ "Day", "Week", "Month" }, &app.mode);
    _ = ui.checkbox(lay.rect(outl), &app.outlines, "Outlines", .{});

    if (side != .none) {
        ui.card(lay.rect(side));
        ui.label(lay.rect(side_head), "FILES", .{ .size = 11, .color = t.dim, .weight = .semibold });
        const vp = lay.rect(side_list);
        _ = ui.beginScroll(vp, &app.side_scroll, lay.contentSize(side_list).h);
        lay.scrollTo(side_list, 0, app.side_scroll.offset);
        for (side_rows, sidebar_items, 0..) |rn, name, i| {
            const rr = lay.rect(rn);
            if (rr.y + rr.h < vp.y or rr.y > vp.y + vp.h) continue;
            if (ui.listRow(rr, .{ .selected = app.selected == i, .radius = 7 }).clicked) app.selected = i;
            ui.label(.{ .x = rr.x + 10, .y = rr.y + 6, .w = rr.w - 20, .h = 18 }, name, .{});
        }
        if (app.outlines) outlines(ui, &lay, @intFromEnum(side_list) + 1, lay.subtreeEnd(side_list));
        ui.endScroll();
    }

    ui.card(lay.rect(content));
    _ = ui.beginScroll(lay.rect(content), &app.content_scroll, lay.contentSize(content).h);
    lay.scrollTo(content, 0, app.content_scroll.offset);
    ui.label(lay.rect(heading), "Project overview", .{ .size = 20, .weight = .semibold });
    _ = ui.labelWrapped(lay.rect(para), paragraph, .{ .size = 13, .color = t.dim });
    ui.label(lay.rect(tags_head), "TAGS", .{ .size = 11, .color = t.dim, .weight = .semibold });
    for (chip_nodes, chip_labels, 0..) |cn, lbl, i| {
        const on = app.chips_on[i];
        const hv = ui.chip(lay.rect(cn), lbl, .{ .fill = if (on) t.accent else t.track, .color = if (on) t.accent_text else t.text });
        if (hv.clicked) app.chips_on[i] = !on;
    }
    ui.label(lay.rect(form_head), "SETTINGS", .{ .size = 11, .color = t.dim, .weight = .semibold });
    ui.list.rrect(lay.rect(form), 10, t.bg);
    ui.label(lay.rect(name_lbl), "Name", .{ .color = t.dim });
    _ = ui.textField(lay.rect(name_f), &app.name, .{ .placeholder = "Project name" });
    ui.label(lay.rect(vol_lbl), "Volume", .{ .color = t.dim });
    _ = ui.slider(lay.rect(vol_f), &app.volume, .{});
    ui.label(lay.rect(notify_lbl), "Notifications", .{ .color = t.dim });
    _ = ui.toggle(lay.rect(notify_f), &app.notify, .{ .width = 40, .height = 22 });
    ui.label(lay.rect(mode_lbl), "Mode", .{ .color = t.dim });
    _ = ui.segmented(lay.rect(mode_f), &.{ .{ .label = "Auto" }, .{ .label = "Light" }, .{ .label = "Dark" } }, &app.mode, .{});
    ui.label(lay.rect(act_head), "ACTIVITY", .{ .size = 11, .color = t.dim, .weight = .semibold });
    ui.list.rrect(lay.rect(act), 10, t.bg);
    for (activity, 0..) |a, i| {
        const d = lay.rect(act_dot[i]);
        ui.list.circle(d.x + d.w / 2, d.y + d.h / 2, 4, if (i == 0) t.good else t.dim.alpha(140));
        ui.label(lay.rect(act_what[i]), a.what, .{ .size = 12.5 });
        ui.label(lay.rect(act_when[i]), a.when, .{ .size = 11.5, .color = t.dim });
    }
    if (app.outlines) outlines(ui, &lay, @intFromEnum(content) + 1, lay.subtreeEnd(content));
    ui.endScroll();

    ui.label(lay.rect(foot_l), count_txt, .{ .size = 12, .color = t.dim });
    if (ui.button(lay.rect(foot_btn), "Reset", .{})) {
        app.selected = 0;
        app.content_scroll.offset = 0;
        app.side_scroll.offset = 0;
    }
    ui.label(lay.rect(foot_r), "vass.Layout", .{ .size = 12, .color = t.dim });

    if (app.outlines) {
        // Everything except the insides of the two scrolling regions (they draw their own, clipped).
        const n = lay.count();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const nd = lay.at(i);
            if (nd == side_list or nd == content) {
                outlines(ui, &lay, i, i + 1);
                i = lay.subtreeEnd(nd) - 1;
                continue;
            }
            outlines(ui, &lay, i, i + 1);
        }
    }
}

/// A form row: a fixed-width label and a control. Returns both nodes.
fn formRow(ui: *Ui, lay: *vass.Layout, label: []const u8, control: vass.layout.Opts) struct { Node, Node } {
    _ = lay.begin(.{ .dir = .row, .gap = 12, .cross = .center });
    const l = ui.layText(lay, label, 12.5, .{ .w = .fixed(104) });
    const c = lay.leaf(control);
    lay.end();
    return .{ l, c };
}

const Size = struct { name: []const u8, w: u32, h: u32, outlines: bool = false, scroll: f32 = 0 };
const snapshots = [_]Size{
    .{ .name = "wide", .w = 980, .h = 700 },
    .{ .name = "narrow", .w = 540, .h = 700 },
    .{ .name = "outlines", .w = 540, .h = 560, .outlines = true, .scroll = 150 },
};

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
            std.debug.print("usage: layout [--snapshot DIR]\n", .{});
            return;
        }
    }

    var app: App = .{ .name = ui_mod.TextFieldState.init(gpa) };
    defer app.deinit();
    try app.name.edit.setText("Aurora");

    if (snapshot_dir) |dir| {
        // One window per size, so the same app state is drawn at several sizes.
        for (snapshots) |s| {
            app.outlines = s.outlines;
            app.content_scroll.offset = s.scroll;
            try run(gpa, arena, &app, s.w, s.h, dir, s.name);
        }
        return;
    }
    try run(gpa, arena, &app, 980, 700, null, "");
}

fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, app: *App, w: u32, h: u32, snapshot_dir: ?[]const u8, name: []const u8) !void {
    var win = try vass.platform.Window.init(gpa, .{ .title = "Layout", .width = w, .height = h, .resizable = true, .hidden = snapshot_dir != null, .min_width = 360, .min_height = 360 });
    defer win.deinit();
    win.startTextInput();
    var list = vass.DisplayList.init(gpa);
    defer list.deinit();

    const theme: vass.ui.Theme = .{ .card_radius = 12 };
    var input: ui_mod.Input = .{};
    var live: Live = .{ .app = app, .win = &win, .list = &list, .input = &input, .theme = theme, .frame_arena = std.heap.ArenaAllocator.init(gpa) };
    defer live.frame_arena.deinit();
    win.setFrameCallback(&live, Live.onResize);

    var n: u32 = 0;
    var running = true;
    while (running) : (n += 1) {
        while (vass.platform.pollEvent()) |ev| switch (ev) {
            .quit, .close_requested => running = false,
            else => if (snapshot_dir == null) input.feed(ev, win.id()),
        };
        input.time = if (snapshot_dir != null) 0 else @as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0;
        const snap = snapshot_dir != null and n == 3;
        if (snap) win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/layout-{s}.bmp", .{ snapshot_dir.?, name }, 0);
        live.draw(input);
        if (snap) running = false;
        input.endFrame();
        vass.platform.sleepMs(16);
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
    frame_arena: std.heap.ArenaAllocator,

    fn draw(l: *Live, in: ui_mod.Input) void {
        l.list.reset();
        _ = l.frame_arena.reset(.retain_capacity);
        var ui = Ui.init(l.list, l.win, in, l.theme);
        ui.state = &l.app.state;
        frame(l.app, &ui, l.frame_arena.allocator());
        ui.finish();
        l.win.render(l.list, l.theme.bg);
    }

    /// Resize callback: an idle frame (no click or key replayed, clock untouched).
    fn onResize(ctx: ?*anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx.?));
        l.draw(l.input.idle());
    }
};
