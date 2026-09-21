//! Mach client for a SketchyBar instance.
//!
//! SketchyBar redraws once per received message, so every update is one batch of
//! commands rather than a `sketchybar` CLI spawn per property change: no `fork`,
//! no argument re-tokenisation, one redraw.

const std = @import("std");

const platform = @import("platform.zig");
const timeouts = @import("timeouts.zig");

/// Bootstrap service name of the running SketchyBar instance.
pub const sketchybar_service: [:0]const u8 = "git.felix.sketchybar";

/// Bootstrap service the kxdesk daemon publishes its command channel under;
/// `main.event_service` is another name for the same receive port.
pub const control_service: [:0]const u8 = "org.kdressler.kxdesk.control";

pub const Error = error{
    /// The bootstrap service this client was built for is not registered.
    SketchyBarUnavailable,
    /// A query response did not fit the caller's buffer.
    ResponseTooLong,
    /// Building the command batch ran out of memory.
    OutOfMemory,
};

/// Response buffer for `query`; far above any answer a `--query` returns.
const response_bytes = 64 * 1024;

fn traceBatch(payload: []const u8) void {
    std.debug.print("--- batch\n", .{});
    var arguments = std.mem.splitScalar(u8, payload, 0);
    while (arguments.next()) |argument| {
        if (argument.len == 0) break;
        std.debug.print("\t{s}\n", .{argument});
    }
}

/// Echo a received block's tokens to stderr, under the same `KXDESK_TRACE`
/// switch as `traceBatch`. The only way to see what SketchyBar sent: which keys
/// an event carries depends on the event and the item's own env vars, so a
/// routing bug otherwise looks like silence.
pub fn traceBlock(block: [*:0]const u8) void {
    std.debug.print("--- block\n", .{});
    var caret: usize = 0;
    while (block[caret] != 0) {
        const token = std.mem.span(@as([*:0]const u8, @ptrCast(block + caret)));
        std.debug.print("\t{s}\n", .{token});
        caret += token.len + 1;
    }
}

/// Parsed view over the environment block that SketchyBar sends with an event:
/// a flat sequence of NUL-terminated `key`/`value` pairs closed by an empty key.
///
/// The block is owned by the mach message and valid only for the duration of the
/// handler call, so nothing here may be retained.
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
            .trace = platform.kx_env("KXDESK_TRACE", &value, value.len) and value[0] != '0',
        };
    }

    pub fn deinit(self: *Client) void {
        const gpa = self.gpa;
        const service = self.service;
        if (self.port != 0) platform.kx_port_release(self.port);
        self.args.deinit(gpa);
        self.* = .{ .gpa = gpa, .service = service };
    }

    /// Resolve the bootstrap service. No retry is needed: SketchyBar registers
    /// `git.felix.sketchybar` before it runs the config script, and the daemon
    /// registers both of its names before it starts serving.
    pub fn connect(self: *Client) !void {
        if (self.port == 0) self.port = platform.kx_bootstrap_lookup(self.service);
        if (self.port == 0) return Error.SketchyBarUnavailable;
    }

    /// Forget the resolved send right, so that the next `connect` resolves the
    /// name again. A restarted SketchyBar registers the same name for a new
    /// instance, and the right held for the old one is dead.
    pub fn reconnect(self: *Client) void {
        if (self.port != 0) platform.kx_port_release(self.port);
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

    /// `--set <item> <props...>`
    pub fn set(self: *Client, item: []const u8, props: []const []const u8) !void {
        try self.arg("--set");
        try self.arg(item);
        for (props) |property| try self.arg(property);
    }

    /// Push one data point into a graph item: a bare argument, a fraction of the
    /// graph's height, so a percentage is divided before it arrives here.
    pub fn push(self: *Client, item: []const u8, value: f64) !void {
        var buffer: [32]u8 = undefined;
        const point = std.fmt.bufPrint(&buffer, "{d:.4}", .{value}) catch return error.OutOfMemory;

        try self.arg("--push");
        try self.arg(item);
        try self.arg(point);
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

    /// `--query <item>`, parsed as `T`, in one batch. The response buffer is
    /// allocated from `arena`, so `T` may point into it.
    pub fn query(self: *Client, comptime T: type, arena: std.mem.Allocator, item: []const u8) !T {
        // The answer describes the whole batch, so nothing else may be queued.
        self.clear();
        try self.arg("--query");
        try self.arg(item);

        const buffer = try arena.alloc(u8, response_bytes);
        const response = try self.commitInto(buffer);

        return std.json.parseFromSliceLeaky(T, arena, response, .{
            .ignore_unknown_fields = true,
            // The buffer outlives the parsed value (both live in the arena), so
            // strings can point into it instead of being copied.
            .allocate = .alloc_if_needed,
        });
    }

    /// Send the queued batch, discarding the response. Returns its length.
    fn transmit(self: *Client, out: ?[]u8) Error!usize {
        // A NUL-separated argument vector has to end with an extra NUL byte so
        // SketchyBar's tokenizer can stop safely at the last argument.
        try self.args.append(self.gpa, 0);
        defer self.args.items.len -= 1;

        const payload = self.args.items;
        if (self.trace) traceBatch(payload);

        // A restored SketchyBar registers its bootstrap name again, so a right
        // held from before then names a dead port. Resolving a name is cheap, so
        // a client whose send just failed resolves again rather than going silent
        // for the rest of the process's life; the daemon's client is built once
        // and used by every item event.
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            if (self.port == 0) self.port = platform.kx_bootstrap_lookup(self.service);
            if (self.port == 0) return Error.SketchyBarUnavailable;

            const written = platform.kx_send(
                self.port,
                payload.ptr,
                payload.len,
                if (out) |buffer| buffer.ptr else null,
                if (out) |buffer| buffer.len else 0,
                timeouts.query_timeout_ms,
            );
            if (written >= 0) return @intCast(written);

            // The right is dead, or nothing answered on it. Drop it, so the next
            // pass resolves the name of whichever SketchyBar is running now.
            platform.kx_port_release(self.port);
            self.port = 0;
            if (attempt > 0) return Error.SketchyBarUnavailable;
        }
    }
};
