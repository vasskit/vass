//! Small line icons drawn from display-list strokes, so they work at any size
//! and colour without image support. Each icon fits a square; `draw` centres
//! it in a rectangle and scales it to the shorter side. Designed for 14-20 pt.
const std = @import("std");
const geom = @import("geom.zig");
const gfx = @import("gfx.zig");
const Rect = geom.Rect;
const Color = geom.Color;

pub const Icon = enum {
    sidebar,
    chevron_right,
    chevron_down,
    chevron_left,
    arrow_left,
    arrow_right,
    search,
    panel_right,
    more,
    sliders,
    arrow_up,
    plus,
};

/// Draws `icon` centred in `r`, scaled to its shorter side, stroked in `color`.
/// `weight` scales the stroke (1 = about 1.5 pt at 18 pt).
pub fn draw(list: *gfx.DisplayList, icon: Icon, r: Rect, color: Color, weight: f32) void {
    const s = @min(r.w, r.h);
    const u = s / 18.0; // one design unit
    const ox = r.x + (r.w - s) / 2;
    const oy = r.y + (r.h - s) / 2;
    const lw = 1.5 * u * weight;
    const p = Painter{ .list = list, .ox = ox, .oy = oy, .u = u, .lw = lw, .color = color };
    switch (icon) {
        .sidebar => {
            p.roundRect(2, 3, 14, 12, 3);
            p.seg(7, 3.5, 7, 14.5);
        },
        .panel_right => {
            p.roundRect(2, 3, 14, 12, 3);
            p.seg(11, 3.5, 11, 14.5);
        },
        .chevron_right => p.poly(&.{ .{ 7, 4 }, .{ 12, 9 }, .{ 7, 14 } }),
        .chevron_left => p.poly(&.{ .{ 11, 4 }, .{ 6, 9 }, .{ 11, 14 } }),
        .chevron_down => p.poly(&.{ .{ 4, 7 }, .{ 9, 12 }, .{ 14, 7 } }),
        .arrow_left => {
            p.seg(3, 9, 15, 9);
            p.poly(&.{ .{ 8, 4 }, .{ 3, 9 }, .{ 8, 14 } });
        },
        .arrow_right => {
            p.seg(3, 9, 15, 9);
            p.poly(&.{ .{ 10, 4 }, .{ 15, 9 }, .{ 10, 14 } });
        },
        .arrow_up => {
            p.seg(9, 15, 9, 3);
            p.poly(&.{ .{ 4, 8 }, .{ 9, 3 }, .{ 14, 8 } });
        },
        .plus => {
            p.seg(9, 3, 9, 15);
            p.seg(3, 9, 15, 9);
        },
        .search => {
            list.arc(ox + 8 * u, oy + 8 * u, 5 * u, 0, 2 * std.math.pi, lw, color);
            p.seg(11.8, 11.8, 15.5, 15.5);
        },
        .more => {
            for ([_]f32{ 3.5, 9, 14.5 }) |x| list.circle(ox + x * u, oy + 9 * u, 1.2 * u * @max(weight, 0.8) + 0.2, color);
        },
        .sliders => {
            p.seg(3, 5.5, 15, 5.5);
            p.seg(3, 12.5, 15, 12.5);
            list.circle(ox + 6 * u, oy + 5.5 * u, 2 * u, color);
            list.circle(ox + 12 * u, oy + 12.5 * u, 2 * u, color);
        },
    }
}

const Painter = struct {
    list: *gfx.DisplayList,
    ox: f32,
    oy: f32,
    u: f32,
    lw: f32,
    color: Color,

    fn seg(p: Painter, x0: f32, y0: f32, x1: f32, y1: f32) void {
        p.list.line(p.ox + x0 * p.u, p.oy + y0 * p.u, p.ox + x1 * p.u, p.oy + y1 * p.u, p.lw, p.color);
    }

    fn poly(p: Painter, pts: []const [2]f32) void {
        var buf: [8][2]f32 = undefined;
        for (pts, 0..) |q, i| buf[i] = .{ p.ox + q[0] * p.u, p.oy + q[1] * p.u };
        p.list.polyline(buf[0..pts.len], p.lw, p.color, false);
    }

    /// Outline of a rounded rectangle in design units.
    fn roundRect(p: Painter, x: f32, y: f32, w: f32, h: f32, r: f32) void {
        const n = 4; // segments per corner
        var buf: [4 * (n + 1)][2]f32 = undefined;
        var k: usize = 0;
        const corners = [4][2]f32{ .{ x + w - r, y + r }, .{ x + w - r, y + h - r }, .{ x + r, y + h - r }, .{ x + r, y + r } };
        for (corners, 0..) |c, ci| {
            const a0 = -std.math.pi / 2.0 + @as(f32, @floatFromInt(ci)) * std.math.pi / 2.0;
            for (0..n + 1) |i| {
                const a = a0 + @as(f32, @floatFromInt(i)) / n * std.math.pi / 2.0;
                buf[k] = .{ p.ox + (c[0] + @cos(a) * r) * p.u, p.oy + (c[1] + @sin(a) * r) * p.u };
                k += 1;
            }
        }
        p.list.polyline(&buf, p.lw, p.color, true);
    }
};

test "every icon draws something inside its square" {
    var l = gfx.DisplayList.init(std.testing.allocator);
    defer l.deinit();
    const r: Rect = .{ .x = 100, .y = 50, .w = 36, .h = 36 }; // scaled 2x
    for (std.enums.values(Icon)) |icon| {
        l.reset();
        draw(&l, icon, r, Color.hex(0xffffff), 1);
        try std.testing.expect(l.cmds.items.len > 0);
        for (l.cmds.items) |cmd| {
            const slack: f32 = 1.5; // stroke half-width and round caps
            switch (cmd) {
                .line => |ln| {
                    for ([_][2]f32{ .{ ln.x0, ln.y0 }, .{ ln.x1, ln.y1 } }) |pt| {
                        try std.testing.expect(pt[0] >= r.x - slack and pt[0] <= r.x + r.w + slack);
                        try std.testing.expect(pt[1] >= r.y - slack and pt[1] <= r.y + r.h + slack);
                    }
                },
                .ellipse => |e| {
                    try std.testing.expect(e.cx - e.rx >= r.x - slack and e.cx + e.rx <= r.x + r.w + slack);
                    try std.testing.expect(e.cy - e.ry >= r.y - slack and e.cy + e.ry <= r.y + r.h + slack);
                },
                .arc => |a| try std.testing.expect(a.cx - a.r >= r.x - slack and a.cx + a.r <= r.x + r.w + slack),
                else => return error.UnexpectedCommand,
            }
        }
    }
}

test "icons centre in a non-square rect and scale with the short side" {
    var l = gfx.DisplayList.init(std.testing.allocator);
    defer l.deinit();
    draw(&l, .plus, .{ .x = 0, .y = 0, .w = 100, .h = 18 }, Color.hex(0xffffff), 1);
    const v = l.cmds.items[0].line; // vertical bar at design x = 9
    try std.testing.expectEqual(@as(f32, 50), v.x0);
    try std.testing.expectEqual(@as(f32, 3), v.y0);
}
