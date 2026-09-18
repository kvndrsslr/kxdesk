//! Native updater for the space strips and the per-display front-app items.
//!
//! One `yabai_update` event becomes one mach message. The shell version this
//! replaces forked `yabai`, `jq` and `sketchybar` several times per event, and
//! re-queried yabai once per stacked window; here every answer comes from the two
//! queries already in hand. Application icons come from the installed app font,
//! which publishes its own mapping (see `app_icons.zig`).

const std = @import("std");

const app_icons = @import("app_icons.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const theme = @import("theme.zig");
const yabai = @import("yabai.zig");

/// Window titles longer than this are clipped, ellipsis included.
const max_title = 48;
/// Spaces beyond the number of `space.*` items that exist are ignored.
const max_spaces = 16;

/// A display as SketchyBar sees it.
const SbDisplay = struct {
    @"DirectDisplayID": u32 = 0,
    @"arrangement-id": u32 = 0,
};

pub const Updater = struct {
    yabai_client: *yabai.Client,
    bar: *sb.Client,
    scratch: *std.heap.ArenaAllocator,
    /// Reused buffer for SketchyBar's `--query displays` response.
    response: []u8,
    /// Application name -> app-font ligature, derived from the installed font.
    icons: *const app_icons.Mapping,
    /// The display map gets its own arena because it outlives the per-update
    /// scratch arena, and is rebuilt only when the displays change.
    displays: std.heap.ArenaAllocator,
    arrangement: ?DisplayMap = null,
    /// Set when a display turned out to be missing from the map, which means it
    /// went stale and has to be rebuilt before the next update.
    stale: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        yabai_client: *yabai.Client,
        bar: *sb.Client,
        scratch: *std.heap.ArenaAllocator,
        response: []u8,
        icons: *const app_icons.Mapping,
    ) Updater {
        return .{
            .yabai_client = yabai_client,
            .bar = bar,
            .scratch = scratch,
            .response = response,
            .icons = icons,
            .displays = std.heap.ArenaAllocator.init(gpa),
        };
    }

    /// Drop the cached display map. Called when SketchyBar reports that the
    /// display configuration changed.
    pub fn invalidateDisplays(self: *Updater) void {
        self.arrangement = null;
        _ = self.displays.reset(.retain_capacity);
    }

    /// Refresh every space, `front_app` and `yabai_status` item.
    pub fn update(self: *Updater) !void {
        const arena = self.scratch.allocator();
        defer _ = self.scratch.reset(.retain_capacity);

        const spaces = try self.yabai_client.spaces(arena);
        const windows = try self.yabai_client.windows(arena);
        const arrangement = try self.displayArrangement();

        const layout = try Layout.build(arena, spaces, windows, arrangement, self.icons);
        try self.emitSpaces(layout);
        try self.emitFrontApps(layout, windows);
        try self.bar.commit();

        if (self.stale) self.invalidateDisplays();
    }

    /// Cheap path for `window_title_changed`: only the label of the front-app
    /// item belonging to the changed window's display moves.
    pub fn updateTitle(self: *Updater, window_id: []const u8) !void {
        const arena = self.scratch.allocator();
        defer _ = self.scratch.reset(.retain_capacity);

        const window = self.yabai_client.window(arena, window_id) catch return;
        const arrangement = try self.displayArrangement();
        const display = arrangement.get(window.display) orelse {
            self.stale = true;
            return;
        };

        var item_buf: [32]u8 = undefined;
        const item = try std.fmt.bufPrint(&item_buf, "front_app.{d}", .{display});

        var title_buf: [max_title + 3]u8 = undefined;
        var props: Props = .{};
        try props.text("label", truncateTitle(window.title, &title_buf));
        try self.bar.set(item, props.slice());
        try self.bar.commit();
    }

    /// Map a yabai display *index* to the SketchyBar arrangement id used by
    /// `front_app.N` items and `associated_display=N`.
    ///
    /// The yabai display id is a `CGDirectDisplayID`, which is what SketchyBar
    /// reports as `DirectDisplayID`; matching on that is exact, unlike the shell
    /// version's assumption that display ids are dense and index-aligned.
    ///
    /// The result is cached: it only changes when the display configuration
    /// does, and this runs on every window focus and every window title change,
    /// where a second round trip is pure latency. `--subscribe` on
    /// `display_change` tells us when to throw it away.
    fn displayArrangement(self: *Updater) !DisplayMap {
        if (self.arrangement) |cached| return cached;

        const arena = self.displays.allocator();
        const displays = try self.yabai_client.displays(arena);

        // The query must be the only command in flight, so start from a clean
        // batch: callers run this before queueing updates.
        self.bar.clear();
        try self.bar.arg("--query");
        try self.bar.arg("displays");
        const response = try self.bar.commitInto(self.response);

        const known = std.json.parseFromSliceLeaky([]SbDisplay, arena, response, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_if_needed,
        }) catch |err| {
            std.debug.print("kxdesk: could not parse '--query displays': {s}\n", .{
                @errorName(err),
            });
            return error.InvalidSketchyBarResponse;
        };

        var map: DisplayMap = .{};
        for (displays) |display| {
            for (known) |candidate| {
                if (candidate.@"DirectDisplayID" != display.id) continue;
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
            try props.text("label", strip);
            props.raw("label.drawing=on");
            try props.text("label.width", if (strip.len == 0) "0" else "dynamic");
            try props.color("label.background.color", background);
            try props.num("label.background.height", 25);
            try props.num("label.background.y_offset", 0);
            props.raw(if (highlighted) "icon.highlight=on" else "icon.highlight=off");
            props.raw(if (highlighted) "label.highlight=on" else "label.highlight=off");
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
            const space = layout.space_of(window.space);

            var icon: []const u8 = theme.glyph.yabai_grid;
            var icon_color: theme.Color = theme.orange;
            if (space != null and std.mem.eql(u8, space.?.@"type", "stack")) {
                icon = theme.glyph.yabai_stack;
                icon_color = theme.aqua;
            }
            if ((space != null and std.mem.eql(u8, space.?.@"type", "float")) or window.@"is-floating") {
                icon = theme.glyph.yabai_float;
                icon_color = theme.magenta;
            } else if (window.@"has-fullscreen-zoom") {
                icon = theme.glyph.yabai_fullscreen_zoom;
                icon_color = theme.green;
            } else if (window.@"has-parent-zoom") {
                icon = theme.glyph.yabai_parent_zoom;
                icon_color = theme.blue;
            } else if (space != null and std.mem.eql(u8, space.?.@"type", "bsp")) {
                icon = theme.glyph.yabai_grid;
                icon_color = theme.orange;
            }

            var title_buf: [max_title + 3]u8 = undefined;
            var stack_buf: [32]u8 = undefined;

            var front: Props = .{};
            try front.text("icon", window.app);
            try front.text("label", truncateTitle(window.title, &title_buf));
            var status: Props = .{};
            try status.text("icon", icon);
            try status.color("icon.color", icon_color);

            if (window.@"stack-index" > 0) {
                const total = layout.max_stack_of(window.space);
                try status.text(
                    "label",
                    try std.fmt.bufPrint(&stack_buf, "[{d}/{d}]", .{
                        window.@"stack-index",
                        total,
                    }),
                );
                status.raw("label.drawing=on");
            } else {
                status.raw("label=");
                status.raw("label.drawing=off");
            }

            var name: [32]u8 = undefined;
            const front_item = try std.fmt.bufPrint(&name, "front_app.{d}", .{arrangement});
            try self.bar.set(front_item, front.slice());
            const status_item = try std.fmt.bufPrint(&name, "yabai_status.{d}", .{arrangement});
            try self.bar.set(status_item, status.slice());
        }
    }
};

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
        var space_count: usize = 0;
        for (spaces) |space| space_count = @max(space_count, space.index);
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
            if (!std.mem.eql(u8, window.@"role", "AXWindow")) continue;
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
