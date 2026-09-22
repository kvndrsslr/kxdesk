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
    return gpa.dupeZ(u8, std.mem.sliceTo(&buffer, 0));
}

/// The applications the bindings open, with the arguments they were bound with:
/// Arc on the debugging port `hyper ret` opened it on, kitty as a single instance
/// listening on the socket `kitty @` reaches.
pub const App = enum { code, kitty, arc_debug };

/// Launch one of them, detached from this process.
pub fn openApp(arena: std.mem.Allocator, application: App) !void {
    switch (application) {
        .code => try spawn(arena, &.{ "/usr/bin/open", "-a", "Visual Studio Code" }),
        .arc_debug => try spawn(arena, &.{
            "/usr/bin/open", "-a", "Arc", "--args", "--remote-debugging-port=9222",
        }),
        .kitty => {
            // Resolved rather than assumed, like every other external command
            // here: the daemon runs under launchd, whose PATH has no Homebrew in
            // it.
            const kitty = try path(arena, "kitty");
            var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
            if (platform.kx_env("HOME", &home_buffer, home_buffer.len)) {
                const home = try arena.dupeZ(u8, std.mem.sliceTo(&home_buffer, 0));
                try spawn(arena, &.{
                    kitty, "-d", home, "--single-instance", "--listen-on", "unix:/tmp/mykitty",
                });
            } else {
                // Without a home to start in, kitty's own default is better than
                // a guess at one.
                try spawn(arena, &.{
                    kitty, "--single-instance", "--listen-on", "unix:/tmp/mykitty",
                });
            }
        },
    }
}

/// Launch an argument vector detached from this process, so that the application
/// a keystroke opened outlives the call that started it. `argv[0]` is a
/// filesystem path; nothing here goes through a shell.
pub fn spawn(arena: std.mem.Allocator, argv: []const []const u8) !void {
    const vector = try arena.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |argument, index| vector[index] = try arena.dupeZ(u8, argument);
    vector[argv.len] = null;
    if (platform.kx_spawn_detached(vector.ptr) < 0) return error.LaunchFailed;
}
