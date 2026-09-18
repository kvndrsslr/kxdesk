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
//! to ask. `kxdesk version` answers from the binary itself. Every other spelling
//! is a client that asks the daemon to run the command.

const std = @import("std");

const app_icons = @import("app_icons.zig");
const background = @import("background.zig");
const build_options = @import("build_options");
const bar_config = @import("bar.zig");
const commands = @import("commands.zig");
const control = @import("control.zig");
const dispatch = @import("dispatch.zig");
const items_system = @import("items_system.zig");
const items_yabai = @import("items_yabai.zig");
const platform = @import("platform.zig");
const pomodoro = @import("pomodoro.zig");
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

    fn context(self: *Daemon, arena: std.mem.Allocator, bar: *sb.Client) commands.Context {
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
            platform.sb_port_release(reply_port);
            arena_state.deinit();
            self.gpa.destroy(arena_state);
        }

        const index = commands.find(verb) orelse
            return control.postReply(reply_port, .{ .err = "unknown command" });

        // A channel of this task's own: the receive loop's client must not see a
        // batch it did not build.
        var bar = sb.Client.init(arena_state.allocator(), sb.sketchybar_service);
        defer bar.deinit();

        var command_context = self.context(arena_state.allocator(), &bar);
        if (commands.all[index].run(&command_context, args)) |payload| {
            control.postReply(reply_port, .{ .ok = payload });
        } else |err| {
            control.postReply(reply_port, .{ .err = @errorName(err) });
        }
    }

    /// Hand a request to the worker pool.
    ///
    /// The block belongs to the mach message, which the receive loop destroys as
    /// soon as this returns, and the reply port goes with it - so the task gets
    /// its own copy of both.
    fn startCommand(self: *Daemon, block: [*:0]const u8, reply_port: u32) void {
        const answer_port = platform.sb_port_copy(reply_port);

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
    platform.sb_port_release(answer_port);
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

    // Two things want the clock, and the loop wakes for whichever is sooner.
    return soonest(daemon.pomodoro.waitMs(daemon.io), daemon.dispatcher.pollUsage());
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
    if (arguments.len < 2) return usage(init.io);

    const mode = arguments[1];
    if (std.mem.eql(u8, mode, "daemon")) return runDaemon(init);
    // Answered here rather than by the daemon: the version of *this* binary is
    // the version of the daemon it starts, and it is worth asking when nothing
    // is answering - which is exactly when a client command cannot be used.
    if (std.mem.eql(u8, mode, "version")) {
        emit(init.io, .stdout, build_options.version);
        return;
    }
    return runClient(init, mode, arguments[2..]);
}

/// The daemon: register the service, then serve until the process is killed.
fn runDaemon(init: std.process.Init) !void {
    const gpa = init.gpa;

    // The event service has to exist before any item is told to use it, and the
    // control name before a client comes looking for one.
    const server_port = platform.sb_server_register(event_service);
    if (server_port == 0) return error.BootstrapRegistrationFailed;
    if (!platform.sb_server_publish(server_port, sb.control_service)) {
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
        if (platform.sb_which("terminal-notifier", &notifier_path, notifier_path.len)) {
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
        bar_config.apply(&bar, .{ .helper = event_service }) catch |err| {
            std.debug.print("kxdesk: startup apply failed: {s}\n", .{@errorName(err)});
        };
        // A bar that has just been built knows nothing about the state the last
        // one was in; the same call the `apply` command makes.
        {
            var restore_state_arena = std.heap.ArenaAllocator.init(gpa);
            defer restore_state_arena.deinit();
            var context = daemon.context(restore_state_arena.allocator(), &bar);
            commands.restoreState(&context);
        }
    } else |_| {}

    // Never returns: the process ends when launchd or a signal ends it, not when
    // SketchyBar does.
    platform.sb_server_serve(server_port, onBlock, onTimer);
}

/// Every other mode: ask the daemon to run one of its commands.
fn runClient(init: std.process.Init, verb: []const u8, args: []const []const u8) !void {
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

/// Write one line, tolerating a closed pipe: a key binding's terminal is long
/// gone by the time the daemon answers.
fn emit(io: std.Io, stream: Stream, text: []const u8) void {
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    file.writeStreamingAll(io, text) catch {};
    file.writeStreamingAll(io, "\n") catch {};
}

fn usage(io: std.Io) noreturn {
    emit(io, .stderr, "usage: kxdesk <command> [arguments...]");
    std.process.exit(1);
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
    if (!platform.sb_app_font_path(&path, path.len)) {
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
