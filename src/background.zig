//! Running an item's slow work off the event path.
//!
//! The daemon's receive loop is a blocking C call on the main thread, so a
//! handler has to return promptly. A refresh that shells out to `brew` or `gh`
//! takes a second or more, which would otherwise stall every other item for that
//! long; it is therefore handed to `std.Io.async`, whose thread pool runs it
//! while the loop keeps receiving. The task applies its own updates when it
//! finishes, so nothing has to be handed back to the loop.

const std = @import("std");

/// A task's result type: these refreshes report failures by logging.
pub const Result = anyerror!void;

/// At most one in-flight refresh per item.
///
/// `std.Io.async` writes the task's result into the `Future`, so that storage
/// must stay put and must not be reused while the old task still owns it. Slots
/// live in the dispatcher, which never moves.
pub const Slot = struct {
    future: std.Io.Future(Result) = undefined,
    started: bool = false,

    /// Start a refresh, awaiting a previous one first. With the schedules these
    /// items carry - a refresh every hour or every few minutes - a previous task
    /// has long finished, so that wait is a formality rather than a stall.
    pub fn request(
        self: *Slot,
        io: std.Io,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) void {
        if (self.started) {
            // A failed refresh must not take the event loop down with it.
            self.future.await(io) catch |err| logFailure(err);
        }
        self.future = std.Io.async(io, function, args);
        self.started = true;
    }

};

fn logFailure(err: anyerror) void {
    std.debug.print("kxdesk: background refresh failed: {s}\n", .{@errorName(err)});
}
