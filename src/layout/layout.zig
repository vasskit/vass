//! Flex-style layout for Vass: declare a tree of boxes with sizing constraints, solve it
//! for a rectangle, then call widgets with the resulting `Rect`s. Everything happens
//! inside one frame, so there is no one-frame lag, and the app stops doing rect
//! arithmetic by hand.
//!
//!     var lay = vass.Layout.init(arena);
//!     _ = lay.begin(.{ .dir = .col, .padding = .all(16), .gap = 12 });
//!     _ = lay.begin(.{ .dir = .row, .h = .fixed(44), .gap = 8, .cross = .center });
//!     const back = lay.leaf(.{ .w = .fixed(32), .h = .fixed(32) });
//!     const title = lay.leaf(.{ .w = .grow(1), .h = .fixed(20) });
//!     lay.end();
//!     const body = lay.leaf(.{ .w = .grow(1), .h = .grow(1) });
//!     lay.end();
//!     lay.solve(window_rect);
//!     _ = ui.iconButton(lay.rect(back), ...);
//!
//! This file depends only on `geom.zig` and std. Text measurement comes in through
//! `Size.measured`, a callback, so layout itself never touches a window or a font.
//!
//! Model (a small subset of CSS flexbox, border-box sizing):
//!  * A node is a box. A container lays its in-flow children along `dir` (`.row` = left
//!    to right, `.col` = top to bottom) separated by `gap`, inside its `padding`.
//!  * Per axis a node's `Size` is `.fixed(px)`, `.grow(weight)`, `.hug`, `.percent(f)` or
//!    `.measured(ctx, fn)`. On the main axis `grow` nodes share what the other children
//!    leave over, in proportion to their weights (a grow child's basis is 0, so weights
//!    are exact ratios). On the cross axis `grow` means stretch.
//!  * `.hug` is the content size: children plus padding for a container, 0 for a leaf.
//!    `.measured` is for leaves: the callback gets a width and returns the extent the
//!    content needs at that width (called with infinity to ask for the intrinsic width),
//!    which gives height-for-width, e.g. wrapped text.
//!  * `min_*`/`max_*` clamp each axis (min wins over max). `aspect` is width / height.
//!  * Children never shrink unless `shrink > 0`, and then not below `min_*`. When the
//!    children do not fit the main axis they overflow; `overflow` reports by how much.
//!
//! Algorithm (all passes are linear in the number of nodes; the only super-linear part is
//! the flex loop that re-resolves min/max violations inside one line, bounded by that
//! line's item count): 1. intrinsic widths, bottom-up. 2. widths, top-down (main-axis
//! flex for rows, alignment for columns, line breaking for `wrap`). 3. natural heights,
//! bottom-up, now that every width is known (this is where height-for-width happens).
//! 4. heights and positions, top-down. 5. snapping.
//!
//! Rounding: layout runs in f32; at the end every node's left, top, right and bottom
//! edges are snapped to whole points with `floor(v + 0.5)` and the size is the
//! difference. Snapping edges (not sizes) means a shared edge lands on the same pixel for
//! both neighbours, so siblings never overlap or leave a gap and children always stay
//! inside their parent. With whole-point gaps the children of a line add up exactly
//! (extents plus gaps equal the content extent); a fractional gap can vary by 1 pt.
//!
//! Scrolling: a container with `scroll = .y` (or `.x`, `.both`) lays its children out
//! against unbounded length on that axis while its own rect stays what its parent gave
//! it. `contentSize` returns what the children need (padding included) for
//! `ui.beginScroll`, and `scrollTo` moves the descendants by the scroll offset.
const std = @import("std");
const geom = @import("../core/geom.zig");

const Rect = geom.Rect;
const inf = std.math.inf(f32);

pub const Dir = enum { row, col };
pub const Justify = enum { start, center, end, space_between };
pub const Align = enum { start, center, end, stretch };
pub const Scroll = enum { none, x, y, both };
pub const Position = enum { flow, absolute };

/// A width and height (also used for `contentSize` and `overflow`).
pub const Extent = struct { w: f32 = 0, h: f32 = 0 };

/// Space on the four sides of a box.
pub const Insets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn all(v: f32) Insets {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }
    /// `x` on the left and right, `y` on the top and bottom.
    pub fn xy(x: f32, y: f32) Insets {
        return .{ .left = x, .top = y, .right = x, .bottom = y };
    }
};

/// Offsets from the parent's rectangle for an `.absolute` node; null sides are free.
pub const Anchor = struct {
    left: ?f32 = null,
    top: ?f32 = null,
    right: ?f32 = null,
    bottom: ?f32 = null,
};

/// Measures a leaf. `max_w` is the width the leaf is given (infinity when the leaf is
/// asked for its intrinsic width). Returns the extent its content needs: for wrapped
/// text `w` is the widest line (at most `max_w`) and `h` all the lines.
pub const MeasureFn = *const fn (ctx: ?*anyopaque, max_w: f32) Extent;

pub const Size = struct {
    kind: Kind = .hug,
    value: f32 = 0,
    ctx: ?*anyopaque = null,
    func: ?MeasureFn = null,

    pub const Kind = enum { fixed, grow, hug, percent, measured };

    /// Content size (children plus padding; 0 for a leaf).
    pub const hug: Size = .{};

    pub fn fixed(px: f32) Size {
        return .{ .kind = .fixed, .value = px };
    }
    /// Share of the leftover main-axis space in proportion to `weight`; stretch on the cross axis.
    pub fn grow(weight: f32) Size {
        return .{ .kind = .grow, .value = weight };
    }
    /// A fraction (0..1) of the parent's content box on this axis (0 when that is unbounded).
    pub fn percent(f: f32) Size {
        return .{ .kind = .percent, .value = f };
    }
    /// A leaf sized by `func(ctx, width)`. On the width axis the intrinsic width is used,
    /// on the height axis the height at the width the leaf ends up with.
    pub fn measured(ctx: ?*anyopaque, func: MeasureFn) Size {
        return .{ .kind = .measured, .ctx = ctx, .func = func };
    }
};

// Free-function spellings, for `rowNamed` where `.fixed(..)` has no result type to resolve against.
pub const hug: Size = Size.hug;
pub const fixed = Size.fixed;
pub const grow = Size.grow;
pub const percent = Size.percent;
pub const measured = Size.measured;

pub const Opts = struct {
    // ---- this node, as a child ----
    w: Size = .hug,
    h: Size = .hug,
    min_w: f32 = 0,
    max_w: f32 = inf,
    min_h: f32 = 0,
    max_h: f32 = inf,
    /// Width divided by height. Derives the height from the width when `h` is `.hug`, and
    /// the width from a `.fixed` height when `w` is `.hug`. Such a node is not stretched, except
    /// across a column, where a `.grow` width takes the column's width and the height follows.
    aspect: ?f32 = null,
    /// How much this node may shrink (relative to its size) when its siblings overflow the
    /// main axis; 0 means never. It does not go below `min_w`/`min_h`.
    shrink: f32 = 0,
    /// Overrides the parent's `cross` alignment for this node.
    align_self: ?Align = null,
    /// `.absolute` takes the node out of the flow: it is placed by `inset` against the
    /// parent's whole rectangle and does not count for the parent's size or content.
    position: Position = .flow,
    inset: Anchor = .{},

    // ---- this node, as a container ----
    dir: Dir = .row,
    gap: f32 = 0,
    /// Space between wrapped lines (defaults to `gap`).
    line_gap: ?f32 = null,
    padding: Insets = .{},
    /// Distribution of free main-axis space (when no child grows).
    main: Justify = .start,
    /// Default cross-axis alignment of the children. `.stretch` fills the cross extent
    /// for children whose size is `.hug`, `.measured` or `.grow` (not for fixed ones).
    cross: Align = .stretch,
    /// Rows only: start a new line when the next child does not fit.
    wrap: bool = false,
    scroll: Scroll = .none,
};

/// Handle to a node of a `Layout`; valid until the layout is reset. `.none` is what
/// calls return when they could not add a node; every query then answers with zeros.
pub const Node = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

const none_idx: u32 = std.math.maxInt(u32);
const max_depth = 64;
const eps: f32 = 1e-3;

const Entry = struct {
    o: Opts,
    sz: [2]Size,
    mn: [2]f32,
    mx: [2]f32,
    parent: u32,
    first: u32 = none_idx,
    last: u32 = none_idx,
    next: u32 = none_idx,
    /// One past the last descendant (entries are stored in pre-order).
    end: u32 = 0,
    /// Natural outer size per axis (width: intrinsic; height: for the width it was given).
    nat: [2]f32 = .{ 0, 0 },
    pos: [2]f32 = .{ 0, 0 },
    len: [2]f32 = .{ 0, 0 },
    content: [2]f32 = .{ 0, 0 },
    /// Wrapped line within the parent, and how many lines this container has.
    line: u32 = 0,
    lines: u32 = 0,
    // flex scratch
    base: f32 = 0,
    tmp: f32 = 0,
    weight: f32 = 0,
    frozen: bool = false,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

fn fin0(v: f32) f32 {
    return if (std.math.isFinite(v)) @max(0, v) else 0;
}

fn cleanSize(s: Size) Size {
    var r = s;
    r.value = fin0(s.value);
    return r;
}

fn cleanMax(v: f32) f32 {
    return if (std.math.isNan(v)) inf else @max(0, v);
}

pub const Layout = struct {
    alloc: ?std.mem.Allocator,
    nodes: std.ArrayList(Entry) = .empty,
    stack: [max_depth]u32 = undefined,
    depth: u32 = 0,
    /// Nesting inside a `begin` that could not be recorded; everything there is ignored.
    dead: u32 = 0,
    /// Set when a node could not be stored (out of memory or too many); the rest is skipped.
    failed: bool = false,

    /// A layout that grows in `alloc` (an arena is ideal: nothing is freed per node).
    pub fn init(alloc: std.mem.Allocator) Layout {
        return .{ .alloc = alloc };
    }

    /// A layout over caller storage (at most `buf.len` nodes, no allocation).
    fn initBuffer(buf: []Entry) Layout {
        return .{ .alloc = null, .nodes = .initBuffer(buf) };
    }

    pub fn deinit(l: *Layout) void {
        if (l.alloc) |a| l.nodes.deinit(a);
        l.* = .{ .alloc = l.alloc };
    }

    /// Forgets every node, keeping the memory. All `Node`s become invalid.
    pub fn reset(l: *Layout) void {
        l.nodes.clearRetainingCapacity();
        l.depth = 0;
        l.dead = 0;
        l.failed = false;
    }

    /// Copies `v` into the layout's allocator, e.g. for a `Size.measured` context that must
    /// live until `solve`. Null without an allocator or memory.
    pub fn create(l: *Layout, comptime T: type, v: T) ?*T {
        const a = l.alloc orelse return null;
        const p = a.create(T) catch return null;
        p.* = v;
        return p;
    }

    // ---- declaring ----------------------------------------------------------------

    fn push(l: *Layout, o: Opts) ?u32 {
        if (l.dead > 0) return null;
        const idx: u32 = @intCast(l.nodes.items.len);
        var oo = o;
        oo.gap = fin0(o.gap);
        if (o.line_gap) |g| oo.line_gap = fin0(g);
        oo.padding = .{ .left = fin0(o.padding.left), .top = fin0(o.padding.top), .right = fin0(o.padding.right), .bottom = fin0(o.padding.bottom) };
        if (o.aspect) |a| oo.aspect = if (std.math.isFinite(a) and a > 0) a else null;
        oo.shrink = fin0(o.shrink);
        const e: Entry = .{
            .o = oo,
            .sz = .{ cleanSize(o.w), cleanSize(o.h) },
            .mn = .{ fin0(o.min_w), fin0(o.min_h) },
            .mx = .{ cleanMax(o.max_w), cleanMax(o.max_h) },
            .parent = if (l.depth > 0) l.stack[l.depth - 1] else none_idx,
            .end = idx + 1,
        };
        if (l.alloc) |a| {
            l.nodes.append(a, e) catch {
                l.failed = true;
                return null;
            };
        } else {
            l.nodes.appendBounded(e) catch {
                l.failed = true;
                return null;
            };
        }
        if (e.parent != none_idx) {
            const p = &l.nodes.items[e.parent];
            if (p.last == none_idx) p.first = idx else l.nodes.items[p.last].next = idx;
            l.nodes.items[e.parent].last = idx;
        }
        return idx;
    }

    /// Opens a container. Add its children, then call `end`.
    pub fn begin(l: *Layout, o: Opts) Node {
        const idx = if (l.depth >= max_depth) null else l.push(o);
        if (idx) |i| {
            l.stack[l.depth] = i;
            l.depth += 1;
            return @enumFromInt(i);
        }
        misuse(l.dead > 0 or l.failed); // otherwise: nested deeper than max_depth
        l.dead += 1;
        return .none;
    }

    /// Closes the innermost `begin`. Unbalanced calls assert in debug builds and are ignored in release.
    pub fn end(l: *Layout) void {
        if (l.dead > 0) {
            l.dead -= 1;
            return;
        }
        misuse(l.depth > 0);
        if (l.depth == 0) return;
        l.depth -= 1;
        const i = l.stack[l.depth];
        l.nodes.items[i].end = @intCast(l.nodes.items.len);
    }

    /// A node without children.
    pub fn leaf(l: *Layout, o: Opts) Node {
        const idx = l.push(o) orelse return .none;
        return @enumFromInt(idx);
    }

    // ---- queries (after `solve`) ----------------------------------------------------

    fn get(l: *const Layout, n: Node) ?*const Entry {
        if (n == .none) return null;
        const i = @intFromEnum(n);
        if (i >= l.nodes.items.len) return null;
        return &l.nodes.items[i];
    }

    /// The node's rectangle in whole points (see "Rounding"), in the coordinates `solve`
    /// was given, moved by any `scrollTo` of an ancestor.
    pub fn rect(l: *const Layout, n: Node) Rect {
        const e = l.get(n) orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return e.rect;
    }

    /// What the node's children need, padding included, rounded to whole points. For a
    /// scrolling node this is the content size to hand to `ui.beginScroll`; it may be
    /// smaller than `rect` (then nothing scrolls).
    pub fn contentSize(l: *const Layout, n: Node) Extent {
        const e = l.get(n) orelse return .{};
        return .{ .w = snap(e.content[0]), .h = snap(e.content[1]) };
    }

    /// How far the children extend past the node's own size (zero when they fit).
    pub fn overflow(l: *const Layout, n: Node) Extent {
        const e = l.get(n) orelse return .{};
        return .{
            .w = if (e.content[0] - e.len[0] > eps) snap(e.content[0] - e.len[0]) else 0,
            .h = if (e.content[1] - e.len[1] > eps) snap(e.content[1] - e.len[1]) else 0,
        };
    }

    /// Moves everything inside `n` (its descendants, not `n`) by `-ox`, `-oy`: apply a
    /// scroll offset after `solve`, typically `lay.scrollTo(node, 0, scroll_state.offset)`
    /// right after `ui.beginScroll` clamped it. Nested scroll nodes compose: call it for
    /// the outer node first.
    pub fn scrollTo(l: *Layout, n: Node, ox: f32, oy: f32) void {
        if (n == .none) return;
        const i = @intFromEnum(n);
        if (i >= l.nodes.items.len) return;
        const dx = if (std.math.isFinite(ox)) ox else 0;
        const dy = if (std.math.isFinite(oy)) oy else 0;
        const stop = l.nodes.items[i].end;
        for (l.nodes.items[i + 1 .. stop]) |*e| {
            e.rect.x -= dx;
            e.rect.y -= dy;
        }
    }

    /// Number of nodes declared (for debug overlays and tests).
    pub fn count(l: *const Layout) usize {
        return l.nodes.items.len;
    }

    /// The `i`-th node in declaration order.
    pub fn at(l: *const Layout, i: usize) Node {
        _ = l;
        return @enumFromInt(i);
    }

    /// One past the index of `n`'s last descendant: the nodes `at(i)` for `i` in
    /// `n + 1 .. subtreeEnd(n)` are inside `n`.
    pub fn subtreeEnd(l: *const Layout, n: Node) usize {
        const e = l.get(n) orelse return 0;
        return e.end;
    }

    /// Nesting depth of `n` (0 for a top-level node).
    pub fn depthOf(l: *const Layout, n: Node) usize {
        var d: usize = 0;
        var e = l.get(n) orelse return 0;
        while (e.parent != none_idx) : (d += 1) e = &l.nodes.items[e.parent];
        return d;
    }

    // ---- solving ------------------------------------------------------------------

    /// Computes every node's rectangle. Top-level nodes are each solved against `area`
    /// (a fixed-size one keeps its size, `.grow` and `.percent` fill or take a share of it).
    pub fn solve(l: *Layout, area_in: Rect) void {
        misuse(l.depth == 0 and l.dead == 0); // unbalanced begin/end
        l.dead = 0;
        while (l.depth > 0) l.end();
        const n = l.nodes.items.len;
        if (n == 0) return;
        const area: Rect = .{
            .x = if (std.math.isFinite(area_in.x)) area_in.x else 0,
            .y = if (std.math.isFinite(area_in.y)) area_in.y else 0,
            .w = fin0(area_in.w),
            .h = fin0(area_in.h),
        };
        const items = l.nodes.items;
        // 1. intrinsic widths.
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            l.natural(i, 0);
        }
        // 2. widths and x, top-down.
        for (items) |*e| if (e.parent == none_idx) {
            e.pos[0] = area.x;
            e.len[0] = rootLen(e, 0, area.w);
        };
        for (0..n) |k| if (items[k].first != none_idx or items[k].parent == none_idx) l.place(k, 0);
        // 3. natural heights.
        i = n;
        while (i > 0) {
            i -= 1;
            l.natural(i, 1);
        }
        // 4. heights and y.
        for (items) |*e| if (e.parent == none_idx) {
            e.pos[1] = area.y;
            e.len[1] = rootLen(e, 1, area.h);
        };
        for (0..n) |k| if (items[k].first != none_idx or items[k].parent == none_idx) l.place(k, 1);
        // 5. snap.
        for (items) |*e| {
            const x0 = snap(e.pos[0]);
            const y0 = snap(e.pos[1]);
            e.rect = .{ .x = x0, .y = y0, .w = snap(e.pos[0] + e.len[0]) - x0, .h = snap(e.pos[1] + e.len[1]) - y0 };
        }
    }

    fn rootLen(e: *const Entry, ax: usize, avail: f32) f32 {
        const s = e.sz[ax];
        const v = switch (s.kind) {
            .fixed => s.value,
            .percent => s.value * avail,
            .grow => avail,
            .hug, .measured => e.nat[ax],
        };
        return clampAx(e, ax, v);
    }

    // ---- helpers ------------------------------------------------------------------

    fn padStart(e: *const Entry, ax: usize) f32 {
        return if (ax == 0) e.o.padding.left else e.o.padding.top;
    }
    fn padEnd(e: *const Entry, ax: usize) f32 {
        return if (ax == 0) e.o.padding.right else e.o.padding.bottom;
    }
    fn dirAxis(e: *const Entry) usize {
        return if (e.o.dir == .row) 0 else 1;
    }
    fn scrollsAx(e: *const Entry, ax: usize) bool {
        return switch (e.o.scroll) {
            .none => false,
            .x => ax == 0,
            .y => ax == 1,
            .both => true,
        };
    }
    fn isFlow(e: *const Entry) bool {
        return e.o.position == .flow;
    }

    fn nextFlow(l: *const Layout, from: u32) u32 {
        var c = from;
        while (c != none_idx and !isFlow(&l.nodes.items[c])) c = l.nodes.items[c].next;
        return c;
    }

    // ---- natural sizes ------------------------------------------------------------

    /// Natural outer size on `ax`: pass 1 for the width, pass 3 for the height (needs every width).
    fn natural(l: *Layout, i: usize, ax: usize) void {
        const e = &l.nodes.items[i];
        const s = e.sz[ax];
        var n: f32 = 0;
        switch (s.kind) {
            .fixed => n = s.value,
            .percent => n = 0,
            .grow, .hug, .measured => {
                if (e.first == none_idx) {
                    n = padStart(e, ax) + padEnd(e, ax);
                    if (s.kind == .measured) if (s.func) |f| {
                        const ex = f(s.ctx, if (ax == 0) inf else e.len[0]);
                        n += fin0(if (ax == 0) ex.w else ex.h);
                    };
                } else n = l.contentNatural(i, ax);
                if (e.o.aspect) |a| {
                    if (ax == 1 and s.kind == .hug) n = e.len[0] / a;
                    if (ax == 0 and s.kind == .hug and e.sz[1].kind == .fixed) n = e.sz[1].value * a;
                }
            },
        }
        e.nat[ax] = clampAx(e, ax, n);
    }

    fn contentNatural(l: *Layout, i: usize, ax: usize) f32 {
        const e = &l.nodes.items[i];
        const pad = padStart(e, ax) + padEnd(e, ax);
        const main = dirAxis(e) == ax;
        var total: f32 = 0;
        var maxv: f32 = 0;
        var cnt: f32 = 0;
        var line_total: f32 = 0;
        var line_max: f32 = 0;
        var cur_line: u32 = 0;
        var lines: f32 = 1;
        var c = l.nextFlow(e.first);
        while (c != none_idx) : (c = l.nextFlow(l.nodes.items[c].next)) {
            const ce = &l.nodes.items[c];
            const v = ce.nat[ax];
            total += v;
            maxv = @max(maxv, v);
            cnt += 1;
            if (ce.line != cur_line) {
                line_total += line_max;
                line_max = 0;
                cur_line = ce.line;
                lines += 1;
            }
            line_max = @max(line_max, v);
        }
        if (cnt == 0) return pad;
        if (main) return pad + total + e.o.gap * (cnt - 1);
        if (ax == 1 and e.o.wrap and e.o.dir == .row) {
            line_total += line_max;
            return pad + line_total + (e.o.line_gap orelse e.o.gap) * (lines - 1);
        }
        return pad + maxv;
    }

    fn clampAx(e: *const Entry, ax: usize, v: f32) f32 {
        return @max(e.mn[ax], @min(fin0(v), e.mx[ax]));
    }

    // ---- placing children along one axis ------------------------------------------

    fn place(l: *Layout, i: usize, ax: usize) void {
        const e = &l.nodes.items[i];
        if (e.first != none_idx) {
            const bounded = !scrollsAx(e, ax);
            const inner_pos = e.pos[ax] + padStart(e, ax);
            const inner_len = if (bounded) @max(0, e.len[ax] - padStart(e, ax) - padEnd(e, ax)) else inf;
            if (ax == dirAxis(e)) l.placeMain(e, ax, inner_pos, inner_len, bounded) else l.placeCross(e, ax, inner_pos, inner_len, bounded);
            l.placeAbsolute(e, ax);
        }
        // Content extent: the farthest in-flow child edge, plus the end padding.
        var far: f32 = e.pos[ax] + padStart(e, ax);
        if (e.first != none_idx) {
            var c = l.nextFlow(e.first);
            while (c != none_idx) : (c = l.nextFlow(l.nodes.items[c].next)) {
                const ce = &l.nodes.items[c];
                far = @max(far, ce.pos[ax] + ce.len[ax]);
            }
        }
        e.content[ax] = far - e.pos[ax] + padEnd(e, ax);
    }

    /// The size a flow child asks for on the main axis before sharing (grow: its minimum).
    fn initItem(c: *Entry, ax: usize, inner_len: f32, bounded: bool) void {
        const s = c.sz[ax];
        const base: f32 = switch (s.kind) {
            .fixed => s.value,
            .percent => if (bounded) s.value * inner_len else 0,
            .grow => if (bounded) 0 else c.nat[ax],
            .hug, .measured => c.nat[ax],
        };
        c.base = base; // the unclamped basis: min/max violations are resolved by the flex loop
        c.tmp = clampAx(c, ax, base);
        c.frozen = false;
        c.weight = 0;
    }

    fn placeMain(l: *Layout, e: *Entry, ax: usize, inner_pos: f32, inner_len: f32, bounded: bool) void {
        const gap = e.o.gap;
        const items = l.nodes.items;
        // Initial sizes, and line breaks (rows that wrap, with a bounded width).
        const wrap = e.o.wrap and e.o.dir == .row and ax == 0 and bounded;
        var line: u32 = 0;
        var acc: f32 = 0;
        var in_line: u32 = 0;
        var c = l.nextFlow(e.first);
        while (c != none_idx) : (c = l.nextFlow(items[c].next)) {
            const ce = &items[c];
            initItem(ce, ax, inner_len, bounded);
            if (wrap) {
                // The size it would get on a line of its own, min and max applied.
                const hyp = if (ce.sz[ax].kind == .grow) @max(ce.tmp, ce.nat[ax]) else ce.tmp;
                if (in_line > 0 and acc + gap + hyp > inner_len + eps) {
                    line += 1;
                    acc = 0;
                    in_line = 0;
                }
                acc += (if (in_line > 0) gap else 0) + hyp;
                in_line += 1;
            }
            ce.line = line;
        }
        if (ax == 0) e.lines = if (e.first == none_idx) 0 else line + 1;
        // Flex each line, then position it.
        c = l.nextFlow(e.first);
        while (c != none_idx) {
            var stop = c;
            var n: u32 = 0;
            const ln = items[c].line;
            while (stop != none_idx and items[stop].line == ln) : (stop = l.nextFlow(items[stop].next)) n += 1;
            l.flexLine(e, c, stop, n, ax, inner_pos, inner_len, bounded);
            c = stop;
        }
    }

    fn flexLine(l: *Layout, e: *Entry, first: u32, stop: u32, n: u32, ax: usize, inner_pos: f32, inner_len: f32, bounded: bool) void {
        const items = l.nodes.items;
        const gap = e.o.gap;
        const nf: f32 = @floatFromInt(n);
        const gaps = gap * @max(0, nf - 1);
        var sum: f32 = 0;
        var c = first;
        while (c != stop) : (c = l.nextFlow(items[c].next)) sum += items[c].tmp;
        if (bounded) {
            const free = inner_len - gaps - sum;
            if (free > eps) {
                c = first;
                while (c != stop) : (c = l.nextFlow(items[c].next)) {
                    if (items[c].sz[ax].kind == .grow) items[c].weight = items[c].sz[ax].value;
                }
                resolve(l, first, stop, ax, inner_len - gaps, n);
            } else if (free < -eps) {
                c = first;
                while (c != stop) : (c = l.nextFlow(items[c].next)) {
                    items[c].weight = items[c].o.shrink * items[c].base;
                }
                resolve(l, first, stop, ax, inner_len - gaps, n);
            }
        }
        var used: f32 = gaps;
        c = first;
        while (c != stop) : (c = l.nextFlow(items[c].next)) {
            items[c].len[ax] = items[c].tmp;
            used += items[c].tmp;
        }
        // Justify.
        const free = if (bounded) @max(0, inner_len - used) else 0;
        var off: f32 = 0;
        var extra: f32 = 0;
        switch (e.o.main) {
            .start => {},
            .center => off = free / 2,
            .end => off = free,
            .space_between => if (n > 1) {
                extra = free / (nf - 1);
            },
        }
        var cur = inner_pos + off;
        c = first;
        while (c != stop) : (c = l.nextFlow(items[c].next)) {
            items[c].pos[ax] = cur;
            cur += items[c].len[ax] + gap + extra;
        }
    }

    /// CSS "resolve flexible lengths": share `space` among the items by weight (grow
    /// weights when there is room, shrink * base when there is not), freezing items that hit
    /// a min or max and sharing the rest again.
    fn resolve(l: *Layout, first: u32, stop: u32, ax: usize, space: f32, n: u32) void {
        const items = l.nodes.items;
        var c = first;
        while (c != stop) : (c = l.nextFlow(items[c].next)) {
            if (items[c].weight <= 0) items[c].frozen = true;
        }
        var iter: u32 = 0;
        while (iter <= n) : (iter += 1) {
            var frozen_sum: f32 = 0;
            var free_base: f32 = 0;
            var wsum: f32 = 0;
            c = first;
            while (c != stop) : (c = l.nextFlow(items[c].next)) {
                if (items[c].frozen) frozen_sum += items[c].tmp else {
                    free_base += items[c].base;
                    wsum += items[c].weight;
                }
            }
            if (wsum <= 0) break;
            const free = space - frozen_sum - free_base;
            var viol: f32 = 0;
            c = first;
            while (c != stop) : (c = l.nextFlow(items[c].next)) {
                const it = &items[c];
                if (it.frozen) continue;
                const t = it.base + free * it.weight / wsum;
                const cl = clampAx(it, ax, t);
                viol += cl - t;
                it.tmp = cl;
            }
            if (@abs(viol) <= eps) break;
            c = first;
            while (c != stop) : (c = l.nextFlow(items[c].next)) {
                const it = &items[c];
                if (it.frozen) continue;
                const t = it.base + free * it.weight / wsum;
                const d = it.tmp - t;
                if ((viol > 0 and d > eps) or (viol < 0 and d < -eps)) it.frozen = true;
            }
        }
    }

    /// The size a flow child wants on a cross axis, before stretching.
    fn crossPref(c: *const Entry, ax: usize, inner_len: f32, bounded: bool) f32 {
        const s = c.sz[ax];
        return clampAx(c, ax, switch (s.kind) {
            .fixed => s.value,
            .percent => if (bounded) s.value * inner_len else 0,
            .grow, .hug, .measured => c.nat[ax],
        });
    }

    fn placeCross(l: *Layout, e: *Entry, ax: usize, inner_pos: f32, inner_len: f32, bounded: bool) void {
        const items = l.nodes.items;
        const wrap = e.o.wrap and e.o.dir == .row;
        const line_gap = e.o.line_gap orelse e.o.gap;
        var cur = inner_pos;
        var c = l.nextFlow(e.first);
        while (c != none_idx) {
            // One line: the children from `c` up to the next line.
            const ln = items[c].line;
            var stop = c;
            var max_pref: f32 = 0;
            while (stop != none_idx and items[stop].line == ln) : (stop = l.nextFlow(items[stop].next)) {
                max_pref = @max(max_pref, crossPref(&items[stop], ax, inner_len, bounded));
            }
            const line_len = if (!wrap and bounded) inner_len else max_pref;
            var k = c;
            while (k != stop) : (k = l.nextFlow(items[k].next)) {
                const ce = &items[k];
                const a = ce.o.align_self orelse e.o.cross;
                // An `aspect` node keeps its own size, unless its width is `.grow` in a column (the
                // height is then derived from the width the column gives it).
                const grows = ce.sz[ax].kind == .grow and (ce.o.aspect == null or ax == 0);
                const stretchable = grows or (ce.o.aspect == null and (ce.sz[ax].kind == .hug or ce.sz[ax].kind == .measured) and a == .stretch);
                var s = crossPref(ce, ax, inner_len, bounded);
                if (stretchable) {
                    s = clampAx(ce, ax, line_len);
                } else if (ax == 0 and ce.sz[0].kind == .measured or (ax == 0 and ce.sz[0].kind == .hug and ce.o.wrap)) {
                    // Text-like content never gets wider than the space it is given.
                    s = clampAx(ce, ax, @min(s, line_len));
                }
                const free = @max(0, line_len - s);
                const off: f32 = switch (a) {
                    .start, .stretch => 0,
                    .center => free / 2,
                    .end => free,
                };
                ce.len[ax] = s;
                ce.pos[ax] = cur + off;
            }
            cur += line_len + line_gap;
            c = stop;
        }
    }

    fn placeAbsolute(l: *Layout, e: *Entry, ax: usize) void {
        const items = l.nodes.items;
        var c = e.first;
        while (c != none_idx) : (c = items[c].next) {
            const ce = &items[c];
            if (isFlow(ce)) continue;
            const a_lo: ?f32 = if (ax == 0) ce.o.inset.left else ce.o.inset.top;
            const a_hi: ?f32 = if (ax == 0) ce.o.inset.right else ce.o.inset.bottom;
            const lo_v: ?f32 = if (a_lo) |v| (if (std.math.isFinite(v)) v else 0) else null;
            const hi_v: ?f32 = if (a_hi) |v| (if (std.math.isFinite(v)) v else 0) else null;
            const parent_len = e.len[ax];
            const s = ce.sz[ax];
            const span = @max(0, parent_len - (lo_v orelse 0) - (hi_v orelse 0));
            const size = clampAx(ce, ax, switch (s.kind) {
                .fixed => s.value,
                .percent => s.value * parent_len,
                .grow => span,
                .hug, .measured => if (lo_v != null and hi_v != null and ce.o.aspect == null) span else ce.nat[ax],
            });
            ce.len[ax] = size;
            ce.pos[ax] = if (lo_v) |v| e.pos[ax] + v else if (hi_v) |v| e.pos[ax] + parent_len - v - size else e.pos[ax];
        }
    }
};

/// API misuse (unbalanced begin/end, too deep, too many items) asserts in Debug builds only;
/// every other mode carries on safely.
fn misuse(ok: bool) void {
    if (@import("builtin").mode == .debug) std.debug.assert(ok);
}

/// Snaps a coordinate to a whole point (`floor(v + 0.5)`, so shifting by whole points
/// commutes with snapping).
fn snap(v: f32) f32 {
    return @floor(v + 0.5);
}

// ---- sugar: one level, no tree ----------------------------------------------------------

/// Most items `row`, `col` and the named variants lay out at once.
pub const max_sugar_items = 48;

fn flat(dir: Dir, area: Rect, opts: Opts, sizes: []const Size, out: []Rect) void {
    var buf: [max_sugar_items + 1]Entry = undefined;
    var lay = Layout.initBuffer(&buf);
    var o = opts;
    o.dir = dir;
    o.w = .fixed(area.w);
    o.h = .fixed(area.h);
    o.min_w = 0;
    o.min_h = 0;
    o.max_w = inf;
    o.max_h = inf;
    o.scroll = .none;
    o.position = .flow;
    misuse(sizes.len <= max_sugar_items);
    misuse(out.len == sizes.len); // a length mismatch is a caller bug: loud in Debug, tolerated otherwise
    const n = @min(sizes.len, max_sugar_items);
    var nodes: [max_sugar_items]Node = undefined;
    // A wrapped line is as tall as its tallest item (0 for `.grow`), so the items get a height
    // of their own: all of `area` first, then, if that made several lines, the lines' share of it.
    const wraps = dir == .row and opts.wrap;
    var line_h: f32 = area.h;
    var pass: u32 = 0;
    while (true) : (pass += 1) {
        lay.reset();
        _ = lay.begin(o);
        for (sizes[0..n], 0..) |s, i| {
            nodes[i] = lay.leaf(if (dir == .row) .{ .w = s, .h = if (wraps) .fixed(line_h) else .grow(1) } else .{ .w = .grow(1), .h = s });
        }
        lay.end();
        lay.solve(area);
        if (!wraps or pass > 0 or n == 0) break;
        const lines: f32 = @floatFromInt(@max(1, lay.nodes.items[0].lines));
        if (lines <= 1) break;
        line_h = @max(0, (area.h - (opts.line_gap orelse opts.gap) * (lines - 1)) / lines);
    }
    for (out, 0..) |*r, i| r.* = if (i < n) lay.rect(nodes[i]) else .{ .x = area.x, .y = area.y, .w = 0, .h = 0 };
}

/// `out.len` must equal `sizes.len` (asserted in Debug; in other modes extra rects come back
/// empty and missing ones are dropped).
/// Lays `sizes` out left to right inside `area` and writes their rectangles to `out`
/// (each as tall as `area`). `opts` supplies `gap`, `padding`, `main` and `wrap`; its sizes are
/// ignored. A `.hug` size is 0 wide here; use `.measured` for content-sized items.
pub fn row(area: Rect, opts: Opts, sizes: []const Size, out: []Rect) void {
    flat(.row, area, opts, sizes, out);
}

/// Like `row`, top to bottom, each item as wide as `area`.
pub fn col(area: Rect, opts: Opts, sizes: []const Size, out: []Rect) void {
    flat(.col, area, opts, sizes, out);
}

/// A struct with a `Rect` field for every field of `T`.
pub fn Named(comptime T: type) type {
    const names = std.meta.fieldNames(T);
    var types: [names.len]type = undefined;
    var attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (0..names.len) |i| {
        types[i] = Rect;
        attrs[i] = .{};
    }
    return @Struct(.auto, null, names, &types, &attrs);
}

fn flatNamed(dir: Dir, area: Rect, opts: Opts, sizes: anytype) Named(@TypeOf(sizes)) {
    const names = comptime std.meta.fieldNames(@TypeOf(sizes));
    var list: [names.len]Size = undefined;
    inline for (names, 0..) |name, i| list[i] = @field(sizes, name);
    var rects: [names.len]Rect = undefined;
    flat(dir, area, opts, &list, &rects);
    var out: Named(@TypeOf(sizes)) = undefined;
    inline for (names, 0..) |name, i| @field(out, name) = rects[i];
    return out;
}

/// `row` with names: `const r = rowNamed(area, .{}, .{ .icon = fixed(32), .title = grow(1) });`
/// returns a struct with `r.icon` and `r.title` rectangles. (Write the sizes as
/// `layout.fixed(32)` or `Size.fixed(32)`: a bare `.fixed(32)` has no type to resolve against.)
pub fn rowNamed(area: Rect, opts: Opts, sizes: anytype) Named(@TypeOf(sizes)) {
    return flatNamed(.row, area, opts, sizes);
}

/// `col` with names.
pub fn colNamed(area: Rect, opts: Opts, sizes: anytype) Named(@TypeOf(sizes)) {
    return flatNamed(.col, area, opts, sizes);
}

// ---- tests ----------------------------------------------------------------------------

const testing = std.testing;
const expectEqual = testing.expectEqual;

fn expectRect(want: Rect, got: Rect) !void {
    try expectEqual(want.x, got.x);
    try expectEqual(want.y, got.y);
    try expectEqual(want.w, got.w);
    try expectEqual(want.h, got.h);
}

fn r4(x: f32, y: f32, w: f32, h: f32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

const area100: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };

test "fixed and grow distribute with weights" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .w = .grow(1), .h = .grow(1), .gap = 5 });
    const a = lay.leaf(.{ .w = .fixed(20) });
    const b = lay.leaf(.{ .w = .grow(1) });
    const c = lay.leaf(.{ .w = .grow(3) });
    lay.end();
    lay.solve(area100);
    // 100 - 20 - 2 gaps of 5 = 70 shared 1:3 (17.5 and 52.5), snapped on edges.
    try expectRect(r4(0, 0, 20, 50), lay.rect(a));
    try expectEqual(@as(f32, 25), lay.rect(b).x);
    const bw = lay.rect(b).w;
    const cw = lay.rect(c).w;
    try testing.expect(bw >= 17 and bw <= 18 and cw >= 52 and cw <= 53);
    try expectEqual(@as(f32, 100), lay.rect(c).x + cw);
    try expectEqual(@as(f32, 50), lay.rect(c).h);
}

test "percent of the parent's content box" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .w = .grow(1), .h = .grow(1), .padding = .all(10), .dir = .row });
    const a = lay.leaf(.{ .w = .percent(0.5), .h = .percent(0.5) });
    lay.end();
    lay.solve(.{ .x = 0, .y = 0, .w = 120, .h = 60 });
    try expectRect(r4(10, 10, 50, 20), lay.rect(a));
}

test "min and max clamps redistribute the leftover" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .w = .grow(1), .h = .grow(1) });
    const a = lay.leaf(.{ .w = .grow(1), .max_w = 20 });
    const b = lay.leaf(.{ .w = .grow(1) });
    const c = lay.leaf(.{ .w = .grow(1), .min_w = 50 });
    lay.end();
    lay.solve(area100);
    // c is frozen at 50, a at its max of 20, b takes the remaining 30.
    try expectEqual(@as(f32, 20), lay.rect(a).w);
    try expectEqual(@as(f32, 30), lay.rect(b).w);
    try expectEqual(@as(f32, 50), lay.rect(c).w);
}

test "hug container is its children plus padding and gaps" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    const root = lay.begin(.{ .dir = .col });
    const box = lay.begin(.{ .dir = .row, .padding = .xy(7, 3), .gap = 4 });
    _ = lay.leaf(.{ .w = .fixed(10), .h = .fixed(8) });
    _ = lay.leaf(.{ .w = .fixed(20), .h = .fixed(12) });
    lay.end();
    lay.end();
    lay.solve(area100);
    _ = root;
    // The box is a stretch child of a col: full width, but hug height = 12 + 2 * 3.
    try expectEqual(@as(f32, 18), lay.rect(box).h);
    // A hug container's contentSize is its natural size.
    try expectEqual(@as(f32, 7 + 10 + 4 + 20 + 7), lay.contentSize(box).w);
}

test "hug width" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .col, .cross = .start });
    const box = lay.begin(.{ .dir = .row, .padding = .all(5), .gap = 2, .cross = .start });
    _ = lay.leaf(.{ .w = .fixed(10), .h = .fixed(8) });
    _ = lay.leaf(.{ .w = .fixed(20), .h = .fixed(12) });
    lay.end();
    lay.end();
    lay.solve(area100);
    try expectRect(r4(0, 0, 42, 22), lay.rect(box));
}

test "nested row in col in row" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .row, .w = .grow(1), .h = .grow(1), .gap = 10 });
    const side = lay.leaf(.{ .w = .fixed(30) });
    _ = lay.begin(.{ .dir = .col, .w = .grow(1), .gap = 4 });
    const top = lay.leaf(.{ .h = .fixed(10) });
    _ = lay.begin(.{ .dir = .row, .h = .grow(1), .gap = 6 });
    const l1 = lay.leaf(.{ .w = .grow(1) });
    const l2 = lay.leaf(.{ .w = .grow(1) });
    lay.end();
    lay.end();
    lay.end();
    lay.solve(.{ .x = 5, .y = 5, .w = 110, .h = 54 });
    try expectRect(r4(5, 5, 30, 54), lay.rect(side));
    try expectRect(r4(45, 5, 70, 10), lay.rect(top));
    try expectRect(r4(45, 19, 32, 40), lay.rect(l1));
    try expectRect(r4(83, 19, 32, 40), lay.rect(l2));
}

test "cross alignment, stretch and align_self" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .row, .w = .fixed(100), .h = .fixed(40), .cross = .center });
    const a = lay.leaf(.{ .w = .fixed(10), .h = .fixed(10) });
    const b = lay.leaf(.{ .w = .fixed(10), .h = .grow(1) });
    const c = lay.leaf(.{ .w = .fixed(10), .h = .fixed(10), .align_self = .end });
    const d = lay.leaf(.{ .w = .fixed(10), .h = .fixed(10), .align_self = .start });
    const e = lay.leaf(.{ .w = .fixed(10), .align_self = .stretch });
    lay.end();
    lay.solve(area100);
    try expectEqual(@as(f32, 15), lay.rect(a).y);
    try expectRect(r4(10, 0, 10, 40), lay.rect(b));
    try expectEqual(@as(f32, 30), lay.rect(c).y);
    try expectEqual(@as(f32, 0), lay.rect(d).y);
    try expectEqual(@as(f32, 40), lay.rect(e).h);
}

test "justification modes" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    const modes = [_]Justify{ .start, .center, .end, .space_between };
    const want_x = [_][3]f32{ .{ 0, 20, 40 }, .{ 20, 40, 60 }, .{ 40, 60, 80 }, .{ 0, 40, 80 } };
    for (modes, want_x) |m, wx| {
        lay.reset();
        _ = lay.begin(.{ .w = .fixed(100), .h = .fixed(10), .main = m });
        const a = lay.leaf(.{ .w = .fixed(20) });
        const b = lay.leaf(.{ .w = .fixed(20) });
        const c = lay.leaf(.{ .w = .fixed(20) });
        lay.end();
        lay.solve(area100);
        try expectEqual(wx[0], lay.rect(a).x);
        try expectEqual(wx[1], lay.rect(b).x);
        try expectEqual(wx[2], lay.rect(c).x);
    }
    // space_between with one child starts it at the start.
    lay.reset();
    _ = lay.begin(.{ .w = .fixed(100), .h = .fixed(10), .main = .space_between });
    const only = lay.leaf(.{ .w = .fixed(20) });
    lay.end();
    lay.solve(area100);
    try expectEqual(@as(f32, 0), lay.rect(only).x);
}

test "wrap breaks lines and the container hugs their height" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .col, .w = .grow(1), .cross = .stretch });
    const chips = lay.begin(.{ .dir = .row, .wrap = true, .gap = 4, .line_gap = 6 });
    var ids: [5]Node = undefined;
    for (&ids) |*id| id.* = lay.leaf(.{ .w = .fixed(30), .h = .fixed(10) });
    lay.end();
    lay.end();
    lay.solve(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    // 30 + 4 + 30 + 4 + 30 = 98 fits three per line; two lines: 10 + 6 + 10 = 26.
    try expectRect(r4(0, 0, 30, 10), lay.rect(ids[0]));
    try expectRect(r4(68, 0, 30, 10), lay.rect(ids[2]));
    try expectRect(r4(0, 16, 30, 10), lay.rect(ids[3]));
    try expectRect(r4(34, 16, 30, 10), lay.rect(ids[4]));
    try expectEqual(@as(f32, 26), lay.rect(chips).h);
}

const TextBox = struct {
    chars: f32,
    fn measure(ctx: ?*anyopaque, max_w: f32) Extent {
        const t: *const TextBox = @ptrCast(@alignCast(ctx.?));
        const full = t.chars * 6; // 6 pt per character, 10 pt lines
        if (!std.math.isFinite(max_w) or full <= max_w) return .{ .w = full, .h = 10 };
        const per_line = @max(1, @floor(max_w / 6));
        return .{ .w = per_line * 6, .h = 10 * @ceil(t.chars / per_line) };
    }
};

test "measured leaf: height for width drives the parent's hug height" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    var tb: TextBox = .{ .chars = 50 }; // 300 pt on one line
    _ = lay.begin(.{ .dir = .col, .w = .fixed(60) });
    const card = lay.begin(.{ .dir = .col, .padding = .all(4) });
    const text = lay.leaf(.{ .w = .grow(1), .h = .measured(&tb, TextBox.measure) });
    lay.end();
    lay.end();
    lay.solve(area100);
    // Inner width 52 -> 8 chars per line -> 7 lines of 10 pt.
    try expectEqual(@as(f32, 52), lay.rect(text).w);
    try expectEqual(@as(f32, 70), lay.rect(text).h);
    try expectEqual(@as(f32, 78), lay.rect(card).h);
}

test "measured on both axes gives a content-sized leaf" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    var tb: TextBox = .{ .chars = 5 };
    _ = lay.begin(.{ .dir = .row, .cross = .start });
    const t = lay.leaf(.{ .w = .measured(&tb, TextBox.measure), .h = .measured(&tb, TextBox.measure) });
    lay.end();
    lay.solve(area100);
    try expectRect(r4(0, 0, 30, 10), lay.rect(t));
}

test "aspect ratio" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .col, .cross = .start });
    const a = lay.leaf(.{ .w = .fixed(80), .aspect = 2 });
    const b = lay.leaf(.{ .h = .fixed(30), .aspect = 0.5 });
    lay.end();
    lay.solve(area100);
    try expectRect(r4(0, 0, 80, 40), lay.rect(a));
    try expectRect(r4(0, 40, 15, 30), lay.rect(b));
}

test "absolute children are out of flow" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    const root = lay.begin(.{ .dir = .row, .w = .fixed(100), .h = .fixed(50), .padding = .all(10) });
    const a = lay.leaf(.{ .w = .fixed(20), .h = .fixed(20) });
    const badge = lay.leaf(.{ .position = .absolute, .w = .fixed(10), .h = .fixed(10), .inset = .{ .right = 2, .top = 3 } });
    const veil = lay.leaf(.{ .position = .absolute, .inset = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 } });
    const b = lay.leaf(.{ .w = .fixed(20), .h = .fixed(20) });
    lay.end();
    lay.solve(area100);
    try expectEqual(@as(f32, 10), lay.rect(a).x);
    try expectEqual(@as(f32, 30), lay.rect(b).x); // the badge took no room
    try expectRect(r4(88, 3, 10, 10), lay.rect(badge));
    try expectRect(r4(0, 0, 100, 50), lay.rect(veil));
    try expectEqual(@as(f32, 0), lay.overflow(root).w);
}

test "scroll container: contentSize, unbounded height, scrollTo" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .col, .w = .grow(1), .h = .grow(1) });
    const sc = lay.begin(.{ .dir = .col, .h = .fixed(50), .scroll = .y, .gap = 2, .padding = .all(3) });
    var items: [10]Node = undefined;
    for (&items) |*it| it.* = lay.leaf(.{ .h = .fixed(10) });
    lay.end();
    lay.end();
    lay.solve(.{ .x = 0, .y = 0, .w = 100, .h = 200 });
    try expectEqual(@as(f32, 50), lay.rect(sc).h);
    // 10 * 10 + 9 * 2 + 2 * 3
    try expectEqual(@as(f32, 124), lay.contentSize(sc).h);
    try expectEqual(@as(f32, 74), lay.overflow(sc).h);
    try expectEqual(@as(f32, 3 + 9 * 12), lay.rect(items[9]).y);
    lay.scrollTo(sc, 0, 20);
    try expectEqual(@as(f32, 3 - 20), lay.rect(items[0]).y);
    try expectEqual(@as(f32, 50), lay.rect(sc).h);
    // The children of a scroll container are as wide as its content box.
    try expectEqual(@as(f32, 94), lay.rect(items[0]).w);
}

test "scrolling content hugging inside a max_h container" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .col, .cross = .start });
    const sc = lay.begin(.{ .dir = .col, .w = .fixed(40), .max_h = 25, .scroll = .y });
    _ = lay.leaf(.{ .h = .fixed(20) });
    _ = lay.leaf(.{ .h = .fixed(20) });
    lay.end();
    lay.end();
    lay.solve(area100);
    try expectEqual(@as(f32, 25), lay.rect(sc).h);
    try expectEqual(@as(f32, 40), lay.contentSize(sc).h);
}

test "overflow is reported and fixed children do not shrink" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    const root = lay.begin(.{ .w = .fixed(100), .h = .fixed(20), .gap = 10 });
    const a = lay.leaf(.{ .w = .fixed(60) });
    const b = lay.leaf(.{ .w = .fixed(60) });
    lay.end();
    lay.solve(area100);
    try expectEqual(@as(f32, 60), lay.rect(a).w);
    try expectEqual(@as(f32, 70), lay.rect(b).x);
    try expectEqual(@as(f32, 30), lay.overflow(root).w);
    try expectEqual(@as(f32, 0), lay.overflow(root).h);
}

test "shrink only for children that ask, and not below min" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    const root = lay.begin(.{ .w = .fixed(100), .h = .fixed(20) });
    const a = lay.leaf(.{ .w = .fixed(80), .shrink = 1, .min_w = 70 });
    const b = lay.leaf(.{ .w = .fixed(80), .shrink = 1 });
    const c = lay.leaf(.{ .w = .fixed(40) });
    lay.end();
    lay.solve(area100);
    // Overflow 100: a would lose 50 but stops at its min of 70, b gives up everything it can
    // (down to 0), c never shrinks. 10 points still overflow and are reported.
    try expectEqual(@as(f32, 70), lay.rect(a).w);
    try expectEqual(@as(f32, 0), lay.rect(b).w);
    try expectEqual(@as(f32, 40), lay.rect(c).w);
    try expectEqual(@as(f32, 10), lay.overflow(root).w);
}

test "shrink splits the overflow in proportion" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .w = .fixed(100), .h = .fixed(20) });
    const a = lay.leaf(.{ .w = .fixed(90), .shrink = 1 });
    const b = lay.leaf(.{ .w = .fixed(30), .shrink = 1 });
    lay.end();
    lay.solve(area100);
    // Overflow 20, shared 3:1 by size: a loses 15, b loses 5.
    try expectEqual(@as(f32, 75), lay.rect(a).w);
    try expectEqual(@as(f32, 25), lay.rect(b).w);
}

test "grow children add up exactly to the content extent" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    var w: f32 = 30;
    while (w < 300) : (w += 13) {
        lay.reset();
        _ = lay.begin(.{ .w = .fixed(w), .h = .fixed(10), .gap = 3, .padding = .all(2) });
        var ids: [7]Node = undefined;
        for (&ids, 0..) |*id, k| id.* = lay.leaf(.{ .w = .grow(@floatFromInt(k + 1)) });
        lay.end();
        lay.solve(.{ .x = 0, .y = 0, .w = 400, .h = 10 });
        var sum: f32 = 0;
        for (ids, 0..) |id, k| {
            sum += lay.rect(id).w;
            if (k > 0) {
                const prev = lay.rect(ids[k - 1]);
                try expectEqual(prev.x + prev.w + 3, lay.rect(id).x); // no gap or overlap beyond the declared one
            }
        }
        // Content extent = w - 4; with all grow children and whole gaps they add up exactly.
        try expectEqual(w - 4 - 6 * 3, sum);
        try expectEqual(w - 2, lay.rect(ids[6]).x + lay.rect(ids[6]).w);
    }
}

test "zero-size, negative and empty inputs" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    // Empty layout.
    lay.solve(area100);
    try expectRect(r4(0, 0, 0, 0), lay.rect(.none));
    // Empty container, zero and negative areas, NaN.
    _ = lay.begin(.{ .padding = .all(10), .w = .grow(1), .h = .grow(1) });
    const k = lay.leaf(.{ .w = .grow(1), .h = .grow(1) });
    lay.end();
    lay.solve(.{ .x = 0, .y = 0, .w = 0, .h = 0 });
    try expectRect(r4(10, 10, 0, 0), lay.rect(k));
    lay.solve(.{ .x = 0, .y = 0, .w = -5, .h = std.math.nan(f32) });
    try expectEqual(@as(f32, 0), lay.rect(k).w);
    try testing.expect(!std.math.isNan(lay.rect(k).h));
    lay.reset();
    const e = lay.begin(.{ .dir = .col });
    lay.end();
    lay.solve(area100);
    try expectEqual(@as(f32, 0), lay.rect(e).h);
    try expectEqual(@as(f32, 0), lay.contentSize(e).w);
    // Nonsense options stay finite.
    lay.reset();
    const n = lay.leaf(.{ .w = .fixed(std.math.nan(f32)), .h = .grow(-3), .min_w = std.math.nan(f32), .max_h = std.math.nan(f32), .aspect = 0 });
    lay.solve(area100);
    try testing.expect(std.math.isFinite(lay.rect(n).w) and std.math.isFinite(lay.rect(n).h));
}

test "named sugar returns the right fields" {
    const r = rowNamed(.{ .x = 10, .y = 20, .w = 200, .h = 30 }, .{ .gap = 8 }, .{
        .icon = fixed(32),
        .title = grow(1),
        .close = Size.fixed(32),
    });
    try expectRect(r4(10, 20, 32, 30), r.icon);
    try expectRect(r4(50, 20, 120, 30), r.title);
    try expectRect(r4(178, 20, 32, 30), r.close);
    const c = colNamed(.{ .x = 0, .y = 0, .w = 50, .h = 100 }, .{ .padding = .all(5) }, .{ .a = fixed(20), .b = grow(1), .c = grow(1) });
    try expectRect(r4(5, 5, 40, 20), c.a);
    try expectRect(r4(5, 25, 40, 35), c.b);
    try expectRect(r4(5, 60, 40, 35), c.c);
}

test "row and col sugar fill a slice" {
    var rs: [3]Rect = undefined;
    row(.{ .x = 0, .y = 0, .w = 100, .h = 20 }, .{ .gap = 5, .main = .end }, &.{ .fixed(10), .fixed(20), .fixed(30) }, &rs);
    try expectRect(r4(30, 0, 10, 20), rs[0]);
    try expectRect(r4(45, 0, 20, 20), rs[1]);
    try expectRect(r4(70, 0, 30, 20), rs[2]);
    col(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, .{}, &.{ .percent(0.25), .grow(1), .grow(3) }, &rs);
    try expectRect(r4(0, 0, 100, 25), rs[0]);
    try expectRect(r4(0, 25, 100, 19), rs[1]);
    try expectRect(r4(0, 44, 100, 56), rs[2]);
    // A length mismatch asserts in Debug; elsewhere extra rects are empty.
    if (@import("builtin").mode != .debug) {
        var five: [5]Rect = undefined;
        row(area100, .{}, &.{.grow(1)}, &five);
        try expectEqual(@as(f32, 100), five[0].w);
        try expectEqual(@as(f32, 0), five[4].w);
    }
}

test "unbalanced begin and end are safe in release" {
    if (@import("builtin").mode == .debug) return error.SkipZigTest; // asserts there instead
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    lay.end(); // too many ends
    _ = lay.begin(.{});
    _ = lay.leaf(.{});
    lay.solve(area100); // missing end
    lay.reset();
}

test "random trees: siblings never overlap on the main axis and stay in their parent" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    for (0..300) |_| {
        lay.reset();
        const w = @as(f32, @floatFromInt(rnd.intRangeAtMost(u32, 0, 400)));
        const h = @as(f32, @floatFromInt(rnd.intRangeAtMost(u32, 0, 400)));
        var tb: TextBox = .{ .chars = @floatFromInt(rnd.intRangeAtMost(u32, 1, 60)) };
        try randomTree(&lay, rnd, 0, &tb);
        lay.solve(.{ .x = 3, .y = 4, .w = w, .h = h });
        for (0..lay.count()) |i| try checkNode(&lay, i);
    }
}

fn randomSize(rnd: std.Random, tb: *TextBox) Size {
    return switch (rnd.intRangeAtMost(u8, 0, 5)) {
        0 => .fixed(@floatFromInt(rnd.intRangeAtMost(u32, 0, 90))),
        1 => .grow(@floatFromInt(rnd.intRangeAtMost(u32, 1, 4))),
        2 => .percent(@as(f32, @floatFromInt(rnd.intRangeAtMost(u32, 0, 10))) / 10),
        3 => .measured(tb, TextBox.measure),
        else => .hug,
    };
}

fn randomOpts(rnd: std.Random, tb: *TextBox) Opts {
    var o: Opts = .{
        .w = randomSize(rnd, tb),
        .h = randomSize(rnd, tb),
        .dir = if (rnd.boolean()) .row else .col,
        .gap = @floatFromInt(rnd.intRangeAtMost(u32, 0, 9)),
        .padding = .xy(@floatFromInt(rnd.intRangeAtMost(u32, 0, 9)), @floatFromInt(rnd.intRangeAtMost(u32, 0, 9))),
        .main = rnd.enumValue(Justify),
        .cross = rnd.enumValue(Align),
        .wrap = rnd.boolean(),
        .shrink = if (rnd.boolean()) 1 else 0,
    };
    if (rnd.intRangeAtMost(u8, 0, 4) == 0) o.min_w = @floatFromInt(rnd.intRangeAtMost(u32, 0, 40));
    if (rnd.intRangeAtMost(u8, 0, 4) == 0) o.max_w = @floatFromInt(rnd.intRangeAtMost(u32, 0, 80));
    if (rnd.intRangeAtMost(u8, 0, 4) == 0) o.max_h = @floatFromInt(rnd.intRangeAtMost(u32, 0, 80));
    return o;
}

fn randomTree(lay: *Layout, rnd: std.Random, depth: u32, tb: *TextBox) !void {
    _ = lay.begin(randomOpts(rnd, tb));
    const n = rnd.intRangeAtMost(u32, 0, 5);
    for (0..n) |_| {
        if (depth < 3 and rnd.intRangeAtMost(u8, 0, 2) == 0) try randomTree(lay, rnd, depth + 1, tb) else {
            var o = randomOpts(rnd, tb);
            o.dir = .row;
            _ = lay.leaf(o);
        }
    }
    lay.end();
}

fn checkNode(lay: *const Layout, idx: usize) !void {
    const e = &lay.nodes.items[idx];
    const r = e.rect;
    try testing.expect(std.math.isFinite(r.x) and std.math.isFinite(r.y) and std.math.isFinite(r.w) and std.math.isFinite(r.h));
    try testing.expect(r.w >= 0 and r.h >= 0);
    try expectEqual(@floor(r.x), r.x);
    try expectEqual(@floor(r.w), r.w);
    if (e.first == none_idx) return;
    const ov = lay.overflow(@enumFromInt(idx));
    const main = Layout.dirAxis(e);
    var prev_end: f32 = -inf;
    var prev_line: u32 = 0;
    var c = e.first;
    while (c != none_idx) : (c = lay.nodes.items[c].next) {
        const ce = &lay.nodes.items[c];
        if (ce.o.position != .flow) continue;
        const cr = ce.rect;
        // Siblings of one line never overlap on the main axis.
        const lo = if (main == 0) cr.x else cr.y;
        if (c != e.first and ce.line == prev_line) try testing.expect(lo >= prev_end);
        prev_end = lo + (if (main == 0) cr.w else cr.h);
        prev_line = ce.line;
        // Children are inside the parent unless the parent reports overflow.
        const inside = cr.x >= r.x and cr.y >= r.y and cr.x + cr.w <= r.x + r.w and cr.y + cr.h <= r.y + r.h;
        if (!inside) try testing.expect(ov.w > 0 or ov.h > 0);
    }
}

// ---- audit fixes -------------------------------------------------------------------------

test "P8: row and col sugar with wrap give each line a share of the area, not zero height" {
    var out: [2]Rect = undefined;
    row(.{ .x = 0, .y = 0, .w = 100, .h = 40 }, .{ .wrap = true }, &.{ fixed(60), fixed(60) }, &out);
    try testing.expect(out[0].h > 0 and out[1].h > 0);
    try expectRect(r4(0, 0, 60, 20), out[0]);
    try expectRect(r4(0, 20, 60, 20), out[1]);
    // One line: as tall as the area, as before.
    row(.{ .x = 0, .y = 0, .w = 200, .h = 40 }, .{ .wrap = true }, &.{ fixed(60), fixed(60) }, &out);
    try expectRect(r4(0, 0, 60, 40), out[0]);
    try expectRect(r4(60, 0, 60, 40), out[1]);
}

test "P9: a grow-width aspect leaf in a column takes the column's width and derives its height" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .col, .w = .grow(1), .h = .grow(1) });
    const a = lay.leaf(.{ .w = .grow(1), .aspect = 16.0 / 9.0 });
    lay.end();
    lay.solve(.{ .x = 0, .y = 0, .w = 160, .h = 300 });
    try expectRect(r4(0, 0, 160, 90), lay.rect(a));
}

test "P10: line breaking uses the sizes after min and max" {
    var lay = Layout.init(testing.allocator);
    defer lay.deinit();
    _ = lay.begin(.{ .dir = .row, .wrap = true, .w = .fixed(200), .h = .hug });
    const a = lay.leaf(.{ .w = .fixed(50), .min_w = 90, .h = .fixed(10) });
    _ = lay.leaf(.{ .w = .fixed(50), .min_w = 90, .h = .fixed(10) });
    const c = lay.leaf(.{ .w = .fixed(50), .min_w = 90, .h = .fixed(10) });
    lay.end();
    lay.solve(.{ .x = 0, .y = 0, .w = 200, .h = 100 });
    try expectEqual(@as(f32, 0), lay.rect(a).y);
    try expectEqual(@as(f32, 10), lay.rect(c).y);
    try expectEqual(@as(f32, 90), lay.rect(c).w);
}
