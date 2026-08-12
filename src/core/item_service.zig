const std = @import("std");
const types = @import("types.zig");
const lock_manager = @import("lock_manager.zig");
const lru_service = @import("lru_service.zig");
const zpage = @import("page.zig");

const Allocator = std.mem.Allocator;
const HashValue = types.HashValue;
const Item = types.Item;

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
    item: *Item,
};

pub const ItemGetter = union(enum) {
    Found: struct {},
    NotFound: struct {},
};

pub fn ItemService(H: type, L: type, S: type) type {
    return struct {
        hash: types.HashFunc(H),
        locker: lock_manager.ILockManager(L),
        lru_svc: lru_service.ILruService(S),

        pager: *zpage.GlobalPager,
        table: HashTable,

        const Self = @This();

        pub fn init(
            gpa: std.mem.Allocator,
            hash_func: types.HashFunc(H),
            locker: lock_manager.ILockManager(L),
            lru_svc: lru_service.ILruService(S),
            pager: *zpage.GlobalPager,
            hash_size_log: u6,
        ) !Self {
            const hash_table = try HashTable.init(gpa, hash_size_log);

            return .{
                .hash = hash_func,
                .locker = locker,
                .lru_svc = lru_svc,
                .pager = pager,
                .table = hash_table,
            };
        }

        pub fn deinit(self: *Self) void {
            self.table.deinit();
        }

        pub fn put(self: *Self, key: []const u8) ?ItemSetter {
            const hash_value = self.hash.hashKey(key);
            const lock_slot = self.locker.getSlot(hash_value);

            self.locker.lock(lock_slot);
            defer self.locker.unlock(lock_slot);

            const item_size = 128; // TODO
            const slab = types.SlabClass{ .slab = 11 }; // TODO

            self.lru_svc.lockSlab(slab);
            defer self.lru_svc.unlockSlab(slab); // TODO

            // TODO get from free list first

            const null_page = self.pager.allocPage(slab);
            const page = if (null_page) |p| p else {
                return null;
            };

            var item_iter = zpage.iterateItemsOfPage(page, item_size);
            while (item_iter.next()) |it| {
                self.lru_svc.putFreeItem(slab, it);
            }

            const null_item = self.lru_svc.getFreeItem(slab);
            const result_item = if (null_item) |it| it else {
                return null;
            };

            return .{
                .hash = hash_value,
                .item = result_item,
            };
        }

        pub fn finishPut(_: *Self, _: ItemSetter) void {}

        pub fn get(_: *Self, _: []const u8) ItemGetter {
            return .{
                .NotFound = .{},
            };
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
        lock_manager.FakeLockManager,
        lru_service.FakeLruService,
    );
    const Self = @This();

    gpa: Allocator,
    hash_func: types.FakeHashFunc,
    pager: zpage.GlobalPager,
    locker: lock_manager.FakeLockManager,
    lru_svc: lru_service.FakeLruService,
    svc: ServiceType,

    fn init() !*Self {
        const io = std.testing.io;
        const gpa = std.testing.allocator;

        const s = try gpa.create(Self);

        s.gpa = gpa;
        s.hash_func = types.FakeHashFunc.init(gpa);
        s.pager = try zpage.GlobalPager.init(io, gpa, 3);
        s.locker = lock_manager.FakeLockManager.init(gpa);
        s.lru_svc = lru_service.FakeLruService.init(gpa);

        s.svc = try ServiceType.init(
            gpa,
            types.HashFunc(types.FakeHashFunc).init(&s.hash_func),
            lock_manager.ILockManager(lock_manager.FakeLockManager).init(&s.locker),
            lru_service.ILruService(lru_service.FakeLruService).init(&s.lru_svc),
            &s.pager,
            5,
        );

        return s;
    }

    fn deinit(self: *Self) void {
        self.svc.deinit();
        self.lru_svc.deinit();
        self.locker.deinit();
        self.pager.deinit();
        self.hash_func.deinit();
        self.gpa.destroy(self);
    }
};

test "item service" {
    const s = try ServiceTest.init();
    defer s.deinit();

    const key01 = "key01";
    const hash1 = HashValue.init(21);

    // setup hash values
    s.hash_func.addKeyHash(key01, hash1);

    const setter1 = s.svc.put(key01);
    try std.testing.expect(setter1 == null); // TODO not null

    // const g1 = s.svc.get(key01);
    // try expectEqual(null, g1);
}
