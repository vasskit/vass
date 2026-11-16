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
- `src/image.zig` — `Image` handles, `ImageOpts`/`Fit` and the pure fit math. No platform.
- `src/decode.zig` — PNG/JPEG/BMP/GIF decoding from memory (stb_image) to RGBA8, plus the pure
  pixel helpers (premultiply, box downscale). No platform.
- `src/svg.zig` — SVG parser (shapes, full path grammar, styles, transforms, gradients). Pure Zig.
- `src/raster.zig` — rasteriser for parsed SVGs: curve flattening, stroker, exact-area scanline
  fill, A8 masks and RGBA. Pure Zig.
- `src/svg_cache.zig` — the bounded per-(icon, pixel size) texture cache policy. Pure.
- `src/audio_pcm.zig` — `Pcm` (decoded float32 audio), WAV parse/encode, OGG Vorbis and MP3
  decoding, waveform peaks, level metering helpers. Pure: no device.
- `src/audio_mixer.zig` — the voice mixer (slots, linear resampling, gain ramps). Pure.
- `src/audio.zig` — `vass.audio.Audio`: sounds, playback voices and microphone recording on SDL3
  audio streams.
- `src/backend_sdl.zig` — SDL3 windows, input, text measuring and the display-list
  renderer (text via SDL3_ttf + FreeType).
- `src/macos.zig` — menu-bar item, overlay windows, Spaces behaviour and notch metrics,
  through the Objective-C runtime.

- `build/deps.zig` — build helpers compiling FreeType and SDL_ttf from source (SDL3 comes
  from the castholm/SDL package).

Layering rule: `geom`, `gfx`, `image`, `png`, `svg`, `raster` and `svg_cache` know nothing about the platform; only the backend
and `macos` do. (`audio_pcm` and `audio_mixer` are pure too; only `audio.zig` talks to SDL.)

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

Images are decoded by [stb_image](https://github.com/nothings/stb) (public domain / MIT),
a pinned, hashed lazy dependency in `build.zig.zon` (commit 9600522) compiled as one C file,
`src/stb_impl.c`, with only PNG, JPEG, BMP and GIF enabled. It is independent of SDL, so it is
built with `-Dsystem-sdl=true` too. It adds roughly 75 KB of code to a binary that uses images
(the linker drops it from apps that do not).

Audio decoding uses two more single-file libraries, both pinned and hashed lazy dependencies
compiled together as `src/audio_impl.c`: `stb_vorbis.c` from the same stb checkout (Ogg Vorbis,
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

- IME composition display: the backend delivers `text_editing` and `Input.composition`, but
  `textField` does not draw the pre-edit text yet. Committed IME text does work.
- Undo/redo, double/triple-click word and line selection inside `textField` (only
  `textSelectable` has them), word-wise drag extension after a double click,
  grapheme-cluster-aware caret movement (combining marks and ZWJ emoji take several presses),
  context menus. Selecting across several separate texts is not possible (one text at a time).
- Scrollbar dragging and keyboard scrolling; horizontal scrolling.
- Accessibility (no screen-reader tree), hover styling, Tab focus traversal, retained
  widgets, and any platform other than macOS.

## Custom fonts, weights, resizing, list helpers

- `WindowOptions.fonts = .{ .regular = @embedFile(...), .medium = ..., .semibold = ... }` draws
  text with your own TTFs (opened from memory) instead of the system font. A missing weight
  falls back to the next lighter one. Text commands carry a `gfx.Weight`; `LabelOpts.weight`
  and `Ui.measureWeighted` / `Window.measureTextWeighted` honour it.
- `WindowOptions.resizable` / `min_width` / `min_height`, and `Window.logicalSize()` to lay out
  each frame (no resize event is needed).
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
`src/controls.zig` and `src/text_area.zig`, exposed as `Ui` methods.

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
  double click (word), triple click (line), shift-click. Cmd+A/C/X/V, vertical scrolling that
  follows the caret, the wheel when the content overflows, scrollbar thumb, placeholder,
  `bare`. `ui.measureTextArea(&area, width, opts)` returns the height for an auto-growing box
  (`min_lines`/`max_lines`). `TextAreaResult.input_area` and `caret_x` are for
  `Window.setTextInputArea` while it is focused. A focused text area holds `State.focus`, so
  enclosing scroll areas leave the arrow keys alone.

`zig build controls -- --snapshot DIR` draws `examples/controls.zig` (all of the above in
various states) to `DIR/controls.bmp`.

Rough edges: when a word longer than the line is broken between characters, the caret at the
break shows on the next line's start (no caret affinity), so End on such a line appears to
stay put; IME pre-edit text is not drawn; no undo.

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
- **Redraws.** Vass has no blocking event wait: the app owns its loop (`pollEvent`, draw, sleep),
  so progress bars and meters animate on their own as long as the app keeps drawing, which the
  examples and Habor do every frame. For an app that redraws only on input, `audio.busy()` is
  true while a sound is playing or the microphone is open: keep drawing frames while it is.
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
