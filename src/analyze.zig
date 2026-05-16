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
        try s.record(entry);
        result.parsed += 1;
    }
    return result;
}

test "processLogFile on fixture" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var s = stats.Stats.init(allocator);
    defer s.deinit();

    const scan = try processLogFile("test/fixtures/sample.log", io, &s);

    try std.testing.expectEqual(@as(usize, 4), scan.parsed);
    try std.testing.expectEqual(@as(usize, 1), scan.skipped);
    try std.testing.expectEqual(@as(usize, 4), s.total);
    try std.testing.expectEqual(@as(usize, 1), s.info);
    try std.testing.expectEqual(@as(usize, 1), s.warn);
    try std.testing.expectEqual(@as(usize, 1), s.error_count);
    try std.testing.expectEqual(@as(usize, 1), s.debug);
    try std.testing.expectEqual(@as(usize, 2), s.per_module.get("auth").?);
    try std.testing.expectEqual(@as(usize, 1), s.per_module.get("db").?);
}
