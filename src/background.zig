//! Running an item's slow work off the event path: the receive loop is a blocking
//! C call on the main thread, so a refresh that shells out to `brew` or `gh` is
//! handed to `std.Io.async` and applies its own updates when it finishes.

const std = @import("std");

const log = @import("log.zig");

/// A task's result type: these refreshes report failures by logging.
pub const Result = anyerror!void;

/// At most one in-flight refresh per item: `std.Io.async` writes the task's result
/// into the `Future`, so that storage must stay put and must not be reused while
/// the old task still owns it. Slots live in the daemon, which never moves.
pub const Slot = struct {
    /// The task last handed to the pool, or null when none has been. The next
    /// task awaits it, never the caller: waiting on the receive loop for a task
    /// still running would stall every item event behind it.
    future: ?std.Io.Future(Result) = null,

    /// Start a refresh, handing the previous one to it to await first. With the
    /// schedules these items carry the previous task has long finished, so that
    /// wait is a formality; a command repeated in quick succession is the case
    /// where it is not.
    pub fn request(
        self: *Slot,
        io: std.Io,
        function: anytype,
        args: std.meta.ArgsTuple(@TypeOf(function)),
    ) void {
        // The wait is expressed as a task of its own, because only a declaration
        // can name a function value: a function type is comptime-only and cannot
        // travel in the tuple `std.Io.async` copies, which is why the function is
        // reached from the enclosing scope rather than passed along.
        const CallArgs = @TypeOf(args);
        const Task = struct {
            /// Await whatever the slot held, then run this task, on the worker
            /// that picked it up rather than on the loop.
            fn run(
                inner: std.Io,
                previous: ?std.Io.Future(Result),
                call_args: CallArgs,
            ) Result {
                if (previous) |earlier| {
                    var awaited = earlier;
                    // A failed refresh must not take the event loop down with it.
                    awaited.await(inner) catch |err| logFailure(err);
                }
                return @call(.auto, function, call_args);
            }
        };

        const previous = self.future;
        self.future = std.Io.async(io, Task.run, .{ io, previous, args });
    }
};

fn logFailure(err: anyerror) void {
    log.warn("background refresh failed: {s}", .{@errorName(err)});
}
