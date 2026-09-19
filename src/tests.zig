//! First unit tests: store roundtrip, the `KXDESK_STATE` seam, and cli
//! validation. A dedicated root rather than `main.zig`, which pulls in
//! `build_options` and the daemon; this only touches the platform-free logic
//! (`store.zig`, `cli.zig`) plus the platform seam under test.

const std = @import("std");

const cli = @import("cli.zig");
const config = @import("config.zig");
const store = @import("store.zig");
const theme = @import("theme.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "store get/set roundtrip" {
    const io = std.testing.io;
    const path = "/tmp/kxdesk-tests-store.db";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        std.Io.Dir.deleteFileAbsolute(io, path ++ "-wal") catch {};
        std.Io.Dir.deleteFileAbsolute(io, path ++ "-shm") catch {};
    }

    var db = store.Store.open(io, path);
    defer db.close();
    try std.testing.expect(db.enabled());

    try db.setText(io, "greeting", "hello");
    var out: [64]u8 = undefined;
    const got = try db.getText(io, "greeting", &out);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("hello", got.?);
}

test "KXDESK_STATE seam" {
    const seam = "/tmp/kxdesk-tests-seam.db";
    try std.testing.expectEqual(@as(c_int, 0), setenv("KXDESK_STATE", seam, 1));
    defer _ = setenv("KXDESK_STATE", "", 1);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(seam, store.Store.defaultPath(&buffer));
}

test "cli.validate rejects malformed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const command = cli.find("state") orelse return error.TestUnexpectedResult;
    const unknown = try cli.validate(arena.allocator(), command, &.{"bogus-sub"});
    try std.testing.expect(unknown != null);

    const missing = try cli.validate(arena.allocator(), command, &.{"get"});
    try std.testing.expect(missing != null);
}

/// Compare the NUL-separated `args` of a compiled config against the flat
/// `key=value` list, tolerating the trailing NUL that terminates each arg (it
/// is the wire layout, but it shows up as a final empty chunk when split).
fn expectArgs(args: []const u8, expected: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, args, 0);
    var index: usize = 0;
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        if (index >= expected.len) return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected[index], arg);
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
}

test "config: nested node flattens to flat key=value args" {
    const cfg = config.node(.{
        .drawing = true,
        .icon = .{
            .font = "JetBrainsMono Nerd Font:Bold:7.0",
            .badge = .{
                .anchor = config.Anchors.bottom_right,
                .x_offset = 2,
                .y_offset = -1,
                .background = .{
                    .drawing = true,
                    .color = config.color(theme.badge_background),
                    .corner_radius = 6,
                    .padding_left = 1,
                    .padding_right = 1,
                },
            },
        },
        .label = .{ .drawing = false, .value = null },
    });

    const expected = [_][]const u8{
        "drawing=on",
        "icon.font=JetBrainsMono Nerd Font:Bold:7.0",
        "icon.badge.anchor=bottom_right",
        "icon.badge.x_offset=2",
        "icon.badge.y_offset=-1",
        "icon.badge.background.drawing=on",
        "icon.badge.background.color=0xff3c3836",
        "icon.badge.background.corner_radius=6",
        "icon.badge.background.padding_left=1",
        "icon.badge.background.padding_right=1",
        "label.drawing=off",
        "label=",
    };

    try expectArgs(cfg.args, &expected);
}

test "config: colour hex and integer leaves" {
    const cfg = config.node(.{
        .x_offset = 2,
        .icon = .{ .color = config.color(theme.green) },
    });

    const expected = [_][]const u8{
        "x_offset=2",
        "icon.color=0xffb8bb27",
    };
    try expectArgs(cfg.args, &expected);
}

test "config: single flag becomes one NUL-terminated arg" {
    const cfg = config.node(.{ .drawing = true });
    try expectArgs(cfg.args, &.{"drawing=on"});
    try std.testing.expectEqual(@as(usize, 11), cfg.args.len);
}
