# Vass

A GUI toolkit for Zig, built app-first: features are added when an app needs them.
This is the first vertical slice, driven by [Claude Buddy](../ClaudeBuddy).

## Layout

- `src/geom.zig` — rectangles and colours. Depends on nothing.
- `src/gfx.zig` — display list: drawing recorded as plain data. Depends only on `geom`.
- `src/ui.zig` — immediate-mode widgets (`vass.Ui`) and the pointer `Input`. Depends on
  `gfx` and, for text measuring and event types, the backend.
- `src/png.zig` — minimal PNG writer, for handing generated images to the OS.
- `src/backend_sdl.zig` — SDL3 windows, input, text measuring and the display-list
  renderer (text via SDL3_ttf).
- `src/macos.zig` — menu-bar item, overlay windows, Spaces behaviour and notch metrics,
  through the Objective-C runtime.

Layering rule: `geom`, `gfx` and `png` know nothing about the platform; only the backend
and `macos` do.

## Using it

Requires Zig 0.17 and `brew install sdl3 sdl3_ttf`. macOS only for now.

In your `build.zig.zon`:

    .dependencies = .{ .vass = .{ .path = "../Vass" } },

In your `build.zig`:

    const vass = b.dependency("vass", .{ .target = target, .optimize = optimize }).module("vass");

Then `@import("vass")`: create a `vass.platform.Window`, fill a `vass.DisplayList` each
frame, and call `window.render(&list, clear_color)`.

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
occlude each other. `Ui.initHeadless` builds a Ui without a window, for tests.

## Not there yet

Hover styling, focus and keyboard navigation, retained widgets, text editing and IME, accessibility, and any platform other
than macOS.
