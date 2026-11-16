//! Keyboard vocabulary shared by the backend, the text editing core and the
//! widgets: modifier flags and the keycodes the toolkit itself reacts to.
//! Pure data, no platform calls. Values are SDL3 keycodes: for printable keys
//! the lowercase ASCII value, for the rest the SDL constants.

pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Command on macOS (the "GUI" key elsewhere).
    cmd: bool = false,

    pub const none: Mods = .{};
};

pub const backspace: u32 = 0x08;
pub const tab: u32 = 0x09;
pub const @"return": u32 = 0x0d;
pub const escape: u32 = 0x1b;
pub const space: u32 = 0x20;
pub const delete: u32 = 0x7f;
pub const a: u32 = 'a';
pub const c: u32 = 'c';
pub const v: u32 = 'v';
pub const x: u32 = 'x';
pub const y: u32 = 'y';
pub const z: u32 = 'z';
pub const home: u32 = 0x4000004a;
pub const page_up: u32 = 0x4000004b;
pub const end: u32 = 0x4000004d;
pub const page_down: u32 = 0x4000004e;
pub const right: u32 = 0x4000004f;
pub const left: u32 = 0x40000050;
pub const down: u32 = 0x40000051;
pub const up: u32 = 0x40000052;

const kp_enter: u32 = 0x40000058;
const kp_tab: u32 = 0x400000ba;
const kp_backspace: u32 = 0x400000bb;
const kp_space: u32 = 0x400000cd;

/// The key code the toolkit reacts to for a platform key code: the keypad's Enter, Tab,
/// Backspace and Space report their main-block equivalents, so widgets see one key. Any other
/// code is returned as is.
pub fn normalize(code: u32) u32 {
    return switch (code) {
        kp_enter => @"return",
        kp_tab => tab,
        kp_backspace => backspace,
        kp_space => space,
        else => code,
    };
}

test "keypad keys report their main-block equivalents" {
    const std = @import("std");
    try std.testing.expectEqual(@"return", normalize(0x40000058));
    try std.testing.expectEqual(tab, normalize(0x400000ba));
    try std.testing.expectEqual(backspace, normalize(0x400000bb));
    try std.testing.expectEqual(space, normalize(0x400000cd));
    try std.testing.expectEqual(left, normalize(left));
    try std.testing.expectEqual(@as(u32, 'a'), normalize('a'));
}
