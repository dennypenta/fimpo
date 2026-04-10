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
    is_direct_import: bool,
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

fn parseImportPath(init_src: []const u8) ?struct {
    path: []const u8,
    is_direct_import: bool,
} {
    const prefix = "@import(";
    if (!std.mem.startsWith(u8, init_src, prefix)) return null;

    var i: usize = prefix.len;
    while (i < init_src.len and std.ascii.isWhitespace(init_src[i])) : (i += 1) {}
    if (i >= init_src.len or init_src[i] != '"') return null;
    i += 1;

    const path_start = i;
    while (i < init_src.len and init_src[i] != '"') : (i += 1) {}
    if (i >= init_src.len) return null;

    const path = init_src[path_start..i];
    i += 1;

    while (i < init_src.len and std.ascii.isWhitespace(init_src[i])) : (i += 1) {}
    if (i >= init_src.len or init_src[i] != ')') return null;
    i += 1;

    while (i < init_src.len and std.ascii.isWhitespace(init_src[i])) : (i += 1) {}

    return .{
        .path = path,
        .is_direct_import = i == init_src.len,
    };
}

fn parseImportDecl(tree: Ast, node: Ast.Node.Index, line: []const u8, line_index: usize) ?ImportLine {
    const var_decl = tree.fullVarDecl(node) orelse return null;
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return null;

    const lhs_token = var_decl.ast.mut_token + 1;
    if (tree.tokenTag(lhs_token) != .identifier) return null;
    const lhs = tree.tokenSlice(lhs_token);

    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    const init_src = nodeSource(tree, init_node);

    if (parseImportPath(init_src)) |parsed_import| {
        return .{
            .line = line,
            .lhs = lhs,
            .path = parsed_import.path,
            .kind = classifyPath(parsed_import.path),
            .is_direct_import = parsed_import.is_direct_import,
            .line_index = line_index,
        };
    }

    if (!std.mem.startsWith(u8, init_src, "std.")) return null;

    return .{
        .line = line,
        .lhs = lhs,
        .path = "",
        .kind = .std_use,
        .is_direct_import = true,
        .line_index = line_index,
    };
}

fn isIdentChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_';
}

fn containsIdent(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, search_from, needle)) |idx| {
        const before_ok = idx == 0 or !isIdentChar(haystack[idx - 1]);
        const after_idx = idx + needle.len;
        const after_ok = after_idx == haystack.len or !isIdentChar(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        search_from = idx + needle.len;
    }

    return false;
}

fn usesAnyImport(decl_src: []const u8, imported_names: []const []const u8) bool {
    for (imported_names) |name| {
        if (containsIdent(decl_src, name)) return true;
    }
    return false;
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
        while (j > 0) : (j -= 1) {
            const prev = items[j - 1];
            const curr = items[j];

            const path_order = std.mem.order(u8, prev.path, curr.path);
            const should_swap = switch (path_order) {
                .gt => true,
                .lt => false,
                .eq => if (prev.is_direct_import != curr.is_direct_import)
                    !prev.is_direct_import and curr.is_direct_import
                else
                    std.mem.order(u8, prev.lhs, curr.lhs) == .gt,
            };

            if (!should_swap) break;
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

fn readInputFromPath(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk try std.fs.openFileAbsolute(path, .{});
        }
        break :blk try std.fs.cwd().openFile(path, .{});
    };

    defer file.close();
    return try file.readToEndAlloc(allocator, max_bytes);
}

fn writeOutputToPath(path: []const u8, data: []const u8) !void {
    const file = blk: {
        if (std.fs.path.isAbsolute(path)) {
            break :blk try std.fs.createFileAbsolute(path, .{ .truncate = true });
        }
        break :blk try std.fs.cwd().createFile(path, .{ .truncate = true });
    };
    defer file.close();
    try file.writeAll(data);
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

    var imported_names = std.ArrayList([]const u8).empty;
    defer imported_names.deinit(allocator);

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
    var import_block_started = false;
    var import_block_ended = false;
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

        if (import_block_ended) continue;

        const parsed = parseImportDecl(tree, decl, line, line_cursor) orelse {
            if (import_block_started and tree.fullVarDecl(decl) != null) {
                const decl_src = nodeSource(tree, decl);
                if (!usesAnyImport(decl_src, imported_names.items)) {
                    import_block_ended = true;
                }
            }
            continue;
        };

        import_block_started = true;
        is_import_line[parsed.line_index] = true;
        try imported_names.append(allocator, parsed.lhs);

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

    const max_input_bytes = 16 * 1024 * 1024;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 2) {
        var stdout_buffer: [1024]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&stdout_buffer);
        const stderr = &writer.interface;

        try stderr.print("Usage: {s} [path-to-file]\n", .{args[0]});
        return error.InvalidArguments;
    }

    if (args.len == 2) {
        std.debug.print("args: {s}\n", .{args[1]});

        const path = args[1];
        const input = try readInputFromPath(allocator, path, max_input_bytes);
        defer allocator.free(input);

        const output = try formatImports(allocator, input);
        defer allocator.free(output);

        try writeOutputToPath(path, output);
        return;
    }

    var stdin_buffer: [1024]u8 = undefined;
    var stdout_buffer: [1024]u8 = undefined;
    var stdinReader = std.fs.File.stdin().reader(&stdin_buffer);
    var stdoutWriter = std.fs.File.stdout().writer(&stdout_buffer);
    const stdin = &stdinReader.interface;
    const stdout = &stdoutWriter.interface;

    const input = try stdin.readAlloc(allocator, max_input_bytes);
    defer allocator.free(input);

    const output = try formatImports(allocator, input);
    defer allocator.free(output);

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

    const in8 =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\
        \\const Filenames = @import("../../Filenames.zig");
        \\const fs = @import("../../fs.zig");
        \\const MemTable = @import("../inmem/MemTable.zig");
        \\const DiskTable = @import("DiskTable.zig");
        \\const IndexBlockHeader = @import("../inmem/IndexBlockHeader.zig");
        \\const TableHeader = @import("../inmem/TableHeader.zig");
        \\const ColumnIDGen = @import("../inmem/ColumnIDGen.zig");
        \\const encoding = @import("encoding");
        \\
        \\const catalog = @import("../table/catalog.zig");
        \\
        \\const Table = @This();
        \\
        \\disk: ?*DiskTable,
        \\mem: ?*MemTable,
        \\
        \\pub fn do(self: *Table) void {
        \\    _ = self;
        \\}
        \\
        \\const testing = std.testing;
        \\
        \\test "test doing" {
        \\    try testing.expect(true);
        \\}
    ;
    const out8 =
        \\const std = @import("std");
        \\const Allocator = std.mem.Allocator;
        \\
        \\const encoding = @import("encoding");
        \\
        \\const DiskTable = @import("DiskTable.zig");
        \\
        \\const Filenames = @import("../../Filenames.zig");
        \\const fs = @import("../../fs.zig");
        \\const ColumnIDGen = @import("../inmem/ColumnIDGen.zig");
        \\const IndexBlockHeader = @import("../inmem/IndexBlockHeader.zig");
        \\const MemTable = @import("../inmem/MemTable.zig");
        \\const TableHeader = @import("../inmem/TableHeader.zig");
        \\const catalog = @import("../table/catalog.zig");
        \\
        \\const Table = @This();
        \\
        \\disk: ?*DiskTable,
        \\mem: ?*MemTable,
        \\
        \\pub fn do(self: *Table) void {
        \\    _ = self;
        \\}
        \\
        \\const testing = std.testing;
        \\
        \\test "test doing" {
        \\    try testing.expect(true);
        \\}
    ;

    const in9 =
        \\const foo = @import("foo");
        \\const std = @import("std");
        \\const tt = @import("../tt.zig");
        \\const xBeta = @import("../beta.zig").x;
        \\const alpha = @import("alpha.zig");
        \\const beta = @import("../beta.zig");
        \\const byAlpha = @import("alpha.zig").by;
        \\
        \\pub const T = @This();
        \\
        \\const byBeta = @import("../beta.zig").by;
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
    const out9 =
        \\const std = @import("std");
        \\
        \\const foo = @import("foo");
        \\
        \\const alpha = @import("alpha.zig");
        \\const byAlpha = @import("alpha.zig").by;
        \\
        \\const beta = @import("../beta.zig");
        \\const xBeta = @import("../beta.zig").x;
        \\const tt = @import("../tt.zig");
        \\
        \\pub const T = @This();
        \\
        \\const byBeta = @import("../beta.zig").by;
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

    try expectFormatted(in1, out1);
    try expectFormatted(in2, out2);
    try expectFormatted(in3, out3);
    try expectFormatted(in4, out4);
    try expectFormatted(in5, out5);
    try expectFormatted(in6, out6);
    try expectFormatted(in7, out7);
    try expectFormatted(in8, out8);
    try expectFormatted(in9, out9);
}
