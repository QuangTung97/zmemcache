const std = @import("std");
const types = @import("types.zig");
const zutil = @import("zutil");
const zatomic = zutil.atomic;

const Allocator = std.mem.Allocator;

const TaskType = enum { Read, Write };

const HandleTaskStatus = enum {
    Continue, // loop right away
    Next, // go to the next task
};

fn assertImply(a: bool, b: bool) void {
    std.debug.assert(!a or b);
}

pub fn EpollCore(
    FD: type,
    Event: type,
    EpollType: type,
    EventFdType: type,
    SocketSvc: type,
    CallbackType: type,
    EventFuncs: types.EventFuncs(Event),
    EpollFuncs: types.EpollFuncs(EpollType, Event, FD),
    EventFdFuncs: types.EventFdFuncs(EventFdType, FD),
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
        reading_yielded: bool = false,

        write_queue_full: bool = false,
        socket_send_full: bool = false,

        num_consecutive_read: usize = 0,

        is_closed: bool = false,

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

        fn isActive(self: *Self) bool {
            if (self.is_reading) {
                return true;
            }
            if (self.is_writing) {
                return true;
            }
            if (self.reading_yielded) {
                return true;
            }
            return false;
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

        _io: std.Io,
        _epoll: *EpollType,
        _eventfd_svc: *EventFdType,
        _socket_svc: *SocketSvc,

        _write_queue_capacity: usize,
        _max_consecutive_read: usize,
        _max_total_read_before_yield: usize,

        _action_queue: ActionQueue,
        _action_queue_mut: std.Io.Mutex,
        _action_queue_cond: std.Io.Condition,

        _task_queue: TaskQueue,
        _yield_queue: TaskQueue,

        _state_alloc: StateAlloc,
        _all_states: zutil.ListHead,
        _eventfd_state: *SocketState,

        _padding1: [64]u8 = undefined,
        _num_active_conns: zatomic.Value(u64) = .init(0),

        _total_num_read: usize = 0,

        pub const Config = struct {
            max_num_sockets: usize,
            write_queue_capacity: usize,
            max_consecutive_read: usize,
            max_total_read_before_yield: usize,
        };

        pub fn init(
            io: std.Io,
            gpa: Allocator,
            epoll: *EpollType,
            eventfd_svc: *EventFdType,
            socket_svc: *SocketSvc,
            eventfd_num: FD,
            config: Config,
        ) !*Self {
            zutil.runtimeAssert(config.write_queue_capacity <= max_write_queue_len);

            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);

            self.* = .{
                ._io = io,
                ._epoll = epoll,
                ._eventfd_svc = eventfd_svc,
                ._socket_svc = socket_svc,

                ._write_queue_capacity = config.write_queue_capacity,
                ._max_consecutive_read = config.max_consecutive_read,
                ._max_total_read_before_yield = config.max_total_read_before_yield,

                ._action_queue = try .initCapacity(gpa, 64),
                ._action_queue_mut = .init,
                ._action_queue_cond = .init,

                ._task_queue = try .initCapacity(gpa, config.max_num_sockets * 2 + 1),
                ._yield_queue = try .initCapacity(gpa, config.max_num_sockets),

                ._state_alloc = try StateAlloc.init(
                    gpa,
                    config.max_num_sockets + 1,
                ),
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

                state.is_reading = false;
                state.is_writing = false;
                state.reading_yielded = false;
                self.doDestroySocket(state);
            }

            std.debug.assert(self._all_states.isEmpty());
            std.debug.assert(self._state_alloc.getNumInUse() == 1);

            self._state_alloc.deinit(gpa);
            self._yield_queue.deinit(gpa);
            self._task_queue.deinit(gpa);
            self._action_queue.deinit(gpa);

            gpa.destroy(self);
        }

        pub fn epollWait(self: *Self, buffer: []Event) []Event {
            std.debug.assert(self._task_queue.len == 0);

            // yield queue not empty => does not wait
            const with_wait = self._yield_queue.len == 0;

            return EpollFuncs.epollWait(self._epoll, buffer, with_wait);
        }

        pub fn handleEpollEvent(self: *Self, event: Event) void {
            const data_ptr = EventFuncs.getDataPtr(event);
            const state: *SocketState = @ptrCast(@alignCast(data_ptr));

            if (EventFuncs.hasEpollOut(event)) {
                self.addWriteTask(state, .EpollOut);
            }

            if (EventFuncs.hasEpollIn(event)) {
                self.addReadTask(state);
            }
        }

        pub fn moveFromYieldQueueToTaskQueue(self: *Self) void {
            while (self.popYieldQueue()) |task| {
                self.addReadTask(task.state);
            }
        }

        pub fn addNewSocket(self: *Self, socket_fd: FD) void {
            _ = self._num_active_conns.fetchAdd(1);
            self.addActionQueue(.{
                .NewConn = .{
                    .fd = socket_fd,
                },
            });
        }

        pub fn shutdown(self: *Self) void {
            self.addActionQueue(.{
                .Shutdown = .{},
            });
        }

        fn addActionQueue(self: *Self, action: ActionType) void {
            const is_first = self.addActionQueueLocked(action);
            if (is_first) {
                EventFdFuncs.inc(self._eventfd_svc, self._eventfd_state.socket_fd);
            }
        }

        fn addActionQueueLocked(self: *Self, action: ActionType) bool {
            self._action_queue_mut.lockUncancelable(self._io);
            defer self._action_queue_mut.unlock(self._io);

            while (self._action_queue.len >= self._action_queue.buffer.len) {
                self._action_queue_cond.waitUncancelable(self._io, &self._action_queue_mut);
            }

            const is_first = self._action_queue.len == 0;
            self._action_queue.pushBackBounded(action) catch unreachable;

            return is_first;
        }

        fn popFromActionQueue(self: *Self) ?ActionType {
            self._action_queue_mut.lockUncancelable(self._io);
            defer self._action_queue_mut.unlock(self._io);

            defer self._action_queue_cond.signal(self._io);

            return self._action_queue.popFront();
        }

        pub fn handleTaskQueue(self: *Self) void {
            self._total_num_read = 0; // clear before loop

            while (self.popTaskQueue()) |task| {
                while (true) {
                    const result = self.handleTask(task);
                    switch (result) {
                        .Continue => {
                            continue;
                        },
                        .Next => {
                            break;
                        },
                    }
                }
            }
        }

        fn popTaskQueue(self: *Self) ?Task {
            const null_task = self._task_queue.popFront();
            const task = if (null_task) |x| x else {
                return null;
            };

            switch (task.task_type) {
                .Read => {
                    task.state.is_reading = false;
                },
                .Write => {
                    task.state.is_writing = false;
                },
            }

            return task;
        }

        fn addReadTask(self: *Self, state: *SocketState) void {
            std.debug.assert(!state.reading_yielded);

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

        fn yieldReadTask(self: *Self, state: *SocketState) void {
            std.debug.assert(!state.is_reading);
            std.debug.assert(!state.reading_yielded);

            const task = Task{
                .task_type = .Read,
                .state = state,
            };
            state.reading_yielded = true;
            self._yield_queue.pushBackBounded(task) catch unreachable;
        }

        fn popYieldQueue(self: *Self) ?Task {
            const null_task = self._yield_queue.popFront();
            const task = if (null_task) |x| x else {
                return null;
            };

            std.debug.assert(task.task_type == .Read);
            task.state.reading_yielded = false;

            return task;
        }

        const AddWriteFrom = enum { EpollOut, AfterRead };

        fn addWriteTask(self: *Self, state: *SocketState, from: AddWriteFrom) void {
            if (state.write_queue.count() == 0) {
                return;
            }
            if (state.is_writing) {
                return;
            }
            if (from == .AfterRead and state.socket_send_full) {
                return;
            }

            const task = Task{
                .task_type = .Write,
                .state = state,
            };
            state.is_writing = true;
            state.socket_send_full = false;

            switch (from) {
                .EpollOut => {
                    self._task_queue.pushBackBounded(task) catch unreachable;
                },
                .AfterRead => {
                    self._task_queue.pushFrontBounded(task) catch unreachable;
                },
            }
        }

        fn handleTask(self: *Self, task: Task) HandleTaskStatus {
            if (task.state == self._eventfd_state) {
                return self.handleTaskEventFD();
            }

            const state = task.state;
            if (state.is_closed) {
                return self.doCloseSocket(state);
            }

            return switch (task.task_type) {
                .Read => self.handleReadSocket(state),
                .Write => self.handleWriteSocket(state),
            };
        }

        fn handleTaskEventFD(self: *Self) HandleTaskStatus {
            const null_action = self.popFromActionQueue();
            const action = if (null_action) |x| x else {
                EventFdFuncs.drain(self._eventfd_svc, self._eventfd_state.socket_fd);
                return .Next;
            };

            switch (action) {
                .NewConn => |new_conn| {
                    self.handleNewConn(new_conn.fd);
                    return .Continue;
                },
                .Shutdown => {
                    var state_iter = self._all_states.iterate();
                    while (state_iter.next()) |e| {
                        const state = SocketState.fromList(e);
                        _ = self.doCloseSocket(state);
                    }
                    return .Continue;
                },
            }
        }

        fn handleNewConn(self: *Self, new_conn_fd: FD) void {
            const conn_state = self._state_alloc.create();
            conn_state.* = .{
                .socket_fd = new_conn_fd,
                .read_size = CallbackFuncs.init_read_size,
                .callbacks = CallbackFuncs.onInit(),
                .write_queue = types.WriteQueue.init(
                    conn_state._write_queue_buffer[0..self._write_queue_capacity],
                ),
                .all_state_list = undefined,
            };

            // add to all states
            self._all_states.pushBack(&conn_state.all_state_list);

            // add to epoll
            EpollFuncs.epollAdd(self._epoll, new_conn_fd, conn_state);
            self.addReadTask(conn_state);
        }

        fn handleReadSocket(self: *Self, state: *SocketState) HandleTaskStatus {
            std.debug.assert(state.read_size > 0);
            std.debug.assert(!state.is_closed);

            if (self._total_num_read >= self._max_total_read_before_yield) {
                self.yieldReadTask(state);
                return self.doReadReturnNext(state);
            }

            if (state.num_consecutive_read >= self._max_consecutive_read) {
                self.addReadTask(state);
                return self.doReadReturnNext(state);
            }

            if (state.handle_buf_len >= state.read_size) {
                return self.doHandleFullReadData(state);
            }
            if (state.getTmpBufLen() > 0) {
                return self.moveFromTmpBufToHandleBuf(state);
            }
            return self.doReadFromSocket(state);
        }

        fn doReadReturnNext(self: *Self, state: *SocketState) HandleTaskStatus {
            self.addWriteTask(state, .AfterRead);
            state.num_consecutive_read = 0;
            return .Next;
        }

        fn doHandleFullReadData(self: *Self, state: *SocketState) HandleTaskStatus {
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
                    if (!is_finished_action) {
                        return .Continue;
                    }

                    state.num_consecutive_read += 1;
                    self._total_num_read += 1;

                    return .Continue;
                },
                .WaitWriteQueue => {
                    state.write_queue_full = true;
                    return self.doReadReturnNext(state);
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
                        return self.doReadReturnNext(state);
                    },
                    types.SocketError.ConnectionError => {
                        return self.doCloseSocket(state);
                    },
                }
            };

            std.debug.assert(num_read > 0);
            state.tmp_buf_end = num_read;
            return .Continue;
        }

        fn handleWriteSocket(self: *Self, state: *SocketState) HandleTaskStatus {
            std.debug.assert(!state.is_closed);

            if (state.write_queue.count() == 0) {
                return .Next;
            }

            const result = SocketFuncs.write(
                self._socket_svc,
                state.socket_fd,
                &state.write_queue,
            );

            if (result) |total_written| {
                return self.writeSocketPopWriteFrames(state, total_written);
            } else |err| {
                switch (err) {
                    types.SocketError.EAGAIN => {
                        state.socket_send_full = true;
                        return .Next;
                    },
                    types.SocketError.ConnectionError => {
                        return self.doCloseSocket(state);
                    },
                }
            }
        }

        fn writeSocketPopWriteFrames(self: *Self, state: *SocketState, total_written: usize) HandleTaskStatus {
            var num_bytes = total_written;
            while (num_bytes > 0) {
                const null_data_ptr = state.write_queue.peakWriteFrame();
                const data_ptr = if (null_data_ptr) |x| x else {
                    break;
                };
                const data_len = data_ptr.len;

                if (num_bytes < data_len) {
                    data_ptr.* = data_ptr.*[num_bytes..]; // sub-slice the remaining
                    break;
                }

                _ = state.write_queue.popWriteFrame();
                CallbackFuncs.popWriteFrame(&state.callbacks);
                num_bytes -= data_len;

                if (state.write_queue_full) {
                    state.write_queue_full = false;
                    self.addReadTask(state);
                }
            }
            return .Continue;
        }

        fn doCloseSocket(self: *Self, state: *SocketState) HandleTaskStatus {
            state.is_closed = true;
            self.doDestroySocket(state);
            return .Next;
        }

        fn doDestroySocket(self: *Self, state: *SocketState) void {
            if (state.isActive()) {
                return;
            }

            // pop all write frames
            while (state.write_queue.popWriteFrame()) |_| {
                CallbackFuncs.popWriteFrame(&state.callbacks);
            }

            CallbackFuncs.onDeinit(&state.callbacks);

            state.all_state_list.remove();
            self._state_alloc.destroy(state);

            // remove from epoll first
            EpollFuncs.epollRemove(self._epoll, state.socket_fd);

            // then close socket
            SocketFuncs.close(self._socket_svc, state.socket_fd);

            _ = self._num_active_conns.fetchSub(1);
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

    pub fn epollRemove(self: *Self, fd: u64) void {
        const ok = self.socket_map.remove(fd);
        std.debug.assert(ok);
    }
};

// ===========================================================================
// Fake EventFd
// ===========================================================================

const FakeEventFd = struct {
    const Self = @This();

    eventfd: u64,
    counter: usize,

    pub fn init(num: u64) Self {
        return .{
            .eventfd = num,
            .counter = 0,
        };
    }

    pub fn inc(self: *Self, fd: u64) void {
        std.debug.assert(fd == self.eventfd);
        self.counter += 1;
    }

    pub fn drain(self: *Self, fd: u64) void {
        std.debug.assert(fd == self.eventfd);
        self.counter = 0;
    }
};

// ===========================================================================
// Fake Socket Svc
// ===========================================================================

const FakeSocketSvc = struct {
    const Self = @This();
    const ReadMap = std.AutoHashMap(u64, []const u8);
    const WriteData = std.ArrayList(u8);
    const WriteDataMap = std.AutoHashMap(u64, WriteData);
    const CloseMap = std.AutoHashMap(u64, struct {});

    read_map: ReadMap,
    write_data_map: WriteDataMap,
    write_buffer_len: usize,
    is_closed_map: CloseMap,

    fn init(write_len: usize) Self {
        const gpa = std.testing.allocator;
        return .{
            .read_map = ReadMap.init(gpa),
            .write_data_map = WriteDataMap.init(gpa),
            .write_buffer_len = write_len,
            .is_closed_map = CloseMap.init(gpa),
        };
    }

    fn deinit(self: *Self) void {
        const gpa = std.testing.allocator;

        // destroy write map
        var write_iter = self.write_data_map.iterator();
        while (write_iter.next()) |e| {
            e.value_ptr.deinit(gpa);
        }
        self.write_data_map.deinit();

        self.is_closed_map.deinit();
        self.read_map.deinit();
    }

    pub fn read(self: *Self, fd: u64, buffer: []u8) types.SocketError!usize {
        if (self.is_closed_map.contains(fd)) {
            return types.SocketError.ConnectionError;
        }

        const null_bytes = self.read_map.get(fd);
        const data = if (null_bytes) |x| x else {
            return types.SocketError.EAGAIN;
        };

        @memcpy(buffer[0..data.len], data);
        _ = self.read_map.remove(fd);
        return data.len;
    }

    pub fn write(self: *Self, fd: u64, write_queue: *types.WriteQueue) types.SocketError!usize {
        std.debug.assert(write_queue.count() > 0);

        if (self.is_closed_map.contains(fd)) {
            return types.SocketError.ConnectionError;
        }

        var total_written: usize = 0;

        const write_data = self.getWriteDataList(fd);
        var iter = write_queue.iterator();
        while (iter.next()) |data| {
            const remain = write_data.capacity - write_data.items.len;
            if (remain == 0) {
                break;
            }
            const num = @min(data.len, remain);
            write_data.appendSliceBounded(data[0..num]) catch unreachable;
            total_written += num;
        }

        if (total_written == 0) {
            return types.SocketError.EAGAIN;
        }

        return total_written;
    }

    pub fn getWriteDataList(self: *Self, fd: u64) *WriteData {
        const gpa = std.testing.allocator;

        const null_entry = self.write_data_map.getEntry(fd);
        if (null_entry) |x| {
            return x.value_ptr;
        }

        self.write_data_map.put(
            fd,
            WriteData.initCapacity(
                gpa,
                self.write_buffer_len,
            ) catch unreachable,
        ) catch unreachable;

        const entry = self.write_data_map.getEntry(fd).?;
        return entry.value_ptr;
    }

    pub fn close(self: *Self, fd: u64) void {
        const gpa = std.testing.allocator;

        _ = self.read_map.remove(fd);

        const write_data = self.write_data_map.getEntry(fd);
        if (write_data) |entry| {
            entry.value_ptr.deinit(gpa);
            _ = self.write_data_map.remove(fd);
        }

        _ = self.is_closed_map.remove(fd);
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
    cmd_num: usize,
    _frame01: [3]u8 = undefined,
    _frame02: [3]u8 = undefined,

    pub const init_read_size: usize = 1;

    pub fn onInit() Self {
        return .{
            .read_data = .empty,
            .state = .Step1,
            .num_writes = 0,
            .cmd_num = 0,
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
                if (!write_queue.allowNumItems(2)) {
                    return .{ .WaitWriteQueue = .{} };
                }

                self.state = .Step1;
                finished.* = true;

                const val0: u8 = @intCast(self.cmd_num * 6 + 40);
                self.num_writes += 2;
                self.cmd_num += 1;

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
    const EventFdFuncs = types.EventFdFuncs(FakeEventFd, u64);
    const SocketFuncs = types.SocketFuncs(FakeSocketSvc, u64);
    const CallbackFuncs = types.CallbackFuncs(FakeCallbacks);

    const CoreType = EpollCore(
        u64,
        FakeEvent,
        FakeEpoll,
        FakeEventFd,
        FakeSocketSvc,
        FakeCallbacks,
        EventFuncs.init(),
        EpollFuncs.init(),
        EventFdFuncs.init(),
        SocketFuncs.init(),
        CallbackFuncs.init(),
        50,
    );

    const Task = CoreType.Task;
    const SocketState = CoreType.CoreSocketState;

    epoll: FakeEpoll,
    eventfd: FakeEventFd,
    socket_svc: FakeSocketSvc,
    core: *CoreType,

    const Config = struct {
        write_queue_capacity: usize = 50,
        max_consecutive_read: usize = 1000,
        max_total_read_before_yield: usize = 1000,
        socket_send_buffer_size: usize = 100,
    };

    fn init(config: Config) !*Self {
        const io = std.testing.io;
        const gpa = std.testing.allocator;

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);

        const eventfd_num: u64 = 11;

        self.* = .{
            .epoll = FakeEpoll.init(gpa),
            .eventfd = FakeEventFd.init(eventfd_num),
            .socket_svc = FakeSocketSvc.init(config.socket_send_buffer_size),
            .core = undefined,
        };

        self.core = try CoreType.init(
            io,
            gpa,
            &self.epoll,
            &self.eventfd,
            &self.socket_svc,
            eventfd_num,
            .{
                .max_num_sockets = 3,
                .write_queue_capacity = config.write_queue_capacity,
                .max_consecutive_read = config.max_consecutive_read,
                .max_total_read_before_yield = config.max_total_read_before_yield,
            },
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

    fn addNewSocket(self: *Self, fd: u64) void {
        self.core.addNewSocket(fd);
    }

    fn popTaskQueue(self: *Self) ?Task {
        return self.core.popTaskQueue();
    }

    fn popYieldQueue(self: *Self) ?Task {
        return self.core.popYieldQueue();
    }

    fn addReadTask(self: *Self, state: *SocketState) void {
        defer self.checkInvariant();
        self.core.addReadTask(state);
    }

    fn handleTask(self: *Self, task: Task) HandleTaskStatus {
        defer self.checkInvariant();

        const status = self.core.handleTask(task);

        // check on next
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

        // --------------------------------
        // iterate task queue
        // --------------------------------
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

        // --------------------------------
        // iterate all states
        // --------------------------------
        var state_iter = self.core._all_states.iterate();
        var num_states: u64 = 0;
        while (state_iter.next()) |x| {
            num_states += 1;
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

            assertImply(state.write_queue_full, !state.is_reading);
            assertImply(state.socket_send_full, !state.is_writing);
            assertImply(state.reading_yielded, !state.is_reading);

            assertImply(state.is_closed, state.isActive());
        }

        std.debug.assert(self.core._num_active_conns.load() >= num_states);

        // --------------------------------
        // iterate yield queue
        // --------------------------------
        var yield_iter = self.core._yield_queue.iterator();
        while (yield_iter.next()) |task| {
            std.debug.assert(task.task_type == .Read);
            const state = task.state;
            std.debug.assert(state.reading_yielded);
            std.debug.assert(self.core._all_states.containsSlow(&state.all_state_list));
        }
    }

    fn checkOnNextInv(self: *Self, state: *SocketState) void {
        if (state == self.core._eventfd_state) {
            return;
        }

        {
            const write_data = self.socket_svc.getWriteDataList(state.socket_fd);

            const pre_cond =
                !state.is_closed and
                state.write_queue.count() > 0 and
                write_data.items.len < write_data.capacity;

            assertImply(pre_cond, state.is_writing);
        }

        std.debug.assert(state.num_consecutive_read == 0);

        assertImply(
            !state.is_closed and state.getTmpBuf().len > 0,
            state.is_reading or state.reading_yielded,
        );
        assertImply(
            state.getHandleBuf().len == state.read_size,
            state.is_reading or state.write_queue_full,
        );
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

    fn newEpollWrite(self: *Self, fd: u64) FakeEvent {
        return .{
            .epoll_in = false,
            .epoll_out = true,
            .data_ptr = self.epoll.socket_map.get(fd).?,
        };
    }

    fn addSocketFD(self: *Self, fd: u64) !void {
        // before
        try expectEqual(0, self.core._action_queue.len);
        try expectEqual(0, self.core._task_queue.len);

        self.handleEpollEvent(self.newEpollEventFD());
        self.addNewSocket(fd);
        try expectEqual(1, self.eventfd.counter);

        // pop and handle task
        const task = self.popTaskQueue().?;
        try expectEqual(HandleTaskStatus.Continue, self.handleTask(task));
        try expectEqual(1, self.eventfd.counter);
        try expectEqual(HandleTaskStatus.Next, self.handleTask(task));
        try expectEqual(0, self.eventfd.counter);

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
    const s = try CoreTest.init(.{});
    defer s.deinit();

    s.handleEpollEvent(s.newEpollEventFD());
    try expectEqual(1, s.core._task_queue.len);

    // add event fd epoll event again
    s.handleEpollEvent(s.newEpollEventFD());
    try expectEqual(1, s.core._task_queue.len);

    // new socket
    const socket_fd1: u64 = 21;
    s.addNewSocket(socket_fd1);
    try expectEqual(1, s.core._action_queue.len);

    // pop and handle task
    const task1 = s.popTaskQueue().?;
    try expectEqual(false, task1.state.is_reading);
    try expectEqual(false, task1.state.is_writing);

    try expectEqual(HandleTaskStatus.Continue, s.handleTask(task1));
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(0, s.core._action_queue.len);
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
    try expectEqual(0, task2.state.num_consecutive_read);

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
    const s = try CoreTest.init(.{});
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

test "fully read action, with write buffer full" {
    const s = try CoreTest.init(.{
        .write_queue_capacity = 5,
        .socket_send_buffer_size = 6,
    });
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    s.setReadData(socket_fd1, &.{ 31, 32, 33, 34, 35, 36 });
    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    // add single byte to write buffer
    const write_data1 = s.socket_svc.getWriteDataList(socket_fd1);
    try write_data1.appendBounded(91);

    // pop write task & handle write partially
    const write_task1 = s.popTaskQueue().?;
    try expectEqual(.Continue, s.handleTask(write_task1));
    try expectEqualSlices(
        u8,
        &.{ 91, 41, 42, 43, 44, 45 },
        write_data1.items,
    );

    // write with EAGAIN
    try expectEqual(.Next, s.handleTask(write_task1));
    try expectEqual(0, s.core._task_queue.len);

    // clear write data
    write_data1.clearRetainingCapacity();

    // handle EPOLL OUT
    s.handleEpollEvent(s.newEpollWrite(socket_fd1));
    try expectEqual(1, s.core._task_queue.len);

    // pop write task & handle write again
    const write_task2 = s.popTaskQueue().?;
    try expectEqual(write_task1, write_task2);
    try expectEqual(.Continue, s.handleTask(write_task2));
    try expectEqualSlices(
        u8,
        &.{46},
        write_data1.items,
    );
}

test "fully read multi actions, reach max consecutive read" {
    const s = try CoreTest.init(.{ .max_consecutive_read = 2 });
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    // read util next
    const read_data = [_]u8{ 31, 32, 33, 34, 35, 36 } ** 3;
    s.setReadData(socket_fd1, &read_data);
    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    try expectEqual(2, s.core._task_queue.len);
    try expectEqual(.Write, s.core._task_queue.at(0).task_type);
    try expectEqual(.Read, s.core._task_queue.at(1).task_type);
    try expectEqual(4, read_task1.state.write_queue.count());
    try expectEqual(6, read_task1.state.getTmpBuf().len);
}

test "write queue is full" {
    const s = try CoreTest.init(.{
        .write_queue_capacity = 5,
        .socket_send_buffer_size = 6,
    });
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    // read util next
    const read_data = [_]u8{ 31, 32, 33, 34, 35, 36 } ** 3;
    s.setReadData(socket_fd1, &read_data);
    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    try expectEqual(true, read_task1.state.write_queue_full);
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(4, read_task1.state.write_queue.count());

    // handle write task
    const write_task1 = s.popTaskQueue().?;
    try expectEqual(.Write, write_task1.task_type);
    try expectEqual(.Continue, s.handleTask(write_task1));
    try expectEqual(false, write_task1.state.write_queue_full);
    try expectEqual(2, read_task1.state.write_queue.count());

    // handle write again
    try expectEqual(.Next, s.handleTask(write_task1));
    try expectEqual(2, read_task1.state.write_queue.count());
    try expectEqual(1, s.core._task_queue.len);
    const write_data1 = s.socket_svc.getWriteDataList(socket_fd1);
    try expectEqual(6, write_data1.items.len); // write buffer is full

    // handle read again
    const read_task2 = s.popTaskQueue().?;
    try expectEqual(read_task1, read_task2);
    s.handleTaskUntilNext(read_task2);
    try expectEqual(4, read_task1.state.write_queue.count());
    try expectEqual(0, s.core._task_queue.len);

    // clear socket send buffer
    write_data1.clearRetainingCapacity();

    // epoll out event
    s.handleEpollEvent(s.newEpollWrite(socket_fd1));

    // handle write task again
    const write_task2 = s.popTaskQueue().?;
    try expectEqual(.Continue, s.handleTask(write_task2));
    try expectEqual(6, write_data1.items.len);

    // clear again
    write_data1.clearRetainingCapacity();
    try expectEqual(.Continue, s.handleTask(write_task2));
    try expectEqualSlices(u8, &.{ 53, 54, 55, 56, 57, 58 }, write_data1.items);
    try expectEqual(0, read_task1.state.write_queue.count());

    // final write EAGAIN
    try expectEqual(.Next, s.handleTask(write_task2));
    try expectEqual(0, s.core._task_queue.len);
}

test "with yield queue, when reaching total max read" {
    const s = try CoreTest.init(.{
        .max_total_read_before_yield = 2,
    });
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    // read util next
    const read_data = [_]u8{ 31, 32, 33, 34, 35, 36 } ** 3;
    s.setReadData(socket_fd1, &read_data);
    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    const state1 = read_task1.state;
    try expectEqual(4, state1.write_queue.count());
    try expectEqual(1, s.core._task_queue.len);

    // check yield queue
    try expectEqual(1, s.core._yield_queue.len);
    try expectEqual(true, state1.reading_yielded);
    try expectEqual(false, state1.is_reading);
    try expectEqual(.Read, s.core._yield_queue.at(0).task_type);

    // pop yield queue
    const read_task2 = s.popYieldQueue().?;
    try expectEqual(read_task1, read_task2);
    try expectEqual(false, state1.reading_yielded);
    try expectEqual(false, state1.is_reading);
    try expectEqual(true, state1.is_writing);

    // push to task queue
    s.addReadTask(state1);
    try expectEqual(false, state1.reading_yielded);
    try expectEqual(true, state1.is_reading);
    try expectEqual(true, state1.is_writing);

    try expectEqual(2, s.core._task_queue.len);
    try expectEqual(0, s.core._yield_queue.len);

    // do write
    const write_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(write_task1);
    try expectEqual(0, state1.write_queue.count());
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(0, s.core._yield_queue.len);
    try expectEqual(true, state1.is_reading);
    try expectEqual(false, state1.is_writing);
    try expectEqual(false, state1.socket_send_full);
    const write_data1 = s.socket_svc.getWriteDataList(socket_fd1);
    try expectEqual(12, write_data1.items.len);

    // reset total num read
    s.core._total_num_read = 0;

    // handle read again
    const read_task3 = s.popTaskQueue().?;
    try expectEqual(read_task1, read_task3);
    s.handleTaskUntilNext(read_task3);
    try expectEqual(2, state1.write_queue.count());
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(0, s.core._yield_queue.len);
}

test "with yield queue, when reaching total max read, use public methods" {
    const s = try CoreTest.init(.{
        .max_total_read_before_yield = 2,
    });
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    // set read data
    const read_data = [_]u8{ 31, 32, 33, 34, 35, 36 } ** 3;
    s.setReadData(socket_fd1, &read_data);

    // handle task queue
    s.core.handleTaskQueue();
    s.checkInvariant();

    try expectEqual(0, s.core._task_queue.len);
    try expectEqual(1, s.core._yield_queue.len);
    const write_data1 = s.socket_svc.getWriteDataList(socket_fd1);
    try expectEqual(12, write_data1.items.len);

    s.core.moveFromYieldQueueToTaskQueue();
    s.checkInvariant();
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(0, s.core._yield_queue.len);

    // handle task queue again
    s.core.handleTaskQueue();
    s.checkInvariant();

    try expectEqual(0, s.core._task_queue.len);
    try expectEqual(0, s.core._yield_queue.len);
    try expectEqual(18, write_data1.items.len);
}

test "socket is closed, when reading" {
    const s = try CoreTest.init(.{});
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    try s.socket_svc.is_closed_map.put(socket_fd1, .{});

    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    try expectEqual(0, s.core._task_queue.len);
    try expectEqual(true, s.core._all_states.isEmpty()); // all states removed
    try expectEqual(1, s.core._state_alloc.getNumInUse());

    try expectEqual(0, s.socket_svc.read_map.count());
    try expectEqual(0, s.socket_svc.is_closed_map.count());
    try expectEqual(0, s.epoll.socket_map.count());
}

test "read util EAGAIN, then close when writing" {
    const s = try CoreTest.init(.{});
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    // set read data
    const read_data = [_]u8{ 31, 32, 33, 34, 35, 36 } ** 2;
    s.setReadData(socket_fd1, &read_data);
    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    const state1 = read_task1.state;

    // close socket
    try s.socket_svc.is_closed_map.put(socket_fd1, .{});

    // with EPOLLIN
    s.handleEpollEvent(s.newEpollRead(socket_fd1));
    try expectEqual(2, s.core._task_queue.len);

    // handle write
    const write_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(write_task1);

    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(true, state1.is_closed);
    try expectEqual(true, s.core._all_states.containsSlow(&state1.all_state_list));

    // handle last read
    const read_task2 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task2);

    try expectEqual(0, s.core._task_queue.len);
    try expectEqual(true, state1.is_closed);
    try expectEqual(0, state1.write_queue.count());
    try expectEqual(false, s.core._all_states.containsSlow(&state1.all_state_list));
}

test "close when reading, with pending writing task" {
    const s = try CoreTest.init(.{
        .socket_send_buffer_size = 6,
    });
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    // set read data
    const read_data = [_]u8{ 31, 32, 33, 34, 35, 36 };
    s.setReadData(socket_fd1, &read_data);

    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    // fill send buffer
    const write_data1 = s.socket_svc.getWriteDataList(socket_fd1);
    try write_data1.appendNTimesBounded(99, 6);

    // handle write
    const write_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(write_task1);
    const state1 = write_task1.state;
    try expectEqual(2, state1.write_queue.count());
    try expectEqual(0, s.core._task_queue.len);

    // handle EPOLLIN and EPOLLOUT
    s.handleEpollEvent(s.newEpollRead(socket_fd1));
    s.handleEpollEvent(s.newEpollWrite(socket_fd1));
    try expectEqual(2, s.core._task_queue.len);

    // close socket
    try s.socket_svc.is_closed_map.put(socket_fd1, .{});

    // handle read
    const read_task2 = s.popTaskQueue().?;
    try expectEqual(read_task1, read_task2);
    s.handleTaskUntilNext(read_task2);
    try expectEqual(true, state1.is_closed);
    try expectEqual(2, state1.write_queue.count());
    try expectEqual(true, s.core._all_states.containsSlow(&state1.all_state_list));

    // handle final write
    const write_task2 = s.popTaskQueue().?;
    s.handleTaskUntilNext(write_task2);
    try expectEqual(true, state1.is_closed);
    try expectEqual(0, state1.write_queue.count());
    try expectEqual(false, s.core._all_states.containsSlow(&state1.all_state_list));
}

test "close when writing, with yielded read" {
    const s = try CoreTest.init(.{
        .max_total_read_before_yield = 1,
    });
    defer s.deinit();

    const socket_fd1: u64 = 21;
    try s.addSocketFD(socket_fd1);

    // set read data
    const read_data = [_]u8{ 31, 32, 33, 34, 35, 36 } ** 2;
    s.setReadData(socket_fd1, &read_data);

    const read_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task1);

    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(1, s.core._yield_queue.len);

    // close socket
    try s.socket_svc.is_closed_map.put(socket_fd1, .{});

    // handle write
    const write_task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(write_task1);

    const state1 = write_task1.state;
    try expectEqual(2, state1.write_queue.count());
    try expectEqual(true, s.core._all_states.containsSlow(&state1.all_state_list));
    try expectEqual(2, s.core._state_alloc.getNumInUse());

    try expectEqual(0, s.core._task_queue.len);
    try expectEqual(1, s.core._yield_queue.len);

    // move yield to task queue
    s.core.moveFromYieldQueueToTaskQueue();
    try expectEqual(1, s.core._task_queue.len);
    try expectEqual(0, s.core._yield_queue.len);

    // handle last task
    const read_task2 = s.popTaskQueue().?;
    s.handleTaskUntilNext(read_task2);
    try expectEqual(0, state1.write_queue.count());
    try expectEqual(0, state1.callbacks.num_writes);
    try expectEqual(false, s.core._all_states.containsSlow(&state1.all_state_list));
    try expectEqual(1, s.core._state_alloc.getNumInUse());
}

test "add multi sockets, shutdown immediately" {
    const s = try CoreTest.init(.{});
    defer s.deinit();

    s.core.addNewSocket(21);
    s.core.addNewSocket(22);
    s.core.addNewSocket(23);
    try expectEqual(1, s.eventfd.counter);

    s.core.shutdown();
    try expectEqual(1, s.eventfd.counter);

    s.handleEpollEvent(s.newEpollEventFD());

    // handle all actions
    const task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(task1);
    try expectEqual(0, s.eventfd.counter);

    try expectEqual(3, s.core._task_queue.len);
    var state_iter = s.core._all_states.iterate();
    var num_states: usize = 0;
    while (state_iter.next()) |e| {
        const state = CoreTest.SocketState.fromList(e);
        try expectEqual(true, state.is_closed);
        num_states += 1;
    }
    try expectEqual(3, num_states);
}

test "add multi sockets, read all then shudown" {
    const s = try CoreTest.init(.{});
    defer s.deinit();

    s.core.addNewSocket(21);
    s.core.addNewSocket(22);
    s.core.addNewSocket(23);
    s.handleEpollEvent(s.newEpollEventFD());

    // handle all actions
    const task1 = s.popTaskQueue().?;
    s.handleTaskUntilNext(task1);
    try expectEqual(0, s.eventfd.counter);

    s.core.handleTaskQueue();
    try expectEqual(0, s.core._task_queue.len);

    // do shutdown
    s.core.shutdown();
    s.handleEpollEvent(s.newEpollEventFD());
    s.core.handleTaskQueue();

    // states empty
    try expectEqual(true, s.core._all_states.isEmpty());
    try expectEqual(0, s.epoll.socket_map.count());
}
