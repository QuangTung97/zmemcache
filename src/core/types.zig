const std = @import("std");
const zutil = @import("zutil");

const Allocator = std.mem.Allocator;
const ListHead = zutil.ListHead;

pub const CachePadding = [64]u8;

pub const LruList = enum(u2) { Hot, Warm, Cold };

pub const SlabFlags = packed struct {
    is_present: bool,
    lru_list: LruList,
};

pub const ItemFlags = packed struct {
    set_partial: bool,
};

pub const RefCount = struct {
    refcount: u32,
    pub fn init(x: u32) @This() {
        return .{ .refcount = x };
    }
};

pub const CasNum = struct {
    cas: u64,
    pub fn init(x: u64) @This() {
        return .{ .cas = x };
    }
};

pub const Item = struct {
    const Self = @This();
    pub const Size = @sizeOf(Self);
    pub const Alignment = std.mem.Alignment.fromByteUnits(@alignOf(Self));

    slab_flags: SlabFlags, // protected by slab lock
    item_flags: ItemFlags, // protected by item lock

    key_len: u8, // constant
    slab: SlabClass, // constant

    is_touched: std.atomic.Value(bool), // set = true when touched

    refcount: RefCount, // protected by item lock
    value_len: u32, // constant

    hash_next: ?*Item, // protected by item lock
    lru_list: ListHead, // protected by slab lock
    cas_num: CasNum, // constant

    // key data & item data are protected by item lock

    pub fn init(slab: SlabClass, key_len: usize, value_len: usize, cas: CasNum) Self {
        const it: Self = .{
            .slab_flags = SlabFlags{
                .is_present = true,
                .lru_list = .Hot,
            },
            .item_flags = ItemFlags{
                .set_partial = false,
            },
            .is_touched = .init(false),
            .hash_next = null,
            .lru_list = undefined,
            .refcount = RefCount.init(1),
            .cas_num = cas,

            .slab = slab,
            .key_len = @intCast(key_len),
            .value_len = @intCast(value_len),
        };

        std.debug.assert(key_len <= std.math.maxInt(@TypeOf(it.key_len)));
        std.debug.assert(value_len <= std.math.maxInt(@TypeOf(it.value_len)));

        return it;
    }

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

    pub fn getItemSize(self: *Self) usize {
        return Size + self.key_len + self.value_len;
    }

    pub fn toItemAddr(self: *Self) [*]u8 {
        return @ptrCast(self);
    }

    pub fn computeItemSize(key_len: usize, value_len: usize) usize {
        return Size + key_len + value_len;
    }

    pub fn fromList(entry: *ListHead) *Self {
        return @fieldParentPtr("lru_list", entry);
    }
};

pub const HashValue = struct {
    hash: u64,
    pub fn init(x: u64) @This() {
        return .{ .hash = x };
    }
};

pub const LockSlot = struct {
    lock_slot: u64,
    pub fn init(x: u64) @This() {
        return .{ .lock_slot = x };
    }
};

pub const SlabClass = struct {
    pub const IntType = u8;
    pub const MaxValue = std.math.maxInt(IntType);
    const Self = @This();

    slab: IntType,

    pub fn init(x: IntType) Self {
        return .{ .slab = x };
    }

    pub fn nullEqual(self: Self, other: ?Self) bool {
        const other_val = if (other) |x| x else {
            return false;
        };
        return self.slab == other_val.slab;
    }
};

pub fn HashFunc(T: type) type {
    return struct {
        hashKey: fn (self: *T, key: []const u8) HashValue,
    };
}

pub fn NewHashFunc(T: type) HashFunc(T) {
    return .{ .hashKey = T.hashKey };
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

    pub fn putKeyHash(self: *Self, key: []const u8, value: HashValue) void {
        self.key_map.put(key, value) catch unreachable;
    }
};

// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "cache padding" {
    try expectEqual(64, @sizeOf(CachePadding));
}

test "check item size" {
    try expectEqual(1, @sizeOf(SlabFlags));
    try expectEqual(1, @sizeOf(ItemFlags));
    try expectEqual(8, @sizeOf(CasNum));
    try expectEqual(8 * 6, Item.Size);
    try expectEqual(std.mem.Alignment.@"8", Item.Alignment);

    try expectEqual(true, Item.Alignment.check(16));
    try expectEqual(false, Item.Alignment.check(17));
    try expectEqual(false, Item.Alignment.check(19));
    try expectEqual(false, Item.Alignment.check(20));
    try expectEqual(true, Item.Alignment.check(24));
}

test "slab class" {
    try expectEqual(255, SlabClass.MaxValue);
}

test "item getter" {
    var item: Item = undefined;
    item.key_len = 11;
    item.value_len = 22;

    const base_addr: [*]u8 = @ptrCast(&item);
    const key = item.getKey();

    try expectEqual(11, key.len);
    try expectEqual(Item.Size, key.ptr - base_addr);

    const val = item.getValue();
    try expectEqual(22, val.len);
    try expectEqual(Item.Size + 11, val.ptr - base_addr);

    try expectEqual(48 + 11 + 22, item.getItemSize());
}

test "check lru list" {
    var item: Item = undefined;
    const entry = &item.lru_list;
    try expectEqual(&item, Item.fromList(entry));
}

test "fake hash func" {
    const gpa = std.testing.allocator;

    var fake = FakeHashFunc.init(gpa);
    defer fake.deinit();

    const s = NewHashFunc(FakeHashFunc);

    const hash1 = HashValue.init(41);
    const key01 = "key01";

    fake.putKeyHash(key01, hash1);

    try expectEqual(hash1, s.hashKey(&fake, key01));
}
