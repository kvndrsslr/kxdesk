//! Comptime SketchyBar layer: `node` compiles a nested struct literal into the
//! flat `key=value` arguments of one `--set`, and the command words below
//! declare the items that configuration describes.
//!
//!     const bell = config.node(.{
//!         .drawing = true,
//!         .icon = .{ .font = "JetBrainsMono Nerd Font:Bold:15.0", .badge = .{ .anchor = config.Anchors.bottom_right } },
//!     });
//!
//! Leaves are typed: strings go verbatim, `bool` is `on`/`off`, integers are
//! decimal - a float leaf is refused, this side takes comptime values only -
//! enums are their tag (`Anchors`), `color(...)` is `0xAARRGGBB`, and a `null`
//! leaf emits `key=`, which is how SketchyBar clears a property. A nested
//! struct is a node: its name joins the dotted key path. Everything is baked at
//! compile time into one static NUL-separated string - the shape `sb.Client`
//! ships.

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

/// SketchyBar item kinds; tags are `--add`'s own spellings.
pub const Kind = enum { item, space, graph, ring, event, alias };

/// Events an item can be subscribed to; tags are SketchyBar's spellings.
pub const Event = enum {
    @"mouse.clicked",
    @"mouse.entered",
    @"mouse.exited",
    @"mouse.exited.global",
    battery,
    system_woke,
    power_source_change,
    brew_update,
    yabai_update,
    display_change,
};

/// Render a theme colour the way SketchyBar spells it - `0xAARRGGBB` - baked
/// at compile time.
pub inline fn color(value: theme.Color) []const u8 {
    return std.fmt.comptimePrint("0x{x:0>8}", .{value});
}

/// `key=value` arguments, concatenated at compile time into one contiguous,
/// NUL-separated string - the same layout a SketchyBar batch uses.
pub const Script = struct {
    args: []const u8,

    /// Queue the compiled arguments into the current command, one per
    /// SketchyBar argument; for a command word like `--bar` or `--default`
    /// whose properties are bare `key=value` pairs.
    pub fn queue(self: Script, client: *sb.Client) !void {
        var it = std.mem.splitScalar(u8, self.args, 0);
        while (it.next()) |arg| {
            if (arg.len == 0) continue;
            try client.arg(arg);
        }
    }

    /// Queue `--set <item>` with every property the node flattened to, clearing
    /// `script=` and `click_script=` first. An item outlives the configuration
    /// that configured it, so a reload must clear both or an earlier
    /// configuration's script keeps running; a real `click_script` follows and
    /// overwrites the clear.
    pub fn apply(self: Script, client: *sb.Client, item: []const u8) !void {
        try client.arg("--set");
        try client.arg(item);
        try client.arg("script=");
        try client.arg("click_script=");
        try self.queue(client);
    }
};

/// One `--add <kind> <name> <position> [<width>]`; an event takes no position
/// and no width.
pub fn add(c: *sb.Client, kind: Kind, name: []const u8, position: []const u8, width: ?u32) !void {
    try c.arg("--add");
    try c.arg(@tagName(kind));
    try c.arg(name);
    if (kind == .event) return;
    try c.arg(position);
    if (width) |points| {
        var buffer: [16]u8 = undefined;
        try c.arg(try std.fmt.bufPrint(&buffer, "{d}", .{points}));
    }
}

/// One `--subscribe <name> <events...>`; emits nothing for an empty list.
pub fn subscribe(c: *sb.Client, name: []const u8, events: []const Event) !void {
    if (events.len == 0) return;
    try c.arg("--subscribe");
    try c.arg(name);
    for (events) |event| try c.arg(@tagName(event));
}

/// `--move <item> before <anchor>`.
pub fn move(c: *sb.Client, item: []const u8, anchor: []const u8) !void {
    try c.arg("--move");
    try c.arg(item);
    try c.arg("before");
    try c.arg(anchor);
}

/// `--remove <pattern>`.
pub fn remove(c: *sb.Client, pattern: []const u8) !void {
    try c.arg("--remove");
    try c.arg(pattern);
}

/// One bar item, complete: what to add, how it looks, where its events go.
pub const Item = struct {
    kind: Kind = .item,
    name: []const u8,
    /// `left`/`right`, or the item a popup row hangs under.
    position: []const u8 = "right",
    /// The `--add` width argument, for graphs and rings.
    width: ?u32 = null,
    /// The item's properties, one `--set`.
    props: ?Script = null,
    /// Whether the item carries `mach_helper`, routing its events to the daemon.
    helper: bool = false,
    /// The one click handler an item carries, for an item whose clicks the bar
    /// itself answers; emitted after the props' clears, so it wins.
    click_script: ?[]const u8 = null,
    events: []const Event = &.{},
};

/// Declare one item: `--add`, its `--set`, and its `--subscribe`; a `.event`
/// item is only the `--add`.
pub fn declare(c: *sb.Client, item: Item, helper: []const u8) !void {
    if (item.kind == .event) return add(c, item.kind, item.name, item.position, item.width);
    try add(c, item.kind, item.name, item.position, item.width);
    if (item.props) |props| try props.apply(c, item.name);
    if (item.helper) try c.prop("mach_helper", helper);
    if (item.click_script) |click_script| try c.prop("click_script", click_script);
    try subscribe(c, item.name, item.events);
}

/// A plain struct leaf is a node: its fields descend, its name joins the dotted
/// key path.
pub fn isNode(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

/// A leaf or field named `value` collapses to its parent's key, so
/// `.{ .label = .{ .value = null } }` clears `label`.
pub fn isValue(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "value");
}

/// The dotted key of `name` under `prefix`: `key("", "icon") == "icon"`,
/// `key("icon", "color") == "icon.color"`, and `key("icon.badge", "value") ==
/// "icon.badge"`.
pub fn key(comptime prefix: []const u8, comptime name: []const u8) []const u8 {
    if (isValue(name)) return prefix;
    if (prefix.len == 0) return name;
    return prefix ++ "." ++ name;
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
        // A `null` leaf still writes its `key=`, so it costs nothing here.
        .null => 0,
        else => @compileError("config: unsupported leaf type " ++ @typeName(T)),
    };
}

/// Total bytes of the compiled script: one `key=value\0` per leaf, in field
/// order, structs descended depth-first.
fn scriptSize(comptime n: anytype, comptime prefix: []const u8) usize {
    var total: usize = 0;
    inline for (std.meta.fields(@TypeOf(n))) |field| {
        const value = @field(n, field.name);
        if (isNode(@TypeOf(value))) {
            total += scriptSize(value, key(prefix, field.name));
        } else {
            total += key(prefix, field.name).len + 1 + valueLen(value) + 1;
        }
    }
    return total;
}

fn append(comptime out: []u8, comptime pos: *usize, comptime bytes: []const u8) void {
    @memcpy(out[pos.* .. pos.* + bytes.len], bytes);
    pos.* += bytes.len;
}

/// Write a leaf's value - the part after `key=`.
fn emitValue(comptime out: []u8, comptime pos: *usize, comptime value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .bool => append(out, pos, if (value) "on" else "off"),
        .int, .comptime_int => append(out, pos, std.fmt.comptimePrint("{d}", .{value})),
        .@"enum" => append(out, pos, @tagName(value)),
        .enum_literal => append(out, pos, @tagName(value)),
        .pointer => append(out, pos, @as([]const u8, value)),
        .array => append(out, pos, &value),
        .optional => if (value) |inner| emitValue(out, pos, inner),
        .null => {},
        else => @compileError("config: unsupported leaf type " ++ @typeName(@TypeOf(value))),
    }
}

/// Write one leaf as `key=value` (no trailing NUL; the caller adds it).
fn emitLeaf(
    comptime out: []u8,
    comptime pos: *usize,
    comptime prefix: []const u8,
    comptime name: []const u8,
    comptime value: anytype,
) void {
    append(out, pos, key(prefix, name));
    append(out, pos, "=");
    emitValue(out, pos, value);
}

/// Recursively write the compiled script into `out`.
fn emit(
    comptime out: []u8,
    comptime pos: *usize,
    comptime n: anytype,
    comptime prefix: []const u8,
) void {
    inline for (std.meta.fields(@TypeOf(n))) |field| {
        const value = @field(n, field.name);
        if (isNode(@TypeOf(value))) {
            emit(out, pos, value, key(prefix, field.name));
        } else {
            emitLeaf(out, pos, prefix, field.name, value);
            out[pos.*] = 0;
            pos.* += 1;
        }
    }
}

/// Compile a configuration node into a `Script` of flat `key=value`
/// arguments, with no runtime formatting or concatenation.
pub fn node(config: anytype) Script {
    @setEvalBranchQuota(100_000);
    const args = comptime blk: {
        const total = scriptSize(config, "");
        var storage: [total]u8 = undefined;
        var pos: usize = 0;
        emit(&storage, &pos, config, "");
        if (pos != total) @compileError("config: internal size mismatch");
        // Copy the filled buffer into a const and hand out a pointer to that:
        // the same trick `std.fmt.comptimePrint` uses to embed comptime
        // strings in the binary, instead of a pointer into a comptime var.
        const final = storage;
        break :blk &final;
    };
    return .{ .args = args };
}
