//! Headless multi-frame tests of the text widgets' shared behaviour: grapheme clusters,
//! input-method pre-edit, mouse selection by click count, password fields and the context menu
//! (see text_input.zig). One unit of width per code point at size 1.
const std = @import("std");
const geom = @import("../core/geom.zig");
const gfx = @import("../core/gfx.zig");
const keys = @import("../core/keys.zig");
const backend = @import("../platform/backend_sdl.zig");
const ui_mod = @import("ui.zig");
const text_edit = @import("../text/text_edit.zig");
const text_input = @import("text_input.zig");
const Rect = geom.Rect;
const Ui = ui_mod.Ui;
const State = ui_mod.State;
const Input = ui_mod.Input;
const Theme = ui_mod.Theme;
const DisplayList = gfx.DisplayList;
const TextFieldState = ui_mod.TextFieldState;
const TextAreaState = ui_mod.TextAreaState;
const t = std.testing;

fn cpMeasure(_: ?*anyopaque, str: []const u8, size: f32) f32 {
    const n = std.unicode.utf8CountCodepoints(str) catch str.len;
    return @as(f32, @floatFromInt(n)) * size;
}

var clip_buf: [256]u8 = undefined;
var clip_len: usize = 0;

var clip_reads: usize = 0;

fn clipGet(gpa: std.mem.Allocator) ?[]u8 {
    clip_reads += 1;
    if (clip_len == 0) return null;
    return gpa.dupe(u8, clip_buf[0..clip_len]) catch null;
}

fn clipSet(_: std.mem.Allocator, str: []const u8) void {
    @memcpy(clip_buf[0..str.len], str);
    clip_len = str.len;
}

fn setClip(str: []const u8) void {
    clipSet(t.allocator, str);
}

fn clipText() []const u8 {
    return clip_buf[0..clip_len];
}

const field_r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 30 };

/// A window's worth of state that lives across the frames of a test.
const Rig = struct {
    list: DisplayList,
    state: State = .{},
    ime: ?ui_mod.ImeArea = null,
    time: f64 = 0,

    fn init() Rig {
        clip_len = 0;
        return .{ .list = DisplayList.init(t.allocator) };
    }

    fn deinit(r: *Rig) void {
        r.list.deinit();
    }

    fn ui(r: *Rig, in: Input) Ui {
        r.list.reset();
        var in2 = in;
        in2.time = r.time;
        var u = Ui.initHeadless(&r.list, in2, .{}, cpMeasure);
        u.state = &r.state;
        u.clipboard = .{ .get = clipGet, .set = clipSet };
        u.bounds = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
        return u;
    }

    fn field(r: *Rig, in: Input, st: *TextFieldState, opts: ui_mod.TextFieldOpts) ui_mod.TextFieldResult {
        var u = r.ui(in);
        var o = opts;
        o.size = 1;
        const res = u.textField(field_r, st, o);
        u.finish();
        r.ime = u.ime_area;
        return res;
    }

    fn area(r: *Rig, in: Input, st: *TextAreaState, rect: Rect) ui_mod.TextAreaResult {
        var u = r.ui(in);
        const res = u.textArea(rect, st, .{ .size = 10, .bare = true });
        u.finish();
        r.ime = u.ime_area;
        return res;
    }

    /// Text commands of the frame (main stream, then overlays).
    fn texts(r: *const Rig, out: *[32][]const u8) usize {
        var n: usize = 0;
        for (r.list.cmds.items) |c| switch (c) {
            .text => |x| if (n < out.len) {
                out[n] = x.str;
                n += 1;
            },
            else => {},
        };
        return n;
    }

    fn hasText(r: *const Rig, str: []const u8) bool {
        var buf: [32][]const u8 = undefined;
        const n = r.texts(&buf);
        for (buf[0..n]) |s| if (std.mem.eql(u8, s, str)) return true;
        return false;
    }

    /// Any text command containing `needle`.
    fn textContains(r: *const Rig, needle: []const u8) bool {
        var buf: [32][]const u8 = undefined;
        const n = r.texts(&buf);
        for (buf[0..n]) |s| if (std.mem.indexOf(u8, s, needle) != null) return true;
        return false;
    }

    /// A one-point-high rectangle in the text colour (the pre-edit underline).
    fn underline(r: *const Rig) ?Rect {
        const col = (Theme{}).text;
        for (r.list.cmds.items) |c| switch (c) {
            .rrect => |x| if (std.meta.eql(x.color, col) and x.rect.h == 1 and x.rect.w != 1.5) return x.rect,
            else => {},
        };
        return null;
    }

    /// The caret: a 1.5 wide rectangle in the text colour.
    fn caret(r: *const Rig) ?Rect {
        const col = (Theme{}).text;
        for (r.list.cmds.items) |c| switch (c) {
            .rrect => |x| if (std.meta.eql(x.color, col) and x.rect.w == 1.5) return x.rect,
            else => {},
        };
        return null;
    }

    fn highlight(r: *const Rig) ?Rect {
        const col = (Theme{}).selection;
        for (r.list.cmds.items) |c| switch (c) {
            .rrect => |x| if (std.meta.eql(x.color, col)) return x.rect,
            else => {},
        };
        return null;
    }
};

fn comp(str: []const u8, start: i32, length: i32) backend.Composition {
    var c: backend.Composition = .{};
    @memcpy(c.buf[0..str.len], str);
    c.len = @intCast(str.len);
    c.start = start;
    c.length = length;
    return c;
}

fn withComp(c: backend.Composition) Input {
    var in: Input = .{};
    in.feed(.{ .text_editing = .{ .window = 1, .comp = c } }, 1);
    return in;
}

fn keyIn(code: u32, mods: keys.Mods) Input {
    var in: Input = .{};
    in.pushKey(code, mods);
    return in;
}

fn textIn(str: []const u8) Input {
    var in: Input = .{};
    in.pushText(str);
    return in;
}

fn clickAt(x: f32, clicks: u8) Input {
    return .{ .mouse_x = x, .mouse_y = 15, .pressed = true, .down = true, .mouse_clicks = clicks };
}

fn rightClickAt(x: f32) Input {
    return .{ .mouse_x = x, .mouse_y = 15, .right_pressed = true };
}

fn dragAt(x: f32) Input {
    return .{ .mouse_x = x, .mouse_y = 15, .down = true };
}

fn setup(st: *TextFieldState, rig: *Rig, str: []const u8) !void {
    try st.edit.setText(str);
    rig.state.focusOn(st);
    _ = rig.field(.{}, st, .{}); // a first frame, so the field counts as having been focused
}

// ---- grapheme clusters in the widgets -----------------------------------------------------------

const family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}";

test "textField: arrows, selection and deletes step by cluster" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "e\u{301}" ++ family ++ "\u{1F1F3}\u{1F1EC}x");
    st.edit.moveTo(0, false);
    // 3 bytes (e + acute), 20 bytes (family: 3 emoji of 4 bytes + 2 ZWJ of 3), 8 (flag), 1.
    _ = rig.field(keyIn(keys.right, .{}), &st, .{});
    try t.expectEqual(@as(usize, 3), st.edit.cursor);
    _ = rig.field(keyIn(keys.right, .{ .shift = true }), &st, .{});
    try t.expectEqual(@as(usize, 3 + family.len), st.edit.cursor);
    try t.expectEqualStrings(family, st.edit.selectedText());
    _ = rig.field(keyIn(keys.right, .{ .shift = true }), &st, .{});
    try t.expectEqualStrings(family ++ "\u{1F1F3}\u{1F1EC}", st.edit.selectedText());
    // Backspace over the flag takes it whole, then the family.
    _ = rig.field(keyIn(keys.right, .{}), &st, .{}); // collapse to the end of the selection
    _ = rig.field(keyIn(keys.left, .{}), &st, .{});
    try t.expectEqual(@as(usize, 3 + family.len), st.edit.cursor);
    _ = rig.field(keyIn(keys.right, .{}), &st, .{});
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    try t.expectEqualStrings("e\u{301}" ++ family ++ "x", st.edit.text());
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    try t.expectEqualStrings("e\u{301}x", st.edit.text());
    try st.edit.setText("e\u{301}x");
    st.edit.moveTo(3, false);
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    try t.expectEqualStrings("x", st.edit.text());
    try st.edit.setText("e\u{301}x");
    st.edit.moveTo(3, false);
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    // Forward delete of a decomposed letter.
    try st.edit.setText("e\u{301}!");
    st.edit.moveTo(0, false);
    _ = rig.field(keyIn(keys.delete, .{}), &st, .{});
    try t.expectEqualStrings("!", st.edit.text());
}

test "textField: a click lands on a cluster boundary, never inside one" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    // Widths: e+acute = 2 units, family = 5 units, x = 1.
    try st.edit.setText("e\u{301}" ++ family ++ "x");
    var x: f32 = 10;
    while (x < 10 + 9) : (x += 0.25) {
        _ = rig.field(clickAt(x, 1), &st, .{});
        const c = st.edit.cursor;
        try t.expect(c == 0 or c == 3 or c == 3 + family.len or c == 3 + family.len + 1);
        _ = rig.field(.{ .mouse_x = 300, .mouse_y = 300, .released = true }, &st, .{});
    }
}

test "textField: typing a combining mark joins the run, and max_len never cuts a cluster" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "");
    _ = rig.field(textIn("e"), &st, .{});
    rig.time = 5; // a pause long enough to end a typing run
    _ = rig.field(textIn("\u{301}"), &st, .{});
    try t.expectEqualStrings("e\u{301}", st.edit.text());
    try t.expect(st.edit.undo());
    try t.expectEqualStrings("", st.edit.text()); // one step: the mark belonged to the letter
    // max_len: the family sequence does not fit after "ab" (2 + 20 > 12): none of it is kept
    // rather than a broken half.
    try st.edit.setText("");
    st.edit.max_len = 12;
    try st.edit.insert("ab");
    try st.edit.insert(family);
    try t.expectEqualStrings("ab", st.edit.text());
    // Two emoji fit in 12 bytes but the cut falls inside the joiner sequence: only whole
    // clusters stay.
    try st.edit.setText("");
    st.edit.max_len = 8;
    try st.edit.insert("a" ++ family);
    try t.expectEqualStrings("a", st.edit.text());
}

// ---- emoji typed through text-input events ---------------------------------------------------------
// The macOS emoji picker (Ctrl+Cmd+Space) and any input method deliver an emoji as an ordinary text
// event: SDL_EVENT_TEXT_INPUT with the whole UTF-8 sequence. These tests feed such events the way
// `Input.feed` does and check that the text is kept as it came, edited by cluster, and drawn as
// the same string.

const flag = "\u{1F1F3}\u{1F1EC}";
/// A family with skin tones: 41 bytes, more than one text event chunk (32 bytes) can carry.
const long_family = "\u{1F468}\u{1F3FD}\u{200D}\u{1F469}\u{1F3FD}\u{200D}\u{1F467}\u{1F3FD}\u{200D}\u{1F466}\u{1F3FD}";

fn textEvent(str: []const u8) Input {
    var in: Input = .{};
    in.feed(.{ .text_input = .{ .window = 1, .text = backend.TextChunk.from(str) } }, 1);
    return in;
}

test "textField: an emoji from the picker is inserted whole and drawn as typed" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "");
    _ = rig.field(textEvent("hi "), &st, .{});
    rig.time = 5;
    _ = rig.field(textEvent(family), &st, .{});
    try t.expectEqualStrings("hi " ++ family, st.edit.text());
    try t.expectEqual(@as(usize, 3 + family.len), st.edit.cursor);
    try t.expect(rig.hasText("hi " ++ family)); // the text command carries the string unchanged
    rig.time = 10;
    _ = rig.field(textEvent(flag), &st, .{});
    try t.expectEqualStrings("hi " ++ family ++ flag, st.edit.text());
    // Undo takes back one typed emoji at a time.
    try t.expect(st.edit.undo());
    try t.expectEqualStrings("hi " ++ family, st.edit.text());
    try t.expect(st.edit.redo());
    try t.expectEqualStrings("hi " ++ family ++ flag, st.edit.text());
    // Backspace over the flag removes both regional indicators, then the family goes in one step.
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    try t.expectEqualStrings("hi " ++ family, st.edit.text());
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    try t.expectEqualStrings("hi ", st.edit.text());
    // Shift+Left selects the whole family, and typing replaces it.
    rig.time = 20;
    _ = rig.field(textEvent(family), &st, .{});
    _ = rig.field(keyIn(keys.left, .{ .shift = true }), &st, .{});
    try t.expectEqualStrings(family, st.edit.selectedText());
    _ = rig.field(textEvent(flag), &st, .{});
    try t.expectEqualStrings("hi " ++ flag, st.edit.text());
}

test "textField: an emoji split over several text chunks is still one cluster" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "");
    // How `Input.pushText` (and a big commit from SDL) cuts it: on code points, not clusters.
    var in: Input = .{};
    in.pushText("a" ++ long_family ++ "b");
    try t.expect(in.events().len >= 2);
    _ = rig.field(in, &st, .{});
    try t.expectEqualStrings("a" ++ long_family ++ "b", st.edit.text());
    // One Backspace takes "b", the next the entire family with all four skin tones.
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    try t.expectEqualStrings("a", st.edit.text());
    // A regional indicator arriving alone, then its partner in another event, becomes a flag.
    rig.time = 5;
    _ = rig.field(textEvent("\u{1F1F3}"), &st, .{});
    _ = rig.field(textEvent("\u{1F1EC}"), &st, .{});
    try t.expectEqualStrings("a" ++ flag, st.edit.text());
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    try t.expectEqualStrings("a", st.edit.text());
}

test "textField: max_len keeps or drops a typed emoji whole, never half" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "");
    st.edit.max_len = 12;
    _ = rig.field(textEvent("ab"), &st, .{});
    rig.time = 5;
    _ = rig.field(textEvent(family), &st, .{}); // 2 + 20 > 12
    try t.expectEqualStrings("ab", st.edit.text());
    _ = rig.field(textEvent(flag), &st, .{}); // 2 + 8 = 10 fits
    try t.expectEqualStrings("ab" ++ flag, st.edit.text());
    rig.time = 10;
    _ = rig.field(textEvent(flag), &st, .{}); // would be 18: dropped, not cut after one indicator
    try t.expectEqualStrings("ab" ++ flag, st.edit.text());
    try t.expect(std.unicode.utf8ValidateSlice(st.edit.text()));
}

test "textArea: an emoji from the picker is inserted whole, edited by cluster and wrapped whole" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextAreaState.init(t.allocator);
    defer st.deinit();
    const rect: Rect = .{ .x = 0, .y = 0, .w = 50, .h = 100 }; // 5 units per line at size 10
    rig.state.focusOn(&st);
    _ = rig.area(.{}, &st, rect);
    _ = rig.area(textEvent("ab"), &st, rect);
    rig.time = 5;
    _ = rig.area(textEvent(family), &st, rect);
    try t.expectEqualStrings("ab" ++ family, st.edit.text());
    rig.time = 10;
    _ = rig.area(textEvent(flag), &st, rect);
    try t.expectEqualStrings("ab" ++ family ++ flag, st.edit.text());
    // No wrapped line breaks inside a cluster: the lines drawn concatenate to the text.
    var buf: [32][]const u8 = undefined;
    const n = rig.texts(&buf);
    var joined: [64]u8 = undefined;
    var len: usize = 0;
    for (buf[0..n]) |line| {
        @memcpy(joined[len..][0..line.len], line);
        len += line.len;
    }
    try t.expectEqualStrings("ab" ++ family ++ flag, joined[0..len]);
    for (buf[0..n]) |line| try t.expect(std.unicode.utf8ValidateSlice(line));
    // Undo, selection and Backspace by cluster.
    try t.expect(st.edit.undo());
    try t.expectEqualStrings("ab" ++ family, st.edit.text());
    try t.expect(st.edit.redo());
    _ = rig.area(keyIn(keys.left, .{ .shift = true }), &st, rect);
    try t.expectEqualStrings(flag, st.edit.selectedText());
    _ = rig.area(keyIn(keys.backspace, .{}), &st, rect);
    try t.expectEqualStrings("ab" ++ family, st.edit.text());
    _ = rig.area(keyIn(keys.backspace, .{}), &st, rect);
    try t.expectEqualStrings("ab", st.edit.text());
    // max_len in a text area keeps the same rule.
    st.edit.max_len = 12;
    rig.time = 20;
    _ = rig.area(textEvent(family), &st, rect);
    try t.expectEqualStrings("ab", st.edit.text());
    _ = rig.area(textEvent(flag), &st, rect);
    try t.expectEqualStrings("ab" ++ flag, st.edit.text());
}

// ---- mouse selection ------------------------------------------------------------------------------

test "textField: double click selects a word, triple click everything, drag grows by words" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try st.edit.setText("one two three four");
    // x = 10 + n is the boundary after n characters; 15 is inside "two" (offset 5).
    _ = rig.field(clickAt(15, 2), &st, .{});
    try t.expectEqualStrings("two", st.edit.selectedText());
    // Drag right into "four": the selection becomes "two three four" (whole words).
    _ = rig.field(dragAt(10 + 16), &st, .{});
    try t.expectEqualStrings("two three four", st.edit.selectedText());
    // Drag left of the first word: grows to "one two".
    _ = rig.field(dragAt(10 + 1), &st, .{});
    try t.expectEqualStrings("one two", st.edit.selectedText());
    try t.expectEqual(@as(usize, 7), st.edit.anchor); // anchored at the far end of the clicked word's... 
    _ = rig.field(.{ .mouse_x = 15, .mouse_y = 15, .released = true }, &st, .{});
    _ = rig.field(.{ .mouse_x = 300, .mouse_y = 300, .pressed = true, .mouse_clicks = 1 }, &st, .{}); // blur
    // Triple click: the whole field.
    _ = rig.field(clickAt(15, 3), &st, .{});
    try t.expectEqualStrings("one two three four", st.edit.selectedText());
    // Shift-click extends from the anchor.
    _ = rig.field(.{ .mouse_x = 300, .mouse_y = 300, .released = true }, &st, .{});
    _ = rig.field(clickAt(11, 1), &st, .{});
    var in = clickAt(14, 1);
    in.mouse_mods = .{ .shift = true };
    _ = rig.field(.{ .mouse_x = 300, .mouse_y = 300, .released = true }, &st, .{});
    _ = rig.field(in, &st, .{});
    try t.expectEqualStrings("ne ", st.edit.selectedText()[0..3]);
}

test "textField: scripted double click is counted from time and position" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try st.edit.setText("one two");
    var in = clickAt(15, 0); // no OS click count
    _ = rig.field(in, &st, .{});
    try t.expect(!st.edit.hasSelection());
    rig.time = 0.2;
    in = clickAt(15, 0);
    _ = rig.field(in, &st, .{});
    try t.expectEqualStrings("two", st.edit.selectedText());
}

test "word helpers keep a combining mark with its base" {
    // " \u{301}x": the mark belongs to the space.
    const s = "ab \u{301}cd";
    const r = text_edit.wordRange(s, 3);
    try t.expectEqual(@as(usize, 2), r.start);
    try t.expectEqual(@as(usize, 5), r.end);
    try t.expectEqual(@as(usize, 7), text_edit.wordEnd(s, 3));
    try t.expectEqual(@as(usize, 0), text_edit.wordStart(s, 2));
}

// ---- input method pre-edit ------------------------------------------------------------------------

test "pre-edit: drawn inline and underlined, not in the buffer or the history" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "ab");
    st.edit.moveTo(1, false);
    // Composing "ka" (2 chars), the IME caret after it.
    _ = rig.field(withComp(comp("ka", 2, 0)), &st, .{});
    try t.expect(rig.hasText("akab"));
    try t.expectEqualStrings("ab", st.edit.text());
    try t.expect(!st.edit.canUndo());
    const u = rig.underline().?;
    try t.expectEqual(@as(f32, 11), u.x);
    try t.expectEqual(@as(f32, 2), u.w);
    // The IME caret is drawn at its position, 2 characters into the pre-edit.
    try t.expectEqual(@as(f32, 13), rig.caret().?.x);
    // The candidate window is under the pre-edit.
    try t.expectEqual(@as(f32, 11), rig.ime.?.rect.x);
    try t.expectEqual(@as(f32, 2), rig.ime.?.rect.w);
    try t.expectEqual(@as(f32, 2), rig.ime.?.cursor_x);
    // The composition grows.
    _ = rig.field(withComp(comp("kan", 3, 0)), &st, .{});
    try t.expect(rig.hasText("akanb"));
    // Cursor inside the pre-edit (after 1 character).
    _ = rig.field(withComp(comp("kan", 1, 0)), &st, .{});
    try t.expectEqual(@as(f32, 12), rig.caret().?.x);
    // A highlighted clause: its own background and no caret.
    _ = rig.field(withComp(comp("kan", 1, 2)), &st, .{});
    try t.expect(rig.caret() == null);
    const h = rig.highlight().?;
    try t.expectEqual(@as(f32, 12), h.x);
    try t.expectEqual(@as(f32, 2), h.w);
    // Commit: the composition ends and the text arrives as typing, one undo step.
    var in = textIn("\u{304B}\u{306A}");
    in.feed(.{ .text_editing = .{ .window = 1, .comp = .{} } }, 1);
    _ = rig.field(in, &st, .{});
    try t.expectEqualStrings("a\u{304B}\u{306A}b", st.edit.text());
    try t.expect(rig.hasText("a\u{304B}\u{306A}b"));
    try t.expect(rig.underline() == null);
    try t.expect(st.edit.undo());
    try t.expectEqualStrings("ab", st.edit.text());
}

test "pre-edit: cancel leaves the buffer alone; plain keys belong to the IME" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "abc");
    var in = withComp(comp("x", 1, 0));
    in.pushKey(keys.left, .{});
    in.pushKey(keys.backspace, .{});
    in.pushKey(keys.@"return", .{});
    const res = rig.field(in, &st, .{});
    try t.expect(!res.submitted and !res.changed);
    try t.expectEqualStrings("abc", st.edit.text());
    try t.expectEqual(@as(usize, 3), st.edit.cursor);
    // Cmd shortcuts still work.
    in = withComp(comp("x", 1, 0));
    in.pushKey(keys.a, .{ .cmd = true });
    _ = rig.field(in, &st, .{});
    try t.expectEqual(@as(usize, 0), st.edit.anchor);
    // Cancel: an empty composition and no text; back to normal drawing with the caret.
    _ = rig.field(withComp(.{}), &st, .{});
    try t.expect(rig.underline() == null);
    try t.expectEqualStrings("abc", st.edit.text());
    // Without composition the keys work again.
    _ = rig.field(keyIn(keys.backspace, .{}), &st, .{});
    try t.expectEqualStrings("", st.edit.text());
}

test "pre-edit: composing over a selection hides it and the commit replaces it in one step" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "abcd");
    st.edit.select(1, 3);
    _ = rig.field(withComp(comp("x", 1, 0)), &st, .{});
    try t.expect(rig.hasText("axd"));
    try t.expectEqualStrings("abcd", st.edit.text()); // the buffer still holds it
    try t.expectEqualStrings("bc", st.edit.selectedText());
    try t.expect(rig.highlight() == null); // the selection highlight is not drawn
    // Cancelling brings the selection back.
    _ = rig.field(withComp(.{}), &st, .{});
    try t.expect(rig.hasText("abcd"));
    try t.expect(rig.highlight() != null);
    // Composing again and committing replaces it as one undoable step.
    _ = rig.field(withComp(comp("x", 1, 0)), &st, .{});
    var in = textIn("x");
    in.feed(.{ .text_editing = .{ .window = 1, .comp = .{} } }, 1);
    _ = rig.field(in, &st, .{});
    try t.expectEqualStrings("axd", st.edit.text());
    try t.expect(st.edit.undo());
    try t.expectEqualStrings("abcd", st.edit.text());
    try t.expect(!st.edit.canUndo());
}

test "pre-edit: in a full max_len field only what fits is shown, and never half a cluster" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "abcd");
    st.edit.max_len = 4;
    _ = rig.field(withComp(comp("xy", 2, 0)), &st, .{});
    try t.expect(rig.hasText("abcd")); // no room: nothing of the pre-edit is shown
    try t.expect(rig.underline() == null);
    var in = textIn("xy");
    in.feed(.{ .text_editing = .{ .window = 1, .comp = .{} } }, 1);
    _ = rig.field(in, &st, .{});
    try t.expectEqualStrings("abcd", st.edit.text()); // the commit is dropped by max_len
    // Room for two bytes: "xy" is shown, a cluster of three bytes is not.
    st.edit.max_len = 6;
    _ = rig.field(withComp(comp("xyz", 3, 0)), &st, .{});
    try t.expect(rig.hasText("abcdxy"));
    _ = rig.field(withComp(comp("e\u{301}", 2, 0)), &st, .{});
    try t.expect(rig.hasText("abcd"));
}

test "pre-edit: focus lost mid-composition drops it; a stale one is not shown by a new field" {
    var rig = Rig.init();
    defer rig.deinit();
    var a = TextFieldState.init(t.allocator);
    defer a.deinit();
    var b = TextFieldState.init(t.allocator);
    defer b.deinit();
    try setup(&a, &rig, "aa");
    var in = withComp(comp("zz", 2, 0));
    _ = rig.field(in, &a, .{});
    try t.expect(rig.underline() != null);
    // Focus is lost: Input drops the composition, the next frame draws plainly.
    in.feed(.{ .focus_lost = 1 }, 1);
    try t.expectEqual(@as(u8, 0), in.composition.len);
    _ = rig.field(in, &a, .{});
    try t.expect(rig.underline() == null);
    // A composition running while another field gets the focus does not appear there.
    try b.edit.setText("bb");
    in = withComp(comp("zz", 2, 0));
    in.mouse_x = 20;
    in.mouse_y = 15;
    in.pressed = true;
    in.mouse_clicks = 1;
    _ = rig.field(in, &b, .{});
    try t.expect(rig.state.focus == @as(?*const anyopaque, &b));
    try t.expect(rig.underline() == null);
    in.pressed = false;
    _ = rig.field(in, &b, .{});
    try t.expect(rig.underline() == null);
    // Once the input method reports an empty composition, a new one shows.
    _ = rig.field(withComp(.{}), &b, .{});
    _ = rig.field(withComp(comp("yy", 2, 0)), &b, .{});
    try t.expect(rig.underline() != null);
}

test "pre-edit: text area wraps it with the text and points the candidate window at it" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextAreaState.init(t.allocator);
    defer st.deinit();
    const rect: Rect = .{ .x = 0, .y = 0, .w = 50, .h = 100 }; // 5 characters per line, 14 high
    try st.edit.setText("abc");
    rig.state.focusOn(&st);
    _ = rig.area(.{}, &st, rect);
    _ = rig.area(withComp(comp("xyz", 3, 0)), &st, rect);
    // "abcxyz" wraps after five characters: "abcxy" / "z".
    try t.expect(rig.hasText("abcxy"));
    try t.expect(rig.hasText("z"));
    try t.expectEqualStrings("abc", st.edit.text());
    try t.expect(!st.edit.canUndo());
    // The candidate window sits under the start of the pre-edit (first line, after "abc").
    try t.expectEqual(@as(f32, 0), rig.ime.?.rect.y);
    try t.expectEqual(@as(f32, 30), rig.ime.?.rect.x);
    // Commit.
    var in = textIn("xyz");
    in.feed(.{ .text_editing = .{ .window = 1, .comp = .{} } }, 1);
    _ = rig.area(in, &st, rect);
    try t.expectEqualStrings("abcxyz", st.edit.text());
}

// ---- password ---------------------------------------------------------------------------------------

test "password: bullets only, never the text, caret and selection on the masked layout" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "");
    _ = rig.field(textIn("p\u{E4}ss\u{1F469}\u{200D}\u{1F469}"), &st, .{ .password = true, .placeholder = "Password" });
    try t.expect(rig.hasText("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")); // p, a-umlaut, s, s, couple
    try t.expect(!rig.textContains("ss"));
    try t.expect(!rig.textContains("p"));
    // Caret: after 5 bullets, x = 10 + 5.
    try t.expectEqual(@as(f32, 15), rig.caret().?.x);
    // Left steps over the whole couple (one cluster).
    _ = rig.field(keyIn(keys.left, .{ .shift = true }), &st, .{ .password = true, .placeholder = "Password" });
    try t.expectEqual(@as(f32, 14), rig.highlight().?.x);
    try t.expectEqual(@as(f32, 1), rig.highlight().?.w);
    // The focus entry's label is the placeholder, not the text.
    const entries = rig.state.focusEntries();
    try t.expect(entries.len == 1);
    try t.expectEqualStrings("Password", entries[0].label());
    // Click lands on cluster boundaries of the masked text; a double click selects it all.
    _ = rig.field(.{ .mouse_x = 300, .mouse_y = 300, .released = true }, &st, .{ .password = true });
    _ = rig.field(clickAt(12.4, 1), &st, .{ .password = true });
    try t.expectEqual(@as(usize, 1 + 2), st.edit.cursor); // after the second bullet: "p" and the umlaut
}

test "password: copy and cut do nothing, paste and undo work, double click selects all" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "");
    const o: ui_mod.TextFieldOpts = .{ .password = true };
    _ = rig.field(textIn("secret"), &st, o);
    setClip("keep");
    _ = rig.field(keyIn(keys.a, .{ .cmd = true }), &st, o);
    _ = rig.field(keyIn(keys.c, .{ .cmd = true }), &st, o);
    try t.expectEqualStrings("keep", clipText());
    _ = rig.field(keyIn(keys.x, .{ .cmd = true }), &st, o);
    try t.expectEqualStrings("keep", clipText());
    try t.expectEqualStrings("secret", st.edit.text());
    // Paste replaces the selection.
    _ = rig.field(keyIn(keys.v, .{ .cmd = true }), &st, o);
    try t.expectEqualStrings("keep", st.edit.text());
    // Undo.
    _ = rig.field(keyIn(keys.z, .{ .cmd = true }), &st, o);
    try t.expectEqualStrings("secret", st.edit.text());
    // Double click selects everything, not a word.
    try st.edit.setText("ab cd");
    _ = rig.field(.{ .mouse_x = 300, .mouse_y = 300, .released = true }, &st, o);
    _ = rig.field(clickAt(11, 2), &st, o);
    try t.expectEqual(@as(usize, 5), st.edit.selection().end - st.edit.selection().start);
    // Alt+Left jumps to the start (a password has no words).
    _ = rig.field(.{ .mouse_x = 300, .mouse_y = 300, .released = true }, &st, o);
    _ = rig.field(keyIn(keys.end, .{}), &st, o);
    _ = rig.field(keyIn(keys.left, .{ .alt = true }), &st, o);
    try t.expectEqual(@as(usize, 0), st.edit.cursor);
}

test "password: the pre-edit is shown as underlined bullets, never as text" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "ab");
    const o: ui_mod.TextFieldOpts = .{ .password = true };
    _ = rig.field(withComp(comp("\u{304B}\u{306A}", 2, 0)), &st, o);
    try t.expect(rig.hasText("\u{2022}\u{2022}\u{2022}\u{2022}"));
    try t.expect(!rig.textContains("\u{304B}"));
    try t.expectEqual(@as(f32, 2), rig.underline().?.w);
}

// ---- context menu ------------------------------------------------------------------------------------

fn menuTexts(rig: *const Rig, labels: []const []const u8) bool {
    for (labels) |l| if (!rig.hasText(l)) return false;
    return true;
}

test "context menu: right click opens it with the editing items; Escape closes it and focus stays" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    var other: u8 = 0;
    try st.edit.setText("hello world");
    rig.state.focusOn(&other);
    _ = rig.field(rightClickAt(15), &st, .{});
    try t.expect(st.ctx.open);
    try t.expect(rig.state.focus == @as(?*const anyopaque, &st)); // right click focuses the field
    try t.expect(menuTexts(&rig, &.{ "Undo", "Redo", "Cut", "Copy", "Paste", "Select All" }));
    try t.expect(rig.textContains("Cmd+C") or rig.textContains("Ctrl+C"));
    try t.expectEqual(@as(usize, 5), st.edit.cursor); // the caret moved to the click
    _ = rig.field(keyIn(keys.escape, .{}), &st, .{});
    try t.expect(!st.ctx.open);
    try t.expect(rig.state.focus == @as(?*const anyopaque, &st));
    // Opt out.
    _ = rig.field(rightClickAt(15), &st, .{ .context_menu = false });
    try t.expect(!st.ctx.open);
}

test "context menu: items are disabled when they do not apply; Select All works from the keyboard" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try st.edit.setText("hello");
    _ = rig.field(rightClickAt(12), &st, .{});
    // No selection, no history, empty clipboard: only Select All is enabled; Down finds it.
    _ = rig.field(keyIn(keys.down, .{}), &st, .{});
    _ = rig.field(keyIn(keys.@"return", .{}), &st, .{});
    try t.expect(!st.ctx.open);
    try t.expectEqualStrings("hello", st.edit.selectedText());
    try t.expect(rig.state.focus == @as(?*const anyopaque, &st));
    // With a selection and text on the clipboard: Cut is the first enabled item.
    setClip("PASTE");
    _ = rig.field(.{}, &st, .{}); // (the closed menu's rectangle still blocks the pointer for a frame)
    _ = rig.field(rightClickAt(12), &st, .{}); // inside the selection: it is kept
    try t.expectEqualStrings("hello", st.edit.selectedText());
    _ = rig.field(keyIn(keys.down, .{}), &st, .{});
    const res = rig.field(keyIn(keys.@"return", .{}), &st, .{});
    try t.expect(res.changed);
    try t.expectEqualStrings("", st.edit.text());
    try t.expectEqualStrings("hello", clipText());
    // Undo is enabled now (and is the first item).
    _ = rig.field(.{}, &st, .{});
    _ = rig.field(rightClickAt(12), &st, .{});
    _ = rig.field(keyIn(keys.down, .{}), &st, .{});
    _ = rig.field(keyIn(keys.@"return", .{}), &st, .{});
    try t.expectEqualStrings("hello", st.edit.text());
}

test "context menu: right click outside the selection moves the caret, inside keeps it" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try st.edit.setText("0123456789");
    st.edit.select(2, 5);
    _ = rig.field(rightClickAt(10 + 3), &st, .{});
    try t.expectEqualStrings("234", st.edit.selectedText());
    _ = rig.field(keyIn(keys.escape, .{}), &st, .{});
    _ = rig.field(rightClickAt(10 + 8), &st, .{});
    try t.expect(!st.edit.hasSelection());
    try t.expectEqual(@as(usize, 8), st.edit.cursor);
}

test "context menu: password fields cannot cut or copy" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try st.edit.setText("hunter2");
    st.edit.selectAll();
    setClip("old");
    _ = rig.field(rightClickAt(12), &st, .{ .password = true });
    // Cut and Copy are disabled: the first enabled item with a selection but an empty
    // history is Paste.
    _ = rig.field(keyIn(keys.down, .{}), &st, .{ .password = true });
    _ = rig.field(keyIn(keys.@"return", .{}), &st, .{ .password = true });
    try t.expectEqualStrings("old", st.edit.text()); // Paste replaced the selection
    try t.expectEqualStrings("old", clipText());
}

test "context menu: a field inside a popup opens a nested menu and the popup stays open" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    var pp: ui_mod.PopupState = .{};
    try st.edit.setText("nested");
    const Frame = struct {
        fn run(r: *Rig, in: Input, s: *TextFieldState, p: *ui_mod.PopupState, open_it: bool) Rect {
            var u = r.ui(in);
            if (open_it) u.openPopup(p);
            var c: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            if (u.beginPopup(p, .{ .x = 100, .y = 100, .w = 10, .h = 10 }, .{ 220, 60 }, .{})) |content| {
                c = content;
                _ = u.textField(.{ .x = content.x, .y = content.y, .w = content.w, .h = 30 }, s, .{ .size = 1 });
                u.endPopup();
            }
            u.finish();
            return c;
        }
    };
    var c = Frame.run(&rig, .{}, &st, &pp, true);
    c = Frame.run(&rig, .{}, &st, &pp, false);
    try t.expect(pp.open);
    const click: Input = .{ .mouse_x = c.x + 40, .mouse_y = c.y + 15, .right_pressed = true };
    _ = Frame.run(&rig, click, &st, &pp, false);
    try t.expect(st.ctx.open);
    try t.expect(pp.open);
    try t.expect(pp.child == &st.ctx);
    try t.expect(rig.hasText("Select All"));
    // Escape closes only the menu; the popup and the field's focus stay.
    _ = Frame.run(&rig, keyIn(keys.escape, .{}), &st, &pp, false);
    try t.expect(!st.ctx.open);
    try t.expect(pp.open);
    try t.expect(rig.state.focus == @as(?*const anyopaque, &st));
}

test "context menu: text area and selectable text" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextAreaState.init(t.allocator);
    defer st.deinit();
    const rect: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try st.edit.setText("area text");
    _ = rig.area(.{ .mouse_x = 20, .mouse_y = 5, .right_pressed = true }, &st, rect);
    try t.expect(st.ctx.open);
    try t.expect(rig.hasText("Paste"));
    _ = rig.area(keyIn(keys.down, .{}), &st, rect);
    _ = rig.area(keyIn(keys.@"return", .{}), &st, rect);
    try t.expectEqualStrings("area text", st.edit.selectedText());

    // textSelectable: Copy and Select All only.
    _ = rig.area(.{}, &st, rect);
    var sel: ui_mod.SelectState = .{};
    const str = "read only words";
    var u = rig.ui(.{ .mouse_x = 20, .mouse_y = 5, .right_pressed = true });
    _ = u.textSelectable(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, str, &sel, .{ .size = 10 });
    u.finish();
    try t.expect(sel.ctx.open);
    try t.expect(rig.hasText("Copy") and rig.hasText("Select All"));
    try t.expect(!rig.hasText("Paste"));
    u = rig.ui(keyIn(keys.down, .{}));
    _ = u.textSelectable(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, str, &sel, .{ .size = 10 });
    u.finish();
    u = rig.ui(keyIn(keys.@"return", .{}));
    _ = u.textSelectable(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, str, &sel, .{ .size = 10 });
    u.finish();
    try t.expectEqualStrings(str, sel.selectedText(str));
    // Copy is enabled now.
    u = rig.ui(.{});
    _ = u.textSelectable(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, str, &sel, .{ .size = 10 });
    u.finish();
    u = rig.ui(.{ .mouse_x = 20, .mouse_y = 5, .right_pressed = true });
    _ = u.textSelectable(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, str, &sel, .{ .size = 10 });
    u.finish();
    u = rig.ui(keyIn(keys.down, .{}));
    _ = u.textSelectable(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, str, &sel, .{ .size = 10 });
    u.finish();
    u = rig.ui(keyIn(keys.@"return", .{}));
    _ = u.textSelectable(.{ .x = 0, .y = 0, .w = 200, .h = 0 }, str, &sel, .{ .size = 10 });
    u.finish();
    try t.expectEqualStrings(str, clipText());
}

test "selectable text: dragging after a double click grows by words" {
    var rig = Rig.init();
    defer rig.deinit();
    var sel: ui_mod.SelectState = .{};
    const str = "one two three";
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 0 };
    var u = rig.ui(.{ .mouse_x = 15, .mouse_y = 5, .pressed = true, .down = true, .mouse_clicks = 2 });
    _ = u.textSelectable(r, str, &sel, .{ .size = 10 });
    u.finish();
    try t.expectEqualStrings("one", sel.selectedText(str));
    u = rig.ui(.{ .mouse_x = 55, .mouse_y = 5, .down = true });
    _ = u.textSelectable(r, str, &sel, .{ .size = 10 });
    u.finish();
    try t.expectEqualStrings("one two", sel.selectedText(str));
}

test "fitText and wrapping never split a cluster" {
    var list = DisplayList.init(t.allocator);
    defer list.deinit();
    var u = Ui.initHeadless(&list, .{}, .{}, cpMeasure);
    var buf: [64]u8 = undefined;
    const s = "ab" ++ family ++ family ++ "cd";
    var w: f32 = 1;
    while (w < 20) : (w += 1) {
        const out = u.fitText(&buf, s, 1, w);
        // Whatever it returns ends before a boundary of the source or is "...".
        if (std.mem.endsWith(u8, out, "...")) {
            const cut = out.len - 3;
            try t.expect(@import("../text/grapheme.zig").isBoundary(s, cut));
        }
    }
    // Over-long word: lines break between clusters.
    const word = "e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}";
    var it = u.wrapText(word, 1, 2);
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        try t.expectEqual(@as(usize, 3), line.len); // one cluster (two code points) per line
    }
    try t.expectEqual(@as(usize, 5), n);
}

// ---- audit batch ---------------------------------------------------------------------------------

test "password: a double click keeps everything selected while the button is held" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "ab cd");
    const o: ui_mod.TextFieldOpts = .{ .password = true };
    _ = rig.field(clickAt(11, 2), &st, o);
    try t.expectEqual(@as(usize, 5), st.edit.selection().end - st.edit.selection().start);
    _ = rig.field(dragAt(11), &st, o);
    try t.expectEqual(@as(usize, 5), st.edit.selection().end - st.edit.selection().start);
    _ = rig.field(dragAt(60), &st, o);
    try t.expectEqual(@as(usize, 5), st.edit.selection().end - st.edit.selection().start);
}

test "textField: events after Escape blurs it are not applied" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "");
    var in: Input = .{};
    in.pushKey(keys.escape, .{});
    in.pushText("x");
    _ = rig.field(in, &st, .{});
    try t.expectEqualStrings("", st.edit.text());
    try t.expect(rig.state.focus == null);
}

test "the same state drawn twice in a frame handles the events once" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "");
    var u = rig.ui(textIn("a"));
    _ = u.textField(field_r, &st, .{ .size = 1 });
    _ = u.textField(field_r, &st, .{ .size = 1 });
    u.finish();
    try t.expectEqualStrings("a", st.edit.text());

    var ar = TextAreaState.init(t.allocator);
    defer ar.deinit();
    rig.state.focusOn(&ar);
    const rect: Rect = .{ .x = 0, .y = 50, .w = 100, .h = 100 };
    _ = rig.area(.{}, &ar, rect);
    u = rig.ui(textIn("b"));
    _ = u.textArea(rect, &ar, .{ .size = 10, .bare = true });
    _ = u.textArea(rect, &ar, .{ .size = 10, .bare = true });
    u.finish();
    try t.expectEqualStrings("b", ar.edit.text());
}

test "composition with a failed allocation draws nothing and does not crash" {
    var rig = Rig.init();
    defer rig.deinit();
    var fa = std.testing.FailingAllocator.init(t.allocator, .{});
    var st = TextFieldState.init(fa.allocator());
    defer st.deinit();
    try setup(&st, &rig, "abc");
    fa.fail_index = fa.alloc_index;
    _ = rig.field(withComp(comp("xyz", 1, 1)), &st, .{});
    fa.fail_index = std.math.maxInt(usize);
    try t.expectEqualStrings("abc", st.edit.text());
    var ar = TextAreaState.init(fa.allocator());
    defer ar.deinit();
    try ar.edit.setText("abc");
    rig.state.focusOn(&ar);
    _ = rig.area(.{}, &ar, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    fa.fail_index = fa.alloc_index;
    _ = rig.area(withComp(comp("xyz", 1, 1)), &ar, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try t.expectEqualStrings("abc", ar.edit.text());
}

test "context menu: the clipboard is looked at when the menu opens, not every frame" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "abc");
    setClip("text");
    clip_reads = 0;
    _ = rig.field(rightClickAt(20), &st, .{});
    try t.expect(st.ctx.open);
    for (0..4) |_| _ = rig.field(.{}, &st, .{});
    try t.expect(st.ctx.open);
    try t.expect(clip_reads <= 1);
    // The next time it opens it looks again.
    _ = rig.field(keyIn(keys.escape, .{}), &st, .{});
    try t.expect(!st.ctx.open);
    const before = clip_reads;
    _ = rig.field(rightClickAt(20), &st, .{});
    try t.expect(clip_reads > before);
}

test "paste that inserts nothing does not report a change" {
    var rig = Rig.init();
    defer rig.deinit();
    var st = TextFieldState.init(t.allocator);
    defer st.deinit();
    try setup(&st, &rig, "abc");
    setClip("\n"); // a single-line field drops line breaks
    var res = rig.field(keyIn(keys.v, .{ .cmd = true }), &st, .{});
    try t.expect(!res.changed);
    try t.expectEqualStrings("abc", st.edit.text());
    setClip("d");
    res = rig.field(keyIn(keys.v, .{ .cmd = true }), &st, .{});
    try t.expect(res.changed);
    try t.expectEqualStrings("abcd", st.edit.text());

    var ar = TextAreaState.init(t.allocator);
    defer ar.deinit();
    try ar.edit.setText("abc");
    ar.edit.max_len = 3;
    rig.state.focusOn(&ar);
    const rect: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    _ = rig.area(.{}, &ar, rect);
    setClip("zzz");
    const ares = rig.area(keyIn(keys.v, .{ .cmd = true }), &ar, rect);
    try t.expect(!ares.changed);
    try t.expectEqualStrings("abc", ar.edit.text());

    // The menu's Paste too.
    var u = rig.ui(.{});
    setClip("\n");
    const len = st.edit.text().len;
    try t.expect(!text_input.applyAction(&u, &st.edit, .paste, true));
    try t.expectEqual(len, st.edit.text().len);
}
