const std = @import("std");
const entry = @import("../entry.zig");

pub const schema = @import("schema.zig");
pub const engine = @import("engine.zig");
pub const load = @import("load.zig");
pub const detect = @import("detect.zig");

pub const Profile = schema.Profile;
pub const ProfileSet = load.ProfileSet;

pub fn parseLine(profile: *const Profile, line: []const u8) entry.ParseError!entry.LogEntry {
    return engine.parseLine(profile, line);
}

pub fn loadProfileFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) entry.ParseError!Profile {
    return load.loadProfileFile(allocator, io, path);
}

pub fn loadPreset(allocator: std.mem.Allocator, id: []const u8) entry.ParseError!Profile {
    return load.loadPreset(allocator, id);
}

pub fn defaultProfile(allocator: std.mem.Allocator) entry.ParseError!Profile {
    return load.defaultProfile(allocator);
}

pub fn allProfiles(allocator: std.mem.Allocator, io: std.Io, format_dir: ?[]const u8) !ProfileSet {
    return load.allProfiles(allocator, io, format_dir);
}

pub fn detectProfile(lines: []const []const u8, set: *const ProfileSet) *const Profile {
    return detect.detect(lines, set);
}

pub fn presetIds() []const []const u8 {
    return load.presetIds();
}
