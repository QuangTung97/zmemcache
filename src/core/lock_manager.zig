const std = @import("std");
const types = @import("types.zig");

pub fn ILockManager(T: type) type {
    return struct {
        private: struct {
            self: *T,
            getSlot: *const fn (self: *T, hash: types.HashValue) types.LockSlot,
            lock: *const fn (self: *T, slot: types.LockSlot) void,
            tryLock: *const fn (self: *T, slot: types.LockSlot) bool,
            unlock: *const fn (self: *T, slot: types.LockSlot) void,
        },

        const Self = @This();

        pub fn getSlot(self: Self, hash: types.HashValue) types.LockSlot {
            const obj = self.private.self;
            return obj.private.getSlot(obj, hash);
        }

        pub fn lock(self: Self, slot: types.LockSlot) void {
            const obj = self.private.self;
            self.private.lock(obj, slot);
        }

        pub fn tryLock(self: Self, slot: types.LockSlot) bool {
            const obj = self.private.self;
            return self.private.tryLock(obj, slot);
        }

        pub fn unlock(self: Self, slot: types.LockSlot) void {
            const obj = self.private.self;
            self.private.unlock(obj, slot);
        }
    };
}

pub fn NewILockManager(T: type, obj: *T) ILockManager(T) {
    return ILockManager(T){
        .private = .{
            .self = obj,
            .getSlot = T.getSlot,
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

    pub fn getSlot(_: *Self, hash: types.HashValue) types.LockSlot {
        return types.LockSlot{ .lock_slot = hash.hash };
    }

    pub fn lock(self: *Self, slot: types.LockSlot) void {
        self.actions.append(self.gpa, LockAction{
            .action = .lock,
            .hash = slot.lock_slot,
        }) catch unreachable;
    }

    pub fn tryLock(self: *Self, slot: types.LockSlot) bool {
        self.actions.append(self.gpa, LockAction{
            .action = .tryLock,
            .hash = slot.lock_slot,
        }) catch unreachable;
        return true;
    }

    pub fn unlock(self: *Self, slot: types.LockSlot) void {
        self.actions.append(self.gpa, LockAction{
            .action = .unlock,
            .hash = slot.lock_slot,
        }) catch unreachable;
    }
};

// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "fake lock manager" {
    var obj = FakeLockManager.init(std.testing.allocator);
    defer obj.deinit();

    const m = NewILockManager(FakeLockManager, &obj);

    m.lock(.{ .lock_slot = 11 });
    m.lock(.{ .lock_slot = 12 });

    const ok = m.tryLock(.{ .lock_slot = 13 });
    try expectEqual(true, ok);

    m.unlock(.{ .lock_slot = 11 });

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
