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
//! The pattern, in short (see the README, "Several windows"):
//!   * One `Win` record per window, heap-allocated so its address never changes while the frame
//!     callback is registered: its own `Window`, `Input`, `ui.State`, `DisplayList` and the
//!     state of its widgets that need one. Create with `Window.create`, free with `destroy`.
//!   * Shared app data (`Doc`, the document list) lives outside the windows; every window reads it
//!     each frame, so an edit made in one shows in the others on the next frame.
//!   * Every event is fed to every window's `Input` (`input.feed(ev, window.id())` keeps only its own).
//!   * Windows are destroyed between frames, never from their own frame, so a click in a window
//!     only records what it wants (`App.want_*`) and the loop does it afterwards.
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Ui = vass.Ui;
const ui_mod = vass.ui;
const Window = vass.platform.Window;

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

/// Everything that belongs to one window.
const Win = struct {
    app: *App,
    kind: Kind,
    doc: ?*Doc = null,
    win: *Window,
    list: vass.DisplayList,
    input: ui_mod.Input = .{},
    state: ui_mod.State = .{},
    /// Widget state that must outlive a frame (one dropdown per document window).
    dropdown: ui_mod.DropdownState = .{},
    /// Set by a close request; the loop destroys the window after the frame.
    dead: bool = false,
    /// The title last given to the OS, to call `setTitle` only when it changes.
    shown_title: [320]u8 = undefined,
    shown_len: usize = 0,
    /// Rectangles of the last frame, for the scripted run to aim at.
    rects: struct { title: Rect = zero, counter: Rect = zero, btn_new: Rect = zero, btn_inspector: Rect = zero, btn_close: Rect = zero } = .{},

    const zero: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

    fn draw(w: *Win, in: ui_mod.Input) void {
        w.list.reset();
        var ui = Ui.init(&w.list, w.win, in, theme);
        ui.state = &w.state;
        switch (w.kind) {
            .main => mainFrame(w, &ui),
            .doc => docFrame(w, &ui),
            .inspector => inspectorFrame(w, &ui),
        }
        ui.finish();
        w.win.render(&w.list, theme.bg);
    }

    /// This window's resize callback: an idle frame (no click or key replayed, clock untouched).
    /// It fires only for this window's own events, so a drag on one does not redraw the others.
    fn onResize(ctx: ?*anyopaque) void {
        const w: *Win = @ptrCast(@alignCast(ctx.?));
        w.draw(w.input.idle());
    }

    /// Keeps the OS title in step with `str`.
    fn setTitleIfChanged(w: *Win, str: []const u8) void {
        const n = @min(str.len, w.shown_title.len);
        if (std.mem.eql(u8, w.shown_title[0..w.shown_len], str[0..n])) return;
        @memcpy(w.shown_title[0..n], str[0..n]);
        w.shown_len = n;
        w.win.setTitle(str);
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    hidden: bool,
    running: bool = true,
    docs: std.ArrayList(*Doc) = .empty,
    wins: std.ArrayList(*Win) = .empty,
    inspector: ?*Win = null,
    /// The document window with keyboard focus, and the last document that had it.
    focused: ?*Win = null,
    last_doc: ?*Doc = null,
    next_doc: u32 = 1,
    /// Document windows opened so far: where the next one cascades to.
    opened: u32 = 0,
    // What clicks asked for this frame; done by `applyWants` between frames.
    want_new: bool = false,
    want_inspector: bool = false,
    want_close_all: bool = false,
    want_open: ?*Doc = null,

    fn deinit(app: *App) void {
        // Last in, first out; the main window is first in the list, so it goes last.
        while (app.wins.items.len > 0) app.destroyAt(app.wins.items.len - 1);
        app.wins.deinit(app.gpa);
        for (app.docs.items) |d| d.deinit(app.gpa);
        app.docs.deinit(app.gpa);
    }

    fn find(app: *App, window_id: u32) ?*Win {
        for (app.wins.items) |w| if (w.win.id() == window_id) return w;
        return null;
    }

    fn openCount(app: *const App) usize {
        var n: usize = 0;
        for (app.wins.items) |w| {
            if (w.kind == .doc and !w.dead) n += 1;
        }
        return n;
    }

    fn mainWin(app: *App) *Win {
        return app.wins.items[0];
    }

    // ---- windows ------------------------------------------------------------------------------

    fn addWin(app: *App, kind: Kind, doc: ?*Doc, opts: vass.platform.WindowOptions) !*Win {
        var o = opts;
        o.hidden = app.hidden;
        const w = try app.gpa.create(Win);
        errdefer app.gpa.destroy(w);
        const sw = try Window.create(app.gpa, o);
        errdefer sw.destroy();
        w.* = .{ .app = app, .kind = kind, .doc = doc, .win = sw, .list = vass.DisplayList.init(app.gpa) };
        errdefer w.list.deinit();
        try app.wins.append(app.gpa, w);
        // `w` has its final address: register the resize callback (resizable windows only).
        if (o.resizable) sw.setFrameCallback(w, Win.onResize);
        if (kind == .doc) sw.startTextInput(); // text input is per window
        if (doc) |d| d.win = w;
        return w;
    }

    fn destroyAt(app: *App, i: usize) void {
        const w = app.wins.orderedRemove(i);
        if (w.doc) |d| d.win = null;
        if (app.focused == w) app.focused = null;
        if (app.inspector == w) app.inspector = null;
        w.win.destroy(); // clears its callback; the other windows are untouched
        w.list.deinit();
        app.gpa.destroy(w);
    }

    fn openMain(app: *App) !void {
        const area = vass.platform.usableBounds();
        const w = try app.addWin(.main, null, .{
            .title = "Windows",
            .width = main_w,
            .height = main_h,
            .resizable = true,
            .min_width = 380,
            .min_height = 360,
            .position = .{ area.x + 40, area.y + 40 },
        });
        _ = w;
    }

    fn openDocWindow(app: *App, d: *Doc) !void {
        // Cascade in the strip right of the main window, so new windows never sit exactly on top of each other.
        const area = vass.platform.usableBounds();
        const free: Rect = .{ .x = area.x + main_w + 60, .y = area.y, .w = area.w - main_w - 60, .h = area.h };
        const pos = vass.platform.cascadeIn(free, app.opened, doc_w, doc_h);
        app.opened += 1;
        const w = try app.addWin(.doc, d, .{
            .title = "Document",
            .width = doc_w,
            .height = doc_h,
            .resizable = true,
            .min_width = 360,
            .min_height = 300,
            .position = pos,
        });
        app.last_doc = d;
        w.state.focusOn(&d.body);
    }

    fn newDoc(app: *App) !void {
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
        try app.openDocWindow(d);
    }

    fn openInspector(app: *App) !void {
        if (app.inspector) |w| {
            w.win.raise();
            return;
        }
        const area = vass.platform.usableBounds();
        app.inspector = try app.addWin(.inspector, null, .{
            .title = "Inspector",
            .width = insp_w,
            .height = insp_h,
            // A tool panel: floats above the documents and never takes keyboard focus from them.
            .always_on_top = true,
            .focusable = false,
            .position = .{ area.x + area.w - insp_w - 24, area.y + 24 },
        });
    }

    /// Does what the clicks of the last frame asked for. Between frames, so no window is destroyed
    /// (or added to the list) while one is being drawn.
    fn applyWants(app: *App) void {
        if (app.want_new) {
            app.want_new = false;
            app.newDoc() catch |e| std.log.err("new window: {s}", .{@errorName(e)});
        }
        if (app.want_inspector) {
            app.want_inspector = false;
            app.openInspector() catch |e| std.log.err("inspector: {s}", .{@errorName(e)});
        }
        if (app.want_close_all) {
            app.want_close_all = false;
            for (app.wins.items) |w| if (w.kind != .main) {
                w.dead = true;
            };
        }
        if (app.want_open) |d| {
            app.want_open = null;
            if (d.win) |w| {
                w.win.raise();
            } else if (app.openCount() < max_open) {
                app.openDocWindow(d) catch |e| std.log.err("reopen: {s}", .{@errorName(e)});
            }
        }
        // Windows that asked to close go now.
        var i = app.wins.items.len;
        while (i > 0) {
            i -= 1;
            if (app.wins.items[i].dead) app.destroyAt(i);
        }
    }

    fn requestClose(app: *App, w: *Win) void {
        if (w.kind == .main) app.running = false else w.dead = true;
    }

    // ---- events -------------------------------------------------------------------------------

    fn feedAll(app: *App, ev: vass.platform.Event) void {
        // Each window's Input keeps only the events of its own window.
        for (app.wins.items) |w| w.input.feed(ev, w.win.id());
    }

    fn handle(app: *App, ev: vass.platform.Event) void {
        switch (ev) {
            .quit => app.running = false,
            // The close button of one window: only that window goes (the main one quits).
            .close_requested => |id| if (app.find(id)) |w| app.requestClose(w),
            .key_down => |k| {
                if (k.mods.cmd and k.code == 'w') {
                    if (app.find(k.window)) |w| app.requestClose(w);
                } else app.feedAll(ev);
            },
            .focus_gained => |id| {
                if (app.find(id)) |w| if (w.kind == .doc) {
                    app.focused = w;
                    app.last_doc = w.doc;
                };
                app.feedAll(ev);
            },
            .focus_lost => |id| {
                if (app.focused) |f| if (f.win.id() == id) {
                    app.focused = null;
                };
                app.feedAll(ev);
            },
            else => app.feedAll(ev),
        }
    }

    /// One frame of every window. The inspector goes last: it reads what the others just did.
    fn drawAll(app: *App, now: f64) void {
        for ([_]bool{ false, true }) |inspector_pass| {
            for (app.wins.items) |w| {
                if ((w.kind == .inspector) != inspector_pass) continue;
                w.input.time = now;
                w.draw(w.input);
                w.input.endFrame();
            }
        }
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
    if (ui.button(w.rects.btn_close, "Close all", .{ .disabled = app.wins.items.len < 2 })) app.want_close_all = true;

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
    if (w.state.focus == @as(?*const anyopaque, &d.title)) w.win.setTextInputArea(title_r, 0);

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
        w.state.focusOn(&d.body);
    }
    if (smallButton(ui, .{ .x = bw - m - bwid, .y = row_y, .w = bwid, .h = 30 }, "Redo", d.body.canRedo())) {
        _ = d.body.redo();
        w.state.focusOn(&d.body);
    }

    // The text area fills the rest, above a status line.
    const body_y = row_y + 30 + 10;
    const body_r: Rect = .{ .x = m, .y = body_y, .w = bw - 2 * m, .h = @max(40, bh - body_y - m - 24) };
    const res = ui.textArea(body_r, &d.body, .{ .placeholder = "Write something in this window", .size = 13 });
    // The input method's candidate window belongs next to the caret of THIS window.
    if (w.state.focus == @as(?*const anyopaque, &d.body)) w.win.setTextInputArea(res.input_area, res.caret_x);
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
        const sz = tw.win.logicalSize();
        Row.put(ui, &area, "Size", std.fmt.bufPrint(&buf, "{d:.0} x {d:.0}", .{ sz.w, sz.h }) catch "");
        const pos = tw.win.position();
        Row.put(ui, &area, "Position", std.fmt.bufPrint(&buf, "{d:.0}, {d:.0}", .{ pos[0], pos[1] }) catch "");
        Row.put(ui, &area, "Keyboard focus", yesNo(tw.win.hasFocus()));
        Row.put(ui, &area, "Pointer over it", yesNo(tw.win.hasMouseFocus()));
        Row.put(ui, &area, "Text input on", yesNo(tw.win.textInputActive()));
        Row.put(ui, &area, "Popup open", yesNo(tw.state.popups.last().len > 0));
        const in = tw.input;
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

fn pointerAway(app: *App) void {
    for (app.wins.items) |w| {
        w.input.mouse_x = -1e9;
        w.input.mouse_y = -1e9;
    }
}

fn press(w: *Win, r: Rect) void {
    const c = center(r);
    w.input.mouse_x = c[0];
    w.input.mouse_y = c[1];
    w.input.pressed = true;
    w.input.down = true;
    w.input.mouse_clicks = 1;
}

fn lift(w: *Win, r: Rect) void {
    const c = center(r);
    w.input.mouse_x = c[0];
    w.input.mouse_y = c[1];
    w.input.down = false;
    w.input.released = true;
}

/// Names the BMP of every window for `stage`.
fn armSnapshots(app: *App, arena: std.mem.Allocator, dir: []const u8, stage: []const u8) !void {
    for (app.wins.items) |w| {
        var name_buf: [24]u8 = undefined;
        const name = switch (w.kind) {
            .main => "main",
            .inspector => "inspector",
            .doc => try std.fmt.bufPrint(&name_buf, "doc{d}", .{w.doc.?.id}),
        };
        w.win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/windows-{s}-{s}.bmp", .{ dir, stage, name }, 0);
    }
}

fn runScript(app: *App, arena: std.mem.Allocator, dir: []const u8) !void {
    var n: u32 = 0;
    var bench_ms: ?struct { frames: u32, ms: u64, windows: usize } = null;
    while (app.running) : (n += 1) {
        // Drain what SDL queued (hidden windows send little); the script injects its own input.
        while (vass.platform.pollEvent()) |_| {}
        const clock = @as(f64, @floatFromInt(n)) * 0.3;
        const main_win = app.mainWin();
        switch (n) {
            // Two real clicks on "New window", one on "Open inspector".
            3 => press(main_win, main_win.rects.btn_new),
            4 => lift(main_win, main_win.rects.btn_new),
            5 => press(main_win, main_win.rects.btn_new),
            6 => lift(main_win, main_win.rects.btn_new),
            7 => press(main_win, main_win.rects.btn_inspector),
            8 => lift(main_win, main_win.rects.btn_inspector),
            9 => {
                pointerAway(app);
                // Hidden windows are never given focus by the OS: say the second one has it.
                app.handle(.{ .focus_gained = app.docs.items[1].win.?.win.id() });
            },
            12 => try armSnapshots(app, arena, dir, "1-open"),
            // Typing into one document: a new title (select all, then type) and the first lines of text.
            13 => {
                const w1 = app.docs.items[0].win.?;
                app.handle(.{ .focus_lost = app.docs.items[1].win.?.win.id() });
                app.handle(.{ .focus_gained = w1.win.id() });
                w1.state.focusOn(&w1.doc.?.title);
                w1.input.pushKey(vass.keys.a, .{ .cmd = true });
                w1.input.pushText("Meeting notes");
            },
            14 => {
                const w1 = app.docs.items[0].win.?;
                w1.state.focusOn(&w1.doc.?.body);
                w1.input.pushText("Dear diary,");
                w1.input.pushKey(vass.keys.@"return", .{});
                w1.input.pushText("this text lives in window one only.");
            },
            // The other document has its dropdown open while the first one keeps working.
            15 => app.docs.items[1].win.?.dropdown.popup = .{ .open = true, .fresh = true },
            // The pointer rests on the title field of the first: its tooltip shows after the delay.
            16 => {
                const w1 = app.docs.items[0].win.?;
                const c = center(w1.rects.title);
                w1.input.mouse_x = c[0];
                w1.input.mouse_y = c[1];
            },
            20 => try armSnapshots(app, arena, dir, "2-typed"),
            // The second document's window is closed (its close button); the others carry on.
            21 => app.handle(.{ .close_requested = app.docs.items[1].win.?.win.id() }),
            24 => try armSnapshots(app, arena, dir, "3-closed"),
            // Closing the main window quits.
            26 => app.handle(.{ .close_requested = main_win.win.id() }),
            else => {},
        }
        if (n > 40) break;

        app.drawAll(clock);
        app.applyWants();

        // Timing: the cost of a frame of every window with all four open (no pacing, nothing saved).
        if (n == 12) {
            const windows = app.wins.items.len;
            const frames: u32 = 200;
            const t0 = vass.platform.ticks();
            for (0..frames) |_| app.drawAll(clock);
            bench_ms = .{ .frames = frames, .ms = vass.platform.ticks() - t0, .windows = windows };
        }
        vass.platform.sleepMs(4);
    }
    if (bench_ms) |b| {
        std.debug.print("timing: {d} windows, {d} frames in {d} ms ({d:.2} ms per frame of all windows)\n", .{ b.windows, b.frames, b.ms, @as(f64, @floatFromInt(b.ms)) / @as(f64, @floatFromInt(b.frames)) });
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
            std.debug.print("usage: windows [--snapshot DIR]\n", .{});
            return;
        }
    }

    var app: App = .{ .gpa = gpa, .hidden = snapshot_dir != null };
    defer app.deinit();
    try app.openMain();

    if (snapshot_dir) |dir| {
        try runScript(&app, arena, dir);
        return;
    }

    while (app.running) {
        while (vass.platform.pollEvent()) |ev| app.handle(ev);
        app.drawAll(@as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0);
        app.applyWants();
        vass.platform.sleepMs(16);
    }
}
