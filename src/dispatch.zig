//! Event routing: every event SketchyBar addresses to the item that declared
//! `mach_helper=`, routed on `NAME` (`SENDER` says what happened). The names here
//! mirror the items in `bar.zig` that declare the helper.
//!
//! Nothing on this path forks a process, and every event is handled inline except
//! the ones whose work is slow: a refresh that reaches the network, and the load
//! graphs' click, which starts a terminal. Those run as `std.Io.async` tasks so
//! the receive loop keeps running while they work - see `background.zig`.

const std = @import("std");

const background = @import("background.zig");
const items_brew = @import("items_brew.zig");
const items_github = @import("items_github.zig");
const items_system = @import("items_system.zig");
const items_usage = @import("items_usage.zig");
const items_yabai = @import("items_yabai.zig");
const kitty = @import("kitty.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const pomodoro = @import("pomodoro.zig");
const state = @import("store.zig");
const sb = @import("sb.zig");
const zen = @import("zen.zig");

/// The quick access terminals a click brings up, named as the files in the kitty
/// configuration directory's `quick-access-terminals` are: the load graphs show
/// what btop shows in full, and the GitHub bell what ghr shows in full.
const load_terminal = "btop";
const github_terminal = "ghr";

/// Show or hide one of them. It runs as a background task because a toggle talks
/// to a socket and, when the terminal is not running, starts a whole kitty
/// process - and the receive loop has to keep running while that happens. A
/// failure is a line in the log, like every other background task's.
fn toggleTerminal(io: std.Io, gpa: std.mem.Allocator, name: []const u8) background.Result {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    return kitty.toggleNamed(io, arena_state.allocator(), name);
}

/// The popup rows under an item are shown and hidden, never toggled: what a
/// hover means is unambiguous.
const Popup = enum { show, hide };

/// Open a URL with the user's default handler - what a click on a provider item
/// asks for. A free function because it needs nothing of the dispatcher.
fn openPage(url: []const u8) !void {
    var target: [std.fs.max_path_bytes]u8 = undefined;
    const terminated = try std.fmt.bufPrintZ(&target, "{s}", .{url});
    if (!platform.kx_open_url(terminated.ptr)) return error.CouldNotOpenUrl;
}

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
    usage: background.Slot = .{},
    /// The load graphs' terminal toggle, at most one in flight: a click that
    /// arrives while one runs waits for it rather than racing it.
    terminal: background.Slot = .{},
    /// A refresh asked for while one ran too recently to repeat. The receive
    /// loop's timer drains it through `pollYabai` once the interval closes.
    yabai_pending: bool = false,
    /// Awake-clock instant the last full refresh started; `.zero` for none yet.
    yabai_refreshed: std.Io.Timestamp = .zero,

    /// A full refresh forks yabai twice and rebuilds every strip, and a drag or a
    /// space flood turns into a stream of `window_moved` events; the loop runs one
    /// update at a time, so holding refreshes this far apart collapses the stream
    /// into one while a lone event still refreshes at once.
    const yabai_refresh_interval_ms: i64 = 120;

    /// Milliseconds since the last full refresh; effectively infinite before the
    /// first one, so that an event with nothing in flight refreshes immediately.
    fn refreshAgeMs(self: *const Dispatcher) i64 {
        if (self.yabai_refreshed.nanoseconds == 0) return std.math.maxInt(i64);
        const age = self.yabai_refreshed.durationTo(std.Io.Timestamp.now(self.io, .awake));
        return @intCast(@divTrunc(age.nanoseconds, std.time.ns_per_ms));
    }

    /// Refresh the strips now, or hold the refresh for the timer when one ran
    /// inside `yabai_refresh_interval_ms`.
    fn requestYabai(self: *Dispatcher) !void {
        if (self.refreshAgeMs() < yabai_refresh_interval_ms) {
            self.yabai_pending = true;
            return;
        }
        return self.refreshYabai();
    }

    fn refreshYabai(self: *Dispatcher) !void {
        self.yabai_refreshed = std.Io.Timestamp.now(self.io, .awake);
        return self.yabai_items.update();
    }

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
            return self.requestYabai();
        }
        if (std.mem.eql(u8, name, items_system.ring_item)) return self.system_items.battery();
        if (std.mem.eql(u8, name, "calendar")) return self.system_items.calendar();

        // `brew outdated` and `gh api` take a second or more, so they run as
        // background tasks rather than on this loop.
        if (std.mem.eql(u8, name, items_brew.item)) {
            self.brew.request(self.io, items_brew.refresh, .{ self.io, self.gpa });
            return;
        }
        // Provider items are refreshed by the receive loop's clock, not by their
        // own events - a refresh pushes labels back to the items, and an item
        // subscribed to updates turns that push into another event - so only the
        // mouse matters here, and only a provider with windows has a popup.
        if (items_usage.providerFor(name)) |provider| {
            if (provider.rows.len == 0) return;

            const sender = env.getOrEmpty("SENDER");
            if (std.mem.eql(u8, sender, "mouse.entered")) {
                return self.setUsagePopup(name, .show);
            }
            if (std.mem.eql(u8, sender, "mouse.exited") or
                std.mem.eql(u8, sender, "mouse.exited.global"))
            {
                return self.setUsagePopup(name, .hide);
            }
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

        // Unknown senders are ignored; `space_change` reaches the space items
        // only because they were created with that subscription.
    }

    /// What a click asks for.
    fn click(self: *Dispatcher, name: []const u8, env: sb.Env) !void {
        if (std.mem.eql(u8, name, "calendar")) return self.toggleZen();
        if (std.mem.eql(u8, name, pomodoro.item)) return self.clickPomodoro(env);
        // The load graphs draw what the terminal shows in full, so a click on
        // either of them brings it up - and the next click puts it away again.
        if (std.mem.eql(u8, name, items_system.cpu_item) or
            std.mem.eql(u8, name, items_system.gpu_item))
        {
            self.terminal.request(self.io, toggleTerminal, .{ self.io, self.gpa, load_terminal });
            return;
        }
        // A provider's number opens that provider's usage page.
        if (items_usage.providerFor(name)) |provider| return openPage(provider.url);
        if (std.mem.eql(u8, name, items_github.bell)) {
            // The popup is the hover's business, in `handle`; the click is the
            // dashboard, which is where the notifications are worked through.
            // The count follows the click rather than its own three-minute
            // schedule: what the dashboard reads is what the item renders, and
            // waiting that out would leave the badge showing notifications that
            // were just worked through.
            self.terminal.request(self.io, toggleTerminal, .{ self.io, self.gpa, github_terminal });
            self.github.request(
                self.io,
                items_github.refresh,
                .{ self.io, self.gpa, self.helper },
            );
            return;
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

    /// Start a usage refresh if the clock says one is due, and report how long
    /// the receive loop may wait next. Called from that loop's timer.
    pub fn pollUsage(self: *Dispatcher) u32 {
        if (items_usage.due(self.io)) {
            self.usage.request(self.io, items_usage.refresh, .{ self.io, self.gpa, self.store });
            return 1000;
        }
        return items_usage.waitMs(self.io);
    }

    /// Drain a refresh that was held back because one had just run, and report how
    /// long the receive loop may wait next; 0 means "nothing scheduled", so a
    /// refresh still inside the interval reports the wait left instead of sleeping
    /// through it.
    pub fn pollYabai(self: *Dispatcher) u32 {
        if (!self.yabai_pending) return 0;

        const age = self.refreshAgeMs();
        if (age < yabai_refresh_interval_ms) {
            return @intCast(yabai_refresh_interval_ms - age);
        }

        self.yabai_pending = false;
        self.refreshYabai() catch |err| {
            log.warn("yabai refresh failed: {s}", .{@errorName(err)});
        };
        return 0;
    }

    /// Show or hide the rows under one of the provider items.
    fn setUsagePopup(self: *Dispatcher, name: []const u8, wanted: Popup) !void {
        var props: Props = .{};
        try props.write(.{ .popup = .{ .drawing = wanted == .show } });
        try self.bar.set(name, props.slice());
        try self.bar.commit();
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
        if (!platform.kx_open_url(terminated.ptr)) return error.CouldNotOpenUrl;
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
