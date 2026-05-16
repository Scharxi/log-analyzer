const std = @import("std");

const parser = @import("parser.zig");

pub const Stats = struct {
    allocator: std.mem.Allocator,
    total: usize = 0,
    info: usize = 0,
    warn: usize = 0,
    error_count: usize = 0,
    debug: usize = 0,
    per_module: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) Stats {
        return .{
            .allocator = allocator,
            .per_module = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Stats) void {
        var it = self.per_module.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.per_module.deinit();
    }

    /// `entry` module slices must remain valid for the duration of this call.
    pub fn record(self: *Stats, entry: parser.LogEntry) !void {
        self.total += 1;

        switch (entry.level) {
            .info => self.info += 1,
            .warn => self.warn += 1,
            .@"error" => self.error_count += 1,
            .debug => self.debug += 1,
        }

        const result = try self.per_module.getOrPut(entry.module);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, entry.module);
            result.value_ptr.* = 0;
        }
        result.value_ptr.* += 1;
    }

    pub fn format(self: *const Stats, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            "Stats{{ total={d}, info={d}, warn={d}, error_count={d}, debug={d}, per_module={{",
            .{ self.total, self.info, self.warn, self.error_count, self.debug },
        );
        var it = self.per_module.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeAll(", ");
            try w.print("{s}={d}", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
        try w.writeAll("} }");
    }
};

test "Stats record and deinit" {
    const allocator = std.testing.allocator;

    var stats = Stats.init(allocator);
    defer stats.deinit();

    try stats.record(.{
        .timestamp = "ts",
        .level = .info,
        .module = "auth",
        .message = "ok",
    });
    try stats.record(.{
        .timestamp = "ts",
        .level = .@"error",
        .module = "auth",
        .message = "fail",
    });

    try std.testing.expectEqual(@as(usize, 2), stats.total);
    try std.testing.expectEqual(@as(usize, 1), stats.info);
    try std.testing.expectEqual(@as(usize, 1), stats.error_count);
    try std.testing.expectEqual(@as(usize, 2), stats.per_module.get("auth").?);
}

test "Stats format output" {
    const allocator = std.testing.allocator;

    var stats = Stats.init(allocator);
    defer stats.deinit();

    try stats.record(.{
        .timestamp = "ts",
        .level = .warn,
        .module = "db",
        .message = "slow",
    });

    var buf: [256]u8 = undefined;
    var fba = std.Io.Writer.fixed(&buf);
    try stats.format(&fba.interface);
    const output = fba.interface.buffer[0..fba.interface.end];

    try std.testing.expect(std.mem.indexOf(u8, output, "total=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "warn=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "db=1") != null);
}
