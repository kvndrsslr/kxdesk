//! Event routing.
//!
//! SketchyBar addresses every event to the item that declared `mach_helper=`, so
//! routing is a lookup on `NAME`; `SENDER` says what actually happened. The names
//! here mirror the items in `bar.zig` that declare the helper.
//!
//! Nothing on this path forks a process. A click is an event - the items that
//! used to carry a `click_script` declare `--subscribe ... mouse.clicked`
//! instead - and what a click asks for is a yabai command or a message back to
//! the bar.
//!
//! Most events are handled inline, because the answers come from yabai or from
//! the kernel and take microseconds. The two items whose refresh reaches the
//! network are handed to `std.Io.async` instead, so the receive loop keeps
//! running while they work; see `background.zig`.

const std = @import("std");

const background = @import("background.zig");
const items_brew = @import("items_brew.zig");
const items_github = @import("items_github.zig");
const items_system = @import("items_system.zig");
const items_yabai = @import("items_yabai.zig");
const platform = @import("platform.zig");
const pomodoro = @import("pomodoro.zig");
const state = @import("store.zig");
const sb = @import("sb.zig");
const zen = @import("zen.zig");

/// Space items are named `space.<index>`, and the index is the space's `SID`.
const space_prefix = "space.";

pub const Dispatcher = struct {
    /// The event loop's own command channel to SketchyBar. Handlers here run
    /// one at a time, so sharing it is safe; background tasks build their own.
    bar: *sb.Client,
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Bootstrap name items carry as `mach_helper`; a refresh that builds new
    /// items has to name it again.
    helper: []const u8,

    yabai_items: items_yabai.Updater,
    system_items: items_system.Updater,
    pomodoro: *pomodoro.Timer,
    store: *state.Store,

    /// At most one of each refresh in flight.
    brew: background.Slot = .{},
    github: background.Slot = .{},

    pub fn handle(self: *Dispatcher, block: [*:0]const u8) !void {
        const env = sb.Env{ .block = block };
        const name = env.getOrEmpty("NAME");

        if (std.mem.eql(u8, env.getOrEmpty("SENDER"), "mouse.clicked")) {
            return self.click(name, env);
        }

        if (std.mem.eql(u8, name, "system.yabai")) {
            // The display map is cached, so a display change has to drop it; the
            // full update below then rebuilds it.
            if (std.mem.eql(u8, env.getOrEmpty("SENDER"), "display_change")) {
                self.yabai_items.invalidateDisplays();
            }

            // `window_title_changed` names the window that changed, so only that
            // display's label needs to move.
            if (std.mem.eql(u8, env.getOrEmpty("ONLY"), "title")) {
                return self.yabai_items.updateTitle(env.getOrEmpty("YABAI_WINDOW_ID"));
            }
            return self.yabai_items.update();
        }
        if (std.mem.eql(u8, name, "battery")) return self.system_items.battery();
        if (std.mem.eql(u8, name, "calendar")) return self.system_items.calendar();

        // `brew outdated` and `gh api` take a second or more, so they run as
        // background tasks rather than on this loop.
        if (std.mem.eql(u8, name, items_brew.item)) {
            self.brew.request(self.io, items_brew.refresh, .{ self.io, self.gpa });
            return;
        }
        if (std.mem.eql(u8, name, items_github.bell)) {
            // Only a scheduled refresh reaches the network; the mouse events
            // just move the popup, so a hover must not start a `gh` call.
            const sender = env.getOrEmpty("SENDER");
            if (std.mem.eql(u8, sender, "routine") or std.mem.eql(u8, sender, "forced")) {
                self.github.request(
                    self.io,
                    items_github.refresh,
                    .{ self.io, self.gpa, self.helper },
                );
                return;
            }
            if (std.mem.eql(u8, sender, "mouse.entered")) {
                return items_github.setPopup(self.bar, .show);
            }
            if (std.mem.eql(u8, sender, "mouse.exited") or
                std.mem.eql(u8, sender, "mouse.exited.global"))
            {
                return items_github.setPopup(self.bar, .hide);
            }
            return;
        }

        // Unknown senders are ignored: items SketchyBar drives itself need no
        // handling here, and so do the `space_change` events the space items
        // receive only because they were created with that subscription.
    }

    /// What a click asks for.
    ///
    /// Each of these was a `click_script` that forked a shell, the `sketchybar`
    /// CLI and `osascript`; the item now sends its click here instead.
    fn click(self: *Dispatcher, name: []const u8, env: sb.Env) !void {
        if (std.mem.eql(u8, name, "calendar")) return self.toggleZen();
        if (std.mem.eql(u8, name, pomodoro.item)) return self.clickPomodoro(env);
        if (std.mem.eql(u8, name, items_github.bell)) {
            return items_github.setPopup(self.bar, .toggle);
        }

        if (std.mem.startsWith(u8, name, items_github.notification_row)) {
            return self.openNotification(name[items_github.notification_row.len..]);
        }

        if (std.mem.startsWith(u8, name, space_prefix)) {
            // The click block carries the space the item stands for, so the
            // focus needs no lookup; the item's own name is the fallback.
            const sid = if (env.getOrEmpty("SID").len > 0)
                env.getOrEmpty("SID")
            else
                name[space_prefix.len..];
            return self.yabai(&.{ "-m", "space", "--focus", sid });
        }
    }

    /// The pomodoro item: a left click starts or stops the timer, a right click
    /// puts it back to a fresh work interval.
    fn clickPomodoro(self: *Dispatcher, env: sb.Env) !void {
        if (std.mem.eql(u8, env.getOrEmpty("BUTTON"), "right")) {
            self.pomodoro.reset(self.io);
        } else {
            self.pomodoro.toggle(self.io);
        }
        self.pomodoro.render(self.io, self.bar);
    }

    /// Open the notification a popup row stands for, and dismiss the popup.
    fn openNotification(self: *Dispatcher, digits: []const u8) !void {
        const index = std.fmt.parseInt(usize, digits, 10) catch return;

        // The row's URL is only known to the refresh that built it. No URL means
        // the row was rebuilt away between the click and this handler, or the
        // bell has an empty inbox; either way there is nothing to open.
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const url = items_github.rowUrl(self.io, index, &buffer) orelse return;

        // Dismissed first, so the popup is gone before the browser appears.
        try items_github.setPopup(self.bar, .hide);

        var target: [std.fs.max_path_bytes]u8 = undefined;
        const terminated = try std.fmt.bufPrintZ(&target, "{s}", .{url});
        if (!platform.sb_open_url(terminated.ptr)) return error.CouldNotOpenUrl;
    }

    /// The calendar's click: collapse the bar down to the essentials and back.
    fn toggleZen(self: *Dispatcher) !void {
        var scratch_state = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch_state.deinit();

        return zen.set(self.bar, scratch_state.allocator(), .toggle, self.store, self.io);
    }

    /// Run a yabai command from the event loop, on a scratch arena of its own so
    /// that nothing it allocates is left behind for the next item update.
    fn yabai(self: *Dispatcher, args: []const []const u8) !void {
        var scratch_state = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch_state.deinit();

        return self.yabai_items.yabai_client.command(scratch_state.allocator(), args);
    }
};
