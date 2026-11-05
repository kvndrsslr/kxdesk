//! The tern item's refresh: how many panes are working, and how many things in
//! Tern's needs-attention inbox are waiting on the user, on the two count chips
//! beside the item's mark.
//!
//! `tern inspect --json` reads the session daemon's own socket - no network, no
//! window - and answers in a few tens of milliseconds, so the item's own clock
//! drives this and the read runs as a background task. The attention count is
//! the window's own state (`tern ctl state`), reached the way a pane reaches it,
//! through the daemon socket; with no window open there is no inbox to read and
//! the count stays zero. A Tern with no daemon running exits rather than starting
//! one, so a machine that does not use Tern costs one failed exec per tick and
//! nothing else.

const std = @import("std");

const exec = @import("exec.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");

/// The item this refresh owns. `bar.zig` declares it and `dispatch.zig` routes
/// its events by this name; neither imports this file.
pub const item = "tern";

/// What one answer counts: the two numbers the item's chips show, and whether
/// anything answered at all.
pub const Counts = struct {
    /// Panes whose program reports work in progress; the lower chip.
    working: u32 = 0,
    /// Entries in the needs-attention inbox - agents waiting on the user, bells,
    /// failed exits: the upper chip. `tern inspect` does not know about the
    /// inbox, so a read with no window leaves this at zero.
    attention: u32 = 0,
    /// Whether the session daemon answered. A read that never got one leaves the
    /// mark dimmed rather than reporting a zero it was not told.
    answered: bool = false,
};

/// The part of `tern inspect --json` this reads: `panes` is the daemon's host
/// listing, which every pane appears in with whether its program is working. Its
/// absence is what tells an answer that is not a listing apart from one that
/// reports no panes.
const Listing = struct {
    panes: ?[]const Pane = null,
};

const Pane = struct {
    working: bool = false,
};

/// The part of `tern ctl state` this reads: the window's own state, of which only
/// the inbox's count matters here.
const State = struct {
    inbox: ?Inbox = null,
};

const Inbox = struct {
    count: u32 = 0,
};

/// Reported once per distinct message: this runs every couple of seconds, so a
/// Tern that keeps answering the same surprise would otherwise fill the log.
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
            // Dim until a daemon answers, like the provider items: a mark that is
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

/// What the daemon answered, or `null` when there was nothing to read: Tern is
/// not installed, no session daemon is running, or the answer is not a listing.
fn read(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) !?Counts {
    const tern = exec.path(gpa, "tern") catch |err| switch (err) {
        error.NotInstalled => return null,
        else => return err,
    };
    defer gpa.free(tern);

    const listing = try std.process.run(gpa, io, .{ .argv = &.{ tern, "inspect", "--json" } });
    defer gpa.free(listing.stdout);
    defer gpa.free(listing.stderr);

    if (!succeeded(listing.term)) {
        // A machine that does not run Tern is the expected answer, and the dimmed
        // mark is what says so; anything else is worth a line, once.
        if (!std.mem.containsAtLeast(u8, listing.stderr, 1, "no Tern is running")) {
            report(listing.stderr);
        }
        return null;
    }

    var counts = countListing(arena, listing.stdout) orelse {
        report(listing.stdout);
        return null;
    };

    counts.attention = try inboxCount(arena, gpa, io, tern) orelse 0;
    return counts;
}

/// The inbox's count from the window's own state, or `null` when no window
/// answered: a daemon alone keeps panes alive but has no inbox to report.
fn inboxCount(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, tern: [:0]const u8) !?u32 {
    var socket_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const socket = daemonSocket(&socket_buffer) orelse return null;

    var assignment_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const assignment = try std.fmt.bufPrint(
        &assignment_buffer,
        "TERN_PANE_SOCKET={s}",
        .{socket},
    );

    // `ctl` reaches a window through the daemon socket a pane names, so it is set
    // for the child rather than inherited: the daemon's own environment has none.
    const state = try std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/env", assignment, tern, "ctl", "state" },
    });
    defer gpa.free(state.stdout);
    defer gpa.free(state.stderr);

    if (!succeeded(state.term)) {
        report(state.stderr);
        return null;
    }

    return countInbox(arena, state.stdout) orelse {
        report(state.stdout);
        return null;
    };
}

/// The daemon's default socket, `~/Library/Application Support/Tern/daemon.sock`,
/// built in the caller's buffer; `null` without a home to build it from.
fn daemonSocket(buffer: []u8) ?[]const u8 {
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (!platform.kx_env("HOME", &home_buffer, home_buffer.len)) return null;
    const home = std.mem.sliceTo(&home_buffer, 0);
    return std.fmt.bufPrint(
        buffer,
        "{s}/Library/Application Support/Tern/daemon.sock",
        .{home},
    ) catch null;
}

/// Count one `tern inspect --json` body, or `null` when it is not a listing.
/// Public because the test hands it a body, which is the only way to see the
/// mapping without a daemon to ask.
pub fn countListing(arena: std.mem.Allocator, body: []const u8) ?Counts {
    const parsed = std.json.parseFromSliceLeaky(Listing, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return null;

    const panes = parsed.panes orelse return null;

    var counts: Counts = .{ .answered = true };
    for (panes) |pane| {
        if (pane.working) counts.working += 1;
    }
    return counts;
}

/// The inbox's count from one `tern ctl state` body, or `null` when it is not a
/// window's state.
pub fn countInbox(arena: std.mem.Allocator, body: []const u8) ?u32 {
    const parsed = std.json.parseFromSliceLeaky(State, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return null;

    const inbox = parsed.inbox orelse return null;
    return inbox.count;
}

/// Whether the run exited with a success status.
fn succeeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |status| status == 0,
        else => false,
    };
}

/// A count as its chip shows it: whole, and at most the two digits the chip's box
/// is measured for, so a hundred panes read as `99` rather than outgrow the box.
fn countText(buffer: *[8]u8, number: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{@min(number, 99)});
}

/// Report an answer this cannot use, once per distinct message.
fn report(message: []const u8) void {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    if (trimmed.len > 0 and reported.changed(trimmed)) {
        log.warn("tern: {s}", .{trimmed});
    }
}
