const std = @import("std");

pub const minimum_stable_bases: usize = 8 << 20;

pub const Verdict = enum { pass, fail, inconclusive };

pub fn verdictFor(mb_per_second: f64, budget: ?f64, input_bases: usize, windows: u64) ?Verdict {
    const target = budget orelse return null;
    if (windows == 0 or input_bases < minimum_stable_bases) return .inconclusive;
    return if (mb_per_second >= target) .pass else .fail;
}

pub fn verdictText(verdict: Verdict) []const u8 {
    return switch (verdict) {
        .pass => "PASS",
        .fail => "FAIL",
        .inconclusive => "INCONCLUSIVE",
    };
}

pub const Summary = struct {
    mask: []const u8,
    span: u16,
    weight: u16,
    engine: []const u8,
    records: usize,
    input_bases: usize,
    windows: u64,
    unique_kmers: u64,
    counts_path: []const u8,
    ns_per_window: f64,
    mb_per_second: f64,
    budget_mb_per_second: ?f64,
    host: []const u8,
    arch: []const u8,
    os: []const u8,
    compiler: []const u8,
    mode: []const u8,
    commit: []const u8,
    fisk_sha: []const u8,

    pub fn verdict(self: Summary) ?Verdict {
        return verdictFor(self.mb_per_second, self.budget_mb_per_second, self.input_bases, self.windows);
    }

    pub fn writeJson(self: Summary, writer: anytype) !void {
        try writer.writeAll("{\"mask\":");
        try writeJsonString(writer, self.mask);
        try writer.print(
            ",\"span\":{d},\"weight\":{d},\"engine\":",
            .{ self.span, self.weight },
        );
        try writeJsonString(writer, self.engine);
        try writer.print(
            ",\"records\":{d},\"input_bases\":{d},\"windows\":{d},\"unique_kmers\":{d},\"counts_path\":",
            .{ self.records, self.input_bases, self.windows, self.unique_kmers },
        );
        try writeJsonString(writer, self.counts_path);
        try writer.print(
            ",\"ns_per_window\":{d:.3},\"mb_per_second\":{d:.1},\"budget_mb_per_second\":",
            .{ self.ns_per_window, self.mb_per_second },
        );
        if (self.budget_mb_per_second) |budget| {
            try writer.print("{d:.1}", .{budget});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"host\":");
        try writeJsonString(writer, self.host);
        try writer.writeAll(",\"arch\":");
        try writeJsonString(writer, self.arch);
        try writer.writeAll(",\"os\":");
        try writeJsonString(writer, self.os);
        try writer.writeAll(",\"compiler\":");
        try writeJsonString(writer, self.compiler);
        try writer.writeAll(",\"mode\":");
        try writeJsonString(writer, self.mode);
        try writer.writeAll(",\"commit\":");
        try writeJsonString(writer, self.commit);
        try writer.writeAll(",\"fisk_sha\":");
        try writeJsonString(writer, self.fisk_sha);
        try writer.writeAll(",\"verdict\":");
        if (self.verdict()) |result| {
            try writer.writeByte('"');
            try writer.writeAll(verdictText(result));
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}\n");
    }
};

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

pub fn writeCounts(
    writer: anytype,
    groups: anytype,
    weight: u16,
) !u64 {
    var iter = groups;
    var unique: u64 = 0;
    var buf: [32]u8 = undefined;
    try writer.writeAll("kmer\tcount\n");
    while (iter.next()) |entry| {
        const text = buf[0..weight];
        @import("canon.zig").decode(entry.key, weight, text);
        try writer.print("{s}\t{d}\n", .{ text, entry.count });
        unique += 1;
    }
    return unique;
}

test "json summary carries verdict and pinned reference" {
    const summary = Summary{
        .mask = "1011",
        .span = 4,
        .weight = 3,
        .engine = "butterfly",
        .records = 1,
        .input_bases = 8 << 20,
        .windows = 4,
        .unique_kmers = 4,
        .counts_path = "out.tsv",
        .ns_per_window = 1.25,
        .mb_per_second = 800,
        .budget_mb_per_second = 500,
        .host = "apple_m2",
        .arch = "aarch64",
        .os = "macos",
        .compiler = "0.17.1",
        .mode = "ReleaseFast",
        .commit = "abc123",
        .fisk_sha = "b242e7b",
    };
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try summary.writeJson(&writer);
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"verdict\":\"PASS\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"fisk_sha\":\"b242e7b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mask\":\"1011\"") != null);
}

test "verdict uses inconclusive below the stable corpus size" {
    try std.testing.expectEqual(Verdict.inconclusive, verdictFor(900, 500, minimum_stable_bases - 1, 10).?);
    try std.testing.expectEqual(Verdict.pass, verdictFor(900, 500, minimum_stable_bases, 10).?);
    try std.testing.expectEqual(Verdict.fail, verdictFor(499.9, 500, minimum_stable_bases, 10).?);
    try std.testing.expectEqual(Verdict.inconclusive, verdictFor(900, 500, minimum_stable_bases, 0).?);
    try std.testing.expectEqual(@as(?Verdict, null), verdictFor(900, null, minimum_stable_bases, 10));
}
