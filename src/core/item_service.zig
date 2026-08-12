const std = @import("std");
const types = @import("types.zig");
const lock_manager = @import("lock_manager.zig");
const lru_service = @import("lru_service.zig");
const zpage = @import("page.zig");

const Allocator = std.mem.Allocator;

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

pub fn ItemService(H: type, L: type, S: type) type {
    return struct {
        private: struct {
            hash: types.HashFunc(H),
            locker: lock_manager.ILockManager(L),
            slab_svc: lru_service.ILruService(S),

            pager: *zpage.GlobalPager,
            table: HashTable,
        },

        const Self = @This();

        pub fn init(
            gpa: std.mem.Allocator,
            hash_func: types.HashFunc(H),
            locker: lock_manager.ILockManager(L),
            slab_svc: lru_service.ILruService(S),
            pager: *zpage.GlobalPager,
            hash_size_log: u6,
        ) !Self {
            const hash_table = try HashTable.init(gpa, hash_size_log);

            return .{
                .private = .{
                    .hash = hash_func,
                    .locker = locker,
                    .slab_svc = slab_svc,
                    .pager = pager,
                    .table = hash_table,
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.private.table.deinit();
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

    fn init(io: std.Io, gpa: Allocator) !*Self {
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
        self.pager.deinit();
        self.hash_func.deinit();
        self.gpa.destroy(self);
    }
};

test "item service" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const s = try ServiceTest.init(io, gpa);
    defer s.deinit();
}
