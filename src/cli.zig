//! The command line as the outside sees it: `--help`, `help <command>`, and the
//! shell completions.
//!
//! Nothing here restates the command table. It is read out of `commands.zig`, so
//! a command that is added, renamed, or given an argument documents and completes
//! itself; the two commands this binary answers itself live in the same table,
//! next to the daemon's, and are treated identically.
//!
//! Completions are computed here rather than in each shell: the generated script
//! is a few lines that hand the words to `kxdesk __complete` and print what comes
//! back. That keeps one description of the command line instead of four, and a
//! shell never has to be regenerated when a command changes.

const std = @import("std");

const commands = @import("commands.zig");

const Allocator = std.mem.Allocator;
const Command = commands.Command;
const ArrayList = std.ArrayList;

/// What every usage line starts with.
pub const program = "kxdesk";

/// The shells `completions` can emit for. Fish is left out on purpose: it is not
/// installed here, and an unexercised script is worse than none.
pub const shells = [_][]const u8{ "zsh", "bash" };

/// The commands this binary answers itself. Same shape as the daemon's, so
/// `--help` and the completions treat them alike; `run` stays null, because the
/// daemon is never asked about them.
const local = [_]Command{
    .{
        .name = "help",
        .summary = "describe a command, or list them all",
        .args = &.{.{
            .name = "[<command>]",
            .summary = "the command to describe",
            .commands = true,
        }},
    },
    .{
        .name = "completions",
        .summary = "print a shell completion script",
        .args = &.{.{
            .name = "<shell>",
            .summary = "the shell to emit for",
            .values = &shells,
        }},
    },
};

/// Everything a client can spell: the daemon's commands, then this binary's.
pub const registry = commands.all ++ local;

/// The command called `name`, or null.
pub fn find(name: []const u8) ?Command {
    for (registry) |command| {
        if (std.mem.eql(u8, command.name, name)) return command;
    }
    return null;
}

// -- help -------------------------------------------------------------------

/// The list `--help` prints: every command, one line each.
pub fn overview(arena: Allocator) Allocator.Error![]const u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(arena);

    try out.appendSlice(arena, program ++ " - personal desktop daemon\n\nusage: " ++ program ++ " <command> [arguments...]\n\ncommands:\n");

    var width: usize = 0;
    for (registry) |command| width = @max(width, command.name.len);

    for (registry) |command| {
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, command.name);
        try pad(&out, arena, width - command.name.len + 2);
        try out.appendSlice(arena, command.summary);
        try out.append(arena, '\n');
    }

    try out.appendSlice(arena, "\n`" ++ program ++ " help <command>` describes one of them, and `--help` after\nany command does the same. `" ++ program ++ " completions <shell>` prints\ncompletions for ");
    try out.appendSlice(arena, try shellList(arena));
    try out.append(arena, '.');
    return out.toOwnedSlice(arena);
}

/// The shells, spelled out the way prose lists them: "zsh or bash".
pub fn shellList(arena: Allocator) Allocator.Error![]const u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(arena);

    for (shells, 0..) |shell, position| {
        if (position != 0) {
            try out.appendSlice(arena, if (position + 1 == shells.len) " or " else ", ");
        }
        try out.appendSlice(arena, shell);
    }
    return out.toOwnedSlice(arena);
}

/// Everything there is to say about one command: what it does, how it is
/// spelled, and what each of its arguments is.
pub fn describe(arena: Allocator, command: Command) Allocator.Error![]const u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(arena);

    try out.appendSlice(arena, command.name);
    try out.appendSlice(arena, " - ");
    try out.appendSlice(arena, command.summary);
    try out.appendSlice(arena, "\n\nusage: ");
    try appendUsage(&out, arena, command);
    try out.append(arena, '\n');

    if (command.subcommands.len != 0) {
        var width: usize = 0;
        for (command.subcommands) |sub| width = @max(width, subUsageLen(sub));

        try out.appendSlice(arena, "\nsubcommands:\n");
        for (command.subcommands) |sub| {
            try out.appendSlice(arena, "  ");
            try appendSubUsage(&out, arena, sub);
            try pad(&out, arena, width - subUsageLen(sub) + 2);
            try out.appendSlice(arena, sub.summary);
            try out.append(arena, '\n');
        }
    }

    try appendArgs(&out, arena, command);
    try appendFlags(&out, arena, command);

    // One trailing newline belongs to the caller (`emit` adds it), not here, so
    // the last line is the last thing said.
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    return out.toOwnedSlice(arena);
}

/// `usage: kxdesk pomodoro [start [<minutes>] | pause | ...]`, exactly as the
/// table spells it.
fn appendUsage(out: *ArrayList(u8), arena: Allocator, command: Command) Allocator.Error!void {
    try out.appendSlice(arena, program);
    try out.append(arena, ' ');
    try out.appendSlice(arena, command.name);

    if (command.subcommands.len != 0) {
        try out.appendSlice(arena, " [");
        for (command.subcommands, 0..) |sub, position| {
            if (position != 0) try out.appendSlice(arena, " | ");
            try appendSubUsage(out, arena, sub);
        }
        try out.append(arena, ']');
    } else {
        for (command.args) |arg| {
            try out.append(arena, ' ');
            try out.appendSlice(arena, arg.name);
        }
    }

    for (command.flags) |flag| {
        try out.appendSlice(arena, " [");
        try out.appendSlice(arena, flag.name);
        try out.append(arena, ']');
    }
}

fn appendSubUsage(out: *ArrayList(u8), arena: Allocator, sub: commands.Sub) Allocator.Error!void {
    try out.appendSlice(arena, sub.name);
    for (sub.args) |arg| {
        try out.append(arena, ' ');
        try out.appendSlice(arena, arg.name);
    }
    for (sub.flags) |flag| {
        try out.appendSlice(arena, " [");
        try out.appendSlice(arena, flag.name);
        try out.append(arena, ']');
    }
}

fn subUsageLen(sub: commands.Sub) usize {
    var length = sub.name.len;
    for (sub.args) |arg| length += 1 + arg.name.len;
    // Two for the brackets around each flag, and one for the space before it.
    for (sub.flags) |flag| length += flag.name.len + 3;
    return length;
}

/// The arguments of the command and of each of its subcommands, each name
/// described once: `<key>` is one thing, whether `get`, `set` or `unset` reads
/// it.
fn appendArgs(out: *ArrayList(u8), arena: Allocator, command: Command) Allocator.Error!void {
    var written = false;
    var seen = ArrayList([]const u8).empty;
    defer seen.deinit(arena);

    var width: usize = 0;
    for (command.args) |arg| width = @max(width, arg.name.len);
    for (command.subcommands) |sub| for (sub.args) |arg| {
        width = @max(width, arg.name.len);
    };

    try offerArgs(out, arena, command.args, &seen, &written, width);
    for (command.subcommands) |sub| {
        try offerArgs(out, arena, sub.args, &seen, &written, width);
    }
}

fn offerArgs(
    out: *ArrayList(u8),
    arena: Allocator,
    args: []const commands.Arg,
    seen: *ArrayList([]const u8),
    written: *bool,
    width: usize,
) Allocator.Error!void {
    for (args) |arg| {
        if (contains(seen.items, arg.name)) continue;
        try seen.append(arena, arg.name);

        if (!written.*) {
            try out.appendSlice(arena, "\narguments:\n");
            written.* = true;
        }
        try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, arg.name);
        try pad(out, arena, width - arg.name.len + 2);
        try out.appendSlice(arena, arg.summary);
        try out.append(arena, '\n');
    }
}

/// The command's flags and its subcommands', each described once, plus `--help`,
/// which every command takes.
fn appendFlags(out: *ArrayList(u8), arena: Allocator, command: Command) Allocator.Error!void {
    var seen = ArrayList([]const u8).empty;
    defer seen.deinit(arena);

    var width: usize = "--help".len;
    for (command.flags) |flag| width = @max(width, flag.name.len);
    for (command.subcommands) |sub| for (sub.flags) |flag| {
        width = @max(width, flag.name.len);
    };

    try out.appendSlice(arena, "\nflags:\n");
    try offerFlagsAll(out, arena, command.flags, &seen, width);
    for (command.subcommands) |sub| {
        try offerFlagsAll(out, arena, sub.flags, &seen, width);
    }
    try offerFlag(out, arena, .{ .name = "--help", .summary = "show this" }, &seen, width);
}

fn offerFlagsAll(
    out: *ArrayList(u8),
    arena: Allocator,
    flags: []const commands.Flag,
    seen: *ArrayList([]const u8),
    width: usize,
) Allocator.Error!void {
    for (flags) |flag| try offerFlag(out, arena, flag, seen, width);
}

fn offerFlag(
    out: *ArrayList(u8),
    arena: Allocator,
    flag: commands.Flag,
    seen: *ArrayList([]const u8),
    width: usize,
) Allocator.Error!void {
    if (contains(seen.items, flag.name)) return;
    try seen.append(arena, flag.name);

    try out.appendSlice(arena, "  ");
    try out.appendSlice(arena, flag.name);
    try pad(out, arena, width - flag.name.len + 2);
    try out.appendSlice(arena, flag.summary);
    try out.append(arena, '\n');
}

fn pad(out: *ArrayList(u8), arena: Allocator, count: usize) Allocator.Error!void {
    for (0..count) |_| try out.append(arena, ' ');
}

// -- completions ------------------------------------------------------------

/// The words that may follow what has been typed, one per line and nothing when
/// there is nothing to offer.
///
/// `words` are the words after the program name, and `cword` is the index within
/// them of the word being completed. It may be one past the end of `words`,
/// because a shell whose line ends in a space may or may not hand over the empty
/// word; both spell the same request, so both are read the same way.
pub fn complete(arena: Allocator, cword: usize, words: []const []const u8) Allocator.Error![]const u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(arena);

    const partial = if (cword < words.len) words[cword] else "";
    const typed = words[0..@min(cword, words.len)];

    if (typed.len == 0) {
        for (registry) |command| try offer(&out, arena, partial, command.name);
        try offer(&out, arena, partial, "--help");
        try offer(&out, arena, partial, "--version");
        return out.toOwnedSlice(arena);
    }

    const command = find(typed[0]) orelse return out.toOwnedSlice(arena);
    var rest = typed[1..];

    var args: []const commands.Arg = command.args;
    var flags: []const commands.Flag = command.flags;

    if (command.subcommands.len != 0) {
        // Either the subcommand is still being chosen, or a flag came first and
        // only flags can be offered until one is.
        if (rest.len == 0 or isFlag(rest[0])) {
            if (rest.len == 0) {
                for (command.subcommands) |sub| try offer(&out, arena, partial, sub.name);
            }
            try offerFlags(&out, arena, partial, command.flags, rest);
            return out.toOwnedSlice(arena);
        }
        const sub = findSub(command, rest[0]) orelse return out.toOwnedSlice(arena);
        args = sub.args;
        flags = sub.flags;
        rest = rest[1..];
    }

    var position: usize = 0;
    for (rest) |word| {
        if (isFlag(word)) continue;
        position += 1;
    }

    if (position < args.len) {
        const arg = args[position];
        if (arg.commands) {
            for (registry) |each| try offer(&out, arena, partial, each.name);
        } else for (arg.values) |value| {
            try offer(&out, arena, partial, value);
        }
    }
    try offerFlags(&out, arena, partial, flags, rest);

    return out.toOwnedSlice(arena);
}

fn offerFlags(
    out: *ArrayList(u8),
    arena: Allocator,
    partial: []const u8,
    flags: []const commands.Flag,
    used: []const []const u8,
) Allocator.Error!void {
    for (flags) |flag| {
        if (contains(used, flag.name)) continue;
        try offer(out, arena, partial, flag.name);
    }
    if (!contains(used, "--help")) try offer(out, arena, partial, "--help");
}

fn offer(
    out: *ArrayList(u8),
    arena: Allocator,
    partial: []const u8,
    candidate: []const u8,
) Allocator.Error!void {
    if (!std.mem.startsWith(u8, candidate, partial)) return;
    try out.appendSlice(arena, candidate);
    try out.append(arena, '\n');
}

fn findSub(command: Command, name: []const u8) ?commands.Sub {
    for (command.subcommands) |sub| {
        if (std.mem.eql(u8, sub.name, name)) return sub;
    }
    return null;
}

fn isFlag(word: []const u8) bool {
    return word.len > 0 and word[0] == '-';
}

fn contains(words: []const []const u8, wanted: []const u8) bool {
    for (words) |word| {
        if (std.mem.eql(u8, word, wanted)) return true;
    }
    return false;
}

/// A shell's completion script, or null for a shell this does not speak.
///
/// Each script is a few lines that hand the words to `kxdesk __complete` and
/// print the answer, so all of the knowledge stays in `complete` above and no
/// shell has to be regenerated when a command changes. The word index is passed
/// explicitly rather than reconstructed, because a shell whose line ends in a
/// space may or may not hand over the empty word and the index says which.
pub fn script(shell: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, shell, "zsh")) return zsh;
    if (std.mem.eql(u8, shell, "bash")) return bash;
    return null;
}

/// zsh completes with `words` 1-based and holding the program name, so the word
/// being completed is `CURRENT` and its index among the words after the program
/// name is `CURRENT - 2`.
const zsh =
    \\#compdef kxdesk
    \\# kxdesk completions for zsh, from `kxdesk completions zsh`.
    \\#
    \\# Install by evaluating it in your shell startup:
    \\#   eval "$(kxdesk completions zsh)"
    \\# or write it where completion functions are found:
    \\#   kxdesk completions zsh > ~/.zsh/completions/_kxdesk
    \\
    \\_kxdesk() {
    \\  local -a candidates
    \\  candidates=(${(f)"$(kxdesk __complete $((CURRENT - 2)) "${(@)words[2,CURRENT]}")"})
    \\  compadd -a candidates
    \\}
    \\
    \\compdef _kxdesk kxdesk
    \\
;

/// bash keeps `COMP_WORDS` 0-based with the program name at 0, so the word being
/// completed is `COMP_CWORD` and its index among the words after the program name
/// is `COMP_CWORD - 1`.
const bash =
    \\# kxdesk completions for bash, from `kxdesk completions bash`.
    \\#
    \\# Install by evaluating it in your shell startup:
    \\#   eval "$(kxdesk completions bash)"
    \\
    \\_kxdesk() {
    \\  local IFS=$'\n'
    \\  local candidates
    \\  candidates=($(kxdesk __complete $((COMP_CWORD - 1)) "${COMP_WORDS[@]:1}"))
    \\  COMPREPLY=("${candidates[@]}")
    \\}
    \\
    \\complete -F _kxdesk kxdesk
    \\
;
