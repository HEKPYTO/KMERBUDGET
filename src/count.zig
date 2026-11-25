const std = @import("std");
const canon = @import("canon.zig");

pub const Entry = struct {
    key: u64,
    count: u64,
};

pub const Collector = struct {
    keys: std.ArrayList(u64) = .empty,
    allocator: std.mem.Allocator,
    weight: u16,

    pub fn init(allocator: std.mem.Allocator, weight: u16) Collector {
        return .{ .allocator = allocator, .weight = weight };
    }

    pub fn deinit(self: *Collector) void {
        self.keys.deinit(self.allocator);
    }

    pub fn emit(self: *Collector, kmer: u64) !void {
        try self.keys.append(self.allocator, canon.canonical(kmer, self.weight));
    }

    pub fn sort(self: *Collector) void {
        std.sort.pdq(u64, self.keys.items, {}, std.sort.asc(u64));
    }

    pub fn groups(self: Collector) Groups {
        return .{ .keys = self.keys.items };
    }
};

pub const Groups = struct {
    keys: []const u64,
    index: usize = 0,

    pub fn next(self: *Groups) ?Entry {
        if (self.index >= self.keys.len) return null;
        const key = self.keys[self.index];
        var end = self.index + 1;
        while (end < self.keys.len and self.keys[end] == key) end += 1;
        const count = end - self.index;
        self.index = end;
        return .{ .key = key, .count = count };
    }
};

test "collector groups canonical orientations in key order" {
    var collector = Collector.init(std.testing.allocator, 3);
    defer collector.deinit();
    const forward = 0b01_10_00;
    const rc = canon.reverseComplement(forward, 3);
    try collector.emit(forward);
    try collector.emit(0b11_11_11);
    try collector.emit(rc);
    collector.sort();
    var groups = collector.groups();
    const first = groups.next().?;
    try std.testing.expectEqual(@as(u64, 0), first.key);
    try std.testing.expectEqual(@as(u64, 1), first.count);
    const second = groups.next().?;
    try std.testing.expectEqual(canon.canonical(forward, 3), second.key);
    try std.testing.expectEqual(@as(u64, 2), second.count);
    try std.testing.expectEqual(@as(?Entry, null), groups.next());
}
