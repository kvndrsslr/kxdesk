//! The GitHub bell's refresh.
//!
//! Replaces `plugins/github.sh`, which SketchyBar forked; the script then forked
//! `gh` (once for the notification list, once per notification to resolve its
//! URL), `jq`, `egrep` and `sketchybar` itself, and round-tripped every field
//! through shell quoting that had to be `sed`-ed back off. `gh api` is a network
//! call, so the daemon runs this as a background task; see `background.zig`.
//!
//! A row is clicked long after the refresh that built it, and only that refresh
//! knows where the row points, so the URLs are published for the event loop.

const std = @import("std");

const exec = @import("exec.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const theme = @import("theme.zig");

/// The bell this refresh owns, and the template item a popup row is cloned
/// from. `bar.zig` declares both items, `dispatch.zig` routes the bell's events
/// by name, and neither imports this file - so the names are stated once here
/// and once there.
pub const bell = "github.bell";
pub const template = "github.template";

/// Popup rows, rebuilt from the template on every refresh.
pub const notification_row = "github.notification.";
/// What `plugins/github.sh` passed to `--remove`; the regex is delimited by
/// slashes, and the escaped dot keeps it anchored to the row prefix.
const notification_pattern = "/github.notification\\.*/";

/// Where a row points when its own URL cannot be resolved.
const notifications_page = "https://www.github.com/notifications";

/// URLs of the popup rows the last refresh built, index-aligned with
/// `github.notification.N`.
///
/// The refresh runs as a worker task while a click arrives on the receive loop,
/// so this is the one piece of state the two share. URLs are copied in and out
/// while the lock is held, so a refresh that replaces the whole set cannot pull
/// storage out from under a click that is already resolving one.
var rows: Rows = .{};

const Rows = struct {
    mutex: std.Io.Mutex = .init,
    /// The published set. Replaced rather than appended to, because a refresh
    /// rebuilds the entire popup.
    arena: ?*std.heap.ArenaAllocator = null,
    urls: []const []const u8 = &.{},

    /// Publish the URLs of the rows just built, releasing the previous set.
    fn publish(self: *Rows, gpa: std.mem.Allocator, io: std.Io, urls: []const []const u8) void {
        const fresh = gpa.create(std.heap.ArenaAllocator) catch return;
        fresh.* = std.heap.ArenaAllocator.init(gpa);

        const arena = fresh.allocator();
        const copies = arena.alloc([]const u8, urls.len) catch
            return discard(fresh, gpa);
        for (urls, 0..) |address, index| {
            copies[index] = arena.dupe(u8, address) catch return discard(fresh, gpa);
        }

        self.mutex.lockUncancelable(io);
        const previous = self.arena;
        self.arena = fresh;
        self.urls = copies;
        self.mutex.unlock(io);

        // Released outside the lock: a reader copies what it needs while holding
        // it, so nothing can still be pointing into this set.
        if (previous) |old| {
            old.deinit();
            gpa.destroy(old);
        }
    }

    /// The URL of popup row `index` - rows are numbered from 1 - copied into
    /// `buffer` so that it outlives the lock. Null when there is no such row.
    fn url(self: *Rows, io: std.Io, index: usize, buffer: []u8) ?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (index == 0 or index > self.urls.len) return null;

        const address = self.urls[index - 1];
        if (address.len > buffer.len) return null;

        @memcpy(buffer[0..address.len], address);
        return buffer[0..address.len];
    }

    fn discard(fresh: *std.heap.ArenaAllocator, gpa: std.mem.Allocator) void {
        fresh.deinit();
        gpa.destroy(fresh);
    }
};

/// Where a click on `github.notification.<index>` should go. The row's URL is
/// only known to the refresh that built it, which is why it is published here
/// rather than carried by the item.
pub fn rowUrl(io: std.Io, index: usize, buffer: []u8) ?[]const u8 {
    return rows.url(io, index, buffer);
}

/// Titles mentioning any of these are singled out, as the shell's `egrep -i`
/// did.
const important_markers = [_][]const u8{ "deprecat", "break", "broke" };

/// Only the fields this renders.
const Notification = struct {
    @"repository": struct { @"name": []const u8 = "" } = .{},
    @"subject": struct {
        @"title": []const u8 = "",
        @"type": []const u8 = "",
        @"latest_comment_url": ?[]const u8 = null,
    } = .{},
};

const HtmlUrl = struct { @"html_url": []const u8 = "" };

pub const Popup = enum { show, hide, toggle };

/// Open, close, or flip the bell's popup. The shell did this from the plugin
/// too - `mouse.entered`/`mouse.exited` events opening and closing it - so this
/// costs one message and no process.
pub fn setPopup(bar: *sb.Client, state: Popup) !void {
    var props: Props = .{};
    switch (state) {
        .show => props.raw("popup.drawing=on"),
        .hide => props.raw("popup.drawing=off"),
        .toggle => props.raw("popup.drawing=toggle"),
    }
    try bar.set(bell, props.slice());
    try bar.commit();
}

pub fn refresh(io: std.Io, gpa: std.mem.Allocator, helper: []const u8) anyerror!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const gh = try exec.path(gpa, "gh");
    defer gpa.free(gh);

    const notifications = try parseNotifications(arena, gpa, io, gh);

    var client = sb.Client.init(gpa, sb.sketchybar_service);
    defer client.deinit();
    try client.connect();

    const previous = try previousCount(&client, arena);
    const count = notifications.len;

    var props: Props = .{};
    // One icon for both states: the Octocat says what this item is about, and
    // whether there is something new is already said twice over - by the count,
    // and by the icon turning red when a notification matters.
    try props.fmt("icon={s}", .{theme.glyph.github});
    try props.fmt("label={d}", .{count});
    try props.color("icon.color", theme.blue);
    try client.set(bell, props.slice());

    // Rows are rebuilt rather than reconciled, as the shell did.
    try client.arg("--remove");
    try client.arg(notification_pattern);

    var important = false;
    var urls = std.ArrayList([]const u8).empty;
    for (notifications, 1..) |notification, index| {
        // A row that cannot be built is still numbered, so the URL list has to
        // advance with the loop: a click on row N must find N's URL, not the
        // next successfully built row's.
        var url: []const u8 = notifications_page;
        if (row(&client, notification, index, gh, helper, arena, gpa, io, &url)) |is_important| {
            important = important or is_important;
        } else |err| {
            std.debug.print("kxdesk: notification {d} skipped: {s}\n", .{ index, @errorName(err) });
        }
        try urls.append(arena, url);
    }
    rows.publish(gpa, io, urls.items);

    if (important) {
        var bell_color: Props = .{};
        try bell_color.color("icon.color", theme.red);
        try client.set(bell, bell_color.slice());
    }

    try client.commit();

    // Nudge the bell when something new arrived, as the shell did.
    const grew = if (previous) |before| count > before else false;
    if (grew) {
        try client.arg("--animate");
        try client.arg("tanh");
        try client.arg("15");
        var nudge: Props = .{};
        try nudge.num("label.y_offset", 5);
        try nudge.num("label.y_offset", 0);
        try client.set(bell, nudge.slice());
        try client.commit();
    }
}

/// Emit one popup row. Returns whether the notification was marked important.
fn row(
    client: *sb.Client,
    notification: Notification,
    index: usize,
    gh: [:0]const u8,
    helper: []const u8,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    url_out: *[]const u8,
) !bool {
    const repo = if (notification.@"repository".@"name".len > 0)
        notification.@"repository".@"name"
    else
        "Note";
    const title = if (notification.@"subject".@"title".len > 0)
        notification.@"subject".@"title"
    else
        "No new notifications";

    const is_important = mentionsImportant(notification.@"subject".@"title");

    var color: theme.Color = theme.blue;
    var icon: []const u8 = theme.glyph.bell;
    var url: []const u8 = notifications_page;

    if (std.mem.eql(u8, notification.@"subject".@"type", "Issue")) {
        color = theme.green;
        icon = theme.glyph.git_issue;
        url = try resolveUrl(arena, gpa, io, gh, notification);
    } else if (std.mem.eql(u8, notification.@"subject".@"type", "PullRequest")) {
        color = theme.magenta;
        icon = theme.glyph.git_pull_request;
        url = try resolveUrl(arena, gpa, io, gh, notification);
    } else if (std.mem.eql(u8, notification.@"subject".@"type", "Commit")) {
        color = theme.white;
        icon = theme.glyph.git_commit;
        url = try resolveUrl(arena, gpa, io, gh, notification);
    } else if (std.mem.eql(u8, notification.@"subject".@"type", "Discussion")) {
        color = theme.white;
        icon = theme.glyph.git_discussion;
    }

    if (is_important) {
        color = theme.red;
        icon = theme.glyph.github_important;
    }

    // Published before the item itself is built, so that a row which fails to
    // be created still leaves the list aligned.
    url_out.* = url;

    var name_buffer: [48]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}{d}", .{ notification_row, index });

    try client.arg("--clone");
    try client.arg(name);
    try client.arg(template);
    try client.arg("--subscribe");
    try client.arg(name);
    try client.arg("mouse.clicked");

    var props: Props = .{};
    try props.text("label", title);
    try props.fmt("icon={s} {s}:", .{ icon, repo });
    try props.num("icon.padding_left", 0);
    try props.num("label.padding_right", 0);
    try props.color("icon.color", color);
    try props.text("position", "popup.github.bell");
    try props.color("icon.background.color", color);
    props.raw("drawing=on");
    // A clone inherits the event port and the update mask only as a side effect
    // of copying its ancestor, and a row that is not routed gets no click at
    // all, so the routing is stated per row as well as on the template.
    try props.text("mach_helper", helper);
    props.raw("updates=on");
    try client.set(name, props.slice());

    return is_important;
}

/// The notification's own URL, resolved through one more `gh api` call.
fn resolveUrl(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    gh: [:0]const u8,
    notification: Notification,
) ![]const u8 {
    const latest = notification.@"subject".@"latest_comment_url" orelse return notifications_page;

    // A notification whose URL cannot be resolved - deleted, or not visible to
    // the token - still belongs in the popup, so it points at the inbox instead
    // of taking the row down with it.
    const body = api(arena, gpa, io, gh, &.{latest}) catch return notifications_page;
    const parsed = std.json.parseFromSliceLeaky(HtmlUrl, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return notifications_page;

    return if (parsed.@"html_url".len > 0) parsed.@"html_url" else notifications_page;
}

fn parseNotifications(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    gh: [:0]const u8,
) ![]Notification {
    const body = try api(arena, gpa, io, gh, &.{"notifications"});
    return std.json.parseFromSliceLeaky([]Notification, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch error.InvalidNotifications;
}

/// Run `gh api <arguments>` and return its output.
fn api(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    gh: [:0]const u8,
    arguments: []const []const u8,
) ![]u8 {
    const argv = try arena.alloc([]const u8, arguments.len + 2);
    argv[0] = gh;
    argv[1] = "api";
    @memcpy(argv[2..], arguments);

    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const succeeded = switch (result.term) {
        .exited => |status| status == 0,
        else => false,
    };
    if (!succeeded) return error.GhFailed;

    return arena.dupe(u8, result.stdout);
}

fn mentionsImportant(title: []const u8) bool {
    for (important_markers) |marker| {
        if (containsIgnoreCase(title, marker)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

/// The bell's current label, used to notice that the count grew. A label that
/// is not a number leaves this unknown, and then no nudge is emitted - which is
/// what the shell's failing numeric comparison did too.
fn previousCount(client: *sb.Client, arena: std.mem.Allocator) !?usize {
    var response: [16 * 1024]u8 = undefined;

    client.clear();
    try client.arg("--query");
    try client.arg(bell);
    const body = try client.commitInto(&response);

    const Bell = struct {
        @"label": struct { @"value": []const u8 = "" } = .{},
    };
    const parsed = std.json.parseFromSliceLeaky(Bell, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch return null;
    return std.fmt.parseInt(usize, parsed.@"label".@"value", 10) catch null;
}
