//! Runtime `key=value` properties for one SketchyBar `--set`.
//!
//! Fixed scratch buffer, fixed item slots: assembling a list never allocates,
//! and `slice` hands the list straight to `sb.Client.set`. `write` mirrors
//! `config.node`'s nested-struct flattening for values known only at runtime,
//! so the dotted-key semantics live in `config` alone.

const std = @import("std");

const config = @import("config.zig");
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
        self.raw(try self.fmtValue(format, values));
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

    /// `value` as the `0xAARRGGBB` string SketchyBar spells colours with,
    /// written into the scratch so the slice lives as long as the list.
    pub fn argb(self: *Props, value: theme.Color) ![]const u8 {
        return self.fmtValue("0x{x:0>8}", .{value});
    }

    /// Write a nested node as `key=value` properties, the runtime counterpart
    /// of `config.node`: field names become dotted keys, nested structs
    /// descend, a field named `value` collapses to its parent's key, and
    /// `null` clears.
    pub fn write(self: *Props, node: anytype) !void {
        @setEvalBranchQuota(10_000);
        try self.emit("", node);
    }

    /// Descend one node, key path threaded as a comptime string because
    /// `config.key` needs comptime-known prefixes; the values stay runtime.
    fn emit(self: *Props, comptime prefix: []const u8, node: anytype) !void {
        @setEvalBranchQuota(10_000);
        inline for (std.meta.fields(@TypeOf(node))) |field| {
            const value = @field(node, field.name);
            if (comptime config.isNode(@TypeOf(value))) {
                try self.emit(config.key(prefix, field.name), value);
            } else {
                try self.emitLeaf(config.key(prefix, field.name), value);
            }
        }
    }

    /// One leaf as a single `key=value` scratch slice; a `null` leaf emits the
    /// bare `key=` SketchyBar reads as a clear.
    fn emitLeaf(self: *Props, comptime key: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        switch (comptime @typeInfo(T)) {
            .null => self.raw(try self.fmtValue("{s}=", .{key})),
            .optional => if (value) |inner| {
                try self.emitLeaf(key, inner);
            } else {
                self.raw(try self.fmtValue("{s}=", .{key}));
            },
            .bool => self.raw(try self.fmtValue("{s}={s}", .{ key, if (value) "on" else "off" })),
            .int, .comptime_int => self.raw(try self.fmtValue("{s}={d}", .{ key, value })),
            .float, .comptime_float => self.raw(try self.fmtValue("{s}={d:.4}", .{ key, value })),
            .@"enum", .enum_literal => self.raw(try self.fmtValue("{s}={s}", .{ key, @tagName(value) })),
            .pointer => |p| {
                const bytes: []const u8 = switch (comptime p.size) {
                    .slice => blk: {
                        if (p.child != u8) @compileError("props: unsupported leaf type " ++ @typeName(T));
                        break :blk value;
                    },
                    .one => blk: {
                        const child = @typeInfo(p.child);
                        if (child != .array or child.array.child != u8)
                            @compileError("props: unsupported leaf type " ++ @typeName(T));
                        break :blk value;
                    },
                    else => @compileError("props: unsupported leaf type " ++ @typeName(T)),
                };
                self.raw(try self.fmtValue("{s}={s}", .{ key, bytes }));
            },
            else => @compileError("props: unsupported leaf type " ++ @typeName(T)),
        }
    }

    /// Format into the scratch and return the slice; the scratch advances, so
    /// every returned slice lives as long as the assembled list.
    fn fmtValue(self: *Props, comptime format: []const u8, values: anytype) ![]const u8 {
        const formatted = try std.fmt.bufPrint(self.scratch[self.scratch_len..], format, values);
        self.scratch_len += formatted.len;
        return formatted;
    }

    /// The assembled list, suitable for `sb.Client.set`.
    pub fn slice(self: *const Props) []const []const u8 {
        return self.items[0..self.len];
    }
};
