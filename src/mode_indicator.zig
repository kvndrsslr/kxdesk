//! The mode indicator: the colour the space items' icons highlight with.
//!
//! Ported from `__set_mode_indicator` in `~/bin/yabai_util`. The mode index is
//! recorded in `/tmp/yabai-mode` for other tooling to read, and one mach message
//! sets the highlight colour on every space item at once - the shell forked the
//! `sketchybar` CLI for that; here it is a batch on the bar's port.

const std = @import("std");

const commands = @import("commands.zig");
const platform = @import("platform.zig");

const Context = commands.Context;

/// The file the mode index is recorded in, for tooling that reads it.
const mode_file_path = "/tmp/yabai-mode";

/// Highlight colours per mode index when the system is in light mode. Index 0
/// is mode 1 - zsh arrays were 1-based and the template's bindings spell the
/// indices, so the off-by-one stays in the table, not at the call sites.
const bright = [_][]const u8{ "83A598", "B8BB26", "FABD2F", "FE8019", "FB4934", "D3869B", "8EC07C" };

/// Same table for dark mode; outside dark mode the bright table is always the
/// bar colour.
const dark = [_][]const u8{ "458588", "98971A", "D79921", "D65D0E", "CC241D", "B16286", "689D6A" };

/// Set the mode indicator. `args[0]` is a mode index (`1`…`7`) or `-` for "no
/// mode": with no mode the indicator is cleared and its colour depends on the
/// system appearance alone.
pub fn setMode(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arg = if (args.len > 0) args[0] else return error.MissingArgument;

    const index: ?usize = if (std.mem.eql(u8, arg, "-"))
        null
    else
        std.fmt.parseInt(usize, arg, 10) catch return error.InvalidModeIndex;
    if (index) |i| {
        // The tables are 1-based, so mode 7 is the last entry and mode 0 has no
        // entry at all.
        if (i == 0 or i > bright.len) return error.InvalidModeIndex;
    }

    const dark_mode = darkMode();
    const y: []const u8 = if (index) |i|
        if (dark_mode) dark[i - 1] else bright[i - 1]
    else if (dark_mode) "79740E" else "fabd2f";
    // The bar colour is the bright-table entry even in dark mode, for both a
    // mode and "no mode"'s only exception below.
    const bar: []const u8 = if (index) |i|
        bright[i - 1]
    else if (dark_mode) "b8bb26" else "504945";

    // The mode colour is written uppercase without a `0x` prefix, matching the
    // file the shell left behind; only `bar` reaches SketchyBar, and only as
    // one message.
    var mode_colour: [6]u8 = undefined;
    const recorded = std.ascii.upperString(&mode_colour, y);
    writeModeFile(context.io, recorded) catch return error.ModeFileUnwritable;

    var bar_upper: [6]u8 = undefined;
    _ = std.ascii.upperString(&bar_upper, bar);
    var highlight: [32]u8 = undefined;
    const property = std.fmt.bufPrint(&highlight, "icon.highlight_color=0xff{s}", .{bar_upper}) catch return error.OutOfMemory;

    try context.ensureBar();
    try context.bar.set("/space.*/", &.{property});
    try context.bar.commit();
    return "";
}

/// Record the mode colour. The shell's `echo "$Y_CLR" >` left a trailing
/// newline; tools may read the file expecting one.
fn writeModeFile(io: std.Io, colour: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, mode_file_path, .{});
    defer file.close(io);

    var line: [7]u8 = undefined;
    const written = std.fmt.bufPrint(&line, "{s}\n", .{colour}) catch return error.ModeColourTooLong;
    try file.writeStreamingAll(io, written);
}

/// Whether the system is in dark mode, read from the preference the system
/// records the appearance in. The shell asked `System Events` over an Apple
/// Event, which needs Automation and Accessibility permission and is asked for
/// again for every new binary; a preference read needs nothing.
fn darkMode() bool {
    return platform.sb_dark_mode();
}
