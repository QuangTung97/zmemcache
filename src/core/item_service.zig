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

const ItemList = std.ArrayList(*Item);

pub fn ItemFuncs(T: type) type {
    return struct {
        put: fn (self: *T, key: String, value_len: usize) ?ItemSetter,
        finishPut: fn (self: *T, setter: ItemSetter) void,
        get: fn (self: *T, key: String) ItemGetter,
        finishGet: fn (self: *T, found: ItemFound) void,
        delete: fn (self: *T, key: String) void,
        startMovePage: fn (
            self: *T,
            from_slab: SlabClass,
            gpa: Allocator,
            delete_list: *ItemList,
        ) ?PageNum,
    };
}

pub fn NewItemFuncs(T: type) ItemFuncs(T) {
    return .{
        .put = T.put,
        .finishPut = T.finishPut,
        .get = T.get,
        .finishGet = T.finishGet,
        .delete = T.delete,
        .startMovePage = T.startMovePage,
    };
}

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
    SetPartial: struct {},
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
            const slab_size = self._slab_conf.getSlabFromItemSize(raw_item_size);
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
            self.decreaseRefcountAndDelete(setter.hash, setter.item);
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

            if (it.item_flags.set_partial) {
                return .{ .SetPartial = .{} };
            }

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

            self.decreaseRefcountAndDelete(found.hash, found.item);
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

            self.doDeleteItem(hash_value, it, pitem);
        }

        pub fn startMovePage(self: *Self, from_slab: SlabClass, gpa: Allocator, delete_list: *ItemList) ?PageNum {
            LruFuncs.lockSlab(self._lru, from_slab);
            defer LruFuncs.unlockSlab(self._lru, from_slab);

            const null_page_num = LruFuncs.popPage(self._lru, from_slab);
            const page_num = if (null_page_num) |num| num else {
                return null;
            };

            const item_size = self._slab_conf.getItemSizeOfSlab(from_slab);
            const moving_page = self._pager.getPageOfPageNum(page_num);

            const IterateCtx = struct {
                self: *Self,
                gpa: Allocator,
                delete_list: *ItemList,
                fn yield(ctx: *@This(), item: *Item) bool {
                    if (item.slab_flags.is_present) {
                        ctx.delete_list.append(ctx.gpa, item) catch unreachable;
                    } else {
                        item.lru_list.remove(); // remove from free list
                    }
                    return true;
                }
            };
            var ctx = IterateCtx{
                .self = self,
                .gpa = gpa,
                .delete_list = delete_list,
            };

            // iterate through items of moving page
            self._pager.iterateItemsOfPage(moving_page, item_size, &ctx, IterateCtx.yield);

            LruFuncs.setMovingPage(self._lru, from_slab, page_num);
            return page_num;
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
                    item.slab_flags.is_present = false;
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
                current_slot: LockSlot,
                pub fn yield(ctx: *@This(), item: *Item) bool {
                    // TODO limit number of attempts
                    const ok = ctx.self.tryToEvictItem(
                        item,
                        ctx.current_slot,
                    );
                    return !ok;
                }
            }{
                .self = self,
                .current_slot = current_slot,
            };

            // iterate through lru list
            LruFuncs.iterateItems(
                self._lru,
                slab,
                ItemIter.init(&ctx),
            );
        }

        fn tryToEvictItem(self: *Self, evicted_item: *Item, current_slot: LockSlot) bool {
            const slab = evicted_item.slab;
            self.assertSlabLocked(slab);

            const new_hash = HashFunc.hashKey(self._hasher, evicted_item.getKey());
            const new_slot = ItemLocks.getSlot(self._locker, new_hash);

            // do not lock if lock slot the same
            if (current_slot.lock_slot == new_slot.lock_slot) {
                return self.checkEvictCondAndDeleteItem(new_hash, evicted_item);
            }

            // try to lock the evicted item
            const locked = ItemLocks.tryLock(self._locker, new_slot);
            if (!locked) {
                return false;
            }
            defer ItemLocks.unlock(self._locker, new_slot);

            return self.checkEvictCondAndDeleteItem(new_hash, evicted_item);
        }

        fn checkEvictCondAndDeleteItem(self: *Self, hash: HashValue, deleted_item: *Item) bool {
            self.assertItemLocked(hash);

            if (deleted_item.refcount.refcount != 1) {
                return false;
            }

            const pitem = self.findItemPointerInBucket(hash, deleted_item);
            const null_item = pitem.*;
            if (null_item == null) {
                return false;
            }

            self.doDeleteItem(hash, deleted_item, pitem);
            return true;
        }

        fn doDeleteItem(self: *Self, hash: HashValue, deleted_item: *Item, pitem: *NullItem) void {
            // unlink from bucket
            const next = deleted_item.hash_next;
            pitem.* = next;

            // try to remove from lru
            self.decreaseRefcountAndDelete(hash, deleted_item);
        }

        fn decreaseRefcountAndDelete(self: *Self, hash: HashValue, deleted_item: *Item) void {
            self.assertItemLocked(hash);
            deleted_item.refcount.refcount -= 1;

            if (deleted_item.refcount.refcount > 0) {
                return;
            }

            const slab = deleted_item.slab;
            if (LruFuncs.isSlabLocked(self._lru, slab)) {
                self.doMoveItemFromLruToFree(deleted_item);
            } else {
                // lock then delete
                LruFuncs.lockSlab(self._lru, slab);
                defer LruFuncs.unlockSlab(self._lru, slab);

                self.doMoveItemFromLruToFree(deleted_item);
            }
        }

        fn doMoveItemFromLruToFree(self: *Self, deleted_item: *Item) void {
            const slab = deleted_item.slab;
            self.assertSlabLocked(slab);

            // clear present flag
            deleted_item.slab_flags.is_present = false;

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
    const HashFunc = types.NewHashFunc(types.FakeHashFunc);
    const ItemLocks = zlock.NewItemLockFuncs(zlock.FakeItemLocks);
    const LruFuncs = zlru.NewLruFuncs(zlru.FakeLruService);

    const ServiceType = ItemService(
        types.FakeHashFunc,
        zlock.FakeItemLocks,
        zlru.FakeLruService,
        HashFunc,
        ItemLocks,
        LruFuncs,
    );

    const Self = @This();

    gpa: Allocator,
    hash_func: types.FakeHashFunc,
    slab_conf: SlabClassConfig,
    pager: zpage.GlobalPager,
    locker: zlock.FakeItemLocks,
    lru_svc: zlru.FakeLruService,
    svc: ServiceType,

    move_items: ItemList,

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

        s.move_items = ItemList.empty;

        // setup hash values
        s.hash_func.putKeyHash(key01, hash1);
        s.hash_func.putKeyHash(key02, hash2);
        s.hash_func.putKeyHash(key03, hash3);
        s.hash_func.putKeyHash(key04, hash4);

        return s;
    }

    fn deinit(self: *Self) void {
        self.checkInvariant();

        self.move_items.deinit(self.gpa);
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
        self.svc.delete(key);
        self.checkInvariant();
    }

    fn tryEvictKey(self: *Self, key: String) bool {
        // compute hash value & lock slot
        const hash_value = HashFunc.hashKey(self.svc._hasher, key);
        const lock_slot = ItemLocks.getSlot(self.svc._locker, hash_value);

        ItemLocks.lock(self.svc._locker, lock_slot);
        defer ItemLocks.unlock(self.svc._locker, lock_slot);

        const pitem = self.svc.findItemPointerWithKey(hash_value, key);
        const null_item = pitem.*;
        const item = null_item.?;
        const slab = item.slab;

        LruFuncs.lockSlab(self.svc._lru, slab);
        defer LruFuncs.unlockSlab(self.svc._lru, slab);

        return self.svc.tryToEvictItem(item, lock_slot);
    }

    fn tryEvictKeyItem(self: *Self, item: *Item) bool {
        // compute hash value & lock slot
        const hash_value = HashFunc.hashKey(self.svc._hasher, item.getKey());
        const lock_slot = ItemLocks.getSlot(self.svc._locker, hash_value);

        ItemLocks.lock(self.svc._locker, lock_slot);
        defer ItemLocks.unlock(self.svc._locker, lock_slot);

        const slab = item.slab;
        LruFuncs.lockSlab(self.svc._lru, slab);
        defer LruFuncs.unlockSlab(self.svc._lru, slab);

        return self.svc.tryToEvictItem(item, lock_slot);
    }

    fn startMovePage(self: *Self, slab: SlabClass) PageNum {
        self.move_items.clearRetainingCapacity();
        const num = self.svc.startMovePage(
            slab,
            self.gpa,
            &self.move_items,
        ).?;
        self.checkInvariant();
        return num;
    }

    fn checkInvariant(self: *Self) void {
        const gpa = std.testing.allocator;

        var inuse_pages = std.AutoHashMap(PageNum, SlabClass).init(gpa);
        defer inuse_pages.deinit();

        var slab_iter = self.slab_conf.getAllSlabClasses();
        while (slab_iter.next()) |slab| {
            const null_page_list = self.lru_svc.page_queue_map.get(slab.slab_class);
            const page_list = if (null_page_list) |h| h else {
                continue;
            };

            const num_pages = page_list.len;
            self.checkSlabInvariant(slab.slab_class, num_pages);

            var it = page_list.iterator();
            while (it.next()) |page_num| {
                inuse_pages.put(page_num, slab.slab_class) catch unreachable;
                self.checkSlabPageInvariant(slab, page_num);
            }
        }

        var page_iter = self.pager.getAllPages();
        while (page_iter.next()) |page_num| {
            const null_slab = self.pager.getSlabClass(page_num);
            if (null_slab) |slab| {
                const moving_page = self.lru_svc.getMovingPage(slab);
                if (page_num.nullEqual(moving_page)) {
                    std.debug.assert(!inuse_pages.contains(page_num));
                } else {
                    std.debug.assert(inuse_pages.contains(page_num));
                    const page_slab = inuse_pages.get(page_num);
                    std.debug.assert(slab.nullEqual(page_slab));
                }
            } else {
                std.debug.assert(!inuse_pages.contains(page_num));
            }
        }
    }

    fn checkSlabInvariant(self: *Self, slab: SlabClass, num_pages: usize) void {
        // check lru list
        var lru_ctx = struct {
            slab: SlabClass,
            self: *Self,
            total: usize,
            pub fn yield(ctx: *@This(), item: *Item) bool {
                std.debug.assert(item.slab_flags.is_present);
                std.debug.assert(item.slab.slab == ctx.slab.slab);
                ctx.self.checkItemInSlab(item, ctx.slab);

                const page_num = ctx.self.pager.getPageNumOfItem(item);
                const moving_page = ctx.self.lru_svc.getMovingPage(ctx.slab);
                if (!page_num.nullEqual(moving_page)) {
                    ctx.total += 1;
                }

                return true;
            }
        }{
            .slab = slab,
            .self = self,
            .total = 0,
        };
        self.lru_svc.iterateItems(slab, ItemIter.init(&lru_ctx));

        // check free list
        const null_free_list = self.lru_svc.free_map.get(slab);
        var total_free_items: usize = 0;
        if (null_free_list) |free_list| {
            var it = free_list.iterate();
            while (it.next()) |n| {
                const item = Item.fromList(n);

                // validate not present
                std.debug.assert(!item.slab_flags.is_present);
                self.checkItemInSlab(item, slab);

                const page_num = self.pager.getPageNumOfItem(item);
                const moving_page = self.lru_svc.getMovingPage(slab);
                std.debug.assert(!page_num.nullEqual(moving_page));
                total_free_items += 1;
            }
        }

        // check total number of items
        const item_size = self.slab_conf.getItemSizeOfSlab(slab);
        const num_items_per_page = self.pager.getNumItemsPerPage(item_size);

        const total_is_equal = num_pages * num_items_per_page == lru_ctx.total + total_free_items;
        if (!total_is_equal) {
            std.debug.print("calculated: {}, real: {}, num_free: {}\n", .{
                num_pages * num_items_per_page,
                lru_ctx.total + total_free_items,
                total_free_items,
            });
        }
        std.debug.assert(total_is_equal);
    }

    fn checkItemInSlab(self: *Self, item: *Item, slab: SlabClass) void {
        const page_num = self.pager.getPageNumOfItem(item);
        const page_slab = self.pager.getSlabClass(page_num).?;
        std.debug.assert(slab.slab == page_slab.slab);
    }

    fn checkSlabPageInvariant(self: *Self, slab: SlabSize, page_num: PageNum) void {
        const page = self.pager.getPageOfPageNum(page_num);

        const IterateCtx = struct {
            slab: SlabClass,
            pub fn yield(ctx: *@This(), item: *Item) bool {
                if (item.slab_flags.is_present) {
                    std.debug.assert(item.slab.slab == ctx.slab.slab);
                }
                return true;
            }
        };
        var ctx = IterateCtx{
            .slab = slab.slab_class,
        };
        self.pager.iterateItemsOfPage(page, slab.item_size, &ctx, IterateCtx.yield);
    }

    fn expectItemKeysInSlab(self: *Self, slab: SlabClass, expected_keys: []const String) !void {
        const gpa = std.testing.allocator;

        var ctx = struct {
            all_keys: std.ArrayList(String),
            pub fn yield(ctx: *@This(), item: *Item) bool {
                std.debug.assert(item.slab_flags.is_present);
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

    fn expectItemKeys(self: *Self, expected_keys: []const String, items: []*Item) !void {
        var item_keys = std.ArrayList(String).empty;
        defer item_keys.deinit(self.gpa);

        for (items) |it| {
            try item_keys.append(self.gpa, it.getKey());
        }

        try zutil.expectStringSlicesEqual(expected_keys, item_keys.items);
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

const test_val_len = 98 - key01.len - Item.Size;

test "put then finish" {
    try expectEqual(45, test_val_len);

    const s = try ServiceTest.init(.{});
    defer s.deinit();

    // put
    const setter = s.put(key01, test_val_len).?;

    // check basic setter info
    try expectEqual(hash1, setter.hash);
    try expectEqual(SlabClass.init(1), setter.item.slab);
    try expectEqual(144, s.slab_conf.getItemSizeOfSlab(setter.item.slab));

    // check item key
    try expectEqual(Item.Size + key01.len + test_val_len, setter.item.getItemSize());
    try std.testing.expectEqualStrings(key01, setter.item.getKey());

    // check flags
    try expectEqual(true, setter.item.slab_flags.is_present);
    try expectEqual(true, setter.item.item_flags.set_partial);
    try expectEqual(2, setter.item.refcount.refcount);

    // check address
    try expectEqual(144 * 2, setter.item.toItemAddr() - s.pager.getBaseAddr());

    // set value
    try expectEqual(test_val_len, setter.item.getValue().len);
    @memset(setter.item.getValue(), 'A');

    s.finishPut(setter);

    // check flags
    try expectEqual(true, setter.item.slab_flags.is_present);
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

    s.putAndFinish(key01, test_val_len);
    s.putAndFinish(key02, test_val_len);

    // clear lock actions
    s.locker.actions.clearRetainingCapacity();

    const get1 = s.get(key01);
    try expectEqual(ItemGetter.Found, std.meta.activeTag(get1));
    try expectEqual(hash1, get1.Found.hash);

    const it1 = get1.Found.item;
    try std.testing.expectEqualStrings(key01, it1.getKey());
    try expectEqual(test_val_len, it1.getValue().len);
    try std.testing.expectEqualSlices(u8, &.{ 71, 71, 71, 71 }, it1.getValue()[0..4]);
    try expectEqual(2, it1.refcount.refcount);
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

    s.putAndFinish(key01, test_val_len);
    s.putAndFinish(key02, test_val_len);
    s.putAndFinish(key03, test_val_len);

    // clear lock actions
    s.locker.actions.clearRetainingCapacity();

    const setter4 = s.put(key04, test_val_len).?;

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

    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInBucket(hash2, &.{key02});
    try s.expectItemKeysInBucket(hash3, &.{key03});
    try s.expectItemKeysInBucket(hash4, &.{key04});
}

test "with eviction same hash" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, test_val_len);
    s.putAndFinish(key02, test_val_len);
    s.putAndFinish(key03, test_val_len);

    s.hash_func.putKeyHash(key04, hash1);

    // clear lock actions
    s.locker.actions.clearRetainingCapacity();

    const setter4 = s.put(key04, test_val_len).?;

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

    s.putAndFinish(key01, test_val_len);
    s.putAndFinish(key02, test_val_len);
    s.putAndFinish(key03, test_val_len);

    // clear lock actions
    s.locker.actions.clearRetainingCapacity();

    // key01 is locking
    s.locker.lock(s.locker.getSlot(hash1));

    const setter4 = s.put(key04, test_val_len).?;

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

    s.putAndFinish(key01, test_val_len);
    s.putAndFinish(key02, test_val_len);
    s.putAndFinish(key03, test_val_len);
    s.delete(key01);

    try s.expectItemKeysInSlab(SlabClass.init(1), &.{
        key02,
        key03,
    });

    try s.expectItemKeysInBucket(hash1, &.{key02});
    try s.expectItemKeysInBucket(hash2, &.{});
    try s.expectItemKeysInBucket(hash3, &.{key03});
}

test "put => get => delete => finish get" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, test_val_len);
    const getter1 = s.get(key01);

    s.delete(key01);

    // check item
    const it = getter1.Found.item;
    try expectEqual(1, it.refcount.refcount);
    try expectEqual(true, it.slab_flags.is_present);
    try expectEqual(false, it.item_flags.set_partial);

    // check items
    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{key01});

    s.finishGet(getter1.Found); // finish get

    // check items
    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{});

    // check item
    try expectEqual(0, it.refcount.refcount);
    try expectEqual(false, it.slab_flags.is_present);
    try expectEqual(false, it.item_flags.set_partial);
}

test "put => get => put finish" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    const setter1 = s.put(key01, test_val_len).?;

    const getter1 = s.get(key01);
    try expectEqual(ItemGetter.SetPartial, std.meta.activeTag(getter1));

    // check items
    try s.expectItemKeysInBucket(hash1, &.{key01});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{key01});

    // delete
    s.delete(key01);

    // check items
    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{key01});

    s.finishPut(setter1);

    // check items
    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{});
}

test "put => try evict directly" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, test_val_len);

    try expectEqual(true, s.tryEvictKey(key01));

    // check items
    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{});
}

test "get => try evict false" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, test_val_len);
    const getter1 = s.get(key01);

    try expectEqual(false, s.tryEvictKey(key01));

    // check items
    try s.expectItemKeysInBucket(hash1, &.{key01});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{key01});

    s.finishGet(getter1.Found);
}

test "get => delete => try evict false" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    s.putAndFinish(key01, test_val_len);

    const getter1 = s.get(key01);
    const it = getter1.Found.item;

    s.delete(key01); // do delete

    // try to evict
    try expectEqual(false, s.tryEvictKeyItem(it));

    // check items
    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{key01});

    s.finishGet(getter1.Found);

    // check items
    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInSlab(SlabClass.init(1), &.{});
}

test "start move page" {
    const s = try ServiceTest.init(.{ .num_pages = 1 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    s.putAndFinish(key01, test_val_len);
    s.putAndFinish(key02, test_val_len);

    try expectEqual(PageNum.init(0), s.startMovePage(slab1));
    try s.expectItemKeys(&.{ key02, key01 }, s.move_items.items);
}

test "start move page, 2 pages, with delete" {
    const s = try ServiceTest.init(.{ .num_pages = 2 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    s.putAndFinish(key01, test_val_len);
    s.putAndFinish(key02, test_val_len);
    s.putAndFinish(key03, test_val_len);
    s.putAndFinish(key04, test_val_len);

    s.delete(key02);

    try expectEqual(PageNum.init(0), s.startMovePage(slab1));
    try s.expectItemKeys(&.{ key03, key01 }, s.move_items.items);
}

test "item funcs" {
    const s = try ServiceTest.init(.{});
    defer s.deinit();

    _ = NewItemFuncs(@TypeOf(s.svc));
}
