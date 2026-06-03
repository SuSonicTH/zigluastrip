const std = @import("std");
const stdout = @import("stdout.zig");
const luastrip = @import("zigLuaStrip");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);

    if (args.len == 3) {
        try luastrip.file(init.io, args[1], args[2], init.arena.allocator());
    } else {
        _ = try stdout.getWriter(init.io).write("\nusage: zigluastrip <input_file> <output_file>\n");
        stdout.flush(init.io);
    }
}
