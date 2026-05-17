const std = @import("std");

const cli = @import("cli.zig");
const log_analyzer = @import("log_analyzer");

const usage =
    \\Usage: log_analyzer [options] [log-file]
    \\
    \\Analyze a log file and print statistics.
    \\Reads from stdin when log-file is omitted:
    \\  cat app.log | log_analyzer
    \\
    \\Options:
    \\  -l, --level <LEVEL>       Minimum level (debug, info, warn, error)
    \\  --level=<LEVEL>           Same as --level
    \\  -m, --module <NAME>       Only include lines from this module
    \\  --grep <PATTERN>          Only include lines whose message contains PATTERN
    \\  --grep=<PATTERN>          Same as --grep
    \\  --since <TIMESTAMP>       Include lines at or after ISO 8601 time (UTC)
    \\  --since=<TIMESTAMP>       Same as --since
    \\  --until <TIMESTAMP>       Include lines at or before ISO 8601 time (UTC)
    \\  --until=<TIMESTAMP>       Same as --until
    \\  --format <FMT>            Output format: text, table, json (default: text)
    \\  --format=<FMT>            Same as --format
    \\  --log-format <ID>         Log layout preset (see formats/)
    \\  --log-format=<ID>          Same as --log-format
    \\  --format-file <PATH>      Custom log layout profile JSON
    \\  --format-file=<PATH>      Same as --format-file
    \\  --format-dir <DIR>        Extra profile directory for auto-detect
    \\  --format-dir=<DIR>        Same as --format-dir
    \\  -h, --help                Show this help
    \\
;

fn printUsage() void {
    std.debug.print("{s}", .{usage});
}

fn envFlagSet(map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = map.get(key) orelse return false;
    return value.len > 0;
}

fn detectStdoutTerminal(init: std.process.Init, w: *std.Io.Writer) !std.Io.Terminal {
    const stdout_file = std.Io.File.stdout();
    const terminal_mode = try std.Io.Terminal.Mode.detect(
        init.io,
        stdout_file,
        envFlagSet(init.environ_map, "NO_COLOR"),
        envFlagSet(init.environ_map, "CLICOLOR_FORCE"),
    );
    return .{ .writer = w, .mode = terminal_mode };
}

fn writeStdout(init: std.process.Init, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
}

const ResolvedProfile = struct {
    profile: *const log_analyzer.Profile,
    owned: bool,
    profile_set: ?log_analyzer.ProfileSet = null,

    pub fn deinit(self: *ResolvedProfile, allocator: std.mem.Allocator) void {
        if (self.owned) {
            const p: *log_analyzer.Profile = @constCast(self.profile);
            p.deinit(allocator);
            allocator.destroy(p);
        }
        if (self.profile_set) |*set| set.deinit();
    }
};

fn resolveProfile(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    opts: cli.CliOptions,
    peek: log_analyzer.PeekBuffer,
) !ResolvedProfile {
    if (opts.format_file) |path| {
        const p = try allocator.create(log_analyzer.Profile);
        p.* = try log_analyzer.loadProfileFile(allocator, init.io, path);
        return .{ .profile = p, .owned = true };
    }

    if (opts.log_format) |id| {
        const p = try allocator.create(log_analyzer.Profile);
        p.* = try log_analyzer.loadPreset(allocator, id);
        return .{ .profile = p, .owned = true };
    }

    var set = try log_analyzer.allProfiles(allocator, init.io, opts.format_dir);
    const picked = log_analyzer.detectProfile(peek.slice(), &set);

    if (envFlagSet(init.environ_map, "LOG_ANALYZER_DEBUG")) {
        std.log.err("detected log profile: {s}", .{picked.id});
    }

    return .{
        .profile = picked,
        .owned = false,
        .profile_set = set,
    };
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

    var peek: log_analyzer.PeekBuffer = .{};
    switch (opts.input) {
        .file => |path| try log_analyzer.peekLogFile(path, init.io, &peek),
        .stdin => {
            const stdin = std.Io.File.stdin();
            if (try stdin.isTty(init.io)) {
                printUsage();
                return error.InvalidArgument;
            }
            try log_analyzer.peekLogStdin(init.io, &peek);
        },
    }

    var resolved = try resolveProfile(arena, init, opts, peek);
    defer resolved.deinit(arena);

    var stats = log_analyzer.Stats.init(init.gpa);
    defer stats.deinit();

    const prefetched = peek.slice();
    const scan = switch (opts.input) {
        .file => |path| try log_analyzer.processLogFile(
            path,
            init.io,
            &stats,
            resolved.profile,
            opts.level,
            opts.module,
            opts.grep,
            opts.time_bounds,
            prefetched,
        ),
        .stdin => try log_analyzer.processLogStdin(
            init.io,
            &stats,
            resolved.profile,
            opts.level,
            opts.module,
            opts.grep,
            opts.time_bounds,
            prefetched,
        ),
    };

    switch (opts.format) {
        .text, .table => {
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            const terminal = try detectStdoutTerminal(init, &w);

            switch (opts.format) {
                .text => try stats.format(&w, terminal),
                .table => try stats.formatTable(scan.parsed, scan.skipped, &w, terminal),
                else => unreachable,
            }
            try w.writeAll("\n");
            try writeStdout(init, buf[0..w.end]);

            if (scan.skipped > 0 and opts.format == .text) {
                std.log.warn("skipped {d} malformed line(s)", .{scan.skipped});
            }
        },
        .json => {
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try stats.formatJson(scan.parsed, scan.skipped, &w);
            try writeStdout(init, w.buffer[0..w.end]);
        },
    }
}

test {
    _ = cli;
}
