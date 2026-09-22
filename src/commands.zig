//! The command registry.
//!
//! Every command is a function over `Context` returning the payload its caller
//! gets. Commands run as worker tasks rather than on the receive loop, so one
//! that spawns yabai a dozen times does not hold up the bar's item updates.
//! `cli.zig` draws the help, the completions and the validation checks from this
//! table, so none of them can drift from what the daemon dispatches on.

const std = @import("std");

const bar_config = @import("bar.zig");
const Context = @import("context.zig").Context;
const exec = @import("exec.zig");
const items_usage = @import("items_usage.zig");
const kanata = @import("kanata.zig");
const kitty = @import("kitty.zig");
const log = @import("log.zig");
const mode_indicator = @import("mode_indicator.zig");
const pomodoro = @import("pomodoro.zig");
const server_mode = @import("server_mode.zig");
const yabai_ops = @import("yabai_ops.zig");
const zen = @import("zen.zig");

/// One command: the name a client spells, what may follow it, and the function
/// that runs it - null for the commands this binary answers itself.
pub const Command = struct {
    /// The name a client spells.
    name: []const u8,
    /// One line for the overview and for the command's own help.
    summary: []const u8,
    /// Words that may follow the name and select a subcommand, whose own
    /// arguments and flags then apply: the first positional must be one of them.
    subcommands: []const Sub = &.{},
    /// Positional arguments, in order; brackets in `name` mark one that may be
    /// left out.
    args: []const Arg = &.{},
    /// Flags, accepted anywhere the command accepts arguments.
    flags: []const Flag = &.{},
    /// Where the command runs; null for `help`, `completions` and `server-mode`,
    /// which the client answers and the daemon is never asked about.
    run: ?*const fn (*Context, []const []const u8) anyerror![]const u8 = null,
};

/// One subcommand: a literal word and what it takes.
pub const Sub = struct {
    /// The word a client types.
    name: []const u8,
    summary: []const u8,
    /// The subcommand a bare `<command>` means, so `kxdesk pomodoro` is
    /// `kxdesk pomodoro status`; at most one per command.
    default: bool = false,
    args: []const Arg = &.{},
    flags: []const Flag = &.{},
};

/// Where a positional argument's values come from; every source but `fixed` is
/// resolved when a completion is asked for.
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
    /// Every quick access terminal configured in kitty.
    terminals,
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

/// The mode indicator's indices, as `set_mode_indicator` accepts them: `1`…`N`
/// select a mode and `-` clears the highlight, over `mode_indicator`'s own table.
const mode_indices = derive: {
    var indices: [mode_indicator.mode_count + 1][]const u8 = undefined;
    for (0..mode_indicator.mode_count) |position| {
        indices[position] = std.fmt.comptimePrint("{d}", .{position + 1});
    }
    indices[mode_indicator.mode_count] = "-";
    break :derive indices;
};

// The fixed word lists `wm`'s verbs take, each derived from the enum that parses
// it so the values offered and the values accepted are the same list. The
// display numbers are the one exception: their bound is the registry's, not the
// parser's, which reads any u8.
const directions = yabai_ops.hyphenTags(yabai_ops.Direction);
const layouts = yabai_ops.hyphenTags(yabai_ops.Layout);
const focus_targets = yabai_ops.hyphenTags(yabai_ops.FocusTarget);
const window_toggles = yabai_ops.hyphenTags(yabai_ops.WindowToggle);
const applications = yabai_ops.hyphenTags(exec.App);
const display_indices = [_][]const u8{ "1", "2", "3", "4" };
const show_desktop_words = [_][]const u8{"show-desktop"};

// One argument per word list, shared by the verbs that take it.
const direction_argument = Arg{
    .name = "<direction>",
    .summary = "west, south, north or east",
    .source = .fixed,
    .values = &directions,
};
const display_argument = Arg{
    .name = "<display>",
    .summary = "the display's number, 1 to 4",
    .source = .fixed,
    .values = &display_indices,
};
const layout_argument = Arg{
    .name = "<layout>",
    .summary = "bsp, stack or float",
    .source = .fixed,
    .values = &layouts,
};
const focus_argument = Arg{
    .name = "<target>",
    .summary = "recent or same-app",
    .source = .fixed,
    .values = &focus_targets,
};
const toggle_argument = Arg{
    .name = "<toggle>",
    .summary = "zoom-fullscreen, native-fullscreen, expose or float-sticky-topmost",
    .source = .fixed,
    .values = &window_toggles,
};
// `<state>` rather than `<toggle>`, which the window states already own: the help
// describes an argument name once, so two different ones must not share a name.
const show_desktop_argument = Arg{
    .name = "<state>",
    .summary = "show-desktop, the one state this verb takes",
    .source = .fixed,
    .values = &show_desktop_words,
};

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

    // The one command that both reports on kanata's channel and can stand in for it.
    .{
        .name = "kanata",
        .summary = "report on the kanata channel, or act on a message from it",
        .subcommands = &.{
            .{ .name = "status", .summary = "say whether the channel is up", .default = true },
            .{
                .name = "inject",
                .summary = "act on a message as if kanata had pushed it",
                .args = &.{
                    .{
                        .name = "<message>",
                        .summary = "an argv line like 'wm window-swap west', or a raw JSON line",
                    },
                },
            },
        },
        .run = kanataCommand,
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
    .{
        .name = "app",
        .summary = "open an application the way the bindings open it",
        .subcommands = &.{
            .{
                .name = "open",
                .summary = "open the named application",
                .args = &.{.{
                    .name = "<app>",
                    .summary = "code, kitty or arc-debug",
                    .source = .fixed,
                    .values = &applications,
                }},
            },
        },
        .run = appCommand,
    },

    // Every window, space and display verb, and yabai's provisioning: the one
    // vocabulary a client types and a key binding in `kanata.kbd` pushes.
    .{
        .name = "wm",
        .summary = "the window, space and display verbs, and yabai's provisioning",
        .subcommands = &.{
            .{
                .name = "cycle-space-windows",
                .summary = "focus the next window of the current space",
                .flags = &.{
                    .{ .name = "--reverse", .summary = "go the other way around" },
                },
            },
            .{
                .name = "cycle-display-spaces",
                .summary = "focus the neighbouring space on the current display",
                .flags = &.{
                    .{ .name = "--reverse", .summary = "go to the previous space instead" },
                },
            },
            .{
                .name = "cycle-displays",
                .summary = "focus the neighbouring display",
                .flags = &.{
                    .{ .name = "--reverse", .summary = "go to the previous display instead" },
                },
            },
            .{
                .name = "switch-workspace",
                .summary = "focus the spaces whose labels are listed",
                .args = &.{
                    .{
                        .name = "<labels>",
                        .summary = "comma-separated space labels; focus lands on one of their display",
                        .source = .space_labels,
                    },
                },
            },
            .{
                .name = "space-labels",
                .summary = "print the label of every labelled space, one per line",
            },
            .{
                .name = "apply-settings",
                .summary = "assert every setting, rule and signal kxdesk manages on yabai",
            },
            .{ .name = "refresh-rules", .summary = "re-provision the yabai rules" },
            .{ .name = "refresh-signals", .summary = "re-provision the yabai signals" },
            .{ .name = "clear-signals", .summary = "drop every configured yabai signal" },
            .{ .name = "refresh-yabai", .summary = "re-provision the yabai rules and signals" },
            .{
                .name = "window-swap",
                .summary = "swap the focused window with its neighbour",
                .args = &.{direction_argument},
            },
            .{
                .name = "window-warp",
                .summary = "send the focused window past its neighbour, tree and all",
                .args = &.{direction_argument},
            },
            .{
                .name = "window-insert",
                .summary = "insert the focused window beside the one under the mouse",
                .args = &.{direction_argument},
            },
            .{
                .name = "window-insert-space",
                .summary = "insert it there and follow it onto that space",
                .args = &.{direction_argument},
            },
            .{
                .name = "window-insert-stack-space",
                .summary = "insert it into the stack under the mouse, and follow it",
            },
            .{
                .name = "window-to-display",
                .summary = "move the focused window to a display",
                .args = &.{display_argument},
            },
            .{
                .name = "display-focus",
                .summary = "focus a display",
                .args = &.{display_argument},
            },
            .{
                .name = "space-to-display",
                .summary = "move the focused space to the display a direction names",
                .args = &.{direction_argument},
            },
            .{
                .name = "space-layout",
                .summary = "set the focused space's layout",
                .args = &.{layout_argument},
            },
            .{
                .name = "space-rotate",
                .summary = "rotate the focused space's tree",
                .args = &.{.{
                    .name = "<degrees>",
                    .summary = "how far round to turn it",
                }},
            },
            .{ .name = "space-balance", .summary = "even out the focused space's tree" },
            .{
                .name = "space-toggle",
                .summary = "hide every window of the focused space, leaving the space up",
                .args = &.{show_desktop_argument},
            },
            .{
                .name = "window-focus",
                .summary = "focus the previous window, or the next of the same application",
                .args = &.{focus_argument},
            },
            .{
                .name = "window-toggle",
                .summary = "toggle a window state",
                .args = &.{toggle_argument},
            },
            .{
                .name = "window-fill-display",
                .summary = "move and size the focused window to fill its display",
            },
            .{ .name = "copy-windows", .summary = "put yabai's window list on the clipboard" },
        },
        .run = yabai_ops.wmRun,
    },
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

    .{
        .name = "term",
        .summary = "show or hide a kitty quick access terminal",
        .subcommands = &.{
            .{
                .name = "toggle",
                .summary = "show the named terminal, or hide it again",
                .default = true,
                .args = &.{.{
                    .name = "<terminal>",
                    .summary = "a terminal in ~/.config/kitty/quick-access-terminals",
                    .source = .terminals,
                }},
            },
        },
        .run = kitty.toggle,
    },

    // The one command with no `run`: it drives `op`, whose 1Password unlock is
    // granted to the session that asked, not to launchd's daemon.
    .{
        .name = "server-mode",
        .summary = "serve this machine as a remote coding server",
        .subcommands = &.{
            .{ .name = "enter", .summary = "materialize the keys, start the agent, and rewire ssh and git" },
            .{ .name = "exit", .summary = "put all of that back and wipe the keys" },
            .{ .name = "toggle", .summary = "enter if the mode is off, exit if it is on" },
            .{ .name = "status", .summary = "say whether the mode is on, and what it serves", .default = true },
            .{ .name = "refresh", .summary = "exit, then enter: for a key or remote added since" },
        },
    },
};

/// Index of the command called `name` in `registry`, or null. The one lookup by
/// name, shared with `cli.find`, whose registry is the daemon's plus its own.
pub fn indexIn(registry: []const Command, name: []const u8) ?usize {
    for (registry, 0..) |command, index| {
        if (std.mem.eql(u8, command.name, name)) return index;
    }
    return null;
}

/// Index in `all` of the command called `name`, or null. An index rather than a
/// pointer, because the daemon keeps one in-flight-task slot per registry entry.
pub fn find(name: []const u8) ?usize {
    return indexIn(&all, name);
}

/// The pomodoro timer; every spelling answers with the timer's state, so
/// `kxdesk pomodoro start` says what it started.
fn pomodoroTimer(context: *Context, args: []const []const u8) ![]const u8 {
    const verb = if (args.len > 0) args[0] else "status";
    const values = if (args.len > 0) args[1..] else args;

    if (std.mem.eql(u8, verb, "start")) {
        // A length given here is this run's work interval; otherwise the stored
        // length stands.
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

    // The item shows the timer, so a change shows now rather than at the next tick.
    const bar = if (context.bar_present.load(.monotonic)) context.bar else null;
    context.pomodoro.render(context.io, bar);

    return context.pomodoro.describe(context.arena, context.io);
}

/// Durable state, reachable from anything that can talk to this daemon. The value
/// is text unless a flag says otherwise: a key binding has nowhere to put a type.
fn stateCommand(context: *Context, args: []const []const u8) ![]const u8 {
    const verb = if (args.len > 0) args[0] else return error.MissingArgument;
    const values = if (args.len > 0) args[1..] else args;
    const store = context.store;

    if (std.mem.eql(u8, verb, "get")) {
        if (values.len == 0) return error.MissingArgument;
        // A missing key is not an empty value: a script has to be able to tell
        // them apart.
        return try store.getTextAlloc(context.io, context.arena, values[0]) orelse error.KeyNotFound;
    }

    if (std.mem.eql(u8, verb, "set")) {
        if (values.len == 0) return error.MissingArgument;
        const key = values[0];

        // A null has no value to spell, so its flag stands where the value would be.
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

/// Apply the bar configuration. Re-applying points every item's `mach_helper` at
/// this daemon again, so a SketchyBar that was restarted ends up with the items
/// this process serves.
fn apply(context: *Context, _: []const []const u8) ![]const u8 {
    try context.ensureBar();
    try bar_config.apply(context.bar, context.io, .{ .helper = context.event_service });
    // A freshly built bar knows nothing about the state the last one was in, and
    // the provider items have just been given placeholder labels.
    restoreState(context);
    items_usage.invalidate();
    return "";
}

/// Put back the state the bar configuration cannot rebuild: a bar that was
/// collapsed, the mode the spaces were highlighted in, and whether this machine is
/// serving. Best effort by design: all of it is cosmetic.
pub fn restoreState(context: *Context) void {
    zen.restore(context.bar, context.arena, context.store, context.io) catch |err| {
        log.warn("cannot restore the bar's collapsed state: {s}", .{@errorName(err)});
    };
    mode_indicator.restore(context);
    // The server item's state lives in the file `enter` wrote rather than in the
    // store, since the daemon never runs that command; see `server_mode.restore`.
    server_mode.restore(context);
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

/// Report on the kanata channel, or act on a message as if kanata had pushed it:
/// the injection runs the same lookup, the same check and the same command the
/// socket path does, which is what makes a binding testable without pressing its
/// keys.
fn kanataCommand(context: *Context, args: []const []const u8) ![]const u8 {
    const verb = if (args.len > 0) args[0] else return kanata.status(context.arena);
    const values = if (args.len > 0) args[1..] else args;

    if (std.mem.eql(u8, verb, "status")) return kanata.status(context.arena);
    if (std.mem.eql(u8, verb, "inject")) {
        if (values.len == 0) return error.MissingArgument;
        return kanata.inject(context, values[0]);
    }
    return error.UnknownArgument;
}

/// Open one of the applications the bindings open.
fn appCommand(context: *Context, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return error.MissingArgument;
    const application = yabai_ops.wordToEnum(exec.App, args[1]) orelse return error.InvalidValue;
    try exec.openApp(context.arena, application);
    return "";
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

    const parsed = context.bar.query(Bar, context.arena, "bar") catch
        return error.InvalidSketchyBarResponse;
    return parsed.items.len;
}
