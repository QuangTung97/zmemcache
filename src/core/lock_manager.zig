const std = @import("std");
const types = @import("types.zig");

pub fn ILockManager(T: type) type {
    return struct {
        self: *T,
        lock: *const fn (self: *T, hash: types.HashValue) void,
        tryLock: *const fn (self: *T, hash: types.HashValue) bool,
        unlock: *const fn (self: *T, hash: types.HashValue) void,
    };
}

pub fn NewILockManager(T: type, obj: *T) ILockManager(T) {
    return ILockManager(T){
        .self = obj,
        .lock = T.lock,
        .tryLock = T.tryLock,
        .unlock = T.unlock,
    };
}

const LockAction = struct {
    hash: types.HashValue,
};

pub const FakeLockManager = struct {
    actions: std.ArrayList(LockAction),
    gpa: std.mem.Allocator,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator) FakeLockManager {
        return FakeLockManager{
            .actions = std.ArrayList(LockAction).empty,
            .gpa = gpa,
        };
    }

    pub fn lock(_: *Self, _: types.HashValue) void {}

    pub fn tryLock(_: *Self, _: types.HashValue) bool {
        return true;
    }

    pub fn unlock(_: *Self, _: types.HashValue) void {}
};

const expectEqual = std.testing.expectEqual;

test "fake lock manager" {
    var obj = FakeLockManager.init(std.testing.allocator);
    const m = NewILockManager(FakeLockManager, &obj);

    m.lock(m.self, .{ .hash = 11 });
    m.lock(m.self, .{ .hash = 12 });

    const ok = m.tryLock(m.self, .{ .hash = 12 });
    try expectEqual(true, ok);

    m.unlock(m.self, .{ .hash = 11 });

    const expectedActions = [_]LockAction{};
    try expectEqual(expectedActions[0..], m.self.actions.items);
}
