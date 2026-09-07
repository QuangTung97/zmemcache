const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn EpollFuncs(T: type, Event: type, FD: type) type {
    return struct {
        epollWait: fn (self: *T, buffer: []Event, with_wait: bool) []Event,
        epollAdd: fn (self: *T, client_fd: FD, data_ptr: *anyopaque) void,
        epollRemove: fn (self: *T, client_fd: FD) void,

        const Self = @This();

        pub fn init() Self {
            return .{
                .epollWait = T.epollWait,
                .epollAdd = T.epollAdd,
                .epollRemove = T.epollRemove,
            };
        }
    };
}

pub fn EventFuncs(Event: type) type {
    return struct {
        hasEpollIn: fn (self: Event) bool,
        hasEpollOut: fn (self: Event) bool,
        getDataPtr: fn (self: Event) *anyopaque,

        const Self = @This();

        pub fn init() Self {
            return .{
                .hasEpollIn = Event.hasEpollIn,
                .hasEpollOut = Event.hasEpollOut,
                .getDataPtr = Event.getDataPtr,
            };
        }
    };
}

pub const SocketError = error{ EAGAIN, ConnectionError };

pub fn SocketFuncs(T: type, FD: type) type {
    return struct {
        // read always returns size > 0
        read: fn (self: *T, socket: FD, buffer: []u8) SocketError!usize,

        // write always returns size > 0
        write: fn (self: *T, socket: FD, write_queue: *WriteQueue) SocketError!usize,

        const Self = @This();

        pub fn init() Self {
            return .{
                .read = T.read,
                .write = T.write,
            };
        }
    };
}

pub fn EventFdFuncs(FD: type) type {
    return struct {
        drain: fn (fd: FD) void, // TODO use
        inc: fn (fd: FD) void, // TODO use
    };
}

pub fn ActionEntry(FD: type) type {
    return union(enum) {
        NewConn: struct {
            fd: FD,
        },
        Shutdown: struct {}, // TODO use
    };
}

pub const WriteQueue = struct {
    const Self = @This();
    const Queue = std.Deque([]const u8);

    _queue: Queue,

    pub fn init(buffer: [][]const u8) Self {
        return .{
            ._queue = Queue.initBuffer(buffer),
        };
    }

    pub fn addWriteFrame(self: *Self, data: []const u8) void {
        std.debug.assert(data.len > 0);
        self._queue.pushBackBounded(data) catch unreachable;
    }

    pub fn popWriteFrame(self: *Self) ?[]const u8 {
        return self._queue.popFront();
    }

    pub fn peakWriteFrame(self: *Self) ?*[]const u8 {
        return self._queue.frontPtr();
    }

    pub fn iterator(self: *Self) Queue.Iterator {
        return self._queue.iterator();
    }

    pub fn allowNumItems(self: *const Self, num_items: usize) bool {
        return self._queue.len + num_items <= self._queue.buffer.len;
    }

    pub fn count(self: *const Self) usize {
        return self._queue.len;
    }
};

pub const OnReadResult = union(enum) {
    const Self = @This();

    Ok: struct {
        next_read_size: usize,
    },
    WaitWriteQueue: struct {},

    pub fn initOk(n: usize) Self {
        return .{
            .Ok = .{
                .next_read_size = n,
            },
        };
    }
};

pub fn CallbackFuncs(T: type) type {
    return struct {
        init_read_size: usize,

        onInit: fn () T,
        onDeinit: fn (self: *T) void,

        onReadData: fn (
            self: *T,
            data: []const u8,
            write_queue: *WriteQueue,
            finished: *bool, // current action is finished
        ) OnReadResult,

        popWriteFrame: fn (self: *T) void,

        const Self = @This();

        pub fn init() Self {
            return .{
                .init_read_size = T.init_read_size,

                .onInit = T.onInit,
                .onDeinit = T.onDeinit,

                .onReadData = T.onReadData,
                .popWriteFrame = T.popWriteFrame,
            };
        }
    };
}

pub fn StackAllocator(T: type) type {
    return struct {
        const Self = @This();
        const IndexList = std.ArrayList(usize);

        _all_items: []T,
        _free_indices: IndexList,

        pub fn init(gpa: Allocator, max_size: usize) !Self {
            const all_items = try gpa.alloc(T, max_size);
            errdefer gpa.free(all_items);

            var free_indices = try IndexList.initCapacity(gpa, max_size);
            for (0..max_size) |i| {
                try free_indices.appendBounded(i);
            }

            return .{
                ._all_items = all_items,
                ._free_indices = free_indices,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self._free_indices.deinit(gpa);
            gpa.free(self._all_items);
        }

        pub fn create(self: *Self) *T {
            const free_index = self._free_indices.pop().?;
            return &self._all_items[free_index];
        }

        pub fn destroy(self: *Self, item: *T) void {
            const item_ptr: [*]T = @ptrCast(item);
            const index = item_ptr - self._all_items.ptr;
            self._free_indices.appendBounded(index) catch unreachable;
        }
    };
}

test "writer queue" {
    var buffer: [3][]const u8 = undefined;
    var w = WriteQueue.init(&buffer);

    try std.testing.expectEqual(true, w.allowNumItems(3));
    try std.testing.expectEqual(false, w.allowNumItems(4));

    w.addWriteFrame("data 01");
    w.addWriteFrame("data 02");

    try std.testing.expectEqual(true, w.allowNumItems(1));
    try std.testing.expectEqual(false, w.allowNumItems(2));
    try std.testing.expectEqual(false, w.allowNumItems(3));

    var it = w.iterator();
    var total: u64 = 0;
    while (it.next()) |e| {
        try std.testing.expectEqual(7, e.len);
        total += 1;
    }
    try std.testing.expectEqual(2, total);

    try std.testing.expectEqualStrings("data 01", w.peakWriteFrame().?.*);
    try std.testing.expectEqualStrings("data 01", w.popWriteFrame().?);
    try std.testing.expectEqualStrings("data 02", w.popWriteFrame().?);
}

test "stack allocator" {
    const gpa = std.testing.allocator;

    var s = try StackAllocator(u64).init(gpa, 3);
    defer s.deinit(gpa);

    // check after init
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, s._free_indices.items);

    // create
    const ptr1 = s.create();
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, s._free_indices.items);

    // create again
    const ptr2 = s.create();
    try std.testing.expectEqualSlices(usize, &.{0}, s._free_indices.items);

    s.destroy(ptr1);
    s.destroy(ptr2);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1 }, s._free_indices.items);
}
