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
const managed_rules = [_][]const []const u8{
    &.{ "-m", "rule", "--add", "label=unmanaged apps", "manage=off", "app=^(Ableton|Blitz|BIAS FX 2|Yousician|ROLI Connect|JetBrains Toolbox|Steam|MTGA|Leader Key)$" },
    &.{ "-m", "rule", "--add", "label=sticky topmost apps", "manage=off", "sticky=on", "app=^System Settings|Vitamin-R 3|Wally|ColorSlurp$" },
    &.{ "-m", "rule", "--add", "label=video and gaming apps in pip mode", "manage=off", "sticky=on", "opacity=1.0", "app=^VLC|mpv$|^(Riot Client)|(League Client)|(League of)|(League Of)" },
    &.{ "-m", "rule", "--add", "label=Teams Notifications", "app=^Microsoft Teams$", "title=^Microsoft Teams Notification$", "manage=off" },
    &.{ "-m", "rule", "--add", "app=^(Slack|kitty)$", "display=^3" },
    &.{ "-m", "rule", "--add", "app=^(Microsoft Outlook|Mail)$", "display=^1" },
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

    // The machine's unfiltered `query --spaces` aborts mid-serialisation (a
    // phantom display), so spaces are enumerated with the filtered per-display
    // query, walking display indexes 1.. until yabai refuses one.
    var focused_display: ?u32 = null;
    var final_focus: ?yabai.Space = null;

    // First pass: which display currently holds focus. Determined globally,
    // before any focusing, as the shell's separate jq pass did.
    var display_index: u32 = 1;
    while (display_index <= max_display_index) : (display_index += 1) {
        const spaces = (try displaySpaces(arena, context.yabai, display_index)) orelse break;
        for (spaces) |space| {
            if (space.@"has-focus") {
                focused_display = space.display;
                break;
            }
        }
        if (focused_display != null) break;
    }

    // Second pass: matches on other displays are focused first, in index
    // order; on the focused display, only the focused match is kept for last
    // (the shell's `.[-1]` after intersecting with that display), and the
    // last so it is the one left focused. The shell ran every focus through
    // one `xargs`, which runs the rest even when one invocation fails and
    // then reports failure - so remember failures instead of aborting.
    var failed = false;
    display_index = 1;
    while (display_index <= max_display_index) : (display_index += 1) {
        const spaces = (try displaySpaces(arena, context.yabai, display_index)) orelse break;
        sort(spaces);

        for (spaces) |space| {
            if (!isSelected(wanted, space.@"label")) continue;

            if (focused_display != null and space.display == focused_display.?) {
                // The shell kept `.[-1]` of this display's matches: focused
                // one when a match holds focus (it sorts last), else the last
                // in index order - both are the last write in this walk.
                final_focus = space;
            } else {
                focusSpace(arena, context.yabai, space.index) catch {
                    failed = true;
                };
            }
        }
    }

    // The focused-display match goes last, so it is the one left focused.
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

    // Same query the shell used - the current display's spaces (this is the
    // one space query that works on this machine, the unfiltered one aborts).
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

/// Upper bound for the per-display enumeration; yabai refuses past the last
/// display, which is what actually ends `switchWorkspace`'s walk.
const max_display_index: u32 = 16;

/// The spaces of display `index`, or null once `index` is past the last
/// display. A refused query ends the walk: yabai prints the reason to stderr
/// and writes nothing to stdout, which surfaces through the client as
/// `InvalidJson` (parsing an empty response) rather than `YabaiFailed`.
fn displaySpaces(arena: std.mem.Allocator, client: *yabai.Client, index: u32) !?[]yabai.Space {
    var buffer: [64]u8 = undefined;
    const index_argument = std.fmt.bufPrint(&buffer, "{d}", .{index}) catch unreachable;
    return client.query([]yabai.Space, arena, &.{ "-m", "query", "--spaces", "--display", index_argument }) catch |err| switch (err) {
        error.YabaiFailed, error.InvalidJson => null,
        else => return err,
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
/// Labels yabai reports as empty are skipped: the shell's unlabeled rules show
/// up with an empty `label`, `--remove ''` is refused, and the shell ignored
/// that failure - so its unlabeled rules survived every refresh, and so do
/// ours (only removing by index would clear them, which the shell never did).
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
