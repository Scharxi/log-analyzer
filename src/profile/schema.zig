const std = @import("std");
const entry = @import("../entry.zig");

pub const max_fields = 8;
pub const max_aliases = 16;
pub const max_derive = 8;
pub const max_extract = 16;

pub const Transform = enum {
    none,
    basename,
    basename_strip_ext,
};

pub const ExtractType = enum {
    token,
    until,
    rest,
    quoted,
    regex_suffix,
    skip_tokens,
};

pub const ExtractStep = struct {
    field: []const u8,
    type: ExtractType,
    separator: ?[]const u8 = null,
    literal: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    group: usize = 0,
    count: usize = 0,
    transform: Transform = .none,
    strip_ext: ?[]const u8 = null,
};

pub const DeriveRange = struct {
    min: i32,
    max: i32,
    level: entry.Level,
};

pub const LevelSpec = struct {
    field: []const u8,
    aliases: []const entry.Alias,
    derive: []const DeriveRange,
};

pub const TimestampSpec = struct {
    at: []const u8,
    pattern: []const u8,
};

pub const Profile = struct {
    id: []const u8,
    description: []const u8,
    timestamp: TimestampSpec,
    extract: []const ExtractStep,
    level: LevelSpec,
    /// Higher = more specific for tie-breaking during detect.
    specificity: usize,

    pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        allocator.free(self.timestamp.at);
        allocator.free(self.timestamp.pattern);
        for (self.extract) |step| {
            allocator.free(step.field);
            if (step.separator) |s| allocator.free(s);
            if (step.literal) |s| allocator.free(s);
            if (step.pattern) |s| allocator.free(s);
            if (step.strip_ext) |s| allocator.free(s);
        }
        allocator.free(self.extract);
        allocator.free(self.level.field);
        for (self.level.aliases) |a| {
            allocator.free(a.from);
            allocator.free(a.to);
        }
        allocator.free(self.level.aliases);
        allocator.free(self.level.derive);
    }
};

// JSON deserialization shapes (parsed into owned Profile).

pub const JsonProfile = struct {
    id: []const u8,
    description: ?[]const u8 = null,
    timestamp: JsonTimestamp,
    extract: []JsonExtract,
    level: JsonLevel,
};

pub const JsonTimestamp = struct {
    at: []const u8,
    pattern: []const u8,
};

pub const JsonExtract = struct {
    field: []const u8,
    type: []const u8,
    separator: ?[]const u8 = null,
    literal: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    group: ?usize = null,
    count: ?usize = null,
    transform: ?[]const u8 = null,
    strip_ext: ?[]const u8 = null,
};

pub const JsonAlias = struct {
    from: []const u8,
    to: []const u8,
};

pub const JsonLevel = struct {
    field: []const u8,
    aliases: ?[]JsonAlias = null,
    derive: ?[]JsonDerive = null,
};

pub const JsonDerive = struct {
    min: i32,
    max: i32,
    level: []const u8,
};

pub fn parseExtractType(s: []const u8) ?ExtractType {
    if (std.mem.eql(u8, s, "token")) return .token;
    if (std.mem.eql(u8, s, "until")) return .until;
    if (std.mem.eql(u8, s, "rest")) return .rest;
    if (std.mem.eql(u8, s, "quoted")) return .quoted;
    if (std.mem.eql(u8, s, "regex_suffix")) return .regex_suffix;
    if (std.mem.eql(u8, s, "skip_tokens")) return .skip_tokens;
    return null;
}

pub fn parseTransform(s: []const u8) ?Transform {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "basename")) return .basename;
    if (std.mem.eql(u8, s, "basename_strip_ext")) return .basename_strip_ext;
    return null;
}

pub fn profileFromJson(allocator: std.mem.Allocator, jp: JsonProfile) !Profile {
    const extract_type = parseExtractType;
    const transform_type = parseTransform;

    var extract = try allocator.alloc(ExtractStep, jp.extract.len);
    errdefer allocator.free(extract);

    for (jp.extract, 0..) |je, i| {
        const et = extract_type(je.type) orelse return error.InvalidProfile;
        const tr = if (je.transform) |t| transform_type(t) orelse return error.InvalidProfile else .none;
        extract[i] = .{
            .field = try allocator.dupe(u8, je.field),
            .type = et,
            .separator = if (je.separator) |s| try allocator.dupe(u8, s) else null,
            .literal = if (je.literal) |s| try allocator.dupe(u8, s) else null,
            .pattern = if (je.pattern) |s| try allocator.dupe(u8, s) else null,
            .group = je.group orelse 0,
            .count = je.count orelse 0,
            .transform = tr,
            .strip_ext = if (je.strip_ext) |s| try allocator.dupe(u8, s) else null,
        };
    }

    var alias_count: usize = 0;
    var aliases: [max_aliases]entry.Alias = undefined;
    if (jp.level.aliases) |list| {
        for (list) |ja| {
            if (alias_count >= max_aliases) return error.InvalidProfile;
            aliases[alias_count] = .{
                .from = try allocator.dupe(u8, ja.from),
                .to = try allocator.dupe(u8, ja.to),
            };
            alias_count += 1;
        }
    }
    const aliases_owned = try allocator.dupe(entry.Alias, aliases[0..alias_count]);

    var derive_count: usize = 0;
    var derive_buf: [max_derive]DeriveRange = undefined;
    if (jp.level.derive) |list| {
        for (list) |jd| {
            if (derive_count >= max_derive) return error.InvalidProfile;
            const lvl = std.meta.stringToEnum(entry.Level, jd.level) orelse return error.InvalidProfile;
            derive_buf[derive_count] = .{ .min = jd.min, .max = jd.max, .level = lvl };
            derive_count += 1;
        }
    }
    const derive_owned = try allocator.dupe(DeriveRange, derive_buf[0..derive_count]);

    const specificity = jp.timestamp.pattern.len + extract.len * 4;

    return .{
        .id = try allocator.dupe(u8, jp.id),
        .description = try allocator.dupe(u8, jp.description orelse ""),
        .timestamp = .{
            .at = try allocator.dupe(u8, jp.timestamp.at),
            .pattern = try allocator.dupe(u8, jp.timestamp.pattern),
        },
        .extract = extract,
        .level = .{
            .field = try allocator.dupe(u8, jp.level.field),
            .aliases = aliases_owned,
            .derive = derive_owned,
        },
        .specificity = specificity,
    };
}
