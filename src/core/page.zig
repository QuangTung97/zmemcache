const std = @import("std");

pub const PageSize = 1 << 20; // 1MB

pub const Page = [PageSize]u8;

pub const MaxSlab: u32 = 0xffffffff;

pub const GlobalPager = struct {
    gpa: std.mem.Allocator,
    all_pages: []Page,
    num_empty_pages: std.atomic.Value(u64),
    mut: std.Io.Mutex,
    pages_to_slab: []std.atomic.Value(u32),

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, num_pages: u64) !Self {
        const all_pages = try gpa.alloc(Page, num_pages);
        const pages_to_slab = try gpa.alloc(std.atomic.Value(u32), num_pages);

        for (pages_to_slab) |*item| {
            item.* = .init(MaxSlab);
        }

        return Self{
            .gpa = gpa,
            .all_pages = all_pages,
            .num_empty_pages = .init(num_pages),
            .mut = .init,
            .pages_to_slab = pages_to_slab,
        };
    }

    pub fn deinit(self: *Self) void {
        self.gpa.free(self.all_pages);
        self.gpa.free(self.pages_to_slab);
    }
};

const expectEqual = std.testing.expectEqual;

test "page size" {
    try std.testing.expectEqual(1024 * 1024, @sizeOf(Page));
    try std.testing.expect(MaxSlab > 1_000_000);
}

test "basic" {
    var g = try GlobalPager.init(std.testing.allocator, 3);
    defer g.deinit();

    try expectEqual(3, g.all_pages.len);
    try expectEqual(3, g.pages_to_slab.len);
    try expectEqual(0xffff_ffff, g.pages_to_slab[0].load(.seq_cst));
    try expectEqual(0xffff_ffff, g.pages_to_slab[2].load(.seq_cst));
}
