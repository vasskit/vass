//! Images: fit modes, rounded corners, opacity, clipping, the decoder (an embedded PNG and
//! JPEG), a generated image, the open-file dialog and drag-and-drop of image files.
//!
//!     zig build images                      run it
//!     zig build images -- --snapshot DIR    draw a few frames, save DIR/images.bmp, exit
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Ui = vass.Ui;
const ui_mod = vass.ui;
const Image = vass.Image;

const win_w = 760;
const win_h = 900;
const margin: f32 = 24;

const sticker_png = @embedFile("assets/sticker.png");
const gradient_jpg = @embedFile("assets/gradient.jpg");

const App = struct {
    state: ui_mod.State = .{},
    test_img: Image = .none,
    sticker: Image = .none,
    jpeg: Image = .none,
    tiny: Image = .none,
    huge: Image = .none,
    added: std.ArrayList(Image) = .empty,
    status: [160]u8 = undefined,
    status_len: usize = 0,
    scroll: ui_mod.ScrollState = .{},

    fn setStatus(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.status_len = if (std.fmt.bufPrint(&app.status, fmt, args)) |s| s.len else |_| 0;
    }
};

/// A 240x160 picture: colour gradient, a red square top-left (orientation / channel
/// check), a white frame, and a soft-edged disc in the middle.
fn makeTestImage(gpa: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(w));
        const fy = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
        var r: f32 = 40 + 160 * fx;
        var g: f32 = 60 + 150 * fy;
        var b: f32 = 230 - 150 * fx;
        const cx = fx - 0.5;
        const cy = (fy - 0.5) * @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(w));
        if (@sqrt(cx * cx + cy * cy) < 0.17) {
            r = 250;
            g = 240;
            b = 120;
        }
        if (fx < 0.12 and fy < 0.18) {
            r = 230;
            g = 30;
            b = 30;
        }
        if (fx < 0.01 or fx > 0.99 or fy < 0.015 or fy > 0.985) {
            r = 255;
            g = 255;
            b = 255;
        }
        px[(y * w + x) * 4 ..][0..4].* = .{ @intFromFloat(r), @intFromFloat(g), @intFromFloat(b), 255 };
    };
    return px;
}

fn loadAll(app: *App, win: *vass.platform.Window, gpa: std.mem.Allocator) !void {
    const px = try makeTestImage(gpa, 240, 160);
    defer gpa.free(px);
    app.test_img = try win.loadImagePixels(px, 240, 160);
    app.sticker = try win.loadImage(sticker_png);
    app.jpeg = try win.loadImage(gradient_jpg);

    // 8x8 checker, scaled up: linear filtering makes it soft.
    var tiny: [8 * 8 * 4]u8 = undefined;
    for (0..64) |i| {
        const on = ((i % 8) + (i / 8)) % 2 == 0;
        tiny[i * 4 ..][0..4].* = if (on) .{ 240, 90, 60, 255 } else .{ 40, 40, 60, 255 };
    }
    app.tiny = try win.loadImagePixels(&tiny, 8, 8);

    // 2400x1600: bigger than the 2048 px texture limit, so it is box-filtered on upload.
    const big = try makeTestImage(gpa, 2400, 1600);
    defer gpa.free(big);
    app.huge = try win.loadImagePixels(big, 2400, 1600);
}

fn addFile(app: *App, win: *vass.platform.Window, gpa: std.mem.Allocator, path: []const u8) void {
    const img = win.loadImageFile(path) catch |e| {
        app.setStatus("Could not load {s}: {s}", .{ std.fs.path.basename(path), @errorName(e) });
        return;
    };
    app.added.append(gpa, img) catch return;
    app.setStatus("Added {s} ({d}x{d})", .{ std.fs.path.basename(path), img.width, img.height });
}

fn heading(ui: *Ui, x: f32, y: f32, str: []const u8) void {
    ui.labelAt(x, y, str, .{ .size = 11, .color = ui.theme.dim, .weight = .semibold });
}

fn caption(ui: *Ui, r: Rect, str: []const u8) void {
    ui.label(.{ .x = r.x, .y = r.y + r.h + 4, .w = r.w, .h = 14 }, str, .{ .size = 10.5, .color = ui.theme.dim });
}

fn frame(app: *App, ui: *Ui, win: *vass.platform.Window, gpa: std.mem.Allocator, snapshot: bool) void {
    const t = ui.theme;
    var y: f32 = 20;
    ui.labelAt(margin, y, "Images", .{ .size = 24 });
    y += 46;

    // Row 1: the fit modes in the same 200x130 frames.
    heading(ui, margin, y, "FIT (THE FRAME IS THE CARD)");
    y += 20;
    const fw: f32 = 220;
    const fh: f32 = 130;
    const fits = [_]vass.image.Fit{ .fill, .contain, .cover };
    for (fits, 0..) |fit, i| {
        const r: Rect = .{ .x = margin + @as(f32, @floatFromInt(i)) * (fw + 16), .y = y, .w = fw, .h = fh };
        ui.list.rrect(r, 10, t.card);
        _ = ui.image(r, app.test_img, .{ .fit = fit });
        caption(ui, r, @tagName(fit));
    }
    y += fh + 34;

    // Row 2: rounded corners, a circle avatar, opacity, tint.
    heading(ui, margin, y, "ROUNDED, CIRCLE, OPACITY, TINT");
    y += 20;
    const sq: f32 = 130;
    const r0: Rect = .{ .x = margin, .y = y, .w = fw, .h = sq };
    _ = ui.image(r0, app.test_img, .{ .fit = .cover, .radius = 24 });
    caption(ui, r0, "cover, radius 24");
    const r1: Rect = .{ .x = margin + fw + 16, .y = y, .w = sq, .h = sq };
    _ = ui.image(r1, app.test_img, .{ .fit = .cover, .radius = sq / 2 });
    caption(ui, r1, "cover, circle");
    const r2: Rect = .{ .x = r1.x + sq + 16, .y = y, .w = 100, .h = sq };
    ui.list.rect(r2, Color.hex(0xE8E2D8));
    _ = ui.image(r2, app.test_img, .{ .fit = .cover, .radius = 12, .opacity = 0.45 });
    caption(ui, r2, "opacity 0.45");
    const r3: Rect = .{ .x = r2.x + 116, .y = y, .w = 100, .h = sq };
    _ = ui.image(r3, app.test_img, .{ .fit = .cover, .radius = 12, .tint = Color.hex(0xF2A06A) });
    caption(ui, r3, "tint");
    y += sq + 34;

    // Row 3: decoded from embedded files, and the small / large images.
    heading(ui, margin, y, "DECODED PNG (TRANSPARENT) AND JPEG, 8x8 UP, 2400x1600 DOWN");
    y += 20;
    const bg: Rect = .{ .x = margin, .y = y, .w = 200, .h = 90 };
    ui.list.rrect(bg, 10, Color.hex(0x7A8FB8)); // a light, coloured backdrop shows alpha halos
    _ = ui.image(bg.inset(8), app.sticker, .{ .fit = .contain });
    caption(ui, bg, "sticker.png");
    const jr: Rect = .{ .x = margin + 216, .y = y, .w = 135, .h = 90 };
    _ = ui.image(jr, app.jpeg, .{ .fit = .contain, .radius = 8 });
    caption(ui, jr, "gradient.jpg");
    const tr: Rect = .{ .x = margin + 216 + 151, .y = y, .w = 90, .h = 90 };
    _ = ui.image(tr, app.tiny, .{ .fit = .contain });
    caption(ui, tr, "8x8, linear");
    const hr: Rect = .{ .x = tr.x + 106, .y = y, .w = 135, .h = 90 };
    _ = ui.image(hr, app.huge, .{ .fit = .contain, .radius = 8 });
    caption(ui, hr, "2400x1600");
    y += 90 + 34;

    // Row 4: clipped inside a scroll area, and the file inputs.
    heading(ui, margin, y, "CLIPPED IN A SCROLL AREA");
    heading(ui, margin + 330, y, "OPEN OR DROP IMAGE FILES");
    y += 20;
    const sc: Rect = .{ .x = margin, .y = y, .w = 300, .h = 150 };
    ui.list.rrect(sc, 10, t.card);
    const content = ui.beginScroll(sc.inset(6), &app.scroll, 300);
    _ = ui.image(.{ .x = content.x, .y = content.y, .w = content.w, .h = 140 }, app.test_img, .{ .fit = .cover, .radius = 12 });
    _ = ui.image(.{ .x = content.x, .y = content.y + 152, .w = content.w, .h = 140 }, app.test_img, .{ .fit = .fill });
    ui.endScroll();

    const open_r: Rect = .{ .x = margin + 330, .y = y, .w = 90, .h = 28 };
    if (ui.button(open_r, "Open\u{2026}", .{})) {
        win.openFileDialog(.{
            .filters = &.{.{ .name = "Images", .pattern = "png;jpg;jpeg;bmp;gif" }},
            .allow_many = true,
        }) catch app.setStatus("A dialog is already open", .{});
    }
    ui.label(.{ .x = open_r.x + 100, .y = y + 6, .w = 320, .h = 16 }, app.status[0..app.status_len], .{ .size = 11, .color = t.dim });
    const drop_r: Rect = .{ .x = margin + 330, .y = y + 38, .w = win_w - margin * 2 - 330, .h = 112 };
    const over = ui.input.drop_active or snapshot;
    ui.list.rrect(drop_r, 10, if (over) t.button_on else t.card);
    if (over) {
        // Outline: a slightly larger accent rounded rect behind, then the card on top.
        ui.list.rrect(drop_r, 10, t.accent);
        ui.list.rrect(drop_r.inset(1.5), 9, t.button_on);
    }
    if (app.added.items.len == 0) {
        ui.label(.{ .x = drop_r.x + drop_r.w / 2, .y = drop_r.y + 48, .w = 0, .h = 16 }, "Drop images here", .{ .size = 13, .color = if (over) t.text else t.dim, .@"align" = .center });
    }
    var tx: f32 = drop_r.x + 8;
    for (app.added.items) |img| {
        if (tx + 96 > drop_r.x + drop_r.w) break;
        _ = ui.image(.{ .x = tx, .y = drop_r.y + 8, .w = 96, .h = 96 }, img, .{ .fit = .cover, .radius = 8 });
        tx += 104;
    }
    _ = gpa;
}

const Color = vass.Color;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var snapshot_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--snapshot") and i + 1 < args.len) {
            i += 1;
            snapshot_dir = args[i];
        } else {
            std.debug.print("usage: images [--snapshot DIR]\n", .{});
            return;
        }
    }

    var win = try vass.platform.Window.init(gpa, .{ .title = "Images", .width = win_w, .height = win_h });
    defer win.deinit();
    var app: App = .{};
    defer app.added.deinit(gpa);
    try loadAll(&app, &win, gpa);
    var list = vass.DisplayList.init(gpa);
    defer list.deinit();

    const theme: vass.ui.Theme = .{ .card_radius = 12 };
    var input: ui_mod.Input = .{};
    if (snapshot_dir != null) {
        app.scroll.offset = 46; // the first image is cut off at the top by the clip
        app.setStatus("Added sticker.png (96x64)", .{});
        try app.added.append(gpa, app.sticker);
        try app.added.append(gpa, app.jpeg);
    }

    var n: u32 = 0;
    var running = true;
    while (running) : (n += 1) {
        while (vass.platform.pollEvent()) |ev| {
            switch (ev) {
                .quit, .close_requested => running = false,
                .file_drop => |d| if (d.window == win.id()) addFile(&app, &win, gpa, d.path.slice()),
                else => {},
            }
            if (snapshot_dir == null) input.feed(ev, win.id());
        }
        // The dialog finishes asynchronously: poll for its result.
        if (try win.takeDialogResult(gpa)) |res| switch (res) {
            .files => |f| {
                defer f.deinit(gpa);
                for (f.paths) |p| addFile(&app, &win, gpa, p);
            },
            .cancelled => app.setStatus("Cancelled", .{}),
            .failed => app.setStatus("The dialog failed", .{}),
        };
        input.time = if (snapshot_dir != null) 0 else @as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0;
        list.reset();
        var ui = Ui.init(&list, &win, input, theme);
        ui.state = &app.state;
        frame(&app, &ui, &win, gpa, snapshot_dir != null);

        const snap = if (snapshot_dir) |dir| n == 3 and dir.len > 0 else false;
        if (snap) win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/images.bmp", .{snapshot_dir.?}, 0);
        win.render(&list, theme.bg);
        if (snap) running = false;
        input.endFrame();
        vass.platform.sleepMs(16);
    }
    // Textures are freed with the window; unload explicitly only to release memory early.
    for (app.added.items) |img| win.unloadImage(img);
}
