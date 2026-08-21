const std = @import("std");
const zutil = @import("zutil");
const wiring = @import("wiring");

const num_keys = 1 << 10;
const max_key_len = 50;

const num_read_thread = 10;
const num_read_loop = 5_000_000;

const write_first = true;
const num_write_thread = 1;
const num_write_loop = 10_000;
const max_value_len = 1024;

var not_found_total = std.atomic.Value(u64).init(0);
var set_partial_total = std.atomic.Value(u64).init(0);

fn runReadingThread(
    svc: *wiring.SystemRoot.ItemSvc,
    root_rand: std.Random,
    all_keys: [][]u8,
) void {
    var prng = std.Random.DefaultPrng.init(root_rand.int(u64));
    const rand = prng.random();

    for (0..num_read_loop) |_| {
        const index = rand.uintLessThan(usize, all_keys.len);
        const key = all_keys[index];

        const getter = svc.get(key);
        switch (getter) {
            .Found => |found| {
                zutil.runtimeAssert(std.mem.eql(u8, key, found.item.getKey()));
                svc.finishGet(found);
            },
            .NotFound => _ = not_found_total.fetchAdd(1, .seq_cst),
            .SetPartial => _ = set_partial_total.fetchAdd(1, .seq_cst),
        }
    }
}

var write_buffer: [max_value_len]u8 = @splat(33);

fn runWritingThread(
    svc: *wiring.SystemRoot.ItemSvc,
    root_rand: std.Random,
    all_keys: [][]u8,
) void {
    var prng = std.Random.DefaultPrng.init(root_rand.int(u64));
    const rand = prng.random();

    for (0..num_write_loop) |_| {
        const index = rand.uintLessThan(usize, all_keys.len);
        const key = all_keys[index];

        const value_len = rand.uintLessThan(usize, write_buffer.len);
        const value_bytes = write_buffer[0..value_len];

        const null_setter = svc.put(key, value_len);
        const setter = null_setter orelse continue;

        const item_value = setter.item.getValue();
        @memcpy(item_value, value_bytes);

        svc.finishPut(setter);
    }
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = threaded.io();

    const init_start = std.Io.Clock.now(.real, io);
    var root = try wiring.SystemRoot.init(io, gpa, .{
        .num_pages = 100, // 100MB
    });
    defer root.deinit();
    const init_duration = init_start.untilNow(io, .real);
    std.debug.print("Init duration: {}ms\n", .{init_duration.toMilliseconds()});

    var group = std.Io.Group.init;
    defer group.cancel(io);

    const io_source = std.Random.IoSource{ .io = io };
    const rand = io_source.interface();

    // init random keys
    const all_keys = try gpa.alloc([]u8, num_keys);
    defer gpa.free(all_keys);
    for (all_keys) |*key| {
        const key_len = rand.intRangeAtMost(u8, 1, max_key_len);
        key.* = try gpa.alloc(u8, key_len);
        rand.bytes(key.*);
    }
    defer for (all_keys) |key| {
        gpa.free(key);
    };

    // run in parallel
    const svc = &root.item_svc;

    const start_time = std.Io.Clock.now(.real, io);

    if (write_first) {
        runWritingThread(svc, rand, all_keys);
    } else {
        for (0..num_write_thread) |_| {
            try group.concurrent(io, runWritingThread, .{ svc, rand, all_keys });
        }
    }

    for (0..num_read_thread) |_| {
        try group.concurrent(io, runReadingThread, .{ svc, rand, all_keys });
    }

    // wait for all threads
    try group.await(io);

    const duration = start_time.untilNow(io, .real);
    std.debug.print("Total time: {}ms\n", .{duration.toMilliseconds()});
    std.debug.print( "Not Found: {}\n", .{not_found_total.load(.seq_cst)});
    std.debug.print( "Set Partial: {}\n", .{set_partial_total.load(.seq_cst)});
}
