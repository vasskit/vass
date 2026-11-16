//! Popups: floating panels drawn above everything else, and what is built on them: menus,
//! context menus, the dropdown (select) control and tooltips. They are `Ui` methods (see
//! `Ui.beginPopup` and friends); this file holds the types and the implementations, like
//! `controls.zig`.
//!
//! ## How it works
//!
//! **Drawing.** Inside `beginPopup`...`endPopup` everything is recorded into an overlay layer
//! of the display list (`DisplayList.setLayer`): layer n for the n-th nested popup (up to
//! `max_depth`), 5 for tooltips. `Ui.finish` appends the layers to the main stream, so a popup
//! is drawn above everything, however early or late it was declared, and a nested popup above
//! its parent even if the parent draws more widgets after it. The clip stack of the code that
//! declared the popup does not apply inside (`Ui.clip_base`).
//!
//! **Input.** A popup is declared after the widgets it covers, so those widgets cannot know
//! about it yet. Each popup therefore records its rectangle in `State.popups`, and `Ui.finish`
//! keeps last frame's list. `Ui.hit` ignores the pointer inside a rectangle of a layer above the
//! one being drawn (and everywhere, below a modal popup). A mouse press, key press or typed text
//! is not delivered to layers below an open popup (`Ui.pressedNow`, `Ui.events`). A press outside
//! every open popup closes it (when `dismiss_on_outside`) and is swallowed; Escape closes the
//! topmost popup and is consumed.
//!
//! Popups need `ui.state` (a caller-owned `State`) and a `ui.finish()` call at the end of every
//! frame; without a state they still draw but route no input.
//!
//! The app's own copy of the `Input` is not changed: an app with global shortcuts should check
//! `ui.popupOpen()` before acting on Escape or the arrow keys.
const std = @import("std");
const geom = @import("geom.zig");
const gfx = @import("gfx.zig");
const icons = @import("icons.zig");
const keys = @import("keys.zig");
const ui_mod = @import("ui.zig");
const focus = @import("focus.zig");
const Rect = geom.Rect;
const Color = geom.Color;
const Ui = ui_mod.Ui;

/// Deepest nesting of popups (a dropdown in a popover in a dialog...).
pub const max_depth = 4;
/// The overlay layer tooltips are drawn on, above every popup.
pub const tooltip_layer: u8 = max_depth + 1;
/// Room kept between a popup and the window edge.
pub const edge_margin: f32 = 6;

pub const Placement = enum {
    /// Under the anchor, flipping above it when there is no room.
    below,
    above,
    right,
    left,
    /// At the point `anchor.x`, `anchor.y` (give the anchor zero size), growing right and down,
    /// flipping to the left / above when it would leave the window. For context menus.
    at_point,
    /// Centred in the window (dialogs); the anchor is ignored.
    center,
};

/// Where the popup sits along the anchor's edge.
pub const Alignment = enum { start, center, end };

pub const PopupOpts = struct {
    placement: Placement = .below,
    alignment: Alignment = .start,
    /// Space between anchor and panel.
    gap: f32 = 6,
    /// Dim the whole window behind the panel and block all pointer input beneath it.
    modal: bool = false,
    /// A press outside the panel closes it (and is swallowed). Off, a modal dialog can only be
    /// closed by the app (or Escape). Off for a non-modal popup lets outside clicks through.
    dismiss_on_outside: bool = true,
    /// Between the panel edge and the content rectangle.
    padding: f32 = 8,
    /// Draw no background, border or shadow: the caller paints the panel.
    bare: bool = false,
    /// Corner radius of the panel.
    radius: f32 = 10,
};

/// Caller-owned state of one popup: keep it at a stable address.
pub const PopupState = struct {
    open: bool = false,
    /// Set by `openPopup`, cleared by the first `beginPopup` that sees it: that frame's pointer
    /// and keys cannot dismiss or activate anything (they opened it).
    fresh: bool = false,
    /// Counts openings, so a popup opened inside another can tell when that one reopened.
    serial: u32 = 0,
    parent_serial: u32 = 0,
    /// The highlighted menu item (keyboard or hover).
    highlight: ?usize = null,
    /// Menu scroll offset when the menu is taller than the window.
    scroll: f32 = 0,
    /// Where it was opened by `contextOpen`.
    point: [2]f32 = .{ 0, 0 },
    last_mouse: [2]f32 = .{ std.math.nan(f32), 0 },
    /// The popup most recently drawn inside this one, closed together with it.
    child: ?*PopupState = null,
    /// Keyboard focus when it was opened, given back when it closes (see `openPopup`).
    return_focus: ?*const anyopaque = null,
    has_return: bool = false,

    /// A zero-size anchor at the point a context menu was opened at.
    pub fn pointAnchor(st: *const PopupState) Rect {
        return .{ .x = st.point[0], .y = st.point[1], .w = 0, .h = 0 };
    }
};

/// A popup drawn this frame or last: where, and how it takes input.
pub const Rec = struct { rect: Rect, layer: u8, modal: bool, swallow: bool };

pub const max_recs = 8;

/// Last frame's popup rectangles (`prev`, what input routing reads) and this frame's (`cur`).
pub const Tracker = struct {
    prev: [max_recs]Rec = undefined,
    prev_n: u8 = 0,
    cur: [max_recs]Rec = undefined,
    cur_n: u8 = 0,

    pub fn record(t: *Tracker, rec: Rec) void {
        if (t.cur_n < max_recs) {
            t.cur[t.cur_n] = rec;
            t.cur_n += 1;
        }
    }

    pub fn rotate(t: *Tracker) void {
        t.prev = t.cur;
        t.prev_n = t.cur_n;
        t.cur_n = 0;
    }

    pub fn last(t: *const Tracker) []const Rec {
        return t.prev[0..t.prev_n];
    }
};

/// One open `beginPopup`, on the Ui's stack until `endPopup`.
pub const Frame = struct {
    st: *PopupState,
    rect: Rect,
    saved_layer: u8,
    saved_clip_base: usize,
    saved_scroll_base: usize,
};

// ---- input routing -------------------------------------------------------------------------

fn lastRecs(ui: *const Ui) []const Rec {
    const s = ui.state orelse return &.{};
    return s.popups.last();
}

/// True if the pointer should not reach widgets of the layer being drawn: it is inside a popup
/// of a higher layer as of last frame, or such a popup is modal.
pub fn pointerBlocked(ui: *const Ui) bool {
    for (lastRecs(ui)) |p| {
        if (p.layer <= ui.layer) continue;
        if (p.modal or p.rect.contains(ui.input.mouse_x, ui.input.mouse_y)) return true;
    }
    return false;
}

/// True if a click or key of this frame belongs to a popup above layer `layer`.
fn takenAbove(ui: *const Ui, layer: u8) bool {
    for (lastRecs(ui)) |p| {
        if (p.layer > layer and p.swallow) return true;
    }
    return false;
}

pub fn pressSwallowed(ui: *const Ui) bool {
    return takenAbove(ui, ui.layer);
}

pub fn eventsFor(ui: *const Ui, layer: u8) []const ui_mod.InEvent {
    if (takenAbove(ui, layer)) return &.{};
    return ui.input.events();
}

pub fn anyOpen(ui: *const Ui) bool {
    return ui.popup_n > 0 or lastRecs(ui).len > 0;
}

fn insideAbove(ui: *const Ui, layer: u8, x: f32, y: f32) bool {
    for (lastRecs(ui)) |p| {
        if (p.layer > layer and p.rect.contains(x, y)) return true;
    }
    return false;
}

// ---- placement -----------------------------------------------------------------------------

/// Where a `w` x `h` panel goes for `anchor` (see `Placement`): on the requested side,
/// flipped to the opposite one when that does not fit but the opposite does (or has more room),
/// then shifted to stay `edge_margin` inside `bounds`. Pure.
pub fn place(anchor: Rect, w: f32, h: f32, placement: Placement, alignment: Alignment, gap: f32, bounds: Rect) Rect {
    const lo_x = bounds.x + edge_margin;
    const hi_x = bounds.x + bounds.w - edge_margin;
    const lo_y = bounds.y + edge_margin;
    const hi_y = bounds.y + bounds.h - edge_margin;
    var x: f32 = anchor.x;
    var y: f32 = anchor.y;
    switch (placement) {
        .below, .above => {
            const below_y = anchor.y + anchor.h + gap;
            const above_y = anchor.y - gap - h;
            const room_below = hi_y - below_y;
            const room_above = anchor.y - gap - lo_y;
            const want_below = placement == .below;
            const fits = if (want_below) room_below >= h else room_above >= h;
            const other_fits = if (want_below) room_above >= h else room_below >= h;
            var use_below = want_below;
            if (!fits and (other_fits or (if (want_below) room_above > room_below else room_below > room_above))) use_below = !want_below;
            y = if (use_below) below_y else above_y;
            x = switch (alignment) {
                .start => anchor.x,
                .center => anchor.x + (anchor.w - w) / 2,
                .end => anchor.x + anchor.w - w,
            };
        },
        .right, .left => {
            const right_x = anchor.x + anchor.w + gap;
            const left_x = anchor.x - gap - w;
            const room_right = hi_x - right_x;
            const room_left = anchor.x - gap - lo_x;
            const want_right = placement == .right;
            const fits = if (want_right) room_right >= w else room_left >= w;
            const other_fits = if (want_right) room_left >= w else room_right >= w;
            var use_right = want_right;
            if (!fits and (other_fits or (if (want_right) room_left > room_right else room_right > room_left))) use_right = !want_right;
            x = if (use_right) right_x else left_x;
            y = switch (alignment) {
                .start => anchor.y,
                .center => anchor.y + (anchor.h - h) / 2,
                .end => anchor.y + anchor.h - h,
            };
        },
        .at_point => {
            x = anchor.x;
            y = anchor.y;
            if (x + w > hi_x and anchor.x - w >= lo_x) x = anchor.x - w;
            if (y + h > hi_y and anchor.y - h >= lo_y) y = anchor.y - h;
        },
        .center => {
            x = bounds.x + (bounds.w - w) / 2;
            y = bounds.y + (bounds.h - h) / 2;
        },
    }
    x = @max(lo_x, @min(x, hi_x - w));
    y = @max(lo_y, @min(y, hi_y - h));
    return .{ .x = x, .y = y, .w = w, .h = h };
}

// ---- popups ---------------------------------------------------------------------------------

/// The panel colour: a little lighter than a card, so it reads above cards.
pub fn surface(ui: *const Ui) Color {
    return ui_mod.mixColor(ui.theme.card, ui.theme.text, 0.07);
}

pub fn openPopup(ui: *Ui, st: *PopupState) void {
    if (st.open) return;
    st.open = true;
    st.fresh = true;
    st.serial +%= 1;
    st.highlight = null;
    st.scroll = 0;
    st.last_mouse = .{ std.math.nan(f32), 0 };
    st.parent_serial = if (ui.popup_n > 0) ui.popup_stack[ui.popup_n - 1].st.serial else 0;
    // Remember what had keyboard focus, to give it back on close.
    if (ui.state) |s| {
        st.return_focus = s.focus;
        st.has_return = true;
    }
}

/// Closes `st` and any popup opened from inside it.
pub fn closePopup(ui: *Ui, st: *PopupState) void {
    for (ui.popup_stack[0..ui.popup_n], 0..) |f, i| {
        if (f.st == st and i > 0 and ui.popup_stack[i - 1].st.child == st) ui.popup_stack[i - 1].st.child = null;
    }
    closeTree(ui, st);
}

fn closeTree(ui: *Ui, st: *PopupState) void {
    st.open = false;
    st.fresh = false;
    if (st.child) |c| {
        st.child = null;
        if (c.open) closeTree(ui, c);
    }
    // Focus goes back to what had it before the popup opened (children first, so the
    // outermost popup's value wins).
    if (st.has_return) {
        st.has_return = false;
        if (ui.state) |s| s.focus = st.return_focus;
    }
}

/// `st` closes itself from inside its own `beginPopup` (Escape, outside press, stale).
fn closeSelf(ui: *Ui, st: *PopupState) void {
    if (ui.popup_n > 0) {
        const parent = ui.popup_stack[ui.popup_n - 1].st;
        if (parent.child == st) parent.child = null;
    }
    closeTree(ui, st);
}

pub fn beginPopup(ui: *Ui, st: *PopupState, anchor: Rect, size: [2]f32, opts: PopupOpts) ?Rect {
    if (!st.open) return null;
    if (ui.popup_n >= max_depth) return null;
    const layer: u8 = @intCast(ui.popup_n + 1);
    // Tab is handled (and removed from the events) even if no widget has been drawn yet.
    if (ui.state) |s| focus.frameBegin(ui, s);

    // A popup opened inside another is stale once that one has been reopened.
    if (ui.popup_n > 0) {
        const parent = ui.popup_stack[ui.popup_n - 1].st;
        if (st.parent_serial == 0) {
            st.parent_serial = parent.serial;
        } else if (st.parent_serial != parent.serial) {
            closeSelf(ui, st);
            return null;
        }
    }

    const fresh = st.fresh;
    st.fresh = false;
    const bounds = ui.bounds;
    const w = @min(size[0], @max(0, bounds.w - 2 * edge_margin));
    const h = @min(size[1], @max(0, bounds.h - 2 * edge_margin));
    const rect = place(anchor, w, h, opts.placement, opts.alignment, opts.gap, bounds);
    const swallow = opts.modal or opts.dismiss_on_outside;

    if (!fresh) {
        const in = &ui.input;
        // Escape: the topmost popup only (the events of a layer under an open popup are empty).
        const evs = eventsFor(ui, layer);
        for (evs, 0..) |ev, i| switch (ev) {
            .key => |k| if (k.code == keys.escape) {
                in.removeEvent(i);
                closeSelf(ui, st);
                return null;
            },
            else => {},
        };
        // A press outside this popup and every popup opened from it.
        if ((in.pressed or in.right_pressed) and opts.dismiss_on_outside and !rect.contains(in.mouse_x, in.mouse_y) and
            !insideAbove(ui, layer, in.mouse_x, in.mouse_y))
        {
            closeSelf(ui, st);
            return null;
        }
    }

    if (ui.popup_n > 0) ui.popup_stack[ui.popup_n - 1].st.child = st;
    if (ui.state) |s| s.popups.record(.{ .rect = rect, .layer = layer, .modal = opts.modal, .swallow = swallow });

    ui.popup_stack[ui.popup_n] = .{ .st = st, .rect = rect, .saved_layer = ui.layer, .saved_clip_base = ui.clip_base, .saved_scroll_base = ui.scroll_base };
    ui.popup_n += 1;
    ui.layer = layer;
    ui.clip_base = ui.clip_n;
    ui.scroll_base = ui.scroll_n;
    ui.list.setLayer(layer);

    const t = ui.theme;
    if (opts.modal) ui.list.rect(bounds, Color{ .r = 0, .g = 0, .b = 0, .a = 135 });
    if (!opts.bare) {
        ui.list.shadow(rect, opts.radius, 14, 5, Color{ .r = 0, .g = 0, .b = 0, .a = 70 });
        // Opaque border and fill, so nothing underneath shows through the hairline.
        const fill = surface(ui);
        ui.list.rrect(rect, opts.radius, ui_mod.mixColor(fill, t.text, 0.14));
        ui.list.rrect(rect.inset(1), @max(0, opts.radius - 1), fill);
    }
    return rect.inset(opts.padding);
}

pub fn endPopup(ui: *Ui) void {
    if (ui.popup_n == 0) return;
    ui.popup_n -= 1;
    const f = ui.popup_stack[ui.popup_n];
    ui.layer = f.saved_layer;
    ui.clip_base = f.saved_clip_base;
    ui.scroll_base = f.saved_scroll_base;
    ui.list.setLayer(f.saved_layer);
}

/// Ends the frame: merges the overlay layers into the main list and rotates the popup records.
pub fn finish(ui: *Ui) void {
    std.debug.assert(ui.popup_n == 0);
    if (ui.state) |s| {
        s.popups.rotate();
        focus.rotate(s, true);
        s.tip.waiting = s.tip.waiting_next;
        s.tip.waiting_next = false;
    }
    ui.list.setLayer(0);
    ui.list.mergeLayers();
}

// ---- menus -----------------------------------------------------------------------------------

pub const MenuItem = struct {
    label: []const u8 = "",
    /// Drawn left of the label (a built-in, an `SvgIcon` or an `icons.Source`).
    icon: ?icons.Source = null,
    /// Right-aligned dim text, e.g. "Cmd+K". Display only; the app handles the shortcut.
    shortcut: []const u8 = "",
    disabled: bool = false,
    /// Draws a check mark in the icon column (instead of the icon).
    checked: bool = false,
    /// Destructive: red label.
    danger: bool = false,
    /// A divider line instead of an item (the other fields are ignored).
    separator: bool = false,
};

pub const MenuOpts = struct {
    placement: Placement = .below,
    alignment: Alignment = .start,
    gap: f32 = 4,
    /// The menu is at least this wide...
    min_width: f32 = 160,
    /// ...or exactly this wide.
    width: ?f32 = null,
    item_h: f32 = 28,
    /// Font size; defaults to the theme's body size.
    size: ?f32 = null,
    /// Item highlighted when the menu opens.
    initial: ?usize = null,
    dismiss_on_outside: bool = true,
};

const menu_pad: f32 = 4;
const sep_h: f32 = 9;
const item_pad_x: f32 = 10;
const lead_w: f32 = 16;
const lead_gap: f32 = 8;

fn itemH(it: MenuItem, opts: MenuOpts) f32 {
    return if (it.separator) sep_h else opts.item_h;
}

fn enabled(it: MenuItem) bool {
    return !it.separator and !it.disabled;
}

/// Index of the nearest enabled item after (`dir` > 0) or before (`dir` < 0) `from`; `from` null
/// starts from the outside. No wrapping. Null if there is none.
pub fn stepEnabled(items: []const MenuItem, from: ?usize, dir: i32) ?usize {
    if (items.len == 0) return null;
    var i: isize = if (from) |f| @intCast(f) else if (dir > 0) -1 else @intCast(items.len);
    const d: isize = if (dir > 0) 1 else -1;
    while (true) {
        i += d;
        if (i < 0 or i >= items.len) return null;
        if (enabled(items[@intCast(i)])) return @intCast(i);
    }
}

pub fn firstEnabled(items: []const MenuItem) ?usize {
    return stepEnabled(items, null, 1);
}

pub fn lastEnabled(items: []const MenuItem) ?usize {
    return stepEnabled(items, null, -1);
}

fn menuHasLead(items: []const MenuItem) bool {
    for (items) |it| if (!it.separator and (it.icon != null or it.checked)) return true;
    return false;
}

/// Outer size of a menu showing `items`.
pub fn menuSize(ui: *const Ui, items: []const MenuItem, opts: MenuOpts) [2]f32 {
    const size = opts.size orelse ui.theme.font_body;
    const lead: f32 = if (menuHasLead(items)) lead_w + lead_gap else 0;
    var w: f32 = 0;
    var h: f32 = 0;
    for (items) |it| {
        h += itemH(it, opts);
        if (it.separator) continue;
        var iw = lead + ui.measure(it.label, size);
        if (it.shortcut.len > 0) iw += 28 + ui.measure(it.shortcut, size - 1);
        w = @max(w, iw);
    }
    const total_w = w + 2 * item_pad_x + 2 * menu_pad + 2; // +2: the panel's hairline
    return .{ opts.width orelse @max(opts.min_width, total_w), h + 2 * menu_pad + 2 };
}

fn itemTop(items: []const MenuItem, i: usize, opts: MenuOpts) f32 {
    var y: f32 = 0;
    for (items[0..i]) |it| y += itemH(it, opts);
    return y;
}

fn drawCheck(ui: *Ui, box: Rect, color: Color) void {
    const k = box.w / 16;
    const mark = [_][2]f32{
        .{ box.x + 3 * k, box.y + 8.4 * k },
        .{ box.x + 6.5 * k, box.y + 11.6 * k },
        .{ box.x + 12.5 * k, box.y + 4.8 * k },
    };
    ui.list.polyline(&mark, 1.7, color, false);
}

/// A menu of `items` in a popup anchored to `anchor`. Hover or Up/Down/Home/End move the
/// highlight (disabled items and separators are skipped), a click or Enter/Space activates
/// it, Escape or a click outside closes. Returns the index activated this frame (the menu
/// closes itself then). While taller than the window it scrolls with the wheel.
pub fn menu(ui: *Ui, st: *PopupState, anchor: Rect, items: []const MenuItem, opts: MenuOpts) ?usize {
    if (!st.open) return null;
    const t = ui.theme;
    const size = opts.size orelse t.font_body;
    const fresh = st.fresh;
    if (fresh) {
        st.highlight = if (opts.initial) |i| (if (i < items.len and enabled(items[i])) i else null) else null;
    }
    const outer = menuSize(ui, items, opts);
    const content = beginPopup(ui, st, anchor, outer, .{
        .placement = opts.placement,
        .alignment = opts.alignment,
        .gap = opts.gap,
        .padding = menu_pad + 1,
        .dismiss_on_outside = opts.dismiss_on_outside,
        .radius = 10,
    }) orelse return null;
    defer endPopup(ui);

    var result: ?usize = null;
    var total_h: f32 = 0;
    for (items) |it| total_h += itemH(it, opts);
    const max_scroll = @max(0, total_h - content.h);

    // Keyboard. (Escape was handled by beginPopup.)
    if (!fresh) {
        var moved = false;
        for (ui.events()) |ev| switch (ev) {
            .key => |k| switch (k.code) {
                keys.down => {
                    st.highlight = stepEnabled(items, st.highlight, 1) orelse st.highlight;
                    moved = true;
                },
                keys.up => {
                    st.highlight = stepEnabled(items, st.highlight, -1) orelse st.highlight;
                    moved = true;
                },
                keys.home => {
                    st.highlight = firstEnabled(items) orelse st.highlight;
                    moved = true;
                },
                keys.end => {
                    st.highlight = lastEnabled(items) orelse st.highlight;
                    moved = true;
                },
                keys.@"return", keys.space => if (st.highlight) |h| {
                    if (h < items.len and enabled(items[h])) result = h;
                },
                else => {},
            },
            else => {},
        };
        if (moved) if (st.highlight) |h| {
            const top = itemTop(items, h, opts);
            const bot = top + itemH(items[h], opts);
            if (top < st.scroll) st.scroll = top;
            if (bot > st.scroll + content.h) st.scroll = bot - content.h;
        };
    }
    if (max_scroll > 0 and ui.hit(content).hovered and ui.input.wheel_y != 0) {
        st.scroll -= ui.input.wheel_y * t.scroll_step;
        ui.input.wheel_y = 0;
    }
    st.scroll = std.math.clamp(st.scroll, 0, max_scroll);

    const mouse_moved = st.last_mouse[0] != ui.input.mouse_x or st.last_mouse[1] != ui.input.mouse_y;
    st.last_mouse = .{ ui.input.mouse_x, ui.input.mouse_y };

    ui.pushClip(content);
    defer ui.popClip();
    const lead: f32 = if (menuHasLead(items)) lead_w + lead_gap else 0;
    var y = content.y - st.scroll;
    for (items, 0..) |it, i| {
        const h = itemH(it, opts);
        const row: Rect = .{ .x = content.x, .y = y, .w = content.w, .h = h };
        y += h;
        if (row.y + row.h < content.y or row.y > content.y + content.h) continue;
        if (it.separator) {
            ui.list.rect(.{ .x = row.x + 6, .y = row.y + @floor(h / 2), .w = row.w - 12, .h = 1 }, t.text.alpha(26));
            continue;
        }
        const on = enabled(it);
        const hv = if (on) ui.hit(row) else ui_mod.Interaction{ .hovered = false, .clicked = false };
        if (hv.hovered and mouse_moved) st.highlight = i;
        if (hv.clicked and !fresh) result = i;
        const lit = on and st.highlight != null and st.highlight.? == i;
        if (lit) ui.list.rrect(row, 6, if (it.danger) t.bad.alpha(38) else t.text.alpha(22));
        var col = if (it.danger) t.bad else t.text;
        if (!on) col = col.alpha(90);
        const dim = if (on) t.dim else t.dim.alpha(90);
        const ty = row.y + @round((h - size * 1.22) / 2);
        if (it.checked) {
            drawCheck(ui, .{ .x = row.x + item_pad_x, .y = row.y + (h - lead_w) / 2, .w = lead_w, .h = lead_w }, col);
        } else if (it.icon) |ic| {
            icons.drawSource(ui.list, ic, .{ .x = row.x + item_pad_x, .y = row.y + (h - lead_w) / 2, .w = lead_w, .h = lead_w }, if (it.danger) col else if (on) t.dim else dim, 1);
        }
        ui.labelAt(row.x + item_pad_x + lead, ty, it.label, .{ .size = size, .color = col });
        if (it.shortcut.len > 0) ui.labelAt(row.x + row.w - item_pad_x, ty + 0.5, it.shortcut, .{ .size = size - 1, .color = dim, .@"align" = .right });
    }

    if (result != null) closePopup(ui, st);
    return result;
}

/// Opens `st` at the pointer when the right button goes down inside `area`. True on that frame.
/// Use it for lists with one shared popup state, then draw `menu(st, st.pointAnchor(), ...,
/// .{ .placement = .at_point })` once, after the rows.
pub fn contextOpen(ui: *Ui, st: *PopupState, area: Rect) bool {
    if (st.open or !ui.input.right_pressed) return false;
    if (pressSwallowed(ui)) return false;
    if (!ui.hit(area).hovered) return false;
    st.point = .{ ui.input.mouse_x, ui.input.mouse_y };
    openPopup(ui, st);
    return true;
}

pub fn contextMenu(ui: *Ui, st: *PopupState, area: Rect, items: []const MenuItem, opts: MenuOpts) ?usize {
    _ = contextOpen(ui, st, area);
    var o = opts;
    o.placement = .at_point;
    return menu(ui, st, st.pointAnchor(), items, o);
}

// ---- dropdown --------------------------------------------------------------------------------

pub const DropdownState = struct {
    popup: PopupState = .{},
};

pub const DropdownOpts = struct {
    /// Shown dimmed when `selected` is out of range.
    placeholder: []const u8 = "",
    /// Font size; defaults to the theme's body size.
    size: ?f32 = null,
    disabled: bool = false,
};

/// A select control filling `r`: the current item and a chevron; click to open a menu as wide
/// as `r` with a check mark on the current item. Focusable (needs `ui.state`): when focused and
/// closed Up/Down change the selection and Enter/Space open it. Returns true when `selected`
/// changed.
pub fn dropdown(ui: *Ui, r: Rect, st: *DropdownState, items: []const []const u8, selected: *usize, opts: DropdownOpts) bool {
    const t = ui.theme;
    const id: *const anyopaque = st;
    const size = opts.size orelse t.font_body;
    var changed = false;
    if (opts.disabled and st.popup.open) st.popup.open = false;
    const hv = if (opts.disabled) ui_mod.Interaction{ .hovered = false, .clicked = false } else ui.hit(r);
    // A Tab stop; the dropdown handles the mouse and its keys itself.
    _ = ui.focusable(focus.idOfPtr(id), r, .{ .role = .dropdown, .label = if (items.len > 0 and selected.* < items.len) items[selected.*] else opts.placeholder, .disabled = opts.disabled, .ring = false, .activate = false, .click_focus = false });
    var focused = if (ui.state) |s| s.focus == id else false;

    if (!opts.disabled) {
        if (hv.clicked) {
            if (ui.state) |s| {
                s.focus = id;
                s.select = null;
            }
            focused = true;
            if (!st.popup.open) ui.openPopup(&st.popup);
        } else if (ui.pressedNow() and focused) {
            if (ui.state) |s| s.focus = null;
            focused = false;
        }
        if (focused and !st.popup.open and items.len > 0) {
            while (!st.popup.open) {
                const k = ui.takeKey(&.{ keys.down, keys.up, keys.@"return", keys.space }) orelse break;
                switch (k.code) {
                    keys.down => {
                        const n = if (selected.* >= items.len) 0 else @min(selected.* + 1, items.len - 1);
                        if (n != selected.*) {
                            selected.* = n;
                            changed = true;
                        }
                    },
                    keys.up => {
                        const n = if (selected.* >= items.len) items.len - 1 else selected.* -| 1;
                        if (n != selected.*) {
                            selected.* = n;
                            changed = true;
                        }
                    },
                    else => if (!k.repeat) ui.openPopup(&st.popup),
                }
            }
        }
    }

    // Face.
    const open = st.popup.open;
    const border = if (opts.disabled) t.track.alpha(120) else if (focused or open) t.accent else if (hv.hovered) t.dim.alpha(150) else t.track;
    ui.list.rrect(r, 9, border);
    ui.list.rrect(r.inset(1.5), 7.5, if (opts.disabled) t.card.alpha(120) else t.card);
    const have = selected.* < items.len;
    const str = if (have) items[selected.*] else opts.placeholder;
    var col = if (have) t.text else t.dim;
    if (opts.disabled) col = col.alpha(90);
    var buf: [128]u8 = undefined;
    const shown = ui.fitText(&buf, str, size, @max(0, r.w - 20 - 26));
    ui.labelAt(r.x + 12, r.y + @round((r.h - size * 1.22) / 2), shown, .{ .size = size, .color = col });
    icons.draw(ui.list, .chevron_down, .{ .x = r.x + r.w - 26, .y = r.y + (r.h - 14) / 2, .w = 14, .h = 14 }, if (opts.disabled) t.dim.alpha(90) else t.dim, 1);
    if (focused and !opts.disabled and ui.focusVisible()) ui.focusRing(r, 9, 2);

    if (st.popup.open) {
        const arena = ui.list.arena.allocator();
        const mitems = arena.alloc(MenuItem, items.len) catch return changed;
        for (items, mitems, 0..) |s, *m, i| m.* = .{ .label = s, .checked = have and i == selected.* };
        if (menu(ui, &st.popup, r, mitems, .{
            .width = r.w,
            .size = size,
            .initial = if (have) selected.* else null,
        })) |i| {
            if (i != selected.*) {
                selected.* = i;
                changed = true;
            }
        }
    }
    return changed;
}

// ---- tooltip ---------------------------------------------------------------------------------

pub const TooltipOpts = struct {
    /// Seconds the pointer must rest in the rectangle.
    delay: f32 = 0.5,
    /// Wraps text wider than this.
    max_width: f32 = 240,
    size: f32 = 11.5,
    gap: f32 = 6,
};

/// Tooltip timer, in `State`.
pub const TipState = struct {
    /// The rectangle the pointer is resting in (zero size: none).
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    since: f64 = 0,
    anchor: [2]f32 = .{ 0, 0 },
    /// A press hid the tooltip; stays hidden until the pointer leaves the rectangle.
    suppressed: bool = false,
    /// A timer ran last frame (see `State.needsRedraw`).
    waiting: bool = false,
    waiting_next: bool = false,
};

fn sameRect(a: Rect, b: Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

/// Whether a tooltip for `r` is showing, as `tooltip` would decide it this frame, updating the
/// timer. Separate from drawing so tests (and apps) can query it.
pub fn tooltipVisible(ui: *Ui, r: Rect, delay: f32) bool {
    const s = ui.state orelse return false;
    const tip = &s.tip;
    const hv = ui.hit(r);
    const same = sameRect(tip.rect, r);
    if (!hv.hovered) {
        if (same) {
            tip.rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            tip.suppressed = false;
        }
        return false;
    }
    const in = &ui.input;
    if (!same) {
        tip.rect = r;
        tip.since = in.time;
        tip.anchor = .{ in.mouse_x, in.mouse_y };
        tip.suppressed = false;
    }
    if (in.pressed or in.right_pressed) tip.suppressed = true;
    if (tip.suppressed) return false;
    const elapsed = in.time - tip.since;
    if (elapsed < delay) {
        const dx = in.mouse_x - tip.anchor[0];
        const dy = in.mouse_y - tip.anchor[1];
        if (dx * dx + dy * dy > 16) { // moved: it is not resting yet
            tip.since = in.time;
            tip.anchor = .{ in.mouse_x, in.mouse_y };
        }
        s.tip.waiting_next = true;
        return false;
    }
    return true;
}

pub fn tooltip(ui: *Ui, r: Rect, text: []const u8, opts: TooltipOpts) void {
    if (text.len == 0) return;
    if (!tooltipVisible(ui, r, opts.delay)) return;
    const t = ui.theme;
    const pad_x: f32 = 8;
    const pad_y: f32 = 5;
    const lh = ui.lineHeight(opts.size);
    const text_w = @min(ui.measure(text, opts.size) + 1, opts.max_width);
    const text_h = ui.measureWrapped(text, opts.size, text_w);
    const w = text_w + 2 * pad_x;
    const h = text_h + 2 * pad_y - (lh - opts.size * 1.22) / 2;
    const rect = place(r, w, h, .below, .center, opts.gap, ui.bounds);

    // Draw on the top layer, unclipped, then put everything back.
    const saved_layer = ui.list.layer;
    const saved_base = ui.clip_base;
    ui.list.setLayer(tooltip_layer);
    ui.clip_base = ui.clip_n;
    defer {
        ui.list.setLayer(saved_layer);
        ui.clip_base = saved_base;
    }
    ui.list.shadow(rect, 7, 8, 3, Color{ .r = 0, .g = 0, .b = 0, .a = 60 });
    const fill = ui_mod.mixColor(t.bg, t.text, 0.1);
    ui.list.rrect(rect, 7, ui_mod.mixColor(fill, t.text, 0.16));
    ui.list.rrect(rect.inset(1), 6, fill);
    var y = rect.y + pad_y;
    var it = ui.wrapText(text, opts.size, text_w);
    while (it.next()) |line| : (y += lh) {
        if (line.len > 0) ui.labelAt(rect.x + pad_x, y - (lh - opts.size * 1.22) / 2, line, .{ .size = opts.size, .color = t.text });
    }
}

// ---- tests -----------------------------------------------------------------------------------

const testing = std.testing;
const DisplayList = gfx.DisplayList;
const State = ui_mod.State;
const Input = ui_mod.Input;

fn fm(_: ?*anyopaque, str: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(str.len)) * size * 0.5;
}

/// A little harness: one list, one State, frames driven with synthetic input.
const Rig = struct {
    list: DisplayList,
    state: State = .{},
    in: Input = .{},
    bounds: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 },

    fn init() Rig {
        return .{ .list = DisplayList.init(testing.allocator) };
    }
    fn deinit(r: *Rig) void {
        r.list.deinit();
    }
    fn ui(r: *Rig) Ui {
        r.list.reset();
        var u = Ui.initHeadless(&r.list, r.in, .{}, fm);
        u.state = &r.state;
        u.bounds = r.bounds;
        return u;
    }
    /// Ends the frame the way the app loop does: finish, then clear one-frame input.
    fn end(r: *Rig, u: *Ui) void {
        u.finish();
        r.in.endFrame();
    }
    fn click(r: *Rig, x: f32, y: f32) void {
        r.in.mouse_x = x;
        r.in.mouse_y = y;
        r.in.pressed = true;
        r.in.down = true;
    }
    fn release(r: *Rig) void {
        r.in.down = false;
        r.in.released = true;
    }
    fn move(r: *Rig, x: f32, y: f32) void {
        r.in.mouse_x = x;
        r.in.mouse_y = y;
    }
    fn key(r: *Rig, code: u32) void {
        r.in.pushKey(code, .{});
    }
};

const test_items = [_]MenuItem{
    .{ .label = "Cut" },
    .{ .label = "Copy", .disabled = true },
    .{ .separator = true },
    .{ .label = "Paste" },
    .{ .label = "Delete", .danger = true },
};

test "place: below, flips above near the bottom, shifts inside the window" {
    const bounds: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 300 };
    const anchor: Rect = .{ .x = 20, .y = 20, .w = 100, .h = 30 };
    const r1 = place(anchor, 120, 80, .below, .start, 4, bounds);
    try testing.expectEqual(@as(f32, 54), r1.y);
    try testing.expectEqual(@as(f32, 20), r1.x);
    const low: Rect = .{ .x = 20, .y = 260, .w = 100, .h = 30 };
    const r2 = place(low, 120, 80, .below, .start, 4, bounds);
    try testing.expectEqual(@as(f32, 260 - 4 - 80), r2.y); // flipped above
    const right_edge: Rect = .{ .x = 350, .y = 20, .w = 40, .h = 30 };
    const r3 = place(right_edge, 120, 80, .below, .start, 4, bounds);
    try testing.expectEqual(@as(f32, 400 - edge_margin - 120), r3.x); // shifted left
    // Right of the anchor flips to the left when it does not fit.
    const r4 = place(.{ .x = 300, .y = 100, .w = 60, .h = 20 }, 120, 40, .right, .start, 4, bounds);
    try testing.expectEqual(@as(f32, 300 - 4 - 120), r4.x);
    // At a point: flips both ways near the bottom-right corner.
    const r5 = place(.{ .x = 390, .y = 290, .w = 0, .h = 0 }, 100, 60, .at_point, .start, 0, bounds);
    try testing.expectEqual(@as(f32, 290), r5.x);
    try testing.expectEqual(@as(f32, 230), r5.y);
    // Centred.
    const r6 = place(anchor, 100, 50, .center, .start, 0, bounds);
    try testing.expectEqual(@as(f32, 150), r6.x);
    try testing.expectEqual(@as(f32, 125), r6.y);
}

test "popup: blocks hit on a widget beneath it, widgets inside it hit normally" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{};
    const btn: Rect = .{ .x = 20, .y = 20, .w = 100, .h = 30 };
    const under: Rect = .{ .x = 20, .y = 70, .w = 100, .h = 30 }; // the popup will cover this
    // Frame 1: open it.
    pst.open = true;
    pst.fresh = true;
    {
        var u = rig.ui();
        const c = u.beginPopup(&pst, btn, .{ 160, 120 }, .{ .padding = 8 }).?;
        try testing.expect(c.w > 0);
        u.endPopup();
        rig.end(&u);
    }
    // Frame 2: pointer over `under` (inside the popup rect) and pressed.
    rig.click(40, 80);
    var u = rig.ui();
    try testing.expect(!u.hit(under).hovered);
    try testing.expect(!u.hit(under).clicked);
    const c = u.beginPopup(&pst, btn, .{ 160, 120 }, .{ .padding = 8 }).?;
    try testing.expect(u.hit(c).hovered); // inside the popup: normal
    try testing.expect(u.hit(c).clicked);
    u.endPopup();
    try testing.expect(pst.open); // a press inside does not dismiss
    rig.end(&u);
}

test "popup: an outside press closes it and is swallowed; the opening click does not" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{};
    const btn: Rect = .{ .x = 20, .y = 20, .w = 100, .h = 30 };
    var count: usize = 0;
    // Frame 1: the button is clicked, which opens the popup in the same frame.
    rig.click(40, 30);
    {
        var u = rig.ui();
        if (u.hit(btn).clicked) u.openPopup(&pst);
        try testing.expect(pst.open);
        if (u.beginPopup(&pst, btn, .{ 160, 100 }, .{})) |_| u.endPopup();
        try testing.expect(pst.open); // the click that opened it did not close it
        rig.end(&u);
    }
    // Frame 2: the pointer is still down but nothing was pressed: stays open.
    {
        var u = rig.ui();
        if (u.beginPopup(&pst, btn, .{ 160, 100 }, .{})) |_| u.endPopup();
        try testing.expect(pst.open);
        rig.end(&u);
    }
    // Frame 3: a press on an unrelated widget outside the popup.
    const other: Rect = .{ .x = 300, .y = 200, .w = 60, .h = 30 };
    rig.click(310, 210);
    {
        var u = rig.ui();
        if (u.hit(other).clicked) count += 1; // swallowed: the popup was open last frame
        try testing.expect(u.hit(other).hovered); // hover itself is not blocked outside the popup
        if (u.beginPopup(&pst, btn, .{ 160, 100 }, .{})) |_| u.endPopup();
        try testing.expect(!pst.open);
        rig.end(&u);
    }
    try testing.expectEqual(@as(usize, 0), count);
    // Frame 4: the popup is gone, the same press now reaches the widget.
    rig.click(310, 210);
    {
        var u = rig.ui();
        if (u.hit(other).clicked) count += 1;
        rig.end(&u);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "popup: non-dismissing popup lets outside presses through" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{ .open = true };
    const btn: Rect = .{ .x = 20, .y = 20, .w = 100, .h = 30 };
    const other: Rect = .{ .x = 300, .y = 200, .w = 60, .h = 30 };
    for (0..2) |_| {
        var u = rig.ui();
        if (u.beginPopup(&pst, btn, .{ 160, 100 }, .{ .dismiss_on_outside = false })) |_| u.endPopup();
        rig.end(&u);
    }
    rig.click(310, 210);
    var u = rig.ui();
    try testing.expect(u.hit(other).clicked);
    if (u.beginPopup(&pst, btn, .{ 160, 100 }, .{ .dismiss_on_outside = false })) |_| u.endPopup();
    try testing.expect(pst.open);
    rig.end(&u);
}

test "popup: modal blocks everything beneath, outside press does not dismiss when off" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{ .open = true };
    const far: Rect = .{ .x = 300, .y = 220, .w = 60, .h = 30 };
    const opts: PopupOpts = .{ .placement = .center, .modal = true, .dismiss_on_outside = false };
    for (0..2) |_| {
        var u = rig.ui();
        if (u.beginPopup(&pst, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .{ 200, 100 }, opts)) |_| u.endPopup();
        rig.end(&u);
    }
    rig.move(310, 230);
    rig.in.pressed = true;
    var u = rig.ui();
    try testing.expect(!u.hit(far).hovered);
    try testing.expect(!u.hit(far).clicked);
    if (u.beginPopup(&pst, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .{ 200, 100 }, opts)) |_| u.endPopup();
    try testing.expect(pst.open);
    rig.end(&u);
    // The backdrop is the first overlay command.
    var found = false;
    for (u.list.cmds.items) |cmd| switch (cmd) {
        .rrect => |r| if (r.rect.w == 400 and r.rect.h == 300 and r.color.a > 0) {
            found = true;
        },
        else => {},
    };
    try testing.expect(found);
}

test "popup: Escape closes the top popup only and is consumed" {
    var rig = Rig.init();
    defer rig.deinit();
    var parent: PopupState = .{};
    var child: PopupState = .{};
    const anchor: Rect = .{ .x = 20, .y = 20, .w = 60, .h = 24 };
    const frame = struct {
        fn run(r: *Rig, p: *PopupState, c: *PopupState, a: Rect) !void {
            var u = r.ui();
            if (u.beginPopup(p, a, .{ 200, 120 }, .{})) |content| {
                if (u.beginPopup(c, content, .{ 80, 50 }, .{ .placement = .right })) |_| u.endPopup();
                u.endPopup();
            }
            // After the popups, Escape must be gone from the Ui's queue when it was used.
            r.end(&u);
        }
    }.run;
    parent.open = true;
    parent.fresh = true;
    try frame(&rig, &parent, &child, anchor);
    // Open the child from within the parent.
    child.open = true; // no openPopup: adopt the parent
    child.fresh = true;
    try frame(&rig, &parent, &child, anchor);
    try frame(&rig, &parent, &child, anchor);
    try testing.expect(parent.open and child.open);
    rig.key(keys.escape);
    try frame(&rig, &parent, &child, anchor);
    try testing.expect(parent.open and !child.open); // only the top one
    rig.key(keys.escape);
    try frame(&rig, &parent, &child, anchor);
    try testing.expect(!parent.open);
}

test "popup: a nested popup does not outlive its parent being reopened, and an inside press keeps the parent" {
    var rig = Rig.init();
    defer rig.deinit();
    var parent: PopupState = .{};
    var child: PopupState = .{};
    const anchor: Rect = .{ .x = 20, .y = 20, .w = 60, .h = 24 };
    const frame = struct {
        fn run(r: *Rig, p: *PopupState, c: *PopupState, a: Rect) !void {
            var u = r.ui();
            if (u.beginPopup(p, a, .{ 200, 120 }, .{})) |content| {
                if (u.beginPopup(c, content, .{ 80, 50 }, .{ .placement = .below })) |_| u.endPopup();
                u.endPopup();
            }
            r.end(&u);
        }
    }.run;
    {
        var u = rig.ui();
        u.openPopup(&parent);
        u.finish();
    }
    try frame(&rig, &parent, &child, anchor);
    try frame(&rig, &parent, &child, anchor);
    {
        // Open the child the way an app does from inside the parent's body.
        var u = rig.ui();
        if (u.beginPopup(&parent, anchor, .{ 200, 120 }, .{})) |_| {
            u.openPopup(&child);
            u.endPopup();
        }
        u.finish();
    }
    try frame(&rig, &parent, &child, anchor);
    try frame(&rig, &parent, &child, anchor);
    try testing.expect(child.open);
    // Click inside the parent but outside the child: the child closes, the parent stays.
    const prect = place(anchor, 200, 120, .below, .start, 6, rig.bounds);
    rig.click(prect.x + 100, prect.y + 110);
    try frame(&rig, &parent, &child, anchor);
    try testing.expect(parent.open);
    try testing.expect(!child.open);
    // Reopen the child, then close and reopen the parent: the child is stale and closes.
    {
        var u = rig.ui();
        if (u.beginPopup(&parent, anchor, .{ 200, 120 }, .{})) |_| {
            u.openPopup(&child);
            u.endPopup();
        }
        u.finish();
        rig.in.endFrame();
    }
    try frame(&rig, &parent, &child, anchor);
    try testing.expect(child.open);
    parent.open = false;
    try frame(&rig, &parent, &child, anchor);
    try testing.expect(child.open); // flagged, but never drawn
    {
        var u = rig.ui();
        u.openPopup(&parent);
        u.finish();
    }
    try frame(&rig, &parent, &child, anchor);
    try testing.expect(!child.open);
}

test "popup: a press outside everything closes the whole chain" {
    var rig = Rig.init();
    defer rig.deinit();
    var parent: PopupState = .{};
    var child: PopupState = .{};
    const anchor: Rect = .{ .x = 20, .y = 20, .w = 60, .h = 24 };
    const frame = struct {
        fn run(r: *Rig, p: *PopupState, c: *PopupState, a: Rect) void {
            var u = r.ui();
            if (u.beginPopup(p, a, .{ 200, 120 }, .{})) |content| {
                if (u.beginPopup(c, content, .{ 80, 50 }, .{})) |_| u.endPopup();
                u.endPopup();
            }
            r.end(&u);
        }
    }.run;
    {
        var u = rig.ui();
        u.openPopup(&parent);
        if (u.beginPopup(&parent, anchor, .{ 200, 120 }, .{})) |_| {
            u.openPopup(&child);
            u.endPopup();
        }
        u.finish();
    }
    frame(&rig, &parent, &child, anchor);
    frame(&rig, &parent, &child, anchor);
    try testing.expect(parent.open and child.open);
    rig.click(380, 280);
    frame(&rig, &parent, &child, anchor);
    try testing.expect(!parent.open and !child.open);
}

fn menuFrame(rig: *Rig, st: *PopupState, anchor: Rect, items: []const MenuItem) ?usize {
    var u = rig.ui();
    const r = u.menu(st, anchor, items, .{});
    rig.end(&u);
    return r;
}

test "menu: keyboard navigation skips disabled items and separators; Enter returns the index" {
    var rig = Rig.init();
    defer rig.deinit();
    var st: PopupState = .{};
    const anchor: Rect = .{ .x = 20, .y = 20, .w = 60, .h = 24 };
    {
        var u = rig.ui();
        u.openPopup(&st);
        u.finish();
    }
    _ = menuFrame(&rig, &st, anchor, &test_items); // fresh frame
    try testing.expectEqual(@as(?usize, null), st.highlight);
    rig.key(keys.down);
    _ = menuFrame(&rig, &st, anchor, &test_items);
    try testing.expectEqual(@as(?usize, 0), st.highlight);
    rig.key(keys.down); // skips Copy (disabled) and the separator
    _ = menuFrame(&rig, &st, anchor, &test_items);
    try testing.expectEqual(@as(?usize, 3), st.highlight);
    rig.key(keys.down);
    _ = menuFrame(&rig, &st, anchor, &test_items);
    try testing.expectEqual(@as(?usize, 4), st.highlight);
    rig.key(keys.down); // no wrap: stays on the last
    _ = menuFrame(&rig, &st, anchor, &test_items);
    try testing.expectEqual(@as(?usize, 4), st.highlight);
    rig.key(keys.up);
    _ = menuFrame(&rig, &st, anchor, &test_items);
    try testing.expectEqual(@as(?usize, 3), st.highlight);
    rig.key(keys.home);
    _ = menuFrame(&rig, &st, anchor, &test_items);
    try testing.expectEqual(@as(?usize, 0), st.highlight);
    rig.key(keys.end);
    _ = menuFrame(&rig, &st, anchor, &test_items);
    try testing.expectEqual(@as(?usize, 4), st.highlight);
    rig.key(keys.up);
    rig.key(keys.@"return");
    const got = menuFrame(&rig, &st, anchor, &test_items);
    try testing.expectEqual(@as(?usize, 3), got);
    try testing.expect(!st.open); // activating closes
    // Escape closes without activating.
    {
        var u = rig.ui();
        u.openPopup(&st);
        u.finish();
    }
    _ = menuFrame(&rig, &st, anchor, &test_items);
    rig.key(keys.escape);
    try testing.expectEqual(@as(?usize, null), menuFrame(&rig, &st, anchor, &test_items));
    try testing.expect(!st.open);
}

test "menu: stepEnabled and an all-disabled menu" {
    const none = [_]MenuItem{ .{ .label = "a", .disabled = true }, .{ .separator = true } };
    try testing.expectEqual(@as(?usize, null), firstEnabled(&none));
    try testing.expectEqual(@as(?usize, null), lastEnabled(&none));
    try testing.expectEqual(@as(?usize, 3), lastEnabled(test_items[0..4]));
    try testing.expectEqual(@as(?usize, 0), stepEnabled(&test_items, null, 1));
}

test "menu: a click on an item activates it and closes; the opening frame cannot" {
    var rig = Rig.init();
    defer rig.deinit();
    var st: PopupState = .{};
    const anchor: Rect = .{ .x = 20, .y = 20, .w = 60, .h = 24 };
    // Opening click lands (by accident) right where the first item will be.
    const size = menuSize(&rig.ui(), &test_items, .{});
    const rect = place(anchor, size[0], size[1], .below, .start, 4, rig.bounds);
    const first_y = rect.y + menu_pad + 1 + 14;
    rig.click(rect.x + 30, first_y);
    {
        var u = rig.ui();
        u.openPopup(&st);
        try testing.expectEqual(@as(?usize, null), u.menu(&st, anchor, &test_items, .{}));
        try testing.expect(st.open);
        rig.end(&u);
    }
    rig.in.pressed = false;
    _ = menuFrame(&rig, &st, anchor, &test_items);
    // Click "Paste" (index 3): top + item 0 (28) + item 1 (28) + sep (9) + 14.
    const paste_y = rect.y + menu_pad + 1 + 28 + 28 + 9 + 14;
    rig.click(rect.x + 30, paste_y);
    try testing.expectEqual(@as(?usize, 3), menuFrame(&rig, &st, anchor, &test_items));
    try testing.expect(!st.open);
    // A disabled item (Copy) does nothing.
    {
        var u = rig.ui();
        u.openPopup(&st);
        u.finish();
    }
    _ = menuFrame(&rig, &st, anchor, &test_items);
    rig.click(rect.x + 30, rect.y + menu_pad + 1 + 28 + 14);
    try testing.expectEqual(@as(?usize, null), menuFrame(&rig, &st, anchor, &test_items));
    try testing.expect(st.open);
}

test "contextMenu: right click inside the area opens it at the pointer" {
    var rig = Rig.init();
    defer rig.deinit();
    var st: PopupState = .{};
    const area: Rect = .{ .x = 10, .y = 10, .w = 200, .h = 100 };
    rig.move(50, 60);
    rig.in.right_pressed = true;
    {
        var u = rig.ui();
        try testing.expectEqual(@as(?usize, null), u.contextMenu(&st, area, &test_items, .{}));
        try testing.expect(st.open);
        try testing.expectEqual(@as(f32, 50), st.point[0]);
        rig.end(&u);
    }
    // The menu rectangle starts at the pointer.
    try testing.expectEqual(@as(f32, 50), rig.state.popups.last()[0].rect.x);
    try testing.expectEqual(@as(f32, 60), rig.state.popups.last()[0].rect.y);
    // A right click outside the area does not open another.
    var st2: PopupState = .{};
    rig.in.right_pressed = false;
    rig.move(300, 200);
    rig.in.right_pressed = true;
    var u = rig.ui();
    _ = u.contextMenu(&st2, area, &test_items, .{});
    try testing.expect(!st2.open);
    rig.end(&u);
}

test "dropdown: click opens, picking an item changes the selection and puts a check on the current one" {
    var rig = Rig.init();
    defer rig.deinit();
    var dd: DropdownState = .{};
    var sel: usize = 1;
    const items = [_][]const u8{ "Small", "Medium", "Large" };
    const r: Rect = .{ .x = 20, .y = 20, .w = 140, .h = 30 };
    const frame = struct {
        fn run(rg: *Rig, d: *DropdownState, s: *usize, rr: Rect) bool {
            var u = rg.ui();
            const ch = u.dropdown(rr, d, &items, s, .{});
            rg.end(&u);
            return ch;
        }
    }.run;
    rig.click(40, 35);
    try testing.expect(!frame(&rig, &dd, &sel, r));
    try testing.expect(dd.popup.open);
    try testing.expectEqual(@as(?usize, 1), dd.popup.highlight);
    try testing.expect(rig.state.focus == @as(?*const anyopaque, &dd));
    rig.in.down = false;
    try testing.expect(!frame(&rig, &dd, &sel, r));
    // Menu rows: width = control width; first item top = control bottom + gap + padding.
    const rect = rig.state.popups.last()[0].rect;
    try testing.expectEqual(@as(f32, 140), rect.w);
    try testing.expectEqual(@as(f32, 54), rect.y);
    rig.click(rect.x + 20, rect.y + menu_pad + 1 + 28 * 2 + 14); // "Large"
    try testing.expect(frame(&rig, &dd, &sel, r));
    try testing.expectEqual(@as(usize, 2), sel);
    try testing.expect(!dd.popup.open);
    // Clicking the current item changes nothing.
    rig.in.down = false;
    rig.click(40, 35);
    _ = frame(&rig, &dd, &sel, r);
    _ = frame(&rig, &dd, &sel, r);
    rig.click(rect.x + 20, rect.y + menu_pad + 1 + 28 * 2 + 14);
    try testing.expect(!frame(&rig, &dd, &sel, r));
    try testing.expect(!dd.popup.open);
}

test "dropdown: keyboard changes selection when focused and closed, Enter opens" {
    var rig = Rig.init();
    defer rig.deinit();
    var dd: DropdownState = .{};
    var other: DropdownState = .{};
    var sel: usize = 0;
    var sel2: usize = 0;
    const items = [_][]const u8{ "A", "B", "C" };
    const r: Rect = .{ .x = 20, .y = 20, .w = 140, .h = 30 };
    const r2: Rect = .{ .x = 20, .y = 100, .w = 140, .h = 30 };
    rig.state.focus = &dd;
    rig.key(keys.down);
    {
        var u = rig.ui();
        try testing.expect(u.dropdown(r, &dd, &items, &sel, .{}));
        try testing.expect(!u.dropdown(r2, &other, &items, &sel2, .{})); // not focused: unchanged
        rig.end(&u);
    }
    try testing.expectEqual(@as(usize, 1), sel);
    try testing.expectEqual(@as(usize, 0), sel2);
    rig.key(keys.down);
    rig.key(keys.down); // clamps at the last
    {
        var u = rig.ui();
        _ = u.dropdown(r, &dd, &items, &sel, .{});
        rig.end(&u);
    }
    try testing.expectEqual(@as(usize, 2), sel);
    rig.key(keys.up);
    {
        var u = rig.ui();
        try testing.expect(u.dropdown(r, &dd, &items, &sel, .{}));
        rig.end(&u);
    }
    try testing.expectEqual(@as(usize, 1), sel);
    rig.key(keys.@"return");
    {
        var u = rig.ui();
        _ = u.dropdown(r, &dd, &items, &sel, .{});
        rig.end(&u);
    }
    try testing.expect(dd.popup.open);
    // Disabled: no input at all.
    var dis: DropdownState = .{};
    var sel3: usize = 0;
    rig.state.focus = &dis;
    rig.key(keys.down);
    {
        var u = rig.ui();
        try testing.expect(!u.dropdown(r2, &dis, &items, &sel3, .{ .disabled = true }));
        rig.end(&u);
    }
    try testing.expectEqual(@as(usize, 0), sel3);
}

test "tooltip: appears only after the delay, hides on leave and on press" {
    var rig = Rig.init();
    defer rig.deinit();
    const r: Rect = .{ .x = 50, .y = 50, .w = 24, .h = 24 };
    const frame = struct {
        fn run(rg: *Rig, rr: Rect, time: f64) usize {
            rg.in.time = time;
            var u = rg.ui();
            u.tooltip(rr, "Attach a file", .{});
            rg.end(&u);
            return rg.list.cmds.items.len;
        }
    }.run;
    rig.move(60, 60);
    try testing.expectEqual(@as(usize, 0), frame(&rig, r, 10.0));
    try testing.expect(rig.state.needsRedraw());
    try testing.expectEqual(@as(usize, 0), frame(&rig, r, 10.3));
    try testing.expect(frame(&rig, r, 10.6) > 0); // 0.6 s of resting
    try testing.expect(!rig.state.needsRedraw());
    try testing.expect(frame(&rig, r, 10.7) > 0);
    // Leaving hides it and restarts the timer.
    rig.move(300, 200);
    try testing.expectEqual(@as(usize, 0), frame(&rig, r, 10.8));
    rig.move(60, 60);
    try testing.expectEqual(@as(usize, 0), frame(&rig, r, 11.0));
    try testing.expectEqual(@as(usize, 0), frame(&rig, r, 11.3));
    try testing.expect(frame(&rig, r, 11.6) > 0);
    // A press hides it until the pointer leaves.
    rig.in.pressed = true;
    try testing.expectEqual(@as(usize, 0), frame(&rig, r, 11.7));
    try testing.expectEqual(@as(usize, 0), frame(&rig, r, 15.0));
    // A tooltip never takes input: it records no popup rectangle, so a click on the rectangle
    // is still a click for the widget underneath.
    try testing.expectEqual(@as(usize, 0), rig.state.popups.last().len);
}

test "tooltip: does not show where a popup covers its rectangle" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{ .open = true };
    const covered: Rect = .{ .x = 30, .y = 80, .w = 20, .h = 20 };
    rig.move(40, 90);
    var shown = false;
    for ([_]f64{ 5, 6, 7, 8 }) |tm| {
        rig.in.time = tm;
        var u = rig.ui();
        u.tooltip(covered, "hidden", .{});
        if (u.beginPopup(&pst, .{ .x = 20, .y = 20, .w = 60, .h = 24 }, .{ 200, 150 }, .{})) |_| u.endPopup();
        rig.end(&u);
        for (rig.list.cmds.items) |cmd| switch (cmd) {
            .text => |t| if (std.mem.eql(u8, t.str, "hidden")) {
                shown = true;
            },
            else => {},
        };
    }
    try testing.expect(!shown);
    // Without the popup the same pointer position does show it.
    pst.open = false;
    for ([_]f64{ 9, 10, 11 }) |tm| {
        rig.in.time = tm;
        var u = rig.ui();
        u.tooltip(covered, "hidden", .{});
        rig.end(&u);
        for (rig.list.cmds.items) |cmd| switch (cmd) {
            .text => |t| if (std.mem.eql(u8, t.str, "hidden")) {
                shown = true;
            },
            else => {},
        };
    }
    try testing.expect(shown);
}

test "tooltip: geometry below, flipped above near the bottom" {
    var rig = Rig.init();
    defer rig.deinit();
    const bottom: Rect = .{ .x = 50, .y = 270, .w = 24, .h = 24 };
    rig.move(60, 280);
    var rect_y: f32 = 0;
    for ([_]f64{ 1, 2 }) |tm| {
        rig.in.time = tm;
        var u = rig.ui();
        u.tooltip(bottom, "Tip", .{});
        rig.end(&u);
    }
    // The shadow is first, then the border rect, then the fill; the border has the panel size.
    for (rig.list.cmds.items) |cmd| switch (cmd) {
        .rrect => |r| if (r.color.a == 255 and r.radius == 7) {
            rect_y = r.rect.y;
        },
        else => {},
    };
    try testing.expect(rect_y > 0 and rect_y + 10 < bottom.y); // above the anchor
}

test "finish: overlay commands come after the main ones in the final list" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{ .open = true };
    pst.fresh = true;
    var u = rig.ui();
    if (u.beginPopup(&pst, .{ .x = 10, .y = 10, .w = 40, .h = 20 }, .{ 100, 60 }, .{})) |_| {
        u.list.text(0, 0, 10, .{ .r = 9, .g = 9, .b = 9 }, .left, "in popup");
        u.endPopup();
    }
    u.list.text(0, 0, 10, .{ .r = 9, .g = 9, .b = 9 }, .left, "main");
    u.finish();
    var seen_popup = false;
    var main_idx: usize = 0;
    var popup_idx: usize = 0;
    for (u.list.cmds.items, 0..) |cmd, i| switch (cmd) {
        .text => |t| {
            if (std.mem.eql(u8, t.str, "main")) main_idx = i;
            if (std.mem.eql(u8, t.str, "in popup")) {
                popup_idx = i;
                seen_popup = true;
            }
        },
        else => {},
    };
    try testing.expect(seen_popup);
    try testing.expect(popup_idx > main_idx);
    try testing.expectEqual(@as(usize, 0), u.list.overlay[0].items.len);
}

test "nested popups draw into higher layers than their parent" {
    var rig = Rig.init();
    defer rig.deinit();
    var parent: PopupState = .{ .open = true, .fresh = true };
    var child: PopupState = .{ .open = true, .fresh = true };
    var u = rig.ui();
    const c = u.beginPopup(&parent, .{ .x = 10, .y = 10, .w = 40, .h = 20 }, .{ 200, 140 }, .{}).?;
    try testing.expectEqual(@as(u8, 1), u.layer);
    const c2 = u.beginPopup(&child, c, .{ 80, 60 }, .{ .placement = .below }).?;
    try testing.expectEqual(@as(u8, 2), u.layer);
    try testing.expectEqual(@as(u8, 2), u.list.layer);
    u.list.text(0, 0, 10, .{ .r = 1, .g = 1, .b = 1 }, .left, "child");
    _ = c2;
    u.endPopup();
    try testing.expectEqual(@as(u8, 1), u.layer);
    u.list.text(0, 0, 10, .{ .r = 1, .g = 1, .b = 1 }, .left, "parent again"); // after the child, still layer 1
    u.endPopup();
    try testing.expectEqual(@as(u8, 0), u.layer);
    u.finish();
    var child_i: usize = 0;
    var parent_i: usize = 0;
    for (u.list.cmds.items, 0..) |cmd, i| switch (cmd) {
        .text => |t| {
            if (std.mem.eql(u8, t.str, "child")) child_i = i;
            if (std.mem.eql(u8, t.str, "parent again")) parent_i = i;
        },
        else => {},
    };
    try testing.expect(child_i > parent_i); // the child is above even though drawn earlier
}

test "popup clips: the clip of the declaring scroll area does not apply inside, and is restored" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{ .open = true, .fresh = true };
    var u = rig.ui();
    u.pushClip(.{ .x = 0, .y = 0, .w = 50, .h = 50 });
    try testing.expect(u.clip() != null);
    _ = u.beginPopup(&pst, .{ .x = 10, .y = 10, .w = 20, .h = 20 }, .{ 100, 80 }, .{}).?;
    try testing.expect(u.clip() == null);
    u.pushClip(.{ .x = 20, .y = 20, .w = 10, .h = 10 });
    try testing.expectEqual(@as(f32, 10), u.clip().?.w);
    u.popClip();
    u.endPopup();
    try testing.expectEqual(@as(f32, 50), u.clip().?.w);
    u.popClip();
    u.finish();
}

test "a text field under a popup does not see keys or presses" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{ .open = true, .fresh = true };
    var field = ui_mod.TextFieldState.init(testing.allocator);
    defer field.deinit();
    const fr: Rect = .{ .x = 10, .y = 200, .w = 200, .h = 28 };
    rig.state.focus = &field;
    {
        var u = rig.ui();
        _ = u.textField(fr, &field, .{});
        if (u.beginPopup(&pst, .{ .x = 10, .y = 10, .w = 40, .h = 20 }, .{ 100, 60 }, .{})) |_| u.endPopup();
        rig.end(&u);
    }
    rig.in.pushText("x");
    rig.key(keys.escape);
    {
        var u = rig.ui();
        _ = u.textField(fr, &field, .{}); // typed text is not delivered under an open popup
        try testing.expectEqual(@as(usize, 0), field.edit.text().len);
        try testing.expect(rig.state.focus == @as(?*const anyopaque, &field)); // Escape did not blur it
        if (u.beginPopup(&pst, .{ .x = 10, .y = 10, .w = 40, .h = 20 }, .{ 100, 60 }, .{})) |_| u.endPopup();
        rig.end(&u);
    }
    try testing.expect(!pst.open);
    // Closed now; the same input would work (next frame the popup is gone from `prev`).
    rig.in.pushText("y");
    var u = rig.ui();
    _ = u.textField(fr, &field, .{});
    try testing.expectEqualStrings("y", field.edit.text());
    rig.end(&u);
}

test "the wheel does not scroll an area under a popup" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{ .open = true, .fresh = true };
    var sc: ui_mod.ScrollState = .{};
    const area: Rect = .{ .x = 0, .y = 100, .w = 200, .h = 100 };
    for (0..2) |_| {
        var u = rig.ui();
        _ = u.beginScroll(area, &sc, 400);
        u.endScroll();
        if (u.beginPopup(&pst, .{ .x = 10, .y = 80, .w = 40, .h = 20 }, .{ 180, 100 }, .{ .placement = .below })) |_| u.endPopup();
        rig.end(&u);
    }
    rig.move(50, 150);
    rig.in.wheel_y = -2;
    var u = rig.ui();
    _ = u.beginScroll(area, &sc, 400);
    u.endScroll();
    try testing.expectEqual(@as(f32, 0), sc.offset);
    rig.end(&u);
}

test "undo and redo work in a text field hosted by a popup" {
    var rig = Rig.init();
    defer rig.deinit();
    var pst: PopupState = .{ .open = true, .fresh = true };
    var field = ui_mod.TextFieldState.init(testing.allocator);
    defer field.deinit();
    const anchor: Rect = .{ .x = 10, .y = 10, .w = 40, .h = 20 };
    const fr: Rect = .{ .x = 20, .y = 40, .w = 120, .h = 28 };
    rig.state.focus = &field;
    // The first frames open the popup (its layer takes input from the frame after).
    for (0..2) |_| {
        var u = rig.ui();
        if (u.beginPopup(&pst, anchor, .{ 160, 100 }, .{})) |_| {
            _ = u.textField(fr, &field, .{});
            u.endPopup();
        }
        rig.end(&u);
    }
    try testing.expect(pst.open);
    const frame = struct {
        fn run(r: *Rig, p: *PopupState, anc: Rect, rect: Rect, fld: *ui_mod.TextFieldState) bool {
            var u = r.ui();
            var changed = false;
            if (u.beginPopup(p, anc, .{ 160, 100 }, .{})) |_| {
                changed = u.textField(rect, fld, .{}).changed;
                u.endPopup();
            }
            r.end(&u);
            return changed;
        }
    }.run;
    rig.in.pushText("abc");
    try testing.expect(frame(&rig, &pst, anchor, fr, &field));
    try testing.expectEqualStrings("abc", field.edit.text());
    rig.in.pushKey(keys.z, .{ .cmd = true });
    try testing.expect(frame(&rig, &pst, anchor, fr, &field));
    try testing.expectEqualStrings("", field.edit.text());
    rig.in.pushKey(keys.z, .{ .cmd = true, .shift = true });
    try testing.expect(frame(&rig, &pst, anchor, fr, &field));
    try testing.expectEqualStrings("abc", field.edit.text());
    try testing.expect(pst.open);
}
