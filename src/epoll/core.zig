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
    EventFuncs: types.EventFuncs(Event),
) type {
    const ActionQueue = std.Deque(types.ActionEntry(FD));

    const buffer_size = 4 * 1024;

    const SocketState = struct {
        socket_fd: FD,

        is_reading: bool = false,
        is_writing: bool = false,

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
        _eventfd_state: *SocketState,
        _action_queue: ActionQueue,
        _task_queue: TaskQueue,
        _yield_queue: TaskQueue,

        // TODO add padding
        _num_active_conns: u64 = 0, // TODO use atomic

        pub fn init(
            gpa: Allocator,
            eventfd_num: FD,
            max_num_sockets: usize,
        ) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);

            const eventfd_state = try gpa.create(SocketState);
            errdefer gpa.destroy(eventfd_state);

            eventfd_state.* = .{
                .socket_fd = eventfd_num,
            };

            self.* = .{
                ._gpa = gpa,
                ._eventfd_state = eventfd_state,
                ._action_queue = try .initCapacity(gpa, 16), // 2 is sufficient
                ._task_queue = try .initCapacity(gpa, max_num_sockets * 2 + 1),
                ._yield_queue = try .initCapacity(gpa, max_num_sockets),
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            const gpa = self._gpa;

            self._yield_queue.deinit(gpa);
            self._task_queue.deinit(gpa);
            self._action_queue.deinit(gpa);

            gpa.destroy(self._eventfd_state);
            gpa.destroy(self);
        }

        fn epollWait(_: *Self, buffer: []Event) []Event {
            return buffer[0..0];
        }

        fn handleEpollEvent(self: *Self, event: Event) void {
            const data_ptr = EventFuncs.getDataPtr(event);
            const state: *SocketState = @ptrCast(@alignCast(data_ptr));

            if (EventFuncs.hasEpollIn(event)) {
                self.addReadTask(state);
            }

            if (EventFuncs.hasEpollOut(event)) {
                self.addWriteTask(state);
            }
        }

        fn addReadTask(self: *Self, state: *SocketState) void {
            if (state.is_reading) {
                return;
            }

            const task = Task{
                .task_type = .Read,
                .state = state,
            };
            state.is_reading = true;
            self._task_queue.pushBackBounded(task) catch unreachable;
        }

        fn addWriteTask(self: *Self, state: *SocketState) void {
            const task = Task{
                .task_type = .Write,
                .state = state,
            };
            self._task_queue.pushBackBounded(task) catch unreachable;
        }

        fn handleTask(_: *Self, _: Task) HandleTaskStatus {}
    };
}

// ===========================================================================
// Fake Objects
// ===========================================================================

const FakeEvent = struct {
    epoll_in: bool,
    epoll_out: bool,
    data_ptr: *anyopaque,

    const Self = @This();

    pub fn hasEpollIn(self: Self) bool {
        return self.epoll_in;
    }

    pub fn hasEpollOut(self: Self) bool {
        return self.epoll_out;
    }

    pub fn getDataPtr(self: Self) *anyopaque {
        return self.data_ptr;
    }
};

// ===========================================================================
// Testing
// ===========================================================================

const CoreTest = struct {
    const Self = @This();

    const EventFuncs = types.EventFuncs(FakeEvent);
    const CoreType = EpollCore(u64, FakeEvent, EventFuncs.init());

    core: *CoreType,

    fn init() !*Self {
        const gpa = std.testing.allocator;

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);

        const core = try CoreType.init(gpa, 11, 3);
        errdefer core.deinit();

        self.* = .{
            .core = core,
        };

        return self;
    }

    fn deinit(self: *Self) void {
        const gpa = std.testing.allocator;

        self.core.deinit();
        gpa.destroy(self);
    }

    fn handleEpollEvent(self: *Self, event: FakeEvent) void {
        self.core.handleEpollEvent(event);
    }

    fn newEpollEventFD(self: *Self) FakeEvent {
        return .{
            .epoll_in = true,
            .epoll_out = false,
            .data_ptr = self.core._eventfd_state,
        };
    }
};

const expectEqual = std.testing.expectEqual;

test "handle epoll event" {
    const s = try CoreTest.init();
    defer s.deinit();

    s.handleEpollEvent(s.newEpollEventFD());
    try expectEqual(1, s.core._task_queue.len);

    // add event fd epoll event again
    s.handleEpollEvent(s.newEpollEventFD());
    try expectEqual(1, s.core._task_queue.len);
}
