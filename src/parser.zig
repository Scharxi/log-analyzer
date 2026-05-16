const std = @import("std");

pub const ParseError = error{
    EmptyLine,
    MissingField,
    InvalidLevel,
    InvalidTimestamp,
};

/// Inclusive lower/upper bounds on log timestamps (`YYYY-MM-DDTHH:MM:SSZ`).
pub const TimeBounds = struct {
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
};

pub const Level = enum {
    info,
    warn,
    @"error",
    debug,

    pub fn rank(self: Level) usize {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .warn => 2,
            .@"error" => 3,
        };
    }

    pub fn parse(s: []const u8) ParseError!Level {
        return parseLevel(s);
    }
};

/// Parsed fields borrow from `line` until that buffer is invalidated.
pub const LogEntry = struct {
    /// Valid for the lifetime of the source line buffer.
    timestamp: []const u8,
    /// Valid for the lifetime of the source line buffer.
    level: Level,
    /// Valid for the lifetime of the source line buffer.
    module: []const u8,
    /// Valid for the lifetime of the source line buffer. May be empty.
    message: []const u8,
};

fn toLowerAscii(buf: []u8) void {
    for (buf) |*c| {
        c.* = std.ascii.toLower(c.*);
    }
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Validates `YYYY-MM-DDTHH:MM:SSZ` and returns the borrowed slice.
pub fn parseTimestamp(s: []const u8) ParseError![]const u8 {
    if (s.len != 20) return error.InvalidTimestamp;

    const separators = [_]struct { index: usize, expected: u8 }{
        .{ .index = 4, .expected = '-' },
        .{ .index = 7, .expected = '-' },
        .{ .index = 10, .expected = 'T' },
        .{ .index = 13, .expected = ':' },
        .{ .index = 16, .expected = ':' },
        .{ .index = 19, .expected = 'Z' },
    };

    for (separators) |sep| {
        if (s[sep.index] != sep.expected) return error.InvalidTimestamp;
    }

    for (s, 0..) |c, i| {
        if (i == 4 or i == 7 or i == 10 or i == 13 or i == 16 or i == 19) continue;
        if (!isDigit(c)) return error.InvalidTimestamp;
    }

    return s;
}

/// UTC ISO timestamps in this format compare correctly as byte strings.
pub fn compareTimestamp(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

pub fn timestampInRange(ts: []const u8, bounds: TimeBounds) bool {
    if (bounds.since) |since| {
        if (compareTimestamp(ts, since) == .lt) return false;
    }
    if (bounds.until) |until| {
        if (compareTimestamp(ts, until) == .gt) return false;
    }
    return true;
}

fn parseLevel(s: []const u8) ParseError!Level {
    var tmp: [16]u8 = undefined;

    if (s.len == 0 or s.len > tmp.len) return error.InvalidLevel;

    @memcpy(tmp[0..s.len], s);
    toLowerAscii(tmp[0..s.len]);

    if (std.meta.stringToEnum(Level, tmp[0..s.len])) |lvl| {
        return lvl;
    }
    return error.InvalidLevel;
}

pub fn parseLine(line: []const u8) ParseError!LogEntry {
    if (line.len == 0) return error.EmptyLine;

    var it = std.mem.splitAny(u8, line, " ");

    const timestamp = it.next() orelse return error.MissingField;
    const level_s = it.next() orelse return error.MissingField;
    const module = it.next() orelse return error.MissingField;

    const msg_start = it.index orelse line.len;
    const message = line[msg_start..];

    const level = try parseLevel(level_s);
    _ = try parseTimestamp(timestamp);

    return .{
        .timestamp = timestamp,
        .level = level,
        .module = module,
        .message = message,
    };
}

test "parse log level" {
    const Case = struct {
        level: []const u8,
        expected: Level,
    };

    const cases = [_]Case{
        .{ .level = "inFo", .expected = .info },
        .{ .level = "waRN", .expected = .warn },
        .{ .level = "debug", .expected = .debug },
        .{ .level = "DeBUg", .expected = .debug },
        .{ .level = "ERRor", .expected = .@"error" },
    };

    for (cases) |c| {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "2026-01-01T00:00:00Z {s} mod msg",
            .{c.level},
        );
        const entry = try parseLine(line);
        try std.testing.expectEqual(c.expected, entry.level);
    }
}

test "parse basic log line" {
    const line = "2026-05-15T20:00:01Z INFO auth login ok";

    const entry = try parseLine(line);
    const expected = LogEntry{
        .timestamp = "2026-05-15T20:00:01Z",
        .level = .info,
        .module = "auth",
        .message = "login ok",
    };

    try std.testing.expectEqualDeep(expected, entry);
}

test "parse line with empty message" {
    const line = "2026-05-15T20:00:01Z INFO auth";
    const entry = try parseLine(line);
    try std.testing.expectEqual("", entry.message);
}

test "parse malformed lines" {
    try std.testing.expectError(error.EmptyLine, parseLine(""));
    try std.testing.expectError(error.MissingField, parseLine("2026-05-15T20:00:01Z INFO"));
    try std.testing.expectError(error.InvalidLevel, parseLine("2026-05-15T20:00:01Z BOGUS auth msg"));
}

test "get level rank" {
    try std.testing.expectEqual(@as(usize, 0), Level.debug.rank());
    try std.testing.expectEqual(@as(usize, 1), Level.info.rank());
    try std.testing.expectEqual(@as(usize, 2), Level.warn.rank());
    try std.testing.expectEqual(@as(usize, 3), Level.@"error".rank());
}

test "parseTimestamp accepts valid ISO 8601 UTC" {
    const valid = "2026-05-15T20:00:01Z";
    try std.testing.expectEqualStrings(valid, try parseTimestamp(valid));
}

test "parseTimestamp rejects invalid timestamps" {
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("2026-05-15T20:00:01"));
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("not-a-timestamp"));
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("2026-05-15T20:00:01z"));
}

test "compareTimestamp orders chronologically" {
    try std.testing.expect(compareTimestamp("2026-05-15T20:00:01Z", "2026-05-15T20:00:02Z") == .lt);
    try std.testing.expect(compareTimestamp("2026-05-15T20:00:02Z", "2026-05-15T20:00:02Z") == .eq);
    try std.testing.expect(compareTimestamp("2026-05-15T20:00:03Z", "2026-05-15T20:00:02Z") == .gt);
}

test "timestampInRange since only" {
    const bounds = TimeBounds{ .since = "2026-05-15T20:00:02Z" };
    try std.testing.expect(timestampInRange("2026-05-15T20:00:02Z", bounds));
    try std.testing.expect(timestampInRange("2026-05-15T20:00:03Z", bounds));
    try std.testing.expect(!timestampInRange("2026-05-15T20:00:01Z", bounds));
}

test "timestampInRange until only" {
    const bounds = TimeBounds{ .until = "2026-05-15T20:00:02Z" };
    try std.testing.expect(timestampInRange("2026-05-15T20:00:01Z", bounds));
    try std.testing.expect(timestampInRange("2026-05-15T20:00:02Z", bounds));
    try std.testing.expect(!timestampInRange("2026-05-15T20:00:03Z", bounds));
}

test "timestampInRange closed interval" {
    const bounds = TimeBounds{
        .since = "2026-05-15T20:00:02Z",
        .until = "2026-05-15T20:00:03Z",
    };
    try std.testing.expect(!timestampInRange("2026-05-15T20:00:01Z", bounds));
    try std.testing.expect(timestampInRange("2026-05-15T20:00:02Z", bounds));
    try std.testing.expect(timestampInRange("2026-05-15T20:00:03Z", bounds));
    try std.testing.expect(!timestampInRange("2026-05-15T20:00:04Z", bounds));
}

test "parseLine rejects invalid timestamp" {
    try std.testing.expectError(
        error.InvalidTimestamp,
        parseLine("2026-05-15T20:00:01 INFO auth msg"),
    );
}
