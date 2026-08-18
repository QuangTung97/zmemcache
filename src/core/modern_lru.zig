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

    pub fn init(io: std.Io, gpa: Allocator, num_classes: usize) !Self {
        zutil.runtimeAssert(num_classes <= SlabClass.MaxNumClass);

        const all_classes = try gpa.alloc(SlabClassState, num_classes);
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

    pub fn putItem(_: *Self, _: SlabClass, _: *Item) void {
        // TODO
    }

    pub fn touchItem(_: *Self, _: SlabClass, _: *Item) void {
        // TODO
    }

    pub fn deleteItem(_: *Self, _: SlabClass, _: *Item) void {
        // TODO
    }

    pub fn iterateItems(_: *Self, _: SlabClass, _: ItemIter) void {
        // TODO
    }

    pub fn pushPage(_: *Self, _: SlabClass, _: PageNum) void {
        // TODO
    }

    pub fn popPage(_: *Self, _: SlabClass) ?PageNum {
        // TODO
        return null;
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

const ServiceTest = struct {
    const Self = @This();

    svc: ModernLru,

    fn init() !*Self {
        const io = std.testing.io;
        const gpa = std.testing.allocator;

        const s = try gpa.create(Self);
        s.svc = try ModernLru.init(io, gpa, 5);

        return s;
    }

    fn deinit(self: *Self) void {
        self.checkInvariant();

        const gpa = std.testing.allocator;
        self.svc.deinit();
        gpa.destroy(self);
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

    fn checkInvariant(_: *Self) void {}
};

test "slab class state size" {
    try expectEqual(64 * 3, @sizeOf(ModernLru.SlabClassState));
}

test "check impl" {
    const m = zlru.NewLruFuncs(ModernLru);
    _ = m;
}

test "locking" {
    const s = try ServiceTest.init();
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
    var s = try ServiceTest.init();
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
    var s = try ServiceTest.init();
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
    var s = try ServiceTest.init();
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
