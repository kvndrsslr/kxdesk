//! The `generate_skhdrc` command and the template expansion behind it.
//!
//! `~/.skhdrc.template` is written with abbreviations — `:::`, `<<<` and `&&&`
//! stand in for whole `skhd`/helper invocations — that a reviewer wants to see
//! expanded, so `op < g ::: generate_skhdrc` regenerates `~/.skhdrc` from it.
//! The expansion is a faithful port of `__generate_skhdrc` in the old
//! `~/bin/yabai_util`, and faithfulness matters in two places: the `:::=`-family
//! tokens must be replaced before `:::`, or the shorter pattern eats their
//! prefix, and the trailing space in the `<<<` mode list is a real artifact of
//! the shell pipeline that the baseline's two spaces before `<` depend on.

const std = @import("std");
const commands = @import("commands.zig");
const platform = @import("platform.zig");

const Context = commands.Context;
const Allocator = std.mem.Allocator;

/// Longest `HOME`, and therefore template/output path, we will act on.
const home_capacity = 256;
/// Path buffer for this binary; plenty for the longest `/opt/homebrew/...` name.
const self_path_capacity = 4096;
/// A hand-maintained binding list; refuse to read something absurd instead of
/// truncating it silently.
const source_limit: std.Io.Limit = .limited(1 << 20);

/// Regenerate `~/.skhdrc` from `~/.skhdrc.template`. No options: the
/// transformation is fully determined by the template and this binary's path,
/// both resolved like the shell did (`${HOME}`, `$0`).
pub fn generate(context: *Context, args: []const []const u8) anyerror![]const u8 {
    _ = args;

    const home_dir = home(context.arena) orelse return error.NoHomeDirectory;
    const binary = selfPath(context.arena) orelse return error.NoSelfPath;

    const template_path = try std.fmt.allocPrint(context.arena, "{s}/.skhdrc.template", .{home_dir});
    const output_path = try std.fmt.allocPrint(context.arena, "{s}/.skhdrc", .{home_dir});

    const source = try std.Io.Dir.cwd().readFileAlloc(context.io, template_path, context.arena, source_limit);

    var output = std.ArrayList(u8).empty;
    try expand(source, binary, context.arena, &output);

    // Truncates, as the shell's `>` did: the file is always the template's
    // full expansion, never a patch over a previous one.
    var file = try std.Io.Dir.createFileAbsolute(context.io, output_path, .{});
    defer file.close(context.io);
    try file.writeStreamingAll(context.io, output.items);
    return "";
}

/// Expand the template's abbreviations into skhd's configuration language,
/// appending to `out`. `binary` is substituted quoted — every expansion lands
/// on a shell command line — wherever the template asks for the helper: `:::`
/// and `&&&` directly, the `:=>`-family tokens after their `skhd -k escape`
/// prefixes, and once per line for a leading `<<<` along with the mode list it
/// expands to. Comment and empty lines are dropped, matching the shell's sed
/// order, which kept `;;;` as the last substitution on every kept line.
pub fn expand(
    source: []const u8,
    binary: []const u8,
    allocator: Allocator,
    out: *std.ArrayList(u8),
) Allocator.Error!void {
    const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{binary});
    defer allocator.free(quoted);

    const modes = try modeList(source, allocator);
    defer allocator.free(modes);

    // `:::=>` and `:::==>` precede `:::` for the same reason `:=>` and `:==>`
    // do: a one-pass scan for the shorter token would consume their `::`/`:`
    // and leave the escape prefixes mangled. The order is the shell's, whose
    // sed expressions ran in this sequence.
    // Each replacement is transcribed from the matching sed expression in
    // `__generate_skhdrc`, including where the binary goes: `:::=>`, `:::==>`,
    // `:::` and `&&&` name it, while `:=>` and `:==>` do not — the template
    // line's own command follows them. The strings are built once here and
    // freed with the arena; the per-line work allocates its own copies.
    const Substitution = struct { needle: []const u8, replacement: []const u8 };
    const substitutions = [_]Substitution{
        .{ .needle = ":::=>", .replacement = try std.fmt.allocPrint(allocator, ": skhd -k escape && {s}", .{quoted}) },
        .{ .needle = ":::==>", .replacement = try std.fmt.allocPrint(allocator, ": skhd -k escape && skhd -k escape && {s}", .{quoted}) },
        .{ .needle = ":=>", .replacement = ": skhd -k escape && " },
        .{ .needle = ":==>", .replacement = ": skhd -k escape && skhd -k escape && " },
        .{ .needle = ":::", .replacement = try std.fmt.allocPrint(allocator, ": {s}", .{quoted}) },
        .{ .needle = "&&&", .replacement = try std.fmt.allocPrint(allocator, "&& {s}", .{quoted}) },
        .{ .needle = ";;;", .replacement = "&& skhd -k escape" },
    };

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        // `sed -e '/^#.*$/d' -e '/^$/d'`: a dropped line gets no substitutions.
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (line.len == 0) continue;

        var line_buffer = std.ArrayList(u8).empty;
        defer line_buffer.deinit(allocator);

        if (std.mem.startsWith(u8, line, "<<<")) {
            // Shell-anchored: `sed 's/^<<</'"$modes"' < /'` only matches the
            // start of a line, so a `<<<` in the middle stays literal.
            try line_buffer.appendSlice(allocator, modes);
            try line_buffer.appendSlice(allocator, " < ");
            try line_buffer.appendSlice(allocator, line[3..]);
        } else {
            try line_buffer.appendSlice(allocator, line);
        }

        for (substitutions) |substitution| {
            const replaced = try replaceAll(line_buffer.items, substitution.needle, substitution.replacement, allocator);
            defer allocator.free(replaced);
            line_buffer.clearRetainingCapacity();
            try line_buffer.appendSlice(allocator, replaced);
        }

        try out.appendSlice(allocator, line_buffer.items);
        // The template ends with a newline, so the split yields an empty final
        // piece and this keeps every kept line terminated either way.
        try out.append(allocator, '\n');
    }
}

/// Every occurrence of `needle` in `haystack` replaced with `replacement`.
fn replaceAll(
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
    allocator: Allocator,
) Allocator.Error![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |hit| {
        try result.appendSlice(allocator, rest[0..hit]);
        try result.appendSlice(allocator, replacement);
        rest = rest[hit + needle.len ..];
    }
    try result.appendSlice(allocator, rest);
    return result.toOwnedSlice(allocator);
}

/// The shell's mode-list computation, step for step.
///
/// `ggrep -oP '^:: \K\w+'` collects the mode names from `:: <name>` lines in
/// order; `xargs` joins them with single spaces; `s/passthrough//g` deletes
/// the literal word wherever it appears, leaving the space that separated it
/// from its neighbour; `s/\s+(\w)/, \1/g` then turns each whitespace run
/// before a word character into `, `. The last one leaves a trailing space
/// alone (nothing word-shaped follows it), which is exactly why this template
/// yields `default, op, wmode, smode ` — trailing space and all — and the
/// baseline's global bindings read `smode  < ` with two spaces.
fn modeList(source: []const u8, allocator: Allocator) Allocator.Error![]u8 {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        // `^:: \K\w+`: anchored, exactly one space, one word.
        if (!std.mem.startsWith(u8, line, ":: ")) continue;
        const rest = line[3..];
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        if (end == 0) continue;
        if (joined.items.len != 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, rest[0..end]);
    }

    // `s/passthrough//g`, before any comma-collapsing: the vacated separator
    // space must survive into the next step.
    const unpassed = try removeLiteral(joined.items, "passthrough", allocator);
    defer allocator.free(unpassed);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var index: usize = 0;
    while (index < unpassed.len) {
        const c = unpassed[index];
        if (c == ' ' or c == '\t') {
            // `\s+(\w)`: one comma regardless of how wide the gap is.
            var word = index + 1;
            while (word < unpassed.len and (unpassed[word] == ' ' or unpassed[word] == '\t')) word += 1;
            if (word < unpassed.len and isWord(unpassed[word])) {
                try result.appendSlice(allocator, ", ");
                try result.append(allocator, unpassed[word]);
                index = word + 1;
                continue;
            }
            // Whitespace with no word after it is left exactly as it was.
            try result.append(allocator, c);
            index += 1;
            continue;
        }
        try result.append(allocator, c);
        index += 1;
    }
    return result.toOwnedSlice(allocator);
}

/// Every occurrence of `needle` deleted, everything around it kept — the
/// `gsed -e 's/passthrough//g'` this replaces.
fn removeLiteral(haystack: []const u8, needle: []const u8, allocator: Allocator) Allocator.Error![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |hit| {
        try result.appendSlice(allocator, rest[0..hit]);
        rest = rest[hit + needle.len ..];
    }
    try result.appendSlice(allocator, rest);
    return result.toOwnedSlice(allocator);
}

/// `\w` as the shell's regular expressions read it: ASCII word characters.
fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// What the shell read as `${HOME}` — from the environment, absolute.
fn home(arena: Allocator) ?[]const u8 {
    var buffer: [home_capacity]u8 = undefined;
    if (!platform.sb_env("HOME", &buffer, buffer.len)) return null;
    return arena.dupe(u8, std.mem.sliceTo(&buffer, 0)) catch null;
}

/// What the shell resolved as `$0`, the binary the generated file names so it
/// never depends on `PATH`.
fn selfPath(arena: Allocator) ?[]const u8 {
    var buffer: [self_path_capacity]u8 = undefined;
    if (!platform.sb_self_path(&buffer, buffer.len)) return null;
    return arena.dupe(u8, std.mem.sliceTo(&buffer, 0)) catch null;
}
