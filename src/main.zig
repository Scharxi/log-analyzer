const std = @import("std");

const cli = @import("cli.zig");
const log_analyzer = @import("log_analyzer");

const usage =
    \\Usage: log_analyzer [options] <log-file>
    \\
    \\Analyze a log file and print statistics.
    \\
    \\Options:
    \\  -l, --level <LEVEL>     Minimum level (debug, info, warn, error)
    \\  --level=<LEVEL>         Same as --level
    \\  -m, --module <NAME>     Only include lines from this module
    \\  --since <TIMESTAMP>     Include lines at or after ISO 8601 time (UTC)
    \\  --since=<TIMESTAMP>     Same as --since
    \\  --until <TIMESTAMP>     Include lines at or before ISO 8601 time (UTC)
    \\  --until=<TIMESTAMP>     Same as --until
    \\  --format <text|json>    Output format (default: text)
    \\  --format=<text|json>    Same as --format
    \\  -h, --help              Show this help
    \\
;

fn printUsage() void {
    std.debug.print("{s}", .{usage});
}

fn envFlagSet(map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = map.get(key) orelse return false;
    return value.len > 0;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const opts = cli.parseArgs(args) catch |err| switch (err) {
        error.HelpRequested => {
            printUsage();
            return;
        },
        error.InvalidArgument => {
            printUsage();
            return err;
        },
    };

    var stats = log_analyzer.Stats.init(init.gpa);
    defer stats.deinit();

    const scan = try log_analyzer.processLogFile(
        opts.path,
        init.io,
        &stats,
        opts.level,
        opts.module,
        opts.time_bounds,
    );

    switch (opts.format) {
        .text => {
            const stdout_file = std.Io.File.stdout();
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);

            const terminal_mode = try std.Io.Terminal.Mode.detect(
                init.io,
                stdout_file,
                envFlagSet(init.environ_map, "NO_COLOR"),
                envFlagSet(init.environ_map, "CLICOLOR_FORCE"),
            );
            const terminal = std.Io.Terminal{
                .writer = &w,
                .mode = terminal_mode,
            };

            try stats.format(&w, terminal);
            try w.writeAll("\n");
            try stdout_file.writeStreamingAll(init.io, buf[0..w.end]);

            if (scan.skipped > 0) {
                std.log.warn("skipped {d} malformed line(s)", .{scan.skipped});
            }
        },
        .json => {
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try stats.formatJson(scan.parsed, scan.skipped, &w);
            try std.Io.File.stdout().writeStreamingAll(init.io, w.buffer[0..w.end]);
        },
    }
}
