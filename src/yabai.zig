//! yabai query client.
//!
//! The shell configuration this replaces piped every query through `jq` and, for
//! stacked windows, re-queried yabai once per window. Here the JSON is parsed
//! straight into typed values, so a single `--windows` query answers every
//! question the updater asks.
//!
//! Two transports, one message. The daemon listens on `/tmp/yabai_<user>.socket`
//! and answers the framing `yabai -m` itself speaks, which is what everything
//! here uses first; the binary is the fallback, and the difference between them
//! is only a process spawn in front of the same message - measured, ~0.5 ms
//! against ~5.6 ms for one query, which is a fork and a dynamic link of a client
//! that adds nothing. yabai exposes no mach service and no library, so the
//! binary is the only thing to fall back to.

const std = @import("std");

const platform = @import("platform.zig");

/// A yabai display. `id` is the `CGDirectDisplayID`, which is also what
/// SketchyBar reports as `DirectDisplayID`.
pub const Display = struct {
    id: u32 = 0,
    index: u32 = 0,
    /// Where the display is and how big it is, in points. Only the window-fill
    /// action reads it: everything else goes by `index`.
    frame: Frame = .{},
};

/// A rectangle yabai reports, as the floating point numbers it writes - they
/// are whole points in practice, and rounding them is the caller's business.
pub const Frame = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
};

/// A yabai space.
pub const Space = struct {
    index: u32 = 0,
    type: []const u8 = "",
    label: []const u8 = "",
    display: u32 = 0,
    @"is-visible": bool = false,
    @"has-focus": bool = false,
};

/// A window yabai knows about. Only the fields the bar renders and the focus
/// cycle steers by are modelled; `id` is what that cycle focuses.
pub const Window = struct {
    id: u32 = 0,
    app: []const u8 = "",
    title: []const u8 = "",
    role: []const u8 = "",
    display: u32 = 0,
    space: u32 = 0,
    @"stack-index": u32 = 0,
    /// Set on the one window yabai has focused. The bar reads it only when the
    /// space query failed and the front window cannot be derived from the space
    /// a display is showing.
    @"has-focus": bool = false,
    @"is-minimized": bool = false,
    @"is-hidden": bool = false,
    @"is-sticky": bool = false,
    @"is-floating": bool = false,
    @"has-parent-zoom": bool = false,
    @"has-fullscreen-zoom": bool = false,
};

pub const Error = error{
    YabaiNotFound,
    YabaiFailed,
    YabaiOutputTooLarge,
    InvalidJson,
};

/// Anything yabai reports as a list of named things: rules and signals. Only the
/// label is modelled, because a rule or signal is removed by label and added by
/// naming it - nothing reads the rest back.
pub const Labeled = struct {
    label: []const u8 = "",
};

/// Largest query response we are willing to buffer. `--windows` on a busy
/// machine is a few hundred kilobytes.
const max_response: usize = 16 * 1024 * 1024;

/// The byte yabai starts a refusal with (`FAILURE_MESSAGE` in its source). Its
/// own client reads it to decide an exit status, and so does this: over the
/// socket a refusal is text, over the binary it is a non-zero exit.
const refusal_marker = 0x07;

/// What the socket answered: the reply, or the daemon's refusal without the
/// marker that precedes it.
const Answer = union(enum) {
    reply: []const u8,
    refusal: []const u8,

    fn of(bytes: []const u8) Answer {
        if (bytes.len > 0 and bytes[0] == refusal_marker) return .{ .refusal = bytes[1..] };
        return .{ .reply = bytes };
    }
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    /// The yabai binary: the fallback transport, and the only way in when the
    /// socket does not answer.
    exe: [:0]u8,
    /// Set by the first socket failure. The socket is the fast path, so giving
    /// up on it is worth one line in the log - the fallback carries the traffic
    /// from then on, and a line per message would only drown that one.
    socket_failure_reported: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator) !Client {
        return .{ .gpa = gpa, .exe = try resolve(gpa, "yabai") };
    }

    pub fn deinit(self: *Client) void {
        self.gpa.free(self.exe);
        self.* = undefined;
    }

    pub fn displays(self: *Client, scratch: std.mem.Allocator) ![]Display {
        return self.query([]Display, scratch, &.{ "-m", "query", "--displays" });
    }

    pub fn spaces(self: *Client, scratch: std.mem.Allocator) ![]Space {
        return self.query([]Space, scratch, &.{ "-m", "query", "--spaces" });
    }

    pub fn windows(self: *Client, scratch: std.mem.Allocator) ![]Window {
        return self.query([]Window, scratch, &.{ "-m", "query", "--windows" });
    }

    /// The windows of the space in focus, floating ones included - the list
    /// cycling has to be built from, since every `--focus` selector of yabai's
    /// own walks the BSP tree and so never reaches a floating window.
    pub fn spaceWindows(self: *Client, scratch: std.mem.Allocator) ![]Window {
        return self.query([]Window, scratch, &.{ "-m", "query", "--windows", "--space" });
    }

    /// Query a single window, used by the cheap `ONLY=title` path where the
    /// window list has not been fetched.
    pub fn window(self: *Client, scratch: std.mem.Allocator, id: []const u8) !Window {
        return self.query(Window, scratch, &.{ "-m", "query", "--windows", "--window", id });
    }

    /// Run `yabai -m <args>` and discard its output.
    ///
    /// Failures are the caller's business: yabai refuses a command it cannot
    /// carry out, and several callers depend on that - the focus cycle steps
    /// over a window that refuses to be focused.
    pub fn command(self: *Client, scratch: std.mem.Allocator, args: []const []const u8) !void {
        _ = try self.send(scratch, args, false);
    }

    /// `yabai` and `args` as the NULL-terminated argument vector the spawn
    /// helpers take, allocated from `scratch`.
    fn argumentVector(
        self: *Client,
        scratch: std.mem.Allocator,
        args: []const []const u8,
    ) !std.ArrayList(?[*:0]const u8) {
        var vector = std.ArrayList(?[*:0]const u8).empty;
        try vector.append(scratch, self.exe.ptr);
        for (args) |argument| try vector.append(scratch, try scratch.dupeZ(u8, argument));
        try vector.append(scratch, null);
        return vector;
    }

    /// The raw JSON of `yabai -m <args>`, unparsed - for a caller that hands
    /// yabai's own answer on instead of reading it, the way the window-list
    /// copy does.
    pub fn rawQuery(
        self: *Client,
        scratch: std.mem.Allocator,
        args: []const []const u8,
    ) ![]const u8 {
        return self.send(scratch, args, true);
    }

    /// Parse the JSON of `yabai -m <args>` into `T`.
    ///
    /// Generic because the provisioning commands ask questions the bar's
    /// updaters do not: `rule --list` and `signal --list` are lists of labels,
    /// and the filtered display and space queries are the only forms that work
    /// on a machine where yabai aborts the unfiltered ones.
    pub fn query(
        self: *Client,
        comptime T: type,
        scratch: std.mem.Allocator,
        args: []const []const u8,
    ) !T {
        const raw = try self.send(scratch, args, true);
        return std.json.parseFromSliceLeaky(T, scratch, raw, .{
            .ignore_unknown_fields = true,
            // `raw` is arena-allocated and outlives the parsed value, so strings
            // can point straight into it instead of being copied.
            .allocate = .alloc_if_needed,
        }) catch |err| {
            std.debug.print("kxdesk: yabai query '{s}' failed: {s}\n", .{
                args[0],
                @errorName(err),
            });
            return Error.InvalidJson;
        };
    }

    /// One message to the yabai daemon, and its answer when one is wanted.
    ///
    /// The daemon's own socket comes first; the binary is the fallback for a
    /// socket that is not there or does not answer. A refusal is an answer, not
    /// a transport failure, and so never falls back: on the socket it is the
    /// daemon's own sentence behind the marker byte, and through the binary it
    /// is a non-zero exit, both surfacing as `error.YabaiFailed`.
    ///
    /// `want_reply` is what separates the two ways silence can be read. A
    /// command that succeeds answers nothing; a query always answers at least
    /// `[]`, so an empty answer to one means the socket did not carry the
    /// message, which falls back to the binary. The reply that comes back from
    /// a `want_reply` call is never empty.
    fn send(
        self: *Client,
        scratch: std.mem.Allocator,
        args: []const []const u8,
        want_reply: bool,
    ) ![]const u8 {
        if (socketRequest(scratch, args)) |answer| {
            switch (answer) {
                .refusal => return Error.YabaiFailed,
                .reply => |bytes| {
                    if (!want_reply or bytes.len > 0) return bytes;
                    self.reportSocketFailure(error.EmptyReply);
                },
            }
        } else |err| self.reportSocketFailure(err);

        if (want_reply) return self.capture(scratch, args);

        const vector = try self.argumentVector(scratch, args);
        if (platform.sb_exec_status(vector.items.ptr) != 0) return Error.YabaiFailed;
        return "";
    }

    /// Say once that the socket is not carrying the traffic, and name what went
    /// wrong: after this the binary answers everything, so there is nothing else
    /// to report about it.
    fn reportSocketFailure(self: *Client, err: anyerror) void {
        if (self.socket_failure_reported.swap(true, .monotonic)) return;
        std.debug.print("kxdesk: yabai socket unavailable ({s}), falling back to the binary\n", .{
            @errorName(err),
        });
    }

    /// The fallback: `yabai -m <args>` in a process of its own, output captured.
    fn capture(
        self: *Client,
        scratch: std.mem.Allocator,
        args: []const []const u8,
    ) ![]u8 {
        const vector = try self.argumentVector(scratch, args);

        var capacity: usize = 256 * 1024;
        while (true) {
            const buffer = try scratch.alloc(u8, capacity);
            const written = platform.sb_exec_capture(vector.items.ptr, buffer.ptr, buffer.len);
            if (written < 0) return Error.YabaiFailed;

            const total: usize = @intCast(written);
            // A query that answers nothing is a refused query, not malformed
            // JSON: yabai explains itself on stderr (which `sb_exec_capture`
            // discards) and exits non-zero without writing anything. Every
            // query that answers at all answers with at least `[]`.
            if (total == 0) return Error.YabaiFailed;
            if (total < capacity) return buffer[0..total];

            // The child wrote more than we could hold; grow and try again.
            if (capacity >= max_response) return Error.YabaiOutputTooLarge;
            capacity *= 4;
        }
    }
};

/// `/tmp/yabai_<user>.socket`, where the daemon listens, or null when `USER` is
/// unset. Named from the same variable and in the same shape yabai's own client
/// builds its path in, so that both agree on the file - and so that a `USER` it
/// would refuse to run with is a socket this does not try.
fn socketPath(buffer: *[std.fs.max_path_bytes]u8) ?[:0]const u8 {
    var environment: [std.fs.max_path_bytes]u8 = undefined;
    if (!platform.sb_env("USER", &environment, environment.len)) return null;

    const user = std.mem.sliceTo(&environment, 0);
    return std.fmt.bufPrintZ(buffer, "/tmp/yabai_{s}.socket", .{user}) catch null;
}

/// One message over `/tmp/yabai_<user>.socket`, in the framing `yabai -m` uses
/// (`client_send_message` in the yabai source): a native-endian length covering
/// every token, each token NUL-terminated with one more NUL after the last, the
/// write side shut down, and the reply read to end of file.
///
/// The wire message starts at the domain, not at `-m`: the binary is what strips
/// that flag (`client_send_message(argc-1, argv+1)`), so the same argv the
/// spawned client is given has to lose its first token here. Sending it whole
/// gets `unknown domain '-m'` back.
///
/// Every error here is a transport failure and none of them is an answer, which
/// is what the caller falls back to the binary for.
fn socketRequest(scratch: std.mem.Allocator, args: []const []const u8) !Answer {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = socketPath(&path_buffer) orelse return error.SocketUnavailable;

    const message = if (args.len > 0 and std.mem.eql(u8, args[0], "-m")) args[1..] else args;

    var payload: usize = 1;
    for (message) |token| payload += token.len + 1;

    const request = try scratch.alloc(u8, @sizeOf(i32) + payload);
    std.mem.writeInt(i32, request[0..@sizeOf(i32)], @intCast(payload), .native);
    @memset(request[@sizeOf(i32)..], 0);
    var cursor: usize = @sizeOf(i32);
    for (message) |token| {
        @memcpy(request[cursor..][0..token.len], token);
        cursor += token.len + 1;
    }

    var capacity: usize = 256 * 1024;
    while (true) {
        const buffer = try scratch.alloc(u8, capacity);
        const written = platform.sb_socket_message(
            path.ptr,
            request.ptr,
            request.len,
            buffer.ptr,
            buffer.len,
        );
        if (written < 0) return error.SocketUnavailable;

        const total: usize = @intCast(written);
        // A full buffer is a reply that did not fit; the same message is asked
        // again with room for it, as a spawned command's output is.
        if (total < capacity) return Answer.of(buffer[0..total]);
        if (capacity >= max_response) return Error.YabaiOutputTooLarge;
        capacity *= 4;
    }
}

/// Resolve an executable name against `PATH` and the Homebrew prefixes.
fn resolve(gpa: std.mem.Allocator, name: [:0]const u8) ![:0]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (!platform.sb_which(name.ptr, &buffer, buffer.len)) return Error.YabaiNotFound;
    return gpa.dupeZ(u8, std.mem.sliceTo(&buffer, 0));
}
