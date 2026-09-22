//! The yabai commands kxdesk manages: settings, rules, signals, and every window,
//! space and display verb `kxdesk wm` runs.
//!
//! Every command is an exact argv, one `yabai -m` per call; a `&&` between two
//! commands is two `try`s, so the second only runs when the first was taken. A
//! verb reads its own word from `args[0]` and its arguments from `args[1..]`, the
//! shape the daemon hands every command's `run` - so the CLI and a pushed key
//! binding reach the same code with the same words.

const std = @import("std");

const Context = @import("context.zig").Context;
const kanata = @import("kanata.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const yabai = @import("yabai.zig");

/// One `rule --add`, complete: the exact argv tokens, spaces inside tokens
/// exactly as they must reach yabai - quoting them differently would change what
/// yabai matches.
///
/// Every rule carries a label, including the two that used to go unlabelled: a
/// rule is removed by naming it, so an unlabelled one could never be removed and
/// accumulated a copy per refresh. Nothing here is added without a name.
const managed_rules = [_][]const []const u8{
    &.{ "-m", "rule", "--add", "label=unmanaged apps", "manage=off", "app=^(Ableton|Blitz|BIAS FX 2|Yousician|ROLI Connect|JetBrains Toolbox|Steam|MTGA|Leader Key)$" },
    &.{ "-m", "rule", "--add", "label=sticky topmost apps", "manage=off", "sticky=on", "app=^System Settings|Vitamin-R 3|Wally|ColorSlurp$" },
    &.{ "-m", "rule", "--add", "label=video and gaming apps in pip mode", "manage=off", "sticky=on", "opacity=1.0", "app=^VLC|mpv$|^(Riot Client)|(League Client)|(League of)|(League Of)" },
    &.{ "-m", "rule", "--add", "label=Teams Notifications", "app=^Microsoft Teams$", "title=^Microsoft Teams Notification$", "manage=off" },
    &.{ "-m", "rule", "--add", "label=slack and kitty on display 3", "app=^(Slack|kitty)$", "display=^3" },
    &.{ "-m", "rule", "--add", "label=mail on display 1", "app=^(Microsoft Outlook|Mail)$", "display=^1" },
};

/// One `signal --add`, complete: the exact argv tokens. `$YABAI_WINDOW_ID` is
/// substituted by yabai at signal time, so it must reach yabai verbatim; argv
/// tokens rather than a shell keep it intact.
///
/// The `kx_*` family fans every event that changes what the bar renders into the
/// one `yabai_update` trigger the helper serves; `window_resized` is in it
/// because yabai retiles a window moved to another space, so that is the event
/// that arrives (measured - `window_moved` is the positional one, a drag in
/// place). The display list is left to the bar's own `display_change`
/// subscription.
const managed_signals = [_][]const []const u8{
    &.{ "-m", "signal", "--add", "event=window_title_changed", "label=kx_atc", "action=sketchybar --trigger yabai_update ONLY=title YABAI_WINDOW_ID=$YABAI_WINDOW_ID", "active=yes" },
    &.{ "-m", "signal", "--add", "event=window_focused", "label=kx_wf", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=window_moved", "label=kx_wm", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=window_resized", "label=kx_wr", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=window_created", "label=kx_wc", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=window_destroyed", "label=kx_wd", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=window_minimized", "label=kx_wmin", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=window_deminimized", "label=kx_wdemin", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=space_changed", "label=kx_sc", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=space_created", "label=kx_spc", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=space_destroyed", "label=kx_spd", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=window_created", "app=Telegram", "label=telegram-display-enforcement", "action=zsh -c \"sleep 1.5 && yabai -m window $YABAI_WINDOW_ID --display 1 --focus\"" },
};

/// Every setting kxdesk asserts on yabai, in the order yabai receives them.
///
/// Flat `key, value, key, value`, because that is the shape `yabai -m config`
/// reads, and the whole table has to reach yabai in one invocation: a `yabai` per
/// setting is twenty-four processes and about 460 ms here, against 77 ms for the
/// one.
///
/// Settings that stay off are left out: an unasserted setting keeps yabai's
/// default.
const settings = [_][]const u8{
    "mouse_follows_focus",         "off",
    "focus_follows_mouse",         "off",
    "window_placement",            "second_child",
    "window_shadow",               "off",
    "skip_window_focus_animation", "on",
    "window_opacity",              "off",
    "active_window_opacity",       "0.97",
    "normal_window_opacity",       "0.93",
    "insert_feedback_color",       "0xffd75f5f",
    "split_ratio",                 "0.50",
    "auto_balance",                "off",
    "mouse_modifier",              "fn",
    "mouse_action1",               "move",
    "mouse_action2",               "resize",
    "mouse_drop_action",           "swap",
    "layout",                      "stack",
    "top_padding",                 "0",
    "bottom_padding",              "0",
    "left_padding",                "0",
    "right_padding",               "0",
    "window_gap",                  "3",
    "external_bar",                "all:26:0",
    "display_arrangement_order",   "horizontal",
    // Off: yabai then writes every event and every bar query to
    // `/tmp/yabai_kdressler.out.log` on the same thread that processes them, and
    // the file only grows - 104 MiB in twenty-five minutes, a drag emitting one
    // event per frame.
    "debug_output",                "off",
};

/// `yabai -m config` followed by every setting: one argument vector, one
/// process, however many settings there are.
const settings_argv = [_][]const u8{ "-m", "config" } ++ settings;

/// Assert everything kxdesk manages on yabai: every setting, then every rule,
/// then every signal.
///
/// One command, because the three are asserted together and this way it is one
/// round trip to the daemon rather than three - and the three stay reachable on
/// their own for a targeted refresh.
pub fn applySettings(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    try context.yabai.command(context.arena, &settings_argv);
    _ = try refreshRules(context, &.{});
    _ = try refreshSignals(context, &.{});
    return "";
}

/// Re-provision the yabai rules: drop whatever is configured, then add the six
/// managed ones. An empty `--list` is not an error, failed removals do not stop
/// the adds, and the result is the last add's.
pub fn refreshRules(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    const arena = context.arena;

    const listed = try context.yabai.query([]yabai.Labeled, arena, &.{ "-m", "rule", "--list" });
    for (listed) |rule| removeByLabel(arena, context.yabai, "rule", rule.label) catch {};

    // The exit status is the last add's, so a rule that cannot be added - the
    // `display=^3` one here, yabai finding no display with arrangement index 3 -
    // does not fail the refresh.
    var last_add: anyerror!void = {};
    for (managed_rules) |rule| {
        last_add = context.yabai.command(arena, rule);
    }
    try last_add;
    return "";
}

/// Re-provision the yabai signals: clear, then add every one in
/// `managed_signals`.
pub fn refreshSignals(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    try clearSignalsInner(context, true);

    const arena = context.arena;
    // The result is the last add's, as in `refreshRules`.
    var last_add: anyerror!void = {};
    for (managed_signals) |signal| {
        last_add = context.yabai.command(arena, signal);
    }
    try last_add;
    return "";
}

/// Drop every configured yabai signal; removing nothing is not an error.
pub fn clearSignals(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    try clearSignalsInner(context, false);
    return "";
}

/// `tolerate_removal_failure` is set by the provisioners, which continue past a
/// failed removal among their adds.
fn clearSignalsInner(context: *Context, tolerate_removal_failure: bool) !void {
    const arena = context.arena;

    const listed = try context.yabai.query([]yabai.Labeled, arena, &.{ "-m", "signal", "--list" });
    for (listed) |signal| {
        removeByLabel(arena, context.yabai, "signal", signal.label) catch |err| {
            if (!tolerate_removal_failure) return err;
        };
    }
}

/// Focus a set of spaces named by label, leaving a member of the group on the
/// currently focused display for last, so that is where focus lands.
///
/// `args[0]` is a comma-separated list of labels, quoted or not. A label
/// matching no space is simply absent, and nothing to focus at all is not an
/// error. Degenerate case this does not handle: no match on the focused display.
pub fn switchWorkspace(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    if (args.len == 0) return error.MissingArgument;

    const wanted = parseLabels(args[0], arena);

    // Queried once and kept: the command passes over them twice. The displays
    // come from a display query rather than from counting upwards, so an
    // arrangement with a gap cannot hide a display above it.
    const displays = displayList(arena, context.yabai);
    const per_display = try arena.alloc([]yabai.Space, displays.len);
    for (displays, 0..) |display, position| {
        per_display[position] = spacesOf(arena, context.yabai, display.index);
    }

    // The deciding display is the one holding the highest-index focused space,
    // determined before anything is focused.
    var focused_display: ?u32 = null;
    for (per_display) |spaces| {
        for (spaces) |space| {
            if (space.@"has-focus") focused_display = space.display;
        }
    }

    // Matches on the other displays are focused first, in index order, and the
    // deciding display's matches last, so the one chosen is the one left focused.
    // A focus that fails is remembered rather than aborting the rest.
    var final_focus: ?yabai.Space = null;
    var failed = false;
    for (per_display) |spaces| {
        sort(spaces);

        for (spaces) |space| {
            if (!isSelected(wanted, space.label)) continue;

            if (focused_display != null and space.display == focused_display.?) {
                // A match holding focus wins; otherwise the last match in index
                // order does.
                const chosen_holds_focus = if (final_focus) |chosen| chosen.@"has-focus" else false;
                if (space.@"has-focus" or
                    (!chosen_holds_focus and
                        (final_focus == null or space.index > final_focus.?.index)))
                {
                    final_focus = space;
                }
            } else {
                focusSpace(arena, context.yabai, space.index) catch {
                    failed = true;
                };
            }
        }
    }

    if (final_focus) |space| {
        focusSpace(arena, context.yabai, space.index) catch {
            failed = true;
        };
    }
    if (failed) return error.YabaiFailed;
    return "";
}

/// Cycle focus through every window of the current space, floating ones
/// included.
///
/// yabai's own `--focus next`/`first` and their `stack.*` cousins resolve through
/// `view_find_window_node`, the BSP tree, so a floating window is never their
/// target - and a floating window holding focus has no node at all. The order
/// here is the space's window list sorted by window id, which is creation order
/// and does not shift as focus moves. Minimized windows are left out, as yabai
/// leaves them out of the tree by untiling them; the focused window is the last
/// candidate, so a space with one window re-raises it; a space with nothing
/// focusable does nothing and still succeeds.
pub fn cycleSpaceWindows(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    const reverse = hasFlag(args, "--reverse");

    // A query yabai refuses leaves nothing to cycle, and is not an error a
    // keybinding should report.
    const windows = context.yabai.spaceWindows(arena) catch return "";
    if (windows.len == 0) return "";

    std.mem.sort(yabai.Window, windows, {}, lessThanId);

    const focused_position: ?usize = for (windows, 0..) |window, position| {
        if (window.@"has-focus" and !window.@"is-minimized") break position;
    } else null;

    // One lap of the list, starting after the window that holds focus and
    // wrapping: the offset that lands back on it is the last one tried, which is
    // what re-raises a lone window.
    var offset: usize = 1;
    while (offset <= windows.len) : (offset += 1) {
        const position = if (focused_position) |focused|
            if (reverse)
                (focused + windows.len - offset) % windows.len
            else
                (focused + offset) % windows.len
        else if (reverse)
            (windows.len - offset) % windows.len
        else
            offset - 1;

        const window = windows[position];
        if (window.@"is-minimized") continue;
        if (focusWindow(arena, context.yabai, window.id)) return "";
    }
    return "";
}

/// Move focus to the neighbouring space on the current display, falling back
/// to Mission Control's arrow keys - pressed through kanata - for the
/// native-fullscreen spaces yabai cannot focus.
pub fn cycleDisplaySpaces(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    const reverse = hasFlag(args, "--reverse");

    const spaces = try context.yabai.query([]yabai.Space, arena, &.{ "-m", "query", "--spaces", "--display" });
    if (spaces.len == 0) return error.YabaiFailed;

    sort(spaces);

    // Next with wrap-around forward, previous with wrap-around reversed, and a
    // self-focus cycle on a one-space display.
    const focused_position: ?usize = for (spaces, 0..) |space, position| {
        if (space.@"has-focus") break position;
    } else null;

    const neighbor = if (focused_position) |focused| blk: {
        if (reverse) {
            break :blk spaces[if (focused == 0) spaces.len - 1 else focused - 1];
        } else {
            break :blk spaces[if (focused + 1 >= spaces.len) 0 else focused + 1];
        }
    } else blk: {
        // No focused space: the last element forward, the first reversed.
        break :blk if (reverse) spaces[0] else spaces[spaces.len - 1];
    };

    const index_argument = try numArg(arena, neighbor.index);
    context.yabai.command(arena, &.{ "-m", "space", "--focus", index_argument }) catch |err| switch (err) {
        // Native-fullscreen spaces refuse to be focused by yabai, and so does
        // re-focusing the current one; the fallback is Mission Control's
        // shortcut, pressed through kanata.
        error.YabaiFailed => {
            try kanata.tapFakeKey(context, if (reverse) "ctrl-left" else "ctrl-right");
            return "";
        },
        else => return err,
    };
    return "";
}

/// Every labelled space, one label per line, in index order.
///
/// This is what a completion offers for `wm switch-workspace`, and it is worth
/// having on its own: the labels are what a binding passes, and they exist
/// nowhere but in yabai's answer.
pub fn spaceLabels(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    const arena = context.arena;

    const spaces = try context.yabai.query([]yabai.Space, arena, &.{ "-m", "query", "--spaces" });
    sort(spaces);

    var labels = std.ArrayList([]const u8).empty;
    for (spaces) |space| {
        if (space.label.len == 0) continue;
        // A label may be on more than one space; it is offered once.
        if (isSelected(labels.items, space.label)) continue;
        try labels.append(arena, space.label);
    }
    return std.mem.join(arena, "\n", labels.items) catch return error.OutOfMemory;
}

/// Move focus to the neighbouring display.
pub fn cycleDisplays(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;

    const attempts: []const []const []const u8 = if (hasFlag(args, "--reverse"))
        &.{
            &.{ "-m", "display", "--focus", "prev" },
            &.{ "-m", "display", "--focus", "last" },
        }
    else
        &.{
            &.{ "-m", "display", "--focus", "next" },
            &.{ "-m", "display", "--focus", "first" },
        };

    for (attempts) |argv| {
        context.yabai.command(arena, argv) catch continue;
        return "";
    }
    return error.YabaiFailed;
}

/// Every display yabai knows, or the one that is in focus when it refuses the
/// list - the shape of the same failure the bar's own display query handles.
fn displayList(arena: std.mem.Allocator, client: *yabai.Client) []yabai.Display {
    return client.displays(arena) catch |err| blk: {
        log.warn("yabai query failed: {s}", .{@errorName(err)});
        break :blk client.query([]yabai.Display, arena, &.{
            "-m", "query", "--displays", "--display",
        }) catch &.{};
    };
}

/// The spaces of one display, or none when yabai will not answer for it: the
/// caller remembers that a focus was missed rather than aborting the rest.
fn spacesOf(arena: std.mem.Allocator, client: *yabai.Client, display: u32) []yabai.Space {
    const index = numArg(arena, display) catch return &.{};
    return client.query([]yabai.Space, arena, &.{ "-m", "query", "--spaces", "--display", index }) catch |err| blk: {
        log.warn("yabai query failed: {s}", .{@errorName(err)});
        break :blk &.{};
    };
}

/// Ascending space index.
fn sort(spaces: []yabai.Space) void {
    std.mem.sort(yabai.Space, spaces, {}, lessThanIndex);
}

fn lessThanIndex(_: void, a: yabai.Space, b: yabai.Space) bool {
    return a.index < b.index;
}

/// Ascending window id: the order yabai reports a space's windows in, which is
/// the order they were created in, and what the focus cycle walks.
fn lessThanId(_: void, a: yabai.Window, b: yabai.Window) bool {
    return a.id < b.id;
}

/// One number as the argv token yabai reads.
fn numArg(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

/// Focus one window by id, reporting whether yabai took it.
///
/// yabai refuses an id it cannot focus, and that refusal is what lets the cycle
/// step over an entry of the space's window list that is not focusable - a
/// non-AX window that holds no accessibility element to raise.
fn focusWindow(arena: std.mem.Allocator, client: *yabai.Client, id: u32) bool {
    const argument = numArg(arena, id) catch return false;
    client.command(arena, &.{ "-m", "window", argument, "--focus" }) catch return false;
    return true;
}

/// `yabai -m <domain> --remove <label>`, for one entry of a `--list`.
///
/// A rule or signal yabai reports without a label is skipped rather than
/// failing the refresh: it cannot be named for removal, and every entry kxdesk
/// adds has one.
fn removeByLabel(arena: std.mem.Allocator, client: *yabai.Client, domain: []const u8, label: []const u8) !void {
    if (label.len == 0) return;
    try client.command(arena, &.{ "-m", domain, "--remove", label });
}

fn focusSpace(arena: std.mem.Allocator, client: *yabai.Client, index: u32) !void {
    const argument = try numArg(arena, index);
    try client.command(arena, &.{ "-m", "space", "--focus", argument });
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |argument| {
        if (std.mem.eql(u8, argument, flag)) return true;
    }
    return false;
}

/// Is `label` one of the wanted spaces?
fn isSelected(wanted: []const []const u8, label: []const u8) bool {
    for (wanted) |candidate| {
        if (std.mem.eql(u8, candidate, label)) return true;
    }
    return false;
}

/// Split the comma-separated label list, stripping the double quotes a quoted
/// caller embeds. Empty labels are dropped, so a trailing comma is harmless.
fn parseLabels(input: []const u8, arena: std.mem.Allocator) []const []const u8 {
    var labels = std.ArrayList([]const u8).empty;
    var iterator = std.mem.splitScalar(u8, input, ',');
    while (iterator.next()) |raw| {
        const stripped = std.mem.trim(u8, raw, "\"");
        if (stripped.len > 0) labels.append(arena, stripped) catch return &.{};
    }
    return labels.items;
}

/// The four directions yabai's window and space commands take.
pub const Direction = enum {
    west,
    south,
    north,
    east,

    /// The word yabai spells this direction with.
    pub fn name(self: Direction) []const u8 {
        return @tagName(self);
    }
};

/// The layouts `yabai -m space --layout` takes.
pub const Layout = enum { bsp, stack, float };

/// What `window-focus` focuses: the window that held focus before this one, or
/// the next window of the focused window's application.
pub const FocusTarget = enum { recent, same_app };

/// One of the window states `window-toggle` toggles.
pub const WindowToggle = enum {
    /// Grow the window to its display, staying in the space's layout.
    zoom_fullscreen,
    /// macOS's own fullscreen.
    native_fullscreen,
    /// Mission Control's window overview.
    expose,
    /// Float, stick and raise at once - three toggles, in this order.
    float_sticky_topmost,
};

/// A CLI word as the enum tag it names, `-` and `_` spelling the same word: the
/// CLI spells `same-app`, and the tag it names is `same_app`.
pub fn wordToEnum(comptime T: type, word: []const u8) ?T {
    inline for (std.meta.fields(T)) |field| {
        if (eqlLoose(field.name, word)) return @enumFromInt(field.value);
    }
    return null;
}

/// A tag name with `_` spelled as the CLI's `-`, at compile time: the fixed
/// values a verb's argument accepts, derived from the enum that parses them, so
/// what the registry offers and what the verb reads cannot drift apart.
pub fn hyphenTags(comptime T: type) [std.meta.fields(T).len][]const u8 {
    const tags = comptime blk: {
        var names: [std.meta.fields(T).len][]const u8 = undefined;
        for (std.meta.fields(T), 0..) |field, position| {
            names[position] = hyphenated(field.name);
        }
        break :blk names;
    };
    return tags;
}

/// One tag's name, hyphenated, as a compile-time string.
fn hyphenated(comptime name: []const u8) []const u8 {
    const frozen = comptime blk: {
        var out: [name.len]u8 = undefined;
        for (name, 0..) |character, position| {
            out[position] = if (character == '_') '-' else character;
        }
        break :blk out;
    };
    return &frozen;
}

/// Whether two words are the same but for `-` against `_`.
fn eqlLoose(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (spelled(left) != spelled(right)) return false;
    }
    return true;
}

fn spelled(character: u8) u8 {
    return if (character == '-') '_' else character;
}

/// The word at `args[arg_index]`, as the enum tag it names.
fn wordArg(comptime T: type, args: []const []const u8, arg_index: usize) !T {
    if (arg_index >= args.len) return error.MissingArgument;
    return wordToEnum(T, args[arg_index]) orelse error.InvalidValue;
}

/// The number at `args[arg_index]`, in the width its verb takes. No range is
/// asserted here: a verb whose numbers are bounded has its bound among the fixed
/// values the registry refuses anything else by.
fn numberArg(comptime T: type, args: []const []const u8, arg_index: usize) !T {
    if (arg_index >= args.len) return error.MissingArgument;
    return std.fmt.parseInt(T, args[arg_index], 10) catch error.InvalidValue;
}

// Every verb below reads its own word from `args[0]` and its arguments from
// `args[1..]`: the shape a command's `run` gets, from the daemon and from a
// pushed key binding alike.

/// Swap the focused window with its neighbour in the direction named.
pub fn windowSwap(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const direction = try wordArg(Direction, args, 1);
    try context.yabai.command(context.arena, &.{ "-m", "window", "--swap", direction.name() });
    return "";
}

/// Send the focused window past its neighbour in the direction named, carrying
/// the rest of the tree along instead of changing places with it.
pub fn windowWarp(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const direction = try wordArg(Direction, args, 1);
    try context.yabai.command(context.arena, &.{ "-m", "window", "--warp", direction.name() });
    return "";
}

/// Insert the focused window into the tree beside the window under the mouse, on
/// the side the direction names.
pub fn windowInsert(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const direction = try wordArg(Direction, args, 1);
    try context.yabai.command(context.arena, &.{
        "-m", "window", "mouse", "--insert", direction.name(),
    });
    return "";
}

/// The same insert, then follow the window onto the space the mouse is on.
pub fn windowInsertIntoSpace(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    const direction = try wordArg(Direction, args, 1);
    try context.yabai.command(arena, &.{ "-m", "window", "mouse", "--insert", direction.name() });
    try context.yabai.command(arena, &.{ "-m", "window", "--space", "mouse" });
    return "";
}

/// Insert the focused window into the stack under the mouse, and follow it.
pub fn windowInsertIntoStack(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    const arena = context.arena;
    try context.yabai.command(arena, &.{ "-m", "window", "mouse", "--insert", "stack" });
    try context.yabai.command(arena, &.{ "-m", "window", "--space", "mouse" });
    return "";
}

/// Move the focused window to the display numbered.
pub fn windowToDisplay(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    const argument = try numArg(arena, try numberArg(u8, args, 1));
    try context.yabai.command(arena, &.{ "-m", "window", "--display", argument });
    return "";
}

/// Focus the display numbered.
pub fn displayFocus(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    const argument = try numArg(arena, try numberArg(u8, args, 1));
    try context.yabai.command(arena, &.{ "-m", "display", "--focus", argument });
    return "";
}

/// Move the focused space to the display the direction names.
pub fn spaceToDisplay(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const direction = try wordArg(Direction, args, 1);
    try context.yabai.command(context.arena, &.{
        "-m", "space", "--display", direction.name(),
    });
    return "";
}

/// Set the focused space's layout.
pub fn spaceLayout(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const layout = try wordArg(Layout, args, 1);
    try context.yabai.command(context.arena, &.{ "-m", "space", "--layout", @tagName(layout) });
    return "";
}

/// Rotate the focused space's tree by the degrees given. Any u16 is taken, as it
/// always was, and yabai answers for the rest.
pub fn spaceRotate(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    const argument = try numArg(arena, try numberArg(u16, args, 1));
    try context.yabai.command(arena, &.{ "-m", "space", "--rotate", argument });
    return "";
}

/// Even out the focused space's tree.
pub fn spaceBalance(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    try context.yabai.command(context.arena, &.{ "-m", "space", "--balance" });
    return "";
}

/// Hide every window of the focused space, leaving the space itself up. The one
/// word the verb takes is `show-desktop`, which the registry holds as a fixed
/// value.
pub fn spaceToggleShowDesktop(context: *Context, args: []const []const u8) anyerror![]const u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[1], "show-desktop")) return error.InvalidValue;
    try context.yabai.command(context.arena, &.{ "-m", "space", "--toggle", "show-desktop" });
    return "";
}

/// Focus the window the target names: the previous one, or the next of the
/// focused window's own application.
pub fn windowFocus(context: *Context, args: []const []const u8) anyerror![]const u8 {
    switch (try wordArg(FocusTarget, args, 1)) {
        .recent => try windowFocusRecent(context),
        .same_app => try windowFocusSameApp(context),
    }
    return "";
}

/// Focus the window that had focus before this one.
fn windowFocusRecent(context: *Context) !void {
    try context.yabai.command(context.arena, &.{ "-m", "window", "--focus", "recent" });
}

/// Focus the next window of the focused window's application.
///
/// The focused window is the first entry of yabai's window list and the one
/// wanted is the next entry carrying the same application. An application with
/// one window has no next entry, which is reported as `error.YabaiFailed` for the
/// caller to log and drop.
fn windowFocusSameApp(context: *Context) !void {
    const arena = context.arena;
    const windows = try context.yabai.windows(arena);
    if (windows.len == 0) return error.YabaiFailed;

    const current = windows[0].app;
    for (windows[1..]) |window| {
        if (!std.mem.eql(u8, window.app, current)) continue;
        if (!focusWindow(arena, context.yabai, window.id)) return error.YabaiFailed;
        return;
    }
    return error.YabaiFailed;
}

/// Toggle the window state named.
pub fn windowToggle(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    const toggle = try wordArg(WindowToggle, args, 1);

    // Three toggles chained, in this order: the sticky state of a window that
    // refused to float is not worth reaching for.
    if (toggle == .float_sticky_topmost) {
        try context.yabai.command(arena, &.{ "-m", "window", "--toggle", "float" });
        try context.yabai.command(arena, &.{ "-m", "window", "--toggle", "sticky" });
        try context.yabai.command(arena, &.{ "-m", "window", "--toggle", "topmost" });
        return "";
    }

    const state: []const u8 = switch (toggle) {
        .zoom_fullscreen => "zoom-fullscreen",
        .native_fullscreen => "native-fullscreen",
        .expose => "expose",
        .float_sticky_topmost => unreachable,
    };
    try context.yabai.command(arena, &.{ "-m", "window", "--toggle", state });
    return "";
}

/// Move the focused window onto its display's frame and size it to fill it. The
/// frame's coordinates are cut to whole points before use.
pub fn windowFillDisplay(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    const arena = context.arena;
    const display = try context.yabai.query(yabai.Display, arena, &.{
        "-m", "query", "--displays", "--window",
    });

    const position = try std.fmt.allocPrint(arena, "abs:{d}:{d}", .{
        @as(i64, @intFromFloat(display.frame.x)),
        @as(i64, @intFromFloat(display.frame.y)),
    });
    try context.yabai.command(arena, &.{ "-m", "window", "--move", position });

    const dimensions = try std.fmt.allocPrint(arena, "abs:{d}:{d}", .{
        @as(i64, @intFromFloat(display.frame.w)),
        @as(i64, @intFromFloat(display.frame.h)),
    });
    try context.yabai.command(arena, &.{ "-m", "window", "--resize", dimensions });
    return "";
}

/// Put yabai's own window list on the clipboard.
pub fn copyWindows(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    const arena = context.arena;
    const list = try context.yabai.rawQuery(arena, &.{ "-m", "query", "--windows" });
    const text = try arena.dupeZ(u8, list);
    if (!platform.kx_clipboard_set(text.ptr)) return error.ClipboardUnavailable;
    return "";
}

/// One `wm` verb: the word a client types after `wm`, and the run over its argv.
pub const WmVerb = struct {
    name: []const u8,
    run: *const fn (*Context, []const []const u8) anyerror![]const u8,
};

/// Every verb of `kxdesk wm`, in the order the help lists them. `Sub` carries no
/// run function, so the registry spells these names a second time and a test
/// pins the two lists against each other.
pub const wm_verbs = [_]WmVerb{
    .{ .name = "cycle-space-windows", .run = cycleSpaceWindows },
    .{ .name = "cycle-display-spaces", .run = cycleDisplaySpaces },
    .{ .name = "cycle-displays", .run = cycleDisplays },
    .{ .name = "switch-workspace", .run = switchWorkspace },
    .{ .name = "space-labels", .run = spaceLabels },
    .{ .name = "apply-settings", .run = applySettings },
    .{ .name = "refresh-rules", .run = refreshRules },
    .{ .name = "refresh-signals", .run = refreshSignals },
    .{ .name = "clear-signals", .run = clearSignals },
    .{ .name = "refresh-yabai", .run = refreshYabai },
    .{ .name = "window-swap", .run = windowSwap },
    .{ .name = "window-warp", .run = windowWarp },
    .{ .name = "window-insert", .run = windowInsert },
    .{ .name = "window-insert-space", .run = windowInsertIntoSpace },
    .{ .name = "window-insert-stack-space", .run = windowInsertIntoStack },
    .{ .name = "window-to-display", .run = windowToDisplay },
    .{ .name = "display-focus", .run = displayFocus },
    .{ .name = "space-to-display", .run = spaceToDisplay },
    .{ .name = "space-layout", .run = spaceLayout },
    .{ .name = "space-rotate", .run = spaceRotate },
    .{ .name = "space-balance", .run = spaceBalance },
    .{ .name = "space-toggle", .run = spaceToggleShowDesktop },
    .{ .name = "window-focus", .run = windowFocus },
    .{ .name = "window-toggle", .run = windowToggle },
    .{ .name = "window-fill-display", .run = windowFillDisplay },
    .{ .name = "copy-windows", .run = copyWindows },
};

/// `kxdesk wm <verb> …`: run the verb the first word names.
pub fn wmRun(context: *Context, args: []const []const u8) anyerror![]const u8 {
    if (args.len == 0) return error.MissingArgument;
    for (wm_verbs) |verb| {
        if (std.mem.eql(u8, verb.name, args[0])) return verb.run(context, args);
    }
    return error.UnknownArgument;
}

/// Re-provision everything kxdesk manages on yabai: the rules, then the signals.
/// A failed rules refresh stops the signal refresh, as it always has.
fn refreshYabai(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = try refreshRules(context, args);
    _ = try refreshSignals(context, args);
    return "";
}
