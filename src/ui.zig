//! Immediate-mode widgets on top of the display list.
//!
//! Every frame the app builds a `Ui`, calls widget functions, and each widget
//! both records its drawing and reports interaction from the same rectangle,
//! so there is one source of truth for where things are. There is no retained
//! state: "selected" values live in the app and are passed in.
//!
//!     var ui = Ui.init(&list, &window, input, .{});
//!     if (ui.button(btn_rect, "Mute", .{ .on = muted })) muted = !muted;
//!
//! Click detection is one frame wide (`Input.pressed`). Widgets do not occlude
//! each other: a click is seen by every widget whose rectangle contains it.
const std = @import("std");
const geom = @import("geom.zig");
const gfx = @import("gfx.zig");
const backend = @import("backend_sdl.zig");
const Rect = geom.Rect;
const Color = geom.Color;
const DisplayList = gfx.DisplayList;

/// Pointer state for one frame.
pub const Input = struct {
    /// Position in window points. Starts far away so nothing is hovered.
    mouse_x: f32 = -1e9,
    mouse_y: f32 = -1e9,
    /// True only for the frame in which a left click arrived.
    pressed: bool = false,

    /// Folds a backend event into the input if it belongs to window `window_id`.
    pub fn feed(in: *Input, ev: backend.Event, window_id: u32) void {
        switch (ev) {
            .mouse_move => |m| if (m.window == window_id) {
                in.mouse_x = m.x;
                in.mouse_y = m.y;
            },
            .mouse_down => |m| if (m.window == window_id) {
                in.mouse_x = m.x;
                in.mouse_y = m.y;
                if (m.button == 1) in.pressed = true;
            },
            else => {},
        }
    }

    /// Call once per frame after drawing, so a click is seen exactly once.
    pub fn endFrame(in: *Input) void {
        in.pressed = false;
    }
};

/// Colours and sizes the widgets draw with. Defaults are Claude Buddy's look.
pub const Theme = struct {
    bg: Color = Color.hex(0x201E1C),
    card: Color = Color.hex(0x2C2A27),
    track: Color = Color.hex(0x3C3935),
    text: Color = Color.hex(0xF3EEE6),
    dim: Color = Color.hex(0xA39D94),
    accent: Color = Color.hex(0xD98566),
    /// Text on an accent-coloured pill.
    accent_text: Color = Color.hex(0x1A1512),
    /// Fill of a button that is switched on.
    button_on: Color = Color.hex(0x54372D),
    good: Color = Color.hex(0x86C08A),
    warn: Color = Color.hex(0xE8B755),
    bad: Color = Color.hex(0xE4695C),
    card_radius: f32 = 16,
    /// Gap between neighbouring pills, tabs and buttons.
    gap: f32 = 8,
    font_label: f32 = 11,
    font_body: f32 = 12.5,
    font_button: f32 = 11.5,
};

pub const Interaction = struct { hovered: bool, clicked: bool };

pub const LabelOpts = struct {
    /// Defaults to the theme's body size.
    size: ?f32 = null,
    /// Defaults to the theme's text colour.
    color: ?Color = null,
    /// Which edge of the rectangle the text is anchored to.
    @"align": gfx.Align = .left,
};

pub const ButtonOpts = struct { on: bool = false };

pub const MeterOpts = struct {
    /// Small dim caption at the left, and the value text at the right.
    label: []const u8 = "",
    value: []const u8 = "",
    /// 0..1 fill, or null for an empty meter.
    frac: ?f64 = null,
    /// Colour of the lit segments; defaults to the theme accent.
    color: ?Color = null,
    /// 0..1 position of a tick drawn over the bar.
    marker: ?f64 = null,
    segments: usize = 24,
};

/// Text-width function, so the Ui can be used (and tested) without a window.
pub const MeasureFn = *const fn (ctx: ?*anyopaque, str: []const u8, size: f32) f32;

pub const Ui = struct {
    list: *DisplayList,
    input: Input,
    theme: Theme,
    measure_ctx: ?*anyopaque = null,
    measure_fn: ?MeasureFn = null,

    /// A Ui that draws into `list` and measures text with `win`.
    pub fn init(list: *DisplayList, win: *backend.Window, input: Input, theme: Theme) Ui {
        return .{ .list = list, .input = input, .theme = theme, .measure_ctx = win, .measure_fn = measureWindow };
    }

    /// A Ui with no window; `measure` may be null (text then measures as 0 wide).
    pub fn initHeadless(list: *DisplayList, input: Input, theme: Theme, measure_fn: ?MeasureFn) Ui {
        return .{ .list = list, .input = input, .theme = theme, .measure_fn = measure_fn };
    }

    fn measureWindow(ctx: ?*anyopaque, str: []const u8, size: f32) f32 {
        const win: *backend.Window = @ptrCast(@alignCast(ctx.?));
        return win.measureText(str, size);
    }

    /// Width in points of `str` at `size`.
    pub fn measure(ui: *const Ui, str: []const u8, size: f32) f32 {
        const f = ui.measure_fn orelse return 0;
        return f(ui.measure_ctx, str, size);
    }

    /// Hover and click state of `r` for this frame. Draws nothing.
    pub fn hit(ui: *const Ui, r: Rect) Interaction {
        const over = r.contains(ui.input.mouse_x, ui.input.mouse_y);
        return .{ .hovered = over, .clicked = over and ui.input.pressed };
    }

    /// Text anchored at `x`,`y` (top of the line); `opts.align` picks which side `x` is.
    pub fn labelAt(ui: *Ui, x: f32, y: f32, str: []const u8, opts: LabelOpts) void {
        ui.list.text(x, y, opts.size orelse ui.theme.font_body, opts.color orelse ui.theme.text, opts.@"align", str);
    }

    /// Text placed against the left, middle or right edge of `r`, at its top.
    pub fn label(ui: *Ui, r: Rect, str: []const u8, opts: LabelOpts) void {
        const x = switch (opts.@"align") {
            .left => r.x,
            .center => r.x + r.w / 2,
            .right => r.x + r.w,
        };
        ui.labelAt(x, r.y, str, opts);
    }

    /// Like `label`, formatting its text.
    pub fn labelFmt(ui: *Ui, r: Rect, comptime fmt: []const u8, args: anytype, opts: LabelOpts) void {
        var buf: [128]u8 = undefined;
        ui.label(r, std.fmt.bufPrint(&buf, fmt, args) catch "", opts);
    }

    /// A rounded panel.
    pub fn card(ui: *Ui, r: Rect) void {
        ui.list.rrect(r, ui.theme.card_radius, ui.theme.card);
    }

    /// A fully rounded toggle chip; returns true on the frame it is clicked.
    pub fn pill(ui: *Ui, r: Rect, str: []const u8, selected: bool) bool {
        const t = ui.theme;
        ui.list.rrect(r, r.h / 2, if (selected) t.accent else t.card);
        ui.list.text(r.x + r.w / 2, r.y + (r.h - 15) / 2, t.font_button, if (selected) t.accent_text else t.dim, .center, str);
        return ui.hit(r).clicked;
    }

    /// A row of pills sharing `r` equally, one per label. Clicking one stores
    /// its index in `selected`; returns true if that changed anything.
    pub fn tabs(ui: *Ui, r: Rect, labels: []const []const u8, selected: *usize) bool {
        var changed = false;
        const current = selected.*;
        for (labels, 0..) |str, i| {
            if (ui.pill(r.column(labels.len, ui.theme.gap, i), str, i == current) and i != current) {
                selected.* = i;
                changed = true;
            }
        }
        return changed;
    }

    /// A rounded button, filled when `opts.on`; returns true when clicked.
    pub fn button(ui: *Ui, r: Rect, str: []const u8, opts: ButtonOpts) bool {
        const t = ui.theme;
        ui.list.rrect(r, t.card_radius, if (opts.on) t.button_on else t.card);
        ui.list.text(r.x + r.w / 2, r.y + (r.h - 14) / 2, t.font_button, if (opts.on) t.text else t.dim, .center, str);
        return ui.hit(r).clicked;
    }

    /// A game-style segmented meter, 30 points tall: caption and value on the
    /// first line, the bar below. Make `r` at least that tall.
    pub fn meter(ui: *Ui, r: Rect, opts: MeterOpts) void {
        const t = ui.theme;
        ui.labelAt(r.x, r.y, opts.label, .{ .size = t.font_label, .color = t.dim });
        ui.labelAt(r.x + r.w, r.y, opts.value, .{ .size = t.font_button, .@"align" = .right });
        const n: f32 = @floatFromInt(opts.segments);
        const gap: f32 = 3;
        const sw = (r.w - gap * (n - 1)) / n;
        const lit: usize = if (opts.frac) |f| @intFromFloat(std.math.clamp(@ceil(f * n), 0, n)) else 0;
        for (0..opts.segments) |i| {
            const seg: Rect = .{ .x = r.x + @as(f32, @floatFromInt(i)) * (sw + gap), .y = r.y + 18, .w = sw, .h = 9 };
            ui.list.rrect(seg, 2, if (i < lit) opts.color orelse t.accent else t.track);
        }
        if (opts.marker) |m| {
            const mx = r.x + r.w * @as(f32, @floatCast(std.math.clamp(m, 0, 1)));
            ui.list.rect(.{ .x = mx - 1, .y = r.y + 15, .w = 2, .h = 15 }, t.text);
        }
    }

    /// A plain rounded progress bar: a track filling `r` and `frac` (0..1) of
    /// it in `color`, never narrower than the bar is tall.
    pub fn bar(ui: *Ui, r: Rect, frac: f32, color: Color) void {
        ui.list.rrect(r, r.h / 2, ui.theme.track);
        ui.list.rrect(.{ .x = r.x, .y = r.y, .w = @max(r.h, r.w * std.math.clamp(frac, 0, 1)), .h = r.h }, r.h / 2, color);
    }

    /// Shortens `str` with "..." until it fits `max_w` points at `size`. The
    /// result is `str` itself or a slice of `buf`.
    pub fn fitText(ui: *const Ui, buf: []u8, str: []const u8, size: f32, max_w: f32) []const u8 {
        if (str.len == 0 or ui.measure(str, size) <= max_w) return str;
        var n = @min(str.len - 1, buf.len -| 3);
        while (n > 0) : (n -= 1) {
            if (str[n] & 0xC0 == 0x80) continue; // not in the middle of a character
            @memcpy(buf[0..n], str[0..n]);
            @memcpy(buf[n..][0..3], "...");
            if (ui.measure(buf[0 .. n + 3], size) <= max_w) return buf[0 .. n + 3];
        }
        return "";
    }
};

// ---- tests (no window needed) -------------------------------------------

fn fakeMeasure(_: ?*anyopaque, str: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(str.len)) * size / 2;
}

fn testUi(list: *DisplayList, x: f32, y: f32, pressed: bool) Ui {
    return Ui.initHeadless(list, .{ .mouse_x = x, .mouse_y = y, .pressed = pressed }, .{}, fakeMeasure);
}

test "hit needs the pointer inside; clicked also needs a press" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 };
    try std.testing.expect(!testUi(&list, 5, 5, true).hit(r).clicked);
    const hover = testUi(&list, 15, 15, false).hit(r);
    try std.testing.expect(hover.hovered and !hover.clicked);
    const click = testUi(&list, 15, 15, true).hit(r);
    try std.testing.expect(click.hovered and click.clicked);
    // The default input hovers nothing.
    var idle = Ui.initHeadless(&list, .{}, .{}, null);
    try std.testing.expect(!idle.hit(r).hovered);
}

test "input feed follows its window and only left clicks press" {
    var in: Input = .{};
    in.feed(.{ .mouse_move = .{ .window = 2, .x = 9, .y = 9 } }, 1);
    try std.testing.expect(!in.pressed and in.mouse_x < 0);
    in.feed(.{ .mouse_down = .{ .window = 1, .x = 3, .y = 4, .button = 3 } }, 1);
    try std.testing.expect(!in.pressed and in.mouse_x == 3 and in.mouse_y == 4);
    in.feed(.{ .mouse_down = .{ .window = 1, .x = 5, .y = 6, .button = 1 } }, 1);
    try std.testing.expect(in.pressed);
    in.endFrame();
    try std.testing.expect(!in.pressed and in.mouse_x == 5);
}

test "pill, button and tabs report clicks" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 26 };
    var ui = testUi(&list, 50, 10, true);
    try std.testing.expect(ui.pill(r, "a", false));
    try std.testing.expect(ui.button(r, "b", .{ .on = true }));
    var miss = testUi(&list, 150, 10, true);
    try std.testing.expect(!miss.pill(r, "a", false));
    try std.testing.expect(!miss.button(r, "b", .{}));

    // Two tabs in a 208-wide row: 100 + 8 gap + 100. Click the second.
    const row: Rect = .{ .x = 0, .y = 0, .w = 208, .h = 26 };
    var sel: usize = 0;
    var second = testUi(&list, 150, 10, true);
    try std.testing.expect(second.tabs(row, &.{ "One", "Two" }, &sel));
    try std.testing.expectEqual(@as(usize, 1), sel);
    // Clicking the already selected tab changes nothing.
    try std.testing.expect(!second.tabs(row, &.{ "One", "Two" }, &sel));
    // The gap between tabs belongs to neither.
    var gap = testUi(&list, 104, 10, true);
    sel = 0;
    try std.testing.expect(!gap.tabs(row, &.{ "One", "Two" }, &sel));
    try std.testing.expectEqual(@as(usize, 0), sel);
}

test "fitText shortens to the width and keeps utf8 intact" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const ui = testUi(&list, 0, 0, false);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("short", ui.fitText(&buf, "short", 10, 100));
    // 5 points per byte at size 10: 30 wide fits 6 bytes, so 3 kept + "...".
    try std.testing.expectEqualStrings("abc...", ui.fitText(&buf, "abcdefghijkl", 10, 30));
    // A cut in the middle of a two-byte character moves back to its start.
    try std.testing.expectEqualStrings("ab...", ui.fitText(&buf, "abéééé", 10, 28));
}

test "meter lights segments and bar keeps a minimum width" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ui = testUi(&list, 0, 0, false);
    ui.meter(.{ .x = 0, .y = 0, .w = 240, .h = 30 }, .{ .frac = 0.5, .marker = 0.25, .segments = 10, .color = Color.hex(0xFF0000) });
    var lit: usize = 0;
    var ticks: usize = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .rrect => |c| {
            if (c.color.r == 0xFF) lit += 1;
            if (c.radius == 0) ticks += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), lit);
    try std.testing.expectEqual(@as(usize, 1), ticks);

    list.reset();
    ui.bar(.{ .x = 0, .y = 0, .w = 100, .h = 7 }, 0.01, Color.hex(0x112233));
    try std.testing.expectEqual(@as(f32, 7), list.cmds.items[1].rrect.rect.w);
}
