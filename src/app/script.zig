//! Deterministic runs: the same loop as a live run, driven by a script instead of a person.
//!
//! A scripted run (`Config.script`, or `Runner.script`) opens its windows hidden, uses a fake
//! clock that is a fixed step times the loop turns so far, ignores the real mouse and keyboard, and calls
//! the program's `script(app, step: *Step) !void` hook once per turn, after `update` and before
//! the frame. The hook injects input with the `Step` methods (they go through
//! `Runner.dispatch`, exactly as OS events do, so the program's `event` hook and `Input.feed`
//! see them), asks for a snapshot with `save`, and ends the run with `done` or `stop`:
//!
//!     pub fn script(app: *App, s: *vass.app.Step) !void {
//!         switch (s.n) {
//!             3 => s.click(120, 40),
//!             5 => s.text("hello"),
//!             8 => try s.save("typed", .{}),
//!             9 => s.done(),
//!             else => {},
//!         }
//!     }
//!
//! Because it is the live loop, code that only runs in the live app (an `update` that polls, the
//! live-resize callback aside) runs here too.
const std = @import("std");
const platform = @import("../platform/backend_sdl.zig");
const ui_mod = @import("../ui/ui.zig");
const runner_mod = @import("runner.zig");
const keys = @import("../core/keys.zig");

const Runner = runner_mod.Runner;
const AppWindow = runner_mod.AppWindow;
const Event = platform.Event;

/// The settings of a scripted run (`Config.script`, `Runner.initScripted`).
pub const Options = struct {
    /// Where `Step.save` writes `<name>.bmp`; null skips the saves.
    dir: ?[]const u8 = null,
    /// Seconds the fake clock advances per loop turn (0: it stays at 0).
    clock_step: f64 = 0,
    /// Use the real clock instead of the fake one.
    real_clock: bool = false,
    /// Pause after every frame, in milliseconds.
    sleep_ms: u32 = 16,
    /// Show the windows (for taking a screenshot from outside) instead of hiding them.
    hold: bool = false,
    /// Let the real mouse and keyboard through to the windows.
    os_input: bool = false,
    /// The run fails with `error.TooManyFrames` after this many loop turns.
    max_frames: u32 = 100_000,

    /// `base` with the clock, pacing, window visibility and input of a scripted run.
    pub fn apply(s: Options, base: runner_mod.Options) runner_mod.Options {
        var o = base;
        o.clock = if (s.real_clock) .real else .{ .fake = s.clock_step };
        o.frame_ms = s.sleep_ms;
        o.hide_windows = !s.hold;
        o.ignore_os_input = !s.os_input;
        o.max_iterations = s.max_frames;
        return o;
    }
};

/// The state of a scripted run, in the runner.
pub const Run = struct {
    /// Where `Step.save` writes `<name>.bmp` (null: saves are skipped).
    dir: ?[]const u8 = null,
    /// Set by `Step.done`: end after this turn's frame has been drawn.
    finish: bool = false,
    /// Set by `Step.stop`: end now, without drawing this frame.
    halt: bool = false,
    /// `Step.save` was called this turn.
    saved: bool = false,
    /// The release of a `Step.click`, injected at the start of the next turn.
    release: ?struct { window: u32, x: f32, y: f32 } = null,

    pub fn flushPending(sc: *Run, r: *Runner) void {
        if (sc.release) |rel| {
            sc.release = null;
            r.dispatch(.{ .mouse_up = .{ .window = rel.window, .x = rel.x, .y = rel.y, .button = 1 } });
        }
    }
};

/// What the program's `script` hook works with: this turn of the loop, and injectors for the
/// window it targets (the main window; `to` picks another).
pub const Step = struct {
    runner: *Runner,
    run: *Run,
    /// Loop turn, from 0.
    n: u32,
    /// The loop's clock (a fake one in a scripted run).
    time: f64,
    /// Null when no window is open (every one was closed under `End.explicit` or
    /// `End.last_window_closed`): injected input then goes nowhere.
    target: ?*AppWindow,

    pub fn make(r: *Runner, run: *Run) Step {
        return .{ .runner = r, .run = run, .n = r.iteration, .time = r.now(), .target = r.mainWindow() };
    }

    fn targetWindow(s: Step) *AppWindow {
        return s.target orelse @panic("vass.app: Step has no window to work on: every window is closed (aim the step at one with `to`)");
    }

    /// The same step aimed at another window.
    pub fn to(s: Step, w: *AppWindow) Step {
        var c = s;
        c.target = w;
        return c;
    }

    /// True on turn `n`.
    pub fn at(s: Step, n: u32) bool {
        return s.n == n;
    }

    /// Panics when there is no target window; so do `input` and `state`.
    pub fn window(s: Step) *platform.Window {
        return s.targetWindow().window;
    }

    /// The target's `Input`, for scripts that set its fields directly (it is the one the frame is
    /// drawn with; if a script replaces the whole value, set `time` again).
    pub fn input(s: Step) *ui_mod.Input {
        return &s.targetWindow().input;
    }

    pub fn state(s: Step) *ui_mod.State {
        return &s.targetWindow().state;
    }

    fn dispatch(s: Step, ev: Event) void {
        s.runner.dispatch(ev);
    }

    /// 0, the id of no window, without a target.
    fn wid(s: Step) u32 {
        return if (s.target) |t| t.id() else 0;
    }

    // ---- injecting input -----------------------------------------------------------------------

    pub fn move(s: Step, x: f32, y: f32) void {
        s.dispatch(.{ .mouse_move = .{ .window = s.wid(), .x = x, .y = y } });
    }

    /// The pointer leaves the window.
    pub fn leave(s: Step) void {
        s.dispatch(.{ .mouse_leave = s.wid() });
    }

    /// Left button down at (`x`,`y`); `clicks` is the OS's count (1 single, 2 double, 3 triple).
    pub fn pressClicks(s: Step, x: f32, y: f32, count: u8) void {
        s.dispatch(.{ .mouse_down = .{ .window = s.wid(), .x = x, .y = y, .button = 1, .clicks = count } });
    }

    pub fn press(s: Step, x: f32, y: f32) void {
        s.pressClicks(x, y, 1);
    }

    pub fn release(s: Step, x: f32, y: f32) void {
        s.dispatch(.{ .mouse_up = .{ .window = s.wid(), .x = x, .y = y, .button = 1 } });
    }

    /// Right button down.
    pub fn rightPress(s: Step, x: f32, y: f32) void {
        s.dispatch(.{ .mouse_down = .{ .window = s.wid(), .x = x, .y = y, .button = 3 } });
    }

    /// A click: down now, up at the start of the next turn (a click is one frame wide for the
    /// widgets, and the release must not share the press's frame).
    pub fn click(s: Step, x: f32, y: f32) void {
        s.multiClick(x, y, 1);
    }

    /// A double (2) or triple (3) click, as one press with that OS click count.
    pub fn multiClick(s: Step, x: f32, y: f32, count: u8) void {
        s.pressClicks(x, y, count);
        s.run.release = .{ .window = s.wid(), .x = x, .y = y };
    }

    /// Scroll in lines (positive `dy`: towards the start of the content).
    pub fn wheel(s: Step, dx: f32, dy: f32) void {
        s.dispatch(.{ .mouse_wheel = .{ .window = s.wid(), .dx = dx, .dy = dy } });
    }

    pub fn key(s: Step, code: u32, mods: keys.Mods) void {
        s.dispatch(.{ .key_down = .{ .code = code, .mods = mods, .window = s.wid() } });
    }

    pub fn keyUp(s: Step, code: u32, mods: keys.Mods) void {
        s.dispatch(.{ .key_up = .{ .code = code, .mods = mods, .window = s.wid() } });
    }

    /// Typed text (split into the chunks the platform delivers).
    pub fn text(s: Step, str: []const u8) void {
        var i: usize = 0;
        while (i < str.len) {
            const end = platform.textChunkEnd(str, i);
            s.dispatch(.{ .text_input = .{ .window = s.wid(), .text = platform.TextChunk.from(str[i..end]) } });
            i = end;
        }
    }

    /// An input-method composition in progress (`""`: it ended); `start` and `length` are the
    /// cursor and the highlighted run in code points.
    pub fn compose(s: Step, str: []const u8, start: i32, length: i32) void {
        var comp: platform.Composition = .{ .start = start, .length = length };
        const n = @min(str.len, comp.buf.len);
        @memcpy(comp.buf[0..n], str[0..n]);
        comp.len = @intCast(n);
        s.dispatch(.{ .text_editing = .{ .window = s.wid(), .comp = comp } });
    }

    /// The window gains or loses keyboard focus.
    pub fn focus(s: Step, gained: bool) void {
        s.dispatch(if (gained) .{ .focus_gained = s.wid() } else .{ .focus_lost = s.wid() });
    }

    /// A file dragged in from another app and dropped at (`x`,`y`): begin, position, file, complete.
    pub fn dropFile(s: Step, x: f32, y: f32, path: []const u8) void {
        s.dispatch(.{ .drop_begin = s.wid() });
        s.dispatch(.{ .drop_position = .{ .window = s.wid(), .x = x, .y = y } });
        if (platform.DropPath.from(path)) |p| s.dispatch(.{ .file_drop = .{ .window = s.wid(), .x = x, .y = y, .path = p } });
        s.dispatch(.{ .drop_complete = s.wid() });
    }

    /// Any event, for what the methods above do not cover.
    pub fn inject(s: Step, ev: Event) void {
        s.dispatch(ev);
    }

    // ---- results ---------------------------------------------------------------------------------

    /// Saves the frame drawn this turn, of the target window, as `<dir>/<name>.bmp`, `name` being
    /// `fmt` filled in with `args`. Asks for a frame this turn (an on-demand run draws nothing
    /// otherwise). Does nothing when the run has no directory or no window is open.
    pub fn save(s: Step, comptime fmt: []const u8, args: anytype) !void {
        const dir = s.run.dir orelse return;
        const t = s.target orelse return;
        t.window.snapshot_path = try std.fmt.allocPrintSentinel(s.runner.keep.allocator(), "{s}/" ++ fmt ++ ".bmp", .{dir} ++ args, 0);
        s.run.saved = true;
        s.runner.requestFrame();
    }

    /// Ends the run after this turn's frame has been drawn (the turn draws even in an on-demand run).
    pub fn done(s: Step) void {
        s.run.finish = true;
        s.runner.requestFrame();
    }

    /// Ends the run now, without drawing this turn.
    pub fn stop(s: Step) void {
        s.run.halt = true;
    }
};
