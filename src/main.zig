const std = @import("std");

const log_analyzer = @import("log_analyzer");

const usage =
    \\Usage: log_analyzer <log-file>
    \\
    \\Analyze a log file and print statistics.
    \\
;

fn printUsage() void {
    std.debug.print("{s}", .{usage});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
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

    const scan = try log_analyzer.processLogFile(log_path, init.io, &stats);

    std.debug.print("{f}\n", .{&stats});
    if (scan.skipped > 0) {
        std.log.warn("skipped {d} malformed line(s)", .{scan.skipped});
    }
}
