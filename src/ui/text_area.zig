//! A multi-line text editor widget (`Ui.textArea`), built on `TextEdit` and the
//! same word wrapping as `labelWrapped`. The text is soft-wrapped to the width
//! of the rectangle (hard newlines are kept), and the area scrolls vertically
//! when the content is taller than the rectangle.
//!
//! Like the single-line `textField`, state is caller-owned (`TextAreaState`,
//! whose address is its focus identity) and the editing keys follow macOS:
//! arrows, alt = by word, cmd+left/right = line edges (visual lines), cmd+up/down
//! = start/end of the text, shift extends the selection, cmd+a/c/x/v, cmd+z undo,
//! cmd+shift+z redo (see `TextEdit` for how typing runs coalesce).
const std = @import("std");
const geom = @import("../core/geom.zig");
const keys = @import("../core/keys.zig");
const text_edit = @import("../text/text_edit.zig");
const ui_mod = @import("ui.zig");
const text_input = @import("text_input.zig");
const popup = @import("popup.zig");
const Rect = geom.Rect;
const Ui = ui_mod.Ui;
const TextEdit = text_edit.TextEdit;

/// State of one `textArea`. Keep it at a stable address while the area exists.
/// The content is `state.edit.text()`; `edit.multiline` is on.
pub const TextAreaState = struct {
    edit: TextEdit,
    /// Points scrolled from the top of the text.
    scroll_y: f32 = 0,
    blink_origin: f64 = 0,
    /// The x (from the left of the text) Up/Down aim for, kept across a run of
    /// vertical moves so a short line does not lose the column.
    want_x: ?f32 = null,
    /// Where the caret and the text length were last frame: the caret is only
    /// scrolled into view when they change, so the wheel can scroll it away.
    seen_cursor: usize = std.math.maxInt(usize),
    seen_len: usize = std.math.maxInt(usize),
    /// `edit.undo_serial` as of last frame: an undo or redo scrolls the caret into view.
    seen_serial: u32 = 0,
    /// What a double or triple click selected, so a drag grows by words or lines.
    multi: text_edit.MultiClick = .{},
    /// The right-click menu (Undo, Redo, Cut, Copy, Paste, Select All); drawn as a popup.
    ctx: popup.PopupState = .{},
    /// The text as drawn while an input-method pre-edit is spliced in, rebuilt each frame.
    disp: std.ArrayList(u8) = .empty,
    /// Pre-edit bookkeeping (see `text_input.composingNow`).
    was_focused: bool = false,
    ime_block: bool = false,

    pub fn init(gpa: std.mem.Allocator) TextAreaState {
        return .{ .edit = .{ .gpa = gpa, .multiline = true } };
    }

    pub fn deinit(s: *TextAreaState) void {
        s.disp.deinit(s.edit.gpa);
        s.edit.deinit();
    }

    /// Reverts the newest edit (see `TextEdit.undo`); returns false if there is none.
    /// The caret is scrolled into view next frame.
    pub fn undo(s: *TextAreaState) bool {
        s.want_x = null;
        return s.edit.undo();
    }

    pub fn redo(s: *TextAreaState) bool {
        s.want_x = null;
        return s.edit.redo();
    }

    pub fn canUndo(s: *const TextAreaState) bool {
        return s.edit.canUndo();
    }

    pub fn canRedo(s: *const TextAreaState) bool {
        return s.edit.canRedo();
    }

    pub fn clearHistory(s: *TextAreaState) void {
        s.edit.clearHistory();
    }

    /// Empties the text, scrolls back to the top and clears the undo history.
    pub fn clear(s: *TextAreaState) void {
        s.edit.clear();
        s.scroll_y = 0;
        s.want_x = null;
    }
};

pub const TextAreaOpts = struct {
    /// Dim text shown while the area is empty.
    placeholder: []const u8 = "",
    /// Font size; defaults to the theme's body size.
    size: ?f32 = null,
    /// Draw only the text and caret: no border or fill, no inner padding.
    bare: bool = false,
    /// Tab inserts a tab character instead of moving keyboard focus to the next widget.
    /// Shift+Tab still moves focus back, so the area can always be left with the keyboard.
    tab_inserts: bool = false,
    /// Return reports `submitted` instead of inserting a line break; Shift+Return
    /// inserts one. Off: Return inserts a line break and never submits.
    submit_on_enter: bool = false,
    /// A right click opens the Undo / Redo / Cut / Copy / Paste / Select All menu (needs `ui.state`).
    context_menu: bool = true,
    /// For `measureTextArea`: the fewest and most lines of height it reports.
    /// (`textArea` itself fills whatever rectangle it is given.)
    min_lines: usize = 1,
    max_lines: ?usize = null,
};

pub const TextAreaResult = struct {
    /// The text changed this frame (typing, deleting, cut, paste, Return).
    changed: bool = false,
    /// Return was pressed while focused, with `submit_on_enter`.
    submitted: bool = false,
    /// While focused: where the caret (or the input-method pre-edit) is, as a screen rectangle one
    /// line high, and the input method's caret offset from its left edge. `textArea` already
    /// passes them to `Ui.setTextInputArea`; they are here for apps that call
    /// `Window.setTextInputArea` themselves.
    input_area: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    caret_x: f32 = 0,
};

/// Horizontal and vertical padding of a non-bare text area.
const pad_x: f32 = 10;
const pad_y: f32 = 8;

const Line = struct { index: usize, start: usize, end: usize, text: []const u8 };

fn lineOf(text: []const u8, line: []const u8, index: usize) Line {
    const start = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
    return .{ .index = index, .start = start, .end = start + line.len, .text = line };
}

/// The `index`-th visual line, or null past the last.
fn lineAtIndex(ui: *const Ui, text: []const u8, size: f32, w: f32, index: usize) ?Line {
    var it = ui.wrapText(text, size, w);
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i == index) return lineOf(text, line, i);
    }
    return null;
}

/// The visual line holding byte offset `pos`: the last line that starts at or
/// before it (so a position between a wrapped line and the next belongs to
/// the next). Empty text has one empty line.
fn locate(ui: *const Ui, text: []const u8, size: f32, w: f32, pos: usize) Line {
    var best: Line = .{ .index = 0, .start = 0, .end = 0, .text = "" };
    var it = ui.wrapText(text, size, w);
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        const l = lineOf(text, line, i);
        if (i > 0 and l.start > pos) break;
        best = l;
    }
    return best;
}

/// x of byte offset `pos` within its line `l`.
fn caretX(ui: *const Ui, l: Line, size: f32, pos: usize) f32 {
    return ui.measure(l.text[0..@min(l.text.len, pos -| l.start)], size);
}

fn lineCount(ui: *const Ui, text: []const u8, size: f32, w: f32) usize {
    var it = ui.wrapText(text, size, w);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

/// Inserts `str` without carriage returns (pasted CRLF text becomes LF), as one edit of `kind`.
fn insertClean(st: *TextAreaState, str: []const u8, kind: text_edit.EditKind) void {
    text_input.insertClean(&st.edit, str, kind);
}

fn moveVertical(ui: *const Ui, st: *TextAreaState, size: f32, w: f32, down: bool, extend: bool) void {
    const text = st.edit.text();
    const c = locate(ui, text, size, w, st.edit.cursor);
    const x = st.want_x orelse caretX(ui, c, size, st.edit.cursor);
    st.want_x = x;
    const target = if (down) lineAtIndex(ui, text, size, w, c.index + 1) else if (c.index == 0) null else lineAtIndex(ui, text, size, w, c.index - 1);
    if (target) |l| {
        st.edit.moveTo(l.start + ui.offsetAtX(l.text, size, x), extend);
    } else {
        // Up on the first line goes to the start, Down on the last to the end.
        st.edit.moveTo(if (down) text.len else 0, extend);
    }
}

fn handleKey(ui: *Ui, st: *TextAreaState, code: u32, m: keys.Mods, opts: TextAreaOpts, size: f32, w: f32, res: *TextAreaResult, s: *ui_mod.State, focused: *bool) void {
    const ed = &st.edit;
    if (code == keys.tab) {
        // Plain Tab only reaches a text area that asked for it (`tab_inserts`).
        if (opts.tab_inserts and !m.shift and !m.cmd and !m.ctrl and !m.alt) {
            st.want_x = null;
            insertClean(st, "\t", .typing);
            res.changed = true;
        }
        return;
    }
    const vertical = code == keys.up or code == keys.down;
    if (!vertical) st.want_x = null;

    if (code == keys.@"return") {
        if (m.cmd or m.ctrl) return;
        if (opts.submit_on_enter and !m.shift) {
            res.submitted = true;
        } else {
            insertClean(st, "\n", .typing);
            res.changed = true;
        }
        return;
    }
    if (vertical and !m.ctrl) {
        if (m.cmd) {
            st.want_x = null;
            ed.moveTo(if (code == keys.down) ed.text().len else 0, m.shift);
        } else moveVertical(ui, st, size, w, code == keys.down, m.shift);
        return;
    }
    // Home/End and cmd+left/right go to the edges of the visual line.
    const home = code == keys.home or (m.cmd and code == keys.left);
    const end = code == keys.end or (m.cmd and code == keys.right);
    if ((home or end) and !m.ctrl) {
        const c = locate(ui, ed.text(), size, w, ed.cursor);
        ed.moveTo(if (home) c.start else c.end, m.shift);
        return;
    }
    switch (ed.handleKey(code, m) catch .none) {
        .none, .handled, .submit => {},
        .changed => res.changed = true,
        .copy => |str| ui.clipboardSet(str),
        .cut => |str| {
            ui.clipboardSet(str);
            res.changed = true;
        },
        .paste => if (ui.clipboard.get) |get| if (get(ed.gpa)) |str| {
            defer ed.gpa.free(str);
            insertClean(st, str, .paste);
            res.changed = true;
        },
        .cancel => {
            s.focus = null;
            focused.* = false;
        },
    }
}

/// A multi-line editable text area.
///
/// Clicking focuses it (needs `ui.state`), clicking elsewhere or Escape blurs
/// it. While focused it consumes this frame's typed text and keys. Return
/// inserts a line break, or with `opts.submit_on_enter` sets `submitted`
/// (Shift+Return then inserts the break; the text stays, clear it yourself).
/// Up/Down move across visual lines keeping their column, Cmd+Up/Down jump to
/// the start/end of the text, Home/End and Cmd+Left/Right to the edges of the
/// visual line. Click places the caret, drag selects, double click selects the
/// word, triple click the line between newlines, shift-click extends. The
/// mouse wheel scrolls it while hovered (only when the content overflows), and
/// typing or moving the caret scrolls it into view. The caret blinks off
/// `Input.time`. The content is `state.edit.text()`.
///
/// While focused it holds `State.focus`, so the arrow keys of an enclosing
/// `beginScroll` stay still, as for `textField`.
pub fn textArea(ui: *Ui, r: Rect, st: *TextAreaState, opts: TextAreaOpts) TextAreaResult {
    const t = ui.theme;
    const size = opts.size orelse t.font_body;
    const lh = ui.lineHeight(size);
    const px: f32 = if (opts.bare) 0 else pad_x;
    const py: f32 = if (opts.bare) 0 else pad_y;
    const box: Rect = .{ .x = r.x + px, .y = r.y + py, .w = @max(0, r.w - 2 * px), .h = @max(0, r.h - 2 * py) };
    const id: *const anyopaque = st;
    var res: TextAreaResult = .{};
    const in = &ui.input;
    // A Tab stop; the area handles the mouse itself. Tab is taken before the area sees keys.
    _ = ui.focusable(ui_mod.focusIdOf(id), r, .{ .role = .text_area, .label = opts.placeholder, .ring = false, .activate = false, .click_focus = false, .captures_tab = opts.tab_inserts });
    var focused = if (ui.state) |s| s.focus == id else false;
    const hv = ui.hit(r);
    if (hv.hovered) ui.setCursor(.text);
    var dragging = false;
    // A composition that was already showing last frame: clicks are the input method's then.
    const comp_before = st.was_focused and focused and in.composition.len > 0 and !st.ime_block;

    if (ui.state) |s| {
        const wants_off = hv.clicked or (in.right_pressed and hv.hovered) or s.drag == id;
        const off = if (wants_off) ui.offsetAtPoint(st.edit.text(), size, box.w, in.mouse_x - box.x, in.mouse_y - box.y + st.scroll_y) else 0;
        if (hv.clicked) {
            const clicks = ui.clickCount();
            s.focus = id;
            s.select = null; // one selection at a time
            focused = true;
            st.blink_origin = in.time;
            st.want_x = null;
            if (!comp_before) {
                const cur = st.edit.text();
                s.drag = id;
                if (in.mouse_mods.shift) {
                    st.multi = .{};
                    st.edit.moveTo(off, true);
                } else if (st.multi.begin(cur, off, clicks, false)) |rg| {
                    st.edit.select(rg.start, rg.end);
                } else st.edit.moveTo(off, false);
            }
        } else if (opts.context_menu and in.right_pressed and !st.ctx.open and hv.hovered and !popup.pressSwallowed(ui)) {
            // Right click: focus the area; keep the selection when the click is inside it, else
            // put the caret there; then open the menu (which hands focus back when it closes).
            s.focus = id;
            s.select = null;
            focused = true;
            st.blink_origin = in.time;
            st.want_x = null;
            const sel = st.edit.selection();
            if (!comp_before and (!st.edit.hasSelection() or off < sel.start or off > sel.end)) st.edit.moveTo(off, false);
            _ = ui.contextOpen(&st.ctx, r);
        } else if (ui.pressedNow() and focused) {
            s.focus = null;
            focused = false;
        } else if (s.drag == id) {
            if (comp_before) {
                if (!in.down) s.drag = null;
            } else if (in.down) {
                if (st.multi.gran != .char) {
                    const m = st.multi.extend(st.edit.text(), off);
                    st.edit.select(m.anchor, m.cursor);
                } else st.edit.moveTo(off, true);
                dragging = true;
            } else s.drag = null;
        }

        if (opts.context_menu and st.ctx.open) {
            const caps: text_input.Caps = .{
                .editable = true,
                .has_selection = st.edit.hasSelection(),
                .has_text = st.edit.text().len > 0,
                .can_undo = st.edit.canUndo(),
                .can_redo = st.edit.canRedo(),
            };
            if (text_input.contextMenu(ui, &st.ctx, caps)) |act| {
                s.focus = id;
                focused = true;
                st.want_x = null;
                st.edit.now = in.time;
                st.blink_origin = in.time;
                if (text_input.applyAction(ui, &st.edit, act, true)) res.changed = true;
            }
        }
    }

    const composing = text_input.composingNow(&st.was_focused, &st.ime_block, focused, in.composition.len > 0);

    if (focused) {
        const s = ui.state.?;
        st.edit.now = in.time;
        for (ui.events()) |ev| {
            if (!focused) break;
            st.blink_origin = in.time;
            switch (ev) {
                .text => |chunk| if (chunk.len > 0) {
                    st.want_x = null;
                    insertClean(st, chunk.slice(), .typing);
                    res.changed = true;
                },
                .key => |k| {
                    if (composing and text_input.imeOwnsKey(k)) continue;
                    handleKey(ui, st, k.code, k.mods, opts, size, box.w, &res, s, &focused);
                },
            }
        }
    }

    // What is drawn: the text, with the pre-edit spliced in at the caret (replacing the selection).
    const text = st.edit.text();
    const sel = st.edit.selection();
    const pre = if (composing and focused) text_input.preedit(&in.composition, false, text_input.roomFor(&st.edit, sel.end - sel.start)) else null;
    const caret_off = text_edit.snapCluster(text, st.edit.cursor);
    const d = text_input.display(st.edit.gpa, &st.disp, text, false, pre, if (pre != null) sel else .{ .start = caret_off, .end = caret_off });
    const dtext = d.text;
    const dcur = d.caretAt(caret_off);

    // Layout, wheel, and keeping the caret in view.
    const content_h = @max(lh, ui.measureWrapped(dtext, size, box.w));
    const caret = locate(ui, dtext, size, box.w, dcur);
    const cx = caretX(ui, caret, size, dcur);
    const caret_top = @as(f32, @floatFromInt(caret.index)) * lh;
    if (hv.hovered and in.wheel_y != 0 and content_h > box.h) {
        st.scroll_y -= in.wheel_y * t.scroll_step;
        in.wheel_y = 0; // consumed, so an enclosing scroll area doesn't also move
    }
    if (focused and (dragging or dcur != st.seen_cursor or dtext.len != st.seen_len or st.edit.undo_serial != st.seen_serial)) {
        if (caret_top < st.scroll_y) {
            st.scroll_y = caret_top;
        } else if (caret_top + lh > st.scroll_y + box.h) {
            st.scroll_y = caret_top + lh - box.h;
        }
    }
    st.seen_cursor = dcur;
    st.seen_len = dtext.len;
    st.seen_serial = st.edit.undo_serial;
    const max_scroll = @max(0, content_h - box.h);
    st.scroll_y = std.math.clamp(st.scroll_y, 0, max_scroll);

    // The caret's line (also what `input_area` reports, for apps that set the text input area
    // themselves) and, for the input method, a tighter rectangle: under the pre-edit's first line,
    // or at the caret.
    res.input_area = .{ .x = box.x, .y = box.y - st.scroll_y + caret_top, .w = box.w, .h = lh };
    res.caret_x = cx;
    if (focused) {
        const first = if (pre != null) locate(ui, dtext, size, box.w, d.pre_start) else caret;
        const fx = caretX(ui, first, size, if (pre != null) d.pre_start else dcur);
        var w: f32 = 1;
        if (pre != null) {
            const e = @min(d.preEnd(), first.end);
            if (e > d.pre_start) w = @max(1, caretX(ui, first, size, e) - fx);
        }
        const area: Rect = .{ .x = box.x + fx, .y = box.y - st.scroll_y + @as(f32, @floatFromInt(first.index)) * lh, .w = w, .h = lh };
        ui.setTextInputArea(area, if (pre != null and caret.index == first.index) @max(0, cx - fx) else 0);
    }

    // Draw.
    if (!opts.bare) {
        ui.list.rrect(r, 10, if (focused) t.accent else t.track);
        ui.list.rrect(r.inset(1.5), 8.5, t.card);
    }
    ui.pushClip(box);
    if (dtext.len == 0) {
        if (opts.placeholder.len > 0) _ = ui.labelWrapped(box, opts.placeholder, .{ .size = size, .color = t.dim });
    } else {
        const show_sel = focused and pre == null and st.edit.hasSelection();
        const sel_s = text_edit.snapCluster(text, sel.start);
        const sel_e = text_edit.snapCluster(text, sel.end);
        const space_w = ui.measure(" ", size);
        var y = box.y - st.scroll_y;
        var it = ui.wrapText(dtext, size, box.w);
        while (it.next()) |line| : (y += lh) {
            if (y + lh < box.y) continue;
            if (y > box.y + box.h) break;
            const l = lineOf(dtext, line, 0);
            if (show_sel) {
                const a = @max(sel_s, l.start);
                const b = @min(sel_e, l.end);
                var x0 = box.x;
                var x1 = box.x;
                var any = true;
                if (a < b) {
                    x0 = box.x + ui.measure(line[0 .. a - l.start], size);
                    x1 = box.x + ui.measure(line[0 .. b - l.start], size);
                } else if (sel_s <= l.end and sel_e > l.end) {
                    x0 = box.x + ui.measure(line, size);
                    x1 = x0;
                } else any = false;
                if (any) {
                    // The selection runs on past a line break: show the break as a stub.
                    if (sel_e > l.end and l.end < dtext.len and sel_s <= l.end and (dtext[l.end] == '\n' or dtext[l.end] == '\r' or dtext[l.end] == ' ')) x1 += space_w;
                    x1 = @min(x1, box.x + box.w);
                    if (x1 > x0) ui.list.rect(.{ .x = x0, .y = y, .w = x1 - x0, .h = lh }, t.selection);
                }
            }
            if (line.len > 0) ui.list.text(box.x, y, size, t.text, .left, line);
            if (pre) |p| {
                // The pre-edit's part of this line: underline, and the highlighted clause.
                const a = @max(d.pre_start, l.start);
                const b = @min(d.preEnd(), l.end);
                if (a < b) {
                    const x0 = box.x + ui.measure(line[0 .. a - l.start], size);
                    const x1 = box.x + ui.measure(line[0 .. b - l.start], size);
                    var clause: ?text_input.ClauseX = null;
                    if (p.clause) |c| {
                        const ca = @max(d.pre_start + c.start, a);
                        const cb = @min(d.pre_start + c.end, b);
                        if (ca < cb) clause = .{
                            .x0 = box.x + ui.measure(line[0 .. ca - l.start], size),
                            .x1 = box.x + ui.measure(line[0 .. cb - l.start], size),
                        };
                    }
                    text_input.drawPreeditMarks(ui, x0, x1, y, lh, clause);
                }
            }
        }
    }
    const show_caret = focused and (pre == null or pre.?.clause == null);
    if (show_caret) ui.requestCaretBlink(st.blink_origin);
    if (show_caret and ui.caretVisible(st.blink_origin)) {
        ui.list.rect(.{ .x = box.x + cx, .y = box.y - st.scroll_y + caret_top, .w = 1.5, .h = lh }, t.text);
    }
    ui.popClip();

    if (max_scroll > 0) {
        const track = r.h - 8;
        const thumb_h = @max(24, track * box.h / content_h);
        const ty = r.y + 4 + (track - thumb_h) * (st.scroll_y / max_scroll);
        ui.list.rrect(.{ .x = r.x + r.w - 6, .y = ty, .w = 3, .h = thumb_h }, 1.5, t.scrollbar);
    }
    return res;
}

/// Height of the rectangle a text area of width `width` needs for the text in
/// `st`: the wrapped lines (at least `opts.min_lines`, at most `opts.max_lines`)
/// plus padding. Pass the result as the height of the rectangle to `textArea`
/// for a box that grows with its text and scrolls beyond `max_lines`.
pub fn measureTextArea(ui: *const Ui, st: *const TextAreaState, width: f32, opts: TextAreaOpts) f32 {
    const size = opts.size orelse ui.theme.font_body;
    const lh = ui.lineHeight(size);
    const px: f32 = if (opts.bare) 0 else pad_x;
    const py: f32 = if (opts.bare) 0 else pad_y;
    var n = @max(opts.min_lines, lineCount(ui, st.edit.text(), size, @max(0, width - 2 * px)));
    if (opts.max_lines) |m| n = @min(n, @max(m, opts.min_lines));
    return @as(f32, @floatFromInt(n)) * lh + 2 * py;
}

// ---- tests ------------------------------------------------------------------------

const DisplayList = @import("../core/gfx.zig").DisplayList;
const Input = ui_mod.Input;
const State = ui_mod.State;
const Theme = ui_mod.Theme;

/// One unit of width per code point, scaled by size.
fn cpMeasure(_: ?*anyopaque, str: []const u8, size: f32) f32 {
    const n = std.unicode.utf8CountCodepoints(str) catch str.len;
    return @as(f32, @floatFromInt(n)) * size;
}

var fake_clip: [128]u8 = undefined;
var fake_clip_len: usize = 0;

fn fakeClipGet(gpa: std.mem.Allocator) ?[]u8 {
    if (fake_clip_len == 0) return null;
    return gpa.dupe(u8, fake_clip[0..fake_clip_len]) catch null;
}

fn fakeClipSet(_: std.mem.Allocator, str: []const u8) void {
    @memcpy(fake_clip[0..str.len], str);
    fake_clip_len = str.len;
}

/// Size 10 text: 10 points per character, line height 14. Bare, so a 50 wide
/// rectangle wraps at 5 characters.
const test_opts: TextAreaOpts = .{ .size = 10, .bare = true };
const test_rect: Rect = .{ .x = 0, .y = 0, .w = 50, .h = 100 };

fn areaFrame(list: *DisplayList, state: *State, in: Input, st: *TextAreaState, r: Rect, opts: TextAreaOpts) TextAreaResult {
    list.reset();
    var ui = Ui.initHeadless(list, in, .{}, cpMeasure);
    ui.state = state;
    ui.clipboard = .{ .get = fakeClipGet, .set = fakeClipSet };
    return ui.textArea(r, st, opts);
}

fn keyIn(code: u32, mods: keys.Mods) Input {
    var in: Input = .{};
    in.pushKey(code, mods);
    return in;
}

const Fixture = struct {
    list: DisplayList,
    state: State,
    st: TextAreaState,

    /// Initialises in place (the display list and the focus identity both
    /// depend on the fixture's address): `var f: Fixture = undefined; try f.setup(..)`.
    /// Sets the text (caret at the end) and focuses the area.
    fn setup(f: *Fixture, text: []const u8) !void {
        f.list = DisplayList.init(std.testing.allocator);
        f.st = TextAreaState.init(std.testing.allocator);
        f.state = .{};
        try f.st.edit.setText(text);
        f.state.focusOn(&f.st);
    }

    fn deinit(f: *Fixture) void {
        f.list.deinit();
        f.st.deinit();
    }

    fn frame(f: *Fixture, in: Input) TextAreaResult {
        return areaFrame(&f.list, &f.state, in, &f.st, test_rect, test_opts);
    }

    fn key(f: *Fixture, code: u32, mods: keys.Mods) TextAreaResult {
        return f.frame(keyIn(code, mods));
    }
};

test "textArea: Return inserts a line break and never submits by default" {
    var f: Fixture = undefined;
    try f.setup("ab");
    defer f.deinit();
    var res = f.key(keys.@"return", .{});
    try std.testing.expect(res.changed and !res.submitted);
    try std.testing.expectEqualStrings("ab\n", f.st.edit.text());
    var in: Input = .{};
    in.pushText("cd");
    res = f.frame(in);
    try std.testing.expectEqualStrings("ab\ncd", f.st.edit.text());
    res = f.key(keys.@"return", .{ .shift = true });
    try std.testing.expect(res.changed and !res.submitted);
    try std.testing.expectEqualStrings("ab\ncd\n", f.st.edit.text());
}

test "textArea: submit_on_enter submits on Return and breaks on Shift+Return" {
    var f: Fixture = undefined;
    try f.setup("ab");
    defer f.deinit();
    const opts: TextAreaOpts = .{ .size = 10, .bare = true, .submit_on_enter = true };
    var res = areaFrame(&f.list, &f.state, keyIn(keys.@"return", .{}), &f.st, test_rect, opts);
    try std.testing.expect(res.submitted and !res.changed);
    try std.testing.expectEqualStrings("ab", f.st.edit.text());
    res = areaFrame(&f.list, &f.state, keyIn(keys.@"return", .{ .shift = true }), &f.st, test_rect, opts);
    try std.testing.expect(!res.submitted and res.changed);
    try std.testing.expectEqualStrings("ab\n", f.st.edit.text());
}

test "textArea: unfocused ignores keys and text" {
    var f: Fixture = undefined;
    try f.setup("ab");
    defer f.deinit();
    f.state.blur();
    var in: Input = .{};
    in.pushText("x");
    in.pushKey(keys.@"return", .{});
    const res = f.frame(in);
    try std.testing.expect(!res.changed and !res.submitted);
    try std.testing.expectEqualStrings("ab", f.st.edit.text());
}

test "textArea: Up and Down cross wrapped and hard lines keeping the column" {
    // Visual lines at 5 characters: "hello" (0..5) "world" (6..11) "xy" (12..14).
    var f: Fixture = undefined;
    try f.setup("hello world\nxy");
    defer f.deinit();
    f.st.edit.moveTo(3, false);
    _ = f.key(keys.down, .{});
    try std.testing.expectEqual(@as(usize, 9), f.st.edit.cursor); // "wor|ld"
    _ = f.key(keys.down, .{});
    try std.testing.expectEqual(@as(usize, 14), f.st.edit.cursor); // clamped to the end of "xy"
    _ = f.key(keys.up, .{});
    try std.testing.expectEqual(@as(usize, 9), f.st.edit.cursor); // column 3 remembered
    _ = f.key(keys.up, .{});
    try std.testing.expectEqual(@as(usize, 3), f.st.edit.cursor);
    // Up on the first line goes to the start, Down on the last to the end.
    _ = f.key(keys.up, .{});
    try std.testing.expectEqual(@as(usize, 0), f.st.edit.cursor);
    f.st.edit.moveTo(13, false);
    _ = f.key(keys.down, .{});
    try std.testing.expectEqual(@as(usize, 14), f.st.edit.cursor);
    // Typing forgets the remembered column.
    f.st.edit.moveTo(3, false);
    _ = f.key(keys.down, .{});
    var in: Input = .{};
    in.pushText("!");
    _ = f.frame(in);
    try std.testing.expect(f.st.want_x == null);
}

test "textArea: blank lines and trailing newline are lines too" {
    var f: Fixture = undefined;
    try f.setup("ab\n\ncd\n");
    defer f.deinit();
    f.st.edit.moveTo(1, false);
    _ = f.key(keys.down, .{});
    try std.testing.expectEqual(@as(usize, 3), f.st.edit.cursor); // the empty line
    _ = f.key(keys.down, .{});
    try std.testing.expectEqual(@as(usize, 5), f.st.edit.cursor); // "cd" at column 1 (kept from "ab")
    _ = f.key(keys.down, .{});
    try std.testing.expectEqual(@as(usize, 7), f.st.edit.cursor); // the empty line after the final newline
    _ = f.key(keys.up, .{});
    try std.testing.expectEqual(@as(usize, 5), f.st.edit.cursor);
}

test "textArea: Cmd+Up/Down, Home/End and Cmd+Left/Right" {
    var f: Fixture = undefined;
    try f.setup("hello world\nxy");
    defer f.deinit();
    f.st.edit.moveTo(8, false); // in "world"
    _ = f.key(keys.home, .{});
    try std.testing.expectEqual(@as(usize, 6), f.st.edit.cursor); // start of the visual line
    _ = f.key(keys.end, .{});
    try std.testing.expectEqual(@as(usize, 11), f.st.edit.cursor);
    _ = f.key(keys.left, .{ .cmd = true });
    try std.testing.expectEqual(@as(usize, 6), f.st.edit.cursor);
    _ = f.key(keys.right, .{ .cmd = true });
    try std.testing.expectEqual(@as(usize, 11), f.st.edit.cursor);
    _ = f.key(keys.up, .{ .cmd = true });
    try std.testing.expectEqual(@as(usize, 0), f.st.edit.cursor);
    _ = f.key(keys.down, .{ .cmd = true, .shift = true });
    try std.testing.expectEqual(@as(usize, 14), f.st.edit.cursor);
    try std.testing.expectEqual(@as(usize, 0), f.st.edit.anchor);
    // Alt moves by word as in the text field.
    f.st.edit.moveTo(14, false);
    _ = f.key(keys.left, .{ .alt = true });
    try std.testing.expectEqual(@as(usize, 12), f.st.edit.cursor);
}

fn highlights(list: *const DisplayList, out: []Rect) usize {
    const sel = (Theme{}).selection;
    var n: usize = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .rrect => |c| if (std.meta.eql(c.color, sel) and n < out.len) {
            out[n] = c.rect;
            n += 1;
        },
        else => {},
    };
    return n;
}

test "textArea: shift+Down selects across lines and highlights each" {
    var f: Fixture = undefined;
    try f.setup("hello world\nxy");
    defer f.deinit();
    f.st.edit.moveTo(3, false);
    _ = f.key(keys.down, .{ .shift = true });
    try std.testing.expectEqualStrings("lo wor", f.st.edit.selectedText());
    var rects: [8]Rect = undefined;
    const n = highlights(&f.list, &rects);
    try std.testing.expectEqual(@as(usize, 2), n);
    // First line from the caret column to the right edge (with the line-break stub).
    try std.testing.expectEqual(Rect{ .x = 30, .y = 0, .w = 20, .h = 14 }, rects[0]);
    // Second line from its start to the selection end.
    try std.testing.expectEqual(Rect{ .x = 0, .y = 14, .w = 30, .h = 14 }, rects[1]);
    // Typing replaces all of it.
    var in: Input = .{};
    in.pushText("-");
    _ = f.frame(in);
    try std.testing.expectEqualStrings("hel-ld\nxy", f.st.edit.text());
    // Not focused: no highlight.
    f.st.edit.selectAll();
    f.state.blur();
    _ = f.frame(.{});
    try std.testing.expectEqual(@as(usize, 0), highlights(&f.list, &rects));
}

test "textArea: click places the caret, drag selects across lines" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextAreaState.init(std.testing.allocator);
    defer st.deinit();
    try st.edit.setText("hello world\nxy");
    const r = test_rect;
    // Line 1 ("world") spans y 14..28; x = 30 is after "wor".
    _ = areaFrame(&list, &state, .{ .mouse_x = 30, .mouse_y = 20, .pressed = true, .down = true, .mouse_clicks = 1 }, &st, r, test_opts);
    try std.testing.expect(state.focus == @as(*const anyopaque, &st));
    try std.testing.expectEqual(@as(usize, 9), st.edit.cursor);
    try std.testing.expect(!st.edit.hasSelection());
    // Drag to the "xy" line, past its end.
    _ = areaFrame(&list, &state, .{ .mouse_x = 45, .mouse_y = 34, .down = true }, &st, r, test_opts);
    try std.testing.expectEqual(@as(usize, 14), st.edit.cursor);
    try std.testing.expectEqual(@as(usize, 9), st.edit.anchor);
    _ = areaFrame(&list, &state, .{ .mouse_x = 5, .mouse_y = 2, .released = true }, &st, r, test_opts);
    try std.testing.expect(state.drag == null);
    // Drag upward past the top gives the start.
    _ = areaFrame(&list, &state, .{ .mouse_x = 2, .mouse_y = 2, .pressed = true, .down = true, .mouse_clicks = 1, .mouse_mods = .{ .shift = true } }, &st, r, test_opts);
    try std.testing.expectEqual(@as(usize, 0), st.edit.cursor);
    try std.testing.expectEqual(@as(usize, 9), st.edit.anchor);
    // A click below the last line goes to the end.
    _ = areaFrame(&list, &state, .{ .mouse_x = 5, .mouse_y = 90, .pressed = true, .mouse_clicks = 1 }, &st, r, test_opts);
    try std.testing.expectEqual(@as(usize, 14), st.edit.cursor);
    // A click outside blurs.
    _ = areaFrame(&list, &state, .{ .mouse_x = 200, .mouse_y = 20, .pressed = true }, &st, r, test_opts);
    try std.testing.expect(state.focus == null);
}

test "textArea: double click selects the word, triple click the hard line" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextAreaState.init(std.testing.allocator);
    defer st.deinit();
    try st.edit.setText("hello world\nxy");
    _ = areaFrame(&list, &state, .{ .mouse_x = 30, .mouse_y = 20, .pressed = true, .down = true, .mouse_clicks = 2 }, &st, test_rect, test_opts);
    try std.testing.expectEqualStrings("world", st.edit.selectedText());
    try std.testing.expect(state.drag != null); // dragging now grows by words
    _ = areaFrame(&list, &state, .{ .mouse_x = 30, .mouse_y = 20, .pressed = true, .down = true, .mouse_clicks = 3 }, &st, test_rect, test_opts);
    try std.testing.expectEqualStrings("hello world", st.edit.selectedText());
}

test "textArea: clipboard shortcuts, pasted CRLF becomes LF" {
    var f: Fixture = undefined;
    try f.setup("one\ntwo");
    defer f.deinit();
    _ = f.key(keys.a, .{ .cmd = true });
    _ = f.key(keys.c, .{ .cmd = true });
    try std.testing.expectEqualStrings("one\ntwo", fake_clip[0..fake_clip_len]);
    var res = f.key(keys.x, .{ .cmd = true });
    try std.testing.expect(res.changed);
    try std.testing.expectEqualStrings("", f.st.edit.text());
    fakeClipSet(std.testing.allocator, "a\r\nb");
    res = f.key(keys.v, .{ .cmd = true });
    try std.testing.expect(res.changed);
    try std.testing.expectEqualStrings("a\nb", f.st.edit.text());
}

test "textArea: scrolls to keep the caret visible, and the wheel scrolls it away" {
    // 100 -> 28 tall: two lines of 14 fit; six lines of text.
    const r: Rect = .{ .x = 0, .y = 0, .w = 50, .h = 28 };
    var f: Fixture = undefined;
    try f.setup("");
    defer f.deinit();
    var in: Input = .{};
    in.pushText("a\nb\nc\nd\ne\nf");
    _ = areaFrame(&f.list, &f.state, in, &f.st, r, test_opts);
    // Content 84, view 28: caret on the last line, so scrolled to the bottom.
    try std.testing.expectEqual(@as(f32, 56), f.st.scroll_y);
    // Cmd+Up: back to the top.
    _ = areaFrame(&f.list, &f.state, keyIn(keys.up, .{ .cmd = true }), &f.st, r, test_opts);
    try std.testing.expectEqual(@as(f32, 0), f.st.scroll_y);
    // Moving down one line at a time scrolls only when the caret would leave.
    _ = areaFrame(&f.list, &f.state, keyIn(keys.down, .{}), &f.st, r, test_opts);
    try std.testing.expectEqual(@as(f32, 0), f.st.scroll_y); // line 1 still fits
    _ = areaFrame(&f.list, &f.state, keyIn(keys.down, .{}), &f.st, r, test_opts);
    try std.testing.expectEqual(@as(f32, 14), f.st.scroll_y); // line 2 pushes it by one line
    // The wheel scrolls (hovered), consumes the event, and the caret is not forced back.
    _ = areaFrame(&f.list, &f.state, .{ .mouse_x = 10, .mouse_y = 10, .wheel_y = -1 }, &f.st, r, test_opts);
    try std.testing.expectEqual(@as(f32, 38), f.st.scroll_y);
    _ = areaFrame(&f.list, &f.state, .{ .mouse_x = 10, .mouse_y = 10 }, &f.st, r, test_opts);
    try std.testing.expectEqual(@as(f32, 38), f.st.scroll_y);
    // Typing brings the caret back.
    in = .{};
    in.pushText("z");
    _ = areaFrame(&f.list, &f.state, in, &f.st, r, test_opts);
    try std.testing.expectEqual(@as(f32, 28), f.st.scroll_y); // caret on line 2 (y 28..42), view 28 tall
    // Hovered wheel with content that fits is left for the enclosing area.
    var ui = Ui.initHeadless(&f.list, .{ .mouse_x = 10, .mouse_y = 10, .wheel_y = -1 }, .{}, cpMeasure);
    ui.state = &f.state;
    var small = TextAreaState.init(std.testing.allocator);
    defer small.deinit();
    _ = ui.textArea(test_rect, &small, test_opts);
    try std.testing.expectEqual(@as(f32, -1), ui.input.wheel_y);
}

test "textArea: scroll is clamped when the text shrinks and when cleared" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 50, .h = 28 };
    var f: Fixture = undefined;
    try f.setup("a\nb\nc\nd\ne\nf");
    defer f.deinit();
    _ = areaFrame(&f.list, &f.state, .{}, &f.st, r, test_opts);
    f.st.scroll_y = 56;
    f.st.edit.clear();
    _ = areaFrame(&f.list, &f.state, .{}, &f.st, r, test_opts);
    try std.testing.expectEqual(@as(f32, 0), f.st.scroll_y);
}

test "textArea: reports where the caret is for the input method" {
    var f: Fixture = undefined;
    try f.setup("hello world");
    defer f.deinit();
    f.st.edit.moveTo(8, false);
    const res = f.key(keys.end, .{}); // end of "world"
    try std.testing.expectEqual(@as(f32, 14), res.input_area.y);
    try std.testing.expectEqual(@as(f32, 14), res.input_area.h);
    try std.testing.expectEqual(@as(f32, 50), res.caret_x);
}

test "textArea: a focused area keeps arrow keys away from an enclosing scroll area" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var st = TextAreaState.init(std.testing.allocator);
    defer st.deinit();
    var scroll: ui_mod.ScrollState = .{ .key_scroll = true };
    var state: State = .{};
    const view: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var in = keyIn(keys.down, .{});
    var ui = Ui.initHeadless(&list, in, .{}, cpMeasure);
    ui.state = &state;
    _ = ui.beginScroll(view, &scroll, 1000);
    ui.endScroll();
    try std.testing.expect(scroll.offset > 0); // nothing focused: the arrow scrolls
    scroll.offset = 0;
    state.focusOn(&st);
    in = keyIn(keys.down, .{});
    ui = Ui.initHeadless(&list, in, .{}, cpMeasure);
    ui.state = &state;
    // Inside the scroll area a focused text area takes the key, the scroll area leaves it.
    const content = ui.beginScroll(view, &scroll, 1000);
    _ = ui.textArea(.{ .x = 0, .y = content.y, .w = 100, .h = 40 }, &st, test_opts);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 0), scroll.offset);
}

test "measureTextArea grows with the text between min and max lines" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var st = TextAreaState.init(std.testing.allocator);
    defer st.deinit();
    const ui = Ui.initHeadless(&list, .{}, .{}, cpMeasure);
    const opts: TextAreaOpts = .{ .size = 10, .bare = true, .min_lines = 1, .max_lines = 3 };
    try std.testing.expectEqual(@as(f32, 14), measureTextArea(&ui, &st, 50, opts));
    try st.edit.setText("ab");
    try std.testing.expectEqual(@as(f32, 14), measureTextArea(&ui, &st, 50, opts));
    try st.edit.setText("ab\ncd");
    try std.testing.expectEqual(@as(f32, 28), measureTextArea(&ui, &st, 50, opts));
    try st.edit.setText("hello world"); // wraps to two lines at 50 wide
    try std.testing.expectEqual(@as(f32, 28), measureTextArea(&ui, &st, 50, opts));
    try std.testing.expectEqual(@as(f32, 14), measureTextArea(&ui, &st, 120, opts));
    try st.edit.setText("a\nb\nc\nd\ne");
    try std.testing.expectEqual(@as(f32, 42), measureTextArea(&ui, &st, 50, opts)); // capped at 3 lines
    // Padding is added for a framed area; min_lines applies to an empty one.
    st.clear();
    try std.testing.expectEqual(@as(f32, 2 * 14 + 16), measureTextArea(&ui, &st, 70, .{ .size = 10, .min_lines = 2 }));
}

test "textArea: placeholder shows only while empty; framed area draws a focus ring" {
    var f: Fixture = undefined;
    try f.setup("");
    defer f.deinit();
    const opts: TextAreaOpts = .{ .size = 10, .placeholder = "Type" };
    const wide: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    _ = areaFrame(&f.list, &f.state, .{}, &f.st, wide, opts);
    var texts: usize = 0;
    var ring = false;
    for (f.list.cmds.items) |cmd| switch (cmd) {
        .text => |tx| {
            texts += 1;
            try std.testing.expectEqualStrings("Type", tx.str);
            try std.testing.expectEqual(@as(f32, 10), tx.x); // padded
        },
        .rrect => |c| if (std.meta.eql(c.color, (Theme{}).accent)) {
            ring = true;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), texts);
    try std.testing.expect(ring);
    try f.st.edit.setText("x");
    _ = areaFrame(&f.list, &f.state, .{}, &f.st, wide, opts);
    for (f.list.cmds.items) |cmd| switch (cmd) {
        .text => |tx| try std.testing.expectEqualStrings("x", tx.str),
        else => {},
    };
}

test "textArea: Cmd+Z / Cmd+Shift+Z through the Ui report changed and restore the caret" {
    var f: Fixture = undefined;
    try f.setup("");
    defer f.deinit();
    var in: Input = .{ .time = 1 };
    in.pushText("one two");
    try std.testing.expect(f.frame(in).changed);
    var res = f.key(keys.@"return", .{});
    try std.testing.expect(res.changed);
    in = .{ .time = 1 };
    in.pushText("three");
    _ = f.frame(in);
    try std.testing.expectEqualStrings("one two\nthree", f.st.edit.text());
    // Steps: "one", " two", "\n", "three" (newline is its own step).
    res = f.key(keys.z, .{ .cmd = true });
    try std.testing.expect(res.changed);
    try std.testing.expectEqualStrings("one two\n", f.st.edit.text());
    res = f.key(keys.z, .{ .cmd = true });
    try std.testing.expect(res.changed);
    try std.testing.expectEqualStrings("one two", f.st.edit.text());
    try std.testing.expectEqual(@as(usize, 7), f.st.edit.cursor);
    res = f.key(keys.z, .{ .cmd = true, .shift = true });
    try std.testing.expect(res.changed);
    try std.testing.expectEqualStrings("one two\n", f.st.edit.text());
    res = f.key(keys.z, .{ .cmd = true, .shift = true });
    try std.testing.expectEqualStrings("one two\nthree", f.st.edit.text());
    res = f.key(keys.z, .{ .cmd = true, .shift = true }); // nothing to redo
    try std.testing.expect(!res.changed);
    try std.testing.expect(f.st.canUndo() and !f.st.canRedo());
}

test "textArea: pasted CRLF text is a single undo step" {
    var f: Fixture = undefined;
    try f.setup("x");
    defer f.deinit();
    f.st.clearHistory();
    fakeClipSet(std.testing.allocator, "a\r\nb\r\nc");
    _ = f.key(keys.v, .{ .cmd = true });
    try std.testing.expectEqualStrings("xa\nb\nc", f.st.edit.text());
    try std.testing.expectEqual(@as(usize, 1), f.st.edit.history.undo_stack.items.len);
    try std.testing.expect(f.key(keys.z, .{ .cmd = true }).changed);
    try std.testing.expectEqualStrings("x", f.st.edit.text());
}

test "textArea: undo and redo scroll the caret into view" {
    var f: Fixture = undefined;
    try f.setup("");
    defer f.deinit();
    // 30 lines: far taller than the 100 point area (line height 14).
    var in: Input = .{};
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        in = .{};
        in.pushText("line");
        _ = f.frame(in);
        _ = f.key(keys.@"return", .{});
    }
    try std.testing.expect(f.st.scroll_y > 0);
    const bottom = f.st.scroll_y;
    // Go to the top and type there.
    _ = f.key(keys.up, .{ .cmd = true });
    try std.testing.expectEqual(@as(f32, 0), f.st.scroll_y);
    in = .{};
    in.pushText("TOP");
    _ = f.frame(in);
    // Jump to the end, then undo the "TOP" typing: the caret goes back up and the view follows.
    _ = f.key(keys.down, .{ .cmd = true });
    try std.testing.expectEqual(bottom + 0, @as(f32, bottom));
    try std.testing.expect(f.st.scroll_y > 0);
    try std.testing.expect(f.key(keys.z, .{ .cmd = true }).changed);
    try std.testing.expectEqual(@as(usize, 0), f.st.edit.cursor);
    try std.testing.expectEqual(@as(f32, 0), f.st.scroll_y);
    // Redo puts the caret after "TOP", still near the top.
    try std.testing.expect(f.key(keys.z, .{ .cmd = true, .shift = true }).changed);
    try std.testing.expectEqual(@as(usize, 3), f.st.edit.cursor);
    try std.testing.expectEqual(@as(f32, 0), f.st.scroll_y);

    // Same caret and length before and after (a same-size replacement): the serial still scrolls.
    f.st.edit.moveTo(f.st.edit.text().len - 1, false);
    f.st.edit.moveTo(f.st.edit.text().len, true); // forward selection of the last character
    f.st.edit.cursor = f.st.edit.text().len;
    in = .{};
    in.pushText("Z");
    _ = f.frame(in);
    f.st.scroll_y = 0;
    const len = f.st.edit.text().len;
    f.st.seen_cursor = f.st.edit.cursor;
    f.st.seen_len = len;
    try std.testing.expect(f.key(keys.z, .{ .cmd = true }).changed);
    try std.testing.expectEqual(len, f.st.edit.text().len);
    try std.testing.expect(f.st.scroll_y > 0);
}
