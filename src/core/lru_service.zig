const std = @import("std");
const types = @import("types.zig");
const zutil = @import("zutil");

const Allocator = std.mem.Allocator;
const Item = types.Item;
const Slab = types.SlabClass;
const CasNum = types.CasNum;
const ItemIter = zutil.Iterator(*Item);

pub fn LruFuncs(T: type) type {
    return struct {
        lockSlab: fn (self: *T, slab: Slab) void,
        unlockSlab: fn (self: *T, slab: Slab) void,
        isSlabLocked: fn (self: *T, slab: Slab) bool,

        putItem: fn (self: *T, slab: Slab, item: *Item) void,
        touchItem: fn (self: *T, slab: Slab, item: *Item) void,
        deleteItem: fn (self: *T, slab: Slab, item: *Item) void,
        // iterateLru: fn (self: *T, slab: Slab) LruIter, TODO add back

        putFreeItem: fn (self: *T, slab: Slab, item: *Item) void,
        getFreeItem: fn (self: *T, slab: Slab) ?*Item,

        // TODO add push page and pop page
    };
}

pub fn NewLruFuncs(T: type) LruFuncs(T) {
    return .{
        .lockSlab = T.lockSlab,
        .unlockSlab = T.unlockSlab,
        .isSlabLocked = T.isSlabLocked,

        .putItem = T.putItem,
        .touchItem = T.touchItem,
        .deleteItem = T.deleteItem,

        .putFreeItem = T.putFreeItem,
        .getFreeItem = T.getFreeItem,
    };
}

// ===========================================================================
// Fake Lru Service
// ===========================================================================

pub const FakeLruService = struct {
    const LockedSetType = std.AutoHashMap(Slab, struct {});
    lockedSet: LockedSetType,

    const Self = @This();

    pub fn init(gpa: Allocator) Self {
        const lockedSet = LockedSetType.init(gpa);
        return .{
            .lockedSet = lockedSet,
        };
    }

    pub fn deinit(self: *Self) void {
        self.lockedSet.deinit();
    }

    pub fn lockSlab(self: *Self, slab: Slab) void {
        std.debug.assert(!self.lockedSet.contains(slab));
        self.lockedSet.put(slab, .{}) catch unreachable;
    }

    pub fn unlockSlab(self: *Self, slab: Slab) void {
        const ok = self.lockedSet.remove(slab);
        std.debug.assert(ok);
    }

    pub fn isSlabLocked(self: *Self, slab: Slab) bool {
        return self.lockedSet.contains(slab);
    }

    pub fn putItem(_: *Self, _: Slab, _: *Item) void {}

    pub fn touchItem(_: *Self, _: Slab, _: *Item) void {}

    pub fn deleteItem(_: *Self, _: Slab, _: *Item) void {}

    pub fn iterateItems(_: *Self, _: Slab, _: ItemIter) void {}

    pub fn putFreeItem(_: *Self, _: Slab, _: *Item) void {}

    pub fn getFreeItem(_: *Self, _: Slab) ?*Item {
        return null;
    }
};

// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "lock & unlock" {
    const gpa = std.testing.allocator;
    var fake = FakeLruService.init(gpa);
    defer fake.deinit();

    const s = NewLruFuncs(FakeLruService);

    const slab1 = Slab{ .slab = 21 };
    const slab2 = Slab{ .slab = 22 };

    try expectEqual(false, s.isSlabLocked(&fake, slab1));
    try expectEqual(false, s.isSlabLocked(&fake, slab2));

    // lock
    s.lockSlab(&fake, slab1);

    try expectEqual(true, s.isSlabLocked(&fake, slab1));
    try expectEqual(false, s.isSlabLocked(&fake, slab2));

    // unlock
    s.unlockSlab(&fake, slab1);
    try expectEqual(false, s.isSlabLocked(&fake, slab1));
}

test "lru list" {
    const gpa = std.testing.allocator;
    var s = FakeLruService.init(gpa);
    defer s.deinit();

    const slab1 = Slab.init(11);

    var item1: Item = undefined;
    item1.cas_num = CasNum.init(41);

    var item2: Item = undefined;
    item2.cas_num = CasNum.init(42);

    var item3: Item = undefined;
    item3.cas_num = CasNum.init(43);

    s.putItem(slab1, &item1);
    s.putItem(slab1, &item2);
    s.putItem(slab1, &item3);
}
