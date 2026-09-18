//! `zen` mode: collapse the bar down to the essentials and back.
//!
//! Replaces `plugins/zen.sh`, which spawned the `sketchybar` CLI once per item
//! and forked `jq` to read back a single boolean. Here it is one query and one
//! command batch.

const std = @import("std");

const Props = @import("props.zig").Props;
const sb = @import("sb.zig");

/// Items that are simply hidden and shown again. These mirror the items
/// `bar.zig` declares: the cpu and Spotify items this list used to name are gone
/// from the configuration, so naming them only produced "item not found".
const simple_items = [_][]const u8{
    "github.bell",
    "separator",
    "brew",
    "/.*_alias/",
};

/// Items paired per display.
const display_items = [_][]const u8{ "front_app", "yabai_status" };

/// Same range of displays as the configured `front_app` / `yabai_status` items.
const max_displays = 4;

pub const Mode = enum { on, off, toggle };

pub fn apply(bar: *sb.Client, arena: std.mem.Allocator, mode: Mode) !void {
    const zen = switch (mode) {
        .on => true,
        .off => false,
        // Clicking the calendar flips whatever state the bar is in, which is
        // read back from the item the shell plugin also used as its sentinel.
        .toggle => try isVisible(bar, arena),
    };
    const drawing = if (zen) "off" else "on";

    for (simple_items) |item| {
        var props: Props = .{};
        try props.fmt("drawing={s}", .{drawing});
        try bar.set(item, props.slice());
    }

    var calendar: Props = .{};
    try calendar.fmt("icon.drawing={s}", .{drawing});
    try bar.set("calendar", calendar.slice());

    var display: u32 = 1;
    while (display <= max_displays) : (display += 1) {
        for (display_items) |prefix| {
            var name: [32]u8 = undefined;
            const item = try std.fmt.bufPrint(&name, "{s}.{d}", .{ prefix, display });
            var props: Props = .{};
            try props.fmt("drawing={s}", .{drawing});
            try bar.set(item, props.slice());
        }
    }

    try bar.commit();
}

const Geometry = struct { drawing: []const u8 = "on" };
const ItemState = struct { @"geometry": Geometry = .{} };

/// Whether the bar is currently drawn, as reported by the GitHub bell item.
fn isVisible(bar: *sb.Client, arena: std.mem.Allocator) !bool {
    const response = try arena.alloc(u8, 32 * 1024);

    bar.clear();
    try bar.arg("--query");
    try bar.arg("github.bell");
    const text = try bar.commitInto(response);

    const state = std.json.parseFromSliceLeaky(ItemState, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return true;

    return std.mem.eql(u8, state.@"geometry".drawing, "on");
}
