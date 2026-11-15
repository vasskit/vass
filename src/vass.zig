//! Vass — a GUI toolkit for Zig. This is the first vertical slice:
//! geometry, a display list, and one platform backend (SDL3).
//!
//! Layering rule: `geom` depends on nothing, `gfx` depends only on `geom`,
//! and only the backend knows about the windowing/rendering library.
pub const geom = @import("geom.zig");
pub const gfx = @import("gfx.zig");
pub const ui = @import("ui.zig");
pub const keys = @import("keys.zig");
pub const text_edit = @import("text_edit.zig");
pub const png = @import("png.zig");
pub const image = @import("image.zig");
pub const decode = @import("decode.zig");
pub const icons = @import("icons.zig");
pub const platform = @import("backend_sdl.zig");
/// macOS-only extras: menu-bar item, overlay window behaviour, notch metrics.
pub const macos = @import("macos.zig");

pub const Rect = geom.Rect;
pub const Color = geom.Color;
pub const DisplayList = gfx.DisplayList;
pub const Image = image.Image;
pub const ImageOpts = image.ImageOpts;
pub const Ui = ui.Ui;
pub const TextEdit = text_edit.TextEdit;

test {
    _ = text_edit;
    _ = ui;
    _ = @import("controls.zig");
    _ = @import("text_area.zig");
    _ = icons;
    _ = gfx;
    _ = geom;
    _ = image;
    _ = decode;
    _ = platform;
}
