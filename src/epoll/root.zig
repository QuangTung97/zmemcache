const types = @import("types.zig");
const ecore = @import("core.zig");
const impl = @import("impl.zig");
const wiring = @import("wiring.zig");

test {
    _ = .{
        types,
        ecore,
        impl,
        wiring,
    };
}
