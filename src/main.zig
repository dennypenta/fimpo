const std = @import("std");

const ImportKind = enum {
    std_root,
    std_use,
    third_party,
    local,
    relative,
};

const ImportLine = struct {
    line: []const u8,
    lhs: []const u8,
    path: []const u8,
    kind: ImportKind,
};

fn parseImportLine(line: []const u8) ?ImportLine {
    if (line.len == 0) return null;
    if (line[0] == ' ' or line[0] == '\t') return null;

    const prefix = "const ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;

    const eq_marker = " = ";
    const eq_idx = std.mem.indexOf(u8, line, eq_marker) orelse return null;
    const lhs = line[prefix.len..eq_idx];
    const rhs = line[eq_idx + eq_marker.len ..];

    if (!std.mem.endsWith(u8, rhs, ";")) return null;
    const rhs_body = rhs[0 .. rhs.len - 1];

    const import_prefix = "@import(\"";
    if (std.mem.startsWith(u8, rhs_body, import_prefix) and std.mem.endsWith(u8, rhs_body, "\")")) {
        const path = rhs_body[import_prefix.len .. rhs_body.len - 2];

        if (std.mem.eql(u8, path, "std")) {
            return .{ .line = line, .lhs = lhs, .path = path, .kind = .std_root };
        }

        if (!std.mem.endsWith(u8, path, ".zig")) {
            return .{ .line = line, .lhs = lhs, .path = path, .kind = .third_party };
        }

        if (std.mem.indexOfScalar(u8, path, '/')) |_| {
            return .{ .line = line, .lhs = lhs, .path = path, .kind = .relative };
        }

        return .{ .line = line, .lhs = lhs, .path = path, .kind = .local };
    }

    if (std.mem.startsWith(u8, rhs_body, "std.")) {
        return .{ .line = line, .lhs = lhs, .path = "", .kind = .std_use };
    }

    return null;
}

fn sortByLhs(items: []ImportLine) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1].lhs, items[j].lhs) == .gt) : (j -= 1) {
            std.mem.swap(ImportLine, &items[j - 1], &items[j]);
        }
    }
}

fn sortByPath(items: []ImportLine) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1].path, items[j].path) == .gt) : (j -= 1) {
            std.mem.swap(ImportLine, &items[j - 1], &items[j]);
        }
    }
}

fn appendGroup(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), group: []const ImportLine) !void {
    if (group.len == 0) return;

    if (lines.items.len != 0) {
        try lines.append(allocator, "");
    }

    for (group) |entry| {
        try lines.append(allocator, entry.line);
    }
}

fn appendLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), group: []const ImportLine) !void {
    for (group) |entry| {
        try lines.append(allocator, entry.line);
    }
}

fn appendJoined(allocator: std.mem.Allocator, builder: *std.ArrayList(u8), lines: []const []const u8) !void {
    for (lines, 0..) |line, idx| {
        if (idx != 0) try builder.append(allocator, '\n');
        try builder.appendSlice(allocator, line);
    }
}

pub fn formatImports(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var std_roots = std.ArrayList(ImportLine).empty;
    defer std_roots.deinit(allocator);
    var std_uses = std.ArrayList(ImportLine).empty;
    defer std_uses.deinit(allocator);
    var third_party = std.ArrayList(ImportLine).empty;
    defer third_party.deinit(allocator);
    var local = std.ArrayList(ImportLine).empty;
    defer local.deinit(allocator);
    var relative = std.ArrayList(ImportLine).empty;
    defer relative.deinit(allocator);
    var body_lines = std.ArrayList([]const u8).empty;
    defer body_lines.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, input, '\n');
    while (line_it.next()) |line| {
        const parsed = parseImportLine(line);
        if (parsed) |entry| {
            switch (entry.kind) {
                .std_root => try std_roots.append(allocator, entry),
                .std_use => try std_uses.append(allocator, entry),
                .third_party => try third_party.append(allocator, entry),
                .local => try local.append(allocator, entry),
                .relative => try relative.append(allocator, entry),
            }
        } else {
            try body_lines.append(allocator, line);
        }
    }

    while (body_lines.items.len > 0 and body_lines.items[0].len == 0) {
        _ = body_lines.orderedRemove(0);
    }

    sortByLhs(std_roots.items);
    sortByLhs(std_uses.items);
    sortByPath(third_party.items);
    sortByPath(local.items);
    sortByPath(relative.items);

    var import_lines = std.ArrayList([]const u8).empty;
    defer import_lines.deinit(allocator);

    if (std_roots.items.len != 0 or std_uses.items.len != 0) {
        try appendLines(allocator, &import_lines, std_roots.items);
        try appendLines(allocator, &import_lines, std_uses.items);
    }

    try appendGroup(allocator, &import_lines, third_party.items);
    try appendGroup(allocator, &import_lines, local.items);
    try appendGroup(allocator, &import_lines, relative.items);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (import_lines.items.len != 0) {
        try appendJoined(allocator, &out, import_lines.items);
        if (body_lines.items.len != 0) {
            try out.appendSlice(allocator, "\n\n");
        }
    }

    if (body_lines.items.len != 0) {
        try appendJoined(allocator, &out, body_lines.items);
    }

    return out.toOwnedSlice(allocator);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin = std.io.getStdIn().reader();
    const input = try stdin.readAllAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(input);

    const output = try formatImports(allocator, input);
    defer allocator.free(output);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(output);
}

fn expectFormatted(input: []const u8, expected: []const u8) !void {
    const actual = try formatImports(std.testing.allocator, input);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test fimpo" {
    const in1 =
        \\const bar = @import("bar.zig");
        \\const fs = std.fs;
        \\const zeit = @import("zeit");
        \\const std = @import("std");
        \\
        \\pub fn demo() void {
        \\    _ = fs;
        \\}
    ;
    const out1 =
        \\const std = @import("std");
        \\const fs = std.fs;
        \\
        \\const zeit = @import("zeit");
        \\
        \\const bar = @import("bar.zig");
        \\
        \\pub fn demo() void {
        \\    _ = fs;
        \\}
    ;

    const in2 =
        \\const fax = @import("../fax.zig");
        \\const baz = @import("baz.zig");
        \\const node = @import("tree/node.zig");
        \\const qux = @import("../qux.zig");
        \\const tree = @import("tree/tree.zig");
        \\
        \\test "noise" {
        \\    try std.testing.expect(true);
        \\}
    ;
    const out2 =
        \\const baz = @import("baz.zig");
        \\
        \\const fax = @import("../fax.zig");
        \\const qux = @import("../qux.zig");
        \\const node = @import("tree/node.zig");
        \\const tree = @import("tree/tree.zig");
        \\
        \\test "noise" {
        \\    try std.testing.expect(true);
        \\}
    ;

    const in3 =
        \\const node = @import("tree/node.zig");
        \\const bar = @import("bar.zig");
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const foo = @import("foo");
        \\
        \\const testing = std.testing;
        \\test "tiny" {
        \\    try testing.expect(mem.eql(u8, "a", "a"));
        \\}
    ;
    const out3 =
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const testing = std.testing;
        \\
        \\const foo = @import("foo");
        \\
        \\const bar = @import("bar.zig");
        \\
        \\const node = @import("tree/node.zig");
        \\
        \\test "tiny" {
        \\    try testing.expect(mem.eql(u8, "a", "a"));
        \\}
    ;

    const in4 =
        \\const baz = @import("baz.zig");
        \\const std = @import("std");
        \\const foo = @import("vendor");
        \\const fax = @import("../fax.zig");
        \\
        \\pub const V = struct {
        \\    pub fn ok() bool {
        \\        return true;
        \\    }
        \\};
    ;
    const out4 =
        \\const std = @import("std");
        \\
        \\const foo = @import("vendor");
        \\
        \\const baz = @import("baz.zig");
        \\
        \\const fax = @import("../fax.zig");
        \\
        \\pub const V = struct {
        \\    pub fn ok() bool {
        \\        return true;
        \\    }
        \\};
    ;

    const in5 =
        \\const node = @import("tree/node.zig");
        \\const std = @import("std");
        \\const fmt = std.fmt;
        \\const bar = @import("bar.zig");
        \\const fs = std.fs;
        \\const dep = @import("dep");
        \\
        \\fn render() []const u8 {
        \\    return fmt.comptimePrint("{s}", .{"x"});
        \\}
    ;
    const out5 =
        \\const std = @import("std");
        \\const fmt = std.fmt;
        \\const fs = std.fs;
        \\
        \\const dep = @import("dep");
        \\
        \\const bar = @import("bar.zig");
        \\
        \\const node = @import("tree/node.zig");
        \\
        \\fn render() []const u8 {
        \\    return fmt.comptimePrint("{s}", .{"x"});
        \\}
    ;

    const in6 =
        \\const foo = @import("foo");
        \\const std = @import("std");
        \\const alpha = @import("alpha.zig");
        \\const beta = @import("../beta.zig");
        \\
        \\const testing = std.testing;
        \\test "last" {
        \\    try testing.expect(true);
        \\}
    ;
    const out6 =
        \\const std = @import("std");
        \\const testing = std.testing;
        \\
        \\const foo = @import("foo");
        \\
        \\const alpha = @import("alpha.zig");
        \\
        \\const beta = @import("../beta.zig");
        \\
        \\test "last" {
        \\    try testing.expect(true);
        \\}
    ;

    const in7 =
        \\const foo = @import("foo");
        \\const std = @import("std");
        \\const alpha = @import("alpha.zig");
        \\const beta = @import("../beta.zig");
        \\
        \\fn render() []const u8 {
        \\    return fmt.comptimePrint("{s}", .{"x"});
        \\}
        \\
        \\const testing = std.testing;
        \\test "last" {
        \\    try testing.expect(true);
        \\}
    ;
    const out7 =
        \\const std = @import("std");
        \\const testing = std.testing;
        \\
        \\const foo = @import("foo");
        \\
        \\const alpha = @import("alpha.zig");
        \\
        \\const beta = @import("../beta.zig");
        \\
        \\fn render() []const u8 {
        \\    return fmt.comptimePrint("{s}", .{"x"});
        \\}
        \\
        \\test "last" {
        \\    try testing.expect(true);
        \\}
    ;

    try expectFormatted(in1, out1);
    try expectFormatted(in2, out2);
    try expectFormatted(in3, out3);
    try expectFormatted(in4, out4);
    try expectFormatted(in5, out5);
    try expectFormatted(in6, out6);
    try expectFormatted(in7, out7);
}
