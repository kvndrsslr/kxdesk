//! Compile-time SketchyBar configuration.
//!
//! A chunk of bar configuration is written as a nested Zig struct literal -
//!
//!     const bell = config.node(.{
//!         .drawing = true,
//!         .icon = .{
//!             .font = "JetBrainsMono Nerd Font:Bold:15.0",
//!             .badge = .{
//!                 .anchor = Anchors.bottom_right,
//!                 .x_offset = 2,
//!                 .background = .{
//!                     .drawing = true,
//!                     .color = config.color(theme.green),
//!                     .corner_radius = 6,
//!                 },
//!             },
//!         },
//!     });
//!
//! and `config.node` flattens it, entirely at compile time, into the flat
//! `key=value` arguments SketchyBar consumes -
//! `icon.badge.anchor=bottom_right`, `icon.badge.background.color=0xffb8bb27`,
//! ... - concatenated into one static, NUL-separated string. No allocation,
//! formatting or joining happens at runtime: the exact bytes the compiler
//! produced are the ones that go out.
//!
//! Leaves are typed. `[]const u8` and string literals are emitted verbatim;
//! `bool` becomes `on`/`off` (SketchyBar spells booleans that way); integers
//! become decimal; enums become their tag (use `Anchors`, whose tags are the
//! fork's own anchor spellings); and `color(...)` renders a theme colour as
//! `0xAARRGGBB`. An optional leaf whose value is `null` emits `key=` - the
//! empty-string assignment SketchyBar uses to clear a property that outlives
//! the configuration. A field whose value is itself a struct is a node: its
//! name joins the dotted path and the recursion descends.
//!
//! The compiled `Script` is the same shape `sb.Client` already ships, so a
//! node is applied to the bar with `config.apply(client, item, script)`.

const std = @import("std");

const sb = @import("sb.zig");
const theme = @import("theme.zig");

/// SketchyBar's badge anchors, named after the strings the local fork parses.
pub const Anchors = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

/// Render a theme colour the way SketchyBar spells it - `0xAARRGGBB`.
///
/// The value must be comptime-known (a theme constant, or a literal): the hex
/// string is baked at compile time, so this can only appear in a comptime
/// context such as a `config.node(...)` argument.
pub inline fn color(value: theme.Color) []const u8 {
    return std.fmt.comptimePrint("0x{x:0>8}", .{value});
}

/// `key=value` arguments, concatenated at compile time into one contiguous,
/// NUL-separated string - the same layout a SketchyBar batch uses.
pub const Script = struct {
    args: []const u8,

    /// Queue the compiled arguments into the current command, one per
    /// SketchyBar argument. Used after a command word like `--bar` or
    /// `--default` whose properties are bare `key=value` pairs.
    pub fn queue(self: Script, client: *sb.Client) !void {
        var it = std.mem.splitScalar(u8, self.args, 0);
        while (it.next()) |arg| {
            if (arg.len == 0) continue;
            try client.arg(arg);
        }
    }

    /// Queue `--set <item>` with every property the node flattened to, so a
    /// declared config applies with one message like any other update. Any
    /// runtime-only property, such as `mach_helper`, follows with the client's
    /// own `prop` and still lands in the same `--set`.
    pub fn apply(self: Script, client: *sb.Client, item: []const u8) !void {
        try client.arg("--set");
        try client.arg(item);
        try self.queue(client);
    }
};

/// The value of a config node is itself a node - a nested struct - and every
/// other field type is a leaf.
fn isNode(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

/// A leaf named `value` stands for the property its parent names themself:
/// `.{ .label = .{ .value = null } }` is `label=` and `.{ .label = .{ .value
/// = "ok" } }` is `label=ok` - the empty-string assignment SketchyBar uses to
/// clear an item state, and the ordinary assignment where the value is the
/// whole property. The fork's own `badge.value` reads the same way.
fn isValue(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "value");
}

/// The key a leaf is written under: the dotted path of its ancestors, and its
/// own name - unless the leaf is named `value`, in which case the ancestors'
/// path alone is the key.
fn keyOf(comptime prefix: []const []const u8, comptime name: []const u8) []const []const u8 {
    if (isValue(name)) return prefix;
    return prefix ++ [1][]const u8{name};
}

/// Length of the dotted key, dots between segments included.
fn keyLen(comptime prefix: []const []const u8, comptime name: []const u8) usize {
    const parts = keyOf(prefix, name);
    var total: usize = 0;
    for (parts, 0..) |part, index| {
        total += part.len;
        if (index + 1 < parts.len) total += 1;
    }
    return total;
}

/// How many bytes a leaf's rendered value occupies.
fn valueLen(comptime value: anytype) usize {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .bool => if (value) 2 else 3, // "on" / "off"
        .int, .comptime_int => blk: {
            const digits = std.fmt.comptimePrint("{d}", .{value});
            break :blk digits.len;
        },
        .@"enum" => @tagName(value).len,
        .enum_literal => @tagName(value).len,
        .pointer => blk: {
            const bytes: []const u8 = value;
            break :blk bytes.len;
        },
        .array => blk: {
            const bytes: []const u8 = &value;
            break :blk bytes.len;
        },
        .optional => if (value) |inner| valueLen(inner) else 0,
        // `.{ .key = null }` - the null type - means "clear this property":
        // the key still gets its `=`, and nothing after it.
        .@"null" => 0,
        else => @compileError("config: unsupported leaf type " ++ @typeName(T)),
    };
}

/// Total bytes of the compiled script: one `key=value\0` per leaf, in field
/// order, structs descended depth-first.
fn scriptSize(comptime n: anytype, comptime prefix: []const []const u8) usize {
    var total: usize = 0;
    inline for (std.meta.fields(@TypeOf(n))) |field| {
        const value = @field(n, field.name);
        if (isNode(@TypeOf(value))) {
            const path = prefix ++ [1][]const u8{field.name};
            total += scriptSize(value, path);
        } else {
            total += keyLen(prefix, field.name) + 1 + valueLen(value) + 1;
        }
    }
    return total;
}

fn append(comptime out: []u8, comptime pos: *usize, comptime bytes: []const u8) void {
    @memcpy(out[pos.* .. pos.* + bytes.len], bytes);
    pos.* += bytes.len;
}

/// Write a leaf's value - the part after `prefix.name=`.
fn emitValue(comptime out: []u8, comptime pos: *usize, comptime value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => append(out, pos, if (value) "on" else "off"),
        .int, .comptime_int => append(out, pos, std.fmt.comptimePrint("{d}", .{value})),
        .@"enum" => append(out, pos, @tagName(value)),
        .enum_literal => append(out, pos, @tagName(value)),
        .pointer => append(out, pos, @as([]const u8, value)),
        .array => append(out, pos, &value),
        .optional => if (value) |inner| emitValue(out, pos, inner),
        .@"null" => {},
        else => @compileError("config: unsupported leaf type " ++ @typeName(@TypeOf(value))),
    }
}

/// Write one leaf as `key=value` (no trailing NUL; the caller adds it).
fn emitLeaf(
    comptime out: []u8,
    comptime pos: *usize,
    comptime prefix: []const []const u8,
    comptime name: []const u8,
    comptime value: anytype,
) void {
    const parts = keyOf(prefix, name);
    for (parts, 0..) |part, index| {
        append(out, pos, part);
        if (index + 1 < parts.len) append(out, pos, ".");
    }
    append(out, pos, "=");
    emitValue(out, pos, value);
}

/// Recursively write the compiled script into `out`.
fn emit(
    comptime out: []u8,
    comptime pos: *usize,
    comptime n: anytype,
    comptime prefix: []const []const u8,
) void {
    inline for (std.meta.fields(@TypeOf(n))) |field| {
        const value = @field(n, field.name);
        if (isNode(@TypeOf(value))) {
            const path = prefix ++ [1][]const u8{field.name};
            emit(out, pos, value, path);
        } else {
            emitLeaf(out, pos, prefix, field.name, value);
            out[pos.*] = 0;
            pos.* += 1;
        }
    }
}

/// Compile a configuration node into a `Script` of flat `key=value`
/// arguments. Everything - the dotted paths, the value formatting, the
/// concatenation - happens during compilation.
pub fn node(config: anytype) Script {
    @setEvalBranchQuota(100_000);
    const args = comptime blk: {
        const total = scriptSize(config, &.{});
        var storage: [total]u8 = undefined;
        var pos: usize = 0;
        emit(&storage, &pos, config, &.{});
        if (pos != total) @compileError("config: internal size mismatch");
        // Copy the filled buffer into a const and hand out a pointer to that:
        // the same trick `std.fmt.comptimePrint` uses to embed comptime
        // strings in the binary, instead of a pointer into a comptime var.
        const final = storage;
        break :blk &final;
    };
    return .{ .args = args };
}
