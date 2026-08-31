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
        _eventfd_state: *SocketState,
        _action_queue: ActionQueue,
        _task_queue: TaskQueue,
        _yield_queue: TaskQueue,

        // TODO add padding
        _num_active_conns: u64 = 0, // TODO use atomic

        pub fn init(gpa: Allocator, eventfd_num: FD) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);

            const eventfd_state = try gpa.create(SocketState);
            errdefer gpa.destroy(eventfd_state);

            eventfd_state.* = .{
                .is_eventfd = true,
                .socket_fd = eventfd_num,
            };

            self.* = .{
                ._gpa = gpa,
                ._eventfd_state = eventfd_state,
                ._action_queue = .empty,
                ._task_queue = .empty,
                ._yield_queue = .empty,
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            const gpa = self._gpa;

            gpa.destroy(self._eventfd_state);
            gpa.destroy(self);
        }

        fn epollWait(_: *Self, buffer: []Event) []Event {
            return buffer[0..0];
        }

        fn handleEpollEvent(self: *Self, event: Event) void {
            const data_ptr = EventFuncs.getDataPtr(event);
            const state: *SocketState = @ptrCast(@alignCast(data_ptr));
            if (state == self._eventfd_state) {
                // TODO handle
                return;
            }
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

        const core = try CoreType.init(gpa, 11);
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
};

test "handle epoll event" {
    const s = try CoreTest.init();
    defer s.deinit();

    const event = FakeEvent{
        .epoll_in = true,
        .epoll_out = false,
        .data_ptr = s.core._eventfd_state,
    };
    s.handleEpollEvent(event);
}
