const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Item = types.Item;
const Slab = types.SlabClass;

pub fn ILruService(T: type) type {
    return struct {
        private: struct {
            self: *T,

            lockSlab: *const fn (self: *T, slab: Slab) void,
            unlockSlab: *const fn (self: *T, slab: Slab) void,
            isSlabLocked: *const fn (self: *T, slab: Slab) bool,

            putItem: *const fn (self: *T, slab: Slab, item: *Item) void,
            touchItem: *const fn (self: *T, slab: Slab, item: *Item) void,
            deleteItem: *const fn (self: *T, slab: Slab, item: *Item) void,
        },

        const Self = @This();

        pub fn init(obj: *T) Self {
            return .{
                .private = .{
                    .self = obj,
                    .lockSlab = T.lockSlab,
                    .unlockSlab = T.unlockSlab,
                    .isSlabLocked = T.isSlabLocked,
                    .putItem = T.putItem,
                    .touchItem = T.touchItem,
                    .deleteItem = T.deleteItem,
                },
            };
        }

        pub fn lockSlab(self: Self, slab: Slab) void {
            self.private.lockSlab(self.private.self, slab);
        }

        pub fn unlockSlab(self: Self, slab: Slab) void {
            self.private.unlockSlab(self.private.self, slab);
        }

        pub fn isSlabLocked(self: Self, slab: Slab) bool {
            return self.private.isSlabLocked(self.private.self, slab);
        }

        pub fn put(self: Self, slab: Slab, item: *Item) void {
            self.private.putItem(self.private.self, slab, item);
        }

        pub fn touch(self: Self, slab: Slab, item: *Item) void {
            self.private.touchItem(self.private.self, slab, item);
        }

        pub fn delete(self: Self, slab: Slab, item: *Item) void {
            self.private.deleteItem(self.private.self, slab, item);
        }
    };
}

// ===========================================================================
// Fake Lru Service
// ===========================================================================

pub const FakeLruService = struct {
    const LockedSetType = std.AutoHashMap(Slab, struct {});
    lockedSet: LockedSetType,

    const Self = @This();

    pub fn init(gpa: Allocator) Self {
        const lockedSet = LockedSetType.init(gpa);
        return .{
            .lockedSet = lockedSet,
        };
    }

    pub fn deinit(self: *Self) void {
        self.lockedSet.deinit();
    }

    pub fn lockSlab(self: *Self, slab: Slab) void {
        std.debug.assert(!self.lockedSet.contains(slab));
        self.lockedSet.put(slab, .{}) catch unreachable;
    }

    pub fn unlockSlab(self: *Self, slab: Slab) void {
        const ok = self.lockedSet.remove(slab);
        std.debug.assert(ok);
    }

    pub fn isSlabLocked(self: *Self, slab: Slab) bool {
        return self.lockedSet.contains(slab);
    }

    pub fn putItem(_: *Self, _: Slab, _: *Item) void {}

    pub fn touchItem(_: *Self, _: Slab, _: *Item) void {}

    pub fn deleteItem(_: *Self, _: Slab, _: *Item) void {}
};

// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "lock & unlock" {
    const gpa = std.testing.allocator;
    var fake = FakeLruService.init(gpa);
    defer fake.deinit();

    const s = ILruService(FakeLruService).init(&fake);

    const slab1 = Slab{ .slab = 21 };
    const slab2 = Slab{ .slab = 22 };

    try expectEqual(false, s.isSlabLocked(slab1));
    try expectEqual(false, s.isSlabLocked(slab2));

    // lock
    s.lockSlab(slab1);

    try expectEqual(true, s.isSlabLocked(slab1));
    try expectEqual(false, s.isSlabLocked(slab2));

    // unlock
    s.unlockSlab(slab1);
    try expectEqual(false, s.isSlabLocked(slab1));
}
