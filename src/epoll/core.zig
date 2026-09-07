const std = @import("std");
const types = @import("types.zig");
const zutil = @import("zutil");

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
    SocketSvc: type,
    CallbackType: type,
    EventFuncs: types.EventFuncs(Event),
    EpollFuncs: types.EpollFuncs(EpollType, Event, FD),
    SocketFuncs: types.SocketFuncs(SocketSvc, FD),
    CallbackFuncs: types.CallbackFuncs(CallbackType),
    comptime max_write_queue_len: usize,
) type {
    const ActionType = types.ActionEntry(FD);
    const ActionQueue = std.Deque(ActionType);

    const buffer_size = 4 * 1024;

    const SocketState = struct {
        const Self = @This();

        socket_fd: FD,

        is_reading: bool = false,
        is_writing: bool = false,
        num_handled_actions: usize = 0,

        client_closed: bool = false,
        server_closed: bool = false,

        tmp_buf: [buffer_size]u8 = undefined,
        tmp_buf_start: usize = 0,
        tmp_buf_end: usize = 0,

        read_size: usize = 0,
        handle_buf: [buffer_size]u8 = undefined,
        handle_buf_len: usize = 0,

        callbacks: CallbackType,

        _write_queue_buffer: [max_write_queue_len][]const u8 = undefined,
        write_queue: types.WriteQueue,

        all_state_list: zutil.ListHead,

        fn getTmpBufLen(self: *Self) usize {
            return self.tmp_buf_end - self.tmp_buf_start;
        }

        fn getTmpBuf(self: *Self) []u8 {
            return self.tmp_buf[self.tmp_buf_start..self.tmp_buf_end];
        }

        fn getHandleBuf(self: *Self) []u8 {
            return self.handle_buf[0..self.handle_buf_len];
        }

        fn fromList(entry: *zutil.ListHead) *Self {
            return @fieldParentPtr("all_state_list", entry);
        }

        fn destroy(self: *Self) void {
            CallbackFuncs.onDeinit(&self.callbacks);
            self.all_state_list.remove();
        }
    };

    return struct {
        const CoreSocketState = SocketState;

        const Task = struct {
            task_type: TaskType,
            state: *SocketState,
        };
        const TaskQueue = std.Deque(Task);
        const StateAlloc = types.StackAllocator(SocketState);

        const Self = @This();

        _epoll: *EpollType,
        _socket_svc: *SocketSvc,
        _action_queue: ActionQueue,
        _task_queue: TaskQueue,
        _yield_queue: TaskQueue,

        _state_alloc: StateAlloc,

        _all_states: zutil.ListHead,
        _eventfd_state: *SocketState,

        // TODO add padding
        _num_active_conns: u64 = 0, // TODO use atomic

        pub fn init(
            gpa: Allocator,
            epoll: *EpollType,
            socket_svc: *SocketSvc,
            eventfd_num: FD,
            max_num_sockets: usize,
        ) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);

            self.* = .{
                ._epoll = epoll,
                ._socket_svc = socket_svc,
                ._action_queue = try .initCapacity(gpa, 16), // 2 is sufficient
                ._task_queue = try .initCapacity(gpa, max_num_sockets * 2 + 1),
                ._yield_queue = try .initCapacity(gpa, max_num_sockets),
                ._state_alloc = try StateAlloc.init(gpa, max_num_sockets + 1),
                ._all_states = undefined,
                ._eventfd_state = undefined,
            };

            self._all_states.initHeader();

            self._eventfd_state = self._state_alloc.create();
            self._eventfd_state.* = .{
                .socket_fd = eventfd_num,
                .callbacks = undefined,
                .write_queue = undefined,
                .all_state_list = undefined,
            };

            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            // destroy all states
            var state_it = self._all_states.iterate();
            while (state_it.next()) |e| {
                const state = SocketState.fromList(e);
                state.destroy();
            }

            std.debug.assert(self._all_states.isEmpty());

            self._state_alloc.deinit(gpa);
            self._yield_queue.deinit(gpa);
            self._task_queue.deinit(gpa);
            self._action_queue.deinit(gpa);

            gpa.destroy(self);
        }

        fn epollWait(self: *Self, buffer: []Event) []Event {
            std.debug.assert(self._task_queue.len == 0);

            // TODO handle with wait
            return EpollFuncs.epollWait(self._epoll, buffer, false);
        }

        fn handleEpollEvent(self: *Self, event: Event) void {
            const data_ptr = EventFuncs.getDataPtr(event);
            const state: *SocketState = @ptrCast(@alignCast(data_ptr));

            if (EventFuncs.hasEpollOut(event)) {
                self.addWriteTask(state, false);
            }

            if (EventFuncs.hasEpollIn(event)) {
                self.addReadTask(state);
            }
        }

        fn addActionQueue(self: *Self, action: ActionType) void {
            self._action_queue.pushBackBounded(action) catch unreachable;
        }

        fn popTaskQueue(self: *Self) ?Task {
            const null_task = self._task_queue.popFront();
            const task = if (null_task) |x| x else {
                return null;
            };

            task.state.is_reading = false;
            task.state.is_writing = false;

            return task;
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

        fn addWriteTask(self: *Self, state: *SocketState, to_front: bool) void {
            if (state.write_queue.count() == 0) {
                return;
            }
            if (state.is_writing) {
                return;
            }

            const task = Task{
                .task_type = .Write,
                .state = state,
            };
            state.is_writing = true;

            if (to_front) {
                self._task_queue.pushFrontBounded(task) catch unreachable;
            } else {
                self._task_queue.pushBackBounded(task) catch unreachable;
            }
        }

        fn handleTask(self: *Self, task: Task) HandleTaskStatus {
            if (task.state == self._eventfd_state) {
                return self.handleTaskEventFD();
            }
            return switch (task.task_type) {
                .Read => self.handleReadSocket(task.state),
                .Write => self.handleWriteSocket(task.state),
            };
        }

        fn handleTaskEventFD(self: *Self) HandleTaskStatus {
            // TODO check num_handled_actions

            const null_action = self._action_queue.popFront();
            const action = if (null_action) |x| x else {
                // TODO clear num handled actions
                // TODO drain eventfd
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
                .read_size = CallbackFuncs.init_read_size,
                .callbacks = CallbackFuncs.onInit(),
                .write_queue = types.WriteQueue.init(&conn_state._write_queue_buffer),
                .all_state_list = undefined,
            };

            // add to all states
            self._all_states.pushBack(&conn_state.all_state_list);

            // add to epoll
            EpollFuncs.epollAdd(self._epoll, new_conn_fd, conn_state);
            self.addReadTask(conn_state);

            const state = self._eventfd_state;
            state.num_handled_actions += 1;
        }

        fn handleReadSocket(self: *Self, state: *SocketState) HandleTaskStatus {
            std.debug.assert(state.read_size > 0);

            if (state.handle_buf_len >= state.read_size) {
                return self.doHandleFullReadData(state);
            }
            if (state.getTmpBufLen() > 0) {
                return self.moveFromTmpBufToHandleBuf(state);
            }
            return self.doReadFromSocket(state);
        }

        fn doHandleFullReadData(_: *Self, state: *SocketState) HandleTaskStatus {
            std.debug.assert(state.getHandleBuf().len == state.read_size);

            var is_finished_action: bool = false;
            const result = CallbackFuncs.onReadData(
                &state.callbacks,
                state.getHandleBuf(),
                &state.write_queue,
                &is_finished_action,
            );

            switch (result) {
                .Ok => |x| {
                    state.read_size = x.next_read_size;
                    state.handle_buf_len = 0;
                    if (is_finished_action) {
                        state.num_handled_actions += 1;
                    }
                    return .Continue;
                },
            }
        }

        fn moveFromTmpBufToHandleBuf(_: *Self, state: *SocketState) HandleTaskStatus {
            const remain = state.read_size - state.handle_buf_len;
            const n = @min(remain, state.getTmpBufLen());

            const start = state.handle_buf_len;
            const end = start + n;
            state.handle_buf_len = end;

            const tmp_start = state.tmp_buf_start;
            const tmp_end = tmp_start + n;
            state.tmp_buf_start = tmp_end;

            @memcpy(state.handle_buf[start..end], state.tmp_buf[tmp_start..tmp_end]);
            return .Continue;
        }

        fn doReadFromSocket(self: *Self, state: *SocketState) HandleTaskStatus {
            state.tmp_buf_start = 0;
            state.tmp_buf_end = 0;

            const read_resp = SocketFuncs.read(
                self._socket_svc,
                state.socket_fd,
                &state.tmp_buf,
            );

            const num_read = if (read_resp) |x| x else |err| {
                switch (err) {
                    types.SocketError.EAGAIN => {
                        self.addWriteTask(state, true);
                        return .Next;
                    },
                    types.SocketError.ConnectionError => {
                        @panic("TODO");
                    },
                }
            };

            std.debug.assert(num_read > 0);
            state.tmp_buf_end = num_read;
            return .Continue;
        }

        fn handleWriteSocket(self: *Self, state: *SocketState) HandleTaskStatus {
            const result = SocketFuncs.write(
                self._socket_svc,
                state.socket_fd,
                &state.write_queue,
            );

            if (result) |total_written_num| {
                var total_written = total_written_num;

                while (true) {
                    const null_data_ptr = state.write_queue.peakWriteFrame();
                    const data_ptr = if (null_data_ptr) |x| x else {
                        break;
                    };
                    const data_len = data_ptr.len;

                    if (total_written >= data_len) {
                        _ = state.write_queue.popWriteFrame();
                        CallbackFuncs.popWriteFrame(&state.callbacks);
                        total_written -= data_len;
                        continue;
                    }

                    // TODO handle sub slice data
                    break;
                }

                std.debug.assert(total_written == 0);
                return .Continue;
            } else |_| {
                @panic("TODO");
            }
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
// Fake Socket Svc
// ===========================================================================

const FakeSocketSvc = struct {
    const Self = @This();
    const ReadMap = std.AutoHashMap(u64, []const u8);
    const WriteData = std.ArrayList(u8);
    const WriteDataMap = std.AutoHashMap(u64, WriteData);

    const write_buffer_len = 6;

    read_map: ReadMap,
    write_data_map: WriteDataMap,

    fn init() Self {
        const gpa = std.testing.allocator;
        return .{
            .read_map = ReadMap.init(gpa),
            .write_data_map = WriteDataMap.init(gpa),
        };
    }

    fn deinit(self: *Self) void {
        const gpa = std.testing.allocator;

        self.read_map.deinit();

        // destroy write map
        var write_iter = self.write_data_map.iterator();
        while (write_iter.next()) |e| {
            e.value_ptr.deinit(gpa);
        }
        self.write_data_map.deinit();
    }

    pub fn read(self: *Self, fd: u64, buffer: []u8) types.SocketError!usize {
        const null_bytes = self.read_map.get(fd);
        const data = if (null_bytes) |x| x else {
            return types.SocketError.EAGAIN;
        };

        @memcpy(buffer[0..data.len], data);
        _ = self.read_map.remove(fd);
        return data.len;
    }

    pub fn write(self: *Self, fd: u64, write_queue: *types.WriteQueue) types.SocketError!usize {
        const gpa = std.testing.allocator;

        const null_entry = self.write_data_map.getEntry(fd);

        var write_data: *WriteData = undefined;
        if (null_entry) |x| {
            write_data = x.value_ptr;
        } else {
            self.write_data_map.put(
                fd,
                WriteData.initCapacity(gpa, write_buffer_len) catch unreachable,
            ) catch unreachable;
            const entry = self.write_data_map.getEntry(fd).?;
            write_data = entry.value_ptr;
        }

        var total_written: usize = 0;
        var iter = write_queue.iterator();
        while (iter.next()) |data| {
            // TODO handle partial write
            write_data.appendSliceBounded(data) catch unreachable;
            total_written += data.len;
        }

        return total_written;
    }
};

// ===========================================================================
// Fake Callbacks
// ===========================================================================

const FakeCallbacks = struct {
    const Self = @This();
    const ReadData = std.ArrayList(u8);
    const State = enum { Step1, Step2, Step3 };

    read_data: ReadData,
    state: State,
    num_writes: usize,
    _frame01: [3]u8 = undefined,
    _frame02: [3]u8 = undefined,

    pub const init_read_size: usize = 1;

    pub fn onInit() Self {
        return .{
            .read_data = .empty,
            .state = .Step1,
            .num_writes = 0,
        };
    }

    pub fn onDeinit(self: *Self) void {
        const gpa = std.testing.allocator;
        self.read_data.deinit(gpa);
    }

    pub fn onReadData(
        self: *Self,
        data: []const u8,
        write_queue: *types.WriteQueue,
        finished: *bool,
    ) types.OnReadResult {
        const gpa = std.testing.allocator;
        self.read_data.appendSlice(gpa, data) catch unreachable;

        switch (self.state) {
            .Step1 => {
                self.state = .Step2;
                return .initOk(3);
            },
            .Step2 => {
                self.state = .Step3;
                return .initOk(2);
            },
            .Step3 => {
                self.state = .Step1;
                finished.* = true;

                const val0: u8 = @intCast(self.num_writes * 3 + 40);
                self.num_writes += 2;

                const data1 = [_]u8{ val0 + 1, val0 + 2, val0 + 3 };
                @memcpy(&self._frame01, &data1);

                const data2 = [_]u8{ val0 + 4, val0 + 5, val0 + 6 };
                @memcpy(&self._frame02, &data2);

                write_queue.addWriteFrame(self._frame01[0..3]);
                write_queue.addWriteFrame(self._frame02[0..3]);

                return .initOk(init_read_size);
            },
        }
    }

    pub fn popWriteFrame(self: *Self) void {
        self.num_writes -= 1;
    }
};

// ===========================================================================
// Testing
// ===========================================================================

const CoreTest = struct {
    const Self = @This();

    const EventFuncs = types.EventFuncs(FakeEvent);
    const EpollFuncs = types.EpollFuncs(FakeEpoll, FakeEvent, u64);
    const SocketFuncs = types.SocketFuncs(FakeSocketSvc, u64);
    const CallbackFuncs = types.CallbackFuncs(FakeCallbacks);

    const CoreType = EpollCore(
        u64,
        FakeEvent,
        FakeEpoll,
        FakeSocketSvc,
        FakeCallbacks,
        EventFuncs.init(),
        EpollFuncs.init(),
        SocketFuncs.init(),
        CallbackFuncs.init(),
        3,
    );

    const Task = CoreType.Task;
    const SocketState = CoreType.CoreSocketState;

    epoll: FakeEpoll,
    socket_svc: FakeSocketSvc,
    core: *CoreType,

    fn init() !*Self {
        const gpa = std.testing.allocator;

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);

        self.* = .{
            .epoll = FakeEpoll.init(gpa),
            .socket_svc = FakeSocketSvc.init(),
            .core = undefined,
        };

        self.core = try CoreType.init(
            gpa,
            &self.epoll,
            &self.socket_svc,
            11,
            3,
        );
        errdefer self.core.deinit();

        return self;
    }

    fn deinit(self: *Self) void {
        const gpa = std.testing.allocator;

        self.core.deinit(gpa);
        self.socket_svc.deinit();
        self.epoll.deinit();

        gpa.destroy(self);
    }

    fn handleEpollEvent(self: *Self, event: FakeEvent) void {
        defer self.checkInvariant();
        self.core.handleEpollEvent(event);
    }

    fn addActionNewConn(self: *Self, fd: u64) void {
        self.core.addActionQueue(.{
            .NewConn = .{ .fd = fd },
        });
    }

    fn popTaskQueue(self: *Self) ?Task {
        defer self.checkInvariant();
        return self.core.popTaskQueue();
    }

    fn handleTask(self: *Self, task: Task) HandleTaskStatus {
        defer self.checkInvariant();

        const status = self.core.handleTask(task);
        if (status == .Next) {
            self.checkOnNextInv(task.state);
        }

        return status;
    }

    fn checkInvariant(self: *Self) void {
        self.checkInvariantErr() catch unreachable;
    }

    fn checkInvariantErr(self: *Self) !void {
        const gpa = std.testing.allocator;

        var running_tasks = std.AutoHashMap(Task, struct {}).init(gpa);
        defer running_tasks.deinit();

        var task_iter = self.core._task_queue.iterator();
        while (task_iter.next()) |task| {
            const state = task.state;
            switch (task.task_type) {
                .Read => {
                    std.debug.assert(state.is_reading);
                },
                .Write => {
                    std.debug.assert(state.is_writing);
                },
            }

            if (state == self.core._eventfd_state) {
                continue;
            }

            std.debug.assert(!running_tasks.contains(task));
            try running_tasks.put(task, .{});

            std.debug.assert(self.core._all_states.containsSlow(&state.all_state_list));
        }

        var state_iter = self.core._all_states.iterate();
        while (state_iter.next()) |x| {
            const state = SocketState.fromList(x);

            std.debug.assert(state.getHandleBuf().len <= state.read_size);
            std.debug.assert(state.callbacks.num_writes == state.write_queue.count());

            if (state.is_reading) {
                std.debug.assert(running_tasks.contains(.{
                    .task_type = .Read,
                    .state = state,
                }));
            }
            if (state.is_writing) {
                std.debug.assert(running_tasks.contains(.{
                    .task_type = .Write,
                    .state = state,
                }));
            }
        }
    }

    fn checkOnNextInv(self: *Self, state: *SocketState) void {
        if (state == self.core._eventfd_state) {
            return;
        }

        if (state.write_queue.count() > 0) {
            std.debug.assert(state.is_writing);
        }
    }

    fn newEpollEventFD(self: *Self) FakeEvent {
        return .{
            .epoll_in = true,
            .epoll_out = false,
            .data_ptr = self.core._eventfd_state,
        };
    }

    fn setReadData(self: *Self, fd: u64, data: []const u8) void {
        self.socket_svc.read_map.put(fd, data) catch unreachable;
    }

    fn newEpollRead(self: *Self, fd: u64) FakeEvent {
        return .{
            .epoll_in = true,
            .epoll_out = false,
            .data_ptr = self.epoll.socket_map.get(fd).?,
        };
    }

    fn addSocketFD(self: *Self, fd: u64) !void {
        // before
        try expectEqual(0, self.core._action_queue.len);
        try expectEqual(0, self.core._task_queue.len);

        self.handleEpollEvent(self.newEpollEventFD());
        self.addActionNewConn(fd);

        // pop and handle task
        const task = self.popTaskQueue().?;
        try expectEqual(HandleTaskStatus.Continue, self.handleTask(task));
        try expectEqual(HandleTaskStatus.Next, self.handleTask(task));

        // after
        try expectEqual(0, self.core._action_queue.len);
    }

    fn handleTaskUntilNext(self: *Self, task: Task) void {
        while (true) {
            const result = self.handleTask(task);
            switch (result) {
                .Next => {
                    return;
                },
                .Continue => {},
            }
        }
    }
};

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "handle epoll event" {
    const s = try CoreTest.init();
    defer s.deinit();

    s.handleEpollEvent(s.newEpollEventFD());
    try expectEqual(1, s.core._task_queue.len);

    // add event fd epoll event again
    s.handleEpollEvent(s.newEpollEventFD());
    try expectEqual(1, s.core._task_queue.len);

    // new socket
    const socket_fd1: u64 = 21;
    s.addActionNewConn(socket_fd1);
    try expectEqual(1, s.core._action_queue.len);

    // pop and handle task
    const task1 = s.popTaskQueue().?;
    try expectEqual(false, task1.state.is_reading);
    try expectEqual(false, task1.state.is_writing);

    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task1));
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(0, s.core._action_queue.len);
    try expectEqual(1, s.core._eventfd_state.num_handled_actions);
    // check socket map
    try expectEqual(1, s.epoll.socket_map.count());
    try expectEqual(true, s.epoll.socket_map.contains(socket_fd1));

    // stub read data
    s.setReadData(socket_fd1, &.{ 31, 32 });

    // pop socket read task
    const task2 = s.popTaskQueue().?;
    try expectEqual(TaskType.Read, task2.task_type);
    try expectEqual(1, task2.state.read_size);

    // handle socket read task
    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task2));
    try expectEqual(2, task2.state.tmp_buf_end);
    try expectEqualSlices(u8, &.{ 31, 32 }, task2.state.getTmpBuf());
    try expectEqualSlices(u8, &.{}, task2.state.getHandleBuf());

    // move from tmp buf to handle buf
    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task2));
    try expectEqual(2, task2.state.tmp_buf_end);
    try expectEqualSlices(u8, &.{32}, task2.state.getTmpBuf());
    try expectEqualSlices(u8, &.{31}, task2.state.getHandleBuf());

    // run callback
    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task2));
    try expectEqual(2, task2.state.tmp_buf_end);
    try expectEqualSlices(u8, &.{32}, task2.state.getTmpBuf());
    try expectEqualSlices(u8, &.{}, task2.state.getHandleBuf());
    try expectEqual(0, s.core._task_queue.len);
    try expectEqualSlices(u8, &.{31}, task2.state.callbacks.read_data.items);
    try expectEqual(3, task2.state.read_size); // new read size
    try expectEqual(0, task2.state.num_handled_actions);

    // move from tmp buf to handle buf again
    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task2));
    try expectEqual(2, task2.state.tmp_buf_end);
    try expectEqualSlices(u8, &.{}, task2.state.getTmpBuf());
    try expectEqualSlices(u8, &.{32}, task2.state.getHandleBuf());
    try expectEqual(3, task2.state.read_size);

    // read with EAGAIN
    try expectEqual(HandleTaskStatus.Next, s.handleTask(task2));
    try expectEqualSlices(u8, &.{32}, task2.state.getHandleBuf());
    try expectEqual(3, task2.state.read_size);
    try expectEqual(0, s.core._task_queue.len);
    try expectEqual(false, task2.state.is_reading);

    // handle epoll read event
    s.handleEpollEvent(s.newEpollRead(socket_fd1));
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(true, task2.state.is_reading);

    // pop socket read task
    const task3 = s.popTaskQueue().?;
    try expectEqual(task2, task3);

    // set and handle new data
    s.setReadData(socket_fd1, &.{ 33, 34 });
    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task3));
    try expectEqual(0, task3.state.tmp_buf_start);
    try expectEqual(2, task3.state.tmp_buf_end);
    try expectEqualSlices(u8, &.{ 33, 34 }, task3.state.getTmpBuf());
    try expectEqualSlices(u8, &.{32}, task3.state.getHandleBuf());

    // move to handle buf and handle
    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task3));
    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task3));
    try expectEqualSlices(u8, &.{}, task3.state.getTmpBuf());
    try expectEqualSlices(u8, &.{}, task3.state.getHandleBuf());
    try expectEqualSlices(u8, &.{ 31, 32, 33, 34 }, task3.state.callbacks.read_data.items);
    try expectEqual(0, s.core._task_queue.len);
}

test "fully read action, with write queue" {
    const s = try CoreTest.init();
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    s.setReadData(socket_fd1, &.{ 31, 32, 33, 34, 35, 36 });
    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    // check after finish first action
    try expectEqualSlices(
        u8,
        &.{ 31, 32, 33, 34, 35, 36 },
        read_task1.state.callbacks.read_data.items,
    );
    try expectEqual(1, read_task1.state.num_handled_actions);
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(2, read_task1.state.write_queue.count());

    // try to add write task again
    s.handleTaskUntilNext(read_task1);
    try expectEqual(1, s.core._task_queue.len);

    // pop write task
    const write_task1 = s.popTaskQueue().?;
    try expectEqual(.Write, write_task1.task_type);
    try expectEqual(false, write_task1.state.is_writing);
    // handle write
    try expectEqual(.Continue, s.handleTask(write_task1));
    try expectEqualSlices(
        u8,
        &.{ 41, 42, 43, 44, 45, 46 },
        s.socket_svc.write_data_map.get(socket_fd1).?.items,
    );
}
