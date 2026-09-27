//! The herdr item's refresh: how many agents are working, and how many are done
//! or waiting on the user, on the two count chips beside the item's mark.
//!
//! `herdr agent list` reads the server's own socket - no network, no client
//! attach - and answers in a few tens of milliseconds, so the item's own clock
//! drives this and the read runs as a background task. A herdr with no server
//! running exits with `server_not_running` rather than starting one, so a machine
//! that does not use herdr costs one failed exec per tick and nothing else.

const std = @import("std");

const exec = @import("exec.zig");
const log = @import("log.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");

/// The item this refresh owns. `bar.zig` declares it and `dispatch.zig` routes
/// its events by this name; neither imports this file.
pub const item = "herdr";

/// What one answer counts: the two numbers the item's chips show, and whether
/// anything answered at all.
pub const Counts = struct {
    /// Agents that are working; the lower chip.
    working: u32 = 0,
    /// Agents that are done, or blocked waiting on the user: the two states that
    /// mean the ball is in the user's court. `idle` - a completion the server has
    /// already shown - is not one of them, and neither is `unknown`, which is an
    /// agent Herdr cannot classify rather than one that has finished.
    attention: u32 = 0,
    /// Whether a server answered. A read that never got one leaves the mark
    /// dimmed rather than reporting a zero it was not told.
    answered: bool = false,

    /// Count one agent's `agent_status`, as `herdr agent list` spells it.
    pub fn add(self: *Counts, status: []const u8) void {
        if (std.mem.eql(u8, status, "working")) {
            self.working += 1;
        } else if (std.mem.eql(u8, status, "done") or std.mem.eql(u8, status, "blocked")) {
            self.attention += 1;
        }
    }
};

/// The part of `herdr agent list`'s reply this reads: `result` is what a reply has
/// and what `herdr`'s own error answer does not, which is how a body that is not a
/// listing is told apart from one that reports no agents.
const Reply = struct {
    result: ?Result = null,
};

const Result = struct {
    agents: []const Agent = &.{},
};

const Agent = struct {
    agent_status: []const u8 = "",
};

/// Reported once per distinct message: this runs every couple of seconds, so a
/// herdr that keeps answering the same surprise would otherwise fill the log.
var reported: log.Once = .{};

pub fn refresh(io: std.Io, gpa: std.mem.Allocator) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const counts = try read(arena_state.allocator(), gpa, io) orelse Counts{};

    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    var attention_text: [8]u8 = undefined;
    var working_text: [8]u8 = undefined;

    var props: Props = .{};
    // The counts come before the flags, because `value` and `drawing` are
    // written in field order and writing a badge's value *sets* its drawing to
    // whether that value is empty: a chip whose count is zero has to have its
    // `drawing` written after its value to stay off.
    try props.write(.{
        .icon = .{
            // Dim until a server answers, like the provider items: a mark that is
            // bright and says nothing is worse than one that admits it is stale.
            .color = try props.argb(if (counts.answered) theme.magenta else style.dim),
            .badge = .{
                .value = try countText(&attention_text, counts.attention),
                .drawing = counts.attention > 0,
            },
        },
        .label = .{ .badge = .{
            .value = try countText(&working_text, counts.working),
            .drawing = counts.working > 0,
        } },
    });

    try client.set(item, props.slice());
    try client.commit();
}

/// What the server answered, or `null` when there was nothing to read: herdr is
/// not installed, no server is running, or the answer is not a listing.
fn read(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) !?Counts {
    const herdr = exec.path(gpa, "herdr") catch |err| switch (err) {
        error.NotInstalled => return null,
        else => return err,
    };
    defer gpa.free(herdr);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ herdr, "agent", "list" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (!succeeded(result.term)) {
        // A server that is not running is the expected answer on a machine that
        // does not use herdr, and the dimmed mark is what says so; anything else
        // is worth a line, once.
        if (!std.mem.containsAtLeast(u8, result.stderr, 1, "server_not_running")) {
            report(result.stderr);
        }
        return null;
    }

    return countReply(arena, result.stdout) orelse answered: {
        report(result.stdout);
        break :answered null;
    };
}

/// Count one `herdr agent list` body, or `null` when it is not one - `herdr`'s
/// own error answer has no `result`, for one. Public because the test hands it a
/// body, which is the only way to see the mapping without a server to ask.
pub fn countReply(arena: std.mem.Allocator, body: []const u8) ?Counts {
    const parsed = std.json.parseFromSliceLeaky(Reply, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return null;

    const result = parsed.result orelse return null;

    var counts: Counts = .{ .answered = true };
    for (result.agents) |agent| counts.add(agent.agent_status);
    return counts;
}

/// Whether the run exited with a success status.
fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |status| status == 0,
        else => false,
    };
}

/// A count as its chip shows it: whole, and at most the two digits the chip's box
/// is measured for, so a hundred agents read as `99` rather than outgrow the box.
fn countText(buffer: *[8]u8, number: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{@min(number, 99)});
}

/// Report an answer this cannot use, once per distinct message.
fn report(message: []const u8) void {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    if (trimmed.len > 0 and reported.changed(trimmed)) {
        log.warn("herdr: {s}", .{trimmed});
    }
}
