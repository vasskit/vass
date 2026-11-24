//! A retained layout of one block of styled text, wrapped to a width: build it once with `init`,
//! then query it and draw it as often as needed. A rich-text editor keeps one per block and
//! width instead of re-wrapping every frame. Pure layout: text is measured through a `Measurer`,
//! nothing here knows about windows or the `Ui`.
//!
//! The text is a sequence of `Run`s (a style, a size, a colour and an opaque tag each). The
//! result is `lines`, each holding `segments`: the maximal piece of one run on one line, with
//! the position to pass to `DisplayList.textStyled` so that all segments of a line share one
//! baseline. Positions are relative to the paragraph's top-left corner.
//!
//! Line breaking is deliberately simple (see `Line breaking` below), not UAX #14, and the text is
//! laid out left to right and left aligned: there is no bidirectional reordering, so right-to-left
//! scripts are not supported.
//!
//! Line breaking:
//!   * A break is allowed after a run of spaces, after a `-` that sits between two letters or
//!     digits, and between two CJK characters (Han, Hiragana, Katakana, Hangul syllables, CJK
//!     and fullwidth punctuation). A closing mark (full stop, comma, closing bracket, the
//!     prolonged sound mark, small kana) never starts a line and an opening bracket never ends
//!     one, so those stay with their neighbour. "Letter or digit" is ASCII, or any code point at
//!     or above U+00C0 outside punctuation, symbol and emoji blocks.
//!   * `'\n'` (or `"\r\n"`) ends a line; a trailing one gives a final empty line. A tab is a space
//!     (the copy of the text kept here has them replaced).
//!   * Spaces at a soft wrap hang: they belong to the upper line's byte range but not to its
//!     width, segments or drawing, and the next line starts at the first non-space. Spaces at the
//!     start of a block or line, and at the end of the text or before a newline, are ordinary
//!     text (a caret after them has to move), so a line may end up wider than the wrap width by
//!     those spaces.
//!   * A word longer than the width starts a line of its own and is cut between grapheme
//!     clusters, at least one cluster per line. A change of run inside a word is not a break.
//!   * Widths of words are summed from their pieces and decide where lines break; the width of a
//!     segment is then measured on its whole string, as `textStyled` draws it, so a line can be a
//!     hair wider than the wrap width where kerning across words differs from the sum.
//!
//! Cost: layout calls the measurer once per piece of a word that lies in one run, once per run for
//! the width of a space, and once per segment, which is linear in the text; it never measures a
//! growing prefix of the paragraph. Cutting an over-long word probes prefixes of it: a cut costs
//! O(log of the piece length) probes, each one call per run the prefix spans, and each call
//! measures a prefix up to the length of the piece cut off, so a word of n bytes costs about
//! n log(line length) bytes measured plus one measure of the whole word. A caret query makes at
//! most one call and a hit test O(log n) calls (n the segment length), both on one segment.
//! `draw` makes none.
//!
//! Every offset taken or returned is a byte offset on a grapheme cluster boundary; an offset
//! given from inside a cluster snaps to the cluster's start.
const std = @import("std");
const builtin = @import("builtin");
const gfx = @import("../core/gfx.zig");
const geom = @import("../core/geom.zig");
const grapheme = @import("grapheme.zig");

const Paragraph = @This();
const Allocator = std.mem.Allocator;
pub const Rect = geom.Rect;
pub const Color = geom.Color;

/// Owned copy of the text (tabs replaced by spaces; same length as the input).
text: []const u8,
lines: []const Line,
segments: []const Segment,
/// Total height: the bottom of the last line.
height: f32,
/// The paragraph's size (`Options.size`).
size: f32,

/// How `init` measures text. `ctx` is handed back to both functions.
pub const Measurer = struct {
    ctx: ?*anyopaque,
    measureFn: *const fn (ctx: ?*anyopaque, str: []const u8, size: f32, style: gfx.TextStyle) f32,
    metricsFn: *const fn (ctx: ?*anyopaque, size: f32, style: gfx.TextStyle) gfx.FontMetrics,

    fn measure(m: Measurer, str: []const u8, size: f32, style: gfx.TextStyle) f32 {
        return m.measureFn(m.ctx, str, size, style);
    }

    fn metrics(m: Measurer, size: f32, style: gfx.TextStyle) gfx.FontMetrics {
        return m.metricsFn(m.ctx, size, style);
    }
};

pub const Run = struct {
    /// Bytes. The runs cover the text in order and their lengths sum to its length. A boundary
    /// inside a code point or a grapheme cluster is moved to the cluster's end: a cluster belongs
    /// entirely to the run it starts in, so a combining mark never draws apart from its base. (A
    /// stray byte of invalid UTF-8 is a cluster of its own.) An empty run is allowed; only a
    /// last one matters, for an empty line at the end (see `init`).
    len: u32,
    style: gfx.TextStyle = .{},
    /// Null: the paragraph's size.
    size: ?f32 = null,
    color: Color,
    /// Opaque, handed back on the segments cut from this run.
    tag: u32 = 0,
};

pub const Options = struct {
    size: f32,
    /// Wrap width in points; zero, negative or infinite means no wrapping.
    width: f32,
    /// Multiplies each line's natural height.
    line_spacing: f32 = 1.0,
};

pub const Error = error{
    /// `Options.size`, `Options.line_spacing` or a run's `size` is not a positive finite number.
    InvalidOptions,
    /// The run lengths do not add up to the text length.
    RunLengthMismatch,
    OutOfMemory,
};

/// Which side of a soft wrap an offset belongs to: the end of the upper line (`upstream`) or the
/// start of the lower one (`downstream`). Everywhere else it makes no difference.
pub const Affinity = enum { upstream, downstream };

pub const Hit = struct { offset: usize, affinity: Affinity };

pub const Line = struct {
    /// Top of the line and its height, in whole points.
    y: f32,
    height: f32,
    /// From the line's top.
    baseline: f32,
    /// Byte range. Ranges of consecutive lines meet: a line ends where the next starts. It
    /// includes hanging spaces and, for a hard break, the newline.
    start: usize,
    end: usize,
    /// Width of the text that is drawn (hanging spaces excluded).
    width: f32,
    first_segment: u32,
    segment_count: u32,
    /// The line ends with a newline.
    hard_break: bool,
};

pub const Segment = struct {
    line: u32,
    /// Position to hand to `textStyled` (`y` puts every segment of the line on the line's
    /// baseline).
    x: f32,
    y: f32,
    /// Measured width of the whole string.
    width: f32,
    /// Byte range of the text drawn; never empty and never includes hanging spaces.
    start: usize,
    end: usize,
    run: u32,
    style: gfx.TextStyle,
    size: f32,
    color: Color,
    tag: u32,
};

const fit_eps: f32 = 0.001;

/// Lays `text` out. `runs` must cover it exactly (see `Run`). The text is copied; `runs` and the
/// measurer are not kept. An empty line takes the size and style of the run holding its newline.
/// A trailing empty line, and empty text, take the last run if it is zero-length (an editor's
/// typing style), else the run holding the last byte; with no runs at all, the paragraph's size
/// and the default style. So an empty heading block still has a heading-sized caret.
pub fn init(gpa: Allocator, m: Measurer, text: []const u8, runs: []const Run, opts: Options) Error!Paragraph {
    if (!positive(opts.size) or !positive(opts.line_spacing)) return error.InvalidOptions;
    for (runs) |r| if (r.size) |rs| if (!positive(rs)) return error.InvalidOptions;
    var total: u64 = 0;
    for (runs) |r| total += r.len;
    if (total != text.len) return error.RunLengthMismatch;

    const owned = try gpa.dupe(u8, text);
    errdefer gpa.free(owned);
    for (owned) |*c| {
        if (c.* == '\t') c.* = ' ';
    }

    var b = try Builder.init(gpa, m, owned, runs, opts);
    defer b.deinit();

    var raws: std.ArrayList(Raw) = .empty;
    defer raws.deinit(gpa);
    try b.breakLines(&raws);

    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(gpa);
    var segs: std.ArrayList(Segment) = .empty;
    errdefer segs.deinit(gpa);
    const height = try b.build(raws.items, &lines, &segs);

    const lines_s = try lines.toOwnedSlice(gpa);
    errdefer gpa.free(lines_s);
    const segs_s = try segs.toOwnedSlice(gpa);
    return .{ .text = owned, .lines = lines_s, .segments = segs_s, .height = height, .size = opts.size };
}

fn positive(v: f32) bool {
    return v > 0 and std.math.isFinite(v);
}

/// Frees everything `init` allocated, with the allocator it was given.
pub fn deinit(p: *Paragraph, gpa: Allocator) void {
    gpa.free(p.text);
    gpa.free(p.lines);
    gpa.free(p.segments);
    p.* = undefined;
}

// ---- layout -------------------------------------------------------------------------------

/// A line as the breaking pass leaves it: byte ranges only.
const Raw = struct {
    start: usize,
    end: usize,
    /// End of the text that is drawn: `end` less hanging spaces and the newline.
    vis_end: usize,
    hard: bool,
};

const Atom = struct {
    /// The unbreakable part, then the spaces after it.
    body_end: usize,
    space_end: usize,
    /// The body is spaces at the start of a line.
    lead: bool,
};

const Builder = struct {
    gpa: Allocator,
    m: Measurer,
    text: []const u8,
    runs: []const Run,
    opts: Options,
    wrap_w: f32,
    /// Start of each run; one more entry than runs, the last being the text length.
    starts: []usize,
    /// Width of one space in each run, NaN until measured.
    space_w: []f32,
    metrics: []?gfx.FontMetrics,
    default_metrics: ?gfx.FontMetrics = null,

    fn init(gpa: Allocator, m: Measurer, text: []const u8, runs: []const Run, opts: Options) Allocator.Error!Builder {
        const starts = try gpa.alloc(usize, runs.len + 1);
        errdefer gpa.free(starts);
        const space_w = try gpa.alloc(f32, runs.len);
        errdefer gpa.free(space_w);
        const metrics = try gpa.alloc(?gfx.FontMetrics, runs.len);
        var at: usize = 0;
        for (runs, 0..) |r, i| {
            starts[i] = at;
            at += r.len;
        }
        starts[runs.len] = at;
        // A cluster belongs to the run it starts in: move each boundary to the next cluster
        // boundary, walking the text once.
        var c: usize = 0;
        if (runs.len > 1) for (1..runs.len) |k| {
            while (c < starts[k]) c = nextCluster(text, c);
            starts[k] = c;
        };
        @memset(space_w, std.math.nan(f32));
        @memset(metrics, null);
        const unwrapped = !(opts.width > 0) or !std.math.isFinite(opts.width);
        return .{
            .gpa = gpa,
            .m = m,
            .text = text,
            .runs = runs,
            .opts = opts,
            .wrap_w = if (unwrapped) std.math.inf(f32) else opts.width,
            .starts = starts,
            .space_w = space_w,
            .metrics = metrics,
        };
    }

    fn deinit(b: *Builder) void {
        b.gpa.free(b.starts);
        b.gpa.free(b.space_w);
        b.gpa.free(b.metrics);
    }

    fn runSize(b: *const Builder, r: usize) f32 {
        return b.runs[r].size orelse b.opts.size;
    }

    /// The run holding the byte at `off` (which must be inside the text).
    fn runAt(b: *const Builder, off: usize) usize {
        var lo: usize = 0;
        var hi: usize = b.runs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (b.starts[mid + 1] > off) hi = mid else lo = mid + 1;
        }
        return lo;
    }

    fn metricsOf(b: *Builder, r: usize) gfx.FontMetrics {
        if (b.metrics[r]) |mt| return mt;
        const mt = b.m.metrics(b.runSize(r), b.runs[r].style);
        b.metrics[r] = mt;
        return mt;
    }

    fn defaultMetrics(b: *Builder) gfx.FontMetrics {
        if (b.default_metrics) |mt| return mt;
        const mt = b.m.metrics(b.opts.size, .{});
        b.default_metrics = mt;
        return mt;
    }

    /// Metrics for a line with no text: those of the run holding its newline; for the trailing
    /// empty line and empty text the last run if it is empty, else the run of the last byte;
    /// without runs the paragraph's.
    fn emptyLineMetrics(b: *Builder, raw: Raw) gfx.FontMetrics {
        const n = b.text.len;
        if (b.runs.len == 0) return b.defaultMetrics();
        if (raw.hard) return b.metricsOf(b.runAt(raw.vis_end));
        if (n == 0 or b.runs[b.runs.len - 1].len == 0) return b.metricsOf(b.runs.len - 1);
        return b.metricsOf(b.runAt(n - 1));
    }

    fn spaceWidth(b: *Builder, r: usize) f32 {
        if (std.math.isNan(b.space_w[r])) b.space_w[r] = b.m.measure(" ", b.runSize(r), b.runs[r].style);
        return b.space_w[r];
    }

    /// Width of the text `a..b`, summed over the pieces in each run.
    fn rangeWidth(b: *Builder, a: usize, e: usize) f32 {
        var w: f32 = 0;
        var pos = a;
        var r = if (a < e) b.runAt(a) else 0;
        while (pos < e) : (r += 1) {
            const stop = @min(e, b.starts[r + 1]);
            if (stop > pos) w += b.m.measure(b.text[pos..stop], b.runSize(r), b.runs[r].style);
            pos = @max(pos, stop);
        }
        return w;
    }

    /// Width of the spaces `a..e`: one measured space per run, times the count.
    fn spacesWidth(b: *Builder, a: usize, e: usize) f32 {
        var w: f32 = 0;
        var pos = a;
        var r = if (a < e) b.runAt(a) else 0;
        while (pos < e) : (r += 1) {
            const stop = @min(e, b.starts[r + 1]);
            if (stop > pos) w += @as(f32, @floatFromInt(stop - pos)) * b.spaceWidth(r);
            pos = @max(pos, stop);
        }
        return w;
    }

    fn bodyWidth(b: *Builder, a: usize, e: usize, lead: bool) f32 {
        return if (lead) b.spacesWidth(a, e) else b.rangeWidth(a, e);
    }

    /// The atom starting at `pos`, which is neither at the end nor at a newline. Walks clusters
    /// forward only.
    fn scanAtom(b: *const Builder, pos: usize) Atom {
        const t = b.text;
        const n = t.len;
        if (spaceAt(t, pos)) |first| {
            var e = first;
            while (spaceAt(t, e)) |nx| e = nx;
            return .{ .body_end = e, .space_end = e, .lead = true };
        }
        var prev: u21 = 0;
        var cur = decode(t, pos).cp;
        var j = nextCluster(t, pos);
        var body_end = n;
        while (j < n) {
            const k = nextCluster(t, j);
            const next = decode(t, j).cp;
            if ((k == j + 1 and t[j] == ' ') or newlineLen(t, j) > 0 or canBreak(prev, cur, next)) {
                body_end = j;
                break;
            }
            prev = cur;
            cur = next;
            j = k;
        }
        var e = body_end;
        while (spaceAt(t, e)) |nx| e = nx;
        return .{ .body_end = body_end, .space_end = e, .lead = false };
    }

    /// Where to cut the text `s..e` so that the first piece fits the wrap width, at a cluster
    /// boundary and with at least one cluster in it; `e` when all of it fits. Probes grow from
    /// the start and boundaries are found by walking forward from the last known one, so the
    /// cost follows the length of the piece, not of the word.
    fn splitPoint(b: *Builder, s: usize, e: usize, lead: bool) usize {
        const t = b.text;
        var lo = nextCluster(t, s);
        if (lo >= e) return e;
        var hi = e; // not known to fit unless the probes say so
        var step: usize = 16;
        while (true) {
            const raw = lo + step;
            if (raw >= e) {
                if (b.bodyWidth(s, e, lead) <= b.wrap_w + fit_eps) return e;
                break;
            }
            const probe = snapFrom(t, lo, raw);
            if (probe > lo) {
                if (b.bodyWidth(s, probe, lead) > b.wrap_w + fit_eps) {
                    hi = probe;
                    break;
                }
                lo = probe;
            }
            step *= 2;
        }
        while (true) {
            var mid = snapFrom(t, lo, lo + (hi - lo) / 2);
            if (mid <= lo) {
                mid = nextCluster(t, lo);
                if (mid >= hi) break;
            }
            if (b.bodyWidth(s, mid, lead) <= b.wrap_w + fit_eps) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Pass one: where the lines break, from word widths alone.
    fn breakLines(b: *Builder, raws: *std.ArrayList(Raw)) Allocator.Error!void {
        const t = b.text;
        const n = t.len;
        var line_start: usize = 0;
        var pos: usize = 0;
        var has = false; // the line has an atom on it
        var x_commit: f32 = 0; // width up to the end of the last body
        var pending: f32 = 0; // width of the spaces after it
        var vis_end: usize = 0;
        while (pos < n) {
            const nl = newlineLen(t, pos);
            if (nl > 0) {
                try raws.append(b.gpa, .{ .start = line_start, .end = pos + nl, .vis_end = pos, .hard = true });
                pos += nl;
                line_start = pos;
                has = false;
                x_commit = 0;
                pending = 0;
                continue;
            }
            const a = b.scanAtom(pos);
            var body_w = b.bodyWidth(pos, a.body_end, a.lead);
            if (has and x_commit + pending + body_w > b.wrap_w + fit_eps) {
                try raws.append(b.gpa, .{ .start = line_start, .end = pos, .vis_end = vis_end, .hard = false });
                line_start = pos;
                has = false;
                x_commit = 0;
                pending = 0;
                // The same atom goes on the new line.
            }
            if (has) {
                x_commit += pending + body_w;
            } else {
                // Alone on its line: cut it until the rest fits (or is one cluster).
                var s = pos;
                if (body_w > b.wrap_w + fit_eps) {
                    while (true) {
                        const cut = b.splitPoint(s, a.body_end, a.lead);
                        if (cut >= a.body_end) break;
                        try raws.append(b.gpa, .{ .start = s, .end = cut, .vis_end = cut, .hard = false });
                        s = cut;
                        line_start = cut;
                    }
                    body_w = b.bodyWidth(s, a.body_end, a.lead);
                }
                x_commit = body_w;
            }
            pending = b.spacesWidth(a.body_end, a.space_end);
            has = true;
            vis_end = a.body_end;
            pos = a.space_end;
        }
        try raws.append(b.gpa, .{ .start = line_start, .end = n, .vis_end = n, .hard = false });
    }

    /// Pass two: cuts every line into segments, measures them and stacks the lines. Returns the
    /// total height.
    fn build(b: *Builder, raws: []const Raw, lines: *std.ArrayList(Line), segs: *std.ArrayList(Segment)) Allocator.Error!f32 {
        try lines.ensureTotalCapacityPrecise(b.gpa, raws.len);
        var top: f32 = 0;
        for (raws, 0..) |raw, li| {
            const first = segs.items.len;
            var x: f32 = 0;
            var asc: f32 = 0;
            var desc: f32 = 0;
            var lh: f32 = 0;
            var pos = raw.start;
            while (pos < raw.vis_end) {
                const r = b.runAt(pos);
                const stop = @min(raw.vis_end, b.starts[r + 1]);
                const run = b.runs[r];
                const size = b.runSize(r);
                const w = b.m.measure(b.text[pos..stop], size, run.style);
                const mt = b.metricsOf(r);
                asc = @max(asc, mt.ascent);
                desc = @max(desc, mt.descent);
                lh = @max(lh, mt.line_height);
                try segs.append(b.gpa, .{
                    .line = @intCast(li),
                    .x = x,
                    .y = 0,
                    .width = w,
                    .start = pos,
                    .end = stop,
                    .run = @intCast(r),
                    .style = run.style,
                    .size = size,
                    .color = run.color,
                    .tag = run.tag,
                });
                x += w;
                pos = stop;
            }
            if (segs.items.len == first) {
                const mt = b.emptyLineMetrics(raw);
                asc = mt.ascent;
                desc = mt.descent;
                lh = mt.line_height;
            }
            const height = @max(1, @round(@max(asc + desc, lh) * b.opts.line_spacing));
            for (segs.items[first..]) |*s| s.y = top + asc - b.metricsOf(s.run).ascent;
            lines.appendAssumeCapacity(.{
                .y = top,
                .height = height,
                .baseline = asc,
                .start = raw.start,
                .end = raw.end,
                .width = x,
                .first_segment = @intCast(first),
                .segment_count = @intCast(segs.items.len - first),
                .hard_break = raw.hard,
            });
            top += height;
        }
        return top;
    }
};

/// Counts cluster steps, so tests can see that cost does not grow faster than the text.
var cluster_steps: usize = 0;

/// The end of the cluster starting at the boundary `i`. Clusters are only ever walked forward:
/// the grapheme module's tests at an arbitrary position count back along the text (a run of
/// flags is walked back whole), which would make layout and queries quadratic. Starting from any
/// boundary with no regional indicator counted before it is right, since an indicator that
/// follows a boundary is always the first of its pair.
fn nextCluster(t: []const u8, i: usize) usize {
    if (builtin.is_test) cluster_steps += 1;
    var after: usize = undefined;
    return grapheme.nextBoundaryCarry(t, i, 0, &after);
}

/// The last cluster boundary at or before `o`, walking forward from the boundary `from`.
fn snapFrom(t: []const u8, from: usize, o: usize) usize {
    var i = from;
    while (i < t.len) {
        const j = nextCluster(t, i);
        if (j > o) return i;
        i = j;
    }
    return i;
}

/// The end of the cluster at `i` if it is a lone space. A space that starts a longer cluster (a
/// combining mark follows) is ordinary text.
fn spaceAt(t: []const u8, i: usize) ?usize {
    if (i >= t.len or t[i] != ' ') return null;
    const j = nextCluster(t, i);
    return if (j == i + 1) j else null;
}

fn newlineLen(t: []const u8, i: usize) usize {
    if (t[i] == '\n') return 1;
    if (t[i] == '\r' and i + 1 < t.len and t[i + 1] == '\n') return 2;
    return 0;
}

const Decoded = struct { cp: u21, len: usize };

/// The code point at `i` and its length; a stray byte is one U+FFFD of length 1.
fn decode(t: []const u8, i: usize) Decoded {
    const bad: Decoded = .{ .cp = 0xFFFD, .len = 1 };
    const l: usize = std.unicode.utf8ByteSequenceLength(t[i]) catch return bad;
    if (i + l > t.len) return bad;
    const cp = std.unicode.utf8Decode(t[i..][0..l]) catch return bad;
    return .{ .cp = cp, .len = l };
}

/// Whether a break is allowed between `a` and `b`; `prev` is the code point before `a`.
fn canBreak(prev: u21, a: u21, b: u21) bool {
    if (a == '-') return isWordChar(prev) and isWordChar(b);
    return isCjk(a) and isCjk(b) and !noLineStart(b) and !noLineEnd(a);
}

fn isWordChar(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp));
    if (cp < 0xC0) return false;
    return !(cp >= 0x2000 and cp <= 0x2BFF) and !(cp >= 0x3000 and cp <= 0x303F) and
        !(cp >= 0xFE00 and cp <= 0xFE0F) and !(cp >= 0x1F000 and cp <= 0x1FAFF);
}

fn isCjk(cp: u21) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0x20000 and cp <= 0x3FFFF) or
        (cp >= 0x3040 and cp <= 0x30FF) or (cp >= 0x31F0 and cp <= 0x31FF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0x3000 and cp <= 0x303F) or
        (cp >= 0xFF00 and cp <= 0xFFEF);
}

/// Marks that must not begin a line: closing brackets, stops and commas, the prolonged sound
/// mark, iteration marks and small kana.
fn noLineStart(cp: u21) bool {
    return switch (cp) {
        0x3001, 0x3002, 0x3005, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301E, 0x301F => true,
        0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E, 0x309B, 0x309C, 0x309D, 0x309E => true,
        0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3, 0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6, 0x30FC, 0x30FD, 0x30FE => true,
        0xFF01, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D => true,
        else => false,
    };
}

/// Marks that must not end a line: opening brackets.
fn noLineEnd(cp: u21) bool {
    return switch (cp) {
        0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301D, 0xFF08, 0xFF3B, 0xFF5B => true,
        else => false,
    };
}

// ---- queries ------------------------------------------------------------------------------

/// Length of the newline that ends a hard-break line.
fn breakLen(p: *const Paragraph, l: Line) usize {
    if (l.end >= l.start + 2 and p.text[l.end - 2] == '\r') return 2;
    return 1;
}

/// The last offset at which a caret sits on line `li`: before its newline, else its end.
fn caretEnd(p: *const Paragraph, li: usize) usize {
    const l = p.lines[li];
    return if (l.hard_break) l.end - p.breakLen(l) else l.end;
}

/// End of the text drawn on a line (before hanging spaces and the newline).
fn visibleEnd(p: *const Paragraph, l: Line) usize {
    if (l.segment_count == 0) return l.start;
    return p.segments[l.first_segment + l.segment_count - 1].end;
}

fn lineSegments(p: *const Paragraph, l: Line) []const Segment {
    return p.segments[l.first_segment..][0..l.segment_count];
}

const Located = struct { li: usize, o: usize };

/// The line a caret at `offset` is drawn on and the offset moved back to the start of its
/// cluster. Boundaries are found by walking the line from its start, so the cost follows the
/// line, not the text.
fn locate(p: *const Paragraph, offset: usize, affinity: Affinity) Located {
    const raw = @min(offset, p.text.len);
    var lo: usize = 0;
    var hi: usize = p.lines.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (p.lines[mid].start <= raw) lo = mid else hi = mid;
    }
    const o = snapFrom(p.text, p.lines[lo].start, raw);
    if (affinity == .upstream and lo > 0 and p.lines[lo].start == o and !p.lines[lo - 1].hard_break) lo -= 1;
    return .{ .li = lo, .o = o };
}

/// The index of the line a caret at `offset` is drawn on.
pub fn lineOf(p: *const Paragraph, offset: usize, affinity: Affinity) usize {
    return p.locate(offset, affinity).li;
}

/// Offset of the start of the line a caret at `offset` is on.
pub fn lineStart(p: *const Paragraph, offset: usize, affinity: Affinity) usize {
    return p.lines[p.lineOf(offset, affinity)].start;
}

/// The end of the line a caret at `offset` is on: before its newline, or, at a soft wrap, the
/// end of the line (upstream).
pub fn lineEnd(p: *const Paragraph, offset: usize, affinity: Affinity) Hit {
    return p.endHit(p.lineOf(offset, affinity));
}

fn endHit(p: *const Paragraph, li: usize) Hit {
    const soft = li + 1 < p.lines.len and !p.lines[li].hard_break;
    return .{ .offset = p.caretEnd(li), .affinity = if (soft) .upstream else .downstream };
}

/// Horizontal position of a caret at `o` (a cluster boundary on line `li`).
fn caretX(p: *const Paragraph, m: Measurer, li: usize, o: usize) f32 {
    const l = p.lines[li];
    if (o <= l.start) return 0;
    if (o >= p.visibleEnd(l)) return l.width;
    for (p.lineSegments(l)) |s| {
        if (o > s.end) continue;
        if (o <= s.start) return s.x;
        if (o == s.end) return s.x + s.width;
        return s.x + m.measure(p.text[s.start..o], s.size, s.style);
    }
    return l.width;
}

/// The caret at `offset`: a zero-width rectangle as tall as its line. `affinity` chooses at a
/// soft wrap between the end of the upper line and the start of the lower one.
pub fn caretRect(p: *const Paragraph, m: Measurer, offset: usize, affinity: Affinity) Rect {
    const at = p.locate(offset, affinity);
    const l = p.lines[at.li];
    return .{ .x = p.caretX(m, at.li, at.o), .y = l.y, .w = 0, .h = l.height };
}

fn lineAtY(p: *const Paragraph, y: f32) usize {
    if (!(y > 0)) return 0;
    var lo: usize = 0;
    var hi: usize = p.lines.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (p.lines[mid].y <= y) lo = mid else hi = mid;
    }
    return lo;
}

/// The cluster edge in segment `s` nearest to `lx` points from its left side.
fn nearestInSegment(p: *const Paragraph, m: Measurer, s: Segment, lx: f32) usize {
    if (lx >= s.width) return s.end;
    if (lx <= 0) return s.start;
    const t = p.text;
    var lo = s.start;
    var hi = s.end;
    var f_lo: f32 = 0;
    var f_hi = s.width;
    while (true) {
        var mid = snapFrom(t, lo, lo + (hi - lo) / 2);
        if (mid <= lo) {
            mid = nextCluster(t, lo);
            if (mid >= hi) break;
        }
        const f = m.measure(t[s.start..mid], s.size, s.style);
        if (f <= lx) {
            lo = mid;
            f_lo = f;
        } else {
            hi = mid;
            f_hi = f;
        }
    }
    return if (lx - f_lo < f_hi - lx) lo else hi;
}

fn hitInLine(p: *const Paragraph, m: Measurer, li: usize, x: f32) Hit {
    const l = p.lines[li];
    if (l.segment_count == 0) return p.endHit(li);
    if (!(x > 0)) return .{ .offset = l.start, .affinity = .downstream };
    if (x >= l.width) return p.endHit(li);
    var seg = p.segments[l.first_segment];
    for (p.lineSegments(l)) |s| {
        if (s.x > x) break;
        seg = s;
    }
    const e = p.nearestInSegment(m, seg, x - seg.x);
    if (e >= p.visibleEnd(l)) return p.endHit(li);
    return .{ .offset = e, .affinity = .downstream };
}

/// The caret position nearest to the point (`x`, `y`): the cluster edge nearest `x` on the line
/// at `y`. A point above or below the paragraph is on its first or last line, one left or right
/// of a line is at the line's start or end (for a soft-wrapped line, its end, upstream).
pub fn offsetAt(p: *const Paragraph, m: Measurer, x: f32, y: f32) Hit {
    return p.hitInLine(m, p.lineAtY(y), x);
}

/// Rectangles covering the selection `start..end` (either order), one per line that has
/// selected text, in line order. A line's rectangle spans the selected part and reaches the
/// line's text end when the selection goes on past it; an empty line inside the selection gets
/// one a third of the paragraph's size wide so that it shows. Writes at most `out.len`
/// rectangles and returns how many there are in all.
pub fn selectionRects(p: *const Paragraph, m: Measurer, start: usize, end: usize, out: []Rect) usize {
    const first = p.locate(@min(start, end), .downstream);
    const stop = p.locate(@max(start, end), .upstream);
    const lo = first.o;
    const hi = stop.o;
    if (lo >= hi) return 0;
    var count: usize = 0;
    var li = first.li;
    const last = stop.li;
    while (li <= last) : (li += 1) {
        const l = p.lines[li];
        const a = @max(lo, l.start);
        const e = @min(hi, l.end);
        if (a >= e) continue;
        const x0 = p.caretX(m, li, a);
        var x1 = p.caretX(m, li, e);
        if (x1 <= x0) {
            // Nothing visible is selected: only the hanging spaces and an empty line get a
            // marker (at the end of the text); a newline after text gets none.
            if (l.width > 0 and !(a >= p.visibleEnd(l) and a < p.caretEnd(li))) continue;
            x1 = x0 + p.size / 3;
        }
        if (count < out.len) out[count] = .{ .x = x0, .y = l.y, .w = x1 - x0, .h = l.height };
        count += 1;
    }
    return count;
}

/// The cluster edge nearest `want_x` on the line above the caret's, or null on the first line
/// (the caller moves to the previous block).
pub fn offsetAbove(p: *const Paragraph, m: Measurer, offset: usize, affinity: Affinity, want_x: f32) ?Hit {
    const li = p.lineOf(offset, affinity);
    if (li == 0) return null;
    return p.hitInLine(m, li - 1, want_x);
}

/// Like `offsetAbove`, for the line below; null on the last line.
pub fn offsetBelow(p: *const Paragraph, m: Measurer, offset: usize, affinity: Affinity, want_x: f32) ?Hit {
    const li = p.lineOf(offset, affinity);
    if (li + 1 >= p.lines.len) return null;
    return p.hitInLine(m, li + 1, want_x);
}

/// Records one `textStyled` per segment at its stored position offset by (`x`, `y`). Nothing is
/// measured. Backgrounds, selection and carets are the caller's.
pub fn draw(p: *const Paragraph, list: *gfx.DisplayList, x: f32, y: f32) void {
    for (p.segments) |s| {
        list.textStyled(x + s.x, y + s.y, s.size, s.color, .left, s.style, p.text[s.start..s.end]);
    }
}

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const white: Color = .{ .r = 255, .g = 255, .b = 255 };

/// Widths are code points x size (x2 bold, x0.5 mono); ascent 0.8 and descent 0.2 of the size
/// (mono: 0.7 and 0.3), line height 1.2 times the size. Counts every call.
const Fake = struct {
    measures: usize = 0,
    metric_calls: usize = 0,

    fn measurer(f: *Fake) Measurer {
        return .{ .ctx = f, .measureFn = measureImpl, .metricsFn = metricsImpl };
    }

    fn measureImpl(ctx: ?*anyopaque, str: []const u8, size: f32, style: gfx.TextStyle) f32 {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.measures += 1;
        var n: f32 = 0;
        for (str) |c| {
            if (c & 0xC0 != 0x80) n += 1; // one per code point; additive for any split
        }
        const k: f32 = if (style.weight == .bold) 2 else if (style.mono) 0.5 else 1;
        return n * size * k;
    }

    fn metricsImpl(ctx: ?*anyopaque, size: f32, style: gfx.TextStyle) gfx.FontMetrics {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.metric_calls += 1;
        return if (style.mono)
            .{ .ascent = size * 0.7, .descent = size * 0.3, .line_height = size * 1.2 }
        else
            .{ .ascent = size * 0.8, .descent = size * 0.2, .line_height = size * 1.2 };
    }
};

fn one(len: usize) [1]Run {
    return .{.{ .len = @intCast(len), .color = white }};
}

/// Lays out `text` as one plain run at size 10.
fn plain(f: *Fake, text: []const u8, width: f32) !Paragraph {
    const runs = one(text.len);
    return init(testing.allocator, f.measurer(), text, &runs, .{ .size = 10, .width = width });
}

fn expectLines(p: *const Paragraph, starts: []const usize) !void {
    try testing.expectEqual(starts.len, p.lines.len);
    for (starts, p.lines, 0..) |s, l, i| {
        try testing.expectEqual(s, l.start);
        if (i + 1 < starts.len) try testing.expectEqual(starts[i + 1], l.end);
    }
    try testing.expectEqual(p.text.len, p.lines[p.lines.len - 1].end);
}

fn lineText(p: *const Paragraph, i: usize) []const u8 {
    const l = p.lines[i];
    return p.text[l.start..p.visibleEnd(l)];
}

test "wraps after spaces; the spaces hang and do not count" {
    var f: Fake = .{};
    var p = try plain(&f, "aaa bbb ccc", 70);
    defer p.deinit(testing.allocator);
    try expectLines(&p, &.{ 0, 8 });
    try testing.expectEqualStrings("aaa bbb", lineText(&p, 0));
    try testing.expectEqual(@as(f32, 70), p.lines[0].width);
    try testing.expectEqual(@as(usize, 8), p.lines[0].end); // the hanging space is in the range
    try testing.expectEqual(@as(usize, 1), p.lines[0].segment_count);
    try testing.expectEqual(@as(usize, 7), p.segments[0].end);
    try testing.expectEqualStrings("ccc", lineText(&p, 1));
    try testing.expectEqual(@as(f32, 24), p.height);
    // Many hanging spaces still do not push the word over.
    var q = try plain(&f, "aaaaaaa      b", 70);
    defer q.deinit(testing.allocator);
    try expectLines(&q, &.{ 0, 13 });
    try testing.expectEqual(@as(f32, 70), q.lines[0].width);
}

test "wraps after a hyphen between letters or digits only" {
    var f: Fake = .{};
    var p = try plain(&f, "ab-cd ef", 30);
    defer p.deinit(testing.allocator);
    try expectLines(&p, &.{ 0, 3, 6 });
    // A hyphen before a space or at the start of a word is not a break: "-5" stays whole.
    var q = try plain(&f, "a - b -5", 30);
    defer q.deinit(testing.allocator);
    try expectLines(&q, &.{ 0, 4, 6 });
    try testing.expectEqualStrings("-5", lineText(&q, 2));
    var r = try plain(&f, "12-34", 30);
    defer r.deinit(testing.allocator);
    try expectLines(&r, &.{ 0, 3 });
}

test "breaks between CJK characters, keeping closing marks off the line start" {
    var f: Fake = .{};
    var p = try plain(&f, "你好世界你好", 40);
    defer p.deinit(testing.allocator);
    try expectLines(&p, &.{ 0, 12 });
    var q = try plain(&f, "你好。世界", 20);
    defer q.deinit(testing.allocator);
    // 好。 stays together, so it moves down as a pair.
    try expectLines(&q, &.{ 0, 3, 9 });
    try testing.expectEqualStrings("好。", lineText(&q, 1));
    // An opening bracket stays with what follows it.
    var r = try plain(&f, "你「世界", 20);
    defer r.deinit(testing.allocator);
    try expectLines(&r, &.{ 0, 3, 9 });
    try testing.expectEqualStrings("「世", lineText(&r, 1));
}

test "hard breaks and a trailing newline" {
    var f: Fake = .{};
    var p = try plain(&f, "ab\ncd\n", 1000);
    defer p.deinit(testing.allocator);
    try expectLines(&p, &.{ 0, 3, 6 });
    try testing.expect(p.lines[0].hard_break and p.lines[1].hard_break and !p.lines[2].hard_break);
    try testing.expectEqualStrings("ab", lineText(&p, 0));
    try testing.expectEqual(@as(usize, 0), p.lines[2].segment_count);
    try testing.expectEqual(@as(f32, 12), p.lines[2].height); // an empty line is as tall as the paragraph size
    try testing.expectEqual(@as(f32, 36), p.height);
    var q = try plain(&f, "a\r\nb", 1000);
    defer q.deinit(testing.allocator);
    try expectLines(&q, &.{ 0, 3 });
    try testing.expectEqual(@as(usize, 1), q.caretEnd(0));
    // Spaces before a newline, and a tab, are text.
    var r = try plain(&f, "a  \tb\n", 1000);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("a   b", lineText(&r, 0));
    try testing.expectEqual(@as(f32, 50), r.lines[0].width);
}

test "empty text is one empty line with the paragraph's metrics" {
    var f: Fake = .{};
    var p = try init(testing.allocator, f.measurer(), "", &.{}, .{ .size = 20, .width = 100 });
    defer p.deinit(testing.allocator);
    try expectLines(&p, &.{0});
    try testing.expectEqual(@as(f32, 24), p.height);
    try testing.expectEqual(@as(f32, 16), p.lines[0].baseline);
    try testing.expectEqual(@as(usize, 0), p.segments.len);
    const c = p.caretRect(f.measurer(), 0, .downstream);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 24 }, c);
    var q = try plain(&f, "", 100);
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 12), q.height);
}

test "an over-long word is cut between clusters, at least one per line" {
    var f: Fake = .{};
    var p = try plain(&f, "abcdefghij", 30);
    defer p.deinit(testing.allocator);
    try expectLines(&p, &.{ 0, 3, 6, 9 });
    // Moves to its own line first.
    var q = try plain(&f, "ab abcdefgh", 50);
    defer q.deinit(testing.allocator);
    try expectLines(&q, &.{ 0, 3, 8 });
    // A cluster is never cut, even where it is wider than the line.
    const t = "a\u{301}bc\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}d";
    var r = try plain(&f, t, 5);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), r.lines.len);
    for (r.lines) |l| try testing.expect(grapheme.isBoundary(t, l.start));
    try testing.expect(r.lines.len == 5 and r.lines[2].end - r.lines[2].start == 1);
    // The rest of a cut word carries on with what follows.
    var s = try plain(&f, "abcdefg hi", 50);
    defer s.deinit(testing.allocator);
    try expectLines(&s, &.{ 0, 5 });
    try testing.expectEqualStrings("fg hi", lineText(&s, 1));
}

test "a word spanning two runs is not broken between them" {
    var f: Fake = .{};
    const text = "hello world";
    const runs = [_]Run{
        .{ .len = 3, .color = white, .tag = 1 },
        .{ .len = 5, .color = white, .style = .{ .weight = .bold }, .tag = 2 },
        .{ .len = 3, .color = white, .tag = 3 },
    };
    var p = try init(testing.allocator, f.measurer(), text, &runs, .{ .size = 10, .width = 100 });
    defer p.deinit(testing.allocator);
    try expectLines(&p, &.{ 0, 6 });
    try testing.expectEqual(@as(usize, 2), p.lines[0].segment_count);
    try testing.expectEqual(@as(u32, 1), p.segments[0].tag);
    try testing.expectEqual(@as(usize, 3), p.segments[0].end);
    try testing.expectEqual(@as(usize, 3), p.segments[1].start);
    try testing.expectEqual(@as(usize, 5), p.segments[1].end); // the hanging space is left out
    try testing.expectEqual(@as(f32, 30), p.segments[1].x);
    try testing.expectEqual(@as(f32, 70), p.lines[0].width);
    try testing.expectEqual(@as(usize, 2), p.lines[1].segment_count);
    try testing.expectEqual(@as(u32, 2), p.segments[2].tag);
    try testing.expectEqual(@as(u32, 3), p.segments[3].tag);
    try testing.expectEqual(@as(f32, 40), p.segments[3].x);
}

test "mixed sizes on a line share a baseline" {
    var f: Fake = .{};
    const runs = [_]Run{
        .{ .len = 3, .color = white },
        .{ .len = 2, .color = white, .size = 20 },
        .{ .len = 2, .color = white, .style = .{ .mono = true } },
    };
    var p = try init(testing.allocator, f.measurer(), "abcdefg", &runs, .{ .size = 10, .width = 1000 });
    defer p.deinit(testing.allocator);
    const l = p.lines[0];
    try testing.expectEqual(@as(f32, 16), l.baseline);
    try testing.expectEqual(@as(f32, 24), l.height); // 20 * 1.2 beats 16 + 4
    try testing.expectEqual(@as(f32, 8), p.segments[0].y); // 16 - 8
    try testing.expectEqual(@as(f32, 0), p.segments[1].y);
    try testing.expectEqual(@as(f32, 16 - 7), p.segments[2].y);
    for (p.segments) |s| try testing.expectEqual(@as(f32, 16), s.y + (if (s.size == 20) @as(f32, 16) else if (s.style.mono) @as(f32, 7) else 8));
    // Line spacing scales the natural height, to whole points.
    const three = one(3);
    var q = try init(testing.allocator, f.measurer(), "abc", &three, .{ .size = 10, .width = 1000, .line_spacing = 1.5 });
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 18), q.lines[0].height);
    // The second line sits below the first.
    var r = try plain(&f, "ab cd", 20);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 12), r.lines[1].y);
    try testing.expectEqual(@as(f32, 12), r.segments[1].y - r.segments[0].y);
}

test "invalid runs are errors" {
    var f: Fake = .{};
    const m = f.measurer();
    const o: Options = .{ .size = 10, .width = 100 };
    try testing.expectError(error.RunLengthMismatch, init(testing.allocator, m, "abc", &one(2), o));
    try testing.expectError(error.RunLengthMismatch, init(testing.allocator, m, "abc", &one(4), o));
    try testing.expectError(error.RunLengthMismatch, init(testing.allocator, m, "abc", &.{}, o));
    try testing.expectError(error.RunLengthMismatch, init(testing.allocator, m, "", &one(1), o));
    // A boundary inside a code point or a stray byte is fine: it moves to the cluster's end.
    const split = [_]Run{ .{ .len = 1, .color = white }, .{ .len = 2, .color = white } };
    var sp = try init(testing.allocator, m, "\u{e9}a", &split, o);
    defer sp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), sp.segments[0].end);
    const stray = [_]Run{ .{ .len = 1, .color = white }, .{ .len = 1, .color = white } };
    var bad = try init(testing.allocator, m, "a\x80", &stray, o);
    defer bad.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), bad.segments.len);
    for ([_]usize{ 0, 1, 2 }) |off| {
        const c = bad.caretRect(m, off, .downstream);
        // The stray byte measures zero, so offsets 1 and 2 share a position: compare positions.
        const h = bad.offsetAt(m, c.x, c.y + c.h / 2);
        try testing.expectEqual(c, bad.caretRect(m, h.offset, h.affinity));
    }
    const fine = [_]Run{ .{ .len = 2, .color = white }, .{ .len = 0, .color = white }, .{ .len = 1, .color = white } };
    var p = try init(testing.allocator, m, "\u{e9}a", &fine, o);
    p.deinit(testing.allocator);
}

test "init frees everything on every failing allocation" {
    var f: Fake = .{};
    const text = "hello wide world\nabcdefg";
    const text_len = text.len;
    const runs = [_]Run{
        .{ .len = 6, .color = white },
        .{ .len = text_len - 6, .color = white, .style = .{ .weight = .bold } },
    };
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        const r = init(fa.allocator(), f.measurer(), text, &runs, .{ .size = 10, .width = 50 });
        if (r) |*ok| {
            var p = ok.*;
            p.deinit(fa.allocator());
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
        try testing.expect(fail_at < 64);
    }
    try testing.expect(fail_at > 3);
}

test "no wrapping for a width of zero, negative or infinite" {
    var f: Fake = .{};
    for ([_]f32{ 0, -5, std.math.inf(f32), std.math.nan(f32) }) |w| {
        var p = try plain(&f, "aaa bbb ccc\nddd", w);
        defer p.deinit(testing.allocator);
        try expectLines(&p, &.{ 0, 12 });
    }
}

/// "aaa bbb ccc ddd" at width 70: line 0 "aaa bbb " [0,8), line 1 "ccc ddd" [8,15).
fn twoLines(f: *Fake) !Paragraph {
    return plain(f, "aaa bbb ccc ddd", 70);
}

test "caretRect at a soft wrap follows the affinity" {
    var f: Fake = .{};
    const m = f.measurer();
    var p = try twoLines(&f);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 0, .h = 12 }, p.caretRect(m, 0, .downstream));
    try testing.expectEqual(Rect{ .x = 30, .y = 0, .w = 0, .h = 12 }, p.caretRect(m, 3, .downstream));
    try testing.expectEqual(Rect{ .x = 70, .y = 0, .w = 0, .h = 12 }, p.caretRect(m, 7, .downstream));
    // Inside the hanging space and after it, upstream: the end of the upper line.
    try testing.expectEqual(Rect{ .x = 70, .y = 0, .w = 0, .h = 12 }, p.caretRect(m, 8, .upstream));
    try testing.expectEqual(Rect{ .x = 0, .y = 12, .w = 0, .h = 12 }, p.caretRect(m, 8, .downstream));
    try testing.expectEqual(Rect{ .x = 20, .y = 12, .w = 0, .h = 12 }, p.caretRect(m, 10, .upstream));
    try testing.expectEqual(Rect{ .x = 70, .y = 12, .w = 0, .h = 12 }, p.caretRect(m, 15, .downstream));
    try testing.expectEqual(Rect{ .x = 70, .y = 12, .w = 0, .h = 12 }, p.caretRect(m, 999, .upstream));
    try testing.expectEqual(@as(usize, 0), p.lineOf(8, .upstream));
    try testing.expectEqual(@as(usize, 1), p.lineOf(8, .downstream));
    // After a hard break the affinity does not matter.
    var q = try plain(&f, "ab\ncd", 1000);
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), q.lineOf(3, .upstream));
    try testing.expectEqual(@as(usize, 0), q.lineOf(2, .downstream));
    try testing.expectEqual(@as(f32, 20), q.caretRect(m, 2, .downstream).x);
    // At most one measure call for a caret.
    f.measures = 0;
    _ = p.caretRect(m, 10, .downstream);
    try testing.expect(f.measures <= 1);
}

test "offsetAt: inside, between, before, after, above and below" {
    var f: Fake = .{};
    const m = f.measurer();
    var p = try twoLines(&f);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(Hit{ .offset = 1, .affinity = .downstream }, p.offsetAt(m, 12, 5));
    try testing.expectEqual(Hit{ .offset = 0, .affinity = .downstream }, p.offsetAt(m, 4, 5));
    try testing.expectEqual(Hit{ .offset = 2, .affinity = .downstream }, p.offsetAt(m, 15, 5)); // a tie goes right
    try testing.expectEqual(Hit{ .offset = 2, .affinity = .downstream }, p.offsetAt(m, 20, 5));
    // Before and after the line.
    try testing.expectEqual(Hit{ .offset = 0, .affinity = .downstream }, p.offsetAt(m, -50, 5));
    try testing.expectEqual(Hit{ .offset = 8, .affinity = .upstream }, p.offsetAt(m, 500, 5));
    try testing.expectEqual(Hit{ .offset = 8, .affinity = .upstream }, p.offsetAt(m, 70, 5));
    try testing.expectEqual(Hit{ .offset = 15, .affinity = .downstream }, p.offsetAt(m, 500, 18));
    // Above the first line and below the last.
    try testing.expectEqual(Hit{ .offset = 2, .affinity = .downstream }, p.offsetAt(m, 20, -40));
    try testing.expectEqual(Hit{ .offset = 10, .affinity = .downstream }, p.offsetAt(m, 20, 400));
    try testing.expectEqual(Hit{ .offset = 8, .affinity = .downstream }, p.offsetAt(m, 0, 12));
    // The nearest edge, by the half-way point.
    try testing.expectEqual(@as(usize, 1), p.offsetAt(m, 14.9, 0).offset);
    try testing.expectEqual(@as(usize, 2), p.offsetAt(m, 15.1, 0).offset);
    // A cost bound: logarithmic in the segment.
    var big = try plain(&f, &@as([4000]u8, @splat('x')), 1e9);
    defer big.deinit(testing.allocator);
    f.measures = 0;
    _ = big.offsetAt(m, 12345, 0);
    try testing.expect(f.measures <= 16);
}

test "offsetAt crosses runs and styles" {
    var f: Fake = .{};
    const m = f.measurer();
    const runs = [_]Run{ .{ .len = 2, .color = white }, .{ .len = 2, .style = .{ .weight = .bold }, .color = white }, .{ .len = 2, .color = white } };
    var p = try init(testing.allocator, m, "abcdef", &runs, .{ .size = 10, .width = 1000 });
    defer p.deinit(testing.allocator);
    // a b | c d (20 each) | e f at 60 and 70
    try testing.expectEqual(@as(usize, 2), p.offsetAt(m, 21, 0).offset);
    try testing.expectEqual(@as(usize, 3), p.offsetAt(m, 41, 0).offset);
    try testing.expectEqual(@as(usize, 3), p.offsetAt(m, 39, 0).offset);
    try testing.expectEqual(@as(usize, 4), p.offsetAt(m, 61, 0).offset);
    try testing.expectEqual(@as(usize, 5), p.offsetAt(m, 74, 0).offset);
    try testing.expectEqual(@as(f32, 40), p.caretRect(m, 3, .downstream).x);
}

/// A paragraph with several lines, runs of different styles and sizes, and a long word.
fn rich(f: *Fake) !Paragraph {
    const text = "The quick brown fox, jumps over the lazy-dog and a very long supercalifragilistic word. End.";
    const runs = [_]Run{
        .{ .len = 10, .color = white },
        .{ .len = 15, .color = white, .style = .{ .weight = .bold } },
        .{ .len = 20, .color = white, .size = 14 },
        .{ .len = 30, .color = white, .style = .{ .mono = true } },
        .{ .len = text.len - 75, .color = white },
    };
    return init(testing.allocator, f.measurer(), text, &runs, .{ .size = 10, .width = 150 });
}

test "offsetAt and caretRect round-trip at every cluster boundary" {
    var f: Fake = .{};
    const m = f.measurer();
    var p = try rich(&f);
    defer p.deinit(testing.allocator);
    try testing.expect(p.lines.len >= 4);
    var o: usize = 0;
    while (true) {
        for ([_]Affinity{ .upstream, .downstream }) |aff| {
            const c = p.caretRect(m, o, aff);
            const hit = p.offsetAt(m, c.x, c.y + c.h / 2);
            try testing.expectEqual(c, p.caretRect(m, hit.offset, hit.affinity));
            // Offsets in the hanging spaces share the position of the line's end and come back
            // as that; every other one comes back as itself.
            const l = p.lines[p.lineOf(o, aff)];
            const vis = p.visibleEnd(l);
            const hangs = !l.hard_break and vis < l.end and o >= vis and o < l.end;
            if (!hangs) try testing.expectEqual(o, hit.offset);
        }
        if (o == p.text.len) break;
        o = grapheme.nextBoundary(p.text, o);
    }
}

test "selectionRects over one, two and three lines, and an empty line" {
    var f: Fake = .{};
    const m = f.measurer();
    var out: [8]Rect = undefined;
    var p = try twoLines(&f);
    defer p.deinit(testing.allocator);
    // One line.
    try testing.expectEqual(@as(usize, 1), p.selectionRects(m, 1, 3, &out));
    try testing.expectEqual(Rect{ .x = 10, .y = 0, .w = 20, .h = 12 }, out[0]);
    // Either order, and an empty selection.
    try testing.expectEqual(@as(usize, 1), p.selectionRects(m, 3, 1, &out));
    try testing.expectEqual(Rect{ .x = 10, .y = 0, .w = 20, .h = 12 }, out[0]);
    try testing.expectEqual(@as(usize, 0), p.selectionRects(m, 3, 3, &out));
    // Two lines: the first runs to its text end, hanging space included.
    try testing.expectEqual(@as(usize, 2), p.selectionRects(m, 5, 10, &out));
    try testing.expectEqual(Rect{ .x = 50, .y = 0, .w = 20, .h = 12 }, out[0]);
    try testing.expectEqual(Rect{ .x = 0, .y = 12, .w = 20, .h = 12 }, out[1]);
    // Ending exactly at the wrap selects nothing on the lower line.
    try testing.expectEqual(@as(usize, 1), p.selectionRects(m, 5, 8, &out));
    // Too small an output: still counts them all.
    try testing.expectEqual(@as(usize, 2), p.selectionRects(m, 0, 15, out[0..1]));
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 70, .h = 12 }, out[0]);

    // Three lines, the middle one empty.
    var q = try plain(&f, "abc\n\ndef", 1000);
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), q.selectionRects(m, 1, 6, &out));
    try testing.expectEqual(Rect{ .x = 10, .y = 0, .w = 20, .h = 12 }, out[0]);
    try testing.expectEqual(@as(f32, 12), out[1].y);
    try testing.expectApproxEqAbs(@as(f32, 10) / 3, out[1].w, 0.001);
    try testing.expectEqual(Rect{ .x = 0, .y = 24, .w = 10, .h = 12 }, out[2]);
    // Selecting only the newline after text shows nothing extra; an empty line at the end does not count.
    try testing.expectEqual(@as(usize, 0), q.selectionRects(m, 3, 4, &out));
    try testing.expectEqual(@as(usize, 1), q.selectionRects(m, 4, 5, &out));
    var r = try plain(&f, "ab\n", 1000);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.selectionRects(m, 0, 3, &out));
    try testing.expectEqual(@as(f32, 20), out[0].w);
}

test "offsetAbove and offsetBelow, with null at the ends and a want_x beyond a short line" {
    var f: Fake = .{};
    const m = f.measurer();
    var p = try plain(&f, "abcdef\nab\nabcdef", 1000);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(?Hit, null), p.offsetAbove(m, 3, .downstream, 30));
    try testing.expectEqual(@as(?Hit, null), p.offsetBelow(m, 12, .downstream, 30));
    try testing.expectEqual(Hit{ .offset = 9, .affinity = .downstream }, p.offsetBelow(m, 3, .downstream, 30).?);
    // Beyond the short line's end: its end, before the newline.
    try testing.expectEqual(Hit{ .offset = 9, .affinity = .downstream }, p.offsetBelow(m, 5, .downstream, 50).?);
    try testing.expectEqual(Hit{ .offset = 9, .affinity = .downstream }, p.offsetAbove(m, 12, .downstream, 50).?);
    try testing.expectEqual(Hit{ .offset = 3, .affinity = .downstream }, p.offsetAbove(m, 8, .downstream, 30).?);
    // Across a soft wrap.
    var w = try twoLines(&f);
    defer w.deinit(testing.allocator);
    try testing.expectEqual(Hit{ .offset = 9, .affinity = .downstream }, w.offsetBelow(m, 1, .downstream, 10).?);
    try testing.expectEqual(Hit{ .offset = 8, .affinity = .upstream }, w.offsetAbove(m, 12, .downstream, 400).?);
    // lineStart and lineEnd.
    try testing.expectEqual(@as(usize, 8), w.lineStart(11, .downstream));
    try testing.expectEqual(@as(usize, 0), w.lineStart(8, .upstream));
    try testing.expectEqual(Hit{ .offset = 8, .affinity = .upstream }, w.lineEnd(2, .downstream));
    try testing.expectEqual(Hit{ .offset = 15, .affinity = .downstream }, w.lineEnd(12, .downstream));
    try testing.expectEqual(Hit{ .offset = 6, .affinity = .downstream }, p.lineEnd(2, .downstream));
}

test "no query ever lands inside a grapheme cluster" {
    var f: Fake = .{};
    const m = f.measurer();
    const text = "e\u{301}x \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} yz \u{1F1E9}\u{1F1EA}k a\u{301}\u{302}b";
    var p = try plain(&f, text, 45);
    defer p.deinit(testing.allocator);
    for (p.lines) |l| try testing.expect(grapheme.isBoundary(text, l.start));
    for (p.segments) |s| try testing.expect(grapheme.isBoundary(text, s.start) and grapheme.isBoundary(text, s.end));
    var y: f32 = -5;
    while (y < p.height + 5) : (y += 6) {
        var x: f32 = -10;
        while (x < 250) : (x += 3.5) {
            const h = p.offsetAt(m, x, y);
            try testing.expect(grapheme.isBoundary(text, h.offset));
        }
    }
    // An offset in the middle of the ZWJ sequence snaps to its start.
    const family = std.mem.indexOf(u8, text, "\u{1F468}").?;
    const inside = family + 4;
    try testing.expectEqual(p.caretRect(m, family, .downstream), p.caretRect(m, inside, .downstream));
    try testing.expectEqual(p.lineOf(family, .downstream), p.lineOf(inside, .downstream));
    var out: [8]Rect = undefined;
    const n = p.selectionRects(m, inside, inside + 1, &out);
    try testing.expectEqual(@as(usize, 0), n);
}

test "layout makes a linear number of measure calls, a query a handful" {
    var f: Fake = .{};
    const words = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(testing.allocator);
    const n_words: usize = 2000;
    var run_start: usize = 0;
    for (0..n_words) |i| {
        if (i > 0) try buf.append(testing.allocator, ' ');
        try buf.appendSlice(testing.allocator, words[(i * 7 + i / 3) % words.len]);
        if (i % 25 == 24) { // a run per 25 words, alternating bold
            try runs.append(testing.allocator, .{ .len = @intCast(buf.items.len - run_start), .color = white, .style = .{ .weight = if (i % 50 == 24) .bold else .regular } });
            run_start = buf.items.len;
        }
    }
    if (buf.items.len > run_start) try runs.append(testing.allocator, .{ .len = @intCast(buf.items.len - run_start), .color = white });
    var p = try init(testing.allocator, f.measurer(), buf.items, runs.items, .{ .size = 10, .width = 400 });
    defer p.deinit(testing.allocator);
    try testing.expect(p.lines.len > 100);
    // A word per call, a space width per run, a segment per call.
    const bound = n_words + 2 * runs.items.len + p.segments.len;
    try testing.expect(f.measures <= bound);
    try testing.expect(f.measures >= n_words / 2);
    try testing.expect(f.metric_calls <= runs.items.len + 1);
    // Deterministic: the same input costs the same.
    const before = f.measures;
    f.measures = 0;
    var q = try init(testing.allocator, f.measurer(), buf.items, runs.items, .{ .size = 10, .width = 400 });
    q.deinit(testing.allocator);
    try testing.expectEqual(before, f.measures);
    // Drawing measures nothing.
    var list = gfx.DisplayList.init(testing.allocator);
    defer list.deinit();
    f.measures = 0;
    p.draw(&list, 0, 0);
    try testing.expectEqual(@as(usize, 0), f.measures);
}

test "a long unbreakable word costs a logarithmic number of calls per cut" {
    var f: Fake = .{};
    var p = try plain(&f, &@as([5000]u8, @splat('x')), 100);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 500), p.lines.len);
    try testing.expect(f.measures < 500 * 24);
}

test "draw emits one styled text per non-empty segment at its position" {
    var f: Fake = .{};
    const runs = [_]Run{
        .{ .len = 6, .color = .{ .r = 1, .g = 2, .b = 3 } },
        .{ .len = 6, .color = .{ .r = 4, .g = 5, .b = 6 }, .style = .{ .italic = true, .underline = true }, .size = 20 },
        .{ .len = 0, .color = white },
    };
    var p = try init(testing.allocator, f.measurer(), "aaa b ccc dd", &runs, .{ .size = 10, .width = 60 });
    defer p.deinit(testing.allocator);
    var list = gfx.DisplayList.init(testing.allocator);
    defer list.deinit();
    p.draw(&list, 100, 200);
    try testing.expectEqual(p.segments.len, list.cmds.items.len);
    for (p.segments, list.cmds.items) |s, c| {
        const t = c.text;
        try testing.expectEqual(100 + s.x, t.x);
        try testing.expectEqual(200 + s.y, t.y);
        try testing.expectEqual(s.size, t.size);
        try testing.expectEqual(s.style, t.style);
        try testing.expectEqual(s.color, t.color);
        try testing.expectEqualStrings(p.text[s.start..s.end], t.str);
        try testing.expect(t.str.len > 0);
    }
    var last_italic = false;
    for (list.cmds.items) |c| last_italic = last_italic or (c.text.style.italic and c.text.size == 20);
    try testing.expect(last_italic);
    // An empty paragraph draws nothing.
    var e = try init(testing.allocator, f.measurer(), "", &.{}, .{ .size = 10, .width = 60 });
    defer e.deinit(testing.allocator);
    var l2 = gfx.DisplayList.init(testing.allocator);
    defer l2.deinit();
    e.draw(&l2, 0, 0);
    try testing.expectEqual(@as(usize, 0), l2.cmds.items.len);
}

test "a run boundary inside a cluster moves to the cluster's end" {
    var f: Fake = .{};
    const m = f.measurer();
    const text = "abe\u{301}cd";
    const runs = [_]Run{ .{ .len = 3, .color = white }, .{ .len = 4, .color = white, .style = .{ .weight = .bold } } };
    var p = try init(testing.allocator, m, text, &runs, .{ .size = 10, .width = 1000 });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), p.segments.len);
    try testing.expectEqual(@as(usize, 5), p.segments[0].end);
    try testing.expectEqual(@as(usize, 5), p.segments[1].start);
    var x: f32 = -5;
    while (x < 150) : (x += 1.5) {
        const h = p.offsetAt(m, x, 0);
        try testing.expect(h.offset != 3 and h.offset != 4);
    }
    try testing.expectEqual(p.caretRect(m, 2, .downstream), p.caretRect(m, 3, .downstream));
    try testing.expectEqual(p.caretRect(m, 2, .downstream), p.caretRect(m, 4, .downstream));
    var list = gfx.DisplayList.init(testing.allocator);
    defer list.deinit();
    p.draw(&list, 0, 0);
    try testing.expectEqualStrings("abe\u{301}", list.cmds.items[0].text.str);
    try testing.expectEqualStrings("cd", list.cmds.items[1].text.str);
    // Several lines: vertical moves never land inside the cluster either.
    var q = try init(testing.allocator, m, text, &runs, .{ .size = 10, .width = 30 });
    defer q.deinit(testing.allocator);
    try testing.expect(q.lines.len >= 3);
    var want: f32 = -5;
    while (want < 60) : (want += 2.5) {
        for ([_]usize{ 0, 2, 5, 6 }) |o| {
            if (q.offsetBelow(m, o, .downstream, want)) |h| try testing.expect(h.offset != 3 and h.offset != 4);
            if (q.offsetAbove(m, o, .downstream, want)) |h| try testing.expect(h.offset != 3 and h.offset != 4);
        }
    }
}

test "layout and queries walk clusters forward: cost does not grow with the square of a run of flags" {
    var f: Fake = .{};
    const m = f.measurer();
    var layout_steps: [2]usize = undefined;
    var query_steps: [2]usize = undefined;
    for ([_]usize{ 500, 2000 }, 0..) |n, k| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        for (0..n) |_| try buf.appendSlice(testing.allocator, "\u{1F1E9}\u{1F1EA}");
        // Our own cluster steps plus the grapheme module's walks back along a run of indicators:
        // testing only the first would pass with a quadratic boundary test swapped in.
        cluster_steps = 0;
        grapheme.test_ri_steps = 0;
        var p = try plain(&f, buf.items, 200);
        defer p.deinit(testing.allocator);
        layout_steps[k] = cluster_steps + grapheme.test_ri_steps;
        cluster_steps = 0;
        grapheme.test_ri_steps = 0;
        _ = p.caretRect(m, p.text.len - 5, .downstream);
        _ = p.offsetAt(m, 55, p.height - 1);
        _ = p.offsetAbove(m, p.text.len - 5, .downstream, 77);
        query_steps[k] = cluster_steps + grapheme.test_ri_steps;
    }
    // Four times the flags, about four times the steps (not sixteen).
    try testing.expect(layout_steps[1] <= layout_steps[0] * 5);
    try testing.expect(layout_steps[1] >= layout_steps[0] * 3);
    // A query follows the length of a line, which is the same here.
    try testing.expect(query_steps[1] <= query_steps[0] + 40);
}

test "an empty line takes the size of the run that holds its newline" {
    var f: Fake = .{};
    const m = f.measurer();
    const text = "Title\n\nMore";
    const big = [_]Run{.{ .len = text.len, .color = white, .size = 30 }};
    var p = try init(testing.allocator, m, text, &big, .{ .size = 10, .width = 1000 });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 36), p.lines[0].height);
    try testing.expectEqual(@as(f32, 36), p.lines[1].height);
    try testing.expectEqual(@as(f32, 36), p.lines[2].height);
    try testing.expectEqual(@as(f32, 36), p.caretRect(m, 6, .downstream).h);
    // Two runs: the empty line follows the run of its own newline.
    const two = [_]Run{ .{ .len = 6, .color = white, .size = 30 }, .{ .len = 5, .color = white } };
    var q = try init(testing.allocator, m, text, &two, .{ .size = 10, .width = 1000 });
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 12), q.lines[1].height);
    // A trailing empty line uses the run at the end of the text.
    const head = [_]Run{.{ .len = 6, .color = white, .size = 30 }};
    var r = try init(testing.allocator, m, "Title\n", &head, .{ .size = 10, .width = 1000 });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 36), r.lines[1].height);
    // Empty text: the last run when it is zero-length, else the paragraph's.
    const none = [_]Run{.{ .len = 0, .color = white, .size = 30 }};
    var e = try init(testing.allocator, m, "", &none, .{ .size = 10, .width = 1000 });
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 36), e.height);
}

test "a space that starts a longer cluster is ordinary text, not a hanging space" {
    var f: Fake = .{};
    var p = try plain(&f, "aa \u{301} bb cc", 55);
    defer p.deinit(testing.allocator);
    try expectLines(&p, &.{ 0, 6 });
    try testing.expectEqualStrings("aa \u{301}", lineText(&p, 0));
    try testing.expectEqual(@as(f32, 40), p.lines[0].width); // four code points, none dropped
    try testing.expectEqualStrings("bb cc", lineText(&p, 1));
}

test "options are validated" {
    var f: Fake = .{};
    const m = f.measurer();
    const runs = one(3);
    const bad = [_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) };
    for (bad) |v| {
        try testing.expectError(error.InvalidOptions, init(testing.allocator, m, "abc", &runs, .{ .size = 10, .width = 100, .line_spacing = v }));
        try testing.expectError(error.InvalidOptions, init(testing.allocator, m, "abc", &runs, .{ .size = v, .width = 100 }));
        const sized = [_]Run{.{ .len = 3, .color = white, .size = v }};
        try testing.expectError(error.InvalidOptions, init(testing.allocator, m, "abc", &sized, .{ .size = 10, .width = 100 }));
    }
    // A bad width still means "no wrapping".
    var p = try init(testing.allocator, m, "aa bb", &one(5), .{ .size = 10, .width = std.math.nan(f32) });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), p.lines.len);
}

fn zeroMeasure(_: ?*anyopaque, _: []const u8, _: f32, _: gfx.TextStyle) f32 {
    return 0;
}

test "with a measurer that sees no fonts both ends of a line are still reachable" {
    var f: Fake = .{};
    const zero: Measurer = .{ .ctx = &f, .measureFn = zeroMeasure, .metricsFn = Fake.metricsImpl };
    const runs = one(5);
    var p = try init(testing.allocator, zero, "hello", &runs, .{ .size = 10, .width = 100 });
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), p.offsetAt(zero, 0, 3).offset);
    try testing.expectEqual(@as(usize, 0), p.offsetAt(zero, -4, 3).offset);
    try testing.expectEqual(@as(usize, 5), p.offsetAt(zero, 1, 3).offset);
}

test "a trailing empty line takes the last run when it is empty, else the run of the last byte" {
    var f: Fake = .{};
    const m = f.measurer();
    const o: Options = .{ .size = 10, .width = 1000 };
    const typing = [_]Run{ .{ .len = 6, .color = white, .size = 30 }, .{ .len = 0, .color = white, .size = 10 } };
    var p = try init(testing.allocator, m, "Title\n", &typing, o);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 12), p.lines[1].height);
    const heading = [_]Run{.{ .len = 6, .color = white, .size = 30 }};
    var q = try init(testing.allocator, m, "Title\n", &heading, o);
    defer q.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 36), q.lines[1].height);
    // Empty text: the last run, which is then empty.
    const two = [_]Run{ .{ .len = 0, .color = white, .size = 30 }, .{ .len = 0, .color = white, .size = 20 } };
    var e = try init(testing.allocator, m, "", &two, o);
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 24), e.height);
}

test "a lone space is a space; a space that starts a cluster is drawn with its mark" {
    var f: Fake = .{};
    var p = try plain(&f, "ab  \u{301}cd", 25);
    defer p.deinit(testing.allocator);
    var list = gfx.DisplayList.init(testing.allocator);
    defer list.deinit();
    p.draw(&list, 0, 0);
    var drawn: std.ArrayList(u8) = .empty;
    defer drawn.deinit(testing.allocator);
    for (list.cmds.items) |c| try drawn.appendSlice(testing.allocator, c.text.str);
    try testing.expect(std.mem.indexOf(u8, drawn.items, " \u{301}") != null);
    for (p.lines) |l| try testing.expect(grapheme.isBoundary(p.text, l.start));
}

test "lines are at least a point tall, so every line can be reached" {
    var f: Fake = .{};
    const m = f.measurer();
    const runs = one(5);
    var p = try init(testing.allocator, m, "ab cd", &runs, .{ .size = 0.3, .width = 0.5 });
    defer p.deinit(testing.allocator);
    try testing.expect(p.lines.len >= 3);
    for (p.lines[1..], 0..) |l, i| try testing.expect(l.y > p.lines[i].y);
    for (p.lines) |l| try testing.expect(l.height >= 1);
    for (p.lines) |l| {
        const c = p.caretRect(m, l.start, .downstream);
        try testing.expectEqual(l.start, p.offsetAt(m, c.x, c.y + c.h / 2).offset);
    }
}

test "selecting only hanging spaces gives the marker at the end of the text" {
    var f: Fake = .{};
    const m = f.measurer();
    var p = try twoLines(&f);
    defer p.deinit(testing.allocator);
    var out: [4]Rect = undefined;
    try testing.expectEqual(@as(usize, 1), p.selectionRects(m, 7, 8, &out));
    try testing.expectEqual(@as(f32, 70), out[0].x);
    try testing.expectEqual(@as(f32, 0), out[0].y);
    try testing.expectApproxEqAbs(@as(f32, 10) / 3, out[0].w, 0.001);
}

const fuzz_pieces = [_][]const u8{
    "hello", "a", "bb", "word", " ", "  ", "\t", "\n", "\r\n", "-", "ab-cd", "你", "好", "。", "「", "\u{301}",
    "\u{1F44D}\u{1F3FD}", "\u{1F468}\u{200D}\u{1F469}", "\u{2764}\u{FE0F}", "\u{1F1E9}", "\u{1F1EA}",
    "\u{1100}", "\u{1161}", "\u{AC00}", "\x80", "\xE2\x82", "\xFF", "\u{200D}", "\u{FE0F}",
};

test "seeded fuzz: layout and queries keep their invariants on awkward text" {
    var f: Fake = .{};
    const m = f.measurer();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rng = prng.random();
    const widths = [_]f32{ 0, 12, 25, 40, 90, 400 };
    var list = gfx.DisplayList.init(testing.allocator);
    defer list.deinit();
    for (0..2000) |_| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        for (0..rng.uintLessThan(usize, 12)) |_| try buf.appendSlice(testing.allocator, fuzz_pieces[rng.uintLessThan(usize, fuzz_pieces.len)]);
        const text = buf.items;
        // Run boundaries anywhere, even inside code points.
        var runs: [5]Run = undefined;
        var n_runs: usize = 0;
        var at: usize = 0;
        while (n_runs < runs.len) : (n_runs += 1) {
            const last = n_runs + 1 == runs.len or rng.boolean();
            const len = if (last) text.len - at else rng.uintAtMost(usize, text.len - at);
            runs[n_runs] = .{
                .len = @intCast(len),
                .color = white,
                .style = .{ .weight = if (rng.boolean()) .bold else .regular, .mono = rng.uintLessThan(u8, 4) == 0 },
                .size = if (rng.boolean()) @as(?f32, 20) else null,
            };
            at += len;
            if (last) {
                n_runs += 1;
                break;
            }
        }
        var p = try init(testing.allocator, m, text, runs[0..n_runs], .{ .size = 10, .width = widths[rng.uintLessThan(usize, widths.len)] });
        defer p.deinit(testing.allocator);
        const t = p.text;

        // Lines tile the text; only the last may be empty.
        try testing.expectEqual(@as(usize, 0), p.lines[0].start);
        try testing.expectEqual(t.len, p.lines[p.lines.len - 1].end);
        for (p.lines, 0..) |l, i| {
            if (i + 1 < p.lines.len) {
                try testing.expectEqual(p.lines[i + 1].start, l.end);
                try testing.expect(l.end > l.start);
            }
            try testing.expect(grapheme.isBoundary(t, l.start) and grapheme.isBoundary(t, l.end));
            // Segments tile the drawn text on cluster boundaries, none empty.
            var pos = l.start;
            for (p.segments[l.first_segment..][0..l.segment_count]) |s| {
                try testing.expectEqual(pos, s.start);
                try testing.expect(s.end > s.start and grapheme.isBoundary(t, s.end));
                try testing.expectEqual(i, s.line);
                pos = s.end;
            }
            try testing.expect(pos <= l.end);
        }

        // Offsets from queries are boundaries on the line asked about.
        for (0..8) |_| {
            const x = rng.float(f32) * 120 - 10;
            const y = rng.float(f32) * (p.height + 10) - 5;
            const h = p.offsetAt(m, x, y);
            try testing.expect(h.offset <= t.len and grapheme.isBoundary(t, h.offset));
            try testing.expectEqual(p.lineAtY(y), p.lineOf(h.offset, h.affinity));
        }
        var o: usize = 0;
        while (true) {
            for ([_]Affinity{ .upstream, .downstream }) |aff| {
                const li = p.lineOf(o, aff);
                const c = p.caretRect(m, o, aff);
                const back = p.offsetAt(m, c.x, c.y + c.h / 2);
                try testing.expectEqual(c, p.caretRect(m, back.offset, back.affinity));
                const e = p.lineEnd(o, aff);
                try testing.expect(grapheme.isBoundary(t, e.offset) and p.lineOf(e.offset, e.affinity) == li);
                const want_x = rng.float(f32) * 100;
                if (p.offsetAbove(m, o, aff, want_x)) |h| {
                    try testing.expect(grapheme.isBoundary(t, h.offset) and li > 0 and p.lineOf(h.offset, h.affinity) == li - 1);
                } else try testing.expectEqual(@as(usize, 0), li);
                if (p.offsetBelow(m, o, aff, want_x)) |h| {
                    try testing.expect(grapheme.isBoundary(t, h.offset) and p.lineOf(h.offset, h.affinity) == li + 1);
                } else try testing.expectEqual(p.lines.len - 1, li);
            }
            if (o >= t.len) break;
            o = grapheme.nextBoundary(t, o);
        }

        // Drawing: one command per segment.
        list.reset();
        p.draw(&list, 0, 0);
        try testing.expectEqual(p.segments.len, list.cmds.items.len);
    }
}
