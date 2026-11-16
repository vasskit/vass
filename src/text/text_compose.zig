//! Pixel helpers for putting colour emoji into a line of text: scale a colour glyph bitmap down
//! and merge pieces into one RGBA buffer. Pure Zig (no SDL, no font), so the tests run anywhere.
//!
//! The emoji font's bitmaps come out of SDL_ttf as little-endian ARGB8888, that is bytes B, G,
//! R, A in memory, with *premultiplied* colour (FreeType premultiplies PNG strikes). The text
//! texture is straight-alpha RGBA, so scaling happens in premultiplied space (no dark fringes)
//! and the result is un-premultiplied on the way out.
const std = @import("std");

/// How wide a bitmap of `src` pixels becomes when scaled by `num / den` (rounded, at least 1
/// for a non-empty bitmap). The one place the draw and measure code get emoji widths from.
pub fn scaled(src: u32, num: u32, den: u32) u32 {
    if (src == 0 or den == 0) return 0;
    const v = (@as(u64, src) * num * 2 + den) / (den * 2);
    return @intCast(@max(1, v));
}

/// Scales premultiplied BGRA (`src`, `sw` by `sh` pixels, `pitch` bytes per row) to `dw` by `dh`
/// with an area-weighted average (a box filter: exact for reductions, nearest-ish for
/// enlargements) and returns it as straight-alpha RGBA, `dw * dh * 4` bytes, owned by the caller.
/// Equal sizes convert without resampling, so a 1:1 emoji strike is untouched.
pub fn scaleBgraPremulToRgba(gpa: std.mem.Allocator, src: []const u8, sw: usize, sh: usize, pitch: usize, dw: usize, dh: usize) ![]u8 {
    const out = try gpa.alloc(u8, dw * dh * 4);
    errdefer gpa.free(out);
    if (dw == 0 or dh == 0 or sw == 0 or sh == 0) {
        @memset(out, 0);
        return out;
    }
    const sx_step = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(dw));
    const sy_step = @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(dh));
    for (0..dh) |dy| {
        const y0 = @as(f32, @floatFromInt(dy)) * sy_step;
        const y1 = y0 + sy_step;
        for (0..dw) |dx| {
            const x0 = @as(f32, @floatFromInt(dx)) * sx_step;
            const x1 = x0 + sx_step;
            var acc: [4]f32 = .{ 0, 0, 0, 0 };
            var area: f32 = 0;
            var sy: usize = @intFromFloat(@floor(y0));
            while (@as(f32, @floatFromInt(sy)) < y1 and sy < sh) : (sy += 1) {
                const wy = @min(y1, @as(f32, @floatFromInt(sy + 1))) - @max(y0, @as(f32, @floatFromInt(sy)));
                if (wy <= 0) continue;
                var sx: usize = @intFromFloat(@floor(x0));
                while (@as(f32, @floatFromInt(sx)) < x1 and sx < sw) : (sx += 1) {
                    const wx = @min(x1, @as(f32, @floatFromInt(sx + 1))) - @max(x0, @as(f32, @floatFromInt(sx)));
                    if (wx <= 0) continue;
                    const p = src[sy * pitch + sx * 4 ..][0..4];
                    const wgt = wx * wy;
                    acc[0] += @as(f32, @floatFromInt(p[0])) * wgt;
                    acc[1] += @as(f32, @floatFromInt(p[1])) * wgt;
                    acc[2] += @as(f32, @floatFromInt(p[2])) * wgt;
                    acc[3] += @as(f32, @floatFromInt(p[3])) * wgt;
                    area += wgt;
                }
            }
            const o = out[(dy * dw + dx) * 4 ..][0..4];
            if (area <= 0) {
                o.* = .{ 0, 0, 0, 0 };
                continue;
            }
            const b = acc[0] / area;
            const g = acc[1] / area;
            const r = acc[2] / area;
            const a = acc[3] / area;
            o.* = unpremultiply(r, g, b, a);
        }
    }
    return out;
}

/// Premultiplied channels (0...255, as floats) to straight RGBA bytes.
fn unpremultiply(r: f32, g: f32, b: f32, a: f32) [4]u8 {
    if (a < 0.5) return .{ 0, 0, 0, 0 };
    const k = 255.0 / a;
    return .{
        @intFromFloat(@min(255.0, @round(r * k))),
        @intFromFloat(@min(255.0, @round(g * k))),
        @intFromFloat(@min(255.0, @round(b * k))),
        @intFromFloat(@min(255.0, @round(a))),
    };
}

/// Draws straight-alpha RGBA `src` (`sw` by `sh`) over `dst` (`dw` by `dh`, straight alpha) with
/// its top-left at (`x`, `y`), which may be negative or reach past the edges (clipped). `opacity`
/// (0...255) multiplies the source alpha. Colours are not touched by it, only coverage.
pub fn overRgba(dst: []u8, dw: usize, dh: usize, src: []const u8, sw: usize, sh: usize, x: i64, y: i64, opacity: u8) void {
    for (0..sh) |sy| {
        const ty = y + @as(i64, @intCast(sy));
        if (ty < 0 or ty >= dh) continue;
        for (0..sw) |sx| {
            const tx = x + @as(i64, @intCast(sx));
            if (tx < 0 or tx >= dw) continue;
            const s = src[(sy * sw + sx) * 4 ..][0..4];
            const sa: u32 = (@as(u32, s[3]) * opacity + 127) / 255;
            if (sa == 0) continue;
            const d = dst[(@as(usize, @intCast(ty)) * dw + @as(usize, @intCast(tx))) * 4 ..][0..4];
            const da: u32 = d[3];
            if (da == 0 or sa == 255) {
                d.* = .{ s[0], s[1], s[2], @intCast(sa) };
                continue;
            }
            // Straight-alpha "over": out_a = sa + da (1 - sa); out_c = (sc sa + dc da (1 - sa)) / out_a.
            const inv = 255 - sa;
            const out_a = sa * 255 + da * inv; // scaled by 255
            for (0..3) |i| {
                const num = @as(u32, s[i]) * sa * 255 + @as(u32, d[i]) * da * inv;
                d[i] = @intCast(@min(255, (num + out_a / 2) / out_a));
            }
            d[3] = @intCast((out_a + 127) / 255);
        }
    }
}

/// Copies a little-endian ARGB8888 surface (bytes B, G, R, A, straight alpha) over `dst` like
/// `overRgba`, for text drawn by SDL_ttf. The alpha is used as it is (the colour was chosen
/// when SDL_ttf drew it).
pub fn overArgb(dst: []u8, dw: usize, dh: usize, src: []const u8, sw: usize, sh: usize, pitch: usize, x: i64, y: i64) void {
    for (0..sh) |sy| {
        const ty = y + @as(i64, @intCast(sy));
        if (ty < 0 or ty >= dh) continue;
        for (0..sw) |sx| {
            const tx = x + @as(i64, @intCast(sx));
            if (tx < 0 or tx >= dw) continue;
            const s = src[sy * pitch + sx * 4 ..][0..4];
            if (s[3] == 0) continue;
            const d = dst[(@as(usize, @intCast(ty)) * dw + @as(usize, @intCast(tx))) * 4 ..][0..4];
            d.* = .{ s[2], s[1], s[0], s[3] };
        }
    }
}

// ---- tests ------------------------------------------------------------------

const t = std.testing;

test "scaled rounds and never collapses a glyph to nothing" {
    try t.expectEqual(@as(u32, 0), scaled(0, 1, 2));
    try t.expectEqual(@as(u32, 30), scaled(160, 30, 160));
    try t.expectEqual(@as(u32, 160), scaled(160, 1, 1));
    try t.expectEqual(@as(u32, 1), scaled(3, 1, 100));
    try t.expectEqual(@as(u32, 15), scaled(20, 3, 4));
}

test "a 1:1 scale only converts premultiplied BGRA to straight RGBA" {
    // One pixel half transparent red (premultiplied: B 0, G 0, R 128, A 128), one opaque green.
    const src = [_]u8{ 0, 0, 128, 128, 0, 255, 0, 255 };
    const out = try scaleBgraPremulToRgba(t.allocator, &src, 2, 1, 8, 2, 1);
    defer t.allocator.free(out);
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 128, 0, 255, 0, 255 }, out);
}

test "halving averages the premultiplied colour, so a transparent neighbour does not darken it" {
    // Left pixel opaque white, right pixel fully transparent with garbage colour data (0 alpha
    // premultiplied must have 0 colour, but straight data would not). Result: white, alpha 128.
    const src = [_]u8{ 255, 255, 255, 255, 0, 0, 0, 0 };
    const out = try scaleBgraPremulToRgba(t.allocator, &src, 2, 1, 8, 1, 1);
    defer t.allocator.free(out);
    try t.expectEqualSlices(u8, &.{ 255, 255, 255, 128 }, out);
}

test "scaling to 3 of 4 pixels keeps total coverage" {
    var src: [4 * 4]u8 = undefined;
    for (0..4) |i| src[i * 4 ..][0..4].* = .{ 10, 20, 30, 255 };
    const out = try scaleBgraPremulToRgba(t.allocator, &src, 4, 1, 16, 3, 1);
    defer t.allocator.free(out);
    for (0..3) |i| try t.expectEqualSlices(u8, &.{ 30, 20, 10, 255 }, out[i * 4 ..][0..4]);
}

test "overRgba clips, applies opacity to alpha only and blends" {
    var dst: [2 * 1 * 4]u8 = @splat(0);
    const src = [_]u8{ 200, 100, 50, 255 };
    overRgba(&dst, 2, 1, &src, 1, 1, 1, 0, 128);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 200, 100, 50, 128 }, &dst);
    overRgba(&dst, 2, 1, &src, 1, 1, 5, 5, 255); // fully outside
    try t.expectEqual(@as(u8, 0), dst[0]);
    // Opaque over half-transparent.
    overRgba(&dst, 2, 1, &src, 1, 1, 1, 0, 255);
    try t.expectEqualSlices(u8, &.{ 200, 100, 50, 255 }, dst[4..8]);
}

test "overArgb swizzles B,G,R,A to R,G,B,A" {
    var dst: [4]u8 = @splat(0);
    overArgb(&dst, 1, 1, &.{ 1, 2, 3, 4 }, 1, 1, 4, 0, 0);
    try t.expectEqualSlices(u8, &.{ 3, 2, 1, 4 }, &dst);
}
