const std = @import("std");
const types = @import("types.zig");

const SlabClass = types.SlabClass;
const CasNum = types.CasNum;
const Item = types.Item;

pub const TouchItem = struct {
    slab: SlabClass,
    cas: CasNum,
    item: *Item,
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

// ===========================================================================
// Fake Touch List
// ===========================================================================

pub const FakeTouchList = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn push(_: *Self, _: TouchItem) void {}

    pub fn pop(_: *Self) error{Closed}!TouchItem {
        return error.Closed;
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
