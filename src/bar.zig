//! Declarative bar configuration - the native replacement for `sketchybarrc`,
//! `colors.sh`, `icons.sh` and the `items/*.sh` files.
//!
//! Everything is emitted into one command batch, so SketchyBar applies the whole
//! configuration and redraws exactly once. Every item whose data this daemon
//! computes declares `mach_helper=`; the space, front-app, alias and separator
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
const items_usage = @import("items_usage.zig");
const pomodoro = @import("pomodoro.zig");
const Props = @import("props.zig").Props;
const theme = @import("theme.zig");

/// Items live in SketchyBar, not in this file: reloading the configuration
/// re-declares them but never removes properties an earlier configuration set.
/// Every item the helper takes over therefore clears the shell `script` it used
/// to carry - `plugins/yabai.sh` in particular - otherwise SketchyBar would still
/// fork that script on every event, and it would race the helper's own updates.
const clear_script = "script=";

/// The same trap applies to `click_script`: an item that a previous
/// configuration gave a click handler keeps it, so taking one away means saying
/// so. The bell's click is now an event the helper handles.
const clear_click_script = "click_script=";

/// Items an earlier configuration declared and this one does not. SketchyBar
/// keeps items across reloads, so retiring one means removing it here: nothing
/// else will, and a leftover item would keep running the plugin it was given.
const retired_items = [_][]const u8{
    // The Spotify popup left the configuration; its plugin is gone.
    "/spotify\\..*/",
    "/^spotify$/",
    // Flow's clock item and the alias to Flow's own status item: the pomodoro
    // replaced both, and an alias whose application is gone draws nothing.
    "/^flow$/",
    "/^fan_alias$/",
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
pub fn apply(c: *sb.Client, config: Config) !void {
    for (retired_items) |pattern| {
        try c.arg("--remove");
        try c.arg(pattern);
    }

    try bar(c);
    try spaces(c);
    try frontAppItems(c, config);
    try rightItems(c, config);
    try c.arg("--update");
    try c.commit();
}

fn bar(c: *sb.Client) !void {
    try c.arg("--bar");
    try c.propFmt("height", "{d}", .{theme.bar_height});
    try c.propFmt("color", "0x{x:0>8}", .{theme.bar_color});
    try c.prop("shadow", "off");
    try c.prop("position", "top");
    try c.prop("sticky", "on");
    try c.prop("topmost", "off");
    try c.prop("padding_right", "8");
    try c.prop("padding_left", "2");
    try c.prop("corner_radius", "0");
    try c.prop("y_offset", "0");
    try c.prop("margin", "0");
    try c.prop("blur_radius", "20");
    try c.prop("notch_width", "225");

    // Defaults are copied into items when they are created, so they must precede
    // every `--add`.
    try c.arg("--default");
    try c.prop("updates", "when_shown");
    try c.propFmt("icon.font", "{s}:Bold:14.0", .{theme.font});
    try c.propFmt("icon.color", "0x{x:0>8}", .{theme.icon_color});
    try c.propFmt("icon.padding_left", "{d}", .{theme.padding});
    try c.propFmt("icon.padding_right", "{d}", .{theme.padding});
    try c.propFmt("label.font", "{s}:SemiBold:13.0", .{theme.font});
    try c.propFmt("label.color", "0x{x:0>8}", .{theme.label_color});
    try c.propFmt("label.padding_left", "{d}", .{theme.padding});
    try c.propFmt("label.padding_right", "{d}", .{theme.padding});
    try c.propFmt("background.padding_right", "{d}", .{theme.padding});
    try c.propFmt("background.padding_left", "{d}", .{theme.padding});
    try c.propFmt("background.height", "{d}", .{theme.bar_height});
    try c.prop("background.corner_radius", "9");
    try c.prop("popup.background.border_width", "0");
    try c.prop("popup.background.corner_radius", "0");
    try c.propFmt("popup.background.border_color", "0x{x:0>8}", .{theme.black});
    try c.propFmt("popup.background.color", "0x{x:0>8}", .{theme.black});
    try c.prop("popup.background.shadow.drawing", "off");
}

fn spaces(c: *sb.Client) !void {
    var index: u32 = 1;
    while (index <= max_spaces) : (index += 1) {
        var name: [16]u8 = undefined;
        const item = try std.fmt.bufPrint(&name, "space.{d}", .{index});

        try c.arg("--add");
        try c.arg("space");
        try c.arg(item);
        try c.arg("left");

        var props: Props = .{};
        // Older configurations attached a highlight script to space items; the
        // helper owns `icon.highlight` now.
        props.raw(clear_script);
        try props.num("associated_space", index);
        try props.num("icon", index);
        try props.num("icon.padding_left", 10);
        try props.num("icon.padding_right", 10);
        try props.color("icon.color", theme.white);
        try props.color("icon.highlight_color", theme.green);
        try props.fmt("icon.font={s}:ExtraBold:13.0", .{theme.font});
        try props.num("background.padding_left", 0);
        try props.num("background.padding_right", 0);
        try props.color("background.color", theme.black);
        props.raw("background.drawing=off");
        try props.fmt("label.font={s}:Regular:14", .{theme.app_font});
        try props.num("label.y_offset", -1);
        try props.num("label.background.height", 28);
        props.raw("label.background.drawing=on");
        try props.color("label.background.color", theme.background_2);
        try props.color("label.color", theme.white);
        try props.color("label.highlight_color", theme.background_1);
        props.raw("label.width=dynamic");
        try props.num("label.padding_right", 6);
        try props.num("label.padding_left", 6);
        try props.num("label.background.corner_radius", 0);
        try props.num("background.corner_radius", 0);
        props.raw("label.drawing=off");
        // A click used to fork `yabai` through a shell. It arrives as an event
        // instead, and the click block already carries the space's `SID`.
        props.raw(clear_click_script);
        try c.set(item, props.slice());

        try c.arg("--subscribe");
        try c.arg(item);
        try c.arg("mouse.clicked");
    }

    try c.arg("--add");
    try c.arg("item");
    try c.arg("separator");
    try c.arg("left");
    var props: Props = .{};
    props.raw("drawing=on");
    try props.fmt("icon={s}", .{theme.glyph.separator});
    try props.fmt("icon.font={s}:Regular:11.0", .{theme.font});
    try props.num("background.padding_left", 16);
    try props.num("background.padding_right", 6);
    props.raw("label.drawing=off");
    try props.color("icon.color", theme.separator_icon);
    try c.set("separator", props.slice());
}

fn frontAppItems(c: *sb.Client, config: Config) !void {
    // A single hidden driver item receives `yabai_update` and lets the helper
    // refresh every space and per-display item from one batch.
    try c.arg("--add");
    try c.arg("event");
    try c.arg("yabai_update");

    try c.arg("--add");
    try c.arg("item");
    try c.arg("system.yabai");
    try c.arg("left");
    var driver: Props = .{};
    driver.raw(clear_script);
    driver.raw("drawing=off");
    driver.raw("updates=on");
    try driver.num("associated_display", 1);
    try driver.text("mach_helper", config.helper);
    try c.set("system.yabai", driver.slice());

    try c.arg("--subscribe");
    try c.arg("system.yabai");
    try c.arg("yabai_update");
    try c.arg("display_change");

    var display: u32 = 1;
    while (display <= max_displays) : (display += 1) {
        var name: [24]u8 = undefined;

        const status = try std.fmt.bufPrint(&name, "yabai_status.{d}", .{display});
        try c.arg("--add");
        try c.arg("item");
        try c.arg(status);
        try c.arg("left");

        var status_props: Props = .{};
        status_props.raw(clear_script);
        status_props.raw("drawing=on");
        try status_props.fmt("icon.font={s}:Bold:14.0", .{theme.font});
        status_props.raw("label.drawing=off");
        try status_props.fmt("label.font={s}:Regular:12.0", .{theme.font});
        try status_props.num("icon.width", 24);
        try status_props.fmt("icon={s}", .{theme.glyph.yabai_grid});
        try status_props.color("icon.color", theme.orange);
        status_props.raw("updates=off");
        try status_props.num("associated_display", display);
        try c.set(status, status_props.slice());

        const front = try std.fmt.bufPrint(&name, "front_app.{d}", .{display});
        try c.arg("--add");
        try c.arg("item");
        try c.arg(front);
        try c.arg("left");

        var front_props: Props = .{};
        front_props.raw("drawing=on");
        try front_props.num("background.padding_left", 0);
        try front_props.num("background.padding_right", 10);
        try front_props.color("icon.color", theme.white);
        try front_props.fmt("icon.font={s}:ExtraBold:12.0", .{theme.font});
        try front_props.color("label.color", theme.grey);
        try front_props.fmt("label.font={s}:Italic:12.0", .{theme.font});
        try front_props.num("associated_display", display);
        try c.set(front, front_props.slice());
    }
}

fn rightItems(c: *sb.Client, config: Config) !void {
    // Battery: read from IOKit in-process instead of spawning `pmset`.
    try c.arg("--add");
    try c.arg("item");
    try c.arg("battery");
    try c.arg("right");
    var battery: Props = .{};
    battery.raw(clear_script);
    try battery.text("mach_helper", config.helper);
    try battery.num("update_freq", 120);
    try c.set("battery", battery.slice());
    try c.arg("--subscribe");
    try c.arg("battery");
    try c.arg("system_woke");
    try c.arg("power_source_change");

    // Calendar: formatted in-process from the system clock.
    try c.arg("--add");
    try c.arg("item");
    try c.arg("calendar");
    try c.arg("right");
    var calendar: Props = .{};
    calendar.raw("icon=cal");
    try calendar.fmt("icon.font={s}:ExtraBold:11.0", .{theme.font});
    try calendar.num("icon.padding_right", 8);
    try calendar.color("icon.color", theme.calendar_icon);
    try calendar.num("icon.y_offset", -2);
    try calendar.num("icon.padding_left", 0);
    calendar.raw("icon.drawing=on");
    try calendar.num("label.width", 40);
    calendar.raw("label.align=right");
    try calendar.num("background.padding_left", 0);
    try calendar.num("update_freq", 5);
    calendar.raw(clear_script);
    calendar.raw(clear_click_script);
    try calendar.text("mach_helper", config.helper);
    try c.set("calendar", calendar.slice());
    try c.arg("--subscribe");
    try c.arg("calendar");
    try c.arg("mouse.clicked");

    // Homebrew: `brew outdated` is genuinely slow, so the item asks for it
    // coarsely, and the daemon runs it off the event path.
    try c.arg("--add");
    try c.arg("event");
    try c.arg("brew_update");
    try c.arg("--add");
    try c.arg("item");
    try c.arg("brew");
    try c.arg("right");
    var brew: Props = .{};
    brew.raw(clear_script);
    try brew.text("mach_helper", config.helper);
    try brew.fmt("icon={s}", .{theme.glyph.brew});
    try brew.num("update_freq", 3600);
    brew.raw("label=?");
    try brew.num("associated_display", 1);
    brew.raw("drawing=on");
    try brew.num("background.padding_right", 15);
    try c.set("brew", brew.slice());
    try c.arg("--subscribe");
    try c.arg("brew");
    try c.arg("brew_update");

    // GitHub notifications: `gh api` every three minutes, event driven.
    try c.arg("--add");
    try c.arg("item");
    try c.arg("github.bell");
    try c.arg("right");
    var bell: Props = .{};
    bell.raw("drawing=on");
    try bell.num("update_freq", 180);
    try bell.fmt("icon.font={s}:Bold:15.0", .{theme.font});
    try bell.fmt("icon={s}", .{theme.glyph.github});
    try bell.color("icon.color", theme.blue);
    try bell.fmt("label={s}", .{theme.glyph.loading});
    try bell.color("label.highlight_color", theme.blue);
    bell.raw("popup.align=right");
    try bell.num("width", 30);
    // A little air on the left, where the provider balances now sit against it.
    try bell.num("background.padding_left", 12);
    try bell.num("associated_display", 1);
    bell.raw(clear_script);
    bell.raw(clear_click_script);
    try bell.text("mach_helper", config.helper);
    try c.set("github.bell", bell.slice());
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
    var template: Props = .{};
    template.raw("drawing=off");
    try template.num("background.corner_radius", 12);
    try template.num("background.padding_left", 7);
    try template.num("background.padding_right", 7);
    try template.color("background.color", theme.black);
    template.raw("background.drawing=off");
    try template.num("icon.background.height", 2);
    try template.num("icon.background.y_offset", -12);
    // A popup row is built by `--clone`, and a row is clicked long after the
    // refresh that built it, so the routing is stated here *and* per row: the
    // row is what SketchyBar resolves, and the template is only its ancestor.
    try template.text("mach_helper", config.helper);
    template.raw(clear_click_script);
    template.raw("updates=on");
    try c.set("github.template", template.slice());
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
    var neuralwatt: Props = .{};
    neuralwatt.raw("drawing=on");
    try neuralwatt.num("associated_display", 1);
    // `dynamic` is SketchyBar's automatic width, and the default - but a
    // property an earlier configuration set stays set otherwise, which is the
    // same trap the empty `script=` and `click_script=` below exist for.
    neuralwatt.raw("width=dynamic");
    try neuralwatt.fmt("icon.font={s}:Bold:14.0", .{theme.font});
    try neuralwatt.fmt("icon={s}", .{theme.glyph.neuralwatt});
    // Dim until the first answer arrives: the colour is the daemon's to set, and
    // a reading that stopped refreshing is dimmed rather than left bright.
    try neuralwatt.color("icon.color", theme.dark_grey);
    neuralwatt.raw("label=?");
    neuralwatt.raw(clear_script);
    neuralwatt.raw(clear_click_script);
    try neuralwatt.text("mach_helper", config.helper);
    try c.set(items_usage.neuralwatt_item, neuralwatt.slice());
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
    var openrouter: Props = .{};
    openrouter.raw("drawing=on");
    try openrouter.num("associated_display", 1);
    openrouter.raw("width=dynamic");
    try openrouter.fmt("icon.font={s}:Bold:14.0", .{theme.font});
    try openrouter.fmt("icon={s}", .{theme.glyph.openrouter});
    try openrouter.color("icon.color", theme.dark_grey);
    openrouter.raw("label=?");
    openrouter.raw(clear_script);
    openrouter.raw(clear_click_script);
    try openrouter.text("mach_helper", config.helper);
    try c.set(items_usage.openrouter_item, openrouter.slice());
    try c.arg("--subscribe");
    try c.arg(items_usage.openrouter_item);
    try c.arg("mouse.entered");
    try c.arg("mouse.exited");
    try c.arg("mouse.exited.global");
    try c.arg("mouse.clicked");

    // One popup row per window, per provider. They are declared rather than
    // cloned, because the number of rows does not vary.
    for ([_]struct { parent: []const u8, color: theme.Color }{
        .{ .parent = items_usage.neuralwatt_item, .color = theme.green },
        .{ .parent = items_usage.openrouter_item, .color = theme.aqua },
    }) |provider| {
        for ([_]struct { suffix: []const u8, nominal: []const u8 }{
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

            var detail: Props = .{};
            detail.raw("drawing=on");
            try detail.num("background.corner_radius", 12);
            try detail.num("background.padding_left", 7);
            try detail.num("background.padding_right", 7);
            try detail.color("background.color", theme.black);
            detail.raw("background.drawing=off");
            try detail.num("label.padding_left", 7);
            try detail.num("label.padding_right", 7);
            try detail.color("label.color", provider.color);
            try detail.fmt("label={s} -", .{row.nominal});
            detail.raw(clear_script);
            detail.raw(clear_click_script);
            try c.set(name, detail.slice());
        }
    }

    // Aliases to other applications' status items.
    try alias(c, "Little Snitch Agent,Item-0", "network_alias", &.{
        "drawing=on",
        "associated_display=1",
        "alias.update_freq=1",
        "background.padding_left=-15",
        "background.padding_right=0",
    });

    // The pomodoro timer. Its countdown is the daemon's own: the daemon pushes
    // it to the label when the second changes, so the item carries no
    // `update_freq`, forks nothing, and asks no other application for the time.
    // A left click starts or stops the timer, a right click resets it.
    try c.arg("--add");
    try c.arg("item");
    try c.arg(pomodoro.item);
    try c.arg("e");
    var timer: Props = .{};
    timer.raw("icon=:clock:");
    try timer.num("associated_display", 1);
    try timer.fmt("icon.font={s}:Regular:16.0", .{theme.app_font});
    try timer.num("icon.padding_right", 2);
    try timer.color("icon.color", theme.dark_grey);
    timer.raw("icon.drawing=on");
    try timer.num("label.width", 52);
    timer.raw("label.align=left");
    try timer.color("label.color", theme.dark_grey);
    timer.raw("label=");
    timer.raw(clear_script);
    timer.raw(clear_click_script);
    try timer.text("mach_helper", config.helper);
    try c.set(pomodoro.item, timer.slice());
    try c.arg("--subscribe");
    try c.arg(pomodoro.item);
    try c.arg("mouse.clicked");
}

/// Alias an item owned by another application and give it a stable name.
///
/// An alias reads its owner and window name out of the `--add` token, so it has
/// to be created under the source name and then renamed. Both names are removed
/// first, because that pair is not idempotent on its own: applying the
/// configuration a second time creates another alias under the source name and
/// the rename then fails, leaving duplicate items capturing the same status
/// item.
fn alias(c: *sb.Client, source: []const u8, name: []const u8, props: []const []const u8) !void {
    try c.arg("--remove");
    try c.arg(name);
    try c.arg("--remove");
    try c.arg(source);
    try c.arg("--add");
    try c.arg("alias");
    try c.arg(source);
    try c.arg("right");
    try c.arg("--rename");
    try c.arg(source);
    try c.arg(name);
    try c.set(name, props);
}
