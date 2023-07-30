const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 3) {
        try luastrip_file(args[1], args[2], allocator);
    } else {
        try std.io.getStdOut().writer().writeAll("\nusage: zigluastrip <input_file> <output_file>\n");
    }
}

pub fn luastrip_file(input: [:0]const u8, output: [:0]const u8, allocator: std.mem.Allocator) !void {
    const input_file = try std.fs.cwd().openFile(input, .{});
    defer input_file.close();

    const file_size = (try input_file.stat()).size;
    const data = try allocator.alloc(u8, file_size);
    defer allocator.free(data);
    _ = try input_file.reader().readAll(data);

    const stripped = try luastrip(data, allocator);
    defer allocator.free(stripped);

    const output_file = try std.fs.cwd().createFile(output, .{});
    defer output_file.close();

    try output_file.writer().writeAll(stripped);
}

pub fn luastrip(source: []u8, allocator: std.mem.Allocator) ![:0]const u8 {
    var iterator: Tokenizer = .{
        .data = source,
    };
    iterator.peek = iterator.next_token();

    const buffer = try allocator.alloc(u8, source.len + 1);
    errdefer allocator.free(buffer);
    var pos: usize = 0;

    var token = iterator.next();
    while (token[0] != 0) : (token = iterator.next()) {
        std.mem.copyForwards(u8, buffer[pos..], token);
        pos += token.len;
        switch (token[0]) {
            ' ', '{', '}', '(', ')', '.', '+', '-', '*', '/', '"', '\'', '[', ']', '\n', '#', '=', ',', '~', ':' => {
                if (iterator.peek[0] == ' ') {
                    _ = iterator.next();
                }
            },
            else => {
                switch (iterator.peek[0]) {
                    ' ', '{', '}', '(', ')', '.', '+', '-', '*', '/', '"', '\'', '[', ']', '\n', '#', '=', ',', '~', ':' => {},
                    else => {
                        buffer[pos] = ' ';
                        pos += 1;
                    },
                }
            },
        }
    }

    buffer[pos] = 0;
    pos += 1;
    const ret = try allocator.realloc(buffer, pos);
    return ret[0 .. pos - 1 :0];
}

const Tokenizer = struct {
    data: []u8 = undefined,
    pos: usize = 0,
    peek: []const u8 = " ",

    pub fn next(self: *Tokenizer) []const u8 {
        const token = self.peek;
        self.peek = self.next_token();
        if (token[0] == ' ') {
            while (self.peek[0] == ' ') {
                self.peek = self.next_token();
            }
        }
        return token;
    }

    fn next_token(self: *Tokenizer) []const u8 {
        if (self.pos == self.data.len - 1) {
            return "\x00";
        }

        switch (self.data[self.pos]) {
            ' ', '\t' => {
                while (self.pos < self.data.len - 1 and (self.data[self.pos] == ' ' or self.data[self.pos] == '\t')) {
                    self.pos += 1;
                }
                return self.next_token();
            },
            '\r', '\n' => {
                while (self.pos < self.data.len - 1 and (self.data[self.pos] == '\r' or self.data[self.pos] == '\n')) {
                    self.pos += 1;
                }
                return " ";
            },
            '-' => {
                if (self.pos < self.data.len - 2 and self.data[self.pos + 1] == '-') {
                    const blockLen = getBlockLen(self.data[self.pos + 2 ..]);
                    if (blockLen > 0) {
                        self.pos += blockLen + 2;
                    } else {
                        while (self.pos < self.data.len - 1 and self.data[self.pos] != '\r' and self.data[self.pos] != '\n') {
                            self.pos += 1;
                        }
                    }
                    return self.next_token();
                } else {
                    self.pos += 1;
                    return "-";
                }
            },
            '_', 'a'...'z', 'A'...'Z', '0'...'9' => {
                const start = self.pos;
                self.pos += 1;
                while (self.pos < self.data.len) {
                    switch (self.data[self.pos]) {
                        '_', 'a'...'z', 'A'...'Z', '0'...'9' => {
                            self.pos += 1;
                        },
                        else => {
                            return self.data[start..self.pos];
                        },
                    }
                }
                std.log.debug("err>{s}<", .{self.data[start..]});
                unreachable;
            },
            '"' => {
                const start = self.pos;
                self.pos += 1;
                while (self.pos < self.data.len - 1 and (self.data[self.pos] != '"' or self.data[self.pos - 1] == '\\')) {
                    self.pos += 1;
                }
                self.pos += 1;
                return self.data[start..self.pos];
            },
            '\'' => {
                const start = self.pos;
                self.pos += 1;
                while (self.pos < self.data.len - 1 and (self.data[self.pos] != '\'' or self.data[self.pos - 1] == '\\')) {
                    self.pos += 1;
                }
                self.pos += 1;
                return self.data[start..self.pos];
            },
            '[' => {
                const blockLen = getBlockLen(self.data[self.pos..]);
                if (blockLen > 0) {
                    const start = self.pos;
                    self.pos += blockLen;
                    return self.data[start .. start + blockLen];
                } else {
                    self.pos += 1;
                    return "[";
                }
            },
            '.' => {
                if (self.data[self.pos + 1] == '.') {
                    if (self.data[self.pos + 2] == '.') {
                        self.pos += 3;
                        return "...";
                    } else {
                        self.pos += 2;
                        return "..";
                    }
                } else {
                    self.pos += 1;
                    return ".";
                }
            },
            else => {
                const cpos = self.pos;
                self.pos += 1;
                return self.data[cpos .. cpos + 1];
            },
        }
        unreachable;
    }
};

fn getBlockLen(data: []u8) usize {
    const eqals = "========================================================================================================================";
    if (data[0] != '[') {
        return 0;
    }
    var eqlen: usize = 0;
    while (data[1 + eqlen] == '=' and eqlen <= eqals.len) {
        eqlen += 1;
    }
    if (data[eqlen + 1] != '[') {
        return 0;
    }

    var pos = eqlen + 2;
    while (pos < data.len) : (pos += 1) {
        if (data[pos] == ']') {
            if ((eqlen == 0 or std.mem.eql(u8, data[pos + 1 .. pos + 1 + eqlen], eqals[0..eqlen])) and data[pos + 1 + eqlen] == ']') {
                return pos + eqlen + 2;
            }
        }
    }
    return 0;
}
