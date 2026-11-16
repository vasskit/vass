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
const geom = @import("../core/geom.zig");
const gfx = @import("../core/gfx.zig");
const backend = @import("../platform/backend_sdl.zig");
const keys = @import("../core/keys.zig");
const icons = @import("icons.zig");
const text_edit = @import("../text/text_edit.zig");
const controls = @import("controls.zig");
const text_area = @import("text_area.zig");
const popup = @import("popup.zig");
const layout = @import("../layout/layout.zig");
const focus = @import("focus.zig");
const split = @import("split.zig");
const grapheme = @import("../text/grapheme.zig");
const text_input = @import("text_input.zig");
pub const Cursor = backend.Cursor;
pub const FocusId = focus.FocusId;
pub const FocusOpts = focus.FocusOpts;
pub const FocusResult = focus.FocusResult;
pub const FocusEntry = focus.Entry;
pub const FocusRole = focus.Role;
pub const idKey = focus.idKey;
pub const focusIdOf = focus.idOfPtr;
pub const TextEdit = text_edit.TextEdit;
pub const mixColor = controls.mix;
const Rect = geom.Rect;
const Color = geom.Color;
const DisplayList = gfx.DisplayList;

/// One keyboard event of the frame, in arrival order.
pub const InEvent = union(enum) {
    key: backend.Key,
    text: backend.TextChunk,
};

/// Most dropped files `Input` remembers per frame.
pub const max_drops = 16;

/// Everything the app learned from the platform this frame. Lives across
/// frames in the app: `feed` it every event, `endFrame` it once per frame.
pub const Input = struct {
    /// Position in window points. Starts far away so nothing is hovered.
    mouse_x: f32 = -1e9,
    mouse_y: f32 = -1e9,
    /// True only for the frame in which a left click arrived.
    pressed: bool = false,
    /// True only for the frame in which the right button went down.
    right_pressed: bool = false,
    /// True only for the frame in which the left button was released.
    released: bool = false,
    /// True while the left button is held.
    down: bool = false,
    /// Modifiers held when the last mouse button went down (shift-click).
    mouse_mods: keys.Mods = .{},
    /// Click count of the last left press: 1 single, 2 double, 3 triple (from the OS).
    /// Only meaningful on the frame `pressed` is true. Scripted input may leave it 0,
    /// which is treated as a single click.
    mouse_clicks: u8 = 0,
    /// Scroll since the last `endFrame`, in lines (see `backend.Event.mouse_wheel`).
    wheel_x: f32 = 0,
    wheel_y: f32 = 0,
    /// Seconds on any steady clock; the app sets it each frame. Drives caret blinking.
    time: f64 = 0,
    /// Input-method composition in progress (empty when none): the pre-edit string and, in code
    /// points, its cursor and selection. The focused `textField` and `textArea` draw it inline.
    composition: backend.Composition = .{},
    queue: [32]InEvent = undefined,
    queue_len: usize = 0,
    /// True while a drag from another app is over the window (for a "drop here" highlight).
    drop_active: bool = false,
    /// Where the drag is, in window points (valid while `drop_active`, and at the drop).
    drop_x: f32 = -1e9,
    drop_y: f32 = -1e9,
    drops: [max_drops]backend.DropPath = undefined,
    drops_len: usize = 0,
    /// False between a `focus_lost` and the next `focus_gained` of this window (it starts true:
    /// a window that was never told anything is assumed focused, as in headless tests). The
    /// toolkit does not read it; apps use it, e.g. to dim a tool panel.
    window_focused: bool = true,

    /// Files dropped on the window this frame, in arrival order. Valid until `endFrame`.
    pub fn droppedFiles(in: *const Input) []const backend.DropPath {
        return in.drops[0..in.drops_len];
    }

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

    /// Drops event `i` of this frame's queue (a widget that consumed a key).
    pub fn removeEvent(in: *Input, i: usize) void {
        if (i >= in.queue_len) return;
        std.mem.copyForwards(InEvent, in.queue[i .. in.queue_len - 1], in.queue[i + 1 .. in.queue_len]);
        in.queue_len -= 1;
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
                if (m.button == 3) in.right_pressed = true;
                if (m.button == 1) {
                    in.pressed = true;
                    in.down = true;
                    in.mouse_mods = m.mods;
                    in.mouse_clicks = m.clicks;
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
            .mouse_leave => |wid| if (wid == window_id) {
                // Nothing is hovered once the pointer has left the window. A held button is kept:
                // the OS keeps delivering motion and the release to the window that was pressed
                // (mouse capture), so a drag may leave the window and still end properly.
                in.mouse_x = -1e9;
                in.mouse_y = -1e9;
            },
            .focus_gained => |wid| if (wid == window_id) {
                in.window_focused = true;
            },
            .focus_lost => |wid| if (wid == window_id) {
                // Another window or app took the keyboard: a release may never reach this one, so
                // a held button ends here (as a release, so a drag finishes cleanly), and an
                // input-method composition or a drag from another app in progress is abandoned.
                in.window_focused = false;
                if (in.down) {
                    in.down = false;
                    in.released = true;
                }
                in.composition = .{};
                in.drop_active = false;
            },
            .text_editing => |t| if (t.window == window_id) {
                in.composition = t.comp;
            },
            .drop_begin => |wid| if (wid == window_id) {
                in.drop_active = true;
            },
            .drop_position => |d| if (d.window == window_id) {
                in.drop_active = true;
                in.drop_x = d.x;
                in.drop_y = d.y;
            },
            .file_drop => |d| if (d.window == window_id) {
                in.drop_x = d.x;
                in.drop_y = d.y;
                if (in.drops_len < in.drops.len) {
                    in.drops[in.drops_len] = d.path;
                    in.drops_len += 1;
                }
            },
            .drop_complete => |wid| if (wid == window_id) {
                in.drop_active = false;
            },
            else => {},
        }
    }

    /// Call once per frame after drawing, so a click, a key or a scroll is seen exactly once.
    pub fn endFrame(in: *Input) void {
        in.pressed = false;
        in.right_pressed = false;
        in.released = false;
        in.wheel_x = 0;
        in.wheel_y = 0;
        in.queue_len = 0;
        in.drops_len = 0;
    }

    /// A copy with this frame's one-shot state cleared (no click, release, scroll, keys or
    /// drops) that keeps the pointer position and held button. For a frame drawn outside the
    /// event loop, e.g. from `Window.setFrameCallback` while the window is being resized:
    /// the real `Input` is untouched, so nothing it holds is consumed or replayed.
    pub fn idle(in: Input) Input {
        var copy = in;
        copy.endFrame();
        return copy;
    }
};

/// Counts successive clicks from time and distance, for input that carries no OS click count
/// (scripted input). A click within `window` seconds and `radius` points of the last one is the
/// next of a series (capped at 3); anything else starts again at 1.
pub const ClickTracker = struct {
    /// Longest gap between two clicks of a series, in seconds (macOS default is about 0.5).
    pub const window: f64 = 0.5;
    /// Furthest the pointer may move between them, in points.
    pub const radius: f32 = 4;

    time: f64 = -1e9,
    x: f32 = -1e9,
    y: f32 = -1e9,
    count: u8 = 0,

    /// Registers a click at (`x`,`y`) at time `now` and returns its number in the series.
    pub fn next(c: *ClickTracker, now: f64, x: f32, y: f32) u8 {
        const near = @abs(x - c.x) <= radius and @abs(y - c.y) <= radius;
        const n: u8 = if (c.count > 0 and near and now - c.time <= window and now >= c.time) @min(c.count + 1, 3) else 1;
        c.* = .{ .time = now, .x = x, .y = y, .count = n };
        return n;
    }
};

/// See `Ui.setTextInputArea`.
pub const ImeArea = struct { rect: Rect, cursor_x: f32 };

/// What outlives a frame in the Ui itself: which widget has keyboard focus
/// (identified by the address of its state struct) and which one is being
/// dragged. Caller-owned; attach with `ui.state = &state`. Without one,
/// text fields never take focus.
pub const State = struct {
    focus: ?*const anyopaque = null,
    drag: ?*const anyopaque = null,
    /// The `SelectState` (by address) that owns the one text selection, if any.
    /// Separate from `focus`: a selection is not a text field, so it does not
    /// stop arrow-key scrolling or an app's own shortcuts.
    select: ?*const anyopaque = null,
    /// Where last frame's popups were (for input routing); see `popup.zig`.
    popups: popup.Tracker = .{},
    /// Tooltip timer; see `Ui.tooltip`.
    tip: popup.TipState = .{},
    /// Where last frame's splitter grab areas were (they take the pointer from the widgets
    /// beside them), and what the drag in progress started from; see `split.zig`.
    grabs: split.Grabs = .{},
    split_drag: split.Drag = .{},
    /// The last left press, for counting clicks when the OS gives no count; see `Ui.clickCount`.
    click: ClickTracker = .{},
    /// The focusable widgets of this frame and the last, and the focus-ring state; see `focus.zig`.
    reg: focus.Registry = .{},

    /// True while something animates on its own and the app should keep drawing frames even
    /// without input: a tooltip waiting for its delay.
    pub fn needsRedraw(s: *const State) bool {
        return s.tip.waiting;
    }

    pub fn blur(s: *State) void {
        s.focus = null;
    }

    pub fn focusOn(s: *State, widget_state: *const anyopaque) void {
        s.focus = widget_state;
    }

    /// The focused widget's id (its state's address, or a derived id), if any.
    pub fn focusId(s: *const State) ?FocusId {
        return if (s.focus) |f| focus.idOfPtr(f) else null;
    }

    /// The focusable widgets declared in the last completed frame, in call order (read only).
    pub fn focusEntries(s: *const State) []const FocusEntry {
        return s.reg.last();
    }

    /// Whether the focus ring is currently shown (focus came from the keyboard).
    pub fn focusRingVisible(s: *const State) bool {
        return s.reg.visible;
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
    /// Colour of the keyboard focus ring. Null: a light tint of `accent` (see `ringColor`).
    focus_ring: ?Color = null,

    /// The focus ring colour: `focus_ring`, or the accent mixed a third of the way to the text colour.
    pub fn ringColor(t: Theme) Color {
        return t.focus_ring orelse controls.mix(t.accent, t.text, 0.3);
    }
};

pub const Interaction = struct { hovered: bool, clicked: bool };

pub const LabelOpts = struct {
    /// Defaults to the theme's body size.
    size: ?f32 = null,
    /// Defaults to the theme's text colour.
    color: ?Color = null,
    /// Which edge of the rectangle the text is anchored to.
    @"align": gfx.Align = .left,
    /// Font weight (needs a window with fonts for it; see `backend.FontSet`).
    weight: gfx.Weight = .regular,
    /// `textSelectable` only: a right click opens a Copy / Select All menu (needs `ui.state`).
    context_menu: bool = true,
};

pub const ButtonOpts = struct {
    on: bool = false,
    /// Dimmed; never clicked, activated or focused.
    disabled: bool = false,
    /// Focus id key (`idKey(x)`); default: derived from the label. See `focus.zig`.
    id: ?u64 = null,
};

pub const PillOpts = struct {
    disabled: bool = false,
    id: ?u64 = null,
};

pub const TabsOpts = struct {
    disabled: bool = false,
    /// Overrides the default id, the address of the `selected` value.
    id: ?u64 = null,
};

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
/// Like `MeasureFn`, for a given font weight.
pub const MeasureWeightFn = *const fn (ctx: ?*anyopaque, str: []const u8, size: f32, weight: gfx.Weight) f32;

pub const ChipOpts = struct {
    /// Fill; defaults to the theme's card colour.
    fill: ?Color = null,
    /// Text colour; defaults to the theme's text colour.
    color: ?Color = null,
    /// Outline drawn inside the fill, if any.
    border: ?Color = null,
    /// Fill used while the pointer is over the chip (only if `clickable`).
    hover_fill: ?Color = null,
    size: f32 = 11,
    weight: gfx.Weight = .medium,
    /// Corner radius; null is fully rounded.
    radius: ?f32 = null,
    /// Takes keyboard focus (Tab) and reports Enter / Space as a click. Null: only when
    /// `hover_fill` is set, since a chip is usually a plain label and only clickable ones belong
    /// in the Tab order.
    focusable: ?bool = null,
    /// Focus id key (`idKey(x)`); default: derived from the text.
    id: ?u64 = null,
    /// Name for assistive technology when the chip has no text of its own.
    label: []const u8 = "",
};

pub const IconButtonOpts = struct {
    /// Drawn pressed-in / switched on (a toggled panel).
    active: bool = false,
    /// Dimmed, no hover, and never reports a click.
    disabled: bool = false,
    /// Icon size in points (the button rectangle is the hit area).
    icon_size: f32 = 18,
    /// Icon colour when idle; defaults to the theme's `dim`.
    color: ?Color = null,
    /// Stroke weight multiplier.
    weight: f32 = 1,
    /// Name for assistive technology (icon buttons have no text).
    label: []const u8 = "",
    /// Focus id key (`idKey(x)`); default: derived from the icon.
    id: ?u64 = null,
};

pub const CheckOpts = controls.CheckOpts;
pub const ToggleOpts = controls.ToggleOpts;
pub const SliderOpts = controls.SliderOpts;
pub const SliderResult = controls.SliderResult;
pub const WaveformOpts = controls.WaveformOpts;
pub const WaveformResult = controls.WaveformResult;
pub const Segment = controls.Segment;
pub const SegmentedOpts = controls.SegmentedOpts;
pub const SplitterOpts = split.SplitterOpts;
pub const SplitterResult = split.SplitterResult;
pub const TextAreaState = text_area.TextAreaState;
pub const TextAreaOpts = text_area.TextAreaOpts;
pub const TextAreaResult = text_area.TextAreaResult;
pub const PopupState = popup.PopupState;
pub const PopupOpts = popup.PopupOpts;
pub const Placement = popup.Placement;
pub const Alignment = popup.Alignment;
pub const MenuItem = popup.MenuItem;
pub const MenuOpts = popup.MenuOpts;
pub const DropdownState = popup.DropdownState;
pub const DropdownOpts = popup.DropdownOpts;
pub const TooltipOpts = popup.TooltipOpts;

pub const RowOpts = struct {
    selected: bool = false,
    /// Defaults to a faint tint of the theme text colour.
    hover: ?Color = null,
    /// Defaults to the theme's `button_on`.
    selected_fill: ?Color = null,
    radius: f32 = 8,
    /// Dimmed by the caller; skipped by Tab and never activated.
    disabled: bool = false,
    /// Takes keyboard focus (Tab) and reports Enter / Space as a click.
    focusable: bool = true,
    /// Focus id key (`idKey(row.key)`). Without one the id is the row's position among the
    /// rows of its id scope, which breaks when rows are reordered: pass one for dynamic lists.
    id: ?u64 = null,
    /// Name for assistive technology.
    label: []const u8 = "",
};

/// Widget kinds mixed into derived focus ids, so a button and a chip with one label differ.
const tag_button: u64 = 1;
const tag_pill: u64 = 2;
const tag_chip: u64 = 3;
const tag_icon_button: u64 = 4;
const tag_row: u64 = 5;
const tag_radio: u64 = 6;
const tag_tabs: u64 = 7;
const tag_check: u64 = 8;
const tag_toggle: u64 = 9;
const tag_segmented: u64 = 10;

/// The selection after Left / Right / Home / End in a row of `n` items (no wrapping).
pub fn stepSelection(cur: usize, n: usize, code: u32) usize {
    if (n == 0) return cur;
    const c = @min(cur, n - 1);
    return switch (code) {
        keys.left => if (cur >= n) n - 1 else c -| 1,
        keys.right => @min(c + 1, n - 1),
        keys.home => 0,
        keys.end => n - 1,
        else => cur,
    };
}

pub const Ui = struct {
    list: *DisplayList,
    input: Input,
    theme: Theme,
    measure_ctx: ?*anyopaque = null,
    measure_fn: ?MeasureFn = null,
    measure_w_fn: ?MeasureWeightFn = null,
    /// Focus and drag state that persists between frames; see `State`.
    state: ?*State = null,
    clipboard: Clipboard = .{},
    clips: [8]Rect = undefined,
    clip_n: usize = 0,
    scrolls: [4]ScrollFrame = undefined,
    scroll_n: usize = 0,
    /// The window's area in points, for placing popups. `init` reads it from the window;
    /// headless Uis set it (the default is huge, so nothing ever flips or shifts).
    bounds: Rect = .{ .x = 0, .y = 0, .w = 10000, .h = 10000 },
    /// Layer being drawn: 0 for the main stream, n inside the n-th nested popup.
    layer: u8 = 0,
    /// Clips below this index belong to the layer below (popups are not clipped by it).
    clip_base: usize = 0,
    /// Scroll frames below this index belong to the layer below (see `clip_base`).
    scroll_base: usize = 0,
    /// Id scope (`pushId`): the hash widget ids are derived from, and the saved outer ones.
    id_base: u64 = 0,
    id_stack: [16]u64 = undefined,
    id_n: usize = 0,
    /// Focus bookkeeping for this frame has started (see `focus.frameBegin`).
    focus_begun: bool = false,
    popup_stack: [popup.max_depth]popup.Frame = undefined,
    popup_n: usize = 0,
    /// The window `init` was given, to hand it the mouse cursor (null for headless Uis).
    win: ?*backend.Window = null,
    /// The cursor requested this frame by `setCursor` (null: nobody asked). Headless Uis
    /// record it without any platform call, so tests can read it.
    cursor: ?Cursor = null,
    /// Splitter bookkeeping for this frame has started (see `split.splitter`).
    grabs_begun: bool = false,
    /// This frame's press, counted (see `clickCount`).
    click_n: ?u8 = null,
    /// Where the focused text widget asked the input method to put its candidate window this
    /// frame (`setTextInputArea`); headless Uis record it so tests can read it.
    ime_area: ?ImeArea = null,

    /// A Ui that draws into `list` and measures text with `win`.
    pub fn init(list: *DisplayList, win: *backend.Window, input: Input, theme: Theme) Ui {
        const sz = win.logicalSize();
        return .{
            .list = list,
            .input = input,
            .theme = theme,
            .bounds = .{ .x = 0, .y = 0, .w = sz.w, .h = sz.h },
            .win = win,
            .measure_ctx = win,
            .measure_fn = measureWindow,
            .measure_w_fn = measureWindowWeighted,
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

    fn measureWindowWeighted(ctx: ?*anyopaque, str: []const u8, size: f32, weight: gfx.Weight) f32 {
        const win: *backend.Window = @ptrCast(@alignCast(ctx.?));
        return win.measureTextWeighted(str, size, weight);
    }

    /// Width in points of `str` at `size`.
    pub fn measure(ui: *const Ui, str: []const u8, size: f32) f32 {
        const f = ui.measure_fn orelse return 0;
        return f(ui.measure_ctx, str, size);
    }

    /// Width in points of `str` at `size` in `weight`. Without a weight-aware
    /// measurer (headless Uis) this is `measure`.
    pub fn measureWeighted(ui: *const Ui, str: []const u8, size: f32, weight: gfx.Weight) f32 {
        if (weight == .regular) return ui.measure(str, size);
        const f = ui.measure_w_fn orelse return ui.measure(str, size);
        return f(ui.measure_ctx, str, size, weight);
    }

    /// Hover and click state of `r` for this frame. Draws nothing. A pointer
    /// outside the current clip (`pushClip`, `beginScroll`) hits nothing.
    pub fn hit(ui: *const Ui, r: Rect) Interaction {
        const over = r.contains(ui.input.mouse_x, ui.input.mouse_y) and ui.clipContains(ui.input.mouse_x, ui.input.mouse_y) and
            !popup.pointerBlocked(ui) and !split.blocks(ui);
        return .{ .hovered = over, .clicked = over and ui.pressedNow() };
    }

    /// True on the frame a left click arrived, unless a popup that was open last frame above
    /// the layer being drawn takes it (an outside click that closes it, or a click inside it).
    /// Widgets use this instead of `input.pressed`.
    pub fn pressedNow(ui: *const Ui) bool {
        return ui.input.pressed and !popup.pressSwallowed(ui);
    }

    /// How many clicks the press of this frame is in a series: 1 single, 2 double, 3 triple; 0 if
    /// there is no press for the layer being drawn (`pressedNow`). Uses the OS count
    /// (`Input.mouse_clicks`); scripted input that leaves it 0 is counted from `Input.time` and
    /// the pointer position instead (`ClickTracker`: within half a second and 4 points). Counted
    /// once per frame, so every widget sees the same number.
    pub fn clickCount(ui: *Ui) u8 {
        if (!ui.pressedNow()) return 0;
        if (ui.click_n) |n| return n;
        const in = &ui.input;
        var n: u8 = if (in.mouse_clicks > 0) in.mouse_clicks else 1;
        if (ui.state) |s| {
            const counted = s.click.next(in.time, in.mouse_x, in.mouse_y);
            if (in.mouse_clicks == 0) n = counted else s.click = .{ .time = in.time, .x = in.mouse_x, .y = in.mouse_y, .count = @min(in.mouse_clicks, 3) };
        }
        ui.click_n = n;
        return n;
    }

    // ---- input method --------------------------------------------------------------------------

    /// Tells the input method where the text being edited is, in window points: `r` is the
    /// pre-edit (or the caret) and `cursor_x` the input method's caret inside it. The text
    /// widgets call this themselves while focused, so the candidate window follows the caret and
    /// the pre-edit, also in scrolled areas and popups. Headless Uis only record it in `ime_area`.
    pub fn setTextInputArea(ui: *Ui, r: Rect, cursor_x: f32) void {
        ui.ime_area = .{ .rect = r, .cursor_x = cursor_x };
        if (ui.win) |w| w.setTextInputArea(r, cursor_x);
    }

    // ---- mouse cursor --------------------------------------------------------------------------

    /// Asks for the mouse cursor `cur` for this frame: the last request wins (widgets are drawn
    /// bottom to top, so the topmost one), and a request while the pointer is over a popup above the
    /// layer being drawn is ignored. Nothing is applied here: the window applies it in
    /// `Window.render` (so it works for apps that never call `finish`) and then goes back to the
    /// arrow, so a widget only has to keep asking while the pointer is over it. A headless Ui
    /// just records it in `cursor`.
    pub fn setCursor(ui: *Ui, cur: Cursor) void {
        if (popup.pointerBlocked(ui)) return;
        ui.cursor = cur;
        if (ui.win) |w| w.setCursor(cur);
    }

    /// This frame's key presses and typed text for the layer being drawn: empty while a popup
    /// above it was open last frame. Widgets use this instead of `input.events()`.
    pub fn events(ui: *const Ui) []const InEvent {
        return popup.eventsFor(ui, ui.layer);
    }

    // ---- keyboard focus (see focus.zig) --------------------------------

    /// Registers a focusable widget occupying `r` under `id` and handles focus for it (click to
    /// focus, Enter / Space, scroll into view, the focus ring). Call after drawing the widget.
    /// `id` is the address of the widget's state (`focus.idOfPtr(&state)`) or derived
    /// (`ui.widgetId`). Without `ui.state` nothing is ever focused.
    pub fn focusable(ui: *Ui, id: FocusId, r: Rect, opts: FocusOpts) FocusResult {
        return focus.focusable(ui, id, r, opts);
    }

    /// A derived focus id for a custom stateless widget: from the id stack, `kind` (any integer
    /// naming the kind of widget), `key` (a label hash: `idKey("Save")`) and the occurrence of that
    /// combination so far this frame. Pass `explicit` (an `idKey`) to name the widget yourself.
    pub fn widgetId(ui: *Ui, kind: u64, key: u64, explicit: ?u64) FocusId {
        return focus.autoId(ui, 0x100 + kind, key, explicit);
    }

    /// Opens an id scope: widget ids derived inside it differ from the same widgets elsewhere.
    /// `key` is any integer, enum, string or pointer. Up to 16 deep; pair with `popId`.
    pub fn pushId(ui: *Ui, key: anytype) void {
        if (ui.id_n >= ui.id_stack.len) return;
        ui.id_stack[ui.id_n] = ui.id_base;
        ui.id_n += 1;
        ui.id_base = focus.hashInto(ui.id_base, key);
    }

    pub fn popId(ui: *Ui) void {
        if (ui.id_n == 0) return;
        ui.id_n -= 1;
        ui.id_base = ui.id_stack[ui.id_n];
    }

    /// Focus moves to the next / previous focusable widget (as Tab / Shift+Tab do), wrapping.
    pub fn focusNext(ui: *Ui) void {
        focus.focusNext(ui);
    }

    pub fn focusPrev(ui: *Ui) void {
        focus.focusPrev(ui);
    }

    /// Focuses the widget with this id (it must be declared this or next frame); scrolls it into view.
    pub fn setFocus(ui: *Ui, id: FocusId) void {
        focus.setFocus(ui, id);
    }

    pub fn isFocused(ui: *const Ui, id: FocusId) bool {
        return focus.isFocused(ui, id);
    }

    pub fn focusedId(ui: *const Ui) ?FocusId {
        return focus.focusedId(ui);
    }

    /// True while the focus ring is shown: focus came from the keyboard and no mouse press since.
    pub fn focusVisible(ui: *const Ui) bool {
        return focus.focusVisible(ui);
    }

    /// The focusable widgets declared in the last completed frame, in call order.
    pub fn focusEntries(ui: *const Ui) []const FocusEntry {
        const s = ui.state orelse return &.{};
        return s.reg.last();
    }

    /// Draws the focus ring around `r` (a widget with corner `radius`), `offset` points outside it.
    pub fn focusRing(ui: *Ui, r: Rect, radius: f32, offset: f32) void {
        focus.drawRing(ui, r, radius, offset);
    }

    /// Removes the first key press of this frame whose code is in `codes` (modifiers: at most
    /// Shift) from `events()` and returns it. For a focused widget that acts on keys.
    pub fn takeKey(ui: *Ui, codes: []const u32) ?backend.Key {
        return focus.takeKey(ui, codes);
    }

    /// True if the focused widget wants this key: for shortcut code that runs before the widgets
    /// of the frame. See `focus.zig`.
    pub fn keyClaimed(ui: *const Ui, code: u32, mods: keys.Mods) bool {
        return focus.keyClaimed(ui, code, mods);
    }

    // ---- clipping ------------------------------------------------------

    /// The visible area widgets are currently confined to, or null if unclipped.
    pub fn clip(ui: *const Ui) ?Rect {
        return if (ui.clip_n > ui.clip_base) ui.clips[ui.clip_n - 1] else null;
    }

    pub fn clipContains(ui: *const Ui, x: f32, y: f32) bool {
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
        if (ui.clip_n > ui.clip_base) ui.clip_n -= 1;
        ui.list.popClip();
    }

    /// Text anchored at `x`,`y` (top of the line); `opts.align` picks which side `x` is.
    pub fn labelAt(ui: *Ui, x: f32, y: f32, str: []const u8, opts: LabelOpts) void {
        ui.list.textWeighted(x, y, opts.size orelse ui.theme.font_body, opts.color orelse ui.theme.text, opts.@"align", opts.weight, str);
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
    /// Draws `img` into `r` (fit, rounded corners, opacity: see `ImageOpts`) and returns the
    /// hover/click state of `r`. An invalid or unloaded image draws nothing.
    pub fn image(ui: *Ui, r: Rect, img: gfx.Image, opts: gfx.ImageOpts) Interaction {
        ui.list.image(r, img, opts);
        return ui.hit(r);
    }

    /// Draws an icon (a built-in, an `SvgIcon` or an `icons.Source`) centred in `r` in `color`.
    pub fn drawIcon(ui: *Ui, r: Rect, src: anytype, color: Color) void {
        icons.drawSource(ui.list, icons.Source.from(src), r, color, 1);
    }

    pub fn card(ui: *Ui, r: Rect) void {
        ui.list.rrect(r, ui.theme.card_radius, ui.theme.card);
    }

    /// A fully rounded toggle chip; returns true on the frame it is clicked (or activated with
    /// Enter / Space while it has keyboard focus).
    pub fn pill(ui: *Ui, r: Rect, str: []const u8, selected: bool) bool {
        return ui.pillWith(r, str, selected, .{});
    }

    /// `pill` with options (a focus id, disabled).
    pub fn pillWith(ui: *Ui, r: Rect, str: []const u8, selected: bool, opts: PillOpts) bool {
        const clicked = ui.pillDraw(r, str, selected, opts.disabled);
        const f = ui.focusable(focus.autoId(ui, tag_pill, focus.idKey(str), opts.id), r, .{
            .role = .button,
            .label = str,
            .disabled = opts.disabled,
            .ring_radius = r.h / 2,
        });
        return clicked or f.activated;
    }

    /// Draws a pill and reports the click; registers nothing for focus.
    fn pillDraw(ui: *Ui, r: Rect, str: []const u8, selected: bool, disabled: bool) bool {
        const t = ui.theme;
        const fill = if (selected) t.accent else t.card;
        const col = if (selected) t.accent_text else t.dim;
        ui.list.rrect(r, r.h / 2, if (disabled) fill.alpha(90) else fill);
        ui.list.text(r.x + r.w / 2, r.y + (r.h - 15) / 2, t.font_button, if (disabled) col.alpha(90) else col, .center, str);
        return !disabled and ui.hit(r).clicked;
    }

    /// A row of pills sharing `r` equally, one per label. Clicking one stores
    /// its index in `selected`; returns true if that changed anything. One Tab stop for the
    /// whole row: Left / Right (and Home / End) change the selection while it has focus.
    pub fn tabs(ui: *Ui, r: Rect, labels: []const []const u8, selected: *usize) bool {
        return ui.tabsWith(r, labels, selected, .{});
    }

    /// `tabs` with options.
    pub fn tabsWith(ui: *Ui, r: Rect, labels: []const []const u8, selected: *usize, opts: TabsOpts) bool {
        var changed = false;
        const id = if (opts.id) |e| focus.autoId(ui, tag_tabs, 0, e) else focus.idOfPtr(selected);
        const f = ui.focusable(id, r, .{ .role = .tab, .disabled = opts.disabled, .activate = false, .ring = false });
        if (f.focused and labels.len > 0) {
            while (ui.takeKey(&.{ keys.left, keys.right, keys.home, keys.end })) |k| {
                const n = stepSelection(selected.*, labels.len, k.code);
                if (n != selected.*) {
                    selected.* = n;
                    changed = true;
                }
            }
        }
        const current = selected.*;
        for (labels, 0..) |str, i| {
            if (ui.pillDraw(r.column(labels.len, ui.theme.gap, i), str, i == current, opts.disabled) and i != current) {
                selected.* = i;
                changed = true;
            }
        }
        if (f.visible and labels.len > 0) {
            const sel = r.column(labels.len, ui.theme.gap, @min(selected.*, labels.len - 1));
            ui.focusRing(sel, sel.h / 2, 2);
        }
        return changed;
    }

    /// A rounded button, filled when `opts.on`; returns true when clicked (or activated with
    /// Enter / Space while it has keyboard focus).
    pub fn button(ui: *Ui, r: Rect, str: []const u8, opts: ButtonOpts) bool {
        const t = ui.theme;
        const fill = if (opts.on) t.button_on else t.card;
        const col = if (opts.on) t.text else t.dim;
        ui.list.rrect(r, t.card_radius, if (opts.disabled) fill.alpha(90) else fill);
        ui.list.text(r.x + r.w / 2, r.y + (r.h - 14) / 2, t.font_button, if (opts.disabled) col.alpha(90) else col, .center, str);
        const clicked = !opts.disabled and ui.hit(r).clicked;
        const f = ui.focusable(focus.autoId(ui, tag_button, focus.idKey(str), opts.id), r, .{
            .role = .button,
            .label = str,
            .disabled = opts.disabled,
            .ring_radius = t.card_radius,
        });
        return clicked or f.activated;
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
        return ui.fitTextWeighted(buf, str, size, .regular, max_w);
    }

    /// `fitText` measuring in `weight`.
    pub fn fitTextWeighted(ui: *const Ui, buf: []u8, str: []const u8, size: f32, weight: gfx.Weight, max_w: f32) []const u8 {
        if (str.len == 0 or ui.measureWeighted(str, size, weight) <= max_w) return str;
        var n = @min(str.len - 1, buf.len -| 3);
        while (n > 0) : (n -= 1) {
            if (!grapheme.isBoundary(str, n)) continue; // not in the middle of a character or cluster
            @memcpy(buf[0..n], str[0..n]);
            @memcpy(buf[n..][0..3], "...");
            if (ui.measureWeighted(buf[0 .. n + 3], size, weight) <= max_w) return buf[0 .. n + 3];
        }
        return "";
    }

    /// A small label pill: a rounded rectangle with centred text. Chips are
    /// laid out by the caller (see `chipWidth`). Returns the interaction of
    /// its rectangle, so a chip that should be clickable just checks `.clicked`.
    pub fn chip(ui: *Ui, r: Rect, str: []const u8, opts: ChipOpts) Interaction {
        const t = ui.theme;
        const hv = ui.hit(r);
        var fill = opts.fill orelse t.card;
        if (hv.hovered) if (opts.hover_fill) |h| {
            fill = h;
        };
        const rad = opts.radius orelse r.h / 2;
        if (opts.border) |b| {
            ui.list.rrect(r, rad, b);
            ui.list.rrect(r.inset(1), @max(0, rad - 1), fill);
        } else ui.list.rrect(r, rad, fill);
        // A font's line box is about 1.2 times its size; centre that in the chip.
        ui.list.textWeighted(r.x + r.w / 2, r.y + (r.h - opts.size * 1.22) / 2, opts.size, opts.color orelse t.text, .center, opts.weight, str);
        if (opts.focusable orelse (opts.hover_fill != null)) {
            const f = ui.focusable(focus.autoId(ui, tag_chip, focus.idKey(str), opts.id), r, .{ .role = .button, .label = if (str.len > 0) str else opts.label, .ring_radius = rad });
            return .{ .hovered = hv.hovered, .clicked = hv.clicked or f.activated };
        }
        return hv;
    }

    /// Width of a chip showing `str`: the text plus `pad` on both sides.
    pub fn chipWidth(ui: *const Ui, str: []const u8, opts: ChipOpts, pad: f32) f32 {
        return ui.measureWeighted(str, opts.size, opts.weight) + 2 * pad;
    }

    /// A square icon button: a subtle rounded background when hovered or
    /// `active`, the icon centred in `r`. Returns the interaction of `r`;
    /// a disabled button is never hovered or clicked.
    /// `icon` is a built-in (`.search`, an `icons.Icon`), a loaded `SvgIcon` or an `icons.Source`.
    pub fn iconButton(ui: *Ui, r: Rect, icon: anytype, opts: IconButtonOpts) Interaction {
        const t = ui.theme;
        var hv = ui.hit(r);
        if (opts.disabled) hv = .{ .hovered = false, .clicked = false };
        if (opts.active) {
            ui.list.rrect(r, 7, t.text.alpha(26));
        } else if (hv.hovered) {
            ui.list.rrect(r, 7, t.text.alpha(16));
        }
        const base = opts.color orelse t.dim;
        const color = if (opts.disabled) base.alpha(90) else if (hv.hovered or opts.active) t.text else base;
        const src = icons.Source.from(icon);
        icons.drawSource(ui.list, src, r.center(opts.icon_size, opts.icon_size), color, opts.weight);
        const f = ui.focusable(focus.autoId(ui, tag_icon_button, focus.iconKey(src), opts.id), r, .{
            .role = .button,
            .label = opts.label,
            .disabled = opts.disabled,
            .ring_radius = 7,
        });
        return .{ .hovered = hv.hovered, .clicked = hv.clicked or f.activated };
    }

    /// A selectable list row: draws a highlight when `opts.selected` or hovered
    /// and returns the interaction of `r`. Draw the row's content on top.
    pub fn listRow(ui: *Ui, r: Rect, opts: RowOpts) Interaction {
        const t = ui.theme;
        const hv = ui.hit(r);
        if (opts.selected) {
            ui.list.rrect(r, opts.radius, opts.selected_fill orelse t.button_on);
        } else if (hv.hovered) {
            ui.list.rrect(r, opts.radius, opts.hover orelse t.text.alpha(14));
        }
        if (opts.focusable) {
            const f = ui.focusable(focus.autoId(ui, tag_row, 0, opts.id), r, .{
                .role = .list_row,
                .label = opts.label,
                .disabled = opts.disabled,
                .ring_radius = opts.radius,
            });
            return .{ .hovered = hv.hovered, .clicked = (hv.clicked and !opts.disabled) or f.activated };
        }
        return hv;
    }

    /// `str` with line breaks and runs of blanks collapsed to single spaces,
    /// copied into `buf` (cut at `buf.len` on a character boundary). For
    /// one-line and two-line previews of multi-paragraph text.
    pub fn flattenText(buf: []u8, str: []const u8) []const u8 {
        var n: usize = 0;
        var pending_space = false;
        for (str) |b| {
            if (b == '\n' or b == '\r' or b == '\t' or b == ' ') {
                pending_space = n > 0;
                continue;
            }
            const need: usize = if (pending_space) 2 else 1;
            if (n + need > buf.len) break;
            if (pending_space) {
                buf[n] = ' ';
                n += 1;
                pending_space = false;
            }
            buf[n] = b;
            n += 1;
        }
        // A cut can leave half a character at the end: drop it.
        var i = n;
        while (i > 0 and buf[i - 1] & 0xC0 == 0x80) i -= 1;
        if (i > 0) {
            const lead = buf[i - 1];
            const want: usize = if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else if (lead >= 0xC0) 2 else 1;
            if (n - (i - 1) < want) n = i - 1;
        }
        return buf[0..n];
    }

    /// Draws `str` wrapped to `r.w` in at most `max_lines` lines; if the text
    /// is longer, the last line is shortened and ends in "...". Returns the
    /// height used (lines drawn times line height). Newlines in `str` break
    /// lines like `labelWrapped`; use `flattenText` first for a compact preview.
    pub fn labelLines(ui: *Ui, r: Rect, str: []const u8, max_lines: usize, opts: LabelOpts) f32 {
        const size = opts.size orelse ui.theme.font_body;
        const lh = ui.lineHeight(size);
        const x = switch (opts.@"align") {
            .left => r.x,
            .center => r.x + r.w / 2,
            .right => r.x + r.w,
        };
        var it = ui.wrapText(str, size, r.w);
        var y = r.y;
        var n: usize = 0;
        var cur = it.next();
        while (cur) |line| : (cur = it.next()) {
            if (n >= max_lines) break;
            n += 1;
            const more = n == max_lines and it.next() != null;
            if (more) {
                var tmp: [384]u8 = undefined;
                var out: [384]u8 = undefined;
                const keep = @min(line.len, tmp.len - 3);
                @memcpy(tmp[0..keep], line[0..keep]);
                @memcpy(tmp[keep..][0..3], "...");
                ui.labelAt(x, y, ui.fitTextWeighted(&out, tmp[0 .. keep + 3], size, opts.weight, r.w), opts);
            } else if (line.len > 0) ui.labelAt(x, y, line, opts);
            y += lh;
        }
        return y - r.y;
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

    // ---- layout leaves for text ---------------------------------------

    const TextLeaf = struct {
        ui: *const Ui,
        str: []const u8,
        size: f32,
        weight: gfx.Weight,

        fn single(ctx: ?*anyopaque, max_w: f32) layout.Extent {
            _ = max_w;
            const t: *const TextLeaf = @ptrCast(@alignCast(ctx.?));
            return .{ .w = t.ui.measureWeighted(t.str, t.size, t.weight), .h = t.ui.lineHeight(t.size) };
        }

        fn wrapped(ctx: ?*anyopaque, max_w: f32) layout.Extent {
            const t: *const TextLeaf = @ptrCast(@alignCast(ctx.?));
            const lh = t.ui.lineHeight(t.size);
            if (!std.math.isFinite(max_w)) return .{ .w = t.ui.measure(t.str, t.size), .h = if (t.str.len == 0) 0 else lh };
            var it = t.ui.wrapText(t.str, t.size, @max(0, max_w));
            var lines: f32 = 0;
            var widest: f32 = 0;
            while (it.next()) |line| {
                lines += 1;
                widest = @max(widest, t.ui.measure(line, t.size));
            }
            return .{ .w = widest, .h = lines * lh };
        }
    };

    /// A single-line text leaf for `lay`: hug width (the text's width) and one line high.
    /// `opts` is used as given except `w` and `h`, which stay as the caller set them unless
    /// they are the default `.hug`. Draw it with `ui.label(lay.rect(node), str, .{ .size = size })`.
    pub fn layText(ui: *const Ui, lay: *layout.Layout, str: []const u8, size: f32, opts: layout.Opts) layout.Node {
        return ui.layTextWeighted(lay, str, size, .regular, opts);
    }

    /// `layText` for a font weight.
    pub fn layTextWeighted(ui: *const Ui, lay: *layout.Layout, str: []const u8, size: f32, weight: gfx.Weight, opts: layout.Opts) layout.Node {
        var o = opts;
        if (lay.create(TextLeaf, .{ .ui = ui, .str = str, .size = size, .weight = weight })) |t| {
            if (o.w.kind == .hug) o.w = .measured(t, TextLeaf.single);
            if (o.h.kind == .hug) o.h = .measured(t, TextLeaf.single);
        }
        return lay.leaf(o);
    }

    /// A wrapped-text leaf for `lay`: its height comes from `measureWrapped` at the width it
    /// is given (the same wrapping `labelWrapped` draws). Width defaults to `.grow(1)`.
    /// Draw it with `ui.labelWrapped(lay.rect(node), str, .{ .size = size })`.
    pub fn layWrapped(ui: *const Ui, lay: *layout.Layout, str: []const u8, size: f32, opts: layout.Opts) layout.Node {
        var o = opts;
        if (o.w.kind == .hug) o.w = .grow(1);
        if (lay.create(TextLeaf, .{ .ui = ui, .str = str, .size = size, .weight = .regular })) |t| {
            if (o.h.kind == .hug) o.h = .measured(t, TextLeaf.wrapped);
        }
        return lay.leaf(o);
    }

    // ---- selectable text ----------------------------------------------

    /// Horizontal offset of `line` from the left of a `max_w` wide block.
    fn lineOffset(ui: *const Ui, line: []const u8, size: f32, max_w: f32, al: gfx.Align) f32 {
        return switch (al) {
            .left => 0,
            .center => (max_w - ui.measure(line, size)) / 2,
            .right => max_w - ui.measure(line, size),
        };
    }

    /// Byte offset into `str` of the caret position nearest to the point
    /// (`x`,`y`), measured in points from the top-left of the text as drawn
    /// by `labelWrapped` (left aligned) at width `max_w`. Pure: nothing is
    /// drawn. Above the first line gives 0, below the last gives `str.len`;
    /// left or right of a line clamps to that line's ends. Always on a UTF-8
    /// boundary.
    pub fn offsetAtPoint(ui: *const Ui, str: []const u8, size: f32, max_w: f32, x: f32, y: f32) usize {
        return ui.offsetAtPointAligned(str, size, max_w, x, y, .left);
    }

    /// `offsetAtPoint` for text drawn with `align` (centre/right lines are
    /// shifted inside the block).
    pub fn offsetAtPointAligned(ui: *const Ui, str: []const u8, size: f32, max_w: f32, x: f32, y: f32, al: gfx.Align) usize {
        if (str.len == 0 or y < 0) return 0;
        const lh = ui.lineHeight(size);
        var top: f32 = 0;
        var it = ui.wrapText(str, size, max_w);
        while (it.next()) |line| : (top += lh) {
            if (y >= top + lh) continue;
            const start = @intFromPtr(line.ptr) - @intFromPtr(str.ptr);
            return start + ui.offsetAtX(line, size, x - ui.lineOffset(line, size, max_w, al));
        }
        return str.len;
    }

    /// Wrapped read-only text (drawn and measured exactly like `labelWrapped`,
    /// same return value) that the user can select and copy.
    ///
    /// Press inside the text and drag to select (a double click selects the
    /// word, a triple click the line between newlines; shift-click extends).
    /// Cmd+C copies the selection through the clipboard hook, Cmd+A selects
    /// all of this text, Escape or a click elsewhere clears it. Only one
    /// selection exists per `Ui.state` (`State.select`): starting one
    /// elsewhere, or focusing a text field, clears this one. The highlight
    /// uses `theme.selection`, drawn behind the text per visual line. An
    /// in-progress drag keeps tracking when the pointer leaves the text, so
    /// pass the rectangle as laid out inside a scroll area (moved by the
    /// scroll offset) and the selection follows the content.
    ///
    /// Without `ui.state` this is just `labelWrapped`. A selection is only
    /// cleared by a click elsewhere while the text is being drawn; text that
    /// is skipped (scrolled out and culled) keeps it until it is drawn again
    /// with another selection active, when it clears itself.
    /// See `SelectState` for what to do when `str` changes.
    pub fn textSelectable(ui: *Ui, r: Rect, str: []const u8, st: *SelectState, opts: LabelOpts) f32 {
        const size = opts.size orelse ui.theme.font_body;
        const lh = ui.lineHeight(size);
        const al = opts.@"align";
        const height = ui.measureWrapped(str, size, r.w);
        const id: *const anyopaque = st;
        const in = &ui.input;
        var selected = false;

        if (ui.state) |s| {
            selected = s.select == id;
            if (!selected) st.clear(); // lost the selection to another text or a field
            const area: Rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = height };
            const hv = ui.hit(area);
            const off = ui.offsetAtPointAligned(str, size, r.w, in.mouse_x - r.x, in.mouse_y - r.y, al);
            if (hv.clicked) {
                const clicks = ui.clickCount();
                const extend = selected and in.mouse_mods.shift and clicks <= 1;
                s.select = id;
                s.focus = null; // blur any text field
                selected = true;
                s.drag = null;
                if (extend) {
                    const rg = st.range(str);
                    // keep the end of the old selection farther from the click as the anchor
                    st.anchor = if (st.anchor <= st.cursor) rg.start else rg.end;
                    st.cursor = off;
                    st.multi = .{};
                    s.drag = id;
                } else if (st.multi.begin(str, off, clicks, false)) |rg| {
                    // double click: the word, triple click: the line; dragging grows by the same unit
                    st.anchor = rg.start;
                    st.cursor = rg.end;
                    s.drag = id;
                } else {
                    st.anchor = off;
                    st.cursor = off;
                    s.drag = id;
                }
            } else if (opts.context_menu and in.right_pressed and !st.ctx.open and hv.hovered and !popup.pressSwallowed(ui)) {
                // Right click: keep the selection when it is inside it, else put the caret there
                // (an empty selection), and open the menu.
                const rg = st.range(str);
                const inside = selected and rg.end > rg.start and off >= rg.start and off <= rg.end;
                s.select = id;
                s.focus = null;
                s.drag = null;
                selected = true;
                if (!inside) {
                    st.anchor = off;
                    st.cursor = off;
                }
                _ = ui.contextOpen(&st.ctx, area);
            } else if (ui.pressedNow() and selected) {
                s.select = null;
                selected = false;
                st.clear();
            } else if (s.drag == id) {
                if (!selected) {
                    s.drag = null;
                } else {
                    if (st.multi.gran != .char) {
                        const m = st.multi.extend(str, off);
                        st.anchor = m.anchor;
                        st.cursor = m.cursor;
                    } else st.cursor = off;
                    if (!in.down) s.drag = null;
                }
            }

            if (opts.context_menu and st.ctx.open) {
                const caps: text_input.Caps = .{ .editable = false, .has_selection = selected and st.hasSelection(str), .has_text = str.len > 0 };
                if (text_input.contextMenu(ui, &st.ctx, caps)) |act| switch (act) {
                    .copy => if (selected and st.hasSelection(str)) ui.clipboardSet(st.selectedText(str)),
                    .select_all => {
                        s.select = id;
                        selected = true;
                        st.anchor = 0;
                        st.cursor = str.len;
                    },
                    else => {},
                };
            }

            if (selected) for (ui.events()) |ev| switch (ev) {
                .key => |k| {
                    if (k.code == keys.escape) {
                        s.select = null;
                        if (s.drag == id) s.drag = null;
                        selected = false;
                        st.clear();
                        break;
                    } else if (k.mods.cmd and k.code == keys.c) {
                        if (st.hasSelection(str)) ui.clipboardSet(st.selectedText(str));
                    } else if (k.mods.cmd and k.code == keys.a) {
                        st.anchor = 0;
                        st.cursor = str.len;
                    }
                },
                else => {},
            };
        }

        const vis = ui.clip();
        if (selected and st.hasSelection(str)) {
            const sel = st.range(str);
            const space_w = ui.measure(" ", size);
            var y = r.y;
            var it = ui.wrapText(str, size, r.w);
            while (it.next()) |line| : (y += lh) {
                if (vis) |v| if (y + lh < v.y or y > v.y + v.h) continue;
                const ls = @intFromPtr(line.ptr) - @intFromPtr(str.ptr);
                const le = ls + line.len;
                const a = @max(sel.start, ls);
                const b = @min(sel.end, le);
                const lx = r.x + ui.lineOffset(line, size, r.w, al);
                var x0 = lx;
                var x1 = lx;
                if (a < b) {
                    x0 = lx + ui.measure(line[0 .. a - ls], size);
                    x1 = lx + ui.measure(line[0 .. b - ls], size);
                } else if (sel.start <= le and sel.end > le) {
                    x0 = lx + ui.measure(line, size);
                    x1 = x0;
                } else continue;
                // The selection runs on past a line break: show the break as a small stub.
                if (sel.end > le and le < str.len and sel.start <= le and (str[le] == '\n' or str[le] == '\r' or str[le] == ' ')) x1 += space_w;
                x1 = @min(x1, r.x + r.w);
                if (x1 > x0) ui.list.rect(.{ .x = x0, .y = y, .w = x1 - x0, .h = lh }, ui.theme.selection);
            }
        }
        return ui.labelWrapped(r, str, opts);
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

    /// Byte offset in the buffer of the caret position nearest to `x` points from the start of
    /// the field's text: by cluster for a password field (every cluster is one bullet wide).
    fn fieldOffsetAtX(ui: *const Ui, st: *TextFieldState, size: f32, password: bool, x: f32) usize {
        const text = st.edit.text();
        if (!password) return ui.offsetAtX(text, size, x);
        const n = grapheme.count(text);
        st.disp.clearRetainingCapacity();
        text_input.appendBulletsTo(&st.disp, st.edit.gpa, n) catch return text.len;
        const idx = ui.offsetAtX(st.disp.items, size, x) / text_input.bullet.len;
        var off: usize = 0;
        var k: usize = 0;
        while (k < idx and off < text.len) : (k += 1) off = text_edit.nextBoundary(text, off);
        return off;
    }

    /// A single-line editable text field.
    ///
    /// Clicking focuses it (needs `ui.state`), clicking elsewhere or Escape
    /// blurs it. While focused it consumes this frame's typed text and keys:
    /// arrows, home/end, alt = by word, shift = select, cmd+a/c/x/v, cmd+z undo,
    /// cmd+shift+z redo, backspace, delete. Return sets `submitted` (the text stays; clear it yourself).
    /// Everything moves and deletes by grapheme cluster (see `TextEdit`). Click and drag select;
    /// a double click selects the word and dragging then grows by words, a triple click selects
    /// everything, shift-click extends. A right click opens a context menu (`opts.context_menu`):
    /// inside the selection it keeps it, elsewhere it first moves the caret there. The text
    /// scrolls horizontally to keep the caret visible. The caret blinks off `Input.time`. The
    /// content is `state.edit.text()`.
    ///
    /// An input-method composition is drawn inline at the caret, underlined, pushing the rest of
    /// the text along; it is not in the buffer until committed (see `text_input.zig`). While it
    /// shows the normal caret is hidden and plain keys are left to the input method.
    /// `opts.password` masks everything. Focused, the field tells the input method where the
    /// caret is (`setTextInputArea`).
    pub fn textField(ui: *Ui, r: Rect, st: *TextFieldState, opts: TextFieldOpts) TextFieldResult {
        const t = ui.theme;
        const size = opts.size orelse t.font_body;
        const line_h = @round(size * 1.3);
        const pad: f32 = if (opts.bare) 0 else 10;
        const box: Rect = .{ .x = r.x + pad, .y = r.y + 2, .w = @max(0, r.w - 2 * pad), .h = @max(0, r.h - 4) };
        const id: *const anyopaque = st;
        const pw = opts.password;
        var res: TextFieldResult = .{};
        const in = &ui.input;
        // A Tab stop; the field handles the mouse itself. Tab is taken before the field sees keys.
        // The label is the placeholder, never the text (a password must not leak into it).
        _ = ui.focusable(focusIdOf(id), r, .{ .role = .text_field, .label = opts.placeholder, .ring = false, .activate = false, .click_focus = false });
        var focused = if (ui.state) |s| s.focus == id else false;
        const hv = ui.hit(r);
        if (hv.hovered) ui.setCursor(.text);
        // A composition that was already showing last frame: clicks are the input method's then.
        const comp_before = st.was_focused and focused and in.composition.len > 0 and !st.ime_block;

        if (ui.state) |s| {
            const wants_off = hv.clicked or (in.right_pressed and hv.hovered) or s.drag == id;
            const off = if (wants_off) ui.fieldOffsetAtX(st, size, pw, in.mouse_x - box.x + st.scroll_x) else 0;
            if (hv.clicked) {
                const clicks = ui.clickCount();
                s.focus = id;
                s.select = null; // one selection at a time
                focused = true;
                st.blink_origin = in.time;
                if (!comp_before) {
                    s.drag = id;
                    if (in.mouse_mods.shift) {
                        st.multi = .{};
                        st.edit.moveTo(off, true);
                    } else if (st.multi.begin(st.edit.text(), off, clicks, pw)) |rg| {
                        st.edit.select(rg.start, rg.end);
                    } else st.edit.moveTo(off, false);
                }
            } else if (opts.context_menu and in.right_pressed and !st.ctx.open and hv.hovered and !popup.pressSwallowed(ui)) {
                // Right click: focus the field; keep the selection when the click is inside it,
                // else put the caret there; then open the menu. Opening remembers the focus and
                // gives it back when the menu closes.
                s.focus = id;
                s.select = null;
                focused = true;
                st.blink_origin = in.time;
                const sel = st.edit.selection();
                if (!comp_before and (!st.edit.hasSelection() or off < sel.start or off > sel.end)) st.edit.moveTo(off, false);
                _ = ui.contextOpen(&st.ctx, r);
            } else if (ui.pressedNow() and focused) {
                s.focus = null;
                focused = false;
            } else if (s.drag == id) {
                if (comp_before) {
                    if (!in.down) s.drag = null;
                } else if (in.down) {
                    if (st.multi.gran != .char) {
                        const m = st.multi.extend(st.edit.text(), off);
                        st.edit.select(m.anchor, m.cursor);
                    } else st.edit.moveTo(off, true);
                } else s.drag = null;
            }

            // The context menu (a popup, so it draws above everything whatever the order).
            if (opts.context_menu and st.ctx.open) {
                const caps: text_input.Caps = .{
                    .editable = true,
                    .has_selection = st.edit.hasSelection(),
                    .has_text = st.edit.text().len > 0,
                    .can_undo = st.edit.canUndo(),
                    .can_redo = st.edit.canRedo(),
                    .allow_copy = !pw,
                };
                if (text_input.contextMenu(ui, &st.ctx, caps)) |act| {
                    s.focus = id;
                    focused = true;
                    st.edit.now = in.time;
                    st.blink_origin = in.time;
                    if (text_input.applyAction(ui, &st.edit, act, !pw)) res.changed = true;
                }
            }
        }

        const composing = text_input.composingNow(&st.was_focused, &st.ime_block, focused, in.composition.len > 0);

        if (focused) {
            const s = ui.state.?;
            st.edit.now = in.time;
            for (ui.events()) |ev| {
                st.blink_origin = in.time;
                switch (ev) {
                    .text => |chunk| {
                        if (chunk.len > 0) {
                            st.edit.insert(chunk.slice()) catch {};
                            res.changed = true;
                        }
                    },
                    .key => |k0| {
                        if (composing and text_input.imeOwnsKey(k0)) continue;
                        if (pw and text_input.isCopyOrCut(k0)) continue;
                        const k = if (pw) text_input.passwordKey(k0) else k0;
                        switch (st.edit.handleKey(k.code, k.mods) catch .none) {
                            .none, .handled => {},
                            .changed => res.changed = true,
                            .copy => |str| ui.clipboardSet(str),
                            .cut => |str| {
                                ui.clipboardSet(str);
                                res.changed = true;
                            },
                            .paste => if (ui.clipboard.get) |get| if (get(st.edit.gpa)) |str| {
                                defer st.edit.gpa.free(str);
                                st.edit.insertAs(str, .paste) catch {};
                                res.changed = true;
                            },
                            .submit => res.submitted = true,
                            .cancel => {
                                s.focus = null;
                                focused = false;
                            },
                        }
                    },
                }
            }
        }

        // What is drawn: the text, with the pre-edit spliced in at the caret (replacing the
        // selection), or bullets.
        const text = st.edit.text();
        const sel = st.edit.selection();
        const pre = if (composing and focused) text_input.preedit(&in.composition, pw, text_input.roomFor(&st.edit, sel.end - sel.start)) else null;
        const caret_off = text_edit.snapCluster(text, st.edit.cursor);
        const d = text_input.display(st.edit.gpa, &st.disp, text, pw, pre, if (pre != null) sel else .{ .start = caret_off, .end = caret_off });
        const dt = d.text;
        const caret_x = ui.measure(dt[0..d.caretAt(caret_off)], size);
        const pre_x = ui.measure(dt[0..d.pre_start], size);

        // Scroll horizontally so the caret stays in view.
        if (focused) {
            if (caret_x - st.scroll_x > box.w - 2) st.scroll_x = caret_x - box.w + 2;
            if (caret_x < st.scroll_x) st.scroll_x = caret_x;
        }
        st.scroll_x = std.math.clamp(st.scroll_x, 0, @max(0, ui.measure(dt, size) + 2 - box.w));

        // Draw.
        if (!opts.bare) {
            ui.list.rrect(r, 10, if (focused) t.accent else t.track);
            ui.list.rrect(r.inset(1.5), 8.5, t.card);
        }
        ui.pushClip(box);
        defer ui.popClip();
        const ty = r.y + @round((r.h - line_h) / 2);
        const tx = box.x - st.scroll_x;
        if (text.len == 0 and pre == null) {
            if (opts.placeholder.len > 0) ui.labelAt(box.x, ty, opts.placeholder, .{ .size = size, .color = t.dim });
        } else {
            if (focused and pre == null and st.edit.hasSelection()) {
                const a = d.toDisplay(text_edit.snapCluster(text, sel.start));
                const b = d.toDisplay(text_edit.snapCluster(text, sel.end));
                const x0 = tx + ui.measure(dt[0..a], size);
                const x1 = tx + ui.measure(dt[0..b], size);
                ui.list.rect(.{ .x = x0, .y = ty, .w = x1 - x0, .h = line_h }, t.selection);
            }
            if (dt.len > 0) ui.list.text(tx, ty, size, t.text, .left, dt);
        }
        if (pre) |p| {
            const x0 = tx + pre_x;
            const x1 = tx + ui.measure(dt[0..d.preEnd()], size);
            if (p.clause) |c| {
                text_input.drawPreeditMarks(ui, x0, x1, ty, line_h, .{
                    .x0 = x0 + ui.measure(dt[d.pre_start..][0..c.start], size),
                    .x1 = x0 + ui.measure(dt[d.pre_start..][0..c.end], size),
                });
            } else text_input.drawPreeditMarks(ui, x0, x1, ty, line_h, null);
        }
        const show_caret = focused and (pre == null or pre.?.clause == null);
        if (show_caret and @mod(in.time - st.blink_origin, 1.06) < 0.53) {
            ui.list.rect(.{ .x = tx + caret_x, .y = ty, .w = 1.5, .h = line_h }, t.text);
        }
        // The caret's line (also what `input_area` reports, for apps that set the text input area
        // themselves) and, for the input method, a tighter rectangle: under the pre-edit, or at
        // the caret.
        res.input_area = .{ .x = box.x, .y = ty, .w = box.w, .h = line_h };
        res.caret_x = caret_x - st.scroll_x;
        if (focused) {
            if (pre != null) {
                const w = @max(1, ui.measure(dt[d.pre_start..d.preEnd()], size));
                ui.setTextInputArea(.{ .x = tx + pre_x, .y = ty, .w = w, .h = line_h }, caret_x - pre_x);
            } else ui.setTextInputArea(.{ .x = tx + caret_x, .y = ty, .w = 1, .h = line_h }, 0);
        }
        return res;
    }

    pub fn clipboardSet(ui: *const Ui, str: []const u8) void {
        if (ui.clipboard.set) |set| set(std.heap.page_allocator, str);
    }

    // ---- form controls ------------------------------------------------

    /// A check box with a label to its right; the whole row `r` is clickable.
    /// Flips `value` on click (`clicked` is then true). See `controls.zig`.
    pub fn checkbox(ui: *Ui, r: Rect, value: *bool, label_str: []const u8, opts: CheckOpts) Interaction {
        return controls.checkbox(ui, r, value, label_str, opts);
    }

    /// A pill-shaped switch centred in `r`, accent coloured when on. Flips `value` on click.
    pub fn toggle(ui: *Ui, r: Rect, value: *bool, opts: ToggleOpts) Interaction {
        return controls.toggle(ui, r, value, opts);
    }

    /// Draws a switch with the knob at `pos` (0..1) without reading input,
    /// for animating `toggle` later.
    pub fn toggleAt(ui: *Ui, r: Rect, pos: f32, hovered: bool, opts: ToggleOpts) void {
        controls.toggleAt(ui, r, pos, hovered, opts);
    }

    /// A horizontal slider for `value` between `opts.min` and `opts.max`: click to jump, drag
    /// the thumb, arrow keys when focused. See `controls.zig`.
    pub fn slider(ui: *Ui, r: Rect, value: *f32, opts: SliderOpts) SliderResult {
        return controls.slider(ui, r, value, opts);
    }

    // ---- split panes (see split.zig) -------------------------------------------------------------

    /// A draggable divider whose line is `r`; reads and writes the pane size `size`. See `split.zig`.
    pub fn splitter(ui: *Ui, r: Rect, size: *f32, opts: SplitterOpts) SplitterResult {
        return split.splitter(ui, r, size, opts);
    }

    /// Draws a splitter's line (for `SplitterOpts.draw = false`); see `split.drawLine`.
    pub fn splitterLine(ui: *Ui, r: Rect, res: SplitterResult, opts: SplitterOpts) void {
        split.drawLine(ui, r, res, opts);
    }

    /// True while the splitter that controls `size` is being dragged.
    pub fn splitterDragging(ui: *const Ui, size: *const f32) bool {
        return split.isDragging(ui, size);
    }

    /// Bars for `peaks` (0..1 each, see `audio.peaks`) filling `r`, coloured up to
    /// `opts.progress`; the result carries the 0..1 position clicked or dragged to, for seeking.
    pub fn waveform(ui: *Ui, r: Rect, peaks: []const f32, opts: WaveformOpts) WaveformResult {
        return controls.waveform(ui, r, peaks, opts);
    }

    /// A round radio button with a label; reports the click, the caller sets its value.
    pub fn radio(ui: *Ui, r: Rect, selected: bool, label_str: []const u8, opts: CheckOpts) Interaction {
        return controls.radio(ui, r, selected, label_str, opts);
    }

    /// A joined control of icon and/or text segments in one rounded container;
    /// the selected one is raised. Returns true when a click changed `selected`.
    pub fn segmented(ui: *Ui, r: Rect, items: []const Segment, selected: *usize, opts: SegmentedOpts) bool {
        return controls.segmented(ui, r, items, selected, opts);
    }

    /// A multi-line text editor with soft wrapping and vertical scrolling. See
    /// `text_area.zig` for the keys and mouse behaviour.
    pub fn textArea(ui: *Ui, r: Rect, st: *TextAreaState, opts: TextAreaOpts) TextAreaResult {
        return text_area.textArea(ui, r, st, opts);
    }

    /// Height of the rectangle `textArea` needs at `width` for the text in
    /// `st`, between `opts.min_lines` and `opts.max_lines` lines.
    pub fn measureTextArea(ui: *const Ui, st: *const TextAreaState, width: f32, opts: TextAreaOpts) f32 {
        return text_area.measureTextArea(ui, st, width, opts);
    }

    // ---- popups, menus, tooltips (see popup.zig) -----------------------

    /// True while any popup is open (was open last frame, or is being drawn). An app's own
    /// shortcuts should ignore keys then, since Escape and the arrows belong to the popup.
    pub fn popupOpen(ui: *const Ui) bool {
        return popup.anyOpen(ui);
    }

    /// Ends the frame: appends the overlay layers (popups, tooltips) to the main display list and
    /// remembers this frame's popup rectangles for next frame's input routing. Call after the
    /// last widget, before `Window.render`. Without it popups are not drawn.
    pub fn finish(ui: *Ui) void {
        if (ui.state) |s| s.grabs.rotate();
        popup.finish(ui);
    }

    /// Opens `st` (no-op if open). Opening from the click of a button is safe: the click that
    /// opens a popup never closes it.
    pub fn openPopup(ui: *Ui, st: *PopupState) void {
        popup.openPopup(ui, st);
    }

    pub fn closePopup(ui: *Ui, st: *PopupState) void {
        popup.closePopup(ui, st);
    }

    /// A floating panel next to `anchor`, of outer size `size`, drawn above everything. Returns
    /// the content rectangle (the panel inset by `opts.padding`) while open, else null; call
    /// `endPopup` only when it returned a rectangle. See `popup.zig`.
    pub fn beginPopup(ui: *Ui, st: *PopupState, anchor: Rect, size: [2]f32, opts: PopupOpts) ?Rect {
        return popup.beginPopup(ui, st, anchor, size, opts);
    }

    pub fn endPopup(ui: *Ui) void {
        popup.endPopup(ui);
    }

    /// A menu of `items` anchored to `anchor`. Returns the index activated this frame.
    pub fn menu(ui: *Ui, st: *PopupState, anchor: Rect, items: []const MenuItem, opts: MenuOpts) ?usize {
        return popup.menu(ui, st, anchor, items, opts);
    }

    /// Opens `st` at the pointer on a right click inside `area`; returns true on that frame.
    pub fn contextOpen(ui: *Ui, st: *PopupState, area: Rect) bool {
        return popup.contextOpen(ui, st, area);
    }

    /// `contextOpen` plus `menu` at the pointer: a context menu for `area`.
    pub fn contextMenu(ui: *Ui, st: *PopupState, area: Rect, items: []const MenuItem, opts: MenuOpts) ?usize {
        return popup.contextMenu(ui, st, area, items, opts);
    }

    /// A select control: shows `items[selected.*]`, opens a menu of all items. True when the
    /// selection changed.
    pub fn dropdown(ui: *Ui, r: Rect, st: *DropdownState, items: []const []const u8, selected: *usize, opts: DropdownOpts) bool {
        return popup.dropdown(ui, r, st, items, selected, opts);
    }

    /// Call after the widget occupying `r`: after the pointer rests in `r` for `opts.delay` a
    /// small label appears below (or above) it, on the top layer. Needs `ui.state`.
    pub fn tooltip(ui: *Ui, r: Rect, text: []const u8, opts: TooltipOpts) void {
        popup.tooltip(ui, r, text, opts);
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
        // Keys: Page Up/Down always; arrows and Home/End only while the focused widget (a text
        // field, a slider...) does not want them (`keyClaimed`).
        if (st.key_scroll or ui.hit(r).hovered) {
            for (ui.events()) |ev| switch (ev) {
                .key => |k| {
                    const free = st.arrow_keys and !ui.keyClaimed(k.code, k.mods);
                    switch (k.code) {
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
                    }
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
    /// Whether the arrow keys, Home and End scroll (Page Up/Down always do).
    /// Turn off when the app uses the arrows itself, e.g. to move a selection.
    arrow_keys: bool = true,

    /// Scrolls the least amount that brings the content span `top`..`bottom`
    /// (content coordinates, from the top of the content) fully into a
    /// viewport `view_h` tall. A span taller than the viewport shows its top.
    /// The offset is clamped to the content on the next `beginScroll`.
    pub fn reveal(st: *ScrollState, view_h: f32, top: f32, bottom: f32) void {
        if (top < st.offset) {
            st.offset = top;
        } else if (bottom > st.offset + view_h) {
            st.offset = @min(top, bottom - view_h);
        }
    }
};

/// Selection inside one `textSelectable` text: a byte range of the string it
/// is drawn with, from `anchor` (where the press began) to `cursor` (where the
/// pointer is now; may be before the anchor). Caller-owned and small: keep one
/// per piece of text at a stable address, its address is the selection's
/// identity in `State.select`.
///
/// When the string a `SelectState` goes with changes (edited, replaced, or the
/// state reused for different text) call `clear()`. Offsets are never trusted:
/// `range` clamps them to the string and snaps them to UTF-8 boundaries, so a
/// stale state selects the wrong text at worst, and never indexes out of bounds.
pub const SelectState = struct {
    anchor: usize = 0,
    cursor: usize = 0,
    /// What a double or triple click selected, so a drag grows by words or lines.
    multi: text_edit.MultiClick = .{},
    /// The right-click menu (Copy, Select All); lives here so there is nothing else to keep.
    ctx: PopupState = .{},

    pub fn clear(s: *SelectState) void {
        s.anchor = 0;
        s.cursor = 0;
    }

    /// The selected bytes of `str` as start <= end, clamped and on grapheme cluster boundaries.
    pub fn range(s: SelectState, str: []const u8) text_edit.TextEdit.Range {
        const a = text_edit.snapCluster(str, s.anchor);
        const c = text_edit.snapCluster(str, s.cursor);
        return .{ .start = @min(a, c), .end = @max(a, c) };
    }

    pub fn hasSelection(s: SelectState, str: []const u8) bool {
        const r = s.range(str);
        return r.end > r.start;
    }

    pub fn selectedText(s: SelectState, str: []const u8) []const u8 {
        const r = s.range(str);
        return str[r.start..r.end];
    }
};

/// Start and end of the "word" at caret position `pos`: the run of same-class
/// clusters (word characters, blanks, other punctuation) around it. Newlines
/// are never included. Both ends are grapheme cluster boundaries.
pub fn wordRange(str: []const u8, pos: usize) text_edit.TextEdit.Range {
    return text_edit.wordRange(str, pos);
}

/// State of one `textField`. Keep it at a stable address while the field
/// exists: the address is the field's focus identity.
pub const TextFieldState = struct {
    edit: TextEdit,
    /// Horizontal scroll of the text inside the field, in points.
    scroll_x: f32 = 0,
    blink_origin: f64 = 0,
    /// What a double or triple click selected, so a drag grows by words (or the whole text).
    multi: text_edit.MultiClick = .{},
    /// The right-click menu (Undo, Redo, Cut, Copy, Paste, Select All); drawn as a popup.
    ctx: PopupState = .{},
    /// The text as drawn (pre-edit spliced in, or bullets for a password), rebuilt each frame.
    disp: std.ArrayList(u8) = .empty,
    /// Pre-edit bookkeeping: was focused last frame, and a composition that was already running
    /// when focus arrived belongs to another widget (see `text_input.composingNow`).
    was_focused: bool = false,
    ime_block: bool = false,

    pub fn init(gpa: std.mem.Allocator) TextFieldState {
        return .{ .edit = TextEdit.init(gpa) };
    }

    pub fn deinit(s: *TextFieldState) void {
        s.disp.deinit(s.edit.gpa);
        s.edit.deinit();
    }

    /// Reverts the newest edit (see `TextEdit.undo`); returns false if there is none.
    pub fn undo(s: *TextFieldState) bool {
        return s.edit.undo();
    }

    pub fn redo(s: *TextFieldState) bool {
        return s.edit.redo();
    }

    pub fn canUndo(s: *const TextFieldState) bool {
        return s.edit.canUndo();
    }

    pub fn canRedo(s: *const TextFieldState) bool {
        return s.edit.canRedo();
    }

    pub fn clearHistory(s: *TextFieldState) void {
        s.edit.clearHistory();
    }
};

pub const TextFieldOpts = struct {
    /// Dim text shown while the field is empty.
    placeholder: []const u8 = "",
    /// Font size; defaults to the theme's body size.
    size: ?f32 = null,
    /// Draw only the text and caret: no border or fill, no inner padding. The
    /// caller draws whatever box it sits in (and can show focus itself).
    bare: bool = false,
    /// A password field: one bullet per grapheme cluster instead of the text, which is never
    /// drawn, never in the focus label and never copied. Cut and Copy do nothing (Paste works),
    /// a double or triple click selects all, Alt+arrows jump to the ends. An input-method
    /// pre-edit is shown too, but as underlined bullets, never as text.
    password: bool = false,
    /// A right click opens the Undo / Redo / Cut / Copy / Paste / Select All menu (needs `ui.state`).
    context_menu: bool = true,
};

pub const TextFieldResult = struct {
    /// The text changed this frame (typing, deleting, cut, paste).
    changed: bool = false,
    /// Return was pressed while focused.
    submitted: bool = false,
    /// The line the caret is on as a screen rectangle (the field's text box), and the caret's
    /// offset from its left edge: the same as `TextAreaResult`, for apps that call
    /// `Window.setTextInputArea` themselves. `textField` also tells the input method itself
    /// while focused, with a rectangle at the caret or pre-edit; a later app call replaces it.
    input_area: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    caret_x: f32 = 0,
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

test "layout leaves for text measure single lines and wrapped height" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ui = wrapUi(&list); // cpMeasure: one point per code point at size 1
    var lay = layout.Layout.init(arena.allocator());
    _ = lay.begin(.{ .dir = .col, .w = .fixed(10), .h = .fixed(100), .cross = .start });
    const one = ui.layText(&lay, "hello", 1, .{});
    const para = ui.layWrapped(&lay, "the quick brown fox", 1, .{});
    lay.end();
    lay.solve(.{ .x = 0, .y = 0, .w = 50, .h = 100 });
    const lh = ui.lineHeight(1);
    try std.testing.expectEqual(@as(f32, 5), lay.rect(one).w);
    try std.testing.expectEqual(lh, lay.rect(one).h);
    // Ten points wide: "the quick" / "brown fox".
    try std.testing.expectEqual(@as(f32, 10), lay.rect(para).w);
    try std.testing.expectEqual(2 * lh, lay.rect(para).h);
    try std.testing.expectEqual(ui.measureWrapped("the quick brown fox", 1, 10), lay.rect(para).h);
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

test "scroll: stays clamped as the viewport or content change size, never jumps to the top" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ss: ScrollState = .{ .offset = 150 };
    var r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    // The window grows during a resize: the viewport gets taller, so the maximum offset drops.
    const heights = [_]f32{ 100, 120, 150, 200, 260, 320 };
    for (heights) |h| {
        r.h = h;
        list.reset();
        var ui = Ui.initHeadless(&list, .{}, .{}, null);
        _ = ui.beginScroll(r, &ss, 300);
        ui.endScroll();
        try std.testing.expectEqual(@min(150, @max(0, 300 - h)), ss.offset);
    }
    // Shrinking again does not scroll back up, and an offset past the end is pulled in.
    r.h = 100;
    ss.offset = 500;
    var ui = Ui.initHeadless(&list, .{}, .{}, null);
    _ = ui.beginScroll(r, &ss, 300);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 200), ss.offset);
}

test "Input.idle keeps the pointer and held button but no one-shot state" {
    var in: Input = .{ .mouse_x = 5, .mouse_y = 6, .pressed = true, .down = true, .released = true, .wheel_y = 2 };
    in.pushText("a");
    const idle = in.idle();
    try std.testing.expect(!idle.pressed and !idle.released and idle.down);
    try std.testing.expectEqual(@as(f32, 0), idle.wheel_y);
    try std.testing.expectEqual(@as(usize, 0), idle.events().len);
    try std.testing.expectEqual(@as(f32, 5), idle.mouse_x);
    // The original still holds its click and key for the next real frame.
    try std.testing.expect(in.pressed);
    try std.testing.expectEqual(@as(usize, 1), in.events().len);
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

// ---- tests: selectable text -----------------------------------------------

/// One frame of a selectable text at (0,0), width 70 (7 chars of 10 points,
/// line height 14), shifted down by `dy` to imitate scrolling.
fn selFrame(list: *DisplayList, state: *State, in: Input, str: []const u8, st: *SelectState, dy: f32) f32 {
    list.reset();
    var ui = Ui.initHeadless(list, in, .{}, cpMeasure);
    ui.state = state;
    ui.clipboard = .{ .get = fakeClipGet, .set = fakeClipSet };
    return ui.textSelectable(.{ .x = 0, .y = dy, .w = 70, .h = 0 }, str, st, .{ .size = 10 });
}

fn highlights(list: *const DisplayList, out: []Rect) usize {
    const sel = (Theme{}).selection;
    var n: usize = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .rrect => |c| if (std.meta.eql(c.color, sel) and n < out.len) {
            out[n] = c.rect;
            n += 1;
        },
        else => {},
    };
    return n;
}

fn mouse(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y };
}

fn press(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y, .pressed = true, .down = true, .mouse_clicks = 1 };
}

fn dragTo(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y, .down = true };
}

fn release(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y, .released = true };
}

test "offsetAtPoint: lines, clamps, newlines, multi-byte" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const ui = wrapUi(&list);
    // "aaa bbb" / "ccc ddd": second line starts at byte 8.
    const s = "aaa bbb ccc ddd";
    try std.testing.expectEqual(@as(usize, 2), ui.offsetAtPoint(s, 10, 70, 24, 5));
    try std.testing.expectEqual(@as(usize, 3), ui.offsetAtPoint(s, 10, 70, 26, 5));
    try std.testing.expectEqual(@as(usize, 8 + 2), ui.offsetAtPoint(s, 10, 70, 24, 14 + 5));
    // Left of a line: its start; right of a line: its end (not the next line's start).
    try std.testing.expectEqual(@as(usize, 0), ui.offsetAtPoint(s, 10, 70, -30, 5));
    try std.testing.expectEqual(@as(usize, 8), ui.offsetAtPoint(s, 10, 70, -30, 20));
    try std.testing.expectEqual(@as(usize, 7), ui.offsetAtPoint(s, 10, 70, 500, 5));
    try std.testing.expectEqual(@as(usize, 15), ui.offsetAtPoint(s, 10, 70, 500, 20));
    // Above everything: 0. Below everything: the end.
    try std.testing.expectEqual(@as(usize, 0), ui.offsetAtPoint(s, 10, 70, 40, -50));
    try std.testing.expectEqual(@as(usize, 15), ui.offsetAtPoint(s, 10, 70, 0, 28));
    try std.testing.expectEqual(@as(usize, 15), ui.offsetAtPoint(s, 10, 70, 0, 900));
    try std.testing.expectEqual(@as(usize, 0), ui.offsetAtPoint("", 10, 70, 5, 5));
    // Explicit newlines and a blank line: "ab\n\ncd".
    const n = "ab\n\ncd";
    try std.testing.expectEqual(@as(usize, 2), ui.offsetAtPoint(n, 10, 70, 100, 5));
    try std.testing.expectEqual(@as(usize, 3), ui.offsetAtPoint(n, 10, 70, 100, 14 + 5));
    try std.testing.expectEqual(@as(usize, 5), ui.offsetAtPoint(n, 10, 70, 11, 28 + 5));
    // Multi-byte: "éé😀x" one cell per code point; offsets land on boundaries.
    const m = "éé😀x";
    try std.testing.expectEqual(@as(usize, 2), ui.offsetAtPoint(m, 10, 70, 11, 5));
    try std.testing.expectEqual(@as(usize, 4), ui.offsetAtPoint(m, 10, 70, 21, 5));
    try std.testing.expectEqual(@as(usize, 8), ui.offsetAtPoint(m, 10, 70, 31, 5));
    try std.testing.expectEqual(@as(usize, 9), ui.offsetAtPoint(m, 10, 70, 99, 5));
}

test "textSelectable draws like labelWrapped" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{};
    const h = selFrame(&list, &state, .{}, "aaa bbb ccc ddd", &st, 3);
    try std.testing.expectEqual(@as(f32, 28), h);
    var ui = wrapUi(&list);
    const want = ui.measureWrapped("aaa bbb ccc ddd", 10, 70);
    try std.testing.expectEqual(want, h);
    var texts: usize = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .text => texts += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), texts);
    // No state: plain label, no interaction.
    list.reset();
    ui = Ui.initHeadless(&list, press(5, 5), .{}, cpMeasure);
    _ = ui.textSelectable(.{ .x = 0, .y = 0, .w = 70, .h = 0 }, "aaa", &st, .{ .size = 10 });
    try std.testing.expect(!st.hasSelection("aaa"));
}

test "textSelectable: drag selects across wrapped lines, release keeps it" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{};
    const s = "aaa bbb ccc ddd";
    _ = selFrame(&list, &state, press(15, 5), s, &st, 0);
    try std.testing.expect(state.select == @as(*const anyopaque, &st));
    try std.testing.expect(!st.hasSelection(s));
    _ = selFrame(&list, &state, dragTo(35, 14 + 5), s, &st, 0);
    // Tie points round to the later boundary: 15 -> 2, 35 -> 4 on the second line.
    try std.testing.expectEqualStrings("a bbb ccc ", st.selectedText(s));
    try std.testing.expect(state.drag == @as(*const anyopaque, &st));
    var hl: [4]Rect = undefined;
    // Highlight per visual line: line 1 from x=20 to its end (70), line 2 from 0 to 40.
    try std.testing.expectEqual(@as(usize, 2), highlights(&list, &hl));
    try std.testing.expectEqual(Rect{ .x = 20, .y = 0, .w = 50, .h = 14 }, hl[0]);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 14, .w = 40, .h = 14 }, hl[1]);
    // Highlight comes before the text commands (drawn behind).
    try std.testing.expect(list.cmds.items[0] == .rrect);
    // Pointer leaves the text entirely: still tracking; far below selects to the end.
    _ = selFrame(&list, &state, dragTo(900, 900), s, &st, 0);
    try std.testing.expectEqual(@as(usize, 15), st.cursor);
    // Far above selects to the start.
    _ = selFrame(&list, &state, dragTo(-90, -90), s, &st, 0);
    try std.testing.expectEqual(@as(usize, 0), st.cursor);
    try std.testing.expectEqual(@as(usize, 2), st.anchor);
    // Release ends the drag (final position applied); later motion changes nothing.
    _ = selFrame(&list, &state, release(15, 19), s, &st, 0);
    try std.testing.expect(state.drag == null);
    try std.testing.expectEqual(@as(usize, 10), st.cursor);
    _ = selFrame(&list, &state, dragTo(60, 5), s, &st, 0);
    try std.testing.expectEqual(@as(usize, 10), st.cursor);
    try std.testing.expect(st.hasSelection(s));
}

test "textSelectable: plain click, click elsewhere and escape clear" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{};
    const s = "aaa bbb ccc ddd";
    _ = selFrame(&list, &state, press(15, 5), s, &st, 0);
    _ = selFrame(&list, &state, dragTo(55, 5), s, &st, 0);
    _ = selFrame(&list, &state, release(55, 5), s, &st, 0);
    try std.testing.expect(st.hasSelection(s));
    // A plain click (press and release in place) inside: no selection.
    _ = selFrame(&list, &state, press(35, 5), s, &st, 0);
    _ = selFrame(&list, &state, release(35, 5), s, &st, 0);
    try std.testing.expect(!st.hasSelection(s));
    var hl: [4]Rect = undefined;
    try std.testing.expectEqual(@as(usize, 0), highlights(&list, &hl));
    // Select again, then click outside the text.
    _ = selFrame(&list, &state, press(15, 5), s, &st, 0);
    _ = selFrame(&list, &state, dragTo(55, 5), s, &st, 0);
    _ = selFrame(&list, &state, release(55, 5), s, &st, 0);
    try std.testing.expect(st.hasSelection(s));
    var in = press(300, 300);
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expect(!st.hasSelection(s) and state.select == null);
    // Escape clears.
    _ = selFrame(&list, &state, press(15, 5), s, &st, 0);
    _ = selFrame(&list, &state, dragTo(55, 5), s, &st, 0);
    _ = selFrame(&list, &state, release(55, 5), s, &st, 0);
    in = .{};
    in.pushKey(keys.escape, .{});
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expect(!st.hasSelection(s) and state.select == null);
}

test "textSelectable: double click selects the word, triple the line" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{};
    const s = "aaa bbb\nccc ddd";
    var in = press(45, 5);
    in.mouse_clicks = 2;
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expectEqualStrings("bbb", st.selectedText(s));
    // The button is still down: dragging now grows the selection by words (see the next test).
    try std.testing.expect(state.drag != null);
    in.mouse_clicks = 3;
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expectEqualStrings("aaa bbb", st.selectedText(s));
    in = press(5, 14 + 5);
    in.mouse_clicks = 2;
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expectEqualStrings("ccc", st.selectedText(s));
    // On the blank between words: the blank.
    in = press(33, 14 + 5);
    in.mouse_clicks = 2;
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expectEqualStrings(" ", st.selectedText(s));
}

test "textSelectable: shift-click extends" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{};
    const s = "aaa bbb ccc ddd";
    _ = selFrame(&list, &state, press(15, 5), s, &st, 0);
    _ = selFrame(&list, &state, release(35, 5), s, &st, 0);
    var in = press(65, 5);
    in.mouse_mods = .{ .shift = true };
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expectEqual(@as(usize, 2), st.anchor);
    try std.testing.expectEqual(@as(usize, 7), st.cursor);
}

test "textSelectable: exclusive with another text and with text fields" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var a: SelectState = .{};
    var b: SelectState = .{};
    var field = TextFieldState.init(std.testing.allocator);
    defer field.deinit();
    const s = "aaa bbb ccc ddd";
    _ = selFrame(&list, &state, press(15, 5), s, &a, 0);
    _ = selFrame(&list, &state, release(55, 5), s, &a, 0);
    try std.testing.expect(a.hasSelection(s));
    // Starting a selection in b (a lower text, y 100..) takes the selection.
    list.reset();
    {
        var ui = Ui.initHeadless(&list, press(15, 105), .{}, cpMeasure);
        ui.state = &state;
        _ = ui.textSelectable(.{ .x = 0, .y = 0, .w = 70, .h = 0 }, s, &a, .{ .size = 10 });
        _ = ui.textSelectable(.{ .x = 0, .y = 100, .w = 70, .h = 0 }, s, &b, .{ .size = 10 });
    }
    try std.testing.expect(state.select == @as(*const anyopaque, &b));
    try std.testing.expect(!a.hasSelection(s));
    // b selects something, then a text field is clicked: selection and focus swap.
    {
        var ui = Ui.initHeadless(&list, dragTo(55, 105), .{}, cpMeasure);
        ui.state = &state;
        _ = ui.textSelectable(.{ .x = 0, .y = 100, .w = 70, .h = 0 }, s, &b, .{ .size = 10 });
    }
    try std.testing.expect(b.hasSelection(s));
    _ = fieldFrame(&list, &state, press(5, 205), &field, .{ .x = 0, .y = 200, .w = 100, .h = 30 });
    try std.testing.expect(state.focus == @as(*const anyopaque, &field));
    try std.testing.expect(state.select == null);
    {
        var ui = Ui.initHeadless(&list, .{}, .{}, cpMeasure);
        ui.state = &state;
        _ = ui.textSelectable(.{ .x = 0, .y = 100, .w = 70, .h = 0 }, s, &b, .{ .size = 10 });
    }
    try std.testing.expect(!b.hasSelection(s)); // cleared lazily
    // Pressing in the text blurs the focused field.
    _ = selFrame(&list, &state, press(15, 5), s, &a, 0);
    try std.testing.expect(state.focus == null and state.select == @as(*const anyopaque, &a));
}

test "textSelectable: cmd+C copies, cmd+A selects all" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{};
    const s = "aaa bbb ccc ddd";
    fake_clip_len = 0;
    // Nothing owns the selection yet: keys do nothing.
    var in: Input = .{};
    in.pushKey(keys.c, .{ .cmd = true });
    in.pushKey(keys.a, .{ .cmd = true });
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expect(!st.hasSelection(s) and fake_clip_len == 0);
    _ = selFrame(&list, &state, press(15, 5), s, &st, 0);
    _ = selFrame(&list, &state, release(35, 5), s, &st, 0);
    in = .{};
    in.pushKey(keys.c, .{ .cmd = true });
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expectEqualStrings("a ", fake_clip[0..fake_clip_len]);
    in = .{};
    in.pushKey(keys.a, .{ .cmd = true });
    in.pushKey(keys.c, .{ .cmd = true });
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expectEqualStrings(s, fake_clip[0..fake_clip_len]);
    // Spans a line break: highlight on both lines, the break stub on the first.
    var hl: [4]Rect = undefined;
    try std.testing.expectEqual(@as(usize, 2), highlights(&list, &hl));
    try std.testing.expectEqual(@as(f32, 70), hl[0].x + hl[0].w);
}

test "textSelectable: stale state never indexes out of bounds" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{ .anchor = 5, .cursor = 400 };
    state.select = &st;
    const s = "héllo"; // 6 bytes
    var in: Input = .{};
    in.pushKey(keys.c, .{ .cmd = true });
    _ = selFrame(&list, &state, in, s, &st, 0);
    try std.testing.expectEqualStrings("o", fake_clip[0..fake_clip_len]);
    // Mid-character offsets snap back; shorter and empty text are fine.
    st = .{ .anchor = 2, .cursor = 3 };
    try std.testing.expectEqualStrings("é", st.selectedText(s));
    try std.testing.expect(!(SelectState{ .anchor = 2, .cursor = 2 }).hasSelection(s));
    st = .{ .anchor = 0, .cursor = 99 };
    _ = selFrame(&list, &state, .{}, "", &st, 0);
    try std.testing.expect(!st.hasSelection(""));
    try std.testing.expectEqualStrings("", st.selectedText(""));
    st = .{ .anchor = 1, .cursor = 4 };
    state.select = &st;
    _ = selFrame(&list, &state, .{}, "ab", &st, 0);
    try std.testing.expectEqualStrings("b", st.selectedText("ab"));
}

test "textSelectable: inside a scroll area" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{};
    var sc: ScrollState = .{};
    const s = "aaa bbb ccc ddd";
    const view: Rect = .{ .x = 0, .y = 0, .w = 70, .h = 20 };
    const Frame = struct {
        fn run(l: *DisplayList, stt: *State, in: Input, str: []const u8, sel: *SelectState, scroll: *ScrollState) void {
            l.reset();
            var ui = Ui.initHeadless(l, in, .{}, cpMeasure);
            ui.state = stt;
            const c = ui.beginScroll(.{ .x = 0, .y = 0, .w = 70, .h = 20 }, scroll, 100);
            _ = ui.textSelectable(.{ .x = 0, .y = c.y + 10, .w = 70, .h = 0 }, str, sel, .{ .size = 10 });
            ui.endScroll();
        }
    };
    _ = view;
    // Press in the visible part (y 15 is inside text at y 10..38 and the clip 0..20).
    Frame.run(&list, &state, press(15, 15), s, &st, &sc);
    try std.testing.expect(state.select == @as(*const anyopaque, &st));
    // Content scrolls under the held mouse: pointer at y 15 now hits line 2 (scroll 14).
    sc.offset = 14;
    Frame.run(&list, &state, dragTo(35, 15), s, &st, &sc);
    try std.testing.expectEqual(@as(usize, 2), st.anchor);
    try std.testing.expectEqual(@as(usize, 8 + 4), st.cursor);
    // Pointer far outside the clip: drag keeps tracking.
    Frame.run(&list, &state, dragTo(35, 400), s, &st, &sc);
    try std.testing.expectEqual(@as(usize, 15), st.cursor);
    Frame.run(&list, &state, release(35, 400), s, &st, &sc);
    // A press outside the clip (y 25, text is there but clipped away) starts nothing
    // and clears.
    Frame.run(&list, &state, press(15, 25), s, &st, &sc);
    try std.testing.expect(!st.hasSelection(s) and state.select == null);
    // Highlights are inside the pushed clip.
    var hl: [4]Rect = undefined;
    st = .{ .anchor = 0, .cursor = 15 };
    state.select = &st;
    Frame.run(&list, &state, .{}, s, &st, &sc);
    try std.testing.expect(highlights(&list, &hl) >= 1);
    try std.testing.expect(list.cmds.items[0] == .push_clip);
}

test "arrow keys scroll while a text selection holds the selection, not while a field has focus" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st: SelectState = .{};
    var sc: ScrollState = .{ .key_scroll = true };
    const s = "aaa bbb ccc ddd";
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    _ = selFrame(&list, &state, press(15, 5), s, &st, 0);
    _ = selFrame(&list, &state, release(55, 5), s, &st, 0);
    try std.testing.expect(state.select != null);
    var in: Input = .{};
    in.pushKey(keys.down, .{});
    var ui = Ui.initHeadless(&list, in, .{}, null);
    ui.state = &state;
    _ = ui.beginScroll(r, &sc, 1000);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 48), sc.offset);
    try std.testing.expect(st.hasSelection(s)); // arrows leave the selection alone
    // With a text field focused, arrows are not free.
    var field = TextFieldState.init(std.testing.allocator);
    defer field.deinit();
    state.focus = &field;
    ui = Ui.initHeadless(&list, in, .{}, null);
    ui.state = &state;
    _ = ui.beginScroll(r, &sc, 1000);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 48), sc.offset);
}

test "input: click count is plumbed from mouse_down" {
    var in: Input = .{};
    in.feed(.{ .mouse_down = .{ .window = 1, .x = 1, .y = 1, .button = 1, .clicks = 2 } }, 1);
    try std.testing.expectEqual(@as(u8, 2), in.mouse_clicks);
    in.feed(.{ .mouse_down = .{ .window = 1, .x = 1, .y = 1, .button = 1 } }, 1);
    try std.testing.expectEqual(@as(u8, 1), in.mouse_clicks);
}

// ---- tests: list helpers --------------------------------------------------

test "ScrollState.reveal scrolls the least amount" {
    var st: ScrollState = .{ .offset = 100 };
    st.reveal(200, 150, 190); // already visible
    try std.testing.expectEqual(@as(f32, 100), st.offset);
    st.reveal(200, 40, 80); // above: align its top
    try std.testing.expectEqual(@as(f32, 40), st.offset);
    st.reveal(200, 300, 360); // below: align its bottom
    try std.testing.expectEqual(@as(f32, 160), st.offset);
    st.reveal(50, 400, 500); // taller than the view: top wins
    try std.testing.expectEqual(@as(f32, 400), st.offset);
}

test "arrow_keys = false leaves the arrows to the app but Page Down still scrolls" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var in: Input = .{ .mouse_x = 5, .mouse_y = 5 };
    in.pushKey(keys.down, .{});
    var ui = Ui.initHeadless(&list, in, .{}, cpMeasure);
    var st: ScrollState = .{ .arrow_keys = false };
    _ = ui.beginScroll(.{ .x = 0, .y = 0, .w = 50, .h = 50 }, &st, 500);
    ui.endScroll();
    try std.testing.expectEqual(@as(f32, 0), st.offset);
    var in2: Input = .{ .mouse_x = 5, .mouse_y = 5 };
    in2.pushKey(keys.page_down, .{});
    var ui2 = Ui.initHeadless(&list, in2, .{}, cpMeasure);
    _ = ui2.beginScroll(.{ .x = 0, .y = 0, .w = 50, .h = 50 }, &st, 500);
    ui2.endScroll();
    try std.testing.expectEqual(@as(f32, 45), st.offset);
}

test "flattenText collapses whitespace and keeps utf8 whole" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a b c d", Ui.flattenText(&buf, "  a\n\nb \t c\r\nd  "));
    try std.testing.expectEqualStrings("", Ui.flattenText(&buf, " \n "));
    var small: [4]u8 = undefined;
    // "aéé": 'a' (1) + 'é' (2) fit in 4 bytes; the second 'é' would be cut in half.
    try std.testing.expectEqualStrings("aé", Ui.flattenText(&small, "aééé"));
}

test "labelLines wraps to a line limit and ends the last line with an ellipsis" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var ui = wrapUi(&list);
    ui.theme.line_spacing = 1;
    // One unit per character at size 1; width 10.
    const h = ui.labelLines(.{ .x = 0, .y = 0, .w = 10, .h = 0 }, "aaaa bbbb cccc dddd eeee", 2, .{ .size = 1 });
    try std.testing.expectEqual(@as(f32, 2), h);
    var lines: [4][]const u8 = undefined;
    var n: usize = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .text => |tx| {
            lines[n] = tx.str;
            n += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("aaaa bbbb", lines[0]);
    try std.testing.expectEqualStrings("cccc dd...", lines[1]);

    // Fits entirely: no ellipsis.
    list.reset();
    _ = ui.labelLines(.{ .x = 0, .y = 0, .w = 10, .h = 0 }, "aaaa bbbb cccc", 2, .{ .size = 1 });
    try std.testing.expectEqualStrings("cccc", list.cmds.items[1].text.str);
}

test "chip and listRow report the pointer; weight reaches the display list" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 60, .h = 20 };
    var ui = testUi(&list, 10, 10, true);
    const hit = ui.chip(r, "tag", .{ .weight = .semibold });
    try std.testing.expect(hit.clicked);
    try std.testing.expectEqual(gfx.Weight.semibold, list.cmds.items[list.cmds.items.len - 1].text.weight);
    try std.testing.expectEqual(@as(f32, 17), ui.chipWidth("tag", .{ .size = 2 }, 7));

    list.reset();
    var miss = testUi(&list, 100, 10, true);
    try std.testing.expect(!miss.listRow(r, .{}).clicked);
    try std.testing.expectEqual(@as(usize, 0), list.cmds.items.len); // no highlight
    _ = miss.listRow(r, .{ .selected = true });
    try std.testing.expectEqual(@as(usize, 1), list.cmds.items.len);
}

test "iconButton: hover tints, disabled never clicks, mouse_leave clears hover" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 28, .h = 28 };
    var ui = testUi(&list, 10, 10, true);
    try std.testing.expect(ui.iconButton(r, .search, .{}).clicked);
    try std.testing.expect(list.cmds.items[0] == .rrect); // hover background
    list.reset();
    var off = testUi(&list, 10, 10, true);
    const res = off.iconButton(r, .search, .{ .disabled = true });
    try std.testing.expect(!res.clicked and !res.hovered);
    try std.testing.expect(list.cmds.items[0] == .arc); // no background, just the icon
    var in: Input = .{ .mouse_x = 10, .mouse_y = 10 };
    in.feed(.{ .mouse_leave = 7 }, 3); // another window: no change
    try std.testing.expectEqual(@as(f32, 10), in.mouse_x);
    in.feed(.{ .mouse_leave = 3 }, 3);
    list.reset();
    var gone = Ui.initHeadless(&list, in, .{}, null);
    try std.testing.expect(!gone.iconButton(r, .search, .{}).hovered);
}

test "input collects dropped files per frame and tracks the drag" {
    var in: Input = .{};
    in.feed(.{ .drop_begin = 1 }, 1);
    try std.testing.expect(in.drop_active);
    in.feed(.{ .drop_position = .{ .window = 1, .x = 12, .y = 34 } }, 1);
    try std.testing.expectEqual(@as(f32, 12), in.drop_x);
    in.feed(.{ .file_drop = .{ .window = 2, .x = 0, .y = 0, .path = backend.DropPath.from("/other.png").? } }, 1); // other window
    in.feed(.{ .file_drop = .{ .window = 1, .x = 12, .y = 34, .path = backend.DropPath.from("/tmp/a.png").? } }, 1);
    in.feed(.{ .file_drop = .{ .window = 1, .x = 12, .y = 34, .path = backend.DropPath.from("/tmp/b.jpg").? } }, 1);
    in.feed(.{ .drop_complete = 1 }, 1);
    try std.testing.expect(!in.drop_active);
    try std.testing.expectEqual(@as(usize, 2), in.droppedFiles().len);
    try std.testing.expectEqualStrings("/tmp/b.jpg", in.droppedFiles()[1].slice());
    in.endFrame();
    try std.testing.expectEqual(@as(usize, 0), in.droppedFiles().len);
}

test "Ui.image records a command and reports hover" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var in: Input = .{ .mouse_x = 5, .mouse_y = 5 };
    var ui = Ui.initHeadless(&list, in, .{}, null);
    const img: gfx.Image = .{ .id = 7, .width = 2, .height = 2 };
    const r = ui.image(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, img, .{ .fit = .cover });
    try std.testing.expect(r.hovered);
    try std.testing.expectEqual(@as(usize, 1), list.cmds.items.len);
    in.endFrame();
}

test "icon widgets accept built-ins, Icon values, SvgIcon and Source" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    const r: Rect = .{ .x = 0, .y = 0, .w = 30, .h = 30 };
    var ui = Ui.initHeadless(&list, .{ .mouse_x = 15, .mouse_y = 15, .pressed = true }, .{}, null);
    const ic: icons.Icon = .plus;
    const sv: gfx.SvgIcon = .{ .id = 5, .aspect = 1 };
    try std.testing.expect(ui.iconButton(r, .search, .{}).clicked); // enum literal
    try std.testing.expect(ui.iconButton(r, ic, .{}).clicked); // Icon value
    list.reset();
    try std.testing.expect(ui.iconButton(r, sv, .{ .icon_size = 16 }).clicked);
    try std.testing.expect(ui.iconButton(r, icons.Source{ .svg = sv }, .{ .disabled = true, .icon_size = 16 }).clicked == false);
    var found: usize = 0;
    for (list.cmds.items) |cmd| switch (cmd) {
        .svg_icon => |s| {
            found += 1;
            try std.testing.expectEqual(@as(u32, 5), s.icon.id);
            try std.testing.expectEqual(@as(f32, 16), s.rect.w); // centred icon_size square
            try std.testing.expectEqual(@as(f32, 7), s.rect.x);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), found);
    // Segments take both kinds, written as before.
    const segs = [_]Segment{ .{ .icon = .search }, .{ .icon = .{ .svg = sv }, .label = "x" } };
    try std.testing.expect(segs[0].icon.?.builtin == .search);
    list.reset();
    ui.drawIcon(r, SvgIcon_none, Color.hex(0xffffff)); // an invalid handle is recorded; the backend draws nothing
    try std.testing.expectEqual(@as(usize, 1), list.cmds.items.len);
}

const SvgIcon_none: gfx.SvgIcon = .none;

test "textField: Cmd+Z / Cmd+Shift+Z undo and redo through the Ui and report changed" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextFieldState.init(std.testing.allocator);
    defer st.deinit();
    state.focusOn(&st);
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 30 };

    var in: Input = .{ .time = 1 };
    in.pushText("hello");
    try std.testing.expect(fieldFrame(&list, &state, in, &st, r).changed);
    in = .{ .time = 1.2 };
    in.pushText(" world");
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(st.canUndo() and !st.canRedo());

    in = .{ .time = 1.4 };
    in.pushKey(keys.z, .{ .cmd = true });
    try std.testing.expect(fieldFrame(&list, &state, in, &st, r).changed);
    try std.testing.expectEqualStrings("hello", st.edit.text());
    try std.testing.expect(st.canRedo());
    in = .{ .time = 1.5 };
    in.pushKey(keys.z, .{ .cmd = true, .shift = true });
    try std.testing.expect(fieldFrame(&list, &state, in, &st, r).changed);
    try std.testing.expectEqualStrings("hello world", st.edit.text());
    // Nothing more to redo: consumed, not changed.
    in = .{ .time = 1.6 };
    in.pushKey(keys.z, .{ .cmd = true, .shift = true });
    try std.testing.expect(!fieldFrame(&list, &state, in, &st, r).changed);
    // Undo twice reaches the empty field; the caret was restored.
    in = .{ .time = 1.7 };
    in.pushKey(keys.z, .{ .cmd = true });
    in.pushKey(keys.z, .{ .cmd = true });
    try std.testing.expect(fieldFrame(&list, &state, in, &st, r).changed);
    try std.testing.expectEqualStrings("", st.edit.text());
    try std.testing.expectEqual(@as(usize, 0), st.edit.cursor);
    // A pause between keystrokes (Input.time) splits the run.
    in = .{ .time = 5 };
    in.pushText("a");
    _ = fieldFrame(&list, &state, in, &st, r);
    in = .{ .time = 7 };
    in.pushText("b");
    _ = fieldFrame(&list, &state, in, &st, r);
    in = .{ .time = 7.1 };
    in.pushKey(keys.z, .{ .cmd = true });
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expectEqualStrings("a", st.edit.text());
    // Pasting is one step, undone as a whole, and the caret returns.
    fake_clip_len = 0;
    fakeClipSet(std.testing.allocator, "pasted text");
    in = .{ .time = 8 };
    in.pushKey(keys.v, .{ .cmd = true });
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expectEqualStrings("apasted text", st.edit.text());
    in = .{ .time = 8.1 };
    in.pushKey(keys.z, .{ .cmd = true });
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expectEqualStrings("a", st.edit.text());
    try std.testing.expectEqual(@as(usize, 1), st.edit.cursor);
}

test "textField: undo keeps the caret visible" {
    var list = DisplayList.init(std.testing.allocator);
    defer list.deinit();
    var state: State = .{};
    var st = TextFieldState.init(std.testing.allocator);
    defer st.deinit();
    state.focusOn(&st);
    const r: Rect = .{ .x = 0, .y = 0, .w = 30, .h = 30 }; // 10 wide inside, one unit per char
    var in: Input = .{};
    in.pushText("0123456789abcdefghijklmnopqrstuvwxyz");
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expect(st.scroll_x > 0);
    // Undo the whole typing: the text is empty, the caret and scroll are back at the start.
    in = .{};
    in.pushKey(keys.z, .{ .cmd = true });
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expectEqual(@as(f32, 0), st.scroll_x);
    in = .{};
    in.pushKey(keys.z, .{ .cmd = true, .shift = true });
    _ = fieldFrame(&list, &state, in, &st, r);
    try std.testing.expectEqual(@as(usize, 36), st.edit.cursor);
    try std.testing.expect(st.scroll_x > 0);
}

test "Input.feed: events of other windows change nothing, whatever their type" {
    var in: Input = .{ .mouse_x = 5, .mouse_y = 6 };
    const other: u32 = 9;
    in.feed(.{ .mouse_move = .{ .window = other, .x = 50, .y = 60 } }, 1);
    in.feed(.{ .mouse_down = .{ .window = other, .x = 1, .y = 1, .button = 1 } }, 1);
    in.feed(.{ .mouse_down = .{ .window = other, .x = 1, .y = 1, .button = 3 } }, 1);
    in.feed(.{ .mouse_up = .{ .window = other, .x = 1, .y = 1, .button = 1 } }, 1);
    in.feed(.{ .mouse_wheel = .{ .window = other, .dx = 1, .dy = 2 } }, 1);
    in.feed(.{ .key_down = .{ .code = 'a', .window = other } }, 1);
    in.feed(.{ .text_input = .{ .window = other, .text = backend.TextChunk.from("x") } }, 1);
    in.feed(.{ .text_editing = .{ .window = other, .comp = .{} } }, 1);
    in.feed(.{ .mouse_leave = other }, 1);
    in.feed(.{ .focus_lost = other }, 1);
    in.feed(.{ .focus_gained = other }, 1);
    in.feed(.{ .drop_begin = other }, 1);
    in.feed(.{ .drop_position = .{ .window = other, .x = 1, .y = 1 } }, 1);
    in.feed(.{ .drop_complete = other }, 1);
    in.feed(.{ .close_requested = 1 }, 1); // not input: the app handles it
    try std.testing.expectEqual(@as(f32, 5), in.mouse_x);
    try std.testing.expectEqual(@as(f32, 6), in.mouse_y);
    try std.testing.expect(!in.pressed and !in.down and !in.released and !in.right_pressed and !in.drop_active and in.window_focused);
    try std.testing.expectEqual(@as(f32, 0), in.wheel_y);
    try std.testing.expectEqual(@as(usize, 0), in.events().len);
}

test "Input.feed: losing focus ends a held button and a composition; leaving the window keeps the drag" {
    var in: Input = .{};
    in.feed(.{ .mouse_down = .{ .window = 1, .x = 10, .y = 10, .button = 1 } }, 1);
    try std.testing.expect(in.down);
    // The pointer leaves (the OS captures the mouse during a drag): hover is gone, the drag is not.
    in.feed(.{ .mouse_leave = 1 }, 1);
    try std.testing.expect(in.mouse_x < -1e8 and in.down);
    in.endFrame();
    in.composition = .{ .len = 2, .start = 0, .length = 2 };
    in.drop_active = true;
    in.feed(.{ .focus_lost = 1 }, 1);
    // No release will arrive from the OS: the press ends now, as a release.
    try std.testing.expect(!in.down and in.released);
    try std.testing.expect(!in.window_focused and in.composition.len == 0 and !in.drop_active);
    in.feed(.{ .focus_gained = 1 }, 1);
    try std.testing.expect(in.window_focused);
    // Focus lost with nothing held is not a release.
    in.endFrame();
    in.feed(.{ .focus_lost = 1 }, 1);
    try std.testing.expect(!in.released);
}
