//! kxdesk - personal desktop daemon.
//!
//! One process serves two things over one mach port:
//!
//! * SketchyBar's item events. Items declare `mach_helper=org.kdressler.kxdesk`
//!   and the bar routes their events here, so a click or a scheduled refresh
//!   costs one message instead of a process.
//! * A command channel, under a second bootstrap name on the same port, that
//!   `kxdesk <command> [arguments...]` clients use. The bar's config script,
//!   `~/.yabairc`, yabai signals and key bindings all speak through it.
//!
//! `kxdesk daemon` is the process itself and is started by launchd, so it starts
//! before SketchyBar and outlives it: it applies the configuration on startup
//! when the bar is already up, and otherwise waits for the bar's config script
//! to ask. `version`, `--help`/`help` and `completions` are answered by the
//! binary itself, so they work when nothing is listening - and a shell setting
//! itself up has something to complete against before the agent is up. Every
//! other spelling is a client that asks the daemon to run the command; the
//! command line is described once, in `commands.zig`, and `cli.zig` draws both
//! the help and the completions from it.
//!
//! `server-mode` is answered by the client too, and for the opposite reason: it
//! drives `op`, whose 1Password unlock the desktop app grants only to the session
//! that asked - which a launchd agent is not.

const std = @import("std");

const app_icons = @import("app_icons.zig");
const background = @import("background.zig");
const build_options = @import("build_options");
const bar_config = @import("bar.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const context = @import("context.zig");
const control = @import("control.zig");
const dispatch = @import("dispatch.zig");
const items_system = @import("items_system.zig");
const items_yabai = @import("items_yabai.zig");
const kanata = @import("kanata.zig");
const platform = @import("platform.zig");
const pomodoro = @import("pomodoro.zig");
const server_mode = @import("server_mode.zig");
const state = @import("store.zig");
const sb = @import("sb.zig");
const yabai = @import("yabai.zig");

/// Bootstrap name every `mach_helper` property refers to. SketchyBar resolves it
/// once, while parsing that property, so it has to be registered before any item
/// is told to point at it.
pub const event_service: [:0]const u8 = "org.kdressler.kxdesk";

/// Buffer for SketchyBar query responses, which are only a few kilobytes.
const response_size = 64 * 1024;

/// The serve loop is a C callback with no context pointer, so the daemon is
/// reached through this single live reference.
var active_daemon: ?*Daemon = null;

/// Everything the receive loop and the commands share.
const Daemon = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The receive loop's own channel to SketchyBar. Handlers run one at a time,
    /// so sharing it is safe; commands build their own.
    bar: *sb.Client,
    yabai_client: *yabai.Client,
    /// The pomodoro timer, shared with the receive loop and the commands.
    pomodoro: *pomodoro.Timer,
    /// Durable state, shared with the commands.
    store: *state.Store,
    dispatcher: dispatch.Dispatcher,
    started: std.Io.Timestamp,

    /// Whether SketchyBar is known to be up. Neither state is fatal: the daemon
    /// starts before the bar and is expected to keep serving after it is gone.
    present: std.atomic.Value(bool) = .init(false),

    /// One in-flight-task slot per registered command, so a command never runs
    /// twice at once and the receive loop never waits for a task to finish.
    slots: [commands.all.len]background.Slot = @splat(.{}),

    fn commandContext(self: *Daemon, arena: std.mem.Allocator, bar: *sb.Client) context.Context {
        return .{
            .arena = arena,
            .io = self.io,
            .bar = bar,
            .yabai = self.yabai_client,
            .pomodoro = self.pomodoro,
            .store = self.store,
            .bar_present = &self.present,
            .event_service = event_service,
            .started = self.started,
        };
    }

    /// Run a request from a client and answer it. Owns `arena_state` - which
    /// holds the verb, the arguments and the copied reply-port reference - and
    /// frees all of it before returning.
    fn runCommand(
        self: *Daemon,
        arena_state: *std.heap.ArenaAllocator,
        verb: []const u8,
        args: []const []const u8,
        reply_port: u32,
    ) anyerror!void {
        defer {
            platform.kx_port_release(reply_port);
            arena_state.deinit();
            self.gpa.destroy(arena_state);
        }

        const index = commands.find(verb) orelse
            return control.postReply(reply_port, .{ .err = "unknown command" });

        // The command is checked against its own description before it runs, so a
        // request that does not fit is answered with what was expected rather
        // than with whatever the command makes of it. The client checks too, and
        // this is the authority: any client can be older than the daemon.
        if (try cli.validate(arena_state.allocator(), commands.all[index], args)) |problem| {
            return control.postReply(reply_port, .{ .err = problem });
        }

        // A channel of this task's own: the receive loop's client must not see a
        // batch it did not build.
        var bar = sb.Client.init(arena_state.allocator(), sb.sketchybar_service);
        defer bar.deinit();

        // A command this binary answers itself has no daemon side; a client old
        // enough to ask anyway is told so rather than dereferenced.
        const run = commands.all[index].run orelse
            return control.postReply(reply_port, .{ .err = "this command runs in the client" });

        var command_context = self.commandContext(arena_state.allocator(), &bar);
        if (run(&command_context, args)) |payload| {
            control.postReply(reply_port, .{ .ok = payload });
        } else |err| {
            std.debug.print("kxdesk: command {s} failed: {s}\n", .{ verb, @errorName(err) });
            control.postReply(reply_port, .{ .err = @errorName(err) });
        }
    }

    /// Hand a request to the worker pool.
    ///
    /// The block belongs to the mach message, which the receive loop destroys as
    /// soon as this returns, and the reply port goes with it - so the task gets
    /// its own copy of both.
    fn startCommand(self: *Daemon, block: [*:0]const u8, reply_port: u32) void {
        const answer_port = platform.kx_port_copy(reply_port);

        const request = control.parse(block) orelse
            return reject(answer_port, "malformed request");
        const index = commands.find(request.verb) orelse
            return reject(answer_port, "unknown command");

        const arena_state = self.gpa.create(std.heap.ArenaAllocator) catch
            return reject(answer_port, "no memory for the request");
        arena_state.* = std.heap.ArenaAllocator.init(self.gpa);
        const arena = arena_state.allocator();

        const verb = arena.dupe(u8, request.verb) catch
            return self.abandon(arena_state, answer_port);
        const args = arena.alloc([]const u8, request.count) catch
            return self.abandon(arena_state, answer_port);
        for (request.args(), 0..) |argument, position| {
            args[position] = arena.dupe(u8, argument) catch
                return self.abandon(arena_state, answer_port);
        }

        self.slots[index].request(self.io, Daemon.runCommand, .{
            self, arena_state, verb, args, answer_port,
        });
    }

    /// Answer a request whose arguments could not be copied.
    fn abandon(self: *Daemon, arena_state: *std.heap.ArenaAllocator, answer_port: u32) void {
        arena_state.deinit();
        self.gpa.destroy(arena_state);
        reject(answer_port, "no memory for the request");
    }
};

/// Answer a request that cannot be run.
fn reject(answer_port: u32, message: []const u8) void {
    control.postReply(answer_port, .{ .err = message });
    platform.kx_port_release(answer_port);
}

fn onBlock(block: [*:0]const u8, reply_port: u32) callconv(.c) void {
    const daemon = active_daemon orelse return;

    // SketchyBar's shutdown marker - the bare two bytes `k` - means the bar is
    // gone. This process is not: the next `apply` will serve it again.
    if (block[0] == 'k' and block[1] == 0) {
        daemon.present.store(false, .monotonic);
        return;
    }

    if (control.isRequest(block)) return daemon.startCommand(block, reply_port);

    // Any other block is proof that a bar is there, because it addressed an item
    // whose `mach_helper` only a configuration this daemon applied could have set.
    // If the bar had been marked gone, this is where it comes back: a bar's
    // shutdown marker and the start of the next bar can cross, and a marker can
    // outlive the bar it named. A daemon that stayed marked away for the rest of
    // its life looked exactly like a bar that had stopped drawing - nothing on the
    // bar moved again until the daemon was restarted, while the bar itself was
    // fine.
    if (!daemon.present.load(.monotonic)) {
        daemon.present.store(true, .monotonic);
        // The right held for the bar that went away names a dead port; dropping
        // it makes the next send resolve whichever bar is running now.
        daemon.dispatcher.bar.reconnect();
    }

    if (daemon.dispatcher.bar.trace) sb.traceBlock(block);

    daemon.dispatcher.handle(block) catch |err| {
        std.debug.print("kxdesk: event failed: {s}\n", .{@errorName(err)});
    };
}

/// The serve loop's clock, as a C callback: end a phase that has run out, show
/// the item, and say how long the loop may block next.
///
/// The loop is the only thread that runs this, and the commands take the timer's
/// own lock to touch it from theirs.
fn onTimer() callconv(.c) u32 {
    const daemon = active_daemon orelse return 0;

    // Nothing is pushed to a bar that is not there; the ring does not depend on
    // the bar at all, which is the point of the timer living in the daemon.
    const bar = if (daemon.present.load(.monotonic)) daemon.bar else null;
    daemon.pomodoro.tick(daemon.io, bar);

    // Four things want the clock, and the loop wakes for whichever is soonest.
    // A held-back yabai refresh reports the wait it still owes, so the loop
    // wakes when that closes rather than sleeping through it.
    const graph_wait = daemon.dispatcher.system_items.pollGraphs(daemon.io, bar);
    const yabai_wait = daemon.dispatcher.pollYabai();
    return soonest(soonest(soonest(daemon.pomodoro.waitMs(daemon.io), daemon.dispatcher.pollUsage()), graph_wait), yabai_wait);
}

/// The sooner of two waits, in the loop's convention that 0 means "nothing
/// scheduled" rather than "now".
fn soonest(first: u32, second: u32) u32 {
    if (first == 0) return second;
    if (second == 0) return first;
    return @min(first, second);
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const arena = init.arena.allocator();
    const io = init.io;

    if (arguments.len < 2) {
        // No command at all: say what there is, on stderr, the way a usage error
        // does.
        emit(io, .stderr, try cli.overview(arena));
        std.process.exit(1);
    }

    const mode = arguments[1];
    if (std.mem.eql(u8, mode, "daemon")) return runDaemon(init);
    // Answered here rather than by the daemon: the version of *this* binary is
    // the version of the daemon it starts, and it is worth asking when nothing is
    // answering - which is exactly when a client command cannot be used. The
    // same goes for `--help` and the completions, which a shell asks for while it
    // is being set up, before any daemon need be running.
    if (std.mem.eql(u8, mode, "version") or std.mem.eql(u8, mode, "--version")) {
        emit(io, .stdout, build_options.version);
        return;
    }
    if (std.mem.eql(u8, mode, "--help") or std.mem.eql(u8, mode, "-h")) {
        emit(io, .stdout, try cli.overview(arena));
        return;
    }
    if (std.mem.eql(u8, mode, "__complete")) return runCompletions(init, arguments[2..]);

    // `kxdesk <command> --help`: answered here so it works with no daemon
    // listening, and so a command that needs arguments can be asked about without
    // supplying any. Before the local commands below, which would otherwise
    // refuse a `--help` as the wrong kind of argument.
    for (arguments[2..]) |argument| {
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            return describe(init, mode);
        }
    }

    // The commands this binary answers itself; see the module comment.
    if (std.mem.eql(u8, mode, "help") or
        std.mem.eql(u8, mode, "completions") or
        std.mem.eql(u8, mode, "server-mode"))
    {
        return runLocally(init, mode, arguments[2..]);
    }

    return runClient(init, mode, arguments[2..]);
}

/// The commands this binary answers itself: `help`, `completions` and
/// `server-mode`. All are checked against their own description, so a wrong shell
/// or an unknown command name is refused with the same kind of message as a
/// daemon command.
fn runLocally(init: std.process.Init, mode: []const u8, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const command = cli.find(mode) orelse return;

    if (try cli.validate(arena, command, args)) |problem| {
        emit(init.io, .stderr, problem);
        std.process.exit(1);
    }

    if (std.mem.eql(u8, mode, "help")) {
        if (args.len == 0) {
            emit(init.io, .stdout, try cli.overview(arena));
            return;
        }
        return describe(init, args[0]);
    }

    if (std.mem.eql(u8, mode, "server-mode")) {
        const payload = server_mode.serverMode(arena, init.io, args) catch |err| return fail(init.io, err);
        if (payload.len > 0) emit(init.io, .stdout, payload);
        return;
    }

    writeText(init.io, .stdout, cli.script(args[0]) orelse return);
}

/// Describe one command, or say there is no such command.
fn describe(init: std.process.Init, name: []const u8) !void {
    const command = cli.find(name) orelse {
        const message = try std.fmt.allocPrint(
            init.arena.allocator(),
            "kxdesk: no such command: {s}",
            .{name},
        );
        emit(init.io, .stderr, message);
        std.process.exit(1);
    };
    emit(init.io, .stdout, try cli.describe(init.arena.allocator(), command));
}

/// The completion protocol the generated shell functions call: optionally
/// `--describe`, then the index of the word being completed, then the words after
/// the program name. Hidden, because `completions` is the interface - these line
/// breaks are not for people.
///
/// `--describe` is what asks for the tab and the explanation; a caller that does
/// not pass it gets the words alone, which is what every earlier version of this
/// protocol answered and what a script that is older than the binary still
/// expects.
fn runCompletions(init: std.process.Init, args: []const []const u8) !void {
    var rest = args;
    var described = false;
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "--describe")) {
        described = true;
        rest = rest[1..];
    }
    if (rest.len == 0) return;

    const cword = std.fmt.parseInt(usize, rest[0], 10) catch return;
    const text = try cli.complete(init.arena.allocator(), described, cword, rest[1..]);
    if (text.len > 0) writeText(init.io, .stdout, text);
}

/// The daemon: register the service, then serve until the process is killed.
fn runDaemon(init: std.process.Init) !void {
    const gpa = init.gpa;

    // The event service has to exist before any item is told to use it, and the
    // control name before a client comes looking for one.
    const server_port = platform.kx_server_register(event_service);
    if (server_port == 0) return error.BootstrapRegistrationFailed;
    if (!platform.kx_server_publish(server_port, sb.control_service)) {
        return error.BootstrapRegistrationFailed;
    }

    var bar = sb.Client.init(gpa, sb.sketchybar_service);
    defer bar.deinit();
    // Not a failure: the daemon is launched as an agent, which happens during
    // login, and SketchyBar may well start later.
    bar.connect() catch {};

    var yabai_client = try yabai.Client.init(gpa);
    defer yabai_client.deinit();

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    const response = try gpa.alloc(u8, response_size);
    defer gpa.free(response);

    var icons = app_icons.Mapping.init(gpa);
    defer icons.deinit();
    loadIcons(&icons, init.io);

    // Durable state. Opened before anything that uses it, and never a reason to
    // fail: a store that cannot be opened says so once and answers
    // `error.Unavailable`, so the bar works with or without it.
    var state_path: [std.fs.max_path_bytes]u8 = undefined;
    var store = state.Store.open(init.io, state.Store.defaultPath(&state_path));
    defer store.close();

    // The notifier the shell `pomo` function used. Resolved once, here: a
    // missing notifier costs the two notifications and nothing else, and it is
    // worth saying so once rather than discovering it silently at the end of an
    // interval.
    var notifier_path: [std.fs.max_path_bytes]u8 = undefined;
    var timer = pomodoro.Timer{ .store = &store, .notifier = blk: {
        if (platform.kx_which("terminal-notifier", &notifier_path, notifier_path.len)) {
            break :blk std.mem.sliceTo(&notifier_path, 0);
        }
        std.debug.print(
            "kxdesk: terminal-notifier is not installed; pomodoro notifications are off\n",
            .{},
        );
        break :blk "";
    } };

    var daemon = Daemon{
        .gpa = gpa,
        .io = init.io,
        .bar = &bar,
        .yabai_client = &yabai_client,
        .pomodoro = &timer,
        .store = &store,
        .dispatcher = .{
            .bar = &bar,
            .io = init.io,
            .gpa = gpa,
            .helper = event_service,
            .pomodoro = &timer,
            .store = &store,
            .yabai_items = items_yabai.Updater.init(gpa, &yabai_client, &bar, &scratch, response, &icons),
            .system_items = items_system.Updater.init(&bar),
        },
        .started = std.Io.Timestamp.now(init.io, .awake),
    };
    active_daemon = &daemon;

    // The timer is restored whether or not the bar is up: it is the daemon's
    // own, and a phase that ran out while this process was not running starts
    // its successor now.
    timer.restore(init.io);

    // Applied here as well as by the `apply` command, because launchd restarts
    // this agent on its own and a restarted daemon listens on a new port: every
    // item's `mach_helper` has to be pointed at it again. When the bar is not up
    // yet - the agent starts at login, SketchyBar may start later - there is
    // nothing to apply to, and the bar's config script asks instead.
    if (bar.connect()) |_| {
        daemon.present.store(true, .monotonic);
        bar_config.apply(&bar, init.io, .{ .helper = event_service }) catch |err| {
            std.debug.print("kxdesk: startup apply failed: {s}\n", .{@errorName(err)});
        };
        // A bar that has just been built knows nothing about the state the last
        // one was in; the same call the `apply` command makes.
        {
            var restore_state_arena = std.heap.ArenaAllocator.init(gpa);
            defer restore_state_arena.deinit();
            var command_context = daemon.commandContext(restore_state_arena.allocator(), &bar);
            commands.restoreState(&command_context);
        }
    } else |_| {}

    // kanata's channel, started last because it is a client of everything above
    // it: from its own thread it reaches the bar, yabai and the store. Losing it
    // costs the key bindings and nothing else, so a failure is said once and the
    // daemon carries on - the bar is what this process is for.
    kanata.Listener.start(gpa, .{
        .io = init.io,
        .store = &store,
        .yabai_client = &yabai_client,
        .pomodoro = &timer,
        .bar_present = &daemon.present,
        .event_service = event_service,
        .started = daemon.started,
    }) catch |err| {
        std.debug.print("kxdesk: kanata channel not started: {s}\n", .{@errorName(err)});
    };

    // Never returns: the process ends when launchd or a signal ends it, not when
    // SketchyBar does.
    platform.kx_server_serve(server_port, onBlock, onTimer);
}

/// Every other mode: ask the daemon to run one of its commands.
///
/// The request is checked against the command's own description first, which is
/// what lets an incomplete one be answered without a daemon - and what keeps a
/// misspelled verb from starting one.
fn runClient(init: std.process.Init, verb: []const u8, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const command = cli.find(verb) orelse {
        const message = try std.fmt.allocPrint(
            arena,
            "kxdesk: no such command: {s}\n`kxdesk --help` lists them.",
            .{verb},
        );
        emit(init.io, .stderr, message);
        std.process.exit(1);
    };
    if (try cli.validate(arena, command, args)) |problem| {
        emit(init.io, .stderr, problem);
        std.process.exit(1);
    }

    var response: [8 * 1024]u8 = undefined;
    const reply = control.submit(init.gpa, init.io, verb, args, &response) catch |err| {
        return fail(init.io, err);
    };

    switch (control.decode(reply) orelse return fail(init.io, error.MalformedReply)) {
        .ok => |payload| if (payload.len > 0) emit(init.io, .stdout, payload),
        .err => |message| {
            emit(init.io, .stderr, message);
            std.process.exit(1);
        },
    }
}

const Stream = enum { stdout, stderr };

/// Write text, tolerating a closed pipe: a key binding's terminal is long gone by
/// the time the daemon answers.
fn writeText(io: std.Io, stream: Stream, text: []const u8) void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    file.writeStreamingAll(io, text) catch {};
}

/// Write one line.
fn emit(io: std.Io, stream: Stream, text: []const u8) void {
    writeText(io, stream, text);
    writeText(io, stream, "\n");
}

fn fail(io: std.Io, err: anyerror) noreturn {
    emit(io, .stderr, switch (err) {
        // Either nothing is listening, or the daemon that was listening while
        // the request was sent went away without answering it. Both are fixed
        // the same way, and a client cannot tell them apart from a distance.
        error.DaemonUnavailable => "kxdesk: no daemon answered - brew services start kxdesk",
        error.MalformedReply => "kxdesk: daemon sent a malformed reply",
        else => @errorName(err),
    });
    std.process.exit(1);
}

/// Read the application -> icon mapping out of the installed app font.
///
/// CoreText is asked where the font lives, so the mapping is always read from the
/// same file the bar renders with. A missing or unreadable font is not fatal: the
/// mapping stays empty and every application falls back to `:default:`.
fn loadIcons(mapping: *app_icons.Mapping, io: std.Io) void {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    if (!platform.kx_app_font_path(&path, path.len)) {
        std.debug.print("kxdesk: sketchybar-app-font is not installed; app icons fall back to {s}\n", .{
            app_icons.default_ligature,
        });
        return;
    }

    const font = std.mem.sliceTo(&path, 0);
    mapping.load(io, font) catch |err| {
        std.debug.print("kxdesk: cannot read app icons from {s}: {s}\n", .{ font, @errorName(err) });
        return;
    };

    std.debug.print("kxdesk: app icons from {s} ({d} of {d} glyphs mapped)\n", .{
        mapping.release,
        mapping.mapped,
        mapping.glyphs,
    });
}
