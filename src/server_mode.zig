//! "Remote coding server" mode: materialize the personal 1Password account's SSH
//! keys to disk, serve them from one persistent agent on a socket of its own, and
//! wire ssh and git signing to it - plus an AC-only keep-awake agent - until
//! `exit` puts the snapshot back. Only the personal account is read; the business
//! one is off-limits.
//!
//! Client-run, not daemon-run: `op`'s unlock is the desktop app's to grant in the
//! session that asked, and the bar item's `click_script` runs this same command.

const std = @import("std");

const Context = @import("context.zig").Context;
const exec = @import("exec.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const theme = @import("theme.zig");

/// The 1Password account whose keys are served, and the only one this touches.
const account = "my.1password.com";

/// The keep-awake service, owned by server mode: installed on `enter`, removed
/// on `exit`.
const caffeinate_label = "local.caffeinate.ac";

/// The bar item that says whether this machine is serving; its click runs this
/// command, and `restore` puts it back after a bar reload from the cookie.
pub const bar_item = "server";

/// Names another state directory. A probe uses it to run against a throwaway
/// one; nothing else should.
const state_override: [:0]const u8 = "KXDESK_SERVER_MODE_STATE";

/// The state directory is the owner's alone - it holds private keys in the clear
/// - and so is everything written into it.
const directory_mode: std.Io.File.Permissions = @enumFromInt(0o700);
const file_mode: std.Io.File.Permissions = @enumFromInt(0o600);
const plist_mode: std.Io.File.Permissions = @enumFromInt(0o644);
const launch_agents_mode: std.Io.File.Permissions = @enumFromInt(0o755);

/// How long to wait for the agent to answer on its socket after spawning it, and
/// how often to look. It binds within milliseconds; this is the ceiling for a
/// machine under load.
const socket_timeout_ms: u32 = 5_000;
const socket_poll_ms: u32 = 100;

/// Largest text this reads into an arena: the ssh config, the pid file, the git
/// snapshot. None of them is anywhere near it.
const max_text = 1024 * 1024;

/// The git settings server mode changes, and therefore the ones `enter`
/// snapshots.
const git_settings = [_][]const u8{ "user.signingkey", "gpg.ssh.program", "gpg.format" };

/// The caffeinate agent, verbatim but for the indentation (a multiline string
/// literal in Zig carries no tab characters). Written from here rather than read
/// out of a dotfiles directory, so that server mode works on a machine that has
/// neither.
const caffeinate_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\  <key>Label</key>
    \\  <string>local.caffeinate.ac</string>
    \\  <key>ProgramArguments</key>
    \\  <array>
    \\    <string>/usr/bin/caffeinate</string>
    \\    <string>-s</string>
    \\  </array>
    \\  <key>ProcessType</key>
    \\  <string>Background</string>
    \\  <key>RunAtLoad</key>
    \\  <true/>
    \\  <key>KeepAlive</key>
    \\  <true/>
    \\</dict>
    \\</plist>
    \\
;

/// `kxdesk server-mode [enter|exit|toggle|status|refresh]`, `status` by default:
/// with no verb the command says what the mode is doing, as `pomodoro` answers.
///
/// Called by the client, so the arena and the io are the client's own and are
/// handed in. `toggle` is what the bar item's click asks for, and every verb that
/// changes the mode shows it on that item while it runs; see `transition`.
pub fn serverMode(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) anyerror![]const u8 {
    const verb = if (args.len > 0) args[0] else "status";
    if (args.len > 1) return error.UnknownArgument;

    const paths = try Paths.derive(arena);

    if (std.mem.eql(u8, verb, "enter")) return transition(arena, io, paths, .enter);
    if (std.mem.eql(u8, verb, "exit")) return transition(arena, io, paths, .leave);
    if (std.mem.eql(u8, verb, "refresh")) return transition(arena, io, paths, .refresh);
    if (std.mem.eql(u8, verb, "toggle")) return transition(arena, io, paths, .toggle);
    if (std.mem.eql(u8, verb, "status")) {
        // Answering with the state is also what puts the item right after the
        // mode was changed from a shell, which no daemon saw happen.
        show(arena, modeOf(io, paths));
        return report(arena, io, paths);
    }
    return error.UnknownArgument;
}

/// A change to the mode that the bar is told about, from the first `op` round
/// trip to the last `launchctl` one.
const Transition = enum { enter, leave, refresh, toggle };

/// Run one of them, with the item saying a change is in flight: an `enter` makes
/// a dozen `op` calls and asks 1Password for an unlock, so without it the bar
/// would look as if the click had done nothing until it was over.
///
/// The item is put back the way the mode *ended up*, whether the command
/// succeeded or failed: the cookie on disk is the truth `modeOf` reads, so a
/// failed `enter` shows the mode as off and a failed `exit` as on.
fn transition(
    arena: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    change: Transition,
) anyerror![]const u8 {
    // One change at a time, whoever asks for it: a click hands the work to a job
    // of its own, and this is what makes a second one - or a run started from a
    // shell - do nothing rather than race the first. The directory is made first
    // because the lock lives in it and an `enter` that has not run has not made
    // it yet.
    try makeDir(io, paths.dir, directory_mode);
    const held = try lock(io, paths);
    defer held.close(io);

    show(arena, .working);
    defer show(arena, modeOf(io, paths));

    return switch (change) {
        .enter => enter(arena, io, paths),
        .leave => leave(arena, io, paths),
        // Leaving first is what makes a key or a remote added in 1Password since
        // the last enter show up: enter materializes the account from scratch.
        .refresh => blk: {
            _ = try leave(arena, io, paths);
            break :blk enter(arena, io, paths);
        },
        .toggle => if (exists(io, paths.cookie))
            leave(arena, io, paths)
        else
            enter(arena, io, paths),
    };
}

/// What the item shows: the mode is off, it is on, or a change is running.
const Indicator = enum { inactive, active, working };

/// The mode as the cookie has it.
fn modeOf(io: std.Io, paths: Paths) Indicator {
    return if (exists(io, paths.cookie)) .active else .inactive;
}

/// The item's `click_script`: the shell line SketchyBar runs when the `server`
/// item is clicked, each path quoted, running this binary's `server-mode toggle`
/// with the click's output kept in a log beside the state directory.
///
/// Entering the mode this way fails - the click runs as a child of the bar, and
/// 1Password will not answer a third-party child - while leaving it asks
/// 1Password nothing and works. Composed here rather than in `bar.zig` so that
/// the state directory, the log and this binary's path are known in one place;
/// `storage` is the caller's because the bar's configuration is built from fixed
/// buffers and has no allocator to hand out.
pub fn clickScript(io: std.Io, storage: []u8) ![]const u8 {
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try std.process.executablePath(io, &exe_buffer);
    const exe = exe_buffer[0..length];

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try stateDirectory(&directory_buffer);

    return std.fmt.bufPrint(
        storage,
        "mkdir -p \"{s}\" && exec \"{s}\" server-mode toggle 2>>\"{s}/last-click.log\"",
        .{ dir, exe, dir },
    );
}

/// The state directory, in the caller's storage: the one path the click script
/// needs, for callers that have no arena of their own.
fn stateDirectory(storage: []u8) ![]const u8 {
    var environment: [std.fs.max_path_bytes]u8 = undefined;
    if (platform.kx_env(state_override, &environment, environment.len)) {
        // Copied into the caller's storage: the buffer it was read into belongs
        // to this frame and is gone by the time the caller uses the answer.
        return std.fmt.bufPrint(storage, "{s}", .{std.mem.sliceTo(&environment, 0)});
    }

    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_dir = if (platform.kx_env("HOME", &home_buffer, home_buffer.len))
        std.mem.sliceTo(&home_buffer, 0)
    else
        "/tmp";
    return std.fmt.bufPrint(storage, "{s}/Library/Application Support/kxdesk/server-mode", .{home_dir});
}

/// Take the lock the mode's changes serialize on, or report that another one is
/// already holding it. It is released when the process ends however it ends, so
/// a change killed halfway does not leave the mode uncallable.
fn lock(io: std.Io, paths: Paths) !std.Io.File {
    var file = std.Io.Dir.createFileAbsolute(io, paths.lock, .{ .truncate = false }) catch |err| return err;
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) return error.ServerModeBusy;
    return file;
}

/// Put the mode's state on the bar, in a connection of this command's own - see
/// the module comment for why this runs here and not in the daemon.
///
/// Best effort: a command whose work succeeded must not fail because there was
/// no bar to tell about it.
fn show(arena: std.mem.Allocator, indicator: Indicator) void {
    var client = sb.Client.init(arena, sb.sketchybar_service);
    defer client.deinit();
    client.connect() catch return;
    setIndicator(&client, indicator) catch {};
}

/// The two properties the item is: its glyph, and the colour that says the
/// state. One `--set` for both, so the bar redraws once.
fn setIndicator(client: *sb.Client, indicator: Indicator) !void {
    const glyph: []const u8 = if (indicator == .working) theme.glyph.loading else theme.glyph.server;
    const color: theme.Color = switch (indicator) {
        .working => theme.yellow,
        .active => theme.green,
        .inactive => theme.dark_grey,
    };

    var props: Props = .{};
    const argb = try props.argb(color);
    try props.write(.{ .icon = .{ .value = glyph, .color = argb } });
    try client.set(bar_item, props.slice());
    try client.commit();
}

/// Put the item back the way the mode is. Called wherever the bar configuration
/// is applied, because a freshly built bar declares the item switched off and
/// nothing else there can know what the mode was: the daemon did not run the
/// command that changed it.
pub fn restore(context: *Context) void {
    const paths = Paths.derive(context.arena) catch return;
    // The `apply` this runs from has already connected, but a bar that went away
    // between the two is not worth failing over.
    context.bar.connect() catch return;
    setIndicator(context.bar, modeOf(context.io, paths)) catch {};
}

/// Everything server mode keeps, under one directory: the materialized keys, the
/// snapshots `exit` restores from, and the three files that say whether the mode
/// is on and which agent serves it.
const Paths = struct {
    dir: []const u8,
    sock: []const u8,
    pidfile: []const u8,
    cookie: []const u8,
    keys: []const u8,
    backup: []const u8,
    ssh_backup: []const u8,
    git_backup: []const u8,
    /// The file the mode's changes serialize on, one at a time; see `lock`.
    lock: []const u8,

    fn derive(arena: std.mem.Allocator) !Paths {
        var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const dir = try arena.dupe(u8, try stateDirectory(&directory_buffer));

        const backup = try under(arena, dir, "backup");
        return .{
            .dir = dir,
            .sock = try under(arena, dir, "agent.sock"),
            .pidfile = try under(arena, dir, "agent.pid"),
            .cookie = try under(arena, dir, "active"),
            .keys = try under(arena, dir, "keys"),
            .backup = backup,
            .ssh_backup = try under(arena, backup, "ssh_config"),
            .git_backup = try under(arena, backup, "git_state"),
            .lock = try under(arena, dir, "lock"),
        };
    }

    fn under(arena: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
    }
};

/// One SSH key materialized from 1Password: where its private half was written,
/// and the public half as 1Password reports it, which is what the git signing
/// identity is matched against.
const Key = struct {
    private: []const u8,
    public: []const u8,
};

/// An item as `op item list` describes it. Only the fields that decide whether a
/// key is materialized, and under what name, are modelled.
const Item = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    category: []const u8 = "",
    vault: Vault = .{},

    const Vault = struct { id: []const u8 = "" };
};

/// Start serving: materialize the keys, load them into an agent, and point the
/// machine at that agent.
fn enter(arena: std.mem.Allocator, io: std.Io, paths: Paths) anyerror![]const u8 {
    if (exists(io, paths.cookie)) return error.ServerModeActive;

    try makeDir(io, paths.dir, directory_mode);
    // Also for a directory an earlier run left with the permissions the umask
    // gave it, which is what this used to create.
    std.Io.Dir.cwd().setFilePermissions(io, paths.dir, directory_mode, .{}) catch {};
    try makeDir(io, paths.keys, directory_mode);
    try makeDir(io, paths.backup, directory_mode);

    const op = try exec.path(arena, "op");
    const ssh_agent = try exec.path(arena, "ssh-agent");
    const ssh_add = try exec.path(arena, "ssh-add");

    // Up to the cookie below, a failure leaves only server mode's own state - a
    // directory and a running agent - and nothing of the machine's, so taking
    // those down again is the whole of the cleanup. Once the cookie is down, the
    // rewiring has started and `exit` is what undoes it; that is why the cookie
    // is not taken off again here.
    var armed = false;
    errdefer if (!armed) wipeAgentAndKeys(arena, io, paths);

    const items = try sshKeyItems(arena, io, op);
    const keys = try materialize(arena, io, paths, op, items);
    if (keys.len == 0) return error.NoSshKeys;

    try ensureAgent(arena, io, paths, ssh_agent, ssh_add);
    const loaded = try loadKeys(arena, io, ssh_add, paths.sock, keys);

    try writeFile(io, paths.cookie, "", file_mode);
    armed = true;

    try rewireSshConfig(arena, io, paths);
    try snapshotGit(arena, io, paths);
    const signing = try wireSigning(arena, io, keys);
    try setCaffeinate(arena, io, true);

    return std.fmt.allocPrint(
        arena,
        "server mode active\n  socket  {s}\n  keys    {d} of {d} loaded\n  signing {s}",
        .{
            paths.sock,
            loaded,
            keys.len,
            signing orelse "left as it was (no materialized key to sign with)",
        },
    );
}

/// Stop serving: put back everything `enter` changed, then take down what it
/// started.
fn leave(arena: std.mem.Allocator, io: std.Io, paths: Paths) anyerror![]const u8 {
    if (!exists(io, paths.cookie)) {
        // Nothing to leave - but an exit that was interrupted, or killed, has
        // taken the cookie off already, and what it did not get to is the
        // materialized keys. The one command anyone would reach for is this one,
        // so it takes them with it rather than reporting the mode gone and
        // leaving private key material on the disk.
        wipeAgentAndKeys(arena, io, paths);
        return error.ServerModeInactive;
    }
    std.Io.Dir.deleteFileAbsolute(io, paths.cookie) catch {};

    restoreSshConfig(arena, io, paths);
    restoreGit(arena, io, paths);

    // The keys and the agent go whatever else happens: `setCaffeinate` can fail,
    // and an exit that leaves the private keys materialized is worse than one
    // that leaves the keep-awake service loaded. Its error is answered after the
    // wipe, not instead of it.
    const caffeinate = setCaffeinate(arena, io, false);
    wipeAgentAndKeys(arena, io, paths);
    try caffeinate;

    return "server mode ended: ssh and git restored, keys wiped";
}

/// What the mode is doing, for a prompt or a probe.
fn report(arena: std.mem.Allocator, io: std.Io, paths: Paths) anyerror![]const u8 {
    if (!exists(io, paths.cookie)) return "server mode: inactive";

    // An agent that is gone is the one way this can be on and still not work -
    // which is what a machine left by an interrupted run looks like - so it is
    // said, rather than reported as an agent that holds nothing.
    const identities: []const u8 = blk: {
        const ssh_add = exec.path(arena, "ssh-add") catch break :blk "cannot tell (no ssh-add)";
        if (!agentAnswers(arena, io, ssh_add, paths.sock)) break :blk "no agent is answering";
        break :blk try std.fmt.allocPrint(arena, "{d}", .{identityCount(arena, io, ssh_add, paths.sock)});
    };
    const signing = try gitGet(arena, io, "user.signingkey");

    return std.fmt.allocPrint(
        arena,
        "server mode: active\n  socket     {s}\n  identities {s}\n  signing    {s}",
        .{ paths.sock, identities, signing orelse "(unset)" },
    );
}

/// Every SSH key of the personal account, from the one listing that has to
/// happen before any of them can be read.
fn sshKeyItems(arena: std.mem.Allocator, io: std.Io, op: []const u8) ![]const Item {
    // One 1Password approval per run: the session that leaves behind is what the
    // reads below use. A sign-in that does not finish is not fatal by itself -
    // the reads are the real gate, and their failure says what is wrong.
    if (try output(arena, io, &.{ op, "signin", "--account", account }, null) == null) {
        log.warn("1Password sign-in did not finish; using the session op already has", .{});
    }

    const listing = try output(arena, io, &.{ op, "item", "list", "--account", account, "--format=json" }, null) orelse {
        // Said rather than returned silently: this is the failure a click
        // produces, and its cause is not the mode's but the process's - a child
        // of the bar, or of the daemon, is refused 1Password's app however well
        // the CLI is set up, while a shell is answered.
        log.warn(
            "`op item list` answered nothing: either the CLI is not signed in, or this process is not one 1Password answers - a shell is, the bar and the daemon are not",
            .{},
        );
        return error.OnePasswordUnavailable;
    };

    const items = std.json.parseFromSliceLeaky([]const Item, arena, listing, .{
        .ignore_unknown_fields = true,
        // The listing outlives the parsed value (both live in the command's
        // arena), so the strings can point into it instead of being copied.
        .allocate = .alloc_if_needed,
    }) catch return error.InvalidOnePasswordResponse;

    var selected = std.ArrayList(Item).empty;
    for (items) |item| {
        if (std.mem.eql(u8, item.category, "SSH_KEY")) try selected.append(arena, item);
    }
    return selected.items;
}

/// Write every key's private half to the state directory, under a name derived
/// from the item's title, and report the keys that were written.
///
/// A key 1Password will not give up is skipped rather than fatal: the others are
/// still worth serving.
fn materialize(
    arena: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    op: []const u8,
    items: []const Item,
) ![]const Key {
    var keys = std.ArrayList(Key).empty;

    for (items) |item| {
        const name = try std.fmt.allocPrint(arena, "{s}/{s}_{s}", .{
            paths.keys,
            try slug(arena, item.title),
            item.id[0..@min(6, item.id.len)],
        });

        // `ssh-format=openssh` is what makes op hand back a key file rather than
        // a PEM blob, which is the form ssh-agent and ssh-keygen both take.
        const reference = try std.fmt.allocPrint(arena, "op://{s}/{s}/private key?ssh-format=openssh", .{
            item.vault.id,
            item.id,
        });
        const private_key = try output(arena, io, &.{ op, "read", reference }, null) orelse {
            log.warn("skipping '{s}': 1Password would not hand over its private key", .{
                item.title,
            });
            continue;
        };
        try writeFile(io, name, private_key, file_mode);

        // The public half is written beside the private one: it is how the git
        // signing identity is matched later.
        const public_key = try publicHalf(arena, io, op, item);
        if (public_key.len > 0) {
            try writeFile(io, try std.fmt.allocPrint(arena, "{s}.pub", .{name}), public_key, file_mode);
        }

        try keys.append(arena, .{ .private = name, .public = public_key });
    }

    return keys.items;
}

/// The key's public half as 1Password reports it, or "" when the item has none.
/// The field is optional, so its absence is an answer rather than an error.
fn publicHalf(arena: std.mem.Allocator, io: std.Io, op: []const u8, item: Item) ![]const u8 {
    const Detail = struct {
        fields: []const Field = &.{},

        const Field = struct {
            label: []const u8 = "",
            value: []const u8 = "",
        };
    };

    const detail_json = try output(arena, io, &.{
        op,              "item",      "get",
        item.id,         "--account", account,
        "--format=json",
    }, null) orelse return "";
    const detail = std.json.parseFromSliceLeaky(Detail, arena, detail_json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return "";

    for (detail.fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.label, "public key")) {
            return std.mem.trim(u8, field.value, " \t\r\n");
        }
    }
    return "";
}

/// The name a key is materialized under: the item's title, lowercased with its
/// slashes and spaces turned into underscores and everything else but letters,
/// digits, underscores and hyphens dropped.
fn slug(arena: std.mem.Allocator, title: []const u8) ![]const u8 {
    const kept = try arena.alloc(u8, title.len);
    var length: usize = 0;
    for (title) |character| {
        const mapped: u8 = switch (character) {
            'A'...'Z' => character + ('a' - 'A'),
            '/', ' ' => '_',
            else => character,
        };
        switch (mapped) {
            'a'...'z', '0'...'9', '_', '-' => {
                kept[length] = mapped;
                length += 1;
            },
            else => {},
        }
    }
    return kept[0..length];
}

/// Start the persistent agent, or keep the one already answering on the socket.
///
/// The agent is detached, so it survives `brew services restart kxdesk`: server
/// mode is on until it is taken off, not until the daemon happens to restart.
fn ensureAgent(
    arena: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    ssh_agent: []const u8,
    ssh_add: []const u8,
) !void {
    if (agentAnswers(arena, io, ssh_add, paths.sock)) return;

    // A socket left behind by an agent that is gone would keep the new one from
    // binding, and nothing else lives at this path.
    std.Io.Dir.deleteFileAbsolute(io, paths.sock) catch {};

    const vector = try terminated(arena, &.{ ssh_agent, "-D", "-a", paths.sock });
    const pid = platform.kx_spawn_detached(vector.items.ptr);
    if (pid <= 0) return error.AgentNotStarted;
    try writeFile(io, paths.pidfile, try std.fmt.allocPrint(arena, "{d}", .{pid}), file_mode);

    var waited: u32 = 0;
    while (waited < socket_timeout_ms and !exists(io, paths.sock)) : (waited += socket_poll_ms) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(socket_poll_ms), .awake) catch {};
    }

    // The socket appears while the agent is still starting, so it is the agent
    // that is asked, and not the filesystem, whether it is serving.
    if (!agentAnswers(arena, io, ssh_add, paths.sock)) return error.AgentNotStarted;
}

/// Load every materialized key into the agent, answering how many it took. A key
/// it refuses - one it already holds, say - is not worth failing the run over.
fn loadKeys(
    arena: std.mem.Allocator,
    io: std.Io,
    ssh_add: []const u8,
    socket: []const u8,
    keys: []const Key,
) !usize {
    const environment = try environmentWith(arena, socket);

    var loaded: usize = 0;
    for (keys) |key| {
        const result = std.process.run(arena, io, .{
            .argv = &.{ ssh_add, key.private },
            .environ_map = &environment,
        }) catch continue;
        switch (result.term) {
            .exited => |code| if (code == 0) {
                loaded += 1;
            },
            else => {},
        }
    }
    return loaded;
}

/// Stop the agent and remove what it was serving. What `exit` ends with, and
/// what an `enter` that failed before it changed anything of the machine's undoes
/// itself with.
fn wipeAgentAndKeys(arena: std.mem.Allocator, io: std.Io, paths: Paths) void {
    if (readText(arena, io, paths.pidfile)) |pid_text| {
        const pid = std.fmt.parseInt(i32, std.mem.trim(u8, pid_text, " \t\r\n"), 10) catch 0;
        if (pid > 0) std.posix.kill(pid, .TERM) catch {};
    } else |_| {}

    std.Io.Dir.deleteFileAbsolute(io, paths.pidfile) catch {};
    std.Io.Dir.deleteFileAbsolute(io, paths.sock) catch {};
    deleteKeys(io, paths);
}

fn deleteKeys(io: std.Io, paths: Paths) void {
    if (std.Io.Dir.openDirAbsolute(io, paths.dir, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io);
        dir.deleteTree(io, "keys") catch {};
    } else |_| {}
}

/// Whether an agent is answering on the socket. `ssh-add -l` exits 0 when the
/// agent holds keys and 1 when it holds none; 2 is "could not connect", which is
/// the only answer that means there is no agent.
fn agentAnswers(arena: std.mem.Allocator, io: std.Io, ssh_add: []const u8, socket: []const u8) bool {
    const environment = environmentWith(arena, socket) catch return false;
    const result = std.process.run(arena, io, .{
        .argv = &.{ ssh_add, "-l" },
        .environ_map = &environment,
    }) catch return false;
    return switch (result.term) {
        .exited => |code| code == 0 or code == 1,
        else => false,
    };
}

/// How many identities the agent holds. "The agent has no identities." is the
/// answer when it holds none - a line of text, and not an identity - which is
/// why the exit status is read as well.
fn identityCount(arena: std.mem.Allocator, io: std.Io, ssh_add: []const u8, socket: []const u8) usize {
    const environment = environmentWith(arena, socket) catch return 0;
    const result = std.process.run(arena, io, .{
        .argv = &.{ ssh_add, "-l" },
        .environ_map = &environment,
    }) catch return 0;

    switch (result.term) {
        .exited => |code| if (code > 1) return 0,
        else => return 0,
    }

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    return count;
}

/// The daemon's own environment plus `SSH_AUTH_SOCK`, which is where `ssh-add`
/// reads the socket from. The daemon is started by launchd, whose environment
/// says nothing about which agent to use.
fn environmentWith(arena: std.mem.Allocator, socket: []const u8) !std.process.Environ.Map {
    var environment = std.process.Environ.Map.init(arena);

    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const setting = std.mem.sliceTo(entry, 0);
        const separator = std.mem.indexOfScalar(u8, setting, '=') orelse continue;
        try environment.put(setting[0..separator], setting[separator + 1 ..]);
    }
    try environment.put("SSH_AUTH_SOCK", socket);
    return environment;
}

/// Point `~/.ssh/config`'s `IdentityAgent` at the agent's socket, keeping the
/// file as it was under the state directory so `exit` restores it byte for byte.
fn rewireSshConfig(arena: std.mem.Allocator, io: std.Io, paths: Paths) !void {
    const config_path = try sshConfigPath(arena);
    const original = std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(max_text)) catch |err| {
        log.warn("cannot read {s}: {s}", .{ config_path, @errorName(err) });
        return err;
    };

    // The snapshot is taken by the enter that is about to change the file, and
    // only when there is not one already: while server mode is on the file is
    // server mode's own, and recording it would throw away the one to restore.
    if (!exists(io, paths.ssh_backup)) try writeFile(io, paths.ssh_backup, original, file_mode);

    var rewritten = std.ArrayList(u8).empty;
    var replaced = false;
    var rest = original;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..end];

        if (try identityAgentLine(arena, line, paths.sock)) |with_socket| {
            try rewritten.appendSlice(arena, with_socket);
            replaced = true;
        } else {
            try rewritten.appendSlice(arena, line);
        }
        if (end < rest.len) try rewritten.append(arena, '\n');
        rest = rest[@min(end + 1, rest.len)..];
    }

    if (!replaced) {
        // 1Password's agent sets this line for every host, so a config without
        // one is a machine set up differently. Writing the file unchanged and
        // saying so beats reporting a server mode that is not wired.
        log.warn("{s} sets no IdentityAgent; ssh keeps the agent it had", .{config_path});
        return;
    }
    try writeFile(io, config_path, rewritten.items, file_mode);
}

/// Put back the ssh config `enter` snapshotted, if there is one.
fn restoreSshConfig(arena: std.mem.Allocator, io: std.Io, paths: Paths) void {
    const recorded = readText(arena, io, paths.ssh_backup) catch return;
    const config_path = sshConfigPath(arena) catch return;
    writeFile(io, config_path, recorded, file_mode) catch |err| {
        log.warn("cannot restore {s}: {s}", .{ config_path, @errorName(err) });
        return;
    };
    std.Io.Dir.deleteFileAbsolute(io, paths.ssh_backup) catch {};
}

/// `line` with its `IdentityAgent` value replaced by the agent's socket, or null
/// when the line sets no agent. The indentation and the whitespace after the
/// keyword are kept exactly as they were, so the file reads the same afterwards.
fn identityAgentLine(arena: std.mem.Allocator, line: []const u8, socket: []const u8) !?[]const u8 {
    const key = "IdentityAgent";
    const indentation = line.len - std.mem.trimStart(u8, line, " \t").len;
    const body = line[indentation..];
    if (!std.mem.startsWith(u8, body, key)) return null;

    const after_key = body[key.len..];
    const spacing = after_key.len - std.mem.trimStart(u8, after_key, " \t").len;
    // A value has to follow the keyword: `IdentityAgentFoo` is another setting
    // and a bare keyword is not one.
    if (spacing == 0 or spacing == after_key.len) return null;

    return try std.fmt.allocPrint(arena, "{s}{s}{s}\"{s}\"", .{
        line[0..indentation],
        key,
        after_key[0..spacing],
        socket,
    });
}

/// Record the three git settings server mode touches, so `exit` puts them back
/// exactly - including the ones that were unset, which are recorded as an empty
/// value rather than left out of the file.
fn snapshotGit(arena: std.mem.Allocator, io: std.Io, paths: Paths) !void {
    var recorded = std.ArrayList(u8).empty;
    for (git_settings) |key| {
        try recorded.appendSlice(arena, key);
        try recorded.append(arena, '\t');
        try recorded.appendSlice(arena, try gitGet(arena, io, key) orelse "");
        try recorded.append(arena, '\n');
    }
    try writeFile(io, paths.git_backup, recorded.items, file_mode);
}

/// Put back the git settings from the snapshot, if there is one.
fn restoreGit(arena: std.mem.Allocator, io: std.Io, paths: Paths) void {
    const recorded = readText(arena, io, paths.git_backup) catch return;
    const git = exec.path(arena, "git") catch return;

    var lines = std.mem.splitScalar(u8, recorded, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const key = line[0..tab];
        const value = line[tab + 1 ..];

        // A setting that was unset goes back to being unset, and a `--unset-all`
        // that finds nothing is that same state rather than a failure.
        if (value.len > 0) {
            _ = succeeded(arena, &.{ git, "config", "--global", key, value });
        } else {
            _ = succeeded(arena, &.{ git, "config", "--global", "--unset-all", key });
        }
    }
    std.Io.Dir.deleteFileAbsolute(io, paths.git_backup) catch {};
}

/// Point git's commit and tag signing at a materialized key, answering which key
/// that is - or null when there is none to sign with.
///
/// The key git already signs with wins; without a match, the first ed25519
/// serves. Signing is left alone when neither finds a key rather than failed
/// over: ssh is wired either way.
fn wireSigning(arena: std.mem.Allocator, io: std.Io, keys: []const Key) !?[]const u8 {
    const current = try gitGet(arena, io, "user.signingkey");

    var signing: ?[]const u8 = null;
    if (current) |identity| {
        for (keys) |key| {
            if (key.public.len > 0 and std.mem.eql(u8, identity, key.public)) {
                signing = key.private;
                break;
            }
        }
    }
    if (signing == null) {
        for (keys) |key| {
            if (std.mem.indexOf(u8, key.public, "ssh-ed25519") != null) {
                signing = key.private;
                break;
            }
        }
    }

    if (signing == null) {
        log.warn("no materialized key to sign with; git signing is left alone", .{});
        return null;
    }

    const git = try exec.path(arena, "git");
    if (!succeeded(arena, &.{ git, "config", "--global", "user.signingkey", signing.? })) {
        return error.GitConfigFailed;
    }
    // The signer is named by absolute path, because the daemon's `PATH` is
    // launchd's and has no Homebrew in it.
    const ssh_keygen = try exec.path(arena, "ssh-keygen");
    if (!succeeded(arena, &.{ git, "config", "--global", "gpg.ssh.program", ssh_keygen })) {
        return error.GitConfigFailed;
    }
    return signing;
}

/// A global git setting, or null when it is unset.
fn gitGet(arena: std.mem.Allocator, io: std.Io, key: []const u8) !?[]const u8 {
    const value = try output(arena, io, &.{ try exec.path(arena, "git"), "config", "--global", "--get", key }, null) orelse
        return null;
    return std.mem.trimEnd(u8, value, "\n");
}

/// Install and start the keep-awake service, or stop it and take it away again.
/// A machine that cannot be told to stay awake is worth saying so about, not
/// failing the whole mode over.
fn setCaffeinate(arena: std.mem.Allocator, io: std.Io, on: bool) !void {
    const plist = try std.fmt.allocPrint(arena, "{s}/Library/LaunchAgents/{s}.plist", .{
        try home(arena),
        caffeinate_label,
    });
    const domain = try std.fmt.allocPrint(arena, "gui/{d}", .{platform.kx_uid()});
    const service = try std.fmt.allocPrint(arena, "{s}/{s}", .{ domain, caffeinate_label });
    const launchctl = exec.path(arena, "launchctl") catch return;

    if (!on) {
        if (launchdKnows(arena, launchctl, service)) {
            _ = succeeded(arena, &.{ launchctl, "bootout", service });
        }
        std.Io.Dir.deleteFileAbsolute(io, plist) catch {};
        return;
    }

    if (std.fs.path.dirname(plist)) |directory| {
        std.Io.Dir.createDirAbsolute(io, directory, launch_agents_mode) catch {};
    }
    try writeFile(io, plist, caffeinate_plist, plist_mode);

    // `bootstrap` refuses a service launchd already has, which is the state to
    // keep when this runs on a machine that was in server mode already.
    if (!launchdKnows(arena, launchctl, service)) {
        if (!succeeded(arena, &.{ launchctl, "bootstrap", domain, plist })) {
            log.warn("launchd would not load {s}; the machine may still sleep", .{plist});
        }
    }
}

fn launchdKnows(arena: std.mem.Allocator, launchctl: []const u8, service: []const u8) bool {
    return succeeded(arena, &.{ launchctl, "print", service });
}

/// Write `bytes` to `path`, replacing what was there. A file that already exists
/// keeps its permissions - the ssh config is the one file here that is not ours
/// to re-mode - and a new one is created with `mode`.
fn writeFile(io: std.Io, path: []const u8, bytes: []const u8, mode: std.Io.File.Permissions) !void {
    const fresh = !exists(io, path);
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    if (fresh) try std.Io.Dir.cwd().setFilePermissions(io, path, mode, .{});
}

fn readText(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_text));
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// The `mkdir -p` of the directories server mode owns: one that is already there
/// is the state an earlier run left rather than a failure - it holds the
/// snapshots `exit` restores from, and the keys are replaced anyway.
fn makeDir(io: std.Io, path: []const u8, mode: std.Io.File.Permissions) !void {
    std.Io.Dir.createDirAbsolute(io, path, mode) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Run `argv` and report whether it exited zero. Both streams are discarded:
/// this is for the commands whose whole answer is their status.
fn succeeded(scratch: std.mem.Allocator, argv: []const []const u8) bool {
    const vector = terminated(scratch, argv) catch return false;
    return platform.kx_exec_status(vector.items.ptr) == 0;
}

/// Run `argv` to completion and return its standard output, or null when it did
/// not exit zero - and when it could not be started at all. Either failure is
/// logged with the command's stderr: that is the whole explanation of a refusal.
fn output(
    scratch: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    environment: ?*const std.process.Environ.Map,
) !?[]u8 {
    const result = std.process.run(scratch, io, .{ .argv = argv, .environ_map = environment }) catch |err| {
        log.warn("cannot run {s}: {s}", .{ argv[0], @errorName(err) });
        return null;
    };
    switch (result.term) {
        .exited => |code| if (code != 0) {
            const said = std.mem.trim(u8, result.stderr, " \t\r\n");
            if (said.len == 0) {
                log.warn("{s} exited {d}", .{ argv[0], code });
            } else {
                log.warn("{s} exited {d}: {s}", .{ argv[0], code, said });
            }
            return null;
        },
        else => return null,
    }
    return result.stdout;
}

fn terminated(scratch: std.mem.Allocator, argv: []const []const u8) !std.ArrayList(?[*:0]const u8) {
    var vector = std.ArrayList(?[*:0]const u8).empty;
    for (argv) |argument| try vector.append(scratch, try scratch.dupeZ(u8, argument));
    try vector.append(scratch, null);
    return vector;
}

/// The user's home directory, from the environment the daemon was started with.
/// The fallback keeps a probe without one working out of `/tmp`.
fn home(arena: std.mem.Allocator) ![]const u8 {
    var environment: [std.fs.max_path_bytes]u8 = undefined;
    if (platform.kx_env("HOME", &environment, environment.len)) {
        return try arena.dupe(u8, std.mem.sliceTo(&environment, 0));
    }
    return "/tmp";
}

fn sshConfigPath(arena: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.ssh/config", .{try home(arena)});
}
