const std = @import("std");

pub const Fasta = struct {
    allocator: std.mem.Allocator,
    bases: []u8,
    records: []const []const u8,

    pub fn parse(allocator: std.mem.Allocator, input: []const u8, max_bases: usize) !Fasta {
        var bases: std.ArrayList(u8) = .empty;
        errdefer bases.deinit(allocator);
        var starts: std.ArrayList(usize) = .empty;
        defer starts.deinit(allocator);
        var in_record = false;

        var lines = std.mem.splitScalar(u8, input, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len > 0 and line[0] == '>') {
                if (!in_record) {
                    try starts.append(allocator, 0);
                    in_record = true;
                } else {
                    try starts.append(allocator, bases.items.len);
                }
                continue;
            }
            if (!in_record) {
                try starts.append(allocator, 0);
                in_record = true;
            }
            for (line) |c| {
                if (std.ascii.isWhitespace(c)) continue;
                if (bases.items.len >= max_bases) return error.CorpusTooLarge;
                try bases.append(allocator, c);
            }
        }
        if (starts.items.len == 0 or bases.items.len == 0) return error.EmptyFasta;

        const owned = try bases.toOwnedSlice(allocator);
        errdefer allocator.free(owned);
        const records = try allocator.alloc([]const u8, starts.items.len);
        for (starts.items, 0..) |start, i| {
            const end = if (i + 1 < starts.items.len) starts.items[i + 1] else owned.len;
            records[i] = owned[start..end];
        }
        return .{ .allocator = allocator, .bases = owned, .records = records };
    }

    pub fn deinit(self: *Fasta) void {
        self.allocator.free(self.records);
        self.allocator.free(self.bases);
    }
};

test "parses records and ignores headers and whitespace" {
    const input = ">alpha\r\nAC GT\n>beta\nnnAC\r\n";
    var fasta = try Fasta.parse(std.testing.allocator, input, 1024);
    defer fasta.deinit();
    try std.testing.expectEqual(@as(usize, 2), fasta.records.len);
    try std.testing.expectEqualStrings("ACGT", fasta.records[0]);
    try std.testing.expectEqualStrings("nnAC", fasta.records[1]);
}

test "accepts headerless input as one record" {
    var fasta = try Fasta.parse(std.testing.allocator, "ACGT\nAC", 1024);
    defer fasta.deinit();
    try std.testing.expectEqual(@as(usize, 1), fasta.records.len);
    try std.testing.expectEqualStrings("ACGTAC", fasta.records[0]);
}

test "rejects oversize and empty input" {
    try std.testing.expectError(error.CorpusTooLarge, Fasta.parse(std.testing.allocator, "ACGT", 3));
    try std.testing.expectError(error.EmptyFasta, Fasta.parse(std.testing.allocator, ">only header\n", 3));
}
