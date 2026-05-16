const std = @import("std");

const parser = @import("parser.zig");
const stats = @import("stats.zig");

const read_buf_size = 64 * 1024;

pub const ScanResult = struct {
    parsed: usize = 0,
    skipped: usize = 0,
};

pub fn processLogFile(
    path: []const u8,
    io: std.Io,
    s: *stats.Stats,
    min_level: ?parser.Level,
    module: ?[]const u8,
) !ScanResult {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var buf: [read_buf_size]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const reader: *std.Io.Reader = &file_reader.interface;

    var result: ScanResult = .{};
    while (try reader.takeDelimiter('\n')) |line| {
        const entry = parser.parseLine(line) catch {
            result.skipped += 1;
            continue;
        };
        if (min_level != null and entry.level.rank() < min_level.?.rank()) {
            result.skipped += 1;
            continue;
        }
        if (module != null and !std.mem.eql(u8, entry.module, module.?)) {
            result.skipped += 1;
            continue;
        }
        try s.record(entry);
        result.parsed += 1;
    }
    return result;
}

const sample_log =
    \\2026-05-15T20:00:01Z INFO auth login ok
    \\2026-05-15T20:00:02Z WARN db connection slow
    \\2026-05-15T20:00:03Z ERROR auth invalid credentials
    \\2026-05-15T20:00:04Z DEBUG auth token refreshed
    \\not a valid log line
    \\
;

fn writeSampleLog(io: std.Io, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "sample.log", .data = sample_log });
    var path_buf: [128]u8 = undefined;
    return try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/sample.log", .{tmp.sub_path});
}

test "processLogFile parses valid lines and skips malformed" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, null, null);

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, parser.Level.warn, null);

    try std.testing.expectEqual(@as(usize, 2), scan.parsed);
    try std.testing.expectEqual(@as(usize, 3), scan.skipped);
    try std.testing.expectEqual(@as(usize, 2), s.total);
    try std.testing.expectEqual(@as(usize, 0), s.info);
    try std.testing.expectEqual(@as(usize, 1), s.warn);
    try std.testing.expectEqual(@as(usize, 1), s.error_count);
    try std.testing.expectEqual(@as(usize, 0), s.debug);
    try std.testing.expectEqual(@as(usize, 1), s.per_module.get("auth").?);
    try std.testing.expectEqual(@as(usize, 1), s.per_module.get("db").?);
}

test "processLogFile filters by module auth" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, null, "auth");

    try std.testing.expectEqual(@as(usize, 3), scan.parsed);
    try std.testing.expectEqual(@as(usize, 2), scan.skipped);
    try std.testing.expectEqual(@as(usize, 3), s.total);
    try std.testing.expectEqual(@as(usize, 1), s.info);
    try std.testing.expectEqual(@as(usize, 0), s.warn);
    try std.testing.expectEqual(@as(usize, 1), s.error_count);
    try std.testing.expectEqual(@as(usize, 1), s.debug);
    try std.testing.expectEqual(@as(usize, 3), s.per_module.get("auth").?);
    try std.testing.expect(s.per_module.get("db") == null);
}

test "processLogFile filters by module db" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, null, "db");

    try std.testing.expectEqual(@as(usize, 1), scan.parsed);
    try std.testing.expectEqual(@as(usize, 4), scan.skipped);
    try std.testing.expectEqual(@as(usize, 1), s.total);
    try std.testing.expectEqual(@as(usize, 0), s.info);
    try std.testing.expectEqual(@as(usize, 1), s.warn);
    try std.testing.expectEqual(@as(usize, 0), s.error_count);
    try std.testing.expectEqual(@as(usize, 0), s.debug);
    try std.testing.expect(s.per_module.get("auth") == null);
    try std.testing.expectEqual(@as(usize, 1), s.per_module.get("db").?);
}

test "processLogFile filters by module with no matches" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, null, "payments");

    try std.testing.expectEqual(@as(usize, 0), scan.parsed);
    try std.testing.expectEqual(@as(usize, 5), scan.skipped);
    try std.testing.expectEqual(@as(usize, 0), s.total);
    try std.testing.expect(s.per_module.count() == 0);
}

test "processLogFile filters by module and min level" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeSampleLog(io, &tmp);

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile(path, io, &s, parser.Level.warn, "auth");

    try std.testing.expectEqual(@as(usize, 1), scan.parsed);
    try std.testing.expectEqual(@as(usize, 4), scan.skipped);
    try std.testing.expectEqual(@as(usize, 1), s.total);
    try std.testing.expectEqual(@as(usize, 0), s.info);
    try std.testing.expectEqual(@as(usize, 0), s.warn);
    try std.testing.expectEqual(@as(usize, 1), s.error_count);
    try std.testing.expectEqual(@as(usize, 0), s.debug);
    try std.testing.expectEqual(@as(usize, 1), s.per_module.get("auth").?);
    try std.testing.expect(s.per_module.get("db") == null);
}
