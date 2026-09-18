//! A pomodoro timer, and the notifications that end each interval.
//!
//! The timer belongs to the daemon rather than to the bar. It holds its own
//! deadline on the awake clock and rings whether or not SketchyBar is running,
//! and the bar item is only a view of it: the daemon pushes the countdown to the
//! item when it changes - once a second while a phase runs, and not at all while
//! the timer is idle - so no item carries an `update_freq`, nothing polls, and
//! no process is forked per tick.
//!
//! The intervals and the wording of the two notifications are the ones from the
//! shell `pomo` function this replaces: forty minutes of work, five of rest, and
//! `terminal-notifier` posting through Finder. Flow used to own that clock; its
//! timer could only be read by asking Flow over an Apple Event, which needs
//! permission that macOS asks for again for every new binary, so the clock is
//! this daemon's own now.

const std = @import("std");

const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const theme = @import("theme.zig");

/// The item the daemon drives.
pub const item = "pomodoro";

/// The shell function's intervals, kept as the defaults.
pub const default_work_minutes = 40;
pub const default_rest_minutes = 5;

/// A phase longer than this is a typo rather than an intention.
pub const max_minutes = 600;

/// Which half of the cycle is running.
pub const Phase = enum {
    work,
    rest,

    fn other(self: Phase) Phase {
        return switch (self) {
            .work => .rest,
            .rest => .work,
        };
    }

    /// What the item is coloured while this phase runs.
    fn color(self: Phase) theme.Color {
        return switch (self) {
            .work => theme.magenta,
            .rest => theme.aqua,
        };
    }

    /// How the phase is spelled in a reply.
    fn name(self: Phase) []const u8 {
        return switch (self) {
            .work => "work",
            .rest => "break",
        };
    }

    /// What the phase is called in the way of a sentence.
    fn description(self: Phase) []const u8 {
        return switch (self) {
            .work => "work",
            .rest => "rest",
        };
    }
};

pub const Timer = struct {
    /// Held by the receive loop's tick and by every command that touches the
    /// timer, which run on different threads.
    mutex: std.Io.Mutex = .init,

    /// Path of `terminal-notifier`, or empty when it is not installed. Resolved
    /// once, by the daemon, and used for the two notifications a cycle posts.
    notifier: []const u8 = "",

    phase: Phase = .work,
    /// Interval lengths in seconds.
    work_seconds: u32 = default_work_minutes * 60,
    rest_seconds: u32 = default_rest_minutes * 60,

    running: bool = false,
    /// Nanoseconds left in the current phase. The truth while paused, and
    /// refreshed from `deadline` for readers while running.
    remaining: u64 = default_work_minutes * 60 * std.time.ns_per_s,
    /// Awake-clock instant the current phase ends; meaningful while running. The
    /// awake clock stops while the machine sleeps, so a nap does not eat the
    /// interval.
    deadline: std.Io.Timestamp = .zero,

    /// What the item was last told to show, so that a tick which changes nothing
    /// visible sends nothing. Empty means "nothing has been shown yet".
    shown: [32]u8 = @splat(0),
    shown_len: usize = 0,

    /// The last failure reported, so a bar that stays broken is complained about
    /// once rather than once a second.
    reported_error: ?[]const u8 = null,

    pub const Lengths = struct { work: u32, rest: u32 };

    // -- what the timer shows -------------------------------------------------

    /// Nanoseconds left in the current phase.
    fn left(self: *const Timer, io: std.Io) u64 {
        if (!self.running) return self.remaining;
        const nanos = self.deadline.nanoseconds - std.Io.Timestamp.now(io, .awake).nanoseconds;
        return if (nanos <= 0) 0 else @intCast(nanos);
    }

    fn phaseNanos(self: *const Timer, phase: Phase) u64 {
        const seconds = switch (phase) {
            .work => self.work_seconds,
            .rest => self.rest_seconds,
        };
        return @as(u64, seconds) * std.time.ns_per_s;
    }

    /// How the item looks right now: the label, the colour, and a key that
    /// changes exactly when either of them does.
    const Appearance = struct {
        key: []const u8,
        /// What the item's label shows: the countdown, or nothing at all for a
        /// phase that has not started.
        label: []const u8,
        /// The time itself, always - what a report of the timer quotes.
        time: []const u8,
        color: theme.Color,
    };

    fn appearance(self: *const Timer, io: std.Io, key: *[32]u8, label: *[8]u8) Appearance {
        const nanos = self.left(io);

        // Rounded up, so a fresh interval reads as the length it started with:
        // forty minutes is `40:00`, not `39:59`.
        const seconds = nanos / std.time.ns_per_s + @intFromBool(nanos % std.time.ns_per_s != 0);
        const time = std.fmt.bufPrint(label, "{d:0>2}:{d:0>2}", .{
            seconds / 60,
            seconds % 60,
        }) catch label[0..0];

        // A fresh interval with nothing running is not a countdown, it is a
        // clock that has not started, and it shows nothing.
        const waiting = !self.running and nanos == self.phaseNanos(self.phase);
        const text = if (waiting) "" else time;
        const color = if (self.running) self.phase.color() else theme.dark_grey;

        const built = std.fmt.bufPrint(key, "{s}:{d}:{s}", .{
            self.phase.name(),
            @intFromBool(self.running),
            text,
        }) catch key[0..0];

        return .{ .key = built, .label = text, .time = time, .color = color };
    }

    /// Show the timer on its item, if what it shows has changed.
    ///
    /// Cheap by design: one mach message, and only when the second, the phase or
    /// the run state moved.
    fn renderLocked(self: *Timer, io: std.Io, bar: ?*sb.Client) void {
        const client = bar orelse return;

        var key_buffer: [32]u8 = undefined;
        var label_buffer: [8]u8 = undefined;
        const shown = self.appearance(io, &key_buffer, &label_buffer);
        if (std.mem.eql(u8, shown.key, self.shown[0..self.shown_len])) return;

        var props: Props = .{};
        props.fmt("label={s}", .{shown.label}) catch return;
        props.color("label.color", shown.color) catch return;
        props.color("icon.color", shown.color) catch return;

        client.set(item, props.slice()) catch |err| return self.report(err);
        client.commit() catch |err| return self.report(err);

        // Only recorded once the bar has it, so a failed update is retried on
        // the next tick rather than lost.
        @memcpy(self.shown[0..shown.key.len], shown.key);
        self.shown_len = shown.key.len;
    }

    /// Show the timer, taking the lock. For callers outside the receive loop.
    pub fn render(self: *Timer, io: std.Io, bar: ?*sb.Client) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.renderLocked(io, bar);
    }

    fn report(self: *Timer, err: anyerror) void {
        self.shown_len = 0;
        if (self.reported_error) |last| {
            if (std.mem.eql(u8, last, @errorName(err))) return;
        }
        self.reported_error = @errorName(err);
        std.debug.print("kxdesk: pomodoro item update failed: {s}\n", .{@errorName(err)});
    }

    // -- what the timer does --------------------------------------------------

    /// Start, or resume a paused phase.
    pub fn start(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.running) return;
        if (self.remaining == 0) self.remaining = self.phaseNanos(self.phase);
        self.deadline = std.Io.Timestamp.now(io, .awake)
            .addDuration(.{ .nanoseconds = @intCast(self.remaining) });
        self.running = true;
    }

    /// Start a paused timer or stop a running one - what a click on the item
    /// asks for.
    pub fn toggle(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.running) {
            self.remaining = self.left(io);
            self.running = false;
            return;
        }
        if (self.remaining == 0) self.remaining = self.phaseNanos(self.phase);
        self.deadline = std.Io.Timestamp.now(io, .awake)
            .addDuration(.{ .nanoseconds = @intCast(self.remaining) });
        self.running = true;
    }

    /// The interval lengths as they stand, in minutes.
    pub fn lengths(self: *Timer, io: std.Io) Lengths {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{ .work = self.work_seconds / 60, .rest = self.rest_seconds / 60 };
    }

    /// Stop the countdown where it stands.
    pub fn pause(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.remaining = self.left(io);
        self.running = false;
    }

    /// Back to a fresh work interval, stopped.
    pub fn reset(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.phase = .work;
        self.running = false;
        self.remaining = self.phaseNanos(.work);
    }

    /// End the current phase early. Deliberate, so it is silent: the
    /// notification is for an interval that ran out.
    pub fn skip(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.advance(io, false);
    }

    /// Set the interval lengths, in minutes. A phase already under way keeps the
    /// time it has left; the new lengths apply from the next phase on.
    pub fn setDurations(self: *Timer, io: std.Io, work_minutes: u32, rest_minutes: u32) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const was_fresh = !self.running and self.remaining == self.phaseNanos(self.phase);
        self.work_seconds = work_minutes * 60;
        self.rest_seconds = rest_minutes * 60;
        if (was_fresh) self.remaining = self.phaseNanos(self.phase);
    }

    /// Move to the other phase, keeping the run state. `ring` posts the
    /// notification for the interval that just ended.
    fn advance(self: *Timer, io: std.Io, ring: bool) void {
        const finished = self.phase;
        self.phase = finished.other();
        self.remaining = self.phaseNanos(self.phase);
        if (self.running) {
            self.deadline = std.Io.Timestamp.now(io, .awake)
                .addDuration(.{ .nanoseconds = @intCast(self.remaining) });
        }
        if (ring) self.notify(finished);
    }

    /// The receive loop's time-based work: end a phase that has run out, and
    /// show the item whatever it should be showing now.
    ///
    /// Called on the loop, so it must not block: the only thing here that can
    /// take a moment is the notification, which happens twice per cycle.
    pub fn tick(self: *Timer, io: std.Io, bar: ?*sb.Client) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.running) {
            const nanos = self.left(io);
            if (nanos == 0) {
                self.advance(io, true);
            } else {
                self.remaining = nanos;
            }
        }

        self.renderLocked(io, bar);
    }

    /// How long the receive loop may wait for a message before this timer needs
    /// attention again, in milliseconds, or 0 when nothing is scheduled and the
    /// loop may wait indefinitely.
    ///
    /// Wakes at the moment the displayed second changes, which is the only thing
    /// a tick can change.
    pub fn waitMs(self: *Timer, io: std.Io) u32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.running) return 0;

        const nanos = self.left(io);
        if (nanos == 0) return 1;

        const into_second = @mod(nanos, std.time.ns_per_s);
        const milliseconds = if (into_second == 0)
            std.time.ms_per_s
        else
            @divTrunc(into_second, std.time.ns_per_ms);
        return @intCast(@max(milliseconds, 20));
    }

    /// One line describing the timer, for `pomodoro status` and for the reply to
    /// every other `pomodoro` spelling.
    pub fn describe(self: *Timer, arena: std.mem.Allocator, io: std.Io) ![]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var key_buffer: [32]u8 = undefined;
        var label_buffer: [8]u8 = undefined;
        const shown = self.appearance(io, &key_buffer, &label_buffer);

        return std.fmt.allocPrint(arena, "phase={s} remaining={s} running={s} work={d}m break={d}m", .{
            self.phase.name(),
            shown.time,
            if (self.running) "yes" else "no",
            self.work_seconds / 60,
            self.rest_seconds / 60,
        });
    }

    // -- the notification -----------------------------------------------------

    /// Post the notification for an interval that ran out.
    ///
    /// The flags are the shell function's - same group, so a new notification
    /// replaces the previous one, same sound, attributed to Finder - and the
    /// process is the one that function already uses. Nothing here asks another
    /// application for anything, so nothing here needs a permission.
    fn notify(self: *Timer, finished: Phase) void {
        if (self.notifier.len == 0) return;

        const notice: Notice = switch (finished) {
            .work => .{ .title = "Time for a break!", .body = "The work interval ended." },
            .rest => .{ .title = "Break is over!", .body = "The break ended." },
        };

        var path: [std.fs.max_path_bytes]u8 = undefined;
        var title: [64]u8 = undefined;
        var body: [64]u8 = undefined;
        const program = std.fmt.bufPrintZ(&path, "{s}", .{self.notifier}) catch return;
        const heading = std.fmt.bufPrintZ(&title, "{s}", .{notice.title}) catch return;
        const text = std.fmt.bufPrintZ(&body, "{s}", .{notice.body}) catch return;

        const vector = [_:null]?[*:0]const u8{
            program.ptr,     "-title",   heading.ptr,
            "-message",      text.ptr,   "-group",
            "pomo",          "-ignoreDnD", "-sound",
            "default",       "-sender",  "com.apple.Finder",
            null,
        };
        _ = platform.sb_exec_status(&vector);
    }

    const Notice = struct { title: []const u8, body: []const u8 };
};

/// Parse the minutes an argument spells, refusing anything that is not a
/// plausible interval.
pub fn parseMinutes(text: []const u8) !u32 {
    const minutes = std.fmt.parseInt(u32, text, 10) catch return error.InvalidArgument;
    if (minutes == 0 or minutes > max_minutes) return error.InvalidArgument;
    return minutes;
}

/// The `break` phase, under the name a person would use for it.
pub fn describePhase(phase: Phase) []const u8 {
    return phase.description();
}
