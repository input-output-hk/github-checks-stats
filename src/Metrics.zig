const std = @import("std");
const utils = @import("utils");
const m = @import("metrics");

const types = @import("api.zig").types;

pull_requests: m.GaugeVec(u32, utils.meta.MergedStructs(&.{ RepoLabel, struct {
    state: types.PullRequestState,
} })),
check_runs: m.GaugeVec(u32, utils.meta.MergedStructs(&.{ RepoLabel, struct {
    state: CheckState,
} })),
time_to_fix: m.HistogramVec(u64, RepoLabel, &.{
    5 * std.time.s_per_min,
    15 * std.time.s_per_min,
    30 * std.time.s_per_min,
    1 * std.time.s_per_hour,
    2 * std.time.s_per_hour,
    4 * std.time.s_per_hour,
    6 * std.time.s_per_hour,
    8 * std.time.s_per_hour,
    12 * std.time.s_per_hour,
    1 * std.time.s_per_day,
    2 * std.time.s_per_day,
    3 * std.time.s_per_day,
    4 * std.time.s_per_day,
    5 * std.time.s_per_day,
    6 * std.time.s_per_day,
    std.time.s_per_week,
    2 * std.time.s_per_week,
}),

const RepoLabel = struct { repo: []const u8 };

pub const CheckState = utils.enums.Merged(&.{types.CheckConclusionState, types.CheckStatusState}, true);

pub fn deinit(self: *@This()) void {
    self.pull_requests.deinit();
    self.check_runs.deinit();
    self.time_to_fix.deinit();
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, comptime opts: m.RegistryOpts) !@This() {
    return .{
        .pull_requests = try .init(allocator, io, "pull_requests", .{
            .help = "Count of pull requests",
        }, opts),
        .check_runs = try .init(allocator, io, "check_runs", .{
            .help = "Count of check runs",
        }, opts),
        .time_to_fix = try .init(allocator, io, "time_to_fix_seconds", .{
            .help = "Duration from first failing commit to first successful commit on a pull request",
        }, opts),
    };
}

pub fn write(self: *const @This(), writer: *std.Io.Writer) !void {
    try m.write(self, writer);
}
