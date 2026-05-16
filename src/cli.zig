const std = @import("std");

const log_analyzer = @import("log_analyzer");

pub const OutputFormat = enum {
    text,
    table,
    json,
};

pub const Input = union(enum) {
    file: []const u8,
    stdin,
};

pub const CliOptions = struct {
    input: Input,
    module: ?[]const u8 = null,
    level: ?log_analyzer.Level = null,
    time_bounds: log_analyzer.TimeBounds = .{},
    format: OutputFormat = .text,
};

pub const ParseError = error{
    HelpRequested,
    InvalidArgument,
};

const level_prefix = "--level=";
const since_prefix = "--since=";
const until_prefix = "--until=";
const format_prefix = "--format=";

fn matchesAny(s: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn takeArg(args: []const []const u8, i: usize) ParseError!usize {
    const next = i + 1;
    if (next >= args.len) return error.InvalidArgument;
    return next;
}

fn parseLevelValue(s: []const u8) ParseError!log_analyzer.Level {
    return log_analyzer.Level.parse(s) catch return error.InvalidArgument;
}

fn parseTimestampValue(s: []const u8) ParseError![]const u8 {
    return log_analyzer.parseTimestamp(s) catch return error.InvalidArgument;
}

fn parseFormatValue(s: []const u8) ParseError!OutputFormat {
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "table")) return .table;
    if (std.mem.eql(u8, s, "json")) return .json;
    return error.InvalidArgument;
}

pub fn parseArgs(args: []const []const u8) ParseError!CliOptions {
    var path: ?[]const u8 = null;
    var level: ?log_analyzer.Level = null;
    var module: ?[]const u8 = null;
    var time_bounds: log_analyzer.TimeBounds = .{};
    var format: OutputFormat = .text;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (matchesAny(arg, &.{ "-h", "--help" })) {
            return error.HelpRequested;
        }

        if (std.mem.startsWith(u8, arg, level_prefix)) {
            if (arg.len <= level_prefix.len) return error.InvalidArgument;
            level = try parseLevelValue(arg[level_prefix.len..]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, since_prefix)) {
            if (arg.len <= since_prefix.len) return error.InvalidArgument;
            time_bounds.since = try parseTimestampValue(arg[since_prefix.len..]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, until_prefix)) {
            if (arg.len <= until_prefix.len) return error.InvalidArgument;
            time_bounds.until = try parseTimestampValue(arg[until_prefix.len..]);
            continue;
        }

        if (std.mem.startsWith(u8, arg, format_prefix)) {
            if (arg.len <= format_prefix.len) return error.InvalidArgument;
            format = try parseFormatValue(arg[format_prefix.len..]);
            continue;
        }

        if (matchesAny(arg, &.{ "-l", "--level" })) {
            i = try takeArg(args, i);
            level = try parseLevelValue(args[i]);
            continue;
        } else if (matchesAny(arg, &.{ "-m", "--module" })) {
            i = try takeArg(args, i);
            module = args[i];
            continue;
        } else if (matchesAny(arg, &.{ "--since" })) {
            i = try takeArg(args, i);
            time_bounds.since = try parseTimestampValue(args[i]);
            continue;
        } else if (matchesAny(arg, &.{ "--until" })) {
            i = try takeArg(args, i);
            time_bounds.until = try parseTimestampValue(args[i]);
            continue;
        } else if (matchesAny(arg, &.{ "--format" })) {
            i = try takeArg(args, i);
            format = try parseFormatValue(args[i]);
            continue;
        }

        if (arg.len > 0 and arg[0] == '-') {
            return error.InvalidArgument;
        }

        if (path != null) return error.InvalidArgument;
        path = arg;
    }

    return .{
        .input = if (path) |p| .{ .file = p } else .stdin,
        .module = module,
        .level = level,
        .time_bounds = time_bounds,
        .format = format,
    };
}

test "parseArgs positional only" {
    const args = [_][]const u8{ "log_analyzer", "a.log" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("a.log", opts.input.file);
    try std.testing.expect(opts.level == null);
    try std.testing.expectEqual(OutputFormat.text, opts.format);
}

test "parseArgs flags only reads stdin" {
    const args = [_][]const u8{ "log_analyzer", "--format", "json" };
    const opts = try parseArgs(&args);
    try std.testing.expect(opts.input == .stdin);
}

test "parseArgs --level two-token form" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--level", "warn" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("a.log", opts.input.file);
    try std.testing.expectEqual(log_analyzer.Level.warn, opts.level.?);
}

test "parseArgs --level= form" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--level=debug" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("a.log", opts.input.file);
    try std.testing.expectEqual(log_analyzer.Level.debug, opts.level.?);
}

test "parseArgs unknown flag" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--bogus" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}

test "parseArgs duplicate positional" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "b.log" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}

test "parseArgs help" {
    const args = [_][]const u8{ "log_analyzer", "--help" };
    try std.testing.expectError(error.HelpRequested, parseArgs(&args));
}

test "parseArgs --level without value" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--level" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}

test "parseArgs --level= empty value" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--level=" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}

test "parseArgs --module" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--module", "auth" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("a.log", opts.input.file);
    try std.testing.expectEqualStrings("auth", opts.module.?);
    try std.testing.expect(opts.level == null);
}

test "parseArgs -m short form" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "-m", "db" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("db", opts.module.?);
}

test "parseArgs --module without value" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--module" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}

test "parseArgs --since two-token form" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--since", "2026-05-15T20:00:02Z" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("2026-05-15T20:00:02Z", opts.time_bounds.since.?);
    try std.testing.expect(opts.time_bounds.until == null);
}

test "parseArgs --until= form" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--until=2026-05-15T20:00:03Z" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("2026-05-15T20:00:03Z", opts.time_bounds.until.?);
}

test "parseArgs --since= form" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--since=2026-05-15T20:00:01Z" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("2026-05-15T20:00:01Z", opts.time_bounds.since.?);
}

test "parseArgs rejects invalid timestamp flag" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--since", "not-valid" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}

test "parseArgs --since without value" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--since" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}

test "parseArgs --format table" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--format", "table" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqual(OutputFormat.table, opts.format);
}

test "parseArgs --format json" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--format", "json" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqual(OutputFormat.json, opts.format);
}

test "parseArgs --format=json" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--format=json" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqual(OutputFormat.json, opts.format);
}

test "parseArgs --format text" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--format", "text" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqual(OutputFormat.text, opts.format);
}

test "parseArgs --format invalid" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--format", "xml" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}

test "parseArgs --format without value" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--format" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&args));
}
