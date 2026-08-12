const std = @import("std");

const Allocator = std.mem.Allocator;

pub const LruList = enum(u2) { Hot, Warm, Cold };

pub const SlabFlags = packed struct {
    is_present: bool,
    lru_list: LruList,
};

pub const ItemFlags = packed struct {
    is_deleting: bool,
    set_partial: bool,
};

pub const RefCount = struct { refcount: u32 };

pub const CasNum = struct { cas: u64 };

pub const Item = struct {
    const Self = @This();
    pub const Size = @sizeOf(Self);
    pub const Alignment = std.mem.Alignment.fromByteUnits(@alignOf(Self));

    slab_flags: SlabFlags, // protected by slab lock
    item_flags: ItemFlags, // protected by item lock
    key_len: u8, // constant
    is_active: std.atomic.Value(bool), // set = true when touched

    refcount: RefCount, // protected by item lock
    value_len: u32, // constant

    hash_next: ?*Item, // protected by item lock

    lru_next: *Item, // protected by slab lock
    lru_prev: *Item, // protected by slab lock

    cas_num: CasNum, // protected by item lock

    // key data & item data are protected by item lock

    fn getKeyAddr(self: *Self) [*]u8 {
        const base_addr: [*]u8 = @ptrCast(self);
        return base_addr + Size;
    }

    pub fn getKey(self: *Self) []u8 {
        const key_addr = self.getKeyAddr();
        return key_addr[0..self.key_len];
    }

    pub fn getValue(self: *Self) []u8 {
        const value_addr = self.getKeyAddr() + self.key_len;
        return value_addr[0..self.value_len];
    }
};

pub const HashValue = struct {
    hash: u64,
    const Self = @This();
    pub fn init(x: u64) Self {
        return .{ .hash = x };
    }
};

pub const LockSlot = struct {
    lock_slot: u64,
    const Self = @This();
    pub fn init(x: u64) Self {
        return .{ .lock_slot = x };
    }
};

pub const SlabClass = struct { slab: u32 };

pub fn HashFunc(T: type) type {
    return struct {
        private: struct {
            self: *T,
            hashKey: *const fn (self: *T, key: []const u8) HashValue,
        },

        const Self = @This();

        pub fn init(obj: *T) Self {
            return .{
                .private = .{
                    .self = obj,
                    .hashKey = T.hashKey,
                },
            };
        }

        pub fn hashKey(self: Self, key: []const u8) HashValue {
            return self.private.hashKey(self.private.self, key);
        }
    };
}

// ===========================================================================
// Fake Hash Func
// ===========================================================================

pub const FakeHashFunc = struct {
    const KeyMapType = std.StringHashMap(HashValue);
    key_map: KeyMapType,

    const Self = @This();

    pub fn init(gpa: Allocator) Self {
        const key_map = KeyMapType.init(gpa);
        return .{
            .key_map = key_map,
        };
    }

    pub fn deinit(self: *Self) void {
        self.key_map.deinit();
    }

    pub fn hashKey(self: *Self, key: []const u8) HashValue {
        const value = self.key_map.get(key);
        if (value) |v| {
            return v;
        }
        @panic("not found key");
    }

    pub fn addKeyHash(self: *Self, key: []const u8, value: HashValue) void {
        self.key_map.put(key, value) catch unreachable;
    }
};

// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "check item size" {
    try expectEqual(1, @sizeOf(SlabFlags));
    try expectEqual(1, @sizeOf(ItemFlags));
    try expectEqual(8, @sizeOf(CasNum));
    try expectEqual(8 * 6, Item.Size);
    try expectEqual(std.mem.Alignment.@"8", Item.Alignment);
}

test "fake hash func" {
    const gpa = std.testing.allocator;

    var fake = FakeHashFunc.init(gpa);
    defer fake.deinit();

    const s = HashFunc(FakeHashFunc).init(&fake);

    const hash1 = HashValue.init(41);
    const key01 = "key01";

    fake.addKeyHash(key01, hash1);

    try expectEqual(hash1, s.hashKey(key01));
}
