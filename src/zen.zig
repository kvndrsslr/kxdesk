//! `zen` mode: collapse the bar down to the essentials and back.
//!
//! Zen is opt-*out*: the bar's own item list comes from `--query bar` and every
//! item `kept` does not name is hidden, so an item added to the configuration is
//! covered without editing this file.

const std = @import("std");

const items_usage = @import("items_usage.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const state = @import("store.zig");

/// Items zen leaves alone: the collapsed bar's content, plus what draws nothing.
const kept = [_][]const u8{
    "space.",
    "calendar",
    "battery.ring",
    "pomodoro",
    "github.template",
    "neuralwatt.",
    "opencode-go.",
    "system.yabai",
};

/// Whether an item is one zen leaves alone; an entry covers by prefix.
pub fn isKept(item: []const u8) bool {
    for (kept) |prefix| {
        if (std.mem.startsWith(u8, item, prefix)) return true;
    }
    return false;
}

pub const Mode = enum { on, off, toggle };

/// Where the collapsed state is remembered.
pub const state_key = "zen";

/// Apply zen mode and remember it, so a restarted bar comes back as it was left.
pub fn set(bar: *sb.Client, arena: std.mem.Allocator, mode: Mode, store: *state.Store, io: std.Io) !void {
    const collapsed = try apply(bar, arena, mode, store, io);
    store.setInt(io, state_key, @intFromBool(collapsed)) catch {};
}

/// Put back the collapsed state, if that is how the bar was left.
pub fn restore(bar: *sb.Client, arena: std.mem.Allocator, store: *state.Store, io: std.Io) !void {
    const collapsed = (store.getInt(io, state_key) catch null) orelse return;
    if (collapsed == 0) return;
    _ = try apply(bar, arena, .on, store, io);
}

/// Returns the state the bar is in afterwards, for the caller to remember.
pub fn apply(bar: *sb.Client, arena: std.mem.Allocator, mode: Mode, store: *state.Store, io: std.Io) !bool {
    const collapsed = switch (mode) {
        .on => true,
        .off => false,
        // Clicking the calendar flips whatever state the bar is in.
        .toggle => try isVisible(bar, arena),
    };
    // A collapsed bar draws nothing, so the drawing flag is its negation.
    const drawing = !collapsed;

    // Every bar item less what `kept` names: this loop hides unknown items and names them back.
    for (try items(bar, arena)) |item| {
        if (isKept(item)) continue;
        // A provider with no token is off the bar in every mode, so do not restore it.
        if (!items_usage.configured(io, store, item)) continue;

        var props: Props = .{};
        try props.write(.{ .drawing = drawing });
        try bar.set(item, props.slice());
    }

    // The clock's icon goes; its label stays, so the collapsed bar still shows the time.
    var calendar: Props = .{};
    try calendar.write(.{ .icon = .{ .drawing = drawing } });
    try bar.set("calendar", calendar.slice());

    try bar.commit();
    return collapsed;
}

/// The bar's own list of its items, from `--query bar`.
fn items(bar: *sb.Client, arena: std.mem.Allocator) ![]const []const u8 {
    const parsed = try bar.query(BarState, arena, "bar");
    return parsed.items;
}

const BarState = struct { items: []const []const u8 = &.{} };

const Geometry = struct { drawing: []const u8 = "on" };
const ItemState = struct { geometry: Geometry = .{} };

/// Whether the bar is drawn, per the bell item's `geometry.drawing`. An answer
/// that does not parse means drawn; a bar that cannot be asked is an error.
fn isVisible(bar: *sb.Client, arena: std.mem.Allocator) !bool {
    const parsed = bar.query(ItemState, arena, "github.bell") catch |err| switch (err) {
        error.SketchyBarUnavailable, error.ResponseTooLong, error.OutOfMemory => return err,
        else => return true,
    };
    return std.mem.eql(u8, parsed.geometry.drawing, "on");
}
