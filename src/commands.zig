//! The command registry.
//!
//! Every command is a function over `Context` that returns the payload to send
//! back to whoever asked. Commands run as worker tasks rather than on the
//! receive loop, so one that spawns yabai a dozen times does not hold up the
//! bar's item updates while it works.

const std = @import("std");

const bar_config = @import("bar.zig");
const items_usage = @import("items_usage.zig");
const mode_indicator = @import("mode_indicator.zig");
const pomodoro = @import("pomodoro.zig");
const sb = @import("sb.zig");
const state = @import("store.zig");
const skhdrc = @import("skhdrc.zig");
const yabai = @import("yabai.zig");
const yabai_ops = @import("yabai_ops.zig");
const zen = @import("zen.zig");

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
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            self.bar.reconnect();
            self.bar.connect() catch |err| {
                if (attempt >= bar_connect_attempts) return err;
                std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(bar_connect_delay_ms), .awake) catch {};
                continue;
            };
            self.bar_present.store(true, .monotonic);
            return;
        }
    }
};

/// How long `ensureBar` waits for a bar that is starting: long enough to cover a
/// restart, short enough that a command on a machine with no bar at all still
/// fails quickly.
const bar_connect_attempts = 20;
const bar_connect_delay_ms = 150;

/// What a command takes after its name, in the terms the usage line is drawn
/// from: `kxdesk pomodoro set 25 5` is `set` (a `Sub`) with `<work>` and
/// `[<rest>]` (`Arg`s), and there is no other spelling of that.
///
/// The whole command line is described here rather than written out twice, so
/// `--help` and the shell completions are derived from the same table the daemon
/// dispatches on and cannot drift from it.
pub const Command = struct {
    /// The name a client spells.
    name: []const u8,
    /// One line for the overview and for a command's own help.
    summary: []const u8,
    /// Words that may follow the name and select a subcommand: the first
    /// positional is one of these, and its own arguments and flags apply after
    /// it. Empty when the command takes plain arguments or none.
    subcommands: []const Sub = &.{},
    /// Positional arguments, in order. Brackets in `name` mark one that may be
    /// left out.
    args: []const Arg = &.{},
    /// Flags, accepted anywhere the command accepts arguments.
    flags: []const Flag = &.{},
    /// Where the command runs. Null for the commands this binary answers itself,
    /// which the daemon is never asked about: `help` and `completions`, which a
    /// shell asks for while it is being set up, before any daemon need be
    /// running, and `server-mode`, which drives `op` and so belongs to the
    /// session that asked rather than to launchd's daemon.
    run: ?*const fn (*Context, []const []const u8) anyerror![]const u8 = null,
};

/// One subcommand of a `Command`: a literal word, and what it takes.
pub const Sub = struct {
    /// The word a client types.
    name: []const u8,
    summary: []const u8,
    /// The subcommand a bare `<command>` means, so `kxdesk pomodoro` is
    /// `kxdesk pomodoro status`. At most one per command.
    default: bool = false,
    args: []const Arg = &.{},
    flags: []const Flag = &.{},
};

/// Where a positional argument's values come from. The ones that are not `fixed`
/// are resolved when a completion is asked for, which is why the values are not
/// written down here.
pub const Source = enum {
    /// The user's to type; there is nothing to offer.
    free,
    /// The `values` below.
    fixed,
    /// Every command in this registry (`help`).
    commands,
    /// Every key in the daemon's state store.
    state_keys,
    /// Every space label yabai knows.
    space_labels,
};

/// One positional argument.
pub const Arg = struct {
    /// How the usage line spells it, brackets included when it may be omitted.
    name: []const u8,
    summary: []const u8,
    /// Where its values come from.
    source: Source = .free,
    /// The values a `fixed` argument accepts, which are also the completions and
    /// the check a malformed request is refused by.
    values: []const []const u8 = &.{},
};

/// One flag. Every flag here stands alone; none takes a value.
pub const Flag = struct {
    name: []const u8,
    summary: []const u8,
};

/// The mode indicator's indices, as `set_mode_indicator` accepts them: `1`…`7`
/// select a mode, `-` clears the highlight.
const mode_indices = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "-" };

pub const all = [_]Command{
    .{
        .name = "apply",
        .summary = "apply the bar configuration to a running SketchyBar",
        .run = apply,
    },
    .{
        .name = "status",
        .summary = "report what the daemon is doing",
        .run = status,
    },
    .{
        .name = "zen",
        .summary = "collapse the bar down to the essentials, or restore it",
        .subcommands = &.{
            .{ .name = "on", .summary = "collapse the bar to the essentials" },
            .{ .name = "off", .summary = "restore everything the bar had" },
            .{ .name = "toggle", .summary = "flip whatever state the bar is in", .default = true },
        },
        .run = zenMode,
    },

    // Navigation, reached from the bindings in `~/.skhdrc`.
    .{
        .name = "cycle_space_windows",
        .summary = "focus the next window of the current space",
        .flags = &.{
            .{ .name = "--reverse", .summary = "go the other way around" },
        },
        .run = yabai_ops.cycleSpaceWindows,
    },
    .{
        .name = "cycle_display_spaces",
        .summary = "focus the neighbouring space on the current display",
        .flags = &.{
            .{ .name = "--reverse", .summary = "go to the previous space instead" },
        },
        .run = yabai_ops.cycleDisplaySpaces,
    },
    .{
        .name = "cycle_displays",
        .summary = "focus the neighbouring display",
        .flags = &.{
            .{ .name = "--reverse", .summary = "go to the previous display instead" },
        },
        .run = yabai_ops.cycleDisplays,
    },
    .{
        .name = "switch_workspace",
        .summary = "focus the spaces whose labels are listed",
        .args = &.{
            .{
                .name = "<labels>",
                .summary = "comma-separated space labels; focus lands on one of their display",
                .source = .space_labels,
            },
        },
        .run = yabai_ops.switchWorkspace,
    },
    .{
        .name = "space_labels",
        .summary = "print the label of every labelled space, one per line",
        .run = yabai_ops.spaceLabels,
    },

    // Provisioning, reached from `~/.yabairc` and from the bindings that
    // reload the rules and signals after an edit.
    .{
        .name = "apply_settings",
        .summary = "assert every setting, rule and signal kxdesk manages on yabai",
        .run = yabai_ops.applySettings,
    },
    .{
        .name = "refresh_rules",
        .summary = "re-provision the yabai rules",
        .run = yabai_ops.refreshRules,
    },
    .{
        .name = "refresh_signals",
        .summary = "re-provision the yabai signals",
        .run = yabai_ops.refreshSignals,
    },
    .{
        .name = "clear_signals",
        .summary = "drop every configured yabai signal",
        .run = yabai_ops.clearSignals,
    },
    .{
        .name = "generate_skhdrc",
        .summary = "regenerate ~/.skhdrc from ~/.skhdrc.template",
        .run = skhdrc.generate,
    },

    // Appearance.
    .{
        .name = "set_mode_indicator",
        .summary = "set the colour the space icons highlight with",
        .args = &.{
            .{
                .name = "<mode>",
                .summary = "a mode index, or - for no mode",
                .source = .fixed,
                .values = &mode_indices,
            },
        },
        .run = mode_indicator.setMode,
    },

    // The timer on the bar, and the intervals it ends.
    .{
        .name = "pomodoro",
        .summary = "run the interval timer on the bar",
        .subcommands = &.{
            .{
                .name = "start",
                .summary = "start the timer",
                .args = &.{
                    .{
                        .name = "[<minutes>]",
                        .summary = "length of the work interval for this run; keeps the stored one when omitted",
                    },
                },
            },
            .{ .name = "pause", .summary = "stop the countdown, keeping the phase" },
            .{ .name = "reset", .summary = "put the timer back to a fresh work interval" },
            .{ .name = "skip", .summary = "end the current phase and start the next" },
            .{
                .name = "set",
                .summary = "set the interval lengths",
                .args = &.{
                    .{ .name = "<work>", .summary = "length of a work interval, in minutes" },
                    .{ .name = "[<rest>]", .summary = "length of a rest interval, in minutes; unchanged when omitted" },
                },
            },
            .{ .name = "status", .summary = "say what the timer is doing", .default = true },
        },
        .run = pomodoroTimer,
    },

    // Durable state, for this daemon and for anything that speaks to it.
    .{
        .name = "state",
        .summary = "read and write the daemon's durable state",
        .subcommands = &.{
            .{
                .name = "get",
                .summary = "print the value stored under a key",
                .args = &.{
                    .{ .name = "<key>", .summary = "the key to read", .source = .state_keys },
                },
            },
            .{
                .name = "set",
                .summary = "store a value under a key",
                .args = &.{
                    .{ .name = "<key>", .summary = "the key to write", .source = .state_keys },
                    .{ .name = "[<value>]", .summary = "the value; left out with --null" },
                },
                .flags = &.{
                    .{ .name = "--int", .summary = "store the value as a whole number" },
                    .{ .name = "--real", .summary = "store the value as a decimal number" },
                    .{ .name = "--null", .summary = "store nothing, whatever the key held before" },
                },
            },
            .{
                .name = "unset",
                .summary = "drop a key",
                .args = &.{
                    .{ .name = "<key>", .summary = "the key to drop", .source = .state_keys },
                },
            },
            .{
                .name = "list",
                .summary = "print the keys, one per line",
                .args = &.{
                    .{ .name = "[<prefix>]", .summary = "only keys starting with this" },
                },
            },
        },
        .run = stateCommand,
    },

    // This machine as a remote coding server: the 1Password keys served over one
    // ssh-agent, and the ssh and git configuration that points at it. The one
    // command with no `run`: it is the client's, because it drives `op` and
    // 1Password's unlock is granted to the session that asked, not to the daemon.
    .{
        .name = "server-mode",
        .summary = "serve this machine as a remote coding server",
        .subcommands = &.{
            .{ .name = "enter", .summary = "materialize the keys, start the agent, and rewire ssh and git" },
            .{ .name = "exit", .summary = "put all of that back and wipe the keys" },
            .{ .name = "status", .summary = "say whether the mode is on, and what it serves", .default = true },
            .{ .name = "refresh", .summary = "exit, then enter: for a key or remote added since" },
        },
    },
};

/// Index of the command called `name`, or null. An index rather than a pointer,
/// because the daemon keeps one in-flight-task slot per registry entry.
pub fn find(name: []const u8) ?usize {
    for (all, 0..) |command, index| {
        if (std.mem.eql(u8, command.name, name)) return index;
    }
    return null;
}

/// The pomodoro timer: start it, stop it, reset it, skip a phase, or set the
/// interval lengths. Every spelling answers with the timer's state, so
/// `kxdesk pomodoro start` says what it started.
fn pomodoroTimer(context: *Context, args: []const []const u8) ![]const u8 {
    const verb = if (args.len > 0) args[0] else "status";
    const values = if (args.len > 0) args[1..] else args;

    if (std.mem.eql(u8, verb, "start")) {
        // Started with a length, it is the work interval for this run; without
        // one the timer keeps the lengths it has.
        if (values.len > 0) {
            const lengths = context.pomodoro.lengths(context.io);
            const work = try pomodoro.parseMinutes(values[0]);
            context.pomodoro.setDurations(context.io, work, lengths.rest);
        }
        context.pomodoro.start(context.io);
    } else if (std.mem.eql(u8, verb, "pause")) {
        context.pomodoro.pause(context.io);
    } else if (std.mem.eql(u8, verb, "reset")) {
        context.pomodoro.reset(context.io);
    } else if (std.mem.eql(u8, verb, "skip")) {
        context.pomodoro.skip(context.io);
    } else if (std.mem.eql(u8, verb, "set")) {
        if (values.len == 0) return error.MissingArgument;
        const lengths = context.pomodoro.lengths(context.io);
        const work = try pomodoro.parseMinutes(values[0]);
        const rest = if (values.len > 1) try pomodoro.parseMinutes(values[1]) else lengths.rest;
        context.pomodoro.setDurations(context.io, work, rest);
    } else if (!std.mem.eql(u8, verb, "status")) {
        return error.UnknownArgument;
    }

    // The item shows the timer, so a command that changed it shows the change
    // now rather than at the next tick.
    const bar = if (context.bar_present.load(.monotonic)) context.bar else null;
    context.pomodoro.render(context.io, bar);

    return context.pomodoro.describe(context.arena, context.io);
}

/// Durable state, reachable from anything that can talk to this daemon: a key
/// binding, a plugin, a shell prompt, or one of the items above.
///
/// The value is text unless a flag says otherwise, because a key binding has
/// nowhere to put a type: `state set layout grid`, `state set pomodoro.work 25
/// --int`.
fn stateCommand(context: *Context, args: []const []const u8) ![]const u8 {
    const verb = if (args.len > 0) args[0] else return error.MissingArgument;
    const values = if (args.len > 0) args[1..] else args;
    const store = context.store;

    if (std.mem.eql(u8, verb, "get")) {
        if (values.len == 0) return error.MissingArgument;
        // A missing key is not an empty value: a script has to be able to tell
        // them apart, and only one of the two is worth falling back from.
        return try store.getTextAlloc(context.io, context.arena, values[0]) orelse error.KeyNotFound;
    }

    if (std.mem.eql(u8, verb, "set")) {
        if (values.len == 0) return error.MissingArgument;
        const key = values[0];

        // A null has no value to spell, so its flag stands where the value would
        // be: `state set scratch --null`.
        if (values.len >= 2 and std.mem.eql(u8, values[1], "--null")) {
            try store.setNull(context.io, key);
            return "";
        }
        if (values.len < 2) return error.MissingArgument;
        const raw = values[1];

        var integer = false;
        var real = false;
        for (values[2..]) |flag| {
            if (std.mem.eql(u8, flag, "--int")) {
                integer = true;
            } else if (std.mem.eql(u8, flag, "--real")) {
                real = true;
            } else return error.UnknownArgument;
        }

        if (integer) {
            try store.setInt(context.io, key, std.fmt.parseInt(i64, raw, 10) catch return error.InvalidValue);
        } else if (real) {
            try store.setReal(context.io, key, std.fmt.parseFloat(f64, raw) catch return error.InvalidValue);
        } else {
            try store.setText(context.io, key, raw);
        }
        return "";
    }

    if (std.mem.eql(u8, verb, "unset")) {
        if (values.len == 0) return error.MissingArgument;
        try store.unset(context.io, values[0]);
        return "";
    }

    if (std.mem.eql(u8, verb, "list")) {
        const keys = try store.keys(context.io, context.arena, if (values.len > 0) values[0] else "");
        return std.mem.join(context.arena, "\n", keys) catch return error.OutOfMemory;
    }

    return error.UnknownArgument;
}

/// Apply the bar configuration.
///
/// This is what `sketchybarrc` runs, and it is the only thing that applies it:
/// re-applying points every item's `mach_helper` at this daemon again, so a
/// SketchyBar that was restarted ends up with the items this process serves.
fn apply(context: *Context, _: []const []const u8) ![]const u8 {
    try context.ensureBar();
    try bar_config.apply(context.bar, .{ .helper = context.event_service });
    // A freshly built bar knows nothing about the state the last one was in, and
    // the provider items have just been given placeholder labels.
    restoreState(context);
    items_usage.invalidate();
    return "";
}

/// Put back the state the bar configuration cannot rebuild by itself: a bar that
/// was collapsed, and the mode the spaces were highlighted in.
///
/// Best effort by design - all of it is cosmetic, and none of it is a reason to
/// fail the `apply` that just succeeded.
pub fn restoreState(context: *Context) void {
    zen.restore(context.bar, context.arena, context.store, context.io) catch |err| {
        std.debug.print("kxdesk: cannot restore the bar's collapsed state: {s}\n", .{@errorName(err)});
    };
    mode_indicator.restore(context);
}

/// Report what the daemon is doing, in one line.
fn status(context: *Context, _: []const []const u8) ![]const u8 {
    const present = context.bar_present.load(.monotonic);
    const items = if (present) itemCount(context) catch 0 else 0;

    const now = std.Io.Timestamp.now(context.io, .awake);
    const seconds = now.nanoseconds - context.started.nanoseconds;

    return std.fmt.allocPrint(context.arena, "pid={d} uptime={d} bar={s} items={d} state={s}", .{
        std.c.getpid(),
        @divTrunc(seconds, std.time.ns_per_s),
        if (present) "connected" else "gone",
        items,
        if (context.store.enabled()) "on" else "off",
    });
}

/// Collapse the bar down to the essentials, or restore it. The calendar's click
/// reaches this too, which is why the mode is optional.
fn zenMode(context: *Context, args: []const []const u8) ![]const u8 {
    const mode: zen.Mode = if (args.len > 0) blk: {
        if (std.mem.eql(u8, args[0], "on")) break :blk .on;
        if (std.mem.eql(u8, args[0], "off")) break :blk .off;
        break :blk .toggle;
    } else .toggle;

    try context.ensureBar();
    try zen.set(context.bar, context.arena, mode, context.store, context.io);
    return "";
}

/// How many items the running SketchyBar has.
fn itemCount(context: *Context) !usize {
    const Bar = struct {
        items: []const []const u8 = &.{},
    };

    var response: [64 * 1024]u8 = undefined;
    try context.bar.connect();
    context.bar.clear();
    try context.bar.arg("--query");
    try context.bar.arg("bar");
    const body = try context.bar.commitInto(&response);

    const parsed = std.json.parseFromSliceLeaky(Bar, context.arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return error.InvalidSketchyBarResponse;
    return parsed.items.len;
}
