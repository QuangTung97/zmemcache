const std = @import("std");
const types = @import("types.zig");
const zslab = @import("slab_class.zig");
const zlock = @import("item_lock.zig");
const zlru = @import("lru_service.zig");
const zpage = @import("page.zig");
const zutil = @import("zutil");

const Allocator = std.mem.Allocator;
const HashValue = types.HashValue;
const Item = types.Item;
const SlabClass = types.SlabClass;
const SlabSize = zslab.SlabSize;
const CasNum = types.CasNum;
const LockSlot = types.LockSlot;
const SlabClassConfig = zslab.SlabClassConfig;
const ItemIter = zlru.ItemIter;
const PageNum = zpage.PageNum;

const String = []const u8;
const NullItem = ?*Item;

// TODO validate hash table must bigger than item locks table

const HashTable = struct {
    gpa: std.mem.Allocator,
    buckets: []NullItem,
    mask: u64,

    const Self = @This();

    fn init(gpa: std.mem.Allocator, hash_size_log: u6) !Self {
        const table_size = @as(u64, 1) << hash_size_log;

        // init buckets
        const buckets = try gpa.alloc(NullItem, table_size);
        for (buckets) |*next| {
            next.* = null;
        }

        return .{
            .gpa = gpa,
            .buckets = buckets,
            .mask = table_size - 1,
        };
    }

    fn deinit(self: *Self) void {
        self.gpa.free(self.buckets);
    }

    fn getBucket(self: *Self, hash: HashValue) *NullItem {
        const index = hash.hash & self.mask;
        return &self.buckets[index];
    }
};

pub const ItemSetter = struct {
    hash: HashValue,
    item: *Item,
};

pub const ItemFound = struct {
    hash: HashValue,
    item: *Item,
};

pub const ItemGetter = union(enum) {
    Found: ItemFound,
    NotFound: struct {},
};

pub fn ItemService(
    H: type,
    L: type,
    S: type,
    HashFunc: types.HashFunc(H),
    ItemLocks: zlock.ItemLockFuncs(L),
    LruFuncs: zlru.LruFuncs(S),
) type {
    return struct {
        _hasher: *H,
        _slab_conf: *SlabClassConfig,
        _pager: *zpage.GlobalPager,
        _locker: *L,
        _lru: *S,
        _last_cas: std.atomic.Value(u64),

        _table: HashTable,

        const Self = @This();

        pub fn init(
            gpa: std.mem.Allocator,
            hasher: *H,
            slab_conf: *SlabClassConfig,
            pager: *zpage.GlobalPager,
            locker: *L,
            lru_svc: *S,
            hash_size_log: u6,
        ) !Self {
            const hash_table = try HashTable.init(gpa, hash_size_log);

            return .{
                ._hasher = hasher,
                ._slab_conf = slab_conf,
                ._pager = pager,
                ._locker = locker,
                ._lru = lru_svc,
                ._table = hash_table,
                ._last_cas = .init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            self._table.deinit();
        }

        pub fn put(self: *Self, key: String, value_len: usize) ?ItemSetter {
            // compute hash value & lock slot
            const hash_value = HashFunc.hashKey(self._hasher, key);
            const lock_slot = ItemLocks.getSlot(self._locker, hash_value);

            // compute slab class & item size
            const raw_item_size = Item.computeItemSize(key.len, value_len);
            const slab_size = self._slab_conf.getItemSlab(raw_item_size);
            const slab = slab_size.slab_class;

            // lock with item locks
            ItemLocks.lock(self._locker, lock_slot);
            defer ItemLocks.unlock(self._locker, lock_slot);

            // lock slab
            LruFuncs.lockSlab(self._lru, slab);
            defer LruFuncs.unlockSlab(self._lru, slab);

            const null_item = self.getFreeItem(slab_size, lock_slot);
            const it = if (null_item) |x| x else {
                // return if not found
                return null;
            };

            // init item
            const cas_num = self.nextCasNum();
            it.* = Item.init(slab, key.len, value_len, cas_num);
            it.item_flags.set_partial = true;
            it.refcount.refcount += 1;

            // copy the key
            @memcpy(it.getKey(), key);

            // put to lru list
            LruFuncs.putItem(self._lru, slab, it);

            // add to bucket
            const hash_next = self._table.getBucket(hash_value);
            it.hash_next = hash_next.*;
            hash_next.* = it;

            return .{
                .hash = hash_value,
                .item = it,
            };
        }

        pub fn finishPut(self: *Self, setter: ItemSetter) void {
            const slot = ItemLocks.getSlot(self._locker, setter.hash);

            ItemLocks.lock(self._locker, slot);
            defer ItemLocks.unlock(self._locker, slot);

            setter.item.item_flags.set_partial = false;
            setter.item.refcount.refcount -= 1;
        }

        pub fn get(self: *Self, key: String) ItemGetter {
            // compute hash value & lock slot
            const hash_value = HashFunc.hashKey(self._hasher, key);
            const lock_slot = ItemLocks.getSlot(self._locker, hash_value);

            // lock item
            ItemLocks.lock(self._locker, lock_slot);
            defer ItemLocks.unlock(self._locker, lock_slot);

            const pitem = self.findItemPointerWithKey(hash_value, key);
            const null_item = pitem.*;
            const it = if (null_item) |p| p else {
                return .{ .NotFound = .{} };
            };

            // increase refcount
            it.refcount.refcount += 1;
            LruFuncs.touchItem(self._lru, it.slab, it);

            return .{
                .Found = .{
                    .hash = hash_value,
                    .item = it,
                },
            };
        }

        pub fn finishGet(self: *Self, found: ItemFound) void {
            const lock_slot = ItemLocks.getSlot(self._locker, found.hash);

            // lock item
            ItemLocks.lock(self._locker, lock_slot);
            defer ItemLocks.unlock(self._locker, lock_slot);

            found.item.refcount.refcount -= 1;
        }

        pub fn delete(self: *Self, key: String) void {
            // compute hash value & lock slot
            const hash_value = HashFunc.hashKey(self._hasher, key);
            const lock_slot = ItemLocks.getSlot(self._locker, hash_value);

            // lock item
            ItemLocks.lock(self._locker, lock_slot);
            defer ItemLocks.unlock(self._locker, lock_slot);

            const pitem = self.findItemPointerWithKey(hash_value, key);
            const null_item = pitem.*;
            const it = if (null_item) |p| p else {
                return;
            };
            self.doDeleteItem(it.slab, it, pitem);
        }

        fn getFreeItem(self: *Self, slab: SlabSize, lock_slot: LockSlot) ?*Item {
            const null_item1 = LruFuncs.getFreeItem(self._lru, slab.slab_class);
            if (null_item1) |it| {
                return it;
            }

            // try to get new page from page pool
            self.getNewPageFromPool(slab);

            const null_item2n = LruFuncs.getFreeItem(self._lru, slab.slab_class);
            if (null_item2n) |it| {
                return it;
            }

            // evict from lru if no free item exists
            self.evictFromLru(slab.slab_class, lock_slot);

            return LruFuncs.getFreeItem(self._lru, slab.slab_class);
        }

        fn getNewPageFromPool(self: *Self, slab: SlabSize) void {
            self.assertSlabLocked(slab.slab_class);

            const null_page = self._pager.allocPage(slab.slab_class);
            const page = if (null_page) |p| p else {
                return;
            };
            const page_num = self._pager.getPageNumOfPage(page);

            const IterateCtx = struct {
                self: *Self,
                slab: SlabClass,
                fn yield(ctx: *@This(), item: *Item) bool {
                    LruFuncs.putFreeItem(ctx.self._lru, ctx.slab, item);
                    return true;
                }
            };
            var ctx = IterateCtx{
                .self = self,
                .slab = slab.slab_class,
            };
            self._pager.iterateItemsOfPage(
                page,
                slab.item_size,
                &ctx,
                IterateCtx.yield,
            );

            // page number to slab
            LruFuncs.pushPage(self._lru, slab.slab_class, page_num);
        }

        fn evictFromLru(self: *Self, slab: SlabClass, current_slot: LockSlot) void {
            self.assertSlabLocked(slab);

            var ctx = struct {
                self: *Self,
                slab: SlabClass,
                current_slot: LockSlot,
                pub fn yield(ctx: *@This(), item: *Item) bool {
                    // TODO limit number of attempts
                    const ok = ctx.self.tryToEvictItem(
                        item,
                        ctx.slab,
                        ctx.current_slot,
                    );
                    return !ok;
                }
            }{
                .self = self,
                .slab = slab,
                .current_slot = current_slot,
            };

            // iterate through lru list
            LruFuncs.iterateItems(
                self._lru,
                slab,
                ItemIter.init(&ctx),
            );
        }

        fn tryToEvictItem(self: *Self, evicted_item: *Item, slab: SlabClass, current_slot: LockSlot) bool {
            self.assertSlabLocked(slab);

            const new_hash = HashFunc.hashKey(self._hasher, evicted_item.getKey());
            const new_slot = ItemLocks.getSlot(self._locker, new_hash);

            // do not lock if lock slot the same
            if (current_slot.lock_slot == new_slot.lock_slot) {
                return self.findInBucketAndDeleteItem(slab, new_hash, evicted_item);
            }

            // try to lock the evicted item
            const locked = ItemLocks.tryLock(self._locker, new_slot);
            if (!locked) {
                return false;
            }
            defer ItemLocks.unlock(self._locker, new_slot);

            return self.findInBucketAndDeleteItem(slab, new_hash, evicted_item);
        }

        fn findInBucketAndDeleteItem(self: *Self, slab: SlabClass, hash: HashValue, deleted_item: *Item) bool {
            self.assertItemLocked(hash);

            const pitem = self.findItemPointerInBucket(hash, deleted_item);
            const null_item = pitem.*;
            if (null_item == null) {
                return false;
            }

            self.doDeleteItem(slab, deleted_item, pitem);
            return true;
        }

        fn doDeleteItem(self: *Self, slab: SlabClass, deleted_item: *Item, pitem: *NullItem) void {
            const next = deleted_item.hash_next;
            pitem.* = next;

            LruFuncs.deleteItem(self._lru, slab, deleted_item);
            LruFuncs.putFreeItem(self._lru, slab, deleted_item);
        }

        fn findItemPointerInBucket(self: *Self, hash: HashValue, find_item: *Item) *NullItem {
            self.assertItemLocked(hash);

            var pitem = self._table.getBucket(hash);
            while (pitem.*) |it| {
                if (it == find_item) {
                    return pitem;
                }
                pitem = &it.hash_next;
            }
            return pitem;
        }

        fn findItemPointerWithKey(self: *Self, hash: HashValue, key: String) *NullItem {
            self.assertItemLocked(hash);

            var pitem = self._table.getBucket(hash);
            while (pitem.*) |it| {
                if (std.mem.eql(u8, it.getKey(), key)) {
                    return pitem;
                }
                pitem = &it.hash_next;
            }
            return pitem;
        }

        fn assertItemLocked(self: *Self, hash: HashValue) void {
            const slot = ItemLocks.getSlot(self._locker, hash);
            std.debug.assert(ItemLocks.isLocked(self._locker, slot));
        }

        fn assertSlabLocked(self: *Self, slab: SlabClass) void {
            std.debug.assert(LruFuncs.isSlabLocked(self._lru, slab));
        }

        fn nextCasNum(self: *Self) CasNum {
            const num = self._last_cas.fetchAdd(1, .seq_cst);
            return CasNum{ .cas = num + 1 };
        }
    };
}

// ===========================================================================
// Testing
// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "hash table" {
    try expectEqual(8 * 5, @sizeOf(HashTable));

    var h = try HashTable.init(std.testing.allocator, 5);
    defer h.deinit();

    try expectEqual(0b11111, h.mask);
}

const key01 = "key01";
const hash1 = HashValue.init(21);

const key02 = "key02";
const hash2 = HashValue.init(22);

const key03 = "key03";
const hash3 = HashValue.init(23);

const key04 = "key04";
const hash4 = HashValue.init(24);

const TouchItem = zlru.FakeLruService.TouchItem;

const ServiceTest = struct {
    const ServiceType = ItemService(
        types.FakeHashFunc,
        zlock.FakeItemLocks,
        zlru.FakeLruService,
        types.NewHashFunc(types.FakeHashFunc),
        zlock.NewItemLockFuncs(zlock.FakeItemLocks),
        zlru.NewLruFuncs(zlru.FakeLruService),
    );
    const Self = @This();

    gpa: Allocator,
    hash_func: types.FakeHashFunc,
    slab_conf: SlabClassConfig,
    pager: zpage.GlobalPager,
    locker: zlock.FakeItemLocks,
    lru_svc: zlru.FakeLruService,
    svc: ServiceType,

    const Config = struct {
        num_pages: u64 = 3,
    };

    fn init(conf: Config) !*Self {
        const io = std.testing.io;
        const gpa = std.testing.allocator;

        const s = try gpa.create(Self);

        s.gpa = gpa;
        s.hash_func = types.FakeHashFunc.init(gpa);
        s.slab_conf = try zslab.SlabClassConfig.init(
            gpa,
            96,
            512,
            1.5,
        );
        s.pager = try zpage.GlobalPager.init(io, gpa, 9, conf.num_pages);
        s.locker = zlock.FakeItemLocks.init(gpa);
        s.lru_svc = zlru.FakeLruService.init(gpa);

        s.svc = try ServiceType.init(
            gpa,
            &s.hash_func,
            &s.slab_conf,
            &s.pager,
            &s.locker,
            &s.lru_svc,
            5,
        );

        // setup hash values
        s.hash_func.putKeyHash(key01, hash1);
        s.hash_func.putKeyHash(key02, hash2);
        s.hash_func.putKeyHash(key03, hash3);
        s.hash_func.putKeyHash(key04, hash4);

        return s;
    }

    fn deinit(self: *Self) void {
        self.svc.deinit();
        self.lru_svc.deinit();
        self.locker.deinit();
        self.pager.deinit();
        self.slab_conf.deinit();
        self.hash_func.deinit();
        self.gpa.destroy(self);
    }

    fn put(self: *Self, key: String, value_len: usize) ?ItemSetter {
        const result = self.svc.put(key, value_len);
        self.checkInvariant();
        return result;
    }

    fn finishPut(self: *Self, setter: ItemSetter) void {
        self.svc.finishPut(setter);
        self.checkInvariant();
    }

    fn putAndFinish(self: *Self, key: String, value_len: usize) void {
        const setter = self.put(key, value_len).?;
        @memset(setter.item.getValue(), 71);
        self.finishPut(setter);
    }

    fn get(self: *Self, key: String) ItemGetter {
        const getter = self.svc.get(key);
        self.checkInvariant();
        return getter;
    }

    fn finishGet(self: *Self, found: ItemFound) void {
        self.svc.finishGet(found);
        self.checkInvariant();
    }

    fn getAndFinish(self: *Self, key: String) void {
        const getter = self.get(key);
        std.debug.assert(std.meta.activeTag(getter) == ItemGetter.Found);
        self.finishGet(getter.Found);
    }

    fn delete(self: *Self, key: String) void {
        return self.svc.delete(key);
    }

    fn checkInvariant(self: *Self) void {
        const gpa = std.testing.allocator;

        var slab_page_map = std.AutoHashMap(SlabClass, PageNum).init(gpa);
        defer slab_page_map.deinit();

        var inuse_pages = std.AutoHashMap(PageNum, struct {}).init(gpa);
        defer inuse_pages.deinit();

        var slab_iter = self.slab_conf.getAllSlabClasses();
        while (slab_iter.next()) |slab| {
            const null_page_list = self.lru_svc.page_queue_map.get(slab.slab_class);
            const page_list = if (null_page_list) |h| h else {
                continue;
            };

            var it = page_list.iterator();
            while (it.next()) |page_num| {
                inuse_pages.put(page_num, .{}) catch unreachable;
                slab_page_map.put(slab.slab_class, page_num) catch unreachable;
                self.checkSlabPageInvariant(slab, page_num);
            }
        }

        var page_iter = self.pager.getAllPages();
        while (page_iter.next()) |page_num| {
            const null_slab = self.pager.getSlabClass(page_num);
            if (null_slab) |slab| {
                std.debug.assert(inuse_pages.contains(page_num));
                std.debug.assert(slab_page_map.get(slab).?.page_num == page_num.page_num);
            } else {
                std.debug.assert(!inuse_pages.contains(page_num));
            }
        }
    }

    fn checkSlabPageInvariant(self: *Self, slab: SlabSize, page_num: PageNum) void {
        const page = self.pager.getPageOfPageNum(page_num);

        const IterateCtx = struct {
            pub fn yield(_: *@This(), _: *Item) bool {
                // TODO handle
                // std.debug.assert(item.slab_flags.is_present);
                return true;
            }
        };
        var ctx = IterateCtx{};
        self.pager.iterateItemsOfPage(page, slab.item_size, &ctx, IterateCtx.yield);
    }

    fn expectItemKeysInSlab(self: *Self, slab: SlabClass, expected_keys: []const String) !void {
        const gpa = std.testing.allocator;

        var ctx = struct {
            all_keys: std.ArrayList(String),
            pub fn yield(ctx: *@This(), item: *Item) bool {
                ctx.all_keys.append(gpa, item.getKey()) catch unreachable;
                return true;
            }
        }{
            .all_keys = .empty,
        };
        defer ctx.all_keys.deinit(gpa);

        self.lru_svc.iterateItems(
            slab,
            ItemIter.init(&ctx),
        );

        try zutil.expectStringSlicesEqual(expected_keys, ctx.all_keys.items);
    }

    fn expectItemKeysInBucket(self: *Self, hash: HashValue, expected_keys: []const String) !void {
        const gpa = std.testing.allocator;
        const bucket_next = self.svc._table.getBucket(hash);

        var actual_keys = std.ArrayList(String).empty;
        defer actual_keys.deinit(gpa);

        var next_item = bucket_next.*;
        while (next_item) |it| {
            try actual_keys.append(gpa, it.getKey());
            next_item = it.hash_next;
        }

        try zutil.expectStringSlicesEqual(expected_keys, actual_keys.items);
    }

    fn expectTouchList(self: *Self, expected: []const TouchItem) !void {
        const actual_list = self.lru_svc.touch_list.items;
        try expectEqual(expected.len, actual_list.len);

        for (actual_list, 0..) |x, index| {
            try expectEqual(expected[index].slab, x.slab);
            try std.testing.expectEqualStrings(expected[index].key, x.key);
        }
    }
};

test "put then finish" {
    const s = try ServiceTest.init(.{});
    defer s.deinit();

    // put
    const setter = s.put(key01, 46).?;

    // check basic setter info
    try expectEqual(hash1, setter.hash);
    try expectEqual(SlabClass.init(1), setter.item.slab);
    try expectEqual(144, s.slab_conf.getSlabSize(setter.item.slab));

    // check item key
    try expectEqual(Item.Size + key01.len + 46, setter.item.getItemSize());
    try std.testing.expectEqualStrings(key01, setter.item.getKey());

    // check flags
    try expectEqual(true, setter.item.slab_flags.is_present);
    try expectEqual(false, setter.item.item_flags.is_deleting);
    try expectEqual(true, setter.item.item_flags.set_partial);
    try expectEqual(2, setter.item.refcount.refcount);

    // check address
    try expectEqual(144 * 2, setter.item.toItemAddr() - s.pager.getBaseAddr());

    // set value
    try expectEqual(46, setter.item.getValue().len);
    @memset(setter.item.getValue(), 'A');

    s.finishPut(setter);

    // check flags
    try expectEqual(true, setter.item.slab_flags.is_present);
    try expectEqual(false, setter.item.item_flags.is_deleting);
    try expectEqual(false, setter.item.item_flags.set_partial);
    try expectEqual(1, setter.item.refcount.refcount);

    // check actions
    try std.testing.expectEqualSlices(zlock.LockAction, &.{
        .{ .action = .Lock, .hash = hash1.hash },
        .{ .action = .Unlock, .hash = hash1.hash },
        .{ .action = .Lock, .hash = hash1.hash },
        .{ .action = .Unlock, .hash = hash1.hash },
    }, s.locker.actions.items);
}

test "put => get => finish get" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, 46);
    s.putAndFinish(key02, 46);

    // clear lock actions
    s.locker.actions.clearRetainingCapacity();

    const get1 = s.get(key01);
    try expectEqual(ItemGetter.Found, std.meta.activeTag(get1));
    try expectEqual(hash1, get1.Found.hash);

    const it1 = get1.Found.item;
    try std.testing.expectEqualStrings(key01, it1.getKey());
    try expectEqual(46, it1.getValue().len);
    try std.testing.expectEqualSlices(u8, &.{ 71, 71, 71, 71 }, it1.getValue()[0..4]);
    try expectEqual(2, it1.refcount.refcount);
    try expectEqual(false, it1.item_flags.is_deleting);
    try expectEqual(false, it1.item_flags.set_partial);

    // check actions
    try std.testing.expectEqualSlices(zlock.LockAction, &.{
        .{ .action = .Lock, .hash = hash1.hash },
        .{ .action = .Unlock, .hash = hash1.hash },
    }, s.locker.actions.items);
    s.locker.actions.clearRetainingCapacity();

    // check touch list
    try s.expectTouchList(&.{
        TouchItem.init(SlabClass.init(1), key01),
    });

    s.finishGet(get1.Found);

    // check actions
    try std.testing.expectEqualSlices(zlock.LockAction, &.{
        .{ .action = .Lock, .hash = hash1.hash },
        .{ .action = .Unlock, .hash = hash1.hash },
    }, s.locker.actions.items);
    s.locker.actions.clearRetainingCapacity();

    // check refcount
    try expectEqual(1, it1.refcount.refcount);
}

test "with eviction" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, 46);
    s.putAndFinish(key02, 46);
    s.putAndFinish(key03, 46);

    // clear lock actions
    s.locker.actions.clearRetainingCapacity();

    const setter4 = s.put(key04, 46).?;

    // check actions
    try std.testing.expectEqualSlices(zlock.LockAction, &.{
        .{ .action = .Lock, .hash = hash4.hash },
        .{ .action = .TryLock, .hash = hash1.hash },
        .{ .action = .Unlock, .hash = hash1.hash },
        .{ .action = .Unlock, .hash = hash4.hash },
    }, s.locker.actions.items);

    s.finishPut(setter4);

    try s.expectItemKeysInSlab(SlabClass.init(1), &.{
        key02, key03, key04,
    });

    try s.expectItemKeysInBucket(hash1, &.{} );
    try s.expectItemKeysInBucket(hash2, &.{key02});
    try s.expectItemKeysInBucket(hash3, &.{key03});
    try s.expectItemKeysInBucket(hash4, &.{key04});
}

test "with eviction same hash" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, 46);
    s.putAndFinish(key02, 46);
    s.putAndFinish(key03, 46);

    s.hash_func.putKeyHash(key04, hash1);

    // clear lock actions
    s.locker.actions.clearRetainingCapacity();

    const setter4 = s.put(key04, 46).?;

    // check actions
    try std.testing.expectEqualSlices(zlock.LockAction, &.{
        .{ .action = .Lock, .hash = hash1.hash },
        .{ .action = .Unlock, .hash = hash1.hash },
    }, s.locker.actions.items);

    s.finishPut(setter4);

    try s.expectItemKeysInSlab(SlabClass.init(1), &.{
        key02, key03, key04,
    });
}

test "with eviction, key01 is locking" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, 46);
    s.putAndFinish(key02, 46);
    s.putAndFinish(key03, 46);

    // clear lock actions
    s.locker.actions.clearRetainingCapacity();

    // key01 is locking
    s.locker.lock(s.locker.getSlot(hash1));

    const setter4 = s.put(key04, 46).?;

    // check actions
    try std.testing.expectEqualSlices(zlock.LockAction, &.{
        .{ .action = .Lock, .hash = hash1.hash },
        .{ .action = .Lock, .hash = hash4.hash },
        .{ .action = .TryLock, .hash = hash2.hash },
        .{ .action = .Unlock, .hash = hash2.hash },
        .{ .action = .Unlock, .hash = hash4.hash },
    }, s.locker.actions.items);

    s.finishPut(setter4);

    try s.expectItemKeysInSlab(SlabClass.init(1), &.{
        key01, key03, key04,
    });
}

test "put => delete" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.hash_func.putKeyHash(key02, hash1); // same hash as key01

    s.putAndFinish(key01, 46);
    s.putAndFinish(key02, 46);
    s.putAndFinish(key03, 46);
    s.delete(key01);

    try s.expectItemKeysInSlab(SlabClass.init(1), &.{
        key02,
        key03,
    });

    try s.expectItemKeysInBucket(hash1, &.{key02});
    try s.expectItemKeysInBucket(hash2, &.{});
    try s.expectItemKeysInBucket(hash3, &.{key03});
}
