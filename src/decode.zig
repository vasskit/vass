//! Image decoding (PNG, JPEG, BMP, first frame of GIF) from memory to straight
//! (non-premultiplied) RGBA8, through stb_image, plus the pure pixel helpers
//! used to prepare a texture. No platform dependency.
const std = @import("std");

extern fn stbi_info_from_memory(buf: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int) c_int;
extern fn stbi_load_from_memory(buf: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int, req_comp: c_int) ?[*]u8;
extern fn stbi_image_free(p: ?*anyopaque) void;

/// Largest width or height accepted.
pub const max_dimension: u32 = 16384;
/// Largest pixel count accepted (64 Mpx = 256 MB of RGBA).
pub const max_pixels: u64 = 64 * 1024 * 1024;
/// Largest encoded file `Window.loadImageFile` reads.
pub const max_file_bytes: usize = 256 * 1024 * 1024;

pub const Error = error{ InvalidImage, ImageTooLarge, OutOfMemory };

pub const Decoded = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes, rows top to bottom, straight alpha.
    pixels: []u8,

    pub fn deinit(d: Decoded, gpa: std.mem.Allocator) void {
        gpa.free(d.pixels);
    }
};

/// True if a `w` x `h` image is within the limits.
pub fn sizeOk(w: u64, h: u64) bool {
    return w > 0 and h > 0 and w <= max_dimension and h <= max_dimension and w * h <= max_pixels;
}

/// Decodes an encoded image. Caller frees with `Decoded.deinit`.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int)) return error.InvalidImage;
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    // Check the size from the header first, so a huge image is never allocated.
    if (stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp) == 0) return error.InvalidImage;
    if (w <= 0 or h <= 0) return error.InvalidImage;
    if (!sizeOk(@intCast(w), @intCast(h))) return error.ImageTooLarge;
    const raw = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse return error.InvalidImage;
    defer stbi_image_free(raw);
    if (w <= 0 or h <= 0 or !sizeOk(@intCast(w), @intCast(h))) return error.InvalidImage;
    const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const out = try gpa.alloc(u8, n);
    @memcpy(out, raw[0..n]);
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = out };
}

/// Straight RGBA -> premultiplied, in place.
pub fn premultiply(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const a: u32 = pixels[i + 3];
        if (a == 255) continue;
        inline for (0..3) |k| pixels[i + k] = @intCast((@as(u32, pixels[i + k]) * a + 127) / 255);
    }
}

pub const Prepared = struct { width: u32, height: u32, pixels: []u8 };

/// A premultiplied copy of straight RGBA `rgba`, box-filtered down by an
/// integer factor so neither side exceeds `max_side` (a texture can be much
/// smaller than a 4000 px photo and look better when it is drawn small).
/// Caller frees `pixels`.
pub fn prepareTexture(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, max_side: u32) !Prepared {
    std.debug.assert(rgba.len == @as(usize, w) * h * 4);
    const big = @max(w, h);
    const f: u32 = if (max_side == 0 or big <= max_side) 1 else (big + max_side - 1) / max_side;
    const full = try gpa.dupe(u8, rgba);
    premultiply(full);
    if (f == 1) return .{ .width = w, .height = h, .pixels = full };
    defer gpa.free(full);
    const ow = @max(1, w / f);
    const oh = @max(1, h / f);
    const out = try gpa.alloc(u8, @as(usize, ow) * oh * 4);
    errdefer gpa.free(out);
    for (0..oh) |y| for (0..ow) |x| {
        var sum = [4]u32{ 0, 0, 0, 0 };
        var count: u32 = 0;
        const y1 = if (y + 1 == oh) h else (y + 1) * f;
        const x1 = if (x + 1 == ow) w else (x + 1) * f;
        for (y * f..y1) |sy| for (x * f..x1) |sx| {
            const p = (sy * w + sx) * 4;
            for (0..4) |k| sum[k] += full[p + k];
            count += 1;
        };
        const o = (y * ow + x) * 4;
        for (0..4) |k| out[o + k] = @intCast((sum[k] + count / 2) / count);
    };
    return .{ .width = ow, .height = oh, .pixels = out };
}

const testing = std.testing;
const png = @import("png.zig");

test "decodes a PNG with straight alpha" {
    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 255 };
    const enc = try png.encodeRgba(testing.allocator, 2, 2, &px);
    defer testing.allocator.free(enc);
    const d = try decode(testing.allocator, enc);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), d.width);
    try testing.expectEqual(@as(u32, 2), d.height);
    try testing.expectEqualSlices(u8, &px, d.pixels);
}

// A 4x2 baseline JPEG (left half red, right half blue), made with `sips`.
const tiny_jpeg = @embedFile("testdata/tiny.jpg");

test "decodes a JPEG" {
    const d = try decode(testing.allocator, tiny_jpeg);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 8), d.width);
    try testing.expectEqual(@as(u32, 8), d.height);
    // Left pixel is red-ish, right pixel blue-ish (channel order is RGBA).
    try testing.expect(d.pixels[0] > 200 and d.pixels[1] < 60 and d.pixels[2] < 60 and d.pixels[3] == 255);
    const r = (7 * 4);
    try testing.expect(d.pixels[r] < 60 and d.pixels[r + 2] > 200);
}

test "garbage and truncated data fail without leaking" {
    try testing.expectError(error.InvalidImage, decode(testing.allocator, "this is not an image at all"));
    try testing.expectError(error.InvalidImage, decode(testing.allocator, ""));
    try testing.expectError(error.InvalidImage, decode(testing.allocator, tiny_jpeg[0..40]));
    const px: [16]u8 = @splat(0);
    const enc = try png.encodeRgba(testing.allocator, 2, 2, &px);
    defer testing.allocator.free(enc);
    try testing.expectError(error.InvalidImage, decode(testing.allocator, enc[0 .. enc.len / 2]));
}

test "absurd dimensions are rejected from the header" {
    // A PNG header claiming 100000 x 100000 pixels (no pixel data follows).
    var hdr: [33]u8 = undefined;
    const sig = "\x89PNG\r\n\x1a\n";
    @memcpy(hdr[0..8], sig);
    std.mem.writeInt(u32, hdr[8..12], 13, .big);
    @memcpy(hdr[12..16], "IHDR");
    std.mem.writeInt(u32, hdr[16..20], 100000, .big);
    std.mem.writeInt(u32, hdr[20..24], 100000, .big);
    hdr[24..29].* = .{ 8, 6, 0, 0, 0 };
    @memset(hdr[29..33], 0);
    const err = decode(testing.allocator, &hdr);
    try testing.expect(err == error.ImageTooLarge or err == error.InvalidImage);
    try testing.expect(!sizeOk(100000, 100000));
    try testing.expect(sizeOk(4000, 3000));
    try testing.expect(!sizeOk(0, 5));
}

test "premultiply and box downscale" {
    var px = [_]u8{ 200, 100, 50, 128, 1, 2, 3, 255 };
    premultiply(&px);
    try testing.expectEqualSlices(u8, &.{ 100, 50, 25, 128, 1, 2, 3, 255 }, &px);

    // 4x2 -> factor 2 -> 2x1, averaging 2x2 blocks.
    var src: [4 * 2 * 4]u8 = undefined;
    for (0..8) |i| src[i * 4 ..][0..4].* = .{ if (i % 4 < 2) 0 else 100, 0, 0, 255 };
    const p = try prepareTexture(testing.allocator, &src, 4, 2, 2);
    defer testing.allocator.free(p.pixels);
    try testing.expectEqual(@as(u32, 2), p.width);
    try testing.expectEqual(@as(u32, 1), p.height);
    try testing.expectEqual(@as(u8, 0), p.pixels[0]);
    try testing.expectEqual(@as(u8, 100), p.pixels[4]);
}
