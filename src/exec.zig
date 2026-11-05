//! Resolving the external commands kxdesk runs, and launching the applications
//! `kxdesk app open` starts.
//!
//! Binaries are resolved rather than assumed: the daemon is started by launchd,
//! whose `PATH` contains neither Homebrew nor anything under the home directory.
//! Resolution happens once per refresh and the result is handed to
//! `std.process.run` as an absolute path, so nothing here needs a shell.

const std = @import("std");

const platform = @import("platform.zig");

/// Absolute path of an executable, or an error when it is not installed.
pub fn path(gpa: std.mem.Allocator, name: [:0]const u8) ![:0]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (!platform.kx_which(name.ptr, &buffer, buffer.len)) return error.NotInstalled;
    return gpa.dupeSentinel(u8, std.mem.sliceTo(&buffer, 0), 0);
}

/// The applications the bindings open, with the arguments they were bound with:
/// kitty as a single instance listening on the socket `kitty @` reaches, and the
/// default browser summoned rather than opened by name, since which browser that
/// is can change under the binding.
pub const App = enum { code, kitty, browser };

/// Run one of them: most are launched detached, the browser is summoned in place.
pub fn openApp(io: std.Io, arena: std.mem.Allocator, application: App) !void {
    switch (application) {
        .code => try spawn(io, arena, &.{ "/usr/bin/open", "-a", "Visual Studio Code" }),
        .browser => if (!platform.kx_browser_open()) return error.BrowserUnavailable,
        .kitty => {
            // Resolved rather than assumed, like every other external command
            // here: the daemon runs under launchd, whose PATH has no Homebrew in
            // it.
            const kitty = try path(arena, "kitty");
            var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (platform.kx_env("HOME", &home_buffer, home_buffer.len)) {
                const home = try arena.dupeSentinel(u8, std.mem.sliceTo(&home_buffer, 0), 0);
                try spawn(io, arena, &.{
                    kitty, "-d", home, "--single-instance", "--listen-on", "unix:/tmp/mykitty",
                });
            } else {
                // Without a home to start in, kitty's own default is better than
                // a guess at one.
                try spawn(io, arena, &.{
                    kitty, "--single-instance", "--listen-on", "unix:/tmp/mykitty",
                });
            }
        },
    }
}

/// Launch an argument vector detached from this process, so that the application
/// a keystroke opened outlives the call that started it. `argv[0]` is a
/// filesystem path; nothing here goes through a shell.
pub fn spawn(io: std.Io, arena: std.mem.Allocator, argv: []const []const u8) !void {
    const vector = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |argument, index| vector[index] = try arena.dupeSentinel(u8, argument, 0);
    vector[argv.len] = null;
    const pid = platform.kx_spawn_detached(vector.ptr);
    if (pid < 0) return error.LaunchFailed;
    remember(io, pid);
}

/// Pids of the detached children `spawn` started and nobody waits for. They stay
/// children of this process, so each one that exits is a zombie until it is
/// reaped; `reap` does that on the receive loop's timer.
var pending: [64]i32 = undefined;
var pending_count: usize = 0;
var pending_lock: std.Io.Mutex = .init;

/// Record a child for `reap`. The list is bounded like everything else that is
/// not on an allocator: full means the oldest pid is forgotten and its process is
/// left a zombie, which a spawn rate that fills this between two wake-ups has
/// earned.
fn remember(io: std.Io, pid: i32) void {
    pending_lock.lockUncancelable(io);
    defer pending_lock.unlock(io);

    if (pending_count == pending.len) {
        std.mem.copyForwards(i32, pending[0..], pending[1..]);
        pending_count -= 1;
    }
    pending[pending_count] = pid;
    pending_count += 1;
}

/// Reap the detached children that have exited; one that is still running is left
/// for the next call. Called from the receive loop's timer, which is the only
/// place this process waits for a child it did not start through `std.process`.
pub fn reap(io: std.Io) void {
    pending_lock.lockUncancelable(io);
    defer pending_lock.unlock(io);

    var kept: usize = 0;
    for (pending[0..pending_count]) |pid| {
        if (platform.kx_reap(pid)) continue;
        pending[kept] = pid;
        kept += 1;
    }
    pending_count = kept;
}
