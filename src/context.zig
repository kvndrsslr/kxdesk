//! What a command gets to work with.
//!
//! Extracted from `commands.zig` so the command implementations
//! (`yabai_ops`, `mode_indicator`) can name this type without
//! importing the registry that points at them.

const std = @import("std");

const pomodoro = @import("pomodoro.zig");
const sb = @import("sb.zig");
const state = @import("store.zig");
const yabai = @import("yabai.zig");
const timeouts = @import("timeouts.zig");

/// What a command gets to work with.
pub const Context = struct {
    /// Everything the command allocates comes from here, and the task frees the
    /// whole arena when it returns, so nothing has to be handed back.
    arena: std.mem.Allocator,
    io: std.Io,
    /// A SketchyBar connection belonging to this command alone: the receive
    /// loop's client must not see a batch it did not build.
    bar: *sb.Client,
    yabai: *yabai.Client,
    /// The pomodoro timer, which the receive loop ticks and these commands
    /// start, stop and set.
    pomodoro: *pomodoro.Timer,
    /// Durable state: what the daemon remembers across restarts, and what the
    /// `state` command reads and writes for everything else.
    store: *state.Store,
    /// Whether SketchyBar is known to be up. Written by the receive loop.
    bar_present: *std.atomic.Value(bool),
    /// Bootstrap name items carry as `mach_helper`, so re-applying the
    /// configuration points them back at this daemon.
    event_service: []const u8,
    /// When this daemon started, for the uptime in `status`.
    started: std.Io.Timestamp,

    /// Connect to SketchyBar, resolving its bootstrap name again first: a bar
    /// that was restarted between two commands registers that name for a new
    /// instance, and the send right held for the old one is dead.
    ///
    /// A bar that is still starting has not registered that name yet, and the one
    /// moment this matters is when `sketchybarrc` applies this configuration: it
    /// runs as the bar starts. A single look arriving too early used to leave a
    /// freshly restarted bar with nothing on it, so this waits for as long as a
    /// start takes - the same wait the control client makes for this daemon, for
    /// the same reason.
    pub fn ensureBar(self: *Context) !void {
        var waited: u32 = 0;
        while (true) {
            self.bar.reconnect();
            self.bar.connect() catch |err| {
                if (waited >= timeouts.start_timeout_ms) return err;
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(timeouts.start_poll_ms), .awake) catch {};
                waited += timeouts.start_poll_ms;
                continue;
            };
            self.bar_present.store(true, .monotonic);
            return;
        }
    }
};
