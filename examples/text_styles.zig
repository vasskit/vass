//! Text styles: weights, italic, monospace, underline and strikethrough, and how runs of
//! different styles share one baseline using the font metrics.
//!
//!     zig build text_styles                      run it
//!     zig build text_styles -- --snapshot DIR    save DIR/text_styles.bmp and exit
const std = @import("std");
const vass = @import("vass");
const harness = @import("common/harness.zig");

const Ui = vass.Ui;
const TextStyle = vass.gfx.TextStyle;

const App = struct {};

const Row = struct { name: []const u8, style: TextStyle };

const rows = [_]Row{
    .{ .name = "regular", .style = .{} },
    .{ .name = "medium", .style = .{ .weight = .medium } },
    .{ .name = "semibold", .style = .{ .weight = .semibold } },
    .{ .name = "bold", .style = .{ .weight = .bold } },
    .{ .name = "italic", .style = .{ .italic = true } },
    .{ .name = "bold italic", .style = .{ .weight = .bold, .italic = true } },
    .{ .name = "mono", .style = .{ .mono = true } },
    .{ .name = "mono bold", .style = .{ .mono = true, .weight = .bold } },
    .{ .name = "underline", .style = .{ .underline = true } },
    .{ .name = "strikethrough", .style = .{ .strikethrough = true } },
    .{ .name = "underline + italic", .style = .{ .italic = true, .underline = true } },
};

const Run = struct { str: []const u8, style: TextStyle };

const runs = [_]Run{
    .{ .str = "Runs of ", .style = .{} },
    .{ .str = "bold", .style = .{ .weight = .bold } },
    .{ .str = ", ", .style = .{} },
    .{ .str = "italic", .style = .{ .italic = true } },
    .{ .str = " and ", .style = .{} },
    .{ .str = "code()", .style = .{ .mono = true } },
    .{ .str = " with \u{1F600} and \u{4F60}\u{597D} ", .style = .{} },
    .{ .str = "struck", .style = .{ .strikethrough = true } },
    .{ .str = " ", .style = .{} },
    .{ .str = "linked", .style = .{ .underline = true, .weight = .semibold } },
};

pub fn frame(app: *App, ui: *Ui) void {
    _ = app;
    const t = ui.theme;
    var area = ui.bounds.inset(24);
    const sample = "The quick brown fox 0123 iiWW";
    const size: f32 = 17;

    for (rows) |row| {
        const r = area.cutTop(28);
        ui.labelAt(r.x, r.y + 5, row.name, .{ .size = t.font_label, .color = t.dim });
        ui.labelAt(r.x + 150, r.y, sample, .{ .size = size, .style = row.style });
    }

    // Runs side by side: each is placed by its own width and drawn so that its baseline is the
    // line's baseline, whatever its face's ascent is.
    _ = area.cutTop(14);
    const line = area.cutTop(34);
    var ascent: f32 = 0;
    for (runs) |run| ascent = @max(ascent, ui.fontMetrics(size, run.style).ascent);
    const baseline = line.y + ascent;
    var x = line.x;
    for (runs) |run| {
        const m = ui.fontMetrics(size, run.style);
        ui.labelAt(x, baseline - m.ascent, run.str, .{ .size = size, .style = run.style });
        x += ui.measureStyled(run.str, size, run.style);
    }
    ui.list.rect(.{ .x = line.x, .y = baseline, .w = x - line.x, .h = 1 }, t.accent.alpha(160));

    _ = area.cutTop(12);
    for ([_]f32{ 14, 28 }) |sz| {
        const m = ui.fontMetrics(sz, .{});
        ui.labelFmt(area.cutTop(22), "size {d}: ascent {d:.2}  descent {d:.2}  line height {d:.2}", .{ sz, m.ascent, m.descent, m.line_height }, .{ .size = t.font_body, .style = .{ .mono = true } });
    }
}

pub fn main(init: std.process.Init) !void {
    const env = try harness.start(init, "text_styles", .{}) orelse return;
    var app: App = .{};
    try harness.run(@This(), env, .{ .window = .{ .title = "Text styles", .width = 640, .height = 520 } }, &app);
}
