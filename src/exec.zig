//! Resolving the external commands the bar's items and commands depend on.
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
    if (!platform.sb_which(name.ptr, &buffer, buffer.len)) return error.NotInstalled;
    return gpa.dupeZ(u8, std.mem.sliceTo(&buffer, 0));
}
