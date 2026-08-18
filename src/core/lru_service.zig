const std = @import("std");
const types = @import("types.zig");
const zutil = @import("zutil");
const zpage = @import("page.zig");

const Allocator = std.mem.Allocator;
const ListHead = zutil.ListHead;

const Item = types.Item;
const Slab = types.SlabClass;
const CasNum = types.CasNum;
const PageNum = zpage.PageNum;

pub const ItemIter = zutil.Iterator(*Item);

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

        pushPage: fn (self: *T, slab: Slab, page: PageNum) void,
        popPage: fn (self: *T, slab: Slab) ?PageNum,

        setMovingPage: fn (self: *T, slab: Slab, page_num: ?PageNum) void,
        getMovingPage: fn (self: *T, slab: Slab) ?PageNum,
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

        .pushPage = T.pushPage,
        .popPage = T.popPage,

        .setMovingPage = T.setMovingPage,
        .getMovingPage = T.getMovingPage,
    };
}

// ===========================================================================
// Fake Lru Service
// ===========================================================================

pub const FakeLruService = struct {
    const Self = @This();
    const LockedSetType = std.AutoHashMap(Slab, struct {});
    const SlabMap = std.AutoHashMap(Slab, *ListHead);
    const PageQueue = std.Deque(PageNum);
    const PageQueueMap = std.AutoHashMap(Slab, *PageQueue);
    const MovingPageMap = std.AutoHashMap(Slab, PageNum);

    pub const TouchItem = struct {
        slab: Slab,
        key: []const u8,
        pub fn init(slab: Slab, key: []const u8) @This() {
            return .{ .slab = slab, .key = key };
        }
    };
    const TouchList = std.ArrayList(TouchItem);

    gpa: Allocator,
    locked_set: LockedSetType,
    lru_map: SlabMap,
    free_map: SlabMap,
    page_queue_map: PageQueueMap,
    touch_list: TouchList,
    moving_page_map: MovingPageMap,

    pub fn init(gpa: Allocator) Self {
        const locked_set = LockedSetType.init(gpa);
        const lru_map = SlabMap.init(gpa);
        const free_map = SlabMap.init(gpa);
        const page_queue_map = PageQueueMap.init(gpa);
        const touch_list = TouchList.empty;
        const moving_page_map = MovingPageMap.init(gpa);

        return .{
            .gpa = gpa,
            .locked_set = locked_set,
            .lru_map = lru_map,
            .free_map = free_map,
            .page_queue_map = page_queue_map,
            .touch_list = touch_list,
            .moving_page_map = moving_page_map,
        };
    }

    pub fn deinit(self: *Self) void {
        self.moving_page_map.deinit();
        self.touch_list.deinit(self.gpa);
        self.destroyPageQueueMap();
        destroyMap(self.gpa, &self.free_map);
        destroyMap(self.gpa, &self.lru_map);
        self.locked_set.deinit();
    }

    fn destroyMap(gpa: Allocator, input_map: *SlabMap) void {
        var iter = input_map.iterator();
        while (iter.next()) |entry| {
            gpa.destroy(entry.value_ptr.*);
        }
        input_map.deinit();
    }

    fn destroyPageQueueMap(self: *Self) void {
        var iter = self.page_queue_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.gpa);
            self.gpa.destroy(entry.value_ptr.*);
        }
        self.page_queue_map.deinit();
    }

    pub fn lockSlab(self: *Self, slab: Slab) void {
        std.debug.assert(!self.locked_set.contains(slab));
        std.debug.assert(self.locked_set.count() == 0); // not allow concurrent slab locks

        self.locked_set.put(slab, .{}) catch unreachable;
    }

    pub fn unlockSlab(self: *Self, slab: Slab) void {
        std.debug.assert(self.locked_set.contains(slab));

        const ok = self.locked_set.remove(slab);
        std.debug.assert(ok);
    }

    pub fn isSlabLocked(self: *Self, slab: Slab) bool {
        return self.locked_set.contains(slab);
    }

    pub fn putItem(self: *Self, slab: Slab, item: *Item) void {
        const head = self.getLruList(slab);
        head.pushBack(&item.lru_list);
    }

    pub fn touchItem(self: *Self, slab: Slab, item: *Item) void {
        const entry = TouchItem.init(slab, item.getKey());
        self.touch_list.append(self.gpa, entry) catch unreachable;
    }

    pub fn deleteItem(_: *Self, _: Slab, item: *Item) void {
        item.lru_list.remove();
    }

    pub fn iterateItems(self: *Self, slab: Slab, iterator: ItemIter) void {
        const head = self.getLruList(slab);
        var iter = head.iterate();
        while (iter.next()) |node| {
            const item = Item.fromList(node);
            const ok = iterator.yield(item);
            if (!ok) {
                return;
            }
        }
    }

    pub fn putFreeItem(self: *Self, slab: Slab, item: *Item) void {
        const head = self.getFreeList(slab);
        head.pushBack(&item.lru_list);
    }

    pub fn getFreeItem(self: *Self, slab: Slab) ?*Item {
        const head = self.getFreeList(slab);
        const null_node = head.popBack();
        if (null_node) |node| {
            return Item.fromList(node);
        }
        return null;
    }

    fn getLruList(self: *Self, slab: Slab) *ListHead {
        return getMapNodeList(self.gpa, &self.lru_map, slab);
    }

    fn getFreeList(self: *Self, slab: Slab) *ListHead {
        return getMapNodeList(self.gpa, &self.free_map, slab);
    }

    fn getMapNodeList(gpa: Allocator, input_map: *SlabMap, slab: Slab) *ListHead {
        const null_list = input_map.get(slab);
        if (null_list) |head| {
            return head;
        }

        var head = gpa.create(ListHead) catch unreachable;
        head.initHeader();
        input_map.put(slab, head) catch unreachable;
        return head;
    }

    pub fn pushPage(self: *Self, slab: Slab, page: PageNum) void {
        const queue = self.getPageQueue(slab);
        queue.pushBack(self.gpa, page) catch unreachable;
    }

    pub fn popPage(self: *Self, slab: Slab) ?PageNum {
        const queue = self.getPageQueue(slab);
        return queue.popFront();
    }

    fn getPageQueue(self: *Self, slab: Slab) *PageQueue {
        const null_queue = self.page_queue_map.get(slab);
        if (null_queue) |q| {
            return q;
        }

        const queue = self.gpa.create(PageQueue) catch unreachable;
        queue.* = PageQueue.empty;
        self.page_queue_map.put(slab, queue) catch unreachable;

        return queue;
    }

    pub fn setMovingPage(self: *Self, slab: Slab, page_num: ?PageNum) void {
        if (page_num) |num| {
            self.moving_page_map.put(slab, num) catch unreachable;
        } else {
            _ = self.moving_page_map.remove(slab);
        }
    }

    pub fn getMovingPage(self: *Self, slab: Slab) ?PageNum {
        return self.moving_page_map.get(slab);
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
    try expectLruList(&.{ 41, 42, 43 }, &s, slab1);

    s.deleteItem(slab1, &item2);

    // check iterate through items
    try expectLruList(&.{ 41, 43 }, &s, slab1);
}

fn expectItemValue(value: u64, item: ?*Item) !void {
    try std.testing.expect(item != null);
    try expectEqual(value, item.?.cas_num.cas);
}

test "free list" {
    const gpa = std.testing.allocator;
    var s = FakeLruService.init(gpa);
    defer s.deinit();

    const slab1 = Slab.init(11);

    var item1 = newItem(41);
    var item2 = newItem(42);
    var item3 = newItem(43);

    s.putFreeItem(slab1, &item1);
    s.putFreeItem(slab1, &item2);
    s.putFreeItem(slab1, &item3);

    try expectItemValue(43, s.getFreeItem(slab1));
    try expectItemValue(42, s.getFreeItem(slab1));
    try expectItemValue(41, s.getFreeItem(slab1));
    try expectEqual(null, s.getFreeItem(slab1));
}

test "page queue" {
    const gpa = std.testing.allocator;
    var s = FakeLruService.init(gpa);
    defer s.deinit();

    const slab1 = Slab.init(11);
    const slab2 = Slab.init(12);

    s.pushPage(slab1, PageNum.init(21));
    s.pushPage(slab1, PageNum.init(22));
    s.pushPage(slab1, PageNum.init(23));

    try expectEqual(null, s.popPage(slab2));

    try expectEqual(PageNum.init(21), s.popPage(slab1));
    try expectEqual(PageNum.init(22), s.popPage(slab1));
    try expectEqual(PageNum.init(23), s.popPage(slab1));
    try expectEqual(null, s.popPage(slab1));
}
