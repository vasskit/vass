//! A showcase of the form controls: checkbox, toggle, radio, segmented control
//! and the multi-line text area, in several states. Fully interactive; the scrolling
//! text area has Undo / Redo buttons beside its heading (Cmd+Z / Cmd+Shift+Z work too).
//!
//!     zig build controls                      run it
//!     zig build controls -- --snapshot DIR    draw a few frames, save DIR/controls.bmp, then
//!                                             DIR/controls-focus.bmp (nine Tab presses: the
//!                                             focus ring on the second segmented control), then
//!                                             a scripted run through the text input group:
//!                                             DIR/controls-text-word.bmp (a word selected by a
//!                                             double click), controls-text-composition.bmp (an
//!                                             input-method pre-edit, fed synthetically),
//!                                             controls-text-menu.bmp (the right-click menu) and
//!                                             controls-text-password.bmp (a password field with
//!                                             a selection); exit (in controls.bmp the first
//!                                             text area is focused with a selection across lines)
//!
//! Keyboard: Tab / Shift+Tab move between all controls; Space / Enter toggle checkboxes and
//! switches and select radios; Left / Right (Home / End) change a focused segmented control;
//! the text areas take Tab out of the way (the first two keep it as focus movement).
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Ui = vass.Ui;
const ui_mod = vass.ui;

const win_w = 560;
const win_h = 886;
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
    /// The "Text input" group: a password field and a field holding combining marks and emoji.
    pw: ui_mod.TextFieldState,
    marks: ui_mod.TextFieldState,
    /// Where those two were drawn this frame, for the scripted snapshots to aim at.
    pw_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    marks_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Where the "Text input" group ends this frame (below the field and the emoji samples).
    input_bottom: f32 = 0,

    fn deinit(app: *App) void {
        app.notes.deinit();
        app.composer.deinit();
        app.empty.deinit();
        app.pw.deinit();
        app.marks.deinit();
    }
};

fn heading(ui: *Ui, x: f32, y: f32, str: []const u8) void {
    ui.labelAt(x, y, str, .{ .size = 11, .color = ui.theme.dim, .weight = .semibold });
}

/// A small text button; a disabled one is drawn dim and never reports a click.
fn smallButton(ui: *Ui, r: Rect, label: []const u8, enabled: bool) bool {
    if (enabled) return ui.button(r, label, .{});
    ui.list.rrect(r, ui.theme.card_radius, ui.theme.card);
    ui.list.text(r.x + r.w / 2, r.y + (r.h - 14) / 2, ui.theme.font_button, ui.theme.dim.alpha(90), .center, label);
    return false;
}

fn frame(app: *App, ui: *Ui, win: ?*vass.platform.Window) void {
    _ = win; // the text widgets tell the input method where the caret is themselves
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

    // Text input: a password field (bullets, no copy or cut, double click selects all) and a
    // field with a combining accent, a family emoji and a flag, which move, select and delete as
    // one character each. Right click for the context menu; the input method's pre-edit is
    // drawn inline.
    var gy = ry + 64 + 22;
    heading(ui, right, gy, "TEXT INPUT");
    gy += 22;
    app.pw_rect = .{ .x = right, .y = gy, .w = col_w, .h = 32 };
    _ = ui.textField(app.pw_rect, &app.pw, .{ .placeholder = "Password", .password = true, .size = 13 });
    gy += 40;
    app.marks_rect = .{ .x = right, .y = gy, .w = col_w, .h = 32 };
    _ = ui.textField(app.marks_rect, &app.marks, .{ .placeholder = "Combining marks and emoji", .size = 13 });
    gy += 32 + 10;

    // Emoji are drawn in colour from the system emoji font, one glyph per sequence: a flag, a
    // ZWJ family, a skin tone, a keycap, a heart with U+FE0F, then inside a sentence, then CJK
    // from the fallback fonts.
    const label_opts: ui_mod.LabelOpts = .{ .size = 13 };
    ui.labelAt(right, gy, "\u{1F1F3}\u{1F1EC}  \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}  \u{1F44D}\u{1F3FD}  1\u{FE0F}\u{20E3}  \u{2764}\u{FE0F}", label_opts);
    gy += 22;
    ui.labelAt(right, gy, "Shipped \u{1F680} on time, caf\u{E9} \u{2615} after!", label_opts);
    gy += 22;
    ui.labelAt(right, gy, "\u{4F60}\u{597D}  \u{3053}\u{3093}\u{306B}\u{3061}\u{306F}  \u{D55C}\u{AD6D}\u{C5B4}", label_opts);
    gy += 18;
    app.input_bottom = gy;

    // Full width below the columns: the text area with content, the composer.
    var by = @max(ly + row_h, @max(ry + 64, app.input_bottom)) + 28;
    heading(ui, margin, by, "TEXT AREA, SCROLLING (FIXED 112 HIGH)");
    // Undo / Redo for the text area, level with its heading: dim while there is nothing to do.
    const btn_w: f32 = 52;
    const btn_y = by - 4;
    if (smallButton(ui, .{ .x = win_w - margin - 2 * btn_w - 6, .y = btn_y, .w = btn_w, .h = 22 }, "Undo", app.notes.canUndo())) {
        _ = app.notes.undo();
        app.state.focusOn(&app.notes);
    }
    if (smallButton(ui, .{ .x = win_w - margin - btn_w, .y = btn_y, .w = btn_w, .h = 22 }, "Redo", app.notes.canRedo())) {
        _ = app.notes.redo();
        app.state.focusOn(&app.notes);
    }
    by += 22;
    const area_r: Rect = .{ .x = margin, .y = by, .w = win_w - 2 * margin, .h = 112 };
    _ = ui.textArea(area_r, &app.notes, .{ .size = 13 });
    by += 112 + 22;

    heading(ui, margin, by, "AUTO-GROWING, RETURN SENDS (1 TO 4 LINES)");
    by += 22;
    const opts: ui_mod.TextAreaOpts = .{ .placeholder = "Message, Return to send, Shift+Return for a new line", .size = 13, .submit_on_enter = true, .max_lines = 4 };
    const comp_h = ui.measureTextArea(&app.composer, win_w - 2 * margin, opts);
    const comp_r: Rect = .{ .x = margin, .y = by, .w = win_w - 2 * margin, .h = comp_h };
    const cres = ui.textArea(comp_r, &app.composer, opts);
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

    var app: App = .{
        .notes = ui_mod.TextAreaState.init(gpa),
        .composer = ui_mod.TextAreaState.init(gpa),
        .empty = ui_mod.TextAreaState.init(gpa),
        .pw = ui_mod.TextFieldState.init(gpa),
        .marks = ui_mod.TextFieldState.init(gpa),
    };
    defer app.deinit();
    try app.marks.edit.setText("cafe\u{301} \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F1F3}\u{1F1EC}");
    try app.notes.edit.setText(sample);
    try app.composer.edit.setText("First line\nSecond line");

    var win = try vass.platform.Window.init(gpa, .{ .title = "Controls", .width = win_w, .height = win_h, .hidden = snapshot_dir != null });
    defer win.deinit();
    win.startTextInput();
    var list = vass.DisplayList.init(gpa);
    defer list.deinit();

    const theme: vass.ui.Theme = .{ .card_radius = 12 };
    var input: ui_mod.Input = .{};
    var live: Live = .{ .app = &app, .win = &win, .list = &list, .input = &input, .theme = theme };
    win.setFrameCallback(&live, Live.onResize);

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

        // Second snapshot: no focus, then nine Tabs through the controls in call order
        // (two checkboxes, two switches, three radios, two segmented controls).
        if (snapshot_dir != null and n == 4) {
            app.state.blur();
            for (0..9) |_| input.pushKey(vass.keys.tab, .{});
        }
        const snap = if (snapshot_dir) |dir| n == 3 and dir.len > 0 else false;
        const snap_focus = if (snapshot_dir) |dir| n == 7 and dir.len > 0 else false;
        if (snap) win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/controls.bmp", .{snapshot_dir.?}, 0);
        if (snap_focus) win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/controls-focus.bmp", .{snapshot_dir.?}, 0);
        if (snapshot_dir != null and n >= 8) {
            if (script(&app, &win, &input, snapshot_dir.?, arena, n)) running = false;
        }
        live.draw(input);
        input.endFrame();
        vass.platform.sleepMs(16);
    }
}

/// An input-method composition, as the backend would deliver it (`start` and `length` count
/// code points; -1 means not set).
fn composition(str: []const u8, start: i32, length: i32) vass.platform.Composition {
    var c: vass.platform.Composition = .{};
    @memcpy(c.buf[0..str.len], str);
    c.len = @intCast(str.len);
    c.start = start;
    c.length = length;
    return c;
}

fn press(input: *ui_mod.Input, r: Rect, dx: f32, clicks: u8) void {
    input.mouse_x = r.x + dx;
    input.mouse_y = r.y + r.h / 2;
    input.pressed = true;
    input.down = true;
    input.mouse_clicks = clicks;
}

fn release(input: *ui_mod.Input) void {
    input.down = false;
    input.released = true;
}

/// The scripted part of the snapshot run (frame `n` >= 8): synthetic mouse, keys and input-method
/// events against the text input group. Returns true after the last snapshot. Nothing here needs
/// a real input method: the composition is injected into `Input` the way `Input.feed` would.
fn script(app: *App, win: *vass.platform.Window, input: *ui_mod.Input, dir: []const u8, arena: std.mem.Allocator, n: u32) bool {
    const snap = struct {
        fn at(w: *vass.platform.Window, a: std.mem.Allocator, d: []const u8, name: []const u8) void {
            w.snapshot_path = std.fmt.allocPrintSentinel(a, "{s}/controls-text-{s}.bmp", .{ d, name }, 0) catch null;
        }
    }.at;
    switch (n) {
        // A double click on "cafe\u{301}": the word is selected, accent and all, as one letter.
        8 => press(input, app.marks_rect, 24, 2),
        9 => {
            release(input);
            snap(win, arena, dir, "word");
        },
        // The input method starts composing after the word: "ni hao" with the first syllable
        // (the part being converted) highlighted.
        10 => app.marks.edit.moveTo(std.mem.indexOf(u8, app.marks.edit.text(), " ").? + 1, false),
        11 => input.composition = composition("ni hao", 0, 2),
        12 => snap(win, arena, dir, "composition"),
        // Cancelled; then a right click on the field opens the context menu.
        13 => {
            input.composition = .{};
            input.mouse_x = app.marks_rect.x + 30;
            input.mouse_y = app.marks_rect.y + 16;
            input.right_pressed = true;
        },
        14 => snap(win, arena, dir, "menu"),
        15 => input.pushKey(vass.keys.escape, .{}),
        // The password field: type, then select the last two characters with Shift+Left.
        16 => press(input, app.pw_rect, 40, 1),
        17 => {
            release(input);
            input.pushText("hunter2!");
        },
        18 => {
            input.pushKey(vass.keys.left, .{ .shift = true });
            input.pushKey(vass.keys.left, .{ .shift = true });
        },
        19 => snap(win, arena, dir, "password"),
        20 => return true,
        else => {},
    }
    return false;
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
        frame(l.app, &ui, l.win);
        ui.finish();
        l.win.render(l.list, l.theme.bg);
    }

    /// Resize callback: an idle frame (no click or key replayed, clock untouched).
    fn onResize(ctx: ?*anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx.?));
        l.draw(l.input.idle());
    }
};

