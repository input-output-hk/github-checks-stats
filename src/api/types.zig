pub const ID = []const u8;

pub const PullRequest = struct {
    id: ID,

    number: usize,
    title: []const u8,
};

pub const Commit = struct {
    id: ID,

    oid: []const u8,
    messageHeadline: []const u8,
};

pub const App = struct {
    name: []const u8,
};

pub const Ref = struct {
    prefix: []const u8,
    name: []const u8,
};

pub const User = struct {
    name: ?[]const u8 = null,
    login: []const u8,
    company: ?[]const u8 = null,
};

pub const CheckConclusionState = enum {
    ACTION_REQUIRED,
    TIMED_OUT,
    CANCELLED,
    FAILURE,
    SUCCESS,
    NEUTRAL,
    SKIPPED,
    STARTUP_FAILURE,
    STALE,
};

pub const CheckStatusState = enum {
    REQUESTED,
    QUEUED,
    IN_PROGRESS,
    COMPLETED,
    WAITING,
    PENDING,
};

pub const CheckSuite = struct {
    id: ID,

    app: App,
    branch: ?Ref = null,
    creator: User,
    conclusion: ?CheckConclusionState = null,
    status: CheckStatusState,
    createdAt: []const u8,
    updatedAt: []const u8,
};

pub const CheckRun = struct {
    id: ID,

    name: []const u8,
    startedAt: []const u8,
    completedAt: []const u8,
};
