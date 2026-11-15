//! A pure text editing core: a UTF-8 buffer with a cursor and a selection.
//! No rendering and no platform calls, so everything here is unit-tested.
//!
//! `cursor` and `anchor` are byte offsets that always sit on UTF-8 character
//! (code point) boundaries. The selection is the range between them; with
//! `anchor == cursor` there is none. Movement is per code point, so a
//! combining sequence or a ZWJ emoji takes several presses (no grapheme
//! clusters yet).
//!
//! Clipboard access stays outside: `copy`/`cut` return the text for the caller
//! to put on the clipboard, and `insert` takes what the caller pasted.
const std = @import("std");
const keys = @import("keys.zig");

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

    pub fn init(gpa: std.mem.Allocator) TextEdit {
        return .{ .gpa = gpa };
    }

    pub fn deinit(e: *TextEdit) void {
        e.buf.deinit(e.gpa);
        e.scratch.deinit(e.gpa);
    }

    pub fn text(e: *const TextEdit) []const u8 {
        return e.buf.items;
    }

    /// Replaces everything with `str` (invalid UTF-8 and, unless `multiline`,
    /// line breaks are dropped); the cursor goes to the end.
    pub fn setText(e: *TextEdit, str: []const u8) !void {
        e.buf.clearRetainingCapacity();
        e.cursor = 0;
        e.anchor = 0;
        try e.insert(str);
    }

    pub fn clear(e: *TextEdit) void {
        e.buf.clearRetainingCapacity();
        e.cursor = 0;
        e.anchor = 0;
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
        e.anchor = 0;
        e.cursor = e.buf.items.len;
    }

    /// Moves the cursor to byte offset `pos` (clamped, and moved back to the
    /// start of its character). With `extend` the anchor stays, growing the selection.
    pub fn moveTo(e: *TextEdit, pos: usize, extend: bool) void {
        e.cursor = snap(e.buf.items, pos);
        if (!extend) e.anchor = e.cursor;
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
    /// anything past `max_len`.
    pub fn insert(e: *TextEdit, str: []const u8) !void {
        _ = e.deleteSelection();
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
            if (e.buf.items.len + n > e.max_len) break;
            try e.buf.insertSlice(e.gpa, e.cursor, piece);
            e.cursor += n;
        }
        e.anchor = e.cursor;
    }

    fn deleteRange(e: *TextEdit, start: usize, end: usize) void {
        e.buf.replaceRangeAssumeCapacity(start, end - start, &.{});
        e.cursor = start;
        e.anchor = start;
    }

    /// Removes the selection; returns whether there was one.
    pub fn deleteSelection(e: *TextEdit) bool {
        if (!e.hasSelection()) return false;
        const s = e.selection();
        e.deleteRange(s.start, s.end);
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
        e.deleteRange(start, e.cursor);
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
        e.deleteRange(e.cursor, end);
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
        _ = e.deleteSelection();
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
                keys.left => return e.go(.home, ext),
                keys.right => return e.go(.end, ext),
                keys.up => return e.go(.home, ext),
                keys.down => return e.go(.end, ext),
                keys.backspace => return e.edited(e.backspace(.line)),
                keys.delete => return e.edited(e.delete(.line)),
                else => return .none,
            }
        }
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

pub fn prevBoundary(s: []const u8, pos: usize) usize {
    var p = @min(pos, s.len);
    if (p == 0) return 0;
    p -= 1;
    while (p > 0 and isContinuation(s[p])) p -= 1;
    return p;
}

pub fn nextBoundary(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return s.len;
    var p = pos + 1;
    while (p < s.len and isContinuation(s[p])) p += 1;
    return p;
}

/// Word characters: ASCII letters and digits, '_', and anything non-ASCII.
fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

/// Start of the word at or before `pos` (skipping separators first).
pub fn wordStart(s: []const u8, pos: usize) usize {
    var p = @min(pos, s.len);
    while (p > 0 and !isWordByte(s[p - 1])) p -= 1;
    while (p > 0 and isWordByte(s[p - 1])) p -= 1;
    return p;
}

/// End of the word at or after `pos` (skipping separators first).
pub fn wordEnd(s: []const u8, pos: usize) usize {
    var p = @min(pos, s.len);
    while (p < s.len and !isWordByte(s[p])) p += 1;
    while (p < s.len and isWordByte(s[p])) p += 1;
    return p;
}

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
