//! SVG icons: real Lucide (stroke, ISC) and Phosphor (fill, MIT) files at many sizes and
//! colours, next to the built-in icons, in icon buttons and a segmented control, plus a colour
//! SVG (gradient, transforms, even-odd) and an icon that is drawn at several sizes in a frame.
//!
//!     zig build icons                      run it
//!     zig build icons -- --snapshot DIR    draw a few frames, save DIR/icons.bmp, exit
const std = @import("std");
const vass = @import("vass");
const harness = @import("common/harness.zig");

const Rect = vass.Rect;
const Color = vass.Color;
const Ui = vass.Ui;
const ui_mod = vass.ui;
const SvgIcon = vass.SvgIcon;

const win_w = 780;
const win_h = 700;
const margin: f32 = 24;

const Named = struct { name: []const u8, svg: []const u8 };
const lucide = [_]Named{
    .{ .name = "paperclip", .svg = @embedFile("assets/icons/lucide-paperclip.svg") },
    .{ .name = "settings", .svg = @embedFile("assets/icons/lucide-settings.svg") },
    .{ .name = "search", .svg = @embedFile("assets/icons/lucide-search.svg") },
    .{ .name = "image", .svg = @embedFile("assets/icons/lucide-image.svg") },
    .{ .name = "send", .svg = @embedFile("assets/icons/lucide-send.svg") },
    .{ .name = "trash", .svg = @embedFile("assets/icons/lucide-trash.svg") },
    .{ .name = "check", .svg = @embedFile("assets/icons/lucide-check.svg") },
    .{ .name = "x", .svg = @embedFile("assets/icons/lucide-x.svg") },
    .{ .name = "folder", .svg = @embedFile("assets/icons/lucide-folder.svg") },
    .{ .name = "heart", .svg = @embedFile("assets/icons/lucide-heart.svg") },
    .{ .name = "star", .svg = @embedFile("assets/icons/lucide-star.svg") },
    .{ .name = "mic", .svg = @embedFile("assets/icons/lucide-mic.svg") },
    .{ .name = "sun", .svg = @embedFile("assets/icons/lucide-sun.svg") },
    .{ .name = "message-square", .svg = @embedFile("assets/icons/lucide-message-square.svg") },
    .{ .name = "sliders", .svg = @embedFile("assets/icons/lucide-sliders-horizontal.svg") },
    .{ .name = "bell", .svg = @embedFile("assets/icons/lucide-bell.svg") },
};
const phosphor = [_]Named{
    .{ .name = "heart", .svg = @embedFile("assets/icons/phosphor-heart-fill.svg") },
    .{ .name = "star", .svg = @embedFile("assets/icons/phosphor-star-fill.svg") },
    .{ .name = "gear", .svg = @embedFile("assets/icons/phosphor-gear-fill.svg") },
    .{ .name = "house", .svg = @embedFile("assets/icons/phosphor-house-fill.svg") },
    .{ .name = "plane", .svg = @embedFile("assets/icons/phosphor-paper-plane-tilt-fill.svg") },
    .{ .name = "gear bold", .svg = @embedFile("assets/icons/phosphor-gear-bold.svg") },
};

/// A colour SVG written for this example: gradient fill, transforms, an even-odd star, an arc
/// with packed flags and a stroked path with round joins.
const colour_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
    \\  <defs>
    \\    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    \\      <stop offset="0" stop-color="#ffb347"/><stop offset="1" stop-color="#d4145a"/>
    \\    </linearGradient>
    \\    <radialGradient id="r"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#3b82f6"/></radialGradient>
    \\  </defs>
    \\  <rect x="2" y="2" width="28" height="28" rx="8" fill="url(#g)"/>
    \\  <circle cx="48" cy="16" r="14" fill="url(#r)"/>
    \\  <path fill-rule="evenodd" fill="#34d399" transform="translate(2 34) scale(.5)"
    \\        d="M30 0 38 22 60 22 42 36 49 58 30 45 11 58 18 36 0 22 22 22Z M30 14 33 24 43 24 35 30 38 40 30 34 22 40 25 30 17 24 27 24Z"/>
    \\  <g transform="rotate(20 48 48)" fill="none" stroke="#f472b6" stroke-width="4" stroke-linecap="round" stroke-linejoin="round">
    \\    <path d="M38 52l6 6 12-14"/><path d="M36 44a12 12 0 0124 0"/>
    \\  </g>
    \\</svg>
;

const App = struct {
    state: ui_mod.State = .{},
    lucide: [lucide.len]SvgIcon = @splat(.none),
    phosphor: [phosphor.len]SvgIcon = @splat(.none),
    colour: SvgIcon = .none,
    seg_a: usize = 1,
    seg_b: usize = 0,
    toggled: bool = true,
    sent: usize = 0,
};

fn loadAll(app: *App, win: *vass.platform.Window) !void {
    for (lucide, 0..) |n, i| app.lucide[i] = try win.loadSvg(n.svg);
    for (phosphor, 0..) |n, i| app.phosphor[i] = try win.loadSvg(n.svg);
    app.colour = try win.loadSvgOpts(colour_svg, .{ .color = true });
}

fn heading(ui: *Ui, x: f32, y: f32, str: []const u8) void {
    ui.labelAt(x, y, str, .{ .size = 11, .color = ui.theme.dim, .weight = .semibold });
}

fn small(ui: *Ui, x: f32, y: f32, w: f32, str: []const u8) void {
    ui.label(.{ .x = x, .y = y, .w = w, .h = 12 }, str, .{ .size = 9.5, .color = ui.theme.dim, .@"align" = .center });
}

pub fn frame(app: *App, ui: *Ui) void {
    const t = ui.theme;
    var y: f32 = 20;
    ui.labelAt(margin, y, "SVG icons", .{ .size = 24 });
    y += 44;

    // Sizes: one icon at 12 ... 96 pt, in the same frame (one texture per pixel size).
    heading(ui, margin, y, "ONE ICON, SEVEN SIZES (12 16 20 24 32 48 96 PT), LUCIDE SETTINGS");
    y += 20;
    const sizes = [_]f32{ 12, 16, 20, 24, 32, 48, 96 };
    var x: f32 = margin;
    const size_names = [_][]const u8{ "12", "16", "20", "24", "32", "48", "96" };
    for (sizes, size_names) |s, sn| {
        const cell: Rect = .{ .x = x, .y = y, .w = s, .h = s };
        ui.drawIcon(cell, app.lucide[1], t.text);
        small(ui, x - 6, y + 100, s + 12, sn);
        x += s + 22;
    }
    // Same sizes in the accent colour on a card, with the fill-style gear (Phosphor).
    const card: Rect = .{ .x = x + 8, .y = y - 6, .w = win_w - margin - x - 8, .h = 108 };
    ui.list.rrect(card, 12, t.card);
    var gx = card.x + 12;
    for ([_]f32{ 16, 24, 32, 48 }) |s| {
        ui.drawIcon(.{ .x = gx, .y = card.y + (card.h - s) / 2, .w = s, .h = s }, app.phosphor[2], t.accent);
        gx += s + 10;
    }
    y += 124;

    // All the Lucide icons at 24 pt in three colours.
    heading(ui, margin, y, "LUCIDE (STROKE) AT 24 PT: TEXT, ACCENT, GOOD, 50% ALPHA");
    y += 20;
    const cols = [_]Color{ t.text, t.accent, t.good, t.text.alpha(128) };
    for (cols, 0..) |col, row| {
        for (app.lucide, 0..) |ic, i| {
            const ix = margin + @as(f32, @floatFromInt(i)) * 44;
            ui.drawIcon(.{ .x = ix, .y = y + @as(f32, @floatFromInt(row)) * 36, .w = 24, .h = 24 }, ic, col);
        }
    }
    y += 4 * 36 + 8;

    // Stroke versus fill versus built-in, same slot size.
    heading(ui, margin, y, "FILL STYLE (PHOSPHOR), STROKE STYLE (LUCIDE), BUILT-IN, AT 20 PT");
    y += 20;
    const pairs = [_]struct { a: usize, b: usize }{ .{ .a = 0, .b = 9 }, .{ .a = 1, .b = 10 }, .{ .a = 2, .b = 1 }, .{ .a = 4, .b = 4 }, .{ .a = 5, .b = 14 } };
    for (pairs, 0..) |p, i| {
        const px = margin + @as(f32, @floatFromInt(i)) * 64;
        ui.drawIcon(.{ .x = px, .y = y, .w = 20, .h = 20 }, app.phosphor[p.a], t.text);
        ui.drawIcon(.{ .x = px, .y = y + 28, .w = 20, .h = 20 }, app.lucide[p.b], t.text);
    }
    const builtin = [_]vass.icons.Icon{ .search, .plus, .sliders, .more, .arrow_up, .chevron_right, .sidebar, .panel_right };
    for (builtin, 0..) |ic, i| {
        const bx = margin + 340 + @as(f32, @floatFromInt(i)) * 30;
        ui.drawIcon(.{ .x = bx, .y = y + 14, .w = 20, .h = 20 }, ic, t.text);
    }
    ui.labelAt(margin + 340, y + 44, "built-in icons (strokes from the display list)", .{ .size = 10, .color = t.dim });
    y += 62;

    // Colour SVG.
    heading(ui, margin, y, "COLOUR SVG (TINT MULTIPLIES)");
    y += 20;
    ui.drawIcon(.{ .x = margin, .y = y, .w = 96, .h = 96 }, app.colour, Color.hex(0xffffff));
    ui.drawIcon(.{ .x = margin + 112, .y = y, .w = 48, .h = 48 }, app.colour, Color.hex(0xffffff));
    ui.drawIcon(.{ .x = margin + 112, .y = y + 56, .w = 32, .h = 32 }, app.colour, Color.hex(0xffffff));
    ui.drawIcon(.{ .x = margin + 176, .y = y, .w = 96, .h = 96 }, app.colour, Color.hex(0xF2A06A));

    // Buttons and the segmented control, with SVG icons.
    const bx0: f32 = margin + 300;
    heading(ui, bx0, y - 20, "ICON BUTTONS AND SEGMENTED CONTROL");
    const names = [_]usize{ 0, 4, 1, 5, 7 };
    for (names, 0..) |ni, i| {
        const r: Rect = .{ .x = bx0 + @as(f32, @floatFromInt(i)) * 40, .y = y, .w = 34, .h = 34 };
        const active = i == 2 and app.toggled;
        const res = ui.iconButton(r, app.lucide[ni], .{ .icon_size = 18, .active = active, .disabled = i == 4 });
        if (res.clicked) {
            if (i == 2) app.toggled = !app.toggled;
            if (i == 1) app.sent += 1;
        }
    }
    // Built-in icon button next to them, for comparison.
    _ = ui.iconButton(.{ .x = bx0 + 200, .y = y, .w = 34, .h = 34 }, .plus, .{ .icon_size = 18 });
    // Mixed built-in / SVG segments.
    const items_a = [_]ui_mod.Segment{
        .{ .icon = .{ .svg = app.lucide[3] } },
        .{ .icon = .{ .svg = app.lucide[2] } },
        .{ .icon = .{ .svg = app.lucide[13] } },
    };
    _ = ui.segmented(.{ .x = bx0, .y = y + 46, .w = 150, .h = 30 }, &items_a, &app.seg_a, .{ .icon_size = 16 });
    const items_b = [_]ui_mod.Segment{
        .{ .icon = .{ .svg = app.lucide[9] }, .label = "Likes" },
        .{ .icon = .search, .label = "Search" },
        .{ .icon = .{ .svg = app.phosphor[1] }, .label = "Stars" },
    };
    _ = ui.segmented(.{ .x = bx0, .y = y + 84, .w = 330, .h = 30 }, &items_b, &app.seg_b, .{ .icon_size = 14 });
    y += 130;

    // Pixel-snapping check: 16 pt icons at fractional positions stay crisp.
    heading(ui, margin, y, "16 PT AT FRACTIONAL POSITIONS (SNAPPED TO DEVICE PIXELS)");
    y += 20;
    for (0..12) |i| {
        const f: f32 = @floatFromInt(i);
        ui.drawIcon(.{ .x = margin + f * 24.37, .y = y + f * 0.31, .w = 16, .h = 16 }, app.lucide[0], t.text);
    }
    // Invalid handle: draws nothing, silently.
    ui.drawIcon(.{ .x = margin + 320, .y = y, .w = 16, .h = 16 }, SvgIcon.none, t.text);
    ui.labelAt(margin + 346, y + 2, "(an invalid handle draws nothing)", .{ .size = 10, .color = t.dim });
}

pub fn main(init: std.process.Init) !void {
    const env = try harness.start(init, "icons", .{}) orelse return;
    var app: App = .{};
    try harness.run(@This(), env, .{ .window = .{ .title = "SVG icons", .width = win_w, .height = win_h } }, &app);
}

pub fn setup(app: *App, win: *vass.platform.Window) !void {
    try loadAll(app, win);
}

pub fn after(_: *App, s: *harness.Step) !void {
    if (s.saved) std.debug.print("svg textures cached: {d}\n", .{s.win.svgTextureCount()});
}
