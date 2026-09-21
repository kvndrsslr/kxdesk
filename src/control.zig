//! The daemon's command channel.
//!
//! A request is the same NUL-framed block SketchyBar uses for events, with `CMD`
//! as its first token:
//!
//!     CMD\0<verb>\0<argument>...\0\0
//!
//! SketchyBar's own traffic can never be mistaken for one. Its events are
//! `key`/`value` pairs whose keys are `NAME`, `SENDER`, `INFO`, `BUTTON`,
//! `MODIFIER`, `SELECTED`, `SID`, `DID`, `ONLY` and `YABAI_WINDOW_ID`, and its
//! shutdown marker is the bare `k`; the receive loop tells the two apart by that
//! first token alone.
//!
//! A reply is posted to the port the request named as its response port:
//!
//!     OK\0<payload>\0
//!     ERR\0<message>\0
//!
//! SketchyBar's own sends are one-way, so an event block has no response port
//! and `postReply` does nothing for it.

const std = @import("std");

const exec = @import("exec.zig");
const platform = @import("platform.zig");
const sb = @import("sb.zig");
const timeouts = @import("timeouts.zig");

/// First token of a control request.
pub const tag = "CMD";
/// Outcome tags of a reply.
pub const ok = "OK";
pub const err = "ERR";

/// Arguments a request may carry beyond its verb.
pub const max_arguments = 8;

/// A request's verb and arguments, all slices into the received block.
pub const Request = struct {
    verb: []const u8,
    arguments: [max_arguments][]const u8 = @splat(""),
    count: usize = 0,

    /// The arguments, in order.
    pub fn args(self: *const Request) []const []const u8 {
        return self.arguments[0..self.count];
    }
};

/// The NUL-separated tokens of a block, ending at the first empty one.
const Tokens = struct {
    block: [*:0]const u8,
    caret: usize = 0,

    fn next(self: *Tokens) ?[]const u8 {
        const token = std.mem.span(@as([*:0]const u8, @ptrCast(self.block + self.caret)));
        if (token.len == 0) return null;
        self.caret += token.len + 1;
        return token;
    }
};

/// Whether `block` is a control request rather than a SketchyBar event.
pub fn isRequest(block: [*:0]const u8) bool {
    return block[0] == 'C' and std.mem.eql(u8, std.mem.sliceTo(block, 0), tag);
}

/// Split `CMD\0verb\0argument...` into its parts. Returns null when the block is
/// not a well-formed request.
pub fn parse(block: [*:0]const u8) ?Request {
    var tokens = Tokens{ .block = block };
    const first = tokens.next() orelse return null;
    if (!std.mem.eql(u8, first, tag)) return null;

    var request = Request{ .verb = tokens.next() orelse return null };
    while (request.count < max_arguments) {
        request.arguments[request.count] = tokens.next() orelse break;
        request.count += 1;
    }
    return request;
}

/// A reply's outcome and payload, as posted and as decoded.
pub const Reply = union(enum) {
    ok: []const u8,
    err: []const u8,
};

/// Largest reply this will frame. Payloads are lines of text - a status line, a
/// list of state keys, a list of space labels - so this fits any of them with
/// room to spare; a longer one is a bug, and is truncated rather than dropped.
const max_reply = 4096;

/// Post `reply` to the port a request asked to be answered on. That port is 0
/// for SketchyBar's one-way event sends, which have nowhere to answer.
pub fn postReply(port: u32, reply: Reply) void {
    if (port == 0) return;

    var buffer: [max_reply]u8 = undefined;
    const framed = frame(&buffer, reply);
    _ = platform.kx_post(port, framed.ptr, framed.len);
}

/// `OK\0<payload>\0` / `ERR\0<message>\0`, truncated to fit `buffer`.
fn frame(buffer: []u8, reply: Reply) []u8 {
    const kind = switch (reply) {
        .ok => ok,
        .err => err,
    };
    const body = switch (reply) {
        .ok => |payload| payload,
        .err => |message| message,
    };

    // kind, its NUL, the body, and the NUL that terminates it.
    const kept = @min(body.len, buffer.len - (kind.len + 2));
    @memcpy(buffer[0..kind.len], kind);
    buffer[kind.len] = 0;
    @memcpy(buffer[kind.len + 1 ..][0..kept], body[0..kept]);
    buffer[kind.len + 1 + kept] = 0;
    return buffer[0 .. kind.len + 2 + kept];
}

/// Split a reply into its outcome and payload.
pub fn decode(reply: []const u8) ?Reply {
    const kind_end = std.mem.indexOfScalar(u8, reply, 0) orelse reply.len;
    const rest = reply[@min(kind_end + 1, reply.len)..];
    const body_end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;

    const kind = reply[0..kind_end];
    const body = rest[0..body_end];

    if (std.mem.eql(u8, kind, ok)) return .{ .ok = body };
    if (std.mem.eql(u8, kind, err)) return .{ .err = body };
    return null;
}

/// launchd labels a `brew services` agent for this formula can carry.
///
/// Homebrew names an agent `sh.brew.<name>` and keeps `homebrew.mxcl.<name>` for
/// agents already loaded under the older spelling: those are the two it tries
/// itself. Which one applies is a property of the deployment, so both are
/// offered and the first one launchd accepts wins.
const agent_labels = [_][]const u8{ "sh.brew.kxdesk", "homebrew.mxcl.kxdesk" };

/// Ask the daemon to run `verb` with `args`, returning its reply.
///
/// The daemon is a launchd agent, so a client that finds nothing listening asks
/// launchd to start it and waits briefly instead of failing: a key binding or a
/// config script should not have to care whether the agent happens to be up.
pub fn submit(
    gpa: std.mem.Allocator,
    io: std.Io,
    verb: []const u8,
    args: []const []const u8,
    out: []u8,
) ![]const u8 {
    const message = try frameRequest(gpa, verb, args);
    defer gpa.free(message);

    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const reply = try exchange(gpa, io, message, out) orelse {
            // A daemon that is being replaced holds its port for a moment after
            // it stops reading, and the instance that replaces it answers on a
            // new port. One retry finds that instance, rather than failing a key
            // binding or the bar's `apply` in the middle of a restart.
            if (attempt > 0) return error.DaemonUnavailable;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(timeouts.retry_delay_ms), .awake) catch {};
            continue;
        };
        return reply;
    }
}

/// Ask a daemon that is already running to run `verb`, returning its reply, or
/// null when nothing is listening.
///
/// Unlike `submit` this never asks launchd to start the agent, because it serves
/// callers that must not have a side effect: a completion is being looked at, not
/// run, and pressing TAB should not start a daemon.
pub fn query(
    gpa: std.mem.Allocator,
    verb: []const u8,
    args: []const []const u8,
    out: []u8,
) ?[]const u8 {
    const port = platform.kx_bootstrap_lookup(sb.control_service);
    if (port == 0) return null;
    defer platform.kx_port_release(port);

    const message = frameRequest(gpa, verb, args) catch return null;
    defer gpa.free(message);

    const written = platform.kx_send(
        port,
        message.ptr,
        message.len,
        out.ptr,
        out.len,
        timeouts.reply_timeout_ms,
    );
    return switch (written) {
        -1, -2 => null,
        else => out[0..@min(@as(usize, @intCast(written)), out.len)],
    };
}

/// Send one request and return the reply, or null when a daemon that the
/// bootstrap service named did not answer it.
fn exchange(
    gpa: std.mem.Allocator,
    io: std.Io,
    message: []const u8,
    out: []u8,
) !?[]const u8 {
    const port = try connect(gpa, io);
    defer platform.kx_port_release(port);

    const written = platform.kx_send(
        port,
        message.ptr,
        message.len,
        out.ptr,
        out.len,
        timeouts.reply_timeout_ms,
    );
    return switch (written) {
        // Sent, but nothing read it: the port belonged to a daemon that is
        // leaving. Or the name resolved to a port that is already dead.
        -1, -2 => null,
        else => out[0..@min(@as(usize, @intCast(written)), out.len)],
    };
}

/// `CMD\0verb\0argument...\0` with the extra trailing NUL a receiver expects.
fn frameRequest(gpa: std.mem.Allocator, verb: []const u8, args: []const []const u8) ![]u8 {
    var message = std.ArrayList(u8).empty;
    errdefer message.deinit(gpa);

    try message.appendSlice(gpa, tag);
    try message.append(gpa, 0);
    try message.appendSlice(gpa, verb);
    try message.append(gpa, 0);
    for (args) |argument| {
        try message.appendSlice(gpa, argument);
        try message.append(gpa, 0);
    }
    try message.append(gpa, 0);
    return message.toOwnedSlice(gpa);
}

/// Resolve the daemon's control service, asking launchd to start the agent when
/// nothing is listening.
fn connect(gpa: std.mem.Allocator, io: std.Io) !u32 {
    const existing = platform.kx_bootstrap_lookup(sb.control_service);
    if (existing != 0) return existing;

    // Nothing is answering. launchd owns the agent, so it is asked to start it -
    // and when it will not (the agent was never installed, or its label is one
    // this machine does not use), there is nothing to wait for.
    if (!try startAgent(gpa, io)) return error.DaemonUnavailable;

    var waited: u32 = 0;
    while (waited < timeouts.start_timeout_ms) : (waited += timeouts.start_poll_ms) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(timeouts.start_poll_ms), .awake) catch {};
        const port = platform.kx_bootstrap_lookup(sb.control_service);
        if (port != 0) return port;
    }

    return error.DaemonUnavailable;
}

/// Ask launchd to start the agent, reporting whether it accepted the request.
/// A refused `kickstart` means no daemon is coming, which is worth knowing
/// immediately rather than after the retry window has expired.
fn startAgent(gpa: std.mem.Allocator, io: std.Io) !bool {
    const launchctl = exec.path(gpa, "launchctl") catch return false;
    defer gpa.free(launchctl);

    for (agent_labels) |label| {
        const target = try std.fmt.allocPrint(gpa, "gui/{d}/{s}", .{ platform.kx_uid(), label });
        defer gpa.free(target);

        const result = std.process.run(gpa, io, .{
            // Without `-k`: a client is here because it could not see the
            // daemon, and `-k` would kill the one that is running before
            // starting another. Starting it if it is not up is the whole job.
            .argv = &.{ launchctl, "kickstart", target },
        }) catch continue;
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);

        switch (result.term) {
            .exited => |status| if (status == 0) return true,
            else => {},
        }
    }

    return false;
}
