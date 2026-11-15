//! Small form controls: checkbox, toggle (switch), radio button, segmented
//! control. They are `Ui` methods (see `Ui.checkbox` and friends); this file
//! holds the option types and the implementations, so `ui.zig` stays readable.
//!
//! Like every widget they are immediate mode: the value lives in the app, the
//! widget draws it and reports the click from the same rectangle. `checkbox`
//! and `toggle` flip the bool they are given; `radio` only reports, because
//! which radio of a group is selected is the app's business.
const std = @import("std");
const geom = @import("geom.zig");
const icons = @import("icons.zig");
const ui_mod = @import("ui.zig");
const Rect = geom.Rect;
const Color = geom.Color;
const Ui = ui_mod.Ui;
const Interaction = ui_mod.Interaction;

pub const CheckOpts = struct {
    /// Dimmed, no hover, and never reports a click or flips the value.
    disabled: bool = false,
    /// Label size; defaults to the theme's body size.
    size: ?f32 = null,
    /// Side of the box (or diameter of a radio) in points.
    box: f32 = 16,
};

pub const ToggleOpts = struct {
    disabled: bool = false,
    /// Size of the pill. It is centred in the rectangle (and shrunk to fit it).
    width: f32 = 34,
    height: f32 = 20,
};

pub const Segment = struct {
    /// Drawn left of the label (or alone); null for none.
    icon: ?icons.Source = null,
    /// Text; empty for an icon-only segment.
    label: []const u8 = "",
};

pub const SegmentedOpts = struct {
    /// Dimmed, no hover, and never changes the selection.
    disabled: bool = false,
    /// Label size; defaults to the theme's button size.
    size: ?f32 = null,
    icon_size: f32 = 14,
    /// All segments the same width. If false each is as wide as its content,
    /// with the spare width shared out equally.
    equal_width: bool = true,
};

/// Most segments `segmented` lays out (more are ignored).
pub const max_segments = 16;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(lerp(@floatFromInt(a), @floatFromInt(b), t)), 0, 255));
}

/// Linear blend of two colours, `t` in 0..1 (0 is `a`).
pub fn mix(a: Color, b: Color, t: f32) Color {
    return .{ .r = lerpU8(a.r, b.r, t), .g = lerpU8(a.g, b.g, t), .b = lerpU8(a.b, b.b, t), .a = lerpU8(a.a, b.a, t) };
}

/// `c` faded for a disabled control.
fn faded(c: Color) Color {
    return c.alpha(@intCast(@as(u16, c.a) * 90 / 255));
}

/// The interaction of `r` with a disabled control never hovered or clicked.
fn interact(ui: *const Ui, r: Rect, disabled: bool) Interaction {
    if (disabled) return .{ .hovered = false, .clicked = false };
    return ui.hit(r);
}

/// Vertically centres a line of `size` text in `r`; a font's line box is about
/// 1.22 times its size.
fn textY(r: Rect, size: f32) f32 {
    return r.y + @round((r.h - size * 1.22) / 2);
}

/// A box with a check mark when `value`, and `label` to its right. The whole
/// of `r` is the click target. Returns the interaction; `clicked` means the
/// value was just flipped.
pub fn checkbox(ui: *Ui, r: Rect, value: *bool, label: []const u8, opts: CheckOpts) Interaction {
    const t = ui.theme;
    const hv = interact(ui, r, opts.disabled);
    if (hv.clicked) value.* = !value.*;
    const on = value.*;
    const b = opts.box;
    const box: Rect = .{ .x = r.x, .y = r.y + @round((r.h - b) / 2), .w = b, .h = b };
    const rad = @round(b / 4);

    if (on) {
        var fill = t.accent;
        if (hv.hovered) fill = mix(fill, t.text, 0.12);
        ui.list.rrect(box, rad, if (opts.disabled) faded(fill) else fill);
        const k = b / 16;
        const mark = [_][2]f32{
            .{ box.x + 4 * k, box.y + 8.4 * k },
            .{ box.x + 7 * k, box.y + 11.2 * k },
            .{ box.x + 12 * k, box.y + 5.2 * k },
        };
        ui.list.polyline(&mark, 1.8 * k, if (opts.disabled) faded(t.accent_text) else t.accent_text, false);
    } else {
        const border = if (opts.disabled) faded(t.dim) else if (hv.hovered) t.dim else t.dim.alpha(130);
        ui.list.rrect(box, rad, border);
        ui.list.rrect(box.inset(1.5), @max(0, rad - 1.5), t.card);
    }

    const size = opts.size orelse t.font_body;
    const col = if (opts.disabled) faded(t.text) else t.text;
    ui.labelAt(box.x + b + 8, textY(r, size), label, .{ .size = size, .color = col });
    return hv;
}

/// Draws a switch with the knob at `pos` (0 = off, 1 = on, anything between
/// is a blend), centred in `r`. Draws only; `toggle` is this plus the click.
/// Animate by feeding it a position that eases towards 0 or 1 across frames.
pub fn toggleAt(ui: *Ui, r: Rect, pos: f32, hovered: bool, opts: ToggleOpts) void {
    const t = ui.theme;
    const p = std.math.clamp(pos, 0, 1);
    const w = @min(opts.width, r.w);
    const h = @min(opts.height, r.h);
    const pill = r.center(w, h);
    var track = mix(t.track, t.accent, p);
    if (hovered) track = mix(track, t.text, 0.08);
    var knob = mix(t.dim, t.text, p);
    if (hovered) knob = mix(knob, t.text, 0.3);
    if (opts.disabled) {
        track = faded(track);
        knob = faded(knob);
    }
    ui.list.rrect(pill, h / 2, track);
    const rad = (h - 4) / 2;
    const cx = lerp(pill.x + 2 + rad, pill.x + pill.w - 2 - rad, p);
    ui.list.circle(cx, pill.y + h / 2, rad, knob);
}

/// A pill-shaped switch, accent coloured when on. `r` is the click target; the
/// pill is centred in it. Returns the interaction; `clicked` means the value
/// was just flipped.
pub fn toggle(ui: *Ui, r: Rect, value: *bool, opts: ToggleOpts) Interaction {
    const hv = interact(ui, r, opts.disabled);
    if (hv.clicked) value.* = !value.*;
    toggleAt(ui, r, if (value.*) 1 else 0, hv.hovered, opts);
    return hv;
}

/// A round radio button with `label` to its right; the whole of `r` is the
/// click target. Does not change anything itself: set your own value when
/// `clicked`.
pub fn radio(ui: *Ui, r: Rect, selected: bool, label: []const u8, opts: CheckOpts) Interaction {
    const t = ui.theme;
    const hv = interact(ui, r, opts.disabled);
    const d = opts.box;
    const cx = r.x + d / 2;
    const cy = r.y + r.h / 2;
    if (selected) {
        var fill = t.accent;
        if (hv.hovered) fill = mix(fill, t.text, 0.12);
        ui.list.circle(cx, cy, d / 2, if (opts.disabled) faded(fill) else fill);
        ui.list.circle(cx, cy, d / 2 - 4.2, if (opts.disabled) faded(t.accent_text) else t.accent_text);
    } else {
        const border = if (opts.disabled) faded(t.dim) else if (hv.hovered) t.dim else t.dim.alpha(130);
        ui.list.circle(cx, cy, d / 2, border);
        ui.list.circle(cx, cy, d / 2 - 1.5, t.card);
    }
    const size = opts.size orelse t.font_body;
    const col = if (opts.disabled) faded(t.text) else t.text;
    ui.labelAt(r.x + d + 8, textY(r, size), label, .{ .size = size, .color = col });
    return hv;
}

/// One segment's content width: icon, gap and label.
fn segmentContentW(ui: *const Ui, s: Segment, size: f32, opts: SegmentedOpts) f32 {
    var w: f32 = 0;
    if (s.icon != null) w += opts.icon_size;
    if (s.label.len > 0) {
        if (s.icon != null) w += 5;
        w += ui.measureWeighted(s.label, size, .medium);
    }
    return w;
}

/// Rectangle of segment `i` in a `segmented` control drawn in `r`. Pure: the
/// same layout `segmented` uses, for hit tests and tests.
pub fn segmentRect(ui: *const Ui, r: Rect, items: []const Segment, i: usize, opts: SegmentedOpts) Rect {
    const n = @min(items.len, max_segments);
    const inner = r.inset(2);
    if (opts.equal_width or n == 0) return inner.column(@max(n, 1), 0, i);
    const size = opts.size orelse ui.theme.font_button;
    const pad: f32 = 12;
    var total: f32 = 0;
    for (items[0..n]) |s| total += segmentContentW(ui, s, size, opts) + 2 * pad;
    const extra = (inner.w - total) / @as(f32, @floatFromInt(n));
    var x = inner.x;
    for (items[0..n], 0..) |s, k| {
        const w = segmentContentW(ui, s, size, opts) + 2 * pad + extra;
        if (k == i) return .{ .x = x, .y = inner.y, .w = w, .h = inner.h };
        x += w;
    }
    return inner;
}

/// A joined control in one rounded container; the selected segment is raised.
/// Clicking a segment stores its index in `selected`. Returns true when that
/// changed the selection. Segments share `r` equally unless
/// `opts.equal_width` is false.
pub fn segmented(ui: *Ui, r: Rect, items: []const Segment, selected: *usize, opts: SegmentedOpts) bool {
    const t = ui.theme;
    const n = @min(items.len, max_segments);
    const rad = @min(@as(f32, 8), r.h / 2);
    const size = opts.size orelse t.font_button;
    ui.list.rrect(r, rad, if (opts.disabled) faded(t.card) else t.card);
    var changed = false;
    const current = selected.*;
    for (items[0..n], 0..) |s, i| {
        const seg = segmentRect(ui, r, items, i, opts);
        const hv = interact(ui, seg, opts.disabled);
        const sel = i == current;
        if (sel) {
            const fill = if (opts.disabled) faded(t.track) else t.track;
            ui.list.rrect(seg, @max(0, rad - 2), fill);
        } else if (hv.hovered) {
            ui.list.rrect(seg, @max(0, rad - 2), t.text.alpha(12));
        }
        // A hairline between two neighbours that are both flat.
        if (i + 1 < n and !sel and i + 1 != current) {
            ui.list.rect(.{ .x = seg.x + seg.w - 0.5, .y = seg.y + seg.h * 0.25, .w = 1, .h = seg.h * 0.5 }, t.text.alpha(if (opts.disabled) 8 else 22));
        }
        var col = if (sel) t.text else if (hv.hovered) mix(t.dim, t.text, 0.5) else t.dim;
        if (opts.disabled) col = faded(col);
        const cw = segmentContentW(ui, s, size, opts);
        var x = seg.x + (seg.w - cw) / 2;
        if (s.icon) |ic| {
            icons.drawSource(ui.list, ic, .{ .x = x, .y = seg.y + (seg.h - opts.icon_size) / 2, .w = opts.icon_size, .h = opts.icon_size }, col, 1);
            x += opts.icon_size + 5;
        }
        if (s.label.len > 0) ui.list.textWeighted(x, textY(seg, size), size, col, .left, .medium, s.label);
        if (hv.clicked and i != current) {
            selected.* = i;
            changed = true;
        }
    }
    return changed;
}

// ---- tests ------------------------------------------------------------------------

const DisplayList = @import("gfx.zig").DisplayList;

fn fakeMeasure(_: ?*anyopaque, str: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(str.len)) * size / 2;
}

fn clickUi(list: *DisplayList, x: f32, y: f32, pressed: bool) Ui {
    return Ui.initHeadless(list, .{ .mouse_x = x, .mouse_y = y, .pressed = pressed }, .{}, fakeMeasure);
}

test "checkbox flips on a click anywhere in the row, and draws a mark only when on" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 10, .y = 10, .w = 200, .h = 24 };
    var v = false;
    // Hover only: no flip.
    var ui = clickUi(&list, 150, 20, false);
    var res = ui.checkbox(r, &v, "Label", .{});
    try std.testing.expect(res.hovered and !res.clicked and !v);
    // Click on the label side (not on the box).
    ui = clickUi(&list, 150, 20, true);
    res = ui.checkbox(r, &v, "Label", .{});
    try std.testing.expect(res.clicked and v);
    var lines: usize = 0;
    for (list.cmds.items) |cmd| if (cmd == .line) {
        lines += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), lines); // the two strokes of the check mark
    // Click outside: unchanged. Click again: off, no mark.
    ui = clickUi(&list, 300, 20, true);
    _ = ui.checkbox(r, &v, "Label", .{});
    try std.testing.expect(v);
    list.reset();
    ui = clickUi(&list, 15, 20, true);
    _ = ui.checkbox(r, &v, "Label", .{});
    try std.testing.expect(!v);
    for (list.cmds.items) |cmd| try std.testing.expect(cmd != .line);
}

test "disabled controls never flip, hover or report" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 24 };
    var v = false;
    var ui = clickUi(&list, 5, 5, true);
    var res = ui.checkbox(r, &v, "x", .{ .disabled = true });
    try std.testing.expect(!res.hovered and !res.clicked and !v);
    res = ui.toggle(r, &v, .{ .disabled = true });
    try std.testing.expect(!res.hovered and !res.clicked and !v);
    res = ui.radio(r, false, "x", .{ .disabled = true });
    try std.testing.expect(!res.clicked);
    var sel: usize = 0;
    try std.testing.expect(!ui.segmented(r, &.{ .{ .label = "a" }, .{ .label = "b" } }, &sel, .{ .disabled = true }));
}

test "toggle flips and moves the knob from one end to the other" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 34, .h = 20 };
    var v = false;
    var ui = clickUi(&list, 5, 5, true);
    const res = ui.toggle(r, &v, .{});
    try std.testing.expect(res.clicked and v);
    // On: knob at the right end.
    var knob = list.cmds.items[list.cmds.items.len - 1].ellipse;
    try std.testing.expectEqual(@as(f32, 34 - 2 - 8), knob.cx);
    try std.testing.expectEqual(@as(f32, 8), knob.rx);
    // Off: left end.
    list.reset();
    ui = clickUi(&list, 500, 5, false);
    _ = ui.toggle(r, &v, .{});
    v = false;
    list.reset();
    _ = ui.toggle(r, &v, .{});
    knob = list.cmds.items[list.cmds.items.len - 1].ellipse;
    try std.testing.expectEqual(@as(f32, 10), knob.cx);
    // An in-between position lands in between, with a blended track colour.
    list.reset();
    toggleAt(&ui, r, 0.5, false, .{});
    knob = list.cmds.items[list.cmds.items.len - 1].ellipse;
    try std.testing.expectEqual(@as(f32, 17), knob.cx);
    const track = list.cmds.items[0].rrect.color;
    try std.testing.expect(track.r > ui.theme.track.r and track.r < ui.theme.accent.r);
}

test "radio reports the click and leaves the value to the caller" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 120, .h = 24 };
    var ui = clickUi(&list, 60, 10, true);
    try std.testing.expect(ui.radio(r, false, "Opt", .{}).clicked);
    list.reset();
    var off = clickUi(&list, 60, 10, false);
    try std.testing.expect(!off.radio(r, true, "Opt", .{}).clicked);
    // Both states draw a ring and an inner disc.
    var n_sel: usize = 0;
    for (list.cmds.items) |cmd| if (cmd == .ellipse) {
        n_sel += 1;
    };
    list.reset();
    _ = off.radio(r, false, "Opt", .{});
    var n_off: usize = 0;
    for (list.cmds.items) |cmd| if (cmd == .ellipse) {
        n_off += 1;
    };
    try std.testing.expectEqual(n_off, n_sel);
}

test "segmented: selection follows the clicked segment, only reports changes" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const items = [_]Segment{ .{ .label = "One" }, .{ .icon = .search }, .{ .icon = .plus, .label = "Three" } };
    const r: Rect = .{ .x = 0, .y = 0, .w = 304, .h = 28 }; // inner 300 wide: 100 per segment
    var sel: usize = 0;
    var ui = clickUi(&list, 150, 14, true);
    try std.testing.expect(ui.segmented(r, &items, &sel, .{}));
    try std.testing.expectEqual(@as(usize, 1), sel);
    // Clicking the selected one changes nothing.
    try std.testing.expect(!ui.segmented(r, &items, &sel, .{}));
    ui = clickUi(&list, 250, 14, true);
    try std.testing.expect(ui.segmented(r, &items, &sel, .{}));
    try std.testing.expectEqual(@as(usize, 2), sel);
    // The padding ring is not a segment.
    ui = clickUi(&list, 1, 14, true);
    try std.testing.expect(!ui.segmented(r, &items, &sel, .{}));
    try std.testing.expectEqual(@as(usize, 2), sel);
    // Equal widths by default.
    try std.testing.expectEqual(@as(f32, 100), segmentRect(&ui, r, &items, 1, .{}).w);
    // Content widths: the label-less icon segment is narrower than the others.
    const w0 = segmentRect(&ui, r, &items, 0, .{ .equal_width = false }).w;
    const w1 = segmentRect(&ui, r, &items, 1, .{ .equal_width = false }).w;
    const w2 = segmentRect(&ui, r, &items, 2, .{ .equal_width = false }).w;
    try std.testing.expect(w1 < w0 and w0 < w2);
    try std.testing.expectApproxEqAbs(@as(f32, 300), w0 + w1 + w2, 0.01);
}

test "segmented raises the selected segment" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ui = clickUi(&list, -1, -1, false);
    var sel: usize = 1;
    _ = ui.segmented(.{ .x = 0, .y = 0, .w = 204, .h = 28 }, &.{ .{ .label = "A" }, .{ .label = "B" } }, &sel, .{});
    // The raised segment is the one rounded rect of the track colour (inner 200 wide: second half).
    var found = false;
    for (list.cmds.items) |cmd| switch (cmd) {
        .rrect => |c| if (std.meta.eql(c.color, ui.theme.track)) {
            found = true;
            try std.testing.expectEqual(@as(f32, 102), c.rect.x);
            try std.testing.expectEqual(@as(f32, 100), c.rect.w);
        },
        else => {},
    };
    try std.testing.expect(found);
}
