//! Provider usage: what is left on NeuralWatt and on OpenRouter.
//!
//! Both numbers change only when you spend, so they refresh on the brew item's
//! slow cadence and never on the event path. One background task fetches both,
//! through the system's `curl`: a TLS stack is not worth carrying for two URLs
//! every five minutes.
//!
//! The bar shows what is left on each. What was spent in the last day, the last
//! week and the last thirty days is on hover, from NeuralWatt's own usage
//! summary, which takes a window as ISO 8601 and returns the charged cost for
//! it. OpenRouter has no such window to offer a normal key - the account's daily
//! activity is behind a management key, and its per-key daily and weekly fields
//! describe a key that has never been used - so its item shows the balance alone.

const std = @import("std");

const exec = @import("exec.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const state = @import("store.zig");
const theme = @import("theme.zig");

/// The items this refresh owns; `dispatch.zig` routes their events by these
/// names.
pub const neuralwatt_item = "neuralwatt";
pub const openrouter_item = "openrouter";

/// Where a click goes: each provider's own usage page.
pub const neuralwatt_url = "https://portal.neuralwatt.com/dashboard/usage";
pub const openrouter_url = "https://openrouter.ai/activity";

/// Where the tokens are read from, so replacing one takes effect at the next
/// refresh rather than at the next restart. The daemon runs under launchd and
/// never had an environment worth reading.
const neuralwatt_token_key = "neuralwatt.token";
const openrouter_token_key = "openrouter.token";

const neuralwatt_quota_url = "https://api.neuralwatt.com/v1/quota";
const neuralwatt_summary_url = "https://api.neuralwatt.com/v1/usage/summary";
const openrouter_credits_url = "https://openrouter.ai/api/v1/credits";

/// How long one request may take. Both APIs answer in a fraction of a second; a
/// timeout is there so a connection that hangs cannot hold the task open.
const request_timeout_seconds = "20";

const day_seconds: i64 = 24 * 60 * 60;
const week_seconds: i64 = 7 * day_seconds;
const month_seconds: i64 = 30 * day_seconds;

/// How often both providers are refreshed. What is left only changes when you
/// spend, and each cycle is five HTTPS requests.
pub const cadence_seconds: i64 = 300;

/// The shortest gap between two refreshes, so that the receive loop asking
/// twice while the first is still starting does not fetch everything twice.
const floor_seconds: i64 = 60;

/// When the last refresh ran, and so when the next is due. Zero until the first
/// one, which is what makes a daemon that has just started fetch immediately.
var last_refresh: i64 = 0;

/// Whether the schedule says a refresh is due.
pub fn due(io: std.Io) bool {
    return last_refresh == 0 or now(io) - last_refresh >= cadence_seconds;
}

/// Ask for a refresh now, whoever is asking. The `apply` that a bar runs on
/// startup uses this, so a restarted bar does not wait five minutes for numbers
/// whose labels it has just blanked.
pub fn invalidate() void {
    last_refresh = 0;
}

/// How long the receive loop may wait before this needs attention, in
/// milliseconds, following its convention that 0 means "nothing scheduled".
pub fn waitMs(io: std.Io) u32 {
    if (last_refresh == 0) return 1;
    const remaining = cadence_seconds - (now(io) - last_refresh);
    if (remaining <= 0) return 1;
    // Capped at a minute, so a machine that slept through the moment still
    // notices within a minute of waking rather than trusting arithmetic.
    return @intCast(@min(remaining * 1000, 60_000));
}

/// A window the popup reports: the suffix its item name carries, the label it is
/// drawn under, and how far back it reaches.
pub const Row = struct {
    suffix: []const u8,
    label: []const u8,
    seconds: i64,
};

/// Every window the popup reports, shortest first. The bar declares one item per
/// row from this list and the refresh fills each one, so the items that exist and
/// the readings that feed them cannot drift apart. Thirty days is the summary
/// endpoint's own fallback default, which is why it is the longest window worth
/// asking for.
pub const rows = [_]Row{
    .{ .suffix = "day", .label = "24h", .seconds = day_seconds },
    .{ .suffix = "week", .label = "7d", .seconds = week_seconds },
    .{ .suffix = "month", .label = "30d", .seconds = month_seconds },
};

/// The colours the two items carry, so they are told apart at a glance.
const neuralwatt_color = theme.green;
const openrouter_color = theme.aqua;

/// Refresh both balances, and both sets of windows.
pub fn refresh(io: std.Io, gpa: std.mem.Allocator, store: *state.Store) anyerror!void {
    const started_at = now(io);
    if (last_refresh != 0 and started_at - last_refresh < floor_seconds) return;
    last_refresh = started_at;

    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    // Each provider on its own: one token that has expired must not blank the
    // other's number.
    updateNeuralwatt(io, gpa, store, &client) catch |err| {
        std.debug.print("kxdesk: neuralwatt usage: {s}\n", .{@errorName(err)});
        stale(&client, neuralwatt_item) catch {};
    };
    updateOpenrouter(io, gpa, store, &client) catch |err| {
        std.debug.print("kxdesk: openrouter usage: {s}\n", .{@errorName(err)});
        stale(&client, openrouter_item) catch {};
    };
}

/// NeuralWatt: the credit balance from the call that reports balance and usage
/// together, and the windows from its own usage summary.
fn updateNeuralwatt(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *state.Store,
    client: *sb.Client,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = try readToken(io, arena, store, neuralwatt_token_key);
    const when = now(io);

    const Quota = struct {
        balance: struct {
            credits_remaining_usd: f64 = 0,
        } = .{},
    };
    const body = try fetch(io, arena, neuralwatt_quota_url, token);
    const quota = std.json.parseFromSliceLeaky(Quota, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.UnreadableResponse;

    var spent: [rows.len]f64 = undefined;
    for (&spent, rows) |*reading, row| {
        reading.* = try summaryWindow(io, arena, token, row.seconds, when);
    }

    try publish(client, neuralwatt_item, neuralwatt_color, quota.balance.credits_remaining_usd, &spent);
}

/// OpenRouter: the credit balance from its totals, and nothing to hover: it has
/// no window endpoint to offer a normal key. See the note at the top of the file.
fn updateOpenrouter(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *state.Store,
    client: *sb.Client,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = try readToken(io, arena, store, openrouter_token_key);

    const Credits = struct {
        data: struct {
            total_credits: f64 = 0,
            total_usage: f64 = 0,
        } = .{},
    };
    const body = try fetch(io, arena, openrouter_credits_url, token);
    const credits = std.json.parseFromSliceLeaky(Credits, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.UnreadableResponse;

    const remaining = credits.data.total_credits - credits.data.total_usage;
    try publish(client, openrouter_item, openrouter_color, remaining, null);
}

/// What one window of NeuralWatt's own usage summary cost.
fn summaryWindow(
    io: std.Io,
    arena: std.mem.Allocator,
    token: []const u8,
    seconds: i64,
    when: i64,
) !f64 {
    var start_buffer: [32]u8 = undefined;
    var end_buffer: [32]u8 = undefined;
    var url_buffer: [512]u8 = undefined;
    const start = try isoUtc(&start_buffer, when - seconds);
    const end = try isoUtc(&end_buffer, when);
    const url = try std.fmt.bufPrint(&url_buffer, "{s}?start_date={s}&end_date={s}", .{
        neuralwatt_summary_url, start, end,
    });

    const Summary = struct {
        period: struct {
            start: []const u8 = "",
        } = .{},
        totals: struct {
            total_cost_usd: f64 = 0,
        } = .{},
    };
    const body = try fetch(io, arena, url, token);
    const summary = std.json.parseFromSliceLeaky(Summary, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.UnreadableResponse;

    // These endpoints fall back to their thirty-day default for a window they
    // cannot parse, and they do it silently. A period that is not the one asked
    // for is therefore a wrong answer rather than a missing one.
    if (!std.mem.startsWith(u8, summary.period.start, start[0..19])) return error.WindowNotHonoured;

    return summary.totals.total_cost_usd;
}

/// Show what is left on the bar, and the windows in the popup.
///
/// `readings` is one cost per entry in `rows`, or null for a provider that has
/// no windows to report.
fn publish(
    client: *sb.Client,
    item: []const u8,
    color: theme.Color,
    remaining: f64,
    readings: ?[]const f64,
) !void {
    var money_buffer: [32]u8 = undefined;
    var props: Props = .{};
    try props.fmt("label={s}", .{try money(&money_buffer, remaining)});
    try props.color("icon.color", color);
    try client.set(item, props.slice());

    // A provider without windows has no rows to write: OpenRouter's popup is
    // empty by nature, so it has none.
    const spent = readings orelse {
        try client.commit();
        return;
    };
    std.debug.assert(spent.len == rows.len);

    for (spent, rows) |amount, row| {
        var name_buffer: [48]u8 = undefined;
        var label_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}.{s}", .{ item, row.suffix });

        var row_props: Props = .{};
        try row_props.fmt("label={s}", .{try windowLabel(&label_buffer, row, amount)});
        try client.set(name, row_props.slice());
    }

    try client.commit();
}

/// A refresh that failed leaves the last number where it was - it is still the
/// last thing the provider said - and dims the icon, so a reading that has
/// stopped being refreshed cannot pass for a fresh one.
fn stale(client: *sb.Client, item: []const u8) !void {
    var props: Props = .{};
    try props.color("icon.color", theme.dark_grey);
    try client.set(item, props.slice());
    try client.commit();
}

/// What a popup row says: the window it covers, and what was spent across it.
fn windowLabel(buffer: []u8, row: Row, spent_usd: f64) ![]const u8 {
    var money_buffer: [32]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ row.label, try money(&money_buffer, spent_usd) });
}

/// Cents for a balance, and a third decimal for the sums a single day of
/// requests adds up to.
fn money(buffer: []u8, amount: f64) ![]const u8 {
    if (amount < 1) return std.fmt.bufPrint(buffer, "${d:.3}", .{amount});
    return std.fmt.bufPrint(buffer, "${d:.2}", .{amount});
}

/// The token to authenticate with, from the store.
///
/// An unset token is a key that has not been given yet, which the item says out
/// loud rather than showing a zero it did not earn.
fn readToken(io: std.Io, arena: std.mem.Allocator, store: *state.Store, key: []const u8) ![]const u8 {
    const value = (store.getTextAlloc(io, arena, key) catch null) orelse return error.NoToken;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return error.NoToken;
    return trimmed;
}

/// One HTTPS GET, through the system's `curl`.
///
/// The response body is owned by the caller's arena.
fn fetch(io: std.Io, arena: std.mem.Allocator, url: []const u8, token: []const u8) ![]const u8 {
    const curl = try exec.path(arena, "curl");

    var header_buffer: [512]u8 = undefined;
    const authorization = try std.fmt.bufPrint(&header_buffer, "Authorization: Bearer {s}", .{token});

    const result = std.process.run(arena, io, .{
        .argv = &.{
            curl,
            // A 4xx is an answer rather than a silence, and its body says which.
            "--silent",
            "--show-error",
            "--fail-with-body",
            "--max-time",
            request_timeout_seconds,
            "--header",
            authorization,
            url,
        },
    }) catch return error.RequestFailed;

    const succeeded = switch (result.term) {
        .exited => |status| status == 0,
        else => false,
    };
    if (!succeeded) {
        // Whatever the provider said, in one line: the alternative is a number
        // that quietly stops moving.
        reportRefusal(url, std.mem.trim(u8, result.stdout, " \r\n"));
        return error.RequestRefused;
    }

    clearRefusal();
    return result.stdout;
}

/// The last refusal reported. A token that is wrong, or a plan that has run out,
/// would otherwise put the same line in the agent's log every five minutes for
/// as long as it lasts.
var last_refusal: [160]u8 = @splat(0);
var last_refusal_len: usize = 0;

fn reportRefusal(url: []const u8, detail: []const u8) void {
    const shown = if (detail.len > last_refusal.len) detail[0..last_refusal.len] else detail;
    if (std.mem.eql(u8, shown, last_refusal[0..last_refusal_len])) return;

    @memcpy(last_refusal[0..shown.len], shown);
    last_refusal_len = shown.len;
    std.debug.print("kxdesk: {s} refused the request: {s}\n", .{ url, shown });
}

/// An answer that arrived is worth saying so, since the next refusal should be
/// reported even if it is the same one as before.
fn clearRefusal() void {
    last_refusal_len = 0;
}

/// Seconds since the epoch.
fn now(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

/// An instant as the ISO 8601 both usage windows are spelled in.
fn isoUtc(buffer: []u8, seconds: i64) ![]const u8 {
    const stamp = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const time = stamp.getDaySeconds();
    const year_day = stamp.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}
