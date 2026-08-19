const std = @import("std");
const zutil = @import("zutil");
const types = @import("types.zig");
const zpage = @import("page.zig");
const zlru = @import("lru_service.zig");

const Allocator = std.mem.Allocator;
const ListHead = zutil.ListHead;
const SlabClass = types.SlabClass;
const PageNum = zpage.PageNum;
const Item = types.Item;
const ItemIter = zlru.ItemIter;
const CasNum = types.CasNum;
const LruList = types.LruList;

pub const ModernLru = struct {
    const Self = @This();

    const SlabClassState = struct {
        mutex: std.Io.Mutex,

        free_list: ListHead,
        hot_list: ListHead,
        warm_list: ListHead,
        cold_list: ListHead,

        num_free: usize,
        num_hot: usize,
        num_warm: usize,
        num_cold: usize,

        page_list: ListHead,
        moving_page: ?PageNum,

        _padding: [8 * 7]u8 = undefined,
    };

    _io: std.Io,
    _gpa: Allocator,
    _all_classes: []SlabClassState,
    _pager: *zpage.GlobalPager,
    _conf: Config,

    const Config = struct {
        num_classes: usize,
        hot_ratio: f64,
    };

    pub fn init(
        io: std.Io,
        gpa: Allocator,
        pager: *zpage.GlobalPager,
        conf: Config,
    ) !Self {
        zutil.runtimeAssert(conf.num_classes <= SlabClass.MaxNumClass);
        const all_classes = try gpa.alloc(SlabClassState, conf.num_classes);
        for (all_classes) |*s| {
            s.* = .{
                .mutex = .init,

                .free_list = undefined,
                .hot_list = undefined,
                .warm_list = undefined,
                .cold_list = undefined,

                .num_free = 0,
                .num_hot = 0,
                .num_warm = 0,
                .num_cold = 0,

                .page_list = undefined,
                .moving_page = null,
            };

            ListHead.initHeader(&s.free_list);
            ListHead.initHeader(&s.hot_list);
            ListHead.initHeader(&s.warm_list);
            ListHead.initHeader(&s.cold_list);

            ListHead.initHeader(&s.page_list);

            ListHead.validateInit(&s.free_list);
            ListHead.validateInit(&s.hot_list);
            ListHead.validateInit(&s.warm_list);
            ListHead.validateInit(&s.cold_list);
            ListHead.validateInit(&s.page_list);
        }

        return .{
            ._io = io,
            ._gpa = gpa,
            ._all_classes = all_classes,
            ._pager = pager,
            ._conf = conf,
        };
    }

    pub fn deinit(self: *Self) void {
        self._gpa.free(self._all_classes);
    }

    pub fn lockSlab(self: *Self, slab: SlabClass) void {
        const state = self.getSlabState(slab);
        state.mutex.lockUncancelable(self._io);
    }

    // for testing only
    fn isSlabLocked(self: *Self, slab: SlabClass) bool {
        const state = self.getSlabState(slab);
        return state.mutex.state.load(.seq_cst) == .locked_once;
    }

    pub fn unlockSlab(self: *Self, slab: SlabClass) void {
        const state = self.getSlabState(slab);
        state.mutex.unlock(self._io);
    }

    pub fn putItem(self: *Self, slab: SlabClass, item: *Item) void {
        std.debug.assert(item.slab_flags.is_present);

        const state = self.getSlabState(slab);
        pushToList(&state.hot_list, &state.num_hot, item, .Hot);
        self.rebalanceLruLists(state);
    }

    pub fn touchItem(_: *Self, _: SlabClass, item: *Item) void {
        std.debug.assert(item.slab_flags.is_present);
        _ = item.atomic_flags.setActive();
        // TODO
    }

    pub fn deleteItem(_: *Self, _: SlabClass, _: *Item) void {
        // TODO
    }

    pub fn iterateItems(self: *Self, slab: SlabClass, iterator: ItemIter) void {
        const state = self.getSlabState(slab);

        if (!iterateLruList(&state.cold_list, iterator)) {
            return;
        }
        if (!iterateLruList(&state.warm_list, iterator)) {
            return;
        }
        if (!iterateLruList(&state.hot_list, iterator)) {
            return;
        }
    }

    fn iterateLruList(head: *ListHead, iterator: ItemIter) bool {
        var iter = head.iterateBackward();
        while (iter.next()) |e| {
            const item = Item.fromList(e);
            const ok = iterator.yield(item);
            if (!ok) {
                return false;
            }
        }
        return true;
    }

    fn rebalanceLruLists(self: *Self, state: *SlabClassState) void {
        const total_int = state.num_hot + state.num_warm + state.num_cold;
        const total: f64 = @floatFromInt(total_int);

        const expected_hot: usize = @floor(total * self._conf.hot_ratio);
        while (state.num_hot > expected_hot) {
            const entry = popFromList(&state.hot_list, &state.num_hot).?;

            const item = Item.fromList(entry);
            const is_active = item.atomic_flags.getInfo().is_active;
            if (is_active) {
                pushToList(&state.warm_list, &state.num_warm, item, .Warm);
            } else {
                pushToList(&state.cold_list, &state.num_cold, item, .Cold);
            }
        }
    }

    fn pushToList(head: *ListHead, counter: *usize, item: *Item, lru_enum: LruList) void {
        item.atomic_flags.setLru(lru_enum);
        head.pushFront(&item.lru_list);
        counter.* += 1;
    }

    fn popFromList(head: *ListHead, counter: *usize) ?*ListHead {
        const null_entry = head.popBack();
        const entry = null_entry orelse return null;

        counter.* -= 1;
        return entry;
    }

    pub fn pushPage(self: *Self, slab: SlabClass, page_num: PageNum) void {
        const state = self.getSlabState(slab);
        const entry = self._pager.getPageListHead(page_num);
        state.page_list.pushBack(entry);
    }

    pub fn popPage(self: *Self, slab: SlabClass) ?PageNum {
        const state = self.getSlabState(slab);
        const null_entry = state.page_list.popFront();
        const entry = null_entry orelse return null;

        const page_num = self._pager.getPageNumOfListHead(entry);
        return page_num;
    }

    pub fn setMovingPage(self: *Self, slab: SlabClass, page_num: ?PageNum) void {
        const state = self.getSlabState(slab);
        state.moving_page = page_num;
    }

    pub fn getMovingPage(self: *Self, slab: SlabClass) ?PageNum {
        const state = self.getSlabState(slab);
        return state.moving_page;
    }

    pub fn putFreeItem(self: *Self, slab: SlabClass, item: *Item) void {
        std.debug.assert(!item.slab_flags.is_present);
        const state = self.getSlabState(slab);
        state.free_list.pushBack(&item.lru_list);
        state.num_free += 1;
    }

    pub fn getFreeItem(self: *Self, slab: SlabClass) ?*Item {
        const state = self.getSlabState(slab);
        const null_entry = state.free_list.popBack();
        const entry = null_entry orelse return null;

        const item = Item.fromList(entry);
        std.debug.assert(!item.slab_flags.is_present);
        state.num_free -= 1;

        return item;
    }

    pub fn deleteFreeItem(self: *Self, slab: SlabClass, item: *Item) void {
        std.debug.assert(!item.slab_flags.is_present);
        const state = self.getSlabState(slab);
        item.lru_list.remove();
        state.num_free -= 1;
    }

    fn getSlabState(self: *Self, slab: SlabClass) *SlabClassState {
        return &self._all_classes[slab.slab];
    }
};

// ===========================================================================
// Testing
// ===========================================================================

const expectEqual = std.testing.expectEqual;

const TestCasList = []const u64;

const ServiceTest = struct {
    const Self = @This();

    pager: *zpage.GlobalPager,
    svc: ModernLru,

    const Config = struct {
        num_classes: usize = 5,
        hot_ratio: f64 = 0.2,
    };

    fn init(conf: Config) !*Self {
        const io = std.testing.io;
        const gpa = std.testing.allocator;

        const s = try gpa.create(Self);

        s.pager = try zpage.GlobalPager.init(io, gpa, 10, 20);
        s.svc = try ModernLru.init(io, gpa, s.pager, .{
            .num_classes = conf.num_classes,
            .hot_ratio = conf.hot_ratio,
        });

        return s;
    }

    fn deinit(self: *Self) void {
        self.checkInvariant();

        const gpa = std.testing.allocator;

        self.pager.deinit();
        self.svc.deinit();
        gpa.destroy(self);
    }

    fn newItem(_: *Self, cas: u64) Item {
        var item: Item = undefined;
        item.slab_flags.is_present = true;
        item.cas_num = CasNum.init(cas);
        return item;
    }

    fn putItem(self: *Self, slab: SlabClass, item: *Item) void {
        defer self.checkInvariant();
        self.svc.putItem(slab, item);
    }

    fn touchItem(self: *Self, slab: SlabClass, item: *Item) void {
        defer self.checkInvariant();
        self.svc.touchItem(slab, item);
    }

    fn expectHotList(self: *Self, slab: SlabClass, cas_list: TestCasList) !void {
        const state = self.svc.getSlabState(slab);
        try expectCasList(self, &state.hot_list, cas_list);
    }

    fn expectWarmList(self: *Self, slab: SlabClass, cas_list: TestCasList) !void {
        const state = self.svc.getSlabState(slab);
        try expectCasList(self, &state.warm_list, cas_list);
    }

    fn expectColdList(self: *Self, slab: SlabClass, cas_list: TestCasList) !void {
        const state = self.svc.getSlabState(slab);
        try expectCasList(self, &state.cold_list, cas_list);
    }

    fn expectCasList(self: *Self, head: *ListHead, cas_list: TestCasList) !void {
        const gpa = std.testing.allocator;

        var list = try self.getCasOfListHead(head);
        defer list.deinit(gpa);

        try std.testing.expectEqualSlices(u64, cas_list, list.items);
    }

    fn getCasOfListHead(_: *Self, head: *ListHead) !std.ArrayList(u64) {
        const gpa = std.testing.allocator;

        var list = std.ArrayList(u64).empty;
        errdefer list.deinit(gpa);

        var iter = head.iterate();
        while (iter.next()) |x| {
            const item = Item.fromList(x);
            try list.append(gpa, item.cas_num.cas);
        }

        return list;
    }

    fn expectIterateLru(self: *Self, slab: SlabClass, cas_list: TestCasList, max_num: usize) !void {
        const gpa = std.testing.allocator;

        var ctx = struct {
            list: std.ArrayList(u64),
            num: usize,
            max_num: usize,
            pub fn yield(ctx: *@This(), item: *Item) bool {
                ctx.num += 1;
                ctx.list.append(gpa, item.cas_num.cas) catch unreachable;
                return ctx.num < ctx.max_num;
            }
        }{
            .list = .empty,
            .num = 0,
            .max_num = max_num,
        };
        defer ctx.list.deinit(gpa);

        self.svc.iterateItems(slab, ItemIter.init(&ctx));

        try std.testing.expectEqualSlices(u64, cas_list, ctx.list.items);
    }

    fn newFreeItem(_: *Self, cas: u64) Item {
        var item: Item = undefined;
        item.slab_flags.is_present = false;
        item.cas_num = CasNum.init(cas);
        return item;
    }

    fn putFreeItem(self: *Self, slab: SlabClass, item: *Item) void {
        defer self.checkInvariant();
        self.svc.lockSlab(slab);
        defer self.svc.unlockSlab(slab);

        self.svc.putFreeItem(slab, item);
    }

    fn getFreeItem(self: *Self, slab: SlabClass) ?u64 {
        defer self.checkInvariant();
        self.svc.lockSlab(slab);
        defer self.svc.unlockSlab(slab);

        const null_item = self.svc.getFreeItem(slab);
        if (null_item) |it| {
            return it.cas_num.cas;
        }

        return null;
    }

    fn deleteFreeItem(self: *Self, slab: SlabClass, item: *Item) void {
        defer self.checkInvariant();
        self.svc.lockSlab(slab);
        defer self.svc.unlockSlab(slab);

        self.svc.deleteFreeItem(slab, item);
    }

    fn pushPage(self: *Self, slab: SlabClass, num: PageNum) void {
        defer self.checkInvariant();
        self.svc.pushPage(slab, num);
    }

    fn popPage(self: *Self, slab: SlabClass) ?PageNum {
        defer self.checkInvariant();
        return self.svc.popPage(slab);
    }

    fn checkInvariant(self: *Self) void {
        for (self.svc._all_classes) |*state| {
            validateLruList(&state.hot_list, state.num_hot, .Hot);
            validateLruList(&state.warm_list, state.num_warm, .Warm);
            validateLruList(&state.cold_list, state.num_cold, .Cold);
        }
    }

    fn validateLruList(head: *ListHead, counter: usize, lru_enum: LruList) void {
        var total: usize = 0;
        var iter = head.iterate();
        while (iter.next()) |e| {
            const item = Item.fromList(e);
            std.debug.assert(item.atomic_flags.getInfo().lru == lru_enum);
            total += 1;
        }
        std.debug.assert(total == counter);
    }
};

test "slab class state size" {
    try expectEqual(64 * 3, @sizeOf(ModernLru.SlabClassState));
}

test "check impl" {
    const m = zlru.NewLruFuncs(ModernLru);
    _ = m;
}

test "locking" {
    const s = try ServiceTest.init(.{});
    defer s.deinit();

    const slab0 = SlabClass.init(0);
    const slab1 = SlabClass.init(1);

    try expectEqual(false, s.svc.isSlabLocked(slab0));
    try expectEqual(false, s.svc.isSlabLocked(slab1));

    s.svc.lockSlab(slab1);

    try expectEqual(false, s.svc.isSlabLocked(slab0));
    try expectEqual(true, s.svc.isSlabLocked(slab1));

    s.svc.unlockSlab(slab1);

    try expectEqual(false, s.svc.isSlabLocked(slab0));
    try expectEqual(false, s.svc.isSlabLocked(slab1));
}

test "free list" {
    var s = try ServiceTest.init(.{});
    defer s.deinit();

    const slab1 = SlabClass.init(1);
    const slab2 = SlabClass.init(2);

    var item1 = s.newFreeItem(11);
    var item2 = s.newFreeItem(12);
    var item3 = s.newFreeItem(13);

    // put
    s.putFreeItem(slab1, &item1);
    s.putFreeItem(slab1, &item2);
    s.putFreeItem(slab2, &item3);

    try expectEqual(2, s.svc.getSlabState(slab1).num_free);
    try expectEqual(1, s.svc.getSlabState(slab2).num_free);

    // get
    try expectEqual(12, s.getFreeItem(slab1));
    try expectEqual(1, s.svc.getSlabState(slab1).num_free);
    try expectEqual(1, s.svc.getSlabState(slab2).num_free);

    // get all
    try expectEqual(11, s.getFreeItem(slab1));
    try expectEqual(null, s.getFreeItem(slab1));
    try expectEqual(0, s.svc.getSlabState(slab1).num_free);
    try expectEqual(1, s.svc.getSlabState(slab2).num_free);
}

test "free list, with delete" {
    var s = try ServiceTest.init(.{});
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    var item1 = s.newFreeItem(11);
    var item2 = s.newFreeItem(12);
    var item3 = s.newFreeItem(13);

    // put
    s.putFreeItem(slab1, &item1);
    s.putFreeItem(slab1, &item2);
    s.putFreeItem(slab1, &item3);

    try expectEqual(3, s.svc.getSlabState(slab1).num_free);

    // delete middle
    s.deleteFreeItem(slab1, &item2);
    try expectEqual(2, s.svc.getSlabState(slab1).num_free);

    // get all
    try expectEqual(13, s.getFreeItem(slab1));
    try expectEqual(11, s.getFreeItem(slab1));
    try expectEqual(null, s.getFreeItem(slab1));
    try expectEqual(0, s.svc.getSlabState(slab1).num_free);
}

test "moving page" {
    var s = try ServiceTest.init(.{});
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    s.svc.lockSlab(slab1);
    defer s.svc.unlockSlab(slab1);

    try expectEqual(null, s.svc.getMovingPage(slab1));

    // set
    s.svc.setMovingPage(slab1, PageNum.init(21));
    try expectEqual(PageNum.init(21), s.svc.getMovingPage(slab1));

    // set null
    s.svc.setMovingPage(slab1, null);
    try expectEqual(null, s.svc.getMovingPage(slab1));
}

test "add page" {
    var s = try ServiceTest.init(.{});
    defer s.deinit();

    const slab1 = SlabClass.init(1);
    const slab2 = SlabClass.init(2);

    const page1 = PageNum.init(11);
    const page2 = PageNum.init(12);

    s.pushPage(slab1, page1);
    s.pushPage(slab1, page2);

    // pop not found
    try expectEqual(null, s.popPage(slab2));

    // pop found
    try expectEqual(page1, s.popPage(slab1));
    try expectEqual(page2, s.popPage(slab1));
    try expectEqual(null, s.popPage(slab1));
}

test "lru, all to cold" {
    var s = try ServiceTest.init(.{});
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    var item1 = s.newItem(31);
    var item2 = s.newItem(32);
    var item3 = s.newItem(33);

    s.putItem(slab1, &item1);
    s.putItem(slab1, &item2);
    s.putItem(slab1, &item3);

    try s.expectHotList(slab1, &.{});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{ 33, 32, 31 });

    // check iterate
    try s.expectIterateLru(slab1, &.{ 31, 32, 33 }, 100);
    try s.expectIterateLru(slab1, &.{31}, 1);
}

test "lru, half to hot" {
    var s = try ServiceTest.init(.{ .hot_ratio = 0.5 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    var item1 = s.newItem(31);
    var item2 = s.newItem(32);
    var item3 = s.newItem(33);

    s.putItem(slab1, &item1);
    s.putItem(slab1, &item2);

    try s.expectHotList(slab1, &.{32});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{31});
    try s.expectIterateLru(slab1, &.{ 31, 32 }, 100);
    try s.expectIterateLru(slab1, &.{31}, 1);

    s.putItem(slab1, &item3);

    try s.expectHotList(slab1, &.{33});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{ 32, 31 });
    try s.expectIterateLru(slab1, &.{ 31, 32, 33 }, 100);
    try s.expectIterateLru(slab1, &.{ 31, 32 }, 2);
}

test "put to hot => touch => move to warm" {
    var s = try ServiceTest.init(.{ .hot_ratio = 0.5 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    var item1 = s.newItem(31);
    var item2 = s.newItem(32);
    var item3 = s.newItem(33);

    s.putItem(slab1, &item1);
    s.putItem(slab1, &item2);

    try s.expectHotList(slab1, &.{32});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{31});

    s.touchItem(slab1, &item2); // touch item 2
    s.putItem(slab1, &item3);

    try s.expectHotList(slab1, &.{33});
    try s.expectWarmList(slab1, &.{32});
    try s.expectColdList(slab1, &.{31});

    try s.expectIterateLru(slab1, &.{ 31, 32, 33 }, 100);
    try s.expectIterateLru(slab1, &.{ 31, 32 }, 2);
    try s.expectIterateLru(slab1, &.{31}, 1);
}
