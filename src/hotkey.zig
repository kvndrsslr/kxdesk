//! The key bindings, run in this process.
//!
//! The engine is upstream skhd.zig compiled into the daemon (`build.zig` copies
//! its pinned source and rewrites one file): the event tap is the engine's, so it
//! owns the keyboard without a root service or a driver extension, the parser is
//! the engine's, so `~/.config/kxdesk/skhdrc` is upstream's grammar, and the
//! action line comes back here through two hooks. A line that starts with `! ` -
//! kxdesk's own form, next to upstream's shell commands - is a `kxdesk` argv line
//! without the binary name: it goes through the same lookup, the same
//! `cli.validate` check and the same `run` a client's request does, with no
//! process launched. Any other line is still a shell command, which is what
//! upstream would have run.
//!
//! Two threads matter. `serve` is the process main thread, because the engine
//! adds its tap, watchdog, FSEvents stream and keyboard timer to the main run
//! loop; what it calls must not block that loop, since macOS disables a tap whose
//! callback takes too long, so a hook only copies its line into a fixed queue.
//! The queue's one worker runs the lines in the order they arrived - the
//! serialization a key press needs, because two commands touching the same window
//! must not race - and applies them with a bar channel and an arena of its own.

const std = @import("std");

const cli = @import("cli.zig");
const commands = @import("commands.zig");
const Context = @import("context.zig").Context;
const log = @import("log.zig");
const mode_indicator = @import("mode_indicator.zig");
const platform = @import("platform.zig");
const pomodoro = @import("pomodoro.zig");
const sb = @import("sb.zig");
const Skhd = @import("skhd");
const state = @import("store.zig");
const yabai = @import("yabai.zig");

/// How many lines may wait for the worker, and the longest one it takes. Both are
/// bounds rather than knobs: the tap's callback must not allocate, and an action
/// is a short argv line (`wm window-swap west`), never a script.
const queue_depth = 16;
const max_line = 4096;

/// Where the bindings live, under `$HOME`.
const config_suffix = "/.config/kxdesk/skhdrc";

/// What the engine needs from the daemon: what a command gets, minus the parts it
/// must not touch - the receive loop's bar client, and the pomodoro timer, which
/// the receive loop ticks.
pub const Deps = struct {
    io: std.Io,
    store: *state.Store,
    yabai_client: *yabai.Client,
    pomodoro: *pomodoro.Timer,
    bar_present: *std.atomic.Value(bool),
    event_service: []const u8,
    started: std.Io.Timestamp,
};

/// The one live engine host, reached from the engine's hooks, which are function
/// pointers with no context of their own. `main.zig` creates it before the
/// receive loop starts and it lives as long as the process does.
var host: ?*Host = null;

/// What a queued line is for: an action to run, or a mode to show.
const Kind = enum { dispatch, mode };

const Entry = struct {
    kind: Kind,
    len: usize,
    text: [max_line]u8,
};

const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    deps: Deps,
    /// The engine's own storage: it must not move, because the engine hands its
    /// address to the run loop, the signal handler and the tap.
    engine: *Skhd,
    config: [:0]const u8,

    /// Whether `serve` has reached the point where the engine's own signal
    /// handler is installed, which is what makes `reload` safe.
    running: std.atomic.Value(bool) = .init(false),
    /// Lines applied, for `kxdesk hotkey status`. Counted by the worker, read
    /// from another thread.
    handled: std.atomic.Value(u64) = .init(0),

    queue_lock: std.Io.Mutex = .init,
    queue_ready: std.Io.Condition = .init,
    entries: [queue_depth]Entry = undefined,
    head: usize = 0,
    count: usize = 0,
    /// The last "the queue is full" line, so that a worker that fell behind says
    /// so once instead of on every key press.
    dropped: log.Once = .{},

    /// Hand a line to the worker. Called from the engine's hooks, which run on the
    /// main run loop: it copies and returns, and never waits for the queue.
    fn push(self: *Host, kind: Kind, text: []const u8) void {
        // A line longer than this is a config mistake, not something to truncate:
        // half an argv line would run something the config never spelled.
        std.debug.assert(text.len <= max_line);
        if (text.len > max_line) return;

        self.queue_lock.lockUncancelable(self.io);
        defer self.queue_lock.unlock(self.io);

        if (self.count == queue_depth) {
            // The newest line is the one dropped: the worker is already behind,
            // and the older lines are the ones the user has been waiting on.
            if (self.dropped.changed("the action queue is full; a binding was dropped"))
                log.warn("hotkey queue is full; dropping the newest action", .{});
            return;
        }

        const entry = &self.entries[(self.head + self.count) % queue_depth];
        entry.kind = kind;
        entry.len = text.len;
        @memcpy(entry.text[0..text.len], text);
        self.count += 1;
        self.queue_ready.signal(self.io);
    }

    /// Run one line, in an arena and a bar channel of its own.
    ///
    /// The channel has to be this thread's: the receive loop shares its own and
    /// must not see a batch it did not build. The arena is per line for the same
    /// reason a command's is per request - whatever a command allocates is handed
    /// back when the line is done, rather than growing a buffer that never ends.
    fn apply(self: *Host, entry: *const Entry) void {
        defer _ = self.handled.fetchAdd(1, .monotonic);

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var bar = sb.Client.init(arena, sb.sketchybar_service);
        defer bar.deinit();

        var context = Context{
            .arena = arena,
            .io = self.io,
            .bar = &bar,
            .yabai = self.deps.yabai_client,
            .pomodoro = self.deps.pomodoro,
            .store = self.deps.store,
            .bar_present = self.deps.bar_present,
            .event_service = self.deps.event_service,
            .started = self.deps.started,
        };

        const text = entry.text[0..entry.len];
        switch (entry.kind) {
            .mode => {
                _ = mode_indicator.setMode(&context, &.{text}) catch |err| {
                    log.warn("hotkey mode indicator '{s}' failed: {s}", .{ text, @errorName(err) });
                };
            },
            .dispatch => dispatch(&context, text, null) catch |err| {
                // A refusal has already been logged with its reason; only the
                // failures that have not been said get a line here.
                if (err != error.Refused)
                    log.warn("hotkey action '{s}' failed: {s}", .{ text, @errorName(err) });
            },
        }
    }

    /// Drain the queue forever: the daemon's bindings live as long as the process
    /// does, and this is the only thread that runs them.
    fn serveQueue(self: *Host) void {
        while (true) {
            self.queue_lock.lockUncancelable(self.io);
            while (self.count == 0) self.queue_ready.waitUncancelable(self.io, &self.queue_lock);
            const entry = self.entries[self.head];
            self.head = (self.head + 1) % queue_depth;
            self.count -= 1;
            self.queue_lock.unlock(self.io);

            self.apply(&entry);
        }
    }
};

/// Set the engine's hooks and parse the config, without starting the run loop.
///
/// Its own failure is the caller's to report: a machine with no `skhdrc` yet, or a
/// config the engine will not parse, costs the key bindings and nothing else, so
/// `main.zig` says so once and serves the bar without them.
pub fn init(gpa: std.mem.Allocator, deps: Deps) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const config = configPath(&path_buffer) orelse return error.ConfigPathUnknown;

    const engine = try gpa.create(Skhd);
    errdefer gpa.destroy(engine);
    // A failed parse leaves nothing to free: `Skhd.init` unwinds its own work.
    engine.* = try Skhd.init(gpa, deps.io, config, false, false);

    const self = try gpa.create(Host);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = deps.io,
        .deps = deps,
        .engine = engine,
        .config = try gpa.dupeSentinel(u8, config, 0),
    };

    Skhd.Dispatch.run = dispatchHook;
    Skhd.ModeNotify.run = modeHook;

    const worker = std.Thread.spawn(.{}, Host.serveQueue, .{self}) catch |err| {
        Skhd.Dispatch.run = Skhd.Dispatch.defaultRun;
        Skhd.ModeNotify.run = noMode;
        return err;
    };
    worker.detach();

    host = self;
}

/// Run the engine's run loop on this thread, which must be the process main
/// thread: the engine adds its tap, its watchdog timer, its FSEvents stream and
/// its keyboard watch to the main run loop, and `NSApplicationLoad` is a
/// main-thread call.
///
/// Returns only when the loop does, which takes a stop request - the grabber's
/// socket going away, or a reload whose tap could not be built; the caller treats
/// that as the end of the bindings and starts the process over so they can come
/// back.
pub fn serve() !void {
    const self = host orelse return error.NotInitialised;

    // The engine installs its own SIGUSR1 handler inside its run loop, and until
    // then the default disposition of that signal is to terminate: a reload asked
    // for too early would kill the daemon. An ignored signal is the placeholder
    // that makes the window harmless, and it is replaced by the engine's own.
    const ignore = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.USR1, &ignore, null);
    self.running.store(true, .release);
    // The loop returning is the bindings ending: `hotkey status` says so, and a
    // reload asked for after it is refused rather than signalled into an engine
    // that is not there.
    defer self.running.store(false, .release);

    self.engine.run(true) catch |err| {
        // The engine's own permission advice is upstream's, and it names another
        // install: its path is right, its commands are not. What kxdesk needs is
        // one toggle in the same pane, and a restart to pick the tap up - the
        // engine creates it once and does not retry after a refusal.
        if (err == error.AccessibilityPermissionDenied) {
            log.warn("grant Accessibility to kxdesk.app, then: brew services restart kxdesk", .{});
        }
        return err;
    };
}

/// Every action the engine runs comes through here, on the main run loop.
///
/// A `!` line is queued for the worker and this returns immediately, which is the
/// point: the tap must not wait for a command. Everything else is upstream's
/// behavior, a shell command started and left running, which costs a fork and no
/// waiting.
fn dispatchHook(shell: [:0]const u8, verbose: bool, cmd: [:0]const u8) anyerror!void {
    const self = host orelse return error.NotInitialised;
    switch (route(cmd)) {
        .kxdesk => |argv| self.push(.dispatch, argv),
        .shell => try Skhd.Dispatch.defaultRun(shell, verbose, cmd),
    }
}

/// Every write of the engine's current mode comes through here. `null` from the
/// map is not an error: a mode with no colour of its own - `bypass`, or a name the
/// config made up - leaves the highlight as it was.
fn modeHook(name: []const u8) void {
    const self = host orelse return;
    const indicator = indicatorFor(name) orelse return;
    self.push(.mode, indicator);
}

fn noMode(_: []const u8) void {}

/// What an action line is: a `kxdesk` argv line, or a command for the shell.
pub const Route = union(enum) {
    /// The argv line after the `! ` prefix, the binary name already absent.
    kxdesk: []const u8,
    /// upstream's behavior: `$SHELL -c` on the line as written.
    shell,
};

/// The one rule of the `! ` form: the prefix is those two bytes at the start, and
/// no other spelling is special - a bare `!`, or a line that merely starts with
/// one, is an ordinary shell command.
pub fn route(line: []const u8) Route {
    if (std.mem.startsWith(u8, line, "! ")) return .{ .kxdesk = line[2..] };
    return .shell;
}

/// The mode indicator argument a mode's name stands for, or null for a mode with
/// no colour of its own.
///
/// The names are the ones `skhdrc` declares and the indices are the ones the mode
/// indicator takes. `-` is "no mode", which is the default mode: the bar's space
/// icons stop highlighting - and a config reload lands here, since the engine
/// resets to the default mode and says so.
pub fn indicatorFor(mode: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, mode, "op")) return "1";
    if (std.mem.eql(u8, mode, "wmode")) return "2";
    if (std.mem.eql(u8, mode, "smode")) return "3";
    if (std.mem.eql(u8, mode, "default")) return "-";
    return null;
}

/// Run an argv line exactly as the CLI would: the words are the command's argv
/// without the binary name, looked up in the registry and checked by the same
/// validation the CLI runs - one vocabulary for keys and commands.
///
/// The check is what keeps a mistyped binding to a line in the log: a name the
/// registry does not know, or a verb given an argument it cannot take, is refused
/// here rather than passed to yabai to refuse in its own words. The payload a
/// command answers with has nobody to answer, so it is dropped.
///
/// `refusal` is for the callers that do have somebody to answer: when it is given,
/// a line the check turns down leaves the cli's own words there as well as the log
/// line. The key path passes null - its answer has nowhere to go.
pub fn dispatch(context: *Context, line: []const u8, refusal: ?*?[]const u8) anyerror!void {
    var words: [16][]const u8 = undefined;
    var count: usize = 0;
    var iterator = std.mem.tokenizeScalar(u8, line, ' ');
    while (iterator.next()) |word| {
        if (count == words.len) return error.InvalidAction;
        words[count] = word;
        count += 1;
    }
    if (count == 0) return error.InvalidAction;

    const index = commands.find(words[0]) orelse return error.UnknownAction;
    const command = commands.all[index];
    if (command.run == null) return error.UnknownAction;

    if (try cli.validate(context.arena, context.io, command, words[1..count])) |problem| {
        log.warn("hotkey message '{s}' refused: {s}", .{ line, problem });
        if (refusal) |slot| slot.* = problem;
        return error.Refused;
    }
    _ = try command.run.?(context, words[1..count]);
}

/// One line about the engine, for `kxdesk hotkey status`.
pub fn status(arena: std.mem.Allocator) ![]const u8 {
    const self = host orelse return "hotkey engine: not started";

    // The grant is asked separately from the run loop's own view: an engine that
    // never got its tap and one whose grant was given to another build look the
    // same from here, and they are fixed differently.
    return arena.print(
        "hotkey engine: {s} accessibility={s} input_monitoring={s} handled={d} config={s}",
        .{
            if (self.running.load(.monotonic)) "running" else "stopped",
            if (platform.kx_ax_trusted()) "granted" else "denied",
            @tagName(platform.inputMonitoring()),
            self.handled.load(.monotonic),
            self.config,
        },
    );
}

/// Ask macOS for Input Monitoring, the grant that lets key events reach the tap:
/// without it the tap is built and its callback never sees a key. The system's
/// dialog blocks this call until it is answered, and a tap built before the grant
/// was given is not the tap a restart would build - hence the restart in the
/// answer.
pub fn grant() []const u8 {
    if (platform.kx_request_input_monitoring()) {
        return "input monitoring: granted - restart the daemon to rebuild the tap: brew services restart kxdesk";
    }
    return "input monitoring: still denied - a row left by an earlier build keeps the dialog away: remove kxdesk from System Settings > Privacy & Security > Input Monitoring, add /opt/homebrew/opt/kxdesk/kxdesk.app with +, then: brew services restart kxdesk";
}

/// Re-read the bindings, for `kxdesk hotkey reload`.
///
/// The engine reloads in its run loop, from a signal it handles itself: its
/// `reloadConfig` frees every hotkey and mode the tap callback is holding, so
/// calling it from here - another thread, or an action's own code - would be a
/// use-after-free. A save of the config file reloads on its own; this is the
/// manual path for when that misses.
pub fn reload() !void {
    const self = host orelse return error.NotInitialised;
    if (!self.running.load(.acquire)) return error.EngineNotRunning;

    // Delivered to whichever thread the kernel picks, and the engine's handler
    // only sets a flag, so this is safe from a command's worker.
    try std.posix.raise(std.posix.SIG.USR1);
}

/// Press a chord as if the keyboard had: the fallback for a space yabai will not
/// focus, which is Mission Control's own arrow key.
///
/// The keyspec is the engine's (`ctrl - 0x7B`), parsed by the engine's parser,
/// because the alternative - posting the events here too - would be a second
/// implementation of the same thing.
pub fn synthTap(keyspec: []const u8) !void {
    const self = host orelse return error.NotInitialised;
    try Skhd.synthesize.synthesizeKey(self.gpa, self.io, keyspec);
}

/// Act on an argv line as if a binding had, for `kxdesk hotkey inject`.
///
/// This is how a binding is exercised without pressing its keys: the lookup, the
/// check and the run are the same code the key path runs. The `! ` prefix is
/// accepted and dropped, so either spelling of a binding's action works here.
pub fn inject(context: *Context, line: []const u8) ![]const u8 {
    const action = switch (route(line)) {
        .kxdesk => |argv| argv,
        .shell => line,
    };

    var refusal: ?[]const u8 = null;
    dispatch(context, action, &refusal) catch |err| switch (err) {
        // Answered with the check's own words: a mistyped binding is readable
        // here without going to the log for the reason.
        error.Refused => return context.arena.print("{s}", .{refusal orelse @errorName(err)}),
        else => return err,
    };
    return context.arena.print("{s}", .{action});
}

/// Whether the bindings file asks for a `.remap`: the one thing the grabber
/// exists for, and the only reason a machine without it needs to be told so.
///
/// Asked of the file rather than of the parsed mappings, because it has to answer
/// at startup, before the engine's parse has produced any - so a line counts only
/// where the engine's grammar would see a directive: the first word of a line that
/// is not a comment.
pub fn wantsTapHold(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, ".remap ") or
            std.mem.startsWith(u8, trimmed, ".remap\t")) return true;
    }
    return false;
}

/// `wantsTapHold` for the file the engine reads. Missing or unreadable is a no: an
/// absent config has no rules, and the engine says so on its own.
pub fn configWantsTapHold(io: std.Io, arena: std.mem.Allocator) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(&buffer) orelse return false;
    const text = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(1 << 20),
        .of(u8),
        0,
    ) catch return false;
    return wantsTapHold(text);
}

/// The bindings file: `$HOME/.config/kxdesk/skhdrc`, in `buffer`.
fn configPath(buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var environment: [std.fs.max_path_bytes]u8 = undefined;
    if (platform.kx_env("HOME", &environment, environment.len)) {
        const home = std.mem.sliceTo(&environment, 0);
        if (home.len > 0)
            return std.fmt.bufPrint(buffer, "{s}" ++ config_suffix, .{home}) catch null;
    }
    return null;
}
