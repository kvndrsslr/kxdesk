//! The command registry.
//!
//! Every command is a function over `Context` that returns the payload to send
//! back to whoever asked. Commands run as worker tasks rather than on the
//! receive loop, so one that spawns yabai a dozen times does not hold up the
//! bar's item updates while it works.

const std = @import("std");

const bar_config = @import("bar.zig");
const mode_indicator = @import("mode_indicator.zig");
const sb = @import("sb.zig");
const skhdrc = @import("skhdrc.zig");
const yabai = @import("yabai.zig");
const yabai_ops = @import("yabai_ops.zig");
const zen = @import("zen.zig");

/// What a command gets to work with.
pub const Context = struct {
    /// Everything the command allocates comes from here, and the task frees the
    /// whole arena when it returns, so nothing has to be handed back.
    arena: std.mem.Allocator,
    io: std.Io,
    /// A SketchyBar connection belonging to this command alone: the receive
    /// loop's client must not see a batch it did not build.
    bar: *sb.Client,
    yabai: *yabai.Client,
    /// Whether SketchyBar is known to be up. Written by the receive loop.
    bar_present: *std.atomic.Value(bool),
    /// Bootstrap name items carry as `mach_helper`, so re-applying the
    /// configuration points them back at this daemon.
    event_service: []const u8,
    /// When this daemon started, for the uptime in `status`.
    started: std.Io.Timestamp,

    /// Connect to SketchyBar, resolving its bootstrap name again first: a bar
    /// that was restarted between two commands registers that name for a new
    /// instance, and the send right held for the old one is dead.
    pub fn ensureBar(self: *Context) !void {
        self.bar.reconnect();
        try self.bar.connect();
        self.bar_present.store(true, .monotonic);
    }
};

pub const Command = struct {
    /// The name a client spells.
    name: []const u8,
    run: *const fn (*Context, []const []const u8) anyerror![]const u8,
};

pub const all = [_]Command{
    .{ .name = "apply", .run = apply },
    .{ .name = "status", .run = status },
    .{ .name = "zen", .run = zenMode },

    // Navigation, reached from the bindings in `~/.skhdrc`.
    .{ .name = "cycle_space_windows", .run = yabai_ops.cycleSpaceWindows },
    .{ .name = "cycle_display_spaces", .run = yabai_ops.cycleDisplaySpaces },
    .{ .name = "cycle_displays", .run = yabai_ops.cycleDisplays },
    .{ .name = "switch_workspace", .run = yabai_ops.switchWorkspace },

    // Provisioning, reached from `~/.yabairc` and from the bindings that
    // reload the rules and signals after an edit.
    .{ .name = "apply_settings", .run = yabai_ops.applySettings },
    .{ .name = "refresh_rules", .run = yabai_ops.refreshRules },
    .{ .name = "refresh_signals", .run = yabai_ops.refreshSignals },
    .{ .name = "clear_signals", .run = yabai_ops.clearSignals },
    .{ .name = "generate_skhdrc", .run = skhdrc.generate },

    // Appearance.
    .{ .name = "set_mode_indicator", .run = mode_indicator.setMode },
};

/// Index of the command called `name`, or null. An index rather than a pointer,
/// because the daemon keeps one in-flight-task slot per registry entry.
pub fn find(name: []const u8) ?usize {
    for (all, 0..) |command, index| {
        if (std.mem.eql(u8, command.name, name)) return index;
    }
    return null;
}

/// Apply the bar configuration.
///
/// This is what `sketchybarrc` runs, and it is the only thing that applies it:
/// re-applying points every item's `mach_helper` at this daemon again, so a
/// SketchyBar that was restarted ends up with the items this process serves.
fn apply(context: *Context, _: []const []const u8) ![]const u8 {
    try context.ensureBar();
    try bar_config.apply(context.bar, .{ .helper = context.event_service });
    return "";
}

/// Report what the daemon is doing, in one line.
fn status(context: *Context, _: []const []const u8) ![]const u8 {
    const present = context.bar_present.load(.monotonic);
    const items = if (present) itemCount(context) catch 0 else 0;

    const now = std.Io.Timestamp.now(context.io, .awake);
    const seconds = now.nanoseconds - context.started.nanoseconds;

    return std.fmt.allocPrint(context.arena, "pid={d} uptime={d} bar={s} items={d}", .{
        std.c.getpid(),
        @divTrunc(seconds, std.time.ns_per_s),
        if (present) "connected" else "gone",
        items,
    });
}

/// Collapse the bar down to the essentials, or restore it. The calendar's click
/// reaches this too, which is why the mode is optional.
fn zenMode(context: *Context, args: []const []const u8) ![]const u8 {
    const mode: zen.Mode = if (args.len > 0) blk: {
        if (std.mem.eql(u8, args[0], "on")) break :blk .on;
        if (std.mem.eql(u8, args[0], "off")) break :blk .off;
        break :blk .toggle;
    } else .toggle;

    try context.ensureBar();
    try zen.apply(context.bar, context.arena, mode);
    return "";
}

/// How many items the running SketchyBar has.
fn itemCount(context: *Context) !usize {
    const Bar = struct {
        @"items": []const []const u8 = &.{},
    };

    var response: [64 * 1024]u8 = undefined;
    try context.bar.connect();
    context.bar.clear();
    try context.bar.arg("--query");
    try context.bar.arg("bar");
    const body = try context.bar.commitInto(&response);

    const parsed = std.json.parseFromSliceLeaky(Bar, context.arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.InvalidSketchyBarResponse;
    return parsed.@"items".len;
}
