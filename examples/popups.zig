//! A showcase of popups: dropdowns (select controls), a button menu with icons, shortcuts,
//! a separator and disabled and danger items, a right-click context menu, a popover with a
//! dropdown inside it (nested popups), a modal confirm dialog and tooltips on icon buttons.
//! Fully interactive.
//!
//!     zig build popups                      run it
//!     zig build popups -- --snapshot DIR    save DIR/popups-1-tooltip.bmp, popups-2-menus.bmp,
//!                                           popups-3-popover.bmp and popups-4-modal.bmp
//!                                           (each scripted into its open state), and exit
const std = @import("std");
const vass = @import("vass");

const Rect = vass.Rect;
const Ui = vass.Ui;
const ui_mod = vass.ui;

const win_w = 780;
const win_h = 560;
const margin: f32 = 28;
const col_w: f32 = 330;
const row_h: f32 = 34;

const sizes = [_][]const u8{ "Small", "Medium", "Large", "Extra large" };
const sorts = [_][]const u8{ "Newest first", "Oldest first", "Name", "Size" };
const actions = [_]vass.MenuItem{
    .{ .label = "New file", .icon = .plus, .shortcut = "Cmd+N" },
    .{ .label = "Find", .icon = .search, .shortcut = "Cmd+F" },
    .{ .label = "Preferences", .icon = .sliders, .shortcut = "Cmd+," },
    .{ .separator = true },
    .{ .label = "Export...", .icon = .arrow_up, .disabled = true },
    .{ .separator = true },
    .{ .label = "Delete", .icon = .more, .shortcut = "Del", .danger = true },
};
const context_items = [_]vass.MenuItem{
    .{ .label = "Copy", .shortcut = "Cmd+C" },
    .{ .label = "Paste", .shortcut = "Cmd+V", .disabled = true },
    .{ .separator = true },
    .{ .label = "Rename" },
    .{ .label = "Remove", .danger = true },
};

const App = struct {
    state: ui_mod.State = .{},
    size_dd: vass.ui.DropdownState = .{},
    size_sel: usize = 1,
    open_dd: vass.ui.DropdownState = .{},
    open_sel: usize = 2,
    disabled_dd: vass.ui.DropdownState = .{},
    disabled_sel: usize = 0,
    sort_dd: vass.ui.DropdownState = .{},
    sort_sel: usize = 0,
    actions_menu: vass.PopupState = .{},
    context: vass.PopupState = .{},
    popover: vass.PopupState = .{},
    starred: bool = true,
    modal: vass.PopupState = .{},
    last: [96]u8 = undefined,
    last_len: usize = 0,
    /// Centre of the second tooltip button (the snapshot script rests the pointer there).
    tip_center: [2]f32 = .{ 0, 0 },

    fn say(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.last_len = if (std.fmt.bufPrint(&app.last, fmt, args)) |str| str.len else |_| 0;
    }
};

fn heading(ui: *Ui, x: f32, y: f32, str: []const u8) void {
    ui.labelAt(x, y, str, .{ .size = 11, .color = ui.theme.dim, .weight = .semibold });
}

fn dangerButton(ui: *Ui, r: Rect, str: []const u8) bool {
    const t = ui.theme;
    const hv = ui.hit(r);
    ui.list.rrect(r, 10, if (hv.hovered) vass.ui.mixColor(t.bad, t.text, 0.12) else t.bad);
    ui.list.textWeighted(r.x + r.w / 2, r.y + @round((r.h - 14.5) / 2), 12, t.accent_text, .center, .semibold, str);
    return hv.clicked;
}

fn frame(app: *App, ui: *Ui) void {
    const t = ui.theme;
    var y: f32 = 22;
    ui.labelAt(margin, y, "Popups", .{ .size = 24 });
    y += 56;
    const left = margin;
    const right = margin * 2 + col_w;

    // ---- left column -------------------------------------------------------------------
    var ly = y;
    heading(ui, left, ly, "DROPDOWN");
    ly += 22;
    if (ui.dropdown(.{ .x = left, .y = ly, .w = 220, .h = row_h }, &app.size_dd, &sizes, &app.size_sel, .{})) app.say("Size: {s}", .{sizes[app.size_sel]});
    ly += row_h + 10;
    _ = ui.dropdown(.{ .x = left, .y = ly, .w = 220, .h = row_h }, &app.open_dd, &sizes, &app.open_sel, .{});
    ly += row_h + 10;
    _ = ui.dropdown(.{ .x = left, .y = ly, .w = 220, .h = row_h }, &app.disabled_dd, &sizes, &app.disabled_sel, .{ .disabled = true });
    ly += row_h + 96; // room for the open one above to show its menu over this space

    heading(ui, left, ly, "MENU");
    ly += 22;
    const menu_btn: Rect = .{ .x = left, .y = ly, .w = 130, .h = row_h };
    if (ui.button(menu_btn, "Actions", .{ .on = app.actions_menu.open })) ui.openPopup(&app.actions_menu);
    if (ui.menu(&app.actions_menu, menu_btn, &actions, .{})) |i| app.say("Menu: {s}", .{actions[i].label});
    ly += row_h + 24;

    heading(ui, left, ly, "CONTEXT MENU");
    ly += 22;
    const area: Rect = .{ .x = left, .y = ly, .w = col_w, .h = 84 };
    ui.card(area);
    ui.label(.{ .x = area.x, .y = area.y + 30, .w = area.w, .h = 20 }, "Right-click anywhere in this card", .{ .@"align" = .center, .color = t.dim });
    if (ui.contextMenu(&app.context, area, &context_items, .{})) |i| app.say("Context: {s}", .{context_items[i].label});

    // ---- right column ------------------------------------------------------------------
    var ry = y;
    heading(ui, right, ry, "POPOVER (A DROPDOWN INSIDE A POPUP)");
    ry += 22;
    const pop_btn: Rect = .{ .x = right, .y = ry, .w = 130, .h = row_h };
    if (ui.button(pop_btn, "Filters", .{ .on = app.popover.open })) ui.openPopup(&app.popover);
    if (ui.beginPopup(&app.popover, pop_btn, .{ 270, 176 }, .{ .padding = 14 })) |c| {
        var cy = c.y;
        ui.labelAt(c.x, cy, "Filters", .{ .size = 13, .weight = .semibold });
        cy += 28;
        ui.labelAt(c.x, cy + 3, "Only starred", .{});
        _ = ui.toggle(.{ .x = c.x + c.w - 40, .y = cy - 3, .w = 40, .h = 26 }, &app.starred, .{});
        cy += 34;
        ui.labelAt(c.x, cy - 2, "Sort by", .{ .size = 11, .color = t.dim });
        cy += 16;
        _ = ui.dropdown(.{ .x = c.x, .y = cy, .w = c.w, .h = 30 }, &app.sort_dd, &sorts, &app.sort_sel, .{});
        cy += 40;
        if (ui.button(.{ .x = c.x + c.w - 70, .y = cy, .w = 70, .h = 28 }, "Done", .{})) {
            ui.closePopup(&app.popover);
            app.say("Filters: {s}", .{sorts[app.sort_sel]});
        }
        ui.endPopup();
    }
    ry += row_h + 36;

    heading(ui, right, ry, "MODAL DIALOG");
    ry += 22;
    if (ui.button(.{ .x = right, .y = ry, .w = 170, .h = row_h }, "Delete project...", .{})) ui.openPopup(&app.modal);
    ry += row_h + 36;

    heading(ui, right, ry, "TOOLTIPS (HOVER AND REST)");
    ry += 22;
    const tips = [_]struct { icon: vass.icons.Icon, text: []const u8 }{
        .{ .icon = .search, .text = "Search everything" },
        .{ .icon = .sliders, .text = "Adjust settings" },
        .{ .icon = .plus, .text = "Create a new item" },
        .{ .icon = .more, .text = "More actions" },
    };
    for (tips, 0..) |tp, i| {
        const r: Rect = .{ .x = right + @as(f32, @floatFromInt(i)) * 44, .y = ry, .w = 36, .h = 36 };
        _ = ui.iconButton(r, tp.icon, .{ .icon_size = 20 });
        if (i == 1) app.tip_center = .{ r.x + r.w / 2, r.y + r.h / 2 };
        ui.tooltip(r, tp.text, .{});
    }
    ry += 36 + 36;

    // ---- status line -------------------------------------------------------------------
    const status = if (app.last_len > 0) app.last[0..app.last_len] else "Nothing chosen yet";
    ui.label(.{ .x = right, .y = win_h - 44, .w = col_w, .h = 18 }, status, .{ .size = 12, .color = t.dim });

    // ---- the modal (declared last; it draws above everything either way) --------------
    if (ui.beginPopup(&app.modal, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .{ 360, 168 }, .{
        .placement = .center,
        .modal = true,
        .dismiss_on_outside = false,
        .padding = 22,
        .radius = 14,
    })) |c| {
        ui.labelAt(c.x, c.y, "Delete this project?", .{ .size = 15, .weight = .semibold });
        _ = ui.labelWrapped(.{ .x = c.x, .y = c.y + 30, .w = c.w, .h = 0 }, "All of its notes and files are removed for good. This cannot be undone.", .{ .size = 12.5, .color = t.dim });
        const by = c.y + c.h - 32;
        if (ui.button(.{ .x = c.x + c.w - 190, .y = by, .w = 88, .h = 32 }, "Cancel", .{})) ui.closePopup(&app.modal);
        if (dangerButton(ui, .{ .x = c.x + c.w - 94, .y = by, .w = 94, .h = 32 }, "Delete")) {
            ui.closePopup(&app.modal);
            app.say("Project deleted", .{});
        }
        ui.endPopup();
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var snapshot_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--snapshot") and i + 1 < args.len) {
            i += 1;
            snapshot_dir = args[i];
        } else {
            std.debug.print("usage: popups [--snapshot DIR]\n", .{});
            return;
        }
    }

    var app: App = .{};
    var win = try vass.platform.Window.init(gpa, .{ .title = "Popups", .width = win_w, .height = win_h });
    defer win.deinit();
    var list = vass.DisplayList.init(gpa);
    defer list.deinit();

    const theme: vass.ui.Theme = .{ .card_radius = 12 };
    var input: ui_mod.Input = .{};
    var live: Live = .{ .app = &app, .win = &win, .list = &list, .input = &input, .theme = theme };
    win.setFrameCallback(&live, Live.onResize);

    // Snapshot script: scene 0..3, each drawn for a few frames on a fake clock so the tooltip
    // timer runs, then saved. The scenes put the state of the popups by hand.
    const scene_names = [_][]const u8{ "1-tooltip", "2-menus", "3-popover", "4-modal" };
    const frames_per_scene = 5;

    var n: u32 = 0;
    var running = true;
    while (running) : (n += 1) {
        while (vass.platform.pollEvent()) |ev| switch (ev) {
            .quit, .close_requested => running = false,
            else => if (snapshot_dir == null) input.feed(ev, win.id()),
        };
        var scene: usize = 0;
        var scene_frame: u32 = 0;
        if (snapshot_dir != null) {
            scene = n / frames_per_scene;
            scene_frame = n % frames_per_scene;
            if (scene >= scene_names.len) break;
            if (scene_frame == 0) {
                app.actions_menu = .{};
                app.context = .{};
                app.popover = .{};
                app.modal = .{};
                app.size_dd.popup = .{};
                app.open_dd.popup = .{};
                app.sort_dd.popup = .{};
                app.state = .{};
                input = .{};
                switch (scene) {
                    0 => {},
                    1 => {
                        app.open_dd.popup = .{ .open = true, .fresh = true };
                        app.actions_menu = .{ .open = true, .highlight = 1 };
                        app.context = .{ .open = true, .point = .{ margin + 250, 432 }, .highlight = 0 };
                    },
                    2 => {
                        app.popover = .{ .open = true };
                        app.sort_dd.popup = .{ .open = true };
                    },
                    else => app.modal = .{ .open = true },
                }
            }
        }
        // Scene 0 rests the pointer on the second icon button once its position is known.
        if (snapshot_dir != null and scene == 0 and scene_frame == 1) {
            input.mouse_x = app.tip_center[0];
            input.mouse_y = app.tip_center[1];
        }
        input.time = if (snapshot_dir != null) @as(f64, @floatFromInt(n)) * 0.3 else @as(f64, @floatFromInt(vass.platform.ticks())) / 1000.0;

        const snap = snapshot_dir != null and scene_frame == frames_per_scene - 1;
        if (snap) win.snapshot_path = try std.fmt.allocPrintSentinel(arena, "{s}/popups-{s}.bmp", .{ snapshot_dir.?, scene_names[scene] }, 0);
        live.draw(input);
        input.endFrame();
        vass.platform.sleepMs(16);
    }
}

/// Draws one frame. The main loop and the window's resize callback both call it, so the
/// window keeps reflowing while the OS is dragging an edge (the loop is blocked then).
const Live = struct {
    app: *App,
    win: *vass.platform.Window,
    list: *vass.DisplayList,
    input: *ui_mod.Input,
    theme: vass.ui.Theme,

    fn draw(l: *Live, in: ui_mod.Input) void {
        l.list.reset();
        var ui = Ui.init(l.list, l.win, in, l.theme);
        ui.state = &l.app.state;
        frame(l.app, &ui);
        ui.finish();
        l.win.render(l.list, l.theme.bg);
    }

    /// Resize callback: an idle frame (no click or key replayed, clock untouched).
    fn onResize(ctx: ?*anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx.?));
        l.draw(l.input.idle());
    }
};
