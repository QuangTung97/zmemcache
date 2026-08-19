const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const SlabClass = types.SlabClass;
const CasNum = types.CasNum;
const Item = types.Item;

pub const TouchItem = struct {
    slab: SlabClass,
    cas: CasNum,
    item: *Item,

    pub fn fromItem(item: *Item) @This() {
        return .{
            .slab = item.slab,
            .cas = item.cas_num,
            .item = item,
        };
    }
};

/// TouchListFuncs is a thread safe object
pub fn TouchListFuncs(T: type) type {
    return struct {
        push: fn (self: *T, item: TouchItem) void,
        pop: fn (self: *T) error{Closed}!TouchItem,
    };
}

pub fn NewTouchListFuncs(T: type) TouchListFuncs(T) {
    return .{
        .push = T.push,
        .pop = T.pop,
    };
}

// TODO add ring buffer touch list

// ===========================================================================
// Fake Touch List
// ===========================================================================

pub const FakeTouchList = struct {
    const Self = @This();
    const Queue = std.Deque(TouchItem);

    _gpa: Allocator,
    _queue: Queue,

    pub fn init(gpa: Allocator) !Self {
        const queue = Queue.empty;
        return .{
            ._gpa = gpa,
            ._queue = queue,
        };
    }

    pub fn deinit(self: *Self) void {
        self._queue.deinit(self._gpa);
    }

    pub fn push(self: *Self, item: TouchItem) void {
        self._queue.pushBack(self._gpa, item) catch unreachable;
    }

    pub fn pop(self: *Self) error{Closed}!TouchItem {
        const item = self._queue.popFront().?;
        return item;
    }
};

// ===========================================================================
// Testing
// ===========================================================================

const expectEqual = std.testing.expectEqual;

test "fake impl" {
    const impl = NewTouchListFuncs(FakeTouchList);
    _ = impl;
}

fn newItem(slab: SlabClass, cas: u64) Item {
    var item: Item = undefined;
    item.slab = slab;
    item.cas_num = CasNum.init(cas);
    return item;
}

test "fake" {
    var l = try FakeTouchList.init(std.testing.allocator);
    defer l.deinit();

    const slab1 = SlabClass.init(1);

    var item1 = newItem(slab1, 21);
    var item2 = newItem(slab1, 22);

    l.push(.fromItem(&item1));
    l.push(.fromItem(&item2));

    const value1 = try l.pop();
    try expectEqual(slab1, value1.slab);
    try expectEqual(21, value1.cas.cas);

    // pop again
    const value2 = try l.pop();
    try expectEqual(slab1, value2.slab);
    try expectEqual(22, value2.cas.cas);
}
