const std = @import("std");
const types = @import("types.zig");

const linux = std.os.linux;

pub const FD = linux.fd_t;
pub const Event = linux.epoll_event;
pub const EpollFuncs = types.EpollFuncs(EpollService, Event, FD);

const EpollService = struct {
    const Self = @This();

    _epoll_fd: FD,

    pub fn init() Self {
        const result = std.os.linux.epoll_create();
        if (linux.errno(result) != .SUCCESS) {
            @panic("Failed to create epoll instance");
        }
        return .{
            ._epoll_fd = @intCast(result),
        };
    }

    pub fn deinit(self: *Self) void {
        const result = linux.close(self._epoll_fd);
        if (linux.errno(result) != .SUCCESS) {
            @panic("Failed to close epoll instance");
        }
    }

    pub fn epollWait(self: *Self, buffer: []Event, with_wait: bool) []Event {
        const timeout: i32 = if (with_wait) -1 else 0;
        const result = linux.epoll_wait(
            self._epoll_fd,
            buffer.ptr,
            @intCast(buffer.len),
            timeout,
        );
        if (linux.errno(result) != .SUCCESS) {
            @panic("Failed to epoll wait");
        }
        return buffer[0..result];
    }

    pub fn epollAdd(self: *Self, client_fd: FD, data_ptr: *anyopaque) void {
        var event = Event{
            .events = linux.EPOLL.IN | linux.EPOLL.OUT,
            .data = .{
                .ptr = @intFromPtr(data_ptr),
            },
        };
        const result = linux.epoll_ctl(
            self._epoll_fd,
            linux.EPOLL.CTL_ADD,
            client_fd,
            &event,
        );
        if (linux.errno(result) != .SUCCESS) {
            @panic("Failed to epoll add");
        }
    }

    pub fn epollRemove(self: *Self, client_fd: FD) void {
        const result = linux.epoll_ctl(
            self._epoll_fd,
            linux.EPOLL.CTL_DEL,
            client_fd,
            null,
        );
        if (linux.errno(result) != .SUCCESS) {
            @panic("Failed to epoll remove");
        }
    }
};

test "epoll" {
    var epoll = EpollService.init();
    defer epoll.deinit();

    std.testing.refAllDecls(EpollService);

    const funcs = EpollFuncs.init();

    // run epoll wait empty
    var buffer: [16]Event = undefined;
    const events = funcs.epollWait(&epoll, &buffer, false);
    try std.testing.expectEqual(0, events.len);
}
