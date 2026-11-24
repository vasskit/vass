//! Display list: drawing is recorded as plain data, then handed to a backend.
//! Strings are copied into a per-frame arena, so callers can pass temporaries.
const std = @import("std");
const geom = @import("geom.zig");
const Rect = geom.Rect;
const Color = geom.Color;
const image_mod = @import("image.zig");
pub const Image = image_mod.Image;
pub const ImageOpts = image_mod.ImageOpts;
pub const Fit = image_mod.Fit;
pub const SvgIcon = image_mod.SvgIcon;

pub const Align = enum { left, center, right };

/// Font weight of a text command. A window whose fonts lack a face for the requested weight
/// draws the nearest one it has; see `backend.FontSet` for the order.
pub const Weight = enum { regular, medium, semibold, bold };

/// How a text command looks besides its size and colour. Weight, italic and mono pick the face
/// (a missing one is synthesised from the nearest); underline and strikethrough are drawn as
/// lines over the whole string in the text colour. The baseline relation in `FontMetrics` holds
/// for text within the face's ascent; see there for when it does not.
pub const TextStyle = struct {
    weight: Weight = .regular,
    italic: bool = false,
    /// The monospace family.
    mono: bool = false,
    /// Underline and strikethrough are filled lines in the text colour: with a translucent colour
    /// the line and the glyphs it crosses blend twice where they overlap.
    underline: bool = false,
    strikethrough: bool = false,
};

/// Vertical metrics of a face at one size, in points, all positive. For a text command at `y`
/// the baseline is at `y + ascent`, so to put runs of different faces on one baseline `b`,
/// draw each at `y = b - metrics.ascent` using that run's own metrics. `descent` is the
/// distance from the baseline to the bottom of the line box; `line_height` is the face's
/// recommended distance between baselines (at least `ascent + descent`). The baseline sits at
/// `y + ascent` for text whose glyphs stay within the face's ascent; SDL_ttf moves a line down
/// when a glyph rises above it, and glyphs from a fallback font sit on that font's own ascent, so
/// tall glyphs and fallback runs (CJK, symbols) can be a few pixels off.
pub const FontMetrics = struct { ascent: f32, descent: f32, line_height: f32 };

pub const Command = union(enum) {
    rrect: struct { rect: Rect, radius: f32, color: Color },
    ellipse: struct { cx: f32, cy: f32, rx: f32, ry: f32, color: Color },
    /// Stroked circular arc from angle `a0` to `a1` (radians, clockwise on screen).
    arc: struct { cx: f32, cy: f32, r: f32, a0: f32, a1: f32, width: f32, color: Color },
    /// Stroked straight segment with round caps.
    line: struct { x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: Color },
    /// `y` is the top of the line box: the baseline is `y + ascent` (see `FontMetrics`, which also
    /// says when a glyph can sit off it).
    text: struct { x: f32, y: f32, str: []const u8, size: f32, color: Color, alignment: Align, style: TextStyle = .{} },
    /// A loaded image (see `Window.loadImage`) fitted into `rect`. Drawn as nothing if the
    /// handle is not (or no longer) valid for the window.
    image: struct { rect: Rect, image: Image, opts: ImageOpts },
    /// A loaded SVG icon (see `Window.loadSvg`) fitted (contain, centred, snapped to device
    /// pixels) into `rect` and tinted with `color`. Nothing if the handle is not valid.
    svg_icon: struct { rect: Rect, icon: SvgIcon, color: Color },
    /// Restricts drawing to `Rect` (intersected with any clip already active)
    /// until the matching `pop_clip`.
    push_clip: Rect,
    pop_clip,
};

/// Number of overlay layers a `DisplayList` keeps besides the main command stream.
pub const overlay_layers = 5;

/// Commands are recorded into the main stream (`cmds`, layer 0) or, after `setLayer(n)`, into
/// overlay layer `n` (1...`overlay_layers`). `mergeLayers` appends the overlays, lowest first,
/// to `cmds`, so they are drawn after (above) everything in the main stream. Strings of all
/// layers live in the one arena.
pub const DisplayList = struct {
    arena: std.heap.ArenaAllocator,
    cmds: std.ArrayList(Command) = .empty,
    overlay: [overlay_layers]std.ArrayList(Command) = @splat(.empty),
    /// Where new commands go: 0 = `cmds`, n = `overlay[n - 1]`.
    layer: u8 = 0,

    pub fn init(gpa: std.mem.Allocator) DisplayList {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(l: *DisplayList) void {
        l.arena.deinit();
    }

    /// Call at the start of every frame.
    pub fn reset(l: *DisplayList) void {
        l.cmds = .empty;
        l.overlay = @splat(.empty);
        l.layer = 0;
        _ = l.arena.reset(.retain_capacity);
    }

    fn push(l: *DisplayList, cmd: Command) void {
        const dst = if (l.layer == 0) &l.cmds else &l.overlay[l.layer - 1];
        dst.append(l.arena.allocator(), cmd) catch @panic("out of memory");
    }

    /// Directs the commands recorded from now on to layer `n` (0 = the main stream).
    pub fn setLayer(l: *DisplayList, n: u8) void {
        l.layer = @min(n, overlay_layers);
    }

    /// Appends the overlay layers (lowest first) to the main stream and empties them. Call
    /// before rendering; `Ui.finish` does.
    pub fn mergeLayers(l: *DisplayList) void {
        const a = l.arena.allocator();
        for (&l.overlay) |*o| {
            l.cmds.appendSlice(a, o.items) catch @panic("out of memory");
            o.clearRetainingCapacity();
        }
    }

    /// A cheap soft shadow under `r`: a few stacked translucent rounded rectangles growing
    /// from the rectangle outwards by up to `blur`, shifted down by `dy`. `color`'s alpha is the
    /// darkest value near the edge.
    pub fn shadow(l: *DisplayList, r: Rect, radius: f32, blur: f32, dy: f32, color: Color) void {
        const steps = 7;
        for (0..steps) |i| {
            const f: f32 = @as(f32, @floatFromInt(steps - i)) / steps; // 1 (widest) .. 1/steps
            const e = blur * f;
            const a: f32 = @as(f32, @floatFromInt(color.a)) * 0.5 / @as(f32, steps) * (1.0 + (1.0 - f));
            l.rrect(.{ .x = r.x - e, .y = r.y - e + dy, .w = r.w + 2 * e, .h = r.h + 2 * e }, radius + e, color.alpha(@intFromFloat(@min(255, @round(a)))));
        }
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

    /// The outline of a rounded rectangle: a stroke of `width` centred on the edge of `r`,
    /// with corner `radius` (clamped to half the shorter side), made of lines and arcs. Draw
    /// it with an opaque colour: the joints overlap.
    pub fn rrectStroke(l: *DisplayList, r: Rect, radius: f32, width: f32, color: Color) void {
        if (r.w <= 0 or r.h <= 0 or width <= 0) return;
        const rad = std.math.clamp(radius, 0, @min(r.w, r.h) / 2);
        const x0 = r.x;
        const y0 = r.y;
        const x1 = r.x + r.w;
        const y1 = r.y + r.h;
        if (rad < 0.5) {
            l.polyline(&.{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } }, width, color, true);
            return;
        }
        if (r.w - 2 * rad > 0.01) {
            l.line(x0 + rad, y0, x1 - rad, y0, width, color);
            l.line(x0 + rad, y1, x1 - rad, y1, width, color);
        }
        if (r.h - 2 * rad > 0.01) {
            l.line(x0, y0 + rad, x0, y1 - rad, width, color);
            l.line(x1, y0 + rad, x1, y1 - rad, width, color);
        }
        const pi = std.math.pi;
        l.arc(x1 - rad, y0 + rad, rad, -pi / 2.0, 0, width, color);
        l.arc(x1 - rad, y1 - rad, rad, 0, pi / 2.0, width, color);
        l.arc(x0 + rad, y1 - rad, rad, pi / 2.0, pi, width, color);
        l.arc(x0 + rad, y0 + rad, rad, pi, 3.0 * pi / 2.0, width, color);
    }

    /// Draws `img` into `r` as `opts` says (fit, rounded corners, opacity, tint).
    pub fn image(l: *DisplayList, r: Rect, img: Image, opts: ImageOpts) void {
        l.push(.{ .image = .{ .rect = r, .image = img, .opts = opts } });
    }

    /// Draws the SVG icon `icon` in `r` (contain-fit, centred) in `color`: a monochrome icon is
    /// painted in that colour, a colour icon is multiplied by it (white = unchanged).
    pub fn svgIcon(l: *DisplayList, r: Rect, icon: SvgIcon, color: Color) void {
        l.push(.{ .svg_icon = .{ .rect = r, .icon = icon, .color = color } });
    }

    pub fn text(l: *DisplayList, x: f32, y: f32, size: f32, color: Color, alignment: Align, str: []const u8) void {
        const copy = l.arena.allocator().dupe(u8, str) catch @panic("out of memory");
        l.push(.{ .text = .{ .x = x, .y = y, .str = copy, .size = size, .color = color, .alignment = alignment } });
    }

    /// Like `text`, in the given font weight.
    pub fn textWeighted(l: *DisplayList, x: f32, y: f32, size: f32, color: Color, alignment: Align, weight: Weight, str: []const u8) void {
        l.textStyled(x, y, size, color, alignment, .{ .weight = weight }, str);
    }

    /// Like `text`, in `style`. `y` is the top of the line box; see `FontMetrics` for where the
    /// baseline is.
    pub fn textStyled(l: *DisplayList, x: f32, y: f32, size: f32, color: Color, alignment: Align, style: TextStyle, str: []const u8) void {
        const copy = l.arena.allocator().dupe(u8, str) catch @panic("out of memory");
        l.push(.{ .text = .{ .x = x, .y = y, .str = copy, .size = size, .color = color, .alignment = alignment, .style = style } });
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

test "image records one command with its options" {
    var l = DisplayList.init(std.testing.allocator);
    defer l.deinit();
    const img: Image = .{ .id = 1, .width = 4, .height = 4 };
    l.image(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, img, .{ .fit = .cover, .radius = 4, .opacity = 0.5 });
    try std.testing.expectEqual(@as(usize, 1), l.cmds.items.len);
    try std.testing.expectEqual(Fit.cover, l.cmds.items[0].image.opts.fit);
    try std.testing.expectEqual(@as(u32, 1), l.cmds.items[0].image.image.id);
}

test "svgIcon records one command" {
    var l = DisplayList.init(std.testing.allocator);
    defer l.deinit();
    l.svgIcon(.{ .x = 1, .y = 2, .w = 16, .h = 16 }, .{ .id = 4, .aspect = 1 }, .{ .r = 1, .g = 2, .b = 3 });
    try std.testing.expectEqual(@as(usize, 1), l.cmds.items.len);
    try std.testing.expectEqual(@as(u32, 4), l.cmds.items[0].svg_icon.icon.id);
}

test "layers: overlay commands are appended after the main ones and the layers empty" {
    var l = DisplayList.init(std.testing.allocator);
    defer l.deinit();
    l.setLayer(2);
    l.text(0, 0, 10, .{ .r = 1, .g = 1, .b = 1 }, .left, "top");
    l.setLayer(1);
    l.rect(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .r = 2, .g = 2, .b = 2 });
    l.setLayer(0);
    l.rect(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, .{ .r = 3, .g = 3, .b = 3 });
    l.rect(.{ .x = 0, .y = 0, .w = 6, .h = 6 }, .{ .r = 3, .g = 3, .b = 3 });
    try std.testing.expectEqual(@as(usize, 2), l.cmds.items.len);
    l.mergeLayers();
    try std.testing.expectEqual(@as(usize, 4), l.cmds.items.len);
    try std.testing.expectEqual(@as(f32, 5), l.cmds.items[0].rrect.rect.w);
    try std.testing.expectEqual(@as(u8, 2), l.cmds.items[2].rrect.color.r); // layer 1 before layer 2
    try std.testing.expectEqualStrings("top", l.cmds.items[3].text.str);
    l.mergeLayers(); // nothing left to append
    try std.testing.expectEqual(@as(usize, 4), l.cmds.items.len);
}

test "shadow records stacked rounded rects, widest first" {
    var l = DisplayList.init(std.testing.allocator);
    defer l.deinit();
    l.shadow(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, 8, 12, 4, .{ .r = 0, .g = 0, .b = 0, .a = 90 });
    try std.testing.expect(l.cmds.items.len >= 3);
    const first = l.cmds.items[0].rrect.rect;
    const last = l.cmds.items[l.cmds.items.len - 1].rrect.rect;
    try std.testing.expect(first.w > last.w);
    try std.testing.expect(l.cmds.items[l.cmds.items.len - 1].rrect.color.a > l.cmds.items[0].rrect.color.a);
}

test "textWeighted and textStyled record the style" {
    var l = DisplayList.init(std.testing.allocator);
    defer l.deinit();
    const col: Color = .{ .r = 1, .g = 2, .b = 3 };
    l.text(0, 0, 10, col, .left, "a");
    l.textWeighted(0, 0, 10, col, .left, .bold, "b");
    l.textStyled(0, 0, 10, col, .left, .{ .italic = true, .mono = true, .underline = true }, "c");
    try std.testing.expectEqual(TextStyle{}, l.cmds.items[0].text.style);
    try std.testing.expectEqual(Weight.bold, l.cmds.items[1].text.style.weight);
    try std.testing.expect(!l.cmds.items[1].text.style.italic);
    const st = l.cmds.items[2].text.style;
    try std.testing.expect(st.italic and st.mono and st.underline and !st.strikethrough);
}
