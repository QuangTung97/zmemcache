const std = @import("std");
const types = @import("types.zig");

const ISlabService = struct {
    ptr: *anyopaque,

    putItem: *const fn (item: *types.Item) void,
    touchItem: *const fn (item: *types.Item) void,
    deleteItem: *const fn (item: *types.Item) void,
};

const ItemService = struct {
    hash_fn: types.HashFunc,
};

test {
    _ = .{
        types,
    };
}
