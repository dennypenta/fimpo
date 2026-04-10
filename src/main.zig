const std = @import("std");

pub fn main() !void {
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
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

    _ = in1;
    _ = out1;
    _ = in2;
    _ = out2;
    _ = in3;
    _ = out3;
    _ = in4;
    _ = out4;
    _ = in5;
    _ = out5;
    _ = in6;
    _ = out6;
    _ = in7;
    _ = out7;
}
