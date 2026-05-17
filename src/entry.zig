const std = @import("std");

pub const ParseError = error{
    EmptyLine,
    MissingField,
    InvalidLevel,
    InvalidTimestamp,
    InvalidProfile,
};

/// Inclusive lower/upper bounds on canonical log timestamps (`YYYY-MM-DDTHH:MM:SSZ`).
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
        return parseLevel(s, &.{});
    }

    pub fn parseWithAliases(s: []const u8, aliases: []const Alias) ParseError!Level {
        for (aliases) |a| {
            if (std.ascii.eqlIgnoreCase(s, a.from)) {
                return std.meta.stringToEnum(Level, a.to) orelse return error.InvalidLevel;
            }
        }
        return parseLevel(s, &.{});
    }
};

pub const Alias = struct {
    from: []const u8,
    to: []const u8,
};

/// Parsed fields borrow from `line` except `timestamp`, which is always canonical ISO UTC.
pub const LogEntry = struct {
    timestamp: [20]u8,
    level: Level,
    module: []const u8,
    message: []const u8,
};

fn toLowerAscii(buf: []u8) void {
    for (buf) |*c| {
        c.* = std.ascii.toLower(c.*);
    }
}

pub fn parseLevel(s: []const u8, aliases: []const Alias) ParseError!Level {
    for (aliases) |a| {
        if (std.ascii.eqlIgnoreCase(s, a.from)) {
            return std.meta.stringToEnum(Level, a.to) orelse return error.InvalidLevel;
        }
    }

    var tmp: [16]u8 = undefined;
    if (s.len == 0 or s.len > tmp.len) return error.InvalidLevel;

    @memcpy(tmp[0..s.len], s);
    toLowerAscii(tmp[0..s.len]);

    if (std.meta.stringToEnum(Level, tmp[0..s.len])) |lvl| {
        return lvl;
    }
    return error.InvalidLevel;
}

/// Returns true when `pattern` occurs in `message` (literal substring).
pub fn messageMatches(message: []const u8, pattern: []const u8) bool {
    return std.mem.indexOf(u8, message, pattern) != null;
}
