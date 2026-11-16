//! macOS extras, done through the Objective-C runtime so no Swift/ObjC source
//! is needed: accessory (no Dock icon) apps, overlay windows, the notch, and
//! a menu-bar status item. Everything here must run on the main thread.
const std = @import("std");
const builtin = @import("builtin");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Point = extern struct { x: f64, y: f64 };
const Size = extern struct { w: f64, h: f64 };
const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const EdgeInsets = extern struct { top: f64, left: f64, bottom: f64, right: f64 };

extern fn objc_getClass(name: [*:0]const u8) Id;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_msgSend() void;
extern fn objc_msgSend_stret() void; // x86_64 only; never referenced elsewhere
extern fn objc_autoreleasePoolPush() ?*anyopaque;
extern fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern fn objc_allocateClassPair(super: Id, name: [*:0]const u8, extra: usize) Id;
extern fn objc_registerClassPair(cls: Id) void;
extern fn class_addMethod(cls: Id, sel: Sel, imp: *const anyopaque, types: [*:0]const u8) bool;

/// Whether a method returning `R` must be called through `objc_msgSend_stret`. Only x86_64 has
/// that entry point: its System V ABI returns structs over 16 bytes in memory (through a hidden
/// pointer in the first argument register, which is what `_stret` expects), while smaller
/// structs of doubles come back in registers like any scalar. arm64 returns everything in
/// registers, or through x8 as an ordinary indirect result, and has no `_stret` at all.
fn needsStret(comptime R: type, comptime arch: std.Target.Cpu.Arch) bool {
    return arch == .x86_64 and @sizeOf(R) > 16;
}

/// Runs `objc_autoreleasePoolPop` when it goes out of scope: for helpers that create autoreleased
/// objects and may be called outside any pool (every call from the app's own code).
const Pool = struct {
    p: ?*anyopaque,
    fn begin() Pool {
        return .{ .p = objc_autoreleasePoolPush() };
    }
    fn end(pool: Pool) void {
        objc_autoreleasePoolPop(pool.p);
    }
};

/// Typed objc_msgSend. Argument types must match the method exactly.
fn send(comptime R: type, target: Id, selector: [*:0]const u8, args: anytype) R {
    const A = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const F = switch (A.len) {
        0 => *const fn (Id, Sel) callconv(.c) R,
        1 => *const fn (Id, Sel, A[0]) callconv(.c) R,
        2 => *const fn (Id, Sel, A[0], A[1]) callconv(.c) R,
        3 => *const fn (Id, Sel, A[0], A[1], A[2]) callconv(.c) R,
        else => @compileError("too many arguments"),
    };
    const func: F = if (comptime needsStret(R, builtin.cpu.arch)) @ptrCast(&objc_msgSend_stret) else @ptrCast(&objc_msgSend);
    return @call(.auto, func, .{ target, sel_registerName(selector) } ++ args);
}

fn nsString(text: [*:0]const u8) Id {
    return send(Id, objc_getClass("NSString"), "stringWithUTF8String:", .{text});
}

fn app() Id {
    return send(Id, objc_getClass("NSApplication"), "sharedApplication", .{});
}

/// Sets the app's Dock icon (`NSApplication.applicationIconImage`) from encoded image
/// bytes (PNG, ...). For apps run unbundled, e.g. `zig build run`, which have no
/// Info.plist icon. The system draws the image as is: give it the rounded-square
/// artwork with its padding. Call after the window exists, from the main thread.
/// Returns false if macOS could not decode the data.
pub fn setDockIcon(png_bytes: []const u8) bool {
    const pool = Pool.begin();
    defer pool.end();
    const NSData = objc_getClass("NSData");
    const data = send(Id, NSData, "dataWithBytes:length:", .{ @as(*const anyopaque, png_bytes.ptr), png_bytes.len });
    if (data == null) return false;
    const alloc = send(Id, objc_getClass("NSImage"), "alloc", .{});
    const image = send(Id, alloc, "initWithData:", .{data});
    if (image == null) return false;
    send(void, app(), "setApplicationIconImage:", .{image});
    send(void, image, "release", .{}); // the application retains it
    return true;
}

/// `AVCaptureDevice` authorisation status for the microphone, without prompting: 0 not
/// determined, 1 restricted, 2 denied, 3 authorised; null if AVFoundation is not loaded.
pub fn microphoneStatus() ?c_long {
    const cls = objc_getClass("AVCaptureDevice") orelse return null;
    const pool = Pool.begin();
    defer pool.end();
    return send(c_long, cls, "authorizationStatusForMediaType:", .{nsString("soun")});
}

/// Run as a menu-bar style app: no Dock icon, no app menu.
pub fn setAccessory() void {
    const pool = Pool.begin();
    defer pool.end();
    _ = send(bool, app(), "setActivationPolicy:", .{@as(c_long, 1)});
}

/// Bring the app's windows in front of other apps.
pub fn activate() void {
    const pool = Pool.begin();
    defer pool.end();
    send(void, app(), "activateIgnoringOtherApps:", .{true});
}

pub const Level = enum(c_long) {
    /// Above normal windows and the Dock.
    floating = 25,
    /// Above the menu bar too.
    above_menu_bar = 27,
};

/// Turns a window into a desktop overlay: fixed stacking level, visible on
/// every Space and over full-screen apps, no shadow.
pub fn makeOverlay(ns_window: ?*anyopaque, level: Level, click_through: bool) void {
    const w = ns_window orelse return;
    const pool = Pool.begin();
    defer pool.end();
    send(void, w, "setLevel:", .{@intFromEnum(level)});
    send(void, w, "setIgnoresMouseEvents:", .{click_through});
    send(void, w, "setHasShadow:", .{false});
    // canJoinAllSpaces | stationary | fullScreenAuxiliary
    send(void, w, "setCollectionBehavior:", .{@as(c_ulong, (1 << 0) | (1 << 4) | (1 << 8))});
}

/// True while the Dock is out of the way for the frontmost app, e.g. it is
/// in full screen. Screen-edge overlays can then use the real bottom edge.
pub fn dockHidden() bool {
    const pool = Pool.begin();
    defer pool.end();
    const opts = send(c_ulong, app(), "currentSystemPresentationOptions", .{});
    // autoHideDock | hideDock | fullScreen
    return opts & ((1 << 0) | (1 << 1) | (1 << 10)) != 0;
}

/// Lets an ordinary window open on whichever Space is in front, including
/// over another app's full-screen Space, instead of pulling the user back
/// to the desktop Space it was created on.
pub fn followActiveSpace(ns_window: ?*anyopaque) void {
    const w = ns_window orelse return;
    const pool = Pool.begin();
    defer pool.end();
    // moveToActiveSpace | fullScreenAuxiliary
    send(void, w, "setCollectionBehavior:", .{@as(c_ulong, (1 << 1) | (1 << 8))});
}

/// The screen whose bottom-left corner is the origin of Cocoa's global coordinates: the first
/// of `NSScreen.screens`. `NSScreen.mainScreen` is the screen with keyboard focus instead, which
/// is somewhere else once a second display is attached. Falls back to it with no screens.
fn primaryScreen() Id {
    const NSScreen = objc_getClass("NSScreen");
    const all = send(Id, NSScreen, "screens", .{});
    if (all != null and send(c_ulong, all, "count", .{}) > 0) return send(Id, all, "objectAtIndex:", .{@as(c_ulong, 0)});
    return send(Id, NSScreen, "mainScreen", .{});
}

/// Places a window by its top-left corner in screen points (y down from the
/// top of the primary screen, the one with the menu bar). Unlike normal placement this may overlap the
/// menu bar.
pub fn setTopLeft(ns_window: ?*anyopaque, x: f64, y: f64) void {
    const w = ns_window orelse return;
    const pool = Pool.begin();
    defer pool.end();
    const screen = primaryScreen();
    const frame = send(Rect, screen, "frame", .{});
    send(void, w, "setFrameTopLeftPoint:", .{Point{ .x = x, .y = frame.h - y }});
}

/// Makes an ordinary window's title bar transparent and lets the content (and
/// so the app's own header bar) extend underneath it: the traffic-light
/// buttons stay, the title text and the bar's background go. Pair with
/// `layoutTrafficLights` every frame and `Window.setDragRegion` so the header
/// still drags the window.
pub fn unifiedTitleBar(ns_window: ?*anyopaque) void {
    const w = ns_window orelse return;
    const pool = Pool.begin();
    defer pool.end();
    const style = send(c_ulong, w, "styleMask", .{});
    send(void, w, "setStyleMask:", .{style | (1 << 15)}); // NSWindowStyleMaskFullSizeContentView
    send(void, w, "setTitlebarAppearsTransparent:", .{true});
    send(void, w, "setTitleVisibility:", .{@as(c_long, 1)}); // NSWindowTitleHidden
}

/// Positions the close/minimise/zoom buttons `left` points from the window's
/// left edge, vertically centred in a header `bar_h` points tall, keeping
/// their native spacing. Cheap and idempotent; call every frame because AppKit
/// re-lays them out on resize and full screen. Returns the x of the right edge
/// of the zoom button (where app controls can start), or null without buttons.
pub fn layoutTrafficLights(ns_window: ?*anyopaque, bar_h: f64, left: f64) ?f64 {
    const w = ns_window orelse return null;
    const pool = Pool.begin();
    defer pool.end();
    const close = send(Id, w, "standardWindowButton:", .{@as(c_ulong, 0)});
    const mini = send(Id, w, "standardWindowButton:", .{@as(c_ulong, 1)});
    const zoom = send(Id, w, "standardWindowButton:", .{@as(c_ulong, 2)});
    if (close == null or mini == null or zoom == null) return null;
    const container = send(Id, close, "superview", .{}); // the title bar view
    const holder = send(Id, container, "superview", .{}); // the title bar container, 32 pt tall by default
    const root = send(Id, holder, "superview", .{}); // the window's frame view
    if (container == null or holder == null or root == null) return null;
    // Make the title bar views as tall as our header, pinned to the top edge.
    const rf = send(Rect, root, "frame", .{});
    const want_holder: Rect = .{ .x = 0, .y = rf.h - bar_h, .w = rf.w, .h = bar_h };
    const hf = send(Rect, holder, "frame", .{});
    if (@abs(hf.y - want_holder.y) > 0.5 or @abs(hf.h - bar_h) > 0.5 or @abs(hf.w - rf.w) > 0.5) send(void, holder, "setFrame:", .{want_holder});
    const want: Rect = .{ .x = 0, .y = 0, .w = rf.w, .h = bar_h };
    const cf = send(Rect, container, "frame", .{});
    if (@abs(cf.y) > 0.5 or @abs(cf.h - bar_h) > 0.5 or @abs(cf.w - rf.w) > 0.5) send(void, container, "setFrame:", .{want});
    const cb = send(Rect, close, "frame", .{});
    const step = send(Rect, mini, "frame", .{}).x - cb.x; // native pitch between buttons
    var right: f64 = left;
    for ([_]Id{ close, mini, zoom }, 0..) |btn, i| {
        const f = send(Rect, btn, "frame", .{});
        const x = left + @as(f64, @floatFromInt(i)) * step;
        const y = (bar_h - f.h) / 2;
        if (@abs(f.x - x) > 0.5 or @abs(f.y - y) > 0.5) send(void, btn, "setFrameOrigin:", .{Point{ .x = x, .y = y }});
        right = x + f.w;
    }
    return right;
}

pub const Notch = struct {
    /// Height of the menu bar / notch area in points.
    height: f64,
    /// Width of the camera housing, or 0 on displays without a notch.
    width: f64,
};

pub fn notch() Notch {
    const pool = Pool.begin();
    defer pool.end();
    const screen = primaryScreen();
    const insets = send(EdgeInsets, screen, "safeAreaInsets", .{});
    if (insets.top <= 0) return .{ .height = 24, .width = 0 };
    const frame = send(Rect, screen, "frame", .{});
    const left = send(Rect, screen, "auxiliaryTopLeftArea", .{});
    const right = send(Rect, screen, "auxiliaryTopRightArea", .{});
    return .{ .height = insets.top, .width = @max(0, frame.w - left.w - right.w) };
}

// ---- menu-bar status item ----------------------------------------------

var pending_action = std.atomic.Value(c_long).init(0);
var menu_target: Id = null;

fn fire(_: Id, _: Sel, sender: Id) callconv(.c) void {
    pending_action.store(send(c_long, sender, "tag", .{}), .release);
}

/// Returns the tag of the menu item chosen since the last call, if any.
pub fn takeMenuAction() ?c_long {
    const tag = pending_action.swap(0, .acq_rel);
    return if (tag == 0) null else tag;
}

pub const StatusItem = struct {
    item: Id,
    menu: Id,

    pub fn init(title: [*:0]const u8) StatusItem {
        if (menu_target == null) {
            const cls = objc_allocateClassPair(objc_getClass("NSObject"), "VassMenuTarget", 0);
            _ = class_addMethod(cls, sel_registerName("fire:"), &fire, "v@:@");
            objc_registerClassPair(cls);
            menu_target = send(Id, send(Id, cls, "alloc", .{}), "init", .{});
        }
        const pool = Pool.begin();
        defer pool.end();
        const bar = send(Id, objc_getClass("NSStatusBar"), "systemStatusBar", .{});
        const item = send(Id, send(Id, bar, "statusItemWithLength:", .{@as(f64, -1)}), "retain", .{}); // released in deinit
        const menu = send(Id, send(Id, objc_getClass("NSMenu"), "alloc", .{}), "init", .{}); // likewise
        send(void, item, "setMenu:", .{menu});
        var s: StatusItem = .{ .item = item, .menu = menu };
        s.setTitle(title);
        return s;
    }

    pub fn setTitle(s: *StatusItem, title: [*:0]const u8) void {
        const pool = Pool.begin();
        defer pool.end();
        send(void, send(Id, s.item, "button", .{}), "setTitle:", .{nsString(title)});
    }

    /// Shows an image (PNG bytes) to the left of the title, at the given
    /// size in points. Pass pixels at 2x for Retina sharpness.
    pub fn setImage(s: *StatusItem, png: []const u8, width: f64, height: f64) void {
        const pool = Pool.begin();
        defer pool.end();
        const data = send(Id, objc_getClass("NSData"), "dataWithBytes:length:", .{ @as(?*const anyopaque, png.ptr), @as(c_ulong, png.len) });
        const img = send(Id, send(Id, objc_getClass("NSImage"), "alloc", .{}), "initWithData:", .{data});
        if (img == null) return;
        send(void, img, "setSize:", .{Size{ .w = width, .h = height }});
        const button = send(Id, s.item, "button", .{});
        send(void, button, "setImage:", .{img});
        send(void, button, "setImagePosition:", .{@as(c_ulong, 2)}); // image left of title
        send(void, img, "release", .{}); // the button keeps its own reference
    }

    /// Adds a menu entry; `tag` (non-zero) is what `takeMenuAction` reports.
    pub fn addItem(s: *StatusItem, title: [*:0]const u8, tag: c_long) void {
        const pool = Pool.begin();
        defer pool.end();
        const mi = send(Id, send(Id, objc_getClass("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
            nsString(title), sel_registerName("fire:"), nsString(""),
        });
        send(void, mi, "setTarget:", .{menu_target});
        send(void, mi, "setTag:", .{tag});
        send(void, s.menu, "addItem:", .{mi});
        send(void, mi, "release", .{}); // the menu keeps its own reference
    }

    pub fn addSeparator(s: *StatusItem) void {
        const pool = Pool.begin();
        defer pool.end();
        send(void, s.menu, "addItem:", .{send(Id, objc_getClass("NSMenuItem"), "separatorItem", .{})});
    }

    pub fn deinit(s: *StatusItem) void {
        const pool = Pool.begin();
        defer pool.end();
        const bar = send(Id, objc_getClass("NSStatusBar"), "systemStatusBar", .{});
        send(void, bar, "removeStatusItem:", .{s.item});
        send(void, s.item, "setMenu:", .{@as(Id, null)});
        send(void, s.menu, "release", .{}); // the menu items go with it
        send(void, s.item, "release", .{});
        s.* = undefined;
    }
};

test "objc_msgSend_stret is used for structs returned in memory on x86_64 only" {
    try std.testing.expect(needsStret(Rect, .x86_64));
    try std.testing.expect(needsStret(EdgeInsets, .x86_64));
    try std.testing.expect(!needsStret(Point, .x86_64)); // two doubles: xmm0:xmm1
    try std.testing.expect(!needsStret(Size, .x86_64));
    try std.testing.expect(!needsStret(c_long, .x86_64));
    try std.testing.expect(!needsStret(Rect, .aarch64));
    try std.testing.expect(!needsStret(EdgeInsets, .aarch64));
}

test "the primary screen is the first of NSScreen.screens, not the focused one" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = Pool.begin();
    defer pool.end();
    const all = send(Id, objc_getClass("NSScreen"), "screens", .{});
    if (all == null or send(c_ulong, all, "count", .{}) == 0) return error.SkipZigTest; // headless
    try std.testing.expectEqual(send(Id, all, "objectAtIndex:", .{@as(c_ulong, 0)}), primaryScreen());
}
