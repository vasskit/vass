//! Tests of the application loop on SDL's dummy video driver (real windows and software
//! renderers, nothing on screen), with the fake clock and injected events.
const std = @import("std");
const platform = @import("../platform/backend_sdl.zig");
const ui_mod = @import("../ui/ui.zig");
const popup = @import("../ui/popup.zig");
const geom = @import("../core/geom.zig");
const app = @import("app.zig");

const testing = std.testing;
const Ui = ui_mod.Ui;
const Rect = geom.Rect;
const Context = app.Context;
const AppWindow = app.AppWindow;
const Runner = app.Runner;

const win_opts: platform.WindowOptions = .{ .title = "t", .width = 300, .height = 200, .hidden = true };
const spec: app.WindowSpec = .{ .window = win_opts };

/// A runner on the fake clock without sleeps; skips the test where no window can be opened.
fn testRunner(opts: app.Options) Runner {
    platform.useDummyVideo();
    var o = opts;
    o.frame_ms = 0;
    if (o.clock == .real) o.clock = .{ .fake = 0 };
    return Runner.init(testing.allocator, o);
}

fn openOrSkip(r: *Runner, comptime W: type, w: *W, s: app.WindowSpec) !*AppWindow {
    return r.open(W, w, s) catch error.SkipZigTest;
}

fn drawn(r: *Runner) !void {
    try testing.expectEqual(app.Result.drew, try r.iterate());
}

// ---- hooks ------------------------------------------------------------------------------------

/// Records the order its hooks are called in.
const Hooked = struct {
    order: [128]u8 = undefined,
    n: usize = 0,
    updates: u32 = 0,
    frames: u32 = 0,
    quit_at: u32 = 3,
    consume: u32 = 'x',
    veto_close: bool = false,

    fn note(h: *Hooked, c: u8) void {
        h.order[h.n] = c;
        h.n += 1;
    }
    fn log(h: *const Hooked) []const u8 {
        return h.order[0..h.n];
    }

    pub fn setup(h: *Hooked, ctx: *Context) !void {
        h.note('I');
        _ = ctx.window(); // the window exists by now
    }
    pub fn teardown(h: *Hooked, ctx: *Context) void {
        _ = ctx;
        h.note('D');
    }
    pub fn update(h: *Hooked, ctx: *Context) !void {
        h.note('U');
        h.updates += 1;
        if (h.updates == h.quit_at) ctx.quit();
    }
    pub fn afterFrame(h: *Hooked, ctx: *Context) !void {
        _ = ctx;
        h.note('A');
    }
    pub fn frame(h: *Hooked, ui: *Ui) void {
        _ = ui;
        h.note('F');
        h.frames += 1;
    }
    pub fn event(h: *Hooked, ctx: *Context, ev: app.Event) bool {
        _ = ctx;
        return switch (ev) {
            .key_down => |k| k.code == h.consume,
            else => false,
        };
    }
    pub fn closeRequested(h: *Hooked, ctx: *Context) bool {
        _ = ctx;
        return !h.veto_close;
    }
};

test "hooks: setup, then update and frame every turn, then teardown" {
    var h: Hooked = .{};
    var r = testRunner(.{});
    defer r.deinit();
    r.use(Hooked, &h);
    _ = try openOrSkip(&r, Hooked, &h, spec);
    try r.run();
    try testing.expectEqualStrings("IUFAUFAUD", h.log());
}

test "the single-window entry point runs a scripted program to its end" {
    platform.useDummyVideo();
    var h: Hooked = .{};
    app.run(Hooked, &h, .{ .window = win_opts, .frame_ms = 0, .gpa = testing.allocator }) catch |e| switch (e) {
        error.PlatformInitFailed => return error.SkipZigTest,
        else => return e,
    };
    try testing.expectEqualStrings("IUFAUFAUD", h.log());
}

test "event: a consumed event reaches nobody else, the rest is fed to the window" {
    var h: Hooked = .{};
    var r = testRunner(.{});
    defer r.deinit();
    r.use(Hooked, &h);
    const w = try openOrSkip(&r, Hooked, &h, spec);
    try r.start();
    defer r.stop();
    r.dispatch(.{ .key_down = .{ .code = 'x', .window = w.id() } });
    try testing.expectEqual(@as(usize, 0), w.input.events().len);
    r.dispatch(.{ .key_down = .{ .code = 'y', .window = w.id() } });
    try testing.expectEqual(@as(usize, 1), w.input.events().len);
    // The frame sees it once, then it is gone.
    try drawn(&r);
    try testing.expectEqual(@as(usize, 0), w.input.events().len);
}

test "closeRequested can veto the close button" {
    var h: Hooked = .{ .veto_close = true, .quit_at = 1000 };
    var r = testRunner(.{});
    defer r.deinit();
    r.use(Hooked, &h);
    const w = try openOrSkip(&r, Hooked, &h, spec);
    try r.start();
    defer r.stop();
    r.dispatch(.{ .close_requested = w.id() });
    try drawn(&r);
    try testing.expectEqual(@as(usize, 1), r.entries.items.len);
    h.veto_close = false;
    r.dispatch(.{ .close_requested = w.id() });
    try testing.expectEqual(app.Result.ended, try r.iterate());
    // The window that ended the loop stays until `stop`.
    try testing.expect(w.dead);
    try testing.expectEqual(@as(usize, 1), r.entries.items.len);
}

test "the update hook is not called by a live-resize redraw, the frame is" {
    var h: Hooked = .{ .quit_at = 1000 };
    var r = testRunner(.{});
    defer r.deinit();
    r.use(Hooked, &h);
    var fixed: Hooked = .{};
    const resizable = try openOrSkip(&r, Hooked, &h, .{ .window = .{ .title = "r", .width = 200, .height = 100, .hidden = true, .resizable = true } });
    const plain = try openOrSkip(&r, Hooked, &fixed, spec);
    // The callback is registered for the resizable window only.
    try testing.expect(resizable.window.live != null);
    try testing.expect(plain.window.live == null);
    try r.start();
    defer r.stop();
    try drawn(&r);
    const updates = h.updates;
    const frames = h.frames;
    var in = resizable.input;
    in.pressed = true; // a click that must not be replayed or consumed by the redraw
    resizable.input = in;
    AppWindow.onResize(resizable);
    try testing.expectEqual(updates, h.updates);
    try testing.expectEqual(frames + 1, h.frames);
    try testing.expect(resizable.input.pressed);
}

// ---- windows ----------------------------------------------------------------------------------

/// A window with its own state; closes and opens others when told to.
const Pane = struct {
    name: u8,
    log: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    ref: ?*AppWindow = null,
    frames: u32 = 0,
    /// What this pane's frame does on its next call.
    close_self: bool = false,
    close_other: ?*Pane = null,
    open_new: ?*Pane = null,
    closed: bool = false,
    last_pressed: bool = false,

    pub fn frame(p: *Pane, ui: *Ui, ctx: *Context) void {
        p.frames += 1;
        p.last_pressed = ui.input.pressed;
        p.log.append(p.gpa, p.name) catch {};
        if (p.close_self) {
            p.close_self = false;
            ctx.close(p.ref.?);
        }
        if (p.close_other) |o| {
            p.close_other = null;
            ctx.close(o.ref.?);
        }
        if (p.open_new) |n| {
            p.open_new = null;
            n.ref = ctx.open(Pane, n, spec) catch null;
        }
    }
    pub fn windowClosed(p: *Pane, ctx: *Context) void {
        _ = ctx;
        p.closed = true;
        p.log.append(p.gpa, p.name - 'a' + 'A') catch {};
    }
};

fn pane(name: u8, log: *std.ArrayList(u8)) Pane {
    return .{ .name = name, .log = log, .gpa = testing.allocator };
}

test "windows open and close in any order, from frames of their own or of other windows" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var r = testRunner(.{ .end = .explicit });
    defer r.deinit();
    var a = pane('a', &log);
    var b = pane('b', &log);
    var c = pane('c', &log);
    var d = pane('d', &log);
    a.ref = try openOrSkip(&r, Pane, &a, spec);
    b.ref = try openOrSkip(&r, Pane, &b, spec);
    c.ref = try openOrSkip(&r, Pane, &c, spec);
    try r.start();
    defer r.stop();

    // a's frame closes a itself, b's closes c before c's turn (so c is not drawn): both are
    // destroyed after the frames, last opened first.
    b.close_other = &c;
    a.close_self = true;
    try drawn(&r);
    try testing.expectEqualStrings("abCA", log.items); // c was closed before its turn; last opened goes first
    try testing.expect(a.closed and c.closed and !b.closed);
    try testing.expectEqual(@as(usize, 1), r.entries.items.len);

    // b opens d from its own frame; d is drawn from the next turn on.
    log.clearRetainingCapacity();
    b.open_new = &d;
    try drawn(&r);
    try testing.expectEqualStrings("b", log.items);
    try testing.expectEqual(@as(usize, 2), r.entries.items.len);
    log.clearRetainingCapacity();
    try drawn(&r);
    try testing.expectEqualStrings("bd", log.items);

    // d closes b, the older one, which goes after the frames; the loop goes on (explicit end).
    log.clearRetainingCapacity();
    d.close_other = &b;
    try drawn(&r);
    try testing.expectEqualStrings("bdB", log.items);
    try testing.expectEqual(@as(usize, 1), r.entries.items.len);
    // Closing the last one does not end an explicit loop; a quit does.
    r.close(d.ref.?);
    try drawn(&r);
    try testing.expectEqual(@as(usize, 0), r.entries.items.len);
    r.dispatch(.quit);
    try testing.expectEqual(app.Result.ended, try r.iterate());
}

test "end policies: main window, last window, explicit" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    // Closing a window that is not the main one keeps a main_window_closed loop going; the main one ends it.
    {
        var r = testRunner(.{ .end = .main_window_closed });
        defer r.deinit();
        var m = pane('m', &log);
        var o = pane('o', &log);
        m.ref = try openOrSkip(&r, Pane, &m, spec);
        o.ref = try openOrSkip(&r, Pane, &o, spec);
        try r.start();
        defer r.stop();
        r.dispatch(.{ .close_requested = o.ref.?.id() });
        try drawn(&r);
        try testing.expect(o.closed and !m.closed);
        r.dispatch(.{ .close_requested = m.ref.?.id() });
        try testing.expectEqual(app.Result.ended, try r.iterate());
    }
    // last_window_closed: the first one to go does not matter, the last one ends it.
    {
        var r = testRunner(.{ .end = .last_window_closed });
        defer r.deinit();
        var m = pane('m', &log);
        var o = pane('o', &log);
        m.ref = try openOrSkip(&r, Pane, &m, spec);
        o.ref = try openOrSkip(&r, Pane, &o, spec);
        try r.start();
        defer r.stop();
        r.dispatch(.{ .close_requested = m.ref.?.id() });
        try drawn(&r);
        r.dispatch(.{ .close_requested = o.ref.?.id() });
        try testing.expectEqual(app.Result.ended, try r.iterate());
    }
    // The window marked main is the one that counts, not the first.
    {
        var r = testRunner(.{ .end = .main_window_closed });
        defer r.deinit();
        var first = pane('f', &log);
        var main = pane('m', &log);
        first.ref = try openOrSkip(&r, Pane, &first, spec);
        var s = spec;
        s.main = true;
        main.ref = try openOrSkip(&r, Pane, &main, s);
        try r.start();
        defer r.stop();
        r.dispatch(.{ .close_requested = first.ref.?.id() });
        try drawn(&r);
        r.dispatch(.{ .close_requested = main.ref.?.id() });
        try testing.expectEqual(app.Result.ended, try r.iterate());
    }
}

test "windows draw in draw_order, then in the order they were opened; each has its own input" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var r = testRunner(.{});
    defer r.deinit();
    var a = pane('a', &log);
    var b = pane('b', &log);
    var c = pane('c', &log);
    var s_late = spec;
    s_late.draw_order = 5;
    a.ref = try openOrSkip(&r, Pane, &a, s_late);
    b.ref = try openOrSkip(&r, Pane, &b, spec);
    c.ref = try openOrSkip(&r, Pane, &c, spec);
    try r.start();
    defer r.stop();
    try drawn(&r);
    try testing.expectEqualStrings("bca", log.items);

    // An event for one window reaches only that window's input.
    r.dispatch(.{ .mouse_down = .{ .window = b.ref.?.id(), .x = 5, .y = 6, .button = 1 } });
    try testing.expect(b.ref.?.input.pressed and !a.ref.?.input.pressed and !c.ref.?.input.pressed);
    try testing.expectEqual(@as(f32, 5), b.ref.?.input.mouse_x);
    try testing.expectEqual(@as(f32, -1e9), a.ref.?.input.mouse_x);
    log.clearRetainingCapacity();
    try drawn(&r);
    try testing.expect(b.last_pressed and !a.last_pressed and !c.last_pressed);
    // Consumed by the frame: gone in the next one.
    try drawn(&r);
    try testing.expect(!b.last_pressed);
}

test "a hidden (paused) window is not drawn until shown" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var r = testRunner(.{});
    defer r.deinit();
    var a = pane('a', &log);
    var b = pane('b', &log);
    a.ref = try openOrSkip(&r, Pane, &a, spec);
    b.ref = try openOrSkip(&r, Pane, &b, spec);
    try r.start();
    defer r.stop();
    b.ref.?.hide();
    try drawn(&r);
    try drawn(&r);
    try testing.expectEqual(@as(u32, 2), a.frames);
    try testing.expectEqual(@as(u32, 0), b.frames);
    b.ref.?.show();
    try drawn(&r);
    try testing.expectEqual(@as(u32, 1), b.frames);
}

// ---- frames -----------------------------------------------------------------------------------

const FrameProbe = struct {
    frames: u32 = 0,
    calls_finish: bool = false,
    times: [8]f64 = undefined,
    alloc_ptrs: [2]usize = .{ 0, 0 },

    pub fn frame(p: *FrameProbe, ui: *Ui, ctx: *Context) void {
        if (p.frames < p.times.len) p.times[p.frames] = ui.input.time;
        p.frames += 1;
        if (p.calls_finish) ui.finish();
        // Allocate every frame: the arena must not grow without bound.
        const buf = ctx.frameAlloc().alloc(u8, 4000) catch return;
        @memset(buf, 7);
    }
};

test "Ui.finish runs exactly once per frame whether or not the frame calls it; the frame arena is reset" {
    for ([_]bool{ false, true }) |calls_finish| {
        var p: FrameProbe = .{ .calls_finish = calls_finish };
        var r = testRunner(.{});
        defer r.deinit();
        const w = try openOrSkip(&r, FrameProbe, &p, spec);
        try r.start();
        defer r.stop();
        for (0..60) |_| try drawn(&r);
        try testing.expectEqual(@as(u32, 60), p.frames);
        try testing.expectEqual(@as(u64, 60), w.state.frames);
        // 60 frames of 4000 bytes would be 240000 bytes without the reset.
        try testing.expect(r.frame_arena.queryCapacity() < 32 * 1024);
    }
}

test "fake clock: Input.time follows it, per turn step and setTime" {
    var p: FrameProbe = .{};
    var r = testRunner(.{ .clock = .{ .fake = 0.25 } });
    defer r.deinit();
    const w = try openOrSkip(&r, FrameProbe, &p, spec);
    try r.start();
    defer r.stop();
    for (0..3) |_| try drawn(&r);
    try testing.expectEqualSlices(f64, &.{ 0, 0.25, 0.5 }, p.times[0..3]);
    r.setTime(10);
    try drawn(&r);
    try testing.expectEqual(@as(f64, 10), p.times[3]);
    try testing.expectEqual(@as(f64, 10), w.input.time);
    try testing.expectEqual(@as(f64, 10.25), r.now());
}

// ---- redraw on demand ---------------------------------------------------------------------------

const Widgets = struct {
    frames: u32 = 0,
    field: ui_mod.TextFieldState,
    with_field: bool = false,
    with_tip: bool = false,
    tip_shown: bool = false,
    animate: bool = false,
    tip_rect: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 30 },
    redraw_requests: u32 = 0,
    interval_ms: ?u32 = null,

    pub fn frame(w: *Widgets, ui: *Ui) void {
        w.frames += 1;
        if (w.with_field) _ = ui.textField(.{ .x = 10, .y = 100, .w = 200, .h = 30 }, &w.field, .{});
        if (w.with_tip) w.tip_shown = popup.tooltipVisible(ui, w.tip_rect, 0.5);
        if (w.animate) ui.requestRedraw();
    }
    pub fn update(w: *Widgets, ctx: *Context) void {
        if (w.redraw_requests > 0) {
            w.redraw_requests -= 1;
            ctx.requestRedraw();
        }
        ctx.redrawEvery(w.interval_ms);
    }
};

/// A started on-demand runner with one window, past its first (settling) frames.
fn onDemand(w: *Widgets, r: *Runner) !*AppWindow {
    r.use(Widgets, w);
    const win = try openOrSkip(r, Widgets, w, spec);
    try r.start();
    try drawn(r);
    try drawn(r);
    try testing.expectEqual(app.Result.idle, try r.iterate());
    try testing.expectEqual(@as(u32, 2), w.frames);
    return win;
}

fn countFrames(r: *Runner, w: *const Widgets, t0: f64, t1: f64, dt: f64) !u32 {
    const before = w.frames;
    var t = t0;
    while (t <= t1 + 1e-9) : (t += dt) {
        r.setTime(t);
        _ = try r.iterate();
    }
    return w.frames - before;
}

test "on demand: idle draws nothing, however long it lasts" {
    var w: Widgets = .{ .field = ui_mod.TextFieldState.init(testing.allocator) };
    defer w.field.deinit();
    var r = testRunner(.{ .redraw = .on_demand });
    defer r.deinit();
    _ = try onDemand(&w, &r);
    defer r.stop();
    try testing.expectEqual(@as(u32, 0), try countFrames(&r, &w, 1, 600, 1));
}

test "on demand: an event draws two frames, then nothing; every kind of input counts" {
    var w: Widgets = .{ .field = ui_mod.TextFieldState.init(testing.allocator) };
    defer w.field.deinit();
    var r = testRunner(.{ .redraw = .on_demand });
    defer r.deinit();
    const win = try onDemand(&w, &r);
    defer r.stop();
    const id = win.id();
    const events = [_]app.Event{
        .{ .mouse_move = .{ .window = id, .x = 1, .y = 1 } },
        .{ .mouse_down = .{ .window = id, .x = 1, .y = 1, .button = 1 } },
        .{ .mouse_up = .{ .window = id, .x = 1, .y = 1, .button = 1 } },
        .{ .mouse_wheel = .{ .window = id, .dx = 0, .dy = 1 } },
        .{ .key_down = .{ .code = 'a', .window = id } },
        .{ .text_input = .{ .window = id, .text = platform.TextChunk.from("a") } },
        .{ .focus_lost = id },
    };
    for (events) |ev| {
        const before = w.frames;
        r.dispatch(ev);
        try drawn(&r);
        try drawn(&r);
        try testing.expectEqual(app.Result.idle, try r.iterate());
        try testing.expectEqual(before + 2, w.frames);
    }
}

test "on demand: the tooltip delay draws frames until the tooltip shows, then none" {
    var w: Widgets = .{ .field = ui_mod.TextFieldState.init(testing.allocator), .with_tip = true };
    defer w.field.deinit();
    var r = testRunner(.{ .redraw = .on_demand });
    defer r.deinit();
    const win = try onDemand(&w, &r);
    defer r.stop();
    r.setTime(1.0);
    r.dispatch(.{ .mouse_move = .{ .window = win.id(), .x = 20, .y = 20 } });
    try drawn(&r);
    try drawn(&r);
    try testing.expect(!w.tip_shown);
    // Nothing to draw until the delay (0.5 s after the pointer came to rest) has run out.
    try testing.expectEqual(@as(u32, 0), try countFrames(&r, &w, 1.01, 1.49, 0.01));
    try testing.expect(!w.tip_shown);
    // One frame at the due time shows it...
    try testing.expectEqual(@as(u32, 1), try countFrames(&r, &w, 1.5, 1.5, 0.01));
    try testing.expect(w.tip_shown);
    // ...and no more are drawn while it stays up.
    try testing.expectEqual(@as(u32, 0), try countFrames(&r, &w, 1.51, 30, 0.5));
    try testing.expect(w.tip_shown);
}

test "on demand: a focused text field redraws at its caret's blink, an unfocused one never" {
    var w: Widgets = .{ .field = ui_mod.TextFieldState.init(testing.allocator), .with_field = true };
    defer w.field.deinit();
    var r = testRunner(.{ .redraw = .on_demand });
    defer r.deinit();
    const win = try onDemand(&w, &r);
    defer r.stop();
    try testing.expectEqual(@as(u32, 0), try countFrames(&r, &w, 0.01, 5, 0.01));

    win.state.focusOn(&w.field);
    w.field.blink_origin = 10.0;
    r.requestRedraw();
    r.setTime(10.0);
    try drawn(&r);
    try drawn(&r);
    // A half period (0.53 s) later the caret turns off, then on again...
    try testing.expectEqual(@as(u32, 0), try countFrames(&r, &w, 10.01, 10.5, 0.01));
    try testing.expectEqual(@as(u32, 6), try countFrames(&r, &w, 10.51, 13.7, 0.01));
    // Typing resets the blink: the caret is on, and the next change is a half period after the key.
    r.setTime(20);
    r.dispatch(.{ .text_input = .{ .window = win.id(), .text = platform.TextChunk.from("a") } });
    try drawn(&r);
    try drawn(&r);
    try testing.expectEqual(@as(u32, 0), try countFrames(&r, &w, 20.01, 20.5, 0.01));
    try testing.expectEqual(@as(u32, 1), try countFrames(&r, &w, 20.51, 20.6, 0.01));
}

test "on demand: animating widgets keep frames coming until they stop asking" {
    var w: Widgets = .{ .field = ui_mod.TextFieldState.init(testing.allocator), .animate = true };
    defer w.field.deinit();
    var r = testRunner(.{ .redraw = .on_demand });
    defer r.deinit();
    r.use(Widgets, &w);
    _ = try openOrSkip(&r, Widgets, &w, spec);
    try r.start();
    defer r.stop();
    for (0..20) |_| try drawn(&r);
    w.animate = false;
    // The frame that does not ask again is the last one (plus any owed settle frame: none left).
    try drawn(&r);
    try testing.expectEqual(app.Result.idle, try r.iterate());
    try testing.expectEqual(@as(u32, 21), w.frames);
}

test "on demand: the app can ask for frames, once, at a time, or every so often" {
    var w: Widgets = .{ .field = ui_mod.TextFieldState.init(testing.allocator) };
    defer w.field.deinit();
    var r = testRunner(.{ .redraw = .on_demand });
    defer r.deinit();
    _ = try onDemand(&w, &r);
    defer r.stop();

    // From `update`: the settle count of frames.
    w.redraw_requests = 1;
    try drawn(&r);
    try drawn(&r);
    try testing.expectEqual(app.Result.idle, try r.iterate());
    try testing.expectEqual(@as(u32, 4), w.frames);

    // At a time: one frame when the clock gets there.
    r.setTime(100);
    r.redrawAt(105);
    try testing.expectEqual(@as(u32, 0), try countFrames(&r, &w, 100, 104.9, 0.5));
    try testing.expectEqual(@as(u32, 1), try countFrames(&r, &w, 105, 110, 0.5));

    // Every 100 ms while an interval is set, nothing once it is cleared.
    w.interval_ms = 100;
    r.setTime(200);
    _ = try r.iterate(); // the update hook sets the interval
    const n = try countFrames(&r, &w, 200.05, 201, 0.05);
    try testing.expect(n >= 9 and n <= 11);
    w.interval_ms = null;
    _ = try r.iterate();
    try testing.expectEqual(@as(u32, 0), try countFrames(&r, &w, 202, 210, 0.05));
}

test "always: every turn draws" {
    var w: Widgets = .{ .field = ui_mod.TextFieldState.init(testing.allocator) };
    defer w.field.deinit();
    var r = testRunner(.{});
    defer r.deinit();
    r.use(Widgets, &w);
    _ = try openOrSkip(&r, Widgets, &w, spec);
    try r.start();
    defer r.stop();
    for (0..25) |_| try drawn(&r);
    try testing.expectEqual(@as(u32, 25), w.frames);
}

// ---- scripted runs ----------------------------------------------------------------------------

const Scripted = struct {
    pressed_on: [16]bool = @splat(false),
    released_on: [16]bool = @splat(false),
    typed: [128]u8 = undefined,
    typed_len: usize = 0,
    wheel: f32 = 0,
    focus_seen: [16]bool = @splat(false),
    frames: u32 = 0,
    saved: bool = false,

    pub fn frame(s: *Scripted, ui: *Ui) void {
        const n = s.frames;
        s.frames += 1;
        if (n < 16) {
            s.pressed_on[n] = ui.input.pressed;
            s.released_on[n] = ui.input.released;
            s.focus_seen[n] = ui.input.window_focused;
        }
        for (ui.input.events()) |e| switch (e) {
            .text => |t| {
                @memcpy(s.typed[s.typed_len..][0..t.len], t.slice());
                s.typed_len += t.len;
            },
            .key => {},
        };
        s.wheel += ui.input.wheel_y;
        ui.label(.{ .x = 10, .y = 10, .w = 200, .h = 20 }, "scripted", .{});
    }
    pub fn script(_: *Scripted, step: *app.Step) !void {
        switch (step.n) {
            2 => step.click(40, 50),
            5 => step.text("héllo, wörld: a string longer than one chunk of thirty-two bytes"),
            6 => step.wheel(0, 3),
            7 => step.focus(false),
            8 => step.focus(true),
            9 => step.done(),
            else => {},
        }
    }
};

test "a scripted run injects input through the live loop and ends when told" {
    platform.useDummyVideo();
    var s: Scripted = .{};
    app.run(Scripted, &s, .{
        .window = win_opts,
        .frame_ms = 0,
        .gpa = testing.allocator,
        .script = .{ .sleep_ms = 0, .max_frames = 50 },
    }) catch |e| switch (e) {
        error.PlatformInitFailed => return error.SkipZigTest,
        else => return e,
    };
    try testing.expectEqual(@as(u32, 10), s.frames);
    // A click: the press in one frame, the release (next turn) in the next, nothing else.
    try testing.expect(s.pressed_on[2] and !s.pressed_on[3] and s.released_on[3] and !s.released_on[2]);
    try testing.expectEqualStrings("héllo, wörld: a string longer than one chunk of thirty-two bytes", s.typed[0..s.typed_len]);
    try testing.expectEqual(@as(f32, 3), s.wheel);
    try testing.expect(s.focus_seen[6] and !s.focus_seen[7] and s.focus_seen[8]);
}

test "a scripted run that never ends fails instead of hanging" {
    platform.useDummyVideo();
    const Never = struct {
        pub fn frame(_: *@This(), _: *Ui) void {}
    };
    var n: Never = .{};
    try testing.expectError(error.TooManyFrames, app.run(Never, &n, .{
        .window = win_opts,
        .gpa = testing.allocator,
        .script = .{ .sleep_ms = 0, .max_frames = 5 },
    }) catch |e| switch (e) {
        error.PlatformInitFailed => return error.SkipZigTest,
        else => e,
    });
}

/// What the hand-written loops drew, and what the loop draws: the same widgets.
fn paint(ui: *Ui) void {
    const t = ui.theme;
    ui.list.rect(.{ .x = 0, .y = 0, .w = 300, .h = 200 }, t.bg);
    ui.label(.{ .x = 16, .y = 16, .w = 200, .h = 24 }, "Snapshot parity", .{ .size = 16, .weight = .semibold });
    _ = ui.button(.{ .x = 16, .y = 60, .w = 120, .h = 32 }, "A button", .{});
    var on = true;
    _ = ui.toggle(.{ .x = 160, .y = 60, .w = 44, .h = 24 }, &on, .{});
    ui.list.rrect(.{ .x = 16, .y = 110, .w = 200, .h = 60 }, 10, t.accent);
}

const Parity = struct {
    pub fn frame(_: *Parity, ui: *Ui) void {
        paint(ui);
    }
    pub fn script(_: *Parity, step: *app.Step) !void {
        if (step.n == 3) {
            try step.save("looped", .{});
            step.done();
        }
    }
};

test "a scripted run writes the same BMP as the hand-written loop it replaced" {
    platform.useDummyVideo();
    const io = testing.io;
    const dir = ".zig-cache/vass-app-test-parity";
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const theme: ui_mod.Theme = .{ .card_radius = 12 };

    // The loop.
    var p: Parity = .{};
    app.run(Parity, &p, .{
        .window = win_opts,
        .theme = theme,
        .frame_ms = 0,
        .gpa = testing.allocator,
        .script = .{ .dir = dir, .sleep_ms = 0, .max_frames = 20 },
    }) catch |e| switch (e) {
        error.PlatformInitFailed => return error.SkipZigTest,
        else => return e,
    };

    // By hand: window, display list, Ui with a State, widgets, finish, render with a snapshot.
    {
        const win = platform.Window.create(testing.allocator, win_opts) catch return error.SkipZigTest;
        defer win.destroy();
        var list = @import("../core/gfx.zig").DisplayList.init(testing.allocator);
        defer list.deinit();
        var state: ui_mod.State = .{};
        var input: ui_mod.Input = .{};
        input.time = 0;
        for (0..4) |_| {
            list.reset();
            var ui = Ui.init(&list, win, input, theme);
            ui.state = &state;
            paint(&ui);
            ui.finish();
            win.snapshot_path = dir ++ "/by-hand.bmp";
            win.render(&list, theme.bg);
            input.endFrame();
        }
    }

    const a = try std.Io.Dir.cwd().readFileAlloc(io, dir ++ "/looped.bmp", testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(a);
    const b = try std.Io.Dir.cwd().readFileAlloc(io, dir ++ "/by-hand.bmp", testing.allocator, .limited(1 << 24));
    defer testing.allocator.free(b);
    try testing.expect(a.len > 1000);
    try testing.expectEqualSlices(u8, a, b);
}

test "a state type with its own init and deinit runs as it is" {
    const Owned = struct {
        gpa: std.mem.Allocator,
        buf: []u8,
        frames: u32 = 0,

        pub fn init(gpa: std.mem.Allocator) !@This() {
            return .{ .gpa = gpa, .buf = try gpa.alloc(u8, 16) };
        }
        pub fn deinit(o: *@This()) void {
            o.gpa.free(o.buf);
        }
        pub fn frame(o: *@This(), _: *Ui) void {
            o.frames += 1;
        }
        pub fn script(_: *@This(), step: *app.Step) !void {
            if (step.n == 2) step.done();
        }
    };
    platform.useDummyVideo();
    var o = try Owned.init(testing.allocator);
    defer o.deinit();
    app.run(Owned, &o, .{ .window = win_opts, .frame_ms = 0, .gpa = testing.allocator, .script = .{ .sleep_ms = 0, .max_frames = 20 } }) catch |e| switch (e) {
        error.PlatformInitFailed => return error.SkipZigTest,
        else => return e,
    };
    try testing.expectEqual(@as(u32, 3), o.frames);
}

// ---- compile-time hook checks are by design compile errors; here, a type with every optional
// hook at once is accepted. ------------------------------------------------------------------------

test "a program may declare every optional hook, with or without errors, and the longer forms" {
    const All = struct {
        pub fn frame(_: *@This(), _: *Ui, _: *Context) !void {}
        pub fn theme(_: *@This()) ui_mod.Theme {
            return .{};
        }
        pub fn windowClosed(_: *@This(), _: *Context) void {}
        pub fn setup(_: *@This(), _: *Context) !void {}
        pub fn teardown(_: *@This(), _: *Context) void {}
        pub fn event(_: *@This(), _: *Context, _: app.Event) bool {
            return false;
        }
        pub fn update(_: *@This(), _: *Context) void {}
        pub fn afterFrame(_: *@This(), _: *Context) !void {}
        pub fn closeRequested(_: *@This(), _: *Context, _: *AppWindow) bool {
            return true;
        }
        pub fn script(_: *@This(), _: *app.Step) void {}
    };
    var all: All = .{};
    var r = testRunner(.{});
    defer r.deinit();
    r.use(All, &all);
    _ = try openOrSkip(&r, All, &all, spec);
    try r.start();
    defer r.stop();
    try drawn(&r);
}

// ---- how the loop ends ---------------------------------------------------------------------------

/// A window of `Life`.
const LifeWin = struct {
    life: *Life,
    name: u8,

    pub fn frame(w: *LifeWin, ui: *Ui) void {
        _ = ui;
        w.life.note(w.name);
    }
    /// Upper case: the window's hook. The platform windows must all still exist.
    pub fn windowClosed(w: *LifeWin, ctx: *Context) void {
        w.life.note(w.name - 'a' + 'A');
        if (ctx.runner.entries.items.len != w.life.nwin) w.life.bad = true;
        _ = ctx.window();
    }
};

/// A program that records what its hooks see, and ends the loop in the way `ending` says on its
/// second turn. Its windows are `a` (the main one) and, with two, `b`.
const Life = struct {
    const Ending = enum { quit_event, close_button, ctx_close, ctx_quit, hook_error, setup_fails, script_done, script_stop };

    order: [64]u8 = undefined,
    n: usize = 0,
    nwin: usize,
    ending: Ending,
    wins: [2]LifeWin = undefined,
    updates: u32 = 0,
    /// A hook ran against a loop that no longer had its windows.
    bad: bool = false,

    fn note(l: *Life, c: u8) void {
        l.order[l.n] = c;
        l.n += 1;
    }
    fn log(l: *const Life) []const u8 {
        return l.order[0..l.n];
    }

    pub fn setup(l: *Life, ctx: *Context) !void {
        l.note('I');
        for (0..l.nwin) |i| {
            l.wins[i] = .{ .life = l, .name = 'a' + @as(u8, @intCast(i)) };
            _ = try ctx.open(LifeWin, &l.wins[i], spec);
        }
        if (l.ending == .setup_fails) return error.Boom;
    }
    pub fn teardown(l: *Life, ctx: *Context) void {
        l.note('T');
        // The windows are still there, the main one included.
        _ = ctx.window();
        _ = ctx.uiState();
        if (ctx.runner.entries.items.len != l.nwin) l.bad = true;
    }
    pub fn update(l: *Life, ctx: *Context) !void {
        l.note('U');
        l.updates += 1;
        if (l.updates != 2) return;
        switch (l.ending) {
            .quit_event => ctx.runner.dispatch(.quit),
            .close_button => ctx.requestClose(ctx.runner.entries.items[0]),
            .ctx_close => ctx.close(ctx.runner.entries.items[0]),
            .ctx_quit => ctx.quit(),
            .hook_error => return error.Boom,
            else => {},
        }
    }
    pub fn afterFrame(l: *Life, ctx: *Context) !void {
        l.note('A');
        _ = ctx.window();
        _ = ctx.uiState();
    }
    pub fn script(l: *Life, step: *app.Step) !void {
        if (step.n != 1) return;
        switch (l.ending) {
            .script_done => step.done(),
            .script_stop => step.stop(),
            else => {},
        }
    }
};

fn expectLife(ending: Life.Ending, nwin: usize, expected: []const u8, run_error: ?anyerror) !void {
    var l: Life = .{ .nwin = nwin, .ending = ending };
    const scripted = ending == .script_done or ending == .script_stop;
    var r = if (scripted)
        Runner.initScripted(testing.allocator, .{ .frame_ms = 0 }, .{ .sleep_ms = 0, .max_frames = 20 })
    else
        testRunner(.{});
    defer r.deinit();
    platform.useDummyVideo();
    r.use(Life, &l);
    if (run_error) |e| {
        try testing.expectError(e, r.run());
    } else {
        r.run() catch |e| switch (e) {
            error.PlatformInitFailed => return error.SkipZigTest,
            else => return e,
        };
    }
    try testing.expectEqualStrings(expected, l.log());
    try testing.expect(!l.bad);
    try testing.expectEqual(@as(usize, 0), r.entries.items.len);
}

/// What `Life` logs: setup, two turns (the second one ends the loop before its frames unless the
/// ending is a scripted `done`), then the windows' hooks (last opened first), then the program's.
fn lifeLog(comptime nwin: usize, comptime ending: Life.Ending) []const u8 {
    const frames = if (nwin == 1) "a" else "ab";
    const closed = if (nwin == 1) "A" else "BA";
    return switch (ending) {
        .setup_fails => "I" ++ closed,
        .script_done => "IU" ++ frames ++ "AU" ++ frames ++ "A" ++ closed ++ "T",
        .script_stop => "IU" ++ frames ++ "AU" ++ closed ++ "T",
        else => "IU" ++ frames ++ "AU" ++ closed ++ "T",
    };
}

test "ending by Cmd+Q (a quit event): windowClosed, then teardown, then the windows are destroyed" {
    inline for (.{ 1, 2 }) |nwin| try expectLife(.quit_event, nwin, lifeLog(nwin, .quit_event), null);
}

test "ending by the close button of the main window: windowClosed, then teardown, then the windows are destroyed" {
    inline for (.{ 1, 2 }) |nwin| try expectLife(.close_button, nwin, lifeLog(nwin, .close_button), null);
}

test "ending by ctx.close of the main window: windowClosed, then teardown, then the windows are destroyed" {
    inline for (.{ 1, 2 }) |nwin| try expectLife(.ctx_close, nwin, lifeLog(nwin, .ctx_close), null);
}

test "ending by ctx.quit: windowClosed, then teardown, then the windows are destroyed" {
    inline for (.{ 1, 2 }) |nwin| try expectLife(.ctx_quit, nwin, lifeLog(nwin, .ctx_quit), null);
}

test "ending by an error returned from a hook: windowClosed, then teardown, then the windows are destroyed" {
    inline for (.{ 1, 2 }) |nwin| try expectLife(.hook_error, nwin, lifeLog(nwin, .hook_error), error.Boom);
}

test "ending by a failing setup: windowClosed, then teardown, then the windows are destroyed" {
    inline for (.{ 1, 2 }) |nwin| try expectLife(.setup_fails, nwin, lifeLog(nwin, .setup_fails), error.Boom);
}

test "ending by a script's done: windowClosed, then teardown, then the windows are destroyed" {
    inline for (.{ 1, 2 }) |nwin| try expectLife(.script_done, nwin, lifeLog(nwin, .script_done), null);
}

test "ending by a script's stop: windowClosed, then teardown, then the windows are destroyed" {
    inline for (.{ 1, 2 }) |nwin| try expectLife(.script_stop, nwin, lifeLog(nwin, .script_stop), null);
}

// ---- scripted runs that draw only on demand -------------------------------------------------------

const Lazy = struct {
    /// Which of `save` and `done` the script calls on a turn without input.
    call: enum { done, save },

    pub fn frame(_: *Lazy, _: *Ui) void {}
    pub fn script(l: *Lazy, step: *app.Step) !void {
        switch (l.call) {
            .done => if (step.n == 6) step.done(),
            .save => switch (step.n) {
                6 => try step.save("lazy", .{}),
                8 => step.stop(),
                else => {},
            },
        }
    }
};

test "a scripted on-demand run: done and save on a turn without input still draw" {
    platform.useDummyVideo();
    const io = testing.io;
    const dir = ".zig-cache/vass-app-test-lazy";
    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    for ([_]@TypeOf(@as(Lazy, undefined).call){ .done, .save }) |call| {
        var l: Lazy = .{ .call = call };
        app.run(Lazy, &l, .{
            .window = win_opts,
            .redraw = .on_demand,
            .frame_ms = 0,
            .gpa = testing.allocator,
            .script = .{ .dir = dir, .sleep_ms = 0, .max_frames = 40 },
        }) catch |e| switch (e) {
            error.PlatformInitFailed => return error.SkipZigTest,
            else => return e,
        };
    }
    const bmp = try std.Io.Dir.cwd().readFileAlloc(io, dir ++ "/lazy.bmp", testing.allocator, .limited(1 << 24));
    testing.allocator.free(bmp);
}

// ---- memory of the frames --------------------------------------------------------------------------

test "live-resize frames do not pile up in the arena of the loop turn" {
    var p: FrameProbe = .{};
    var r = testRunner(.{});
    defer r.deinit();
    const w = try openOrSkip(&r, FrameProbe, &p, .{ .window = .{ .title = "r", .width = 200, .height = 100, .hidden = true, .resizable = true } });
    try r.start();
    defer r.stop();
    try drawn(&r);
    // A drag is about sixty frames a second inside one loop turn.
    for (0..60) |_| AppWindow.onResize(w);
    try testing.expectEqual(@as(u32, 61), p.frames);
    try testing.expect(r.frame_arena.queryCapacity() < 32 * 1024);
}

/// Allocates in the turn's arena, then runs live-resize frames of another window, then checks its
/// memory is intact.
const Interrupted = struct {
    other: *AppWindow = undefined,
    intact: bool = false,

    pub fn frame(i: *Interrupted, ui: *Ui, ctx: *Context) void {
        _ = ui;
        const mine = ctx.frameAlloc().alloc(u8, 4000) catch return;
        @memset(mine, 5);
        for (0..30) |_| AppWindow.onResize(i.other);
        i.intact = std.mem.allEqual(u8, mine, 5);
    }
};

test "a live-resize frame inside a loop turn leaves the turn's frame memory alone" {
    var probe: FrameProbe = .{};
    var i: Interrupted = .{};
    var r = testRunner(.{});
    defer r.deinit();
    i.other = try openOrSkip(&r, FrameProbe, &probe, .{ .window = .{ .title = "r", .width = 200, .height = 100, .hidden = true, .resizable = true }, .draw_order = 1 });
    _ = try openOrSkip(&r, Interrupted, &i, spec);
    try r.start();
    defer r.stop();
    try drawn(&r);
    try testing.expect(i.intact);
    try testing.expectEqual(@as(u32, 31), probe.frames);
}

test "a closed or hidden window gets no live-resize frame" {
    var p: FrameProbe = .{};
    var r = testRunner(.{});
    defer r.deinit();
    const w = try openOrSkip(&r, FrameProbe, &p, .{ .window = .{ .title = "r", .width = 200, .height = 100, .hidden = true, .resizable = true } });
    try r.start();
    defer r.stop();
    AppWindow.onResize(w);
    try testing.expectEqual(@as(u32, 1), p.frames);
    w.hide();
    AppWindow.onResize(w);
    try testing.expectEqual(@as(u32, 1), p.frames);
    w.show();
    r.close(w);
    AppWindow.onResize(w);
    try testing.expectEqual(@as(u32, 1), p.frames);
}

// ---- the window list ----------------------------------------------------------------------------------

/// Opens windows while it walks `ctx.windows()`.
const Spawner = struct {
    log: *std.ArrayList(u8),
    panes: [6]Pane = undefined,
    done: bool = false,
    stable: bool = false,

    pub fn update(s: *Spawner, ctx: *Context) !void {
        if (s.done) return;
        s.done = true;
        // Every append may move the runner's own list: make sure the next one does.
        ctx.runner.entries.shrinkAndFree(testing.allocator, ctx.runner.entries.items.len);
        const ws = try ctx.windows();
        var before: [8]*AppWindow = undefined;
        @memcpy(before[0..ws.len], ws);
        const n = ws.len;
        for (&s.panes, 0..) |*p, i| {
            p.* = pane('x' + @as(u8, @intCast(i)), s.log);
            _ = try ctx.open(Pane, p, spec);
            // What was handed out is still the list of the turn's start.
            if (ws.len != n or !std.mem.eql(*AppWindow, ws, before[0..n])) return;
        }
        s.stable = true;
    }
};

test "ctx.windows() stays valid while windows are opened during the turn" {
    var log: std.ArrayList(u8) = .empty;
    defer log.deinit(testing.allocator);
    var s: Spawner = .{ .log = &log };
    var r = testRunner(.{ .end = .explicit });
    defer r.deinit();
    r.use(Spawner, &s);
    var a = pane('a', &log);
    var b = pane('b', &log);
    _ = try openOrSkip(&r, Pane, &a, spec);
    _ = try openOrSkip(&r, Pane, &b, spec);
    try r.start();
    defer r.stop();
    try drawn(&r);
    try testing.expect(s.stable);
    try testing.expectEqual(@as(usize, 8), r.entries.items.len);
}

// ---- the fake clock ----------------------------------------------------------------------------------

test "fake clock: a long run is n * step, not a sum of rounded steps" {
    var r = testRunner(.{ .redraw = .on_demand, .clock = .{ .fake = 0.1 } });
    defer r.deinit();
    try r.start();
    defer r.stop();
    for (0..1000) |_| _ = try r.iterate();
    try testing.expectEqual(@as(f64, 1000) * 0.1, r.now());
    r.setTime(5);
    for (0..3) |_| _ = try r.iterate();
    try testing.expectEqual(5 + @as(f64, 3) * 0.1, r.now());
}

// ---- no window -----------------------------------------------------------------------------------------

test "an explicit loop with every window closed: hooks and scripts get null, nothing panics" {
    const Empty = struct {
        saw_none: bool = false,
        pub fn frame(_: *@This(), _: *Ui) void {}
        pub fn update(e: *@This(), ctx: *Context) !void {
            if ((try ctx.windows()).len == 0) {
                e.saw_none = ctx.windowOrNull() == null and ctx.uiStateOrNull() == null and ctx.runner.mainWindow() == null;
            }
        }
        pub fn script(_: *@This(), step: *app.Step) !void {
            if (step.n == 1) for (step.runner.entries.items) |w| step.runner.close(w);
            // Input and a snapshot for a window that is not there are dropped.
            if (step.n == 3) {
                step.click(1, 1);
                step.text("x");
                try step.save("none", .{});
                step.done();
            }
        }
    };
    platform.useDummyVideo();
    var e: Empty = .{};
    var r = Runner.initScripted(testing.allocator, .{ .end = .explicit, .frame_ms = 0 }, .{ .sleep_ms = 0, .max_frames = 20 });
    defer r.deinit();
    r.use(Empty, &e);
    var w: Empty = .{};
    _ = r.open(Empty, &w, spec) catch return error.SkipZigTest;
    try r.run();
    try testing.expect(e.saw_none);
}
