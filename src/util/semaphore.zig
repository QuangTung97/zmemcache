const std = @import("std");

pub const Semaphore = struct {
    _io: std.Io,
    _mutex: std.Io.Mutex,
    _cond: std.Io.Condition,
    _counter: u64,
    _padding: [3]u64 = undefined,

    const Self = @This();

    pub fn init(io: std.Io) Self {
        return .{
            ._io = io,
            ._mutex = .init,
            ._cond = .init,
            ._counter = 0,
        };
    }

    pub fn up(self: *Self) void {
        self._mutex.lockUncancelable(self._io);
        defer self._mutex.unlock(self._io);

        const prev = self._counter;
        self._counter = prev + 1;

        self._cond.signal(self._io);
    }

    pub fn down(self: *Self) void {
        self._mutex.lockUncancelable(self._io);
        defer self._mutex.unlock(self._io);

        while (self._counter == 0) {
            self._cond.waitUncancelable(self._io, &self._mutex);
        }
        self._counter -= 1;
    }
};

const expectEqual = std.testing.expectEqual;

test "size" {
    try expectEqual(64, @sizeOf(Semaphore));
}

test "single thread" {
    var s = Semaphore.init(std.testing.io);

    s.up();
    s.up();
    s.up();
    try expectEqual(3, s._counter);

    s.down();
    try expectEqual(2, s._counter);

    s.down();
    s.down();
    try expectEqual(0, s._counter);
}

fn runInBackground(s: *Semaphore, finished: *bool) void {
    finished.* = true;
    s.up();
}

test "parallel" {
    const io = std.testing.io;
    var s = Semaphore.init(io);
    var finished = false;

    var task1 = try io.concurrent(runInBackground, .{ &s, &finished });
    defer task1.cancel(io);

    s.down();
    try expectEqual(true, finished);
}
