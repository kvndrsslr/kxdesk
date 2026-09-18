//! yabai query client.
//!
//! The shell configuration this replaces piped every query through `jq` and, for
//! stacked windows, re-queried yabai once per window. Here the JSON is parsed
//! straight into typed values, so a single `--windows` query answers every
//! question the updater asks.

const std = @import("std");

const platform = @import("platform.zig");

/// A yabai display. `id` is the `CGDirectDisplayID`, which is also what
/// SketchyBar reports as `DirectDisplayID`.
pub const Display = struct {
    id: u32 = 0,
    index: u32 = 0,
};

/// A yabai space.
pub const Space = struct {
    index: u32 = 0,
    @"type": []const u8 = "",
    @"label": []const u8 = "",
    display: u32 = 0,
    @"is-visible": bool = false,
    @"has-focus": bool = false,
};

/// A managed window. Only the fields the bar renders are modelled.
pub const Window = struct {
    app: []const u8 = "",
    title: []const u8 = "",
    @"role": []const u8 = "",
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
    @"label": []const u8 = "",
};

/// Largest query response we are willing to buffer. `--windows` on a busy
/// machine is a few hundred kilobytes.
const max_response: usize = 16 * 1024 * 1024;

pub const Client = struct {
    gpa: std.mem.Allocator,
    exe: [:0]u8,

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

    /// Query a single window, used by the cheap `ONLY=title` path where the
    /// window list has not been fetched.
    pub fn window(self: *Client, scratch: std.mem.Allocator, id: []const u8) !Window {
        return self.query(Window, scratch, &.{ "-m", "query", "--windows", "--window", id });
    }

    /// Run `yabai -m <args>` and discard its output.
    ///
    /// Failures are the caller's business: yabai exits non-zero for a command it
    /// refused, and several callers depend on that - `yabai -m window --focus
    /// stack.next || ... --focus next || ... --focus first` is a chain of them.
    pub fn command(self: *Client, scratch: std.mem.Allocator, args: []const []const u8) !void {
        const vector = try self.argumentVector(scratch, args);
        if (platform.sb_exec_status(vector.items.ptr) != 0) return Error.YabaiFailed;
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
        const raw = try self.exec(scratch, args);
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

    fn exec(
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

/// Resolve an executable name against `PATH` and the Homebrew prefixes.
fn resolve(gpa: std.mem.Allocator, name: [:0]const u8) ![:0]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (!platform.sb_which(name.ptr, &buffer, buffer.len)) return Error.YabaiNotFound;
    return gpa.dupeZ(u8, std.mem.sliceTo(&buffer, 0));
}
