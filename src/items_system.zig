//! Updaters for the items whose data the daemon reads directly: the battery ring,
//! the calendar, the two graph pairs and the link icon.
//!
//! Each reading is the rate between two reads of a cumulative counter - Mach's
//! tick counters for the load, one `sysctl` for the interfaces' byte counters - so
//! the sample cadence is the window the numbers average over.

const std = @import("std");

const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const theme = @import("theme.zig");

/// The graph items, one point pushed into each per tick: the load pair - CPU and
/// GPU - and the network pair.
pub const cpu_item = "cpu";
pub const gpu_item = "gpu";
pub const net_down_item = "net.down";
pub const net_up_item = "net.up";

/// What the machine is connected through. The graphs cannot say it: a link that
/// is up and carrying nothing draws exactly like one that is down.
pub const link_item = "net.link";

/// The graphs are sampled once a second - shorter and the lines twitch, longer
/// and they lag.
const sample_cadence_ms: i64 = std.time.ms_per_s;

/// The network graphs' scale, in bytes per second: a kilobyte to a gigabyte,
/// six decades each taking a sixth of the height. Traffic spans orders of
/// magnitude, which a linear scale would flatten into a line on the bottom.
const net_floor_bps: f64 = 1_000;
const net_ceiling_bps: f64 = 1_000_000_000;

/// One tick's traffic, per direction, in bytes per second.
const Traffic = struct {
    received: f64,
    sent: f64,
};

/// Where a rate lands on the graph, as the fraction of its height the point
/// fills.
pub fn netLevel(bytes_per_second: f64) f64 {
    // Also what a NaN - a rate that could not be computed - belongs on: the
    // comparison is false for it, as it is for the floor.
    if (!(bytes_per_second > net_floor_bps)) return 0;
    const decades = @log10(net_ceiling_bps / net_floor_bps);
    return @min(@log10(bytes_per_second / net_floor_bps) / decades, 1);
}

/// A rate as the graph's reading shows it, in the decimal units the counters
/// are: three digits at most, one separator, then the unit - `12.3K`, `999M`,
/// `1.00G`. Truncated rather than rounded, so a rate a hair under a unit boundary
/// cannot round up into a digit `style.zig`'s `readout_chars` left no room for.
pub fn formatRate(bytes_per_second: f64, buffer: *[8]u8) ![]const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T" };
    var magnitude: usize = 0;
    var scaled = bytes_per_second;
    while (scaled >= 1_000 and magnitude + 1 < units.len) : (magnitude += 1) {
        scaled /= 1_000;
    }

    // Bytes are whole, so the `B` magnitude takes no separator; above it, two
    // digits after the separator below ten, one below a hundred.
    const decimals: u8 = if (magnitude == 0)
        0
    else if (scaled < 10)
        2
    else if (scaled < 100)
        1
    else
        0;

    const places: f64 = switch (decimals) {
        0 => 1,
        1 => 10,
        else => 100,
    };
    // A rate no link can carry still reads as three digits.
    const reading = @min(@floor(scaled * places) / places, 999);

    return switch (decimals) {
        0 => std.fmt.bufPrint(buffer, "{d:.0}{s}", .{ reading, units[magnitude] }),
        1 => std.fmt.bufPrint(buffer, "{d:.1}{s}", .{ reading, units[magnitude] }),
        else => std.fmt.bufPrint(buffer, "{d:.2}{s}", .{ reading, units[magnitude] }),
    };
}

/// The battery's charge, and its only readout on the bar: a ring whose value is
/// the charge and whose marker is the battery's own level glyph.
pub const ring_item = "battery.ring";

/// The battery, calendar, graph and link readings, over the daemon's bar client.
pub const Updater = struct {
    bar: *sb.Client,
    clock_icon: [64]u8 = undefined,
    clock_label: [64]u8 = undefined,
    /// When the graphs last got a point, zero until they get their first.
    last_sample: i64 = 0,
    /// The links' cumulative byte counters and when they were read; a rate is a
    /// difference between two readings, so both survive the tick.
    net_received: u64 = 0,
    net_sent: u64 = 0,
    net_sampled: i64 = 0,

    /// One updater over the daemon's bar client.
    pub fn init(bar: *sb.Client) Updater {
        return .{ .bar = bar };
    }

    /// Refresh the battery ring from the machine's own charge reading.
    pub fn battery(self: *Updater) !void {
        var percent: i32 = 0;
        var charging = false;
        // A machine without a battery simply has no reading to publish.
        if (!platform.kx_battery(&percent, &charging)) return;

        const icon = if (charging) theme.glyph.battery_charging else switch (percent) {
            90...100 => theme.glyph.battery_full,
            60...89 => theme.glyph.battery_3,
            30...59 => theme.glyph.battery_2,
            10...29 => theme.glyph.battery_1,
            else => theme.glyph.battery_empty,
        };

        // The ring is the battery's whole readout: the charge as its value, the
        // level glyph inside it as the marker. `ring.value` is spelled out because
        // the `.value` collapse is for a key that is the item's own (`label`).
        var ring: Props = .{};
        try ring.write(.{
            .drawing = true,
            .@"ring.value" = @as(f64, @floatFromInt(percent)) / 100.0,
            .ring = .{ .marker = icon },
        });
        try self.bar.set(ring_item, ring.slice());

        try self.bar.commit();
    }

    /// Refresh the clock's icon and label from the wall clock.
    pub fn calendar(self: *Updater) !void {
        platform.kx_clock(
            &self.clock_icon,
            self.clock_icon.len,
            &self.clock_label,
            self.clock_label.len,
        );

        var props: Props = .{};
        try props.write(.{
            .icon = std.mem.sliceTo(&self.clock_icon, 0),
            .label = std.mem.sliceTo(&self.clock_label, 0),
        });
        try self.bar.set("calendar", props.slice());
        try self.bar.commit();
    }

    /// Push one reading per graph series if the sample cadence says one is due,
    /// and report what the receive loop may wait next.
    ///
    /// Readings are taken even with no bar to push them to: a baseline left to
    /// go stale would turn the first point after the bar comes back into an
    /// average over however long it was gone.
    pub fn pollGraphs(self: *Updater, io: std.Io, bar: ?*sb.Client) u32 {
        const sampled = nowMs(io);
        if (self.last_sample != 0) {
            const waiting = sample_cadence_ms - (sampled - self.last_sample);
            if (waiting > 0) return @intCast(waiting);
        }
        self.last_sample = sampled;

        const cpu = platform.kx_cpu_load();
        const gpu = platform.kx_gpu_load();
        const traffic = self.pollTraffic(sampled);

        if (bar) |client| {
            // One batch for every series, so they cannot fall out of step: the
            // graphs share a window only by each getting exactly one point per
            // tick.
            client.push(cpu_item, cpu) catch return @intCast(std.time.ms_per_s);
            client.push(gpu_item, gpu) catch return @intCast(std.time.ms_per_s);
            showLoad(client, cpu, gpu) catch return @intCast(std.time.ms_per_s);
            if (traffic) |rates| {
                client.push(net_down_item, netLevel(rates.received)) catch
                    return @intCast(std.time.ms_per_s);
                client.push(net_up_item, netLevel(rates.sent)) catch
                    return @intCast(std.time.ms_per_s);
                showRates(client, rates) catch return @intCast(std.time.ms_per_s);
            }
            showLink(client) catch return @intCast(std.time.ms_per_s);
            client.commit() catch return @intCast(std.time.ms_per_s);
        }
        return @intCast(std.time.ms_per_s);
    }

    /// The links' traffic since the previous reading, in bytes per second and per
    /// direction - or `null` when there is nothing to report.
    ///
    /// Counters belong to an interface and are gone with it, so a total that went
    /// backwards is a replaced link rather than traffic: it becomes the new
    /// baseline and this tick carries nothing.
    fn pollTraffic(self: *Updater, sampled: i64) ?Traffic {
        var received: u64 = 0;
        var sent: u64 = 0;
        if (!platform.kx_net_bytes(&received, &sent)) return null;

        var rates: ?Traffic = null;
        if (self.net_sampled != 0 and sampled > self.net_sampled and
            received >= self.net_received and sent >= self.net_sent)
        {
            const seconds: f64 =
                @as(f64, @floatFromInt(sampled - self.net_sampled)) / std.time.ms_per_s;
            rates = .{
                .received = @as(f64, @floatFromInt(received - self.net_received)) / seconds,
                .sent = @as(f64, @floatFromInt(sent - self.net_sent)) / seconds,
            };
        }

        self.net_received = received;
        self.net_sent = sent;
        self.net_sampled = sampled;
        return rates;
    }
};

/// Put the two load readings on their graphs, each on its own item's label slot
/// - the slot `style.zig`'s `graphSlot` keeps the pair's readout in.
fn showLoad(client: *sb.Client, cpu: f64, gpu: f64) !void {
    var cpu_text: [8]u8 = undefined;
    var gpu_text: [8]u8 = undefined;

    var cpu_props: Props = .{};
    try cpu_props.write(.{ .label = .{ .badge = try loadPercentText(cpu, &cpu_text) } });
    try client.set(cpu_item, cpu_props.slice());

    var gpu_props: Props = .{};
    try gpu_props.write(.{ .label = .{ .badge = try loadPercentText(gpu, &gpu_text) } });
    try client.set(gpu_item, gpu_props.slice());
}

/// A share of one as the load graphs' reading shows it: whole percent, which is
/// the resolution the number deserves, and the widest the reading gets.
fn loadPercentText(share: f64, buffer: *[8]u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d:.0}%", .{share * 100});
}

/// Put the newest readings on the two network graphs, each in the colour of its
/// own line, on the item's own label slot.
fn showRates(client: *sb.Client, rates: Traffic) !void {
    var down: [8]u8 = undefined;
    var up: [8]u8 = undefined;

    var received: Props = .{};
    try received.write(.{ .label = .{ .badge = try formatRate(rates.received, &down) } });
    try client.set(net_down_item, received.slice());

    var sent: Props = .{};
    try sent.write(.{ .label = .{ .badge = try formatRate(rates.sent, &up) } });
    try client.set(net_up_item, sent.slice());
}

/// Put the link the machine is on into the icon beside the graphs.
///
/// It is set on every tick rather than when it changes: it is one property in a
/// batch that is going out anyway, so a link that changed while the bar was away
/// is corrected by the next tick.
fn showLink(client: *sb.Client) !void {
    const reading = switch (netLink()) {
        .wifi => .{ theme.glyph.wifi, theme.white },
        .wired => .{ theme.glyph.ethernet, theme.white },
        .disconnected => .{ theme.glyph.disconnected, theme.red },
    };

    var props: Props = .{};
    try props.write(.{
        .icon = .{ .value = reading[0], .color = try props.argb(reading[1]) },
    });
    try client.set(link_item, props.slice());
}

/// What the machine is connected through. A value the platform does not spell -
/// which it never should - reads as the disconnected mark.
fn netLink() platform.Link {
    return std.enums.fromInt(platform.Link, platform.kx_net_link()) orelse .disconnected;
}

/// Milliseconds on the wall clock, the unit the sample cadence is kept in.
fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}
