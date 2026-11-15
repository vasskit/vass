pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }
};

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
