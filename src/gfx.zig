//! Display list: drawing is recorded as plain data, then handed to a backend.
//! Strings are copied into a per-frame arena, so callers can pass temporaries.
const std = @import("std");
const geom = @import("geom.zig");
const Rect = geom.Rect;
const Color = geom.Color;

pub const Align = enum { left, center, right };

/// Font weight of a text command. A window with only one font (or without a
/// face for the requested weight) draws every weight with its regular face.
pub const Weight = enum { regular, medium, semibold };

pub const Command = union(enum) {
    rrect: struct { rect: Rect, radius: f32, color: Color },
    ellipse: struct { cx: f32, cy: f32, rx: f32, ry: f32, color: Color },
    /// Stroked circular arc from angle `a0` to `a1` (radians, clockwise on screen).
    arc: struct { cx: f32, cy: f32, r: f32, a0: f32, a1: f32, width: f32, color: Color },
    /// Stroked straight segment with round caps.
    line: struct { x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: Color },
    text: struct { x: f32, y: f32, str: []const u8, size: f32, color: Color, alignment: Align, weight: Weight = .regular },
    /// Restricts drawing to `Rect` (intersected with any clip already active)
    /// until the matching `pop_clip`.
    push_clip: Rect,
    pop_clip,
};

pub const DisplayList = struct {
    arena: std.heap.ArenaAllocator,
    cmds: std.ArrayList(Command) = .empty,

    pub fn init(gpa: std.mem.Allocator) DisplayList {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(l: *DisplayList) void {
        l.arena.deinit();
    }

    /// Call at the start of every frame.
    pub fn reset(l: *DisplayList) void {
        l.cmds = .empty;
        _ = l.arena.reset(.retain_capacity);
    }

    fn push(l: *DisplayList, cmd: Command) void {
        l.cmds.append(l.arena.allocator(), cmd) catch @panic("out of memory");
    }

    /// Clips everything drawn until `popClip` to `r`. Clips nest and intersect.
    pub fn pushClip(l: *DisplayList, r: Rect) void {
        l.push(.{ .push_clip = r });
    }

    pub fn popClip(l: *DisplayList) void {
        l.push(.pop_clip);
    }

    pub fn rect(l: *DisplayList, r: Rect, color: Color) void {
        l.push(.{ .rrect = .{ .rect = r, .radius = 0, .color = color } });
    }

    pub fn rrect(l: *DisplayList, r: Rect, radius: f32, color: Color) void {
        l.push(.{ .rrect = .{ .rect = r, .radius = radius, .color = color } });
    }

    pub fn circle(l: *DisplayList, cx: f32, cy: f32, r: f32, color: Color) void {
        l.push(.{ .ellipse = .{ .cx = cx, .cy = cy, .rx = r, .ry = r, .color = color } });
    }

    pub fn ellipse(l: *DisplayList, cx: f32, cy: f32, rx: f32, ry: f32, color: Color) void {
        l.push(.{ .ellipse = .{ .cx = cx, .cy = cy, .rx = rx, .ry = ry, .color = color } });
    }

    pub fn arc(l: *DisplayList, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, width: f32, color: Color) void {
        l.push(.{ .arc = .{ .cx = cx, .cy = cy, .r = r, .a0 = a0, .a1 = a1, .width = width, .color = color } });
    }

    /// A stroked segment with round caps.
    pub fn line(l: *DisplayList, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: Color) void {
        l.push(.{ .line = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .width = width, .color = color } });
    }

    /// Connected stroked segments through `pts` (round caps and joins); with
    /// `closed` the last point is joined back to the first.
    pub fn polyline(l: *DisplayList, pts: []const [2]f32, width: f32, color: Color, closed: bool) void {
        if (pts.len < 2) return;
        for (pts[0 .. pts.len - 1], pts[1..]) |a, b| l.line(a[0], a[1], b[0], b[1], width, color);
        if (closed and pts.len > 2) l.line(pts[pts.len - 1][0], pts[pts.len - 1][1], pts[0][0], pts[0][1], width, color);
    }

    pub fn text(l: *DisplayList, x: f32, y: f32, size: f32, color: Color, alignment: Align, str: []const u8) void {
        const copy = l.arena.allocator().dupe(u8, str) catch @panic("out of memory");
        l.push(.{ .text = .{ .x = x, .y = y, .str = copy, .size = size, .color = color, .alignment = alignment } });
    }

    /// Like `text`, in the given font weight.
    pub fn textWeighted(l: *DisplayList, x: f32, y: f32, size: f32, color: Color, alignment: Align, weight: Weight, str: []const u8) void {
        const copy = l.arena.allocator().dupe(u8, str) catch @panic("out of memory");
        l.push(.{ .text = .{ .x = x, .y = y, .str = copy, .size = size, .color = color, .alignment = alignment, .weight = weight } });
    }

    pub fn textFmt(l: *DisplayList, x: f32, y: f32, size: f32, color: Color, alignment: Align, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(l.arena.allocator(), fmt, args) catch @panic("out of memory");
        l.push(.{ .text = .{ .x = x, .y = y, .str = str, .size = size, .color = color, .alignment = alignment } });
    }
};

test "polyline records one line per segment, plus the closing one" {
    var l = DisplayList.init(std.testing.allocator);
    defer l.deinit();
    const pts = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 } };
    l.polyline(&pts, 2, .{ .r = 1, .g = 2, .b = 3 }, false);
    try std.testing.expectEqual(@as(usize, 2), l.cmds.items.len);
    l.polyline(&pts, 2, .{ .r = 1, .g = 2, .b = 3 }, true);
    try std.testing.expectEqual(@as(usize, 5), l.cmds.items.len);
    try std.testing.expectEqual(@as(f32, 10), l.cmds.items[4].line.x0);
    l.polyline(pts[0..1], 2, .{ .r = 0, .g = 0, .b = 0 }, true); // too short: nothing
    try std.testing.expectEqual(@as(usize, 5), l.cmds.items.len);
}
