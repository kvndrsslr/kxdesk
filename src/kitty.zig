//! The kitty quick access terminals: the configurations they live in, the socket
//! they are toggled over, and the one process a terminal that is not running
//! costs.
//!
//! A terminal is two files under the kitty configuration directory: the base that
//! every one of them inherits, and its own, which is named by the word a key
//! binding spells. Hiding and showing one that is already running is a kitty
//! remote control command to the socket this gives it on start-up - the interface
//! kitty documents for controlling a panel from outside, and one this daemon
//! names itself - so a key press costs a message rather than a process. Only a
//! terminal that is not running needs one, and then it is kitty's own
//! `kitten quick_access_terminal` that draws the window.

const std = @import("std");

const Context = @import("context.zig").Context;
const exec = @import("exec.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const timeouts = @import("timeouts.zig");

/// The shared base every terminal inherits, and the directory the terminals' own
/// configurations live in: both beside `kitty.conf`, in the kitty configuration
/// directory.
const base_file = "quick-access-terminal-base.conf";
const terminal_directory = "quick-access-terminals";
const terminal_suffix = ".conf";

/// Where a terminal's control socket is made: one directory per user under the
/// temporary directory, named the way yabai's own socket is, so that a second
/// user's daemon cannot collide with this one's. The directory is the owner's
/// alone, because a remote control command is accepted from the socket in it and
/// from nothing else.
const socket_root = "/tmp/kxdesk-qat";
const socket_mode: std.Io.File.Permissions = @enumFromInt(0o700);

/// kitty appends the process id to a socket path it reads from configuration
/// rather than from the command line, and the socket a terminal is given is an
/// override - so what a terminal's socket is called is not what it was named, and
/// finding a running terminal means looking for one rather than remembering one.
/// Nothing else is appended, which is what keeps two names apart: the socket of a
/// terminal called `bt` is `bt-<pid>`, and never one of `btop`'s.
const pid_separator = '-';

/// The two commands this asks for, framed in kitty's remote control protocol: one
/// JSON object between two escape sequences, and the same framing around the
/// answer. They are the two the panel kitten's own `--toggle-visibility` ends up
/// asking for, over the whole instance, as that path does - a quick access
/// terminal is one instance per name, so there is one OS window to act on.
///
/// The version is claimed as the release that added the panel and the
/// `resize-os-window` command: kitty refuses a client that claims to be newer
/// than it is, and claiming the floor is what keeps this working against every
/// kitty new enough to have a quick access terminal at all.
///
/// A terminal that has just been started is shown rather than toggled: its window
/// is drawn before it is seen, and "is it up yet" cannot be answered by hiding it.
const toggle_request =
    "\x1bP@kitty-cmd{\"cmd\":\"resize-os-window\",\"version\":[0,42,0]," ++
    "\"payload\":{\"match\":\"all\",\"action\":\"toggle-visibility\"}}\x1b\\";
const show_request =
    "\x1bP@kitty-cmd{\"cmd\":\"resize-os-window\",\"version\":[0,42,0]," ++
    "\"payload\":{\"match\":\"all\",\"action\":\"show\"}}\x1b\\";
const reply_prefix = "\x1bP@kitty-cmd";
const reply_terminator = "\x1b\\";

/// An answer is a small object, and anything longer than this is not one: the
/// bound is what keeps a socket belonging to something else from making this
/// daemon allocate.
const reply_bytes = 1024;

/// Show or hide the named terminal: what the `term toggle` command runs, and what
/// the load graphs' click runs.
pub fn toggleNamed(io: std.Io, arena: std.mem.Allocator, name: []const u8) !void {
    // Checked here as well as by `cli.validate`, which is what a client's word
    // and a binding's word are refused by: a terminal this would start is a
    // window with a configuration of its own, and one without is a window
    // nothing configured.
    if (!configured(io, name)) return error.NotConfigured;

    if (try ask(io, arena, name, toggle_request)) return;

    try start(io, arena, name);

    // The window comes up hidden - kitty draws and lays it out before it is seen
    // - so the ask that follows is what shows it, and it is the same ask the next
    // key press makes.
    var waited: u32 = 0;
    while (waited < timeouts.terminal_timeout_ms) : (waited += timeouts.start_poll_ms) {
        if (try ask(io, arena, name, show_request)) return;
        std.Io.sleep(
            io,
            std.Io.Duration.fromMilliseconds(timeouts.start_poll_ms),
            .awake,
        ) catch {};
    }

    log.warn("quick access terminal {s} did not answer on its socket", .{name});
    return error.TerminalNotStarted;
}

/// The `term toggle` command: the word names the terminal, and the toggle itself
/// is `toggleNamed`. It answers with nothing, like every other action.
pub fn toggle(context: *Context, args: []const []const u8) ![]const u8 {
    const name = if (args.len > 1) args[1] else return error.MissingArgument;
    try toggleNamed(context.io, context.arena, name);
    return "";
}

/// Whether a terminal is configured: the word is one a terminal can be named and
/// its own configuration is there. This is what a typo is refused by, so that a
/// binding that names nothing is a line in the log rather than a key that starts
/// an unconfigured window.
pub fn configured(io: std.Io, name: []const u8) bool {
    if (!isTerminalName(name)) return false;

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = terminalFile(&buffer, name) orelse return false;
    return isFile(io, path);
}

/// The name of every terminal configured, sorted: the `.conf` files in the
/// terminals directory, without their suffix. A directory that is not there is a
/// machine with no terminals yet, which is a completion with nothing to offer
/// rather than a failure.
pub fn names(io: std.Io, arena: std.mem.Allocator) []const []const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = terminalDirectory(&directory_buffer) orelse return &.{};

    var opened = std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true }) catch return &.{};
    defer opened.close(io);

    var list = std.ArrayList([]const u8).empty;
    var entries = opened.iterate();
    while (entries.next(io) catch return list.items) |entry| {
        if (entry.kind == .directory) continue;
        list.append(arena, terminalName(entry.name) orelse continue) catch return list.items;
    }

    std.mem.sort([]const u8, list.items, {}, lessThan);
    return list.items;
}

/// Whether a directory entry is the socket of the named terminal: kitty appends
/// the process id and nothing else, so an entry is `<name>-<digits>`.
pub fn isSocketOf(entry: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, entry, name)) return false;

    const rest = entry[name.len..];
    if (rest.len < 2 or rest[0] != pid_separator) return false;
    for (rest[1..]) |character| {
        if (!std.ascii.isDigit(character)) return false;
    }
    return true;
}

/// The JSON of one answer, out of the escape sequences kitty frames it in, or
/// null when what arrived is not an answer at all.
pub fn replyPayload(reply: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, reply, reply_prefix)) return null;
    if (!std.mem.endsWith(u8, reply, reply_terminator)) return null;
    return reply[reply_prefix.len .. reply.len - reply_terminator.len];
}

/// Ask the terminal that is running to hide or show itself, answering whether one
/// was there to ask. A terminal that is not running is not a failure: it is the
/// answer that says to start one.
fn ask(io: std.Io, arena: std.mem.Allocator, name: []const u8, request: []const u8) !bool {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = socketDirectory(&directory_buffer) orelse return false;

    // A directory that is not there is a machine whose terminals have never been
    // started, which is the same answer as no socket inside it.
    var opened = std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true }) catch
        return false;
    defer opened.close(io);

    var entries = opened.iterate();
    while (entries.next(io) catch return false) |entry| {
        if (!isSocketOf(entry.name, name)) continue;

        // The sockets are looked for rather than remembered, because this daemon
        // may well not be the one that started the window - a restarted daemon,
        // or a terminal started before this code was, are the ordinary cases -
        // and a socket left behind by a terminal that is gone is skipped by
        // failing to connect to it.
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ directory, entry.name }) catch
            continue;

        const reply = send(arena, path, request) orelse continue;
        if (reply.ok) return true;

        log.warn("quick access terminal {s} refused: {s}", .{
            name, reply.@"error" orelse "no reason given",
        });
        return error.TerminalRefused;
    }
    return false;
}

/// One remote control command to a socket, answering what came back: null when
/// nothing did, which is a socket left behind rather than a failure.
fn send(arena: std.mem.Allocator, path: [:0]const u8, request: []const u8) ?Reply {
    var response: [reply_bytes]u8 = undefined;
    const size = platform.kx_unix_reply(
        path.ptr,
        request.ptr,
        request.len,
        reply_terminator.ptr,
        reply_terminator.len,
        &response,
        response.len,
        timeouts.socket_reply_timeout_ms,
    );
    if (size < 0) return null;

    const payload = replyPayload(response[0..@intCast(size)]) orelse return null;
    return std.json.parseFromSliceLeaky(Reply, arena, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch null;
}

/// Start a terminal: the QAT kitten, which is the only thing that can make the
/// window, with this terminal's configurations and the socket the next key press
/// reaches it on.
fn start(io: std.Io, arena: std.mem.Allocator, name: []const u8) !void {
    // The kitten binary, not `kitty +kitten`: the quick access terminal is a Go
    // kitten, and only `kitten` dispatches to it - the `+kitten` route reaches
    // the Python modules, where this one is a stub that says to use the other.
    const kitten = try exec.path(arena, "kitten");

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = socketDirectory(&directory_buffer) orelse return error.PathTooLong;
    // kitty binds into the directory and does not make it, and nothing else makes
    // it either: `PathAlreadyExists` is this terminal's predecessor, or a
    // terminal of another name's.
    std.Io.Dir.createDirAbsolute(io, directory, socket_mode) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var listen_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const listen = std.fmt.bufPrint(
        &listen_buffer,
        "kitty_override=listen_on=unix:{s}/{s}",
        .{ directory, name },
    ) catch return error.PathTooLong;

    var arguments = std.ArrayList([]const u8).empty;
    try arguments.appendSlice(arena, &.{
        kitten,
        "quick_access_terminal",
        // One instance per terminal, named by the word a binding spells: it is
        // what keeps two terminals' windows, and their sockets, apart.
        "--instance-group",
        name,
        // The socket is named here rather than in a configuration, so that it is
        // this daemon's to find rather than the user's to keep in step. kitty
        // takes a kitty option through the terminal's configuration, which is
        // where these two go, and they are passed last so that they stand
        // whatever a terminal's own configuration says. Remote control is scoped
        // to the socket alone.
        "-o",
        listen,
        "-o",
        "kitty_override=allow_remote_control=socket-only",
    });

    // The base is passed first, so that the terminal's own file wins wherever the
    // two disagree. A machine without one is a terminal that stands on the
    // built-in defaults, which is not worth refusing a toggle over.
    var base_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (baseFile(&base_buffer)) |base| {
        if (isFile(io, base)) try arguments.appendSlice(arena, &.{ "-c", base });
    }

    var terminal_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const terminal = terminalFile(&terminal_buffer, name) orelse return error.PathTooLong;
    try arguments.appendSlice(arena, &.{ "-c", terminal });

    try exec.spawn(arena, arguments.items);
}

/// The kitty configuration directory: `KITTY_CONFIG_DIRECTORY`, kitty's own
/// escape hatch, when it is set, and `~/.config/kitty` otherwise.
fn configDirectory(buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var environment: [std.fs.max_path_bytes]u8 = undefined;
    if (platform.kx_env("KITTY_CONFIG_DIRECTORY", &environment, environment.len)) {
        const value = std.mem.sliceTo(&environment, 0);
        if (value.len > 0) return std.fmt.bufPrint(buffer, "{s}", .{value}) catch null;
    }
    if (platform.kx_env("HOME", &environment, environment.len)) {
        const home = std.mem.sliceTo(&environment, 0);
        if (home.len > 0) {
            return std.fmt.bufPrint(buffer, "{s}/.config/kitty", .{home}) catch null;
        }
    }
    return null;
}

/// The path of the shared base configuration, in `buffer`.
fn baseFile(buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = configDirectory(&directory_buffer) orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/" ++ base_file, .{directory}) catch null;
}

/// The directory the terminals' own configurations live in, in `buffer`.
fn terminalDirectory(buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = configDirectory(&directory_buffer) orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/" ++ terminal_directory, .{directory}) catch null;
}

/// The path of a terminal's own configuration, in `buffer`.
fn terminalFile(buffer: *[std.fs.max_path_bytes]u8, name: []const u8) ?[]const u8 {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = terminalDirectory(&directory_buffer) orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/{s}" ++ terminal_suffix, .{ directory, name }) catch null;
}

/// The directory the terminals' sockets are made in, in `buffer`.
fn socketDirectory(buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}-{d}", .{ socket_root, platform.kx_uid() }) catch null;
}

/// The terminal a file in the terminals directory configures, or null when it is
/// not a terminal's configuration at all: a terminal's name is its file's name.
fn terminalName(entry: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, entry, terminal_suffix)) return null;

    const name = entry[0 .. entry.len - terminal_suffix.len];
    return if (isTerminalName(name)) name else null;
}

/// Whether a word can be a terminal's name: a file's name, and one a socket can
/// be made for. Both halves matter - a name with a separator in it names no file
/// in the terminals directory, and a socket is what the toggle is made of.
fn isTerminalName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |character| {
        // A control character would be read as the end of the configuration line
        // the socket is spelled into, and would break the line-based completion
        // protocol this name is offered through.
        if (character == '/' or character == '\\' or std.ascii.isControl(character)) return false;
    }
    return true;
}

/// Whether a path is a file. A directory that happens to be named like one is
/// not a configuration, and neither is a path this cannot look at.
fn isFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn lessThan(_: void, first: []const u8, second: []const u8) bool {
    return std.mem.lessThan(u8, first, second);
}

/// What kitty answered, under the names the answer uses on the wire.
const Reply = struct {
    ok: bool = false,
    @"error": ?[]const u8 = null,
};
