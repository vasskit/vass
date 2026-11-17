//! SDL3 backend: windows (any number, see `Window`), input events, and a display-list renderer.
//! SDL is declared by hand (only what is used) so the build needs no C headers.
const std = @import("std");
const builtin = @import("builtin");
const geom = @import("../core/geom.zig");
const gfx = @import("../core/gfx.zig");
const Color = geom.Color;
const keys = @import("../core/keys.zig");
const image_mod = @import("../core/image.zig");
const decode_mod = @import("../image/decode.zig");
const svg_mod = @import("../image/svg.zig");
const raster_mod = @import("../image/raster.zig");
const svg_cache = @import("../image/svg_cache.zig");
const emoji_mod = @import("../text/emoji.zig");
const compose = @import("../text/text_compose.zig");
pub const Image = image_mod.Image;
pub const ImageOpts = image_mod.ImageOpts;
pub const SvgIcon = image_mod.SvgIcon;

const c = struct {
    const SdlWindow = opaque {};
    const Renderer = opaque {};
    const Texture = opaque {};
    const Surface = opaque {};
    const Font = opaque {};
    const SdlCursor = opaque {};
    const FRect = extern struct { x: f32, y: f32, w: f32, h: f32 };
    const FPoint = extern struct { x: f32, y: f32 };
    const FColor = extern struct { r: f32, g: f32, b: f32, a: f32 };
    const SdlColor = extern struct { r: u8, g: u8, b: u8, a: u8 };
    const Vertex = extern struct { position: FPoint, color: FColor, tex_coord: FPoint };
    const SdlEvent = extern union { type: u32, raw: [128]u8, force_align: u64 };

    const INIT_VIDEO: u32 = 0x20;
    const SdlRect = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };
    const WINDOW_HIDDEN: u64 = 0x8;
    const WINDOW_RESIZABLE: u64 = 0x20;
    const IOStream = opaque {};
    const WINDOW_BORDERLESS: u64 = 0x10;
    const WINDOW_HIGH_PIXEL_DENSITY: u64 = 0x2000;
    const WINDOW_ALWAYS_ON_TOP: u64 = 0x10000;
    const WINDOW_TRANSPARENT: u64 = 0x40000000;
    const WINDOW_NOT_FOCUSABLE: u64 = 0x80000000;
    const EVENT_WINDOW_CLOSE_REQUESTED: u32 = 0x210;
    const EVENT_QUIT: u32 = 0x100;
    const EVENT_USER: u32 = 0x8000;
    const EVENT_KEY_DOWN: u32 = 0x300;
    const EVENT_KEY_UP: u32 = 0x301;
    const EVENT_TEXT_EDITING: u32 = 0x302;
    const EVENT_TEXT_INPUT: u32 = 0x303;
    const EVENT_MOUSE_MOTION: u32 = 0x400;
    const EVENT_MOUSE_BUTTON_DOWN: u32 = 0x401;
    const EVENT_MOUSE_BUTTON_UP: u32 = 0x402;
    const EVENT_MOUSE_WHEEL: u32 = 0x403;
    const EVENT_WINDOW_MOUSE_LEAVE: u32 = 0x20D;
    const EVENT_WINDOW_FOCUS_GAINED: u32 = 0x20E;
    const EVENT_WINDOW_FOCUS_LOST: u32 = 0x20F;
    const EVENT_WINDOW_EXPOSED: u32 = 0x204;
    const EVENT_WINDOW_RESIZED: u32 = 0x206;
    const EVENT_WINDOW_PIXEL_SIZE_CHANGED: u32 = 0x207;
    const EventWatch = *const fn (userdata: ?*anyopaque, event: *SdlEvent) callconv(.c) bool;
    const SdlPoint = extern struct { x: c_int, y: c_int };
    const HitTest = *const fn (w: *SdlWindow, area: *const SdlPoint, data: ?*anyopaque) callconv(.c) c_int;
    const KMOD_SHIFT: u16 = 0x0003;
    const KMOD_CTRL: u16 = 0x00C0;
    const KMOD_ALT: u16 = 0x0300;
    const KMOD_GUI: u16 = 0x0C00;
    const BLENDMODE_BLEND: u32 = 1;
    const BLENDMODE_BLEND_PREMULTIPLIED: u32 = 0x10;
    const PIXELFORMAT_RGBA32: u32 = 0x16762004; // ABGR8888: bytes R,G,B,A in memory on little-endian
    const TEXTUREACCESS_STATIC: c_int = 0;
    const SCALEMODE_LINEAR: c_int = 1;
    const EVENT_DROP_FILE: u32 = 0x1000;
    const EVENT_DROP_TEXT: u32 = 0x1001;
    const EVENT_DROP_BEGIN: u32 = 0x1002;
    const EVENT_DROP_COMPLETE: u32 = 0x1003;
    const EVENT_DROP_POSITION: u32 = 0x1004;
    const DialogFilter = extern struct { name: [*:0]const u8, pattern: [*:0]const u8 };
    const DialogCallback = *const fn (userdata: ?*anyopaque, filelist: ?[*:null]const ?[*:0]const u8, filter: c_int) callconv(.c) void;

    extern fn SDL_Init(flags: u32) bool;
    extern fn SDL_QuitSubSystem(flags: u32) void;
    extern fn SDL_GetError() [*:0]const u8;
    extern fn SDL_Delay(ms: u32) void;
    extern fn SDL_GetTicks() u64;
    // SDL_mouse.h (SDL 3.4): SDL_SystemCursor ids are DEFAULT 0, TEXT 1, WAIT 2, CROSSHAIR 3, PROGRESS 4,
    // NWSE_RESIZE 5, NESW_RESIZE 6, EW_RESIZE 7, NS_RESIZE 8, MOVE 9, NOT_ALLOWED 10, POINTER 11.
    extern fn SDL_CreateSystemCursor(id: c_int) ?*SdlCursor;
    extern fn SDL_SetCursor(cursor: ?*SdlCursor) bool;
    extern fn SDL_DestroyCursor(cursor: *SdlCursor) void;
    extern fn SDL_CreateWindow(title: [*:0]const u8, w: c_int, h: c_int, flags: u64) ?*SdlWindow;
    extern fn SDL_DestroyWindow(w: *SdlWindow) void;
    extern fn SDL_GetWindowPixelDensity(w: *SdlWindow) f32;
    extern fn SDL_SetWindowAlwaysOnTop(w: *SdlWindow, on_top: bool) bool;
    extern fn SDL_SetWindowTitle(w: *SdlWindow, title: [*:0]const u8) bool;
    extern fn SDL_GetWindowPosition(w: *SdlWindow, x: *c_int, y: *c_int) bool;
    extern fn SDL_GetMouseFocus() ?*SdlWindow;
    extern fn SDL_GetKeyboardFocus() ?*SdlWindow;
    extern fn SDL_TextInputActive(w: *SdlWindow) bool;
    extern fn SDL_CreateRenderer(w: *SdlWindow, name: ?[*:0]const u8) ?*Renderer;
    extern fn SDL_DestroyRenderer(r: *Renderer) void;
    extern fn SDL_SetRenderVSync(r: *Renderer, vsync: c_int) bool;
    extern fn SDL_SetRenderScale(r: *Renderer, sx: f32, sy: f32) bool;
    extern fn SDL_SetRenderDrawBlendMode(r: *Renderer, mode: u32) bool;
    extern fn SDL_SetRenderDrawColor(r: *Renderer, red: u8, g: u8, b: u8, a: u8) bool;
    extern fn SDL_RenderClear(r: *Renderer) bool;
    extern fn SDL_RenderPresent(r: *Renderer) bool;
    extern fn SDL_RenderGeometry(r: *Renderer, tex: ?*Texture, verts: [*]const Vertex, n: c_int, idx: ?[*]const c_int, n_idx: c_int) bool;
    extern fn SDL_RenderTexture(r: *Renderer, tex: *Texture, src: ?*const FRect, dst: ?*const FRect) bool;
    extern fn SDL_CreateTextureFromSurface(r: *Renderer, s: *Surface) ?*Texture;
    extern fn SDL_GetTextureSize(t: *Texture, w: *f32, h: *f32) bool;
    extern fn SDL_DestroyTexture(t: *Texture) void;
    extern fn SDL_DestroySurface(s: *Surface) void;
    extern fn SDL_RenderReadPixels(r: *Renderer, rect: ?*const anyopaque) ?*Surface;
    extern fn SDL_SaveBMP(s: *Surface, file: [*:0]const u8) bool;
    extern fn SDL_GetGlobalMouseState(x: *f32, y: *f32) u32;
    extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) bool;
    extern fn SDL_GetPrimaryDisplay() u32;
    extern fn SDL_GetDisplayBounds(display: u32, rect: *SdlRect) bool;
    extern fn SDL_GetDisplayUsableBounds(display: u32, rect: *SdlRect) bool;
    extern fn SDL_GetWindowID(w: *SdlWindow) u32;
    extern fn SDL_GetWindowProperties(w: *SdlWindow) u32;
    extern fn SDL_GetPointerProperty(props: u32, name: [*:0]const u8, default: ?*anyopaque) ?*anyopaque;
    extern fn SDL_SetWindowHitTest(w: *SdlWindow, cb: ?HitTest, data: ?*anyopaque) bool;
    extern fn SDL_GetWindowSize(w: *SdlWindow, width: *c_int, height: *c_int) bool;
    extern fn SDL_GetWindowSizeInPixels(w: *SdlWindow, width: *c_int, height: *c_int) bool;
    extern fn SDL_SetWindowSize(w: *SdlWindow, width: c_int, height: c_int) bool;
    extern fn SDL_AddEventWatch(filter: EventWatch, userdata: ?*anyopaque) bool;
    extern fn SDL_RemoveEventWatch(filter: EventWatch, userdata: ?*anyopaque) void;
    extern fn SDL_GetCurrentThreadID() u64;
    extern fn SDL_PushEvent(e: *SdlEvent) bool;
    extern fn SDL_SetWindowMinimumSize(w: *SdlWindow, min_w: c_int, min_h: c_int) bool;
    extern fn SDL_IOFromConstMem(mem: *const anyopaque, size: usize) ?*IOStream;
    extern fn TTF_OpenFontIO(src: *IOStream, closeio: bool, ptsize: f32) ?*Font;
    extern fn SDL_SetWindowPosition(w: *SdlWindow, x: c_int, y: c_int) bool;
    extern fn SDL_ShowWindow(w: *SdlWindow) bool;
    extern fn SDL_HideWindow(w: *SdlWindow) bool;
    extern fn SDL_RaiseWindow(w: *SdlWindow) bool;
    extern fn SDL_PollEvent(e: *SdlEvent) bool;
    extern fn SDL_WaitEvent(e: *SdlEvent) bool;
    extern fn SDL_WaitEventTimeout(e: *SdlEvent, timeout_ms: i32) bool;
    extern fn SDL_StartTextInput(w: *SdlWindow) bool;
    extern fn SDL_StopTextInput(w: *SdlWindow) bool;
    extern fn SDL_SetTextInputArea(w: *SdlWindow, rect: ?*const SdlRect, cursor: c_int) bool;
    extern fn SDL_GetModState() u16;
    extern fn SDL_GetClipboardText() ?[*:0]u8;
    extern fn SDL_SetClipboardText(text: [*:0]const u8) bool;
    extern fn SDL_free(p: ?*anyopaque) void;
    extern fn SDL_CreateTexture(r: *Renderer, format: u32, access: c_int, w: c_int, h: c_int) ?*Texture;
    extern fn SDL_UpdateTexture(t: *Texture, rect: ?*const SdlRect, pixels: *const anyopaque, pitch: c_int) bool;
    extern fn SDL_SetTextureBlendMode(t: *Texture, mode: u32) bool;
    extern fn SDL_SetTextureScaleMode(t: *Texture, mode: c_int) bool;
    extern fn SDL_GetTextureBlendMode(t: *Texture, mode: *u32) bool;
    const PathInfo = extern struct { kind: c_int, size: u64, create_time: i64, modify_time: i64, access_time: i64 };
    const PATHTYPE_FILE: c_int = 1;
    extern fn SDL_GetPathInfo(path: [*:0]const u8, info: *PathInfo) bool;
    extern fn SDL_LoadFile(file: [*:0]const u8, datasize: *usize) ?*anyopaque;
    extern fn SDL_CreateSurfaceFrom(w: c_int, h: c_int, format: u32, pixels: *anyopaque, pitch: c_int) ?*Surface;
    extern fn SDL_SetWindowIcon(w: *SdlWindow, icon: *Surface) bool;
    extern fn SDL_ShowOpenFileDialog(cb: DialogCallback, userdata: ?*anyopaque, w: ?*SdlWindow, filters: ?[*]const DialogFilter, n: c_int, default_location: ?[*:0]const u8, allow_many: bool) void;
    extern fn SDL_SetRenderClipRect(r: *Renderer, rect: ?*const SdlRect) bool;
    extern fn SDL_GetRendererProperties(r: *Renderer) u32;
    extern fn SDL_GetNumberProperty(props: u32, name: [*:0]const u8, default: i64) i64;
    extern fn TTF_Init() bool;
    extern fn TTF_Quit() void;
    extern fn TTF_OpenFont(file: [*:0]const u8, ptsize: f32) ?*Font;
    extern fn TTF_CloseFont(f: *Font) void;
    extern fn TTF_GetStringSize(f: *Font, text: [*]const u8, len: usize, w: *c_int, h: *c_int) bool;
    extern fn TTF_RenderText_Blended(f: *Font, text: [*]const u8, len: usize, fg: SdlColor) ?*Surface;
    extern fn TTF_FontHasGlyph(f: *Font, ch: u32) bool;
    extern fn TTF_GetFontHeight(f: *Font) c_int;
    extern fn TTF_GetFontAscent(f: *Font) c_int;
    extern fn TTF_FontIsScalable(f: *Font) bool;
    extern fn TTF_SetFontSize(f: *Font, ptsize: f32) bool;
    extern fn TTF_AddFallbackFont(f: *Font, fallback: *Font) bool;
    /// The start of `SDL_Surface` (SDL 3.4), enough to read the pixels SDL_ttf drew.
    const SurfaceHeader = extern struct { flags: u32, format: u32, w: c_int, h: c_int, pitch: c_int, pixels: ?[*]u8 };
    const PIXELFORMAT_ARGB8888: u32 = 0x16362004;
};

/// UTF-8 text from the keyboard or an input method, copied out of the SDL
/// event. A long commit (e.g. a big IME string) arrives as several chunks, each
/// ending on a character boundary.
pub const TextChunk = struct {
    buf: [32]u8 = undefined,
    len: u8 = 0,

    pub fn slice(t: *const TextChunk) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn from(str: []const u8) TextChunk {
        var t: TextChunk = .{};
        const n = @min(str.len, t.buf.len);
        @memcpy(t.buf[0..n], str[0..n]);
        t.len = @intCast(n);
        return t;
    }
};

/// Where the `TextChunk` that starts at `str[start]` ends: after at most `TextChunk.buf.len`
/// bytes, on a character boundary (unless one character alone does not fit). Splits a longer
/// string into the chunks the platform delivers it in.
pub fn textChunkEnd(str: []const u8, start: usize) usize {
    var end = @min(start + @sizeOf(@FieldType(TextChunk, "buf")), str.len);
    if (end < str.len) {
        while (end > start + 1 and str[end] & 0xC0 == 0x80) end -= 1;
    }
    return end;
}

/// An in-progress input-method composition ("preedit" text).
pub const Composition = struct {
    buf: [96]u8 = undefined,
    len: u8 = 0,
    /// Cursor and selection inside the composition, in code points (SDL reports UTF-32 units on
    /// macOS), not bytes; -1 if not set. `start` is the cursor, `length` the highlighted run.
    start: i32 = -1,
    length: i32 = -1,

    pub fn slice(t: *const Composition) []const u8 {
        return t.buf[0..t.len];
    }
};

pub const Key = struct {
    /// SDL keycode; for printable keys this is the lowercase ASCII value
    /// (see `keys` for named constants).
    code: u32,
    mods: keys.Mods = .{},
    /// True for auto-repeat events while the key is held.
    repeat: bool = false,
    /// The window that had keyboard focus (0 if none).
    window: u32 = 0,
};

pub const Event = union(enum) {
    /// The application was asked to quit (Cmd+Q, or the last window closed).
    quit,
    /// A window's close button (or Cmd+W where the app maps it) was pressed; payload is the
    /// window id. Nothing is closed by it: the app decides which window to destroy. Distinct
    /// from `quit` (the whole app was asked to quit, or the last window was closed).
    close_requested: u32,
    /// `button` is 1 for left, 2 for middle, 3 for right. `mods` are the
    /// modifiers held at that moment (for shift-click).
    mouse_down: struct { window: u32, x: f32, y: f32, button: u8, mods: keys.Mods = .{}, clicks: u8 = 1 },
    mouse_up: struct { window: u32, x: f32, y: f32, button: u8 },
    mouse_move: struct { window: u32, x: f32, y: f32 },
    /// Scroll amount in "lines" (SDL's unit; trackpads deliver fractions).
    /// `dy` > 0 means the content should move down, i.e. scroll towards the
    /// start (wheel rolled away from the user). `dx` > 0 is towards the right.
    mouse_wheel: struct { window: u32, dx: f32, dy: f32 },
    /// The pointer left the window (hover states should end); payload is the window id.
    mouse_leave: u32,
    key_down: Key,
    key_up: Key,
    /// Typed or committed text. Only sent while text input is started
    /// (`Window.startTextInput`).
    text_input: struct { window: u32, text: TextChunk },
    /// Input-method composition changed; an empty string means it ended.
    text_editing: struct { window: u32, comp: Composition },
    /// The window gained keyboard focus; payload is the window id.
    focus_gained: u32,
    /// The window lost keyboard focus (another window or app was activated); payload is the window id.
    /// A button that was held may never report its release to this window.
    focus_lost: u32,
    /// A drag from another app entered the window (a new set of drops begins).
    drop_begin: u32,
    /// The dragged items moved over the window (window points).
    drop_position: struct { window: u32, x: f32, y: f32 },
    /// A file was dropped. The path is copied into the event, so it stays valid
    /// as long as the event does. Several files arrive as several events,
    /// followed by `drop_complete`.
    file_drop: struct { window: u32, x: f32, y: f32, path: DropPath },
    /// The drag ended (after the last file, or because it left the window).
    drop_complete: u32,
};

/// A file path from a drop event, copied out of SDL's event memory.
pub const DropPath = struct {
    buf: [1024]u8 = undefined,
    len: u16 = 0,

    pub fn slice(p: *const DropPath) []const u8 {
        return p.buf[0..p.len];
    }

    /// Null if `str` does not fit.
    pub fn from(str: []const u8) ?DropPath {
        var p: DropPath = .{};
        if (str.len == 0 or str.len > p.buf.len) return null;
        @memcpy(p.buf[0..str.len], str);
        p.len = @intCast(str.len);
        return p;
    }
};

/// Decodes a raw SDL drop event (`SDL_DropEvent` layout: window id at 16, x/y at
/// 20/24, the data string pointer at 40). Null for other event types, for text
/// drops, and for paths longer than `DropPath` holds.
pub fn decodeDropEvent(ev_type: u32, raw: []const u8) ?Event {
    const window = std.mem.readInt(u32, raw[16..20], .little);
    switch (ev_type) {
        c.EVENT_DROP_BEGIN => return .{ .drop_begin = window },
        c.EVENT_DROP_COMPLETE => return .{ .drop_complete = window },
        c.EVENT_DROP_POSITION => return .{ .drop_position = .{ .window = window, .x = readF32(raw, 20), .y = readF32(raw, 24) } },
        c.EVENT_DROP_FILE => {
            const path = DropPath.from(eventString(raw, 40)) orelse return null;
            return .{ .file_drop = .{ .window = window, .x = readF32(raw, 20), .y = readF32(raw, 24), .path = path } };
        },
        else => return null,
    }
}

// ---- open-file dialog -----------------------------------------------------

/// One entry of the dialog's file-type menu. `pattern` lists extensions
/// separated by `;` without dots, e.g. `"png;jpg;jpeg"` (or `"*"` for all).
/// Both strings must outlive the dialog: use literals.
pub const FileFilter = struct { name: [*:0]const u8, pattern: [*:0]const u8 };

pub const FileDialogOptions = struct {
    filters: []const FileFilter = &.{},
    allow_many: bool = false,
    default_location: ?[*:0]const u8 = null,
};

/// The files the user picked. Free with `deinit` using the allocator given to
/// `takeDialogResult`.
pub const ChosenFiles = struct {
    paths: [][]u8,

    pub fn deinit(f: ChosenFiles, gpa: std.mem.Allocator) void {
        for (f.paths) |p| gpa.free(p);
        gpa.free(f.paths);
    }
};

/// How a dialog ended. `cancelled` (the user closed it) is not `failed` (the
/// platform could not show it, or reported an error).
pub const DialogResult = union(enum) {
    files: ChosenFiles,
    cancelled,
    failed,
};

/// What the SDL callback leaves behind, possibly from another thread. Paths are
/// stored NUL-separated in memory from the C allocator, so the callback needs no
/// Zig allocator; `takeDialogResult` moves them into the caller's allocator.
const RawDialog = struct { kind: enum { files, cancelled, failed }, data: []u8, count: usize };
var dialog_lock: std.atomic.Value(bool) = .init(false);
var dialog_pending: bool = false; // a dialog is open (guarded by the lock)
var dialog_done: ?RawDialog = null; // its result, until taken (guarded by the lock)
var dialog_filters: [8]c.DialogFilter = undefined;
/// The window (id) that opened the open dialog; only it can take the result. Main thread only.
var dialog_owner: u32 = 0;
/// The owner went away while the dialog was open: its result is dropped when it arrives (guarded by the lock).
var dialog_orphaned: bool = false;

fn lockDialog() void {
    while (dialog_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockDialog() void {
    dialog_lock.store(false, .release);
}

fn dialogCallback(_: ?*anyopaque, list: ?[*:null]const ?[*:0]const u8, _: c_int) callconv(.c) void {
    var raw: RawDialog = .{ .kind = .failed, .data = &.{}, .count = 0 };
    if (list) |l| {
        if (l[0] == null) {
            raw.kind = .cancelled;
        } else {
            var total: usize = 0;
            var n: usize = 0;
            while (l[n]) |p| : (n += 1) total += std.mem.span(p).len + 1;
            if (std.heap.c_allocator.alloc(u8, total)) |buf| {
                var off: usize = 0;
                for (0..n) |i| {
                    const s = std.mem.span(l[i].?);
                    @memcpy(buf[off..][0..s.len], s);
                    buf[off + s.len] = 0;
                    off += s.len + 1;
                }
                raw = .{ .kind = .files, .data = buf, .count = n };
            } else |_| {}
        }
    }
    lockDialog();
    dialog_pending = false;
    if (dialog_orphaned) {
        dialog_orphaned = false;
        unlockDialog();
        if (raw.data.len > 0) std.heap.c_allocator.free(raw.data);
        return;
    }
    dialog_done = raw;
    unlockDialog();
}

/// A window is going away: its dialog result (finished or still to come) must not stay behind,
/// or no window could ever open another dialog.
fn discardDialogOf(window_id: u32) void {
    lockDialog();
    defer unlockDialog();
    if (dialog_owner != window_id) return;
    dialog_owner = 0;
    if (dialog_done) |raw| {
        dialog_done = null;
        if (raw.data.len > 0) std.heap.c_allocator.free(raw.data);
    } else if (dialog_pending) {
        dialog_orphaned = true;
    }
}

/// Moves a finished dialog's result out of the shared slot (without touching SDL).
fn takeRawDialog(gpa: std.mem.Allocator) error{OutOfMemory}!?DialogResult {
    lockDialog();
    const raw = dialog_done orelse {
        unlockDialog();
        return null;
    };
    dialog_done = null;
    unlockDialog();
    defer if (raw.data.len > 0) std.heap.c_allocator.free(raw.data);
    switch (raw.kind) {
        .cancelled => return .cancelled,
        .failed => return .failed,
        .files => {
            const paths = try gpa.alloc([]u8, raw.count);
            var made: usize = 0;
            errdefer {
                for (paths[0..made]) |p| gpa.free(p);
                gpa.free(paths);
            }
            var it = std.mem.splitScalar(u8, raw.data, 0);
            while (made < raw.count) : (made += 1) paths[made] = try gpa.dupe(u8, it.next().?);
            return .{ .files = .{ .paths = paths } };
        },
    }
}

/// Test hook: leaves `list` as the SDL callback would.
fn deliverDialogForTest(list: ?[*:null]const ?[*:0]const u8) void {
    lockDialog();
    dialog_pending = true;
    unlockDialog();
    dialogCallback(null, list, 0);
}

/// TrueType font data to draw text with instead of the system fonts. The
/// bytes must stay valid for the life of the window (embed them with
/// `@embedFile`). A weight left null is drawn with `regular`.
pub const FontSet = struct {
    regular: []const u8,
    medium: ?[]const u8 = null,
    semibold: ?[]const u8 = null,

    pub fn forWeight(f: FontSet, weight: gfx.Weight) []const u8 {
        return switch (weight) {
            .regular => f.regular,
            .medium => f.medium orelse f.regular,
            .semibold => f.semibold orelse f.medium orelse f.regular,
        };
    }
};

/// A font file for `WindowOptions.fallback_fonts` or `WindowOptions.emoji_font`: a TrueType or
/// OpenType font (a collection's first face), as embedded bytes or a file on disk.
pub const FontSource = union(enum) {
    /// The font file's bytes; they must stay valid for the life of the window (`@embedFile`).
    bytes: []const u8,
    /// Path of a font file, read when the font is first needed.
    path: [:0]const u8,
};

pub const WindowOptions = struct {
    title: [*:0]const u8,
    width: u32,
    height: u32,
    always_on_top: bool = false,
    /// No title bar or frame.
    borderless: bool = false,
    /// The window background is see-through; clear with an alpha of 0.
    transparent: bool = false,
    /// Start hidden; call `show` later.
    hidden: bool = false,
    /// If false the window never takes keyboard focus (for overlays).
    focusable: bool = true,
    /// Custom fonts; null uses the system font.
    fonts: ?FontSet = null,
    /// Fonts tried, in order, for a character the UI font has no glyph for (a script it does not
    /// cover, symbols), before the system's own fallbacks. Opened the first time a string needs
    /// one. The slice, and the bytes of any `.bytes` source, must stay valid for the life of the
    /// window.
    fallback_fonts: []const FontSource = &.{},
    /// Also try the fonts macOS ships for symbols, Chinese, Japanese and Korean after
    /// `fallback_fonts`. Has no effect on other systems (nothing is known to be installed).
    system_fallback_fonts: bool = true,
    /// Draw emoji in colour. The font is the system's colour emoji font (Apple Color Emoji on
    /// macOS) unless `emoji_font` names another. Without a usable font, emoji draw as the UI
    /// font's missing-glyph boxes and nothing fails.
    colour_emoji: bool = true,
    /// A colour emoji font to use instead of the system's: a bitmap font (PNG strikes: `sbix`,
    /// `CBDT`) or a font with `COLR` colours. Bitmap strikes are scaled so the emoji's ascent
    /// equals the text size. Same lifetime rules as `fallback_fonts`.
    emoji_font: ?FontSource = null,
    /// The user can resize the window. Read the size each frame with `Window.logicalSize`.
    resizable: bool = false,
    /// Smallest size a resizable window can be dragged to (points; 0 = none).
    min_width: u32 = 0,
    min_height: u32 = 0,
    /// Where the window's top-left corner goes (screen points) before it is first shown; null
    /// leaves the placement to the OS, which stacks new windows on the same spot. See `cascadeIn`.
    position: ?[2]f32 = null,
};

/// How far each window of a cascade is offset from the previous one, in points.
pub const cascade_step: f32 = 28;

/// Where window number `index` (0, 1, 2, ...) of size `width` x `height` goes so that windows
/// opened one after another do not hide each other: stepped down and right by `cascade_step` from
/// 40 points inside `area` (use `usableBounds`), wrapping back to the first spot before one would
/// leave the area. Pure.
pub fn cascadeIn(area: geom.Rect, index: u32, width: f32, height: f32) [2]f32 {
    const margin: f32 = 40;
    const room = @min(area.w - width - margin, area.h - height - margin);
    if (room < 0) return .{ area.x, area.y }; // does not fit: top-left corner
    const steps: u32 = @as(u32, @intFromFloat(room / cascade_step)) + 1;
    const k: f32 = @floatFromInt(index % steps);
    return .{ area.x + margin + k * cascade_step, area.y + margin + k * cascade_step };
}

/// `cascadeIn` on the primary display's usable area.
pub fn cascadePosition(index: u32, width: f32, height: f32) [2]f32 {
    return cascadeIn(usableBounds(), index, width, height);
}

var live_windows: usize = 0;

/// The last window is gone: free what is process-wide and shut SDL down.
fn shutdownVideo() void {
    freeCursors();
    c.TTF_Quit();
    // Only video: an `Audio` may still be using SDL (it quits its own subsystem).
    c.SDL_QuitSubSystem(c.INIT_VIDEO);
}

/// Primary display in points, including the menu bar and Dock areas.
pub fn displayBounds() geom.Rect {
    var r: c.SdlRect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
    _ = c.SDL_GetDisplayBounds(c.SDL_GetPrimaryDisplay(), &r);
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
}

/// Primary display minus the menu bar and Dock.
pub fn usableBounds() geom.Rect {
    var r: c.SdlRect = .{ .x = 0, .y = 0, .w = 1440, .h = 900 };
    _ = c.SDL_GetDisplayUsableBounds(c.SDL_GetPrimaryDisplay(), &r);
    return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
}

pub const Mouse = struct { x: f32, y: f32, left_down: bool };

/// Cursor position in screen points and the left button state, whichever
/// app has focus. Poll this for overlays, which get no motion events.
pub fn globalMouse() Mouse {
    var x: f32 = 0;
    var y: f32 = 0;
    const buttons = c.SDL_GetGlobalMouseState(&x, &y);
    return .{ .x = x, .y = y, .left_down = buttons & 1 != 0 };
}

/// Window drag regions (`Window.setDragRegion`), one per window. SDL's hit-test callback gets
/// the SDL window, so the entry is found by it; the table is process-wide but keyed per window.
const max_drag_windows = 8;
const DragEntry = struct {
    win: *c.SdlWindow,
    region: geom.Rect,
    exclude: [16]geom.Rect = undefined,
    n: usize = 0,
};
var drag_table: [max_drag_windows]?DragEntry = @splat(null);

fn dragEntry(win: *c.SdlWindow) ?*const DragEntry {
    for (&drag_table) |*slot| if (slot.*) |*e| if (e.win == win) return e;
    return null;
}

fn dragHit(e: *const DragEntry, x: f32, y: f32) bool {
    if (!e.region.contains(x, y)) return false;
    for (e.exclude[0..e.n]) |ex| if (ex.contains(x, y)) return false;
    return true;
}

fn hitTest(win: *c.SdlWindow, area: *const c.SdlPoint, _: ?*anyopaque) callconv(.c) c_int {
    const e = dragEntry(win) orelse return 0;
    return if (dragHit(e, @floatFromInt(area.x), @floatFromInt(area.y))) 1 else 0; // 1 = SDL_HITTEST_DRAGGABLE
}

/// Sets, replaces (`region` non-null) or removes (null) the drag region of `win`. False if the
/// table is full.
fn setDrag(win: *c.SdlWindow, region: ?geom.Rect, exclude: []const geom.Rect) bool {
    var slot_i: ?usize = null;
    var free_i: ?usize = null;
    for (drag_table, 0..) |slot, i| {
        if (slot) |e| {
            if (e.win == win) slot_i = i;
        } else if (free_i == null) free_i = i;
    }
    const r = region orelse {
        if (slot_i) |i| drag_table[i] = null;
        return true;
    };
    const i = slot_i orelse free_i orelse return false;
    var e: DragEntry = .{ .win = win, .region = r };
    e.n = @min(exclude.len, e.exclude.len);
    @memcpy(e.exclude[0..e.n], exclude[0..e.n]);
    drag_table[i] = e;
    return true;
}

/// The text event being delivered, copied out of SDL's event memory. Short strings use
/// `pending_buf`; a longer one (dictation, a big IME commit) gets a heap copy, freed once the
/// next text event replaces it.
var pending_buf: [256]u8 = undefined;
var pending_text: []const u8 = "";
var pending_heap: ?[]u8 = null;
var pending_pos: usize = 0;
var pending_window: u32 = 0;

fn modsFrom(m: u16) keys.Mods {
    return .{ .shift = m & c.KMOD_SHIFT != 0, .ctrl = m & c.KMOD_CTRL != 0, .alt = m & c.KMOD_ALT != 0, .cmd = m & c.KMOD_GUI != 0 };
}

/// Modifier keys held right now.
pub fn modState() keys.Mods {
    return modsFrom(c.SDL_GetModState());
}

fn readF32(raw: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, raw[off..][0..4], .little));
}

fn keyFrom(raw: []const u8) Key {
    return .{
        .code = keys.normalize(std.mem.readInt(u32, raw[28..32], .little)),
        .mods = modsFrom(std.mem.readInt(u16, raw[32..34], .little)),
        .repeat = raw[37] != 0,
        .window = std.mem.readInt(u32, raw[16..20], .little),
    };
}

/// Reads the NUL-terminated string pointer stored at `off` in the event.
fn eventString(raw: []const u8, off: usize) []const u8 {
    const addr = std.mem.readInt(usize, raw[off..][0..@sizeOf(usize)], .little);
    if (addr == 0) return "";
    const p: [*:0]const u8 = @ptrFromInt(addr);
    return std.mem.span(p);
}

/// Splits `pending_text` into chunks of at most 32 bytes on character boundaries.
fn nextPendingChunk() ?Event {
    if (pending_pos >= pending_text.len) return null;
    const end = textChunkEnd(pending_text, pending_pos);
    const chunk = TextChunk.from(pending_text[pending_pos..end]);
    pending_pos = end;
    return .{ .text_input = .{ .window = pending_window, .text = chunk } };
}

/// Turns one raw SDL event (`SDL_Event` layout: type at 0, window id at 16) into an `Event`, or
/// null for the ones the toolkit ignores. Every event that belongs to a window carries its id.
/// Text events are queued in `pending_text` and come out in chunks (see `nextPendingChunk`).
fn decodeRaw(ev_type: u32, raw: []const u8) ?Event {
    const window = std.mem.readInt(u32, raw[16..20], .little);
    switch (ev_type) {
        c.EVENT_QUIT => return .quit,
        c.EVENT_WINDOW_CLOSE_REQUESTED => return .{ .close_requested = window },
        c.EVENT_KEY_DOWN => return .{ .key_down = keyFrom(raw) },
        c.EVENT_KEY_UP => return .{ .key_up = keyFrom(raw) },
        c.EVENT_TEXT_INPUT => {
            const str = eventString(raw, 24);
            // The previous event was fully delivered before SDL was polled again.
            if (pending_heap) |h| std.heap.c_allocator.free(h);
            pending_heap = null;
            if (str.len <= pending_buf.len) {
                @memcpy(pending_buf[0..str.len], str);
                pending_text = pending_buf[0..str.len];
            } else if (std.heap.c_allocator.dupe(u8, str)) |h| {
                pending_heap = h;
                pending_text = h;
            } else |_| {
                // Out of memory: deliver what fits, cut on a character boundary.
                var n = pending_buf.len;
                while (n > 0 and str[n] & 0xC0 == 0x80) n -= 1;
                @memcpy(pending_buf[0..n], str[0..n]);
                pending_text = pending_buf[0..n];
            }
            pending_pos = 0;
            pending_window = window;
            return nextPendingChunk();
        },
        c.EVENT_TEXT_EDITING => {
            const str = eventString(raw, 24);
            var comp: Composition = .{
                .start = std.mem.readInt(i32, raw[32..36], .little),
                .length = std.mem.readInt(i32, raw[36..40], .little),
            };
            var n = @min(str.len, comp.buf.len);
            while (n > 0 and n < str.len and str[n] & 0xC0 == 0x80) n -= 1;
            @memcpy(comp.buf[0..n], str[0..n]);
            comp.len = @intCast(n);
            return .{ .text_editing = .{ .window = window, .comp = comp } };
        },
        c.EVENT_WINDOW_MOUSE_LEAVE => return .{ .mouse_leave = window },
        c.EVENT_WINDOW_FOCUS_GAINED => return .{ .focus_gained = window },
        c.EVENT_WINDOW_FOCUS_LOST => return .{ .focus_lost = window },
        // The path lives in SDL's event memory until the next poll; decodeDropEvent copies it.
        c.EVENT_DROP_FILE, c.EVENT_DROP_BEGIN, c.EVENT_DROP_COMPLETE, c.EVENT_DROP_POSITION => return decodeDropEvent(ev_type, raw),
        c.EVENT_MOUSE_WHEEL => return .{ .mouse_wheel = .{ .window = window, .dx = readF32(raw, 24), .dy = readF32(raw, 28) } },
        c.EVENT_MOUSE_MOTION => return .{ .mouse_move = .{ .window = window, .x = readF32(raw, 28), .y = readF32(raw, 32) } },
        c.EVENT_MOUSE_BUTTON_UP => return .{ .mouse_up = .{ .window = window, .x = readF32(raw, 28), .y = readF32(raw, 32), .button = raw[24] } },
        c.EVENT_MOUSE_BUTTON_DOWN => return .{ .mouse_down = .{ .window = window, .x = readF32(raw, 28), .y = readF32(raw, 32), .button = raw[24], .mods = modState(), .clicks = raw[26] } },
        else => return null,
    }
}

/// An event `waitEvent` took from SDL that `pollEvent` has not returned yet.
var held_event: ?Event = null;

/// Blocks until an event arrives or `timeout_ms` has passed (null: no limit); true if one arrived.
/// The event stays queued for `pollEvent`. An event the toolkit does not decode (a window
/// exposed, say) also ends the wait, so a caller that redraws on every wake-up repaints for it.
/// Costs no CPU while it waits: this is what an app that draws only on demand sleeps in.
pub fn waitEvent(timeout_ms: ?u32) bool {
    if (held_event != null or pending_pos < pending_text.len) return true;
    var e: c.SdlEvent = undefined;
    const got = if (timeout_ms) |ms|
        c.SDL_WaitEventTimeout(&e, @intCast(@min(ms, std.math.maxInt(i32))))
    else
        c.SDL_WaitEvent(&e);
    if (!got) return false;
    held_event = decodeRaw(e.type, &e.raw);
    return true;
}

/// Ends a `waitEvent` that is blocking (or the next one) without any real input: for a thread
/// that finished something the UI should show. Safe to call from any thread.
pub fn wakeEventLoop() void {
    var e: c.SdlEvent = undefined;
    @memset(&e.raw, 0);
    e.type = c.EVENT_USER;
    _ = c.SDL_PushEvent(&e);
}

/// Makes SDL use its dummy video driver (real windows and software renderers, nothing on
/// screen) for the windows opened from now on. For tests and headless runs; call it before the
/// first window.
pub fn useDummyVideo() void {
    _ = c.SDL_SetHint("SDL_VIDEO_DRIVER", "dummy");
}

/// Returns the next pending event for any window, or null when the queue is empty.
pub fn pollEvent() ?Event {
    if (held_event) |ev| {
        held_event = null;
        return ev;
    }
    if (nextPendingChunk()) |ev| return ev;
    var e: c.SdlEvent = undefined;
    while (c.SDL_PollEvent(&e)) {
        if (decodeRaw(e.type, &e.raw)) |ev| return ev;
    }
    return null;
}

/// The system clipboard's text, copied into memory from `gpa` (free it), or
/// null if the clipboard holds no text.
pub fn clipboardText(gpa: std.mem.Allocator) !?[]u8 {
    const p = c.SDL_GetClipboardText() orelse return null;
    defer c.SDL_free(p);
    const str = std.mem.span(p);
    if (str.len == 0) return null;
    return try gpa.dupe(u8, str);
}

/// Puts `str` on the system clipboard.
pub fn setClipboardText(gpa: std.mem.Allocator, str: []const u8) !void {
    const z = try gpa.allocSentinel(u8, str.len, 0);
    defer gpa.free(z);
    @memcpy(z, str);
    _ = c.SDL_SetClipboardText(z.ptr);
}

const font_paths = [_][*:0]const u8{
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
};

/// Fonts tried after the UI font, and after `WindowOptions.fallback_fonts`, for characters the UI
/// font lacks (symbols, then Han in Simplified Chinese and Japanese forms, kana, Hangul, then
/// Arial Unicode for scripts the others do not cover). Whatever is not installed is skipped.
const system_fallback_paths: []const [:0]const u8 = if (builtin.os.tag == .macos) &.{
    "/System/Library/Fonts/Apple Symbols.ttf",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/\u{30D2}\u{30E9}\u{30AE}\u{30CE}\u{89D2}\u{30B4}\u{30B7}\u{30C3}\u{30AF} W3.ttc",
    "/System/Library/Fonts/AppleSDGothicNeo.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
} else &.{};

/// Advance of the system emoji font's glyphs in percent of their bitmap width (see `EmojiState`).
const system_emoji_advance_pct: u32 = 115;

/// How far the system emoji font's glyphs sit below the baseline, in percent of the text size.
const system_emoji_drop_pct: u32 = 15;

/// The system colour emoji font.
const system_emoji_path: ?[:0]const u8 = if (builtin.os.tag == .macos) "/System/Library/Fonts/Apple Color Emoji.ttc" else null;

const CachedFont = struct { px: u32, weight: gfx.Weight, font: *c.Font, fb_attached: bool = false };
/// A fallback font opened at one pixel size (shared by every weight of the UI font at that size);
/// null when the file could not be opened.
const FallbackFont = struct { index: u16, px: u32, font: ?*c.Font };
/// A colour emoji font opened for one strike (a bitmap font) or one pixel size (a scalable one).
const EmojiFont = struct { key: u32, font: *c.Font };
const max_strikes = 24;

/// The colour emoji font of a window, found on first use.
const EmojiState = struct {
    /// 0 not tried yet, 1 usable, 2 no usable font.
    status: enum { untried, ready, unavailable } = .untried,
    scalable: bool = false,
    /// How wide a glyph's advance is as a percentage of the bitmap's width. Apple Color Emoji's
    /// bitmaps are as wide as the em but the font advances 1.15 em (CoreText leaves that gap
    /// between emoji); FreeType reports the bitmap width, so the gap is added here.
    advance_pct: u32 = 100,
    /// How far below the baseline the glyphs are moved, in percent of the text size. CoreText sets
    /// Apple Color Emoji about 0.15 em lower than the origin FreeType reports for its bitmaps.
    drop_pct: u32 = 0,
    /// Bitmap fonts: the size of each strike in pixels (the font's ascent there), ascending; the
    /// index into this array is what SDL_ttf takes as a "size" for a font that cannot scale.
    strikes: [max_strikes]u16 = @splat(0),
    n_strikes: u8 = 0,
    fonts: std.ArrayList(EmojiFont) = .empty,
};
const ImageTex = struct { tex: *c.Texture, w: u32, h: u32 };
/// Image ids are unique across windows and never reused, so a stale or foreign
/// handle can only miss.
var next_image_id: u32 = 1;
/// Textures are downscaled (box filter) to at most this many pixels per side.
const max_texture_side: u32 = 2048;

/// SVG icon ids, like image ids: unique across windows, never reused.
var next_svg_id: u32 = 1;
/// Icon textures are never larger than this per side (bigger requests are scaled down).
const max_svg_side: u32 = 1024;

pub const SvgError = svg_mod.Error;
/// How an SVG is rasterised.
pub const SvgOptions = struct {
    /// Keep the SVG's own colours and gradients (a logo or illustration). The colour passed
    /// when drawing then multiplies them (white = as authored), and `currentColor` is white.
    /// False (the default): a monochrome icon; every painted shape is ink, drawn in the
    /// colour passed when drawing.
    color: bool = false,
};
const SvgEntry = struct { doc: svg_mod.Doc, color: bool };

fn destroySvgTexture(_: void, t: ?*c.Texture) void {
    if (t) |tex| c.SDL_DestroyTexture(tex);
}

pub const ImageError = decode_mod.Error || error{ FileReadFailed, TextureFailed };

/// The renderer's maximum texture size per side (the software renderer reports none: unlimited).
fn rendererMaxTexture(ren: *c.Renderer) u32 {
    const n = c.SDL_GetNumberProperty(c.SDL_GetRendererProperties(ren), "SDL.renderer.max_texture_size", 0);
    return if (n > 0) @intCast(@min(n, std.math.maxInt(c_int))) else std.math.maxInt(c_int);
}

/// A drawn line of text. A line wider than the renderer's largest texture is cut into strips:
/// `tex` is the first, `more` the rest, left to right, each `max texture size` pixels wide
/// except the last.
const CachedText = struct {
    tex: *c.Texture,
    /// Size in points (pixels / density).
    w: f32,
    h: f32,
    /// Size in device pixels, whole numbers. Strips included in the width.
    pw: f32,
    ph: f32,
    last_frame: u64,
    more: []const *c.Texture = &.{},
};

/// Text wider than this many pixels is not drawn (it would take tens of megabytes to rasterise).
const max_line_px: u32 = 1 << 18;
/// Most pixels (width x height) one line of text may take: 32 Mpx is 128 MB of ARGB, and the
/// width limit alone allows gigabytes at the largest text size.
const max_text_area: u64 = 1 << 25;

/// Whether a line `width` x `height` pixels may be rasterised.
fn textSurfaceOk(width: u64, height: u64) bool {
    return width <= max_line_px and width * height <= max_text_area;
}

/// A string that was not drawn, remembered so it is not rasterised every frame.
const TextMiss = struct {
    /// The last frame it was asked for (it is dropped when nobody asks for a while).
    seen: u64,
    /// The first frame it may be tried again; `never` for what can never succeed (too big).
    retry_at: u64,
    tries: u8 = 0,

    const never = std.math.maxInt(u64);

    /// Frames to wait after the `tries`-th failure: half a second at 60 fps, doubling to eight.
    fn backoff(tries: u8) u64 {
        return @as(u64, 30) << @min(tries, 4);
    }

    /// The entry after a failure at `frame` (`prev`: the one it had, if it was tried again).
    fn failed(prev: ?TextMiss, frame: u64, permanent: bool) TextMiss {
        const tries: u8 = if (prev) |p| p.tries +| 1 else 0;
        return .{ .seen = frame, .retry_at = if (permanent) never else frame + backoff(tries), .tries = tries };
    }
};
/// Text sizes are clamped to this many pixels tall.
const max_text_px: f32 = 4096;


pub fn sleepMs(ms: u32) void {
    c.SDL_Delay(ms);
}

/// A mouse cursor shape. Apps ask for one with `Ui.setCursor` (or `Window.setCursor`); the
/// backend creates the system cursor lazily, caches it and frees it with the last window.
/// SDL has no open-hand cursor, so `grab` and `grabbing` are both SDL's "move" cursor (on
/// macOS the closed hand).
pub const Cursor = enum {
    arrow,
    text,
    pointer,
    resize_h,
    resize_v,
    resize_nwse,
    resize_nesw,
    grab,
    grabbing,
    move,
    crosshair,
    wait,
    not_allowed,

    fn sdlId(cur: Cursor) c_int {
        return switch (cur) {
            .arrow => 0,
            .text => 1,
            .wait => 2,
            .crosshair => 3,
            .resize_nwse => 5,
            .resize_nesw => 6,
            .resize_h => 7,
            .resize_v => 8,
            .move, .grab, .grabbing => 9,
            .not_allowed => 10,
            .pointer => 11,
        };
    }
};

/// Created system cursors, one per `Cursor`; SDL cursors are process-wide, not per window.
var cursor_cache: [std.enums.values(Cursor).len]?*c.SdlCursor = @splat(null);
/// The cursor SDL was last told to show, and for which window (null: none yet), to skip redundant calls.
var cursor_applied: ?Cursor = null;
var cursor_applied_for: ?*c.SdlWindow = null;

/// A window may set the process-wide cursor only while the pointer is over it: otherwise the
/// window drawn last (which wants the arrow) would reset the cursor a window under the pointer
/// asked for. With the pointer over none of our windows the cursor is not visible, so anyone may.
fn cursorOwner(mouse_focus: ?*c.SdlWindow, mine: *c.SdlWindow) bool {
    const f = mouse_focus orelse return true;
    return f == mine;
}

fn systemCursor(cur: Cursor) ?*c.SdlCursor {
    const i = @intFromEnum(cur);
    if (cursor_cache[i] == null) cursor_cache[i] = c.SDL_CreateSystemCursor(cur.sdlId());
    return cursor_cache[i];
}

fn freeCursors() void {
    for (&cursor_cache) |*slot| {
        if (slot.*) |cur| c.SDL_DestroyCursor(cur);
        slot.* = null;
    }
    cursor_applied = null;
    cursor_applied_for = null;
}

/// Milliseconds since the platform was initialised.
pub fn ticks() u64 {
    return c.SDL_GetTicks();
}

const LiveFrame = struct { ctx: ?*anyopaque, func: *const fn (ctx: ?*anyopaque) void, window_id: u32, thread: u64 };

pub const Window = struct {
    gpa: std.mem.Allocator,
    win: *c.SdlWindow,
    ren: *c.Renderer,
    /// Physical pixels per logical point (2.0 on Retina displays).
    /// The largest texture the renderer can make, in pixels per side (see `rendererMaxTexture`).
    max_tex: u32,
    density: f32,
    frame: u64 = 0,
    fonts: std.ArrayList(CachedFont) = .empty,
    texts: std.AutoHashMapUnmanaged(u64, CachedText) = .empty,
    /// Strings that could not be drawn, so they are not rasterised again every frame.
    text_misses: std.AutoHashMapUnmanaged(u64, TextMiss) = .empty,
    /// Set by `textTexture` when it returns null for a reason that cannot go away (too big), as
    /// opposed to running out of memory or a texture failing, which may pass.
    text_never: bool = false,
    /// Icons whose render failure has been logged, and how many log lines that made.
    svg_failed: std.AutoHashMapUnmanaged(u32, void) = .empty,
    svg_failure_logs: u32 = 0,
    verts: std.ArrayList(c.Vertex) = .empty,
    idx: std.ArrayList(c_int) = .empty,
    /// If set, the next rendered frame is also saved to this path as a BMP.
    snapshot_path: ?[*:0]const u8 = null,
    /// Active clip rectangles (window points), innermost last.
    clips: [16]geom.Rect = undefined,
    clip_n: usize = 0,
    /// Pushes beyond the stack depth, so pops stay balanced; while it is non-zero `clip_over`
    /// is the clip in force (the innermost intersected).
    clip_overflow: usize = 0,
    clip_over: geom.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    font_set: ?FontSet = null,
    fallback_sources: []const FontSource = &.{},
    system_fallback: bool = true,
    colour_emoji: bool = true,
    emoji_source: ?FontSource = null,
    /// Fallback fonts opened so far, per source and pixel size.
    fb_fonts: std.ArrayList(FallbackFont) = .empty,
    emoji: EmojiState = .{},
    /// Advance (pixels) of each emoji cluster per pixel size, as `emojiAdvance` worked it out.
    emoji_adv: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    images: std.AutoHashMapUnmanaged(u32, ImageTex) = .empty,
    svgs: std.AutoHashMapUnmanaged(u32, SvgEntry) = .empty,
    /// Rasterised icons per (icon, pixel size); a null texture marks a size that failed.
    svg_cache: svg_cache.Cache(?*c.Texture) = .{},
    /// See `setFrameCallback`. The watcher holds a pointer to this `Window`.
    live: ?LiveFrame = null,
    /// Window size (points and pixels) of the last frame drawn, to skip redundant live frames.
    drawn_key: [4]c_int = .{ 0, 0, 0, 0 },
    in_render: bool = false,
    live_busy: bool = false,
    /// The cursor the app asked for this frame (`setCursor`); `render` applies it and goes back to arrow.
    cursor_wanted: Cursor = .arrow,

    /// Opens a window. SDL and SDL_ttf are started by the first window and shut down with the last
    /// one (each is initialised once and quit once, however many windows come and go in
    /// between); a failed `init` leaves nothing started that it started. The returned `Window`
    /// is a value: keep it at one address while a frame callback is registered or a `Ui` holds
    /// it. For a window that is opened and closed at run time use `create` and `destroy`.
    pub fn init(gpa: std.mem.Allocator, opts: WindowOptions) !Window {
        const first = live_windows == 0;
        if (first) {
            // Let the first click on an unfocused window count as a click.
            _ = c.SDL_SetHint("SDL_MOUSE_FOCUS_CLICKTHROUGH", "1");
            if (!c.SDL_Init(c.INIT_VIDEO)) return fail("SDL_Init");
            if (!c.TTF_Init()) {
                const err = fail("TTF_Init");
                c.SDL_QuitSubSystem(c.INIT_VIDEO);
                return err;
            }
        }
        errdefer if (first) shutdownVideo();
        var flags: u64 = c.WINDOW_HIGH_PIXEL_DENSITY;
        if (opts.always_on_top) flags |= c.WINDOW_ALWAYS_ON_TOP;
        if (opts.borderless) flags |= c.WINDOW_BORDERLESS;
        if (opts.transparent) flags |= c.WINDOW_TRANSPARENT;
        // A window with a position is created hidden, moved, then shown, so it never flashes at the OS's spot.
        const show_after = opts.position != null and !opts.hidden;
        if (opts.hidden or show_after) flags |= c.WINDOW_HIDDEN;
        if (opts.resizable) flags |= c.WINDOW_RESIZABLE;
        if (!opts.focusable) flags |= c.WINDOW_NOT_FOCUSABLE;
        const win = c.SDL_CreateWindow(opts.title, @intCast(opts.width), @intCast(opts.height), flags) orelse
            return fail("SDL_CreateWindow");
        errdefer c.SDL_DestroyWindow(win);
        const ren = c.SDL_CreateRenderer(win, null) orelse return fail("SDL_CreateRenderer");
        // No vsync: with several windows each present would block in turn.
        // The app paces its own frames.
        _ = c.SDL_SetRenderVSync(ren, 0);
        live_windows += 1;
        if (opts.min_width > 0 and opts.min_height > 0) _ = c.SDL_SetWindowMinimumSize(win, @intCast(opts.min_width), @intCast(opts.min_height));
        _ = c.SDL_SetRenderDrawBlendMode(ren, c.BLENDMODE_BLEND);
        const density = @max(1.0, c.SDL_GetWindowPixelDensity(win));
        _ = c.SDL_SetRenderScale(ren, density, density);
        if (opts.position) |p| _ = c.SDL_SetWindowPosition(win, @intFromFloat(@round(p[0])), @intFromFloat(@round(p[1])));
        if (show_after) _ = c.SDL_ShowWindow(win);
        return .{
            .gpa = gpa,
            .win = win,
            .ren = ren,
            .max_tex = rendererMaxTexture(ren),
            .density = density,
            .font_set = opts.fonts,
            .fallback_sources = opts.fallback_fonts,
            .system_fallback = opts.system_fallback_fonts,
            .colour_emoji = opts.colour_emoji,
            .emoji_source = opts.emoji_font,
        };
    }

    /// Destroys the window and everything loaded into it (images, icons, fonts, text textures; a
    /// handle loaded here means nothing to another window). Safe from the frame callback of
    /// another window and between frames; not from this window's own frame callback or while it
    /// is rendering (that would free the window under the code running on it, so it panics).
    /// The last window to go shuts SDL down.
    pub fn deinit(w: *Window) void {
        if (w.live_busy or w.in_render) @panic("Window.deinit from the window's own frame callback or render: destroy it after the current frame");
        w.setFrameCallback(null, null);
        discardDialogOf(w.id());
        _ = setDrag(w.win, null, &.{});
        var it = w.texts.valueIterator();
        while (it.next()) |t| w.destroyText(t.*);
        w.texts.deinit(w.gpa);
        w.text_misses.deinit(w.gpa);
        w.svg_failed.deinit(w.gpa);
        var imgs = w.images.valueIterator();
        while (imgs.next()) |t| c.SDL_DestroyTexture(t.tex);
        w.images.deinit(w.gpa);
        w.svg_cache.deinit(w.gpa, {}, destroySvgTexture);
        var docs = w.svgs.valueIterator();
        while (docs.next()) |e| e.doc.deinit();
        w.svgs.deinit(w.gpa);
        for (w.fonts.items) |f| c.TTF_CloseFont(f.font);
        w.fonts.deinit(w.gpa);
        for (w.fb_fonts.items) |f| if (f.font) |font| c.TTF_CloseFont(font);
        w.fb_fonts.deinit(w.gpa);
        for (w.emoji.fonts.items) |f| c.TTF_CloseFont(f.font);
        w.emoji.fonts.deinit(w.gpa);
        w.emoji_adv.deinit(w.gpa);
        w.verts.deinit(w.gpa);
        w.idx.deinit(w.gpa);
        c.SDL_DestroyRenderer(w.ren);
        c.SDL_DestroyWindow(w.win);
        live_windows -= 1;
        if (live_windows == 0) shutdownVideo();
    }

    /// Heap-allocates a window with `init`, for an app whose set of windows changes at run time:
    /// the address stays put (what `setFrameCallback` and `Ui.init` need) however the app's own
    /// list of windows grows or shrinks. Free with `destroy`.
    pub fn create(gpa: std.mem.Allocator, opts: WindowOptions) !*Window {
        const w = try gpa.create(Window);
        errdefer gpa.destroy(w);
        w.* = try init(gpa, opts);
        return w;
    }

    /// `deinit` and free a window made by `create`. Same restrictions as `deinit`.
    pub fn destroy(w: *Window) void {
        const gpa = w.gpa;
        w.deinit();
        gpa.destroy(w);
    }

    pub fn id(w: *const Window) u32 {
        return c.SDL_GetWindowID(w.win);
    }

    /// Current size of the window's drawable area in points. Call it every
    /// frame to lay out a resizable window.
    pub fn logicalSize(w: *const Window) struct { w: f32, h: f32 } {
        var iw: c_int = 0;
        var ih: c_int = 0;
        _ = c.SDL_GetWindowSize(w.win, &iw, &ih);
        return .{ .w = @floatFromInt(iw), .h = @floatFromInt(ih) };
    }

    /// Registers `func` to draw one frame while the OS is live-resizing the
    /// window, or clears it with a null `func`. Required for a resizable window
    /// to reflow during a drag: on macOS the system runs its own loop while an
    /// edge is dragged, so the app's `while (running)` loop is blocked inside
    /// `pollEvent` and nothing is drawn; the OS then stretches the last frame
    /// until the mouse is released.
    ///
    /// `func(ctx)` is called synchronously from inside SDL's event pump, on the
    /// thread that called `setFrameCallback` (the main thread), when this
    /// window is exposed, resized or its pixel size changes (about 60 times a
    /// second during a drag, at most once per distinct size). It must do
    /// exactly what one iteration of the app's loop does after reading events:
    /// build the UI at `logicalSize()` and `render`. Feed it an idle `Input`
    /// (`Input.idle`) so a click or key is not seen twice, and do not advance
    /// the app's own timers. Before it runs the window's scale factor is
    /// refreshed, and `logicalSize()` is already the new size.
    ///
    /// It is never called re-entrantly, while `render` is running, or from
    /// another thread (SDL may call watchers from any thread; those events are
    /// ignored). The window must not move in memory while a callback is set
    /// (SDL holds a pointer to it): register after the `Window` has its final
    /// address. `deinit` clears it. Events for other windows are ignored.
    pub fn setFrameCallback(w: *Window, ctx: ?*anyopaque, func: ?*const fn (ctx: ?*anyopaque) void) void {
        if (w.live != null) c.SDL_RemoveEventWatch(liveWatch, w);
        w.live = null;
        const f = func orelse return;
        w.live = .{ .ctx = ctx, .func = f, .window_id = w.id(), .thread = c.SDL_GetCurrentThreadID() };
        if (!c.SDL_AddEventWatch(liveWatch, w)) w.live = null;
    }

    fn liveWatch(ud: ?*anyopaque, e: *c.SdlEvent) callconv(.c) bool {
        const w: *Window = @ptrCast(@alignCast(ud.?));
        switch (e.type) {
            c.EVENT_WINDOW_EXPOSED, c.EVENT_WINDOW_RESIZED, c.EVENT_WINDOW_PIXEL_SIZE_CHANGED => {},
            else => return true,
        }
        const live = w.live orelse return true;
        if (std.mem.readInt(u32, e.raw[16..20], .little) != live.window_id) return true;
        w.liveFrame(live, e.type == c.EVENT_WINDOW_EXPOSED);
        return true;
    }

    fn liveFrame(w: *Window, live: LiveFrame, exposed: bool) void {
        // SDL may call watchers from any thread; only the registering thread may draw.
        if (c.SDL_GetCurrentThreadID() != live.thread) return;
        if (w.live_busy or w.in_render) return;
        w.live_busy = true;
        defer w.live_busy = false;
        w.syncMetrics();
        // A size we already drew needs no new frame, except an expose (it may have
        // been uncovered); SDL's own resize timer is an expose too, hence the check.
        const key = w.sizeKey();
        if (!exposed and std.mem.eql(c_int, &key, &w.drawn_key)) return;
        live.func(live.ctx);
    }

    fn sizeKey(w: *const Window) [4]c_int {
        var k: [4]c_int = .{ 0, 0, 0, 0 };
        _ = c.SDL_GetWindowSize(w.win, &k[0], &k[1]);
        _ = c.SDL_GetWindowSizeInPixels(w.win, &k[2], &k[3]);
        return k;
    }

    /// Re-reads the pixel density (it changes when the window moves between
    /// a Retina and a normal display) and updates the render scale.
    fn syncMetrics(w: *Window) void {
        const d = @max(1.0, c.SDL_GetWindowPixelDensity(w.win));
        if (d == w.density) return;
        w.density = d;
        _ = c.SDL_SetRenderScale(w.ren, d, d);
    }

    /// Makes the strip `region` (window points) drag the window, except where
    /// it overlaps one of `exclude` (buttons). For windows whose title bar is
    /// drawn by the app (see `macos.unifiedTitleBar`). The rectangles are
    /// copied (at most 16 exclusions); call again whenever they move. Pass a
    /// null region to turn dragging off. Every window has its own region (up to 8
    /// windows at once; a ninth gets none).
    pub fn setDragRegion(w: *Window, region: ?geom.Rect, exclude: []const geom.Rect) void {
        const ok = setDrag(w.win, region, exclude);
        if (!ok) std.log.warn("setDragRegion: too many windows with a drag region", .{});
        _ = c.SDL_SetWindowHitTest(w.win, if (region != null and ok) hitTest else null, null);
    }

    pub fn show(w: *Window) void {
        _ = c.SDL_ShowWindow(w.win);
    }

    pub fn hide(w: *Window) void {
        _ = c.SDL_HideWindow(w.win);
    }

    /// Brings the window to the front and asks the OS to give it keyboard focus (the OS may
    /// decline for a background app).
    pub fn raise(w: *Window) void {
        _ = c.SDL_RaiseWindow(w.win);
    }

    /// Changes the title bar text. `title` is copied (at most 255 bytes, cut on a character
    /// boundary); an empty title is allowed. No allocation.
    pub fn setTitle(w: *Window, title: []const u8) void {
        var buf: [256]u8 = undefined;
        var n = @min(title.len, buf.len - 1);
        while (n > 0 and n < title.len and title[n] & 0xC0 == 0x80) n -= 1;
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        _ = c.SDL_SetWindowTitle(w.win, @ptrCast(&buf));
    }

    /// True while this window has keyboard focus (the window `key_down` and `text_input` go to).
    pub fn hasFocus(w: *const Window) bool {
        return c.SDL_GetKeyboardFocus() == w.win;
    }

    /// True while the pointer is over this window.
    pub fn hasMouseFocus(w: *const Window) bool {
        return c.SDL_GetMouseFocus() == w.win;
    }

    /// Top-left corner in screen points.
    pub fn position(w: *const Window) [2]f32 {
        var x: c_int = 0;
        var y: c_int = 0;
        _ = c.SDL_GetWindowPosition(w.win, &x, &y);
        return .{ @floatFromInt(x), @floatFromInt(y) };
    }

    /// Top-left corner in screen points.
    pub fn setPosition(w: *Window, x: f32, y: f32) void {
        _ = c.SDL_SetWindowPosition(w.win, @intFromFloat(@round(x)), @intFromFloat(@round(y)));
    }

    /// The OS window object (an NSWindow on macOS), for platform extras.
    pub fn nativeHandle(w: *const Window) ?*anyopaque {
        return c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(w.win), "SDL.window.cocoa.window", null);
    }

    /// Starts delivering `text_input` / `text_editing` events for this window
    /// (and, on macOS, enables the input-method machinery). Call when a text
    /// field gains focus, or once at startup.
    pub fn startTextInput(w: *Window) void {
        _ = c.SDL_StartTextInput(w.win);
    }

    pub fn stopTextInput(w: *Window) void {
        _ = c.SDL_StopTextInput(w.win);
    }

    /// Whether `startTextInput` is in effect for this window. Text input is per window: starting it
    /// in one window does not start it in the others, and events only come from the window that
    /// has keyboard focus.
    pub fn textInputActive(w: *const Window) bool {
        return c.SDL_TextInputActive(w.win);
    }

    fn clampInt(v: f32) c_int {
        if (std.math.isNan(v)) return 0;
        return @intFromFloat(std.math.clamp(v, -1e6, 1e6));
    }

    /// Tells the input method where the text being edited is (window points),
    /// so its candidate popup can sit next to it. `cursor_x` is the caret's
    /// x offset inside `r`.
    pub fn setTextInputArea(w: *Window, r: geom.Rect, cursor_x: f32) void {
        const ir: c.SdlRect = .{ .x = clampInt(r.x), .y = clampInt(r.y), .w = clampInt(r.w), .h = clampInt(r.h) };
        _ = c.SDL_SetTextInputArea(w.win, &ir, clampInt(cursor_x));
    }

    // ---- images -------------------------------------------------------

    /// Decodes PNG, JPEG, BMP or GIF (first frame) from memory and uploads it as a texture.
    /// Fails with `InvalidImage` (not an image / corrupt) or `ImageTooLarge`.
    pub fn loadImage(w: *Window, bytes: []const u8) ImageError!Image {
        const d = try decode_mod.decode(w.gpa, bytes);
        defer d.deinit(w.gpa);
        return w.loadImagePixels(d.pixels, d.width, d.height);
    }

    /// Reads and decodes a file (see `loadImage`). `FileReadFailed` if it cannot be read.
    pub fn loadImageFile(w: *Window, path: []const u8) ImageError!Image {
        const z = try w.gpa.allocSentinel(u8, path.len, 0);
        @memcpy(z, path);
        defer w.gpa.free(z);
        // Look before reading: a huge file is refused without loading it.
        var info: c.PathInfo = undefined;
        if (!c.SDL_GetPathInfo(z.ptr, &info) or info.kind != c.PATHTYPE_FILE) return error.FileReadFailed;
        if (info.size > decode_mod.max_file_bytes) return error.ImageTooLarge;
        var size: usize = 0;
        const data = c.SDL_LoadFile(z.ptr, &size) orelse return error.FileReadFailed;
        defer c.SDL_free(data);
        if (size > decode_mod.max_file_bytes) return error.ImageTooLarge;
        return w.loadImage(@as([*]const u8, @ptrCast(data))[0..size]);
    }

    /// Uploads straight-alpha RGBA8 pixels (`width * height * 4` bytes, rows top to bottom)
    /// as an image. The pixels are copied. Very large images are reduced to a 2048 px texture
    /// (the handle still reports the original size).
    pub fn loadImagePixels(w: *Window, rgba: []const u8, width: u32, height: u32) ImageError!Image {
        if (!decode_mod.sizeOk(width, height)) return error.ImageTooLarge;
        if (rgba.len != @as(usize, width) * height * 4) return error.InvalidImage;
        const prep = try decode_mod.prepareTexture(w.gpa, rgba, width, height, max_texture_side);
        defer w.gpa.free(prep.pixels);
        const tex = c.SDL_CreateTexture(w.ren, c.PIXELFORMAT_RGBA32, c.TEXTUREACCESS_STATIC, @intCast(prep.width), @intCast(prep.height)) orelse return error.TextureFailed;
        errdefer c.SDL_DestroyTexture(tex);
        if (!c.SDL_UpdateTexture(tex, null, prep.pixels.ptr, @intCast(prep.width * 4))) return error.TextureFailed;
        // Premultiplied alpha: linear filtering then never bleeds the colour of fully
        // transparent pixels into the edges (no dark/bright halos).
        _ = c.SDL_SetTextureBlendMode(tex, c.BLENDMODE_BLEND_PREMULTIPLIED);
        _ = c.SDL_SetTextureScaleMode(tex, c.SCALEMODE_LINEAR);
        const new_id = next_image_id;
        next_image_id += 1;
        try w.images.put(w.gpa, new_id, .{ .tex = tex, .w = width, .h = height });
        return .{ .id = new_id, .width = width, .height = height };
    }

    /// Frees the texture. The handle (and copies of it) become invalid and draw nothing.
    /// Unloading an unknown or already unloaded handle is a no-op.
    pub fn unloadImage(w: *Window, img: Image) void {
        if (w.images.fetchRemove(img.id)) |kv| c.SDL_DestroyTexture(kv.value.tex);
    }

    /// True if `img` is currently loaded in this window.
    pub fn hasImage(w: *const Window, img: Image) bool {
        return img.isValid() and w.images.contains(img.id);
    }

    /// Pixel size of a loaded image, or null if the handle is not loaded here.
    pub fn imageSize(w: *const Window, img: Image) ?struct { w: u32, h: u32 } {
        const t = w.images.get(img.id) orelse return null;
        return .{ .w = t.w, .h = t.h };
    }

    // ---- SVG icons ----------------------------------------------------

    /// Parses an SVG as a monochrome icon (see `svg.zig` for what is supported). Nothing is
    /// rasterised yet: that happens on first draw, once per pixel size (cached, bounded).
    /// Fails with `InvalidSvg` or `TooComplex`.
    pub fn loadSvg(w: *Window, bytes: []const u8) SvgError!SvgIcon {
        return w.loadSvgOpts(bytes, .{});
    }

    pub fn loadSvgOpts(w: *Window, bytes: []const u8, opts: SvgOptions) SvgError!SvgIcon {
        var doc = try svg_mod.parse(w.gpa, bytes);
        errdefer doc.deinit();
        const new_id = next_svg_id;
        try w.svgs.put(w.gpa, new_id, .{ .doc = doc, .color = opts.color });
        next_svg_id += 1;
        return .{ .id = new_id, .aspect = doc.aspect() };
    }

    /// Frees the icon and its cached textures; the handle (and copies) draw nothing afterwards.
    /// Call between frames (never while a display list that uses it is being rendered).
    pub fn unloadSvg(w: *Window, icon: SvgIcon) void {
        if (w.svgs.fetchRemove(icon.id)) |kv| {
            var doc = kv.value.doc;
            doc.deinit();
            w.svg_cache.removeIcon(w.gpa, icon.id, {}, destroySvgTexture);
        }
    }

    pub fn hasSvg(w: *const Window, icon: SvgIcon) bool {
        return icon.isValid() and w.svgs.contains(icon.id);
    }

    /// Number of icon textures currently cached (for tests and diagnostics).
    pub fn svgTextureCount(w: *const Window) usize {
        return w.svg_cache.count();
    }

    /// The device-pixel size an icon drawn into `r` gets: contain-fit, rounded to whole pixels.
    /// Pure; shared with the drawing code.
    pub fn svgPixelSize(r: geom.Rect, aspect: f32, density: f32) ?struct { w: u32, h: u32 } {
        const sw = r.w * density;
        const sh = r.h * density;
        if (!(sw >= 1 and sh >= 1) or !(aspect > 0) or !std.math.isFinite(sw) or !std.math.isFinite(sh)) return null;
        var wpx: f32 = undefined;
        var hpx: f32 = undefined;
        if (aspect >= 1) {
            wpx = @round(@min(sw, sh * aspect));
            hpx = @round(wpx / aspect);
        } else {
            hpx = @round(@min(sh, sw / aspect));
            wpx = @round(hpx * aspect);
        }
        wpx = @max(wpx, 1);
        hpx = @max(hpx, 1);
        const big = @max(wpx, hpx);
        const lim: f32 = @floatFromInt(max_svg_side);
        if (big > lim) {
            wpx = @max(1, @round(wpx * lim / big));
            hpx = @max(1, @round(hpx * lim / big));
        }
        return .{ .w = @intFromFloat(wpx), .h = @intFromFloat(hpx) };
    }

    /// Says once per icon why it did not draw (the failure is cached, so it would otherwise be
    /// a blank icon with no trace).
    fn noteSvgFailure(w: *Window, icon_id: u32, err: anyerror, wpx: u32, hpx: u32) void {
        const gop = w.svg_failed.getOrPut(w.gpa, icon_id) catch return;
        if (gop.found_existing) return;
        w.svg_failure_logs += 1;
        if (!@import("builtin").is_test) std.log.warn("svg icon {d} not drawn: {s} at {d}x{d} px", .{ icon_id, @errorName(err), wpx, hpx });
    }

    fn makeSvgTexture(w: *Window, icon_id: u32, e: *const SvgEntry, wpx: u32, hpx: u32) ?*c.Texture {
        const n = @as(usize, wpx) * hpx;
        const rgba = w.gpa.alloc(u8, n * 4) catch |err| {
            w.noteSvgFailure(icon_id, err, wpx, hpx);
            return null;
        };
        defer w.gpa.free(rgba);
        if (e.color) {
            const px = raster_mod.renderRgba(w.gpa, &e.doc, wpx, hpx, .{ .r = 255, .g = 255, .b = 255 }) catch |err| {
                w.noteSvgFailure(icon_id, err, wpx, hpx);
                return null;
            };
            defer w.gpa.free(px);
            @memcpy(rgba, px);
        } else {
            const mask = raster_mod.renderMask(w.gpa, &e.doc, wpx, hpx) catch |err| {
                w.noteSvgFailure(icon_id, err, wpx, hpx);
                return null;
            };
            defer w.gpa.free(mask);
            // Premultiplied white: the tint colour then scales it at draw time.
            for (mask, 0..) |a, i| rgba[i * 4 ..][0..4].* = .{ a, a, a, a };
        }
        const tex = c.SDL_CreateTexture(w.ren, c.PIXELFORMAT_RGBA32, c.TEXTUREACCESS_STATIC, @intCast(wpx), @intCast(hpx)) orelse return null;
        if (!c.SDL_UpdateTexture(tex, null, rgba.ptr, @intCast(wpx * 4))) {
            c.SDL_DestroyTexture(tex);
            return null;
        }
        _ = c.SDL_SetTextureBlendMode(tex, c.BLENDMODE_BLEND_PREMULTIPLIED);
        _ = c.SDL_SetTextureScaleMode(tex, c.SCALEMODE_LINEAR);
        return tex;
    }

    fn drawSvg(w: *Window, r: geom.Rect, icon: SvgIcon, color: Color) void {
        const e = w.svgs.getPtr(icon.id) orelse return;
        if (color.a == 0) return;
        const d = w.density;
        const aspect = e.doc.aspect();
        const sz = svgPixelSize(r, aspect, d) orelse return;
        const k = svg_cache.key(icon.id, sz.w, sz.h);
        const tex_opt: ?*c.Texture = w.svg_cache.get(k, w.frame) orelse blk: {
            const t = w.makeSvgTexture(icon.id, e, sz.w, sz.h);
            w.svg_cache.put(w.gpa, k, t, @as(usize, sz.w) * sz.h * 4, w.frame) catch {
                if (t) |tt| c.SDL_DestroyTexture(tt);
                return;
            };
            break :blk t;
        };
        const tex = tex_opt orelse return;
        // Snap to whole device pixels so a stroke that is a whole number of pixels stays crisp.
        const wf: f32 = @floatFromInt(sz.w);
        const hf: f32 = @floatFromInt(sz.h);
        const x0 = @round(r.x * d + (r.w * d - wf) / 2);
        const y0 = @round(r.y * d + (r.h * d - hf) / 2);
        const a = @as(f32, @floatFromInt(color.a)) / 255.0;
        const tr = @as(f32, @floatFromInt(color.r)) / 255.0 * a;
        const tg = @as(f32, @floatFromInt(color.g)) / 255.0 * a;
        const tb = @as(f32, @floatFromInt(color.b)) / 255.0 * a;
        const col: c.FColor = .{ .r = tr, .g = tg, .b = tb, .a = a };
        const l = x0 / d;
        const t = y0 / d;
        const rr = (x0 + wf) / d;
        const bb = (y0 + hf) / d;
        const verts = [4]c.Vertex{
            .{ .position = .{ .x = l, .y = t }, .color = col, .tex_coord = .{ .x = 0, .y = 0 } },
            .{ .position = .{ .x = rr, .y = t }, .color = col, .tex_coord = .{ .x = 1, .y = 0 } },
            .{ .position = .{ .x = rr, .y = bb }, .color = col, .tex_coord = .{ .x = 1, .y = 1 } },
            .{ .position = .{ .x = l, .y = bb }, .color = col, .tex_coord = .{ .x = 0, .y = 1 } },
        };
        const idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
        _ = c.SDL_RenderGeometry(w.ren, tex, &verts, 4, &idx, 6);
    }

    /// Sets the window icon from straight-alpha RGBA8 pixels (used by platforms that have
    /// window icons; on macOS see `macos.setDockIcon`).
    pub fn setIcon(w: *Window, rgba: []const u8, width: u32, height: u32) !void {
        if (!decode_mod.sizeOk(width, height) or rgba.len != @as(usize, width) * height * 4) return error.InvalidImage;
        const copy = try w.gpa.dupe(u8, rgba);
        defer w.gpa.free(copy);
        const surf = c.SDL_CreateSurfaceFrom(@intCast(width), @intCast(height), c.PIXELFORMAT_RGBA32, copy.ptr, @intCast(width * 4)) orelse return error.IconFailed;
        defer c.SDL_DestroySurface(surf);
        // SDL copies the surface into the window's icon images.
        if (!c.SDL_SetWindowIcon(w.win, surf)) return error.IconFailed;
    }

    /// `setIcon` from an encoded image (PNG, ...).
    pub fn setIconEncoded(w: *Window, bytes: []const u8) !void {
        const d = try decode_mod.decode(w.gpa, bytes);
        defer d.deinit(w.gpa);
        try w.setIcon(d.pixels, d.width, d.height);
    }

    fn drawImage(w: *Window, r: geom.Rect, img: Image, opts: ImageOpts) void {
        const t = w.images.get(img.id) orelse return;
        const opacity = std.math.clamp(opts.opacity, 0, 1);
        const a = opacity * @as(f32, @floatFromInt(opts.tint.a)) / 255.0;
        if (a <= 0) return;
        const pl = image_mod.place(r, @floatFromInt(img.width), @floatFromInt(img.height), opts.fit);
        const d = pl.dest;
        if (d.w <= 0 or d.h <= 0) return;
        // Premultiplied vertex colour: rgb scaled by the alpha, as the texture is.
        const tint = [3]f32{
            @as(f32, @floatFromInt(opts.tint.r)) / 255.0 * a,
            @as(f32, @floatFromInt(opts.tint.g)) / 255.0 * a,
            @as(f32, @floatFromInt(opts.tint.b)) / 255.0 * a,
        };
        const iw: f32 = @floatFromInt(img.width);
        const ih: f32 = @floatFromInt(img.height);

        var pts: [4 * (rrect_seg + 1)][2]f32 = undefined;
        var nrm: [4 * (rrect_seg + 1)][2]f32 = undefined;
        const n = rrectOutline(d, opts.radius, &pts, &nrm);
        const f = 0.5 / w.density;
        var cx: f32 = 0;
        var cy: f32 = 0;
        for (pts[0..n]) |p| {
            cx += p[0];
            cy += p[1];
        }
        const nf: f32 = @floatFromInt(n);
        const Map = struct {
            d: geom.Rect,
            s: geom.Rect,
            iw: f32,
            ih: f32,
            fn uv(m: @This(), x: f32, y: f32) c.FPoint {
                const u = (m.s.x + (x - m.d.x) / m.d.w * m.s.w) / m.iw;
                const v = (m.s.y + (y - m.d.y) / m.d.h * m.s.h) / m.ih;
                return .{ .x = std.math.clamp(u, 0, 1), .y = std.math.clamp(v, 0, 1) };
            }
        };
        const map: Map = .{ .d = d, .s = pl.src, .iw = iw, .ih = ih };
        const center = w.tvert(cx / nf, cy / nf, map, tint, a, 1);
        const inner = center + 1;
        for (pts[0..n], nrm[0..n]) |p, m| _ = w.tvert(p[0] - m[0] * f, p[1] - m[1] * f, map, tint, a, 1);
        const outer = inner + @as(c_int, @intCast(n));
        for (pts[0..n], nrm[0..n]) |p, m| _ = w.tvert(p[0] + m[0] * f, p[1] + m[1] * f, map, tint, a, 0);
        for (0..n) |i| {
            const p: c_int = @intCast(i);
            const q: c_int = @intCast((i + 1) % n);
            w.tri(center, inner + p, inner + q);
            w.tri(inner + p, outer + p, outer + q);
            w.tri(inner + p, outer + q, inner + q);
        }
        _ = c.SDL_RenderGeometry(w.ren, t.tex, w.verts.items.ptr, @intCast(w.verts.items.len), w.idx.items.ptr, @intCast(w.idx.items.len));
        w.verts.clearRetainingCapacity();
        w.idx.clearRetainingCapacity();
    }

    fn tvert(w: *Window, x: f32, y: f32, map: anytype, tint: [3]f32, a: f32, edge: f32) c_int {
        const i: c_int = @intCast(w.verts.items.len);
        w.verts.append(w.gpa, .{
            .position = .{ .x = x, .y = y },
            .color = .{ .r = tint[0] * edge, .g = tint[1] * edge, .b = tint[2] * edge, .a = a * edge },
            .tex_coord = map.uv(x, y),
        }) catch @panic("out of memory");
        return i;
    }

    // ---- files --------------------------------------------------------

    /// Shows the system open-file dialog (asynchronous; it may finish on another thread).
    /// Poll `takeDialogResult` each frame for the outcome. Only one dialog at a time in the whole
    /// app: `error.DialogBusy` while one is open or its result has not been taken, whichever
    /// window opened it. The result goes to this window only.
    pub fn openFileDialog(w: *Window, opts: FileDialogOptions) error{DialogBusy}!void {
        lockDialog();
        if (dialog_pending or dialog_done != null) {
            unlockDialog();
            return error.DialogBusy;
        }
        dialog_pending = true;
        dialog_orphaned = false;
        dialog_owner = w.id();
        unlockDialog();
        const n = @min(opts.filters.len, dialog_filters.len);
        for (opts.filters[0..n], 0..) |flt, i| dialog_filters[i] = .{ .name = flt.name, .pattern = flt.pattern };
        c.SDL_ShowOpenFileDialog(dialogCallback, null, w.win, if (n > 0) &dialog_filters else null, @intCast(n), opts.default_location, opts.allow_many);
    }

    /// The finished dialog's outcome, once, or null while it is still open (or none was
    /// shown by this window; a window destroyed with a dialog open drops its result). Paths are copied into `gpa`; free with `ChosenFiles.deinit(gpa)`.
    pub fn takeDialogResult(w: *Window, gpa: std.mem.Allocator) error{OutOfMemory}!?DialogResult {
        // Another window's dialog is not ours to take.
        if (dialog_owner != w.id()) return null;
        return takeRawDialog(gpa);
    }

    pub fn setAlwaysOnTop(w: *Window, on: bool) void {
        _ = c.SDL_SetWindowAlwaysOnTop(w.win, on);
    }

    /// Asks for `cur` for the frame being drawn. Applied (and reset to arrow) by the next
    /// `render`, so a widget that stops asking gets the arrow back. `Ui.setCursor` calls this.
    pub fn setCursor(w: *Window, cur: Cursor) void {
        w.cursor_wanted = cur;
    }

    fn applyCursor(w: *Window) void {
        const want = w.cursor_wanted;
        w.cursor_wanted = .arrow;
        if (!cursorOwner(c.SDL_GetMouseFocus(), w.win)) return;
        // Same cursor again is skipped, but not when the pointer just came from another window.
        if (cursor_applied == want and cursor_applied_for == w.win) return;
        cursor_applied = want;
        cursor_applied_for = w.win;
        if (systemCursor(want)) |cur| _ = c.SDL_SetCursor(cur);
    }

    /// Draws the display list and presents the frame.
    pub fn render(w: *Window, list: *const gfx.DisplayList, clear: Color) void {
        if (w.in_render) return;
        w.in_render = true;
        defer w.in_render = false;
        w.applyCursor();
        w.syncMetrics();
        w.drawn_key = w.sizeKey();
        w.frame += 1;
        _ = c.SDL_SetRenderDrawColor(w.ren, clear.r, clear.g, clear.b, clear.a);
        _ = c.SDL_RenderClear(w.ren);
        w.clip_n = 0;
        w.clip_overflow = 0;
        for (list.cmds.items) |cmd| switch (cmd) {
            .rrect => |r| w.addRRect(r.rect, r.radius, r.color),
            .ellipse => |e| w.addEllipse(e.cx, e.cy, e.rx, e.ry, e.color),
            .arc => |a| w.addArc(a.cx, a.cy, a.r, a.a0, a.a1, a.width, a.color),
            .line => |l| w.addLine(l.x0, l.y0, l.x1, l.y1, l.width, l.color),
            .image => |im| {
                w.flush();
                w.drawImage(im.rect, im.image, im.opts);
            },
            .svg_icon => |sv| {
                w.flush();
                w.drawSvg(sv.rect, sv.icon, sv.color);
            },
            .text => |t| {
                w.flush();
                w.drawText(t.x, t.y, t.str, t.size, t.color, t.alignment, t.weight);
            },
            .push_clip => |r| w.pushClip(r),
            .pop_clip => w.popClip(),
        };
        w.flush();
        _ = c.SDL_SetRenderClipRect(w.ren, null);
        if (w.snapshot_path) |path| {
            w.snapshot_path = null;
            if (c.SDL_RenderReadPixels(w.ren, null)) |surf| {
                defer c.SDL_DestroySurface(surf);
                if (!c.SDL_SaveBMP(surf, path)) std.log.warn("snapshot failed: {s}", .{c.SDL_GetError()});
            }
        }
        _ = c.SDL_RenderPresent(w.ren);
        w.evictTexts();
        w.svg_cache.evict(w.gpa, w.frame, {}, destroySvgTexture);
    }

    // ---- clipping -----------------------------------------------------

    fn pushClip(w: *Window, r: geom.Rect) void {
        w.flush(); // geometry queued so far belongs to the old clip
        var next = r;
        if (w.clip_n > 0) {
            const p = if (w.clip_overflow > 0) w.clip_over else w.clips[w.clip_n - 1];
            const x0 = @max(p.x, r.x);
            const y0 = @max(p.y, r.y);
            const x1 = @min(p.x + p.w, r.x + r.w);
            const y1 = @min(p.y + p.h, r.y + r.h);
            next = .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
        }
        if (w.clip_n < w.clips.len and w.clip_overflow == 0) {
            w.clips[w.clip_n] = next;
            w.clip_n += 1;
        } else {
            // Too deep: remember the depth, and keep the innermost intersected until it unwinds.
            w.clip_overflow += 1;
            w.clip_over = next;
        }
        w.applyClip();
    }

    fn popClip(w: *Window) void {
        w.flush();
        if (w.clip_overflow > 0) {
            w.clip_overflow -= 1;
        } else if (w.clip_n > 0) {
            w.clip_n -= 1;
        }
        w.applyClip();
    }

    /// The clip rect is given to SDL in the renderer's scaled (point)
    /// coordinates, like every other draw call. It is widened to whole units.
    fn applyClip(w: *Window) void {
        if (w.clip_n == 0) {
            _ = c.SDL_SetRenderClipRect(w.ren, null);
            return;
        }
        const r = if (w.clip_overflow > 0) w.clip_over else w.clips[w.clip_n - 1];
        const ir = clipInts(r);
        _ = c.SDL_SetRenderClipRect(w.ren, &ir);
    }

    /// The whole-unit clip rectangle for `r`. SDL reads a negative size as "no clipping", so the
    /// result never has one: a rectangle that is NaN, or reaches NaN (inf - inf), clips everything
    /// away, and infinite or huge edges are limited to +-1e6 instead of collapsing to 0.
    fn clipInts(r: geom.Rect) c.SdlRect {
        const none: c.SdlRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const rx1 = r.x + r.w;
        const ry1 = r.y + r.h;
        if (std.math.isNan(r.x) or std.math.isNan(r.y) or std.math.isNan(rx1) or std.math.isNan(ry1)) return none;
        const x0 = clampInt(@floor(r.x));
        const y0 = clampInt(@floor(r.y));
        const x1 = clampInt(@ceil(rx1));
        const y1 = clampInt(@ceil(ry1));
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    // ---- shapes -------------------------------------------------------

    fn flush(w: *Window) void {
        if (w.idx.items.len > 0) {
            _ = c.SDL_RenderGeometry(w.ren, null, w.verts.items.ptr, @intCast(w.verts.items.len), w.idx.items.ptr, @intCast(w.idx.items.len));
        }
        w.verts.clearRetainingCapacity();
        w.idx.clearRetainingCapacity();
    }

    fn vert(w: *Window, x: f32, y: f32, col: Color, a: f32) c_int {
        const i: c_int = @intCast(w.verts.items.len);
        w.verts.append(w.gpa, .{
            .position = .{ .x = x, .y = y },
            .color = .{
                .r = @as(f32, @floatFromInt(col.r)) / 255.0,
                .g = @as(f32, @floatFromInt(col.g)) / 255.0,
                .b = @as(f32, @floatFromInt(col.b)) / 255.0,
                .a = a * @as(f32, @floatFromInt(col.a)) / 255.0,
            },
            .tex_coord = .{ .x = 0, .y = 0 },
        }) catch @panic("out of memory");
        return i;
    }

    fn tri(w: *Window, a: c_int, b: c_int, d: c_int) void {
        w.idx.appendSlice(w.gpa, &.{ a, b, d }) catch @panic("out of memory");
    }

    /// Fills a convex outline, with a one-pixel alpha feather for smooth edges.
    fn addConvex(w: *Window, pts: []const [2]f32, nrm: []const [2]f32, col: Color) void {
        const n = pts.len;
        const f = 0.5 / w.density;
        var cx: f32 = 0;
        var cy: f32 = 0;
        for (pts) |p| {
            cx += p[0];
            cy += p[1];
        }
        const nf: f32 = @floatFromInt(n);
        const center = w.vert(cx / nf, cy / nf, col, 1);
        const inner = center + 1;
        for (pts, nrm) |p, m| _ = w.vert(p[0] - m[0] * f, p[1] - m[1] * f, col, 1);
        const outer = inner + @as(c_int, @intCast(n));
        for (pts, nrm) |p, m| _ = w.vert(p[0] + m[0] * f, p[1] + m[1] * f, col, 0);
        for (0..n) |i| {
            const a: c_int = @intCast(i);
            const b: c_int = @intCast((i + 1) % n);
            w.tri(center, inner + a, inner + b);
            w.tri(inner + a, outer + a, outer + b);
            w.tri(inner + a, outer + b, inner + b);
        }
    }

    fn addRRect(w: *Window, r: geom.Rect, radius: f32, col: Color) void {
        var pts: [4 * (rrect_seg + 1)][2]f32 = undefined;
        var nrm: [4 * (rrect_seg + 1)][2]f32 = undefined;
        const n = rrectOutline(r, radius, &pts, &nrm);
        w.addConvex(pts[0..n], nrm[0..n], col);
    }

    fn addEllipse(w: *Window, cx: f32, cy: f32, rx: f32, ry: f32, col: Color) void {
        const n = 48;
        var pts: [n][2]f32 = undefined;
        var nrm: [n][2]f32 = undefined;
        for (0..n) |i| {
            const ang = @as(f32, @floatFromInt(i)) / n * 2.0 * std.math.pi;
            pts[i] = .{ cx + @cos(ang) * rx, cy + @sin(ang) * ry };
            const gx = @cos(ang) / @max(rx, 0.001);
            const gy = @sin(ang) / @max(ry, 0.001);
            const len = @max(@sqrt(gx * gx + gy * gy), 1e-6);
            nrm[i] = .{ gx / len, gy / len };
        }
        w.addConvex(&pts, &nrm, col);
    }

    fn addLine(w: *Window, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, col: Color) void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len = @sqrt(dx * dx + dy * dy);
        const hw = width / 2;
        if (len < 0.01) {
            w.addEllipse(x0, y0, hw, hw, col);
            return;
        }
        const tx = dx / len;
        const ty = dy / len;
        const nx = -ty;
        const ny = tx;
        const pts = [4][2]f32{
            .{ x0 + nx * hw, y0 + ny * hw },
            .{ x1 + nx * hw, y1 + ny * hw },
            .{ x1 - nx * hw, y1 - ny * hw },
            .{ x0 - nx * hw, y0 - ny * hw },
        };
        const nrm = [4][2]f32{ .{ nx, ny }, .{ nx, ny }, .{ -nx, -ny }, .{ -nx, -ny } };
        w.addConvex(&pts, &nrm, col);
        w.addEllipse(x0, y0, hw, hw, col);
        w.addEllipse(x1, y1, hw, hw, col);
    }

    fn addArc(w: *Window, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, width: f32, col: Color) void {
        const f = 0.5 / w.density;
        const hw = width / 2;
        const steps: usize = @intFromFloat(std.math.clamp(@abs(a1 - a0) * r / 2.0, 8, 64));
        const radii = [4]f32{ r + hw + f, r + hw - f, r - hw + f, r - hw - f };
        const alphas = [4]f32{ 0, 1, 1, 0 };
        const base: c_int = @intCast(w.verts.items.len);
        for (0..steps + 1) |s| {
            const ang = a0 + (a1 - a0) * @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            for (radii, alphas) |rr, al| _ = w.vert(cx + @cos(ang) * rr, cy + @sin(ang) * rr, col, al);
        }
        for (0..steps) |s| {
            const row = base + @as(c_int, @intCast(s)) * 4;
            for (0..3) |j| {
                const a = row + @as(c_int, @intCast(j));
                w.tri(a, a + 1, a + 4);
                w.tri(a + 1, a + 5, a + 4);
            }
        }
        // Round caps.
        w.addEllipse(cx + @cos(a0) * r, cy + @sin(a0) * r, hw, hw, col);
        w.addEllipse(cx + @cos(a1) * r, cy + @sin(a1) * r, hw, hw, col);
    }

    // ---- text ---------------------------------------------------------

    fn openSource(src: FontSource, ptsize: f32) ?*c.Font {
        switch (src) {
            .bytes => |bytes| {
                const io = c.SDL_IOFromConstMem(bytes.ptr, bytes.len) orelse return null;
                // closeio = true: the font owns the stream (the bytes stay with the caller).
                return c.TTF_OpenFontIO(io, true, ptsize);
            },
            .path => |path| return c.TTF_OpenFont(path.ptr, ptsize),
        }
    }

    fn openUiFont(w: *Window, px: u32, weight: gfx.Weight) ?*c.Font {
        if (w.font_set) |set| {
            const bytes = set.forWeight(weight);
            return openSource(.{ .bytes = bytes }, @floatFromInt(px));
        }
        for (font_paths) |path| {
            if (c.TTF_OpenFont(path, @floatFromInt(px))) |font| return font;
        }
        return null;
    }

    /// Index in `fonts` of the UI font for this size and weight, opening it the first time.
    fn fontIndex(w: *Window, px: u32, weight: gfx.Weight) ?usize {
        for (w.fonts.items, 0..) |f, i| if (f.px == px and f.weight == weight) return i;
        const font = w.openUiFont(px, weight) orelse return null;
        w.fonts.append(w.gpa, .{ .px = px, .weight = weight, .font = font }) catch @panic("out of memory");
        return w.fonts.items.len - 1;
    }

    fn fallbackCount(w: *const Window) usize {
        return w.fallback_sources.len + (if (w.system_fallback) system_fallback_paths.len else 0);
    }

    fn fallbackSource(w: *const Window, index: usize) FontSource {
        if (index < w.fallback_sources.len) return w.fallback_sources[index];
        if (comptime system_fallback_paths.len == 0) unreachable; // fallbackCount() is 0 then
        return .{ .path = system_fallback_paths[index - w.fallback_sources.len] };
    }

    /// The fallback font number `index` at `px`, opened the first time; null if it cannot be opened.
    fn fallbackFont(w: *Window, index: u16, px: u32) ?*c.Font {
        for (w.fb_fonts.items) |f| if (f.index == index and f.px == px) return f.font;
        const font = openSource(w.fallbackSource(index), @floatFromInt(px));
        w.fb_fonts.append(w.gpa, .{ .index = index, .px = px, .font = font }) catch @panic("out of memory");
        return font;
    }

    /// The UI font `i`, with the fallback fonts attached to it when `text` holds a character it
    /// has no glyph for. Strings the UI font covers (all Latin text) never open a fallback.
    fn withFallbacks(w: *Window, i: usize, text: []const u8) *c.Font {
        const f = &w.fonts.items[i];
        if (f.fb_attached or !needsFallback(f.font, text)) return f.font;
        f.fb_attached = true;
        for (0..w.fallbackCount()) |k| {
            if (w.fallbackFont(@intCast(k), f.px)) |fb| _ = c.TTF_AddFallbackFont(f.font, fb);
        }
        return f.font;
    }

    // ---- colour emoji ----

    /// Opens the emoji font and learns its strikes the first time; false if there is none.
    fn emojiReady(w: *Window) bool {
        if (!w.colour_emoji) return false;
        switch (w.emoji.status) {
            .ready => return true,
            .unavailable => return false,
            .untried => {},
        }
        w.emoji.status = .unavailable;
        w.emoji.advance_pct = if (w.emoji_source == null) system_emoji_advance_pct else 100;
        w.emoji.drop_pct = if (w.emoji_source == null) system_emoji_drop_pct else 0;
        const src: FontSource = w.emoji_source orelse if (system_emoji_path) |p| .{ .path = p } else return false;
        // Size 0.5 is strike 0 for a bitmap font, which takes an index, not a size.
        const font = openSource(src, 0.5) orelse return false;
        const st = &w.emoji;
        if (c.TTF_FontIsScalable(font)) {
            // Colour outlines (COLR): sized like any font, opened per pixel size on demand.
            st.scalable = true;
            c.TTF_CloseFont(font);
            st.status = .ready;
            return true;
        }
        var last: c_int = 0;
        var idx: u8 = 0;
        while (idx < max_strikes) : (idx += 1) {
            if (idx > 0 and !c.TTF_SetFontSize(font, @as(f32, @floatFromInt(idx)) + 0.5)) break;
            const asc = c.TTF_GetFontAscent(font);
            // SDL_ttf clamps the index at the last strike, so the ascent stops growing there.
            if (asc <= last or asc > std.math.maxInt(u16)) break;
            st.strikes[idx] = @intCast(asc);
            last = asc;
        }
        st.n_strikes = idx;
        if (idx == 0) {
            c.TTF_CloseFont(font);
            return false;
        }
        // The font now sits on its last strike.
        st.fonts.append(w.gpa, .{ .key = idx - 1, .font = font }) catch @panic("out of memory");
        st.status = .ready;
        return true;
    }

    const EmojiSize = struct { font: *c.Font, num: u32, den: u32 };

    /// The emoji font opened for text `px` pixels tall, and the ratio (`num / den`) its glyph
    /// bitmaps are scaled by: the smallest strike at least `px` tall, shrunk to `px`.
    fn emojiFontFor(w: *Window, px: u32) ?EmojiSize {
        if (!w.emojiReady()) return null;
        const st = &w.emoji;
        const src: FontSource = w.emoji_source orelse if (system_emoji_path) |p| .{ .path = p } else return null;
        var key: u32 = px;
        var ptsize: f32 = @floatFromInt(px);
        var num: u32 = 1;
        var den: u32 = 1;
        if (!st.scalable) {
            var k: usize = st.n_strikes - 1;
            for (st.strikes[0..st.n_strikes], 0..) |strike, i| {
                if (strike >= px) {
                    k = i;
                    break;
                }
            }
            key = @intCast(k);
            ptsize = @as(f32, @floatFromInt(k)) + 0.5;
            num = px;
            den = st.strikes[k];
        }
        for (st.fonts.items) |f| if (f.key == key) return .{ .font = f.font, .num = num, .den = den };
        const font = openSource(src, ptsize) orelse return null;
        st.fonts.append(w.gpa, .{ .key = key, .font = font }) catch @panic("out of memory");
        return .{ .font = font, .num = num, .den = den };
    }

    const no_advance: u32 = std.math.maxInt(u32);

    /// Width in pixels of the emoji cluster at `px`; null if the emoji font cannot draw it (no
    /// font, or no glyph for its first code point), when it is drawn as ordinary text.
    fn emojiAdvance(w: *Window, cluster: []const u8, px: u32) ?u32 {
        var h = std.hash.Wyhash.init(px);
        h.update(cluster);
        const key = h.final();
        if (w.emoji_adv.get(key)) |v| return if (v == no_advance) null else v;
        const v = w.emojiAdvanceUncached(cluster, px);
        w.emoji_adv.put(w.gpa, key, v orelse no_advance) catch {};
        return v;
    }

    fn emojiAdvanceUncached(w: *Window, cluster: []const u8, px: u32) ?u32 {
        const ef = w.emojiFontFor(px) orelse return null;
        const n = std.unicode.utf8ByteSequenceLength(cluster[0]) catch return null;
        if (n > cluster.len) return null;
        const first = std.unicode.utf8Decode(cluster[0..n]) catch return null;
        if (!c.TTF_FontHasGlyph(ef.font, first)) return null;
        var tw: c_int = 0;
        var th: c_int = 0;
        if (!c.TTF_GetStringSize(ef.font, cluster.ptr, cluster.len, &tw, &th) or tw <= 0) return null;
        return compose.scaled(@intCast(tw), ef.num * w.emoji.advance_pct, ef.den * 100);
    }

    /// An emoji cluster drawn at `px`: straight-alpha RGBA, `base` rows from the top to the baseline.
    const EmojiBitmap = struct { w: u32, h: u32, base: u32, rgba: []u8 };

    fn emojiBitmap(w: *Window, cluster: []const u8, px: u32) ?EmojiBitmap {
        const ef = w.emojiFontFor(px) orelse return null;
        // White: the emoji font's colours are in the glyphs, and SDL_ttf leaves them alone.
        const surf = c.TTF_RenderText_Blended(ef.font, cluster.ptr, cluster.len, .{ .r = 255, .g = 255, .b = 255, .a = 255 }) orelse return null;
        defer c.SDL_DestroySurface(surf);
        const hdr: *const c.SurfaceHeader = @ptrCast(@alignCast(surf));
        const pixels = hdr.pixels orelse return null;
        if (hdr.format != c.PIXELFORMAT_ARGB8888 or hdr.w <= 0 or hdr.h <= 0 or hdr.pitch < hdr.w * 4) return null;
        const sw: u32 = @intCast(hdr.w);
        const sh: u32 = @intCast(hdr.h);
        const dw = compose.scaled(sw, ef.num, ef.den);
        const dh = compose.scaled(sh, ef.num, ef.den);
        const asc: u32 = @intCast(@max(0, c.TTF_GetFontAscent(ef.font)));
        const rgba = compose.scaleBgraPremulToRgba(w.gpa, pixels[0 .. @as(usize, @intCast(hdr.pitch)) * sh], sw, sh, @intCast(hdr.pitch), dw, dh) catch return null;
        return .{ .w = dw, .h = dh, .base = compose.scaled(asc, ef.num, ef.den), .rgba = rgba };
    }

    /// Pixel width of `str` drawn with UI font `i`, as SDL_ttf lays it out (fallback fonts included).
    fn plainWidth(w: *Window, i: usize, str: []const u8) u32 {
        const font = w.withFallbacks(i, str);
        var tw: c_int = 0;
        var th: c_int = 0;
        if (!c.TTF_GetStringSize(font, str.ptr, str.len, &tw, &th)) return 0;
        return @intCast(@max(0, tw));
    }

    /// Whether `str` has an emoji cluster the emoji font can draw (otherwise the whole string goes
    /// through SDL_ttf as it always did).
    fn hasEmojiRuns(w: *Window, str: []const u8, px: u32) bool {
        if (!w.colour_emoji or !emoji_mod.mayContainEmoji(str) or !w.emojiReady()) return false;
        var it = emoji_mod.runs(str);
        while (it.next()) |r| {
            if (r.emoji and w.emojiAdvance(r.slice(str), px) != null) return true;
        }
        return false;
    }

    /// Pixel width of one run of a string that has emoji in it.
    fn runWidth(w: *Window, i: usize, str: []const u8, r: emoji_mod.Run, px: u32) u32 {
        if (r.emoji) {
            if (w.emojiAdvance(r.slice(str), px)) |a| return a;
        }
        return w.plainWidth(i, r.slice(str));
    }

    /// The texture of `str` for text pixels `px` tall in colour `col`, or null if nothing could be drawn.
    fn textTexture(w: *Window, i: usize, str: []const u8, col: Color, px: u32) ?CachedText {
        w.text_never = false;
        if (w.hasEmojiRuns(str, px)) {
            if (w.composeText(i, str, col, px)) |t| return t;
            w.text_never = false; // the plain path below may still draw it
        }
        const font = w.withFallbacks(i, str);
        const fh = c.TTF_GetFontHeight(font);
        if (fh <= 0 or !textSurfaceOk(w.plainWidth(i, str), @intCast(fh))) {
            w.text_never = true;
            return null;
        }
        const surf = c.TTF_RenderText_Blended(font, str.ptr, str.len, .{ .r = col.r, .g = col.g, .b = col.b, .a = col.a }) orelse return null;
        defer c.SDL_DestroySurface(surf);
        const hdr: *const c.SurfaceHeader = @ptrCast(@alignCast(surf));
        if (hdr.w > 0 and @as(u32, @intCast(hdr.w)) > w.maxTextureSize()) {
            if (hdr.pixels == null or hdr.format != c.PIXELFORMAT_ARGB8888 or hdr.h <= 0 or hdr.pitch < hdr.w * 4) return null;
            return w.stripTexture(c.PIXELFORMAT_ARGB8888, c.BLENDMODE_BLEND, hdr.pixels.?, @intCast(hdr.pitch), @intCast(hdr.w), @intCast(hdr.h));
        }
        const tex = c.SDL_CreateTextureFromSurface(w.ren, surf) orelse return null;
        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &tw, &th);
        return .{ .tex = tex, .w = tw / w.density, .h = th / w.density, .pw = tw, .ph = th, .last_frame = w.frame };
    }

    fn maxTextureSize(w: *const Window) u32 {
        return w.max_tex;
    }

    /// Uploads a line of pixels wider than the renderer's maximum texture as side-by-side strips.
    /// `pixels` is `height` rows of `pitch` bytes, 4 bytes per pixel in `format`.
    fn stripTexture(w: *Window, format: u32, blend: u32, pixels: [*]const u8, pitch: usize, width: usize, height: usize) ?CachedText {
        const max: usize = w.maxTextureSize();
        const n = (width + max - 1) / max;
        const texs = w.gpa.alloc(*c.Texture, n) catch return null;
        var made: usize = 0;
        while (made < n) : (made += 1) {
            const x0 = made * max;
            const sw = @min(max, width - x0);
            const tex = c.SDL_CreateTexture(w.ren, format, c.TEXTUREACCESS_STATIC, @intCast(sw), @intCast(height)) orelse break;
            if (!c.SDL_UpdateTexture(tex, null, pixels + x0 * 4, @intCast(pitch))) {
                c.SDL_DestroyTexture(tex);
                break;
            }
            _ = c.SDL_SetTextureBlendMode(tex, blend);
            texs[made] = tex;
        }
        if (made < n) {
            for (texs[0..made]) |t| c.SDL_DestroyTexture(t);
            w.gpa.free(texs);
            return null;
        }
        const rest = if (n > 1) w.gpa.dupe(*c.Texture, texs[1..]) catch null else &[0]*c.Texture{};
        defer w.gpa.free(texs);
        if (rest == null) {
            for (texs) |t| c.SDL_DestroyTexture(t);
            return null;
        }
        return .{
            .tex = texs[0],
            .more = rest.?,
            .w = @as(f32, @floatFromInt(width)) / w.density,
            .h = @as(f32, @floatFromInt(height)) / w.density,
            .pw = @floatFromInt(width),
            .ph = @floatFromInt(height),
            .last_frame = w.frame,
        };
    }

    fn destroyText(w: *Window, t: CachedText) void {
        c.SDL_DestroyTexture(t.tex);
        for (t.more) |m| c.SDL_DestroyTexture(m);
        if (t.more.len > 0) w.gpa.free(t.more);
    }

    /// A line of text as straight-alpha RGBA pixels.
    const Composed = struct { rgba: []u8, w: usize, h: usize };

    /// Draws a string with emoji in it into pixels: each emoji cluster from the colour emoji font
    /// (scaled to the text size, keeping its own colours; the text colour only sets its opacity)
    /// and the stretches between them from the UI font, side by side on one baseline. The caller
    /// frees `rgba` with the window's allocator.
    fn composeBuffer(w: *Window, i: usize, str: []const u8, col: Color, px: u32) ?Composed {
        const ui_font = w.fonts.items[i].font;
        const height_i = c.TTF_GetFontHeight(ui_font);
        const ascent_i = c.TTF_GetFontAscent(ui_font);
        if (height_i <= 0) {
            w.text_never = true;
            return null;
        }
        const height: usize = @intCast(height_i);
        var total: usize = 0;
        var it = emoji_mod.runs(str);
        while (it.next()) |r| total += w.runWidth(i, str, r, px);
        if (total == 0 or !textSurfaceOk(total, height)) {
            w.text_never = true;
            return null;
        }
        const buf = w.gpa.alloc(u8, total * height * 4) catch return null;
        @memset(buf, 0);
        var x: usize = 0;
        it = emoji_mod.runs(str);
        while (it.next()) |r| {
            const piece = r.slice(str);
            const rw = w.runWidth(i, str, r, px);
            if (r.emoji and w.emojiAdvance(piece, px) != null) {
                if (w.emojiBitmap(piece, px)) |bm| {
                    defer w.gpa.free(bm.rgba);
                    // Centred in its advance, which is wider than the bitmap for the system font.
                    const pad = @divFloor(@as(i64, @intCast(rw)) - bm.w, 2);
                    compose.overRgba(buf, total, height, bm.rgba, bm.w, bm.h, @as(i64, @intCast(x)) + pad, @as(i64, ascent_i) - bm.base + @as(i64, (px * w.emoji.drop_pct + 50) / 100), col.a);
                }
            } else {
                const font = w.withFallbacks(i, piece);
                if (c.TTF_RenderText_Blended(font, piece.ptr, piece.len, .{ .r = col.r, .g = col.g, .b = col.b, .a = col.a })) |surf| {
                    defer c.SDL_DestroySurface(surf);
                    const hdr: *const c.SurfaceHeader = @ptrCast(@alignCast(surf));
                    if (hdr.pixels != null and hdr.format == c.PIXELFORMAT_ARGB8888 and hdr.w > 0 and hdr.h > 0) {
                        const sw: usize = @min(@as(usize, @intCast(hdr.w)), rw);
                        const pitch: usize = @intCast(hdr.pitch);
                        const sh: usize = @intCast(hdr.h);
                        compose.overArgb(buf, total, height, hdr.pixels.?[0 .. pitch * sh], sw, sh, pitch, @intCast(x), 0);
                    }
                }
            }
            x += rw;
        }
        return .{ .rgba = buf, .w = total, .h = height };
    }

    fn composeText(w: *Window, i: usize, str: []const u8, col: Color, px: u32) ?CachedText {
        const line = w.composeBuffer(i, str, col, px) orelse return null;
        defer w.gpa.free(line.rgba);
        compose.premultiply(line.rgba);
        if (line.w > w.maxTextureSize()) return w.stripTexture(c.PIXELFORMAT_RGBA32, c.BLENDMODE_BLEND_PREMULTIPLIED, line.rgba.ptr, line.w * 4, line.w, line.h);
        const tex = c.SDL_CreateTexture(w.ren, c.PIXELFORMAT_RGBA32, c.TEXTUREACCESS_STATIC, @intCast(line.w), @intCast(line.h)) orelse return null;
        if (!c.SDL_UpdateTexture(tex, null, line.rgba.ptr, @intCast(line.w * 4))) {
            c.SDL_DestroyTexture(tex);
            return null;
        }
        // Premultiplied, like images: linear filtering at an edge then never mixes in the
        // colour of a transparent texel, which would darken light text.
        _ = c.SDL_SetTextureBlendMode(tex, c.BLENDMODE_BLEND_PREMULTIPLIED);
        return .{
            .tex = tex,
            .w = @as(f32, @floatFromInt(line.w)) / w.density,
            .h = @as(f32, @floatFromInt(line.h)) / w.density,
            .pw = @floatFromInt(line.w),
            .ph = @floatFromInt(line.h),
            .last_frame = w.frame,
        };
    }

    /// Width in points that `str` takes when drawn at `size` (regular weight).
    pub fn measureText(w: *Window, str: []const u8, size: f32) f32 {
        return w.measureTextWeighted(str, size, .regular);
    }

    /// Width in points that `str` takes when drawn at `size` in `weight`: the width of the texture
    /// `drawText` makes for it, emoji and fallback fonts included.
    pub fn measureTextWeighted(w: *Window, str: []const u8, size: f32, weight: gfx.Weight) f32 {
        if (str.len == 0) return 0;
        const px = w.textPx(size) orelse return 0;
        const i = w.fontIndex(px, weight) orelse return 0;
        var total: u32 = 0;
        if (w.hasEmojiRuns(str, px)) {
            var it = emoji_mod.runs(str);
            while (it.next()) |r| total += w.runWidth(i, str, r, px);
        } else {
            total = w.plainWidth(i, str);
        }
        return @as(f32, @floatFromInt(total)) / w.density;
    }

    fn drawText(w: *Window, x: f32, y: f32, str: []const u8, size: f32, col: Color, alignment: gfx.Align, weight: gfx.Weight) void {
        if (str.len == 0) return;
        const px = w.textPx(size) orelse return;
        var h = std.hash.Wyhash.init(@as(u64, px) << 8 | @intFromEnum(weight));
        h.update(str);
        h.update(std.mem.asBytes(&col));
        const key = h.final();

        const entry = w.texts.getPtr(key) orelse blk: {
            var prior: ?TextMiss = null;
            if (w.text_misses.getPtr(key)) |m| {
                m.seen = w.frame;
                if (w.frame < m.retry_at) return;
                prior = m.*; // a failure that may have passed: try again, not every frame
            }
            const i = w.fontIndex(px, weight) orelse return;
            const t = w.textTexture(i, str, col, px) orelse {
                w.text_misses.put(w.gpa, key, TextMiss.failed(prior, w.frame, w.text_never)) catch @panic("out of memory");
                return;
            };
            _ = w.text_misses.remove(key);
            w.texts.put(w.gpa, key, t) catch @panic("out of memory");
            break :blk w.texts.getPtr(key).?;
        };
        entry.last_frame = w.frame;
        const o = textOrigin(x, y, entry.pw, alignment, w.density);
        const d = w.density;
        const first_w = if (entry.more.len > 0) blk: {
            var tw: f32 = 0;
            var th: f32 = 0;
            _ = c.SDL_GetTextureSize(entry.tex, &tw, &th);
            break :blk tw;
        } else entry.pw;
        const dst: c.FRect = .{ .x = o.x / d, .y = o.y / d, .w = first_w / d, .h = entry.ph / d };
        _ = c.SDL_RenderTexture(w.ren, entry.tex, null, &dst);
        // Strips continue by whole texels from the snapped origin: no gap, no overlap.
        var sx = o.x + first_w;
        for (entry.more) |m| {
            var tw: f32 = 0;
            var th: f32 = 0;
            _ = c.SDL_GetTextureSize(m, &tw, &th);
            const part: c.FRect = .{ .x = sx / d, .y = o.y / d, .w = tw / d, .h = entry.ph / d };
            _ = c.SDL_RenderTexture(w.ren, m, null, &part);
            sx += tw;
        }
    }

    /// Where the top-left of a text texture `pw` pixels wide goes, in device pixels, whole numbers.
    /// The texture is never scaled, so on whole pixels its texels map 1:1 onto the screen's and
    /// the glyphs stay as sharp as the rasteriser made them. Carets, selections and underlines
    /// are shapes at fractional positions and are not moved: a shape edge rounds the same way
    /// (to the nearest pixel), so it stays within half a pixel of the glyph it belongs to.
    fn textOrigin(x: f32, y: f32, pw: f32, alignment: gfx.Align, density: f32) struct { x: f32, y: f32 } {
        const px = x * density;
        const left = switch (alignment) {
            .left => px,
            .center => px - pw / 2,
            .right => px - pw,
        };
        return .{ .x = @round(left), .y = @round(y * density) };
    }

    /// Text pixel height for a size in points, or null for sizes that draw nothing (not a
    /// positive finite number, or under half a pixel).
    fn textPx(w: *const Window, size: f32) ?u32 {
        const v = size * w.density;
        if (!(v >= 0.5)) return null;
        return @intFromFloat(@round(@min(v, max_text_px)));
    }

    /// Drops text textures that have not been drawn for a couple of seconds.
    fn evictTexts(w: *Window) void {
        if (w.frame % 120 != 0) return;
        var it = w.texts.iterator();
        while (it.next()) |e| {
            if (w.frame - e.value_ptr.last_frame > 120) {
                w.destroyText(e.value_ptr.*);
                w.texts.removeByPtr(e.key_ptr);
                it = w.texts.iterator(); // removal invalidates the iterator
            }
        }
        var mi = w.text_misses.iterator();
        while (mi.next()) |e| {
            if (w.frame - e.value_ptr.seen > 120) {
                w.text_misses.removeByPtr(e.key_ptr);
                mi = w.text_misses.iterator();
            }
        }
    }
};

/// Characters that draw nothing (joiners, variation selectors, ...): a UI font need not have a
/// glyph for them, so they do not by themselves call for the fallback fonts.
fn isInvisible(cp: u21) bool {
    return switch (cp) {
        0xAD, 0x34F, 0x180B...0x180F, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x206F, 0xFE00...0xFE0F, 0xFEFF, 0xE0100...0xE01EF => true,
        else => false,
    };
}

/// Whether `text` has a character `font` has no glyph for.
fn needsFallback(font: *c.Font, text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < 0x80) {
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + n > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch {
            i += 1;
            continue;
        };
        i += n;
        if (!isInvisible(cp) and !c.TTF_FontHasGlyph(font, cp)) return true;
    }
    return false;
}

const rrect_seg = 10;

/// Outline of a rounded rectangle, clockwise from the top-right corner, with
/// outward unit normals. Returns the point count (4 for a plain rectangle).
fn rrectOutline(r: geom.Rect, radius: f32, pts: *[4 * (rrect_seg + 1)][2]f32, nrm: *[4 * (rrect_seg + 1)][2]f32) usize {
    const seg = rrect_seg;
    const rad = @max(0, @min(radius, @min(r.w, r.h) / 2));
    if (rad < 0.05) {
        // Plain rectangle: one point per corner. (Collapsed corner arcs
        // would add sliver triangles that show up under alpha blending.)
        pts[0..4].* = .{ .{ r.x + r.w, r.y }, .{ r.x + r.w, r.y + r.h }, .{ r.x, r.y + r.h }, .{ r.x, r.y } };
        nrm[0..4].* = .{ .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 }, .{ -1, -1 } };
        return 4;
    }
    const centers = [4][2]f32{
        .{ r.x + r.w - rad, r.y + rad }, // top-right
        .{ r.x + r.w - rad, r.y + r.h - rad }, // bottom-right
        .{ r.x + rad, r.y + r.h - rad }, // bottom-left
        .{ r.x + rad, r.y + rad }, // top-left
    };
    var k: usize = 0;
    for (centers, 0..) |cc, corner| {
        const start = -std.math.pi / 2.0 + @as(f32, @floatFromInt(corner)) * std.math.pi / 2.0;
        for (0..seg + 1) |s| {
            const ang = start + @as(f32, @floatFromInt(s)) / seg * std.math.pi / 2.0;
            nrm[k] = .{ @cos(ang), @sin(ang) };
            pts[k] = .{ cc[0] + nrm[k][0] * rad, cc[1] + nrm[k][1] * rad };
            k += 1;
        }
    }
    return k;
}

fn fail(what: []const u8) error{PlatformInitFailed} {
    std.log.err("{s} failed: {s}", .{ what, c.SDL_GetError() });
    return error.PlatformInitFailed;
}

fn testRaw(ev_type: u32, window: u32, x: f32, y: f32, data: ?[*:0]const u8) [128]u8 {
    var raw: [128]u8 = @splat(0);
    std.mem.writeInt(u32, raw[0..4], ev_type, .little);
    std.mem.writeInt(u32, raw[16..20], window, .little);
    std.mem.writeInt(u32, raw[20..24], @bitCast(x), .little);
    std.mem.writeInt(u32, raw[24..28], @bitCast(y), .little);
    if (data) |d| std.mem.writeInt(usize, raw[40..][0..@sizeOf(usize)], @intFromPtr(d), .little);
    return raw;
}

test "text is chunked on character boundaries, in chunks of at most 32 bytes" {
    // 31 ASCII bytes, then a 2-byte character that straddles the 32nd byte, then more.
    const a31 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const str = a31 ++ "é" ++ "tail";
    try std.testing.expectEqual(@as(usize, 31), textChunkEnd(str, 0));
    try std.testing.expectEqual(str.len, textChunkEnd(str, 31));
    try std.testing.expectEqual(@as(usize, 32), textChunkEnd(a31 ++ "bbbbbbbbb", 0));
    try std.testing.expectEqual(@as(usize, 3), textChunkEnd("abc", 0));
    // Whatever the string, the chunks cover it exactly and each one is valid UTF-8.
    const mixed = "héllo wörld, 日本語のテキスト, \u{1F600} and more text to be split up";
    var i: usize = 0;
    while (i < mixed.len) {
        const end = textChunkEnd(mixed, i);
        try std.testing.expect(end > i and end - i <= 32);
        try std.testing.expect(std.unicode.utf8ValidateSlice(mixed[i..end]));
        i = end;
    }
}

test "a long text event is delivered whole, in valid UTF-8 chunks, in order" {
    var cjk_buf: [336:0]u8 = undefined; // past the 256-byte buffer
    for (0..14) |k| @memcpy(cjk_buf[k * 24 ..][0..24], "日本語のテキスト");
    cjk_buf[336] = 0;
    const cjk: [:0]const u8 = &cjk_buf;
    var raw: [128]u8 = @splat(0);
    std.mem.writeInt(u32, raw[0..4], c.EVENT_TEXT_INPUT, .little);
    std.mem.writeInt(u32, raw[16..20], 5, .little);
    std.mem.writeInt(usize, raw[24..][0..@sizeOf(usize)], @intFromPtr(cjk.ptr), .little);
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(std.testing.allocator);
    var ev = decodeRaw(c.EVENT_TEXT_INPUT, &raw);
    while (ev) |e| : (ev = nextPendingChunk()) {
        try std.testing.expectEqual(@as(u32, 5), e.text_input.window);
        try std.testing.expect(std.unicode.utf8ValidateSlice(e.text_input.text.slice()));
        try got.appendSlice(std.testing.allocator, e.text_input.text.slice());
    }
    try std.testing.expectEqualStrings(cjk, got.items);
    // A short event after it reuses the inline buffer and releases the heap copy.
    std.mem.writeInt(usize, raw[24..][0..@sizeOf(usize)], @intFromPtr(@as([*:0]const u8, "hi")), .little);
    try std.testing.expectEqualStrings("hi", decodeRaw(c.EVENT_TEXT_INPUT, &raw).?.text_input.text.slice());
    try std.testing.expect(pending_heap == null and nextPendingChunk() == null);
}

test "text sizes that are not a positive finite number draw nothing and measure 0" {
    const win = try dummyWindow(.{ .title = "sizes", .width = 80, .height = 60 });
    defer win.destroy();
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    for ([_]f32{ -5, 0, 0.1, nan, inf, -inf }) |size| {
        const m = win.measureText("hello", size);
        if (size == inf) {
            try std.testing.expect(m > 0); // clamped, not a crash
        } else {
            try std.testing.expectEqual(@as(f32, 0), m);
        }
        win.drawText(0, 0, "hello", size, white, .left, .regular);
    }
    // A huge size is clamped to the text size cap: a finite, bounded width.
    const huge_w = win.measureText("hello", 1e30);
    try std.testing.expect(std.math.isFinite(huge_w) and huge_w > win.measureText("hello", 14) and huge_w < 1e6);
    win.drawText(0, 0, "hello", 1e30, white, .left, .regular);
    // A size under half a pixel opens no font, however often it is asked for.
    const fonts = win.fonts.items.len;
    for (0..5) |_| _ = win.measureText("hello", 0.1);
    try std.testing.expectEqual(fonts, win.fonts.items.len);
}

test "text wider than the largest texture is drawn in strips, measured as one line" {
    const win = try dummyWindow(.{ .title = "long text", .width = 80, .height = 60 });
    defer win.destroy();
    const size: f32 = 14;
    const px: u32 = @intFromFloat(@round(size * win.density));
    const i = win.fontIndex(px, .regular).?;
    win.max_tex = 2048; // as if the renderer could not make wider textures
    const max = win.maxTextureSize();
    // Plain text: enough characters to need three strips.
    const per = win.measureText("m", size) * win.density;
    const n: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(max)) * 2.5 / per));
    const long = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(long);
    @memset(long, 'm');
    const want = win.measureText(long, size);
    try std.testing.expect(want * win.density > @as(f32, @floatFromInt(max)));
    if (win.textTexture(i, long, white, px)) |t| {
        defer win.destroyText(t);
        try std.testing.expectEqual(want, t.w);
        try std.testing.expect(t.more.len >= 2);
        var sum: f32 = 0;
        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(t.tex, &tw, &th);
        sum += tw;
        for (t.more) |m| {
            _ = c.SDL_GetTextureSize(m, &tw, &th);
            sum += tw;
        }
        try std.testing.expectEqual(want * win.density, sum);
    } else return error.TestUnexpectedResult;
    // Drawn through the cache it is not retried: one texture set, no miss entry.
    win.drawText(0, 0, long, size, white, .left, .regular);
    win.drawText(0, 0, long, size, white, .left, .regular);
    try std.testing.expectEqual(@as(u32, 1), win.texts.count());
    try std.testing.expectEqual(@as(u32, 0), win.text_misses.count());
    // A string under the limit is one texture, as before.
    const short = win.textTexture(i, "hello", white, px).?;
    defer win.destroyText(short);
    try std.testing.expectEqual(@as(usize, 0), short.more.len);
    // Text past the size cap cannot be drawn: it is remembered, not rasterised every frame.
    const huge = try std.testing.allocator.alloc(u8, max_line_px / 2);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'm');
    win.drawText(0, 0, huge, size, white, .left, .regular);
    win.drawText(0, 0, huge, size, white, .left, .regular);
    try std.testing.expectEqual(@as(u32, 1), win.text_misses.count());
    try std.testing.expectEqual(@as(u32, 1), win.texts.count());
}

/// The window's current render target as bytes (rows of `pitch`). Test helper.
fn readBack(win: *Window) ![]u8 {
    const surf = c.SDL_RenderReadPixels(win.ren, null) orelse return error.TestUnexpectedResult;
    defer c.SDL_DestroySurface(surf);
    const hdr: *const c.SurfaceHeader = @ptrCast(@alignCast(surf));
    const n: usize = @intCast(hdr.pitch * hdr.h);
    return std.testing.allocator.dupe(u8, hdr.pixels.?[0..n]);
}

fn clearTo(win: *Window, v: u8) void {
    _ = c.SDL_SetRenderDrawColor(win.ren, v, v, v, 255);
    _ = c.SDL_RenderClear(win.ren);
}

test "text origin is on whole device pixels at any density and alignment, within half a pixel" {
    for ([_]f32{ 1, 1.5, 2, 3 }) |d| {
        for ([_]gfx.Align{ .left, .center, .right }) |al| {
            for ([_]f32{ 51, 52, 7, 1 }) |pw| {
                var x: f32 = 10.0;
                while (x < 11.0) : (x += 0.125) {
                    const o = Window.textOrigin(x, x * 1.3, pw, al, d);
                    try std.testing.expectEqual(@round(o.x), o.x);
                    try std.testing.expectEqual(@round(o.y), o.y);
                    const ideal: f32 = switch (al) {
                        .left => x * d,
                        .center => x * d - pw / 2,
                        .right => x * d - pw,
                    };
                    try std.testing.expect(@abs(o.x - ideal) <= 0.5);
                    try std.testing.expect(@abs(o.y - x * 1.3 * d) <= 0.5);
                }
            }
        }
    }
}

test "text drawn at a fractional position is pixel-identical to the same text on the snapped pixel" {
    const win = try dummyWindow(.{ .title = "snap", .width = 120, .height = 40 });
    defer win.destroy();
    for ([_]f32{ 1, 2 }) |d| {
        win.density = d;
        _ = c.SDL_SetRenderScale(win.ren, d, d);
        for ([_]gfx.Align{ .left, .center, .right }) |al| {
            for ([_]f32{ 0, 0.25, 0.5, 0.75 }) |fr| {
                const x = 60 + fr;
                const y = 10 + fr;
                clearTo(win, 40);
                win.drawText(x, y, "Hello", 13, white, al, .regular);
                const got = try readBack(win);
                defer std.testing.allocator.free(got);
                // Reference: left aligned at the pixel the origin should round to.
                const pw = win.measureText("Hello", 13) * d;
                const left = switch (al) {
                    .left => x * d,
                    .center => x * d - pw / 2,
                    .right => x * d - pw,
                };
                clearTo(win, 40);
                win.drawText(@round(left) / d, @round(y * d) / d, "Hello", 13, white, .left, .regular);
                const want = try readBack(win);
                defer std.testing.allocator.free(want);
                try std.testing.expectEqualSlices(u8, want, got);
            }
        }
    }
}

test "a line drawn in strips is as wide as the measure and contiguous at a fractional position" {
    const win = try dummyWindow(.{ .title = "strip snap", .width = 120, .height = 40 });
    defer win.destroy();
    const size: f32 = 14;
    const per = win.measureText("m", size);
    const n: usize = @intFromFloat(@ceil(2.5 * 2048 / per));
    const long = try std.testing.allocator.alloc(u8, n);
    defer std.testing.allocator.free(long);
    @memset(long, 'm');
    // Left of the window so that the seams between strips (2048 px apart) are on screen.
    const x: f32 = 50.5 - 2048;
    var shots: [2][]u8 = undefined;
    for (&shots, [_]u32{ 2048, 1 << 20 }) |*shot, max| {
        win.max_tex = max;
        var it = win.texts.iterator();
        while (it.next()) |e| win.destroyText(e.value_ptr.*);
        win.texts.clearRetainingCapacity();
        clearTo(win, 40);
        win.drawText(x, 10.5, long, size, white, .left, .regular);
        shot.* = try readBack(win);
    }
    defer for (shots) |s| std.testing.allocator.free(s);
    const stripped = win.texts.count() == 1;
    try std.testing.expect(stripped);
    try std.testing.expectEqualSlices(u8, shots[1], shots[0]);
    // And the drawn width is the measured width, in whole pixels.
    win.max_tex = 2048;
    const i = win.fontIndex(@intFromFloat(@round(size * win.density)), .regular).?;
    const t = win.textTexture(i, long, white, @intFromFloat(@round(size * win.density))).?;
    defer win.destroyText(t);
    try std.testing.expect(t.more.len >= 2);
    try std.testing.expectEqual(win.measureText(long, size) * win.density, t.pw);
    try std.testing.expectEqual(@round(t.pw), t.pw);
}

test "composed (emoji) text is premultiplied, so a transparent texel carries no colour" {
    const win = try emojiWindow(.{ .title = "premul", .width = 80, .height = 60 });
    defer win.destroy();
    const px: u32 = 20;
    const i = win.fontIndex(px, .regular).?;
    const str = "ab \u{1F600}";
    const t = win.composeText(i, str, white, px) orelse return error.TestUnexpectedResult;
    defer win.destroyText(t);
    var mode: u32 = 0;
    try std.testing.expect(c.SDL_GetTextureBlendMode(t.tex, &mode));
    try std.testing.expectEqual(c.BLENDMODE_BLEND_PREMULTIPLIED, mode);
    // Also for a line wider than a texture.
    win.max_tex = 40;
    const s = win.composeText(i, str, white, px) orelse return error.TestUnexpectedResult;
    defer win.destroyText(s);
    try std.testing.expect(s.more.len > 0);
    try std.testing.expect(c.SDL_GetTextureBlendMode(s.more[0], &mode));
    try std.testing.expectEqual(c.BLENDMODE_BLEND_PREMULTIPLIED, mode);
    // The buffer it is made from keeps straight alpha, with the emoji's own colours and the text
    // alpha as opacity (unchanged).
    const half: Color = .{ .r = 255, .g = 255, .b = 255, .a = 128 };
    const line = win.composeBuffer(i, "ab", half, px) orelse return error.TestUnexpectedResult;
    defer win.gpa.free(line.rgba);
    var seen = false;
    var k: usize = 0;
    while (k < line.rgba.len) : (k += 4) {
        if (line.rgba[k + 3] != 0) {
            seen = true;
            try std.testing.expect(line.rgba[k + 3] <= 128);
            try std.testing.expectEqual(@as(u8, 255), line.rgba[k]);
        }
    }
    try std.testing.expect(seen);
}

test "a line is limited by its area, not only its width" {
    try std.testing.expect(textSurfaceOk(1000, 100));
    try std.testing.expect(textSurfaceOk(max_line_px, 20));
    // Within the width limit, but a gigabyte of pixels at the largest text size.
    try std.testing.expect(!textSurfaceOk(max_line_px, 4800));
    try std.testing.expect(!textSurfaceOk(max_line_px + 1, 1));
}

test "only a failure that cannot pass is remembered for good; others are retried, at a bounded rate" {
    const first = TextMiss.failed(null, 100, false);
    try std.testing.expectEqual(@as(u64, 130), first.retry_at);
    const second = TextMiss.failed(first, 130, false);
    try std.testing.expectEqual(@as(u64, 190), second.retry_at);
    var m = second;
    var at: u64 = 190;
    for (0..20) |_| {
        at = m.retry_at;
        m = TextMiss.failed(m, at, false);
    }
    try std.testing.expectEqual(@as(u64, 480), m.retry_at - at); // the wait stops doubling at 480 frames
    try std.testing.expect(TextMiss.failed(null, 5, true).retry_at == TextMiss.never);
    try std.testing.expect(TextMiss.failed(first, 130, true).retry_at == TextMiss.never);
}

test "a string that is too big is a permanent miss, one that merely failed is retried later" {
    const win = try dummyWindow(.{ .title = "misses", .width = 80, .height = 60 });
    defer win.destroy();
    const size: f32 = 14;
    const huge = try std.testing.allocator.alloc(u8, max_line_px / 2);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'm');
    win.drawText(0, 0, huge, size, white, .left, .regular);
    try std.testing.expectEqual(@as(u32, 1), win.text_misses.count());
    var it = win.text_misses.valueIterator();
    try std.testing.expectEqual(TextMiss.never, it.next().?.retry_at);
    // A transient failure (here: the miss table says so) is tried again once it is due.
    var key_it = win.text_misses.keyIterator();
    const key = key_it.next().?.*;
    win.text_misses.getPtr(key).?.retry_at = win.frame + 1;
    win.frame += 1;
    win.drawText(0, 0, huge, size, white, .left, .regular);
    try std.testing.expectEqual(TextMiss.never, win.text_misses.get(key).?.retry_at); // tried, and now permanent
    try std.testing.expectEqual(@as(u8, 1), win.text_misses.get(key).?.tries);
}

test "a failed icon render is reported once per icon" {
    const win = try dummyWindow(.{ .title = "svg log", .width = 80, .height = 60 });
    defer win.destroy();
    const icon = try win.loadSvg("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\"/></svg>");
    const e = win.svgs.getPtr(icon.id).?;
    // Over the raster's side limit: refused.
    try std.testing.expect(win.makeSvgTexture(icon.id, e, 5000, 1) == null);
    try std.testing.expect(win.makeSvgTexture(icon.id, e, 5000, 2) == null);
    try std.testing.expectEqual(@as(u32, 1), win.svg_failure_logs);
    try std.testing.expect(win.makeSvgTexture(icon.id, e, 16, 16) != null);
}

test "clip rects: push and pop stay balanced past the depth, and odd numbers do not crash" {
    const win = try dummyWindow(.{ .title = "clips", .width = 80, .height = 60 });
    defer win.destroy();
    const depth = win.clips.len;
    for (0..depth + 4) |k| win.pushClip(.{ .x = @floatFromInt(k), .y = 0, .w = 50, .h = 50 });
    try std.testing.expectEqual(depth, win.clip_n);
    try std.testing.expectEqual(@as(usize, 4), win.clip_overflow);
    for (0..4) |_| win.popClip();
    // Back at the depth limit with the 16th clip in force, not the 15th.
    try std.testing.expectEqual(depth, win.clip_n);
    try std.testing.expectEqual(@as(f32, depth - 1), win.clips[depth - 1].x);
    for (0..depth) |_| win.popClip();
    try std.testing.expectEqual(@as(usize, 0), win.clip_n);
    win.popClip(); // popping an empty stack is harmless
    const inf = std.math.inf(f32);
    win.pushClip(.{ .x = std.math.nan(f32), .y = -inf, .w = inf, .h = 1e30 });
    win.pushClip(.{ .x = -1e30, .y = 0, .w = 1e30, .h = inf });
    win.popClip();
    win.popClip();
    try std.testing.expectEqual(@as(usize, 0), win.clip_n);
}

test "an infinite or NaN clip rectangle never widens what is drawn" {
    const inf = std.math.inf(f32);
    const a = Window.clipInts(.{ .x = 100, .y = 0, .w = inf, .h = 50 });
    try std.testing.expectEqual(@as(c_int, 100), a.x);
    try std.testing.expect(a.w > 0 and a.h == 50);
    const b = Window.clipInts(.{ .x = -inf, .y = 0, .w = 10, .h = 10 });
    try std.testing.expect(b.w >= 0 and b.x + b.w <= 11);
    const n = Window.clipInts(.{ .x = std.math.nan(f32), .y = 0, .w = 10, .h = 10 });
    try std.testing.expect(n.w == 0 and n.h == 0);
    const m = Window.clipInts(.{ .x = -inf, .y = 0, .w = inf, .h = 10 }); // inf - inf
    try std.testing.expect(m.w == 0 and m.h == 0);
    const big = Window.clipInts(.{ .x = 5, .y = 5, .w = 1e30, .h = 1e30 });
    try std.testing.expect(big.w > 0 and big.h > 0);
}

test "loadImageFile refuses a file over the size limit without reading it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // builds a sparse file with POSIX calls
    const win = try dummyWindow(.{ .title = "big file", .width = 80, .height = 60 });
    defer win.destroy();
    var buf: [256]u8 = undefined;
    const dir = std.mem.span(std.c.getenv("TMPDIR") orelse "/tmp");
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/vass-big-image-{d}.bin", .{ std.mem.trimEnd(u8, dir, "/"), std.c.getpid() }, 0);
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o600));
    try std.testing.expect(fd >= 0); // the temp directory must be writable
    defer _ = std.c.unlink(path.ptr);
    // A sparse 16 TB file: reading it would need more memory than exists.
    const rc = std.c.ftruncate(fd, 1 << 44);
    _ = std.c.close(fd);
    if (rc != 0) {
        // Only a file system that cannot hold such a file excuses the test.
        switch (std.posix.errno(rc)) {
            .FBIG, .NOSPC, .INVAL, .OPNOTSUPP => return error.SkipZigTest,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectError(error.ImageTooLarge, win.loadImageFile(path));
    try std.testing.expectError(error.FileReadFailed, win.loadImageFile("/tmp/vass-no-such-image.png"));
    try std.testing.expectError(error.FileReadFailed, win.loadImageFile("/tmp")); // a directory
}

test "keypad Enter arrives as Return" {
    var raw: [128]u8 = @splat(0);
    std.mem.writeInt(u32, raw[16..20], 3, .little);
    std.mem.writeInt(u32, raw[28..32], 0x40000058, .little); // SDLK_KP_ENTER
    try std.testing.expectEqual(keys.@"return", decodeRaw(c.EVENT_KEY_DOWN, &raw).?.key_down.code);
    try std.testing.expectEqual(keys.@"return", decodeRaw(c.EVENT_KEY_UP, &raw).?.key_up.code);
}

test "drop events decode, copying the path" {
    const raw = testRaw(c.EVENT_DROP_FILE, 3, 10.5, 20, "/Users/me/pic.png");
    const ev = decodeDropEvent(c.EVENT_DROP_FILE, &raw).?;
    try std.testing.expectEqual(@as(u32, 3), ev.file_drop.window);
    try std.testing.expectEqual(@as(f32, 10.5), ev.file_drop.x);
    try std.testing.expectEqualStrings("/Users/me/pic.png", ev.file_drop.path.slice());
    const pos = decodeDropEvent(c.EVENT_DROP_POSITION, &testRaw(c.EVENT_DROP_POSITION, 3, 1, 2, null)).?;
    try std.testing.expectEqual(@as(f32, 2), pos.drop_position.y);
    try std.testing.expectEqual(@as(u32, 3), decodeDropEvent(c.EVENT_DROP_BEGIN, &testRaw(c.EVENT_DROP_BEGIN, 3, 0, 0, null)).?.drop_begin);
    try std.testing.expectEqual(@as(u32, 3), decodeDropEvent(c.EVENT_DROP_COMPLETE, &testRaw(c.EVENT_DROP_COMPLETE, 3, 0, 0, null)).?.drop_complete);
    // A text drop, a NULL path and other event types are not file drops.
    try std.testing.expect(decodeDropEvent(c.EVENT_DROP_TEXT, &testRaw(c.EVENT_DROP_TEXT, 3, 0, 0, "hello")) == null);
    try std.testing.expect(decodeDropEvent(c.EVENT_DROP_FILE, &testRaw(c.EVENT_DROP_FILE, 3, 0, 0, null)) == null);
    try std.testing.expect(decodeDropEvent(c.EVENT_KEY_DOWN, &testRaw(c.EVENT_KEY_DOWN, 3, 0, 0, null)) == null);
}

test "dialog results: files, cancel and error are distinct and owned by the caller" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try takeRawDialog(gpa)) == null);

    const picked = [_:null]?[*:0]const u8{ "/a/one.png", "/b/two.jpg" };
    deliverDialogForTest(&picked);
    const r = (try takeRawDialog(gpa)).?;
    defer r.files.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), r.files.paths.len);
    try std.testing.expectEqualStrings("/b/two.jpg", r.files.paths[1]);
    try std.testing.expect((try takeRawDialog(gpa)) == null); // taken once

    const none = [_:null]?[*:0]const u8{};
    deliverDialogForTest(&none);
    try std.testing.expect((try takeRawDialog(gpa)).? == .cancelled);

    deliverDialogForTest(null);
    try std.testing.expect((try takeRawDialog(gpa)).? == .failed);
}

test "a long path does not fit a DropPath" {
    const long: [2000]u8 = @splat('a');
    try std.testing.expect(DropPath.from(&long) == null);
    try std.testing.expect(DropPath.from("") == null);
}

test "svgPixelSize: contain-fits into whole device pixels" {
    const sz = Window.svgPixelSize(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, 1, 2).?;
    try std.testing.expectEqual(@as(u32, 32), sz.w);
    try std.testing.expectEqual(@as(u32, 32), sz.h);
    // Wide icon in a square: width limits.
    const wide = Window.svgPixelSize(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, 2, 1).?;
    try std.testing.expectEqual(@as(u32, 20), wide.w);
    try std.testing.expectEqual(@as(u32, 10), wide.h);
    // Tall icon in a wide rectangle: height limits.
    const tall = Window.svgPixelSize(.{ .x = 0, .y = 0, .w = 100, .h = 18 }, 0.5, 2).?;
    try std.testing.expectEqual(@as(u32, 18), tall.w);
    try std.testing.expectEqual(@as(u32, 36), tall.h);
    // Different density, different size: one texture per pixel size.
    const d3 = Window.svgPixelSize(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, 1, 3).?;
    try std.testing.expectEqual(@as(u32, 48), d3.w);
    // Degenerate rectangles and aspects draw nothing; huge ones are capped.
    try std.testing.expect(Window.svgPixelSize(.{ .x = 0, .y = 0, .w = 0, .h = 16 }, 1, 2) == null);
    try std.testing.expect(Window.svgPixelSize(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, 0, 2) == null);
    try std.testing.expect(Window.svgPixelSize(.{ .x = 0, .y = 0, .w = 16, .h = 16 }, std.math.nan(f32), 2) == null);
    const big = Window.svgPixelSize(.{ .x = 0, .y = 0, .w = 5000, .h = 5000 }, 1, 2).?;
    try std.testing.expectEqual(max_svg_side, big.w);
}

const LiveTest = struct {
    win: *Window,
    calls: u32 = 0,
    last_w: f32 = 0,
    last_h: f32 = 0,
    nested_calls: u32 = 0,
    pump_inside: bool = false,

    fn cb(ctx: ?*anyopaque) void {
        const t: *LiveTest = @ptrCast(@alignCast(ctx.?));
        t.calls += 1;
        const sz = t.win.logicalSize();
        t.last_w = sz.w;
        t.last_h = sz.h;
        if (t.pump_inside) {
            // An event arriving while a frame is being drawn must not re-enter the callback.
            const before = t.calls;
            pushWindowEvent(c.EVENT_WINDOW_EXPOSED, t.win.id());
            t.nested_calls += t.calls - before;
        }
    }
};

fn pushWindowEvent(ev_type: u32, window_id: u32) void {
    var e: c.SdlEvent = undefined;
    @memset(&e.raw, 0);
    e.type = ev_type;
    std.mem.writeInt(u32, e.raw[16..20], window_id, .little);
    _ = c.SDL_PushEvent(&e);
}

fn pushFromThread(window_id: u32) void {
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, window_id);
}

test "frame callback: runs for this window's expose/resize events with the new size, guarded" {
    // SDL's dummy video driver: a real SDL window and software renderer, no display needed.
    _ = c.SDL_SetHint("SDL_VIDEO_DRIVER", "dummy");
    var win = Window.init(std.testing.allocator, .{ .title = "t", .width = 200, .height = 100, .resizable = true }) catch return error.SkipZigTest;
    defer win.deinit();
    var t: LiveTest = .{ .win = &win };
    win.setFrameCallback(&t, LiveTest.cb);

    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, win.id());
    try std.testing.expectEqual(@as(u32, 1), t.calls);
    try std.testing.expectEqual(@as(f32, 200), t.last_w);

    // Another window's event is ignored.
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, win.id() + 1000);
    try std.testing.expectEqual(@as(u32, 1), t.calls);

    // Unrelated event types are ignored.
    pushWindowEvent(c.EVENT_KEY_DOWN, win.id());
    try std.testing.expectEqual(@as(u32, 1), t.calls);

    // A real size change reaches the callback with the new logical size.
    _ = c.SDL_SetWindowSize(win.win, 320, 180);
    pushWindowEvent(c.EVENT_WINDOW_RESIZED, win.id());
    try std.testing.expect(t.calls >= 2);
    try std.testing.expectEqual(@as(f32, 320), t.last_w);
    try std.testing.expectEqual(@as(f32, 180), t.last_h);

    // An unchanged size is not redrawn for a resize event (no duplicate frame per step).
    win.drawn_key = win.sizeKey();
    const before = t.calls;
    pushWindowEvent(c.EVENT_WINDOW_RESIZED, win.id());
    try std.testing.expectEqual(before, t.calls);

    // Not re-entrant: an expose pushed from inside the callback is dropped.
    t.pump_inside = true;
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, win.id());
    try std.testing.expectEqual(before + 1, t.calls);
    try std.testing.expectEqual(@as(u32, 0), t.nested_calls);
    t.pump_inside = false;

    // Not while render() is running.
    win.in_render = true;
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, win.id());
    win.in_render = false;
    try std.testing.expectEqual(before + 1, t.calls);

    // Events from another thread never draw.
    const th = try std.Thread.spawn(.{}, pushFromThread, .{win.id()});
    th.join();
    try std.testing.expectEqual(before + 1, t.calls);

    // Cleared: no more calls.
    win.setFrameCallback(null, null);
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, win.id());
    try std.testing.expectEqual(before + 1, t.calls);
}

fn wakeFromThread() void {
    sleepMs(30);
    wakeEventLoop();
}

test "waitEvent: times out when idle, ends on an event or a wake-up, keeps the event for pollEvent" {
    useDummyVideo();
    var win = Window.init(std.testing.allocator, .{ .title = "t", .width = 100, .height = 80 }) catch return error.SkipZigTest;
    defer win.deinit();
    while (pollEvent()) |_| {}
    try std.testing.expect(!waitEvent(5));

    // A decoded event ends the wait and is still there for pollEvent, once.
    pushWindowEvent(c.EVENT_WINDOW_FOCUS_GAINED, win.id());
    try std.testing.expect(waitEvent(1000));
    try std.testing.expect(waitEvent(0)); // already holding one
    try std.testing.expectEqual(win.id(), pollEvent().?.focus_gained);
    try std.testing.expect(pollEvent() == null);

    // A wake-up ends the wait but is no `Event`; one from another thread works too.
    wakeEventLoop();
    try std.testing.expect(waitEvent(1000));
    try std.testing.expect(pollEvent() == null);
    const th = try std.Thread.spawn(.{}, wakeFromThread, .{});
    try std.testing.expect(waitEvent(5000));
    th.join();
    while (pollEvent()) |_| {}
}

// ---- several windows --------------------------------------------------------------------------

fn dummyWindow(opts: WindowOptions) error{SkipZigTest}!*Window {
    // SDL's dummy video driver: real SDL windows and software renderers, no display needed.
    _ = c.SDL_SetHint("SDL_VIDEO_DRIVER", "dummy");
    return Window.create(std.testing.allocator, opts) catch error.SkipZigTest;
}

fn pushRaw(raw: [128]u8) void {
    var e: c.SdlEvent = undefined;
    e.raw = raw;
    _ = c.SDL_PushEvent(&e);
}

test "every event that belongs to a window carries that window's id" {
    const wid: u32 = 7;
    var raw: [128]u8 = @splat(0);
    std.mem.writeInt(u32, raw[16..20], wid, .little);
    std.mem.writeInt(u32, raw[28..32], 'q', .little); // key code
    // Mouse: button at 24, position at 28 and 32.
    std.mem.writeInt(u32, raw[28..32], @bitCast(@as(f32, 3.5)), .little);
    std.mem.writeInt(u32, raw[32..36], @bitCast(@as(f32, 4.5)), .little);
    raw[24] = 1;
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_MOUSE_MOTION, &raw).?.mouse_move.window);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_MOUSE_BUTTON_DOWN, &raw).?.mouse_down.window);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_MOUSE_BUTTON_UP, &raw).?.mouse_up.window);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_MOUSE_WHEEL, &raw).?.mouse_wheel.window);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_KEY_DOWN, &raw).?.key_down.window);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_KEY_UP, &raw).?.key_up.window);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_WINDOW_MOUSE_LEAVE, &raw).?.mouse_leave);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_WINDOW_FOCUS_GAINED, &raw).?.focus_gained);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_WINDOW_FOCUS_LOST, &raw).?.focus_lost);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_WINDOW_CLOSE_REQUESTED, &raw).?.close_requested);
    try std.testing.expect(decodeRaw(c.EVENT_QUIT, &raw).? == .quit);
    // Text input and composition: the string pointer sits at 24.
    var traw = testRaw(c.EVENT_TEXT_INPUT, wid, 0, 0, null);
    const hello: [*:0]const u8 = "hello";
    std.mem.writeInt(usize, traw[24..][0..@sizeOf(usize)], @intFromPtr(hello), .little);
    const ti = decodeRaw(c.EVENT_TEXT_INPUT, &traw).?.text_input;
    try std.testing.expectEqual(wid, ti.window);
    try std.testing.expectEqualStrings("hello", ti.text.slice());
    const te = decodeRaw(c.EVENT_TEXT_EDITING, &traw).?.text_editing;
    try std.testing.expectEqual(wid, te.window);
    try std.testing.expectEqualStrings("hello", te.comp.slice());
    // Drops (decoded in decodeDropEvent) and events the toolkit ignores.
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_DROP_BEGIN, &raw).?.drop_begin);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_DROP_COMPLETE, &raw).?.drop_complete);
    try std.testing.expectEqual(wid, decodeRaw(c.EVENT_DROP_POSITION, &raw).?.drop_position.window);
    try std.testing.expect(decodeRaw(c.EVENT_WINDOW_EXPOSED, &raw) == null);
}

test "pollEvent: close requests and focus changes arrive per window, apart from quit" {
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60 });
    defer a.destroy();
    const b = try dummyWindow(.{ .title = "b", .width = 80, .height = 60 });
    defer b.destroy();
    while (pollEvent()) |_| {} // whatever SDL queued while opening them
    pushRaw(testRaw(c.EVENT_WINDOW_CLOSE_REQUESTED, b.id(), 0, 0, null));
    pushRaw(testRaw(c.EVENT_WINDOW_FOCUS_LOST, a.id(), 0, 0, null));
    pushRaw(testRaw(c.EVENT_WINDOW_FOCUS_GAINED, b.id(), 0, 0, null));
    var got: [3]Event = undefined;
    var n: usize = 0;
    while (pollEvent()) |ev| {
        if (n < got.len) got[n] = ev;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(b.id(), got[0].close_requested);
    try std.testing.expectEqual(a.id(), got[1].focus_lost);
    try std.testing.expectEqual(b.id(), got[2].focus_gained);
}

test "windows come and go in any order; SDL starts once and stops with the last window" {
    const before = live_windows;
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60 });
    const b = try dummyWindow(.{ .title = "b", .width = 80, .height = 60 });
    const d = try dummyWindow(.{ .title = "c", .width = 80, .height = 60 });
    try std.testing.expectEqual(before + 3, live_windows);
    try std.testing.expect(a.id() != b.id() and b.id() != d.id());
    // Closing one does not touch the others: they still draw and measure.
    b.destroy();
    var list = gfx.DisplayList.init(std.testing.allocator);
    defer list.deinit();
    list.rect(.{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    list.text(2, 2, 12, .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .left, "still here");
    a.render(&list, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    d.render(&list, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    _ = d.measureText("x", 12);
    a.destroy();
    try std.testing.expectEqual(before + 1, live_windows);
    d.destroy();
    try std.testing.expectEqual(before, live_windows);
    try std.testing.expectEqual(@as(usize, 0), live_windows);
    // Everything process-wide went with the last window (cursors), and a new window starts it again.
    for (cursor_cache) |slot| try std.testing.expect(slot == null);
    try std.testing.expect(cursor_applied == null);
    const e = try dummyWindow(.{ .title = "again", .width = 80, .height = 60 });
    _ = systemCursor(.text); // create, then...
    e.destroy(); // ...destroy with the window
    for (cursor_cache) |slot| try std.testing.expect(slot == null);
    const f = try dummyWindow(.{ .title = "and again", .width = 80, .height = 60 });
    defer f.destroy();
    f.render(&list, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
}

test "images and icons belong to the window that loaded them" {
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60 });
    defer a.destroy();
    const b = try dummyWindow(.{ .title = "b", .width = 80, .height = 60 });
    defer b.destroy();
    const px = [16]u8{ 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255 };
    const img = try a.loadImagePixels(&px, 2, 2);
    const img_b = try b.loadImagePixels(&px, 2, 2);
    try std.testing.expect(img.id != img_b.id); // ids are never shared, so a handle can only miss
    try std.testing.expect(a.hasImage(img) and !b.hasImage(img));
    try std.testing.expect(b.imageSize(img) == null);
    const icon = try a.loadSvg("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\"/></svg>");
    try std.testing.expect(a.hasSvg(icon) and !b.hasSvg(icon));
    // Drawing a foreign handle draws nothing and creates no texture.
    var list = gfx.DisplayList.init(std.testing.allocator);
    defer list.deinit();
    list.image(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, img, .{});
    list.svgIcon(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, icon, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    b.render(&list, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try std.testing.expectEqual(@as(usize, 0), b.svgTextureCount());
    a.render(&list, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try std.testing.expect(a.svgTextureCount() > 0);
    // Unloading it on the wrong window changes nothing.
    b.unloadImage(img);
    try std.testing.expect(a.hasImage(img));
}

const Probe = struct {
    win: *Window,
    calls: u32 = 0,
    /// Destroyed from inside this probe's callback (another window's frame).
    kill: ?*Window = null,

    fn cb(ctx: ?*anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx.?));
        p.calls += 1;
        if (p.kill) |victim| {
            p.kill = null;
            victim.destroy();
        }
    }
};

test "frame callbacks of several windows: each fires for its own events, and a window can be destroyed from another's" {
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60, .resizable = true });
    const b = try dummyWindow(.{ .title = "b", .width = 80, .height = 60, .resizable = true });
    const d = try dummyWindow(.{ .title = "c", .width = 80, .height = 60, .resizable = true });
    var pa: Probe = .{ .win = a };
    var pb: Probe = .{ .win = b };
    var pd: Probe = .{ .win = d };
    a.setFrameCallback(&pa, Probe.cb);
    b.setFrameCallback(&pb, Probe.cb);
    d.setFrameCallback(&pd, Probe.cb);
    const b_id = b.id();

    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, a.id());
    try std.testing.expectEqual([3]u32{ 1, 0, 0 }, [3]u32{ pa.calls, pb.calls, pd.calls });
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, b_id);
    try std.testing.expectEqual([3]u32{ 1, 1, 0 }, [3]u32{ pa.calls, pb.calls, pd.calls });

    // a's frame destroys b (callback registered, window heap-allocated): safe, and its id is dead.
    pa.kill = b;
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, a.id());
    try std.testing.expectEqual(@as(u32, 2), pa.calls);
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, b_id);
    try std.testing.expectEqual(@as(u32, 2), pa.calls);
    try std.testing.expectEqual(@as(u32, 0), pd.calls);
    // The survivors still get their own events.
    pushWindowEvent(c.EVENT_WINDOW_EXPOSED, d.id());
    try std.testing.expectEqual(@as(u32, 1), pd.calls);
    // Destroying the others from the loop (between frames) is fine too.
    d.destroy();
    a.destroy();
}

test "text input is per window" {
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60 });
    defer a.destroy();
    const b = try dummyWindow(.{ .title = "b", .width = 80, .height = 60 });
    defer b.destroy();
    a.stopTextInput();
    b.stopTextInput();
    a.startTextInput();
    try std.testing.expect(a.textInputActive());
    try std.testing.expect(!b.textInputActive());
    b.startTextInput();
    a.stopTextInput();
    try std.testing.expect(!a.textInputActive() and b.textInputActive());
}

test "a window can be titled and placed; windows cascade" {
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60, .position = .{ 120, 90 }, .hidden = true });
    defer a.destroy();
    a.setTitle("Renamed \u{e9}");
    a.setTitle("");
    const long: [400]u8 = @splat('x');
    a.setTitle(&long); // longer than the copy buffer: cut, not overflowed
    try std.testing.expectEqual(@as([2]f32, .{ 120, 90 }), a.position());
    a.setPosition(200, 150);
    try std.testing.expectEqual(@as([2]f32, .{ 200, 150 }), a.position());
    try std.testing.expect(!a.hasFocus() and !a.hasMouseFocus()); // hidden, nobody is pointing at it

    const area: geom.Rect = .{ .x = 0, .y = 25, .w = 1000, .h = 700 };
    const p0 = cascadeIn(area, 0, 400, 300);
    const p1 = cascadeIn(area, 1, 400, 300);
    try std.testing.expectEqual(@as(f32, 40), p0[0]);
    try std.testing.expectEqual(@as(f32, 65), p0[1]);
    try std.testing.expectEqual(p0[0] + cascade_step, p1[0]);
    try std.testing.expectEqual(p0[1] + cascade_step, p1[1]);
    // Room for 12 steps (360 / 28), then it wraps instead of walking off the area.
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const p = cascadeIn(area, i, 400, 300);
        try std.testing.expect(p[0] + 400 <= area.x + area.w and p[1] + 300 <= area.y + area.h);
    }
    try std.testing.expectEqual(p0, cascadeIn(area, 13, 400, 300));
    // A window as big as the area still gets a spot.
    try std.testing.expectEqual(@as([2]f32, .{ 0, 25 }), cascadeIn(area, 5, 1000, 700));
}

test "the cursor is only set by the window under the pointer" {
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60 });
    defer a.destroy();
    const b = try dummyWindow(.{ .title = "b", .width = 80, .height = 60 });
    defer b.destroy();
    try std.testing.expect(cursorOwner(a.win, a.win));
    try std.testing.expect(!cursorOwner(a.win, b.win)); // pointer over a: b (drawn last, wants the arrow) must not reset it
    try std.testing.expect(cursorOwner(null, b.win)); // over none of ours: harmless
}

test "drag regions are kept per window" {
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60 });
    defer a.destroy();
    const b = try dummyWindow(.{ .title = "b", .width = 80, .height = 60 });
    defer b.destroy();
    a.setDragRegion(.{ .x = 0, .y = 0, .w = 80, .h = 20 }, &.{.{ .x = 60, .y = 0, .w = 20, .h = 20 }});
    b.setDragRegion(.{ .x = 0, .y = 40, .w = 80, .h = 20 }, &.{});
    const pa: c.SdlPoint = .{ .x = 10, .y = 10 };
    const pb: c.SdlPoint = .{ .x = 10, .y = 50 };
    const pex: c.SdlPoint = .{ .x = 70, .y = 10 };
    try std.testing.expectEqual(@as(c_int, 1), hitTest(a.win, &pa, null));
    try std.testing.expectEqual(@as(c_int, 0), hitTest(a.win, &pb, null)); // b's strip is not a's
    try std.testing.expectEqual(@as(c_int, 0), hitTest(a.win, &pex, null)); // excluded (a button)
    try std.testing.expectEqual(@as(c_int, 1), hitTest(b.win, &pb, null));
    try std.testing.expectEqual(@as(c_int, 0), hitTest(b.win, &pa, null));
    a.setDragRegion(null, &.{});
    try std.testing.expectEqual(@as(c_int, 0), hitTest(a.win, &pa, null));
    try std.testing.expectEqual(@as(c_int, 1), hitTest(b.win, &pb, null)); // still there
}

test "an open-file dialog result belongs to the window that opened it" {
    const gpa = std.testing.allocator;
    const a = try dummyWindow(.{ .title = "a", .width = 80, .height = 60 });
    defer a.destroy();
    const b = try dummyWindow(.{ .title = "b", .width = 80, .height = 60 });
    defer b.destroy();
    const picked = [_:null]?[*:0]const u8{"/x/one.png"};

    // a's result is invisible to b, and a gets it once.
    dialog_owner = a.id();
    deliverDialogForTest(&picked);
    try std.testing.expect((try b.takeDialogResult(gpa)) == null);
    const r = (try a.takeDialogResult(gpa)).?;
    r.files.deinit(gpa);
    try std.testing.expect((try a.takeDialogResult(gpa)) == null);

    // A window closed with its result waiting does not block the next dialog.
    const tmp = try dummyWindow(.{ .title = "tmp", .width = 80, .height = 60 });
    dialog_owner = tmp.id();
    deliverDialogForTest(&picked);
    tmp.destroy();
    try std.testing.expect(dialog_done == null and !dialog_pending);

    // A window closed while the dialog is still open: the late result is dropped.
    const tmp2 = try dummyWindow(.{ .title = "tmp2", .width = 80, .height = 60 });
    dialog_owner = tmp2.id();
    lockDialog();
    dialog_pending = true;
    unlockDialog();
    tmp2.destroy();
    try std.testing.expect(dialog_orphaned);
    dialogCallback(null, &picked, 0);
    try std.testing.expect(dialog_done == null and !dialog_pending and !dialog_orphaned);
}

// ---- colour emoji and font fallback -----------------------------------------------------------

const family_emoji = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}";
const flag_ng = "\u{1F1F3}\u{1F1EC}";
const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

/// A dummy-driver window whose emoji font works, or a skip: the system font may be absent (not
/// macOS, a stripped install) or unreadable.
fn emojiWindow(opts: WindowOptions) error{SkipZigTest}!*Window {
    const w = try dummyWindow(opts);
    if (!w.emojiReady()) {
        w.destroy();
        return error.SkipZigTest;
    }
    return w;
}

fn expectNear(want: f32, got: f32, tol: f32) !void {
    try std.testing.expect(@abs(want - got) <= tol);
}

/// Bounding box of the pixels of `line` that are coloured (not grey, as the UI text is white or
/// red here: a pixel with red, green and blue far apart).
fn colourBox(line: Window.Composed) ?struct { x0: usize, x1: usize, n: usize } {
    var x0: usize = line.w;
    var x1: usize = 0;
    var n: usize = 0;
    for (0..line.h) |y| for (0..line.w) |x| {
        const p = line.rgba[(y * line.w + x) * 4 ..][0..4];
        if (p[3] < 128) continue;
        const hi = @max(p[0], @max(p[1], p[2]));
        const lo = @min(p[0], @min(p[1], p[2]));
        if (hi - lo < 40) continue;
        n += 1;
        x0 = @min(x0, x);
        x1 = @max(x1, x);
    };
    if (n == 0) return null;
    return .{ .x0 = x0, .x1 = x1, .n = n };
}

test "emoji: measured width equals the drawn texture, and a family is one glyph wide" {
    const win = try emojiWindow(.{ .title = "emoji", .width = 80, .height = 60 });
    defer win.destroy();
    const size: f32 = 20;
    const px: u32 = 20;
    const one = win.measureText("\u{1F600}", size);
    const fam = win.measureText(family_emoji, size);
    const flag = win.measureText(flag_ng, size);
    try std.testing.expect(one > 0);
    try expectNear(one, fam, one * 0.25); // not three or four glyphs
    try expectNear(one, flag, one * 0.25);
    try std.testing.expect(win.measureText("\u{1F469}\u{1F469}\u{1F467}", size) > 2 * fam); // without the joiners
    try std.testing.expect(win.measureText("1\u{FE0F}\u{20E3}", size) < 1.5 * one);
    // Each string: the texture drawText makes is exactly as wide as measureText says.
    const i = win.fontIndex(px, .regular).?;
    const strs = [_][]const u8{ "\u{1F600}", family_emoji, flag_ng, "caf\u{E9} " ++ family_emoji ++ " ok", "\u{1F44D}\u{1F3FD}", "\u{2764}\u{FE0F}", "1\u{FE0F}\u{20E3}" };
    for (strs) |str| {
        const t = win.textTexture(i, str, white, px) orelse return error.TestUnexpectedResult;
        defer c.SDL_DestroyTexture(t.tex);
        try std.testing.expectEqual(win.measureText(str, size), t.w);
        try std.testing.expect(t.w > 0 and t.h > 0);
    }
}

test "emoji: strings without emoji are measured and drawn as before" {
    const win = try emojiWindow(.{ .title = "plain", .width = 80, .height = 60 });
    defer win.destroy();
    const off = try dummyWindow(.{ .title = "plain off", .width = 80, .height = 60, .colour_emoji = false });
    defer off.destroy();
    for ([_][]const u8{ "hello", "caf\u{E9}", "x \u{2764} y", "\u{A9} 2026", "tab\there" }) |str| {
        try std.testing.expectEqual(off.measureText(str, 15), win.measureText(str, 15));
    }
}

test "emoji: the glyph keeps its own colours whatever the text colour is, only opacity applies" {
    const win = try emojiWindow(.{ .title = "colour", .width = 80, .height = 60 });
    defer win.destroy();
    const px: u32 = 24;
    const i = win.fontIndex(px, .regular).?;
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const blue: Color = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    const half: Color = .{ .r = 255, .g = 0, .b = 0, .a = 128 };
    for ([_][]const u8{ "\u{1F600}", family_emoji, flag_ng }) |str| {
        const a = win.composeBuffer(i, str, red, px) orelse return error.TestUnexpectedResult;
        defer win.gpa.free(a.rgba);
        const b = win.composeBuffer(i, str, blue, px) orelse return error.TestUnexpectedResult;
        defer win.gpa.free(b.rgba);
        const h = win.composeBuffer(i, str, half, px) orelse return error.TestUnexpectedResult;
        defer win.gpa.free(h.rgba);
        // Coloured (not grey) pixels exist, and the text colour changes nothing.
        const box = colourBox(a) orelse return error.TestUnexpectedResult;
        try std.testing.expect(box.n > 50);
        try std.testing.expectEqualSlices(u8, a.rgba, b.rgba);
        // Half opacity: same colours, about half the alpha.
        try std.testing.expectEqual(a.rgba.len, h.rgba.len);
        var checked: usize = 0;
        var k: usize = 0;
        while (k < a.rgba.len) : (k += 4) {
            if (a.rgba[k + 3] != 255) continue;
            try std.testing.expectEqualSlices(u8, a.rgba[k..][0..3], h.rgba[k..][0..3]);
            try std.testing.expect(h.rgba[k + 3] >= 127 and h.rgba[k + 3] <= 129);
            checked += 1;
        }
        try std.testing.expect(checked > 50);
    }
    // Text next to it is tinted as usual.
    const mixed = win.composeBuffer(i, "ab \u{1F600}", red, px) orelse return error.TestUnexpectedResult;
    defer win.gpa.free(mixed.rgba);
    var red_text: usize = 0;
    var k: usize = 0;
    while (k < mixed.rgba.len) : (k += 4) {
        const p = mixed.rgba[k..][0..4];
        if (p[3] > 200 and p[0] == 255 and p[1] == 0 and p[2] == 0) red_text += 1;
    }
    try std.testing.expect(red_text > 20);
}

test "emoji: the caret positions around a cluster match where it is drawn" {
    const win = try emojiWindow(.{ .title = "caret", .width = 80, .height = 60 });
    defer win.destroy();
    const px: u32 = 26;
    const i = win.fontIndex(px, .regular).?;
    const size: f32 = 26;
    inline for ([_][]const u8{ family_emoji, flag_ng, "\u{1F44D}\u{1F3FD}", "\u{1F600}" }) |cluster| {
        const str = "ab" ++ cluster;
        // Prefix before the cluster and through it, as a text field measures them for the caret.
        const x0 = win.measureText("ab", size);
        const x1 = win.measureText(str, size);
        try std.testing.expect(x1 > x0);
        const line = win.composeBuffer(i, str, white, px) orelse return error.TestUnexpectedResult;
        defer win.gpa.free(line.rgba);
        try std.testing.expectEqual(@as(usize, @intFromFloat(x1)), line.w);
        const box = colourBox(line) orelse return error.TestUnexpectedResult;
        // The coloured pixels lie between the two caret positions and fill most of the gap.
        try std.testing.expect(@as(f32, @floatFromInt(box.x0)) >= x0 - 1);
        try std.testing.expect(@as(f32, @floatFromInt(box.x1)) <= x1);
        try std.testing.expect(@as(f32, @floatFromInt(box.x1 - box.x0)) >= 0.5 * (x1 - x0));
    }
    // The widths add up piece by piece, so every cluster boundary is a caret stop.
    const a = win.measureText("a", size);
    const e = win.measureText(family_emoji, size);
    try expectNear(a + e, win.measureText("a" ++ family_emoji, size), 0.01);
    try expectNear(a + e + a, win.measureText("a" ++ family_emoji ++ "a", size), 0.01);
}

test "emoji: it sits on the baseline at the text size, at any pixel size" {
    const win = try emojiWindow(.{ .title = "size", .width = 80, .height = 60 });
    defer win.destroy();
    for ([_]u32{ 13, 20, 26, 30, 44, 70, 200 }) |px| {
        const i = win.fontIndex(px, .regular).?;
        const line = win.composeBuffer(i, "\u{1F600}", white, px) orelse return error.TestUnexpectedResult;
        defer win.gpa.free(line.rgba);
        // About an em and a bit wide (the font advances 1.15 em), and inside the line box (not cut
        // off at the top by a wrong baseline).
        try std.testing.expect(line.w >= px and line.w <= px * 13 / 10 + 1);
        var first: usize = line.h;
        var last: usize = 0;
        for (0..line.h) |y| for (0..line.w) |x| {
            if (line.rgba[(y * line.w + x) * 4 + 3] > 128) {
                first = @min(first, y);
                last = @max(last, y);
            }
        };
        try std.testing.expect(last >= first);
        const asc: usize = @intCast(c.TTF_GetFontAscent(win.fonts.items[i].font));
        try std.testing.expect(last <= asc + px / 5); // at most a little below the baseline
        try std.testing.expect(first <= asc);
        try std.testing.expect(last - first + 1 >= px * 6 / 10); // fills most of an em in height
    }
}

test "emoji: a missing or broken emoji font leaves boxes and breaks nothing" {
    const plain = try dummyWindow(.{ .title = "off", .width = 80, .height = 60, .colour_emoji = false });
    defer plain.destroy();
    const str = "caf\u{E9} " ++ family_emoji ++ " " ++ flag_ng;
    const want = plain.measureText(str, 15);
    try std.testing.expect(want > 0);
    const bad = [_]WindowOptions{
        .{ .title = "missing", .width = 80, .height = 60, .emoji_font = .{ .path = "/nonexistent/NoSuchEmoji.ttc" } },
        .{ .title = "garbage", .width = 80, .height = 60, .emoji_font = .{ .bytes = "this is not a font" } },
    };
    for (bad) |opts| {
        const win = try dummyWindow(opts);
        defer win.destroy();
        try std.testing.expect(!win.emojiReady());
        try std.testing.expectEqual(want, win.measureText(str, 15));
        var list = gfx.DisplayList.init(std.testing.allocator);
        defer list.deinit();
        list.text(2, 2, 15, white, .left, str);
        win.render(&list, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        try std.testing.expectEqual(want, win.measureText(str, 15));
    }
}

test "emoji: a whole display list with emoji everywhere renders" {
    const win = try emojiWindow(.{ .title = "render", .width = 200, .height = 100 });
    defer win.destroy();
    var list = gfx.DisplayList.init(std.testing.allocator);
    defer list.deinit();
    list.text(2, 2, 13, white, .left, "Shipped \u{1F680} " ++ family_emoji);
    list.text(100, 22, 13, white, .center, flag_ng ++ " a");
    list.text(198, 42, 13, .{ .r = 255, .g = 255, .b = 255, .a = 90 }, .right, "\u{2764}\u{FE0F} dim");
    list.text(2, 62, 16, white, .left, "\u{1F44D}\u{1F3FD} semibold");
    win.render(&list, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
    win.render(&list, .{ .r = 0, .g = 0, .b = 0, .a = 255 }); // cached textures
    try std.testing.expect(win.texts.count() >= 4);
}

test "fallback fonts: CJK has glyphs through the system fallbacks, and only when asked for" {
    const on = try dummyWindow(.{ .title = "fb on", .width = 80, .height = 60 });
    defer on.destroy();
    // Hiragino Sans GB is the second system fallback; no font, no test.
    if (builtin.os.tag != .macos or on.fallbackFont(1, 20) == null) return error.SkipZigTest;
    const off = try dummyWindow(.{ .title = "fb off", .width = 80, .height = 60, .system_fallback_fonts = false });
    defer off.destroy();
    const cjk = "\u{4F60}\u{597D}";
    const with = on.measureText(cjk, 20);
    const without = off.measureText(cjk, 20);
    try std.testing.expect(with > 0 and without > 0);
    try std.testing.expect(with != without); // real glyphs, not the UI font's boxes
    // The fallback fonts are opened only for strings that need them: Latin text opened none.
    const latin = try dummyWindow(.{ .title = "latin", .width = 80, .height = 60 });
    defer latin.destroy();
    _ = latin.measureText("caf\u{E9} hello", 20);
    try std.testing.expectEqual(@as(usize, 0), latin.fb_fonts.items.len);
    _ = latin.measureText(cjk, 20);
    try std.testing.expect(latin.fb_fonts.items.len > 0);
    // An app's own fallback list works on its own, in place of the system's.
    const own = try dummyWindow(.{ .title = "own", .width = 80, .height = 60, .system_fallback_fonts = false, .fallback_fonts = &.{.{ .path = "/System/Library/Fonts/Hiragino Sans GB.ttc" }} });
    defer own.destroy();
    try std.testing.expectEqual(with, own.measureText(cjk, 20));
}
