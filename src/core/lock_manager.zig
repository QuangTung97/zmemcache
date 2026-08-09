const std = @import("std");
const types = @import("types.zig");

pub fn ILockManager(T: type) type {
    return struct {
        private: struct {
            self: *T,
            lock: *const fn (self: *T, hash: types.HashValue) void,
            tryLock: *const fn (self: *T, hash: types.HashValue) bool,
            unlock: *const fn (self: *T, hash: types.HashValue) void,
        },

        const Self = @This();

        pub fn lock(self: Self, hash: types.HashValue) void {
            const obj = self.private.self;
            self.private.lock(obj, hash);
        }

        pub fn tryLock(self: Self, hash: types.HashValue) bool {
            const obj = self.private.self;
            return self.private.tryLock(obj, hash);
        }

        pub fn unlock(self: Self, hash: types.HashValue) void {
            const obj = self.private.self;
            self.private.unlock(obj, hash);
        }
    };
}

pub fn NewILockManager(T: type, obj: *T) ILockManager(T) {
    return ILockManager(T){
        .private = .{
            .self = obj,
            .lock = T.lock,
            .tryLock = T.tryLock,
            .unlock = T.unlock,
        },
    };
}

// ===========================================================================

const LockActionType = enum {
    lock,
    unlock,
    tryLock,
};

const LockAction = struct {
    action: LockActionType,
    hash: u64,
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

    pub fn deinit(self: *Self) void {
        self.actions.deinit(self.gpa);
    }

    pub fn lock(self: *Self, hash: types.HashValue) void {
        self.actions.append(self.gpa, LockAction{
            .action = .lock,
            .hash = hash.hash,
        }) catch unreachable;
    }

    pub fn tryLock(self: *Self, hash: types.HashValue) bool {
        self.actions.append(self.gpa, LockAction{
            .action = .tryLock,
            .hash = hash.hash,
        }) catch unreachable;
        return true;
    }

    pub fn unlock(self: *Self, hash: types.HashValue) void {
        self.actions.append(self.gpa, LockAction{
            .action = .unlock,
            .hash = hash.hash,
        }) catch unreachable;
    }
};

// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "fake lock manager" {
    var obj = FakeLockManager.init(std.testing.allocator);
    defer obj.deinit();

    const m = NewILockManager(FakeLockManager, &obj);

    m.lock(.{ .hash = 11 });
    m.lock(.{ .hash = 12 });

    const ok = m.tryLock(.{ .hash = 13 });
    try expectEqual(true, ok);

    m.unlock(.{ .hash = 11 });

    const expectedActions = [_]LockAction{
        LockAction{ .action = .lock, .hash = 11 },
        LockAction{ .action = .lock, .hash = 12 },
        LockAction{ .action = .tryLock, .hash = 13 },
        LockAction{ .action = .unlock, .hash = 11 },
    };
    try std.testing.expectEqualSlices(
        LockAction,
        expectedActions[0..],
        m.private.self.actions.items,
    );
}
