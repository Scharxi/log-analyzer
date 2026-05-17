const std = @import("std");
const entry = @import("entry.zig");
const timestamp = @import("timestamp.zig");
const profile = @import("profile/mod.zig");

pub const ParseError = entry.ParseError;
pub const TimeBounds = entry.TimeBounds;
pub const Level = entry.Level;
pub const LogEntry = entry.LogEntry;
pub const Profile = profile.Profile;

pub const parseTimestamp = timestamp.parseCanonical;
pub const compareTimestamp = timestamp.compareTimestamp;
pub const timestampInRange = timestamp.timestampInRange;
pub const messageMatches = entry.messageMatches;

var default_profile_storage: ?profile.Profile = null;

fn defaultProfile() ParseError!*const Profile {
    if (default_profile_storage == null) {
        default_profile_storage = profile.defaultProfile(std.heap.page_allocator) catch return error.InvalidProfile;
    }
    return &default_profile_storage.?;
}

/// Parses a line using the default `iso-structured` profile.
pub fn parseLine(line: []const u8) ParseError!LogEntry {
    const p = try defaultProfile();
    return profile.parseLine(p, line);
}

pub fn parseLineWithProfile(p: *const Profile, line: []const u8) ParseError!LogEntry {
    return profile.parseLine(p, line);
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
        const entry_parsed = try parseLine(line);
        try std.testing.expectEqual(c.expected, entry_parsed.level);
    }
}

test "parse basic log line" {
    const line = "2026-05-15T20:00:01Z INFO auth login ok";

    const entry_parsed = try parseLine(line);
    try std.testing.expectEqualStrings("2026-05-15T20:00:01Z", &entry_parsed.timestamp);
    try std.testing.expectEqual(.info, entry_parsed.level);
    try std.testing.expectEqualStrings("auth", entry_parsed.module);
    try std.testing.expectEqualStrings("login ok", entry_parsed.message);
}

test "parse line with empty message" {
    const line = "2026-05-15T20:00:01Z INFO auth";
    const entry_parsed = try parseLine(line);
    try std.testing.expectEqualStrings("", entry_parsed.message);
}

test "parse malformed lines" {
    try std.testing.expectError(error.EmptyLine, parseLine(""));
    try std.testing.expectError(error.MissingField, parseLine("2026-05-15T20:00:01Z INFO"));
    try std.testing.expectError(error.InvalidLevel, parseLine("2026-05-15T20:00:01Z BOGUS auth msg"));
}

test "parseLine rejects invalid timestamp" {
    try std.testing.expectError(
        error.InvalidTimestamp,
        parseLine("2026-05-15T20:00:01 INFO auth msg"),
    );
}

test "timestampInRange since only" {
    const bounds = TimeBounds{ .since = "2026-05-15T20:00:02Z" };
    try std.testing.expect(timestampInRange("2026-05-15T20:00:02Z", bounds));
    try std.testing.expect(timestampInRange("2026-05-15T20:00:03Z", bounds));
    try std.testing.expect(!timestampInRange("2026-05-15T20:00:01Z", bounds));
}

test "messageMatches substring" {
    try std.testing.expect(messageMatches("login failed for user", "login failed"));
    try std.testing.expect(!messageMatches("login ok", "login failed"));
}
