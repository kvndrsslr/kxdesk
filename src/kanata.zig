//! kanata's channel, and the actions its messages name.
//!
//! The key bindings live in kanata and the commands they run here: a binding
//! pushes a message, kanata broadcasts it to its TCP clients, and this turns it
//! into an action run as the user, in the user's session. Three shapes are acted
//! on - `{"MessagePush":{"message":[...]}}`, `{"LayerChange":{"new":"op"}}` and
//! `{"ConfigFileReload":…}` - and a pushed name is parsed and checked against the
//! verbs in `parseAction` before anything runs.

const std = @import("std");

const Context = @import("context.zig").Context;
const exec = @import("exec.zig");
const log = @import("log.zig");
const mode_indicator = @import("mode_indicator.zig");
const platform = @import("platform.zig");
const pomodoro = @import("pomodoro.zig");
const sb = @import("sb.zig");
const state = @import("store.zig");
const yabai = @import("yabai.zig");
const yabai_ops = @import("yabai_ops.zig");

/// Where kanata's server listens unless the store says otherwise. The launchd
/// job passes the same address to kanata with `-p`, so the two agree by
/// default; either side can be moved with `kxdesk state set kanata.port …`,
/// which is why the value is read rather than compiled in.
pub const default_host = "127.0.0.1";
pub const default_port = 4038;

const host_key = "kanata.host";
const port_key = "kanata.port";

/// How long to wait before connecting again. Not an error path: kanata is a
/// daemon that starts at login and is stopped, upgraded and restarted, and the
/// channel simply is not there while it is not running.
const reconnect_delay_ms = 2000;

/// Largest message we will hold. kanata's own are a few hundred bytes; the
/// bound is here so that whatever is on the other end of the port cannot make
/// this daemon allocate.
const max_message = 4096;

/// Largest read at once. Deliberately unrelated to `max_message`: two messages
/// can arrive in one read, and one message can arrive over several.
const read_chunk = 1024;

/// The listening channel, so that `kxdesk kanata status` can report on it. The
/// thread that owns it has no other way to be reached, the same single live
/// reference `main.zig` keeps for the receive loop.
var active: std.atomic.Value(?*Listener) = .init(null);

/// What a pushed message can name.
pub const Action = union(enum) {
    cycle_space_windows: Sequence,
    cycle_displays: Sequence,
    cycle_display_spaces: Sequence,
    refresh_yabai,
    window_swap: yabai_ops.Direction,
    window_warp: yabai_ops.Direction,
    window_insert: yabai_ops.Direction,
    window_insert_space: yabai_ops.Direction,
    window_insert_stack_space,
    window_to_display: u8,
    display_focus: u8,
    space_to_display: yabai_ops.Direction,
    space_layout: yabai_ops.Layout,
    space_rotate: u16,
    space_balance,
    space_toggle_show_desktop,
    window_focus: FocusTarget,
    window_toggle: yabai_ops.WindowToggle,
    window_fill_display,
    copy_windows,
    screen_capture,
    open_app: App,
    dump_path,
};

/// Which way a cycle goes. The bindings that run backwards spell `reverse`; the
/// others say nothing at all.
pub const Sequence = enum { forward, reverse };

/// What `yabai:window-focus` focuses.
pub const FocusTarget = enum { recent, same_app };

/// What `app:open` opens.
pub const App = enum { code, kitty, arc_debug };

/// Why a message was refused. Every one of these is a line in the log and
/// nothing else: a binding that cannot be carried out must not be able to stop
/// the channel, and the log is where a mistyped name becomes visible.
pub const ParseError = error{ InvalidMessage, UnknownAction, MissingArgument, BadArgument };

/// The name a pushed message carried, out of the shape kanata wrapped it in.
///
/// `simple_sexpr_to_json_array` turns the action's arguments into a JSON array, so
/// what arrives for `(push-msg "debug:dump-path")` is `["debug:dump-path"]`; the
/// bare string its protocol documents is read as well. A list of several names, a
/// nested list, a number, or a name that is not a string at all is refused rather
/// than guessed at.
pub fn pushedName(message: std.json.Value) ParseError![]const u8 {
    if (message == .string) return message.string;
    if (message == .array) {
        const items = message.array.items;
        if (items.len == 1 and items[0] == .string) return items[0].string;
    }
    return error.InvalidMessage;
}

/// Read a name as `namespace:verb[:argument]`.
///
/// The namespace, the verb and the argument are all checked here, before
/// anything runs. The argument is checked against the verb that takes it - a
/// direction, a display number, one of a few words - because that is the part a
/// config file can get wrong, and because a verb whose argument is unread is a
/// verb that would otherwise reach yabai as a command it refuses.
pub fn parseAction(name: []const u8) ParseError!Action {
    var parts = std.mem.splitScalar(u8, name, ':');
    const namespace = parts.next() orelse return error.UnknownAction;
    const verb = parts.next() orelse return error.UnknownAction;
    const argument = parts.next();
    // A fourth segment is not a longer name, it is a name this cannot read.
    if (parts.next() != null) return error.UnknownAction;

    if (std.mem.eql(u8, namespace, "kxdesk")) {
        if (std.mem.eql(u8, verb, "cycle-space-windows")) {
            return .{ .cycle_space_windows = try sequence(argument) };
        }
        if (std.mem.eql(u8, verb, "cycle-displays")) {
            return .{ .cycle_displays = try sequence(argument) };
        }
        if (std.mem.eql(u8, verb, "cycle-display-spaces")) {
            return .{ .cycle_display_spaces = try sequence(argument) };
        }
        if (std.mem.eql(u8, verb, "refresh-yabai")) return noArgument(argument, .refresh_yabai);
        return error.UnknownAction;
    }

    if (std.mem.eql(u8, namespace, "yabai")) {
        if (std.mem.eql(u8, verb, "window-swap")) return .{ .window_swap = try direction(argument) };
        if (std.mem.eql(u8, verb, "window-warp")) return .{ .window_warp = try direction(argument) };
        if (std.mem.eql(u8, verb, "window-insert")) {
            return .{ .window_insert = try direction(argument) };
        }
        if (std.mem.eql(u8, verb, "window-insert-space")) {
            return .{ .window_insert_space = try direction(argument) };
        }
        if (std.mem.eql(u8, verb, "window-insert-stack-space")) {
            return noArgument(argument, .window_insert_stack_space);
        }
        if (std.mem.eql(u8, verb, "window-to-display")) {
            return .{ .window_to_display = try displayIndex(argument) };
        }
        if (std.mem.eql(u8, verb, "display-focus")) {
            return .{ .display_focus = try displayIndex(argument) };
        }
        if (std.mem.eql(u8, verb, "space-to-display")) {
            return .{ .space_to_display = try direction(argument) };
        }
        if (std.mem.eql(u8, verb, "space-layout")) return .{ .space_layout = try layout(argument) };
        if (std.mem.eql(u8, verb, "space-rotate")) return .{ .space_rotate = try degrees(argument) };
        if (std.mem.eql(u8, verb, "space-balance")) return noArgument(argument, .space_balance);
        if (std.mem.eql(u8, verb, "space-toggle")) {
            try expectWord(argument, "show-desktop");
            return .space_toggle_show_desktop;
        }
        if (std.mem.eql(u8, verb, "window-focus")) {
            return .{ .window_focus = try focusTarget(argument) };
        }
        if (std.mem.eql(u8, verb, "window-toggle")) {
            return .{ .window_toggle = try windowToggle(argument) };
        }
        if (std.mem.eql(u8, verb, "window-fill-display")) {
            return noArgument(argument, .window_fill_display);
        }
        if (std.mem.eql(u8, verb, "copy-windows")) return noArgument(argument, .copy_windows);
        return error.UnknownAction;
    }

    if (std.mem.eql(u8, namespace, "app")) {
        if (std.mem.eql(u8, verb, "open")) return .{ .open_app = try app(argument) };
        return error.UnknownAction;
    }

    if (std.mem.eql(u8, namespace, "screen")) {
        if (std.mem.eql(u8, verb, "capture")) return noArgument(argument, .screen_capture);
        return error.UnknownAction;
    }

    if (std.mem.eql(u8, namespace, "debug")) {
        if (std.mem.eql(u8, verb, "dump-path")) return noArgument(argument, .dump_path);
        return error.UnknownAction;
    }

    return error.UnknownAction;
}

/// A verb that takes no argument at all, and refuses one.
fn noArgument(argument: ?[]const u8, action: Action) ParseError!Action {
    if (argument != null) return error.BadArgument;
    return action;
}

/// A verb that takes exactly one word, which is this one.
fn expectWord(argument: ?[]const u8, word: []const u8) ParseError!void {
    const text = argument orelse return error.MissingArgument;
    if (!std.mem.eql(u8, text, word)) return error.BadArgument;
}

fn sequence(argument: ?[]const u8) ParseError!Sequence {
    const text = argument orelse return .forward;
    return std.meta.stringToEnum(Sequence, text) orelse error.BadArgument;
}

fn direction(argument: ?[]const u8) ParseError!yabai_ops.Direction {
    const text = argument orelse return error.MissingArgument;
    return std.meta.stringToEnum(yabai_ops.Direction, text) orelse error.BadArgument;
}

/// A display number, as the bindings spell it: 1 to 4. The bound is checked so
/// that a mistyped one is a line in the log rather than a yabai call that fails
/// quietly - widening it is a one-line change here and in the config.
fn displayIndex(argument: ?[]const u8) ParseError!u8 {
    const text = argument orelse return error.MissingArgument;
    const index = std.fmt.parseInt(u8, text, 10) catch return error.BadArgument;
    if (index < 1 or index > 4) return error.BadArgument;
    return index;
}

fn layout(argument: ?[]const u8) ParseError!yabai_ops.Layout {
    const text = argument orelse return error.MissingArgument;
    return std.meta.stringToEnum(yabai_ops.Layout, text) orelse error.BadArgument;
}

fn degrees(argument: ?[]const u8) ParseError!u16 {
    const text = argument orelse return error.MissingArgument;
    return std.fmt.parseInt(u16, text, 10) catch return error.BadArgument;
}

/// The two words carry a hyphen, so they are matched by name rather than read
/// as an enum's tags - as the window toggles and the applications below are, for
/// the same reason.
fn focusTarget(argument: ?[]const u8) ParseError!FocusTarget {
    const text = argument orelse return error.MissingArgument;
    if (std.mem.eql(u8, text, "recent")) return .recent;
    if (std.mem.eql(u8, text, "same-app")) return .same_app;
    return error.BadArgument;
}

fn windowToggle(argument: ?[]const u8) ParseError!yabai_ops.WindowToggle {
    const text = argument orelse return error.MissingArgument;
    if (std.mem.eql(u8, text, "zoom-fullscreen")) return .zoom_fullscreen;
    if (std.mem.eql(u8, text, "native-fullscreen")) return .native_fullscreen;
    if (std.mem.eql(u8, text, "expose")) return .expose;
    if (std.mem.eql(u8, text, "float-sticky-topmost")) return .float_sticky_topmost;
    return error.BadArgument;
}

fn app(argument: ?[]const u8) ParseError!App {
    const text = argument orelse return error.MissingArgument;
    if (std.mem.eql(u8, text, "code")) return .code;
    if (std.mem.eql(u8, text, "kitty")) return .kitty;
    if (std.mem.eql(u8, text, "arc-debug")) return .arc_debug;
    return error.BadArgument;
}

/// Run what a message named.
///
/// Every failure is the caller's to log. A binding whose application has gone,
/// or whose yabai refuses the move, is a keystroke that did not do what it said
/// - not a reason for the channel to stop reading.
pub fn perform(context: *Context, action: Action) anyerror!void {
    switch (action) {
        // The helpers that already existed answer with the payload a client
        // would be sent - they are command implementations - and an action has
        // nobody to answer, so those payloads are dropped here rather than at
        // the call sites below.
        .cycle_space_windows => |value| {
            try discard(yabai_ops.cycleSpaceWindows(context, sequenceArgs(value)));
        },
        .cycle_displays => |value| {
            try discard(yabai_ops.cycleDisplays(context, sequenceArgs(value)));
        },
        .cycle_display_spaces => |value| {
            try discard(yabai_ops.cycleDisplaySpaces(context, sequenceArgs(value)));
        },
        .refresh_yabai => {
            // The old `op r` binding chained the two with `&&`, so the signals
            // are only re-provisioned once the rules are in place.
            try discard(yabai_ops.refreshRules(context, &.{}));
            try discard(yabai_ops.refreshSignals(context, &.{}));
        },
        .window_swap => |value| try yabai_ops.windowSwap(context, value),
        .window_warp => |value| try yabai_ops.windowWarp(context, value),
        .window_insert => |value| try yabai_ops.windowInsert(context, value),
        .window_insert_space => |value| try yabai_ops.windowInsertIntoSpace(context, value),
        .window_insert_stack_space => try yabai_ops.windowInsertIntoStack(context),
        .window_to_display => |value| try yabai_ops.windowToDisplay(context, value),
        .display_focus => |value| try yabai_ops.displayFocus(context, value),
        .space_to_display => |value| try yabai_ops.spaceToDisplay(context, value),
        .space_layout => |value| try yabai_ops.spaceLayout(context, value),
        .space_rotate => |value| try yabai_ops.spaceRotate(context, value),
        .space_balance => try yabai_ops.spaceBalance(context),
        .space_toggle_show_desktop => try yabai_ops.spaceToggleShowDesktop(context),
        .window_focus => |value| switch (value) {
            .recent => try yabai_ops.windowFocusRecent(context),
            .same_app => try yabai_ops.windowFocusSameApp(context),
        },
        .window_toggle => |value| try yabai_ops.windowToggle(context, value),
        .window_fill_display => try yabai_ops.windowFillDisplay(context),
        .copy_windows => try yabai_ops.copyWindows(context),
        .screen_capture => try screenCapture(context),
        .open_app => |value| try openApp(context, value),
        .dump_path => try dumpPath(context),
    }
}

/// Drop the payload a command-shaped helper answered with.
fn discard(result: anyerror![]const u8) anyerror!void {
    _ = try result;
}

/// The argument list the cycle commands read: they look for `--reverse`, and a
/// forward cycle is that flag's absence.
fn sequenceArgs(sequence_value: Sequence) []const []const u8 {
    return switch (sequence_value) {
        .forward => &.{},
        .reverse => &.{"--reverse"},
    };
}

/// `screencapture -ixc`: a selection of the screen, into the clipboard.
///
/// Detached rather than waited for: it lives as long as the user takes to drag
/// the rectangle, and this thread has a channel to keep reading. The old binding
/// ran it from a shell, which is also why it used to wait.
fn screenCapture(context: *Context) !void {
    const arena = context.arena;
    const capture = try exec.path(arena, "screencapture");
    try spawn(arena, &.{ capture, "-ixc" });
}

/// The applications the bindings open, with the arguments their bindings used to
/// spell: Arc on the debugging port `hyper ret` opened it on, kitty as a single
/// instance listening on the socket `kitty @` reaches.
fn openApp(context: *Context, application: App) !void {
    const arena = context.arena;

    switch (application) {
        .code => try spawn(arena, &.{ "/usr/bin/open", "-a", "Visual Studio Code" }),
        .arc_debug => try spawn(arena, &.{
            "/usr/bin/open", "-a", "Arc", "--args", "--remote-debugging-port=9222",
        }),
        .kitty => {
            // Resolved rather than assumed, like every other external command
            // here: the daemon runs under launchd, whose PATH has no Homebrew in
            // it.
            const kitty = try exec.path(arena, "kitty");
            var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (platform.kx_env("HOME", &home_buffer, home_buffer.len)) {
                const home = try arena.dupeZ(u8, std.mem.sliceTo(&home_buffer, 0));
                try spawn(arena, &.{
                    kitty, "-d", home, "--single-instance", "--listen-on", "unix:/tmp/mykitty",
                });
            } else {
                // Without a home to start in, kitty's own default is better than
                // a guess at one.
                try spawn(arena, &.{
                    kitty, "--single-instance", "--listen-on", "unix:/tmp/mykitty",
                });
            }
        },
    }
}

/// Launch an argument vector detached from this process, so that a keystroke's
/// application outlives the call that started it. `argv[0]` is a filesystem
/// path; nothing here goes through a shell.
fn spawn(arena: std.mem.Allocator, argv: []const []const u8) !void {
    const vector = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |argument, index| vector[index] = try arena.dupeZ(u8, argument);
    vector[argv.len] = null;
    if (platform.kx_spawn_detached(vector.ptr) < 0) return error.LaunchFailed;
}

/// Record the PATH this daemon runs things with, and where the channel stands,
/// where the old `hyper p` binding wrote. skhd recorded its own PATH there; what
/// can be wrong now is this side of the channel - the daemon runs under launchd,
/// whose PATH is not a login shell's, which is exactly why every external
/// command here is resolved rather than assumed.
fn dumpPath(context: *Context) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (platform.kx_env("PATH", &path_buffer, path_buffer.len))
        std.mem.sliceTo(&path_buffer, 0)
    else
        "(unset)";

    var report: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&report, "{s}\nlistener={s} handled={d}\n", .{
        path,
        connectionState(),
        handledCount(),
    }) catch return error.OutOfMemory;

    var file = try std.Io.Dir.createFileAbsolute(context.io, "/tmp/kanata-path", .{});
    defer file.close(context.io);
    try file.writeStreamingAll(context.io, text);
}

/// Whether the channel to kanata is up, for the report above and `status`.
fn connectionState() []const u8 {
    const listener = active.load(.monotonic) orelse return "not started";
    return if (listener.connected.load(.monotonic)) "connected" else "disconnected";
}

fn handledCount() u64 {
    const listener = active.load(.monotonic) orelse return 0;
    return listener.handled.load(.monotonic);
}

/// The mode indicator argument a layer's name stands for, or null for a layer
/// with no colour of its own.
///
/// The names are the ones `kanata.kbd` defines and the indices are the ones
/// `kxdesk set_mode_indicator` has always taken - the same call the skhd config
/// made on entering each mode. `-` is "no mode", which is the default layer: the
/// bar's space icons stop highlighting.
pub fn indicatorFor(layer: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, layer, "op")) return "1";
    if (std.mem.eql(u8, layer, "wmode")) return "2";
    if (std.mem.eql(u8, layer, "smode")) return "3";
    if (std.mem.eql(u8, layer, "default")) return "-";
    return null;
}

/// What a line turned out to be, so that `kxdesk kanata inject` can say.
pub const Handled = union(enum) {
    /// A binding's action ran.
    action: Action,
    /// The mode indicator was set for this layer.
    layer: []const u8,
    /// The config was reloaded, which clears the indicator.
    reload,
    /// A message with nothing here to do: kanata sends several kinds, and the
    /// ones nobody asked for are not errors.
    ignored,
};

/// The messages this daemon acts on, out of the several kanata sends.
///
/// Every field is optional and unknown ones are ignored, because the rest -
/// `HelloOk`, `Error`, the layer and fake-key queries - are answers to questions
/// nobody here asks.
const Incoming = struct {
    LayerChange: ?struct { new: []const u8 } = null,
    ConfigFileReload: ?struct { new: []const u8 } = null,
    /// A `serde_json::Value`, not a string, because that is what the field is on
    /// the wire: `pushedName` reads the wrapper kanata put around the name.
    MessagePush: ?struct { message: std.json.Value } = null,
};

/// Act on one line of JSON, as kanata sent it.
pub fn handleLine(context: *Context, line: []const u8) !Handled {
    const message = std.json.parseFromSliceLeaky(Incoming, context.arena, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.InvalidMessage;

    if (message.MessagePush) |push| {
        const action = try parseAction(try pushedName(push.message));
        try perform(context, action);
        return .{ .action = action };
    }

    if (message.LayerChange) |change| {
        const indicator = indicatorFor(change.new) orelse return .ignored;
        _ = try mode_indicator.setMode(context, &.{indicator});
        return .{ .layer = change.new };
    }

    // A reload returns to the default layer, so the highlight goes with it.
    if (message.ConfigFileReload != null) {
        _ = try mode_indicator.setMode(context, &.{"-"});
        return .reload;
    }

    return .ignored;
}

/// Newline-delimited JSON arriving over a stream.
///
/// The socket hands over arbitrary chunks: one message can arrive in two reads
/// and two can arrive in one, so the partial tail is kept and read again when
/// the rest of it turns up. A line longer than the buffer is dropped whole
/// rather than truncated - half a message is not a message, and parsing it would
/// report something that was never sent.
pub const Framer = struct {
    buffer: [max_message]u8 = undefined,
    len: usize = 0,
    /// Set while the line being read has outgrown the buffer, so that the rest
    /// of it is skipped instead of being read as the start of the next one.
    discarding: bool = false,
    /// The line most recently handed out, so that it survives the compaction
    /// that `next` does to the buffer it was read from.
    line: [max_message]u8 = undefined,

    /// Add what was just read.
    ///
    /// The caller drains with `next` after every call, so what is held between
    /// calls is at most one incomplete line.
    pub fn feed(self: *Framer, chunk: []const u8) void {
        var remaining = chunk;

        if (self.discarding) {
            // The rest of a line that did not fit: everything up to and
            // including the newline that ends it, which may be in this chunk or
            // in one still to come.
            const newline = std.mem.indexOfScalar(u8, remaining, '\n') orelse return;
            self.discarding = false;
            remaining = remaining[newline + 1 ..];
        }

        const room = self.buffer.len - self.len;
        if (remaining.len <= room) {
            @memcpy(self.buffer[self.len..][0..remaining.len], remaining);
            self.len += remaining.len;
            return;
        }

        // The line does not fit, so what is held is a fragment of it and worth
        // nothing - half a message is not a message. It goes, and the rest of
        // the line goes with it: up to the newline that ends it, which may still
        // be in this chunk.
        self.len = 0;
        const newline = std.mem.indexOfScalar(u8, remaining[room..], '\n') orelse {
            self.discarding = true;
            return;
        };
        self.feed(remaining[room + newline + 1 ..]);
    }

    /// The next complete line without its newline, or null when the rest of one
    /// has not arrived yet. Valid until the next call.
    pub fn next(self: *Framer) ?[]const u8 {
        const newline = std.mem.indexOfScalar(u8, self.buffer[0..self.len], '\n') orelse
            return null;

        const line = self.buffer[0..newline];
        @memcpy(self.line[0..line.len], line);

        const rest = self.len - newline - 1;
        std.mem.copyForwards(u8, self.buffer[0..rest], self.buffer[newline + 1 .. self.len]);
        self.len = rest;

        return self.line[0..line.len];
    }
};

/// What the channel needs from the daemon: what a command gets, minus the parts
/// it must not touch - the receive loop's bar client, and the pomodoro timer,
/// which the receive loop ticks.
pub const Deps = struct {
    io: std.Io,
    store: *state.Store,
    yabai_client: *yabai.Client,
    pomodoro: *pomodoro.Timer,
    bar_present: *std.atomic.Value(bool),
    event_service: []const u8,
    started: std.Io.Timestamp,
};

pub const Listener = struct {
    gpa: std.mem.Allocator,
    deps: Deps,
    host: [:0]const u8,
    port: u16,

    /// Whether the channel is up, and how many messages have been acted on.
    /// Written by the reading thread and read by `kxdesk kanata status`, which
    /// runs on another one.
    connected: std.atomic.Value(bool) = .init(false),
    handled: std.atomic.Value(u64) = .init(0),

    /// Start reading kanata's channel on a thread of its own.
    ///
    /// The thread is never joined: it lives exactly as long as the daemon does,
    /// and it is the daemon's only way to hear from kanata.
    pub fn start(gpa: std.mem.Allocator, deps: Deps) !void {
        const self = try gpa.create(Listener);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .deps = deps,
            .host = try resolveHost(gpa, deps.io, deps.store),
            .port = resolvePort(deps.io, deps.store),
        };
        active.store(self, .monotonic);

        const thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            active.store(null, .monotonic);
            return err;
        };
        thread.detach();
    }

    /// Connect, read until the connection ends, and do it again - for as long as
    /// the daemon lives. kanata being down is an ordinary state, so only the
    /// first failure of a run is worth a line.
    fn run(self: *Listener) void {
        var reported = false;

        while (true) {
            const fd = platform.kx_tcp_connect(self.host.ptr, self.port);
            if (fd < 0) {
                if (!reported) {
                    log.warn("kanata is not listening on {s}:{d}", .{
                        self.host, self.port,
                    });
                    reported = true;
                }
                std.Io.sleep(
                    self.deps.io,
                    std.Io.Duration.fromMilliseconds(reconnect_delay_ms),
                    .awake,
                ) catch {};
                continue;
            }

            // Once per connection. A channel that opens is worth a line - it is
            // how a kanata restart becomes visible - while a peer that keeps
            // refusing is not worth one each time.
            log.warn("kanata channel open on {s}:{d}", .{
                self.host, self.port,
            });
            self.connected.store(true, .monotonic);

            var framer = Framer{};
            var chunk: [read_chunk]u8 = undefined;
            while (true) {
                // 0 is kanata closing the connection - a restart, or a stop -
                // and -1 a socket that failed; either way this connection is
                // over and the next attempt is a fresh one.
                const read = platform.kx_tcp_read(fd, &chunk, chunk.len);
                if (read <= 0) break;
                framer.feed(chunk[0..@intCast(read)]);
                while (framer.next()) |line| self.act(line);
            }

            self.connected.store(false, .monotonic);
            platform.kx_tcp_close(fd);
            // Whatever happens next is a new fact about a new connection, and
            // worth saying once.
            reported = false;
        }
    }

    /// Act on one line, in an arena and a bar channel of its own.
    ///
    /// The client has to be this thread's: the receive loop shares its own and
    /// must not see a batch it did not build. The arena is per message for the
    /// same reason a command's is per request - whatever an action allocates is
    /// handed back when the message is done, rather than growing a buffer that
    /// never ends.
    fn act(self: *Listener, line: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();

        const arena = arena_state.allocator();
        var bar = sb.Client.init(arena, sb.sketchybar_service);
        defer bar.deinit();

        var context = Context{
            .arena = arena,
            .io = self.deps.io,
            .bar = &bar,
            .yabai = self.deps.yabai_client,
            .pomodoro = self.deps.pomodoro,
            .store = self.deps.store,
            .bar_present = self.deps.bar_present,
            .event_service = self.deps.event_service,
            .started = self.deps.started,
        };

        _ = handleLine(&context, line) catch |err| {
            log.warn("kanata message '{s}' failed: {s}", .{
                line, @errorName(err),
            });
            return;
        };
        _ = self.handled.fetchAdd(1, .monotonic);
    }
};

/// Where kanata's server is: the store's value when one has been set, and the
/// address the launchd job passes kanata otherwise. Read per connection - the
/// reading thread's and a tap's alike - so the two cannot disagree.
fn resolveHost(gpa: std.mem.Allocator, io: std.Io, store: *state.Store) ![:0]const u8 {
    var buffer: [128]u8 = undefined;
    if (store.getText(io, host_key, &buffer) catch null) |text| {
        if (text.len > 0) return gpa.dupeZ(u8, text);
    }
    return gpa.dupeZ(u8, default_host);
}

fn resolvePort(io: std.Io, store: *state.Store) u16 {
    var buffer: [16]u8 = undefined;
    const text = store.getText(io, port_key, &buffer) catch return default_port;
    if (text) |value| {
        const port = std.fmt.parseInt(u16, std.mem.trim(u8, value, " \n"), 10) catch
            return default_port;
        if (port != 0) return port;
    }
    return default_port;
}

/// One line about the channel, for `kxdesk kanata status`.
pub fn status(arena: std.mem.Allocator) ![]const u8 {
    const listener = active.load(.monotonic) orelse
        return "kanata channel: not started";

    return std.fmt.allocPrint(arena, "kanata channel: {s} {s}:{d} handled={d}", .{
        if (listener.connected.load(.monotonic)) "connected to" else "waiting for",
        listener.host,
        listener.port,
        listener.handled.load(.monotonic),
    });
}

/// `{"ActOnFakeKey":{"name":"…","action":"Tap"}}` plus the newline the protocol's
/// line framing expects; the name is written between the two verbatim.
const fake_key_prefix = "{\"ActOnFakeKey\":{\"name\":\"";
const fake_key_suffix = "\",\"action\":\"Tap\"}}\n";

/// `{"MessagePush":{"message":["…"]}}`, the wrapper kanata puts around a pushed
/// name; the name is written between the two verbatim.
const push_prefix = "{\"MessagePush\":{\"message\":[\"";
const push_suffix = "\"]}}";

/// Press one of the fake keys the config defines, over a connection of its own.
///
/// The fallback for a space yabai will not focus is a Mission Control arrow key,
/// and the protocol's only way to output a key is a fake key: `kanata.kbd` names
/// the two chords and this asks for one, as the user, in the session.
///
/// A connection made and dropped per tap: the reading thread owns its socket and
/// never writes, so a tap cannot disturb the messages coming back, and an action
/// on a fake key is not acknowledged - a name kanata does not define is a line in
/// kanata's log and nothing on this side, which is why the names live next to the
/// `defvirtualkeys` that define them.
pub fn tapFakeKey(context: *Context, name: []const u8) !void {
    const host = try resolveHost(context.arena, context.io, context.store);
    const port = resolvePort(context.io, context.store);

    const fd = platform.kx_tcp_connect(host.ptr, port);
    if (fd < 0) return error.KanataUnreachable;
    defer platform.kx_tcp_close(fd);

    const request = try std.mem.concat(context.arena, u8, &.{
        fake_key_prefix, name, fake_key_suffix,
    });
    if (!platform.kx_tcp_write(fd, request.ptr, request.len)) return error.KanataUnreachable;
}

/// Act on a message as if kanata had pushed it, for `kxdesk kanata inject`.
///
/// This is how a binding is exercised without pressing its keys, and how the
/// channel is tested when kanata is not running at all: the parsing and the
/// action are the same code the socket path runs. An action name is what a
/// binding pushes, so it is taken as one and wrapped the way kanata wraps it;
/// anything starting with `{` is read as the line kanata would have sent.
pub fn inject(context: *Context, message: []const u8) ![]const u8 {
    const line = if (std.mem.startsWith(u8, message, "{"))
        message
    else
        try std.mem.concat(context.arena, u8, &.{ push_prefix, message, push_suffix });

    return switch (try handleLine(context, line)) {
        .action => |action| std.fmt.allocPrint(context.arena, "{s}", .{@tagName(action)}),
        .layer => |layer| std.fmt.allocPrint(context.arena, "layer {s}", .{layer}),
        .reload => "reloaded",
        .ignored => "ignored",
    };
}
