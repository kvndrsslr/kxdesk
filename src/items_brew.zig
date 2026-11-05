//! The brew item: the outdated count on its badge, and the upgrade its click runs.
//!
//! `brew outdated` takes over a second and an upgrade takes minutes, so the daemon
//! runs both as background tasks rather than on the event path; see
//! `background.zig`.
//!
//! Both run through the user's login shell. Homebrew decides which taps are
//! trusted from `${XDG_CONFIG_HOME}/homebrew/trust.json`, and the daemon has no
//! `XDG_CONFIG_HOME`: launchd starts it without the shell that exports it, so
//! Homebrew reads `~/.homebrew/trust.json` and refuses every tap `brew trust`
//! recorded in the user's own file. The count is therefore read through that shell
//! from a marked line, and the upgrade runs in a quick access terminal the daemon
//! names, where the user's configuration is the one in force.
//!
//! That terminal is started hidden and is the only place the upgrade runs. A run
//! that fails keeps its window - the shell at the end of its script holds the
//! output - and leaves a mark on the item; the click that follows shows that
//! window. A window that is gone by then is answered with the same text in a
//! terminal of the daemon's own, which is why the failure is kept in the store.
//! The item reads that same key, so the mark and the stored failure cannot
//! disagree.

const std = @import("std");

const exec = @import("exec.zig");
const kitty = @import("kitty.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const state = @import("store.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");
const yabai = @import("yabai.zig");

/// The item this file owns. `dispatch.zig` routes its events by this name.
pub const item = "brew";

/// The store key a failed command's output waits in, which is also what says the
/// item has a failure to show.
const error_key = "brew.error";

/// The terminal the upgrade runs in: the daemon's, not one of the user's, so
/// `term toggle` has no word for it and no configuration file names it.
const run_terminal = "brew";

/// The terminal a failure is printed in when the run's own window is gone. Also
/// the daemon's: nothing about it is the user's to keep in step.
const error_terminal = "brew-error";

/// The two files the upgrade script leaves beside the terminal's socket: what the
/// commands printed, and the status that says whether they all succeeded.
const log_suffix = ".log";
const status_suffix = ".status";

/// The mark an error wears in the chip: a plain letter, because a glyph for it
/// would have to be checked by rendering it and would say no more than this does.
const error_mark = "X";

/// Largest failure this keeps in the store: an upgrade's output is a few screens,
/// and a run that says more than this is a run the terminal still holds.
const max_failure_bytes = 4 * 1024 * 1024;

/// What the run's terminal executes, as one zsh script. It is a script rather than
/// an argv because it must run in the user's shell, with the environment and the
/// trust file that shell's configuration gives it - the reason the run is in a
/// terminal at all.
///
/// `$0` is the shell's own path (see `upgrade`), which is what lets the user's
/// `zsh4humans` bootstrap find the zsh it is running; the four arguments are the
/// brew binary, the log, the status file, and the kxdesk that posts the refresh.
/// The pipeline's status is `pipestatus[1]`, the brew command's, not `tee`'s, and
/// a failure stops the chain there - the same order the daemon used to run.
///
/// A failure hands the window to a login shell, so the output stays readable and
/// the panel stays alive for the click that reveals it. Success ends the script,
/// which closes the panel.
const run_script =
    \\brew=$1 log_file=$2 state_file=$3 kx=$4
    \\"$brew" update 2>&1 | tee "$log_file"
    \\code=$pipestatus[1]
    \\if (( code == 0 )); then
    \\  "$brew" upgrade --formulae --yes 2>&1 | tee -a "$log_file"
    \\  code=$pipestatus[1]
    \\fi
    \\if (( code == 0 )); then
    \\  "$brew" upgrade --casks --yes 2>&1 | tee -a "$log_file"
    \\  code=$pipestatus[1]
    \\fi
    \\printf '%d\n' "$code" > "$state_file"
    \\"$kx" brew refresh
    \\if (( code != 0 )); then
    \\  exec "${SHELL:-/bin/zsh}" -l
    \\fi
;

/// How the count is read through the shell: a marked line, because the shell's
/// own configuration may print while it starts, and only brew's standard output
/// feeds `wc`. The marker is what the daemon parses out of everything the shell
/// said.
const count_marker = "KXDESK-COUNT ";
const count_script = "printf 'KXDESK-COUNT '; \"$@\" 2>/dev/null | command wc -l";

/// The item's own schedule: how many packages are outdated, on the badge. A
/// failure waiting to be read is what it draws instead, so that an item left
/// wearing one - by the hourly tick, or by a daemon that was restarted - still
/// says what the click would find there.
pub fn refresh(io: std.Io, gpa: std.mem.Allocator, store: *state.Store) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    settle(io, arena_state.allocator(), store);

    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    if (hasFailure(io, store)) return render(&client, errored());
    return renderCount(&client, io, gpa);
}

/// What a click asks for: a failure waiting is the click's business - the run it
/// came from is over - so its window is shown and the failure cleared, and the
/// count is what the item goes back to; with nothing waiting, a run that is still
/// up is shown, and otherwise the upgrade starts.
///
/// A click that arrives while one of these runs waits for it rather than racing
/// it, which is what the slot it is handed to is for.
pub fn clicked(
    io: std.Io,
    gpa: std.mem.Allocator,
    yabai_client: *yabai.Client,
    store: *state.Store,
) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The whole text, not just the fact of it: the terminal is about to print it.
    // A store that cannot be read is a machine with no failure waiting, which is
    // the same thing the item's own schedule decides from.
    if (store.getTextAlloc(io, arena, error_key) catch null) |failure| {
        return showFailure(io, gpa, arena, yabai_client, store, failure);
    }

    var display_buffer: [kitty.max_display_name]u8 = undefined;
    const display = kitty.focusedDisplayName(yabai_client, arena, &display_buffer);

    // A run in progress, or the window of a failure that has been read already:
    // showing it is what a click asks for. A socket left behind by a terminal
    // that is gone answers nothing, and the upgrade starts below.
    if (kitty.running(io, run_terminal)) {
        if (kitty.showNamed(io, arena, run_terminal, display) catch false) return;
    }

    return upgrade(io, gpa, store);
}

/// Show a failed command's output in its run's terminal, or - when that terminal
/// is gone - in one of the daemon's that prints the text the store kept. The
/// failure is taken off the item afterwards: what the click asked for has been
/// answered, and the count is what the item says next. The key is cleared only
/// once a window is up, so a click that could not open one leaves the output for
/// the next.
fn showFailure(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    yabai_client: *yabai.Client,
    store: *state.Store,
    failure: []const u8,
) !void {
    var display_buffer: [kitty.max_display_name]u8 = undefined;
    const display = kitty.focusedDisplayName(yabai_client, arena, &display_buffer);

    const revealed = kitty.showNamed(io, arena, run_terminal, display) catch false;
    if (!revealed) try kitty.showText(io, arena, error_terminal, failure);

    store.unset(io, error_key) catch |err| log.warn(
        "could not clear the brew failure: {s}",
        .{@errorName(err)},
    );
    return refresh(io, gpa, store);
}

/// Start the upgrade a click asks for: the loading mark while the window's script
/// runs, and nothing waited for - the script posts its own refresh when it ends,
/// which is what draws the count or the failure mark.
fn upgrade(io: std.Io, gpa: std.mem.Allocator, store: *state.Store) anyerror!void {
    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    try render(&client, loading());

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const brew = exec.path(arena, "brew") catch |err| return fail(io, store, &client, err);
    const shell = exec.path(arena, "zsh") catch |err| return fail(io, store, &client, err);
    const kxdesk = clientPath(arena) catch |err| return fail(io, store, &client, err);

    var log_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = kitty.scratchPath(io, &log_buffer, run_terminal, log_suffix) catch |err|
        return fail(io, store, &client, err);
    var status_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const status_path = kitty.scratchPath(io, &status_buffer, run_terminal, status_suffix) catch |err|
        return fail(io, store, &client, err);

    // A result the daemon never read would be taken for this run's; it is the
    // script's to write, and this one has not run yet.
    std.Io.Dir.deleteFileAbsolute(io, status_path) catch {};

    // The shell is named twice: once to run the script, and once as its `$0`,
    // which is how the user's zsh configuration finds the zsh it is running.
    const command = [_][]const u8{
        shell, "-l", "-i", "-c", run_script, shell, brew, log_path, status_path, kxdesk,
    };
    kitty.startHidden(io, arena, run_terminal, command[0..]) catch |err|
        return fail(io, store, &client, err);
}

/// What a click whose run could not even start leaves behind: the error's name
/// where the terminal would have printed it, and the failure mark, so that the
/// item does not sit on the loading mark until its next clock.
fn fail(io: std.Io, store: *state.Store, client: *sb.Client, err: anyerror) !void {
    log.warn("brew upgrade could not start: {s}", .{@errorName(err)});
    keep(io, store, @errorName(err));
    return render(client, errored());
}

/// The binary a shell in the terminal runs to post the refresh: this process's
/// own, so that the client and the daemon are the same version. A daemon that
/// cannot name itself falls back to the `kxdesk` a PATH would find.
fn clientPath(arena: std.mem.Allocator) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (platform.kx_self_path(&buffer, buffer.len)) {
        return arena.dupe(u8, std.mem.sliceTo(&buffer, 0));
    }
    return exec.path(arena, "kxdesk");
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

/// Take a run's result off its terminal and into the item: the status the script
/// left decides whether the log is a failure to keep or a run that clears the last
/// one. A status file that is not there is a run that has not ended, or one the
/// daemon was not up to hear; both leave the item as it is.
fn settle(io: std.Io, arena: std.mem.Allocator, store: *state.Store) void {
    var status_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const status_path = kitty.scratchPath(io, &status_buffer, run_terminal, status_suffix) catch
        return;

    const text = std.Io.Dir.cwd().readFileAlloc(io, status_path, arena, .limited(16)) catch
        return;
    std.Io.Dir.deleteFileAbsolute(io, status_path) catch {};

    const code = std.fmt.parseInt(u8, std.mem.trim(u8, text, " \t\r\n"), 10) catch return;
    if (code == 0) {
        store.unset(io, error_key) catch |err| log.warn(
            "could not clear the brew failure: {s}",
            .{@errorName(err)},
        );
        return;
    }

    var log_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const log_path = kitty.scratchPath(io, &log_buffer, run_terminal, log_suffix) catch return;
    const failure = std.Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(max_failure_bytes)) catch {
        keep(io, store, "the upgrade failed and its output could not be read");
        return;
    };
    keep(io, store, failure);
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
    const count = try outdatedCount(io, gpa);

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

/// How many packages `brew outdated` lists, read through the user's login shell so
/// that Homebrew sees the trust file `brew trust` writes. Without the shell - or
/// when its startup says too much for the bound - the direct command is still
/// worth running: it is the count the daemon had before, and an item that
/// undercounts a third-party tap is better than one that says nothing.
fn outdatedCount(io: std.Io, gpa: std.mem.Allocator) !usize {
    const brew = try exec.path(gpa, "brew");
    defer gpa.free(brew);

    if (exec.path(gpa, "zsh") catch null) |shell| {
        defer gpa.free(shell);
        const argv = [_][]const u8{ shell, "-l", "-i", "-c", count_script, shell, brew, "outdated" };
        if (std.process.run(gpa, io, .{
            .argv = argv[0..],
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        })) |result| {
            defer gpa.free(result.stdout);
            defer gpa.free(result.stderr);
            if (countFrom(result.stdout)) |count| return count;
        } else |_| {}
    }

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ brew, "outdated" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return std.mem.count(u8, result.stdout, "\n");
}

/// The count out of the shell's marked line: `wc -l` pads its number, and the
/// shell's own startup may have printed before the marker.
fn countFrom(output: []const u8) ?usize {
    const at = std.mem.indexOf(u8, output, count_marker) orelse return null;
    const rest = output[at + count_marker.len ..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    return std.fmt.parseInt(usize, std.mem.trim(u8, rest[0..end], " \t"), 10) catch null;
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
