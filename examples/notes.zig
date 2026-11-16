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
const harness = @import("common/harness.zig");

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
pub fn frame(app: *App, ui: *Ui) !void {
    const lay = Layout.of(win_w, win_h);
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
    const env = try harness.start(init, "notes", .{ .script = true, .debug_input = true }) orelse return;
    const scripted = env.cli.script;

    var app: App = .{ .gpa = env.gpa, .field = ui_mod.TextFieldState.init(env.gpa) };
    defer app.deinit();
    // The seeds are listed newest first.
    for (seed_notes) |n| try app.append(n, app.notes.items.len);

    try harness.run(@This(), env, .{
        .window = .{ .title = "Notes", .width = win_w, .height = win_h },
        .text_input = true,
        .snapshot_frame = if (scripted) 12 else 3,
        // A scripted run ignores the real mouse and keyboard and runs on a fake clock.
        .feed_input = !scripted,
        .fixed_clock = scripted,
        .snapshot_clock_step = 0.016,
    }, &app);
}

/// The script (`--script`): synthetic input aimed at where the cards are.
pub fn step(app: *App, s: *harness.Step) !void {
    if (!s.env.cli.script) return;
    const lay = Layout.of(win_w, win_h);
    // The script needs the Ui's text measuring to aim at a card.
    var ui = s.measureUi();
    const pts = pickSelection(app, &ui, lay);
    script(s.input, s.n, lay, pts[0], pts[1]);
}

/// `--debug-input`: print mouse events and the field's selection.
pub fn event(app: *App, s: *harness.Step, ev: vass.platform.Event) void {
    if (!s.env.cli.debug_input) return;
    switch (ev) {
        .mouse_down => |m| std.debug.print("down b={d} x={d:.0} y={d:.0} win={d}/{d}\n", .{ m.button, m.x, m.y, m.window, s.win.id() }),
        .mouse_up => |m| std.debug.print("up b={d} x={d:.0}\n", .{ m.button, m.x }),
        .mouse_move => |m| std.debug.print("move x={d:.0} y={d:.0} down={} cur={d} anc={d} drag={}\n", .{ m.x, m.y, s.input.down, app.field.edit.cursor, app.field.edit.anchor, s.state.drag != null }),
        else => {},
    }
}
