//! Updaters for the items whose data the daemon reads directly.
//!
//! Each of these replaces a shell plugin that forked a process: `pmset` for the
//! battery and `date` twice for the calendar. They now cost a syscall and a mach
//! message. The graphs are fed the same way: Mach's tick counters for the load
//! and one `sysctl` for the interfaces' byte counters, once a second.
//!
//! Flow's countdown used to be here too, read once a second through Flow's
//! scripting dictionary. That is an Apple Event, and an Apple Event to another
//! application needs Automation permission - which macOS asks for again for every
//! new binary, so an upgraded daemon would have to be approved again. A prompt on
//! every launch is worse than a countdown, so nothing here asks another
//! application anything.

const std = @import("std");

const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const theme = @import("theme.zig");

/// The graph items, one point pushed into each per tick: the load pair - CPU and
/// GPU - and the network pair, each pair drawn over one another in a window of
/// its own.
pub const cpu_item = "cpu";
pub const gpu_item = "gpu";
pub const net_down_item = "net.down";
pub const net_up_item = "net.up";

/// What the machine is connected through. The graphs cannot say this: they are
/// silent about a link that is there and carrying nothing, which is exactly the
/// state a link icon is for.
pub const link_item = "net.link";

/// The graphs are sampled once a second. A reading is the rate between two reads
/// of a cumulative counter - Mach's tick counters for the load, the interfaces'
/// byte counters for the traffic - so this interval *is* the window the numbers
/// average over: shorter and the lines twitch, longer and they lag.
const sample_cadence_ms: i64 = std.time.ms_per_s;

/// What the network graphs' height means, in bytes per second: the rate at the
/// bottom of the graph and the rate at the top. Traffic is spread over orders of
/// magnitude - an idle machine is kilobytes a second, a saturated link hundreds
/// of megabytes - so a linear scale would show either nothing but the peaks or a
/// flat line with the peaks off the top of the graph. The graph is logarithmic
/// instead: a kilobyte to a gigabyte a second, six decades, each taking a sixth
/// of the height. A rate at the floor is a line on the bottom, a megabyte a
/// second is halfway up, and the shape of the line reads the same whatever the
/// machine is doing.
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
/// are: three digits at most, one separator at most, then the unit - `12.3K`,
/// `999M`, `1.00G`.
///
/// That bound is not decoration: `bar.zig` sizes the room to the graph's right
/// for the widest reading this can produce (`readout_chars`), so a reading that
/// grew a fourth digit would draw itself over the line. What it produces is
/// truncated rather than rounded for the same reason - a rate a hair under a unit
/// boundary must not round up into the digit that does not fit.
pub fn formatRate(bytes_per_second: f64, buffer: *[8]u8) ![]const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T" };
    var magnitude: usize = 0;
    var scaled = bytes_per_second;
    while (scaled >= 1_000 and magnitude + 1 < units.len) : (magnitude += 1) {
        scaled /= 1_000;
    }

    // Three digits: two of them after the separator below ten, one below a
    // hundred, and none from a hundred up. Bytes are whole - there is no
    // half byte to report, and a rate that slow reads better as `512B`.
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
    // The clamp is what keeps a reading to three digits for a rate no link can
    // carry; the graph's room is sized for three and no more.
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

pub const Updater = struct {
    bar: *sb.Client,
    clock_icon: [64]u8 = undefined,
    clock_label: [64]u8 = undefined,
    /// When the graphs last got a point, zero until they get their first.
    last_sample: i64 = 0,
    /// The links' cumulative byte counters at the last reading, and when it was
    /// taken. A rate is a difference between two readings, so both are kept
    /// between ticks; zero until the first reading has been taken.
    net_received: u64 = 0,
    net_sent: u64 = 0,
    net_sampled: i64 = 0,

    pub fn init(bar: *sb.Client) Updater {
        return .{ .bar = bar };
    }

    pub fn battery(self: *Updater) !void {
        var percent: i32 = 0;
        var charging = false;
        // A machine without a battery simply has no reading to publish.
        if (!platform.sb_battery(&percent, &charging)) return;

        const icon = if (charging) theme.glyph.battery_charging else switch (percent) {
            90...100 => theme.glyph.battery_full,
            60...89 => theme.glyph.battery_3,
            30...59 => theme.glyph.battery_2,
            10...29 => theme.glyph.battery_1,
            else => theme.glyph.battery_empty,
        };

        // The ring is the battery's whole readout: the charge is its value and
        // the same level glyph - the charging one while the machine is on AC -
        // sits inside it as the marker, so it reads as the battery filling and
        // says which of the two it is at the same time. It is drawn whether or
        // not the battery is taking power, so the drawing is set on every
        // reading as well as by the configuration, which is also what an item
        // left over from an earlier configuration needs.
        var ring: Props = .{};
        ring.raw("drawing=on");
        try ring.fmt("ring.value={d:.2}", .{@as(f64, @floatFromInt(percent)) / 100.0});
        try ring.fmt("ring.marker={s}", .{icon});
        try self.bar.set(ring_item, ring.slice());

        try self.bar.commit();
    }

    pub fn calendar(self: *Updater) !void {
        platform.sb_clock(
            &self.clock_icon,
            self.clock_icon.len,
            &self.clock_label,
            self.clock_label.len,
        );

        var props: Props = .{};
        try props.fmt("icon={s}", .{std.mem.sliceTo(&self.clock_icon, 0)});
        try props.fmt("label={s}", .{std.mem.sliceTo(&self.clock_label, 0)});
        try self.bar.set("calendar", props.slice());
        try self.bar.commit();
    }

    /// Push one reading per graph series if the schedule says a sample is due,
    /// and report how long the receive loop may wait next - the shape
    /// `pollUsage` has, because both are driven by that one timer.
    ///
    /// Every reading is taken even when there is no bar to push it to. The
    /// counters only mean anything as a difference between two of them, and a
    /// baseline left to go stale would turn the first point after the bar comes
    /// back into an average over however long it was gone.
    pub fn pollGraphs(self: *Updater, io: std.Io, bar: ?*sb.Client) u32 {
        const sampled = nowMs(io);
        if (self.last_sample != 0) {
            const waiting = sample_cadence_ms - (sampled - self.last_sample);
            if (waiting > 0) return @intCast(waiting);
        }
        self.last_sample = sampled;

        const cpu = platform.sb_cpu_load();
        const gpu = platform.sb_gpu_load();
        const traffic = self.pollTraffic(sampled);

        if (bar) |client| {
            // One message for every series, so they cannot fall out of step: the
            // graphs share a window only by each getting exactly one point per
            // tick. A failed send is the next tick's business - nothing is left
            // half done by it, and every series catches up a second later.
            client.push(cpu_item, cpu) catch return @intCast(std.time.ms_per_s);
            client.push(gpu_item, gpu) catch return @intCast(std.time.ms_per_s);
            showLoad(client, cpu, gpu) catch return @intCast(std.time.ms_per_s);
            if (traffic) |rates| {
                client.push(net_down_item, netLevel(rates.received)) catch
                    return @intCast(std.time.ms_per_s);
                client.push(net_up_item, netLevel(rates.sent)) catch
                    return @intCast(std.time.ms_per_s);
                // The readouts and the link come in this same batch: a rate that
                // changed and a link that changed are the same moment, and a
                // message of its own for either would only redraw the bar twice
                // for one tick.
                showRates(client, rates) catch return @intCast(std.time.ms_per_s);
            }
            showLink(client) catch return @intCast(std.time.ms_per_s);
            client.commit() catch return @intCast(std.time.ms_per_s);
        }
        return @intCast(std.time.ms_per_s);
    }

    /// The links' traffic since the previous reading, in bytes per second and per
    /// direction - or `null` when there is nothing to report: no counters to be
    /// read, or no earlier reading to difference against.
    ///
    /// Counters belong to an interface and are gone with it, so a total that went
    /// backwards is a link that was replaced rather than traffic: it becomes the
    /// new baseline and this tick carries nothing. A reading that could not be
    /// taken at all is a tick the network graphs simply miss - the next one
    /// divides by the seconds that actually passed, so what it reports is still
    /// the rate over the interval it covers.
    fn pollTraffic(self: *Updater, sampled: i64) ?Traffic {
        var received: u64 = 0;
        var sent: u64 = 0;
        if (!platform.sb_net_bytes(&received, &sent)) return null;

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

/// Put the two load readings on their graphs: the CPU on the cpu item and the
/// GPU on the gpu item, each on its own item's label slot, which is the slot the
/// pair draws its readings in - see `graphSlot` in `bar.zig`.
fn showLoad(client: *sb.Client, cpu: f64, gpu: f64) !void {
    var cpu_text: [8]u8 = undefined;
    var gpu_text: [8]u8 = undefined;

    var cpu_props: Props = .{};
    try cpu_props.fmt("label.badge={s}", .{try percentText(cpu, &cpu_text)});
    try client.set(cpu_item, cpu_props.slice());

    var gpu_props: Props = .{};
    try gpu_props.fmt("label.badge={s}", .{try percentText(gpu, &gpu_text)});
    try client.set(gpu_item, gpu_props.slice());
}

/// A share of one as the load graphs' reading shows it: whole percent, which is
/// the resolution the number deserves. The line is what says the machine is
/// busy - the reading only says how busy, and "100%" is the widest it gets.
fn percentText(share: f64, buffer: *[8]u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d:.0}%", .{share * 100});
}

/// Put the newest readings on the two network graphs, each in the colour of its
/// own line, on the item's own label slot - the space the graph keeps free on its
/// right; see `graphSlot` in `bar.zig`.
fn showRates(client: *sb.Client, rates: Traffic) !void {
    var down: [8]u8 = undefined;
    var up: [8]u8 = undefined;

    var received: Props = .{};
    try received.fmt("label.badge={s}", .{try formatRate(rates.received, &down)});
    try client.set(net_down_item, received.slice());

    var sent: Props = .{};
    try sent.fmt("label.badge={s}", .{try formatRate(rates.sent, &up)});
    try client.set(net_up_item, sent.slice());
}

/// Put the link the machine is on into the icon beside the graphs.
///
/// It is set with every tick rather than when it changes: it is one property in
/// a message that is going out anyway, and a link that changed while the bar was
/// away - or a reading that could not be taken when it did - is then corrected
/// by the next tick instead of leaving the wrong mark up.
fn showLink(client: *sb.Client) !void {
    const reading = switch (netLink()) {
        .wifi => .{ theme.glyph.wifi, theme.white },
        .wired => .{ theme.glyph.ethernet, theme.white },
        .disconnected => .{ theme.glyph.disconnected, theme.red },
    };

    var props: Props = .{};
    try props.fmt("icon={s}", .{reading[0]});
    try props.color("icon.color", reading[1]);
    try client.set(link_item, props.slice());
}

/// What the machine is connected through. A value the platform does not spell -
/// which it never should - reads as the disconnected mark rather than as a link
/// that is not there.
fn netLink() platform.Link {
    return std.enums.fromInt(platform.Link, platform.sb_net_link()) orelse .disconnected;
}

/// `"00:00".substring(0, 5 - value.length) + value` - left-pad the timer to the
/// five characters the label is sized for.
fn padFlowTime(value: []const u8, buffer: *[8]u8) []const u8 {
    if (value.len >= 5) return value;

    const width = 5 - value.len;
    @memset(buffer[0..width], '0');
    @memcpy(buffer[width..][0..value.len], value);
    return buffer[0 .. width + value.len];
}

/// Milliseconds on the wall clock: the unit the sample cadence is kept in, and
/// fine enough that a rate divided by the interval between two samples is the
/// rate over that interval rather than over a rounded second.
fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}
