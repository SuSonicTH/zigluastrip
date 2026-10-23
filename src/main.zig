const std = @import("std");
const stdout = @import("stdout.zig");
const luastrip = @import("zigLuaStrip");

const usage = "\nusage: zigluastrip <input_file> <output_file>\n";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);

    if (args.len != 3) {
        _ = try stdout.getErrWriter(init.io).write(usage);
        stdout.flushErr(init.io);
        std.process.exit(2);
    }

    luastrip.file(init.io, args[1], args[2], init.arena.allocator()) catch |err| {
        stdout.getErrWriter(init.io).print("error: {s}\n", .{@errorName(err)}) catch {};
        stdout.flushErr(init.io);
        std.process.exit(1);
    };
}
