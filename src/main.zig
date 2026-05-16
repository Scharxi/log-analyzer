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
    \\  -h, --help              Show this help
    \\
;

fn printUsage() void {
    std.debug.print("{s}", .{usage});
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

    const scan = try log_analyzer.processLogFile(opts.path, init.io, &stats, opts.level, opts.module);

    std.debug.print("{f}\n", .{&stats});
    if (scan.skipped > 0) {
        std.log.warn("skipped {d} malformed line(s)", .{scan.skipped});
    }
}
