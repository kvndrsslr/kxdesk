//! Mach client for a SketchyBar instance.
//!
//! SketchyBar redraws once per received message, so every update is expressed as
//! a single batch of commands. Driving the bar this way - instead of spawning the
//! `sketchybar` CLI once per property change - is what makes kxdesk cheap: no
//! `fork`/`exec`, no argument re-tokenisation, one redraw.

const std = @import("std");

const platform = @import("platform.zig");

/// Bootstrap service name of the running SketchyBar instance.
pub const sketchybar_service: [:0]const u8 = "git.felix.sketchybar";

/// Bootstrap service the kxdesk daemon publishes its command channel under.
/// Both it and `main.event_service` are names for the daemon's one receive
/// port, so a client resolves this one and gets the daemon either way.
pub const control_service: [:0]const u8 = "org.kdressler.kxdesk.control";

pub const Error = error{
    /// The bootstrap service this client was built for is not registered.
    SketchyBarUnavailable,
    /// A query response did not fit the caller's buffer.
    ResponseTooLong,
    /// Building the command batch ran out of memory.
    OutOfMemory,
};

/// How long to wait for SketchyBar to answer a query. It applies commands on its
/// own thread and answers immediately, so this only elapses when it is wedged;
/// the daemon's event path must not sit on a query for longer than that.
pub const query_timeout_ms: u32 = 1000;

fn traceBatch(payload: []const u8) void {
    std.debug.print("--- batch\n", .{});
    var arguments = std.mem.splitScalar(u8, payload, 0);
    while (arguments.next()) |argument| {
        if (argument.len == 0) break;
        std.debug.print("\t{s}\n", .{argument});
    }
}

/// Echo a received block's tokens to stderr, under the same `KXDESK_TRACE`
/// switch as `traceBatch`.
///
/// The counterpart of the outgoing trace, and the only way to see what
/// SketchyBar actually sent: which keys an event carries depends on the event
/// and on the item's own env vars, so a routing bug otherwise looks like silence.
pub fn traceBlock(block: [*:0]const u8) void {
    std.debug.print("--- block\n", .{});
    var caret: usize = 0;
    while (block[caret] != 0) {
        const token = std.mem.span(@as([*:0]const u8, @ptrCast(block + caret)));
        std.debug.print("\t{s}\n", .{token});
        caret += token.len + 1;
    }
}

/// Parsed view over the environment block that SketchyBar sends with an event.
///
/// The block is a flat sequence of NUL-terminated `key`/`value` pairs closed by
/// an empty key. It is owned by the mach message and only valid for the duration
/// of the handler call, so nothing here may be retained.
pub const Env = struct {
    block: [*:0]const u8,

    pub fn get(self: Env, key: []const u8) ?[]const u8 {
        var caret: usize = 0;
        while (self.block[caret] != 0) {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(self.block + caret)));
            caret += name.len + 1;

            const value = std.mem.span(@as([*:0]const u8, @ptrCast(self.block + caret)));
            caret += value.len + 1;

            if (std.mem.eql(u8, name, key)) return value;
        }
        return null;
    }

    /// Value for `key`, or `""` when the variable is absent. SketchyBar and the
    /// shell plugins it replaces make no distinction, so neither do we.
    pub fn getOrEmpty(self: Env, key: []const u8) []const u8 {
        return self.get(key) orelse "";
    }
};

/// Accumulates SketchyBar commands and ships them in one mach message.
pub const Client = struct {
    gpa: std.mem.Allocator,
    /// Bootstrap service to talk to: SketchyBar itself for the bar's own
    /// updates, or the daemon's control channel when a client is what is
    /// running.
    service: [:0]const u8,
    port: u32 = 0,
    args: std.ArrayList(u8) = .empty,
    /// Echo every batch to stderr when `KXDESK_TRACE` is set. SketchyBar keeps
    /// no log of what a client asked it for, so this is the only way to see the
    /// command stream a configuration produces.
    trace: bool = false,

    pub fn init(gpa: std.mem.Allocator, service: [:0]const u8) Client {
        var value: [8]u8 = undefined;
        return .{
            .gpa = gpa,
            .service = service,
            .trace = platform.sb_env("KXDESK_TRACE", &value, value.len) and value[0] != '0',
        };
    }

    pub fn deinit(self: *Client) void {
        const gpa = self.gpa;
        const service = self.service;
        if (self.port != 0) platform.sb_port_release(self.port);
        self.args.deinit(gpa);
        self.* = .{ .gpa = gpa, .service = service };
    }

    /// Resolve the bootstrap service. No retry is needed: SketchyBar registers
    /// `git.felix.sketchybar` before it runs the config script, and the daemon
    /// registers both of its names before it starts serving.
    pub fn connect(self: *Client) !void {
        if (self.port == 0) self.port = platform.sb_bootstrap_lookup(self.service);
        if (self.port == 0) return Error.SketchyBarUnavailable;
    }

    /// Forget the resolved send right, so that the next `connect` resolves the
    /// name again. A restarted SketchyBar registers the same name for a new
    /// instance, and the right held for the old one is dead.
    pub fn reconnect(self: *Client) void {
        if (self.port != 0) platform.sb_port_release(self.port);
        self.port = 0;
    }

    /// Drop queued commands, keeping the underlying allocation for reuse.
    pub fn clear(self: *Client) void {
        self.args.clearRetainingCapacity();
    }

    /// Queue one raw argument.
    pub fn arg(self: *Client, value: []const u8) !void {
        try self.args.appendSlice(self.gpa, value);
        try self.args.append(self.gpa, 0);
    }

    /// Queue a `key=value` property.
    pub fn prop(self: *Client, key: []const u8, value: []const u8) !void {
        try self.args.appendSlice(self.gpa, key);
        try self.args.append(self.gpa, '=');
        try self.args.appendSlice(self.gpa, value);
        try self.args.append(self.gpa, 0);
    }

    /// Queue a `key=value` property with a formatted value.
    pub fn propFmt(self: *Client, key: []const u8, comptime fmt: []const u8, values: anytype) !void {
        var buf: [256]u8 = undefined;
        try self.prop(key, try std.fmt.bufPrint(&buf, fmt, values));
    }

    /// `--set <item> <props...>`
    pub fn set(self: *Client, item: []const u8, props: []const []const u8) !void {
        try self.arg("--set");
        try self.arg(item);
        for (props) |property| try self.arg(property);
    }

    /// Send the queued batch and forget it. SketchyBar applies every command in
    /// the batch before it redraws, so items never flash an intermediate state.
    ///
    /// The batch is dropped whether or not it was sent: it describes the state of
    /// the world at the moment it was built, and every caller rebuilds it from a
    /// fresh query, so keeping a failed one would only mix stale commands into the
    /// next update - and grow without bound, since the events that trigger an
    /// update keep arriving.
    pub fn commit(self: *Client) !void {
        if (self.args.items.len == 0) return;
        defer self.clear();

        _ = try self.transmit(null);
    }

    /// Send the queued batch and copy SketchyBar's textual response into `out`.
    /// The response is written straight into `out`, so this stays safe to call
    /// from several tasks at once.
    pub fn commitInto(self: *Client, out: []u8) ![]u8 {
        defer self.clear();

        const length = try self.transmit(out);
        if (length > out.len) return Error.ResponseTooLong;
        return out[0..length];
    }

    /// Send the queued batch, discarding the response. Returns its length.
    fn transmit(self: *Client, out: ?[]u8) Error!usize {
        // A NUL-separated argument vector has to end with an extra NUL byte so
        // SketchyBar's tokenizer can stop safely at the last argument.
        try self.args.append(self.gpa, 0);
        defer self.args.items.len -= 1;

        const payload = self.args.items;
        if (self.trace) traceBatch(payload);

        // SketchyBar registers its bootstrap name again when it is restarted, and
        // a send right held from before then names a dead port. Resolving a name
        // is cheap, so a client that has no right - or whose right just failed -
        // resolves it again rather than going silent for the rest of the
        // process's life: the daemon's own client is built once and used by every
        // item event, so a single stale right used to mean a bar that never drew
        // again.
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            if (self.port == 0) self.port = platform.sb_bootstrap_lookup(self.service);
            if (self.port == 0) return Error.SketchyBarUnavailable;

            const written = platform.sb_send(
                self.port,
                payload.ptr,
                payload.len,
                if (out) |buffer| buffer.ptr else null,
                if (out) |buffer| buffer.len else 0,
                query_timeout_ms,
            );
            if (written >= 0) return @intCast(written);

            // The right is dead, or nothing answered on it. Drop it, so the next
            // pass resolves the name of whichever SketchyBar is running now.
            platform.sb_port_release(self.port);
            self.port = 0;
            if (attempt > 0) return Error.SketchyBarUnavailable;
        }
    }
};
