//! A pomodoro timer, and the notifications that end each interval.
//!
//! The timer belongs to the daemon rather than to the bar: it holds its own
//! deadline on the awake clock and rings whether or not SketchyBar is running, and
//! the daemon pushes the countdown to the item only when it changes - once a
//! second while a phase runs, never while the timer is idle - so no item carries
//! an `update_freq` and no process is forked per tick.

const std = @import("std");

const log = @import("log.zig");
const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const state = @import("store.zig");
const theme = @import("theme.zig");

/// The item the daemon drives.
pub const item = "pomodoro";

/// The two interval lengths the timer starts with, in minutes.
pub const default_work_minutes = 40;
pub const default_rest_minutes = 5;

/// A phase longer than this is a typo rather than an intention.
pub const max_minutes = 600;

/// Where the timer is remembered: separate keys rather than one blob, so the
/// `state` commands can read a running timer a field at a time.
const key_phase = "pomodoro.phase";
const key_ends_at = "pomodoro.ends_at";
const key_remaining = "pomodoro.remaining";
const key_work = "pomodoro.work";
const key_break = "pomodoro.break";

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

    /// The database the timer is remembered in, so a restart - a `brew upgrade`
    /// or a crash - resumes the interval instead of forgetting it.
    store: *state.Store,
    /// Path of `terminal-notifier`, or empty when it is not installed. Resolved
    /// once, by the daemon, and used for the two notifications a cycle posts.
    notifier: []const u8 = "",

    phase: Phase = .work,
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
    reported_error: log.Once = .{},

    pub const Lengths = struct { work: u32, rest: u32 };

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

        // Rounded up, so a fresh interval reads as the length it started with -
        // `40:00`, not `39:59`.
        const seconds = nanos / std.time.ns_per_s + @intFromBool(nanos % std.time.ns_per_s != 0);
        const time = std.fmt.bufPrint(label, "{d:0>2}:{d:0>2}", .{
            seconds / 60,
            seconds % 60,
        }) catch label[0..0];

        // A fresh interval with nothing running is a clock that has not started
        // rather than a countdown, and it shows nothing.
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

    /// Show the timer on its item, if what it shows has changed: one mach message,
    /// and only when the second, the phase or the run state moved.
    fn renderLocked(self: *Timer, io: std.Io, bar: ?*sb.Client) void {
        const client = bar orelse return;

        var key_buffer: [32]u8 = undefined;
        var label_buffer: [8]u8 = undefined;
        const shown = self.appearance(io, &key_buffer, &label_buffer);
        if (std.mem.eql(u8, shown.key, self.shown[0..self.shown_len])) return;

        var props: Props = .{};
        const color = props.argb(shown.color) catch return;
        props.write(.{
            .label = .{ .value = shown.label, .color = color },
            .icon = .{ .color = color },
        }) catch return;

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
        const message = @errorName(err);
        if (self.reported_error.changed(message)) {
            log.warn("pomodoro item update failed: {s}", .{message});
        }
    }

    /// Start counting down from wherever `remaining` stands.
    fn beginLocked(self: *Timer, io: std.Io) void {
        if (self.remaining == 0) self.remaining = self.phaseNanos(self.phase);
        self.deadline = std.Io.Timestamp.now(io, .awake)
            .addDuration(.{ .nanoseconds = @intCast(self.remaining) });
        self.running = true;
    }

    /// Start, or resume a paused phase.
    pub fn start(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.running) return;
        self.beginLocked(io);
        self.saveLocked(io);
    }

    /// Start a paused timer or stop a running one - what a click on the item
    /// asks for.
    pub fn toggle(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.running) {
            self.remaining = self.left(io);
            self.running = false;
        } else {
            self.beginLocked(io);
        }
        self.saveLocked(io);
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
        self.saveLocked(io);
    }

    /// Back to a fresh work interval, stopped.
    pub fn reset(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.phase = .work;
        self.running = false;
        self.remaining = self.phaseNanos(.work);
        self.saveLocked(io);
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
        self.saveLocked(io);
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
        self.saveLocked(io);
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

    /// Write the timer down. Called under the lock on every change of state, and
    /// not on every tick: a running phase is fully described by the instant it
    /// ends, so a second-by-second write would say nothing new.
    fn saveLocked(self: *Timer, io: std.Io) void {
        const store = self.store;

        const ends_at: i64 = if (self.running)
            wallSeconds(io) + @as(i64, @intCast(self.remaining / std.time.ns_per_s))
        else
            0;

        store.setInt(io, key_remaining, @intCast(self.remaining)) catch {};
        store.setInt(io, key_work, @intCast(self.work_seconds / 60)) catch {};
        store.setInt(io, key_break, @intCast(self.rest_seconds / 60)) catch {};
        store.setText(io, key_phase, self.phase.name()) catch {};
        // Written last: a save interrupted half-way then leaves a timer that
        // reads as paused, rather than one pointing at a deadline that belongs
        // to the phase it has already left.
        store.setInt(io, key_ends_at, ends_at) catch {};
    }

    /// Put back what the previous daemon wrote. Called once at startup, before
    /// the first tick - which is what rings for a phase that ends later.
    pub fn restore(self: *Timer, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const store = self.store;
        if (store.getInt(io, key_work) catch null) |minutes| {
            if (minutes > 0 and minutes <= max_minutes) self.work_seconds = @intCast(minutes * 60);
        }
        if (store.getInt(io, key_break) catch null) |minutes| {
            if (minutes > 0 and minutes <= max_minutes) self.rest_seconds = @intCast(minutes * 60);
        }

        var buffer: [32]u8 = undefined;
        if (store.getText(io, key_phase, &buffer) catch null) |value| {
            if (std.mem.eql(u8, value, "break")) self.phase = .rest;
        }
        if (store.getInt(io, key_remaining) catch null) |nanos| {
            if (nanos >= 0) self.remaining = @intCast(nanos);
        }
        self.remaining = @min(self.remaining, self.phaseNanos(self.phase));
        self.running = false;

        const ends_at = (store.getInt(io, key_ends_at) catch null) orelse return;
        if (ends_at <= 0) return;

        const now = wallSeconds(io);
        if (ends_at <= now) {
            // It ran out while this process was not running. Nobody was watching
            // for that notification, so the next phase starts now rather than
            // ringing for an interval that ended unnoticed.
            self.phase = self.phase.other();
            self.remaining = 0;
            self.beginLocked(io);
            self.saveLocked(io);
            return;
        }

        self.remaining = @intCast(@as(i64, @intCast(ends_at - now)) * std.time.ns_per_s);
        self.running = true;
        self.deadline = std.Io.Timestamp.now(io, .awake)
            .addDuration(.{ .nanoseconds = @intCast(self.remaining) });
    }

    /// Post the notification for an interval that ran out, through
    /// `terminal-notifier`: grouped, so a new notification replaces the previous
    /// one. Nothing here asks another application for anything, so nothing here
    /// needs a permission.
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

        // `-sender com.apple.Finder` is gone: terminal-notifier dropped it,
        // because the notification framework will not let it override its bundle
        // identifier.
        const vector = [_:null]?[*:0]const u8{
            program.ptr, "-title",     heading.ptr,
            "-message",  text.ptr,     "-group",
            "pomo",      "-ignoreDnD", "-sound",
            "default",   null,
        };
        // A ring that did not happen is worth saying out loud: the timer would
        // otherwise look like it worked, and the notification is the point.
        const status = platform.kx_exec_status(&vector);
        if (status != 0) {
            log.warn("could not post the interval notification (status {d})", .{status});
        }
    }

    const Notice = struct { title: []const u8, body: []const u8 };
};

/// Seconds since the epoch, for the one thing the awake clock cannot say: when
/// an instant was, in terms another process will understand.
fn wallSeconds(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

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
