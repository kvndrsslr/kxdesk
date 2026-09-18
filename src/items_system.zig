//! Updaters for the items whose data the daemon reads directly.
//!
//! Each of these replaces a shell plugin that forked a process: `pmset` for the
//! battery and `date` twice for the calendar. They now cost a syscall and a mach
//! message.
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

/// The two graph items, each fed one point per tick and drawn over one another.
pub const cpu_item = "cpu";
pub const gpu_item = "gpu";

/// The graph is sampled once a second. A reading is the rate between two reads of
/// Mach's cumulative tick counters, so this interval *is* the window the number
/// averages over: shorter and the line twitches, longer and it lags.
const cpu_cadence_seconds: i64 = 1;

/// The battery's charge, and its only readout on the bar: a ring whose value is
/// the charge and whose marker is the battery's own level glyph.
pub const ring_item = "battery.ring";

pub const Updater = struct {
    bar: *sb.Client,
    clock_icon: [64]u8 = undefined,
    clock_label: [64]u8 = undefined,
    /// When the graphs last got a point, zero until they get their first.
    last_sample: i64 = 0,

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

    /// Push one CPU reading and one GPU reading into the graphs if the schedule
    /// says a sample is due, and report how long the receive loop may wait next -
    /// the shape `pollUsage` has, because both are driven by that one timer.
    ///
    /// Both readings are taken even when there is no bar to push them to. The CPU
    /// counters only mean anything as a difference between two of them, and a
    /// baseline left to go stale would turn the first point after the bar comes
    /// back into an average over however long it was gone.
    pub fn pollLoad(self: *Updater, io: std.Io, bar: ?*sb.Client) u32 {
        if (self.last_sample != 0) {
            const waiting = cpu_cadence_seconds - (now(io) - self.last_sample);
            if (waiting > 0) return @intCast(waiting * std.time.ms_per_s);
        }
        self.last_sample = now(io);

        const cpu = platform.sb_cpu_load();
        const gpu = platform.sb_gpu_load();
        if (bar) |client| {
            // One message for both series, so they cannot fall out of step: the
            // graphs share a window only by each getting exactly one point per
            // tick. A failed send is the next tick's business - nothing is left
            // half done by it, and both catch up a second later.
            client.push(cpu_item, cpu) catch return @intCast(std.time.ms_per_s);
            client.push(gpu_item, gpu) catch return @intCast(std.time.ms_per_s);
            client.commit() catch return @intCast(std.time.ms_per_s);
        }
        return @intCast(std.time.ms_per_s);
    }

};

/// `"00:00".substring(0, 5 - value.length) + value` - left-pad the timer to the
/// five characters the label is sized for.
fn padFlowTime(value: []const u8, buffer: *[8]u8) []const u8 {
    if (value.len >= 5) return value;

    const width = 5 - value.len;
    @memset(buffer[0..width], '0');
    @memcpy(buffer[width..][0..value.len], value);
    return buffer[0 .. width + value.len];
}

/// Whole seconds on the wall clock, the unit the cadences are kept in.
fn now(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}
