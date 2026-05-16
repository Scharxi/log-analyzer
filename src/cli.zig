const std = @import("std");

const log_analyzer = @import("log_analyzer");

pub const CliOptions = struct {
    path: []const u8,
    module: ?[]const u8 = null,
    level: ?log_analyzer.Level = null,
};

pub const ParseError = error{
    HelpRequested,
    InvalidArgument,
};

const level_prefix = "--level=";

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

pub fn parseArgs(args: []const []const u8) ParseError!CliOptions {
    var path: ?[]const u8 = null;
    var level: ?log_analyzer.Level = null;
    var module: ?[]const u8 = null;

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

        if (matchesAny(arg, &.{ "-l", "--level" })) {
            i = try takeArg(args, i);
            level = try parseLevelValue(args[i]);
            continue;
        } else if (matchesAny(arg, &.{ "-m", "--module" })) {
            i = try takeArg(args, i);
            module = args[i];
            continue;
        }

        if (arg.len > 0 and arg[0] == '-') {
            return error.InvalidArgument;
        }

        if (path != null) return error.InvalidArgument;
        path = arg;
    }

    return .{
        .path = path orelse return error.InvalidArgument,
        .module = module,
        .level = level,
    };
}

test "parseArgs positional only" {
    const args = [_][]const u8{ "log_analyzer", "a.log" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("a.log", opts.path);
    try std.testing.expect(opts.level == null);
}

test "parseArgs --level two-token form" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--level", "warn" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("a.log", opts.path);
    try std.testing.expectEqual(log_analyzer.Level.warn, opts.level.?);
}

test "parseArgs --level= form" {
    const args = [_][]const u8{ "log_analyzer", "a.log", "--level=debug" };
    const opts = try parseArgs(&args);
    try std.testing.expectEqualStrings("a.log", opts.path);
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
    try std.testing.expectEqualStrings("a.log", opts.path);
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
