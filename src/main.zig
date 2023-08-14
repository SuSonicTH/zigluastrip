const std = @import("std");
const luastrip = @import("zigLuaStrip");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 3) {
        try luastrip.file(args[1], args[2], allocator);
    } else {
        try std.io.getStdOut().writer().writeAll("\nusage: zigluastrip <input_file> <output_file>\n");
    }
}
