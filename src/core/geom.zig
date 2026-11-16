pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }

    /// `r` shrunk by `pad` on every side (never below zero size).
    pub fn inset(r: Rect, pad: f32) Rect {
        const w = @max(0, r.w - 2 * pad);
        const h = @max(0, r.h - 2 * pad);
        return .{ .x = r.x + (r.w - w) / 2, .y = r.y + (r.h - h) / 2, .w = w, .h = h };
    }

    /// Cuts a strip of height `h` off the top of `r`, shrinking `r`, and returns the strip.
    /// If `r` is shorter than `h` the strip is whatever is left.
    pub fn cutTop(r: *Rect, h: f32) Rect {
        const c = std.math.clamp(h, 0, r.h);
        const piece: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = c };
        r.y += c;
        r.h -= c;
        return piece;
    }

    /// Like `cutTop`, from the bottom edge.
    pub fn cutBottom(r: *Rect, h: f32) Rect {
        const c = std.math.clamp(h, 0, r.h);
        r.h -= c;
        return .{ .x = r.x, .y = r.y + r.h, .w = r.w, .h = c };
    }

    /// Like `cutTop`, from the left edge, with width `w`.
    pub fn cutLeft(r: *Rect, w: f32) Rect {
        const c = std.math.clamp(w, 0, r.w);
        const piece: Rect = .{ .x = r.x, .y = r.y, .w = c, .h = r.h };
        r.x += c;
        r.w -= c;
        return piece;
    }

    /// Like `cutLeft`, from the right edge.
    pub fn cutRight(r: *Rect, w: f32) Rect {
        const c = std.math.clamp(w, 0, r.w);
        r.w -= c;
        return .{ .x = r.x + r.w, .y = r.y, .w = c, .h = r.h };
    }

    /// The `i`-th of `n` equal-width columns of `r`, separated by `gap`.
    pub fn column(r: Rect, n: usize, gap: f32, i: usize) Rect {
        const nf: f32 = @floatFromInt(n);
        const w = (r.w - gap * (nf - 1)) / nf;
        return .{ .x = r.x + @as(f32, @floatFromInt(i)) * (w + gap), .y = r.y, .w = w, .h = r.h };
    }

    /// The `i`-th of `n` equal-height rows of `r`, separated by `gap`.
    pub fn row(r: Rect, n: usize, gap: f32, i: usize) Rect {
        const nf: f32 = @floatFromInt(n);
        const h = (r.h - gap * (nf - 1)) / nf;
        return .{ .x = r.x, .y = r.y + @as(f32, @floatFromInt(i)) * (h + gap), .w = r.w, .h = h };
    }

    /// A `w` x `h` rectangle centred in `r`.
    pub fn center(r: Rect, w: f32, h: f32) Rect {
        return .{ .x = r.x + (r.w - w) / 2, .y = r.y + (r.h - h) / 2, .w = w, .h = h };
    }
};

const std = @import("std");
const expectEqual = std.testing.expectEqual;

test "rect cuts shrink the source and return the strip" {
    var r: Rect = .{ .x = 10, .y = 20, .w = 100, .h = 50 };
    const top = r.cutTop(10);
    try expectEqual(Rect{ .x = 10, .y = 20, .w = 100, .h = 10 }, top);
    try expectEqual(Rect{ .x = 10, .y = 30, .w = 100, .h = 40 }, r);
    const bot = r.cutBottom(15);
    try expectEqual(Rect{ .x = 10, .y = 55, .w = 100, .h = 15 }, bot);
    try expectEqual(Rect{ .x = 10, .y = 30, .w = 100, .h = 25 }, r);
    const left = r.cutLeft(30);
    try expectEqual(Rect{ .x = 10, .y = 30, .w = 30, .h = 25 }, left);
    const right = r.cutRight(20);
    try expectEqual(Rect{ .x = 90, .y = 30, .w = 20, .h = 25 }, right);
    try expectEqual(Rect{ .x = 40, .y = 30, .w = 50, .h = 25 }, r);
}

test "rect cuts clamp to what is left" {
    var r: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const a = r.cutTop(25);
    try expectEqual(@as(f32, 10), a.h);
    try expectEqual(@as(f32, 0), r.h);
    const b = r.cutTop(5);
    try expectEqual(@as(f32, 0), b.h);
}

test "inset, columns, rows, center" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 328, .h = 100 };
    try expectEqual(Rect{ .x = 8, .y = 8, .w = 312, .h = 84 }, r.inset(8));
    try expectEqual(@as(f32, 0), r.inset(1000).w);
    const c1 = r.column(3, 8, 1);
    try expectEqual(@as(f32, 104), c1.w);
    try expectEqual(@as(f32, 112), c1.x);
    try expectEqual(@as(f32, 224), r.column(3, 8, 2).x);
    const r2 = r.row(2, 10, 1);
    try expectEqual(Rect{ .x = 0, .y = 55, .w = 328, .h = 45 }, r2);
    try expectEqual(Rect{ .x = 114, .y = 40, .w = 100, .h = 20 }, r.center(100, 20));
}


pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn hex(comptime v: u24) Color {
        return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
    }

    pub fn alpha(c: Color, a: u8) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }
};
