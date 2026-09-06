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

    pub fn validateInit(self: *Self) void {
        std.debug.assert(self.prev == self);
        std.debug.assert(self.next == self);
    }

    pub fn pushBack(head: *Self, item: *ListHead) void {
        const last = head.prev;
        last.next = item;
        item.prev = last;

        head.prev = item;
        item.next = head;
    }

    pub fn pushFront(head: *Self, item: *ListHead) void {
        const front = head.next;
        front.prev = item;
        item.next = front;

        head.next = item;
        item.prev = head;
    }

    pub fn popFront(head: *Self) ?*ListHead {
        const item = head.next;
        if (item == head) {
            return null;
        }

        const next = item.next;
        next.prev = head;
        head.next = next;

        return item;
    }

    pub fn popBack(head: *Self) ?*ListHead {
        const item = head.prev;
        if (item == head) {
            return null;
        }

        const prev = item.prev;
        prev.next = head;
        head.prev = prev;

        return item;
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

    pub fn isEmpty(head: *Self) bool {
        return head.next == head;
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

fn expectEntryValue(node: ?*ListHead, value: u64) !void {
    try std.testing.expect(node != null);
    const entry = TestEntry.fromList(node.?);
    try expectEqual(value, entry.value);
}

fn expectIterValues(expected: []const u64, iter: anytype) !void {
    const gpa = std.testing.allocator;
    var values = std.ArrayList(u64).empty;
    defer values.deinit(gpa);

    while (iter.next()) |node| {
        const entry = TestEntry.fromList(node);
        try values.append(gpa, entry.value);
    }

    try std.testing.expectEqualSlices(u64, expected, values.items);
}

fn expectListValues(expected: []const u64, head: *ListHead) !void {
    var iter = head.iterate();
    try expectIterValues(expected, &iter);
}

test "normal" {
    var head: ListHead = undefined;
    head.initHeader();

    var e1 = TestEntry.init(21);
    var e2 = TestEntry.init(22);
    var e3 = TestEntry.init(23);

    head.pushBack(&e1.list);
    head.pushBack(&e2.list);
    head.pushBack(&e3.list);

    // iterate forward
    var iter1 = head.iterate();
    try expectIterValues(&.{ 21, 22, 23 }, &iter1);

    // iterate backward
    var iter2 = head.iterateBackward();
    try expectIterValues(&.{ 23, 22, 21 }, &iter2);

    // remove in middle
    e2.list.remove();

    // iterate again
    var iter3 = head.iterate();
    try expectIterValues(&.{ 21, 23 }, &iter3);
}

test "add then remove all" {
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

    // get all
    var iter1 = head.iterate();
    try expectIterValues(&.{}, &iter1);
}

test "pop front" {
    var head: ListHead = undefined;
    head.initHeader();

    var e1 = TestEntry.init(21);
    var e2 = TestEntry.init(22);
    var e3 = TestEntry.init(23);

    head.pushBack(&e1.list);
    head.pushBack(&e2.list);
    head.pushBack(&e3.list);

    try expectEntryValue(head.popFront(), 21);

    try expectListValues(&.{ 22, 23 }, &head);

    try expectEntryValue(head.popFront(), 22);
    try expectEntryValue(head.popFront(), 23);
    try std.testing.expect(head.popFront() == null);
}

test "pop back" {
    var head: ListHead = undefined;
    head.initHeader();

    var e1 = TestEntry.init(21);
    var e2 = TestEntry.init(22);
    var e3 = TestEntry.init(23);

    head.pushBack(&e1.list);
    head.pushBack(&e2.list);
    head.pushBack(&e3.list);

    try expectEntryValue(head.popBack(), 23);

    try expectListValues(&.{ 21, 22 }, &head);

    try expectEntryValue(head.popBack(), 22);
    try expectEntryValue(head.popBack(), 21);
    try std.testing.expect(head.popBack() == null);
}

test "push front" {
    var head: ListHead = undefined;
    head.initHeader();

    var e1 = TestEntry.init(21);
    var e2 = TestEntry.init(22);
    var e3 = TestEntry.init(23);

    head.pushFront(&e1.list);
    head.pushFront(&e2.list);
    head.pushFront(&e3.list);

    // iterate forward
    var iter1 = head.iterate();
    try expectIterValues(&.{ 23, 22, 21 }, &iter1);

    // iterate backward
    var iter2 = head.iterateBackward();
    try expectIterValues(&.{ 21, 22, 23 }, &iter2);
}

test "iterate and remove at the same time" {
    var head: ListHead = undefined;
    head.initHeader();

    var e1 = TestEntry.init(21);
    var e2 = TestEntry.init(22);
    var e3 = TestEntry.init(23);

    head.pushBack(&e1.list);
    head.pushBack(&e2.list);
    head.pushBack(&e3.list);
    try expectEqual(false, head.isEmpty());

    var it = head.iterate();
    while (it.next()) |e| {
        e.remove();
    }

    try expectListValues(&.{}, &head);
    try expectEqual(true, head.isEmpty());
}
