//! Declarative bar configuration - the native replacement for `sketchybarrc`,
//! `colors.sh`, `icons.sh` and the `items/*.sh` files.
//!
//! Every property list is declared as a nested struct and compiled to the flat
//! `key=value` arguments SketchyBar consumes by `config.node`, entirely at
//! compile time (see `config.zig`). Nothing is formatted or concatenated at
//! runtime: the string the compiler baked is the one that goes out.
//!
//! Everything is emitted into one command batch, so SketchyBar applies the whole
//! configuration and redraws exactly once. Every item whose data this daemon
//! computes declares `mach_helper=`; the space, front-app and separator
//! items are driven from the helper's own batches instead, and nothing here
//! forks a process or keeps a shell `script=` or `click_script`.
//!
//! Items outlive a configuration reload, so three properties have to be restated
//! every time or an earlier configuration leaks through: `script` and
//! `click_script`, otherwise a plugin or click handler the daemon replaced keeps
//! running, and `drawing` on visible items, otherwise a `zen` from a previous
//! session survives the reload.

const std = @import("std");

const sb = @import("sb.zig");
const config = @import("config.zig");
const items_system = @import("items_system.zig");
const items_usage = @import("items_usage.zig");
const pomodoro = @import("pomodoro.zig");
const theme = @import("theme.zig");

/// Items an earlier configuration declared and this one does not. SketchyBar
/// keeps items across reloads, so retiring one means removing it here: nothing
/// else will, and a leftover item would keep running the plugin it was given.
const retired_items = [_][]const u8{
    // The Spotify popup left the configuration; its plugin is gone.
    "/spotify\\..*/",
    "/^spotify$/",
    // Flow's clock item and the alias to Flow's own status item: the pomodoro
    // replaced both, and every alias is gone from this configuration now.
    "/^flow$/",
    "/^fan_alias$/",
    // OpenRouter's popup, which an earlier version built and which had nothing to
    // put in it.
    "/^openrouter\\.day$/",
    "/^openrouter\\.week$/",
    // The battery item, whose glyph and percentage the ring replaced. Items
    // outlive a reload, so an earlier configuration's percentage would stay on the
    // bar beside the ring otherwise. The pattern is anchored, so `battery.ring` -
    // the item that took its place - is not matched.
    "/^battery$/",
    // Aliases to other applications' status items drew nothing on the two macOS
    // versions before this one either, so the mechanism is out of the
    // configuration rather than merely disabled in it.
    "/^network_alias$/",
};

/// The air around every item, in points, so that every gap on the bar is the
/// same 2 x this.
///
/// An item's padding is inside its own frame and the gap to its neighbour is the
/// sum of their two paddings, so one value applied to every item is what makes
/// the spacing uniform.
const item_padding = 4;

/// How wide each of the two graphs is, in points. Both are this wide, so their
/// windows hold the same number of samples and the same stretch of time.
const graph_width = 60;

/// The battery ring's diameter, in points. A ring takes exactly this much of the
/// bar, and the bar is 24 points tall.
const battery_ring_diameter = 20;

/// Spaces 1..16 exist as items; yabai decides which ones are real.
pub const max_spaces = 16;
/// Displays 1..4 get a `front_app` / `yabai_status` pair.
pub const max_displays = 4;

pub const Config = struct {
    /// Bootstrap name this daemon is registered under - the value SketchyBar
    /// needs in an item's `mach_helper` property to route events here.
    helper: []const u8,
};

/// Apply a compile-time item config, then the one property whose value is only
/// known at runtime: the bootstrap name the daemon registered under, which is
/// what routes the item's events back to it. It lands in the same `--set`, since
/// nothing else queues a command word between the two.
fn applyHelper(c: *sb.Client, item: []const u8, script: config.Script, helper: []const u8) !void {
    try script.apply(c, item);
    try c.prop("mach_helper", helper);
}

/// Emit the complete configuration.
pub fn apply(c: *sb.Client, config_input: Config) !void {
    for (retired_items) |pattern| {
        try c.arg("--remove");
        try c.arg(pattern);
    }

    try bar(c);
    try spaces(c);
    try frontAppItems(c, config_input);
    try rightItems(c, config_input);
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

    // Defaults are copied into items when they are created, so they must precede
    // every `--add`.
    try c.arg("--default");
    const defaults = config.node(.{
        .updates = "when_shown",
        .icon = .{
            .font = theme.font ++ ":Bold:14.0",
            .color = config.color(theme.icon_color),
            .padding_left = theme.padding,
            .padding_right = theme.padding,
        },
        .label = .{
            .font = theme.font ++ ":SemiBold:13.0",
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
        var name: [16]u8 = undefined;
        const item = try std.fmt.bufPrint(&name, "space.{d}", .{index});

        try c.arg("--add");
        try c.arg("space");
        try c.arg(item);
        try c.arg("left");

        // `icon.value` is the space number: `value` collapses to its parent's
        // key, so `icon` is set to the number *and* carries font and colours.
        const script = config.node(.{
            // Older configurations attached a highlight script to space items;
            // the helper owns `icon.highlight` now.
            .script = null,
            .click_script = null,
            .associated_space = index,
            .padding_left = item_padding,
            .padding_right = item_padding,
            .icon = .{
                .value = index,
                .padding_left = 10,
                .padding_right = 10,
                .color = config.color(theme.white),
                .highlight_color = config.color(theme.green),
                .font = theme.font ++ ":ExtraBold:13.0",
            },
            .label = .{
                .font = theme.app_font ++ ":Regular:14",
                .y_offset = -1,
                .color = config.color(theme.white),
                .highlight_color = config.color(theme.background_1),
                .width = "dynamic",
                .padding_right = 6,
                .padding_left = 6,
                .background = .{
                    .height = 28,
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
        });
        try script.apply(c, item);

        try c.arg("--subscribe");
        try c.arg(item);
        try c.arg("mouse.clicked");
    }

    try c.arg("--add");
    try c.arg("item");
    try c.arg("separator");
    try c.arg("left");
    const separator = config.node(.{
        .drawing = true,
        .padding_left = item_padding,
        .padding_right = item_padding,
        .icon = .{
            .value = theme.glyph.separator,
            .font = theme.font ++ ":Regular:11.0",
            .color = config.color(theme.separator_icon),
        },
        .label = .{ .drawing = false },
    });
    try separator.apply(c, "separator");
}

fn frontAppItems(c: *sb.Client, config_input: Config) !void {
    @setEvalBranchQuota(1_000_000);
    // A single hidden driver item receives `yabai_update` and lets the helper
    // refresh every space and per-display item from one batch.
    try c.arg("--add");
    try c.arg("event");
    try c.arg("yabai_update");

    try c.arg("--add");
    try c.arg("item");
    try c.arg("system.yabai");
    try c.arg("left");
    const driver = config.node(.{
        .script = null,
        .drawing = false,
        .updates = true,
        .associated_display = 1,
    });
    try applyHelper(c, "system.yabai", driver, config_input.helper);

    try c.arg("--subscribe");
    try c.arg("system.yabai");
    try c.arg("yabai_update");
    try c.arg("display_change");

    inline for (1..max_displays + 1) |display| {
        var name: [24]u8 = undefined;

        const status = try std.fmt.bufPrint(&name, "yabai_status.{d}", .{display});
        try c.arg("--add");
        try c.arg("item");
        try c.arg(status);
        try c.arg("left");

        const status_cfg = config.node(.{
            .script = null,
            .drawing = true,
            .padding_left = item_padding,
            .padding_right = item_padding,
            .icon = .{
                .value = theme.glyph.yabai_grid,
                .width = 24,
                .font = theme.font ++ ":Bold:14.0",
                .color = config.color(theme.orange),
            },
            .label = .{
                .drawing = false,
                .font = theme.font ++ ":Regular:12.0",
            },
            .updates = false,
            .associated_display = display,
        });
        try status_cfg.apply(c, status);

        const front = try std.fmt.bufPrint(&name, "front_app.{d}", .{display});
        try c.arg("--add");
        try c.arg("item");
        try c.arg(front);
        try c.arg("left");

        const front_cfg = config.node(.{
            .drawing = true,
            .padding_left = item_padding,
            .padding_right = item_padding,
            .icon = .{
                .color = config.color(theme.white),
                .font = theme.font ++ ":ExtraBold:12.0",
            },
            .label = .{
                .color = config.color(theme.grey),
                .font = theme.font ++ ":Italic:12.0",
            },
            .associated_display = display,
        });
        try front_cfg.apply(c, front);
    }
}

fn rightItems(c: *sb.Client, config_input: Config) !void {
    @setEvalBranchQuota(1_000_000);
    // The battery: read from IOKit in-process instead of spawning `pmset`, and
    // shown as one ring rather than as an item and a ring. Its value is the charge
    // and the battery's own level glyph sits inside it as the marker, so it reads
    // as the battery filling - and the marker's glyph is what says whether the
    // machine is on AC. The item carries the battery's events itself, since the
    // item that used to carry them is gone.
    try c.arg("--add");
    try c.arg("ring");
    try c.arg(items_system.ring_item);
    try c.arg("right");
    try c.arg(std.fmt.comptimePrint("{d}", .{battery_ring_diameter}));
    const ring = config.node(.{
        // Drawn from the start: the charge is this item's to show, and on a bar
        // that is already up the drawing a previous configuration left behind is
        // the only other thing that could say. This is also what
        // `items_system.battery` sets with every reading.
        .drawing = true,
        // The air between the ring and the clock, which is the item to its left,
        // is the ring's left padding and the clock's right padding - and a ring
        // is round, so the same number of points reads wider there than between
        // two glyphs. The ring's own side of that gap is dropped, since the
        // clock's is enough, and the ring keeps the bar's standard padding on its
        // other side.
        .padding_left = 0,
        .padding_right = item_padding,
        .ring = .{
            .color = config.color(theme.green),
            .track_color = config.color(theme.dark_grey),
            // The diameter is given to `--add` and also set here: that argument
            // only lands when the item is created, and an item that outlives the
            // configuration keeps whatever a later `--set` gave it - which is the
            // same trap `script` and `click_script` fall into.
            .width = battery_ring_diameter,
            .line_width = 2,
            .marker = .{
                .position = "center",
                .font = theme.font ++ ":Bold:12.0",
            },
        },
        .script = null,
        .click_script = null,
        // The battery's own readings, and how often they are asked for again: a
        // battery that is not changing sends nothing, so the level is re-read on
        // the item's own clock.
        .update_freq = 120,
    });
    try applyHelper(c, items_system.ring_item, ring, config_input.helper);
    try c.arg("--subscribe");
    try c.arg(items_system.ring_item);
    try c.arg("battery");
    try c.arg("system_woke");
    try c.arg("power_source_change");

    // Calendar: formatted in-process from the system clock.
    try c.arg("--add");
    try c.arg("item");
    try c.arg("calendar");
    try c.arg("right");
    const calendar = config.node(.{
        .padding_left = item_padding,
        .padding_right = item_padding,
        .icon = .{
            .value = "cal",
            .font = theme.font ++ ":ExtraBold:11.0",
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
        .script = null,
        .click_script = null,
    });
    try applyHelper(c, "calendar", calendar, config_input.helper);
    try c.arg("--subscribe");
    try c.arg("calendar");
    try c.arg("mouse.clicked");

    // The ring is moved against the calendar - before it in the item list, which
    // is to the right of it on the bar - rather than left to the place it was
    // given when it was created. An item keeps that place, and one that has to be
    // created again lands at the end of the list, which is the far left of the
    // right side; this is the same move the graphs below make, for the same
    // reason. It runs after the calendar is declared so that a fresh bar has the
    // item to move against.
    try c.arg("--move");
    try c.arg(items_system.ring_item);
    try c.arg("before");
    try c.arg("calendar");

    // CPU and GPU: two graphs over one window, sitting between the date and the
    // Homebrew status. A graph's ring is exactly as wide as the graph is, and each
    // tick appends one point to each, so equal widths are what hold the two
    // windows together - a wider graph would hold a longer stretch of time and the
    // two would drift apart in what they were showing.
    //
    // They are drawn over one another rather than side by side, and neither
    // carries text: the graph is the whole item and its colour is its only label.
    inline for ([_]struct { name: []const u8, color: theme.Color }{
        .{ .name = items_system.cpu_item, .color = theme.graph_cpu },
        .{ .name = items_system.gpu_item, .color = theme.graph_gpu },
    }, 0..) |series, index| {
        try c.arg("--add");
        try c.arg("graph");
        try c.arg(series.name);
        try c.arg("right");
        try c.arg(std.fmt.comptimePrint("{d}", .{graph_width}));

        const graph = config.node(.{
            .padding_left = item_padding,
            .padding_right = item_padding,
            .drawing = true,
            .associated_display = 1,
            // The transparent background is not for looks: giving a graph a
            // background is what makes it draw inside that background's height
            // instead of across the whole 24-point bar, which is the frame the
            // original helper's graphs used. Both text slots are off, so neither
            // reserves room.
            .label = .{ .drawing = false },
            .icon = .{ .drawing = false },
            .background = .{
                .drawing = true,
                .color = config.color(theme.graph_no_fill),
                .height = 20,
            },
            .graph = .{
                .color = config.color(series.color),
                .fill_color = config.color(theme.graph_no_fill),
                .line_width = 1,
            },
            .script = null,
            .click_script = null,
        });
        try graph.apply(c, series.name);
        // The first of the two takes no room of its own, so the second begins at
        // the same x and the two graphs are drawn over one another. The width is
        // not lost from the bar: the second graph still occupies its own, and that
        // is what the item after the pair is placed against.
        if (index == 0) try c.prop("width", "0");
    }

    // The pair is placed between the date and the Homebrew status by moving it
    // there, rather than by the order it was added in: an item keeps the place it
    // was given when it was created, so on a bar that is already running an
    // `--add` of an existing item changes nothing and a re-added one lands at the
    // end. Moving them is what makes this hold on any bar, fresh or not.
    try c.arg("--move");
    try c.arg(items_system.gpu_item);
    try c.arg("before");
    try c.arg("brew");
    try c.arg("--move");
    try c.arg(items_system.cpu_item);
    try c.arg("before");
    try c.arg(items_system.gpu_item);

    // Homebrew: `brew outdated` is genuinely slow, so the item asks for it
    // coarsely, and the daemon runs it off the event path.
    try c.arg("--add");
    try c.arg("event");
    try c.arg("brew_update");
    try c.arg("--add");
    try c.arg("item");
    try c.arg("brew");
    try c.arg("right");
    const brew = config.node(.{
        .padding_left = item_padding,
        .padding_right = item_padding,
        .script = null,
        .icon = .{
            .value = theme.glyph.brew,
            .badge = .{
                // A count with two digits must not widen the item and shift what
                // is beside it - the numeral is a badge on the icon, like the
                // bell's, for the same reason.
                .value = "?",
                .font = theme.font ++ ":Bold:9.0",
                .anchor = config.Anchors.bottom_right,
                .x_offset = 2,
                .y_offset = -1,
                .background = .{
                    .drawing = true,
                    .color = config.color(theme.badge_background),
                    // Dynamic box with 1px air on every side, so the chip hugs
                    // the count - a circle for a single digit - instead of a
                    // fixed-height pill.
                    .width = "dynamic",
                    .height = 0,
                    .corner_radius = 6,
                    .padding_left = 1,
                    .padding_right = 1,
                },
            },
        },
        .label = .{ .value = null, .drawing = false },
        .update_freq = 3600,
        .associated_display = 1,
        .drawing = true,
    });
    try applyHelper(c, "brew", brew, config_input.helper);
    try c.arg("--subscribe");
    try c.arg("brew");
    try c.arg("brew_update");

    // GitHub notifications: `gh api` every three minutes, event driven.
    try c.arg("--add");
    try c.arg("item");
    try c.arg("github.bell");
    try c.arg("right");
    const bell = config.node(.{
        .drawing = true,
        .update_freq = 180,
        // The count is a badge on the icon rather than the item's label. A badge
        // is drawn over its parent and takes no room in the bar, so the item is
        // the width of the bell however long the number gets and nothing beside
        // it shifts. The label still has to be emptied and switched off, because
        // an item outlives the configuration that set it.
        //
        // `badge.*` comes from the local SketchyBar fork, not from a release: an
        // upstream bar rejects the unknown properties and draws no badge, which
        // costs the count and nothing else.
        .padding_left = item_padding,
        .padding_right = item_padding,
        .icon = .{
            .value = theme.glyph.github,
            .font = theme.font ++ ":Bold:15.0",
            .color = config.color(theme.blue),
            .badge = .{
                .value = theme.glyph.loading,
                .font = theme.font ++ ":Bold:9.0",
                .anchor = config.Anchors.bottom_right,
                .x_offset = 2,
                .y_offset = -1,
                // Compact chip hugging the count; see the brew item.
                .background = .{
                    .drawing = true,
                    .color = config.color(theme.badge_background),
                    .width = "dynamic",
                    .height = 0,
                    .corner_radius = 6,
                    .padding_left = 1,
                    .padding_right = 1,
                },
            },
        },
        .label = .{ .value = null, .drawing = false },
        .popup = .{ .@"align" = "right" },
        // Dynamic rather than the fixed width an earlier configuration gave it: a
        // fixed width swallows the padding, which is what made this item overlap
        // the balance beside it.
        .width = "dynamic",
        .associated_display = 1,
        .script = null,
        .click_script = null,
    });
    try applyHelper(c, "github.bell", bell, config_input.helper);
    try c.arg("--subscribe");
    try c.arg("github.bell");
    try c.arg("mouse.entered");
    try c.arg("mouse.exited");
    try c.arg("mouse.exited.global");
    try c.arg("mouse.clicked");

    try c.arg("--add");
    try c.arg("item");
    try c.arg("github.template");
    try c.arg("popup.github.bell");
    const template = config.node(.{
        .drawing = false,
        .background = .{
            .corner_radius = 12,
            .padding_left = 7,
            .padding_right = 7,
            .color = config.color(theme.black),
            .drawing = false,
        },
        .icon = .{
            .background = .{
                .height = 2,
                .y_offset = -12,
            },
        },
        .updates = true,
        .click_script = null,
    });
    // A popup row is built by `--clone`, and a row is clicked long after the
    // refresh that built it, so the routing is stated here *and* per row: the
    // row is what SketchyBar resolves, and the template is only its ancestor.
    try applyHelper(c, "github.template", template, config_input.helper);
    try c.arg("--subscribe");
    try c.arg("github.template");
    try c.arg("mouse.clicked");

    // Provider balances: what is left on NeuralWatt and on OpenRouter. One
    // background task fetches both, on the daemon's own clock rather than on an
    // item's `update_freq` - a refresh that pushed to an item which was
    // subscribed to updates came straight back as another event. Hovering either
    // shows the last day and the last week; clicking opens its usage page.
    try c.arg("--add");
    try c.arg("item");
    try c.arg(items_usage.neuralwatt_item);
    try c.arg("right");
    const neuralwatt = config.node(.{
        .drawing = true,
        .associated_display = 1,
        .padding_left = item_padding,
        .padding_right = item_padding,
        // `dynamic` is SketchyBar's automatic width, and the default - but a
        // property an earlier configuration set stays set otherwise, which is the
        // same trap the empty `script=` and `click_script=` below exist for.
        .width = "dynamic",
        // Smaller than its neighbour on purpose: the app font's icons are not the
        // same shape at the same size. Measured at 16 points, `:neuralwatt:`
        // inks a full 16x16 square where `:openrouter:` is 16x13.7 and `:clock:`
        // is 15.5x15.6, so at the same size it reads much heavier than the rest.
        .icon = .{
            .value = ":neuralwatt:",
            .font = theme.app_font ++ ":Regular:14.0",
            .padding_right = 2,
            // Dim until the first answer arrives: the colour is the daemon's to
            // set, and a reading that stopped refreshing is dimmed rather than
            // left bright.
            .color = config.color(theme.dark_grey),
        },
        .label = .{ .value = "?" },
        .script = null,
        .click_script = null,
    });
    try applyHelper(c, items_usage.neuralwatt_item, neuralwatt, config_input.helper);
    try c.arg("--subscribe");
    try c.arg(items_usage.neuralwatt_item);
    try c.arg("mouse.entered");
    try c.arg("mouse.exited");
    try c.arg("mouse.exited.global");
    try c.arg("mouse.clicked");

    try c.arg("--add");
    try c.arg("item");
    try c.arg(items_usage.openrouter_item);
    try c.arg("right");
    const openrouter = config.node(.{
        .drawing = true,
        .associated_display = 1,
        .padding_left = item_padding,
        .padding_right = item_padding,
        .width = "dynamic",
        .icon = .{
            .value = ":openrouter:",
            .font = theme.app_font ++ ":Regular:16.0",
            .padding_right = 2,
            .color = config.color(theme.dark_grey),
        },
        .label = .{ .value = "?" },
        .script = null,
        .click_script = null,
    });
    try applyHelper(c, items_usage.openrouter_item, openrouter, config_input.helper);
    // A click opens its usage page. There is no popup: this provider has no
    // daily or weekly figure to put in one.
    try c.arg("--subscribe");
    try c.arg(items_usage.openrouter_item);
    try c.arg("mouse.clicked");

    // One popup row per window, per provider. They are declared rather than
    // cloned, because the number of rows does not vary.
    inline for ([_]struct { parent: []const u8, color: theme.Color }{
        .{ .parent = items_usage.neuralwatt_item, .color = theme.green },
    }) |provider| {
        inline for ([_]struct { suffix: []const u8, nominal: []const u8 }{
            .{ .suffix = "day", .nominal = "24h" },
            .{ .suffix = "week", .nominal = "7d" },
        }) |row| {
            var name_buffer: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "{s}.{s}", .{ provider.parent, row.suffix });

            var position_buffer: [48]u8 = undefined;
            const position = try std.fmt.bufPrint(&position_buffer, "popup.{s}", .{provider.parent});

            try c.arg("--add");
            try c.arg("item");
            try c.arg(name);
            try c.arg(position);

            const detail = config.node(.{
                .drawing = true,
                .background = .{
                    .corner_radius = 12,
                    .padding_left = 7,
                    .padding_right = 7,
                    .color = config.color(theme.black),
                    .drawing = false,
                },
                .label = .{
                    .value = row.nominal ++ " -",
                    .padding_left = 7,
                    .padding_right = 7,
                    .color = config.color(provider.color),
                },
                .script = null,
                .click_script = null,
            });
            try detail.apply(c, name);
        }
    }

    // The pomodoro timer. Its countdown is the daemon's own: the daemon pushes
    // it to the label when the second changes, so the item carries no
    // `update_freq`, forks nothing, and asks no other application for the time.
    // A left click starts or stops the timer, a right click resets it.
    try c.arg("--add");
    try c.arg("item");
    try c.arg(pomodoro.item);
    try c.arg("e");
    const timer = config.node(.{
        .padding_left = item_padding,
        .padding_right = item_padding,
        .associated_display = 1,
        .icon = .{
            .value = ":clock:",
            .font = theme.app_font ++ ":Regular:16.0",
            .padding_right = 2,
            .color = config.color(theme.dark_grey),
            .drawing = true,
        },
        .label = .{
            .value = null,
            .width = 52,
            .@"align" = "left",
            .color = config.color(theme.dark_grey),
        },
        .script = null,
        .click_script = null,
    });
    try applyHelper(c, pomodoro.item, timer, config_input.helper);
    try c.arg("--subscribe");
    try c.arg(pomodoro.item);
    try c.arg("mouse.clicked");
}
