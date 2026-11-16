//! A tiny notes app: a scrolling list of wrapped note cards and a text field.
//! Return adds the typed text as the newest note. Everything lives in memory.
//!
//!     zig build notes                      run it
//!     zig build notes -- --snapshot DIR    draw a few frames, save DIR/notes.bmp, exit
//!     zig build notes -- --snapshot DIR --script
//!                                          same, after scripted input: click the
//!                                          field, type "héllo wörld", select all,
//!                                          scroll the list, drag-select text across two
//!                                          lines of a card (deterministic clock)
//! Note bodies are selectable: drag, double/triple click, cmd+C, cmd+A, Escape.
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Ui = vass.Ui;
const ui_mod = vass.ui;

const win_w = 420;
const win_h = 600;
const margin: f32 = 16;
const card_pad: f32 = 14;
const card_gap: f32 = 10;
const body_size: f32 = 14;
const caption_size: f32 = 11;

const seed_notes = [_][]const u8{
    "Ask Sam about the venue for the offsite. Needs to hold forty people, have a projector, and be reachable by train.",
    "Grocery run: oats, lemons, the good olive oil, two ripe avocados, coffee beans (the dark roast), and something for Sunday dinner.",
    "Idea: the notes app should remember where you were. Scroll position, the half-typed draft, and which note you last touched.",
    "https://example.com/a/really/long/link/that/has/no/spaces/at/all/and/must/break/somewhere?utm_source=notes",
    "Short one.",
    "Call the landlord about the boiler.\nThird time this month. Write down the dates so there is a paper trail.",
    "Café résumé naïve — übergroße Straße. Unicode should wrap without ever cutting a character in half: 日本語のテキストも。",
    "Book recommendation from Mira: a slow novel about lighthouse keepers. She said to read it in winter, with tea, and not on the train.",
    "Weekly review: finished the toolkit text input, started on scrolling. Wrapping is next. Keep the diff small and the tests many.",
    "Gift ideas for Dad: a good pocket knife, the bird guide he keeps borrowing, or a day out on the water if the weather holds.",
    "Remember to water the plants.",
    "The very first note. Everything above this one is newer, because the list is newest first and this was written when the app was empty.",
};

/// One note. Heap allocated so the address of `sel` (its selection identity)
/// stays put while the list grows and notes are inserted at the front.
const Note = struct {
    text: []u8,
    sel: ui_mod.SelectState = .{},
};

const App = struct {
    gpa: std.mem.Allocator,
    notes: std.ArrayList(*Note) = .empty,
    field: ui_mod.TextFieldState,
    scroll: ui_mod.ScrollState = .{ .key_scroll = true },
    state: ui_mod.State = .{},

    fn deinit(app: *App) void {
        for (app.notes.items) |n| {
            app.gpa.free(n.text);
            app.gpa.destroy(n);
        }
        app.notes.deinit(app.gpa);
        app.field.deinit();
    }

    fn append(app: *App, text: []const u8, at: usize) !void {
        const note = try app.gpa.create(Note);
        errdefer app.gpa.destroy(note);
        note.* = .{ .text = try app.gpa.dupe(u8, text) };
        errdefer app.gpa.free(note.text);
        try app.notes.insert(app.gpa, at, note);
    }

    /// Adds `text` (trimmed) as the newest note; false if it was blank.
    fn add(app: *App, text: []const u8) !bool {
        const t = std.mem.trim(u8, text, " ");
        if (t.len == 0) return false;
        try app.append(t, 0);
        return true;
    }
};

const Layout = struct {
    title: Rect,
    list: Rect,
    field: Rect,

    fn of(w: f32, h: f32) Layout {
        var area: Rect = .{ .x = 0, .y = 0, .w = w, .h = h };
        var title = area.cutTop(56);
        title = title.inset(0);
        title.x += margin;
        title.w -= 2 * margin;
        title.y += 18;
        var bottom = area.cutBottom(margin + 40 + 8);
        bottom.x += margin;
        bottom.w -= 2 * margin;
        bottom.y += 8;
        bottom.h = 40;
        return .{ .title = title, .list = area, .field = bottom };
    }
};

fn cardHeight(ui: *const Ui, text: []const u8, text_w: f32) f32 {
    return card_pad + ui.lineHeight(caption_size) + 4 + ui.measureWrapped(text, body_size, text_w) + card_pad;
}

/// Draws one frame and handles its input. Returns after the field's Return,
/// having added the note.
fn frame(app: *App, ui: *Ui, lay: Layout) !void {
    const t = ui.theme;
    const total: usize = app.notes.items.len;

    var buf: [32]u8 = undefined;
    ui.labelAt(lay.title.x, lay.title.y - 2, "Notes", .{ .size = 24 });
    ui.label(lay.title, std.fmt.bufPrint(&buf, "{d} notes", .{total}) catch "", .{ .size = 12, .color = t.dim, .@"align" = .right });

    // Measure first: beginScroll needs the content height.
    const card_w = lay.list.w - 2 * margin;
    const text_w = card_w - 2 * card_pad;
    var content_h: f32 = card_gap;
    for (app.notes.items) |n| content_h += cardHeight(ui, n.text, text_w) + card_gap;

    const content = ui.beginScroll(lay.list, &app.scroll, content_h);
    var y = content.y + card_gap;
    for (app.notes.items, 0..) |n, i| {
        const h = cardHeight(ui, n.text, text_w);
        const card: Rect = .{ .x = margin, .y = y, .w = card_w, .h = h };
        y += h + card_gap;
        if (card.y + card.h < lay.list.y or card.y > lay.list.y + lay.list.h) continue;
        ui.card(card);
        ui.labelFmt(.{ .x = card.x + card_pad, .y = card.y + card_pad, .w = text_w, .h = 14 }, "Note {d}", .{total - i}, .{ .size = caption_size, .color = t.accent });
        _ = ui.textSelectable(.{ .x = card.x + card_pad, .y = card.y + card_pad + ui.lineHeight(caption_size) + 4, .w = text_w, .h = 0 }, n.text, &n.sel, .{ .size = body_size });
    }
    ui.endScroll();

    const res = ui.textField(lay.field, &app.field, .{ .placeholder = "Write a note, press Return", .size = body_size });
    if (res.submitted) {
        if (try app.add(app.field.edit.text())) {
            app.field.edit.clear();
            app.field.scroll_x = 0;
            app.scroll.offset = 0; // show the new note
        }
    }
}

const Point = struct { x: f32, y: f32 };

/// For `--script`: a press point near the start of the first line of the first
/// fully visible card with a body of two or more lines, and a drag target in
/// the middle of its second line.
fn pickSelection(app: *const App, ui: *const Ui, lay: Layout) [2]Point {
    const card_w = lay.list.w - 2 * margin;
    const text_w = card_w - 2 * card_pad;
    const lh = ui.lineHeight(body_size);
    var y = lay.list.y - app.scroll.offset + card_gap;
    for (app.notes.items) |n| {
        const h = cardHeight(ui, n.text, text_w);
        const body_y = y + card_pad + ui.lineHeight(caption_size) + 4;
        if (y >= lay.list.y and y + h <= lay.list.y + lay.list.h and ui.measureWrapped(n.text, body_size, text_w) >= 2 * lh) {
            return .{
                .{ .x = margin + card_pad + 30, .y = body_y + lh / 2 },
                .{ .x = margin + card_pad + 150, .y = body_y + lh * 1.5 },
            };
        }
        y += h + card_gap;
    }
    return .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 } };
}

/// Synthetic input for `--script`, by frame number.
fn script(in: *ui_mod.Input, n: u32, lay: Layout, sel_from: Point, sel_to: Point) void {
    const field_c = lay.field.center(0, 0);
    const list_c = lay.list.center(0, 0);
    switch (n) {
        2 => { // click the field
            in.mouse_x = field_c.x;
            in.mouse_y = field_c.y;
            in.pressed = true;
            in.down = true;
        },
        3 => in.down = false,
        4 => in.pushText("héllo wörld"),
        6 => in.pushKey(vass.keys.a, .{ .cmd = true }), // select all
        7 => {
            in.mouse_x = list_c.x;
            in.mouse_y = list_c.y;
        },
        8 => in.wheel_y = -6, // six lines down
        9 => { // press in the first visible card's body ...
            in.mouse_x = sel_from.x;
            in.mouse_y = sel_from.y;
            in.pressed = true;
            in.down = true;
            in.mouse_clicks = 1;
        },
        10 => { // ... drag to the next wrapped line
            in.mouse_x = sel_to.x;
            in.mouse_y = sel_to.y;
        },
        11 => { // release
            in.down = false;
            in.released = true;
        },
        else => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var snapshot_dir: ?[]const u8 = null;
    var scripted = false;
    var debug_input = false; // print mouse events and the field's selection
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--snapshot") and i + 1 < args.len) {
            i += 1;
            snapshot_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--script")) {
            scripted = true;
        } else if (std.mem.eql(u8, args[i], "--debug-input")) {
            debug_input = true;
        } else {
            std.debug.print("usage: notes [--snapshot DIR] [--script] [--debug-input]\n", .{});
            return;
        }
    }
    const snap_frame: u32 = if (scripted) 12 else 3;

    var app: App = .{ .gpa = gpa, .field = ui_mod.TextFieldState.init(gpa) };
    defer app.deinit();
    // The seeds are listed newest first.
    for (seed_notes) |n| try app.append(n, app.notes.items.len);

    var win = try vass.platform.Window.init(gpa, .{ .title = "Notes", .width = win_w, .height = win_h });
    defer win.deinit();
    win.startTextInput();
    var list = vass.DisplayList.init(gpa);
    defer list.deinit();

    const theme: vass.ui.Theme = .{ .card_radius = 12 };
    var input: ui_mod.Input = .{};
    var live: Live = .{ .app = &app, .win = &win, .list = &list, .input = &input, .theme = theme, .lay = Layout.of(win_w, win_h) };
    // Redraw while the OS live-resizes the window (the loop below is blocked then).
    win.setFrameCallback(&live, Live.onResize);

    var n: u32 = 0;
    var running = true;
    while (running) : (n += 1) {
        while (vass.platform.pollEvent()) |ev| switch (ev) {
            .quit, .close_requested => running = false,
            // Scripted runs ignore the real mouse and keyboard.
            else => if (!scripted) {
                if (debug_input) switch (ev) {
                    .mouse_down => |m| std.debug.print("down b={d} x={d:.0} y={d:.0} win={d}/{d}\n", .{ m.button, m.x, m.y, m.window, win.id() }),
                    .mouse_up => |m| std.debug.print("up b={d} x={d:.0}\n", .{ m.button, m.x }),
                    .mouse_move => |m| std.debug.print("move x={d:.0} y={d:.0} down={} cur={d} anc={d} drag={}\n", .{ m.x, m.y, input.down, app.field.edit.cursor, app.field.edit.anchor, app.state.drag != null }),
                    else => {},
                };
                input.feed(ev, win.id());
            },
        };
        input.time = if (scripted) @as(f64, @floatFromInt(n)) * 0.016 else @as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0;

        const snap = if (snapshot_dir) |dir| n == snap_frame and dir.len > 0 else false;
        if (snap) win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/notes.bmp", .{snapshot_dir.?}, 0);
        try live.draw(input, if (scripted) n else null);
        if (snap) running = false;

        // The Ui worked on a copy of the input; keep what it consumed.
        input.endFrame();
        vass.platform.sleepMs(16);
    }
}

/// Everything one frame needs, so the main loop and the resize callback draw the same way.
const Live = struct {
    app: *App,
    win: *vass.platform.Window,
    list: *vass.DisplayList,
    input: *ui_mod.Input,
    theme: vass.ui.Theme,
    lay: Layout,

    /// One frame: build the UI from `in` and render it. `script_n` is the frame number of a
    /// scripted run, which injects its own input.
    fn draw(l: *Live, in: ui_mod.Input, script_n: ?u32) !void {
        l.list.reset();
        var ui = Ui.init(l.list, l.win, in, l.theme);
        if (script_n) |n| {
            // The script needs the Ui's text measuring to aim at a card.
            const pts = pickSelection(l.app, &ui, l.lay);
            script(l.input, n, l.lay, pts[0], pts[1]);
            ui.input = l.input.*;
        }
        ui.state = &l.app.state;
        try frame(l.app, &ui, l.lay);
        if (l.app.state.focus != null) l.win.setTextInputArea(l.lay.field, 0);
        l.win.render(l.list, l.theme.bg);
    }

    /// Called by the window while it is being resized: an idle frame, so no click or key is
    /// replayed and `input.time` (hence animations) stays where the last real frame left it.
    fn onResize(ctx: ?*anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx.?));
        l.draw(l.input.idle(), null) catch |e| std.log.warn("resize frame failed: {s}", .{@errorName(e)});
    }
};
