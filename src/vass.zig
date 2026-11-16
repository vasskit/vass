//! Vass — a GUI toolkit for Zig. This is the first vertical slice:
//! geometry, a display list, and one platform backend (SDL3).
//!
//! Layering rule: `geom` depends on nothing, `gfx` depends only on `geom`,
//! and only the backend knows about the windowing/rendering library.
//!
//! The source tree is grouped by the package each folder would become: `core/` (geometry, display
//! list, keys, image handles, PNG writer), `platform/` (SDL3 backend, macOS extras), `text/`
//! (grapheme/emoji tables, editing core, undo, emoji compositing), `layout/`, `image/` (decoders,
//! SVG, rasteriser, texture cache policy), `audio/`, `ui/` (the immediate-mode widgets) and `app/`
//! (the application loop over `platform` and `ui`).
//! The tests of every file are pulled in by the `test` block at the end of this file.
pub const geom = @import("core/geom.zig");
pub const layout = @import("layout/layout.zig");
pub const gfx = @import("core/gfx.zig");
pub const ui = @import("ui/ui.zig");
pub const popup = @import("ui/popup.zig");
pub const focus = @import("ui/focus.zig");
pub const split = @import("ui/split.zig");
pub const keys = @import("core/keys.zig");
pub const text_edit = @import("text/text_edit.zig");
pub const grapheme = @import("text/grapheme.zig");
pub const emoji = @import("text/emoji.zig");
pub const png = @import("core/png.zig");
pub const image = @import("core/image.zig");
pub const decode = @import("image/decode.zig");
pub const icons = @import("ui/icons.zig");
pub const svg = @import("image/svg.zig");
pub const raster = @import("image/raster.zig");
pub const svg_cache = @import("image/svg_cache.zig");
pub const audio = @import("audio/audio.zig");
pub const platform = @import("platform/backend_sdl.zig");
/// macOS-only extras: menu-bar item, overlay window behaviour, notch metrics.
pub const macos = @import("platform/macos.zig");
/// The application loop: windows, events, frames, redraw policy, scripted runs.
pub const app = @import("app/app.zig");

pub const Rect = geom.Rect;
pub const Color = geom.Color;
pub const Layout = layout.Layout;
pub const DisplayList = gfx.DisplayList;
pub const Audio = audio.Audio;
pub const Image = image.Image;
pub const SvgIcon = image.SvgIcon;
pub const ImageOpts = image.ImageOpts;
pub const Ui = ui.Ui;
pub const FocusId = focus.FocusId;
pub const FocusOpts = focus.FocusOpts;
pub const FocusResult = focus.FocusResult;
pub const FocusRole = focus.Role;
pub const PopupState = ui.PopupState;
pub const PopupOpts = ui.PopupOpts;
pub const MenuItem = ui.MenuItem;
pub const MenuOpts = ui.MenuOpts;
pub const DropdownState = ui.DropdownState;
pub const DropdownOpts = ui.DropdownOpts;
pub const TooltipOpts = ui.TooltipOpts;
pub const Cursor = platform.Cursor;
pub const SplitterOpts = split.SplitterOpts;
pub const SplitterResult = split.SplitterResult;
pub const SplitState = split.SplitState;
pub const TextEdit = text_edit.TextEdit;
/// Runs a program in one window: `vass.run(App, &state, .{ .window = ... })`; see `vass.app`.
pub const run = app.run;
pub const Runner = app.Runner;
pub const AppContext = app.Context;
pub const AppConfig = app.Config;

test {
    _ = text_edit;
    _ = grapheme;
    _ = emoji;
    _ = @import("text/text_compose.zig");
    _ = ui;
    _ = @import("ui/controls.zig");
    _ = @import("ui/text_area.zig");
    _ = @import("ui/popup.zig");
    _ = focus;
    _ = split;
    _ = @import("ui/focus_test.zig");
    _ = @import("ui/text_input_test.zig");
    _ = icons;
    _ = svg;
    _ = raster;
    _ = svg_cache;
    _ = gfx;
    _ = geom;
    _ = layout;
    _ = image;
    _ = decode;
    _ = audio;
    _ = @import("audio/audio_pcm.zig");
    _ = @import("audio/audio_mixer.zig");
    _ = platform;
    _ = app;
}
