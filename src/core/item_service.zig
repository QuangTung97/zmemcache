const std = @import("std");
const types = @import("types.zig");
const lock_manager = @import("lock_manager.zig");
const slab_service = @import("slab_service.zig");

const HashTable = struct {
    buckets: []?*types.Item,
};

pub fn ItemService(H: type, L: type, S: type) type {
    return struct {
        private: struct {
            hash: types.HashFunc(H),
            locker: lock_manager.ILockManager(L),
            slab_svc: slab_service.ISlabService(S),
            table: HashTable,
        },
    };
}

test {
    try std.testing.expectEqual(16, @sizeOf(HashTable));
}
