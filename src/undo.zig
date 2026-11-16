//! Undo/redo history for `TextEdit`: edits stored as deltas (where, which bytes
//! left, which bytes arrived, and the caret/selection before and after), with
//! macOS-style coalescing of typing runs. Pure data, no rendering.
//!
//! The history never fails an edit: recording an entry that cannot be allocated
//! just drops the whole history (`clear`), so the text is always right and at
//! worst there is nothing to undo.
//!
//! Memory is bounded by `Limits`: when there are too many entries or too many
//! bytes the oldest are dropped.
const std = @import("std");

/// Caret and selection anchor, as byte offsets.
pub const Sel = struct { cursor: usize, anchor: usize };

/// What kind of edit an entry is. Only `typing`, `backspace` and `forward_delete`
/// runs coalesce; every other kind is a step of its own.
pub const Kind = enum {
    /// Typed or composed (IME) text.
    typing,
    /// A single-character backspace.
    backspace,
    /// A single-character forward delete.
    forward_delete,
    /// Pasted text.
    paste,
    /// Cut.
    cut,
    /// The selection was replaced (typed over, deleted, ...).
    replace,
    /// A line break.
    newline,
    /// Anything else: word/line deletion, programmatic replacement.
    other,

    fn mergeable(k: Kind) bool {
        return k == .typing or k == .backspace or k == .forward_delete;
    }
};

pub const Limits = struct {
    /// Most undo steps kept.
    max_entries: usize = 1000,
    /// Most bytes of removed and inserted text kept, over undo and redo together.
    max_bytes: usize = 1 << 20,
    /// A pause longer than this (seconds) ends a typing run.
    pause: f64 = 1.0,
    /// A run is not extended past this many bytes of text.
    max_group_bytes: usize = 4096,
};

/// One undoable change: at `offset`, `removed()` was replaced by `inserted()`.
pub const Entry = struct {
    offset: usize,
    removed_len: usize,
    /// `removed_len` bytes of removed text, then the inserted text.
    data: []u8,
    before: Sel,
    after: Sel,
    kind: Kind,
    /// When the entry was last extended (the caller's clock).
    time: f64,

    pub fn removed(en: Entry) []const u8 {
        return en.data[0..en.removed_len];
    }

    pub fn inserted(en: Entry) []const u8 {
        return en.data[en.removed_len..];
    }
};

/// A change as the editor describes it; the history copies the bytes.
pub const Delta = struct {
    offset: usize,
    removed: []const u8,
    inserted: []const u8,
    before: Sel,
    after: Sel,
    kind: Kind,
};

pub const History = struct {
    undo_stack: std.ArrayList(Entry) = .empty,
    redo_stack: std.ArrayList(Entry) = .empty,
    /// Bytes held by all entries' data.
    bytes: usize = 0,
    /// Whether the newest undo entry may still be extended by the next edit.
    /// Cleared by anything that is not an edit: moving the caret, undo, redo.
    open: bool = false,
    limits: Limits = .{},

    pub fn deinit(h: *History, gpa: std.mem.Allocator) void {
        h.clear(gpa);
        h.undo_stack.deinit(gpa);
        h.redo_stack.deinit(gpa);
    }

    /// Forgets everything.
    pub fn clear(h: *History, gpa: std.mem.Allocator) void {
        for (h.undo_stack.items) |en| gpa.free(en.data);
        for (h.redo_stack.items) |en| gpa.free(en.data);
        h.undo_stack.clearRetainingCapacity();
        h.redo_stack.clearRetainingCapacity();
        h.bytes = 0;
        h.open = false;
    }

    pub fn canUndo(h: *const History) bool {
        return h.undo_stack.items.len > 0;
    }

    pub fn canRedo(h: *const History) bool {
        return h.redo_stack.items.len > 0;
    }

    /// Ends the current typing run: the next edit starts a new step.
    pub fn breakGroup(h: *History) void {
        h.open = false;
    }

    fn clearRedo(h: *History, gpa: std.mem.Allocator) void {
        for (h.redo_stack.items) |en| {
            h.bytes -= en.data.len;
            gpa.free(en.data);
        }
        h.redo_stack.clearRetainingCapacity();
    }

    fn isSpace(b: u8) bool {
        return b == ' ' or b == '\t';
    }

    /// Whether `d` continues the newest entry `top`.
    fn continues(h: *const History, top: Entry, d: Delta, now: f64) bool {
        if (!h.open or !d.kind.mergeable() or d.kind != top.kind) return false;
        if (@abs(now - top.time) > h.limits.pause) return false;
        if (top.data.len + d.removed.len + d.inserted.len > h.limits.max_group_bytes) return false;
        // The caret must be exactly where the run left it.
        if (d.before.cursor != top.after.cursor or d.before.anchor != top.after.anchor) return false;
        switch (d.kind) {
            .typing => {
                if (d.removed.len != 0 or d.inserted.len == 0) return false;
                if (d.offset != top.offset + top.inserted().len) return false;
                // A space typed after a word starts a new step.
                const last = top.inserted();
                if (last.len > 0 and isSpace(d.inserted[0]) and !isSpace(last[last.len - 1])) return false;
                return true;
            },
            .backspace => return d.inserted.len == 0 and d.offset + d.removed.len == top.offset,
            .forward_delete => return d.inserted.len == 0 and d.offset == top.offset,
            else => return false,
        }
    }

    /// Records a change that has just been (or is about to be) applied. Clears
    /// the redo stack. Never fails: if memory runs out the history is dropped.
    pub fn record(h: *History, gpa: std.mem.Allocator, d: Delta, now: f64) void {
        if (d.removed.len == 0 and d.inserted.len == 0) return;
        h.clearRedo(gpa);
        if (h.undo_stack.items.len > 0) {
            const top = &h.undo_stack.items[h.undo_stack.items.len - 1];
            if (h.continues(top.*, d, now)) {
                if (h.merge(gpa, top, d, now)) return;
                h.clear(gpa);
                return;
            }
        }
        const data = gpa.alloc(u8, d.removed.len + d.inserted.len) catch return h.clear(gpa);
        @memcpy(data[0..d.removed.len], d.removed);
        @memcpy(data[d.removed.len..], d.inserted);
        h.undo_stack.append(gpa, .{
            .offset = d.offset,
            .removed_len = d.removed.len,
            .data = data,
            .before = d.before,
            .after = d.after,
            .kind = d.kind,
            .time = now,
        }) catch {
            gpa.free(data);
            return h.clear(gpa);
        };
        h.bytes += data.len;
        h.open = true;
        h.trim(gpa);
    }

    fn merge(h: *History, gpa: std.mem.Allocator, top: *Entry, d: Delta, now: f64) bool {
        const old = top.data;
        const data = gpa.alloc(u8, old.len + d.removed.len + d.inserted.len) catch return false;
        switch (d.kind) {
            .typing => {
                @memcpy(data[0..old.len], old);
                @memcpy(data[old.len..], d.inserted);
            },
            .backspace => {
                // The new deletion lies before the old one.
                @memcpy(data[0..d.removed.len], d.removed);
                @memcpy(data[d.removed.len..], old);
                top.offset = d.offset;
                top.removed_len += d.removed.len;
            },
            .forward_delete => {
                @memcpy(data[0..old.len], old);
                @memcpy(data[old.len..], d.removed);
                top.removed_len += d.removed.len;
            },
            else => unreachable,
        }
        gpa.free(old);
        h.bytes = h.bytes - old.len + data.len;
        top.data = data;
        top.after = d.after;
        top.time = now;
        h.trim(gpa);
        return true;
    }

    /// Drops the oldest steps until the limits hold.
    fn trim(h: *History, gpa: std.mem.Allocator) void {
        while (h.undo_stack.items.len > 0 and
            (h.undo_stack.items.len > h.limits.max_entries or h.bytes > h.limits.max_bytes))
        {
            const en = h.undo_stack.orderedRemove(0);
            h.bytes -= en.data.len;
            gpa.free(en.data);
        }
        if (h.undo_stack.items.len == 0) h.open = false;
    }

    // ---- moving entries between the stacks (used by TextEdit) ----------

    /// The newest undo entry, if any.
    pub fn peekUndo(h: *const History) ?Entry {
        return if (h.undo_stack.items.len > 0) h.undo_stack.items[h.undo_stack.items.len - 1] else null;
    }

    pub fn peekRedo(h: *const History) ?Entry {
        return if (h.redo_stack.items.len > 0) h.redo_stack.items[h.redo_stack.items.len - 1] else null;
    }

    /// Makes room so `moveToRedo`/`moveToUndo` cannot fail.
    pub fn reserve(h: *History, gpa: std.mem.Allocator) !void {
        try h.undo_stack.ensureUnusedCapacity(gpa, 1);
        try h.redo_stack.ensureUnusedCapacity(gpa, 1);
    }

    /// Moves the newest undo entry onto the redo stack. Needs `reserve` first.
    pub fn moveToRedo(h: *History) void {
        h.redo_stack.appendAssumeCapacity(h.undo_stack.pop().?);
        h.open = false;
    }

    /// Moves the newest redo entry back onto the undo stack. Needs `reserve` first.
    pub fn moveToUndo(h: *History) void {
        h.undo_stack.appendAssumeCapacity(h.redo_stack.pop().?);
        h.open = false;
    }
};
