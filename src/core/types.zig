const std = @import("std");

pub const ItemFlags = packed struct {
    is_deleting: bool,
    set_partial: bool,
};

pub const RefCount = struct { refcount: u32 };

pub const CasNum = struct { cas: u64 };

pub const Item = struct {
    is_present: bool, // protected by slab lock
    flags: ItemFlags, // protected by item lock
    key_len: u8, // constant
    is_active: std.atomic.Value(bool), // set = true when touched

    refcount: RefCount, // protected by item lock
    value_len: u32, // constant

    hash_next: ?*Item, // protected by item lock

    lru_next: *Item, // protected by slab lock
    lru_prev: *Item, // protected by slab lock

    cas_num: CasNum, // protected by item lock

    // key data & item data are protected by item lock
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
