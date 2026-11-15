//! macOS extras, done through the Objective-C runtime so no Swift/ObjC source
//! is needed: accessory (no Dock icon) apps, overlay windows, the notch, and
//! a menu-bar status item. Everything here must run on the main thread.
const std = @import("std");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const Point = extern struct { x: f64, y: f64 };
const Size = extern struct { w: f64, h: f64 };
const Rect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const EdgeInsets = extern struct { top: f64, left: f64, bottom: f64, right: f64 };

extern fn objc_getClass(name: [*:0]const u8) Id;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_msgSend() void;
extern fn objc_allocateClassPair(super: Id, name: [*:0]const u8, extra: usize) Id;
extern fn objc_registerClassPair(cls: Id) void;
extern fn class_addMethod(cls: Id, sel: Sel, imp: *const anyopaque, types: [*:0]const u8) bool;

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
    const func: F = @ptrCast(&objc_msgSend);
    return @call(.auto, func, .{ target, sel_registerName(selector) } ++ args);
}

fn nsString(text: [*:0]const u8) Id {
    return send(Id, objc_getClass("NSString"), "stringWithUTF8String:", .{text});
}

fn app() Id {
    return send(Id, objc_getClass("NSApplication"), "sharedApplication", .{});
}

/// Run as a menu-bar style app: no Dock icon, no app menu.
pub fn setAccessory() void {
    _ = send(bool, app(), "setActivationPolicy:", .{@as(c_long, 1)});
}

/// Bring the app's windows in front of other apps.
pub fn activate() void {
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
    send(void, w, "setLevel:", .{@intFromEnum(level)});
    send(void, w, "setIgnoresMouseEvents:", .{click_through});
    send(void, w, "setHasShadow:", .{false});
    // canJoinAllSpaces | stationary | fullScreenAuxiliary
    send(void, w, "setCollectionBehavior:", .{@as(c_ulong, (1 << 0) | (1 << 4) | (1 << 8))});
}

/// True while the Dock is out of the way for the frontmost app, e.g. it is
/// in full screen. Screen-edge overlays can then use the real bottom edge.
pub fn dockHidden() bool {
    const opts = send(c_ulong, app(), "currentSystemPresentationOptions", .{});
    // autoHideDock | hideDock | fullScreen
    return opts & ((1 << 0) | (1 << 1) | (1 << 10)) != 0;
}

/// Lets an ordinary window open on whichever Space is in front, including
/// over another app's full-screen Space, instead of pulling the user back
/// to the desktop Space it was created on.
pub fn followActiveSpace(ns_window: ?*anyopaque) void {
    const w = ns_window orelse return;
    // moveToActiveSpace | fullScreenAuxiliary
    send(void, w, "setCollectionBehavior:", .{@as(c_ulong, (1 << 1) | (1 << 8))});
}

/// Places a window by its top-left corner in screen points (y down from the
/// top of the main screen). Unlike normal placement this may overlap the
/// menu bar.
pub fn setTopLeft(ns_window: ?*anyopaque, x: f64, y: f64) void {
    const w = ns_window orelse return;
    const screen = send(Id, objc_getClass("NSScreen"), "mainScreen", .{});
    const frame = send(Rect, screen, "frame", .{});
    send(void, w, "setFrameTopLeftPoint:", .{Point{ .x = x, .y = frame.h - y }});
}

pub const Notch = struct {
    /// Height of the menu bar / notch area in points.
    height: f64,
    /// Width of the camera housing, or 0 on displays without a notch.
    width: f64,
};

pub fn notch() Notch {
    const screen = send(Id, objc_getClass("NSScreen"), "mainScreen", .{});
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
        const bar = send(Id, objc_getClass("NSStatusBar"), "systemStatusBar", .{});
        const item = send(Id, send(Id, bar, "statusItemWithLength:", .{@as(f64, -1)}), "retain", .{});
        const menu = send(Id, send(Id, objc_getClass("NSMenu"), "alloc", .{}), "init", .{});
        send(void, item, "setMenu:", .{menu});
        var s: StatusItem = .{ .item = item, .menu = menu };
        s.setTitle(title);
        return s;
    }

    pub fn setTitle(s: *StatusItem, title: [*:0]const u8) void {
        send(void, send(Id, s.item, "button", .{}), "setTitle:", .{nsString(title)});
    }

    /// Shows an image (PNG bytes) to the left of the title, at the given
    /// size in points. Pass pixels at 2x for Retina sharpness.
    pub fn setImage(s: *StatusItem, png: []const u8, width: f64, height: f64) void {
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
        const mi = send(Id, send(Id, objc_getClass("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
            nsString(title), sel_registerName("fire:"), nsString(""),
        });
        send(void, mi, "setTarget:", .{menu_target});
        send(void, mi, "setTag:", .{tag});
        send(void, s.menu, "addItem:", .{mi});
    }

    pub fn addSeparator(s: *StatusItem) void {
        send(void, s.menu, "addItem:", .{send(Id, objc_getClass("NSMenuItem"), "separatorItem", .{})});
    }

    pub fn deinit(s: *StatusItem) void {
        const bar = send(Id, objc_getClass("NSStatusBar"), "systemStatusBar", .{});
        send(void, bar, "removeStatusItem:", .{s.item});
    }
};
