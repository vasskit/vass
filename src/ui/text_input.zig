//! What the three text widgets (`textField`, `textArea`, `textSelectable`) share: the
//! input-method pre-edit (composition) model and the text they draw for it, password masking,
//! the context menu and its actions, and pasting. Widget-specific code stays in the widgets.
//!
//! ## Pre-edit
//! The input method sends the string being composed (`Input.composition`, UTF-8) and, in code
//! points, the range inside it the user is working on (`start`, `length`; -1 when absent). The
//! widget with keyboard focus draws that string inline at the caret, underlined, pushing the
//! text after it along. It is not in the buffer or the undo history: it only becomes part of
//! the text when the input method commits it (a `text_input` event), as an ordinary typed
//! insertion. A selection is not deleted when composing starts; it is hidden and drawn over by
//! the pre-edit, and the commit replaces it as one undo step, like typing over it. If the
//! composition is cancelled the selection is still there.
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../platform/backend_sdl.zig");
const geom = @import("../core/geom.zig");
const text_edit = @import("../text/text_edit.zig");
const grapheme = @import("../text/grapheme.zig");
const popup = @import("popup.zig");
const ui_mod = @import("ui.zig");
const Rect = geom.Rect;
const Ui = ui_mod.Ui;
const TextEdit = text_edit.TextEdit;
const Range = TextEdit.Range;

/// The character a password field draws for each grapheme cluster.
pub const bullet = "\u{2022}";
const chunk_bullets = 64;
/// 64 bullets, to cut runs from (drawing, masking).
pub const bullets: []const u8 = &bullet_array;
const bullet_array = blk: {
    var a: [chunk_bullets * bullet.len]u8 = undefined;
    for (0..chunk_bullets) |i| @memcpy(a[i * bullet.len ..][0..bullet.len], bullet);
    break :blk a;
};

/// Appends `n` bullets to `list`.
pub fn appendBulletsTo(list: *std.ArrayList(u8), gpa: std.mem.Allocator, n: usize) !void {
    var left = n;
    while (left > 0) {
        const k = @min(left, chunk_bullets);
        try list.appendSlice(gpa, bullets[0 .. k * bullet.len]);
        left -= k;
    }
}

// ---- pre-edit ----------------------------------------------------------------------------

/// The composition as the widget shows it.
pub const Preedit = struct {
    /// What is drawn: the composition text (cut to what the field has room for), or one bullet
    /// per cluster in a password field.
    shown: []const u8,
    /// Where the input method's caret is inside `shown` (bytes), when it has no highlighted
    /// clause.
    caret: ?usize,
    /// The highlighted clause (bytes inside `shown`), if any.
    clause: ?Range,
};

/// Byte offset of code point number `n` of `s` (clamped to the length).
pub fn codepointOffset(s: []const u8, n: usize) usize {
    var i: usize = 0;
    var k: usize = 0;
    while (k < n and i < s.len) : (k += 1) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(s.len, i + l);
    }
    return i;
}

/// The pre-edit to show for `comp`, or null when nothing is being composed. `room` is how many
/// more bytes the buffer can take (`max_len`); a longer composition is cut at a cluster
/// boundary for display (the input method still holds all of it, and its commit is cut the
/// same way by `TextEdit.insert`). With `mask` the text is replaced by bullets.
pub fn preedit(comp: *const backend.Composition, mask: bool, room: usize) ?Preedit {
    const full = comp.slice();
    if (full.len == 0) return null;
    const text = full[0..grapheme.snapDown(full, @min(full.len, room))];
    var caret: ?usize = null;
    var clause: ?Range = null;
    if (comp.start < 0) {
        caret = text.len;
    } else {
        const a = codepointOffset(text, @intCast(comp.start));
        if (comp.length > 0) {
            const b = codepointOffset(text, @as(usize, @intCast(comp.start)) + @as(usize, @intCast(comp.length)));
            if (b > a) clause = .{ .start = a, .end = b } else caret = a;
        } else caret = a;
    }
    if (!mask) return .{ .shown = text, .caret = caret, .clause = clause };
    // One bullet per cluster; the offsets become the same cluster counts.
    const n = @min(grapheme.count(text), bullets.len / bullet.len);
    const m: Preedit = .{ .shown = bullets[0 .. n * bullet.len], .caret = null, .clause = null };
    var out = m;
    if (caret) |c| out.caret = @min(grapheme.count(text[0..grapheme.snapDown(text, c)]), n) * bullet.len;
    if (clause) |cl| out.clause = .{
        .start = @min(grapheme.count(text[0..grapheme.snapDown(text, cl.start)]), n) * bullet.len,
        .end = @min(grapheme.count(text[0..grapheme.snapDown(text, cl.end)]), n) * bullet.len,
    };
    return out;
}

/// How much more text a buffer with `max_len` can take once `selected` bytes are replaced.
pub fn roomFor(edit: *const TextEdit, selected: usize) usize {
    return edit.max_len -| (edit.buf.items.len - selected);
}

/// What a widget draws and measures this frame: the buffer text, or a version with the
/// pre-edit spliced in at the caret and/or every cluster replaced by a bullet. `toDisplay`
/// maps buffer offsets to offsets of `text`.
pub const Display = struct {
    src: []const u8,
    text: []const u8,
    masked: bool = false,
    /// The buffer range the pre-edit replaces (the selection, else the caret).
    ins_start: usize = 0,
    ins_end: usize = 0,
    pre: ?Preedit = null,
    /// Where the pre-edit starts in `text`.
    pre_start: usize = 0,

    /// Display length of `src[a..b]`.
    fn baseLen(d: *const Display, a: usize, b: usize) usize {
        if (!d.masked) return b - a;
        return grapheme.count(d.src[a..b]) * bullet.len;
    }

    /// Offset in `text` of buffer offset `o`. Offsets inside the replaced range map to where the
    /// pre-edit starts.
    pub fn toDisplay(d: *const Display, o: usize) usize {
        const off = @min(o, d.src.len);
        var r: usize = undefined;
        if (off <= d.ins_start) {
            r = d.baseLen(0, off);
        } else {
            r = d.baseLen(0, d.ins_start);
            if (off >= d.ins_end) r += (if (d.pre) |p| p.shown.len else 0) + d.baseLen(d.ins_end, off);
        }
        return @min(r, d.text.len);
    }

    pub fn composing(d: *const Display) bool {
        return d.pre != null;
    }

    /// Where the pre-edit ends in `text`.
    pub fn preEnd(d: *const Display) usize {
        return d.pre_start + (if (d.pre) |p| p.shown.len else 0);
    }

    /// The offset in `text` the caret is drawn at when `cursor` is the buffer's caret: inside
    /// the pre-edit where the input method put its own caret, else the mapped caret.
    pub fn caretAt(d: *const Display, cursor: usize) usize {
        if (d.pre) |p| return d.pre_start + (p.caret orelse (if (p.clause) |c| c.end else p.shown.len));
        return d.toDisplay(cursor);
    }
};

/// Builds the `Display` of `src` into `scratch` when needed (a pre-edit or `mask`); otherwise
/// `text` is `src` itself and nothing is allocated. If the allocation fails a masked field
/// shows nothing rather than its text, and `pre` is null (the pre-edit is not shown either).
pub fn display(gpa: std.mem.Allocator, scratch: *std.ArrayList(u8), src: []const u8, mask: bool, pre: ?Preedit, sel: Range) Display {
    var d: Display = .{ .src = src, .text = src, .masked = mask, .ins_start = sel.start, .ins_end = sel.end, .pre = pre };
    if (!mask and pre == null) return d;
    scratch.clearRetainingCapacity();
    const ok = build(gpa, scratch, &d);
    if (!ok) {
        d.text = "";
        d.pre_start = 0;
        d.pre = null; // nothing of it is in `text`
        return d;
    }
    d.text = scratch.items;
    return d;
}

fn build(gpa: std.mem.Allocator, scratch: *std.ArrayList(u8), d: *Display) bool {
    if (d.masked) {
        const n_before = grapheme.count(d.src[0..d.ins_start]);
        const n_after = grapheme.count(d.src[d.ins_end..]);
        appendBulletsTo(scratch, gpa, n_before) catch return false;
        d.pre_start = scratch.items.len;
        if (d.pre) |p| scratch.appendSlice(gpa, p.shown) catch return false;
        appendBulletsTo(scratch, gpa, n_after) catch return false;
        return true;
    }
    scratch.appendSlice(gpa, d.src[0..d.ins_start]) catch return false;
    d.pre_start = scratch.items.len;
    if (d.pre) |p| scratch.appendSlice(gpa, p.shown) catch return false;
    scratch.appendSlice(gpa, d.src[d.ins_end..]) catch return false;
    return true;
}

/// Width of one bullet at `size` (a run of bullets measures the same per bullet).
pub fn bulletWidth(ui: *const Ui, size: f32) f32 {
    return ui.measure(bullets[0 .. 16 * bullet.len], size) / 16;
}

/// Tracks, per widget, a composition that was already going on when the widget got focus: it
/// belongs to what had focus before, so the new widget shows none until the input method sends
/// an empty one. Call each frame with whether the widget is focused and whether a composition
/// exists; returns whether this widget is composing.
pub fn composingNow(was_focused: *bool, blocked: *bool, focused: bool, has_comp: bool) bool {
    if (!has_comp) blocked.* = false;
    if (focused and !was_focused.* and has_comp) blocked.* = true;
    was_focused.* = focused;
    return focused and has_comp and !blocked.*;
}

/// Draws the pre-edit's underline and highlighted clause (`x0` is where the pre-edit starts,
/// `y` the line top, `lh` the line height; `w` measures a display range).
pub const ClauseX = struct { x0: f32, x1: f32 };

pub fn drawPreeditMarks(ui: *Ui, x0: f32, x1: f32, y: f32, lh: f32, clause: ?ClauseX) void {
    const t = ui.theme;
    if (clause) |c| ui.list.rect(.{ .x = c.x0, .y = y, .w = @max(0, c.x1 - c.x0), .h = lh }, t.selection);
    if (x1 > x0) ui.list.rect(.{ .x = x0, .y = y + lh - 2, .w = x1 - x0, .h = 1 }, t.text);
    if (clause) |c| ui.list.rect(.{ .x = c.x0, .y = y + lh - 3, .w = @max(0, c.x1 - c.x0), .h = 2 }, t.text);
}

// ---- keys the input method owns ----------------------------------------------------------------

/// Whether a key press should be ignored by a widget while a composition is showing: the input
/// method owns plain keys (arrows, Backspace, Return, Escape, Tab) then. SDL does not deliver the
/// ones the system input method consumed, so this is a safety net for those it passes on;
/// command shortcuts still work.
pub fn imeOwnsKey(k: backend.Key) bool {
    return !k.mods.cmd and !k.mods.ctrl;
}

// ---- password keys -----------------------------------------------------------------------------

/// Copy and cut (and their command-key forms) are disabled in a password field.
pub fn isCopyOrCut(k: backend.Key) bool {
    return k.mods.cmd and !k.mods.alt and !k.mods.ctrl and (k.code == @import("../core/keys.zig").c or k.code == @import("../core/keys.zig").x);
}

/// In a password field a word is the whole text: Alt+arrows and Alt+Backspace/Delete act as
/// Cmd+arrows (to the ends) and delete to the end.
pub fn passwordKey(k: backend.Key) backend.Key {
    if (!k.mods.alt or k.mods.cmd) return k;
    var out = k;
    out.mods.alt = false;
    out.mods.cmd = true;
    return out;
}

// ---- pasting -------------------------------------------------------------------------------

/// Inserts `str` without carriage returns (pasted CRLF text becomes LF), as one edit of `kind`.
/// Returns whether the text changed: false when nothing was inserted (everything was dropped,
/// or `max_len` is reached) and no selection was replaced.
pub fn insertClean(edit: *TextEdit, str: []const u8, kind: text_edit.EditKind) bool {
    const had_selection = edit.hasSelection();
    const start = edit.selection().start;
    insertCleanRaw(edit, str, kind);
    return had_selection or edit.cursor != start;
}

fn insertCleanRaw(edit: *TextEdit, str: []const u8, kind: text_edit.EditKind) void {
    if (std.mem.indexOfScalar(u8, str, '\r') == null) {
        edit.insertAs(str, kind) catch {};
        return;
    }
    const gpa = edit.gpa;
    if (gpa.alloc(u8, str.len)) |clean| {
        defer gpa.free(clean);
        var n: usize = 0;
        for (str) |b| {
            if (b != '\r') {
                clean[n] = b;
                n += 1;
            }
        }
        edit.insertAs(clean[0..n], kind) catch {};
    } else |_| {
        var parts = std.mem.splitScalar(u8, str, '\r');
        while (parts.next()) |p| {
            if (p.len > 0) edit.insertAs(p, kind) catch {};
        }
    }
}

// ---- context menu ------------------------------------------------------------------------------

pub const Action = enum { undo, redo, cut, copy, paste, select_all };

/// What the menu should offer for the widget it belongs to.
pub const Caps = struct {
    editable: bool,
    has_selection: bool,
    has_text: bool,
    can_undo: bool = false,
    can_redo: bool = false,
    /// False in a password field: Cut and Copy are disabled.
    allow_copy: bool = true,
    /// Whether the clipboard holds text (Paste is disabled otherwise); see `PasteProbe`.
    can_paste: bool = true,
};

/// Whether the clipboard holds text, asked once per time a menu opens (reading the system
/// clipboard copies all of it, which is too much to do every frame the menu stays open).
pub const PasteProbe = struct {
    known: bool = false,
    has_text: bool = false,

    /// The answer, looked up on the first call after `known` was cleared (the widget clears it
    /// once its menu is closed).
    pub fn get(p: *PasteProbe, ui: *const Ui) bool {
        if (!p.known) {
            p.has_text = clipboardHasText(ui);
            p.known = true;
        }
        return p.has_text;
    }
};

const mod_name = if (builtin.os.tag == .macos) "Cmd" else "Ctrl";

/// Whether the clipboard holds text (false when the Ui has no clipboard).
fn clipboardHasText(ui: *const Ui) bool {
    const get = ui.clipboard.get orelse return false;
    const s = get(std.heap.page_allocator) orelse return false;
    defer std.heap.page_allocator.free(s);
    return s.len > 0;
}

/// Draws the context menu while `st` is open and returns the action the user picked this frame
/// (the menu closes itself then). Call every frame the widget is drawn, at the widget's own
/// popup depth (a field inside a popover opens its menu as a child of the popover).
pub fn contextMenu(ui: *Ui, st: *popup.PopupState, caps: Caps) ?Action {
    if (!st.open) return null;
    var items: [8]popup.MenuItem = undefined;
    var acts: [8]?Action = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(it: *[8]popup.MenuItem, ac: *[8]?Action, k: *usize, item: popup.MenuItem, a: ?Action) void {
            it[k.*] = item;
            ac[k.*] = a;
            k.* += 1;
        }
    }.f;
    const can_copy = caps.has_selection and caps.allow_copy;
    if (caps.editable) {
        add(&items, &acts, &n, .{ .label = "Undo", .shortcut = mod_name ++ "+Z", .disabled = !caps.can_undo }, .undo);
        add(&items, &acts, &n, .{ .label = "Redo", .shortcut = mod_name ++ "+Shift+Z", .disabled = !caps.can_redo }, .redo);
        add(&items, &acts, &n, .{ .separator = true }, null);
        add(&items, &acts, &n, .{ .label = "Cut", .shortcut = mod_name ++ "+X", .disabled = !can_copy }, .cut);
        add(&items, &acts, &n, .{ .label = "Copy", .shortcut = mod_name ++ "+C", .disabled = !can_copy }, .copy);
        add(&items, &acts, &n, .{ .label = "Paste", .shortcut = mod_name ++ "+V", .disabled = !caps.can_paste }, .paste);
    } else {
        add(&items, &acts, &n, .{ .label = "Copy", .shortcut = mod_name ++ "+C", .disabled = !can_copy }, .copy);
    }
    add(&items, &acts, &n, .{ .separator = true }, null);
    add(&items, &acts, &n, .{ .label = "Select All", .shortcut = mod_name ++ "+A", .disabled = !caps.has_text }, .select_all);
    const picked = ui.menu(st, st.pointAnchor(), items[0..n], .{ .placement = .at_point, .min_width = 190 }) orelse return null;
    return acts[picked];
}

/// Applies a picked `Action` to `edit` (all of them but copy and cut-less ones edit the text);
/// returns whether the text changed. `Copy` and `Cut` go to the clipboard; Cut and Copy must not
/// be offered for a password field (the menu disables them, and this refuses too).
pub fn applyAction(ui: *const Ui, edit: *TextEdit, act: Action, allow_copy: bool) bool {
    switch (act) {
        .undo => return edit.undo(),
        .redo => return edit.redo(),
        .cut => {
            if (!allow_copy or !edit.hasSelection()) return false;
            const s = edit.cut() catch return false;
            ui.clipboardSet(s);
            return true;
        },
        .copy => {
            if (allow_copy and edit.hasSelection()) ui.clipboardSet(edit.copy());
            return false;
        },
        .paste => {
            const get = ui.clipboard.get orelse return false;
            const s = get(edit.gpa) orelse return false;
            defer edit.gpa.free(s);
            if (s.len == 0) return false;
            return insertClean(edit, s, .paste);
        },
        .select_all => {
            edit.selectAll();
            return false;
        },
    }
}
