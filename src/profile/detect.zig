const std = @import("std");
const entry = @import("../entry.zig");
const schema = @import("schema.zig");
const engine = @import("engine.zig");
const load = @import("load.zig");

pub fn scoreProfile(profile: *const schema.Profile, lines: []const []const u8) usize {
    var score: usize = 0;
    for (lines) |line| {
        if (line.len == 0) continue;
        if (engine.parseLine(profile, line)) |_| {
            score += 1;
        } else |_| {}
    }
    return score;
}

pub fn detect(lines: []const []const u8, set: *const load.ProfileSet) *const schema.Profile {
    var best: ?*const schema.Profile = null;
    var best_score: usize = 0;
    var best_specificity: usize = 0;

    for (set.profiles) |*profile| {
        const s = scoreProfile(profile, lines);
        if (s > best_score or (s == best_score and s > 0 and profile.specificity > best_specificity) or
            (s == best_score and s > 0 and profile.specificity == best_specificity and best != null and
                std.mem.order(u8, profile.id, best.?.id) == .lt))
        {
            best = profile;
            best_score = s;
            best_specificity = profile.specificity;
        }
    }

    if (best_score == 0) {
        return set.findById("iso-structured") orelse &set.profiles[0];
    }

    return best.?;
}

test "detect level-colon sample" {
    const lines = [_][]const u8{
        "2026-05-03 18:29:23,784 INFO: startup [in /app/__init__.py:62]",
        "2026-05-03 18:59:03,083 WARNING: Page not found [in /app/__init__.py:243]",
    };
    var set = try load.loadEmbeddedSet(std.testing.allocator);
    defer set.deinit();
    const picked = detect(&lines, &set);
    try std.testing.expectEqualStrings("level-colon-suffix", picked.id);
}

test "detect apache sample" {
    const lines = [_][]const u8{
        "8.134.9.15 - - [17/May/2026:00:56:41 +0000] \"GET /dump.sql HTTP/1.1\" 400 248 \"-\" \"Go-http-client/1.1\" \"-\"",
    };
    var set = try load.loadEmbeddedSet(std.testing.allocator);
    defer set.deinit();
    const picked = detect(&lines, &set);
    try std.testing.expectEqualStrings("bracket-timestamp-quoted-request", picked.id);
}
