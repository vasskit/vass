//! A pure text editing core: a UTF-8 buffer with a cursor and a selection.
//! No rendering and no platform calls, so everything here is unit-tested.
//!
//! `cursor` and `anchor` are byte offsets that sit on extended grapheme cluster
//! boundaries (`grapheme.zig`, UAX #29), which are also UTF-8 code point
//! boundaries. The selection is the range between them; with `anchor == cursor`
//! there is none. Movement and deletion are per cluster, so a base letter with
//! its combining marks, an emoji ZWJ sequence, a flag or a Hangul syllable moves
//! and deletes as one character. Backspace removes the whole cluster before the
//! caret (macOS can peel the last code point off a decomposed sequence; this does
//! not). A caret can only end up inside a cluster when text is inserted in front
//! of a combining mark by other means than the keyboard; it is then drawn at the
//! cluster's start and the next movement leaves the cluster.
//!
//! Clipboard access stays outside: `copy`/`cut` return the text for the caller
//! to put on the clipboard, and `insert` takes what the caller pasted.
//!
//! Every edit is recorded in `history` (see `undo.zig`) as a delta, with typing
//! runs coalesced the way macOS does; `undo`/`redo` (Cmd+Z, Cmd+Shift+Z) replay
//! them and restore the caret and selection. `setText` and `clear` forget the
//! history; `replaceAll` is the undoable way to swap the whole text.
const std = @import("std");
const builtin = @import("builtin");
const keys = @import("keys.zig");
const undo_mod = @import("undo.zig");
const grapheme = @import("grapheme.zig");

pub const History = undo_mod.History;
pub const EditKind = undo_mod.Kind;
pub const HistoryLimits = undo_mod.Limits;

pub const Mods = keys.Mods;

pub const Move = enum { left, right, word_left, word_right, home, end };

/// What `handleKey` did, so the caller knows what else to do.
pub const Action = union(enum) {
    /// The key means nothing to a text field; the caller may use it.
    none,
    /// Consumed, text unchanged (cursor or selection may have moved).
    handled,
    /// Consumed, text changed.
    changed,
    /// Put this text on the clipboard. Valid until the next edit.
    copy: []const u8,
    /// Put this text on the clipboard; the text changed. Valid until the next edit.
    cut: []const u8,
    /// Fetch the clipboard and pass it to `insert`.
    paste,
    /// Return was pressed.
    submit,
    /// Escape was pressed.
    cancel,
};

pub const TextEdit = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    anchor: usize = 0,
    /// If false (default), `insert` drops line breaks.
    multiline: bool = false,
    /// Longest text `insert` will grow the buffer to, in bytes.
    max_len: usize = std.math.maxInt(usize),
    /// Holds the text returned by `cut`.
    scratch: std.ArrayList(u8) = .empty,
    /// Undo/redo history. Starts empty and is freed by `deinit`; tune `history.limits`
    /// (entry and byte caps, the typing pause) if the defaults do not suit.
    history: History = .{},
    /// The current time in seconds, on any steady clock. The widgets copy
    /// `Input.time` here each frame; a typing run is ended by a pause of more than
    /// `history.limits.pause` seconds. Set it yourself when using `TextEdit` alone
    /// (tests inject time this way).
    now: f64 = 0,
    /// Also accept Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y as undo and redo. On by default
    /// everywhere but macOS (where Ctrl is not the shortcut key). Cmd+Z / Cmd+Shift+Z
    /// always work.
    ctrl_undo: bool = builtin.os.tag != .macos,
    /// Counts successful `undo`/`redo` calls, so a widget can tell the text was
    /// changed under the caret (and scroll it into view).
    undo_serial: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) TextEdit {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *TextEdit) void {
        e.history.deinit(e.gpa);
        e.buf.deinit(e.gpa);
        e.scratch.deinit(e.gpa);
    }

    pub fn text(e: *const TextEdit) []const u8 {
        return e.buf.items;
    }

    /// Replaces everything with `str` (invalid UTF-8 and, unless `multiline`,
    /// line breaks are dropped); the cursor goes to the end. This is a
    /// programmatic reset, not an edit: it clears the undo history. Use
    /// `replaceAll` for a replacement the user can undo.
    pub fn setText(e: *TextEdit, str: []const u8) !void {
        defer e.history.clear(e.gpa);
        e.buf.clearRetainingCapacity();
        e.cursor = 0;
        e.anchor = 0;
        try e.insert(str);
    }

    /// Replaces everything with `str` like `setText`, but as one undoable step
    /// (and the history is kept).
    pub fn replaceAll(e: *TextEdit, str: []const u8) !void {
        e.selectAll();
        try e.insertAs(str, .other);
    }

    /// Empties the text and clears the undo history.
    pub fn clear(e: *TextEdit) void {
        e.buf.clearRetainingCapacity();
        e.cursor = 0;
        e.anchor = 0;
        e.history.clear(e.gpa);
    }

    // ---- undo / redo ---------------------------------------------------

    pub fn canUndo(e: *const TextEdit) bool {
        return e.history.canUndo();
    }

    pub fn canRedo(e: *const TextEdit) bool {
        return e.history.canRedo();
    }

    /// Forgets all undo and redo steps (the text stays).
    pub fn clearHistory(e: *TextEdit) void {
        e.history.clear(e.gpa);
    }

    fn sel(e: *const TextEdit) undo_mod.Sel {
        return .{ .cursor = e.cursor, .anchor = e.anchor };
    }

    /// Whether the buffer holds `bytes` at `offset`, with both ends on character
    /// boundaries: the check that a history entry still applies.
    fn matches(e: *const TextEdit, offset: usize, bytes: []const u8) bool {
        const s = e.buf.items;
        if (offset > s.len or s.len - offset < bytes.len) return false;
        if (!std.mem.eql(u8, s[offset..][0..bytes.len], bytes)) return false;
        return snap(s, offset) == offset and snap(s, offset + bytes.len) == offset + bytes.len;
    }

    fn restoreSel(e: *TextEdit, s: undo_mod.Sel) void {
        e.cursor = snap(e.buf.items, s.cursor);
        e.anchor = snap(e.buf.items, s.anchor);
        e.undo_serial +%= 1;
    }

    /// Reverts the newest step: restores the text, caret and selection from
    /// before it. Returns false if there is nothing to undo (or it cannot be done:
    /// out of memory or `max_len`; if the text was changed behind the history's
    /// back the history is dropped).
    pub fn undo(e: *TextEdit) bool {
        const en = e.history.peekUndo() orelse return false;
        if (!e.matches(en.offset, en.inserted())) {
            e.history.clear(e.gpa);
            return false;
        }
        const len = e.buf.items.len - en.inserted().len + en.removed().len;
        if (len > e.max_len and en.removed().len > en.inserted().len) return false;
        e.history.reserve(e.gpa) catch return false;
        e.buf.replaceRange(e.gpa, en.offset, en.inserted().len, en.removed()) catch return false;
        e.history.moveToRedo();
        e.restoreSel(en.before);
        return true;
    }

    /// Re-applies the newest undone step. Returns false if there is nothing to redo.
    pub fn redo(e: *TextEdit) bool {
        const en = e.history.peekRedo() orelse return false;
        if (!e.matches(en.offset, en.removed())) {
            e.history.clear(e.gpa);
            return false;
        }
        const len = e.buf.items.len - en.removed().len + en.inserted().len;
        if (len > e.max_len and en.inserted().len > en.removed().len) return false;
        e.history.reserve(e.gpa) catch return false;
        e.buf.replaceRange(e.gpa, en.offset, en.removed().len, en.inserted()) catch return false;
        e.history.moveToUndo();
        e.restoreSel(en.after);
        return true;
    }

    // ---- selection ---------------------------------------------------

    pub const Range = struct { start: usize, end: usize };

    pub fn selection(e: *const TextEdit) Range {
        return .{ .start = @min(e.cursor, e.anchor), .end = @max(e.cursor, e.anchor) };
    }

    pub fn hasSelection(e: *const TextEdit) bool {
        return e.cursor != e.anchor;
    }

    pub fn selectedText(e: *const TextEdit) []const u8 {
        const s = e.selection();
        return e.buf.items[s.start..s.end];
    }

    pub fn selectAll(e: *TextEdit) void {
        e.history.breakGroup();
        e.anchor = 0;
        e.cursor = e.buf.items.len;
    }

    /// Moves the cursor to byte offset `pos` (clamped, and moved back to the
    /// start of its grapheme cluster). With `extend` the anchor stays, growing the selection.
    pub fn moveTo(e: *TextEdit, pos: usize, extend: bool) void {
        e.history.breakGroup();
        e.cursor = snapCluster(e.buf.items, pos);
        if (!extend) e.anchor = e.cursor;
    }

    /// Selects from `anchor` to `cursor` (byte offsets, moved back to cluster starts).
    pub fn select(e: *TextEdit, anchor: usize, cursor: usize) void {
        e.history.breakGroup();
        e.anchor = snapCluster(e.buf.items, anchor);
        e.cursor = snapCluster(e.buf.items, cursor);
    }

    /// Moves the cursor. Without `extend`, an existing selection collapses to
    /// its near edge for left/right (like every native text field).
    pub fn move(e: *TextEdit, m: Move, extend: bool) void {
        const s = e.buf.items;
        if (!extend and e.hasSelection()) switch (m) {
            .left, .word_left => return e.moveTo(e.selection().start, false),
            .right, .word_right => return e.moveTo(e.selection().end, false),
            else => {},
        };
        const target = switch (m) {
            .left => prevBoundary(s, e.cursor),
            .right => nextBoundary(s, e.cursor),
            .word_left => wordStart(s, e.cursor),
            .word_right => wordEnd(s, e.cursor),
            .home => lineStart(s, e.cursor),
            .end => lineEnd(s, e.cursor),
        };
        e.moveTo(target, extend);
    }

    // ---- editing -----------------------------------------------------

    /// Replaces the selection (if any) with `str` and puts the cursor after it.
    /// Invalid UTF-8 is dropped, as are line breaks unless `multiline`, and
    /// anything past `max_len`. Recorded in the history as typing (consecutive
    /// calls coalesce); see `insertAs` for other kinds.
    pub fn insert(e: *TextEdit, str: []const u8) !void {
        return e.insertAs(str, .typing);
    }

    /// Like `insert`, recorded as an edit of `kind` (`.paste` for pasted text, ...).
    /// Over a selection the step is a `.replace` unless `kind` is not `.typing`.
    /// Whatever happens to the history, the edit itself is never lost.
    pub fn insertAs(e: *TextEdit, str: []const u8, kind: EditKind) !void {
        const before = e.sel();
        const start = e.selection().start;
        const had_selection = e.hasSelection();
        var truncated = false;
        // The selection is about to be overwritten: keep a copy for the history.
        var removed: []u8 = &.{};
        var lost = false;
        if (had_selection) {
            if (e.gpa.dupe(u8, e.selectedText())) |d| removed = d else |_| lost = true;
        }
        defer if (had_selection and !lost) e.gpa.free(removed);
        // Runs last (after the anchor below is settled), also when an allocation failed midway.
        defer {
            const inserted = e.buf.items[start..e.cursor];
            if (lost) {
                e.history.clear(e.gpa);
            } else {
                const k: EditKind = if (kind == .typing)
                    (if (had_selection) .replace else if (std.mem.eql(u8, inserted, "\n") or std.mem.eql(u8, inserted, "\r")) .newline else .typing)
                else
                    kind;
                e.history.record(e.gpa, .{
                    .offset = start,
                    .removed = removed,
                    .inserted = inserted,
                    .before = before,
                    .after = .{ .cursor = e.cursor, .anchor = e.cursor },
                    .kind = k,
                    .joins = start > 0 and !had_selection and inserted.len > 0 and !grapheme.isBoundary(e.buf.items, start),
                }, e.now);
            }
        }
        defer e.anchor = e.cursor;
        // Cut short by `max_len`: never leave half a cluster (a ZWJ sequence, a flag) behind. The
        // piece that did not fit decides: if it would have joined the last cluster, that cluster
        // goes too.
        var cut_piece: []const u8 = "";
        defer if (truncated) {
            const gpa = e.gpa;
            const at = e.cursor;
            if (e.buf.insertSlice(gpa, at, cut_piece)) {
                var p = at;
                while (p > start and !grapheme.isBoundary(e.buf.items, p)) p = grapheme.prevBoundary(e.buf.items, p);
                p = @max(p, start);
                e.buf.replaceRangeAssumeCapacity(at, cut_piece.len, &.{});
                if (p < at) {
                    e.buf.replaceRangeAssumeCapacity(p, at - p, &.{});
                    e.cursor = p;
                }
            } else |_| {}
        };
        e.deleteRangeRaw(e.selection().start, e.selection().end);
        var i: usize = 0;
        while (i < str.len) {
            const n = std.unicode.utf8ByteSequenceLength(str[i]) catch {
                i += 1;
                continue;
            };
            if (i + n > str.len or !std.unicode.utf8ValidateSlice(str[i .. i + n])) {
                i += 1;
                continue;
            }
            const piece = str[i .. i + n];
            i += n;
            if (!e.multiline and (piece[0] == '\n' or piece[0] == '\r')) continue;
            if (e.buf.items.len + n > e.max_len) {
                truncated = true;
                cut_piece = piece;
                break;
            }
            try e.buf.insertSlice(e.gpa, e.cursor, piece);
            e.cursor += n;
        }
    }

    fn deleteRangeRaw(e: *TextEdit, start: usize, end: usize) void {
        e.buf.replaceRangeAssumeCapacity(start, end - start, &.{});
        e.cursor = start;
        e.anchor = start;
    }

    /// Deletes bytes `start..end` (on character boundaries) and records it.
    fn deleteRange(e: *TextEdit, start: usize, end: usize, kind: EditKind) void {
        e.history.record(e.gpa, .{
            .offset = start,
            .removed = e.buf.items[start..end],
            .inserted = "",
            .before = e.sel(),
            .after = .{ .cursor = start, .anchor = start },
            .kind = kind,
        }, e.now);
        e.deleteRangeRaw(start, end);
    }

    /// Removes the selection; returns whether there was one.
    pub fn deleteSelection(e: *TextEdit) bool {
        return e.deleteSelectionAs(.replace);
    }

    fn deleteSelectionAs(e: *TextEdit, kind: EditKind) bool {
        if (!e.hasSelection()) return false;
        const s = e.selection();
        e.deleteRange(s.start, s.end, kind);
        return true;
    }

    /// Deletes the selection, or else the character (or `by` span) before the cursor.
    pub fn backspace(e: *TextEdit, by: enum { char, word, line }) bool {
        if (e.deleteSelection()) return true;
        const s = e.buf.items;
        if (e.cursor == 0) return false;
        const from = switch (by) {
            .char => prevBoundary(s, e.cursor),
            .word => wordStart(s, e.cursor),
            .line => lineStart(s, e.cursor),
        };
        // Already at a line start: "delete to line start" removes the break.
        const start = if (from == e.cursor) prevBoundary(s, e.cursor) else from;
        e.deleteRange(start, e.cursor, if (by == .char) .backspace else .other);
        return true;
    }

    /// Deletes the selection, or else the character (or `by` span) after the cursor.
    pub fn delete(e: *TextEdit, by: enum { char, word, line }) bool {
        if (e.deleteSelection()) return true;
        const s = e.buf.items;
        if (e.cursor >= s.len) return false;
        const to = switch (by) {
            .char => nextBoundary(s, e.cursor),
            .word => wordEnd(s, e.cursor),
            .line => lineEnd(s, e.cursor),
        };
        const end = if (to == e.cursor) nextBoundary(s, e.cursor) else to;
        e.deleteRange(e.cursor, end, if (by == .char) .forward_delete else .other);
        return true;
    }

    // ---- clipboard hooks ----------------------------------------------

    /// The selected text, to put on the clipboard (empty if nothing is selected).
    pub fn copy(e: *const TextEdit) []const u8 {
        return e.selectedText();
    }

    /// Removes the selection and returns it for the clipboard; the slice stays
    /// valid until the next `cut`. Empty if nothing is selected.
    pub fn cut(e: *TextEdit) ![]const u8 {
        e.scratch.clearRetainingCapacity();
        try e.scratch.appendSlice(e.gpa, e.selectedText());
        _ = e.deleteSelectionAs(.cut);
        return e.scratch.items;
    }

    // ---- keys --------------------------------------------------------

    /// The one entry point for key presses (not text; that goes to `insert`).
    /// Follows macOS conventions: alt = by word, cmd = to line edge or
    /// select-all / copy / cut / paste, shift extends the selection.
    pub fn handleKey(e: *TextEdit, key: u32, mods: Mods) !Action {
        const ext = mods.shift;
        if (mods.cmd and !mods.alt and !mods.ctrl) {
            switch (key) {
                keys.a => {
                    e.selectAll();
                    return .handled;
                },
                keys.c => return if (e.hasSelection()) .{ .copy = e.copy() } else .handled,
                keys.x => {
                    if (!e.hasSelection()) return .handled;
                    return .{ .cut = try e.cut() };
                },
                keys.v => return .paste,
                keys.z => return e.edited(if (ext) e.redo() else e.undo()),
                keys.left => return e.go(.home, ext),
                keys.right => return e.go(.end, ext),
                keys.up => return e.go(.home, ext),
                keys.down => return e.go(.end, ext),
                keys.backspace => return e.edited(e.backspace(.line)),
                keys.delete => return e.edited(e.delete(.line)),
                else => return .none,
            }
        }
        if (e.ctrl_undo and mods.ctrl and !mods.cmd and !mods.alt) switch (key) {
            keys.z => return e.edited(if (ext) e.redo() else e.undo()),
            keys.y => return e.edited(e.redo()),
            else => {},
        };
        if (mods.cmd or mods.ctrl) return .none;
        const word = mods.alt;
        switch (key) {
            keys.left => return e.go(if (word) .word_left else .left, ext),
            keys.right => return e.go(if (word) .word_right else .right, ext),
            keys.home, keys.up => return e.go(.home, ext),
            keys.end, keys.down => return e.go(.end, ext),
            keys.backspace => return e.edited(e.backspace(if (word) .word else .char)),
            keys.delete => return e.edited(e.delete(if (word) .word else .char)),
            keys.@"return" => return .submit,
            keys.escape => return .cancel,
            else => return .none,
        }
    }

    fn go(e: *TextEdit, m: Move, extend: bool) Action {
        e.move(m, extend);
        return .handled;
    }

    fn edited(_: *TextEdit, changed: bool) Action {
        return if (changed) .changed else .handled;
    }
};

// ---- UTF-8 and word helpers ---------------------------------------------

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Moves `pos` back to the start of the character it is inside (clamped to the length).
pub fn snap(s: []const u8, pos: usize) usize {
    var p = @min(pos, s.len);
    while (p > 0 and p < s.len and isContinuation(s[p])) p -= 1;
    return p;
}

/// Moves `pos` back to the start of the grapheme cluster it is inside (clamped to the length).
/// `snap` does the same for code points only.
pub fn snapCluster(s: []const u8, pos: usize) usize {
    return grapheme.snapDown(s, pos);
}

/// The previous grapheme cluster boundary before `pos` (0 at the start).
pub fn prevBoundary(s: []const u8, pos: usize) usize {
    return grapheme.prevBoundary(s, pos);
}

/// The next grapheme cluster boundary after `pos` (the length at the end).
pub fn nextBoundary(s: []const u8, pos: usize) usize {
    return grapheme.nextBoundary(s, pos);
}

/// Word characters: ASCII letters and digits, '_', and anything non-ASCII.
fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Start of the word at or before `pos` (skipping separators first). Steps by cluster, so it
/// never stops inside one (a combining mark after a space stays with its base).
pub fn wordStart(s: []const u8, pos: usize) usize {
    var p = snapCluster(s, pos);
    while (p > 0) {
        const q = prevBoundary(s, p);
        if (isWordByte(s[q])) break;
        p = q;
    }
    while (p > 0) {
        const q = prevBoundary(s, p);
        if (!isWordByte(s[q])) break;
        p = q;
    }
    return p;
}

/// End of the word at or after `pos` (skipping separators first).
pub fn wordEnd(s: []const u8, pos: usize) usize {
    var p = snapCluster(s, pos);
    while (p < s.len and !isWordByte(s[p])) p = nextBoundary(s, p);
    while (p < s.len and isWordByte(s[p])) p = nextBoundary(s, p);
    return p;
}

fn byteClass(b: u8) u8 {
    if (b == '\n' or b == '\r') return 3;
    if (b == ' ' or b == '\t') return 1;
    if (isWordByte(b)) return 0;
    return 2;
}

/// Start and end of the "word" at caret position `pos`: the run of same-class
/// clusters (word characters, blanks, other punctuation) around it. Newlines
/// are never included. The ends are cluster boundaries.
pub fn wordRange(str: []const u8, pos: usize) TextEdit.Range {
    if (str.len == 0) return .{ .start = 0, .end = 0 };
    var p = snapCluster(str, pos);
    if (p >= str.len) p = prevBoundary(str, str.len);
    const cls = byteClass(str[p]);
    var s = p;
    while (s > 0) {
        const q = prevBoundary(str, s);
        if (byteClass(str[q]) != cls) break;
        s = q;
    }
    var e = nextBoundary(str, p);
    while (e < str.len and byteClass(str[e]) == cls) e = nextBoundary(str, e);
    return .{ .start = s, .end = e };
}

/// The unit a mouse selection grows by.
pub const Granularity = enum { char, word, line };

/// Mouse selection by click count, shared by every text widget: a double click selects the word,
/// a triple click the line (between newlines; a single-line field has one), and dragging after
/// either grows the selection by whole words or lines, like macOS. Keep one next to the
/// widget's selection (`begin` on the press, `extend` while the button is held).
pub const MultiClick = struct {
    gran: Granularity = .char,
    /// The word or line that was selected by the click.
    start: usize = 0,
    end: usize = 0,

    pub const Sel = struct { anchor: usize, cursor: usize };

    /// A press at byte offset `off` with click number `clicks` (0 and 1 are single). For a double
    /// or triple click returns the range to select; null for a single click (the caller places
    /// the caret). With `all` the double click selects everything too (password fields).
    pub fn begin(m: *MultiClick, str: []const u8, off: usize, clicks: u8, all: bool) ?TextEdit.Range {
        if (clicks < 2) {
            m.* = .{};
            return null;
        }
        const r: TextEdit.Range = if (all)
            .{ .start = 0, .end = str.len }
        else if (clicks == 2)
            wordRange(str, off)
        else
            .{ .start = lineStart(str, off), .end = lineEnd(str, off) };
        // With `all` there is nothing to grow (a drag keeps everything selected).
        m.* = .{ .gran = if (all) .char else if (clicks > 2) .line else .word, .start = r.start, .end = r.end };
        return r;
    }

    /// The selection while the pointer is at byte offset `off` after a `begin`: the clicked
    /// word or line joined with the word or line under the pointer.
    pub fn extend(m: MultiClick, str: []const u8, off: usize) Sel {
        const unit: TextEdit.Range = switch (m.gran) {
            .char => .{ .start = off, .end = off },
            .word => wordRange(str, off),
            .line => .{ .start = lineStart(str, off), .end = lineEnd(str, off) },
        };
        if (m.gran == .char) return .{ .anchor = m.start, .cursor = m.end };
        if (off < m.start) return .{ .anchor = m.end, .cursor = unit.start };
        if (off > m.end) return .{ .anchor = m.start, .cursor = unit.end };
        return .{ .anchor = m.start, .cursor = m.end };
    }
};

/// Start of the line (after the previous '\n') that contains `pos`.
pub fn lineStart(s: []const u8, pos: usize) usize {
    var p = @min(pos, s.len);
    while (p > 0 and s[p - 1] != '\n') p -= 1;
    return p;
}

pub fn lineEnd(s: []const u8, pos: usize) usize {
    var p = @min(pos, s.len);
    while (p < s.len and s[p] != '\n') p += 1;
    return p;
}

// ---- tests ---------------------------------------------------------------

const t = std.testing;

fn fresh(str: []const u8) !TextEdit {
    var e = TextEdit.init(t.allocator);
    errdefer e.deinit();
    try e.insert(str);
    return e;
}

fn expectText(e: *const TextEdit, str: []const u8, cursor: usize, anchor: usize) !void {
    try t.expectEqualStrings(str, e.text());
    try t.expectEqual(cursor, e.cursor);
    try t.expectEqual(anchor, e.anchor);
}

test "insert at the cursor and advance it" {
    var e = try fresh("");
    defer e.deinit();
    try e.insert("hello");
    try expectText(&e, "hello", 5, 5);
    e.moveTo(2, false);
    try e.insert("XY");
    try expectText(&e, "heXYllo", 4, 4);
}

test "insert replaces the selection" {
    var e = try fresh("hello world");
    defer e.deinit();
    e.moveTo(6, false);
    e.moveTo(11, true);
    try t.expectEqualStrings("world", e.selectedText());
    try e.insert("zig");
    try expectText(&e, "hello zig", 9, 9);
    // A backwards selection works the same.
    e.moveTo(9, false);
    e.moveTo(6, true);
    try e.insert("!");
    try expectText(&e, "hello !", 7, 7);
}

test "multi-byte characters move and delete whole" {
    var e = try fresh("aé😀b");
    defer e.deinit();
    // bytes: a(1) é(2) 😀(4) b(1)
    try t.expectEqual(@as(usize, 8), e.text().len);
    e.move(.left, false);
    try t.expectEqual(@as(usize, 7), e.cursor);
    e.move(.left, false);
    try t.expectEqual(@as(usize, 3), e.cursor); // over the emoji
    e.move(.left, false);
    try t.expectEqual(@as(usize, 1), e.cursor); // over é
    e.move(.right, false);
    try t.expectEqual(@as(usize, 3), e.cursor);
    try t.expect(e.backspace(.char)); // removes é
    try expectText(&e, "a😀b", 1, 1);
    try t.expect(e.delete(.char)); // removes the emoji
    try expectText(&e, "ab", 1, 1);
    // Backspace of an emoji.
    var f = try fresh("x😀");
    defer f.deinit();
    try t.expect(f.backspace(.char));
    try expectText(&f, "x", 1, 1);
}

test "grapheme clusters move, select and delete as one character" {
    const family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    var e = try fresh("e\u{301}" ++ family ++ "\u{1F1F3}\u{1F1EC}!");
    defer e.deinit();
    e.moveTo(0, false);
    e.move(.right, false);
    try t.expectEqual(@as(usize, 3), e.cursor);
    e.move(.right, true);
    try t.expectEqualStrings(family, e.selectedText());
    e.moveTo(4, false); // inside the family: back to the start of its cluster
    try t.expectEqual(@as(usize, 3), e.cursor);
    e.moveTo(e.text().len, false);
    e.move(.left, false);
    try t.expect(e.backspace(.char)); // the flag
    try t.expect(e.backspace(.char)); // the family
    try t.expectEqualStrings("e\u{301}!", e.text());
    e.moveTo(0, false);
    try t.expect(e.delete(.char));
    try t.expectEqualStrings("!", e.text());
}

test "MultiClick: word and line units, growing in both directions" {
    const s = "one two three\nfour";
    var m: MultiClick = .{};
    try t.expect(m.begin(s, 5, 1, false) == null);
    const w = m.begin(s, 5, 2, false).?;
    try t.expectEqual(@as(usize, 4), w.start);
    try t.expectEqual(@as(usize, 7), w.end);
    var x = m.extend(s, 9);
    try t.expectEqual(@as(usize, 4), x.anchor);
    try t.expectEqual(@as(usize, 13), x.cursor);
    x = m.extend(s, 0);
    try t.expectEqual(@as(usize, 7), x.anchor);
    try t.expectEqual(@as(usize, 0), x.cursor);
    x = m.extend(s, 5); // back inside the clicked word: just the word
    try t.expectEqual(@as(usize, 4), x.anchor);
    try t.expectEqual(@as(usize, 7), x.cursor);
    const l = m.begin(s, 5, 3, false).?;
    try t.expectEqual(@as(usize, 0), l.start);
    try t.expectEqual(@as(usize, 13), l.end);
    x = m.extend(s, 16);
    try t.expectEqual(@as(usize, 0), x.anchor);
    try t.expectEqual(@as(usize, 18), x.cursor);
    const all = m.begin(s, 5, 2, true).?;
    try t.expectEqual(s.len, all.end);
}

test "moveTo snaps into the middle of a character back to its start" {
    var e = try fresh("é😀");
    defer e.deinit();
    e.moveTo(1, false);
    try t.expectEqual(@as(usize, 0), e.cursor);
    e.moveTo(4, false);
    try t.expectEqual(@as(usize, 2), e.cursor);
    e.moveTo(1000, false);
    try t.expectEqual(@as(usize, 6), e.cursor);
}

test "backspace and delete at the edges do nothing" {
    var e = try fresh("ab");
    defer e.deinit();
    e.moveTo(0, false);
    try t.expect(!e.backspace(.char));
    e.moveTo(2, false);
    try t.expect(!e.delete(.char));
    try expectText(&e, "ab", 2, 2);
}

test "backspace and delete remove the selection first" {
    var e = try fresh("abcdef");
    defer e.deinit();
    e.moveTo(1, false);
    e.moveTo(4, true);
    try t.expect(e.backspace(.char));
    try expectText(&e, "aef", 1, 1);
    e.moveTo(0, false);
    e.moveTo(2, true);
    try t.expect(e.delete(.word));
    try expectText(&e, "f", 0, 0);
}

test "selection with shift and collapsing without it" {
    var e = try fresh("héllo");
    defer e.deinit();
    e.moveTo(0, false);
    e.move(.right, true);
    e.move(.right, true);
    try expectText(&e, "héllo", 3, 0);
    try t.expectEqualStrings("hé", e.selectedText());
    e.move(.left, true);
    try t.expectEqualStrings("h", e.selectedText());
    // Plain right collapses to the selection's end and does not also advance.
    e.move(.right, true);
    e.move(.right, false);
    try expectText(&e, "héllo", 3, 3);
    // Plain left collapses to the start.
    e.moveTo(4, true);
    e.move(.left, false);
    try expectText(&e, "héllo", 3, 3);
}

test "left and right stop at the ends" {
    var e = try fresh("é");
    defer e.deinit();
    e.move(.right, false);
    try t.expectEqual(@as(usize, 2), e.cursor);
    e.moveTo(0, false);
    e.move(.left, false);
    try t.expectEqual(@as(usize, 0), e.cursor);
}

test "word movement and word deletion" {
    var e = try fresh("hello wörld,  foo");
    defer e.deinit();
    e.moveTo(0, false);
    e.move(.word_right, false);
    try t.expectEqual(@as(usize, 5), e.cursor);
    e.move(.word_right, false);
    try t.expectEqual(@as(usize, 12), e.cursor); // after "wörld" (6 + 6 bytes)
    e.move(.word_right, false);
    try t.expectEqual(@as(usize, 18), e.cursor);
    e.move(.word_right, false);
    try t.expectEqual(@as(usize, 18), e.cursor);
    e.move(.word_left, false);
    try t.expectEqual(@as(usize, 15), e.cursor);
    e.move(.word_left, false);
    try t.expectEqual(@as(usize, 6), e.cursor);
    try t.expect(e.backspace(.word));
    try expectText(&e, "wörld,  foo", 0, 0);
    try t.expect(e.delete(.word));
    try expectText(&e, ",  foo", 0, 0);
}

test "home and end work per line" {
    var e = try fresh("ab");
    defer e.deinit();
    e.multiline = true;
    try e.insert("\ncd");
    // "ab\ncd", cursor at 5
    e.move(.home, false);
    try t.expectEqual(@as(usize, 3), e.cursor);
    e.move(.end, true);
    try expectText(&e, "ab\ncd", 5, 3);
    e.moveTo(1, false);
    e.move(.end, false);
    try t.expectEqual(@as(usize, 2), e.cursor);
    e.move(.home, true);
    try expectText(&e, "ab\ncd", 0, 2);
}

test "select all, then typing replaces everything" {
    var e = try fresh("héllo wörld");
    defer e.deinit();
    e.selectAll();
    try t.expectEqualStrings("héllo wörld", e.selectedText());
    try e.insert("x");
    try expectText(&e, "x", 1, 1);
    // Select all of nothing is no selection.
    e.clear();
    e.selectAll();
    try t.expect(!e.hasSelection());
}

test "copy, cut and paste hooks" {
    var e = try fresh("one two");
    defer e.deinit();
    e.moveTo(4, false);
    e.moveTo(7, true);
    try t.expectEqualStrings("two", e.copy());
    try t.expectEqualStrings("one two", e.text());
    const cut = try e.cut();
    try t.expectEqualStrings("two", cut);
    try expectText(&e, "one ", 4, 4);
    // The cut text outlives the deletion.
    try e.insert("overwrite-the-old-bytes");
    try t.expectEqualStrings("two", cut);
    // Nothing selected: empty.
    try t.expectEqualStrings("", e.copy());
    try t.expectEqualStrings("", try e.cut());
}

test "insert drops line breaks, invalid UTF-8 and honours max_len" {
    var e = try fresh("");
    defer e.deinit();
    try e.insert("a\nb\r\nc");
    try t.expectEqualStrings("abc", e.text());
    try e.insert("x\xFFy\xC3"); // stray bytes, truncated sequence
    try t.expectEqualStrings("abcxy", e.text());
    e.multiline = true;
    try e.insert("\n");
    try t.expectEqualStrings("abcxy\n", e.text());
    e.max_len = 8;
    try e.insert("éé"); // 4 bytes, only one fits
    try t.expectEqualStrings("abcxy\né", e.text());
    try t.expect(e.text().len <= 8);
}

test "setText replaces and puts the cursor at the end" {
    var e = try fresh("old");
    defer e.deinit();
    try e.setText("héllo");
    try expectText(&e, "héllo", 6, 6);
}

test "handleKey: movement, selection, deletion" {
    var e = try fresh("héllo");
    defer e.deinit();
    try t.expectEqual(Action.handled, try e.handleKey(keys.home, .{}));
    try t.expectEqual(@as(usize, 0), e.cursor);
    try t.expectEqual(Action.handled, try e.handleKey(keys.right, .{ .shift = true }));
    try t.expectEqual(Action.handled, try e.handleKey(keys.right, .{ .shift = true }));
    try t.expectEqualStrings("hé", e.selectedText());
    try t.expectEqual(Action.changed, try e.handleKey(keys.backspace, .{}));
    try expectText(&e, "llo", 0, 0);
    try t.expectEqual(Action.handled, try e.handleKey(keys.backspace, .{})); // at start: nothing to do
    try t.expectEqual(Action.changed, try e.handleKey(keys.delete, .{}));
    try t.expectEqualStrings("lo", e.text());
    try t.expectEqual(Action.handled, try e.handleKey(keys.right, .{ .alt = true }));
    try t.expectEqual(@as(usize, 2), e.cursor);
    try t.expectEqual(Action.changed, try e.handleKey(keys.backspace, .{ .alt = true }));
    try t.expectEqualStrings("", e.text());
    try t.expectEqual(Action.handled, try e.handleKey(keys.end, .{}));
}

test "handleKey: cmd shortcuts and special keys" {
    var e = try fresh("abc def");
    defer e.deinit();
    try t.expectEqual(Action.handled, try e.handleKey(keys.a, .{ .cmd = true }));
    try t.expectEqualStrings("abc def", e.selectedText());
    switch (try e.handleKey(keys.c, .{ .cmd = true })) {
        .copy => |s| try t.expectEqualStrings("abc def", s),
        else => return error.TestUnexpectedResult,
    }
    switch (try e.handleKey(keys.x, .{ .cmd = true })) {
        .cut => |s| try t.expectEqualStrings("abc def", s),
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqualStrings("", e.text());
    try t.expectEqual(Action.paste, try e.handleKey(keys.v, .{ .cmd = true }));
    try t.expectEqual(Action.submit, try e.handleKey(keys.@"return", .{}));
    try t.expectEqual(Action.cancel, try e.handleKey(keys.escape, .{}));
    try t.expectEqual(Action.none, try e.handleKey(keys.tab, .{}));
    try t.expectEqual(Action.none, try e.handleKey('q', .{ .cmd = true }));
    try t.expectEqual(Action.none, try e.handleKey('a', .{ .ctrl = true }));
    // Copy with nothing selected is consumed but offers nothing.
    try t.expectEqual(Action.handled, try e.handleKey(keys.c, .{ .cmd = true }));
}

test "handleKey: cmd+left/right/backspace act on the line" {
    var e = try fresh("one two");
    defer e.deinit();
    _ = try e.handleKey(keys.left, .{ .cmd = true });
    try t.expectEqual(@as(usize, 0), e.cursor);
    _ = try e.handleKey(keys.right, .{ .cmd = true, .shift = true });
    try expectText(&e, "one two", 7, 0);
    _ = try e.handleKey(keys.right, .{});
    try t.expectEqual(@as(usize, 7), e.cursor);
    e.moveTo(4, false);
    try t.expectEqual(Action.changed, try e.handleKey(keys.backspace, .{ .cmd = true }));
    try expectText(&e, "two", 0, 0);
}

test "invariants: cursor and anchor stay on boundaries under a key storm" {
    var e = try fresh("aé😀 b ü");
    defer e.deinit();
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    const ks = [_]u32{ keys.left, keys.right, keys.home, keys.end, keys.backspace, keys.delete };
    for (0..2000) |_| {
        const k = ks[r.uintLessThan(usize, ks.len)];
        _ = try e.handleKey(k, .{ .shift = r.boolean(), .alt = r.boolean() });
        if (r.uintLessThan(u8, 8) == 0) try e.insert("é😀x");
        try t.expect(std.unicode.utf8ValidateSlice(e.text()));
        try t.expect(e.cursor <= e.text().len and e.anchor <= e.text().len);
        try t.expectEqual(e.cursor, snap(e.text(), e.cursor));
        try t.expectEqual(e.anchor, snap(e.text(), e.anchor));
    }
}

// ---- undo / redo tests -----------------------------------------------------

/// Types `str` one code point at a time, the way key presses arrive.
fn typeEach(e: *TextEdit, str: []const u8) !void {
    var i: usize = 0;
    while (i < str.len) {
        const n = try std.unicode.utf8ByteSequenceLength(str[i]);
        try e.insert(str[i .. i + n]);
        i += n;
    }
}

fn countUndo(e: *TextEdit) usize {
    var n: usize = 0;
    while (e.undo()) n += 1;
    return n;
}

test "undo: typing coalesces into words, a space after a word starts a new step" {
    var e = try fresh("");
    defer e.deinit();
    try typeEach(&e, "hello world");
    try t.expectEqual(@as(usize, 2), e.history.undo_stack.items.len);
    try t.expect(e.undo());
    try expectText(&e, "hello", 5, 5);
    try t.expect(e.undo());
    try expectText(&e, "", 0, 0);
    try t.expect(!e.undo());
    try t.expect(e.redo());
    try expectText(&e, "hello", 5, 5);
    try t.expect(e.redo());
    try expectText(&e, "hello world", 11, 11);
    try t.expect(!e.redo());
}

test "undo: a pause breaks the typing run (injected clock)" {
    var e = try fresh("");
    defer e.deinit();
    e.now = 10;
    try e.insert("a");
    e.now = 10.9;
    try e.insert("b"); // within the pause: same step
    e.now = 12.5;
    try e.insert("c"); // 1.6 s later: new step
    try t.expectEqual(@as(usize, 2), e.history.undo_stack.items.len);
    try t.expect(e.undo());
    try expectText(&e, "ab", 2, 2);
    try t.expect(e.undo());
    try expectText(&e, "", 0, 0);
    // Steady typing stays in one run as long as each gap is short.
    e.clearHistory();
    e.now = 0;
    for ("abcdefgh") |ch| {
        try e.insert(&.{ch});
        e.now += 0.8;
    }
    try t.expectEqual(@as(usize, 1), e.history.undo_stack.items.len);
}

test "undo: moving the caret, even back to the same spot, breaks the run" {
    var e = try fresh("");
    defer e.deinit();
    try typeEach(&e, "ab");
    e.moveTo(0, false);
    e.moveTo(2, false);
    try typeEach(&e, "c");
    try t.expectEqual(@as(usize, 2), e.history.undo_stack.items.len);
    // Setting the fields directly (as widgets do for double click) is caught too.
    try typeEach(&e, "d"); // joins "c"
    try t.expectEqual(@as(usize, 2), e.history.undo_stack.items.len);
    e.cursor = 1;
    e.anchor = 1;
    try typeEach(&e, "e");
    try t.expectEqual(@as(usize, 3), e.history.undo_stack.items.len);
    try t.expect(e.undo());
    try expectText(&e, "abcd", 1, 1);
    try t.expect(e.undo());
    try expectText(&e, "ab", 2, 2);
}

test "undo: a run of backspaces is one step and restores text and caret" {
    var e = try fresh("hello");
    defer e.deinit();
    e.clearHistory();
    for (0..3) |_| try t.expect(e.backspace(.char));
    try expectText(&e, "he", 2, 2);
    try t.expectEqual(@as(usize, 1), e.history.undo_stack.items.len);
    try t.expect(e.undo());
    try expectText(&e, "hello", 5, 5);
    try t.expect(e.redo());
    try expectText(&e, "he", 2, 2);
}

test "undo: a run of forward deletes is one step" {
    var e = try fresh("hello");
    defer e.deinit();
    e.clearHistory();
    e.moveTo(1, false);
    try t.expect(e.delete(.char));
    try t.expect(e.delete(.char));
    try expectText(&e, "hlo", 1, 1);
    try t.expectEqual(@as(usize, 1), e.history.undo_stack.items.len);
    try t.expect(e.undo());
    try expectText(&e, "hello", 1, 1);
}

test "undo: different kinds of edit do not merge" {
    var e = try fresh("");
    defer e.deinit();
    try typeEach(&e, "abc");
    try t.expect(e.backspace(.char));
    try t.expect(e.delete(.char) == false); // at the end: nothing, no step
    e.moveTo(0, false);
    try t.expect(e.delete(.char));
    // typing, backspace, forward delete
    try t.expectEqual(@as(usize, 3), e.history.undo_stack.items.len);
    try t.expectEqual(@as(usize, 3), countUndo(&e));
    try expectText(&e, "", 0, 0);
}

test "undo: replacing a selection is one step that restores the selection" {
    var e = try fresh("hello world");
    defer e.deinit();
    e.clearHistory();
    e.moveTo(6, false);
    e.moveTo(11, true);
    try e.insert("zig");
    try expectText(&e, "hello zig", 9, 9);
    try t.expectEqual(@as(usize, 1), e.history.undo_stack.items.len);
    try t.expect(e.undo());
    try expectText(&e, "hello world", 11, 6);
    try t.expect(e.redo());
    try expectText(&e, "hello zig", 9, 9);
    // Typing on after the replacement is a new step.
    try typeEach(&e, "!");
    try t.expectEqual(@as(usize, 2), e.history.undo_stack.items.len);
    // Deleting a selection with backspace is one step too, and a backwards selection restores as such.
    e.moveTo(9, false);
    e.moveTo(6, true);
    try t.expect(e.backspace(.char));
    try t.expect(e.undo());
    try expectText(&e, "hello zig!", 6, 9);
}

test "undo: paste and cut are single steps" {
    var e = try fresh("");
    defer e.deinit();
    try e.insertAs("one two", .paste);
    try e.insertAs(" three", .paste);
    try t.expectEqual(@as(usize, 2), e.history.undo_stack.items.len);
    e.moveTo(0, false);
    e.moveTo(3, true);
    _ = try e.cut();
    try expectText(&e, " two three", 0, 0);
    try t.expect(e.undo());
    try expectText(&e, "one two three", 3, 0);
    try t.expect(e.undo());
    try expectText(&e, "one two", 7, 7);
    try t.expect(e.undo());
    try expectText(&e, "", 0, 0);
}

test "undo: a new edit clears the redo stack" {
    var e = try fresh("");
    defer e.deinit();
    try typeEach(&e, "abc");
    try t.expect(e.undo());
    try t.expect(e.canRedo());
    try typeEach(&e, "x");
    try t.expect(!e.canRedo());
    try t.expect(!e.redo());
    try expectText(&e, "x", 1, 1);
    // A caret move alone does not clear it.
    try t.expect(e.undo());
    e.moveTo(0, false);
    try t.expect(e.canRedo());
    try t.expect(e.redo());
    try expectText(&e, "x", 1, 1);
}

test "undo: the history is bounded and drops the oldest steps" {
    var e = try fresh("");
    defer e.deinit();
    e.history.limits.max_entries = 3;
    for ("abcdefghij") |ch| try e.insertAs(&.{ch}, .paste);
    try t.expectEqualStrings("abcdefghij", e.text());
    try t.expectEqual(@as(usize, 3), countUndo(&e));
    try expectText(&e, "abcdefg", 7, 7);
    // Redo walks back up through the same three.
    try t.expect(e.redo() and e.redo() and e.redo());
    try t.expectEqualStrings("abcdefghij", e.text());

    // By bytes: 4 KiB budget, 1 KiB pastes.
    var f = try fresh("");
    defer f.deinit();
    f.history.limits.max_bytes = 2500;
    var kb_buf: [1024]u8 = undefined;
    @memset(&kb_buf, 'k');
    const kb: []const u8 = &kb_buf;
    for (0..5) |_| try f.insertAs(kb, .paste);
    try t.expectEqual(@as(usize, 2), f.history.undo_stack.items.len);
    try t.expect(f.history.bytes <= 2500);
    try t.expectEqual(@as(usize, 2), countUndo(&f));
    try t.expectEqual(@as(usize, 3 * 1024), f.text().len);
    // A single step bigger than the whole budget is dropped, the text is fine.
    f.history.limits.max_bytes = 100;
    try f.insertAs(kb, .paste);
    try t.expect(!f.canUndo());
    try t.expectEqual(@as(usize, 4 * 1024), f.text().len);
}

test "undo: multi-byte text round-trips and never splits a code point" {
    var e = try fresh("");
    defer e.deinit();
    try typeEach(&e, "aé😀");
    try t.expectEqual(@as(usize, 7), e.text().len);
    try t.expect(e.undo());
    try expectText(&e, "", 0, 0);
    try t.expect(e.redo());
    try expectText(&e, "aé😀", 7, 7);
    e.clearHistory();
    try t.expect(e.backspace(.char)); // the emoji
    try t.expect(e.backspace(.char)); // é
    try expectText(&e, "a", 1, 1);
    try t.expect(e.undo());
    try expectText(&e, "aé😀", 7, 7);
    try t.expect(std.unicode.utf8ValidateSlice(e.text()));
    try t.expect(e.redo());
    try expectText(&e, "a", 1, 1);
    // Forward delete across multi-byte characters.
    try e.setText("é😀ü");
    e.moveTo(0, false);
    try t.expect(e.delete(.char));
    try t.expect(e.delete(.char));
    try t.expect(e.undo());
    try expectText(&e, "é😀ü", 0, 0);
}

test "undo: text changed behind the history's back drops it instead of corrupting" {
    var e = try fresh("");
    defer e.deinit();
    try typeEach(&e, "héllo");
    e.buf.items[0] = 'H'; // outside edit
    try t.expect(!e.undo());
    try t.expect(!e.canUndo() and !e.canRedo());
    try t.expectEqualStrings("Héllo", e.text());
    // Entry offsets that no longer lie on a boundary are refused too.
    var f = try fresh("");
    defer f.deinit();
    try f.insertAs("é", .paste);
    f.buf.items[0] = 0xC3;
    f.buf.items[1] = 0xA9;
    try f.buf.insertSlice(f.gpa, 0, "ab");
    try t.expect(!f.undo()); // "é" is no longer at offset 0
    try t.expect(std.unicode.utf8ValidateSlice(f.text()));
}

test "undo: setText and clear forget the history, replaceAll keeps it" {
    var e = try fresh("");
    defer e.deinit();
    try typeEach(&e, "abc");
    try e.setText("xyz");
    try t.expect(!e.canUndo());
    try typeEach(&e, "!");
    try t.expect(e.canUndo());
    e.clear();
    try t.expect(!e.canUndo() and !e.canRedo());
    try e.setText("one");
    try e.replaceAll("two");
    try expectText(&e, "two", 3, 3);
    try t.expect(e.undo());
    try expectText(&e, "one", 3, 0);
    try t.expect(e.redo());
    try expectText(&e, "two", 3, 3);
}

test "undo: max_len is respected when undo or redo would grow the text" {
    var e = try fresh("abcdef");
    defer e.deinit();
    e.clearHistory();
    e.moveTo(0, false);
    e.moveTo(4, true);
    try t.expect(e.backspace(.char));
    try t.expectEqualStrings("ef", e.text());
    e.max_len = 3;
    try t.expect(!e.undo()); // would grow to 6 bytes
    try t.expectEqualStrings("ef", e.text());
    try t.expect(e.canUndo());
    e.max_len = 100;
    try t.expect(e.undo());
    try t.expectEqualStrings("abcdef", e.text());
}

test "undo: a failed insert is not recorded as text that is not there" {
    var e = try fresh("");
    defer e.deinit();
    e.max_len = 3;
    try typeEach(&e, "abcde"); // "d" and "e" do not fit
    try t.expectEqualStrings("abc", e.text());
    try t.expect(e.undo());
    try expectText(&e, "", 0, 0);
}

test "undo: newlines are steps of their own (multiline)" {
    var e = try fresh("");
    defer e.deinit();
    e.multiline = true;
    try typeEach(&e, "ab");
    try typeEach(&e, "\n");
    try typeEach(&e, "cd");
    try typeEach(&e, "\n");
    try typeEach(&e, "\n");
    try t.expectEqual(@as(usize, 5), e.history.undo_stack.items.len);
    try t.expect(e.undo());
    try t.expect(e.undo());
    try expectText(&e, "ab\ncd", 5, 5);
    try t.expect(e.undo());
    try expectText(&e, "ab\n", 3, 3);
    // Without multiline the break is dropped and nothing is recorded.
    var f = try fresh("");
    defer f.deinit();
    try f.insert("\n");
    try t.expect(!f.canUndo());
}

test "undo: key bindings" {
    var e = try fresh("");
    defer e.deinit();
    e.ctrl_undo = false;
    try typeEach(&e, "ab");
    // Ctrl is not undo here (macOS).
    try t.expectEqual(Action.none, try e.handleKey(keys.z, .{ .ctrl = true }));
    try t.expectEqualStrings("ab", e.text());
    try t.expectEqual(Action.changed, try e.handleKey(keys.z, .{ .cmd = true }));
    try t.expectEqualStrings("", e.text());
    try t.expectEqual(Action.handled, try e.handleKey(keys.z, .{ .cmd = true })); // nothing left
    try t.expectEqual(Action.changed, try e.handleKey(keys.z, .{ .cmd = true, .shift = true }));
    try t.expectEqualStrings("ab", e.text());
    try t.expectEqual(Action.handled, try e.handleKey(keys.z, .{ .cmd = true, .shift = true }));
    // Off macOS: Ctrl+Z, Ctrl+Shift+Z and Ctrl+Y.
    e.ctrl_undo = true;
    try t.expectEqual(Action.changed, try e.handleKey(keys.z, .{ .ctrl = true }));
    try t.expectEqualStrings("", e.text());
    try t.expectEqual(Action.changed, try e.handleKey(keys.y, .{ .ctrl = true }));
    try t.expectEqualStrings("ab", e.text());
    try t.expectEqual(Action.changed, try e.handleKey(keys.z, .{ .ctrl = true }));
    try t.expectEqual(Action.changed, try e.handleKey(keys.z, .{ .ctrl = true, .shift = true }));
    try t.expectEqualStrings("ab", e.text());
    // Alt-modified combinations are not undo.
    try t.expectEqual(Action.none, try e.handleKey(keys.z, .{ .ctrl = true, .alt = true }));
    try t.expectEqual(Action.none, try e.handleKey(keys.z, .{}));
}

test "undo: allocation failure while recording never loses the edit" {
    var fa = std.testing.FailingAllocator.init(t.allocator, .{});
    var e = TextEdit.init(fa.allocator());
    defer e.deinit();
    try e.buf.ensureTotalCapacity(e.gpa, 256); // text growth must not be what fails
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(t.allocator);
    try e.insert("a");
    try expected.append(t.allocator, 'a');
    for (0..12) |k| {
        fa.fail_index = fa.alloc_index + k % 3;
        try e.insert("b");
        try expected.append(t.allocator, 'b');
        try t.expectEqualStrings(expected.items, e.text());
        try t.expectEqual(e.text().len, e.cursor);
    }
    // Deleting while allocation fails: the deletion happens, the history is dropped.
    e.history.clear(e.gpa);
    try e.insertAs("xyz", .paste);
    fa.fail_index = fa.alloc_index;
    try t.expect(e.backspace(.char));
    try t.expect(e.text().len == expected.items.len + 2);
    try t.expect(!e.canUndo());
    // Whatever history survived, undo then redo is consistent.
    try e.insert("q");
    const full = try t.allocator.dupe(u8, e.text());
    defer t.allocator.free(full);
    _ = countUndo(&e);
    try t.expect(std.mem.startsWith(u8, full, e.text()));
    while (e.redo()) {}
    try t.expectEqualStrings(full, e.text());
}

test "undo: random edits undo to the start and redo to the end" {
    var e = try fresh("");
    defer e.deinit();
    e.multiline = true;
    try e.insert("seed é😀");
    e.clearHistory();
    e.history.limits = .{ .max_entries = 1 << 20, .max_bytes = 1 << 28 };
    const initial = try t.allocator.dupe(u8, e.text());
    defer t.allocator.free(initial);
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    const ks = [_]u32{ keys.left, keys.right, keys.home, keys.end, keys.backspace, keys.delete };
    for (0..3000) |_| {
        e.now += r.float(f64) * 0.6;
        switch (r.uintLessThan(u8, 6)) {
            0 => try e.insert("é"),
            1 => try e.insert("😀x"),
            2 => try e.insertAs("pasted\nline", .paste),
            3 => _ = try e.handleKey(keys.x, .{ .cmd = true }),
            else => _ = try e.handleKey(ks[r.uintLessThan(usize, ks.len)], .{ .shift = r.boolean(), .alt = r.uintLessThan(u8, 4) == 0 }),
        }
        try t.expect(std.unicode.utf8ValidateSlice(e.text()));
        try t.expectEqual(e.cursor, snap(e.text(), e.cursor));
    }
    const final = try t.allocator.dupe(u8, e.text());
    defer t.allocator.free(final);
    while (e.undo()) {
        try t.expect(std.unicode.utf8ValidateSlice(e.text()));
        try t.expect(e.cursor <= e.text().len and e.anchor <= e.text().len);
    }
    try t.expectEqualStrings(initial, e.text());
    while (e.redo()) {
        try t.expect(std.unicode.utf8ValidateSlice(e.text()));
    }
    try t.expectEqualStrings(final, e.text());
}
