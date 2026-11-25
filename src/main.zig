const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const extract = @import("extract.zig");
const fasta = @import("fasta.zig");
const scan = @import("scan.zig");
const count = @import("count.zig");
const report = @import("report.zig");
const reference = @import("reference.zig");
const host = @import("host.zig");

const max_bases: usize = 64 << 20;
const max_file: usize = max_bases + (8 << 20);

const TimedSink = struct {
    checksum: u64 = 0,
    windows: u64 = 0,

    pub fn emit(self: *TimedSink, kmer: u64) !void {
        self.checksum ^= kmer;
        self.windows += 1;
    }
};

const Args = struct {
    fasta_path: []const u8,
    mask_text: []const u8,
    out_path: []const u8,
    budget: ?f64,
};

fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\kmerbudget scan <fasta> --mask <bits> --out <tsv> [--budget <MB/s>]
        \\  Measures extraction throughput and counts canonical spaced k-mers.
        \\  --mask    binary mask over the span, e.g. 1110011 (first base is leftmost)
        \\  --out     TSV path for kmer and count columns
        \\  --budget  optional MB/s/core threshold for a PASS/FAIL verdict
        \\
        \\kmerbudget serve [--port <n>]
        \\  Serves the no-JS measurement page on 127.0.0.1.
        \\
        \\kmerbudget seed [--mb n] [--seed n] [--n-rate r] --out <fasta>
        \\  Writes a deterministic splitmix64 corpus.
        \\
        \\kmerbudget design <fasta> [-k span] [-w weight] [--error rate] [--iterations n] [--seed n] [--budget MB/s]
        \\  Hill-climbs a mask against planted substitutions and indels; proxy is not a guarantee.
        \\
    );
}

fn parseScanArgs(args: []const []const u8) !Args {
    var fasta_path: ?[]const u8 = null;
    var mask_text: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var budget: ?f64 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mask")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            mask_text = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--budget")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            budget = try std.fmt.parseFloat(f64, args[i]);
            if (!(budget.? > 0)) return error.InvalidBudget;
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.UnknownFlag;
        } else {
            if (fasta_path != null) return error.TooManyInputs;
            fasta_path = arg;
        }
    }
    return .{
        .fasta_path = fasta_path orelse return error.MissingInput,
        .mask_text = mask_text orelse return error.MissingMask,
        .out_path = out_path orelse return error.MissingOutput,
        .budget = budget,
    };
}

fn scanCommand(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const parsed = try parseScanArgs(args);
    const mask = extract.Mask.parse(parsed.mask_text) catch return error.InvalidMask;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, parsed.fasta_path, arena, .limited(max_file));
    var corpus = try fasta.Fasta.parse(arena, source, max_bases);
    defer corpus.deinit();

    const scanner = scan.Scanner.init(mask);
    var timed: TimedSink = .{};
    const start = std.Io.Clock.now(.cpu_thread, io);
    for (corpus.records) |record| {
        try scanner.scan(record, &timed);
    }
    const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - start.nanoseconds;
    std.mem.doNotOptimizeAway(timed.checksum);

    var collector = count.Collector.init(arena, mask.weight);
    for (corpus.records) |record| {
        try scanner.scan(record, &collector);
    }
    collector.sort();

    const counts_file = try std.Io.Dir.cwd().createFile(io, parsed.out_path, .{});
    defer counts_file.close(io);
    var counts_buffer: [16384]u8 = undefined;
    var counts_writer: std.Io.File.Writer = .init(counts_file, io, &counts_buffer);
    const unique = try report.writeCounts(&counts_writer.interface, collector.groups(), mask.weight);
    try counts_writer.interface.flush();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var host_buffer: [256]u8 = undefined;
    const summary = report.Summary{
        .mask = parsed.mask_text,
        .span = mask.span,
        .weight = mask.weight,
        .engine = @tagName(scanner.kind),
        .records = corpus.records.len,
        .input_bases = corpus.bases.len,
        .windows = timed.windows,
        .unique_kmers = unique,
        .counts_path = parsed.out_path,
        .ns_per_window = if (timed.windows == 0) 0 else @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(timed.windows)),
        .mb_per_second = if (elapsed == 0) 0 else @as(f64, @floatFromInt(corpus.bases.len)) * 1000.0 / @as(f64, @floatFromInt(elapsed)),
        .budget_mb_per_second = parsed.budget,
        .host = host.cpuName(&host_buffer, io),
        .arch = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
        .compiler = builtin.zig_version_string,
        .mode = @tagName(builtin.mode),
        .commit = build_options.commit,
        .fisk_sha = reference.fisk_sha,
    };
    try summary.writeJson(&stdout_file_writer.interface);
    try stdout_file_writer.interface.flush();
}

fn designCommand(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var fasta_path: ?[]const u8 = null;
    var span: u16 = 16;
    var weight: u16 = 8;
    var error_rate: f64 = 0.02;
    var iterations: usize = 200;
    var seed: u64 = 20261125;
    var budget: ?f64 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-k")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            span = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "-w")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            weight = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--error")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            error_rate = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            iterations = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--budget")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            budget = try std.fmt.parseFloat(f64, args[i]);
            if (!(budget.? > 0)) return error.InvalidBudget;
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.UnknownFlag;
        } else {
            if (fasta_path != null) return error.TooManyInputs;
            fasta_path = arg;
        }
    }
    const path = fasta_path orelse return error.MissingInput;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file));
    var corpus = try fasta.Fasta.parse(arena, source, max_bases);
    defer corpus.deinit();

    const outcome = @import("design.zig").design(
        arena,
        corpus.records,
        span,
        weight,
        error_rate,
        iterations,
        seed,
        512,
    ) catch |err| switch (err) {
        error.InvalidSpan => return error.InvalidSpan,
        error.InvalidWeight => return error.InvalidWeight,
        error.InvalidErrorRate => return error.InvalidErrorRate,
        error.NoUsableWindows => return error.NoUsableWindows,
        else => return err,
    };

    var mask_buffer: [32]u8 = undefined;
    const mask_text = @import("design.zig").formatMask(outcome.mask, &mask_buffer);
    const scanner = scan.Scanner.init(outcome.mask);
    var timed: TimedSink = .{};
    const start = std.Io.Clock.now(.cpu_thread, io);
    for (corpus.records) |record| try scanner.scan(record, &timed);
    const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - start.nanoseconds;
    std.mem.doNotOptimizeAway(timed.checksum);
    const mb_per_second = @as(f64, @floatFromInt(corpus.bases.len)) * 1000.0 / @as(f64, @floatFromInt(elapsed));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;
    try out.writeAll("{\"mask\":");
    try report.writeJsonString(out, mask_text);
    try out.print(",\"span\":{d},\"weight\":{d},\"proxy\":{d:.4},\"events\":{d}", .{
        outcome.mask.span, outcome.mask.weight, outcome.proxy, outcome.events,
    });
    try out.print(",\"input_bases\":{d},\"mb_per_second\":{d:.1},\"budget_mb_per_second\":", .{
        corpus.bases.len, mb_per_second,
    });
    if (budget) |target| {
        try out.print("{d:.1}", .{target});
    } else {
        try out.writeAll("null");
    }
    try out.writeAll(",\"verdict\":");
    if (report.verdictFor(mb_per_second, budget, corpus.bases.len, timed.windows)) |verdict| {
        try out.writeByte('"');
        try out.writeAll(report.verdictText(verdict));
        try out.writeByte('"');
    } else {
        try out.writeAll("null");
    }
    try out.writeAll(",\"host\":");
    var host_buffer: [256]u8 = undefined;
    try report.writeJsonString(out, host.cpuName(&host_buffer, io));
    try out.writeAll(",\"compiler\":");
    try report.writeJsonString(out, builtin.zig_version_string);
    try out.writeAll(",\"mode\":");
    try report.writeJsonString(out, @tagName(builtin.mode));
    try out.writeAll(",\"commit\":");
    try report.writeJsonString(out, build_options.commit);
    try out.writeAll(",\"fisk_sha\":");
    try report.writeJsonString(out, reference.fisk_sha);
    try out.print(",\"seed\":{d},\"error_rate\":{d:.4},\"iterations\":{d},\"command\":", .{
        seed, error_rate, iterations,
    });
    var command_buffer: [512]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "kmerbudget design {s} -k {d} -w {d} --error {d} --iterations {d} --seed {d}", .{
        path, span, weight, error_rate, iterations, seed,
    });
    try report.writeJsonString(out, command);
    try out.writeAll("}\n");
    try out.flush();
}

fn seedCommand(init: std.process.Init, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var megabytes: usize = 1;
    var seed: u64 = 20261125;
    var invalid_rate: f64 = 0.001;
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--mb")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            megabytes = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            seed = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--n-rate")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            invalid_rate = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            out_path = args[i];
        } else {
            return error.UnknownFlag;
        }
    }
    const path = out_path orelse return error.MissingOutput;
    const bases = try @import("seed.zig").generate(arena, megabytes << 20, seed, invalid_rate);
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, ">seed\n");
    try text.appendSlice(arena, bases);
    try text.append(arena, '\n');
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.items });
}

fn run(init: std.process.Init, args: []const []const u8) !void {
    if (args.len < 2) return error.MissingCommand;
    const command = args[1];
    if (std.mem.eql(u8, command, "scan")) return scanCommand(init, args[2..]);
    if (std.mem.eql(u8, command, "design")) return designCommand(init, args[2..]);
    if (std.mem.eql(u8, command, "seed")) return seedCommand(init, args[2..]);
    if (std.mem.eql(u8, command, "serve")) {
        var port: u16 = 8080;
        if (args.len > 3 and std.mem.eql(u8, args[2], "--port")) {
            port = try std.fmt.parseInt(u16, args[3], 10);
        } else if (args.len > 2) {
            return error.InvalidServeArgs;
        }
        return @import("server.zig").serve(init.io, port);
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        var buffer: [4096]u8 = undefined;
        var out: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
        try usage(&out.interface);
        try out.interface.flush();
        return;
    }
    return error.UnknownCommand;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    run(init, args) catch |err| {
        var buffer: [4096]u8 = undefined;
        var err_writer: std.Io.File.Writer = .init(.stderr(), init.io, &buffer);
        try err_writer.interface.print("error: {s}\n\n", .{@errorName(err)});
        usage(&err_writer.interface) catch {};
        err_writer.interface.flush() catch {};
        std.process.exit(2);
    };
}
