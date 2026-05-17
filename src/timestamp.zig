const std = @import("std");
const entry = @import("entry.zig");

pub const ParseError = entry.ParseError;

pub const canonical_len: usize = 20;

/// UTC ISO timestamps in canonical form compare correctly as byte strings.
pub fn compareTimestamp(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

pub fn timestampInRange(ts: []const u8, bounds: entry.TimeBounds) bool {
    if (bounds.since) |since| {
        if (compareTimestamp(ts, since) == .lt) return false;
    }
    if (bounds.until) |until| {
        if (compareTimestamp(ts, until) == .gt) return false;
    }
    return true;
}

/// Validates `YYYY-MM-DDTHH:MM:SSZ`.
pub fn parseCanonical(s: []const u8) ParseError!void {
    if (s.len != canonical_len) return error.InvalidTimestamp;

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
        if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
    }
}

/// Validates and copies a canonical timestamp into `out`.
pub fn copyCanonical(s: []const u8, out: *[canonical_len]u8) ParseError!void {
    try parseCanonical(s);
    @memcpy(out, s[0..canonical_len]);
}

const DateTimeParts = struct {
    year: u16 = 0,
    month: u8 = 0,
    day: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn parseTwoDigits(s: []const u8) ?u8 {
    if (s.len < 2 or !isDigit(s[0]) or !isDigit(s[1])) return null;
    return (s[0] - '0') * 10 + (s[1] - '0');
}

fn parseFourDigits(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var n: u16 = 0;
    for (s[0..4]) |c| {
        if (!isDigit(c)) return null;
        n = n * 10 + (c - '0');
    }
    return n;
}

fn monthFromAbbrev(s: []const u8) ?u8 {
    const months = [_][]const u8{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    for (months, 0..) |name, i| {
        if (std.ascii.eqlIgnoreCase(s, name)) return @intCast(i + 1);
    }
    return null;
}

fn writeTwo(out: []u8, offset: *usize, value: u8) void {
    out[offset.*] = '0' + @divFloor(value, 10);
    out[offset.* + 1] = '0' + (value % 10);
    offset.* += 2;
}

fn writeFour(out: []u8, offset: *usize, value: u16) void {
    out[offset.*] = '0' + @as(u8, @intCast(@divFloor(value, 1000) % 10));
    out[offset.* + 1] = '0' + @as(u8, @intCast(@divFloor(value, 100) % 10));
    out[offset.* + 2] = '0' + @as(u8, @intCast(@divFloor(value, 10) % 10));
    out[offset.* + 3] = '0' + @as(u8, @intCast(value % 10));
    offset.* += 4;
}

/// Writes `YYYY-MM-DDTHH:MM:SSZ` into `out`.
pub fn writeCanonical(parts: DateTimeParts, out: *[canonical_len]u8) void {
    var i: usize = 0;
    writeFour(out, &i, parts.year);
    out[i] = '-';
    i += 1;
    writeTwo(out, &i, parts.month);
    out[i] = '-';
    i += 1;
    writeTwo(out, &i, parts.day);
    out[i] = 'T';
    i += 1;
    writeTwo(out, &i, parts.hour);
    out[i] = ':';
    i += 1;
    writeTwo(out, &i, parts.minute);
    out[i] = ':';
    i += 1;
    writeTwo(out, &i, parts.second);
    out[i] = 'Z';
}

/// Match `pattern` against `input` at `input` start; returns consumed byte count.
pub fn matchPattern(pattern: []const u8, input: []const u8, parts: *DateTimeParts) ParseError!usize {
    var pi: usize = 0;
    var ii: usize = 0;

    while (ii < input.len and (input[ii] == ' ' or input[ii] == '\t')) ii += 1;

    while (pi < pattern.len) {
        if (pattern[pi] == '%' and pi + 1 < pattern.len) {
            pi += 1;
            const spec = pattern[pi];
            pi += 1;
            switch (spec) {
                'Y' => {
                    const y = parseFourDigits(input[ii..]) orelse return error.InvalidTimestamp;
                    parts.year = y;
                    ii += 4;
                },
                'm' => {
                    const m = parseTwoDigits(input[ii..]) orelse return error.InvalidTimestamp;
                    parts.month = m;
                    ii += 2;
                },
                'd' => {
                    const d = parseTwoDigits(input[ii..]) orelse return error.InvalidTimestamp;
                    parts.day = d;
                    ii += 2;
                },
                'H' => {
                    const h = parseTwoDigits(input[ii..]) orelse return error.InvalidTimestamp;
                    parts.hour = h;
                    ii += 2;
                },
                'M' => {
                    const m = parseTwoDigits(input[ii..]) orelse return error.InvalidTimestamp;
                    parts.minute = m;
                    ii += 2;
                },
                'S' => {
                    const s = parseTwoDigits(input[ii..]) orelse return error.InvalidTimestamp;
                    parts.second = s;
                    ii += 2;
                },
                'b' => {
                    if (ii + 3 > input.len) return error.InvalidTimestamp;
                    parts.month = monthFromAbbrev(input[ii .. ii + 3]) orelse return error.InvalidTimestamp;
                    ii += 3;
                },
                '3' => {
                    if (pi >= pattern.len or pattern[pi] != 'f') return error.InvalidTimestamp;
                    pi += 1;
                    if (ii + 3 > input.len) return error.InvalidTimestamp;
                    for (input[ii .. ii + 3]) |c| {
                        if (!isDigit(c)) return error.InvalidTimestamp;
                    }
                    ii += 3;
                },
                'z' => {
                    if (ii >= input.len) return error.InvalidTimestamp;
                    if (input[ii] == 'Z') {
                        ii += 1;
                    } else if (input[ii] == '+' or input[ii] == '-') {
                        if (input.len - ii < 5) return error.InvalidTimestamp;
                        ii += 5;
                    } else {
                        return error.InvalidTimestamp;
                    }
                },
                else => return error.InvalidTimestamp,
            }
            continue;
        }

        if (ii >= input.len or input[ii] != pattern[pi]) return error.InvalidTimestamp;
        ii += 1;
        pi += 1;
    }

    return ii;
}

/// Find first `[` ... `]` segment in line and parse inner text with pattern (without brackets in pattern).
pub fn matchBracketedPattern(pattern: []const u8, line: []const u8, parts: *DateTimeParts) ParseError!struct { start: usize, end: usize } {
    const open = std.mem.indexOfScalar(u8, line, '[') orelse return error.InvalidTimestamp;
    const close = std.mem.indexOfScalar(u8, line[open + 1 ..], ']') orelse return error.InvalidTimestamp;
    const close_abs = open + 1 + close;
    const inner = line[open + 1 .. close_abs];
    _ = try matchPattern(pattern, inner, parts);
    return .{ .start = open, .end = close_abs + 1 };
}

pub fn parseToCanonical(pattern: []const u8, at: []const u8, line: []const u8, out: *[canonical_len]u8) ParseError!usize {
    var parts: DateTimeParts = .{};

    const consumed: usize = if (std.mem.eql(u8, at, "regex"))
        blk: {
            const span = try matchBracketedPattern(pattern, line, &parts);
            break :blk span.end;
        }
    else blk: {
        if (!std.mem.eql(u8, at, "start")) return error.InvalidProfile;
        break :blk try matchPattern(pattern, line, &parts);
    };

    writeCanonical(parts, out);
    return consumed;
}

test "parseCanonical valid" {
    var out: [canonical_len]u8 = undefined;
    try copyCanonical("2026-05-15T20:00:01Z", &out);
    try std.testing.expectEqualStrings("2026-05-15T20:00:01Z", &out);
}

test "matchPattern iso structured" {
    var parts: DateTimeParts = .{};
    const n = try matchPattern("%Y-%m-%dT%H:%M:%SZ", "2026-05-15T20:00:01Z INFO", &parts);
    try std.testing.expectEqual(@as(usize, 20), n);
    try std.testing.expectEqual(@as(u16, 2026), parts.year);
}

test "matchPattern python style" {
    var parts: DateTimeParts = .{};
    const n = try matchPattern("%Y-%m-%d %H:%M:%S,%3f", "2026-05-03 18:29:23,784 INFO:", &parts);
    try std.testing.expectEqual(@as(usize, 23), n);
    var out: [canonical_len]u8 = undefined;
    writeCanonical(parts, &out);
    try std.testing.expectEqualStrings("2026-05-03T18:29:23Z", &out);
}

test "matchBracketedPattern apache" {
    const line = "8.134.9.15 - - [17/May/2026:00:56:41 +0000] \"GET /x HTTP/1.1\"";
    var parts: DateTimeParts = .{};
    const span = try matchBracketedPattern("%d/%b/%Y:%H:%M:%S %z", line, &parts);
    try std.testing.expect(span.start < span.end);
    var out: [canonical_len]u8 = undefined;
    writeCanonical(parts, &out);
    try std.testing.expectEqualStrings("2026-05-17T00:56:41Z", &out);
}
