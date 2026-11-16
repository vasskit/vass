//! Keyboard focus: Tab traversal, focus ids for stateless widgets, the focus ring and the
//! per-frame list of focusable widgets (also the groundwork for accessibility).
//!
//! ## Identity
//!
//! A focus id (`FocusId`, a `u64`) names one focusable widget across frames.
//!
//! * Widgets that own state (`textField`, `textArea`, `dropdown`) use the address of their state
//!   struct, as before; value-bound widgets (`checkbox`, `toggle`, `slider`, `segmented`, `tabs`)
//!   use the address of the bound value (`*bool`, `*f32`, `*usize`). `State.focus` still holds
//!   these as plain pointers, so `State.focusOn(&state)` and `state.focus == &state` keep working.
//! * Stateless widgets (`button`, `iconButton`, `chip`, `pill`, `radio`, `listRow`) derive an id:
//!   `hash(id stack, widget kind, key)`, then, when several widgets of one kind produce the same
//!   hash in one frame, the occurrence number (first, second, ...). The key is the explicit
//!   `opts.id` if there is one, else the label (or the icon). The rectangle is never hashed, so
//!   ids survive resizing and scrolling. `Ui.pushId` / `Ui.popId` open an id scope: the same label
//!   in two scopes gives two ids. Two rows with the same label in the same scope are told apart by
//!   their order, which is stable as long as the structure does not change; give them an explicit
//!   `id` (`vass.ui.idKey(row.key)`) when they can be reordered or when the label changes.
//! * Derived ids have bit 63 set, so they can never equal the address of a state struct. A derived
//!   id is stored in `State.focus` as a pseudo pointer (never dereferenced).
//! * Collisions degrade safely: the first widget that registers an id in a frame owns it; a second
//!   one with the same id is inert (never focused, never activated by keys). Mouse clicks still work.
//!
//! ## Traversal
//!
//! Each frame, every focusable widget registers itself (`Ui.focusable`) in call order. Tab and
//! Shift+Tab, processed by the first focus-aware widget of the frame, move focus through the
//! entries of the *previous* frame (`State.reg`), wrapping around, skipping disabled ones. Only
//! the topmost open popup's entries take part while a popup is open. The Tab key is removed from
//! the frame's events. A widget that is not declared in a frame (scrolled out and culled, collapsed)
//! cannot be reached by Tab, and focus on a widget that vanishes is cleared.
//!
//! ## Keys
//!
//! One rule: a widget that acts on a key press removes that event from the frame's queue (`Ui.takeKey`),
//! so code that reads `Ui.events()` afterwards does not see it. Code that runs *before* the widgets
//! (a shortcut handler at the top of the frame, `Ui.beginScroll`) asks `Ui.keyClaimed` whether the
//! focused widget wants a key. Text widgets claim every key without Cmd (and the editing keys with it).
//! Typed text is never claimed by anything but text widgets.
const std = @import("std");
const geom = @import("geom.zig");
const icons = @import("icons.zig");
const keys = @import("keys.zig");
const backend = @import("backend_sdl.zig");
const ui_mod = @import("ui.zig");
const Rect = geom.Rect;
const Ui = ui_mod.Ui;
const State = ui_mod.State;

pub const FocusId = u64;

/// Set on every derived id; no address has it.
pub const derived_bit: FocusId = @as(FocusId, 1) << 63;

/// Most widgets remembered per frame; further ones still work with the mouse, but Tab skips them.
pub const max_entries = 256;
/// Longest label kept per entry (longer ones are cut on a character boundary).
pub const max_label = 40;
/// Deepest nest of scroll areas recorded for one entry.
pub const max_scrolls = 4;

/// What kind of control an entry is (for keyboard rules now, assistive technology later).
pub const Role = enum {
    button,
    checkbox,
    toggle,
    radio,
    /// Tabs and segmented controls: one stop, Left/Right change the selection.
    tab,
    slider,
    text_field,
    text_area,
    dropdown,
    menu_item,
    list_row,
    link,
    other,
};

/// A scroll area an entry sits in: its view rectangle and the state `reveal` scrolls.
pub const ScrollRef = struct { state: *ui_mod.ScrollState, view: Rect };

/// One focusable widget as of one frame.
pub const Entry = struct {
    id: FocusId,
    rect: Rect,
    role: Role,
    /// Popup layer it was declared in (0 = the main stream).
    layer: u8,
    disabled: bool,
    /// Plain Tab belongs to the widget (a text area with `tab_inserts`).
    captures_tab: bool,
    /// Scroll areas it is inside, outermost first. Only valid during the frame it was declared.
    scroll_n: u8,
    scrolls: [max_scrolls]ScrollRef,
    label_len: u8,
    label_buf: [max_label]u8,

    /// The widget's label (copied, so it outlives the caller's buffer); "" for icon-only widgets.
    pub fn label(e: *const Entry) []const u8 {
        return e.label_buf[0..e.label_len];
    }
};

/// The focusable widgets of the frame being drawn and of the one before, plus the focus-ring state.
pub const Registry = struct {
    bufs: [2][max_entries]Entry = undefined,
    lens: [2]u16 = .{ 0, 0 },
    cur_i: u1 = 0,
    /// A frame is being collected (its first widget has registered, `finish` has not run yet).
    open: bool = false,
    /// Focus arrived by keyboard since the last mouse press: draw the focus ring.
    visible: bool = false,
    /// Focus moved by keyboard or code: scroll the widget into view when it registers.
    reveal_pending: bool = false,
    /// Focus as of the end of the previous frame.
    end_focus: ?*const anyopaque = null,
    /// Focus as the last widget registration saw it (to tell code that moved focus between
    /// frames from a widget that vanished).
    seen_focus: ?*const anyopaque = null,
    /// Widgets that lost focus after they were drawn this / last frame.
    carry_lost: ?*const anyopaque = null,
    lost_last: ?*const anyopaque = null,

    /// Last completed frame's entries, in declaration order.
    pub fn last(r: *const Registry) []const Entry {
        const i = r.cur_i ^ 1;
        return r.bufs[i][0..r.lens[i]];
    }

    fn current(r: *Registry) []Entry {
        return r.bufs[r.cur_i][0..r.lens[r.cur_i]];
    }

    fn add(r: *Registry, e: Entry) void {
        if (r.lens[r.cur_i] >= max_entries) return;
        r.bufs[r.cur_i][r.lens[r.cur_i]] = e;
        r.lens[r.cur_i] += 1;
    }
};

pub const FocusOpts = struct {
    role: Role = .other,
    /// Skipped by Tab, never focused or activated.
    disabled: bool = false,
    /// Corner radius of the widget (the ring is drawn around it at a larger radius).
    ring_radius: f32 = 6,
    /// Gap between the widget and the ring in points.
    ring_offset: f32 = 2,
    /// For assistive technology and tests; copied.
    label: []const u8 = "",
    /// Draw the ring now (call `focusable` after drawing the widget). Off: draw it yourself
    /// with `Ui.focusRing` when `FocusResult.visible`.
    ring: bool = true,
    /// Enter and Space (consumed) set `FocusResult.activated`.
    activate: bool = true,
    /// A click on `r` focuses the widget, a click elsewhere blurs it. Off for widgets that
    /// handle the mouse themselves (text fields).
    click_focus: bool = true,
    /// Plain Tab (without Shift) is the widget's own key and is left in the events.
    captures_tab: bool = false,
};

pub const FocusResult = struct {
    /// The widget has keyboard focus.
    focused: bool = false,
    /// Enter or Space was pressed while focused (the key is consumed). Treat as a click.
    activated: bool = false,
    /// Focus arrived since the end of the previous frame.
    gained: bool = false,
    /// Focus left since the end of the previous frame.
    lost: bool = false,
    /// The ring should be shown (focused, and focus came from the keyboard).
    visible: bool = false,
};

// ---- ids -------------------------------------------------------------------------------------

pub fn idOfPtr(p: *const anyopaque) FocusId {
    return @intFromPtr(p);
}

pub fn ptrOfId(id: FocusId) *const anyopaque {
    return @ptrFromInt(id);
}

fn bytesHash(seed: u64, bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

fn intHash(seed: u64, v: u64) u64 {
    return std.hash.Wyhash.hash(seed, std.mem.asBytes(&v));
}

/// Hashes a key (an integer, enum, bool, string, or the address a pointer holds) for use as
/// an explicit id (`opts.id`) or an `Ui.pushId` scope. Equal inputs always give equal keys.
pub fn idKey(x: anytype) u64 {
    return hashInto(0x9e3779b97f4a7c15, x);
}

pub fn hashInto(seed: u64, x: anytype) u64 {
    const T = @TypeOf(x);
    switch (@typeInfo(T)) {
        .int => |i| return intHash(seed, if (i.signedness == .signed) @as(u64, @bitCast(@as(i64, x))) else @as(u64, x)),
        .comptime_int => return intHash(seed, @as(u64, @bitCast(@as(i64, x)))),
        .bool => return intHash(seed, @intFromBool(x)),
        .@"enum" => return intHash(seed, @intFromEnum(x)),
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child != u8) @compileError("idKey: slices must be strings");
                return bytesHash(seed, x);
            },
            .one => switch (@typeInfo(p.child)) {
                .array => |a| {
                    if (a.child != u8) @compileError("idKey: arrays must be strings");
                    return bytesHash(seed, x);
                },
                else => return intHash(seed, @intFromPtr(x)),
            },
            else => return intHash(seed, @intFromPtr(x)),
        },
        else => @compileError("idKey: unsupported key type " ++ @typeName(T)),
    }
}

/// A key for an icon (built-in or SVG handle).
pub fn iconKey(src: icons.Source) u64 {
    return switch (src) {
        .builtin => |i| intHash(1, @intFromEnum(i)),
        .svg => |s| intHash(2, s.id),
    };
}

fn finalize(h: u64) FocusId {
    return h | derived_bit;
}

fn find(list: []const Entry, id: FocusId) ?*const Entry {
    for (list) |*e| if (e.id == id) return e;
    return null;
}

/// The id for a stateless widget: see the module comment. `tag` names the widget kind, `key`
/// is its label or icon hash, `explicit` the caller's `opts.id`.
pub fn autoId(ui: *Ui, tag: u64, key: u64, explicit: ?u64) FocusId {
    const base = ui.id_base;
    if (explicit) |e| return finalize(intHash(intHash(base, tag), e));
    const k = intHash(intHash(base, tag), key);
    const s = ui.state orelse return finalize(intHash(k, 0));
    frameBegin(ui, s);
    const cur = s.reg.current();
    var n: u64 = 0;
    while (true) : (n += 1) {
        const id = finalize(intHash(k, n));
        if (find(cur, id) == null) return id;
    }
}

// ---- per-frame bookkeeping -------------------------------------------------------------------

/// Starts the frame for focus purposes (once per `Ui`): rotates the entry lists if the previous
/// frame did not call `finish`, hides the ring on a mouse press, and handles Tab.
pub fn frameBegin(ui: *Ui, s: *State) void {
    if (ui.focus_begun) return;
    ui.focus_begun = true;
    const reg = &s.reg;
    if (reg.open) rotate(s, false);
    reg.open = true;
    if (ui.input.pressed or ui.input.right_pressed) reg.visible = false;
    processTab(ui, s);
}

/// Ends the collection of a frame (called by `Ui.finish`, or by the next frame's first widget).
/// Focus on a widget that was not declared is cleared.
pub fn rotate(s: *State, explicit: bool) void {
    const reg = &s.reg;
    // `explicit`: the frame is known to be over (`finish`). Otherwise this runs at the start of the
    // next frame, and code may have moved focus since (`focusOn` a widget not drawn yet): leave that.
    if (s.focus) |f| {
        if ((explicit or s.focus == reg.seen_focus) and find(reg.current(), idOfPtr(f)) == null) s.focus = null;
    }
    reg.cur_i ^= 1;
    reg.lens[reg.cur_i] = 0;
    reg.open = false;
    reg.reveal_pending = false;
    reg.end_focus = s.focus;
    reg.lost_last = reg.carry_lost;
    reg.carry_lost = null;
}

fn setRaw(s: *State, p: ?*const anyopaque) void {
    const old = s.focus;
    s.focus = p;
    if (old) |o| if (o != p) {
        if (find(s.reg.current(), idOfPtr(o)) != null) s.reg.carry_lost = o;
    };
}

fn topLayer(s: *const State) u8 {
    var top: u8 = 0;
    for (s.popups.last()) |p| top = @max(top, p.layer);
    return top;
}

fn focusedEntry(s: *State) ?*const Entry {
    const f = s.focus orelse return null;
    const id = idOfPtr(f);
    return find(s.reg.current(), id) orelse find(s.reg.last(), id);
}

/// Moves focus to the next (`dir` > 0) or previous entry of the last frame in the topmost layer.
/// Without focus, forward goes to the first entry and backward to the last. False if nothing
/// can take focus.
fn moveFocus(s: *State, dir: i32) bool {
    const top = topLayer(s);
    const list = s.reg.last();
    var cand: [max_entries]u16 = undefined;
    var n: usize = 0;
    var pos: ?usize = null;
    const cur: ?FocusId = if (s.focus) |f| idOfPtr(f) else null;
    for (list, 0..) |e, i| {
        if (e.layer != top or e.disabled) continue;
        if (cur != null and e.id == cur.?) pos = n;
        cand[n] = @intCast(i);
        n += 1;
    }
    if (n == 0) return false;
    const pick: usize = if (pos) |p|
        (if (dir > 0) (p + 1) % n else (p + n - 1) % n)
    else if (dir > 0) 0 else n - 1;
    setRaw(s, ptrOfId(list[cand[pick]].id));
    s.reg.visible = true;
    s.reg.reveal_pending = true;
    return true;
}

fn plainMods(m: keys.Mods) bool {
    return !m.cmd and !m.ctrl and !m.alt;
}

fn processTab(ui: *Ui, s: *State) void {
    const q = &ui.input;
    var i: usize = 0;
    while (i < q.queue_len) {
        const ev = q.queue[i];
        if (ev == .key and ev.key.code == keys.tab and plainMods(ev.key.mods)) {
            const shift = ev.key.mods.shift;
            const captured = !shift and if (focusedEntry(s)) |e| e.captures_tab else false;
            if (!captured) {
                q.removeEvent(i);
                _ = moveFocus(s, if (shift) -1 else 1);
                continue;
            }
        }
        i += 1;
    }
}

// ---- public Ui-level operations --------------------------------------------------------------

pub fn focusNext(ui: *Ui) void {
    const s = ui.state orelse return;
    frameBegin(ui, s);
    _ = moveFocus(s, 1);
}

pub fn focusPrev(ui: *Ui) void {
    const s = ui.state orelse return;
    frameBegin(ui, s);
    _ = moveFocus(s, -1);
}

pub fn setFocus(ui: *Ui, id: FocusId) void {
    const s = ui.state orelse return;
    frameBegin(ui, s);
    setRaw(s, ptrOfId(id));
    s.reg.reveal_pending = true;
}

pub fn isFocused(ui: *const Ui, id: FocusId) bool {
    const s = ui.state orelse return false;
    return s.focus == ptrOfId(id);
}

pub fn focusedId(ui: *const Ui) ?FocusId {
    const s = ui.state orelse return null;
    return if (s.focus) |f| idOfPtr(f) else null;
}

pub fn focusVisible(ui: *const Ui) bool {
    const s = ui.state orelse return false;
    return s.reg.visible;
}

/// Removes and returns the first key press of this frame (for the layer being drawn) whose code is
/// in `codes` and whose modifiers are at most Shift. Marks the ring visible. Only call it for a
/// widget that has focus.
pub fn takeKey(ui: *Ui, codes: []const u32) ?backend.Key {
    const evs = ui.events();
    for (evs, 0..) |ev, i| switch (ev) {
        .key => |k| {
            if (!plainMods(k.mods)) continue;
            for (codes) |c| if (c == k.code) {
                ui.input.removeEvent(i);
                if (ui.state) |s| s.reg.visible = true;
                return k;
            };
        },
        else => {},
    };
    return null;
}

fn roleClaims(role: Role, code: u32, m: keys.Mods) bool {
    switch (role) {
        .text_field, .text_area => {
            if (code == keys.tab) return false;
            if (m.cmd) return switch (code) {
                keys.a, keys.c, keys.x, keys.v, keys.z, keys.left, keys.right, keys.up, keys.down, keys.backspace, keys.delete => true,
                else => false,
            };
            return true;
        },
        else => {},
    }
    if (!plainMods(m)) return false;
    return switch (role) {
        .tab => code == keys.left or code == keys.right or code == keys.home or code == keys.end,
        .slider => code == keys.left or code == keys.right or code == keys.up or code == keys.down or code == keys.home or code == keys.end,
        .dropdown => code == keys.up or code == keys.down or code == keys.@"return" or code == keys.space,
        else => code == keys.@"return" or code == keys.space,
    };
}

/// True if the focused widget wants this key (as of the widgets' last registration). For code that
/// runs before the widgets of the frame; widgets drawn first consume their keys themselves.
pub fn keyClaimed(ui: *const Ui, code: u32, mods: keys.Mods) bool {
    const s = ui.state orelse return false;
    if (s.focus == null) return false;
    const e = focusedEntry(s) orelse return roleClaims(.text_field, code, mods); // unknown: be safe
    if (e.disabled) return false;
    return roleClaims(e.role, code, mods);
}

// ---- the primitive ---------------------------------------------------------------------------

fn copyLabel(e: *Entry, str: []const u8) void {
    var n = @min(str.len, max_label);
    // Do not cut a UTF-8 sequence in half.
    if (n < str.len) while (n > 0 and str[n] & 0xC0 == 0x80) : (n -= 1) {};
    @memcpy(e.label_buf[0..n], str[0..n]);
    e.label_len = @intCast(n);
}

/// Registers a focusable widget occupying `r` and handles focus for it: click to focus, a click
/// elsewhere to blur, Enter / Space activation, scroll-into-view when focus arrived by keyboard,
/// and the focus ring. Call it every frame the widget is declared, after drawing it (or with
/// `opts.ring = false` before, then `Ui.focusRing`). Needs `ui.state`: without one nothing is
/// ever focused.
pub fn focusable(ui: *Ui, id: FocusId, r: Rect, opts: FocusOpts) FocusResult {
    var res: FocusResult = .{};
    const s = ui.state orelse return res;
    frameBegin(ui, s);
    const reg = &s.reg;
    if (find(reg.current(), id) != null) return res; // first one wins
    const ptr = ptrOfId(id);

    var e: Entry = .{
        .id = id,
        .rect = r,
        .role = opts.role,
        .layer = ui.layer,
        .disabled = opts.disabled,
        .captures_tab = opts.captures_tab,
        .scroll_n = 0,
        .scrolls = undefined,
        .label_len = 0,
        .label_buf = undefined,
    };
    copyLabel(&e, opts.label);
    for (ui.scrolls[ui.scroll_base..ui.scroll_n]) |f| {
        if (e.scroll_n >= max_scrolls) break;
        e.scrolls[e.scroll_n] = .{ .state = f.state, .view = f.rect };
        e.scroll_n += 1;
    }
    reg.add(e);

    var focused = s.focus == ptr;
    if (opts.disabled) {
        if (focused) {
            setRaw(s, null);
            focused = false;
        }
    } else if (opts.click_focus) {
        if (ui.hit(r).clicked) {
            setRaw(s, ptr);
            s.select = null;
            focused = true;
        } else if (focused and ui.pressedNow()) {
            setRaw(s, null);
            focused = false;
        }
    }

    if (focused and opts.activate) {
        while (takeKey(ui, &.{ keys.@"return", keys.space })) |k| {
            if (!k.repeat) res.activated = true;
        }
    }
    if (focused and reg.reveal_pending) {
        reveal(&e);
        reg.reveal_pending = false;
    }
    res.focused = focused;
    res.gained = focused and reg.end_focus != ptr;
    res.lost = !focused and (reg.end_focus == ptr or reg.lost_last == ptr);
    res.visible = focused and reg.visible and !opts.disabled;
    reg.seen_focus = s.focus;
    if (opts.ring and res.visible) drawRing(ui, r, opts.ring_radius, opts.ring_offset);
    return res;
}

/// Scrolls the scroll areas `e` sits in (innermost first) so that it is visible.
fn reveal(e: *const Entry) void {
    var r = e.rect;
    var i: usize = e.scroll_n;
    while (i > 0) : (i -= 1) {
        const f = e.scrolls[i - 1];
        const top = r.y - f.view.y + f.state.offset;
        f.state.reveal(f.view.h, top, top + r.h);
        // After this move the entry sits inside the view: that is what the outer areas must show.
        r.y = std.math.clamp(r.y, f.view.y, @max(f.view.y, f.view.y + f.view.h - r.h));
    }
}

/// Draws the focus ring around `r` (a widget with corner `radius`), `offset` points outside it.
pub fn drawRing(ui: *Ui, r: Rect, radius: f32, offset: f32) void {
    const w: f32 = 2;
    const o = offset + w / 2;
    ui.list.rrectStroke(.{ .x = r.x - o, .y = r.y - o, .w = r.w + 2 * o, .h = r.h + 2 * o }, radius + o, w, ui.theme.ringColor());
}
