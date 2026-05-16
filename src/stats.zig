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

    const FormatError = std.Io.Writer.Error || std.Io.Terminal.SetColorError;

    fn writeLevelField(
        w: *std.Io.Writer,
        terminal: ?std.Io.Terminal,
        label: []const u8,
        value: usize,
        color: std.Io.Terminal.Color,
    ) FormatError!void {
        try w.writeAll(label);
        if (terminal) |t| {
            try t.setColor(color);
            try w.print("{d}", .{value});
            try t.setColor(.reset);
        } else {
            try w.print("{d}", .{value});
        }
    }

    pub fn format(
        self: *const Stats,
        w: *std.Io.Writer,
        terminal: ?std.Io.Terminal,
    ) FormatError!void {
        try w.writeAll("Stats{ total=");
        try w.print("{d}", .{self.total});
        try w.writeAll(", ");
        try writeLevelField(w, terminal, "info=", self.info, .green);
        try w.writeAll(", ");
        try writeLevelField(w, terminal, "warn=", self.warn, .yellow);
        try w.writeAll(", ");
        try writeLevelField(w, terminal, "error_count=", self.error_count, .red);
        try w.writeAll(", ");
        try writeLevelField(w, terminal, "debug=", self.debug, .cyan);
        try w.writeAll(", per_module={");
        var it = self.per_module.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try w.writeAll(", ");
            try w.print("{s}={d}", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }
        try w.writeAll("} }");
    }

    const max_modules = 256;

    fn collectSortedModuleKeys(self: *const Stats, keys: [][]const u8) usize {
        var count: usize = 0;
        var it = self.per_module.iterator();
        while (it.next()) |entry| {
            keys[count] = entry.key_ptr.*;
            count += 1;
        }
        std.mem.sort(
            []const u8,
            keys[0..count],
            {},
            struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan,
        );
        return count;
    }

    fn writeLevelRow(
        w: *std.Io.Writer,
        terminal: ?std.Io.Terminal,
        label: []const u8,
        value: usize,
        color: std.Io.Terminal.Color,
    ) FormatError!void {
        try w.writeAll("  ");
        if (terminal) |t| {
            try t.setColor(color);
            try w.print("{s:<7}", .{label});
            try t.setColor(.reset);
        } else {
            try w.print("{s:<7}", .{label});
        }
        if (terminal) |t| {
            try t.setColor(color);
            try w.print("{d}\n", .{value});
            try t.setColor(.reset);
        } else {
            try w.print("{d}\n", .{value});
        }
    }

    pub fn formatTable(
        self: *const Stats,
        parsed: usize,
        skipped: usize,
        w: *std.Io.Writer,
        terminal: ?std.Io.Terminal,
    ) FormatError!void {
        try w.writeAll("Log analysis summary\n");
        try w.writeAll("====================\n");
        try w.print("Total lines:  {d}\n", .{self.total});
        try w.print("Parsed:       {d}\n", .{parsed});
        try w.print("Skipped:      {d}\n\n", .{skipped});

        try w.writeAll("Levels\n");
        try w.writeAll("------\n");
        try writeLevelRow(w, terminal, "DEBUG", self.debug, .cyan);
        try writeLevelRow(w, terminal, "INFO", self.info, .green);
        try writeLevelRow(w, terminal, "WARN", self.warn, .yellow);
        try writeLevelRow(w, terminal, "ERROR", self.error_count, .red);

        var keys: [max_modules][]const u8 = undefined;
        const module_count = self.collectSortedModuleKeys(&keys);
        if (module_count == 0) return;

        var max_name_len: usize = "Module".len;
        for (keys[0..module_count]) |key| {
            max_name_len = @max(max_name_len, key.len);
        }

        try w.writeAll("\nModules\n");
        try w.writeAll("-------\n");
        for (keys[0..module_count]) |key| {
            try w.print("  {s}", .{key});
            const pad = max_name_len - key.len + 2;
            var i: usize = 0;
            while (i < pad) : (i += 1) try w.writeAll(" ");
            try w.print("{d}\n", .{self.per_module.get(key).?});
        }
    }

    pub fn formatJson(
        self: *const Stats,
        parsed: usize,
        skipped: usize,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const json_opts: std.json.Stringify.Options = .{};

        try w.writeAll("{\n");
        try w.print("  \"total\": {d},\n", .{self.total});
        try w.print("  \"info\": {d},\n", .{self.info});
        try w.print("  \"warn\": {d},\n", .{self.warn});
        try w.print("  \"error_count\": {d},\n", .{self.error_count});
        try w.print("  \"debug\": {d},\n", .{self.debug});
        try w.writeAll("  \"per_module\": {\n");

        var keys: [max_modules][]const u8 = undefined;
        const count = self.collectSortedModuleKeys(&keys);
        if (count >= max_modules) return error.WriteFailed;

        for (keys[0..count], 0..) |key, idx| {
            try w.writeAll("    ");
            try std.json.Stringify.encodeJsonString(key, json_opts, w);
            try w.print(": {d}", .{self.per_module.get(key).?});
            if (idx + 1 < count) try w.writeAll(",");
            try w.writeAll("\n");
        }

        try w.writeAll("  },\n");
        try w.print("  \"parsed\": {d},\n", .{parsed});
        try w.print("  \"skipped\": {d}\n", .{skipped});
        try w.writeAll("}\n");
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
    var w = std.Io.Writer.fixed(&buf);
    try stats.format(&w, null);
    const output = w.buffer[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, output, "total=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "warn=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "db=1") != null);
}

test "Stats format colors level counts" {
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
        .level = .warn,
        .module = "db",
        .message = "slow",
    });
    try stats.record(.{
        .timestamp = "ts",
        .level = .@"error",
        .module = "auth",
        .message = "fail",
    });

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const terminal = std.Io.Terminal{
        .writer = &w,
        .mode = .escape_codes,
    };
    try stats.format(&w, terminal);
    const output = w.buffer[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, output, "info=\x1b[32m1\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "warn=\x1b[33m1\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "error_count=\x1b[31m1\x1b[0m") != null);
}

test "Stats formatJson output" {
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
        .level = .warn,
        .module = "db",
        .message = "slow",
    });
    try stats.record(.{
        .timestamp = "ts",
        .level = .@"error",
        .module = "auth",
        .message = "fail",
    });

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try stats.formatJson(3, 2, &w);
    const output = w.buffer[0..w.end];

    const expected =
        \\{
        \\  "total": 3,
        \\  "info": 1,
        \\  "warn": 1,
        \\  "error_count": 1,
        \\  "debug": 0,
        \\  "per_module": {
        \\    "auth": 2,
        \\    "db": 1
        \\  },
        \\  "parsed": 3,
        \\  "skipped": 2
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, output);
}

test "Stats formatTable output" {
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
        .level = .warn,
        .module = "db",
        .message = "slow",
    });
    try stats.record(.{
        .timestamp = "ts",
        .level = .@"error",
        .module = "auth",
        .message = "fail",
    });

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try stats.formatTable(3, 1, &w, null);
    const output = w.buffer[0..w.end];

    try std.testing.expect(std.mem.indexOf(u8, output, "Log analysis summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Total lines:  3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Skipped:      1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "INFO    1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "auth  2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "db    1") != null);
}
