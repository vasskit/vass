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

        const Stale = struct { key: u64, tex: Tex, last_used: u64 };

        map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
        /// Textures replaced by `put`, destroyed by the first `evict` after their last use.
        stale: std.ArrayList(Stale) = .empty,
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
            if (c.map.getPtr(k)) |e| {
                // Queued draws may still use the old texture, and `put` has no way to destroy
                // it: keep it until `evict` can.
                try c.stale.append(gpa, .{ .key = k, .tex = e.tex, .last_used = e.last_used });
                c.bytes -= e.bytes;
                e.* = .{ .tex = tex, .bytes = bytes, .last_used = frame };
            } else {
                try c.map.put(gpa, k, .{ .tex = tex, .bytes = bytes, .last_used = frame });
            }
            c.bytes += bytes;
        }

        /// Drops entries over the limits, least recently used first, never one used in `frame`.
        /// `destroy(ctx, tex)` releases the texture.
        pub fn evict(c: *Self, gpa: std.mem.Allocator, frame: u64, ctx: anytype, comptime destroy: anytype) void {
            var keep: usize = 0;
            for (c.stale.items) |st| {
                if (st.last_used < frame) {
                    destroy(ctx, st.tex);
                } else {
                    c.stale.items[keep] = st;
                    keep += 1;
                }
            }
            c.stale.shrinkRetainingCapacity(keep);
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
            var keep: usize = 0;
            for (c.stale.items) |st| {
                if (keyId(st.key) == id) {
                    destroy(ctx, st.tex);
                } else {
                    c.stale.items[keep] = st;
                    keep += 1;
                }
            }
            c.stale.shrinkRetainingCapacity(keep);
        }

        pub fn deinit(c: *Self, gpa: std.mem.Allocator, ctx: anytype, comptime destroy: anytype) void {
            var it = c.map.valueIterator();
            while (it.next()) |e| destroy(ctx, e.tex);
            for (c.stale.items) |st| destroy(ctx, st.tex);
            c.stale.deinit(gpa);
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

test "replacing an entry hands the old texture back for destruction, once, after its frame" {
    var c: Cache(u32) = .{};
    var f: Fake = .{};
    defer f.destroyed.deinit(testing.allocator);
    try c.put(testing.allocator, key(1, 16, 16), 10, 100, 1);
    // Frame 5 replaces it (a re-rasterise at the same size); queued draws of frame 5 may still
    // use texture 10, so it goes at the first eviction after that frame.
    _ = c.get(key(1, 16, 16), 5);
    try c.put(testing.allocator, key(1, 16, 16), 11, 300, 5);
    try testing.expectEqual(@as(usize, 300), c.bytes);
    c.evict(testing.allocator, 5, &f, Fake.destroy);
    try testing.expectEqual(@as(usize, 0), f.destroyed.items.len);
    c.evict(testing.allocator, 6, &f, Fake.destroy);
    try testing.expectEqualSlices(u32, &.{10}, f.destroyed.items);
    c.evict(testing.allocator, 7, &f, Fake.destroy);
    try testing.expectEqual(@as(usize, 1), f.destroyed.items.len);
    // A replacement that is never evicted is released by deinit, together with the live ones.
    try c.put(testing.allocator, key(1, 16, 16), 12, 5, 8);
    c.deinit(testing.allocator, &f, Fake.destroy);
    std.mem.sort(u32, f.destroyed.items, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 10, 11, 12 }, f.destroyed.items);
}

test "removeIcon also releases replaced textures of that icon" {
    var c: Cache(u32) = .{};
    var f: Fake = .{};
    defer f.destroyed.deinit(testing.allocator);
    defer c.deinit(testing.allocator, &f, Fake.destroy);
    try c.put(testing.allocator, key(1, 16, 16), 1, 5, 1);
    try c.put(testing.allocator, key(1, 16, 16), 2, 5, 2);
    try c.put(testing.allocator, key(2, 16, 16), 3, 5, 2);
    try c.put(testing.allocator, key(2, 16, 16), 4, 5, 3);
    c.removeIcon(testing.allocator, 1, &f, Fake.destroy);
    std.mem.sort(u32, f.destroyed.items, {}, std.sort.asc(u32));
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, f.destroyed.items);
}
