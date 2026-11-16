//! The plumbing every example repeats, in one place: command line, window setup, the frame loop,
//! the live-resize callback and snapshot files. An example then reads as "state + `frame(app, ui)`":
//!
//!     pub fn main(init: std.process.Init) !void {
//!         const env = try harness.start(init, "split", .{}) orelse return;
//!         var app: App = .{};
//!         try harness.run(@This(), env, .{ .window = .{ .title = "Split", .width = 800, .height = 600 } }, &app);
//!     }
//!     pub fn frame(app: *App, ui: *Ui) void { ... }
//!
//! `run` takes the example's own file (`@This()`) as the hook namespace, so the hooks are plain
//! top-level `pub fn`s of the example, found by name:
//!
//!   * `frame(app: *App, ui: *Ui) void | !void` (required): builds one frame of UI. `App` is the
//!     example's state struct, which must have a `state: vass.ui.State` field (the Ui's keyboard
//!     focus, drags and so on). Call `ui.finish()` at the end if the example has popups.
//!   * `setup(app: *App, win: *Window) !void`: once, after the window exists (load images, sounds).
//!   * `teardown(app: *App, win: *Window) void`: once, before the window is destroyed.
//!   * `event(app: *App, s: *Step, ev: Event) void`: every event that is about to be fed to the
//!     input (not called while a snapshot or script run ignores the real mouse and keyboard).
//!   * `step(app: *App, s: *Step) !void`: once per loop iteration, after the events and before the
//!     frame is drawn. Scripted runs push synthetic input into `s.input` and name snapshots here.
//!   * `after(app: *App, s: *Step) !void`: once per iteration, after the frame was drawn.
//!
//! Without a `step`, a snapshot run draws `Config.snapshot_frame` frames, saves `DIR/<name>.bmp`
//! and exits. Snapshot runs use a hidden window (`--hold` shows it) and a fake clock, so the
//! images are reproducible.
const std = @import("std");
const vass = @import("vass");

const Ui = vass.Ui;
const ui_mod = vass.ui;
pub const Window = vass.platform.Window;

/// What the command line asked for.
pub const Cli = struct {
    /// `--snapshot DIR`: write BMPs into DIR (the window is hidden) and exit.
    snapshot_dir: ?[]const u8 = null,
    /// `--hold`: keep the window visible during a snapshot run.
    hold: bool = false,
    /// `--script` (only for examples that accept it).
    script: bool = false,
    /// `--debug-input` (only for examples that accept it).
    debug_input: bool = false,

    /// Extra flags an example accepts besides `--snapshot DIR` and `--hold`.
    pub const Accept = struct { script: bool = false, debug_input: bool = false };

    pub fn snapshot(c: Cli) bool {
        return c.snapshot_dir != null;
    }
};

/// The process-level things `main` needs: allocators and the parsed command line.
pub const Env = struct {
    /// Leak-checked in debug builds by the runtime.
    gpa: std.mem.Allocator,
    /// Lives until the process exits; snapshot paths are allocated from it.
    arena: std.mem.Allocator,
    cli: Cli,
    /// The example's name, the default stem of its snapshot file.
    name: []const u8,
};

/// Reads the arguments. Prints the usage line and returns null for anything unknown (`main` then
/// just returns).
pub fn start(init: std.process.Init, comptime name: []const u8, comptime accept: Cli.Accept) !?Env {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var cli: Cli = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--snapshot") and i + 1 < args.len) {
            i += 1;
            cli.snapshot_dir = args[i];
        } else if (std.mem.eql(u8, a, "--hold")) {
            cli.hold = true;
        } else if (accept.script and std.mem.eql(u8, a, "--script")) {
            cli.script = true;
        } else if (accept.debug_input and std.mem.eql(u8, a, "--debug-input")) {
            cli.debug_input = true;
        } else {
            std.debug.print("usage: " ++ name ++ " [--snapshot DIR]" ++
                (if (accept.script) " [--script]" else "") ++
                (if (accept.debug_input) " [--debug-input]" else "") ++
                " [--hold]\n", .{});
            return null;
        }
    }
    return .{ .gpa = init.gpa, .arena = arena, .cli = cli, .name = name };
}

pub const Config = struct {
    /// The window. `hidden` is set by `run` (hidden in a snapshot run unless `--hold`).
    window: vass.platform.WindowOptions,
    /// Start the input method (text fields and areas need it).
    text_input: bool = false,
    theme: ui_mod.Theme = .{ .card_radius = 12 },
    /// The frame at which a snapshot run saves `DIR/<snapshot_name>.bmp` and ends. Null: the
    /// example's `step` names the snapshots and ends the run itself.
    snapshot_frame: ?u32 = 3,
    /// Stem of the default snapshot file; null is the example's name.
    snapshot_name: ?[]const u8 = null,
    /// Seconds the fake clock advances per frame (it is used in snapshot runs).
    snapshot_clock_step: f64 = 0,
    /// Use the fake clock (true) or the real one (false). Null: fake in snapshot runs.
    fixed_clock: ?bool = null,
    /// Feed the real mouse and keyboard to the input. Null: yes unless this is a snapshot run.
    feed_input: ?bool = null,
    /// Pause after each frame while snapshotting; live runs always wait 16 ms.
    snapshot_sleep_ms: u32 = 16,
};

/// What `step`, `event` and `after` get to work with: this iteration of the loop.
pub const Step = struct {
    env: Env,
    /// Frame number, from 0.
    n: u32,
    win: *Window,
    /// The input the frame is drawn with (a scripted run writes its synthetic input here). If a
    /// script replaces the whole value, set `time` again.
    input: *ui_mod.Input,
    /// The clock of this frame: the fake one in snapshot runs, else the real one. Already in `input.time`.
    time: f64,
    list: *vass.DisplayList,
    theme: ui_mod.Theme,
    /// A snapshot was requested for this frame (it is written by the draw).
    saved: bool = false,
    finish: bool = false,
    halt: bool = false,

    /// Saves this frame as `DIR/<stem>.bmp`, the stem being `fmt` filled in with `args`.
    pub fn save(s: *Step, comptime fmt: []const u8, args: anytype) !void {
        const dir = s.env.cli.snapshot_dir orelse return;
        s.win.snapshot_path = try std.fmt.allocPrintSentinel(s.env.arena, "{s}/" ++ fmt ++ ".bmp", .{dir} ++ args, 0);
        s.saved = true;
    }

    /// Ends the run after this frame has been drawn.
    pub fn done(s: *Step) void {
        s.finish = true;
    }

    /// Ends the run now, without drawing this frame.
    pub fn stop(s: *Step) void {
        s.halt = true;
    }

    /// A Ui over the current input without any state, for measuring text before the real frame.
    pub fn measureUi(s: *Step) Ui {
        return Ui.init(s.list, s.win, s.input.*, s.theme);
    }
};

/// Runs `app` in a window until it is closed, or, in a snapshot run, until the snapshots are
/// written. Call it again with another `cfg` to run the same state in another window (a second size).
pub fn run(comptime Ex: type, env: Env, cfg: Config, app: anytype) !void {
    const App = @TypeOf(app.*);
    const snapshot = env.cli.snapshot();
    const gpa = env.gpa;

    var opts = cfg.window;
    opts.hidden = snapshot and !env.cli.hold;
    var win = try Window.init(gpa, opts);
    defer win.deinit();
    if (cfg.text_input) win.startTextInput();
    if (@hasDecl(Ex, "setup")) try Ex.setup(app, &win);
    defer if (@hasDecl(Ex, "teardown")) Ex.teardown(app, &win);
    var list = vass.DisplayList.init(gpa);
    defer list.deinit();

    var input: ui_mod.Input = .{};
    const L = Live(Ex, App);
    var live: L = .{ .app = app, .win = &win, .list = &list, .input = &input, .theme = cfg.theme };
    // Redraw while the OS live-resizes the window (the loop below is blocked then).
    win.setFrameCallback(&live, L.onResize);

    const feed = cfg.feed_input orelse !snapshot;
    const fixed_clock = cfg.fixed_clock orelse snapshot;
    var n: u32 = 0;
    var running = true;
    while (running) : (n += 1) {
        const time: f64 = if (fixed_clock)
            @as(f64, @floatFromInt(n)) * cfg.snapshot_clock_step
        else
            @as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0;
        var step: Step = .{ .env = env, .n = n, .win = &win, .input = &input, .time = time, .list = &list, .theme = cfg.theme };

        while (vass.platform.pollEvent()) |ev| switch (ev) {
            .quit, .close_requested => running = false,
            else => if (feed) {
                if (@hasDecl(Ex, "event")) Ex.event(app, &step, ev);
                input.feed(ev, win.id());
            },
        };
        input.time = time;

        if (@hasDecl(Ex, "step")) try Ex.step(app, &step);
        if (snapshot) if (cfg.snapshot_frame) |f| if (n == f) {
            try step.save("{s}", .{cfg.snapshot_name orelse env.name});
            step.done();
        };
        if (step.halt) break;

        try live.draw(input);
        if (@hasDecl(Ex, "after")) try Ex.after(app, &step);
        if (step.finish) running = false;

        // The Ui worked on a copy of the input; keep what it consumed.
        input.endFrame();
        vass.platform.sleepMs(if (snapshot) cfg.snapshot_sleep_ms else 16);
    }
}

/// Everything one frame needs, so the main loop and the resize callback draw the same way.
fn Live(comptime Ex: type, comptime App: type) type {
    return struct {
        app: *App,
        win: *Window,
        list: *vass.DisplayList,
        input: *ui_mod.Input,
        theme: ui_mod.Theme,

        fn draw(l: *@This(), in: ui_mod.Input) !void {
            l.list.reset();
            var ui = Ui.init(l.list, l.win, in, l.theme);
            ui.state = &l.app.state;
            const R = @typeInfo(@TypeOf(Ex.frame)).@"fn".return_type.?;
            if (comptime @typeInfo(R) == .error_union) try Ex.frame(l.app, &ui) else Ex.frame(l.app, &ui);
            l.win.render(l.list, l.theme.bg);
        }

        /// Called by the window while it is being resized: an idle frame, so no click or key is
        /// replayed and `input.time` (hence animations) stays where the last real frame left it.
        fn onResize(ctx: ?*anyopaque) void {
            const l: *@This() = @ptrCast(@alignCast(ctx.?));
            l.draw(l.input.idle()) catch |e| std.log.warn("resize frame failed: {s}", .{@errorName(e)});
        }
    };
}
