const std = @import("std");
const types = @import("types.zig");

pub fn ILockManager(T: type) type {
    return struct {
        private: struct {
            self: *T,
            getSlot: *const fn (self: *T, hash: types.HashValue) types.LockSlot,
            lock: *const fn (self: *T, slot: types.LockSlot) void,
            isLocked: *const fn (self: *T, slot: types.LockSlot) bool,
            tryLock: *const fn (self: *T, slot: types.LockSlot) bool,
            unlock: *const fn (self: *T, slot: types.LockSlot) void,
        },

        const Self = @This();

        pub fn getSlot(self: Self, hash: types.HashValue) types.LockSlot {
            const obj = self.private.self;
            return self.private.getSlot(obj, hash);
        }

        pub fn lock(self: Self, slot: types.LockSlot) void {
            const obj = self.private.self;
            self.private.lock(obj, slot);
        }

        pub fn isLocked(self: Self, slot: types.LockSlot) bool {
            const obj = self.private.self;
            return self.private.isLocked(obj, slot);
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
            .isLocked = T.isLocked,
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
    gpa: std.mem.Allocator,
    actions: std.ArrayList(LockAction),
    lockedSet: LockedSetType,

    const Self = @This();
    const LockedSetType = std.AutoHashMap(types.LockSlot, struct {});

    pub fn init(gpa: std.mem.Allocator) FakeLockManager {
        const lockedSet = LockedSetType.init(gpa);
        return FakeLockManager{
            .gpa = gpa,
            .actions = std.ArrayList(LockAction).empty,
            .lockedSet = lockedSet,
        };
    }

    pub fn deinit(self: *Self) void {
        self.actions.deinit(self.gpa);
        self.lockedSet.deinit();
    }

    pub fn getSlot(_: *Self, hash: types.HashValue) types.LockSlot {
        return types.LockSlot{ .lock_slot = hash.hash };
    }

    pub fn lock(self: *Self, slot: types.LockSlot) void {
        self.lockedSet.put(slot, .{}) catch unreachable;
        self.actions.append(self.gpa, LockAction{
            .action = .lock,
            .hash = slot.lock_slot,
        }) catch unreachable;
    }

    pub fn isLocked(self: *Self, slot: types.LockSlot) bool {
        return self.lockedSet.contains(slot);
    }

    pub fn tryLock(self: *Self, slot: types.LockSlot) bool {
        if (self.lockedSet.contains(slot))  {
            return false;
        }
        self.lockedSet.put(slot, .{}) catch unreachable;
        self.actions.append(self.gpa, LockAction{
            .action = .tryLock,
            .hash = slot.lock_slot,
        }) catch unreachable;
        return true;
    }

    pub fn unlock(self: *Self, slot: types.LockSlot) void {
        _ = self.lockedSet.remove(slot);
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
    try expectEqual(types.NewLockSlot(81), m.getSlot(types.NewHash(81)));

    m.lock(types.NewLockSlot(11));
    m.lock(types.NewLockSlot(12));

    // try lock
    try expectEqual(true, m.tryLock(types.NewLockSlot(13)));
    try expectEqual(false, m.tryLock(types.NewLockSlot(13))); // again

    // unlock
    m.unlock(types.NewLockSlot(11));

    // check is locked
    try expectEqual(false, m.isLocked(types.NewLockSlot(11)));
    try expectEqual(true, m.isLocked(types.NewLockSlot(12)));
    try expectEqual(true, m.isLocked(types.NewLockSlot(13)));

    // check actions
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
