const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn EpollFuncs(T: type, Event: type, FD: type) type {
    return struct {
        epollWait: fn (self: T, events: []Event, with_wait: bool) []Event,
        epollAdd: fn (self: T, client_fd: FD, data_ptr: *anyopaque) void,
        epollRemove: fn (self: T, client_fd: FD) void,
    };
}

pub fn EventFuncs(Event: type) type {
    return struct {
        hasEpollIn: fn (self: *const Event) bool,
        hasEpollOut: fn (self: *const Event) bool,
        getDataPtr: fn (self: *const Event) *anyopaque,
    };
}

pub const SocketError = error{ EAGAIN, ConnectionError };

pub fn SocketFuncs(FD: type) type {
    return struct {
        read: fn (socket: FD, buffer: []u8) SocketError![]u8,
        write: fn (socket: FD, data: []const u8) SocketError!usize,
        close: fn (socket: FD) void,
    };
}

pub fn EventFdFuncs(FD: type) type {
    return struct {
        drain: fn (fd: FD) void,
        inc: fn (fd: FD) void,
    };
}

pub fn ActionEntry(FD: type) type {
    return union(enum) {
        NewConn: struct {
            fd: FD,
        },
        Shutdown: struct {},
    };
}

pub const WriteQueue = struct {
    const Self = @This();
    const Queue = std.Deque([]const u8);

    _gpa: Allocator,
    _queue: Queue,

    pub fn init(gpa: Allocator, queue_size: usize) !Self {
        const queue = try Queue.initCapacity(gpa, queue_size);
        return .{
            ._gpa = gpa,
            ._queue = queue,
        };
    }

    pub fn addWriteFrame(self: *Self, data: []const u8) void {
        self._queue.pushBackBounded(data) catch unreachable;
    }

    pub fn popWriteFrame(self: *Self) ?[]const u8 {
        return self._queue.popFront();
    }

    pub fn iterator(self: *Self) Queue.Iterator {
        return self._queue.iterator();
    }

    pub fn deinit(self: *Self) void {
        self._queue.deinit(self._gpa);
    }

    pub fn allowNumItems(self: *const Self, num_items: usize) bool {
        return self._queue.len + num_items <= self._queue.buffer.len;
    }
};

pub fn CallbackFuncs(T: type) type {
    return struct {
        onReadData: fn (self: *T, data: []const u8, writeQueue: *WriteQueue) void,
        popWriteFrame: fn (self: *T) void,
    };
}

test "writer queue" {
    const gpa = std.testing.allocator;
    var w = try WriteQueue.init(gpa, 3);
    defer w.deinit();

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

    try std.testing.expectEqualStrings("data 01", w.popWriteFrame().?);
    try std.testing.expectEqualStrings("data 02", w.popWriteFrame().?);
}
