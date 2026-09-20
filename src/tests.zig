//! First unit tests: store roundtrip, the `KXDESK_STATE` seam, and cli
//! validation. A dedicated root rather than `main.zig`, which pulls in
//! `build_options` and the daemon; this only touches the platform-free logic
//! (`store.zig`, `cli.zig`) plus the platform seam under test.

const std = @import("std");

const cli = @import("cli.zig");
const config = @import("config.zig");
const items_system = @import("items_system.zig");
const items_usage = @import("items_usage.zig");
const store = @import("store.zig");
const theme = @import("theme.zig");
const zen = @import("zen.zig");

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

test "netLevel maps a rate onto the graph logarithmically" {
    // A rate at the graph's floor is a line on the bottom, and the graph is six
    // decades tall, so a decade is a sixth of its height.
    try std.testing.expectEqual(@as(f64, 0), items_system.netLevel(0));
    try std.testing.expectEqual(@as(f64, 0), items_system.netLevel(1_000));
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 6.0), items_system.netLevel(10_000), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), items_system.netLevel(1_000_000), 1e-9);
    // A rate at the ceiling fills the graph, and one past it stays in it.
    try std.testing.expectApproxEqAbs(@as(f64, 1), items_system.netLevel(1_000_000_000), 1e-9);
    try std.testing.expectEqual(@as(f64, 1), items_system.netLevel(10_000_000_000));
}

test "formatRate keeps a reading inside three digits and a unit" {
    const cases = [_]struct { rate: f64, text: []const u8 }{
        .{ .rate = 0, .text = "0B" },
        .{ .rate = 512, .text = "512B" },
        .{ .rate = 999.9, .text = "999B" },
        .{ .rate = 1_000, .text = "1.00K" },
        .{ .rate = 9_999, .text = "9.99K" },
        .{ .rate = 10_000, .text = "10.0K" },
        .{ .rate = 99_999, .text = "99.9K" },
        .{ .rate = 100_000, .text = "100K" },
        .{ .rate = 999_999, .text = "999K" },
        .{ .rate = 1_000_000, .text = "1.00M" },
        .{ .rate = 9_999_999, .text = "9.99M" },
        .{ .rate = 10_000_000, .text = "10.0M" },
        .{ .rate = 29_700_000, .text = "29.7M" },
        .{ .rate = 999_999_999, .text = "999M" },
        .{ .rate = 1_000_000_000, .text = "1.00G" },
        .{ .rate = 42_000_000_000, .text = "42.0G" },
    };

    for (cases) |case| {
        var buffer: [8]u8 = undefined;
        const text = try items_system.formatRate(case.rate, &buffer);
        try std.testing.expectEqualStrings(case.text, text);
        // Three digits, one separator and the unit is what the graph's right
        // padding is sized for - see `readout_chars` in `bar.zig` - so the width
        // is a contract and not a coincidence of these cases.
        try std.testing.expect(text.len <= 5);
    }
}

test "an unreadable reset instant costs a Go row its countdown, not its number" {
    var buffer: [64]u8 = undefined;
    const rolling = items_usage.opencode_rows[0];

    // The endpoint's own shape: UTC, and the countdown is what is left between the
    // row's instant and now. `20716` is 2026-09-20, checked against the epoch.
    const noon = 20716 * std.time.s_per_day + 12 * std.time.s_per_hour;
    try std.testing.expectEqualStrings(
        "5h 14% · resets in 2h 30m",
        try items_usage.opencodeRow(&buffer, rolling, 14, "2026-09-20T12:00:00Z", noon - 2 * std.time.s_per_hour - 30 * std.time.s_per_min),
    );

    // Fractional seconds are dropped rather than refused, and an offset is
    // subtracted, so `+02:00` means an instant two hours earlier than the clock
    // says - the one mistake a countdown must not make. Half an hour before it is
    // half an hour left; read as UTC it would have been two and a half.
    try std.testing.expectEqualStrings(
        "5h 14% · resets in 30m",
        try items_usage.opencodeRow(&buffer, rolling, 14, "2026-09-20T14:00:00.500+02:00", noon - 30 * std.time.s_per_min),
    );

    // Longer than a day reads in days and hours, and a window whose instant has
    // already passed reads as none left rather than as one in the past.
    try std.testing.expectEqualStrings(
        "month 3% · resets in 1d 1h",
        try items_usage.opencodeRow(&buffer, items_usage.opencode_rows[2], 3, "2026-09-21T13:00:00Z", noon),
    );
    try std.testing.expectEqualStrings(
        "5h 0% · resets in 0m",
        try items_usage.opencodeRow(&buffer, rolling, 0, "2026-09-20T11:00:00Z", noon),
    );

    // A stamp this cannot read is not counted from: an instant without a zone, a
    // month that does not exist, and a word that is not a stamp at all all cost
    // the row its countdown and leave the share alone.
    for ([_][]const u8{
        "2026-09-20T12:00:00",
        "2026-13-20T12:00:00Z",
        "2026-09-20 12:00:00Z",
        "2026-09-20T12:00:00+0200",
        "soon",
        "",
    }) |stamp| {
        try std.testing.expectEqualStrings(
            "5h 14%",
            try items_usage.opencodeRow(&buffer, rolling, 14, stamp, noon),
        );
    }
}

test "zen keeps the collapsed bar's furniture and hides the rest" {
    // Spaces keep whole, the clock keeps, and everything the bar carries news in
    // is hidden - which is what makes zen opt-out: an item is hidden unless it is
    // named, and these are the only names.
    try std.testing.expect(zen.isKept("space.7"));
    try std.testing.expect(zen.isKept("calendar"));
    try std.testing.expect(zen.isKept("battery.ring"));
    try std.testing.expect(zen.isKept("pomodoro"));

    try std.testing.expect(!zen.isKept("cpu"));
    try std.testing.expect(!zen.isKept("net.down"));
    try std.testing.expect(!zen.isKept("net.up"));
    try std.testing.expect(!zen.isKept("net.link"));
    try std.testing.expect(!zen.isKept("brew"));
    try std.testing.expect(!zen.isKept("front_app.2"));

    // A provider's popup rows stay, its item does not: the rows are drawn inside
    // the popup and only while it is open, while the item is content zen hides.
    try std.testing.expect(zen.isKept("opencode-go.monthly"));
    try std.testing.expect(!zen.isKept("opencode-go"));
}
