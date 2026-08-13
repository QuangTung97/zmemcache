const std = @import("std");
const types = @import("types.zig");
const zslab = @import("slab_class.zig");
const zlock = @import("item_lock.zig");
const zlru = @import("lru_service.zig");
const zpage = @import("page.zig");

const Allocator = std.mem.Allocator;
const HashValue = types.HashValue;
const Item = types.Item;
const SlabClass = types.SlabClass;
const CasNum = types.CasNum;
const SlabClassConfig = zslab.SlabClassConfig;

const HashTable = struct {
    gpa: std.mem.Allocator,
    buckets: []?*types.Item,
    mask: u64,

    const Self = @This();

    fn init(gpa: std.mem.Allocator, hash_size_log: u6) !Self {
        const table_size = @as(u64, 1) << hash_size_log;
        const buckets = try gpa.alloc(?*types.Item, table_size);
        return .{
            .gpa = gpa,
            .buckets = buckets,
            .mask = table_size - 1,
        };
    }

    fn deinit(self: Self) void {
        self.gpa.free(self.buckets);
    }
};

pub const ItemSetter = struct {
    hash: HashValue,
    slab: SlabClass,
    item: *Item,
};

pub const ItemGetter = union(enum) {
    Found: struct {},
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

        pub fn put(self: *Self, key: []const u8, value_len: usize) ?ItemSetter {
            // compute hash value & lock slot
            const hash_value = HashFunc.hashKey(self._hasher, key);
            const lock_slot = ItemLocks.getSlot(self._locker, hash_value);

            // compute slab class & item size
            const raw_item_size = Item.computeItemSize(key.len, value_len);
            const slab_size = self._slab_conf.getItemSlab(raw_item_size);
            const slab = slab_size.slab_class;
            const item_size = slab_size.item_size;

            // lock with item locks
            ItemLocks.lock(self._locker, lock_slot);
            defer ItemLocks.unlock(self._locker, lock_slot);

            // lock slab
            LruFuncs.lockSlab(self._lru, slab);
            defer LruFuncs.unlockSlab(self._lru, slab);

            const null_item = self.getFreeItem(slab, item_size);
            if (null_item) |it| {
                // init item
                const cas_num = self.nextCasNum();
                it.* = Item.init(key.len, value_len, cas_num);
                it.item_flags.set_partial = true;

                // copy the key
                @memcpy(it.getKey(), key);

                return .{
                    .hash = hash_value,
                    .slab = slab,
                    .item = it,
                };
            } else {
                return null;
            }
        }

        pub fn finishPut(_: *Self, _: ItemSetter) void {}

        pub fn get(_: *Self, _: []const u8) ItemGetter {
            return .{
                .NotFound = .{},
            };
        }

        fn getFreeItem(self: *Self, slab: SlabClass, item_size: usize) ?*Item {
            const null_item = LruFuncs.getFreeItem(self._lru, slab);
            if (null_item) |it| {
                return it;
            }

            // try to get new page from page pool
            self.getNewPageFromPool(slab, item_size);

            const new_null_item = LruFuncs.getFreeItem(self._lru, slab);
            if (new_null_item) |it| {
                return it;
            }

            return null;
        }

        fn getNewPageFromPool(self: *Self, slab: SlabClass, item_size: usize) void {
            std.debug.assert(LruFuncs.isSlabLocked(self._lru, slab));

            const null_page = self._pager.allocPage(slab);
            const page = if (null_page) |p| p else {
                return;
            };

            const IterateCtx = struct {
                self: *Self,
                slab: types.SlabClass,
                fn yield(ctx: *@This(), item: *Item) bool {
                    LruFuncs.putFreeItem(ctx.self._lru, ctx.slab, item);
                    return true;
                }
            };
            var ctx = IterateCtx{
                .self = self,
                .slab = slab,
            };
            self._pager.iterateItemsOfPage(
                page,
                item_size,
                &ctx,
                IterateCtx.yield,
            );

            // TODO add page to the slab
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

    const h = try HashTable.init(std.testing.allocator, 5);
    defer h.deinit();

    try expectEqual(0b11111, h.mask);
}

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

    fn init() !*Self {
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
        s.pager = try zpage.GlobalPager.init(io, gpa, 20,3);
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
};

test "basic" {
    const svc = try ServiceTest.init();
    defer svc.deinit();

    const key01 = "key01";
    const hash1 = HashValue.init(21);

    // setup hash values
    svc.hash_func.addKeyHash(key01, hash1);

    // put1
    const setter1 = svc.svc.put(key01, 46);
    try std.testing.expect(setter1 != null);
    if (setter1) |s| {
        try expectEqual(hash1, s.hash);
        try expectEqual(SlabClass.init(1), s.slab);
        try expectEqual(144, svc.slab_conf.getSlabSize(s.slab));

        // check item key
        try expectEqual(Item.Size + key01.len + 46, s.item.getItemSize());
        try std.testing.expectEqualStrings(key01, s.item.getKey());

        // check flags
        try expectEqual(true, s.item.slab_flags.is_present);
        try expectEqual(false, s.item.item_flags.is_deleting);
        try expectEqual(true, s.item.item_flags.set_partial);
        try expectEqual(1, s.item.refcount.refcount);
    }
}
