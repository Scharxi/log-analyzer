const std = @import("std");
const entry = @import("../entry.zig");
const schema = @import("schema.zig");

pub const embedded_presets = [_]struct { id: []const u8, data: []const u8 }{
    .{ .id = "iso-structured", .data = @embedFile("../formats/iso-structured.json") },
    .{ .id = "level-colon-suffix", .data = @embedFile("../formats/level-colon-suffix.json") },
    .{ .id = "bracket-timestamp-quoted-request", .data = @embedFile("../formats/bracket-timestamp-quoted-request.json") },
};

pub const ProfileSet = struct {
    profiles: []schema.Profile,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProfileSet) void {
        for (self.profiles) |*p| p.deinit(self.allocator);
        self.allocator.free(self.profiles);
    }

    pub fn findById(self: *const ProfileSet, id: []const u8) ?*const schema.Profile {
        for (self.profiles) |*p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }
};

pub fn parseJsonProfile(allocator: std.mem.Allocator, json_bytes: []const u8) entry.ParseError!schema.Profile {
    var parsed = std.json.parseFromSlice(schema.JsonProfile, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidProfile;
    defer parsed.deinit();
    return schema.profileFromJson(allocator, parsed.value) catch return error.InvalidProfile;
}

pub fn loadProfileBytes(allocator: std.mem.Allocator, json_bytes: []const u8) entry.ParseError!schema.Profile {
    return parseJsonProfile(allocator, json_bytes);
}

pub fn loadProfileFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) entry.ParseError!schema.Profile {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return error.InvalidProfile;
    defer allocator.free(data);
    return parseJsonProfile(allocator, data);
}

pub fn loadPreset(allocator: std.mem.Allocator, id: []const u8) entry.ParseError!schema.Profile {
    for (embedded_presets) |preset| {
        if (std.mem.eql(u8, preset.id, id)) {
            return parseJsonProfile(allocator, preset.data);
        }
    }
    return error.InvalidProfile;
}

pub fn defaultProfile(allocator: std.mem.Allocator) entry.ParseError!schema.Profile {
    return loadPreset(allocator, "iso-structured");
}

pub fn loadEmbeddedSet(allocator: std.mem.Allocator) !ProfileSet {
    var list = try allocator.alloc(schema.Profile, embedded_presets.len);
    errdefer allocator.free(list);

    for (embedded_presets, 0..) |preset, i| {
        list[i] = try parseJsonProfile(allocator, preset.data);
    }

    return .{ .profiles = list, .allocator = allocator };
}

pub fn loadDirProfiles(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) ![]schema.Profile {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.InvalidProfile;
    defer dir.close(io);

    var list: std.ArrayList(schema.Profile) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit(allocator);
        list.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry_fs| {
        if (entry_fs.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry_fs.name, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry_fs.name });
        defer allocator.free(path);
        const profile = loadProfileFile(allocator, io, path) catch continue;
        try list.append(allocator, profile);
    }

    return list.toOwnedSlice(allocator);
}

pub fn mergeProfileSets(
    allocator: std.mem.Allocator,
    base: ProfileSet,
    extra: []schema.Profile,
) !ProfileSet {
    var combined = try allocator.alloc(schema.Profile, base.profiles.len + extra.len);
    @memcpy(combined[0..base.profiles.len], base.profiles);
    @memcpy(combined[base.profiles.len..], extra);

    allocator.free(base.profiles);

    return .{ .profiles = combined, .allocator = allocator };
}

pub fn allProfiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    format_dir: ?[]const u8,
) !ProfileSet {
    var set = try loadEmbeddedSet(allocator);
    if (format_dir) |dir| {
        const extra = try loadDirProfiles(allocator, io, dir);
        errdefer {
            for (extra) |*p| p.deinit(allocator);
            allocator.free(extra);
        }
        set = try mergeProfileSets(allocator, set, extra);
    }
    return set;
}

pub fn presetIds() []const []const u8 {
    const ids = comptime blk: {
        var buf: [embedded_presets.len][]const u8 = undefined;
        for (embedded_presets, 0..) |p, i| buf[i] = p.id;
        break :blk buf;
    };
    return &ids;
}
