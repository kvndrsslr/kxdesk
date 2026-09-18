//! The brew item's refresh.
//!
//! Replaces `plugins/brew.sh`, which SketchyBar forked and which then forked
//! `brew outdated` through `sh`, `wc` and a sourced colour file. `brew outdated`
//! alone takes over a second here, so the daemon runs this as a background task
//! rather than on the event path; see `background.zig`.

const std = @import("std");

const exec = @import("exec.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const theme = @import("theme.zig");

/// The item this refresh owns. `dispatch.zig` routes its events by this name.
pub const item = "brew";

pub fn refresh(io: std.Io, gpa: std.mem.Allocator) anyerror!void {
    const brew = try exec.path(gpa, "brew");
    defer gpa.free(brew);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ brew, "outdated" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // The shell counted lines (`brew outdated | wc -l`), not entries, so a
    // command whose output ends without a newline still counts as it did then.
    const count = std.mem.count(u8, result.stdout, "\n");

    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    var props: Props = .{};
    if (count == 0) {
        try props.fmt("icon.badge={s}", .{theme.glyph.brew_current});
        try props.color("icon.color", theme.green);
    } else {
        try props.fmt("icon.badge={d}", .{count});
        try props.color("icon.color", outdatedColor(count));
    }

    try client.set(item, props.slice());
    try client.commit();
}

/// The shell graded the count: 1-9 white, 10-29 yellow, 30-59 orange, anything
/// larger red, and none at all green with a tick.
fn outdatedColor(count: usize) theme.Color {
    return switch (count) {
        1...9 => theme.white,
        10...29 => theme.yellow,
        30...59 => theme.orange,
        else => theme.red,
    };
}
