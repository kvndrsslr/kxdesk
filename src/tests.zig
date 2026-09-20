//! First unit tests: store roundtrip, the `KXDESK_STATE` seam, and cli
//! validation. A dedicated root rather than `main.zig`, which pulls in
//! `build_options` and the daemon; this only touches the platform-free logic
//! (`store.zig`, `cli.zig`) plus the platform seam under test.

const std = @import("std");

const cli = @import("cli.zig");
const config = @import("config.zig");
const items_system = @import("items_system.zig");
const items_usage = @import("items_usage.zig");
const kanata = @import("kanata.zig");
const Props = @import("props.zig").Props;
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

test "the Go item's face is the tightest window, the month's ring, and spent" {
    // The three windows in `opencode_rows` order: rolling, weekly, monthly.
    const reading = items_usage.face(.{
        .{ .percent = 12 },
        .{ .percent = 64 },
        .{ .percent = 30 },
    }) orelse return error.TestUnexpectedResult;

    // The label carries what would stop the next request, the ring the month.
    try std.testing.expectEqual(@as(f64, 64), reading.label);
    try std.testing.expectEqual(@as(f64, 30), reading.ring);
    try std.testing.expect(!reading.spent);

    // Any window at its limit is spent, not the month alone: the rolling window is
    // the one that cuts the next request off, and the label goes with it.
    const spent = items_usage.face(.{
        .{ .percent = 100 },
        .{ .percent = 5 },
        .{ .percent = 9 },
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(spent.spent);
    try std.testing.expectEqual(@as(f64, 9), spent.ring);

    // The month at its limit is spent too, and it is that flag - not the ring's own
    // bracket, which stops at ninety-nine - that reddens the ring.
    const monthly_spent = items_usage.face(.{
        .{ .percent = 0 },
        .{ .percent = 0 },
        .{ .percent = 100 },
    }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(monthly_spent.spent);
    try std.testing.expectEqual(theme.red, items_usage.ringColor(monthly_spent.spent, monthly_spent.ring));

    // A window the endpoint reports without a number is not an unspent one: there
    // is nothing to draw, so nothing is drawn.
    try std.testing.expect(items_usage.face(.{
        .{ .percent = 1 },
        .{},
        .{ .percent = 2 },
    }) == null);
}

test "the Go ring's colour: the month's brackets, and red once anything is spent" {
    const cases = [_]struct { monthly: f64, color: theme.Color }{
        .{ .monthly = 0, .color = theme.green },
        .{ .monthly = 49, .color = theme.green },
        .{ .monthly = 50, .color = theme.yellow },
        .{ .monthly = 79, .color = theme.yellow },
        .{ .monthly = 80, .color = theme.orange },
        .{ .monthly = 99, .color = theme.orange },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.color, items_usage.ringColor(false, case.monthly));
    }

    // Red is the spent state rather than a bracket, and it is spent that says so -
    // any window at its limit, whatever the month reads, since the window that is
    // spent is the one the next request is up against.
    try std.testing.expectEqual(theme.red, items_usage.ringColor(true, 0));
    try std.testing.expectEqual(theme.red, items_usage.ringColor(true, 30));
    try std.testing.expectEqual(theme.red, items_usage.ringColor(true, 99));
}

test "a spent Go reading drops the label and reddens the ringed mark" {
    var props: Props = .{};
    try items_usage.lineProps(&props, "opencode-go", .{
        .label = "100%",
        .mark_color = theme.red,
        .label_drawn = false,
        .ring = .{ .share = 1, .color = theme.red },
    });

    const expected = [_][]const u8{
        "drawing=on",
        "label=100%",
        // The mark is the glyph the ring draws, so its colour is the marker's and
        // not the item's own icon - which is why an icon on this item is cleared.
        "ring.marker.color=0xfffa4934",
        "label.drawing=off",
        "ring.value=1.0000",
        "ring.color=0xfffa4934",
    };
    try std.testing.expectEqual(expected.len, props.slice().len);
    for (expected, props.slice()) |want, got| try std.testing.expectEqualStrings(want, got);

    // A provider with room keeps its label, and a provider with no ring never
    // touches either property: its mark is its icon.
    var plain: Props = .{};
    try items_usage.lineProps(&plain, "neuralwatt", .{ .label = "$12.00", .mark_color = theme.green });
    const plain_expected = [_][]const u8{ "drawing=on", "label=$12.00", "icon.color=0xffb8bb27" };
    try std.testing.expectEqual(plain_expected.len, plain.slice().len);
    for (plain_expected, plain.slice()) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a provider item is drawn only while its token is in the store" {
    const io = std.testing.io;
    const path = "/tmp/kxdesk-tests-usage.db";
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    defer {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        std.Io.Dir.deleteFileAbsolute(io, path ++ "-wal") catch {};
        std.Io.Dir.deleteFileAbsolute(io, path ++ "-shm") catch {};
    }

    var db = store.Store.open(io, path);
    defer db.close();

    // No token: every provider is off the bar, and every other item - which this
    // is not about - is not.
    try std.testing.expect(!items_usage.configured(io, &db, "neuralwatt"));
    try std.testing.expect(!items_usage.configured(io, &db, "openrouter"));
    try std.testing.expect(!items_usage.configured(io, &db, "opencode-go"));
    try std.testing.expect(items_usage.configured(io, &db, "brew"));
    try std.testing.expect(items_usage.configured(io, &db, "opencode-go.rolling"));

    // A token, and only that provider's item is drawn. Whitespace is not a token:
    // an empty `state set` is a key that was cleared, not one that was given.
    try db.setText(io, "opencode-go.token", "sk-test");
    try std.testing.expect(items_usage.configured(io, &db, "opencode-go"));
    try std.testing.expect(!items_usage.configured(io, &db, "neuralwatt"));

    try db.setText(io, "neuralwatt.token", "  \t ");
    try std.testing.expect(!items_usage.configured(io, &db, "neuralwatt"));
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

test "kanata names parse into the actions they spell" {
    // One case per shape the vocabulary uses: a direction, a number, one of a
    // few words, a flag that is only there when it is spelled, and a verb with
    // nothing after it.
    try std.testing.expectEqual(
        kanata.Action{ .window_swap = .west },
        try kanata.parseAction("yabai:window-swap:west"),
    );
    try std.testing.expectEqual(
        kanata.Action{ .window_to_display = 3 },
        try kanata.parseAction("yabai:window-to-display:3"),
    );
    try std.testing.expectEqual(
        kanata.Action{ .space_layout = .float },
        try kanata.parseAction("yabai:space-layout:float"),
    );
    try std.testing.expectEqual(
        kanata.Action{ .window_focus = .same_app },
        try kanata.parseAction("yabai:window-focus:same-app"),
    );
    try std.testing.expectEqual(
        kanata.Action{ .window_toggle = .float_sticky_topmost },
        try kanata.parseAction("yabai:window-toggle:float-sticky-topmost"),
    );
    try std.testing.expectEqual(
        kanata.Action{ .cycle_displays = .reverse },
        try kanata.parseAction("kxdesk:cycle-displays:reverse"),
    );
    // The bindings that run forwards spell nothing, which is the whole reason
    // `reverse` is the word that is written and not the other one.
    try std.testing.expectEqual(
        kanata.Action{ .cycle_displays = .forward },
        try kanata.parseAction("kxdesk:cycle-displays"),
    );
    try std.testing.expectEqual(
        kanata.Action{ .open_app = .arc_debug },
        try kanata.parseAction("app:open:arc-debug"),
    );
    try std.testing.expectEqual(
        kanata.Action.dump_path,
        try kanata.parseAction("debug:dump-path"),
    );
}

test "kanata refuses a name it cannot carry out" {
    // A mistyped binding is a key that does nothing, so the channel refuses the
    // name and says why rather than passing it to yabai to refuse in its own
    // words. Each case names the error that reason is.
    const refused = [_]struct { name: []const u8, expected: kanata.ParseError }{
        // The argument the verb needs, missing or not one it knows.
        .{ .name = "yabai:window-swap", .expected = error.MissingArgument },
        .{ .name = "yabai:window-swap:sideways", .expected = error.BadArgument },
        .{ .name = "yabai:window-swap:west:now", .expected = error.UnknownAction },
        .{ .name = "yabai:window-to-display:two", .expected = error.BadArgument },
        .{ .name = "yabai:space-rotate:sideways", .expected = error.BadArgument },
        .{ .name = "yabai:space-toggle:show-dock", .expected = error.BadArgument },
        .{ .name = "kxdesk:cycle-displays:backwards", .expected = error.BadArgument },
        .{ .name = "app:open", .expected = error.MissingArgument },
        // A verb that takes nothing, given something.
        .{ .name = "screen:capture:now", .expected = error.BadArgument },
        .{ .name = "debug:dump-path:now", .expected = error.BadArgument },
        // Names that are not verbs at all: a flat name from before the
        // vocabulary was structured, an unknown namespace, and the empty string.
        .{ .name = "yabai:window-swap-west", .expected = error.UnknownAction },
        .{ .name = "yabai:window-insert-stack-space:west", .expected = error.BadArgument },
        .{ .name = "windows:swap:west", .expected = error.UnknownAction },
        .{ .name = "yabai", .expected = error.UnknownAction },
        .{ .name = "", .expected = error.UnknownAction },
    };
    for (refused) |case| {
        try std.testing.expectError(case.expected, kanata.parseAction(case.name));
    }

    // The display bound is the one argument with a range, because the bindings
    // spell 1 to 4 and a fifth would be a config that meant something else.
    try std.testing.expectEqual(
        kanata.Action{ .display_focus = 4 },
        try kanata.parseAction("yabai:display-focus:4"),
    );
    try std.testing.expectError(error.BadArgument, kanata.parseAction("yabai:display-focus:5"));
    try std.testing.expectError(error.BadArgument, kanata.parseAction("yabai:display-focus:0"));
}

test "a pushed message is read in the shape kanata sends, and in the documented one" {
    // `push-msg` arrives as a JSON array - kanata converts the action's
    // arguments with `simple_sexpr_to_json_array`, so a config cannot produce
    // the bare string its protocol documents - and a name that is not one name
    // is refused, since what is pushed is a name and not a command.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = [_]struct { payload: []const u8, name: ?[]const u8 }{
        .{ .payload = "[\"debug:dump-path\"]", .name = "debug:dump-path" },
        .{ .payload = "\"debug:dump-path\"", .name = "debug:dump-path" },
        .{ .payload = "[\"yabai:window-swap:west\"]", .name = "yabai:window-swap:west" },
        .{ .payload = "[\"a\",\"b\"]", .name = null },
        .{ .payload = "[[\"a\"]]", .name = null },
        .{ .payload = "[]", .name = null },
        .{ .payload = "7", .name = null },
    };

    for (cases) |case| {
        const message = try std.json.parseFromSliceLeaky(std.json.Value, arena, case.payload, .{});
        if (case.name) |name| {
            try std.testing.expectEqualStrings(name, try kanata.pushedName(message));
        } else {
            try std.testing.expectError(error.InvalidMessage, kanata.pushedName(message));
        }
    }
}

test "kanata framing keeps messages apart across read boundaries" {
    var framer = kanata.Framer{};

    // A socket has no idea where a message ends: one line can arrive in two
    // reads, and two lines in one. This is both, in order.
    framer.feed("{\"MessagePush\":{\"mess");
    try std.testing.expect(framer.next() == null);
    framer.feed("age\":[\"debug:dump-path\"]}}\n{\"LayerChange\":{\"new\":\"op\"}}\n");

    try std.testing.expectEqualStrings(
        "{\"MessagePush\":{\"message\":[\"debug:dump-path\"]}}",
        framer.next().?,
    );
    try std.testing.expectEqualStrings("{\"LayerChange\":{\"new\":\"op\"}}", framer.next().?);
    try std.testing.expect(framer.next() == null);

    // A read that ends exactly on the newline is the same as one that carries
    // the start of the next message.
    framer.feed("{\"a\":1}\n");
    try std.testing.expectEqualStrings("{\"a\":1}", framer.next().?);
    try std.testing.expect(framer.next() == null);
}

test "kanata framing drops a line that outgrows its buffer" {
    // Half a message is not a message. The overlong line is dropped whole - and
    // so is the fragment of it that was already buffered, or everything after it
    // would be glued onto that fragment and lost with it.
    var framer = kanata.Framer{};
    var long: [5000]u8 = undefined;
    @memset(long[0..4999], 'x');
    long[4999] = '\n';

    framer.feed(&long);
    framer.feed("{\"LayerChange\":{\"new\":\"op\"}}\n");
    try std.testing.expectEqualStrings("{\"LayerChange\":{\"new\":\"op\"}}", framer.next().?);
    try std.testing.expect(framer.next() == null);

    // The same when the newline that ends the long line arrives in a later read
    // than the line itself.
    var framer_again = kanata.Framer{};
    var head: [4500]u8 = undefined;
    @memset(&head, 'y');
    framer_again.feed(&head);
    try std.testing.expect(framer_again.next() == null);
    framer_again.feed("tail\n{\"a\":1}\n");
    try std.testing.expectEqualStrings("{\"a\":1}", framer_again.next().?);
    try std.testing.expect(framer_again.next() == null);
}

test "the mode indicator follows the layer kanata reports" {
    // The indices are the ones the skhd config passed to `set_mode_indicator` on
    // entering each mode; the layer names are the ones kanata.kbd defines.
    try std.testing.expectEqualStrings("1", kanata.indicatorFor("op").?);
    try std.testing.expectEqualStrings("2", kanata.indicatorFor("wmode").?);
    try std.testing.expectEqualStrings("3", kanata.indicatorFor("smode").?);
    try std.testing.expectEqualStrings("-", kanata.indicatorFor("default").?);

    // A layer nobody colours is not an error: the config may define layers of
    // its own, and the highlight simply stays as it was.
    try std.testing.expect(kanata.indicatorFor("nav") == null);
}
