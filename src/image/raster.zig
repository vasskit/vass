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

/// Coverage rasteriser with reusable scratch memory.
const Filler = struct {
    gpa: std.mem.Allocator,
    w: u32,
    h: u32,
    partial: []f32,
    diff: []f32,
    active: std.ArrayList(u32) = .empty,
    cross: std.ArrayList(Crossing) = .empty,

    fn init(gpa: std.mem.Allocator, w: u32, h: u32) Error!Filler {
        const partial = try gpa.alloc(f32, w + 2);
        errdefer gpa.free(partial);
        const diff = try gpa.alloc(f32, w + 2);
        return .{ .gpa = gpa, .w = w, .h = h, .partial = partial, .diff = diff };
    }

    fn deinit(f: *Filler) void {
        f.gpa.free(f.partial);
        f.gpa.free(f.diff);
        f.active.deinit(f.gpa);
        f.cross.deinit(f.gpa);
    }

    /// Fills `cov` (w*h, 0..1) with the coverage of `edges` under `rule`.
    fn fill(f: *Filler, edges: []Edge, rule: svg.FillRule, cov: []f32) Error!void {
        @memset(cov, 0);
        if (edges.len == 0) return;
        std.sort.pdq(Edge, edges, {}, edgeLess);
        f.active.clearRetainingCapacity();
        var next: usize = 0;
        const wf: f32 = @floatFromInt(f.w);
        const wt: f32 = 1.0 / @as(f32, sub_n);
        var row: u32 = 0;
        while (row < f.h) : (row += 1) {
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
            @memset(f.partial, 0);
            @memset(f.diff, 0);
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
                // Insertion sort: tiny lists.
                var i: usize = 1;
                while (i < cs.len) : (i += 1) {
                    const v = cs[i];
                    var j = i;
                    while (j > 0 and cs[j - 1].x > v.x) : (j -= 1) cs[j] = cs[j - 1];
                    cs[j] = v;
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
            const out = cov[@as(usize, row) * f.w ..][0..f.w];
            for (out, 0..) |*o, x| {
                acc += f.diff[x];
                o.* = std.math.clamp(f.partial[x] + acc, 0, 1);
            }
        }
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
            try out.pts.append(gpa, cur);
        },
        .line => {
            if (start_idx == null) {
                start_idx = out.pts.items.len;
                try out.pts.append(gpa, cur);
            }
            cur = sh.pts[pi];
            pi += 1;
            try out.pts.append(gpa, cur);
            drawn = true;
        },
        .cubic => {
            if (start_idx == null) {
                start_idx = out.pts.items.len;
                try out.pts.append(gpa, cur);
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
                try out.pts.append(gpa, .{
                    a * cur[0] + b * c1[0] + c * c2[0] + d * e[0],
                    a * cur[1] + b * c1[1] + c * c2[1] + d * e[1],
                });
            }
            try out.pts.append(gpa, e);
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
fn perp(d: P) P {
    return .{ -d[1], d[0] };
}

/// Appends an arc around `c` of radius `r` from unit vector `un0` through signed angle `delta`
/// (steps of at most `step` radians), excluding the start point, including the end point.
fn arcPoints(pts: *std.ArrayList(P), gpa: std.mem.Allocator, c: P, un0: P, delta: f32, r: f32, step: f32) Error!void {
    const n: usize = @max(1, @min(256, @as(usize, @intFromFloat(@ceil(@abs(delta) / step)))));
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
            const dv = sub2(b, a);
            const l = len2(dv);
            const d: P = .{ dv[0] / l, dv[1] / l };
            try s.segment(a, b, d);
        }
        // Joins.
        const jstart: usize = if (closed) 0 else 1;
        const jend: usize = if (closed) n else n - 1;
        var j = jstart;
        while (j < jend) : (j += 1) {
            const prev = pts[(j + n - 1) % n];
            const v = pts[j];
            const nx = pts[(j + 1) % n];
            const dp = sub2(v, prev);
            const dn = sub2(nx, v);
            const lp = len2(dp);
            const ln = len2(dn);
            try s.joinAt(v, .{ dp[0] / lp, dp[1] / lp }, .{ dn[0] / ln, dn[1] / ln });
        }
        if (!closed) {
            const d0 = sub2(pts[1], pts[0]);
            const l0 = len2(d0);
            try s.capAt(pts[0], .{ -d0[0] / l0, -d0[1] / l0 });
            const d1 = sub2(pts[n - 1], pts[n - 2]);
            const l1 = len2(d1);
            try s.capAt(pts[n - 1], .{ d1[0] / l1, d1[1] / l1 });
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
            try c.filler.fill(c.edges.edges.items, sh.rule, c.cov);
            try c.composite(sh, sh.fill, sh.fill_alpha, m);
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
            try c.filler.fill(c.edges.edges.items, .nonzero, c.cov);
            try c.composite(sh, sh.stroke, sh.stroke_alpha, m);
        }
    }

    fn composite(c: *Canvas, sh: *const svg.Shape, paint: svg.Paint, alpha: f32, m: svg.Affine) Error!void {
        const n = @as(usize, c.w) * c.h;
        if (c.mode == .mono) {
            var a = alpha;
            if (paint == .color) a *= @as(f32, @floatFromInt(paint.color.a)) / 255.0;
            for (c.cov[0..n], c.acc[0..n]) |cv, *dst| {
                const s = cv * a;
                dst.* = dst.* + s - dst.* * s;
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
                const b = @as(f32, @floatFromInt(col.b)) / 255.0;
                for (0..n) |i| {
                    const s = c.cov[i] * a;
                    if (s <= 0) continue;
                    const d = c.acc[i * 4 ..][0..4];
                    const k = 1 - s;
                    d[0] = r * s + d[0] * k;
                    d[1] = g * s + d[1] * k;
                    d[2] = b * s + d[2] * k;
                    d[3] = s + d[3] * k;
                }
            },
            .gradient => |gi| try c.compositeGradient(sh, c.doc.gradients[gi], alpha, m),
        }
    }

    fn compositeGradient(c: *Canvas, sh: *const svg.Shape, g: svg.Gradient, alpha: f32, m: svg.Affine) Error!void {
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
        for (0..c.h) |y| {
            for (0..c.w) |x| {
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
