const iter = @import( "iterator.zig");
const linked = @import("linked_list.zig");

pub const Iterator = iter.Iterator;
pub const ListHead = linked.ListHead;

test {
    _ = .{
        iter,
        linked,
    };
}
