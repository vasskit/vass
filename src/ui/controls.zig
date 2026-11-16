//! Small form controls: checkbox, toggle (switch), radio button, segmented
//! control. They are `Ui` methods (see `Ui.checkbox` and friends); this file
//! holds the option types and the implementations, so `ui.zig` stays readable.
//!
//! Like every widget they are immediate mode: the value lives in the app, the
//! widget draws it and reports the click from the same rectangle. `checkbox`
//! and `toggle` flip the bool they are given; `radio` only reports, because
//! which radio of a group is selected is the app's business.
const std = @import("std");
const geom = @import("../core/geom.zig");
const icons = @import("icons.zig");
const keys = @import("../core/keys.zig");
const ui_mod = @import("ui.zig");
const focus = @import("focus.zig");
const Rect = geom.Rect;
const Color = geom.Color;
const Ui = ui_mod.Ui;
const Interaction = ui_mod.Interaction;

pub const CheckOpts = struct {
    /// Dimmed, no hover, and never reports a click or flips the value.
    disabled: bool = false,
    /// Label size; defaults to the theme's body size.
    size: ?f32 = null,
    /// Side of the box (or diameter of a radio) in points.
    box: f32 = 16,
    /// Focus id key (`idKey(x)`). Checkbox: default is the address of the value. Radio: default
    /// is derived from the label.
    id: ?u64 = null,
};

pub const ToggleOpts = struct {
    disabled: bool = false,
    /// Size of the pill. It is centred in the rectangle (and shrunk to fit it).
    width: f32 = 34,
    height: f32 = 20,
    /// Focus id key (`idKey(x)`); default: the address of the value.
    id: ?u64 = null,
    /// Name for assistive technology.
    label: []const u8 = "",
};

pub const Segment = struct {
    /// Drawn left of the label (or alone); null for none.
    icon: ?icons.Source = null,
    /// Text; empty for an icon-only segment.
    label: []const u8 = "",
};

pub const SegmentedOpts = struct {
    /// Dimmed, no hover, and never changes the selection.
    disabled: bool = false,
    /// Label size; defaults to the theme's button size.
    size: ?f32 = null,
    icon_size: f32 = 14,
    /// All segments the same width. If false each is as wide as its content,
    /// with the spare width shared out equally.
    equal_width: bool = true,
    /// Focus id key (`idKey(x)`); default: the address of the selected index.
    id: ?u64 = null,
};

/// Most segments `segmented` lays out (more are ignored).
pub const max_segments = 16;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(lerp(@floatFromInt(a), @floatFromInt(b), t)), 0, 255));
}

/// Linear blend of two colours, `t` in 0..1 (0 is `a`).
pub fn mix(a: Color, b: Color, t: f32) Color {
    return .{ .r = lerpU8(a.r, b.r, t), .g = lerpU8(a.g, b.g, t), .b = lerpU8(a.b, b.b, t), .a = lerpU8(a.a, b.a, t) };
}

/// `c` faded for a disabled control.
fn faded(c: Color) Color {
    return c.alpha(@intCast(@as(u16, c.a) * 90 / 255));
}

/// The interaction of `r` with a disabled control never hovered or clicked.
fn interact(ui: *const Ui, r: Rect, disabled: bool) Interaction {
    if (disabled) return .{ .hovered = false, .clicked = false };
    return ui.hit(r);
}

/// Vertically centres a line of `size` text in `r`; a font's line box is about
/// 1.22 times its size.
fn textY(r: Rect, size: f32) f32 {
    return r.y + @round((r.h - size * 1.22) / 2);
}

/// A box with a check mark when `value`, and `label` to its right. The whole
/// of `r` is the click target. Returns the interaction; `clicked` means the
/// value was just flipped.
pub fn checkbox(ui: *Ui, r: Rect, value: *bool, label: []const u8, opts: CheckOpts) Interaction {
    const t = ui.theme;
    var hv = interact(ui, r, opts.disabled);
    const fid = if (opts.id) |e| ui.widgetId(8, 0, e) else focus.idOfPtr(value);
    const f = ui.focusable(fid, r, .{ .role = .checkbox, .label = label, .disabled = opts.disabled, .ring = false });
    if (f.activated) hv.clicked = true;
    if (hv.clicked) value.* = !value.*;
    const on = value.*;
    const b = opts.box;
    const box: Rect = .{ .x = r.x, .y = r.y + @round((r.h - b) / 2), .w = b, .h = b };
    const rad = @round(b / 4);

    if (on) {
        var fill = t.accent;
        if (hv.hovered) fill = mix(fill, t.text, 0.12);
        ui.list.rrect(box, rad, if (opts.disabled) faded(fill) else fill);
        const k = b / 16;
        const mark = [_][2]f32{
            .{ box.x + 4 * k, box.y + 8.4 * k },
            .{ box.x + 7 * k, box.y + 11.2 * k },
            .{ box.x + 12 * k, box.y + 5.2 * k },
        };
        ui.list.polyline(&mark, 1.8 * k, if (opts.disabled) faded(t.accent_text) else t.accent_text, false);
    } else {
        const border = if (opts.disabled) faded(t.dim) else if (hv.hovered) t.dim else t.dim.alpha(130);
        ui.list.rrect(box, rad, border);
        ui.list.rrect(box.inset(1.5), @max(0, rad - 1.5), t.card);
    }

    const size = opts.size orelse t.font_body;
    const col = if (opts.disabled) faded(t.text) else t.text;
    ui.labelAt(box.x + b + 8, textY(r, size), label, .{ .size = size, .color = col });
    if (f.visible) ui.focusRing(tightRow(ui, r, b, label, size), rad, 2);
    return hv;
}

/// The part of a checkbox or radio row that holds something: the box and its label.
fn tightRow(ui: *const Ui, r: Rect, box: f32, label: []const u8, size: f32) Rect {
    const w = @min(r.w, box + 8 + ui.measure(label, size));
    const h = @min(r.h, @max(box, size * 1.22) + 4);
    return .{ .x = r.x, .y = r.y + (r.h - h) / 2, .w = w, .h = h };
}

/// Draws a switch with the knob at `pos` (0 = off, 1 = on, anything between
/// is a blend), centred in `r`. Draws only; `toggle` is this plus the click.
/// Animate by feeding it a position that eases towards 0 or 1 across frames.
pub fn toggleAt(ui: *Ui, r: Rect, pos: f32, hovered: bool, opts: ToggleOpts) void {
    const t = ui.theme;
    const p = std.math.clamp(pos, 0, 1);
    const w = @min(opts.width, r.w);
    const h = @min(opts.height, r.h);
    const pill = r.center(w, h);
    var track = mix(t.track, t.accent, p);
    if (hovered) track = mix(track, t.text, 0.08);
    var knob = mix(t.dim, t.text, p);
    if (hovered) knob = mix(knob, t.text, 0.3);
    if (opts.disabled) {
        track = faded(track);
        knob = faded(knob);
    }
    ui.list.rrect(pill, h / 2, track);
    const rad = (h - 4) / 2;
    const cx = lerp(pill.x + 2 + rad, pill.x + pill.w - 2 - rad, p);
    ui.list.circle(cx, pill.y + h / 2, rad, knob);
}

/// A pill-shaped switch, accent coloured when on. `r` is the click target; the
/// pill is centred in it. Returns the interaction; `clicked` means the value
/// was just flipped.
pub fn toggle(ui: *Ui, r: Rect, value: *bool, opts: ToggleOpts) Interaction {
    var hv = interact(ui, r, opts.disabled);
    const fid = if (opts.id) |e| ui.widgetId(9, 0, e) else focus.idOfPtr(value);
    const f = ui.focusable(fid, r, .{ .role = .toggle, .label = opts.label, .disabled = opts.disabled, .ring = false });
    if (f.activated) hv.clicked = true;
    if (hv.clicked) value.* = !value.*;
    toggleAt(ui, r, if (value.*) 1 else 0, hv.hovered, opts);
    if (f.visible) {
        const pill = r.center(@min(opts.width, r.w), @min(opts.height, r.h));
        ui.focusRing(pill, pill.h / 2, 2);
    }
    return hv;
}

/// A round radio button with `label` to its right; the whole of `r` is the
/// click target. Does not change anything itself: set your own value when
/// `clicked`.
pub fn radio(ui: *Ui, r: Rect, selected: bool, label: []const u8, opts: CheckOpts) Interaction {
    const t = ui.theme;
    var hv = interact(ui, r, opts.disabled);
    const f = ui.focusable(ui.widgetId(6, focus.idKey(label), opts.id), r, .{ .role = .radio, .label = label, .disabled = opts.disabled, .ring = false });
    if (f.activated) hv.clicked = true;
    const d = opts.box;
    const cx = r.x + d / 2;
    const cy = r.y + r.h / 2;
    if (selected) {
        var fill = t.accent;
        if (hv.hovered) fill = mix(fill, t.text, 0.12);
        ui.list.circle(cx, cy, d / 2, if (opts.disabled) faded(fill) else fill);
        ui.list.circle(cx, cy, d / 2 - 4.2, if (opts.disabled) faded(t.accent_text) else t.accent_text);
    } else {
        const border = if (opts.disabled) faded(t.dim) else if (hv.hovered) t.dim else t.dim.alpha(130);
        ui.list.circle(cx, cy, d / 2, border);
        ui.list.circle(cx, cy, d / 2 - 1.5, t.card);
    }
    const size = opts.size orelse t.font_body;
    const col = if (opts.disabled) faded(t.text) else t.text;
    ui.labelAt(r.x + d + 8, textY(r, size), label, .{ .size = size, .color = col });
    if (f.visible) {
        const row = tightRow(ui, r, d, label, size);
        ui.focusRing(row, row.h / 2, 2);
    }
    return hv;
}

/// One segment's content width: icon, gap and label.
fn segmentContentW(ui: *const Ui, s: Segment, size: f32, opts: SegmentedOpts) f32 {
    var w: f32 = 0;
    if (s.icon != null) w += opts.icon_size;
    if (s.label.len > 0) {
        if (s.icon != null) w += 5;
        w += ui.measureWeighted(s.label, size, .medium);
    }
    return w;
}

/// Rectangle of segment `i` in a `segmented` control drawn in `r`. Pure: the
/// same layout `segmented` uses, for hit tests and tests.
pub fn segmentRect(ui: *const Ui, r: Rect, items: []const Segment, i: usize, opts: SegmentedOpts) Rect {
    const n = @min(items.len, max_segments);
    const inner = r.inset(2);
    if (opts.equal_width or n == 0) return inner.column(@max(n, 1), 0, i);
    const size = opts.size orelse ui.theme.font_button;
    const pad: f32 = 12;
    var total: f32 = 0;
    for (items[0..n]) |s| total += segmentContentW(ui, s, size, opts) + 2 * pad;
    const extra = (inner.w - total) / @as(f32, @floatFromInt(n));
    var x = inner.x;
    for (items[0..n], 0..) |s, k| {
        const w = segmentContentW(ui, s, size, opts) + 2 * pad + extra;
        if (k == i) return .{ .x = x, .y = inner.y, .w = w, .h = inner.h };
        x += w;
    }
    return inner;
}

/// A joined control in one rounded container; the selected segment is raised.
/// Clicking a segment stores its index in `selected`. Returns true when that
/// changed the selection. Segments share `r` equally unless
/// `opts.equal_width` is false.
pub fn segmented(ui: *Ui, r: Rect, items: []const Segment, selected: *usize, opts: SegmentedOpts) bool {
    const t = ui.theme;
    const n = @min(items.len, max_segments);
    const rad = @min(@as(f32, 8), r.h / 2);
    const size = opts.size orelse t.font_button;
    ui.list.rrect(r, rad, if (opts.disabled) faded(t.card) else t.card);
    var changed = false;
    // One Tab stop for the whole control; Left / Right / Home / End change the selection.
    const fid = if (opts.id) |e| ui.widgetId(10, 0, e) else focus.idOfPtr(selected);
    const f = ui.focusable(fid, r, .{ .role = .tab, .disabled = opts.disabled, .activate = false, .ring = false });
    if (f.focused and n > 0) {
        while (ui.takeKey(&.{ keys.left, keys.right, keys.home, keys.end })) |k| {
            const nxt = ui_mod.stepSelection(selected.*, n, k.code);
            if (nxt != selected.*) {
                selected.* = nxt;
                changed = true;
            }
        }
    }
    const current = selected.*;
    defer if (f.visible) ui.focusRing(r, rad, 2);
    for (items[0..n], 0..) |s, i| {
        const seg = segmentRect(ui, r, items, i, opts);
        const hv = interact(ui, seg, opts.disabled);
        const sel = i == current;
        if (sel) {
            const fill = if (opts.disabled) faded(t.track) else t.track;
            ui.list.rrect(seg, @max(0, rad - 2), fill);
        } else if (hv.hovered) {
            ui.list.rrect(seg, @max(0, rad - 2), t.text.alpha(12));
        }
        // A hairline between two neighbours that are both flat.
        if (i + 1 < n and !sel and i + 1 != current) {
            ui.list.rect(.{ .x = seg.x + seg.w - 0.5, .y = seg.y + seg.h * 0.25, .w = 1, .h = seg.h * 0.5 }, t.text.alpha(if (opts.disabled) 8 else 22));
        }
        var col = if (sel) t.text else if (hv.hovered) mix(t.dim, t.text, 0.5) else t.dim;
        if (opts.disabled) col = faded(col);
        const cw = segmentContentW(ui, s, size, opts);
        var x = seg.x + (seg.w - cw) / 2;
        if (s.icon) |ic| {
            icons.drawSource(ui.list, ic, .{ .x = x, .y = seg.y + (seg.h - opts.icon_size) / 2, .w = opts.icon_size, .h = opts.icon_size }, col, 1);
            x += opts.icon_size + 5;
        }
        if (s.label.len > 0) ui.list.textWeighted(x, textY(seg, size), size, col, .left, .medium, s.label);
        if (hv.clicked and i != current) {
            selected.* = i;
            changed = true;
        }
    }
    return changed;
}

// ---- slider -------------------------------------------------------------------------

pub const SliderOpts = struct {
    min: f32 = 0,
    max: f32 = 1,
    /// Values snap to multiples of `step` from `min`; 0 is continuous. Also the arrow-key
    /// increment (a continuous slider moves by a twentieth of its range).
    step: f32 = 0,
    /// Dimmed, no hover, no input.
    disabled: bool = false,
    /// Thickness of the track and diameter of the thumb.
    track: f32 = 4,
    thumb: f32 = 16,
    /// Focus id key (`idKey(x)`); default: the address of the value.
    id: ?u64 = null,
};

pub const SliderResult = struct {
    hovered: bool = false,
    /// The thumb is being dragged (the button is down on it).
    dragging: bool = false,
    /// `value` changed this frame (click, drag or key).
    changed: bool = false,
    /// The button was let go this frame at the end of a drag: commit the value now.
    released: bool = false,
    /// Has keyboard focus (arrow keys, Home and End work).
    focused: bool = false,
};

/// Position of `value` in the range as 0..1 (0 for an empty range or a NaN).
pub fn sliderFrac(value: f32, min: f32, max: f32) f32 {
    if (!(max > min) or !std.math.isFinite(value)) return 0;
    return std.math.clamp((value - min) / (max - min), 0, 1);
}

/// The value at position `frac` (0..1), snapped to `step` from `min` when step > 0.
pub fn sliderValue(frac: f32, min: f32, max: f32, step: f32) f32 {
    if (!(max > min)) return min;
    var v = min + std.math.clamp(frac, 0, 1) * (max - min);
    if (step > 0) v = min + @round((v - min) / step) * step;
    return std.math.clamp(v, min, max);
}

/// A horizontal slider: a track filled up to a round thumb. Click anywhere on it to jump
/// there, drag the thumb, or (once clicked, so it has focus) use Left/Right and Down/Up for
/// one step, Home and End for the ends. `r` is the whole hit area; the track is centred in
/// it and the thumb stays inside it. Writes the new value to `value` and reports it.
/// Dragging and focus need `ui.state`; without one a click still jumps.
pub fn slider(ui: *Ui, r: Rect, value: *f32, opts: SliderOpts) SliderResult {
    const t = ui.theme;
    const in = &ui.input;
    const id: *const anyopaque = value;
    const half = opts.thumb / 2;
    const span = @max(r.w - opts.thumb, 1);
    var res: SliderResult = .{};
    const hv = interact(ui, r, opts.disabled);
    res.hovered = hv.hovered;
    const before = value.*;
    const fracAt = struct {
        fn f(x: f32, left: f32, w: f32) f32 {
            return (x - left) / w;
        }
    }.f;

    const fid = if (opts.id) |e| ui.widgetId(11, 0, e) else focus.idOfPtr(value);
    const fr = ui.focusable(fid, r, .{ .role = .slider, .disabled = opts.disabled, .activate = false, .ring = false });
    var ring = false;
    if (!opts.disabled) {
        if (ui.state) |s| {
            if (hv.clicked) {
                s.drag = id;
                s.select = null;
            }
            if (s.drag == id) {
                if (in.down or hv.clicked) {
                    value.* = sliderValue(fracAt(in.mouse_x, r.x + half, span), opts.min, opts.max, opts.step);
                    res.dragging = true;
                } else {
                    s.drag = null;
                    res.released = true;
                }
            }
            res.focused = s.focus == focus.ptrOfId(fid);
            if (res.focused) {
                const inc = if (opts.step > 0) opts.step else (opts.max - opts.min) / 20;
                while (ui.takeKey(&.{ keys.left, keys.right, keys.up, keys.down, keys.home, keys.end })) |k| {
                    var v = value.*;
                    const mult: f32 = if (k.mods.shift) 5 else 1;
                    switch (k.code) {
                        keys.left, keys.down => v -= inc * mult,
                        keys.right, keys.up => v += inc * mult,
                        keys.home => v = opts.min,
                        else => v = opts.max,
                    }
                    value.* = sliderValue(sliderFrac(v, opts.min, opts.max), opts.min, opts.max, opts.step);
                }
            }
            ring = fr.visible or (ui.focusVisible() and res.focused);
        } else if (hv.clicked) {
            value.* = sliderValue(fracAt(in.mouse_x, r.x + half, span), opts.min, opts.max, opts.step);
        }
    }
    res.changed = value.* != before;

    // Drawing.
    const p = sliderFrac(value.*, opts.min, opts.max);
    const active = res.dragging or res.hovered;
    const trk = opts.track;
    const track: Rect = .{ .x = r.x + half, .y = r.y + @round((r.h - trk) / 2), .w = span, .h = trk };
    const cx = track.x + span * p;
    const cy = r.y + r.h / 2;
    var bg = t.track;
    var fill = t.accent;
    var knob = mix(t.text, t.dim, 0.1);
    if (active) knob = t.text;
    if (opts.disabled) {
        bg = faded(bg);
        fill = faded(fill);
        knob = faded(knob);
    }
    ui.list.rrect(.{ .x = r.x + half - trk / 2, .y = track.y, .w = span + trk, .h = trk }, trk / 2, bg);
    ui.list.rrect(.{ .x = r.x + half - trk / 2, .y = track.y, .w = span * p + trk, .h = trk }, trk / 2, fill);
    if (res.focused and !opts.disabled and !ring) ui.list.circle(cx, cy, half + 3, t.accent.alpha(70));
    ui.list.circle(cx, cy, if (res.dragging) half + 1 else half, knob);
    if (ring and res.focused and !opts.disabled) ui.focusRing(.{ .x = cx - half, .y = cy - half, .w = 2 * half, .h = 2 * half }, half, 2);
    return res;
}

// ---- waveform -----------------------------------------------------------------------

pub const WaveformOpts = struct {
    /// 0..1 how far playback is; bars before it use `played_color`. Null: none played.
    progress: ?f32 = null,
    /// Bars not yet played. Default: the theme's dim colour.
    color: ?Color = null,
    /// Bars already played. Default: the theme's accent.
    played_color: ?Color = null,
    bar_width: f32 = 3,
    gap: f32 = 2,
    /// Shortest a bar is drawn, so silence still reads as a line of dots.
    min_bar: f32 = 2,
    /// Dimmed, and clicks are ignored.
    disabled: bool = false,
    /// Draw only: no hover, click or drag tracking, and no dimming (a level history, a
    /// thumbnail of a clip).
    passive: bool = false,
    /// Identifies this waveform for drag tracking. Default: the address of the peaks, so
    /// two waveforms drawn from the same slice need different ids.
    id: ?*const anyopaque = null,
};

pub const WaveformResult = struct {
    hovered: bool = false,
    /// The button went down on the waveform this frame.
    clicked: bool = false,
    /// A drag that began on the waveform is going on (also true on the click frame).
    dragging: bool = false,
    /// The button was let go this frame at the end of a drag.
    released: bool = false,
    /// While clicking or dragging: where along the waveform the pointer is, 0..1 (clamped
    /// to the ends, also when the pointer has left sideways). Seek there.
    seek: ?f32 = null,
};

/// How many bars fit `w` points.
pub fn waveformBars(w: f32, bar_width: f32, gap: f32) usize {
    if (w <= 0 or bar_width <= 0) return 0;
    const n = @floor((w + gap) / (bar_width + gap));
    return if (n < 1) 0 else @intFromFloat(n);
}

/// Peak for bar `i` of `bars`: the largest of the peaks that bar covers (a bar always
/// covers at least one), 0 if there are none.
pub fn waveformPeak(peaks: []const f32, i: usize, bars: usize) f32 {
    if (peaks.len == 0 or bars == 0) return 0;
    const a = i * peaks.len / bars;
    const b = @min(peaks.len, @max(a + 1, (i + 1) * peaks.len / bars));
    var m: f32 = 0;
    for (peaks[a..b]) |v| m = @max(m, if (std.math.isFinite(v)) v else 0);
    return std.math.clamp(m, 0, 1);
}

/// Draws `peaks` (0..1 each, e.g. from `audio.peaks`) as centred vertical bars filling `r`,
/// the played part in another colour, and turns clicks and drags into a position to seek
/// to. Reduces or stretches the peaks to the number of bars that fit.
pub fn waveform(ui: *Ui, r: Rect, peaks: []const f32, opts: WaveformOpts) WaveformResult {
    const t = ui.theme;
    const in = &ui.input;
    var res: WaveformResult = .{};
    const hv = interact(ui, r, opts.disabled or opts.passive);
    res.hovered = hv.hovered;
    const id: *const anyopaque = opts.id orelse @ptrCast(peaks.ptr);
    // Focusable like a slider: Left / Right seek by 5% (Shift: 20%), Home / End to the ends.
    var ring_vis = false;
    defer if (ring_vis) ui.focusRing(r, @min(4, r.h / 2), 2);
    if (!opts.disabled and !opts.passive and r.w > 0) {
        const f = ui.focusable(focus.idOfPtr(id), r, .{ .role = .slider, .label = "", .activate = false, .ring = false });
        ring_vis = f.visible;
        if (f.focused) {
            const at = opts.progress orelse 0;
            while (ui.takeKey(&.{ keys.left, keys.right, keys.home, keys.end })) |k| {
                const step: f32 = if (k.mods.shift) 0.2 else 0.05;
                res.seek = std.math.clamp(switch (k.code) {
                    keys.left => (res.seek orelse at) - step,
                    keys.right => (res.seek orelse at) + step,
                    keys.home => 0,
                    else => 1,
                }, 0, 1);
            }
        }
    }
    if (!opts.disabled and !opts.passive and r.w > 0) {
        const at = std.math.clamp((in.mouse_x - r.x) / r.w, 0, 1);
        if (ui.state) |s| {
            if (hv.clicked) {
                s.drag = id;
                res.clicked = true;
            }
            if (s.drag == id) {
                if (in.down or hv.clicked) {
                    res.dragging = true;
                    res.seek = at;
                } else {
                    s.drag = null;
                    res.released = true;
                }
            }
        } else if (hv.clicked) {
            res.clicked = true;
            res.seek = at;
        }
    }

    const bars = waveformBars(r.w, opts.bar_width, opts.gap);
    if (bars == 0) return res;
    const used = @as(f32, @floatFromInt(bars)) * (opts.bar_width + opts.gap) - opts.gap;
    const x0 = r.x + (r.w - used) / 2;
    const mid = r.y + r.h / 2;
    const prog = if (opts.progress) |p| std.math.clamp(if (std.math.isFinite(p)) p else 0, 0, 1) else 0;
    var base = opts.color orelse t.dim.alpha(150);
    var played = opts.played_color orelse t.accent;
    if (opts.disabled) {
        base = faded(base);
        played = faded(played);
    }
    for (0..bars) |i| {
        const x = x0 + @as(f32, @floatFromInt(i)) * (opts.bar_width + opts.gap);
        const h = std.math.clamp(@max(opts.min_bar, waveformPeak(peaks, i, bars) * r.h), opts.min_bar, @max(r.h, opts.min_bar));
        const centre = (x + opts.bar_width / 2 - r.x) / r.w;
        const col = if (opts.progress != null and centre <= prog) played else base;
        ui.list.rrect(.{ .x = x, .y = mid - h / 2, .w = opts.bar_width, .h = h }, @min(opts.bar_width / 2, h / 2), col);
    }
    return res;
}

// ---- tests ------------------------------------------------------------------------

const DisplayList = @import("../core/gfx.zig").DisplayList;

fn fakeMeasure(_: ?*anyopaque, str: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(str.len)) * size / 2;
}

fn clickUi(list: *DisplayList, x: f32, y: f32, pressed: bool) Ui {
    return Ui.initHeadless(list, .{ .mouse_x = x, .mouse_y = y, .pressed = pressed }, .{}, fakeMeasure);
}

test "checkbox flips on a click anywhere in the row, and draws a mark only when on" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 10, .y = 10, .w = 200, .h = 24 };
    var v = false;
    // Hover only: no flip.
    var ui = clickUi(&list, 150, 20, false);
    var res = ui.checkbox(r, &v, "Label", .{});
    try std.testing.expect(res.hovered and !res.clicked and !v);
    // Click on the label side (not on the box).
    ui = clickUi(&list, 150, 20, true);
    res = ui.checkbox(r, &v, "Label", .{});
    try std.testing.expect(res.clicked and v);
    var lines: usize = 0;
    for (list.cmds.items) |cmd| if (cmd == .line) {
        lines += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), lines); // the two strokes of the check mark
    // Click outside: unchanged. Click again: off, no mark.
    ui = clickUi(&list, 300, 20, true);
    _ = ui.checkbox(r, &v, "Label", .{});
    try std.testing.expect(v);
    list.reset();
    ui = clickUi(&list, 15, 20, true);
    _ = ui.checkbox(r, &v, "Label", .{});
    try std.testing.expect(!v);
    for (list.cmds.items) |cmd| try std.testing.expect(cmd != .line);
}

test "disabled controls never flip, hover or report" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 24 };
    var v = false;
    var ui = clickUi(&list, 5, 5, true);
    var res = ui.checkbox(r, &v, "x", .{ .disabled = true });
    try std.testing.expect(!res.hovered and !res.clicked and !v);
    res = ui.toggle(r, &v, .{ .disabled = true });
    try std.testing.expect(!res.hovered and !res.clicked and !v);
    res = ui.radio(r, false, "x", .{ .disabled = true });
    try std.testing.expect(!res.clicked);
    var sel: usize = 0;
    try std.testing.expect(!ui.segmented(r, &.{ .{ .label = "a" }, .{ .label = "b" } }, &sel, .{ .disabled = true }));
}

test "toggle flips and moves the knob from one end to the other" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 34, .h = 20 };
    var v = false;
    var ui = clickUi(&list, 5, 5, true);
    const res = ui.toggle(r, &v, .{});
    try std.testing.expect(res.clicked and v);
    // On: knob at the right end.
    var knob = list.cmds.items[list.cmds.items.len - 1].ellipse;
    try std.testing.expectEqual(@as(f32, 34 - 2 - 8), knob.cx);
    try std.testing.expectEqual(@as(f32, 8), knob.rx);
    // Off: left end.
    list.reset();
    ui = clickUi(&list, 500, 5, false);
    _ = ui.toggle(r, &v, .{});
    v = false;
    list.reset();
    _ = ui.toggle(r, &v, .{});
    knob = list.cmds.items[list.cmds.items.len - 1].ellipse;
    try std.testing.expectEqual(@as(f32, 10), knob.cx);
    // An in-between position lands in between, with a blended track colour.
    list.reset();
    toggleAt(&ui, r, 0.5, false, .{});
    knob = list.cmds.items[list.cmds.items.len - 1].ellipse;
    try std.testing.expectEqual(@as(f32, 17), knob.cx);
    const track = list.cmds.items[0].rrect.color;
    try std.testing.expect(track.r > ui.theme.track.r and track.r < ui.theme.accent.r);
}

test "radio reports the click and leaves the value to the caller" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 120, .h = 24 };
    var ui = clickUi(&list, 60, 10, true);
    try std.testing.expect(ui.radio(r, false, "Opt", .{}).clicked);
    list.reset();
    var off = clickUi(&list, 60, 10, false);
    try std.testing.expect(!off.radio(r, true, "Opt", .{}).clicked);
    // Both states draw a ring and an inner disc.
    var n_sel: usize = 0;
    for (list.cmds.items) |cmd| if (cmd == .ellipse) {
        n_sel += 1;
    };
    list.reset();
    _ = off.radio(r, false, "Opt", .{});
    var n_off: usize = 0;
    for (list.cmds.items) |cmd| if (cmd == .ellipse) {
        n_off += 1;
    };
    try std.testing.expectEqual(n_off, n_sel);
}

test "segmented: selection follows the clicked segment, only reports changes" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const items = [_]Segment{ .{ .label = "One" }, .{ .icon = .search }, .{ .icon = .plus, .label = "Three" } };
    const r: Rect = .{ .x = 0, .y = 0, .w = 304, .h = 28 }; // inner 300 wide: 100 per segment
    var sel: usize = 0;
    var ui = clickUi(&list, 150, 14, true);
    try std.testing.expect(ui.segmented(r, &items, &sel, .{}));
    try std.testing.expectEqual(@as(usize, 1), sel);
    // Clicking the selected one changes nothing.
    try std.testing.expect(!ui.segmented(r, &items, &sel, .{}));
    ui = clickUi(&list, 250, 14, true);
    try std.testing.expect(ui.segmented(r, &items, &sel, .{}));
    try std.testing.expectEqual(@as(usize, 2), sel);
    // The padding ring is not a segment.
    ui = clickUi(&list, 1, 14, true);
    try std.testing.expect(!ui.segmented(r, &items, &sel, .{}));
    try std.testing.expectEqual(@as(usize, 2), sel);
    // Equal widths by default.
    try std.testing.expectEqual(@as(f32, 100), segmentRect(&ui, r, &items, 1, .{}).w);
    // Content widths: the label-less icon segment is narrower than the others.
    const w0 = segmentRect(&ui, r, &items, 0, .{ .equal_width = false }).w;
    const w1 = segmentRect(&ui, r, &items, 1, .{ .equal_width = false }).w;
    const w2 = segmentRect(&ui, r, &items, 2, .{ .equal_width = false }).w;
    try std.testing.expect(w1 < w0 and w0 < w2);
    try std.testing.expectApproxEqAbs(@as(f32, 300), w0 + w1 + w2, 0.01);
}

test "segmented raises the selected segment" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ui = clickUi(&list, -1, -1, false);
    var sel: usize = 1;
    _ = ui.segmented(.{ .x = 0, .y = 0, .w = 204, .h = 28 }, &.{ .{ .label = "A" }, .{ .label = "B" } }, &sel, .{});
    // The raised segment is the one rounded rect of the track colour (inner 200 wide: second half).
    var found = false;
    for (list.cmds.items) |cmd| switch (cmd) {
        .rrect => |c| if (std.meta.eql(c.color, ui.theme.track)) {
            found = true;
            try std.testing.expectEqual(@as(f32, 102), c.rect.x);
            try std.testing.expectEqual(@as(f32, 100), c.rect.w);
        },
        else => {},
    };
    try std.testing.expect(found);
}

fn dragUi(list: *DisplayList, st: *ui_mod.State, x: f32, pressed: bool, down: bool) Ui {
    var ui = Ui.initHeadless(list, .{ .mouse_x = x, .mouse_y = 10, .pressed = pressed, .down = down }, .{}, fakeMeasure);
    ui.state = st;
    return ui;
}

test "slider math: fraction, value, snapping, degenerate ranges" {
    try std.testing.expectEqual(@as(f32, 0.25), sliderFrac(2.5, 0, 10));
    try std.testing.expectEqual(@as(f32, 0), sliderFrac(-5, 0, 10));
    try std.testing.expectEqual(@as(f32, 1), sliderFrac(50, 0, 10));
    try std.testing.expectEqual(@as(f32, 0), sliderFrac(5, 3, 3));
    try std.testing.expectEqual(@as(f32, 0), sliderFrac(std.math.nan(f32), 0, 1));
    try std.testing.expectEqual(@as(f32, 7.5), sliderValue(0.75, 0, 10, 0));
    try std.testing.expectEqual(@as(f32, 8), sliderValue(0.77, 0, 10, 2)); // 7.7 snaps to 8
    try std.testing.expectEqual(@as(f32, 9), sliderValue(2, 0, 10, 3)); // clamped, then on the step grid
    try std.testing.expectEqual(@as(f32, 0), sliderValue(-1, 0, 10, 0));
    try std.testing.expectEqual(@as(f32, 3), sliderValue(0.5, 3, 3, 1));
}

test "slider: click jumps, drag follows past the ends, release reports" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var st: ui_mod.State = .{};
    var v: f32 = 0;
    // 116 wide with a 16 thumb: the thumb centre travels x = 8 .. 108.
    const r: Rect = .{ .x = 0, .y = 0, .w = 116, .h = 24 };
    var ui = dragUi(&list, &st, 58, true, true);
    var res = ui.slider(r, &v, .{ .min = 0, .max = 100 });
    try std.testing.expect(res.changed and res.dragging and res.focused);
    try std.testing.expectApproxEqAbs(@as(f32, 50), v, 0.01);
    // Drag to the right, beyond the control: pinned to max.
    list.reset();
    ui = dragUi(&list, &st, 400, false, true);
    res = ui.slider(r, &v, .{ .min = 0, .max = 100 });
    try std.testing.expect(res.changed and res.dragging);
    try std.testing.expectEqual(@as(f32, 100), v);
    // Same position again: no change.
    list.reset();
    ui = dragUi(&list, &st, 400, false, true);
    try std.testing.expect(!ui.slider(r, &v, .{ .min = 0, .max = 100 }).changed);
    // Let go: released, no longer dragging, value stays.
    list.reset();
    ui = dragUi(&list, &st, 400, false, false);
    res = ui.slider(r, &v, .{ .min = 0, .max = 100 });
    try std.testing.expect(res.released and !res.dragging and !res.changed);
    try std.testing.expect(st.drag == null);
    try std.testing.expectEqual(@as(f32, 100), v);
    // Moving with the button up does nothing.
    list.reset();
    ui = dragUi(&list, &st, 20, false, false);
    try std.testing.expect(!ui.slider(r, &v, .{ .min = 0, .max = 100 }).changed);
}

test "slider: step snapping, arrow keys when focused, a click elsewhere blurs" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var st: ui_mod.State = .{};
    var v: f32 = 0;
    const r: Rect = .{ .x = 0, .y = 0, .w = 116, .h = 24 };
    const o: SliderOpts = .{ .min = 0, .max = 10, .step = 1 };
    var ui = dragUi(&list, &st, 8 + 100 * 0.34, true, true); // 3.4 snaps to 3
    _ = ui.slider(r, &v, o);
    try std.testing.expectEqual(@as(f32, 3), v);
    list.reset();
    ui = dragUi(&list, &st, 8 + 34, false, false); // release
    _ = ui.slider(r, &v, o);
    // Keys.
    list.reset();
    ui = dragUi(&list, &st, 1000, false, false);
    ui.input.pushKey(keys.right, .{});
    ui.input.pushKey(keys.right, .{});
    var res = ui.slider(r, &v, o);
    try std.testing.expect(res.changed and res.focused);
    try std.testing.expectEqual(@as(f32, 5), v);
    list.reset();
    ui = dragUi(&list, &st, 1000, false, false);
    ui.input.pushKey(keys.down, .{});
    ui.input.pushKey(keys.end, .{});
    ui.input.pushKey(keys.right, .{}); // past the end: stays
    _ = ui.slider(r, &v, o);
    try std.testing.expectEqual(@as(f32, 10), v);
    ui.input.pushKey(keys.home, .{});
    list.reset();
    ui = dragUi(&list, &st, 1000, false, false);
    ui.input.pushKey(keys.home, .{});
    _ = ui.slider(r, &v, o);
    try std.testing.expectEqual(@as(f32, 0), v);
    // A press elsewhere takes the focus away: keys then do nothing.
    list.reset();
    ui = dragUi(&list, &st, 1000, true, true);
    res = ui.slider(r, &v, o);
    try std.testing.expect(!res.focused);
    list.reset();
    ui = dragUi(&list, &st, 1000, false, false);
    ui.input.pushKey(keys.right, .{});
    try std.testing.expect(!ui.slider(r, &v, o).changed);
    // Continuous sliders step by a twentieth of the range.
    var w: f32 = 0.5;
    st.focus = &w;
    list.reset();
    ui = dragUi(&list, &st, 1000, false, false);
    ui.input.pushKey(keys.left, .{});
    _ = ui.slider(r, &w, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), w, 1e-6);
}

test "slider: disabled ignores everything; without a state a click still jumps" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var st: ui_mod.State = .{};
    var v: f32 = 0.2;
    const r: Rect = .{ .x = 0, .y = 0, .w = 116, .h = 24 };
    var ui = dragUi(&list, &st, 58, true, true);
    var res = ui.slider(r, &v, .{ .disabled = true });
    try std.testing.expect(!res.changed and !res.hovered and st.drag == null);
    try std.testing.expectEqual(@as(f32, 0.2), v);
    list.reset();
    var bare = clickUi(&list, 108, 10, true);
    res = bare.slider(r, &v, .{});
    try std.testing.expect(res.changed);
    try std.testing.expectEqual(@as(f32, 1), v);
    // It draws a track, a fill and a thumb.
    var circles: usize = 0;
    for (list.cmds.items) |c| if (c == .ellipse) {
        circles += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), circles);
}

test "waveform: bar layout and peak reduction" {
    try std.testing.expectEqual(@as(usize, 20), waveformBars(100, 3, 2)); // 5 per bar, last gap trimmed
    try std.testing.expectEqual(@as(usize, 0), waveformBars(2, 3, 2));
    try std.testing.expectEqual(@as(usize, 0), waveformBars(0, 3, 2));
    try std.testing.expectEqual(@as(usize, 1), waveformBars(3, 3, 2));
    const pk = [_]f32{ 0.1, 0.9, 0.2, 0.3, 0.4, 0.5 };
    // 3 bars over 6 peaks: pairs.
    try std.testing.expectEqual(@as(f32, 0.9), waveformPeak(&pk, 0, 3));
    try std.testing.expectEqual(@as(f32, 0.3), waveformPeak(&pk, 1, 3));
    try std.testing.expectEqual(@as(f32, 0.5), waveformPeak(&pk, 2, 3));
    // More bars than peaks repeats; no peaks is flat; NaN counts as 0.
    try std.testing.expectEqual(@as(f32, 0.9), waveformPeak(&pk, 2, 12));
    try std.testing.expectEqual(@as(f32, 0), waveformPeak(&.{}, 0, 4));
    try std.testing.expectEqual(@as(f32, 0), waveformPeak(&.{std.math.nan(f32)}, 0, 1));
}

test "waveform: colours the played bars, reports click and drag positions" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var st: ui_mod.State = .{};
    const pk = [_]f32{ 0.5, 1.0, 0.25, 0.75 };
    const r: Rect = .{ .x = 10, .y = 0, .w = 100, .h = 40 };
    // 20 bars; progress 0.5 colours the first ten.
    var ui = dragUi(&list, &st, 1000, false, false);
    _ = ui.waveform(r, &pk, .{ .progress = 0.5 });
    var played: usize = 0;
    var unplayed: usize = 0;
    for (list.cmds.items) |c| switch (c) {
        .rrect => |b| {
            if (std.meta.eql(b.color, ui.theme.accent)) played += 1 else unplayed += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 10), played);
    try std.testing.expectEqual(@as(usize, 10), unplayed);
    // No progress: nothing is played.
    list.reset();
    _ = ui.waveform(r, &pk, .{});
    for (list.cmds.items) |c| if (c == .rrect) try std.testing.expect(!std.meta.eql(c.rrect.color, ui.theme.accent));
    // Click at 25 % then drag past the right edge and let go.
    list.reset();
    ui = dragUi(&list, &st, 35, true, true);
    var res = ui.waveform(r, &pk, .{});
    try std.testing.expect(res.clicked and res.dragging);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), res.seek.?, 1e-5);
    list.reset();
    ui = dragUi(&list, &st, 500, false, true);
    res = ui.waveform(r, &pk, .{});
    try std.testing.expect(!res.clicked and res.dragging);
    try std.testing.expectEqual(@as(f32, 1), res.seek.?);
    list.reset();
    ui = dragUi(&list, &st, 500, false, false);
    res = ui.waveform(r, &pk, .{});
    try std.testing.expect(res.released and res.seek == null and st.drag == null);
    // Passive never seeks or hovers; disabled never seeks; an empty waveform draws dots and does not crash.
    list.reset();
    ui = dragUi(&list, &st, 35, true, true);
    try std.testing.expect(ui.waveform(r, &pk, .{ .disabled = true }).seek == null);
    list.reset();
    const pas = ui.waveform(r, &pk, .{ .passive = true });
    try std.testing.expect(pas.seek == null and !pas.hovered and !pas.clicked);
    list.reset();
    _ = ui.waveform(r, &.{}, .{});
    try std.testing.expect(list.cmds.items.len > 0);
    // Too narrow for one bar: nothing drawn.
    list.reset();
    _ = ui.waveform(.{ .x = 0, .y = 0, .w = 1, .h = 20 }, &pk, .{});
    try std.testing.expectEqual(@as(usize, 0), list.cmds.items.len);
}
