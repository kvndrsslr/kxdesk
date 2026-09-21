//! Application name -> icon mapping, read from the installed app font at runtime.
//!
//! The font describes its own mapping: its OpenType `meta` table carries a
//! private data map tagged `APPM` whose payload is JSON giving each ligature
//! (`:safari:`) a Private Use Area codepoint and the application names that
//! resolve to it. Every font build reassigns those codepoints, so the mapping is
//! read from the installed font rather than compiled in; every read is bounds
//! checked, so a truncated font degrades to `:default:`.

// Layout, all big-endian:
//
//   sfnt header   `sfntVersion` u32 @0, `numTables` u16 @4, then 16-byte records
//                 from @12: tag[4], checksum u32, offset u32 (absolute), length u32
//   `meta` table  version u32, flags u32, reserved u32, `dataMapsCount` u32 @+12,
//                 then 12-byte data maps: tag[4], dataOffset u32, dataLength u32 -
//                 where `dataOffset` is relative to the start of `meta`
//   `APPM` data   UTF-8 JSON: {"version":1,"release":"2.0.87","icons":[[...]]}

const std = @import("std");

/// An app icon: the ligature SketchyBar renders and the codepoint behind it.
pub const Icon = struct {
    ligature: []const u8,
    codepoint: u21,
};

/// Rendered for applications the font does not map.
pub const default_ligature = ":default:";

/// The real font is ~320 KiB; anything larger is not this font.
const max_font_bytes = 8 << 20;

pub const Mapping = struct {
    /// Owns the font bytes, the parsed payload and both lookup tables, so a
    /// single `deinit` releases everything.
    arena: std.heap.ArenaAllocator,
    /// Exact application names. Both tables are unmanaged and stay empty until
    /// `load` runs, because an allocator taken from `arena` points at whichever
    /// `Mapping` it was taken from and must not be created before this value
    /// has come to rest.
    exact: std.StringHashMapUnmanaged(Icon) = .empty,
    /// Application name prefixes, in payload order; the first match wins.
    prefixes: std.ArrayListUnmanaged(Prefix) = .empty,
    /// Yielded for anything unmapped, including when the font is unavailable.
    fallback: Icon = .{ .ligature = default_ligature, .codepoint = 0 },
    /// Glyphs listed by the font, and how many of them name applications.
    glyphs: usize = 0,
    mapped: usize = 0,
    /// Font release the mapping was read from, e.g. `2.0.87`.
    release: []const u8 = "",

    const Prefix = struct { pattern: []const u8, icon: Icon };

    pub fn init(allocator: std.mem.Allocator) Mapping {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Mapping) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Read the mapping for the font at `path`.
    ///
    /// On failure the mapping is left empty and every lookup yields the
    /// fallback, so a missing or unreadable font costs the icons and nothing
    /// else.
    pub fn load(self: *Mapping, io: std.Io, path: []const u8) !void {
        const arena = self.arena.allocator();
        const font = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_font_bytes));
        try self.parse(arena, try appMap(font));
    }

    /// The icon the font maps `app` to: an exact name first, then the first
    /// matching prefix. Null when the font knows nothing about the application.
    pub fn find(self: *const Mapping, app: []const u8) ?Icon {
        if (self.exact.get(app)) |icon| return icon;
        for (self.prefixes.items) |entry| {
            if (std.mem.startsWith(u8, app, entry.pattern)) return entry.icon;
        }
        return null;
    }

    /// The icon to render for `app`, falling back to `:default:` when the font
    /// has no mapping.
    pub fn lookup(self: *const Mapping, app: []const u8) Icon {
        return self.find(app) orelse self.fallback;
    }

    /// Payload schema 1: `{"version":1,"release":"...","icons":[[ligature,
    /// codepoint, [appNames]|null], ...]}`. Unknown keys and malformed rows are
    /// skipped so a newer font build still works.
    fn parse(self: *Mapping, arena: std.mem.Allocator, payload: []const u8) !void {
        const root = switch (std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
            // The payload outlives the parsed value - both live in the arena -
            // so strings can point into it rather than being copied.
            .allocate = .alloc_if_needed,
        }) catch return error.InvalidPayload) {
            .object => |object| object,
            else => return error.InvalidPayload,
        };

        self.release = switch (root.get("release") orelse return error.InvalidPayload) {
            .string => |text| text,
            else => return error.InvalidPayload,
        };
        const icons = switch (root.get("icons") orelse return error.InvalidPayload) {
            .array => |array| array.items,
            else => return error.InvalidPayload,
        };

        for (icons) |entry| {
            const columns = switch (entry) {
                .array => |array| array.items,
                else => continue,
            };
            if (columns.len < 3) continue;

            const ligature = switch (columns[0]) {
                .string => |text| text,
                else => continue,
            };
            const codepoint = switch (columns[1]) {
                .integer => |value| value,
                else => continue,
            };
            if (codepoint < 0 or codepoint > 0x10FFFF) continue;

            const icon: Icon = .{ .ligature = ligature, .codepoint = @intCast(codepoint) };
            self.glyphs += 1;
            if (std.mem.eql(u8, ligature, default_ligature)) self.fallback = icon;

            const names = switch (columns[2]) {
                .array => |array| array.items,
                .null => continue,
                else => continue,
            };
            self.mapped += 1;

            for (names) |name| {
                const text = switch (name) {
                    .string => |string| string,
                    else => continue,
                };
                // A trailing `*` means "any application whose name starts with
                // this".
                if (std.mem.endsWith(u8, text, "*")) {
                    try self.prefixes.append(arena, .{
                        .pattern = text[0 .. text.len - 1],
                        .icon = icon,
                    });
                } else {
                    try self.exact.put(arena, text, icon);
                }
            }
        }
    }
};

fn readU16(data: []const u8, offset: usize) ?u16 {
    if (offset + 2 > data.len) return null;
    return std.mem.readInt(u16, data[offset..][0..2], .big);
}

fn readU32(data: []const u8, offset: usize) ?u32 {
    if (offset + 4 > data.len) return null;
    return std.mem.readInt(u32, data[offset..][0..4], .big);
}

/// Absolute offset of the table with this 4-byte tag.
fn tableOffset(font: []const u8, tag: *const [4]u8) !usize {
    const count = readU16(font, 4) orelse return error.TruncatedFont;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const record = 12 + index * 16;
        if (record + 16 > font.len) return error.TruncatedFont;
        if (!std.mem.eql(u8, font[record..][0..4], tag)) continue;

        const offset = readU32(font, record + 8) orelse return error.TruncatedFont;
        if (offset >= font.len) return error.TruncatedFont;
        return offset;
    }
    return error.NoMetaTable;
}

/// Data of the first data map in the `meta` table whose tag matches. Its offset
/// is relative to the start of `meta`, unlike the table offsets above.
fn dataMap(font: []const u8, meta: usize, tag: *const [4]u8) ![]const u8 {
    const count = readU32(font, meta + 12) orelse return error.TruncatedFont;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const record = meta + 16 + index * 12;
        if (record + 12 > font.len) return error.TruncatedFont;
        if (!std.mem.eql(u8, font[record..][0..4], tag)) continue;

        const offset = readU32(font, record + 4) orelse return error.TruncatedFont;
        const length = readU32(font, record + 8) orelse return error.TruncatedFont;
        const start = meta + offset;
        if (start > font.len or length > font.len - start) return error.TruncatedFont;
        return font[start..][0..length];
    }
    return error.NoAppMap;
}

/// The JSON payload describing the mapping.
fn appMap(font: []const u8) ![]const u8 {
    return dataMap(font, try tableOffset(font, "meta"), "APPM");
}
