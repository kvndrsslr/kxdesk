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

const std = @import("std");

/// Our daemon: the label, where launchd is told about it, and where it logs. The
/// program path is the one brew keeps stable across `HEAD-<sha>` installs, which
/// is why the plist names it rather than a Cellar path.
const label = "org.kdressler.kxdesk.grabber";
const plist_path = "/Library/LaunchDaemons/" ++ label ++ ".plist";
// The bundle's inner binary, not `bin/kxdesk-grabber`: the seize needs an Input
// Monitoring grant, a root LaunchDaemon cannot raise that dialog, and an app is what
// the pane can be told to trust - signed with the same certificate as the daemon, so
// the grant survives upgrades.
const program = "/opt/homebrew/opt/kxdesk/kxdesk-grabber.app/Contents/MacOS/kxdesk-grabber";
const log_path = "/opt/homebrew/var/log/kxdesk-grabber.log";

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

    return "installed: the grabber daemon. If it cannot seize the keyboard it needs\n" ++
        "Input Monitoring for kxdesk-grabber in System Settings > Privacy & Security,\n" ++
        "and one more `kxdesk grabber install` to restart it with that grant.";
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
    return arena.print("grabber: {s}  driver: {s}, {s}  log: {s}", .{
        daemon, installed, serving, log_path,
    });
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
