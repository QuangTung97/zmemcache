const std = @import("std");
const types = @import("types.zig");
const zutil = @import("zutil");

const Allocator = std.mem.Allocator;

const ItemIter = zutil.Iterator(*Item);
const ListHead = zutil.ListHead;

const Item = types.Item;
const Slab = types.SlabClass;
const CasNum = types.CasNum;

pub fn LruFuncs(T: type) type {
    return struct {
        lockSlab: fn (self: *T, slab: Slab) void,
        unlockSlab: fn (self: *T, slab: Slab) void,
        isSlabLocked: fn (self: *T, slab: Slab) bool,

        putItem: fn (self: *T, slab: Slab, item: *Item) void,
        touchItem: fn (self: *T, slab: Slab, item: *Item) void,
        deleteItem: fn (self: *T, slab: Slab, item: *Item) void,
        iterateItems: fn (self: *T, slab: Slab, iterator: ItemIter) void,

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
        .iterateItems = T.iterateItems,

        .putFreeItem = T.putFreeItem,
        .getFreeItem = T.getFreeItem,
    };
}

// ===========================================================================
// Fake Lru Service
// ===========================================================================

pub const FakeLruService = struct {
    const Self = @This();
    const LockedSetType = std.AutoHashMap(Slab, struct {});
    const SlabMap = std.AutoHashMap(Slab, *ListHead);

    gpa: Allocator,
    lockedSet: LockedSetType,
    slabMap: SlabMap,

    pub fn init(gpa: Allocator) Self {
        const lockedSet = LockedSetType.init(gpa);
        const slabMap = SlabMap.init(gpa);

        return .{
            .gpa = gpa,
            .lockedSet = lockedSet,
            .slabMap = slabMap,
        };
    }

    pub fn deinit(self: *Self) void {
        self.lockedSet.deinit();

        var iter = self.slabMap.iterator();
        while (iter.next()) |entry| {
            self.gpa.destroy(entry.value_ptr.*);
        }

        self.slabMap.deinit();
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

    pub fn putItem(self: *Self, slab: Slab, item: *Item) void {
        const head = self.getSlabList(slab);
        head.pushBack(&item.lru_list);
    }

    pub fn touchItem(_: *Self, _: Slab, _: *Item) void {}

    pub fn deleteItem(_: *Self, _: Slab, item: *Item) void {
        item.lru_list.remove();
    }

    pub fn iterateItems(self: *Self, slab: Slab, iterator: ItemIter) void {
        const head = self.getSlabList(slab);
        var iter = head.iterate();
        while (iter.next()) |node| {
            const item = Item.fromList(node);
            const ok = iterator.yield(item);
            if (!ok) {
                return;
            }
        }
    }

    pub fn putFreeItem(_: *Self, _: Slab, _: *Item) void {}

    pub fn getFreeItem(_: *Self, _: Slab) ?*Item {
        return null;
    }

    fn getSlabList(self: *Self, slab: Slab) *ListHead {
        const null_list = self.slabMap.get(slab);
        if (null_list) |head| {
            return head;
        }

        var head = self.gpa.create(ListHead) catch unreachable;
        head.initHeader();

        self.slabMap.put(slab, head) catch unreachable;

        return head;
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

fn newItem(v: u64) Item {
    var item: Item = undefined;
    item.cas_num = CasNum.init(v);
    return item;
}

fn expectLruList(expected: []const u64, s: *FakeLruService, slab: Slab) !void {
    const gpa = std.testing.allocator;

    const CasList = std.ArrayList(u64);

    var ctx = struct {
        values: CasList,
        pub fn yield(self: *@This(), item: *Item) bool {
            self.values.append(gpa, item.cas_num.cas) catch unreachable;
            return true;
        }
        fn deinit(self: *@This()) void {
            self.values.deinit(gpa);
        }
    }{
        .values = CasList.empty,
    };
    defer ctx.deinit();

    s.iterateItems(slab, ItemIter.init(&ctx));

    try std.testing.expectEqualSlices(u64, expected, ctx.values.items);
}

test "lru list" {
    const gpa = std.testing.allocator;
    var s = FakeLruService.init(gpa);
    defer s.deinit();

    const slab1 = Slab.init(11);

    var item1 = newItem(41);
    var item2 = newItem(42);
    var item3 = newItem(43);

    s.putItem(slab1, &item1);
    s.putItem(slab1, &item2);
    s.putItem(slab1, &item3);

    // check iterate through items
    try expectLruList(&.{41, 42, 43}, &s, slab1);

    s.deleteItem(slab1, &item2);

    // check iterate through items
    try expectLruList(&.{41, 43}, &s, slab1);
}
