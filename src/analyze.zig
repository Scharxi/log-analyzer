const std = @import("std");

const entry = @import("entry.zig");
const timestamp = @import("timestamp.zig");
const profile = @import("profile/mod.zig");
const stats = @import("stats.zig");

const read_buf_size = 64 * 1024;
pub const max_peek_lines = 5;

pub const ScanResult = struct {
    parsed: usize = 0,
    skipped: usize = 0,
};

pub const PeekBuffer = struct {
    lines: [max_peek_lines][]const u8 = undefined,
    storage: [max_peek_lines][512]u8 = undefined,
    count: usize = 0,

    pub fn slice(self: *const PeekBuffer) []const []const u8 {
        return self.lines[0..self.count];
    }
};

fn processLine(
    line: []const u8,
    p: *const profile.Profile,
    s: *stats.Stats,
    min_level: ?entry.Level,
    module: ?[]const u8,
    grep: ?[]const u8,
    time_bounds: entry.TimeBounds,
    result: *ScanResult,
) !void {
    const log_entry = profile.parseLine(p, line) catch {
        result.skipped += 1;
        return;
    };
    if (min_level != null and log_entry.level.rank() < min_level.?.rank()) {
        result.skipped += 1;
        return;
    }
    if (module != null and !std.mem.eql(u8, log_entry.module, module.?)) {
        result.skipped += 1;
        return;
    }
    if (grep != null and !entry.messageMatches(log_entry.message, grep.?)) {
        result.skipped += 1;
        return;
    }
    if (time_bounds.since != null or time_bounds.until != null) {
        const ts_str: []const u8 = &log_entry.timestamp;
        if (!timestamp.timestampInRange(ts_str, time_bounds)) {
            result.skipped += 1;
            return;
        }
    }
    try s.record(log_entry);
    result.parsed += 1;
}

pub fn peekReader(reader: *std.Io.Reader, peek: *PeekBuffer) !void {
    peek.count = 0;
    while (peek.count < max_peek_lines) {
        const line = (reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return,
            else => |e| return e,
        }) orelse return;
        if (line.len == 0) continue;
        if (line.len > peek.storage[0].len) return error.ReadFailed;
        @memcpy(peek.storage[peek.count][0..line.len], line);
        peek.lines[peek.count] = peek.storage[peek.count][0..line.len];
        peek.count += 1;
    }
}

pub fn processLogReader(
    reader: *std.Io.Reader,
    s: *stats.Stats,
    p: *const profile.Profile,
    min_level: ?entry.Level,
    module: ?[]const u8,
    grep: ?[]const u8,
    time_bounds: entry.TimeBounds,
    prefetched: []const []const u8,
) !ScanResult {
    var result: ScanResult = .{};

    for (prefetched) |line| {
        try processLine(line, p, s, min_level, module, grep, time_bounds, &result);
    }

    while (try reader.takeDelimiter('\n')) |line| {
        try processLine(line, p, s, min_level, module, grep, time_bounds, &result);
    }
    return result;
}

pub fn processLogFile(
    path: []const u8,
    io: std.Io,
    s: *stats.Stats,
    p: *const profile.Profile,
    min_level: ?entry.Level,
    module: ?[]const u8,
    grep: ?[]const u8,
    time_bounds: entry.TimeBounds,
    prefetched: []const []const u8,
) !ScanResult {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var buf: [read_buf_size]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return processLogReader(&file_reader.interface, s, p, min_level, module, grep, time_bounds, prefetched);
}

pub fn processLogStdin(
    io: std.Io,
    s: *stats.Stats,
    p: *const profile.Profile,
    min_level: ?entry.Level,
    module: ?[]const u8,
    grep: ?[]const u8,
    time_bounds: entry.TimeBounds,
    prefetched: []const []const u8,
) !ScanResult {
    var buf: [read_buf_size]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &buf);
    return processLogReader(&stdin_reader.interface, s, p, min_level, module, grep, time_bounds, prefetched);
}

pub fn peekLogFile(path: []const u8, io: std.Io, peek: *PeekBuffer) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var buf: [read_buf_size]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return peekReader(&file_reader.interface, peek);
}

pub fn peekLogStdin(io: std.Io, peek: *PeekBuffer) !void {
    var buf: [read_buf_size]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &buf);
    return peekReader(&stdin_reader.interface, peek);
}

const sample_log =
    \\2026-05-15T20:00:01Z INFO auth login ok
    \\2026-05-15T20:00:02Z WARN db connection slow
    \\2026-05-15T20:00:03Z ERROR auth invalid credentials
    \\2026-05-15T20:00:04Z DEBUG auth token refreshed
    \\not a valid log line
    \\
;

fn defaultIsoProfile() !*const profile.Profile {
    const gpa = std.testing.allocator;
    const p = try gpa.create(profile.Profile);
    p.* = try profile.loadPreset(gpa, "iso-structured");
    return p;
}

fn writeSampleLog(io: std.Io, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.log", .data = sample_log });
    var path_buf: [128]u8 = undefined;
    return try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/sample.log", .{tmp.sub_path});
}

test "processLogFile parses valid lines and skips malformed" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const p = try defaultIsoProfile();
    defer {
        p.deinit(allocator);
        allocator.destroy(p);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, p, null, null, null, .{}, &.{});

    try std.testing.expectEqual(@as(usize, 4), scan.parsed);
    try std.testing.expectEqual(@as(usize, 1), scan.skipped);
    try std.testing.expectEqual(@as(usize, 4), s.total);
    try std.testing.expectEqual(@as(usize, 1), s.info);
    try std.testing.expectEqual(@as(usize, 1), s.warn);
    try std.testing.expectEqual(@as(usize, 1), s.error_count);
    try std.testing.expectEqual(@as(usize, 1), s.debug);
    try std.testing.expectEqual(@as(usize, 3), s.per_module.get("auth").?);
    try std.testing.expectEqual(@as(usize, 1), s.per_module.get("db").?);
}

test "processLogFile filters by min level" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const p = try defaultIsoProfile();
    defer {
        p.deinit(allocator);
        allocator.destroy(p);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, p, entry.Level.warn, null, null, .{}, &.{});

    try std.testing.expectEqual(@as(usize, 2), scan.parsed);
    try std.testing.expectEqual(@as(usize, 3), scan.skipped);
}

test "processLogFile filters by module auth" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const p = try defaultIsoProfile();
    defer {
        p.deinit(allocator);
        allocator.destroy(p);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, p, null, "auth", null, .{}, &.{});

    try std.testing.expectEqual(@as(usize, 3), scan.parsed);
    try std.testing.expectEqual(@as(usize, 2), scan.skipped);
}

test "processLogFile filters by since timestamp" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const p = try defaultIsoProfile();
    defer {
        p.deinit(allocator);
        allocator.destroy(p);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, p, null, null, null, .{
        .since = "2026-05-15T20:00:02Z",
    }, &.{});

    try std.testing.expectEqual(@as(usize, 3), scan.parsed);
    try std.testing.expectEqual(@as(usize, 2), scan.skipped);
}

test "processLogFile filters by grep substring in message" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const p = try defaultIsoProfile();
    defer {
        p.deinit(allocator);
        allocator.destroy(p);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, p, null, null, "invalid", .{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), scan.parsed);
    try std.testing.expectEqual(@as(usize, 4), scan.skipped);
}
