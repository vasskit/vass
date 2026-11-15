//! A showcase of the form controls: checkbox, toggle, radio, segmented control
//! and the multi-line text area, in several states. Fully interactive.
//!
//!     zig build controls                      run it
//!     zig build controls -- --snapshot DIR    draw a few frames, save DIR/controls.bmp, exit
//!                                             (the first text area is focused with a
//!                                             selection across lines)
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Ui = vass.Ui;
const ui_mod = vass.ui;

const win_w = 560;
const win_h = 800;
const margin: f32 = 24;
const row_h: f32 = 26;

const sample =
    "Multi-line text area. It wraps long lines softly to the width of the box, and keeps hard line breaks.\n" ++
    "\n" ++
    "Up and Down move across visual lines, Cmd+Up and Cmd+Down jump to the ends, and the wheel scrolls once the text is taller than the box.";

const App = struct {
    state: ui_mod.State = .{},
    check_a: bool = true,
    check_b: bool = false,
    check_c: bool = true,
    check_d: bool = false,
    tog_a: bool = true,
    tog_b: bool = false,
    tog_c: bool = true,
    radio: usize = 1,
    seg_text: usize = 0,
    seg_icons: usize = 1,
    seg_mixed: usize = 0,
    seg_fit: usize = 2,
    seg_off: usize = 1,
    notes: ui_mod.TextAreaState,
    composer: ui_mod.TextAreaState,
    empty: ui_mod.TextAreaState,
    sent: usize = 0,

    fn deinit(app: *App) void {
        app.notes.deinit();
        app.composer.deinit();
        app.empty.deinit();
    }
};

fn heading(ui: *Ui, x: f32, y: f32, str: []const u8) void {
    ui.labelAt(x, y, str, .{ .size = 11, .color = ui.theme.dim, .weight = .semibold });
}

fn frame(app: *App, ui: *Ui, win: ?*vass.platform.Window) void {
    const t = ui.theme;
    const col_w = (win_w - 3 * margin) / 2;
    const left = margin;
    const right = margin * 2 + col_w;
    var y: f32 = 22;
    ui.labelAt(margin, y, "Controls", .{ .size = 24 });
    y += 52;

    // Left column: checkbox, toggle, radio.
    var ly = y;
    heading(ui, left, ly, "CHECKBOX");
    ly += 22;
    _ = ui.checkbox(.{ .x = left, .y = ly, .w = col_w, .h = row_h }, &app.check_a, "Checked", .{});
    ly += row_h;
    _ = ui.checkbox(.{ .x = left, .y = ly, .w = col_w, .h = row_h }, &app.check_b, "Unchecked", .{});
    ly += row_h;
    _ = ui.checkbox(.{ .x = left, .y = ly, .w = col_w, .h = row_h }, &app.check_c, "Disabled, checked", .{ .disabled = true });
    ly += row_h;
    _ = ui.checkbox(.{ .x = left, .y = ly, .w = col_w, .h = row_h }, &app.check_d, "Disabled, unchecked", .{ .disabled = true });
    ly += row_h + 22;

    heading(ui, left, ly, "TOGGLE");
    ly += 22;
    const labels = [_][]const u8{ "Notifications", "Dark mode", "Disabled" };
    const toggles = [_]*bool{ &app.tog_a, &app.tog_b, &app.tog_c };
    for (labels, toggles, 0..) |lbl, v, i| {
        const row: Rect = .{ .x = left, .y = ly, .w = col_w, .h = row_h };
        ui.labelAt(left, row.y + 4, lbl, .{ .color = if (i == 2) t.dim.alpha(110) else t.text });
        _ = ui.toggle(.{ .x = left + col_w - 40, .y = ly, .w = 40, .h = row_h }, v, .{ .disabled = i == 2 });
        ly += row_h + 4;
    }
    ly += 14;

    heading(ui, left, ly, "RADIO");
    ly += 22;
    const choices = [_][]const u8{ "Small", "Medium", "Large" };
    for (choices, 0..) |c, i| {
        if (ui.radio(.{ .x = left, .y = ly, .w = col_w, .h = row_h }, app.radio == i, c, .{}).clicked) app.radio = i;
        ly += row_h;
    }
    _ = ui.radio(.{ .x = left, .y = ly, .w = col_w, .h = row_h }, true, "Disabled, selected", .{ .disabled = true });
    ly += row_h;
    _ = ui.radio(.{ .x = left, .y = ly, .w = col_w, .h = row_h }, false, "Disabled", .{ .disabled = true });

    // Right column: segmented controls.
    var ry = y;
    heading(ui, right, ry, "SEGMENTED");
    ry += 22;
    _ = ui.segmented(.{ .x = right, .y = ry, .w = col_w, .h = 30 }, &.{ .{ .label = "Day" }, .{ .label = "Week" }, .{ .label = "Month" } }, &app.seg_text, .{});
    ry += 42;
    _ = ui.segmented(.{ .x = right, .y = ry, .w = col_w, .h = 30 }, &.{ .{ .icon = .sidebar }, .{ .icon = .search }, .{ .icon = .sliders }, .{ .icon = .more } }, &app.seg_icons, .{});
    ry += 42;
    _ = ui.segmented(.{ .x = right, .y = ry, .w = col_w, .h = 30 }, &.{ .{ .icon = .arrow_left, .label = "Back" }, .{ .icon = .arrow_right, .label = "Next" } }, &app.seg_mixed, .{});
    ry += 42;
    _ = ui.segmented(.{ .x = right, .y = ry, .w = col_w, .h = 30 }, &.{ .{ .label = "A" }, .{ .label = "Longer label" }, .{ .label = "Mid" } }, &app.seg_fit, .{ .equal_width = false });
    ry += 42;
    _ = ui.segmented(.{ .x = right, .y = ry, .w = col_w, .h = 30 }, &.{ .{ .label = "One" }, .{ .label = "Two" } }, &app.seg_off, .{ .disabled = true });
    ry += 30 + 22;

    heading(ui, right, ry, "TEXT AREA, EMPTY");
    ry += 22;
    const empty_r: Rect = .{ .x = right, .y = ry, .w = col_w, .h = 64 };
    _ = ui.textArea(empty_r, &app.empty, .{ .placeholder = "Write something\u{2026}" });

    // Full width below the columns: the text area with content, the composer.
    var by = @max(ly + row_h, ry + 64) + 28;
    heading(ui, margin, by, "TEXT AREA, SCROLLING (FIXED 112 HIGH)");
    by += 22;
    const area_r: Rect = .{ .x = margin, .y = by, .w = win_w - 2 * margin, .h = 112 };
    const res = ui.textArea(area_r, &app.notes, .{ .size = 13 });
    if (win) |w| if (app.state.focus == @as(?*const anyopaque, &app.notes)) w.setTextInputArea(res.input_area, res.caret_x);
    by += 112 + 22;

    heading(ui, margin, by, "AUTO-GROWING, RETURN SENDS (1 TO 4 LINES)");
    by += 22;
    const opts: ui_mod.TextAreaOpts = .{ .placeholder = "Message, Return to send, Shift+Return for a new line", .size = 13, .submit_on_enter = true, .max_lines = 4 };
    const comp_h = ui.measureTextArea(&app.composer, win_w - 2 * margin, opts);
    const comp_r: Rect = .{ .x = margin, .y = by, .w = win_w - 2 * margin, .h = comp_h };
    const cres = ui.textArea(comp_r, &app.composer, opts);
    if (win) |w| if (app.state.focus == @as(?*const anyopaque, &app.composer)) w.setTextInputArea(cres.input_area, cres.caret_x);
    if (cres.submitted and app.composer.edit.text().len > 0) {
        app.sent += 1;
        app.composer.clear();
    }
    var buf: [48]u8 = undefined;
    ui.label(.{ .x = margin, .y = by + comp_h + 8, .w = win_w - 2 * margin, .h = 16 }, std.fmt.bufPrint(&buf, "{d} sent", .{app.sent}) catch "", .{ .size = 11, .color = t.dim });
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
            std.debug.print("usage: controls [--snapshot DIR]\n", .{});
            return;
        }
    }

    var app: App = .{ .notes = ui_mod.TextAreaState.init(gpa), .composer = ui_mod.TextAreaState.init(gpa), .empty = ui_mod.TextAreaState.init(gpa) };
    defer app.deinit();
    try app.notes.edit.setText(sample);
    try app.composer.edit.setText("First line\nSecond line");

    var win = try vass.platform.Window.init(gpa, .{ .title = "Controls", .width = win_w, .height = win_h });
    defer win.deinit();
    win.startTextInput();
    var list = vass.DisplayList.init(gpa);
    defer list.deinit();

    const theme: vass.ui.Theme = .{ .card_radius = 12 };
    var input: ui_mod.Input = .{};

    if (snapshot_dir != null) {
        // A selection from the middle of the first paragraph into the third.
        const text = app.notes.edit.text();
        app.notes.edit.anchor = std.mem.indexOf(u8, text, "wraps").?;
        app.notes.edit.cursor = std.mem.indexOf(u8, text, "Cmd+Up").?;
        app.state.focusOn(&app.notes);
    }

    var n: u32 = 0;
    var running = true;
    while (running) : (n += 1) {
        while (vass.platform.pollEvent()) |ev| switch (ev) {
            .quit, .close_requested => running = false,
            else => if (snapshot_dir == null) input.feed(ev, win.id()),
        };
        input.time = if (snapshot_dir != null) 0 else @as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0;
        list.reset();
        var ui = Ui.init(&list, &win, input, theme);
        ui.state = &app.state;
        frame(&app, &ui, &win);

        const snap = if (snapshot_dir) |dir| n == 3 and dir.len > 0 else false;
        if (snap) win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/controls.bmp", .{snapshot_dir.?}, 0);
        win.render(&list, theme.bg);
        if (snap) running = false;
        input.endFrame();
        vass.platform.sleepMs(16);
    }
}
