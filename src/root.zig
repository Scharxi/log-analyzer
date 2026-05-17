const entry = @import("entry.zig");
const timestamp = @import("timestamp.zig");
const stats = @import("stats.zig");
const analyze = @import("analyze.zig");
const parser = @import("parser.zig");
const profile = @import("profile/mod.zig");

pub const ParseError = entry.ParseError;
pub const Level = entry.Level;
pub const LogEntry = entry.LogEntry;
pub const TimeBounds = entry.TimeBounds;
pub const Profile = profile.Profile;
pub const ProfileSet = profile.ProfileSet;
pub const PeekBuffer = analyze.PeekBuffer;

pub const parseTimestamp = timestamp.parseCanonical;
pub const compareTimestamp = timestamp.compareTimestamp;
pub const timestampInRange = timestamp.timestampInRange;
pub const messageMatches = entry.messageMatches;
pub const Stats = stats.Stats;
pub const ScanResult = analyze.ScanResult;

pub const parseLine = parser.parseLine;
pub const parseLineWithProfile = parser.parseLineWithProfile;
pub const loadProfileFile = profile.loadProfileFile;
pub const loadPreset = profile.loadPreset;
pub const defaultProfile = profile.defaultProfile;
pub const allProfiles = profile.allProfiles;
pub const detectProfile = profile.detectProfile;
pub const presetIds = profile.presetIds;

pub const processLogFile = analyze.processLogFile;
pub const processLogStdin = analyze.processLogStdin;
pub const processLogReader = analyze.processLogReader;
pub const peekLogFile = analyze.peekLogFile;
pub const peekLogStdin = analyze.peekLogStdin;
