//! Image handles, fit options and the fit math. Pure data: no platform, no
//! decoding (see `decode.zig`), so the display list can carry images.
const std = @import("std");
const geom = @import("geom.zig");
const Rect = geom.Rect;
const Color = geom.Color;

/// A loaded image: an id issued by `Window.loadImage*` plus the pixel size of
/// the decoded image. Small and copyable; keep it in app state. The id 0 is
/// never issued (`none`), and ids are never reused, so drawing a handle that
/// was unloaded (or belongs to another window) draws nothing.
pub const Image = struct {
    id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,

    pub const none: Image = .{};

    pub fn isValid(img: Image) bool {
        return img.id != 0 and img.width > 0 and img.height > 0;
    }

    /// Width / height, or 1 for an invalid handle.
    pub fn aspect(img: Image) f32 {
        if (!img.isValid()) return 1;
        return @as(f32, @floatFromInt(img.width)) / @as(f32, @floatFromInt(img.height));
    }
};

pub const Fit = enum {
    /// Stretch to the whole rectangle (aspect ratio not kept).
    fill,
    /// The whole image, scaled to fit inside the rectangle and centred.
    contain,
    /// Scaled to cover the whole rectangle, centred; the overflow is cropped.
    cover,
};

pub const ImageOpts = struct {
    fit: Fit = .contain,
    /// Corner radius in points of the drawn image (for `.contain` that is the
    /// image's own rectangle, not the frame around it).
    radius: f32 = 0,
    /// 0..1, multiplies the image's own alpha.
    opacity: f32 = 1,
    /// Multiplied into every pixel (white = unchanged); its alpha counts too.
    tint: Color = .{ .r = 255, .g = 255, .b = 255 },
};

/// Where an image goes: `dest` in the same space as the rectangle, `src` the
/// part of the image shown, in image pixels.
pub const Placement = struct { dest: Rect, src: Rect };

/// Fit math for `fit`: `img_w` x `img_h` pixels into `r`. A degenerate image
/// or rectangle gives empty rectangles.
pub fn place(r: Rect, img_w: f32, img_h: f32, fit: Fit) Placement {
    const empty: Placement = .{ .dest = .{ .x = r.x, .y = r.y, .w = 0, .h = 0 }, .src = .{ .x = 0, .y = 0, .w = 0, .h = 0 } };
    if (img_w <= 0 or img_h <= 0 or r.w <= 0 or r.h <= 0) return empty;
    const full: Rect = .{ .x = 0, .y = 0, .w = img_w, .h = img_h };
    switch (fit) {
        .fill => return .{ .dest = r, .src = full },
        .contain => {
            const s = @min(r.w / img_w, r.h / img_h);
            return .{ .dest = r.center(img_w * s, img_h * s), .src = full };
        },
        .cover => {
            const s = @max(r.w / img_w, r.h / img_h);
            const sw = r.w / s;
            const sh = r.h / s;
            return .{ .dest = r, .src = .{ .x = (img_w - sw) / 2, .y = (img_h - sh) / 2, .w = sw, .h = sh } };
        },
    }
}

const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "fill stretches over the rectangle and shows the whole image" {
    const p = place(.{ .x = 10, .y = 20, .w = 100, .h = 50 }, 40, 40, .fill);
    try expectEqual(Rect{ .x = 10, .y = 20, .w = 100, .h = 50 }, p.dest);
    try expectEqual(Rect{ .x = 0, .y = 0, .w = 40, .h = 40 }, p.src);
}

test "contain letterboxes a wide image in a square and pillarboxes a tall one" {
    const sq: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const wide = place(sq, 200, 100, .contain);
    try expectEqual(Rect{ .x = 0, .y = 25, .w = 100, .h = 50 }, wide.dest);
    try expectEqual(Rect{ .x = 0, .y = 0, .w = 200, .h = 100 }, wide.src);
    const tall = place(sq, 100, 400, .contain);
    try expectEqual(Rect{ .x = 37.5, .y = 0, .w = 25, .h = 100 }, tall.dest);
    // Contain scales small images up, too.
    const small = place(sq, 10, 10, .contain);
    try expectEqual(Rect{ .x = 0, .y = 0, .w = 100, .h = 100 }, small.dest);
}

test "cover crops the overflow, centred" {
    const sq: Rect = .{ .x = 5, .y = 5, .w = 100, .h = 100 };
    const wide = place(sq, 200, 100, .cover);
    try expectEqual(sq, wide.dest);
    try expectEqual(Rect{ .x = 50, .y = 0, .w = 100, .h = 100 }, wide.src);
    const tall = place(sq, 100, 400, .cover);
    try expectEqual(Rect{ .x = 0, .y = 150, .w = 100, .h = 100 }, tall.src);
    // The shown part always has the rectangle's aspect ratio.
    const odd = place(.{ .x = 0, .y = 0, .w = 90, .h = 30 }, 123, 77, .cover);
    try expectApproxEqAbs(@as(f32, 3), odd.src.w / odd.src.h, 1e-4);
}

test "degenerate sizes give empty rectangles" {
    const r: Rect = .{ .x = 1, .y = 2, .w = 10, .h = 10 };
    try expectEqual(@as(f32, 0), place(r, 0, 10, .contain).dest.w);
    try expectEqual(@as(f32, 0), place(.{ .x = 0, .y = 0, .w = 0, .h = 5 }, 10, 10, .cover).dest.w);
}

test "handle validity" {
    try std.testing.expect(!Image.none.isValid());
    try std.testing.expect(!(Image{ .id = 3, .width = 0, .height = 4 }).isValid());
    const ok: Image = .{ .id = 3, .width = 8, .height = 4 };
    try std.testing.expect(ok.isValid());
    try expectEqual(@as(f32, 2), ok.aspect());
    try expectEqual(@as(f32, 1), Image.none.aspect());
}
