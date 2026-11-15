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
//! each other: a click is seen by every widget whose rectangle contains it,
//! except that `hit` ignores points outside the current clip (`pushClip`,
//! `beginScroll`).
//!
//! Widgets that need memory between frames take a caller-owned state struct
//! (`TextFieldState`, `ScrollState`). Which widget has keyboard focus lives in
//! a caller-owned `State`, handed to the Ui with `ui.state = &state`. There is
//! no hidden or hashed per-widget state anywhere.
const std = @import("std");
const geom = @import("geom.zig");
const gfx = @import("gfx.zig");
const backend = @import("backend_sdl.zig");
const keys = @import("keys.zig");
const text_edit = @import("text_edit.zig");
pub const TextEdit = text_edit.TextEdit;
const Rect = geom.Rect;
const Color = geom.Color;
const DisplayList = gfx.DisplayList;

/// One keyboard event of the frame, in arrival order.
pub const InEvent = union(enum) {
    key: backend.Key,
    text: backend.TextChunk,
};

/// Everything the app learned from the platform this frame. Lives across
/// frames in the app: `feed` it every event, `endFrame` it once per frame.
pub const Input = struct {
    /// Position in window points. Starts far away so nothing is hovered.
    mouse_x: f32 = -1e9,
    mouse_y: f32 = -1e9,
    /// True only for the frame in which a left click arrived.
    pressed: bool = false,
    /// True only for the frame in which the left button was released.
    released: bool = false,
    /// True while the left button is held.
    down: bool = false,
    /// Modifiers held when the last mouse button went down (shift-click).
    mouse_mods: keys.Mods = .{},
    /// Scroll since the last `endFrame`, in lines (see `backend.Event.mouse_wheel`).
    wheel_x: f32 = 0,
    wheel_y: f32 = 0,
    /// Seconds on any steady clock; the app sets it each frame. Drives caret blinking.
    time: f64 = 0,
    /// Input-method composition in progress (empty when none).
    composition: backend.Composition = .{},
    queue: [32]InEvent = undefined,
    queue_len: usize = 0,

    /// Key presses and typed text of this frame, in the order they happened.
    pub fn events(in: *const Input) []const InEvent {
        return in.queue[0..in.queue_len];
    }

    pub fn pushKey(in: *Input, code: u32, mods: keys.Mods) void {
        in.push(.{ .key = .{ .code = code, .mods = mods } });
    }

    /// Queues typed text (also how scripted input is injected).
    pub fn pushText(in: *Input, str: []const u8) void {
        var i: usize = 0;
        while (i < str.len) {
            var end = @min(i + 32, str.len);
            if (end < str.len) {
                while (end > i + 1 and str[end] & 0xC0 == 0x80) end -= 1;
            }
            in.push(.{ .text = backend.TextChunk.from(str[i..end]) });
            i = end;
        }
    }

    fn push(in: *Input, ev: InEvent) void {
        if (in.queue_len < in.queue.len) {
            in.queue[in.queue_len] = ev;
            in.queue_len += 1;
        }
    }

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
                if (m.button == 1) {
                    in.pressed = true;
                    in.down = true;
                    in.mouse_mods = m.mods;
                }
            },
            .mouse_up => |m| if (m.window == window_id) {
                in.mouse_x = m.x;
                in.mouse_y = m.y;
                if (m.button == 1) {
                    in.down = false;
                    in.released = true;
                }
            },
            .mouse_wheel => |m| if (m.window == window_id) {
                in.wheel_x += m.dx;
                in.wheel_y += m.dy;
            },
            .key_down => |k| if (k.window == window_id) in.push(.{ .key = k }),
            .text_input => |t| if (t.window == window_id) in.push(.{ .text = t.text }),
            .text_editing => |t| if (t.window == window_id) {
                in.composition = t.comp;
            },
            else => {},
        }
    }

    /// Call once per frame after drawing, so a click, a key or a scroll is seen exactly once.
    pub fn endFrame(in: *Input) void {
        in.pressed = false;
        in.released = false;
        in.wheel_x = 0;
        in.wheel_y = 0;
        in.queue_len = 0;
    }
};

/// What outlives a frame in the Ui itself: which widget has keyboard focus
/// (identified by the address of its state struct) and which one is being
/// dragged. Caller-owned; attach with `ui.state = &state`. Without one,
/// text fields never take focus.
pub const State = struct {
    focus: ?*const anyopaque = null,
    drag: ?*const anyopaque = null,

    pub fn blur(s: *State) void {
        s.focus = null;
    }

    pub fn focusOn(s: *State, widget_state: *const anyopaque) void {
        s.focus = widget_state;
    }
};

/// System clipboard hooks. `Ui.init` wires the real one; headless Uis have none
/// (copy and paste then do nothing) unless a test installs a fake.
pub const Clipboard = struct {
    /// Text on the clipboard, allocated from `gpa` (the caller frees), or null.
    get: ?*const fn (gpa: std.mem.Allocator) ?[]u8 = null,
    set: ?*const fn (gpa: std.mem.Allocator, str: []const u8) void = null,
};

fn systemClipGet(gpa: std.mem.Allocator) ?[]u8 {
    return (backend.clipboardText(gpa) catch return null);
}

fn systemClipSet(gpa: std.mem.Allocator, str: []const u8) void {
    backend.setClipboardText(gpa, str) catch {};
}

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
    /// Highlight behind selected text.
    selection: Color = Color.hex(0xD98566).alpha(110),
    /// Scrollbar thumb.
    scrollbar: Color = Color.hex(0xA39D94).alpha(150),
    /// Points scrolled per wheel "line".
    scroll_step: f32 = 24,
    /// Line spacing for wrapped text, as a multiple of the font size.
    line_spacing: f32 = 1.4,
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
    /// Focus and drag state that persists between frames; see `State`.
    state: ?*State = null,
    clipboard: Clipboard = .{},
    clips: [8]Rect = undefined,
    clip_n: usize = 0,
    scrolls: [4]ScrollFrame = undefined,
    scroll_n: usize = 0,

    /// A Ui that draws into `list` and measures text with `win`.
    pub fn init(list: *DisplayList, win: *backend.Window, input: Input, theme: Theme) Ui {
        return .{
            .list = list,
            .input = input,
            .theme = theme,
            .measure_ctx = win,
            .measure_fn = measureWindow,
            .clipboard = .{ .get = systemClipGet, .set = systemClipSet },
        };
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

    /// Hover and click state of `r` for this frame. Draws nothing. A pointer
    /// outside the current clip (`pushClip`, `beginScroll`) hits nothing.
    pub fn hit(ui: *const Ui, r: Rect) Interaction {
        const over = r.contains(ui.input.mouse_x, ui.input.mouse_y) and ui.clipContains(ui.input.mouse_x, ui.input.mouse_y);
        return .{ .hovered = over, .clicked = over and ui.input.pressed };
    }

    // ---- clipping ------------------------------------------------------

    /// The visible area widgets are currently confined to, or null if unclipped.
    pub fn clip(ui: *const Ui) ?Rect {
        return if (ui.clip_n > 0) ui.clips[ui.clip_n - 1] else null;
    }

    fn clipContains(ui: *const Ui, x: f32, y: f32) bool {
        return if (ui.clip()) |r| r.contains(x, y) else true;
    }

    /// Confines drawing and hit-testing to `r` (and the clip already active)
    /// until `popClip`. Up to 8 deep.
    pub fn pushClip(ui: *Ui, r: Rect) void {
        var next = r;
        if (ui.clip()) |p| {
            const x0 = @max(p.x, r.x);
            const y0 = @max(p.y, r.y);
            next = .{ .x = x0, .y = y0, .w = @max(0, @min(p.x + p.w, r.x + r.w) - x0), .h = @max(0, @min(p.y + p.h, r.y + r.h) - y0) };
        }
        std.debug.assert(ui.clip_n < ui.clips.len);
        if (ui.clip_n < ui.clips.len) {
            ui.clips[ui.clip_n] = next;
            ui.clip_n += 1;
        }
        ui.list.pushClip(r);
    }

    pub fn popClip(ui: *Ui) void {
        if (ui.clip_n > 0) ui.clip_n -= 1;
        ui.list.popClip();
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

    // ---- wrapped text -------------------------------------------------

    /// Line height used for wrapped text at `size`.
    pub fn lineHeight(ui: *const Ui, size: f32) f32 {
        return @round(size * ui.theme.line_spacing);
    }

    /// Iterates the lines `str` wraps to at `size` within `max_w` points.
    /// See `WrapIter`.
    pub fn wrapText(ui: *const Ui, str: []const u8, size: f32, max_w: f32) WrapIter {
        return .{ .ui = ui, .str = str, .size = size, .max_w = max_w, .done = str.len == 0 };
    }

    /// Height of `str` wrapped to `max_w` (lines times line height; 0 for "").
    pub fn measureWrapped(ui: *const Ui, str: []const u8, size: f32, max_w: f32) f32 {
        var it = ui.wrapText(str, size, max_w);
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return @as(f32, @floatFromInt(n)) * ui.lineHeight(size);
    }

    /// Draws `str` wrapped to `r.w`, starting at the top of `r` (it may run
    /// past the bottom; `r.h` is ignored). Returns the height used, equal to
    /// `measureWrapped`. Lines entirely outside the current clip are not drawn.
    pub fn labelWrapped(ui: *Ui, r: Rect, str: []const u8, opts: LabelOpts) f32 {
        const size = opts.size orelse ui.theme.font_body;
        const lh = ui.lineHeight(size);
        const x = switch (opts.@"align") {
            .left => r.x,
            .center => r.x + r.w / 2,
            .right => r.x + r.w,
        };
        const vis = ui.clip();
        var y = r.y;
        var it = ui.wrapText(str, size, r.w);
        while (it.next()) |line| : (y += lh) {
            if (vis) |v| if (y + lh < v.y or y > v.y + v.h) continue;
            if (line.len > 0) ui.labelAt(x, y, line, opts);
        }
        return y - r.y;
    }

    // ---- text field ---------------------------------------------------

    /// Byte offset in `str` whose caret position is nearest to `x` points
    /// from the start of the text.
    pub fn offsetAtX(ui: *const Ui, str: []const u8, size: f32, x: f32) usize {
        if (x <= 0) return 0;
        var prev_w: f32 = 0;
        var i: usize = 0;
        while (i < str.len) {
            const nb = text_edit.nextBoundary(str, i);
            const w = ui.measure(str[0..nb], size);
            if (w >= x) return if (x - prev_w < w - x) i else nb;
            prev_w = w;
            i = nb;
        }
        return str.len;
    }

    /// A single-line editable text field.
    ///
    /// Clicking focuses it (needs `ui.state`), clicking elsewhere or Escape
    /// blurs it. While focused it consumes this frame's typed text and keys:
    /// arrows, home/end, alt = by word, shift = select, cmd+a/c/x/v, backspace,
    /// delete. Return sets `submitted` (the text stays; clear it yourself).
    /// Click and drag select; shift-click extends. The text scrolls
    /// horizontally to keep the caret visible. The caret blinks off
    /// `Input.time`. The content is `state.edit.text()`.
    pub fn textField(ui: *Ui, r: Rect, st: *TextFieldState, opts: TextFieldOpts) TextFieldResult {
        const t = ui.theme;
        const size = opts.size orelse t.font_body;
        const line_h = @round(size * 1.3);
        const pad: f32 = 10;
        const box: Rect = .{ .x = r.x + pad, .y = r.y + 2, .w = @max(0, r.w - 2 * pad), .h = @max(0, r.h - 4) };
        const id: *const anyopaque = st;
        var res: TextFieldResult = .{};
        const in = &ui.input;
        var focused = if (ui.state) |s| s.focus == id else false;
        const hv = ui.hit(r);

        if (ui.state) |s| {
            if (hv.clicked) {
                s.focus = id;
                s.drag = id;
                focused = true;
                st.blink_origin = in.time;
                st.edit.moveTo(ui.offsetAtX(st.edit.text(), size, in.mouse_x - box.x + st.scroll_x), in.mouse_mods.shift);
            } else if (in.pressed and focused) {
                s.focus = null;
                focused = false;
            } else if (s.drag == id) {
                if (in.down) {
                    st.edit.moveTo(ui.offsetAtX(st.edit.text(), size, in.mouse_x - box.x + st.scroll_x), true);
                } else s.drag = null;
            }
        }

        if (focused) {
            const s = ui.state.?;
            for (in.events()) |ev| {
                st.blink_origin = in.time;
                switch (ev) {
                    .text => |chunk| {
                        if (chunk.len > 0) {
                            st.edit.insert(chunk.slice()) catch {};
                            res.changed = true;
                        }
                    },
                    .key => |k| switch (st.edit.handleKey(k.code, k.mods) catch .none) {
                        .none, .handled => {},
                        .changed => res.changed = true,
                        .copy => |str| ui.clipboardSet(str),
                        .cut => |str| {
                            ui.clipboardSet(str);
                            res.changed = true;
                        },
                        .paste => if (ui.clipboard.get) |get| if (get(st.edit.gpa)) |str| {
                            defer st.edit.gpa.free(str);
                            st.edit.insert(str) catch {};
                            res.changed = true;
                        },
                        .submit => res.submitted = true,
                        .cancel => {
                            s.focus = null;
                            focused = false;
                        },
                    },
                }
            }
        }

        // Scroll horizontally so the caret stays in view.
        const text = st.edit.text();
        const caret_x = ui.measure(text[0..st.edit.cursor], size);
        if (focused) {
            if (caret_x - st.scroll_x > box.w - 2) st.scroll_x = caret_x - box.w + 2;
            if (caret_x < st.scroll_x) st.scroll_x = caret_x;
        }
        st.scroll_x = std.math.clamp(st.scroll_x, 0, @max(0, ui.measure(text, size) + 2 - box.w));

        // Draw.
        ui.list.rrect(r, 10, if (focused) t.accent else t.track);
        ui.list.rrect(r.inset(1.5), 8.5, t.card);
        ui.pushClip(box);
        defer ui.popClip();
        const ty = r.y + @round((r.h - line_h) / 2);
        const tx = box.x - st.scroll_x;
        if (text.len == 0) {
            if (opts.placeholder.len > 0) ui.labelAt(box.x, ty, opts.placeholder, .{ .size = size, .color = t.dim });
        } else {
            if (focused and st.edit.hasSelection()) {
                const sel = st.edit.selection();
                const x0 = tx + ui.measure(text[0..sel.start], size);
                const x1 = tx + ui.measure(text[0..sel.end], size);
                ui.list.rect(.{ .x = x0, .y = ty, .w = x1 - x0, .h = line_h }, t.selection);
            }
            ui.list.text(tx, ty, size, t.text, .left, text);
        }
        if (focused and @mod(in.time - st.blink_origin, 1.06) < 0.53) {
            ui.list.rect(.{ .x = tx + caret_x, .y = ty, .w = 1.5, .h = line_h }, t.text);
        }
        return res;
    }

    fn clipboardSet(ui: *const Ui, str: []const u8) void {
        if (ui.clipboard.set) |set| set(std.heap.page_allocator, str);
    }

    // ---- scrolling ----------------------------------------------------

    /// Starts a scrolling viewport at `r` over content `content_h` tall.
    /// Returns the content's rectangle: `r`'s x and width, `content_h` tall,
    /// moved up by the scroll offset. Lay children out inside it; they are
    /// clipped to `r`, and clicks outside `r` don't reach them. The mouse
    /// wheel scrolls it while the pointer is over `r`. Pair with `endScroll`.
    /// The scrollbar is drawn over the right edge of `r`, so leave it some padding.
    pub fn beginScroll(ui: *Ui, r: Rect, st: *ScrollState, content_h: f32) Rect {
        const max = @max(0, content_h - r.h);
        if (ui.hit(r).hovered and ui.input.wheel_y != 0) {
            st.offset -= ui.input.wheel_y * ui.theme.scroll_step;
            ui.input.wheel_y = 0; // consumed, so an enclosing scroll area doesn't also move
        }
        // Keys: Page Up/Down always; arrows and Home/End only while no text
        // field has focus, since a field uses those itself.
        if (st.key_scroll or ui.hit(r).hovered) {
            const free = if (ui.state) |s| s.focus == null else true;
            for (ui.input.events()) |ev| switch (ev) {
                .key => |k| switch (k.code) {
                    keys.page_up => st.offset -= r.h * 0.9,
                    keys.page_down => st.offset += r.h * 0.9,
                    keys.up => if (free) {
                        st.offset -= ui.theme.scroll_step * 2;
                    },
                    keys.down => if (free) {
                        st.offset += ui.theme.scroll_step * 2;
                    },
                    keys.home => if (free) {
                        st.offset = 0;
                    },
                    keys.end => if (free) {
                        st.offset = max;
                    },
                    else => {},
                },
                else => {},
            };
        }
        st.offset = std.math.clamp(st.offset, 0, max);
        std.debug.assert(ui.scroll_n < ui.scrolls.len);
        if (ui.scroll_n < ui.scrolls.len) {
            ui.scrolls[ui.scroll_n] = .{ .rect = r, .state = st, .content_h = content_h };
            ui.scroll_n += 1;
        }
        ui.pushClip(r);
        return .{ .x = r.x, .y = r.y - st.offset, .w = r.w, .h = content_h };
    }

    /// Ends the innermost `beginScroll` and draws its scrollbar thumb if the
    /// content overflows.
    pub fn endScroll(ui: *Ui) void {
        ui.popClip();
        if (ui.scroll_n == 0) return;
        ui.scroll_n -= 1;
        const f = ui.scrolls[ui.scroll_n];
        const max = f.content_h - f.rect.h;
        if (max <= 0) return;
        const track = f.rect.h - 8;
        const thumb_h = @max(24, track * f.rect.h / f.content_h);
        const ty = f.rect.y + 4 + (track - thumb_h) * (f.state.offset / max);
        ui.list.rrect(.{ .x = f.rect.x + f.rect.w - 6, .y = ty, .w = 3, .h = thumb_h }, 1.5, ui.theme.scrollbar);
    }
};

const ScrollFrame = struct { rect: Rect, state: *ScrollState, content_h: f32 };

/// Scroll position of one `beginScroll` area. The app owns it; set `offset`
/// to scroll programmatically (it is clamped on the next `beginScroll`).
pub const ScrollState = struct {
    /// Points scrolled from the top.
    offset: f32 = 0,
    /// Scroll with the keyboard even when the pointer is elsewhere. Leave
    /// false when a window has several scroll areas: keys then go to the
    /// one under the pointer.
    key_scroll: bool = false,
};

/// State of one `textField`. Keep it at a stable address while the field
/// exists: the address is the field's focus identity.
pub const TextFieldState = struct {
    edit: TextEdit,
    /// Horizontal scroll of the text inside the field, in points.
    scroll_x: f32 = 0,
    blink_origin: f64 = 0,

    pub fn init(gpa: std.mem.Allocator) TextFieldState {
        return .{ .edit = TextEdit.init(gpa) };
    }

    pub fn deinit(s: *TextFieldState) void {
        s.edit.deinit();
    }
};

pub const TextFieldOpts = struct {
    /// Dim text shown while the field is empty.
    placeholder: []const u8 = "",
    /// Font size; defaults to the theme's body size.
    size: ?f32 = null,
};

pub const TextFieldResult = struct {
    /// The text changed this frame (typing, deleting, cut, paste).
    changed: bool = false,
    /// Return was pressed while focused.
    submitted: bool = false,
};

/// Lines of text wrapped greedily to a width. Each `next` returns a slice of
/// the source: words break at spaces (the spaces at a break are dropped),
/// '\n' always breaks (a blank line is an empty slice), and a word wider
/// than the width breaks between characters. Never splits a UTF-8 sequence.
/// Text that ends in '\n' yields a final empty line; "" yields no lines.
pub const WrapIter = struct {
    ui: *const Ui,
    str: []const u8,
    size: f32,
    max_w: f32,
    pos: usize = 0,
    done: bool,

    fn fits(it: *const WrapIter, str: []const u8) bool {
        return it.ui.measure(str, it.size) <= it.max_w;
    }

    pub fn next(it: *WrapIter) ?[]const u8 {
        if (it.done) return null;
        const s = it.str;
        const start = it.pos;
        const para_end = std.mem.indexOfScalarPos(u8, s, start, '\n') orelse s.len;
        var end_fit = start;
        var p = start;
        while (true) {
            var ws = p;
            while (ws < para_end and s[ws] == ' ') ws += 1;
            var we = ws;
            while (we < para_end and s[we] != ' ') we += 1;
            if (we == ws) break; // only spaces (or nothing) left in the paragraph
            if (it.fits(s[start..we])) {
                end_fit = we;
                p = we;
                continue;
            }
            if (end_fit == start) {
                // Not even the first word fits: break it between characters,
                // but always take at least one.
                var cut = ws;
                while (true) {
                    const nb = text_edit.nextBoundary(s, cut);
                    if (nb == cut or nb > we or !it.fits(s[start..nb])) break;
                    cut = nb;
                }
                if (cut == ws) cut = text_edit.nextBoundary(s, ws);
                end_fit = cut;
            }
            break;
        }
        var line = s[start..end_fit];
        var np = end_fit;
        while (np < para_end and s[np] == ' ') np += 1;
        if (np >= para_end) {
            if (para_end >= s.len) it.done = true else np = para_end + 1;
        }
        it.pos = np;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
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

// ---- tests: wrapping, text field, scrolling ------------------------------

/// One unit of width per code point, scaled by size (size 1 => 1 per char).
fn cpMeasure(_: ?*anyopaque, str: []const u8, size: f32) f32 {
    const n = std.unicode.utf8CountCodepoints(str) catch str.len;
    return @as(f32, @floatFromInt(n)) * size;
}

fn expectLines(ui: *const Ui, str: []const u8, max_w: f32, want: []const []const u8) !void {
    var it = ui.wrapText(str, 1, max_w);
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i >= want.len) return error.TooManyLines;
        try std.testing.expectEqualStrings(want[i], line);
    }
    try std.testing.expectEqual(want.len, i);
}

fn wrapUi(list: *DisplayList) Ui {
    return Ui.initHeadless(list, .{}, .{}, cpMeasure);
}

test "wrapText: greedy word wrap" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const ui = wrapUi(&list);
    try expectLines(&ui, "the quick brown fox", 10, &.{ "the quick", "brown fox" });
    try expectLines(&ui, "the quick brown fox", 9, &.{ "the quick", "brown fox" });
    try expectLines(&ui, "the quick brown fox", 8, &.{ "the", "quick", "brown", "fox" });
    try expectLines(&ui, "the quick brown fox", 100, &.{"the quick brown fox"});
    // Runs of spaces at a break vanish; elsewhere they stay.
    try expectLines(&ui, "aa   bb", 4, &.{ "aa", "bb" });
    try expectLines(&ui, "a  b", 10, &.{"a  b"});
}

test "wrapText: newlines, blank lines, empty input" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const ui = wrapUi(&list);
    try expectLines(&ui, "", 10, &.{});
    try expectLines(&ui, "a\nb", 10, &.{ "a", "b" });
    try expectLines(&ui, "a\n\nb", 10, &.{ "a", "", "b" });
    try expectLines(&ui, "a\n", 10, &.{ "a", "" });
    try expectLines(&ui, "\n", 10, &.{ "", "" });
    try expectLines(&ui, "aa bb\ncc dd", 5, &.{ "aa bb", "cc dd" });
    try expectLines(&ui, "aa bb cc\nx", 5, &.{ "aa bb", "cc", "x" });
    try expectLines(&ui, "a\r\nb", 10, &.{ "a", "b" });
}

test "wrapText: over-long words break between characters" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const ui = wrapUi(&list);
    try expectLines(&ui, "abcdefghij", 4, &.{ "abcd", "efgh", "ij" });
    try expectLines(&ui, "ab abcdefghij cd", 4, &.{ "ab", "abcd", "efgh", "ij", "cd" });
    // A long word after a short one that leaves room: the short one stays alone.
    try expectLines(&ui, "a abcdefgh", 5, &.{ "a", "abcde", "fgh" });
    // Width smaller than a character still makes progress, one char per line.
    try expectLines(&ui, "abc", 0.5, &.{ "a", "b", "c" });
}

test "wrapText: utf8 is never split" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const ui = wrapUi(&list);
    try expectLines(&ui, "ééééé", 2, &.{ "éé", "éé", "é" });
    try expectLines(&ui, "😀😀😀 é", 2, &.{ "😀😀", "😀", "é" });
    try expectLines(&ui, "héllo wörld", 5, &.{ "héllo", "wörld" });
}

test "measureWrapped and labelWrapped agree and cull outside the clip" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ui = wrapUi(&list);
    ui.theme.line_spacing = 2;
    // size 10: width 10 per char, line height 20. "aaa bbb ccc" in 70 -> 2 lines.
    try std.testing.expectEqual(@as(f32, 40), ui.measureWrapped("aaa bbb ccc", 10, 70));
    try std.testing.expectEqual(@as(f32, 0), ui.measureWrapped("", 10, 70));
    const used = ui.labelWrapped(.{ .x = 5, .y = 7, .w = 70, .h = 0 }, "aaa bbb ccc", .{ .size = 10 });
    try std.testing.expectEqual(@as(f32, 40), used);
    var texts: usize = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .text => |tx| {
            texts += 1;
            try std.testing.expectEqual(@as(f32, 5), tx.x);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), texts);

    // Clip showing only the second line: the first is skipped.
    list.reset();
    ui.pushClip(.{ .x = 0, .y = 30, .w = 100, .h = 10 });
    _ = ui.labelWrapped(.{ .x = 5, .y = 7, .w = 70, .h = 0 }, "aaa bbb ccc", .{ .size = 10 });
    ui.popClip();
    texts = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .text => |tx| {
            texts += 1;
            try std.testing.expectEqualStrings("ccc", tx.str);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "clip: hit ignores points outside, pushClip/popClip are recorded and nest" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ui = Ui.initHeadless(&list, .{ .mouse_x = 50, .mouse_y = 50, .pressed = true }, .{}, null);
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expect(ui.hit(r).clicked);
    ui.pushClip(.{ .x = 0, .y = 0, .w = 100, .h = 40 });
    try std.testing.expect(!ui.hit(r).hovered);
    ui.pushClip(.{ .x = 0, .y = 30, .w = 100, .h = 100 }); // intersects to y 30..40
    try std.testing.expectEqual(Rect{ .x = 0, .y = 30, .w = 100, .h = 10 }, ui.clip().?);
    ui.popClip();
    ui.popClip();
    try std.testing.expect(ui.clip() == null);
    try std.testing.expect(ui.hit(r).clicked);
    try std.testing.expectEqual(@as(usize, 4), list.cmds.items.len);
    try std.testing.expect(list.cmds.items[0] == .push_clip and list.cmds.items[3] == .pop_clip);
}

test "input: wheel, mouse up, keys and text queue; endFrame clears them" {
    var in: Input = .{};
    in.feed(.{ .mouse_wheel = .{ .window = 1, .dx = 0, .dy = 1.5 } }, 1);
    in.feed(.{ .mouse_wheel = .{ .window = 1, .dx = 0, .dy = 0.5 } }, 1);
    in.feed(.{ .mouse_wheel = .{ .window = 2, .dx = 0, .dy = 9 } }, 1);
    try std.testing.expectEqual(@as(f32, 2), in.wheel_y);
    in.feed(.{ .mouse_down = .{ .window = 1, .x = 1, .y = 1, .button = 1, .mods = .{ .shift = true } } }, 1);
    try std.testing.expect(in.down and in.pressed and in.mouse_mods.shift);
    in.feed(.{ .mouse_up = .{ .window = 1, .x = 2, .y = 2, .button = 1 } }, 1);
    try std.testing.expect(!in.down and in.released);
    in.feed(.{ .key_down = .{ .code = keys.left, .window = 1 } }, 1);
    in.feed(.{ .key_down = .{ .code = keys.left, .window = 2 } }, 1);
    in.feed(.{ .text_input = .{ .window = 1, .text = backend.TextChunk.from("é") } }, 1);
    try std.testing.expectEqual(@as(usize, 2), in.events().len);
    try std.testing.expectEqualStrings("é", in.events()[1].text.slice());
    in.endFrame();
    try std.testing.expect(!in.released and in.wheel_y == 0 and in.events().len == 0);
}

test "pushText splits long text on character boundaries" {
    var in: Input = .{};
    var s: [80]u8 = undefined;
    for (0..40) |i| @memcpy(s[i * 2 ..][0..2], "é");
    in.pushText(&s);
    var total: usize = 0;
    for (in.events()) |ev| {
        const sl = ev.text.slice();
        try std.testing.expect(std.unicode.utf8ValidateSlice(sl));
        total += sl.len;
    }
    try std.testing.expectEqual(@as(usize, 80), total);
}

var fake_clip: [64]u8 = undefined;
var fake_clip_len: usize = 0;

fn fakeClipGet(gpa: std.mem.Allocator) ?[]u8 {
    if (fake_clip_len == 0) return null;
    return gpa.dupe(u8, fake_clip[0..fake_clip_len]) catch null;
}

fn fakeClipSet(_: std.mem.Allocator, str: []const u8) void {
    @memcpy(fake_clip[0..str.len], str);
    fake_clip_len = str.len;
}

/// Runs one frame of a text field with `in`; returns the result.
fn fieldFrame(list: *DisplayList, state: *State, in: Input, st: *TextFieldState, r: Rect) TextFieldResult {
    list.reset();
    var ui = Ui.initHeadless(list, in, .{}, cpMeasure);
    ui.state = state;
    ui.clipboard = .{ .get = fakeClipGet, .set = fakeClipSet };
    return ui.textField(r, st, .{ .size = 1 });
}

test "textField: click focuses, typing edits, return submits, escape blurs" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextFieldState.init(std.testing.allocator);
    defer st.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 30 };

    // Typing before focus does nothing.
    var in: Input = .{};
    in.pushText("zzz");
    var res = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(!res.changed and st.edit.text().len == 0);

    in = .{ .mouse_x = 50, .mouse_y = 10, .pressed = true, .down = true };
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(state.focus == @as(*const anyopaque, &st));

    in = .{};
    in.pushText("héllo");
    in.pushKey(keys.backspace, .{});
    in.pushText("o");
    res = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(res.changed and !res.submitted);
    try std.testing.expectEqualStrings("héllo", st.edit.text());

    in = .{};
    in.pushKey(keys.@"return", .{});
    res = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(res.submitted and !res.changed);
    try std.testing.expect(state.focus != null);

    in = .{};
    in.pushKey(keys.escape, .{});
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(state.focus == null);
}

test "textField: clicking elsewhere blurs; another field takes focus" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var a = TextFieldState.init(std.testing.allocator);
    defer a.deinit();
    var b = TextFieldState.init(std.testing.allocator);
    defer b.deinit();
    const ra: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 30 };
    const rb: Rect = .{ .x = 0, .y = 40, .w = 100, .h = 30 };
    _ = fieldFrame(&list, &state, .{ .mouse_x = 5, .mouse_y = 5, .pressed = true }, &a, ra);
    try std.testing.expect(state.focus == @as(*const anyopaque, &a));
    _ = fieldFrame(&list, &state, .{ .mouse_x = 5, .mouse_y = 45, .pressed = true }, &a, ra);
    try std.testing.expect(state.focus == null);
    _ = fieldFrame(&list, &state, .{ .mouse_x = 5, .mouse_y = 45, .pressed = true }, &b, rb);
    try std.testing.expect(state.focus == @as(*const anyopaque, &b));
    _ = fieldFrame(&list, &state, .{ .mouse_x = 5, .mouse_y = 5, .pressed = true }, &a, ra);
    try std.testing.expect(state.focus == @as(*const anyopaque, &a));
}

test "textField: click places the caret, shift-click and drag select" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextFieldState.init(std.testing.allocator);
    defer st.deinit();
    try st.edit.setText("abcdef");
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 30 };
    // Text starts at x = 10 (padding); one unit per char at size 1, so
    // x = 10 + n lands on the boundary after n chars; 10.4 rounds down, 10.6 up.
    _ = fieldFrame(&list, &state, .{ .mouse_x = 13.4, .mouse_y = 5, .pressed = true, .down = true }, &st, r);
    try std.testing.expectEqual(@as(usize, 3), st.edit.cursor);
    try std.testing.expect(!st.edit.hasSelection());
    // Drag to 5.
    _ = fieldFrame(&list, &state, .{ .mouse_x = 15.2, .mouse_y = 50, .down = true }, &st, r);
    try std.testing.expectEqual(@as(usize, 5), st.edit.cursor);
    try std.testing.expectEqual(@as(usize, 3), st.edit.anchor);
    // Release ends the drag; later moves do nothing.
    _ = fieldFrame(&list, &state, .{ .mouse_x = 12, .mouse_y = 5, .released = true }, &st, r);
    try std.testing.expect(state.drag == null);
    _ = fieldFrame(&list, &state, .{ .mouse_x = 11, .mouse_y = 5, .down = true }, &st, r);
    try std.testing.expectEqual(@as(usize, 5), st.edit.cursor);
    // Shift-click extends from the anchor.
    _ = fieldFrame(&list, &state, .{ .mouse_x = 10, .mouse_y = 5, .pressed = true, .down = true, .mouse_mods = .{ .shift = true } }, &st, r);
    try std.testing.expectEqual(@as(usize, 0), st.edit.cursor);
    try std.testing.expectEqual(@as(usize, 3), st.edit.anchor);
    // Click past the end.
    _ = fieldFrame(&list, &state, .{ .mouse_x = 190, .mouse_y = 5, .pressed = true }, &st, r);
    try std.testing.expectEqual(@as(usize, 6), st.edit.cursor);
}

test "textField: clipboard shortcuts" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextFieldState.init(std.testing.allocator);
    defer st.deinit();
    try st.edit.setText("héllo");
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 30 };
    state.focusOn(&st);
    var in: Input = .{};
    in.pushKey(keys.a, .{ .cmd = true });
    in.pushKey(keys.c, .{ .cmd = true });
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expectEqualStrings("héllo", fake_clip[0..fake_clip_len]);
    in = .{};
    in.pushKey(keys.x, .{ .cmd = true });
    var res = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(res.changed);
    try std.testing.expectEqualStrings("", st.edit.text());
    in = .{};
    in.pushKey(keys.v, .{ .cmd = true });
    in.pushKey(keys.v, .{ .cmd = true });
    res = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(res.changed);
    try std.testing.expectEqualStrings("héllohéllo", st.edit.text());
}

test "textField: scrolls to keep the caret visible and is clipped" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextFieldState.init(std.testing.allocator);
    defer st.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 50, .h = 30 }; // 30 wide text box
    state.focusOn(&st);
    var in: Input = .{};
    in.pushText("012345678901234567890123456789");
    _ = fieldFrame(&list, &state, in, &st, r);
    // Caret at 30 in a 30-wide box with 2 slack: scrolled by 2.
    try std.testing.expectEqual(@as(f32, 2), st.scroll_x);
    in = .{};
    in.pushKey(keys.home, .{});
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expectEqual(@as(f32, 0), st.scroll_x);
    // The text is drawn between a push_clip and a pop_clip.
    var pushes: usize = 0;
    var pops: usize = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .push_clip => pushes += 1,
        .pop_clip => pops += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), pushes);
    try std.testing.expectEqual(@as(usize, 1), pops);
}

test "textField: selection highlight is drawn only while focused" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextFieldState.init(std.testing.allocator);
    defer st.deinit();
    try st.edit.setText("abcd");
    st.edit.selectAll();
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 30 };
    const theme: Theme = .{};
    _ = fieldFrame(&list, &state, .{}, &st, r);
    var found = false;
    for (list.cmds.items) |cmd| switch (cmd) {
        .rrect => |c| if (std.meta.eql(c.color, theme.selection)) {
            found = true;
        },
        else => {},
    };
    try std.testing.expect(!found);
    state.focusOn(&st);
    _ = fieldFrame(&list, &state, .{}, &st, r);
    for (list.cmds.items) |cmd| switch (cmd) {
        .rrect => |c| if (std.meta.eql(c.color, theme.selection)) {
            found = true;
            try std.testing.expectEqual(@as(f32, 10), c.rect.x);
            try std.testing.expectEqual(@as(f32, 4), c.rect.w);
        },
        else => {},
    };
    try std.testing.expect(found);
}

test "scroll: wheel scrolls when hovered, clamps, content rect follows" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ss: ScrollState = .{};
    const r: Rect = .{ .x = 10, .y = 20, .w = 100, .h = 100 };
    // Wheel away from the user (positive) scrolls up: already at the top.
    var ui = Ui.initHeadless(&list, .{ .mouse_x = 50, .mouse_y = 50, .wheel_y = 3 }, .{}, null);
    var c = ui.beginScroll(r, &ss, 300);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 0), ss.offset);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 100, .h = 300 }, c);
    // Toward the user: scrolls down by lines * step.
    ui = Ui.initHeadless(&list, .{ .mouse_x = 50, .mouse_y = 50, .wheel_y = -2 }, .{}, null);
    c = ui.beginScroll(r, &ss, 300);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 48), ss.offset);
    try std.testing.expectEqual(@as(f32, -28), c.y);
    // Clamped to content_h - r.h.
    ui = Ui.initHeadless(&list, .{ .mouse_x = 50, .mouse_y = 50, .wheel_y = -100 }, .{}, null);
    _ = ui.beginScroll(r, &ss, 300);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 200), ss.offset);
    // Pointer elsewhere: wheel ignored.
    ss.offset = 10;
    ui = Ui.initHeadless(&list, .{ .mouse_x = 500, .mouse_y = 50, .wheel_y = -2 }, .{}, null);
    _ = ui.beginScroll(r, &ss, 300);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 10), ss.offset);
    // Content shrinks: offset is pulled back; no overflow means no scrollbar.
    list.reset();
    ui = Ui.initHeadless(&list, .{}, .{}, null);
    _ = ui.beginScroll(r, &ss, 60);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 0), ss.offset);
    try std.testing.expectEqual(@as(usize, 2), list.cmds.items.len); // push_clip, pop_clip
}

test "scroll: thumb is drawn at the right edge and tracks the offset; children are clipped for hits" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ss: ScrollState = .{ .offset = 100 };
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    // Click at y=150 is outside the viewport but inside a child rect that
    // overflows it.
    var ui = Ui.initHeadless(&list, .{ .mouse_x = 50, .mouse_y = 150, .pressed = true }, .{}, null);
    const content = ui.beginScroll(r, &ss, 300);
    const child: Rect = .{ .x = 0, .y = content.y + 200, .w = 100, .h = 100 }; // y 100..200 on screen
    try std.testing.expect(!ui.hit(child).clicked);
    ui.endScroll();
    try std.testing.expect(ui.hit(child).clicked); // outside the scroll area the clip is gone
    const last = list.cmds.items[list.cmds.items.len - 1].rrect;
    try std.testing.expectEqual(@as(f32, 94), last.rect.x);
    // track 92, thumb 92*100/300 = 30.67; offset 100 of max 200 => halfway.
    try std.testing.expectApproxEqAbs(@as(f32, 4.0 + (92.0 - 30.666666) / 2.0), last.rect.y, 0.01);
}

test "scroll area: arrow and page keys" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var st: ScrollState = .{ .key_scroll = true };
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    var in: Input = .{};
    in.pushKey(keys.down, .{});
    var ui = Ui.initHeadless(&list, in, .{}, null);
    _ = ui.beginScroll(r, &st, 1000);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 48), st.offset);

    in = .{};
    in.pushKey(keys.page_down, .{});
    in.pushKey(keys.end, .{});
    ui = Ui.initHeadless(&list, in, .{}, null);
    _ = ui.beginScroll(r, &st, 1000);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 900), st.offset);

    // Arrows belong to a focused text field; Page Up still scrolls.
    var state: State = .{ .focus = @ptrCast(&st) };
    in = .{};
    in.pushKey(keys.up, .{});
    in.pushKey(keys.page_up, .{});
    ui = Ui.initHeadless(&list, in, .{}, null);
    ui.state = &state;
    _ = ui.beginScroll(r, &st, 1000);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 810), st.offset);
}
