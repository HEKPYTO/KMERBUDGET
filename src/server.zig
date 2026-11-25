const std = @import("std");
const builtin = @import("builtin");
const extract = @import("extract.zig");
const fasta = @import("fasta.zig");
const scan = @import("scan.zig");
const count = @import("count.zig");
const canon = @import("canon.zig");
const reference = @import("reference.zig");
const report = @import("report.zig");

const max_body: usize = 16 << 20;
const max_bases: usize = 8 << 20;
const max_rows: usize = 500;

const TimedSink = struct {
    checksum: u64 = 0,
    windows: u64 = 0,

    pub fn emit(self: *TimedSink, kmer: u64) !void {
        self.checksum ^= kmer;
        self.windows += 1;
    }
};

const Escape = struct {
    pub fn write(writer: anytype, value: []const u8) !void {
        for (value) |c| {
            switch (c) {
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                '&' => try writer.writeAll("&amp;"),
                '"' => try writer.writeAll("&quot;"),
                '\'' => try writer.writeAll("&#39;"),
                else => try writer.writeByte(c),
            }
        }
    }
};

fn pageStart(writer: anytype) !void {
    try writer.writeAll(
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>kmerbudget</title>
        \\<style>
        \\:root{color-scheme:light dark;--line:#8a8a8a55}body{font:16px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;max-width:60rem;margin:2rem auto;padding:0 1rem}
        \\h1{font-size:1.4rem}h2{font-size:1.1rem;margin-top:2rem}form{display:grid;gap:.75rem}label{display:grid;gap:.25rem}
        \\textarea,input,button{font:inherit;padding:.5rem;border:1px solid var(--line);border-radius:.35rem;background:transparent;color:inherit}
        \\textarea{min-height:8rem}button{width:max-content;cursor:pointer}table{border-collapse:collapse;width:100%;margin-top:.5rem}
        \\th,td{text-align:left;padding:.25rem .5rem;border-bottom:1px solid var(--line)}td.num{text-align:right;font-variant-numeric:tabular-nums}
        \\dl{display:grid;grid-template-columns:max-content 1fr;gap:.2rem 1rem}dt{color:#888}dd{margin:0}
        \\.muted{color:#888}.fail{color:#b00020}.pass{color:#0a7d32}
        \\</style></head><body>
        \\<h1>kmerbudget</h1>
        \\<p class="muted">Measured spaced-k-mer extraction. Canonical counts, no JavaScript, no retained input.</p>
        \\
    );
}

fn pageEnd(writer: anytype) !void {
    try writer.writeAll("</body></html>\n");
}

fn formPage(writer: anytype) !void {
    try pageStart(writer);
    try writer.writeAll(
        \\<h2>Measure a mask</h2>
        \\<form method="post" action="/scan">
        \\<label>FASTA (max 8 MB) <textarea name="fasta" required placeholder=">seq&#10;ACGT..."></textarea></label>
        \\<label>Mask <input name="mask" required pattern="[01]{1,32}" placeholder="1100110011001100"></label>
        \\<label>Speed budget, MB/s/core (optional) <input name="budget" type="number" min="1" step="any"></label>
        \\<button type="submit">Measure</button>
        \\</form>
        \\<h2>Design a mask</h2>
        \\<p class="muted">Deterministic hill-climb against planted substitutions and indels. The score is a detection proxy, not a sensitivity guarantee.</p>
        \\<form method="post" action="/design">
        \\<label>FASTA (max 8 MB) <textarea name="fasta" required placeholder=">seq&#10;ACGT..."></textarea></label>
        \\<label>Span <input name="span" type="number" min="1" max="32" value="16" required></label>
        \\<label>Weight <input name="weight" type="number" min="1" max="32" value="8" required></label>
        \\<label>Error rate <input name="error" type="number" min="0.0001" max="1" step="any" value="0.02" required></label>
        \\<label>Speed budget, MB/s/core (optional) <input name="budget" type="number" min="1" step="any"></label>
        \\<button type="submit">Design</button>
        \\</form>
        \\
    );
    try pageEnd(writer);
}

fn renderResult(
    writer: anytype,
    mask_text: []const u8,
    mask: extract.Mask,
    engine: []const u8,
    bases: usize,
    windows: u64,
    unique: u64,
    ns_per_window: f64,
    mb_per_second: f64,
    budget: ?f64,
    groups: *count.Groups,
) !void {
    try pageStart(writer);
    try writer.writeAll("<h2>Result</h2><dl>");
    try writer.writeAll("<dt>mask</dt><dd>");
    try Escape.write(writer, mask_text);
    try writer.print("</dd><dt>span / weight</dt><dd>{d} / {d}</dd>", .{ mask.span, mask.weight });
    try writer.writeAll("<dt>engine</dt><dd>");
    try Escape.write(writer, engine);
    try writer.print(
        "</dd><dt>input bases</dt><dd>{d}</dd><dt>windows</dt><dd>{d}</dd><dt>unique k-mers</dt><dd>{d}</dd><dt>throughput</dt><dd>{d:.1} MB/s/core ({d:.3} ns/window)</dd>",
        .{ bases, windows, unique, mb_per_second, ns_per_window },
    );
    if (budget) |target| {
        try writer.print("<dt>budget</dt><dd>{d:.1} MB/s/core</dd><dt>verdict</dt><dd>", .{target});
        const verdict = report.verdictFor(mb_per_second, budget, bases, windows).?;
        switch (verdict) {
            .pass => try writer.writeAll("<span class=\"pass\">PASS</span>"),
            .fail => try writer.writeAll("<span class=\"fail\">FAIL</span>"),
            .inconclusive => try writer.writeAll("<span class=\"muted\">INCONCLUSIVE</span>"),
        }
        try writer.writeAll("</dd>");
    }
    try writer.writeAll("</dl><h2>Counts</h2>");
    if (unique > max_rows) {
        try writer.print("<p class=\"muted\">Showing the first {d} of {d} canonical k-mers in key order.</p>", .{ max_rows, unique });
    }
    try writer.writeAll("<table><thead><tr><th>k-mer</th><th class=\"num\">count</th></tr></thead><tbody>");
    var shown: usize = 0;
    var buf: [32]u8 = undefined;
    while (shown < max_rows) : (shown += 1) {
        const entry = groups.next() orelse break;
        const text = buf[0..mask.weight];
        canon.decode(entry.key, mask.weight, text);
        try writer.writeAll("<tr><td>");
        try Escape.write(writer, text);
        try writer.print("</td><td class=\"num\">{d}</td></tr>", .{entry.count});
    }
    try writer.writeAll("</tbody></table><h2>Reproduce</h2><pre>kmerbudget scan input.fa --mask ");
    try Escape.write(writer, mask_text);
    try writer.writeAll(" --out counts.tsv");
    if (budget) |target| try writer.print(" --budget {d:.1}", .{target});
    try writer.print("</pre><p class=\"muted\">{s} · fisk {s} · Zig {s} · {s}</p>", .{
        reference.paper,
        reference.fisk_sha[0..12],
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    try pageEnd(writer);
}

fn errorPage(writer: anytype, message: []const u8) !void {
    try pageStart(writer);
    try writer.writeAll("<h2 class=\"fail\">Error</h2><p>");
    try Escape.write(writer, message);
    try writer.writeAll("</p><p><a href=\"/\">Back</a></p>");
    try pageEnd(writer);
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '+' => try out.append(allocator, ' '),
            '%' => {
                if (i + 2 >= input.len) return error.InvalidForm;
                const hi = std.fmt.charToDigit(input[i + 1], 16) catch return error.InvalidForm;
                const lo = std.fmt.charToDigit(input[i + 2], 16) catch return error.InvalidForm;
                try out.append(allocator, hi << 4 | lo);
                i += 2;
            },
            else => try out.append(allocator, input[i]),
        }
    }
    return out.toOwnedSlice(allocator);
}

const Form = struct {
    fasta: ?[]const u8 = null,
    mask: ?[]const u8 = null,
    budget: ?[]const u8 = null,
    span: ?[]const u8 = null,
    weight: ?[]const u8 = null,
    error_rate: ?[]const u8 = null,

    fn parse(allocator: std.mem.Allocator, body: []const u8) !Form {
        var form: Form = .{};
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidForm;
            const key = try percentDecode(allocator, pair[0..eq]);
            const value = try percentDecode(allocator, pair[eq + 1 ..]);
            if (std.mem.eql(u8, key, "fasta")) {
                form.fasta = value;
            } else if (std.mem.eql(u8, key, "mask")) {
                form.mask = value;
            } else if (std.mem.eql(u8, key, "budget")) {
                form.budget = value;
            } else if (std.mem.eql(u8, key, "span")) {
                form.span = value;
            } else if (std.mem.eql(u8, key, "weight")) {
                form.weight = value;
            } else if (std.mem.eql(u8, key, "error")) {
                form.error_rate = value;
            }
        }
        return form;
    }
};

fn scanForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    body: []const u8,
    out: *std.Io.Writer,
) !void {
    const form = Form.parse(allocator, body) catch {
        try errorPage(out, "Malformed form body.");
        return;
    };
    const fasta_text = form.fasta orelse {
        try errorPage(out, "Missing FASTA input.");
        return;
    };
    if (fasta_text.len > max_bases) {
        try errorPage(out, "FASTA exceeds 8 MB of bases.");
        return;
    }
    const mask_text = form.mask orelse {
        try errorPage(out, "Missing mask.");
        return;
    };
    const mask = extract.Mask.parse(mask_text) catch {
        try errorPage(out, "Mask must be 1-32 characters of 0 and 1 with at least one 1.");
        return;
    };
    var budget: ?f64 = null;
    if (form.budget) |text| {
        if (text.len > 0) {
            budget = std.fmt.parseFloat(f64, text) catch {
                try errorPage(out, "Budget must be a positive number.");
                return;
            };
            if (!(budget.? > 0)) {
                try errorPage(out, "Budget must be a positive number.");
                return;
            }
        }
    }
    var corpus = fasta.Fasta.parse(allocator, fasta_text, max_bases) catch {
        try errorPage(out, "FASTA is empty or exceeds 8 MB of bases.");
        return;
    };
    defer corpus.deinit();

    const scanner = scan.Scanner.init(mask);
    var timed: TimedSink = .{};
    const start = std.Io.Clock.now(.cpu_thread, io);
    for (corpus.records) |record| try scanner.scan(record, &timed);
    const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - start.nanoseconds;
    std.mem.doNotOptimizeAway(timed.checksum);

    var collector = count.Collector.init(allocator, mask.weight);
    for (corpus.records) |record| try scanner.scan(record, &collector);
    collector.sort();

    var groups = collector.groups();
    var unique: u64 = 0;
    {
        var peek = groups;
        while (peek.next() != null) unique += 1;
    }

    const ns_per_window = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(timed.windows));
    const mb_per_second = @as(f64, @floatFromInt(corpus.bases.len)) * 1000.0 / @as(f64, @floatFromInt(elapsed));
    try renderResult(
        out,
        mask_text,
        mask,
        @tagName(scanner.kind),
        corpus.bases.len,
        timed.windows,
        unique,
        ns_per_window,
        mb_per_second,
        budget,
        &groups,
    );
}

fn renderDesign(
    writer: anytype,
    mask_text: []const u8,
    mask: extract.Mask,
    proxy: f64,
    events: usize,
    bases: usize,
    windows: u64,
    mb_per_second: f64,
    budget: ?f64,
    command: []const u8,
) !void {
    try pageStart(writer);
    try writer.writeAll("<h2>Designed mask</h2><dl><dt>mask</dt><dd>");
    try Escape.write(writer, mask_text);
    try writer.print("</dd><dt>span / weight</dt><dd>{d} / {d}</dd>", .{ mask.span, mask.weight });
    try writer.print("</dd><dt>proxy</dt><dd>{d:.4} over {d} planted events</dd>", .{ proxy, events });
    try writer.print("<dt>input bases</dt><dd>{d}</dd><dt>throughput</dt><dd>{d:.1} MB/s/core</dd>", .{ bases, mb_per_second });
    if (budget) |target| {
        try writer.print("<dt>budget</dt><dd>{d:.1} MB/s/core</dd><dt>verdict</dt><dd>", .{target});
        const verdict = report.verdictFor(mb_per_second, budget, bases, windows).?;
        switch (verdict) {
            .pass => try writer.writeAll("<span class=\"pass\">PASS</span>"),
            .fail => try writer.writeAll("<span class=\"fail\">FAIL</span>"),
            .inconclusive => try writer.writeAll("<span class=\"muted\">INCONCLUSIVE</span>"),
        }
        try writer.writeAll("</dd>");
    }
    try writer.writeAll("</dl><h2>Reproduce</h2><pre>");
    try Escape.write(writer, command);
    try writer.writeAll("</pre><p class=\"muted\">Proxy is not a sensitivity guarantee.</p>");
    try pageEnd(writer);
}

fn designForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    body: []const u8,
    out: *std.Io.Writer,
) !void {
    const form = Form.parse(allocator, body) catch {
        try errorPage(out, "Malformed form body.");
        return;
    };
    const fasta_text = form.fasta orelse {
        try errorPage(out, "Missing FASTA input.");
        return;
    };
    if (fasta_text.len > max_bases) {
        try errorPage(out, "FASTA exceeds 8 MB of bases.");
        return;
    }
    const span = std.fmt.parseInt(u16, form.span orelse "16", 10) catch {
        try errorPage(out, "Span must be an integer in 1-32.");
        return;
    };
    const weight = std.fmt.parseInt(u16, form.weight orelse "8", 10) catch {
        try errorPage(out, "Weight must be an integer in 1-32.");
        return;
    };
    const error_rate = std.fmt.parseFloat(f64, form.error_rate orelse "0.02") catch {
        try errorPage(out, "Error rate must be a number in (0, 1].");
        return;
    };
    var budget: ?f64 = null;
    if (form.budget) |text| {
        if (text.len > 0) {
            budget = std.fmt.parseFloat(f64, text) catch {
                try errorPage(out, "Budget must be a positive number.");
                return;
            };
            if (!(budget.? > 0)) {
                try errorPage(out, "Budget must be a positive number.");
                return;
            }
        }
    }
    var corpus = fasta.Fasta.parse(allocator, fasta_text, max_bases) catch {
        try errorPage(out, "FASTA is empty or exceeds 8 MB of bases.");
        return;
    };
    defer corpus.deinit();

    const outcome = @import("design.zig").design(allocator, corpus.records, span, weight, error_rate, 200, 20261125, 512) catch |err| {
        switch (err) {
            error.InvalidSpan => try errorPage(out, "Span must be in 1-32."),
            error.InvalidWeight => try errorPage(out, "Weight must be in 1..span."),
            error.InvalidErrorRate => try errorPage(out, "Error rate must be in (0, 1]."),
            error.NoUsableWindows => try errorPage(out, "FASTA is too short or too repetitive for planted events."),
            else => try errorPage(out, "Design failed."),
        }
        return;
    };
    var mask_buffer: [32]u8 = undefined;
    const mask_text = @import("design.zig").formatMask(outcome.mask, &mask_buffer);
    const scanner = scan.Scanner.init(outcome.mask);
    var timed: TimedSink = .{};
    const start = std.Io.Clock.now(.cpu_thread, io);
    for (corpus.records) |record| try scanner.scan(record, &timed);
    const elapsed = std.Io.Clock.now(.cpu_thread, io).nanoseconds - start.nanoseconds;
    std.mem.doNotOptimizeAway(timed.checksum);
    const mb_per_second = if (elapsed == 0) 0 else @as(f64, @floatFromInt(corpus.bases.len)) * 1000.0 / @as(f64, @floatFromInt(elapsed));

    var command_buffer: [256]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "kmerbudget design input.fa -k {d} -w {d} --error {d} --seed 20261125", .{
        span, weight, error_rate,
    });
    try renderDesign(out, mask_text, outcome.mask, outcome.proxy, outcome.events, corpus.bases.len, timed.windows, mb_per_second, budget, command);
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var read_buffer: [8192]u8 = undefined;
    var body_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;
    const target = request.head.target[0..(std.mem.indexOfScalar(u8, request.head.target, '?') orelse request.head.target.len)];

    var page = std.Io.Writer.Allocating.init(allocator);
    defer page.deinit();
    var status: std.http.Status = .ok;

    if (std.mem.eql(u8, target, "/") and request.head.method == .GET) {
        try formPage(&page.writer);
    } else if (std.mem.eql(u8, target, "/scan") and request.head.method == .POST) {
        const body_reader = request.readerExpectNone(&body_buffer);
        const body = body_reader.allocRemaining(allocator, .limited(max_body)) catch {
            status = .payload_too_large;
            try errorPage(&page.writer, "Could not read the request body.");
            try request.respond(page.writer.buffered(), .{ .status = status, .keep_alive = false, .extra_headers = htmlHeaders });
            return;
        };
        try scanForm(allocator, io, body, &page.writer);
    } else if (std.mem.eql(u8, target, "/design") and request.head.method == .POST) {
        const body_reader = request.readerExpectNone(&body_buffer);
        const body = body_reader.allocRemaining(allocator, .limited(max_body)) catch {
            status = .payload_too_large;
            try errorPage(&page.writer, "Could not read the request body.");
            try request.respond(page.writer.buffered(), .{ .status = status, .keep_alive = false, .extra_headers = htmlHeaders });
            return;
        };
        try designForm(allocator, io, body, &page.writer);
    } else {
        status = .not_found;
        try errorPage(&page.writer, "Not found.");
    }
    try request.respond(page.writer.buffered(), .{ .status = status, .keep_alive = false, .extra_headers = htmlHeaders });
}

pub fn serve(io: std.Io, port: u16) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var err_buffer: [512]u8 = undefined;
    var err_writer: std.Io.File.Writer = .init(.stderr(), io, &err_buffer);
    try err_writer.interface.print("kmerbudget serving on http://127.0.0.1:{d}\n", .{port});
    try err_writer.interface.flush();
    while (true) {
        var stream = server.accept(io) catch continue;
        handleConnection(io, stream) catch {};
        stream.close(io);
    }
}

const htmlHeaders = &[_]std.http.Header{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
};
