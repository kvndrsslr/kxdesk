//! `zen` mode: collapse the bar down to the essentials and back.
//!
//! Replaces `plugins/zen.sh`, which spawned the `sketchybar` CLI once per item
//! and forked `jq` to read back a single boolean. Here it is two queries and one
//! command batch.
//!
//! Zen is opt-*out*: it hides every item the bar has and keeps only what this
//! file names, rather than hiding a list of items written down here. The bar is
//! asked what it has, so an item added to the configuration is hidden by the next
//! toggle without anyone remembering to come back to this file - which is how
//! the network graphs and the link icon joined the collapsed bar.

const std = @import("std");

const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const state = @import("store.zig");

/// The items zen leaves alone: the collapsed bar is the spaces, the clock, the
/// battery and the timer, and what is not drawn on the bar at all is none of
/// zen's business either.
///
/// That last part is why the popup rows and the helper item are named here: they
/// carry `drawing = off` - or are only ever drawn inside a popup - so a zen that
/// showed them back would put a stray divider in the bell's popup and a blank
/// stretch on the left of the bar. Every other item the bar has is drawn when the
/// bar is not collapsed, and is hidden and shown again by name.
const kept = [_][]const u8{
    // The spaces are the bar's left side, and stay through a collapse.
    "space.",
    // The clock's *label* stays; only its icon goes (see `apply`).
    "calendar",
    "battery.ring",
    "pomodoro",
    // Popup rows: drawn inside a popup, and only while it is open. Named by
    // prefix, so a row added to `items_usage.rows` is covered without a second
    // edit here.
    "github.template",
    "neuralwatt.",
    // The helper item that carries yabai's events. It draws nothing.
    "system.yabai",
};

/// Whether an item is one zen leaves alone. Prefixes, so `space.` covers every
/// space without naming them one by one.
pub fn isKept(item: []const u8) bool {
    for (kept) |prefix| {
        if (std.mem.startsWith(u8, item, prefix)) return true;
    }
    return false;
}

pub const Mode = enum { on, off, toggle };

/// Where the collapsed bar is remembered.
pub const state_key = "zen";

/// Apply zen mode and remember it, so a bar that is restarted comes back the way
/// the last one was left.
pub fn set(bar: *sb.Client, arena: std.mem.Allocator, mode: Mode, store: *state.Store, io: std.Io) !void {
    const collapsed = try apply(bar, arena, mode);
    store.setInt(io, state_key, @intFromBool(collapsed)) catch {};
}

/// Put back the collapsed state, if that is how the bar was left.
pub fn restore(bar: *sb.Client, arena: std.mem.Allocator, store: *state.Store, io: std.Io) !void {
    const collapsed = (store.getInt(io, state_key) catch null) orelse return;
    if (collapsed == 0) return;
    _ = try apply(bar, arena, .on);
}

/// Returns the state the bar is in afterwards - `.toggle` reads it from the bar
/// first, so the caller can remember the answer.
pub fn apply(bar: *sb.Client, arena: std.mem.Allocator, mode: Mode) !bool {
    const zen = switch (mode) {
        .on => true,
        .off => false,
        // Clicking the calendar flips whatever state the bar is in, which is
        // read back from the item the shell plugin also used as its sentinel.
        .toggle => try isVisible(bar, arena),
    };
    const drawing = if (zen) "off" else "on";

    // Everything the bar has, read back from the bar itself, less what zen
    // keeps. An item this file has never heard of is hidden with the rest - and
    // named back into place when the bar is expanded again, since an item that is
    // drawn when the bar is not collapsed is exactly the set zen hides.
    for (try items(bar, arena)) |item| {
        if (isKept(item)) continue;

        var props: Props = .{};
        try props.fmt("drawing={s}", .{drawing});
        try bar.set(item, props.slice());
    }

    // The clock's icon goes with the rest and its label stays, so the collapsed
    // bar still says what time it is.
    var calendar: Props = .{};
    try calendar.fmt("icon.drawing={s}", .{drawing});
    try bar.set("calendar", calendar.slice());

    try bar.commit();
    return zen;
}

/// The bar's own list of its items, from `--query bar`.
fn items(bar: *sb.Client, arena: std.mem.Allocator) ![]const []const u8 {
    const response = try arena.alloc(u8, 64 * 1024);

    bar.clear();
    try bar.arg("--query");
    try bar.arg("bar");
    const text = try bar.commitInto(response);

    const parsed = try std.json.parseFromSliceLeaky(BarState, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    });
    return parsed.items;
}

const BarState = struct { items: []const []const u8 = &.{} };

const Geometry = struct { drawing: []const u8 = "on" };
const ItemState = struct { geometry: Geometry = .{} };

/// Whether the bar is currently drawn, as reported by the GitHub bell item.
fn isVisible(bar: *sb.Client, arena: std.mem.Allocator) !bool {
    const response = try arena.alloc(u8, 32 * 1024);

    bar.clear();
    try bar.arg("--query");
    try bar.arg("github.bell");
    const text = try bar.commitInto(response);

    const parsed = std.json.parseFromSliceLeaky(ItemState, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return true;

    return std.mem.eql(u8, parsed.geometry.drawing, "on");
}
