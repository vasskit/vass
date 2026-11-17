//! Headless, multi-frame tests of keyboard focus (see focus.zig).
const std = @import("std");
const geom = @import("../core/geom.zig");
const gfx = @import("../core/gfx.zig");
const keys = @import("../core/keys.zig");
const ui_mod = @import("ui.zig");
const focus = @import("focus.zig");
const Rect = geom.Rect;
const Ui = ui_mod.Ui;
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

    fn arcs(r: *const Rig) usize {
        var n: usize = 0;
        for (r.list.cmds.items) |c| if (c == .arc) {
            n += 1;
        };
        return n;
    }

    fn focusedLabel(r: *const Rig) []const u8 {
        const id = r.state.focusId() orelse return "<none>";
        for (r.state.focusEntries()) |*e| if (e.id == id) return e.label();
        return "<unlisted>";
    }
};

fn keyIn(code: u32, mods: keys.Mods) Input {
    var in: Input = .{};
    in.pushKey(code, mods);
    return in;
}

fn tab() Input {
    return keyIn(keys.tab, .{});
}

fn clickAt(x: f32, y: f32) Input {
    return .{ .mouse_x = x, .mouse_y = y, .pressed = true, .down = true };
}

fn row(i: usize) Rect {
    return .{ .x = 0, .y = @as(f32, @floatFromInt(i)) * 30, .w = 200, .h = 26 };
}

// ---- a scene with one of everything ---------------------------------------------------------

const Scene = struct {
    check: bool = false,
    tog: bool = false,
    radio: usize = 0,
    seg: usize = 1,
    tabsel: usize = 0,
    slider: f32 = 5,
    dd: ui_mod.DropdownState = .{},
    dd_sel: usize = 0,
    field: ui_mod.TextFieldState,
    area: ui_mod.TextAreaState,
    tab_inserts: bool = false,
    // Results of the last frame.
    btn: bool = false,
    icon: bool = false,
    chip: bool = false,
    pill: bool = false,
    list_row: bool = false,
    radio_click: bool = false,
    seg_changed: bool = false,
    tabs_changed: bool = false,
    slider_changed: bool = false,
    dd_changed: bool = false,
    /// Keys left in `ui.events()` after the widgets ran.
    leftover: usize = 0,

    fn init() Scene {
        return .{ .field = ui_mod.TextFieldState.init(t.allocator), .area = ui_mod.TextAreaState.init(t.allocator) };
    }

    fn deinit(s: *Scene) void {
        s.field.deinit();
        s.area.deinit();
    }
};

// Entry indices of the scene, in call order.
const e_btn = 0;
const e_off = 1;
const e_check = 2;
const e_tog = 3;
const e_r1 = 4;
const e_r2 = 5;
const e_seg = 6;
const e_tabs = 7;
const e_slider = 8;
const e_icon = 9;
const e_chip = 10;
const e_pill = 11;
const e_row = 12;
const e_dd = 13;
const e_field = 14;
const e_area = 15;
const e_count = 16;

fn drawScene(ui: *Ui, s: *Scene) void {
    s.btn = ui.button(row(0), "Btn", .{});
    _ = ui.button(row(1), "Off", .{ .disabled = true });
    _ = ui.checkbox(row(2), &s.check, "Check", .{});
    _ = ui.toggle(row(3), &s.tog, .{ .label = "Tog" });
    if (ui.radio(row(4), s.radio == 0, "R1", .{}).clicked) {
        s.radio = 0;
        s.radio_click = true;
    }
    if (ui.radio(row(5), s.radio == 1, "R2", .{}).clicked) s.radio = 1;
    s.seg_changed = ui.segmented(row(6), &.{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } }, &s.seg, .{});
    s.tabs_changed = ui.tabs(row(7), &.{ "One", "Two", "Three" }, &s.tabsel);
    s.slider_changed = ui.slider(row(8), &s.slider, .{ .min = 0, .max = 10, .step = 1 }).changed;
    s.icon = ui.iconButton(row(9), .search, .{ .label = "Search" }).clicked;
    s.chip = ui.chip(row(10), "Chip", .{ .focusable = true }).clicked;
    s.pill = ui.pill(row(11), "Pill", false);
    s.list_row = ui.listRow(row(12), .{ .label = "Row" }).clicked;
    s.dd_changed = ui.dropdown(row(13), &s.dd, &.{ "x", "y", "z" }, &s.dd_sel, .{});
    _ = ui.textField(row(14), &s.field, .{ .placeholder = "Field" });
    _ = ui.textArea(.{ .x = 0, .y = 450, .w = 200, .h = 60 }, &s.area, .{ .placeholder = "Area", .tab_inserts = s.tab_inserts });
    s.leftover = ui.events().len;
}

fn frameScene(rig: *Rig, s: *Scene, in: Input) void {
    var ui = rig.ui(in);
    drawScene(&ui, s);
    ui.finish();
}

fn tabTimes(rig: *Rig, s: *Scene, n: usize) void {
    for (0..n) |_| frameScene(rig, s, tab());
}

fn focusIndex(rig: *const Rig) ?usize {
    const id = rig.state.focusId() orelse return null;
    for (rig.state.focusEntries(), 0..) |e, i| if (e.id == id) return i;
    return null;
}

/// Tabs until entry `k` has focus, then runs one idle frame.
fn gotoEntry(rig: *Rig, s: *Scene, k: usize) !void {
    frameScene(rig, s, .{});
    var guard: usize = 0;
    while (focusIndex(rig) != k) : (guard += 1) {
        if (guard > 2 * e_count) return error.NeverFocused;
        frameScene(rig, s, tab());
    }
    frameScene(rig, s, .{});
}

test "registration: every widget lists itself with a role, in call order" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    frameScene(&rig, &s, .{});
    frameScene(&rig, &s, .{});
    const es = rig.state.focusEntries();
    try t.expectEqual(@as(usize, e_count), es.len);
    try t.expectEqual(focus.Role.button, es[e_btn].role);
    try t.expectEqualStrings("Btn", es[e_btn].label());
    try t.expect(es[e_off].disabled);
    try t.expectEqual(focus.Role.checkbox, es[e_check].role);
    try t.expectEqual(focus.Role.toggle, es[e_tog].role);
    try t.expectEqual(focus.Role.radio, es[e_r1].role);
    try t.expectEqual(focus.Role.tab, es[e_seg].role);
    try t.expectEqual(focus.Role.tab, es[e_tabs].role);
    try t.expectEqual(focus.Role.slider, es[e_slider].role);
    try t.expectEqual(focus.Role.list_row, es[e_row].role);
    try t.expectEqual(focus.Role.dropdown, es[e_dd].role);
    try t.expectEqual(focus.Role.text_field, es[e_field].role);
    try t.expectEqual(focus.Role.text_area, es[e_area].role);
    try t.expectEqualStrings("Search", es[e_icon].label());
    // Stateful widgets use the address of their state, value-bound ones the address of the value.
    try t.expectEqual(@intFromPtr(&s.check), es[e_check].id);
    try t.expectEqual(@intFromPtr(&s.field), es[e_field].id);
    try t.expectEqual(@intFromPtr(&s.dd), es[e_dd].id);
    try t.expect(es[e_btn].id & focus.derived_bit != 0);
    // Nothing is focused until asked.
    try t.expect(rig.state.focus == null);
}

test "Tab: first Tab goes to the first entry, order follows calls, disabled is skipped, wraps" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    frameScene(&rig, &s, .{});
    frameScene(&rig, &s, tab());
    try t.expectEqual(@as(?usize, e_btn), focusIndex(&rig));
    frameScene(&rig, &s, tab()); // "Off" is disabled
    try t.expectEqual(@as(?usize, e_check), focusIndex(&rig));
    frameScene(&rig, &s, tab());
    try t.expectEqual(@as(?usize, e_tog), focusIndex(&rig));
    // Several Tabs in one frame step several times.
    var in: Input = .{};
    in.pushKey(keys.tab, .{});
    in.pushKey(keys.tab, .{});
    frameScene(&rig, &s, in);
    try t.expectEqual(@as(?usize, e_r2), focusIndex(&rig));
    // Wrap: from the last entry to the first.
    try gotoEntry(&rig, &s, e_area);
    frameScene(&rig, &s, tab());
    try t.expectEqual(@as(?usize, e_btn), focusIndex(&rig));
}

test "Shift+Tab: with no focus goes to the last entry, then reverses and wraps" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    frameScene(&rig, &s, .{});
    frameScene(&rig, &s, keyIn(keys.tab, .{ .shift = true }));
    try t.expectEqual(@as(?usize, e_area), focusIndex(&rig));
    frameScene(&rig, &s, keyIn(keys.tab, .{ .shift = true }));
    try t.expectEqual(@as(?usize, e_field), focusIndex(&rig));
    try gotoEntry(&rig, &s, e_check);
    frameScene(&rig, &s, keyIn(keys.tab, .{ .shift = true })); // skips the disabled button
    try t.expectEqual(@as(?usize, e_btn), focusIndex(&rig));
    frameScene(&rig, &s, keyIn(keys.tab, .{ .shift = true }));
    try t.expectEqual(@as(?usize, e_area), focusIndex(&rig));
}

test "Tab with Cmd or Ctrl held is not traversal and stays in the events" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    frameScene(&rig, &s, .{});
    frameScene(&rig, &s, keyIn(keys.tab, .{ .cmd = true }));
    try t.expect(rig.state.focus == null);
    try t.expectEqual(@as(usize, 1), s.leftover);
}

test "Enter and Space activate buttons, icon buttons, chips, pills and rows like a click" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    const cases = [_]struct { entry: usize, code: u32 }{
        .{ .entry = e_btn, .code = keys.@"return" },
        .{ .entry = e_btn, .code = keys.space },
        .{ .entry = e_icon, .code = keys.@"return" },
        .{ .entry = e_chip, .code = keys.space },
        .{ .entry = e_pill, .code = keys.@"return" },
        .{ .entry = e_row, .code = keys.space },
    };
    for (cases) |c| {
        try gotoEntry(&rig, &s, c.entry);
        try t.expect(!s.btn and !s.icon and !s.chip and !s.pill and !s.list_row);
        frameScene(&rig, &s, keyIn(c.code, .{}));
        const got = switch (c.entry) {
            e_btn => s.btn,
            e_icon => s.icon,
            e_chip => s.chip,
            e_pill => s.pill,
            else => s.list_row,
        };
        try t.expect(got);
        // The key was consumed.
        try t.expectEqual(@as(usize, 0), s.leftover);
        // Auto-repeat of a held key does not activate again.
        var rep: Input = .{};
        rep.queue[0] = .{ .key = .{ .code = c.code, .repeat = true } };
        rep.queue_len = 1;
        frameScene(&rig, &s, rep);
        try t.expect(!s.btn and !s.icon and !s.chip and !s.pill and !s.list_row);
    }
}

test "Enter and Space flip checkboxes and switches and select radios" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    try gotoEntry(&rig, &s, e_check);
    frameScene(&rig, &s, keyIn(keys.space, .{}));
    try t.expect(s.check);
    frameScene(&rig, &s, keyIn(keys.@"return", .{}));
    try t.expect(!s.check);
    try gotoEntry(&rig, &s, e_tog);
    frameScene(&rig, &s, keyIn(keys.space, .{}));
    try t.expect(s.tog);
    try gotoEntry(&rig, &s, e_r2);
    frameScene(&rig, &s, keyIn(keys.space, .{}));
    try t.expectEqual(@as(usize, 1), s.radio);
    try gotoEntry(&rig, &s, e_r1);
    frameScene(&rig, &s, keyIn(keys.@"return", .{}));
    try t.expectEqual(@as(usize, 0), s.radio);
    try t.expect(s.radio_click);
}

test "segmented and tabs are one Tab stop; arrows, Home and End change the selection" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    try gotoEntry(&rig, &s, e_seg);
    frameScene(&rig, &s, keyIn(keys.right, .{}));
    try t.expectEqual(@as(usize, 2), s.seg);
    try t.expect(s.seg_changed);
    try t.expectEqual(@as(usize, 0), s.leftover);
    frameScene(&rig, &s, keyIn(keys.right, .{})); // at the end: stays
    try t.expectEqual(@as(usize, 2), s.seg);
    try t.expect(!s.seg_changed);
    frameScene(&rig, &s, keyIn(keys.home, .{}));
    try t.expectEqual(@as(usize, 0), s.seg);
    frameScene(&rig, &s, keyIn(keys.end, .{}));
    try t.expectEqual(@as(usize, 2), s.seg);
    frameScene(&rig, &s, keyIn(keys.left, .{}));
    try t.expectEqual(@as(usize, 1), s.seg);
    // Tab leaves the whole control in one step.
    frameScene(&rig, &s, tab());
    try t.expectEqual(@as(?usize, e_tabs), focusIndex(&rig));
    frameScene(&rig, &s, keyIn(keys.right, .{}));
    try t.expectEqual(@as(usize, 1), s.tabsel);
    try t.expect(s.tabs_changed);
    frameScene(&rig, &s, keyIn(keys.end, .{}));
    try t.expectEqual(@as(usize, 2), s.tabsel);
    frameScene(&rig, &s, keyIn(keys.left, .{}));
    try t.expectEqual(@as(usize, 1), s.tabsel);
    frameScene(&rig, &s, tab());
    try t.expectEqual(@as(?usize, e_slider), focusIndex(&rig));
}

test "slider: arrows step, Shift steps more, Home and End jump, keys are consumed" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    try gotoEntry(&rig, &s, e_slider);
    frameScene(&rig, &s, keyIn(keys.right, .{}));
    try t.expectEqual(@as(f32, 6), s.slider);
    try t.expect(s.slider_changed);
    try t.expectEqual(@as(usize, 0), s.leftover);
    frameScene(&rig, &s, keyIn(keys.left, .{}));
    try t.expectEqual(@as(f32, 5), s.slider);
    frameScene(&rig, &s, keyIn(keys.up, .{ .shift = true }));
    try t.expectEqual(@as(f32, 10), s.slider); // 5 + 5 steps
    frameScene(&rig, &s, keyIn(keys.home, .{}));
    try t.expectEqual(@as(f32, 0), s.slider);
    frameScene(&rig, &s, keyIn(keys.end, .{}));
    try t.expectEqual(@as(f32, 10), s.slider);
    // keyClaimed tells code that runs before the widgets.
    var ui = rig.ui(.{});
    try t.expect(ui.keyClaimed(keys.down, .{}));
    try t.expect(!ui.keyClaimed(keys.@"return", .{}));
    try t.expect(!ui.keyClaimed(keys.down, .{ .cmd = true }));
}

test "dropdown: a Tab stop; Enter opens it, Up and Down change the selection" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    try gotoEntry(&rig, &s, e_dd);
    frameScene(&rig, &s, keyIn(keys.down, .{}));
    try t.expectEqual(@as(usize, 1), s.dd_sel);
    try t.expect(s.dd_changed);
    try t.expectEqual(@as(usize, 0), s.leftover);
    frameScene(&rig, &s, keyIn(keys.@"return", .{}));
    try t.expect(s.dd.popup.open);
    try t.expectEqual(@as(usize, 0), s.leftover);
}

test "waveform: focusable like a slider, arrows seek" {
    var rig = try Rig.init();
    defer rig.deinit();
    const peaks = [_]f32{ 0.2, 0.5, 0.9, 0.4 };
    var seek: ?f32 = null;
    for (0..3) |i| {
        var ui = rig.ui(if (i == 0) .{} else tab());
        seek = ui.waveform(.{ .x = 0, .y = 0, .w = 100, .h = 30 }, &peaks, .{ .progress = 0.5 }).seek;
        ui.finish();
    }
    try t.expectEqual(@as(usize, 1), rig.state.focusEntries().len);
    var ui = rig.ui(keyIn(keys.right, .{}));
    seek = ui.waveform(.{ .x = 0, .y = 0, .w = 100, .h = 30 }, &peaks, .{ .progress = 0.5 }).seek;
    ui.finish();
    try t.expectApproxEqAbs(@as(f32, 0.55), seek.?, 1e-6);
    // A passive waveform is not a Tab stop.
    ui = rig.ui(.{});
    _ = ui.waveform(.{ .x = 0, .y = 0, .w = 100, .h = 30 }, &peaks, .{ .passive = true });
    ui.finish();
    try t.expectEqual(@as(usize, 0), rig.state.focusEntries().len);
}

test "focus ring: shown after Tab, hidden after a mouse press, a click focuses without it" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    frameScene(&rig, &s, .{});
    const base = rig.arcs(); // the search icon is stroked with arcs
    frameScene(&rig, &s, tab());
    try t.expect(rig.state.focusRingVisible());
    try t.expect(rig.arcs() > base);
    frameScene(&rig, &s, .{}); // stays while nothing happens
    try t.expect(rig.arcs() > base);
    // A press somewhere empty hides it and blurs.
    frameScene(&rig, &s, clickAt(900, 900));
    try t.expect(!rig.state.focusRingVisible());
    try t.expectEqual(base, rig.arcs());
    try t.expect(rig.state.focus == null);
    // Clicking a button focuses it, without a ring.
    frameScene(&rig, &s, clickAt(50, 10));
    try t.expect(s.btn);
    try t.expectEqual(@as(?usize, e_btn), focusIndex(&rig));
    try t.expectEqual(base, rig.arcs());
    // Space then shows it again (keyboard use).
    frameScene(&rig, &s, keyIn(keys.space, .{}));
    try t.expect(s.btn);
    try t.expect(rig.arcs() > base);
    // Tab to the next one: still visible, and a press hides it again.
    frameScene(&rig, &s, tab());
    try t.expect(rig.arcs() > base);
    frameScene(&rig, &s, clickAt(900, 900));
    try t.expectEqual(base, rig.arcs());
}

test "Tab leaves a text field; typed text and other keys still reach it" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    try gotoEntry(&rig, &s, e_field);
    var in: Input = .{};
    in.pushText("hi");
    frameScene(&rig, &s, in);
    try t.expectEqualStrings("hi", s.field.edit.text());
    frameScene(&rig, &s, tab());
    try t.expectEqualStrings("hi", s.field.edit.text());
    try t.expectEqual(@as(?usize, e_area), focusIndex(&rig));
    try t.expectEqual(@as(usize, 0), s.leftover); // Tab did not linger
    // Shift+Tab back into the field.
    frameScene(&rig, &s, keyIn(keys.tab, .{ .shift = true }));
    try t.expectEqual(@as(?usize, e_field), focusIndex(&rig));
}

test "text area: Tab leaves it by default, tab_inserts inserts a tab and Shift+Tab leaves" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    try gotoEntry(&rig, &s, e_area);
    frameScene(&rig, &s, tab());
    try t.expectEqualStrings("", s.area.edit.text());
    try t.expectEqual(@as(?usize, e_btn), focusIndex(&rig)); // wrapped

    s.tab_inserts = true;
    try gotoEntry(&rig, &s, e_area);
    frameScene(&rig, &s, tab());
    try t.expectEqualStrings("\t", s.area.edit.text());
    try t.expectEqual(@as(?usize, e_area), focusIndex(&rig));
    frameScene(&rig, &s, keyIn(keys.tab, .{ .shift = true }));
    try t.expectEqualStrings("\t", s.area.edit.text());
    try t.expectEqual(@as(?usize, e_field), focusIndex(&rig));
}

test "consumed keys do not reach events(); others do" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    try gotoEntry(&rig, &s, e_btn);
    var in: Input = .{};
    in.pushKey(keys.@"return", .{});
    in.pushKey(keys.down, .{}); // a button does not use Down
    in.pushKey('x', .{});
    frameScene(&rig, &s, in);
    try t.expect(s.btn);
    try t.expectEqual(@as(usize, 2), s.leftover);
    // A widget under no focus consumes nothing.
    rig.state.blur();
    frameScene(&rig, &s, keyIn(keys.@"return", .{}));
    try t.expect(!s.btn);
    try t.expectEqual(@as(usize, 1), s.leftover);
}

test "a scroll area does not scroll on arrows the focused slider uses, but does for a button" {
    var rig = try Rig.init();
    defer rig.deinit();
    var sc: ui_mod.ScrollState = .{ .key_scroll = true };
    var v: f32 = 5;
    for (0..4) |i| {
        var ui = rig.ui(if (i == 0) .{} else if (i == 1) tab() else if (i == 2) tab() else keyIn(keys.down, .{}));
        const c = ui.beginScroll(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &sc, 400);
        _ = ui.button(.{ .x = 0, .y = c.y, .w = 100, .h = 20 }, "B", .{});
        _ = ui.slider(.{ .x = 0, .y = c.y + 30, .w = 100, .h = 20 }, &v, .{ .min = 0, .max = 10, .step = 1 });
        ui.endScroll();
        ui.finish();
    }
    // Focus is on the slider (second Tab): Down was its, not the scroll area's.
    try t.expectEqual(@as(f32, 4), v);
    try t.expectEqual(@as(f32, 0), sc.offset);
    // On the button, Down scrolls.
    {
        var ui = rig.ui(keyIn(keys.tab, .{ .shift = true }));
        _ = ui.beginScroll(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &sc, 400);
        ui.endScroll();
        ui.finish();
    }
    {
        var ui = rig.ui(keyIn(keys.down, .{}));
        const c = ui.beginScroll(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &sc, 400);
        _ = ui.button(.{ .x = 0, .y = c.y, .w = 100, .h = 20 }, "B", .{});
        ui.endScroll();
        ui.finish();
    }
    try t.expect(sc.offset > 0);
}

// ---- ids --------------------------------------------------------------------------------------

fn idsOf(rig: *const Rig, out: []focus.FocusId) void {
    for (rig.state.focusEntries(), 0..) |e, i| out[i] = e.id;
}

test "ids are stable across frames and when rectangles change (resize, scroll)" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    frameScene(&rig, &s, .{});
    frameScene(&rig, &s, .{});
    var a: [e_count]focus.FocusId = undefined;
    idsOf(&rig, &a);
    // Same structure at other positions and sizes.
    for ([_]f32{ 40, 300 }) |dx| {
        var ui = rig.ui(.{});
        const r2 = struct {
            fn at(i: usize, off: f32) Rect {
                return .{ .x = off, .y = @as(f32, @floatFromInt(i)) * 41 + off, .w = 90, .h = 33 };
            }
        };
        _ = ui.button(r2.at(0, dx), "Btn", .{});
        _ = ui.button(r2.at(1, dx), "Off", .{ .disabled = true });
        _ = ui.checkbox(r2.at(2, dx), &s.check, "Check", .{});
        ui.finish();
        const es = rig.state.focusEntries();
        try t.expectEqual(a[0], es[0].id);
        try t.expectEqual(a[1], es[1].id);
        try t.expectEqual(a[2], es[2].id);
    }
    // Focus survives the move.
    frameScene(&rig, &s, tab());
    const was = rig.state.focus;
    var ui = rig.ui(.{});
    _ = ui.button(.{ .x = 5, .y = 500, .w = 10, .h = 10 }, "Btn", .{});
    ui.finish();
    try t.expect(rig.state.focus == was);
}

test "id scopes tell repeated labels in a list apart; the occurrence index does it within a scope" {
    var rig = try Rig.init();
    defer rig.deinit();
    var ids1: [6]focus.FocusId = undefined;
    for (0..2) |frame_i| {
        var ui = rig.ui(.{});
        for (0..2) |g| {
            ui.pushId(g);
            _ = ui.button(row(g * 3), "Edit", .{});
            _ = ui.button(row(g * 3 + 1), "Edit", .{}); // same label, same scope: the second occurrence
            _ = ui.button(row(g * 3 + 2), "Delete", .{});
            ui.popId();
        }
        ui.finish();
        const es = rig.state.focusEntries();
        try t.expectEqual(@as(usize, 6), es.len);
        if (frame_i == 0) idsOf(&rig, &ids1) else for (es, 0..) |e, i| try t.expectEqual(ids1[i], e.id);
    }
    for (ids1, 0..) |x, i| for (ids1[i + 1 ..]) |y| try t.expect(x != y);
}

test "explicit ids follow their row when the list is reordered" {
    var rig = try Rig.init();
    defer rig.deinit();
    const order_a = [_]u64{ 1, 2, 3 };
    const order_b = [_]u64{ 3, 1, 2 };
    for ([_][]const u64{ &order_a, &order_a, &order_b }, 0..) |order, f| {
        var ui = rig.ui(if (f == 1) tab() else .{});
        for (order, 0..) |k, i| _ = ui.listRow(row(i), .{ .id = ui_mod.idKey(k) });
        ui.finish();
    }
    try t.expect(rig.state.focus != null);
    // The focused entry is the row with key 1, now second.
    try t.expectEqual(@as(usize, 1), focusIndex(&rig).?);
}

test "a custom widget uses focusable with a widgetId, and two with one id: the first wins" {
    var rig = try Rig.init();
    defer rig.deinit();
    var r1: focus.FocusResult = undefined;
    var r2: focus.FocusResult = undefined;
    for (0..3) |f| {
        var ui = rig.ui(if (f == 1) tab() else .{});
        const id = ui.widgetId(1, ui_mod.idKey("x"), ui_mod.idKey(7));
        r1 = ui.focusable(id, row(0), .{ .role = .link, .label = "first" });
        r2 = ui.focusable(id, row(1), .{ .role = .link, .label = "second" }); // collision
        ui.finish();
    }
    try t.expectEqual(@as(usize, 1), rig.state.focusEntries().len);
    try t.expectEqualStrings("first", rig.state.focusEntries()[0].label());
    try t.expect(r1.focused);
    try t.expect(!r2.focused and !r2.activated);
}

test "removing the focused widget from a frame clears focus instead of leaving it dangling" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    try gotoEntry(&rig, &s, e_tog);
    try t.expect(rig.state.focus != null);
    // A frame without the switch.
    var ui = rig.ui(.{});
    _ = ui.button(row(0), "Btn", .{});
    ui.finish();
    try t.expect(rig.state.focus == null);
    // Tab starts over from the first entry.
    ui = rig.ui(tab());
    _ = ui.button(row(0), "Btn", .{});
    ui.finish();
    try t.expectEqualStrings("Btn", rig.focusedLabel());
}

test "without finish(): the next frame's first widget notices the focused widget is gone" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    // Frames that never call finish (as the controls example does).
    for (0..3) |_| {
        var ui = rig.ui(.{});
        drawScene(&ui, &s);
    }
    {
        var ui = rig.ui(tab());
        drawScene(&ui, &s);
    }
    try t.expect(rig.state.focus != null);
    {
        var ui = rig.ui(.{});
        _ = ui.button(row(0), "Btn", .{});
    }
    try t.expect(rig.state.focus != null); // not rotated yet
    {
        var ui = rig.ui(.{});
        _ = ui.button(row(0), "Btn", .{});
    }
    // The frame that dropped the focused widget is complete now; a button was focused and is back.
    try t.expect(rig.state.focus != null);
    {
        var ui = rig.ui(.{});
        _ = ui.button(row(5), "Other", .{});
    }
    {
        var ui = rig.ui(.{});
        _ = ui.button(row(5), "Other", .{});
    }
    try t.expect(rig.state.focus == null);
}

test "existing focusOn and blur keep working, and a focusOn before the first frame sticks" {
    var rig = try Rig.init();
    defer rig.deinit();
    var field = ui_mod.TextFieldState.init(t.allocator);
    defer field.deinit();
    rig.state.focusOn(&field);
    for (0..2) |_| {
        var ui = rig.ui(.{});
        _ = ui.textField(row(0), &field, .{});
        ui.finish();
    }
    try t.expect(rig.state.focus == @as(?*const anyopaque, &field));
    try t.expectEqual(@as(?focus.FocusId, @intFromPtr(&field)), rig.state.focusId());
    var in: Input = .{};
    in.pushText("a");
    var ui = rig.ui(in);
    _ = ui.textField(row(0), &field, .{});
    ui.finish();
    try t.expectEqualStrings("a", field.edit.text());
    rig.state.blur();
    try t.expect(rig.state.focus == null);
}

test "programmatic focus: setFocus, isFocused, focusedId, focusNext and focusPrev" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = Scene.init();
    defer s.deinit();
    frameScene(&rig, &s, .{});
    frameScene(&rig, &s, .{});
    const target = rig.state.focusEntries()[e_tog].id;
    var ui = rig.ui(.{});
    try t.expect(ui.focusedId() == null);
    ui.setFocus(target);
    try t.expect(ui.isFocused(target));
    try t.expectEqual(@as(?focus.FocusId, target), ui.focusedId());
    drawScene(&ui, &s);
    ui.finish();
    ui = rig.ui(.{});
    ui.focusNext();
    try t.expectEqual(rig.state.focusEntries()[e_r1].id, ui.focusedId().?);
    ui.focusPrev();
    ui.focusPrev();
    try t.expectEqual(rig.state.focusEntries()[e_check].id, ui.focusedId().?);
    drawScene(&ui, &s);
    ui.finish();
}

test "gained and lost are reported on the frame focus arrives and leaves" {
    var rig = try Rig.init();
    defer rig.deinit();
    var res: [2]focus.FocusResult = undefined;
    for (0..4) |f| {
        var ui = rig.ui(if (f == 1 or f == 2) tab() else .{});
        const a = ui.focusable(ui.widgetId(1, 1, null), row(0), .{});
        const b = ui.focusable(ui.widgetId(1, 2, null), row(1), .{});
        res = .{ a, b };
        ui.finish();
        if (f == 1) try t.expect(res[0].gained and !res[0].lost and !res[1].gained);
        if (f == 2) try t.expect(!res[0].focused and res[0].lost and res[1].gained);
        if (f == 3) try t.expect(!res[0].lost and !res[1].gained and res[1].focused);
    }
}

// ---- scrolling ------------------------------------------------------------------------------------

test "scroll into view: Tab to a widget below the fold scrolls its area; nested areas too" {
    var rig = try Rig.init();
    defer rig.deinit();
    var sc: ui_mod.ScrollState = .{};
    for (0..14) |f| {
        var ui = rig.ui(if (f == 0) .{} else tab());
        const c = ui.beginScroll(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &sc, 600);
        for (0..20) |i| _ = ui.button(.{ .x = 0, .y = c.y + @as(f32, @floatFromInt(i)) * 30, .w = 100, .h = 26 }, "b", .{});
        ui.endScroll();
        ui.finish();
        if (f == 0) try t.expectEqual(@as(f32, 0), sc.offset);
    }
    // 13 Tabs reached the 13th button (content 360..386) in a view 100 tall.
    try t.expectEqual(@as(f32, 386 - 100), sc.offset);
    // Back up: Shift+Tab to a button above scrolls up.
    for (0..11) |_| {
        var ui = rig.ui(keyIn(keys.tab, .{ .shift = true }));
        const c = ui.beginScroll(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &sc, 600);
        for (0..20) |i| _ = ui.button(.{ .x = 0, .y = c.y + @as(f32, @floatFromInt(i)) * 30, .w = 100, .h = 26 }, "b", .{});
        ui.endScroll();
        ui.finish();
    }
    try t.expectEqual(@as(f32, 30), sc.offset); // the 2nd button, at content 30
}

test "scroll into view: nested scroll areas both move" {
    var rig = try Rig.init();
    defer rig.deinit();
    var outer: ui_mod.ScrollState = .{};
    var inner: ui_mod.ScrollState = .{};
    for (0..3) |f| {
        var ui = rig.ui(if (f == 0) .{} else if (f == 1) keyIn(keys.tab, .{ .shift = true }) else .{});
        const oc = ui.beginScroll(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, &outer, 500);
        // Outer content: a 400 tall block holding the inner area (view 80 tall, content 300).
        const view: Rect = .{ .x = 0, .y = oc.y + 200, .w = 200, .h = 80 };
        const ic = ui.beginScroll(view, &inner, 300);
        for (0..10) |i| _ = ui.button(.{ .x = 0, .y = ic.y + @as(f32, @floatFromInt(i)) * 30, .w = 100, .h = 26 }, "n", .{});
        ui.endScroll();
        ui.endScroll();
        ui.finish();
    }
    // Shift+Tab with no focus picked the last button (content 270..296 of the inner area).
    try t.expect(inner.offset > 0);
    try t.expect(outer.offset > 0);
}

// ---- popups -------------------------------------------------------------------------------------------

const PopScene = struct {
    pop: ui_mod.PopupState = .{},
    modal: bool = false,
    open_req: bool = false,
    close_req: bool = false,
    done: bool = false,
    field: ui_mod.TextFieldState,

    fn init() PopScene {
        return .{ .field = ui_mod.TextFieldState.init(t.allocator) };
    }
};

fn popFrame(rig: *Rig, s: *PopScene, in: Input) void {
    var ui = rig.ui(in);
    _ = ui.button(row(0), "Main1", .{});
    _ = ui.button(row(1), "Main2", .{});
    if (s.open_req) {
        s.open_req = false;
        ui.openPopup(&s.pop);
    }
    if (ui.beginPopup(&s.pop, row(1), .{ 160, 120 }, .{ .modal = s.modal, .dismiss_on_outside = !s.modal, .placement = .center })) |c| {
        _ = ui.button(.{ .x = c.x, .y = c.y, .w = 60, .h = 26 }, "P1", .{});
        _ = ui.button(.{ .x = c.x, .y = c.y + 30, .w = 60, .h = 26 }, "P2", .{});
        if (s.close_req) {
            s.close_req = false;
            ui.closePopup(&s.pop);
        }
        s.done = ui.button(.{ .x = c.x, .y = c.y + 60, .w = 60, .h = 26 }, "P3", .{});
        ui.endPopup();
    }
    ui.finish();
}

test "popups: Tab is confined to the open popup, cycles inside it, and focus is restored on close" {
    for ([_]bool{ false, true }) |modal| {
        var rig = try Rig.init();
        defer rig.deinit();
        var s = PopScene.init();
        defer s.field.deinit();
        s.modal = modal;
        popFrame(&rig, &s, .{});
        popFrame(&rig, &s, tab());
        popFrame(&rig, &s, tab());
        try t.expectEqualStrings("Main2", rig.focusedLabel());
        s.open_req = true;
        popFrame(&rig, &s, .{});
        popFrame(&rig, &s, .{});
        try t.expect(s.pop.open);
        // Entries of the popup are on layer 1.
        try t.expectEqual(@as(u8, 1), rig.state.focusEntries()[2].layer);
        popFrame(&rig, &s, tab());
        try t.expectEqualStrings("P1", rig.focusedLabel());
        popFrame(&rig, &s, tab());
        try t.expectEqualStrings("P2", rig.focusedLabel());
        popFrame(&rig, &s, tab());
        try t.expectEqualStrings("P3", rig.focusedLabel());
        popFrame(&rig, &s, tab()); // wraps inside the popup, never out to Main1
        try t.expectEqualStrings("P1", rig.focusedLabel());
        popFrame(&rig, &s, keyIn(keys.tab, .{ .shift = true }));
        try t.expectEqualStrings("P3", rig.focusedLabel());
        // Enter on a popup button activates it and does not reach the buttons beneath.
        popFrame(&rig, &s, keyIn(keys.@"return", .{}));
        try t.expect(s.done);
        // Closing gives focus back to where it was.
        s.close_req = true;
        popFrame(&rig, &s, .{});
        popFrame(&rig, &s, .{});
        try t.expect(!s.pop.open);
        try t.expectEqualStrings("Main2", rig.focusedLabel());
        // Back to normal Tab traversal.
        popFrame(&rig, &s, tab());
        try t.expectEqualStrings("Main1", rig.focusedLabel());
    }
}

test "popups: Escape closes it and restores focus; keys do not reach widgets beneath" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = PopScene.init();
    defer s.field.deinit();
    popFrame(&rig, &s, .{});
    popFrame(&rig, &s, tab());
    s.open_req = true;
    popFrame(&rig, &s, .{});
    popFrame(&rig, &s, tab());
    try t.expectEqualStrings("P1", rig.focusedLabel());
    popFrame(&rig, &s, keyIn(keys.escape, .{}));
    popFrame(&rig, &s, .{});
    try t.expect(!s.pop.open);
    try t.expectEqualStrings("Main1", rig.focusedLabel());
}

test "popups: a menu ignores Tab (items use their own highlight) and tooltips never take focus" {
    var rig = try Rig.init();
    defer rig.deinit();
    var menu: ui_mod.PopupState = .{};
    const items = [_]ui_mod.MenuItem{ .{ .label = "One" }, .{ .label = "Two" } };
    var picked: ?usize = null;
    for (0..5) |f| {
        var ui = rig.ui(if (f == 2) tab() else if (f == 3) keyIn(keys.down, .{}) else if (f == 4) keyIn(keys.@"return", .{}) else .{});
        _ = ui.button(row(0), "Open", .{});
        _ = ui.button(row(1), "Other", .{});
        ui.tooltip(row(0), "Tip", .{ .delay = 0 });
        if (f == 0) ui.openPopup(&menu);
        if (ui.menu(&menu, row(0), &items, .{})) |i| picked = i;
        ui.finish();
    }
    try t.expect(menu.open == false);
    try t.expectEqual(@as(?usize, 0), picked);
    // Tab did nothing: no widget beneath got focus.
    try t.expect(rig.state.focus == null);
    for (rig.state.focusEntries()) |e| try t.expect(e.role != .other);
}

test "modal dialog: Tab cycles through its buttons and a text field" {
    var rig = try Rig.init();
    defer rig.deinit();
    var pop: ui_mod.PopupState = .{};
    var field = ui_mod.TextFieldState.init(t.allocator);
    defer field.deinit();
    for (0..6) |f| {
        var ui = rig.ui(if (f >= 2) tab() else .{});
        _ = ui.button(row(0), "Behind", .{});
        if (f == 0) ui.openPopup(&pop);
        if (ui.beginPopup(&pop, row(0), .{ 200, 140 }, .{ .modal = true, .dismiss_on_outside = false, .placement = .center })) |c| {
            _ = ui.textField(.{ .x = c.x, .y = c.y, .w = 160, .h = 28 }, &field, .{ .placeholder = "Name" });
            _ = ui.button(.{ .x = c.x, .y = c.y + 40, .w = 70, .h = 26 }, "Cancel", .{});
            _ = ui.button(.{ .x = c.x + 80, .y = c.y + 40, .w = 70, .h = 26 }, "OK", .{});
            ui.endPopup();
        }
        ui.finish();
        if (f == 2) try t.expectEqualStrings("Name", rig.focusedLabel());
        if (f == 3) try t.expectEqualStrings("Cancel", rig.focusedLabel());
        if (f == 4) try t.expectEqualStrings("OK", rig.focusedLabel());
        if (f == 5) try t.expectEqualStrings("Name", rig.focusedLabel());
    }
}

// ---- edge cases -----------------------------------------------------------------------------------------

fn farRow(i: usize) Rect {
    return .{ .x = 0, .y = @as(f32, @floatFromInt(i)) * 30, .w = 200, .h = 26 };
}

test "a text field declared after max_entries other widgets keeps the focus a click gave it" {
    var rig = try Rig.init();
    defer rig.deinit();
    var field = ui_mod.TextFieldState.init(t.allocator);
    defer field.deinit();
    const fr = farRow(focus.max_entries + 10);
    for (0..3) |f| {
        var ui = rig.ui(if (f == 1) clickAt(fr.x + 10, fr.y + 10) else .{});
        for (0..focus.max_entries) |i| _ = ui.focusable(1000 + i, farRow(i), .{});
        _ = ui.textField(fr, &field, .{});
        ui.finish();
    }
    try t.expect(rig.state.focus == @as(?*const anyopaque, &field));
}

test "derived ids stay distinct past max_entries" {
    var rig = try Rig.init();
    defer rig.deinit();
    var ui = rig.ui(.{});
    for (0..focus.max_entries) |i| _ = ui.focusable(1000 + i, farRow(i), .{});
    const a = focus.autoId(&ui, 7, 99, null);
    _ = ui.focusable(a, farRow(300), .{});
    const b = focus.autoId(&ui, 7, 99, null);
    try t.expect(a != b);
    ui.finish();
}

test "setFocus for a widget that is declared next frame, not this one, still focuses it" {
    for ([_]bool{ false, true }) |before_widgets| {
        var rig = try Rig.init();
        defer rig.deinit();
        const id: focus.FocusId = 0x1234;
        {
            var ui = rig.ui(.{});
            if (before_widgets) ui.setFocus(id);
            _ = ui.focusable(1, row(0), .{});
            if (!before_widgets) ui.setFocus(id);
            ui.finish();
        }
        {
            var ui = rig.ui(.{});
            _ = ui.focusable(1, row(0), .{});
            const r = ui.focusable(id, row(1), .{});
            try t.expect(r.focused);
            ui.finish();
        }
        try t.expectEqual(@as(?focus.FocusId, id), rig.state.focusId());
        // The grace is one frame: a widget that never shows up loses the focus.
        const other: focus.FocusId = 0x5678;
        for (0..3) |f| {
            var ui = rig.ui(.{});
            if (f == 0) ui.setFocus(other);
            _ = ui.focusable(1, row(0), .{});
            ui.finish();
        }
        try t.expect(rig.state.focus == null);
    }
}

test "closing a popup does not take focus back from a widget the app moved it to" {
    var rig = try Rig.init();
    defer rig.deinit();
    var s = PopScene.init();
    defer s.field.deinit();
    popFrame(&rig, &s, .{});
    popFrame(&rig, &s, tab());
    popFrame(&rig, &s, tab());
    try t.expectEqualStrings("Main2", rig.focusedLabel());
    s.open_req = true;
    popFrame(&rig, &s, .{});
    popFrame(&rig, &s, .{});
    try t.expect(s.pop.open);
    // The app puts focus on Main1, below the popup.
    rig.state.focusOn(focus.ptrOfId(rig.state.focusEntries()[0].id));
    popFrame(&rig, &s, .{});
    s.close_req = true;
    popFrame(&rig, &s, .{});
    popFrame(&rig, &s, .{});
    try t.expect(!s.pop.open);
    try t.expectEqualStrings("Main1", rig.focusedLabel());
}

test "focusing a text field by Tab or by code ends the selection of a read-only text" {
    for ([_]bool{ false, true }) |by_code| {
        var rig = try Rig.init();
        defer rig.deinit();
        var field = ui_mod.TextFieldState.init(t.allocator);
        defer field.deinit();
        var sel: ui_mod.SelectState = .{};
        const frame = struct {
            fn run(r: *Rig, in: Input, f: *ui_mod.TextFieldState, sl: *ui_mod.SelectState, code: bool) void {
                var ui = r.ui(in);
                _ = ui.textSelectable(row(0), "hello world", sl, .{});
                if (code) ui.setFocus(focus.idOfPtr(f));
                _ = ui.textField(row(1), f, .{});
                ui.finish();
            }
        }.run;
        frame(&rig, .{}, &field, &sel, false);
        rig.state.select = &sel;
        sel.anchor = 0;
        sel.cursor = 5;
        frame(&rig, if (by_code) Input{} else tab(), &field, &sel, by_code);
        try t.expect(rig.state.focus == @as(?*const anyopaque, &field));
        try t.expect(rig.state.select == null);
    }
}

test "text typed before a Tab goes to the field that had focus, text after it to the next" {
    var rig = try Rig.init();
    defer rig.deinit();
    var a = ui_mod.TextFieldState.init(t.allocator);
    defer a.deinit();
    var b = ui_mod.TextFieldState.init(t.allocator);
    defer b.deinit();
    rig.state.focusOn(&a);
    const frame = struct {
        fn run(r: *Rig, in: Input, fa: *ui_mod.TextFieldState, fb: *ui_mod.TextFieldState) void {
            var ui = r.ui(in);
            _ = ui.textField(row(0), fa, .{});
            _ = ui.textField(row(1), fb, .{});
            ui.finish();
        }
    }.run;
    frame(&rig, .{}, &a, &b);
    var in: Input = .{};
    in.pushText("a");
    in.pushKey(keys.tab, .{});
    in.pushText("b");
    frame(&rig, in, &a, &b);
    try t.expectEqualStrings("a", a.edit.text());
    // The Tab and what followed it arrive with the next frame (the loop is asked for one).
    try t.expect(rig.state.redraw.animating);
    frame(&rig, .{}, &a, &b);
    try t.expectEqualStrings("a", a.edit.text());
    try t.expectEqualStrings("b", b.edit.text());
    try t.expect(rig.state.focus == @as(?*const anyopaque, &b));
}

test "events lost when parked ones and the new frame's do not fit are counted" {
    var rig = try Rig.init();
    defer rig.deinit();
    var a = ui_mod.TextFieldState.init(t.allocator);
    defer a.deinit();
    rig.state.focusOn(&a);
    var f1: Input = .{};
    f1.pushKey(keys.left, .{});
    f1.pushKey(keys.tab, .{});
    for (0..100) |_| f1.pushKey(keys.right, .{});
    {
        var ui = rig.ui(f1);
        _ = ui.textField(row(0), &a, .{});
        ui.finish();
    }
    try t.expectEqual(@as(u8, 101), rig.state.reg.parked_n);
    var f2: Input = .{};
    for (0..200) |_| f2.pushKey(keys.right, .{});
    var ui = rig.ui(f2);
    _ = ui.textField(row(0), &a, .{});
    // 101 parked + 200 new = 301 events for 256 slots.
    try t.expectEqual(@as(u32, 45), ui.input.lost_events);
    ui.finish();
}
