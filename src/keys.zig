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
