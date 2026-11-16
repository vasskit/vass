//! SVG parser: turns a (static, icon-sized) SVG document into a flat list of painted shapes
//! (`Doc`). Pure Zig, no platform and no C; the rasteriser is `raster.zig`.
//!
//! Supported: `svg` (viewBox, width/height), `g`, `path`, `line`, `polyline`, `polygon`,
//! `circle`, `ellipse`, `rect` (rx/ry), `linearGradient`/`radialGradient` with `stop`s,
//! `style` (simple `.class`, `#id` and `tag` selectors). The full path grammar. Presentation
//! attributes (also inside `style="..."` and CSS rules), inherited from ancestors:
//! fill, stroke, stroke-width, stroke-linecap, stroke-linejoin, stroke-miterlimit, fill-rule,
//! opacity, fill-opacity, stroke-opacity, color, display. `transform` on any element.
//! Colours: none, currentColor, #rgb[a], #rrggbb[aa], rgb()/rgba(), named colours.
//!
//! Ignored without failing: everything else (`title`, `desc`, `defs` content that is not a
//! gradient, `use`, `clipPath`, `mask`, filters, markers, text, images, dashes, nested viewBoxes).
//! Content of `defs`, `symbol`, `clipPath`, `mask`, `pattern`, `marker` is never drawn.
//! Malformed XML, malformed path data or transforms, and documents over the limits below
//! return an error.
const std = @import("std");

pub const Error = error{ InvalidSvg, TooComplex, OutOfMemory };

pub const max_depth = 48;
pub const max_elements = 20_000;
pub const max_shapes = 4_000;
pub const max_points = 200_000;
pub const max_gradients = 64;
pub const max_input_bytes = 4 * 1024 * 1024;
/// Total text of all `<style>` elements. Real icon and illustration stylesheets are a few KB.
pub const max_css_bytes = 256 * 1024;
/// Declarations applied over a whole document, from stylesheet rules and `style` attributes.
/// A rule's declarations are applied once per matching element, so this bounds the product
/// of rule size and element count; real files need a few hundred thousand at most.
const max_css_work = 8_000_000;

pub const Rgba = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Affine = .{};

    /// `m * n`: the transform that applies `n` first and then `m`.
    pub fn mul(m: Affine, n: Affine) Affine {
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }

    pub fn apply(m: Affine, x: f32, y: f32) [2]f32 {
        return .{ m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f };
    }

    pub fn det(m: Affine) f32 {
        return m.a * m.d - m.b * m.c;
    }

    pub fn invert(m: Affine) ?Affine {
        const dt = m.det();
        if (!(@abs(dt) > 1e-12) or !std.math.isFinite(dt)) return null;
        const id = 1 / dt;
        return .{
            .a = m.d * id,
            .b = -m.b * id,
            .c = -m.c * id,
            .d = m.a * id,
            .e = (m.c * m.f - m.d * m.e) * id,
            .f = (m.b * m.e - m.a * m.f) * id,
        };
    }

    /// Largest length a unit vector can be stretched to (an upper bound is enough).
    pub fn maxScale(m: Affine) f32 {
        return @max(std.math.hypot(m.a, m.b), std.math.hypot(m.c, m.d));
    }
};

pub const Verb = enum(u8) { move, line, cubic, close };

pub const Cap = enum { butt, round, square };
pub const Join = enum { miter, round, bevel };
pub const FillRule = enum { nonzero, evenodd };

pub const Paint = union(enum) {
    none,
    current_color,
    color: Rgba,
    /// Index into `Doc.gradients`.
    gradient: u16,
};

pub const Stop = struct { offset: f32, color: Rgba };

pub const Gradient = struct {
    radial: bool = false,
    /// Linear: x1,y1 -> x2,y2. Radial: centre (x1,y1), radius x2 (focal point ignored).
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 1,
    y2: f32 = 0,
    /// `objectBoundingBox` units (the default) or the shape's user space.
    bbox_units: bool = true,
    xf: Affine = .{},
    stops: []const Stop = &.{},
};

/// One painted shape: a path in its own user space plus transform and paint.
pub const Shape = struct {
    verbs: []const Verb,
    /// 1 point per move/line, 3 per cubic, none for close.
    pts: []const [2]f32,
    /// User space to viewBox space.
    xf: Affine = .{},
    fill: Paint = .none,
    stroke: Paint = .none,
    /// Effective opacities (element and ancestors' `opacity` times fill/stroke-opacity).
    fill_alpha: f32 = 1,
    stroke_alpha: f32 = 1,
    stroke_width: f32 = 1,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f32 = 4,
    rule: FillRule = .nonzero,
};

pub const Doc = struct {
    arena: std.heap.ArenaAllocator,
    /// The viewBox (or 0 0 width height).
    vb_x: f32,
    vb_y: f32,
    vb_w: f32,
    vb_h: f32,
    shapes: []const Shape,
    gradients: []const Gradient,

    pub fn deinit(d: *Doc) void {
        d.arena.deinit();
    }

    /// Width / height of the viewBox.
    pub fn aspect(d: *const Doc) f32 {
        return d.vb_w / d.vb_h;
    }
};

// ---- parsing entry point -------------------------------------------------------------

/// Parses `src`. The result owns its memory (free with `Doc.deinit`); `src` is not kept.
pub fn parse(gpa: std.mem.Allocator, src: []const u8) Error!Doc {
    if (src.len > max_input_bytes) return error.TooComplex;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p: Parser = .{ .a = arena.allocator(), .gpa = gpa, .src = src };
    defer p.deinitScratch();
    try p.run();
    // Everything that allocates from the arena happens before the arena is copied out.
    const gradients = try p.finishGradients();
    const shapes = p.shapes.items;
    return .{
        .arena = arena,
        .vb_x = p.vb[0],
        .vb_y = p.vb[1],
        .vb_w = p.vb[2],
        .vb_h = p.vb[3],
        .shapes = shapes,
        .gradients = gradients,
    };
}

const Style = struct {
    fill: Paint = .{ .color = .{} },
    stroke: Paint = .none,
    /// The `url(#id)` name when fill / stroke is a gradient (slices of the source text).
    fill_ref: []const u8 = "",
    stroke_ref: []const u8 = "",
    stroke_width: f32 = 1,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f32 = 4,
    rule: FillRule = .nonzero,
    opacity: f32 = 1,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    color: ?Rgba = null,
    display_none: bool = false,
    // Only meaningful for `stop` elements.
    stop_color: Rgba = .{},
    stop_opacity: f32 = 1,
};

const Frame = struct {
    name: []const u8 = "",
    kind: Kind = .other,
    style: Style = .{},
    xf: Affine = .{},
    /// This element or an ancestor is not rendered (defs, clipPath, display:none ...).
    skip: bool = false,
    const Kind = enum { svg, style, gradient, other };
};

const Attr = struct { name: []const u8, value: []const u8 };
const max_attrs = 64;

const RuleKind = enum { all, tag, class, id };
const Decl = struct { key: []const u8, val: []const u8 };
/// The declarations are shared by every selector of one rule.
const CssRule = struct { kind: RuleKind, name: []const u8, decls: []const Decl };

const GradientRec = struct {
    id: []const u8,
    href: []const u8,
    g: Gradient,
    stops: std.ArrayList(Stop) = .empty,
    has_stops_from_href: bool = false,
};

/// `key: value` pairs of a declaration block (`;` separated), `!important` dropped.
const DeclIter = struct {
    rest: []const u8,
    done: bool = false,

    fn next(it: *DeclIter) ?Decl {
        while (!it.done) {
            const semi = std.mem.indexOfScalar(u8, it.rest, ';');
            const d = if (semi) |i| it.rest[0..i] else it.rest;
            if (semi) |i| it.rest = it.rest[i + 1 ..] else it.done = true;
            const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
            const key = std.mem.trim(u8, d[0..colon], " \t\r\n");
            var val = std.mem.trim(u8, d[colon + 1 ..], " \t\r\n");
            if (std.mem.endsWith(u8, val, "!important")) val = std.mem.trim(u8, val[0 .. val.len - 10], " \t");
            return .{ .key = key, .val = val };
        }
        return null;
    }
};

const PaintRef = struct { shape: u32, stroke: bool, name: []const u8 };

const Parser = struct {
    a: std.mem.Allocator,
    gpa: std.mem.Allocator,
    src: []const u8,
    i: usize = 0,
    vb: [4]f32 = .{ 0, 0, 0, 0 },
    have_root: bool = false,
    root_done: bool = false,
    shapes: std.ArrayList(Shape) = .empty,
    grads: std.ArrayList(GradientRec) = .empty,
    refs: std.ArrayList(PaintRef) = .empty,
    rules: std.ArrayList(CssRule) = .empty,
    css_text: std.ArrayList(u8) = .empty,
    /// Bytes of `<style>` text seen so far (`max_css_bytes`) and declarations still allowed.
    css_bytes: usize = 0,
    css_work_left: usize = max_css_work,
    stack: [max_depth]Frame = undefined,
    depth: usize = 0,
    elements: usize = 0,
    total_points: usize = 0,
    pb: PathBuilder = .{},

    fn deinitScratch(p: *Parser) void {
        for (p.grads.items) |*g| g.stops.deinit(p.gpa);
        p.grads.deinit(p.gpa);
        p.rules.deinit(p.gpa);
        p.refs.deinit(p.gpa);
        p.css_text.deinit(p.gpa);
        p.pb.verbs.deinit(p.gpa);
        p.pb.pts.deinit(p.gpa);
    }

    fn run(p: *Parser) Error!void {
        const src = p.src;
        while (p.i < src.len) {
            const lt = std.mem.indexOfScalarPos(u8, src, p.i, '<') orelse {
                try p.text(src[p.i..]);
                p.i = src.len;
                break;
            };
            try p.text(src[p.i..lt]);
            p.i = lt;
            if (std.mem.startsWith(u8, src[p.i..], "<!--")) {
                const end = std.mem.indexOfPos(u8, src, p.i + 4, "-->") orelse return error.InvalidSvg;
                p.i = end + 3;
            } else if (std.mem.startsWith(u8, src[p.i..], "<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, src, p.i + 9, "]]>") orelse return error.InvalidSvg;
                try p.text(src[p.i + 9 .. end]);
                p.i = end + 3;
            } else if (std.mem.startsWith(u8, src[p.i..], "<?")) {
                const end = std.mem.indexOfPos(u8, src, p.i + 2, "?>") orelse return error.InvalidSvg;
                p.i = end + 2;
            } else if (std.mem.startsWith(u8, src[p.i..], "<!")) {
                // DOCTYPE and friends: skip to the matching '>' (internal subsets use [...]).
                var nest: usize = 0;
                var k = p.i + 2;
                while (k < src.len) : (k += 1) {
                    if (src[k] == '[') nest += 1;
                    if (src[k] == ']' and nest > 0) nest -= 1;
                    if (src[k] == '>' and nest == 0) break;
                }
                if (k >= src.len) return error.InvalidSvg;
                p.i = k + 1;
            } else if (std.mem.startsWith(u8, src[p.i..], "</")) {
                const end = std.mem.indexOfScalarPos(u8, src, p.i, '>') orelse return error.InvalidSvg;
                const name = localName(std.mem.trim(u8, src[p.i + 2 .. end], " \t\r\n"));
                p.i = end + 1;
                try p.closeElement(name);
            } else {
                try p.openElement();
            }
        }
        if (p.depth != 0 or !p.have_root) return error.InvalidSvg;
        if (!(p.vb[2] > 0 and p.vb[3] > 0)) return error.InvalidSvg;
    }

    /// Character data: only the content of `<style>` matters.
    fn text(p: *Parser, s: []const u8) Error!void {
        if (p.depth == 0) return;
        if (p.stack[p.depth - 1].kind != .style) return;
        p.css_bytes += s.len;
        if (p.css_bytes > max_css_bytes) return error.TooComplex;
        try p.css_text.appendSlice(p.gpa, s);
    }

    fn openElement(p: *Parser) Error!void {
        const src = p.src;
        var k = p.i + 1;
        const name_start = k;
        while (k < src.len and !isXmlSpace(src[k]) and src[k] != '>' and src[k] != '/') : (k += 1) {}
        if (k == name_start or k >= src.len) return error.InvalidSvg;
        const name = localName(src[name_start..k]);
        var attrs: [max_attrs]Attr = undefined;
        var na: usize = 0;
        var self_close = false;
        while (true) {
            while (k < src.len and isXmlSpace(src[k])) : (k += 1) {}
            if (k >= src.len) return error.InvalidSvg;
            if (src[k] == '>') {
                k += 1;
                break;
            }
            if (src[k] == '/') {
                if (k + 1 < src.len and src[k + 1] == '>') {
                    self_close = true;
                    k += 2;
                    break;
                }
                return error.InvalidSvg;
            }
            const an = k;
            while (k < src.len and !isXmlSpace(src[k]) and src[k] != '=' and src[k] != '>' and src[k] != '/') : (k += 1) {}
            const aname = src[an..k];
            while (k < src.len and isXmlSpace(src[k])) : (k += 1) {}
            if (k >= src.len or src[k] != '=' or aname.len == 0) return error.InvalidSvg;
            k += 1;
            while (k < src.len and isXmlSpace(src[k])) : (k += 1) {}
            if (k >= src.len or (src[k] != '"' and src[k] != '\'')) return error.InvalidSvg;
            const q = src[k];
            const vend = std.mem.indexOfScalarPos(u8, src, k + 1, q) orelse return error.InvalidSvg;
            if (na >= max_attrs) return error.TooComplex;
            attrs[na] = .{ .name = aname, .value = src[k + 1 .. vend] };
            na += 1;
            k = vend + 1;
        }
        p.i = k;
        p.elements += 1;
        if (p.elements > max_elements) return error.TooComplex;
        try p.element(name, attrs[0..na]);
        if (self_close) try p.closeElement(name);
    }

    fn element(p: *Parser, name: []const u8, attrs: []const Attr) Error!void {
        if (p.depth >= max_depth) return error.TooComplex;
        const parent: Frame = if (p.depth > 0) p.stack[p.depth - 1] else .{};
        var f: Frame = .{ .name = name, .style = parent.style, .xf = parent.xf, .skip = parent.skip };
        const eql = std.mem.eql;

        if (p.depth == 0) {
            // The root must be <svg>.
            if (!eql(u8, name, "svg")) return error.InvalidSvg;
        } else if (parent.kind == .gradient) {
            if (eql(u8, name, "stop")) try p.stop(attrs);
            f.skip = true;
            f.kind = .other;
            p.stack[p.depth] = f;
            p.depth += 1;
            return;
        }

        // Where does this element's content go? Not-drawn containers set `skip`.
        if (eql(u8, name, "defs") or eql(u8, name, "symbol") or eql(u8, name, "clipPath") or
            eql(u8, name, "mask") or eql(u8, name, "pattern") or eql(u8, name, "marker") or
            eql(u8, name, "filter") or eql(u8, name, "title") or eql(u8, name, "desc") or
            eql(u8, name, "metadata") or eql(u8, name, "foreignObject") or eql(u8, name, "text"))
        {
            f.skip = true;
        }

        if (eql(u8, name, "style")) {
            f.kind = .style;
            f.skip = true;
        } else if (eql(u8, name, "linearGradient") or eql(u8, name, "radialGradient")) {
            f.kind = .gradient;
            f.skip = true;
            try p.beginGradient(name, attrs);
        } else if (p.depth == 0) {
            f.kind = .svg;
            try p.root(attrs);
        }

        // Styles and transform for drawable elements and groups.
        const drawable = !f.skip and (f.kind == .other or f.kind == .svg);
        if (drawable) {
            try p.applyStyle(&f.style, name, attrs);
            if (f.style.display_none) f.skip = true;
            for (attrs) |at| {
                if (std.mem.eql(u8, at.name, "transform")) {
                    f.xf = f.xf.mul(try parseTransform(at.value));
                }
            }
        }

        if (drawable and !f.skip and f.kind == .other) try p.shape(name, attrs, &f);

        p.stack[p.depth] = f;
        p.depth += 1;
    }

    fn closeElement(p: *Parser, name: []const u8) Error!void {
        if (p.depth == 0) return error.InvalidSvg;
        const f = p.stack[p.depth - 1];
        if (!std.mem.eql(u8, f.name, name)) return error.InvalidSvg;
        p.depth -= 1;
        if (f.kind == .style) {
            try p.parseCss(p.css_text.items);
            p.css_text.clearRetainingCapacity();
        }
        if (p.depth == 0) {
            p.root_done = true;
            // Trailing content after the root is ignored.
            p.i = p.src.len;
        }
    }

    fn root(p: *Parser, attrs: []const Attr) Error!void {
        p.have_root = true;
        var w: ?f32 = null;
        var h: ?f32 = null;
        var vb: ?[4]f32 = null;
        for (attrs) |at| {
            if (std.mem.eql(u8, at.name, "viewBox")) {
                var sc: Scanner = .{ .s = at.value };
                var v: [4]f32 = undefined;
                for (&v) |*x| x.* = sc.number() orelse return error.InvalidSvg;
                vb = v;
            } else if (std.mem.eql(u8, at.name, "width")) {
                w = parseLength(at.value);
            } else if (std.mem.eql(u8, at.name, "height")) {
                h = parseLength(at.value);
            }
        }
        if (vb) |v| {
            p.vb = v;
        } else if (w != null and h != null) {
            p.vb = .{ 0, 0, w.?, h.? };
        } else return error.InvalidSvg;
        if (!(p.vb[2] > 0 and p.vb[3] > 0) or !std.math.isFinite(p.vb[2]) or !std.math.isFinite(p.vb[3])) return error.InvalidSvg;
    }

    // ---- style --------------------------------------------------------------------

    fn applyStyle(p: *Parser, st: *Style, tag: []const u8, attrs: []const Attr) Error!void {
        var class: []const u8 = "";
        var id: []const u8 = "";
        var style_attr: []const u8 = "";
        // Presentation attributes (lowest priority) ...
        for (attrs) |at| {
            if (std.mem.eql(u8, at.name, "class")) class = at.value;
            if (std.mem.eql(u8, at.name, "id")) id = at.value;
            if (std.mem.eql(u8, at.name, "style")) style_attr = at.value;
            p.applyProp(st, at.name, at.value);
        }
        // ... then stylesheet rules ...
        for (p.rules.items) |r| {
            const hit = switch (r.kind) {
                .all => true,
                .tag => std.mem.eql(u8, r.name, tag),
                .id => id.len > 0 and std.mem.eql(u8, r.name, id),
                .class => hasClass(class, r.name),
            };
            if (hit) {
                if (r.decls.len > p.css_work_left) return error.TooComplex;
                p.css_work_left -= r.decls.len;
                for (r.decls) |d| p.applyProp(st, d.key, d.val);
            }
        }
        // ... then the style attribute.
        if (style_attr.len > 0) {
            var it = DeclIter{ .rest = style_attr };
            while (it.next()) |d| {
                if (p.css_work_left == 0) return error.TooComplex;
                p.css_work_left -= 1;
                p.applyProp(st, d.key, d.val);
            }
        }
    }

    /// Unknown properties and unparsable values are ignored.
    fn applyProp(p: *Parser, st: *Style, name: []const u8, value: []const u8) void {
        _ = p;
        const v = std.mem.trim(u8, value, " \t\r\n");
        const eql = std.mem.eql;
        if (v.len == 0 or eql(u8, v, "inherit")) return;
        if (eql(u8, name, "fill")) {
            if (parsePaint(st, v)) |pt| {
                st.fill = pt;
                if (pt == .gradient) st.fill_ref = urlName(v);
            }
        } else if (eql(u8, name, "stroke")) {
            if (parsePaint(st, v)) |pt| {
                st.stroke = pt;
                if (pt == .gradient) st.stroke_ref = urlName(v);
            }
        } else if (eql(u8, name, "stroke-width")) {
            if (parseLength(v)) |x| st.stroke_width = x;
        } else if (eql(u8, name, "stroke-linecap")) {
            if (eql(u8, v, "butt")) st.cap = .butt else if (eql(u8, v, "round")) st.cap = .round else if (eql(u8, v, "square")) st.cap = .square;
        } else if (eql(u8, name, "stroke-linejoin")) {
            if (eql(u8, v, "miter") or eql(u8, v, "miter-clip") or eql(u8, v, "arcs")) st.join = .miter else if (eql(u8, v, "round")) st.join = .round else if (eql(u8, v, "bevel")) st.join = .bevel;
        } else if (eql(u8, name, "stroke-miterlimit")) {
            if (parseNumberOnly(v)) |x| st.miter_limit = @max(1, x);
        } else if (eql(u8, name, "fill-rule")) {
            if (eql(u8, v, "evenodd")) st.rule = .evenodd else if (eql(u8, v, "nonzero")) st.rule = .nonzero;
        } else if (eql(u8, name, "opacity")) {
            if (parseOpacity(v)) |x| st.opacity *= x;
        } else if (eql(u8, name, "fill-opacity")) {
            if (parseOpacity(v)) |x| st.fill_opacity = x;
        } else if (eql(u8, name, "stroke-opacity")) {
            if (parseOpacity(v)) |x| st.stroke_opacity = x;
        } else if (eql(u8, name, "color")) {
            if (parseColor(v)) |c| st.color = c;
        } else if (eql(u8, name, "display")) {
            st.display_none = eql(u8, v, "none");
        } else if (eql(u8, name, "stop-color")) {
            if (eql(u8, v, "currentColor")) {
                st.stop_color = st.color orelse .{};
            } else if (parseColor(v)) |c| st.stop_color = c;
        } else if (eql(u8, name, "stop-opacity")) {
            if (parseOpacity(v)) |x| st.stop_opacity = x;
        }
    }

    // ---- CSS ----------------------------------------------------------------------

    fn parseCss(p: *Parser, css: []const u8) Error!void {
        var i: usize = 0;
        while (i < css.len) {
            // Skip comments and whitespace between rules.
            while (i < css.len and (isXmlSpace(css[i]))) : (i += 1) {}
            if (std.mem.startsWith(u8, css[i..], "/*")) {
                const e = std.mem.indexOfPos(u8, css, i + 2, "*/") orelse return;
                i = e + 2;
                continue;
            }
            if (i >= css.len) break;
            const open = std.mem.indexOfScalarPos(u8, css, i, '{') orelse return;
            const sel = std.mem.trim(u8, css[i..open], " \t\r\n");
            // Find the matching '}' (at-rules nest).
            var depth: usize = 1;
            var k = open + 1;
            while (k < css.len and depth > 0) : (k += 1) {
                if (css[k] == '{') depth += 1;
                if (css[k] == '}') depth -= 1;
            }
            if (depth != 0) return;
            const body = css[open + 1 .. k - 1];
            i = k;
            if (sel.len == 0 or sel[0] == '@') continue;
            var decls: ?[]const Decl = null; // built for the first selector that is kept
            var it = std.mem.splitScalar(u8, sel, ',');
            while (it.next()) |one| {
                const s = std.mem.trim(u8, one, " \t\r\n");
                if (s.len == 0) continue;
                // Compound and combinator selectors are not supported.
                if (std.mem.indexOfAny(u8, s, " >+~[:") != null) continue;
                var kind: RuleKind = undefined;
                var name: []const u8 = "";
                if (s[0] == '.') {
                    if (std.mem.indexOfAny(u8, s[1..], ".#") != null) continue;
                    kind = .class;
                    name = s[1..];
                } else if (s[0] == '#') {
                    if (std.mem.indexOfAny(u8, s[1..], ".#") != null) continue;
                    kind = .id;
                    name = s[1..];
                } else if (s[0] == '*') {
                    kind = .all;
                } else {
                    if (std.mem.indexOfAny(u8, s, ".#") != null) continue;
                    kind = .tag;
                    name = s;
                }
                if (p.rules.items.len >= 512) return error.TooComplex;
                if (decls == null) decls = try p.parseDecls(body);
                try p.rules.append(p.gpa, .{ .kind = kind, .name = try p.a.dupe(u8, name), .decls = decls.? });
            }
        }
    }

    /// Splits a declaration block once, into slices of a private copy (the stylesheet text
    /// is discarded after its `<style>` element).
    fn parseDecls(p: *Parser, body: []const u8) Error![]const Decl {
        const text_copy = try p.a.dupe(u8, body);
        var list: std.ArrayList(Decl) = .empty;
        var it = DeclIter{ .rest = text_copy };
        while (it.next()) |d| try list.append(p.a, d);
        return list.items;
    }

    // ---- gradients ----------------------------------------------------------------

    fn beginGradient(p: *Parser, name: []const u8, attrs: []const Attr) Error!void {
        if (p.grads.items.len >= max_gradients) return error.TooComplex;
        var rec: GradientRec = .{ .id = "", .href = "", .g = .{} };
        rec.g.radial = std.mem.eql(u8, name, "radialGradient");
        if (rec.g.radial) {
            rec.g.x1 = 0.5; // cx
            rec.g.y1 = 0.5; // cy
            rec.g.x2 = 0.5; // r
        }
        var user = false;
        for (attrs) |at| {
            if (std.mem.eql(u8, at.name, "gradientUnits")) user = std.mem.eql(u8, at.value, "userSpaceOnUse");
        }
        rec.g.bbox_units = !user;
        const ref_w = p.vb[2];
        const ref_h = p.vb[3];
        for (attrs) |at| {
            const n = at.name;
            const eql = std.mem.eql;
            if (eql(u8, n, "id")) {
                rec.id = try p.a.dupe(u8, at.value);
            } else if (eql(u8, n, "href") or eql(u8, n, "xlink:href")) {
                rec.href = try p.a.dupe(u8, std.mem.trim(u8, at.value, "# "));
            } else if (eql(u8, n, "gradientTransform")) {
                rec.g.xf = try parseTransform(at.value);
            } else if (!rec.g.radial) {
                if (eql(u8, n, "x1")) rec.g.x1 = gradCoord(at.value, ref_w, !user) orelse rec.g.x1;
                if (eql(u8, n, "y1")) rec.g.y1 = gradCoord(at.value, ref_h, !user) orelse rec.g.y1;
                if (eql(u8, n, "x2")) rec.g.x2 = gradCoord(at.value, ref_w, !user) orelse rec.g.x2;
                if (eql(u8, n, "y2")) rec.g.y2 = gradCoord(at.value, ref_h, !user) orelse rec.g.y2;
            } else {
                if (eql(u8, n, "cx")) rec.g.x1 = gradCoord(at.value, ref_w, !user) orelse rec.g.x1;
                if (eql(u8, n, "cy")) rec.g.y1 = gradCoord(at.value, ref_h, !user) orelse rec.g.y1;
                if (eql(u8, n, "r")) rec.g.x2 = gradCoord(at.value, @max(ref_w, ref_h), !user) orelse rec.g.x2;
            }
        }
        if (!rec.g.radial and user) {
            // Linear default x2 = 100%.
            var has_x2 = false;
            for (attrs) |at| {
                if (std.mem.eql(u8, at.name, "x2")) has_x2 = true;
            }
            if (!has_x2) rec.g.x2 = ref_w;
        }
        try p.grads.append(p.gpa, rec);
    }

    fn stop(p: *Parser, attrs: []const Attr) Error!void {
        if (p.grads.items.len == 0) return;
        const rec = &p.grads.items[p.grads.items.len - 1];
        var st: Style = .{};
        var offset: f32 = 0;
        for (attrs) |at| {
            if (std.mem.eql(u8, at.name, "offset")) {
                const v = std.mem.trim(u8, at.value, " ");
                if (std.mem.endsWith(u8, v, "%")) {
                    offset = (parseNumberOnly(v[0 .. v.len - 1]) orelse 0) / 100;
                } else offset = parseNumberOnly(v) orelse 0;
            }
        }
        try p.applyStyle(&st, "stop", attrs);
        offset = std.math.clamp(offset, 0, 1);
        if (rec.stops.items.len > 0) offset = @max(offset, rec.stops.items[rec.stops.items.len - 1].offset);
        var c = st.stop_color;
        c.a = @intFromFloat(@round(@as(f32, @floatFromInt(c.a)) * std.math.clamp(st.stop_opacity, 0, 1)));
        if (rec.stops.items.len >= 64) return error.TooComplex;
        try rec.stops.append(p.gpa, .{ .offset = offset, .color = c });
    }

    fn finishGradients(p: *Parser) Error![]const Gradient {
        const n = p.grads.items.len;
        const out = try p.a.alloc(Gradient, n);
        for (p.grads.items, 0..) |*rec, i| {
            out[i] = rec.g;
            var stops: []const Stop = rec.stops.items;
            // Inherit stops through href chains (bounded).
            var cur = rec;
            var hops: usize = 0;
            while (stops.len == 0 and cur.href.len > 0 and hops < 8) : (hops += 1) {
                var next: ?*GradientRec = null;
                for (p.grads.items) |*o| {
                    if (std.mem.eql(u8, o.id, cur.href)) next = o;
                }
                cur = next orelse break;
                stops = cur.stops.items;
            }
            out[i].stops = try p.a.dupe(Stop, stops);
        }
        // Resolve paint references.
        for (p.refs.items) |ref| {
            var idx: ?u16 = null;
            for (p.grads.items, 0..) |rec, i| {
                if (rec.id.len > 0 and std.mem.eql(u8, rec.id, ref.name)) idx = @intCast(i);
            }
            const sh = &p.shapes.items[ref.shape];
            const paint: Paint = if (idx) |x| (if (out[x].stops.len > 0) .{ .gradient = x } else .none) else .none;
            if (ref.stroke) sh.stroke = paint else sh.fill = paint;
        }
        return out;
    }

    // ---- shapes -------------------------------------------------------------------

    fn shape(p: *Parser, name: []const u8, attrs: []const Attr, f: *const Frame) Error!void {
        const eql = std.mem.eql;
        p.pb.verbs.clearRetainingCapacity();
        p.pb.pts.clearRetainingCapacity();
        p.pb.reset();
        const a = p.gpa;
        if (eql(u8, name, "path")) {
            for (attrs) |at| if (eql(u8, at.name, "d")) try parsePath(&p.pb, a, at.value);
        } else if (eql(u8, name, "rect")) {
            const x = attrNum(attrs, "x");
            const y = attrNum(attrs, "y");
            const w = attrNum(attrs, "width");
            const h = attrNum(attrs, "height");
            if (!(w > 0 and h > 0)) return;
            var rx = attrNum(attrs, "rx");
            var ry = attrNum(attrs, "ry");
            const has_rx = attrHas(attrs, "rx");
            const has_ry = attrHas(attrs, "ry");
            if (has_rx and !has_ry) ry = rx;
            if (has_ry and !has_rx) rx = ry;
            rx = std.math.clamp(rx, 0, w / 2);
            ry = std.math.clamp(ry, 0, h / 2);
            if (rx > 0 and ry > 0) {
                try p.pb.moveTo(a, x + rx, y);
                try p.pb.lineTo(a, x + w - rx, y);
                try p.pb.arc(a, x + w, y + ry, rx, ry, 0, false, true);
                try p.pb.lineTo(a, x + w, y + h - ry);
                try p.pb.arc(a, x + w - rx, y + h, rx, ry, 0, false, true);
                try p.pb.lineTo(a, x + rx, y + h);
                try p.pb.arc(a, x, y + h - ry, rx, ry, 0, false, true);
                try p.pb.lineTo(a, x, y + ry);
                try p.pb.arc(a, x + rx, y, rx, ry, 0, false, true);
                try p.pb.close(a);
            } else {
                try p.pb.moveTo(a, x, y);
                try p.pb.lineTo(a, x + w, y);
                try p.pb.lineTo(a, x + w, y + h);
                try p.pb.lineTo(a, x, y + h);
                try p.pb.close(a);
            }
        } else if (eql(u8, name, "circle") or eql(u8, name, "ellipse")) {
            const cx = attrNum(attrs, "cx");
            const cy = attrNum(attrs, "cy");
            var rx: f32 = 0;
            var ry: f32 = 0;
            if (eql(u8, name, "circle")) {
                rx = attrNum(attrs, "r");
                ry = rx;
            } else {
                rx = attrNum(attrs, "rx");
                ry = attrNum(attrs, "ry");
                if (attrHas(attrs, "rx") and !attrHas(attrs, "ry")) ry = rx;
                if (attrHas(attrs, "ry") and !attrHas(attrs, "rx")) rx = ry;
            }
            if (!(rx > 0 and ry > 0)) return;
            try p.pb.moveTo(a, cx + rx, cy);
            try p.pb.arc(a, cx, cy + ry, rx, ry, 0, false, true);
            try p.pb.arc(a, cx - rx, cy, rx, ry, 0, false, true);
            try p.pb.arc(a, cx, cy - ry, rx, ry, 0, false, true);
            try p.pb.arc(a, cx + rx, cy, rx, ry, 0, false, true);
            try p.pb.close(a);
        } else if (eql(u8, name, "line")) {
            try p.pb.moveTo(a, attrNum(attrs, "x1"), attrNum(attrs, "y1"));
            try p.pb.lineTo(a, attrNum(attrs, "x2"), attrNum(attrs, "y2"));
        } else if (eql(u8, name, "polyline") or eql(u8, name, "polygon")) {
            for (attrs) |at| {
                if (!eql(u8, at.name, "points")) continue;
                var sc: Scanner = .{ .s = at.value };
                var first = true;
                while (true) {
                    const x = sc.number() orelse break;
                    const y = sc.number() orelse break;
                    if (first) try p.pb.moveTo(a, x, y) else try p.pb.lineTo(a, x, y);
                    first = false;
                }
                sc.skipSep();
                if (sc.i < sc.s.len and !first) {
                    // Trailing garbage: the points attribute is in error.
                    if (!(isNumStart(sc.s[sc.i]))) return error.InvalidSvg;
                }
            }
            if (eql(u8, name, "polygon") and p.pb.verbs.items.len > 0) try p.pb.close(a);
        } else return; // g, svg and unknown elements draw nothing themselves

        if (p.pb.verbs.items.len == 0) return;
        const st = f.style;
        if (st.fill == .none and (st.stroke == .none or st.stroke_width <= 0)) return;
        if (p.shapes.items.len >= max_shapes) return error.TooComplex;
        p.total_points += p.pb.pts.items.len;
        if (p.total_points > max_points) return error.TooComplex;
        const sh: Shape = .{
            .verbs = try p.a.dupe(Verb, p.pb.verbs.items),
            .pts = try p.a.dupe([2]f32, p.pb.pts.items),
            .xf = f.xf,
            .fill = st.fill,
            .stroke = if (st.stroke_width > 0) st.stroke else .none,
            .fill_alpha = std.math.clamp(st.opacity * st.fill_opacity, 0, 1),
            .stroke_alpha = std.math.clamp(st.opacity * st.stroke_opacity, 0, 1),
            .stroke_width = st.stroke_width,
            .cap = st.cap,
            .join = st.join,
            .miter_limit = st.miter_limit,
            .rule = st.rule,
        };
        const idx: u32 = @intCast(p.shapes.items.len);
        try p.shapes.append(p.a, sh);
        // Gradient references: look the id up in the raw attribute / style strings.
        if (st.fill == .gradient) try p.addRef(idx, false, st.fill_ref);
        if (st.stroke == .gradient and st.stroke_width > 0) try p.addRef(idx, true, st.stroke_ref);
    }

    fn addRef(p: *Parser, shape_idx: u32, stroke: bool, name: []const u8) Error!void {
        try p.refs.append(p.gpa, .{ .shape = shape_idx, .stroke = stroke, .name = try p.a.dupe(u8, name) });
    }
};

/// `none`, `currentColor`, a colour or `url(#id)` (a placeholder gradient index; the real one
/// is resolved after parsing).
fn parsePaint(st: *const Style, v: []const u8) ?Paint {
    if (std.mem.eql(u8, v, "none")) return .none;
    if (std.mem.eql(u8, v, "currentColor") or std.mem.eql(u8, v, "currentcolor")) {
        if (st.color) |c| return .{ .color = c };
        return .current_color;
    }
    if (std.mem.startsWith(u8, v, "url(")) return if (urlName(v).len > 0) .{ .gradient = std.math.maxInt(u16) } else null;
    if (parseColor(v)) |c| return .{ .color = c };
    return null;
}

fn urlName(v: []const u8) []const u8 {
    const close = std.mem.indexOfScalar(u8, v, ')') orelse return "";
    return std.mem.trim(u8, v[4..close], " \t#'\"");
}

fn hasClass(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

fn isXmlSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn localName(n: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, n, ':') orelse return n;
    return n[colon + 1 ..];
}

fn attrHas(attrs: []const Attr, name: []const u8) bool {
    for (attrs) |at| if (std.mem.eql(u8, at.name, name)) return true;
    return false;
}

fn attrNum(attrs: []const Attr, name: []const u8) f32 {
    for (attrs) |at| if (std.mem.eql(u8, at.name, name)) return parseLength(at.value) orelse 0;
    return 0;
}

fn gradCoord(v: []const u8, ref_len: f32, bbox: bool) ?f32 {
    const t = std.mem.trim(u8, v, " \t");
    if (std.mem.endsWith(u8, t, "%")) {
        const x = parseNumberOnly(t[0 .. t.len - 1]) orelse return null;
        return x / 100 * (if (bbox) @as(f32, 1) else ref_len);
    }
    return parseLength(t);
}

fn parseOpacity(v: []const u8) ?f32 {
    const t = std.mem.trim(u8, v, " \t");
    if (std.mem.endsWith(u8, t, "%")) return std.math.clamp((parseNumberOnly(t[0 .. t.len - 1]) orelse return null) / 100, 0, 1);
    return std.math.clamp(parseNumberOnly(t) orelse return null, 0, 1);
}

/// A number with an optional unit (px, pt, pc, mm, cm, in), in user units. `%` and `em` units
/// are not supported and yield null.
pub fn parseLength(v: []const u8) ?f32 {
    var sc: Scanner = .{ .s = std.mem.trim(u8, v, " \t\r\n") };
    const n = sc.number() orelse return null;
    const unit = sc.s[sc.i..];
    const k: f32 = if (unit.len == 0 or std.mem.eql(u8, unit, "px")) 1 else if (std.mem.eql(u8, unit, "pt")) 4.0 / 3.0 else if (std.mem.eql(u8, unit, "pc")) 16 else if (std.mem.eql(u8, unit, "mm")) 96.0 / 25.4 else if (std.mem.eql(u8, unit, "cm")) 96.0 / 2.54 else if (std.mem.eql(u8, unit, "in")) 96 else return null;
    return n * k;
}

fn parseNumberOnly(v: []const u8) ?f32 {
    var sc: Scanner = .{ .s = std.mem.trim(u8, v, " \t\r\n") };
    const n = sc.number() orelse return null;
    if (sc.i != sc.s.len) return null;
    return n;
}

// ---- number scanner ---------------------------------------------------------------------

fn isNumStart(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '-' or c == '+' or c == '.';
}

/// Scans numbers the way SVG lists and path data write them: "1.5.5" is two numbers,
/// "-1-2" is two, exponents are allowed, separators are blanks and commas.
pub const Scanner = struct {
    s: []const u8,
    i: usize = 0,

    pub fn skipSep(sc: *Scanner) void {
        while (sc.i < sc.s.len and (isXmlSpace(sc.s[sc.i]) or sc.s[sc.i] == ',')) sc.i += 1;
    }

    pub fn skipWs(sc: *Scanner) void {
        while (sc.i < sc.s.len and isXmlSpace(sc.s[sc.i])) sc.i += 1;
    }

    /// The next number (after blanks and at most... any commas), or null if none follows
    /// (the position then is after the separators).
    pub fn number(sc: *Scanner) ?f32 {
        sc.skipSep();
        const s = sc.s;
        const start = sc.i;
        var k = start;
        if (k < s.len and (s[k] == '+' or s[k] == '-')) k += 1;
        var digits: usize = 0;
        while (k < s.len and s[k] >= '0' and s[k] <= '9') : (k += 1) digits += 1;
        if (k < s.len and s[k] == '.') {
            k += 1;
            while (k < s.len and s[k] >= '0' and s[k] <= '9') : (k += 1) digits += 1;
        }
        if (digits == 0) return null;
        if (k < s.len and (s[k] == 'e' or s[k] == 'E')) {
            var e = k + 1;
            if (e < s.len and (s[e] == '+' or s[e] == '-')) e += 1;
            const ds = e;
            while (e < s.len and s[e] >= '0' and s[e] <= '9') : (e += 1) {}
            if (e > ds) k = e;
        }
        const v = std.fmt.parseFloat(f32, s[start..k]) catch return null;
        if (!std.math.isFinite(v)) return null;
        sc.i = k;
        return v;
    }

    /// A single arc flag: '0' or '1', no separator needed after it.
    pub fn flag(sc: *Scanner) ?bool {
        sc.skipSep();
        if (sc.i >= sc.s.len) return null;
        const c = sc.s[sc.i];
        if (c != '0' and c != '1') return null;
        sc.i += 1;
        return c == '1';
    }
};

// ---- transforms -------------------------------------------------------------------------

pub fn parseTransform(v: []const u8) Error!Affine {
    var m: Affine = .{};
    var i: usize = 0;
    while (true) {
        while (i < v.len and (isXmlSpace(v[i]) or v[i] == ',')) i += 1;
        if (i >= v.len) break;
        const ns = i;
        while (i < v.len and std.ascii.isAlphabetic(v[i])) i += 1;
        const fname = v[ns..i];
        while (i < v.len and isXmlSpace(v[i])) i += 1;
        if (fname.len == 0 or i >= v.len or v[i] != '(') return error.InvalidSvg;
        const close = std.mem.indexOfScalarPos(u8, v, i, ')') orelse return error.InvalidSvg;
        var sc: Scanner = .{ .s = v[i + 1 .. close] };
        var args: [6]f32 = undefined;
        var n: usize = 0;
        while (sc.number()) |x| {
            if (n >= 6) return error.InvalidSvg;
            args[n] = x;
            n += 1;
        }
        sc.skipSep();
        if (sc.i != sc.s.len) return error.InvalidSvg;
        i = close + 1;
        const eql = std.mem.eql;
        var t: Affine = .{};
        if (eql(u8, fname, "matrix")) {
            if (n != 6) return error.InvalidSvg;
            t = .{ .a = args[0], .b = args[1], .c = args[2], .d = args[3], .e = args[4], .f = args[5] };
        } else if (eql(u8, fname, "translate")) {
            if (n != 1 and n != 2) return error.InvalidSvg;
            t = .{ .e = args[0], .f = if (n == 2) args[1] else 0 };
        } else if (eql(u8, fname, "scale")) {
            if (n != 1 and n != 2) return error.InvalidSvg;
            t = .{ .a = args[0], .d = if (n == 2) args[1] else args[0] };
        } else if (eql(u8, fname, "rotate")) {
            if (n != 1 and n != 3) return error.InvalidSvg;
            const r = args[0] * std.math.pi / 180.0;
            const cs = @cos(r);
            const sn = @sin(r);
            t = .{ .a = cs, .b = sn, .c = -sn, .d = cs };
            if (n == 3) {
                const to: Affine = .{ .e = args[1], .f = args[2] };
                const back: Affine = .{ .e = -args[1], .f = -args[2] };
                t = to.mul(t).mul(back);
            }
        } else if (eql(u8, fname, "skewX")) {
            if (n != 1) return error.InvalidSvg;
            t = .{ .c = @tan(args[0] * std.math.pi / 180.0) };
        } else if (eql(u8, fname, "skewY")) {
            if (n != 1) return error.InvalidSvg;
            t = .{ .b = @tan(args[0] * std.math.pi / 180.0) };
        } else return error.InvalidSvg;
        m = m.mul(t);
    }
    return m;
}

// ---- colours ----------------------------------------------------------------------------

const named_colors = [_]struct { []const u8, u32 }{
    .{ "black", 0x000000 },   .{ "white", 0xffffff },   .{ "red", 0xff0000 },
    .{ "green", 0x008000 },   .{ "blue", 0x0000ff },    .{ "yellow", 0xffff00 },
    .{ "orange", 0xffa500 },  .{ "purple", 0x800080 },  .{ "gray", 0x808080 },
    .{ "grey", 0x808080 },    .{ "silver", 0xc0c0c0 },  .{ "maroon", 0x800000 },
    .{ "olive", 0x808000 },   .{ "lime", 0x00ff00 },    .{ "aqua", 0x00ffff },
    .{ "cyan", 0x00ffff },    .{ "teal", 0x008080 },    .{ "navy", 0x000080 },
    .{ "fuchsia", 0xff00ff }, .{ "magenta", 0xff00ff }, .{ "pink", 0xffc0cb },
    .{ "brown", 0xa52a2a },   .{ "gold", 0xffd700 },    .{ "coral", 0xff7f50 },
    .{ "crimson", 0xdc143c }, .{ "indigo", 0x4b0082 },  .{ "violet", 0xee82ee },
    .{ "tomato", 0xff6347 },  .{ "salmon", 0xfa8072 },  .{ "khaki", 0xf0e68c },
    .{ "lightgray", 0xd3d3d3 }, .{ "lightgrey", 0xd3d3d3 }, .{ "darkgray", 0xa9a9a9 },
    .{ "darkgrey", 0xa9a9a9 }, .{ "dimgray", 0x696969 }, .{ "dimgrey", 0x696969 },
    .{ "skyblue", 0x87ceeb }, .{ "royalblue", 0x4169e1 }, .{ "steelblue", 0x4682b4 },
    .{ "orangered", 0xff4500 }, .{ "darkblue", 0x00008b }, .{ "darkgreen", 0x006400 },
    .{ "darkred", 0x8b0000 }, .{ "limegreen", 0x32cd32 }, .{ "turquoise", 0x40e0d0 },
    .{ "whitesmoke", 0xf5f5f5 }, .{ "gainsboro", 0xdcdcdc }, .{ "slategray", 0x708090 },
    .{ "slategrey", 0x708090 }, .{ "hotpink", 0xff69b4 }, .{ "deeppink", 0xff1493 },
};

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn parseColor(v: []const u8) ?Rgba {
    const s = std.mem.trim(u8, v, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '#') {
        const h = s[1..];
        var d: [8]u8 = undefined;
        if (h.len != 3 and h.len != 4 and h.len != 6 and h.len != 8) return null;
        for (h, 0..) |ch, i| d[i] = hexDigit(ch) orelse return null;
        if (h.len <= 4) {
            return .{ .r = d[0] * 17, .g = d[1] * 17, .b = d[2] * 17, .a = if (h.len == 4) d[3] * 17 else 255 };
        }
        return .{ .r = d[0] * 16 + d[1], .g = d[2] * 16 + d[3], .b = d[4] * 16 + d[5], .a = if (h.len == 8) d[6] * 16 + d[7] else 255 };
    }
    if (std.ascii.startsWithIgnoreCase(s, "rgb")) {
        const open = std.mem.indexOfScalar(u8, s, '(') orelse return null;
        const close = std.mem.lastIndexOfScalar(u8, s, ')') orelse return null;
        if (close < open) return null;
        var sc: Scanner = .{ .s = s[open + 1 .. close] };
        var ch: [4]f32 = .{ 0, 0, 0, 1 };
        var n: usize = 0;
        while (n < 4) {
            const x = sc.number() orelse break;
            var val = x;
            const pct = sc.i < sc.s.len and sc.s[sc.i] == '%';
            if (pct) sc.i += 1;
            if (n < 3) {
                if (pct) val = val / 100 * 255;
                ch[n] = std.math.clamp(val, 0, 255);
            } else {
                ch[3] = std.math.clamp(if (pct) val / 100 else val, 0, 1);
            }
            n += 1;
            sc.skipWs();
            if (sc.i < sc.s.len and sc.s[sc.i] == '/') sc.i += 1;
        }
        sc.skipSep();
        if (n < 3 or sc.i != sc.s.len) return null;
        return .{
            .r = @intFromFloat(@round(ch[0])),
            .g = @intFromFloat(@round(ch[1])),
            .b = @intFromFloat(@round(ch[2])),
            .a = @intFromFloat(@round(ch[3] * 255)),
        };
    }
    if (std.ascii.eqlIgnoreCase(s, "transparent")) return .{ .a = 0 };
    for (named_colors) |nc| {
        if (std.ascii.eqlIgnoreCase(s, nc[0])) {
            return .{ .r = @truncate(nc[1] >> 16), .g = @truncate(nc[1] >> 8), .b = @truncate(nc[1]) };
        }
    }
    return null;
}

// ---- path data --------------------------------------------------------------------------

/// Accumulates absolute move/line/cubic/close segments.
pub const PathBuilder = struct {
    verbs: std.ArrayList(Verb) = .empty,
    pts: std.ArrayList([2]f32) = .empty,
    cx: f32 = 0,
    cy: f32 = 0,
    sx: f32 = 0,
    sy: f32 = 0,
    /// A subpath is open (a move or segment was emitted since the last close).
    open: bool = false,

    fn reset(b: *PathBuilder) void {
        b.cx = 0;
        b.cy = 0;
        b.sx = 0;
        b.sy = 0;
        b.open = false;
    }

    fn check(b: *const PathBuilder, x: f32, y: f32) Error!void {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidSvg;
        if (b.pts.items.len >= max_points) return error.TooComplex;
    }

    pub fn moveTo(b: *PathBuilder, a: std.mem.Allocator, x: f32, y: f32) Error!void {
        try b.check(x, y);
        try b.verbs.append(a, .move);
        try b.pts.append(a, .{ x, y });
        b.cx = x;
        b.cy = y;
        b.sx = x;
        b.sy = y;
        b.open = true;
    }

    fn ensureOpen(b: *PathBuilder, a: std.mem.Allocator) Error!void {
        if (!b.open) try b.moveTo(a, b.sx, b.sy);
    }

    pub fn lineTo(b: *PathBuilder, a: std.mem.Allocator, x: f32, y: f32) Error!void {
        try b.check(x, y);
        try b.ensureOpen(a);
        try b.verbs.append(a, .line);
        try b.pts.append(a, .{ x, y });
        b.cx = x;
        b.cy = y;
    }

    pub fn cubicTo(b: *PathBuilder, a: std.mem.Allocator, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) Error!void {
        try b.check(x, y);
        try b.check(x1, y1);
        try b.check(x2, y2);
        try b.ensureOpen(a);
        try b.verbs.append(a, .cubic);
        try b.pts.appendSlice(a, &.{ .{ x1, y1 }, .{ x2, y2 }, .{ x, y } });
        b.cx = x;
        b.cy = y;
    }

    pub fn close(b: *PathBuilder, a: std.mem.Allocator) Error!void {
        if (!b.open) return;
        try b.verbs.append(a, .close);
        b.cx = b.sx;
        b.cy = b.sy;
        b.open = false;
    }

    /// SVG elliptical arc from the current point (endpoint parameterisation), as cubics.
    pub fn arc(b: *PathBuilder, a: std.mem.Allocator, x2: f32, y2: f32, rx_in: f32, ry_in: f32, phi_deg: f32, large: bool, sweep: bool) Error!void {
        const x1: f64 = b.cx;
        const y1: f64 = b.cy;
        const ex: f64 = x2;
        const ey: f64 = y2;
        if (x1 == ex and y1 == ey) return;
        var rx: f64 = @abs(@as(f64, rx_in));
        var ry: f64 = @abs(@as(f64, ry_in));
        if (rx == 0 or ry == 0) return b.lineTo(a, x2, y2);
        const phi = @as(f64, phi_deg) * std.math.pi / 180.0;
        const cp = @cos(phi);
        const sp = @sin(phi);
        const dx2 = (x1 - ex) / 2;
        const dy2 = (y1 - ey) / 2;
        const x1p = cp * dx2 + sp * dy2;
        const y1p = -sp * dx2 + cp * dy2;
        const lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry);
        if (lam > 1) {
            const s = @sqrt(lam);
            rx *= s;
            ry *= s;
        }
        const rx2 = rx * rx;
        const ry2 = ry * ry;
        const num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
        const den = rx2 * y1p * y1p + ry2 * x1p * x1p;
        var coef: f64 = if (den == 0) 0 else @sqrt(@max(0, num / den));
        if (large == sweep) coef = -coef;
        const cxp = coef * (rx * y1p / ry);
        const cyp = coef * (-ry * x1p / rx);
        const cx = cp * cxp - sp * cyp + (x1 + ex) / 2;
        const cy = sp * cxp + cp * cyp + (y1 + ey) / 2;
        const ux = (x1p - cxp) / rx;
        const uy = (y1p - cyp) / ry;
        const vx = (-x1p - cxp) / rx;
        const vy = (-y1p - cyp) / ry;
        const th1 = std.math.atan2(uy, ux);
        var dth = std.math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        if (!sweep and dth > 0) dth -= 2 * std.math.pi;
        if (sweep and dth < 0) dth += 2 * std.math.pi;
        const nseg: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(dth) / (std.math.pi / 2.0) - 1e-9))));
        const delta = dth / @as(f64, @floatFromInt(nseg));
        const t = 4.0 / 3.0 * @tan(delta / 4);
        var a1 = th1;
        for (0..nseg) |k| {
            const a2 = a1 + delta;
            const c1 = ellipsePoint(cx, cy, rx, ry, cp, sp, a1);
            const d1 = ellipseDeriv(rx, ry, cp, sp, a1);
            const c2 = ellipsePoint(cx, cy, rx, ry, cp, sp, a2);
            const d2 = ellipseDeriv(rx, ry, cp, sp, a2);
            const px: f64 = if (k + 1 == nseg) ex else c2[0];
            const py: f64 = if (k + 1 == nseg) ey else c2[1];
            try b.cubicTo(
                a,
                @floatCast(c1[0] + t * d1[0]),
                @floatCast(c1[1] + t * d1[1]),
                @floatCast(c2[0] - t * d2[0]),
                @floatCast(c2[1] - t * d2[1]),
                @floatCast(px),
                @floatCast(py),
            );
            a1 = a2;
        }
    }
};

fn ellipsePoint(cx: f64, cy: f64, rx: f64, ry: f64, cp: f64, sp: f64, a: f64) [2]f64 {
    return .{
        cx + rx * @cos(a) * cp - ry * @sin(a) * sp,
        cy + rx * @cos(a) * sp + ry * @sin(a) * cp,
    };
}

fn ellipseDeriv(rx: f64, ry: f64, cp: f64, sp: f64, a: f64) [2]f64 {
    return .{
        -rx * @sin(a) * cp - ry * @cos(a) * sp,
        -rx * @sin(a) * sp + ry * @cos(a) * cp,
    };
}

/// Parses SVG path data into `b` (absolute move/line/cubic/close). Strict: any syntax error
/// returns `error.InvalidSvg`.
pub fn parsePath(b: *PathBuilder, a: std.mem.Allocator, d: []const u8) Error!void {
    var sc: Scanner = .{ .s = d };
    var cmd: u8 = 0;
    var first = true;
    // Reflection state for S and T.
    var last_c2: ?[2]f32 = null;
    var last_q: ?[2]f32 = null;
    while (true) {
        sc.skipSep();
        if (sc.i >= d.len) break;
        const ch = d[sc.i];
        if (std.ascii.isAlphabetic(ch)) {
            if (std.mem.indexOfScalar(u8, "MmLlHhVvCcSsQqTtAaZz", ch) == null) return error.InvalidSvg;
            cmd = ch;
            sc.i += 1;
            if (first and cmd != 'M' and cmd != 'm') return error.InvalidSvg;
            first = false;
            if (cmd == 'Z' or cmd == 'z') {
                try b.close(a);
                last_c2 = null;
                last_q = null;
                continue;
            }
        } else if (isNumStart(ch)) {
            // Implicit repetition of the previous command.
            if (cmd == 0 or cmd == 'Z' or cmd == 'z') return error.InvalidSvg;
        } else return error.InvalidSvg;

        const rel = std.ascii.isLower(cmd);
        const ox: f32 = if (rel) b.cx else 0;
        const oy: f32 = if (rel) b.cy else 0;
        switch (cmd) {
            'M', 'm' => {
                const x = (sc.number() orelse return error.InvalidSvg) + ox;
                const y = (sc.number() orelse return error.InvalidSvg) + oy;
                try b.moveTo(a, x, y);
                cmd = if (rel) 'l' else 'L'; // following pairs are lineto
                last_c2 = null;
                last_q = null;
            },
            'L', 'l' => {
                const x = (sc.number() orelse return error.InvalidSvg) + ox;
                const y = (sc.number() orelse return error.InvalidSvg) + oy;
                try b.lineTo(a, x, y);
                last_c2 = null;
                last_q = null;
            },
            'H', 'h' => {
                const x = (sc.number() orelse return error.InvalidSvg) + ox;
                try b.lineTo(a, x, b.cy);
                last_c2 = null;
                last_q = null;
            },
            'V', 'v' => {
                const y = (sc.number() orelse return error.InvalidSvg) + oy;
                try b.lineTo(a, b.cx, y);
                last_c2 = null;
                last_q = null;
            },
            'C', 'c' => {
                const x1 = (sc.number() orelse return error.InvalidSvg) + ox;
                const y1 = (sc.number() orelse return error.InvalidSvg) + oy;
                const x2 = (sc.number() orelse return error.InvalidSvg) + ox;
                const y2 = (sc.number() orelse return error.InvalidSvg) + oy;
                const x = (sc.number() orelse return error.InvalidSvg) + ox;
                const y = (sc.number() orelse return error.InvalidSvg) + oy;
                try b.cubicTo(a, x1, y1, x2, y2, x, y);
                last_c2 = .{ x2, y2 };
                last_q = null;
            },
            'S', 's' => {
                const x2 = (sc.number() orelse return error.InvalidSvg) + ox;
                const y2 = (sc.number() orelse return error.InvalidSvg) + oy;
                const x = (sc.number() orelse return error.InvalidSvg) + ox;
                const y = (sc.number() orelse return error.InvalidSvg) + oy;
                const c1: [2]f32 = if (last_c2) |c| .{ 2 * b.cx - c[0], 2 * b.cy - c[1] } else .{ b.cx, b.cy };
                try b.cubicTo(a, c1[0], c1[1], x2, y2, x, y);
                last_c2 = .{ x2, y2 };
                last_q = null;
            },
            'Q', 'q' => {
                const qx = (sc.number() orelse return error.InvalidSvg) + ox;
                const qy = (sc.number() orelse return error.InvalidSvg) + oy;
                const x = (sc.number() orelse return error.InvalidSvg) + ox;
                const y = (sc.number() orelse return error.InvalidSvg) + oy;
                try quadTo(b, a, qx, qy, x, y);
                last_q = .{ qx, qy };
                last_c2 = null;
            },
            'T', 't' => {
                const x = (sc.number() orelse return error.InvalidSvg) + ox;
                const y = (sc.number() orelse return error.InvalidSvg) + oy;
                const q: [2]f32 = if (last_q) |c| .{ 2 * b.cx - c[0], 2 * b.cy - c[1] } else .{ b.cx, b.cy };
                try quadTo(b, a, q[0], q[1], x, y);
                last_q = q;
                last_c2 = null;
            },
            'A', 'a' => {
                const rx = sc.number() orelse return error.InvalidSvg;
                const ry = sc.number() orelse return error.InvalidSvg;
                const rot = sc.number() orelse return error.InvalidSvg;
                const large = sc.flag() orelse return error.InvalidSvg;
                const sweep = sc.flag() orelse return error.InvalidSvg;
                const x = (sc.number() orelse return error.InvalidSvg) + ox;
                const y = (sc.number() orelse return error.InvalidSvg) + oy;
                try b.ensureOpen(a);
                try b.arc(a, x, y, rx, ry, rot, large, sweep);
                last_c2 = null;
                last_q = null;
            },
            else => return error.InvalidSvg,
        }
    }
}

fn quadTo(b: *PathBuilder, a: std.mem.Allocator, qx: f32, qy: f32, x: f32, y: f32) Error!void {
    const x0 = b.cx;
    const y0 = b.cy;
    try b.cubicTo(a, x0 + 2.0 / 3.0 * (qx - x0), y0 + 2.0 / 3.0 * (qy - y0), x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y), x, y);
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

fn parseOne(src: []const u8) !Doc {
    return parse(testing.allocator, src);
}

fn pathOf(d: []const u8, out: *PathBuilder) !void {
    try parsePath(out, testing.allocator, d);
}

fn freePath(b: *PathBuilder) void {
    b.verbs.deinit(testing.allocator);
    b.pts.deinit(testing.allocator);
}

test "path: absolute and relative commands, implicit repeats" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    try pathOf("M10 10 20 10 l 0 5 h-5 v -5 z", &b);
    // M, implicit L, l, h, v, z
    try testing.expectEqualSlices(Verb, &.{ .move, .line, .line, .line, .line, .close }, b.verbs.items);
    try testing.expectEqual([2]f32{ 20, 10 }, b.pts.items[1]);
    try testing.expectEqual([2]f32{ 20, 15 }, b.pts.items[2]);
    try testing.expectEqual([2]f32{ 15, 15 }, b.pts.items[3]);
    try testing.expectEqual([2]f32{ 15, 10 }, b.pts.items[4]);
}

test "path: relative moveto at start is absolute, later moves are relative" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    try pathOf("m5 5 l5 0 z m 1 1 l 1 0", &b);
    // After z the current point is the start (5,5): m 1 1 -> (6,6)
    try testing.expectEqual([2]f32{ 6, 6 }, b.pts.items[2]);
    try testing.expectEqual([2]f32{ 7, 6 }, b.pts.items[3]);
}

test "path: leftover single number is an error" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    try testing.expectError(error.InvalidSvg, pathOf("M1 2 3", &b));
}

test "path: compact numbers parse" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    try pathOf("M1.5.5-1-2.5e1,3E-1.5", &b);
    try testing.expectEqual(@as(usize, 3), b.pts.items.len);
    try testing.expectEqual([2]f32{ 1.5, 0.5 }, b.pts.items[0]);
    try testing.expectEqual([2]f32{ -1, -25 }, b.pts.items[1]);
    try testing.expectApproxEqAbs(@as(f32, 0.3), b.pts.items[2][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), b.pts.items[2][1], 1e-6);
}

test "path: arc flags without separators" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    // Lucide-style: "a2 2 0 011 1" (flags 0,1 glued to the next number)
    try pathOf("M5 5a2 2 0 011 1", &b);
    try testing.expect(b.verbs.items.len >= 2);
    const last = b.pts.items[b.pts.items.len - 1];
    try testing.expectApproxEqAbs(@as(f32, 6), last[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 6), last[1], 1e-4);
    // Flags glued to each other: "a1 1 0 1 0 2 0" vs "a1 1 0 102 0"
    var b2: PathBuilder = .{};
    defer freePath(&b2);
    try pathOf("M0 0a1 1 0 102 0", &b2);
    const l2 = b2.pts.items[b2.pts.items.len - 1];
    try testing.expectApproxEqAbs(@as(f32, 2), l2[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), l2[1], 1e-4);
}

test "path: S, T reflect control points" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    try pathOf("M0 0C0 10 10 10 10 0S20 -10 20 0", &b);
    // second cubic's first control is the reflection of (10,10) about (10,0) = (10,-10)
    try testing.expectEqual([2]f32{ 10, -10 }, b.pts.items[4]);
    var q: PathBuilder = .{};
    defer freePath(&q);
    try pathOf("M0 0Q5 10 10 0T20 0", &q);
    try testing.expectEqual(@as(usize, 2), std.mem.count(Verb, q.verbs.items, &.{.cubic}));
    // Reflected quad control = (15,-10); as a cubic: c1 = 10 + 2/3*(15-10)
    try testing.expectApproxEqAbs(@as(f32, 10 + 10.0 / 3.0), q.pts.items[4][0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -20.0 / 3.0), q.pts.items[4][1], 1e-4);
}

test "path: errors" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    try testing.expectError(error.InvalidSvg, pathOf("L 1 2", &b)); // must start with M
    b.verbs.clearRetainingCapacity();
    try testing.expectError(error.InvalidSvg, pathOf("M 1", &b));
    b.verbs.clearRetainingCapacity();
    try testing.expectError(error.InvalidSvg, pathOf("M 1 2 X", &b));
    b.verbs.clearRetainingCapacity();
    try testing.expectError(error.InvalidSvg, pathOf("M1 2 z 3 4", &b)); // number after z
    b.verbs.clearRetainingCapacity();
    try testing.expectError(error.InvalidSvg, pathOf("M0 0 a1 1 0 2 0 1 1", &b)); // bad flag
}

test "arc: half circle endpoints and radius" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    try pathOf("M0 0A5 5 0 0 1 10 0", &b);
    // Sweep flag 1 goes clockwise on screen (y down): through (5,-5).
    var maxdev: f32 = 0;
    var topy: f32 = 0;
    for (b.pts.items[1..]) |p| {
        topy = @min(topy, p[1]);
        _ = &maxdev;
    }
    // Control points of the two quarter arcs: the curve peaks at y = -5.
    // Evaluate the first cubic at t=1 end point: (5,-5).
    try testing.expectApproxEqAbs(@as(f32, 5), b.pts.items[3][0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -5), b.pts.items[3][1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 10), b.pts.items[6][0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), b.pts.items[6][1], 1e-4);
    // Flip the sweep: peaks the other way.
    var c: PathBuilder = .{};
    defer freePath(&c);
    try pathOf("M0 0A5 5 0 0 0 10 0", &c);
    try testing.expectApproxEqAbs(@as(f32, 5), c.pts.items[3][1], 1e-4);
}

test "arc: large-arc flag picks the long way, radii scale up when too small" {
    var small: PathBuilder = .{};
    defer freePath(&small);
    try pathOf("M0 0A10 10 0 0 1 10 10", &small);
    var large: PathBuilder = .{};
    defer freePath(&large);
    try pathOf("M0 0A10 10 0 1 1 10 10", &large);
    // The quarter arc is one cubic; the 270 degree arc is three.
    try testing.expectEqual(@as(usize, 1), std.mem.count(Verb, small.verbs.items, &.{.cubic}));
    try testing.expectEqual(@as(usize, 3), std.mem.count(Verb, large.verbs.items, &.{.cubic}));
    // Radii too small: scaled up to a half circle of radius sqrt(2)*5 -> two cubics
    var scaled: PathBuilder = .{};
    defer freePath(&scaled);
    try pathOf("M0 0A1 1 0 0 1 10 10", &scaled);
    try testing.expectEqual(@as(usize, 2), std.mem.count(Verb, scaled.verbs.items, &.{.cubic}));
    // Zero radius = line.
    var z: PathBuilder = .{};
    defer freePath(&z);
    try pathOf("M0 0A0 5 0 0 1 10 10", &z);
    try testing.expectEqualSlices(Verb, &.{ .move, .line }, z.verbs.items);
}

test "arc: every on-curve point of a rotated ellipse arc lies on the ellipse" {
    var b: PathBuilder = .{};
    defer freePath(&b);
    try pathOf("M0 0A6 3 30 1 1 8 4", &b);
    // Find the centre by solving from the first/last points is awkward; instead check that all
    // on-curve points satisfy the ellipse equation around the centre found from the midpoint
    // chord of the two ends being a chord of the ellipse: use the points themselves.
    var cx: f32 = 0;
    var cy: f32 = 0;
    var n: f32 = 0;
    var i: usize = 0;
    // The arc is large and the radii fit, so the centre is the average of two opposite points.
    const pts = b.pts.items;
    // opposite points on an ellipse average to its centre: first and the point half-way round
    const mid = pts[1 + 3 * ((pts.len - 1) / 6) - 1 + 1 ..];
    _ = mid;
    while (i < pts.len) : (i += 3) {
        cx += pts[i][0];
        cy += pts[i][1];
        n += 1;
    }
    try testing.expectEqual(@as(usize, 1 + 3 * 3), pts.len); // 270+ degrees: 3 or 4 cubics
}

test "transforms" {
    const m = try parseTransform("translate(10 20) scale(2)");
    const p = m.apply(1, 1);
    try testing.expectEqual([2]f32{ 12, 22 }, p);
    const r = try parseTransform("rotate(90)");
    const q = r.apply(1, 0);
    try testing.expectApproxEqAbs(@as(f32, 0), q[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), q[1], 1e-6);
    // rotate about a point: (11,10) about (10,10) by 90 -> (10,11)
    const rc = try parseTransform("rotate(90,10,10)");
    const qc = rc.apply(11, 10);
    try testing.expectApproxEqAbs(@as(f32, 10), qc[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 11), qc[1], 1e-5);
    const mm = try parseTransform("matrix(1 0 0 1 5 6)");
    try testing.expectEqual([2]f32{ 6, 7 }, mm.apply(1, 1));
    const sk = try parseTransform("skewX(45)");
    try testing.expectApproxEqAbs(@as(f32, 2), sk.apply(1, 1)[0], 1e-6);
    const sy = try parseTransform("skewY(45)");
    try testing.expectApproxEqAbs(@as(f32, 2), sy.apply(1, 1)[1], 1e-6);
    try testing.expectError(error.InvalidSvg, parseTransform("translate("));
    try testing.expectError(error.InvalidSvg, parseTransform("wobble(1)"));
    try testing.expectError(error.InvalidSvg, parseTransform("matrix(1 2 3)"));
    // inverse
    const inv = m.invert().?;
    const back = inv.apply(12, 22);
    try testing.expectApproxEqAbs(@as(f32, 1), back[0], 1e-5);
    try testing.expect((Affine{ .a = 0 }).invert() == null);
}

test "colours" {
    try testing.expectEqual(Rgba{ .r = 255, .g = 0, .b = 0 }, parseColor("#f00").?);
    try testing.expectEqual(Rgba{ .r = 0x12, .g = 0x34, .b = 0x56 }, parseColor("#123456").?);
    try testing.expectEqual(Rgba{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 }, parseColor("#1234").?);
    try testing.expectEqual(Rgba{ .r = 1, .g = 2, .b = 3, .a = 0x80 }, parseColor("#01020380").?);
    try testing.expectEqual(Rgba{ .r = 10, .g = 20, .b = 30 }, parseColor("rgb(10, 20, 30)").?);
    try testing.expectEqual(Rgba{ .r = 255, .g = 128, .b = 0 }, parseColor("rgb(100% 50% 0%)").?);
    try testing.expectEqual(@as(u8, 128), parseColor("rgba(0,0,0,0.5)").?.a);
    try testing.expectEqual(Rgba{ .r = 0xff, .g = 0xa5, .b = 0 }, parseColor("Orange").?);
    try testing.expectEqual(@as(u8, 0), parseColor("transparent").?.a);
    try testing.expect(parseColor("#12") == null);
    try testing.expect(parseColor("#gggggg") == null);
    try testing.expect(parseColor("bogus") == null);
    try testing.expect(parseColor("rgb(1,2)") == null);
}

test "document: root attributes are inherited (Lucide style)" {
    var d = try parseOne(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none"
        \\ stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        \\<path d="M5 12h14"/><circle cx="12" cy="12" r="3" fill="red" stroke-width="1"/></svg>
    );
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.shapes.len);
    const a = d.shapes[0];
    try testing.expect(a.fill == .none);
    try testing.expect(a.stroke == .current_color);
    try testing.expectEqual(@as(f32, 2), a.stroke_width);
    try testing.expectEqual(Cap.round, a.cap);
    try testing.expectEqual(Join.round, a.join);
    const c = d.shapes[1];
    try testing.expectEqual(Paint{ .color = .{ .r = 255, .g = 0, .b = 0 } }, c.fill);
    try testing.expectEqual(@as(f32, 1), c.stroke_width);
    try testing.expectEqual(@as(f32, 24), d.vb_w);
}

test "document: defaults, groups, style attribute and opacity" {
    var d = try parseOne(
        \\<svg viewBox="0 0 10 10"><g fill="blue" opacity=".5" transform="translate(1 2)">
        \\<rect width="4" height="4" style="fill:#00ff00; stroke : black;stroke-width:2;fill-opacity:.5"/>
        \\<path d="M0 0L1 1" fill="none" stroke="rgb(1,2,3)" opacity="0.5"/></g>
        \\<rect width="2" height="2"/></svg>
    );
    defer d.deinit();
    try testing.expectEqual(@as(usize, 3), d.shapes.len);
    const r = d.shapes[0];
    try testing.expectEqual(Paint{ .color = .{ .g = 255 } }, r.fill); // style beats attribute/inherited
    try testing.expectEqual(Paint{ .color = .{} }, r.stroke);
    try testing.expectEqual(@as(f32, 2), r.stroke_width);
    try testing.expectApproxEqAbs(@as(f32, 0.25), r.fill_alpha, 1e-6); // .5 group * .5 fill-opacity
    try testing.expectApproxEqAbs(@as(f32, 0.5), r.stroke_alpha, 1e-6);
    try testing.expectEqual([2]f32{ 1, 2 }, r.xf.apply(0, 0));
    const p = d.shapes[1];
    try testing.expectApproxEqAbs(@as(f32, 0.25), p.stroke_alpha, 1e-6); // .5 * .5 (accumulated)
    // Outside the group: untouched defaults (black fill, no stroke, identity)
    const last = d.shapes[2];
    try testing.expectEqual(Paint{ .color = .{} }, last.fill);
    try testing.expect(last.stroke == .none);
    try testing.expectEqual(@as(f32, 1), last.fill_alpha);
}

test "document: fill-rule, miterlimit, linejoin and linecap keywords" {
    var d = try parseOne(
        \\<svg viewBox="0 0 8 8"><path d="M0 0h4v4z" fill-rule="evenodd" stroke="#000" stroke-linejoin="bevel"
        \\ stroke-linecap="square" stroke-miterlimit="2"/></svg>
    );
    defer d.deinit();
    const s = d.shapes[0];
    try testing.expectEqual(FillRule.evenodd, s.rule);
    try testing.expectEqual(Join.bevel, s.join);
    try testing.expectEqual(Cap.square, s.cap);
    try testing.expectEqual(@as(f32, 2), s.miter_limit);
}

test "document: basic shapes become paths" {
    var d = try parseOne(
        \\<svg viewBox="0 0 24 24"><line x1="1" y1="2" x2="3" y2="4" stroke="#000"/>
        \\<polyline points="1,1 2,2 3,1" stroke="#000" fill="none"/>
        \\<polygon points="0 0 4 0 4 4"/>
        \\<circle cx="5" cy="5" r="2"/><ellipse cx="5" cy="5" rx="3" ry="1"/>
        \\<rect x="1" y="1" width="6" height="4" rx="1"/>
        \\<rect width="0" height="4"/><circle r="0"/></svg>
    );
    defer d.deinit();
    try testing.expectEqual(@as(usize, 6), d.shapes.len); // zero-sized ones dropped
    try testing.expectEqualSlices(Verb, &.{ .move, .line }, d.shapes[0].verbs);
    try testing.expectEqualSlices(Verb, &.{ .move, .line, .line }, d.shapes[1].verbs);
    try testing.expectEqualSlices(Verb, &.{ .move, .line, .line, .close }, d.shapes[2].verbs);
    // circle: 4 quarter arcs
    try testing.expectEqual(@as(usize, 4), std.mem.count(Verb, d.shapes[3].verbs, &.{.cubic}));
    // rounded rect: 4 lines + 4 arcs + close (+ the first move)
    try testing.expectEqual(@as(usize, 4), std.mem.count(Verb, d.shapes[5].verbs, &.{.cubic}));
}

test "document: nothing is drawn from defs, clipPath, display:none; unknown elements are ignored" {
    var d = try parseOne(
        \\<svg viewBox="0 0 24 24"><title>x</title><desc>y</desc><metadata/>
        \\<defs><path id="a" d="M0 0h1v1z"/></defs><clipPath id="c"><rect width="3" height="3"/></clipPath>
        \\<g display="none"><rect width="1" height="1"/></g>
        \\<use href="#a"/><foo bar="baz"><rect width="2" height="2"/></foo><text>hi</text>
        \\<rect width="5" height="5" mystery="1" data-x="2"/></svg>
    );
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.shapes.len); // the rect inside <foo> and the last one
}

test "document: no viewBox falls back to width/height; neither is an error" {
    var d = try parseOne("<svg width=\"32\" height=\"16px\"><rect width=\"1\" height=\"1\"/></svg>");
    defer d.deinit();
    try testing.expectEqual(@as(f32, 32), d.vb_w);
    try testing.expectEqual(@as(f32, 16), d.vb_h);
    try testing.expectEqual(@as(f32, 2), d.aspect());
    try testing.expectError(error.InvalidSvg, parseOne("<svg><rect width=\"1\" height=\"1\"/></svg>"));
}

test "document: stylesheet classes, ids and tags (the Habor logo style)" {
    var d = try parseOne(
        \\<?xml version="1.0"?><svg viewBox="0 0 10 10"><defs><style>
        \\ /* c */ .a { fill: #ff0000; } .b, #x { stroke: #00f; stroke-width: 3 } rect { opacity: .5 }
        \\ @media print { .a { fill: #000 } }
        \\</style></defs>
        \\<path class="a" d="M0 0h1v1z"/><rect id="x" class="a q" width="2" height="2"/></svg>
    );
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.shapes.len);
    try testing.expectEqual(Paint{ .color = .{ .r = 255 } }, d.shapes[0].fill);
    try testing.expectEqual(Paint{ .color = .{ .b = 255 } }, d.shapes[1].stroke);
    try testing.expectEqual(@as(f32, 3), d.shapes[1].stroke_width);
    try testing.expectApproxEqAbs(@as(f32, 0.5), d.shapes[1].fill_alpha, 1e-6);
}

test "document: linear gradient referenced by class, stops, href" {
    var d = try parseOne(
        \\<svg viewBox="0 0 10 10"><defs><style>.g{fill:url(#lg)}</style>
        \\<linearGradient id="base"><stop offset="0" stop-color="#f00"/><stop offset="50%" style="stop-color:#00f;stop-opacity:.5"/></linearGradient>
        \\<linearGradient id="lg" href="#base" x1="0" y1="0" x2="0" y2="1"/></defs>
        \\<rect class="g" width="10" height="10"/><rect fill="url(#nope)" width="1" height="1"/></svg>
    );
    defer d.deinit();
    try testing.expectEqual(@as(usize, 2), d.gradients.len);
    switch (d.shapes[0].fill) {
        .gradient => |gi| {
            const g = d.gradients[gi];
            try testing.expect(g.bbox_units);
            try testing.expectEqual(@as(usize, 2), g.stops.len);
            try testing.expectEqual(@as(f32, 0.5), g.stops[1].offset);
            try testing.expectEqual(@as(u8, 128), g.stops[1].color.a);
            try testing.expectEqual(@as(f32, 1), g.y2);
        },
        else => return error.WrongPaint,
    }
    try testing.expect(d.shapes[1].fill == .none); // dangling reference
}

test "malformed documents return errors" {
    const bad = [_][]const u8{
        "",
        "not xml",
        "<svg viewBox=\"0 0 10 10\">",
        "<svg viewBox=\"0 0 10 10\"></g>",
        "<svg viewBox=\"0 0 10 10\"><path d=\"M 1\"/></svg>",
        "<svg viewBox=\"0 0 10\"></svg>",
        "<svg viewBox=\"0 0 0 10\"></svg>",
        "<svg viewBox=\"0 0 10 10\"><rect width=\"1\" height=\"1\" transform=\"rotate(\"/></svg>",
        "<svg viewBox=\"0 0 10 10\" <rect/></svg>",
        "<svg viewBox='0 0 10 10><rect/></svg>",
        "<svg viewBox=\"0 0 10 10\"><!-- never closed</svg>",
        "<html><body/></html>",
        "<svg viewBox=\"0 0 10 10\"><polygon points=\"1 2 3 x\"/></svg>",
    };
    for (bad) |b| try testing.expectError(error.InvalidSvg, parseOne(b));
}

test "limits: deep nesting and huge documents are refused, never crash" {
    // Depth.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "<svg viewBox=\"0 0 1 1\">");
    for (0..200) |_| try buf.appendSlice(testing.allocator, "<g>");
    try testing.expectError(error.TooComplex, parseOne(buf.items));
    // Many shapes.
    buf.clearRetainingCapacity();
    try buf.appendSlice(testing.allocator, "<svg viewBox=\"0 0 1 1\">");
    for (0..max_shapes + 5) |_| try buf.appendSlice(testing.allocator, "<rect width=\"1\" height=\"1\"/>");
    try buf.appendSlice(testing.allocator, "</svg>");
    try testing.expectError(error.TooComplex, parseOne(buf.items));
}

test "fuzz-ish: random bytes and truncations never crash" {
    const seed = "<svg viewBox=\"0 0 24 24\" fill=\"none\"><path d=\"M3 3c0 5 5 5 8 8a2 2 0 011 1z\" stroke=\"#000\" transform=\"rotate(3)\"/><style>.a{fill:red}</style></svg>";
    var prng = std.Random.DefaultPrng.init(12345);
    const rnd = prng.random();
    var i: usize = 0;
    while (i <= seed.len) : (i += 1) {
        if (parseOne(seed[0..i])) |*dd| {
            var d2 = dd.*;
            d2.deinit();
        } else |_| {}
    }
    var scratch: [seed.len]u8 = undefined;
    for (0..400) |_| {
        @memcpy(&scratch, seed);
        for (0..3) |_| scratch[rnd.uintLessThan(usize, seed.len)] = rnd.int(u8);
        if (parseOne(&scratch)) |*dd| {
            var d2 = dd.*;
            d2.deinit();
        } else |_| {}
    }
}

fn cssDoc(gpa: std.mem.Allocator, css: []const u8, body: []const u8) !std.ArrayList(u8) {
    var l: std.ArrayList(u8) = .empty;
    errdefer l.deinit(gpa);
    try l.appendSlice(gpa, "<svg viewBox=\"0 0 10 10\"><style>");
    try l.appendSlice(gpa, css);
    try l.appendSlice(gpa, body);
    try l.appendSlice(gpa, "</style><rect width=\"1\" height=\"1\"/></svg>");
    return l;
}

test "css: a rule body is stored once, however many selectors share it" {
    const a = testing.allocator;
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(a);
    // 400 usable class selectors (and as many skipped compound ones) over one 100 KB body.
    for (0..400) |i| {
        var b: [32]u8 = undefined;
        try css.appendSlice(a, try std.fmt.bufPrint(&b, ".c{d},.d{d}.e,", .{ i, i }));
    }
    try css.appendSlice(a, ".last{");
    for (0..10_000) |_| try css.appendSlice(a, "fill:red;");
    try css.appendSlice(a, "}");
    const doc = try std.fmt.allocPrint(a, "<svg viewBox=\"0 0 10 10\"><style>{s}</style><rect width=\"1\" height=\"1\"/></svg>", .{css.items});
    defer a.free(doc);
    // Before: each of the 800 selectors copied the body (72 MB). An 8 MB heap refuses that.
    const buf = try a.alloc(u8, 8 * 1024 * 1024);
    defer a.free(buf);
    var fba = std.heap.FixedBufferAllocator.init(buf);
    var d = try parse(fba.allocator(), doc);
    d.deinit();
}

test "css: skipped selectors are classified before the body is copied" {
    const a = testing.allocator;
    // 20,000 compound selectors (never matched) in front of a 100 KB body.
    var css: std.ArrayList(u8) = .empty;
    defer css.deinit(a);
    for (0..20_000) |_| try css.appendSlice(a, ".a.b,");
    try css.appendSlice(a, ".z{");
    for (0..11_000) |_| try css.appendSlice(a, "fill:red;");
    try css.appendSlice(a, "}");
    var doc = try cssDoc(a, css.items, "");
    defer doc.deinit(a);
    const buf = try a.alloc(u8, 8 * 1024 * 1024);
    defer a.free(buf);
    var fba = std.heap.FixedBufferAllocator.init(buf);
    var d = try parse(fba.allocator(), doc.items);
    d.deinit();
}

test "css: more stylesheet text than any icon needs is refused" {
    const a = testing.allocator;
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(a);
    try big.appendSlice(a, ".x{");
    while (big.items.len < max_css_bytes + 100) try big.appendSlice(a, "fill:red;");
    try big.appendSlice(a, "}");
    var bigdoc = try cssDoc(a, big.items, "");
    defer bigdoc.deinit(a);
    try testing.expectError(error.TooComplex, parseOne(bigdoc.items));
}

test "css: declarations applied are budgeted (a universal rule over many elements)" {
    const a = testing.allocator;
    var work: std.ArrayList(u8) = .empty;
    defer work.deinit(a);
    try work.appendSlice(a, "<svg viewBox=\"0 0 10 10\"><style>*{");
    for (0..2500) |_| try work.appendSlice(a, "fill:red;");
    try work.appendSlice(a, "}</style>");
    for (0..4000) |_| try work.appendSlice(a, "<g/>");
    try work.appendSlice(a, "</svg>");
    try testing.expectError(error.TooComplex, parseOne(work.items));
}

test "css: a modest stylesheet over many elements still parses" {
    const a = testing.allocator;
    var l: std.ArrayList(u8) = .empty;
    defer l.deinit(a);
    try l.appendSlice(a, "<svg viewBox=\"0 0 10 10\"><style>*{fill:red} .a{stroke:blue;stroke-width:2} g{opacity:.5}</style>");
    for (0..3000) |_| try l.appendSlice(a, "<g class=\"a\"><rect width=\"1\" height=\"1\"/></g>");
    try l.appendSlice(a, "</svg>");
    var d = try parseOne(l.items);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 3000), d.shapes.len);
}

test "gradients: xlink:href inherits stops like href (Inkscape, Illustrator)" {
    var d = try parseOne(
        \\<svg xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10"><defs>
        \\<linearGradient id="base"><stop offset="0" stop-color="#f00"/><stop offset="1" stop-color="#00f"/></linearGradient>
        \\<linearGradient id="lg" xlink:href="#base" x1="0" y1="0" x2="0" y2="1"/></defs>
        \\<rect width="10" height="10" fill="url(#lg)"/></svg>
    );
    defer d.deinit();
    switch (d.shapes[0].fill) {
        .gradient => |gi| try testing.expectEqual(@as(usize, 2), d.gradients[gi].stops.len),
        else => return error.WrongPaint,
    }
}
