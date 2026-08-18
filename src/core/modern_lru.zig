const std = @import("std");
const zutil = @import("zutil");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const ListHead = zutil.ListHead;
const SlabClass = types.SlabClass;

pub const ModernLru = struct {
    const Self = @This();

    const SlabClassState = struct {
        mutex: std.Io.Mutex,
        is_locked: bool,

        free_list: ListHead,

        hot_list: ListHead,
        warm_list: ListHead,
        cold_list: ListHead,
    };

    _io: std.Io,
    _gpa: Allocator,
    _all_classes: []SlabClassState,

    pub fn init(io: std.Io, gpa: Allocator, num_classes: usize) !Self {
        zutil.runtimeAssert(num_classes <= SlabClass.MaxNumClass);

        const all_classes = try gpa.alloc(SlabClassState, num_classes);
        for (all_classes) |*s| {
            s.* = .{
                .mutex = .init,
            };
        }

        return .{
            ._io = io,
            ._gpa = gpa,
            ._all_classes = all_classes,
        };
    }
};
