//! The command line as the outside sees it: the help, the completions, and the
//! check that a request is spelled the way the command says it is.
//!
//! Nothing here restates the command table: it is read out of `commands.zig`, so
//! a command documents itself, completes itself, and is validated against its own
//! description. Completions are computed here rather than in each shell, which is
//! what lets a candidate carry what it does alongside its name - and lets a value
//! that only exists at runtime, such as a state key, be offered at all.

const std = @import("std");

const commands = @import("commands.zig");
const control = @import("control.zig");
const kitty = @import("kitty.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Command = commands.Command;

/// What every usage line starts with.
pub const program = "kxdesk";

/// The shells `completions` can emit for. Fish is left out on purpose: it is not
/// installed here, and an unexercised script is worse than none.
pub const shells = [_][]const u8{ "zsh", "bash" };

/// The commands this binary answers itself, in the daemon's shape so the help,
/// the completions and the validation treat them alike; `run` stays null, because
/// the daemon is never asked about them.
const local = [_]Command{
    .{
        .name = "help",
        .summary = "describe a command, or list them all",
        .args = &.{.{
            .name = "[<command>]",
            .summary = "the command to describe",
            .source = .commands,
        }},
    },
    .{
        .name = "completions",
        .summary = "print a shell completion script",
        .args = &.{.{
            .name = "<shell>",
            .summary = "the shell to emit for",
            .source = .fixed,
            .values = &shells,
        }},
    },
};

/// Everything a client can spell: the daemon's commands, then this binary's.
pub const registry = commands.all ++ local;

/// The command called `name`, this binary's or the daemon's, or null.
pub fn find(name: []const u8) ?Command {
    const index = commands.indexIn(&registry, name) orelse return null;
    return registry[index];
}

/// What a command's own arguments and flags are, once its subcommand - named or
/// defaulted - is known.
const Spec = struct {
    args: []const commands.Arg,
    flags: []const commands.Flag,
    sub: ?commands.Sub = null,
};

fn specOf(command: Command, sub: ?commands.Sub) Spec {
    return if (sub) |chosen|
        .{ .args = chosen.args, .flags = chosen.flags, .sub = chosen }
    else
        .{ .args = command.args, .flags = command.flags };
}

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
            if (sub.default) try out.appendSlice(arena, " (default)");
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

/// `kxdesk state set <key> [<value>]`: one command spelled out the way the
/// problem message for it has to be run.
fn appendInvocation(out: *ArrayList(u8), arena: Allocator, command: Command, spec: Spec) Allocator.Error!void {
    try out.appendSlice(arena, program);
    try out.append(arena, ' ');
    try out.appendSlice(arena, command.name);

    if (spec.sub) |sub| {
        try out.append(arena, ' ');
        try appendSubUsage(out, arena, sub);
        return;
    }
    for (spec.args) |arg| {
        try out.append(arena, ' ');
        try out.appendSlice(arena, arg.name);
    }
    for (spec.flags) |flag| {
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

/// Check `args` against the command's own description, returning null when the
/// request fits or a message naming what was expected and how the command is
/// spelled.
///
/// Only `--`-prefixed words are flags, so a value may begin with one dash -
/// `state set level -5`, `set_mode_indicator -` - and flags are refused before
/// arguments, which a command reads by position.
pub fn validate(
    arena: Allocator,
    io: std.Io,
    command: Command,
    args: []const []const u8,
) Allocator.Error!?[]const u8 {
    var rest = args;
    var spec = specOf(command, null);

    if (command.subcommands.len != 0) {
        if (rest.len == 0) {
            const chosen = defaultSub(command) orelse
                return try problem(arena, command, spec, "a subcommand is required");
            spec = specOf(command, chosen);
        } else if (isFlag(rest[0])) {
            return try problem(arena, command, spec, "expected a subcommand, not a flag");
        } else {
            const chosen = findSub(command, rest[0]) orelse {
                const detail = try std.fmt.allocPrint(arena, "no subcommand named '{s}'", .{rest[0]});
                return try problem(arena, command, spec, detail);
            };
            spec = specOf(command, chosen);
            rest = rest[1..];
        }
    }

    var positionals = ArrayList([]const u8).empty;
    var after_flag = false;
    for (rest) |word| {
        if (isFlag(word)) {
            if (!declares(spec.flags, word)) {
                const detail = try std.fmt.allocPrint(arena, "unknown flag '{s}'", .{word});
                return try problem(arena, command, spec, detail);
            }
            after_flag = true;
            continue;
        }
        if (after_flag) {
            const detail = try std.fmt.allocPrint(arena, "unexpected argument '{s}' after a flag", .{word});
            return try problem(arena, command, spec, detail);
        }
        try positionals.append(arena, word);
    }

    const required = requiredArgs(spec.args);
    if (positionals.items.len < required) {
        const detail = try std.fmt.allocPrint(arena, "missing {s}", .{spec.args[positionals.items.len].name});
        return try problem(arena, command, spec, detail);
    }
    if (positionals.items.len > spec.args.len) {
        const detail = try std.fmt.allocPrint(
            arena,
            "unexpected argument '{s}'",
            .{positionals.items[spec.args.len]},
        );
        return try problem(arena, command, spec, detail);
    }

    for (positionals.items, spec.args) |value, argument| {
        switch (argument.source) {
            .fixed => if (argument.values.len > 0 and !contains(argument.values, value)) {
                const detail = try std.fmt.allocPrint(
                    arena,
                    "{s} is not one of: {s}",
                    .{ argument.name, try std.mem.join(arena, ", ", argument.values) },
                );
                return try problem(arena, command, spec, detail);
            },
            .commands => if (find(value) == null) {
                const detail = try std.fmt.allocPrint(arena, "no such command '{s}'", .{value});
                return try problem(arena, command, spec, detail);
            },
            .terminals => if (!kitty.configured(io, value)) {
                const names = kitty.names(io, arena);
                const detail = if (names.len == 0)
                    try std.fmt.allocPrint(arena, "no quick access terminal named '{s}'", .{value})
                else
                    try std.fmt.allocPrint(
                        arena,
                        "no quick access terminal named '{s}'; configured: {s}",
                        .{ value, try std.mem.join(arena, ", ", names) },
                    );
                return try problem(arena, command, spec, detail);
            },
            .free, .state_keys, .space_labels => {},
        }
    }
    return null;
}

/// `state set: missing <key>` and the line to run.
fn problem(
    arena: Allocator,
    command: Command,
    spec: Spec,
    detail: []const u8,
) Allocator.Error![]const u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(arena);

    try out.appendSlice(arena, command.name);
    if (spec.sub) |sub| {
        try out.append(arena, ' ');
        try out.appendSlice(arena, sub.name);
    }
    try out.appendSlice(arena, ": ");
    try out.appendSlice(arena, detail);
    try out.appendSlice(arena, "\nusage: ");
    try appendInvocation(&out, arena, command, spec);
    return out.toOwnedSlice(arena);
}

/// How many arguments a command will not run without: the ones whose name is not
/// bracketed.
fn requiredArgs(args: []const commands.Arg) usize {
    var count: usize = 0;
    for (args) |argument| {
        char: {
            if (argument.name.len == 0 or argument.name[0] != '[') break :char;
            continue;
        }
        count += 1;
    }
    return count;
}

fn defaultSub(command: Command) ?commands.Sub {
    for (command.subcommands) |sub| {
        if (sub.default) return sub;
    }
    return null;
}

fn declares(flags: []const commands.Flag, name: []const u8) bool {
    for (flags) |flag| {
        if (std.mem.eql(u8, flag.name, name)) return true;
    }
    return false;
}

/// The words that may follow what has been typed, one per line, and nothing when
/// there is nothing to offer.
///
/// `described` adds a tab and what each candidate does, for a shell that has
/// somewhere to show it; it is opt-in because the script that asks and the binary
/// that answers are installed separately and can be out of step. `words` are the
/// words after the program name, and `cword` is the index within them of the word
/// being completed - which may be one past the end, since a shell whose line ends
/// in a space may or may not hand over the empty word.
pub fn complete(
    arena: Allocator,
    io: std.Io,
    described: bool,
    cword: usize,
    words: []const []const u8,
) Allocator.Error![]const u8 {
    const text = try candidates(arena, io, cword, words);
    if (described) return text;

    // In place, because the descriptions are already written and only the tail
    // of each line is being given up.
    return text[0..undescribed(text)];
}

/// Every candidate, each with what it does after a tab.
fn candidates(
    arena: Allocator,
    io: std.Io,
    cword: usize,
    words: []const []const u8,
) Allocator.Error![]u8 {
    var out = ArrayList(u8).empty;
    errdefer out.deinit(arena);

    const partial = if (cword < words.len) words[cword] else "";
    const typed = words[0..@min(cword, words.len)];

    if (typed.len == 0) {
        for (registry) |command| try offer(&out, arena, partial, command.name, command.summary);
        try offer(&out, arena, partial, "--help", "show the help");
        try offer(&out, arena, partial, "--version", "print the version");
        return out.toOwnedSlice(arena);
    }

    const command = find(typed[0]) orelse return out.toOwnedSlice(arena);
    var rest = typed[1..];
    var spec = specOf(command, null);

    if (command.subcommands.len != 0) {
        // Either the subcommand is still being chosen, or a flag came first and
        // only flags can be offered until one is.
        if (rest.len == 0 or isFlag(rest[0])) {
            if (rest.len == 0) {
                for (command.subcommands) |sub| try offer(&out, arena, partial, sub.name, sub.summary);
            }
            try offerFlags(&out, arena, partial, command.flags, rest);
            return out.toOwnedSlice(arena);
        }
        const sub = findSub(command, rest[0]) orelse return out.toOwnedSlice(arena);
        spec = specOf(command, sub);
        rest = rest[1..];
    }

    var position: usize = 0;
    for (rest) |word| {
        if (isFlag(word)) continue;
        position += 1;
    }

    if (position < spec.args.len) try offerValues(&out, arena, io, partial, spec.args[position]);
    try offerFlags(&out, arena, partial, spec.flags, rest);

    return out.toOwnedSlice(arena);
}

/// What may stand where one argument is expected.
fn offerValues(
    out: *ArrayList(u8),
    arena: Allocator,
    io: std.Io,
    partial: []const u8,
    argument: commands.Arg,
) Allocator.Error!void {
    switch (argument.source) {
        .free => {},
        .fixed => for (argument.values) |value| try offer(out, arena, partial, value, ""),
        .commands => for (registry) |command| {
            try offer(out, arena, partial, command.name, command.summary);
        },
        .terminals => for (kitty.names(io, arena)) |name| {
            try offer(out, arena, partial, name, "");
        },
        .state_keys => {
            const keys = askDaemon(arena, "state", &.{"list"}) orelse return;
            var lines = std.mem.splitScalar(u8, keys, '\n');
            while (lines.next()) |key| try offer(out, arena, partial, key, "");
        },
        .space_labels => {
            // The argument is a comma-separated list, so only the field the cursor
            // is in is completed, and a candidate keeps the fields before it.
            const field_start = if (std.mem.lastIndexOfScalar(u8, partial, ',')) |comma| comma + 1 else 0;
            const already_typed = partial[0..field_start];

            const labels = askDaemon(arena, "wm", &.{"space-labels"}) orelse return;
            var lines = std.mem.splitScalar(u8, labels, '\n');
            while (lines.next()) |label| {
                if (label.len == 0) continue;
                const candidate = try std.fmt.allocPrint(arena, "{s}{s}", .{ already_typed, label });
                try offer(out, arena, partial, candidate, "");
            }
        },
    }
}

/// Ask a running daemon for the value of one command, for the values only it can
/// enumerate. Null when no daemon is listening, or when it refused - a completion
/// offers what it can and never fails a TAB over it.
fn askDaemon(arena: Allocator, command: []const u8, args: []const []const u8) ?[]const u8 {
    var response: [8 * 1024]u8 = undefined;
    const reply = control.query(arena, command, args, &response) orelse return null;
    return switch (control.decode(reply) orelse return null) {
        .ok => |payload| if (payload.len > 0) arena.dupe(u8, payload) catch null else null,
        .err => null,
    };
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
        try offer(out, arena, partial, flag.name, flag.summary);
    }
    if (!contains(used, "--help")) try offer(out, arena, partial, "--help", "show this");
}

/// One candidate, and what it does. The description follows a tab, which both
/// shells understand: zsh splits it off to show beside the match, and bash takes
/// the word and drops the rest.
fn offer(
    out: *ArrayList(u8),
    arena: Allocator,
    partial: []const u8,
    candidate: []const u8,
    description: []const u8,
) Allocator.Error!void {
    if (candidate.len == 0) return;
    if (!std.mem.startsWith(u8, candidate, partial)) return;

    try out.appendSlice(arena, candidate);
    if (description.len > 0) {
        try out.append(arena, '\t');
        try out.appendSlice(arena, description);
    }
    try out.append(arena, '\n');
}

/// Give up every `\t<description>` tail, in place, and say how much is left. A
/// tail runs to the end of its line.
fn undescribed(text: []u8) usize {
    var kept: usize = 0;
    var read: usize = 0;
    while (read < text.len) {
        if (text[read] == '\t') {
            while (read < text.len and text[read] != '\n') read += 1;
            continue;
        }
        text[kept] = text[read];
        kept += 1;
        read += 1;
    }
    return kept;
}

fn findSub(command: Command, name: []const u8) ?commands.Sub {
    for (command.subcommands) |sub| {
        if (std.mem.eql(u8, sub.name, name)) return sub;
    }
    return null;
}

fn isFlag(word: []const u8) bool {
    return word.len > 1 and word[0] == '-' and word[1] == '-';
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
/// being completed is `CURRENT - 2` among the words after it.
///
/// It alone passes `--describe`: `_describe` lays candidates out as
/// `name  -- what it does` and reads each element as `name:description`, which is
/// why a colon in a description is escaped here - the binary does not know what is
/// reading it. (`compadd -d` is not the call: it displays the description instead
/// of the candidate.)
///
/// A candidate that arrives without a tab is taken as a bare word, so the script
/// keeps working if it runs ahead of the binary - and if the binary is the older
/// one, which does not know `--describe`, the first call answers nothing and the
/// second one asks without it.
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
    \\  local -a candidates described
    \\  local candidate
    \\  candidates=("${(@f)$(kxdesk __complete --describe $((CURRENT - 2)) "${(@)words[2,CURRENT]}")}")
    \\  [[ -n $candidates[1] ]] || candidates=("${(@f)$(kxdesk __complete $((CURRENT - 2)) "${(@)words[2,CURRENT]}")}")
    \\  [[ -n $candidates[1] ]] || return 1
    \\  for candidate in "${(@)candidates}"; do
    \\    if [[ $candidate == *$'\t'* ]]; then
    \\      described+=("${candidate%%$'\t'*}:${${candidate#*$'\t'}//:/\\:}")
    \\    else
    \\      described+=("$candidate")
    \\    fi
    \\  done
    \\  _describe -t kxdesk 'kxdesk' described
    \\}
    \\
    \\compdef _kxdesk kxdesk
    \\
;

/// bash keeps `COMP_WORDS` 0-based with the program name at 0, so the word being
/// completed is `COMP_CWORD` and its index among the words after the program name
/// is `COMP_CWORD - 1`. Readline has nowhere to show a description, so it does not
/// ask for one.
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
