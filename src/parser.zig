const std = @import("std");

pub const ParseError = error{
    EmptyLine,
    MissingField,
    InvalidLevel,
};

pub const Level = enum {
    info,
    warn,
    @"error",
    debug,
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
