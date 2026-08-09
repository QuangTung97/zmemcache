const std = @import("std");
const types = @import("types.zig");

const PageSizeShift = 20;

pub const PageSize = 1 << PageSizeShift; // 1MB

pub const Page = [PageSize]u8;

pub const PageNum = struct { page_num: u64 };

pub const MaxSlab: u32 = 0xffffffff;

pub const GlobalPager = struct {
    private: struct {
        io: std.Io,
        gpa: std.mem.Allocator,

        all_pages: []Page,
        num_empty_pages: std.atomic.Value(u64),
        mut: std.Io.Mutex,
        pages_to_slab: []std.atomic.Value(u32),
    },

    const Self = @This();

    pub fn init(io: std.Io, gpa: std.mem.Allocator, num_pages: u64) !Self {
        const all_pages = try gpa.alignedAlloc(
            Page,
            types.ItemAlignment,
            num_pages,
        );
        const pages_to_slab = try gpa.alloc(std.atomic.Value(u32), num_pages);

        for (pages_to_slab) |*item| {
            item.* = .init(MaxSlab);
        }

        return Self{
            .private = .{
                .io = io,
                .gpa = gpa,
                .all_pages = all_pages,
                .num_empty_pages = .init(num_pages),
                .mut = .init,
                .pages_to_slab = pages_to_slab,
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.private.gpa.free(self.private.all_pages);
        self.private.gpa.free(self.private.pages_to_slab);
    }

    pub fn allocPage(self: *Self, slab: types.SlabClass) ?*Page {
        const this = &self.private;

        var num_empty = this.num_empty_pages.load(.seq_cst);
        if (num_empty == 0) {
            return null;
        }

        this.mut.lockUncancelable(this.io);
        defer this.mut.unlock(this.io);

        // check again
        num_empty = this.num_empty_pages.load(.seq_cst);
        if (num_empty == 0) {
            return null;
        }

        this.num_empty_pages.store(num_empty - 1, .seq_cst);

        const index = this.all_pages.len - num_empty;
        this.pages_to_slab[index].store(slab.slab, .seq_cst);

        return &this.all_pages[index];
    }

    pub fn getPageNumOfItem(self: Self, item: *types.Item) PageNum {
        const this = self.private;
        const base_addr: *u8 = @ptrCast(&this.all_pages[0]);
        const item_addr: *u8 = @ptrCast(item);
        const offset = item_addr - base_addr;

        const page_num = offset >> PageSizeShift;
        return .{ .page_num = page_num };
    }

    pub fn getSlabClass(self: Self, page_num: PageNum) types.SlabClass {
        return .{
            .slab = self.private.pages_to_slab[page_num.page_num].load(.seq_cst),
        };
    }
};

const ItemIterator = struct {
    item_size_shift: u64,
    page_addr: *u8,
    current: u64,
    max_offset: u64,

    const Self = @This();

    pub fn next(self: *Self) ?*types.Item {
        if (self.current >= self.max_offset) {
            return null;
        }

        const item_addr = self.page_addr + (self.current * self.item_size_shift);
        self.current = self.current + 1;

        const item: *types.Item = @ptrCast(@alignCast(item_addr));
        return item;
    }
};

pub fn iterateItemsOfPage(page: *Page, item_size_shift: u64) ItemIterator {
    const item_size = 1 << item_size_shift;
    const num_items = PageSize / item_size;

    return .{
        .item_size_shift = item_size_shift,
        .page_addr = @ptrCast(page),
        .current = 0,
        .max_offset = num_items,
    };
}

const expectEqual = std.testing.expectEqual;

test "page size" {
    try expectEqual(1024 * 1024, @sizeOf(Page));
    try std.testing.expect(MaxSlab > 1_000_000);
    try expectEqual(1, @alignOf(Page));
}

test "basic" {
    var g = try GlobalPager.init(
        std.testing.io,
        std.testing.allocator,
        3,
    );
    defer g.deinit();

    try expectEqual(3, g.private.all_pages.len);
    try expectEqual(3, g.private.pages_to_slab.len);
    try expectEqual(0xffff_ffff, g.private.pages_to_slab[0].load(.seq_cst));
    try expectEqual(0xffff_ffff, g.private.pages_to_slab[2].load(.seq_cst));

    // test allocate pages
    const p1 = g.allocPage(.{ .slab = 11 });
    try expectEqual(&g.private.all_pages[0], p1);
    try expectEqual(3, g.private.pages_to_slab.len);

    const p2 = g.allocPage(.{ .slab = 12 });
    try expectEqual(&g.private.all_pages[1], p2);
    try expectEqual(11, g.private.pages_to_slab[0].load(.seq_cst));
    try expectEqual(12, g.private.pages_to_slab[1].load(.seq_cst));

    const p3 = g.allocPage(.{ .slab = 13 });
    try expectEqual(&g.private.all_pages[2], p3);

    const p4 = g.allocPage(.{ .slab = 14 });
    try expectEqual(null, p4);

    // test get page num
    const item1: *types.Item = @ptrCast(@alignCast(p1));
    const num1 = g.getPageNumOfItem(item1);
    try expectEqual(0, num1.page_num);
    try expectEqual(11, g.getSlabClass(num1).slab);

    const item2: *types.Item = @ptrCast(@alignCast(p2));
    const num2 = g.getPageNumOfItem(item2);
    try expectEqual(1, num2.page_num);
    try expectEqual(12, g.getSlabClass(num2).slab);

    const item3: *types.Item = @ptrCast(@alignCast(p3));
    try expectEqual(2, g.getPageNumOfItem(item3).page_num);
}
