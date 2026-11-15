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
