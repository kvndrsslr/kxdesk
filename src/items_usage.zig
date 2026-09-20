//! Provider usage: what is left on NeuralWatt and on OpenRouter, and how much of
//! the OpenCode Go subscription is spent.
//!
//! These numbers change only when you spend, so they refresh on the brew item's
//! slow cadence and never on the event path. One background task fetches all
//! three, through the system's `curl`: a TLS stack is not worth carrying for six
//! URLs every five minutes.
//!
//! A provider whose token is not in the store is not drawn at all: there is
//! nothing to fetch and nothing to say, so its item is taken off the bar rather
//! than left holding a placeholder - and setting the token puts it back at the next
//! refresh.
//!
//! The bar shows what is left on each balance, and the share of the tightest of
//! the Go plan's windows. What was spent in the last day, the last week and the
//! last thirty days is on hover, from NeuralWatt's own usage summary, which takes
//! a window as ISO 8601 and returns the charged cost for it; the same hover on the
//! Go item shows its three windows, each against its own limit. OpenRouter has no
//! such window to offer a normal key - the account's daily activity is behind a
//! management key, and its per-key daily and weekly fields describe a key that has
//! never been used - so its item shows the balance alone.

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
pub const opencode_item = "opencode-go";

/// Where a click goes: each provider's own usage page.
pub const neuralwatt_url = "https://portal.neuralwatt.com/dashboard/usage";
pub const openrouter_url = "https://openrouter.ai/activity";
/// The console rather than the plan's own page: the console is where the three
/// windows are drawn, and the plan page is only what they are bought against.
pub const opencode_url = "https://opencode.ai/auth";

/// Where the tokens are read from, so replacing one takes effect at the next
/// refresh rather than at the next restart. The daemon runs under launchd and
/// never had an environment worth reading.
const neuralwatt_token_key = "neuralwatt.token";
const openrouter_token_key = "openrouter.token";
/// The key the Go subscription hands out, which is not the Zen one: only this
/// key is answered by the usage endpoint below.
const opencode_token_key = "opencode-go.token";

const neuralwatt_quota_url = "https://api.neuralwatt.com/v1/quota";
const neuralwatt_summary_url = "https://api.neuralwatt.com/v1/usage/summary";
const openrouter_credits_url = "https://openrouter.ai/api/v1/credits";
/// The endpoint the OpenCode console itself reads its Go meters from, so the
/// number here is the console's own accounting rather than a client-side
/// estimate. It answers `{usage: {rolling, weekly, monthly}}`, each window a
/// share of its own limit and the instant it resets.
const opencode_usage_url = "https://opencode.ai/zen/go/v1/usage";

/// How long one request may take. Both APIs answer in a fraction of a second; a
/// timeout is there so a connection that hangs cannot hold the task open.
const request_timeout_seconds = "20";

const day_seconds: i64 = 24 * 60 * 60;
const week_seconds: i64 = 7 * day_seconds;
const month_seconds: i64 = 30 * day_seconds;

/// How often the providers are refreshed. What is left only changes when you
/// spend, and each cycle is six HTTPS requests.
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

/// A window a popup reports: the suffix its item name carries, the label it is
/// drawn under, and - for a provider asked by date range - how far back it
/// reaches.
pub const Row = struct {
    suffix: []const u8,
    label: []const u8,
    /// The window's own length, for a provider that has to name the range in its
    /// request. Left at zero for one whose endpoint reports its own windows, where
    /// the suffix is that field's name instead.
    seconds: i64 = 0,
};

/// NeuralWatt's windows, shortest first. The bar declares one item per row from
/// this list and the refresh fills each one, so the items that exist and the
/// readings that feed them cannot drift apart. Thirty days is the summary
/// endpoint's own fallback default, which is why it is the longest window worth
/// asking for.
pub const neuralwatt_rows = [_]Row{
    .{ .suffix = "day", .label = "24h", .seconds = day_seconds },
    .{ .suffix = "week", .label = "7d", .seconds = week_seconds },
    .{ .suffix = "month", .label = "30d", .seconds = month_seconds },
};

/// OpenCode Go's windows, in the order the endpoint reports them: five rolling
/// hours, the week and the billing month, each a share of that window's own
/// limit. The suffix is the field's name in the response and the label is the
/// console's word for it, so a row and the number it shows are one word apart.
pub const opencode_rows = [_]Row{
    .{ .suffix = "rolling", .label = "5h" },
    .{ .suffix = "weekly", .label = "week" },
    .{ .suffix = "monthly", .label = "month" },
};

/// One provider's bar item: its name, where a click goes, the colour its icon and
/// its popup rows carry, and the windows its popup shows.
pub const Provider = struct {
    item: []const u8,
    url: []const u8,
    /// The store key the token is read from. An item whose key holds nothing is
    /// not drawn: there is nothing to fetch and nothing to say.
    token_key: []const u8,
    color: theme.Color,
    /// Empty for a provider with no windows to report - which is also the item a
    /// hover has nothing to show for.
    rows: []const Row,
    /// Whether the item carries a ring. Its mark is then ringed - the glyph the
    /// ring draws inside it rather than the item's own icon - so the mark's colour
    /// belongs to the ring's marker, and there is an icon to keep clear.
    ringed: bool = false,
};

/// Every provider item, in the order the bar draws them and the refresh fills
/// them. One entry per item, so a click, a hover and the rows under it are all
/// read off this table rather than matched by name in three files.
pub const providers = [_]Provider{
    .{
        .item = neuralwatt_item,
        .url = neuralwatt_url,
        .token_key = neuralwatt_token_key,
        .color = neuralwatt_color,
        .rows = &neuralwatt_rows,
    },
    .{
        .item = openrouter_item,
        .url = openrouter_url,
        .token_key = openrouter_token_key,
        .color = openrouter_color,
        .rows = &.{},
    },
    .{
        .item = opencode_item,
        .url = opencode_url,
        .token_key = opencode_token_key,
        .color = opencode_color,
        .rows = &opencode_rows,
        .ringed = true,
    },
};

/// The provider a bar item stands for, or null for any other item: what a click
/// opens, and whether a hover has a popup to show.
pub fn providerFor(item: []const u8) ?*const Provider {
    for (&providers) |*provider| {
        if (std.mem.eql(u8, provider.item, item)) return provider;
    }
    return null;
}

/// The colours the three items carry, so they are told apart at a glance.
const neuralwatt_color = theme.green;
const openrouter_color = theme.aqua;
const opencode_color = theme.orange;

/// Refresh every provider: both balances, and the Go plan's windows.
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
    updateOpencode(io, gpa, store, &client) catch |err| {
        std.debug.print("kxdesk: opencode-go usage: {s}\n", .{@errorName(err)});
        stale(&client, opencode_item) catch {};
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

    var token_buffer: [token_bytes]u8 = undefined;
    const token = readToken(io, &token_buffer, store, neuralwatt_token_key) orelse
        return hide(client, neuralwatt_item);
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

    var text_buffers: [neuralwatt_rows.len][48]u8 = undefined;
    var texts: [neuralwatt_rows.len][]const u8 = undefined;
    for (neuralwatt_rows, &text_buffers, &texts) |row, *buffer, *text| {
        const spent = try summaryWindow(io, arena, token, row.seconds, when);
        text.* = try windowLabel(buffer, row, spent);
    }

    var money_buffer: [32]u8 = undefined;
    try publish(client, neuralwatt_item, .{
        .label = try money(&money_buffer, quota.balance.credits_remaining_usd),
        .mark_color = neuralwatt_color,
    }, &neuralwatt_rows, &texts);
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

    var token_buffer: [token_bytes]u8 = undefined;
    const token = readToken(io, &token_buffer, store, openrouter_token_key) orelse
        return hide(client, openrouter_item);

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
    var money_buffer: [32]u8 = undefined;
    try publish(client, openrouter_item, .{
        .label = try money(&money_buffer, remaining),
        .mark_color = openrouter_color,
    }, &.{}, null);
}

/// OpenCode Go: three shares of three limits, and no balance - the plan is a cap,
/// and what its endpoint reports is how much of it is gone.
///
/// The label carries the highest of the three, since that is the window that would
/// stop the next request, and the ring around the mark carries the month's own
/// share, which is what says how much of the plan is left. The hover names each
/// window, and the moment any of them is spent the ring and the mark go red and the
/// label goes away - there is no number left to give.
fn updateOpencode(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *state.Store,
    client: *sb.Client,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var token_buffer: [token_bytes]u8 = undefined;
    const token = readToken(io, &token_buffer, store, opencode_token_key) orelse
        return hide(client, opencode_item);
    const when = now(io);

    const Usage = struct {
        usage: struct {
            rolling: Window = .{},
            weekly: Window = .{},
            monthly: Window = .{},
        } = .{},
    };
    const body = try fetch(io, arena, opencode_usage_url, token);
    const parsed = std.json.parseFromSliceLeaky(Usage, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return error.UnreadableResponse;

    // In `opencode_rows` order, which is the order the endpoint reports them in.
    const windows = [_]Window{ parsed.usage.rolling, parsed.usage.weekly, parsed.usage.monthly };
    const reading = face(windows) orelse return error.UnreadableResponse;

    var text_buffers: [opencode_rows.len][64]u8 = undefined;
    var texts: [opencode_rows.len][]const u8 = undefined;
    for (windows, opencode_rows, &text_buffers, &texts) |window, row, *buffer, *text| {
        const share = window.percent orelse return error.UnreadableResponse;
        text.* = try opencodeRow(buffer, row, share, window.resetsAt, when);
    }

    var percent_buffer: [32]u8 = undefined;
    try publish(client, opencode_item, .{
        .label = try percentText(&percent_buffer, reading.label),
        // A window at its limit is what the mark and its ring say, since it is the
        // state the next request runs into; the identity colour is for a plan with
        // room.
        .mark_color = if (reading.spent) theme.red else opencode_color,
        .label_drawn = !reading.spent,
        .ring = .{
            .share = reading.ring / 100,
            .color = ringColor(reading.spent, reading.ring),
        },
    }, &opencode_rows, &texts);
}

/// What the Go item says on its own line, read off its three windows.
pub const Face = struct {
    /// The tightest window's share, which is the number under the icon.
    label: f64,
    /// The month's share, which is what the ring is filled to.
    ring: f64,
    /// Whether any window is at its limit. That drops the label - the ring is
    /// still worth reading, and the number would only repeat it - and reddens the
    /// icon, since what has run out is what stops the next request.
    spent: bool,
};

/// Read the three windows - in `opencode_rows` order - into the item's own line.
///
/// Null for a window the endpoint reported without a number: that is a response
/// that cannot be shown, because zero spent and nothing said are not the same
/// answer.
pub fn face(windows: [opencode_rows.len]Window) ?Face {
    var tightest: f64 = 0;
    var monthly: f64 = 0;
    var spent = false;

    for (windows, 0..) |window, index| {
        const share = window.percent orelse return null;
        tightest = @max(tightest, share);
        spent = spent or share >= full_percent;
        // The month is the last of the three, and the window the ring carries.
        if (index == windows.len - 1) monthly = share;
    }

    return .{ .label = tightest, .ring = monthly, .spent = spent };
}

/// The ring's colour: the red of a plan that is spent, and otherwise the month's
/// own bracket - green while half the month is left, yellow to four fifths,
/// orange past that. The month at its limit is spent too, so the top bracket is
/// the eighty-to-ninety-nine range the red does not cover.
pub fn ringColor(spent: bool, monthly: f64) theme.Color {
    if (spent) return theme.red;
    if (monthly < 50) return theme.green;
    if (monthly < 80) return theme.yellow;
    return theme.orange;
}

/// A share at its limit: the point a window is spent, and the point the month is
/// at the top of the ring's brackets.
const full_percent: f64 = 100;

/// One window of the Go plan's usage: the share of it that is spent, and when it
/// resets. `percent` is null rather than zero when the endpoint names a window
/// without a number: a window it says nothing about is not an unspent one.
pub const Window = struct {
    percent: ?f64 = null,
    resetsAt: ?[]const u8 = null,
};

/// What one Go popup row says: the window, the share of it that is spent, and -
/// when the endpoint's instant can be read - how long is left of it.
pub fn opencodeRow(
    buffer: []u8,
    row: Row,
    percent: f64,
    resets_at: ?[]const u8,
    when: i64,
) ![]const u8 {
    var percent_buffer: [32]u8 = undefined;
    const spent = try percentText(&percent_buffer, percent);

    const reset = if (resets_at) |stamp| parseInstant(stamp) else null;
    const instant = reset orelse return std.fmt.bufPrint(buffer, "{s} {s}", .{ row.label, spent });

    var countdown_buffer: [24]u8 = undefined;
    const left = try countdown(&countdown_buffer, instant - when);
    return std.fmt.bufPrint(buffer, "{s} {s} · resets in {s}", .{ row.label, spent, left });
}

/// A share of a limit, as the endpoint reports it: whole percents, with a decimal
/// only if it ever sends one.
fn percentText(buffer: []u8, percent: f64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}%", .{percent});
}

/// How long is left of a window, in the two coarsest units that describe it: days
/// and hours, hours and minutes, or minutes alone. Rounded up, so a window that
/// closes in seconds reads as a minute rather than as nothing, and never
/// negative, since an instant in the past is a window that has already reset.
fn countdown(buffer: []u8, seconds: i64) ![]const u8 {
    const minutes = @divTrunc(@max(0, seconds) + 59, 60);
    if (minutes < 60) return std.fmt.bufPrint(buffer, "{d}m", .{minutes});

    const hours = @divTrunc(minutes, 60);
    if (hours < 24) return std.fmt.bufPrint(buffer, "{d}h {d}m", .{ hours, minutes % 60 });

    return std.fmt.bufPrint(buffer, "{d}d {d}h", .{ @divTrunc(hours, 24), hours % 24 });
}

/// The instant an endpoint spells in ISO 8601, as seconds since the epoch.
///
/// This reads the shape the Go endpoint sends - `YYYY-MM-DDTHH:MM:SS`, optional
/// fractional seconds, and a `Z` or a `±HH:MM` offset - and nothing else. An
/// instant without a zone is not read as UTC: a countdown that is hours out is
/// worse than no countdown, and the row says its share without one instead.
fn parseInstant(stamp: []const u8) ?i64 {
    if (stamp.len < 19) return null;
    if (stamp[4] != '-' or stamp[7] != '-' or stamp[10] != 'T' or
        stamp[13] != ':' or stamp[16] != ':') return null;

    const year = digits(stamp[0..4]) orelse return null;
    const month = digits(stamp[5..7]) orelse return null;
    const day = digits(stamp[8..10]) orelse return null;
    const hour = digits(stamp[11..13]) orelse return null;
    const minute = digits(stamp[14..16]) orelse return null;
    const second = digits(stamp[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    var rest = stamp[19..];
    if (rest.len > 0 and rest[0] == '.') {
        const fraction = std.mem.indexOfNone(u8, rest[1..], "0123456789") orelse return null;
        rest = rest[1 + fraction ..];
    }

    var offset: i64 = 0;
    if (std.mem.eql(u8, rest, "Z")) {
        // UTC: the offset this already starts from.
    } else if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const offset_hour = digits(rest[1..3]) orelse return null;
        const offset_minute = digits(rest[4..6]) orelse return null;
        if (offset_hour > 23 or offset_minute > 59) return null;
        offset = offset_hour * std.time.s_per_hour + offset_minute * std.time.s_per_min;
        if (rest[0] == '-') offset = -offset;
    } else {
        return null;
    }

    const days = daysFromCivil(year, month, day);
    return days * std.time.s_per_day + hour * std.time.s_per_hour +
        minute * std.time.s_per_min + second - offset;
}

/// How many ASCII digits spell, as a number - or null if they spell anything
/// else, which is how a malformed stamp is rejected rather than read as zero.
fn digits(text: []const u8) ?i64 {
    var value: i64 = 0;
    for (text) |character| {
        if (character < '0' or character > '9') return null;
        value = value * 10 + (character - '0');
    }
    return value;
}

/// Days between 1970-01-01 and one civil date, by Howard Hinnant's
/// `days_from_civil`. Leap years fall out of the era arithmetic, so there is no
/// month table - and no February - to get wrong.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const shifted_year = year - @as(i64, @intFromBool(month <= 2));
    const era = @divFloor(shifted_year, 400);
    const year_of_era = shifted_year - era * 400;
    const month_from_march = month + if (month > 2) @as(i64, -3) else @as(i64, 9);
    const day_of_year = @divTrunc(153 * month_from_march + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) -
        @divTrunc(year_of_era, 100) + day_of_year;

    return era * 146097 + day_of_era - 719468;
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

/// What one provider's item says on its own line: the label under its mark, the
/// colour of that mark, and - for the one provider whose item carries one - the
/// ring around it.
const Reading = struct {
    label: []const u8,
    /// The colour of the provider's mark: its icon glyph, or the glyph inside a
    /// ringed mark's ring. Red once nothing is left, dimmed by a failed refresh.
    mark_color: theme.Color,
    /// Whether the label is drawn at all. Only a ringed item ever hides it, so
    /// only that one states it: the other two have nothing else to say what is
    /// left.
    label_drawn: bool = true,
    /// Absent for a provider with no ring.
    ring: ?Ring = null,
};

/// The ring around a mark: the share of it that is filled, and its colour.
const Ring = struct {
    share: f64,
    color: theme.Color,
};

/// Where a provider item's mark is drawn: on the item's own icon, or, for the item
/// whose mark is ringed, on the glyph the ring draws inside it.
fn markKey(item: []const u8) []const u8 {
    const ringed = if (providerFor(item)) |provider| provider.ringed else false;
    return if (ringed) "ring.marker.color" else "icon.color";
}

/// Fill in what one provider's item says on its own line: the label under its
/// mark, the colour of that mark, and - for a mark that is ringed - the ring's
/// share, its colour, and whether the label is drawn at all.
pub fn lineProps(props: *Props, item: []const u8, reading: Reading) !void {
    // A reading puts the item back: a provider whose token went away was taken off
    // the bar, and one whose token has just been set belongs on it.
    props.raw("drawing=on");
    try props.fmt("label={s}", .{reading.label});
    try props.color(markKey(item), reading.mark_color);
    if (reading.ring) |ring| {
        props.raw(if (reading.label_drawn) "label.drawing=on" else "label.drawing=off");
        // Four decimals, since a share the endpoint sends with a decimal is worth
        // a tenth of a percent on the ring rather than a whole one.
        try props.fmt("ring.value={d:.4}", .{ring.share});
        try props.color("ring.color", ring.color);
    }
}

/// Show one provider's reading on the bar, and its windows in the popup.
///
/// `texts` is one text per entry in `rows_list` - what that row says once the
/// item's placeholder is replaced - or null for a provider that has no windows to
/// report and so no rows to write.
fn publish(
    client: *sb.Client,
    item: []const u8,
    reading: Reading,
    rows_list: []const Row,
    texts: ?[]const []const u8,
) !void {
    var props: Props = .{};
    try lineProps(&props, item, reading);
    try client.set(item, props.slice());

    // A provider without windows has no rows to write: OpenRouter's popup is
    // empty by nature, so it has none.
    const readings = texts orelse {
        try client.commit();
        return;
    };
    std.debug.assert(readings.len == rows_list.len);

    for (readings, rows_list) |text, row| {
        var name_buffer: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "{s}.{s}", .{ item, row.suffix });

        var row_props: Props = .{};
        try row_props.fmt("label={s}", .{text});
        try client.set(name, row_props.slice());
    }

    try client.commit();
}

/// Take a provider's item off the bar: its token is not in the store, so there is
/// no reading to show and no request worth making. Nothing else is touched - the
/// label keeps whatever it had, so a token that is set later shows a number the
/// moment the fetch answers instead of a placeholder.
fn hide(client: *sb.Client, item: []const u8) !void {
    var props: Props = .{};
    props.raw("drawing=off");
    try client.set(item, props.slice());
    try client.commit();
}

/// How long a token may be. API keys are a fraction of this; the store copies what
/// fits its caller's buffer, so the only thing a longer one costs is its tail.
const token_bytes = 1024;

/// A refresh that failed leaves the last number where it was - it is still the
/// last thing the provider said - and dims the mark, so a reading that has
/// stopped being refreshed cannot pass for a fresh one.
fn stale(client: *sb.Client, item: []const u8) !void {
    var props: Props = .{};
    // The token is there, so the item belongs on the bar: a provider that is
    // configured but not answering says so by being dim rather than by vanishing.
    props.raw("drawing=on");
    try props.color(markKey(item), theme.dark_grey);
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
fn readToken(io: std.Io, buffer: []u8, store: *state.Store, key: []const u8) ?[]const u8 {
    const value = (store.getText(io, key, buffer) catch null) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

/// Whether a provider's token is in the store, which is what says whether its item
/// belongs on the bar at all: an item with no token has nothing to show, so it is
/// not drawn - and anything that decides what the bar draws, `zen` included, has to
/// ask this rather than assume.
///
/// Every other item answers true: this is only about the providers.
pub fn configured(io: std.Io, store: *state.Store, item: []const u8) bool {
    const provider = providerFor(item) orelse return true;

    var buffer: [token_bytes]u8 = undefined;
    return readToken(io, &buffer, store, provider.token_key) != null;
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
