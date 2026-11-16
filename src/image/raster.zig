//! Software rasteriser for `svg.Doc`: curves are flattened, strokes are converted to polygons
//! (round/butt/square caps, miter/round/bevel joins), and polygons are filled with an exact-area
//! horizontal / 16x vertical sub-scanline coverage rasteriser (non-zero and even-odd).
//! Pure Zig, no platform.
//!
//! Two outputs:
//!  * `renderMask`: an A8 coverage mask where every painted shape counts as ink (union of
//!    coverage, scaled by the shape's opacity). Colours are ignored. For monochrome icons that
//!    are tinted at draw time.
//!  * `renderRgba`: premultiplied RGBA8 with each shape's own flat colour or gradient;
//!    `currentColor` is replaced by the colour passed in.
//!
//! The document is fitted into the `w` x `h` pixel box uniformly (contain, centred); pick a
//! box with the document's aspect ratio for an exact fit.
const std = @import("std");
const svg = @import("svg.zig");

pub const Error = error{ OutOfMemory, TooLarge, TooComplex };

/// Largest raster side accepted.
pub const max_side: u32 = 2048;
/// Sub-scanlines per pixel row.
const sub_n = 16;
/// Flattening tolerance in device pixels.
const flat_tol: f32 = 0.08;
const max_edges = 3_000_000;
/// Points that curve flattening may produce for one render, over all shapes (16 MB). A cubic
/// emits up to 400, so the document's own 200,000-point limit alone would allow 26 million.
/// Real icons and illustrations use well under 100,000.
const max_flat_points = 2_000_000;
/// Active edges examined per sub-scanline, summed over a render: about a second of work. A
/// 2048 px tall page with 500 edges crossing every row costs 16 million.
const max_fill_work: u64 = 1 << 27;
/// Crossing lists up to this long are sorted by insertion, which beats a real sort when tiny.
const small_sort = 16;

const P = [2]f32;

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, dir: i8 };

/// Collects polygon edges in device space.
const EdgeList = struct {
    edges: std.ArrayList(Edge) = .empty,
    gpa: std.mem.Allocator,
    /// User space to device.
    m: svg.Affine = .{},
    /// Reverse polygons wound negatively in user space, so overlapping pieces add up.
    normalize: bool = false,
    failed: bool = false,

    fn clear(l: *EdgeList) void {
        l.edges.clearRetainingCapacity();
        l.failed = false;
    }

    /// Adds the closed polygon `pts` (user space).
    fn poly(l: *EdgeList, pts: []const P) void {
        if (pts.len < 3 or l.failed) return;
        var rev = false;
        if (l.normalize) {
            var area: f32 = 0;
            for (pts, 0..) |a, i| {
                const b = pts[(i + 1) % pts.len];
                area += a[0] * b[1] - b[0] * a[1];
            }
            // Sign convention: compare in device orientation, so a flipping transform keeps
            // all pieces consistently wound (they are all reversed or none).
            rev = area < 0;
        }
        var prev = l.m.apply(pts[if (rev) pts.len - 1 else 0][0], pts[if (rev) pts.len - 1 else 0][1]);
        const first = prev;
        var k: usize = 1;
        while (k <= pts.len) : (k += 1) {
            const q = if (k == pts.len) first else blk: {
                const src = pts[if (rev) pts.len - 1 - k else k];
                break :blk l.m.apply(src[0], src[1]);
            };
            l.add(prev, q);
            prev = q;
        }
    }

    fn add(l: *EdgeList, a: P, b: P) void {
        if (!(std.math.isFinite(a[0]) and std.math.isFinite(a[1]) and std.math.isFinite(b[0]) and std.math.isFinite(b[1]))) return;
        if (a[1] == b[1]) return;
        if (l.edges.items.len >= max_edges) {
            l.failed = true;
            return;
        }
        const lim = 1e6;
        const ca = P{ std.math.clamp(a[0], -lim, lim), std.math.clamp(a[1], -lim, lim) };
        const cb = P{ std.math.clamp(b[0], -lim, lim), std.math.clamp(b[1], -lim, lim) };
        if (ca[1] == cb[1]) return;
        const e: Edge = if (ca[1] < cb[1])
            .{ .x0 = ca[0], .y0 = ca[1], .x1 = cb[0], .y1 = cb[1], .dir = 1 }
        else
            .{ .x0 = cb[0], .y0 = cb[1], .x1 = ca[0], .y1 = ca[1], .dir = -1 };
        l.edges.append(l.gpa, e) catch {
            l.failed = true;
        };
    }
};

fn edgeLess(_: void, a: Edge, b: Edge) bool {
    return a.y0 < b.y0;
}

const Crossing = struct { x: f32, dir: i32 };

fn crossingLess(ops: *u64, a: Crossing, b: Crossing) bool {
    ops.* += 1;
    return a.x < b.x;
}

/// A half-open rectangle of raster rows and columns.
const Bounds = struct {
    r0: u32 = 0,
    r1: u32 = 0,
    c0: u32 = 0,
    c1: u32 = 0,

    fn empty(b: Bounds) bool {
        return b.r0 >= b.r1 or b.c0 >= b.c1;
    }

    fn area(b: Bounds) u64 {
        return if (b.empty()) 0 else @as(u64, b.r1 - b.r0) * (b.c1 - b.c0);
    }
};

/// Coverage rasteriser with reusable scratch memory.
///
/// `fill` writes coverage only inside the shape's bounding box and clears only what the previous
/// fill wrote, so a shape costs its own size and not the raster's. The coverage buffer must be
/// all zero outside `dirty`; the first fill clears all of it, whatever it held.
const Filler = struct {
    gpa: std.mem.Allocator,
    w: u32,
    h: u32,
    partial: []f32,
    diff: []f32,
    active: std.ArrayList(u32) = .empty,
    cross: std.ArrayList(Crossing) = .empty,
    /// Remaining budget of `max_fill_work` units.
    work_left: u64 = max_fill_work,
    /// Comparisons and moves spent sorting crossings; tests bound it.
    sort_ops: u64 = 0,
    /// Where the coverage buffer may be non-zero.
    dirty: Bounds,
    /// Treat every shape as covering the whole raster (the reference the tests compare with).
    whole_raster: bool = false,

    fn init(gpa: std.mem.Allocator, w: u32, h: u32) Error!Filler {
        const partial = try gpa.alloc(f32, w + 2);
        errdefer gpa.free(partial);
        const diff = try gpa.alloc(f32, w + 2);
        return .{ .gpa = gpa, .w = w, .h = h, .partial = partial, .diff = diff, .dirty = .{ .r0 = 0, .r1 = h, .c0 = 0, .c1 = w } };
    }

    fn deinit(f: *Filler) void {
        f.gpa.free(f.partial);
        f.gpa.free(f.diff);
        f.active.deinit(f.gpa);
        f.cross.deinit(f.gpa);
    }

    /// The raster rows and columns that `edges` can reach.
    fn boundsOf(f: *const Filler, edges: []const Edge) Bounds {
        if (f.whole_raster) return .{ .r0 = 0, .r1 = f.h, .c0 = 0, .c1 = f.w };
        var minx: f32 = std.math.inf(f32);
        var maxx: f32 = -std.math.inf(f32);
        var miny: f32 = std.math.inf(f32);
        var maxy: f32 = -std.math.inf(f32);
        for (edges) |e| {
            minx = @min(minx, @min(e.x0, e.x1));
            maxx = @max(maxx, @max(e.x0, e.x1));
            miny = @min(miny, e.y0);
            maxy = @max(maxy, e.y1);
        }
        const wf: f32 = @floatFromInt(f.w);
        const hf: f32 = @floatFromInt(f.h);
        if (!(maxy > 0 and miny < hf and maxx > 0 and minx < wf)) return .{};
        // A span ending exactly on a column edge writes that column's partial, hence the + 1.
        return .{
            .r0 = @intFromFloat(@floor(@max(miny, 0))),
            .r1 = @intFromFloat(@min(@ceil(maxy), hf)),
            .c0 = @intFromFloat(@floor(@max(minx, 0))),
            .c1 = @intFromFloat(@min(@floor(maxx) + 1, wf)),
        };
    }

    /// Fills `cov` (w*h, 0..1) with the coverage of `edges` under `rule` and returns the rows and
    /// columns that may be non-zero in it (everything else is zero).
    fn fill(f: *Filler, edges: []Edge, rule: svg.FillRule, cov: []f32) Error!Bounds {
        const wi: usize = f.w;
        if (!f.dirty.empty()) {
            var r = f.dirty.r0;
            while (r < f.dirty.r1) : (r += 1) @memset(cov[r * wi ..][f.dirty.c0..f.dirty.c1], 0);
        }
        f.dirty = .{};
        if (edges.len == 0) return .{};
        const b = f.boundsOf(edges);
        if (b.empty()) return .{};
        // Clearing the rows and compositing the result touch every pixel of the box; a pixel
        // costs about a quarter of a sub-scanline's edge visit.
        if (b.area() / 4 > f.work_left) return error.TooComplex;
        f.work_left -= b.area() / 4;
        f.dirty = b;
        std.sort.pdq(Edge, edges, {}, edgeLess);
        f.active.clearRetainingCapacity();
        var next: usize = 0;
        const wf: f32 = @floatFromInt(f.w);
        const wt: f32 = 1.0 / @as(f32, sub_n);
        var row: u32 = b.r0;
        while (row < b.r1) : (row += 1) {
            const rtop: f32 = @floatFromInt(row);
            const rbot = rtop + 1;
            while (next < edges.len and edges[next].y0 < rbot) : (next += 1) {
                try f.active.append(f.gpa, @intCast(next));
            }
            // Drop finished edges.
            var keep: usize = 0;
            for (f.active.items) |ei| {
                if (edges[ei].y1 > rtop) {
                    f.active.items[keep] = ei;
                    keep += 1;
                }
            }
            f.active.shrinkRetainingCapacity(keep);
            if (keep == 0) {
                if (next >= edges.len) break;
                continue;
            }
            const row_work = @as(u64, keep) * sub_n;
            if (row_work > f.work_left) return error.TooComplex;
            f.work_left -= row_work;
            const cend = @min(b.c1 + 2, wi + 2);
            @memset(f.partial[b.c0..cend], 0);
            @memset(f.diff[b.c0..cend], 0);
            var any = false;
            for (0..sub_n) |k| {
                const y = rtop + (@as(f32, @floatFromInt(k)) + 0.5) * wt;
                f.cross.clearRetainingCapacity();
                for (f.active.items) |ei| {
                    const e = edges[ei];
                    if (y < e.y0 or y >= e.y1) continue;
                    const x = e.x0 + (y - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0);
                    try f.cross.append(f.gpa, .{ .x = x, .dir = e.dir });
                }
                const cs = f.cross.items;
                if (cs.len < 2) continue;
                if (cs.len <= small_sort) {
                    var i: usize = 1;
                    while (i < cs.len) : (i += 1) {
                        const v = cs[i];
                        var j = i;
                        while (j > 0 and cs[j - 1].x > v.x) : (j -= 1) {
                            cs[j] = cs[j - 1];
                            f.sort_ops += 1;
                        }
                        cs[j] = v;
                    }
                } else {
                    // Stable, like the insertion sort, so crossings at one x keep their order
                    // and the coverage is bit-identical either way.
                    std.sort.block(Crossing, cs, &f.sort_ops, crossingLess);
                }
                var wind: i32 = 0;
                var start: f32 = 0;
                var inside = false;
                for (cs) |c| {
                    wind += c.dir;
                    const now = switch (rule) {
                        .nonzero => wind != 0,
                        .evenodd => @mod(wind, 2) != 0,
                    };
                    if (now and !inside) {
                        start = c.x;
                    } else if (!now and inside) {
                        f.span(start, c.x, wf, wt);
                        any = true;
                    }
                    inside = now;
                }
            }
            if (!any) continue;
            var acc: f32 = 0;
            const out = cov[@as(usize, row) * f.w ..][b.c0..b.c1];
            for (out, b.c0..) |*o, x| {
                acc += f.diff[x];
                o.* = std.math.clamp(f.partial[x] + acc, 0, 1);
            }
        }
        return b;
    }

    fn span(f: *Filler, xa_in: f32, xb_in: f32, wf: f32, wt: f32) void {
        const xa = @max(xa_in, 0);
        const xb = @min(xb_in, wf);
        if (xb <= xa) return;
        const ia: usize = @intFromFloat(@floor(xa));
        const ib: usize = @intFromFloat(@floor(xb));
        if (ia == ib) {
            f.partial[ia] += (xb - xa) * wt;
        } else {
            f.partial[ia] += (@as(f32, @floatFromInt(ia + 1)) - xa) * wt;
            f.diff[ia + 1] += wt;
            f.diff[ib] -= wt;
            f.partial[ib] += (xb - @as(f32, @floatFromInt(ib))) * wt;
        }
    }
};

// ---- flattening -----------------------------------------------------------------------

const Sub = struct { start: u32, len: u32, closed: bool };

const Flat = struct {
    pts: std.ArrayList(P) = .empty,
    subs: std.ArrayList(Sub) = .empty,
    /// Points still allowed for this render (`max_flat_points`); `clear` keeps it.
    left: usize = max_flat_points,

    fn push(f: *Flat, gpa: std.mem.Allocator, p: P) Error!void {
        if (f.left == 0) return error.TooComplex;
        f.left -= 1;
        try f.pts.append(gpa, p);
    }

    fn deinit(f: *Flat, gpa: std.mem.Allocator) void {
        f.pts.deinit(gpa);
        f.subs.deinit(gpa);
    }

    fn clear(f: *Flat) void {
        f.pts.clearRetainingCapacity();
        f.subs.clearRetainingCapacity();
    }
};

/// Flattens the shape's path (user space) into polylines; cubic segment counts follow the
/// curve's second differences, so tighter curves and larger scales get more segments.
fn flatten(gpa: std.mem.Allocator, sh: *const svg.Shape, tol: f32, out: *Flat) Error!void {
    out.clear();
    var pi: usize = 0;
    var cur: P = .{ 0, 0 };
    var start_idx: ?usize = null; // index in out.pts where the current sub starts
    var drawn = false;
    const finish = struct {
        fn run(o: *Flat, g: std.mem.Allocator, s: *?usize, d: *bool, closed: bool) Error!void {
            if (s.*) |st| {
                if (d.*) try o.subs.append(g, .{ .start = @intCast(st), .len = @intCast(o.pts.items.len - st), .closed = closed });
                if (!d.*) o.pts.shrinkRetainingCapacity(st);
            }
            s.* = null;
            d.* = false;
        }
    }.run;
    for (sh.verbs) |v| switch (v) {
        .move => {
            try finish(out, gpa, &start_idx, &drawn, false);
            cur = sh.pts[pi];
            pi += 1;
            start_idx = out.pts.items.len;
            try out.push(gpa, cur);
        },
        .line => {
            if (start_idx == null) {
                start_idx = out.pts.items.len;
                try out.push(gpa, cur);
            }
            cur = sh.pts[pi];
            pi += 1;
            try out.push(gpa, cur);
            drawn = true;
        },
        .cubic => {
            if (start_idx == null) {
                start_idx = out.pts.items.len;
                try out.push(gpa, cur);
            }
            const c1 = sh.pts[pi];
            const c2 = sh.pts[pi + 1];
            const e = sh.pts[pi + 2];
            pi += 3;
            const ddx1 = cur[0] - 2 * c1[0] + c2[0];
            const ddy1 = cur[1] - 2 * c1[1] + c2[1];
            const ddx2 = c1[0] - 2 * c2[0] + e[0];
            const ddy2 = c1[1] - 2 * c2[1] + e[1];
            const dd = @max(std.math.hypot(ddx1, ddy1), std.math.hypot(ddx2, ddy2));
            const nf = @ceil(@sqrt(0.75 * dd / tol));
            const n: usize = if (std.math.isFinite(nf)) @intFromFloat(std.math.clamp(nf, 1, 400)) else 1;
            var k: usize = 1;
            while (k < n) : (k += 1) {
                const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
                const mt = 1 - t;
                const a = mt * mt * mt;
                const b = 3 * mt * mt * t;
                const c = 3 * mt * t * t;
                const d = t * t * t;
                try out.push(gpa, .{
                    a * cur[0] + b * c1[0] + c * c2[0] + d * e[0],
                    a * cur[1] + b * c1[1] + c * c2[1] + d * e[1],
                });
            }
            try out.push(gpa, e);
            cur = e;
            drawn = true;
        },
        .close => {
            if (start_idx) |st| {
                const first = out.pts.items[st];
                drawn = true;
                try finish(out, gpa, &start_idx, &drawn, true);
                cur = first;
                // A closed subpath of a single point ("M x y z") is kept as a dot.
            }
        },
    };
    try finish(out, gpa, &start_idx, &drawn, false);
}

// ---- stroking -------------------------------------------------------------------------

fn sub2(a: P, b: P) P {
    return .{ a[0] - b[0], a[1] - b[1] };
}
fn len2(a: P) f32 {
    return std.math.hypot(a[0], a[1]);
}
/// The unit vector along `v`. Two huge finite coordinates can differ by more than f32 holds,
/// which makes the direction NaN and every angle derived from it meaningless: refuse.
fn unit(v: P) Error!P {
    const l = len2(v);
    const d: P = .{ v[0] / l, v[1] / l };
    if (!(std.math.isFinite(d[0]) and std.math.isFinite(d[1]))) return error.TooComplex;
    return d;
}
fn perp(d: P) P {
    return .{ -d[1], d[0] };
}

/// Appends an arc around `c` of radius `r` from unit vector `un0` through signed angle `delta`
/// (steps of at most `step` radians), excluding the start point, including the end point.
fn arcPoints(pts: *std.ArrayList(P), gpa: std.mem.Allocator, c: P, un0: P, delta: f32, r: f32, step: f32) Error!void {
    const steps = @ceil(@abs(delta) / step);
    const n: usize = if (std.math.isFinite(steps)) @max(1, @min(256, @as(usize, @intFromFloat(steps)))) else 1;
    var k: usize = 1;
    const a0 = std.math.atan2(un0[1], un0[0]);
    while (k <= n) : (k += 1) {
        const a = a0 + delta * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        try pts.append(gpa, .{ c[0] + r * @cos(a), c[1] + r * @sin(a) });
    }
}

const Stroker = struct {
    gpa: std.mem.Allocator,
    edges: *EdgeList,
    hw: f32,
    cap: svg.Cap,
    join: svg.Join,
    miter_limit: f32,
    step: f32,
    scratch: std.ArrayList(P) = .empty,

    fn deinit(s: *Stroker) void {
        s.scratch.deinit(s.gpa);
    }

    fn emit(s: *Stroker) void {
        s.edges.poly(s.scratch.items);
        s.scratch.clearRetainingCapacity();
    }

    fn circle(s: *Stroker, c: P) Error!void {
        s.scratch.clearRetainingCapacity();
        try s.scratch.append(s.gpa, .{ c[0] + s.hw, c[1] });
        try arcPoints(&s.scratch, s.gpa, c, .{ 1, 0 }, 2 * std.math.pi, s.hw, s.step);
        s.emit();
    }

    fn dot(s: *Stroker, c: P) Error!void {
        switch (s.cap) {
            .butt => {},
            .round => try s.circle(c),
            .square => {
                s.scratch.clearRetainingCapacity();
                const h = s.hw;
                try s.scratch.appendSlice(s.gpa, &.{ .{ c[0] - h, c[1] - h }, .{ c[0] + h, c[1] - h }, .{ c[0] + h, c[1] + h }, .{ c[0] - h, c[1] + h } });
                s.emit();
            },
        }
    }

    fn capAt(s: *Stroker, v: P, d: P) Error!void {
        // `d` points outwards from the path end.
        const n = perp(d);
        const h = s.hw;
        s.scratch.clearRetainingCapacity();
        switch (s.cap) {
            .butt => return,
            .square => {
                try s.scratch.appendSlice(s.gpa, &.{
                    .{ v[0] + n[0] * h, v[1] + n[1] * h },
                    .{ v[0] + n[0] * h + d[0] * h, v[1] + n[1] * h + d[1] * h },
                    .{ v[0] - n[0] * h + d[0] * h, v[1] - n[1] * h + d[1] * h },
                    .{ v[0] - n[0] * h, v[1] - n[1] * h },
                });
            },
            .round => {
                try s.scratch.append(s.gpa, .{ v[0] + n[0] * h, v[1] + n[1] * h });
                try arcPoints(&s.scratch, s.gpa, v, n, -std.math.pi, h, s.step);
            },
        }
        s.emit();
    }

    fn joinAt(s: *Stroker, v: P, d0: P, d1: P) Error!void {
        const cross = d0[0] * d1[1] - d0[1] * d1[0];
        const dotp = d0[0] * d1[0] + d0[1] * d1[1];
        if (@abs(cross) < 1e-4 and dotp > 0) return; // straight on
        const sg: f32 = if (cross > 0) -1 else 1;
        const un0: P = .{ perp(d0)[0] * sg, perp(d0)[1] * sg };
        const un1: P = .{ perp(d1)[0] * sg, perp(d1)[1] * sg };
        const h = s.hw;
        const a: P = .{ v[0] + un0[0] * h, v[1] + un0[1] * h };
        const b: P = .{ v[0] + un1[0] * h, v[1] + un1[1] * h };
        s.scratch.clearRetainingCapacity();
        switch (s.join) {
            .bevel => try s.scratch.appendSlice(s.gpa, &.{ v, a, b }),
            .miter => {
                const c1 = un0[0] * un1[0] + un0[1] * un1[1]; // cos of the turn angle
                // 1/sin(theta/2) with theta = pi - turn: sqrt(2/(1+cos(turn)))
                const ratio = if (1 + c1 > 1e-6) @sqrt(2 / (1 + c1)) else std.math.inf(f32);
                if (ratio <= s.miter_limit) {
                    const k = h / (1 + c1);
                    const m: P = .{ v[0] + (un0[0] + un1[0]) * k, v[1] + (un0[1] + un1[1]) * k };
                    try s.scratch.appendSlice(s.gpa, &.{ v, a, m, b });
                } else {
                    try s.scratch.appendSlice(s.gpa, &.{ v, a, b });
                }
            },
            .round => {
                const delta = std.math.atan2(un0[0] * un1[1] - un0[1] * un1[0], un0[0] * un1[0] + un0[1] * un1[1]);
                try s.scratch.append(s.gpa, v);
                try s.scratch.append(s.gpa, a);
                try arcPoints(&s.scratch, s.gpa, v, un0, delta, h, s.step);
            },
        }
        s.emit();
    }

    fn segment(s: *Stroker, a: P, b: P, d: P) Error!void {
        const n = perp(d);
        const h = s.hw;
        s.scratch.clearRetainingCapacity();
        try s.scratch.appendSlice(s.gpa, &.{
            .{ a[0] + n[0] * h, a[1] + n[1] * h },
            .{ b[0] + n[0] * h, b[1] + n[1] * h },
            .{ b[0] - n[0] * h, b[1] - n[1] * h },
            .{ a[0] - n[0] * h, a[1] - n[1] * h },
        });
        s.emit();
    }

    /// Strokes one polyline (`pts` with consecutive duplicates already removed).
    fn path(s: *Stroker, pts: []const P, closed: bool) Error!void {
        const n = pts.len;
        if (n == 1) return s.dot(pts[0]);
        const nseg = if (closed) n else n - 1;
        var i: usize = 0;
        while (i < nseg) : (i += 1) {
            const a = pts[i];
            const b = pts[(i + 1) % n];
            try s.segment(a, b, try unit(sub2(b, a)));
        }
        // Joins.
        const jstart: usize = if (closed) 0 else 1;
        const jend: usize = if (closed) n else n - 1;
        var j = jstart;
        while (j < jend) : (j += 1) {
            const prev = pts[(j + n - 1) % n];
            const v = pts[j];
            const nx = pts[(j + 1) % n];
            try s.joinAt(v, try unit(sub2(v, prev)), try unit(sub2(nx, v)));
        }
        if (!closed) {
            const d0 = try unit(sub2(pts[1], pts[0]));
            try s.capAt(pts[0], .{ -d0[0], -d0[1] });
            try s.capAt(pts[n - 1], try unit(sub2(pts[n - 1], pts[n - 2])));
        }
    }
};

// ---- painting -------------------------------------------------------------------------

pub const Mode = enum { mono, color };

const Canvas = struct {
    gpa: std.mem.Allocator,
    w: u32,
    h: u32,
    mode: Mode,
    current: svg.Rgba,
    doc: *const svg.Doc,
    /// Device <- viewBox.
    base: svg.Affine,
    edges: EdgeList,
    flat: Flat = .{},
    filler: Filler,
    cov: []f32,
    /// mono: alpha (w*h). color: premultiplied r,g,b,a (w*h*4).
    acc: []f32,
    pts_scratch: std.ArrayList(P) = .empty,

    fn deinit(c: *Canvas) void {
        c.edges.edges.deinit(c.gpa);
        c.flat.deinit(c.gpa);
        c.filler.deinit();
        c.gpa.free(c.cov);
        c.gpa.free(c.acc);
        c.pts_scratch.deinit(c.gpa);
    }

    fn paintShape(c: *Canvas, sh: *const svg.Shape) Error!void {
        const m = c.base.mul(sh.xf);
        const scale = m.maxScale();
        if (!(scale > 1e-9) or !std.math.isFinite(scale)) return;
        const tol = flat_tol / scale;
        try flatten(c.gpa, sh, tol, &c.flat);

        if (sh.fill != .none and sh.fill_alpha > 0) {
            c.edges.clear();
            c.edges.m = m;
            c.edges.normalize = false;
            for (c.flat.subs.items) |sub| {
                if (sub.len < 3) continue;
                c.edges.poly(c.flat.pts.items[sub.start..][0..sub.len]);
            }
            if (c.edges.failed) return error.TooComplex;
            const b = try c.filler.fill(c.edges.edges.items, sh.rule, c.cov);
            try c.composite(sh, sh.fill, sh.fill_alpha, m, b);
        }
        if (sh.stroke != .none and sh.stroke_alpha > 0 and sh.stroke_width > 0) {
            c.edges.clear();
            c.edges.m = m;
            c.edges.normalize = true;
            const hw = sh.stroke_width / 2;
            const ratio = @min(tol * 0.25 / hw, 1); // finer than curves: round caps and dots are small
            const step = @max(0.05, 2 * std.math.acos(1 - ratio));
            var st: Stroker = .{ .gpa = c.gpa, .edges = &c.edges, .hw = hw, .cap = sh.cap, .join = sh.join, .miter_limit = sh.miter_limit, .step = @min(step, std.math.pi / 2.0) };
            defer st.deinit();
            for (c.flat.subs.items) |sub| {
                const raw = c.flat.pts.items[sub.start..][0..sub.len];
                c.pts_scratch.clearRetainingCapacity();
                for (raw) |p| {
                    if (c.pts_scratch.items.len > 0) {
                        const last = c.pts_scratch.items[c.pts_scratch.items.len - 1];
                        if (@abs(last[0] - p[0]) < 1e-6 and @abs(last[1] - p[1]) < 1e-6) continue;
                    }
                    try c.pts_scratch.append(c.gpa, p);
                }
                var closed = sub.closed;
                if (closed and c.pts_scratch.items.len > 1) {
                    const a = c.pts_scratch.items[0];
                    const b = c.pts_scratch.items[c.pts_scratch.items.len - 1];
                    if (@abs(a[0] - b[0]) < 1e-6 and @abs(a[1] - b[1]) < 1e-6) _ = c.pts_scratch.pop();
                }
                if (c.pts_scratch.items.len == 0) continue;
                if (c.pts_scratch.items.len == 1) closed = false;
                try st.path(c.pts_scratch.items, closed);
                if (c.edges.failed) return error.TooComplex;
            }
            const b = try c.filler.fill(c.edges.edges.items, .nonzero, c.cov);
            try c.composite(sh, sh.stroke, sh.stroke_alpha, m, b);
        }
    }

    /// Blends the coverage in `b` (everything outside it is zero) into the accumulator.
    fn composite(c: *Canvas, sh: *const svg.Shape, paint: svg.Paint, alpha: f32, m: svg.Affine, b: Bounds) Error!void {
        if (b.empty()) return;
        const wi: usize = c.w;
        if (c.mode == .mono) {
            var a = alpha;
            if (paint == .color) a *= @as(f32, @floatFromInt(paint.color.a)) / 255.0;
            var y: usize = b.r0;
            while (y < b.r1) : (y += 1) {
                const cvs = c.cov[y * wi ..][b.c0..b.c1];
                const dsts = c.acc[y * wi ..][b.c0..b.c1];
                for (cvs, dsts) |cv, *dst| {
                    const s = cv * a;
                    dst.* = dst.* + s - dst.* * s;
                }
            }
            return;
        }
        switch (paint) {
            .none => {},
            .current_color, .color => {
                const col = if (paint == .color) paint.color else c.current;
                const a = alpha * @as(f32, @floatFromInt(col.a)) / 255.0;
                const r = @as(f32, @floatFromInt(col.r)) / 255.0;
                const g = @as(f32, @floatFromInt(col.g)) / 255.0;
                const bl = @as(f32, @floatFromInt(col.b)) / 255.0;
                var y: usize = b.r0;
                while (y < b.r1) : (y += 1) {
                    for (b.c0..b.c1) |x| {
                        const i = y * wi + x;
                        const s = c.cov[i] * a;
                        if (s <= 0) continue;
                        const d = c.acc[i * 4 ..][0..4];
                        const k = 1 - s;
                        d[0] = r * s + d[0] * k;
                        d[1] = g * s + d[1] * k;
                        d[2] = bl * s + d[2] * k;
                        d[3] = s + d[3] * k;
                    }
                }
            },
            .gradient => |gi| try c.compositeGradient(sh, c.doc.gradients[gi], alpha, m, b),
        }
    }

    fn compositeGradient(c: *Canvas, sh: *const svg.Shape, g: svg.Gradient, alpha: f32, m: svg.Affine, bd: Bounds) Error!void {
        if (g.stops.len == 0) return;
        // Pixel -> shape user space -> gradient space.
        const inv = m.invert() orelse return;
        var to_grad: svg.Affine = .{};
        if (g.bbox_units) {
            var minx: f32 = std.math.inf(f32);
            var miny: f32 = std.math.inf(f32);
            var maxx: f32 = -std.math.inf(f32);
            var maxy: f32 = -std.math.inf(f32);
            for (sh.pts) |p| {
                minx = @min(minx, p[0]);
                maxx = @max(maxx, p[0]);
                miny = @min(miny, p[1]);
                maxy = @max(maxy, p[1]);
            }
            const bw = maxx - minx;
            const bh = maxy - miny;
            if (!(bw > 0 and bh > 0)) return;
            // user -> unit square
            to_grad = (svg.Affine{ .a = 1 / bw, .d = 1 / bh, .e = -minx / bw, .f = -miny / bh });
        }
        // gradientTransform maps gradient space to the (user or bbox) space, so invert it.
        const gi = g.xf.invert() orelse return;
        to_grad = gi.mul(to_grad);
        const full = to_grad.mul(inv);
        for (bd.r0..bd.r1) |y| {
            for (bd.c0..bd.c1) |x| {
                const i = y * c.w + x;
                const cv = c.cov[i];
                if (cv <= 0) continue;
                const q = full.apply(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
                var t: f32 = undefined;
                if (g.radial) {
                    t = std.math.hypot(q[0] - g.x1, q[1] - g.y1) / @max(g.x2, 1e-9);
                } else {
                    const vx = g.x2 - g.x1;
                    const vy = g.y2 - g.y1;
                    const vv = vx * vx + vy * vy;
                    t = if (vv > 0) ((q[0] - g.x1) * vx + (q[1] - g.y1) * vy) / vv else 0;
                }
                const col = gradientColor(g.stops, std.math.clamp(t, 0, 1));
                const s = cv * alpha * col[3];
                if (s <= 0) continue;
                const d = c.acc[i * 4 ..][0..4];
                const k = 1 - s;
                d[0] = col[0] * s + d[0] * k;
                d[1] = col[1] * s + d[1] * k;
                d[2] = col[2] * s + d[2] * k;
                d[3] = s + d[3] * k;
            }
        }
    }
};

/// Colour (straight r,g,b,a in 0..1) at `t` in 0..1.
pub fn gradientColor(stops: []const svg.Stop, t: f32) [4]f32 {
    const f = struct {
        fn col(s: svg.Rgba) [4]f32 {
            return .{
                @as(f32, @floatFromInt(s.r)) / 255.0,
                @as(f32, @floatFromInt(s.g)) / 255.0,
                @as(f32, @floatFromInt(s.b)) / 255.0,
                @as(f32, @floatFromInt(s.a)) / 255.0,
            };
        }
    };
    if (t <= stops[0].offset) return f.col(stops[0].color);
    for (stops[1..], 1..) |s1, i| {
        const s0 = stops[i - 1];
        if (t <= s1.offset) {
            const span = s1.offset - s0.offset;
            const u = if (span > 0) (t - s0.offset) / span else 1;
            const a = f.col(s0.color);
            const b = f.col(s1.color);
            return .{ a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u, a[3] + (b[3] - a[3]) * u };
        }
    }
    return f.col(stops[stops.len - 1].color);
}

fn canvasInit(gpa: std.mem.Allocator, doc: *const svg.Doc, w: u32, h: u32, mode: Mode, current: svg.Rgba) Error!Canvas {
    if (w == 0 or h == 0 or w > max_side or h > max_side) return error.TooLarge;
    const n = @as(usize, w) * h;
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const s = @min(wf / doc.vb_w, hf / doc.vb_h);
    const base: svg.Affine = .{
        .a = s,
        .d = s,
        .e = (wf - doc.vb_w * s) / 2 - doc.vb_x * s,
        .f = (hf - doc.vb_h * s) / 2 - doc.vb_y * s,
    };
    const cov = try gpa.alloc(f32, n);
    errdefer gpa.free(cov);
    const acc = try gpa.alloc(f32, if (mode == .mono) n else n * 4);
    errdefer gpa.free(acc);
    @memset(acc, 0);
    var filler = try Filler.init(gpa, w, h);
    errdefer filler.deinit();
    return .{
        .gpa = gpa,
        .w = w,
        .h = h,
        .mode = mode,
        .current = current,
        .doc = doc,
        .base = base,
        .edges = .{ .gpa = gpa },
        .filler = filler,
        .cov = cov,
        .acc = acc,
    };
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

/// Renders `doc` as an A8 coverage mask of `w` x `h` pixels (caller frees with `gpa`).
pub fn renderMask(gpa: std.mem.Allocator, doc: *const svg.Doc, w: u32, h: u32) Error![]u8 {
    var c = try canvasInit(gpa, doc, w, h, .mono, .{});
    defer c.deinit();
    for (doc.shapes) |*sh| try c.paintShape(sh);
    const out = try gpa.alloc(u8, c.acc.len);
    for (out, c.acc) |*o, a| o.* = toByte(a);
    return out;
}

/// Renders `doc` in colour as premultiplied RGBA8 (`w * h * 4` bytes, caller frees with
/// `gpa`). `current` replaces `currentColor`.
pub fn renderRgba(gpa: std.mem.Allocator, doc: *const svg.Doc, w: u32, h: u32, current: svg.Rgba) Error![]u8 {
    var c = try canvasInit(gpa, doc, w, h, .color, current);
    defer c.deinit();
    for (doc.shapes) |*sh| try c.paintShape(sh);
    const out = try gpa.alloc(u8, c.acc.len);
    for (out, c.acc) |*o, a| o.* = toByte(a);
    return out;
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

fn maskOf(src: []const u8, w: u32, h: u32) ![]u8 {
    var d = try svg.parse(testing.allocator, src);
    defer d.deinit();
    return renderMask(testing.allocator, &d, w, h);
}

fn sum(mask: []const u8) f64 {
    var s: f64 = 0;
    for (mask) |v| s += @as(f64, @floatFromInt(v)) / 255.0;
    return s;
}

test "a filled square's coverage is its area, with exact partial pixels" {
    // 10x10 viewBox rendered at 10x10 px: a 4.5 x 3.25 rect at (1.25, 2.5).
    const m = try maskOf("<svg viewBox=\"0 0 10 10\"><rect x=\"1.25\" y=\"2.5\" width=\"4.5\" height=\"3.25\"/></svg>", 10, 10);
    defer testing.allocator.free(m);
    try testing.expectApproxEqAbs(@as(f64, 4.5 * 3.25), sum(m), 0.1);
    // A pixel fully inside is 255, one outside is 0, the left edge pixel is 75%.
    try testing.expectEqual(@as(u8, 255), m[3 * 10 + 3]);
    try testing.expectEqual(@as(u8, 0), m[0]);
    try testing.expectApproxEqAbs(@as(f32, 0.75 * 255), @as(f32, @floatFromInt(m[3 * 10 + 1])), 2);
}

test "pixel-aligned shapes are crisp, scaling keeps the area" {
    const m = try maskOf("<svg viewBox=\"0 0 24 24\"><rect x=\"6\" y=\"6\" width=\"12\" height=\"12\"/></svg>", 24, 24);
    defer testing.allocator.free(m);
    try testing.expectApproxEqAbs(@as(f64, 144), sum(m), 0.01);
    for (m) |v| try testing.expect(v == 0 or v == 255);
    const m2 = try maskOf("<svg viewBox=\"0 0 24 24\"><rect x=\"6\" y=\"6\" width=\"12\" height=\"12\"/></svg>", 37, 37);
    defer testing.allocator.free(m2);
    const k = 37.0 / 24.0;
    try testing.expectApproxEqAbs(144.0 * k * k, sum(m2), 1.0);
}

test "a circle's coverage is pi r^2" {
    const m = try maskOf("<svg viewBox=\"0 0 100 100\"><circle cx=\"50\" cy=\"50\" r=\"40\"/></svg>", 100, 100);
    defer testing.allocator.free(m);
    try testing.expectApproxEqRel(@as(f64, std.math.pi * 1600), sum(m), 0.003);
    // Rendered at 3x, the area is 9x.
    const m3 = try maskOf("<svg viewBox=\"0 0 100 100\"><circle cx=\"50\" cy=\"50\" r=\"40\"/></svg>", 300, 300);
    defer testing.allocator.free(m3);
    try testing.expectApproxEqRel(@as(f64, std.math.pi * 1600 * 9), sum(m3), 0.003);
}

test "a stroked line with round caps: length*width + pi r^2" {
    const m = try maskOf("<svg viewBox=\"0 0 40 40\"><path d=\"M8 20H32\" stroke=\"#000\" stroke-width=\"6\" stroke-linecap=\"round\" fill=\"none\"/></svg>", 40, 40);
    defer testing.allocator.free(m);
    try testing.expectApproxEqRel(@as(f64, 24 * 6 + std.math.pi * 9), sum(m), 0.006);
    const b = try maskOf("<svg viewBox=\"0 0 40 40\"><path d=\"M8 20H32\" stroke=\"#000\" stroke-width=\"6\" fill=\"none\"/></svg>", 40, 40);
    defer testing.allocator.free(b);
    try testing.expectApproxEqRel(@as(f64, 24 * 6), sum(b), 0.006); // butt
    const sq = try maskOf("<svg viewBox=\"0 0 40 40\"><path d=\"M8 20H32\" stroke=\"#000\" stroke-width=\"6\" stroke-linecap=\"square\" fill=\"none\"/></svg>", 40, 40);
    defer testing.allocator.free(sq);
    try testing.expectApproxEqRel(@as(f64, 30 * 6), sum(sq), 0.006);
}

test "a zero-length round-capped line is a dot (Lucide dots)" {
    const m = try maskOf("<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"#000\" stroke-width=\"2\" stroke-linecap=\"round\"><path d=\"M12 12h.01\"/></svg>", 48, 48);
    defer testing.allocator.free(m);
    // radius 1 unit = 2 px
    try testing.expectApproxEqRel(@as(f64, std.math.pi * 4), sum(m), 0.03);
}

test "closed stroked square: joins" {
    // A 20x20 square outline, width 4: miter = ring of area 24*24 - 16*16; round corners lose
    // (4 - pi) * r^2 with r = 2; bevel loses 2 * (r^2) / ... = 4 * r^2/2 = 8.
    const base = "<svg viewBox=\"0 0 40 40\"><rect x=\"10\" y=\"10\" width=\"20\" height=\"20\" fill=\"none\" stroke=\"#000\" stroke-width=\"4\" stroke-linejoin=\"{s}\"/></svg>";
    var buf: [256]u8 = undefined;
    const ring: f64 = 24 * 24 - 16 * 16;
    const expect = [_]struct { []const u8, f64 }{
        .{ "miter", ring },
        .{ "round", ring - (4 - std.math.pi) * 4 },
        .{ "bevel", ring - 4 * 2 },
    };
    for (expect) |e| {
        const src = try std.fmt.bufPrint(&buf, base, .{e[0]});
        const m = try maskOf(src, 40, 40);
        defer testing.allocator.free(m);
        try testing.expectApproxEqAbs(e[1], sum(m), 1.2);
    }
}

test "miter limit turns sharp miters into bevels" {
    const sharp = "<svg viewBox=\"0 0 40 40\"><path d=\"M5 30L20 10L35 30\" fill=\"none\" stroke=\"#000\" stroke-width=\"4\" stroke-miterlimit=\"{d}\"/></svg>";
    var b1: [200]u8 = undefined;
    var b2: [200]u8 = undefined;
    const lo = try maskOf(try std.fmt.bufPrint(&b1, sharp, .{1}), 40, 40);
    defer testing.allocator.free(lo);
    const hi = try maskOf(try std.fmt.bufPrint(&b2, sharp, .{10}), 40, 40);
    defer testing.allocator.free(hi);
    try testing.expect(sum(hi) > sum(lo) + 3);
}

test "even-odd versus non-zero" {
    // Two nested squares drawn in the same direction: non-zero fills the hole, even-odd keeps it.
    const d = "M2 2h16v16h-16z M6 6h8v8h-8z";
    var buf: [256]u8 = undefined;
    const nz = try maskOf(try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 20 20\"><path d=\"{s}\"/></svg>", .{d}), 20, 20);
    defer testing.allocator.free(nz);
    try testing.expectApproxEqAbs(@as(f64, 256), sum(nz), 0.01);
    const eo = try maskOf(try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 20 20\"><path fill-rule=\"evenodd\" d=\"{s}\"/></svg>", .{d}), 20, 20);
    defer testing.allocator.free(eo);
    try testing.expectApproxEqAbs(@as(f64, 256 - 64), sum(eo), 0.01);
    // Opposite direction hole is a hole under non-zero as well.
    const nz2 = try maskOf("<svg viewBox=\"0 0 20 20\"><path d=\"M2 2h16v16h-16z M6 6v8h8v-8z\"/></svg>", 20, 20);
    defer testing.allocator.free(nz2);
    try testing.expectApproxEqAbs(@as(f64, 256 - 64), sum(nz2), 0.01);
}

test "transforms move and scale the ink" {
    const m = try maskOf("<svg viewBox=\"0 0 20 20\"><rect width=\"4\" height=\"4\" transform=\"translate(10 10) scale(2)\"/></svg>", 20, 20);
    defer testing.allocator.free(m);
    try testing.expectApproxEqAbs(@as(f64, 64), sum(m), 0.01);
    try testing.expectEqual(@as(u8, 255), m[12 * 20 + 12]);
    try testing.expectEqual(@as(u8, 0), m[9 * 20 + 9]);
    // Non-uniform scale also scales the stroke non-uniformly: a horizontal line of width 2
    // under scale(1, 3) is 6 thick.
    const s = try maskOf("<svg viewBox=\"0 0 20 20\"><path d=\"M2 5H18\" stroke=\"#000\" stroke-width=\"2\" transform=\"scale(1 3)\"/></svg>", 20, 20);
    defer testing.allocator.free(s);
    try testing.expectApproxEqAbs(@as(f64, 16 * 6), sum(s), 0.5);
}

test "opacity scales mono ink; fill:none shapes paint nothing" {
    const m = try maskOf("<svg viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\" opacity=\".5\"/><rect width=\"10\" height=\"10\" fill=\"none\"/></svg>", 10, 10);
    defer testing.allocator.free(m);
    try testing.expectApproxEqAbs(@as(f64, 50), sum(m), 0.5);
}

test "the viewBox is contained and centred in a non-matching box" {
    // 10x10 square viewBox into 20x10: scaled 1x, centred horizontally (x offset 5).
    const m = try maskOf("<svg viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\"/></svg>", 20, 10);
    defer testing.allocator.free(m);
    try testing.expectEqual(@as(u8, 0), m[4]);
    try testing.expectEqual(@as(u8, 255), m[5]);
    try testing.expectEqual(@as(u8, 255), m[14]);
    try testing.expectEqual(@as(u8, 0), m[15]);
}

test "arcs rasterise to the right shape (flags and sweep)" {
    // Lucide-ish half disc: two arcs; area of a semicircle of radius 8 is 32 pi.
    const m = try maskOf("<svg viewBox=\"0 0 20 20\"><path d=\"M2 10a8 8 0 0 1 16 0z\"/></svg>", 80, 80);
    defer testing.allocator.free(m);
    try testing.expectApproxEqRel(@as(f64, 32 * std.math.pi * 16), sum(m), 0.004);
    // Upper half: pixels above the chord are inked, below are not.
    try testing.expectEqual(@as(u8, 255), m[30 * 80 + 40]);
    try testing.expectEqual(@as(u8, 0), m[50 * 80 + 40]);
    // Large arc: 3/4 of a disc plus nothing else.
    const l = try maskOf("<svg viewBox=\"0 0 20 20\"><path d=\"M18 10A8 8 0 1 1 10 2L10 10z\"/></svg>", 80, 80);
    defer testing.allocator.free(l);
    try testing.expectApproxEqRel(@as(f64, 0.75 * 64 * std.math.pi * 16), sum(l), 0.006);
}

test "colour mode: flat colours, currentColor and a vertical gradient" {
    var d = try svg.parse(testing.allocator,
        \\<svg viewBox="0 0 10 10"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="10" gradientUnits="userSpaceOnUse">
        \\<stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient></defs>
        \\<rect width="5" height="10" fill="#00ff00"/><rect x="5" width="5" height="10" fill="url(#g)"/></svg>
    );
    defer d.deinit();
    const px = try renderRgba(testing.allocator, &d, 10, 10, .{ .r = 9, .g = 9, .b = 9 });
    defer testing.allocator.free(px);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, px[(5 * 10 + 2) * 4 ..][0..4]);
    // Gradient top is red-ish, bottom blue-ish.
    const top = px[(0 * 10 + 7) * 4 ..][0..4];
    const bot = px[(9 * 10 + 7) * 4 ..][0..4];
    try testing.expect(top[0] > 230 and top[2] < 25 and top[3] == 255);
    try testing.expect(bot[2] > 230 and bot[0] < 25);

    var d2 = try svg.parse(testing.allocator, "<svg viewBox=\"0 0 4 4\"><rect width=\"4\" height=\"4\" fill=\"currentColor\" fill-opacity=\".5\"/></svg>");
    defer d2.deinit();
    const p2 = try renderRgba(testing.allocator, &d2, 4, 4, .{ .r = 200, .g = 100, .b = 0 });
    defer testing.allocator.free(p2);
    // premultiplied: rgb = colour * alpha(0.5)
    try testing.expectEqualSlices(u8, &.{ 100, 50, 0, 128 }, p2[0..4]);
}

test "gradient colour stops" {
    const stops = [_]svg.Stop{ .{ .offset = 0.2, .color = .{ .r = 0 } }, .{ .offset = 0.6, .color = .{ .r = 200 } } };
    try testing.expectEqual(@as(f32, 0), gradientColor(&stops, 0.0)[0]);
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 255.0), gradientColor(&stops, 0.4)[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), gradientColor(&stops, 1.0)[0], 1e-5);
}

test "sizes: zero and oversized rasters are refused; degenerate shapes do not hang" {
    var d = try svg.parse(testing.allocator, "<svg viewBox=\"0 0 4 4\"><path d=\"M1 1L1 1\" stroke=\"#000\"/><path d=\"M0 0C1e30 1e30 -1e30 3 4 4\" stroke=\"#000\" stroke-width=\"1e20\"/><path d=\"M2 2z\" stroke=\"#000\"/></svg>");
    defer d.deinit();
    try testing.expectError(error.TooLarge, renderMask(testing.allocator, &d, 0, 4));
    try testing.expectError(error.TooLarge, renderMask(testing.allocator, &d, max_side + 1, 4));
    const m = renderMask(testing.allocator, &d, 8, 8) catch |e| {
        try testing.expect(e == error.TooComplex or e == error.OutOfMemory);
        return;
    };
    testing.allocator.free(m);
}

test "a stroke whose segment length overflows f32 is refused, not converted from NaN" {
    // The difference of two huge finite coordinates is infinite, so the direction is NaN and
    // `@intFromFloat` of an angle count would be illegal behaviour (a trap on some targets).
    for ([_][]const u8{ "round", "miter", "bevel" }) |join| {
        var buf: [256]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "<svg viewBox=\"0 0 10 10\"><path d=\"M-3e38 0H3e38V1\" fill=\"none\" stroke=\"#000\" stroke-linejoin=\"{s}\"/></svg>", .{join});
        var d = try svg.parse(testing.allocator, src);
        defer d.deinit();
        try testing.expectError(error.TooComplex, renderMask(testing.allocator, &d, 16, 16));
    }
}

/// A fan of `n` long edges from a common apex, all active on most rows at once.
fn fanEdges(gpa: std.mem.Allocator, n: usize) ![]Edge {
    const edges = try gpa.alloc(Edge, n);
    for (edges, 0..) |*e, i| {
        const fi: f32 = @floatFromInt(i);
        const top = fi * 8.0 / @as(f32, @floatFromInt(n)) * 1.6;
        e.* = .{ .x0 = (9 - fi * 8.0 / @as(f32, @floatFromInt(n))) * 1.6, .y0 = top, .x1 = 5 * 1.6, .y1 = 16, .dir = if (i % 2 == 0) 1 else -1 };
    }
    return edges;
}

test "many crossings on one scanline are sorted in n log n, not n squared" {
    const n = 3000;
    const edges = try fanEdges(testing.allocator, n);
    defer testing.allocator.free(edges);
    var f = try Filler.init(testing.allocator, 16, 16);
    defer f.deinit();
    const cov = try testing.allocator.alloc(f32, 16 * 16);
    defer testing.allocator.free(cov);
    _ = try f.fill(edges, .nonzero, cov);
    // 16 rows x 16 sub-scanlines x up to n crossings x log2(n) is about 9 million.
    try testing.expect(f.sort_ops < 20_000_000);
}

test "fill work is budgeted: edges times rows past the limit is TooComplex" {
    const edges = try fanEdges(testing.allocator, 100);
    defer testing.allocator.free(edges);
    var f = try Filler.init(testing.allocator, 16, 16);
    defer f.deinit();
    const cov = try testing.allocator.alloc(f32, 16 * 16);
    defer testing.allocator.free(cov);
    f.work_left = 1000; // the fan needs about 100 edges x 16 sub-scanlines x 16 rows
    try testing.expectError(error.TooComplex, f.fill(edges, .nonzero, cov));
    f.work_left = max_fill_work;
    _ = try f.fill(edges, .nonzero, cov);
    try testing.expect(f.work_left < max_fill_work);
}

/// Fails an allocation that would take the live total over `cap` bytes.
const CapAllocator = struct {
    inner: std.mem.Allocator,
    cap: usize,
    live: usize = 0,

    fn allocator(c: *CapAllocator) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *CapAllocator = @ptrCast(@alignCast(ctx));
        if (c.live + len > c.cap) return null;
        const p = c.inner.rawAlloc(len, al, ra) orelse return null;
        c.live += len;
        return p;
    }
    fn resize(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const c: *CapAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > m.len and c.live + (new_len - m.len) > c.cap) return false;
        if (!c.inner.rawResize(m, al, new_len, ra)) return false;
        c.live = c.live - m.len + new_len;
        return true;
    }
    fn remap(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *CapAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > m.len and c.live + (new_len - m.len) > c.cap) return null;
        const p = c.inner.rawRemap(m, al, new_len, ra) orelse return null;
        c.live = c.live - m.len + new_len;
        return p;
    }
    fn free(ctx: *anyopaque, m: []u8, al: std.mem.Alignment, ra: usize) void {
        const c: *CapAllocator = @ptrCast(@alignCast(ctx));
        c.inner.rawFree(m, al, ra);
        c.live -= m.len;
    }
};

test "flattening is budgeted in points, not only in input points" {
    // 12,000 wild cubics (36,000 input points, under the parser's limit) flatten to 400 points
    // each: 4.8 million points, 38 MB. Capped at 48 MB the old code ran out of memory instead.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "<svg viewBox=\"0 0 10 10\"><path d=\"");
    for (0..12_000) |_| try src.appendSlice(testing.allocator, "M0 0C10000 0 0 10000 10000 10000");
    try src.appendSlice(testing.allocator, "\"/></svg>");
    var d = try svg.parse(testing.allocator, src.items);
    defer d.deinit();
    var cap: CapAllocator = .{ .inner = testing.allocator, .cap = 48 * 1024 * 1024 };
    try testing.expectError(error.TooComplex, renderMask(cap.allocator(), &d, 16, 16));
    try testing.expectEqual(@as(usize, 0), cap.live);
}

fn renderBytes(src: []const u8, w: u32, h: u32, mode: Mode, whole: bool) ![]u8 {
    var d = try svg.parse(testing.allocator, src);
    defer d.deinit();
    var c = try canvasInit(testing.allocator, &d, w, h, mode, .{ .r = 10, .g = 20, .b = 30 });
    defer c.deinit();
    c.filler.whole_raster = whole;
    for (d.shapes) |*sh| try c.paintShape(sh);
    const out = try testing.allocator.alloc(u8, c.acc.len);
    for (out, c.acc) |*o, a| o.* = toByte(a);
    return out;
}

test "bounding the clear and the composite to each shape gives the same pixels as the full raster" {
    const src =
        \\<svg viewBox="0 0 40 40"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
        \\<stop offset="0" stop-color="#f00"/><stop offset="1" stop-color="#00f"/></linearGradient></defs>
        \\<rect x="2" y="3" width="9" height="7" fill="#123456"/>
        \\<circle cx="30" cy="12" r="6" fill="url(#g)" opacity="0.7"/>
        \\<path d="M5 20 L35 22 L20 38 Z M12 26 L28 26 L20 33 Z" fill="#0a0" fill-rule="evenodd"/>
        \\<path d="M-10 5 L50 8" stroke="#333" stroke-width="3" stroke-linecap="round" fill="none"/>
        \\<path d="M20 -5 Q38 20 20 60" stroke="#c0c" stroke-width="2.5" fill="none" stroke-linejoin="round"/>
        \\<rect x="100" y="100" width="5" height="5"/>
        \\<rect x="-30" y="-30" width="20" height="20" fill="#f80"/>
        \\<rect x="39.5" y="39.5" width="9" height="9" fill="#08f" fill-opacity="0.5"/>
        \\</svg>
    ;
    for ([_]Mode{ .mono, .color }) |mode| {
        for ([_][2]u32{ .{ 40, 40 }, .{ 37, 23 }, .{ 128, 128 } }) |sz| {
            const a = try renderBytes(src, sz[0], sz[1], mode, false);
            defer testing.allocator.free(a);
            const b = try renderBytes(src, sz[0], sz[1], mode, true);
            defer testing.allocator.free(b);
            try testing.expectEqualSlices(u8, b, a);
            var ink: usize = 0;
            for (a) |v| ink += v;
            try testing.expect(ink > 0);
        }
    }
}

test "many small shapes on a big raster cost their own size, not the raster's, in the work budget" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    try src.appendSlice(testing.allocator, "<svg viewBox=\"0 0 2048 2048\">");
    for (0..3000) |i| try src.print(testing.allocator, "<rect x=\"{d}\" y=\"{d}\" width=\"4\" height=\"4\"/>", .{ (i * 37) % 2000, (i * 91) % 2000 });
    try src.appendSlice(testing.allocator, "</svg>");
    var d = try svg.parse(testing.allocator, src.items);
    defer d.deinit();
    var c = try canvasInit(testing.allocator, &d, 2048, 2048, .mono, .{});
    defer c.deinit();
    for (d.shapes) |*sh| try c.paintShape(sh);
    // Each box is a few dozen pixels; the full-raster path would have been 3000 x 4M pixels.
    try testing.expect(max_fill_work - c.filler.work_left < max_fill_work / 100);
    // A handful of full-size shapes is charged for the pixels it touches.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "<svg viewBox=\"0 0 2048 2048\">");
    for (0..200) |_| try big.appendSlice(testing.allocator, "<rect width=\"2048\" height=\"2048\"/>");
    try big.appendSlice(testing.allocator, "</svg>");
    var d2 = try svg.parse(testing.allocator, big.items);
    defer d2.deinit();
    try testing.expectError(error.TooComplex, renderMask(testing.allocator, &d2, 2048, 2048));
}

test "every bundled icon renders at the largest size using under a quarter of the work and point budgets" {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "examples/assets/icons", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var seen: usize = 0;
    var worst_work: u64 = 0;
    var worst_points: usize = 0;
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".svg")) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        var d = try svg.parse(testing.allocator, bytes);
        defer d.deinit();
        var c = try canvasInit(testing.allocator, &d, max_side, max_side, .mono, .{});
        defer c.deinit();
        for (d.shapes) |*sh| c.paintShape(sh) catch |e| {
            std.debug.print("{s}: {s}\n", .{ entry.name, @errorName(e) });
            return error.TestUnexpectedResult;
        };
        const work = max_fill_work - c.filler.work_left;
        const points = max_flat_points - c.flat.left;
        worst_work = @max(worst_work, work);
        worst_points = @max(worst_points, points);
        if (work >= max_fill_work / 4 or points >= max_flat_points / 4) {
            std.debug.print("{s}: work {d} of {d}, points {d} of {d}\n", .{ entry.name, work, max_fill_work, points, max_flat_points });
            return error.TestUnexpectedResult;
        }
        seen += 1;
    }
    try testing.expect(seen >= 20);
}
