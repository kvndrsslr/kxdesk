//! The mode indicator: the colour the space items' icons highlight with.
//!
//! The mode index is recorded in `/tmp/yabai-mode` for other tooling to read --
//! see `mode_file_path` -- and one mach message sets the highlight colour on
//! every space item at once.

const std = @import("std");

const Context = @import("context.zig").Context;
const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const theme = @import("theme.zig");

/// The file the mode index is recorded in, for tooling that reads it. It is the
/// shell's interface and survives a restart of this daemon, but not a reboot -
/// which is what the store is for.
const mode_file_path = "/tmp/yabai-mode";

/// Where the mode index is remembered, so a restarted bar comes back with the
/// highlight colour it had.
const state_key = "mode";

/// Highlight colours per mode index in light mode. Index 0 is mode 1 - the shell's
/// arrays were 1-based and the template's bindings spell the indices, so the
/// off-by-one stays in the table, not at the call sites.
const bright = [_]theme.Color{
    0xFF83A598, 0xFFB8BB26, 0xFFFABD2F, 0xFFFE8019, 0xFFFB4934, 0xFFD3869B, 0xFF8EC07C,
};

/// The same table for dark mode. Outside dark mode the bright table is always the
/// bar colour.
const dark = [_]theme.Color{
    0xFF458588, 0xFF98971A, 0xFFD79921, 0xFFD65D0E, 0xFFCC241D, 0xFFB16286, 0xFF689D6A,
};

/// The mode indices `set_mode_indicator` accepts, as a count: `1`…`mode_count`
/// select a mode.
pub const mode_count = bright.len;

/// `-`'s highlight and bar colour: `no_mode_dark` is the palette's own dark
/// green, `no_mode_bar_dark` the bright table's second entry.
const no_mode_light = 0xFFFABD2F;
const no_mode_dark = 0xFF79740E;
const no_mode_bar_light = 0xFF504945;
const no_mode_bar_dark = 0xFFB8BB26;

/// Set the mode indicator. `args[0]` is a mode index (`1`…`7`) or `-` for "no
/// mode": with no mode the indicator is cleared and its colour depends on the
/// system appearance alone.
pub fn setMode(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arg = if (args.len > 0) args[0] else return error.MissingArgument;

    const index: ?usize = if (std.mem.eql(u8, arg, "-"))
        null
    else
        std.fmt.parseInt(usize, arg, 10) catch return error.InvalidModeIndex;
    // The tables are 1-based, so mode 0 has no entry at all.
    if (index) |i| {
        if (i == 0 or i > mode_count) return error.InvalidModeIndex;
    }

    const dark_mode = darkMode();
    const colour: theme.Color = if (index) |i|
        if (dark_mode) dark[i - 1] else bright[i - 1]
    else if (dark_mode) no_mode_dark else no_mode_light;
    // A mode's bar colour is the bright-table entry whatever the appearance;
    // only "no mode" changes with it.
    const bar: theme.Color = if (index) |i|
        bright[i - 1]
    else if (dark_mode) no_mode_bar_dark else no_mode_bar_light;

    writeModeFile(context.io, colour) catch return error.ModeFileUnwritable;

    try context.ensureBar();
    var props: Props = .{};
    try props.write(.{ .icon = .{ .highlight_color = try props.argb(bar) } });
    try context.bar.set("/space.*/", props.slice());
    try context.bar.commit();

    // Remembered as the argument was spelled, so "no mode" comes back as "no
    // mode" rather than as a mode index that happens to look the same.
    context.store.setText(context.io, state_key, arg) catch {};

    return "";
}

/// Put back the mode the previous daemon was in, wherever the bar configuration
/// is applied: a rebuilt bar has lost the highlight colour.
pub fn restore(context: *Context) void {
    var buffer: [8]u8 = undefined;
    const remembered = (context.store.getText(context.io, state_key, &buffer) catch null) orelse return;
    _ = setMode(context, &.{remembered}) catch {};
}

/// Record the mode colour as the six uppercase hex digits the shell's
/// `echo "$Y_CLR" >` left behind, trailing newline included.
fn writeModeFile(io: std.Io, colour: theme.Color) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, mode_file_path, .{});
    defer file.close(io);

    var line: [7]u8 = undefined;
    const written = try std.fmt.bufPrint(&line, "{X:0>6}\n", .{colour & 0xFF_FFFF});
    try file.writeStreamingAll(io, written);
}

/// Whether the system is in dark mode, read from the preference that records the
/// appearance - a preference read needs no Automation permission, unlike the
/// Apple Event the shell asked `System Events` over.
fn darkMode() bool {
    return platform.kx_dark_mode();
}
