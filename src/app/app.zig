//! The application loop: the glue between `platform` (windows, events) and `ui` (widgets) that
//! every program otherwise writes by hand.
//!
//! One window, the common case:
//!
//!     const MyApp = struct {
//!         // the Ui's state (focus, popups) is kept by the loop; read it as `ui.state`
//!         pub fn frame(app: *MyApp, ui: *vass.Ui) void { ... }
//!     };
//!     pub fn main() !void {
//!         var app: MyApp = .{};
//!         try vass.run(MyApp, &app, .{ .window = .{ .title = "Notes", .width = 900, .height = 600, .resizable = true } });
//!     }
//!
//! The program type may also declare (all optional, found by name, checked at compile time):
//!
//!   * `setup(app, ctx: *Context) !void`: once the window exists (load images, sounds, fonts).
//!     If it fails, the window is closed and `teardown` is not called: clean up what it did.
//!   * `teardown(app, ctx: *Context) void`: once, when the loop ends, however it ends (the close
//!     button, `ctx.quit`, Cmd+Q, a script, an error from a hook). Every window is still there,
//!     its `windowClosed` hook has run, and the windows are destroyed after it returns.
//!   * `event(app, ctx, ev: Event) bool`: every event first; return true to consume it (global
//!     shortcuts). Nothing else sees a consumed event.
//!   * `update(app, ctx) !void`: once per loop turn, before the frame (timers, polling, results
//!     from another thread). Not called for the live-resize redraws of a window being resized.
//!   * `afterFrame(app, ctx) !void`: once per loop turn that drew, after the frames. Not called
//!     once the loop has been told to end.
//!   * `closeRequested(app, ctx) bool` (or `(app, ctx, window: *AppWindow)`): the close button;
//!     return false to keep the window open.
//!   * `theme(app) Theme`: a theme chosen every frame (it replaces `Config.theme`).
//!   * `script(app, step: *Step) !void`: scripted runs only, see `script.zig`.
//!
//! The names `setup` and `teardown` (not `init` and `deinit`) leave a state type's own
//! constructor and destructor alone: `vass.run` can take a type that has both.
//!
//! Several windows: make a `Runner`, `use` a program for the hooks above, `open` windows (at any
//! time, from any hook or frame) each with the state its own `frame` works on, then `run`. The
//! windows' `Input`, `ui.State` and display list belong to the loop, one set per window.
const std = @import("std");
const platform = @import("../platform/backend_sdl.zig");
const ui_mod = @import("../ui/ui.zig");
const geom = @import("../core/geom.zig");
const runner = @import("runner.zig");
const script = @import("script.zig");

pub const Runner = runner.Runner;
pub const Options = runner.Options;
pub const Context = runner.Context;
pub const AppWindow = runner.AppWindow;
pub const WindowSpec = runner.WindowSpec;
pub const RedrawPolicy = runner.RedrawPolicy;
pub const End = runner.End;
pub const Clock = runner.Clock;
pub const Result = runner.Result;
pub const Event = runner.Event;
pub const Step = script.Step;
pub const ScriptOptions = script.Options;

/// `run`'s settings.
pub const Config = struct {
    window: platform.WindowOptions,
    theme: ui_mod.Theme = .{},
    /// What the frame is cleared with; null is `theme.bg`.
    background: ?geom.Color = null,
    /// Start the input method (text fields and areas need it).
    text_input: bool = false,
    redraw: RedrawPolicy = .always,
    /// The frame period in milliseconds (see `Options.frame_ms`).
    frame_ms: u32 = 16,
    redraw_every_ms: ?u32 = null,
    /// A scripted run instead of a live one.
    script: ?ScriptOptions = null,
    /// For the loop's own memory; leak-checked if you pass a leak-checking allocator.
    gpa: std.mem.Allocator = std.heap.smp_allocator,
};

/// The `Runner` options a `Config` stands for (a scripted run's are applied on top by `Runner.initScripted`).
pub fn optionsOf(cfg: Config) Options {
    return .{
        .redraw = cfg.redraw,
        .frame_ms = cfg.frame_ms,
        .redraw_every_ms = cfg.redraw_every_ms,
    };
}

/// Opens one window for `app` and runs the loop until it is closed (or Cmd+Q). `App` has the
/// hooks listed at the top of this file; `frame` is required.
pub fn run(comptime App: type, app: *App, cfg: Config) !void {
    var r = if (cfg.script) |s| Runner.initScripted(cfg.gpa, optionsOf(cfg), s) else Runner.init(cfg.gpa, optionsOf(cfg));
    defer r.deinit();
    r.use(App, app);
    _ = try r.open(App, app, .{
        .window = cfg.window,
        .theme = cfg.theme,
        .background = cfg.background,
        .text_input = cfg.text_input,
    });
    try r.run();
}

test {
    _ = @import("app_test.zig");
}
