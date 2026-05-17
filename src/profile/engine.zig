const std = @import("std");
const entry = @import("../entry.zig");
const timestamp = @import("../timestamp.zig");
const schema = @import("schema.zig");
const load = @import("load.zig");

const FieldBag = struct {
    names: [schema.max_fields][]const u8,
    values: [schema.max_fields][]const u8,
    count: usize = 0,

    fn put(self: *FieldBag, name: []const u8, value: []const u8) entry.ParseError!void {
        if (self.count >= schema.max_fields) return error.InvalidProfile;
        self.names[self.count] = name;
        self.values[self.count] = value;
        self.count += 1;
    }

    fn get(self: *const FieldBag, name: []const u8) ?[]const u8 {
        for (self.names[0..self.count], self.values[0..self.count]) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }
};

fn trimSpace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn applyTransform(value: []const u8, transform: schema.Transform, strip_ext: ?[]const u8) []const u8 {
    return switch (transform) {
        .none => value,
        .basename, .basename_strip_ext => blk: {
            const base = std.fs.path.basename(value);
            if (transform == .basename_strip_ext) {
                if (strip_ext) |ext| {
                    if (std.mem.endsWith(u8, base, ext)) {
                        break :blk base[0 .. base.len - ext.len];
                    }
                }
            }
            break :blk base;
        },
    };
}

fn skipTokens(line: []const u8, cursor: *usize, count: usize) entry.ParseError!void {
    var n: usize = 0;
    while (n < count) : (n += 1) {
        while (cursor.* < line.len and line[cursor.*] == ' ') cursor.* += 1;
        if (cursor.* >= line.len) return error.MissingField;
        while (cursor.* < line.len and line[cursor.*] != ' ') cursor.* += 1;
    }
}

fn readToken(line: []const u8, cursor: *usize, separator: ?[]const u8) entry.ParseError![]const u8 {
    while (cursor.* < line.len and line[cursor.*] == ' ') cursor.* += 1;
    if (cursor.* >= line.len) return error.MissingField;
    const start = cursor.*;
    while (cursor.* < line.len and line[cursor.*] != ' ') cursor.* += 1;
    var end = cursor.*;
    if (separator) |sep| {
        if (end > start and end - sep.len >= start and std.mem.eql(u8, line[end - sep.len .. end], sep)) {
            end -= sep.len;
        }
    }
    return line[start..end];
}

fn readUntil(line: []const u8, cursor: *usize, literal: []const u8) entry.ParseError![]const u8 {
    const start = cursor.*;
    const idx = std.mem.indexOf(u8, line[cursor.*..], literal) orelse return error.MissingField;
    const end = cursor.* + idx;
    cursor.* = end;
    return trimSpace(line[start..end]);
}

fn readRest(line: []const u8, cursor: *usize) []const u8 {
    while (cursor.* < line.len and line[cursor.*] == ' ') cursor.* += 1;
    return trimSpace(line[cursor.*..]);
}

fn readQuoted(line: []const u8, cursor: *usize) entry.ParseError![]const u8 {
    while (cursor.* < line.len and line[cursor.*] != '"') cursor.* += 1;
    if (cursor.* >= line.len or line[cursor.*] != '"') return error.MissingField;
    cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < line.len and line[cursor.*] != '"') cursor.* += 1;
    if (cursor.* >= line.len) return error.MissingField;
    const value = line[start..cursor.*];
    cursor.* += 1;
    return value;
}

fn readRegexSuffix(line: []const u8, pattern: []const u8, group: usize) entry.ParseError![]const u8 {
    _ = pattern;
    _ = group;
    const trailer = " [in ";
    const idx = std.mem.lastIndexOf(u8, line, trailer) orelse return error.MissingField;
    const after = idx + trailer.len;
    const close_rel = std.mem.indexOf(u8, line[after..], "]") orelse return error.MissingField;
    const seg = line[after .. after + close_rel];
    const colon = std.mem.lastIndexOfScalar(u8, seg, ':') orelse return seg;
    return seg[0..colon];
}

fn resolveLevel(profile: *const schema.Profile, fields: *const FieldBag) entry.ParseError!entry.Level {
    const raw = fields.get(profile.level.field) orelse return error.MissingField;

    if (profile.level.derive.len > 0) {
        const status = std.fmt.parseInt(i32, raw, 10) catch return error.InvalidLevel;
        for (profile.level.derive) |r| {
            if (status >= r.min and status <= r.max) return r.level;
        }
        return error.InvalidLevel;
    }

    return entry.parseLevel(raw, profile.level.aliases);
}

pub fn parseLine(profile: *const schema.Profile, line: []const u8) entry.ParseError!entry.LogEntry {
    if (line.len == 0) return error.EmptyLine;

    var cursor: usize = 0;
    var fields: FieldBag = .{ .names = undefined, .values = undefined, .count = 0 };

    for (profile.extract) |step| {
        if (step.type != .skip_tokens) break;
        try skipTokens(line, &cursor, step.count);
    }

    var ts: [timestamp.canonical_len]u8 = undefined;
    const ts_end = try timestamp.parseToCanonical(
        profile.timestamp.pattern,
        profile.timestamp.at,
        if (std.mem.eql(u8, profile.timestamp.at, "regex")) line else line[cursor..],
        &ts,
    );

    if (std.mem.eql(u8, profile.timestamp.at, "start")) {
        cursor += ts_end;
    } else {
        const open = std.mem.indexOfScalar(u8, line, '[') orelse return error.InvalidTimestamp;
        const close = std.mem.indexOfScalar(u8, line[open + 1 ..], ']') orelse return error.InvalidTimestamp;
        cursor = open + 1 + close + 1;
    }

    var module: []const u8 = "";
    var message: []const u8 = "";

    for (profile.extract) |step| {
        switch (step.type) {
            .skip_tokens => continue,
            .token => {
                const raw = try readToken(line, &cursor, step.separator);
                const value = applyTransform(raw, step.transform, step.strip_ext);
                try fields.put(step.field, value);
                if (std.mem.eql(u8, step.field, "module")) module = value;
                if (std.mem.eql(u8, step.field, "message")) message = value;
            },
            .until => {
                const lit = step.literal orelse return error.InvalidProfile;
                const value = readUntil(line, &cursor, lit) catch readRest(line, &cursor);
                try fields.put(step.field, value);
                if (std.mem.eql(u8, step.field, "message")) message = value;
            },
            .rest => {
                const value = readRest(line, &cursor);
                try fields.put(step.field, value);
                if (std.mem.eql(u8, step.field, "message")) message = value;
            },
            .quoted => {
                const value = try readQuoted(line, &cursor);
                try fields.put(step.field, value);
                if (std.mem.eql(u8, step.field, "message")) message = value;
            },
            .regex_suffix => {
                const pat = step.pattern orelse return error.InvalidProfile;
                const raw = try readRegexSuffix(line, pat, step.group);
                const value = applyTransform(raw, step.transform, step.strip_ext);
                try fields.put(step.field, value);
                if (std.mem.eql(u8, step.field, "module")) module = value;
            },
        }
    }

    if (module.len == 0) {
        if (fields.get("module")) |m| module = m else if (fields.get("status")) |s| module = s;
    }
    if (message.len == 0) {
        if (fields.get("message")) |m| message = m;
    }

    const level = try resolveLevel(profile, &fields);

    return .{
        .timestamp = ts,
        .level = level,
        .module = module,
        .message = message,
    };
}

test "engine iso-structured preset" {
    const gpa = std.testing.allocator;
    const p = try load.loadPreset(gpa, "iso-structured");
    defer p.deinit(gpa);

    const line = "2026-05-15T20:00:01Z INFO auth login ok";
    const e = try parseLine(&p, line);
    try std.testing.expectEqual(.info, e.level);
    try std.testing.expectEqualStrings("auth", e.module);
    try std.testing.expectEqualStrings("login ok", e.message);
    try std.testing.expectEqualStrings("2026-05-15T20:00:01Z", &e.timestamp);
}

test "engine level-colon preset" {
    const gpa = std.testing.allocator;
    const p = try load.loadPreset(gpa, "level-colon-suffix");
    defer p.deinit(gpa);

    const line = "2026-05-03 18:59:03,083 WARNING: Page not found [in /app/routes/x.py:1]";
    const e = try parseLine(&p, line);
    try std.testing.expectEqual(.warn, e.level);
    try std.testing.expectEqualStrings("x", e.module);
}

test "engine apache combined preset" {
    const gpa = std.testing.allocator;
    const p = try load.loadPreset(gpa, "bracket-timestamp-quoted-request");
    defer p.deinit(gpa);

    const line = "8.134.9.15 - - [17/May/2026:00:56:41 +0000] \"GET /dump.sql HTTP/1.1\" 400 248 \"-\" \"agent\" \"-\"";
    const e = try parseLine(&p, line);
    try std.testing.expectEqual(.warn, e.level);
    try std.testing.expectEqualStrings("400", e.module);
    try std.testing.expectEqualStrings("GET /dump.sql HTTP/1.1", e.message);
}
