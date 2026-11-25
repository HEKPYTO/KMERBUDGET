const std = @import("std");
const builtin = @import("builtin");
const pack = @import("pack.zig");
const extract = @import("extract.zig");
const scan = @import("scan.zig");
const seed = @import("seed.zig");
const host = @import("host.zig");

const masks = [_][]const u8{
    "1100110011001100",
    "111100001111000011110000",
    "11110000111100001111000011110000",
};

const Sink = struct {
    checksum: u64 = 0,
    windows: u64 = 0,

    pub fn emit(self: *Sink, kmer: u64) !void {
        self.checksum ^= kmer;
        self.windows += 1;
    }
};

fn mbPerSecond(bytes: usize, elapsed: i96) f64 {
    return @as(f64, @floatFromInt(bytes)) * 1000.0 / @as(f64, @floatFromInt(elapsed));
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    var megabytes: usize = 64;
    if (args.len > 1) megabytes = try std.fmt.parseInt(usize, args[1], 10);

    const seq = try arena.alloc(u8, megabytes << 20);
    var rng: u64 = 0x243f6a8885a308d3;
    for (seq) |*base| {
        base.* = "ACGT"[seed.splitmix64(&rng) & 3];
    }

    var host_buffer: [256]u8 = undefined;
    try out.print(
        "{{\"host\":\"{s}\",\"compiler\":\"{s}\",\"mode\":\"{s}\",\"bytes\":{d}}}\n",
        .{ host.cpuName(&host_buffer, io), builtin.zig_version_string, @tagName(builtin.mode), seq.len },
    );

    var rolling = pack.Rolling.init(32);
    var rolling_checksum: u64 = 0;
    var rolling_windows: u64 = 0;
    var start = std.Io.Clock.now(.cpu_thread, io);
    for (seq, 0..) |base, index| {
        rolling.push(pack.encode(base));
        if (index + 1 >= rolling.span and rolling.valid(0xffff_ffff)) {
            rolling_checksum ^= rolling.value;
            rolling_windows += 1;
        }
    }
    var elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - start.nanoseconds;
    std.mem.doNotOptimizeAway(rolling_checksum);
    try out.print(
        "{{\"phases\":\"rolling_only\",\"mb_per_second\":{d:.1},\"windows\":{d}}}\n",
        .{ mbPerSecond(seq.len, elapsed), rolling_windows },
    );

    for (masks) |text| {
        const mask = try extract.Mask.parse(text);
        const engines = [_]extract.Engine{
            .butterfly,
            .pext,
        };
        for (engines) |engine| {
            if (engine == .pext and extract.nativeEngine() != .pext) continue;
            var scanner = scan.Scanner.init(mask);
            scanner.kind = engine;
            var sink: Sink = .{};
            start = std.Io.Clock.now(.cpu_thread, io);
            try scanner.scan(seq, &sink);
            elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - start.nanoseconds;
            std.mem.doNotOptimizeAway(sink.checksum);
            try out.print(
                "{{\"phases\":\"scan\",\"span\":{d},\"weight\":{d},\"engine\":\"{s}\",\"ns_per_window\":{d:.3},\"mb_per_second\":{d:.1},\"windows\":{d},\"checksum\":{d}}}\n",
                .{
                    mask.span,
                    mask.weight,
                    @tagName(engine),
                    @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(sink.windows)),
                    mbPerSecond(seq.len, elapsed),
                    sink.windows,
                    sink.checksum,
                },
            );
        }
    }

    try out.flush();
}
