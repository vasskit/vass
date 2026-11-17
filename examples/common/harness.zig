//! What the examples share beyond the toolkit's own loop (`vass.app`): the command line and the
//! mapping from the example's hooks to a live or a snapshot run. An example then reads as "state
//! + `frame(app, ui)`":
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
//!   * `frame(app: *App, ui: *Ui) void | !void` (required): builds one frame of UI. The loop keeps
//!     the Ui's state (focus, popups) and calls `ui.finish()` itself; read the state as `ui.state`.
//!   * `setup(app: *App, win: *Window) !void`: once, after the window exists (load images, sounds).
//!   * `teardown(app: *App, win: *Window) void`: once, when the run ends however it ends (the close
//!     button, Cmd+Q, the end of a snapshot run, an error); the window is destroyed after it returns.
//!     Not called if `setup` failed: `setup` cleans up after itself.
//!   * `event(app: *App, s: *Step, ev: Event) void`: every event that is about to be fed to the
//!     input (not called while a snapshot or script run ignores the real mouse and keyboard).
//!   * `step(app: *App, s: *Step) !void`: once per loop iteration, after the events and before the
//!     frame is drawn. Scripted runs push synthetic input into `s.input` and name snapshots here.
//!   * `after(app: *App, s: *Step) !void`: once per iteration, after the frame was drawn.
//!
//! Without a `step`, a snapshot run draws `Config.snapshot_frame` frames, saves `DIR/<name>.bmp`
//! and exits. Snapshot runs use a hidden window (`--hold` shows it) and a fake clock, so the
//! images are reproducible. They are `vass.app` scripted runs: the same loop as a live run.
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
    /// Lives until the process exits.
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
    /// The window. `hidden` is set by the loop (hidden in a snapshot run unless `--hold`).
    window: vass.platform.WindowOptions,
    /// Start the input method (text fields and areas need it).
    text_input: bool = false,
    theme: ui_mod.Theme = .{ .card_radius = 12 },
    /// What the frame is cleared with; null is `theme.bg`. Alpha 0 lets a vibrancy view show.
    background: ?vass.Color = null,
    /// The frame at which a snapshot run saves `DIR/<snapshot_name>.bmp` and ends. Null: the
    /// example's `step` names the snapshots and ends the run itself.
    snapshot_frame: ?u32 = 3,
    /// Stem of the default snapshot file; null is the example's name.
    snapshot_name: ?[]const u8 = null,
    /// Seconds the fake clock advances per frame (it is used in snapshot runs).
    snapshot_clock_step: f64 = 0,
    /// Use the fake clock (true) or the real one (false) in a snapshot run. Null: fake.
    fixed_clock: ?bool = null,
    /// Feed the real mouse and keyboard to the input in a snapshot run. Null: no.
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
    /// The Ui's state: keyboard focus, drags, popups.
    state: *ui_mod.State,
    /// A snapshot was requested for this frame (it is written by the draw).
    saved: bool = false,
    /// The scripted run's step (null in a live run).
    core: ?vass.app.Step = null,

    /// Saves this frame as `DIR/<stem>.bmp`, the stem being `fmt` filled in with `args`.
    pub fn save(s: *Step, comptime fmt: []const u8, args: anytype) !void {
        const core = s.core orelse return;
        try core.save(fmt, args);
        s.saved = true;
    }

    /// Ends the run after this frame has been drawn.
    pub fn done(s: *Step) void {
        if (s.core) |core| core.done();
    }

    /// Ends the run now, without drawing this frame.
    pub fn stop(s: *Step) void {
        if (s.core) |core| core.stop();
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
    const Host = struct {
        const Self = @This();
        app: *App,
        env: Env,
        cfg: Config,
        scripted: bool,

        fn makeStep(h: *Self, ctx: *vass.app.Context, core: ?vass.app.Step) Step {
            // The loop ends when the main window is closed and keeps every window until `teardown`
            // has returned, so every hook finds it.
            const w = ctx.runner.mainWindow().?;
            return .{
                .env = h.env,
                .n = ctx.runner.iteration,
                .win = w.window,
                .input = &w.input,
                .time = ctx.time(),
                .list = &w.list,
                .theme = h.cfg.theme,
                .state = &w.state,
                .saved = if (ctx.runner.script) |sc| sc.saved else false,
                .core = core,
            };
        }

        pub fn frame(h: *Self, ui: *Ui) !void {
            const R = @typeInfo(@TypeOf(Ex.frame)).@"fn".return_type.?;
            if (comptime @typeInfo(R) == .error_union) try Ex.frame(h.app, ui) else Ex.frame(h.app, ui);
        }

        pub fn setup(h: *Self, ctx: *vass.app.Context) !void {
            if (@hasDecl(Ex, "setup")) try Ex.setup(h.app, ctx.window());
        }

        pub fn teardown(h: *Self, ctx: *vass.app.Context) void {
            if (@hasDecl(Ex, "teardown")) Ex.teardown(h.app, ctx.window());
        }

        pub fn event(h: *Self, ctx: *vass.app.Context, ev: vass.platform.Event) bool {
            if (!@hasDecl(Ex, "event")) return false;
            switch (ev) {
                .quit, .close_requested => {},
                else => {
                    var s = h.makeStep(ctx, null);
                    Ex.event(h.app, &s, ev);
                },
            }
            return false;
        }

        /// A live run's per-turn hook; a snapshot run's is `script`.
        pub fn update(h: *Self, ctx: *vass.app.Context) !void {
            if (h.scripted or !@hasDecl(Ex, "step")) return;
            var s = h.makeStep(ctx, null);
            try Ex.step(h.app, &s);
        }

        pub fn script(h: *Self, core: *vass.app.Step) !void {
            const ctx_runner = core.runner;
            var ctx = ctx_runner.context(null);
            var s = h.makeStep(&ctx, core.*);
            if (@hasDecl(Ex, "step")) try Ex.step(h.app, &s);
            if (h.cfg.snapshot_frame) |f| if (core.n == f) {
                try s.save("{s}", .{h.cfg.snapshot_name orelse h.env.name});
                s.done();
            };
        }

        pub fn afterFrame(h: *Self, ctx: *vass.app.Context) !void {
            if (!@hasDecl(Ex, "after")) return;
            var s = h.makeStep(ctx, null);
            try Ex.after(h.app, &s);
        }
    };

    const snapshot = env.cli.snapshot();
    var window = cfg.window;
    window.hidden = snapshot and !env.cli.hold;
    var host: Host = .{ .app = app, .env = env, .cfg = cfg, .scripted = snapshot };
    try vass.app.run(Host, &host, .{
        .window = window,
        .theme = cfg.theme,
        .background = cfg.background,
        .text_input = cfg.text_input,
        .gpa = env.gpa,
        .script = if (snapshot) .{
            .dir = env.cli.snapshot_dir,
            .clock_step = cfg.snapshot_clock_step,
            .real_clock = !(cfg.fixed_clock orelse true),
            .sleep_ms = cfg.snapshot_sleep_ms,
            .hold = env.cli.hold,
            .os_input = cfg.feed_input orelse false,
        } else null,
    });
}
