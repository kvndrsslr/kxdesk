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

pub const Updater = struct {
    bar: *sb.Client,
    clock_icon: [64]u8 = undefined,
    clock_label: [64]u8 = undefined,

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

        var props: Props = .{};
        try props.fmt("icon={s}", .{icon});
        try props.fmt("label={d}%", .{percent});
        try self.bar.set("battery", props.slice());
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
