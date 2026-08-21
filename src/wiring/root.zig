const wiring = @import("wiring.zig");

pub const SystemRoot = wiring.SystemRoot;

test {
    _ = .{
        wiring,
    };
}
