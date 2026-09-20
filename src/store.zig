//! Durable state for the daemon: one SQLite database, owned by this process.
//!
//! Several things here want to remember across restarts - the pomodoro timer a
//! `brew upgrade` interrupted, whether the bar was collapsed, which mode the
//! spaces were in - and the previous answers were ad hoc: `/tmp/yabai-mode` for
//! one of them, nothing at all for the others. This is the single place for that
//! instead, and it is reachable from outside too: `kxdesk state set <key>
//! <value>` persists whatever a key binding or a plugin wants to keep, so the
//! state lives in one file rather than in a directory of little ones.
//!
//! SQLite is not in the standard library - it was removed, and only the C
//! library is left - so the header is translated into a Zig module by the build
//! system and linked against the copy macOS ships. That copy needs no
//! dependency, and the one here (3.54.0, with FTS5) is newer than Homebrew's.
//!
//! Two rules this module keeps:
//!
//! * It never takes the daemon down. A database that cannot be opened leaves a
//!   store that answers `error.Unavailable`: the daemon starts anyway and the
//!   bar keeps working, because persistence is a convenience and not a
//!   prerequisite.
//! * A corrupt database is moved aside rather than repaired - renamed to
//!   `state.db.corrupt-<timestamp>` and replaced - so a wedged file cannot wedge
//!   the daemon for the rest of its life.

const std = @import("std");

const c = @import("sqlite");
const platform = @import("platform.zig");

/// Schema version this build produces. Bump this and add a step in `migrate`.
pub const schema_version: c_int = 3;

/// The directory is the owner's alone. The database holds whatever the bar and
/// the tools that speak to it choose to keep, and SQLite creates its own
/// write-ahead log and shared-memory file alongside with modes of its own - so
/// the directory is what keeps all three private, not the file modes.
const directory_mode: std.Io.File.Permissions = @enumFromInt(0o700);

/// How long a write waits for another writer before giving up. The daemon is
/// the only writer, so reaching this means something is wrong; waiting beats
/// failing with SQLITE_BUSY on a key binding.
const busy_timeout_ms = 5000;

pub const Store = struct {
    /// Null when the database could not be opened. Every operation then answers
    /// `error.Unavailable`, which the daemon's own callers ignore and the
    /// `state` command reports.
    db: ?*c.sqlite3 = null,

    /// Commands run on worker tasks while the receive loop ticks the timer, so
    /// one connection is shared and serialized rather than one per thread.
    mutex: std.Io.Mutex = .init,

    /// The path, NUL-terminated: it is passed to the C API as it stands, and
    /// kept for moving a corrupt file aside.
    path: [std.fs.max_path_bytes]u8 = @splat(0),
    path_len: usize = 0,

    pub const Error = error{ Unavailable, Query, Busy, NoSpaceLeft };

    /// Where the database lives when nothing overrides it.
    ///
    /// `KXDESK_STATE` names another file, which is what a test or a probe uses.
    /// The default is the per-user application data directory, so the file
    /// survives an upgrade of the binary - unlike anything under the brew
    /// prefix, which is replaced wholesale.
    pub fn defaultPath(buffer: *[std.fs.max_path_bytes]u8) []const u8 {
        var environment: [std.fs.max_path_bytes]u8 = undefined;
        if (platform.kx_env("KXDESK_STATE", &environment, environment.len)) {
            const value = std.mem.sliceTo(&environment, 0);
            if (value.len > 0 and value.len <= buffer.len) {
                @memcpy(buffer[0..value.len], value);
                return buffer[0..value.len];
            }
        }

        const home = if (platform.kx_env("HOME", &environment, environment.len))
            std.mem.sliceTo(&environment, 0)
        else
            "/tmp";

        return std.fmt.bufPrint(buffer, "{s}/Library/Application Support/kxdesk/state.db", .{home}) catch
            buffer[0..0];
    }

    /// Open the database, creating it and bringing the schema up to date.
    ///
    /// Never fails: an unusable path, an unopenable file or a schema that cannot
    /// be prepared all leave a store whose operations answer
    /// `error.Unavailable`, with one line on stderr saying so.
    pub fn open(io: std.Io, path: []const u8) Store {
        var store = Store{};
        if (path.len == 0 or path.len >= store.path.len) {
            std.debug.print("kxdesk: state path is unusable; persistence is off\n", .{});
            return store;
        }
        @memcpy(store.path[0..path.len], path);
        store.path_len = path.len;

        // Only the last level is ours; the platform's `Application Support`
        // directory is always there.
        if (std.fs.path.dirname(path)) |directory| {
            std.Io.Dir.createDirAbsolute(io, directory, directory_mode) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    std.debug.print("kxdesk: cannot create the state directory: {s}\n", .{@errorName(err)});
                    return store;
                },
            };
            // Also for a directory an earlier version created with the default
            // permissions, which is what this used to do.
            std.Io.Dir.cwd().setFilePermissions(io, directory, directory_mode, .{}) catch {};
        }

        var connection = store.connect() orelse {
            std.debug.print("kxdesk: cannot open {s}; persistence is off\n", .{path});
            return store;
        };

        if (!usable(connection)) {
            std.debug.print("kxdesk: {s} is not a usable database; starting a fresh one\n", .{path});
            store.setAside(io, connection) orelse return store;
            connection = store.connect() orelse return store;
        }

        store.db = connection;
        store.migrate() catch |err| {
            std.debug.print("kxdesk: cannot prepare the state schema: {s}\n", .{@errorName(err)});
            _ = c.sqlite3_close_v2(connection);
            store.db = null;
        };
        return store;
    }

    pub fn close(self: *Store) void {
        if (self.db) |db| _ = c.sqlite3_close_v2(db);
        self.db = null;
    }

    /// Whether the store can be used at all.
    pub fn enabled(self: *Store) bool {
        return self.db != null;
    }

    // -- what the rest of the daemon calls ------------------------------------

    /// Read an integer, or null when the key is absent.
    pub fn getInt(self: *Store, io: std.Io, key: []const u8) Error!?i64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const db = self.db orelse return error.Unavailable;

        const statement = try prepare(db, "SELECT value FROM kv WHERE key = ?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return null;
        if (c.sqlite3_column_type(statement, 0) != c.SQLITE_INTEGER) return null;
        return c.sqlite3_column_int64(statement, 0);
    }

    /// Read text into `out`, or null when the key is absent. The bytes are
    /// copied, so nothing depends on the statement staying alive.
    pub fn getText(self: *Store, io: std.Io, key: []const u8, out: []u8) Error!?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const db = self.db orelse return error.Unavailable;

        const statement = try prepare(db, "SELECT value FROM kv WHERE key = ?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return null;

        const pointer = c.sqlite3_column_text(statement, 0) orelse return null;
        const length: usize = @intCast(c.sqlite3_column_bytes(statement, 0));
        const copied = out[0..@min(length, out.len)];
        @memcpy(copied, pointer[0..copied.len]);
        return copied;
    }

    /// Read text, allocated from `gpa`. For callers that cannot size a buffer
    /// up front - the `state get` reply, for instance.
    pub fn getTextAlloc(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        key: []const u8,
    ) Error!?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const db = self.db orelse return error.Unavailable;

        const statement = try prepare(db, "SELECT value FROM kv WHERE key = ?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return null;
        if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) return null;

        const pointer = c.sqlite3_column_text(statement, 0) orelse return null;
        const length: usize = @intCast(c.sqlite3_column_bytes(statement, 0));
        return gpa.dupe(u8, pointer[0..length]) catch return error.NoSpaceLeft;
    }

    pub fn setInt(self: *Store, io: std.Io, key: []const u8, value: i64) Error!void {
        return self.write(io, key, .{ .integer = value });
    }

    pub fn setText(self: *Store, io: std.Io, key: []const u8, value: []const u8) Error!void {
        return self.write(io, key, .{ .text = value });
    }

    pub fn setReal(self: *Store, io: std.Io, key: []const u8, value: f64) Error!void {
        return self.write(io, key, .{ .real = value });
    }

    pub fn setNull(self: *Store, io: std.Io, key: []const u8) Error!void {
        return self.write(io, key, .{ .null = {} });
    }

    pub fn unset(self: *Store, io: std.Io, key: []const u8) Error!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const db = self.db orelse return error.Unavailable;

        const statement = try prepare(db, "DELETE FROM kv WHERE key = ?1");
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, key);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.Query;
    }

    /// Every key, or every key under a prefix. `substr` rather than `LIKE`, so a
    /// prefix containing `%` or `_` is a prefix and not a pattern.
    pub fn keys(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        prefix: []const u8,
    ) Error![]const []const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const db = self.db orelse return error.Unavailable;

        const statement = try prepare(db,
            \\SELECT key FROM kv
            \\WHERE substr(key, 1, length(?1)) = ?1
            \\ORDER BY key
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindText(statement, 1, prefix);

        var found: std.ArrayList([]const u8) = .empty;
        while (true) {
            const rc = c.sqlite3_step(statement);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.Query;

            const pointer = c.sqlite3_column_text(statement, 0) orelse continue;
            const length: usize = @intCast(c.sqlite3_column_bytes(statement, 0));
            const key = gpa.dupe(u8, pointer[0..length]) catch return error.NoSpaceLeft;
            found.append(gpa, key) catch return error.NoSpaceLeft;
        }
        return found.toOwnedSlice(gpa) catch return error.NoSpaceLeft;
    }

    // -- the pieces -----------------------------------------------------------

    const Value = union(enum) {
        text: []const u8,
        integer: i64,
        real: f64,
        null: void,
    };

    fn write(self: *Store, io: std.Io, key: []const u8, value: Value) Error!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const db = self.db orelse return error.Unavailable;

        const statement = try prepare(db,
            \\INSERT INTO kv (key, value, updated) VALUES (?1, ?2, unixepoch())
            \\ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated = excluded.updated
        );
        defer _ = c.sqlite3_finalize(statement);

        try bindText(statement, 1, key);
        switch (value) {
            // Borrowed, not copied: the statement is stepped below, before the
            // caller's slice can go anywhere. See `bindText`.
            .text => |text| if (c.sqlite3_bind_text(statement, 2, text.ptr, @intCast(text.len), c.SQLITE_STATIC) != c.SQLITE_OK)
                return error.Query,
            .integer => |number| if (c.sqlite3_bind_int64(statement, 2, number) != c.SQLITE_OK)
                return error.Query,
            .real => |number| if (c.sqlite3_bind_double(statement, 2, number) != c.SQLITE_OK)
                return error.Query,
            .null => if (c.sqlite3_bind_null(statement, 2) != c.SQLITE_OK) return error.Query,
        }
        return step(statement);
    }

    /// The connection, with the pragmas that decide how it behaves.
    fn connect(self: *Store) ?*c.sqlite3 {
        if (self.path_len == 0) return null;

        var handle: ?*c.sqlite3 = null;
        // `FULLMUTEX` as well as the mutex above: the connection is shared by
        // worker tasks, and serializing inside SQLite costs nothing measurable
        // while removing a whole class of mistake.
        const rc = c.sqlite3_open_v2(
            self.pathPointer(),
            &handle,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX,
            null,
        );
        if (rc != c.SQLITE_OK) {
            if (handle) |partial| _ = c.sqlite3_close_v2(partial);
            return null;
        }

        _ = c.sqlite3_busy_timeout(handle.?, busy_timeout_ms);
        // WAL, so a reader never blocks the writer and a crash costs at most the
        // last transaction; `NORMAL` is the right trade for state this cheap to
        // lose - a timer's remaining seconds, not a ledger.
        execOn(handle.?, "PRAGMA journal_mode=WAL") catch {};
        execOn(handle.?, "PRAGMA synchronous=NORMAL") catch {};
        return handle;
    }

    /// Whether the file is a database we can read.
    fn usable(db: *c.sqlite3) bool {
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &statement, null) != c.SQLITE_OK) return false;
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return false;
        const answer = c.sqlite3_column_text(statement, 0) orelse return false;
        return std.mem.eql(u8, std.mem.span(answer), "ok");
    }

    /// Move a corrupt file out of the way, together with its write-ahead log,
    /// and leave the path free for a fresh database.
    fn setAside(self: *Store, io: std.Io, db: *c.sqlite3) ?void {
        _ = c.sqlite3_close_v2(db);

        const path = self.pathSlice() orelse return null;
        const seconds = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s);

        var aside: [std.fs.max_path_bytes]u8 = undefined;
        const name = std.fmt.bufPrintZ(&aside, "{s}.corrupt-{d}", .{ path, seconds }) catch return null;
        std.Io.Dir.renameAbsolute(path, name, io) catch |err| {
            std.debug.print("kxdesk: cannot move the corrupt database aside: {s}\n", .{@errorName(err)});
            return null;
        };

        for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
            var side: [std.fs.max_path_bytes]u8 = undefined;
            const side_path = std.fmt.bufPrintZ(&side, "{s}{s}", .{ path, suffix }) catch continue;
            std.Io.Dir.deleteFileAbsolute(io, side_path) catch {};
        }
        return {};
    }

    fn migrate(self: *Store) Error!void {
        const db = self.db orelse return error.Unavailable;

        const current = try userVersion(db);
        if (current >= schema_version) return;

        try execOn(db, "BEGIN IMMEDIATE");
        errdefer execOn(db, "ROLLBACK") catch {};

        if (current < 1) {
            // `STRICT` so a typo in a query is an error rather than a silently
            // typed row, and `ANY` for the value because one column holds text,
            // integers, reals and nulls.
            try execOn(db,
                \\CREATE TABLE kv (
                \\  key     TEXT PRIMARY KEY,
                \\  value   ANY,
                \\  updated INTEGER NOT NULL DEFAULT (unixepoch())
                \\) STRICT
            );
        }

        if (current < 2) {
            // Cumulative spend, sampled: the first version of this kept readings
            // of a provider's running total so that the difference between two
            // of them could answer "the last day and the last week". Only
            // OpenRouter needed it, only its popup showed it, and both are gone.
            try execOn(db,
                \\CREATE TABLE usage_samples (
                \\  provider   TEXT NOT NULL,
                \\  sampled_at INTEGER NOT NULL,
                \\  spent_usd  REAL NOT NULL,
                \\  PRIMARY KEY (provider, sampled_at)
                \\) STRICT
            );
        }

        if (current < 3) {
            // Nothing interposes if this fails: SQLite reports an unknown
            // `CREATE TABLE` through the same `exec` as any other statement.
            try execOn(db, "DROP TABLE IF EXISTS usage_samples");
        }

        var statement: [64]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&statement, "PRAGMA user_version={d}", .{schema_version}) catch
            return error.Query;
        try execOn(db, sql);
        try execOn(db, "COMMIT");
    }

    fn userVersion(db: *c.sqlite3) Error!c_int {
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, null) != c.SQLITE_OK) return error.Query;
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.Query;
        return c.sqlite3_column_int(statement, 0);
    }

    fn execOn(db: *c.sqlite3, sql: [*:0]const u8) Error!void {
        if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) return error.Query;
    }

    fn prepare(db: *c.sqlite3, sql: [:0]const u8) Error!*c.sqlite3_stmt {
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &statement, null) != c.SQLITE_OK)
            return error.Query;
        return statement.?;
    }

    /// One step, with the two results that mean "try again" separated from the
    /// rest.
    fn step(statement: *c.sqlite3_stmt) Error!void {
        return switch (c.sqlite3_step(statement)) {
            c.SQLITE_DONE => {},
            c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
            else => error.Query,
        };
    }

    /// Bind one text argument.
    ///
    /// `SQLITE_STATIC`, so the bytes are borrowed rather than copied - which is
    /// only sound because every statement here is prepared, bound, stepped and
    /// finalized inside a single function, and the caller's slice outlives all
    /// of it. Copying instead (`SQLITE_TRANSIENT`) is a cast of -1 that this
    /// language will not let us spell: the C header's macro does not survive
    /// translation into a valid Zig function pointer.
    fn bindText(statement: *c.sqlite3_stmt, index: c_int, value: []const u8) Error!void {
        if (c.sqlite3_bind_text(statement, index, value.ptr, @intCast(value.len), c.SQLITE_STATIC) != c.SQLITE_OK)
            return error.Query;
    }

    fn pathSlice(self: *Store) ?[]const u8 {
        if (self.path_len == 0) return null;
        return self.path[0..self.path_len];
    }

    fn pathPointer(self: *Store) [*:0]const u8 {
        return @ptrCast(&self.path);
    }
};
