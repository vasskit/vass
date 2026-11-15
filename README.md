# Vass

A GUI toolkit for Zig, built app-first: features are added when an app needs them.
This is the first vertical slice, driven by [Claude Buddy](../ClaudeBuddy).

## Layout

- `src/geom.zig` — rectangles and colours. Depends on nothing.
- `src/gfx.zig` — display list: drawing recorded as plain data. Depends only on `geom`.
- `src/ui.zig` — immediate-mode widgets (`vass.Ui`) and the pointer `Input`. Depends on
  `gfx` and, for text measuring and event types, the backend.
- `src/keys.zig` — modifier flags and keycode constants. Depends on nothing.
- `src/text_edit.zig` — `TextEdit`: the pure text editing core (buffer, cursor, selection,
  key handling). No rendering, no SDL.
- `src/png.zig` — minimal PNG writer, for handing generated images to the OS.
- `src/backend_sdl.zig` — SDL3 windows, input, text measuring and the display-list
  renderer (text via SDL3_ttf + FreeType).
- `src/macos.zig` — menu-bar item, overlay windows, Spaces behaviour and notch metrics,
  through the Objective-C runtime.

- `build/deps.zig` — build helpers compiling FreeType and SDL_ttf from source (SDL3 comes
  from the castholm/SDL package).

Layering rule: `geom`, `gfx` and `png` know nothing about the platform; only the backend
and `macos` do.

## Using it

Requires Zig 0.17 and Xcode (or the Command Line Tools) for the macOS SDK. macOS only for
now. Nothing else needs installing: SDL3 3.4.20, SDL_ttf 3.2.2, FreeType 2.14.3 and
HarfBuzz 15.1.0 are fetched as pinned dependencies (`build.zig.zon`), compiled from source by
the Zig build and linked statically, so an app is a single binary that links only system
frameworks and libSystem/libobjc. HarfBuzz is C++ (single-file amalgamation); Zig builds it
with its bundled libc++, so no C++ toolchain is needed either. The first build compiles
SDL3 and HarfBuzz (about 40 s); later builds reuse the cache.

SDL_ttf uses HarfBuzz for shaping (including AAT `trak` tracking), so text measures and
renders identically to Homebrew's build. It is built without PlutoSVG (no colour SVG
emoji); FreeType is built without zlib/bzip2/png/brotli (no WOFF2/PNG-bitmap fonts) and
HarfBuzz without CoreText/ICU/GLib.

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

## Text input, scrolling, wrapping

Widgets that need memory across frames take a caller-owned state struct; there is no hidden
per-widget state. Keyboard focus lives in a caller-owned `vass.ui.State`:

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

- **`textField`**: single line. Click to focus (and place the caret), drag or shift-click to
  select, Escape or a click elsewhere to blur, Return reports `submitted`. Arrows, home/end,
  alt for words, cmd for line ends, shift to select, cmd+A/C/X/V, backspace/delete (with alt
  or cmd for word/line). Scrolls horizontally to keep the caret visible, blinks off
  `Input.time`, and is clipped to its rectangle. Typed text arrives through
  `Input.events()` in order with key presses; apps with their own shortcuts should ignore
  keys while `ustate.focus != null`.
- **`TextEdit`** (`vass.TextEdit`) is the editor behind it and usable on its own:
  `insert`, `backspace`, `delete`, `move`, `moveTo`, `selectAll`, `copy`/`cut`, and
  `handleKey(code, mods) -> Action` (changed / copy / cut / paste / submit / cancel ...).
  Offsets are bytes on UTF-8 code point boundaries; clipboard access stays with the caller.
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
  wrapped lines and newlines; double-click = word, triple-click = line, shift-click extends),
  copied with Cmd+C through the clipboard hook, Cmd+A to select all of it, Escape or a click
  elsewhere to clear. One selection per `Ui.state` (`State.select`, separate from `focus`, so it
  does not block arrow-key scrolling); starting another, or focusing a text field, clears it. Keep
  one `vass.ui.SelectState` per text at a stable address and call `sel.clear()` when the string
  changes (offsets are clamped defensively anyway). A selection is cleared by a click elsewhere
  only while its text is being drawn. `Ui.offsetAtPoint(str, size, max_w, x, y)` is the pure
  point-to-byte-offset helper behind it. `Input.mouse_clicks` carries the OS click count.
- **Backend**: events `mouse_up`, `mouse_wheel` (lines), `text_input`, `text_editing`,
  `key_down`/`key_up` (a `Key` with `code`, `mods`, `repeat`), plus
  `Window.startTextInput/stopTextInput/setTextInputArea` and `clipboardText`/`setClipboardText`.

## Example: notes

`examples/notes.zig` is a small notes app (scrolling wrapped cards, a text field, Return
adds a note; in memory only).

    zig build notes                                  # run it
    zig build notes -- --snapshot DIR                # save DIR/notes.bmp and exit
    zig build notes -- --snapshot DIR --script       # same after scripted input: click the
                                                     # field, type, select all, scroll,
                                                     # drag-select across two lines of a card

## Not there yet

- Multi-line text area. `TextEdit` already handles line breaks (`multiline`), home/end per
  line and line deletion; what is missing is the widget: wrapping the buffer into visual
  lines, mapping caret/selection to them, up/down movement with a remembered column, vertical
  scrolling to the caret, and per-line selection rectangles.
- IME composition display: the backend delivers `text_editing` and `Input.composition`, but
  `textField` does not draw the pre-edit text yet. Committed IME text does work.
- Undo/redo, double/triple-click word and line selection inside `textField` (only
  `textSelectable` has them), word-wise drag extension after a double click,
  grapheme-cluster-aware caret movement (combining marks and ZWJ emoji take several presses),
  context menus. Selecting across several separate texts is not possible (one text at a time).
- Scrollbar dragging and keyboard scrolling; horizontal scrolling.
- Accessibility (no screen-reader tree), hover styling, Tab focus traversal, retained
  widgets, and any platform other than macOS.
