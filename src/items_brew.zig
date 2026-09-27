//! The brew item: the outdated count on its badge, and the upgrade its click runs.
//!
//! `brew outdated` takes over a second and an upgrade takes minutes, so the daemon
//! runs both as background tasks rather than on the event path; see
//! `background.zig`.
//!
//! A run that fails keeps what the failing command said in the store and leaves the
//! item wearing the failure; the next click opens a terminal that prints it. The
//! item reads that same key, so the mark and the stored failure cannot disagree.

const std = @import("std");

const exec = @import("exec.zig");
const kitty = @import("kitty.zig");
const log = @import("log.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const state = @import("store.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");

/// The item this file owns. `dispatch.zig` routes its events by this name.
pub const item = "brew";

/// The store key a failed command's output waits in, which is also what says the
/// item has a failure to show.
const error_key = "brew.error";

/// The terminal a failure is printed in. Not one of the user's configured
/// terminals: nothing about it is theirs to keep in step, so the daemon names it
/// and writes what it prints itself.
const error_terminal = "brew-error";

/// The mark an error wears in the chip: a plain letter, because a glyph for it
/// would have to be checked by rendering it and would say no more than this does.
const error_mark = "X";

/// One command of the upgrade, as the click runs it: `brew update`, then the
/// formulae, then the casks, each of the last two with `--yes` - one argv at a
/// time, with nothing here going through a shell. `name` is how the step reads in
/// the log.
const Step = struct {
    name: []const u8,
    argv: []const []const u8,
};

const steps = [_]Step{
    .{ .name = "update", .argv = &.{"update"} },
    .{ .name = "upgrade --formulae", .argv = &.{ "upgrade", "--formulae", "--yes" } },
    .{ .name = "upgrade --casks", .argv = &.{ "upgrade", "--casks", "--yes" } },
};

/// The item's own schedule: how many packages are outdated, on the badge. A
/// failure waiting to be read is what it draws instead, so that an item left
/// wearing one - by the hourly tick, or by a daemon that was restarted - still
/// says what the click would find there.
pub fn refresh(io: std.Io, gpa: std.mem.Allocator, store: *state.Store) anyerror!void {
    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    if (hasFailure(io, store)) return render(&client, errored());
    return renderCount(&client, io, gpa);
}

/// What a click asks for: a failure waiting is the click's business - the run it
/// came from is over - so it is printed in a terminal and cleared, and the count
/// is what the item goes back to; with nothing waiting, the upgrade starts.
///
/// A click that arrives while one of these runs waits for it rather than racing
/// it, which is what the slot it is handed to is for.
pub fn clicked(io: std.Io, gpa: std.mem.Allocator, store: *state.Store) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The whole text, not just the fact of it: the terminal is about to print it.
    // A store that cannot be read is a machine with no failure waiting, which is
    // the same thing the item's own schedule decides from.
    if (store.getTextAlloc(io, arena, error_key) catch null) |failure| {
        return showFailure(io, gpa, arena, store, failure);
    }
    return upgrade(io, gpa, store);
}

/// Print a failed command's output in a terminal, and take the failure off the
/// item: what the click asked for has been answered, and the count is what the
/// item says next. The key is cleared only once the terminal is up, so a click
/// that could not open a window leaves the output for the next one.
fn showFailure(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    store: *state.Store,
    failure: []const u8,
) !void {
    try kitty.showText(io, arena, error_terminal, failure);

    store.unset(io, error_key) catch |err| log.warn(
        "could not clear the brew failure: {s}",
        .{@errorName(err)},
    );
    return refresh(io, gpa, store);
}

/// Run the upgrade a click asks for, as one task: the loading mark while the
/// commands run, and then the count when every one of them succeeded - or the
/// failure mark, with the output of the command that failed kept for the click
/// that follows.
fn upgrade(io: std.Io, gpa: std.mem.Allocator, store: *state.Store) anyerror!void {
    const brew = try exec.path(gpa, "brew");
    defer gpa.free(brew);

    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    try render(&client, loading());

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (steps) |step| {
        const result = std.process.run(gpa, io, .{ .argv = try argvOf(arena, brew, step) }) catch |err| {
            // The command could not be run at all: what it would have said is the
            // error's name, and that is what the terminal gets.
            log.warn("brew {s} could not be run: {s}", .{ step.name, @errorName(err) });
            keep(io, store, @errorName(err));
            return render(&client, errored());
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code == 0) continue else log.warn(
                "brew {s} failed with exit {d}",
                .{ step.name, code },
            ),
            else => log.warn("brew {s} was killed by a signal", .{step.name}),
        }

        keep(io, store, try output(arena, result));
        return render(&client, errored());
    }

    return renderCount(&client, io, gpa);
}

/// `brew` and one step's arguments, in the caller's arena.
fn argvOf(arena: std.mem.Allocator, brew: []const u8, step: Step) ![]const []const u8 {
    const argv = try arena.alloc([]const u8, step.argv.len + 1);
    argv[0] = brew;
    @memcpy(argv[1..], step.argv);
    return argv;
}

/// What a failed command said, as the terminal prints it: its standard output and
/// then its standard error, the two `std.process.run` collected, with a newline
/// between them when the output did not end in one.
fn output(arena: std.mem.Allocator, result: std.process.RunResult) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    try text.appendSlice(arena, result.stdout);
    if (result.stderr.len > 0) {
        if (text.items.len > 0 and text.items[text.items.len - 1] != '\n') {
            try text.append(arena, '\n');
        }
        try text.appendSlice(arena, result.stderr);
    }
    return text.items;
}

/// Keep what a failed command said, for the click that prints it. The item wears
/// the failure whether or not the store took it: the store is best-effort, and a
/// mark with nothing behind it beats hiding a failure that happened.
fn keep(io: std.Io, store: *state.Store, text: []const u8) void {
    store.setText(io, error_key, text) catch |err| log.warn(
        "could not keep the brew failure: {s}",
        .{@errorName(err)},
    );
}

/// Whether a failure's output is waiting. Read into a byte of scratch: the text
/// itself is the terminal's business, and only its presence is the item's. An
/// output that was empty is still a failure, which is why this asks whether the
/// key is there rather than what it says.
fn hasFailure(io: std.Io, store: *state.Store) bool {
    var probe: [1]u8 = undefined;
    return (store.getText(io, error_key, &probe) catch null) != null;
}

/// The outdated count: `brew outdated` run again now rather than on the item's own
/// clock, which is what the item says once an upgrade has succeeded.
fn renderCount(client: *sb.Client, io: std.Io, gpa: std.mem.Allocator) !void {
    const brew = try exec.path(gpa, "brew");
    defer gpa.free(brew);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ brew, "outdated" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    // Newlines, not entries: this is the count `brew outdated | wc -l` printed, down
    // to output that ends without a newline.
    const count = std.mem.count(u8, result.stdout, "\n");

    const idle = count == 0;
    var count_buffer: [16]u8 = undefined;
    // Numbers read at 9pt like the bell's; the idle checkmark in the same Nerd Font
    // draws oversized next to them, so it gets 8pt.
    const font = if (idle) style.mono(.Bold, 8) else style.mono(.Bold, 9);
    const badge: []const u8 = if (idle)
        theme.glyph.brew_current
    else
        try std.fmt.bufPrint(&count_buffer, "{d}", .{count});

    return render(client, .{
        .badge = badge,
        .font = font,
        .color = if (idle) theme.green else outdatedColor(count),
    });
}

/// The mark the item wears while the upgrade's commands run. White is the icon's
/// own default colour, so the mark says "in progress" without grading anything.
fn loading() Mark {
    return .{ .badge = theme.glyph.loading, .font = style.mono(.Bold, 9), .color = theme.white };
}

/// The mark the item wears after a command failed, until the click that prints it.
fn errored() Mark {
    return .{ .badge = error_mark, .font = style.mono(.Bold, 9), .color = theme.red };
}

/// What the item's badge and icon say: the chip's text, the font it is drawn in,
/// and the colour the icon wears.
const Mark = struct {
    badge: []const u8,
    font: []const u8,
    color: theme.Color,
};

/// Draw one mark on the item: the chip's text and font, and the icon's colour,
/// in one batch.
fn render(client: *sb.Client, mark: Mark) !void {
    var props: Props = .{};
    try props.write(.{ .icon = .{
        .badge = .{ .value = mark.badge, .font = mark.font },
        .color = try props.argb(mark.color),
    } });

    try client.set(item, props.slice());
    try client.commit();
}

/// The count's grade: 1-9 white, 10-29 yellow, 30-59 orange, anything larger red -
/// and none at all green with a tick.
fn outdatedColor(count: usize) theme.Color {
    return switch (count) {
        1...9 => theme.white,
        10...29 => theme.yellow,
        30...59 => theme.orange,
        else => theme.red,
    };
}
