# Vass

A GUI toolkit for Zig, built app-first: features are added when an app needs them.
This is the first vertical slice, driven by [Claude Buddy](../ClaudeBuddy).

## Layout

- `src/geom.zig` — rectangles and colours. Depends on nothing.
- `src/gfx.zig` — display list: drawing recorded as plain data. Depends only on `geom`.
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

## Not there yet

Layout, retained widgets, text editing and IME, accessibility, and any platform other
than macOS.
