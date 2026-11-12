//! kxdesk - personal desktop daemon.
//!
//! One process serves two things over one mach port: SketchyBar's item events and
//! the command channel `kxdesk <command> [arguments...]`. Both bootstrap names
//! share that port. The daemon owns the bar's state, applying the configuration
//! and restoring the store's state whenever a bar appears. Its window, space and
//! display events arrive natively - accessibility observers per application, the
//! workspace's notifications and the window server's - and are coalesced into the same
//! refresh the bar's own `display_change` drives. `help`, `completions`, `version`,
//! `server-mode`, `grabber`, and the event `brew refresh` posts are answered by the
//! binary itself; the rest is described once in `commands.zig`.

const std = @import("std");

const app_icons = @import("app_icons.zig");
const background = @import("background.zig");
const bootstrap = @import("bootstrap.zig");
const build_options = @import("build_options");
const bar_config = @import("bar.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const context = @import("context.zig");
const control = @import("control.zig");
const dispatch = @import("dispatch.zig");
const exec = @import("exec.zig");
const grabber = @import("grabber.zig");
const items_audio = @import("items_audio.zig");
const items_brew = @import("items_brew.zig");
const items_system = @import("items_system.zig");
const items_yabai = @import("items_yabai.zig");
const hotkey = @import("hotkey.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const pomodoro = @import("pomodoro.zig");
const server_mode = @import("server_mode.zig");
const state = @import("store.zig");
const sb = @import("sb.zig");
const yabai = @import("yabai.zig");

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

    /// Whether SketchyBar is known to be up; neither state is fatal, since the
    /// daemon starts before the bar and keeps serving after it is gone.
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
            .event_service = bootstrap.event,
            .started = self.started,
        };
    }

    /// Run a request from a client and answer it. Owns `arena_state`, which holds
    /// the verb, the arguments and the copied reply-port reference.
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

        // Checked against its own description first: this is the authority, since
        // any client can be older than the daemon.
        if (try cli.validate(arena_state.allocator(), self.io, commands.all[index], args)) |problem| {
            return control.postReply(reply_port, .{ .err = problem });
        }

        // Its own client, never the loop's; see `context.Context.bar`.
        var bar = sb.Client.init(arena_state.allocator(), sb.sketchybar_service);
        defer bar.deinit();

        // A command the client answers has no daemon side; a client old enough to
        // ask anyway is told so rather than dereferenced.
        const run = commands.all[index].run orelse
            return control.postReply(reply_port, .{ .err = "this command runs in the client" });

        var command_context = self.commandContext(arena_state.allocator(), &bar);
        if (run(&command_context, args)) |payload| {
            control.postReply(reply_port, .{ .ok = payload });
        } else |err| {
            log.warn("command {s} failed: {s}", .{ verb, @errorName(err) });
            control.postReply(reply_port, .{ .err = @errorName(err) });
        }
    }

    /// Hand a request to the worker pool. The block belongs to the mach message,
    /// which the receive loop destroys as soon as this returns, so the task gets
    /// its own copy of the block and of the reply port.
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

    // An event a client posted is not SketchyBar sending, so it says nothing
    // about whether the bar is there - which is why it is routed before the
    // presence check below rather than through it.
    if (control.isEvent(block)) {
        if (daemon.dispatcher.bar.trace) sb.traceBlock(block);
        daemon.dispatcher.handleClientEvent(control.eventPayload(block)) catch |err| {
            log.warn("event failed: {s}", .{@errorName(err)});
        };
        return;
    }

    // A block addressed to our `mach_helper` proves a bar is present - and can
    // arrive after the shutdown marker of the bar it belongs to.
    if (!daemon.present.load(.monotonic)) {
        daemon.present.store(true, .monotonic);
        // The right held for the bar that went away names a dead port.
        daemon.dispatcher.bar.reconnect();
    }

    if (daemon.dispatcher.bar.trace) sb.traceBlock(block);

    daemon.dispatcher.handle(block) catch |err| {
        log.warn("event failed: {s}", .{@errorName(err)});
    };
}

/// The native window observers' sink, as the pipe's C handler. It runs on the main
/// run-loop thread, which also owns the hotkey engine's tap, so it posts and
/// returns: the coalescing refresh happens where every other event goes, on the
/// receive loop.
///
/// A title event names its window, which is the cheap path; a created event also
/// names its application, which is the Telegram rule's input; anything else rebuilds
/// every strip.
fn onWmEvent(kind: [*:0]const u8, window_id: u32, app_name: [*:0]const u8) callconv(.c) void {
    var id_buf: [10]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}", .{window_id}) catch return;

    const name = std.mem.span(kind);
    if (std.mem.eql(u8, name, "title") and window_id != 0) {
        _ = control.postEvent(&.{ "item", items_yabai.item, "window", id });
        return;
    }
    if (std.mem.eql(u8, name, "created")) {
        // `control.frameEvent` refuses a block past `control.max_event` and would
        // drop the whole event, so the name is cut to a width no application name
        // needs and no comparison here can notice.
        const application = std.mem.sliceTo(app_name, 0);
        const kept = application[0..@min(application.len, max_app_name)];
        _ = control.postEvent(&.{
            "item",   items_yabai.item, "event", "created",
            "window", id,               "app",   kept,
        });
        return;
    }
    _ = control.postEvent(&.{ "item", items_yabai.item });
}

/// Widest application name an event carries; see `onWmEvent`.
const max_app_name = 48;

/// The serve loop's clock, as a C callback: end a phase that has run out, show
/// the item, and say how long the loop may block next. The loop is the only thread
/// that runs this; the commands take the timer's own lock to touch it from theirs.
fn onTimer() callconv(.c) u32 {
    // Detached helpers that have exited are reaped before the wait this loop is
    // about to commit to; nobody else waits for them, so a zombie would otherwise
    // be as long-lived as this process.
    const daemon = active_daemon orelse return 0;
    exec.reap(daemon.io);

    // Nothing is pushed to a bar that is not there; the ring does not depend on
    // the bar at all, which is the point of the timer living in the daemon.
    const bar = if (daemon.present.load(.monotonic)) daemon.bar else null;
    daemon.pomodoro.tick(daemon.io, bar);

    // Four things want the clock, and the loop wakes for whichever is soonest.
    // A held-back yabai refresh reports the wait it still owes, so the loop
    // wakes when that closes rather than sleeping through it.
    const graph_wait = daemon.dispatcher.system_items.pollGraphs(daemon.io, bar);
    const audio_wait = daemon.dispatcher.audio_items.poll(daemon.io, bar);
    const yabai_wait = daemon.dispatcher.pollYabai();
    const space_wait = daemon.dispatcher.pollSpaces();
    return soonest(
        soonest(
            soonest(soonest(soonest(daemon.pomodoro.waitMs(daemon.io), daemon.dispatcher.pollUsage()), graph_wait), audio_wait),
            yabai_wait,
        ),
        space_wait,
    );
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

    // Before anything registers or looks a name up: `KXDESK_BOOTSTRAP` is the
    // pair a probe daemon and the client talking to it use, instead of the
    // installed service's.
    bootstrap.resolve();

    if (arguments.len < 2) {
        // No command at all: say what there is, on stderr, the way a usage error
        // does.
        emit(io, .stderr, try cli.overview(arena));
        std.process.exit(1);
    }

    // `--version` is the flag spelling of the `version` command, which the
    // registry describes like any other. Both are answered here rather than by
    // the daemon: this binary's version is the version of the daemon it starts,
    // and it is worth asking when nothing is answering - which is exactly when a
    // client command cannot be used.
    const mode = if (std.mem.eql(u8, arguments[1], "--version")) "version" else arguments[1];
    if (std.mem.eql(u8, mode, "daemon")) return runDaemon(init);
    if (std.mem.eql(u8, mode, "--help") or std.mem.eql(u8, mode, "-h")) {
        emit(io, .stdout, try cli.overview(arena));
        return;
    }
    if (std.mem.eql(u8, mode, "__complete")) return runCompletions(init, arguments[2..]);
    if (std.mem.eql(u8, mode, "__blackout")) return runBlackout(init, arguments[2..]);
    if (std.mem.eql(u8, mode, "__guide")) return runGuide(init, arguments[2..]);

    // `kxdesk <command> --help`: answered here so it works with no daemon
    // listening, and before the local commands below, which would refuse a
    // `--help` as the wrong kind of argument.
    for (arguments[2..]) |argument| {
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            return describe(init, mode);
        }
    }

    // The commands this binary answers itself; see the module comment.
    if (std.mem.eql(u8, mode, "help") or
        std.mem.eql(u8, mode, "completions") or
        std.mem.eql(u8, mode, "version") or
        std.mem.eql(u8, mode, "server-mode") or
        std.mem.eql(u8, mode, "grabber") or
        std.mem.eql(u8, mode, "brew"))
    {
        return runLocally(init, mode, arguments[2..]);
    }

    return runClient(init, mode, arguments[2..]);
}

/// The process `wm blackout` starts: draw the overlay on every display but the
/// focused window's, and return when it ends. The display id and the socket the
/// running overlay listens on are the two arguments the command hands over.
fn runBlackout(init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 2) std.process.exit(1);
    const display_id = std.fmt.parseInt(u32, args[0], 10) catch std.process.exit(1);
    const arena = init.arena.allocator();
    const socket = try arena.dupeSentinel(u8, args[1], 0);
    if (!platform.kx_blackout_run(display_id, socket.ptr)) std.process.exit(1);
}

/// The process `guide` starts: the panel beside the privacy pane the missing grant is
/// given in.
///
/// Three modes, and the command that spawns this picks one by what is missing, never
/// by what it hopes: `drag <bundle>` for the Input Monitoring tile, `install <script>`
/// for the button that runs a root install in a terminal, and `accessibility` for the
/// grant the window observers need, which has no tile and no script - the panel is one
/// line and a Close.
fn runGuide(init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 2) std.process.exit(1);
    const arena = init.arena.allocator();

    if (std.mem.eql(u8, args[0], "accessibility")) {
        const instruction = try arena.dupeSentinel(u8, commands.accessibility_instruction, 0);
        const pane = try arena.dupeSentinel(u8, commands.accessibility_pane, 0);
        _ = platform.kx_guide_run(null, instruction.ptr, pane.ptr, null, &guideDoneAccessibility);
        return;
    }

    const drag = std.mem.eql(u8, args[0], "drag");
    const bundle = try arena.dupeSentinel(u8, if (drag) args[1] else "", 0);
    const script = try arena.dupeSentinel(u8, if (drag) "" else args[1], 0);
    const instruction = try arena.dupeSentinel(
        u8,
        if (drag) grabber.drag_instruction else grabber.install_instruction,
        0,
    );
    const pane = try arena.dupeSentinel(u8, grabber.pane_url, 0);

    guide_io = init.io;
    _ = platform.kx_guide_run(
        if (drag) bundle.ptr else null,
        instruction.ptr,
        pane.ptr,
        if (drag) null else script.ptr,
        &guideDone,
    );
}

/// The guide's polling loop has no context of its own, and `state` needs an io.
var guide_io: ?std.Io = null;

/// Whether the panel has nothing left to ask for: the same "green" the daemon
/// waits for, not merely "approved" - a panel opened for an unapproved grabber
/// must not close on a grant a stale process reports, and one opened for a stale
/// grabber must not close on the grant the stale process already carries.
///
/// Its own arena each time: this runs for as long as the panel is open, and a
/// shared one would grow half a second at a time.
fn guideDone() callconv(.c) bool {
    const io = guide_io orelse return false;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    return switch (grabber.state(scratch.allocator(), io)) {
        .green => true,
        else => false,
    };
}

/// Whether the Accessibility grant the panel was shown for has landed. The helper is
/// the daemon's own binary, so this is the daemon's grant that is being read - the
/// identity that has to be in the list.
fn guideDoneAccessibility() callconv(.c) bool {
    return platform.kx_ax_trusted();
}

/// The commands this binary answers itself, each checked against its own
/// description so a wrong shell or an unknown name is refused like a daemon
/// command would be.
fn runLocally(init: std.process.Init, mode: []const u8, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const command = cli.find(mode) orelse return;

    if (try cli.validate(arena, init.io, command, args)) |problem| {
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

    if (std.mem.eql(u8, mode, "version")) {
        emit(init.io, .stdout, build_options.version);
        return;
    }

    // The event a shell posts after upgrading Homebrew, naming the item it is about;
    // see `control.postEvent` for why nothing waits for the work it starts.
    if (std.mem.eql(u8, mode, "brew")) {
        _ = control.postEvent(&.{ "item", items_brew.item });
        return;
    }

    if (std.mem.eql(u8, mode, "grabber")) {
        const payload = grabber.grabber(arena, init.io, args) catch |err| return fail(init.io, err);
        if (payload.len > 0) emit(init.io, .stdout, payload);
        return;
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
        const message = try init.arena.allocator().print(
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
/// the program name. Hidden, because `completions` is the interface.
///
/// `--describe` is what asks for the tab and the explanation; without it the
/// words alone come back, which is what a script older than the binary expects.
fn runCompletions(init: std.process.Init, args: []const []const u8) !void {
    var rest = args;
    var described = false;
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "--describe")) {
        described = true;
        rest = rest[1..];
    }
    if (rest.len == 0) return;

    const cword = std.fmt.parseInt(usize, rest[0], 10) catch return;
    const text = try cli.complete(init.arena.allocator(), init.io, described, cword, rest[1..]);
    if (text.len > 0) writeText(init.io, .stdout, text);
}

/// The daemon: register the service, then serve until the process is killed.
fn runDaemon(init: std.process.Init) !void {
    const gpa = init.gpa;
    // A daemon started on another bootstrap base is a probe, and the machine it
    // runs on already has the installed daemon: the bar's items, the key
    // bindings and the grabber are that one's, and a probe that touched them
    // would point the live bar at a name that dies with it and run every binding
    // twice. Probes serve their control channel and nothing else.
    const probe = bootstrap.overridden;

    // The event service has to exist before any item is told to use it, and the
    // control name before a client comes looking for one.
    const server_port = platform.kx_server_register(bootstrap.event);
    if (server_port == 0) return error.BootstrapRegistrationFailed;
    if (!platform.kx_server_publish(server_port, bootstrap.control)) {
        return error.BootstrapRegistrationFailed;
    }
    if (probe) log.warn(
        "probe daemon: {s}; the bar, the bindings and the grabber stay the installed daemon's",
        .{bootstrap.control},
    );

    var bar = sb.Client.init(gpa, sb.sketchybar_service);
    defer bar.deinit();
    // Not a failure: the daemon is launched as an agent, which happens during
    // login, and SketchyBar may well start later.
    bar.connect() catch {};

    var yabai_client = try yabai.Client.init(gpa);
    defer yabai_client.deinit();

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var icons = app_icons.Mapping.init(gpa);
    defer icons.deinit();
    loadIcons(&icons, init.io);

    // Durable state, never a reason to fail: a store that cannot be opened says so
    // once and answers `error.Unavailable`.
    var state_path: [std.fs.max_path_bytes]u8 = undefined;
    var store = state.Store.open(init.io, state.Store.defaultPath(&state_path));
    defer store.close();

    // The notifier the shell `pomo` function used: missing one costs the
    // notifications and nothing else, so it is said once here.
    var notifier_path: [std.fs.max_path_bytes]u8 = undefined;
    var timer = pomodoro.Timer{ .store = &store, .notifier = blk: {
        if (platform.kx_which("terminal-notifier", &notifier_path, notifier_path.len)) {
            break :blk std.mem.sliceTo(&notifier_path, 0);
        }
        log.warn("terminal-notifier is not installed; pomodoro notifications are off", .{});
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
            .helper = bootstrap.event,
            .pomodoro = &timer,
            .store = &store,
            .yabai_items = items_yabai.Updater.init(gpa, &yabai_client, &bar, &scratch, &icons),
            .system_items = items_system.Updater.init(&bar),
            .audio_items = items_audio.Updater.init(&bar),
        },
        .started = std.Io.Timestamp.now(init.io, .awake),
    };
    active_daemon = &daemon;

    // The timer is restored whether or not the bar is up: a phase that ran out
    // while this process was not running starts its successor now.
    timer.restore(init.io);

    // Applied here as well as by the `apply` command: launchd restarts this agent
    // on its own, and a restarted daemon listens on a new port, so every item's
    // `mach_helper` has to be pointed at it again. Not from a probe: its name
    // dies with the process, and the live bar would send its clicks into nothing.
    if (!probe) {
        if (bar.connect()) |_| {
            daemon.present.store(true, .monotonic);
            bar_config.apply(&bar, init.io, .{ .helper = bootstrap.event, .store = &store }) catch |err| {
                log.warn("startup apply failed: {s}", .{@errorName(err)});
            };
            // A freshly built bar knows nothing about the state the last one was in.
            {
                var restore_state_arena = std.heap.ArenaAllocator.init(gpa);
                defer restore_state_arena.deinit();
                var command_context = daemon.commandContext(restore_state_arena.allocator(), &bar);
                commands.restoreState(&command_context);
            }
        } else |_| {}
    }

    // The key bindings, set up last and in two parts, because the engine's tap has
    // to be on this thread while the receive loop needs one of its own: the engine
    // is parsed and its hooks installed here, the loop is handed to a thread, and
    // this thread then runs the engine's run loop. Losing the bindings costs them
    // and nothing else, so a failure is said once and the bar keeps being served.
    const bindings = if (probe) false else blk: {
        hotkey.init(gpa, .{
            .io = init.io,
            .store = &store,
            .yabai_client = &yabai_client,
            .pomodoro = &timer,
            .bar_present = &daemon.present,
            .event_service = bootstrap.event,
            .started = daemon.started,
        }) catch |err| {
            log.warn("hotkey engine not started: {s}", .{@errorName(err)});
            break :blk false;
        };
        break :blk true;
    };

    // A tap built before Input Monitoring was granted is created and then sees no
    // key events at all - no error, no log line of its own - so say which command
    // asks for the grant while the rest of the daemon is fine.
    if (bindings and platform.inputMonitoring() != .granted) {
        log.warn(
            "input monitoring {s}: key events may not reach the tap; run `kxdesk hotkey grant`",
            .{@tagName(platform.inputMonitoring())},
        );
    }

    // The receive loop never returns: the process ends when launchd or a signal
    // ends it, not when SketchyBar does. Every handler it runs was already
    // thread-agnostic - commands run on their own workers - so a thread of its own
    // costs nothing and leaves this one to the engine.
    const server = std.Thread.spawn(.{}, receiveLoop, .{server_port}) catch |err| {
        log.warn("receive loop not started: {s}", .{@errorName(err)});
        return err;
    };

    // The grabber the bindings need, checked and driven to green off this thread:
    // the one below it becomes the engine's run loop and never comes back. A probe
    // never touches it - asking the installed daemon's grabber to restart is how a
    // probe would break the user's own tap-hold rules.
    if (!probe) {
        if (std.Thread.spawn(.{}, convergeGrabber, .{&daemon})) |thread| {
            thread.detach();
        } else |err| {
            log.warn("the grabber check not started: {s}", .{@errorName(err)});
        }
    }

    // The Accessibility grant the window observers need, asked for and waited on
    // off this thread, for the reason above. A probe asks for nothing: the grant
    // and the observers belong to the installed daemon.
    if (!probe) {
        if (std.Thread.spawn(.{}, convergeAxAccess, .{&daemon})) |thread| {
            thread.detach();
        } else |err| {
            log.warn("the accessibility check not started: {s}", .{@errorName(err)});
        }
    }

    // This thread ends up inside a run loop either way: the engine's while it runs,
    // and the one the window observers and the workspace's notifications are
    // serviced from afterwards - or instead, when the engine never started. Nothing
    // they report is delivered while this thread blocks anywhere else.
    if (bindings) {
        hotkey.serve() catch |err| {
            log.warn("hotkey engine stopped: {s}", .{@errorName(err)});
        };
        // The engine's run loop only ends with the engine, and its tap belongs to
        // this thread: a daemon that keeps serving the bar with the bindings gone
        // cannot bring them back. Exiting is what the engine's own failure path
        // asks for - launchd starts the process over, engine included.
        log.warn("bindings stopped with the engine; exiting so the service restarts", .{});
        std.process.exit(0);
    }
    platform.kx_run_loop_run();
    server.join();
}

/// Ask for the Accessibility grant the native window observers need, then start
/// them.
///
/// The observers are the daemon's own: without the grant they register nothing, and
/// the bar's yabai items would keep whatever they last drew - so the one thing this
/// can do is ask, and wait for the answer. The system's prompt is one click; the
/// panel beside the Accessibility list is what says which row it is. Once the
/// deadline passes nothing asks again: a daemon left alone is not a daemon that
/// keeps opening panes.
fn convergeAxAccess(daemon: *Daemon) void {
    const io = daemon.io;
    if (platform.kx_ax_request()) return startWmEvents();

    var scratch = std.heap.ArenaAllocator.init(daemon.gpa);
    defer scratch.deinit();

    var guided = false;
    var waited: u32 = 0;
    while (waited < converge_deadline_ms) {
        if (platform.kx_ax_trusted()) return startWmEvents();
        if (!guided) {
            guided = true;
            // The panel, never the command: a missing grabber must not put its own
            // install panel in front of this grant.
            var context_value = daemon.commandContext(scratch.allocator(), daemon.bar);
            _ = commands.guideAccessibility(&context_value, &.{}) catch |err| {
                log.warn("the accessibility guide could not be shown: {s}", .{@errorName(err)});
            };
        }
        waited += sleepMs(io, 2000);
    }
    log.warn("window events are off: the Accessibility grant is missing", .{});
}

/// Start the pipe and ask for the paint it would otherwise take an event to cause:
/// nothing else refreshes the strips on the way up any more.
fn startWmEvents() void {
    if (!platform.kx_wm_events_start(&onWmEvent)) {
        log.warn("native window events unavailable", .{});
        return;
    }
    _ = control.postEvent(&.{ "item", items_yabai.item });
}

/// How long the loop keeps looking: long enough for a person to read a panel and
/// drag one row, short enough that a daemon left alone stops asking.
const converge_deadline_ms: u32 = 600_000;

/// Long enough for launchd to bring the grabber back after it exits for an
/// upgrade: its job carries a ten-second `ThrottleInterval`.
const restart_settle_ms: u32 = 12_000;

/// The grabber, driven to green on every start.
///
/// A daemon that owns the key bindings is the only thing placed to notice that the
/// half they need is missing, stale or unapproved: `brew upgrade` replaces the
/// grabber's file without restarting the process that holds the old image, a grant
/// is given by a drag nobody is told about, and neither shows up as an error
/// anywhere. So it probes and acts - asks a stale process to exit, so launchd
/// starts the binary on disk; shows the panel that installs a missing one; shows
/// the panel that carries the drag for an unapproved one - and stops as soon as
/// the grabber says it may seize.
///
/// A thread of its own, because the main thread becomes the engine's run loop and
/// this waits on a person rather than on a socket.
fn convergeGrabber(daemon: *Daemon) void {
    const io = daemon.io;
    var scratch = std.heap.ArenaAllocator.init(daemon.gpa);
    defer scratch.deinit();
    if (!hotkey.configWantsTapHold(io, scratch.allocator())) return;

    var waited: u32 = 0;
    var restarted = false;
    var guided = false;
    while (waited < converge_deadline_ms) {
        // A probe of its own each time: this loop can run for ten minutes, and the
        // reply it parses is dead the moment the answer is read.
        var call = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer call.deinit();

        switch (grabber.state(call.allocator(), io)) {
            // Green: the engine's own reconnect asks the grabber to seize after
            // the fact, within two seconds of it coming back, and a reload here
            // would only reset the mode the bar is showing.
            .green => return,
            // Older than the binary on disk. Nothing but the job itself can
            // replace it, so ask it to exit and give launchd its throttle
            // interval to bring the file up.
            .stale => {
                if (!restarted) {
                    restarted = grabber.restart();
                    if (!restarted and !guided) {
                        guided = true;
                        showGuide(daemon, scratch.allocator());
                    }
                    waited += sleepMs(io, restart_settle_ms);
                    continue;
                }
                if (!guided) {
                    guided = true;
                    showGuide(daemon, scratch.allocator());
                }
                waited += sleepMs(io, 2000);
                continue;
            },
            // Answering, and TCC has not let it seize: the drag is the only fix.
            .unapproved => {
                if (!guided) {
                    guided = true;
                    showGuide(daemon, scratch.allocator());
                }
                waited += sleepMs(io, 2000);
                continue;
            },
            // Not installed, or launchd has it down. Both are install's work.
            .absent => {
                if (!guided) {
                    guided = true;
                    showGuide(daemon, scratch.allocator());
                }
                waited += sleepMs(io, 3000);
                continue;
            },
        }
    }
}

/// The panel, asked for the way a client asks: the same command, the same choice
/// between the drag and the install.
fn showGuide(daemon: *Daemon, arena: std.mem.Allocator) void {
    var context_value = daemon.commandContext(arena, daemon.bar);
    _ = commands.guide(&context_value, &.{}) catch |err| {
        log.warn("the grabber guide could not be shown: {s}", .{@errorName(err)});
    };
}

/// Sleep, and answer how long was waited: the loop's own clock, so that a probe
/// failing instantly cannot turn it into a spin.
fn sleepMs(io: std.Io, milliseconds: u32) u32 {
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(milliseconds), .awake) catch {};
    return milliseconds;
}

/// The receive loop, on the thread the engine does not own.
fn receiveLoop(port: u32) void {
    platform.kx_server_serve(port, onBlock, onTimer);
}

/// Every other mode: ask the daemon to run one of its commands. The request is
/// checked against the command's own description first, so a misspelled verb is
/// answered without a daemon being started.
fn runClient(init: std.process.Init, verb: []const u8, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const command = cli.find(verb) orelse {
        const message = try arena.print(
            "kxdesk: no such command: {s}\n`kxdesk --help` lists them.",
            .{verb},
        );
        emit(init.io, .stderr, message);
        std.process.exit(1);
    };
    if (try cli.validate(arena, init.io, command, args)) |problem| {
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
        // The store switch that takes server mode off a machine wholesale; see
        // `server_mode.disabled`. Naming the key is the whole answer, since the
        // person running this is the one who set it.
        error.ServerModeDisabled => "kxdesk: server mode is disabled on this machine (state: server-mode.disabled)",
        else => @errorName(err),
    });
    std.process.exit(1);
}

/// Read the application -> icon mapping out of the installed app font, located
/// through CoreText so it is the file the bar renders with. A missing or unreadable
/// font is not fatal: the mapping stays empty and every application falls back to
/// `:default:`.
fn loadIcons(mapping: *app_icons.Mapping, io: std.Io) void {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    if (!platform.kx_app_font_path(&path, path.len)) {
        log.warn("sketchybar-app-font is not installed; app icons fall back to {s}", .{
            app_icons.default_ligature,
        });
        return;
    }

    const font = std.mem.sliceTo(&path, 0);
    mapping.load(io, font) catch |err| {
        log.warn("cannot read app icons from {s}: {s}", .{ font, @errorName(err) });
        return;
    };

    log.warn("app icons from {s} ({d} of {d} glyphs mapped)", .{
        mapping.release,
        mapping.mapped,
        mapping.glyphs,
    });
}
