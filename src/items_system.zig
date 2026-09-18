//! Updaters for the items whose data the helper reads directly.
//!
//! Each of these replaces a shell plugin that forked a process: `pmset` for the
//! battery, `date` twice for the calendar, and `osascript` once a second for the
//! Flow timer. They now cost a syscall and a mach message.

const std = @import("std");

const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const theme = @import("theme.zig");

/// Flow exposes its countdown through its scripting dictionary.
///
/// AppleScript rather than the JavaScript-for-Automation spelling of the same
/// call: the two return the same string, and the JavaScript one loads
/// JavaScriptCore - its own allocator and JIT - into a daemon that is otherwise
/// a few megabytes.
const flow_script_source = "tell application \"Flow\" to gettime()";
/// Starting the timer is an AppleScript verb, and is what a click on the Flow
/// item used to run through `plugins/flow-click.sh`.
const flow_start_source = "tell application \"Flow\" to start";

pub const Updater = struct {
    bar: *sb.Client,
    /// Compiled program, or null when the OSA component is unavailable.
    flow_script: ?*anyopaque = null,
    flow_start_script: ?*anyopaque = null,
    flow_output: [64]u8 = undefined,
    clock_icon: [64]u8 = undefined,
    clock_label: [64]u8 = undefined,

    pub fn init(bar: *sb.Client) Updater {
        return .{
            .bar = bar,
            .flow_script = platform.sb_osa_compile(flow_script_source, "AppleScript"),
            .flow_start_script = platform.sb_osa_compile(flow_start_source, "AppleScript"),
        };
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

    /// Refresh the Flow countdown. When Flow cannot be reached the label is
    /// cleared, matching what the shell plugin did with an empty `osascript`
    /// substitution.
    pub fn flow(self: *Updater) !void {
        var props: Props = .{};

        const script = self.flow_script orelse {
            props.raw("label=");
            try self.bar.set("flow", props.slice());
            return self.bar.commit();
        };

        if (platform.sb_osa_run(script, &self.flow_output, self.flow_output.len)) {
            var padded: [8]u8 = undefined;
            const value = padFlowTime(std.mem.sliceTo(&self.flow_output, 0), &padded);
            try props.fmt("label={s}", .{value});
        } else {
            props.raw("label=");
        }

        try self.bar.set("flow", props.slice());
        try self.bar.commit();
    }

    /// Start the Flow timer. A click on the Flow item reaches this.
    pub fn startFlow(self: *Updater) !void {
        const script = self.flow_start_script orelse return error.OsaUnavailable;
        if (!platform.sb_osa_run(script, null, 0)) return error.FlowRefused;
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
