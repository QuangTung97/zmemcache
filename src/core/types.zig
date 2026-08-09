const std = @import("std");

pub const ItemFlags = packed struct {
    present: bool,
    is_deleting: bool,
    set_partial: bool,
};

pub const RefCount = struct { refcount: u32 };

pub const CasNum = struct { cas: u64 };

pub const Item = struct {
    flags: ItemFlags,
    key_len: u8,
    is_touched: std.atomic.Value(bool),

    refcount: RefCount,
    value_len: u32,

    hash_next: ?*Item,

    lru_next: *Item,
    lru_prev: *Item,

    cas_num: CasNum,
};

pub const ItemSize = @sizeOf(Item);

pub const HashValue = struct { hash: u64 };

pub fn HashFunc(T: type) type {
    return struct {
        self: *T,
        private: struct {
            hash: *const fn (self: *T, key: []const u8) HashValue,
        },
    };
}

test "check item size" {
    try std.testing.expectEqual(1, @sizeOf(ItemFlags));
    try std.testing.expectEqual(8, @sizeOf(CasNum));
    try std.testing.expectEqual(8 * 6, ItemSize);
}
