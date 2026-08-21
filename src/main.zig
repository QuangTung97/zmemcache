const std = @import("std");
const zutil = @import("zutil");
const wiring = @import("wiring");

const num_keys = 1 << 10;

const num_read_thread = 4;
const num_read_loop = 1000_000;

const num_write_thread = 2;
const num_write_loop = 100_000;

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
                const item_value = found.item.getValue();
                const value_len = item_value.len - 4;

                // compute crc of key + value
                var crc_sum = std.hash.crc.Crc32.init();
                crc_sum.update(key);
                crc_sum.update(item_value[0..value_len]);
                const crc_value = crc_sum.final();

                // check crc match
                zutil.runtimeAssert(std.mem.eql(u8, item_value[value_len..], std.mem.asBytes(&crc_value)));

                svc.finishGet(found);
            },
            .NotFound => continue,
            .SetPartial => continue,
        }
    }
}

fn runWritingThread(
    svc: *wiring.SystemRoot.ItemSvc,
    root_rand: std.Random,
    all_keys: [][]u8,
) void {
    var prng = std.Random.DefaultPrng.init(root_rand.int(u64));
    const rand = prng.random();

    var write_buffer: [16 * 1024]u8 = undefined;

    for (0..num_write_loop) |_| {
        const index = rand.uintLessThan(usize, all_keys.len);
        const key = all_keys[index];

        const value_len = rand.uintLessThan(usize, write_buffer.len);
        const value_bytes = write_buffer[0..value_len];
        rand.bytes(value_bytes); // generate random value

        // compute crc of key + value
        var crc_sum = std.hash.crc.Crc32.init();
        crc_sum.update(key);
        crc_sum.update(value_bytes);
        const crc_value = crc_sum.final();

        const null_setter = svc.put(key, value_len + 4);
        const setter = null_setter orelse continue;

        const item_value = setter.item.getValue();
        @memcpy(item_value[0..value_len], value_bytes);
        @memcpy(item_value[value_len..], std.mem.asBytes(&crc_value));

        svc.finishPut(setter);
    }
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = threaded.io();

    var root = try wiring.SystemRoot.init(io, gpa, .{
        .num_pages = 100, // 100MB
    });
    defer root.deinit();

    var group = std.Io.Group.init;
    defer group.cancel(io);

    const io_source = std.Random.IoSource{ .io = io };
    const rand = io_source.interface();

    // init random keys
    const all_keys = try gpa.alloc([]u8, num_keys);
    defer gpa.free(all_keys);
    for (all_keys) |*key| {
        const key_len = rand.intRangeAtMost(u8, 1, 255);
        key.* = try gpa.alloc(u8, key_len);
        rand.bytes(key.*);
    }
    defer for (all_keys) |key| {
        gpa.free(key);
    };

    // run in parallel
    const svc = &root.item_svc;
    for (0..num_read_thread) |_| {
        try group.concurrent(io, runReadingThread, .{ svc, rand, all_keys });
    }
    for (0..num_write_thread) |_| {
        try group.concurrent(io, runWritingThread, .{ svc, rand, all_keys });
    }

    // wait for all threads
    try group.await(io);
}
