const std = @import("std");
const Io = std.Io;

pub fn main() !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("Hello World", .{});
}
