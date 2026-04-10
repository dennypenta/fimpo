const std = @import("std");
const Ast = std.zig.Ast;

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
    line_index: usize,
};

fn classifyPath(path: []const u8) ImportKind {
    if (std.mem.eql(u8, path, "std")) return .std_root;
    if (!std.mem.endsWith(u8, path, ".zig")) return .third_party;
    if (std.mem.indexOfScalar(u8, path, '/')) |_| return .relative;
    return .local;
}

fn nodeSource(tree: Ast, node: Ast.Node.Index) []const u8 {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    const start = tree.tokenStart(first);
    const end = tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len));
    return tree.source[start..end];
}

fn parseImportDecl(tree: Ast, node: Ast.Node.Index, line: []const u8, line_index: usize) ?ImportLine {
    const var_decl = tree.fullVarDecl(node) orelse return null;
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return null;

    const lhs_token = var_decl.ast.mut_token + 1;
    if (tree.tokenTag(lhs_token) != .identifier) return null;
    const lhs = tree.tokenSlice(lhs_token);

    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    const init_tag = tree.nodeTag(init_node);

    switch (init_tag) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@import")) return null;

            var buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&buffer, init_node) orelse return null;
            if (params.len != 1) return null;

            const arg_src = nodeSource(tree, params[0]);
            if (arg_src.len < 2 or arg_src[0] != '"' or arg_src[arg_src.len - 1] != '"') return null;
            const path = arg_src[1 .. arg_src.len - 1];

            return .{
                .line = line,
                .lhs = lhs,
                .path = path,
                .kind = classifyPath(path),
                .line_index = line_index,
            };
        },
        else => {
            const init_src = nodeSource(tree, init_node);
            if (!std.mem.startsWith(u8, init_src, "std.")) return null;

            return .{
                .line = line,
                .lhs = lhs,
                .path = "",
                .kind = .std_use,
                .line_index = line_index,
            };
        },
    }
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
    const source_z = try allocator.dupeZ(u8, input);
    defer allocator.free(source_z);

    var tree = try Ast.parse(allocator, source_z, .zig);
    defer tree.deinit(allocator);

    if (tree.errors.len != 0) {
        return allocator.dupe(u8, input);
    }

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

    var all_lines = std.ArrayList([]const u8).empty;
    defer all_lines.deinit(allocator);
    var line_starts = std.ArrayList(usize).empty;
    defer line_starts.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, input, '\n');
    var byte_pos: usize = 0;
    while (line_it.next()) |line| {
        try all_lines.append(allocator, line);
        try line_starts.append(allocator, byte_pos);
        byte_pos += line.len + 1;
    }

    const is_import_line = try allocator.alloc(bool, all_lines.items.len);
    defer allocator.free(is_import_line);
    @memset(is_import_line, false);

    var line_cursor: usize = 0;
    for (tree.rootDecls()) |decl| {
        const first_tok = tree.firstToken(decl);
        const decl_start = @as(usize, tree.tokenStart(first_tok));

        while (line_cursor + 1 < line_starts.items.len and line_starts.items[line_cursor + 1] <= decl_start) {
            line_cursor += 1;
        }
        if (line_cursor >= all_lines.items.len) continue;

        const line = all_lines.items[line_cursor];
        if (std.mem.indexOfScalar(u8, line, '\r')) |_| {
            continue;
        }
        if (std.mem.indexOfScalar(u8, line, '\n')) |_| {
            continue;
        }

        const parsed = parseImportDecl(tree, decl, line, line_cursor) orelse continue;
        is_import_line[parsed.line_index] = true;

        switch (parsed.kind) {
            .std_root => try std_roots.append(allocator, parsed),
            .std_use => try std_uses.append(allocator, parsed),
            .third_party => try third_party.append(allocator, parsed),
            .local => try local.append(allocator, parsed),
            .relative => try relative.append(allocator, parsed),
        }
    }

    for (all_lines.items, 0..) |line, idx| {
        if (!is_import_line[idx]) {
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
