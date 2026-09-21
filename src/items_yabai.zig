//! Native updater for the space strips and the per-display front-app items:
//! every `yabai_update` becomes one batch, assembled from the yabai space and
//! window queries.
//!
//! A query that fails degrades the update rather than aborting it, and a failure
//! that repeats is reported once. The display map is cached until SketchyBar
//! reports a `display_change`. Application icons come from the installed app
//! font, which publishes its own mapping (see `app_icons.zig`).

const std = @import("std");

const app_icons = @import("app_icons.zig");
const log = @import("log.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");
const yabai = @import("yabai.zig");

/// Window titles longer than this are clipped, ellipsis included.
const max_title = 48;
/// Spaces beyond the number of `space.*` items that exist are ignored.
const max_spaces = 16;

/// A display as SketchyBar sees it.
const SbDisplay = struct {
    DirectDisplayID: u32 = 0,
    @"arrangement-id": u32 = 0,
};

/// The space strips, the front-app items and their status marks, over the
/// daemon's clients.
pub const Updater = struct {
    yabai_client: *yabai.Client,
    bar: *sb.Client,
    scratch: *std.heap.ArenaAllocator,
    /// Application name -> app-font ligature, derived from the installed font.
    icons: *const app_icons.Mapping,
    /// The display map gets its own arena because it outlives the per-update
    /// scratch arena, and is rebuilt only when the displays change.
    displays: std.heap.ArenaAllocator,
    arrangement: ?DisplayMap = null,
    /// Set when a display was missing from the map, so the map is rebuilt before
    /// the next update.
    stale: bool = false,
    /// The last failure reported for each query the updater depends on, cleared
    /// by that query answering again.
    reported: struct { spaces: log.Once = .{}, displays: log.Once = .{} } = .{},

    /// One updater over the daemon's bar client, scratch arena and icon map.
    pub fn init(
        gpa: std.mem.Allocator,
        yabai_client: *yabai.Client,
        bar: *sb.Client,
        scratch: *std.heap.ArenaAllocator,
        icons: *const app_icons.Mapping,
    ) Updater {
        return .{
            .yabai_client = yabai_client,
            .bar = bar,
            .scratch = scratch,
            .icons = icons,
            .displays = std.heap.ArenaAllocator.init(gpa),
        };
    }

    /// Drop the cached display map, for a `display_change`.
    pub fn invalidateDisplays(self: *Updater) void {
        self.arrangement = null;
        _ = self.displays.reset(.retain_capacity);
    }

    /// Refresh every space, `front_app` and `yabai_status` item.
    ///
    /// A failed query degrades rather than taking the update down: yabai refuses
    /// the space and display queries on this machine whenever it cannot place a
    /// display, aborting mid-serialisation with an answer of `[`.
    pub fn update(self: *Updater) !void {
        const arena = self.scratch.allocator();
        defer _ = self.scratch.reset(.retain_capacity);

        var spaces: []yabai.Space = &.{};
        if (self.yabai_client.spaces(arena)) |answered| {
            spaces = answered;
            self.reported.spaces.clear();
        } else |err| {
            report(&self.reported.spaces, err);
        }

        const windows = try self.yabai_client.windows(arena);
        const arrangement = self.displayArrangement() catch |err| blk: {
            report(&self.reported.displays, err);
            break :blk DisplayMap{};
        };

        const layout = try Layout.build(arena, spaces, windows, arrangement, self.icons);
        try self.emitSpaces(layout);
        try self.emitFrontApps(layout, windows);
        try self.bar.commit();

        if (self.stale) self.invalidateDisplays();
    }

    /// Cheap path for `window_title_changed`: only the label of the changed
    /// window's own display moves.
    pub fn updateTitle(self: *Updater, window_id: []const u8) !void {
        const arena = self.scratch.allocator();
        defer _ = self.scratch.reset(.retain_capacity);

        const window = self.yabai_client.window(arena, window_id) catch |err| {
            report(&self.reported.spaces, err);
            return;
        };
        const arrangement = try self.displayArrangement();
        const display = arrangement.get(window.display) orelse {
            self.stale = true;
            return;
        };

        var item_buf: [32]u8 = undefined;
        const item = try std.fmt.bufPrint(&item_buf, "front_app.{d}", .{display});

        var title_buf: [max_title + 3]u8 = undefined;
        var props: Props = .{};
        try props.write(.{ .label = truncateTitle(window.title, &title_buf) });
        try self.bar.set(item, props.slice());
        try self.bar.commit();
    }

    /// Report a failed query once, into the guard for that query: the bar asks
    /// again on every window focus, so the same failure must not be logged every
    /// time.
    fn report(guard: *log.Once, err: anyerror) void {
        const name = @errorName(err);
        var buffer: [96]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "yabai query failed: {s}", .{name}) catch name;
        if (guard.changed(message)) log.warn("{s}", .{message});
    }

    /// The yabai display *index* -> SketchyBar arrangement id map, cached until
    /// the display configuration changes (see `invalidateDisplays`).
    ///
    /// Matching the `CGDirectDisplayID` the two tools both report is exact,
    /// unlike assuming display ids are dense and index-aligned.
    fn displayArrangement(self: *Updater) !DisplayMap {
        if (self.arrangement) |cached| return cached;

        const arena = self.displays.allocator();
        // The whole display list, or the one display that is in focus when yabai
        // refuses to serialise the list: the map only has to place the display a
        // window is on, and that is the focused one for as long as yabai cannot
        // name the others.
        const displays = if (self.yabai_client.displays(arena)) |list| blk: {
            self.reported.displays.clear();
            break :blk list;
        } else |err| blk: {
            report(&self.reported.displays, err);
            break :blk self.yabai_client.query([]yabai.Display, arena, &.{
                "-m", "query", "--displays", "--display",
            }) catch return error.DisplayMapUnavailable;
        };

        const known = self.bar.query([]SbDisplay, arena, "displays") catch |err| {
            log.warn("could not parse '--query displays': {s}", .{@errorName(err)});
            return error.InvalidSketchyBarResponse;
        };

        var map: DisplayMap = .{};
        for (displays) |display| {
            for (known) |candidate| {
                if (candidate.DirectDisplayID != display.id) continue;
                try map.put(arena, display.index, candidate.@"arrangement-id");
                break;
            }
        }

        self.arrangement = map;
        self.stale = false;
        return map;
    }

    fn emitSpaces(self: *Updater, layout: Layout) !void {
        for (layout.spaces, 0..) |space, index| {
            if (space == null) continue;
            if (index == 0 or index > max_spaces) continue;

            const strip = layout.strip(index);
            const visible = space.?.@"is-visible";
            const highlighted = visible and space.?.@"has-focus";
            const background = if (!visible)
                theme.background_1
            else if (highlighted)
                theme.dark_green
            else
                theme.space_visible;

            var name: [24]u8 = undefined;
            const item = try std.fmt.bufPrint(&name, "space.{d}", .{index});

            var props: Props = .{};
            try props.write(.{
                .label = .{
                    .value = strip,
                    .drawing = true,
                    .width = if (strip.len == 0) "0" else "dynamic",
                    .background = .{
                        .color = try props.argb(background),
                        .height = style.space_chip_height,
                        .y_offset = 0,
                    },
                },
                .icon = .{ .highlight = highlighted },
            });
            // One node cannot carry both highlights in the batch's order, so the
            // label's follows the icon's in a node of its own.
            try props.write(.{ .label = .{ .highlight = highlighted } });
            try self.bar.set(item, props.slice());
        }
    }

    fn emitFrontApps(
        self: *Updater,
        layout: Layout,
        windows: []const yabai.Window,
    ) !void {
        for (layout.front_window, 0..) |maybe_window, position| {
            const window_index = maybe_window orelse continue;
            if (position == 0) continue;
            const display_index: u32 = @intCast(position);

            const arrangement = layout.arrangement.get(display_index) orelse {
                // Unknown display: the map no longer describes the world.
                self.stale = true;
                continue;
            };
            const window = windows[window_index];
            const mark = markFor(layout.space_of(window.space), window);

            var title_buf: [max_title + 3]u8 = undefined;
            var stack_buf: [32]u8 = undefined;

            var front: Props = .{};
            try front.write(.{
                .icon = window.app,
                .label = truncateTitle(window.title, &title_buf),
            });

            const stack: ?[]const u8 = if (window.@"stack-index" > 0)
                try std.fmt.bufPrint(&stack_buf, "[{d}/{d}]", .{
                    window.@"stack-index",
                    layout.max_stack_of(window.space),
                })
            else
                null;

            var status: Props = .{};
            try status.write(.{
                .icon = .{ .value = mark.icon, .color = try status.argb(mark.color) },
                .label = .{ .value = stack, .drawing = stack != null },
            });

            var name: [32]u8 = undefined;
            const front_item = try std.fmt.bufPrint(&name, "front_app.{d}", .{arrangement});
            try self.bar.set(front_item, front.slice());
            const status_item = try std.fmt.bufPrint(&name, "yabai_status.{d}", .{arrangement});
            try self.bar.set(status_item, status.slice());
        }
    }
};

/// What one window's status item draws.
const Mark = struct { icon: []const u8, color: theme.Color };

/// The status mark for one window: the space's window layout first - a stack or a
/// float - then the window's own floating and zoom state.
fn markFor(space: ?yabai.Space, window: yabai.Window) Mark {
    var mark: Mark = .{ .icon = theme.glyph.yabai_grid, .color = theme.orange };
    if (space != null and std.mem.eql(u8, space.?.type, "stack")) {
        mark = .{ .icon = theme.glyph.yabai_stack, .color = theme.aqua };
    }
    if ((space != null and std.mem.eql(u8, space.?.type, "float")) or window.@"is-floating") {
        mark = .{ .icon = theme.glyph.yabai_float, .color = theme.magenta };
    } else if (window.@"has-fullscreen-zoom") {
        mark = .{ .icon = theme.glyph.yabai_fullscreen_zoom, .color = theme.green };
    } else if (window.@"has-parent-zoom") {
        mark = .{ .icon = theme.glyph.yabai_parent_zoom, .color = theme.blue };
    } else if (space != null and std.mem.eql(u8, space.?.type, "bsp")) {
        mark = .{ .icon = theme.glyph.yabai_grid, .color = theme.orange };
    }
    return mark;
}

/// yabai display index -> SketchyBar arrangement id.
const DisplayMap = struct {
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { index: u32, arrangement: u32 };

    fn put(self: *DisplayMap, arena: std.mem.Allocator, index: u32, arrangement: u32) !void {
        for (self.entries.items) |*entry| {
            if (entry.index == index) {
                entry.arrangement = arrangement;
                return;
            }
        }
        try self.entries.append(arena, .{ .index = index, .arrangement = arrangement });
    }

    fn get(self: DisplayMap, index: u32) ?u32 {
        for (self.entries.items) |entry| {
            if (entry.index == index) return entry.arrangement;
        }
        return null;
    }
};

/// Derived per-space state: which windows are on which space and what each space
/// strip renders as.
const Layout = struct {
    /// Window order per space, as yabai reports it: the first entry is rendered
    /// as the strip's head icon, the rest trail it.
    strips: [][]const u8,
    spaces: []?yabai.Space,
    /// First window of each visible space, keyed by display index.
    front_window: []?usize,
    arrangement: DisplayMap,
    /// Highest `stack-index` in use per space.
    max_stack: []u32,

    fn build(
        arena: std.mem.Allocator,
        spaces: []const yabai.Space,
        windows: []const yabai.Window,
        arrangement: DisplayMap,
        app_icon_map: *const app_icons.Mapping,
    ) !Layout {
        // Sized from the windows as well as the spaces: the space query can fail
        // while the window query answers, and the stack totals come from windows.
        var space_count: usize = 0;
        for (spaces) |space| space_count = @max(space_count, space.index);
        for (windows) |window| space_count = @max(space_count, window.space);
        var display_count: usize = 0;
        for (spaces) |space| display_count = @max(display_count, space.display);
        for (windows) |window| display_count = @max(display_count, window.display);

        var layout: Layout = .{
            .strips = try arena.alloc([]const u8, space_count + 1),
            .spaces = try arena.alloc(?yabai.Space, space_count + 1),
            .front_window = try arena.alloc(?usize, display_count + 1),
            .arrangement = arrangement,
            .max_stack = try arena.alloc(u32, space_count + 1),
        };
        @memset(layout.strips, "");
        @memset(layout.spaces, null);
        @memset(layout.front_window, null);
        @memset(layout.max_stack, 0);

        // Space lookup is by index, and every window's space must be reflected
        // even past `max_spaces`, so that no strip silently loses a window.
        for (spaces) |space| {
            if (space.index < layout.spaces.len) layout.spaces[space.index] = space;
        }
        for (windows) |window| {
            if (window.space < layout.max_stack.len) {
                layout.max_stack[window.space] =
                    @max(layout.max_stack[window.space], window.@"stack-index");
            }
        }

        // A sticky window belongs to whichever space is active on its display.
        var active_space = try arena.alloc(u32, display_count + 1);
        @memset(active_space, 0);
        for (spaces) |space| {
            if (!space.@"is-visible") continue;
            if (space.display < active_space.len) active_space[space.display] = space.index;
        }

        var head = try arena.alloc(?[]const u8, space_count + 1);
        @memset(head, null);
        var tail = try arena.alloc([]const u8, space_count + 1);
        @memset(tail, "");

        for (windows, 0..) |window, index| {
            if (!std.mem.eql(u8, window.role, "AXWindow")) continue;
            if (window.@"is-minimized" or window.@"is-hidden") continue;

            const space_index = if (window.@"is-sticky")
                (if (window.display < active_space.len) active_space[window.display] else 0)
            else
                window.space;
            if (space_index == 0 or space_index >= head.len) continue;

            const icon = app_icon_map.lookup(window.app).ligature;
            if (head[space_index] == null) {
                head[space_index] = icon;
                if (layout.space_of(space_index)) |space| {
                    if (space.@"is-visible" and space.display < layout.front_window.len) {
                        layout.front_window[space.display] = index;
                    }
                }
            } else {
                tail[space_index] = try std.fmt.allocPrint(arena, " {s}{s}", .{
                    icon,
                    tail[space_index],
                });
            }
        }

        for (layout.strips, 0..) |*rendered, index| {
            if (head[index]) |value| {
                rendered.* = if (index < tail.len and tail[index].len > 0)
                    try std.fmt.allocPrint(arena, "{s}{s}", .{ value, tail[index] })
                else
                    value;
            }
        }

        // The space query failing is why this runs, so visibility is unknown: the
        // focused window places the display that has focus.
        for (windows, 0..) |window, index| {
            if (!window.@"has-focus") continue;
            if (!std.mem.eql(u8, window.role, "AXWindow")) continue;
            if (window.@"is-minimized" or window.@"is-hidden") continue;
            if (window.display == 0 or window.display >= layout.front_window.len) continue;

            if (layout.front_window[window.display] == null) {
                layout.front_window[window.display] = index;
            }
        }

        return layout;
    }

    fn strip(self: Layout, index: usize) []const u8 {
        if (index >= self.strips.len) return "";
        return self.strips[index];
    }

    fn space_of(self: Layout, index: u32) ?yabai.Space {
        if (index >= self.spaces.len) return null;
        return self.spaces[index];
    }

    fn max_stack_of(self: Layout, index: u32) u32 {
        if (index >= self.max_stack.len) return 0;
        return self.max_stack[index];
    }
};

/// Clip a window title to `max_title` characters, appending an ellipsis.
fn truncateTitle(title: []const u8, buffer: []u8) []const u8 {
    const view = std.unicode.Utf8View.init(title) catch return title;

    var count: usize = 0;
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |_| count += 1;
    if (count <= max_title) return title;

    iterator = view.iterator();
    var end: usize = 0;
    var kept: usize = 0;
    while (kept < max_title - 3) : (kept += 1) {
        const slice = iterator.nextCodepointSlice() orelse break;
        end += slice.len;
    }
    return std.fmt.bufPrint(buffer, "{s}...", .{title[0..end]}) catch title;
}
