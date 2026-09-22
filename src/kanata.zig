//! kanata's channel, and the commands its messages name.
//!
//! The key bindings live in kanata and the commands they run here: a binding
//! pushes a message, kanata broadcasts it to its TCP clients, and this turns it
//! into a command run as the user, in the user's session. Three shapes are acted
//! on - `{"MessagePush":{"message":[...]}}`, `{"LayerChange":{"new":"op"}}` and
//! `{"ConfigFileReload":…}` - and a pushed name is the `kxdesk` argv line without
//! the binary name (`wm window-swap west`), looked up in the registry and checked
//! by `cli.validate` exactly as the CLI checks what a client typed.

const std = @import("std");

const cli = @import("cli.zig");
const commands = @import("commands.zig");
const Context = @import("context.zig").Context;
const log = @import("log.zig");
const mode_indicator = @import("mode_indicator.zig");
const platform = @import("platform.zig");
const pomodoro = @import("pomodoro.zig");
const sb = @import("sb.zig");
const state = @import("store.zig");
const yabai = @import("yabai.zig");

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

/// The name a pushed message carried, out of the shape kanata wrapped it in.
///
/// `simple_sexpr_to_json_array` turns the action's arguments into a JSON array, so
/// what arrives for `(push-msg "wm window-swap west")` is
/// `["wm window-swap west"]`; the bare string its protocol documents is read as
/// well. A list of several names, a nested list, a number, or a name that is not a
/// string at all is refused rather than guessed at.
pub fn pushedName(message: std.json.Value) error{InvalidMessage}![]const u8 {
    if (message == .string) return message.string;
    if (message == .array) {
        const items = message.array.items;
        if (items.len == 1 and items[0] == .string) return items[0].string;
    }
    return error.InvalidMessage;
}

/// The mode indicator argument a layer's name stands for, or null for a layer
/// with no colour of its own.
///
/// The names are the ones `kanata.kbd` defines and the indices are the ones
/// `kxdesk set_mode_indicator` takes. `-` is "no mode", which is the default
/// layer: the bar's space icons stop highlighting.
pub fn indicatorFor(layer: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, layer, "op")) return "1";
    if (std.mem.eql(u8, layer, "wmode")) return "2";
    if (std.mem.eql(u8, layer, "smode")) return "3";
    if (std.mem.eql(u8, layer, "default")) return "-";
    return null;
}

/// What a line turned out to be, so that `kxdesk kanata inject` can say.
pub const Handled = union(enum) {
    /// A binding's command ran, named as the binding spelled it.
    command: []const u8,
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

/// Run a pushed name exactly as the CLI would: the words are the command's argv
/// without the binary name, looked up in the registry and checked by the same
/// validation the CLI runs - one vocabulary for keys and commands.
///
/// The check is what keeps a mistyped binding to a line in the log: a name the
/// registry does not know, or a verb given an argument it cannot take, is refused
/// here rather than passed to yabai to refuse in its own words. The payload a
/// command answers with has nobody to answer, so it is dropped.
fn dispatch(context: *Context, name: []const u8) anyerror!void {
    var words: [16][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.tokenizeScalar(u8, name, ' ');
    while (iterator.next()) |word| {
        if (count == words.len) return error.InvalidMessage;
        words[count] = word;
        count += 1;
    }
    if (count == 0) return error.InvalidMessage;

    const index = commands.find(words[0]) orelse return error.UnknownAction;
    const command = commands.all[index];
    if (command.run == null) return error.UnknownAction;

    if (try cli.validate(context.arena, command, words[1..count])) |problem| {
        log.warn("kanata message '{s}' refused: {s}", .{ name, problem });
        return error.Refused;
    }
    _ = try command.run.?(context, words[1..count]);
}

/// Act on one line of JSON, as kanata sent it.
pub fn handleLine(context: *Context, line: []const u8) !Handled {
    const message = std.json.parseFromSliceLeaky(Incoming, context.arena, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.InvalidMessage;

    if (message.MessagePush) |push| {
        const name = try pushedName(push.message);
        try dispatch(context, name);
        return .{ .command = name };
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
    /// same reason a command's is per request - whatever a command allocates is
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
            // A refusal has already been logged with its reason; only the
            // failures that have not been said get a line here.
            if (err != error.Refused)
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
/// never writes, so a tap cannot disturb the messages coming back, and a tapped
/// fake key is not acknowledged - a name kanata does not define is a line in
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
/// channel is tested when kanata is not running at all: the lookup, the check and
/// the run are the same code the socket path runs. An argv line is what a binding
/// pushes, so it is taken as one and wrapped the way kanata wraps it; anything
/// starting with `{` is read as the line kanata would have sent.
pub fn inject(context: *Context, message: []const u8) ![]const u8 {
    const line = if (std.mem.startsWith(u8, message, "{"))
        message
    else
        try std.mem.concat(context.arena, u8, &.{ push_prefix, message, push_suffix });

    return switch (try handleLine(context, line)) {
        .command => |name| std.fmt.allocPrint(context.arena, "{s}", .{name}),
        .layer => |layer| std.fmt.allocPrint(context.arena, "layer {s}", .{layer}),
        .reload => "reloaded",
        .ignored => "ignored",
    };
}
