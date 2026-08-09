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

pub const ItemAlignment = std.mem.Alignment.fromByteUnits(@alignOf(Item));

pub const HashValue = struct { hash: u64 };

pub fn HashFunc(T: type) type {
    return struct {
        private: struct {
            self: *T,
            hash: *const fn (self: *T, key: []const u8) HashValue,
        },

        const Self = @This();

        pub fn hashKey(self: Self, key: []const u8) HashValue {
            return self.private.hash(self.private.self, key);
        }
    };
}

pub const SlabClass = struct { slab: u32 };

const expectEqual = std.testing.expectEqual;

test "check item size" {
    try expectEqual(1, @sizeOf(ItemFlags));
    try expectEqual(8, @sizeOf(CasNum));
    try expectEqual(8 * 6, ItemSize);
    try expectEqual(std.mem.Alignment.@"8", ItemAlignment);
}
