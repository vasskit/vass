//! The application loop: windows, events, one frame per window, pacing.
//!
//! A `Runner` owns a dynamic set of windows. Each window has its own `Input`, `ui.State`,
//! display list and live-resize callback; its frame function builds the UI. Every turn of the
//! loop (`iterate`) does, in this order:
//!
//!   1. (on-demand policy only) wait for an event, a due timer or a redraw request,
//!   2. pump the events: the program's `event` hook first, then `Input.feed` for every window,
//!   3. set `Input.time` from the clock,
//!   4. the program's `update` hook, then, in a scripted run, its `script` hook,
//!   5. destroy the windows that were closed so far (never while a frame runs),
//!   6. draw every window: `Ui.init`, attach the window's `ui.State`, the frame function,
//!      `Ui.finish`, `Window.render`,
//!   7. `Input.endFrame` for every window, the program's `afterFrame` hook, destroy windows
//!      closed during the frames, then the pacing sleep.
//!
//! The loop ends when a quit event, `Context.quit`, the end policy or a script says so. From then
//! on it draws nothing and calls no frame or `afterFrame` hook, and it destroys no window: that
//! is `stop`'s job, which runs, in this order, every window's `windowClosed` hook (last opened
//! first), the program's `teardown` hook and then the destruction of the windows. So the hooks
//! can still use the windows, the main one included.
//!
//! The live-resize callback of a resizable window draws that window alone with `Input.idle`
//! and without `update`, as `Window.setFrameCallback` requires.
//!
//! A `Runner` must stay at one address once a window is open (the windows point back at it).
const std = @import("std");
const platform = @import("../platform/backend_sdl.zig");
const ui_mod = @import("../ui/ui.zig");
const gfx = @import("../core/gfx.zig");
const geom = @import("../core/geom.zig");
const script_mod = @import("script.zig");

const Ui = ui_mod.Ui;
pub const Event = platform.Event;
pub const Step = script_mod.Step;

/// When the loop draws.
pub const RedrawPolicy = enum {
    /// Every loop turn, paced to one frame per `Options.frame_ms`: a steady frame rate whether or not
    /// anything changed. What hand-written loops do.
    always,
    /// Only when something asks for it, blocking in the OS's event wait (no CPU) in between.
    /// What asks: any input event (two frames, because an immediate-mode UI needs a second one
    /// to settle: popups use last frame's rectangles), `Ui.requestRedraw` while a widget
    /// animates, `Ui.requestRedrawAt` (the tooltip delay, the caret's blink),
    /// `Context.requestRedraw`, `Context.redrawAt` and `Options.redraw_every_ms` (audio meters,
    /// polling) and `wake` from another thread.
    on_demand,
};

/// When the loop ends because a window was closed. (Cmd+Q, `Context.quit` and the end of a
/// scripted run always end it.)
pub const End = enum {
    /// The main window was closed: the first one opened, or the one opened with `WindowSpec.main`.
    main_window_closed,
    /// No window is left.
    last_window_closed,
    /// Never: closing windows is not enough, the app calls `Context.quit`. For an app that lives
    /// in the menu bar and opens or hides windows as it likes.
    explicit,
};

pub const Clock = union(enum) {
    /// Milliseconds from the platform's timer, in seconds.
    real,
    /// Deterministic: starts at 0 and is this many seconds times the number of loop turns so far
    /// (0: only `Runner.setTime` moves it).
    fake: f64,
};

pub const Pace = struct { sleep_ns: u64, deadline: ?u64 };

/// How long to sleep after a frame that began at `start` and finished at `now`, and the deadline
/// for the next one. The deadline moves by whole periods so small errors do not add up; a late
/// frame restarts from `now` rather than catching up with a burst. Zero `period` never sleeps.
pub fn pace(deadline: ?u64, start: u64, now: u64, period: u64) Pace {
    if (period == 0) return .{ .sleep_ns = 0, .deadline = null };
    const due = (deadline orelse start) + period;
    if (due <= now) return .{ .sleep_ns = 0, .deadline = now };
    return .{ .sleep_ns = due - now, .deadline = due };
}

pub const Options = struct {
    redraw: RedrawPolicy = .always,
    /// The frame period in milliseconds: the pace of `.always`, and the fastest rate a stream of
    /// events or an animation can reach in `.on_demand`. After a drawn frame the loop sleeps only
    /// the rest of the period (a frame that took longer is not followed by a sleep). With the fake
    /// clock and in scripted runs it is a plain sleep after every frame. 0: no sleep.
    frame_ms: u32 = 16,
    /// `.on_demand`: also draw at least this often (an audio meter, a polled source). Can be
    /// changed at run time with `Context.redrawEvery`.
    redraw_every_ms: ?u32 = null,
    /// Frames drawn after an event (or `requestRedraw`) in `.on_demand`.
    settle_frames: u32 = 2,
    end: End = .main_window_closed,
    clock: Clock = .real,
    /// Throw away the real mouse and keyboard (a scripted run injects its own); quit and close
    /// requests still count.
    ignore_os_input: bool = false,
    /// Open every window hidden (scripted runs).
    hide_windows: bool = false,
    /// A guard for scripted runs and tests: `run` fails with `error.TooManyFrames` after this
    /// many loop turns.
    max_iterations: ?u32 = null,
};

pub const WindowSpec = struct {
    window: platform.WindowOptions,
    theme: ui_mod.Theme = .{},
    /// What the frame is cleared with; null is `theme.bg`.
    background: ?geom.Color = null,
    /// Start the input method for this window (text fields and areas need it).
    text_input: bool = false,
    /// The window `End.main_window_closed` watches (the first one opened is it otherwise).
    main: bool = false,
    /// Windows are drawn in ascending order, ties in the order they were opened. A tool panel that
    /// reads what the others just did gets a higher number.
    draw_order: i32 = 0,
};

/// One window of the loop. Handles are pointers and stay valid until the window is closed.
pub const AppWindow = struct {
    runner: *Runner,
    window: *platform.Window,
    list: gfx.DisplayList,
    input: ui_mod.Input = .{},
    /// Keyboard focus, popups, tooltip timer, splitter drags...; attached to every `Ui`.
    state: ui_mod.State = .{},
    /// The pointer given to `Runner.open`.
    user: *anyopaque,
    vt: *const WindowVTable,
    theme: ui_mod.Theme,
    background: ?geom.Color,
    draw_order: i32,
    main: bool,
    /// Not drawn while true (a hidden window; see `hide`).
    paused: bool = false,
    /// Closed, and destroyed at the next point between frames (or, when its closing ended the
    /// loop, by `Runner.stop`).
    dead: bool = false,
    /// `windowClosed` has run.
    notified: bool = false,
    /// Frames drawn.
    frames: u64 = 0,

    pub fn id(w: *const AppWindow) u32 {
        return w.window.id();
    }

    /// The pointer passed to `open`, as its type.
    pub fn userAs(w: *const AppWindow, comptime T: type) *T {
        return @ptrCast(@alignCast(w.user));
    }

    /// Shows the window and draws it again. A window the app hides and shows (not closes) is
    /// worth a call here: a hidden one costs no frames.
    pub fn show(w: *AppWindow) void {
        w.paused = false;
        w.window.show();
        w.runner.redraw_frames = @max(w.runner.redraw_frames, w.runner.opts.settle_frames);
    }

    pub fn hide(w: *AppWindow) void {
        w.paused = true;
        w.window.hide();
    }

    /// One frame of this window from `in`: what the loop does for it, and what its live-resize
    /// callback does with `Input.idle`.
    fn draw(w: *AppWindow, in: ui_mod.Input) !void {
        const r = w.runner;
        w.list.reset();
        const theme = if (w.vt.theme) |f| f(w.user) else w.theme;
        var ui = Ui.init(&w.list, w.window, in, theme);
        ui.state = &w.state;
        var ctx = r.context(w);
        try w.vt.frame(w.user, &ui, &ctx);
        ui.finish();
        w.window.render(&w.list, w.background orelse theme.bg);
        w.frames += 1;
    }

    /// Runs `windowClosed`, once.
    fn notifyClosed(w: *AppWindow) void {
        if (w.notified) return;
        w.notified = true;
        if (w.vt.closed) |f| {
            var ctx = w.runner.context(w);
            f(w.user, &ctx);
        }
    }

    /// The window's frame callback while the OS live-resizes it (see `Window.setFrameCallback`).
    /// A closed or hidden window gets no frame, as in the loop.
    pub fn onResize(ctx: ?*anyopaque) void {
        const w: *AppWindow = @ptrCast(@alignCast(ctx.?));
        if (w.dead or w.paused) return;
        const r = w.runner;
        // About sixty of these frames run inside one loop turn, which is still using its own
        // frame memory: they get a second arena, emptied by every one of them.
        const nested = r.in_callback;
        if (!nested) _ = r.callback_arena.reset(.retain_capacity);
        r.in_callback = true;
        defer r.in_callback = nested;
        w.draw(w.input.idle()) catch |e| std.log.warn("resize frame failed: {s}", .{@errorName(e)});
    }
};

pub const WindowVTable = struct {
    frame: *const fn (user: *anyopaque, ui: *Ui, ctx: *Context) anyerror!void,
    theme: ?*const fn (user: *anyopaque) ui_mod.Theme,
    closed: ?*const fn (user: *anyopaque, ctx: *Context) void,

    fn of(comptime W: type) *const WindowVTable {
        const S = struct {
            fn frame(user: *anyopaque, ui: *Ui, ctx: *Context) anyerror!void {
                const w: *W = @ptrCast(@alignCast(user));
                if (comptime checkHook(W, "frame", &.{ *W, *Ui }, *Context, void) == 2) {
                    return callVoid(W.frame, .{ w, ui });
                } else return callVoid(W.frame, .{ w, ui, ctx });
            }
            fn theme(user: *anyopaque) ui_mod.Theme {
                const w: *W = @ptrCast(@alignCast(user));
                return W.theme(w);
            }
            fn closed(user: *anyopaque, ctx: *Context) void {
                const w: *W = @ptrCast(@alignCast(user));
                callVoid(W.windowClosed, .{ w, ctx }) catch |e| std.log.warn("windowClosed failed: {s}", .{@errorName(e)});
            }
            const vt: WindowVTable = .{
                .frame = frame,
                .theme = if (@hasDecl(W, "theme")) theme else null,
                .closed = if (@hasDecl(W, "windowClosed")) closed else null,
            };
        };
        if (!@hasDecl(W, "frame")) @compileError("vass.app: " ++ @typeName(W) ++ " needs `pub fn frame(w: *" ++ @typeName(W) ++ ", ui: *vass.Ui) void`");
        _ = checkHook(W, "frame", &.{ *W, *Ui }, *Context, void);
        if (@hasDecl(W, "theme")) _ = checkHook(W, "theme", &.{*W}, null, ui_mod.Theme);
        if (@hasDecl(W, "windowClosed")) _ = checkHook(W, "windowClosed", &.{ *W, *Context }, null, void);
        return &S.vt;
    }
};

const ProgramVTable = struct {
    setup: ?*const fn (p: *anyopaque, ctx: *Context) anyerror!void = null,
    teardown: ?*const fn (p: *anyopaque, ctx: *Context) void = null,
    event: ?*const fn (p: *anyopaque, ctx: *Context, ev: Event) bool = null,
    update: ?*const fn (p: *anyopaque, ctx: *Context) anyerror!void = null,
    after_frame: ?*const fn (p: *anyopaque, ctx: *Context) anyerror!void = null,
    close_requested: ?*const fn (p: *anyopaque, ctx: *Context, w: *AppWindow) bool = null,
    script: ?*const fn (p: *anyopaque, step: *Step) anyerror!void = null,

    fn of(comptime P: type) *const ProgramVTable {
        const S = struct {
            fn self(p: *anyopaque) *P {
                return @ptrCast(@alignCast(p));
            }
            fn setup(p: *anyopaque, ctx: *Context) anyerror!void {
                return callVoid(P.setup, .{ self(p), ctx });
            }
            fn teardown(p: *anyopaque, ctx: *Context) void {
                callVoid(P.teardown, .{ self(p), ctx }) catch |e| std.log.warn("teardown failed: {s}", .{@errorName(e)});
            }
            fn event(p: *anyopaque, ctx: *Context, ev: Event) bool {
                return P.event(self(p), ctx, ev);
            }
            fn update(p: *anyopaque, ctx: *Context) anyerror!void {
                return callVoid(P.update, .{ self(p), ctx });
            }
            fn afterFrame(p: *anyopaque, ctx: *Context) anyerror!void {
                return callVoid(P.afterFrame, .{ self(p), ctx });
            }
            fn closeRequested(p: *anyopaque, ctx: *Context, w: *AppWindow) bool {
                if (comptime checkHook(P, "closeRequested", &.{ *P, *Context }, *AppWindow, bool) == 2) return P.closeRequested(self(p), ctx);
                return P.closeRequested(self(p), ctx, w);
            }
            fn script(p: *anyopaque, step: *Step) anyerror!void {
                return callVoid(P.script, .{ self(p), step });
            }
            const vt: ProgramVTable = .{
                .setup = if (@hasDecl(P, "setup")) setup else null,
                .teardown = if (@hasDecl(P, "teardown")) teardown else null,
                .event = if (@hasDecl(P, "event")) event else null,
                .update = if (@hasDecl(P, "update")) update else null,
                .after_frame = if (@hasDecl(P, "afterFrame")) afterFrame else null,
                .close_requested = if (@hasDecl(P, "closeRequested")) closeRequested else null,
                .script = if (@hasDecl(P, "script")) script else null,
            };
        };
        if (@hasDecl(P, "setup")) _ = checkHook(P, "setup", &.{ *P, *Context }, null, void);
        if (@hasDecl(P, "teardown")) _ = checkHook(P, "teardown", &.{ *P, *Context }, null, void);
        if (@hasDecl(P, "event")) _ = checkHook(P, "event", &.{ *P, *Context, Event }, null, bool);
        if (@hasDecl(P, "update")) _ = checkHook(P, "update", &.{ *P, *Context }, null, void);
        if (@hasDecl(P, "afterFrame")) _ = checkHook(P, "afterFrame", &.{ *P, *Context }, null, void);
        if (@hasDecl(P, "closeRequested")) _ = checkHook(P, "closeRequested", &.{ *P, *Context }, *AppWindow, bool);
        if (@hasDecl(P, "script")) _ = checkHook(P, "script", &.{ *P, *Step }, null, void);
        return &S.vt;
    }
};

/// Compile-time check of the hook `T.name`: its parameters are `want`, plus, if `extra` is not
/// null, optionally one more of that type; it returns `ret` (for `void`, an error union of
/// `void` is fine too). Returns how many parameters it has.
fn checkHook(comptime T: type, comptime name: []const u8, comptime want: []const type, comptime extra: ?type, comptime ret: type) usize {
    const F = @TypeOf(@field(T, name));
    if (@typeInfo(F) != .@"fn") @compileError("vass.app: " ++ @typeName(T) ++ "." ++ name ++ " must be a function");
    const info = @typeInfo(F).@"fn";
    const max = want.len + @intFromBool(extra != null);
    if (info.param_types.len < want.len or info.param_types.len > max) badHook(T, name, want, extra, ret);
    inline for (want, 0..) |W, i| {
        if (info.param_types[i] != W) badHook(T, name, want, extra, ret);
    }
    if (info.param_types.len > want.len and info.param_types[want.len] != extra.?) badHook(T, name, want, extra, ret);
    const R = info.return_type.?;
    const ok = R == ret or (ret == void and @typeInfo(R) == .error_union and @typeInfo(R).error_union.payload == void);
    if (!ok) badHook(T, name, want, extra, ret);
    return info.param_types.len;
}

fn badHook(comptime T: type, comptime name: []const u8, comptime want: []const type, comptime extra: ?type, comptime ret: type) noreturn {
    comptime var sig: []const u8 = "";
    inline for (want, 0..) |W, i| sig = sig ++ (if (i > 0) ", " else "") ++ @typeName(W);
    if (extra) |x| sig = sig ++ " [, " ++ @typeName(x) ++ "]";
    @compileError("vass.app: " ++ @typeName(T) ++ "." ++ name ++ " must be `fn (" ++ sig ++ ") " ++ @typeName(ret) ++ "` (where the hook may fail, an error union of it is fine)");
}

inline fn callVoid(comptime f: anytype, args: anytype) anyerror!void {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    if (R == void) {
        @call(.auto, f, args);
    } else {
        try @call(.auto, f, args);
    }
}

/// What a hook gets: the runner's services, for the window the hook is about (if any).
pub const Context = struct {
    runner: *Runner,
    gpa: std.mem.Allocator,
    /// The window of the frame or hook, null for hooks that are not about one window.
    app_window: ?*AppWindow = null,

    /// The platform window of this frame, or of the main window. For a one-window app, its window.
    /// Panics when there is none: only an app whose end policy is `.last_window_closed` or
    /// `.explicit` can have closed every window; it uses `windowOrNull`.
    pub fn window(ctx: *const Context) *platform.Window {
        return ctx.windowOrNull() orelse noWindow("window");
    }

    /// `window`, or null when no window is open.
    pub fn windowOrNull(ctx: *const Context) ?*platform.Window {
        const w = ctx.app_window orelse ctx.runner.mainWindow() orelse return null;
        return w.window;
    }

    /// The `ui.State` of this window (or of the main window): keyboard focus, popups, drags.
    /// Panics when no window is open; see `window`.
    pub fn uiState(ctx: *const Context) *ui_mod.State {
        return ctx.uiStateOrNull() orelse noWindow("uiState");
    }

    /// `uiState`, or null when no window is open.
    pub fn uiStateOrNull(ctx: *const Context) ?*ui_mod.State {
        const w = ctx.app_window orelse ctx.runner.mainWindow() orelse return null;
        return &w.state;
    }

    /// An allocator whose memory lives until the end of the current loop turn: for what one frame
    /// needs (a layout tree, a formatted label). Reset at the start of every turn. A live-resize
    /// frame (see `AppWindow.onResize`) gets other memory, reset at the start of every such
    /// frame, so what a hook got before it was called stays valid.
    pub fn frameAlloc(ctx: *const Context) std.mem.Allocator {
        return ctx.runner.frameAllocator();
    }

    /// Seconds on the loop's clock (the real one, or the fake one of a scripted run): what the
    /// windows' `Input.time` is set to.
    pub fn time(ctx: *const Context) f64 {
        return ctx.runner.now();
    }

    /// Ends the loop: no further frame is drawn (the windows go when `Runner.stop` runs).
    pub fn quit(ctx: *Context) void {
        ctx.runner.quit();
    }

    /// `.on_demand`: draws the next frames (the settle count, two) even though no input came.
    pub fn requestRedraw(ctx: *Context) void {
        ctx.runner.requestRedraw();
    }

    /// `.on_demand`: draws a frame when the clock reaches `t` (seconds, see `time`).
    pub fn redrawAt(ctx: *Context, t: f64) void {
        ctx.runner.redrawAt(t);
    }

    /// `.on_demand`: also draws at least every `ms` milliseconds from now on (null: stop).
    /// For an audio meter or a playback position: set it while the thing runs, clear it after.
    pub fn redrawEvery(ctx: *Context, ms: ?u32) void {
        ctx.runner.opts.redraw_every_ms = ms;
    }

    /// Opens another window; see `Runner.open`.
    pub fn open(ctx: *Context, comptime W: type, w: *W, spec: WindowSpec) !*AppWindow {
        return ctx.runner.open(W, w, spec);
    }

    /// Closes a window as the close button would after `closeRequested` agreed: it is destroyed
    /// at the next point between frames (by `Runner.stop` if its closing ended the loop), so this
    /// is safe from any hook and from a frame, the window's own included.
    pub fn close(ctx: *Context, w: *AppWindow) void {
        ctx.runner.close(w);
    }

    /// The close button of `w`: asks the program's `closeRequested` first.
    pub fn requestClose(ctx: *Context, w: *AppWindow) void {
        ctx.runner.requestClose(w);
    }

    /// The windows that are open (closed ones, not yet destroyed, are in the list too: see
    /// `AppWindow.dead`), as a copy in the frame memory: it stays valid, unchanged, for the
    /// rest of the current turn, whatever windows are opened or closed meanwhile.
    pub fn windows(ctx: *const Context) std.mem.Allocator.Error![]const *AppWindow {
        return ctx.frameAlloc().dupe(*AppWindow, ctx.runner.entries.items);
    }

    pub fn find(ctx: *const Context, window_id: u32) ?*AppWindow {
        return ctx.runner.find(window_id);
    }
};

pub const Result = enum {
    /// Windows were drawn.
    drew,
    /// Nothing was due (`.on_demand`); nothing was drawn.
    idle,
    /// The loop is over.
    ended,
};

fn noWindow(comptime what: []const u8) noreturn {
    @panic("vass.app: Context." ++ what ++ "() was called while no window is open (the app closed every one under End.last_window_closed or End.explicit); use " ++ what ++ "OrNull()");
}

const ProgramBinding = struct { ptr: *anyopaque, vt: *const ProgramVTable };

pub const Runner = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    entries: std.ArrayList(*AppWindow) = .empty,
    program: ?ProgramBinding = null,
    /// Reset at the start of every loop turn; see `Context.frameAlloc`.
    frame_arena: std.heap.ArenaAllocator,
    /// What `Context.frameAlloc` hands out during a live-resize frame; reset by each of them.
    callback_arena: std.heap.ArenaAllocator,
    in_callback: bool = false,
    /// Lives as long as the runner (snapshot file names).
    keep: std.heap.ArenaAllocator,
    /// Loop turns so far.
    iteration: u32 = 0,
    /// The fake clock reads `fake_origin` plus the turns since `fake_origin_turn`, times its step.
    fake_origin: f64 = 0,
    fake_origin_turn: u32 = 0,
    started: bool = false,
    /// False once the loop has been told to end.
    running: bool = false,
    has_dead: bool = false,
    /// `.on_demand`: frames still owed to an event or a request.
    redraw_frames: u32 = 0,
    timer_at: f64 = std.math.inf(f64),
    last_draw: f64 = -std.math.inf(f64),
    /// Turns that drew, and windows drawn (for tests and idle measurements).
    turns_drawn: u64 = 0,
    /// When the next drawn frame is due (`platform.ticksNs` time); null until the first one.
    frame_deadline_ns: ?u64 = null,
    script: ?script_mod.Run = null,

    pub fn init(gpa: std.mem.Allocator, opts: Options) Runner {
        return .{ .gpa = gpa, .opts = opts, .frame_arena = .init(gpa), .callback_arena = .init(gpa), .keep = .init(gpa) };
    }

    /// A runner for a scripted run: `opts` with the scripted run's clock, pacing and hidden windows.
    pub fn initScripted(gpa: std.mem.Allocator, opts: Options, s: script_mod.Options) Runner {
        var r = init(gpa, s.apply(opts));
        r.script = .{ .dir = s.dir };
        return r;
    }

    /// Destroys the windows still open and frees the runner.
    pub fn deinit(r: *Runner) void {
        r.destroyAll();
        r.entries.deinit(r.gpa);
        r.frame_arena.deinit();
        r.callback_arena.deinit();
        r.keep.deinit();
    }

    /// Binds the hooks of `P` (`setup`, `teardown`, `event`, `update`, `afterFrame`,
    /// `closeRequested`, `script`; all optional) to the runner.
    pub fn use(r: *Runner, comptime P: type, p: *P) void {
        r.program = .{ .ptr = p, .vt = ProgramVTable.of(P) };
    }

    // ---- windows ------------------------------------------------------------------------------

    /// Opens a window whose frames `W.frame(w, ui)` build (or `frame(w, ui, ctx)`; also optional:
    /// `theme(w) Theme`, evaluated every frame, and `windowClosed(w, ctx)`, called just before
    /// the window is destroyed, to free what `w` is: at the latest in `stop`, before the program's
    /// `teardown`). `w` must outlive the window. Safe from any
    /// hook and from a frame; a window opened during a loop turn is first drawn in the next one.
    pub fn open(r: *Runner, comptime W: type, w: *W, spec: WindowSpec) !*AppWindow {
        const vt = WindowVTable.of(W);
        var o = spec.window;
        if (r.opts.hide_windows) o.hidden = true;
        const e = try r.gpa.create(AppWindow);
        errdefer r.gpa.destroy(e);
        const win = try platform.Window.create(r.gpa, o);
        errdefer win.destroy();
        e.* = .{
            .runner = r,
            .window = win,
            .list = gfx.DisplayList.init(r.gpa),
            .user = w,
            .vt = vt,
            .theme = spec.theme,
            .background = spec.background,
            .draw_order = spec.draw_order,
            .main = spec.main or r.entries.items.len == 0,
        };
        errdefer e.list.deinit();
        try r.entries.append(r.gpa, e);
        // A window marked main takes the role from the one that had it by being first.
        if (spec.main) for (r.entries.items) |other| {
            other.main = other == e;
        };
        // `e` has its final address now.
        if (o.resizable) win.setFrameCallback(e, AppWindow.onResize);
        if (spec.text_input) win.startTextInput();
        r.redraw_frames = @max(r.redraw_frames, r.opts.settle_frames);
        return e;
    }

    pub fn find(r: *const Runner, window_id: u32) ?*AppWindow {
        for (r.entries.items) |e| if (!e.dead and e.id() == window_id) return e;
        return null;
    }

    /// The window `End.main_window_closed` watches. After it was closed it is still the main window
    /// until it is destroyed (that is when the closing ended the loop, and `teardown` runs).
    /// Null when no window is left (possible under `End.last_window_closed` and `End.explicit`).
    pub fn mainWindow(r: *const Runner) ?*AppWindow {
        for (r.entries.items) |e| if (e.main and !e.dead) return e;
        for (r.entries.items) |e| if (e.main) return e;
        return if (r.entries.items.len > 0) r.entries.items[0] else null;
    }

    pub fn close(r: *Runner, w: *AppWindow) void {
        if (w.dead) return;
        w.dead = true;
        r.has_dead = true;
    }

    pub fn requestClose(r: *Runner, w: *AppWindow) void {
        if (w.dead) return;
        if (r.program) |p| if (p.vt.close_requested) |f| {
            var ctx = r.context(w);
            if (!f(p.ptr, &ctx, w)) return;
        };
        r.close(w);
    }

    pub fn context(r: *Runner, w: ?*AppWindow) Context {
        return .{ .runner = r, .gpa = r.gpa, .app_window = w };
    }

    fn destroy(r: *Runner, i: usize) void {
        const e = r.entries.items[i];
        e.notifyClosed();
        // The hook may have opened or closed windows: find `e` again.
        const at = std.mem.indexOfScalar(*AppWindow, r.entries.items, e).?;
        _ = r.entries.orderedRemove(at);
        e.window.destroy(); // unregisters its live-resize callback
        e.list.deinit();
        r.gpa.destroy(e);
    }

    /// Destroys the closed windows (last opened first) and applies the end policy. When the policy
    /// says the loop is over nothing is destroyed: `stop` does it, after `teardown`.
    fn reap(r: *Runner) void {
        if (!r.has_dead) return;
        var main_closed = false;
        var alive: usize = 0;
        for (r.entries.items) |e| {
            if (e.dead and e.main) main_closed = true;
            if (!e.dead) alive += 1;
        }
        const over = switch (r.opts.end) {
            .main_window_closed => main_closed,
            .last_window_closed => alive == 0,
            .explicit => false,
        };
        if (over) {
            r.running = false;
            return;
        }
        r.has_dead = false;
        var i = r.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (i < r.entries.items.len and r.entries.items[i].dead) r.destroy(i);
        }
    }

    /// Every window's `windowClosed` hook, last opened first, while all of them still exist.
    fn notifyAll(r: *Runner) void {
        var i = r.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (i < r.entries.items.len) r.entries.items[i].notifyClosed();
        }
    }

    fn destroyAll(r: *Runner) void {
        r.notifyAll();
        while (r.entries.items.len > 0) r.destroy(r.entries.items.len - 1);
    }

    // ---- clock and requests -------------------------------------------------------------------

    pub fn now(r: *const Runner) f64 {
        return switch (r.opts.clock) {
            .real => @as(f64, @floatFromInt(platform.ticks())) / 1000.0,
            // From the count of turns, not by adding the step every turn: no rounding drift.
            .fake => |step| r.fake_origin + @as(f64, @floatFromInt(r.iteration - r.fake_origin_turn)) * step,
        };
    }

    /// Sets the fake clock to `t` now; it goes on advancing by its step per turn from there (a
    /// no-op for the real one).
    pub fn setTime(r: *Runner, t: f64) void {
        r.fake_origin = t;
        r.fake_origin_turn = r.iteration;
    }

    pub fn quit(r: *Runner) void {
        r.running = false;
    }

    /// The memory `Context.frameAlloc` hands out now.
    fn frameAllocator(r: *Runner) std.mem.Allocator {
        return (if (r.in_callback) &r.callback_arena else &r.frame_arena).allocator();
    }

    /// Draws at least one frame this turn (a script's `save` and `done` need it: a frame is where
    /// they take effect).
    pub fn requestFrame(r: *Runner) void {
        r.redraw_frames = @max(r.redraw_frames, 1);
    }

    pub fn requestRedraw(r: *Runner) void {
        r.redraw_frames = @max(r.redraw_frames, r.opts.settle_frames);
    }

    pub fn redrawAt(r: *Runner, t: f64) void {
        r.timer_at = @min(r.timer_at, t);
    }

    /// Makes a loop that waits for events draw: callable from any thread (a worker that finished
    /// something). Nothing is drawn if the loop is not waiting; the next turn will see the
    /// changed data.
    pub fn wake() void {
        platform.wakeEventLoop();
    }

    // ---- the loop ------------------------------------------------------------------------------

    /// Starts the loop: the program's `setup` hook (it may open the windows). If it fails the
    /// windows are closed and destroyed (`teardown` is not called: `setup` cleans up what it did
    /// itself) and the error is returned.
    pub fn start(r: *Runner) !void {
        r.started = true;
        r.running = true;
        r.redraw_frames = r.opts.settle_frames;
        if (r.program) |p| if (p.vt.setup) |f| {
            var ctx = r.context(null);
            f(p.ptr, &ctx) catch |e| {
                r.started = false;
                r.running = false;
                r.destroyAll();
                return e;
            };
        };
    }

    /// Ends the loop, however it ended (a close, a quit, an error): every window's `windowClosed`
    /// hook (last opened first), the program's `teardown` hook, then the windows are destroyed.
    /// So until `teardown` returns, the windows, the main one included, are all still there.
    pub fn stop(r: *Runner) void {
        if (!r.started) return;
        r.started = false;
        r.running = false;
        r.notifyAll();
        if (r.program) |p| if (p.vt.teardown) |f| {
            var ctx = r.context(null);
            f(p.ptr, &ctx);
        };
        r.destroyAll();
    }

    /// `start`, loop until the end policy, a quit or a scripted run says stop, `stop`.
    pub fn run(r: *Runner) !void {
        try r.start();
        defer r.stop();
        while (true) {
            if (r.opts.max_iterations) |m| if (r.iteration >= m) return error.TooManyFrames;
            if (try r.iterate() == .ended) break;
        }
    }

    /// Whether the on-demand policy owes a frame at time `t`.
    fn due(r: *const Runner, t: f64) bool {
        if (r.redraw_frames > 0 or r.timer_at <= t) return true;
        if (r.opts.redraw_every_ms) |ms| if (t - r.last_draw >= @as(f64, @floatFromInt(ms)) / 1000.0) return true;
        for (r.entries.items) |e| {
            if (e.dead or e.paused) continue;
            if (e.state.wantsFrame(t)) return true;
        }
        return false;
    }

    /// Milliseconds until something is due (null: never, wait for an event).
    fn waitMs(r: *const Runner, t: f64) ?u32 {
        var at = r.timer_at;
        if (r.opts.redraw_every_ms) |ms| at = @min(at, r.last_draw + @as(f64, @floatFromInt(ms)) / 1000.0);
        for (r.entries.items) |e| {
            if (e.dead or e.paused) continue;
            at = @min(at, e.state.redraw.at);
        }
        if (!std.math.isFinite(at)) return null;
        const ms = @ceil((at - t) * 1000.0);
        return if (ms < 1) 1 else if (ms > 1e9) 1_000_000_000 else @intFromFloat(ms);
    }

    /// Feeds `ev` as if the platform had delivered it: the program's `event` hook, which may
    /// consume it, then the default handling (`quit`, close requests) or every window's `Input`.
    /// Scripts use it to inject input; it is also what the loop does with each OS event.
    pub fn dispatch(r: *Runner, ev: Event) void {
        r.requestRedraw();
        var ctx = r.context(null);
        if (r.program) |p| if (p.vt.event) |f| {
            if (f(p.ptr, &ctx, ev)) return;
        };
        switch (ev) {
            .quit => r.running = false,
            .close_requested => |id| if (r.find(id)) |e| r.requestClose(e),
            else => for (r.entries.items) |e| {
                if (!e.dead) e.input.feed(ev, e.id());
            },
        }
    }

    fn pump(r: *Runner) void {
        while (platform.pollEvent()) |ev| {
            if (r.opts.ignore_os_input) switch (ev) {
                .quit, .close_requested => {},
                else => continue,
            };
            r.dispatch(ev);
        }
    }

    /// One turn of the loop (see the top of the file). In `.on_demand` with the real clock it
    /// blocks until something is due or an event comes; with a fake clock it never blocks and
    /// returns `.idle` when nothing is due. Once the loop was told to end it returns `.ended`
    /// without drawing or calling `afterFrame`. Call `start` first.
    pub fn iterate(r: *Runner) !Result {
        std.debug.assert(r.started);
        if (!r.running) return .ended;
        const real = r.opts.clock == .real;
        var woke = false;
        if (r.opts.redraw == .on_demand and real and r.script == null and !r.due(r.now())) {
            woke = platform.waitEvent(r.waitMs(r.now()));
        }
        const frame_start_ns = if (real) platform.ticksNs() else 0;
        _ = r.frame_arena.reset(.retain_capacity);
        const t = r.now();
        r.pump();
        if (woke) r.requestRedraw();
        for (r.entries.items) |e| e.input.time = t;

        if (r.program) |p| if (p.vt.update) |f| {
            var ctx = r.context(null);
            try f(p.ptr, &ctx);
        };
        if (r.script) |*sc| {
            try r.runScript(sc);
            if (sc.halt) r.running = false;
        }
        r.reap();
        defer r.endTurn();
        if (!r.running) return .ended;

        const draw_now = r.opts.redraw == .always or r.due(t);
        var drew = false;
        if (draw_now) {
            try r.drawAll();
            if (!r.running) return .ended;
            drew = true;
            r.turns_drawn += 1;
            r.last_draw = t;
            if (r.redraw_frames > 0) r.redraw_frames -= 1;
            if (r.timer_at <= t) r.timer_at = std.math.inf(f64);
            for (r.entries.items) |e| e.input.endFrame();
            if (r.program) |p| if (p.vt.after_frame) |f| {
                var ctx = r.context(null);
                try f(p.ptr, &ctx);
            };
            if (r.script) |*sc| if (sc.finish) {
                r.running = false;
            };
            r.reap();
            if (!r.running) return .ended;
            if (r.opts.frame_ms > 0) {
                if (real and r.script == null) {
                    // Vsync is off (windows would block in present one after another), so pace here.
                    const p = pace(r.frame_deadline_ns, frame_start_ns, platform.ticksNs(), @as(u64, r.opts.frame_ms) * std.time.ns_per_ms);
                    r.frame_deadline_ns = p.deadline;
                    if (p.sleep_ns > 0) platform.sleepNs(p.sleep_ns);
                } else {
                    platform.sleepMs(r.opts.frame_ms);
                }
            }
        }
        return if (drew) .drew else .idle;
    }

    fn endTurn(r: *Runner) void {
        r.iteration += 1;
    }

    fn drawAll(r: *Runner) !void {
        const n = r.entries.items.len;
        const list = try r.frame_arena.allocator().dupe(*AppWindow, r.entries.items[0..n]);
        std.sort.insertion(*AppWindow, list, {}, struct {
            fn lt(_: void, a: *AppWindow, b: *AppWindow) bool {
                return a.draw_order < b.draw_order;
            }
        }.lt);
        for (list) |e| {
            // A frame that quit the loop is the last one.
            if (!r.running) return;
            if (e.dead or e.paused) continue;
            try e.draw(e.input);
        }
    }

    fn runScript(r: *Runner, sc: *script_mod.Run) !void {
        sc.saved = false;
        sc.flushPending(r);
        const p = r.program orelse return;
        const f = p.vt.script orelse return;
        var step = Step.make(r, sc);
        try f(p.ptr, &step);
    }
};
