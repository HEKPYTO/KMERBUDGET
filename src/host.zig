const std = @import("std");
const builtin = @import("builtin");

pub fn cpuName(buffer: []u8, io: std.Io) []const u8 {
    switch (builtin.os.tag) {
        .macos => if (macosName(buffer)) |name| return name,
        .linux => if (linuxName(buffer, io)) |name| return name,
        else => {},
    }
    return builtin.cpu.model.name;
}

fn macosName(buffer: []u8) ?[]const u8 {
    var size = buffer.len;
    if (std.c.sysctlbyname("machdep.cpu.brand_string", buffer.ptr, &size, null, 0) != 0 or size == 0) return null;
    return std.mem.trimEnd(u8, buffer[0..size], "\x00");
}

fn linuxName(buffer: []u8, io: std.Io) ?[]const u8 {
    var file = std.Io.Dir.cwd().openFile(io, "/proc/cpuinfo", .{}) catch return null;
    defer file.close(io);
    const size = file.readPositionalAll(io, buffer, 0) catch return null;
    var lines = std.mem.splitScalar(u8, buffer[0..size], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

test "cpu name is not empty" {
    var buffer: [256]u8 = undefined;
    const name = cpuName(&buffer, std.testing.io);
    try std.testing.expect(name.len > 0);
}
