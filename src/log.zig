//! stderr logging: one prefix, one newline, one place.

const std = @import("std");

/// `kxdesk: <message>\n` to stderr.
pub fn warn(comptime format: []const u8, values: anytype) void {
    std.debug.print("kxdesk: " ++ format ++ "\n", values);
}

/// Remembers the last message reported; `changed` is true only when this one
/// differs, so a repeating failure logs once until it clears. Fixed 160-byte
/// memory, truncating longer messages.
pub const Once = struct {
    last: [160]u8 = undefined,
    last_len: usize = 0,

    pub fn changed(self: *Once, message: []const u8) bool {
        const remembered = message[0..@min(message.len, self.last.len)];
        if (self.last_len == remembered.len and
            std.mem.eql(u8, self.last[0..self.last_len], remembered)) return false;

        @memcpy(self.last[0..remembered.len], remembered);
        self.last_len = remembered.len;
        return true;
    }

    pub fn clear(self: *Once) void {
        self.last_len = 0;
    }
};
