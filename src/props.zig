//! Building blocks for SketchyBar command batches.

const std = @import("std");

const theme = @import("theme.zig");

/// A short-lived list of `key=value` properties for a single `--set`.
///
/// Values are formatted into a fixed scratch buffer, so assembling a property
/// list never allocates. Lists are small, built and consumed immediately.
pub const Props = struct {
    scratch: [4096]u8 = undefined,
    scratch_len: usize = 0,
    items: [64][]const u8 = undefined,
    len: usize = 0,

    /// Append a pre-built property.
    ///
    /// The list is bounded rather than grown: a `Props` is a handful of
    /// properties assembled on the stack for one `--set`, and the bound is far
    /// above the largest item in `bar.zig`. Running past it is a mistake in this
    /// file, so it is caught here rather than by writing over the fields that
    /// follow.
    pub fn raw(self: *Props, property: []const u8) void {
        std.debug.assert(self.len < self.items.len);
        self.items[self.len] = property;
        self.len += 1;
    }

    /// Append a formatted property.
    pub fn fmt(self: *Props, comptime format: []const u8, values: anytype) !void {
        const formatted = try std.fmt.bufPrint(self.scratch[self.scratch_len..], format, values);
        self.scratch_len += formatted.len;
        self.raw(formatted);
    }

    pub fn text(self: *Props, key: []const u8, value: []const u8) !void {
        try self.fmt("{s}={s}", .{ key, value });
    }

    pub fn num(self: *Props, key: []const u8, value: anytype) !void {
        try self.fmt("{s}={d}", .{ key, value });
    }

    pub fn color(self: *Props, key: []const u8, value: theme.Color) !void {
        try self.fmt("{s}=0x{x:0>8}", .{ key, value });
    }

    /// The assembled list, suitable for `sb.Client.set`.
    pub fn slice(self: *const Props) []const []const u8 {
        return self.items[0..self.len];
    }
};
