const std = @import("std");

pub const WaitGroup = struct {
    _io: std.Io,
    _counter: std.atomic.Value(u64),
    _mut: std.Io.Mutex,
    _cond: std.Io.Condition,

    const Self = @This();

    pub fn init(io: std.Io) Self {
        return .{
            ._io = io,
            ._counter = .init(0),
            ._mut = .init,
            ._cond = .init,
        };
    }

    pub fn add(self: *Self, n: u64) void {
        _ = self._counter.fetchAdd(n, .seq_cst);
    }

    pub fn done(self: *Self) void {
        const prev = self._counter.fetchSub(1, .seq_cst);
        std.debug.assert(prev != 0);
        if (prev > 1) {
            return;
        }

        const io = self._io;
        self._mut.lockUncancelable(io);
        defer self._mut.unlock(io);

        self._cond.broadcast(io);
    }

    pub fn wait(self: *Self) void {
        const io = self._io;

        self._mut.lockUncancelable(io);
        defer self._mut.unlock(io);

        while (self._counter.load(.seq_cst) != 0) {
            self._cond.waitUncancelable(io, &self._mut);
        }
    }
};

test "normal" {
    const io = std.testing.io;
    var wg = WaitGroup.init(io);

    wg.add(3);
    wg.done();
    wg.done();
    wg.done();

    wg.wait();
}

fn runInParallel(wg: *WaitGroup, total: *std.atomic.Value(u64)) void {
    defer wg.done();
    _ = total.fetchAdd(1, .seq_cst);
}

test "with concurrent" {
    const io = std.testing.io;
    var wg = WaitGroup.init(io);
    var total = std.atomic.Value(u64).init(0);

    wg.add(3);

    var task1 = try io.concurrent(runInParallel, .{&wg, &total});
    defer task1.cancel(io);

    var task2 = try io.concurrent(runInParallel, .{&wg, &total});
    defer task2.cancel(io);

    var task3 = try io.concurrent(runInParallel, .{&wg, &total});
    defer task3.cancel(io);

    wg.wait();

    try std.testing.expectEqual(3, total.load(.seq_cst));
}
