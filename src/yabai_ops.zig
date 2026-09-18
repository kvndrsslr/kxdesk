//! The yabai-touching ports of `~/bin/yabai_util`.
//!
//! The shell piped every query through `jq` and spawned `yabai` once per
//! mutation, relying on `||` chains between them: yabai exits non-zero for a
//! command it refuses, and those chains are the fallback logic. `Client.command`
//! errors on a non-zero exit, so each `||` maps to a `catch` here. Anything the
//! shell shaped with jq - sorting spaces, extracting labels by predicate - is a
//! typed query plus a loop instead.

const std = @import("std");

const commands = @import("commands.zig");
const exec = @import("exec.zig");
const platform = @import("platform.zig");
const yabai = @import("yabai.zig");

const Context = commands.Context;

/// One `rule --add`, complete: the exact argv tokens, spaces inside tokens
/// exactly as the shell passed them - quoting them differently would change
/// what yabai matches.
///
/// Every rule carries a label, including the two the shell left unlabelled: a
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
const managed_signals = [_][]const []const u8{
    &.{ "-m", "signal", "--add", "event=window_title_changed", "label=sb_atc", "action=sketchybar --trigger yabai_update ONLY=title YABAI_WINDOW_ID=$YABAI_WINDOW_ID", "active=yes" },
    &.{ "-m", "signal", "--add", "event=window_focused", "label=sb_wf", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=space_changed", "label=sb_sc", "action=sketchybar --trigger yabai_update" },
    &.{ "-m", "signal", "--add", "event=window_created", "app=Telegram", "label=telegram-display-enforcement", "action=zsh -c \"sleep 1.5 && yabai -m window $YABAI_WINDOW_ID --display 1 --focus\"" },
};

/// Every setting kxdesk asserts on yabai, in the order `~/.yabairc` set them.
///
/// Flat `key, value, key, value`, because that is the shape `yabai -m config`
/// reads, and the whole table has to reach yabai in one invocation: the shell
/// spawned a `yabai` per setting - twenty-three processes and about 460 ms here,
/// against 77 ms for the one - so these are batched.
///
/// Settings that file had commented out are not here: they were off.
const settings = [_][]const u8{
    "mouse_follows_focus",     "off",
    "focus_follows_mouse",     "off",
    "window_placement",        "second_child",
    "window_shadow",           "off",
    "skip_window_focus_animation", "on",
    "window_opacity",          "off",
    "active_window_opacity",   "0.97",
    "normal_window_opacity",   "0.93",
    "insert_feedback_color",   "0xffd75f5f",
    "split_ratio",             "0.50",
    "auto_balance",            "off",
    "mouse_modifier",          "fn",
    "mouse_action1",           "move",
    "mouse_action2",           "resize",
    "mouse_drop_action",       "swap",
    "layout",                  "stack",
    "top_padding",             "0",
    "bottom_padding",          "0",
    "left_padding",            "0",
    "right_padding",           "0",
    "window_gap",              "3",
    "external_bar",            "all:26:0",
    "display_arrangement_order", "horizontal",
    "debug_output",            "on",
};

/// `yabai -m config` followed by every setting: one argument vector, one
/// process, however many settings there are.
const settings_argv = [_][]const u8{ "-m", "config" } ++ settings;

/// Assert everything kxdesk manages on yabai: every setting, then every rule,
/// then every signal.
///
/// One command, because `~/.yabairc` wants all three and this way it is one
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
/// managed ones, in the shell's order. An empty `--list` is not an error, as
/// the shell's `xargs` over empty input also succeeded; failed removals did
/// not stop its adds either (they continued and its status was the last add's).
pub fn refreshRules(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    const arena = context.arena;

    const listed = try context.yabai.query([]yabai.Labeled, arena, &.{ "-m", "rule", "--list" });
    for (listed) |rule| removeByLabel(arena, context.yabai, "rule", rule.@"label") catch {};

    // zsh keeps going after a failed add (no `set -e`) and the function's exit
    // is the last add's status. On this machine the `display=^3` rule can
    // never be added - yabai locates no display with arrangement index 3 -
    // and the shell still exited 0 because the final add succeeded.
    var last_add: anyerror!void = {};
    for (managed_rules) |rule| {
        last_add = context.yabai.command(arena, rule);
    }
    try last_add;
    return "";
}

/// Re-provision the yabai signals: clear, then add the four that survive the
/// migration. The shell's fifth (`kme`) only ran a command that is not ported.
pub fn refreshSignals(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    try clearSignalsInner(context, true);

    const arena = context.arena;
    // Same last-add-status semantics as `refreshRules`: the telegram add was
    // the shell's final statement, and only its status reached the caller.
    var last_add: anyerror!void = {};
    for (managed_signals) |signal| {
        last_add = context.yabai.command(arena, signal);
    }
    try last_add;
    return "";
}

/// Drop every configured yabai signal. Removing nothing is not an error, as
/// the shell's `xargs` over an empty list also succeeded.
pub fn clearSignals(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    try clearSignalsInner(context, false);
    return "";
}

/// Shared by `refreshSignals` and `clearSignals`. As a provisioner the shell
/// tolerated failed removals among its adds; standalone it did not.
fn clearSignalsInner(context: *Context, tolerate_removal_failure: bool) !void {
    const arena = context.arena;

    const listed = try context.yabai.query([]yabai.Labeled, arena, &.{ "-m", "signal", "--list" });
    for (listed) |signal| {
        removeByLabel(arena, context.yabai, "signal", signal.@"label") catch |err| {
            if (!tolerate_removal_failure) return err;
        };
    }
}

/// Focus a set of spaces named by label, leaving a member of the group on the
/// currently focused display for last, so that is where focus lands.
///
/// `args[0]` is a comma-separated list of labels, which the skhd binding passes
/// with embedded double quotes (`"stonks","pkms","gtd"`); strip those, and
/// tolerate labels that arrive unquoted. A label matching no space is simply
/// absent, and nothing to focus at all is not an error - the shell piped an
/// empty list through `xargs -I {}` and exited 0. Degenerate case it did not
/// handle and neither does this: no match on the focused display.
pub fn switchWorkspace(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    if (args.len == 0) return error.MissingArgument;

    const wanted = parseLabels(args[0], arena);

    // The spaces of every display, asked for one display at a time and kept: the
    // command passes over them twice, and a query per pass would double the
    // processes it spawns. The displays themselves come from a display query
    // rather than from counting upwards, so a machine whose arrangement has a
    // gap cannot hide a display above it.
    const displays = displayList(arena, context.yabai);
    const per_display = try arena.alloc([]yabai.Space, displays.len);
    for (displays, 0..) |display, position| {
        per_display[position] = spacesOf(arena, context.yabai, display.index);
    }

    // Which display decides the order: the shell took `sort_by(."has-focus") |
    // .[-1].display` over every space, so it is the one holding the highest-index
    // space that has focus, not the first display that has one. Determined before
    // anything is focused, as the shell's separate pass did.
    var focused_display: ?u32 = null;
    for (per_display) |spaces| {
        for (spaces) |space| {
            if (space.@"has-focus") focused_display = space.display;
        }
    }

    // The shell's two lists, run through one `xargs` in this order: matches on the
    // other displays are focused first, in index order, and the deciding display's
    // matches are left for last - the one that is chosen is the one left focused.
    // A focus that fails is remembered rather than aborting: `xargs` ran the rest
    // and then reported the failure, which is this command's exit status.
    var final_focus: ?yabai.Space = null;
    var failed = false;
    for (per_display) |spaces| {
        sort(spaces);

        for (spaces) |space| {
            if (!isSelected(wanted, space.@"label")) continue;

            if (focused_display != null and space.display == focused_display.?) {
                // `.[-1]` of `sort_by(."has-focus")` over this display's matches:
                // a match that holds focus sorts last and so wins, and otherwise
                // the last match in index order does.
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

    // The deciding display's match goes last, so it is the one left focused.
    if (final_focus) |space| {
        focusSpace(arena, context.yabai, space.index) catch {
            failed = true;
        };
    }
    if (failed) return error.YabaiFailed;
    return "";
}

/// Cycle focus through the windows of the current space: stack first, then
/// plain order. First success wins; the shell ended the chain with `exit 0`,
/// so even a cycle with nothing to focus succeeds.
pub fn cycleSpaceWindows(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;

    const attempts: []const []const []const u8 = if (hasFlag(args, "--reverse"))
        &.{
            &.{ "-m", "window", "--focus", "stack.prev" },
            &.{ "-m", "window", "--focus", "stack.last" },
            &.{ "-m", "window", "--focus", "prev" },
            &.{ "-m", "window", "--focus", "last" },
        }
    else
        &.{
            &.{ "-m", "window", "--focus", "stack.next" },
            &.{ "-m", "window", "--focus", "stack.first" },
            &.{ "-m", "window", "--focus", "next" },
            &.{ "-m", "window", "--focus", "first" },
        };

    for (attempts) |argv| {
        context.yabai.command(arena, argv) catch continue;
        return "";
    }
    return "";
}

/// Move focus to the neighbouring space on the current display, falling back
/// to skhd's key emulation for the native-fullscreen spaces yabai cannot focus.
pub fn cycleDisplaySpaces(context: *Context, args: []const []const u8) anyerror![]const u8 {
    const arena = context.arena;
    const reverse = hasFlag(args, "--reverse");

    // The current display's spaces, which is the scope this command works on.
    const spaces = try context.yabai.query([]yabai.Space, arena, &.{ "-m", "query", "--spaces", "--display" });
    if (spaces.len == 0) return error.YabaiFailed;

    sort(spaces);

    // The shell's selector: `nth(index(focused) - 1)` into `sort_by(.index)`,
    // reversed when going forward. jq's negative index wraps, so the net
    // effect is next with wrap-around forward, previous with wrap-around
    // reversed, and a self-focus cycle on a one-space display.
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
        // jq's `index` misses (`null - 1 == -1`): `nth(-1)` of the array -
        // its last element forward, its first reversed.
        break :blk if (reverse) spaces[0] else spaces[spaces.len - 1];
    };

    var buffer: [64]u8 = undefined;
    const index_argument = std.fmt.bufPrint(&buffer, "{d}", .{neighbor.index}) catch unreachable;
    context.yabai.command(arena, &.{ "-m", "space", "--focus", index_argument }) catch |err| switch (err) {
        // Native-fullscreen spaces refuse to be focused by yabai (and so does
        // re-focusing the current one); the shell fell through to emulating
        // Mission Control's shortcut, and its status was the fallback's.
        error.YabaiFailed => {
            try skhdArrow(context, if (reverse) "left" else "right");
            return "";
        },
        else => return err,
    };
    return "";
}

/// Every labelled space, one label per line, in index order.
///
/// This is what a completion offers for `switch_workspace`, and it is worth
/// having on its own: the labels are what a binding passes, and they exist
/// nowhere but in yabai's answer.
pub fn spaceLabels(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;
    const arena = context.arena;

    const spaces = try context.yabai.query([]yabai.Space, arena, &.{ "-m", "query", "--spaces" });
    sort(spaces);

    var labels = std.ArrayList([]const u8).empty;
    for (spaces) |space| {
        if (space.@"label".len == 0) continue;
        // A label may be on more than one space; it is offered once.
        if (isSelected(labels.items, space.@"label")) continue;
        try labels.append(arena, space.@"label");
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
        std.debug.print("kxdesk: yabai query failed: {s}\n", .{@errorName(err)});
        break :blk client.query([]yabai.Display, arena, &.{
            "-m", "query", "--displays", "--display",
        }) catch &.{};
    };
}

/// The spaces of one display, or none when yabai will not answer for it: the
/// caller remembers that a focus was missed, as the shell's `xargs` reported
/// failure for the invocations that failed while running the ones that did not.
fn spacesOf(arena: std.mem.Allocator, client: *yabai.Client, display: u32) []yabai.Space {
    var buffer: [16]u8 = undefined;
    const index = std.fmt.bufPrint(&buffer, "{d}", .{display}) catch unreachable;
    return client.query([]yabai.Space, arena, &.{ "-m", "query", "--spaces", "--display", index }) catch |err| blk: {
        std.debug.print("kxdesk: yabai query failed: {s}\n", .{@errorName(err)});
        break :blk &.{};
    };
}

/// Ascending space index, the shell's `sort_by(.index)`.
fn sort(spaces: []yabai.Space) void {
    std.mem.sort(yabai.Space, spaces, {}, lessThanIndex);
}

fn lessThanIndex(_: void, a: yabai.Space, b: yabai.Space) bool {
    return a.index < b.index;
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
    var buffer: [64]u8 = undefined;
    const argument = std.fmt.bufPrint(&buffer, "{d}", .{index}) catch unreachable;
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

/// Split the comma-separated label list, stripping the double quotes the skhd
/// binding embeds. Empty labels are dropped, so a trailing comma is harmless.
fn parseLabels(input: []const u8, arena: std.mem.Allocator) []const []const u8 {
    var labels = std.ArrayList([]const u8).empty;
    var iterator = std.mem.splitScalar(u8, input, ',');
    while (iterator.next()) |raw| {
        const stripped = std.mem.trim(u8, raw, "\"");
        if (stripped.len > 0) labels.append(arena, stripped) catch return &.{};
    }
    return labels.items;
}

/// Emulate a Mission Control arrow key through skhd: the fallback the shell
/// reached for whenever yabai refused a neighbouring-space focus.
fn skhdArrow(context: *Context, direction: []const u8) !void {
    const skhd = try exec.path(context.arena, "skhd");
    const key = try std.fmt.allocPrintSentinel(context.arena, "ctrl - {s}", .{direction}, 0);
    const vector = [_:null]?[*:0]const u8{ skhd.ptr, "-k", key.ptr, null };
    if (platform.sb_exec_status(&vector) != 0) return error.YabaiFailed;
}
