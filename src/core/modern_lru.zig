const std = @import("std");
const zutil = @import("zutil");
const types = @import("types.zig");
const zpage = @import("page.zig");
const zlru = @import("lru_service.zig");
const ztouch = @import("touch_list.zig");

const Allocator = std.mem.Allocator;
const ListHead = zutil.ListHead;
const SlabClass = types.SlabClass;
const PageNum = zpage.PageNum;
const Item = types.Item;
const ItemIter = zlru.ItemIter;
const CasNum = types.CasNum;
const LruList = types.LruList;
const TouchItem = ztouch.TouchItem;

const LruListInfo = struct {
    head: *ListHead,
    counter: *usize,
    lru_enum: LruList,

    const Self = @This();

    fn pushToList(self: Self, item: *Item) void {
        item.atomic_flags.setLru(self.lru_enum);
        self.head.pushFront(&item.lru_list);
        self.counter.* += 1;
    }

    fn popFromList(self: LruListInfo) ?*ListHead {
        const null_entry = self.head.popBack();
        const entry = null_entry orelse return null;
        self.counter.* -= 1;
        return entry;
    }

    fn deleteFromList(self: LruListInfo, item: *Item) void {
        std.debug.assert(item.atomic_flags.getInfo().lru == self.lru_enum);
        item.lru_list.remove();
        self.counter.* -= 1;
    }
};

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

    const Self = @This();

    fn getHot(self: *Self) LruListInfo {
        return .{
            .head = &self.hot_list,
            .counter = &self.num_hot,
            .lru_enum = .Hot,
        };
    }

    fn getWarm(self: *Self) LruListInfo {
        return .{
            .head = &self.warm_list,
            .counter = &self.num_warm,
            .lru_enum = .Warm,
        };
    }

    fn getCold(self: *Self) LruListInfo {
        return .{
            .head = &self.cold_list,
            .counter = &self.num_cold,
            .lru_enum = .Cold,
        };
    }

    fn getTotal(self: *Self) f64 {
        const total = self.num_hot + self.num_warm + self.num_cold;
        return @floatFromInt(total);
    }
};

pub fn ModernLru(
    TouchList: type,
    TouchListFuncs: ztouch.TouchListFuncs(TouchList),
) type {
    return struct {
        const Self = @This();

        _io: std.Io,
        _gpa: Allocator,
        _all_classes: []SlabClassState,
        _pager: *zpage.GlobalPager,
        _conf: Config,
        _touch_list: *TouchList,

        const Config = struct {
            num_classes: usize,
            hot_ratio: f64,
            warm_ratio: f64,
            max_repeated_in_warm: usize,
        };

        pub fn init(
            io: std.Io,
            gpa: Allocator,
            pager: *zpage.GlobalPager,
            touch_list: *TouchList,
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
                ._touch_list = touch_list,
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
            state.getHot().pushToList(item);
            self.rebalanceLruLists(state);
        }

        pub fn touchItem(self: *Self, slab: SlabClass, item: *Item) void {
            std.debug.assert(item.slab_flags.is_present);
            std.debug.assert(item.slab.equal(slab));

            const status = item.atomic_flags.setActive();
            switch (status) {
                .OK => {
                    return;
                },
                .IsCold => {
                    TouchListFuncs.push(self._touch_list, .fromItem(item));
                },
            }
        }

        // asyncTouchItem must be called when locked
        pub fn asyncTouchItem(self: *Self, touch_item: TouchItem) void {
            const page_num = self._pager.getPageNumOfItem(touch_item.item);
            const null_slab = self._pager.getSlabClass(page_num);
            if (!touch_item.slab.nullEqual(null_slab)) {
                return;
            }

            const item = touch_item.item;
            if (!item.slab_flags.is_present) {
                return;
            }
            if (!item.cas_num.equal(touch_item.cas)) {
                return;
            }
            if (item.atomic_flags.getInfo().lru != .Cold) {
                return;
            }

            const state = self.getSlabState(touch_item.slab);

            state.getCold().deleteFromList(item);
            state.getWarm().pushToList(item);

            self.rebalanceLruLists(state);
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
                const entry = state.getHot().popFromList().?;
                const item = Item.fromList(entry);
                const is_active = item.atomic_flags.getInfo().is_active;
                if (is_active) {
                    state.getWarm().pushToList(item);
                } else {
                    state.getCold().pushToList(item);
                }
            }

            const expected_warm: usize = @floor(total * self._conf.warm_ratio);
            var repeated_active_count: usize = 0;
            while (state.num_warm > expected_warm) {
                const entry = state.getWarm().popFromList().?;
                const item = Item.fromList(entry);
                const is_active = item.atomic_flags.getInfo().is_active;
                if (is_active and repeated_active_count < self._conf.max_repeated_in_warm) {
                    repeated_active_count += 1;
                    state.getWarm().pushToList(item);
                } else {
                    repeated_active_count = 0;
                    state.getCold().pushToList(item);
                }
            }
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
}

// ===========================================================================
// Testing
// ===========================================================================

const expectEqual = std.testing.expectEqual;

const TestCasList = []const u64;

const ServiceTest = struct {
    const Self = @This();

    const Service = ModernLru(
        ztouch.FakeTouchList,
        ztouch.NewTouchListFuncs(ztouch.FakeTouchList),
    );

    pager: *zpage.GlobalPager,
    touch_list: ztouch.FakeTouchList,
    fake_lru: zlru.FakeLruService,
    svc: Service,

    const Config = struct {
        num_classes: usize = 5,
        hot_ratio: f64 = 0.2,
        warm_ratio: f64 = 0.4,
        max_repeated_in_warm: usize = 5,
    };

    fn init(conf: Config) !*Self {
        const io = std.testing.io;
        const gpa = std.testing.allocator;

        const s = try gpa.create(Self);
        s.* = .{
            .pager = try zpage.GlobalPager.init(io, gpa, 10, 20),
            .touch_list = try ztouch.FakeTouchList.init(gpa),
            .fake_lru = zlru.FakeLruService.init(gpa),
            .svc = undefined,
        };

        s.svc = try Service.init(io, gpa, s.pager, &s.touch_list, .{
            .num_classes = conf.num_classes,
            .hot_ratio = conf.hot_ratio,
            .warm_ratio = conf.warm_ratio,
            .max_repeated_in_warm = conf.max_repeated_in_warm,
        });

        return s;
    }

    fn deinit(self: *Self) void {
        self.checkInvariant();

        const gpa = std.testing.allocator;

        self.svc.deinit();
        self.fake_lru.deinit();
        self.touch_list.deinit();
        self.pager.deinit();
        gpa.destroy(self);
    }

    fn newItem(self: *Self, slab: SlabClass, cas: u64) *Item {
        const item = self.allocNewItem(slab);
        item.cas_num = CasNum.init(cas);
        item.slab_flags.is_present = true;
        return item;
    }

    fn allocNewItem(self: *Self, slab: SlabClass) *Item {
        const null_item = self.fake_lru.getFreeItem(slab);
        if (null_item) |it| {
            return it;
        }

        const null_page = self.pager.allocPage(slab);
        const page = null_page.?;

        const IterateCtx = struct {
            self: *Self,
            slab: SlabClass,
            fn yield(ctx: *@This(), item: *Item) bool {
                item.slab_flags.is_present = false;
                item.slab = ctx.slab;
                ctx.self.fake_lru.putFreeItem(ctx.slab, item);
                return true;
            }
        };
        var ctx = IterateCtx{
            .self = self,
            .slab = slab,
        };
        self.pager.iterateItemsOfPage(
            page,
            Item.Size,
            &ctx,
            IterateCtx.yield,
        );

        return self.fake_lru.getFreeItem(slab).?;
    }

    fn putItem(self: *Self, slab: SlabClass, item: *Item) void {
        defer self.checkInvariant();
        self.svc.putItem(slab, item);
    }

    fn touchItem(self: *Self, slab: SlabClass, item: *Item) void {
        defer self.checkInvariant();
        self.svc.touchItem(slab, item);
    }

    fn asyncTouch(self: *Self) void {
        const item = self.touch_list.pop() catch unreachable;
        self.svc.asyncTouchItem(item);
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

            const total_int = state.num_hot + state.num_warm + state.num_cold;
            const total: f64 = @floatFromInt(total_int);

            const max_hot: usize = @floor(total * self.svc._conf.hot_ratio);
            const max_warm: usize = @floor(total * self.svc._conf.warm_ratio);

            std.debug.assert(state.num_hot <= max_hot);
            std.debug.assert(state.num_warm <= max_warm);
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
    try expectEqual(64 * 3, @sizeOf(SlabClassState));
}

test "check impl" {
    const m = zlru.NewLruFuncs(ServiceTest.Service);
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

    const item1 = s.newItem(slab1, 31);
    const item2 = s.newItem(slab1, 32);
    const item3 = s.newItem(slab1, 33);

    s.putItem(slab1, item1);
    s.putItem(slab1, item2);
    s.putItem(slab1, item3);

    try s.expectHotList(slab1, &.{});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{ 33, 32, 31 });

    // check iterate
    try s.expectIterateLru(slab1, &.{ 31, 32, 33 }, 100);
    try s.expectIterateLru(slab1, &.{31}, 1);

    // check touch list
    try expectEqual(0, s.touch_list._queue.len);
}

test "lru, half to hot" {
    var s = try ServiceTest.init(.{ .hot_ratio = 0.5 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    const item1 = s.newItem(slab1, 31);
    const item2 = s.newItem(slab1, 32);
    const item3 = s.newItem(slab1, 33);

    s.putItem(slab1, item1);
    s.putItem(slab1, item2);

    try s.expectHotList(slab1, &.{32});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{31});
    try s.expectIterateLru(slab1, &.{ 31, 32 }, 100);
    try s.expectIterateLru(slab1, &.{31}, 1);

    s.putItem(slab1, item3);

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

    const item1 = s.newItem(slab1, 31);
    const item2 = s.newItem(slab1, 32);
    const item3 = s.newItem(slab1, 33);

    s.putItem(slab1, item1);
    s.putItem(slab1, item2);

    try s.expectHotList(slab1, &.{32});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{31});

    s.touchItem(slab1, item2); // touch item 2
    s.putItem(slab1, item3);

    try s.expectHotList(slab1, &.{33});
    try s.expectWarmList(slab1, &.{32});
    try s.expectColdList(slab1, &.{31});

    try s.expectIterateLru(slab1, &.{ 31, 32, 33 }, 100);
    try s.expectIterateLru(slab1, &.{ 31, 32 }, 2);
    try s.expectIterateLru(slab1, &.{31}, 1);
}

test "cold to warm" {
    var s = try ServiceTest.init(.{ .hot_ratio = 0.2, .warm_ratio = 0.4 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    const item1 = s.newItem(slab1, 31);
    const item2 = s.newItem(slab1, 32);
    const item3 = s.newItem(slab1, 33);
    const item4 = s.newItem(slab1, 34);
    const item5 = s.newItem(slab1, 35);

    s.putItem(slab1, item1);
    s.putItem(slab1, item2);
    s.putItem(slab1, item3);
    s.putItem(slab1, item4);
    s.putItem(slab1, item5);

    s.touchItem(slab1, item2);

    try s.expectHotList(slab1, &.{35});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{ 34, 33, 32, 31 });
    try expectEqual(1, s.touch_list._queue.len); // update touch list

    // async touch
    s.asyncTouch();

    try s.expectHotList(slab1, &.{35});
    try s.expectWarmList(slab1, &.{32});
    try s.expectColdList(slab1, &.{ 34, 33, 31 });
    try expectEqual(0, s.touch_list._queue.len);
}

test "cold to warm, multi items" {
    var s = try ServiceTest.init(.{ .hot_ratio = 0.2, .warm_ratio = 0.4 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    const item1 = s.newItem(slab1, 31);
    const item2 = s.newItem(slab1, 32);
    const item3 = s.newItem(slab1, 33);
    const item4 = s.newItem(slab1, 34);
    const item5 = s.newItem(slab1, 35);

    s.putItem(slab1, item1);
    s.putItem(slab1, item2);
    s.putItem(slab1, item3);
    s.putItem(slab1, item4);
    s.putItem(slab1, item5);

    s.touchItem(slab1, item2);
    s.touchItem(slab1, item3);
    s.touchItem(slab1, item4);

    try s.expectHotList(slab1, &.{35});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{ 34, 33, 32, 31 });
    try expectEqual(3, s.touch_list._queue.len); // update touch list

    // async touch
    s.asyncTouch();
    s.asyncTouch();
    s.asyncTouch();

    try s.expectHotList(slab1, &.{35});
    try s.expectWarmList(slab1, &.{ 34, 33 });
    try s.expectColdList(slab1, &.{ 32, 31 });
    try expectEqual(0, s.touch_list._queue.len);
}

test "cold to warm => touch in warm => move other back to cold" {
    var s = try ServiceTest.init(.{ .hot_ratio = 0.2, .warm_ratio = 0.4 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    const item1 = s.newItem(slab1, 31);
    const item2 = s.newItem(slab1, 32);
    const item3 = s.newItem(slab1, 33);
    const item4 = s.newItem(slab1, 34);
    const item5 = s.newItem(slab1, 35);

    s.putItem(slab1, item1);
    s.putItem(slab1, item2);
    s.putItem(slab1, item3);
    s.putItem(slab1, item4);
    s.putItem(slab1, item5);

    try s.expectHotList(slab1, &.{35});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{ 34, 33, 32, 31 });

    s.touchItem(slab1, item2);
    s.touchItem(slab1, item3);
    s.asyncTouch();
    s.asyncTouch();

    // touch item 2
    s.touchItem(slab1, item2);
    try expectEqual(true, item2.atomic_flags.getInfo().is_active);

    // touch item 4
    s.touchItem(slab1, item4);
    s.asyncTouch();

    try s.expectHotList(slab1, &.{35});
    try s.expectWarmList(slab1, &.{ 32, 34 });
    try s.expectColdList(slab1, &.{ 33, 31 });
    try expectEqual(0, s.touch_list._queue.len);
    try expectEqual(false, item2.atomic_flags.getInfo().is_active);
}

test "cold to warm => with max repeated in warm = 1" {
    var s = try ServiceTest.init(.{
        .hot_ratio = 0.2,
        .warm_ratio = 0.4,
        .max_repeated_in_warm = 1,
    });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    const item1 = s.newItem(slab1, 31);
    const item2 = s.newItem(slab1, 32);
    const item3 = s.newItem(slab1, 33);
    const item4 = s.newItem(slab1, 34);
    const item5 = s.newItem(slab1, 35);

    s.putItem(slab1, item1);
    s.putItem(slab1, item2);
    s.putItem(slab1, item3);
    s.putItem(slab1, item4);
    s.putItem(slab1, item5);

    try s.expectHotList(slab1, &.{35});
    try s.expectWarmList(slab1, &.{});
    try s.expectColdList(slab1, &.{ 34, 33, 32, 31 });

    s.touchItem(slab1, item2);
    s.touchItem(slab1, item3);
    s.asyncTouch();
    s.asyncTouch();

    // touch item 2 & 3
    s.touchItem(slab1, item2);
    s.touchItem(slab1, item3);

    // touch item 4
    s.touchItem(slab1, item4);
    s.asyncTouch();

    try s.expectHotList(slab1, &.{35});
    try s.expectWarmList(slab1, &.{ 32, 34 });
    try s.expectColdList(slab1, &.{ 33, 31 });
}
