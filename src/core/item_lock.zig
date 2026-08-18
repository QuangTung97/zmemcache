const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const HashValue = types.HashValue;
const LockSlot = types.LockSlot;
const CachePadding = types.CachePadding;

pub fn ItemLockFuncs(T: type) type {
    return struct {
        getTableSize: fn (self: *const T) LockSlot,
        getSlot: fn (self: *const T, hash: HashValue) LockSlot,
        lock: fn (self: *T, slot: LockSlot) void,
        isLocked: fn (self: *const T, slot: LockSlot) bool, // TODO remove
        tryLock: fn (self: *T, slot: LockSlot) bool,
        unlock: fn (self: *T, slot: LockSlot) void,
    };
}

pub fn NewItemLockFuncs(T: type) ItemLockFuncs(T) {
    return .{
        .getTableSize = T.getTableSize,
        .getSlot = T.getSlot,
        .lock = T.lock,
        .isLocked = T.isLocked,
        .tryLock = T.tryLock,
        .unlock = T.unlock,
    };
}

// ===========================================================================
// Item Lock Service
// ===========================================================================

pub const ItemLockService = struct {
    const Self = @This();

    _before_padding: CachePadding = undefined,
    _io: std.Io,
    _gpa: Allocator,
    _table: []TableEntry,
    _mask: u64,
    _after_padding: CachePadding = undefined,

    const TableEntry = struct {
        mutex: std.Io.Mutex,
        is_locked: bool,
    };

    pub fn init(io: std.Io, gpa: Allocator, table_size_log: u6) !Self {
        const table_size: u64 = @as(u64, 1) << table_size_log;

        // init table
        const table = try gpa.alloc(TableEntry, table_size);
        for (table) |*e| {
            e.* = .{
                .mutex = .init,
                .is_locked = false,
            };
        }

        return .{
            ._io = io,
            ._gpa = gpa,
            ._table = table,
            ._mask = table_size - 1,
        };
    }

    pub fn deinit(self: *Self) void {
        self._gpa.free(self._table);
    }

    pub fn getTableSize(self: *const Self) LockSlot {
        return LockSlot.init(self._table.len);
    }

    pub fn getSlot(self: *const Self, hash: HashValue) LockSlot {
        return LockSlot.init(hash.hash & self._mask);
    }

    pub fn lock(self: *Self, slot: LockSlot) void {
        const entry = &self._table[slot.lock_slot];
        entry.mutex.lockUncancelable(self._io);
        entry.is_locked = true;
    }

    pub fn tryLock(self: *Self, slot: LockSlot) bool {
        const entry = &self._table[slot.lock_slot];

        const ok = entry.mutex.tryLock();
        if (!ok) {
            return false;
        }

        entry.is_locked = true;
        return true;
    }

    pub fn unlock(self: *Self, slot: LockSlot) void {
        const entry = &self._table[slot.lock_slot];
        entry.is_locked = false;
        entry.mutex.unlock(self._io);
    }

    // TODO remove
    pub fn isLocked(self: *const Self, slot: LockSlot) bool {
        const entry = &self._table[slot.lock_slot];
        return entry.is_locked;
    }
};

// ===========================================================================
// Test Item Lock Service
// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "item lock service impl" {
    const m = NewItemLockFuncs(ItemLockService);
    _ = m;
}

test "table entry size" {
    try expectEqual(8, @sizeOf(ItemLockService.TableEntry));
}

test "item lock service" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var svc = try ItemLockService.init(io, gpa, 2);
    defer svc.deinit();

    try expectEqual(4, svc.getTableSize().lock_slot);

    // check get slot
    try expectEqual(LockSlot.init(1), svc.getSlot(HashValue.init(5)));
    try expectEqual(LockSlot.init(0), svc.getSlot(HashValue.init(4)));
    try expectEqual(LockSlot.init(3), svc.getSlot(HashValue.init(7)));

    const slot1 = LockSlot.init(1);
    const slot2 = LockSlot.init(2);

    try expectEqual(false, svc.isLocked(slot1));
    try expectEqual(false, svc.isLocked(slot2));

    // lock
    svc.lock(slot1);
    try expectEqual(true, svc.isLocked(slot1));
    try expectEqual(false, svc.isLocked(slot2));

    // unlock
    svc.unlock(slot1);
    try expectEqual(false, svc.isLocked(slot1));
    try expectEqual(false, svc.isLocked(slot2));

    // try lock
    try expectEqual(true, svc.tryLock(slot1));
    try expectEqual(true, svc.isLocked(slot1));
    try expectEqual(false, svc.isLocked(slot2));

    // try lock not ok
    try expectEqual(false, svc.tryLock(slot1));

    svc.unlock(slot1);
    try expectEqual(false, svc.isLocked(slot1));
    try expectEqual(false, svc.isLocked(slot2));
}

// ===========================================================================
// Fake Item Locks
// ===========================================================================

pub const LockActionType = enum {
    Lock,
    Unlock,
    TryLock,
};

pub const LockAction = struct {
    action: LockActionType,
    hash: u64,
};

pub const FakeItemLocks = struct {
    gpa: std.mem.Allocator,
    actions: std.ArrayList(LockAction),
    lockedSet: LockedSetType,

    const Self = @This();
    const LockedSetType = std.AutoHashMap(LockSlot, struct {});

    pub fn init(gpa: std.mem.Allocator) FakeItemLocks {
        const lockedSet = LockedSetType.init(gpa);
        return FakeItemLocks{
            .gpa = gpa,
            .actions = std.ArrayList(LockAction).empty,
            .lockedSet = lockedSet,
        };
    }

    pub fn deinit(self: *Self) void {
        self.actions.deinit(self.gpa);
        self.lockedSet.deinit();
    }

    pub fn getTableSize(_: *const Self) LockSlot {
        return LockSlot.init(16);
    }

    pub fn getSlot(_: *const Self, hash: HashValue) LockSlot {
        return LockSlot{ .lock_slot = hash.hash };
    }

    pub fn lock(self: *Self, slot: LockSlot) void {
        std.debug.assert(!self.lockedSet.contains(slot));
        self.lockedSet.put(slot, .{}) catch unreachable;
        self.actions.append(self.gpa, LockAction{
            .action = .Lock,
            .hash = slot.lock_slot,
        }) catch unreachable;
    }

    pub fn isLocked(self: *const Self, slot: LockSlot) bool {
        return self.lockedSet.contains(slot);
    }

    pub fn tryLock(self: *Self, slot: LockSlot) bool {
        if (self.lockedSet.contains(slot)) {
            return false;
        }
        self.lockedSet.put(slot, .{}) catch unreachable;
        self.actions.append(self.gpa, LockAction{
            .action = .TryLock,
            .hash = slot.lock_slot,
        }) catch unreachable;
        return true;
    }

    pub fn unlock(self: *Self, slot: LockSlot) void {
        const ok = self.lockedSet.remove(slot);
        std.debug.assert(ok);
        self.actions.append(self.gpa, LockAction{
            .action = .Unlock,
            .hash = slot.lock_slot,
        }) catch unreachable;
    }
};

// ===========================================================================
// Testing
// ===========================================================================

test "fake item locks" {
    var obj = FakeItemLocks.init(std.testing.allocator);
    defer obj.deinit();

    const m = NewItemLockFuncs(FakeItemLocks);
    try expectEqual(LockSlot.init(81), m.getSlot(&obj, HashValue.init(81)));
    try expectEqual(16, m.getTableSize(&obj).lock_slot);

    m.lock(&obj, LockSlot.init(11));
    m.lock(&obj, LockSlot.init(12));

    // try lock
    try expectEqual(true, m.tryLock(&obj, LockSlot.init(13)));
    try expectEqual(false, m.tryLock(&obj, LockSlot.init(13))); // again

    // unlock
    m.unlock(&obj, LockSlot.init(11));

    // check is locked
    try expectEqual(false, m.isLocked(&obj, LockSlot.init(11)));
    try expectEqual(true, m.isLocked(&obj, LockSlot.init(12)));
    try expectEqual(true, m.isLocked(&obj, LockSlot.init(13)));

    // check actions
    try std.testing.expectEqualSlices(
        LockAction,
        &.{
            LockAction{ .action = .Lock, .hash = 11 },
            LockAction{ .action = .Lock, .hash = 12 },
            LockAction{ .action = .TryLock, .hash = 13 },
            LockAction{ .action = .Unlock, .hash = 11 },
        },
        obj.actions.items,
    );
}
