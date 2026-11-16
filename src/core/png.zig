//! Minimal PNG writer (uncompressed), for handing small generated images to
//! the OS, e.g. a menu-bar icon.
const std = @import("std");

fn chunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

/// Encodes straight-alpha RGBA8 pixels (`width * height * 4` bytes, rows top
/// to bottom). Caller owns the result.
pub fn encodeRgba(gpa: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit RGBA, no interlace
    try chunk(&out, gpa, "IHDR", &ihdr);

    // Scanlines, each prefixed with filter type 0.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    const stride = @as(usize, width) * 4;
    for (0..height) |row| {
        try raw.append(gpa, 0);
        try raw.appendSlice(gpa, pixels[row * stride ..][0..stride]);
    }

    // zlib stream made of stored (uncompressed) deflate blocks.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (true) {
        const n: u16 = @intCast(@min(raw.items.len - off, 65535));
        const last = off + n == raw.items.len;
        var hdr: [5]u8 = undefined;
        hdr[0] = @intFromBool(last);
        std.mem.writeInt(u16, hdr[1..3], n, .little);
        std.mem.writeInt(u16, hdr[3..5], ~n, .little);
        try z.appendSlice(gpa, &hdr);
        try z.appendSlice(gpa, raw.items[off..][0..n]);
        off += n;
        if (last) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw.items), .big);
    try z.appendSlice(gpa, &adler);
    try chunk(&out, gpa, "IDAT", z.items);
    try chunk(&out, gpa, "IEND", "");
    return out.toOwnedSlice(gpa);
}
