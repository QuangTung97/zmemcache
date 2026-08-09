const std = @import("std");
const types = @import("types.zig");
const lock_manager = @import("lock_manager.zig");
const lru_service = @import("lru_service.zig");
const zpage = @import("page.zig");

const HashTable = struct {
    gpa: std.mem.Allocator,
    buckets: []?*types.Item,
    mask: u64,

    const Self = @This();

    fn init(gpa: std.mem.Allocator, hash_size_shift: u6) !Self {
        const table_size = @as(u64, 1) << hash_size_shift;
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

pub fn NewItemService(H: type, L: type, S: type) type {
    return struct {
        private: struct {
            hash: types.HashFunc(H),
            locker: lock_manager.ILockManager(L),
            slab_svc: lru_service.ILruService(S),

            pager: *zpage.GlobalPager,
            table: HashTable,
            table_mask: u64,
        },

        const Self = @This();

        pub fn init(
            gpa: std.mem.Allocator,
            hash_func: types.HashFunc[H],
            locker: lock_manager.ILockManager(L),
            slab_svc: lru_service.ILruService(S),
            pager: *zpage.GlobalPager,
            hash_size_shift: u64,
        ) Self {
            return .{
                .private = .{
                    .hash = hash_func,
                    .locker = locker,
                    .slab_svc = slab_svc,
                    .pager = pager,
                    .table = .init(gpa, hash_size_shift),
                },
            };
        }
    };
}

const expectEqual = std.testing.expectEqual;

test "hash table" {
    try expectEqual(8 * 5, @sizeOf(HashTable));

    const h = try HashTable.init(std.testing.allocator, 5);
    defer h.deinit();

    try expectEqual(0b11111, h.mask);
}
