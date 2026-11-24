//! Paragraph layout: a few hundred blocks of styled text, each laid out once per width with
//! `vass.Paragraph` and kept. Only the blocks near the viewport are laid out (the rest have an
//! estimated height that is corrected when they are), and a frame in which nothing changes lays
//! out nothing: the corner readout shows how many paragraphs were laid out this frame and how
//! long that took.
//!
//! Click to place a caret, drag to select within a block, Left/Right and Up/Down move the caret
//! (across blocks too), Cmd+Left/Right go to the start or end of the line. The window is
//! resizable: a new width lays the visible blocks out again.
//!
//!     zig build paragraphs                      run it
//!     zig build paragraphs -- --snapshot DIR    save DIR/paragraphs-1-initial.bmp, -2-selected, -3-keys,
//!                                               -4-scrolled and -5-follow (the view follows the caret
//!                                               into a block below it), exit
const std = @import("std");
const vass = @import("vass");
const harness = @import("common/harness.zig");

const Ui = vass.Ui;
const Rect = vass.Rect;
const Color = vass.Color;
const Paragraph = vass.Paragraph;
const grapheme = vass.grapheme;
const keys = vass.keys;
const ui_mod = vass.ui;

const body_size: f32 = 15;
const head_size: f32 = 24;
const code_size: f32 = 13;
const block_gap: f32 = 14;
const margin: f32 = 28;
const max_col: f32 = 640;
const block_count = 300;
/// Blocks this far outside the viewport are laid out too, so a short scroll finds them ready.
const overscan: f32 = 200;

const Block = struct {
    text: []const u8,
    runs: []const Paragraph.Run,
    size: f32,
    spacing: f32,
    layout: ?Paragraph = null,
    /// The width `layout` is for.
    layout_w: f32 = 0,
    /// Block height with its gap: from `layout` once there is one, else an estimate.
    height: f32 = 0,
};

const Caret = struct {
    block: usize,
    offset: usize,
    affinity: Paragraph.Affinity = .downstream,
    /// Where Up and Down aim, kept while moving through short lines.
    want_x: ?f32 = null,
};

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    doc: std.heap.ArenaAllocator,
    blocks: []Block = &.{},
    scroll: ui_mod.ScrollState = .{ .arrow_keys = false },
    width: f32 = 0,
    caret: ?Caret = null,
    /// The other end of the selection, in the caret's block.
    anchor: usize = 0,
    dragging: bool = false,
    reveal: bool = false,
    // The readout.
    laid: u32 = 0,
    layout_ns: i96 = 0,
    // What the scripted run aims its mouse at, found while drawing the first frames.
    click_pt: [2]f32 = .{ 0, 0 },
    drag_pt: [2]f32 = .{ 0, 0 },
    /// Show the layout time in the readout (a scripted run shows the count only, so its
    /// snapshots repeat).
    show_time: bool = true,
    /// Display density the layouts were built for.
    density: f32 = 0,

    fn deinit(app: *App) void {
        for (app.blocks) |*b| if (b.layout) |*p| p.deinit(app.gpa);
        app.doc.deinit();
    }

    fn nowNs(app: *const App) i96 {
        return std.Io.Timestamp.now(app.io, .awake).nanoseconds;
    }

    /// The block's layout for the current width, built if it is missing or for another width.
    fn ensure(app: *App, m: Paragraph.Measurer, i: usize) !*Paragraph {
        const b = &app.blocks[i];
        if (b.layout) |*p| if (b.layout_w == app.width) return p;
        const t0 = app.nowNs();
        if (b.layout) |*old| old.deinit(app.gpa);
        b.layout = null;
        b.layout = try Paragraph.init(app.gpa, m, b.text, b.runs, .{ .size = b.size, .width = app.width, .line_spacing = b.spacing });
        b.layout_w = app.width;
        b.height = b.layout.?.height + block_gap;
        app.laid += 1;
        app.layout_ns += app.nowNs() - t0;
        return &b.layout.?;
    }

    /// A guess at a block's height before it is laid out.
    fn estimate(app: *const App, b: *const Block) f32 {
        const chars_per_line = @max(8, app.width / (b.size * 0.5));
        const lines = @ceil(@as(f32, @floatFromInt(b.text.len)) / chars_per_line);
        return @max(1, lines) * @round(b.size * 1.2 * b.spacing) + block_gap;
    }
};

// ---- the document -------------------------------------------------------------------------------

const vocab = [_][]const u8{
    "layout",  "line",     "paragraph", "baseline", "cluster", "caret",   "width",  "word",    "style",    "measure",
    "wrap",    "segment",  "offset",    "block",    "run",     "glyph",   "margin", "scroll",  "selection", "cache",
    "visible", "estimate", "height",    "text",     "break",   "affinity", "frame",  "pointer", "boundary", "ascent",
};

const Rng = struct {
    s: u32,

    fn next(r: *Rng, n: u32) u32 {
        r.s = r.s *% 1664525 +% 1013904223;
        return (r.s >> 8) % n;
    }
};

const Doc = struct {
    a: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Paragraph.Run) = .empty,
    theme: ui_mod.Theme = .{},

    fn add(d: *Doc, str: []const u8, style: vass.gfx.TextStyle, size: ?f32, color: Color, tag: u32) !void {
        try d.text.appendSlice(d.a, str);
        try d.runs.append(d.a, .{ .len = @intCast(str.len), .style = style, .size = size, .color = color, .tag = tag });
    }

    fn plain(d: *Doc, str: []const u8) !void {
        try d.add(str, .{}, null, d.theme.text, 0);
    }

    /// `n` vocabulary words separated by spaces, with a space before the first when `lead`.
    fn words(d: *Doc, rng: *Rng, n: u32, lead: bool) !void {
        var buf: std.ArrayList(u8) = .empty;
        for (0..n) |i| {
            if (i > 0 or lead) try buf.append(d.a, ' ');
            try buf.appendSlice(d.a, vocab[rng.next(vocab.len)]);
        }
        try d.plain(buf.items);
    }

    fn body(d: *Doc, rng: *Rng, index: usize) !void {
        const t = d.theme;
        const sentences = 3 + rng.next(3);
        for (0..sentences) |s| {
            try d.words(rng, 4 + rng.next(5), s > 0);
            switch (rng.next(9)) {
                0 => {
                    try d.plain(" ");
                    try d.add(vocab[rng.next(vocab.len)], .{ .weight = .bold }, null, t.text, 0);
                },
                1 => {
                    try d.plain(" ");
                    try d.add("an emphasised phrase", .{ .italic = true }, null, t.text, 0);
                },
                2 => {
                    try d.plain(" ");
                    try d.add("layout.init()", .{ .mono = true }, code_size, t.warn, 0);
                },
                3 => {
                    try d.plain(" ");
                    try d.add("a link", .{ .underline = true }, null, Color.hex(0x7FB0FF), 1);
                },
                4 => {
                    try d.plain(" ");
                    try d.add("a struck word", .{ .strikethrough = true }, null, t.dim, 0);
                },
                5 => try d.plain(" \u{1F600}"),
                else => {},
            }
            try d.words(rng, 3 + rng.next(5), true);
            try d.plain(".");
        }
        if (index % 7 == 3) try d.plain(" 段落排版测试：这是一个用于演示换行的较长的中文句子，它应该在任意两个汉字之间折行。");
        if (index % 5 == 2) try d.plain(" Family: \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} and a flag \u{1F1E9}\u{1F1EA}.");
    }

    fn heading(d: *Doc, rng: *Rng, index: usize) !void {
        const t = try std.fmt.allocPrint(d.a, "Chapter {d}: {s} and {s}", .{ index / 12 + 1, vocab[rng.next(vocab.len)], vocab[rng.next(vocab.len)] });
        try d.add(t, .{ .weight = .bold }, null, d.theme.text, 0);
    }
};

fn buildDocument(app: *App) !void {
    const a = app.doc.allocator();
    const blocks = try a.alloc(Block, block_count);
    var rng: Rng = .{ .s = 12345 };
    for (blocks, 0..) |*b, i| {
        var d: Doc = .{ .a = a };
        const is_head = i % 12 == 0;
        if (is_head) try d.heading(&rng, i) else try d.body(&rng, i);
        b.* = .{
            .text = d.text.items,
            .runs = d.runs.items,
            .size = if (is_head) head_size else body_size,
            .spacing = if (is_head) 1.1 else 1.3,
        };
    }
    app.blocks = blocks;
}

// ---- the frame ----------------------------------------------------------------------------------

/// Lays out the blocks near the viewport (and the caret's), in order, so each block's top is
/// final once the one above has its real height. Returns the content height.
fn layoutNear(app: *App, m: Paragraph.Measurer, view_h: f32) !f32 {
    if (app.caret) |c| _ = try app.ensure(m, c.block);
    const top = app.scroll.offset - overscan;
    const bottom = app.scroll.offset + view_h + overscan;
    var y: f32 = margin;
    for (app.blocks, 0..) |*b, i| {
        if (y + b.height >= top and y <= bottom) _ = try app.ensure(m, i);
        y += b.height;
    }
    return y;
}

fn blockTop(app: *const App, index: usize) f32 {
    var y: f32 = margin;
    for (app.blocks[0..index]) |b| y += b.height;
    return y;
}

pub fn frame(app: *App, ui: *Ui) !void {
    app.laid = 0;
    app.layout_ns = 0;
    const t = ui.theme;
    const m = ui.paragraphMeasurer();
    const view = ui.bounds;
    const col_w = @floor(@max(120, @min(max_col, view.w - 2 * margin)));
    const col_x = view.x + @floor((view.w - col_w) / 2);
    const density: f32 = if (ui.win) |w| w.density else 1;

    // Layouts depend on the width and the display density: a change of either drops them all
    // and goes back to estimated heights.
    if (col_w != app.width or density != app.density) {
        app.width = col_w;
        app.density = density;
        for (app.blocks) |*b| {
            if (b.layout) |*p| p.deinit(app.gpa);
            b.layout = null;
            b.height = app.estimate(b);
        }
    }

    // Settle the scroll offset before anything is drawn: lay out around it, bring the caret into
    // view if a key asked for that, clamp, and go round again if the offset moved (laying out
    // changes heights, so tops move). Drawing then uses the final offset, once.
    var content_h: f32 = 0;
    var round: u32 = 0;
    var settled = false;
    while (true) : (round += 1) {
        const before = app.scroll.offset;
        content_h = try layoutNear(app, m, view.h);
        if (app.reveal) if (app.caret) |c| {
            const p = &app.blocks[c.block].layout.?;
            const top = blockTop(app, c.block);
            const r = p.caretRect(m, c.offset, c.affinity);
            app.scroll.reveal(view.h, top + r.y - 8, top + r.y + r.h + 8);
        };
        app.scroll.offset = std.math.clamp(app.scroll.offset, 0, @max(0, content_h - view.h));
        if (app.scroll.offset == before) {
            settled = true;
            break;
        }
        if (round >= 3) break;
    }
    // Out of rounds (heights were badly estimated): keep asking, the next frame carries on.
    if (settled) app.reveal = false else ui.requestRedraw();

    const content = ui.beginScroll(view, &app.scroll, content_h);
    var y: f32 = margin;
    var missing = false;
    for (app.blocks, 0..) |*b, i| {
        defer y += b.height;
        const vis_top = app.scroll.offset;
        if (y + b.height < vis_top or y > vis_top + view.h) continue;
        // Never draw a layout made for another width.
        const p = if (b.layout) |*p| (if (b.layout_w == app.width) p else null) else null;
        if (p == null) {
            missing = true;
            continue;
        }
        const ox = col_x;
        const oy = content.y + y;
        const block_rect: Rect = .{ .x = ox, .y = oy, .w = col_w, .h = p.?.height };
        try interact(app, ui, m, i, p.?, block_rect);
        const sel_here = if (app.caret) |c| c.block == i else false;
        if (sel_here) drawSelection(app, ui, m, p.?, ox, oy);
        p.?.draw(ui.list, ox, oy);
        if (sel_here) drawCaret(app, ui, m, p.?, ox, oy);
        if (i == 1) probe(app, p.?, ox, oy);
    }
    ui.endScroll();
    if (missing) ui.requestRedraw();
    if (!ui.input.down) app.dragging = false;

    // The readout.
    const r: Rect = .{ .x = view.x + view.w - 232, .y = view.y + 8, .w = 224, .h = 22 };
    ui.list.rrect(r, 6, t.card.alpha(235));
    const lab: Rect = .{ .x = r.x + 10, .y = r.y + 4, .w = r.w - 20, .h = 16 };
    const opts: ui_mod.LabelOpts = .{ .size = 11, .color = t.dim, .style = .{ .mono = true } };
    if (app.show_time) {
        ui.labelFmt(lab, "laid out {d}   {d} us", .{ app.laid, @divTrunc(app.layout_ns, std.time.ns_per_us) }, opts);
    } else {
        ui.labelFmt(lab, "laid out {d}", .{app.laid}, opts);
    }
    if (ui.input.mouse_y >= 0) ui.setCursor(.text);

    try keyboard(app, ui, m);
}

/// Mouse: a press puts the caret down, a drag from it selects within its block.
fn interact(app: *App, ui: *Ui, m: Paragraph.Measurer, i: usize, p: *const Paragraph, r: Rect) !void {
    const mx = ui.input.mouse_x - r.x;
    const my = ui.input.mouse_y - r.y;
    // The gap below a block belongs to it, so a click between two blocks still lands.
    const hit_rect: Rect = .{ .x = r.x - 12, .y = r.y, .w = r.w + 24, .h = r.h + block_gap };
    if (ui.hit(hit_rect).clicked) {
        const h = p.offsetAt(m, mx, my);
        app.caret = .{ .block = i, .offset = h.offset, .affinity = h.affinity };
        app.anchor = h.offset;
        app.dragging = true;
    } else if (app.dragging and ui.input.down) {
        if (app.caret) |*c| if (c.block == i) {
            const h = p.offsetAt(m, mx, my);
            c.offset = h.offset;
            c.affinity = h.affinity;
        };
    }
}

fn drawSelection(app: *const App, ui: *Ui, m: Paragraph.Measurer, p: *const Paragraph, ox: f32, oy: f32) void {
    const c = app.caret.?;
    if (c.offset == app.anchor) return;
    var rects: [128]Rect = undefined;
    const n = @min(rects.len, p.selectionRects(m, app.anchor, c.offset, &rects));
    for (rects[0..n]) |r| ui.list.rect(.{ .x = ox + r.x, .y = oy + r.y, .w = r.w, .h = r.h }, ui.theme.selection);
}

fn drawCaret(app: *App, ui: *Ui, m: Paragraph.Measurer, p: *const Paragraph, ox: f32, oy: f32) void {
    const c = app.caret.?;
    const r = p.caretRect(m, c.offset, c.affinity);
    ui.list.rect(.{ .x = ox + r.x - 0.75, .y = oy + r.y, .w = 1.5, .h = r.h }, ui.theme.accent);
}

/// Where the scripted run clicks and drags to, taken from the second block while it is on screen.
fn probe(app: *App, p: *const Paragraph, ox: f32, oy: f32) void {
    const first = p.lines[0];
    const last = p.lines[@min(2, p.lines.len - 1)];
    app.click_pt = .{ ox + 90, oy + first.y + first.height / 2 };
    app.drag_pt = .{ ox + 230, oy + last.y + last.height / 2 };
}

// ---- the keyboard -------------------------------------------------------------------------------

fn keyboard(app: *App, ui: *Ui, m: Paragraph.Measurer) !void {
    var i: usize = 0;
    while (i < ui.input.queue_len) {
        const k = switch (ui.input.queue[i]) {
            .key => |k| k,
            else => {
                i += 1;
                continue;
            },
        };
        if (app.caret != null and try moveCaret(app, m, k.code, k.mods)) {
            ui.input.removeEvent(i);
            ui.requestRedraw();
        } else i += 1;
    }
}

/// Moves the caret for an arrow key; false when the key is not one or there is no caret.
fn moveCaret(app: *App, m: Paragraph.Measurer, code: u32, mods: keys.Mods) !bool {
    var c = app.caret.?;
    const p = try app.ensure(m, c.block);
    const last_block = app.blocks.len - 1;
    switch (code) {
        keys.left => {
            if (mods.cmd) {
                c.offset = p.lineStart(c.offset, c.affinity);
                c.affinity = .downstream;
            } else if (c.offset > 0) {
                c.offset = grapheme.prevBoundary(p.text, c.offset);
                c.affinity = .downstream;
            } else if (c.block > 0) {
                c.block -= 1;
                c.offset = (try app.ensure(m, c.block)).text.len;
                c.affinity = .downstream;
            }
            c.want_x = null;
        },
        keys.right => {
            if (mods.cmd) {
                const h = p.lineEnd(c.offset, c.affinity);
                c.offset = h.offset;
                c.affinity = h.affinity;
            } else if (c.offset < p.text.len) {
                c.offset = grapheme.nextBoundary(p.text, c.offset);
                c.affinity = .downstream;
            } else if (c.block < last_block) {
                c.block += 1;
                c.offset = 0;
                c.affinity = .downstream;
            }
            c.want_x = null;
        },
        keys.up, keys.down => {
            const want = c.want_x orelse p.caretRect(m, c.offset, c.affinity).x;
            const moved = if (code == keys.up) p.offsetAbove(m, c.offset, c.affinity, want) else p.offsetBelow(m, c.offset, c.affinity, want);
            if (moved) |h| {
                c.offset = h.offset;
                c.affinity = h.affinity;
            } else if (code == keys.up and c.block > 0) {
                // The previous block's last line: a point below it.
                c.block -= 1;
                const q = try app.ensure(m, c.block);
                const h = q.offsetAt(m, want, q.height + 1);
                c.offset = h.offset;
                c.affinity = h.affinity;
            } else if (code == keys.down and c.block < last_block) {
                c.block += 1;
                const q = try app.ensure(m, c.block);
                const h = q.offsetAt(m, want, 0);
                c.offset = h.offset;
                c.affinity = h.affinity;
            }
            c.want_x = want;
        },
        else => return false,
    }
    app.caret = c;
    app.anchor = c.offset;
    app.reveal = true;
    return true;
}

// ---- the scripted run ---------------------------------------------------------------------------

pub fn step(app: *App, s: *harness.Step) !void {
    if (!s.env.cli.snapshot()) return;
    const input = s.input;
    switch (s.n) {
        3 => try s.save("paragraphs-1-initial", .{}),
        // Press in the second block, drag down two lines and across, release.
        4 => press(input, app.click_pt, true),
        5, 6 => press(input, app.drag_pt, false),
        7 => {
            input.mouse_x = app.drag_pt[0];
            input.mouse_y = app.drag_pt[1];
            input.down = false;
            input.released = true;
        },
        9 => try s.save("paragraphs-2-selected", .{}),
        // Keys: to the end of the line, then down through the block into the next ones.
        10 => {
            input.pushKey(keys.right, .{ .cmd = true });
            for (0..9) |_| input.pushKey(keys.down, .{});
        },
        12 => try s.save("paragraphs-3-keys", .{}),
        // The frame that jumps far down is the one that lays out the blocks it lands on.
        13 => {
            app.scroll.offset = 3000;
            try s.save("paragraphs-4-scrolled", .{});
        },
        // Back at the top with the caret in the second block, then forty Downs: the caret ends
        // well below the view, which has to follow it.
        14 => {
            app.scroll.offset = 0;
            app.caret = .{ .block = 1, .offset = 0 };
            app.anchor = 0;
        },
        16 => for (0..40) |_| input.pushKey(keys.down, .{}),
        19 => {
            try s.save("paragraphs-5-follow", .{});
            s.done();
        },
        else => {},
    }
}

fn press(input: *ui_mod.Input, pt: [2]f32, first: bool) void {
    input.mouse_x = pt[0];
    input.mouse_y = pt[1];
    input.down = true;
    input.pressed = first;
    input.mouse_clicks = 1;
}

pub fn main(init: std.process.Init) !void {
    const env = try harness.start(init, "paragraphs", .{}) orelse return;
    var app: App = .{ .gpa = env.gpa, .io = init.io, .doc = std.heap.ArenaAllocator.init(env.gpa) };
    defer app.deinit();
    app.show_time = !env.cli.snapshot();
    try buildDocument(&app);
    try harness.run(@This(), env, .{
        .window = .{ .title = "Paragraphs", .width = 760, .height = 640, .resizable = true, .min_width = 360, .min_height = 300 },
        .snapshot_frame = null,
    }, &app);
}
