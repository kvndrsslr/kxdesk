//! Installing the root daemon that tap-hold rules need, and the driver extension
//! it types through.
//!
//! `.remap a [device builtin] { tap: a, hold: lshift }` cannot be done from an
//! event tap: deciding tap-versus-hold means swallowing the key before anyone else
//! sees it, and delivering the hold means typing a modifier back - which takes a
//! seized keyboard (root) and a virtual HID device to type through. Two things
//! follow, and neither is installed by `brew`:
//!
//!   * pqrs's Karabiner-DriverKit virtual HID device - the driver extension plus
//!     the userland daemon that serves it, from a pinned `.pkg`. The extension
//!     needs a click in System Settings the first time, which no installer can do.
//!   * upstream's `kxdesk-grabber`, built from the same pinned source as the
//!     engine, as its own LaunchDaemon running the copy brew installs.
//!
//! Both are root's, so both are this one command's work: `sudo kxdesk grabber
//! install`. It runs in the client rather than the daemon - `server-mode`'s reason
//! - because `sudo` and `installer` need the terminal the daemon does not have.
//!
//! One step is neither root's nor a terminal's: the Input Monitoring grant the
//! seize needs, which TCC only takes from a drag in System Settings. `install`
//! hands that to the daemon's guide panel and waits for the grant to land, then
//! restarts the grabber with it - so a fresh machine is one password and one drag.

const std = @import("std");

const control = @import("control.zig");
const platform = @import("platform.zig");

/// Our daemon: the label, where launchd is told about it, and where it logs. The
/// program path is the one brew keeps stable across `HEAD-<sha>` installs, which
/// is why the plist names it rather than a Cellar path.
const label = "org.kdressler.kxdesk.grabber";
const plist_path = "/Library/LaunchDaemons/" ++ label ++ ".plist";
/// The bundle, which is what the privacy pane lists, and the binary inside it.
/// Not `bin/kxdesk-grabber`: the seize needs an Input Monitoring grant, a root
/// LaunchDaemon cannot raise that dialog, and an app is what the pane can be told
/// to trust - signed with the same certificate as the daemon, so the grant
/// survives upgrades.
pub const bundle = "/opt/homebrew/opt/kxdesk/kxdesk-grabber.app";
const program = bundle ++ "/Contents/MacOS/kxdesk-grabber";
const log_path = "/opt/homebrew/var/log/kxdesk-grabber.log";

/// The grabber's IPC: the socket upstream's agent and grabber agree on, and the
/// protocol revision the pinned source speaks. A pin bump that changes either is
/// not silent - the grabber answers a mismatch with an error frame, which `probe`
/// turns into `error.GrabberRefused`.
const socket_path = "/var/run/skhd/grabber.sock";
const protocol_version = 2;

/// Where the Input Monitoring grant is given. The pane's own URL rather than the
/// Privacy & Security root, so the list is what opens; `Privacy_ListenEvent` is
/// that list.
pub const pane_url = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension" ++
    "?Privacy_ListenEvent";

/// The guide panel's one line per case, kept next to the URLs they talk about.
pub const drag_instruction = "Drag kxdesk-grabber into the Input Monitoring list";
pub const install_instruction = "Tap-hold rules need the grabber: one install, then one drag";

/// The script the panel's Install button opens in Terminal, and the stable brew
/// link it runs: a root install needs a password prompt, and a password prompt
/// needs a terminal - neither of which a daemon can produce.
const install_script_path = "/tmp/kxdesk-grabber-install.command";
const client_path = "/opt/homebrew/bin/kxdesk";
const install_script =
    \\#!/bin/sh
    \\# Written by kxdesk for the guide panel's Install button.
    \\
    \\/opt/homebrew/bin/kxdesk grabber install
    \\printf '\nPress return to close this window.\n'
    \\read _
    \\
;

/// The pinned driver extension, verbatim from upstream skhd.zig: its grabber's
/// IPC is validated against this version of the dext and daemon, and the hash is
/// what makes the download worth trusting. A bump is deliberate, hence the pin.
const dext_version = "6.14.0";
const dext_url = "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v" ++
    dext_version ++ "/Karabiner-DriverKit-VirtualHIDDevice-" ++ dext_version ++ ".pkg";
const dext_sha256 = "ebfb6a643ea98bb7c2e08a4f99353b2a3129e397f4302340443bbd936f12eb1c";

/// The driver's own daemon. Its `.pkg` installs the app but registers no launchd
/// job - the plist ships with Karabiner-Elements, not with the standalone driver -
/// so on a machine that has never run that, nothing would start it. The socket
/// directory below is how the grabber finds it, and what this checks for.
const vhidd_label = "org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon";
const vhidd_plist_path = "/Library/LaunchDaemons/" ++ vhidd_label ++ ".plist";
const vhidd_program = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice" ++
    "/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon";

/// What the running grabber says about itself.
pub const Report = struct {
    /// Its build version, for `status`: the handshake already carries it.
    version: []const u8 = "",
    access: Access = .unknown,

    /// Whether it may seize a keyboard. TCC answers that for the asking process
    /// only, so this arrives in the grabber's own reply rather than being asked
    /// from here; `unknown` is a grabber built before it says.
    pub const Access = enum {
        granted,
        denied,
        unknown,

        pub fn text(self: Access) []const u8 {
            return @tagName(self);
        }
    };
};

/// Ask the running grabber what it is and whether it may seize, over its socket.
///
/// Errors rather than a fourth state: nothing answering is the answer for a
/// grabber that is not installed, and the caller decides what to do about it.
pub fn probe(arena: std.mem.Allocator) !Report {
    var body_buffer: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(
        &body_buffer,
        "{{\"type\":\"hello\",\"uid\":{d},\"version\":{d}}}",
        .{ platform.kx_uid(), protocol_version },
    );

    // The frame the shared protocol declares: four big-endian length bytes, then
    // the body.
    var frame: [4 + body_buffer.len]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], @intCast(body.len), .big);
    @memcpy(frame[4..][0..body.len], body);
    const request = frame[0 .. 4 + body.len];

    // Read to the closing brace rather than to a length: the reply is one frame,
    // its body is JSON, and a terminator is what lets the wait be bounded - a
    // frame read has no timeout to give.
    var reply_buffer: [1024]u8 = undefined;
    const received = platform.kx_unix_reply(
        socket_path,
        request.ptr,
        request.len,
        "}",
        1,
        &reply_buffer,
        reply_buffer.len,
        500,
    );
    if (received < 5) return error.GrabberUnavailable;
    return parseReport(arena, reply_buffer[0..@intCast(received)]);
}

/// One hello reply: the shared frame's length prefix, then the body. Split out of
/// `probe` because the wire format is the part worth a test.
pub fn parseReport(arena: std.mem.Allocator, frame: []const u8) !Report {
    if (frame.len < 5) return error.MalformedReply;
    const length: usize = std.mem.readInt(u32, frame[0..4], .big);
    if (length == 0 or length + 4 > frame.len) return error.MalformedReply;

    const Reply = struct {
        type: []const u8,
        grabber_version: ?[]const u8 = null,
        input_monitoring: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Reply, arena, frame[4..][0..length], .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedReply;
    if (!std.mem.eql(u8, parsed.value.type, "ok")) return error.GrabberRefused;

    return .{
        .version = parsed.value.grabber_version orelse "",
        // A grabber built before the reply carried the grant cannot say whether it
        // may seize, and `unknown` is what a caller has to act on: show the panel,
        // because that is the fix either way.
        .access = if (parsed.value.input_monitoring) |word|
            std.meta.stringToEnum(Report.Access, word) orelse .unknown
        else
            .unknown,
    };
}

/// Write the script the panel's Install button runs, and answer its path.
pub fn writeInstallScript(io: std.Io) ![]const u8 {
    var file = try std.Io.Dir.createFileAbsolute(io, install_script_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, install_script);
    try std.Io.Dir.cwd().setFilePermissions(io, install_script_path, @enumFromInt(0o755), .{});
    return install_script_path;
}

/// One line about the daemon, or an empty string after acting: the shape
/// `server_mode.serverMode` answers with, so the client can print it and go.
pub fn grabber(arena: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    const verb = if (args.len > 0) args[0] else "status";

    if (std.mem.eql(u8, verb, "status")) return status(arena, io);
    if (std.mem.eql(u8, verb, "install")) return install(arena, io);
    if (std.mem.eql(u8, verb, "uninstall")) return uninstall(arena, io);
    return error.UnknownArgument;
}

/// Install both halves. Not idempotent by pretending: each step asks whether it
/// has already happened, so a re-run after a macOS update - or after only the
/// extension was approved - does the rest rather than downloading a driver that is
/// already there.
fn install(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (std.c.geteuid() != 0) return elevate(arena, io, "install");

    if (!driverPresent(io)) try installDriver(arena, io);
    try startDriver(arena, io);
    try installDaemon(arena, io);

    return grant(arena, io);
}

/// The one step no installer can take: the Input Monitoring grant.
///
/// TCC takes it only from a drag into the pane's list, so the last half of an
/// install is a panel - shown by the daemon, because a root process must not be
/// the one opening panes or drawing windows in the user's session. This process
/// then waits for the probe to say the grant has landed, restarts the grabber so
/// it opens the keyboards with it, and tells the engine to hand its rules over
/// again. That restart is the part root makes free here: it is the same password
/// prompt, not a second one.
fn grant(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const report = probe(arena) catch {
        return "installed: the grabber daemon, but it is not answering on " ++ socket_path ++
            ".\nCheck `launchctl print system/" ++ label ++ "` and " ++ log_path;
    };
    if (report.access == .granted) return "installed: the grabber daemon, and Input Monitoring is already granted.";

    std.debug.print(
        "the grabber cannot seize a keyboard yet: macOS takes Input Monitoring only from\n" ++
            "a drag into System Settings, so a panel is opening beside the list.\n",
        .{},
    );
    guide(arena, io);

    var waited: u32 = 0;
    while (waited < grant_wait_ms) : (waited += grant_poll_ms) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(grant_poll_ms), .awake) catch {};
        // A probe of its own each time: the arena that outlives a command would
        // otherwise hold every parse of a three-minute wait.
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const again = probe(scratch.allocator()) catch continue;
        if (again.access != .granted) continue;

        quiet(io, &.{ "/bin/launchctl", "kickstart", "-k", "system/" ++ label });
        restartEngine(arena, io);
        return "installed: the grabber daemon, and Input Monitoring is granted.\n" ++
            "The keyboards are seized again, so the tap-hold rules are live.";
    }

    return "installed: the grabber daemon. Input Monitoring is still not granted:\n" ++
        "add kxdesk-grabber in System Settings > Privacy & Security > Input Monitoring,\n" ++
        "then run `sudo kxdesk grabber install` once more.";
}

/// How long the panel is given, and how often the grant is looked for: long
/// enough to find System Settings and drag one row, short enough that a walk-away
/// leaves a command that ends.
const grant_wait_ms: u32 = 180_000;
const grant_poll_ms: u32 = 500;

/// Ask the daemon to show the guide panel. Nothing waits on the answer and a
/// daemon that is not running is not an error: the panel is a convenience, and
/// the instructions are printed either way.
fn guide(arena: std.mem.Allocator, io: std.Io) void {
    var response: [1024]u8 = undefined;
    _ = control.submit(arena, io, "guide", &.{}, &response) catch return;
}

/// Have the engine re-forward its rules: the grabber is a new process with none,
/// and the engine's old subscription socket went with the old one. A reload is
/// the path a saved `skhdrc` takes, so it is the one to reuse.
fn restartEngine(arena: std.mem.Allocator, io: std.Io) void {
    var response: [1024]u8 = undefined;
    _ = control.submit(arena, io, "hotkey", &.{"reload"}, &response) catch return;
}

fn uninstall(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (std.c.geteuid() != 0) return elevate(arena, io, "uninstall");

    // Only our daemon: the driver extension is pqrs's, it may predate kxdesk, and
    // removing it would take any other client of it with it.
    quiet(io, &.{ "/bin/launchctl", "bootout", "system/" ++ label });
    std.Io.Dir.deleteFileAbsolute(io, plist_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return "removed the grabber daemon; the driver extension is still installed";
}

fn status(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const daemon = if (try launchdKnows(io, label)) "running" else "not installed";
    const installed = if (driverPresent(io)) "installed" else "not installed";
    const serving = if (try launchdKnows(io, vhidd_label)) "running" else "stopped";
    // The grant is the half nothing else can report: the socket says whether the
    // grabber is answering at all, and its own reply says the rest.
    const report = probe(arena) catch {
        return arena.print("grabber: {s}  driver: {s}, {s}  api: no answer  log: {s}", .{
            daemon, installed, serving, log_path,
        });
    };
    return arena.print(
        "grabber: {s}  driver: {s}, {s}  api: {s} (build {s})  input monitoring: {s}  log: {s}",
        .{ daemon, installed, serving, "ok", report.version, report.access.text(), log_path },
    );
}

/// Re-run this binary under sudo, which is the only way the caller's terminal sees
/// the password prompt and `installer`'s progress. `sudo` resolves the binary
/// again, so the elevated run continues as root and does not come back here.
fn elevate(arena: std.mem.Allocator, io: std.Io, verb: []const u8) ![]const u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try std.process.executablePath(io, &path_buffer);
    const self = path_buffer[0..length];
    _ = arena;

    try run(io, &.{ "/usr/bin/sudo", self, "grabber", verb });
    return "";
}

/// Download, verify and install the driver extension, then start its daemon.
fn installDriver(arena: std.mem.Allocator, io: std.Io) !void {
    const package = try std.fmt.allocPrint(arena, "/tmp/kxdesk-dext-{s}.pkg", .{dext_version});

    if (!exists(io, package)) {
        std.debug.print("downloading the Karabiner driver extension {s}\n  {s}\n", .{
            dext_version, dext_url,
        });
        try run(io, &.{ "/usr/bin/curl", "-fsSL", "-o", package, dext_url });
    }

    // The hash is the pin's other half: a re-tagged or tampered package is refused
    // here rather than installed as root.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, package, arena, .limited(64 << 20));
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = try std.fmt.allocPrint(arena, "{x}", .{&digest});
    if (!std.mem.eql(u8, actual, dext_sha256)) {
        // Dropped, so the next attempt downloads it again instead of retrying a
        // file that cannot be right.
        std.Io.Dir.deleteFileAbsolute(io, package) catch {};
        std.debug.print("refusing {s}: sha256 {s}, expected {s}\n", .{
            package, actual, dext_sha256,
        });
        return error.Sha256Mismatch;
    }

    std.debug.print("installing it (the system extension may ask to be approved)\n", .{});
    try run(io, &.{ "/usr/sbin/installer", "-pkg", package, "-target", "/" });
}

/// Write our daemon's job and start it. Bootout first, so a re-run replaces the
/// running one instead of being refused as already loaded.
fn installDaemon(arena: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("installing the grabber daemon {s}\n", .{label});
    var file = try std.Io.Dir.createFileAbsolute(io, plist_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, try daemonPlist(arena, label, program));

    quiet(io, &.{ "/bin/launchctl", "bootout", "system/" ++ label });
    try run(io, &.{ "/bin/launchctl", "bootstrap", "system", plist_path });
}

/// A LaunchDaemon's job, for a program that logs to one file and is restarted if it
/// dies - but not in a tight loop.
fn daemonPlist(arena: std.mem.Allocator, job: []const u8, executable: []const u8) ![]const u8 {
    return arena.print(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <true/>
        \\    <key>ThrottleInterval</key>
        \\    <integer>10</integer>
        \\    <key>StandardOutPath</key>
        \\    <string>{s}</string>
        \\    <key>StandardErrorPath</key>
        \\    <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ job, executable, log_path, log_path });
}

/// Whether the driver's payload is on disk. Asked of the daemon's own executable
/// rather than of the socket directory: a `.sock` file outlives the process that
/// listened there, so a machine whose driver was removed still shows one, and
/// trusting it would skip the install that is needed.
fn driverPresent(io: std.Io) bool {
    return exists(io, vhidd_program);
}

/// Write the driver's job if it is missing and start it if it is not loaded,
/// which is also the whole of what an already-installed payload needs after a
/// logout, a macOS update, or an extension approval.
fn startDriver(arena: std.mem.Allocator, io: std.Io) !void {
    if (!driverPresent(io)) {
        std.debug.print("the driver daemon is missing from {s}\n", .{vhidd_program});
        return error.InstallerFailed;
    }

    if (!exists(io, vhidd_plist_path)) {
        var file = try std.Io.Dir.createFileAbsolute(io, vhidd_plist_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, try daemonPlist(arena, vhidd_label, vhidd_program));
    }
    if (!try launchdKnows(io, vhidd_label)) {
        try run(io, &.{ "/bin/launchctl", "bootstrap", "system", vhidd_plist_path });
    }
    // A loaded job whose daemon has not spawned yet still answers `launchctl
    // print`; kicking it is what makes the socket exist now rather than later.
    quiet(io, &.{ "/bin/launchctl", "kickstart", "system/" ++ vhidd_label });
}

/// Whether launchd has the job loaded. `launchctl print` answers non-zero for a
/// label it does not know, which is the state a fresh machine is in.
fn launchdKnows(io: std.Io, comptime job: []const u8) !bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/launchctl", "print", "system/" ++ job },
        // Nothing to show: the answer is the exit code, and its output is noise.
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    return (try child.wait(io)).success();
}

/// Run something the user is meant to watch - `sudo`, `curl`, `installer` - with
/// the terminal inherited, and fail on a non-zero exit.
fn run(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv });
    if (!(try child.wait(io)).success()) return error.CommandFailed;
}

/// Run a probe whose failure is a normal answer - "was not loaded", "already
/// gone" - with its output dropped rather than shown. `launchctl` writes the
/// reason to stderr, and none of it is the caller's business.
fn quiet(io: std.Io, argv: []const []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}
