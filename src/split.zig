//! Split panes: a draggable divider (`Ui.splitter`) and the pure helpers that turn a stored
//! pane size into rectangles (`two`, `three`). The `Ui` methods are thin forwarders; this file
//! holds the types and the implementation, like `controls.zig` and `popup.zig`.
//!
//! The app owns the size (an `f32`, usually in a `SplitState`). Each frame it asks `two` /
//! `three` for the pane rectangles, draws the panes, then calls `splitter` with the divider
//! rectangle; the splitter reads the pointer and writes the new size. Because the rectangles
//! are computed from the size before the splitter runs, a frame later the layout follows the
//! pointer; to avoid that lag, call `splitter` *before* computing the rectangles, or just feed
//! the size into `vass.Layout` (`.fixed(size)`) each frame (see README, "Split panes").
//!
//! ## Winning hit-testing over the panels beside it
//!
//! The divider is usually declared after the panels it sits between (so its line is drawn on
//! top), by which time the panels' widgets have already looked at the pointer. So, like popups,
//! it works from last frame: each splitter records its grab rectangle in `State.grabs`, and
//! `Ui.finish` keeps last frame's list. `Ui.hit` (which every widget goes through, including
//! the focus click handling) reports no hover and no click for a pointer inside a grab
//! rectangle of the same or a lower layer, and for any pointer at all while a splitter is being
//! dragged (nothing else hovers or clicks during the drag). The splitter itself tests the
//! pointer directly. A popup above the splitter still blocks the splitter (it asks
//! `popup.pointerBlocked`), and widgets in a popup are never blocked by it.
//!
//! One frame of lag: when the divider moves, the blocked region is where it was last frame.
//! The grab area is `hit` points wide and the pointer is on the divider while dragging, so the
//! difference is far smaller than the area. Needs `ui.state` and `ui.finish()` (the same as
//! popups); without them the splitter draws and reports hover but cannot drag and blocks nothing.
const std = @import("std");
const geom = @import("geom.zig");
const keys = @import("keys.zig");
const ui_mod = @import("ui.zig");
const focus = @import("focus.zig");
const popup = @import("popup.zig");
const Rect = geom.Rect;
const Color = geom.Color;
const Ui = ui_mod.Ui;

/// Which way the divider runs.
pub const Axis = enum {
    /// A vertical bar between side-by-side panes, dragged left / right (the pane size is a width).
    vertical,
    /// A horizontal bar between stacked panes, dragged up / down (the pane size is a height).
    horizontal,
};

pub const SplitterOpts = struct {
    axis: Axis = .vertical,
    /// Clamp of the controlled size.
    min: f32 = 0,
    max: f32 = std.math.inf(f32),
    /// Double-click (and Enter when focused) sets the size to this.
    default: ?f32 = null,
    /// Dragging the size below this snaps it to 0 (collapsed); dragging back out restores a size
    /// of at least `min`. Stepping down from `min` with the keyboard collapses too.
    collapse_below: ?f32 = null,
    /// The size grows when the divider moves toward negative (left / up): for a right or bottom pane.
    invert: bool = false,
    /// Width of the visible line.
    thickness: f32 = 1,
    /// Width of the grab area, centred on the line (never less than `thickness`).
    hit: f32 = 8,
    /// Arrow-key step; Shift multiplies it by 5.
    step: f32 = 16,
    /// Focus id key (`idKey(x)`); default: the address of the size.
    id: ?u64 = null,
    /// Dimmed to nothing, no hover, no cursor, no input, no blocking of what is beneath.
    disabled: bool = false,
    /// The size currently shown, when it is smaller than the stored size because the window is
    /// too small (`Two.size`). A drag or key press then starts from it, so the divider does not
    /// jump, and stores it. Null: the stored size.
    shown: ?f32 = null,
    /// Colour of the line at rest; null is `theme.track`. `.alpha(0)` hides it (the hover
    /// highlight still shows).
    color: ?Color = null,
    /// Draw the line. Off, call `drawLine` yourself later in the frame (so it sits above panels
    /// drawn after the splitter ran).
    draw: bool = true,
    /// A Tab stop that takes the arrow keys. Off: the splitter only handles the mouse. Together
    /// with `draw = false` this lets an app run the splitter early in the frame (so the panes follow
    /// the pointer with no lag) and call it again late (where its Tab order and line belong); both
    /// calls may share one `size` and agree on it. See README, "Split panes".
    tab_stop: bool = true,
};

pub const SplitterResult = struct {
    /// `size` changed this frame (drag, key or reset).
    changed: bool = false,
    /// The grab area is being dragged (the button is down on it, or a drag that started on it is going on).
    dragging: bool = false,
    /// The pointer is over the grab area (also true while dragging over it).
    hovered: bool = false,
    /// The size is 0.
    collapsed: bool = false,
    /// Double-click or Enter reset the size to `default` this frame.
    reset: bool = false,
    /// The button was let go this frame at the end of a drag: commit the size now.
    released: bool = false,
    /// Has keyboard focus (arrow keys, Home, End and Enter work).
    focused: bool = false,
};

// ---- last frame's grab areas (the blocking) -------------------------------------------------------

pub const Grab = struct { rect: Rect, layer: u8, active: bool };

pub const max_grabs = 16;

/// Grab areas of the splitters drawn last frame (`prev`, what `Ui.hit` reads) and this frame.
pub const Grabs = struct {
    prev: [max_grabs]Grab = undefined,
    prev_n: u8 = 0,
    cur: [max_grabs]Grab = undefined,
    cur_n: u8 = 0,

    pub fn record(g: *Grabs, grab: Grab) void {
        if (g.cur_n < max_grabs) {
            g.cur[g.cur_n] = grab;
            g.cur_n += 1;
        }
    }

    pub fn rotate(g: *Grabs) void {
        g.prev = g.cur;
        g.prev_n = g.cur_n;
        g.cur_n = 0;
    }

    pub fn last(g: *const Grabs) []const Grab {
        return g.prev[0..g.prev_n];
    }
};

/// What an in-progress drag started from: the pointer position along the axis and the size then.
pub const Drag = struct { start_pos: f32 = 0, start_size: f32 = 0 };

/// True if the pointer must not reach a widget of the layer being drawn because of a splitter:
/// it is inside a grab area drawn last frame, or a splitter is being dragged. Used by `Ui.hit`.
pub fn blocks(ui: *const Ui) bool {
    const s = ui.state orelse return false;
    for (s.grabs.last()) |g| {
        if (ui.layer > g.layer) continue;
        if (g.active or g.rect.contains(ui.input.mouse_x, ui.input.mouse_y)) return true;
    }
    return false;
}

/// True while the splitter that controls `size` is being dragged.
pub fn isDragging(ui: *const Ui, size: *const f32) bool {
    const s = ui.state orelse return false;
    return s.drag == @as(*const anyopaque, size);
}

// ---- the size rules (pure) --------------------------------------------------------------------------

/// `raw` as a stored size: below `collapse_below` it is 0, otherwise clamped to `min`..`max`.
pub fn resolve(raw: f32, opts: SplitterOpts) f32 {
    if (std.math.isNan(raw)) return opts.min;
    if (opts.collapse_below) |cb| if (raw < cb) return 0;
    const hi = @max(opts.min, opts.max);
    return std.math.clamp(raw, opts.min, hi);
}

/// The size after a key moved it by `delta` from `cur`.
pub fn stepSize(cur: f32, delta: f32, opts: SplitterOpts) f32 {
    var raw = cur + delta;
    if (delta < 0 and opts.collapse_below != null and raw < opts.min) return 0;
    // Out of a collapse the pane comes back at least `min` wide, not as a sliver that would collapse again.
    if (delta > 0 and opts.collapse_below != null and cur <= 0) raw = @max(raw, opts.min);
    return resolve(raw, opts);
}

fn grabRect(r: Rect, opts: SplitterOpts) Rect {
    const w = @max(opts.hit, opts.thickness);
    return switch (opts.axis) {
        .vertical => .{ .x = r.x + r.w / 2 - w / 2, .y = r.y, .w = w, .h = r.h },
        .horizontal => .{ .x = r.x, .y = r.y + r.h / 2 - w / 2, .w = r.w, .h = w },
    };
}

fn lineRect(r: Rect, th: f32, axis: Axis) Rect {
    return switch (axis) {
        .vertical => .{ .x = @round(r.x + r.w / 2 - th / 2), .y = r.y, .w = th, .h = r.h },
        .horizontal => .{ .x = r.x, .y = @round(r.y + r.h / 2 - th / 2), .w = r.w, .h = th },
    };
}

// ---- the widget -------------------------------------------------------------------------------------

/// A draggable divider. `r` is the line's rectangle (thin along the axis, as long as the panes);
/// the grab area extends to `opts.hit` centred on it. `size` is the controlled pane size: it is
/// read every frame and written while dragging, stepping with the keys, and on a reset. See the
/// module comment for how the grab area wins hit-testing.
pub fn splitter(ui: *Ui, r: Rect, size: *f32, opts: SplitterOpts) SplitterResult {
    const in = &ui.input;
    const vertical = opts.axis == .vertical;
    const id: *const anyopaque = size;
    const grab = grabRect(r, opts);
    var res: SplitterResult = .{};
    if (!std.math.isFinite(size.*)) size.* = opts.default orelse opts.min;
    const before = size.*;
    const sign: f32 = if (opts.invert) -1 else 1;
    const pos = if (vertical) in.mouse_x else in.mouse_y;

    const fid = if (opts.id) |e| ui.widgetId(12, 0, e) else focus.idOfPtr(size);
    const role: focus.Role = if (vertical) .splitter else .splitter_horizontal;
    if (opts.tab_stop) _ = ui.focusable(fid, grab, .{
        .role = role,
        .label = "Resize",
        .disabled = opts.disabled,
        .activate = false,
        .ring = false,
        .click_focus = false,
    });

    var dragging = false;
    if (ui.state) |s| {
        // A frame without `finish` never rotated the records: do it for the first splitter.
        if (!ui.grabs_begun) {
            ui.grabs_begun = true;
            if (s.grabs.cur_n > 0) s.grabs.rotate();
        }
        const mine = s.drag == id;
        const over = !opts.disabled and grab.contains(in.mouse_x, in.mouse_y) and ui.clipContains(in.mouse_x, in.mouse_y) and
            !popup.pointerBlocked(ui) and (s.drag == null or mine);
        res.hovered = over;
        var focused = opts.tab_stop and s.focus == focus.ptrOfId(fid);

        if (!opts.disabled) {
            if (over and ui.pressedNow()) {
                s.select = null;
                if (opts.tab_stop) {
                    s.focus = focus.ptrOfId(fid);
                    focused = true;
                }
                if (opts.default != null and ui.clickCount() >= 2) {
                    size.* = resolve(opts.default.?, opts);
                    res.reset = true;
                    if (mine) s.drag = null;
                } else {
                    s.drag = id;
                    if (opts.shown) |sh| size.* = resolve(sh, opts);
                    s.split_drag = .{ .start_pos = pos, .start_size = size.* };
                }
            } else if (opts.tab_stop and ui.pressedNow() and s.focus == focus.ptrOfId(fid)) {
                s.focus = null; // a press elsewhere blurs it
                focused = false;
            }
            if (s.drag == id) {
                if (in.down or in.released) {
                    const raw = s.split_drag.start_size + (pos - s.split_drag.start_pos) * sign;
                    size.* = resolve(raw, opts);
                    dragging = in.down; // the release frame applies the final position but is not "dragging"
                }
                if (!in.down) {
                    s.drag = null;
                    res.released = true;
                }
            }
            res.focused = focused;
            if (focused) {
                const dec: u32 = if (vertical) keys.left else keys.up;
                const inc: u32 = if (vertical) keys.right else keys.down;
                while (ui.takeKey(&.{ dec, inc, keys.home, keys.end, keys.@"return" })) |k| {
                    const base = opts.shown orelse size.*;
                    const mult: f32 = if (k.mods.shift) 5 else 1;
                    switch (k.code) {
                        keys.home => size.* = resolve(opts.min, opts),
                        keys.end => {
                            if (std.math.isFinite(opts.max)) size.* = resolve(opts.max, opts);
                        },
                        keys.@"return" => if (opts.default) |d| {
                            size.* = resolve(d, opts);
                            res.reset = true;
                        },
                        else => {
                            const dir: f32 = if (k.code == inc) 1 else -1;
                            size.* = stepSize(base, dir * sign * opts.step * mult, opts);
                        },
                    }
                }
            }
            s.grabs.record(.{ .rect = grab, .layer = ui.layer, .active = s.drag == id });
        }
    }
    res.dragging = dragging;
    res.changed = size.* != before;
    res.collapsed = size.* <= 0;

    if (!opts.disabled and (res.hovered or res.dragging)) ui.setCursor(if (vertical) .resize_h else .resize_v);

    if (opts.draw) drawLine(ui, r, res, opts);
    return res;
}

/// Draws the divider's line for `r` as `splitter` does: `opts.color` at rest, the accent and
/// a little heavier while hovered or dragged, the focus-ring colour when focused by keyboard.
/// For `opts.draw = false` splitters; `res` is what `splitter` returned.
pub fn drawLine(ui: *Ui, r: Rect, res: SplitterResult, opts: SplitterOpts) void {
    const theme = ui.theme;
    const active = res.hovered or res.dragging;
    var col = opts.color orelse theme.track;
    var th = opts.thickness;
    if (active) {
        col = theme.accent;
        th = @max(th, 2);
    }
    if (res.focused and ui.focusVisible()) {
        col = theme.ringColor();
        th = @max(th, 2);
    }
    if (opts.disabled) col = col.alpha(col.a / 2);
    if (col.a > 0) ui.list.rect(lineRect(r, th, opts.axis), col);
}

// ---- stored size ------------------------------------------------------------------------------------

/// A pane size that remembers what it was before it was collapsed, for a toggle button that
/// collapses and restores the pane and a splitter that does the same by dragging. Keep it in the app.
pub const SplitState = struct {
    /// The size (0 when collapsed). Pass `&state.size` to `splitter`.
    size: f32,
    /// The last non-zero size, what `expand` goes back to.
    restore: f32,

    pub fn init(size: f32) SplitState {
        return .{ .size = size, .restore = size };
    }

    pub fn collapsed(s: *const SplitState) bool {
        return s.size <= 0;
    }

    /// Call once per frame after the splitter: remembers the size while it is open.
    pub fn remember(s: *SplitState) void {
        if (s.size > 0) s.restore = s.size;
    }

    pub fn collapse(s: *SplitState) void {
        s.remember();
        s.size = 0;
    }

    pub fn expand(s: *SplitState) void {
        if (s.size <= 0) s.size = s.restore;
    }

    pub fn toggle(s: *SplitState) void {
        if (s.collapsed()) s.expand() else s.collapse();
    }
};

// ---- pane rectangles (pure) -------------------------------------------------------------------------

/// Which pane of a `two` split the stored size belongs to.
pub const Side = enum { first, second };

pub const TwoOpts = struct {
    axis: Axis = .vertical,
    /// `first`: the size is the left / top pane's; `second`: the right / bottom pane's.
    side: Side = .first,
    /// The other pane keeps at least this much (the size used is reduced to leave it).
    min_other: f32 = 0,
    /// Empty space between the panes, with the divider centred in it.
    gap: f32 = 0,
    /// Thickness of the divider rectangle.
    thickness: f32 = 1,
};

pub const Two = struct {
    first: Rect,
    second: Rect,
    /// The divider's line rectangle, centred on the boundary (or in the gap).
    divider: Rect,
    /// The size actually used: the stored one, clamped to what fits. The stored size is never
    /// changed, so it comes back when there is room again. Pass it as `SplitterOpts.shown`.
    size: f32,
};

/// Splits `area` into two panes from a stored `size` (see `TwoOpts`). Pure.
pub fn two(area: Rect, size: f32, opts: TwoOpts) Two {
    const vertical = opts.axis == .vertical;
    const total = if (vertical) area.w else area.h;
    const room = @max(0, total - opts.gap - @max(0, opts.min_other));
    const s_in = if (std.math.isFinite(size)) size else 0;
    const used = std.math.clamp(s_in, 0, room);
    // Extent of the first pane along the axis.
    const first_len = if (opts.side == .first) used else @max(0, total - opts.gap - used);
    const second_start = first_len + opts.gap;
    const second_len = @max(0, total - second_start);
    const mid = first_len + opts.gap / 2;
    const th = opts.thickness;
    const d0 = @floor(mid - th / 2 + 0.5);
    if (vertical) return .{
        .first = .{ .x = area.x, .y = area.y, .w = first_len, .h = area.h },
        .second = .{ .x = area.x + second_start, .y = area.y, .w = second_len, .h = area.h },
        .divider = .{ .x = area.x + d0, .y = area.y, .w = th, .h = area.h },
        .size = used,
    };
    return .{
        .first = .{ .x = area.x, .y = area.y, .w = area.w, .h = first_len },
        .second = .{ .x = area.x, .y = area.y + second_start, .w = area.w, .h = second_len },
        .divider = .{ .x = area.x, .y = area.y + d0, .w = area.w, .h = th },
        .size = used,
    };
}

pub const ThreeOpts = struct {
    axis: Axis = .vertical,
    /// The centre pane keeps at least this much; the right pane gives way first, then the left one.
    min_centre: f32 = 0,
    gap: f32 = 0,
    thickness: f32 = 1,
};

pub const Three = struct {
    left: Rect,
    centre: Rect,
    right: Rect,
    /// Between left and centre, and between centre and right.
    left_divider: Rect,
    right_divider: Rect,
    /// The sizes used (stored sizes clamped to what fits).
    left_size: f32,
    right_size: f32,
};

/// Left | centre | right (or top | middle | bottom) from two stored sizes: the left pane is
/// served first, the right one gets what is left over the centre's minimum. Pure; it is two
/// `two` calls.
pub fn three(area: Rect, left_size: f32, right_size: f32, opts: ThreeOpts) Three {
    const l = two(area, left_size, .{ .axis = opts.axis, .side = .first, .min_other = opts.min_centre, .gap = opts.gap, .thickness = opts.thickness });
    const r = two(l.second, right_size, .{ .axis = opts.axis, .side = .second, .min_other = opts.min_centre, .gap = opts.gap, .thickness = opts.thickness });
    return .{
        .left = l.first,
        .centre = r.first,
        .right = r.second,
        .left_divider = l.divider,
        .right_divider = r.divider,
        .left_size = l.size,
        .right_size = r.size,
    };
}

// ---- tests ------------------------------------------------------------------------------------------

const gfx = @import("gfx.zig");
const State = ui_mod.State;
const Input = ui_mod.Input;
const DisplayList = gfx.DisplayList;
const t = std.testing;

fn fm(_: ?*anyopaque, str: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(str.len)) * size / 2;
}

/// A state and display list that live across the frames of a test.
const Rig = struct {
    list: DisplayList,
    state: *State,
    /// Cursor the last frame asked for.
    cursor: ?ui_mod.Cursor = null,

    fn init() !Rig {
        const st = try t.allocator.create(State);
        st.* = .{};
        return .{ .list = DisplayList.init(t.allocator), .state = st };
    }

    fn deinit(r: *Rig) void {
        r.list.deinit();
        t.allocator.destroy(r.state);
    }

    fn ui(r: *Rig, in: Input) Ui {
        r.list.reset();
        var u = Ui.initHeadless(&r.list, in, .{}, fm);
        u.state = r.state;
        return u;
    }

    fn end(r: *Rig, u: *Ui) void {
        r.cursor = u.cursor;
        u.finish();
    }
};

fn at(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y };
}
fn press(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y, .pressed = true, .down = true, .mouse_clicks = 1 };
}
fn press2(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y, .pressed = true, .down = true, .mouse_clicks = 2 };
}
fn held(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y, .down = true };
}
fn lift(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y, .released = true };
}
fn keyIn(code: u32, mods: keys.Mods) Input {
    var in: Input = .{};
    in.pushKey(code, mods);
    return in;
}

/// A vertical divider whose line is at x = 200 (width 1), 400 tall.
const vbar: Rect = .{ .x = 200, .y = 0, .w = 1, .h = 400 };
const hbar: Rect = .{ .x = 0, .y = 200, .w = 400, .h = 1 };

fn frameV(rig: *Rig, in: Input, size: *f32, opts: SplitterOpts) SplitterResult {
    var u = rig.ui(in);
    const res = splitter(&u, vbar, size, opts);
    rig.end(&u);
    return res;
}

test "drag moves the size by the pointer delta without a jump" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    var r = frameV(&rig, at(203, 50), &size, .{});
    try t.expect(r.hovered and !r.dragging);
    // Grab 3 points right of the line centre: nothing moves on the press frame.
    r = frameV(&rig, press(203, 50), &size, .{});
    try t.expect(r.dragging and !r.changed);
    try t.expectEqual(@as(f32, 200), size);
    r = frameV(&rig, held(233, 50), &size, .{});
    try t.expect(r.dragging and r.changed);
    try t.expectEqual(@as(f32, 230), size);
    r = frameV(&rig, held(180, 60), &size, .{});
    try t.expectEqual(@as(f32, 177), size);
    r = frameV(&rig, lift(180, 60), &size, .{});
    try t.expect(r.released and !r.dragging);
    try t.expect(rig.state.drag == null);
    // Later motion changes nothing.
    r = frameV(&rig, at(300, 60), &size, .{});
    try t.expectEqual(@as(f32, 177), size);
    try t.expect(!r.changed);
}

test "drag clamps at min and max" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    const o: SplitterOpts = .{ .min = 120, .max = 260 };
    _ = frameV(&rig, press(200, 5), &size, o);
    _ = frameV(&rig, held(500, 5), &size, o);
    try t.expectEqual(@as(f32, 260), size);
    _ = frameV(&rig, held(-100, 5), &size, o);
    try t.expectEqual(@as(f32, 120), size);
    // Coming back from far outside tracks the pointer again from the clamp edge.
    _ = frameV(&rig, held(230, 5), &size, o);
    try t.expectEqual(@as(f32, 230), size);
}

test "invert: the size grows when the pointer moves toward negative" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 300;
    const o: SplitterOpts = .{ .invert = true, .min = 100, .max = 500 };
    _ = frameV(&rig, press(200, 5), &size, o);
    _ = frameV(&rig, held(170, 5), &size, o);
    try t.expectEqual(@as(f32, 330), size);
    _ = frameV(&rig, held(260, 5), &size, o);
    try t.expectEqual(@as(f32, 240), size);
}

test "horizontal axis drags up and down and asks for the vertical-resize cursor" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 150;
    const o: SplitterOpts = .{ .axis = .horizontal, .min = 50 };
    var u = rig.ui(at(40, 202));
    var r = splitter(&u, hbar, &size, o);
    try t.expect(r.hovered);
    try t.expectEqual(ui_mod.Cursor.resize_v, u.cursor.?);
    rig.end(&u);
    u = rig.ui(press(40, 202));
    _ = splitter(&u, hbar, &size, o);
    rig.end(&u);
    u = rig.ui(held(999, 232)); // x is irrelevant
    r = splitter(&u, hbar, &size, o);
    rig.end(&u);
    try t.expectEqual(@as(f32, 180), size);
}

test "collapse_below snaps to 0 and dragging back out restores at least min" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 270;
    const o: SplitterOpts = .{ .min = 200, .max = 420, .collapse_below = 120 };
    _ = frameV(&rig, press(200, 5), &size, o);
    var r = frameV(&rig, held(150, 5), &size, o); // raw 220
    try t.expectEqual(@as(f32, 220), size);
    r = frameV(&rig, held(110, 5), &size, o); // raw 180: below min, above the snap point
    try t.expectEqual(@as(f32, 200), size);
    try t.expect(!r.collapsed);
    r = frameV(&rig, held(40, 5), &size, o); // raw 110 < 120
    try t.expectEqual(@as(f32, 0), size);
    try t.expect(r.collapsed and r.dragging);
    // Still dragging after the pane vanished: the pointer back out restores >= min.
    r = frameV(&rig, held(70, 5), &size, o); // raw 140
    try t.expectEqual(@as(f32, 200), size);
    try t.expect(!r.collapsed);
    r = frameV(&rig, held(300, 5), &size, o);
    try t.expectEqual(@as(f32, 370), size);
}

test "double click resets to default, a single click does not" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 333;
    const o: SplitterOpts = .{ .default = 270, .min = 100 };
    _ = frameV(&rig, press(200, 5), &size, o);
    _ = frameV(&rig, lift(200, 5), &size, o);
    try t.expectEqual(@as(f32, 333), size);
    const r = frameV(&rig, press2(200, 5), &size, o);
    try t.expect(r.reset and r.changed and !r.dragging);
    try t.expectEqual(@as(f32, 270), size);
    try t.expect(rig.state.drag == null);
    // Without a default a double click is just a press.
    size = 333;
    const r2 = frameV(&rig, press2(200, 5), &size, .{});
    try t.expect(!r2.reset and r2.dragging);
}

test "scripted double click (no OS count) is detected by time and distance" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 333;
    const o: SplitterOpts = .{ .default = 270 };
    var in = press(200, 5);
    in.mouse_clicks = 0;
    in.time = 10.0;
    _ = frameV(&rig, in, &size, o);
    _ = frameV(&rig, lift(200, 5), &size, o);
    in.time = 10.2;
    const r = frameV(&rig, in, &size, o);
    try t.expect(r.reset);
    try t.expectEqual(@as(f32, 270), size);
}

test "the drag continues outside the grab area and nothing else hovers or clicks" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    var other_clicks: u32 = 0;
    var other_hover = false;
    const panel: Rect = .{ .x = 300, .y = 100, .w = 80, .h = 40 };
    const Frame = struct {
        fn run(rg: *Rig, in: Input, sz: *f32, clicks: *u32, hover: *bool) SplitterResult {
            var u = rg.ui(in);
            const hv = u.hit(panel);
            if (hv.clicked) clicks.* += 1;
            hover.* = hv.hovered;
            const res = splitter(&u, vbar, sz, .{});
            rg.end(&u);
            return res;
        }
    };
    _ = Frame.run(&rig, press(200, 20), &size, &other_clicks, &other_hover);
    // Pointer far from the divider, over the other widget, button held: still dragging.
    var r = Frame.run(&rig, held(320, 110), &size, &other_clicks, &other_hover);
    try t.expect(r.dragging);
    try t.expectEqual(@as(f32, 320), size);
    try t.expect(!other_hover);
    // Release over the other widget: no click, hover returns on the next frame.
    r = Frame.run(&rig, lift(320, 110), &size, &other_clicks, &other_hover);
    try t.expect(r.released);
    try t.expectEqual(@as(u32, 0), other_clicks);
    _ = Frame.run(&rig, at(320, 110), &size, &other_clicks, &other_hover);
    try t.expect(other_hover);
    try t.expect(r.hovered == false);
}

test "the grab area takes the click over an overlapping widget beneath it" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    var clicks: u32 = 0;
    var hovers: u32 = 0;
    // A button-like widget under the divider, declared BEFORE it (as panels are).
    const beneath: Rect = .{ .x = 150, .y = 50, .w = 100, .h = 40 };
    const Frame = struct {
        fn run(rg: *Rig, in: Input, sz: *f32, c: *u32, h: *u32) SplitterResult {
            var u = rg.ui(in);
            const hv = u.hit(beneath);
            if (hv.clicked) c.* += 1;
            if (hv.hovered) h.* += 1;
            const res = splitter(&u, vbar, sz, .{});
            rg.end(&u);
            return res;
        }
    };
    // Hover first so last frame knows the grab area is there (the pointer was there already).
    _ = Frame.run(&rig, at(203, 60), &size, &clicks, &hovers);
    hovers = 0;
    // Even the very first frame of a press over the grab area belongs to the splitter, because
    // last frame recorded the area.
    const r = Frame.run(&rig, press(203, 60), &size, &clicks, &hovers);
    try t.expect(r.dragging);
    try t.expectEqual(@as(u32, 0), clicks);
    try t.expectEqual(@as(u32, 0), hovers);
    // Outside the 8 wide grab area (x 196..204) the widget works.
    _ = Frame.run(&rig, lift(203, 60), &size, &clicks, &hovers);
    _ = Frame.run(&rig, at(230, 60), &size, &clicks, &hovers);
    _ = Frame.run(&rig, press(230, 60), &size, &clicks, &hovers);
    try t.expectEqual(@as(u32, 1), clicks);
}

test "blocked beneath a popup, and widgets in the popup are not blocked by the splitter" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    var pop: ui_mod.PopupState = .{};
    var inside_clicks: u32 = 0;
    const Frame = struct {
        fn run(rg: *Rig, in: Input, sz: *f32, ps: *ui_mod.PopupState, clicks: *u32, open: bool) SplitterResult {
            var u = rg.ui(in);
            u.bounds = .{ .x = 0, .y = 0, .w = 400, .h = 400 };
            if (open) u.openPopup(ps);
            const res = splitter(&u, vbar, sz, .{});
            // A modal popup centred on the window, declared after the splitter.
            if (u.beginPopup(ps, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ 120, 120 }, .{ .placement = .center, .modal = true, .dismiss_on_outside = false })) |_| {
                // A widget exactly where the divider's grab area is, under the pointer.
                if (u.hit(.{ .x = 196, .y = 190, .w = 8, .h = 20 }).clicked) clicks.* += 1;
                u.endPopup();
            }
            rg.end(&u);
            return res;
        }
    };
    // Without a popup the splitter takes the pointer.
    var r = Frame.run(&rig, at(200, 200), &size, &pop, &inside_clicks, false);
    try t.expect(r.hovered);
    _ = Frame.run(&rig, lift(200, 200), &size, &pop, &inside_clicks, false);
    // Open the popup, let a frame pass so its rectangle is known.
    _ = Frame.run(&rig, at(200, 200), &size, &pop, &inside_clicks, true);
    r = Frame.run(&rig, at(200, 200), &size, &pop, &inside_clicks, false);
    try t.expect(!r.hovered);
    try t.expect(rig.cursor == null);
    r = Frame.run(&rig, press(200, 200), &size, &pop, &inside_clicks, false);
    try t.expect(!r.dragging);
    try t.expectEqual(@as(f32, 200), size);
    try t.expectEqual(@as(u32, 1), inside_clicks); // the popup's own widget got the click
    r = Frame.run(&rig, held(300, 200), &size, &pop, &inside_clicks, false);
    try t.expectEqual(@as(f32, 200), size);
}

test "keyboard: arrows step, shift steps more, Home and End jump, Enter resets" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    const o: SplitterOpts = .{ .min = 100, .max = 400, .default = 250, .step = 10 };
    // Click focuses it (and ends a zero-length drag).
    _ = frameV(&rig, press(200, 5), &size, o);
    _ = frameV(&rig, lift(200, 5), &size, o);
    var r = frameV(&rig, keyIn(keys.right, .{}), &size, o);
    try t.expect(r.focused and r.changed);
    try t.expectEqual(@as(f32, 210), size);
    _ = frameV(&rig, keyIn(keys.left, .{}), &size, o);
    _ = frameV(&rig, keyIn(keys.left, .{}), &size, o);
    try t.expectEqual(@as(f32, 190), size);
    _ = frameV(&rig, keyIn(keys.right, .{ .shift = true }), &size, o);
    try t.expectEqual(@as(f32, 240), size);
    // Up / Down do nothing on a vertical bar and are not consumed.
    var in = keyIn(keys.down, .{});
    var u = rig.ui(in);
    _ = splitter(&u, vbar, &size, o);
    try t.expectEqual(@as(usize, 1), u.input.events().len);
    rig.end(&u);
    _ = frameV(&rig, keyIn(keys.home, .{}), &size, o);
    try t.expectEqual(@as(f32, 100), size);
    _ = frameV(&rig, keyIn(keys.end, .{}), &size, o);
    try t.expectEqual(@as(f32, 400), size);
    r = frameV(&rig, keyIn(keys.@"return", .{}), &size, o);
    try t.expect(r.reset);
    try t.expectEqual(@as(f32, 250), size);
    // Clamped at the ends.
    size = 105;
    _ = frameV(&rig, keyIn(keys.left, .{ .shift = true }), &size, o);
    try t.expectEqual(@as(f32, 100), size);
    // Consumed keys are gone from the frame's events.
    in = keyIn(keys.right, .{});
    u = rig.ui(in);
    _ = splitter(&u, vbar, &size, o);
    try t.expectEqual(@as(usize, 0), u.input.events().len);
    rig.end(&u);
}

test "keyboard: invert flips the direction, collapse_below collapses from min, a horizontal bar uses Up and Down" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 300;
    var o: SplitterOpts = .{ .min = 200, .max = 480, .step = 20, .invert = true, .collapse_below = 100 };
    _ = frameV(&rig, press(200, 5), &size, o);
    _ = frameV(&rig, lift(200, 5), &size, o);
    _ = frameV(&rig, keyIn(keys.right, .{}), &size, o); // divider right = right pane smaller
    try t.expectEqual(@as(f32, 280), size);
    _ = frameV(&rig, keyIn(keys.left, .{}), &size, o);
    try t.expectEqual(@as(f32, 300), size);
    size = 200;
    _ = frameV(&rig, keyIn(keys.right, .{}), &size, o); // below min with collapse: 0
    try t.expectEqual(@as(f32, 0), size);
    _ = frameV(&rig, keyIn(keys.left, .{}), &size, o); // out of collapse: at least min
    try t.expectEqual(@as(f32, 200), size);
    // Horizontal.
    o = .{ .axis = .horizontal, .step = 10 };
    size = 100;
    var u = rig.ui(press(10, 200));
    _ = splitter(&u, hbar, &size, o);
    rig.end(&u);
    u = rig.ui(lift(10, 200));
    _ = splitter(&u, hbar, &size, o);
    rig.end(&u);
    u = rig.ui(keyIn(keys.down, .{}));
    _ = splitter(&u, hbar, &size, o);
    rig.end(&u);
    try t.expectEqual(@as(f32, 110), size);
    u = rig.ui(keyIn(keys.left, .{}));
    _ = splitter(&u, hbar, &size, o);
    try t.expectEqual(@as(usize, 1), u.input.events().len);
    rig.end(&u);
}

test "disabled: no hover, no drag, no cursor, nothing blocked beneath" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    var clicks: u32 = 0;
    const beneath: Rect = .{ .x = 150, .y = 50, .w = 100, .h = 40 };
    for ([_]Input{ at(203, 60), press(203, 60), held(260, 60), lift(260, 60) }) |in| {
        var u = rig.ui(in);
        const hv = u.hit(beneath);
        const r = splitter(&u, vbar, &size, .{ .disabled = true });
        if (hv.clicked) clicks += 1;
        try t.expect(!r.hovered and !r.dragging);
        try t.expect(u.cursor == null);
        rig.end(&u);
    }
    try t.expectEqual(@as(f32, 200), size);
    try t.expectEqual(@as(u32, 1), clicks);
}

test "the cursor is the resize cursor on hover and during the drag, and reverts after" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    _ = frameV(&rig, at(100, 5), &size, .{});
    try t.expect(rig.cursor == null);
    _ = frameV(&rig, at(202, 5), &size, .{});
    try t.expectEqual(ui_mod.Cursor.resize_h, rig.cursor.?);
    _ = frameV(&rig, press(202, 5), &size, .{});
    try t.expectEqual(ui_mod.Cursor.resize_h, rig.cursor.?);
    // Far away from the bar, still dragging: still the resize cursor.
    _ = frameV(&rig, held(30, 300), &size, .{});
    try t.expectEqual(ui_mod.Cursor.resize_h, rig.cursor.?);
    _ = frameV(&rig, lift(30, 300), &size, .{});
    try t.expect(rig.cursor == null); // let go away from the bar: back to the arrow at once
    // Let go over the bar: it stays the resize cursor (hovered).
    _ = frameV(&rig, press(202, 5), &size, .{});
    _ = frameV(&rig, lift(202, 5), &size, .{});
    try t.expectEqual(ui_mod.Cursor.resize_h, rig.cursor.?);
}

test "a splitter in a frame that never calls finish still rotates its records" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    var clicks: u32 = 0;
    const beneath: Rect = .{ .x = 150, .y = 50, .w = 100, .h = 40 };
    for ([_]Input{ at(203, 60), at(203, 60), press(203, 60) }) |in| {
        var u = rig.ui(in);
        const hv = u.hit(beneath);
        if (hv.clicked) clicks += 1;
        _ = splitter(&u, vbar, &size, .{}); // no finish
    }
    try t.expectEqual(@as(u32, 0), clicks);
}

test "two: sizes, sides, gap and the divider rectangle" {
    const area: Rect = .{ .x = 10, .y = 20, .w = 800, .h = 600 };
    var s = two(area, 270, .{});
    try t.expectEqual(Rect{ .x = 10, .y = 20, .w = 270, .h = 600 }, s.first);
    try t.expectEqual(Rect{ .x = 280, .y = 20, .w = 530, .h = 600 }, s.second);
    try t.expectEqual(Rect{ .x = 280, .y = 20, .w = 1, .h = 600 }, s.divider);
    s = two(area, 300, .{ .side = .second });
    try t.expectEqual(@as(f32, 500), s.first.w);
    try t.expectEqual(@as(f32, 300), s.second.w);
    try t.expectEqual(@as(f32, 510), s.second.x);
    // Horizontal with a gap: the divider is centred in it.
    s = two(area, 200, .{ .axis = .horizontal, .gap = 8, .thickness = 2 });
    try t.expectEqual(Rect{ .x = 10, .y = 20, .w = 800, .h = 200 }, s.first);
    try t.expectEqual(Rect{ .x = 10, .y = 228, .w = 800, .h = 392 }, s.second);
    try t.expectEqual(Rect{ .x = 10, .y = 223, .w = 800, .h = 2 }, s.divider);
}

test "two: a shrinking area clamps the used size but keeps the preferred one" {
    var pref: f32 = 300;
    var area: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 100 };
    var s = two(area, pref, .{ .min_other = 420 });
    try t.expectEqual(@as(f32, 300), s.size);
    area.w = 600; // only 180 left for the first pane
    s = two(area, pref, .{ .min_other = 420 });
    try t.expectEqual(@as(f32, 180), s.size);
    try t.expectEqual(@as(f32, 420), s.second.w);
    try t.expectEqual(@as(f32, 300), pref); // never written
    area.w = 300; // nothing fits
    s = two(area, pref, .{ .min_other = 420 });
    try t.expectEqual(@as(f32, 0), s.size);
    try t.expectEqual(@as(f32, 300), s.second.w);
    // Room again: back to the preferred size.
    area.w = 900;
    s = two(area, pref, .{ .min_other = 420 });
    try t.expectEqual(@as(f32, 300), s.size);
    // Hostile input.
    pref = std.math.nan(f32);
    s = two(area, pref, .{});
    try t.expectEqual(@as(f32, 0), s.size);
    s = two(area, -50, .{});
    try t.expectEqual(@as(f32, 0), s.size);
}

test "three: the left pane is served first, the right one gives way" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 1200, .h = 700 };
    var s = three(area, 270, 300, .{ .min_centre = 420 });
    try t.expectEqual(@as(f32, 270), s.left.w);
    try t.expectEqual(@as(f32, 630), s.centre.w);
    try t.expectEqual(@as(f32, 300), s.right.w);
    try t.expectEqual(@as(f32, 900), s.right.x);
    try t.expectEqual(@as(f32, 270), s.left_divider.x);
    try t.expectEqual(@as(f32, 900), s.right_divider.x);
    s = three(.{ .x = 0, .y = 0, .w = 800, .h = 700 }, 270, 300, .{ .min_centre = 420 });
    try t.expectEqual(@as(f32, 270), s.left_size);
    try t.expectEqual(@as(f32, 110), s.right_size);
    try t.expectEqual(@as(f32, 420), s.centre.w);
    s = three(.{ .x = 0, .y = 0, .w = 500, .h = 700 }, 270, 300, .{ .min_centre = 420 });
    try t.expectEqual(@as(f32, 80), s.left_size);
    try t.expectEqual(@as(f32, 0), s.right_size);
    try t.expectEqual(@as(f32, 420), s.centre.w);
}

test "SplitState remembers the size across a collapse" {
    var s = SplitState.init(270);
    s.toggle();
    try t.expect(s.collapsed());
    try t.expectEqual(@as(f32, 270), s.restore);
    s.toggle();
    try t.expectEqual(@as(f32, 270), s.size);
    s.size = 310;
    s.remember();
    s.size = 0;
    s.expand();
    try t.expectEqual(@as(f32, 310), s.size);
}

test "shown: a drag starts from the displayed size, not the stored one" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 300; // stored; only 180 is shown because the window is small
    const o: SplitterOpts = .{ .shown = 180 };
    _ = frameV(&rig, press(200, 5), &size, o);
    try t.expectEqual(@as(f32, 180), size);
    _ = frameV(&rig, held(215, 5), &size, o);
    try t.expectEqual(@as(f32, 195), size);
}

test "resolve and stepSize" {
    const o: SplitterOpts = .{ .min = 200, .max = 400, .collapse_below = 120 };
    try t.expectEqual(@as(f32, 0), resolve(119, o));
    try t.expectEqual(@as(f32, 200), resolve(120, o));
    try t.expectEqual(@as(f32, 400), resolve(999, o));
    try t.expectEqual(@as(f32, 200), resolve(std.math.nan(f32), o));
    try t.expectEqual(@as(f32, 0), stepSize(200, -16, o));
    try t.expectEqual(@as(f32, 200), stepSize(0, 16, o));
    try t.expectEqual(@as(f32, 216), stepSize(200, 16, o));
}

test "ClickTracker: double-click time and distance thresholds" {
    var c: ui_mod.ClickTracker = .{};
    try t.expectEqual(@as(u8, 1), c.next(1.0, 100, 100));
    try t.expectEqual(@as(u8, 2), c.next(1.5, 104, 96)); // exactly 0.5 s and 4 points: still a double click
    try t.expectEqual(@as(u8, 3), c.next(1.9, 100, 100));
    try t.expectEqual(@as(u8, 3), c.next(2.2, 100, 100)); // capped at triple
    try t.expectEqual(@as(u8, 1), c.next(2.8, 100, 100)); // 0.6 s: a new series
    try t.expectEqual(@as(u8, 1), c.next(3.0, 105, 100)); // 5 points away: a new series
    try t.expectEqual(@as(u8, 1), c.next(3.1, 105, 106)); // 6 points in y
    try t.expectEqual(@as(u8, 1), c.next(2.0, 105, 106)); // the clock went backwards
    try t.expectEqual(@as(u8, 2), c.next(2.3, 105, 106));
}

test "setCursor: last request wins, and a request under a popup is ignored" {
    var rig = try Rig.init();
    defer rig.deinit();
    var u = rig.ui(.{});
    try t.expect(u.cursor == null);
    u.setCursor(.pointer);
    u.setCursor(.text);
    try t.expectEqual(ui_mod.Cursor.text, u.cursor.?);
    rig.end(&u);
    // A modal popup covers the window: layer 0 may not ask for a cursor, the popup's own widgets may.
    var pop: ui_mod.PopupState = .{};
    u = rig.ui(at(200, 200));
    u.bounds = .{ .x = 0, .y = 0, .w = 400, .h = 400 };
    u.openPopup(&pop);
    if (u.beginPopup(&pop, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ 100, 100 }, .{ .placement = .center, .modal = true })) |_| u.endPopup();
    rig.end(&u);
    u = rig.ui(at(200, 200));
    u.bounds = .{ .x = 0, .y = 0, .w = 400, .h = 400 };
    u.setCursor(.resize_h);
    try t.expect(u.cursor == null);
    if (u.beginPopup(&pop, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ 100, 100 }, .{ .placement = .center, .modal = true })) |_| {
        u.setCursor(.pointer);
        u.endPopup();
    }
    try t.expectEqual(ui_mod.Cursor.pointer, u.cursor.?);
    rig.end(&u);
}

test "text fields and text areas ask for the text cursor while hovered" {
    var rig = try Rig.init();
    defer rig.deinit();
    var field = ui_mod.TextFieldState.init(t.allocator);
    defer field.deinit();
    const box: Rect = .{ .x = 10, .y = 10, .w = 200, .h = 30 };
    var u = rig.ui(at(50, 20));
    _ = u.textField(box, &field, .{});
    try t.expectEqual(ui_mod.Cursor.text, u.cursor.?);
    rig.end(&u);
    u = rig.ui(at(300, 20));
    _ = u.textField(box, &field, .{});
    try t.expect(u.cursor == null);
    rig.end(&u);
    // A splitter grab area over the field takes the hover, and so the cursor, from it.
    var size: f32 = 100;
    u = rig.ui(at(100, 20));
    _ = splitter(&u, .{ .x = 100, .y = 0, .w = 1, .h = 100 }, &size, .{});
    rig.end(&u);
    u = rig.ui(at(100, 20));
    _ = u.textField(box, &field, .{});
    try t.expect(u.cursor == null);
    rig.end(&u);
}

test "early call without tab stop plus late call: both agree, one line drawn, one Tab entry" {
    var rig = try Rig.init();
    defer rig.deinit();
    var size: f32 = 200;
    const Frame = struct {
        fn run(rg: *Rig, in: Input, sz: *f32) struct { early: SplitterResult, late: SplitterResult } {
            var u = rg.ui(in);
            const early = splitter(&u, vbar, sz, .{ .draw = false, .tab_stop = false });
            // ... panels would be laid out and drawn here from `sz` ...
            const late = splitter(&u, vbar, sz, .{ .tab_stop = true });
            rg.end(&u);
            return .{ .early = early, .late = late };
        }
    };
    _ = Frame.run(&rig, at(200, 5), &size);
    var r = Frame.run(&rig, press(200, 5), &size);
    try t.expect(r.early.dragging and r.late.dragging);
    r = Frame.run(&rig, held(250, 5), &size);
    try t.expectEqual(@as(f32, 250), size);
    try t.expect(r.early.changed and !r.late.changed);
    try t.expect(r.late.dragging);
    var lines: usize = 0;
    for (rig.list.cmds.items) |c| if (c == .rrect) {
        lines += 1;
    };
    try t.expectEqual(@as(usize, 1), lines);
    try t.expectEqual(@as(usize, 1), rig.state.focusEntries().len);
    r = Frame.run(&rig, lift(250, 5), &size);
    try t.expectEqual(@as(f32, 250), size);
    try t.expect(rig.state.drag == null);
}

test "feeds a Layout with no lag: the splitter runs first with last frame's divider" {
    const layout = @import("layout.zig");
    var rig = try Rig.init();
    defer rig.deinit();
    var side_w: f32 = 270;
    var div: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var side_rect: Rect = undefined;
    const Frame = struct {
        fn run(rg: *Rig, in: Input, w: *f32, d: *Rect, out: *Rect) void {
            var u = rg.ui(in);
            _ = splitter(&u, d.*, w, .{ .min = 100, .max = 400 });
            var lay = layout.Layout.init(t.allocator);
            defer lay.deinit();
            _ = lay.begin(.{ .dir = .row, .w = .grow(1), .h = .grow(1) });
            const side = lay.leaf(.{ .w = .fixed(w.*), .h = .grow(1) });
            const gap = lay.leaf(.{ .w = .fixed(8), .h = .grow(1) });
            _ = lay.leaf(.{ .w = .grow(1), .h = .grow(1) });
            lay.end();
            lay.solve(.{ .x = 0, .y = 0, .w = 1000, .h = 600 });
            d.* = lay.rect(gap);
            out.* = lay.rect(side);
            rg.end(&u);
        }
    };
    Frame.run(&rig, .{}, &side_w, &div, &side_rect);
    try t.expectEqual(@as(f32, 270), side_rect.w);
    const grab_x = div.x + div.w / 2;
    Frame.run(&rig, at(grab_x, 50), &side_w, &div, &side_rect);
    Frame.run(&rig, press(grab_x, 50), &side_w, &div, &side_rect);
    // The very frame the pointer moves, the pane is already 40 wider.
    Frame.run(&rig, held(grab_x + 40, 50), &side_w, &div, &side_rect);
    try t.expectEqual(@as(f32, 310), side_rect.w);
    try t.expectEqual(@as(f32, 310), side_w);
    Frame.run(&rig, held(grab_x + 400, 50), &side_w, &div, &side_rect);
    try t.expectEqual(@as(f32, 400), side_rect.w);
}
