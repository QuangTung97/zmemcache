const std = @import("std");
const types = @import("types.zig");
const zutil = @import("zutil");
const zatomic = zutil.atomic;

const Allocator = std.mem.Allocator;
const SlabClass = types.SlabClass;
const CasNum = types.CasNum;
const Item = types.Item;
const CachePadding = types.CachePadding;

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

// ===========================================================================
// Touch List Ring Buffer
// ===========================================================================

const RingEntry = struct {
    next: zatomic.Value(u64),
    touch_item: TouchItem,

    const Empty: u64 = 0;
    const Linked: u64 = 1;
    const ConsumeWait: u64 = std.math.maxInt(u64);
};

pub const TouchRingBuffer = struct {
    const Self = @This();

    _gpa: Allocator,
    _buffer: []RingEntry,
    _mask: u64,

    _padding1: CachePadding = undefined,
    _consume_seq: zatomic.Value(u64),

    _padding2: CachePadding = undefined,
    _produce_seq: zatomic.Value(u64),

    _padding3: CachePadding = undefined,
    _sema: zutil.Semaphore,

    pub fn init(io: std.Io, gpa: Allocator, max_size_log: u6) !Self {
        const max_size: u64 = @as(u64, 1) << max_size_log;

        // init buffer
        const buffer = try gpa.alloc(RingEntry, max_size);
        for (buffer) |*e| {
            e.next.store(RingEntry.Empty);
        }

        return .{
            ._gpa = gpa,
            ._buffer = buffer,
            ._mask = max_size - 1,
            ._consume_seq = .init(0),
            ._produce_seq = .init(0),
            ._sema = .init(io),
        };
    }

    pub fn deinit(self: *Self) void {
        self._gpa.free(self._buffer);
    }

    pub fn push(self: *Self, item: TouchItem) void {
        const total_size: u64 = self._buffer.len;

        var seq = self._produce_seq.load();
        while (true) {
            const consume_seq = self._consume_seq.load();
            if (seq >= consume_seq + total_size) {
                return;
            }

            const null_new_seq = self._produce_seq.cmpxchgWeak(seq, seq + 1);
            if (null_new_seq) |new_seq| {
                seq = new_seq;
                continue;
            }

            const entry = self.getEntry(seq);
            entry.touch_item = item;
            entry.next.store(RingEntry.Linked);
            return;
        }
    }

    pub fn pop(self: *Self) error{Closed}!TouchItem {
        const seq = self._consume_seq.load();
        const entry = self.getEntry(seq);

        var next_val = entry.next.load();

        while (true) {
            if (next_val == RingEntry.Linked) {
                const item = entry.touch_item;
                entry.next.store(RingEntry.Empty);
                self._consume_seq.store(seq + 1); // go to next
                return item;
            }

            const null_new_val = entry.next.cmpxchgWeak(next_val, RingEntry.ConsumeWait);
            if (null_new_val) |new_val| {
                next_val = new_val;
                continue;
            }

            // wait on semaphore
            try self._sema.down();
        }
    }

    pub fn close(self: *Self) void {
        self._sema.close();
    }

    fn getEntry(self: *Self, seq: u64) *RingEntry {
        const index = seq & self._mask;
        return &self._buffer[index];
    }
};

const expectEqual = std.testing.expectEqual;

fn newItem(slab: SlabClass, cas: u64) Item {
    var item: Item = undefined;
    item.slab = slab;
    item.cas_num = CasNum.init(cas);
    return item;
}

test "ring entry size" {
    try expectEqual(32, @sizeOf(RingEntry));
    try expectEqual(0xffff_ffff_ffff_ffff, RingEntry.ConsumeWait);
}

test "ring buffer impl" {
    // TODO
}

test "ring buffer, simple push and pop" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var b = try TouchRingBuffer.init(io, gpa, 3);
    defer b.deinit();

    const slab1 = SlabClass.init(1);

    var item1 = newItem(slab1, 31);
    var item2 = newItem(slab1, 32);
    var item3 = newItem(slab1, 33);

    b.push(TouchItem.fromItem(&item1));
    b.push(TouchItem.fromItem(&item2));
    b.push(TouchItem.fromItem(&item3));

    const touch1 = try b.pop();
    try expectEqual(31, touch1.cas.cas);

    const touch2 = try b.pop();
    try expectEqual(32, touch2.cas.cas);

    const touch3 = try b.pop();
    try expectEqual(33, touch3.cas.cas);
}

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

test "fake impl" {
    const impl = NewTouchListFuncs(FakeTouchList);
    _ = impl;
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
