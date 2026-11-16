# Vass

A GUI toolkit for Zig, built app-first: features are added when an app needs them.
This is the first vertical slice, driven by [Claude Buddy](../apps/ClaudeBuddy).

## Layout

`src/` is grouped by the package each folder would become when it is extracted; `src/vass.zig` is
the public root and keeps every public name (`vass.ui`, `vass.Layout`, `vass.audio`, ...).

- `src/core/` — what everything else builds on, no platform, nothing outside the folder:
  `geom.zig` (rectangles, colours), `gfx.zig` (the display list: drawing recorded as plain data),
  `image.zig` (`Image` handles, `ImageOpts`/`Fit`, the pure fit math; here because `gfx` carries
  images), `keys.zig` (modifier flags, keycodes), `png.zig` (a minimal PNG writer).
- `src/platform/` — `backend_sdl.zig` (SDL3 windows, input, text measuring and the display-list
  renderer, text via SDL3_ttf + FreeType; `vass.platform`) and `macos.zig` (menu-bar item, overlay
  windows, Spaces behaviour, notch metrics, through the Objective-C runtime).
- `src/text/` — pure text machinery: `text_edit.zig` (`TextEdit`, the editing core), `undo.zig`
  (`History`), `grapheme.zig` (UAX #29 boundaries, Unicode 18.0) and `emoji.zig` (UTS #51 emoji
  clusters) with their generated tables `grapheme_data.zig` / `emoji_data.zig` (`tools/gen_grapheme.py`,
  `tools/gen_emoji.py`; `testdata/GraphemeBreakTest.txt` is the official test file, comments
  stripped), and `text_compose.zig` (pixel helpers that put colour emoji into a line of text).
- `src/layout/layout.zig` — flex-style layout (`vass.Layout`): a per-frame tree solved to
  rectangles. Depends only on `geom`.
- `src/image/` — `decode.zig` (PNG/JPEG/BMP/GIF from memory through stb_image, `stb_impl.c`; pixel
  helpers), `svg.zig` (SVG parser), `raster.zig` (rasteriser for parsed SVGs), `svg_cache.zig`
  (texture cache policy). All but the C file are pure Zig.
- `src/audio/` — `audio_pcm.zig` (`Pcm`, WAV, OGG Vorbis and MP3 decoding via `audio_impl.c`),
  `audio_mixer.zig` (the voice mixer; both pure) and `audio.zig` (`vass.audio.Audio`: sounds,
  voices and microphone recording on SDL3 audio streams).
- `src/ui/` — the immediate-mode toolkit: `ui.zig` (widgets, `vass.Ui`, the pointer `Input`),
  `controls.zig`, `text_area.zig`, `text_input.zig` (what text fields and areas share: the
  input-method pre-edit model, password masking, the right-click menu), `popup.zig` (popups, menus,
  dropdown, tooltips), `split.zig` (split panes), `focus.zig` (keyboard focus), `icons.zig`, and the
  headless `focus_test.zig` / `text_input_test.zig`. These depend on `platform` for text measuring
  and event types.
- `src/app/` — the application loop (`vass.app`, `vass.run`): windows, events, one frame per window,
  redraw policy, scripted runs (see "Application loop"). It sits on `platform` and `ui`.
- `build/deps.zig` — build helpers compiling zlib, libpng, FreeType, HarfBuzz and SDL_ttf from
  source (SDL3 comes from the castholm/SDL package).
- `examples/` — the example programs (see "Examples"), `tools/` — the table generators.

Layering rule: `core/` imports nothing outside `core/`; `text/` imports only `core/` and itself;
`layout/` and `image/` know nothing about the platform; only `platform/` talks to SDL (and
`audio/audio.zig` to SDL's audio streams). `ui/` sits on top of all of them, and `app/` on `platform`
and `ui`: nothing in the other folders imports `app/`.

## Examples

Every `examples/*.zig` is a program, and `build.zig` finds them by listing the folder: there is no
per-example code to write. For each file `name.zig` you get an executable and a step that runs it,
with everything after `--` forwarded:

    zig build -l                        # lists the steps, one per example
    zig build split                     # run examples/split.zig
    zig build split -- --snapshot DIR   # hidden window, scripted, writes BMPs into DIR, exits
    zig build examples                  # build all of them (zig build test does too)

**Add one:** drop `examples/mything.zig` (a `pub fn main`, importing `@import("vass")`) in the folder;
`zig build mything` works at once. Subfolders are never examples: `examples/common/` is the shared
helper and `examples/assets/` holds what the examples `@embedFile` (paths relative to the file, e.g.
`@embedFile("assets/chime.wav")`). Every example gets the `vass` module and nothing else.

`examples/common/harness.zig` is what the examples share beyond the toolkit's loop: the command line
(`--snapshot DIR`, `--hold` to show the window during a snapshot run, the per-example `--script` /
`--debug-input`) and the mapping from an example's hooks to a `vass.run`. An example is its state plus
`pub fn frame(app: *App, ui: *Ui)`, and `main` is `harness.start(...)` then
`harness.run(@This(), env, .{ .window = ... }, &app)`; the optional hooks `setup`, `teardown`,
`event`, `step` (scripted input) and `after` are described at the top of the file. `windows.zig`
uses the multi-window `Runner` directly and only the command line part of the harness.

## Using it

Requires Zig 0.17 and Xcode (or the Command Line Tools) for the macOS SDK. macOS only for
now. Nothing else needs installing: SDL3 3.4.20, SDL_ttf 3.2.2, FreeType 2.14.3,
HarfBuzz 15.1.0, libpng 1.6.58 and zlib 1.3.2 are fetched as pinned dependencies (`build.zig.zon`), compiled from source by
the Zig build and linked statically, so an app is a single binary that links only system
frameworks and libSystem/libobjc. HarfBuzz is C++ (single-file amalgamation); Zig builds it
with its bundled libc++, so no C++ toolchain is needed either. The first build compiles
SDL3 and HarfBuzz (about 40 s); later builds reuse the cache.

SDL_ttf uses HarfBuzz for shaping (including AAT `trak` tracking), so text measures and
renders identically to Homebrew's build. It is built without PlutoSVG (no colour SVG
fonts); FreeType is built with libpng and zlib (they let it read the PNG bitmaps in colour
emoji fonts, see "Emoji and fallback fonts") but without bzip2/brotli (no WOFF2), and HarfBuzz
without CoreText/ICU/GLib. libpng (libpng licence) and zlib (zlib licence) are two more pinned
lazy dependencies, about 90 KB in a release binary and about a second of clean-build time.

Images are decoded by [stb_image](https://github.com/nothings/stb) (public domain / MIT),
a pinned, hashed lazy dependency in `build.zig.zon` (commit 9600522) compiled as one C file,
`src/image/stb_impl.c`, with only PNG, JPEG, BMP and GIF enabled. It is independent of SDL, so it is
built with `-Dsystem-sdl=true` too. It adds roughly 75 KB of code to a binary that uses images
(the linker drops it from apps that do not).

Audio decoding uses two more single-file libraries, both pinned and hashed lazy dependencies
compiled together as `src/audio/audio_impl.c`: `stb_vorbis.c` from the same stb checkout (Ogg Vorbis,
public domain / MIT) and [dr_mp3](https://github.com/mackron/dr_libs) (commit f12e197, public
domain / MIT-0). Like stb_image they are dropped by the linker from apps that never decode audio.
SDL's audio subsystem and CoreAudio were already part of the static SDL build.

`-Dsystem-sdl=true` skips all that and links the Homebrew dylibs (`brew install sdl3
sdl3_ttf`, looked up in /opt/homebrew/lib) as before. The source dependencies are lazy, so
that mode downloads nothing.

**Deployment target.** Vass exports `default_target` from its `build.zig`: the host with a
macOS 13.0 deployment target (`minos 13.0`), instead of the build machine's OS version.
Pass `-Dtarget=aarch64-macos.14.0` (any version) to override. An app should use the same
default for its own code and hand the resolved target to the dependency:

In your `build.zig.zon`:

    .dependencies = .{ .vass = .{ .path = "../Vass" } },

In your `build.zig`:

    const vass_build = @import("vass");   // Vass's build.zig, for default_target
    const target = b.standardTargetOptions(.{ .default_target = vass_build.default_target });
    const optimize = b.standardOptimizeOption(.{});
    const system_sdl = b.option(bool, "system-sdl", "Use Homebrew SDL3/SDL_ttf") orelse false;
    const vass = b.dependency("vass", .{
        .target = target,
        .optimize = optimize,
        .@"system-sdl" = system_sdl, // optional escape hatch
    }).module("vass");

Add `zig-pkg/` to the app's `.gitignore` (Zig 0.17 unpacks dependencies there).

Then `@import("vass")` and hand `vass.run` a state type with a `frame` function (see "Application
loop"). The pieces underneath it are public too: a `vass.platform.Window`, a `vass.DisplayList` filled
each frame, and `window.render(&list, clear_color)`.

## Application loop

`vass.run` is the loop every program otherwise writes by hand: create the window, give it an `Input`,
poll events and feed them, build the `Ui`, call your frame function, `ui.finish()`, render, sleep;
plus the live-resize redraw, the input method, a deterministic snapshot mode and the cleanup.

    const Notes = struct {
        text: vass.ui.TextFieldState,
        pub fn frame(app: *Notes, ui: *vass.Ui) void { ... }   // the only required hook
    };
    pub fn main(init: std.process.Init) !void {
        var app: Notes = .{ .text = vass.ui.TextFieldState.init(init.gpa) };
        try vass.run(Notes, &app, .{ .gpa = init.gpa, .text_input = true, .window = .{ .title = "Notes", .width = 900, .height = 600, .resizable = true } });
    }

**Who owns what.** The loop owns, per window, the `Input`, the `ui.State` (focus, popups, tooltip
timer, splitter drags; it is attached to every `Ui`, read it in a frame as `ui.state`) and the display
list. You own your app state. `ui.finish()` is called for you after the frame (it is safe to call it
yourself too: only the first call counts). Frames and hooks run on the main thread.

**Hooks.** All optional but `frame`, found by name on the type, with their signatures checked at
compile time (a function that may fail can return `!void`):

| hook | when |
|---|---|
| `frame(app, ui)` or `frame(app, ui, ctx)` | every frame of the window |
| `setup(app, ctx) !void` | once, after the window exists: load images, sounds. If it fails, `teardown` is not called: clean up what it did |
| `teardown(app, ctx)` | once, when the loop ends however it ends (close button, `ctx.quit`, Cmd+Q, a script, an error from a hook); every window is still there and is destroyed after it returns |
| `event(app, ctx, ev) bool` | every event first; `true` consumes it (global shortcuts) |
| `update(app, ctx)` | once per loop turn, before the frames: timers, polling, results from a worker. **Not** called for the live-resize redraws of a window being resized |
| `afterFrame(app, ctx)` | after the frames of a turn; not once the loop has been told to end |
| `closeRequested(app, ctx) bool` | the close button (also `(app, ctx, window)`); `false` keeps the window |
| `theme(app) Theme` | a theme chosen every frame, instead of `Config.theme` |
| `script(app, step)` | scripted runs only, below |

The hooks are called `setup` and `teardown`, not `init` and `deinit`, so a state type with its own
`pub fn init(gpa) !App` and `deinit` goes to `vass.run` as it is.

`ctx` (a `vass.AppContext`) gives `ctx.window()` (the platform window), `ctx.uiState()`, `ctx.gpa`, `ctx.frameAlloc()`
(an arena reset at the start of every loop turn, and, separately, at the start of every live-resize
frame), `ctx.time()` (the clock `Input.time` follows), `ctx.quit()` (no further frame is drawn),
`ctx.requestRedraw()`, `ctx.redrawAt(t)`, `ctx.redrawEvery(ms)`, and the window set (`open`, `close`,
`requestClose`, `windows` (a copy for this turn), `find`). `window()` and `uiState()` panic when no
window is open, which only an app that ends with `End.last_window_closed` or `End.explicit` can have
closed; it uses `windowOrNull()` and `uiStateOrNull()`. `Config` also takes `.theme`, `.background`
(the clear colour, default `theme.bg`), `.text_input`, `.frame_ms` and `.gpa`.

**Several windows.** `vass.Runner` is the loop with a dynamic set of windows. `use` a program type for
the hooks above, `open` windows (before `run`, from `init`, or later from any hook or frame) each with
its own state type and `frame`, then `run`. The per-window state type may also declare `theme(w)` and
`windowClosed(w, ctx)` (called just before its window is destroyed: free what `w` is). Windows are
drawn in `WindowSpec.draw_order`, then in the order opened. Closing is deferred: `ctx.close(w)` marks
the window and the loop destroys it between frames, so it is safe from another window's frame, from
the window's own frame, or from a hook. What ends the loop is `Options.end`: the main window closed
(the default: the first one opened, or `WindowSpec.main`), the last window closed, or never (an app that
lives in the menu bar; it quits with `ctx.quit()` or Cmd+Q, which always end it). When the loop ends
the windows are not destroyed at once: first every window's `windowClosed` runs (last opened first),
then `teardown`, then the windows go, so both can still use all of them. A window the app
hides and shows again (`AppWindow.hide`/`show`) is not drawn while hidden. `examples/windows.zig`
is the reference; see "Several windows".
Shared data is the caller's: plain app state that every window's frame reads.

**The turn.** Each loop turn (`Runner.iterate`): events (the `event` hook, then `Input.feed` for every
window, which keeps only its own), `Input.time`, `update`, `script`, destroy closed windows, a frame per
window, `Input.endFrame`, `afterFrame`, sleep. Once the loop has been told to end (a quit, the end
policy, `ctx.quit()`, a script's `done` after its frame) the turn stops there. A resizable window also
gets the live-resize callback (`Window.setFrameCallback`) wired for you: it draws that window with
`Input.idle()` and without `update`.

**Redraw policy.** `Config.redraw` / `Options.redraw`:

- `.always` (the default, what hand-written loops did): a frame every turn, then sleep `frame_ms` (16).
- `.on_demand`: block in the OS's event wait (no CPU) and draw only when something asks. Every trigger
  draws at least two frames, because an immediate-mode UI needs a second one to settle (popups use the
  last frame's rectangles). What asks: any input event or a `wake()` from another thread (two frames);
  a widget that is animating (`ui.requestRedraw()` every frame it runs; frames come at the `frame_ms`
  pace until a frame does not ask again); a time a widget asked for (`ui.requestRedrawAt(t)`: the
  tooltip delay, and the blink of the caret of a focused text field or text area use it, so an idle
  window with a tooltip waiting or a caret in it wakes only when the tooltip is due or the caret
  flips); and the app itself (`ctx.requestRedraw()`, `ctx.redrawAt(t)`, `ctx.redrawEvery(ms)` or
  `redraw_every_ms` for an audio meter or a playback position, set while it runs and cleared after).
  `update` runs once per wake-up, not at a steady rate. A program with its own time-based drawing
  (a toggle that slides) calls `ui.requestRedraw()` while it moves.

**Scripted runs.** `Config.script = .{ .dir = "out", .clock_step = 0.016 }` (or
`Runner.initScripted`) runs the same loop with hidden windows, a fake clock that is `clock_step`
times the turns so far, the real mouse and keyboard ignored, and the program's `script(app, step: *vass.app.Step)`
hook called each turn after `update`. The hook injects input with `step.click(x, y)`, `press`,
`release`, `move`, `wheel`, `key(code, mods)`, `text`, `compose`, `focus`, `dropFile`, `inject(ev)`
(they travel through the same dispatch as OS events: your `event` hook and `Input.feed` see them),
aims at another window with `step.to(window)`, reads `step.n` (the turn), writes `<dir>/<name>.bmp`
with `try step.save("name-{d}", .{i})`, and ends the run with `step.done()` (after this frame) or
`step.stop()` (now); `save` and `done` make the turn draw even in an `.on_demand` run. `step.input()` and `step.state()` reach the window's `Input` and `ui.State` for
scripts that set fields directly. Because it is the live loop, code that only runs in the live app
(an `update` that polls) runs in snapshot runs too, and `max_frames` stops a script that never ends.
Command-line parsing is yours; `examples/common/harness.zig` is a small one.

**By hand.** A `vass.platform.Window` can still be driven without any of this (see "Custom fonts,
weights, resizing, list helpers" for the rule a resizable window then follows: register
`setFrameCallback` and draw an idle frame from it).

## Widgets and layout

`vass.Ui` is immediate mode: each frame, build a `Ui` over the display list and call
widgets. A widget draws itself and returns its interaction from the same rectangle, so
there is no separate hit-testing code. State (selected tab, toggles) stays in the app.

    var input: vass.ui.Input = .{};              // lives across frames
    // in the event loop:      input.feed(event, window.id());
    // once per frame:
    var ui = vass.Ui.init(&list, &window, input, .{});   // .{} = default Theme
    var area = vass.Rect{ .x = 0, .y = 0, .w = 360, .h = 640 }.inset(16);
    const header = area.cutTop(26);
    if (ui.tabs(header, &.{ "Overview", "Costs" }, &tab)) {}
    if (ui.button(area.cutBottom(32), "Mute", .{ .on = muted })) muted = !muted;
    input.endFrame();                            // after drawing

Layout is rect cutting: `Rect.cutTop/cutBottom/cutLeft/cutRight` shrink a rectangle and
return the strip, and `inset`, `column`, `row`, `center` derive sub-rectangles.
Widgets: `label`, `card`, `pill`, `tabs`, `button`, `meter`, `bar`, `hit`, `fitText`.
`Input.pressed` is true only on the frame a left click arrived, and widgets do not
occlude each other (except under an open popup, see below). `Ui.initHeadless` builds a Ui without a window, for tests.

## Flex layout

Rect cutting (above) is fine for a handful of boxes. When a screen has many boxes that wrap,
share space or depend on text size, declare them instead and let `vass.Layout` produce the
rects. Widgets are still called with a `Rect`; the layout is declared, solved and used in the
same frame, so nothing lags a frame behind.

    var lay = vass.Layout.init(arena);                // arena reset every frame
    _ = lay.begin(.{ .dir = .col, .padding = .all(16), .gap = 12 });
    _ = lay.begin(.{ .dir = .row, .h = .fixed(44), .gap = 8, .cross = .center });
    const back  = lay.leaf(.{ .w = .fixed(32), .h = .fixed(32) });
    const title = ui.layText(&lay, "Inbox", 15, .{ .w = .grow(1) });
    lay.end();
    const body = ui.layWrapped(&lay, long_text, 13, .{});   // height follows the width
    lay.end();
    lay.solve(ui.bounds);
    _ = ui.iconButton(lay.rect(back), .arrow_left, .{});
    ui.label(lay.rect(title), "Inbox", .{ .size = 15 });
    _ = ui.labelWrapped(lay.rect(body), long_text, .{ .size = 13 });

- **Sizes** per axis: `.fixed(px)`, `.grow(weight)` (shares leftover main-axis space; stretches on
  the cross axis), `.hug` (children plus padding; 0 for a leaf), `.percent(f)` of the parent's content
  box, `.measured(ctx, fn)` (a leaf whose extent comes from a callback at the width it is given).
  Plus `min_w/max_w/min_h/max_h`, `aspect` (w/h) and `shrink` (children never shrink unless asked).
- **Containers**: `dir` (`.row`/`.col`), `gap`, `padding` (`.all`, `.xy`), `main` (`.start .center .end
  .space_between`), `cross` (`.start .center .end .stretch`, per child `align_self`), `wrap` with
  `line_gap` (rows only), `scroll` (`.y`/`.x`/`.both`), and `position = .absolute` with `inset` for
  out-of-flow badges and overlays. Sizes are border-box.
- **Queries after `solve`**: `rect`, `contentSize`, `overflow`, `scrollTo`. For a scrolling node:
  `ui.beginScroll(lay.rect(n), &st, lay.contentSize(n).h); lay.scrollTo(n, 0, st.offset);`
  then draw the children with their `rect`s.
- **Rounding**: every edge is snapped to a whole point (`floor(v + 0.5)`), so neighbours share an
  edge and never overlap or leave a gap, and children stay inside their parent.
- **One level, no tree**: `layout.row(area, .{ .gap = 8 }, &.{ .fixed(32), .grow(1) }, &rects)`
  (`col` likewise; `rects.len` must equal the sizes), or by name:
  `const r = layout.rowNamed(area, .{}, .{ .icon = layout.fixed(32), .title = layout.grow(1) });`
  gives `r.icon`, `r.title`. (Write `layout.fixed(..)`, not a bare `.fixed(..)`: an anonymous
  struct gives Zig no type to resolve it against.)
- Misuse (unbalanced `begin`/`end`, nesting past 64) asserts in Debug and is ignored otherwise;
  every input is sanitised, so NaN or negative sizes cannot produce NaN rects.

Use rect cutting for a fixed strip or two; use `Layout` for forms, rows that adapt to the window
size, wrapping chips, text-driven heights and scrolling columns. They mix freely: any `Rect` from a
layout can be cut further. `zig build layout` is a resizable demo (`-- --snapshot DIR` for images).

## Split panes

A `splitter` is a divider the user drags to resize the pane on one side of it. The size lives in
the app (an `f32`, or a `vass.SplitState`); the splitter reads and writes it, and `split.two` /
`split.three` turn it into the rectangles of the panes and of the divider, so the app computes
nothing by hand.

    var side = vass.SplitState.init(270);        // across frames: the size, and what it was before a collapse
    // per frame:
    const sh = vass.split.two(area, side.size, .{ .min_other = 420, .gap = 8 });   // first | second
    // ... draw the panes in sh.first and sh.second ...
    const res = ui.splitter(sh.divider, &side.size, .{
        .min = 160, .max = 420, .default = 270, .collapse_below = 110,
        .shown = sh.size,                        // what is on screen, if the window squeezed it
    });
    side.remember();                             // keeps the last open size for side.toggle()

    // A right-hand pane grows when the divider moves left:
    const rt = vass.split.two(area, right_w, .{ .side = .second, .min_other = 420 });
    _ = ui.splitter(rt.divider, &right_w, .{ .invert = true, .min = 240, .max = 480, .shown = rt.size });

    // Left | centre | right is two of them (the left pane is served first, the right one gives way):
    const t3 = vass.split.three(area, left_w, right_w, .{ .min_centre = 420, .gap = 8 });
    // t3.left, t3.centre, t3.right, t3.left_divider, t3.right_divider, t3.left_size, t3.right_size

`SplitterOpts`: `axis` (`.vertical` = a vertical bar dragged left / right; `.horizontal` = a horizontal
bar dragged up / down), `min` / `max` (clamp of the size), `default` (double-click and Enter reset to
it), `collapse_below` (dragging below it snaps the size to 0; dragging back out restores at least
`min`; stepping down from `min` with the keyboard collapses too), `invert`, `thickness` (the visible
line, default 1) and `hit` (the grab area centred on it, default 8), `step` (arrow key, Shift = 5x),
`id`, `disabled`, `shown`, `color` (the line at rest; `.alpha(0)` hides it, e.g. over a panel border
that is already drawn), `draw` and `tab_stop` (below). `SplitterResult`: `changed`, `dragging`,
`hovered`, `collapsed` (size is 0), `reset`, `released`, `focused`.

- **Dragging.** The press records the pointer and the size; the size is then
  `start + pointer movement`, clamped, so the divider never jumps under the pointer, also when it
  was grabbed off-centre. The drag is captured in `State.drag` (the splitter keeps tracking when the
  pointer leaves the grab area or the window) and nothing else hovers or is clicked until the button
  is up. Needs `ui.state`. A double click (the OS click count, `Input.mouse_clicks`; scripted input
  that leaves it 0 is counted from `Input.time` and position: within 0.5 s and 4 points, see
  `ui.clickCount()`) resets to `default`.
- **The grab area wins over the panels beside it.** Panels are usually declared before the divider
  that sits on top of them, so their widgets have already looked at the pointer when it runs. Like
  popups, splitters therefore work from last frame: each records its grab area in `State.grabs`,
  `Ui.finish` keeps last frame's list, and `Ui.hit` (which every widget uses, the focus click
  handling included) reports no hover and no click for a pointer inside one of them, or anywhere
  while a splitter is being dragged. It applies to widgets of the same or a lower layer: a popup
  above the splitter is not blocked by it, and a popup *over* the splitter blocks the splitter
  (`popup.pointerBlocked`). So the call needs `ui.state` and `ui.finish()` every frame; a frame that
  skips `finish` still works (the first splitter of the frame rotates the records). The blocked area is where the
  divider was last frame, which is within the grab width of where it is now while dragging.
- **Keyboard.** A Tab stop (`FocusRole.splitter` for a vertical bar, `.splitter_horizontal`): Left /
  Right (Up / Down for a horizontal bar) move the divider by `step`, Shift by 5x, Home / End go to `min` / `max`, Enter
  resets. Consumed with `ui.takeKey`; `keyClaimed` reports them for a focused splitter. The focus
  ring is the line drawn in the ring colour.
- **Squeezed windows.** `split.two` clamps the size it *uses* to what fits (leaving `min_other`) and
  returns it as `.size`; the stored size is untouched, so it comes back when there is room. Pass
  `.size` as `SplitterOpts.shown` so that a drag or key press starts from what the user sees and
  stores that.
- **No lag.** The rectangles are computed from the size, then the splitter writes the size, so a
  frame that draws the panes before calling the splitter shows the new size one frame later. Either
  call the splitter first and compute the rectangles after, or feed the size to `vass.Layout`
  and run the splitter on the solved divider before drawing anything: the same-frame result.
  For a divider that must be drawn on top of panels and sit last in the Tab order, call it twice:
  early with `.draw = false, .tab_stop = false` (only the mouse), late with the defaults. Both calls
  see the same pointer and agree on the size (`examples/split.zig`, HaborDesktop).

With `vass.Layout` the size is a fixed width next to a growing centre, and the divider is the
leaf between them. The layout is solved after the splitter has run, so the pane follows the
pointer in the same frame: call the splitter first, with the divider rectangle the layout gave
last frame (the splitter only needs it to know where the grab area is):

    // app state: side_w: f32 = 270, side_div: Rect = .{ 0, 0, 0, 0 } (zero on the first frame)
    _ = ui.splitter(app.side_div, &app.side_w, .{ .min = 160, .max = 420, .default = 270 });

    var lay = vass.Layout.init(arena);
    _ = lay.begin(.{ .dir = .row, .w = .grow(1), .h = .grow(1) });
    const side = lay.leaf(.{ .w = .fixed(app.side_w), .h = .grow(1) });
    const gap  = lay.leaf(.{ .w = .fixed(8), .h = .grow(1) });       // the divider sits in here
    const main = lay.leaf(.{ .w = .grow(1), .h = .grow(1), .min_w = 420 });
    lay.end();
    lay.solve(ui.bounds);
    app.side_div = lay.rect(gap);                  // for next frame's splitter
    // draw the panes in lay.rect(side) and lay.rect(main)

This is tested (`split.zig`, "feeds a Layout with no lag"). Without that, call it after the panes
are drawn and the new size shows a frame later. `zig build split` is a runnable example: a
resizable window with a three-pane shell, a horizontal split in the centre, a collapsing sidebar and
toggle buttons; `-- --snapshot DIR` writes six pictures after scripted input.

## Mouse cursors

`vass.Cursor` is `arrow, text, pointer, resize_h, resize_v, resize_nwse, resize_nesw, grab, grabbing,
move, crosshair, wait, not_allowed`: SDL system cursors, created lazily, cached and freed with the
last window. (SDL has no open-hand cursor: `grab` and `grabbing` are its "move" cursor, the closed
hand on macOS.) A widget asks for one while the pointer is over it:

    if (hv.hovered) ui.setCursor(.pointer);

The last request of the frame wins (widgets are drawn bottom to top, so the topmost one), and a
request made while the pointer is over a popup above the layer being drawn is ignored. Nothing is
set at the time of the call: the window applies the request in `Window.render` and then falls back
to the arrow, so a widget only has to keep asking, and apps that never call `ui.finish()` get cursors
too. With several windows only the window the pointer is over changes the cursor (a window drawn last
cannot reset what another asked for). A headless Ui (`initHeadless`) records the request in `ui.cursor` (null when nobody asked)
without touching SDL, which is what the tests read. Text fields and text areas ask for `text` while
hovered, splitters for `resize_h` / `resize_v` while hovered and for the whole drag. Custom widgets
call `ui.setCursor` themselves; `Window.setCursor` does the same without a Ui.

## Text input, scrolling, wrapping

Widgets that need memory across frames take a caller-owned state struct; there is no hidden
per-widget state. Keyboard focus lives in a caller-owned `vass.ui.State`:

    // (with `vass.run` the loop keeps the Input and the State; the rest of this section is what it does)
    var input: vass.ui.Input = .{};          // across frames
    var ustate: vass.ui.State = .{};         // across frames: who has focus
    var field = vass.ui.TextFieldState.init(gpa);   // keep its address stable
    var scroll: vass.ui.ScrollState = .{};
    window.startTextInput();                 // once; enables text_input events

    // per event: input.feed(ev, window.id());   per frame, before drawing: input.time = seconds;
    var ui = vass.Ui.init(&list, &window, input, .{});
    ui.state = &ustate;

    const res = ui.textField(rect, &field, .{ .placeholder = "Type here" });
    if (res.submitted) { use(field.edit.text()); field.edit.clear(); }

    const content = ui.beginScroll(list_rect, &scroll, content_height);
    // lay children out inside `content` (it is moved up by the scroll offset)
    ui.endScroll();

    const h = ui.measureWrapped(text, size, width);        // height only
    _ = ui.labelWrapped(.{ .x = x, .y = y, .w = width, .h = 0 }, text, .{ .size = size });

- **`textField`**: single line. Click to focus (and place the caret), double click selects a word
  (dragging then grows by words), triple click everything, drag or shift-click to select, Escape
  or a click elsewhere to blur, Return reports `submitted`. Arrows, home/end,
  alt for words, cmd for line ends, shift to select, cmd+A/C/X/V, cmd+Z / cmd+shift+Z for
  undo/redo, backspace/delete (with alt or cmd for word/line). Scrolls horizontally to keep the caret visible, blinks off
  `Input.time`, and is clipped to its rectangle. Typed text arrives through
  `Input.events()` in order with key presses; apps with their own shortcuts should skip the
  keys the focused widget wants: `ui.keyClaimed(code, mods)` (see Keyboard focus below).
  See "Text input details" below for clusters, the input method, passwords and the context menu.
- **`TextEdit`** (`vass.TextEdit`) is the editor behind it and usable on its own:
  `insert`, `backspace`, `delete`, `move`, `moveTo`, `select`, `selectAll`, `copy`/`cut`, and
  `handleKey(code, mods) -> Action` (changed / copy / cut / paste / submit / cancel ...).
  Offsets are bytes on grapheme cluster boundaries (see below); clipboard access stays with the
  caller.
- **Undo/redo** comes with every `TextEdit`, hence with `TextFieldState` and `TextAreaState` and
  both widgets, with no setup. Cmd+Z undoes, Cmd+Shift+Z redoes (off macOS also Ctrl+Z,
  Ctrl+Shift+Z and Ctrl+Y; `TextEdit.ctrl_undo`); the caret and selection are restored and kept in
  view, and `changed` is reported. Programmatically: `undo() bool`, `redo() bool`, `canUndo()`,
  `canRedo()`, `clearHistory()` on `TextEdit` and on both states (e.g. for Undo/Redo buttons, see
  `examples/controls.zig`). Edits are stored as deltas, not snapshots, in `edit.history`
  (default caps: 1000 steps and 1 MiB, oldest dropped first; tune `edit.history.limits`).
  Coalescing follows macOS: consecutive typed characters, consecutive backspaces and consecutive
  forward deletes each form one step, which ends at a space typed after a word, at a pause over
  1 s (`TextEdit.now`, which the widgets set from `Input.time`; set it yourself outside the
  widgets), on any caret move, click or selection change, on a line break, and when the kind of
  edit changes. Paste, cut, word/line deletion and typing over a selection are one step each, and
  composed (IME) text counts as typing. A new edit clears the redo stack. `setText`, `clear` and
  `TextAreaState.clear` also clear the history (they are resets, not edits); `replaceAll` swaps the
  text as one undoable step; `insertAs(str, kind)` records an insertion as a given kind. Running
  out of memory while recording drops the history, never the edit; if the text was changed behind
  the history's back (writing `edit.buf` directly) the next undo/redo notices and drops it.
- **`beginScroll` / `endScroll`**: wheel scrolling while hovered (`Theme.scroll_step` points
  per line), clamped, children clipped, and a thin scrollbar thumb drawn over the right edge
  when the content overflows. `Ui.hit` ignores the pointer outside the current clip, so
  clipped-away widgets cannot be clicked. `pushClip`/`popClip` do the same for any region;
  the display list carries `push_clip`/`pop_clip` commands (nested clips intersect).
- **`wrapText` / `measureWrapped` / `labelWrapped`**: greedy word wrap using the Ui's
  measure function; honours `\n`, breaks over-long words between characters, never splits
  UTF-8. Lines outside the clip are not drawn.
- **`textSelectable`** (`ui.textSelectable(rect, str, &sel, opts) -> height`): read-only wrapped
  text drawn exactly like `labelWrapped`, that can be selected with the mouse (drag, also across
  wrapped lines and newlines; double-click = word, triple-click = line, dragging after either
  grows by words or lines, shift-click extends),
  copied with Cmd+C through the clipboard hook, Cmd+A to select all of it, Escape or a click
  elsewhere to clear. A right click opens a Copy / Select All menu (`LabelOpts.context_menu`). One selection per `Ui.state` (`State.select`, separate from `focus`, so it
  does not block arrow-key scrolling); starting another, or focusing a text field, clears it. Keep
  one `vass.ui.SelectState` per text at a stable address and call `sel.clear()` when the string
  changes (offsets are clamped defensively anyway). A selection is cleared by a click elsewhere
  only while its text is being drawn. `Ui.offsetAtPoint(str, size, max_w, x, y)` is the pure
  point-to-byte-offset helper behind it. `Input.mouse_clicks` carries the OS click count.
### Text input details

- **Grapheme clusters.** Caret movement, Shift+arrow selection, Backspace, forward Delete,
  click-to-caret (`offsetAtX`, `offsetAtPoint`), selection drawing, word helpers, wrapping of
  over-long words, `fitText` and `max_len` all work on extended grapheme clusters (`vass.grapheme`,
  UAX #29 including emoji ZWJ sequences, flags, Hangul and Indic conjuncts), so "cafe\u{301}", a
  family emoji or a flag is one character. Backspace removes the whole cluster before the caret
  (macOS can peel the last code point off a decomposed sequence; Vass does not). `max_len` never
  leaves half a cluster: an insertion that does not fit is cut at a cluster boundary. A combining
  mark typed after its base joins that typing run in the undo history, whatever the pause.
  `TextEdit.moveTo` and `select` move offsets back to a cluster start; `text_edit.snap` is the
  code point version.
- **Input-method pre-edit.** The focused `textField` / `textArea` draw `Input.composition` inline at
  the caret, underlined, pushing the following text along; the part the input method is working
  on (`Composition.start`/`length`, in code points) gets a highlighted background, and its caret
  is drawn when it has no highlighted part. The pre-edit is not in the buffer or the undo history:
  the commit arrives as a `text_input` event and is an ordinary typing edit (one undo step; over a
  selection it replaces it as one `replace` step). A selection is hidden while composing and
  comes back if the composition is cancelled. While composing the widget's own caret is hidden and
  plain keys (arrows, Backspace, Return, Escape) are left to the input method; Cmd shortcuts still
  work. Mouse clicks inside the widget during a composition do not move the caret (the OS commits
  it). Losing focus drops the composition (`Input.feed`). In a full `max_len` field only what fits
  is shown. The widgets call `Ui.setTextInputArea` themselves while focused, with the pre-edit's
  (or the caret's) rectangle in window points, so the candidate window follows scrolling and works
  inside popups; a later `Window.setTextInputArea` call from the app replaces it, so apps need not
  call it any more. `TextFieldResult` and `TextAreaResult` still report `input_area` and `caret_x`
  (the caret's line and the offset in it). Headless Uis record the request in `Ui.ime_area`.
- **Mouse selection.** `Ui.clickCount` counts the clicks (the OS count, or time and distance for
  scripted input). Double click = word, triple click = line (the whole field in a `textField`),
  Shift+click extends, and a drag after a double or triple click grows by whole words or lines
  (`text_edit.MultiClick`, shared by `textField`, `textArea` and `textSelectable`).
- **Password field.** `TextFieldOpts.password`: one bullet per cluster; caret, selection and click
  work on the masked layout; Cut and Copy do nothing (Paste works); a double or triple click selects
  everything; Alt+arrows jump to the ends and Alt+Backspace deletes to the start (a password has no
  words); undo works. The text is never drawn, never in the focus entry's label (that is the
  placeholder) and never in the display list. A composition is shown too, as underlined bullets
  (the input method itself still sees what you type; the text never appears).
- **Context menu.** A right click in `textField`, `textArea` and `textSelectable` opens Undo / Redo
  (editable only), Cut, Copy, Paste, Select All with shortcut hints, disabled when they do not apply
  (no selection, nothing to undo, empty clipboard, password field). The menu is a popup of the
  existing layer, its state is `ctx` in `TextFieldState` / `TextAreaState` / `SelectState`, and
  `context_menu = false` in the opts turns it off. A right click inside the selection keeps it; elsewhere
  it puts the caret there first (macOS selects the word under the pointer instead; Vass takes the
  simpler rule). The field is focused by the right click and gets focus back when the menu
  closes (`openPopup` remembers it). A field inside a popover opens its menu as a nested popup.
  Apps that already open their own context menu over a text widget should set `context_menu = false`
  there.

- **Backend**: events `mouse_up`, `mouse_wheel` (lines), `text_input`, `text_editing`,
  `key_down`/`key_up` (a `Key` with `code`, `mods`, `repeat`), plus
  `Window.startTextInput/stopTextInput/setTextInputArea` and `clipboardText`/`setClipboardText`.

## Example: split panes

`examples/split.zig`: `zig build split` (`-- --snapshot DIR` saves `split-default.bmp`,
`split-dragged.bmp`, `split-collapsed.bmp`, `split-hover.bmp`, `split-inspector-hidden.bmp` and
`split-narrow.bmp` from a hidden window). See "Split panes" above.

## Example: several windows

`examples/windows.zig`: `zig build windows` (`-- --snapshot DIR` saves `windows-1-open-main.bmp`,
`-doc1`, `-doc2` and `-inspector`, then the same four after typing (`windows-2-typed-*.bmp`) and
the three that remain after a document window is closed (`windows-3-closed-*.bmp`), all windows
hidden). See "Several windows" above.

## Example: notes

`examples/notes.zig` is a small notes app (scrolling wrapped cards, a text field, Return
adds a note; in memory only).

    zig build notes                                  # run it
    zig build notes -- --snapshot DIR                # save DIR/notes.bmp and exit
    zig build notes -- --snapshot DIR --script       # same after scripted input: click the
                                                     # field, type, select all, scroll,
                                                     # drag-select across two lines of a card

## Several windows

`examples/windows.zig` (`zig build windows`) is the reference: a main window with a list of
documents, a window per document (title field, text area with undo, dropdown, counter, tooltip)
and an always-on-top inspector that reports on whichever document window has focus. Windows are
opened and closed at run time, in any order. `zig build windows -- --snapshot DIR` writes
`windows-1-open-*.bmp`, `windows-2-typed-*.bmp` and `windows-3-closed-*.bmp` (one BMP per window,
all windows hidden). Claude Buddy runs three windows with a loop of its own.

**The pattern** (the loop itself is in "Application loop"). A `vass.Runner` owns the windows; for
each one you write a state struct with a `frame`, and the runner keeps what every window needs and
nothing shared: the platform `Window`, an `Input`, a `ui.State` (focus, popups, tooltip timer,
splitter drags, click count), a display list, and the live-resize callback. Per-window widget state
(a `DropdownState`) lives in your struct. Shared app data (the document list) is plain state in the
program that every window's frame reads, so an edit in one window shows in the others on the next
frame. The runner feeds every event to every window's `Input` (`feed` keeps only the events of that
window), draws the windows in order and destroys closed ones between frames.

**What is per window.** `Window` (renderer, fonts, text, image and icon textures, frame callback,
text input on or off, cursor request, drag region, title, position), `Input` (pointer, held
button, keys, text, composition, drops, `window_focused`), `ui.State` (keyboard focus, drag
state, popup rectangles, tooltip timer, focus ring, splitter grabs, click counter) and the widget
states you keep. Nothing in `ui`, `popup`, `focus` or `split` is global: a popup open in one
window does not block, close or take keys from another, and Escape typed into one window reaches
only that window's popups.

**What is shared.** The process-wide parts of the platform, which the backend keeps balanced for
you: SDL video and SDL_ttf start with the first window and stop with the last (closing one window
never tears down video for the rest; a failed `Window.init` leaves nothing started), the system
cursors (created lazily, freed with the last window; the cursor is only changed by the window the
pointer is over, so a window drawn last cannot reset the cursor another one asked for), the
clipboard, the modifier state and the single open-file dialog (`DialogBusy` while one is open, in
whichever window opened it; its result is delivered to the window that opened it only, and is
dropped if that window is destroyed first). Fonts are opened per window.

**Lifetime rules.**
- With the `Runner` none of this is your problem: it heap-allocates windows (stable addresses) and
  destroys them between frames. By hand: a `Window` must not move in memory while a frame callback is
  registered or a `Ui` holds it, so for a window that comes and goes use `Window.create(gpa, opts)`
  and `w.destroy()` (`Window.init` / `deinit` are the by-value form); destroy it between frames or
  from another window's frame or frame callback, never from its own frame callback or while it is
  rendering (that frees it under the running code, so `deinit` panics instead).
- Closing: `Event.close_requested` carries the id of the window whose close button was pressed. The
  `Runner` asks `closeRequested` and closes it (a main window ends the loop); by hand, nothing is
  closed for you. `Event.quit` is the whole app (Cmd+Q, or the last window closed). Cmd+W is an
  ordinary `key_down` with `mods.cmd` and `code == 'w'` and a `window` id (SDL has no default binding
  for it): handle it in the `event` hook and call `ctx.requestClose(window)`.
- Destroy in any order; the last window to go shuts SDL down, and a window opened afterwards
  starts it again.

**Handles are per window.** Textures belong to one renderer. `Image` and `SvgIcon` handles carry
ids that are unique across windows and never reused, so a handle loaded in window A and drawn
(or passed to `hasImage`, `unloadImage`, ...) in window B simply is not found there: nothing is
drawn and nothing is shared. Load what each window needs into that window.

**Input and focus.**
- Events carry the window id: mouse (`mouse_down`, `mouse_up`, `mouse_move`, `mouse_wheel`),
  `mouse_leave`, `focus_gained`, `focus_lost`, `close_requested`, keys (`Key.window`), `text_input`,
  `text_editing`, and the drop events. Window resize and expose are not events: read
  `logicalSize()` each frame, and register `setFrameCallback` per window for live resize (each
  callback fires only for its own window's events).
- `Input.feed` ignores other windows' events. `mouse_leave` clears hover; `focus_lost` ends a
  held button (as a release, so a drag finishes cleanly), drops an input-method composition and
  an unfinished drop highlight, and clears `Input.window_focused` (set again by `focus_gained`).
- Text input is per window: call `startTextInput` for each window that has a text field
  (`WindowSpec.text_input`; the example sets it for document windows). Typed text goes to the window with keyboard
  focus only, so a text field focused in window A cannot see keys typed in B. `setTextInputArea`
  is per window too (the example sets it for the window's own focused field).
  `Window.hasFocus()`, `hasMouseFocus()` and `textInputActive()` query the state.
- `Window.setTitle`, `position`, `raise`, `WindowOptions.position` (the window is created hidden,
  placed and then shown, so it never flashes at the OS's spot) and `cascadeIn(area, index, w, h)`
  / `cascadePosition` (stagger new windows by 28 points, wrapping before leaving the screen).
- `Window.setDragRegion` is per window (up to 8 windows at once).

Frame time. Each renderer is created with vsync off (`SDL_SetRenderVSync(ren, 0)`), so presenting
N windows is not N waits for the display. Measured on this machine (hidden windows, 200 frames
drawn back to back, no sleeping): 8.3 ms per frame with one window and the same 8.3 ms with four,
about one refresh of a 120 Hz display; the cost does not multiply with the window count. Only
hidden windows were measured (a real, visible window may be paced differently by the OS). The loop
sleeps between frames itself (`.always`), or draws only on demand (`.on_demand`, see "Application
loop").

## Not there yet

- Real input-method behaviour (Japanese, Chinese, Korean input, dead keys, where the candidate
  window appears) has only been exercised with synthetic composition events, never with a real
  input method. A wrapped line can still start with a combining mark that follows a space (the
  wrap treats the space as a separator). A caret is not shown at a wrap boundary on the line it
  belongs to (no caret affinity). Selecting across several separate texts is not possible (one
  text at a time). The reveal toggle for password fields does not exist.
- Emoji newer than the OS's emoji font draw as boxes (or as their parts, for a sequence the font
  does not join); only macOS has a system emoji font Vass knows about (see "Emoji and fallback
  fonts"). A selected emoji is not drawn in the selection's text colour, and a disabled one is
  dimmed, not greyed.
- Scrollbar dragging; horizontal scrolling in `beginScroll`. (Keyboard scrolling exists:
  PageUp/PageDown, arrows and Home/End through `ScrollState.key_scroll` and `arrow_keys`.)
- Accessibility (no screen-reader tree: the focus list carries roles and labels, nothing calls the
  OS yet), hover styling, retained widgets, and any platform other than macOS.

## Emoji and fallback fonts

Text is drawn with the UI font (the system font, or `WindowOptions.fonts`). For anything it has
no glyph for, Vass looks further, in this order:

1. **Colour emoji.** An emoji (a grapheme cluster as `vass.emoji` defines it: a character with
   U+FE0F, a keycap, a flag, a skin-tone or ZWJ sequence, a default-emoji character such as
   U+1F600) is drawn from the colour emoji font as one glyph, whatever the UI font has: the
   system font on macOS is `/System/Library/Fonts/Apple Color Emoji.ttc`, and
   `WindowOptions.emoji_font` names another (a PNG-strike bitmap font such as Noto Color Emoji,
   or a `COLR` font; both by path or as embedded bytes, same lifetime rule as `fonts`).
   `colour_emoji = false` turns it off. Pictographs that are text by default and have no U+FE0F
   (a bare "\u{2764}", "\u{A9}") are text and go through the fallback fonts below.
2. **Fallback fonts**, tried in order through SDL_ttf's `TTF_AddFallbackFont`:
   `WindowOptions.fallback_fonts` (your own list of `FontSource`, bytes or a path), then, unless
   `system_fallback_fonts = false`, the fonts macOS ships: Apple Symbols, Hiragino Sans GB
   (Simplified Chinese and Han), Hiragino Kaku Gothic (Japanese), Apple SD Gothic Neo (Korean),
   Arial Unicode (broad coverage). A font that is not installed is skipped. Fallback fonts are
   opened the first time a string has a character the UI font lacks (Latin text never opens one),
   one font per source and pixel size, shared by all weights.
3. Otherwise the UI font's own missing-glyph box.

How the emoji are drawn: SDL_ttf only knows fallback fonts for outline glyphs: it does not
scale the fixed-size PNG strikes of Apple Color Emoji (its smallest "size" is a strike index, and
it would draw a 160 pixel bitmap at any text size), and a ZWJ sequence or a keycap is cut in
pieces when the UI font owns some of its code points (the joiner and U+FE0F). So the backend
splits the string by emoji cluster, shapes each cluster with HarfBuzz on the emoji font alone (that
is where Apple's ZWJ ligatures live), takes the smallest strike at least as tall as the text,
shrinks it to the text size with an area-averaging filter in premultiplied alpha (exact at
the display's pixel size, so it is crisp on Retina), and composes the stretches of ordinary text
and the emoji into one texture on a common baseline. Text without an emoji cluster goes through
SDL_ttf exactly as before.

- **Metrics.** An emoji is as tall as the text is wide (the font's ascent equals the text size)
  and advances 1.15 em, like CoreText, sitting about 0.15 em below the baseline as CoreText sets
  it. `measureText`, `measureTextWeighted`, wrapping, `offsetAtX` and truncation use the widths
  of the same composition, so the caret and selection rectangles line up with what is drawn.
- **Colour.** Emoji keep their own colours: the text colour never tints them. Only its alpha
  applies (a dimmed label or placeholder dims the emoji too).
- **Cost.** Nothing is opened at window creation. The emoji font opens (a fraction of a
  millisecond in a release build; the 188 MB file is read lazily) when the first emoji is
  measured, one more handle per strike size in use; fallback fonts open on the first string that
  needs them (about 1 ms for all five at one size).
- **Failure.** A missing, unreadable or non-font emoji font leaves emoji as the UI font's boxes;
  nothing fails and windows still open. On systems other than macOS there is no system emoji
  font or system fallback list in the build: give `emoji_font` and `fallback_fonts` yourself
  (untested there).
- **Limits.** Emoji and their metrics follow the installed font: an emoji from a Unicode version
  newer than the OS's font is a box. A custom emoji font is sized by its ascent and advance as
  reported (no 1.15 em widening, no baseline drop). Monochrome glyphs from an emoji font are
  drawn white (not in the text colour).
- **Typing emoji.** The macOS emoji picker (Ctrl+Cmd+Space) sends the emoji as an ordinary
  text-input event; `textField` and `textArea` insert it as it comes (a sequence longer than one
  32-byte chunk arrives in several, and is still one cluster in the buffer), edit it by cluster
  and `max_len` never keeps half of it. This was checked with synthetic events only, not with
  the real picker.

## Custom fonts, weights, resizing, list helpers

- `WindowOptions.fonts = .{ .regular = @embedFile(...), .medium = ..., .semibold = ... }` draws
  text with your own TTFs (opened from memory) instead of the system font. A missing weight
  falls back to the next lighter one. Text commands carry a `gfx.Weight`; `LabelOpts.weight`
  and `Ui.measureWeighted` / `Window.measureTextWeighted` honour it.
- `WindowOptions.resizable` / `min_width` / `min_height`, and `Window.logicalSize()` to lay out
  each frame (no resize event is needed).
- Several windows: see "Several windows" below.
- **Live resize needs a frame callback** when you drive a `Window` by hand (`vass.run` wires it for
  you). While the user drags a window edge, macOS runs its own loop and yours is blocked inside
  `pollEvent`, so nothing is drawn. Register `win.setFrameCallback(ctx, func)` (after the `Window` has
  its final address; `deinit` unregisters it); SDL calls it on the main thread from inside the event
  pump (about 60 times a second during a drag, once per distinct size), with the window's size and
  scale already refreshed. In it, draw one frame with `input.idle()` (a copy without this frame's
  click, keys or scroll, so nothing is replayed or consumed) and leave your own timers and polling to
  the main loop. It is never re-entered, never runs during `render`, and is ignored on other threads.
  `ScrollState` offsets are re-clamped to the content each frame, so a scroll area stays put (not
  jump to the top) as the window grows or shrinks.
- `Ui.chip` / `chipWidth` (small label pills, clickable via the returned `Interaction`),
  `Ui.listRow` (selected/hover highlight for a row), `Ui.labelLines` (wrap to N lines, ending
  in "..."), `Ui.flattenText` (collapse whitespace for previews), `ScrollState.reveal`
  (scroll a span into view) and `ScrollState.arrow_keys` (leave arrows to the app).

## Icons, strokes, title bar

- `DisplayList.line` / `polyline`: anti-aliased strokes with round caps (`gfx.Command.line`).
- `vass.icons`: `Icon` (sidebar, panel_right, chevrons, arrows, search, more, sliders, plus,
  arrow_up) and `icons.draw(list, icon, rect, color, weight)`, drawn from strokes at any size.
- `Ui.iconButton(rect, icon, .{ .active, .disabled })` with hover tint; `TextFieldOpts.bare`
  for a field that sits inside the app's own box.
- `Event.mouse_leave` (fed to `Input`, which then hovers nothing).
- macOS: `macos.unifiedTitleBar(handle)` (transparent title bar, content underneath),
  `macos.layoutTrafficLights(handle, bar_h, left)` (call each frame; returns where app controls
  can start) and `Window.setDragRegion(region, exclude)` so the app's header drags the window.

## Form controls and the text area

Immediate mode like the rest: the value lives in the app. Implementations are in
`src/ui/controls.zig` and `src/ui/text_area.zig`, exposed as `Ui` methods.

- `ui.checkbox(rect, &bool, "label", .{})`: box with a drawn check mark, label on the right,
  the whole row clickable; flips the bool. `.disabled`, `.size`, `.box`.
- `ui.toggle(rect, &bool, .{})`: pill switch with a knob, accent when on; flips the bool.
  `ui.toggleAt(rect, pos, hovered, opts)` draws it with the knob at `pos` (0..1) without
  reading input, so an app can animate it later.
- `ui.radio(rect, selected, "label", .{})`: reports the click; the app sets its own value.
- `ui.segmented(rect, &.{ .{ .icon = .search }, .{ .label = "Day" } }, &selected, .{})`: one
  rounded container, the selected segment raised; each `Segment` has an optional icon and/or
  label. Equal widths by default (`.equal_width = false` sizes to content). Returns true when
  the selection changed.
- `ui.textArea(rect, &area, opts) -> TextAreaResult` (`vass.ui.TextAreaState`, keep it at a
  stable address): multi-line, soft-wrapped to the width, hard newlines kept. Return inserts a
  newline, or with `opts.submit_on_enter` sets `submitted` (Shift+Return inserts one). Up/Down
  move across visual lines keeping the column, Cmd+Up/Down go to the start/end, Home/End and
  Cmd+Left/Right to the visual line edges, alt for words, shift extends. Mouse: click, drag,
  double click (word), triple click (line), dragging after either grows by words or lines, shift-click, right click (context menu). Cmd+A/C/X/V, vertical scrolling that
  follows the caret, the wheel when the content overflows, scrollbar thumb, placeholder,
  `bare`. `ui.measureTextArea(&area, width, opts)` returns the height for an auto-growing box
  (`min_lines`/`max_lines`). `TextAreaResult.input_area` and `caret_x` are for
  `Window.setTextInputArea` while it is focused. A focused text area claims the arrow keys, so
  enclosing scroll areas leave them alone. Tab leaves it unless `opts.tab_inserts`.

`zig build controls -- --snapshot DIR` draws `examples/controls.zig` (all of the above in
various states, plus a "Text input" group with a password field and a field holding combining marks and emoji) to `DIR/controls.bmp`, `DIR/controls-focus.bmp` after nine Tab presses, and then four scripted ones: `controls-text-word.bmp` (a word selected by a double click), `controls-text-composition.bmp` (a synthetic input-method pre-edit), `controls-text-menu.bmp` (the right-click menu) and `controls-text-password.bmp` (a masked field with a selection). The "Text input" group also shows the emoji and fallback-font samples (a flag, a ZWJ family, a skin tone, a keycap, a heart with U+FE0F, an emoji in a sentence, Chinese, Japanese and Korean), so `controls*.bmp` show them in colour.

Rough edges: when a word longer than the line is broken between characters, the caret at the
break shows on the next line's start (no caret affinity), so End on such a line appears to
stay put.

## Popups, menus, dropdowns and tooltips

Implemented in `src/ui/popup.zig`, exposed as `Ui` methods. Anything floating is drawn into an overlay
layer of the display list, above everything else however late it was declared, and the widgets
under it stop receiving the pointer and keys. It needs a `ui.state` (a caller-owned `State`) and a
`ui.finish()` call after the last widget of every frame (before `Window.render`):

    var ui = vass.Ui.init(&list, &window, input, .{});
    ui.state = &ustate;                       // required for popups
    ...widgets and popups...
    ui.finish();                              // merges the overlay layers, remembers popup rectangles
    window.render(&list, bg);

    var menu: vass.PopupState = .{};          // caller-owned, stable address
    if (ui.button(btn, "Actions", .{})) ui.openPopup(&menu);
    if (ui.menu(&menu, btn, &.{
        .{ .label = "New", .icon = .plus, .shortcut = "Cmd+N" },
        .{ .separator = true },
        .{ .label = "Delete", .danger = true },
    }, .{})) |i| { ... }                      // index activated this frame; it closes itself

- **`ui.beginPopup(&st, anchor, .{ w, h }, PopupOpts) ?Rect` / `ui.endPopup()`**: a panel (rounded,
  surface colour, hairline, soft shadow) of outer size `size` placed `.below`, `.above`, `.right`,
  `.left` the anchor rectangle, `.at_point` (a zero-size anchor, for context menus) or `.center` (in
  the window), aligned `start`/`center`/`end`, `gap` away; it flips to the other side when it does not
  fit and is shifted to stay 6 pt inside `ui.bounds` (the window, set by `Ui.init`; set it yourself
  for a headless Ui). Returns the content rectangle (panel inset by `padding`) while open, else null;
  call `endPopup` only after a rectangle. `bare` leaves the painting to you, `modal` dims the window and
  blocks everything beneath, `dismiss_on_outside = false` keeps it open on outside clicks. Open it with
  `ui.openPopup(&st)` (also from inside another popup), close it with `ui.closePopup(&st)`.
- **Nesting**: up to 4 deep (a dropdown inside a popover inside a dialog). Each level draws above the
  one before, even if its parent draws more widgets after it, and closes with its parent.
- **Input**: widgets that were drawn before a popup know about it from last frame's rectangles
  (`State.popups`): `Ui.hit` ignores the pointer inside a popup of a higher layer (and everywhere under
  a modal one), mouse presses, keys and typed text do not reach lower layers while a popup is open
  (`Ui.pressedNow`, `Ui.events`; the toolkit's own widgets use these, custom widgets should too). A
  press outside every open popup closes the top one and is swallowed; Escape closes the topmost and is
  consumed; the click that opens a popup cannot close it. The app's own `Input` is not changed, so
  check `ui.popupOpen()` before acting on Escape or the arrows yourself.
- **`ui.menu(&st, anchor, items, MenuOpts) ?usize`**: `MenuItem{ label, icon, shortcut, disabled,
  checked, danger, separator }`; hover highlight, Up/Down/Home/End skipping disabled items and separators,
  Enter/Space or a click activate; wheel scrolling when taller than the window. `ui.contextMenu(&st, area,
  items, opts)` opens it at the pointer on a right click inside `area` (`Input.right_pressed`); for a
  list with one shared state use `ui.contextOpen(&st, row)` per row and draw `ui.menu(&st,
  st.pointAnchor(), items, .{ .placement = .at_point })` once.
- **`ui.dropdown(rect, &DropdownState, items, &selected, DropdownOpts) bool`**: a select control with
  a chevron; the menu is as wide as the control with a check on the current item. Focusable: when
  focused and closed Up/Down change the selection and Enter/Space open it. True when `selected` changed.
- **`ui.tooltip(rect, text, TooltipOpts)`**: call after the widget; shown below (above if that does not
  fit) after the pointer has rested in `rect` for `delay` (0.5 s, from `Input.time`), hidden on leaving
  and on a press, never takes input, drawn on the top layer. `State.needsRedraw()` is true while a timer
  runs, for apps that only redraw on input.
- **`DisplayList`** gained overlay layers (`setLayer`, `mergeLayers`) and `shadow(rect, radius, blur,
  dy, color)`, a cheap soft shadow of stacked translucent rectangles.

Not there yet: two sibling popups at the same depth do not block each other; the right button only
opens and dismisses (no right-click drag); a popup that is closed by assigning `st.open = false` instead of
`closePopup` leaves popups opened from it flagged open (they are never drawn, and close when it reopens); no animation, no type-ahead in
dropdowns, no submenus (a menu item cannot open a menu, though a popover can contain widgets that open
popups). Menu items are not Tab stops (see Keyboard focus).

`zig build popups -- --snapshot DIR` writes `DIR/popups-1-tooltip.bmp`, `popups-2-menus.bmp` (a
dropdown, a menu with icons, shortcuts, separators and disabled and danger items, and a context menu,
all open), `popups-3-popover.bmp` (a dropdown inside a popover) and `popups-4-modal.bmp` (a confirm
dialog), then `popups-focus.bmp` (the modal after two Tab presses: the focus ring on its Delete
button). Interactive behaviour is covered by headless multi-frame tests; the real mouse and keyboard
path was not exercised by a human.

## Keyboard focus

Tab / Shift+Tab walk the focusable widgets, Space / Enter activate, arrows adjust. A focus ring is
drawn only when focus arrived by keyboard (a mouse press hides it until the next Tab or key).
Everything needs `ui.state` (a caller-owned `vass.ui.State`) and one `ui.finish()` per frame
(frames without `finish` work too, but then a vanished focused widget is noticed a frame late).

**Ids.** A focus id is a `u64` (`vass.FocusId`). Widgets with state use the address of their state
struct (`textField`, `textArea`, `dropdown`), value-bound ones the address of the value
(`checkbox`, `toggle`, `slider`, `segmented`, `tabs`: the `*bool`, `*f32`, `*usize`), so
`State.focus` is still a plain pointer and `state.focusOn(&field)` / `state.blur()` work as before.
Stateless widgets (`button`, `pill`, `chip`, `iconButton`, `radio`, `listRow`) derive an id:
`hash(id stack, widget kind, key)` plus the occurrence number when the same hash appears again in the
frame. The key is `opts.id` (an `idKey(x)`) if given, else the label (the icon for `iconButton`).
Rectangles are never hashed, so ids survive resizing and scrolling. Same label twice in one scope
is fine while the order is stable; wrap lists in `ui.pushId(group)` / `ui.popId()`, and give rows
that can reorder, or whose label changes, `.id = vass.ui.idKey(row.key)` (a `listRow` without an id is
numbered by position in its scope). Derived ids have bit 63 set (no address does); `State.focus` holds
them as pseudo pointers that are never dereferenced. If two widgets register the same id in a frame
the first one wins and the other is inert for the keyboard (it still works with the mouse).

**Traversal.** Every focusable widget registers itself each frame, in call order
(`ui.focusEntries()` / `State.focusEntries()`: id, rect, role, label, disabled, layer, copied labels,
up to 256 per frame). Tab moves through the *previous* frame's list, wrapping, skipping disabled
ones; with no focus Tab goes to the first and Shift+Tab to the last. The Tab key is removed from the
frame's events, so text widgets never see it. Focus on a widget that was not declared in the frame
is cleared, so a widget that is culled (an off-screen row you skip drawing) cannot be reached by Tab.
When focus moves by keyboard (or `ui.setFocus`) into scroll areas, `ScrollState.reveal` scrolls each
one (innermost first) so the widget is visible: the offset changes during that frame and shows the
next one. The tab order is the call order: draw (or at least declare) widgets in reading order.
`ui.focusNext()`, `focusPrev()`, `setFocus(id)`, `isFocused(id)`, `focusedId()`, `focusVisible()`.

**Keys.** A widget that acts on a key removes that event from the frame (`ui.takeKey`), so `ui.events()`
read afterwards does not contain it; keys it ignores stay. Code that runs before the widgets (a
shortcut handler at the top of the frame, `beginScroll` for its arrow keys) asks
`ui.keyClaimed(code, mods)`: true if the focused widget wants that key. Text widgets claim every key
without Cmd (and a, c, x, v, z, arrows, delete with it); typed text only ever goes to them.

| Widget | Focused keys |
| --- | --- |
| `button`, `pill`, `chip` (opt in, see below), `iconButton`, `listRow` | Space / Enter = click (`clicked` / true) |
| `checkbox`, `toggle` | Space / Enter flip the value |
| `radio` | Space / Enter = click (you set your value). No arrow-key group navigation: each radio is a Tab stop |
| `segmented`, `tabs` | one Tab stop; Left / Right (Home / End) change the selection and return changed |
| `slider` | Left / Down, Right / Up one step (`step`, or a twentieth); Shift = five steps; Home / End. Consumed |
| `waveform` | Left / Right seek by 5% (Shift 20%) through `res.seek`; Home / End |
| `dropdown` | Up / Down change the selection, Space / Enter open the menu |
| `textField` | Tab / Shift+Tab leave it |
| `textArea` | Tab leaves it; `opts.tab_inserts` makes plain Tab insert a tab (Shift+Tab still leaves) |

A `chip` is usually a plain label, so it only joins the Tab order with `ChipOpts.focusable = true` (the
default when `hover_fill` is set). `ButtonOpts`, `IconButtonOpts`, `ChipOpts`, `RowOpts`, `PillOpts`,
`TabsOpts`, `CheckOpts`, `ToggleOpts`, `SegmentedOpts`, `SliderOpts` have an optional `id`;
`ButtonOpts`/`RowOpts` and friends take `disabled`, `label` (for assistive technology).

**Popups.** While a popup is open Tab cycles through the widgets declared inside the topmost one
(a modal dialog: its buttons and fields); the layers beneath already get no keys. `openPopup`
remembers the focused id and the close (Escape, an outside press, `closePopup`) restores it. A menu
(and the menu of a dropdown) has no Tab stops, its items follow the Up / Down highlight: Tab is
ignored there, as in macOS menus. Tooltips never take focus.

**Ring.** `Theme.focus_ring` (default: the accent mixed with the text colour, `theme.ringColor()`),
2 pt wide, 2 pt outside the widget with a matching corner radius, drawn on top of the widget by the
widget itself (after its drawing), under the current clip. Text fields and areas keep their accent
border; the slider shows its halo until focus is visible.

**Custom widgets.** Draw, then call the primitive, which registers it and draws the ring:

    const id = ui.widgetId(1, vass.ui.idKey("Delete"), null);   // or focus.idOfPtr(&my_state)
    const f = ui.focusable(id, r, .{ .role = .button, .label = "Delete", .ring_radius = 10 });
    if (hv.clicked or f.activated) doIt();   // f.focused, f.gained, f.lost, f.visible

`FocusOpts` also has `disabled`, `ring` (false: draw `ui.focusRing(r, radius, offset)` yourself),
`activate`, `click_focus` (false when you handle the mouse), `captures_tab`. For keys other than
Space and Enter use `ui.takeKey(&.{ vass.keys.left, ... })` while `f.focused`.

Not done: radio-group arrow navigation, Tab stops or roles for menu items, a Tab order other than
call order, no accessibility calls into the OS. Tested headlessly over multiple frames
(`src/ui/focus_test.zig`); the real keyboard was not exercised by a human.

## Images, file drops and the open-file dialog

    var win = try vass.platform.Window.init(gpa, .{ ... });
    const img = try win.loadImage(png_or_jpeg_bytes);       // or loadImageFile(path) / loadImagePixels(rgba, w, h)
    // per frame:
    _ = ui.image(rect, img, .{ .fit = .cover, .radius = 12, .opacity = 0.8 });
    // or list.image(rect, img, opts) without a Ui

- **Handles.** `vass.Image = { id, width, height }` is a small value for app state;
  `img.isValid()`, `img.aspect()`, `Image.none`. `Window.loadImage(bytes)` decodes PNG, JPEG, BMP
  or GIF (first frame) and uploads a texture; `loadImageFile(path)` reads then decodes;
  `loadImagePixels(rgba, w, h)` takes straight-alpha RGBA8 (copied). Errors: `InvalidImage`
  (not an image, or corrupt), `ImageTooLarge` (over 16384 px a side or 64 Mpx, rejected from
  the header before anything is allocated), `FileReadFailed`, `TextureFailed`.
  `unloadImage(img)` frees the texture; ids are never reused, so drawing an unloaded handle (or
  one from another window, or `Image.none`) draws nothing. `hasImage`, `imageSize` query it.
- **Drawing.** `ImageOpts{ fit, radius, opacity, tint }`: `.fill` stretches, `.contain` (default)
  letterboxes, `.cover` crops, centred. `radius` rounds the drawn image (for `.contain` its own
  rectangle) as real textured geometry with an anti-aliased edge, not a mask. Opacity and tint
  multiply the image. Images obey the clip stack (`pushClip`, `beginScroll`) and show up in
  `--snapshot` output. `vass.image.place(rect, w, h, fit)` is the pure fit math (dest and source
  rectangles). `Ui.image` returns the `Interaction` of the rectangle.
- **Quality.** Textures use linear filtering and premultiplied alpha, so scaling transparent PNGs
  leaves no dark or bright halos; drawing happens in points, so Retina is sharp. Images larger
  than 2048 px are box-filtered down on upload (the handle keeps the original size). There is no
  mipmapping: a big photo drawn at thumbnail size can still look slightly aliased. JPEG EXIF
  orientation is ignored (stb does not apply it).
- **Dropped files.** The backend emits `Event.drop_begin`, `drop_position`, `file_drop`
  (`{ window, x, y, path }`) and `drop_complete`. `DropPath` holds the path inline (up to 1024 bytes;
  longer ones are ignored), so it lives as long as the event. `Input` folds them in: `drop_active`
  and `drop_x/drop_y` for a "drop here" highlight, `droppedFiles()` for this frame's files
  (up to 16 per frame). Text drops are ignored.
- **Open-file dialog.** `win.openFileDialog(.{ .filters = &.{.{ .name = "Images", .pattern = "png;jpg;jpeg" }},
  .allow_many = true })` shows the system dialog (`error.DialogBusy` if one is open or its
  result is untaken; filter strings must be literals). It finishes asynchronously, possibly on
  another thread, so poll `win.takeDialogResult(gpa)` once per frame: `null` while open, then
  `.files` (owned paths, free with `ChosenFiles.deinit(gpa)`), `.cancelled` (the user closed it) or
  `.failed` (the platform could not show it). The callback only writes into a lock-guarded slot.
- **Window / Dock icon.** `win.setIcon(rgba, w, h)` and `win.setIconEncoded(png_bytes)` use
  `SDL_SetWindowIcon`. On macOS an unbundled app (`zig build run`) has no Info.plist icon:
  `vass.macos.setDockIcon(png_bytes)` sets `NSApplication.applicationIconImage` at runtime. The
  Dock draws the image as is, so supply rounded-square artwork with its padding (about 824 px of
  art centred in a 1024 px transparent canvas).

`zig build images -- --snapshot DIR` draws `examples/images.zig` (fit modes, rounded corners,
opacity, tint, an embedded PNG with transparency and JPEG, an 8x8 and a 2400x1600 image, a scroll
clip, an Open... button and a drop target) to `DIR/images.bmp`.

Not verified by the author without a human: the native dialog and real drag-and-drop (decoding
of the SDL events and of the dialog callback is unit-tested with synthetic data).


## SVG icons

    const gear = try win.loadSvg(svg_bytes);                 // monochrome icon, tinted when drawn
    const logo = try win.loadSvgOpts(svg_bytes, .{ .color = true });   // keeps colours and gradients
    // per frame:
    ui.drawIcon(rect, gear, color);                          // or list.svgIcon(rect, gear, color)
    _ = ui.iconButton(btn, gear, .{ .icon_size = 18 });      // built-ins still work: iconButton(btn, .search, .{})
    const items = [_]vass.ui.Segment{ .{ .icon = .search }, .{ .icon = .{ .svg = gear }, .label = "Gear" } };

Design: rasterise, do not tessellate. The SVG is parsed once into paths (`svg.Doc`); on first
draw each (icon, pixel size) is rasterised to a coverage mask at exactly the device-pixel size,
uploaded as a texture and drawn through the image path, tinted. The draw rectangle is
contain-fitted, centred and snapped to whole device pixels, so a Lucide icon at 16 pt on a 2x
display is a 32x32 texture drawn 1:1. The same icon at several sizes in one frame, and at
different Retina scales, just gets one texture per size. Textures are cached (at most 192 and
24 MB, least recently used first, evicted after presenting and never one used in the frame
being presented; sizes are capped at 1024 px a side). Drawing an invalid, unloaded or foreign
handle draws nothing. It works in `--snapshot` runs like images do (the real renderer is used).

- **API.** `Window.loadSvg(bytes) !SvgIcon`, `loadSvgOpts(bytes, .{ .color = bool })`,
  `unloadSvg(icon)` (call between frames), `hasSvg`, `svgTextureCount`. Errors: `InvalidSvg`,
  `TooComplex`. `vass.SvgIcon = { id, aspect }` is a small value for app state (`none`,
  `isValid()`); `DisplayList.svgIcon(rect, icon, color)`; `Ui.drawIcon(rect, src, color)` where
  `src` is a built-in, an `SvgIcon` or an `icons.Source`.
- **`icons.Source`** is `union(enum) { builtin: Icon, svg: SvgIcon }`. `Ui.iconButton` takes
  `anytype` (an enum literal like `.search`, an `Icon` value, an `SvgIcon` or a `Source`), and
  `Segment.icon` is `?icons.Source`: `.icon = .search` still works (each built-in is also a
  declaration of `Source`, so declaration literals resolve); write `.icon = .{ .svg = x }` or
  `.icon = .from(my_icon_value)` for the rest. The `weight` of an icon button only applies to
  built-in icons; an SVG keeps its own stroke widths.
- **Monochrome vs colour.** Monochrome (the default): every painted shape counts as ink (union of
  coverage, scaled by the shape's opacity, so duotone layers with `opacity=".2"` come out
  lighter); colours are ignored and the draw colour is used, including its alpha. Colour mode
  keeps each shape's flat fill / stroke colour and gradients; the draw colour then multiplies the
  result (white = as authored) and `currentColor` is white, so it takes the draw colour.
- **Supported SVG.** `svg` (viewBox, else width/height), `g`, `path`, `line`, `polyline`,
  `polygon`, `circle`, `ellipse`, `rect` (rx/ry). The whole path grammar (M L H V C S Q T A Z,
  relative forms, implicit repeats, `1.5.5`, `-1-2`, exponents, arc flags glued to numbers, arcs
  converted to cubics). Presentation attributes, inherited from ancestors and from the root
  `svg`, also inside `style="..."` and simple `<style>` rules (`.class`, `#id`, `tag`):
  fill, stroke, stroke-width, -linecap, -linejoin, -miterlimit, fill-rule, opacity, fill-opacity,
  stroke-opacity, color, display. `transform` (matrix, translate, scale, rotate, skewX/Y) on any
  element, applied before stroking, so non-uniform scales stretch strokes like a browser.
  Colours: `none`, `currentColor`, `#rgb[a]`, `#rrggbb[aa]`, `rgb()/rgba()`, ~50 named colours.
  `linearGradient` and `radialGradient` (objectBoundingBox or userSpaceOnUse, gradientTransform,
  stops with opacity, stops inherited through `href`), in colour mode.
- **Not supported (ignored without failing).** `use`, `symbol`, `clipPath`, `mask`, `pattern`,
  `filter`, `marker`, `text`, `image`, nested `svg` viewBoxes, `stroke-dasharray`, `vector-effect`,
  `hsl()` colours, radial focal points, `spreadMethod` (always pad), CSS combinators /
  pseudo-classes / attribute selectors, `%` and `em` lengths on shapes, `preserveAspectRatio`
  (always contain, centred; the aspect comes from the viewBox), group opacity as a composite (the
  opacity is multiplied into each child, which differs where children overlap). Content inside
  `defs` and the other non-rendered containers is never drawn. A gradient set on a group and
  inherited by children works; one that references a missing id paints nothing.
- **Robust.** Malformed XML, unbalanced tags, bad path data or transforms return `InvalidSvg`;
  documents over the caps (input 4 MB, depth 48, 20 000 elements, 4 000 shapes, 200 000 points,
  64 gradients) return `TooComplex`. A truncation / byte-flip test runs the parser over mangled
  input; the rasteriser clamps coordinates and refuses over-large output instead of looping.
- **Rasteriser.** Curves are flattened with a segment count from their second differences and the
  device scale (0.08 px tolerance; round caps and joins 4x finer). Fills use exact horizontal
  coverage with 16 sub-scanlines per row (non-zero or even-odd); strokes become polygons (round,
  butt or square caps; miter with limit, round or bevel joins; closed subpaths join; zero-length
  round-capped segments become dots) that are unioned by the same non-zero fill. Vertical
  anti-aliasing has 16 levels, so a nearly horizontal edge can be off by up to ~3 %.

`zig build icons -- --snapshot DIR` draws `examples/icons.zig` to `DIR/icons.bmp`: Lucide icons
(`examples/assets/icons/lucide-*.svg`, ISC) in several colours and at 12 to 96 pt, Phosphor fill
icons (MIT), the built-in icons next to them, icon buttons and segmented controls with SVG icons,
a colour SVG, and icons at fractional positions. Licences: `LICENSE-lucide.txt`,
`LICENSE-phosphor.txt` in that folder. The tests cover the path grammar, arcs, transforms,
style inheritance, colours, malformed input, rasteriser areas (square, circle, round-capped line,
joins, even-odd), gradients and the cache policy.

## Audio, sliders and waveforms

`vass.audio` plays and records sound; `Ui.slider` and `Ui.waveform` are the two widgets that go
with it (the slider is general purpose). `zig build audio -- --snapshot DIR` draws
`examples/audio.zig`: generated tones that overlap, an embedded WAV and OGG, a looped pad with
pause and resume, a master-volume slider, a recorder with a live level meter, and a waveform of
the recording with playback, click-to-seek and Save WAV. In snapshot mode it uses SDL's silent
"dummy" audio driver and synthetic data (the level meter, the 0:06 length and the half-way
playhead are staged), so the picture needs no sound card and no microphone.

    var audio = vass.audio.Audio.init(gpa, .{});   // opens no device yet; declare it after the Window
    defer audio.deinit();
    const click = try audio.loadSound(@embedFile("click.wav"));   // WAV, OGG Vorbis or MP3, by content
    const v = try audio.play(click, .{ .volume = 0.8, .loop = false, .start = 0 });
    audio.pause(v); audio.resumeVoice(v); audio.seek(v, 1.5); audio.setVolume(v, 0.5); audio.stop(v);
    audio.position(v); audio.duration(v); audio.isPlaying(v); audio.voiceState(v); // .playing .paused .ended
    audio.setMasterVolume(0.7);

- **Sounds** are decoded float32 PCM (mono or stereo, any sample rate up to 768 kHz, at most
  256 MB) owned by the `Audio` and referred to by a small copyable `Sound` handle, like `Image`s:
  `loadSound(bytes)`, `loadSoundFile(path)`, `soundFromSamples(samples, rate, channels)` (copies),
  `soundFromPcm(pcm)` (takes ownership), `unloadSound(s)` (stops the sound's voices first, so it
  is safe while playing), `soundDuration`, `soundPcm`. Stale handles are ignored everywhere.
- **Formats.** WAV (a pure-Zig parser): integer PCM 8 (unsigned), 16, 24 and 32 bits and float
  32 / 64 bits, mono or stereo, also WAVE_FORMAT_EXTENSIBLE; tolerant of unknown and odd-sized
  chunks, streaming files whose `data` size is 0 / 0xFFFFFFFF / too big, a partial last frame and
  wrong RIFF sizes; truncated or lying headers give `InvalidAudio` / `UnsupportedFormat`, never a
  crash (tests truncate generated files at every length and feed random junk). OGG Vorbis through stb_vorbis (mono, stereo; 3 to 6
  channels are mixed down by the decoder). MP3 through dr_mp3 (mono, stereo). More than two
  channels in a WAV, A-law / mu-law and 12-bit samples are `UnsupportedFormat`. `isAudioName(name)`
  tells the extensions (`.wav .ogg .mp3`).
- **Voices.** Up to 32 at once (`play` returns `error.TooManyVoices` beyond); linear resampling
  to the 48 kHz stereo mixer; every gain change, pause, stop and seek ramps over 6 ms so none
  clicks. A `Voice` is a (slot, generation) handle: when the sound ends or is stopped it goes
  stale and every call on it is a no-op (`voiceState` says `.ended`). Finished voices free their
  own slot, so nothing needs reaping. `position()` is the mixer's read position: it runs ahead of
  the speakers by about one device buffer (1024 frames, 21 ms) plus hardware latency.
- **Recording.** `startRecording(.{ .sample_rate = 44100, .channels = 1, .max_seconds = 300 })`
  opens the default input device lazily (`error.NoDevice`, `error.PermissionDenied` when macOS
  reports the microphone as denied up front, `error.AlreadyRecording`). Then `isRecording()`,
  `recordingState()` (`.recording`, `.limit_reached`), `recordingSeconds()`, `level()` (recent peak,
  0..1 linear, with meter ballistics; `audio.meterScale(level, -50)` maps it to 0..1 on a dB scale)
  and `recordingPeak()` (a recording that stays at exactly 0 after a couple of seconds is what a
  denied or muted microphone looks like on macOS, which delivers silence instead of an error).
  `stopRecording()` returns a `Sound` (`error.EmptyRecording` if nothing arrived),
  `cancelRecording()` discards. After `max_seconds` samples are dropped and the state says so.
- **Peaks and files.** `soundPeaks(gpa, s, n)` gives `n` absolute peaks (0..1) for a waveform;
  `soundWav(gpa, s)` the sound as a 16-bit WAV; `saveWav(s, path)` writes it. The pure
  functions `audio.peaks`, `audio.encodeWav(gpa, pcm, .pcm16 | .float32)`, `audio.decode*` work on
  a `Pcm` without any `Audio`.
- **Threads.** SDL runs one callback on its audio thread whenever the playback device wants data.
  It takes a short spin lock, renders the mixer into a 512-frame stack buffer, releases the lock and
  hands the buffer to SDL: no allocation, no frees, no callbacks into the app. Every public call
  runs on the caller's thread and takes the same lock for a few instructions, so voice operations
  are atomic. Sounds live in the `Audio`'s table and voices only borrow their samples under the
  lock; `unloadSound` stops its voices first, so the audio thread never reads freed memory. Recording
  is polled instead: SDL queues the microphone in a thread-safe stream and the UI thread drains it
  in `level`, `recordingSeconds`, `update` and `stopRecording`, so the audio thread never touches
  the recording buffer and a stalled UI loses nothing. `deinit` destroys the streams (which waits
  for a callback in progress) before freeing anything.
- **Redraws.** Progress bars and meters animate on their own as long as the app keeps drawing,
  which the `.always` loop does every frame. In an `.on_demand` loop (see "Application loop") nothing
  redraws by itself: while `audio.busy()` is true (a sound is playing or the microphone is open) set
  `ctx.redrawEvery(33)` or call `ctx.requestRedraw()` from `update`, and clear it when it is not.
  `audio.update()` is optional per-frame housekeeping (drains the microphone, pauses the output
  device after 2 s of silence; the next `play` restarts it).
- **Devices and drivers.** Nothing is opened until needed: the playback device on the first
  `play`, the recording device on `startRecording`. `Options.driver = "dummy"` (or the
  `SDL_AUDIO_DRIVER=dummy` environment variable) selects SDL's dummy driver: playback runs in real
  time into nowhere and the microphone records silence. The tests use it, so `zig build test`
  makes no sound and needs no hardware. `VASS_AUDIO_REAL=1 zig build test` additionally opens the
  real output device and queues one silent (volume 0) sound as a smoke test; it never records.
  `Window.deinit` now quits only SDL's video subsystem and `Audio.deinit` its audio one, so the
  order of the two does not matter.
- **macOS microphone permission.** An app bundle that records must have `NSMicrophoneUsageDescription`
  in its Info.plist; without it macOS ends the process the moment it touches the microphone.
  The first recording makes the system show the permission prompt and, until the user answers, no
  samples arrive. `Audio.microphonePermission()` reads the authorisation status without prompting
  (`.not_determined`, `.denied`, `.granted`, `.unknown`), and `startRecording` refuses with
  `PermissionDenied` when it is `.denied`. A binary started from a terminal (`zig build run`) has no
  Info.plist: macOS attributes the request to the terminal app, which must itself have microphone
  access, and the permission is the terminal's, not the binary's; if the terminal has none the
  recording is silent. The user changes it in System Settings > Privacy & Security > Microphone.

`Ui.slider(r, &value, .{ .min, .max, .step, .disabled, .track, .thumb })` is a horizontal slider
(a track filled to a round thumb, in the look of `toggle`). Click anywhere to jump, drag the thumb
(it keeps following the pointer past the ends), and once clicked (focus lives in `ui.state`) Left /
Down and Right / Up move one step (a twentieth of the range when `step` is 0) and Home / End jump to
the ends. It returns `SliderResult{ hovered, dragging, changed, released, focused }`: use `changed`
to react to every movement and `released` to commit at the end of a drag. Values snap to multiples
of `step` from `min` (so an end that is off the grid is not reachable). Without `ui.state` a click
still jumps but there is no drag or focus.

`Ui.waveform(r, peaks, .{ .progress, .color, .played_color, .bar_width, .gap, .min_bar, .passive,
.disabled, .id })` draws `peaks` (0..1 each) as centred rounded bars filling `r`, reduced to the
bars that fit (the loudest peak in each bar's share), the bars up to `progress` in
`played_color`. It returns `WaveformResult{ hovered, clicked, dragging, released, seek }`:
`seek` is the 0..1 position under the pointer while the button went down on it or a drag that began
there continues (clamped when the pointer leaves sideways), so `if (res.seek) |f| audio.seek(v,
f * duration)` is click-to-seek and drag-to-scrub. `passive` makes it draw-only (a level history
or clip thumbnail). Drag tracking uses the address of `peaks` as its id; pass `.id` when two
waveforms share a slice.

Tests: the pure parts are unit-tested without a device: WAV parse (every sample format,
extensible, streaming sizes, odd chunks, truncation at every length, header lies, random junk),
encode/round-trip, OGG and MP3 decoding of small real files (`src/testdata/tone.ogg`, `tone.mp3`:
rate, length, pitch, truncations), peaks, levels and meter scale, the mixer (end of sound, stale
handles, overlap and slot exhaustion, looping, resampling, pause / stop fades, seeking, volume
ramps), slider and waveform behaviour. Device tests use the dummy driver.

## Licence

Vass is licensed under either of

- the MIT licence ([LICENSE-MIT](LICENSE-MIT)), or
- the Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE)),

at your option. Unless you state otherwise, any contribution you submit for inclusion in Vass is
licensed the same way, with no additional terms.

This covers Vass's own code. The libraries it builds from source (SDL3, SDL_ttf, FreeType,
HarfBuzz, libpng, zlib, stb, dr_libs) and the bundled icon sets keep their own licences; the icon licences are
in `examples/assets/icons/`.
