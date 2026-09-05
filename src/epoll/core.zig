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
    EpollType: type,
    EventFuncs: types.EventFuncs(Event),
    EpollFuncs: types.EpollFuncs(EpollType, Event, FD),
) type {
    const ActionType = types.ActionEntry(FD);
    const ActionQueue = std.Deque(ActionType);

    const buffer_size = 4 * 1024;

    const SocketState = struct {
        socket_fd: FD,

        is_reading: bool = false,
        is_writing: bool = false,
        num_handled_actions: usize = 0,

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

    return struct {
        const Task = struct {
            task_type: TaskType,
            state: *SocketState,
        };
        const TaskQueue = std.Deque(Task);
        const StateAlloc = types.StackAllocator(SocketState);
        const Self = @This();

        _epoll: *EpollType,
        _action_queue: ActionQueue,
        _task_queue: TaskQueue,
        _yield_queue: TaskQueue,
        _state_alloc: StateAlloc,
        _eventfd_state: *SocketState,

        // TODO add padding
        _num_active_conns: u64 = 0, // TODO use atomic

        pub fn init(
            gpa: Allocator,
            epoll: *EpollType,
            eventfd_num: FD,
            max_num_sockets: usize,
        ) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);

            self.* = .{
                ._epoll = epoll,
                ._action_queue = try .initCapacity(gpa, 16), // 2 is sufficient
                ._task_queue = try .initCapacity(gpa, max_num_sockets * 2 + 1),
                ._yield_queue = try .initCapacity(gpa, max_num_sockets),
                ._state_alloc = try StateAlloc.init(gpa, max_num_sockets + 1),
                ._eventfd_state = undefined,
            };

            self._eventfd_state = self._state_alloc.create();
            self._eventfd_state.* = .{
                .socket_fd = eventfd_num,
            };

            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self._state_alloc.deinit(gpa);
            self._yield_queue.deinit(gpa);
            self._task_queue.deinit(gpa);
            self._action_queue.deinit(gpa);

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

        fn addActionQueue(self: *Self, action: ActionType) void {
            self._action_queue.pushBackBounded(action) catch unreachable;
        }

        fn popTaskQueue(self: *Self) ?Task {
            return self._task_queue.popFront();
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

        fn handleTask(self: *Self, task: Task) HandleTaskStatus {
            if (task.state == self._eventfd_state) {
                return self.handleTaskEventFD();
            }
            return .Next;
        }

        fn handleTaskEventFD(self: *Self) HandleTaskStatus {
            // TODO check num_handled_actions

            const null_action = self._action_queue.popFront();
            const action = if (null_action) |x| x else {
                // TODO clear num handled actions
                return .Next;
            };

            switch (action) {
                .NewConn => |new_conn| {
                    self.handleNewConn(new_conn.fd);
                    return .Continue;
                },
                .Shutdown => {
                    @panic("TODO");
                },
            }
        }

        fn handleNewConn(self: *Self, new_conn_fd: FD) void {
            const conn_state = self._state_alloc.create();
            conn_state.* = .{
                .socket_fd = new_conn_fd,
            };

            // add to epoll
            EpollFuncs.epollAdd(self._epoll, new_conn_fd, conn_state);
            self.addReadTask(conn_state);

            const state = self._eventfd_state;
            state.num_handled_actions += 1;
        }
    };
}

// ===========================================================================
// Fake Event
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
// Fake Epoll
// ===========================================================================

const FakeEpoll = struct {
    const Self = @This();
    const SocketMap = std.AutoHashMap(u64, *anyopaque);

    socket_map: SocketMap,

    fn init(gpa: Allocator) Self {
        return .{
            .socket_map = SocketMap.init(gpa),
        };
    }

    fn deinit(self: *Self) void {
        self.socket_map.deinit();
    }

    pub fn epollWait(_: *Self, buffer: []FakeEvent, _: bool) []FakeEvent {
        return buffer[0..0];
    }

    pub fn epollAdd(self: *Self, fd: u64, data_ptr: *anyopaque) void {
        self.socket_map.put(fd, data_ptr) catch unreachable;
    }

    pub fn epollRemove(_: *Self, _: u64) void {}
};

// ===========================================================================
// Testing
// ===========================================================================

const CoreTest = struct {
    const Self = @This();

    const EventFuncs = types.EventFuncs(FakeEvent);
    const EpollFuncs = types.EpollFuncs(FakeEpoll, FakeEvent, u64);

    const CoreType = EpollCore(
        u64,
        FakeEvent,
        FakeEpoll,
        EventFuncs.init(),
        EpollFuncs.init(),
    );

    epoll: FakeEpoll,
    core: *CoreType,

    fn init() !*Self {
        const gpa = std.testing.allocator;

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);

        self.* = .{
            .epoll = FakeEpoll.init(gpa),
            .core = undefined,
        };

        self.core = try CoreType.init(
            gpa,
            &self.epoll,
            11,
            3,
        );
        errdefer self.core.deinit();

        return self;
    }

    fn deinit(self: *Self) void {
        const gpa = std.testing.allocator;

        self.core.deinit(gpa);
        self.epoll.deinit();

        gpa.destroy(self);
    }

    fn handleEpollEvent(self: *Self, event: FakeEvent) void {
        self.core.handleEpollEvent(event);
    }

    fn addActionNewConn(self: *Self, fd: u64) void {
        self.core.addActionQueue(.{ .NewConn = .{ .fd = fd } });
    }

    fn popTaskQueue(self: *Self) ?CoreType.Task {
        return self.core.popTaskQueue();
    }

    fn handleTask(self: *Self, task: CoreType.Task) HandleTaskStatus {
        return self.core.handleTask(task);
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

    // new socket
    s.addActionNewConn(21);
    try expectEqual(1, s.core._action_queue.len);

    // pop and handle task
    const task1 = s.popTaskQueue().?;
    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task1));
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(0, s.core._action_queue.len);
    try expectEqual(1, s.core._eventfd_state.num_handled_actions);
    // check socket map
    try expectEqual(1, s.epoll.socket_map.count());
    try expectEqual(true, s.epoll.socket_map.contains(21));
}
