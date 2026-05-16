const std = @import("std");

const log_analyzer = @import("log_analyzer");

const usage =
    \\Usage: log_analyzer [options] <log-file>
    \\
    \\Analyze a log file and print statistics.
    \\
    \\Options:
    \\  -l, --level <LEVEL>  Minimum level (debug, info, warn, error)
    \\  -h, --help           Show this help
    \\
;

fn printUsage() void {
    std.debug.print("{s}", .{usage});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var path: ?[]const u8 = null;
    var level: ?log_analyzer.Level = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--level") or std.mem.eql(u8, arg, "-l")) {
            i += 1;
            if (i >= args.len) {
                printUsage();
                return error.InvalidArgument;
            }
            level = try log_analyzer.Level.parse(args[i]);
            continue;
        }

        if (path != null) {
            printUsage();
            return error.InvalidArgument;
        }
        path = arg;
    }

    const log_path = path orelse {
        printUsage();
        return error.InvalidArgument;
    };

    var stats = log_analyzer.Stats.init(init.gpa);
    defer stats.deinit();

    const scan = try log_analyzer.processLogFile(log_path, init.io, &stats, level);

    std.debug.print("{f}\n", .{&stats});
    if (scan.skipped > 0) {
        std.log.warn("skipped {d} malformed line(s)", .{scan.skipped});
    }
}
