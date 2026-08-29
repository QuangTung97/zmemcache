const std = @import("std");

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

test "hello" {
    try std.testing.expectEqual(2, 2);
}
