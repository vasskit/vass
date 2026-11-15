//! SDL3 backend: one window, input events, and a display-list renderer.
//! SDL is declared by hand (only what is used) so the build needs no C headers.
const std = @import("std");
const geom = @import("geom.zig");
const gfx = @import("gfx.zig");
const Color = geom.Color;

const c = struct {
    const SdlWindow = opaque {};
    const Renderer = opaque {};
    const Texture = opaque {};
    const Surface = opaque {};
    const Font = opaque {};
    const FRect = extern struct { x: f32, y: f32, w: f32, h: f32 };
    const FPoint = extern struct { x: f32, y: f32 };
    const FColor = extern struct { r: f32, g: f32, b: f32, a: f32 };
    const SdlColor = extern struct { r: u8, g: u8, b: u8, a: u8 };
    const Vertex = extern struct { position: FPoint, color: FColor, tex_coord: FPoint };
    const SdlEvent = extern union { type: u32, raw: [128]u8, force_align: u64 };

    const INIT_VIDEO: u32 = 0x20;
    const SdlRect = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };
    const WINDOW_HIDDEN: u64 = 0x8;
    const WINDOW_BORDERLESS: u64 = 0x10;
    const WINDOW_HIGH_PIXEL_DENSITY: u64 = 0x2000;
    const WINDOW_ALWAYS_ON_TOP: u64 = 0x10000;
    const WINDOW_TRANSPARENT: u64 = 0x40000000;
    const WINDOW_NOT_FOCUSABLE: u64 = 0x80000000;
    const EVENT_WINDOW_CLOSE_REQUESTED: u32 = 0x210;
    const EVENT_QUIT: u32 = 0x100;
    const EVENT_KEY_DOWN: u32 = 0x300;
    const EVENT_MOUSE_MOTION: u32 = 0x400;
    const EVENT_MOUSE_BUTTON_DOWN: u32 = 0x401;
    const BLENDMODE_BLEND: u32 = 1;

    extern fn SDL_Init(flags: u32) bool;
    extern fn SDL_Quit() void;
    extern fn SDL_GetError() [*:0]const u8;
    extern fn SDL_Delay(ms: u32) void;
    extern fn SDL_GetTicks() u64;
    extern fn SDL_CreateWindow(title: [*:0]const u8, w: c_int, h: c_int, flags: u64) ?*SdlWindow;
    extern fn SDL_DestroyWindow(w: *SdlWindow) void;
    extern fn SDL_GetWindowPixelDensity(w: *SdlWindow) f32;
    extern fn SDL_SetWindowAlwaysOnTop(w: *SdlWindow, on_top: bool) bool;
    extern fn SDL_CreateRenderer(w: *SdlWindow, name: ?[*:0]const u8) ?*Renderer;
    extern fn SDL_DestroyRenderer(r: *Renderer) void;
    extern fn SDL_SetRenderVSync(r: *Renderer, vsync: c_int) bool;
    extern fn SDL_SetRenderScale(r: *Renderer, sx: f32, sy: f32) bool;
    extern fn SDL_SetRenderDrawBlendMode(r: *Renderer, mode: u32) bool;
    extern fn SDL_SetRenderDrawColor(r: *Renderer, red: u8, g: u8, b: u8, a: u8) bool;
    extern fn SDL_RenderClear(r: *Renderer) bool;
    extern fn SDL_RenderPresent(r: *Renderer) bool;
    extern fn SDL_RenderGeometry(r: *Renderer, tex: ?*Texture, verts: [*]const Vertex, n: c_int, idx: ?[*]const c_int, n_idx: c_int) bool;
    extern fn SDL_RenderTexture(r: *Renderer, tex: *Texture, src: ?*const FRect, dst: ?*const FRect) bool;
    extern fn SDL_CreateTextureFromSurface(r: *Renderer, s: *Surface) ?*Texture;
    extern fn SDL_GetTextureSize(t: *Texture, w: *f32, h: *f32) bool;
    extern fn SDL_DestroyTexture(t: *Texture) void;
    extern fn SDL_DestroySurface(s: *Surface) void;
    extern fn SDL_RenderReadPixels(r: *Renderer, rect: ?*const anyopaque) ?*Surface;
    extern fn SDL_SaveBMP(s: *Surface, file: [*:0]const u8) bool;
    extern fn SDL_GetGlobalMouseState(x: *f32, y: *f32) u32;
    extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) bool;
    extern fn SDL_GetPrimaryDisplay() u32;
    extern fn SDL_GetDisplayBounds(display: u32, rect: *SdlRect) bool;
    extern fn SDL_GetDisplayUsableBounds(display: u32, rect: *SdlRect) bool;
    extern fn SDL_GetWindowID(w: *SdlWindow) u32;
    extern fn SDL_GetWindowProperties(w: *SdlWindow) u32;
    extern fn SDL_GetPointerProperty(props: u32, name: [*:0]const u8, default: ?*anyopaque) ?*anyopaque;
    extern fn SDL_SetWindowPosition(w: *SdlWindow, x: c_int, y: c_int) bool;
    extern fn SDL_ShowWindow(w: *SdlWindow) bool;
    extern fn SDL_HideWindow(w: *SdlWindow) bool;
    extern fn SDL_RaiseWindow(w: *SdlWindow) bool;
    extern fn SDL_PollEvent(e: *SdlEvent) bool;
    extern fn TTF_Init() bool;
    extern fn TTF_Quit() void;
    extern fn TTF_OpenFont(file: [*:0]const u8, ptsize: f32) ?*Font;
    extern fn TTF_CloseFont(f: *Font) void;
    extern fn TTF_GetStringSize(f: *Font, text: [*]const u8, len: usize, w: *c_int, h: *c_int) bool;
    extern fn TTF_RenderText_Blended(f: *Font, text: [*]const u8, len: usize, fg: SdlColor) ?*Surface;
};

pub const Event = union(enum) {
    /// The application was asked to quit (Cmd+Q, or the last window closed).
    quit,
    /// A window's close button was pressed; payload is the window id.
    close_requested: u32,
    /// `button` is 1 for left, 2 for middle, 3 for right.
    mouse_down: struct { window: u32, x: f32, y: f32, button: u8 },
    mouse_move: struct { window: u32, x: f32, y: f32 },
    /// SDL keycode; for printable keys this is the lowercase ASCII value.
    key_down: u32,
};

pub const WindowOptions = struct {
    title: [*:0]const u8,
    width: u32,
    height: u32,
    always_on_top: bool = false,
    /// No title bar or frame.
    borderless: bool = false,
    /// The window background is see-through; clear with an alpha of 0.
    transparent: bool = false,
    /// Start hidden; call `show` later.
    hidden: bool = false,
    /// If false the window never takes keyboard focus (for overlays).
    focusable: bool = true,
};

var live_windows: usize = 0;

/// Primary display in points, including the menu bar and Dock areas.
pub fn displayBounds() geom.Rect {
    var r: c.SdlRect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
    _ = c.SDL_GetDisplayBounds(c.SDL_GetPrimaryDisplay(), &r);
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
}

/// Primary display minus the menu bar and Dock.
pub fn usableBounds() geom.Rect {
    var r: c.SdlRect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
    _ = c.SDL_GetDisplayUsableBounds(c.SDL_GetPrimaryDisplay(), &r);
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
}

pub const Mouse = struct { x: f32, y: f32, left_down: bool };

/// Cursor position in screen points and the left button state, whichever
/// app has focus. Poll this for overlays, which get no motion events.
pub fn globalMouse() Mouse {
    var x: f32 = 0;
    var y: f32 = 0;
    const buttons = c.SDL_GetGlobalMouseState(&x, &y);
    return .{ .x = x, .y = y, .left_down = buttons & 1 != 0 };
}

/// Returns the next pending event for any window, or null when the queue is empty.
pub fn pollEvent() ?Event {
    var e: c.SdlEvent = undefined;
    while (c.SDL_PollEvent(&e)) {
        const window = std.mem.readInt(u32, e.raw[16..20], .little);
        switch (e.type) {
            c.EVENT_QUIT => return .quit,
            c.EVENT_WINDOW_CLOSE_REQUESTED => return .{ .close_requested = window },
            c.EVENT_KEY_DOWN => return .{ .key_down = std.mem.readInt(u32, e.raw[28..32], .little) },
            c.EVENT_MOUSE_BUTTON_DOWN, c.EVENT_MOUSE_MOTION => {
                const x: f32 = @bitCast(std.mem.readInt(u32, e.raw[28..32], .little));
                const y: f32 = @bitCast(std.mem.readInt(u32, e.raw[32..36], .little));
                if (e.type == c.EVENT_MOUSE_MOTION) return .{ .mouse_move = .{ .window = window, .x = x, .y = y } };
                return .{ .mouse_down = .{ .window = window, .x = x, .y = y, .button = e.raw[24] } };
            },
            else => {},
        }
    }
    return null;
}

const font_paths = [_][*:0]const u8{
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
};

const CachedFont = struct { px: u32, font: *c.Font };
const CachedText = struct { tex: *c.Texture, w: f32, h: f32, last_frame: u64 };

pub fn sleepMs(ms: u32) void {
    c.SDL_Delay(ms);
}

/// Milliseconds since the platform was initialised.
pub fn ticks() u64 {
    return c.SDL_GetTicks();
}

pub const Window = struct {
    gpa: std.mem.Allocator,
    win: *c.SdlWindow,
    ren: *c.Renderer,
    /// Physical pixels per logical point (2.0 on Retina displays).
    density: f32,
    frame: u64 = 0,
    fonts: std.ArrayList(CachedFont) = .empty,
    texts: std.AutoHashMapUnmanaged(u64, CachedText) = .empty,
    verts: std.ArrayList(c.Vertex) = .empty,
    idx: std.ArrayList(c_int) = .empty,
    /// If set, the next rendered frame is also saved to this path as a BMP.
    snapshot_path: ?[*:0]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, opts: WindowOptions) !Window {
        if (live_windows == 0) {
            // Let the first click on an unfocused window count as a click.
            _ = c.SDL_SetHint("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1");
            if (!c.SDL_Init(c.INIT_VIDEO)) return fail("SDL_Init");
            if (!c.TTF_Init()) return fail("TTF_Init");
        }
        var flags: u64 = c.WINDOW_HIGH_PIXEL_DENSITY;
        if (opts.always_on_top) flags |= c.WINDOW_ALWAYS_ON_TOP;
        if (opts.borderless) flags |= c.WINDOW_BORDERLESS;
        if (opts.transparent) flags |= c.WINDOW_TRANSPARENT;
        if (opts.hidden) flags |= c.WINDOW_HIDDEN;
        if (!opts.focusable) flags |= c.WINDOW_NOT_FOCUSABLE;
        const win = c.SDL_CreateWindow(opts.title, @intCast(opts.width), @intCast(opts.height), flags) orelse
            return fail("SDL_CreateWindow");
        const ren = c.SDL_CreateRenderer(win, null) orelse return fail("SDL_CreateRenderer");
        // No vsync: with several windows each present would block in turn.
        // The app paces its own frames.
        _ = c.SDL_SetRenderVSync(ren, 0);
        live_windows += 1;
        _ = c.SDL_SetRenderDrawBlendMode(ren, c.BLENDMODE_BLEND);
        const density = @max(1.0, c.SDL_GetWindowPixelDensity(win));
        _ = c.SDL_SetRenderScale(ren, density, density);
        return .{ .gpa = gpa, .win = win, .ren = ren, .density = density };
    }

    pub fn deinit(w: *Window) void {
        var it = w.texts.valueIterator();
        while (it.next()) |t| c.SDL_DestroyTexture(t.tex);
        w.texts.deinit(w.gpa);
        for (w.fonts.items) |f| c.TTF_CloseFont(f.font);
        w.fonts.deinit(w.gpa);
        w.verts.deinit(w.gpa);
        w.idx.deinit(w.gpa);
        c.SDL_DestroyRenderer(w.ren);
        c.SDL_DestroyWindow(w.win);
        live_windows -= 1;
        if (live_windows == 0) {
            c.TTF_Quit();
            c.SDL_Quit();
        }
    }

    pub fn id(w: *const Window) u32 {
        return c.SDL_GetWindowID(w.win);
    }

    pub fn show(w: *Window) void {
        _ = c.SDL_ShowWindow(w.win);
    }

    pub fn hide(w: *Window) void {
        _ = c.SDL_HideWindow(w.win);
    }

    pub fn raise(w: *Window) void {
        _ = c.SDL_RaiseWindow(w.win);
    }

    /// Top-left corner in screen points.
    pub fn setPosition(w: *Window, x: f32, y: f32) void {
        _ = c.SDL_SetWindowPosition(w.win, @intFromFloat(@round(x)), @intFromFloat(@round(y)));
    }

    /// The OS window object (an NSWindow on macOS), for platform extras.
    pub fn nativeHandle(w: *const Window) ?*anyopaque {
        return c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(w.win), "SDL.window.cocoa.window", null);
    }

    pub fn setAlwaysOnTop(w: *Window, on: bool) void {
        _ = c.SDL_SetWindowAlwaysOnTop(w.win, on);
    }

    /// Draws the display list and presents the frame.
    pub fn render(w: *Window, list: *const gfx.DisplayList, clear: Color) void {
        w.frame += 1;
        _ = c.SDL_SetRenderDrawColor(w.ren, clear.r, clear.g, clear.b, clear.a);
        _ = c.SDL_RenderClear(w.ren);
        for (list.cmds.items) |cmd| switch (cmd) {
            .rrect => |r| w.addRRect(r.rect, r.radius, r.color),
            .ellipse => |e| w.addEllipse(e.cx, e.cy, e.rx, e.ry, e.color),
            .arc => |a| w.addArc(a.cx, a.cy, a.r, a.a0, a.a1, a.width, a.color),
            .text => |t| {
                w.flush();
                w.drawText(t.x, t.y, t.str, t.size, t.color, t.alignment);
            },
        };
        w.flush();
        if (w.snapshot_path) |path| {
            w.snapshot_path = null;
            if (c.SDL_RenderReadPixels(w.ren, null)) |surf| {
                defer c.SDL_DestroySurface(surf);
                if (!c.SDL_SaveBMP(surf, path)) std.log.warn("snapshot failed: {s}", .{c.SDL_GetError()});
            }
        }
        _ = c.SDL_RenderPresent(w.ren);
        w.evictTexts();
    }

    // ---- shapes -------------------------------------------------------

    fn flush(w: *Window) void {
        if (w.idx.items.len > 0) {
            _ = c.SDL_RenderGeometry(w.ren, null, w.verts.items.ptr, @intCast(w.verts.items.len), w.idx.items.ptr, @intCast(w.idx.items.len));
        }
        w.verts.clearRetainingCapacity();
        w.idx.clearRetainingCapacity();
    }

    fn vert(w: *Window, x: f32, y: f32, col: Color, a: f32) c_int {
        const i: c_int = @intCast(w.verts.items.len);
        w.verts.append(w.gpa, .{
            .position = .{ .x = x, .y = y },
            .color = .{
                .r = @as(f32, @floatFromInt(col.r)) / 255.0,
                .g = @as(f32, @floatFromInt(col.g)) / 255.0,
                .b = @as(f32, @floatFromInt(col.b)) / 255.0,
                .a = a * @as(f32, @floatFromInt(col.a)) / 255.0,
            },
            .tex_coord = .{ .x = 0, .y = 0 },
        }) catch @panic("out of memory");
        return i;
    }

    fn tri(w: *Window, a: c_int, b: c_int, d: c_int) void {
        w.idx.appendSlice(w.gpa, &.{ a, b, d }) catch @panic("out of memory");
    }

    /// Fills a convex outline, with a one-pixel alpha feather for smooth edges.
    fn addConvex(w: *Window, pts: []const [2]f32, nrm: []const [2]f32, col: Color) void {
        const n = pts.len;
        const f = 0.5 / w.density;
        var cx: f32 = 0;
        var cy: f32 = 0;
        for (pts) |p| {
            cx += p[0];
            cy += p[1];
        }
        const nf: f32 = @floatFromInt(n);
        const center = w.vert(cx / nf, cy / nf, col, 1);
        const inner = center + 1;
        for (pts, nrm) |p, m| _ = w.vert(p[0] - m[0] * f, p[1] - m[1] * f, col, 1);
        const outer = inner + @as(c_int, @intCast(n));
        for (pts, nrm) |p, m| _ = w.vert(p[0] + m[0] * f, p[1] + m[1] * f, col, 0);
        for (0..n) |i| {
            const a: c_int = @intCast(i);
            const b: c_int = @intCast((i + 1) % n);
            w.tri(center, inner + a, inner + b);
            w.tri(inner + a, outer + a, outer + b);
            w.tri(inner + a, outer + b, inner + b);
        }
    }

    fn addRRect(w: *Window, r: geom.Rect, radius: f32, col: Color) void {
        const seg = 10;
        var pts: [4 * (seg + 1)][2]f32 = undefined;
        var nrm: [4 * (seg + 1)][2]f32 = undefined;
        const rad = @max(0, @min(radius, @min(r.w, r.h) / 2));
        if (rad < 0.05) {
            // Plain rectangle: one point per corner. (Collapsed corner arcs
            // would add sliver triangles that show up under alpha blending.)
            const sq = [4][2]f32{ .{ r.x + r.w, r.y }, .{ r.x + r.w, r.y + r.h }, .{ r.x, r.y + r.h }, .{ r.x, r.y } };
            const diag = [4][2]f32{ .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 }, .{ -1, -1 } };
            w.addConvex(&sq, &diag, col);
            return;
        }
        const centers = [4][2]f32{
            .{ r.x + r.w - rad, r.y + rad }, // top-right
            .{ r.x + r.w - rad, r.y + r.h - rad }, // bottom-right
            .{ r.x + rad, r.y + r.h - rad }, // bottom-left
            .{ r.x + rad, r.y + rad }, // top-left
        };
        var k: usize = 0;
        for (centers, 0..) |cc, corner| {
            const start = -std.math.pi / 2.0 + @as(f32, @floatFromInt(corner)) * std.math.pi / 2.0;
            for (0..seg + 1) |s| {
                const ang = start + @as(f32, @floatFromInt(s)) / seg * std.math.pi / 2.0;
                nrm[k] = .{ @cos(ang), @sin(ang) };
                pts[k] = .{ cc[0] + nrm[k][0] * rad, cc[1] + nrm[k][1] * rad };
                k += 1;
            }
        }
        w.addConvex(&pts, &nrm, col);
    }

    fn addEllipse(w: *Window, cx: f32, cy: f32, rx: f32, ry: f32, col: Color) void {
        const n = 48;
        var pts: [n][2]f32 = undefined;
        var nrm: [n][2]f32 = undefined;
        for (0..n) |i| {
            const ang = @as(f32, @floatFromInt(i)) / n * 2.0 * std.math.pi;
            pts[i] = .{ cx + @cos(ang) * rx, cy + @sin(ang) * ry };
            const gx = @cos(ang) / @max(rx, 0.001);
            const gy = @sin(ang) / @max(ry, 0.001);
            const len = @max(@sqrt(gx * gx + gy * gy), 1e-6);
            nrm[i] = .{ gx / len, gy / len };
        }
        w.addConvex(&pts, &nrm, col);
    }

    fn addArc(w: *Window, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, width: f32, col: Color) void {
        const f = 0.5 / w.density;
        const hw = width / 2;
        const steps: usize = @intFromFloat(std.math.clamp(@abs(a1 - a0) * r / 2.0, 8, 64));
        const radii = [4]f32{ r + hw + f, r + hw - f, r - hw + f, r - hw - f };
        const alphas = [4]f32{ 0, 1, 1, 0 };
        const base: c_int = @intCast(w.verts.items.len);
        for (0..steps + 1) |s| {
            const ang = a0 + (a1 - a0) * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            for (radii, alphas) |rr, al| _ = w.vert(cx + @cos(ang) * rr, cy + @sin(ang) * rr, col, al);
        }
        for (0..steps) |s| {
            const row = base + @as(c_int, @intCast(s)) * 4;
            for (0..3) |j| {
                const a = row + @as(c_int, @intCast(j));
                w.tri(a, a + 1, a + 4);
                w.tri(a + 1, a + 5, a + 4);
            }
        }
        // Round caps.
        w.addEllipse(cx + @cos(a0) * r, cy + @sin(a0) * r, hw, hw, col);
        w.addEllipse(cx + @cos(a1) * r, cy + @sin(a1) * r, hw, hw, col);
    }

    // ---- text ---------------------------------------------------------

    fn fontFor(w: *Window, px: u32) ?*c.Font {
        for (w.fonts.items) |f| if (f.px == px) return f.font;
        for (font_paths) |path| {
            if (c.TTF_OpenFont(path, @floatFromInt(px))) |font| {
                w.fonts.append(w.gpa, .{ .px = px, .font = font }) catch @panic("out of memory");
                return font;
            }
        }
        return null;
    }

    /// Width in points that `str` takes when drawn at `size`.
    pub fn measureText(w: *Window, str: []const u8, size: f32) f32 {
        if (str.len == 0) return 0;
        const font = w.fontFor(@intFromFloat(@round(size * w.density))) orelse return 0;
        var tw: c_int = 0;
        var th: c_int = 0;
        if (!c.TTF_GetStringSize(font, str.ptr, str.len, &tw, &th)) return 0;
        return @as(f32, @floatFromInt(tw)) / w.density;
    }

    fn drawText(w: *Window, x: f32, y: f32, str: []const u8, size: f32, col: Color, alignment: gfx.Align) void {
        if (str.len == 0) return;
        const px: u32 = @intFromFloat(@round(size * w.density));
        var h = std.hash.Wyhash.init(px);
        h.update(str);
        h.update(std.mem.asBytes(&col));
        const key = h.final();

        const entry = w.texts.getPtr(key) orelse blk: {
            const font = w.fontFor(px) orelse return;
            const surf = c.TTF_RenderText_Blended(font, str.ptr, str.len, .{ .r = col.r, .g = col.g, .b = col.b, .a = col.a }) orelse return;
            defer c.SDL_DestroySurface(surf);
            const tex = c.SDL_CreateTextureFromSurface(w.ren, surf) orelse return;
            var tw: f32 = 0;
            var th: f32 = 0;
            _ = c.SDL_GetTextureSize(tex, &tw, &th);
            w.texts.put(w.gpa, key, .{ .tex = tex, .w = tw / w.density, .h = th / w.density, .last_frame = w.frame }) catch @panic("out of memory");
            break :blk w.texts.getPtr(key).?;
        };
        entry.last_frame = w.frame;
        const dx = switch (alignment) {
            .left => x,
            .center => x - entry.w / 2,
            .right => x - entry.w,
        };
        const dst: c.FRect = .{ .x = dx, .y = y, .w = entry.w, .h = entry.h };
        _ = c.SDL_RenderTexture(w.ren, entry.tex, null, &dst);
    }

    /// Drops text textures that have not been drawn for a couple of seconds.
    fn evictTexts(w: *Window) void {
        if (w.frame % 120 != 0) return;
        var it = w.texts.iterator();
        while (it.next()) |e| {
            if (w.frame - e.value_ptr.last_frame > 120) {
                c.SDL_DestroyTexture(e.value_ptr.tex);
                w.texts.removeByPtr(e.key_ptr);
                it = w.texts.iterator(); // removal invalidates the iterator
            }
        }
    }
};

fn fail(what: []const u8) error{PlatformInitFailed} {
    std.log.err("{s} failed: {s}", .{ what, c.SDL_GetError() });
    return error.PlatformInitFailed;
}
