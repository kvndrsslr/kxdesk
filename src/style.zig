//! Presentation the bar's items share: fonts, the badge chip, the popup row,
//! ring and graph geometry, and the semantic colours.
//!
//! Every size and colour an item draws with is stated here once, so a change of
//! look is an edit to this file rather than to each item that draws it.

const std = @import("std");

const config = @import("config.zig");
const theme = @import("theme.zig");

/// The air every item keeps around itself, in points.
pub const item_padding = 4;

/// Every graph's width, in points; equal widths are what keep a pair's windows
/// holding the same stretch of time.
pub const graph_width = 60;

/// Every ring's diameter, in points.
pub const ring_diameter = 20;

/// The height a graph draws in: the background itself is transparent, but a
/// graph without a background height draws across the whole 24-point bar.
pub const graph_height = 20;

/// A graph's line thickness, in points.
pub const graph_line_width = 1;

/// A ring's line thickness, in points.
pub const ring_line_width = 2;

/// The colour a ring's unfilled track is drawn in.
pub const ring_track = config.color(theme.dark_grey);

/// A graph's fill, which is transparent: two graphs share one window, and a
/// fill on either would muddle the two lines.
pub const graph_fill = config.color(theme.graph_no_fill);

/// The visible chip behind a space's label, in points - the height the bar
/// shows.
pub const space_chip_height = 25;

/// The colour a stale or idle mark wears.
pub const dim = theme.dark_grey;

/// Font weights, spelled as SketchyBar's font spec spells them.
pub const Weight = enum { Regular, Bold, SemiBold, ExtraBold, Italic };

/// `JetBrainsMono Nerd Font:<weight>:<size>.0`, at compile time. `inline` so the
/// call is comptime-known inside a `config.node` literal.
pub inline fn mono(comptime weight: Weight, comptime size: u8) []const u8 {
    return std.fmt.comptimePrint("{s}:{s}:{d}.0", .{ theme.font, @tagName(weight), size });
}

/// `sketchybar-app-font:Regular:<size>.0`, at compile time. `inline` for the same
/// reason as `mono`.
pub inline fn app(comptime size: u8) []const u8 {
    return std.fmt.comptimePrint("{s}:Regular:{d}.0", .{ theme.app_font, size });
}

/// The chip behind a badge count: a dynamic box with a point of air on every
/// side, so it hugs the count. Use as `.{ .icon = .{ .badge = style.badge } }`.
pub const badge = .{
    .font = mono(.Bold, 9),
    .anchor = config.Anchors.bottom_right,
    .x_offset = 2,
    .y_offset = -1,
    .background = .{
        .drawing = true,
        .color = config.color(theme.badge_background),
        .width = "dynamic",
        .height = 0,
        .corner_radius = 6,
        .padding_left = 1,
        .padding_right = 1,
    },
};

/// `badge`'s look with a count in it; every field but `value` is `badge`'s, so
/// the chip is stated once. `value` leads because a `config.node` literal emits
/// in field order and the count is the chip's whole text. Write it at the call
/// site as `style.BadgeChip{ .value = count }` — a struct literal, not a call,
/// because the literal has to be comptime-known inside `config.node`.
pub const BadgeChip = struct {
    value: []const u8,
    font: []const u8 = badge.font,
    anchor: config.Anchors = badge.anchor,
    x_offset: i32 = badge.x_offset,
    y_offset: i32 = badge.y_offset,
    background: @TypeOf(badge.background) = badge.background,
};

/// Popup row background, for the GitHub template and the usage rows. Use as
/// `.{ .background = style.popup_row, ... }`.
pub const popup_row = .{
    .corner_radius = 12,
    .padding_left = 7,
    .padding_right = 7,
    .color = config.color(theme.black),
    .drawing = false,
};

/// One graph item: its name, the colour of its line, and whether the newest
/// reading is drawn on it.
pub const Graph = struct {
    name: []const u8,
    color: theme.Color,
    /// The series' newest reading, drawn in the series' own colour in the room
    /// the pair keeps free at the graph's right end. The daemon keeps the value
    /// current; this declares where it goes.
    readout: bool = false,
    /// Whether the reading sits in the top half of the item. The readings of a
    /// pair share one column, so this is what tells them apart on the bar.
    top: bool = false,
    /// Whether the reading keeps a character of air from the graph. The network
    /// pair's five-character rates need it; the load pair's percentages are a
    /// character shorter and read better that character closer.
    air: bool = true,
};

/// A graph item's text slot: `graphSlot` fills one in, and the pair of them is
/// all a graph item declares about text.
pub const Slot = struct {
    drawing: bool,
    value: ?[]const u8,
    padding_left: u32,
    padding_right: u32,
    badge: Badge,
};

/// The badge slot a graph's reading is drawn on.
pub const Badge = struct {
    drawing: bool,
    font: []const u8,
    color: []const u8,
    @"align": []const u8,
    anchor: config.Anchors,
    width: u32,
    x_offset: i32,
    y_offset: i32,
    background: Background,
};

/// The chip behind a reading, of which there is none. It is declared, with
/// `drawing = off`, rather than left out: an item outlives the configuration
/// that set it, so a background an earlier configuration drew has to be turned
/// off by name or it stays on the bar.
pub const Background = struct {
    drawing: bool,
};

const readout_font_size = 9;
/// A reading is at most three digits, one separator and a unit - `12.3K`,
/// `100%` - so five characters; JetBrains Mono sets every glyph six tenths of
/// its size wide.
const readout_chars = 5;
const readout_font = mono(.Bold, readout_font_size);

/// One character of that font, in tenths of a point.
const readout_char_tenths = readout_font_size * 6;

/// The box a reading is right-aligned in, in points: the characters the widest
/// reading of its pair can take, its air, and the point of padding the fork
/// keeps around glyph ink.
///
/// The air belongs inside the box: a right-aligned reading sits a box's width
/// less its own characters from the graph, so a box with a character of air in
/// it holds that character and a box without holds none.
fn readoutBox(comptime air: usize) u32 {
    return (readout_chars + air) * readout_char_tenths / 10 + 1;
}

/// What the graph keeps free on its right for the readings: their box, and a
/// point of air at each end of it. It is the label slot's padding - see
/// `graphSlot` - which is also what makes the item wide enough to draw them in.
fn readoutRoom(comptime air: usize) u32 {
    return readoutBox(air) + 2;
}

/// The air between a reading's end and the edge of the room it is drawn in.
const readout_air = 1;

/// How tall a reading is, and so how far the one in the bottom half of the item
/// is moved down out of the top half: nine-point digits are about this tall.
const readout_height = 8;

/// One of a graph item's two text slots - `icon` tells them apart, `high` is
/// which half of the item its reading sits in. The reading is drawn on the
/// *label* slot: the two items of a pair overlay, so their label slots coincide
/// and the readings line up, and the room the readings need is that slot's
/// `padding_right` (`readoutRoom`) - an item's own padding lies outside the
/// window it draws into, and a slot that is not drawn has no length.
///
/// The anchor cannot say top from bottom: a badge hangs up from its slot's
/// bounds, and an empty slot has no text to have bounds. So the top-half reading
/// sits at the slot's midpoint and the bottom-half one a reading's height below.
pub fn graphSlot(comptime series: Graph, comptime icon: bool, comptime high: bool) Slot {
    const reading = series.readout and !icon;
    const air: usize = if (series.air) 1 else 0;
    return .{
        .drawing = reading,
        .value = null,
        .padding_left = 0,
        .padding_right = if (reading) readoutRoom(air) else 0,
        .badge = .{
            .drawing = reading,
            .font = readout_font,
            .color = config.color(series.color),
            // Right-aligned in a box as wide as the widest reading, so every
            // reading ends on the same point however long it is.
            .@"align" = "right",
            .anchor = config.Anchors.bottom_left,
            .width = readoutBox(air),
            .x_offset = readout_air,
            .y_offset = if (high) 0 else -readout_height,
            .background = .{ .drawing = false },
        },
    };
}
