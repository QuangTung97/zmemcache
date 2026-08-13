const std = @import("std");

pub const ListIter = struct {
    head: *ListHead,
    current: *ListHead,

    pub fn next(self: *@This()) ?*ListHead {
        const item = self.current;
        if (item == self.head) {
            return null;
        }
        self.current = self.current.next;
        return item;
    }
};

pub const ListIterBackward = struct {
    head: *ListHead,
    current: *ListHead,

    pub fn next(self: *@This()) ?*ListHead {
        const item = self.current;
        if (item == self.head) {
            return null;
        }
        self.current = self.current.prev;
        return item;
    }
};

pub const ListHead = struct {
    next: *ListHead,
    prev: *ListHead,

    const Self = @This();

    pub fn initHeader(self: *Self) void {
        self.next = self;
        self.prev = self;
    }

    pub fn pushBack(head: *Self, item: *ListHead) void {
        const last = head.prev;
        last.next = item;
        item.prev = last;

        head.prev = item;
        item.next = head;
    }

    pub fn remove(self: *Self) void {
        const next = self.next;
        const prev = self.prev;
        next.prev = prev;
        prev.next = next;
    }

    pub fn iterate(head: *Self) ListIter {
        return .{
            .head = head,
            .current = head.next,
        };
    }

    pub fn iterateBackward(head: *Self) ListIterBackward {
        return .{
            .head = head,
            .current = head.prev,
        };
    }
};

// ===========================================================================
// Testing
// ===========================================================================

const TestEntry = struct {
    value: u64,
    list: ListHead,

    fn init(v: u64) @This() {
        return .{
            .value = v,
            .list = undefined,
        };
    }

    fn fromList(item: *ListHead) *@This() {
        return @fieldParentPtr("list", item);
    }
};

const expectEqual = std.testing.expectEqual;

test "normal" {
    const gpa = std.testing.allocator;

    var head: ListHead = undefined;
    head.initHeader();

    var e1 = TestEntry.init(21);
    var e2 = TestEntry.init(22);
    var e3 = TestEntry.init(23);

    head.pushBack(&e1.list);
    head.pushBack(&e2.list);
    head.pushBack(&e3.list);

    const ValueList = std.ArrayList(u64);
    var values = ValueList.empty;
    defer values.deinit(gpa);

    // iterate backward
    var iter = head.iterate();
    while (iter.next()) |x| {
        const entry = TestEntry.fromList(x);
        try values.append(gpa, entry.value);
    }

    const values01 = [_]u64{ 21, 22, 23 };
    try std.testing.expectEqualSlices(u64, &values01, values.items);

    // iterate backward
    var iter2 = head.iterateBackward();
    values.clearRetainingCapacity();
    while (iter2.next()) |x| {
        const entry = TestEntry.fromList(x);
        try values.append(gpa, entry.value);
    }
    const values02 = [_]u64{ 23, 22, 21 };
    try std.testing.expectEqualSlices(u64, &values02, values.items);

    // remove in middle
    e2.list.remove();

    // iterate again
    var iter3 = head.iterate();
    values.clearRetainingCapacity();
    while (iter3.next()) |x| {
        const entry = TestEntry.fromList(x);
        try values.append(gpa, entry.value);
    }
    const values03 = [_]u64{ 21, 23 };
    try std.testing.expectEqualSlices(u64, &values03, values.items);
}

test "add then remove all" {
    const gpa = std.testing.allocator;

    var head: ListHead = undefined;
    head.initHeader();

    var e1 = TestEntry.init(21);
    var e2 = TestEntry.init(22);
    var e3 = TestEntry.init(23);

    head.pushBack(&e1.list);
    head.pushBack(&e2.list);
    head.pushBack(&e3.list);

    // remove in middle
    e2.list.remove();
    e3.list.remove();
    e1.list.remove();

    // init values
    const ValueList = std.ArrayList(u64);
    var values = ValueList.empty;
    defer values.deinit(gpa);

    // iterate again
    var iter1 = head.iterate();
    while (iter1.next()) |x| {
        const entry = TestEntry.fromList(x);
        try values.append(gpa, entry.value);
    }
    const values01 = [_]u64{};
    try std.testing.expectEqualSlices(u64, &values01, values.items);
}
