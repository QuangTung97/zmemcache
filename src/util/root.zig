const ztest = @import("testing.zig");
const iter = @import("iterator.zig");
const linked = @import("linked_list.zig");
const wait_group = @import("wait_group.zig");

pub const atomic = @import("atomic.zig");

pub const expectIteratorValues = ztest.expectIteratorValues;
pub const expectStringSlicesEqual = ztest.expectStringSlicesEqual;

pub const Iterator = iter.Iterator;
pub const ListHead = linked.ListHead;
pub const WaitGroup = wait_group.WaitGroup;

pub fn runtimeAssert(b: bool) void {
    if (!b) {
        @panic("assertion failed");
    }
}

test {
    _ = .{
        ztest,
        iter,
        linked,
        wait_group,
        atomic,
    };
}
