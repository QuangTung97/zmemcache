const std = @import("std");
const types = @import("types.zig");
const zslab = @import("slab_class.zig");
const zlock = @import("item_lock.zig");
const zlru = @import("lru_service.zig");
const zpage = @import("page.zig");
const zutil = @import("zutil");
const zatomic = zutil.atomic;

const Allocator = std.mem.Allocator;
const CachePadding = types.CachePadding;
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

const ItemOpaquePtr = struct {
    const Self = @This();
    item: *anyopaque,

    fn init(item: *Item) Self {
        return .{
            .item = item,
        };
    }

    fn equal(self: Self, other: *Item) bool {
        const other_ptr: *anyopaque = other;
        return self.item == other_ptr;
    }
};

pub const ItemHash = struct {
    hash: HashValue,
    item: ItemOpaquePtr,
};

const ItemHashList = std.ArrayList(ItemHash);

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
            delete_list: *ItemHashList,
        ) ?PageNum,
        deleteMoveItem: fn (self: *T, item: ItemHash) void,
        removePageFrom: fn (self: *T, from_slab: SlabClass) void,
        addPageTo: fn (self: *T, to_slab: SlabClass, page: PageNum) void,
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
        .deleteMoveItem = T.deleteMoveItem,
        .removePageFrom = T.removePageFrom,
        .addPageTo = T.addPageTo,
    };
}

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

    fn deinit(self: *const Self) void {
        self.gpa.free(self.buckets);
    }

    fn getBucket(self: *const Self, hash: HashValue) *NullItem {
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

const LockCtx = struct {
    _slots: [2]?LockSlot,
    _slab: ?SlabClass,

    const Self = @This();

    fn init() Self {
        return .{
            ._slots = .{ null, null },
            ._slab = null,
        };
    }

    fn addSlot(self: *Self, slot: LockSlot) void {
        for (self._slots[0..]) |*x| {
            if (x.* == null) {
                x.* = slot;
                return;
            }
            std.debug.assert(!slot.nullEqual(x.*));
        }
        @panic("no slot to add");
    }

    fn removeSlot(self: *Self, slot: LockSlot) void {
        for (self._slots[0..]) |*x| {
            std.debug.assert(x.* != null);
            if (slot.nullEqual(x.*)) {
                x.* = null;
                return;
            }
        }
        @panic("no slot to remove");
    }

    fn containSlot(self: *Self, slot: LockSlot) bool {
        for (self._slots[0..]) |x| {
            if (slot.nullEqual(x)) {
                return true;
            }
        }
        return false;
    }

    fn addSlab(self: *Self, slab: SlabClass) void {
        std.debug.assert(self._slab == null);
        self._slab = slab;
    }

    fn removeSlab(self: *Self, slab: SlabClass) void {
        std.debug.assert(slab.nullEqual(self._slab));
        self._slab = null;
    }

    fn isSlabLocked(self: *Self, slab: SlabClass) bool {
        return slab.nullEqual(self._slab);
    }
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
        _slab_conf: *const SlabClassConfig,
        _pager: *zpage.GlobalPager,
        _locker: *L,
        _lru: *S,
        _table: HashTable,
        _max_evict_attempts: usize,

        // -----------------------------------------------------
        // Mutable Fields
        // -----------------------------------------------------
        _before_padding: CachePadding = undefined, // padding
        _mover_need_delete: zutil.WaitGroup,
        _last_cas: zatomic.Value(u64),
        _after_padding: CachePadding = undefined, // padding

        const Self = @This();

        pub const Config = struct {
            hash_size_log: u6,
            max_evict_attempts: usize = 5,
        };

        pub fn init(
            io: std.Io,
            gpa: std.mem.Allocator,
            hasher: *H,
            slab_conf: *const SlabClassConfig,
            pager: *zpage.GlobalPager,
            locker: *L,
            lru_svc: *S,
            conf: Config,
        ) !Self {
            const hash_table = try HashTable.init(gpa, conf.hash_size_log);
            zutil.runtimeAssert(std.math.isPowerOfTwo(hash_table.buckets.len));

            const lockTableSize = ItemLocks.getTableSize(locker).lock_slot;
            zutil.runtimeAssert(std.math.isPowerOfTwo(lockTableSize));

            zutil.runtimeAssert(lockTableSize <= hash_table.buckets.len);

            return .{
                ._hasher = hasher,
                ._slab_conf = slab_conf,
                ._pager = pager,
                ._locker = locker,
                ._lru = lru_svc,
                ._table = hash_table,
                ._max_evict_attempts = conf.max_evict_attempts,

                ._last_cas = .init(0),
                ._mover_need_delete = zutil.WaitGroup.init(io),
            };
        }

        pub fn deinit(self: *Self) void {
            self._table.deinit();
        }

        fn lockSlot(self: *Self, ctx: *LockCtx, slot: LockSlot) void {
            ItemLocks.lock(self._locker, slot);
            ctx.addSlot(slot);
        }

        fn tryLockSlot(self: *Self, ctx: *LockCtx, slot: LockSlot) bool {
            const ok = ItemLocks.tryLock(self._locker, slot);
            if (!ok) {
                return false;
            }
            ctx.addSlot(slot);
            return true;
        }

        fn unlockSlot(self: *Self, ctx: *LockCtx, slot: LockSlot) void {
            ctx.removeSlot(slot);
            ItemLocks.unlock(self._locker, slot);
        }

        fn lockSlab(self: *Self, ctx: *LockCtx, slab: SlabClass) void {
            LruFuncs.lockSlab(self._lru, slab);
            ctx.addSlab(slab);
        }

        fn unlockSlab(self: *Self, ctx: *LockCtx, slab: SlabClass) void {
            LruFuncs.unlockSlab(self._lru, slab);
            ctx.removeSlab(slab);
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
            var ctx = LockCtx.init();
            self.lockSlot(&ctx, lock_slot);
            defer self.unlockSlot(&ctx, lock_slot);

            // delete previous item
            const prev_pitem = self.findItemPointerWithKey(&ctx, hash_value, key);
            const null_prev_item = prev_pitem.*;
            if (null_prev_item) |prev_item| {
                self.doDeleteItem(&ctx, hash_value, prev_item, prev_pitem);
            }

            // lock slab
            self.lockSlab(&ctx, slab);
            defer self.unlockSlab(&ctx, slab);

            // try to get free item
            const null_item = self.getFreeItem(&ctx, slab_size, lock_slot);
            const it = null_item orelse return null;

            // init item
            const cas_num = self.nextCasNum();
            it.* = Item.init(slab, key.len, value_len, cas_num);
            it.item_flags.set_partial = true;
            it.refcount.refcount += 1;

            // copy the key
            @memcpy(it.getKey(), key);

            // put to lru list
            self.assertSlabLocked(&ctx, slab);
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

            // lock item
            var ctx = LockCtx.init();
            self.lockSlot(&ctx, slot);
            defer self.unlockSlot(&ctx, slot);

            setter.item.item_flags.set_partial = false;
            self.decreaseRefcountAndDelete(&ctx, setter.hash, setter.item);
        }

        pub fn get(self: *Self, key: String) ItemGetter {
            // compute hash value & lock slot
            const hash_value = HashFunc.hashKey(self._hasher, key);
            const lock_slot = ItemLocks.getSlot(self._locker, hash_value);

            // lock item
            var ctx = LockCtx.init();
            self.lockSlot(&ctx, lock_slot);
            defer self.unlockSlot(&ctx, lock_slot);

            const pitem = self.findItemPointerWithKey(&ctx, hash_value, key);
            const null_item = pitem.*;
            const it = null_item orelse return .{ .NotFound = .{} };

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
            var ctx = LockCtx.init();
            self.lockSlot(&ctx, lock_slot);
            defer self.unlockSlot(&ctx, lock_slot);

            self.decreaseRefcountAndDelete(&ctx, found.hash, found.item);
        }

        pub fn delete(self: *Self, key: String) void {
            // compute hash value & lock slot
            const hash_value = HashFunc.hashKey(self._hasher, key);
            const lock_slot = ItemLocks.getSlot(self._locker, hash_value);

            // lock item
            var ctx = LockCtx.init();
            self.lockSlot(&ctx, lock_slot);
            defer self.unlockSlot(&ctx, lock_slot);

            const pitem = self.findItemPointerWithKey(&ctx, hash_value, key);
            const null_item = pitem.*;
            const it = null_item orelse return;

            self.doDeleteItem(&ctx, hash_value, it, pitem);
        }

        const MovePageIterateCtx = struct {
            self: *Self,
            gpa: Allocator,
            slab: SlabClass,
            delete_list: *ItemHashList,
            fn yield(ctx: *@This(), item: *Item) bool {
                if (item.slab_flags.is_present) {
                    const hash_val = HashFunc.hashKey(ctx.self._hasher, item.getKey());
                    const item_hash = ItemHash{
                        .hash = hash_val,
                        .item = .init(item),
                    };
                    ctx.delete_list.append(ctx.gpa, item_hash) catch unreachable;
                } else {
                    LruFuncs.deleteFreeItem(ctx.self._lru, ctx.slab, item);
                }
                return true;
            }
        };

        pub fn startMovePage(
            self: *Self,
            from_slab: SlabClass,
            gpa: Allocator,
            delete_list: *ItemHashList,
        ) ?PageNum {
            // lock the slab
            var lock_ctx = LockCtx.init();
            self.lockSlab(&lock_ctx, from_slab);
            defer self.unlockSlab(&lock_ctx, from_slab);

            const null_page_num = LruFuncs.popPage(self._lru, from_slab);
            const page_num = null_page_num orelse return null;

            const item_size = self._slab_conf.getItemSizeOfSlab(from_slab);
            const moving_page = self._pager.getPageOfPageNum(page_num);

            // clear delete_list
            delete_list.clearRetainingCapacity();

            // iterate through items of moving page
            var iterate_ctx = MovePageIterateCtx{
                .self = self,
                .gpa = gpa,
                .slab = from_slab,
                .delete_list = delete_list,
            };
            self._pager.iterateItemsOfPage(
                moving_page,
                item_size,
                &iterate_ctx,
                MovePageIterateCtx.yield,
            );

            LruFuncs.setMovingPage(self._lru, from_slab, page_num);

            const num_delete: u64 = delete_list.items.len;
            self._mover_need_delete.add(num_delete);

            return page_num;
        }

        pub fn deleteMoveItem(self: *Self, item_hash: ItemHash) void {
            const hash_value = item_hash.hash;
            const lock_slot = ItemLocks.getSlot(self._locker, hash_value);

            // lock item
            var ctx = LockCtx.init();
            self.lockSlot(&ctx, lock_slot);
            defer self.unlockSlot(&ctx, lock_slot);

            const pitem = self.findItemPointerInBucket(&ctx, hash_value, item_hash.item);
            const null_item = pitem.*;
            const item = null_item orelse return;

            std.debug.assert(item.slab_flags.is_present);
            self.doDeleteItem(&ctx, hash_value, item, pitem);
        }

        pub fn removePageFrom(self: *Self, from_slab: SlabClass) void {
            // wait for zero deleting items
            self._mover_need_delete.wait();

            // lock the slab
            var ctx = LockCtx.init();
            self.lockSlab(&ctx, from_slab);
            defer self.unlockSlab(&ctx, from_slab);

            std.debug.assert(self._mover_need_delete.getCounter() == 0);

            const page_num = LruFuncs.getMovingPage(self._lru, from_slab).?;

            // clear moving page
            self.assertSlabLocked(&ctx, from_slab);
            LruFuncs.setMovingPage(self._lru, from_slab, null);
            self._pager.updatePageSlab(page_num, null);
        }

        pub fn addPageTo(self: *Self, to_slab: SlabClass, page_num: PageNum) void {
            // lock the slab
            var ctx = LockCtx.init();
            self.lockSlab(&ctx, to_slab);
            defer self.unlockSlab(&ctx, to_slab);

            self._pager.updatePageSlab(page_num, to_slab);

            // add free items of new page to this slab
            const page = self._pager.getPageOfPageNum(page_num);
            const item_size = self._slab_conf.getItemSizeOfSlab(to_slab);
            self.addFreePageToSlab(&ctx, to_slab, item_size, page);
        }

        fn getFreeItem(self: *Self, ctx: *LockCtx, slab: SlabSize, lock_slot: LockSlot) ?*Item {
            self.assertSlabLocked(ctx, slab.slab_class);

            const null_item1 = LruFuncs.getFreeItem(self._lru, slab.slab_class);
            if (null_item1) |it| {
                return it;
            }

            // try to get new page from page pool
            self.getNewPageFromPool(ctx, slab);

            const null_item2 = LruFuncs.getFreeItem(self._lru, slab.slab_class);
            if (null_item2) |it| {
                return it;
            }

            // evict from lru if no free item exists
            self.evictFromLru(ctx, slab.slab_class, lock_slot);

            return LruFuncs.getFreeItem(self._lru, slab.slab_class);
        }

        fn getNewPageFromPool(self: *Self, ctx: *LockCtx, slab: SlabSize) void {
            self.assertSlabLocked(ctx, slab.slab_class);

            const null_page = self._pager.allocPage(slab.slab_class);
            const page = null_page orelse return;

            self.addFreePageToSlab(ctx, slab.slab_class, slab.item_size, page);
        }

        fn addFreePageToSlab(
            self: *Self,
            lock_ctx: *LockCtx,
            slab_class: SlabClass,
            item_size: usize,
            page: zpage.Page,
        ) void {
            self.assertSlabLocked(lock_ctx, slab_class);

            // iterate and add to free item list
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
                .slab = slab_class,
            };
            self._pager.iterateItemsOfPage(
                page,
                item_size,
                &ctx,
                IterateCtx.yield,
            );

            // add page to slab
            const page_num = self._pager.getPageNumOfPage(page);
            LruFuncs.pushPage(self._lru, slab_class, page_num);
        }

        fn evictFromLru(
            self: *Self,
            lock_ctx: *LockCtx,
            slab: SlabClass,
            current_slot: LockSlot,
        ) void {
            self.assertSlabLocked(lock_ctx, slab);

            var ctx = struct {
                self: *Self,
                lock_ctx: *LockCtx,
                current_slot: LockSlot,
                num_attempts: usize,
                pub fn yield(ctx: *@This(), item: *Item) bool {
                    const ok = ctx.self.tryToEvictItem(
                        ctx.lock_ctx,
                        item,
                        ctx.current_slot,
                    );
                    if (ok) {
                        return false;
                    }

                    ctx.num_attempts += 1;
                    return ctx.num_attempts < ctx.self._max_evict_attempts;
                }
            }{
                .self = self,
                .lock_ctx = lock_ctx,
                .current_slot = current_slot,
                .num_attempts = 0,
            };

            // iterate through lru list
            LruFuncs.iterateItems(
                self._lru,
                slab,
                ItemIter.init(&ctx),
            );

            std.debug.assert(ctx.num_attempts <= self._max_evict_attempts);
        }

        fn tryToEvictItem(self: *Self, ctx: *LockCtx, evicted_item: *Item, current_slot: LockSlot) bool {
            const slab = evicted_item.slab;
            self.assertSlabLocked(ctx, slab);

            const new_hash = HashFunc.hashKey(self._hasher, evicted_item.getKey());
            const new_slot = ItemLocks.getSlot(self._locker, new_hash);

            // do not lock if lock slot the same
            if (current_slot.lock_slot == new_slot.lock_slot) {
                return self.checkEvictCondAndDeleteItem(ctx, new_hash, evicted_item);
            }

            // try to lock the evicted item
            const locked = self.tryLockSlot(ctx, new_slot);
            if (!locked) {
                return false;
            }
            defer self.unlockSlot(ctx, new_slot);

            return self.checkEvictCondAndDeleteItem(ctx, new_hash, evicted_item);
        }

        fn checkEvictCondAndDeleteItem(self: *Self, ctx: *LockCtx, hash: HashValue, deleted_item: *Item) bool {
            self.assertItemLocked(ctx, hash);

            if (deleted_item.refcount.refcount != 1) {
                return false;
            }

            const pitem = self.findItemPointerInBucket(ctx, hash, .init(deleted_item));
            const null_item = pitem.*;
            if (null_item == null) {
                return false;
            }

            self.doDeleteItem(ctx, hash, deleted_item, pitem);
            return true;
        }

        fn doDeleteItem(self: *Self, ctx: *LockCtx, hash: HashValue, deleted_item: *Item, pitem: *NullItem) void {
            self.assertItemLocked(ctx, hash);

            // unlink from bucket
            const next = deleted_item.hash_next;
            pitem.* = next;

            // try to remove from lru
            self.decreaseRefcountAndDelete(ctx, hash, deleted_item);
        }

        fn decreaseRefcountAndDelete(self: *Self, ctx: *LockCtx, hash: HashValue, deleted_item: *Item) void {
            self.assertItemLocked(ctx, hash);

            deleted_item.refcount.refcount -= 1;
            if (deleted_item.refcount.refcount > 0) {
                return;
            }

            const slab = deleted_item.slab;
            if (ctx.isSlabLocked(slab)) {
                // if slab already locked
                self.doMoveItemFromLruToFree(ctx, deleted_item);
            } else {
                // lock then delete
                self.lockSlab(ctx, slab);
                defer self.unlockSlab(ctx, slab);

                self.doMoveItemFromLruToFree(ctx, deleted_item);
            }
        }

        fn doMoveItemFromLruToFree(self: *Self, ctx: *LockCtx, deleted_item: *Item) void {
            const slab = deleted_item.slab;
            self.assertSlabLocked(ctx, slab);

            // clear present flag
            deleted_item.slab_flags.is_present = false;
            LruFuncs.deleteItem(self._lru, slab, deleted_item);

            const page_num = self._pager.getPageNumOfItem(deleted_item);
            const move_page = LruFuncs.getMovingPage(self._lru, slab);

            if (page_num.nullEqual(move_page)) {
                self._mover_need_delete.done();
            } else {
                LruFuncs.putFreeItem(self._lru, slab, deleted_item);
            }
        }

        fn findItemPointerInBucket(self: *Self, ctx: *LockCtx, hash: HashValue, find_item: ItemOpaquePtr) *NullItem {
            self.assertItemLocked(ctx, hash);

            var pitem = self._table.getBucket(hash);
            while (pitem.*) |it| {
                if (find_item.equal(it)) {
                    return pitem;
                }
                pitem = &it.hash_next;
            }
            return pitem;
        }

        fn findItemPointerWithKey(self: *Self, ctx: *LockCtx, hash: HashValue, key: String) *NullItem {
            self.assertItemLocked(ctx, hash);

            var pitem = self._table.getBucket(hash);
            while (pitem.*) |it| {
                if (std.mem.eql(u8, it.getKey(), key)) {
                    return pitem;
                }
                pitem = &it.hash_next;
            }
            return pitem;
        }

        fn assertItemLocked(self: *Self, ctx: *LockCtx, hash: HashValue) void {
            const slot = ItemLocks.getSlot(self._locker, hash);
            std.debug.assert(ctx.containSlot(slot));
        }

        fn assertSlabLocked(_: *Self, ctx: *LockCtx, slab: SlabClass) void {
            std.debug.assert(ctx.isSlabLocked(slab));
        }

        fn nextCasNum(self: *Self) CasNum {
            const num = self._last_cas.fetchAdd(1);
            return CasNum{ .cas = num + 1 };
        }
    };
}

// ===========================================================================
// Testing
// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "lock context" {
    var ctx = LockCtx.init();

    const slot1 = LockSlot.init(11);
    const slot2 = LockSlot.init(12);

    try expectEqual(false, ctx.containSlot(slot1));
    try expectEqual(false, ctx.containSlot(slot2));

    ctx.addSlot(slot1);
    try expectEqual(true, ctx.containSlot(slot1));
    try expectEqual(false, ctx.containSlot(slot2));

    ctx.removeSlot(slot1);
    try expectEqual(false, ctx.containSlot(slot1));
    try expectEqual(false, ctx.containSlot(slot2));
}

test "lock context, nested slots" {
    var ctx = LockCtx.init();

    const slot1 = LockSlot.init(11);
    const slot2 = LockSlot.init(12);

    ctx.addSlot(slot1);
    ctx.addSlot(slot2);
    try expectEqual(true, ctx.containSlot(slot1));
    try expectEqual(true, ctx.containSlot(slot2));

    ctx.removeSlot(slot2);
    ctx.removeSlot(slot1);
    try expectEqual(false, ctx.containSlot(slot1));
    try expectEqual(false, ctx.containSlot(slot2));
}

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

const key05 = "key05";
const hash5 = HashValue.init(25);

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
    pager: *zpage.GlobalPager,
    locker: zlock.FakeItemLocks,
    lru_svc: zlru.FakeLruService,
    svc: ServiceType,

    move_items: ItemHashList,

    const Config = struct {
        num_pages: u64 = 3,
        max_evict_attempts: usize = 5,
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
            io,
            gpa,
            &s.hash_func,
            &s.slab_conf,
            s.pager,
            &s.locker,
            &s.lru_svc,
            .{
                .hash_size_log = 5, // 32 buckets
                .max_evict_attempts = conf.max_evict_attempts,
            },
        );

        s.move_items = ItemHashList.empty;

        // setup hash values
        s.hash_func.putKeyHash(key01, hash1);
        s.hash_func.putKeyHash(key02, hash2);
        s.hash_func.putKeyHash(key03, hash3);
        s.hash_func.putKeyHash(key04, hash4);
        s.hash_func.putKeyHash(key05, hash5);

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

        // lock item
        var ctx = LockCtx.init();
        self.svc.lockSlot(&ctx, lock_slot);
        defer self.svc.unlockSlot(&ctx, lock_slot);

        const pitem = self.svc.findItemPointerWithKey(&ctx, hash_value, key);
        const null_item = pitem.*;
        const item = null_item.?;
        const slab = item.slab;

        self.svc.lockSlab(&ctx, slab);
        defer self.svc.unlockSlab(&ctx, slab);

        return self.svc.tryToEvictItem(&ctx, item, lock_slot);
    }

    fn tryEvictKeyItem(self: *Self, item: *Item) bool {
        // compute hash value & lock slot
        const hash_value = HashFunc.hashKey(self.svc._hasher, item.getKey());
        const lock_slot = ItemLocks.getSlot(self.svc._locker, hash_value);

        // lock item
        var ctx = LockCtx.init();
        self.svc.lockSlot(&ctx, lock_slot);
        defer self.svc.unlockSlot(&ctx, lock_slot);

        // lock slab
        const slab = item.slab;
        self.svc.lockSlab(&ctx, slab);
        defer self.svc.unlockSlab(&ctx, slab);

        return self.svc.tryToEvictItem(&ctx, item, lock_slot);
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

    fn deleteMoveItem(self: *Self, index: usize) void {
        self.svc.deleteMoveItem(self.move_items.items[index]);
        self.checkInvariant();
    }

    fn removePageFrom(self: *Self, slab: SlabClass) void {
        self.svc.removePageFrom(slab);
        self.checkInvariant();
    }

    fn addPageTo(self: *Self, slab: SlabClass, page_num: PageNum) void {
        self.svc.addPageTo(slab, page_num);
        self.checkInvariant();
    }

    fn checkInvariant(self: *Self) void {
        const gpa = std.testing.allocator;

        var inuse_pages = std.AutoHashMap(PageNum, SlabClass).init(gpa);
        defer inuse_pages.deinit();

        var slab_iter = self.slab_conf.getAllSlabClasses();
        while (slab_iter.next()) |slab| {
            const null_page_list = self.lru_svc.page_queue_map.get(slab.slab_class);
            const page_list = null_page_list orelse continue;

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
                std.debug.assert(item.refcount.refcount > 0);

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

                // free item must not in moving page
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

    fn expectItemHashKeys(self: *Self, expected_keys: []const String, items: []ItemHash) !void {
        var item_keys = std.ArrayList(String).empty;
        defer item_keys.deinit(self.gpa);

        for (items) |it| {
            const item: *Item = @ptrCast(@alignCast(it.item.item));
            try item_keys.append(self.gpa, item.getKey());
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

test "item funcs" {
    const s = try ServiceTest.init(.{});
    defer s.deinit();

    _ = NewItemFuncs(@TypeOf(s.svc));
}

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
    try s.expectItemHashKeys(&.{ key02, key01 }, s.move_items.items);
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

    // do move
    const move_page = PageNum.init(0);
    try expectEqual(move_page, s.startMovePage(slab1));
    try s.expectItemHashKeys(&.{ key03, key01 }, s.move_items.items);
    try s.expectItemKeysInSlab(slab1, &.{ key01, key03, key04 });
    try expectEqual(2, s.svc._mover_need_delete.getCounter());

    // delete mover key03
    s.deleteMoveItem(0);

    try s.expectItemKeysInBucket(hash3, &.{});
    try s.expectItemKeysInSlab(slab1, &.{ key01, key04 });
    try expectEqual(1, s.svc._mover_need_delete.getCounter());

    // delete mover key01
    s.deleteMoveItem(1);

    try s.expectItemKeysInBucket(hash1, &.{});
    try s.expectItemKeysInSlab(slab1, &.{key04});
    try expectEqual(0, s.svc._mover_need_delete.getCounter());

    // remove from source slab
    s.removePageFrom(slab1);
    try expectEqual(null, s.lru_svc.getMovingPage(slab1));
    try expectEqual(null, s.pager.getSlabClass(move_page));

    // add to new slab
    const slab2 = SlabClass.init(2);
    s.addPageTo(slab2, move_page);
    try expectEqual(slab2, s.pager.getSlabClass(move_page));
}

test "move page, delete and delete move item" {
    const s = try ServiceTest.init(.{ .num_pages = 2 });
    defer s.deinit();

    const slab1 = SlabClass.init(1);

    s.putAndFinish(key01, test_val_len);
    s.putAndFinish(key02, test_val_len);
    s.putAndFinish(key03, test_val_len);
    s.putAndFinish(key04, test_val_len);

    // do move
    const move_page = PageNum.init(0);
    try expectEqual(move_page, s.startMovePage(slab1));
    try s.expectItemHashKeys(&.{ key03, key02, key01 }, s.move_items.items);
    try s.expectItemKeysInSlab(slab1, &.{ key01, key02, key03, key04 });
    try expectEqual(3, s.svc._mover_need_delete.getCounter());

    // delete
    s.delete(key03);

    // delete move item
    s.deleteMoveItem(0);

    try s.expectItemKeysInSlab(slab1, &.{ key01, key02, key04 });
    try expectEqual(2, s.svc._mover_need_delete.getCounter());
}

test "put with max evict attempt 3, evict ok" {
    const s = try ServiceTest.init(.{ .num_pages = 2, .max_evict_attempts = 3 });
    defer s.deinit();

    const value_len = 210 - key01.len - Item.Size;

    s.putAndFinish(key01, value_len);
    s.putAndFinish(key02, value_len);
    s.putAndFinish(key03, value_len);
    s.putAndFinish(key04, value_len);

    const slab2 = SlabClass.init(2);
    try s.expectItemKeysInSlab(slab2, &.{ key01, key02, key03, key04 });

    _ = s.get(key01);
    _ = s.get(key02);

    s.putAndFinish(key05, value_len);
    try s.expectItemKeysInSlab(slab2, &.{ key01, key02, key04, key05 });
}

test "put with max evict attempt 3, not success" {
    const s = try ServiceTest.init(.{ .num_pages = 2, .max_evict_attempts = 3 });
    defer s.deinit();

    const value_len = 210 - key01.len - Item.Size;

    s.putAndFinish(key01, value_len);
    s.putAndFinish(key02, value_len);
    s.putAndFinish(key03, value_len);
    s.putAndFinish(key04, value_len);

    const slab2 = SlabClass.init(2);
    try s.expectItemKeysInSlab(slab2, &.{ key01, key02, key03, key04 });

    _ = s.get(key01);
    _ = s.get(key02);
    _ = s.get(key03);

    // put fail
    const setter = s.put(key05, value_len);
    try expectEqual(null, setter);
    try s.expectItemKeysInSlab(slab2, &.{ key01, key02, key03, key04 });
}

test "put and then update value" {
    const s = try ServiceTest.init(.{ .num_pages = 2 });
    defer s.deinit();

    const setter1 = s.put(key01, 4).?;
    @memcpy(setter1.item.getValue(), "abcd");
    s.finishPut(setter1);

    const setter2 = s.put(key01, 5).?;
    @memcpy(setter2.item.getValue(), "123xy");
    s.finishPut(setter2);

    const slab0 = SlabClass.init(0);
    try s.expectItemKeysInBucket(hash1, &.{key01});
    try s.expectItemKeysInSlab(slab0, &.{key01});

    // get
    const getter1 = s.get(key01);
    try std.testing.expectEqualStrings("123xy", getter1.Found.item.getValue());
    s.finishGet(getter1.Found);
}

test "put and then update value, different slab size" {
    const s = try ServiceTest.init(.{ .num_pages = 2 });
    defer s.deinit();

    // slab 0
    const setter1 = s.put(key01, 4).?;
    s.finishPut(setter1);

    // slab 1
    const setter2 = s.put(key01, test_val_len).?;
    s.finishPut(setter2);

    const getter1 = s.get(key01);
    try expectEqual(test_val_len, getter1.Found.item.getValue().len);
}
