const std = @import("std");
const types = @import("types.zig");

const HashValue = types.HashValue;
const LockSlot = types.LockSlot;

pub fn ILockManager(T: type) type {
    return struct {
        private: struct {
            self: *T,
            getSlot: *const fn (self: *T, hash: HashValue) LockSlot,
            lock: *const fn (self: *T, slot: LockSlot) void,
            isLocked: *const fn (self: *T, slot: LockSlot) bool,
            tryLock: *const fn (self: *T, slot: LockSlot) bool,
            unlock: *const fn (self: *T, slot: LockSlot) void,
        },

        const Self = @This();

        pub fn init(obj: *T) Self {
            return Self{
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

        pub fn getSlot(self: Self, hash: HashValue) LockSlot {
            const obj = self.private.self;
            return self.private.getSlot(obj, hash);
        }

        pub fn lock(self: Self, slot: LockSlot) void {
            const obj = self.private.self;
            self.private.lock(obj, slot);
        }

        pub fn isLocked(self: Self, slot: LockSlot) bool {
            const obj = self.private.self;
            return self.private.isLocked(obj, slot);
        }

        pub fn tryLock(self: Self, slot: LockSlot) bool {
            const obj = self.private.self;
            return self.private.tryLock(obj, slot);
        }

        pub fn unlock(self: Self, slot: LockSlot) void {
            const obj = self.private.self;
            self.private.unlock(obj, slot);
        }
    };
}

// ===========================================================================
// Fake Lock Manager
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
    const LockedSetType = std.AutoHashMap(LockSlot, struct {});

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

    pub fn getSlot(_: *Self, hash: HashValue) LockSlot {
        return LockSlot{ .lock_slot = hash.hash };
    }

    pub fn lock(self: *Self, slot: LockSlot) void {
        std.debug.assert(!self.lockedSet.contains(slot));
        self.lockedSet.put(slot, .{}) catch unreachable;
        self.actions.append(self.gpa, LockAction{
            .action = .lock,
            .hash = slot.lock_slot,
        }) catch unreachable;
    }

    pub fn isLocked(self: *Self, slot: LockSlot) bool {
        return self.lockedSet.contains(slot);
    }

    pub fn tryLock(self: *Self, slot: LockSlot) bool {
        if (self.lockedSet.contains(slot)) {
            return false;
        }
        self.lockedSet.put(slot, .{}) catch unreachable;
        self.actions.append(self.gpa, LockAction{
            .action = .tryLock,
            .hash = slot.lock_slot,
        }) catch unreachable;
        return true;
    }

    pub fn unlock(self: *Self, slot: LockSlot) void {
        const ok = self.lockedSet.remove(slot);
        std.debug.assert(ok);
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

    const m = ILockManager(FakeLockManager).init(&obj);
    try expectEqual(LockSlot.init(81), m.getSlot(HashValue.init(81)));

    m.lock(LockSlot.init(11));
    m.lock(LockSlot.init(12));

    // try lock
    try expectEqual(true, m.tryLock(LockSlot.init(13)));
    try expectEqual(false, m.tryLock(LockSlot.init(13))); // again

    // unlock
    m.unlock(LockSlot.init(11));

    // check is locked
    try expectEqual(false, m.isLocked(LockSlot.init(11)));
    try expectEqual(true, m.isLocked(LockSlot.init(12)));
    try expectEqual(true, m.isLocked(LockSlot.init(13)));

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
