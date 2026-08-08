const std = @import("std");

const ItemFlags = packed struct {
    present: bool,
    is_deleting: bool,
    set_partial: bool,
};

const Item = struct {
    flags: ItemFlags,
    key_len: u8,
    is_touched: std.atomic.Value(bool),

    refcount: u32,
    value_len: u32,

    hash_next: ?*Item,

    lru_next: *Item,
    lru_prev: *Item,

    cas_num: u64,
};

const ItemSize = @sizeOf(Item);

pub fn ItemService() type {
    return struct {
        const Self = @This();
    };
}

test "hello" {
    try std.testing.expectEqual(8 * 6, ItemSize);
}
