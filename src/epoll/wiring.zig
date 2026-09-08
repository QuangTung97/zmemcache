const std = @import("std");
const types = @import("types.zig");
const ecore = @import("core.zig");
const impl = @import("impl.zig");

const Allocator = std.mem.Allocator;

pub fn EpollRoot(
    CallbackType: type,
    comptime max_write_queue_size: usize,
    comptime epoll_buffer_size: usize,
) type {
    return struct {
        const Self = @This();

        const FD = impl.FD;
        const SocketSvc = impl.SocketService(max_write_queue_size);

        const CoreType = ecore.EpollCore(
            FD,
            impl.Event,
            impl.EventService,
            impl.EpollService,
            impl.EventFdService,
            SocketSvc,
            CallbackType,
            impl.EventFuncs.init(),
            impl.EpollFuncs.init(),
            impl.EventFdFuncs.init(),
            types.SocketFuncs(SocketSvc, FD).init(),
            types.CallbackFuncs(CallbackType).init(),
            max_write_queue_size,
        );

        epoll: impl.EpollService,
        eventfd_svc: impl.EventFdService,
        eventfd_num: FD,
        socket_svc: SocketSvc,
        core: *CoreType,

        pub const Config = struct {
            max_num_sockets: usize,
            max_consecutive_read: usize,
            max_total_read_before_yield: usize,
        };

        pub fn init(
            io: std.Io,
            gpa: Allocator,
            config: Config,
        ) !*Self {
            const s = try gpa.create(Self);

            s.* = .{
                .epoll = impl.EpollService.init(),
                .eventfd_svc = impl.EventFdService.init(),
                .eventfd_num = undefined,
                .socket_svc = SocketSvc.init(),
                .core = undefined,
            };

            s.eventfd_num = s.eventfd_svc.new_eventfd();

            s.core = try CoreType.init(
                io,
                gpa,
                &s.epoll,
                &s.eventfd_svc,
                &s.socket_svc,
                s.eventfd_num,
                .{
                    .max_num_sockets = config.max_num_sockets,
                    .write_queue_capacity = max_write_queue_size,
                    .max_consecutive_read = config.max_consecutive_read,
                    .max_total_read_before_yield = config.max_total_read_before_yield,
                },
            );

            return s;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.eventfd_svc.close_eventfd(self.eventfd_num);

            self.epoll.deinit();
            self.core.deinit(gpa);
            gpa.destroy(self);
        }

        pub fn runLoop(self: *Self) void {
            while (!self.core.shutdownFinished()) {
                var events_buffer: [epoll_buffer_size]impl.Event = undefined;
                const epoll_events = self.core.epollWait(&events_buffer);

                self.core.moveFromYieldQueueToTaskQueue();

                for (epoll_events) |event| {
                    self.core.handleEpollEvent(event);
                }

                self.core.handleTaskQueue();
            }
        }
    };
}

test "test epoll wiring" {
    const RootType = EpollRoot(
        ecore.FakeCallbacks,
        16,
        32,
    );
    std.testing.refAllDecls(RootType);

    const gpa = std.testing.allocator;
    const root = try RootType.init(std.testing.io, gpa, .{
        .max_consecutive_read = 20,
        .max_total_read_before_yield = 200,
        .max_num_sockets = 16,
    });
    defer root.deinit(gpa);

    root.core.shutdown();
    root.runLoop();
}
