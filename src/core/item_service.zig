const types = @import("types.zig");
const lock_manager = @import("lock_manager.zig");
const slab_service = @import("slab_service.zig");

pub const HashTable = struct {
    buckets: []?*types.Item,
};

pub fn ItemService(H: type, L: type, S: type) type {
    return struct {
        hash_obj: H,
        hash_func: types.HashFunc(H),
        lock_obj: L,
        lock_funcs: lock_manager.ILockManager(L),
        slab_obj: S,
        slab_funcs: slab_service.ISlabService(S),

        table: HashTable,
    };
}
