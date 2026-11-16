//! Several windows in one app. A main window lists the "documents"; each document opens in a
//! window of its own with a title field, a text area (with undo), a dropdown, a counter and a
//! tooltip; a small always-on-top inspector shows live facts about whichever document window has
//! keyboard focus. Windows come and go at run time, in any order.
//!
//!     zig build windows                      run it
//!     zig build windows -- --snapshot DIR    write windows-1-open-*.bmp (the main window, two
//!                                            documents and the inspector), windows-2-typed-*.bmp
//!                                            (text typed and a title edited in one document, a
//!                                            dropdown open in the other) and windows-3-closed-*.bmp
//!                                            (after one document was closed), one BMP per window,
//!                                            all windows hidden, then exit
//!
//! Keyboard: Cmd+W closes the focused document window (and quits from the main one); the close
//! button does the same. Click a document in the main window to bring its window to the front,
//! or to reopen it if it was closed.
//!
//! The pattern, in short (see the README, "Application loop"):
//!   * A `vass.Runner` owns the windows: each has its own `Window`, `Input`, `ui.State` and
//!     display list, and draws with the `frame` of the state struct it was opened with (`Win`).
//!   * `App` is the program: `event` (Cmd+W, focus tracking) and `update` (what the clicks asked
//!     for) are its hooks, and the shared data (`Doc`) lives in it, outside the windows, so an
//!     edit in one window shows in the others on the next frame.
//!   * Windows are closed with `ctx.close`, from anywhere, their own frame included: the runner
//!     destroys them between frames.
const std = @import("std");
const vass = @import("vass");
const harness = @import("common/harness.zig");

const Rect = vass.Rect;
const Ui = vass.Ui;
const ui_mod = vass.ui;
const AppWindow = vass.app.AppWindow;
const Context = vass.AppContext;

const main_w = 460;
const main_h = 560;
const doc_w = 520;
const doc_h = 420;
const insp_w = 280;
const insp_h = 340;
/// Document windows open at once, and documents in the list.
const max_open = 6;
const max_docs = 12;

const tags = [_][]const u8{ "Draft", "Review", "Done" };
const theme: ui_mod.Theme = .{ .card_radius = 12 };

const Kind = enum { main, doc, inspector };

/// Shared app data: what a document is, whether or not a window shows it.
const Doc = struct {
    id: u32,
    title: ui_mod.TextFieldState,
    body: ui_mod.TextAreaState,
    counter: u32 = 0,
    tag: usize = 0,
    /// The window showing it, null while closed.
    win: ?*Win = null,

    fn deinit(d: *Doc, gpa: std.mem.Allocator) void {
        d.title.deinit();
        d.body.deinit();
        gpa.destroy(d);
    }
};

/// What belongs to one window besides what the runner keeps (its `Window`, `Input`, `ui.State`).
const Win = struct {
    app: *App,
    kind: Kind,
    doc: ?*Doc = null,
    /// The runner's handle, set once the window is open.
    ref: *AppWindow = undefined,
    /// Widget state that must outlive a frame (one dropdown per document window).
    dropdown: ui_mod.DropdownState = .{},
    /// The title last given to the OS, to call `setTitle` only when it changes.
    shown_title: [320]u8 = undefined,
    shown_len: usize = 0,
    /// Rectangles of the last frame, for the scripted run to aim at.
    rects: struct { title: Rect = zero, counter: Rect = zero, btn_new: Rect = zero, btn_inspector: Rect = zero, btn_close: Rect = zero } = .{},

    const zero: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    pub fn frame(w: *Win, ui: *Ui) void {
        switch (w.kind) {
            .main => mainFrame(w, ui),
            .doc => docFrame(w, ui),
            .inspector => inspectorFrame(w, ui),
        }
    }

    /// Called just before the runner destroys the window: forget it everywhere.
    pub fn windowClosed(w: *Win, ctx: *Context) void {
        _ = ctx;
        const app = w.app;
        if (w.doc) |d| d.win = null;
        if (app.focused == w) app.focused = null;
        if (app.inspector == w) app.inspector = null;
        app.window_count -= 1;
        app.gpa.destroy(w);
    }

    /// Keeps the OS title in step with `str`.
    fn setTitleIfChanged(w: *Win, str: []const u8) void {
        const n = @min(str.len, w.shown_title.len);
        if (std.mem.eql(u8, w.shown_title[0..w.shown_len], str[0..n])) return;
        @memcpy(w.shown_title[0..n], str[0..n]);
        w.shown_len = n;
        w.ref.window.setTitle(str);
    }
};

/// The program: shared data, the keyboard and what clicks asked for.
const App = struct {
    gpa: std.mem.Allocator,
    docs: std.ArrayList(*Doc) = .empty,
    inspector: ?*Win = null,
    /// Windows open, the main one included.
    window_count: usize = 0,
    /// The document window with keyboard focus, and the last document that had it.
    focused: ?*Win = null,
    last_doc: ?*Doc = null,
    next_doc: u32 = 1,
    /// Document windows opened so far: where the next one cascades to.
    opened: u32 = 0,
    // What clicks asked for; done by `update`, between frames.
    want_new: bool = false,
    want_inspector: bool = false,
    want_close_all: bool = false,
    want_open: ?*Doc = null,

    /// After the loop ended and every window is gone.
    fn deinit(app: *App) void {
        for (app.docs.items) |d| d.deinit(app.gpa);
        app.docs.deinit(app.gpa);
    }

    fn openCount(app: *const App) usize {
        var n: usize = 0;
        for (app.docs.items) |d| {
            if (d.win != null) n += 1;
        }
        return n;
    }

    // ---- windows ------------------------------------------------------------------------------

    fn addWin(app: *App, ctx: *Context, kind: Kind, doc: ?*Doc, window: vass.platform.WindowOptions, draw_order: i32) !*Win {
        const w = try app.gpa.create(Win);
        errdefer app.gpa.destroy(w);
        w.* = .{ .app = app, .kind = kind, .doc = doc };
        w.ref = try ctx.open(Win, w, .{
            .window = window,
            .theme = theme,
            .text_input = kind == .doc, // text input is per window
            .draw_order = draw_order,
        });
        app.window_count += 1;
        if (doc) |d| d.win = w;
        return w;
    }

    fn openMain(app: *App, ctx: *Context) !void {
        const area = vass.platform.usableBounds();
        _ = try app.addWin(ctx, .main, null, .{
            .title = "Windows",
            .width = main_w,
            .height = main_h,
            .resizable = true,
            .min_width = 380,
            .min_height = 360,
            .position = .{ area.x + 40, area.y + 40 },
        }, 0);
    }

    fn openDocWindow(app: *App, ctx: *Context, d: *Doc) !void {
        // Cascade in the strip right of the main window, so new windows never sit exactly on top of each other.
        const area = vass.platform.usableBounds();
        const free: Rect = .{ .x = area.x + main_w + 60, .y = area.y, .w = area.w - main_w - 60, .h = area.h };
        const pos = vass.platform.cascadeIn(free, app.opened, doc_w, doc_h);
        app.opened += 1;
        const w = try app.addWin(ctx, .doc, d, .{
            .title = "Document",
            .width = doc_w,
            .height = doc_h,
            .resizable = true,
            .min_width = 360,
            .min_height = 300,
            .position = pos,
        }, 0);
        app.last_doc = d;
        w.ref.state.focusOn(&d.body);
    }

    fn newDoc(app: *App, ctx: *Context) !void {
        if (app.docs.items.len >= max_docs or app.openCount() >= max_open) return;
        const d = try app.gpa.create(Doc);
        errdefer app.gpa.destroy(d);
        d.* = .{ .id = app.next_doc, .title = ui_mod.TextFieldState.init(app.gpa), .body = ui_mod.TextAreaState.init(app.gpa) };
        errdefer d.title.deinit();
        errdefer d.body.deinit();
        var buf: [32]u8 = undefined;
        try d.title.edit.setText(try std.fmt.bufPrint(&buf, "Untitled {d}", .{d.id}));
        d.title.edit.clearHistory();
        try app.docs.append(app.gpa, d);
        app.next_doc += 1;
        errdefer _ = app.docs.pop();
        try app.openDocWindow(ctx, d);
    }

    fn openInspector(app: *App, ctx: *Context) !void {
        if (app.inspector) |w| {
            w.ref.window.raise();
            return;
        }
        const area = vass.platform.usableBounds();
        // A tool panel: floats above the documents and never takes keyboard focus from them. It
        // draws last, since it reads what the others just did.
        app.inspector = try app.addWin(ctx, .inspector, null, .{
            .title = "Inspector",
            .width = insp_w,
            .height = insp_h,
            .always_on_top = true,
            .focusable = false,
            .position = .{ area.x + area.w - insp_w - 24, area.y + 24 },
        }, 1);
    }

    // ---- hooks --------------------------------------------------------------------------------

    pub fn setup(app: *App, ctx: *Context) !void {
        try app.openMain(ctx);
    }

    /// Does what the clicks of the last frame asked for. Between frames, so no window is
    /// destroyed (or opened) while one is being drawn.
    pub fn update(app: *App, ctx: *Context) !void {
        if (app.want_new) {
            app.want_new = false;
            app.newDoc(ctx) catch |e| std.log.err("new window: {s}", .{@errorName(e)});
        }
        if (app.want_inspector) {
            app.want_inspector = false;
            app.openInspector(ctx) catch |e| std.log.err("inspector: {s}", .{@errorName(e)});
        }
        if (app.want_close_all) {
            app.want_close_all = false;
            for (try ctx.windows()) |w| if (!w.main) ctx.close(w);
        }
        if (app.want_open) |d| {
            app.want_open = null;
            if (d.win) |w| {
                w.ref.window.raise();
            } else if (app.openCount() < max_open) {
                app.openDocWindow(ctx, d) catch |e| std.log.err("reopen: {s}", .{@errorName(e)});
            }
        }
    }

    pub fn event(app: *App, ctx: *Context, ev: vass.platform.Event) bool {
        switch (ev) {
            // Cmd+W is the close button of the window that has the keyboard. The loop handles
            // the close button itself: only that window goes (the main one quits).
            .key_down => |k| if (k.mods.cmd and k.code == 'w') {
                if (ctx.find(k.window)) |w| ctx.requestClose(w);
                return true;
            },
            .focus_gained => |id| if (ctx.find(id)) |w| {
                const win = w.userAs(Win);
                if (win.kind == .doc) {
                    app.focused = win;
                    app.last_doc = win.doc;
                }
            },
            .focus_lost => |id| if (app.focused) |f| if (f.ref.id() == id) {
                app.focused = null;
            },
            else => {},
        }
        return false; // the loop feeds it to every window's Input, which keeps only its own
    }

    pub fn script(app: *App, s: *vass.app.Step) !void {
        try runScript(app, s);
    }
};

// ---- the three kinds of window ----------------------------------------------------------------

fn mainFrame(w: *Win, ui: *Ui) void {
    const app = w.app;
    const t = ui.theme;
    var area = (Rect{ .x = 0, .y = 0, .w = ui.bounds.w, .h = ui.bounds.h }).inset(16);
    var buf: [96]u8 = undefined;

    var title_buf: [48]u8 = undefined;
    w.setTitleIfChanged(std.fmt.bufPrint(&title_buf, "Windows ({d} open)", .{app.openCount()}) catch "Windows");

    ui.label(area.cutTop(26), "Documents", .{ .size = 18, .weight = .semibold });
    ui.label(area.cutTop(20), std.fmt.bufPrint(&buf, "{d} documents, {d} open", .{ app.docs.items.len, app.openCount() }) catch "", .{ .size = 12, .color = t.dim });
    _ = area.cutTop(8);

    // Buttons along the bottom.
    var bar = area.cutBottom(34);
    _ = area.cutBottom(8);
    const can_new = app.docs.items.len < max_docs and app.openCount() < max_open;
    const bw = (bar.w - 16) / 3;
    w.rects.btn_new = bar.cutLeft(bw);
    _ = bar.cutLeft(8);
    w.rects.btn_inspector = bar.cutLeft(bw);
    _ = bar.cutLeft(8);
    w.rects.btn_close = bar;
    if (ui.button(w.rects.btn_new, "New window", .{ .disabled = !can_new })) app.want_new = true;
    if (ui.button(w.rects.btn_inspector, "Open inspector", .{ .on = app.inspector != null })) app.want_inspector = true;
    if (ui.button(w.rects.btn_close, "Close all", .{ .disabled = app.window_count < 2 })) app.want_close_all = true;

    // The list: every document, read from the shared data each frame.
    ui.card(area);
    var y = area.y + 8;
    if (app.docs.items.len == 0) {
        ui.label(.{ .x = area.x + 16, .y = y + 6, .w = area.w - 32, .h = 18 }, "No documents yet. Press New window.", .{ .color = t.dim });
    }
    for (app.docs.items) |d| {
        const rr: Rect = .{ .x = area.x + 8, .y = y, .w = area.w - 16, .h = 30 };
        y += 32;
        if (rr.y + rr.h > area.y + area.h) break;
        const open = d.win != null;
        if (ui.listRow(rr, .{ .selected = d.win != null and app.focused == d.win, .radius = 7, .id = ui_mod.idKey(d.id) }).clicked) app.want_open = d;
        const name = d.title.edit.text();
        ui.pushClip(.{ .x = rr.x, .y = rr.y, .w = rr.w - 130, .h = rr.h });
        ui.label(.{ .x = rr.x + 10, .y = rr.y + 7, .w = rr.w - 150, .h = 18 }, if (name.len > 0) name else "(untitled)", .{});
        ui.popClip();
        ui.label(.{ .x = rr.x + rr.w - 10, .y = rr.y + 8, .w = 0, .h = 16 }, std.fmt.bufPrint(&buf, "{s}  |  {d}  |  {s}", .{ tags[d.tag], d.counter, if (open) "open" else "closed" }) catch "", .{ .size = 11, .color = if (open) t.accent else t.dim, .@"align" = .right });
    }
}

fn smallButton(ui: *Ui, r: Rect, label: []const u8, enabled: bool) bool {
    return ui.button(r, label, .{ .disabled = !enabled });
}

fn docFrame(w: *Win, ui: *Ui) void {
    const d = w.doc.?;
    const t = ui.theme;
    const m: f32 = 16;
    const bw = ui.bounds.w;
    const bh = ui.bounds.h;
    var buf: [96]u8 = undefined;

    var tb: [320]u8 = undefined;
    const name = d.title.edit.text();
    w.setTitleIfChanged(std.fmt.bufPrint(&tb, "{s} - Windows", .{if (name.len > 0) name else "Untitled"}) catch "Document");

    // Title field.
    const title_r: Rect = .{ .x = m, .y = m, .w = bw - 2 * m, .h = 32 };
    w.rects.title = title_r;
    _ = ui.textField(title_r, &d.title, .{ .placeholder = "Title", .size = 14 });
    ui.tooltip(title_r, "The title is shared: the main window's list shows it too", .{});

    // Dropdown, counter and undo / redo.
    const row_y = m + 32 + 10;
    _ = ui.dropdown(.{ .x = m, .y = row_y, .w = 130, .h = 30 }, &w.dropdown, &tags, &d.tag, .{});
    const counter_r: Rect = .{ .x = m + 140, .y = row_y, .w = 120, .h = 30 };
    w.rects.counter = counter_r;
    if (ui.button(counter_r, std.fmt.bufPrint(&buf, "Count: {d}", .{d.counter}) catch "Count", .{})) d.counter += 1;
    ui.tooltip(counter_r, "Counts clicks in this document; the main list shows it", .{});
    const bwid: f32 = 56;
    if (smallButton(ui, .{ .x = bw - m - 2 * bwid - 6, .y = row_y, .w = bwid, .h = 30 }, "Undo", d.body.canUndo())) {
        _ = d.body.undo();
        ui.state.?.focusOn(&d.body);
    }
    if (smallButton(ui, .{ .x = bw - m - bwid, .y = row_y, .w = bwid, .h = 30 }, "Redo", d.body.canRedo())) {
        _ = d.body.redo();
        ui.state.?.focusOn(&d.body);
    }

    // The text area fills the rest, above a status line.
    const body_y = row_y + 30 + 10;
    const body_r: Rect = .{ .x = m, .y = body_y, .w = bw - 2 * m, .h = @max(40, bh - body_y - m - 24) };
    // (The text widgets tell the input method where the caret is, through the Ui of THIS window.)
    _ = ui.textArea(body_r, &d.body, .{ .placeholder = "Write something in this window", .size = 13 });
    const text = d.body.edit.text();
    ui.label(.{ .x = m, .y = bh - m - 14, .w = bw - 2 * m, .h = 16 }, std.fmt.bufPrint(&buf, "{d} characters, {d} lines", .{ text.len, std.mem.count(u8, text, "\n") + 1 }) catch "", .{ .size = 11, .color = t.dim });
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

fn inspectorFrame(w: *Win, ui: *Ui) void {
    const app = w.app;
    const t = ui.theme;
    var area = (Rect{ .x = 0, .y = 0, .w = ui.bounds.w, .h = ui.bounds.h }).inset(16);
    ui.label(area.cutTop(24), "Inspector", .{ .size = 16, .weight = .semibold });
    const doc = if (app.focused) |f| f.doc else app.last_doc;
    const live = app.focused != null;
    ui.label(area.cutTop(20), if (doc == null) "No document window yet" else if (live) "Focused document window" else "Last focused (none focused now)", .{ .size = 11.5, .color = if (live) t.accent else t.dim });
    _ = area.cutTop(8);
    const d = doc orelse return;
    var buf: [96]u8 = undefined;
    const target = d.win; // null if its window was closed
    const text = d.body.edit.text();

    const Row = struct {
        fn put(u: *Ui, a: *Rect, key: []const u8, val: []const u8) void {
            const r = a.cutTop(21);
            u.label(r, key, .{ .size = 12, .color = u.theme.dim });
            u.label(.{ .x = r.x + 112, .y = r.y, .w = r.w - 112, .h = r.h }, val, .{ .size = 12 });
        }
    };
    Row.put(ui, &area, "Document", if (d.title.edit.text().len > 0) d.title.edit.text() else "(untitled)");
    Row.put(ui, &area, "Window", if (target != null) "open" else "closed");
    if (target) |tw| {
        const sz = tw.ref.window.logicalSize();
        Row.put(ui, &area, "Size", std.fmt.bufPrint(&buf, "{d:.0} x {d:.0}", .{ sz.w, sz.h }) catch "");
        const pos = tw.ref.window.position();
        Row.put(ui, &area, "Position", std.fmt.bufPrint(&buf, "{d:.0}, {d:.0}", .{ pos[0], pos[1] }) catch "");
        Row.put(ui, &area, "Keyboard focus", yesNo(tw.ref.window.hasFocus()));
        Row.put(ui, &area, "Pointer over it", yesNo(tw.ref.window.hasMouseFocus()));
        Row.put(ui, &area, "Text input on", yesNo(tw.ref.window.textInputActive()));
        Row.put(ui, &area, "Popup open", yesNo(tw.ref.state.popups.last().len > 0));
        const in = tw.ref.input;
        Row.put(ui, &area, "Pointer", if (in.mouse_x > -1e8) (std.fmt.bufPrint(&buf, "{d:.0}, {d:.0}", .{ in.mouse_x, in.mouse_y }) catch "") else "outside");
    }
    Row.put(ui, &area, "Characters", std.fmt.bufPrint(&buf, "{d}", .{text.len}) catch "");
    Row.put(ui, &area, "Counter", std.fmt.bufPrint(&buf, "{d}", .{d.counter}) catch "");
    Row.put(ui, &area, "Status", tags[d.tag]);
    Row.put(ui, &area, "Can undo", yesNo(d.body.canUndo()));
}

// ---- scripted run (--snapshot) ------------------------------------------------------------------

fn center(r: Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

fn docWin(app: *App, i: usize) *Win {
    return app.docs.items[i].win.?;
}

fn press(s: vass.app.Step, w: *Win, r: Rect) void {
    const c = center(r);
    s.to(w.ref).press(c[0], c[1]);
}

fn lift(s: vass.app.Step, w: *Win, r: Rect) void {
    const c = center(r);
    s.to(w.ref).release(c[0], c[1]);
}

/// Names the BMP of every window for `stage`.
fn armSnapshots(s: *vass.app.Step, stage: []const u8) !void {
    for (s.runner.entries.items) |e| {
        const w = e.userAs(Win);
        var name_buf: [24]u8 = undefined;
        const name = switch (w.kind) {
            .main => "main",
            .inspector => "inspector",
            .doc => try std.fmt.bufPrint(&name_buf, "doc{d}", .{w.doc.?.id}),
        };
        try s.to(e).save("windows-{s}-{s}", .{ stage, name });
    }
}

/// What the script does on loop turn `s.n`. The loop injects it as input events, so the app's
/// `event` hook and every window's `Input` see it as they would see a person.
fn runScript(app: *App, s: *vass.app.Step) !void {
    const main_win = s.runner.mainWindow().?.userAs(Win); // closing it ends the run
    switch (s.n) {
        // Two real clicks on "New window", one on "Open inspector".
        3 => press(s.*, main_win, main_win.rects.btn_new),
        4 => lift(s.*, main_win, main_win.rects.btn_new),
        5 => press(s.*, main_win, main_win.rects.btn_new),
        6 => lift(s.*, main_win, main_win.rects.btn_new),
        7 => press(s.*, main_win, main_win.rects.btn_inspector),
        8 => lift(s.*, main_win, main_win.rects.btn_inspector),
        9 => {
            for (s.runner.entries.items) |e| s.to(e).leave(); // the pointer is nowhere
            // Hidden windows are never given focus by the OS: say the second one has it.
            s.to(docWin(app, 1).ref).focus(true);
        },
        12 => try armSnapshots(s, "1-open"),
        // Typing into one document: a new title (select all, then type) and the first lines of text.
        13 => {
            const w1 = docWin(app, 0);
            s.to(docWin(app, 1).ref).focus(false);
            s.to(w1.ref).focus(true);
            w1.ref.state.focusOn(&w1.doc.?.title);
            s.to(w1.ref).key(vass.keys.a, .{ .cmd = true });
            s.to(w1.ref).text("Meeting notes");
        },
        14 => {
            const w1 = docWin(app, 0);
            w1.ref.state.focusOn(&w1.doc.?.body);
            s.to(w1.ref).text("Dear diary,");
            s.to(w1.ref).key(vass.keys.@"return", .{});
            s.to(w1.ref).text("this text lives in window one only.");
        },
        // The other document has its dropdown open while the first one keeps working.
        15 => docWin(app, 1).dropdown.popup = .{ .open = true, .fresh = true },
        // The pointer rests on the title field of the first: its tooltip shows after the delay.
        16 => {
            const w1 = docWin(app, 0);
            const c = center(w1.rects.title);
            s.to(w1.ref).move(c[0], c[1]);
        },
        20 => try armSnapshots(s, "2-typed"),
        // The second document's window is closed (its close button); the others carry on.
        21 => s.inject(.{ .close_requested = docWin(app, 1).ref.id() }),
        24 => try armSnapshots(s, "3-closed"),
        // Closing the main window quits.
        26 => s.inject(.{ .close_requested = main_win.ref.id() }),
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const env = try harness.start(init, "windows", .{}) orelse return;
    var app: App = .{ .gpa = env.gpa };
    defer app.deinit();

    var r = if (env.cli.snapshot_dir) |dir|
        vass.Runner.initScripted(env.gpa, .{}, .{ .dir = dir, .clock_step = 0.3, .sleep_ms = 4, .hold = env.cli.hold, .max_frames = 100 })
    else
        vass.Runner.init(env.gpa, .{});
    defer r.deinit();
    r.use(App, &app);
    try r.run();
}
