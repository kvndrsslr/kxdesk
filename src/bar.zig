//! The bar's configuration: what every item is, how it looks and which events
//! reach the daemon, declared through `config` and compiled to one `--set` each.
//!
//! Everything lands in one batch; items the daemon feeds declare `mach_helper`,
//! and the space, front-app and separator items are driven from the helper's own
//! batches. `config.declare` clears `script` and `click_script` on every item.

const std = @import("std");

const sb = @import("sb.zig");
const config = @import("config.zig");
const style = @import("style.zig");
const items_system = @import("items_system.zig");
const items_usage = @import("items_usage.zig");
const pomodoro = @import("pomodoro.zig");
const server_mode = @import("server_mode.zig");
const theme = @import("theme.zig");

/// Items an earlier configuration declared and this one does not; SketchyBar
/// keeps items across reloads, so retiring one means removing it here.
const retired_items = [_][]const u8{
    "/spotify\\..*/",
    "/^spotify$/",
    "/^flow$/",
    "/^fan_alias$/",
    // OpenRouter's popup, which an earlier version built and had nothing to put in it.
    "/^openrouter\\.day$/",
    "/^openrouter\\.week$/",
    // Anchored, so `battery.ring` - the item that took its place - is not matched.
    "/^battery$/",
    // An item's type is fixed at creation and `--add` refuses a name it knows, so a
    // ring means removing the plain item and creating it again, in the same batch.
    "/^opencode-go$/",
    // Aliases to other applications' status items drew nothing on the two macOS versions before this one either.
    "/^network_alias$/",
};

/// Spaces 1..16 exist as items; yabai decides which ones are real.
pub const max_spaces = 16;
/// Displays 1..4 get a `front_app` / `yabai_status` pair.
pub const max_displays = 4;

pub const Config = struct {
    /// Bootstrap name this daemon is registered under - the value SketchyBar
    /// needs in an item's `mach_helper` property to route events here.
    helper: []const u8,
};

/// Emit the complete configuration.
pub fn apply(c: *sb.Client, io: std.Io, config_input: Config) !void {
    for (retired_items) |pattern| try config.remove(c, pattern);

    try bar(c);
    try spaces(c);
    try frontAppItems(c, config_input);
    try rightItems(c, io, config_input);
    try c.arg("--update");
    try c.commit();
}

fn bar(c: *sb.Client) !void {
    @setEvalBranchQuota(1_000_000);
    try c.arg("--bar");
    const bar_cfg = config.node(.{
        .height = theme.bar_height,
        .color = config.color(theme.bar_color),
        .shadow = false,
        .position = "top",
        .sticky = true,
        .topmost = false,
        .padding_right = 8,
        .padding_left = 2,
        .corner_radius = 0,
        .y_offset = 0,
        .margin = 0,
        .blur_radius = 20,
        .notch_width = 225,
    });
    try bar_cfg.queue(c);

    // Defaults are copied into items when they are created, so they must precede every `--add`.
    try c.arg("--default");
    const defaults = config.node(.{
        .updates = "when_shown",
        .icon = .{
            .font = style.mono(.Bold, 14),
            .color = config.color(theme.icon_color),
            .padding_left = theme.padding,
            .padding_right = theme.padding,
        },
        .label = .{
            .font = style.mono(.SemiBold, 13),
            .color = config.color(theme.label_color),
            .padding_left = theme.padding,
            .padding_right = theme.padding,
        },
        .background = .{
            .padding_right = theme.padding,
            .padding_left = theme.padding,
            .height = theme.bar_height,
            .corner_radius = 9,
        },
        .popup = .{ .background = .{
            .border_width = 0,
            .corner_radius = 0,
            .border_color = config.color(theme.black),
            .color = config.color(theme.black),
            .shadow = .{ .drawing = false },
        } },
    });
    try defaults.queue(c);
}

fn spaces(c: *sb.Client) !void {
    @setEvalBranchQuota(1_000_000);
    inline for (1..max_spaces + 1) |index| {
        try config.declare(c, .{
            .kind = .space,
            .name = std.fmt.comptimePrint("space.{d}", .{index}),
            .position = "left",
            // `icon.value` is the space number: `value` collapses to its parent's
            // key, so `icon` is set to the number *and* carries font and colours.
            .props = config.node(.{
                .associated_space = index,
                .padding_left = style.item_padding,
                .padding_right = style.item_padding,
                .icon = .{
                    .value = index,
                    .padding_left = 10,
                    .padding_right = 10,
                    .color = config.color(theme.white),
                    .highlight_color = config.color(theme.green),
                    .font = style.mono(.ExtraBold, 13),
                },
                .label = .{
                    .font = style.app(14),
                    .y_offset = -1,
                    .color = config.color(theme.white),
                    .highlight_color = config.color(theme.background_1),
                    .width = "dynamic",
                    .padding_right = 6,
                    .padding_left = 6,
                    .background = .{
                        .height = style.space_chip_height,
                        .drawing = true,
                        .color = config.color(theme.background_2),
                        .corner_radius = 0,
                    },
                    .drawing = false,
                },
                .background = .{
                    .color = config.color(theme.black),
                    .drawing = false,
                    .corner_radius = 0,
                },
            }),
            .events = &.{.@"mouse.clicked"},
        }, "");
    }

    try config.declare(c, .{
        .name = "separator",
        .position = "left",
        .props = config.node(.{
            .drawing = true,
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            .icon = .{
                .value = theme.glyph.separator,
                .font = style.mono(.Regular, 11),
                .color = config.color(theme.separator_icon),
            },
            .label = .{ .drawing = false },
        }),
    }, "");
}

fn frontAppItems(c: *sb.Client, config_input: Config) !void {
    @setEvalBranchQuota(1_000_000);
    // One hidden driver item receives `yabai_update` and lets the helper refresh
    // every space and per-display item from one batch.
    try config.declare(c, .{ .kind = .event, .name = "yabai_update" }, config_input.helper);

    try config.declare(c, .{
        .name = "system.yabai",
        .position = "left",
        .props = config.node(.{
            .drawing = false,
            .updates = true,
            .associated_display = 1,
        }),
        .helper = true,
        .events = &.{ .yabai_update, .display_change },
    }, config_input.helper);

    inline for (1..max_displays + 1) |display| {
        try config.declare(c, .{
            .name = std.fmt.comptimePrint("yabai_status.{d}", .{display}),
            .position = "left",
            .props = config.node(.{
                .drawing = true,
                .padding_left = style.item_padding,
                .padding_right = style.item_padding,
                .icon = .{
                    .value = theme.glyph.yabai_grid,
                    .width = 24,
                    .font = style.mono(.Bold, 14),
                    .color = config.color(theme.orange),
                },
                .label = .{
                    .drawing = false,
                    .font = style.mono(.Regular, 12),
                },
                .updates = false,
                .associated_display = display,
            }),
        }, config_input.helper);

        try config.declare(c, .{
            .name = std.fmt.comptimePrint("front_app.{d}", .{display}),
            .position = "left",
            .props = config.node(.{
                .drawing = true,
                .padding_left = style.item_padding,
                .padding_right = style.item_padding,
                .icon = .{
                    .color = config.color(theme.white),
                    .font = style.mono(.ExtraBold, 12),
                },
                .label = .{
                    .color = config.color(theme.grey),
                    .font = style.mono(.Italic, 12),
                },
                .associated_display = display,
            }),
        }, config_input.helper);
    }
}

/// Declare one pair of the graph items `style.Graph` describes.
fn graphPair(c: *sb.Client, comptime pair: [2]style.Graph) !void {
    @setEvalBranchQuota(1_000_000);
    inline for (pair, 0..) |series, index| {
        const icon_slot = comptime style.graphSlot(series, true, series.top);
        const label_slot = comptime style.graphSlot(series, false, series.top);
        try config.declare(c, .{
            .kind = .graph,
            .name = series.name,
            .width = style.graph_width,
            .props = config.node(.{
                .padding_left = style.item_padding,
                .padding_right = style.item_padding,
                .drawing = true,
                .associated_display = 1,
                .icon = icon_slot,
                .label = label_slot,
                .background = .{
                    .drawing = true,
                    .color = style.graph_fill,
                    .height = style.graph_height,
                },
                .graph = .{
                    .color = config.color(series.color),
                    .fill_color = style.graph_fill,
                    .line_width = style.graph_line_width,
                },
            }),
        }, "");
        // The first of a pair takes no room of its own, so the second begins at
        // the same x.
        if (index == 0) try c.prop("width", "0");
    }
}

fn rightItems(c: *sb.Client, io: std.Io, config_input: Config) !void {
    try batteryRing(c, config_input);
    try calendarItem(c, config_input);
    try serverItem(c, io, config_input);

    // The ring belongs against the calendar: an item created again lands at the end of the list.
    try config.move(c, items_system.ring_item, "calendar");

    // The two graph pairs, the load pair first, since it is the nearer the clock.
    try graphPair(c, .{
        .{ .name = items_system.cpu_item, .color = theme.graph_cpu, .readout = true, .top = true, .air = false },
        .{ .name = items_system.gpu_item, .color = theme.graph_gpu, .readout = true, .air = false },
    });
    try graphPair(c, .{
        .{ .name = items_system.net_down_item, .color = theme.graph_net_down, .readout = true },
        .{ .name = items_system.net_up_item, .color = theme.graph_net_up, .readout = true, .top = true },
    });

    try linkItem(c);

    // The link and the four graphs are moved into place between the date and the
    // Homebrew status, each against the item to its right: an item keeps the place
    // it was given when it was created.
    try config.move(c, items_system.link_item, "brew");
    try config.move(c, items_system.net_up_item, items_system.link_item);
    try config.move(c, items_system.net_down_item, items_system.net_up_item);
    try config.move(c, items_system.gpu_item, items_system.net_down_item);
    try config.move(c, items_system.cpu_item, items_system.gpu_item);
    // Server mode sits against the date, on the far side of the graphs; moved after them.
    try config.move(c, server_mode.bar_item, items_system.cpu_item);

    try brewItem(c, config_input);
    try githubBell(c, config_input);
    try githubTemplate(c, config_input);
    try neuralwattItem(c, config_input);
    try openrouterItem(c, config_input);
    try opencodeItem(c, config_input);
    try usageRows(c);
    try pomodoroItem(c, config_input);
}

/// The battery as one ring: the charge is its value, the level glyph its marker.
fn batteryRing(c: *sb.Client, config_input: Config) !void {
    try config.declare(c, .{
        .kind = .ring,
        .name = items_system.ring_item,
        .width = style.ring_diameter,
        .props = config.node(.{
            .drawing = true,
            // A ring is round, so the clock's own padding is gap enough on the ring's left.
            .padding_left = 0,
            .padding_right = style.item_padding,
            .ring = .{
                .color = config.color(theme.green),
                .track_color = style.ring_track,
                // The diameter is given to `--add` and set here as well: that
                // argument only lands when the item is created.
                .width = style.ring_diameter,
                .line_width = style.ring_line_width,
                .marker = .{
                    .position = "center",
                    .font = style.mono(.Bold, 12),
                },
            },
            // A battery that is not changing sends nothing, so the level is re-read on the item's own clock.
            .update_freq = 120,
        }),
        .helper = true,
        .events = &.{ .battery, .system_woke, .power_source_change },
    }, config_input.helper);
}

fn calendarItem(c: *sb.Client, config_input: Config) !void {
    try config.declare(c, .{
        .name = "calendar",
        .props = config.node(.{
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            .icon = .{
                .value = "cal",
                .font = style.mono(.ExtraBold, 11),
                .padding_right = 8,
                .color = config.color(theme.calendar_icon),
                .y_offset = -2,
                .padding_left = 0,
                .drawing = true,
            },
            .label = .{
                .width = 40,
                .@"align" = "right",
            },
            .update_freq = 5,
        }),
        .helper = true,
        .events = &.{.@"mouse.clicked"},
    }, config_input.helper);
}

/// The server-mode indicator, carrying the one `click_script` on the bar: `op` is
/// refused to a child of the bar, so the click hands the work to a launchd job.
fn serverItem(c: *sb.Client, io: std.Io, config_input: Config) !void {
    var click_buffer: [4 * std.fs.max_path_bytes]u8 = undefined;
    try config.declare(c, .{
        .name = server_mode.bar_item,
        .props = config.node(.{
            .drawing = true,
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            .associated_display = 1,
            // The client that changes the mode sets the icon; only a reload has to be told.
            .updates = false,
            .icon = .{
                .value = theme.glyph.server,
                .drawing = true,
                .color = config.color(style.dim),
            },
            .label = .{ .value = null, .drawing = false },
            // Cleared by name, not a script clear: an item carrying a helper would
            // have its clicks sent to the daemon, which cannot run the mode.
            .mach_helper = null,
        }),
        .click_script = try server_mode.clickScript(io, &click_buffer),
    }, config_input.helper);
}

/// The link icon: the one thing about the network a flat graph line cannot say.
fn linkItem(c: *sb.Client) !void {
    try config.declare(c, .{
        .name = items_system.link_item,
        .props = config.node(.{
            .drawing = true,
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            .associated_display = 1,
            .icon = .{
                .value = null,
                .font = style.mono(.Bold, 14),
                .drawing = true,
            },
            .label = .{ .value = null, .drawing = false },
        }),
    }, "");
}

/// Homebrew's outdated count; `brew outdated` is slow, so the daemon runs it off the event path.
fn brewItem(c: *sb.Client, config_input: Config) !void {
    try config.declare(c, .{ .kind = .event, .name = "brew_update" }, config_input.helper);
    try config.declare(c, .{
        .name = "brew",
        .props = config.node(.{
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            .icon = .{
                .value = theme.glyph.brew,
                // The count is a badge so that two digits cannot widen the item;
                // `badge.*` is a property of the local SketchyBar fork - an
                // upstream bar draws no badge.
                .badge = style.BadgeChip{ .value = "?" },
            },
            .label = .{ .value = null, .drawing = false },
            .update_freq = 3600,
            .associated_display = 1,
            .drawing = true,
        }),
        .helper = true,
        .events = &.{.brew_update},
    }, config_input.helper);
}

/// GitHub's notification count, on the same chip as the brew count.
fn githubBell(c: *sb.Client, config_input: Config) !void {
    try config.declare(c, .{
        .name = "github.bell",
        .props = config.node(.{
            .drawing = true,
            .update_freq = 180,
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            // The label is emptied and switched off because an item outlives the
            // configuration that set it; the count itself is the badge.
            .icon = .{
                .value = theme.glyph.github,
                .font = style.mono(.Bold, 15),
                .color = config.color(theme.blue),
                .badge = style.BadgeChip{ .value = theme.glyph.loading },
            },
            .label = .{ .value = null, .drawing = false },
            .popup = .{ .@"align" = "right" },
            // Dynamic rather than a fixed width, which would swallow the padding and overlap the balance beside it.
            .width = "dynamic",
            .associated_display = 1,
        }),
        .helper = true,
        .events = &.{ .@"mouse.entered", .@"mouse.exited", .@"mouse.exited.global", .@"mouse.clicked" },
    }, config_input.helper);
}

fn githubTemplate(c: *sb.Client, config_input: Config) !void {
    try config.declare(c, .{
        .name = "github.template",
        .position = "popup.github.bell",
        .props = config.node(.{
            .drawing = false,
            .background = style.popup_row,
            .icon = .{
                .background = .{
                    .height = 2,
                    .y_offset = -12,
                },
            },
            .updates = true,
        }),
        // A row is built by `--clone` and clicked long after the refresh that built
        // it, so the routing is stated here *and* per row.
        .helper = true,
        .events = &.{.@"mouse.clicked"},
    }, config_input.helper);
}

fn neuralwattItem(c: *sb.Client, config_input: Config) !void {
    try config.declare(c, .{
        .name = items_usage.neuralwatt_item,
        .props = config.node(.{
            // Drawn by the refresh, and only if a token for it is in the store.
            .drawing = false,
            .associated_display = 1,
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            // `dynamic` is the default, but a property an earlier configuration set stays set.
            .width = "dynamic",
            // Smaller than its neighbour on purpose: at 16 points `:neuralwatt:` inks
            // a 16x16 square where `:openrouter:` inks 16x13.7.
            .icon = .{
                .value = ":neuralwatt:",
                .font = style.app(14),
                .padding_right = 2,
                // Dim until the first answer arrives; a reading that stopped refreshing is dimmed rather than left bright.
                .color = config.color(style.dim),
            },
            .label = .{ .value = "?" },
        }),
        .helper = true,
        .events = &.{ .@"mouse.entered", .@"mouse.exited", .@"mouse.exited.global", .@"mouse.clicked" },
    }, config_input.helper);
}

/// What is left on OpenRouter; a click opens its usage page, and there is no popup to fill.
fn openrouterItem(c: *sb.Client, config_input: Config) !void {
    try config.declare(c, .{
        .name = items_usage.openrouter_item,
        .props = config.node(.{
            .drawing = false,
            .associated_display = 1,
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            .width = "dynamic",
            .icon = .{
                .value = ":openrouter:",
                .font = style.app(16),
                .padding_right = 2,
                .color = config.color(style.dim),
            },
            .label = .{ .value = "?" },
        }),
        .helper = true,
        .events = &.{.@"mouse.clicked"},
    }, config_input.helper);
}

/// How much of the OpenCode Go plan is spent; its number is a share of a limit.
fn opencodeItem(c: *sb.Client, config_input: Config) !void {
    // The daemon colours this item's mark on the ring's marker, not on an icon,
    // which only works while the item is a ring.
    comptime std.debug.assert(items_usage.providerFor(items_usage.opencode_item).?.ringed);

    try config.declare(c, .{
        .kind = .ring,
        .name = items_usage.opencode_item,
        .width = style.ring_diameter,
        .props = config.node(.{
            .drawing = false,
            .associated_display = 1,
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            .width = "dynamic",
            // The mark is the ring's own marker, because an item draws its icon
            // *before* its ring; the empty assignment clears an earlier icon.
            .icon = .{ .value = "", .padding_left = 0, .padding_right = 0 },
            .ring = .{
                // Only the start: the colour and the share are the daemon's, from the month's usage.
                .color = config.color(theme.green),
                .track_color = style.ring_track,
                .width = style.ring_diameter,
                .line_width = style.ring_line_width,
                .marker = .{
                    // The app font spells this one `:opencode_go:` and has no
                    // hyphenated form; the item's own name keeps the hyphen.
                    .value = ":opencode_go:",
                    .position = "center",
                    // Twelve points in a twenty-point ring: the app font's glyphs
                    // ink a full square, and a wider one would run into the stroke.
                    .font = style.app(12),
                    // The ink box and the font's ascent and descent leave the ring's
                    // own centring 3.5 points left of centre and 2 above it, whole
                    // points being what the fork takes; measured against the font.
                    .x_offset = 3,
                    .y_offset = 0,
                },
            },
            .label = .{ .value = "?", .padding_left = 2 },
        }),
        .helper = true,
        .events = &.{ .@"mouse.entered", .@"mouse.exited", .@"mouse.exited.global", .@"mouse.clicked" },
    }, config_input.helper);
}

/// One popup row per window per provider, from the table the refresh fills.
fn usageRows(c: *sb.Client) !void {
    @setEvalBranchQuota(1_000_000);
    inline for (items_usage.providers) |provider| {
        inline for (provider.rows) |row| {
            var name_buffer: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "{s}.{s}", .{ provider.item, row.suffix });

            var position_buffer: [48]u8 = undefined;
            const position = try std.fmt.bufPrint(&position_buffer, "popup.{s}", .{provider.item});

            try config.declare(c, .{
                .name = name,
                .position = position,
                .props = config.node(.{
                    .drawing = true,
                    .background = style.popup_row,
                    .label = .{
                        .value = row.label ++ " -",
                        .padding_left = 7,
                        .padding_right = 7,
                        .color = config.color(provider.color),
                    },
                }),
            }, "");
        }
    }
}

/// The pomodoro timer: the daemon pushes its countdown when the second changes.
fn pomodoroItem(c: *sb.Client, config_input: Config) !void {
    try config.declare(c, .{
        .name = pomodoro.item,
        // The invalid position the previous configuration declared, carried over unchanged.
        .position = "e",
        .props = config.node(.{
            .padding_left = style.item_padding,
            .padding_right = style.item_padding,
            .associated_display = 1,
            .icon = .{
                .value = ":clock:",
                .font = style.app(16),
                .padding_right = 2,
                .color = config.color(style.dim),
                .drawing = true,
            },
            .label = .{
                .value = null,
                .width = 52,
                .@"align" = "left",
                .color = config.color(style.dim),
            },
        }),
        .helper = true,
        .events = &.{.@"mouse.clicked"},
    }, config_input.helper);
}
