const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const TaskType = enum { Read, Write };

const HandleTaskStatus = enum {
    Continue, // loop right away
    Next, // go to the next task
};

pub fn EpollCore(
    FD: type,
    Event: type,
    E: type,
    _: types.EventFdFuncs(FD),
    _: types.SocketFuncs(FD),
    _: types.EventFuncs(Event),
    _: types.EpollFuncs(E, Event, FD),
) type {
    const ActionQueue = std.Deque(types.ActionEntry(FD));

    const buffer_size = 4 * 1024;

    const SocketState = struct {
        is_eventfd: bool,
        socket_fd: FD,

        client_closed: bool = false,
        server_closed: bool = false,

        tmp_buf: [buffer_size]u8 = undefined,
        tmp_buf_start: usize = 0,
        tmp_buf_end: usize = 0,

        read_size: ?usize = null,
        handle_buf: [buffer_size]u8 = undefined,
        handle_buf_len: usize = 0,

        // TODO add linked list of all socket states
    };

    const Task = struct {
        task_type: TaskType,
        state: *SocketState,
    };

    const TaskQueue = std.Deque(Task);

    return struct {
        const Self = @This();

        _gpa: Allocator,
        _action_queue: ActionQueue,
        _task_queue: TaskQueue,
        _yield_queue: TaskQueue,

        // TODO add padding
        _num_active_conns: u64, // TODO use atomic

        pub fn init(gpa: Allocator) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);

            self.* = .{
                ._gpa = gpa,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            const gpa = self._gpa;
            gpa.destroy(self);
        }

        fn epollWait(_: *Self, buffer: []Event) []Event {
            return buffer[0..0];
        }

        fn handleEpollEvent(_: *Self, _: Event) void {}

        fn handleTask(_: *Self, _: Task) HandleTaskStatus {}
    };
}
