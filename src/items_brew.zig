//! The brew item's refresh: how many packages are outdated, on the item's badge.
//!
//! `brew outdated` alone takes over a second here, so the daemon runs this as a
//! background task rather than on the event path; see `background.zig`.

const std = @import("std");

const exec = @import("exec.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");

/// The item this refresh owns. `dispatch.zig` routes its events by this name.
pub const item = "brew";

pub fn refresh(io: std.Io, gpa: std.mem.Allocator) anyerror!void {
    const brew = try exec.path(gpa, "brew");
    defer gpa.free(brew);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ brew, "outdated" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // Newlines, not entries: this is the count `brew outdated | wc -l` printed, down
    // to output that ends without a newline.
    const count = std.mem.count(u8, result.stdout, "\n");

    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    const idle = count == 0;
    var count_buffer: [16]u8 = undefined;
    // Numbers read at 9pt like the bell's; the idle checkmark in the same Nerd Font
    // draws oversized next to them, so it gets 8pt.
    const font = if (idle) style.mono(.Bold, 8) else style.mono(.Bold, 9);
    const badge: []const u8 = if (idle)
        theme.glyph.brew_current
    else
        try std.fmt.bufPrint(&count_buffer, "{d}", .{count});

    var props: Props = .{};
    try props.write(.{ .icon = .{
        .badge = .{ .value = badge, .font = font },
        .color = try props.argb(if (idle) theme.green else outdatedColor(count)),
    } });

    try client.set(item, props.slice());
    try client.commit();
}

/// The count's grade: 1-9 white, 10-29 yellow, 30-59 orange, anything larger red -
/// and none at all green with a tick.
fn outdatedColor(count: usize) theme.Color {
    return switch (count) {
        1...9 => theme.white,
        10...29 => theme.yellow,
        30...59 => theme.orange,
        else => theme.red,
    };
}
