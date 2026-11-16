//! Bounded cache of rasterised SVG icons, keyed by (icon id, pixel width, pixel height).
//! Generic over the texture handle type so the policy is testable without a GPU.
//!
//! Entries touched during frame `n` are never evicted by `evict(n)`: the renderer may still
//! have queued draws that use them. Entries beyond the limits are dropped least recently used
//! first, once per frame after presenting.
const std = @import("std");

pub fn key(id: u32, w: u32, h: u32) u64 {
    return (@as(u64, id) << 32) | (@as(u64, w & 0xffff) << 16) | (h & 0xffff);
}

pub fn keyId(k: u64) u32 {
    return @intCast(k >> 32);
}

pub fn Cache(comptime Tex: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { tex: Tex, bytes: usize, last_used: u64 };

        map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
        bytes: usize = 0,
        max_entries: usize = 192,
        max_bytes: usize = 24 * 1024 * 1024,

        pub fn count(c: *const Self) usize {
            return c.map.count();
        }

        /// The cached texture, marked as used in `frame`.
        pub fn get(c: *Self, k: u64, frame: u64) ?Tex {
            const e = c.map.getPtr(k) orelse return null;
            e.last_used = frame;
            return e.tex;
        }

        pub fn put(c: *Self, gpa: std.mem.Allocator, k: u64, tex: Tex, bytes: usize, frame: u64) !void {
            const old = try c.map.fetchPut(gpa, k, .{ .tex = tex, .bytes = bytes, .last_used = frame });
            if (old) |o| c.bytes -= o.value.bytes;
            c.bytes += bytes;
        }

        /// Drops entries over the limits, least recently used first, never one used in `frame`.
        /// `destroy(ctx, tex)` releases the texture.
        pub fn evict(c: *Self, gpa: std.mem.Allocator, frame: u64, ctx: anytype, comptime destroy: anytype) void {
            while (c.map.count() > c.max_entries or c.bytes > c.max_bytes) {
                var oldest: ?u64 = null;
                var oldest_used: u64 = frame;
                var it = c.map.iterator();
                while (it.next()) |kv| {
                    if (kv.value_ptr.last_used < oldest_used) {
                        oldest_used = kv.value_ptr.last_used;
                        oldest = kv.key_ptr.*;
                    }
                }
                const k = oldest orelse return; // everything left was used this frame
                c.remove(gpa, k, ctx, destroy);
            }
        }

        fn remove(c: *Self, gpa: std.mem.Allocator, k: u64, ctx: anytype, comptime destroy: anytype) void {
            _ = gpa;
            if (c.map.fetchRemove(k)) |kv| {
                c.bytes -= kv.value.bytes;
                destroy(ctx, kv.value.tex);
            }
        }

        /// Drops every size of one icon.
        pub fn removeIcon(c: *Self, gpa: std.mem.Allocator, id: u32, ctx: anytype, comptime destroy: anytype) void {
            var doomed: std.ArrayList(u64) = .empty;
            defer doomed.deinit(gpa);
            var it = c.map.keyIterator();
            while (it.next()) |k| {
                if (keyId(k.*) == id) doomed.append(gpa, k.*) catch break;
            }
            for (doomed.items) |k| c.remove(gpa, k, ctx, destroy);
        }

        pub fn deinit(c: *Self, gpa: std.mem.Allocator, ctx: anytype, comptime destroy: anytype) void {
            var it = c.map.valueIterator();
            while (it.next()) |e| destroy(ctx, e.tex);
            c.map.deinit(gpa);
            c.bytes = 0;
        }
    };
}

const testing = std.testing;

const Fake = struct {
    destroyed: std.ArrayList(u32) = .empty,
    fn destroy(f: *Fake, t: u32) void {
        f.destroyed.append(testing.allocator, t) catch unreachable;
    }
};

test "keys separate icon and size" {
    try testing.expect(key(1, 32, 32) != key(1, 48, 48));
    try testing.expect(key(1, 32, 32) != key(2, 32, 32));
    try testing.expectEqual(@as(u32, 7), keyId(key(7, 1000, 20)));
}

test "get marks use; put replaces and accounts bytes" {
    var c: Cache(u32) = .{};
    var f: Fake = .{};
    defer f.destroyed.deinit(testing.allocator);
    defer c.deinit(testing.allocator, &f, Fake.destroy);
    try c.put(testing.allocator, key(1, 16, 16), 10, 100, 1);
    try testing.expectEqual(@as(?u32, 10), c.get(key(1, 16, 16), 5));
    try testing.expectEqual(@as(?u32, null), c.get(key(1, 17, 16), 5));
    try c.put(testing.allocator, key(1, 16, 16), 11, 300, 5);
    try testing.expectEqual(@as(usize, 300), c.bytes);
    try testing.expectEqual(@as(usize, 1), c.count());
}

test "eviction is LRU, bounded by entries and bytes, and spares the current frame" {
    var c: Cache(u32) = .{ .max_entries = 3 };
    var f: Fake = .{};
    defer f.destroyed.deinit(testing.allocator);
    defer c.deinit(testing.allocator, &f, Fake.destroy);
    for (0..5) |i| try c.put(testing.allocator, key(1, @intCast(16 + i), 16), @intCast(i), 10, 1 + i);
    // Frame 5: entries 0..3 are older, entry 4 is current.
    c.evict(testing.allocator, 5, &f, Fake.destroy);
    try testing.expectEqual(@as(usize, 3), c.count());
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, f.destroyed.items); // oldest first
    // Everything used this frame survives even over the limit.
    c.max_entries = 1;
    _ = c.get(key(1, 18, 16), 9);
    _ = c.get(key(1, 19, 16), 9);
    _ = c.get(key(1, 20, 16), 9);
    c.evict(testing.allocator, 9, &f, Fake.destroy);
    try testing.expectEqual(@as(usize, 3), c.count());
    // Byte limit.
    c.max_entries = 100;
    c.max_bytes = 15;
    c.evict(testing.allocator, 10, &f, Fake.destroy);
    try testing.expectEqual(@as(usize, 1), c.count());
    try testing.expect(c.bytes <= 15);
}

test "removeIcon drops all sizes of one icon only" {
    var c: Cache(u32) = .{};
    var f: Fake = .{};
    defer f.destroyed.deinit(testing.allocator);
    defer c.deinit(testing.allocator, &f, Fake.destroy);
    try c.put(testing.allocator, key(1, 16, 16), 1, 5, 1);
    try c.put(testing.allocator, key(1, 32, 32), 2, 5, 1);
    try c.put(testing.allocator, key(2, 16, 16), 3, 5, 1);
    c.removeIcon(testing.allocator, 1, &f, Fake.destroy);
    try testing.expectEqual(@as(usize, 1), c.count());
    try testing.expectEqual(@as(usize, 5), c.bytes);
    try testing.expectEqual(@as(usize, 2), f.destroyed.items.len);
}
